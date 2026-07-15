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
//
// These are marked `isLeaf: true`: they run in O(1), never call back into Dart,
// touch no Dart heap or handles, and return immediately — so skipping the
// Dart↔native state transition is a free win with no GC-safepoint hazard. (The
// long-running compute kernels below are deliberately NOT leaf — see the note
// there.)

@ffi.Native<ffi.Int32 Function()>(isLeaf: true)
external int camera_pro_core_version();

@ffi.Native<ffi.Pointer<ffi.Char> Function()>(isLeaf: true)
external ffi.Pointer<ffi.Char> camera_pro_core_version_string();

@ffi.Native<ffi.Int32 Function()>(isLeaf: true)
external int camera_pro_simd_level();

@ffi.Native<ffi.Pointer<ffi.Char> Function()>(isLeaf: true)
external ffi.Pointer<ffi.Char> camera_pro_simd_name();

@ffi.Native<ffi.Pointer<ffi.Char> Function(ffi.Int32)>(isLeaf: true)
external ffi.Pointer<ffi.Char> camera_pro_error_string(int error);

// ── Buffer pool ────────────────────────────────────────────────────────────
//
// acquire/release/available/capacity are O(1) lock-free atomics on the hot
// per-frame path → `isLeaf: true`. create/destroy allocate/free (not O(1), not
// hot) so they stay non-leaf.

@ffi.Native<ffi.Pointer<CameraProBufferPool> Function(ffi.Int32, ffi.Int32)>()
external ffi.Pointer<CameraProBufferPool> camera_pro_buffer_pool_create(
  int bufferSize,
  int bufferCount,
);

@ffi.Native<
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<CameraProBufferPool>,
      ffi.Pointer<ffi.Int32>,
    )>(isLeaf: true)
external ffi.Pointer<ffi.Uint8> camera_pro_buffer_pool_acquire(
  ffi.Pointer<CameraProBufferPool> pool,
  ffi.Pointer<ffi.Int32> outSize,
);

@ffi.Native<
    ffi.Void Function(
      ffi.Pointer<CameraProBufferPool>,
      ffi.Pointer<ffi.Uint8>,
    )>(isLeaf: true)
external void camera_pro_buffer_pool_release(
  ffi.Pointer<CameraProBufferPool> pool,
  ffi.Pointer<ffi.Uint8> buffer,
);

@ffi.Native<ffi.Int32 Function(ffi.Pointer<CameraProBufferPool>)>(isLeaf: true)
external int camera_pro_buffer_pool_available(
  ffi.Pointer<CameraProBufferPool> pool,
);

@ffi.Native<ffi.Int32 Function(ffi.Pointer<CameraProBufferPool>)>(isLeaf: true)
external int camera_pro_buffer_pool_capacity(
  ffi.Pointer<CameraProBufferPool> pool,
);

@ffi.Native<ffi.Void Function(ffi.Pointer<CameraProBufferPool>)>()
external void camera_pro_buffer_pool_destroy(
  ffi.Pointer<CameraProBufferPool> pool,
);

// ── Compute kernels ──────────────────────────────────────────────────────────
//
// Deliberately NOT `isLeaf`. Each iterates a full frame — measured at
// ~0.7 ms (YUV) up to ~34 ms (focus peaking) per 1080p frame — and a leaf call
// keeps the thread out of the native state, so the isolate can't reach a GC
// safepoint for the whole call. Blocking GC for milliseconds risks jank, and
// the ~tens-of-ns transition a leaf call would save is noise next to a
// millisecond kernel. (`camera_pro_write_dng` also does blocking file I/O, so
// it must never be leaf.) The real lever for these is the GPU/isolate path.

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
  int isBgra,
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
  int isBgra,
  double threshold,
  int frameCounter,
);

@ffi.Native<
    ffi.Int32 Function(
      ffi.Pointer<ffi.Uint8>,
      ffi.Int32,
      ffi.Int32,
      ffi.Int32,
      ffi.Int32,
      ffi.Pointer<ffi.Uint32>,
      ffi.Int32,
    )>()
