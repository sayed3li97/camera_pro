# Android HAL Backend

> 🚧 **SCAFFOLDED — NOT IMPLEMENTED**
>
> This backend does not exist yet. The SDK currently falls back to the conformant
> stub HAL (`src/platform/stub/camera_hal_stub.c`) on every platform, including
> Android. No Camera2 NDK code is wired, no Vulkan compute shaders exist, and no
> Flutter texture registration is in place. Everything below describes the
> *intended* design for a future contributor.

---

## Current status

| Component | Status |
|---|---|
| NDK Camera2 open/close | ❌ Not started |
| AImageReader frame loop | ❌ Not started |
| AHardwareBuffer zero-copy path | ❌ Not started |
| SurfaceProducer → Flutter TextureRegistry | ❌ Not started |
| Capture request control mapping | ❌ Not started |
| Vulkan compute (histogram / focus peaking / zebra) | ❌ Not started |
| Dart `CameraBackend` forwarding layer | ❌ Not started |
| Unit / integration tests | ❌ Not started |

The only working backend today is `StubCameraBackend`, which satisfies the HAL
contract with no-op implementations and returns `CameraTier.basic` with all
capabilities reported as `NotSupported`.

---

## Target native API

### Camera2 NDK (API level 24+)

The Android backend must be built against the **NDK Camera2** C API. The
relevant headers are:

```
<camera/NdkCameraManager.h>
<camera/NdkCameraDevice.h>
<camera/NdkCaptureRequest.h>
<camera/NdkCameraCaptureSession.h>
<camera/NdkImage.h>
<android/hardware_buffer.h>
```

Key objects and their roles:

| NDK type | Purpose |
|---|---|
| `ACameraManager` | Enumerate devices, query characteristics, open a device |
| `ACameraDevice` | Represents one physical or logical camera |
| `ACaptureRequest` | Carries per-frame controls (exposure, ISO, WB, …) |
| `ACameraCaptureSession` | Active session binding outputs to the device |
| `AImageReader` | CPU-accessible image queue for still capture and frame processing |
| `AHardwareBuffer` | GPU-shareable buffer for the zero-copy preview path |

### GPU: Vulkan compute

For histogram computation, focus peaking, and zebra overlays the backend should
dispatch Vulkan compute shaders rather than the scalar C fallback that the
current shared core provides. The shared-core SIMD kernels (`camera_pro_compute_histogram_rgba`,
`camera_pro_compute_focus_peaking`, `camera_pro_compute_zebra`) remain as a CPU
fallback when Vulkan is unavailable (e.g., LEGACY hardware level).

---

## Zero-copy preview: SurfaceProducer → Flutter TextureRegistry

The intended preview pipeline is:

```
ACameraCaptureSession
        │  (AHardwareBuffer stream)
        ▼
AImageReader (AIMAGE_FORMAT_PRIVATE)
        │  acquireLatestImage → AImage_getHardwareBuffer
        ▼
FlutterTextureRegistry::registerTexture()
  → SurfaceProducer (Flutter engine GL/Vulkan surface)
        │
        ▼
Flutter Texture widget  (textureId exposed as controller.textureId)
```

This avoids a CPU round-trip: the `AHardwareBuffer` handle is shared directly
with the Flutter engine's compositor without copying pixels through Dart memory.

The `textureId` field on `CameraProController` is reserved for this handle. It
is `null` today because no real HAL is wired.

---

## Implementing `src/hal/camera_hal.h`

Every function declared in `src/hal/camera_hal.h` must have a non-stub
implementation in this backend. The contract is reproduced below for reference:

```c
/* Lifecycle */
int  camera_hal_initialize(void);
void camera_hal_shutdown(void);

/* Device enumeration */
int  camera_hal_get_device_count(void);
int  camera_hal_get_device_info(int index, CameraDeviceInfo *out);

/* Session */
int  camera_hal_open(int device_index, const CameraOpenParams *params,
                     CameraHandle *out_handle);
void camera_hal_close(CameraHandle handle);

/* Streaming */
int  camera_hal_start_preview(CameraHandle handle, CameraPreviewConfig *cfg);
void camera_hal_stop_preview(CameraHandle handle);

/* Controls */
int  camera_hal_set_exposure_time_ns(CameraHandle handle, int64_t ns);
int  camera_hal_set_sensitivity(CameraHandle handle, int32_t iso);
int  camera_hal_set_wb_temperature(CameraHandle handle, int32_t kelvin);
int  camera_hal_set_af_distance(CameraHandle handle, float normalised);
int  camera_hal_set_zoom(CameraHandle handle, float ratio);
int  camera_hal_set_flash_mode(CameraHandle handle, CameraFlashMode mode);

/* Still capture */
int  camera_hal_capture_still(CameraHandle handle,
                               const CameraStillConfig *cfg,
                               CameraImageBuffer *out);
void camera_hal_free_image(CameraImageBuffer *buf);

/* Capabilities */
int  camera_hal_get_capabilities(CameraHandle handle,
                                  CameraCapabilitySet *out);
```

