/// Selects the default [CameraBackend] for the current platform via a
/// conditional import, so the web build never pulls in `dart:io`/`dart:ffi`.
library;

export 'default_backend_io.dart'
    if (dart.library.js_interop) 'default_backend_web.dart';
