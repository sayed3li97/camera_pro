/// Conditional re-export of [NativeCore] — the FFI implementation on native,
/// the pure-Dart implementation on web.
library;

export 'ffi/native_core.dart'
    if (dart.library.js_interop) 'web/native_core_web.dart' show NativeCore;
