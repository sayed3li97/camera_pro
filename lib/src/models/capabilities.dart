/// The "Capability Passport" — a crash-proof description of what a device can do.
///
/// Every tunable is a [Capability]: either [Supported] (with range/current) or
/// [NotSupported] (with a human reason). Because [Capability] is `sealed`, a
/// `switch` handles both cases exhaustively — it is impossible to read a range
/// off an unsupported control by accident.
library;

import 'package:meta/meta.dart';

import 'settings.dart';

/// A device capability that is either [Supported] or [NotSupported].
@immutable
sealed class Capability<T> {
  const Capability();

  /// Convenience: the supported value, or null when unsupported.
  T? get valueOrNull => switch (this) {
        Supported<T>(:final currentValue) => currentValue,
        NotSupported<T>() => null,
      };

  /// Whether this capability is available on the device.
  bool get isSupported => this is Supported<T>;
}

/// A capability the device supports, with its range and current value.
@immutable
final class Supported<T> extends Capability<T> {
  const Supported({
    required this.currentValue,
    required this.minValue,
    required this.maxValue,
    this.stepSize,
  });

  /// The current value of the control.
  final T currentValue;

  /// Minimum settable value.
  final T minValue;

  /// Maximum settable value.
  final T maxValue;

  /// Increment between valid values, if quantized.
  final T? stepSize;

  @override
  String toString() => 'Supported($minValue..$maxValue, current: $currentValue)';
}

/// A capability the device does not support, with a human-readable reason.
@immutable
final class NotSupported<T> extends Capability<T> {
  const NotSupported({required this.reason});

  /// Why the control is unavailable (e.g. "Fixed aperture lens").
  final String reason;

  @override
  String toString() => 'NotSupported($reason)';
}

/// The full capability passport for an opened camera.
@immutable
class CameraCapabilities {
  const CameraCapabilities({
    required this.shutterSpeed,
    required this.iso,
    required this.aperture,
    required this.whiteBalanceKelvin,
    required this.focusDistance,
    required this.exposureCompensation,
    required this.zoom,
    required this.supportedMeteringModes,
    required this.supportedFocusModes,
    required this.supportedPhotoFormats,
    required this.supportedVideoResolutions,
    required this.supportedFrameRates,
    required this.supportedVideoCodecs,
    required this.supportsRawCapture,
    required this.supportsProRaw,
    required this.supportsBurstMode,
    required this.supportsHdr,
    required this.supportsBracketing,
    required this.supportsDepthCapture,
    required this.supportsLidar,
    required this.supportsMultiCamera,
    required this.supportsFaceDetection,
    required this.supportsSlowMotion,
    required this.hasFlash,
    required this.hasTorch,
    required this.hasOis,
    required this.platformName,
    required this.deviceName,
    required this.hardwareLevel,
  });

  /// Empty passport used before a device is opened or on the stub backend.
  factory CameraCapabilities.unsupported({
    String platformName = 'unknown',
    String deviceName = 'unknown',
    int hardwareLevel = -1,
    String reason = 'No camera opened',
  }) {
    return CameraCapabilities(
      shutterSpeed: NotSupported<Duration>(reason: reason),
      iso: NotSupported<int>(reason: reason),
      aperture: NotSupported<double>(reason: reason),
      whiteBalanceKelvin: NotSupported<int>(reason: reason),
      focusDistance: NotSupported<double>(reason: reason),
      exposureCompensation: NotSupported<double>(reason: reason),
      zoom: NotSupported<double>(reason: reason),
      supportedMeteringModes: const <MeteringMode>[],
      supportedFocusModes: const <FocusMode>[],
      supportedPhotoFormats: const <ImageFormat>[],
      supportedVideoResolutions: const <VideoResolution>[],
      supportedFrameRates: const <int>[],
      supportedVideoCodecs: const <VideoCodec>[],
      supportsRawCapture: false,
      supportsProRaw: false,
      supportsBurstMode: false,
      supportsHdr: false,
      supportsBracketing: false,
      supportsDepthCapture: false,
      supportsLidar: false,
      supportsMultiCamera: false,
      supportsFaceDetection: false,
      supportsSlowMotion: false,
      hasFlash: false,
      hasTorch: false,
      hasOis: false,
      platformName: platformName,
      deviceName: deviceName,
      hardwareLevel: hardwareLevel,
    );
  }

  /// Manual shutter speed range.
  final Capability<Duration> shutterSpeed;

  /// Manual ISO range.
  final Capability<int> iso;

  /// Aperture (f-stop) range, where the lens supports it.
  final Capability<double> aperture;

  /// White balance temperature range in Kelvin.
  final Capability<int> whiteBalanceKelvin;

  /// Manual focus distance range in diopters.
  final Capability<double> focusDistance;

  /// Exposure compensation range in EV.
  final Capability<double> exposureCompensation;

  /// Zoom factor range.
  final Capability<double> zoom;

  final List<MeteringMode> supportedMeteringModes;
  final List<FocusMode> supportedFocusModes;
  final List<ImageFormat> supportedPhotoFormats;
  final List<VideoResolution> supportedVideoResolutions;
  final List<int> supportedFrameRates;
  final List<VideoCodec> supportedVideoCodecs;

  final bool supportsRawCapture;
  final bool supportsProRaw;
  final bool supportsBurstMode;
  final bool supportsHdr;
  final bool supportsBracketing;
  final bool supportsDepthCapture;
  final bool supportsLidar;
  final bool supportsMultiCamera;
  final bool supportsFaceDetection;
  final bool supportsSlowMotion;
  final bool hasFlash;
  final bool hasTorch;
  final bool hasOis;

  /// e.g. "Android 14, Camera2 FULL".
  final String platformName;

  /// e.g. "Pixel 8 Pro".
  final String deviceName;

  /// Android Camera2 hardware level (0=LEGACY..3=LEVEL_3), or -1 if N/A.
  final int hardwareLevel;

  @override
  String toString() =>
      'CameraCapabilities($deviceName / $platformName, iso: $iso, '
      'shutter: $shutterSpeed)';
}
