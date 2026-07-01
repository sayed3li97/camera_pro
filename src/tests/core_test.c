/*
 * core_test.c — Standalone C test harness for the shared core.
 *
 * Compiled and run directly (no Flutter/Dart) as the ground-truth verification
 * that the native core is correct. Cross-checks the SIMD histogram against the
 * scalar reference, exercises the buffer pool, and sanity-checks the format
 * converters and visual-aid kernels.
 *
 * Build & run:
 *   clang -std=c11 -O2 -I src/core -I src/hal \
 *     src/core/buffer_pool.c src/core/image_processor.c \
 *     src/core/format_converter.c src/core/camera_pro_core.c \
 *     src/platform/stub/camera_hal_stub.c src/tests/core_test.c \
 *     -o core_test && ./core_test
 *
 * Copyright (c) 2026 camera_pro contributors. BSD-3-Clause.
 */
#include "camera_pro_core.h"
#include "../hal/camera_hal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_failures = 0;
static int g_checks   = 0;

#define CHECK(cond, msg) do { \
    g_checks++; \
    if (!(cond)) { g_failures++; printf("  [FAIL] %s\n", msg); } \
    else         { printf("  [ ok ] %s\n", msg); } \
} while (0)

/* Deterministic xorshift so the test is reproducible without Date/rand seed. */
static uint32_t rng_state = 0x1234567u;
static uint32_t xrand(void) {
    uint32_t x = rng_state;
    x ^= x << 13; x ^= x >> 17; x ^= x << 5;
    return (rng_state = x);
}

static void test_version(void) {
    printf("version / introspection\n");
    CHECK(camera_pro_core_version() == ((0 << 16) | (1 << 8) | 0), "version encodes 0.1.0");
    CHECK(strcmp(camera_pro_core_version_string(), "0.1.0") == 0, "version string");
    CHECK(camera_pro_simd_name() != NULL, "simd name non-null");
    CHECK(strcmp(camera_pro_error_string(CAMERA_ERROR_PERMISSION_DENIED),
                 "Camera permission denied") == 0, "error string");
    printf("  simd kernel: %s\n", camera_pro_simd_name());
}

static void test_buffer_pool(void) {
    printf("buffer pool\n");
    camera_pro_buffer_pool_t* pool = camera_pro_buffer_pool_create(1000, 4);
    CHECK(pool != NULL, "create");
    CHECK(camera_pro_buffer_pool_capacity(pool) == 4, "capacity == 4");
    CHECK(camera_pro_buffer_pool_available(pool) == 4, "all free initially");

    int32_t s0 = 0, s1 = 0, s2 = 0, s3 = 0, s4 = 0;
    uint8_t* b0 = camera_pro_buffer_pool_acquire(pool, &s0);
    uint8_t* b1 = camera_pro_buffer_pool_acquire(pool, &s1);
    uint8_t* b2 = camera_pro_buffer_pool_acquire(pool, &s2);
    uint8_t* b3 = camera_pro_buffer_pool_acquire(pool, &s3);
    CHECK(b0 && b1 && b2 && b3, "acquired 4 distinct buffers");
    CHECK(s0 >= 1000 && (s0 % 64) == 0, "buffer size rounded up to 64-alignment");
    CHECK(camera_pro_buffer_pool_available(pool) == 0, "pool drained");

    uint8_t* b4 = camera_pro_buffer_pool_acquire(pool, &s4);
    CHECK(b4 == NULL && s4 == 0, "acquire returns NULL when drained");

    camera_pro_buffer_pool_release(pool, b2);
    CHECK(camera_pro_buffer_pool_available(pool) == 1, "release returns buffer");
    uint8_t* b5 = camera_pro_buffer_pool_acquire(pool, &s4);
    CHECK(b5 == b2, "reacquire reuses released buffer");

    /* buffers must be usable memory */
    memset(b0, 0xAB, (size_t)s0);
    CHECK(b0[0] == 0xAB && b0[s0 - 1] == 0xAB, "buffer is writable across full capacity");

    camera_pro_buffer_pool_destroy(pool);

    CHECK(camera_pro_buffer_pool_create(10, 999) == NULL, "reject oversized count");
    CHECK(camera_pro_buffer_pool_create(0, 4) == NULL, "reject zero size");
}

static void test_histogram(void) {
    printf("histogram (SIMD vs scalar cross-check)\n");
    const int32_t W = 129, H = 71;   /* deliberately not a multiple of 16 */
    const int32_t stride = W * 4;
    uint8_t* img = (uint8_t*)malloc((size_t)stride * H);
    for (int32_t i = 0; i < stride * H; i++) img[i] = (uint8_t)(xrand() & 0xFF);

    uint32_t lref[256], rref[256], gref[256], bref[256];
    uint32_t lsimd[256], rsimd[256], gsimd[256], bsimd[256];
    camera_pro_compute_histogram_rgba_scalar(img, W, H, stride, lref, rref, gref, bref);
    camera_pro_compute_histogram_rgba(img, W, H, stride, lsimd, rsimd, gsimd, bsimd);

    int equal = 1;
    uint64_t ltot = 0;
    for (int i = 0; i < 256; i++) {
        if (lref[i] != lsimd[i] || rref[i] != rsimd[i] ||
            gref[i] != gsimd[i] || bref[i] != bsimd[i]) equal = 0;
        ltot += lref[i];
    }
    CHECK(equal, "SIMD histogram bit-exact vs scalar");
    CHECK(ltot == (uint64_t)(W * H), "luma bins sum to pixel count");

    /* A uniform gray image must land entirely in one luma bin. */
    for (int32_t i = 0; i < stride * H; i++) img[i] = 128;
    camera_pro_compute_histogram_rgba(img, W, H, stride, lsimd, rsimd, gsimd, bsimd);
    CHECK(lsimd[128] == (uint32_t)(W * H), "uniform gray => single luma bin");

    free(img);
}

