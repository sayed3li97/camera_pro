// Verifies the pure-Dart visual-aid kernels used by the web backend.
//
// On the browser (`--platform chrome`) `NativeCore` resolves to the pure-Dart
// web implementation; on the VM it resolves to the FFI core. Running this on
// both platforms therefore also cross-checks that the two implementations agree
// (the web kernels are ports of the C reference, so values are identical).
import 'dart:typed_data';

import 'package:camera_pro/camera_pro.dart';
// ignore: implementation_imports
import 'package:camera_pro/src/web/web_dng.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _solid(int w, int h, int r, int g, int b) {
  final px = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    px[i * 4] = r;
    px[i * 4 + 1] = g;
    px[i * 4 + 2] = b;
    px[i * 4 + 3] = 255;
  }
  return px;
}

void main() {
  group('web NativeCore kernels', () {
    test('histogram bins a solid color exactly', () {
      const w = 10, h = 8;
      final hist = NativeCore.histogramFromRgba(
        _solid(w, h, 200, 100, 50),
        width: w,
        height: h,
      );
      expect(hist.red[200], w * h);
      expect(hist.green[100], w * h);
      expect(hist.blue[50], w * h);
      // luma = (77*200 + 150*100 + 29*50) >> 8 = (15400+15000+1450)>>8 = 124
      expect(hist.luminance[124], w * h);
    });

    test('false color maps a mid-luma frame to the green zone', () {
      const w = 4, h = 4;
      // luma 124 → the 100..149 "correct exposure" band → grey 0xC0C0C0.
      final out = NativeCore.falseColorFromRgba(
        _solid(w, h, 200, 100, 50),
        width: w,
        height: h,
        isBgra: false,
      );
      expect(out[0], 0xC0);
      expect(out[1], 0xC0);
      expect(out[2], 0xC0);
    });

    test('zebra stripes a clipped highlight, leaves darks alone', () {
      const w = 8, h = 8;
      final bright = NativeCore.zebra(
        _solid(w, h, 255, 255, 255),
        width: w,
        height: h,
        isBgra: false,
        threshold: 0.9,
        frameCounter: 0,
      );
      // Some pixels must be recolored to the red stripe (255,0,0).
      var striped = 0;
      for (var i = 0; i < w * h; i++) {
        if (bright[i * 4] == 255 && bright[i * 4 + 1] == 0 && bright[i * 4 + 2] == 0) {
          striped++;
        }
      }
      expect(striped, greaterThan(0));

      final dark = NativeCore.zebra(
        _solid(w, h, 10, 10, 10),
        width: w,
        height: h,
        isBgra: false,
        threshold: 0.9,
      );
      for (var i = 0; i < w * h; i++) {
        expect(dark[i * 4], 10, reason: 'dark pixels untouched');
      }
    });

    test('adjustPixels brightens with gain and darkens with negative bias', () {
      const w = 4, h = 4;
      final base = _solid(w, h, 100, 100, 100);
      final up = Uint8List.fromList(base);
      NativeCore.adjustPixels(up, width: w, height: h, isBgra: false, gain: 2.0);
      expect(up[0], 200); // 100 * 2.0
      final down = Uint8List.fromList(base);
      NativeCore.adjustPixels(down, width: w, height: h, isBgra: false, bias: -40);
      expect(down[0], 60); // 100 - 40
    });

    test('adjustPixels rounds to nearest like the C clampf_u8', () {
      const w = 2, h = 2;
      // R=101, gain=1.5 → 151.5 → rounds to 152 (truncation would give 151).
      final px = _solid(w, h, 101, 101, 101);
      NativeCore.adjustPixels(px, width: w, height: h, isBgra: false, gain: 1.5);
      expect(px[0], 152);
    });

    test('digitalZoom center-crops (edges pull toward the center)', () {
      const w = 8, h = 8;
      // Distinct corners; a 2x crop should replace the corner with center color.
      final px = _solid(w, h, 10, 20, 30);
      px[0] = 200; // top-left R marker (outside the 2x central crop)
      final out =
          NativeCore.digitalZoom(px, width: w, height: h, factor: 2.0);
      expect(out[0], isNot(200), reason: 'corner cropped away by 2x zoom');
    });

    test('boxBlur spreads a single bright pixel to neighbors', () {
      const w = 8, h = 8;
      final px = Uint8List(w * h * 4);
      for (var i = 0; i < w * h; i++) {
        px[i * 4 + 3] = 255;
      }
      final c = ((h ~/ 2) * w + w ~/ 2) * 4;
      px[c] = px[c + 1] = px[c + 2] = 255; // one white pixel
      NativeCore.boxBlur(px, width: w, height: h, radius: 2);
      // A neighbor that was black must now be non-zero.
      final n = ((h ~/ 2) * w + w ~/ 2 + 1) * 4;
      expect(px[n], greaterThan(0));
    });

    test('encodeLinearDng emits a valid little-endian TIFF/DNG', () {
      const w = 8, h = 6;
      final dng = encodeLinearDng(
        rgba: _solid(w, h, 200, 100, 50),
        width: w,
        height: h,
        isBgra: false,
        iso: 400,
        exposureNs: 16666667,
      );
      expect(dng[0], 0x49); // 'I'
      expect(dng[1], 0x49); // 'I'
      expect(dng[2], 42); // TIFF magic
      // header + IFDs + values + w*h*3 pixels.
      expect(dng.length, greaterThan(w * h * 3));
    });

    test('focus peaking marks a hard edge and reports the SIMD name', () {
      expect(NativeCore.simdName, isNotEmpty);
      const w = 6, h = 6;
      // Left half black, right half white → a vertical edge down the middle.
      final px = Uint8List(w * h * 4);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final v = x >= w ~/ 2 ? 255 : 0;
          final o = (y * w + x) * 4;
          px[o] = px[o + 1] = px[o + 2] = v;
          px[o + 3] = 255;
        }
      }
      final out = NativeCore.focusPeaking(px,
          width: w,
          height: h,
          isBgra: false,
          threshold: 0.1,
          peakColor: 0x00FF00FF); // green marker
      var marked = 0;
      for (var i = 0; i < w * h; i++) {
        if (out[i * 4 + 1] == 0xFF && out[i * 4] == 0x00) marked++;
      }
      expect(marked, greaterThan(0), reason: 'edge pixels highlighted');
    });

    test('exposure fusion lifts shadows and recovers highlights', () {
      // 2-pixel scene, 3-frame bracket: the shadow pixel is only well-exposed
      // in the bright frame, the highlight only in the dark frame.
      const w = 2, h = 1;
      Uint8List frame(int shadow, int highlight) {
        final b = Uint8List(w * h * 4);
        b[0] = b[1] = b[2] = shadow;
        b[3] = 255;
        b[4] = b[5] = b[6] = highlight;
        b[7] = 255;
        return b;
      }

      final fused = NativeCore.exposureFusion(
        <Uint8List>[frame(0, 150), frame(30, 230), frame(110, 255)],
        width: w,
        height: h,
        isBgra: false,
      );
      expect(fused[0], greaterThan(90)); // shadow lifted toward 110
      expect(fused[4], lessThan(180)); // highlight recovered toward 150
      expect(fused[3], 255);
    });

    test('exposure fusion preserves channel order on a colored bracket', () {
      // A saturated orange bracket — pins channel order and saturation, which a
      // grayscale test (R=G=B) can't distinguish.
      Uint8List frame(int r, int g, int b) {
        final px = Uint8List(4);
        px[0] = r;
        px[1] = g;
        px[2] = b;
        px[3] = 255;
        return px;
      }

      final fused = NativeCore.exposureFusion(
        <Uint8List>[frame(40, 24, 12), frame(200, 120, 60), frame(255, 200, 150)],
        width: 1,
        height: 1,
        isBgra: false,
      );
      expect(fused[0], greaterThan(fused[1])); // R > G
      expect(fused[1], greaterThan(fused[2])); // G > B
      expect(fused[0], greaterThan(150));
    });
  });
}
