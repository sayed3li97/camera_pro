// Shared test fixtures.
import 'dart:typed_data';

import 'package:camera_pro/camera_pro.dart';

/// A capability passport for a high-end device (full manual controls).
CameraCapabilities fullCapabilities() => CameraCapabilities(
      shutterSpeed: const Supported<Duration>(
        currentValue: Duration(microseconds: 2000),
        minValue: Duration(microseconds: 125),
        maxValue: Duration(seconds: 30),
      ),
      iso: const Supported<int>(currentValue: 100, minValue: 50, maxValue: 12800),
      aperture: const Supported<double>(
        currentValue: 1.8,
        minValue: 1.8,
        maxValue: 16.0,
      ),
      whiteBalanceKelvin: const Supported<int>(
        currentValue: 5600,
        minValue: 2500,
        maxValue: 10000,
      ),
      focusDistance: const Supported<double>(
        currentValue: 1.0,
        minValue: 0.0,
        maxValue: 10.0,
      ),
      exposureCompensation: const Supported<double>(
        currentValue: 0.0,
        minValue: -3.0,
        maxValue: 3.0,
        stepSize: 0.333,
      ),
      zoom: const Supported<double>(
        currentValue: 1.0,
        minValue: 0.5,
        maxValue: 15.0,
      ),
      supportedMeteringModes: MeteringMode.values,
      supportedFocusModes: FocusMode.values,
      supportedPhotoFormats: const <ImageFormat>[
        ImageFormat.jpeg,
        ImageFormat.heif,
        ImageFormat.raw,
        ImageFormat.rawPlusJpeg,
      ],
      supportedVideoResolutions: const <VideoResolution>[
        VideoResolution.hd720p,
        VideoResolution.fhd1080p,
        VideoResolution.uhd4k,
      ],
      supportedFrameRates: const <int>[24, 30, 60, 120, 240],
      supportedVideoCodecs: const <VideoCodec>[VideoCodec.h264, VideoCodec.hevc],
      supportsRawCapture: true,
      supportsProRaw: true,
      supportsBurstMode: true,
      supportsHdr: true,
      supportsBracketing: true,
      supportsDepthCapture: true,
      supportsLidar: true,
      supportsMultiCamera: true,
      supportsFaceDetection: true,
      supportsSlowMotion: true,
      hasFlash: true,
      hasTorch: true,
      hasOis: true,
      platformName: 'iOS 18, AVFoundation',
      deviceName: 'iPhone 16 Pro',
      hardwareLevel: 3,
    );

/// A capability passport for a device with only exposure compensation
/// (standard tier).
CameraCapabilities standardCapabilities() => CameraCapabilities(
      shutterSpeed: const NotSupported<Duration>(reason: 'Camera2 LIMITED'),
      iso: const NotSupported<int>(reason: 'Camera2 LIMITED'),
      aperture: const NotSupported<double>(reason: 'Fixed aperture'),
      whiteBalanceKelvin: const NotSupported<int>(reason: 'Camera2 LIMITED'),
      focusDistance: const NotSupported<double>(reason: 'No manual focus'),
      exposureCompensation: const Supported<double>(
        currentValue: 0.0,
        minValue: -2.0,
        maxValue: 2.0,
      ),
      zoom: const Supported<double>(
        currentValue: 1.0,
        minValue: 1.0,
        maxValue: 8.0,
      ),
      supportedMeteringModes: const <MeteringMode>[MeteringMode.matrix],
      supportedFocusModes: const <FocusMode>[FocusMode.autoContinuous],
      supportedPhotoFormats: const <ImageFormat>[ImageFormat.jpeg],
      supportedVideoResolutions: const <VideoResolution>[
        VideoResolution.fhd1080p,
      ],
      supportedFrameRates: const <int>[30],
      supportedVideoCodecs: const <VideoCodec>[VideoCodec.h264],
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
      hasFlash: true,
      hasTorch: false,
      hasOis: false,
      platformName: 'Android 12, Camera2 LIMITED',
      deviceName: 'Budget Phone',
      hardwareLevel: 1,
    );