static void test_format_conversion(void) {
    printf("format conversion\n");
    const int32_t W = 8, H = 8;
    uint8_t y[64], u[16], v[16];
    /* Neutral gray: Y=125 (~mid after video-range expand), U=V=128 => near-gray. */
    memset(y, 125, sizeof(y));
    memset(u, 128, sizeof(u));
    memset(v, 128, sizeof(v));
    uint8_t rgba[64 * 4];
    int32_t rc = camera_pro_yuv420p_to_rgba(y, u, v, W, W / 2, rgba, W, H);
    CHECK(rc == CAMERA_OK, "yuv420p returns OK");

    uint8_t r = rgba[0], g = rgba[1], b = rgba[2], a = rgba[3];
    int gray = (abs((int)r - (int)g) <= 2) && (abs((int)g - (int)b) <= 2);
    CHECK(gray, "neutral chroma => near-gray RGB");
    CHECK(a == 255, "alpha is opaque");

    CHECK(camera_pro_nv12_to_rgba(NULL, u, W, W, rgba, W, H) == CAMERA_ERROR_INVALID_PARAMETER,
          "null input rejected");
}

static void test_visual_aids(void) {
    printf("visual aids\n");
    const int32_t W = 16, H = 16, stride = W * 4;
    uint8_t* in  = (uint8_t*)calloc((size_t)stride * H, 1);
    uint8_t* out = (uint8_t*)calloc((size_t)stride * H, 1);
    /* Left half black, right half white => a strong vertical edge in the middle. */
    for (int32_t yy = 0; yy < H; yy++) {
        for (int32_t xx = 0; xx < W; xx++) {
            uint8_t val = (xx >= W / 2) ? 255 : 0;
            uint8_t* p = in + (size_t)yy * stride + xx * 4;
            p[0] = p[1] = p[2] = val; p[3] = 255;
        }
    }
    int32_t rc = camera_pro_compute_focus_peaking(in, out, W, H, stride, 0.2f, 0x00FFFFFFu);
    CHECK(rc == CAMERA_OK, "focus peaking returns OK");
    /* Column at the edge (x = W/2 - 1 or W/2) should be tinted cyan-ish (G/B high, differs from pure b/w). */
    int found_edge = 0;
    for (int32_t yy = 1; yy < H - 1; yy++) {
        uint8_t* p = out + (size_t)yy * stride + (W / 2) * 4;
        if (p[1] == 0xFF && p[2] == 0xFF) found_edge = 1;
    }
    CHECK(found_edge, "vertical edge is highlighted");

    /* Zebra: fully white image over threshold must gain some red-striped pixels. */
    for (int32_t i = 0; i < stride * H; i++) in[i] = 255;
    rc = camera_pro_compute_zebra(in, out, W, H, stride, 0.9f, 0);
    CHECK(rc == CAMERA_OK, "zebra returns OK");
    int striped = 0;
    for (int32_t i = 0; i < W * H; i++) {
        if (out[i * 4 + 0] == 255 && out[i * 4 + 1] == 0 && out[i * 4 + 2] == 0) striped = 1;
    }
    CHECK(striped, "over-exposed region gets zebra stripes");

    free(in);
    free(out);
}

static void test_hal_stub(void) {
    printf("HAL stub backend\n");
    camera_context_t* ctx = NULL;
    CHECK(camera_hal_create(&ctx) == CAMERA_OK && ctx != NULL, "create context");
    int32_t count = -1;
    CHECK(camera_hal_enumerate_devices(ctx, &count) == CAMERA_OK && count == 0, "enumerate (0 devices)");
    CHECK(camera_hal_open(ctx, 0, 0) == CAMERA_OK, "open");
    CHECK(camera_hal_start_preview(ctx) == CAMERA_OK, "start preview");
    CHECK(camera_hal_set_iso(ctx, 100) == CAMERA_ERROR_FEATURE_NOT_SUPPORTED, "iso unsupported on stub");
    camera_capabilities_t caps;
    CHECK(camera_hal_get_capabilities(ctx, &caps) == CAMERA_OK, "get capabilities");
    CHECK(caps.shutter.supported == false, "stub reports no manual shutter");
    CHECK(camera_hal_close(ctx) == CAMERA_OK, "close");
    CHECK(camera_hal_destroy(ctx) == CAMERA_OK, "destroy");
}

int main(void) {
    printf("=== camera_pro core test harness ===\n");
    test_version();
    test_buffer_pool();
    test_histogram();
    test_format_conversion();
    test_visual_aids();
    test_hal_stub();
    printf("\n=== %d checks, %d failures ===\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
