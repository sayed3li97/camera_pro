/*
 * camera_hal_apple.h — FFI-friendly accessors for the Apple (AVFoundation) HAL.
 *
 * The full HAL implements src/hal/camera_hal.h. These extra flat accessors let
 * the Dart AppleCameraBackend read enumeration + capabilities without mirroring
 * the large nested camera_capabilities_t struct across FFI.
 *
 * Copyright (c) 2026 camera_pro contributors. BSD-3-Clause.
 */
#ifndef CAMERA_PRO_HAL_APPLE_H
#define CAMERA_PRO_HAL_APPLE_H

#include "../../core/camera_pro_types.h"
#include "../../hal/camera_hal.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Flat, pointer-free capability snapshot — trivial to mirror as a Dart
 * ffi.Struct. Field order MUST match lib/src/ffi/hal_bindings.dart. */
typedef struct {
    int32_t device_count;

    int32_t iso_supported;
    int32_t iso_min;
    int32_t iso_max;

    int32_t shutter_supported;
    int64_t shutter_min_ns;
    int64_t shutter_max_ns;

    int32_t focus_supported;

    int32_t ev_supported;
    float   ev_min;
    float   ev_max;

    int32_t zoom_supported;
    float   zoom_max;

    int32_t has_flash;
    int32_t has_torch;
} camera_pro_apple_caps_t;

/* Number of cameras discovered by the most recent enumerate call. */
CAMERA_PRO_EXPORT int32_t camera_pro_apple_device_count(camera_context_t* ctx);

/* Writes a UTF-8 device name for device `index` into `out` (bounded by cap).
 * Returns the number of bytes written (excluding the NUL). */
CAMERA_PRO_EXPORT int32_t camera_pro_apple_device_name(
    camera_context_t* ctx, int32_t index, char* out, int32_t cap);

/* Lens position for device `index`: 0 unspecified, 1 back, 2 front. */
CAMERA_PRO_EXPORT int32_t camera_pro_apple_device_position(
    camera_context_t* ctx, int32_t index);

/* Fills `out` with the resolved capabilities of the currently open device. */
CAMERA_PRO_EXPORT void camera_pro_apple_get_caps(
    camera_context_t* ctx, camera_pro_apple_caps_t* out);

/* Writes the platform name (e.g. "macOS, AVFoundation") of the open device. */
CAMERA_PRO_EXPORT int32_t camera_pro_apple_platform_name(
    camera_context_t* ctx, char* out, int32_t cap);

/* Writes the localized name of the currently open device. */
CAMERA_PRO_EXPORT int32_t camera_pro_apple_active_device_name(
    camera_context_t* ctx, char* out, int32_t cap);

/* Number of preview frames delivered so far (0 until permission is granted). */
CAMERA_PRO_EXPORT int64_t camera_pro_apple_frame_count(camera_context_t* ctx);

/* Copies the latest preview frame as tightly-packed BGRA into `out` (bounded by
 * cap). Writes width/height. Returns bytes copied, or 0 if none / too small. */
CAMERA_PRO_EXPORT int32_t camera_pro_apple_copy_latest_frame(
    camera_context_t* ctx, uint8_t* out, int32_t cap,
    int32_t* width, int32_t* height);

/* ── Metal GPU compute (metal_processor.m) ─────────────────────────────────
 * Runtime-compiled MSL kernels, bit-compatible with the C CPU kernels. Used
 * for runtime GPU/CPU dispatch selection. All return CAMERA_OK, or
 * CAMERA_ERROR_FEATURE_NOT_SUPPORTED when no Metal device exists.
 * ───────────────────────────────────────────────────────────────────────── */
CAMERA_PRO_EXPORT int32_t camera_pro_metal_available(void);
CAMERA_PRO_EXPORT const char* camera_pro_metal_device_name(void);

CAMERA_PRO_EXPORT int32_t camera_pro_metal_histogram(
    const uint8_t* rgba, int32_t width, int32_t height, int32_t is_bgra,
    uint32_t* luma_hist, uint32_t* r_hist, uint32_t* g_hist, uint32_t* b_hist);

CAMERA_PRO_EXPORT int32_t camera_pro_metal_focus_peaking(
    const uint8_t* in_px, uint8_t* out_px, int32_t width, int32_t height,
    int32_t is_bgra, float threshold, uint32_t peak_color);

CAMERA_PRO_EXPORT int32_t camera_pro_metal_zebra(
    const uint8_t* in_px, uint8_t* out_px, int32_t width, int32_t height,
    int32_t is_bgra, float threshold, int32_t frame_counter);

#ifdef __cplusplus
}
#endif
#endif /* CAMERA_PRO_HAL_APPLE_H */
