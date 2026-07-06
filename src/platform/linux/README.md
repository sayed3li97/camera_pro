# Linux Platform Backend

> **✅ C HAL implemented + CI-verified · 🚧 Dart wiring pending**
>
> [`camera_hal_linux.c`](camera_hal_linux.c) implements the full 44-function [`camera_hal.h`](../../hal/camera_hal.h) contract against V4L2 (`/dev/video*` enumeration, `VIDIOC_QUERYCTRL` capability mapping, manual controls via V4L2 CIDs, mmap streaming with a pthread capture loop). It compiles with `gcc -Werror` and passes the portable lifecycle harness on a real ubuntu runner every push (see `.github/workflows/native.yml`). **Gaps:** not yet exposed through a Dart `CameraBackend` (desktop Dart falls back to the stub), and — with no camera on CI runners — the hardware capture path has never been exercised.

---

## Project Status

| Item | Status |
|---|---|
| HAL contract (`src/hal/camera_hal.h`) | ✅ Defined |
| Stub backend (used on Linux today) | ✅ Implemented & verified |
| Linux V4L2 backend | 🚧 Not started |
| DMABUF / mmap zero-copy streaming | 🚧 Not started |
| OpenGL compute shaders | 🚧 Not started |
| libcamera optional backend | 🚧 Not started |
| Dart `CameraBackend` FFI bridge | 🚧 Not started |

---

## Target Native API

### Primary: V4L2 ioctl Interface

The primary implementation target is the **Video4Linux2 (V4L2)** kernel subsystem, accessible via `<linux/videodev2.h>`. V4L2 is the standard capture interface on Linux desktops and embedded SBCs (Raspberry Pi, NVIDIA Jetson, etc.).

Key V4L2 entry points this backend will use:

```c
#include <linux/videodev2.h>
#include <sys/ioctl.h>
#include <sys/mman.h>

// Device enumeration
VIDIOC_QUERYCAP          // verify V4L2_CAP_VIDEO_CAPTURE
VIDIOC_ENUM_FMT          // enumerate supported pixel formats
VIDIOC_ENUM_FRAMESIZES   // enumerate frame dimensions

// Control discovery & manipulation
VIDIOC_QUERYCTRL         // check if a CID is supported + get range
VIDIOC_G_CTRL / VIDIOC_S_CTRL   // get/set integer controls
VIDIOC_G_EXT_CTRLS / VIDIOC_S_EXT_CTRLS  // extended controls (menus, 64-bit)

// Buffer management
VIDIOC_REQBUFS           // allocate kernel buffers
VIDIOC_QUERYBUF          // query buffer addresses/offsets
VIDIOC_QBUF / VIDIOC_DQBUF  // enqueue / dequeue frames
VIDIOC_STREAMON / VIDIOC_STREAMOFF

// Format negotiation
VIDIOC_S_FMT / VIDIOC_G_FMT
VIDIOC_S_PARM / VIDIOC_G_PARM  // frame rate
```

### Optional: libcamera

For embedded targets (Raspberry Pi CSI cameras, ISP-integrated sensors) where the V4L2 control interface is insufficient or bypassed by a proprietary ISP, an optional **libcamera** path is planned. libcamera provides a unified C++ API that handles ISP tuning, sensor bring-up, and 3A algorithms. The build system will detect libcamera via `pkg-config libcamera` and compile in the libcamera sub-backend when present.

### GPU Compute: OpenGL ES Compute Shaders

For preview processing (YUV→RGBA conversion, focus peaking overlay, zebra pattern), the Linux backend targets **OpenGL ES 3.1 compute shaders** (or OpenGL 4.3 on desktop). This offloads per-frame processing from the C core's scalar/SIMD path to the GPU, reducing CPU load during live preview. The C core implementations remain the fallback when a GL context is unavailable.

---

## How This Backend Will Implement `src/hal/camera_hal.h`

The HAL contract lives in `src/hal/camera_hal.h`. Every function in that header must be implemented in a single translation unit (or a set of units compiled together) that is conditionally included on Linux. The planned source file is `src/platform/linux/camera_hal_linux.c`.

The implementation must satisfy every `camera_hal_*` function signature defined in the HAL header:

