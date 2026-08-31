/// The main camera controller.
///
/// Wraps a [CameraBackend] with the capability-guard logic that makes the API
/// crash-proof: every manual control validates against the device's
/// [CameraCapabilities] and throws a typed [CameraProError] *before* touching
/// native code, rather than letting the platform fail deep in a callback.
library;

import 'dart:async';

import 'package:meta/meta.dart';

import '../models/camera_device.dart';
import '../models/camera_state.dart';
import '../models/capabilities.dart';
import '../models/capture_result.dart';
import '../models/errors.dart';
import '../models/settings.dart';
import '../models/stream_config.dart';
import '../processing/frame_processor.dart';
import 'camera_backend.dart';
import 'camera_state_machine.dart';
import 'camera_tier.dart';

/// An immutable snapshot of the currently applied manual settings.
@immutable
class CameraSettings {
  const CameraSettings({
    this.exposureMode = ExposureMode.auto,
    this.iso,
    this.shutterSpeed,
    this.exposureCompensation,
    this.focusMode = FocusMode.autoContinuous,
    this.focusDistance,
    this.whiteBalance,
    this.zoom = 1.0,
    this.flashMode = FlashMode.off,
  });

  final ExposureMode exposureMode;
  final Iso? iso;
  final ShutterSpeed? shutterSpeed;
  final Ev? exposureCompensation;
  final FocusMode focusMode;
  final double? focusDistance;
  final WhiteBalance? whiteBalance;
  final double zoom;
  final FlashMode flashMode;

  CameraSettings copyWith({
    ExposureMode? exposureMode,
    Iso? iso,
    ShutterSpeed? shutterSpeed,
    Ev? exposureCompensation,
    FocusMode? focusMode,
    double? focusDistance,
    WhiteBalance? whiteBalance,
    double? zoom,
    FlashMode? flashMode,
  }) {
    return CameraSettings(
      exposureMode: exposureMode ?? this.exposureMode,
      iso: iso ?? this.iso,
      shutterSpeed: shutterSpeed ?? this.shutterSpeed,
      exposureCompensation: exposureCompensation ?? this.exposureCompensation,
      focusMode: focusMode ?? this.focusMode,
      focusDistance: focusDistance ?? this.focusDistance,
      whiteBalance: whiteBalance ?? this.whiteBalance,
      zoom: zoom ?? this.zoom,
      flashMode: flashMode ?? this.flashMode,
    );
  }
}

/// Drives a camera session and enforces capability-safe control.
class CameraProController {
  CameraProController._({
    required CameraBackend backend,
    required CameraCapabilities capabilities,
    CameraStateMachine? stateMachine,
    int? textureId,
  })  : _backend = backend,
        _capabilities = capabilities,
        _tier = determineTier(capabilities),
        _stateMachine = stateMachine ?? CameraStateMachine(),
        _textureId = textureId;

  /// Opens a session against [backend] (defaults to [StubCameraBackend] until a
  /// platform HAL is wired), reads the capability passport, and starts preview.
  static Future<CameraProController> create({
    CameraBackend? backend,
    CameraDevice? device,
  }) async {
    final b = backend ?? StubCameraBackend();
    final target = device ??
        (await b.enumerateDevices()).defaultCamera ??
        const CameraDevice(
          index: 0,
          name: 'default',
          direction: LensDirection.unknown,
        );

    final textureId = await b.open(target);
    final caps = await b.getCapabilities();

    final controller = CameraProController._(
      backend: b,
      capabilities: caps,
      textureId: textureId,
    );
    controller._stateMachine.transition(CameraState.opened);
    await b.startPreview();
    controller._stateMachine.transition(CameraState.previewing);
    return controller;
  }

  /// Builds a controller in the previewing state with injected capabilities,
  /// for unit-testing the capability-guard logic without a device.
  @visibleForTesting
  static CameraProController forTesting({
    required CameraCapabilities capabilities,
    CameraBackend? backend,
  }) {
    final controller = CameraProController._(
      backend: backend ?? StubCameraBackend(),
      capabilities: capabilities,
    );
    controller._stateMachine
      ..transition(CameraState.opened)
      ..transition(CameraState.previewing);
    return controller;
  }

