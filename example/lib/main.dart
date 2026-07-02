// camera_pro example.
//
// Shows a LIVE preview from the native camera (frames delivered over FFI and
// painted with dart:ui), the "Capability Passport", the control tier, and the
// crash-proof typed-error handling. Falls back to a capabilities-only view when
// no camera is available.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:camera_pro/camera_pro.dart';
import 'package:flutter/material.dart';

void main() => runApp(const CameraProExampleApp());

class CameraProExampleApp extends StatelessWidget {
  const CameraProExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'camera_pro example',
      theme: ThemeData.dark(useMaterial3: true),
      home: const CapabilityPage(),
    );
  }
}

class CapabilityPage extends StatefulWidget {
  const CapabilityPage({super.key});

  @override
  State<CapabilityPage> createState() => _CapabilityPageState();
}

class _CapabilityPageState extends State<CapabilityPage> {
  CameraProController? _controller;
  String _nativeVersion = 'unknown';
  String _simd = 'unknown';
  String? _error;

  Timer? _frameTimer;
  ui.Image? _preview;
  bool _decoding = false;
  int _frames = 0;
  HistogramData? _hist;
  String? _savedPath;
  bool _recording = false;
  bool _focusPeaking = false;
  bool _zebra = false;
  bool _falseColor = false;
  bool _waveform = false;
  WaveformData? _wf;

  // Live manual-control state.
  double _iso = 100;
  double _shutterDenom = 60; // 1/60s
  double _ev = 0;
  double _wb = 5500;
  double _focus = 0.5;
  double _zoom = 1;

