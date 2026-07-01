/*
 * camera_pro_core.h — Public C API exposed to Dart via FFI.
 *
 * This is the "fast path" boundary described in ARCHITECTURE.md. Every symbol
 * here is intended to be called directly from Dart (dart:ffi), with zero-copy
 * pointer passing for frame data. Keep it small, stable, and allocation-aware.
 *
 * Copyright (c) 2026 camera_pro contributors. BSD-3-Clause.
 */
#ifndef CAMERA_PRO_CORE_H
#define CAMERA_PRO_CORE_H

#include "camera_pro_types.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Encoded as (major << 16) | (minor << 8) | patch. */
#define CAMERA_PRO_CORE_VERSION_MAJOR 0
#define CAMERA_PRO_CORE_VERSION_MINOR 1
#define CAMERA_PRO_CORE_VERSION_PATCH 0

/* ── Version / build introspection ─────────────────────────────────────── */
CAMERA_PRO_EXPORT int32_t     camera_pro_core_version(void);
CAMERA_PRO_EXPORT const char* camera_pro_core_version_string(void);

/* Which SIMD kernel is active for image processing on this build. */
CAMERA_PRO_EXPORT int32_t     camera_pro_simd_level(void);   /* camera_simd_level_t */
CAMERA_PRO_EXPORT const char* camera_pro_simd_name(void);

/* Human-readable string for a camera_error_t value (never NULL). */
CAMERA_PRO_EXPORT const char* camera_pro_error_string(int32_t error);

/* ── Zero-allocation frame buffer pool ─────────────────────────────────────
 * A fixed set of cache-line-aligned buffers, handed out by pointer. Producers
 * acquire, consumers release. acquire() returns NULL when the pool is drained
 * (the caller should drop the frame rather than block). This keeps frame
 * delivery off the Dart GC entirely.
 * ───────────────────────────────────────────────────────────────────────── */
typedef struct camera_pro_buffer_pool camera_pro_buffer_pool_t;

CAMERA_PRO_EXPORT camera_pro_buffer_pool_t*
camera_pro_buffer_pool_create(int32_t buffer_size, int32_t buffer_count);

CAMERA_PRO_EXPORT uint8_t*
camera_pro_buffer_pool_acquire(camera_pro_buffer_pool_t* pool, int32_t* out_size);

CAMERA_PRO_EXPORT void
camera_pro_buffer_pool_release(camera_pro_buffer_pool_t* pool, uint8_t* buffer);

/* Number of buffers currently free (for diagnostics / backpressure). */
CAMERA_PRO_EXPORT int32_t
camera_pro_buffer_pool_available(camera_pro_buffer_pool_t* pool);

CAMERA_PRO_EXPORT int32_t
camera_pro_buffer_pool_capacity(camera_pro_buffer_pool_t* pool);

CAMERA_PRO_EXPORT void
camera_pro_buffer_pool_destroy(camera_pro_buffer_pool_t* pool);

/* ── Real-time histogram ───────────────────────────────────────────────────
 * Computes luminance + per-channel histograms (256 bins each) over an RGBA
 * frame. SIMD-accelerated where available; the scalar path is the reference
 * implementation. Each output pointer must point to at least 256 uint32_t.
 * ───────────────────────────────────────────────────────────────────────── */
CAMERA_PRO_EXPORT void
camera_pro_compute_histogram_rgba(
    const uint8_t* rgba,
    int32_t        width,
    int32_t        height,
    int32_t        stride,        /* bytes per row; 0 => width*4 */
    uint32_t*      luma_hist,     /* 256 bins */
    uint32_t*      r_hist,        /* 256 bins */
    uint32_t*      g_hist,        /* 256 bins */
    uint32_t*      b_hist);       /* 256 bins */

/* Force the scalar reference path (used by tests to validate SIMD kernels). */
CAMERA_PRO_EXPORT void
camera_pro_compute_histogram_rgba_scalar(
    const uint8_t* rgba, int32_t width, int32_t height, int32_t stride,
    uint32_t* luma_hist, uint32_t* r_hist, uint32_t* g_hist, uint32_t* b_hist);

/* ── Focus peaking (Sobel edge highlight) ─────────────────────────────────
 * Writes an RGBA copy of the input with high-frequency edges tinted by
 * peak_color (0xRRGGBBAA). Returns CAMERA_OK or an error code.
 * out_rgba may alias nothing (must be a distinct buffer of width*height*4).
 * ───────────────────────────────────────────────────────────────────────── */
CAMERA_PRO_EXPORT int32_t
camera_pro_compute_focus_peaking(
    const uint8_t* rgba,
    uint8_t*       out_rgba,
    int32_t        width,
    int32_t        height,
    int32_t        stride,
    float          threshold,     /* 0..1 edge magnitude threshold */
    uint32_t       peak_color);   /* 0xRRGGBBAA */

/* ── Zebra stripes (over-exposure overlay) ─────────────────────────────────
 * Tints pixels whose luminance exceeds `threshold` (0..1) with an animated
 * diagonal stripe pattern (phase advances with frame_counter).
 * ───────────────────────────────────────────────────────────────────────── */
CAMERA_PRO_EXPORT int32_t
camera_pro_compute_zebra(
    const uint8_t* rgba,
    uint8_t*       out_rgba,
    int32_t        width,
    int32_t        height,
    int32_t        stride,
    float          threshold,
    int32_t        frame_counter);

/* ── Format conversion (scalar BT.601) ─────────────────────────────────────
 * All converters write tightly-packed RGBA8888 (stride = width*4).
 * Return CAMERA_OK or an error code.
 * ───────────────────────────────────────────────────────────────────────── */
CAMERA_PRO_EXPORT int32_t
camera_pro_yuv420p_to_rgba(
    const uint8_t* y, const uint8_t* u, const uint8_t* v,
    int32_t y_stride, int32_t uv_stride,
    uint8_t* rgba, int32_t width, int32_t height);

CAMERA_PRO_EXPORT int32_t
camera_pro_nv12_to_rgba(
    const uint8_t* y, const uint8_t* uv,
    int32_t y_stride, int32_t uv_stride,
    uint8_t* rgba, int32_t width, int32_t height);

CAMERA_PRO_EXPORT int32_t
camera_pro_nv21_to_rgba(
    const uint8_t* y, const uint8_t* vu,
    int32_t y_stride, int32_t uv_stride,
    uint8_t* rgba, int32_t width, int32_t height);

#ifdef __cplusplus
}
#endif
#endif /* CAMERA_PRO_CORE_H */
