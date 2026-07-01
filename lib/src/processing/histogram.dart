/// Real-time histogram data model.
///
/// The native core (`camera_pro_compute_histogram_rgba`) fills four 256-bin
/// arrays each frame; this immutable view wraps them for the UI.
library;

import 'dart:typed_data';

import 'package:meta/meta.dart';

/// One frame's worth of luminance + RGB histogram bins.
@immutable
class HistogramData {
  const HistogramData({
    required this.luminance,
    required this.red,
    required this.green,
    required this.blue,
  });

  /// A flat/empty histogram (all zeros).
  factory HistogramData.empty() => HistogramData(
        luminance: Uint32List(256),
        red: Uint32List(256),
        green: Uint32List(256),
        blue: Uint32List(256),
      );

  /// 256 luminance bins.
  final Uint32List luminance;

  /// 256 red bins.
  final Uint32List red;

  /// 256 green bins.
  final Uint32List green;

  /// 256 blue bins.
  final Uint32List blue;

  /// The largest bin count across all channels (for normalizing a chart).
  int get peak {
    var maxV = 0;
    for (final ch in <Uint32List>[luminance, red, green, blue]) {
      for (final v in ch) {
        if (v > maxV) maxV = v;
      }
    }
    return maxV;
  }

  /// Total number of pixels sampled (sum of luminance bins).
  int get totalPixels {
    var sum = 0;
    for (final v in luminance) {
      sum += v;
    }
    return sum;
  }

  /// Fraction of pixels at the top luminance bin (clipped highlights, 0..1).
  double get clippedHighlights {
    final total = totalPixels;
    return total == 0 ? 0 : luminance[255] / total;
  }

  /// Fraction of pixels at the bottom luminance bin (crushed shadows, 0..1).
  double get clippedShadows {
    final total = totalPixels;
    return total == 0 ? 0 : luminance[0] / total;
  }
}
