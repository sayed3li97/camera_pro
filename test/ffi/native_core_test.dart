// Exercises the real FFI boundary: these tests call into the C core compiled
// by hook/build.dart. They run under `flutter test` because native assets are
// built for the host. If the native asset isn't available (e.g. a platform
// where the hook didn't run), the whole group is skipped rather than failing.
import 'dart:typed_data';

import 'package:camera_pro/camera_pro.dart';
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
