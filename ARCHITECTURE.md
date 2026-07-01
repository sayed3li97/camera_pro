# camera_pro — Technical Architecture

> **Project status:** This is the initial foundation commit (v0.1.0). The Dart
> control-plane, shared C core, and build pipeline are implemented and verified.
> Real platform HALs (Android, iOS, Windows, Linux, Web) and the GPU overlay
> path are **not yet wired**; the package runs against a conformant stub backend
> that returns safe defaults. See [Implemented vs Roadmap](#implemented-vs-roadmap)
> for the full picture.

---

## Table of Contents

1. [Overview — The Hybrid Bridge](#overview--the-hybrid-bridge)
2. [Layer Diagram](#layer-diagram)
3. [Layer 1: Dart API / Control-Plane](#layer-1-dart-api--control-plane)
   - [Capability Passport](#capability-passport)
   - [State Machine](#state-machine)
   - [Typed Error Hierarchy](#typed-error-hierarchy)
   - [Tier Selection](#tier-selection)
4. [Layer 2: FFI Fast Path](#layer-2-ffi-fast-path)
   - [CameraBackend Dart Abstraction](#camerabackend-dart-abstraction)
   - [NativeCore and NativeBufferPool](#nativecore-and-nativebufferpool)
5. [Layer 3: Shared C Core](#layer-3-shared-c-core)
   - [buffer_pool — Lock-free Atomic Pool](#buffer_pool--lock-free-atomic-pool)
   - [image_processor — SIMD Histogram, Focus Peaking, Zebra](#image_processor--simd-histogram-focus-peaking-zebra)
   - [format_converter — Scalar BT.601 YUV→RGBA](#format_converter--scalar-bt601-yuv-rgba)
6. [The HAL Contract (camera_hal.h)](#the-hal-contract-camera_halh)
   - [Stub HAL](#stub-hal)
7. [Build System](#build-system)
8. [Threading Model (Target Design)](#threading-model-target-design)
9. [Implemented vs Roadmap](#implemented-vs-roadmap)

---

## Overview — The Hybrid Bridge

camera_pro uses a three-layer architecture called the **Hybrid Bridge**:

| Layer | What it does | Language |
|---|---|---|
| **Dart API / Control-plane** | Typed API, capability passport, state machine, error hierarchy, tier selection | Dart |
| **FFI fast path** | Zero-copy pointer passing for frame data; SIMD image-processing kernels called at frame rate | C via `dart:ffi` |
| **Native HAL + shared C core** | Platform-specific camera session (Camera2 / AVFoundation / etc.) plus the frame-processing core | C / C++ |

The key invariant is that **control decisions live in Dart** (the capability passport, the state machine, the guarded setters) while **data-plane work lives in C** (histograms, format conversion, focus peaking). This keeps the hot path off the Dart GC and lets Dart remain the single source of truth for device capabilities.

---

## Layer Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│  Flutter Application                                                │
│  ─────────────────────────────────────────────────────────────────  │
│  CameraPro.create()  ·  CameraProController  ·  CameraCapabilities │
│  CameraProError (sealed)  ·  CameraTier  ·  CameraSettings         │
│                          Dart control-plane                         │
└──────────────┬──────────────────────────────────┬───────────────────┘
               │ capability-guarded setters        │ stateChanges stream
               ▼                                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│  CameraBackend (Dart interface)                                     │
│  StubCameraBackend  (✅ today)   [AndroidCamera2Backend  🚧]        │
│                          Dart mirror of HAL                         │
└──────────────┬──────────────────────────────────────────────────────┘
               │ dart:ffi  @Native externals
               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  libcamera_pro_core  (native code asset, compiled by hook/build.dart)│
│  ─────────────────────────────────────────────────────────────────  │
│  camera_pro_core.h  — FFI boundary (version, pool, histogram, …)   │
│  ─────────────────────────────────────────────────────────────────  │
│  buffer_pool.c      lock-free atomic frame pool                     │
│  image_processor.c  SIMD histogram · Sobel focus peaking · zebra   │
│  format_converter.c scalar BT.601 YUV420p/NV12/NV21 → RGBA         │
│  camera_pro_core.c  version + error-string registry                 │
│  ─────────────────────────────────────────────────────────────────  │
│  camera_hal.h       HAL contract (one C interface per platform)     │
│  ─────────────────────────────────────────────────────────────────  │
│  stub/camera_hal_stub.c   (✅ today — no-op, conformant)           │
│  android/camera_hal_android.c   🚧  (NDK Camera2, not wired)       │
│  apple/camera_hal_apple.mm      🚧  (AVFoundation, not wired)      │
│  windows/camera_hal_windows.c   🚧  (Media Foundation, not wired)  │
│  linux/camera_hal_linux.c       🚧  (V4L2, not wired)             │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Layer 1: Dart API / Control-Plane

Source: `lib/src/{models,controller,processing,platform,ffi,utils}/`

The control-plane's job is to **make it structurally impossible to call a feature that does not exist on the device** and to **surface every failure as a typed, actionable error** before anything reaches native code.

### Capability Passport

`lib/src/models/capabilities.dart`

Every tunable control is represented as a `Capability<T>`, a sealed class with exactly two subtypes:

```dart
sealed class Capability<T> { ... }

final class Supported<T> extends Capability<T> {
  final T currentValue;
  final T minValue;
  final T maxValue;
  final T? stepSize;   // non-null when the control is quantized
}

final class NotSupported<T> extends Capability<T> {
  final String reason; // e.g. "Fixed aperture lens"
}
```

Because the class is `sealed`, every `switch` over a `Capability` is **exhaustively checked at compile time**. There is no runtime path that accidentally reads a range off an unsupported control:

```dart
switch (controller.capabilities.iso) {
  case Supported<int>(:final minValue, :final maxValue):
    // safe to show a slider
  case NotSupported<int>(:final reason):
    // disable the control and show the reason
}
```

`CameraCapabilities` collects all tunables into a single immutable passport — shutter speed, ISO, aperture, white-balance Kelvin, focus distance, exposure compensation, zoom — alongside boolean feature flags (supportsRawCapture, supportsHdr, hasFlash, etc.) and lists of supported modes/formats/codecs.

The `CameraCapabilities.unsupported()` factory produces a fully-`NotSupported` passport used by the stub backend and before any device is opened. This means the control-plane can always be exercised without a real camera attached.

### State Machine

`lib/src/controller/camera_state_machine.dart`

The controller's lifecycle is enforced by a strict state machine rather than ad-hoc boolean flags. States and their allowed transitions:

```
uninitialized ──► opened ──► previewing ──► capturing ──► previewing
                    │             │
                    │             ├──► recording ──► recordingPaused
                    │             │         └──► previewing
                    │             │
                    │             ├──► interrupted ──► previewing
                    │             │                └──► opened
                    │             │
                    │             └──► error ──► previewing
                    │                       └──► fatal ──► disposed
                    │
                    └──► disposed
```

`CameraStateMachine.transition(to)` throws `CameraStateException` immediately if the transition is not in the valid-transition map, before any native call is made. The `changes` stream broadcasts `CameraStateChange(from, to)` values for reactive UIs.

The `camera_state_callback_t` in the native HAL feeds back into this machine so that OS-driven interruptions (phone calls, backgrounding, thermal events) are reflected on the Dart side without polling.

### Typed Error Hierarchy

`lib/src/models/errors.dart`

Every failure is a `CameraProError` subclass (sealed). Each carries a `CameraErrorRecovery` enum value so callers can react programmatically:

| Subclass | Recovery | Trigger |
|---|---|---|
| `CameraPermissionError` | `requestPermission` | OS denied camera access |
| `CameraDeviceError` | `reinitialize` | NDK/AVFoundation device error |
| `CameraInUseError` | `userAction` | Another app holds the camera |
| `CameraSessionInterruptedError` | `automatic` | Call, background, thermal |
| `CameraThermalThrottleError` | `automatic` | Device overheating |
| `CameraFeatureNotSupportedError` | `fatal` | Control not on this device |
| `CameraCaptureError` | `retry` | Photo/video encode failure |
| `CameraServiceFatalError` | `deviceRestart` | OS camera service crashed |
| `CameraInvalidParameterError` | `retry` | Out-of-range value passed |

The capability-guarded setters in `CameraProController` throw `CameraFeatureNotSupportedError` or `CameraInvalidParameterError` **before** forwarding the call to the backend. This means a `CameraFeatureNotSupportedError` from a setter is always a pure-Dart check — the native layer is never invoked with an unsupported parameter.

### Tier Selection

`lib/src/controller/camera_tier.dart`

`determineTier(CameraCapabilities)` is a pure function that maps a capability passport to one of three UX tiers:

| Tier | Requirements | Typical device |
|---|---|---|
| `CameraTier.full` | Manual shutter + ISO + focus + WB all `Supported` | Pro phone, dedicated camera |
| `CameraTier.standard` | Exposure compensation `Supported` | Mid-range phone |
| `CameraTier.basic` | None of the above | Tablet, webcam, stub |

The tier is computed once at `create()` time from the immutable capability passport and never changes during a session.

---

## Layer 2: FFI Fast Path

### CameraBackend Dart Abstraction

`lib/src/controller/camera_backend.dart`

`CameraBackend` is the Dart mirror of `camera_hal.h`. It is a pure Dart abstract interface — no FFI, no `dart:io`. Each platform backend (today: `StubCameraBackend`; future: Android, iOS, etc.) implements it. The controller depends only on this interface, so platform HALs can be injected in tests and swapped at runtime without rebuilding the controller.

Key methods mirror the HAL 1-to-1: `enumerateDevices`, `open`, `getCapabilities`, `startPreview`, `stopPreview`, `setIso`, `setShutterSpeed`, `setExposureCompensation`, `setWhiteBalance`, `setFocusDistance`, `setZoom`, `setFlashMode`, `capturePhoto`, `close`.

The `StubCameraBackend` implements every method as a safe no-op that returns empty or `unsupported` values. It is what `CameraPro.create()` uses until a platform HAL is wired.

### NativeCore and NativeBufferPool

`lib/src/ffi/native_core.dart`

`NativeCore` is a static façade over the `@Native` externals auto-generated by ffigen from `camera_pro_core.h`. It exposes typed helpers:

- `NativeCore.versionString` — real FFI call, verified to return `"0.1.0"`
- `NativeCore.simdName` — returns the active kernel name (`"NEON"` on arm64)
- `NativeCore.errorString(code)` — maps a native `camera_error_t` to a human string
- `NativeCore.histogramFromRgba(...)` — copies a `Uint8List` into native memory, calls the SIMD histogram kernel, copies the 4 × 256-bin result back to Dart

`NativeBufferPool` wraps the native pool lifecycle: `create → acquire → release → dispose`. The `acquire` path calls through to `camera_pro_buffer_pool_acquire` and returns a raw `Pointer<Uint8>`; no Dart allocation occurs per frame on the hot path.

The `@DefaultAsset` annotation in `camera_pro_bindings.dart` matches the `assetName` in `hook/build.dart`, closing the loop between the build system and the FFI binding.

---

## Layer 3: Shared C Core

Source: `src/core/`, compiled into `libcamera_pro_core` by the native-assets hook.

The core is written in C11 and is platform-agnostic. It is compiled and tested independently of any Flutter build. The C test harness (`src/tests/core_test.c`) runs 36 checks under `clang -std=c11 -O2 -Wall -Wextra -Werror`.

### buffer_pool — Lock-free Atomic Pool

`src/core/buffer_pool.c`

The buffer pool provides a fixed-size set of cache-line-aligned heap buffers allocated once at `camera_pro_buffer_pool_create`. Producers (the platform HAL delivering frames) `acquire` a slot by atomically CAS-ing a free-list index; consumers (the Dart processing pipeline) `release` the slot when done. If the pool is drained, `acquire` returns `NULL` and the caller drops the frame rather than blocking — this prevents pipeline stalls from propagating into the camera hardware thread.

The pool is the reason frame delivery never allocates: the buffers exist for the lifetime of the session, and only an integer index moves between threads.

### image_processor — SIMD Histogram, Focus Peaking, Zebra

`src/core/image_processor.c`

**Histogram (`camera_pro_compute_histogram_rgba`):** Walks an RGBA8888 frame and accumulates 4 × 256 `uint32_t` bins (luminance, R, G, B). The luminance weight is the BT.601 approximation `(R * 77 + G * 150 + B * 29) >> 8`. On arm64 targets, a NEON-vectorized kernel processes 16 pixels per iteration; on x86_64 an AVX2/SSE2 path is selected at compile time; on other targets the scalar path is used. The scalar path is also exposed separately as `camera_pro_compute_histogram_rgba_scalar` and serves as the reference for cross-checking SIMD results in tests.

The NEON kernel has been verified to produce bit-exact output against the scalar reference on an arm64 host (the active SIMD level reported by `camera_pro_simd_name()` on the CI machine is `"NEON"`).

**Focus peaking (`camera_pro_compute_focus_peaking`):** Applies a 3x3 Sobel operator to the luma channel of each pixel. Pixels whose edge magnitude exceeds `threshold` (0..1) have their color replaced by `peak_color` (0xRRGGBBAA) in the output buffer. This runs as a scalar pass; GPU acceleration is on the roadmap (see below).

**Zebra stripes (`camera_pro_compute_zebra`):** Pixels whose BT.601 luminance exceeds `threshold` are tinted with a diagonal stripe pattern. The stripe phase advances with `frame_counter`, producing the animated effect expected by camera operators. Like focus peaking, this is a CPU scalar pass today.

### format_converter — Scalar BT.601 YUV→RGBA

`src/core/format_converter.c`

Three conversion entry points handle the most common YUV families delivered by mobile camera hardware:

| Function | Input planes | Notes |
|---|---|---|
| `camera_pro_yuv420p_to_rgba` | Y + U + V (planar 4:2:0) | Android Camera2 YUV_420_888 planar |
| `camera_pro_nv12_to_rgba` | Y + interleaved UV | AVFoundation kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange |
| `camera_pro_nv21_to_rgba` | Y + interleaved VU | Android Camera2 default semi-planar |

All three use the full-range BT.601 matrix and clamp outputs to [0, 255]. The implementations are scalar today; libyuv integration for SIMD-accelerated conversion is on the roadmap.

---

## The HAL Contract (camera_hal.h)

`src/hal/camera_hal.h`

The HAL is a single C header defining an opaque `camera_context_t*` handle and a flat set of `camera_hal_*` functions. Each platform backend implements **exactly this interface** and nothing else. The shared core and the FFI layer call only these symbols; they never include platform SDK headers directly.

Rationale for one C interface per platform:

- **ABI stability.** The FFI layer is generated from `camera_pro_core.h` (the FFI boundary). The HAL is internal — it can evolve without regenerating bindings.
- **Testability.** The stub backend satisfies the entire interface so every Dart test runs on any host without platform SDKs installed.
- **Separation of native-assets from platform plugins.** The shared C core compiles via the native-assets hook (`hook/build.dart`). Platform HALs link against platform SDKs (NDK, AVFoundation, Media Foundation, V4L2) via each platform's own build system (CMake for Android/Linux/Windows, CocoaPods for iOS/macOS). The hook does not need to know about them.

The HAL structs convey capabilities back to Dart:

```c
typedef struct {
    camera_shutter_capability_t    shutter;   // {supported, min_ns, max_ns}
    camera_iso_capability_t        iso;        // {supported, min_iso, max_iso}
    camera_focus_capability_t      focus;
    camera_wb_capability_t         white_balance;
    camera_ev_capability_t         exposure_compensation;
    camera_zoom_capability_t       zoom;       // {min, max, optical_levels[]}
    camera_flash_capability_t      flash;
    camera_advanced_capabilities_t advanced;  // raw, hdr, burst, depth, lidar…
    camera_video_capabilities_t    video;
    const char*                    platform_name;
    const char*                    device_name;
    int32_t                        hardware_level;
} camera_capabilities_t;
```

The Dart side reads this struct via the `CameraBackend.getCapabilities()` call, translates it into `CameraCapabilities` (with `Supported`/`NotSupported` wrapping), and never touches the C struct again.

### Stub HAL

`src/platform/stub/camera_hal_stub.c`

The stub implements every `camera_hal_*` function as a no-op that returns `CAMERA_OK`. `camera_hal_get_capabilities` fills the capabilities struct with all `supported = false` and empty lists. The stub is the implementation that `hook/build.dart` currently links, so `flutter test` and `flutter run` both work on any host.

---

## Build System

`hook/build.dart`

camera_pro uses the Dart **native-assets** feature (`hooks` + `code_assets` + `native_toolchain_c`) to compile the shared C core automatically during `flutter test`, `flutter run`, and `flutter build`.

```dart
final builder = CBuilder.library(
  name: 'camera_pro_core',
  assetName: 'src/ffi/camera_pro_bindings.dart',  // must match @DefaultAsset
  sources: [
    'src/core/buffer_pool.c',
    'src/core/image_processor.c',
    'src/core/format_converter.c',
    'src/core/camera_pro_core.c',
    'src/platform/stub/camera_hal_stub.c',
  ],
  includes: ['src/core', 'src/hal'],
  flags: ['-ffast-math'],
);
```

The `assetName` value (`'src/ffi/camera_pro_bindings.dart'`) is the path used as the `@DefaultAsset` in `lib/src/ffi/camera_pro_bindings.dart`. When `native_toolchain_c` compiles the sources, the resulting shared library is registered under that asset ID, and Dart's FFI runtime loads it automatically at process startup — no manual `DynamicLibrary.open` call required.

**Per-platform HAL wiring (future):** When a platform HAL is ready, it will be linked in via the platform's own build system, not via the native-assets hook:

- **Android:** A `CMakeLists.txt` under `android/` will compile `camera_hal_android.c` with the NDK and link against `libcamera2ndk.so`.
- **iOS / macOS:** A `Podspec` will compile `camera_hal_apple.mm` with the AVFoundation framework.
- **Windows:** A `CMakeLists.txt` under `windows/` will link `camera_hal_windows.c` against `mf.lib` / `mfplat.lib`.
- **Linux:** A `CMakeLists.txt` under `linux/` will link `camera_hal_linux.c` against `libv4l2`.
- **Web:** A separate WASM / JS bridge; the HAL contract does not apply directly.

The shared C core (buffer pool, image processor, format converter) stays in `hook/build.dart` across all platforms. Only the HAL translation unit changes per platform.

FFI bindings are generated by `ffigen` from `camera_pro_core.h` using the configuration in `ffigen.yaml`.

---

## Threading Model (Target Design)

This section describes the **intended** threading model. It is not yet verified because real platform HALs are not wired. The model is designed in the HAL contract and the buffer pool, but actual thread management is not exercised today.

```
┌─────────────────────┐      acquire/release        ┌────────────────────┐
│  Platform HAL       │  ─────────────────────────► │  NativeBufferPool  │
│  (camera thread)    │  writes frame data           │  (lock-free pool)  │
└─────────────────────┘                             └────────┬───────────┘
                                                             │ pointer
                                                             ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  Dart Isolate (main)                                                    │
│  NativeCallable / ReceivePort from camera_frame_callback_t              │
│  ─────────────────────────────────────────────────────────────────────  │
│  1. NativeCore.histogramFromRgba(pointer, width, height)                │
│  2. focusPeaking / zebra overlay                                        │
│  3. Flutter Texture.markFrameAvailable()              🚧 not wired yet  │
└─────────────────────────────────────────────────────────────────────────┘
```

Key properties:
- The platform HAL owns its camera delivery thread; it writes frames into pool buffers without entering the Dart heap.
- `camera_frame_callback_t` is a C function pointer registered by the controller; the HAL calls it on its own thread. The callback posts the pointer (not a copy) to a Dart `ReceivePort` via a `NativeCallable`.
- The Dart isolate receives the pointer, runs processing (histogram, peaking, zebra), and calls `Texture.markFrameAvailable()` to signal Flutter's raster thread.
- After Flutter has composited the frame, the Dart side calls `release` to return the buffer to the pool.
- No per-frame allocation reaches the Dart GC on the hot path; the only Dart allocation in `NativeCore.histogramFromRgba` is the `HistogramData` result object (4 × 256 `Uint32List` copies), which is acceptable for display-rate histogram updates.

GPU compute overlays (Metal, Vulkan, D3D11, WebGPU) will replace the CPU Sobel and zebra passes on capable devices. They are on the roadmap and have no wired implementation today.

---

## Implemented vs Roadmap

### ✅ Implemented and verified (this commit)

| Component | Evidence |
|---|---|
| Shared C core (buffer pool, histogram SIMD, Sobel focus peaking, zebra, BT.601 format converters) | 36/36 C tests pass; NEON kernel bit-exact vs scalar on arm64 |
| `camera_pro_core.h` FFI boundary | Stable, documented, unchanged across test runs |
| `camera_hal.h` HAL contract | Defined; used by stub |
| Conformant stub HAL (`camera_hal_stub.c`) | All 36 C tests link against it |
| Dart capability passport (`Capability<T>` sealed hierarchy, `CameraCapabilities`) | 54 pure-logic Dart tests pass |
| Dart state machine (`CameraStateMachine`) | Covered by unit tests |
| Dart typed error hierarchy (`CameraProError` sealed, 9 subclasses) | Covered by unit tests |
| Tier selection (`determineTier`) | Covered by unit tests |
| `CameraProController` with capability-guarded setters | Covered by unit tests |
| `NativeCore` / `NativeBufferPool` FFI façade | 5 real-FFI tests pass (version string, SIMD name, histogram end-to-end) |
| Native-assets hook (`hook/build.dart`) | Compiles `libcamera_pro_core.dylib` automatically during `flutter test`/`flutter run` on macOS arm64 |
| Example app | `flutter analyze` clean, widget test passes |
| `flutter analyze` | No issues on package + example |
| Toolchain | Flutter 3.44.1, Dart 3.12.1, macOS arm64 |

### 🚧 Designed / scaffolded — API exists, native side NOT wired

| Component | Status |
|---|---|
| Android NDK Camera2 HAL (`camera_hal_android.c`) | HAL interface designed; implementation not started |
| Apple AVFoundation HAL (`camera_hal_apple.mm`) | HAL interface designed; implementation not started |
| Windows Media Foundation HAL | HAL interface designed; implementation not started |
| Linux V4L2 HAL | HAL interface designed; implementation not started |
| Flutter texture registration (`Texture`, `markFrameAvailable`) | Threading model designed; no wired HAL to drive it |
| `CameraBackend` platform implementations (Android, iOS) | Dart interface exists; only `StubCameraBackend` is wired |
| Frame processor / image stream callback path | `camera_hal_start_image_stream` defined in HAL; no Dart consumer wired |
| Thermal throttle integration (live policy application) | `ThermalPolicy` + `ThermalLevel` types implemented; not driven by a real OS thermal API |
| Device quirks database (native mirror) | Dart-side `quirksFor()` implemented; native side not integrated |

### ❌ Not started

| Component |
|---|
| GPU compute shaders (Metal, Vulkan, D3D11, WebGPU) for focus peaking / zebra |
| RAW / DNG capture (libtiff not integrated) |
| EXIF embedding (libexif not integrated) |
| libyuv / libjpeg-turbo integration (SIMD-accelerated format conversion and JPEG encode) |
| Live streaming (RTMP / SRT / WebRTC) |
| Multi-camera capture |
| Depth / LiDAR capture |
| Video recording (HAL `camera_hal_start_recording` defined but not wired) |
| Burst and bracket capture |
| HDR photo/video |
| Web platform (WASM / JS bridge) |
| Audio gain control |

---

*Copyright (c) 2026 camera_pro contributors. BSD-3-Clause.*
