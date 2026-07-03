/// Default backend for native (dart:io) targets.
library;

import 'dart:io' show Platform;

import '../controller/camera_backend.dart';
import 'apple/apple_camera_backend.dart';

/// Apple backend on macOS/iOS; conformant stub elsewhere (until a native HAL
/// is wired for that platform).
CameraBackend defaultCameraBackend() {
  if (Platform.isMacOS || Platform.isIOS) return AppleCameraBackend();
  return StubCameraBackend();
}
