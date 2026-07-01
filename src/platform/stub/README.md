# Stub HAL backend ✅

`camera_hal_stub.c` is a **conformant no-op implementation** of the entire
`hal/camera_hal.h` contract. It exists for two reasons:

1. **Contract proof.** It compiles as part of the unit build on every platform,
   guaranteeing `camera_hal.h` is a complete, implementable C interface. If a
   function is added to the HAL, the stub must implement it or the build breaks.

2. **Safe default.** On any platform whose real HAL is not yet wired, the SDK
   links the stub instead of crashing. The stub reports **zero devices** and
   returns `CAMERA_ERROR_FEATURE_NOT_SUPPORTED` for every control, so the Dart
   layer degrades to `CameraTier.basic` and every capability reads as
   `NotSupported`.

This is why, today, `CameraPro.create()` succeeds everywhere but manual controls
raise a typed `CameraFeatureNotSupportedError` — the crash-proof contract holds
even with no camera present.

When you implement a real backend (see the sibling platform READMEs), it
replaces the stub at link time for that platform.
