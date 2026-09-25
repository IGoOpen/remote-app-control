import 'dart:typed_data';

/// Baseline JPEG encoder (4:2:0, standard Huffman tables).
///
/// Flutter can only encode PNG, which is several times larger for photos.
/// This runs in a background isolate on opaque images.
Uint8List encodeJpeg(Uint8List rgba, int width, int height, {int quality = 80}) =>
    _JpegEncoder(quality).encode(rgba, width, height);

/// Arguments bundle for `compute`.
class JpegJob {
  const JpegJob(this.rgba, this.width, this.height, this.quality);

  final Uint8List rgba;
  final int width;
  final int height;
  final int quality;
}

Uint8List encodeJpegJob(JpegJob job) => encodeJpeg(job.rgba, job.width, job.height, quality: job.quality);

const List<int> _zigzag = [
  0, 1, 5, 6, 14, 15, 27, 28, //
  2, 4, 7, 13, 16, 26, 29, 42,
  3, 8, 12, 17, 25, 30, 41, 43,
  9, 11, 18, 24, 31, 40, 44, 53,
  10, 19, 23, 32, 39, 45, 52, 54,
  20, 22, 33, 38, 46, 51, 55, 60,
  21, 34, 37, 47, 50, 56, 59, 61,
  35, 36, 48, 49, 57, 58, 62, 63,
];

const List<int> _lumaQuant = [
  16, 11, 10, 16, 24, 40, 51, 61, //
  12, 12, 14, 19, 26, 58, 60, 55,
  14, 13, 16, 24, 40, 57, 69, 56,
  14, 17, 22, 29, 51, 87, 80, 62,
  18, 22, 37, 56, 68, 109, 103, 77,
  24, 35, 55, 64, 81, 104, 113, 92,
  49, 64, 78, 87, 103, 121, 120, 101,
  72, 92, 95, 98, 112, 100, 103, 99,
];

const List<int> _chromaQuant = [
  17, 18, 24, 47, 99, 99, 99, 99, //
  18, 21, 26, 66, 99, 99, 99, 99,
  24, 26, 56, 99, 99, 99, 99, 99,
  47, 66, 99, 99, 99, 99, 99, 99,
  99, 99, 99, 99, 99, 99, 99, 99,
  99, 99, 99, 99, 99, 99, 99, 99,
  99, 99, 99, 99, 99, 99, 99, 99,
  99, 99, 99, 99, 99, 99, 99, 99,
];

// Standard Huffman tables (ITU T.81, Annex K). Counts are indexed 1..16.
const List<int> _dcLumaCounts = [0, 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0];
const List<int> _dcValues = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
const List<int> _acLumaCounts = [0, 0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d];
const List<int> _acLumaValues = [
  0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07, //
  0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
  0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
  0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
  0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
  0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
  0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
  0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
  0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
  0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
  0xf9, 0xfa,
];
const List<int> _dcChromaCounts = [0, 0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0];
const List<int> _acChromaCounts = [0, 0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77];
const List<int> _acChromaValues = [
  0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71, //
  0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0,
  0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
  0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
  0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
  0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
  0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5,
  0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
  0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
  0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
  0xf9, 0xfa,
];

const List<double> _aanScale = [1.0, 1.387039845, 1.306562965, 1.175875602, 1.0, 0.785694958, 0.541196100, 0.275899379];

/// Huffman code table: `codes[symbol]` and `lengths[symbol]`.
class _Huffman {
  _Huffman(List<int> counts, List<int> values) {
    assert(counts.skip(1).fold<int>(0, (a, b) => a + b) == values.length);
    var code = 0;
    var index = 0;
    for (var length = 1; length <= 16; length++) {
      for (var i = 0; i < counts[length]; i++) {
        codes[values[index]] = code;
        lengths[values[index]] = length;
        index++;
        code++;
      }
      code <<= 1;
    }
  }

  final Int32List codes = Int32List(256);
  final Int32List lengths = Int32List(256);
}

class _JpegEncoder {
  _JpegEncoder(int quality) {
    final q = quality.clamp(1, 100);
    final scale = q < 50 ? 5000 ~/ q : 200 - q * 2;
    for (var i = 0; i < 64; i++) {
      _lumaTable[_zigzag[i]] = ((_lumaQuant[i] * scale + 50) ~/ 100).clamp(1, 255);
      _chromaTable[_zigzag[i]] = ((_chromaQuant[i] * scale + 50) ~/ 100).clamp(1, 255);
    }
    var k = 0;
    for (var row = 0; row < 8; row++) {
      for (var col = 0; col < 8; col++) {
        final aan = _aanScale[row] * _aanScale[col] * 8.0;
        _lumaDivisors[k] = 1.0 / (_lumaTable[_zigzag[k]] * aan);
        _chromaDivisors[k] = 1.0 / (_chromaTable[_zigzag[k]] * aan);
        k++;
      }
    }
  }

