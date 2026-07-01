/*
 * camera_hal_stub.c — Conformant no-op HAL backend.
 *
 * Implements the entire camera_hal.h surface with sane, side-effect-free
 * behaviour. It exists for two reasons:
 *   1. It proves the HAL header is a complete, implementable C contract (it
 *      compiles as part of the CI/unit build on every platform).
 *   2. It is the backend used on platforms whose native HAL is not yet wired,
 *      so the Dart layer degrades to CameraTier.basic instead of crashing.
 *
 * Real backends (Android NDK Camera2, Apple AVFoundation, Windows Media
 * Foundation, Linux V4L2) live in sibling directories and replace this at link
 * time. See src/platform/<platform>/README.md for status.
 *
 * Copyright (c) 2026 camera_pro contributors. BSD-3-Clause.
 */
#include "../../hal/camera_hal.h"

#include <stdlib.h>
#include <string.h>

struct camera_context {
    camera_state_t          state;
    int32_t                 device_index;
    camera_error_callback_t error_cb;
    void*                   error_ud;
    camera_state_callback_t state_cb;
    void*                   state_ud;
};

static void set_state(camera_context_t* ctx, camera_state_t s) {
    ctx->state = s;
    if (ctx->state_cb) ctx->state_cb(ctx->state_ud, (int32_t)s);
}

camera_error_t camera_hal_create(camera_context_t** ctx) {
    if (!ctx) return CAMERA_ERROR_INVALID_PARAMETER;
    camera_context_t* c = (camera_context_t*)calloc(1, sizeof(camera_context_t));
    if (!c) return CAMERA_ERROR_OUT_OF_MEMORY;
    c->state = CAMERA_STATE_UNINITIALIZED;
    c->device_index = -1;
    *ctx = c;
    return CAMERA_OK;
}

camera_error_t camera_hal_destroy(camera_context_t* ctx) {
    if (!ctx) return CAMERA_ERROR_INVALID_PARAMETER;
    free(ctx);
    return CAMERA_OK;
}

camera_error_t camera_hal_enumerate_devices(camera_context_t* ctx, int32_t* count) {
    (void)ctx;
    if (count) *count = 0;   /* stub exposes no devices */
    return CAMERA_OK;
}

camera_error_t camera_hal_open(camera_context_t* ctx, int32_t device_index, int64_t texture_id) {
    (void)texture_id;
    if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;
    ctx->device_index = device_index;
    set_state(ctx, CAMERA_STATE_OPENED);
    return CAMERA_OK;
}

camera_error_t camera_hal_close(camera_context_t* ctx) {
    if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;
    set_state(ctx, CAMERA_STATE_DISPOSED);
    return CAMERA_OK;
}

camera_error_t camera_hal_get_capabilities(camera_context_t* ctx, camera_capabilities_t* caps) {
    if (!ctx || !caps) return CAMERA_ERROR_INVALID_PARAMETER;
    memset(caps, 0, sizeof(*caps));
    caps->platform_name  = "stub";
    caps->device_name    = "No camera (stub backend)";
    caps->hardware_level = -1;
    return CAMERA_OK;
}

/* Everything below is a well-behaved no-op that reports the feature as absent
 * rather than pretending to succeed on hardware that isn't there. */
#define STUB_OK(name, ...) \
    camera_error_t name(__VA_ARGS__) { return CAMERA_ERROR_FEATURE_NOT_SUPPORTED; }