/// A [CameraBackend] that records applied settings and never touches native
/// code, for testing the controller's capability-guard logic.
class RecordingBackend implements CameraBackend {
  final List<String> calls = <String>[];

  /// The frame [latestFrame] returns; tests set it to exercise capture paths.
  PreviewFrame? frame;

  /// If non-empty, [latestFrame] dequeues from here first (lets a test feed a
  /// changing sequence of frames, e.g. a mid-bracket resolution change).
  final List<PreviewFrame> frameQueue = <PreviewFrame>[];

  @override
  Future<CameraList> enumerateDevices() async => const CameraList(<CameraDevice>[
        CameraDevice(index: 0, name: 'fake', direction: LensDirection.back),
      ]);

  @override
  Future<int?> open(CameraDevice device) async => 42;

  @override
  Future<CameraCapabilities> getCapabilities() async => fullCapabilities();

  @override
  Future<void> startPreview() async => calls.add('startPreview');

  @override
  Future<void> stopPreview() async => calls.add('stopPreview');

  @override
  Future<void> startFrameStream() async => calls.add('startFrameStream');

  @override
  Future<void> stopFrameStream() async => calls.add('stopFrameStream');

  @override
  PreviewFrame? latestFrame() =>
      frameQueue.isNotEmpty ? frameQueue.removeAt(0) : frame;

  @override
  int get frameCount => 0;

  @override
  Future<void> setExposureMode(ExposureMode mode) async =>
      calls.add('exposureMode:$mode');

  @override
  Future<void> setShutterSpeed(ShutterSpeed value) async =>
      calls.add('shutter:${value.label}');

  @override
  Future<void> setIso(Iso iso) async => calls.add('iso:${iso.value}');

  @override
  Future<void> setExposureCompensation(Ev ev) async => calls.add('ev:${ev.stops}');

  @override
  Future<void> setFocusMode(FocusMode mode) async => calls.add('focusMode:$mode');

  @override
  Future<void> setFocusDistance(double diopters) async =>
      calls.add('focus:$diopters');

  @override
  Future<void> setWhiteBalance(WhiteBalance wb) async => calls.add('wb:$wb');

  @override
  Future<void> setZoom(double factor) async => calls.add('zoom:$factor');

  @override
  Future<void> setFlashMode(FlashMode mode) async => calls.add('flash:$mode');

  @override
  Future<void> setTorch({required bool enabled, double intensity = 1.0}) async =>
      calls.add('torch:$enabled');

  @override
  Future<CapturedPhoto> capturePhoto({ImageFormat? format}) async {
    calls.add('capture:$format');
    return CapturedPhoto(
      width: 4032,
      height: 3024,
      format: format ?? ImageFormat.jpeg,
      timestamp: DateTime(2026),
      path: '/tmp/photo.jpg',
    );
  }

  @override
  Future<CapturedPhoto> renderHdr(
    Uint8List frame, {
    required int width,
    required int height,
    required List<double> stops,
    bool isBgra = true,
  }) async {
    calls.add('hdr:${stops.length}:${width}x$height');
    return CapturedPhoto(
      width: width,
      height: height,
      format: ImageFormat.png,
      timestamp: DateTime(2026),
      bytes: frame,
      path: '/tmp/hdr.png',
    );
  }

  @override
  Future<void> startVideoRecording(String path) async =>
      calls.add('startRecording:$path');

  @override
  Future<VideoResult> stopVideoRecording() async {
    calls.add('stopRecording');
    return const VideoResult(
      path: '/tmp/video.mp4',
      duration: Duration(seconds: 10),
      codec: VideoCodec.hevc,
      resolution: VideoResolution.uhd4k,
    );
  }

  @override
  Future<void> close() async => calls.add('close');
}
