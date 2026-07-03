/// Native (dart:ffi) platform implementations, selected on non-web targets.
library;

export 'ffi/native_core.dart' show NativeBufferPool, NativeCore;
export 'platform/apple/apple_camera_backend.dart' show AppleCameraBackend;
export 'platform/apple/metal_compute.dart' show MetalCompute;
