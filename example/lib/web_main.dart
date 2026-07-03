// camera_pro — web sample app.
//
// A browser camera demo on the same camera_pro API used on native: getUserMedia
// preview (WebCameraBackend), the capability passport, and the pure-Dart visual
// aids (histogram / focus peaking / zebra / false color / waveform) computed on
// each frame. No dart:io / file paths — captures are held in memory.
import 'dart:async';
import 'dart:ui' as ui;

import 'package:camera_pro/camera_pro.dart';
import 'package:flutter/material.dart';

void main() => runApp(const CameraProWebApp());

class CameraProWebApp extends StatelessWidget {
  const CameraProWebApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'camera_pro (web)',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const WebCameraPage(),
    );
  }
}

class WebCameraPage extends StatefulWidget {
  const WebCameraPage({super.key});

  @override
  State<WebCameraPage> createState() => _WebCameraPageState();
}

class _WebCameraPageState extends State<WebCameraPage> {
  CameraProController? _controller;
  String? _error;
  Timer? _timer;
  ui.Image? _preview;
  ui.Image? _captured;
  bool _decoding = false;
  int _frames = 0;
  HistogramData? _hist;

  String _overlay = 'none'; // none | peaking | zebra | falsecolor | waveform
  WaveformData? _wf;

  @override
  void initState() {
    super.initState();
    // Allow deterministic overlay selection via URL, e.g. `?overlay=falsecolor`
    // (used for reproducible screenshots / demos).
    final q = Uri.base.queryParameters['overlay'];
    if (q != null &&
        const <String>{'peaking', 'zebra', 'falsecolor', 'waveform'}
            .contains(q)) {
      _overlay = q;
    }
    _init();
    // `?capture=1` auto-captures a still after the stream warms up, so the
    // in-memory capture path can be demonstrated without a manual click.
    if (Uri.base.queryParameters['capture'] == '1') {
      Timer(const Duration(seconds: 3), _capture);
    }
  }

  Future<void> _init() async {
    try {
      final controller = await CameraPro.create();
      if (!mounted) return;
      setState(() => _controller = controller);
      await controller.startPreviewStream();
      _timer = Timer.periodic(const Duration(milliseconds: 40), (_) => _pump());
    } on Object catch (e) {
      setState(() => _error = '$e');
    }
  }