  final CameraBackend _backend;
  final CameraCapabilities _capabilities;
  final CameraTier _tier;
  final CameraStateMachine _stateMachine;
  final int? _textureId;

  CameraSettings _settings = const CameraSettings();

  /// The device capability passport.
  CameraCapabilities get capabilities => _capabilities;

  /// The control tier for this device.
  CameraTier get tier => _tier;

  /// The current lifecycle state.
  CameraState get state => _stateMachine.state;

  /// Stream of lifecycle transitions.
  Stream<CameraStateChange> get stateChanges => _stateMachine.changes;

  /// Flutter texture id for the preview, or null on backends without one.
  int? get textureId => _textureId;

  /// The currently applied manual settings.
  CameraSettings get currentSettings => _settings;

  // ── Live preview frames ─────────────────────────────────────────────────

  /// Starts the live preview frame stream (requests camera permission on
  /// platforms that need it). Frames are then available via [latestPreviewFrame].
  Future<void> startPreviewStream() => _backend.startFrameStream();

  /// Stops the live preview frame stream.
  Future<void> stopPreviewStream() => _backend.stopFrameStream();

  final List<FrameProcessor> _frameProcessors = <FrameProcessor>[];

  /// Attaches a [FrameProcessor]; it receives every subsequently polled frame.
  void addFrameProcessor(FrameProcessor processor) {
    _frameProcessors.add(processor);
    processor.onAttach(_capabilities);
  }

  /// Detaches a previously added processor.
  void removeFrameProcessor(FrameProcessor processor) {
    if (_frameProcessors.remove(processor)) processor.onDetach();
  }

  /// The most recent preview frame, or null if none has arrived yet.
  /// Attached [FrameProcessor]s are invoked with each frame returned here.
  PreviewFrame? latestPreviewFrame() {
    final frame = _backend.latestFrame();
    if (frame != null) {
      for (final p in _frameProcessors) {
        p.onFrame(frame);
      }
    }
    return frame;
  }

  /// Number of preview frames delivered so far.
  int get previewFrameCount => _backend.frameCount;

  // ── Capability-guarded setters ─────────────────────────────────────────

  /// Sets manual ISO. Throws [CameraFeatureNotSupportedError] if the device has
  /// no manual ISO, or [CameraInvalidParameterError] if out of range.
  Future<void> setIso(Iso iso) async {
    final cap = _capabilities.iso;
    switch (cap) {
      case NotSupported<int>(:final reason):
        throw CameraFeatureNotSupportedError(
          feature: 'Manual ISO',
          platformReason: reason,
        );
      case Supported<int>(:final minValue, :final maxValue):
        if (iso.value < minValue || iso.value > maxValue) {
          throw CameraInvalidParameterError(
            message: 'ISO ${iso.value} out of range [$minValue, $maxValue]',
          );
        }
    }
    await _backend.setIso(iso);
    _settings = _settings.copyWith(iso: iso);
  }

  /// Sets manual shutter speed. Guarded by [CameraCapabilities.shutterSpeed].
  Future<void> setShutterSpeed(ShutterSpeed value) async {
    final cap = _capabilities.shutterSpeed;
    switch (cap) {
      case NotSupported<Duration>(:final reason):
        throw CameraFeatureNotSupportedError(
          feature: 'Manual shutter speed',
          platformReason: reason,
        );
      case Supported<Duration>(:final minValue, :final maxValue):
        if (value.duration < minValue || value.duration > maxValue) {
          throw CameraInvalidParameterError(
            message: 'Shutter ${value.label} out of range '
                '[${minValue.inMicroseconds}us, ${maxValue.inMicroseconds}us]',
          );
        }
    }
    await _backend.setShutterSpeed(value);
    _settings = _settings.copyWith(shutterSpeed: value);
  }

  /// Sets exposure compensation. Guarded by
  /// [CameraCapabilities.exposureCompensation].
  Future<void> setExposureCompensation(Ev ev) async {
    final cap = _capabilities.exposureCompensation;
    switch (cap) {
      case NotSupported<double>(:final reason):
        throw CameraFeatureNotSupportedError(
          feature: 'Exposure compensation',
          platformReason: reason,
        );
      case Supported<double>(:final minValue, :final maxValue):
        if (ev.stops < minValue || ev.stops > maxValue) {
          throw CameraInvalidParameterError(
            message: 'EV ${ev.stops} out of range [$minValue, $maxValue]',
          );
        }
    }
    await _backend.setExposureCompensation(ev);
    _settings = _settings.copyWith(exposureCompensation: ev);
  }

