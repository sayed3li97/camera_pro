/// Camera device descriptors and enumeration helpers.
library;

import 'package:meta/meta.dart';

/// Which way a camera faces.
enum LensDirection { front, back, external, unknown }

/// A rough optical classification for multi-lens devices.
enum LensType { wide, ultraWide, telephoto, trueDepth, lidar, unknown }

/// A single physical or logical camera on the device.
@immutable
class CameraDevice {
  const CameraDevice({
    required this.index,
    required this.name,
    required this.direction,
    this.lensType = LensType.unknown,
    this.focalLengthMm,
    this.isLogicalMultiCamera = false,
  });

  /// Native device index passed to `camera_hal_open`.
  final int index;

  /// Human-readable device name.
  final String name;

  /// Which way the lens faces.
  final LensDirection direction;

  /// Optical classification.
  final LensType lensType;

  /// 35mm-equivalent focal length, if known.
  final double? focalLengthMm;

  /// Whether this is a logical camera fusing several physical lenses.
  final bool isLogicalMultiCamera;

  @override
  String toString() =>
      'CameraDevice(#$index, $name, ${direction.name}/${lensType.name})';
}

/// The set of cameras available on the device, with convenience accessors.
@immutable
class CameraList {
  const CameraList(this.devices);

  /// All enumerated cameras.
  final List<CameraDevice> devices;

  /// The rear-facing cameras.
  List<CameraDevice> get rear =>
      devices.where((d) => d.direction == LensDirection.back).toList();

  /// The front-facing cameras.
  List<CameraDevice> get front =>
      devices.where((d) => d.direction == LensDirection.front).toList();

  /// The default rear wide camera, falling back to the first device.
  CameraDevice? get defaultCamera {
    final backWide = devices.where(
      (d) => d.direction == LensDirection.back && d.lensType == LensType.wide,
    );
    if (backWide.isNotEmpty) return backWide.first;
    return devices.isEmpty ? null : devices.first;
  }

  /// Whether any camera was found.
  bool get isEmpty => devices.isEmpty;
}
