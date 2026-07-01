/// High-level, Dart-friendly facade over the FFI bindings.
///
/// Wraps the raw `@Native` externals in `camera_pro_bindings.dart` with typed
/// helpers (version strings, a managed buffer pool, histogram over a
/// `Uint8List`). These execute against the native code asset compiled by
/// `hook/build.dart`; pure-Dart model/logic tests do not touch them.
library;

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as pkg_ffi;

import '../processing/histogram.dart';
import '../processing/waveform.dart';
import 'camera_pro_bindings.dart' as bindings;

/// Static accessors for the shared native core.
class NativeCore {
  const NativeCore._();

  /// Encoded core version `(major << 16) | (minor << 8) | patch`.
  static int get versionCode => bindings.camera_pro_core_version();

  /// Core version as a string, e.g. "0.1.0".
  static String get versionString =>
      bindings.camera_pro_core_version_string().cast<pkg_ffi.Utf8>().toDartString();

  /// The active SIMD kernel name ("NEON", "AVX2", "SSE2", or "scalar").
  static String get simdName =>
      bindings.camera_pro_simd_name().cast<pkg_ffi.Utf8>().toDartString();

  /// Human-readable message for a native `camera_error_t` code.
  static String errorString(int code) => bindings
      .camera_pro_error_string(code)
      .cast<pkg_ffi.Utf8>()
      .toDartString();

  /// Computes luminance + RGB histograms for a tightly-packed RGBA buffer.
  ///
  /// Copies [rgba] into native memory, runs the SIMD kernel, and returns the
  /// bins. For the zero-copy hot path the controller passes a pool pointer
  /// straight through instead; this convenience form is for one-off frames.
  static HistogramData histogramFromRgba(
    Uint8List rgba, {
    required int width,
    required int height,
    int stride = 0,
  }) {
    final effectiveStride = stride == 0 ? width * 4 : stride;
    final src = pkg_ffi.malloc<ffi.Uint8>(rgba.length);
    final luma = pkg_ffi.calloc<ffi.Uint32>(256);
    final red = pkg_ffi.calloc<ffi.Uint32>(256);
    final green = pkg_ffi.calloc<ffi.Uint32>(256);
    final blue = pkg_ffi.calloc<ffi.Uint32>(256);
    try {
      src.asTypedList(rgba.length).setAll(0, rgba);
      bindings.camera_pro_compute_histogram_rgba(
        src, width, height, effectiveStride, luma, red, green, blue,
      );
      return HistogramData(
        luminance: Uint32List.fromList(luma.asTypedList(256)),
        red: Uint32List.fromList(red.asTypedList(256)),
        green: Uint32List.fromList(green.asTypedList(256)),
        blue: Uint32List.fromList(blue.asTypedList(256)),
      );
    } finally {
      pkg_ffi.malloc.free(src);
      pkg_ffi.calloc.free(luma);
      pkg_ffi.calloc.free(red);
      pkg_ffi.calloc.free(green);
      pkg_ffi.calloc.free(blue);
    }
  }

  /// Computes a luminance waveform over a tightly-packed RGBA buffer.
  static WaveformData waveformFromRgba(
    Uint8List rgba, {
    required int width,
    required int height,
    int columns = 256,
    bool isBgra = false,
    int stride = 0,
  }) {
    final effectiveStride = stride == 0 ? width * 4 : stride;
    final src = pkg_ffi.malloc<ffi.Uint8>(rgba.length);
    final out = pkg_ffi.calloc<ffi.Uint32>(columns * 256);
    try {
      src.asTypedList(rgba.length).setAll(0, rgba);
      bindings.camera_pro_compute_luma_waveform(
        src, width, height, effectiveStride, isBgra ? 1 : 0, out, columns,
      );
      return WaveformData(
        columns: columns,
        bins: Uint32List.fromList(out.asTypedList(columns * 256)),
      );
    } finally {
      pkg_ffi.malloc.free(src);
      pkg_ffi.calloc.free(out);
    }
  }

