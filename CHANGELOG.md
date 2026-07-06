# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.0.2] - 2026-07-07

### Changed

- **FFI:** marked the O(1) native calls `isLeaf: true` — the introspection
  queries (`version`, `simd_*`, `error_string`) and the lock-free buffer-pool
  ops (`acquire`/`release`/`available`/`capacity`). The per-frame compute
  kernels and `write_dng` are deliberately left non-leaf (a leaf call would
  hold GC off a safepoint for the kernel's whole duration, and the transition
  it saves is noise next to a 0.7–34 ms kernel).

### Docs

- Added a pub.dev version badge, CI badge, and install line to the README.
- Refreshed `ROADMAP.md` stats (80 VM + 65 browser tests; ~375 KB archive;
  marked pub.dev **published**; noted web `MediaRecorder` video recording).
- Ten animated architecture diagrams (dark / monospace house style) woven
  through the README, with a `doc/diagrams/` gallery.

### CI

- **Automated pub.dev publishing**: `release.yml` cuts a GitHub Release + tag on
  every version bump merged to `main` and dispatches `publish.yml`, which uses
  pub.dev trusted publishing (OIDC — no stored credentials).

## [0.0.1] - 2026-07-04

Initial open-source release. Everything below is part of this first version;
the dated section at the bottom records the original foundation work.

### Added

**Full manual controls on every platform (web reaches the DSLR tier)**

- The web backend now applies all six manual controls — ISO, shutter, exposure,
  white balance, focus, zoom — through a **pure-Dart digital pipeline**
  (`NativeCore.adjustPixels` / `digitalZoom` / `boxBlur`, ports of the C
  kernels), exactly as the macOS built-in camera does. Every control is
  reported `Supported`, so a browser camera reaches `CameraTier.full` ("Full
  manual (DSLR)"). Aperture is the one honest exception (fixed-aperture lens).
- `NativeCore` gains `adjustPixels` / `digitalZoom` / `boxBlur` on native (FFI)
  too, so the manual-control API is identical across platforms.
- Web RAW capture is real: a pure-Dart linear-DNG encoder (`web_dng.dart`, a
  port of `dng_writer.c`) — ffmpeg decodes the output (20 direntries, matches
  the C writer). `supportsRawCapture` is now honestly true on web.
- `supportsBurstMode` / `supportsBracketing` corrected to `true` on Apple and
  web (both are implemented at the controller level and work everywhere).
- Web sample app: a manual-control panel (ISO/EV/WB/zoom/focus sliders) plus
  `?ev=`/`?wb=`/`?zoom=`/`?focus=`/`?iso=` URL params and a `?view=caps` mode.
- Web video recording is now **real** via `MediaRecorder` (h264/webm, returned
  as an object URL with byte size + resolution); the video capability is only
  advertised when the browser can actually encode it. Adds `vp9`/`vp8` to
  `VideoCodec`. Verified live in Chrome: recorded a 3s 50 KB h264 clip.
- Adversarial self-review fixes: web `adjustPixels` now round-to-nearest
  matching the C `clampf_u8` (was truncating — off-by-one vs native; a
  fractional-input test now locks parity on both VM and browser); `rawPlusJpeg`
  dropped from web's advertised formats (the browser has no filesystem for a
  JPEG companion, so the claim was dishonest).
- Verified live in Chrome (exposure, zoom, and focus visibly change the feed;
  tier shows Full manual; all capabilities Supported; video recorded —
  screenshots in `doc/web/`). VM suite 80/80; browser suite 65/65 (adds
  digital-pipeline + DNG + rounding-parity tests that cross-check the Dart ports
  against the FFI C core).

**Web support (getUserMedia backend + pure-Dart visual aids)**

- **Conditional-import refactor**: `camera_pro.dart` now selects native (FFI) or
  web implementations via `if (dart.library.js_interop)` exports, so the web
  build never references `dart:ffi`/`dart:io`. New `platform_io.dart` /
  `platform_web.dart` aggregators, `core_facade.dart`, and a
  `default_backend.dart` factory. The native-assets hook skips C compilation
  when `buildCodeAssets` is false (web).
- **`WebCameraBackend`** (`package:web`): device enumeration, `getUserMedia`
  preview via `<video>`→`<canvas>` pixel readback, capabilities from
  `MediaStreamTrack.getCapabilities()` (zoom where exposed; manual controls
  honestly reported NotSupported), `applyConstraints` zoom, and in-memory
  `capturePhoto`.
- **Pure-Dart visual aids** (`native_core_web.dart`): histogram, focus peaking,
  zebra, false color, waveform, and digital adjust reimplemented in Dart —
  byte-identical to the C reference (cross-checked: the web-kernel test passes
  on both the browser and the FFI VM).
- **Web sample app** (`example/lib/web_main.dart`): live preview, capability
  passport, toggle-able overlays, in-memory capture; `?overlay=`/`?capture=`
  URL params for reproducible demos.
- **Verified**: builds with `flutter build web`; runs in Chrome against a fake
  camera device (live preview + all overlays + capture, screenshots in
  `doc/web/`); `flutter test --platform chrome` passes 60 tests in the browser.
  New CI `web` job builds the app and runs the browser tests every push.

