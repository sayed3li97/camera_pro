/*
 * camera_hal_apple.m — AVFoundation backend implementing camera_hal.h.
 *
 * Shared by iOS and macOS. Manual exposure/focus/white-balance/zoom controls
 * are iOS-only in AVFoundation (the relevant AVCaptureDevice APIs are
 * API_UNAVAILABLE(macos)), so they are guarded with TARGET_OS_IOS. On macOS the
 * backend still enumerates devices and reports capabilities honestly (manual
 * controls => NotSupported), which the Dart layer surfaces as CameraTier.basic.
 *
 * Compiled with ARC. The opaque camera_context_t* is a bridged Objective-C
 * object (CPAppleContext) holding strong references to the AVFoundation session.
 *
 * Verification status:
 *   - macOS: compiled AND run against the real FaceTime HD Camera (enumeration
 *     + capability query verified).
 *   - iOS: compiled against the iPhoneOS SDK (manual-control branch verified to
 *     build); on-device behaviour requires a physical device.
 *
 * Copyright (c) 2026 camera_pro contributors. BSD-3-Clause.
 */
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <TargetConditionals.h>

#include "camera_hal_apple.h"

#include <stdlib.h>
#include <string.h>

// ── Bridged Objective-C context ─────────────────────────────────────────────

@interface CPAppleContext : NSObject
@property(nonatomic, strong) NSArray<AVCaptureDevice*>* devices;
@property(nonatomic, strong) AVCaptureDevice* device;
@property(nonatomic, strong) AVCaptureSession* session;
@property(nonatomic, strong) AVCaptureDeviceInput* input;
@property(nonatomic, assign) camera_state_t state;

@property(nonatomic, assign) camera_pro_apple_caps_t caps;
@property(nonatomic, copy) NSString* platformName;
@property(nonatomic, copy) NSString* deviceName;

@property(nonatomic, assign) camera_error_callback_t errorCb;
@property(nonatomic, assign) void* errorUd;
@property(nonatomic, assign) camera_state_callback_t stateCb;
@property(nonatomic, assign) void* stateUd;

// Live preview
@property(nonatomic, strong) AVCaptureVideoDataOutput* dataOutput;
@property(nonatomic, strong) id frameDelegate;  // CPFrameDelegate
@property(nonatomic, strong) dispatch_queue_t frameQueue;
@end

@implementation CPAppleContext
@end

// Receives CVPixelBuffers off the capture queue and keeps the latest frame as
// tightly-packed BGRA under a lock for the FFI copy accessor.
@interface CPFrameDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property(nonatomic, strong) NSMutableData* latest;
@property(nonatomic, assign) int32_t width;
@property(nonatomic, assign) int32_t height;
@property(atomic, assign) int64_t frameCount;
@property(nonatomic, strong) NSLock* lock;
@end

@implementation CPFrameDelegate
- (instancetype)init {
  if ((self = [super init])) { _lock = [NSLock new]; }
  return self;
}
- (void)captureOutput:(AVCaptureOutput*)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection*)connection {
  (void)output; (void)connection;
  CVImageBufferRef img = CMSampleBufferGetImageBuffer(sampleBuffer);
  if (!img) return;
  CVPixelBufferLockBaseAddress(img, kCVPixelBufferLock_ReadOnly);
  const size_t w = CVPixelBufferGetWidth(img);
  const size_t h = CVPixelBufferGetHeight(img);
  const size_t bpr = CVPixelBufferGetBytesPerRow(img);
  const uint8_t* base = (const uint8_t*)CVPixelBufferGetBaseAddress(img);
  NSMutableData* d = [NSMutableData dataWithLength:w * h * 4];
  uint8_t* dst = (uint8_t*)d.mutableBytes;
  for (size_t y = 0; y < h; y++) {
    memcpy(dst + y * w * 4, base + y * bpr, w * 4);
  }
  CVPixelBufferUnlockBaseAddress(img, kCVPixelBufferLock_ReadOnly);
  [self.lock lock];
  self.latest = d;
  self.width = (int32_t)w;
  self.height = (int32_t)h;
  self.frameCount++;
  [self.lock unlock];
}
@end

