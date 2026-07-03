/// Web stub for [MetalCompute]. There is no Metal on web, so every entry point
/// reports unavailable and callers fall back to the pure-Dart `NativeCore`
/// kernels. (A WebGPU compute path is future work — see ROADMAP.md.)
library;

import 'dart:typed_data';

/// No-op GPU compute facade for the web target.
class MetalCompute {
  const MetalCompute._();

  static bool get available => false;
  static String get deviceName => '';

  static Uint8List? focusPeaking(
    Uint8List pixels, {
    required int width,
    required int height,
    bool isBgra = true,
    double threshold = 0.15,
    int peakColor = 0xFFFFFFFF,
  }) =>
      null;

  static Uint8List? zebra(
    Uint8List pixels, {
    required int width,
    required int height,
    bool isBgra = true,
    double threshold = 0.9,
    int frameCounter = 0,
  }) =>
      null;
}
