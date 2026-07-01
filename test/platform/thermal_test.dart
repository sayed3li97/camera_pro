import 'package:camera_pro/camera_pro.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ThermalLevel', () {
    test('requiresThrottling from serious upward', () {
      expect(ThermalLevel.nominal.requiresThrottling, isFalse);
      expect(ThermalLevel.fair.requiresThrottling, isFalse);
      expect(ThermalLevel.serious.requiresThrottling, isTrue);
      expect(ThermalLevel.critical.requiresThrottling, isTrue);
    });
  });

  group('ThermalPolicy', () {
    test('nominal keeps full quality', () {
      final s = ThermalPolicy.policyFor(ThermalLevel.nominal);
      expect(s.throttledFrameRate, isNull);
      expect(s.disabledFeatures, isEmpty);
    });

    test('serious clamps fps and resolution', () {
      final s = ThermalPolicy.policyFor(ThermalLevel.serious);
      expect(s.throttledFrameRate, 30);
      expect(s.throttledResolutionHeight, 1080);
    });

    test('critical disables visual aids', () {
      final s = ThermalPolicy.policyFor(ThermalLevel.critical);
      expect(s.disabledFeatures, contains('histogram'));
      expect(s.throttledResolutionHeight, 720);
    });

    test('shutdown stops recording', () {
      final s = ThermalPolicy.policyFor(ThermalLevel.shutdown);
      expect(s.disabledFeatures, contains('recording'));
    });
  });
}
