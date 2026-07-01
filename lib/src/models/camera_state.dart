/// Camera lifecycle state and transition types.
///
/// Kept in sync with `camera_state_t` in `camera_pro_types.h`. The state machine
/// that enforces valid transitions lives in
/// `controller/camera_state_machine.dart`.
library;

import 'package:meta/meta.dart';

/// Every distinct state a camera session can occupy.
enum CameraState {
  /// No resources allocated.
  uninitialized,

  /// Device opened, session not yet configured.
  opened,

  /// Preview stream active, ready to capture.
  previewing,

  /// A photo capture is in progress (transient).
  capturing,

  /// Video recording active.
  recording,

  /// Video recording paused.
  recordingPaused,

  /// Interrupted by the system (call, background, thermal).
  interrupted,

  /// Recoverable error; auto-recovery may be underway.
  error,

  /// Unrecoverable error.
  fatal,

  /// Disposed; all resources released.
  disposed;

  /// Whether the session is in a state where capture can be requested.
  bool get canCapture => this == CameraState.previewing;

  /// Whether the session currently holds camera hardware.
  bool get isActive => switch (this) {
        CameraState.opened ||
        CameraState.previewing ||
        CameraState.capturing ||
        CameraState.recording ||
        CameraState.recordingPaused =>
          true,
        _ => false,
      };

  /// Maps the native integer state to this enum.
  static CameraState fromNative(int value) =>
      value >= 0 && value < CameraState.values.length
          ? CameraState.values[value]
          : CameraState.error;
}

/// An observed state transition, emitted on the controller's state stream.
@immutable
class CameraStateChange {
  const CameraStateChange({required this.from, required this.to});

  /// Previous state.
  final CameraState from;

  /// New state.
  final CameraState to;

  @override
  bool operator ==(Object other) =>
      other is CameraStateChange && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);

  @override
  String toString() => 'CameraStateChange(${from.name} → ${to.name})';
}

/// Thrown when an invalid state transition is attempted.
class CameraStateException implements Exception {
  CameraStateException(this.message);

  /// Description of the illegal transition.
  final String message;

  @override
  String toString() => 'CameraStateException: $message';
}
