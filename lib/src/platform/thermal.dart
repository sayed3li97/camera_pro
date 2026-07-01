/// Cross-platform thermal state model.
///
/// Mirrors the thermal levels reported by AVFoundation's `systemPressureState`,
/// Android's `PowerManager.getThermalHeadroom`, and desktop equivalents. The
/// controller throttles preview/processing as the level rises (see
/// [ThermalPolicy]).
library;

import 'package:meta/meta.dart';

/// Device thermal severity, ordered from coolest to hottest.
enum ThermalLevel {
  /// Normal operating temperature. Full quality.
  nominal,

  /// Slight pressure. Consider disabling the most expensive features (HDR).
  fair,

  /// Serious pressure. Reduce frame rate and resolution.
  serious,

  /// Critical pressure. Drop to the minimum viable configuration.
  critical,

  /// The system is about to terminate the capture session.
  shutdown;

  /// Whether the app should proactively reduce load at this level.
  bool get requiresThrottling => index >= ThermalLevel.serious.index;
}

/// A snapshot of the device thermal state plus the actions the SDK took.
@immutable
class ThermalStatus {
  const ThermalStatus({
    required this.level,
    this.throttledFrameRate,
    this.throttledResolutionHeight,
    this.disabledFeatures = const <String>[],
  });

  /// Current thermal severity.
  final ThermalLevel level;

  /// Frame rate the SDK clamped to, or null if unchanged.
  final int? throttledFrameRate;

  /// Preview height the SDK clamped to, or null if unchanged.
  final int? throttledResolutionHeight;

  /// Human-readable list of features disabled to shed heat.
  final List<String> disabledFeatures;

  @override
  String toString() =>
      'ThermalStatus(level: ${level.name}, fps: $throttledFrameRate, '
      'height: $throttledResolutionHeight, disabled: $disabledFeatures)';
}

/// Maps a thermal level to a recommended degradation policy. Pure function so
/// it can be unit-tested without a device.
class ThermalPolicy {
  const ThermalPolicy._();

  /// Returns the [ThermalStatus] the SDK would apply for [level].
  static ThermalStatus policyFor(ThermalLevel level) {
    switch (level) {
      case ThermalLevel.nominal:
        return const ThermalStatus(level: ThermalLevel.nominal);
      case ThermalLevel.fair:
        return const ThermalStatus(
          level: ThermalLevel.fair,
          disabledFeatures: <String>['hdr'],
        );
      case ThermalLevel.serious:
        return const ThermalStatus(
          level: ThermalLevel.serious,
          throttledFrameRate: 30,
          throttledResolutionHeight: 1080,
          disabledFeatures: <String>['hdr'],
        );
      case ThermalLevel.critical:
        return const ThermalStatus(
          level: ThermalLevel.critical,
          throttledFrameRate: 24,
          throttledResolutionHeight: 720,
          disabledFeatures: <String>['hdr', 'focusPeaking', 'zebra', 'histogram'],
        );
      case ThermalLevel.shutdown:
        return const ThermalStatus(
          level: ThermalLevel.shutdown,
          throttledFrameRate: 24,
          throttledResolutionHeight: 720,
          disabledFeatures: <String>[
            'hdr', 'focusPeaking', 'zebra', 'histogram', 'recording',
          ],
        );
    }
  }
}