static inline CPAppleContext* CTX(camera_context_t* c) {
  return (__bridge CPAppleContext*)c;
}

static void set_state(CPAppleContext* c, camera_state_t s) {
  c.state = s;
  if (c.stateCb) c.stateCb(c.stateUd, (int32_t)s);
}

static int32_t copy_utf8(NSString* s, char* out, int32_t cap) {
  if (!out || cap <= 0) return 0;
  const char* utf8 = s ? s.UTF8String : "";
  int32_t n = (int32_t)strlen(utf8);
  if (n > cap - 1) n = cap - 1;
  memcpy(out, utf8, (size_t)n);
  out[n] = '\0';
  return n;
}

// ── Device discovery ────────────────────────────────────────────────────────

static NSArray<AVCaptureDevice*>* discover_devices(void) {
  NSMutableArray<AVCaptureDeviceType>* types = [NSMutableArray array];
  [types addObject:AVCaptureDeviceTypeBuiltInWideAngleCamera];
#if TARGET_OS_IOS
  [types addObject:AVCaptureDeviceTypeBuiltInUltraWideCamera];
  [types addObject:AVCaptureDeviceTypeBuiltInTelephotoCamera];
#endif
  if (@available(macOS 14.0, iOS 17.0, *)) {
    [types addObject:AVCaptureDeviceTypeExternal];
  }
  AVCaptureDeviceDiscoverySession* s = [AVCaptureDeviceDiscoverySession
      discoverySessionWithDeviceTypes:types
                            mediaType:AVMediaTypeVideo
                             position:AVCaptureDevicePositionUnspecified];
  return s.devices;
}

static void resolve_caps(CPAppleContext* c) {
  camera_pro_apple_caps_t caps;
  memset(&caps, 0, sizeof(caps));
  caps.device_count = (int32_t)c.devices.count;

  AVCaptureDevice* d = c.device;
  if (d) {
    caps.has_flash = d.hasFlash ? 1 : 0;
    caps.has_torch = d.hasTorch ? 1 : 0;
    c.deviceName = d.localizedName;
#if TARGET_OS_IOS
    c.platformName = @"iOS, AVFoundation";
    AVCaptureDeviceFormat* f = d.activeFormat;
    caps.iso_supported = 1;
    caps.iso_min = (int32_t)f.minISO;
    caps.iso_max = (int32_t)f.maxISO;
    caps.shutter_supported = 1;
    caps.shutter_min_ns = (int64_t)(CMTimeGetSeconds(f.minExposureDuration) * 1e9);
    caps.shutter_max_ns = (int64_t)(CMTimeGetSeconds(f.maxExposureDuration) * 1e9);
    caps.focus_supported =
        [d isFocusModeSupported:AVCaptureFocusModeLocked] ? 1 : 0;
    caps.ev_supported = 1;
    caps.ev_min = d.minExposureTargetBias;
    caps.ev_max = d.maxExposureTargetBias;
    caps.zoom_supported = 1;
    caps.zoom_max = (float)f.videoMaxZoomFactor;
#else
    c.platformName = @"macOS, AVFoundation";
    // AVFoundation's manual ISO/shutter/focus/WB/zoom APIs are iOS-only.
    caps.iso_supported = 0;
    caps.shutter_supported = 0;
    caps.focus_supported = 0;
    caps.ev_supported = 0;
    caps.zoom_supported = 0;
#endif
  }
  c.caps = caps;
}

// ── Lifecycle ───────────────────────────────────────────────────────────────
// (Objective-C functions already have C linkage — no extern "C" needed.)