All functions must return `CAMERA_HAL_OK` (0) on success or a negative
`CAMERA_HAL_ERR_*` code on failure. Returning `CAMERA_HAL_ERR_NOT_SUPPORTED`
for an unimplemented control is acceptable as long as the session remains valid.

---

## Control mapping table

The table below shows how `CameraProController` setter calls must map to
Camera2 NDK capture request keys. `AE_MODE` must be set to
`ACAMERA_CONTROL_AE_MODE_OFF` before any manual exposure key takes effect.

| Dart setter | ACaptureRequest key | Notes |
|---|---|---|
| `setShutterSpeed(ShutterSpeed)` | `ACAMERA_SENSOR_EXPOSURE_TIME` (int64 ns) | Requires `ACAMERA_CONTROL_AE_MODE_OFF` |
| `setIso(Iso)` | `ACAMERA_SENSOR_SENSITIVITY` (int32) | Requires `ACAMERA_CONTROL_AE_MODE_OFF` |
| `setExposureCompensation(Ev)` | `ACAMERA_CONTROL_AE_EXPOSURE_COMPENSATION` (int32 steps) | Only valid in auto-AE modes |
| `setWhiteBalance(WhiteBalance.preset)` | `ACAMERA_CONTROL_AWB_MODE` (enum) | Map `WhiteBalanceMode` → NDK constant |
| `setWhiteBalance(WhiteBalance.temperature)` | `ACAMERA_COLOR_CORRECTION_MODE` = `TRANSFORM_MATRIX` + `ACAMERA_COLOR_CORRECTION_GAINS` (float[4]) | Kelvin → RGGB gains conversion required |
| `setFocusDistance(double)` | `ACAMERA_LENS_FOCUS_DISTANCE` (float, dioptres) | Requires `ACAMERA_CONTROL_AF_MODE_OFF` |
| `setZoom(double)` | `ACAMERA_SCALER_CROP_REGION` (rect) | Compute crop from active array size |
| `setFlashMode(FlashMode)` | `ACAMERA_FLASH_MODE` + `ACAMERA_CONTROL_AE_MODE` | `TORCH` maps to `AE_MODE_ON_ALWAYS_FLASH` |

---

## Hardware level → CameraTier mapping

Query `ACAMERA_INFO_SUPPORTED_HARDWARE_LEVEL` from `ACameraManager` during
`camera_hal_get_capabilities`. Map as follows:

| Camera2 hardware level | `CameraTier` | Notes |
|---|---|---|
| `ACAMERA_INFO_SUPPORTED_HARDWARE_LEVEL_LEGACY` | `basic` | No per-frame controls; limited format support |
| `ACAMERA_INFO_SUPPORTED_HARDWARE_LEVEL_LIMITED` | `standard` | Per-frame controls available; no RAW |
| `ACAMERA_INFO_SUPPORTED_HARDWARE_LEVEL_FULL` | `full` | Full manual control + RAW |
| `ACAMERA_INFO_SUPPORTED_HARDWARE_LEVEL_3` | `full` | Level 3 superset; treat same as FULL |

The `determineTier(CameraCapabilities)` function in
`lib/src/models/camera_tier.dart` will derive the tier from the `CameraCapabilities`
passport that the HAL populates, so the HAL only needs to fill the capabilities
struct correctly; tier selection is handled in Dart.

---

## Dart forwarding layer

Once the C backend is wired, a Dart class must be added at
`lib/src/platform/android_camera_backend.dart` implementing the `CameraBackend`
interface. It forwards each call over FFI to the compiled
`libcamera_pro_core.so` (which must link the Android HAL object). Pass this
backend to `CameraPro.create(backend: AndroidCameraBackend())` or register it
as the default when `Platform.isAndroid` is true inside `CameraPro.create`.

```dart
// Sketch only — not implemented
class AndroidCameraBackend implements CameraBackend {
  @override
  Future<List<CameraDevice>> enumerateDevices() async { ... }

  @override
  Future<CameraCapabilities> openDevice(CameraDevice device) async { ... }

  // ... all other CameraBackend members ...
}
```

---

## How to contribute this backend

1. Create `src/platform/android/camera_hal_android.c` (and supporting files).
2. Implement every `camera_hal_*` function declared in `src/hal/camera_hal.h`.
3. Update `hook/build.dart` to compile and link the new source files when
   `buildConfig.targetOS == OS.android`.
4. Update `ffigen.yaml` if any new C symbols need a Dart binding.
5. Add `lib/src/platform/android_camera_backend.dart` implementing `CameraBackend`.
6. Wire automatic selection in `CameraPro.create` for `Platform.isAndroid`.
7. Add unit tests in `test/` and integration tests under `example/`.
8. Update `src/platform/android/README.md` to change ❌ rows above to ✅ as
   work lands, and add measured (not target) benchmark data.

> **Important:** Do not change the public `CameraProController` API or the
> `camera_hal.h` contract without a coordinated update to all platforms and
> tests. The HAL boundary is the only stable ABI between native and Dart.
