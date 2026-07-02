/// Custom frame-processor plugin API.
///
/// Processors receive every polled preview frame ([PreviewFrame]) — for ML
/// inference, barcode scanning, custom analysis. They run synchronously on the
/// frame-poll path, so keep [onFrame] fast (< a frame interval) or hand the
/// bytes off to an isolate.
library;

import '../controller/camera_backend.dart';
import '../models/capabilities.dart';

/// A plugin that observes live preview frames.
abstract class FrameProcessor {
  /// Called once when attached, with the device's capability passport.
  void onAttach(CameraCapabilities capabilities) {}

  /// Called for each polled preview frame.
  void onFrame(PreviewFrame frame);

  /// Called once when detached.
  void onDetach() {}
}
