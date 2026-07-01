/// Luminance waveform monitor data.
///
/// A waveform is a per-column luminance distribution: for each horizontal
/// bucket (`column`) it holds 256 bins counting how many pixels in that column
/// had each luminance value. Produced by `camera_pro_compute_luma_waveform`.
library;

import 'dart:typed_data';

import 'package:meta/meta.dart';

/// One frame's luminance waveform.
@immutable
class WaveformData {
  const WaveformData({required this.columns, required this.bins});

  /// Number of horizontal buckets.
  final int columns;

  /// Flat `columns * 256` counts; bin for (col, luma) is `bins[col * 256 + luma]`.
  final Uint32List bins;

  /// Count of pixels in [column] with luminance [luma] (both bounds-checked).
  int at(int column, int luma) {
    if (column < 0 || column >= columns || luma < 0 || luma > 255) return 0;
    return bins[column * 256 + luma];
  }

  /// The largest single-cell count (for normalizing a render).
  int get peak {
    var maxV = 0;
    for (final v in bins) {
      if (v > maxV) maxV = v;
    }
    return maxV;
  }
}
