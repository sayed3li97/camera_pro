import 'dart:typed_data';

import 'package:camera_pro/camera_pro.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('HistogramData', () {
    test('empty histogram is all zeros', () {
      final h = HistogramData.empty();
      expect(h.totalPixels, 0);
      expect(h.peak, 0);
      expect(h.clippedHighlights, 0);
      expect(h.clippedShadows, 0);
    });

    test('derived metrics compute from bins', () {
      final luma = Uint32List(256);
      luma[0] = 10; // crushed shadows
      luma[128] = 80;
      luma[255] = 10; // clipped highlights
      final h = HistogramData(
        luminance: luma,
        red: Uint32List(256),
        green: Uint32List(256),
        blue: Uint32List(256),
      );
      expect(h.totalPixels, 100);
      expect(h.peak, 80);
      expect(h.clippedHighlights, closeTo(0.10, 1e-9));
      expect(h.clippedShadows, closeTo(0.10, 1e-9));
    });
  });
}
