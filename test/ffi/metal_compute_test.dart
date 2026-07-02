// GPU/CPU cross-check through the Dart FFI layer (macOS hosts with Metal).
//
// The definitive kernel-level verification lives in
// src/platform/apple/metal_test.c (bit-exact histogram/zebra on the real GPU);
// this test proves the same result holds end-to-end through the Dart bindings.
@TestOn('mac-os')
library;

import 'dart:typed_data';

import 'package:camera_pro/camera_pro.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final gpu = MetalCompute.available;

  group('MetalCompute', () {
    test('reports a GPU device', () {
      expect(MetalCompute.deviceName, isNotEmpty);
    });

    test('GPU zebra output is byte-identical to the CPU kernel', () {
      const w = 64, h = 48;
      final rng = <int>[];
      var seed = 0x12345;
      for (var i = 0; i < w * h * 4; i++) {
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
        rng.add(seed & 0xFF);
      }
      final img = Uint8List.fromList(rng);

      final cpu = NativeCore.zebra(img,
          width: w, height: h, isBgra: true, threshold: 0.7, frameCounter: 3);
      final gpuOut = MetalCompute.zebra(img,
          width: w, height: h, isBgra: true, threshold: 0.7, frameCounter: 3);
      expect(gpuOut, isNotNull);
      expect(gpuOut, equals(cpu));
    });
  }, skip: gpu ? false : 'no Metal device on this host');
}
