# Native core (`src/`)

The portable C/C++ heart of `camera_pro`. Everything here is platform-agnostic
except `platform/`, which contains one backend per OS implementing the single C
contract in `hal/camera_hal.h`.

```
src/
├── core/                     # Shared, portable C core (compiled everywhere)
│   ├── camera_pro_core.h     # ★ Public FFI boundary (Dart binds to this)
│   ├── camera_pro_types.h    # Shared enums (errors, pixel formats, states)
│   ├── buffer_pool.c         # Lock-free, cache-line-aligned frame buffer pool
│   ├── image_processor.c     # SIMD histogram (NEON/SSE) + focus peaking + zebra
│   ├── format_converter.c    # Scalar BT.601 YUV420P/NV12/NV21 → RGBA
│   └── camera_pro_core.c      # Version + error-string introspection
├── hal/
│   └── camera_hal.h          # ★ Platform abstraction contract (one per OS)
├── platform/
│   ├── stub/                 # ✅ Conformant no-op HAL (built into unit build)
│   ├── android/ apple/ windows/ linux/ web/   # 🚧 Real backends (scaffolded)
└── tests/
    └── core_test.c           # Standalone C test harness (36 checks)
```

## Building & testing the core standalone

The core has **no external dependencies** — it compiles with just a C11
compiler. To build and run the test harness:

```sh
clang -std=c11 -O2 -Wall -Wextra -Werror -I src/core -I src/hal \
  src/core/buffer_pool.c src/core/image_processor.c \
  src/core/format_converter.c src/core/camera_pro_core.c \
  src/platform/stub/camera_hal_stub.c src/tests/core_test.c \
  -o core_test && ./core_test
```

Expected: `36 checks, 0 failures`. The harness cross-checks the SIMD histogram
against the scalar reference for bit-exact equality.

## How the core reaches Dart

`hook/build.dart` (Dart native-assets) compiles `core/*.c` plus the stub HAL
into a code asset that the `@Native` externals in
`lib/src/ffi/camera_pro_bindings.dart` bind to. No manual FFI glue, no dlopen.

Platform HALs (Android NDK, Apple AVFoundation, …) are **not yet implemented** —
see each `platform/<name>/README.md`.
