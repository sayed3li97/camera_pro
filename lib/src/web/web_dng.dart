/// Pure-Dart linear-DNG encoder for the web RAW-capture path.
///
/// A direct port of `src/core/dng_writer.c` (no libtiff/libexif): an
/// uncompressed 8-bit LinearRaw RGB DNG (TIFF container, DNG 1.4 tags) with an
/// EXIF IFD (ExposureTime, ISO, DateTimeOriginal) and a ColorMatrix1. Returns
/// the encoded bytes (web can't write files; callers hand these to a download
/// or hold them in memory). The byte layout matches the C writer exactly.
library;

import 'dart:convert';
import 'dart:typed_data';

// TIFF type codes.
const int _tByte = 1;
const int _tAscii = 2;
const int _tShort = 3;
const int _tLong = 4;
const int _tRational = 5;
const int _tSrational = 10;

class _Entry {
  _Entry(this.tag, this.type, this.count, this.value);
  final int tag;
  final int type;
  final int count;
  int value;
}

int _asciiExternLen(String s) {
  final n = s.length + 1;
  return n <= 4 ? 0 : n;
}

/// Encodes [rgba] as a linear-DNG and returns the file bytes.
Uint8List encodeLinearDng({
  required Uint8List rgba,
  required int width,
  required int height,
  int stride = 0,
  bool isBgra = false,
  int iso = 100,
  int exposureNs = 0,
  String make = 'camera_pro',
  String model = 'camera_pro',
  String datetime = '2026:01:01 00:00:00',
}) {
  if (stride <= 0) stride = width * 4;
  const software = 'camera_pro 0.0.1';
  final pixelBytes = width * height * 3;

  // ── Layout (identical to the C writer) ────────────────────────────────────
  const hdr = 8;
  const ifd0Entries = 20;
  const ifd0Off = hdr;
  const ifd0Sz = 2 + ifd0Entries * 12 + 4;
  var voff = ifd0Off + ifd0Sz;

  const bpsLen = 6;
  final bpsOff = voff;
  voff += bpsLen;
  final makeLen = _asciiExternLen(make);
  final makeOff = voff;
  voff += makeLen;
  final modelLen = _asciiExternLen(model);
  final modelOff = voff;
  voff += modelLen;
  final swLen = _asciiExternLen(software);
  final swOff = voff;
  voff += swLen;
  final dtLen = _asciiExternLen(datetime);
  final dtOff = voff;
  voff += dtLen;
  final ucmLen = _asciiExternLen(model);
  final ucmOff = voff;
  voff += ucmLen;
  final cmOff = voff;
  voff += 9 * 8;

  const exifEntries = 3;
  final exifOff = voff;
  const exifSz = 2 + exifEntries * 12 + 4;
  voff = exifOff + exifSz;
  final exptimeOff = voff;
  voff += 8;
  final dtoLen = _asciiExternLen(datetime);
  final dtoOff = voff;
  voff += dtoLen;

  final pixelsOff = voff;
  final total = pixelsOff + pixelBytes;

  // Pack a short (<=4 byte) ASCII value into the inline value field.
  int packInline(String s, int count) {
    final b = latin1.encode(s);
    var v = 0;
    for (var i = 0; i < count; i++) {
      final byte = i < b.length ? b[i] : 0; // trailing NUL
      v |= byte << (8 * i);
    }
    return v & 0xFFFFFFFF;
  }

  int asciiValue(String s, int externLen, int externOff) =>
      externLen != 0 ? externOff : packInline(s, s.length + 1);

  // ── IFD0 (ascending tag order) ────────────────────────────────────────────
  final ifd0 = <_Entry>[
    _Entry(254, _tLong, 1, 0), // NewSubfileType
    _Entry(256, _tLong, 1, width), // ImageWidth
    _Entry(257, _tLong, 1, height), // ImageLength
    _Entry(258, _tShort, 3, bpsOff), // BitsPerSample
    _Entry(259, _tShort, 1, 1), // Compression = none
    _Entry(262, _tShort, 1, 34892), // Photometric = LinearRaw
    _Entry(271, _tAscii, make.length + 1, asciiValue(make, makeLen, makeOff)),
    _Entry(272, _tAscii, model.length + 1, asciiValue(model, modelLen, modelOff)),
    _Entry(273, _tLong, 1, pixelsOff), // StripOffsets
    _Entry(274, _tShort, 1, 1), // Orientation
    _Entry(277, _tShort, 1, 3), // SamplesPerPixel
    _Entry(278, _tLong, 1, height), // RowsPerStrip
    _Entry(279, _tLong, 1, pixelBytes), // StripByteCounts
    _Entry(305, _tAscii, software.length + 1, asciiValue(software, swLen, swOff)),
    _Entry(306, _tAscii, datetime.length + 1, asciiValue(datetime, dtLen, dtOff)),
    _Entry(34665, _tLong, 1, exifOff), // ExifIFD pointer
    _Entry(50706, _tByte, 4, 0x00000401), // DNGVersion 1.4.0.0 (LE bytes 01 04 00 00)
    _Entry(50708, _tAscii, model.length + 1, asciiValue(model, ucmLen, ucmOff)),
    _Entry(50721, _tSrational, 9, cmOff), // ColorMatrix1
    _Entry(50778, _tShort, 1, 21), // CalibrationIlluminant1 = D65
  ];

  final exif = <_Entry>[
    _Entry(33434, _tRational, 1, exptimeOff), // ExposureTime
    _Entry(34855, _tShort, 1, iso < 0 ? 0 : (iso > 65535 ? 65535 : iso)), // ISO
    _Entry(36867, _tAscii, datetime.length + 1, asciiValue(datetime, dtoLen, dtoOff)),
  ];

  // ── Emit ──────────────────────────────────────────────────────────────────
  final out = Uint8List(total);
  final bd = ByteData.sublistView(out);
  var pos = 0;
  void u16(int v) {
    bd.setUint16(pos, v, Endian.little);
    pos += 2;
  }

  void u32(int v) {
    bd.setUint32(pos, v & 0xFFFFFFFF, Endian.little);
    pos += 4;
  }

  void i32(int v) {
    bd.setInt32(pos, v, Endian.little);
    pos += 4;
  }

  void ascii(String s) {
    final b = latin1.encode(s);
    out.setRange(pos, pos + b.length, b);
    pos += b.length;
    out[pos++] = 0; // NUL terminator
  }

  void writeIfd(List<_Entry> ifd) {
    u16(ifd.length);
    for (final e in ifd) {
      u16(e.tag);
      u16(e.type);
      u32(e.count);
      u32(e.value);
    }
    u32(0); // next IFD offset
  }

  // Header.
  out[0] = 0x49; // 'I'
  out[1] = 0x49; // 'I'
  pos = 2;
  u16(42);
  u32(ifd0Off);

  writeIfd(ifd0);

  // IFD0 external values.
  u16(8);
  u16(8);
  u16(8); // BitsPerSample
  if (makeLen != 0) ascii(make);
  if (modelLen != 0) ascii(model);
  ascii(software);
  ascii(datetime);
  if (ucmLen != 0) ascii(model);

  // ColorMatrix1: XYZ(D65) -> linear sRGB, x10000 rationals.
  const cm = <int>[
    32405, -15371, -4985, //
    -9693, 18760, 416, //
    556, -2040, 10572,
  ];
  for (final n in cm) {
    i32(n);
    u32(10000);
  }

  writeIfd(exif);

  // EXIF values.
  u32(exposureNs < 0 ? 0 : exposureNs ~/ 1000);
  u32(1000000); // ExposureTime = microsec / 1e6
  ascii(datetime);

  // Pixels: RGB, dropping alpha, honoring channel order.
  final ri = isBgra ? 2 : 0;
  final bi = isBgra ? 0 : 2;
  for (var y = 0; y < height; y++) {
    final src = y * stride;
    for (var x = 0; x < width; x++) {
      final sp = src + x * 4;
      out[pos++] = rgba[sp + ri];
      out[pos++] = rgba[sp + 1];
      out[pos++] = rgba[sp + bi];
    }
  }

  assert(pos == total, 'DNG layout mismatch: wrote $pos, expected $total');
  return out;
}
