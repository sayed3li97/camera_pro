/// Dart mirror of the native Android device-quirks database.
///
/// The authoritative list lives in the native layer so the HAL can apply
/// work-arounds without a round-trip; this mirror lets the Dart UI explain a
/// quirk to the user or pre-emptively disable an affected control.
library;

/// A known device-specific work-around flag.
enum DeviceQuirk {
  /// White balance is ignored while recording video.
  wbIgnoredInVideo,

  /// RAW frames come back with a color shift that needs correction.
  rawColorShift,

  /// Setting manual exposure also resets focus.
  manualExposureResetsFocus,

  /// Auto-focus lock is slow on this device.
  slowAfLock,

  /// Burst mode is capped at 10 frames.
  burstLimit10,

  /// Torch can't be used while recording.
  noTorchDuringRecording,

  /// Electronic image stabilization crops the preview.
  eisCropsPreview,
}

/// A quirk table entry: a manufacturer + model prefix mapped to flags.
class DeviceQuirkEntry {
  const DeviceQuirkEntry({
    required this.manufacturer,
    required this.modelPrefix,
    required this.quirks,
  });

  final String manufacturer;
  final String modelPrefix;
  final Set<DeviceQuirk> quirks;
}

/// The known-quirks table, mirrored from `device_quirks` in the native layer.
const List<DeviceQuirkEntry> kDeviceQuirks = <DeviceQuirkEntry>[
  DeviceQuirkEntry(
    manufacturer: 'samsung',
    modelPrefix: 'SM-G99',
    quirks: <DeviceQuirk>{
      DeviceQuirk.wbIgnoredInVideo,
      DeviceQuirk.rawColorShift,
    },
  ),
  DeviceQuirkEntry(
    manufacturer: 'xiaomi',
    modelPrefix: '23053',
    quirks: <DeviceQuirk>{DeviceQuirk.manualExposureResetsFocus},
  ),
  DeviceQuirkEntry(
    manufacturer: 'oneplus',
    modelPrefix: 'IN202',
    quirks: <DeviceQuirk>{DeviceQuirk.noTorchDuringRecording},
  ),
  DeviceQuirkEntry(
    manufacturer: 'huawei',
    modelPrefix: 'ELS-',
    quirks: <DeviceQuirk>{DeviceQuirk.burstLimit10},
  ),
  // Community-reported (flutter/flutter camera plugin issue tracker):
  // EIS crop offsets tap-to-focus coordinates on Pixel 6/7 family.
  DeviceQuirkEntry(
    manufacturer: 'google',
    modelPrefix: 'Pixel 6',
    quirks: <DeviceQuirk>{DeviceQuirk.eisCropsPreview},
  ),
  DeviceQuirkEntry(
    manufacturer: 'google',
    modelPrefix: 'Pixel 7',
    quirks: <DeviceQuirk>{DeviceQuirk.eisCropsPreview},
  ),
  // Samsung A-series (LIMITED hardware level): slow AF convergence widely
  // reported; manual exposure kicks the AF trigger on some builds.
  DeviceQuirkEntry(
    manufacturer: 'samsung',
    modelPrefix: 'SM-A5',
    quirks: <DeviceQuirk>{
      DeviceQuirk.slowAfLock,
      DeviceQuirk.manualExposureResetsFocus,
    },
  ),
  DeviceQuirkEntry(
    manufacturer: 'xiaomi',
    modelPrefix: '2201',
    quirks: <DeviceQuirk>{DeviceQuirk.wbIgnoredInVideo},
  ),
];

/// Returns the quirks for a device, matching manufacturer (case-insensitive)
/// and model prefix. Empty when no known quirks apply.
Set<DeviceQuirk> quirksFor(String manufacturer, String model) {
  final mfr = manufacturer.toLowerCase();
  for (final entry in kDeviceQuirks) {
    if (entry.manufacturer.toLowerCase() == mfr &&
        model.startsWith(entry.modelPrefix)) {
      return entry.quirks;
    }
  }
  return const <DeviceQuirk>{};
}
