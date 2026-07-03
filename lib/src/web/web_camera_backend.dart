/// Web [CameraBackend] backed by the browser's MediaDevices / getUserMedia.
///
/// Live preview frames are pulled by drawing the `<video>` element to an
/// offscreen `<canvas>` and reading back RGBA pixels, so the same Dart preview
/// + visual-aid pipeline used on native works unchanged on web. Manual controls
/// map to `MediaStreamTrack.applyConstraints`, which most webcams don't expose
/// (reported honestly as NotSupported).
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import '../controller/camera_backend.dart';
import '../models/camera_device.dart';
import '../models/capabilities.dart';
import '../models/capture_result.dart';
import '../models/errors.dart';
import '../models/settings.dart';

/// A [CameraBackend] driven by `navigator.mediaDevices`.
class WebCameraBackend implements CameraBackend {
  web.MediaStream? _stream;
  web.HTMLVideoElement? _video;
  web.HTMLCanvasElement? _canvas;
  web.CanvasRenderingContext2D? _ctx;
  List<CameraDevice> _devices = const <CameraDevice>[];
  int _frameCount = 0;

  web.MediaStreamTrack? get _track {
    final tracks = _stream?.getVideoTracks().toDart;
    return (tracks == null || tracks.isEmpty) ? null : tracks.first;
  }

  @override
  Future<CameraList> enumerateDevices() async {
    final md = web.window.navigator.mediaDevices;
    final list = (await md.enumerateDevices().toDart).toDart;
    final devices = <CameraDevice>[];
    var idx = 0;
    for (final d in list) {
      if (d.kind == 'videoinput') {
        devices.add(CameraDevice(
          index: idx++,
          name: d.label.isEmpty ? 'Camera $idx' : d.label,
          direction: LensDirection.unknown,
        ));
      }
    }
    _devices = devices;
    return CameraList(devices);
  }

  @override
  Future<int?> open(CameraDevice device) async {
    if (_devices.isEmpty) await enumerateDevices();
    final md = web.window.navigator.mediaDevices;
    // Request the specific device when we have its id; else any camera.
    final JSAny videoConstraint = device.name.startsWith('Camera')
        ? true.toJS
        : (<String, Object>{
            'width': <String, Object>{'ideal': 640},
            'height': <String, Object>{'ideal': 480},
          }).jsify()!;
    final constraints = web.MediaStreamConstraints(video: videoConstraint);
    _stream = await md.getUserMedia(constraints).toDart;

    final video = web.HTMLVideoElement()
      ..autoplay = true
      ..muted = true
      ..srcObject = _stream;
    // Keep it off-screen but attached so decoding runs.
    video.style.position = 'absolute';
    video.style.width = '1px';
    video.style.height = '1px';
    video.style.opacity = '0';
    web.document.body?.append(video);
    await video.play().toDart;
    _video = video;
    return null; // no Flutter texture id on web
  }

  @override
  Future<CameraCapabilities> getCapabilities() async {
    final track = _track;
    Capability<double> zoom = const NotSupported<double>(reason: 'No zoom control');
    var deviceName = 'Web camera';
    if (track != null) {
      deviceName = track.label.isEmpty ? 'Web camera' : track.label;
      final capsObj = track.getCapabilities() as JSObject;
      if (capsObj.has('zoom')) {
        final z = capsObj.getProperty('zoom'.toJS) as JSObject;
        final min = (z.getProperty('min'.toJS) as JSNumber?)?.toDartDouble ?? 1.0;
        final max = (z.getProperty('max'.toJS) as JSNumber?)?.toDartDouble ?? 1.0;
        if (max > min) {
          zoom = Supported<double>(currentValue: min, minValue: min, maxValue: max);
        }
      }
    }
    const notWeb = 'Not exposed by MediaStreamTrack on this camera';
    return CameraCapabilities(
      iso: const NotSupported<int>(reason: notWeb),
      shutterSpeed: const NotSupported<Duration>(reason: notWeb),
      aperture: const NotSupported<double>(reason: 'Fixed aperture'),
      whiteBalanceKelvin: const NotSupported<int>(reason: notWeb),
      focusDistance: const NotSupported<double>(reason: notWeb),
      exposureCompensation: const NotSupported<double>(reason: notWeb),
      zoom: zoom,
      supportedMeteringModes: const <MeteringMode>[MeteringMode.matrix],
      supportedFocusModes: const <FocusMode>[FocusMode.autoContinuous],
      supportedPhotoFormats: const <ImageFormat>[ImageFormat.png],
      supportedVideoResolutions: const <VideoResolution>[
        VideoResolution.hd720p,
      ],
      supportedFrameRates: const <int>[30],
      supportedVideoCodecs: const <VideoCodec>[VideoCodec.h264],
      supportsRawCapture: false,
      supportsProRaw: false,
      supportsBurstMode: true,
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
      platformName: 'Web, MediaDevices',
      deviceName: deviceName,
      hardwareLevel: -1,
    );
  }

