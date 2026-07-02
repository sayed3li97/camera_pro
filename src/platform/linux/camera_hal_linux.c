/*
 * camera_hal_linux.c — V4L2 backend implementing camera_hal.h.
 *
 * Real Video4Linux2 implementation for Linux desktops and SBCs:
 *   - Device enumeration over /dev/video0..63 (VIDIOC_QUERYCAP, capture-capable
 *     nodes only).
 *   - Control discovery via the VIDIOC_QUERYCTRL / V4L2_CTRL_FLAG_NEXT_CTRL
 *     walk, caching exposure, focus, white-balance and gain ranges so the
 *     reported camera_capabilities_t reflects what the driver actually offers.
 *   - Manual controls mapped onto V4L2 CIDs (shutter → EXPOSURE_ABSOLUTE in
 *     100 µs units, ISO → GAIN, WB → WHITE_BALANCE_TEMPERATURE, focus →
 *     FOCUS_ABSOLUTE). Anything the driver did not enumerate returns
 *     CAMERA_ERROR_FEATURE_NOT_SUPPORTED — never fake success.
 *   - Image streaming with 4 mmap'd buffers and a pthread poll()/DQBUF loop
 *     delivering frames through camera_frame_callback_t.
 * Photo/video/audio pipelines are not wired yet and report NotSupported.
 *
 * Verification status: compiles on CI linux runner; not yet run against
 * camera hardware.
 *
 * Copyright (c) 2026 camera_pro contributors. BSD-3-Clause.
 */
#ifdef __linux__

#include "../../hal/camera_hal.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <linux/videodev2.h>

/* ── Constants ───────────────────────────────────────────────────────────── */

#define CP_MAX_DEVICES   64
#define CP_PATH_MAX      32
#define CP_CARD_NAME_MAX 64
#define CP_NUM_BUFFERS   4
#define CP_POLL_TIMEOUT_MS 100

/* V4L2_CID_EXPOSURE_ABSOLUTE is in units of 100 µs. */
#define CP_EXPOSURE_UNIT_NS 100000LL

/* ── Control cache ───────────────────────────────────────────────────────── */

typedef struct {
    bool    present;
    int32_t min;
    int32_t max;
    int32_t step;
    int32_t def;
} cp_ctrl_t;

typedef struct {
    void*  start;
    size_t length;
} cp_buffer_t;

struct camera_context {
    camera_state_t state;

    /* Enumeration results (paths owned by the context). */
    char    device_paths[CP_MAX_DEVICES][CP_PATH_MAX];
    int32_t device_count;
    bool    enumerated;

    /* Open device. */
    int     fd;
    int32_t device_index;
    char    card_name[CP_CARD_NAME_MAX];

    /* Cached V4L2 control ranges (filled at open). */
    cp_ctrl_t ctl_exposure_auto;   /* V4L2_CID_EXPOSURE_AUTO              */
    cp_ctrl_t ctl_exposure_abs;    /* V4L2_CID_EXPOSURE_ABSOLUTE          */
    cp_ctrl_t ctl_focus_auto;      /* V4L2_CID_FOCUS_AUTO                 */
    cp_ctrl_t ctl_focus_abs;       /* V4L2_CID_FOCUS_ABSOLUTE             */
    cp_ctrl_t ctl_wb_auto;         /* V4L2_CID_AUTO_WHITE_BALANCE         */
    cp_ctrl_t ctl_wb_temp;         /* V4L2_CID_WHITE_BALANCE_TEMPERATURE  */
    cp_ctrl_t ctl_gain;            /* V4L2_CID_GAIN                       */

    camera_capabilities_t caps;

    /* Image stream. */
    bool        streaming;
    pthread_t   capture_thread;
    atomic_bool capture_running;
    cp_buffer_t buffers[CP_NUM_BUFFERS];
    uint32_t    n_buffers;
    int32_t     frame_width;
    int32_t     frame_height;
    int32_t     frame_format;      /* camera_pixel_format_t */
    camera_frame_callback_t frame_cb;
    void*       frame_ud;

