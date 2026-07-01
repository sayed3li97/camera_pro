# camera_pro Cookbook

Practical recipes for working with `camera_pro` v0.1.0. This file is split into two clear sections:

- **Works today** — recipes that are fully implemented, tested, and runnable against the current codebase.
- **Roadmap recipes** — intended future API shown for design reference only. Native platform HALs are not yet wired; these snippets will not work until those HALs land.

---

## Project status

`camera_pro` v0.1.0 is a **foundation release**. The shared C core (SIMD histogram, lock-free buffer pool, YUV→RGBA conversion, Sobel focus peaking, zebra), the conformant stub HAL backend, and the full Dart control-plane (capability passport, state machine, typed errors, tier selection, controller) are implemented and verified. Real platform HALs (Android Camera2, Apple AVFoundation, Windows Media Foundation, Linux V4L2, Web) and GPU compute shaders are not yet integrated. Every recipe in this file is labelled accordingly.

---

## Works today

### 1. Reading the native core version and active SIMD kernel

The `NativeCore` class calls directly into `libcamera_pro_core` via FFI. Both calls are real FFI round-trips — verified end-to-end with the native-assets build hook.

```dart
import 'package:camera_pro/camera_pro.dart';

void printCoreInfo() {
  // Static helpers on CameraPro delegate to NativeCore internally.
  print(CameraPro.nativeCoreVersion); // e.g. "0.1.0"
  print(CameraPro.simdKernel);        // e.g. "NEON" on Apple Silicon

  // Or use NativeCore directly for more detail.
  final core = NativeCore();
  print(core.versionString); // "0.1.0"
  print(core.simdName);      // "NEON" | "SSE4.1" | "AVX2" | "SCALAR"
}
```

`CameraPro.simdKernel` returns the kernel that was compiled in and is actually active at runtime. On Apple Silicon arm64 this is NEON, verified bit-exact against the scalar reference in the C test suite.

---

### 2. Creating a controller and querying capabilities

```dart
import 'package:camera_pro/camera_pro.dart';

Future<void> queryCapabilities() async {
  // Until a platform HAL is wired, create() returns a controller backed
  // by StubCameraBackend. Passing a real backend is the same call.
  final controller = await CameraPro.create();

  final caps = controller.capabilities;

  // ISO
  switch (caps.iso) {
    case Supported<int>(:final currentValue, :final minValue, :final maxValue):
      print('ISO $currentValue  [$minValue – $maxValue]');
    case NotSupported<int>(:final reason):
      print('ISO not supported: $reason');
  }

  // Shutter speed
  switch (caps.shutterSpeed) {
    case Supported<ShutterSpeed>(:final currentValue, :final minValue, :final maxValue):
      print('Shutter: $currentValue  [$minValue – $maxValue]');
    case NotSupported<ShutterSpeed>(:final reason):
      print('Shutter not supported: $reason');
  }

  // Boolean flags
  print('Has flash:      ${caps.hasFlash}');
  print('Supports RAW:   ${caps.supportsRawCapture}');
  print('Supports HDR:   ${caps.supportsHdr}');

  await controller.dispose();
}
```

`Capability<T>` is a sealed class. The compiler enforces exhaustive matching — you cannot accidentally reach an unhandled case.

---

### 3. Enumerating available cameras

```dart
import 'package:camera_pro/camera_pro.dart';

Future<void> listCameras() async {
  final cameras = await CameraPro.availableCameras();
  for (final device in cameras) {
    print('${device.id}  ${device.position}  ${device.name}');
  }

  // To target a specific device:
  final controller = await CameraPro.create(device: cameras.first);
  await controller.dispose();
}
```

---

### 4. Capability-guarded control with typed error handling

Every setter on `CameraProController` checks the capability passport before calling into native. If the capability is absent the controller throws `CameraFeatureNotSupportedError` — never a null-deref or a cryptic platform exception.

```dart
import 'package:camera_pro/camera_pro.dart';

Future<void> adjustExposure(CameraProController controller) async {
  // ISO
  try {
    await controller.setIso(const Iso(400));
  } on CameraFeatureNotSupportedError catch (e) {
    // e.recovery gives a CameraErrorRecovery hint (e.g. .disableFeature)
    print('ISO not available: ${e.message}  recovery: ${e.recovery}');
  } on CameraInvalidParameterError catch (e) {
    print('Value out of range: ${e.message}');
  }

  // Shutter speed
  try {
    await controller.setShutterSpeed(ShutterSpeed.fromFraction(1, 250));
  } on CameraFeatureNotSupportedError catch (e) {
    print('Manual shutter not available: ${e.message}');
  }

  // Exposure compensation (works on more devices than manual shutter)
  try {
    await controller.setExposureCompensation(const Ev(1.0));
  } on CameraProError catch (e) {
    print('EV adjustment failed: ${e.message}  [${e.recovery}]');
  }

  // White balance
  try {
    await controller.setWhiteBalance(WhiteBalance.preset(WhiteBalanceMode.daylight));
    // Or by Kelvin temperature:
    await controller.setWhiteBalance(WhiteBalance.temperature(5500));
  } on CameraFeatureNotSupportedError catch (e) {
    print('WB control not available: ${e.message}');
  }
}
```

