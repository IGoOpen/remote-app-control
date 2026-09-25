import 'dart:convert';
import 'dart:typed_data';

/// Growable little-endian binary writer used for every wire message.
class ByteWriter {
  ByteWriter([int initialCapacity = 4096]) : _buffer = Uint8List(initialCapacity) {
    _data = ByteData.sublistView(_buffer);
  }

  Uint8List _buffer;
  late ByteData _data;
  int _length = 0;

  int get length => _length;

  void _ensure(int extra) {
    final required = _length + extra;
    if (required <= _buffer.length) return;
    var capacity = _buffer.length * 2;
    while (capacity < required) {
      capacity *= 2;
    }
    final next = Uint8List(capacity)..setRange(0, _length, _buffer);
    _buffer = next;
    _data = ByteData.sublistView(_buffer);
  }

  void u8(int value) {
    _ensure(1);
    _buffer[_length++] = value;
  }

  void boolean(bool value) => u8(value ? 1 : 0);

  void u16(int value) {
    _ensure(2);
    _data.setUint16(_length, value, Endian.little);
    _length += 2;
  }

  void u32(int value) {
    _ensure(4);
    _data.setUint32(_length, value, Endian.little);
    _length += 4;
  }

  void f32(double value) {
    _ensure(4);
    _data.setFloat32(_length, value, Endian.little);
    _length += 4;
  }

  /// Unsigned LEB128, used for counts and ids.
  void varUint(int value) {
    assert(value >= 0);
    while (value >= 0x80) {
      u8((value & 0x7f) | 0x80);
      value >>= 7;
    }
    u8(value);
  }

  void bytes(List<int> value) {
    _ensure(value.length);
    _buffer.setRange(_length, _length + value.length, value);
    _length += value.length;
  }

  void string(String value) {
    final encoded = utf8.encode(value);
    varUint(encoded.length);
    bytes(encoded);
  }

  void float32List(Float32List values) {
    varUint(values.length);
    for (final v in values) {
      f32(v);
    }
  }

  Uint8List takeBytes() => Uint8List.sublistView(_buffer, 0, _length);
}

class ByteReader {
  ByteReader(Uint8List bytes, [int offset = 0]) : _bytes = bytes, _data = ByteData.sublistView(bytes), _offset = offset;

  final Uint8List _bytes;
  final ByteData _data;
  int _offset;

  bool get hasMore => _offset < _bytes.length;
  int get offset => _offset;

  int u8() => _bytes[_offset++];

  bool boolean() => u8() != 0;

  int u16() {
    final v = _data.getUint16(_offset, Endian.little);
    _offset += 2;
    return v;
  }

  int u32() {
    final v = _data.getUint32(_offset, Endian.little);
    _offset += 4;
    return v;
  }

  double f32() {
    final v = _data.getFloat32(_offset, Endian.little);
    _offset += 4;
    return v;
  }

  int varUint() {
    var result = 0;
    var shift = 0;
    while (true) {
      final b = u8();
      result |= (b & 0x7f) << shift;
      if (b < 0x80) return result;
      shift += 7;
    }
  }

  Uint8List bytes(int length) {
    final v = Uint8List.sublistView(_bytes, _offset, _offset + length);
    _offset += length;
    return v;
  }

  Uint8List rest() => bytes(_bytes.length - _offset);

  String string() => utf8.decode(bytes(varUint()));

  Float32List float32List() {
    final n = varUint();
    final out = Float32List(n);
    for (var i = 0; i < n; i++) {
      out[i] = f32();
    }
    return out;
  }
}
