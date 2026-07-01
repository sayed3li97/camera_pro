# camera_pro

A Flutter camera package built on a shared C/C++ core with a crash-proof Dart API and a capability passport pattern — designed for production-quality camera UX across all platforms.

---

> **Project status: early foundation (v0.1.0)**
>
> The architectural skeleton is complete and verified. The C core (SIMD processing, lock-free buffer pool, format conversion, focus peaking, zebra), the Dart control-plane (capability passport, typed state machine, typed errors, FFI wiring), and the stub HAL backend all pass their full test suites. Real platform camera access (Android, iOS, macOS, Windows, Linux, Web) is **not yet wired** — you get a conformant stub backend until native HAL implementations land. This README is explicit about what is ✅ done vs 🚧 designed-but-not-yet-native-wired vs ❌ not started.

---

## Why camera_pro?

Most Flutter camera packages wrap platform APIs directly and surface raw exceptions. `camera_pro` takes a different approach:

| Design choice | What it means for you |
|---|---|
| **Shared C core** | Image processing (histograms, YUV→RGBA conversion, focus peaking, zebra) runs the same bit-exact code on every platform, compiled with SIMD where available (NEON on arm64). |
| **HAL abstraction** | A C platform-abstraction layer (`camera_hal.h`) separates the core from each platform backend. Adding a new platform means implementing one HAL contract, not forking the whole package. |
| **Capability passport** | Every feature the camera reports is a `Capability<T>` — either `Supported<T>` (with current value, min, max, step) or `NotSupported<T>` (with a reason string). Your UI never crashes trying to set a feature the device doesn't have. |
| **Typed errors** | A sealed `CameraProError` hierarchy with a `CameraErrorRecovery` hint on every error. No raw platform exceptions bubble up unchecked. |
| **Dart FFI + native assets** | The C core is compiled automatically at build time via Flutter's native-assets hook. No manual `.so`/`.dylib` bundling. |
| **Tier system** | `CameraTier { full, standard, basic }` is derived from the capability passport. Your UI can adapt layout to what the hardware actually supports. |

---

## Feature status

### Architecture

| Feature | Status | Notes |
|---|---|---|
| Shared C core (camera_pro_core.h) | ✅ | Compiles on macOS arm64, Windows, Linux via native-assets |
| Lock-free buffer pool (C) | ✅ | 36/36 C tests pass |
| NEON SIMD histogram kernel | ✅ | Bit-exact vs scalar reference, cross-checked on arm64 |
| Scalar fallback histogram | ✅ | Active when NEON unavailable |
| YUV→RGBA format conversion (YUV420p, NV12, NV21) | ✅ | Scalar; SIMD path is 🚧 |
| native-assets FFI build hook | ✅ | hook/build.dart, verified end-to-end |
| Dart capability passport | ✅ | `Capability<T>`, `Supported<T>`, `NotSupported<T>` |
| Dart typed error hierarchy | ✅ | Sealed `CameraProError` + `CameraErrorRecovery` |
| Dart state machine | ✅ | `CameraState` + `stateChanges` stream |
| Tier selection (`determineTier`) | ✅ | Derived from capabilities |
| Conformant stub HAL backend | ✅ | All HAL contract methods implemented as no-ops |
| Android NDK Camera2 HAL | 🚧 | HAL contract defined; native side not wired |
| Apple AVFoundation HAL (iOS/macOS) | ✅* | Control-plane done & verified: enumeration, capabilities, manual controls. Preview/capture 🚧 |
| Windows Media Foundation HAL | 🚧 | HAL contract defined; native side not wired |
| Linux V4L2 HAL | 🚧 | HAL contract defined; native side not wired |
| Web (getUserMedia) HAL | 🚧 | HAL contract defined; native side not wired |
| Flutter texture registration | 🚧 | API surface designed; not connected |

### Manual controls

