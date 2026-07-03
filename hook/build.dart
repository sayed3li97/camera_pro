// Native-assets build hook.
//
// Compiles the shared C core plus the platform backend into a single code asset
// that the `@Native` externals bind to (asset id must match the
// `@DefaultAsset(...)` in lib/src/ffi/camera_pro_bindings.dart).
//
// Backend selection by target OS:
//   - Apple (macOS/iOS): the AVFoundation HAL (Objective-C, links AVFoundation
//     & friends). Compiled with ARC.
//   - everything else:   the conformant stub HAL (until a native backend lands).
//
// Runs automatically during `flutter run`/`build`/`test`.

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    // Web (and any target that doesn't request code assets) has no C core —
    // the pure-Dart NativeCore is used there. Nothing to compile.
    if (!input.config.buildCodeAssets) return;

    final targetOS = input.config.code.targetOS;
    final isApple = targetOS == OS.macOS || targetOS == OS.iOS;

    const coreSources = <String>[
      'src/core/buffer_pool.c',
      'src/core/image_processor.c',
      'src/core/format_converter.c',
      'src/core/dng_writer.c',
      'src/core/camera_pro_core.c',
    ];
    final backendSources = isApple
        ? <String>[
            'src/platform/apple/camera_hal_apple.m',
            'src/platform/apple/metal_processor.m',
          ]
        : <String>['src/platform/stub/camera_hal_stub.c'];

    final builder = CBuilder.library(
      name: 'camera_pro_core',
      assetName: 'src/ffi/camera_pro_bindings.dart',
      language: isApple ? Language.objectiveC : Language.c,
      sources: <String>[...coreSources, ...backendSources],
      includes: <String>[
        'src/core',
        'src/hal',
        if (isApple) 'src/platform/apple',
      ],
      frameworks: isApple
          ? <String>[
              'AVFoundation',
              'Foundation',
              'CoreMedia',
              'CoreVideo',
              'Metal',
            ]
          : <String>[],
      flags: <String>[
        '-ffast-math',
        if (isApple) '-fobjc-arc',
      ],
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
