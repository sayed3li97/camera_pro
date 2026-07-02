/// AVFoundation-backed [CameraBackend] for macOS and iOS.
///
/// Forwards to the native HAL (`camera_hal_apple.m`) over FFI. Manual controls
/// use the device's *sensor* controls where the hardware exposes them (iOS, and
/// external UVC webcams); where it doesn't (the built-in camera on macOS, whose
/// controls are unavailable via AVFoundation/CoreMediaIO/UVC), they fall back to
/// a **digital** pipeline in the C core (`camera_pro_adjust_pixels` /
/// `camera_pro_digital_zoom`) applied to preview frames — so ISO, exposure,
/// white balance, and zoom still work and are visible on macOS.
library;

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart' as pkg_ffi;

import '../../controller/camera_backend.dart';
import '../../ffi/camera_pro_bindings.dart' as core;
import '../../ffi/hal_bindings.dart' as hal;
import '../../models/camera_device.dart';
import '../../models/capabilities.dart';
import '../../models/capture_result.dart';
import '../../models/errors.dart';
import '../../models/settings.dart';

/// A [CameraBackend] backed by the native AVFoundation HAL.
class AppleCameraBackend implements CameraBackend {
  AppleCameraBackend() {
    final out = pkg_ffi.calloc<ffi.Pointer<hal.CameraHalContext>>();
    try {
      final rc = hal.camera_hal_create(out);
      if (rc != 0) {
        throw CameraDeviceError(
          nativeErrorCode: rc,
          message: 'Failed to create AVFoundation HAL context',
        );
      }
      _ctx = out.value;
    } finally {
      pkg_ffi.calloc.free(out);
    }
  }

  late final ffi.Pointer<hal.CameraHalContext> _ctx;
  bool _closed = false;

  // True when the device exposes real sensor controls (iOS / UVC). When false
  // (macOS built-in camera), manual controls use the digital pipeline below.
  bool _hardwareControls = false;

  // Digital manual-control state (identity = no change).
  double _gain = 1.0; // digital ISO
  double _shutterGain = 1.0; // digital shutter (brightness ∝ exposure time)
  double _bias = 0.0; // exposure/EV, additive
  double _temp = 0.0; // white balance, warm(+)/cool(-)
  double _zoom = 1.0; // digital zoom factor
  int _blurRadius = 0; // digital defocus (manual focus)

  bool get _adjustActive =>
      !_hardwareControls &&
      (_gain != 1.0 ||
          _shutterGain != 1.0 ||
          _bias != 0.0 ||
          _temp != 0.0 ||
          _zoom > 1.001 ||
          _blurRadius > 0);

  static String _readString(
    int Function(ffi.Pointer<hal.CameraHalContext>, ffi.Pointer<ffi.Char>, int)
        reader, {
    required ffi.Pointer<hal.CameraHalContext> ctx,
    int cap = 256,
  }) {
    final buf = pkg_ffi.calloc<ffi.Uint8>(cap);
    try {
      reader(ctx, buf.cast<ffi.Char>(), cap);
      return buf.cast<pkg_ffi.Utf8>().toDartString();
    } finally {
      pkg_ffi.calloc.free(buf);
    }
  }

  @override
  Future<CameraList> enumerateDevices() async {
    final countPtr = pkg_ffi.calloc<ffi.Int32>();
    try {
      hal.camera_hal_enumerate_devices(_ctx, countPtr);
      final count = countPtr.value;
      final devices = <CameraDevice>[];
      for (var i = 0; i < count; i++) {
        final nameBuf = pkg_ffi.calloc<ffi.Uint8>(256);
        try {
          hal.camera_pro_apple_device_name(_ctx, i, nameBuf.cast<ffi.Char>(), 256);
          final name = nameBuf.cast<pkg_ffi.Utf8>().toDartString();
          final pos = hal.camera_pro_apple_device_position(_ctx, i);
          devices.add(
            CameraDevice(
              index: i,
              name: name,
              direction: switch (pos) {
                1 => LensDirection.back,
                2 => LensDirection.front,
                _ => LensDirection.unknown,
              },
            ),
          );
        } finally {
          pkg_ffi.calloc.free(nameBuf);
        }
      }
      return CameraList(devices);
    } finally {
      pkg_ffi.calloc.free(countPtr);
    }
  }

