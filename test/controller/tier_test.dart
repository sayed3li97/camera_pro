import 'package:camera_pro/camera_pro.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

void main() {
  group('determineTier', () {
    test('full tier when all manual controls supported', () {
      expect(determineTier(fullCapabilities()), CameraTier.full);
    });

    test('standard tier when only EV supported', () {
      expect(determineTier(standardCapabilities()), CameraTier.standard);
    });

    test('basic tier when nothing manual supported', () {
      expect(
        determineTier(CameraCapabilities.unsupported()),
        CameraTier.basic,
      );
    });
  });
}
