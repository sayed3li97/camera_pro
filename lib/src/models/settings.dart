/// Value types and enums for camera settings.
///
/// These are strongly-typed wrappers (ISO, shutter speed, EV, white balance) so
/// the API can't be called with a bare `int` that means the wrong thing, plus
/// the enums that describe modes and formats.
library;

import 'package:meta/meta.dart';

/// Exposure control mode.
enum ExposureMode { auto, manual, shutterPriority, isoPriority }

/// Light metering strategy.
enum MeteringMode { matrix, center, spot }

/// Auto-focus behaviour.
enum FocusMode { autoSingle, autoContinuous, manual }

/// White balance preset (or [WhiteBalanceMode.manual] for Kelvin control).
enum WhiteBalanceMode {
  auto,
  daylight,
  cloudy,
  shade,
  tungsten,
  fluorescent,
  flash,
  manual,
}

/// Flash firing mode.
enum FlashMode { off, auto, on }

/// Still-image output format.
enum ImageFormat { jpeg, png, heif, raw, rawPlusJpeg, proRaw }

/// Video codec.
enum VideoCodec { h264, hevc, prores, av1 }

/// Video color profile / gamma.
enum ColorProfile { standard, flat, log, hlg, appleLog }

/// Video stabilization strategy.
enum Stabilization { off, standard, cinematic, auto }

/// Live-streaming transport.
enum StreamProtocol { rtmp, rtsp, srt, hls }

/// A strongly-typed ISO value.
@immutable
class Iso {
  const Iso(this.value) : assert(value > 0, 'ISO must be positive');

  /// The raw ISO sensitivity (e.g. 100, 800).
  final int value;

  @override
  bool operator ==(Object other) => other is Iso && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'ISO $value';
}

/// A strongly-typed exposure compensation value in stops (EV).
@immutable
class Ev {
  const Ev(this.stops);

  /// Exposure compensation in stops (e.g. -0.7, +1.0).
  final double stops;

  @override
  bool operator ==(Object other) => other is Ev && other.stops == stops;

  @override
  int get hashCode => stops.hashCode;

  @override
  String toString() => '${stops >= 0 ? '+' : ''}${stops.toStringAsFixed(1)} EV';
}

/// A shutter speed, stored internally as a [Duration] but constructible from the
/// familiar `1/x` photographic fractions.
@immutable
class ShutterSpeed {
  const ShutterSpeed(this.duration);

  /// Builds a shutter speed from a fraction of a second, e.g.
  /// `ShutterSpeed.fromFraction(1, 500)` for 1/500s.
  factory ShutterSpeed.fromFraction(int numerator, int denominator) {
    assert(denominator > 0, 'denominator must be positive');
    final micros = (numerator * 1000000) ~/ denominator;
    return ShutterSpeed(Duration(microseconds: micros));
  }

  /// Builds a shutter speed from whole seconds (long exposure).
  factory ShutterSpeed.seconds(double seconds) =>
      ShutterSpeed(Duration(microseconds: (seconds * 1000000).round()));

  /// The exposure time.
  final Duration duration;

  /// Nanoseconds, as passed across the FFI boundary.
  int get nanoseconds => duration.inMicroseconds * 1000;

  /// A photographer-friendly label like "1/500s" or "2s".
  String get label {
    final us = duration.inMicroseconds;
    if (us <= 0) return '0';
    if (us >= 1000000) {
      return '${(us / 1000000).toStringAsFixed(us % 1000000 == 0 ? 0 : 1)}s';
    }
    final denom = (1000000 / us).round();
    return '1/$denom';
  }

  @override
  bool operator ==(Object other) =>
      other is ShutterSpeed && other.duration == duration;

  @override
  int get hashCode => duration.hashCode;

  @override
  String toString() => 'ShutterSpeed($label)';
}

/// White balance, either a preset [WhiteBalanceMode] or a manual Kelvin value.
@immutable
class WhiteBalance {
  const WhiteBalance.preset(this.mode)
      : kelvin = null,
        assert(mode != WhiteBalanceMode.manual,
            'Use WhiteBalance.temperature for manual mode');

  const WhiteBalance.temperature(int this.kelvin)
      : mode = WhiteBalanceMode.manual;

  /// The preset mode, or [WhiteBalanceMode.manual].
  final WhiteBalanceMode mode;

  /// Manual color temperature in Kelvin, when [mode] is manual.
  final int? kelvin;

  @override
  bool operator ==(Object other) =>
      other is WhiteBalance && other.mode == mode && other.kelvin == kelvin;

  @override
  int get hashCode => Object.hash(mode, kelvin);

  @override
  String toString() =>
      mode == WhiteBalanceMode.manual ? '${kelvin}K' : mode.name;
}

/// A discrete video resolution.
@immutable
class VideoResolution {
  const VideoResolution(this.width, this.height);

  final int width;
  final int height;

  static const VideoResolution hd720p = VideoResolution(1280, 720);
  static const VideoResolution fhd1080p = VideoResolution(1920, 1080);
  static const VideoResolution uhd4k = VideoResolution(3840, 2160);
  static const VideoResolution uhd8k = VideoResolution(7680, 4320);

  @override
  bool operator ==(Object other) =>
      other is VideoResolution && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => '${width}x$height';
}

/// A video/preview bitrate.
@immutable
class Bitrate {
  const Bitrate(this.bitsPerSecond);

  factory Bitrate.mbps(num mbps) => Bitrate((mbps * 1000000).round());
  factory Bitrate.kbps(num kbps) => Bitrate((kbps * 1000).round());

  final int bitsPerSecond;

  @override
  String toString() => '${(bitsPerSecond / 1000000).toStringAsFixed(1)} Mbps';
}
