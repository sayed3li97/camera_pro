import 'dart:typed_data';

import 'package:camera_pro/camera_pro.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';

/// A backend that serves synthetic frames, for exercising the processor path.
class FrameServingBackend extends RecordingBackend {
  int served = 0;

  @override
  PreviewFrame? latestFrame() {
    served++;
    return PreviewFrame(
      bytes: Uint8List(16 * 16 * 4),
      width: 16,
      height: 16,
    );
  }
}

class CountingProcessor extends FrameProcessor {
  int attached = 0;
  int frames = 0;
  int detached = 0;
  CameraCapabilities? caps;

  @override
  void onAttach(CameraCapabilities capabilities) {
    attached++;
    caps = capabilities;
  }

  @override
  void onFrame(PreviewFrame frame) {
    frames++;
    expect(frame.width, 16);
  }

  @override
  void onDetach() => detached++;
}

void main() {
  test('frame processors receive every polled frame', () {
    final controller = CameraProController.forTesting(
      capabilities: fullCapabilities(),
      backend: FrameServingBackend(),
    );
    final p = CountingProcessor();
    controller.addFrameProcessor(p);
    expect(p.attached, 1);
    expect(p.caps?.deviceName, 'iPhone 16 Pro');

    controller.latestPreviewFrame();
    controller.latestPreviewFrame();
    controller.latestPreviewFrame();
    expect(p.frames, 3);

    controller.removeFrameProcessor(p);
    expect(p.detached, 1);
    controller.latestPreviewFrame();
    expect(p.frames, 3, reason: 'no frames after detach');
  });

  test('startStreaming surfaces a typed not-implemented error', () {
    final controller = CameraProController.forTesting(
      capabilities: fullCapabilities(),
    );
    expect(
      () => controller.startStreaming(const StreamConfig(
        url: 'rtmp://example.com/live/key',
        protocol: StreamProtocol.rtmp,
      )),
      throwsA(isA<CameraFeatureNotSupportedError>()),
    );
  });
}
