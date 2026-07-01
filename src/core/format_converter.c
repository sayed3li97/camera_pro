/*
 * format_converter.c — Scalar YUV → RGBA converters (BT.601, video range).
 *
 * These are self-contained reference converters with no external dependency on
 * libyuv, so the core builds and is testable everywhere. libyuv can be dropped
 * in later behind the same entry points for a SIMD speedup (see ROADMAP).
 *
 * Copyright (c) 2026 camera_pro contributors. BSD-3-Clause.
 */
#include "camera_pro_core.h"

#include <stddef.h>   /* size_t */

static inline uint8_t clamp_u8(int v) {
    if (v < 0)   return 0;
    if (v > 255) return 255;
    return (uint8_t)v;
}

/* BT.601 video-range YCbCr → RGB, integer fixed-point (16.16-ish, >>8). */
static inline void yuv_to_rgb(int Y, int U, int V, uint8_t* out) {
    int c = Y - 16;
    int d = U - 128;
    int e = V - 128;
    if (c < 0) c = 0;
    out[0] = clamp_u8((298 * c + 409 * e + 128) >> 8);           /* R */
    out[1] = clamp_u8((298 * c - 100 * d - 208 * e + 128) >> 8); /* G */
    out[2] = clamp_u8((298 * c + 516 * d + 128) >> 8);           /* B */
    out[3] = 255;                                                /* A */
}

int32_t camera_pro_yuv420p_to_rgba(
    const uint8_t* y, const uint8_t* u, const uint8_t* v,
    int32_t y_stride, int32_t uv_stride,
    uint8_t* rgba, int32_t width, int32_t height) {

    if (!y || !u || !v || !rgba || width <= 0 || height <= 0)
        return CAMERA_ERROR_INVALID_PARAMETER;
    if (y_stride <= 0)  y_stride  = width;
    if (uv_stride <= 0) uv_stride = (width + 1) / 2;

    for (int32_t j = 0; j < height; j++) {
        const uint8_t* yr = y + (size_t)j * y_stride;
        const uint8_t* ur = u + (size_t)(j / 2) * uv_stride;
        const uint8_t* vr = v + (size_t)(j / 2) * uv_stride;
        uint8_t* out = rgba + (size_t)j * width * 4;
        for (int32_t i = 0; i < width; i++) {
            yuv_to_rgb(yr[i], ur[i / 2], vr[i / 2], out + i * 4);
        }
    }
    return CAMERA_OK;
}

int32_t camera_pro_nv12_to_rgba(
    const uint8_t* y, const uint8_t* uv,
    int32_t y_stride, int32_t uv_stride,
    uint8_t* rgba, int32_t width, int32_t height) {

    if (!y || !uv || !rgba || width <= 0 || height <= 0)
        return CAMERA_ERROR_INVALID_PARAMETER;
    if (y_stride <= 0)  y_stride  = width;
    if (uv_stride <= 0) uv_stride = width;

    for (int32_t j = 0; j < height; j++) {
        const uint8_t* yr  = y  + (size_t)j * y_stride;
        const uint8_t* uvr = uv + (size_t)(j / 2) * uv_stride;
        uint8_t* out = rgba + (size_t)j * width * 4;
        for (int32_t i = 0; i < width; i++) {
            int uvi = (i / 2) * 2;
            yuv_to_rgb(yr[i], uvr[uvi], uvr[uvi + 1], out + i * 4);
        }
    }
    return CAMERA_OK;
}

int32_t camera_pro_nv21_to_rgba(
    const uint8_t* y, const uint8_t* vu,
    int32_t y_stride, int32_t uv_stride,
    uint8_t* rgba, int32_t width, int32_t height) {

    if (!y || !vu || !rgba || width <= 0 || height <= 0)
        return CAMERA_ERROR_INVALID_PARAMETER;
    if (y_stride <= 0)  y_stride  = width;
    if (uv_stride <= 0) uv_stride = width;

    for (int32_t j = 0; j < height; j++) {
        const uint8_t* yr  = y  + (size_t)j * y_stride;
        const uint8_t* vur = vu + (size_t)(j / 2) * uv_stride;
        uint8_t* out = rgba + (size_t)j * width * 4;
        for (int32_t i = 0; i < width; i++) {
            int vui = (i / 2) * 2;
            /* NV21 stores V first, then U. */
            yuv_to_rgb(yr[i], vur[vui + 1], vur[vui], out + i * 4);
        }
    }
    return CAMERA_OK;
}
