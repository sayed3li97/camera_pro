# Migration Guide: `camera` and `camerawesome` → `camera_pro`

> **Project status (v0.1.0):** This is an early foundation release. The shared C core, Dart control-plane, capability passport, typed errors, and stub HAL are implemented and verified. Real platform HAL backends (Android NDK Camera2, Apple AVFoundation, Windows Media Foundation, Linux V4L2, Web) are **🚧 roadmap** and not yet wired. This guide describes the **target API shape** so you can structure your migration now and drop in a live backend when it ships.

---

## Table of contents

1. [Why migrate?](#why-migrate)
2. [Concept mapping](#concept-mapping)
3. [Common call mapping](#common-call-mapping)
   - [List cameras](#1-list-cameras)
   - [Initialize / create a controller](#2-initialize--create-a-controller)
   - [Take a photo](#3-take-a-photo)
   - [Dispose](#4-dispose)
   - [ISO, shutter speed, exposure compensation](#5-iso-shutter-speed-exposure-compensation)
   - [White balance](#6-white-balance)
   - [Flash](#7-flash)
   - [Zoom](#8-zoom)
   - [Focus](#9-focus)
4. [Capability passport instead of feature assumptions](#capability-passport-instead-of-feature-assumptions)
5. [Typed errors instead of raw exceptions](#typed-errors-instead-of-raw-exceptions)
6. [CameraTier-driven UI](#cameratier-driven-ui)
7. [State machine](#state-machine)
8. [Not yet available](#not-yet-available)

---

## Why migrate?

| Pain point in `camera` / `camerawesome` | How `camera_pro` addresses it |
|---|---|
| Features gated on platform with no introspection API; you discover mismatches at runtime | **Capability passport** — every feature is either `Supported<T>` (with current value, min, max, optional step) or `NotSupported<T>` (with a reason string) before you draw any UI |
| Opaque exceptions or silent no-ops on unsupported hardware | **Typed sealed errors** with a `CameraErrorRecovery` hint on every subclass |
| UI code must hard-code logic per-platform | **CameraTier** (`full` / `standard` / `basic`) lets you render one of three UI templates driven entirely by the capability passport |
| Benchmark-quality C hot paths require a separate plugin or Dart reimplementation | Shared C core (SIMD histogram, lock-free buffer pool, YUV→RGBA, Sobel focus peaking, zebra) ships inside the package and compiles automatically via the native-assets hook |

---

## Concept mapping

| `camera` concept | `camerawesome` concept | `camera_pro` equivalent |
|---|---|---|
| `CameraDescription` | `CameraDevice` | `CameraDevice` |
| `CameraController` | `CamerawesomeBuilder` / state | `CameraProController` |
| `ResolutionPreset` | `SensorConfig` | `VideoResolution` + capability passport |
| `FlashMode` enum | `FlashMode` | `FlashMode` enum (same names) |
| `ImageFormatGroup` | `CaptureMode` | `ImageFormat` enum |
| Untyped `CameraException` | `CameraError` | Sealed `CameraProError` hierarchy |
| No tier concept | No tier concept | `CameraTier { full, standard, basic }` |

---

## Common call mapping

### 1. List cameras

**`camera`**

```dart
final cameras = await availableCameras();
```

**`camerawesome`**

```dart
// discovered implicitly during builder initialization
```

**`camera_pro`**

```dart
import 'package:camera_pro/camera_pro.dart';

final cameras = await CameraPro.availableCameras();
// Optionally scope to a specific backend:
// final cameras = await CameraPro.availableCameras(backend: myBackend);
```

---

### 2. Initialize / create a controller

**`camera`**

```dart
final controller = CameraController(
  cameras.first,
  ResolutionPreset.high,
  imageFormatGroup: ImageFormatGroup.yuv420,
);
await controller.initialize();
```

**`camerawesome`**

```dart
CamerawesomeBuilder.awesome(
  saveConfig: SaveConfig.photo(),
  onImageForAnalysis: (img) async { /* ... */ },
).build()
```

**`camera_pro`**

```dart
// Uses stub backend until a platform HAL is wired (see "Not yet available").
final controller = await CameraPro.create();

// Or target a specific device:
final cameras = await CameraPro.availableCameras();
final controller = await CameraPro.create(device: cameras.first);
```

`CameraPro.create` returns a fully initialised `CameraProController`. No separate `initialize()` call is needed.

---

### 3. Take a photo

**`camera`**

```dart
final XFile file = await controller.takePicture();
```

**`camerawesome`**

```dart
await _captureState.when(photo: (photo) => photo.takePhoto());
```

**`camera_pro`**

```dart
// Capture with default format (determined by capability passport):
final result = await controller.capturePhoto();

// Capture with an explicit format:
final result = await controller.capturePhoto(format: ImageFormat.jpeg);
```

`capturePhoto` throws a typed `CameraCaptureError` (never an untyped `Exception`) if the capture fails.

---

### 4. Dispose

**`camera`**

```dart
await controller.dispose();
```

**`camerawesome`**

Managed by the widget lifecycle.

**`camera_pro`**

```dart
await controller.dispose();
```

Identical call. After dispose the controller transitions to `CameraState.disposed` and any further calls throw `CameraDeviceError`.

---

### 5. ISO, shutter speed, exposure compensation

**`camera`**

```dart
// No first-class ISO API; exposure offset only:
await controller.setExposureOffset(1.5);
```

**`camerawesome`**

```dart
sensorConfig.iso.add(800);
sensorConfig.speed.add(1 / 250);
```

**`camera_pro`**

```dart
// Always check the capability before calling the setter.
switch (controller.capabilities.iso) {
  case Supported<int>(:final minValue, :final maxValue, :final stepSize):
    // Safe to call — build a slider from minValue/maxValue/stepSize.
    await controller.setIso(const Iso(400));
  case NotSupported<int>(:final reason):
    // Disable the ISO control; show reason to the user.
}

switch (controller.capabilities.shutterSpeed) {
  case Supported<ShutterSpeed>(:final minValue, :final maxValue):
    await controller.setShutterSpeed(ShutterSpeed.fromFraction(1, 250));
  case NotSupported<ShutterSpeed>():
    // Disable shutter speed control.
}

switch (controller.capabilities.exposureCompensation) {
  case Supported<Ev>(:final minValue, :final maxValue):
    await controller.setExposureCompensation(const Ev(1.5));
  case NotSupported<Ev>():
    // Disable EV control.
}
```

---

### 6. White balance

**`camera`**

```dart
await controller.setFlashMode(FlashMode.off); // no WB API
```

**`camerawesome`**

```dart
sensorConfig.whiteBalance.add(AwbMode.daylight);
```

**`camera_pro`**

```dart
// Preset mode:
await controller.setWhiteBalance(WhiteBalance.preset(WhiteBalanceMode.daylight));

// Kelvin value (check capability first):
switch (controller.capabilities.whiteBalanceKelvin) {
  case Supported<int>(:final minValue, :final maxValue):
    await controller.setWhiteBalance(WhiteBalance.temperature(5600));
  case NotSupported<int>():
    // Kelvin slider not available on this device.
}
```

---

### 7. Flash

**`camera`**

```dart
await controller.setFlashMode(FlashMode.torch);
```

**`camerawesome`**

```dart
sensorConfig.flashMode.add(CameraFlashMode.on);
```

**`camera_pro`**

```dart
// Guard on the capability flag first:
if (controller.capabilities.hasFlash) {
  await controller.setFlashMode(FlashMode.torch);
}
```

---

### 8. Zoom

**`camera`**

```dart
await controller.setZoomLevel(2.0);
```

**`camerawesome`**

```dart
sensorConfig.zoom.add(2.0);
```

**`camera_pro`**

```dart
switch (controller.capabilities.zoom) {
  case Supported<double>(:final minValue, :final maxValue):
    await controller.setZoom(2.0.clamp(minValue, maxValue));
  case NotSupported<double>():
    // No zoom on this device.
}
```

---

### 9. Focus

**`camera`**

```dart
await controller.setFocusPoint(Offset(0.5, 0.5));
```

**`camerawesome`**

```dart
sensorConfig.focusPoint.add(point);
```

**`camera_pro`**

```dart
switch (controller.capabilities.focusDistance) {
  case Supported<double>(:final minValue, :final maxValue):
    // Normalised 0.0 (near) – 1.0 (infinity).
    await controller.setFocusDistance(0.5);
  case NotSupported<double>(:final reason):
    // Fixed-focus or autofocus-only; reason explains the constraint.
}
```

---

## Capability passport instead of feature assumptions

The central design difference is that `camera_pro` makes every hardware capability **explicit and queryable** before you build any UI, rather than requiring you to catch runtime exceptions or hard-code platform conditionals.

```dart
final caps = controller.capabilities;

// Every capability is a sealed Capability<T>:
// - Supported<T>(currentValue, minValue, maxValue, stepSize?)
// - NotSupported<T>(reason)

Widget buildIsoControl() {
  return switch (caps.iso) {
    Supported<int>(:final currentValue, :final minValue, :final maxValue,
                   :final stepSize) =>
      Slider(
        value: currentValue.toDouble(),
        min: minValue.toDouble(),
        max: maxValue.toDouble(),
        divisions: stepSize != null
            ? ((maxValue - minValue) / stepSize).round()
            : null,
        onChanged: (v) => controller.setIso(Iso(v.round())),
      ),
    NotSupported<int>(:final reason) =>
      Tooltip(message: reason, child: const Icon(Icons.lock_outline)),
  };
}

// Boolean flags:
if (caps.supportsRawCapture)   showRawToggle();
if (caps.supportsHdr)          showHdrToggle();
if (caps.hasFlash)             showFlashControl();
if (caps.hasTorch)             showTorchControl();
if (caps.supportsMultiCamera)  showLensSwitcher();
if (caps.supportsDepthCapture) showDepthToggle();
```

This replaces patterns like:

```dart
// camera — error-prone, platform-specific, no min/max info:
try {
  await controller.setExposureOffset(ev);
} catch (_) {
  // silently swallowed
}
```

---

## Typed errors instead of raw exceptions

Every failure in `camera_pro` is a subclass of the **sealed** `CameraProError`. Each subclass carries a `CameraErrorRecovery` hint.

```dart
// camera — catch-all with string parsing:
try {
  await controller.takePicture();
} on CameraException catch (e) {
  if (e.code == 'CameraAccessDenied') { /* ... */ }
}

// camerawesome — varies by state:
// errors surfaced through stream callbacks

// camera_pro — exhaustive sealed switch:
try {
  await controller.capturePhoto();
} on CameraPermissionError catch (e) {
  // e.recovery == CameraErrorRecovery.requestPermission
  openAppSettings();
} on CameraInUseError catch (e) {
  // e.recovery == CameraErrorRecovery.retry
  scheduleRetry();
} on CameraFeatureNotSupportedError catch (e) {
  // e.recovery == CameraErrorRecovery.fatal
  showUnsupportedMessage(e.message);
} on CameraCaptureError catch (e) {
  // e.recovery == CameraErrorRecovery.retry
  showRetryDialog();
} on CameraProError catch (e) {
  // Catch-all for any other typed camera error.
  log(e.toString());
}
```

Full error hierarchy:

| Class | Typical cause | Recovery hint |
|---|---|---|
| `CameraPermissionError` | Camera permission denied | `requestPermission` |
| `CameraDeviceError` | Hardware fault or bad device id | `none` |
| `CameraInUseError` | Device locked by another process | `waitAndRetry` |
| `CameraSessionInterruptedError` | Phone call, backgrounding | `restart` |
| `CameraThermalThrottleError` | Device too hot | `coolDown` |
| `CameraFeatureNotSupportedError` | Feature absent on this device | `none` |
| `CameraCaptureError` | Capture pipeline failure | `retry` |
| `CameraServiceFatalError` | Unrecoverable HAL crash | `restart` |
| `CameraInvalidParameterError` | Value out of capability range | `fixParameter` |

---

## CameraTier-driven UI

`camera_pro` provides a `CameraTier` enum (`full`, `standard`, `basic`) derived automatically from the capability passport. This lets you maintain three UI templates rather than infinite per-device conditionals.

```dart
// camera / camerawesome — no tier concept:
// you manually check each feature and accumulate booleans

// camera_pro:
final tier = controller.tier; // determineTier(controller.capabilities)

Widget buildCameraUI() => switch (tier) {
  CameraTier.full     => const FullProCameraUI(),    // RAW, manual ETTR, histogram overlay
  CameraTier.standard => const StandardCameraUI(),   // JPEG, limited manual, auto-WB
  CameraTier.basic    => const BasicCameraUI(),       // point-and-shoot only
};
```

`determineTier` is a pure function you can also call directly with any `CameraCapabilities` value, making it easy to unit-test UI branching without hardware.

---

## State machine

`CameraProController` exposes `state` (a `CameraState`) and `stateChanges` (a `Stream<CameraState>`). This replaces ad-hoc `isInitialized` flags:

```dart
// camera:
if (controller.value.isInitialized) { /* ... */ }

// camera_pro:
StreamBuilder<CameraState>(
  stream: controller.stateChanges,
  builder: (context, snap) => switch (snap.data ?? controller.state) {
    CameraState.idle        => const CircularProgressIndicator(),
    CameraState.previewing  => CameraPreview(controller),
    CameraState.capturing   => const CapturingOverlay(),
    CameraState.disposed    => const SizedBox.shrink(),
    CameraState.error       => const ErrorView(),
    _                       => const SizedBox.shrink(),
  },
);
```

---

## Not yet available

> **Important:** Real platform HAL backends are **🚧 roadmap** and are not implemented in v0.1.0. Until they land, `CameraPro.create()` returns a controller backed by the **stub HAL**, which:
>
> - Returns `CameraCapabilities.unsupported()` for all features.
> - Reports `CameraTier.basic`.
> - Does not open a real camera or display a preview.
> - Does not write captured images to disk.
>
> This means the migration guide above describes the **target API shape**. You can write and test your UI logic (capability guards, error handling, tier switching) against the stub today. When an Android or iOS HAL ships you will drop in the backend and your control-plane code will work without changes.

| Feature | Status |
|---|---|
| Android NDK Camera2 HAL | 🚧 roadmap |
| Apple AVFoundation HAL | 🚧 roadmap |
| Windows Media Foundation HAL | 🚧 roadmap |
| Linux V4L2 HAL | 🚧 roadmap |
| Web (MediaDevices) HAL | 🚧 roadmap |
| Flutter texture registration / live preview | 🚧 roadmap |
| Video recording | 🚧 roadmap |
| Live streaming (RTMP/HLS/SRT) | 🚧 roadmap |
| RAW/DNG + EXIF (libtiff/libexif) | 🚧 roadmap |
| GPU compute shaders (Metal/Vulkan/D3D11/WebGPU) | 🚧 roadmap |
| libyuv / libjpeg-turbo integration | 🚧 roadmap |
| Multi-camera / depth / LiDAR | 🚧 roadmap |
| Burst / bracket / HDR | 🚧 roadmap |
| Frame processors | 🚧 roadmap |

**Already implemented and verified** in v0.1.0:

- Shared C core: SIMD histogram (NEON, 36/36 C tests pass), lock-free buffer pool, scalar YUV→RGBA format conversion, Sobel focus peaking, zebra.
- Conformant stub HAL (`StubCameraBackend` / `camera_hal_stub.c`).
- Dart control-plane: capability passport, state machine, typed errors, tier selection, `CameraProController` with capability-guarded setters.
- Native-assets FFI build wiring (`hook/build.dart`).
- 59 Dart tests pass (54 pure-logic + 5 real FFI-through-compiled-core); `flutter analyze` reports no issues.
