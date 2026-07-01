/// FFI bindings for the shared C core (`camera_pro_core.h`).
///
/// These `@Native` externals bind to the code asset produced by
/// `hook/build.dart`. The asset id below must match the `assetName` passed to
/// `CBuilder.library` in that hook. In a normal ffigen workflow this file would
/// be generated (`dart run ffigen`); it is hand-maintained here so the
/// foundation builds without libclang installed, and kept 1:1 with the header.
///
/// Symbol names intentionally mirror the C API, so the usual identifier lints
/// are disabled for this file only.
@ffi.DefaultAsset('package:camera_pro/src/ffi/camera_pro_bindings.dart')
library;

// ignore_for_file: non_constant_identifier_names, camel_case_types

import 'dart:ffi' as ffi;

/// Opaque handle to a native frame buffer pool.
final class CameraProBufferPool extends ffi.Opaque {}

// ── Version / introspection ────────────────────────────────────────────────

@ffi.Native<ffi.Int32 Function()>()
external int camera_pro_core_version();

@ffi.Native<ffi.Pointer<ffi.Char> Function()>()
external ffi.Pointer<ffi.Char> camera_pro_core_version_string();

@ffi.Native<ffi.Int32 Function()>()
external int camera_pro_simd_level();

@ffi.Native<ffi.Pointer<ffi.Char> Function()>()
external ffi.Pointer<ffi.Char> camera_pro_simd_name();

@ffi.Native<ffi.Pointer<ffi.Char> Function(ffi.Int32)>()
external ffi.Pointer<ffi.Char> camera_pro_error_string(int error);

// ── Buffer pool ────────────────────────────────────────────────────────────

@ffi.Native<ffi.Pointer<CameraProBufferPool> Function(ffi.Int32, ffi.Int32)>()
external ffi.Pointer<CameraProBufferPool> camera_pro_buffer_pool_create(
  int bufferSize,
  int bufferCount,
);

@ffi.Native<
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<CameraProBufferPool>,
      ffi.Pointer<ffi.Int32>,
    )>()
external ffi.Pointer<ffi.Uint8> camera_pro_buffer_pool_acquire(
  ffi.Pointer<CameraProBufferPool> pool,
  ffi.Pointer<ffi.Int32> outSize,
);

@ffi.Native<
    ffi.Void Function(
      ffi.Pointer<CameraProBufferPool>,
      ffi.Pointer<ffi.Uint8>,
    )>()
external void camera_pro_buffer_pool_release(
  ffi.Pointer<CameraProBufferPool> pool,
  ffi.Pointer<ffi.Uint8> buffer,
);

@ffi.Native<ffi.Int32 Function(ffi.Pointer<CameraProBufferPool>)>()
external int camera_pro_buffer_pool_available(
  ffi.Pointer<CameraProBufferPool> pool,
);

@ffi.Native<ffi.Int32 Function(ffi.Pointer<CameraProBufferPool>)>()
external int camera_pro_buffer_pool_capacity(
  ffi.Pointer<CameraProBufferPool> pool,
);

@ffi.Native<ffi.Void Function(ffi.Pointer<CameraProBufferPool>)>()
external void camera_pro_buffer_pool_destroy(
  ffi.Pointer<CameraProBufferPool> pool,
);

// ── Histogram ──────────────────────────────────────────────────────────────

@ffi.Native<
    ffi.Void Function(
      ffi.Pointer<ffi.Uint8>,
      ffi.Int32,
      ffi.Int32,
      ffi.Int32,
      ffi.Pointer<ffi.Uint32>,
      ffi.Pointer<ffi.Uint32>,
      ffi.Pointer<ffi.Uint32>,
      ffi.Pointer<ffi.Uint32>,
    )>()
external void camera_pro_compute_histogram_rgba(
  ffi.Pointer<ffi.Uint8> rgba,
  int width,
  int height,
  int stride,
  ffi.Pointer<ffi.Uint32> lumaHist,
  ffi.Pointer<ffi.Uint32> rHist,
  ffi.Pointer<ffi.Uint32> gHist,
  ffi.Pointer<ffi.Uint32> bHist,
);

// ── Visual aids ────────────────────────────────────────────────────────────

@ffi.Native<
    ffi.Int32 Function(
      ffi.Pointer<ffi.Uint8>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Int32,
      ffi.Int32,
      ffi.Int32,
      ffi.Float,
      ffi.Uint32,
    )>()
external int camera_pro_compute_focus_peaking(
  ffi.Pointer<ffi.Uint8> rgba,
  ffi.Pointer<ffi.Uint8> outRgba,
  int width,
  int height,
  int stride,
  double threshold,
  int peakColor,
);

@ffi.Native<
    ffi.Int32 Function(
      ffi.Pointer<ffi.Uint8>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Int32,
      ffi.Int32,
      ffi.Int32,
      ffi.Float,
      ffi.Int32,
    )>()
external int camera_pro_compute_zebra(
  ffi.Pointer<ffi.Uint8> rgba,
  ffi.Pointer<ffi.Uint8> outRgba,
  int width,
  int height,
  int stride,
  double threshold,
  int frameCounter,
);

// ── Format conversion ──────────────────────────────────────────────────────

@ffi.Native<
    ffi.Int32 Function(
      ffi.Pointer<ffi.Uint8>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Int32,
      ffi.Int32,
      ffi.Pointer<ffi.Uint8>,
      ffi.Int32,
      ffi.Int32,
    )>()
external int camera_pro_yuv420p_to_rgba(
  ffi.Pointer<ffi.Uint8> y,
  ffi.Pointer<ffi.Uint8> u,
  ffi.Pointer<ffi.Uint8> v,
  int yStride,
  int uvStride,
  ffi.Pointer<ffi.Uint8> rgba,
  int width,
  int height,
);