  @override
  Future<int?> open(CameraDevice device) async {
    final rc = hal.camera_hal_open(_ctx, device.index, 0);
    if (rc != 0) throw cameraProErrorFromCode(rc);
    return null; // preview texture id is roadmap
  }

  @override
  Future<CameraCapabilities> getCapabilities() async {
    final capsPtr = pkg_ffi.calloc<hal.AppleCaps>();
    try {
      hal.camera_pro_apple_get_caps(_ctx, capsPtr);
      final c = capsPtr.ref;
      final platform =
          _readString(hal.camera_pro_apple_platform_name, ctx: _ctx, cap: 64);
      final device =
          _readString(hal.camera_pro_apple_active_device_name, ctx: _ctx);

      // Hardware sensor controls (iOS / UVC) vs. digital fallback (macOS built-in).
      _hardwareControls = c.iso_supported == 1;
      final hw = _hardwareControls;

      return CameraCapabilities(
        // ISO: hardware sensitivity on iOS; digital gain on macOS.
        iso: hw
            ? Supported<int>(
                currentValue: c.iso_min, minValue: c.iso_min, maxValue: c.iso_max)
            : const Supported<int>(
                currentValue: 100, minValue: 50, maxValue: 1600),
        // Shutter: hardware exposure time on iOS; digital brightness on macOS
        // (1/1000s..1/4s, brightness scales with exposure time).
        shutterSpeed: hw
            ? Supported<Duration>(
                currentValue: Duration(microseconds: c.shutter_min_ns ~/ 1000),
                minValue: Duration(microseconds: c.shutter_min_ns ~/ 1000),
                maxValue: Duration(microseconds: c.shutter_max_ns ~/ 1000),
              )
            : const Supported<Duration>(
                currentValue: Duration(microseconds: 16667), // ~1/60s
                minValue: Duration(microseconds: 1000), // 1/1000s
                maxValue: Duration(microseconds: 250000), // 1/4s
              ),
        // Focus: hardware lens position on iOS; digital defocus (blur) on macOS.
        focusDistance: hw
            ? const Supported<double>(
                currentValue: 0.5, minValue: 0.0, maxValue: 1.0)
            : const Supported<double>(
                currentValue: 0.5, minValue: 0.0, maxValue: 1.0),
        // Exposure compensation: hardware bias on iOS; digital brightness on macOS.
        exposureCompensation: hw
            ? Supported<double>(
                currentValue: 0.0, minValue: c.ev_min, maxValue: c.ev_max)
            : const Supported<double>(
                currentValue: 0.0, minValue: -3.0, maxValue: 3.0),
        // White balance: hardware gains on iOS; digital channel balance on macOS.
        whiteBalanceKelvin: const Supported<int>(
            currentValue: 5500, minValue: 2500, maxValue: 10000),
        // Zoom: hardware on iOS; digital crop-zoom on macOS.
        zoom: hw
            ? Supported<double>(
                currentValue: 1.0, minValue: 1.0, maxValue: c.zoom_max)
            : const Supported<double>(
                currentValue: 1.0, minValue: 1.0, maxValue: 4.0),
        aperture: const NotSupported<double>(reason: 'Fixed aperture'),
        supportedMeteringModes: const <MeteringMode>[MeteringMode.matrix],
        supportedFocusModes: const <FocusMode>[
          FocusMode.autoContinuous,
          FocusMode.manual,
        ],
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
        hasFlash: c.has_flash == 1,
        hasTorch: c.has_torch == 1,
        hasOis: false,
        platformName: platform.isEmpty ? 'AVFoundation' : platform,
        deviceName: device.isEmpty ? 'AVFoundation camera' : device,
        hardwareLevel: -1,
      );
    } finally {
      pkg_ffi.calloc.free(capsPtr);
    }
  }

  void _check(int rc) {
    if (rc != 0) throw cameraProErrorFromCode(rc);
  }

  @override
  Future<void> startPreview() async => _check(hal.camera_hal_start_preview(_ctx));

  @override
  Future<void> stopPreview() async => _check(hal.camera_hal_stop_preview(_ctx));

