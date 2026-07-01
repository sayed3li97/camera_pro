// Real end-to-end test of the AVFoundation backend through Dart FFI.
//
// Runs only on macOS/iOS hosts, where hook/build.dart compiles the AVFoundation
// HAL into the code asset. It drives actual device enumeration + capability
// query against whatever camera the host has (e.g. the FaceTime HD Camera on a
// Mac). It never starts a capture session, so no camera permission is needed.
@TestOn('mac-os')
library;

import 'package:camera_pro/camera_pro.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AppleCameraBackend enumerates real devices and reports capabilities',
      () async {
    final backend = AppleCameraBackend();
    addTearDown(backend.close);

    final devices = await backend.enumerateDevices();
    expect(devices.devices, isNotEmpty,
        reason: 'a Mac should expose at least one camera');

    final device = devices.defaultCamera!;
    await backend.open(device);
    final caps = await backend.getCapabilities();

    // Real device metadata came back through FFI.
    expect(caps.deviceName, isNotEmpty);
    expect(caps.platformName, contains('AVFoundation'));

    // On macOS the built-in camera has no sensor controls, so the full manual
    // set (ISO, shutter, focus, WB, EV, zoom) is offered via the digital
    // pipeline — every control is Supported, landing the device at `full` tier.
    expect(caps.iso, isA<Supported<int>>());
    expect(caps.shutterSpeed, isA<Supported<Duration>>());
    expect(caps.focusDistance, isA<Supported<double>>());
    expect(caps.whiteBalanceKelvin, isA<Supported<int>>());
    expect(caps.exposureCompensation, isA<Supported<double>>());
    expect(caps.zoom, isA<Supported<double>>());
    expect(determineTier(caps), CameraTier.full);
  });

  test('every digital manual control applies without a native crash', () async {
    final controller = await CameraPro.create(backend: AppleCameraBackend());
    addTearDown(controller.dispose);

    expect(controller.state, CameraState.previewing);

    // All six controls apply and update the settings snapshot.
    await controller.setIso(const Iso(400));
    await controller.setShutterSpeed(ShutterSpeed.fromFraction(1, 125));
    await controller.setExposureCompensation(const Ev(1.0));
    await controller.setWhiteBalance(const WhiteBalance.temperature(3200));
    await controller.setFocusDistance(0.9);
    await controller.setZoom(2.0);

    final s = controller.currentSettings;
    expect(s.iso, const Iso(400));
    expect(s.shutterSpeed?.label, '1/125');
    expect(s.zoom, 2.0);
    expect(s.focusDistance, 0.9);

    // Capture with no active frame stream surfaces a typed error (not a crash).
    await expectLater(
      controller.capturePhoto(format: ImageFormat.png),
      throwsA(isA<CameraCaptureError>()),
    );
  });
}
