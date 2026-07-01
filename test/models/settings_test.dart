import 'package:camera_pro/camera_pro.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ShutterSpeed', () {
    test('fromFraction produces the right duration and label', () {
      final s = ShutterSpeed.fromFraction(1, 500);
      expect(s.duration.inMicroseconds, 2000);
      expect(s.label, '1/500');
      expect(s.nanoseconds, 2000000);
    });

    test('seconds factory labels long exposures', () {
      expect(ShutterSpeed.seconds(2).label, '2s');
      expect(ShutterSpeed.seconds(0.5).label, '1/2');
    });
  });

  group('Iso / Ev', () {
    test('Iso equality and label', () {
      expect(const Iso(200), const Iso(200));
      expect(const Iso(200).toString(), 'ISO 200');
    });

    test('Ev signs its label', () {
      expect(const Ev(-0.7).toString(), '-0.7 EV');
      expect(const Ev(1.0).toString(), '+1.0 EV');
    });
  });

  group('WhiteBalance', () {
    test('manual temperature carries kelvin', () {
      const wb = WhiteBalance.temperature(5600);
      expect(wb.mode, WhiteBalanceMode.manual);
      expect(wb.kelvin, 5600);
      expect(wb.toString(), '5600K');
    });

    test('preset has no kelvin', () {
      const wb = WhiteBalance.preset(WhiteBalanceMode.daylight);
      expect(wb.kelvin, isNull);
      expect(wb.toString(), 'daylight');
    });
  });

  group('Bitrate / VideoResolution', () {
    test('bitrate helpers', () {
      expect(Bitrate.mbps(50).bitsPerSecond, 50000000);
      expect(Bitrate.kbps(128).bitsPerSecond, 128000);
    });

    test('resolution constants', () {
      expect(VideoResolution.uhd4k.width, 3840);
      expect(VideoResolution.fhd1080p.toString(), '1920x1080');
    });
  });
}
