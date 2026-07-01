# Apple Platform HAL — iOS + macOS

> **🚧 STATUS: SCAFFOLDED — NOT IMPLEMENTED**
>
> This directory is reserved for the Apple (iOS + macOS) platform Hardware Abstraction Layer.
> **No native code exists here yet.** The SDK currently falls back to the conformant stub HAL
> (`src/platform/stub/camera_hal_stub.c`) on all Apple platforms. Every API call succeeds
> silently and returns no real camera data until this backend is wired.

---

## Table of Contents

1. [Project status](#1-project-status)
2. [Target architecture](#2-target-architecture)
3. [Shared iOS + macOS strategy](#3-shared-ios--macos-strategy)
4. [HAL contract to implement](#4-hal-contract-to-implement)
5. [Control mapping](#5-control-mapping)
6. [Zero-copy preview plan](#6-zero-copy-preview-plan)
7. [GPU compute (Metal)](#7-gpu-compute-metal)
8. [Thermal pressure mapping](#8-thermal-pressure-mapping)
9. [How to contribute this backend](#9-how-to-contribute-this-backend)

---

## 1. Project status

| Area | Status |
|---|---|
| `src/hal/camera_hal.h` contract (the C interface) | ✅ Defined |
| Stub HAL (`src/platform/stub/`) | ✅ Conformant, used today on all platforms |
| Apple HAL source files (`camera_hal_apple.mm`) | 🚧 Not created |
| AVFoundation session setup | 🚧 Not wired |
| Metal compute shaders | 🚧 Not written |
| CVMetalTextureCache → Flutter TextureRegistry | 🚧 Not wired |
| `hook/build.dart` Apple sources registered | 🚧 Not done |
| Dart `AppleCameraBackend` forwarding class | 🚧 Not written |
| End-to-end live preview on device | ❌ Not possible yet |

**Current behaviour on iOS / macOS**: `CameraPro.create()` returns a controller backed by the
stub HAL. `nativeCoreVersion` and all C-core processing functions (histogram, focus peaking,
zebra, YUV conversion) work via real FFI. Camera enumeration returns an empty list. `textureId`
is `null`. No frames are delivered.

---

## 2. Target architecture

```
┌──────────────────────────────────────────────────────────┐
│  Flutter Dart layer                                      │
│  CameraProController  ──►  AppleCameraBackend            │
│                               │  (FFI via native-assets) │
└───────────────────────────────┼──────────────────────────┘
                                │
┌───────────────────────────────▼──────────────────────────┐
│  camera_hal_apple.mm  (Objective-C++)                    │
│                                                          │
│  AVCaptureSession                                        │
│  AVCaptureDevice  ──►  AVCaptureVideoDataOutput          │
│        │                     │                           │
│        │               CVPixelBuffer (BGRA / 420f)       │
│        │                     │                           │
│        │           CVMetalTextureCache                   │
│        │                     │                           │
│  AVCapturePhotoOutput   MTLTexture (zero-copy)           │
│                               │                          │
│                     Flutter TextureRegistry              │
│                     (FlutterTextureRegistry)             │
└──────────────────────────────────────────────────────────┘
                                │
┌───────────────────────────────▼──────────────────────────┐
│  Metal compute (histogram / focus peaking / zebra)       │
│  Falls back to shared C core (SIMD NEON) when needed     │
└──────────────────────────────────────────────────────────┘
```

**Native language:** Objective-C++ (`.mm`). Swift interop is possible later but is not the
initial target because the C HAL boundary requires direct C-linkage functions.

**Frameworks required:**
- `AVFoundation` — camera session, device control, photo capture
- `Metal` + `MetalKit` — GPU compute for preview overlays
- `CoreVideo` — `CVMetalTextureCache`, `CVPixelBuffer`
- `CoreImage` — fallback processing if Metal not available
- `UIKit` (iOS) / `AppKit` (macOS) — for texture registration hooks

---

## 3. Shared iOS + macOS strategy

Both platforms expose AVFoundation and Metal with near-identical APIs since macOS 10.15
(Catalyst parity). A single `camera_hal_apple.mm` file is the target, with thin
`#if TARGET_OS_IPHONE` guards only where the API differs (for example, `UIDevice` thermal
notifications on iOS vs. `NSProcessInfo` thermal state on macOS).

**Known divergences to handle:**

| Feature | iOS | macOS |
|---|---|---|
| Thermal pressure | `AVCaptureDevice.systemPressureState` + `UIDevice.thermalState` | `NSProcessInfo.thermalState` |
| Front camera | `AVCaptureDevice.Position.front` | `AVCaptureDevice.deviceType .builtInWideAngleCamera` (Mac has no "front/back" concept on external cameras) |
| Lens position (manual focus) | `setFocusModeLockedWithLensPosition:completionHandler:` | Same — available on built-in cameras only |
| Continuity Camera (macOS 13+) | Not applicable | `AVCaptureDevice.DeviceType.continuityCamera` — enumerate separately |

---

## 4. HAL contract to implement

Every function declared in `src/hal/camera_hal.h` must have a non-stub implementation.
The full list of functions the Apple HAL must implement:

```c
/* Lifecycle */
camera_hal_error_t camera_hal_init(camera_hal_context_t **ctx, const camera_hal_config_t *cfg);
void               camera_hal_destroy(camera_hal_context_t *ctx);

/* Enumeration */
camera_hal_error_t camera_hal_enumerate_devices(camera_hal_context_t *ctx,
                                                 camera_device_info_t *out, uint32_t *count);

/* Session */
camera_hal_error_t camera_hal_open_device(camera_hal_context_t *ctx, const char *device_id);
camera_hal_error_t camera_hal_close_device(camera_hal_context_t *ctx);
camera_hal_error_t camera_hal_start_preview(camera_hal_context_t *ctx);
camera_hal_error_t camera_hal_stop_preview(camera_hal_context_t *ctx);

/* Capability query */
camera_hal_error_t camera_hal_get_capabilities(camera_hal_context_t *ctx,
                                                camera_hal_capabilities_t *out);

/* Control */
camera_hal_error_t camera_hal_set_shutter_speed_ns(camera_hal_context_t *ctx, int64_t ns);
camera_hal_error_t camera_hal_set_iso(camera_hal_context_t *ctx, int32_t iso);
camera_hal_error_t camera_hal_set_exposure_compensation(camera_hal_context_t *ctx, float ev);
camera_hal_error_t camera_hal_set_white_balance_temperature(camera_hal_context_t *ctx,
                                                              uint32_t kelvin);
camera_hal_error_t camera_hal_set_focus_distance(camera_hal_context_t *ctx, float normalised);
camera_hal_error_t camera_hal_set_zoom(camera_hal_context_t *ctx, float factor);
camera_hal_error_t camera_hal_set_flash_mode(camera_hal_context_t *ctx, int mode);

/* Capture */
camera_hal_error_t camera_hal_capture_photo(camera_hal_context_t *ctx,
                                             int image_format,
                                             camera_hal_photo_callback_t cb, void *user_data);

/* Frame callback registration */
camera_hal_error_t camera_hal_set_frame_callback(camera_hal_context_t *ctx,
                                                   camera_hal_frame_callback_t cb,
                                                   void *user_data);

/* Texture */
camera_hal_error_t camera_hal_get_texture_id(camera_hal_context_t *ctx, int64_t *texture_id_out);

/* Thermal */
camera_hal_thermal_level_t camera_hal_get_thermal_level(camera_hal_context_t *ctx);
```

The stub implementation in `src/platform/stub/camera_hal_stub.c` shows the required
function signatures and return-value conventions. Match them exactly.

---

## 5. Control mapping

The table below describes how each Dart-level setter maps to the AVFoundation API. All
`AVCaptureDevice` configuration must be wrapped in `lockForConfiguration:` /
`unlockForConfiguration`.

| Dart API | HAL function | AVFoundation call |
|---|---|---|
| `setShutterSpeed(ShutterSpeed)` | `camera_hal_set_shutter_speed_ns` | `setExposureModeCustomWithDuration:ISO:completionHandler:` — pass `CMTimeMakeWithSeconds(ns / 1e9, NSEC_PER_SEC)` for duration; pass `AVCaptureISOCurrent` to leave ISO unchanged |
| `setIso(Iso)` | `camera_hal_set_iso` | `setExposureModeCustomWithDuration:ISO:completionHandler:` — pass `AVCaptureExposureDurationCurrent` for duration; pass the ISO float value |
| `setExposureCompensation(Ev)` | `camera_hal_set_exposure_compensation` | `setExposureTargetBias:completionHandler:` — value is clamped to `[minExposureTargetBias, maxExposureTargetBias]` |
| `setWhiteBalance(WhiteBalance.temperature(k))` | `camera_hal_set_white_balance_temperature` | `setWhiteBalanceModeLockedWithDeviceWhiteBalanceGains:completionHandler:` with gains from `deviceWhiteBalanceGainsForTemperatureAndTintValues:` (tint = 0 default) |
| `setWhiteBalance(WhiteBalance.preset(mode))` | `camera_hal_set_white_balance_temperature` | Set `whiteBalanceMode` to `AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance` (auto) or lock with preset-derived gains |
| `setFocusDistance(double)` | `camera_hal_set_focus_distance` | `setFocusModeLockedWithLensPosition:completionHandler:` — value is normalised `0.0` (near) … `1.0` (far), maps directly to AVFoundation `lensPosition` |
| `setZoom(double)` | `camera_hal_set_zoom` | `videoZoomFactor` property; clamp to `[minAvailableVideoZoomFactor, maxAvailableVideoZoomFactor]` |
| `setFlashMode(FlashMode)` | `camera_hal_set_flash_mode` | `AVCapturePhotoSettings.flashMode` set at capture time (`.auto`, `.on`, `.off`) |
| Capability query | `camera_hal_get_capabilities` | Read `activeFormat.videoSupportedFrameRateRanges`, `minISO`/`maxISO`, `minExposureTargetBias`/`maxExposureTargetBias`, `isAdjustingFocus`, `minAvailableVideoZoomFactor` etc. |

**Important notes:**

- `setExposureModeCustomWithDuration:ISO:` requires `AVCaptureExposureModeCustom`. If the
  device only supports `.continuousAutoExposure`, the HAL must return
  `CAMERA_HAL_ERROR_NOT_SUPPORTED` and the Dart layer will surface a
  `CameraFeatureNotSupportedError`.
- `lensPosition` requires `AVCaptureFocusModeLocked`. The HAL must switch focus mode before
  calling `setFocusModeLockedWithLensPosition:`.
- White-balance temperature conversion via `deviceWhiteBalanceGainsForTemperatureAndTintValues:`
  returns `AVCaptureWhiteBalanceGains`; clamp each channel to `[1.0, maxWhiteBalanceGain]` before
  passing to `setWhiteBalanceModeLockedWithDeviceWhiteBalanceGains:`.

---

## 6. Zero-copy preview plan

The target preview path avoids any CPU-side pixel copy:

```
AVCaptureVideoDataOutput
  └─► captureOutput:didOutputSampleBuffer:  (dispatch_queue)
        └─► CVPixelBufferRef  (kCVPixelFormatType_32BGRA or 420f)
              └─► CVMetalTextureCacheCreateTextureFromImage
                    └─► MTLTexture  (no copy — wraps the same IOSurface)
                          └─► FlutterTextureRegistry.registerTexture
                                └─► textureId  → Dart controller.textureId
```

`CVMetalTextureCache` holds a pool of `MTLTexture` wrappers backed by the same
`IOSurface` memory that AVFoundation writes into. `[registry textureFrameAvailable:textureId]`
notifies Flutter to composite the new frame. No pixel data crosses the CPU ↔ GPU boundary.

Frame processing overlays (histogram, focus peaking, zebra) will run as Metal compute shaders
(see section 7) on the same `MTLTexture` before signalling Flutter, keeping the entire
preview pipeline on the GPU.

---

## 7. GPU compute (Metal)

The shared C core already provides scalar and NEON-SIMD implementations of histogram,
focus peaking, and zebra. On Apple platforms the target is to replace these with Metal
compute shaders operating on the `MTLTexture` directly, so no readback to CPU memory is
needed for overlay rendering.

Planned shader files (not yet written):

```
src/platform/apple/
  shaders/
    histogram.metal          # parallel reduction → histogram buffer
    focus_peaking.metal      # Sobel on luma, threshold, overlay colour
    zebra.metal              # luma threshold → striped overlay
```

**Fallback:** If Metal is unavailable (simulator, old hardware) or the texture is not
Metal-backed, the implementation must fall back to the C-core scalar path by reading the
`CVPixelBuffer` CPU-side. The fallback must be transparent to the Dart API.

---

## 8. Thermal pressure mapping

The Dart `ThermalLevel` enum (`nominal`, `fair`, `serious`, `critical`) maps to Apple
thermal state values as follows:

| `ThermalLevel` (Dart) | iOS (`UIDevice.thermalState`) | macOS (`NSProcessInfo.thermalState`) | AVFoundation (`systemPressureState.level`) |
|---|---|---|---|
| `nominal` | `.nominal` | `.nominal` | `.nominal` |
| `fair` | `.fair` | `.fair` | `.fair` |
| `serious` | `.serious` | `.serious` | `.serious` |
| `critical` | `.critical` | `.critical` | `.critical` / `.shutdown` |

The HAL implementation of `camera_hal_get_thermal_level` should prefer
`AVCaptureDevice.systemPressureState.level` (iOS 11.1+, the most camera-specific signal)
and fall back to `[UIDevice currentDevice].thermalState` (iOS) or
`[NSProcessInfo processInfo].thermalState` (macOS) when the device is not open.

The Dart `ThermalPolicy` layer then throttles frame rate or disables features automatically
based on `ThermalLevel`. This logic already exists in the Dart control plane; the HAL only
needs to supply the correct level.

---

## 9. How to contribute this backend

Follow these steps to implement the Apple HAL from scratch.

### Step 1 — Create the source file

```
src/platform/apple/camera_hal_apple.mm
```

Implement every function from `src/hal/camera_hal.h` (listed in section 4). Use the stub
at `src/platform/stub/camera_hal_stub.c` as a template for function signatures, error
constants, and return-value conventions.

### Step 2 — Register sources in `hook/build.dart`

The native-assets hook must conditionally compile `camera_hal_apple.mm` on Apple targets
and link the required frameworks:

```dart
// Inside hook/build.dart, add approximately:
if (target.os == OS.iOS || target.os == OS.macOS) {
  sources.add('src/platform/apple/camera_hal_apple.mm');
  // Remove stub source for this target
  frameworksToLink.addAll([
    'AVFoundation', 'Metal', 'MetalKit', 'CoreVideo', 'CoreMedia', 'CoreImage',
  ]);
  if (target.os == OS.iOS) frameworksToLink.add('UIKit');
  if (target.os == OS.macOS) frameworksToLink.add('AppKit');
}
```

Exact `NativeToolchain` and `CBuilder` API calls depend on the `native_toolchain_c` version
in use. Consult `hook/build.dart` for the current pattern.

### Step 3 — Write a Dart `AppleCameraBackend`

Create `lib/src/platform/apple_camera_backend.dart` implementing the `CameraBackend`
interface. It should mirror `StubCameraBackend` but dispatch to the compiled Apple HAL
via the existing FFI bindings in `lib/src/ffi/`.

```dart
// Approximate structure — not the real file yet
class AppleCameraBackend implements CameraBackend {
  @override
  Future<List<CameraDevice>> enumerateDevices() async {
    // Call camera_hal_enumerate_devices via FFI
  }
  // ... all other CameraBackend methods
}
```

### Step 4 — Wire platform detection in `CameraPro.create()`

`lib/src/controller/camera_pro.dart` (the `CameraPro` static factory) should select
`AppleCameraBackend` when `Platform.isIOS || Platform.isMacOS` and no explicit backend
is provided.

### Step 5 — Test

Add integration tests under `test/` or `example/integration_test/` that run on a real
device (simulator has no camera for most tests). Verify:

- `availableCameras()` returns at least one device.
- `CameraProController.textureId` is non-null after `startPreview`.
- Each capability-guarded setter either succeeds or throws a typed `CameraProError`.
- Thermal level reports `ThermalLevel.nominal` at rest.

### Step 6 — Update capability passport

Once the Apple HAL returns real `camera_hal_capabilities_t` data, verify that
`determineTier(capabilities)` returns `CameraTier.full` on a modern iPhone/Mac with
a built-in camera.

---

## Minimum deployment targets (planned)

| Platform | Minimum OS | Reason |
|---|---|---|
| iOS | 16.0 | `AVCaptureDevice.systemPressureState` stable; Metal 3 widespread |
| macOS | 13.0 | Continuity Camera API; `NSProcessInfo.thermalState` reliable |

These are targets only; they may be revised when the implementation is written.

---

*This README describes planned architecture. Nothing in this directory is implemented.
All camera functionality on Apple platforms today is provided by the stub HAL.*