    /* Callbacks. */
    camera_error_callback_t error_cb;
    void*                   error_ud;
    camera_state_callback_t state_cb;
    void*                   state_ud;
};

/* ── Small helpers ───────────────────────────────────────────────────────── */

static int xioctl(int fd, unsigned long request, void* arg) {
    int r;
    do {
        r = ioctl(fd, request, arg);
    } while (r == -1 && errno == EINTR);
    return r;
}

static void set_state(camera_context_t* ctx, camera_state_t s) {
    ctx->state = s;
    if (ctx->state_cb) ctx->state_cb(ctx->state_ud, (int32_t)s);
}

static void report_error(camera_context_t* ctx, camera_error_t err, const char* msg) {
    if (ctx->error_cb) ctx->error_cb(ctx->error_ud, err, msg);
}

static int32_t clamp_i32(int64_t v, int32_t lo, int32_t hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return (int32_t)v;
}

static camera_error_t set_ctrl(int fd, uint32_t id, int32_t value) {
    struct v4l2_control c;
    memset(&c, 0, sizeof(c));
    c.id = id;
    c.value = value;
    if (xioctl(fd, VIDIOC_S_CTRL, &c) == -1) {
        return CAMERA_ERROR_CONFIGURATION_FAILED;
    }
    return CAMERA_OK;
}

static int32_t map_v4l2_format(uint32_t fourcc) {
    switch (fourcc) {
        case V4L2_PIX_FMT_NV12:   return (int32_t)CAMERA_PIXEL_FORMAT_NV12;
        case V4L2_PIX_FMT_NV21:   return (int32_t)CAMERA_PIXEL_FORMAT_NV21;
        case V4L2_PIX_FMT_YUV420: return (int32_t)CAMERA_PIXEL_FORMAT_YUV420P;
        case V4L2_PIX_FMT_GREY:   return (int32_t)CAMERA_PIXEL_FORMAT_GRAY8;
#ifdef V4L2_PIX_FMT_RGBA32
        case V4L2_PIX_FMT_RGBA32: return (int32_t)CAMERA_PIXEL_FORMAT_RGBA8888;
#endif
#ifdef V4L2_PIX_FMT_ABGR32
        case V4L2_PIX_FMT_ABGR32: return (int32_t)CAMERA_PIXEL_FORMAT_BGRA8888;
#endif
        default:
            /* YUYV and other packed formats have no camera_pixel_format_t
             * entry yet; report UNKNOWN honestly rather than mislabelling. */
            return (int32_t)CAMERA_PIXEL_FORMAT_UNKNOWN;
    }
}

/* ── Control discovery ───────────────────────────────────────────────────── */

static void cache_ctrl_from_query(camera_context_t* ctx, const struct v4l2_queryctrl* qc) {
    if (qc->flags & V4L2_CTRL_FLAG_DISABLED) return;

    cp_ctrl_t* slot = NULL;
    switch (qc->id) {
        case V4L2_CID_EXPOSURE_AUTO:              slot = &ctx->ctl_exposure_auto; break;
        case V4L2_CID_EXPOSURE_ABSOLUTE:          slot = &ctx->ctl_exposure_abs;  break;
        case V4L2_CID_FOCUS_AUTO:                 slot = &ctx->ctl_focus_auto;    break;
        case V4L2_CID_FOCUS_ABSOLUTE:             slot = &ctx->ctl_focus_abs;     break;
        case V4L2_CID_AUTO_WHITE_BALANCE:         slot = &ctx->ctl_wb_auto;       break;
        case V4L2_CID_WHITE_BALANCE_TEMPERATURE:  slot = &ctx->ctl_wb_temp;       break;
        case V4L2_CID_GAIN:                       slot = &ctx->ctl_gain;          break;
        default: return;
    }
    slot->present = true;
    slot->min  = qc->minimum;
    slot->max  = qc->maximum;
    slot->step = qc->step;
    slot->def  = qc->default_value;
}

