/// Typed error hierarchy for camera_pro.
///
/// Every failure surfaces as a [CameraProError] subclass carrying a
/// machine-readable [CameraErrorRecovery] so callers can react without string
/// matching. The hierarchy is `sealed`, so a `switch` over it is exhaustive.
library;

import 'package:meta/meta.dart';

import '../platform/thermal.dart';

/// How a caller can recover from a [CameraProError].
enum CameraErrorRecovery {
  /// The SDK is retrying/recovering automatically; no caller action needed.
  automatic,

  /// The caller should retry the failed operation.
  retry,

  /// Dispose the controller and create a fresh one.
  reinitialize,

  /// The user must grant camera permission in system settings.
  requestPermission,

  /// The user must take an action (e.g. close another camera app).
  userAction,

  /// A device restart may be required.
  deviceRestart,

  /// Unrecoverable; the feature is unavailable on this device.
  fatal,
}

/// Why an active session was interrupted.
enum CameraInterruptionReason {
  phoneCall('Incoming phone call'),
  backgrounded('App moved to background'),
  otherApp('Another app opened the camera'),
  thermalPressure('Device overheating'),
  splitScreen('Multi-window mode'),
  systemDialog('System dialog overlay');

  const CameraInterruptionReason(this.description);

  /// Human-readable description.
  final String description;
}

/// Why a capture failed.
enum CaptureFailureReason {
  timeout('Capture timed out'),
  storageFull('Insufficient storage'),
  focusFailed('Unable to achieve focus'),
  interrupted('Interrupted before completion'),
  encodingFailed('Image/video encoding failed'),
  unknown('Unknown capture failure');

  const CaptureFailureReason(this.description);

  /// Human-readable description.
  final String description;
}

/// Base class for all camera_pro errors. Sealed for exhaustive matching.
@immutable
sealed class CameraProError implements Exception {
  const CameraProError({
    required this.message,
    required this.recovery,
    this.nativeMessage,
    this.nativeStack,
  });

  /// Human-readable, developer-facing message.
  final String message;

  /// Raw message from the platform backend, if any.
  final String? nativeMessage;

  /// Native stack trace, if captured.
  final StackTrace? nativeStack;

  /// What the caller/user can do about it.
  final CameraErrorRecovery recovery;

  @override
  String toString() {
    final native = nativeMessage == null ? '' : ' (native: $nativeMessage)';
    return '$runtimeType: $message [recovery: ${recovery.name}]$native';
  }
}

/// Camera permission was denied.
final class CameraPermissionError extends CameraProError {
  const CameraPermissionError({required this.isPermanentlyDenied})
      : super(
          message: isPermanentlyDenied
              ? 'Camera permission permanently denied. Open Settings to grant '
                  'access.'
              : 'Camera permission denied. Please grant camera access.',
          recovery: CameraErrorRecovery.requestPermission,
        );

  /// True when the OS will no longer prompt and the user must visit Settings.
  final bool isPermanentlyDenied;
}

/// A device-level error occurred; the controller should be reinitialized.
final class CameraDeviceError extends CameraProError {
  const CameraDeviceError({required this.nativeErrorCode, required super.message})
      : super(recovery: CameraErrorRecovery.reinitialize);

  /// Platform error code (e.g. Android `ACAMERA_ERROR_*`).
  final int nativeErrorCode;
}

/// The camera is held by another application.
final class CameraInUseError extends CameraProError {
  const CameraInUseError()
      : super(
          message: 'Camera is in use by another application.',
          recovery: CameraErrorRecovery.userAction,
        );
}

/// The active session was interrupted (recoverable, usually automatically).
final class CameraSessionInterruptedError extends CameraProError {
  CameraSessionInterruptedError({required this.reason})
      : super(
          message: 'Camera session interrupted: ${reason.description}',
          recovery: CameraErrorRecovery.automatic,
        );

  /// Why the interruption happened.
  final CameraInterruptionReason reason;
}

/// The device is thermally throttling.
final class CameraThermalThrottleError extends CameraProError {
  CameraThermalThrottleError({
    required this.level,
    this.suggestedActions = const <String>[],
  }) : super(
          message: 'Device thermal throttling at level: ${level.name}',
          recovery: CameraErrorRecovery.automatic,
        );

  /// Current thermal severity.
  final ThermalLevel level;

  /// Actions the SDK took or recommends.
  final List<String> suggestedActions;
}

/// A requested feature is not supported by this device/backend.
final class CameraFeatureNotSupportedError extends CameraProError {
  const CameraFeatureNotSupportedError({
    required this.feature,
    required this.platformReason,
  }) : super(
          message: '$feature is not supported: $platformReason',
          recovery: CameraErrorRecovery.fatal,
        );

  /// The feature name (e.g. "Manual ISO").
  final String feature;

  /// Why the platform can't provide it.
  final String platformReason;
}

/// A capture (photo/video) failed.
final class CameraCaptureError extends CameraProError {
  CameraCaptureError({required this.reason})
      : super(
          message: 'Capture failed: ${reason.description}',
          recovery: CameraErrorRecovery.retry,
        );

  /// Why the capture failed.
  final CaptureFailureReason reason;
}

/// The camera system service crashed; recovery likely needs a device restart.
final class CameraServiceFatalError extends CameraProError {
  const CameraServiceFatalError()
      : super(
          message: 'Camera system service crashed. Device restart may be '
              'required.',
          recovery: CameraErrorRecovery.deviceRestart,
        );
}

/// An invalid argument was passed to the SDK.
final class CameraInvalidParameterError extends CameraProError {
  const CameraInvalidParameterError({required super.message})
      : super(recovery: CameraErrorRecovery.retry);
}

/// Maps a native `camera_error_t` integer to a typed error. Keep in sync with
/// `camera_pro_types.h`.
CameraProError cameraProErrorFromCode(int code, {String? nativeMessage}) {
  switch (code) {
    case 6: // CAMERA_ERROR_PERMISSION_DENIED
      return CameraPermissionError(isPermanentlyDenied: false);
    case 4: // CAMERA_ERROR_DEVICE_IN_USE
      return CameraInUseError();
    case 5: // CAMERA_ERROR_DEVICE_DISCONNECTED
      return CameraDeviceError(
        nativeErrorCode: code,
        message: 'Camera disconnected',
      );
    case 9: // CAMERA_ERROR_FEATURE_NOT_SUPPORTED
      return CameraFeatureNotSupportedError(
        feature: 'Requested operation',
        platformReason: nativeMessage ?? 'Not available on this device',
      );
    case 10: // CAMERA_ERROR_INVALID_PARAMETER
      return CameraInvalidParameterError(
        message: nativeMessage ?? 'Invalid parameter',
      );
    case 12: // CAMERA_ERROR_THERMAL_THROTTLE
      return CameraThermalThrottleError(level: ThermalLevel.serious);
    case 14: // CAMERA_ERROR_SERVICE_FATAL
      return CameraServiceFatalError();
    case 8: // CAMERA_ERROR_CAPTURE_FAILED
      return CameraCaptureError(reason: CaptureFailureReason.unknown);
    default:
      return CameraDeviceError(
        nativeErrorCode: code,
        message: nativeMessage ?? 'Camera error (code $code)',
      );
  }
}
