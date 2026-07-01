import 'package:camera_pro/camera_pro.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CameraState', () {
    test('canCapture only in previewing', () {
      expect(CameraState.previewing.canCapture, isTrue);
      expect(CameraState.recording.canCapture, isFalse);
      expect(CameraState.opened.canCapture, isFalse);
    });

    test('isActive reflects hardware ownership', () {
      expect(CameraState.previewing.isActive, isTrue);
      expect(CameraState.recording.isActive, isTrue);
      expect(CameraState.uninitialized.isActive, isFalse);
      expect(CameraState.disposed.isActive, isFalse);
    });

    test('fromNative maps valid indices and clamps invalid ones', () {
      expect(CameraState.fromNative(0), CameraState.uninitialized);
      expect(CameraState.fromNative(2), CameraState.previewing);
      expect(CameraState.fromNative(999), CameraState.error);
      expect(CameraState.fromNative(-1), CameraState.error);
    });
  });

  group('CameraStateChange', () {
    test('equality and toString', () {
      const a = CameraStateChange(
        from: CameraState.opened,
        to: CameraState.previewing,
      );
      const b = CameraStateChange(
        from: CameraState.opened,
        to: CameraState.previewing,
      );
      expect(a, b);
      expect(a.toString(), contains('opened → previewing'));
    });
  });
}
