# camera_pro — Implementation Roadmap

Legend: ✅ implemented **and verified** (the README's "Verified this build" section
says how) · 🚧 partially done / API modelled · ⛔ gated on hardware or
infrastructure this project's CI and dev machines don't have · ❌ not started.

Every ✅ below was verified by at least one of: the 60-check C harness, the
71-test Dart suite, the GPU cross-check harness, CI runners (ubuntu/windows/
macos), Rosetta x86 runs, ffprobe/ffmpeg inspection of produced files, or
live operation of the example app against real cameras.

---

## Phase 1 — Foundation & C Core ✅ (complete)

| Item | Status |
|------|--------|
| HAL contract (`camera_hal.h`, 44 functions) | ✅ four backends implement it |
| Lock-free buffer pool (+ Windows UCRT aligned-alloc shim) | ✅ |
| SIMD histogram: NEON + SSSE3 (x86) + scalar reference | ✅ bit-exact, Rosetta-verified on x86 |
| YUV420P/NV12/NV21 → RGBA (NEON fast path for 420P) | ✅ bit-exact vs reference |
| Native-assets FFI build hook | ✅ |
| Capability passport / state machine / typed errors / tiers | ✅ |
| ffigen-generated bindings (replace hand-written) | 🚧 hand-written `@Native` bindings ship; regression-tested per symbol |

## Phase 2 — Apple Backend (AVFoundation) ✅ (complete for macOS-verifiable scope)

| Item | Status |
|------|--------|
| Device enumeration / open / capabilities | ✅ real cameras |
| Live preview (frames over FFI → dart:ui) | ✅ |
| Manual controls: sensor (iOS, SDK-compiled) + digital (macOS, live-verified) | ✅ |
| Photo capture (PNG) | ✅ |
| RAW capture (linear-DNG + EXIF, dependency-free writer) | ✅ ffmpeg-decodes; ImageIO's DNG codec is camera-profile-gated and does not accept generic linear DNGs |
| Video recording (.mov, AVCaptureMovieFileOutput) | ✅ ffprobe-verified h264 |
| Burst capture | ✅ 5 shots ≈1.2s |
| EV bracket capture | ✅ measured YAVG 25.8/96.9/183.4 at −2/0/+2 |
| Camera permission flow | ✅ |
| Flutter `textureId` zero-copy Metal preview | ❌ (polled-frame preview shipped instead; texture path is an optimization) |
| Full-res `AVCapturePhotoOutput` stills | ❌ (captures are at session preset) |
| iOS on-device validation | ⛔ needs a physical iPhone |

## Phase 3 — Android Backend (Camera2 NDK) ⛔

Requires Android hardware/emulator with camera HAL access for honest
verification. The HAL contract, build wiring, quirks DB, and the Linux/Windows
backend patterns make this a mechanical port. ❌ not started (by policy: no
unverifiable device code).

## Phase 4 — Pro Capture & Visual Aids ✅ (complete)

| Item | Status |
|------|--------|
| Live histogram / focus peaking / zebra / false color / waveform | ✅ all five live overlays |
| RAW/DNG + EXIF (ISO, exposure, timestamps) | ✅ no libtiff/libexif needed |
| Burst / EV bracketing | ✅ |
| HDR fusion (merge brackets into one image) | ❌ (brackets are captured; fusion algorithm not written) |
| libjpeg-turbo | skipped by design — PNG via dart:ui + DNG cover stills today |

## Phase 5 — GPU Visual Aids ✅ Metal · ⛔ others

| Item | Status |
|------|--------|
| Metal compute: histogram / peaking / zebra (runtime-compiled MSL) | ✅ bit-exact vs CPU on Apple M1 Pro; byte-identical through Dart FFI |
| Runtime GPU/CPU dispatch (`MetalCompute` → `NativeCore` fallback) | ✅ example overlays run on GPU |
| Vulkan (Android/Linux) / D3D11 (Windows) / WebGPU (web) | ⛔ need those platforms' GPUs to verify; MSL kernels are the port template |

## Phase 6 — Advanced Features

| Item | Status |
|------|--------|
| Video recording with codec selection | ✅ h264 today; HEVC/ProRes selection ❌ |
| Frame processor plugin API | ✅ tested |
| Multi-camera | ✅ concurrent two-device open verified (FaceTime + Elgato); simultaneous multi-stream UI ❌ |
| Live streaming (RTMP/SRT/HLS) | 🚧 API modelled (`StreamConfig`/`StreamStatus`); transport ⛔ needs a protocol client + streaming endpoint to verify |
| Depth / LiDAR | ⛔ iOS-hardware-only (models exist: `DepthData`) |
| x86 SIMD histogram | ✅ SSSE3, Rosetta + CI-x86 verified |
| Accelerated YUV conversion | ✅ custom NEON (0.66 ms/1080p frame measured) — libyuv not needed |
| Device quirks DB | ✅ 8 entries |

## Phase 7 — Desktop & Web

| Item | Status |
|------|--------|
| Linux backend (V4L2, full 44-function contract) | ✅ compiles + lifecycle harness passes on CI ubuntu runner · ⛔ camera-hardware runtime untested |
| Windows backend (Media Foundation, full contract) | ✅ compiles + lifecycle harness passes on CI windows runner · ⛔ camera-hardware runtime untested |
| Web backend | ❌ — requires a conditional-import refactor (the package currently imports `dart:ffi`/`dart:io` unconditionally) plus a `package:web` getUserMedia backend and WebGPU ports. Plan: split `camera_pro.dart` exports behind `if (dart.library.js_interop)`, stub `NativeCore`, implement `WebCameraBackend` |

## Phase 8 — Polish & Publication ✅ (complete)

| Item | Status |
|------|--------|
| Measured performance benchmarks (`src/tests/bench.c`) | ✅ real numbers in README (including the honest scalar-beats-NEON histogram result) |
| dartdoc | ✅ 0 warnings / 0 errors |
| `dart pub publish --dry-run` | ✅ 0 warnings (313 KB archive) |
| CI (macos/ubuntu/windows, every push) | ✅ green |
| pub.dev publication | user's call — the package validates cleanly |
| Localization of error strings | ❌ (English only; messages centralised in `errors.dart` / `camera_pro_error_string`) |

---

## What remains, and what it takes

| Item | Blocked on |
|---|---|
| iOS on-device run, depth/LiDAR, ProRAW | a physical iPhone |
| Android backend | Android device/emulator |
| Linux/Windows camera runtime validation | machines with cameras (CI validates compile + lifecycle) |
| Streaming transport | RTMP/SRT client implementation + an endpoint to verify against |
| Web | conditional-import refactor (plan above) |
| HDR fusion, HEVC/ProRes selection, texture-based preview, ffigen swap | pure engineering time — no hardware gate |
