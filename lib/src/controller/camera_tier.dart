/// Three-tier graceful degradation based on device capabilities.
library;

import '../models/capabilities.dart';

/// The control tier the SDK offers for a given device.
enum CameraTier {
  /// Full DSLR controls: manual shutter, ISO, WB, focus, RAW, GPU overlays.
  full,

  /// Auto exposure with EV offset, tap-to-focus, JPEG.
  standard,

  /// Preview and capture only.
  basic;

  /// Short description for UI.
  String get label => switch (this) {
        CameraTier.full => 'Full manual (DSLR)',
        CameraTier.standard => 'Standard (auto + EV)',
        CameraTier.basic => 'Basic (preview + capture)',
      };
}

/// Selects the [CameraTier] for a capability passport.
///
/// Pure function — unit-tested without a device.
CameraTier determineTier(CameraCapabilities caps) {
  if (caps.shutterSpeed.isSupported &&
      caps.iso.isSupported &&
      caps.focusDistance.isSupported &&
      caps.whiteBalanceKelvin.isSupported) {
    return CameraTier.full;
  }
  if (caps.exposureCompensation.isSupported) {
    return CameraTier.standard;
  }
  return CameraTier.basic;
}
