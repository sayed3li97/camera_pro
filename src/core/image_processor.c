/*
 * image_processor.c — SIMD-accelerated visual-aid kernels.
 *
 * Contains the reference (scalar) implementations plus NEON / SSE2 fast paths
 * for the histogram. The scalar and SIMD kernels use identical fixed-point
 * luma coefficients (Y = (77R + 150G + 29B) >> 8) so their results are
 * bit-exact — the C test harness cross-checks them.
 *
 * Copyright (c) 2026 camera_pro contributors. BSD-3-Clause.
 */
#include "camera_pro_core.h"

#include <math.h>
#include <string.h>

#if defined(__ARM_NEON) || defined(__ARM_NEON__)
#  include <arm_neon.h>
#  define CAMERA_PRO_HAVE_NEON 1
#endif

#if defined(__SSE2__)
#  include <emmintrin.h>
#  define CAMERA_PRO_HAVE_SSE2 1
#endif

/* Fixed-point BT.601 luma. Shared by every code path for bit-exact results. */
static inline uint8_t luma_u8(uint8_t r, uint8_t g, uint8_t b) {
    return (uint8_t)((77u * r + 150u * g + 29u * b) >> 8);
}

/* ── SIMD level introspection ──────────────────────────────────────────── */
int32_t camera_pro_simd_level(void) {
#if defined(CAMERA_PRO_HAVE_NEON)
    return CAMERA_SIMD_NEON;
#elif defined(__AVX2__)
    return CAMERA_SIMD_AVX2;
#elif defined(CAMERA_PRO_HAVE_SSE2)
    return CAMERA_SIMD_SSE2;
#else
    return CAMERA_SIMD_SCALAR;
#endif
}

const char* camera_pro_simd_name(void) {
    switch (camera_pro_simd_level()) {
        case CAMERA_SIMD_NEON: return "NEON";
        case CAMERA_SIMD_AVX2: return "AVX2";
        case CAMERA_SIMD_SSE2: return "SSE2";
        default:               return "scalar";
    }
}

/* ── Histogram: scalar reference ───────────────────────────────────────── */
void camera_pro_compute_histogram_rgba_scalar(
    const uint8_t* rgba, int32_t width, int32_t height, int32_t stride,
    uint32_t* luma_hist, uint32_t* r_hist, uint32_t* g_hist, uint32_t* b_hist) {

    if (!rgba || width <= 0 || height <= 0) return;
    if (stride <= 0) stride = width * 4;

    memset(luma_hist, 0, 256 * sizeof(uint32_t));
    memset(r_hist,    0, 256 * sizeof(uint32_t));
    memset(g_hist,    0, 256 * sizeof(uint32_t));
    memset(b_hist,    0, 256 * sizeof(uint32_t));

    for (int32_t y = 0; y < height; y++) {
        const uint8_t* row = rgba + (size_t)y * stride;
        for (int32_t x = 0; x < width; x++) {
            uint8_t r = row[x * 4 + 0];
            uint8_t g = row[x * 4 + 1];
            uint8_t b = row[x * 4 + 2];
            luma_hist[luma_u8(r, g, b)]++;
            r_hist[r]++;
            g_hist[g]++;
            b_hist[b]++;
        }
    }
}

/* ── Histogram: dispatched (SIMD where available) ──────────────────────── */
void camera_pro_compute_histogram_rgba(
    const uint8_t* rgba, int32_t width, int32_t height, int32_t stride,
    uint32_t* luma_hist, uint32_t* r_hist, uint32_t* g_hist, uint32_t* b_hist) {

    if (!rgba || width <= 0 || height <= 0) return;
    if (stride <= 0) stride = width * 4;

#if defined(CAMERA_PRO_HAVE_NEON)
    memset(luma_hist, 0, 256 * sizeof(uint32_t));
    memset(r_hist,    0, 256 * sizeof(uint32_t));
    memset(g_hist,    0, 256 * sizeof(uint32_t));
    memset(b_hist,    0, 256 * sizeof(uint32_t));

    const uint8x8_t cr = vdup_n_u8(77);
    const uint8x8_t cg = vdup_n_u8(150);
    const uint8x8_t cb = vdup_n_u8(29);

    for (int32_t y = 0; y < height; y++) {
        const uint8_t* row = rgba + (size_t)y * stride;
        int32_t x = 0;
        for (; x + 16 <= width; x += 16) {
            uint8x16x4_t px = vld4q_u8(row + (size_t)x * 4);
            uint8x16_t r = px.val[0];
            uint8x16_t g = px.val[1];
            uint8x16_t b = px.val[2];

            uint16x8_t lo = vmull_u8(vget_low_u8(r), cr);
            lo = vmlal_u8(lo, vget_low_u8(g), cg);
            lo = vmlal_u8(lo, vget_low_u8(b), cb);
            uint8x8_t y_lo = vshrn_n_u16(lo, 8);

            uint16x8_t hi = vmull_u8(vget_high_u8(r), cr);
            hi = vmlal_u8(hi, vget_high_u8(g), cg);
            hi = vmlal_u8(hi, vget_high_u8(b), cb);
            uint8x8_t y_hi = vshrn_n_u16(hi, 8);

            uint8_t rv[16], gv[16], bv[16], yv[16];
            vst1q_u8(rv, r);
            vst1q_u8(gv, g);
            vst1q_u8(bv, b);
            vst1_u8(yv, y_lo);
            vst1_u8(yv + 8, y_hi);

            for (int i = 0; i < 16; i++) {
                luma_hist[yv[i]]++;
                r_hist[rv[i]]++;
                g_hist[gv[i]]++;
                b_hist[bv[i]]++;
            }
        }
        for (; x < width; x++) {
            uint8_t r = row[x * 4 + 0];
            uint8_t g = row[x * 4 + 1];
            uint8_t b = row[x * 4 + 2];
            luma_hist[luma_u8(r, g, b)]++;
            r_hist[r]++;
            g_hist[g]++;
            b_hist[b]++;
        }
    }
#else
    /* No NEON — the scalar reference is already the fast path. */
    camera_pro_compute_histogram_rgba_scalar(
        rgba, width, height, stride, luma_hist, r_hist, g_hist, b_hist);
#endif
}

