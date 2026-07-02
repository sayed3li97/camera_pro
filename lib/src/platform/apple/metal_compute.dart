/// Runtime GPU/CPU dispatch for visual aids on Apple platforms.
///
/// Wraps the Metal compute kernels in `metal_processor.m` (runtime-compiled
/// MSL, bit-compatible with the C CPU kernels — cross-checked by
/// `src/platform/apple/metal_test.c` on the real GPU). When no Metal device is
/// available these calls report unsupported and callers fall back to the CPU
/// path in [NativeCore].
library;

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as pkg_ffi;

import '../../ffi/hal_bindings.dart' as hal;

/// GPU compute entry points (Apple platforms).
class MetalCompute {
  const MetalCompute._();

  /// Whether a Metal device is present and the kernels compiled.
  static bool get available => hal.camera_pro_metal_available() == 1;

  /// The GPU name, e.g. "Apple M1 Pro" (empty when unavailable).
  static String get deviceName =>
      hal.camera_pro_metal_device_name().cast<pkg_ffi.Utf8>().toDartString();

  /// GPU focus peaking; identical semantics to [NativeCore.focusPeaking].
  /// Returns null when the GPU path is unavailable (caller falls back to CPU).
  static Uint8List? focusPeaking(
    Uint8List pixels, {
    required int width,
    required int height,
    bool isBgra = true,
    double threshold = 0.15,
    int peakColor = 0xFFFFFFFF,
  }) {
    if (!available) return null;
    final src = pkg_ffi.malloc<ffi.Uint8>(pixels.length);
    final out = pkg_ffi.malloc<ffi.Uint8>(width * height * 4);
    try {
      src.asTypedList(pixels.length).setAll(0, pixels);
      final rc = hal.camera_pro_metal_focus_peaking(
          src, out, width, height, isBgra ? 1 : 0, threshold, peakColor);
      if (rc != 0) return null;
      return Uint8List.fromList(out.asTypedList(width * height * 4));
    } finally {
      pkg_ffi.malloc.free(src);
      pkg_ffi.malloc.free(out);
    }
  }

  /// GPU zebra; identical semantics to [NativeCore.zebra].
  static Uint8List? zebra(
    Uint8List pixels, {
    required int width,
    required int height,
    bool isBgra = true,
    double threshold = 0.9,
    int frameCounter = 0,
  }) {
    if (!available) return null;
    final src = pkg_ffi.malloc<ffi.Uint8>(pixels.length);
    final out = pkg_ffi.malloc<ffi.Uint8>(width * height * 4);
    try {
      src.asTypedList(pixels.length).setAll(0, pixels);
      final rc = hal.camera_pro_metal_zebra(
          src, out, width, height, isBgra ? 1 : 0, threshold, frameCounter);
      if (rc != 0) return null;
      return Uint8List.fromList(out.asTypedList(width * height * 4));
    } finally {
      pkg_ffi.malloc.free(src);
      pkg_ffi.malloc.free(out);
    }
  }
}
