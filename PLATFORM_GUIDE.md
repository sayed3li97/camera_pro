# camera_pro — Platform Guide

This document describes the per-platform capabilities, native API mappings, and current implementation status for `camera_pro` v0.0.1. The shared C core and Dart control-plane are complete and verified; the Apple (macOS/iOS) and Web backends are implemented and live-verified; the Linux and Windows C HALs are fully implemented and CI-verified (Dart wiring pending); Android has not been started.

---

## Project Status

| Layer | Status |
|---|---|
| Shared C core (histogram, buffer pool, YUV→RGBA, focus peaking, zebra, false color, waveform, digital adjust/zoom/blur) | ✅ Implemented & verified (60-check C harness passing on arm64 **and** x86_64-under-Rosetta; NEON + SSSE3 SIMD bit-exact vs scalar; measured `bench.c` numbers) |
| Dart control-plane (capability passport, state machine, typed errors, tier selection, controller, burst/bracket, `FrameProcessor` API, quirks DB) | ✅ Implemented & verified (80 VM Dart tests + 65 browser tests, `flutter analyze` clean, dartdoc 0 warnings) |
| Native-assets FFI build wiring (`hook/build.dart`) | ✅ Compiles `libcamera_pro_core` automatically on `flutter test`/`flutter run` |
| Conformant stub HAL (`StubCameraBackend`) | ✅ Passes all tests; fallback for platforms without a wired Dart backend |
| Apple AVFoundation backend (macOS/iOS) | ✅ Implemented, live-verified on real Mac cameras (preview, capture, RAW DNG, H.264 video, burst, bracketing, multi-camera) |
| Web backend (`WebCameraBackend`, getUserMedia) | ✅ Implemented, live-verified in Chrome (full tier via pure-Dart digital pipeline) |
| Linux V4L2 + Windows Media Foundation C HALs | ✅ Full 44-function HAL contract implemented; compile with `-Werror` / `/W4` and pass the lifecycle harness on CI runners every push. 🚧 Dart backend wiring pending; not yet run against real camera hardware |
| Android backend | ❌ Not started (gated on hardware for honest verification) |
| GPU compute shaders | ✅ Metal (runtime-compiled MSL histogram/peaking/zebra, bit-exact vs C on Apple M1 Pro, auto GPU/CPU dispatch); 🚧 Vulkan / D3D11 / WebGPU not implemented |
| RAW/DNG + EXIF | ✅ Dependency-free linear-DNG writer with EXIF (C core + pure-Dart web port, both ffmpeg-verified) |
| Video recording, multi-camera, burst/bracketing, frame processors | ✅ Implemented & verified (H.264 `.mov` ffprobe-verified on macOS; MediaRecorder on web) |
| Live streaming transport (RTMP/SRT), HDR fusion | ❌ Not implemented — `StreamConfig`/`StreamStatus` API surface exists, transport throws a typed error |

---

## Platform × Capability Matrix

| Platform | Backend API | GPU compute | Manual controls | Current status |
|---|---|---|---|---|
| **Android** | NDK Camera2 (`ACameraManager`, `ACameraDevice`) — planned | Vulkan compute — planned | ISO, Shutter, EV, WB, Focus, Zoom, Flash | ❌ Not started (gated on hardware for honest verification) |
| **iOS** | AVFoundation (`AVCaptureDevice`) | Metal compute | ISO, Shutter, EV, WB gains, Focus, Zoom, Torch (real sensor controls) | ✅ Backend implemented, compiles for iOS; 🚧 not yet run on a physical iPhone |
| **macOS** | AVFoundation (`AVCaptureDevice`) | Metal compute (bit-exact vs C, verified on M1 Pro) | All six controls via C-core digital pipeline → `CameraTier.full` | ✅ Live-verified on real Mac cameras |
| **Windows** | Media Foundation (`IMFSourceReader`, `IMFMediaSource`) | D3D11 compute — planned | EV, WB, Zoom; ISO/Shutter device-dependent | ✅ Full C HAL, CI-verified compile + lifecycle; 🚧 Dart wiring pending, no real-hardware run yet |
| **Linux** | V4L2 (`v4l2_queryctrl`, `VIDIOC_S_CTRL`) | Vulkan compute — planned | EV, WB, Focus; ISO/Shutter device-dependent | ✅ Full C HAL, CI-verified compile + lifecycle; 🚧 Dart wiring pending, no real-hardware run yet |
| **Web** | `MediaDevices.getUserMedia()` via `package:web` | Pure-Dart kernels (byte-identical to C); WebGPU — planned | All six controls via pure-Dart digital pipeline → `CameraTier.full` | ✅ Live-verified in Chrome |

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

