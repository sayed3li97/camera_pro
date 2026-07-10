import 'dart:typed_data';

import 'package:camera_pro/camera_pro.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

void main() {
  group('CameraProController.create', () {
    test('opens, reads capabilities, and starts preview', () async {
      final backend = RecordingBackend();
      final controller = await CameraPro.create(backend: backend);
      addTearDown(controller.dispose);

      expect(controller.state, CameraState.previewing);
      expect(controller.tier, CameraTier.full);
      expect(controller.textureId, 42);
      expect(backend.calls, contains('startPreview'));
    });
  });

  group('capability-guarded controls (full tier)', () {
    late CameraProController controller;

    setUp(() {
      controller = CameraProController.forTesting(
        capabilities: fullCapabilities(),
        backend: RecordingBackend(),
      );
    });

    test('setIso within range applies and records', () async {
      await controller.setIso(const Iso(400));
      expect(controller.currentSettings.iso, const Iso(400));
    });

    test('setIso out of range throws CameraInvalidParameterError', () async {
      expect(
        () => controller.setIso(const Iso(50000)),
        throwsA(isA<CameraInvalidParameterError>()),
      );
    });

    test('setShutterSpeed applies within range', () async {
      await controller.setShutterSpeed(ShutterSpeed.fromFraction(1, 500));
      expect(controller.currentSettings.shutterSpeed?.label, '1/500');
    });

    test('setWhiteBalance manual within Kelvin range applies', () async {
      await controller.setWhiteBalance(const WhiteBalance.temperature(5600));
      expect(controller.currentSettings.whiteBalance?.kelvin, 5600);
    });

    test('setWhiteBalance out of Kelvin range throws', () async {
      expect(
        () => controller.setWhiteBalance(const WhiteBalance.temperature(50000)),
        throwsA(isA<CameraInvalidParameterError>()),
      );
    });
  });

  group('capability-guarded controls (basic tier — crash-proof)', () {
    late CameraProController controller;

    setUp(() {
      controller = CameraProController.forTesting(
        capabilities: CameraCapabilities.unsupported(),
      );
    });

    test('setIso throws CameraFeatureNotSupportedError, never native crash',
        () async {
      expect(
        () => controller.setIso(const Iso(100)),
        throwsA(isA<CameraFeatureNotSupportedError>()),
      );
    });

    test('setShutterSpeed throws CameraFeatureNotSupportedError', () async {
      expect(
        () => controller.setShutterSpeed(ShutterSpeed.fromFraction(1, 250)),
        throwsA(isA<CameraFeatureNotSupportedError>()),
      );
    });

    test('setFocusDistance throws CameraFeatureNotSupportedError', () async {
      expect(
        () => controller.setFocusDistance(1.0),
        throwsA(isA<CameraFeatureNotSupportedError>()),
      );
    });
  });

  group('capture', () {
    test('capturePhoto transitions capturing → previewing', () async {
      final backend = RecordingBackend();
      final controller = CameraProController.forTesting(
        capabilities: fullCapabilities(),
        backend: backend,
      );
      final photo = await controller.capturePhoto(format: ImageFormat.jpeg);
      expect(photo.path, '/tmp/photo.jpg');
      expect(controller.state, CameraState.previewing);
      expect(backend.calls, contains('capture:ImageFormat.jpeg'));
    });

    test('RAW capture throws when unsupported', () async {
      final controller = CameraProController.forTesting(
        capabilities: standardCapabilities(),
        backend: RecordingBackend(),
      );
      expect(
        () => controller.capturePhoto(format: ImageFormat.raw),
        throwsA(isA<CameraFeatureNotSupportedError>()),
      );
    });

    test('captureHdr brackets, fuses, and restores exposure', () async {
      final backend = RecordingBackend()
        ..frame = PreviewFrame(
            bytes: Uint8List(2 * 1 * 4), width: 2, height: 1, isBgra: false);
      final controller = CameraProController.forTesting(
        capabilities: fullCapabilities(),
        backend: backend,
      );
      final photo = await controller.captureHdr(stops: const [-1.0, 0.0, 1.0]);
      expect(photo.path, '/tmp/hdr.png');
      expect(controller.state, CameraState.previewing);
      // Bracket walks the three stops in order, then restores to the baseline
      // (0), not the last stop — otherwise the camera is left over-exposed.
      // Parse the EV numerically so the assertion holds on both the VM and web
      // (dart2js prints -1.0 as "-1").
      final evValues = backend.calls
          .where((c) => c.startsWith('ev:'))
          .map((c) => double.parse(c.substring(3)))
          .toList();
      expect(evValues, <double>[-1.0, 0.0, 1.0, 0.0]);
      expect(evValues.last, 0.0); // exposure restored last
      expect(backend.calls, contains('fuse:3:2x1'));
    });

    test('captureHdr throws when HDR is unsupported', () async {
      final controller = CameraProController.forTesting(
        capabilities: standardCapabilities(),
        backend: RecordingBackend(),
      );
      expect(
        () => controller.captureHdr(),
        throwsA(isA<CameraFeatureNotSupportedError>()),
      );
    });

    test('captureHdr rejects a mid-bracket resolution change and recovers',
        () async {
      // Frame 2 comes back a different size (e.g. an orientation flip on web).
      final backend = RecordingBackend()
        ..frameQueue.addAll(<PreviewFrame>[
          PreviewFrame(
              bytes: Uint8List(2 * 2 * 4), width: 2, height: 2, isBgra: false),
          PreviewFrame(
              bytes: Uint8List(4 * 2 * 4), width: 4, height: 2, isBgra: false),
        ]);
      final controller = CameraProController.forTesting(
        capabilities: fullCapabilities(),
        backend: backend,
      );
      await expectLater(
        controller.captureHdr(stops: const [-1.0, 1.0]),
        throwsA(isA<CameraCaptureError>()),
      );
      // The finally still restored exposure and unwedged the state machine.
      expect(controller.state, CameraState.previewing);
      final lastEv =
          backend.calls.where((c) => c.startsWith('ev:')).last;
      expect(double.parse(lastEv.substring(3)), 0.0);
    });
  });
}