  // Reused scratch buffers for polling preview frames (avoid per-frame malloc).
  ffi.Pointer<ffi.Uint8> _frameBuf = ffi.nullptr;
  ffi.Pointer<ffi.Uint8> _zoomBuf = ffi.nullptr;
  int _frameBufCap = 0;

  @override
  Future<void> startFrameStream() async {
    // Requests camera permission (system prompt) and starts the session.
    _check(hal.camera_hal_start_image_stream(
      _ctx, 0, 0, 30, ffi.nullptr, ffi.nullptr));
  }

  @override
  Future<void> stopFrameStream() async {
    hal.camera_hal_stop_image_stream(_ctx);
  }

  @override
  int get frameCount => hal.camera_pro_apple_frame_count(_ctx);

  @override
  PreviewFrame? latestFrame() {
    if (_closed) return null;
    // Ensure the scratch buffer can hold a 4K BGRA frame at most.
    const maxBytes = 3840 * 2160 * 4;
    if (_frameBufCap == 0) {
      _frameBuf = pkg_ffi.malloc<ffi.Uint8>(maxBytes);
      _zoomBuf = pkg_ffi.malloc<ffi.Uint8>(maxBytes);
      _frameBufCap = maxBytes;
    }
    final wPtr = pkg_ffi.calloc<ffi.Int32>();
    final hPtr = pkg_ffi.calloc<ffi.Int32>();
    try {
      final bytes = hal.camera_pro_apple_copy_latest_frame(
        _ctx, _frameBuf, _frameBufCap, wPtr, hPtr);
      if (bytes <= 0) return null;
      final w = wPtr.value;
      final h = hPtr.value;

      // Apply the digital manual-control pipeline (macOS fallback). Frames are
      // BGRA (is_bgra = 1). Hardware-controlled devices skip this entirely.
      var src = _frameBuf;
      if (_adjustActive) {
        if (_zoom > 1.001) {
          core.camera_pro_digital_zoom(_frameBuf, _zoomBuf, w, h, w * 4, _zoom);
          src = _zoomBuf;
        }
        // ISO × shutter both scale brightness; EV is additive; temp is WB.
        core.camera_pro_adjust_pixels(
          src, w, h, w * 4, 1, _gain * _shutterGain, _bias, _temp, 1.0);
        if (_blurRadius > 0) {
          core.camera_pro_box_blur(src, w, h, w * 4, _blurRadius);
        }
      }

      return PreviewFrame(
        bytes: Uint8List.fromList(src.asTypedList(bytes)),
        width: w,
        height: h,
      );
    } finally {
      pkg_ffi.calloc.free(wPtr);
      pkg_ffi.calloc.free(hPtr);
    }
  }

  @override
  Future<void> setExposureMode(ExposureMode mode) async {
    // Exposure mode is applied implicitly by the custom shutter/ISO setters.
  }

  @override
  Future<void> setShutterSpeed(ShutterSpeed value) async {
    if (_hardwareControls) {
      _check(hal.camera_hal_set_shutter_speed_ns(_ctx, value.nanoseconds));
    } else {
      // Digital shutter: brightness scales with exposure time relative to 1/60s,
      // clamped so extremes stay usable.
      const referenceUs = 16667.0; // 1/60s
      final g = value.duration.inMicroseconds / referenceUs;
      _shutterGain = g.clamp(0.25, 4.0);
    }
  }

  @override
  Future<void> setIso(Iso iso) async {
    if (_hardwareControls) {
      _check(hal.camera_hal_set_iso(_ctx, iso.value));
    } else {
      // Digital gain: ISO 100 == 1.0x.
      _gain = iso.value / 100.0;
    }
  }

  @override
  Future<void> setExposureCompensation(Ev ev) async {
    if (_hardwareControls) {
      _check(hal.camera_hal_set_exposure_compensation(_ctx, ev.stops));
    } else {
      // Digital brightness: ~40 levels per stop.
      _bias = ev.stops * 40.0;
    }
  }

  @override
  Future<void> setFocusMode(FocusMode mode) async {}

  @override
  Future<void> setFocusDistance(double diopters) async {
    if (_hardwareControls) {
      _check(hal.camera_hal_set_focus_distance(_ctx, diopters));
    } else {
      // Digital "rack focus": sharpest at 0.5, defocus (blur) toward either end.
      final off = (diopters.clamp(0.0, 1.0) - 0.5).abs() * 2.0; // 0..1
      _blurRadius = (off * 12).round();
    }
  }

