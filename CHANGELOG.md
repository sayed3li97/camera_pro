# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

**Live camera preview (macOS + iOS)**

- The AVFoundation HAL now requests camera permission and runs an `AVCaptureVideoDataOutput`, delivering BGRA frames that the Dart side polls over FFI (`camera_pro_apple_copy_latest_frame`) and paints with `dart:ui` — no Flutter `TextureRegistry`/plugin channel required.
- `CameraBackend` gains `startFrameStream` / `stopFrameStream` / `latestFrame` / `frameCount`, surfaced on `CameraProController` as `startPreviewStream()`, `latestPreviewFrame()`, and `previewFrameCount`; new `PreviewFrame` value type.
- The example app renders a live viewfinder and was **verified streaming real frames from a Mac camera** (the earlier build could not open the camera because it never requested permission or started the session).

### Notes on manual controls

- Reconnaissance confirmed AVFoundation exposes **no** manual exposure/ISO/focus/WB controls on macOS (they are `API_UNAVAILABLE(macos)`), and the available cameras are not UVC/USB devices — so manual controls have no OS/hardware path on this Mac. They are implemented for iOS (compiled against the iOS SDK) and are the domain of external UVC webcams (IOKit) on desktop.

**Shared C core visual aids**

- Luminance waveform monitor (`camera_pro_compute_luma_waveform`) → `WaveformData` (per-column 256-bin luminance distribution), exposed via `NativeCore.waveformFromRgba`.
- False-color exposure map (`camera_pro_compute_false_color`) → RGBA zones (crushed→purple … clipped→red), exposed via `NativeCore.falseColorFromRgba`.
- C harness grows to 43 checks; 2 new Dart FFI tests exercise both through the compiled core (63 Dart tests total).

**Apple (iOS + macOS) AVFoundation backend — first real platform HAL**

- `src/platform/apple/camera_hal_apple.m`: shared Objective-C implementation of the full `camera_hal.h` contract against AVFoundation. Device enumeration (`AVCaptureDeviceDiscoverySession`), open/close, capability reporting, and manual controls (ISO, shutter, exposure compensation, focus lens position, white-balance temperature, zoom, torch). iOS-only manual-control APIs are guarded with `#if TARGET_OS_IOS`; on macOS they are honestly reported as unsupported (degrading to `CameraTier.basic`).
- `AppleCameraBackend` (`lib/src/platform/apple/apple_camera_backend.dart`): drives the HAL over FFI; auto-selected on macOS/iOS by `CameraPro.create()` / `availableCameras()`.
- FFI bindings for the HAL and Apple accessors (`lib/src/ffi/hal_bindings.dart`), including the `AppleCaps` struct mirror.
- `hook/build.dart` now selects the AVFoundation backend (Objective-C + AVFoundation/CoreMedia/CoreVideo/Foundation frameworks, ARC) for Apple targets and the stub backend elsewhere.
- Native harness `src/platform/apple/apple_hal_test.c` and Dart FFI test `test/ffi/apple_backend_test.dart`.

### Verified

- macOS: HAL compiled and **run against real host cameras** (FaceTime HD + external/virtual), enumerating devices and reading capabilities; `AppleCameraBackend` exercised end-to-end via `flutter test`.
- iOS: the shared `.m` compiles clean against the iPhoneOS SDK (manual-control branch), pending on-device validation.
- Dart test count: **61 passing** (was 59); `flutter analyze` clean.

### Still roadmap for Apple

Preview-texture rendering (`CVMetalTextureCache` → Flutter `TextureRegistry`), photo/video capture outputs, Metal GPU visual aids, and the camera permission flow.

## [0.1.0] - 2026-07-01

### Added

**Shared C core (`src/core/`)**

