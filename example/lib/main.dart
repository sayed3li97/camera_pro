// camera_pro example.
//
// Demonstrates the "Capability Passport" and the crash-proof API. It runs on
// any platform: it uses the stub backend, so there is no live camera, but it
// shows the real flow — query capabilities, pick a control tier, and attempt a
// control/capture that surfaces a *typed* error instead of crashing.
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

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // Reading the native core exercises the FFI path. Guard it so the demo
    // still renders if native assets weren't built for this host.
    try {
      _nativeVersion = CameraPro.nativeCoreVersion;
      _simd = CameraPro.simdKernel;
    } on Object catch (e) {
      _nativeVersion = 'native core unavailable ($e)';
    }

    final controller = await CameraPro.create();
    if (!mounted) return;
    setState(() => _controller = controller);
  }

  Future<void> _attemptCapture() async {
    final controller = _controller;
    if (controller == null) return;
    setState(() => _error = null);
    try {
      final photo = await controller.capturePhoto(format: ImageFormat.jpeg);
      _showSnack('Captured ${photo.width}x${photo.height} → ${photo.path}');
    } on CameraProError catch (e) {
      // The whole point: an unsupported feature is a typed, recoverable error.
      setState(() => _error = '${e.runtimeType}: ${e.message}');
      _showSnack('Recovery: ${e.recovery.name}');
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
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
          : FloatingActionButton.extended(
              onPressed: _attemptCapture,
              icon: const Icon(Icons.camera),
              label: const Text('Capture'),
            ),
      body: controller == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                _InfoCard(
                  nativeVersion: _nativeVersion,
                  simd: _simd,
                  tier: controller.tier,
                  caps: controller.capabilities,
                ),
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
