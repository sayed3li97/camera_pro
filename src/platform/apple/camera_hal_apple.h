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

#ifdef __cplusplus
}
#endif
#endif /* CAMERA_PRO_HAL_APPLE_H */