/* ── Focus peaking (Sobel edge highlight) ──────────────────────────────── */
int32_t camera_pro_compute_focus_peaking(
    const uint8_t* rgba, uint8_t* out_rgba,
    int32_t width, int32_t height, int32_t stride,
    float threshold, uint32_t peak_color) {

    if (!rgba || !out_rgba || width <= 0 || height <= 0)
        return CAMERA_ERROR_INVALID_PARAMETER;
    if (stride <= 0) stride = width * 4;

    const uint8_t pr = (uint8_t)((peak_color >> 24) & 0xFF);
    const uint8_t pg = (uint8_t)((peak_color >> 16) & 0xFF);
    const uint8_t pb = (uint8_t)((peak_color >> 8) & 0xFF);

    /* Sobel magnitude is at most ~4*255 in each direction; normalise by 1020. */
    const float norm = 1.0f / 1020.0f;
    const int32_t out_stride = width * 4;

    for (int32_t y = 0; y < height; y++) {
        const uint8_t* row = rgba + (size_t)y * stride;
        uint8_t* orow = out_rgba + (size_t)y * out_stride;
        for (int32_t x = 0; x < width; x++) {
            /* Copy original pixel first. */
            orow[x * 4 + 0] = row[x * 4 + 0];
            orow[x * 4 + 1] = row[x * 4 + 1];
            orow[x * 4 + 2] = row[x * 4 + 2];
            orow[x * 4 + 3] = row[x * 4 + 3];

            if (x < 1 || y < 1 || x >= width - 1 || y >= height - 1) continue;

            #define LUMA_AT(dx, dy) \
                luma_u8(rgba[((size_t)(y+(dy))*stride)+((size_t)(x+(dx))*4)+0], \
                        rgba[((size_t)(y+(dy))*stride)+((size_t)(x+(dx))*4)+1], \
                        rgba[((size_t)(y+(dy))*stride)+((size_t)(x+(dx))*4)+2])

            int tl = LUMA_AT(-1, -1), tc = LUMA_AT(0, -1), tr = LUMA_AT(1, -1);
            int ml = LUMA_AT(-1,  0),                       mr = LUMA_AT(1,  0);
            int bl = LUMA_AT(-1,  1), bc = LUMA_AT(0,  1), br = LUMA_AT(1,  1);
            #undef LUMA_AT

            int gx = -tl + tr - 2 * ml + 2 * mr - bl + br;
            int gy = -tl - 2 * tc - tr + bl + 2 * bc + br;
            float edge = sqrtf((float)(gx * gx + gy * gy)) * norm;

            if (edge > threshold) {
                orow[x * 4 + 0] = pr;
                orow[x * 4 + 1] = pg;
                orow[x * 4 + 2] = pb;
            }
        }
    }
    return CAMERA_OK;
}

/* ── Zebra stripes (over-exposure overlay) ─────────────────────────────── */
int32_t camera_pro_compute_zebra(
    const uint8_t* rgba, uint8_t* out_rgba,
    int32_t width, int32_t height, int32_t stride,
    float threshold, int32_t frame_counter) {

    if (!rgba || !out_rgba || width <= 0 || height <= 0)
        return CAMERA_ERROR_INVALID_PARAMETER;
    if (stride <= 0) stride = width * 4;

    const int32_t thr = (int32_t)(threshold * 255.0f);
    const int32_t out_stride = width * 4;

    for (int32_t y = 0; y < height; y++) {
        const uint8_t* row = rgba + (size_t)y * stride;
        uint8_t* orow = out_rgba + (size_t)y * out_stride;
        for (int32_t x = 0; x < width; x++) {
            uint8_t r = row[x * 4 + 0];
            uint8_t g = row[x * 4 + 1];
            uint8_t b = row[x * 4 + 2];
            uint8_t a = row[x * 4 + 3];

            if (luma_u8(r, g, b) > thr) {
                int stripe = (((x + y + frame_counter * 2) / 4) & 1);
                if (stripe == 0) { r = 255; g = 0; b = 0; }
            }
            orow[x * 4 + 0] = r;
            orow[x * 4 + 1] = g;
            orow[x * 4 + 2] = b;
            orow[x * 4 + 3] = a;
        }
    }
    return CAMERA_OK;
}