  /// Sets a manual white-balance temperature. Guarded by
  /// [CameraCapabilities.whiteBalanceKelvin] when [wb] is manual.
  Future<void> setWhiteBalance(WhiteBalance wb) async {
    if (wb.mode == WhiteBalanceMode.manual) {
      final cap = _capabilities.whiteBalanceKelvin;
      switch (cap) {
        case NotSupported<int>(:final reason):
          throw CameraFeatureNotSupportedError(
            feature: 'Manual white balance',
            platformReason: reason,
          );
        case Supported<int>(:final minValue, :final maxValue):
          final k = wb.kelvin!;
          if (k < minValue || k > maxValue) {
            throw CameraInvalidParameterError(
              message: '${k}K out of range [${minValue}K, ${maxValue}K]',
            );
          }
      }
    }
    await _backend.setWhiteBalance(wb);
    _settings = _settings.copyWith(whiteBalance: wb);
  }

  /// Sets manual focus distance in diopters. Guarded by
  /// [CameraCapabilities.focusDistance].
  Future<void> setFocusDistance(double diopters) async {
    final cap = _capabilities.focusDistance;
    switch (cap) {
      case NotSupported<double>(:final reason):
        throw CameraFeatureNotSupportedError(
          feature: 'Manual focus',
          platformReason: reason,
        );
      case Supported<double>(:final minValue, :final maxValue):
        if (diopters < minValue || diopters > maxValue) {
          throw CameraInvalidParameterError(
            message: 'Focus $diopters out of range [$minValue, $maxValue]',
          );
        }
    }
    await _backend.setFocusDistance(diopters);
    _settings = _settings.copyWith(focusDistance: diopters);
  }

  /// Sets the zoom factor, clamped to the supported range when known.
  Future<void> setZoom(double factor) async {
    final cap = _capabilities.zoom;
    if (cap case Supported<double>(:final minValue, :final maxValue)) {
      if (factor < minValue || factor > maxValue) {
        throw CameraInvalidParameterError(
          message: 'Zoom $factor out of range [$minValue, $maxValue]',
        );
      }
    }
    await _backend.setZoom(factor);
    _settings = _settings.copyWith(zoom: factor);
  }

  /// Sets the flash mode. Throws if the device has no flash.
  Future<void> setFlashMode(FlashMode mode) async {
    if (mode != FlashMode.off && !_capabilities.hasFlash) {
      throw CameraFeatureNotSupportedError(
        feature: 'Flash',
        platformReason: 'No flash unit on this device',
      );
    }
    await _backend.setFlashMode(mode);
    _settings = _settings.copyWith(flashMode: mode);
  }

  // ── Capture ────────────────────────────────────────────────────────────

  /// Captures a still photo. Throws [CameraStateException] if not previewing.
  Future<CapturedPhoto> capturePhoto({ImageFormat? format}) async {
    if (!state.canCapture) {
      throw CameraStateException('Cannot capture in state ${state.name}');
    }
    if (format == ImageFormat.raw && !_capabilities.supportsRawCapture) {
      throw CameraFeatureNotSupportedError(
        feature: 'RAW capture',
        platformReason: 'Device does not expose a RAW stream',
      );
    }
    _stateMachine.transition(CameraState.capturing);
    try {
      return await _backend.capturePhoto(format: format);
    } finally {
      if (_stateMachine.canTransitionTo(CameraState.previewing)) {
        _stateMachine.transition(CameraState.previewing);
      }
    }
  }

  /// Captures [count] photos back-to-back as fast as encoding allows.
  ///
  /// Each frame goes through the normal capture path (all digital
  /// manual-control adjustments applied). Returns the photos in order.
  Future<List<CapturedPhoto>> captureBurst({
    int count = 5,
    ImageFormat? format,
  }) async {
    if (count < 1) {
      throw CameraInvalidParameterError(message: 'Burst count must be >= 1');
    }
    final photos = <CapturedPhoto>[];
    for (var i = 0; i < count; i++) {
      photos.add(await capturePhoto(format: format));
    }
    return photos;
  }

