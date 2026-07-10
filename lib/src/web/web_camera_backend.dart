/// Web [CameraBackend] backed by the browser's MediaDevices / getUserMedia.
///
/// Live preview frames are pulled by drawing the `<video>` element to an
/// offscreen `<canvas>` and reading back RGBA pixels, so the same Dart preview
/// + visual-aid pipeline used on native works unchanged on web.
///
/// Manual controls: browsers expose almost no sensor controls through
/// `MediaStreamTrack`, so — exactly like the macOS built-in camera — ISO,
/// shutter, exposure, white balance, focus, and zoom are applied by a **digital
/// pipeline** in pure Dart (`NativeCore.adjustPixels` / `digitalZoom` /
/// `boxBlur`) on each preview frame. Every control therefore works and is
/// reported `Supported`, so a browser camera reaches `CameraTier.full` too.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../controller/camera_backend.dart';
import '../models/camera_device.dart';
import '../models/capabilities.dart';
import '../models/capture_result.dart';
import '../models/errors.dart';
import '../models/settings.dart';
import 'native_core_web.dart';
import 'web_dng.dart';

/// A [CameraBackend] driven by `navigator.mediaDevices`.
class WebCameraBackend implements CameraBackend {
  web.MediaStream? _stream;
  web.HTMLVideoElement? _video;
  web.HTMLCanvasElement? _canvas;
  web.CanvasRenderingContext2D? _ctx;
  List<CameraDevice> _devices = const <CameraDevice>[];
  int _frameCount = 0;

  // Digital manual-control state (identity = no change), mirroring the macOS
  // fallback pipeline.
  double _gain = 1.0; // digital ISO (ISO 100 == 1.0x)
  double _shutterGain = 1.0; // digital shutter (brightness ∝ exposure time)
  double _bias = 0.0; // exposure/EV, additive
  double _temp = 0.0; // white balance, warm(+)/cool(-)
  double _zoom = 1.0; // digital crop-zoom factor
  int _blurRadius = 0; // digital defocus (manual focus)

  bool get _adjustActive =>
      _gain != 1.0 ||
      _shutterGain != 1.0 ||
      _bias != 0.0 ||
      _temp != 0.0 ||
      _zoom > 1.001 ||
      _blurRadius > 0;

  // Video recording (MediaRecorder).
  web.MediaRecorder? _recorder;
  final List<web.Blob> _chunks = <web.Blob>[];
  DateTime? _recStart;
  Completer<void>? _recDone;
  String _recMime = '';

  web.MediaStreamTrack? get _track {
    final tracks = _stream?.getVideoTracks().toDart;
    return (tracks == null || tracks.isEmpty) ? null : tracks.first;
  }

  /// The best MediaRecorder MIME type this browser supports, or '' if none.
  String get _videoMime {
    for (final m in const <String>[
      'video/mp4;codecs=avc1',
      'video/webm;codecs=vp9',
      'video/webm;codecs=vp8',
      'video/webm',
    ]) {
      if (web.MediaRecorder.isTypeSupported(m)) return m;
    }
    return '';
  }

