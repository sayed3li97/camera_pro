import 'package:camera_pro/camera_pro.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

void main() {
  group('Capability', () {
    test('Supported exposes range and current value', () {
      const iso = Supported<int>(currentValue: 100, minValue: 50, maxValue: 12800);
      expect(iso.isSupported, isTrue);
      expect(iso.valueOrNull, 100);
      expect(iso.minValue, 50);
      expect(iso.maxValue, 12800);
    });

    test('NotSupported carries a reason and no value', () {
      const cap = NotSupported<int>(reason: 'Fixed aperture');
      expect(cap.isSupported, isFalse);
      expect(cap.valueOrNull, isNull);
      expect(cap.reason, 'Fixed aperture');
    });

    test('exhaustive switch handles both cases', () {
      Capability<int> cap = const Supported<int>(
        currentValue: 1,
        minValue: 0,
        maxValue: 2,
      );
      String describe(Capability<int> c) => switch (c) {
            Supported<int>(:final currentValue) => 'value $currentValue',
            NotSupported<int>(:final reason) => 'nope: $reason',
          };
      expect(describe(cap), 'value 1');
      cap = const NotSupported<int>(reason: 'x');
      expect(describe(cap), 'nope: x');
    });
  });

  group('CameraCapabilities', () {
    test('unsupported factory reports everything as NotSupported', () {
      final caps = CameraCapabilities.unsupported();
      expect(caps.iso, isA<NotSupported<int>>());
      expect(caps.shutterSpeed, isA<NotSupported<Duration>>());
      expect(caps.supportsRawCapture, isFalse);
      expect(caps.supportedPhotoFormats, isEmpty);
    });

    test('full fixture reports rich support', () {
      final caps = fullCapabilities();
      expect(caps.iso, isA<Supported<int>>());
      expect(caps.supportsRawCapture, isTrue);
      expect(caps.supportedFrameRates, contains(240));
      expect(caps.deviceName, 'iPhone 16 Pro');
    });
  });
}
