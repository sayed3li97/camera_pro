/// Web implementation of [NativeCore] / [NativeBufferPool].
///
/// The web target has no C core over FFI, so the visual-aid kernels are
/// reimplemented in pure Dart here — byte-for-byte matching the C reference in
/// `src/core/image_processor.c` (same fixed-point luma `(77r+150g+29b)>>8`,
/// same Sobel, same exposure zones). This keeps `NativeCore.histogramFromRgba`
/// et al. working identically on web and native.
library;

import 'dart:typed_data';

import '../processing/histogram.dart';
import '../processing/waveform.dart';

int _luma(int r, int g, int b) => (77 * r + 150 * g + 29 * b) >> 8;
int _clamp(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

/// Pure-Dart drop-in for the FFI `NativeCore` (web target).
class NativeCore {
  const NativeCore._();

  static String get versionString => '0.1.0';
  static int get versionCode => (0 << 16) | (1 << 8) | 0;

  /// There is no SIMD/C path on web; kernels run in Dart.
  static String get simdName => 'dart';

  static String errorString(int code) => 'error $code';

  static HistogramData histogramFromRgba(
    Uint8List rgba, {
    required int width,
    required int height,
    int stride = 0,
  }) {
    final s = stride == 0 ? width * 4 : stride;
    final luma = Uint32List(256);
    final red = Uint32List(256);
    final green = Uint32List(256);
    final blue = Uint32List(256);
    for (var y = 0; y < height; y++) {
      var i = y * s;
      for (var x = 0; x < width; x++, i += 4) {
        final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
        luma[_luma(r, g, b)]++;
        red[r]++;
        green[g]++;
        blue[b]++;
      }
    }
    return HistogramData(luminance: luma, red: red, green: green, blue: blue);
  }

  static WaveformData waveformFromRgba(
    Uint8List rgba, {
    required int width,
    required int height,
    int columns = 256,
    bool isBgra = false,
    int stride = 0,
  }) {
    final s = stride == 0 ? width * 4 : stride;
    final ri = isBgra ? 2 : 0;
    final bi = isBgra ? 0 : 2;
    final bins = Uint32List(columns * 256);
    for (var y = 0; y < height; y++) {
      final row = y * s;
      for (var x = 0; x < width; x++) {
        final col = (x * columns) ~/ width;
        final p = row + x * 4;
        final l = _luma(rgba[p + ri], rgba[p + 1], rgba[p + bi]);
        bins[(col >= columns ? columns - 1 : col) * 256 + l]++;
      }
    }
    return WaveformData(columns: columns, bins: bins);
  }

  static Uint8List falseColorFromRgba(
    Uint8List rgba, {
    required int width,
    required int height,
    bool isBgra = false,
    int stride = 0,
  }) {
    final s = stride == 0 ? width * 4 : stride;
    final ri = isBgra ? 2 : 0;
    final bi = isBgra ? 0 : 2;
    final out = Uint8List(width * height * 4);
    for (var y = 0; y < height; y++) {
      final src = y * s;
      final dst = y * width * 4;
      for (var x = 0; x < width; x++) {
        final p = src + x * 4;
        final o = dst + x * 4;
        final l = _luma(rgba[p + ri], rgba[p + 1], rgba[p + bi]);
        int r, g, b;
        if (l < 3) {
          (r, g, b) = (0x30, 0x00, 0x60);
        } else if (l < 20) {
          (r, g, b) = (0x00, 0x00, 0xFF);
        } else if (l < 42) {
          (r, g, b) = (0x00, 0xC0, 0xFF);
        } else if (l < 100) {
          (r, g, b) = (0x00, 0xFF, 0x00);
        } else if (l < 150) {
          (r, g, b) = (0xC0, 0xC0, 0xC0);
        } else if (l < 200) {
          (r, g, b) = (0xFF, 0xC0, 0xC0);
        } else if (l < 250) {
          (r, g, b) = (0xFF, 0xFF, 0x00);
        } else {
          (r, g, b) = (0xFF, 0x00, 0x00);
        }
        out[o + ri] = r;
        out[o + 1] = g;
        out[o + bi] = b;
        out[o + 3] = rgba[p + 3];
      }
    }
    return out;
  }

  static Uint8List focusPeaking(
    Uint8List rgba, {
    required int width,
    required int height,
    bool isBgra = true,
    double threshold = 0.15,
    int peakColor = 0xFFFFFFFF,
    int stride = 0,
  }) {
    final s = stride == 0 ? width * 4 : stride;
    final ri = isBgra ? 2 : 0;
    final bi = isBgra ? 0 : 2;
    final pr = (peakColor >> 24) & 0xFF;
    final pg = (peakColor >> 16) & 0xFF;
    final pb = (peakColor >> 8) & 0xFF;
    final thr = threshold * 1020.0;
    final thr2 = thr * thr;
    final out = Uint8List(width * height * 4);

    int lumaAt(int x, int y) {
      final p = y * s + x * 4;
      return _luma(rgba[p], rgba[p + 1], rgba[p + 2]);
    }

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final src = y * s + x * 4;
        final o = (y * width + x) * 4;
        out[o] = rgba[src];
        out[o + 1] = rgba[src + 1];
        out[o + 2] = rgba[src + 2];
        out[o + 3] = rgba[src + 3];
        if (x < 1 || y < 1 || x >= width - 1 || y >= height - 1) continue;
        final tl = lumaAt(x - 1, y - 1),
            tc = lumaAt(x, y - 1),
            tr = lumaAt(x + 1, y - 1);
        final ml = lumaAt(x - 1, y), mr = lumaAt(x + 1, y);
        final bl = lumaAt(x - 1, y + 1),
            bc = lumaAt(x, y + 1),
            br = lumaAt(x + 1, y + 1);
        final gx = -tl + tr - 2 * ml + 2 * mr - bl + br;
        final gy = -tl - 2 * tc - tr + bl + 2 * bc + br;
        if (gx * gx + gy * gy > thr2) {
          out[o + ri] = pr;
          out[o + 1] = pg;
          out[o + bi] = pb;
        }
      }
    }
    return out;
  }

  static Uint8List zebra(
    Uint8List rgba, {
    required int width,
    required int height,
    bool isBgra = true,
    double threshold = 0.9,
    int frameCounter = 0,
    int stride = 0,
  }) {
    final s = stride == 0 ? width * 4 : stride;
    final ri = isBgra ? 2 : 0;
    final bi = isBgra ? 0 : 2;
    final thr = (threshold * 255).toInt();
    final out = Uint8List(width * height * 4);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final src = y * s + x * 4;
        final o = (y * width + x) * 4;
        out[o] = rgba[src];
        out[o + 1] = rgba[src + 1];
        out[o + 2] = rgba[src + 2];
        out[o + 3] = rgba[src + 3];
        final l = _luma(rgba[src + ri], rgba[src + 1], rgba[src + bi]);
        if (l > thr) {
          final stripe = ((x + y + frameCounter * 2) ~/ 4) & 1;
          if (stripe == 0) {
            out[o + ri] = 255;
            out[o + 1] = 0;
            out[o + bi] = 0;
          }
        }
      }
    }
    return out;
  }

  /// Digital manual-control adjustment (in place), mirroring
  /// `camera_pro_adjust_pixels`.
  static void adjustPixels(
    Uint8List px, {
    required int width,
    required int height,
    bool isBgra = true,
    double gain = 1.0,
    double bias = 0.0,
    double temp = 0.0,
    double contrast = 1.0,
    int stride = 0,
  }) {
    final s = stride == 0 ? width * 4 : stride;
    final ri = isBgra ? 2 : 0;
    final bi = isBgra ? 0 : 2;
    final rGain = 1.0 + temp * 0.6;
    final bGain = 1.0 - temp * 0.6;
    for (var y = 0; y < height; y++) {
      var i = y * s;
      for (var x = 0; x < width; x++, i += 4) {
        final ch = <double>[px[i].toDouble(), px[i + 1].toDouble(), px[i + 2].toDouble()];
        for (var c = 0; c < 3; c++) {
          var v = (ch[c] - 128.0) * contrast + 128.0;
          v = v * gain + bias;
          ch[c] = v;
        }
        ch[ri == 2 ? 2 : 0] *= rGain;
        ch[bi == 2 ? 2 : 0] *= bGain;
        px[i] = _clamp((ch[0] + 0.5).toInt());
        px[i + 1] = _clamp((ch[1] + 0.5).toInt());
        px[i + 2] = _clamp((ch[2] + 0.5).toInt());
      }
    }
  }
}

/// Minimal pure-Dart buffer pool (web has no native ring buffer).
class NativeBufferPool {
  NativeBufferPool._(this.bufferSize, this.count);

  static NativeBufferPool? create({required int bufferSize, required int count}) {
    if (bufferSize <= 0 || count <= 0) return null;
    return NativeBufferPool._(bufferSize, count);
  }

  final int bufferSize;
  final int count;

  int get available => count;
  void dispose() {}
}