  VideoCodec _codecFor(String mime) {
    if (mime.contains('avc1') || mime.contains('mp4')) return VideoCodec.h264;
    if (mime.contains('vp8')) return VideoCodec.vp8;
    return VideoCodec.vp9;
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
    var deviceName = 'Web camera';
    var hasTorch = false;
    if (track != null) {
      deviceName = track.label.isEmpty ? 'Web camera' : track.label;
      // A real hardware torch is only exposed on some (mobile) devices.
      final capsObj = track.getCapabilities() as JSObject;
      hasTorch = capsObj.has('torch');
    }
    // Every manual control is applied by the digital pipeline (see class doc),
    // so all are Supported — identical ranges to the macOS digital fallback.
    return CameraCapabilities(
      iso: const Supported<int>(currentValue: 100, minValue: 50, maxValue: 1600),
      shutterSpeed: const Supported<Duration>(
        currentValue: Duration(microseconds: 16667), // ~1/60s
        minValue: Duration(microseconds: 1000), // 1/1000s
        maxValue: Duration(microseconds: 250000), // 1/4s
      ),
      exposureCompensation: const Supported<double>(
          currentValue: 0.0, minValue: -3.0, maxValue: 3.0),
      whiteBalanceKelvin: const Supported<int>(
          currentValue: 5500, minValue: 2500, maxValue: 10000),
      focusDistance: const Supported<double>(
          currentValue: 0.5, minValue: 0.0, maxValue: 1.0),
      zoom: const Supported<double>(
          currentValue: 1.0, minValue: 1.0, maxValue: 4.0),
      aperture: const NotSupported<double>(
          reason: 'Fixed-aperture lens — no diaphragm to control'),
      supportedMeteringModes: const <MeteringMode>[MeteringMode.matrix],
      supportedFocusModes: const <FocusMode>[
        FocusMode.autoContinuous,
        FocusMode.manual,
      ],
      // Only PNG (in-memory RGBA) and RAW (linear-DNG bytes). rawPlusJpeg is
      // not offered on web: it implies two file paths, and the browser has no
      // filesystem to write a JPEG companion to.
      supportedPhotoFormats: const <ImageFormat>[
        ImageFormat.png,
        ImageFormat.raw,
      ],
      // Video recording is only advertised when MediaRecorder can actually
      // encode it in this browser.
      supportedVideoResolutions: _videoMime.isEmpty
          ? const <VideoResolution>[]
          : const <VideoResolution>[VideoResolution.hd720p],
      supportedFrameRates: _videoMime.isEmpty ? const <int>[] : const <int>[30],
      supportedVideoCodecs: _videoMime.isEmpty
          ? const <VideoCodec>[]
          : <VideoCodec>[_codecFor(_videoMime)],
      supportsRawCapture: true, // pure-Dart linear-DNG writer
      supportsProRaw: false,
      supportsBurstMode: true, // controller-level, works everywhere
      supportsHdr: true, // controller-level captureHdr (fusion), works everywhere
      supportsBracketing: true, // controller-level, works everywhere
      supportsDepthCapture: false,
      supportsLidar: false,
      supportsMultiCamera: _devices.length > 1,
      supportsFaceDetection: false,
      supportsSlowMotion: false,
      hasFlash: false,
      hasTorch: hasTorch,
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
    return PreviewFrame(
        bytes: _applyDigital(bytes, w, h), width: w, height: h, isBgra: false);
  }

  /// Applies the digital manual-control pipeline to an RGBA frame. Returns the
  /// input unchanged when all controls are at identity.
  Uint8List _applyDigital(Uint8List src, int w, int h) {
    if (!_adjustActive) return src;
    // digitalZoom returns a fresh buffer; otherwise copy so we never mutate the
    // ImageData view in place.
    final px = _zoom > 1.001
        ? NativeCore.digitalZoom(src, width: w, height: h, factor: _zoom)
        : Uint8List.fromList(src);
    NativeCore.adjustPixels(px,
        width: w,
        height: h,
        isBgra: false,
        gain: _gain * _shutterGain,
        bias: _bias,
        temp: _temp);
    if (_blurRadius > 0) {
      NativeCore.boxBlur(px, width: w, height: h, radius: _blurRadius);
    }
    return px;
  }

  @override
  Future<void> setExposureMode(ExposureMode mode) async {
    // Applied implicitly by the digital shutter/ISO setters.
  }

  @override
  Future<void> setShutterSpeed(ShutterSpeed value) async {
    // Digital shutter: brightness scales with exposure time relative to 1/60s.
    const referenceUs = 16667.0;
    _shutterGain =
        (value.duration.inMicroseconds / referenceUs).clamp(0.25, 4.0);
  }

  @override
  Future<void> setIso(Iso iso) async => _gain = iso.value / 100.0;

  @override
  Future<void> setExposureCompensation(Ev ev) async => _bias = ev.stops * 40.0;

  @override
  Future<void> setFocusMode(FocusMode mode) async {}

  @override
  Future<void> setFocusDistance(double diopters) async {
    // Digital "rack focus": sharpest at 0.5, defocus (blur) toward either end.
    final off = (diopters.clamp(0.0, 1.0) - 0.5).abs() * 2.0;
    _blurRadius = (off * 12).round();
  }

  @override
  Future<void> setWhiteBalance(WhiteBalance wb) async {
    final kelvin = wb.kelvin;
    if (kelvin == null) return;
    _temp = ((5500 - kelvin) / 5000.0).clamp(-1.0, 1.0);
  }

  @override
  Future<void> setZoom(double factor) async =>
      _zoom = factor < 1.0 ? 1.0 : factor;

  @override
  Future<void> setFlashMode(FlashMode mode) async {
    throw const CameraFeatureNotSupportedError(
      feature: 'Flash',
      platformReason: 'No flash hardware on this camera',
    );
  }

  @override
  Future<void> setTorch({required bool enabled, double intensity = 1.0}) async {
    // Real torch only where the device exposes it (some mobile browsers).
    final track = _track;
    if (track == null || !(track.getCapabilities() as JSObject).has('torch')) {
      throw const CameraFeatureNotSupportedError(
        feature: 'Torch',
        platformReason: 'No torch hardware on this camera',
      );
    }
    final set = web.MediaTrackConstraintSet();
    (set as JSObject).setProperty('torch'.toJS, enabled.toJS);
    await track
        .applyConstraints(web.MediaTrackConstraints(
            advanced: <web.MediaTrackConstraintSet>[set].toJS))
        .toDart;
  }

  @override
  Future<CapturedPhoto> capturePhoto({ImageFormat? format}) async {
    final frame = latestFrame();
    if (frame == null) {
      throw CameraCaptureError(reason: CaptureFailureReason.noFrame);
    }
    final ts = DateTime.now();
    final fmt = format ?? ImageFormat.png;
    if (fmt == ImageFormat.raw) {
      // Encode a real linear-DNG in pure Dart (web can't write files, so the
      // bytes are returned in memory for the caller to download/save).
      String two(int v) => v.toString().padLeft(2, '0');
      final exifTime = '${ts.year}:${two(ts.month)}:${two(ts.day)} '
          '${two(ts.hour)}:${two(ts.minute)}:${two(ts.second)}';
      final dng = encodeLinearDng(
        rgba: frame.bytes,
        width: frame.width,
        height: frame.height,
        iso: (_gain * 100).round(),
        exposureNs: (_shutterGain * 16666667).round(),
        make: 'camera_pro',
        model: 'Web, MediaDevices',
        datetime: exifTime,
      );
      return CapturedPhoto(
        width: frame.width,
        height: frame.height,
        format: fmt,
        timestamp: ts,
        bytes: dng,
        exif: ExifData(
          iso: (_gain * 100).round(),
          exposureTime: Duration(microseconds: (_shutterGain * 16667).round()),
          dateTimeOriginal: ts,
        ),
      );
    }
    // PNG path: return the in-memory RGBA frame (the sample app decodes it via
    // decodeImageFromPixels; a production app would encode via canvas.toBlob).
    return CapturedPhoto(
      width: frame.width,
      height: frame.height,
      format: ImageFormat.png,
      timestamp: ts,
      bytes: frame.bytes,
    );
  }

  @override
  Future<CapturedPhoto> fuseExposures(
    List<Uint8List> frames, {
    required int width,
    required int height,
    bool isBgra = false,
  }) async {
    final fused = NativeCore.exposureFusion(frames,
        width: width, height: height, isBgra: isBgra);
    // Web can't write files; return the fused RGBA in memory (the sample app
    // decodes it via decodeImageFromPixels, same as capturePhoto).
    return CapturedPhoto(
      width: width,
      height: height,
      format: ImageFormat.png,
      timestamp: DateTime.now(),
      bytes: fused,
    );
  }

  @override
  Future<void> startVideoRecording(String path) async {
    final stream = _stream;
    final mime = _videoMime;
    if (stream == null || mime.isEmpty) {
      throw const CameraFeatureNotSupportedError(
        feature: 'Video recording',
        platformReason: 'MediaRecorder is unavailable in this browser',
      );
    }
    _chunks.clear();
    _recMime = mime;
    _recDone = Completer<void>();
    final rec = web.MediaRecorder(
        stream, web.MediaRecorderOptions(mimeType: mime));
    rec.addEventListener(
        'dataavailable',
        (web.Event e) {
          final data = (e as web.BlobEvent).data;
          if (data.size > 0) _chunks.add(data);
        }.toJS);
    rec.addEventListener('stop', ((web.Event e) {
      if (!(_recDone?.isCompleted ?? true)) _recDone?.complete();
    }).toJS);
    rec.start();
    _recorder = rec;
    _recStart = DateTime.now();
  }

  @override
  Future<VideoResult> stopVideoRecording() async {
    final rec = _recorder;
    final start = _recStart;
    if (rec == null || start == null) {
      throw CameraCaptureError(reason: CaptureFailureReason.interrupted);
    }
    rec.stop();
    await _recDone?.future; // wait for the final chunk + stop event
    _recorder = null;
    _recStart = null;

    final blob = web.Blob(
      _chunks.map((b) => b as JSAny).toList().toJS,
      web.BlobPropertyBag(type: _recMime),
    );
    final url = web.URL.createObjectURL(blob);
    final w = _video?.videoWidth ?? 1280;
    final h = _video?.videoHeight ?? 720;
    return VideoResult(
      path: url, // object URL; a production app would download/upload it
      duration: DateTime.now().difference(start),
      codec: _codecFor(_recMime),
      resolution: VideoResolution(w, h),
      fileSizeBytes: blob.size,
    );
  }

  @override
  Future<void> close() async {
    if (_recorder?.state == 'recording') _recorder?.stop();
    _recorder = null;
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
