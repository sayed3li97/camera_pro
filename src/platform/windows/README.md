# Windows HAL Backend

> **🚧 STATUS: SCAFFOLDED — NOT IMPLEMENTED**
>
> This directory is a placeholder for the Windows platform HAL. The C functions
> defined in `src/hal/camera_hal.h` are **not wired** on Windows. All Windows
> builds currently fall through to `src/platform/stub/camera_hal_stub.c`.
> No real camera access, frame delivery, or manual-control path exists yet.

---

## Current Behaviour on Windows

The `camera_pro` SDK compiles and runs on Windows today, but every
`camera_hal_*` call is serviced by the conformant stub backend. That means:

- `camera_hal_list_devices()` returns zero devices.
- `camera_hal_open_device()` returns `CAMERA_ERROR_NOT_SUPPORTED`.
- All capability queries report `NotSupported`.
- The Dart controller tier resolves to `CameraTier.basic` (stub path).
- `CameraPro.nativeCoreVersion` and all C-core processing functions
  (histogram, focus peaking, zebra, buffer pool, YUV conversion) work
  correctly because they live in the platform-independent core.

---

## Target Native API

When this backend is implemented it will be built on the following Windows
platform APIs:

| Concern | Targeted API |
|---|---|
| Device enumeration | `IMFActivate` via `MFEnumDeviceSources` (Media Foundation) |
| Frame capture / preview | `IMFSourceReader` (synchronous or async callback mode) |
| Manual shutter speed | `IAMCameraControl` — `CameraControl_Exposure` property |
| Manual ISO / gain | `IAMVideoProcAmp` — `VideoProcAmp_Gain` property |
| White balance | `IAMVideoProcAmp` — `VideoProcAmp_WhiteBalance` property |
| Focus distance | `IAMCameraControl` — `CameraControl_Focus` property |
| Zoom | `IAMCameraControl` — `CameraControl_Zoom` property |
| GPU compute (optional) | D3D11 compute shaders for histogram / focus-peaking overlay |
| Zero-copy preview texture | D3D11 shared texture → Flutter `TextureRegistry` |
| Still capture | `IMFSinkWriter` or in-band sample grab from `IMFSourceReader` |

All COM/Media Foundation work will be isolated inside this directory and
exposed exclusively through the `camera_hal.h` C interface so the rest of the
SDK remains platform-agnostic.

---

## HAL Contract

Every function declared in `src/hal/camera_hal.h` must be implemented.
The signatures are reproduced here for reference; see the header for full
documentation.

```c
// Lifecycle
int  camera_hal_init(void);
void camera_hal_deinit(void);

// Enumeration
int  camera_hal_list_devices(CameraDeviceInfo* out, int max_count);

// Session
int  camera_hal_open_device(int device_index, CameraSessionHandle* handle_out);
void camera_hal_close_device(CameraSessionHandle handle);

// Capability negotiation
int  camera_hal_query_capabilities(CameraSessionHandle handle,
                                   CameraCapabilitySet* caps_out);

// Control setters
int  camera_hal_set_exposure(CameraSessionHandle handle,
                             double shutter_seconds, int iso);
int  camera_hal_set_white_balance(CameraSessionHandle handle,
                                  int kelvin);
int  camera_hal_set_focus(CameraSessionHandle handle,
                          double normalised_distance);
int  camera_hal_set_zoom(CameraSessionHandle handle,
                         double factor);
int  camera_hal_set_flash(CameraSessionHandle handle,
                          CameraFlashMode mode);

// Frame streaming
int  camera_hal_start_preview(CameraSessionHandle handle,
                              CameraFrameCallback callback,
                              void* user_data);
void camera_hal_stop_preview(CameraSessionHandle handle);

// Still capture
int  camera_hal_capture_photo(CameraSessionHandle handle,
                              CameraCaptureOptions* opts,
                              CameraCaptureCallback callback,
                              void* user_data);
```

---

## Control Mapping Table

The table below shows how each `camera_hal.h` control will map to the
corresponding Windows API property. None of this is wired yet.

| HAL control | Windows interface | Property constant | Units / notes |
|---|---|---|---|
| `shutter_seconds` | `IAMCameraControl` | `CameraControl_Exposure` | Log₂ seconds; must also pass `CameraControl_Flags_Manual` |
| `iso` | `IAMVideoProcAmp` | `VideoProcAmp_Gain` | Linear gain steps; 0 = auto |
| `kelvin` (white balance) | `IAMVideoProcAmp` | `VideoProcAmp_WhiteBalance` | Kelvin; requires `VideoProcAmp_Flags_Manual` |
| `normalised_distance` (focus) | `IAMCameraControl` | `CameraControl_Focus` | Map [0,1] onto `[minVal, maxVal]` returned by `GetRange()` |
| `factor` (zoom) | `IAMCameraControl` | `CameraControl_Zoom` | Map onto `[minVal, maxVal]` from `GetRange()` |
| `flash` | No standard MF API | — | Device-specific or unsupported; report `NotSupported` |

### Capability Discovery via `GetRange()`