  Future<void> _apply(Future<void> Function() action) async {
    try {
      await action();
    } on CameraProError catch (e) {
      setState(() => _error = '${e.runtimeType}: ${e.message}');
    }
  }

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      _nativeVersion = CameraPro.nativeCoreVersion;
      _simd = CameraPro.simdKernel;
    } on Object catch (e) {
      _nativeVersion = 'native core unavailable ($e)';
    }

    CameraProController controller;
    try {
      controller = await CameraPro.create();
    } on Object {
      controller = await CameraPro.create(backend: StubCameraBackend());
    }
    if (!mounted) return;
    setState(() => _controller = controller);

    // Start the live preview stream (this triggers the OS camera-permission
    // prompt on first run) and poll frames ~30x/sec.
    await controller.startPreviewStream();
    _frameTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      _pumpFrame();
    });
  }

  void _pumpFrame() {
    final controller = _controller;
    if (controller == null || _decoding) return;
    final frame = controller.latestPreviewFrame();
    if (frame == null) return;

    // Live histogram (+ optional waveform), computed by the native C core.
    if (_frames % 3 == 0) {
      try {
        _hist = NativeCore.histogramFromRgba(
          frame.bytes,
          width: frame.width,
          height: frame.height,
        );
        if (_waveform) {
          _wf = NativeCore.waveformFromRgba(
            frame.bytes,
            width: frame.width,
            height: frame.height,
            columns: 128,
            isBgra: frame.isBgra,
          );
        }
      } on Object {
        // ignore — visual aids are best-effort
      }
    }

    // Apply the selected visual-aid overlay in the native C core.
    var pixels = frame.bytes;
    if (_focusPeaking) {
      pixels = NativeCore.focusPeaking(
        frame.bytes,
        width: frame.width,
        height: frame.height,
        isBgra: frame.isBgra,
        threshold: 0.1,
        peakColor: 0x00FFFFFF, // cyan (classic focus-peaking colour)
      );
    } else if (_zebra) {
      pixels = NativeCore.zebra(frame.bytes,
          width: frame.width,
          height: frame.height,
          isBgra: frame.isBgra,
          frameCounter: _frames);
    } else if (_falseColor) {
      pixels = NativeCore.falseColorFromRgba(frame.bytes,
          width: frame.width, height: frame.height, isBgra: frame.isBgra);
    }

    _decoding = true;
    ui.decodeImageFromPixels(
      pixels,
      frame.width,
      frame.height,
      frame.isBgra ? ui.PixelFormat.bgra8888 : ui.PixelFormat.rgba8888,
      (image) {
        _decoding = false;
        if (!mounted) {
          image.dispose();
          return;
        }
        setState(() {
          _preview?.dispose();
          _preview = image;
          _frames = controller.previewFrameCount;
        });
      },
    );
  }

  Future<void> _attemptCapture() async {
    final controller = _controller;
    if (controller == null) return;
    setState(() => _error = null);
    try {
      final photo = await controller.capturePhoto(format: ImageFormat.png);
      setState(() => _savedPath = photo.path);
      _showSnack('Captured ${photo.width}x${photo.height} → ${photo.path}');
    } on CameraProError catch (e) {
      setState(() => _error = '${e.runtimeType}: ${e.message}');
      _showSnack('Recovery: ${e.recovery.name}');
    }
  }

  Future<void> _burst() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      final photos = await controller.captureBurst(count: 5);
      setState(() => _savedPath = photos.last.path);
      _showSnack('Burst: ${photos.length} photos saved');
    } on Object catch (e) {
      setState(() => _error = '$e');
    }
  }

  Future<void> _bracket() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      final photos = await controller
          .captureExposureBracket(stops: const <double>[-2, 0, 2]);
      setState(() => _savedPath = photos.last.path);
      _showSnack('Bracket: ${photos.length} photos at -2/0/+2 EV');
    } on Object catch (e) {
      setState(() => _error = '$e');
    }
  }

  Future<void> _toggleRecording() async {
    final controller = _controller;
    if (controller == null) return;
    setState(() => _error = null);
    try {
      if (_recording) {
        final video = await controller.stopVideoRecording();
        setState(() {
          _recording = false;
          _savedPath = video.path;
        });
        _showSnack('Recorded ${video.duration.inSeconds}s '
            '(${video.fileSizeBytes ?? 0} bytes) → ${video.path}');
      } else {
        final ts = DateTime.now().millisecondsSinceEpoch;
        final path = '${Directory.systemTemp.path}/camera_pro_$ts.mov';
        await controller.startVideoRecording(path);
        setState(() => _recording = true);
      }
    } on Object catch (e) {
      setState(() {
        _recording = false;
        _error = '$e';
      });
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _frameTimer?.cancel();
    _preview?.dispose();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      appBar: AppBar(title: const Text('camera_pro')),
      floatingActionButton: controller == null
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                FloatingActionButton.extended(
                  heroTag: 'record',
                  backgroundColor: _recording ? Colors.red : null,
                  onPressed: _toggleRecording,
                  icon: Icon(_recording ? Icons.stop : Icons.fiber_manual_record),
                  label: Text(_recording ? 'Stop' : 'Record'),
                ),
                const SizedBox(width: 12),
                FloatingActionButton.small(
                  heroTag: 'burst',
                  tooltip: 'Burst (5 shots)',
                  onPressed: _burst,
                  child: const Icon(Icons.burst_mode),
                ),
                const SizedBox(width: 12),
                FloatingActionButton.small(
                  heroTag: 'bracket',
                  tooltip: 'EV bracket (-2/0/+2)',
                  onPressed: _bracket,
                  child: const Icon(Icons.exposure),
                ),
                const SizedBox(width: 12),
                FloatingActionButton.extended(
                  heroTag: 'capture',
                  onPressed: _attemptCapture,
                  icon: const Icon(Icons.camera),
                  label: const Text('Capture'),
                ),
              ],
            ),
      body: controller == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                _PreviewArea(
                  image: _preview,
                  frames: _frames,
                  hist: _hist,
                  waveform: _waveform ? _wf : null,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: <Widget>[
                    FilterChip(
                      label: const Text('Focus peaking'),
                      avatar: const Icon(Icons.filter_center_focus, size: 16),
                      selected: _focusPeaking,
                      onSelected: (v) => setState(() {
                        _focusPeaking = v;
                        if (v) _zebra = _falseColor = false;
                      }),
                    ),
                    FilterChip(
                      label: const Text('Zebra'),
                      avatar: const Icon(Icons.gradient, size: 16),
                      selected: _zebra,
                      onSelected: (v) => setState(() {
                        _zebra = v;
                        if (v) _focusPeaking = _falseColor = false;
                      }),
                    ),
                    FilterChip(
                      label: const Text('False color'),
                      avatar: const Icon(Icons.palette, size: 16),
                      selected: _falseColor,
                      onSelected: (v) => setState(() {
                        _falseColor = v;
                        if (v) _focusPeaking = _zebra = false;
                      }),
                    ),
                    FilterChip(
                      label: const Text('Waveform'),
                      avatar: const Icon(Icons.show_chart, size: 16),
                      selected: _waveform,
                      onSelected: (v) => setState(() {
                        _waveform = v;
                        if (!v) _wf = null;
                      }),
                    ),
                  ],
                ),
                if (_savedPath != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      children: <Widget>[
                        const Icon(Icons.check_circle,
                            color: Colors.greenAccent, size: 16),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text('Saved: $_savedPath',
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.greenAccent)),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 12),
                _InfoCard(
                  nativeVersion: _nativeVersion,
                  simd: _simd,
                  tier: controller.tier,
                  caps: controller.capabilities,
                ),
                ..._buildControls(controller),
                if (_error != null)
                  Card(
                    color: Colors.red.shade900,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(_error!),
                    ),
                  ),
                const SizedBox(height: 8),
                const Text('Capabilities',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                const SizedBox(height: 8),
                ..._capabilityRows(controller.capabilities),
              ],
            ),
    );
  }

  List<Widget> _buildControls(CameraProController controller) {
    final caps = controller.capabilities;
    final rows = <Widget>[];

    if (caps.iso case Supported<int>(:final minValue, :final maxValue)) {
      rows.add(_slider('ISO', _iso, minValue.toDouble(), maxValue.toDouble(),
          _iso.round().toString(), (v) {
        setState(() => _iso = v);
        _apply(() => controller.setIso(Iso(v.round())));
      }));
    }
    if (caps.shutterSpeed
        case Supported<Duration>(:final minValue, :final maxValue)) {
      final minDenom = 1000000 / maxValue.inMicroseconds; // slow -> small denom
      final maxDenom = 1000000 / minValue.inMicroseconds; // fast -> large denom
      rows.add(_slider('Shutter', _shutterDenom, minDenom, maxDenom,
          '1/${_shutterDenom.round()}', (v) {
        setState(() => _shutterDenom = v);
        _apply(() =>
            controller.setShutterSpeed(ShutterSpeed.fromFraction(1, v.round())));
      }));
    }
    if (caps.exposureCompensation
        case Supported<double>(:final minValue, :final maxValue)) {
      rows.add(_slider('Exposure (EV)', _ev, minValue, maxValue,
          '${_ev >= 0 ? '+' : ''}${_ev.toStringAsFixed(1)}', (v) {
        setState(() => _ev = v);
        _apply(() => controller.setExposureCompensation(Ev(v)));
      }));
    }
    if (caps.whiteBalanceKelvin
        case Supported<int>(:final minValue, :final maxValue)) {
      rows.add(_slider('White balance', _wb, minValue.toDouble(),
          maxValue.toDouble(), '${_wb.round()}K', (v) {
        setState(() => _wb = v);
        _apply(() => controller.setWhiteBalance(WhiteBalance.temperature(v.round())));
      }));
    }
    if (caps.focusDistance
        case Supported<double>(:final minValue, :final maxValue)) {
      rows.add(_slider('Focus', _focus, minValue, maxValue,
          _focus.toStringAsFixed(2), (v) {
        setState(() => _focus = v);
        _apply(() => controller.setFocusDistance(v));
      }));
    }
    if (caps.zoom case Supported<double>(:final minValue, :final maxValue)) {
      rows.add(_slider('Zoom', _zoom, minValue, maxValue,
          '${_zoom.toStringAsFixed(1)}x', (v) {
        setState(() => _zoom = v);
        _apply(() => controller.setZoom(v));
      }));
    }

    if (rows.isEmpty) return const <Widget>[];
    return <Widget>[
      const SizedBox(height: 8),
      Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(children: const <Widget>[
                Icon(Icons.tune, size: 18),
                SizedBox(width: 6),
                Text('Manual controls',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ]),
              if (controller.tier != CameraTier.full)
                const Padding(
                  padding: EdgeInsets.only(top: 2, bottom: 4),
                  child: Text(
                    'digital pipeline (this camera has no sensor controls)',
                    style: TextStyle(fontSize: 11, color: Colors.white54),
                  ),
                ),
              ...rows,
            ],
          ),
        ),
      ),
    ];
  }

  Widget _slider(String label, double value, double min, double max,
      String valueLabel, ValueChanged<double> onChanged) {
    return Row(
      children: <Widget>[
        SizedBox(
            width: 96,
            child: Text(label, style: const TextStyle(fontSize: 13))),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
            width: 56,
            child: Text(valueLabel,
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 12))),
      ],
    );
  }

  List<Widget> _capabilityRows(CameraCapabilities caps) {
    return <Widget>[
      _capRow('Manual ISO', caps.iso),
      _capRow('Shutter speed', caps.shutterSpeed),
      _capRow('White balance (K)', caps.whiteBalanceKelvin),
      _capRow('Manual focus', caps.focusDistance),
      _capRow('Exposure comp.', caps.exposureCompensation),
      _capRow('Zoom', caps.zoom),
      _boolRow('RAW capture', caps.supportsRawCapture),
      _boolRow('HDR', caps.supportsHdr),
      _boolRow('Flash', caps.hasFlash),
      _boolRow('Multi-camera', caps.supportsMultiCamera),
    ];
  }

  Widget _capRow<T>(String label, Capability<T> cap) {
    final supported = cap.isSupported;
    final detail = switch (cap) {
      Supported<T>(:final minValue, :final maxValue) => '$minValue … $maxValue',
      NotSupported<T>(:final reason) => reason,
    };
    return ListTile(
      dense: true,
      leading: Icon(
        supported ? Icons.check_circle : Icons.cancel,
        color: supported ? Colors.greenAccent : Colors.grey,
      ),
      title: Text(label),
      subtitle: Text(detail),
    );
  }

  Widget _boolRow(String label, bool value) {
    return ListTile(
      dense: true,
      leading: Icon(
        value ? Icons.check_circle : Icons.cancel,
        color: value ? Colors.greenAccent : Colors.grey,
      ),
      title: Text(label),
    );
  }
}