static void probe_ctrl(camera_context_t* ctx, uint32_t id) {
    struct v4l2_queryctrl qc;
    memset(&qc, 0, sizeof(qc));
    qc.id = id;
    if (xioctl(ctx->fd, VIDIOC_QUERYCTRL, &qc) == 0) {
        cache_ctrl_from_query(ctx, &qc);
    }
}

static void enumerate_controls(camera_context_t* ctx) {
    memset(&ctx->ctl_exposure_auto, 0, sizeof(cp_ctrl_t));
    memset(&ctx->ctl_exposure_abs,  0, sizeof(cp_ctrl_t));
    memset(&ctx->ctl_focus_auto,    0, sizeof(cp_ctrl_t));
    memset(&ctx->ctl_focus_abs,     0, sizeof(cp_ctrl_t));
    memset(&ctx->ctl_wb_auto,       0, sizeof(cp_ctrl_t));
    memset(&ctx->ctl_wb_temp,       0, sizeof(cp_ctrl_t));
    memset(&ctx->ctl_gain,          0, sizeof(cp_ctrl_t));

    bool any = false;
    struct v4l2_queryctrl qc;
    memset(&qc, 0, sizeof(qc));
    qc.id = V4L2_CTRL_FLAG_NEXT_CTRL;
    while (xioctl(ctx->fd, VIDIOC_QUERYCTRL, &qc) == 0) {
        any = true;
        cache_ctrl_from_query(ctx, &qc);
        qc.id |= V4L2_CTRL_FLAG_NEXT_CTRL;
    }

    if (!any) {
        /* Old drivers without NEXT_CTRL support: probe the CIDs we care about
         * individually. */
        probe_ctrl(ctx, V4L2_CID_EXPOSURE_AUTO);
        probe_ctrl(ctx, V4L2_CID_EXPOSURE_ABSOLUTE);
        probe_ctrl(ctx, V4L2_CID_FOCUS_AUTO);
        probe_ctrl(ctx, V4L2_CID_FOCUS_ABSOLUTE);
        probe_ctrl(ctx, V4L2_CID_AUTO_WHITE_BALANCE);
        probe_ctrl(ctx, V4L2_CID_WHITE_BALANCE_TEMPERATURE);
        probe_ctrl(ctx, V4L2_CID_GAIN);
    }
}

static void fill_capabilities(camera_context_t* ctx) {
    camera_capabilities_t* c = &ctx->caps;
    memset(c, 0, sizeof(*c));

    if (ctx->ctl_exposure_abs.present) {
        c->shutter.supported = true;
        c->shutter.min_ns = (int64_t)ctx->ctl_exposure_abs.min * CP_EXPOSURE_UNIT_NS;
        c->shutter.max_ns = (int64_t)ctx->ctl_exposure_abs.max * CP_EXPOSURE_UNIT_NS;
    }
    if (ctx->ctl_gain.present) {
        /* V4L2 exposes sensor gain, not calibrated ISO; the range is the
         * driver's raw gain range. */
        c->iso.supported = true;
        c->iso.min_iso = ctx->ctl_gain.min;
        c->iso.max_iso = ctx->ctl_gain.max;
    }
    if (ctx->ctl_focus_abs.present) {
        /* FOCUS_ABSOLUTE is a driver-specific range, not diopters; the HAL
         * accepts a normalized 0..1 position (see set_focus_distance). */
        c->focus.supported = true;
        c->focus.min_diopters = 0.0f;
        c->focus.max_diopters = 1.0f;
    }
    if (ctx->ctl_wb_temp.present) {
        c->white_balance.supported = true;
        c->white_balance.min_kelvin = ctx->ctl_wb_temp.min;
        c->white_balance.max_kelvin = ctx->ctl_wb_temp.max;
    }
    /* No EV compensation, zoom, flash or advanced/video pipelines are wired
     * on this backend yet — leave them reported as unsupported. */
    c->zoom.min_zoom = 1.0f;
    c->zoom.max_zoom = 1.0f;

    c->platform_name  = "Linux, V4L2";
    c->device_name    = ctx->card_name;
    c->hardware_level = -1;
}

/* ── Lifecycle ───────────────────────────────────────────────────────────── */