The full sealed error hierarchy:

| Class | Typical cause |
|---|---|
| `CameraPermissionError` | OS permission denied |
| `CameraDeviceError` | Hardware fault / not present |
| `CameraInUseError` | Another process holds the camera |
| `CameraSessionInterruptedError` | Phone call, screen lock |
| `CameraThermalThrottleError` | Device too hot |
| `CameraFeatureNotSupportedError` | Capability absent on this device |
| `CameraCaptureError` | Capture pipeline failure |
| `CameraServiceFatalError` | Unrecoverable HAL crash |
| `CameraInvalidParameterError` | Value outside capability range |

---

### 5. Choosing UI by CameraTier

`determineTier(caps)` maps a `CameraCapabilities` instance to one of three tiers. Use it to progressively disclose controls.

```dart
import 'package:camera_pro/camera_pro.dart';

Widget buildControls(CameraProController controller) {
  return switch (controller.tier) {
    CameraTier.full => const FullProControlPanel(),     // ISO, shutter, aperture, WB, focus
    CameraTier.standard => const StandardControlPanel(), // ISO, EV, WB presets
    CameraTier.basic => const BasicControlPanel(),       // EV only
  };
}
```

`CameraTier.full` requires manual ISO, shutter speed, aperture, white-balance Kelvin, and focus distance all reported as `Supported`. The stub backend returns `CameraTier.basic`.

---

### 6. Computing a histogram over an RGBA buffer

`NativeCore.histogramFromRgba` calls `camera_pro_compute_histogram_rgba` in the C core, which dispatches to the active SIMD kernel (NEON on arm64, SSE4.1/AVX2 on x86-64, scalar fallback everywhere else).

```dart
import 'dart:typed_data';
import 'package:camera_pro/camera_pro.dart';

HistogramData computeHistogram(Uint8List rgbaPixels, int width, int height) {
  final core = NativeCore();
  // rgbaPixels must be exactly width * height * 4 bytes.
  final histogram = core.histogramFromRgba(
    rgbaPixels,
    width: width,
    height: height,
  );

  // histogram.r / .g / .b / .luminance are each Uint32List(256).
  final peakBin = histogram.luminance
      .indexed
      .reduce((a, b) => a.$2 >= b.$2 ? a : b)
      .$1;
  print('Luminance peak at bin $peakBin');

  return histogram;
}
```

The scalar reference path is also accessible if you need reproducible cross-platform output independent of SIMD:

```dart
// camera_pro_compute_histogram_rgba_scalar — always scalar, useful in tests.
final scalarHistogram = core.histogramFromRgbaScalar(rgbaPixels, width: width, height: height);
```

---

### 7. Using NativeBufferPool

The lock-free buffer pool (`camera_pro_buffer_pool_*` in the C core) avoids per-frame allocation. Dart access is through `NativeBufferPool`.

```dart
import 'package:camera_pro/camera_pro.dart';

Future<void> processFrames() async {
  // Create a pool of 4 buffers, each 3 MB (e.g. 1080p RGBA).
  final pool = NativeBufferPool.create(capacity: 4, bufferSize: 3 * 1024 * 1024);

  print('Pool capacity:  ${pool.capacity}');   // 4
  print('Buffers available: ${pool.available}'); // 4

  // Acquire a buffer, use it, then release it back.
  final buf = pool.acquire();
  if (buf != null) {
    // buf is a NativeBuffer wrapping a pointer into native memory.
    // Write frame data, hand to C processing functions, then release.
    pool.release(buf);
  }

  pool.destroy();
}
```

`pool.acquire()` returns `null` when all buffers are in use rather than blocking or throwing — the caller decides the back-pressure strategy.

---

### 8. Observing the controller state machine

```dart
import 'package:camera_pro/camera_pro.dart';

Future<void> observeState() async {
  final controller = await CameraPro.create();

  print('Initial state: ${controller.state}'); // CameraState.ready (stub)

  controller.stateChanges.listen((state) {
    switch (state) {
      case CameraState.ready:
        print('Camera ready');
      case CameraState.capturing:
        print('Capture in progress');
      case CameraState.error:
        print('Camera entered error state');
      // handle other states...
      default:
        print('State: $state');
    }
  });

  await controller.dispose();
}
```

---

### 9. Thermal policy

`ThermalPolicy` lets you react to `ThermalLevel` changes (e.g. drop frame rate or disable RAW before the OS forces a shutdown).