class _PreviewArea extends StatelessWidget {
  const _PreviewArea({
    required this.image,
    required this.frames,
    required this.hist,
    required this.waveform,
  });

  final ui.Image? image;
  final int frames;
  final HistogramData? hist;
  final WaveformData? waveform;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 4 / 3,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white24),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: image == null
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(Icons.videocam_off, size: 40, color: Colors.white54),
                      SizedBox(height: 8),
                      Text('Waiting for camera…\n(grant permission if prompted)',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white54)),
                    ],
                  ),
                )
              : Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    RawImage(image: image, fit: BoxFit.cover),
                    Positioned(
                      left: 8,
                      top: 8,
                      child: Container(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text('● LIVE  ·  $frames frames',
                            style: const TextStyle(
                                color: Colors.redAccent, fontSize: 12)),
                      ),
                    ),
                    if (hist != null)
                      Positioned(
                        right: 8,
                        top: 8,
                        child: Container(
                          width: 128,
                          height: 72,
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: CustomPaint(painter: _HistogramPainter(hist!)),
                        ),
                      ),
                    if (waveform != null)
                      Positioned(
                        left: 8,
                        right: 8,
                        bottom: 8,
                        height: 72,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.55),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: CustomPaint(painter: _WaveformPainter(waveform!)),
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// Paints the native-computed luminance + RGB histogram.
class _HistogramPainter extends CustomPainter {
  _HistogramPainter(this.hist);