- Lock-free buffer pool (`buffer_pool.c`) with configurable capacity and thread-safe acquire/release semantics.
- SIMD histogram computation (`image_processor.c`): NEON kernel on arm64, scalar fallback on other architectures; NEON output verified bit-exact against scalar reference on arm64.
- Scalar YUV→RGBA format converters (`format_converter.c`): YUV420p, NV12, NV21 → RGBA8888.
- Sobel-based focus peaking overlay (`camera_pro_core.c`).
- Zebra-stripe highlight clipping overlay (`camera_pro_core.c`).
- Public C FFI boundary (`camera_pro_core.h`) exposing version/SIMD queries, buffer pool lifecycle, histogram, focus peaking, zebra, and format conversion functions.
- Platform-abstraction contract (`src/hal/camera_hal.h`) defining the HAL interface all platform backends must conform to.
- Conformant no-op stub HAL (`src/platform/stub/camera_hal_stub.c`) for development and testing without a real camera device.
- C test harness (`src/tests/core_test.c`): 36/36 checks pass under `clang -std=c11 -O2 -Wall -Wextra -Werror`.

**Native-assets build wiring**

- `hook/build.dart` using `hooks`, `code_assets`, and `native_toolchain_c` to compile the C core into `libcamera_pro_core` automatically during `flutter test` / `flutter run`, proving the native→FFI→Dart pipeline end-to-end.
- `ffigen.yaml` configuration for generating Dart FFI bindings from the C headers.

**Dart control-plane (`lib/src/`)**

- `NativeCore` wrapper (version string, SIMD name, error string, `histogramFromRgba`) and `NativeBufferPool` — real FFI calls into the compiled C core.
- `HistogramData` value type for histogram results.
- Capability passport: sealed `Capability<T>` with `Supported<T>` (currentValue, minValue, maxValue, optional stepSize) and `NotSupported<T>` (reason); `CameraCapabilities` with typed fields for shutterSpeed, iso, aperture, whiteBalanceKelvin, focusDistance, exposureCompensation, zoom, plus boolean flags `supportsRawCapture`, `supportsHdr`, `hasFlash`, and more; `CameraCapabilities.unsupported()` convenience factory.
- `CameraTier { full, standard, basic }` enum and `determineTier(CameraCapabilities)` pure function.
- Typed error hierarchy: sealed `CameraProError` base with `CameraErrorRecovery` enum; concrete subclasses `CameraPermissionError`, `CameraDeviceError`, `CameraInUseError`, `CameraSessionInterruptedError`, `CameraThermalThrottleError`, `CameraFeatureNotSupportedError`, `CameraCaptureError`, `CameraServiceFatalError`, `CameraInvalidParameterError`.
- Value types: `Iso(int)`, `Ev(double)`, `ShutterSpeed.fromFraction(n,d)` / `ShutterSpeed.seconds(x)`, `WhiteBalance.preset(mode)` / `WhiteBalance.temperature(kelvin)`, `VideoResolution`, `Bitrate.mbps()`.
- Enums: `ExposureMode`, `MeteringMode`, `FocusMode`, `WhiteBalanceMode`, `FlashMode`, `ImageFormat`, `VideoCodec`, `ColorProfile`, `Stabilization`, `StreamProtocol`.
- `CameraBackend` interface and `StubCameraBackend` implementation.
- `DeviceQuirk` / `quirksFor()` device quirk registry; `ThermalLevel` / `ThermalPolicy` thermal management types; `Result<T,E>` generic result type.
- `CameraProController` with capability-guarded setters (`setIso`, `setShutterSpeed`, `setExposureCompensation`, `setWhiteBalance`, `setFocusDistance`, `setZoom`, `setFlashMode`), `capturePhoto({ImageFormat? format})`, `dispose()`, `stateChanges` stream, and `CameraProController.forTesting({required capabilities, backend})` constructor.
- `CameraPro` facade: static `nativeCoreVersion`, `simdKernel`, `availableCameras({CameraBackend? backend})`, `create({CameraBackend? backend, CameraDevice? device})`.
- Barrel export (`lib/camera_pro.dart`).

**Tests and example**

- 59 Dart tests passing: 54 pure-logic unit tests + 5 real-FFI integration tests exercising the compiled C core through the Dart bindings.
- `flutter analyze` reports no issues on library, tests, and example.
- Example Flutter app (`example/`) with clean static analysis and passing widget test.

### Not yet implemented

Platform HALs, GPU compute, RAW/DNG capture, video recording, multi-camera, live streaming, and all other roadmap items are not part of this release. See [ROADMAP.md](ROADMAP.md) for the planned feature set and status indicators.
