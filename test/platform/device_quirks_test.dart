import 'package:camera_pro/camera_pro.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('quirksFor', () {
    test('matches Samsung SM-G99x family', () {
      final q = quirksFor('samsung', 'SM-G998B');
      expect(q, contains(DeviceQuirk.wbIgnoredInVideo));
      expect(q, contains(DeviceQuirk.rawColorShift));
    });

    test('is case-insensitive on manufacturer', () {
      expect(quirksFor('Samsung', 'SM-G991'), isNotEmpty);
    });

    test('unknown device has no quirks', () {
      expect(quirksFor('google', 'Pixel 8'), isEmpty);
    });

    test('OnePlus torch quirk', () {
      expect(
        quirksFor('oneplus', 'IN2025'),
        contains(DeviceQuirk.noTorchDuringRecording),
      );
    });
  });
}