`StubCameraBackend` returns `CameraCapabilities.unsupported()` for all fields, which causes `determineTier` to return `CameraTier.basic` unconditionally. Calls to capability-guarded setters on the stub throw `CameraFeatureNotSupportedError` with a clear reason string.

The stub is now the fallback only for platforms without a wired Dart backend: Android (backend not started) and desktop Linux/Windows (the C HALs are complete, but the Dart `CameraBackend` wiring is pending). On macOS the Apple backend reaches `CameraTier.full` via the C-core digital pipeline (verified live), and on the web the pure-Dart digital pipeline likewise reaches `CameraTier.full` (verified live in Chrome).

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
| `capturePhoto(format: ImageFormat.raw)` | `AIMAGE_FORMAT_RAW16` (target; will feed the built-in dependency-free linear-DNG writer) |

**GPU compute target:** Vulkan compute shaders for histogram, focus peaking, and zebra overlays (replacing scalar C fallback at runtime).

**Current status:** ❌ Not started — deliberately gated on physical Android hardware so every claim can be honestly verified. `camera_hal.h` interface is designed; no JNI or NDK linkage exists yet; Android falls back to the stub.

---

### iOS — AVFoundation + Metal

**Backend:** `AVCaptureSession` / `AVCaptureDevice` bridged to C via a thin Objective-C++ shim — implemented.

| Dart control | iOS mapping |
|---|---|
| `setIso(Iso)` | `AVCaptureDevice.setExposureModeCustom(duration:ISO:)` |
| `setShutterSpeed(ShutterSpeed)` | `AVCaptureDevice.setExposureModeCustom(duration:ISO:)` — `CMTime` duration |
| `setExposureCompensation(Ev)` | `AVCaptureDevice.setExposureTargetBias(_:completionHandler:)` |
| `setWhiteBalance(WhiteBalance)` | `AVCaptureDevice.setWhiteBalanceModeLocked(with:)` — `AVCaptureDevice.WhiteBalanceGains` |
| `setFocusDistance(double)` | `AVCaptureDevice.setFocusModeLocked(lensPosition:)` |
| `setZoom(double)` | `AVCaptureDevice.videoZoomFactor` |
| `setFlashMode(FlashMode)` | `AVCapturePhotoSettings.flashMode` |
| `capturePhoto(format: ImageFormat.raw)` | Frame-grab → built-in linear-DNG writer (implemented); `AVCapturePhotoSettings(rawPixelFormatType:)` / ProRAW is a future target |

**GPU compute:** Metal compute shaders implemented — runtime-compiled MSL histogram, focus-peaking, and zebra kernels, bit-exact vs the C kernels (verified on Apple M1 Pro), with automatic GPU/CPU dispatch (`MetalCompute`).

**Current status:** ✅ Backend implemented and shared with macOS. The real sensor controls above (custom exposure/ISO, lens position, WB gains, zoom, torch) compile for iOS. 🚧 Not yet run on a physical iPhone — on-device verification, depth/LiDAR, and ProRAW are gated on hardware.

---

### macOS — AVFoundation + Metal

macOS shares the AVFoundation backend with iOS but with notable differences:

- Built-in and USB/Thunderbolt Mac cameras expose no manual sensor controls through AVFoundation. Rather than degrading to `CameraTier.basic`, all six controls (ISO, shutter, EV, WB, focus, zoom) run through a **digital pipeline in the C core**, so macOS reaches `CameraTier.full` — verified live on real Mac cameras.
- The Metal compute path is identical to iOS (same GPU family on Apple Silicon).

| Dart control | macOS mapping | Notes |
|---|---|---|
| All six manual controls | C-core digital pipeline (adjust/zoom/blur kernels) | Verified live; sensor-level control unavailable on Mac cameras |
| Everything else | Same as iOS | — |

**Current status:** ✅ Live-verified on real Mac cameras: enumeration, capabilities, live preview over FFI into Flutter, PNG capture, RAW linear-DNG capture (ffmpeg-verified), H.264 video recording (ffprobe-verified `.mov`), burst (5 shots in ~1.2 s), EV bracketing (measured luminance 25.8 / 96.9 / 183.4 at −2/0/+2), multi-camera concurrent open, and the camera permission flow. Note: stills are frame-grabs at preview resolution; full-res `AVCapturePhotoOutput` stills are a future target.

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
