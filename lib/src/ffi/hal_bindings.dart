/// FFI bindings for the platform HAL (`camera_hal.h`) and the Apple accessors
/// (`camera_hal_apple.h`).
///
/// Bound to the same code asset as `camera_pro_bindings.dart`. These symbols
/// only exist when a real backend is linked for the target (e.g. the
/// AVFoundation HAL on macOS/iOS); they are never called on platforms that link
/// the stub, so lazy `@Native` resolution is safe.
@ffi.DefaultAsset('package:camera_pro/src/ffi/camera_pro_bindings.dart')
library;

// ignore_for_file: non_constant_identifier_names, camel_case_types

import 'dart:ffi' as ffi;

/// Opaque handle to a native HAL context (`camera_context_t*`).
final class CameraHalContext extends ffi.Opaque {}

/// Mirror of `camera_pro_apple_caps_t`. Field order MUST match the C struct.
final class AppleCaps extends ffi.Struct {
  @ffi.Int32()
  external int device_count;

  @ffi.Int32()
  external int iso_supported;
  @ffi.Int32()
  external int iso_min;
  @ffi.Int32()
  external int iso_max;

  @ffi.Int32()
  external int shutter_supported;
  @ffi.Int64()
  external int shutter_min_ns;
  @ffi.Int64()
  external int shutter_max_ns;

  @ffi.Int32()
  external int focus_supported;

  @ffi.Int32()
  external int ev_supported;
  @ffi.Float()
  external double ev_min;
  @ffi.Float()
  external double ev_max;

  @ffi.Int32()
  external int zoom_supported;
  @ffi.Float()
  external double zoom_max;

  @ffi.Int32()
  external int has_flash;
  @ffi.Int32()
  external int has_torch;
}

// ── Generic HAL lifecycle / controls ───────────────────────────────────────

@ffi.Native<ffi.Int32 Function(ffi.Pointer<ffi.Pointer<CameraHalContext>>)>()
external int camera_hal_create(ffi.Pointer<ffi.Pointer<CameraHalContext>> ctx);

@ffi.Native<ffi.Int32 Function(ffi.Pointer<CameraHalContext>)>()
external int camera_hal_destroy(ffi.Pointer<CameraHalContext> ctx);

@ffi.Native<
    ffi.Int32 Function(ffi.Pointer<CameraHalContext>, ffi.Pointer<ffi.Int32>)>()
external int camera_hal_enumerate_devices(
  ffi.Pointer<CameraHalContext> ctx,
  ffi.Pointer<ffi.Int32> count,
);

@ffi.Native<
    ffi.Int32 Function(ffi.Pointer<CameraHalContext>, ffi.Int32, ffi.Int64)>()
external int camera_hal_open(
  ffi.Pointer<CameraHalContext> ctx,
  int deviceIndex,
  int textureId,
);

@ffi.Native<ffi.Int32 Function(ffi.Pointer<CameraHalContext>)>()
external int camera_hal_close(ffi.Pointer<CameraHalContext> ctx);

@ffi.Native<ffi.Int32 Function(ffi.Pointer<CameraHalContext>)>()
external int camera_hal_start_preview(ffi.Pointer<CameraHalContext> ctx);

@ffi.Native<ffi.Int32 Function(ffi.Pointer<CameraHalContext>)>()
external int camera_hal_stop_preview(ffi.Pointer<CameraHalContext> ctx);

@ffi.Native<ffi.Int32 Function(ffi.Pointer<CameraHalContext>, ffi.Int64)>()
external int camera_hal_set_shutter_speed_ns(
  ffi.Pointer<CameraHalContext> ctx,
  int durationNs,
);

@ffi.Native<ffi.Int32 Function(ffi.Pointer<CameraHalContext>, ffi.Int32)>()
external int camera_hal_set_iso(ffi.Pointer<CameraHalContext> ctx, int iso);

@ffi.Native<ffi.Int32 Function(ffi.Pointer<CameraHalContext>, ffi.Float)>()
external int camera_hal_set_exposure_compensation(
  ffi.Pointer<CameraHalContext> ctx,
  double ev,
);

@ffi.Native<ffi.Int32 Function(ffi.Pointer<CameraHalContext>, ffi.Float)>()
external int camera_hal_set_focus_distance(
  ffi.Pointer<CameraHalContext> ctx,
  double diopters,
);

@ffi.Native<ffi.Int32 Function(ffi.Pointer<CameraHalContext>, ffi.Int32)>()
external int camera_hal_set_wb_temperature(
  ffi.Pointer<CameraHalContext> ctx,
  int kelvin,
);

@ffi.Native<ffi.Int32 Function(ffi.Pointer<CameraHalContext>, ffi.Float)>()
external int camera_hal_set_zoom(ffi.Pointer<CameraHalContext> ctx, double factor);

@ffi.Native<
    ffi.Int32 Function(ffi.Pointer<CameraHalContext>, ffi.Bool, ffi.Float)>()
external int camera_hal_set_torch(
  ffi.Pointer<CameraHalContext> ctx,
  bool enabled,
  double intensity,
);

// ── Video recording ─────────────────────────────────────────────────────────

