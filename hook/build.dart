// Native-assets build hook.
//
// Compiles the shared C core (src/core + the stub HAL) into a code asset that
// the `@Native` externals in lib/src/ffi/camera_pro_bindings.dart bind to. The
// `assetName` here must match the `@DefaultAsset(...)` id in that file.
//
// This runs automatically during `flutter run`/`build`/`test` when native
// assets are enabled. Platform-specific HALs (Android NDK, Apple AVFoundation,
// etc.) are linked separately via each platform's CMake/podspec — see
// ARCHITECTURE.md → "Build system".

import 'dart:io';

import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    final builder = CBuilder.library(
      name: 'camera_pro_core',
      assetName: 'src/ffi/camera_pro_bindings.dart',
      sources: <String>[
        'src/core/buffer_pool.c',
        'src/core/image_processor.c',
        'src/core/format_converter.c',
        'src/core/camera_pro_core.c',
        'src/platform/stub/camera_hal_stub.c',
      ],
      includes: <String>['src/core', 'src/hal'],
      flags: <String>['-ffast-math'],
    );

    // Per-logger levels require hierarchical logging to be enabled first.
    hierarchicalLoggingEnabled = true;
    await builder.run(
      input: input,
      output: output,
      logger: Logger('camera_pro')
        ..level = Level.INFO
        ..onRecord.listen((record) {
          stderr.writeln('${record.level.name}: ${record.message}');
        }),
    );
  });
}
