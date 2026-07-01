/// AVFoundation-backed [CameraBackend] for macOS and iOS.
///
/// Forwards to the native HAL (`camera_hal_apple.m`) over FFI. On macOS the
/// device's manual-control capabilities come back as unsupported (an
/// AVFoundation limitation), so the controller degrades to `CameraTier.basic`;
/// on iOS the same code reports full manual control. Photo/video capture and
/// preview-texture rendering are still roadmap — those setters report the
/// feature as unsupported rather than pretending.
library;

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart' as pkg_ffi;

import '../../controller/camera_backend.dart';
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

      // On iOS the manual-control APIs exist together; WB tracks ISO support.
      final manual = c.iso_supported == 1;
      const iosOnly = 'AVFoundation manual control is iOS-only';

      return CameraCapabilities(
        iso: c.iso_supported == 1
            ? Supported<int>(
                currentValue: c.iso_min, minValue: c.iso_min, maxValue: c.iso_max)
            : const NotSupported<int>(reason: iosOnly),
        shutterSpeed: c.shutter_supported == 1
            ? Supported<Duration>(
                currentValue: Duration(microseconds: c.shutter_min_ns ~/ 1000),
                minValue: Duration(microseconds: c.shutter_min_ns ~/ 1000),
                maxValue: Duration(microseconds: c.shutter_max_ns ~/ 1000),
              )
            : const NotSupported<Duration>(reason: iosOnly),
        focusDistance: c.focus_supported == 1
            ? const Supported<double>(
                currentValue: 0.5, minValue: 0.0, maxValue: 1.0)
            : const NotSupported<double>(reason: iosOnly),
        exposureCompensation: c.ev_supported == 1
            ? Supported<double>(
                currentValue: 0.0, minValue: c.ev_min, maxValue: c.ev_max)
            : const NotSupported<double>(reason: iosOnly),
        whiteBalanceKelvin: manual
            ? const Supported<int>(
                currentValue: 5000, minValue: 2500, maxValue: 10000)
            : const NotSupported<int>(reason: iosOnly),
        zoom: c.zoom_supported == 1
            ? Supported<double>(
                currentValue: 1.0, minValue: 1.0, maxValue: c.zoom_max)
            : const NotSupported<double>(reason: iosOnly),
        aperture: const NotSupported<double>(reason: 'Fixed aperture'),
        supportedMeteringModes: const <MeteringMode>[MeteringMode.matrix],
        supportedFocusModes: manual
            ? const <FocusMode>[FocusMode.autoContinuous, FocusMode.manual]
            : const <FocusMode>[FocusMode.autoContinuous],
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

  @override
  Future<void> setExposureMode(ExposureMode mode) async {
    // Exposure mode is applied implicitly by the custom shutter/ISO setters.
  }

  @override
  Future<void> setShutterSpeed(ShutterSpeed value) async =>
      _check(hal.camera_hal_set_shutter_speed_ns(_ctx, value.nanoseconds));

  @override
  Future<void> setIso(Iso iso) async =>
      _check(hal.camera_hal_set_iso(_ctx, iso.value));

  @override
  Future<void> setExposureCompensation(Ev ev) async =>
      _check(hal.camera_hal_set_exposure_compensation(_ctx, ev.stops));

  @override
  Future<void> setFocusMode(FocusMode mode) async {}

  @override
  Future<void> setFocusDistance(double diopters) async =>
      _check(hal.camera_hal_set_focus_distance(_ctx, diopters));

  @override
  Future<void> setWhiteBalance(WhiteBalance wb) async {
    if (wb.kelvin != null) {
      _check(hal.camera_hal_set_wb_temperature(_ctx, wb.kelvin!));
    }
  }

  @override
  Future<void> setZoom(double factor) async =>
      _check(hal.camera_hal_set_zoom(_ctx, factor));

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
    throw const CameraFeatureNotSupportedError(
      feature: 'Photo capture',
      platformReason: 'AVFoundation capture output is roadmap',
    );
  }

  @override
  Future<void> startVideoRecording(String path) async {
    throw const CameraFeatureNotSupportedError(
      feature: 'Video recording',
      platformReason: 'AVCaptureMovieFileOutput wiring is roadmap',
    );
  }

  @override
  Future<VideoResult> stopVideoRecording() async {
    throw const CameraFeatureNotSupportedError(
      feature: 'Video recording',
      platformReason: 'AVCaptureMovieFileOutput wiring is roadmap',
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    hal.camera_hal_close(_ctx);
    hal.camera_hal_destroy(_ctx);
  }
}
