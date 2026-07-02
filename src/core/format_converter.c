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

#if defined(__ARM_NEON) || defined(__ARM_NEON__)
#  include <arm_neon.h>
#  define CP_YUV_NEON 1
#endif

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

#if CP_YUV_NEON
/* Converts 8 pixels with the exact integer math of yuv_to_rgb (bit-exact:
 * same products, same +128 rounding, same arithmetic >>8, same clamping). */
static inline void yuv8_to_rgba_neon(
    const uint8_t* yp, const uint8_t* up, const uint8_t* vp, uint8_t* out) {
    /* c = max(y-16, 0); d = u-128; e = v-128 (u/v duplicated per pair). */
    int16x8_t c = vreinterpretq_s16_u16(vmovl_u8(vld1_u8(yp)));
    c = vmaxq_s16(vsubq_s16(c, vdupq_n_s16(16)), vdupq_n_s16(0));

    uint8x8_t u4 = vld1_u8(up);       /* only first 4 lanes used */
    uint8x8_t v4 = vld1_u8(vp);
    /* duplicate each chroma sample for its 2 luma pixels */
    uint8x8x2_t uz = vzip_u8(u4, u4);
    uint8x8x2_t vz = vzip_u8(v4, v4);
    int16x8_t d = vsubq_s16(vreinterpretq_s16_u16(vmovl_u8(uz.val[0])),
                            vdupq_n_s16(128));
    int16x8_t e = vsubq_s16(vreinterpretq_s16_u16(vmovl_u8(vz.val[0])),
                            vdupq_n_s16(128));

    #define CP_HALF(comp, lo_or_hi) \
        int32x4_t comp##_##lo_or_hi
    /* 298c (+128) as the common base, in 32-bit. */
    int32x4_t base_lo = vmull_n_s16(vget_low_s16(c), 298);
    int32x4_t base_hi = vmull_n_s16(vget_high_s16(c), 298);
    base_lo = vaddq_s32(base_lo, vdupq_n_s32(128));
    base_hi = vaddq_s32(base_hi, vdupq_n_s32(128));

    int32x4_t r_lo = vmlal_n_s16(base_lo, vget_low_s16(e), 409);
    int32x4_t r_hi = vmlal_n_s16(base_hi, vget_high_s16(e), 409);
    int32x4_t g_lo = vmlal_n_s16(vmlal_n_s16(base_lo, vget_low_s16(d), -100),
                                 vget_low_s16(e), -208);
    int32x4_t g_hi = vmlal_n_s16(vmlal_n_s16(base_hi, vget_high_s16(d), -100),
                                 vget_high_s16(e), -208);
    int32x4_t b_lo = vmlal_n_s16(base_lo, vget_low_s16(d), 516);
    int32x4_t b_hi = vmlal_n_s16(base_hi, vget_high_s16(d), 516);
    #undef CP_HALF

    /* >>8 arithmetic, saturate i32→u16→u8 (same as scalar clamp_u8). */
    #define CP_NARROW(lo, hi) \
        vqmovn_u16(vcombine_u16(vqmovun_s32(vshrq_n_s32(lo, 8)), \
                                vqmovun_s32(vshrq_n_s32(hi, 8))))
    uint8x8x4_t px;
    px.val[0] = CP_NARROW(r_lo, r_hi);
    px.val[1] = CP_NARROW(g_lo, g_hi);
    px.val[2] = CP_NARROW(b_lo, b_hi);
    px.val[3] = vdup_n_u8(255);
    #undef CP_NARROW
    vst4_u8(out, px);
}
#endif /* CP_YUV_NEON */

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
        int32_t i = 0;
#if CP_YUV_NEON
        /* NEON fast path: 8 luma pixels / 4 chroma samples per iteration.
         * The chroma loads read 8 bytes, so stop while 8 are in-bounds. */
        for (; i + 8 <= width && (i / 2) + 8 <= uv_stride; i += 8) {
            yuv8_to_rgba_neon(yr + i, ur + i / 2, vr + i / 2, out + (size_t)i * 4);
        }
#endif
        for (; i < width; i++) {
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
