# camera_pro — Platform Guide

This document describes the per-platform capabilities, intended native API mappings, and current implementation status for `camera_pro` v0.1.0. It is written against the **initial foundation commit**; the shared C core and Dart control-plane are complete and verified, but every platform HAL listed here is 🚧 scaffolded — the API contract exists, the native side is not yet wired.

---

## Project Status

| Layer | Status |
|---|---|
| Shared C core (histogram, buffer pool, YUV→RGBA, focus peaking, zebra) | ✅ Implemented & verified (36/36 C tests, NEON cross-checked) |
| Dart control-plane (capability passport, state machine, typed errors, tier selection, controller) | ✅ Implemented & verified (59 Dart tests, `flutter analyze` clean) |
| Native-assets FFI build wiring (`hook/build.dart`) | ✅ Compiles `libcamera_pro_core` automatically on `flutter test`/`flutter run` |
| Conformant stub HAL (`StubCameraBackend`) | ✅ Passes all tests; degrades every platform to `CameraTier.basic` |
| All real platform HALs (Android, iOS/macOS, Windows, Linux, Web) | 🚧 Scaffolded — C interface designed, not implemented |
| GPU compute shaders (Metal, Vulkan, D3D11, WebGPU) | 🚧 Designed, not implemented |
| libyuv / libjpeg-turbo integration | 🚧 Not integrated |
| RAW/DNG + EXIF (libtiff / libexif) | 🚧 Not integrated |
| Video recording, live streaming, multi-camera, burst/HDR, frame processors | ❌ Not started |

---

## Platform × Capability Matrix

| Platform | Backend API planned | GPU compute planned | Manual controls expected | Current status |
|---|---|---|---|---|
| **Android** | NDK Camera2 (`ACameraManager`, `ACameraDevice`) | Vulkan compute | ISO, Shutter, EV, WB, Focus, Zoom, Flash | 🚧 HAL scaffolded, not wired |
| **iOS** | AVFoundation (`AVCaptureDevice`) | Metal compute | ISO, Shutter, EV, WB, Focus, Zoom, Flash | 🚧 HAL scaffolded, not wired |
| **macOS** | AVFoundation (`AVCaptureDevice`) | Metal compute | ISO, Shutter, EV, WB, Focus, Zoom (USB cams limited) | 🚧 HAL scaffolded, not wired |
| **Windows** | Media Foundation (`IMFSourceReader`, `IMFMediaSource`) | D3D11 compute | EV, WB, Zoom; ISO/Shutter device-dependent | 🚧 HAL scaffolded, not wired |
| **Linux** | V4L2 (`v4l2_queryctrl`, `VIDIOC_S_CTRL`) | Vulkan compute | EV, WB, Focus; ISO/Shutter device-dependent | 🚧 HAL scaffolded, not wired |
| **Web** | `MediaDevices.getUserMedia()` + `ImageCapture` API | WebGPU compute | EV, WB, Zoom (browser-permitting); ISO/Shutter limited | 🚧 HAL scaffolded, not wired |

---

## Three-Tier Degradation

`camera_pro` uses a three-tier model to degrade gracefully across the wide range of hardware and platform capability levels it targets.

```
CameraTier.full      — all professional controls available
CameraTier.standard  — core controls available; some advanced features absent
CameraTier.basic     — minimal controls only (EV compensation, flash, zoom)
```

### How `determineTier` Works

`determineTier(CameraCapabilities caps)` inspects the **capability passport** returned by the real HAL (or stub) and applies the following logic (source of truth: `lib/src/controller/`):

1. **`CameraTier.full`** — requires `Supported` for: `shutterSpeed`, `iso`, `whiteBalanceKelvin`, `focusDistance`, plus `supportsRawCapture == true`.
2. **`CameraTier.standard`** — requires `Supported` for: `shutterSpeed`, `iso`, and `whiteBalanceKelvin` (RAW not required).
3. **`CameraTier.basic`** — fallback; applies when fewer than the `standard` requirements are met.

Each `Capability<T>` is a sealed type:

```dart
switch (controller.capabilities.iso) {
  case Supported<int>(:final minValue, :final maxValue, :final currentValue):
    // show ISO slider from minValue to maxValue
  case NotSupported<int>(:final reason):
    // disable ISO control, show reason string
}
```

The Dart controller guards every setter against its corresponding capability at runtime:

```dart
try {
  await controller.setIso(const Iso(800));
} on CameraFeatureNotSupportedError catch (e) {
  // typed error, never a crash
}
```

### Stub Backend and Tier Today

