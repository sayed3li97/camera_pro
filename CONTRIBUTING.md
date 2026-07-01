# Contributing to camera_pro

Thank you for your interest in contributing to `camera_pro`. This document explains how to build, test, and extend the package, and the standards we hold contributors to.

## Project status

This is an early foundation (v0.1.0). The shared C core and Dart control-plane are implemented and verified. Real platform HALs (Android, Apple, Windows, Linux, Web) are not yet wired. Please read the status markers throughout the codebase before claiming a feature works:

- ✅ implemented and verified
- 🚧 API/interface scaffolded; native side not connected
- ❌ not started

## Repository layout

```
camera_pro/
├── src/
│   ├── core/                   # Shared C core (✅ verified)
│   │   ├── camera_pro_core.h   # FFI boundary (public C API)
│   │   ├── camera_pro_types.h  # Shared types
│   │   ├── buffer_pool.c       # Lock-free buffer pool
│   │   ├── image_processor.c   # Sobel focus peaking, zebra
│   │   ├── format_converter.c  # Scalar YUV→RGBA conversions
│   │   └── camera_pro_core.c   # SIMD histogram, top-level glue
│   ├── hal/
│   │   └── camera_hal.h        # C platform-abstraction contract
│   ├── platform/
│   │   └── stub/
│   │       └── camera_hal_stub.c  # Conformant no-op HAL (✅ verified)
│   └── tests/
│       └── core_test.c         # C test harness (36/36 checks)
├── hook/
│   └── build.dart              # native-assets hook (compiles C core via native_toolchain_c)
├── ffigen.yaml                 # FFI binding generation config
├── lib/
│   ├── camera_pro.dart         # Barrel export
│   └── src/
│       ├── models/             # Value types, enums, capability passport
│       ├── controller/         # CameraProController, state machine
│       ├── processing/         # HistogramData, NativeCore, NativeBufferPool
│       ├── platform/           # CameraBackend interface, StubCameraBackend
│       ├── ffi/                # Generated FFI bindings
│       └── utils/              # Result<T,E>, DeviceQuirk, ThermalPolicy
├── test/                       # Dart tests (59 pass: 54 pure-logic + 5 real-FFI)
├── example/                    # Flutter demo app
├── pubspec.yaml
└── CONTRIBUTING.md
```

## Building and running the C test harness

The C tests are self-contained and do not require Flutter. From the repository root:

```sh
clang -std=c11 -O2 -Wall -Wextra -Werror \
    -Isrc/core \
    src/core/buffer_pool.c \
    src/core/image_processor.c \
    src/core/format_converter.c \
    src/core/camera_pro_core.c \
    src/platform/stub/camera_hal_stub.c \
    src/tests/core_test.c \
    -o /tmp/core_test && /tmp/core_test
```

Expected output: `36/36 checks pass`. The NEON histogram kernel is cross-checked bit-exact against the scalar reference on arm64. On non-NEON hosts the scalar path is used and the same count passes.

Do not submit changes to the C core without keeping this at 36/36.

## Running the Dart tests

```sh
flutter test
```

This also exercises the native-assets hook: `hook/build.dart` compiles the C core into `libcamera_pro_core.dylib` (or the platform equivalent) automatically, so the 5 real-FFI tests exercise the full native→FFI→Dart pipeline.

Expected: 59 tests pass, 0 failures.

## Static analysis

```sh
flutter analyze
```

Expected: no issues. The project uses `flutter_lints`. Fix all warnings before opening a pull request; the CI gate treats warnings as errors.

## Code style

### Dart

- Format all Dart with `dart format .` before committing.
- Follow `flutter_lints` rules. Do not suppress lint warnings with `// ignore` without a detailed comment explaining why.
- Public APIs must have doc comments (`///`). Include an example snippet in the doc comment for non-trivial members.

### C

- Standard: C11 (`-std=c11`).
- All new C files must compile cleanly under `-Wall -Wextra -Werror` with no suppressions.
- No platform-specific headers in `src/core/`; those belong in `src/platform/<name>/`.
- SIMD paths must have a scalar fallback and must be guarded with the appropriate compile-time macro (e.g. `#if defined(__ARM_NEON)`).

## Adding a new platform HAL

Real platform support is the highest-value contribution right now. Every function declared in `src/hal/camera_hal.h` must be implemented; partial implementations that silently no-op are not acceptable for a non-stub backend.

### Step 1 — Implement the C HAL

Create `src/platform/<name>/camera_hal_<name>.c` (and any supporting files). Implement every function in `src/hal/camera_hal.h`. Use only platform-specific APIs appropriate for that backend (e.g. NDK Camera2 for Android, AVFoundation for Apple).

Do not copy the stub implementation and call it done. The stub returns `CAMERA_HAL_ERROR_NOT_SUPPORTED` for every operation intentionally; a real HAL must return real data.