external int camera_pro_compute_luma_waveform(
  ffi.Pointer<ffi.Uint8> rgba,
  int width,
  int height,
  int stride,
  int isBgra,
  ffi.Pointer<ffi.Uint32> out,
  int columns,
);

@ffi.Native<
    ffi.Int32 Function(
      ffi.Pointer<ffi.Uint8>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Int32,
      ffi.Int32,
      ffi.Int32,
      ffi.Int32,
    )>()
external int camera_pro_compute_false_color(
  ffi.Pointer<ffi.Uint8> rgba,
  ffi.Pointer<ffi.Uint8> outRgba,
  int width,
  int height,
  int stride,
  int isBgra,
);

// ── Digital manual-control adjustments ──────────────────────────────────────

@ffi.Native<
    ffi.Int32 Function(
      ffi.Pointer<ffi.Uint8>,
      ffi.Int32,
      ffi.Int32,
      ffi.Int32,
      ffi.Int32,
      ffi.Float,
      ffi.Float,
      ffi.Float,
      ffi.Float,
    )>()
external int camera_pro_adjust_pixels(
  ffi.Pointer<ffi.Uint8> px,
  int width,
  int height,
  int stride,
  int isBgra,
  double gain,
  double bias,
  double temp,
  double contrast,
);

@ffi.Native<
    ffi.Int32 Function(
      ffi.Pointer<ffi.Uint8>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Int32,
      ffi.Int32,
      ffi.Int32,
      ffi.Float,
    )>()
external int camera_pro_digital_zoom(
  ffi.Pointer<ffi.Uint8> inPx,
  ffi.Pointer<ffi.Uint8> outPx,
  int width,
  int height,
  int stride,
  double factor,
);

@ffi.Native<
    ffi.Int32 Function(
      ffi.Pointer<ffi.Uint8>,
      ffi.Int32,
      ffi.Int32,
      ffi.Int32,
      ffi.Int32,
    )>()
external int camera_pro_box_blur(
  ffi.Pointer<ffi.Uint8> px,
  int width,
  int height,
  int stride,
  int radius,
);

// HDR exposure fusion — O(n*w*h) work, so NOT a leaf call.
@ffi.Native<
    ffi.Int32 Function(
      ffi.Pointer<ffi.Uint8>,
      ffi.Int32,
      ffi.Int32,
      ffi.Int32,
      ffi.Int32,
      ffi.Int32,
      ffi.Pointer<ffi.Uint8>,
    )>()
external int camera_pro_exposure_fusion(
  ffi.Pointer<ffi.Uint8> frames,
  int n,
  int width,
  int height,
  int stride,
  int isBgra,
  ffi.Pointer<ffi.Uint8> out,
);

// Single-capture local tone mapping (synthesize stack from one frame, fuse).
@ffi.Native<
    ffi.Int32 Function(
      ffi.Pointer<ffi.Uint8>,
      ffi.Int32,
      ffi.Int32,
      ffi.Int32,
      ffi.Int32,
      ffi.Pointer<ffi.Float>,
      ffi.Int32,
      ffi.Pointer<ffi.Uint8>,
    )>()
external int camera_pro_local_tonemap(
  ffi.Pointer<ffi.Uint8> frame,
  int width,
  int height,
  int stride,
  int isBgra,
  ffi.Pointer<ffi.Float> evs,
  int nEv,
  ffi.Pointer<ffi.Uint8> out,
);

// ── Linear-DNG (RAW) writer ─────────────────────────────────────────────────

@ffi.Native<
    ffi.Int32 Function(
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Int32,
      ffi.Int32,
      ffi.Int32,
      ffi.Int32,
      ffi.Int32,
      ffi.Int64,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
    )>()
external int camera_pro_write_dng(
  ffi.Pointer<ffi.Char> path,
  ffi.Pointer<ffi.Uint8> px,
  int width,
  int height,
  int stride,
  int isBgra,
  int iso,
  int exposureNs,
  ffi.Pointer<ffi.Char> make,
  ffi.Pointer<ffi.Char> model,
  ffi.Pointer<ffi.Char> datetime,
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
