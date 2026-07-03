// Verifies the pure-Dart visual-aid kernels used by the web backend.
//
// On the browser (`--platform chrome`) `NativeCore` resolves to the pure-Dart
// web implementation; on the VM it resolves to the FFI core. Running this on
// both platforms therefore also cross-checks that the two implementations agree
// (the web kernels are ports of the C reference, so values are identical).
import 'dart:typed_data';

import 'package:camera_pro/camera_pro.dart';
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
  });
}
