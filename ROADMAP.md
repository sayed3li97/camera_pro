# camera_pro — Implementation Roadmap

This document tracks the phased implementation plan for `camera_pro`. Status markers reflect the state as of the initial foundation commit (v0.1.0).

**Status key:**
- ✅ Implemented and verified (test suite passes, end-to-end wired)
- 🚧 Designed or scaffolded (API/interface exists, native side not wired)
- ❌ Not started

---

## Project Status

`camera_pro` v0.1.0 is an **early foundation release**. The shared C processing core, Dart control-plane, and native-assets FFI pipeline are complete and verified. No real platform camera hardware abstraction layer (HAL) is wired yet — all platform backends are stubs. The package is not production-ready for capturing photos or video on any device.

---

## Phase 1 — Foundation & C Core ✅ (v0.1.0)

Goal: establish the shared C core, Dart API contract, and build pipeline such that future platform backends can be added without touching the control-plane.

| Item | Status | Notes |
|------|--------|-------|
| HAL interface (`src/hal/camera_hal.h`) | ✅ | Platform-abstraction contract defined in C |
| Conformant stub HAL (`src/platform/stub/camera_hal_stub.c`) | ✅ | No-op backend; passes all HAL contract checks |
| Lock-free buffer pool (`buffer_pool.c`) | ✅ | 36/36 C checks pass |
| SIMD histogram — NEON kernel | ✅ | Bit-exact vs scalar reference on arm64 |
| SIMD histogram — scalar fallback | ✅ | Active when NEON not available |
| SIMD histogram — AVX2/SSE4 kernel | ❌ | x86 path not yet written |
| Scalar YUV→RGBA format conversion (`format_converter.c`) | ✅ | YUV420p, NV12, NV21 |
| libyuv integration (accelerated YUV conversion) | ❌ | Not integrated; scalar path used |
| Sobel focus-peaking compute (`image_processor.c`) | ✅ | C scalar implementation |
| Zebra-stripe overexposure compute (`image_processor.c`) | ✅ | C scalar implementation |
| `camera_pro_core.h` FFI boundary | ✅ | Public C API surface finalized |
| `ffigen.yaml` configuration | ✅ | Config present and correct |
| Generated FFI bindings | 🚧 | Bindings hand-written for v0.1.0; ffigen auto-generation target for v0.2.0 |
| native-assets hook (`hook/build.dart`) | ✅ | Compiles C core to `libcamera_pro_core` automatically during `flutter test`/`flutter run` |
| Capability passport (`Capability<T>`, `CameraCapabilities`) | ✅ | Sealed types with `Supported`/`NotSupported` variants |
| `CameraTier` + `determineTier()` | ✅ | `full`/`standard`/`basic` tier selection |
| `CameraProController` skeleton | ✅ | State machine, typed errors, capability-guarded setters |
| Typed error hierarchy (`CameraProError` sealed) | ✅ | 9 concrete error types with recovery hints |
| Value types (`Iso`, `Ev`, `ShutterSpeed`, `WhiteBalance`, etc.) | ✅ | All defined and validated |
| `CameraPro` static entry points | ✅ | `create()`, `availableCameras()`, `nativeCoreVersion`, `simdKernel` |
| Dart test suite | ✅ | 59 tests pass (54 pure-logic + 5 real FFI through compiled core) |
| Example app | ✅ | `flutter analyze` clean; widget test passes |
| libjpeg-turbo integration | ❌ | Not integrated |
| libtiff / libexif integration (RAW/DNG + EXIF) | ❌ | Not integrated |

---

## Phase 2 — iOS / macOS Backend (AVFoundation) 🚧 (control-plane ✅)

Goal: first real device backend. The **control-plane is implemented and verified**
(`src/platform/apple/camera_hal_apple.m` + `AppleCameraBackend`) — device
enumeration, capability reporting, and manual controls run against real
AVFoundation. The preview-texture and capture pipeline remain the open work.

**Done ✅** — verified on real Mac cameras + compiled against the iPhoneOS SDK
(see `src/platform/apple/README.md`).

| Item | Status |
|------|--------|
| AVFoundation HAL implementation (control-plane) | ✅ |
| Device enumeration (`AVCaptureDeviceDiscoverySession`) | ✅ |
| Real `CameraCapabilities` from `AVCaptureDevice` / `activeFormat` | ✅ |
| ISO / shutter / EV / WB setters wired to `AVCaptureDevice` (iOS) | ✅ |
| Zoom wired to `videoZoomFactor` (iOS) | ✅ |
| Torch control (iOS) | ✅ |
| Focus distance wired to `lensPosition` (iOS) | ✅ |
| `AppleCameraBackend` (Dart FFI) + auto-selection on macOS/iOS | ✅ |
| Flutter texture registration (iOS/macOS) | ❌ |
| Camera permission request flow | ❌ |
| Live preview via `textureId` | ❌ |
| `capturePhoto()` → JPEG output (`AVCapturePhotoOutput`) | ❌ |
| Flash capture | ❌ |
| Thermal state monitoring (`ProcessInfo.thermalState`) | ❌ |

---

## Phase 3 — Android Backend (Camera2 NDK) 🚧

Goal: real device backend on Android via the Camera2 NDK C API.

