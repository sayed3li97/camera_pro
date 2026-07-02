/// Live-streaming configuration and status models.
///
/// The API surface is modelled and type-safe; the native RTMP/SRT client is
/// not yet implemented (an RTMP handshake/chunking/AMF stack, or an SRT
/// transport, plus a hardware encoder tap). `startStreaming` therefore throws
/// a typed [CameraFeatureNotSupportedError] today — see ROADMAP.md.
library;

import 'package:meta/meta.dart';

import 'settings.dart';

/// Configuration for a live stream session.
@immutable
class StreamConfig {
  const StreamConfig({
    required this.url,
    required this.protocol,
    this.videoCodec = VideoCodec.h264,
    this.videoBitrate = const Bitrate(4000000),
    this.audioBitrate = const Bitrate(128000),
    this.resolution = VideoResolution.fhd1080p,
    this.frameRate = 30,
    this.keyframeInterval = const Duration(seconds: 2),
    this.adaptiveBitrate = true,
  });

  final String url;
  final StreamProtocol protocol;
  final VideoCodec videoCodec;
  final Bitrate videoBitrate;
  final Bitrate audioBitrate;
  final VideoResolution resolution;
  final int frameRate;
  final Duration keyframeInterval;
  final bool adaptiveBitrate;
}

/// Connection health of an active stream.
enum StreamHealth { good, fair, poor, critical }

/// Lifecycle state of a stream session.
enum StreamState { connecting, streaming, reconnecting, stopped, error }

/// A snapshot of stream session status.
@immutable
class StreamStatus {
  const StreamStatus({
    required this.state,
    this.bitrate,
    this.droppedFrames = 0,
    this.health = StreamHealth.good,
    this.uptime = Duration.zero,
  });

  final StreamState state;
  final Bitrate? bitrate;
  final int droppedFrames;
  final StreamHealth health;
  final Duration uptime;
}
