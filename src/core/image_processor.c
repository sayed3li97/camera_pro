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

#if defined(__SSSE3__)
#  include <tmmintrin.h>
#  define CAMERA_PRO_HAVE_SSSE3 1
#elif defined(__SSE2__)
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
#elif defined(CAMERA_PRO_HAVE_SSSE3) || defined(CAMERA_PRO_HAVE_SSE2)
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
#elif defined(CAMERA_PRO_HAVE_SSSE3)
    memset(luma_hist, 0, 256 * sizeof(uint32_t));
    memset(r_hist,    0, 256 * sizeof(uint32_t));
    memset(g_hist,    0, 256 * sizeof(uint32_t));
    memset(b_hist,    0, 256 * sizeof(uint32_t));

    /* maddubs computes u8*i8 pairs with i16 SATURATION, so split the luma
     * coefficients so no pair can exceed 32767: (77r + 29b) max 27030 and
     * (150g) max 38250 — the latter alone still fits u16 but not i16, so give
     * g its own pass with coefficient split 75+75. Sum both passes in 32-bit. */
    const __m128i c_rb = _mm_set1_epi32((int)0x001D004Du); /* [77,0,29,0] */
    const __m128i ones16 = _mm_set1_epi16(1);

    for (int32_t y = 0; y < height; y++) {
        const uint8_t* row = rgba + (size_t)y * stride;
        int32_t x = 0;
        for (; x + 4 <= width; x += 4) {
            __m128i px = _mm_loadu_si128((const __m128i*)(row + (size_t)x * 4));
            /* rb: byte pairs (r*77 + g*0) and (b*29 + a*0) → madd → r*77+b*29 */
            __m128i rb = _mm_madd_epi16(_mm_maddubs_epi16(px, c_rb), ones16);
            /* g*150 would saturate maddubs' i16 result (38250 > 32767), so
             * compute g*75 and double it in 32-bit space. */
            __m128i g1 = _mm_madd_epi16(
                _mm_maddubs_epi16(px, _mm_set1_epi32(0x00004B00)), ones16);
            __m128i luma = _mm_add_epi32(rb, _mm_add_epi32(g1, g1));
            luma = _mm_srli_epi32(luma, 8);

            uint32_t lv[4];
            _mm_storeu_si128((__m128i*)lv, luma);
            for (int i = 0; i < 4; i++) {
                const uint8_t* p = row + (size_t)(x + i) * 4;
                luma_hist[lv[i] > 255 ? 255 : lv[i]]++;
                r_hist[p[0]]++;
                g_hist[p[1]]++;
                b_hist[p[2]]++;
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
    /* No SIMD — the scalar reference is already the fast path. */
    camera_pro_compute_histogram_rgba_scalar(
        rgba, width, height, stride, luma_hist, r_hist, g_hist, b_hist);
#endif
}

/* ── Focus peaking (Sobel edge highlight) ──────────────────────────────── */
int32_t camera_pro_compute_focus_peaking(
    const uint8_t* rgba, uint8_t* out_rgba,
    int32_t width, int32_t height, int32_t stride,
    int32_t is_bgra, float threshold, uint32_t peak_color) {

    if (!rgba || !out_rgba || width <= 0 || height <= 0)
        return CAMERA_ERROR_INVALID_PARAMETER;
    if (stride <= 0) stride = width * 4;

    const uint8_t pr = (uint8_t)((peak_color >> 24) & 0xFF);
    const uint8_t pg = (uint8_t)((peak_color >> 16) & 0xFF);
    const uint8_t pb = (uint8_t)((peak_color >> 8) & 0xFF);
    const int ri = is_bgra ? 2 : 0;  /* red channel index   */
    const int bi = is_bgra ? 0 : 2;  /* blue channel index  */

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
                orow[x * 4 + ri] = pr;
                orow[x * 4 + 1]  = pg;
                orow[x * 4 + bi] = pb;
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

static inline uint8_t clampd_u8(double v) {
    if (v < 0.0) return 0;
    if (v > 255.0) return 255;
    return (uint8_t)(v + 0.5);
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

/* ── HDR exposure fusion (multi-scale Mertens) ─────────────────────────────
 * Real exposure fusion (Mertens, Kautz & Van Reeth 2009): each source image is
 * weighted per pixel by contrast (|Laplacian| of luma) × saturation (stddev of
 * RGB) × well-exposedness (Gaussian around mid-grey), and the weighted blend is
 * done through a Laplacian pyramid so local contrast is preserved and there are
 * no seams or halos. A naive single-scale weighted average (the previous
 * implementation) looks washed-out and haloed; the multi-resolution blend is
 * what makes the result usable. Everything is computed in float [0,1].
 * ───────────────────────────────────────────────────────────────────────── */

#define MF_MAX_LEVELS 16

typedef struct {
    float*  level[MF_MAX_LEVELS];
    int32_t w[MF_MAX_LEVELS];
    int32_t h[MF_MAX_LEVELS];
    int32_t levels;
} MfPyr;

static const float MF_K[5] = {1.f/16, 4.f/16, 6.f/16, 4.f/16, 1.f/16};

static inline float mf_clamp01(float v) { return v < 0.f ? 0.f : (v > 1.f ? 1.f : v); }

/* sRGB <-> linear, so exposure gains are applied in physically-linear light. */
static inline float mf_srgb_to_lin(float c) {
    return c <= 0.04045f ? c / 12.92f : powf((c + 0.055f) / 1.055f, 2.4f);
}
static inline float mf_lin_to_srgb(float c) {
    if (c <= 0.f) return 0.f;
    if (c >= 1.f) return 1.f;
    return c <= 0.0031308f ? c * 12.92f : 1.055f * powf(c, 1.f / 2.4f) - 0.055f;
}

static int32_t mf_levels_for(int32_t w, int32_t h) {
    int32_t m = w < h ? w : h, l = 1;
    while (m > 1 && l < MF_MAX_LEVELS) { m = (m + 1) / 2; l++; }
    return l;
}

/* Binomial [1 4 6 4 1]/16 blur, subsample by 2 (border-replicated). */
static void mf_reduce(const float* src, int32_t sw, int32_t sh,
                      float* dst, int32_t dw, int32_t dh) {
    for (int32_t y = 0; y < dh; y++)
        for (int32_t x = 0; x < dw; x++) {
            float acc = 0.f;
            for (int32_t q = -2; q <= 2; q++) {
                int32_t sy = 2 * y + q;
                sy = sy < 0 ? 0 : (sy >= sh ? sh - 1 : sy);
                for (int32_t p = -2; p <= 2; p++) {
                    int32_t sx = 2 * x + p;
                    sx = sx < 0 ? 0 : (sx >= sw ? sw - 1 : sx);
                    acc += MF_K[p + 2] * MF_K[q + 2] * src[(size_t)sy * sw + sx];
                }
            }
            dst[(size_t)y * dw + x] = acc;
        }
}

/* Upsample src (sw×sh) to dst (dw×dh) via the same binomial kernel (×4 gain). */
static void mf_expand(const float* src, int32_t sw, int32_t sh,
                      float* dst, int32_t dw, int32_t dh) {
    for (int32_t y = 0; y < dh; y++)
        for (int32_t x = 0; x < dw; x++) {
            float acc = 0.f;
            for (int32_t q = -2; q <= 2; q++) {
                int32_t yy = y - q;
                if (yy & 1) continue;
                int32_t sy = yy / 2;
                sy = sy < 0 ? 0 : (sy >= sh ? sh - 1 : sy);
                for (int32_t p = -2; p <= 2; p++) {
                    int32_t xx = x - p;
                    if (xx & 1) continue;
                    int32_t sx = xx / 2;
                    sx = sx < 0 ? 0 : (sx >= sw ? sw - 1 : sx);
                    acc += MF_K[p + 2] * MF_K[q + 2] * src[(size_t)sy * sw + sx];
                }
            }
            dst[(size_t)y * dw + x] = 4.f * acc;
        }
}

static int mf_pyr_alloc(MfPyr* p, int32_t w, int32_t h) {
    p->levels = mf_levels_for(w, h);
    int32_t cw = w, ch = h;
    for (int32_t l = 0; l < p->levels; l++) {
        p->w[l] = cw; p->h[l] = ch;
        p->level[l] = (float*)malloc((size_t)cw * ch * sizeof(float));
        if (!p->level[l]) {
            for (int32_t j = 0; j < l; j++) free(p->level[j]);
            p->levels = 0; /* make mf_pyr_free a safe no-op on a failed pyramid */
            return 0;
        }
        cw = (cw + 1) / 2; ch = (ch + 1) / 2;
    }
    return 1;
}
static void mf_pyr_free(MfPyr* p) {
    for (int32_t l = 0; l < p->levels; l++) free(p->level[l]);
}
static void mf_gauss_fill(MfPyr* g) {  /* level[0] must be set */
    for (int32_t l = 1; l < g->levels; l++)
        mf_reduce(g->level[l - 1], g->w[l - 1], g->h[l - 1],
                  g->level[l], g->w[l], g->h[l]);
}
/* Turn a filled Gaussian pyramid into a Laplacian pyramid in place. */
static void mf_gauss_to_lap(MfPyr* g, float* tmp) {
    for (int32_t l = 0; l < g->levels - 1; l++) {
        mf_expand(g->level[l + 1], g->w[l + 1], g->h[l + 1], tmp, g->w[l], g->h[l]);
        size_t nn = (size_t)g->w[l] * g->h[l];
        for (size_t i = 0; i < nn; i++) g->level[l][i] -= tmp[i];
    }
}
/* Collapse a Laplacian pyramid; result ends up in level[0]. */
static void mf_collapse(MfPyr* lap, float* tmp) {
    for (int32_t l = lap->levels - 2; l >= 0; l--) {
        mf_expand(lap->level[l + 1], lap->w[l + 1], lap->h[l + 1], tmp, lap->w[l], lap->h[l]);
        size_t nn = (size_t)lap->w[l] * lap->h[l];
        for (size_t i = 0; i < nn; i++) lap->level[l][i] += tmp[i];
    }
}

/* Fuse n interleaved-RGB float images ([0,1], w*h*3 each) into `out` (w*h*3). */
static int32_t mf_fuse(const float* imgs, int32_t n, int32_t w, int32_t h, float* out) {
    const size_t npx = (size_t)w * h;
    const float inv2s2 = 1.f / (2.f * 0.2f * 0.2f);
    int32_t rc = CAMERA_ERROR_OUT_OF_MEMORY;

    float* gray = (float*)malloc(npx * sizeof(float));
    float* wsum = (float*)calloc(npx, sizeof(float));
    float* tmp  = (float*)malloc(npx * sizeof(float));
    MfPyr* wpyr = (MfPyr*)calloc((size_t)n, sizeof(MfPyr));
    MfPyr lpyr, acc;
    memset(&lpyr, 0, sizeof lpyr); /* levels=0 => mf_pyr_free is a safe no-op */
    memset(&acc, 0, sizeof acc);
    if (!gray || !wsum || !tmp || !wpyr) goto done;
    if (!mf_pyr_alloc(&lpyr, w, h)) goto done;
    if (!mf_pyr_alloc(&acc, w, h)) goto done;
    for (int32_t k = 0; k < n; k++) {
        if (!mf_pyr_alloc(&wpyr[k], w, h)) goto done;
    }

    /* Per-image weights: contrast × saturation × well-exposedness (+ floors). */
    for (int32_t k = 0; k < n; k++) {
        const float* im = imgs + (size_t)k * npx * 3;
        for (size_t i = 0; i < npx; i++)
            gray[i] = 0.299f * im[i*3] + 0.587f * im[i*3+1] + 0.114f * im[i*3+2];
        for (int32_t y = 0; y < h; y++)
            for (int32_t x = 0; x < w; x++) {
                size_t i = (size_t)y * w + x;
                int32_t xm = x > 0 ? x-1 : 0, xp = x < w-1 ? x+1 : w-1;
                int32_t ym = y > 0 ? y-1 : 0, yp = y < h-1 ? y+1 : h-1;
                float lap = gray[(size_t)y*w+xm] + gray[(size_t)y*w+xp]
                          + gray[(size_t)ym*w+x] + gray[(size_t)yp*w+x] - 4.f*gray[i];
                float C = lap < 0 ? -lap : lap;
                float R = im[i*3], G = im[i*3+1], B = im[i*3+2];
                float m = (R + G + B) / 3.f;
                float S = sqrtf(((R-m)*(R-m) + (G-m)*(G-m) + (B-m)*(B-m)) / 3.f);
                float zr = R-0.5f, zg = G-0.5f, zb = B-0.5f;
                float E = expf(-(zr*zr + zg*zg + zb*zb) * inv2s2);
                float Wt = (C + 1e-5f) * (S + 1e-5f) * E;
                wpyr[k].level[0][i] = Wt;
                wsum[i] += Wt;
            }
    }
    /* Normalise weights per pixel, then build their Gaussian pyramids. */
    for (int32_t k = 0; k < n; k++) {
        for (size_t i = 0; i < npx; i++)
            wpyr[k].level[0][i] /= (wsum[i] + 1e-12f);
        mf_gauss_fill(&wpyr[k]);
    }

    /* Blend each channel through the pyramid. */
    for (int32_t c = 0; c < 3; c++) {
        for (int32_t l = 0; l < acc.levels; l++)
            memset(acc.level[l], 0, (size_t)acc.w[l] * acc.h[l] * sizeof(float));
        for (int32_t k = 0; k < n; k++) {
            const float* im = imgs + (size_t)k * npx * 3;
            for (size_t i = 0; i < npx; i++) lpyr.level[0][i] = im[i*3 + c];
            mf_gauss_fill(&lpyr);
            mf_gauss_to_lap(&lpyr, tmp);
            for (int32_t l = 0; l < acc.levels; l++) {
                size_t nn = (size_t)acc.w[l] * acc.h[l];
                const float* wl = wpyr[k].level[l];
                const float* ll = lpyr.level[l];
                float* al = acc.level[l];
                for (size_t i = 0; i < nn; i++) al[i] += wl[i] * ll[i];
            }
        }
        mf_collapse(&acc, tmp);
        for (size_t i = 0; i < npx; i++) out[i*3 + c] = mf_clamp01(acc.level[0][i]);
    }
    rc = CAMERA_OK;

done:
    free(gray); free(wsum); free(tmp);
    mf_pyr_free(&lpyr);
    mf_pyr_free(&acc);
    if (wpyr) { for (int32_t k = 0; k < n; k++) mf_pyr_free(&wpyr[k]); free(wpyr); }
    return rc;
}

/* Load an RGBA/BGRA frame into canonical interleaved-RGB float [0,1]. */
static void mf_load_rgb(const uint8_t* frame, int32_t w, int32_t h, int32_t stride,
                        int32_t is_bgra, float* dst) {
    int ri = is_bgra ? 2 : 0, bi = is_bgra ? 0 : 2;
    for (int32_t y = 0; y < h; y++) {
        const uint8_t* row = frame + (size_t)y * stride;
        for (int32_t x = 0; x < w; x++) {
            const uint8_t* p = row + x * 4;
            float* d = dst + ((size_t)y * w + x) * 3;
            d[0] = p[ri] / 255.f; d[1] = p[1] / 255.f; d[2] = p[bi] / 255.f;
        }
    }
}
/* Store canonical RGB float back to an RGBA/BGRA buffer (alpha opaque). */
static void mf_store_rgba(const float* src, int32_t w, int32_t h, int32_t is_bgra, uint8_t* out) {
    int ri = is_bgra ? 2 : 0, bi = is_bgra ? 0 : 2;
    for (size_t i = 0; i < (size_t)w * h; i++) {
        uint8_t* o = out + i * 4;
        o[ri] = clampd_u8(src[i*3]   * 255.f);
        o[1]  = clampd_u8(src[i*3+1] * 255.f);
        o[bi] = clampd_u8(src[i*3+2] * 255.f);
        o[3]  = 255;
    }
}

int32_t camera_pro_exposure_fusion(
    const uint8_t* frames, int32_t n, int32_t width, int32_t height,
    int32_t stride, int32_t is_bgra, uint8_t* out) {

    if (!frames || !out || n <= 0 || width <= 0 || height <= 0)
        return CAMERA_ERROR_INVALID_PARAMETER;
    if (stride <= 0) stride = width * 4;

    const size_t npx = (size_t)width * height;
    const size_t frame_bytes = (size_t)height * stride;
    float* imgs = (float*)malloc((size_t)n * npx * 3 * sizeof(float));
    float* fused = (float*)malloc(npx * 3 * sizeof(float));
    if (!imgs || !fused) { free(imgs); free(fused); return CAMERA_ERROR_OUT_OF_MEMORY; }

    for (int32_t k = 0; k < n; k++)
        mf_load_rgb(frames + (size_t)k * frame_bytes, width, height, stride, is_bgra,
                    imgs + (size_t)k * npx * 3);
    int32_t rc = mf_fuse(imgs, n, width, height, fused);
    if (rc == CAMERA_OK) mf_store_rgba(fused, width, height, is_bgra, out);
    free(imgs); free(fused);
    return rc;
}

/* ── Single-capture local tone mapping ─────────────────────────────────────
 * One frame in, one tone-mapped frame out. Synthesises an exposure stack from
 * the single frame by scaling it in linear light at each EV in `evs`
 * (gain = 2^ev), then runs multi-scale exposure fusion. Because every synthetic
 * exposure comes from the same instant, the result is sharp and ghost-free —
 * the right behaviour for cameras without sensor-level exposure bracketing.
 * `out` is width*height*4. Returns CAMERA_OK or an error code.
 * ───────────────────────────────────────────────────────────────────────── */
int32_t camera_pro_local_tonemap(
    const uint8_t* frame, int32_t width, int32_t height, int32_t stride,
    int32_t is_bgra, const float* evs, int32_t n_ev, uint8_t* out) {

    if (!frame || !out || !evs || n_ev <= 0 || width <= 0 || height <= 0)
        return CAMERA_ERROR_INVALID_PARAMETER;
    if (stride <= 0) stride = width * 4;

    const size_t npx = (size_t)width * height;
    float* base = (float*)malloc(npx * 3 * sizeof(float));
    float* imgs = (float*)malloc((size_t)n_ev * npx * 3 * sizeof(float));
    float* fused = (float*)malloc(npx * 3 * sizeof(float));
    if (!base || !imgs || !fused) {
        free(base); free(imgs); free(fused); return CAMERA_ERROR_OUT_OF_MEMORY;
    }
    mf_load_rgb(frame, width, height, stride, is_bgra, base);

    for (int32_t e = 0; e < n_ev; e++) {
        float gain = exp2f(evs[e]);
        float* im = imgs + (size_t)e * npx * 3;
        for (size_t i = 0; i < npx * 3; i++)
            im[i] = mf_lin_to_srgb(mf_clamp01(mf_srgb_to_lin(base[i]) * gain));
    }
    int32_t rc = mf_fuse(imgs, n_ev, width, height, fused);
    if (rc == CAMERA_OK) mf_store_rgba(fused, width, height, is_bgra, out);
    free(base); free(imgs); free(fused);
    return rc;
}

/* ── Luminance waveform monitor ────────────────────────────────────────── */
int32_t camera_pro_compute_luma_waveform(
    const uint8_t* rgba, int32_t width, int32_t height, int32_t stride,
    int32_t is_bgra, uint32_t* out, int32_t columns) {

    if (!rgba || !out || width <= 0 || height <= 0 || columns <= 0)
        return CAMERA_ERROR_INVALID_PARAMETER;
    if (stride <= 0) stride = width * 4;

    const int ri = is_bgra ? 2 : 0;
    const int bi = is_bgra ? 0 : 2;
    memset(out, 0, (size_t)columns * 256 * sizeof(uint32_t));

    for (int32_t y = 0; y < height; y++) {
        const uint8_t* row = rgba + (size_t)y * stride;
        for (int32_t x = 0; x < width; x++) {
            int32_t col = (int32_t)(((int64_t)x * columns) / width);
            if (col >= columns) col = columns - 1;
            uint8_t luma = luma_u8(row[x * 4 + ri], row[x * 4 + 1], row[x * 4 + bi]);
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
    int32_t width, int32_t height, int32_t stride, int32_t is_bgra) {

    if (!rgba || !out_rgba || width <= 0 || height <= 0)
        return CAMERA_ERROR_INVALID_PARAMETER;
    if (stride <= 0) stride = width * 4;

    const int ri = is_bgra ? 2 : 0;
    const int bi = is_bgra ? 0 : 2;
    const int32_t out_stride = width * 4;
    for (int32_t y = 0; y < height; y++) {
        const uint8_t* row = rgba + (size_t)y * stride;
        uint8_t* orow = out_rgba + (size_t)y * out_stride;
        for (int32_t x = 0; x < width; x++) {
            uint8_t luma = luma_u8(row[x * 4 + ri], row[x * 4 + 1], row[x * 4 + bi]);
            uint8_t r, g, b;
            false_color_for(luma, &r, &g, &b);
            orow[x * 4 + ri] = r;
            orow[x * 4 + 1]  = g;
            orow[x * 4 + bi] = b;
            orow[x * 4 + 3]  = row[x * 4 + 3];
        }
    }
    return CAMERA_OK;
}

/* ── Zebra stripes (over-exposure overlay) ─────────────────────────────── */
int32_t camera_pro_compute_zebra(
    const uint8_t* rgba, uint8_t* out_rgba,
    int32_t width, int32_t height, int32_t stride,
    int32_t is_bgra, float threshold, int32_t frame_counter) {

    if (!rgba || !out_rgba || width <= 0 || height <= 0)
        return CAMERA_ERROR_INVALID_PARAMETER;
    if (stride <= 0) stride = width * 4;

    const int32_t thr = (int32_t)(threshold * 255.0f);
    const int32_t out_stride = width * 4;
    const int ri = is_bgra ? 2 : 0;
    const int bi = is_bgra ? 0 : 2;

    for (int32_t y = 0; y < height; y++) {
        const uint8_t* row = rgba + (size_t)y * stride;
        uint8_t* orow = out_rgba + (size_t)y * out_stride;
        for (int32_t x = 0; x < width; x++) {
            const uint8_t c0 = row[x * 4 + 0];
            const uint8_t c1 = row[x * 4 + 1];
            const uint8_t c2 = row[x * 4 + 2];
            orow[x * 4 + 0] = c0;
            orow[x * 4 + 1] = c1;
            orow[x * 4 + 2] = c2;
            orow[x * 4 + 3] = row[x * 4 + 3];

            const uint8_t luma = luma_u8(row[x * 4 + ri], c1, row[x * 4 + bi]);
            if (luma > thr) {
                const int stripe = (((x + y + frame_counter * 2) / 4) & 1);
                if (stripe == 0) {          /* red stripe, channel-order aware */
                    orow[x * 4 + ri] = 255;
                    orow[x * 4 + 1]  = 0;
                    orow[x * 4 + bi] = 0;
                }
            }
        }
    }
    return CAMERA_OK;
}