camera_error_t camera_hal_start_preview(camera_context_t* ctx) {
    if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;
    set_state(ctx, CAMERA_STATE_PREVIEWING);
    return CAMERA_OK;
}
camera_error_t camera_hal_stop_preview(camera_context_t* ctx) {
    if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;
    set_state(ctx, CAMERA_STATE_OPENED);
    return CAMERA_OK;
}
camera_error_t camera_hal_set_preview_resolution(camera_context_t* ctx, int32_t w, int32_t h) {
    (void)ctx; (void)w; (void)h; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

camera_error_t camera_hal_set_exposure_mode(camera_context_t* ctx, int32_t m) { (void)ctx; (void)m; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED; }
camera_error_t camera_hal_set_shutter_speed_ns(camera_context_t* ctx, int64_t d) { (void)ctx; (void)d; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED; }
camera_error_t camera_hal_set_iso(camera_context_t* ctx, int32_t i) { (void)ctx; (void)i; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED; }
camera_error_t camera_hal_set_exposure_compensation(camera_context_t* ctx, float ev) { (void)ctx; (void)ev; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED; }
camera_error_t camera_hal_lock_exposure(camera_context_t* ctx) { (void)ctx; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED; }
camera_error_t camera_hal_unlock_exposure(camera_context_t* ctx) { (void)ctx; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED; }
camera_error_t camera_hal_set_metering_mode(camera_context_t* ctx, int32_t m) { (void)ctx; (void)m; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED; }
camera_error_t camera_hal_set_metering_point(camera_context_t* ctx, float x, float y) { (void)ctx; (void)x; (void)y; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED; }

camera_error_t camera_hal_set_focus_mode(camera_context_t* ctx, int32_t m) { (void)ctx; (void)m; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED; }
camera_error_t camera_hal_set_focus_distance(camera_context_t* ctx, float d) { (void)ctx; (void)d; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED; }
camera_error_t camera_hal_set_focus_point(camera_context_t* ctx, float x, float y) { (void)ctx; (void)x; (void)y; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED; }
camera_error_t camera_hal_lock_focus(camera_context_t* ctx) { (void)ctx; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED; }
camera_error_t camera_hal_unlock_focus(camera_context_t* ctx) { (void)ctx; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED; }

camera_error_t camera_hal_set_wb_mode(camera_context_t* ctx, int32_t m) { (void)ctx; (void)m; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED; }
camera_error_t camera_hal_set_wb_temperature(camera_context_t* ctx, int32_t k) { (void)ctx; (void)k; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED; }
camera_error_t camera_hal_set_wb_tint(camera_context_t* ctx, float gm, float ba) { (void)ctx; (void)gm; (void)ba; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED; }
camera_error_t camera_hal_lock_white_balance(camera_context_t* ctx) { (void)ctx; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED; }

camera_error_t camera_hal_set_flash_mode(camera_context_t* ctx, int32_t m) { (void)ctx; (void)m; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED; }
camera_error_t camera_hal_set_torch(camera_context_t* ctx, bool e, float i) { (void)ctx; (void)e; (void)i; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED; }

camera_error_t camera_hal_set_zoom(camera_context_t* ctx, float f) { (void)ctx; (void)f; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED; }

camera_error_t camera_hal_capture_photo(camera_context_t* ctx, int32_t fmt, const char* path) { (void)ctx; (void)fmt; (void)path; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED; }
camera_error_t camera_hal_start_burst(camera_context_t* ctx, int32_t fmt, int32_t n) { (void)ctx; (void)fmt; (void)n; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED; }
camera_error_t camera_hal_stop_burst(camera_context_t* ctx) { (void)ctx; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED; }
camera_error_t camera_hal_capture_bracket(camera_context_t* ctx, const float* ev, int32_t n, int32_t fmt) { (void)ctx; (void)ev; (void)n; (void)fmt; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED; }

camera_error_t camera_hal_set_video_config(camera_context_t* ctx, int32_t w, int32_t h, int32_t fps, int32_t codec, int64_t br, int32_t stab, int32_t cp) {
    (void)ctx; (void)w; (void)h; (void)fps; (void)codec; (void)br; (void)stab; (void)cp; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}
camera_error_t camera_hal_start_recording(camera_context_t* ctx, const char* path) { (void)ctx; (void)path; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED; }
camera_error_t camera_hal_pause_recording(camera_context_t* ctx) { (void)ctx; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED; }
camera_error_t camera_hal_resume_recording(camera_context_t* ctx) { (void)ctx; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED; }
camera_error_t camera_hal_stop_recording(camera_context_t* ctx) { (void)ctx; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED; }

camera_error_t camera_hal_set_audio_enabled(camera_context_t* ctx, bool e) { (void)ctx; (void)e; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED; }
camera_error_t camera_hal_set_audio_gain(camera_context_t* ctx, float g) { (void)ctx; (void)g; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED; }

camera_error_t camera_hal_start_image_stream(camera_context_t* ctx, int32_t w, int32_t h, int32_t fps, camera_frame_callback_t cb, void* ud) {
    (void)ctx; (void)w; (void)h; (void)fps; (void)cb; (void)ud; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}
camera_error_t camera_hal_stop_image_stream(camera_context_t* ctx) { (void)ctx; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED; }

camera_error_t camera_hal_set_error_callback(camera_context_t* ctx, camera_error_callback_t cb, void* ud) {
    if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;
    ctx->error_cb = cb; ctx->error_ud = ud; return CAMERA_OK;
}
camera_error_t camera_hal_set_state_callback(camera_context_t* ctx, camera_state_callback_t cb, void* ud) {
    if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;
    ctx->state_cb = cb; ctx->state_ud = ud; return CAMERA_OK;
}