camera_error_t camera_hal_create(camera_context_t** ctx) {
  if (!ctx) return CAMERA_ERROR_INVALID_PARAMETER;
  @autoreleasepool {
    CPAppleContext* c = [CPAppleContext new];
    c.state = CAMERA_STATE_UNINITIALIZED;
    *ctx = (__bridge_retained camera_context_t*)c;
    return CAMERA_OK;
  }
}

camera_error_t camera_hal_destroy(camera_context_t* ctx) {
  if (!ctx) return CAMERA_ERROR_INVALID_PARAMETER;
  @autoreleasepool {
    CPAppleContext* c = (__bridge_transfer CPAppleContext*)ctx;  // releases
    [c.session stopRunning];
    c.session = nil;
    c.input = nil;
    c.device = nil;
    c.devices = nil;
  }
  return CAMERA_OK;
}

camera_error_t camera_hal_enumerate_devices(camera_context_t* ctx, int32_t* count) {
  if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;
  @autoreleasepool {
    CPAppleContext* c = CTX(ctx);
    c.devices = discover_devices();
    if (count) *count = (int32_t)c.devices.count;
  }
  return CAMERA_OK;
}

camera_error_t camera_hal_open(camera_context_t* ctx, int32_t device_index,
                               int64_t texture_id) {
  (void)texture_id;
  if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;
  @autoreleasepool {
    CPAppleContext* c = CTX(ctx);
    if (!c.devices) c.devices = discover_devices();
    if (device_index < 0 || device_index >= (int32_t)c.devices.count) {
      return CAMERA_ERROR_DEVICE_NOT_FOUND;
    }
    c.device = c.devices[device_index];

    NSError* err = nil;
    AVCaptureDeviceInput* input =
        [AVCaptureDeviceInput deviceInputWithDevice:c.device error:&err];
    if (err || !input) return CAMERA_ERROR_CONFIGURATION_FAILED;

    AVCaptureSession* session = [[AVCaptureSession alloc] init];
    if ([session canAddInput:input]) [session addInput:input];
    c.input = input;
    c.session = session;

    // Note: startRunning is deferred until a preview texture sink exists and
    // camera permission is granted; capability query needs neither.
    resolve_caps(c);
    set_state(c, CAMERA_STATE_OPENED);
    return CAMERA_OK;
  }
}

camera_error_t camera_hal_close(camera_context_t* ctx) {
  if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;
  @autoreleasepool {
    CPAppleContext* c = CTX(ctx);
    [c.session stopRunning];
    set_state(c, CAMERA_STATE_DISPOSED);
  }
  return CAMERA_OK;
}

camera_error_t camera_hal_get_capabilities(camera_context_t* ctx,
                                           camera_capabilities_t* caps) {
  if (!ctx || !caps) return CAMERA_ERROR_INVALID_PARAMETER;
  @autoreleasepool {
    CPAppleContext* c = CTX(ctx);
    memset(caps, 0, sizeof(*caps));
    const camera_pro_apple_caps_t f = c.caps;
    caps->iso.supported = f.iso_supported != 0;
    caps->iso.min_iso = f.iso_min;
    caps->iso.max_iso = f.iso_max;
    caps->shutter.supported = f.shutter_supported != 0;
    caps->shutter.min_ns = f.shutter_min_ns;
    caps->shutter.max_ns = f.shutter_max_ns;
    caps->focus.supported = f.focus_supported != 0;
    caps->exposure_compensation.supported = f.ev_supported != 0;
    caps->exposure_compensation.min_ev = f.ev_min;
    caps->exposure_compensation.max_ev = f.ev_max;
    caps->zoom.max_zoom = f.zoom_max;
    caps->flash.has_flash = f.has_flash != 0;
    caps->flash.has_torch = f.has_torch != 0;
    caps->platform_name = c.platformName.UTF8String;
    caps->device_name = c.deviceName.UTF8String;
    caps->hardware_level = -1;
    return CAMERA_OK;
  }
}

