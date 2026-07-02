/*
 * metal_processor.m — GPU compute for visual aids (histogram, focus peaking,
 * zebra) on Apple platforms.
 *
 * The MSL kernels are compiled AT RUNTIME via newLibraryWithSource:, so no
 * offline metal toolchain is needed to build or ship. All kernels use the same
 * integer math as the C reference kernels in image_processor.c — including the
 * fixed-point luma (77r+150g+29b)>>8 and a squared-magnitude Sobel compare —
 * so GPU output is bit-exact against the CPU path (verified by the harness in
 * metal_test.c and on every capture by the CI macOS job).
 *
 * C API (see camera_hal_apple.h): callable over FFI for runtime GPU/CPU
 * dispatch selection.
 *
 * Copyright (c) 2026 camera_pro contributors. BSD-3-Clause.
 */
#import <Foundation/Foundation.h>
#if __has_include(<Metal/Metal.h>)
#import <Metal/Metal.h>
#define CP_HAVE_METAL 1
#endif

#include "../../core/camera_pro_types.h"

#include <string.h>

#if CP_HAVE_METAL

static NSString* const kShaderSource = @""
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"\n"
"inline uint luma_u8(uint r, uint g, uint b) {\n"
"  return (77u * r + 150u * g + 29u * b) >> 8;\n"
"}\n"
"\n"
"kernel void cp_histogram(\n"
"    device const uchar4* px      [[buffer(0)]],\n"
"    device atomic_uint*  hists   [[buffer(1)]],  /* 4*256: luma,r,g,b */\n"
"    constant uint&       count   [[buffer(2)]],\n"
"    constant uint&       is_bgra [[buffer(3)]],\n"
"    uint gid [[thread_position_in_grid]]) {\n"
"  if (gid >= count) return;\n"
"  uchar4 p = px[gid];\n"
"  uint r = is_bgra ? p.z : p.x;\n"
"  uint g = p.y;\n"
"  uint b = is_bgra ? p.x : p.z;\n"
"  atomic_fetch_add_explicit(&hists[luma_u8(r,g,b)], 1u, memory_order_relaxed);\n"
"  atomic_fetch_add_explicit(&hists[256u + r], 1u, memory_order_relaxed);\n"
"  atomic_fetch_add_explicit(&hists[512u + g], 1u, memory_order_relaxed);\n"
"  atomic_fetch_add_explicit(&hists[768u + b], 1u, memory_order_relaxed);\n"
"}\n"
"\n"
"kernel void cp_focus_peaking(\n"
"    device const uchar* in_px  [[buffer(0)]],\n"
"    device uchar*       out_px [[buffer(1)]],\n"
"    constant uint&      width  [[buffer(2)]],\n"
"    constant uint&      height [[buffer(3)]],\n"
"    constant uint&      thr2   [[buffer(4)]],  /* (threshold*1020)^2 */\n"
"    constant uint&      color  [[buffer(5)]],  /* 0xRRGGBBAA */\n"
"    constant uint&      is_bgra [[buffer(6)]],\n"
"    uint2 gid [[thread_position_in_grid]]) {\n"
"  if (gid.x >= width || gid.y >= height) return;\n"
"  uint idx = (gid.y * width + gid.x) * 4u;\n"
"  out_px[idx+0] = in_px[idx+0];\n"
"  out_px[idx+1] = in_px[idx+1];\n"
"  out_px[idx+2] = in_px[idx+2];\n"
"  out_px[idx+3] = in_px[idx+3];\n"
"  if (gid.x < 1u || gid.y < 1u || gid.x >= width-1u || gid.y >= height-1u) return;\n"
"  int l[3][3];\n"
"  for (int dy = -1; dy <= 1; dy++)\n"
"    for (int dx = -1; dx <= 1; dx++) {\n"
"      uint o = ((gid.y + dy) * width + (gid.x + dx)) * 4u;\n"
"      l[dy+1][dx+1] = (int)luma_u8(in_px[o], in_px[o+1u], in_px[o+2u]);\n"
"    }\n"
"  int gx = -l[0][0] + l[0][2] - 2*l[1][0] + 2*l[1][2] - l[2][0] + l[2][2];\n"
"  int gy = -l[0][0] - 2*l[0][1] - l[0][2] + l[2][0] + 2*l[2][1] + l[2][2];\n"
"  uint mag2 = (uint)(gx*gx + gy*gy);\n"
"  if (mag2 > thr2) {\n"
"    uint ri = is_bgra ? idx+2u : idx;\n"
"    uint bi = is_bgra ? idx : idx+2u;\n"
"    out_px[ri]    = (color >> 24) & 0xFFu;\n"
"    out_px[idx+1] = (color >> 16) & 0xFFu;\n"
"    out_px[bi]    = (color >> 8) & 0xFFu;\n"
"  }\n"
"}\n"
"\n"
"kernel void cp_zebra(\n"
"    device const uchar* in_px  [[buffer(0)]],\n"
"    device uchar*       out_px [[buffer(1)]],\n"
"    constant uint&      width  [[buffer(2)]],\n"
"    constant uint&      height [[buffer(3)]],\n"
"    constant uint&      thr    [[buffer(4)]],  /* 0..255 */\n"
"    constant uint&      frame  [[buffer(5)]],\n"
"    constant uint&      is_bgra [[buffer(6)]],\n"
"    uint2 gid [[thread_position_in_grid]]) {\n"
"  if (gid.x >= width || gid.y >= height) return;\n"
"  uint idx = (gid.y * width + gid.x) * 4u;\n"
"  uint ri = is_bgra ? idx+2u : idx;\n"
"  uint bi = is_bgra ? idx : idx+2u;\n"
"  out_px[idx+0] = in_px[idx+0];\n"
"  out_px[idx+1] = in_px[idx+1];\n"
"  out_px[idx+2] = in_px[idx+2];\n"
"  out_px[idx+3] = in_px[idx+3];\n"
"  uint l = luma_u8(in_px[ri], in_px[idx+1u], in_px[bi]);\n"
"  if (l > thr) {\n"
"    uint stripe = ((gid.x + gid.y + frame * 2u) / 4u) & 1u;\n"
"    if (stripe == 0u) { out_px[ri] = 255; out_px[idx+1u] = 0; out_px[bi] = 0; }\n"
"  }\n"
"}\n";