| Feature | Status | Notes |
|---|---|---|
| ISO setter (`setIso`) | ✅ | Capability-guarded; throws `CameraFeatureNotSupportedError` if not supported |
| Shutter speed setter (`setShutterSpeed`) | ✅ | Capability-guarded |
| Exposure compensation setter (`setExposureCompensation`) | ✅ | Capability-guarded |
| White balance setter (`setWhiteBalance`) | ✅ | Preset and temperature modes |
| Focus distance setter (`setFocusDistance`) | ✅ | Capability-guarded |
| Zoom setter (`setZoom`) | ✅ | Capability-guarded |
| Flash mode setter (`setFlashMode`) | ✅ | Capability-guarded |
| Aperture control | 🚧 | Capability modelled; no hardware exposes it on mobile |
| Manual controls — iOS (sensor) | ✅ | Wired to `AVCaptureDevice`: custom exposure duration + ISO, lens position, WB gains, zoom, torch — compiled against the iOS SDK |
| Manual controls — macOS (digital) | ✅ | The built-in camera exposes **no** sensor controls (measured across AVFoundation, CoreMediaIO, and IOKit/USB — see note below), so ISO, shutter, exposure, white balance, focus, and zoom are applied by a **digital pipeline** in the C core (`camera_pro_adjust_pixels`, `camera_pro_digital_zoom`, `camera_pro_box_blur`). Verified changing the live feed. → `CameraTier.full` |

### Visual aids

| Feature | Status | Notes |
|---|---|---|
| Sobel focus peaking (C core) | ✅ | `camera_pro_compute_focus_peaking` |
| Zebra highlight clipping (C core) | ✅ | `camera_pro_compute_zebra` |
| RGBA histogram (C core) | ✅ | `camera_pro_compute_histogram_rgba` + `_scalar` |
| Luminance waveform monitor (C core) | ✅ | `camera_pro_compute_luma_waveform` → `WaveformData` |
| False-color exposure map (C core) | ✅ | `camera_pro_compute_false_color` |
| GPU compute focus peaking (Metal/Vulkan/D3D11/WebGPU) | 🚧 | Architecture planned; shaders not written |
| Live camera preview (macOS/iOS) | ✅ | AVFoundation frames → FFI → `dart:ui` (no TextureRegistry needed); verified streaming on real hardware |

### Capture

| Feature | Status | Notes |
|---|---|---|
| `capturePhoto()` API surface | ✅ | Method exists, capability-guarded, typed error on failure |
| Actual JPEG capture | 🚧 | Requires platform HAL |
| RAW/DNG capture | 🚧 | API modelled (`ImageFormat.raw`); libtiff/libexif not integrated |
| EXIF embedding | 🚧 | Not started |
| libjpeg-turbo integration | 🚧 | Not integrated |
| Burst / bracket / HDR | ❌ | Not started |

### Video

| Feature | Status | Notes |
|---|---|---|
| Video recording API | ❌ | Not started |
| Live streaming | ❌ | Not started |
| Frame processors | 🚧 | Architecture planned |
| `VideoResolution` / `Bitrate` value types | ✅ | Defined in Dart |
| `VideoCodec` / `StreamProtocol` enums | ✅ | Defined in Dart |

### Robustness

| Feature | Status | Notes |
|---|---|---|
| Sealed typed error hierarchy | ✅ | 9 error subclasses, each with `CameraErrorRecovery` |
| Thermal throttle signalling | ✅ | `ThermalLevel` / `ThermalPolicy` in Dart |
| Device quirks registry | ✅ | `DeviceQuirk` / `quirksFor()` scaffolded |
| Multi-camera support | 🚧 | API designed; not wired |
| Depth / LiDAR | 🚧 | Not started |

---

## Platform support

| Platform | Camera access | C core + stub | Notes |
|---|---|---|---|
| Android | 🚧 | ✅ | NDK Camera2 HAL designed, not wired |
| iOS | ✅ controls + preview | ✅ | AVFoundation HAL: enumeration, capabilities, manual controls, live preview (compiled vs iOS SDK) |
| macOS | ✅ preview + manual | ✅ | Live preview streaming on real cameras; full manual control set (ISO/shutter/exposure/WB/focus/zoom) via the digital pipeline since the built-in camera exposes no sensor controls → `CameraTier.full` |
| Windows | 🚧 | ✅ | Media Foundation HAL designed, not wired |
| Linux | 🚧 | ✅ | V4L2 HAL designed, not wired |
| Web | 🚧 | ✅ (scalar only) | getUserMedia HAL designed; SIMD requires WASM target |

All platforms get the C core and stub backend today. Platform camera access requires the corresponding HAL implementation.

---

## Installation

`camera_pro` is not yet published to pub.dev. Add it as a path or git dependency:

