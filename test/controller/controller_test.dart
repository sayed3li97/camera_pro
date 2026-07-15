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

    test('captureHdr renders from a single frame (no exposure walk)', () async {
      final backend = RecordingBackend()
        ..frame = PreviewFrame(
            bytes: Uint8List(2 * 1 * 4), width: 2, height: 1, isBgra: false);
      final controller = CameraProController.forTesting(
        capabilities: fullCapabilities(),
        backend: backend,
      );
      final photo = await controller.captureHdr(stops: const [-2.0, 0.0, 2.0]);
      expect(photo.path, '/tmp/hdr.png');
      expect(controller.state, CameraState.previewing);
      expect(backend.calls, contains('hdr:3:2x1'));
      // Single capture: it must NOT walk exposures (that path ghosts).
      expect(backend.calls.where((c) => c.startsWith('ev:')), isEmpty);
    });

    test('captureHdr surfaces noFrame and recovers state', () async {
      final backend = RecordingBackend(); // latestFrame() == null
      final controller = CameraProController.forTesting(
        capabilities: fullCapabilities(),
        backend: backend,
      );
      await expectLater(
        controller.captureHdr(),
        throwsA(isA<CameraCaptureError>()),
      );
      expect(controller.state, CameraState.previewing);
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
  });
}