### Step 2 — Wire the build

Add your new source files to `hook/build.dart` under the appropriate platform guard, or to the platform CMake file if one exists:

```dart
// hook/build.dart (simplified excerpt)
if (target.os == OS.android) {
  sources.add('src/platform/android/camera_hal_android.c');
} else if (target.os == OS.iOS || target.os == OS.macOS) {
  sources.add('src/platform/apple/camera_hal_apple.m');
}
```

Verify that `flutter test` still passes after your build change.

### Step 3 — Implement the Dart CameraBackend

Create `lib/src/platform/<name>_camera_backend.dart` implementing the `CameraBackend` interface. The backend is responsible for:

- Forwarding `availableCameras()` to the native HAL via FFI.
- Opening a camera session and populating a real `CameraCapabilities` by probing the hardware.
- Forwarding setter calls (`setIso`, `setZoom`, etc.) to the native HAL.

**Capabilities must be probed from the hardware, never assumed.** If a device does not report manual ISO support, `capabilities.iso` must be `NotSupported<int>` with a human-readable reason. Do not hard-code capability values.

```dart
// Correct: probe, then report
final isoRange = await _hal.queryIsoRange();
final iso = isoRange != null
    ? Supported<int>(
        currentValue: isoRange.current,
        minValue: isoRange.min,
        maxValue: isoRange.max,
      )
    : const NotSupported<int>(reason: 'Device does not support manual ISO');
```

### Step 4 — Register the backend

Wire your backend into `CameraPro.create()` and `CameraPro.availableCameras()` behind the appropriate platform check or explicit `CameraBackend` argument.

### Step 5 — Tests

Add at minimum:

- A unit test using `CameraProController.forTesting(capabilities: ..., backend: YourFakeBackend())` covering the happy path and each error variant your HAL can surface.
- A note in your PR describing which real device(s) you tested on and what `CameraPro.nativeCoreVersion` + `CameraPro.simdKernel` printed.

## Regenerating FFI bindings

The Dart FFI bindings in `lib/src/ffi/` are generated from `camera_pro_core.h` using `package:ffigen`. Regenerate them whenever you change the public C API:

```sh
dart run ffigen --config ffigen.yaml
```

`ffigen` requires `libclang` to be installed:

- macOS: `brew install llvm` (the LLVM toolchain includes libclang).
- Ubuntu/Debian: `sudo apt-get install libclang-dev`.
- Windows: install LLVM from https://releases.llvm.org/ and add it to `PATH`.

After regenerating, run `flutter analyze` and `flutter test` to confirm nothing broke.

## The honesty principle

This principle is non-negotiable and applies to all contributions:

> **Capabilities must be probed from hardware, never assumed. Do not claim an unimplemented feature works.**

Concretely:

- Never hard-code `Supported<T>` for a capability without querying the underlying platform API.
- Never change a `🚧` status to `✅` in documentation or comments unless you have test results proving the feature works end-to-end on real hardware.
- If you cannot test on a specific device or OS, mark the status `🚧` and document what remains unverified.
- Benchmark numbers must be measured, not estimated. Label architectural goals as "target" rather than presenting them as measured results.

## Commit and pull request conventions

### Commit messages

Use the conventional commits format:

```
<type>(<scope>): <short imperative summary>

[optional body: what and why, not how]

[optional footer: breaking changes, issue refs]
```

Types: `feat`, `fix`, `perf`, `refactor`, `test`, `docs`, `build`, `ci`, `chore`.

Scopes: `core` (C layer), `dart` (Dart library), `hal` (platform HAL), `ffi` (bindings), `example`, `build` (hook/CMake), `docs`.

Examples:

```
feat(hal): add Android NDK Camera2 HAL implementation

fix(core): guard NEON histogram behind __ARM_NEON compile-time check

test(dart): add FFI round-trip test for histogram on arm64

docs: update CONTRIBUTING with V4L2 build instructions
```

### Pull requests

- Open a draft PR early if you want feedback before the implementation is complete.
- The PR description must include:
  - What is implemented and what remains 🚧.
  - How you tested it (device model, OS version, Flutter/Dart version).
  - Output of `flutter test` and `flutter analyze`.
  - Output of the C test harness (`36/36 checks pass` or a note if you added new checks).
- One logical change per PR. Refactors and feature additions should be separate PRs.
- Do not force-push to a PR branch after review has started; add fixup commits instead.

### Breaking changes

The public Dart API and the C FFI boundary (`camera_pro_core.h`) are both considered stable once a platform HAL ships. Until then (v0.x.0), breaking changes are acceptable but must be:

- Described explicitly in the PR.
- Accompanied by a migration note in `CHANGELOG.md`.

## License

By contributing you agree that your changes will be licensed under the BSD-3-Clause license that covers this project.
