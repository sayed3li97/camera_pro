# Web Backend — `camera_pro`

> **✅ STATUS: Implemented and live-verified in Chrome.**
> `WebCameraBackend` drives the camera via `navigator.mediaDevices.getUserMedia`
> (preview via `<video>`→`<canvas>` readback). All six manual controls run
> through a pure-Dart digital pipeline (→ `CameraTier.full`); the visual-aid
> kernels are pure-Dart ports of the C core (byte-identical, cross-checked);
> RAW capture uses a pure-Dart linear-DNG encoder; video recording uses
> `MediaRecorder`. Conditional imports keep `dart:ffi`/`dart:io` off the web
> tree. Sample app: [`example/lib/web_main.dart`](../../../example/lib/web_main.dart).

---

## Project Status

| Area | Status |
|---|---|
| `camera_hal.h` contract on Web | 🚧 designed, not implemented |
| Dart JS interop layer | 🚧 designed, not implemented |
| `MediaDevices.getUserMedia` integration | 🚧 designed, not implemented |
| `ImageCapture` / `MediaStreamTrack` constraints | 🚧 designed, not implemented |
| `WebCodecs VideoFrame` pipeline | 🚧 designed, not implemented |
| WebGPU (WGSL) compute shaders | 🚧 designed, not implemented |
| Flutter texture registration | 🚧 designed, not implemented |
| Dart `CameraBackend` forwarding | 🚧 designed, not implemented |
| **Currently used on Web** | ✅ `StubCameraBackend` (no-op) |

If you call `CameraPro.create()` in a Flutter Web build today, you receive a controller backed by
the conformant stub HAL. Every capability returns `NotSupported`, `tier` is `CameraTier.basic`,
and `nativeCoreVersion` returns the version string from the pre-compiled C core (loaded via
WASM or skipped on Web — exact behaviour subject to change).

---

## Target Native API Surface

Unlike the Android, Apple, Windows and Linux backends, the Web backend has **no C/C++ layer**.
The shared C core (`libcamera_pro_core`) handles CPU-side image processing and is intended to be
compiled to WebAssembly. The camera access and control path is purely Dart via `dart:js_interop`.

### Browser APIs targeted

| API | Purpose |
|---|---|
| `MediaDevices.getUserMedia(constraints)` | Open a camera stream; supply `video` constraints for resolution, frame rate, facing mode |
| `MediaDevices.enumerateDevices()` | Discover available `videoinput` devices; populate `availableCameras()` |
| `MediaStreamTrack.getCapabilities()` | Read hardware capability ranges (ISO, exposure time, white balance, zoom, torch) |
| `MediaStreamTrack.getSettings()` | Read current setting values |
| `MediaStreamTrack.applyConstraints(constraints)` | Apply control changes (shutter speed, ISO, white balance, zoom, torch) |
| `ImageCapture` | `takePhoto()` for still capture; `grabFrame()` for `ImageBitmap` preview frames |
| `WebCodecs VideoFrame` | Zero-copy access to decoded YUV or RGBA frame data from a `MediaStreamTrackProcessor` |
| `WebGPU` (WGSL compute shaders) | GPU-accelerated histogram, focus-peaking overlay, zebra overlay |

#### Browser compatibility notes (target, not measured)

| Feature | Chromium | Safari | Firefox |
|---|---|---|---|
| `getUserMedia` + constraints | Full | Partial | Partial |
| `ImageCapture` | Yes | Limited | No (flag) |
| `MediaStreamTrackProcessor` | Yes | No | No |
| `WebCodecs VideoFrame` | Yes | Safari 17+ | Partial |
| `WebGPU` | Yes (stable) | Safari 18+ (partial) | Behind flag |
| Extended constraints (ISO, exposureTime, zoom) | Yes | No | No |
| Expected `CameraTier` | `standard` | `basic` | `basic` |

---

## How the Web Backend Will Implement `src/hal/camera_hal.h`

`src/hal/camera_hal.h` defines the C platform-abstraction contract. Because there is no native
C/C++ camera access on the web, the Web backend implements this contract differently from other
platforms:

1. **Dart-side JS interop** replaces C HAL functions. A Dart class
   `WebCameraBackend implements CameraBackend` calls browser APIs directly.
2. **WASM bridge** (planned): the C core (`libcamera_pro_core`) is compiled to WASM by the
   native-assets hook for Web targets. The `camera_hal_*` function pointers in
   `camera_hal.h` are satisfied by thin C shims that `__import__` Dart/JS callbacks rather than
   calling platform OS APIs.