**Roadmap completion sweep (pro capture, GPU, SIMD, platforms, polish)**

- **Video recording**: `AVCaptureMovieFileOutput` wired through HAL → backend → controller (`startVideoRecording`/`stopVideoRecording`, blocking finalize). ffprobe-verified h264 `.mov`.
- **Burst + EV bracketing**: `captureBurst(count)` and `captureExposureBracket(stops)` (EV restore, settle delay). Verified: 5 shots ≈1.2s; bracket mean-luminance 25.8/96.9/183.4 at −2/0/+2.
- **RAW/DNG + EXIF**: dependency-free linear-DNG writer (`dng_writer.c`, DNG 1.4 + ColorMatrix1 + EXIF IFD); `ImageFormat.raw`/`rawPlusJpeg` wired; ffmpeg-verified from the real camera.
- **Metal GPU compute**: runtime-compiled MSL histogram/peaking/zebra, bit-exact vs the C kernels on Apple M1 Pro; `MetalCompute` with automatic CPU fallback; example overlays run on GPU.
- **SIMD**: SSSE3 x86 histogram (bit-exact, verified under Rosetta 2 and on CI x86); NEON YUV420P→RGBA (bit-exact, 0.66ms/1080p).
- **Frame processors**: `FrameProcessor` plugin API on the preview path. **Multi-camera**: concurrent two-device open verified. **Quirks DB**: 8 entries. **Streaming**: typed API surface (transport roadmap).
- **Linux V4L2 + Windows Media Foundation backends**: full 44-function HAL contract each; GitHub Actions CI (`native.yml`) compiles and runs the portable lifecycle harness on macos-14/ubuntu/windows every push — all green.
- **Polish**: measured benchmark harness (`bench.c`) with README numbers; dartdoc 0 warnings; `pub publish --dry-run` 0 warnings.

**Live false-color + waveform overlays (visual-aids suite complete)**

- Added an `is_bgra` parameter to `camera_pro_compute_false_color` and `camera_pro_compute_luma_waveform` for correct colours/luma on BGRA preview frames.
- The example gains **False color** (full-frame exposure-zone map) and **Waveform** (luminance waveform monitor) toggles, computed per frame in C. Verified live on the Mac camera: false color renders the correct exposure zones (green mid / yellow near-clip / pink highlight / blue shadow / red clip) and the waveform trace tracks the scene. This completes the visual-aids suite: **histogram · focus peaking · zebra · false color · waveform**, all live.

**Live focus-peaking + zebra overlays**

- `camera_pro_compute_focus_peaking` and `camera_pro_compute_zebra` gained an `is_bgra` parameter so the overlay colours are correct on BGRA preview frames, exposed via `NativeCore.focusPeaking` / `NativeCore.zebra`.
- The example has toggle chips that run the Sobel focus-peaking (cyan edge highlight) and zebra (over-exposure stripes) kernels on each preview frame. Verified live: focus peaking outlines in-focus edges in cyan on the running camera feed. (C harness 54 checks; 2 new FFI tests → 65 Dart tests.)

**Photo capture + live histogram**

- `capturePhoto()` is wired on the Apple backend: it grabs the latest preview frame (with digital manual-control adjustments applied), encodes a PNG via `dart:ui`, and writes it to disk, returning a `CapturedPhoto` with path + bytes. Verified on macOS — the example's Capture button saves a real 1920×1080 PNG. Full-res `AVCapturePhotoOutput`/RAW remains roadmap. New `ImageFormat.png` and `CaptureFailureReason.noFrame`.
- Live histogram: the example computes the luminance + RGB histogram from each preview frame via the native C core (`camera_pro_compute_histogram_rgba`) and paints it as an overlay — the first camera-frame → C-compute → UI visual aid wired end-to-end.

**Full manual controls on macOS via a digital pipeline**

- Researched macOS camera controls across all three layers — AVFoundation (manual controls `API_UNAVAILABLE(macos)`), CoreMediaIO (`kCMIOExposureControlClassID`/`Gain`/`WhiteBalance`… exist but the built-in/virtual/Continuity cameras expose **0** control objects), and IOKit/USB (**0** UVC devices). Sensor-level control genuinely requires hardware that isn't present.
- So manual controls now fall back to a **digital pipeline** in the C core, used automatically where the hardware has no sensor controls: `camera_pro_adjust_pixels` (digital ISO/gain, exposure/EV, white-balance, contrast), `camera_pro_digital_zoom` (center crop-zoom), and `camera_pro_box_blur` (defocus for manual focus). Shutter maps to a brightness gain ∝ exposure time.
- `AppleCameraBackend` routes each setter to the sensor control (iOS/UVC) or the digital pipeline (macOS built-in), and reports the full manual set — ISO, shutter, exposure, white balance, focus, zoom — as `Supported`. On macOS the example reaches `CameraTier.full` and the sliders visibly transform the live feed. Focus/shutter that can't be emulated are still surfaced honestly where applicable.
- C harness grows to 54 checks (digital gain/EV/WB/contrast, zoom, blur).

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

### Foundation work (2026-07-01, pre-release — folded into 0.0.1)

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