```yaml
# pubspec.yaml

dependencies:
  camera_pro:
    git:
      url: https://github.com/sayed3li97/camera_pro.git
      ref: main   # or pin to a commit SHA for reproducibility
```

**Native assets requirement.** The C core is compiled automatically via Flutter's native-assets feature. This is enabled by default in Flutter 3.22 and later. No manual `.so`/`.dylib` bundling is needed.

Verify your Flutter version supports native assets:

```sh
flutter --version
# Flutter 3.22.0 or later required
```

---

## Quick start

The following snippet works today. You get a stub backend (no real camera frames), but the FFI call into the C core, the capability passport, the state machine, and typed errors are all live:

```dart
import 'package:camera_pro/camera_pro.dart';

Future<void> main() async {
  // nativeCoreVersion is a real FFI call into the compiled C core.
  print(CameraPro.nativeCoreVersion); // "0.1.0"
  print(CameraPro.simdKernel);        // "NEON" on arm64, "scalar" otherwise

  // create() returns a controller backed by the stub HAL until a platform HAL lands.
  final controller = await CameraPro.create();

  print(controller.tier);   // CameraTier.basic on stub

  // Capability passport: check before building UI.
  switch (controller.capabilities.iso) {
    case Supported<int>(:final currentValue, :final minValue, :final maxValue):
      print('ISO $currentValue  [$minValue – $maxValue]');
      // Show ISO slider.
    case NotSupported<int>(:final reason):
      print('ISO not supported: $reason');
      // Disable ISO control.
  }

  // Typed setters — never crash; throw CameraProError subtypes on misuse.
  try {
    await controller.setIso(const Iso(400));
  } on CameraFeatureNotSupportedError catch (e) {
    print('${e.feature}: ${e.message}  recovery: ${e.recovery}');
  } on CameraInvalidParameterError catch (e) {
    print('Bad value: ${e.message}');
  }

  // White balance: preset or Kelvin temperature.
  await controller.setWhiteBalance(WhiteBalance.preset(WhiteBalanceMode.daylight));
  await controller.setWhiteBalance(WhiteBalance.temperature(5500));

  // Listen to state transitions.
  controller.stateChanges.listen((state) => print('Camera state: $state'));

  await controller.dispose();
}
```

---

## Verified this build

The following results were produced on macOS arm64 with Flutter 3.44.1 / Dart 3.12.1:

| Test suite | Result |
|---|---|
| C core (`clang -std=c11 -O2 -Wall -Wextra -Werror`) | **54/54 checks pass** |
| NEON histogram cross-check vs scalar reference | Bit-exact on arm64 |
| Dart unit + FFI tests (`flutter test`) | **63/63 pass** (54 pure-logic, 9 real FFI through compiled core) |
| `flutter analyze` (package) | **No issues** |
| `flutter analyze` (example app) | **No issues** |
| Example app widget test | **Pass** |
| native-assets end-to-end (hook/build.dart → libcamera_pro_core.dylib → FFI) | **Verified** |
| AVFoundation HAL harness on real Mac cameras | **Pass** (enumerated FaceTime HD + external) |
| `AppleCameraBackend` via Dart FFI (`flutter test`, macOS) | **Pass** |
| Apple HAL iOS branch (iPhoneOS SDK compile) | **Compiles** |
| Live camera preview (example app, real Mac camera) | **Streaming** (frames flowing continuously into the Flutter UI) |
| macOS manual controls (all six) applied to the live feed | **Verified** — ISO/exposure/WB visibly transform the feed; example reaches `Tier: Full manual (DSLR)` |
| macOS sensor-control availability (3-layer recon) | **Measured: none** — probed AVFoundation (0 controls), CoreMediaIO (`kCMIOExposureControlClassID` etc. exist but 0 control objects on-device), and IOKit/USB (0 UVC devices). Hence the digital pipeline. |

---

## Documentation

| Document | Contents |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | C core internals, HAL contract, buffer pool design, SIMD strategy |
| [PLATFORM_GUIDE.md](PLATFORM_GUIDE.md) | How to implement a new platform HAL |
| [COOKBOOK.md](COOKBOOK.md) | Recipes: histogram UI, focus peaking overlay, manual exposure |
| [ROADMAP.md](ROADMAP.md) | Prioritised list of 🚧 items and ❌ future work |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Build instructions, test commands, PR guidelines |

---

## License

BSD 3-Clause. See [LICENSE](LICENSE).
