import 'package:camera_pro/camera_pro.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CameraProError recovery guidance', () {
    test('permission error asks for permission', () {
      final e = CameraPermissionError(isPermanentlyDenied: true);
      expect(e.recovery, CameraErrorRecovery.requestPermission);
      expect(e.message, contains('Settings'));
    });

    test('in-use error requires user action', () {
      expect(const CameraInUseError().recovery, CameraErrorRecovery.userAction);
    });

    test('feature-not-supported is fatal for that feature', () {
      const e = CameraFeatureNotSupportedError(
        feature: 'Manual ISO',
        platformReason: 'LEGACY device',
      );
      expect(e.recovery, CameraErrorRecovery.fatal);
      expect(e.toString(), contains('Manual ISO'));
    });

    test('service-fatal recommends device restart', () {
      expect(
        const CameraServiceFatalError().recovery,
        CameraErrorRecovery.deviceRestart,
      );
    });

    test('errors are exhaustively switchable (sealed)', () {
      CameraProError e = const CameraInUseError();
      String kind(CameraProError err) => switch (err) {
            CameraPermissionError() => 'permission',
            CameraDeviceError() => 'device',
            CameraInUseError() => 'in-use',
            CameraSessionInterruptedError() => 'interrupted',
            CameraThermalThrottleError() => 'thermal',
            CameraFeatureNotSupportedError() => 'unsupported',
            CameraCaptureError() => 'capture',
            CameraServiceFatalError() => 'fatal',
            CameraInvalidParameterError() => 'invalid',
          };
      expect(kind(e), 'in-use');
      e = CameraCaptureError(reason: CaptureFailureReason.timeout);
      expect(kind(e), 'capture');
    });
  });

  group('cameraProErrorFromCode', () {
    test('maps native codes to typed errors', () {
      expect(cameraProErrorFromCode(6), isA<CameraPermissionError>());
      expect(cameraProErrorFromCode(4), isA<CameraInUseError>());
      expect(cameraProErrorFromCode(9), isA<CameraFeatureNotSupportedError>());
      expect(cameraProErrorFromCode(14), isA<CameraServiceFatalError>());
    });

    test('unknown code falls back to device error', () {
      final e = cameraProErrorFromCode(999, nativeMessage: 'weird');
      expect(e, isA<CameraDeviceError>());
      expect((e as CameraDeviceError).nativeErrorCode, 999);
    });
  });
}
