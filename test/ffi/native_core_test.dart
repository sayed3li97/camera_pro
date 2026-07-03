// Exercises the real FFI boundary: these tests call into the C core compiled
// by hook/build.dart. They run under `flutter test` because native assets are
// built for the host. If the native asset isn't available (e.g. a platform
// where the hook didn't run), the whole group is skipped rather than failing.
@TestOn('vm') // uses dart:ffi — never runs in the browser
library;

import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:camera_pro/camera_pro.dart';
// ignore: implementation_imports
import 'package:camera_pro/src/ffi/camera_pro_bindings.dart' as bindings;
import 'package:ffi/ffi.dart' as pkg_ffi;
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Probe once: can we reach the native core at all?
  var nativeAvailable = true;
  String? version;
  try {
    version = NativeCore.versionString;
  } on Object {
    nativeAvailable = false;
  }

  group('native core FFI', () {
    test('reports version 0.1.0', () {
      expect(version, '0.1.0');
      expect(NativeCore.versionCode, (0 << 16) | (1 << 8) | 0);
    });

    test('reports an active SIMD kernel', () {
      expect(
        NativeCore.simdName,
        anyOf('NEON', 'AVX2', 'SSE2', 'scalar'),
      );
    });

    test('maps error codes to strings', () {
      expect(NativeCore.errorString(0), 'OK');
      expect(NativeCore.errorString(6), 'Camera permission denied');
    });

    test('computes a histogram over a real RGBA buffer', () {
      // 4x4 solid mid-gray image.
      const w = 4, h = 4;
      final rgba = Uint8List(w * h * 4);
      for (var i = 0; i < w * h; i++) {
        rgba[i * 4 + 0] = 128;
        rgba[i * 4 + 1] = 128;
        rgba[i * 4 + 2] = 128;
        rgba[i * 4 + 3] = 255;
      }
      final hist = NativeCore.histogramFromRgba(rgba, width: w, height: h);
      expect(hist.totalPixels, w * h);
      // Solid gray => everything in one luma bin.
      expect(hist.luminance[128], w * h);
      expect(hist.peak, w * h);
    });

    test('computes a luminance waveform over a real buffer', () {
      const w = 16, h = 4;
      final rgba = Uint8List(w * h * 4);
      for (var i = 0; i < w * h; i++) {
        rgba[i * 4 + 0] = 128;
        rgba[i * 4 + 1] = 128;
        rgba[i * 4 + 2] = 128;
        rgba[i * 4 + 3] = 255;
      }
      final wf = NativeCore.waveformFromRgba(rgba, width: w, height: h, columns: 8);
      expect(wf.columns, 8);
      // Solid gray => each column's pixels all land in luma bin 128.
      expect(wf.at(0, 128), (w ~/ 8) * h);
      expect(wf.at(3, 128), (w ~/ 8) * h);
      expect(wf.at(0, 200), 0);
    });

    test('produces a false-color exposure map', () {
      const w = 4, h = 4;
      Uint8List solid(int v) {
        final b = Uint8List(w * h * 4);
        for (var i = 0; i < w * h; i++) {
          b[i * 4 + 0] = v;
          b[i * 4 + 1] = v;
          b[i * 4 + 2] = v;
          b[i * 4 + 3] = 255;
        }
        return b;
      }

      final gray = NativeCore.falseColorFromRgba(solid(128), width: w, height: h);
      expect([gray[0], gray[1], gray[2]], [0xC0, 0xC0, 0xC0]); // mid => gray
      final white = NativeCore.falseColorFromRgba(solid(255), width: w, height: h);
      expect([white[0], white[1], white[2]], [0xFF, 0x00, 0x00]); // clip => red
    });

    test('focus peaking highlights a sharp edge', () {
      const w = 16, h = 16;
      final rgba = Uint8List(w * h * 4);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final v = x >= w ~/ 2 ? 255 : 0;
          final i = (y * w + x) * 4;
          rgba[i] = v;
          rgba[i + 1] = v;
          rgba[i + 2] = v;
          rgba[i + 3] = 255;
        }
      }
      final out = NativeCore.focusPeaking(rgba,
          width: w, height: h, isBgra: false, threshold: 0.2);
      // The vertical edge column should be tinted white (0xFF,0xFF,0xFF).
      var found = false;
      for (var y = 1; y < h - 1; y++) {
        final i = (y * w + w ~/ 2) * 4;
        if (out[i] == 0xFF && out[i + 1] == 0xFF && out[i + 2] == 0xFF) {
          found = true;
        }
      }
      expect(found, isTrue);
    });

    test('zebra stripes over-exposure on a bright image', () {
      const w = 16, h = 16;
      final rgba = Uint8List.fromList(
          List<int>.generate(w * h * 4, (i) => i % 4 == 3 ? 255 : 255));
      final out = NativeCore.zebra(rgba,
          width: w, height: h, isBgra: false, threshold: 0.9);
      // Some pixels become red (255,0,0) stripes.
      var striped = false;
      for (var i = 0; i < w * h; i++) {
        if (out[i * 4] == 255 && out[i * 4 + 1] == 0 && out[i * 4 + 2] == 0) {
          striped = true;
        }
      }
      expect(striped, isTrue);
    });

    test('writes a valid DNG through FFI', () async {
      const w = 8, h = 8;
      final rgba = Uint8List(w * h * 4);
      for (var i = 0; i < w * h; i++) {
        rgba[i * 4] = 200;
        rgba[i * 4 + 1] = 100;
        rgba[i * 4 + 2] = 50;
        rgba[i * 4 + 3] = 255;
      }
      final path =
          '${Directory.systemTemp.path}/cp_ffi_test_${DateTime.now().millisecondsSinceEpoch}.dng';
      final px = pkg_ffi.malloc<ffi.Uint8>(rgba.length);
      final cPath = path.toNativeUtf8(allocator: pkg_ffi.malloc);
      final cStr = 'test'.toNativeUtf8(allocator: pkg_ffi.malloc);
      final cTime = '2026:07:02 12:00:00'.toNativeUtf8(allocator: pkg_ffi.malloc);
      try {
        px.asTypedList(rgba.length).setAll(0, rgba);
        final rc = bindings.camera_pro_write_dng(
          cPath.cast(), px, w, h, w * 4, 0, 200, 8333333,
          cStr.cast(), cStr.cast(), cTime.cast(),
        );
        expect(rc, 0);
        final bytes = File(path).readAsBytesSync();
        // TIFF little-endian magic "II*\0".
        expect(bytes.sublist(0, 3), [0x49, 0x49, 0x2A]);
        expect(bytes.length, greaterThan(w * h * 3));
      } finally {
        pkg_ffi.malloc.free(px);
        pkg_ffi.malloc.free(cPath);
        pkg_ffi.malloc.free(cStr);
        pkg_ffi.malloc.free(cTime);
      }
    });

    test('buffer pool acquires, drains, and releases', () {
      final pool = NativeBufferPool.create(bufferSize: 1024, count: 2);
      expect(pool, isNotNull);
      final p = pool!;
      expect(p.available, 2);
      final a = p.acquire();
      final b = p.acquire();
      expect(a.address != 0 && b.address != 0, isTrue);
      expect(p.available, 0);
      p.release(a);
      expect(p.available, 1);
      p.dispose();
    });
  }, skip: nativeAvailable ? false : 'native core asset unavailable on host');
}