  void _pump() {
    final controller = _controller;
    if (controller == null || _decoding) return;
    final frame = controller.latestPreviewFrame();
    if (frame == null) return;

    if (_frames % 3 == 0) {
      _hist = NativeCore.histogramFromRgba(frame.bytes,
          width: frame.width, height: frame.height);
      if (_overlay == 'waveform') {
        _wf = NativeCore.waveformFromRgba(frame.bytes,
            width: frame.width, height: frame.height, columns: 128);
      }
    }

    var pixels = frame.bytes;
    switch (_overlay) {
      case 'peaking':
        pixels = NativeCore.focusPeaking(frame.bytes,
            width: frame.width,
            height: frame.height,
            isBgra: false,
            threshold: 0.1,
            peakColor: 0x00FFFFFF);
      case 'zebra':
        pixels = NativeCore.zebra(frame.bytes,
            width: frame.width,
            height: frame.height,
            isBgra: false,
            frameCounter: _frames);
      case 'falsecolor':
        pixels = NativeCore.falseColorFromRgba(frame.bytes,
            width: frame.width, height: frame.height, isBgra: false);
    }

    _decoding = true;
    ui.decodeImageFromPixels(
      pixels,
      frame.width,
      frame.height,
      ui.PixelFormat.rgba8888,
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

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      final photo = await controller.capturePhoto();
      final bytes = photo.bytes;
      if (bytes == null) return;
      final c = Completer<ui.Image>();
      ui.decodeImageFromPixels(
          bytes, photo.width, photo.height, ui.PixelFormat.rgba8888, c.complete);
      final img = await c.future;
      setState(() {
        _captured?.dispose();
        _captured = img;
      });
    } on Object catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _preview?.dispose();
    _captured?.dispose();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      appBar: AppBar(title: const Text('camera_pro · web')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: controller == null
              ? _loading()
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: <Widget>[
                    _previewArea(),
                    const SizedBox(height: 10),
                    _overlayChips(),
                    const SizedBox(height: 10),
                    _infoCard(controller),
                    const SizedBox(height: 10),
                    const Text('Capabilities',
                        style:
                            TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                    ..._capRows(controller.capabilities),
                  ],
                ),
        ),
      ),
      floatingActionButton: controller == null
          ? null
          : FloatingActionButton.extended(
              onPressed: _capture,
              icon: const Icon(Icons.camera),
              label: const Text('Capture'),
            ),
    );
  }

  Widget _loading() => Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const CircularProgressIndicator(),
          const SizedBox(height: 12),
          Text(_error ?? 'Requesting camera…'),
        ],
      );

  Widget _previewArea() {
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
          child: _preview == null
              ? const Center(
                  child: Text('Waiting for camera…',
                      style: TextStyle(color: Colors.white54)))
              : Stack(fit: StackFit.expand, children: <Widget>[
                  RawImage(image: _preview, fit: BoxFit.cover),
                  Positioned(
                    left: 8,
                    top: 8,
                    child: _badge('● LIVE · $_frames frames'),
                  ),
                  if (_hist != null)
                    Positioned(
                      right: 8,
                      top: 8,
                      child: Container(
                        width: 132,
                        height: 74,
                        color: Colors.black54,
                        child: CustomPaint(painter: _HistPainter(_hist!)),
                      ),
                    ),
                  if (_overlay == 'waveform' && _wf != null)
                    Positioned(
                      left: 8,
                      right: 8,
                      bottom: 8,
                      height: 70,
                      child: Container(
                        color: Colors.black54,
                        child: CustomPaint(painter: _WavePainter(_wf!)),
                      ),
                    ),
                  if (_captured != null)
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: Container(
                        width: 96,
                        height: 72,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.greenAccent, width: 2),
                        ),
                        child: RawImage(image: _captured, fit: BoxFit.cover),
                      ),
                    ),
                ]),
        ),
      ),
    );
  }

  Widget _badge(String t) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
            color: Colors.black54, borderRadius: BorderRadius.circular(6)),
        child: Text(t, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
      );

  Widget _overlayChips() {
    Widget chip(String id, String label, IconData icon) => ChoiceChip(
          label: Text(label),
          avatar: Icon(icon, size: 16),
          selected: _overlay == id,
          onSelected: (_) => setState(() {
            _overlay = _overlay == id ? 'none' : id;
            _wf = null;
          }),
        );
    return Wrap(spacing: 8, runSpacing: 4, children: <Widget>[
      chip('peaking', 'Focus peaking', Icons.filter_center_focus),
      chip('zebra', 'Zebra', Icons.gradient),
      chip('falsecolor', 'False color', Icons.palette),
      chip('waveform', 'Waveform', Icons.show_chart),
    ]);
  }

  Widget _infoCard(CameraProController c) {
    final caps = c.capabilities;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Device: ${caps.deviceName}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            Text('Platform: ${caps.platformName}'),
            Text('Kernels: ${CameraPro.simdKernel}  ·  core ${CameraPro.nativeCoreVersion}'),
            const SizedBox(height: 8),
            Chip(label: Text('Tier: ${c.tier.label}')),
          ],
        ),
      ),
    );
  }

  List<Widget> _capRows(CameraCapabilities caps) {
    Widget row<T>(String label, Capability<T> cap) {
      final ok = cap.isSupported;
      final detail = switch (cap) {
        Supported<T>(:final minValue, :final maxValue) => '$minValue … $maxValue',
        NotSupported<T>(:final reason) => reason,
      };
      return ListTile(
        dense: true,
        leading: Icon(ok ? Icons.check_circle : Icons.cancel,
            color: ok ? Colors.greenAccent : Colors.grey),
        title: Text(label),
        subtitle: Text(detail),
      );
    }

    return <Widget>[
      row('Manual ISO', caps.iso),
      row('Shutter speed', caps.shutterSpeed),
      row('White balance', caps.whiteBalanceKelvin),
      row('Zoom', caps.zoom),
    ];
  }
}

class _HistPainter extends CustomPainter {
  _HistPainter(this.h);
  final HistogramData h;
  @override
  void paint(Canvas canvas, Size size) {
    final peak = h.peak;
    if (peak == 0) return;
    final dx = size.width / 256.0;
    for (final (bins, color) in <(List<int>, Color)>[
      (h.red, Colors.red.withValues(alpha: 0.6)),
      (h.green, Colors.green.withValues(alpha: 0.6)),
      (h.blue, Colors.blue.withValues(alpha: 0.6)),
      (h.luminance, Colors.white.withValues(alpha: 0.85)),
    ]) {
      final paint = Paint()
        ..color = color
        ..strokeWidth = dx;
      for (var i = 0; i < 256; i++) {
        final hgt = (bins[i] / peak) * size.height;
        if (hgt <= 0) continue;
        final x = i * dx + dx / 2;
        canvas.drawLine(Offset(x, size.height), Offset(x, size.height - hgt), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_HistPainter oldDelegate) => true;
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.wf);
  final WaveformData wf;
  @override
  void paint(Canvas canvas, Size size) {
    var peak = 1;
    for (final v in wf.bins) {
      if (v > peak) peak = v;
    }
    final dx = size.width / wf.columns;
    final paint = Paint()..strokeWidth = 1;
    for (var c = 0; c < wf.columns; c++) {
      final x = c * dx + dx / 2;
      for (var l = 0; l < 256; l++) {
        final count = wf.at(c, l);
        if (count == 0) continue;
        paint.color = Colors.greenAccent
            .withValues(alpha: (count / peak).clamp(0.05, 1.0) * 0.9);
        canvas.drawRect(
            Rect.fromLTWH(x, size.height * (1 - l / 255.0), dx, 1), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_WavePainter oldDelegate) => true;
}
