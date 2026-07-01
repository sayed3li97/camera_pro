/// Results returned by photo and video capture.
library;

import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'settings.dart';

/// EXIF metadata read from or written to a captured image.
@immutable
class ExifData {
  const ExifData({
    this.iso,
    this.exposureTime,
    this.fNumber,
    this.focalLength,
    this.artist,
    this.copyright,
    this.dateTimeOriginal,
    this.latitude,
    this.longitude,
  });

  final int? iso;
  final Duration? exposureTime;
  final double? fNumber;
  final double? focalLength;
  final String? artist;
  final String? copyright;
  final DateTime? dateTimeOriginal;
  final double? latitude;
  final double? longitude;
}

/// A per-pixel depth map paired with a photo (portrait / LiDAR).
@immutable
class DepthData {
  const DepthData({
    required this.width,
    required this.height,
    required this.distances,
  });

  final int width;
  final int height;

  /// Row-major distances in metres.
  final Float32List distances;
}

/// A captured still image.
///
/// In the full FFI pipeline the pixel bytes are a zero-copy view into a native
/// buffer freed by a `NativeFinalizer`. In the foundation build the model holds
/// an optional [bytes] view and/or a file [path].
@immutable
class CapturedPhoto {
  const CapturedPhoto({
    required this.width,
    required this.height,
    required this.format,
    required this.timestamp,
    this.bytes,
    this.path,
    this.rawPath,
    this.jpegPath,
    this.exif,
    this.depthMap,
  });

  final int width;
  final int height;
  final ImageFormat format;
  final DateTime timestamp;

  /// In-memory pixel/encoded bytes, when the capture was kept in memory.
  final Uint8List? bytes;

  /// Primary on-disk path, when saved.
  final String? path;

  /// RAW/DNG path for `rawPlusJpeg` captures.
  final String? rawPath;

  /// JPEG path for `rawPlusJpeg` captures.
  final String? jpegPath;

  /// EXIF metadata, if parsed.
  final ExifData? exif;

  /// Depth map, if captured.
  final DepthData? depthMap;

  @override
  String toString() =>
      'CapturedPhoto(${width}x$height, ${format.name}, path: $path)';
}

/// A single frame produced during a burst.
@immutable
class BurstFrame {
  const BurstFrame({required this.index, required this.path});

  final int index;
  final String path;
}

/// The result of a finished video recording.
@immutable
class VideoResult {
  const VideoResult({
    required this.path,
    required this.duration,
    required this.codec,
    required this.resolution,
    this.fileSizeBytes,
  });

  final String path;
  final Duration duration;
  final VideoCodec codec;
  final VideoResolution resolution;
  final int? fileSizeBytes;

  @override
  String toString() =>
      'VideoResult($path, ${duration.inSeconds}s, ${codec.name}, $resolution)';
}