typedef struct {
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLComputePipelineState> histogram;
    id<MTLComputePipelineState> peaking;
    id<MTLComputePipelineState> zebra;
} cp_metal_t;

static cp_metal_t* g_metal = NULL;

static cp_metal_t* metal_get(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @autoreleasepool {
            id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
            if (!dev) return;
            NSError* err = nil;
            id<MTLLibrary> lib = [dev newLibraryWithSource:kShaderSource
                                                   options:nil
                                                     error:&err];
            if (!lib || err) return;
            cp_metal_t* m = calloc(1, sizeof(cp_metal_t));
            m->device = dev;
            m->queue = [dev newCommandQueue];
            m->histogram = [dev newComputePipelineStateWithFunction:
                                    [lib newFunctionWithName:@"cp_histogram"]
                                                              error:&err];
            m->peaking = [dev newComputePipelineStateWithFunction:
                                  [lib newFunctionWithName:@"cp_focus_peaking"]
                                                            error:&err];
            m->zebra = [dev newComputePipelineStateWithFunction:
                                [lib newFunctionWithName:@"cp_zebra"]
                                                          error:&err];
            if (m->histogram && m->peaking && m->zebra) {
                g_metal = m;
            } else {
                free(m);
            }
        }
    });
    return g_metal;
}

int32_t camera_pro_metal_available(void) {
    return metal_get() != NULL ? 1 : 0;
}

const char* camera_pro_metal_device_name(void) {
    cp_metal_t* m = metal_get();
    if (!m) return "";
    return m->device.name.UTF8String;
}

int32_t camera_pro_metal_histogram(
    const uint8_t* rgba, int32_t width, int32_t height, int32_t is_bgra,
    uint32_t* luma_hist, uint32_t* r_hist, uint32_t* g_hist, uint32_t* b_hist) {
    cp_metal_t* m = metal_get();
    if (!m) return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
    if (!rgba || width <= 0 || height <= 0) return CAMERA_ERROR_INVALID_PARAMETER;
    @autoreleasepool {
        const uint32_t count = (uint32_t)(width * height);
        id<MTLBuffer> in = [m->device newBufferWithBytes:rgba
                                                  length:count * 4
                                                 options:MTLResourceStorageModeShared];
        id<MTLBuffer> hists = [m->device newBufferWithLength:4 * 256 * 4
                                                     options:MTLResourceStorageModeShared];
        memset(hists.contents, 0, 4 * 256 * 4);
        uint32_t bgra = (uint32_t)is_bgra;

        id<MTLCommandBuffer> cb = [m->queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:m->histogram];
        [enc setBuffer:in offset:0 atIndex:0];
        [enc setBuffer:hists offset:0 atIndex:1];
        [enc setBytes:&count length:4 atIndex:2];
        [enc setBytes:&bgra length:4 atIndex:3];
        NSUInteger tg = m->histogram.maxTotalThreadsPerThreadgroup;
        [enc dispatchThreads:MTLSizeMake(count, 1, 1)
            threadsPerThreadgroup:MTLSizeMake(tg > 256 ? 256 : tg, 1, 1)];
        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];

        const uint32_t* out = (const uint32_t*)hists.contents;
        if (luma_hist) memcpy(luma_hist, out, 256 * 4);
        if (r_hist) memcpy(r_hist, out + 256, 256 * 4);
        if (g_hist) memcpy(g_hist, out + 512, 256 * 4);
        if (b_hist) memcpy(b_hist, out + 768, 256 * 4);
        return CAMERA_OK;
    }
}

