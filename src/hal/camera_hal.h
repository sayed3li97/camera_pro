/*
 * camera_hal.h — Platform Abstraction Layer.
 *
 * Every platform backend (Android NDK Camera2, Apple AVFoundation, Windows
 * Media Foundation, Linux V4L2) implements this single C interface. The shared
 * core and the Dart FFI layer talk only to these functions, never to platform
 * APIs directly. A conformant no-op implementation lives in
 * src/platform/stub/camera_hal_stub.c and is what the unit build links against.
 *
 * Copyright (c) 2026 camera_pro contributors. BSD-3-Clause.
 */
#ifndef CAMERA_PRO_HAL_H
#define CAMERA_PRO_HAL_H

#include "../core/camera_pro_types.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque per-session handle owned by the platform backend. */
typedef struct camera_context camera_context_t;

/* ── Capability structures ─────────────────────────────────────────────── */

typedef struct { bool supported; int64_t min_ns;   int64_t max_ns;   } camera_shutter_capability_t;
typedef struct { bool supported; int32_t min_iso;  int32_t max_iso;  } camera_iso_capability_t;
typedef struct { bool supported; float   min_diopters; float max_diopters; } camera_focus_capability_t;
typedef struct { bool supported; int32_t min_kelvin; int32_t max_kelvin; } camera_wb_capability_t;
typedef struct { bool supported; float min_ev; float max_ev; float step_ev; } camera_ev_capability_t;

typedef struct {
    float    min_zoom;
    float    max_zoom;
    int32_t  optical_levels_count;
    const float* optical_levels;   /* borrowed; owned by the context */
} camera_zoom_capability_t;

typedef struct {
    bool has_flash;
    bool has_torch;
    bool has_torch_intensity;
} camera_flash_capability_t;

typedef struct {
    bool    supports_raw;
    bool    supports_pro_raw;
    bool    supports_heif;
    bool    supports_burst;
    int32_t max_burst_count;
    bool    supports_hdr;
    bool    supports_bracketing;
    bool    supports_depth;
    bool    supports_lidar;
    bool    supports_multi_camera;
    bool    supports_face_detection;
    bool    supports_ois;
    bool    has_manual_audio_gain;
} camera_advanced_capabilities_t;

typedef struct {
    int32_t        num_resolutions;
    const int32_t* resolutions;    /* [w0,h0, w1,h1, ...] */
    int32_t        num_frame_rates;
    const int32_t* frame_rates;
    bool           supports_hevc;
    bool           supports_prores;
    bool           supports_av1;
    int64_t        max_bitrate;
    bool           supports_hdr_video;
    bool           supports_slow_motion;
} camera_video_capabilities_t;

typedef struct {
    camera_shutter_capability_t    shutter;
    camera_iso_capability_t        iso;
    camera_focus_capability_t      focus;
    camera_wb_capability_t         white_balance;
    camera_ev_capability_t         exposure_compensation;
    camera_zoom_capability_t       zoom;
    camera_flash_capability_t      flash;
    camera_advanced_capabilities_t advanced;
    camera_video_capabilities_t    video;
    const char*                    platform_name;
    const char*                    device_name;
    int32_t                        hardware_level;
} camera_capabilities_t;

/* ── Callbacks (native → Dart via NativeCallable) ──────────────────────── */

typedef void (*camera_frame_callback_t)(
    void* user_data, uint8_t* buffer, int32_t size,
    int32_t width, int32_t height, int32_t format, int64_t timestamp_ns);

typedef void (*camera_error_callback_t)(
    void* user_data, camera_error_t error, const char* message);

typedef void (*camera_state_callback_t)(
    void* user_data, int32_t state);

/* ── Lifecycle ─────────────────────────────────────────────────────────── */
CAMERA_PRO_EXPORT camera_error_t camera_hal_create(camera_context_t** ctx);
CAMERA_PRO_EXPORT camera_error_t camera_hal_destroy(camera_context_t* ctx);
CAMERA_PRO_EXPORT camera_error_t camera_hal_enumerate_devices(camera_context_t* ctx, int32_t* count);
CAMERA_PRO_EXPORT camera_error_t camera_hal_open(camera_context_t* ctx, int32_t device_index, int64_t flutter_texture_id);
CAMERA_PRO_EXPORT camera_error_t camera_hal_close(camera_context_t* ctx);
CAMERA_PRO_EXPORT camera_error_t camera_hal_get_capabilities(camera_context_t* ctx, camera_capabilities_t* caps);

/* ── Preview ───────────────────────────────────────────────────────────── */
CAMERA_PRO_EXPORT camera_error_t camera_hal_start_preview(camera_context_t* ctx);
CAMERA_PRO_EXPORT camera_error_t camera_hal_stop_preview(camera_context_t* ctx);
CAMERA_PRO_EXPORT camera_error_t camera_hal_set_preview_resolution(camera_context_t* ctx, int32_t width, int32_t height);

