/// The backend abstraction the controller drives.
///
/// This is the Dart-side mirror of `camera_hal.h`. A real backend forwards to
/// the native HAL over FFI; [StubCameraBackend] is the conformant no-op used
/// when no native session is wired (and by unit tests). Keeping the controller
/// backend-agnostic is what makes its capability-guard logic testable without a
/// device.
library;

import '../models/camera_device.dart';
import '../models/capabilities.dart';
import '../models/capture_result.dart';
import '../models/settings.dart';

/// Contract every platform backend implements.
abstract interface class CameraBackend {
  /// Enumerates available cameras.
  Future<CameraList> enumerateDevices();

  /// Opens [device] (or the default) and returns a Flutter texture id, or null
  /// if this backend renders without a texture.
  Future<int?> open(CameraDevice device);

  /// Reads the capability passport for the open device.
  Future<CameraCapabilities> getCapabilities();

  /// Starts the preview stream.
  Future<void> startPreview();

  /// Stops the preview stream.
  Future<void> stopPreview();

  // ── Manual controls (throw CameraProError on failure) ──
  Future<void> setExposureMode(ExposureMode mode);
  Future<void> setShutterSpeed(ShutterSpeed value);
  Future<void> setIso(Iso iso);
  Future<void> setExposureCompensation(Ev ev);
  Future<void> setFocusMode(FocusMode mode);
  Future<void> setFocusDistance(double diopters);
  Future<void> setWhiteBalance(WhiteBalance wb);
  Future<void> setZoom(double factor);
  Future<void> setFlashMode(FlashMode mode);
  Future<void> setTorch({required bool enabled, double intensity});

  // ── Capture ──
  Future<CapturedPhoto> capturePhoto({ImageFormat? format});
  Future<void> startVideoRecording(String path);
  Future<VideoResult> stopVideoRecording();

  /// Releases native resources.
  Future<void> close();
}

/// A backend that reports no camera and refuses every control. Used when the
/// native HAL for the current platform is not yet wired, so the SDK degrades to
/// [CameraTier.basic] instead of crashing.
class StubCameraBackend implements CameraBackend {
  @override
  Future<CameraList> enumerateDevices() async => const CameraList(<CameraDevice>[]);

  @override
  Future<int?> open(CameraDevice device) async => null;

  @override
  Future<CameraCapabilities> getCapabilities() async =>
      CameraCapabilities.unsupported(
        platformName: 'stub',
        deviceName: 'No camera (stub backend)',
        reason: 'Native backend not wired for this platform',
      );

  @override
  Future<void> startPreview() async {}

  @override
  Future<void> stopPreview() async {}

  Never _unsupported(String feature) => throw StateError('$feature: stub backend');

  @override
  Future<void> setExposureMode(ExposureMode mode) async => _unsupported('exposureMode');

  @override
  Future<void> setShutterSpeed(ShutterSpeed value) async => _unsupported('shutterSpeed');

  @override
  Future<void> setIso(Iso iso) async => _unsupported('iso');

  @override
  Future<void> setExposureCompensation(Ev ev) async => _unsupported('ev');

  @override
  Future<void> setFocusMode(FocusMode mode) async => _unsupported('focusMode');

  @override
  Future<void> setFocusDistance(double diopters) async => _unsupported('focusDistance');

  @override
  Future<void> setWhiteBalance(WhiteBalance wb) async => _unsupported('whiteBalance');

  @override
  Future<void> setZoom(double factor) async => _unsupported('zoom');

  @override
  Future<void> setFlashMode(FlashMode mode) async => _unsupported('flash');

  @override
  Future<void> setTorch({required bool enabled, double intensity = 1.0}) async =>
      _unsupported('torch');

  @override
  Future<CapturedPhoto> capturePhoto({ImageFormat? format}) async =>
      _unsupported('capturePhoto');

  @override
  Future<void> startVideoRecording(String path) async => _unsupported('recording');

  @override
  Future<VideoResult> stopVideoRecording() async => _unsupported('recording');

  @override
  Future<void> close() async {}
}