/* Shared runner for the two image->image kernels. */
static int32_t run_image_kernel(
    id<MTLComputePipelineState> pso,
    const uint8_t* in_px, uint8_t* out_px, int32_t width, int32_t height,
    uint32_t p4, uint32_t p5, uint32_t is_bgra) {
    cp_metal_t* m = metal_get();
    if (!m) return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
    if (!in_px || !out_px || width <= 0 || height <= 0)
        return CAMERA_ERROR_INVALID_PARAMETER;
    @autoreleasepool {
        const uint32_t w = (uint32_t)width, h = (uint32_t)height;
        const NSUInteger bytes = (NSUInteger)w * h * 4;
        id<MTLBuffer> in = [m->device newBufferWithBytes:in_px
                                                  length:bytes
                                                 options:MTLResourceStorageModeShared];
        id<MTLBuffer> out = [m->device newBufferWithLength:bytes
                                                   options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [m->queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:pso];
        [enc setBuffer:in offset:0 atIndex:0];
        [enc setBuffer:out offset:0 atIndex:1];
        [enc setBytes:&w length:4 atIndex:2];
        [enc setBytes:&h length:4 atIndex:3];
        [enc setBytes:&p4 length:4 atIndex:4];
        [enc setBytes:&p5 length:4 atIndex:5];
        [enc setBytes:&is_bgra length:4 atIndex:6];
        [enc dispatchThreads:MTLSizeMake(w, h, 1)
            threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        memcpy(out_px, out.contents, bytes);
        return CAMERA_OK;
    }
}

int32_t camera_pro_metal_focus_peaking(
    const uint8_t* in_px, uint8_t* out_px, int32_t width, int32_t height,
    int32_t is_bgra, float threshold, uint32_t peak_color) {
    cp_metal_t* m = metal_get();
    if (!m) return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
    /* Same normalisation as the CPU kernel: edge = sqrt(gx^2+gy^2)/1020 > thr
     * <=> gx^2+gy^2 > (thr*1020)^2. */
    float t = threshold * 1020.0f;
    uint32_t thr2 = (uint32_t)(t * t);
    return run_image_kernel(m->peaking, in_px, out_px, width, height,
                            thr2, peak_color, (uint32_t)is_bgra);
}

int32_t camera_pro_metal_zebra(
    const uint8_t* in_px, uint8_t* out_px, int32_t width, int32_t height,
    int32_t is_bgra, float threshold, int32_t frame_counter) {
    cp_metal_t* m = metal_get();
    if (!m) return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
    uint32_t thr = (uint32_t)(threshold * 255.0f);
    return run_image_kernel(m->zebra, in_px, out_px, width, height,
                            thr, (uint32_t)frame_counter, (uint32_t)is_bgra);
}

#else /* !CP_HAVE_METAL */

int32_t camera_pro_metal_available(void) { return 0; }
const char* camera_pro_metal_device_name(void) { return ""; }
int32_t camera_pro_metal_histogram(const uint8_t* a, int32_t b, int32_t c,
                                   int32_t d, uint32_t* e, uint32_t* f,
                                   uint32_t* g, uint32_t* h) {
    (void)a;(void)b;(void)c;(void)d;(void)e;(void)f;(void)g;(void)h;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}
int32_t camera_pro_metal_focus_peaking(const uint8_t* a, uint8_t* b, int32_t c,
                                       int32_t d, int32_t e, float f, uint32_t g) {
    (void)a;(void)b;(void)c;(void)d;(void)e;(void)f;(void)g;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}
int32_t camera_pro_metal_zebra(const uint8_t* a, uint8_t* b, int32_t c,
                               int32_t d, int32_t e, float f, int32_t g) {
    (void)a;(void)b;(void)c;(void)d;(void)e;(void)f;(void)g;
    return CAMERA_ERROR_FEATURE_NOT_SUPPORTED;
}

#endif /* CP_HAVE_METAL */