  final Int32List _lumaTable = Int32List(64);
  final Int32List _chromaTable = Int32List(64);
  final Float64List _lumaDivisors = Float64List(64);
  final Float64List _chromaDivisors = Float64List(64);

  final _Huffman _dcLuma = _Huffman(_dcLumaCounts, _dcValues);
  final _Huffman _acLuma = _Huffman(_acLumaCounts, _acLumaValues);
  final _Huffman _dcChroma = _Huffman(_dcChromaCounts, _dcValues);
  final _Huffman _acChroma = _Huffman(_acChromaCounts, _acChromaValues);

  final BytesBuilder _out = BytesBuilder(copy: false);
  late Uint8List _chunk;
  int _chunkLength = 0;
  int _bitBuffer = 0;
  int _bitCount = 0;

  final Int32List _quantized = Int32List(64);
  final Int32List _block = Int32List(64);

  Uint8List encode(Uint8List rgba, int width, int height) {
    _chunk = Uint8List(64 * 1024);
    _writeHeaders(width, height);

    final y = List.generate(4, (_) => Float64List(64));
    final cb = Float64List(64);
    final cr = Float64List(64);
    var dcY = 0, dcCb = 0, dcCr = 0;

    for (var mcuY = 0; mcuY < height; mcuY += 16) {
      for (var mcuX = 0; mcuX < width; mcuX += 16) {
        cb.fillRange(0, 64, 0);
        cr.fillRange(0, 64, 0);
        for (var row = 0; row < 16; row++) {
          final py = mcuY + row < height ? mcuY + row : height - 1;
          for (var col = 0; col < 16; col++) {
            final px = mcuX + col < width ? mcuX + col : width - 1;
            final p = (py * width + px) * 4;
            final r = rgba[p].toDouble(), g = rgba[p + 1].toDouble(), b = rgba[p + 2].toDouble();
            final block = (row >> 3) * 2 + (col >> 3);
            y[block][(row & 7) * 8 + (col & 7)] = 0.299 * r + 0.587 * g + 0.114 * b - 128;
            // 4:2:0 subsampling: each chroma sample averages a 2x2 square.
            final c = (row >> 1) * 8 + (col >> 1);
            cb[c] += (-0.16874 * r - 0.33126 * g + 0.5 * b) * 0.25;
            cr[c] += (0.5 * r - 0.41869 * g - 0.08131 * b) * 0.25;
          }
        }
        for (final block in y) {
          dcY = _encodeBlock(block, _lumaDivisors, dcY, _dcLuma, _acLuma);
        }
        dcCb = _encodeBlock(cb, _chromaDivisors, dcCb, _dcChroma, _acChroma);
        dcCr = _encodeBlock(cr, _chromaDivisors, dcCr, _dcChroma, _acChroma);
      }
    }

    // Pad the final byte with 1 bits, as the spec requires.
    if (_bitCount > 0) _writeBits((1 << (8 - _bitCount)) - 1, 8 - _bitCount);
    _flushChunk();
    _out.add(const [0xFF, 0xD9]);
    return _out.takeBytes();
  }

  int _encodeBlock(Float64List data, Float64List divisors, int previousDc, _Huffman dc, _Huffman ac) {
    _forwardDct(data);
    for (var i = 0; i < 64; i++) {
      final v = data[i] * divisors[i];
      _quantized[i] = v > 0 ? (v + 0.5).toInt() : (v - 0.5).toInt();
    }
    for (var i = 0; i < 64; i++) {
      _block[_zigzag[i]] = _quantized[i];
    }

    final diff = _block[0] - previousDc;
    if (diff == 0) {
      _writeBits(dc.codes[0], dc.lengths[0]);
    } else {
      final category = _category(diff);
      _writeBits(dc.codes[category], dc.lengths[category]);
      _writeBits(_bits(diff, category), category);
    }

    var last = 63;
    while (last > 0 && _block[last] == 0) {
      last--;
    }
    var i = 1;
    while (i <= last) {
      final start = i;
      while (_block[i] == 0 && i <= last) {
        i++;
      }
      var zeros = i - start;
      while (zeros >= 16) {
        _writeBits(ac.codes[0xF0], ac.lengths[0xF0]);
        zeros -= 16;
      }
      final value = _block[i];
      final category = _category(value);
      final symbol = (zeros << 4) + category;
      _writeBits(ac.codes[symbol], ac.lengths[symbol]);
      _writeBits(_bits(value, category), category);
      i++;
    }
    if (last != 63) _writeBits(ac.codes[0], ac.lengths[0]);
    return _block[0];
  }

