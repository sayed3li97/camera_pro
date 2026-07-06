# Troubleshooting — camera_pro

This guide covers known issues, their root causes, and concrete fixes for the
`camera_pro` package (v0.0.2). Issues are presented as **Problem → Cause → Fix**.

---

## Table of Contents

1. [Native core unavailable / symbol not found](#1-native-core-unavailable--symbol-not-found)
2. [Build hook reports an error or produces no output](#2-build-hook-reports-an-error-or-produces-no-output)
3. [Controller always returns `CameraTier.basic`](#3-controller-always-returns-cameratierbasic)
4. [`flutter test` recompiles the native core on every run](#4-flutter-test-recompiles-the-native-core-on-every-run)
5. [`ffigen` fails with "could not find libclang"](#5-ffigen-fails-with-could-not-find-libclang)
6. [Capability-guarded setters throw `CameraFeatureNotSupportedError`](#6-capability-guarded-setters-throw-camerafeaturenotsupportederror)
7. [Reading and acting on `CameraProError.recovery`](#7-reading-and-acting-on-cameraproerrorrecovery)

---

## 1. Native core unavailable / symbol not found

**Problem**

`flutter run` or `flutter test` crashes with an error such as:

```
Invalid argument(s): Failed to lookup symbol 'camera_pro_core_version'
```

or

```
DartApiError: Failed to load dynamic library 'libcamera_pro_core.dylib'
```

**Cause**

The package uses the Flutter **native-assets** experimental feature
(`hook/build.dart`) to compile the C core (`libcamera_pro_core`) automatically.
If native assets are not enabled for your Flutter installation, the hook never
runs, the shared library is never produced, and every FFI call fails at runtime.

**Fix**

1. Confirm your Flutter version supports native assets. The feature is enabled
   by default from **Flutter 3.22** onwards for `flutter test` and from
   **Flutter 3.44** (the version used during development of this package) for
   `flutter run` as well.

   ```bash
   flutter --version
   ```

2. If you are on an older channel, switch to a version that includes native
   assets support:

   ```bash
   flutter channel stable   # or 'main' for the cutting edge
   flutter upgrade
   ```

3. Verify that the hook is recognized by running:

   ```bash
   flutter test --verbose 2>&1 | grep -i 'hook\|native'
   ```

   You should see lines referencing `hook/build.dart` and the output path for
   `libcamera_pro_core`.

4. If you are integrating `camera_pro` into an existing project, ensure the
   consuming `pubspec.yaml` does **not** opt out of native assets. No explicit
   opt-in flag is required in recent Flutter versions.

**How the hook works**

`hook/build.dart` uses `package:native_toolchain_c` to:

- Locate a C compiler on the host (`clang` on macOS/Linux, MSVC or clang-cl on
  Windows).
- Compile `src/core/*.c` plus the platform backend selected by target OS: the
  AVFoundation HAL (`src/platform/apple/*.m`, Objective-C with ARC, linking
  AVFoundation/Metal and friends) on macOS/iOS, or the conformant stub
  (`src/platform/stub/camera_hal_stub.c`) on other native targets.
- Produce a platform-appropriate shared library (`libcamera_pro_core.dylib`,
  `.so`, or `.dll`) as a `code_asset` that Flutter links into the test runner or
  app bundle.

On **web** the hook compiles nothing by design: there is no C core on that
target, and a pure-Dart implementation (byte-identical to the C kernels,
cross-checked in tests) is used instead. A missing-symbol error therefore
cannot occur on web.

---

## 2. Build hook reports an error or produces no output

**Problem**

The hook runs but exits with a non-zero code, or the build log shows
`hook/build.dart` completed without producing a library.

**Cause**

Common sub-causes:

| Sub-cause | Typical log fragment |
|-----------|----------------------|
| No C compiler on `PATH` | `Could not find a suitable C compiler` |
| Missing system headers | `fatal error: 'stdint.h' file not found` |
| Incompatible `native_toolchain_c` version | `type 'BuildConfig' is not a subtype` |

**Fix**

1. **Check hook output verbosely.**  Pass `--verbose` to surface the full hook
   log:

   ```bash
   flutter test --verbose 2>&1 | grep -A 20 'hook'
   ```

2. **Install a C compiler.**
   - macOS: `xcode-select --install`
   - Linux (Debian/Ubuntu): `sudo apt-get install build-essential`
   - Windows: Install [Build Tools for Visual Studio](https://visualstudio.microsoft.com/downloads/) or the LLVM/clang Windows distribution.

3. **Verify `native_toolchain_c` version compatibility.**  Open `pubspec.yaml`
   and confirm the constraint on `native_toolchain_c` matches the version
   required by the hook. Run `dart pub upgrade` if in doubt.

4. **Clean and retry.**

   ```bash
   flutter clean
   dart pub get
   flutter test
   ```

---

## 3. Controller always returns `CameraTier.basic`

**Problem**

Every `CameraProController` instance reports `controller.tier == CameraTier.basic`
regardless of the device, and all `Capability` fields come back as
`NotSupported`.

**Cause**

Whether this is expected depends on the platform. In v0.0.2 the default backend
is selected per target:

| Platform | Default backend in v0.0.2 |
|----------|---------------------------|
| Apple AVFoundation (macOS/iOS) | ✅ `AppleCameraBackend` — wired, live-verified on real Mac cameras; all six manual controls reach `CameraTier.full` (via the digital pipeline where the sensor exposes no controls) |
| Web | ✅ `WebCameraBackend` (getUserMedia) — wired, live-verified in Chrome; all six manual controls reach `CameraTier.full` via the pure-Dart digital pipeline |
| Linux V4L2 | 🚧 Full 44-function C HAL implemented and CI-tested, but not yet exposed as a Dart backend — falls back to the stub |
| Windows Media Foundation | 🚧 Full 44-function C HAL implemented and CI-tested, but not yet exposed as a Dart backend — falls back to the stub |
| Android | 🚧 Not started — falls back to the stub |

On the platforms that fall back to `StubCameraBackend` — a conformant no-op HAL
that returns an empty `CameraCapabilities` (all capabilities `NotSupported`) —
`determineTier(caps)` returns `CameraTier.basic` whenever no capabilities are
supported, which is the correct result for the stub.

**Fix**

- **On Linux desktop, Windows desktop, or Android** there is nothing to fix;
  the behavior is correct for v0.0.2. Use `CameraTier.basic` as the trigger to
  display a "limited functionality" banner in your UI, and watch the repository
  for the Dart backend wiring for these platforms (the Linux/Windows C HALs
  already exist and pass the portable lifecycle harness on CI).
- **On macOS, iOS, or web**, `CameraTier.basic` is *not* expected — verify that
  camera permission was granted and that a camera device actually enumerates.
- Supply a custom `CameraBackend` to `CameraPro.create(backend: myBackend)` if
  you are implementing your own HAL.

---

## 4. `flutter test` recompiles the native core on every run

**Problem**

Each `flutter test` invocation takes noticeably longer than expected because
the C core is rebuilt from source every time.

**Cause**

Flutter's native-assets build system caches compiled artifacts, but the cache
is keyed on source file hashes and build configuration. If any of the following
change between runs, a rebuild is triggered:

- Any `src/core/*.c` file or platform backend source (`src/platform/apple/*.m`,
  `src/platform/stub/*.c`) is modified (expected).
- The build configuration (target OS, architecture, optimization level) changes.
- The Flutter tool is upgraded, invalidating the build cache.
- The working directory or project path changes (cache paths include the project
  path on some platforms).

**Fix**

1. Avoid unnecessary changes to C source files during development when you only
   need to run Dart tests.

2. If the cache appears corrupt (rebuilds every run with no source changes),
   clear it:

   ```bash
   flutter clean
   dart pub get
   flutter test
   ```

3. For CI pipelines, cache the Flutter build directory (`.dart_tool/`) between
   runs to avoid cold-start rebuilds:

   ```yaml
   # GitHub Actions example
   - uses: actions/cache@v4
     with:
       path: |
         ~/.pub-cache
         .dart_tool/
       key: ${{ runner.os }}-flutter-${{ hashFiles('pubspec.lock', 'src/**/*.c') }}
   ```

---

## 5. `ffigen` fails with "could not find libclang"

**Problem**

Running `dart run ffigen` (to regenerate the FFI bindings from
`camera_pro_core.h`) fails with:

```
Could not find dynamic library for libclang.
Looked in: /usr/lib/libclang.so, ...
```

**Cause**

`ffigen` parses C headers using libclang. It requires the `libclang` shared
library to be installed separately from the C compiler itself.

**Fix**

- **macOS**: libclang ships with Xcode. Ensure Xcode command-line tools are
  installed (`xcode-select --install`). If using Homebrew LLVM, set the
  `LLVM_PATH` environment variable:

  ```bash
  export LLVM_PATH=$(brew --prefix llvm)
  dart run ffigen
  ```

- **Linux (Debian/Ubuntu)**:

  ```bash
  sudo apt-get install libclang-dev
  dart run ffigen
  ```

- **Windows**: Install LLVM from https://releases.llvm.org/ and add the `bin`
  directory to `PATH`. Then set `LLVM_PATH` to the LLVM install root in
  `ffigen.yaml` or as an environment variable.

**Note**: Running `ffigen` is entirely optional. The bindings shipped in
v0.0.2 (`lib/src/ffi/camera_pro_bindings.dart`) are hand-maintained `@Native`
bindings kept 1:1 with `camera_pro_core.h` and regression-tested per symbol, so
the package builds and works out of the box without libclang. Regeneration via
`ffigen.yaml` is only relevant if you modify `camera_pro_core.h` and prefer
generating over hand-editing.

---

## 6. Capability-guarded setters throw `CameraFeatureNotSupportedError`

**Problem**

Calling a setter such as `controller.setIso(const Iso(100))` throws
`CameraFeatureNotSupportedError` instead of applying the setting.

**Cause**

This is **correct, intentional behavior — not a bug**.

Every setter checks the corresponding `Capability` field on `controller.capabilities`
before delegating to the backend. If the capability is `NotSupported`, the setter
throws `CameraFeatureNotSupportedError` immediately, before any native call is
made. On the stub backend (and on real hardware that lacks a given feature) this
is the expected outcome.

The pattern prevents silent no-ops and ensures your UI knows exactly which
features are available on the current device.

**Fix**

Guard every setter with a capability check before calling it:

```dart
switch (controller.capabilities.iso) {
  case Supported<int>(:final minValue, :final maxValue, :final currentValue):
    // Safe to call setIso — show a slider bounded to [minValue, maxValue].
    await controller.setIso(const Iso(400));

  case NotSupported<int>(:final reason):
    // Disable the ISO control and surface the reason in your UI.
    print('ISO not supported: $reason');
}
```

Alternatively, wrap the call in a try/catch where you prefer an imperative style:

```dart
try {
  await controller.setIso(const Iso(400));
} on CameraFeatureNotSupportedError catch (e) {
  // e.recovery tells you what the user or app can do next.
  _showFeatureUnavailableToast(e.message);
}
```

**Tip**: On the stub backend — the fallback on Linux desktop, Windows desktop,
and Android in v0.0.2 — *all* setters will throw this error because the stub
reports no capabilities as supported. This is expected there until the Dart
backends for those platforms land. On macOS, iOS, and web the wired backends
report all six manual controls (ISO, shutter, EV, white balance, focus, zoom)
as `Supported`, so these setters succeed.

---

## 7. Reading and acting on `CameraProError.recovery`

**Problem**

A `CameraProError` is caught but it is unclear what the application should do
next.

**Cause**

All errors in `camera_pro` are subtypes of the sealed class `CameraProError`.
Each instance carries a `recovery` field of type `CameraErrorRecovery` that
encodes the recommended recovery action.

**Fix**

Match on `recovery` to drive your error-handling logic:

```dart
try {
  await controller.capturePhoto();
} on CameraProError catch (e) {
  switch (e.recovery) {
    case CameraErrorRecovery.retry:
      // Transient glitch; retry without user intervention.
      await controller.capturePhoto();

    case CameraErrorRecovery.automatic:
      // Back off briefly then retry (e.g. thermal throttle easing).
      await Future<void>.delayed(const Duration(seconds: 2));
      await controller.capturePhoto();

    case CameraErrorRecovery.requestPermission:
      // Navigate the user to the permission request flow.
      _openPermissionSettings();

    case CameraErrorRecovery.userAction:
      // The current device is unavailable; offer an alternative.
      _promptUserToSwitchCamera();

    case CameraErrorRecovery.reinitialize:
      // Dispose and recreate the controller.
      await controller.dispose();
      _controller = await CameraPro.create();

    case CameraErrorRecovery.fatal:
      // Non-recoverable. Surface the error and let the user exit.
      _showFatalErrorDialog(e.message);
  }
}
```

**Error subtype reference**

| Subtype | Typical `recovery` value |
|---------|--------------------------|
| `CameraPermissionError` | `requestPermission` |
| `CameraDeviceError` | `switchCamera` or `restartSession` |
| `CameraInUseError` | `retryAfterDelay` |
| `CameraSessionInterruptedError` | `restartSession` |
| `CameraThermalThrottleError` | `retryAfterDelay` |
| `CameraFeatureNotSupportedError` | `fatal` (feature absent on device) |
| `CameraCaptureError` | `retryImmediately` |
| `CameraServiceFatalError` | `fatal` |
| `CameraInvalidParameterError` | `fatal` (fix the calling code) |

> The `recovery` values shown above are the most common defaults. Always read
> the actual `recovery` field at runtime rather than hard-coding the subtype →
> recovery mapping, as the value may vary depending on context.

---

*Last updated: 2026-07-04 — camera_pro v0.0.2*