`StubCameraBackend` returns `CameraCapabilities.unsupported()` for all fields, which causes `determineTier` to return `CameraTier.basic` unconditionally. This is the only tier achievable until a real platform HAL is wired. Calls to capability-guarded setters on the stub throw `CameraFeatureNotSupportedError` with a clear reason string.

---

## Per-Platform Detail

### Android — NDK Camera2

**Planned backend:** `ACameraManager` / `ACameraDevice` / `ACaptureRequest` via NDK.

| Dart control | Intended Android mapping |
|---|---|
| `setIso(Iso)` | `ACAMERA_SENSOR_SENSITIVITY` |
| `setShutterSpeed(ShutterSpeed)` | `ACAMERA_SENSOR_EXPOSURE_TIME` (nanoseconds) |
| `setExposureCompensation(Ev)` | `ACAMERA_CONTROL_AE_EXPOSURE_COMPENSATION` |
| `setWhiteBalance(WhiteBalance)` | `ACAMERA_CONTROL_AWB_MODE` / `ACAMERA_COLOR_CORRECTION_GAINS` |
| `setFocusDistance(double)` | `ACAMERA_LENS_FOCUS_DISTANCE` |
| `setZoom(double)` | `ACAMERA_CONTROL_ZOOM_RATIO` (API 30+) or crop-region |
| `setFlashMode(FlashMode)` | `ACAMERA_FLASH_MODE` |
| `capturePhoto(format: ImageFormat.raw)` | `AIMAGE_FORMAT_RAW16` (target; libtiff not yet integrated) |

**GPU compute target:** Vulkan compute shaders for histogram, focus peaking, and zebra overlays (replacing scalar C fallback at runtime).

**Current status:** 🚧 `camera_hal.h` interface designed; `camera_hal_stub.c` is the only active HAL. No JNI or NDK linkage exists yet.

---

### iOS — AVFoundation + Metal

**Planned backend:** `AVCaptureSession` / `AVCaptureDevice` / `AVCapturePhotoOutput` bridged to C via a thin Objective-C++ shim.

| Dart control | Intended iOS mapping |
|---|---|
| `setIso(Iso)` | `AVCaptureDevice.setExposureModeCustom(duration:ISO:)` |
| `setShutterSpeed(ShutterSpeed)` | `AVCaptureDevice.setExposureModeCustom(duration:ISO:)` — `CMTime` duration |
| `setExposureCompensation(Ev)` | `AVCaptureDevice.setExposureTargetBias(_:completionHandler:)` |
| `setWhiteBalance(WhiteBalance)` | `AVCaptureDevice.setWhiteBalanceModeLocked(with:)` — `AVCaptureDevice.WhiteBalanceGains` |
| `setFocusDistance(double)` | `AVCaptureDevice.setFocusModeLocked(lensPosition:)` |
| `setZoom(double)` | `AVCaptureDevice.videoZoomFactor` |
| `setFlashMode(FlashMode)` | `AVCapturePhotoSettings.flashMode` |
| `capturePhoto(format: ImageFormat.raw)` | `AVCapturePhotoSettings(rawPixelFormatType:)` (target; libtiff not integrated) |

**GPU compute target:** Metal compute shaders invoked from the C core via a Metal context pointer; histogram and overlay kernels are designed targets.

**Current status:** 🚧 HAL interface defined; Objective-C++ shim not written; Metal pipeline not wired.

---

### macOS — AVFoundation + Metal

macOS shares the AVFoundation API with iOS but with notable differences:

- External USB/Thunderbolt cameras may not expose manual ISO or shutter; `determineTier` will return `CameraTier.basic` for those devices.
- `videoZoomFactor` may be unavailable on some built-in FaceTime cameras; zoom would fall back to `NotSupported`.
- The Metal compute path is identical to iOS (same GPU family on Apple Silicon).

| Dart control | Intended macOS mapping | Notes |
|---|---|---|
| `setIso` / `setShutterSpeed` | Same as iOS | USB cameras often `NotSupported` |
| `setZoom` | `videoZoomFactor` or `NotSupported` | Device-dependent |
| All others | Same as iOS | — |

**Current status:** 🚧 Shared with iOS scaffolding; not wired.

---

### Windows — Media Foundation

**Planned backend:** `IMFSourceReader` for frame acquisition; `IAMCameraControl` / `IAMVideoProcAmp` for control properties; Direct3D 11 for GPU overlays.

| Dart control | Intended Windows mapping |
|---|---|
| `setExposureCompensation(Ev)` | `IAMVideoProcAmp::Set(VideoProcAmp_Gain, ...)` |
| `setWhiteBalance(WhiteBalance)` | `IAMVideoProcAmp::Set(VideoProcAmp_WhiteBalance, ...)` |
| `setZoom(double)` | `IAMCameraControl::Set(CameraControl_Zoom, ...)` |
| `setIso(Iso)` | No universal MF mapping — device-specific via `IKsPropertySet` (target) |
| `setShutterSpeed(ShutterSpeed)` | `IAMCameraControl::Set(CameraControl_Exposure, ...)` where supported |
| `setFlashMode(FlashMode)` | `IKsPropertySet` vendor extension (target) |

