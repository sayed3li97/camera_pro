/*
 * camera_hal_windows.cpp — Windows Media Foundation backend implementing
 * camera_hal.h.
 *
 * Device enumeration (MFEnumDeviceSources), open (IMFActivate ->
 * IMFMediaSource -> IMFSourceReader), capability query and the four manual
 * controls (shutter/ISO/white balance/focus) are real, driven through the
 * DirectShow-era IAMCameraControl / IAMVideoProcAmp interfaces that Media
 * Foundation video-capture sources expose via QueryInterface. Many UVC
 * drivers do not implement one or both interfaces; in that case the affected
 * controls are honestly reported as CAMERA_ERROR_FEATURE_NOT_SUPPORTED.
 *
 * Units, as defined by the DirectShow property semantics:
 *   - CameraControl_Exposure is log2(seconds): value -13 = 1/8192 s, 1 = 2 s.
 *     We convert to/from the HAL's nanoseconds at the boundary.
 *   - VideoProcAmp_WhiteBalance is degrees Kelvin on conformant drivers.
 *   - VideoProcAmp_Gain is a driver-defined raw gain range, NOT true ISO;
 *     the capability struct reports the raw range and set_iso clamps into it.
 *   - CameraControl_Focus is a driver-defined range; set_focus_distance
 *     treats its input as normalized 0..1 and maps it into that range.
 *
 * The frame path (source-reader pull loop feeding the frame callback) is
 * follow-up work; camera_hal_start_image_stream returns FEATURE_NOT_SUPPORTED
 * rather than pretending frames flow. Photo capture, video recording, audio,
 * flash, zoom, and metering are likewise honestly stubbed.
 *
 * COM lifetime is managed manually (no wrl/atl): every interface acquired is
 * Release()d in close/destroy, the IMFActivate array is CoTaskMemFree()d, and
 * MFShutdown()/CoUninitialize() pair with create's MFStartup()/CoInitializeEx.
 *
 * Verification status: compiles on CI windows runner (MSVC cl /W4, C++17);
 * not yet run against camera hardware.
 *
 * Copyright (c) 2026 camera_pro contributors. BSD-3-Clause.
 */
#ifdef _WIN32

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif

#include <windows.h>

#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <ks.h>
#include <ksmedia.h>
#include <strmif.h>

#include <cmath>
#include <cstdint>
#include <cstring>
#include <new>

#include "../../hal/camera_hal.h"

#pragma comment(lib, "mf.lib")
#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfreadwrite.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "ole32.lib")

// ── Context ─────────────────────────────────────────────────────────────────

struct camera_context {
    // COM state — every pointer here is manually Release()d.
    IMFActivate**     devices      = nullptr;  // owned array from MFEnumDeviceSources
    UINT32            device_count = 0;
    IMFMediaSource*   source       = nullptr;
    IMFSourceReader*  reader       = nullptr;
    IAMCameraControl* cam_ctrl     = nullptr;  // may be null (driver-dependent)
    IAMVideoProcAmp*  proc_amp     = nullptr;  // may be null (driver-dependent)

    bool    mf_started     = false;  // MFStartup succeeded → MFShutdown in destroy
    bool    co_initialized = false;  // CoInitializeEx succeeded → CoUninitialize

    camera_state_t        state = CAMERA_STATE_UNINITIALIZED;
    camera_capabilities_t caps{};   // resolved in open(); pointers into buffers below
    bool                  caps_valid = false;

    char device_name[256] = "";

    camera_error_callback_t error_cb = nullptr;
    void*                   error_ud = nullptr;
    camera_state_callback_t state_cb = nullptr;
    void*                   state_ud = nullptr;
};

static const char kPlatformName[] = "Windows, Media Foundation";

// ── Helpers ─────────────────────────────────────────────────────────────────

static void set_state(camera_context_t* ctx, camera_state_t s) {
    ctx->state = s;
    if (ctx->state_cb) ctx->state_cb(ctx->state_ud, (int32_t)s);
}