  /// Captures one photo per EV offset in [stops] (e.g. `[-2, 0, 2]`),
  /// restoring the previous exposure compensation afterwards.
  Future<List<CapturedPhoto>> captureExposureBracket({
    required List<double> stops,
    ImageFormat? format,
  }) async {
    if (stops.isEmpty) {
      throw CameraInvalidParameterError(message: 'Bracket needs >= 1 stop');
    }
    final previous = _settings.exposureCompensation ?? const Ev(0);
    final photos = <CapturedPhoto>[];
    try {
      for (final stop in stops) {
        await setExposureCompensation(Ev(stop));
        // Let at least one adjusted frame land before grabbing it.
        await Future<void>.delayed(const Duration(milliseconds: 120));
        photos.add(await capturePhoto(format: format));
      }
    } finally {
      // Best-effort restore; a failure here must not mask a capture error.
      try {
        await setExposureCompensation(previous);
      } on Object {
        // ignore
      }
    }
    return photos;
  }

  /// Captures a single frame and renders one HDR still from it with local tone
  /// mapping: an exposure stack is synthesized from the frame (gain = 2^ev for
  /// each ev in [stops], in linear light) and fused with multi-scale exposure
  /// fusion, lifting shadows and taming highlights while preserving local
  /// contrast. Because it uses one instant, the result is sharp and ghost-free.
  ///
  /// This is the right model for cameras without sensor-level exposure
  /// bracketing (all current backends): a temporal bracket on a hand-held or
  /// moving subject would ghost. Throws [CameraFeatureNotSupportedError] when
  /// the backend can't render HDR.
  Future<CapturedPhoto> captureHdr({
    List<double> stops = const <double>[-3.0, -1.5, 0.0, 1.5, 3.0],
  }) async {
    if (!_capabilities.supportsHdr) {
      throw CameraFeatureNotSupportedError(
        feature: 'HDR fusion',
        platformReason: 'Backend does not support HDR capture',
      );
    }
    if (stops.isEmpty) {
      throw CameraInvalidParameterError(message: 'HDR needs >= 1 EV stop');
    }
    if (!state.canCapture) {
      throw CameraStateException('Cannot capture in state ${state.name}');
    }
    _stateMachine.transition(CameraState.capturing);
    try {
      final frame = _backend.latestFrame();
      if (frame == null) {
        throw CameraCaptureError(reason: CaptureFailureReason.noFrame);
      }
      return await _backend.renderHdr(
        frame.bytes,
        width: frame.width,
        height: frame.height,
        isBgra: frame.isBgra,
        stops: stops,
      );
    } finally {
      if (_stateMachine.canTransitionTo(CameraState.previewing)) {
        _stateMachine.transition(CameraState.previewing);
      }
    }
  }

  /// Starts a live stream. The API is modelled; the native RTMP/SRT client is
  /// roadmap, so this currently throws a typed error rather than pretending.
  Future<void> startStreaming(StreamConfig config) async {
    throw CameraFeatureNotSupportedError(
      feature: 'Live streaming (${config.protocol.name.toUpperCase()})',
      platformReason:
          'Streaming transport (RTMP/SRT client) is not yet implemented',
    );
  }

  // ── Video recording ────────────────────────────────────────────────────

  /// Starts recording video to [path]. Requires an active preview.
  Future<void> startVideoRecording(String path) async {
    if (state != CameraState.previewing) {
      throw CameraStateException('Cannot record in state ${state.name}');
    }
    await _backend.startVideoRecording(path);
    _stateMachine.transition(CameraState.recording);
  }

  /// Stops recording and returns the finalized [VideoResult].
  Future<VideoResult> stopVideoRecording() async {
    if (state != CameraState.recording) {
      throw CameraStateException('Not recording (state ${state.name})');
    }
    try {
      return await _backend.stopVideoRecording();
    } finally {
      if (_stateMachine.canTransitionTo(CameraState.previewing)) {
        _stateMachine.transition(CameraState.previewing);
      }
    }
  }

  /// Releases all resources.
  Future<void> dispose() async {
    if (_stateMachine.canTransitionTo(CameraState.disposed)) {
      _stateMachine.transition(CameraState.disposed);
    }
    await _backend.close();
    await _stateMachine.dispose();
  }
}
