# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