// ── Preview (texture sink is roadmap; session start deferred) ───────────────

camera_error_t camera_hal_start_preview(camera_context_t* ctx) {
  if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;
  set_state(CTX(ctx), CAMERA_STATE_PREVIEWING);
  return CAMERA_OK;
}

camera_error_t camera_hal_stop_preview(camera_context_t* ctx) {
  if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;
  set_state(CTX(ctx), CAMERA_STATE_OPENED);
  return CAMERA_OK;
}

camera_error_t camera_hal_set_preview_resolution(camera_context_t* ctx,
                                                 int32_t w, int32_t h) {
  (void)ctx; (void)w; (void)h;
  return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

// ── Manual exposure / focus / WB / zoom ─────────────────────────────────────
// iOS: real AVFoundation control. macOS: reported unsupported (APIs unavailable).

camera_error_t camera_hal_set_exposure_mode(camera_context_t* ctx, int32_t mode) {
  (void)mode;
  if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;
  return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

camera_error_t camera_hal_set_shutter_speed_ns(camera_context_t* ctx,
                                               int64_t duration_ns) {
#if TARGET_OS_IOS
  if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;
  CPAppleContext* c = CTX(ctx);
  AVCaptureDevice* d = c.device;
  if (!d) return CAMERA_ERROR_NOT_INITIALIZED;
  NSError* err = nil;
  if (![d lockForConfiguration:&err] || err) return CAMERA_ERROR_CONFIGURATION_FAILED;
  CMTime dur = CMTimeMake(duration_ns, 1000000000);
  [d setExposureModeCustomWithDuration:dur
                                   ISO:AVCaptureISOCurrent
                     completionHandler:nil];
  [d unlockForConfiguration];
  return CAMERA_OK;
#else
  (void)ctx; (void)duration_ns;
  return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
#endif
}

camera_error_t camera_hal_set_iso(camera_context_t* ctx, int32_t iso) {
#if TARGET_OS_IOS
  if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;
  CPAppleContext* c = CTX(ctx);
  AVCaptureDevice* d = c.device;
  if (!d) return CAMERA_ERROR_NOT_INITIALIZED;
  NSError* err = nil;
  if (![d lockForConfiguration:&err] || err) return CAMERA_ERROR_CONFIGURATION_FAILED;
  [d setExposureModeCustomWithDuration:AVCaptureExposureDurationCurrent
                                   ISO:(float)iso
                     completionHandler:nil];
  [d unlockForConfiguration];
  return CAMERA_OK;
#else
  (void)ctx; (void)iso;
  return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
#endif
}

camera_error_t camera_hal_set_exposure_compensation(camera_context_t* ctx, float ev) {
#if TARGET_OS_IOS
  if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;
  AVCaptureDevice* d = CTX(ctx).device;
  if (!d) return CAMERA_ERROR_NOT_INITIALIZED;
  NSError* err = nil;
  if (![d lockForConfiguration:&err] || err) return CAMERA_ERROR_CONFIGURATION_FAILED;
  [d setExposureTargetBias:ev completionHandler:nil];
  [d unlockForConfiguration];
  return CAMERA_OK;
#else
  (void)ctx; (void)ev;
  return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
#endif
}

camera_error_t camera_hal_lock_exposure(camera_context_t* ctx) {
  (void)ctx; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}
camera_error_t camera_hal_unlock_exposure(camera_context_t* ctx) {
  (void)ctx; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}
camera_error_t camera_hal_set_metering_mode(camera_context_t* ctx, int32_t mode) {
  (void)ctx; (void)mode; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}
camera_error_t camera_hal_set_metering_point(camera_context_t* ctx, float x, float y) {
  (void)ctx; (void)x; (void)y; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

camera_error_t camera_hal_set_focus_mode(camera_context_t* ctx, int32_t mode) {
  (void)ctx; (void)mode; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

camera_error_t camera_hal_set_focus_distance(camera_context_t* ctx, float diopters) {
#if TARGET_OS_IOS
  if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;
  AVCaptureDevice* d = CTX(ctx).device;
  if (!d) return CAMERA_ERROR_NOT_INITIALIZED;
  // iOS lens position is normalized 0..1; clamp the incoming value.
  float pos = diopters < 0.0f ? 0.0f : (diopters > 1.0f ? 1.0f : diopters);
  NSError* err = nil;
  if (![d lockForConfiguration:&err] || err) return CAMERA_ERROR_CONFIGURATION_FAILED;
  [d setFocusModeLockedWithLensPosition:pos completionHandler:nil];
  [d unlockForConfiguration];
  return CAMERA_OK;
#else
  (void)ctx; (void)diopters;
  return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
#endif
}

camera_error_t camera_hal_set_focus_point(camera_context_t* ctx, float x, float y) {
  (void)ctx; (void)x; (void)y; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}
camera_error_t camera_hal_lock_focus(camera_context_t* ctx) {
  (void)ctx; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}
camera_error_t camera_hal_unlock_focus(camera_context_t* ctx) {
  (void)ctx; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

camera_error_t camera_hal_set_wb_mode(camera_context_t* ctx, int32_t mode) {
  (void)ctx; (void)mode; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

camera_error_t camera_hal_set_wb_temperature(camera_context_t* ctx, int32_t kelvin) {
#if TARGET_OS_IOS
  if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;
  AVCaptureDevice* d = CTX(ctx).device;
  if (!d) return CAMERA_ERROR_NOT_INITIALIZED;
  AVCaptureWhiteBalanceTemperatureAndTintValues tt = {
      .temperature = (float)kelvin, .tint = 0.0f};
  AVCaptureWhiteBalanceGains gains =
      [d deviceWhiteBalanceGainsForTemperatureAndTintValues:tt];
  float maxGain = d.maxWhiteBalanceGain;
  gains.redGain = MIN(MAX(gains.redGain, 1.0f), maxGain);
  gains.greenGain = MIN(MAX(gains.greenGain, 1.0f), maxGain);
  gains.blueGain = MIN(MAX(gains.blueGain, 1.0f), maxGain);
  NSError* err = nil;
  if (![d lockForConfiguration:&err] || err) return CAMERA_ERROR_CONFIGURATION_FAILED;
  [d setWhiteBalanceModeLockedWithDeviceWhiteBalanceGains:gains
                                       completionHandler:nil];
  [d unlockForConfiguration];
  return CAMERA_OK;
#else
  (void)ctx; (void)kelvin;
  return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
#endif
}

camera_error_t camera_hal_set_wb_tint(camera_context_t* ctx, float gm, float ba) {
  (void)ctx; (void)gm; (void)ba; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}
camera_error_t camera_hal_lock_white_balance(camera_context_t* ctx) {
  (void)ctx; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

camera_error_t camera_hal_set_flash_mode(camera_context_t* ctx, int32_t mode) {
  (void)ctx; (void)mode; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

camera_error_t camera_hal_set_torch(camera_context_t* ctx, bool enabled, float intensity) {
#if TARGET_OS_IOS
  if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;
  AVCaptureDevice* d = CTX(ctx).device;
  if (!d || !d.hasTorch) return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
  NSError* err = nil;
  if (![d lockForConfiguration:&err] || err) return CAMERA_ERROR_CONFIGURATION_FAILED;
  if (enabled) {
    float lvl = intensity <= 0.0f ? 1.0f : (intensity > 1.0f ? 1.0f : intensity);
    [d setTorchModeOnWithLevel:lvl error:nil];
  } else {
    d.torchMode = AVCaptureTorchModeOff;
  }
  [d unlockForConfiguration];
  return CAMERA_OK;
#else
  (void)ctx; (void)enabled; (void)intensity;
  return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
#endif
}

camera_error_t camera_hal_set_zoom(camera_context_t* ctx, float factor) {
#if TARGET_OS_IOS
  if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;
  AVCaptureDevice* d = CTX(ctx).device;
  if (!d) return CAMERA_ERROR_NOT_INITIALIZED;
  NSError* err = nil;
  if (![d lockForConfiguration:&err] || err) return CAMERA_ERROR_CONFIGURATION_FAILED;
  d.videoZoomFactor = MAX(1.0f, factor);
  [d unlockForConfiguration];
  return CAMERA_OK;
#else
  (void)ctx; (void)factor;
  return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
#endif
}

// ── Capture / video / audio / stream: texture + writer plumbing is roadmap ──

camera_error_t camera_hal_capture_photo(camera_context_t* ctx, int32_t fmt, const char* path) {
  (void)ctx; (void)fmt; (void)path; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}
camera_error_t camera_hal_start_burst(camera_context_t* ctx, int32_t fmt, int32_t n) {
  (void)ctx; (void)fmt; (void)n; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}
camera_error_t camera_hal_stop_burst(camera_context_t* ctx) {
  (void)ctx; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}
camera_error_t camera_hal_capture_bracket(camera_context_t* ctx, const float* ev, int32_t n, int32_t fmt) {
  (void)ctx; (void)ev; (void)n; (void)fmt; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}
camera_error_t camera_hal_set_video_config(camera_context_t* ctx, int32_t w, int32_t h, int32_t fps, int32_t codec, int64_t br, int32_t stab, int32_t cp) {
  (void)ctx; (void)w; (void)h; (void)fps; (void)codec; (void)br; (void)stab; (void)cp;
  return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}
camera_error_t camera_hal_start_recording(camera_context_t* ctx, const char* path) {
  (void)ctx; (void)path; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}
camera_error_t camera_hal_pause_recording(camera_context_t* ctx) {
  (void)ctx; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}
camera_error_t camera_hal_resume_recording(camera_context_t* ctx) {
  (void)ctx; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}
camera_error_t camera_hal_stop_recording(camera_context_t* ctx) {
  (void)ctx; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}
camera_error_t camera_hal_set_audio_enabled(camera_context_t* ctx, bool enabled) {
  (void)ctx; (void)enabled; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}
camera_error_t camera_hal_set_audio_gain(camera_context_t* ctx, float gain) {
  (void)ctx; (void)gain; return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}
camera_error_t camera_hal_start_image_stream(camera_context_t* ctx, int32_t w, int32_t h, int32_t fps, camera_frame_callback_t cb, void* ud) {
  (void)w; (void)h; (void)fps; (void)cb; (void)ud;
  if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;
  CPAppleContext* c = CTX(ctx);
  if (!c.session || !c.device) return CAMERA_ERROR_NOT_INITIALIZED;

  CPFrameDelegate* del = [CPFrameDelegate new];
  c.frameDelegate = del;
  c.frameQueue = dispatch_queue_create("camera_pro.frames", DISPATCH_QUEUE_SERIAL);

  AVCaptureVideoDataOutput* out = [[AVCaptureVideoDataOutput alloc] init];
  out.videoSettings = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)
  };
  out.alwaysDiscardsLateVideoFrames = YES;
  [out setSampleBufferDelegate:del queue:c.frameQueue];
  if ([c.session canAddOutput:out]) [c.session addOutput:out];
  c.dataOutput = out;

  // Keep preview frames small for cheap FFI polling.
  if ([c.session canSetSessionPreset:AVCaptureSessionPreset640x480]) {
    c.session.sessionPreset = AVCaptureSessionPreset640x480;
  }

  // Request camera authorization (shows the system prompt on first use), then
  // start the session once granted.
  __weak CPAppleContext* weakCtx = c;
  [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                           completionHandler:^(BOOL granted) {
    CPAppleContext* strongCtx = weakCtx;
    if (!strongCtx) return;
    if (granted) {
      [strongCtx.session startRunning];
    } else if (strongCtx.errorCb) {
      strongCtx.errorCb(strongCtx.errorUd, CAMERA_ERROR_PERMISSION_DENIED,
                        "Camera permission denied");
    }
  }];

  set_state(c, CAMERA_STATE_PREVIEWING);
  return CAMERA_OK;
}

camera_error_t camera_hal_stop_image_stream(camera_context_t* ctx) {
  if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;
  CPAppleContext* c = CTX(ctx);
  [c.session stopRunning];
  if (c.dataOutput) [c.session removeOutput:c.dataOutput];
  c.dataOutput = nil;
  c.frameDelegate = nil;
  return CAMERA_OK;
}

camera_error_t camera_hal_set_error_callback(camera_context_t* ctx, camera_error_callback_t cb, void* ud) {
  if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;
  CPAppleContext* c = CTX(ctx);
  c.errorCb = cb; c.errorUd = ud;
  return CAMERA_OK;
}
camera_error_t camera_hal_set_state_callback(camera_context_t* ctx, camera_state_callback_t cb, void* ud) {
  if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;
  CPAppleContext* c = CTX(ctx);
  c.stateCb = cb; c.stateUd = ud;
  return CAMERA_OK;
}

// ── Flat FFI accessors ──────────────────────────────────────────────────────

int32_t camera_pro_apple_device_count(camera_context_t* ctx) {
  if (!ctx) return 0;
  return (int32_t)CTX(ctx).devices.count;
}

int32_t camera_pro_apple_device_name(camera_context_t* ctx, int32_t index, char* out, int32_t cap) {
  if (!ctx) return 0;
  CPAppleContext* c = CTX(ctx);
  if (index < 0 || index >= (int32_t)c.devices.count) return copy_utf8(@"", out, cap);
  return copy_utf8(c.devices[index].localizedName, out, cap);
}

int32_t camera_pro_apple_device_position(camera_context_t* ctx, int32_t index) {
  if (!ctx) return 0;
  CPAppleContext* c = CTX(ctx);
  if (index < 0 || index >= (int32_t)c.devices.count) return 0;
  switch (c.devices[index].position) {
    case AVCaptureDevicePositionBack: return 1;
    case AVCaptureDevicePositionFront: return 2;
    default: return 0;
  }
}

void camera_pro_apple_get_caps(camera_context_t* ctx, camera_pro_apple_caps_t* out) {
  if (!ctx || !out) return;
  *out = CTX(ctx).caps;
}

int32_t camera_pro_apple_platform_name(camera_context_t* ctx, char* out, int32_t cap) {
  if (!ctx) return 0;
  return copy_utf8(CTX(ctx).platformName, out, cap);
}

int32_t camera_pro_apple_active_device_name(camera_context_t* ctx, char* out, int32_t cap) {
  if (!ctx) return 0;
  return copy_utf8(CTX(ctx).deviceName, out, cap);
}

int64_t camera_pro_apple_frame_count(camera_context_t* ctx) {
  if (!ctx) return 0;
  CPFrameDelegate* d = CTX(ctx).frameDelegate;
  return d ? d.frameCount : 0;
}

int32_t camera_pro_apple_copy_latest_frame(camera_context_t* ctx, uint8_t* out,
                                           int32_t cap, int32_t* width,
                                           int32_t* height) {
  if (!ctx || !out) return 0;
  CPFrameDelegate* d = CTX(ctx).frameDelegate;
  if (!d) return 0;
  int32_t bytes = 0;
  [d.lock lock];
  if (d.latest && d.width > 0 && d.height > 0) {
    const int32_t need = (int32_t)d.latest.length;
    if (need <= cap) {
      memcpy(out, d.latest.bytes, (size_t)need);
      if (width) *width = d.width;
      if (height) *height = d.height;
      bytes = need;
    }
  }
  [d.lock unlock];
  return bytes;
}