camera_error_t camera_hal_create(camera_context_t** ctx) {
    if (!ctx) return CAMERA_ERROR_INVALID_PARAMETER;
    camera_context_t* c = (camera_context_t*)calloc(1, sizeof(camera_context_t));
    if (!c) return CAMERA_ERROR_OUT_OF_MEMORY;
    c->state = CAMERA_STATE_UNINITIALIZED;
    c->fd = -1;
    c->device_index = -1;
    atomic_init(&c->capture_running, false);
    snprintf(c->card_name, sizeof(c->card_name), "No camera opened (V4L2 backend)");
    fill_capabilities(c); /* honest empty caps until a device is opened */
    *ctx = c;
    return CAMERA_OK;
}

camera_error_t camera_hal_destroy(camera_context_t* ctx) {
    if (!ctx) return CAMERA_ERROR_INVALID_PARAMETER;
    if (ctx->streaming) (void)camera_hal_stop_image_stream(ctx);
    if (ctx->fd >= 0) {
        close(ctx->fd);
        ctx->fd = -1;
    }
    free(ctx);
    return CAMERA_OK;
}

camera_error_t camera_hal_enumerate_devices(camera_context_t* ctx, int32_t* count) {
    if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;

    ctx->device_count = 0;
    for (int i = 0; i < CP_MAX_DEVICES; i++) {
        char path[CP_PATH_MAX];
        snprintf(path, sizeof(path), "/dev/video%d", i);

        int fd = open(path, O_RDWR | O_NONBLOCK);
        if (fd < 0) continue;

        struct v4l2_capability cap;
        memset(&cap, 0, sizeof(cap));
        if (xioctl(fd, VIDIOC_QUERYCAP, &cap) == 0) {
            uint32_t caps = (cap.capabilities & V4L2_CAP_DEVICE_CAPS)
                                ? cap.device_caps
                                : cap.capabilities;
            if (caps & V4L2_CAP_VIDEO_CAPTURE) {
                memcpy(ctx->device_paths[ctx->device_count], path, sizeof(path));
                ctx->device_count++;
            }
        }
        close(fd);
    }
    ctx->enumerated = true;
    if (count) *count = ctx->device_count;
    return CAMERA_OK;
}

camera_error_t camera_hal_open(camera_context_t* ctx, int32_t device_index,
                               int64_t flutter_texture_id) {
    (void)flutter_texture_id;
    if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;

    if (!ctx->enumerated) {
        int32_t n = 0;
        (void)camera_hal_enumerate_devices(ctx, &n);
    }
    if (device_index < 0 || device_index >= ctx->device_count) {
        return CAMERA_ERROR_DEVICE_NOT_FOUND;
    }
    if (ctx->fd >= 0) return CAMERA_ERROR_ALREADY_INITIALIZED;

    int fd = open(ctx->device_paths[device_index], O_RDWR | O_NONBLOCK);
    if (fd < 0) {
        if (errno == EBUSY) return CAMERA_ERROR_DEVICE_IN_USE;
        if (errno == EACCES || errno == EPERM) return CAMERA_ERROR_PERMISSION_DENIED;
        return CAMERA_ERROR_DEVICE_NOT_FOUND;
    }

    struct v4l2_capability cap;
    memset(&cap, 0, sizeof(cap));
    if (xioctl(fd, VIDIOC_QUERYCAP, &cap) == -1) {
        close(fd);
        return CAMERA_ERROR_CONFIGURATION_FAILED;
    }

    ctx->fd = fd;
    ctx->device_index = device_index;
    /* v4l2_capability.card is 32 bytes and not guaranteed NUL-terminated. */
    size_t n = sizeof(cap.card);
    if (n >= sizeof(ctx->card_name)) n = sizeof(ctx->card_name) - 1;
    memcpy(ctx->card_name, cap.card, n);
    ctx->card_name[n] = '\0';
    if (ctx->card_name[0] == '\0') {
        snprintf(ctx->card_name, sizeof(ctx->card_name), "%s",
                 ctx->device_paths[device_index]);
    }

    enumerate_controls(ctx);
    fill_capabilities(ctx);

    set_state(ctx, CAMERA_STATE_OPENED);
    return CAMERA_OK;
}