ISO and raw shutter are expected to reach only `CameraTier.standard` on most Windows webcams; RAW capture is unlikely on consumer hardware, keeping tier at `standard` or `basic`.

**GPU compute target:** D3D11 compute shaders for real-time overlays.

**Current status:** 🚧 HAL interface defined; MF linkage not written; no COM calls exist.

---

### Linux — V4L2

**Planned backend:** `/dev/videoN` via `v4l2_queryctrl` / `VIDIOC_G_CTRL` / `VIDIOC_S_CTRL`.

| Dart control | Intended V4L2 mapping |
|---|---|
| `setExposureCompensation(Ev)` | `V4L2_CID_EXPOSURE_ABSOLUTE` |
| `setWhiteBalance(WhiteBalance)` | `V4L2_CID_WHITE_BALANCE_TEMPERATURE` / `V4L2_CID_AUTO_WHITE_BALANCE` |
| `setFocusDistance(double)` | `V4L2_CID_FOCUS_ABSOLUTE` |
| `setZoom(double)` | `V4L2_CID_ZOOM_ABSOLUTE` |
| `setIso(Iso)` | `V4L2_CID_ISO_SENSITIVITY` (v4l2 ext-ctrls; not all drivers) |
| `setShutterSpeed(ShutterSpeed)` | `V4L2_CID_EXPOSURE_ABSOLUTE` (µs units; driver-dependent) |
| `setFlashMode(FlashMode)` | `V4L2_CID_FLASH_LED_MODE` (flash class controls) |

All V4L2 controls will be discovered at runtime via `VIDIOC_QUERYCTRL`; unsupported controls produce `NotSupported` capability entries, so tier degradation is fully dynamic per device.

**GPU compute target:** Vulkan compute (same target as Android).

**Current status:** 🚧 HAL interface defined; no ioctl calls exist; no `/dev/video` enumeration.

---

### Web — MediaDevices / WebGPU

**Planned backend:** `MediaDevices.getUserMedia()` for stream acquisition; `ImageCapture` API for still capture and manual controls; WebGPU compute for GPU overlays.

| Dart control | Intended Web mapping |
|---|---|
| `setExposureCompensation(Ev)` | `ImageCapture.applyConstraints({ exposureCompensation })` |
| `setWhiteBalance(WhiteBalance)` | `ImageCapture.applyConstraints({ whiteBalanceMode, colorTemperature })` |
| `setZoom(double)` | `MediaTrackConstraints.zoom` (Chrome 87+) |
| `setIso(Iso)` | `ImageCapture` `iso` constraint (limited browser support) |
| `setShutterSpeed(ShutterSpeed)` | `ImageCapture` `exposureTime` constraint (limited browser support) |
| `setFlashMode(FlashMode)` | `ImageCapture` `fillLightMode` |

The `ImageCapture` API has inconsistent support across browsers. ISO and manual shutter are not widely available; the web platform is expected to reach at most `CameraTier.standard` on Chrome and `CameraTier.basic` on Firefox/Safari in practice.

**GPU compute target:** WebGPU compute shaders compiled from WGSL; falls back to scalar C core (via Wasm) when WebGPU is unavailable.

**Current status:** 🚧 HAL interface defined; no JS interop written; no `dart:js_interop` calls exist.

---

## HAL Contract

All platform backends implement `src/hal/camera_hal.h`. The conformant stub (`src/platform/stub/camera_hal_stub.c`) is the reference implementation and the only active backend today. A real HAL implementation must:

1. Populate a `camera_hal_capabilities_t` struct with accurate min/max/step values for each control, or mark them unsupported.
2. Implement all function pointers in `camera_hal_ops_t` (open, close, set_control, capture_frame, etc.).
3. Be registered with `CameraBackend` on the Dart side and passed to `CameraPro.create(backend: myBackend)`.

Until a real HAL is registered, every call routes to the stub, capabilities report `unsupported`, and the controller tier is `CameraTier.basic`.

---

## See Also

- `README.md` — quick-start and overall package overview
- `ARCHITECTURE.md` — layered design, C core internals, FFI wiring
- `src/hal/camera_hal.h` — the C platform-abstraction contract every HAL must satisfy
- `src/platform/stub/camera_hal_stub.c` — conformant reference HAL
- `hook/build.dart` — native-assets build hook