  final HistogramData hist;

  @override
  void paint(Canvas canvas, Size size) {
    final peak = hist.peak;
    if (peak == 0) return;
    final channels = <(List<int>, Color)>[
      (hist.red, Colors.red.withValues(alpha: 0.6)),
      (hist.green, Colors.green.withValues(alpha: 0.6)),
      (hist.blue, Colors.blue.withValues(alpha: 0.6)),
      (hist.luminance, Colors.white.withValues(alpha: 0.85)),
    ];
    final dx = size.width / 256.0;
    for (final (bins, color) in channels) {
      final paint = Paint()
        ..color = color
        ..strokeWidth = dx
        ..style = PaintingStyle.stroke;
      for (var i = 0; i < 256; i++) {
        final h = (bins[i] / peak) * size.height;
        if (h <= 0) continue;
        final x = i * dx + dx / 2;
        canvas.drawLine(
            Offset(x, size.height), Offset(x, size.height - h), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_HistogramPainter oldDelegate) => true;
}

/// Paints the native-computed luminance waveform (x = column, y = luma).
class _WaveformPainter extends CustomPainter {
  _WaveformPainter(this.wf);

  final WaveformData wf;

  @override
  void paint(Canvas canvas, Size size) {
    // Normalise per-column so faint traces stay visible.
    var peak = 1;
    for (final v in wf.bins) {
      if (v > peak) peak = v;
    }
    final dx = size.width / wf.columns;
    final paint = Paint()..strokeWidth = 1;
    for (var c = 0; c < wf.columns; c++) {
      final x = c * dx + dx / 2;
      for (var luma = 0; luma < 256; luma++) {
        final count = wf.at(c, luma);
        if (count == 0) continue;
        final intensity = (count / peak).clamp(0.05, 1.0);
        // y: luma 255 at top, 0 at bottom.
        final y = size.height * (1 - luma / 255.0);
        paint.color = Colors.greenAccent.withValues(alpha: intensity * 0.9);
        canvas.drawRect(Rect.fromLTWH(x, y, dx, 1), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter oldDelegate) => true;
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.nativeVersion,
    required this.simd,
    required this.tier,
    required this.caps,
  });

  final String nativeVersion;
  final String simd;
  final CameraTier tier;
  final CameraCapabilities caps;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Device: ${caps.deviceName}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            Text('Platform: ${caps.platformName}'),
            Text('Native core: $nativeVersion  ·  SIMD: $simd'),
            const SizedBox(height: 8),
            Chip(label: Text('Tier: ${tier.label}')),
          ],
        ),
      ),
    );
  }
}
