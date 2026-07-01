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

    // macOS honestly reports manual controls as unsupported (iOS-only APIs),
    // so the tier degrades to basic rather than crashing.
    expect(determineTier(caps), CameraTier.basic);
    expect(caps.iso, isA<NotSupported<int>>());
  });

  test('controller over AppleCameraBackend guards unsupported controls',
      () async {
    final controller =
        await CameraPro.create(backend: AppleCameraBackend());
    addTearDown(controller.dispose);

    expect(controller.state, CameraState.previewing);
    // Manual ISO is unsupported on macOS → typed error, never a native crash.
    await expectLater(
      controller.setIso(const Iso(100)),
      throwsA(isA<CameraFeatureNotSupportedError>()),
    );
  });
}
