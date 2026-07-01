/// Top-level entrypoint for the camera_pro API.
library;

import 'dart:io' show Platform;

import 'controller/camera_backend.dart';
import 'controller/camera_pro_controller.dart';
import 'ffi/native_core.dart';
import 'models/camera_device.dart';
import 'platform/apple/apple_camera_backend.dart';

/// Picks the native backend for the current platform, falling back to the stub
/// where no HAL is wired yet.
CameraBackend _defaultBackend() {
  if (Platform.isMacOS || Platform.isIOS) return AppleCameraBackend();
  return StubCameraBackend();
}

/// The entrypoint for creating and querying cameras.
///
/// ```dart
/// final controller = await CameraPro.create();
/// // ... use controller.capturePhoto(), controller.setIso(...), etc.
/// await controller.dispose();
/// ```
class CameraPro {
  const CameraPro._();

  /// Version of the bundled native core (e.g. "0.1.0"). Reads the FFI core.
  static String get nativeCoreVersion => NativeCore.versionString;

  /// The active SIMD kernel in the native core ("NEON", "SSE2", ...).
  static String get simdKernel => NativeCore.simdName;

  /// Enumerates the cameras available on this device.
  ///
  /// Pass a [backend] to target a specific platform HAL; defaults to the stub
  /// backend until the native HAL for the current platform is wired.
  static Future<CameraList> availableCameras({CameraBackend? backend}) {
    final b = backend ?? _defaultBackend();
    return b.enumerateDevices();
  }

  /// Creates and initializes a controller for [device] (or the default camera).
  static Future<CameraProController> create({
    CameraBackend? backend,
    CameraDevice? device,
  }) =>
      CameraProController.create(
        backend: backend ?? _defaultBackend(),
        device: device,
      );
}