```
camera_hal_enumerate_devices()    — walk /dev/video*, call VIDIOC_QUERYCAP
camera_hal_open()                 — open(2) the device node, VIDIOC_QUERYCAP
camera_hal_close()                — VIDIOC_STREAMOFF, close(2)
camera_hal_get_capabilities()     — VIDIOC_QUERYCTRL loop over known CIDs
camera_hal_configure()            — VIDIOC_S_FMT, VIDIOC_S_PARM
camera_hal_start_stream()         — VIDIOC_REQBUFS, mmap/DMABUF, VIDIOC_STREAMON
camera_hal_stop_stream()          — VIDIOC_STREAMOFF, unmap, VIDIOC_REQBUFS(count=0)
camera_hal_dequeue_frame()        — VIDIOC_DQBUF (blocking or with select/poll)
camera_hal_release_frame()        — VIDIOC_QBUF
camera_hal_set_control()          — VIDIOC_S_CTRL or VIDIOC_S_EXT_CTRLS
camera_hal_get_control()          — VIDIOC_G_CTRL or VIDIOC_G_EXT_CTRLS
camera_hal_capture_still()        — single-frame acquisition or separate capture device
```

All error paths must map to the `CameraProError` codes defined in `camera_pro_types.h`.

---

## Control Mapping Table

The table below maps `camera_pro` logical controls to their V4L2 control IDs. Capability detection uses `VIDIOC_QUERYCTRL`: if the query returns `EINVAL` or the control has flag `V4L2_CTRL_FLAG_DISABLED`, the corresponding `Capability<T>` in the Dart layer reports `NotSupported`.

| camera_pro control | V4L2 Control ID | Units / Notes |
|---|---|---|
| Shutter speed | `V4L2_CID_EXPOSURE_ABSOLUTE` | 100 µs units; requires `V4L2_CID_EXPOSURE_AUTO` = `V4L2_EXPOSURE_MANUAL` (`V4L2_CID_EXPOSURE_AUTO` must be set first) |
| ISO / gain | `V4L2_CID_GAIN` (or `V4L2_CID_ISO_SENSITIVITY`) | Sensor-specific units; `VIDIOC_QUERYCTRL` provides min/max/step |
| Focus distance | `V4L2_CID_FOCUS_ABSOLUTE` | Device-specific units (steps); requires `V4L2_CID_FOCUS_AUTO = 0` |
| White balance temperature | `V4L2_CID_WHITE_BALANCE_TEMPERATURE` | Kelvin; requires `V4L2_CID_AUTO_WHITE_BALANCE = 0` |
| Exposure compensation | `V4L2_CID_AUTO_EXPOSURE_BIAS` | In steps (driver-defined); only meaningful in auto-exposure modes |
| Zoom | `V4L2_CID_ZOOM_ABSOLUTE` | Device-specific steps |
| Flash mode | `V4L2_CID_FLASH_LED_MODE` | V4L2 flash sub-device (`/dev/v4l-subdev*`) |
| Autofocus trigger | `V4L2_CID_AUTO_FOCUS_START` | One-shot; `V4L2_CID_AUTO_FOCUS_STOP` to cancel |
| Auto white balance | `V4L2_CID_AUTO_WHITE_BALANCE` | Boolean |
| Auto exposure mode | `V4L2_CID_EXPOSURE_AUTO` | `V4L2_EXPOSURE_AUTO` / `V4L2_EXPOSURE_MANUAL` / etc. |

**Capability discovery pattern:**

```c
struct v4l2_queryctrl qc = { .id = V4L2_CID_EXPOSURE_ABSOLUTE };
if (ioctl(fd, VIDIOC_QUERYCTRL, &qc) == 0 &&
    !(qc.flags & V4L2_CTRL_FLAG_DISABLED)) {
    // control is supported; populate Capability<T> with qc.minimum/maximum/step
} else {
    // report NotSupported
}
```

---

## Zero-Copy Preview Plan

The Linux backend will use **mmap or DMABUF** buffer sharing to avoid copying frame data from kernel to userspace on every frame.

**mmap path (universally supported):**

1. `VIDIOC_REQBUFS` with `memory = V4L2_MEMORY_MMAP` to allocate `N` kernel buffers (target: 4).
2. `VIDIOC_QUERYBUF` + `mmap(2)` to map each buffer into the process address space.
3. `VIDIOC_QBUF` all buffers, then `VIDIOC_STREAMON`.
4. `poll(2)` or `select(2)` on the device fd; on readiness call `VIDIOC_DQBUF`.
5. Pass the mapped pointer directly into `camera_pro_buffer_pool_acquire` so the C core's lock-free buffer pool holds the live kernel buffer.
6. After the frame is consumed, `VIDIOC_QBUF` to return the buffer to the kernel.

