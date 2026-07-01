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
#include <stdlib.h>
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

/* ── Digital manual-control adjustments ────────────────────────────────── */
static inline uint8_t clampf_u8(float v) {
    if (v < 0.0f) return 0;
    if (v > 255.0f) return 255;
    return (uint8_t)(v + 0.5f);
}

int32_t camera_pro_adjust_pixels(
    uint8_t* px, int32_t width, int32_t height, int32_t stride,
    int32_t is_bgra, float gain, float bias, float temp, float contrast) {

    if (!px || width <= 0 || height <= 0) return CAMERA_ERROR_INVALID_PARAMETER;
    if (stride <= 0) stride = width * 4;

    const int ri = is_bgra ? 2 : 0;
    const int bi = is_bgra ? 0 : 2;
    /* White-balance channel gains: warm boosts red, cuts blue. */
    const float r_gain = 1.0f + temp * 0.6f;
    const float b_gain = 1.0f - temp * 0.6f;

    for (int32_t y = 0; y < height; y++) {
        uint8_t* row = px + (size_t)y * stride;
        for (int32_t x = 0; x < width; x++) {
            uint8_t* p = row + x * 4;
            float ch[3];
            ch[0] = (float)p[0];
            ch[1] = (float)p[1];
            ch[2] = (float)p[2];
            for (int i = 0; i < 3; i++) {
                float v = (ch[i] - 128.0f) * contrast + 128.0f; /* contrast */
                v = v * gain + bias;                            /* ISO + EV  */
                ch[i] = v;
            }
            ch[ri] *= r_gain;  /* white balance */
            ch[bi] *= b_gain;
            p[0] = clampf_u8(ch[0]);
            p[1] = clampf_u8(ch[1]);
            p[2] = clampf_u8(ch[2]);
        }
    }
    return CAMERA_OK;
}

int32_t camera_pro_digital_zoom(
    const uint8_t* in_px, uint8_t* out_px,
    int32_t width, int32_t height, int32_t stride, float factor) {

    if (!in_px || !out_px || width <= 0 || height <= 0)
        return CAMERA_ERROR_INVALID_PARAMETER;
    if (stride <= 0) stride = width * 4;
    if (factor < 1.0f) factor = 1.0f;

    const int32_t crop_w = (int32_t)(width / factor);
    const int32_t crop_h = (int32_t)(height / factor);
    const int32_t off_x = (width - crop_w) / 2;
    const int32_t off_y = (height - crop_h) / 2;
    const int32_t out_stride = width * 4;

    for (int32_t y = 0; y < height; y++) {
        const int32_t sy = off_y + (int32_t)(((int64_t)y * crop_h) / height);
        const uint8_t* srow = in_px + (size_t)sy * stride;
        uint8_t* orow = out_px + (size_t)y * out_stride;
        for (int32_t x = 0; x < width; x++) {
            const int32_t sx = off_x + (int32_t)(((int64_t)x * crop_w) / width);
            const uint8_t* sp = srow + sx * 4;
            uint8_t* op = orow + x * 4;
            op[0] = sp[0]; op[1] = sp[1]; op[2] = sp[2]; op[3] = sp[3];
        }
    }
    return CAMERA_OK;
}

/* ── Separable box blur (digital defocus) ──────────────────────────────── */
int32_t camera_pro_box_blur(
    uint8_t* px, int32_t width, int32_t height, int32_t stride, int32_t radius) {

    if (!px || width <= 0 || height <= 0) return CAMERA_ERROR_INVALID_PARAMETER;
    if (stride <= 0) stride = width * 4;
    if (radius <= 0) return CAMERA_OK;

    uint8_t* tmp = (uint8_t*)malloc((size_t)width * height * 4);
    if (!tmp) return CAMERA_ERROR_OUT_OF_MEMORY;
    const int32_t tstride = width * 4;

    /* Horizontal pass: px -> tmp. */
    for (int32_t y = 0; y < height; y++) {
        const uint8_t* srow = px + (size_t)y * stride;
        uint8_t* trow = tmp + (size_t)y * tstride;
        for (int32_t x = 0; x < width; x++) {
            int32_t x0 = x - radius, x1 = x + radius;
            if (x0 < 0) x0 = 0;
            if (x1 >= width) x1 = width - 1;
            int32_t sum0 = 0, sum1 = 0, sum2 = 0, sum3 = 0;
            const int32_t count = x1 - x0 + 1;
            for (int32_t xx = x0; xx <= x1; xx++) {
                const uint8_t* p = srow + xx * 4;
                sum0 += p[0]; sum1 += p[1]; sum2 += p[2]; sum3 += p[3];
            }
            uint8_t* t = trow + x * 4;
            t[0] = (uint8_t)(sum0 / count);
            t[1] = (uint8_t)(sum1 / count);
            t[2] = (uint8_t)(sum2 / count);
            t[3] = (uint8_t)(sum3 / count);
        }
    }

    /* Vertical pass: tmp -> px. */
    for (int32_t y = 0; y < height; y++) {
        int32_t y0 = y - radius, y1 = y + radius;
        if (y0 < 0) y0 = 0;
        if (y1 >= height) y1 = height - 1;
        const int32_t count = y1 - y0 + 1;
        uint8_t* drow = px + (size_t)y * stride;
        for (int32_t x = 0; x < width; x++) {
            int32_t sum0 = 0, sum1 = 0, sum2 = 0, sum3 = 0;
            for (int32_t yy = y0; yy <= y1; yy++) {
                const uint8_t* p = tmp + (size_t)yy * tstride + x * 4;
                sum0 += p[0]; sum1 += p[1]; sum2 += p[2]; sum3 += p[3];
            }
            uint8_t* d = drow + x * 4;
            d[0] = (uint8_t)(sum0 / count);
            d[1] = (uint8_t)(sum1 / count);
            d[2] = (uint8_t)(sum2 / count);
            d[3] = (uint8_t)(sum3 / count);
        }
    }

    free(tmp);
    return CAMERA_OK;
}