  @override
  Future<void> setWhiteBalance(WhiteBalance wb) async {
    final kelvin = wb.kelvin;
    if (kelvin == null) return;
    if (_hardwareControls) {
      _check(hal.camera_hal_set_wb_temperature(_ctx, kelvin));
    } else {
      // Digital channel balance: below 5500K warms, above cools.
      _temp = ((5500 - kelvin) / 5000.0).clamp(-1.0, 1.0);
    }
  }

  @override
  Future<void> setZoom(double factor) async {
    if (_hardwareControls) {
      _check(hal.camera_hal_set_zoom(_ctx, factor));
    } else {
      _zoom = factor < 1.0 ? 1.0 : factor;
    }
  }

  @override
  Future<void> setFlashMode(FlashMode mode) async {
    throw const CameraFeatureNotSupportedError(
      feature: 'Flash',
      platformReason: 'Photo flash capture is roadmap on the AVFoundation HAL',
    );
  }

  @override
  Future<void> setTorch({required bool enabled, double intensity = 1.0}) async =>
      _check(hal.camera_hal_set_torch(_ctx, enabled, intensity));

  @override
  Future<CapturedPhoto> capturePhoto({ImageFormat? format}) async {
    // Capture the latest preview frame (with all digital manual-control
    // adjustments already applied) and encode it as a PNG on disk. This is the
    // still-capture path until AVCapturePhotoOutput is wired for full-res RAW.
    final frame = latestFrame();
    if (frame == null) {
      throw CameraCaptureError(reason: CaptureFailureReason.noFrame);
    }

    final decodeCompleter = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      frame.bytes,
      frame.width,
      frame.height,
      frame.isBgra ? ui.PixelFormat.bgra8888 : ui.PixelFormat.rgba8888,
      decodeCompleter.complete,
    );
    final image = await decodeCompleter.future;
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (png == null) {
      throw CameraCaptureError(reason: CaptureFailureReason.encodingFailed);
    }

    final bytes = png.buffer.asUint8List();
    final ts = DateTime.now();
    final path =
        '${Directory.systemTemp.path}/camera_pro_${ts.millisecondsSinceEpoch}.png';
    await File(path).writeAsBytes(bytes, flush: true);

    return CapturedPhoto(
      width: frame.width,
      height: frame.height,
      format: ImageFormat.png,
      timestamp: ts,
      bytes: bytes,
      path: path,
    );
  }

  String? _recordingPath;
  DateTime? _recordingStart;

  @override
  Future<void> startVideoRecording(String path) async {
    final cPath = path.toNativeUtf8(allocator: pkg_ffi.malloc);
    try {
      _check(hal.camera_hal_start_recording(_ctx, cPath.cast<ffi.Char>()));
      _recordingPath = path;
      _recordingStart = DateTime.now();
    } finally {
      pkg_ffi.malloc.free(cPath);
    }
  }

  @override
  Future<VideoResult> stopVideoRecording() async {
    final path = _recordingPath;
    final start = _recordingStart;
    if (path == null || start == null) {
      throw CameraCaptureError(reason: CaptureFailureReason.interrupted);
    }
    // The HAL blocks until the .mov is finalized on disk.
    _check(hal.camera_hal_stop_recording(_ctx));
    _recordingPath = null;
    _recordingStart = null;
    final file = File(path);
    // Recording happens at the active session preset; report the true frame
    // dimensions from the preview stream rather than assuming a resolution.
    final frame = latestFrame();
    return VideoResult(
      path: path,
      duration: DateTime.now().difference(start),
      codec: VideoCodec.h264,
      resolution: frame != null
          ? VideoResolution(frame.width, frame.height)
          : VideoResolution.fhd1080p,
      fileSizeBytes: file.existsSync() ? file.lengthSync() : null,
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    hal.camera_hal_stop_image_stream(_ctx);
    hal.camera_hal_close(_ctx);
    hal.camera_hal_destroy(_ctx);
    if (_frameBufCap > 0) {
      pkg_ffi.malloc.free(_frameBuf);
      pkg_ffi.malloc.free(_zoomBuf);
      _frameBufCap = 0;
    }
  }
}