| Item | Status |
|------|--------|
| Camera2 NDK HAL implementation | ❌ |
| Flutter texture registration (Android SurfaceTexture) | ❌ |
| Camera permission request flow | ❌ |
| Live preview via `textureId` | ❌ |
| `capturePhoto()` → JPEG output | ❌ |
| Real `CameraCapabilities` from `ACameraMetadata` | ❌ |
| Manual controls wired to `ACaptureRequest` | ❌ |
| Zoom via crop region / ACAMERA_CONTROL_ZOOM_RATIO | ❌ |
| Thermal headroom monitoring | ❌ |

---

## Phase 4 — Pro Capture Features 🚧

Depends on Phase 2 or 3 completing at least one platform backend.

| Item | Status |
|------|--------|
| RAW / DNG capture | ❌ |
| EXIF metadata embedding (libexif) | ❌ |
| libtiff integration for DNG writing | ❌ |
| libjpeg-turbo for fast JPEG encode | ❌ |
| Burst capture | ❌ |
| Bracket / HDR capture | ❌ |
| Histogram live feed from camera frames | 🚧 C compute ready; frame pipeline not wired |
| Focus peaking overlay | 🚧 C compute ready; texture compositing not wired |
| Zebra overexposure overlay | 🚧 C compute ready; texture compositing not wired |
| Auto-generated FFI bindings (replace hand-written) | 🚧 `ffigen.yaml` present; run blocked on stable codegen |

---

## Phase 5 — GPU Visual Aids (Metal / Vulkan / D3D11 / WebGPU) ❌

Goal: move histogram, focus peaking, and zebra from scalar C to GPU compute shaders for real-time overlay performance.

| Item | Status |
|------|--------|
| Metal compute shader — histogram | ❌ |
| Metal compute shader — focus peaking | ❌ |
| Metal compute shader — zebra | ❌ |
| Vulkan compute shader — histogram | ❌ |
| Vulkan compute shader — focus peaking | ❌ |
| Vulkan compute shader — zebra | ❌ |
| D3D11 / HLSL equivalents | ❌ |
| WebGPU compute shader equivalents | ❌ |
| Runtime GPU/CPU dispatch selection | ❌ |

---

## Phase 6 — Advanced Camera Features ❌

| Item | Status |
|------|--------|
| Video recording with codec selection (H.264 / HEVC / ProRes) | ❌ |
| Live streaming (RTMP / SRT / HLS) | ❌ |
| Frame processor plugin API | ❌ |
| Multi-camera (logical / physical) | ❌ |
| Depth / LiDAR capture | ❌ |
| AVX2 / SSE4 histogram kernel (x86 SIMD path) | ❌ |
| libyuv accelerated YUV conversion | ❌ |
| `DeviceQuirk` database populated from real device reports | 🚧 API scaffolded; no entries yet |

---

## Phase 7 — Desktop & Web ❌

| Item | Status |
|------|--------|
| Windows backend (Media Foundation) | ❌ |
| Linux backend (V4L2) | ❌ |
| Web backend (WebRTC / `getUserMedia`) | ❌ |
| WebGPU compute pipeline (web GPU visual aids) | ❌ |

---

## Phase 8 — Polish & Publication ❌

| Item | Status |
|------|--------|
| API documentation (dartdoc) complete | 🚧 Partial |
| pub.dev publication (full `pubspec.yaml`, topics, screenshots) | ❌ |
| Integration test suite on real devices | ❌ |
| Performance benchmarks (measured, not target) | ❌ |
| Accessibility review | ❌ |
| Localization of error strings | ❌ |
| CHANGELOG.md convention | 🚧 File present, one entry |

---

## Definition of Done for v0.2.0

v0.2.0 is complete when **all** of the following are true:

- [ ] At least one real platform HAL is implemented and passes the HAL contract test suite (iOS/AVFoundation or Android/Camera2 NDK accepted).
- [ ] `CameraProController.textureId` returns a live Flutter texture on that platform.
- [ ] `capturePhoto()` returns a valid JPEG byte buffer on that platform.
- [ ] `CameraCapabilities` fields are populated from real device metadata (not stub defaults).
- [ ] At least ISO, shutter speed, and exposure compensation setters produce measurable effect in a capture.
- [ ] FFI bindings are generated by `ffigen` (not hand-written).
- [ ] Dart test count grows by at least 20 integration tests exercising the real backend.
- [ ] `flutter analyze` and `dart format --set-exit-if-changed` remain clean.
- [ ] `CHANGELOG.md` entry for v0.2.0 is present and accurate.

---

## What Unblocks the First Real Device Backend

The stub HAL already conforms to `src/hal/camera_hal.h`. To wire a real backend:

1. Create `src/platform/<platform>/camera_hal_<platform>.c` implementing every function declared in `camera_hal.h`.
2. Update `hook/build.dart` to compile that source file when building for the target platform (the native-assets hook already supports conditional compilation; add an `if (target.os == OS.<platform>)` branch).
3. Register a Flutter texture in the platform channel or via `FlutterTextureRegistry` and return its ID through the HAL's frame-delivery callback.
4. Run `dart run ffigen` once to regenerate bindings if any `camera_pro_core.h` symbols changed.
5. Add platform-specific permission handling (the Dart `CameraPermissionError` type is already defined; wire it to the OS permission result).

No changes to the Dart control-plane, capability model, or error types are expected to be necessary for a basic backend — those layers are designed to be backend-agnostic.