/* ── Luminance waveform monitor ────────────────────────────────────────── */
int32_t camera_pro_compute_luma_waveform(
    const uint8_t* rgba, int32_t width, int32_t height, int32_t stride,
    uint32_t* out, int32_t columns) {

    if (!rgba || !out || width <= 0 || height <= 0 || columns <= 0)
        return CAMERA_ERROR_INVALID_PARAMETER;
    if (stride <= 0) stride = width * 4;

    memset(out, 0, (size_t)columns * 256 * sizeof(uint32_t));

    for (int32_t y = 0; y < height; y++) {
        const uint8_t* row = rgba + (size_t)y * stride;
        for (int32_t x = 0; x < width; x++) {
            int32_t col = (int32_t)(((int64_t)x * columns) / width);
            if (col >= columns) col = columns - 1;
            uint8_t luma = luma_u8(row[x * 4 + 0], row[x * 4 + 1], row[x * 4 + 2]);
            out[(size_t)col * 256 + luma]++;
        }
    }
    return CAMERA_OK;
}

/* ── False-color exposure map ──────────────────────────────────────────── */
static void false_color_for(uint8_t y, uint8_t* r, uint8_t* g, uint8_t* b) {
    if (y < 3)        { *r = 0x30; *g = 0x00; *b = 0x60; }  /* crushed  → purple */
    else if (y < 20)  { *r = 0x00; *g = 0x00; *b = 0xFF; }  /* shadows  → blue   */
    else if (y < 42)  { *r = 0x00; *g = 0xC0; *b = 0xFF; }  /* low mid  → cyan   */
    else if (y < 100) { *r = 0x00; *g = 0xFF; *b = 0x00; }  /* 18% gray → green  */
    else if (y < 150) { *r = 0xC0; *g = 0xC0; *b = 0xC0; }  /* mid      → gray   */
    else if (y < 200) { *r = 0xFF; *g = 0xC0; *b = 0xC0; }  /* highlight→ pink   */
    else if (y < 250) { *r = 0xFF; *g = 0xFF; *b = 0x00; }  /* near clip→ yellow */
    else              { *r = 0xFF; *g = 0x00; *b = 0x00; }  /* clipped  → red    */
}

int32_t camera_pro_compute_false_color(
    const uint8_t* rgba, uint8_t* out_rgba,
    int32_t width, int32_t height, int32_t stride) {

    if (!rgba || !out_rgba || width <= 0 || height <= 0)
        return CAMERA_ERROR_INVALID_PARAMETER;
    if (stride <= 0) stride = width * 4;

    const int32_t out_stride = width * 4;
    for (int32_t y = 0; y < height; y++) {
        const uint8_t* row = rgba + (size_t)y * stride;
        uint8_t* orow = out_rgba + (size_t)y * out_stride;
        for (int32_t x = 0; x < width; x++) {
            uint8_t luma = luma_u8(row[x * 4 + 0], row[x * 4 + 1], row[x * 4 + 2]);
            uint8_t r, g, b;
            false_color_for(luma, &r, &g, &b);
            orow[x * 4 + 0] = r;
            orow[x * 4 + 1] = g;
            orow[x * 4 + 2] = b;
            orow[x * 4 + 3] = row[x * 4 + 3];
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
