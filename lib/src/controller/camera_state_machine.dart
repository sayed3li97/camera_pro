/// Strict camera state machine.
///
/// Rejects illegal transitions (e.g. recording before previewing) and emits a
/// stream of [CameraStateChange]s. This is the single source of truth for the
/// controller's lifecycle; the native `camera_state_callback_t` feeds into it.
library;

import 'dart:async';

import '../models/camera_state.dart';

/// Enforces the valid-transition graph for [CameraState].
class CameraStateMachine {
  CameraStateMachine([this._state = CameraState.uninitialized]);

  CameraState _state;
  final StreamController<CameraStateChange> _controller =
      StreamController<CameraStateChange>.broadcast();

  /// The current state.
  CameraState get state => _state;

  /// Stream of transitions, for reactive UIs.
  Stream<CameraStateChange> get changes => _controller.stream;

  /// The transition graph. A state maps to the set of states reachable from it.
  static const Map<CameraState, Set<CameraState>> _validTransitions =
      <CameraState, Set<CameraState>>{
    CameraState.uninitialized: <CameraState>{
      CameraState.opened,
      CameraState.disposed,
    },
    CameraState.opened: <CameraState>{
      CameraState.previewing,
      CameraState.error,
      CameraState.disposed,
    },
    CameraState.previewing: <CameraState>{
      CameraState.capturing,
      CameraState.recording,
      CameraState.interrupted,
      CameraState.error,
      CameraState.opened,
      CameraState.disposed,
    },
    CameraState.capturing: <CameraState>{
      CameraState.previewing,
      CameraState.error,
    },
    CameraState.recording: <CameraState>{
      CameraState.recordingPaused,
      CameraState.previewing,
      CameraState.interrupted,
      CameraState.error,
    },
    CameraState.recordingPaused: <CameraState>{
      CameraState.recording,
      CameraState.previewing,
      CameraState.error,
    },
    CameraState.interrupted: <CameraState>{
      CameraState.previewing,
      CameraState.opened,
      CameraState.error,
      CameraState.disposed,
    },
    CameraState.error: <CameraState>{
      CameraState.previewing,
      CameraState.opened,
      CameraState.fatal,
      CameraState.disposed,
    },
    CameraState.fatal: <CameraState>{CameraState.disposed},
    CameraState.disposed: <CameraState>{},
  };

  /// Whether [to] is a legal next state from the current state.
  bool canTransitionTo(CameraState to) =>
      _validTransitions[_state]?.contains(to) ?? false;

  /// Transitions to [to], throwing [CameraStateException] if illegal.
  void transition(CameraState to) {
    if (!canTransitionTo(to)) {
      final allowed = _validTransitions[_state] ?? const <CameraState>{};
      throw CameraStateException(
        'Invalid transition: ${_state.name} → ${to.name}. '
        'Allowed: ${allowed.isEmpty ? 'none' : allowed.map((s) => s.name).join(', ')}',
      );
    }
    final from = _state;
    _state = to;
    if (!_controller.isClosed) {
      _controller.add(CameraStateChange(from: from, to: to));
    }
  }

  /// Releases the change stream.
  Future<void> dispose() async {
    await _controller.close();
  }
}