template <typename T>
static void safe_release(T*& p) {
    if (p) {
        p->Release();
        p = nullptr;
    }
}

static void release_device_list(camera_context_t* ctx) {
    if (ctx->devices) {
        for (UINT32 i = 0; i < ctx->device_count; i++) {
            if (ctx->devices[i]) ctx->devices[i]->Release();
        }
        CoTaskMemFree(ctx->devices);
        ctx->devices = nullptr;
    }
    ctx->device_count = 0;
}

static void release_open_device(camera_context_t* ctx) {
    safe_release(ctx->cam_ctrl);
    safe_release(ctx->proc_amp);
    safe_release(ctx->reader);
    if (ctx->source) {
        ctx->source->Shutdown();
        ctx->source->Release();
        ctx->source = nullptr;
    }
    ctx->caps_valid = false;
}

static long clamp_long(long v, long lo, long hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

/* Queries a control range and reports whether manual mode is available. */
static bool camera_ctrl_range(IAMCameraControl* c, long prop, long* mn, long* mx,
                              long* step, long* def) {
    if (!c) return false;
    long caps_flags = 0;
    HRESULT hr = c->GetRange(prop, mn, mx, step, def, &caps_flags);
    return SUCCEEDED(hr) && (caps_flags & CameraControl_Flags_Manual) != 0;
}

static bool proc_amp_range(IAMVideoProcAmp* a, long prop, long* mn, long* mx,
                           long* step, long* def) {
    if (!a) return false;
    long caps_flags = 0;
    HRESULT hr = a->GetRange(prop, mn, mx, step, def, &caps_flags);
    return SUCCEEDED(hr) && (caps_flags & VideoProcAmp_Flags_Manual) != 0;
}

/* Builds the cached capability struct from the live control interfaces. */
static void resolve_caps(camera_context_t* ctx) {
    camera_capabilities_t caps;
    memset(&caps, 0, sizeof(caps));

    long mn = 0, mx = 0, step = 0, def = 0;

    // Shutter: CameraControl_Exposure is log2(seconds).
    if (camera_ctrl_range(ctx->cam_ctrl, CameraControl_Exposure, &mn, &mx, &step, &def)) {
        caps.shutter.supported = true;
        caps.shutter.min_ns = (int64_t)(ldexp(1.0, (int)mn) * 1e9);
        caps.shutter.max_ns = (int64_t)(ldexp(1.0, (int)mx) * 1e9);
    }

    // Focus: driver-defined units; set_focus_distance normalizes 0..1 into the
    // raw range, so the capability advertises the normalized bounds.
    if (camera_ctrl_range(ctx->cam_ctrl, CameraControl_Focus, &mn, &mx, &step, &def)) {
        caps.focus.supported = true;
        caps.focus.min_diopters = 0.0f;
        caps.focus.max_diopters = 1.0f;
    }

    // White balance: degrees Kelvin on conformant UVC drivers.
    if (proc_amp_range(ctx->proc_amp, VideoProcAmp_WhiteBalance, &mn, &mx, &step, &def)) {
        caps.white_balance.supported = true;
        caps.white_balance.min_kelvin = (int32_t)mn;
        caps.white_balance.max_kelvin = (int32_t)mx;
    }

    // "ISO": VideoProcAmp_Gain raw range (driver-defined units, not true ISO).
    if (proc_amp_range(ctx->proc_amp, VideoProcAmp_Gain, &mn, &mx, &step, &def)) {
        caps.iso.supported = true;
        caps.iso.min_iso = (int32_t)mn;
        caps.iso.max_iso = (int32_t)mx;
    }

    caps.platform_name  = kPlatformName;
    caps.device_name    = ctx->device_name;
    caps.hardware_level = -1;

    ctx->caps = caps;
    ctx->caps_valid = true;
}

static void cache_device_name(camera_context_t* ctx, IMFActivate* activate) {
    strcpy_s(ctx->device_name, sizeof(ctx->device_name), "Unknown camera");
    WCHAR* wname = nullptr;
    UINT32 wlen = 0;
    if (SUCCEEDED(activate->GetAllocatedString(MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME,
                                               &wname, &wlen)) && wname) {
        int n = WideCharToMultiByte(CP_UTF8, 0, wname, -1, ctx->device_name,
                                    (int)sizeof(ctx->device_name), nullptr, nullptr);
        if (n <= 0) {
            strcpy_s(ctx->device_name, sizeof(ctx->device_name), "Unknown camera");
        }
        CoTaskMemFree(wname);
    }
}

extern "C" {

// ── Lifecycle ───────────────────────────────────────────────────────────────

camera_error_t camera_hal_create(camera_context_t** ctx) {
    if (!ctx) return CAMERA_ERROR_INVALID_PARAMETER;
    camera_context_t* c = new (std::nothrow) camera_context();
    if (!c) return CAMERA_ERROR_OUT_OF_MEMORY;

    HRESULT co_hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    // S_OK / S_FALSE → we own a matching CoUninitialize. RPC_E_CHANGED_MODE →
    // COM already up in another mode; usable, but not ours to tear down.
    c->co_initialized = SUCCEEDED(co_hr);
    if (FAILED(co_hr) && co_hr != RPC_E_CHANGED_MODE) {
        delete c;
        return CAMERA_ERROR_CONFIGURATION_FAILED;
    }

    HRESULT hr = MFStartup(MF_VERSION);
    if (FAILED(hr)) {
        if (c->co_initialized) CoUninitialize();
        delete c;
        return CAMERA_ERROR_CONFIGURATION_FAILED;
    }
    c->mf_started = true;
    c->state = CAMERA_STATE_UNINITIALIZED;
    *ctx = c;
    return CAMERA_OK;
}

camera_error_t camera_hal_destroy(camera_context_t* ctx) {
    if (!ctx) return CAMERA_ERROR_INVALID_PARAMETER;
    release_open_device(ctx);
    release_device_list(ctx);
    if (ctx->mf_started) MFShutdown();
    if (ctx->co_initialized) CoUninitialize();
    delete ctx;
    return CAMERA_OK;
}

camera_error_t camera_hal_enumerate_devices(camera_context_t* ctx, int32_t* count) {
    if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;
    release_device_list(ctx);

    IMFAttributes* attrs = nullptr;
    HRESULT hr = MFCreateAttributes(&attrs, 1);
    if (FAILED(hr)) return CAMERA_ERROR_CONFIGURATION_FAILED;

    hr = attrs->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
                        MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
    if (SUCCEEDED(hr)) {
        hr = MFEnumDeviceSources(attrs, &ctx->devices, &ctx->device_count);
    }
    attrs->Release();

    if (FAILED(hr)) {
        ctx->devices = nullptr;
        ctx->device_count = 0;
        return CAMERA_ERROR_CONFIGURATION_FAILED;
    }
    if (count) *count = (int32_t)ctx->device_count;
    return CAMERA_OK;
}

camera_error_t camera_hal_open(camera_context_t* ctx, int32_t device_index,
                               int64_t flutter_texture_id) {
    (void)flutter_texture_id;  // texture sink is follow-up work
    if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;

    if (!ctx->devices) {
        int32_t n = 0;
        camera_error_t err = camera_hal_enumerate_devices(ctx, &n);
        if (err != CAMERA_OK) return err;
    }
    if (device_index < 0 || (UINT32)device_index >= ctx->device_count) {
        return CAMERA_ERROR_DEVICE_NOT_FOUND;
    }

    release_open_device(ctx);  // reopening replaces any previous device

    IMFActivate* activate = ctx->devices[device_index];
    cache_device_name(ctx, activate);

    HRESULT hr = activate->ActivateObject(IID_PPV_ARGS(&ctx->source));
    if (FAILED(hr)) {
        return (hr == E_ACCESSDENIED) ? CAMERA_ERROR_PERMISSION_DENIED
                                      : CAMERA_ERROR_DEVICE_IN_USE;
    }

    hr = MFCreateSourceReaderFromMediaSource(ctx->source, nullptr, &ctx->reader);
    if (FAILED(hr)) {
        release_open_device(ctx);
        return CAMERA_ERROR_CONFIGURATION_FAILED;
    }

    // Manual-control interfaces. Some drivers implement neither; the controls
    // then report FEATURE_NOT_SUPPORTED instead of faking success.
    if (FAILED(ctx->source->QueryInterface(IID_PPV_ARGS(&ctx->cam_ctrl)))) {
        ctx->cam_ctrl = nullptr;
    }
    if (FAILED(ctx->source->QueryInterface(IID_PPV_ARGS(&ctx->proc_amp)))) {
        ctx->proc_amp = nullptr;
    }

    resolve_caps(ctx);
    set_state(ctx, CAMERA_STATE_OPENED);
    return CAMERA_OK;
}

camera_error_t camera_hal_close(camera_context_t* ctx) {
    if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;
    release_open_device(ctx);
    set_state(ctx, CAMERA_STATE_DISPOSED);
    return CAMERA_OK;
}

camera_error_t camera_hal_get_capabilities(camera_context_t* ctx,
                                           camera_capabilities_t* caps) {
    if (!ctx || !caps) return CAMERA_ERROR_INVALID_PARAMETER;
    if (!ctx->caps_valid) {
        memset(caps, 0, sizeof(*caps));
        caps->platform_name  = kPlatformName;
        caps->device_name    = "No camera opened";
        caps->hardware_level = -1;
        return CAMERA_OK;
    }
    *caps = ctx->caps;  // pointers reference ctx-owned buffers / static strings
    return CAMERA_OK;
}

// ── Preview ─────────────────────────────────────────────────────────────────
// State transitions mirror the conformant stub; actual frame delivery is the
// image-stream follow-up (source-reader pull loop), not faked here.

camera_error_t camera_hal_start_preview(camera_context_t* ctx) {
    if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;
    set_state(ctx, CAMERA_STATE_PREVIEWING);
    return CAMERA_OK;
}

camera_error_t camera_hal_stop_preview(camera_context_t* ctx) {
    if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;
    set_state(ctx, CAMERA_STATE_OPENED);
    return CAMERA_OK;
}

camera_error_t camera_hal_set_preview_resolution(camera_context_t* ctx,
                                                 int32_t width, int32_t height) {
    (void)ctx; (void)width; (void)height;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

// ── Exposure ────────────────────────────────────────────────────────────────

camera_error_t camera_hal_set_exposure_mode(camera_context_t* ctx, int32_t mode) {
    (void)ctx; (void)mode;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

camera_error_t camera_hal_set_shutter_speed_ns(camera_context_t* ctx,
                                               int64_t duration_ns) {
    if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;
    if (duration_ns <= 0) return CAMERA_ERROR_INVALID_PARAMETER;

    long mn = 0, mx = 0, step = 0, def = 0;
    if (!camera_ctrl_range(ctx->cam_ctrl, CameraControl_Exposure, &mn, &mx, &step, &def)) {
        return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
    }

    // CameraControl_Exposure is log2(seconds).
    const double seconds = (double)duration_ns / 1e9;
    long v = std::lround(std::log2(seconds));
    v = clamp_long(v, mn, mx);

    HRESULT hr = ctx->cam_ctrl->Set(CameraControl_Exposure, v,
                                    CameraControl_Flags_Manual);
    return SUCCEEDED(hr) ? CAMERA_OK : CAMERA_ERROR_CONFIGURATION_FAILED;
}

camera_error_t camera_hal_set_iso(camera_context_t* ctx, int32_t iso) {
    if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;

    long mn = 0, mx = 0, step = 0, def = 0;
    if (!proc_amp_range(ctx->proc_amp, VideoProcAmp_Gain, &mn, &mx, &step, &def)) {
        return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
    }

    // Gain units are driver-defined; the capability struct exposed the raw
    // range as [min_iso, max_iso], so the input is clamped straight into it.
    long v = clamp_long((long)iso, mn, mx);
    HRESULT hr = ctx->proc_amp->Set(VideoProcAmp_Gain, v, VideoProcAmp_Flags_Manual);
    return SUCCEEDED(hr) ? CAMERA_OK : CAMERA_ERROR_CONFIGURATION_FAILED;
}

camera_error_t camera_hal_set_exposure_compensation(camera_context_t* ctx, float ev) {
    (void)ctx; (void)ev;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

camera_error_t camera_hal_lock_exposure(camera_context_t* ctx) {
    (void)ctx;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

camera_error_t camera_hal_unlock_exposure(camera_context_t* ctx) {
    (void)ctx;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

camera_error_t camera_hal_set_metering_mode(camera_context_t* ctx, int32_t mode) {
    (void)ctx; (void)mode;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

camera_error_t camera_hal_set_metering_point(camera_context_t* ctx, float x, float y) {
    (void)ctx; (void)x; (void)y;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

// ── Focus ───────────────────────────────────────────────────────────────────

camera_error_t camera_hal_set_focus_mode(camera_context_t* ctx, int32_t mode) {
    (void)ctx; (void)mode;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

camera_error_t camera_hal_set_focus_distance(camera_context_t* ctx, float diopters) {
    if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;

    long mn = 0, mx = 0, step = 0, def = 0;
    if (!camera_ctrl_range(ctx->cam_ctrl, CameraControl_Focus, &mn, &mx, &step, &def)) {
        return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
    }

    // CameraControl_Focus units are driver-defined; treat the input as a
    // normalized 0..1 position and map it into the driver's raw range.
    float pos = diopters;
    if (pos < 0.0f) pos = 0.0f;
    if (pos > 1.0f) pos = 1.0f;
    long v = mn + std::lround((double)pos * (double)(mx - mn));
    v = clamp_long(v, mn, mx);

    HRESULT hr = ctx->cam_ctrl->Set(CameraControl_Focus, v,
                                    CameraControl_Flags_Manual);
    return SUCCEEDED(hr) ? CAMERA_OK : CAMERA_ERROR_CONFIGURATION_FAILED;
}

camera_error_t camera_hal_set_focus_point(camera_context_t* ctx, float x, float y) {
    (void)ctx; (void)x; (void)y;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

camera_error_t camera_hal_lock_focus(camera_context_t* ctx) {
    (void)ctx;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

camera_error_t camera_hal_unlock_focus(camera_context_t* ctx) {
    (void)ctx;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

// ── White balance ───────────────────────────────────────────────────────────

camera_error_t camera_hal_set_wb_mode(camera_context_t* ctx, int32_t mode) {
    (void)ctx; (void)mode;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

camera_error_t camera_hal_set_wb_temperature(camera_context_t* ctx, int32_t kelvin) {
    if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;

    long mn = 0, mx = 0, step = 0, def = 0;
    if (!proc_amp_range(ctx->proc_amp, VideoProcAmp_WhiteBalance, &mn, &mx, &step, &def)) {
        return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
    }

    long v = clamp_long((long)kelvin, mn, mx);
    HRESULT hr = ctx->proc_amp->Set(VideoProcAmp_WhiteBalance, v,
                                    VideoProcAmp_Flags_Manual);
    return SUCCEEDED(hr) ? CAMERA_OK : CAMERA_ERROR_CONFIGURATION_FAILED;
}

camera_error_t camera_hal_set_wb_tint(camera_context_t* ctx, float green_magenta,
                                      float blue_amber) {
    (void)ctx; (void)green_magenta; (void)blue_amber;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

camera_error_t camera_hal_lock_white_balance(camera_context_t* ctx) {
    (void)ctx;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

// ── Flash / torch ───────────────────────────────────────────────────────────
// Desktop webcams have no flash hardware exposed through MF; honest no.

camera_error_t camera_hal_set_flash_mode(camera_context_t* ctx, int32_t mode) {
    (void)ctx; (void)mode;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

camera_error_t camera_hal_set_torch(camera_context_t* ctx, bool enabled,
                                    float intensity) {
    (void)ctx; (void)enabled; (void)intensity;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

// ── Zoom ────────────────────────────────────────────────────────────────────

camera_error_t camera_hal_set_zoom(camera_context_t* ctx, float factor) {
    (void)ctx; (void)factor;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

// ── Photo capture (follow-up work) ──────────────────────────────────────────

camera_error_t camera_hal_capture_photo(camera_context_t* ctx, int32_t format,
                                        const char* path) {
    (void)ctx; (void)format; (void)path;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

camera_error_t camera_hal_start_burst(camera_context_t* ctx, int32_t format,
                                      int32_t max_count) {
    (void)ctx; (void)format; (void)max_count;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

camera_error_t camera_hal_stop_burst(camera_context_t* ctx) {
    (void)ctx;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

camera_error_t camera_hal_capture_bracket(camera_context_t* ctx,
                                          const float* ev_values, int32_t count,
                                          int32_t format) {
    (void)ctx; (void)ev_values; (void)count; (void)format;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

// ── Video (follow-up work: IMFSinkWriter pipeline) ──────────────────────────

camera_error_t camera_hal_set_video_config(camera_context_t* ctx, int32_t width,
                                           int32_t height, int32_t fps,
                                           int32_t codec, int64_t bitrate,
                                           int32_t stabilization,
                                           int32_t color_profile) {
    (void)ctx; (void)width; (void)height; (void)fps; (void)codec; (void)bitrate;
    (void)stabilization; (void)color_profile;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

camera_error_t camera_hal_start_recording(camera_context_t* ctx, const char* path) {
    (void)ctx; (void)path;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

camera_error_t camera_hal_pause_recording(camera_context_t* ctx) {
    (void)ctx;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

camera_error_t camera_hal_resume_recording(camera_context_t* ctx) {
    (void)ctx;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

camera_error_t camera_hal_stop_recording(camera_context_t* ctx) {
    (void)ctx;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

// ── Audio ───────────────────────────────────────────────────────────────────

camera_error_t camera_hal_set_audio_enabled(camera_context_t* ctx, bool enabled) {
    (void)ctx; (void)enabled;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

camera_error_t camera_hal_set_audio_gain(camera_context_t* ctx, float gain) {
    (void)ctx; (void)gain;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

// ── Image stream ────────────────────────────────────────────────────────────
// Honest FEATURE_NOT_SUPPORTED for now. The real implementation is a worker
// thread running an IMFSourceReader::ReadSample pull loop on the ctx->reader
// (converting to a HAL pixel format and invoking camera_frame_callback_t);
// that is scheduled follow-up work, and until it lands this backend must not
// pretend frames are flowing.

camera_error_t camera_hal_start_image_stream(camera_context_t* ctx, int32_t width,
                                             int32_t height, int32_t max_fps,
                                             camera_frame_callback_t callback,
                                             void* user_data) {
    (void)ctx; (void)width; (void)height; (void)max_fps; (void)callback;
    (void)user_data;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

camera_error_t camera_hal_stop_image_stream(camera_context_t* ctx) {
    (void)ctx;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

// ── Callback registration ───────────────────────────────────────────────────

camera_error_t camera_hal_set_error_callback(camera_context_t* ctx,
                                             camera_error_callback_t callback,
                                             void* user_data) {
    if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;
    ctx->error_cb = callback;
    ctx->error_ud = user_data;
    return CAMERA_OK;
}

camera_error_t camera_hal_set_state_callback(camera_context_t* ctx,
                                             camera_state_callback_t callback,
                                             void* user_data) {
    if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;
    ctx->state_cb = callback;
    ctx->state_ud = user_data;
    return CAMERA_OK;
}

}  // extern "C"

#else  /* !_WIN32 */

/* Non-Windows build: this backend is excluded from the link (the stub or a
 * native backend is used instead); keep the translation unit non-empty. */
typedef int camera_hal_windows_not_built_on_this_platform_t;

#endif /* _WIN32 */