```dart
import 'package:camera_pro/camera_pro.dart';

void configureThermalPolicy(CameraProController controller) {
  final policy = ThermalPolicy(
    onNominal:  () => print('Nominal — full quality'),
    onFair:     () => print('Fair — consider reducing resolution'),
    onSerious:  () => print('Serious — drop to 1080p'),
    onCritical: () => print('Critical — suspend preview'),
  );

  // Wire the policy to your thermal monitoring source.
  // ThermalLevel values: nominal, fair, serious, critical.
}
```

---

### 10. Device quirks lookup

`quirksFor(device)` returns a set of `DeviceQuirk` flags for known-problematic hardware combinations so the UI can work around them without trial-and-error at runtime.

```dart
import 'package:camera_pro/camera_pro.dart';

Future<void> applyQuirks() async {
  final cameras = await CameraPro.availableCameras();
  for (final device in cameras) {
    final quirks = quirksFor(device);
    if (quirks.contains(DeviceQuirk.noManualFocus)) {
      print('${device.name}: manual focus unavailable — hiding slider');
    }
    if (quirks.contains(DeviceQuirk.unreliableIso)) {
      print('${device.name}: ISO values may be approximate');
    }
  }
}
```

---

### 11. Unit-testing a controller with a fake CameraBackend

`CameraProController.forTesting` accepts a `CameraBackend` you supply, so tests never touch a real camera or the platform channel.

```dart
import 'package:camera_pro/camera_pro.dart';
import 'package:test/test.dart';

class FakeBackend implements CameraBackend {
  @override
  Future<CameraCapabilities> queryCapabilities(CameraDevice device) async {
    return CameraCapabilities(
      iso: Supported<int>(
        currentValue: 100,
        minValue: 50,
        maxValue: 3200,
      ),
      shutterSpeed: NotSupported<ShutterSpeed>(reason: 'test stub'),
      aperture: NotSupported<double>(reason: 'test stub'),
      whiteBalanceKelvin: NotSupported<int>(reason: 'test stub'),
      focusDistance: NotSupported<double>(reason: 'test stub'),
      exposureCompensation: Supported<double>(
        currentValue: 0.0,
        minValue: -3.0,
        maxValue: 3.0,
        stepSize: 0.3,
      ),
      zoom: Supported<double>(currentValue: 1.0, minValue: 1.0, maxValue: 4.0),
      supportsRawCapture: false,
      supportsHdr: false,
      hasFlash: false,
    );
  }

  // Implement remaining CameraBackend members as no-ops or throws as needed.
}

void main() {
  test('tier is standard when ISO and EV are supported but shutter is not', () async {
    final caps = await FakeBackend().queryCapabilities(CameraDevice.unknown());
    expect(determineTier(caps), CameraTier.standard);
  });

  test('setIso succeeds within range', () async {
    final controller = CameraProController.forTesting(
      capabilities: await FakeBackend().queryCapabilities(CameraDevice.unknown()),
      backend: FakeBackend(),
    );
    await expectLater(controller.setIso(const Iso(200)), completes);
    await controller.dispose();
  });

  test('setIso throws CameraFeatureNotSupportedError for unsupported capability', () async {
    final noIsoCaps = CameraCapabilities.unsupported();
    final controller = CameraProController.forTesting(
      capabilities: noIsoCaps,
      backend: FakeBackend(),
    );
    expect(
      () => controller.setIso(const Iso(200)),
      throwsA(isA<CameraFeatureNotSupportedError>()),
    );
    await controller.dispose();
  });
}
```

`CameraCapabilities.unsupported()` is the factory that marks every capability as `NotSupported`, useful for testing graceful degradation paths.

---

## Roadmap recipes

The snippets below show the **intended** public API design for features that are not yet implemented. Native platform HALs must be wired before any of these work. Each is marked 🚧.

---

### RAW / DNG capture workflow 🚧

> **Status:** 🚧 The `ImageFormat.raw` enum value and `capturePhoto` call exist in Dart. libtiff and libexif are **not** integrated; no platform HAL returns actual sensor data yet.

```dart
// ROADMAP — does not work today
Future<void> captureRaw(CameraProController controller) async {
  if (!controller.capabilities.supportsRawCapture) {
    throw CameraFeatureNotSupportedError('RAW not available on this device');
  }

  final photo = await controller.capturePhoto(format: ImageFormat.raw);
  // photo.dngBytes will contain a DNG-wrapped RAW buffer with EXIF metadata.
  await File('capture.dng').writeAsBytes(photo.dngBytes!);
}
```

---

### ProRes / log video recording 🚧

> **Status:** 🚧 `VideoCodec`, `ColorProfile`, `Stabilization`, `Bitrate`, and `VideoResolution` value types exist. The record pipeline is not connected to any platform HAL.