/* ── Exposure ──────────────────────────────────────────────────────────── */
CAMERA_PRO_EXPORT camera_error_t camera_hal_set_exposure_mode(camera_context_t* ctx, int32_t mode);
CAMERA_PRO_EXPORT camera_error_t camera_hal_set_shutter_speed_ns(camera_context_t* ctx, int64_t duration_ns);
CAMERA_PRO_EXPORT camera_error_t camera_hal_set_iso(camera_context_t* ctx, int32_t iso);
CAMERA_PRO_EXPORT camera_error_t camera_hal_set_exposure_compensation(camera_context_t* ctx, float ev);
CAMERA_PRO_EXPORT camera_error_t camera_hal_lock_exposure(camera_context_t* ctx);
CAMERA_PRO_EXPORT camera_error_t camera_hal_unlock_exposure(camera_context_t* ctx);
CAMERA_PRO_EXPORT camera_error_t camera_hal_set_metering_mode(camera_context_t* ctx, int32_t mode);
CAMERA_PRO_EXPORT camera_error_t camera_hal_set_metering_point(camera_context_t* ctx, float x, float y);

/* ── Focus ─────────────────────────────────────────────────────────────── */
CAMERA_PRO_EXPORT camera_error_t camera_hal_set_focus_mode(camera_context_t* ctx, int32_t mode);
CAMERA_PRO_EXPORT camera_error_t camera_hal_set_focus_distance(camera_context_t* ctx, float diopters);
CAMERA_PRO_EXPORT camera_error_t camera_hal_set_focus_point(camera_context_t* ctx, float x, float y);
CAMERA_PRO_EXPORT camera_error_t camera_hal_lock_focus(camera_context_t* ctx);
CAMERA_PRO_EXPORT camera_error_t camera_hal_unlock_focus(camera_context_t* ctx);

/* ── White balance ─────────────────────────────────────────────────────── */
CAMERA_PRO_EXPORT camera_error_t camera_hal_set_wb_mode(camera_context_t* ctx, int32_t mode);
CAMERA_PRO_EXPORT camera_error_t camera_hal_set_wb_temperature(camera_context_t* ctx, int32_t kelvin);
CAMERA_PRO_EXPORT camera_error_t camera_hal_set_wb_tint(camera_context_t* ctx, float green_magenta, float blue_amber);
CAMERA_PRO_EXPORT camera_error_t camera_hal_lock_white_balance(camera_context_t* ctx);

/* ── Flash / torch ─────────────────────────────────────────────────────── */
CAMERA_PRO_EXPORT camera_error_t camera_hal_set_flash_mode(camera_context_t* ctx, int32_t mode);
CAMERA_PRO_EXPORT camera_error_t camera_hal_set_torch(camera_context_t* ctx, bool enabled, float intensity);

/* ── Zoom ──────────────────────────────────────────────────────────────── */
CAMERA_PRO_EXPORT camera_error_t camera_hal_set_zoom(camera_context_t* ctx, float factor);

/* ── Photo capture ─────────────────────────────────────────────────────── */
CAMERA_PRO_EXPORT camera_error_t camera_hal_capture_photo(camera_context_t* ctx, int32_t format, const char* path);
CAMERA_PRO_EXPORT camera_error_t camera_hal_start_burst(camera_context_t* ctx, int32_t format, int32_t max_count);
CAMERA_PRO_EXPORT camera_error_t camera_hal_stop_burst(camera_context_t* ctx);
CAMERA_PRO_EXPORT camera_error_t camera_hal_capture_bracket(camera_context_t* ctx, const float* ev_values, int32_t count, int32_t format);

/* ── Video ─────────────────────────────────────────────────────────────── */
CAMERA_PRO_EXPORT camera_error_t camera_hal_set_video_config(camera_context_t* ctx, int32_t width, int32_t height, int32_t fps, int32_t codec, int64_t bitrate, int32_t stabilization, int32_t color_profile);
CAMERA_PRO_EXPORT camera_error_t camera_hal_start_recording(camera_context_t* ctx, const char* path);
CAMERA_PRO_EXPORT camera_error_t camera_hal_pause_recording(camera_context_t* ctx);
CAMERA_PRO_EXPORT camera_error_t camera_hal_resume_recording(camera_context_t* ctx);
CAMERA_PRO_EXPORT camera_error_t camera_hal_stop_recording(camera_context_t* ctx);

/* ── Audio ─────────────────────────────────────────────────────────────── */
CAMERA_PRO_EXPORT camera_error_t camera_hal_set_audio_enabled(camera_context_t* ctx, bool enabled);
CAMERA_PRO_EXPORT camera_error_t camera_hal_set_audio_gain(camera_context_t* ctx, float gain);

/* ── Image stream (for frame processors) ───────────────────────────────── */
CAMERA_PRO_EXPORT camera_error_t camera_hal_start_image_stream(camera_context_t* ctx, int32_t width, int32_t height, int32_t max_fps, camera_frame_callback_t callback, void* user_data);
CAMERA_PRO_EXPORT camera_error_t camera_hal_stop_image_stream(camera_context_t* ctx);

/* ── Callback registration ─────────────────────────────────────────────── */
CAMERA_PRO_EXPORT camera_error_t camera_hal_set_error_callback(camera_context_t* ctx, camera_error_callback_t callback, void* user_data);
CAMERA_PRO_EXPORT camera_error_t camera_hal_set_state_callback(camera_context_t* ctx, camera_state_callback_t callback, void* user_data);

#ifdef __cplusplus
}
#endif
#endif /* CAMERA_PRO_HAL_H */
