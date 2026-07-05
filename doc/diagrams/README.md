# camera_pro — architecture diagrams

Animated explanatory diagrams of how `camera_pro` works. They render (and
animate) natively on GitHub. Each is a self-contained, dependency-free SVG.

> On pub.dev, SVGs may render as a static first frame — view this page on
> GitHub for the animation.

## Architecture · the one FFI hop

A camera frame's path from sensor to live overlay, and the single Dart ↔ native
boundary it crosses.

![Architecture and FFI flow](architecture-ffi-flow.svg)

## Capability passport → tier

Every feature is reported as `Supported` or `NotSupported`; `determineTier`
maps the passport to Full / Standard / Basic.

![Capability passport to tier](capability-passport-tier.svg)

## Visual-aids pipeline

One preview frame, dispatched to the Metal GPU when available or the SIMD CPU
core otherwise — both produce byte-identical overlays.

![Visual-aids pipeline](visual-aids-pipeline.svg)

## Digital manual-control pipeline

When a camera exposes no sensor controls (the macOS built-in camera, most
browsers), the six controls are applied digitally per frame — so the device
still reaches `CameraTier.full`.

![Digital manual-control pipeline](digital-controls.svg)

## Web pure-Dart split

A single conditional export keeps `dart:ffi` / `dart:io` off the web build; the
browser gets a pure-Dart `WebCameraBackend` with the C kernels ported to Dart.

![Web pure-Dart split](web-puredart-split.svg)
