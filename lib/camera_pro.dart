/// camera_pro — DSLR-grade camera controls with a native C/C++ core over FFI.
///
/// See the [CameraPro] entrypoint to create a controller, and
/// [CameraProController] for capture and manual controls. The public API is
/// capability-aware: query [CameraCapabilities] and pattern-match on
/// [Capability] to build UI that can't request an unsupported control.
library;

export 'src/camera_pro_base.dart' show CameraPro;
// Controller & lifecycle
export 'src/controller/camera_backend.dart'
    show CameraBackend, StubCameraBackend;
export 'src/controller/camera_pro_controller.dart'
    show CameraProController, CameraSettings;
export 'src/controller/camera_state_machine.dart' show CameraStateMachine;
export 'src/controller/camera_tier.dart' show CameraTier, determineTier;
// FFI facade (native core helpers)
export 'src/ffi/native_core.dart' show NativeBufferPool, NativeCore;
// Models
export 'src/models/camera_device.dart'
    show CameraDevice, CameraList, LensDirection, LensType;
export 'src/models/camera_state.dart'
    show CameraState, CameraStateChange, CameraStateException;
export 'src/models/capabilities.dart'
    show Capability, CameraCapabilities, NotSupported, Supported;
export 'src/models/capture_result.dart'
    show BurstFrame, CapturedPhoto, DepthData, ExifData, VideoResult;
export 'src/models/errors.dart';
export 'src/models/settings.dart';
// Platform
export 'src/platform/device_quirks.dart'
    show DeviceQuirk, DeviceQuirkEntry, kDeviceQuirks, quirksFor;
export 'src/platform/thermal.dart'
    show ThermalLevel, ThermalPolicy, ThermalStatus;
// Processing
export 'src/processing/histogram.dart' show HistogramData;
// Utils
export 'src/utils/result.dart' show Err, Ok, Result;
