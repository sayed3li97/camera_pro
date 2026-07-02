/*
 * metal_test.c — GPU-vs-CPU cross-check for the Metal compute kernels.
 *
 * Runs the runtime-compiled Metal kernels on the real GPU and compares the
 * results against the C reference kernels in image_processor.c:
 *   - histogram: bit-exact (pure integer math + atomic adds)
 *   - zebra:     bit-exact (pure integer math)
 *   - peaking:   allows <= 0.05% borderline-pixel mismatch (the CPU path
 *                compares float sqrt, the GPU compares squared magnitude;
 *                real-arithmetic-equal, float-borderline cases may differ)
 *
 * Build & run (macOS):
 *   clang -fobjc-arc -O2 src/platform/apple/metal_processor.m \
 *     src/core/image_processor.c src/platform/apple/metal_test.c \
 *     -I src/core -I src/hal -I src/platform/apple \
 *     -framework Metal -framework Foundation -o metal_test && ./metal_test
 *
 * Copyright (c) 2026 camera_pro contributors. BSD-3-Clause.
 */
#include "camera_hal_apple.h"
#include "camera_pro_core.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_fail = 0;
#define CHECK(cond, msg) do { \
  if (!(cond)) { g_fail++; printf("  [FAIL] %s\n", msg); } \
  else         { printf("  [ ok ] %s\n", msg); } \
} while (0)

static uint32_t rng = 0xC0FFEE42u;
static uint32_t xrand(void) {
    rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5; return rng;
}

int main(void) {
    printf("=== camera_pro Metal GPU cross-check ===\n");
    if (!camera_pro_metal_available()) {
        printf("no Metal device — skipping (not a failure on CI-less hosts)\n");
        return 0;
    }
    printf("GPU: %s\n", camera_pro_metal_device_name());

    const int32_t W = 639, H = 481;    /* deliberately odd sizes */
    const int32_t N = W * H;
    uint8_t* img = malloc((size_t)N * 4);
    for (int32_t i = 0; i < N * 4; i++) img[i] = (uint8_t)(xrand() & 0xFF);

    /* ── Histogram: must be bit-exact ── */
    uint32_t cl[256], cr[256], cg[256], cb[256];
    uint32_t gl[256], gr[256], gg[256], gb[256];
    camera_pro_compute_histogram_rgba(img, W, H, W * 4, cl, cr, cg, cb);
    int32_t rc = camera_pro_metal_histogram(img, W, H, 0, gl, gr, gg, gb);
    CHECK(rc == CAMERA_OK, "GPU histogram returns OK");
    CHECK(memcmp(cl, gl, sizeof(cl)) == 0 && memcmp(cr, gr, sizeof(cr)) == 0 &&
          memcmp(cg, gg, sizeof(cg)) == 0 && memcmp(cb, gb, sizeof(cb)) == 0,
          "GPU histogram bit-exact vs CPU (random image)");

    /* ── Zebra: must be bit-exact ── */
    uint8_t* czeb = malloc((size_t)N * 4);
    uint8_t* gzeb = malloc((size_t)N * 4);
    camera_pro_compute_zebra(img, czeb, W, H, W * 4, 0, 0.72f, 7);
    rc = camera_pro_metal_zebra(img, gzeb, W, H, 0, 0.72f, 7);
    CHECK(rc == CAMERA_OK, "GPU zebra returns OK");
    CHECK(memcmp(czeb, gzeb, (size_t)N * 4) == 0, "GPU zebra bit-exact vs CPU");

    /* ── Focus peaking: <= 0.05% borderline mismatches allowed ── */
    uint8_t* cpk = malloc((size_t)N * 4);
    uint8_t* gpk = malloc((size_t)N * 4);
    camera_pro_compute_focus_peaking(img, cpk, W, H, W * 4, 0, 0.2f, 0x00FFFFFFu);
    rc = camera_pro_metal_focus_peaking(img, gpk, W, H, 0, 0.2f, 0x00FFFFFFu);
    CHECK(rc == CAMERA_OK, "GPU peaking returns OK");
    int64_t diff = 0;
    for (int32_t i = 0; i < N; i++) {
        if (memcmp(cpk + (size_t)i * 4, gpk + (size_t)i * 4, 4) != 0) diff++;
    }
    double pct = 100.0 * (double)diff / (double)N;
    printf("  peaking pixel mismatches: %lld / %d (%.4f%%)\n",
           (long long)diff, N, pct);
    CHECK(pct <= 0.05, "GPU peaking matches CPU within 0.05%");

    /* ── BGRA channel-order handling ── */
    camera_pro_compute_zebra(img, czeb, W, H, W * 4, 1, 0.72f, 7);
    rc = camera_pro_metal_zebra(img, gzeb, W, H, 1, 0.72f, 7);
    CHECK(rc == CAMERA_OK && memcmp(czeb, gzeb, (size_t)N * 4) == 0,
          "GPU zebra bit-exact vs CPU (BGRA order)");

    free(img); free(czeb); free(gzeb); free(cpk); free(gpk);
    printf("\n=== %s ===\n", g_fail == 0 ? "ALL GPU CHECKS PASSED" : "FAILURES");
    return g_fail == 0 ? 1 - 1 : 1;
}