```dart
// ROADMAP — does not work today
Future<void> recordProRes(CameraProController controller) async {
  await controller.startRecording(
    resolution: VideoResolution.uhd4k,
    codec: VideoCodec.proRes422HQ,
    colorProfile: ColorProfile.logC,
    stabilization: Stabilization.optical,
    bitrate: Bitrate.mbps(800),
  );

  await Future<void>.delayed(const Duration(seconds: 10));
  final file = await controller.stopRecording();
  print('Saved: ${file.path}');
}
```

---

### RTMP / SRT live streaming 🚧

> **Status:** 🚧 `StreamProtocol` enum exists. No streaming pipeline is implemented.

```dart
// ROADMAP — does not work today
Future<void> goLive(CameraProController controller) async {
  await controller.startStreaming(
    protocol: StreamProtocol.rtmp,
    endpoint: Uri.parse('rtmp://live.example.com/stream/key'),
    videoBitrate: Bitrate.mbps(5),
  );
}
```

---

### Portrait mode / depth data 🚧

> **Status:** 🚧 Not started. Requires LiDAR / dual-camera HAL integration.

```dart
// ROADMAP — does not work today
Future<void> capturePortrait(CameraProController controller) async {
  final photo = await controller.capturePhoto(
    format: ImageFormat.heif,
    portraitMode: true,
    depthData: true,
  );
  // photo.depthMap — Float32List in metres, same dimensions as photo.
}
```

---

### On-device ML frame processor 🚧

> **Status:** 🚧 Not started. Requires Flutter texture registration and a frame-dispatch mechanism.

```dart
// ROADMAP — does not work today
void attachFrameProcessor(CameraProController controller) {
  controller.setFrameProcessor((CameraFrame frame) {
    // frame.rgbaBytes, frame.width, frame.height, frame.timestampUs
    // Run Core ML / TFLite inference here.
  });
}
```

---

### Multi-camera picture-in-picture 🚧

> **Status:** 🚧 Not started. Requires multi-stream HAL support and simultaneous texture registration.

```dart
// ROADMAP — does not work today
Future<void> multiCamPiP() async {
  final cameras = await CameraPro.availableCameras();
  final wide  = await CameraPro.create(device: cameras.firstWhere((c) => c.isWideAngle));
  final tele  = await CameraPro.create(device: cameras.firstWhere((c) => c.isTelephoto));

  // Both textureIds are valid simultaneously — compose in your widget tree.
  print('Wide texture: ${wide.textureId}   Tele texture: ${tele.textureId}');
}
```

---

### Focus stacking 🚧

> **Status:** 🚧 Not started. Requires burst capture and manual focus stepping, both unimplemented on the native side.

```dart
// ROADMAP — does not work today
Future<void> focusStack(CameraProController controller) async {
  const steps = 8;
  final focusRange = switch (controller.capabilities.focusDistance) {
    Supported<double>(:final minValue, :final maxValue) => (minValue, maxValue),
    NotSupported() => throw CameraFeatureNotSupportedError('No manual focus'),
  };

  final frames = <CapturedPhoto>[];
  for (var i = 0; i < steps; i++) {
    final d = focusRange.$1 + (focusRange.$2 - focusRange.$1) * i / (steps - 1);
    await controller.setFocusDistance(d);
    frames.add(await controller.capturePhoto());
  }
  // Pass frames to an image-fusion library.
}
```

---

## Value-type quick reference

| Type | Construction examples |
|---|---|
| `Iso` | `Iso(100)`, `Iso(3200)` |
| `Ev` | `Ev(0.0)`, `Ev(-1.5)`, `Ev(2.0)` |
| `ShutterSpeed` | `ShutterSpeed.fromFraction(1, 250)`, `ShutterSpeed.seconds(4.0)` |
| `WhiteBalance` | `WhiteBalance.preset(WhiteBalanceMode.daylight)`, `WhiteBalance.temperature(5500)` |
| `Bitrate` | `Bitrate.mbps(50)` |
| `VideoResolution` | `VideoResolution.uhd4k`, `VideoResolution.fhd1080p` |

---

## Running the test suite

```bash
# C core — 36/36 checks (NEON active on arm64)
clang -std=c11 -O2 -Wall -Wextra -Werror \
  src/core/buffer_pool.c src/core/image_processor.c \
  src/core/format_converter.c src/core/camera_pro_core.c \
  src/platform/stub/camera_hal_stub.c \
  src/tests/core_test.c -o core_test && ./core_test

# Dart — 59 tests (54 logic + 5 real FFI through compiled core)
flutter test

# Example app — analyze + widget test
cd example && flutter analyze && flutter test
```

All three suites pass on Flutter 3.44.1 / Dart 3.12.1 / macOS arm64. The native-assets hook (`hook/build.dart`) compiles `libcamera_pro_core.dylib` automatically during `flutter test` and `flutter run`.
