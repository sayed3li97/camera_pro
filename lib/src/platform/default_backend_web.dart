/// Default backend for the web target.
library;

import '../controller/camera_backend.dart';
import '../web/web_camera_backend.dart';

/// The MediaDevices/getUserMedia backend.
CameraBackend defaultCameraBackend() => WebCameraBackend();
