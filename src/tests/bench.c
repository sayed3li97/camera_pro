/*
 * bench.c — Measured performance of the C core kernels.
 *
 * Times each kernel over a 1920x1080 RGBA frame (median of 31 runs). These are
 * the MEASURED numbers behind the README performance table — rerun on your own
 * hardware:
 *
 *   clang -std=c11 -O2 -I src/core -I src/hal src/core/[a-z]*.c \
 *     src/platform/stub/camera_hal_stub.c src/tests/bench.c -o bench && ./bench
 *
 * Copyright (c) 2026 camera_pro contributors. BSD-3-Clause.
 */
#include "camera_pro_core.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define W 1920
#define H 1080
#define RUNS 31

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1e3 + (double)ts.tv_nsec / 1e6;
}

static int cmp_d(const void* a, const void* b) {
    double x = *(const double*)a, y = *(const double*)b;
    return x < y ? -1 : (x > y ? 1 : 0);
}

#define BENCH(label, ...) do { \
    double t[RUNS]; \
    for (int run = 0; run < RUNS; run++) { \
        double t0 = now_ms(); \
        __VA_ARGS__; \
        t[run] = now_ms() - t0; \
    } \
    qsort(t, RUNS, sizeof(double), cmp_d); \
    printf("%-34s %8.3f ms/frame  (%.1f fps)\n", label, t[RUNS/2], \
           1000.0 / t[RUNS/2]); \
} while (0)

int main(void) {
    printf("camera_pro C core — %dx%d, median of %d runs, SIMD: %s\n\n",
           W, H, RUNS, camera_pro_simd_name());

    uint8_t* img = malloc((size_t)W * H * 4);
    uint8_t* out = malloc((size_t)W * H * 4);
    uint32_t rng = 0x1234567u;
    for (size_t i = 0; i < (size_t)W * H * 4; i++) {
        rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5;
        img[i] = (uint8_t)rng;
    }
    uint32_t l[256], r[256], g[256], b[256];
    uint32_t* wf = malloc(256 * 256 * sizeof(uint32_t));

    BENCH("histogram (SIMD)",
          camera_pro_compute_histogram_rgba(img, W, H, W * 4, l, r, g, b));
    BENCH("histogram (scalar reference)",
          camera_pro_compute_histogram_rgba_scalar(img, W, H, W * 4, l, r, g, b));
    BENCH("focus peaking (Sobel)",
          camera_pro_compute_focus_peaking(img, out, W, H, W * 4, 0, 0.2f, 0x00FFFFFFu));
    BENCH("zebra",
          camera_pro_compute_zebra(img, out, W, H, W * 4, 0, 0.9f, 0));
    BENCH("false color",
          camera_pro_compute_false_color(img, out, W, H, W * 4, 0));
    BENCH("waveform (256 cols)",
          camera_pro_compute_luma_waveform(img, W, H, W * 4, 0, wf, 256));
    BENCH("digital adjust (gain+EV+WB)",
          camera_pro_adjust_pixels(out, W, H, W * 4, 0, 1.5f, 10.f, 0.3f, 1.0f));
    BENCH("digital zoom 2x",
          camera_pro_digital_zoom(img, out, W, H, W * 4, 2.0f));
    BENCH("box blur r=6",
          camera_pro_box_blur(out, W, H, W * 4, 6));

    /* YUV → RGBA over equivalent pixel count */
    uint8_t* yp = malloc((size_t)W * H);
    uint8_t* up = malloc((size_t)(W / 2) * (H / 2));
    uint8_t* vp = malloc((size_t)(W / 2) * (H / 2));
    memset(yp, 128, (size_t)W * H);
    memset(up, 100, (size_t)(W / 2) * (H / 2));
    memset(vp, 160, (size_t)(W / 2) * (H / 2));
    BENCH("YUV420P -> RGBA (SIMD+tail)",
          camera_pro_yuv420p_to_rgba(yp, up, vp, W, W / 2, out, W, H));

    free(img); free(out); free(wf); free(yp); free(up); free(vp);
    return 0;
}