  @override
  Future<void> startPreview() async {}

  @override
  Future<void> stopPreview() async {}

  @override
  Future<void> startFrameStream() async {
    _canvas = web.HTMLCanvasElement();
    _ctx = _canvas!.getContext('2d') as web.CanvasRenderingContext2D?;
  }

  @override
  Future<void> stopFrameStream() async {
    _canvas = null;
    _ctx = null;
  }

  @override
  int get frameCount => _frameCount;

  @override
  PreviewFrame? latestFrame() {
    final video = _video;
    final ctx = _ctx;
    final canvas = _canvas;
    if (video == null || ctx == null || canvas == null) return null;
    final w = video.videoWidth;
    final h = video.videoHeight;
    if (w == 0 || h == 0) return null; // metadata not ready

    if (canvas.width != w || canvas.height != h) {
      canvas.width = w;
      canvas.height = h;
    }
    ctx.drawImage(video, 0, 0);
    final img = ctx.getImageData(0, 0, w, h);
    final bytes = img.data.toDart.buffer.asUint8List();
    _frameCount++;
    return PreviewFrame(bytes: bytes, width: w, height: h, isBgra: false);
  }

  Never _unsupported(String feature) => throw CameraFeatureNotSupportedError(
        feature: feature,
        platformReason: 'Not exposed by this camera via MediaStreamTrack',
      );

  @override
  Future<void> setExposureMode(ExposureMode mode) async => _unsupported('Exposure mode');
  @override
  Future<void> setShutterSpeed(ShutterSpeed value) async => _unsupported('Shutter speed');
  @override
  Future<void> setIso(Iso iso) async => _unsupported('ISO');
  @override
  Future<void> setExposureCompensation(Ev ev) async => _unsupported('Exposure compensation');
  @override
  Future<void> setFocusMode(FocusMode mode) async {}
  @override
  Future<void> setFocusDistance(double diopters) async => _unsupported('Focus distance');
  @override
  Future<void> setWhiteBalance(WhiteBalance wb) async => _unsupported('White balance');

  @override
  Future<void> setZoom(double factor) async {
    final track = _track;
    if (track == null) _unsupported('Zoom');
    final set = web.MediaTrackConstraintSet();
    (set as JSObject).setProperty('zoom'.toJS, factor.toJS);
    final constraints = web.MediaTrackConstraints(
      advanced: <web.MediaTrackConstraintSet>[set].toJS,
    );
    await track.applyConstraints(constraints).toDart;
  }

  @override
  Future<void> setFlashMode(FlashMode mode) async => _unsupported('Flash');
  @override
  Future<void> setTorch({required bool enabled, double intensity = 1.0}) async =>
      _unsupported('Torch');

  @override
  Future<CapturedPhoto> capturePhoto({ImageFormat? format}) async {
    final frame = latestFrame();
    if (frame == null) {
      throw CameraCaptureError(reason: CaptureFailureReason.noFrame);
    }
    // Web can't write arbitrary files; return the RGBA bytes in memory.
    return CapturedPhoto(
      width: frame.width,
      height: frame.height,
      format: ImageFormat.png,
      timestamp: DateTime.now(),
      bytes: frame.bytes,
    );
  }

  @override
  Future<void> startVideoRecording(String path) async {
    throw const CameraFeatureNotSupportedError(
      feature: 'Video recording',
      platformReason: 'MediaRecorder wiring is roadmap on web',
    );
  }

  @override
  Future<VideoResult> stopVideoRecording() async {
    throw const CameraFeatureNotSupportedError(
      feature: 'Video recording',
      platformReason: 'MediaRecorder wiring is roadmap on web',
    );
  }

  @override
  Future<void> close() async {
    final tracks = _stream?.getTracks().toDart;
    if (tracks != null) {
      for (final t in tracks) {
        t.stop();
      }
    }
    _video?.remove();
    _stream = null;
    _video = null;
    _canvas = null;
    _ctx = null;
  }
}
