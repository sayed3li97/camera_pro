/*
 * camera_pro_types.h — Shared types and enums for the camera_pro native core.
 *
 * This header is part of the FFI boundary. Everything here must be plain C,
 * ABI-stable, and free of platform-specific includes so that it can be parsed
 * by ffigen and implemented by every platform HAL.
 *
 * Copyright (c) 2026 camera_pro contributors. BSD-3-Clause.
 */
#ifndef CAMERA_PRO_TYPES_H
#define CAMERA_PRO_TYPES_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Visibility / export macro so the FFI symbols survive stripping and LTO. */
#if defined(_WIN32)
#  define CAMERA_PRO_EXPORT __declspec(dllexport)
#else
#  define CAMERA_PRO_EXPORT __attribute__((visibility("default")))
#endif

/* ─────────────────────────────────────────────────────────────────────────
 * Error codes — mirrored by camera_error_t in the HAL and by CameraProError
 * on the Dart side. Values are stable; append only.
 * ───────────────────────────────────────────────────────────────────────── */
typedef enum {
    CAMERA_OK = 0,
    CAMERA_ERROR_NOT_INITIALIZED,
    CAMERA_ERROR_ALREADY_INITIALIZED,
    CAMERA_ERROR_DEVICE_NOT_FOUND,
    CAMERA_ERROR_DEVICE_IN_USE,
    CAMERA_ERROR_DEVICE_DISCONNECTED,
    CAMERA_ERROR_PERMISSION_DENIED,
    CAMERA_ERROR_CONFIGURATION_FAILED,
    CAMERA_ERROR_CAPTURE_FAILED,
    CAMERA_ERROR_FEATURE_NOT_SUPPORTED,
    CAMERA_ERROR_INVALID_PARAMETER,
    CAMERA_ERROR_SESSION_INTERRUPTED,
    CAMERA_ERROR_THERMAL_THROTTLE,
    CAMERA_ERROR_MEMORY_PRESSURE,
    CAMERA_ERROR_SERVICE_FATAL,
    CAMERA_ERROR_TIMEOUT,
    CAMERA_ERROR_OUT_OF_MEMORY,
    CAMERA_ERROR_UNKNOWN,
} camera_error_t;

/* ─────────────────────────────────────────────────────────────────────────
 * Pixel formats understood by the shared core's converters and processors.
 * ───────────────────────────────────────────────────────────────────────── */
typedef enum {
    CAMERA_PIXEL_FORMAT_UNKNOWN = 0,
    CAMERA_PIXEL_FORMAT_RGBA8888,   /* 4 bytes/px, R,G,B,A                    */
    CAMERA_PIXEL_FORMAT_BGRA8888,   /* 4 bytes/px, B,G,R,A                    */
    CAMERA_PIXEL_FORMAT_YUV420P,    /* planar Y, U, V (I420)                  */
    CAMERA_PIXEL_FORMAT_NV12,       /* Y plane + interleaved UV               */
    CAMERA_PIXEL_FORMAT_NV21,       /* Y plane + interleaved VU               */
    CAMERA_PIXEL_FORMAT_GRAY8,      /* single luminance plane                 */
} camera_pixel_format_t;

/* Camera lifecycle state — mirrored by CameraState on the Dart side. */
typedef enum {
    CAMERA_STATE_UNINITIALIZED = 0,
    CAMERA_STATE_OPENED,
    CAMERA_STATE_PREVIEWING,
    CAMERA_STATE_CAPTURING,
    CAMERA_STATE_RECORDING,
    CAMERA_STATE_RECORDING_PAUSED,
    CAMERA_STATE_INTERRUPTED,
    CAMERA_STATE_ERROR,
    CAMERA_STATE_FATAL,
    CAMERA_STATE_DISPOSED,
} camera_state_t;

/* Which SIMD kernel the core selected at compile time / runtime. */
typedef enum {
    CAMERA_SIMD_SCALAR = 0,
    CAMERA_SIMD_NEON,
    CAMERA_SIMD_SSE2,
    CAMERA_SIMD_AVX2,
} camera_simd_level_t;

#ifdef __cplusplus
}
#endif
#endif /* CAMERA_PRO_TYPES_H */
