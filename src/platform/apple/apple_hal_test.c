/*
 * apple_hal_test.c — Standalone harness for the AVFoundation HAL.
 *
 * Exercises the real backend against whatever camera the host has. On a Mac
 * this typically finds the built-in FaceTime/webcam and reports macOS's
 * (limited) manual-control capabilities. Build (macOS):
 *
 *   clang -fobjc-arc -ObjC \
 *     src/platform/apple/camera_hal_apple.mm src/platform/apple/apple_hal_test.c \
 *     -framework AVFoundation -framework Foundation -framework CoreMedia \
 *     -framework CoreVideo -o apple_hal_test && ./apple_hal_test
 *
 * Copyright (c) 2026 camera_pro contributors. BSD-3-Clause.
 */
#include "camera_hal_apple.h"

#include <stdio.h>
#include <string.h>

static int g_fail = 0;
#define CHECK(cond, msg) do { \
  if (!(cond)) { g_fail++; printf("  [FAIL] %s\n", msg); } \
  else         { printf("  [ ok ] %s\n", msg); } \
} while (0)

int main(void) {
  printf("=== camera_pro AVFoundation HAL harness ===\n");

  camera_context_t* ctx = NULL;
  CHECK(camera_hal_create(&ctx) == CAMERA_OK && ctx != NULL, "create context");

  int32_t count = -1;
  CHECK(camera_hal_enumerate_devices(ctx, &count) == CAMERA_OK, "enumerate devices");
  printf("  devices: %d\n", count);
  CHECK(count == camera_pro_apple_device_count(ctx), "device_count accessor matches");

  for (int32_t i = 0; i < count; i++) {
    char name[128];
    camera_pro_apple_device_name(ctx, i, name, sizeof(name));
    printf("    [%d] %s (position=%d)\n", i, name,
           camera_pro_apple_device_position(ctx, i));
  }

  if (count > 0) {
    CHECK(camera_hal_open(ctx, 0, 0) == CAMERA_OK, "open device 0");

    camera_pro_apple_caps_t caps;
    camera_pro_apple_get_caps(ctx, &caps);
    char plat[64], dev[128];
    camera_pro_apple_platform_name(ctx, plat, sizeof(plat));
    camera_pro_apple_active_device_name(ctx, dev, sizeof(dev));
    printf("  opened: %s [%s]\n", dev, plat);
    printf("  caps: iso_sup=%d [%d..%d] shutter_sup=%d focus_sup=%d ev_sup=%d "
           "zoom_sup=%d(max %.1f) flash=%d torch=%d\n",
           caps.iso_supported, caps.iso_min, caps.iso_max,
           caps.shutter_supported, caps.focus_supported, caps.ev_supported,
           caps.zoom_supported, caps.zoom_max, caps.has_flash, caps.has_torch);

    // The struct HAL query must agree with the flat accessor.
    camera_capabilities_t s;
    CHECK(camera_hal_get_capabilities(ctx, &s) == CAMERA_OK, "struct get_capabilities");
    CHECK((s.iso.supported ? 1 : 0) == caps.iso_supported, "struct/flat iso agree");
    CHECK(s.device_name != NULL && strlen(s.device_name) > 0, "device name populated");

    // A control that macOS cannot honour must fail cleanly (never crash).
    camera_error_t r = camera_hal_set_iso(ctx, 100);
    CHECK(r == CAMERA_OK || r == CAMERA_ERROR_FEATURE_NOT_SUPPORTED,
          "set_iso returns a defined result");

    CHECK(camera_hal_start_preview(ctx) == CAMERA_OK, "start preview");
    CHECK(camera_hal_close(ctx) == CAMERA_OK, "close");
  } else {
    printf("  (no camera on host — enumeration path still verified)\n");
  }

  CHECK(camera_hal_destroy(ctx) == CAMERA_OK, "destroy context");
  printf("\n=== %s ===\n", g_fail == 0 ? "ALL CHECKS PASSED" : "FAILURES");
  return g_fail == 0 ? 0 : 1;
}