3. **FFI on Web**: Dart's `dart:ffi` is not supported on Web. Instead, `NativeCore` and
   `NativeBufferPool` on Web call the WASM module via `dart:js_interop` wrappers generated from
   the same `ffigen.yaml` (with a Web-specific output target, not yet written).

The functions that must be implemented / forwarded:

| `camera_hal.h` function | Web mapping |
|---|---|
| `camera_hal_open(device_id, config, out_handle)` | `getUserMedia({video: {deviceId, ...constraints}})` |
| `camera_hal_close(handle)` | `MediaStreamTrack.stop()` |
| `camera_hal_get_capabilities(handle, out_caps)` | `MediaStreamTrack.getCapabilities()` → populate `CameraCapabilities` |
| `camera_hal_get_frame(handle, out_buf)` | `MediaStreamTrackProcessor` → `ReadableStream<VideoFrame>` → copy/map to buffer pool slot |
| `camera_hal_capture_still(handle, format, out_buf)` | `ImageCapture.takePhoto()` → decode Blob → copy to buffer |
| `camera_hal_apply_settings(handle, settings)` | `MediaStreamTrack.applyConstraints(...)` |
| `camera_hal_set_torch(handle, on)` | `applyConstraints({advanced: [{torch: on}]})` |

---

## Control Mapping Table

The table below shows how each `CameraProController` setter is handled. Most
browsers expose no sensor controls via `MediaStreamTrack`, so — like the macOS
built-in camera — they run through the pure-Dart digital pipeline
(`NativeCore.adjustPixels`/`digitalZoom`/`boxBlur`).

| Dart setter | `applyConstraints` key | Unit / notes |
|---|---|---|
| `setShutterSpeed(ShutterSpeed)` | `advanced: [{exposureTime: µs}]` | `ShutterSpeed` stores nanoseconds internally; divide by 1 000 for µs. Requires `exposureMode: "manual"`. Chromium only. |
| `setIso(Iso)` | `advanced: [{iso: value}]` | Chromium only; Safari/Firefox: `NotSupported`. |
| `setExposureCompensation(Ev)` | `advanced: [{exposureCompensation: ev}]` | EV float; available on more browsers than manual ISO/shutter. |
| `setWhiteBalance(WhiteBalance)` | `advanced: [{colorTemperature: K}]` (temperature) or `whiteBalanceMode: "manual"/"continuous"` | Kelvin range varies by device. |
| `setFocusDistance(double)` | `advanced: [{focusDistance: d}]` with `focusMode: "manual"` | Normalised 0.0–1.0 or device-specific range; to be determined at `getCapabilities()` time. |
| `setZoom(double)` | `advanced: [{zoom: factor}]` | Factor; `getCapabilities().zoom.{min,max,step}` gates the `Supported<double>` capability. |
| `setFlashMode(FlashMode)` | `advanced: [{torch: bool}]` (torch) / `ImageCapture.takePhoto({fillLightMode})` (flash) | `FlashMode.torch` → `torch`; `FlashMode.on`/`off`/`auto` → `fillLightMode` on `takePhoto`. |

### `getCapabilities()` → Capability Passport

`MediaStreamTrack.getCapabilities()` returns a `MediaTrackCapabilities` dictionary. The Web
backend will map each range to a `Supported<T>` or `NotSupported<T>`:

```dart
// Pseudocode — NOT yet implemented
final raw = track.getCapabilities();
final iso = raw.iso != null
    ? Supported<int>(
        currentValue: raw.getSettings().iso,
        minValue: raw.iso!.min.toInt(),
        maxValue: raw.iso!.max.toInt(),
        stepSize: raw.iso!.step?.toInt(),
      )
    : const NotSupported<int>(reason: 'ISO not exposed by this browser/device');
```

On Safari and Firefox, most advanced constraints are absent from `getCapabilities()`, so the
passport will contain mostly `NotSupported` entries, yielding `CameraTier.basic`.
On Chromium with a compatible device, ISO, shutter speed, and zoom may all be
`Supported`, yielding `CameraTier.standard`. `CameraTier.full` (RAW capture, aperture control)
is not reachable via browser APIs.

---

## Zero-Copy Preview Plan

The intended preview path on Chromium:

```
MediaStreamTrack
  └─ MediaStreamTrackProcessor
       └─ ReadableStream<VideoFrame>          ← VideoFrame holds GPU/CPU data
            └─ VideoFrame.copyTo(Uint8List)   ← one copy into a NativeBufferPool slot
                 └─ camera_pro_compute_histogram_rgba (C core / WASM)
                 └─ Flutter GPU texture upload via dart:ui Image.fromPixels
```