camera_error_t camera_hal_close(camera_context_t* ctx) {
    if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;
    if (ctx->streaming) (void)camera_hal_stop_image_stream(ctx);
    if (ctx->fd >= 0) {
        close(ctx->fd);
        ctx->fd = -1;
    }
    set_state(ctx, CAMERA_STATE_DISPOSED);
    return CAMERA_OK;
}

camera_error_t camera_hal_get_capabilities(camera_context_t* ctx,
                                           camera_capabilities_t* caps) {
    if (!ctx || !caps) return CAMERA_ERROR_INVALID_PARAMETER;
    *caps = ctx->caps; /* name strings remain owned by the context */
    return CAMERA_OK;
}

/* ── Preview (rendering is the Dart side's job; only track state) ────────── */

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

/* ── Exposure ────────────────────────────────────────────────────────────── */

camera_error_t camera_hal_set_exposure_mode(camera_context_t* ctx, int32_t mode) {
    (void)ctx; (void)mode;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

camera_error_t camera_hal_set_shutter_speed_ns(camera_context_t* ctx,
                                               int64_t duration_ns) {
    if (!ctx || ctx->fd < 0) return CAMERA_ERROR_NOT_INITIALIZED;
    if (!ctx->ctl_exposure_abs.present) return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;

    if (ctx->ctl_exposure_auto.present) {
        /* Best effort — some drivers expose only manual and reject the mode
         * switch; the EXPOSURE_ABSOLUTE set below is what must succeed. */
        (void)set_ctrl(ctx->fd, V4L2_CID_EXPOSURE_AUTO, V4L2_EXPOSURE_MANUAL);
    }

    int64_t units = duration_ns / CP_EXPOSURE_UNIT_NS;
    int32_t value = clamp_i32(units, ctx->ctl_exposure_abs.min,
                              ctx->ctl_exposure_abs.max);
    return set_ctrl(ctx->fd, V4L2_CID_EXPOSURE_ABSOLUTE, value);
}

camera_error_t camera_hal_set_iso(camera_context_t* ctx, int32_t iso) {
    if (!ctx || ctx->fd < 0) return CAMERA_ERROR_NOT_INITIALIZED;
    if (!ctx->ctl_gain.present) return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
    int32_t value = clamp_i32(iso, ctx->ctl_gain.min, ctx->ctl_gain.max);
    return set_ctrl(ctx->fd, V4L2_CID_GAIN, value);
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

/* ── Focus ───────────────────────────────────────────────────────────────── */

camera_error_t camera_hal_set_focus_mode(camera_context_t* ctx, int32_t mode) {
    (void)ctx; (void)mode;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

camera_error_t camera_hal_set_focus_distance(camera_context_t* ctx, float diopters) {
    if (!ctx || ctx->fd < 0) return CAMERA_ERROR_NOT_INITIALIZED;
    if (!ctx->ctl_focus_abs.present) return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;

    if (ctx->ctl_focus_auto.present) {
        /* Disable continuous autofocus first (best effort). */
        (void)set_ctrl(ctx->fd, V4L2_CID_FOCUS_AUTO, 0);
    }

    /* The HAL passes a normalized 0..1 lens position on this backend
     * (FOCUS_ABSOLUTE ranges are driver-specific, not diopters). */
    float norm = diopters;
    if (norm < 0.0f) norm = 0.0f;
    if (norm > 1.0f) norm = 1.0f;
    const int64_t span = (int64_t)ctx->ctl_focus_abs.max - ctx->ctl_focus_abs.min;
    int64_t raw = (int64_t)ctx->ctl_focus_abs.min
                + (int64_t)((float)span * norm + 0.5f);
    int32_t value = clamp_i32(raw, ctx->ctl_focus_abs.min, ctx->ctl_focus_abs.max);
    return set_ctrl(ctx->fd, V4L2_CID_FOCUS_ABSOLUTE, value);
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

/* ── White balance ───────────────────────────────────────────────────────── */

camera_error_t camera_hal_set_wb_mode(camera_context_t* ctx, int32_t mode) {
    (void)ctx; (void)mode;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

camera_error_t camera_hal_set_wb_temperature(camera_context_t* ctx, int32_t kelvin) {
    if (!ctx || ctx->fd < 0) return CAMERA_ERROR_NOT_INITIALIZED;
    if (!ctx->ctl_wb_temp.present) return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;

    if (ctx->ctl_wb_auto.present) {
        /* Manual temperature only takes effect with auto WB off (best effort;
         * the temperature set below is what must succeed). */
        (void)set_ctrl(ctx->fd, V4L2_CID_AUTO_WHITE_BALANCE, 0);
    }

    int32_t value = clamp_i32(kelvin, ctx->ctl_wb_temp.min, ctx->ctl_wb_temp.max);
    return set_ctrl(ctx->fd, V4L2_CID_WHITE_BALANCE_TEMPERATURE, value);
}

camera_error_t camera_hal_set_wb_tint(camera_context_t* ctx,
                                      float green_magenta, float blue_amber) {
    (void)ctx; (void)green_magenta; (void)blue_amber;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

camera_error_t camera_hal_lock_white_balance(camera_context_t* ctx) {
    (void)ctx;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

/* ── Flash / torch / zoom (no V4L2 mapping wired yet) ────────────────────── */

camera_error_t camera_hal_set_flash_mode(camera_context_t* ctx, int32_t mode) {
    (void)ctx; (void)mode;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

camera_error_t camera_hal_set_torch(camera_context_t* ctx, bool enabled, float intensity) {
    (void)ctx; (void)enabled; (void)intensity;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

camera_error_t camera_hal_set_zoom(camera_context_t* ctx, float factor) {
    (void)ctx; (void)factor;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

/* ── Photo capture (not wired yet) ───────────────────────────────────────── */

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

/* ── Video / audio (not wired yet) ───────────────────────────────────────── */

camera_error_t camera_hal_set_video_config(camera_context_t* ctx, int32_t width,
                                           int32_t height, int32_t fps,
                                           int32_t codec, int64_t bitrate,
                                           int32_t stabilization,
                                           int32_t color_profile) {
    (void)ctx; (void)width; (void)height; (void)fps; (void)codec;
    (void)bitrate; (void)stabilization; (void)color_profile;
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

camera_error_t camera_hal_set_audio_enabled(camera_context_t* ctx, bool enabled) {
    (void)ctx; (void)enabled;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

camera_error_t camera_hal_set_audio_gain(camera_context_t* ctx, float gain) {
    (void)ctx; (void)gain;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

/* ── Image stream (mmap streaming I/O + pthread capture loop) ────────────── */

static void unmap_buffers(camera_context_t* ctx) {
    for (uint32_t i = 0; i < ctx->n_buffers; i++) {
        if (ctx->buffers[i].start && ctx->buffers[i].start != MAP_FAILED) {
            munmap(ctx->buffers[i].start, ctx->buffers[i].length);
        }
        ctx->buffers[i].start = NULL;
        ctx->buffers[i].length = 0;
    }
    ctx->n_buffers = 0;

    /* Release driver buffers (best effort). */
    struct v4l2_requestbuffers req;
    memset(&req, 0, sizeof(req));
    req.count = 0;
    req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    req.memory = V4L2_MEMORY_MMAP;
    (void)xioctl(ctx->fd, VIDIOC_REQBUFS, &req);
}

static void* capture_thread_main(void* arg) {
    camera_context_t* ctx = (camera_context_t*)arg;

    while (atomic_load(&ctx->capture_running)) {
        struct pollfd pfd;
        pfd.fd = ctx->fd;
        pfd.events = POLLIN;
        pfd.revents = 0;

        int pr = poll(&pfd, 1, CP_POLL_TIMEOUT_MS);
        if (pr < 0) {
            if (errno == EINTR) continue;
            report_error(ctx, CAMERA_ERROR_CAPTURE_FAILED, "poll() on V4L2 fd failed");
            break;
        }
        if (pr == 0) continue; /* timeout — re-check the running flag */
        if (pfd.revents & (POLLERR | POLLNVAL)) {
            report_error(ctx, CAMERA_ERROR_DEVICE_DISCONNECTED,
                         "V4L2 device reported an error condition");
            break;
        }

        struct v4l2_buffer buf;
        memset(&buf, 0, sizeof(buf));
        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = V4L2_MEMORY_MMAP;
        if (xioctl(ctx->fd, VIDIOC_DQBUF, &buf) == -1) {
            if (errno == EAGAIN) continue;
            report_error(ctx, CAMERA_ERROR_CAPTURE_FAILED, "VIDIOC_DQBUF failed");
            break;
        }

        if (buf.index < ctx->n_buffers && ctx->frame_cb) {
            const int64_t ts_ns =
                (int64_t)buf.timestamp.tv_sec * 1000000000LL +
                (int64_t)buf.timestamp.tv_usec * 1000LL;
            uint32_t used = buf.bytesused;
            if (used == 0 || used > ctx->buffers[buf.index].length) {
                used = (uint32_t)ctx->buffers[buf.index].length;
            }
            ctx->frame_cb(ctx->frame_ud,
                          (uint8_t*)ctx->buffers[buf.index].start,
                          (int32_t)used, ctx->frame_width, ctx->frame_height,
                          ctx->frame_format, ts_ns);
        }

        if (xioctl(ctx->fd, VIDIOC_QBUF, &buf) == -1) {
            report_error(ctx, CAMERA_ERROR_CAPTURE_FAILED, "VIDIOC_QBUF failed");
            break;
        }
    }
    return NULL;
}

camera_error_t camera_hal_start_image_stream(camera_context_t* ctx, int32_t width,
                                             int32_t height, int32_t max_fps,
                                             camera_frame_callback_t callback,
                                             void* user_data) {
    if (!ctx || ctx->fd < 0) return CAMERA_ERROR_NOT_INITIALIZED;
    if (!callback) return CAMERA_ERROR_INVALID_PARAMETER;
    if (ctx->streaming) return CAMERA_ERROR_ALREADY_INITIALIZED;

    /* Negotiate the capture format: prefer YUYV, fall back to whatever the
     * driver enumerates first. The driver may adjust size/format; we read the
     * negotiated values back and report them per-frame. */
    struct v4l2_format fmt;
    memset(&fmt, 0, sizeof(fmt));
    fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    fmt.fmt.pix.width = (width > 0) ? (uint32_t)width : 640u;
    fmt.fmt.pix.height = (height > 0) ? (uint32_t)height : 480u;
    fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
    fmt.fmt.pix.field = V4L2_FIELD_NONE;
    if (xioctl(ctx->fd, VIDIOC_S_FMT, &fmt) == -1) {
        struct v4l2_fmtdesc desc;
        memset(&desc, 0, sizeof(desc));
        desc.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        desc.index = 0;
        if (xioctl(ctx->fd, VIDIOC_ENUM_FMT, &desc) == -1) {
            return CAMERA_ERROR_CONFIGURATION_FAILED;
        }
        fmt.fmt.pix.pixelformat = desc.pixelformat;
        if (xioctl(ctx->fd, VIDIOC_S_FMT, &fmt) == -1) {
            return CAMERA_ERROR_CONFIGURATION_FAILED;
        }
    }
    ctx->frame_width = (int32_t)fmt.fmt.pix.width;
    ctx->frame_height = (int32_t)fmt.fmt.pix.height;
    ctx->frame_format = map_v4l2_format(fmt.fmt.pix.pixelformat);

    /* Frame-rate cap (best effort; many UVC drivers ignore it). */
    if (max_fps > 0) {
        struct v4l2_streamparm parm;
        memset(&parm, 0, sizeof(parm));
        parm.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        parm.parm.capture.timeperframe.numerator = 1;
        parm.parm.capture.timeperframe.denominator = (uint32_t)max_fps;
        (void)xioctl(ctx->fd, VIDIOC_S_PARM, &parm);
    }

    /* Request and map buffers. */
    struct v4l2_requestbuffers req;
    memset(&req, 0, sizeof(req));
    req.count = CP_NUM_BUFFERS;
    req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    req.memory = V4L2_MEMORY_MMAP;
    if (xioctl(ctx->fd, VIDIOC_REQBUFS, &req) == -1) {
        return (errno == EINVAL) ? CAMERA_ERROR_FEATURE_NOT_SUPPORTED
                                 : CAMERA_ERROR_CONFIGURATION_FAILED;
    }
    if (req.count < 2) {
        unmap_buffers(ctx);
        return CAMERA_ERROR_CONFIGURATION_FAILED;
    }
    ctx->n_buffers = (req.count < CP_NUM_BUFFERS) ? req.count : CP_NUM_BUFFERS;

    for (uint32_t i = 0; i < ctx->n_buffers; i++) {
        struct v4l2_buffer buf;
        memset(&buf, 0, sizeof(buf));
        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.index = i;
        if (xioctl(ctx->fd, VIDIOC_QUERYBUF, &buf) == -1) {
            unmap_buffers(ctx);
            return CAMERA_ERROR_CONFIGURATION_FAILED;
        }
        ctx->buffers[i].length = buf.length;
        ctx->buffers[i].start = mmap(NULL, buf.length, PROT_READ | PROT_WRITE,
                                     MAP_SHARED, ctx->fd, (off_t)buf.m.offset);
        if (ctx->buffers[i].start == MAP_FAILED) {
            ctx->buffers[i].start = NULL;
            ctx->buffers[i].length = 0;
            unmap_buffers(ctx);
            return CAMERA_ERROR_OUT_OF_MEMORY;
        }
    }

    /* Queue everything and start streaming. */
    for (uint32_t i = 0; i < ctx->n_buffers; i++) {
        struct v4l2_buffer buf;
        memset(&buf, 0, sizeof(buf));
        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.index = i;
        if (xioctl(ctx->fd, VIDIOC_QBUF, &buf) == -1) {
            unmap_buffers(ctx);
            return CAMERA_ERROR_CONFIGURATION_FAILED;
        }
    }

    enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (xioctl(ctx->fd, VIDIOC_STREAMON, &type) == -1) {
        unmap_buffers(ctx);
        return CAMERA_ERROR_CONFIGURATION_FAILED;
    }

    ctx->frame_cb = callback;
    ctx->frame_ud = user_data;
    atomic_store(&ctx->capture_running, true);
    if (pthread_create(&ctx->capture_thread, NULL, capture_thread_main, ctx) != 0) {
        atomic_store(&ctx->capture_running, false);
        (void)xioctl(ctx->fd, VIDIOC_STREAMOFF, &type);
        unmap_buffers(ctx);
        ctx->frame_cb = NULL;
        ctx->frame_ud = NULL;
        return CAMERA_ERROR_UNKNOWN;
    }

    ctx->streaming = true;
    set_state(ctx, CAMERA_STATE_PREVIEWING);
    return CAMERA_OK;
}

camera_error_t camera_hal_stop_image_stream(camera_context_t* ctx) {
    if (!ctx) return CAMERA_ERROR_NOT_INITIALIZED;
    if (!ctx->streaming) return CAMERA_OK;

    atomic_store(&ctx->capture_running, false);
    (void)pthread_join(ctx->capture_thread, NULL);

    enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    (void)xioctl(ctx->fd, VIDIOC_STREAMOFF, &type);
    unmap_buffers(ctx);

    ctx->frame_cb = NULL;
    ctx->frame_ud = NULL;
    ctx->streaming = false;
    set_state(ctx, CAMERA_STATE_OPENED);
    return CAMERA_OK;
}

/* ── Callback registration ───────────────────────────────────────────────── */

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

#else /* !__linux__ */

/* This backend is Linux-only. Provide a harmless declaration so the file is a
 * valid (non-empty) translation unit when included in cross-platform builds. */
typedef int camera_hal_linux_backend_not_built_on_this_platform;

#endif /* __linux__ */