`IAMCameraControl::GetRange()` and `IAMVideoProcAmp::GetRange()` return
`(min, max, step, default, flags)`. The implementation must:

1. Call `GetRange()` for each property during `camera_hal_query_capabilities`.
2. If the call succeeds **and** the `flags` field includes the `Manual` bit,
   populate the corresponding `CameraCapabilitySet` field as supported, storing
   `min`, `max`, and `step`.
3. If `GetRange()` fails or returns only the `Auto` flag, report the capability
   as `NotSupported` with an appropriate reason string.

This maps directly onto the Dart `Capability<T>` sealed type:
`Supported<T>(currentValue, minValue, maxValue, stepSize)` vs
`NotSupported<T>(reason)`.

---

## Zero-Copy Preview Plan

The target preview path avoids CPU copies:

1. Configure `IMFSourceReader` to deliver `MF_MT_SUBTYPE = MFVideoFormat_NV12`
   samples directly into a D3D11 texture allocated with
   `D3D11_BIND_SHADER_RESOURCE | D3D11_RESOURCE_MISC_SHARED`.
2. Obtain the shared texture `HANDLE` via `IDXGIResource::GetSharedHandle`.
3. Register the handle with Flutter's `TextureRegistry` using the
   `FlutterDesktopGpuSurfaceDescriptor` path (D3D11 texture variant).
4. The C core's `camera_pro_nv12_to_rgba` scalar converter serves as a CPU
   fallback when the GPU path is unavailable.
5. D3D11 compute shaders (one CS per pass) will replace the C-core scalar
   kernels for histogram, focus-peaking, and zebra overlays once the GPU path
   is established. Until then, the C-core SIMD implementations are used.

---

## How to Contribute This Backend

To wire the Windows HAL and replace the stub:

1. **Create the implementation file.**
   Add `src/platform/windows/camera_hal_windows.c` (or `.cpp` if COM helpers
   are needed). Implement every `camera_hal_*` function listed above.

2. **Guard with the correct preprocessor macro.**
   The build system will define `CAMERA_PRO_PLATFORM_WINDOWS`. Wrap the
   implementation:
   ```c
   #ifdef CAMERA_PRO_PLATFORM_WINDOWS
   // ... implementation ...
   #endif
   ```

3. **Register the source in `hook/build.dart`.**
   Add the new source file to the `CBuilder` sources list and ensure the stub
   is excluded when the Windows source is present:
   ```dart
   // hook/build.dart (illustrative — not the current file)
   final sources = [
     'src/core/camera_pro_core.c',
     'src/core/buffer_pool.c',
     'src/core/image_processor.c',
     'src/core/format_converter.c',
     if (target.os == OS.windows)
       'src/platform/windows/camera_hal_windows.c'
     else
       'src/platform/stub/camera_hal_stub.c',
   ];
   ```

4. **Link Windows system libraries.**
   Add the required libraries to the `CBuilder` `libraries` list:
   `mf`, `mfplat`, `mfreadwrite`, `mfuuid`, `strmiids`, `d3d11`, `dxgi`.

5. **Add a Dart `CameraBackend` implementation.**
   Create `lib/src/platform/windows_camera_backend.dart` implementing the
   `CameraBackend` interface. It should forward every method over FFI into the
   compiled `camera_hal_windows.c` functions. Register it as the default
   backend when `Platform.isWindows` is true inside `CameraPro.create()`.

6. **Write tests.**
   Add integration tests under `test/` that exercise capability negotiation,
   control-setter round-trips, and error paths (device not found, permission
   denied). Mark them `@TestOn('windows')` so they are skipped on other hosts.

7. **Validate against the HAL contract.**
   The existing `src/tests/core_test.c` harness tests the C core only. Add a
   separate `src/tests/hal_windows_test.c` that exercises every `camera_hal_*`
   entry point against a real or virtual camera device.

---

## Checklist (all items are ❌ not started)

- [ ] `camera_hal_windows.c` — device enumeration via `MFEnumDeviceSources`
- [ ] `camera_hal_windows.c` — `IMFSourceReader` session open / close
- [ ] `camera_hal_windows.c` — `GetRange()` → `CameraCapabilitySet` mapping
- [ ] `camera_hal_windows.c` — `IAMCameraControl` / `IAMVideoProcAmp` setters
- [ ] `camera_hal_windows.c` — frame callback delivering NV12 buffers
- [ ] `camera_hal_windows.c` — still-capture path
- [ ] `hook/build.dart` — conditional source and library registration
- [ ] D3D11 shared-texture path → `FlutterDesktopGpuSurfaceDescriptor`
- [ ] D3D11 compute shaders for histogram / focus-peaking / zebra
- [ ] `lib/src/platform/windows_camera_backend.dart` Dart FFI bridge
- [ ] Integration tests tagged `@TestOn('windows')`
- [ ] `hal_windows_test.c` C-level HAL tests
- [ ] CI job running on `windows-latest`

---

*Last updated: 2026-07-01. Toolchain baseline: Flutter 3.44.1 / Dart 3.12.1.*