On browsers without `MediaStreamTrackProcessor` (Safari, Firefox), the fallback is
`ImageCapture.grabFrame()` → `ImageBitmap` → Canvas 2D `drawImage` → `getImageData`.
This involves an extra GPU→CPU readback and is slower.

WebGPU compute (when available) bypasses the CPU copy for histogram and focus-peaking:
`VideoFrame` is imported as a `GPUExternalTexture` and the WGSL compute shader writes
results to a `GPUBuffer` mapped back to Dart. This path is entirely unwritten.

---

## How to Contribute This Backend

To implement the Web backend from scratch:

### 1. Implement every `camera_hal_*` function

Create `src/platform/web/camera_hal_web.c` (for WASM) **or** a pure-Dart equivalent in
`lib/src/platform/web/`. If using WASM, the file must be listed in `hook/build.dart` under
the `web` target and compiled with Emscripten or the Dart native-assets WASM toolchain (not
yet supported by `package:native_toolchain_c` — check current Flutter/Dart roadmap before
starting).

The pure-Dart approach is simpler for now:

```
lib/src/platform/web/
  web_camera_backend.dart       ← implements CameraBackend
  web_hal_bindings.dart         ← dart:js_interop declarations for browser APIs
  web_capability_mapper.dart    ← MediaTrackCapabilities → CameraCapabilities
  web_control_mapper.dart       ← Dart setters → applyConstraints calls
```

### 2. Declare JS interop types

Use `dart:js_interop` (not `dart:html`) per current Dart guidance:

```dart
import 'dart:js_interop';

@JS('MediaDevices')
extension type MediaDevices._(JSObject _) implements JSObject {
  external JSPromise<JSArray<MediaDeviceInfo>> enumerateDevices();
  external JSPromise<MediaStream> getUserMedia(MediaStreamConstraints constraints);
}
// ... MediaStreamTrack, MediaTrackCapabilities, ImageCapture, etc.
```

### 3. Register the backend

In `lib/src/platform/camera_backend_registry.dart` (to be created), detect the web platform
and return `WebCameraBackend()` instead of `StubCameraBackend()`:

```dart
CameraBackend defaultBackend() {
  if (kIsWeb) return WebCameraBackend();
  // ... other platforms
  return StubCameraBackend();
}
```

### 4. Add Dart tests

Add tests under `test/platform/web/` using `package:mocktail` to mock the JS interop layer.
Tests must pass with `flutter test --platform chrome`.

### 5. Update `hook/build.dart`

If a WASM C core is produced, add a `BuildConfig.targetOS == OS.browser` branch that
invokes Emscripten and outputs a `.wasm` + `.js` glue file as a code asset.

### 6. Confirm the capability passport

Run `flutter run -d chrome` against the example app and verify that:
- `CameraPro.availableCameras()` lists real devices.
- `controller.capabilities` returns `Supported<T>` for zoom (most browsers) and
  extended constraints (Chromium with compatible hardware).
- `controller.tier` is `CameraTier.standard` on Chromium, `CameraTier.basic` on Safari.
- `capturePhoto()` returns a `Uint8List` JPEG.

---

## What Is Wired Today (Web)

Nothing. When running under `flutter run -d chrome`:

- `CameraPro.create()` returns a controller backed by `StubCameraBackend`.
- All capabilities return `NotSupported`.
- `tier` is `CameraTier.basic`.
- `nativeCoreVersion` and `simdKernel` values depend on whether the C core is compiled to
  WASM for the web target; this is not yet configured.
- No camera frames are produced, no preview is shown, and `capturePhoto()` throws
  `CameraFeatureNotSupportedError`.

The stub backend is conformant — it satisfies the `camera_hal.h` contract and exercises the
full Dart control-plane (state machine, typed errors, capability passport) — so the Dart layer
can be developed and tested without a real browser camera.

---

## Related Files

| Path | Description |
|---|---|
| `src/hal/camera_hal.h` | C HAL contract this backend must satisfy |
| `src/platform/stub/camera_hal_stub.c` | Reference conformant no-op implementation |
| `lib/src/platform/` | Dart platform abstraction (`CameraBackend` interface, `StubCameraBackend`) |
| `lib/src/models/capabilities.dart` | `Capability<T>`, `CameraCapabilities`, `CameraTier` |
| `lib/src/models/errors.dart` | Sealed `CameraProError` hierarchy |
| `hook/build.dart` | Native-assets build hook (extend for WASM) |
| `ffigen.yaml` | FFI binding generator config (extend for Web WASM target) |

---

*camera_pro v0.0.2 — BSD-3-Clause*
