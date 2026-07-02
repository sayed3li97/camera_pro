/*
 * hal_lifecycle_test.c — Portable HAL lifecycle/conformance harness.
 *
 * Links against ANY camera_hal.h backend (stub, V4L2, Media Foundation,
 * AVFoundation) and exercises the paths that must be safe on a machine with
 * zero cameras: create, enumerate, callback registration, capability query on
 * an unopened context, NULL-context hardening, destroy. If a device is
 * present it additionally opens device 0 and prints its capability flags.
 *
 * Build & run (stub backend):
 *   gcc -std=c11 -Wall -Wextra -Werror -I src/hal -I src/core \
 *     src/platform/stub/camera_hal_stub.c src/tests/hal_lifecycle_test.c \
 *     -o hal_lifecycle_test && ./hal_lifecycle_test
 *
 * Verification status: compiled with -Wall -Wextra -Werror and run against
 * the stub backend (zero-device path); the count>0 hardware path is exercised
 * only on machines with a camera.
 *
 * Copyright (c) 2026 camera_pro contributors. BSD-3-Clause.
 */
#include "../hal/camera_hal.h"

#include <stdio.h>

static int g_failures = 0;
static int g_checks   = 0;

#define CHECK(cond, msg) do { \
    g_checks++; \
    if (!(cond)) { g_failures++; printf("  [FAIL] %s\n", msg); } \
    else         { printf("  [ ok ] %s\n", msg); } \
} while (0)

static void on_error(void* user_data, camera_error_t error, const char* message) {
    (void)user_data; (void)error; (void)message;
}

static void on_state(void* user_data, int32_t state) {
    (void)user_data; (void)state;
}

static void print_caps(const camera_capabilities_t* caps) {
    printf("  platform=%s device=%s hw_level=%d\n",
           caps->platform_name ? caps->platform_name : "(null)",
           caps->device_name ? caps->device_name : "(null)",
           caps->hardware_level);
    printf("  shutter=%d iso=%d focus=%d wb=%d ev=%d flash=%d torch=%d\n",
           (int)caps->shutter.supported, (int)caps->iso.supported,
           (int)caps->focus.supported, (int)caps->white_balance.supported,
           (int)caps->exposure_compensation.supported,
           (int)caps->flash.has_flash, (int)caps->flash.has_torch);
    printf("  raw=%d hdr=%d burst=%d depth=%d multi_cam=%d hevc=%d\n",
           (int)caps->advanced.supports_raw, (int)caps->advanced.supports_hdr,
           (int)caps->advanced.supports_burst, (int)caps->advanced.supports_depth,
           (int)caps->advanced.supports_multi_camera,
           (int)caps->video.supports_hevc);
}

int main(void) {
    printf("=== camera_pro HAL lifecycle test ===\n");

    camera_context_t* ctx = NULL;
    CHECK(camera_hal_create(&ctx) == CAMERA_OK, "create returns OK");
    CHECK(ctx != NULL, "create yields non-null context");
    if (!ctx) {
        printf("\n=== %d checks, %d failures ===\n", g_checks, g_failures);
        return 1;
    }

    int32_t count = -1;
    CHECK(camera_hal_enumerate_devices(ctx, &count) == CAMERA_OK, "enumerate returns OK");
    CHECK(count >= 0, "device count >= 0");
    printf("  devices found: %d\n", count);

    CHECK(camera_hal_set_error_callback(ctx, on_error, NULL) == CAMERA_OK, "set_error_callback");
    CHECK(camera_hal_set_state_callback(ctx, on_state, NULL) == CAMERA_OK, "set_state_callback");

    /* Capability query before open must not crash; several outcomes are legal. */
    camera_capabilities_t caps;
    camera_error_t rc = camera_hal_get_capabilities(ctx, &caps);
    CHECK(rc == CAMERA_OK || rc == CAMERA_ERROR_NOT_INITIALIZED ||
          rc == CAMERA_ERROR_INVALID_PARAMETER,
          "get_capabilities on unopened context is safe");

    /* NULL-context hardening: must return an error, never crash. */
    CHECK(camera_hal_set_iso(NULL, 100) != CAMERA_OK, "set_iso(NULL) returns error");
    CHECK(camera_hal_open(NULL, 0, 0) != CAMERA_OK, "open(NULL) returns error");

    if (count > 0) {
        printf("hardware path (device 0)\n");
        CHECK(camera_hal_open(ctx, 0, 0) == CAMERA_OK, "open device 0");
        CHECK(camera_hal_get_capabilities(ctx, &caps) == CAMERA_OK, "get_capabilities after open");
        print_caps(&caps);
        CHECK(camera_hal_close(ctx) == CAMERA_OK, "close");
    }

    CHECK(camera_hal_destroy(ctx) == CAMERA_OK, "destroy returns OK");
    CHECK(camera_hal_destroy(NULL) != CAMERA_OK, "destroy(NULL) returns error");

    printf("\n=== %d checks, %d failures ===\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