  static int _category(int value) {
    var v = value < 0 ? -value : value;
    var bits = 0;
    while (v > 0) {
      bits++;
      v >>= 1;
    }
    return bits;
  }

  static int _bits(int value, int category) => value >= 0 ? value : value + (1 << category) - 1;

  /// In-place AAN forward DCT; the scaling is folded into the divisors.
  static void _forwardDct(Float64List d) {
    for (var pass = 0; pass < 2; pass++) {
      final step = pass == 0 ? 1 : 8;
      final stride = pass == 0 ? 8 : 1;
      for (var n = 0; n < 8; n++) {
        final o = n * stride;
        final d0 = d[o], d1 = d[o + step], d2 = d[o + 2 * step], d3 = d[o + 3 * step];
        final d4 = d[o + 4 * step], d5 = d[o + 5 * step], d6 = d[o + 6 * step], d7 = d[o + 7 * step];
        final t0 = d0 + d7, t7 = d0 - d7, t1 = d1 + d6, t6 = d1 - d6;
        final t2 = d2 + d5, t5 = d2 - d5, t3 = d3 + d4, t4 = d3 - d4;

        var t10 = t0 + t3;
        final t13 = t0 - t3;
        var t11 = t1 + t2;
        var t12 = t1 - t2;
        d[o] = t10 + t11;
        d[o + 4 * step] = t10 - t11;
        final z1 = (t12 + t13) * 0.707106781;
        d[o + 2 * step] = t13 + z1;
        d[o + 6 * step] = t13 - z1;

        t10 = t4 + t5;
        t11 = t5 + t6;
        t12 = t6 + t7;
        final z5 = (t10 - t12) * 0.382683433;
        final z2 = 0.541196100 * t10 + z5;
        final z4 = 1.306562965 * t12 + z5;
        final z3 = t11 * 0.707106781;
        final z11 = t7 + z3;
        final z13 = t7 - z3;
        d[o + 5 * step] = z13 + z2;
        d[o + 3 * step] = z13 - z2;
        d[o + step] = z11 + z4;
        d[o + 7 * step] = z11 - z4;
      }
    }
  }

  void _writeBits(int code, int length) {
    _bitBuffer = (_bitBuffer << length) | (code & ((1 << length) - 1));
    _bitCount += length;
    while (_bitCount >= 8) {
      final byte = (_bitBuffer >> (_bitCount - 8)) & 0xFF;
      _byte(byte);
      if (byte == 0xFF) _byte(0); // Byte stuffing.
      _bitCount -= 8;
    }
    _bitBuffer &= (1 << _bitCount) - 1;
  }

  void _byte(int b) {
    if (_chunkLength == _chunk.length) _flushChunk();
    _chunk[_chunkLength++] = b;
  }

  void _flushChunk() {
    if (_chunkLength == 0) return;
    _out.add(Uint8List.fromList(Uint8List.sublistView(_chunk, 0, _chunkLength)));
    _chunkLength = 0;
  }

  void _u16(int v) {
    _byte(v >> 8);
    _byte(v & 0xFF);
  }

  void _writeHeaders(int width, int height) {
    // SOI and JFIF APP0.
    for (final b in [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 1, 1, 0]) {
      _byte(b);
    }
    _u16(1);
    _u16(1);
    _byte(0);
    _byte(0);

    // Quantization tables, already in zigzag order.
    _u16(0xFFDB);
    _u16(132);
    _byte(0);
    _lumaTable.forEach(_byte);
    _byte(1);
    _chromaTable.forEach(_byte);

    // Baseline frame: Y sampled 2x2, Cb and Cr 1x1.
    _u16(0xFFC0);
    _u16(17);
    _byte(8);
    _u16(height);
    _u16(width);
    _byte(3);
    for (final (id, sampling, table) in [(1, 0x22, 0), (2, 0x11, 1), (3, 0x11, 1)]) {
      _byte(id);
      _byte(sampling);
      _byte(table);
    }

    _u16(0xFFC4);
    _u16(418);
    for (final (klass, counts, values) in [
      (0x00, _dcLumaCounts, _dcValues),
      (0x10, _acLumaCounts, _acLumaValues),
      (0x01, _dcChromaCounts, _dcValues),
      (0x11, _acChromaCounts, _acChromaValues),
    ]) {
      _byte(klass);
      for (var i = 1; i <= 16; i++) {
        _byte(counts[i]);
      }
      values.forEach(_byte);
    }

    _u16(0xFFDA);
    _u16(12);
    _byte(3);
    for (final (id, tables) in [(1, 0x00), (2, 0x11), (3, 0x11)]) {
      _byte(id);
      _byte(tables);
    }
    for (final b in [0x00, 0x3F, 0x00]) {
      _byte(b);
    }
  }
}