  /// Produces a false-color exposure map (tightly-packed RGBA) for a frame.
  static Uint8List falseColorFromRgba(
    Uint8List rgba, {
    required int width,
    required int height,
    bool isBgra = false,
    int stride = 0,
  }) {
    final effectiveStride = stride == 0 ? width * 4 : stride;
    final src = pkg_ffi.malloc<ffi.Uint8>(rgba.length);
    final out = pkg_ffi.malloc<ffi.Uint8>(width * height * 4);
    try {
      src.asTypedList(rgba.length).setAll(0, rgba);
      bindings.camera_pro_compute_false_color(
        src, out, width, height, effectiveStride, isBgra ? 1 : 0,
      );
      return Uint8List.fromList(out.asTypedList(width * height * 4));
    } finally {
      pkg_ffi.malloc.free(src);
      pkg_ffi.malloc.free(out);
    }
  }

  /// Returns a copy of [pixels] with Sobel-edge focus peaking applied.
  /// [peakColor] is 0xRRGGBBAA. Set [isBgra] for BGRA-ordered input.
  static Uint8List focusPeaking(
    Uint8List pixels, {
    required int width,
    required int height,
    bool isBgra = true,
    double threshold = 0.15,
    int peakColor = 0xFFFFFFFF,
    int stride = 0,
  }) {
    final effectiveStride = stride == 0 ? width * 4 : stride;
    final src = pkg_ffi.malloc<ffi.Uint8>(pixels.length);
    final out = pkg_ffi.malloc<ffi.Uint8>(width * height * 4);
    try {
      src.asTypedList(pixels.length).setAll(0, pixels);
      bindings.camera_pro_compute_focus_peaking(
        src, out, width, height, effectiveStride, isBgra ? 1 : 0, threshold,
        peakColor,
      );
      return Uint8List.fromList(out.asTypedList(width * height * 4));
    } finally {
      pkg_ffi.malloc.free(src);
      pkg_ffi.malloc.free(out);
    }
  }

  /// Returns a copy of [pixels] with zebra over-exposure stripes applied.
  static Uint8List zebra(
    Uint8List pixels, {
    required int width,
    required int height,
    bool isBgra = true,
    double threshold = 0.9,
    int frameCounter = 0,
    int stride = 0,
  }) {
    final effectiveStride = stride == 0 ? width * 4 : stride;
    final src = pkg_ffi.malloc<ffi.Uint8>(pixels.length);
    final out = pkg_ffi.malloc<ffi.Uint8>(width * height * 4);
    try {
      src.asTypedList(pixels.length).setAll(0, pixels);
      bindings.camera_pro_compute_zebra(
        src, out, width, height, effectiveStride, isBgra ? 1 : 0, threshold,
        frameCounter,
      );
      return Uint8List.fromList(out.asTypedList(width * height * 4));
    } finally {
      pkg_ffi.malloc.free(src);
      pkg_ffi.malloc.free(out);
    }
  }
}

/// A managed handle to a native ring buffer pool.
///
/// Owns the native pool and frees it on [dispose]. Frame producers [acquire]
/// buffers (null when drained) and [release] them; no per-frame allocation
/// reaches the Dart GC.
class NativeBufferPool {
  NativeBufferPool._(this._pool, this.bufferSize, this.count);

  /// Creates a pool of [count] buffers, each at least [bufferSize] bytes.
  /// Returns null if the native allocation failed.
  static NativeBufferPool? create({
    required int bufferSize,
    required int count,
  }) {
    final pool = bindings.camera_pro_buffer_pool_create(bufferSize, count);
    if (pool == ffi.nullptr) return null;
    return NativeBufferPool._(pool, bufferSize, count);
  }

  final ffi.Pointer<bindings.CameraProBufferPool> _pool;

  /// Requested buffer size in bytes.
  final int bufferSize;

  /// Number of buffers in the pool.
  final int count;

  bool _disposed = false;

  /// Buffers currently free.
  int get available => _disposed
      ? 0
      : bindings.camera_pro_buffer_pool_available(_pool);

  /// Acquires a buffer, or null if the pool is drained.
  ffi.Pointer<ffi.Uint8> acquire() {
    if (_disposed) return ffi.nullptr;
    final outSize = pkg_ffi.calloc<ffi.Int32>();
    try {
      return bindings.camera_pro_buffer_pool_acquire(_pool, outSize);
    } finally {
      pkg_ffi.calloc.free(outSize);
    }
  }

  /// Returns a buffer to the pool.
  void release(ffi.Pointer<ffi.Uint8> buffer) {
    if (_disposed) return;
    bindings.camera_pro_buffer_pool_release(_pool, buffer);
  }

  /// Frees the native pool.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    bindings.camera_pro_buffer_pool_destroy(_pool);
  }
}
