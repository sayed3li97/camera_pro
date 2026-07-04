# Apple HAL (iOS + macOS) — AVFoundation

Status: **live-verified on real Mac cameras ✅** — preview, PNG/RAW capture, H.264 recording, burst, bracketing, multi-camera, Metal GPU overlays. iOS sensor controls compile against the SDK (not yet run on a device).

This is the first real platform backend. One Objective-C file
([`camera_hal_apple.m`](camera_hal_apple.m)) implements the entire
[`camera_hal.h`](../../hal/camera_hal.h) contract against AVFoundation, shared
between iOS and macOS. It is compiled into the native-assets code asset for
Apple targets (see [`hook/build.dart`](../../../hook/build.dart)) and driven
from Dart by [`AppleCameraBackend`](../../../lib/src/platform/apple/apple_camera_backend.dart).

## What works today ✅

| Area | Status | Notes |
|---|---|---|
| Device enumeration | ✅ | `AVCaptureDeviceDiscoverySession`; returns name + lens position |
| Open / close | ✅ | Selects device, builds `AVCaptureSession` + input (no `startRunning`) |
| Capability query | ✅ | Reported honestly per platform (see below) |
| Manual ISO / shutter | ✅ iOS · ❌ macOS | `setExposureModeCustomWithDuration:ISO:` (iOS-only API) |
| Exposure compensation | ✅ iOS · ❌ macOS | `setExposureTargetBias:` |
| Manual focus (lens pos) | ✅ iOS · ❌ macOS | `setFocusModeLockedWithLensPosition:` |
| White balance (Kelvin) | ✅ iOS · ❌ macOS | `deviceWhiteBalanceGainsForTemperatureAndTintValues:` |
| Zoom | ✅ iOS · ❌ macOS | `videoZoomFactor` |
| Torch | ✅ iOS · ❌ macOS | `setTorchModeOnWithLevel:` |
| Live preview | ✅ | Frames copied over FFI into `dart:ui` (polled). Zero-copy `CVMetalTextureCache` → `TextureRegistry` is roadmap |
| Photo capture | ✅ | Frame-grab → PNG / linear-DNG + EXIF. Full-res `AVCapturePhotoOutput` still roadmap |
| Video recording | ✅ | `AVCaptureMovieFileOutput` → H.264 `.mov` (ffprobe-verified) |
| Burst / EV bracket | ✅ | Controller-level; verified (5-shot burst, −2/0/+2 bracket) |
| Metal GPU visual aids | ✅ | Runtime-compiled MSL histogram/peaking/zebra, bit-exact vs the C kernels |
| macOS manual controls | ✅ | Digital pipeline in the C core (see below) → `CameraTier.full` |

## The macOS ≠ iOS reality

AVFoundation's fine-grained manual controls (`minISO`/`maxISO`,
`min/maxExposureDuration`, `setExposureModeCustomWithDuration:ISO:`,
`setExposureTargetBias:`, `videoZoomFactor`, lens position, manual WB gains) are
declared `API_UNAVAILABLE(macos)` — they exist only on iOS/Mac Catalyst. So the
shared `.m` guards every one of them with `#if TARGET_OS_IOS`. On macOS the HAL
still enumerates devices and reports capabilities, but manual controls come back
as **unsupported**, which the Dart layer surfaces as `CameraTier.basic`. This is
correct behaviour, not a stub — a MacBook's FaceTime camera genuinely has no
manual exposure API.

## Verification

- **macOS (run):** `camera_hal_apple.m` + [`apple_hal_test.c`](apple_hal_test.c)
  compile and run against the real cameras on the build host (FaceTime HD
  Camera, external/virtual cameras), enumerating devices and reading
  capabilities. All harness checks pass.
- **macOS (Dart FFI):** [`test/ffi/apple_backend_test.dart`](../../../test/ffi/apple_backend_test.dart)
  drives `AppleCameraBackend` through `flutter test` — real enumeration +
  capability query end-to-end, verifying the tier degrades to `basic`.
- **iOS (compile):** the same `.m` compiles clean against the iPhoneOS SDK,
  proving the `TARGET_OS_IOS` manual-control branch builds. On-device behaviour
  needs a physical iPhone.

Build & run the native harness on a Mac:

```sh
clang -fobjc-arc -O2 -Wall -Wextra \
  src/platform/apple/camera_hal_apple.m src/platform/apple/apple_hal_test.c \
  -I src/core -I src/hal -I src/platform/apple \
  -framework AVFoundation -framework Foundation -framework CoreMedia -framework CoreVideo \
  -o apple_hal_test && ./apple_hal_test
```

## Finishing the backend

1. **Preview:** create an `AVCaptureVideoDataOutput`, bridge `CVPixelBuffer` →
   `CVMetalTexture`, register it with the Flutter `TextureRegistry` (a small
   Swift/ObjC plugin shim), and return the texture id from `camera_hal_open`.
2. **Capture:** add `AVCapturePhotoOutput` and implement `camera_hal_capture_photo`
   (JPEG/HEIF, then RAW/ProRAW).
3. **Video:** `AVCaptureMovieFileOutput` for `camera_hal_start/stop_recording`.
4. **Permissions:** request camera/mic authorization via the platform channel
   before `startRunning`.
5. Extend `AppleCameraBackend` to surface the new outputs.