@ffi.Native<
    ffi.Int32 Function(ffi.Pointer<CameraHalContext>, ffi.Pointer<ffi.Char>)>()
external int camera_hal_start_recording(
  ffi.Pointer<CameraHalContext> ctx,
  ffi.Pointer<ffi.Char> path,
);

@ffi.Native<ffi.Int32 Function(ffi.Pointer<CameraHalContext>)>()
external int camera_hal_stop_recording(ffi.Pointer<CameraHalContext> ctx);

// ── Live preview image stream ───────────────────────────────────────────────

@ffi.Native<
    ffi.Int32 Function(
      ffi.Pointer<CameraHalContext>,
      ffi.Int32,
      ffi.Int32,
      ffi.Int32,
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Void>,
    )>()
external int camera_hal_start_image_stream(
  ffi.Pointer<CameraHalContext> ctx,
  int width,
  int height,
  int fps,
  ffi.Pointer<ffi.Void> callback,
  ffi.Pointer<ffi.Void> userData,
);

@ffi.Native<ffi.Int32 Function(ffi.Pointer<CameraHalContext>)>()
external int camera_hal_stop_image_stream(ffi.Pointer<CameraHalContext> ctx);

@ffi.Native<ffi.Int64 Function(ffi.Pointer<CameraHalContext>)>()
external int camera_pro_apple_frame_count(ffi.Pointer<CameraHalContext> ctx);

@ffi.Native<
    ffi.Int32 Function(
      ffi.Pointer<CameraHalContext>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Int32,
      ffi.Pointer<ffi.Int32>,
      ffi.Pointer<ffi.Int32>,
    )>()
external int camera_pro_apple_copy_latest_frame(
  ffi.Pointer<CameraHalContext> ctx,
  ffi.Pointer<ffi.Uint8> out,
  int cap,
  ffi.Pointer<ffi.Int32> width,
  ffi.Pointer<ffi.Int32> height,
);

// ── Metal GPU compute (Apple) ───────────────────────────────────────────────

@ffi.Native<ffi.Int32 Function()>()
external int camera_pro_metal_available();

@ffi.Native<ffi.Pointer<ffi.Char> Function()>()
external ffi.Pointer<ffi.Char> camera_pro_metal_device_name();

@ffi.Native<
    ffi.Int32 Function(
      ffi.Pointer<ffi.Uint8>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Int32,
      ffi.Int32,
      ffi.Int32,
      ffi.Float,
      ffi.Uint32,
    )>()
external int camera_pro_metal_focus_peaking(
  ffi.Pointer<ffi.Uint8> inPx,
  ffi.Pointer<ffi.Uint8> outPx,
  int width,
  int height,
  int isBgra,
  double threshold,
  int peakColor,
);

@ffi.Native<
    ffi.Int32 Function(
      ffi.Pointer<ffi.Uint8>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Int32,
      ffi.Int32,
      ffi.Int32,
      ffi.Float,
      ffi.Int32,
    )>()
external int camera_pro_metal_zebra(
  ffi.Pointer<ffi.Uint8> inPx,
  ffi.Pointer<ffi.Uint8> outPx,
  int width,
  int height,
  int isBgra,
  double threshold,
  int frameCounter,
);

// ── Apple flat accessors ────────────────────────────────────────────────────

@ffi.Native<ffi.Int32 Function(ffi.Pointer<CameraHalContext>)>()
external int camera_pro_apple_device_count(ffi.Pointer<CameraHalContext> ctx);

@ffi.Native<
    ffi.Int32 Function(
      ffi.Pointer<CameraHalContext>,
      ffi.Int32,
      ffi.Pointer<ffi.Char>,
      ffi.Int32,
    )>()
external int camera_pro_apple_device_name(
  ffi.Pointer<CameraHalContext> ctx,
  int index,
  ffi.Pointer<ffi.Char> out,
  int cap,
);

@ffi.Native<ffi.Int32 Function(ffi.Pointer<CameraHalContext>, ffi.Int32)>()
external int camera_pro_apple_device_position(
  ffi.Pointer<CameraHalContext> ctx,
  int index,
);

@ffi.Native<
    ffi.Void Function(ffi.Pointer<CameraHalContext>, ffi.Pointer<AppleCaps>)>()
external void camera_pro_apple_get_caps(
  ffi.Pointer<CameraHalContext> ctx,
  ffi.Pointer<AppleCaps> out,
);

@ffi.Native<
    ffi.Int32 Function(
      ffi.Pointer<CameraHalContext>, ffi.Pointer<ffi.Char>, ffi.Int32)>()
external int camera_pro_apple_platform_name(
  ffi.Pointer<CameraHalContext> ctx,
  ffi.Pointer<ffi.Char> out,
  int cap,
);

@ffi.Native<
    ffi.Int32 Function(
      ffi.Pointer<CameraHalContext>, ffi.Pointer<ffi.Char>, ffi.Int32)>()
external int camera_pro_apple_active_device_name(
  ffi.Pointer<CameraHalContext> ctx,
  ffi.Pointer<ffi.Char> out,
  int cap,
);