**DMABUF path (for GPU pipeline, when available):**

1. Allocate DMA-BUF handles via the GPU driver (e.g. `/dev/dri/renderD128` with GBM, or EGL image extensions).
2. `VIDIOC_REQBUFS` with `memory = V4L2_MEMORY_DMABUF`.
3. `VIDIOC_QBUF` with `m.fd` set to the DMA-BUF file descriptor.
4. The GPU compute shader reads directly from the DMA-BUF without any CPU copy.

The zero-copy path is a target architecture, not an implemented feature.

---

## How to Contribute This Backend

If you want to implement the Linux V4L2 backend, here is what is required:

### 1. Implement all HAL functions

Create `src/platform/linux/camera_hal_linux.c` and implement every function declared in `src/hal/camera_hal.h`. Use the stub at `src/platform/stub/camera_hal_stub.c` as a reference for expected return conventions and error handling patterns.

Compile and run the C test harness to verify the core remains passing:

```sh
clang -std=c11 -O2 -Wall -Wextra -Werror \
      src/tests/core_test.c \
      src/core/buffer_pool.c \
      src/core/image_processor.c \
      src/core/format_converter.c \
      src/core/camera_pro_core.c \
      -o core_test && ./core_test
# Expected: 36/36 checks pass
```

### 2. Register sources in the native-assets build

Edit `hook/build.dart`. The build hook uses `package:native_toolchain_c` to compile the C core. Add the Linux HAL sources conditionally:

```dart
// In hook/build.dart, inside the CBuilder.library() sources list:
if (Platform.isLinux) ...[
  'src/platform/linux/camera_hal_linux.c',
],
```

Add any required system link flags (e.g. `-lv4l2` if using libv4l2 for format emulation):

```dart
if (Platform.isLinux) ...[
  '-lv4l2',   // optional; direct ioctl needs no extra lib
],
```

### 3. Add a Dart CameraBackend forwarding over FFI

Create a new class in `lib/src/platform/` (e.g. `linux_camera_backend.dart`) that:

- Extends or implements `CameraBackend`.
- Calls the FFI-bound `camera_hal_*` functions via the bindings generated by `ffigen.yaml`.
- Translates HAL error codes to the appropriate `CameraProError` subclass.
- Returns a populated `CameraCapabilities` by calling `camera_hal_get_capabilities()` and mapping each V4L2 control query result to `Supported<T>` or `NotSupported<T>`.

Register this backend in `lib/src/platform/platform_camera_backend.dart` behind a `Platform.isLinux` guard so `CameraPro.create()` picks it up automatically.

### 4. Add tests

- A unit test for the Dart backend using `CameraProController.forTesting()`.
- A Dart integration test (device-lab only) that opens a real `/dev/video0` and asserts `controller.state == CameraState.ready`.

### 5. Update the top-level README and CHANGELOG

Mark the Linux backend as implemented and document any known driver compatibility caveats.

---

## Current Behaviour on Linux

Until this backend is implemented, `CameraPro.create()` on Linux returns a controller backed by `StubCameraBackend`. All capabilities report `NotSupported`, `controller.tier` is `CameraTier.basic`, and `capturePhoto()` returns a stub result. No real camera device is opened. This is intentional and safe.

```dart
final controller = await CameraPro.create(); // uses StubCameraBackend on Linux today
print(controller.tier);  // CameraTier.basic
print(CameraPro.nativeCoreVersion);  // "0.0.2" — real FFI call into libcamera_pro_core
```

---

## References

- [Linux Kernel V4L2 API Documentation](https://www.kernel.org/doc/html/latest/userspace-api/media/v4l/v4l2.html)
- [V4L2 Control IDs — `<linux/videodev2.h>`](https://www.kernel.org/doc/html/latest/userspace-api/media/v4l/control.html)
- [libcamera project](https://libcamera.org/)
- [DMABUF in V4L2](https://www.kernel.org/doc/html/latest/userspace-api/media/v4l/dmabuf.html)
- `src/hal/camera_hal.h` — HAL contract this backend must satisfy
- `src/platform/stub/camera_hal_stub.c` — reference conformant implementation
