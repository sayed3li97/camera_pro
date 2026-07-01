import 'package:camera_pro/camera_pro.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CameraStateMachine', () {
    test('starts uninitialized', () {
      expect(CameraStateMachine().state, CameraState.uninitialized);
    });

    test('valid transition path opened → previewing → capturing', () {
      final sm = CameraStateMachine()..transition(CameraState.opened);
      sm.transition(CameraState.previewing);
      sm.transition(CameraState.capturing);
      expect(sm.state, CameraState.capturing);
    });

    test('illegal transition throws', () {
      final sm = CameraStateMachine();
      expect(
        () => sm.transition(CameraState.recording),
        throwsA(isA<CameraStateException>()),
      );
    });

    test('cannot leave fatal except to disposed', () {
      final sm = CameraStateMachine()
        ..transition(CameraState.opened)
        ..transition(CameraState.error)
        ..transition(CameraState.fatal);
      expect(sm.canTransitionTo(CameraState.previewing), isFalse);
      expect(sm.canTransitionTo(CameraState.disposed), isTrue);
    });

    test('emits change events', () async {
      final sm = CameraStateMachine();
      final events = <CameraStateChange>[];
      final sub = sm.changes.listen(events.add);
      sm.transition(CameraState.opened);
      sm.transition(CameraState.previewing);
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(2));
      expect(events.first.to, CameraState.opened);
      expect(events.last.to, CameraState.previewing);
      await sub.cancel();
      await sm.dispose();
    });
  });
}
