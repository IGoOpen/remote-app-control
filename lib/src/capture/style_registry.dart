import 'dart:convert';
import 'dart:typed_data';

import '../protocol/byte_buffer.dart';
import '../protocol/wire_text_style.dart';

/// Interns text styles so each one crosses the wire once per session.
class StyleRegistry {
  final Map<String, int> _ids = {};
  final List<(int, Uint8List)> _pending = [];
  final Set<String> _families = {};
  final List<String> _newFamilies = [];

  /// Changes whenever ids are invalidated, so caches keyed on style ids know
  /// to rebuild.
  int generation = 0;

  int idFor(WireTextStyle style) {
    final writer = ByteWriter(64);
    style.write(writer);
    final encoded = writer.takeBytes();
    // Latin-1 keeps the bytes intact as a map key.
    final key = latin1.decode(encoded);
    final existing = _ids[key];
    if (existing != null) return existing;
    final id = _ids.length + 1;
    _ids[key] = id;
    _pending.add((id, encoded));
    for (final family in [style.family, ...style.fallback]) {
      if (family.isNotEmpty && _families.add(family)) _newFamilies.add(family);
    }
    return id;
  }

  /// Encoded `styles` message payload for styles defined since the last
  /// call, or null if there are none.
  Uint8List? takePending(int messageType) {
    if (_pending.isEmpty) return null;
    final w = ByteWriter()
      ..u8(messageType)
      ..varUint(_pending.length);
    for (final (id, bytes) in _pending) {
      w
        ..varUint(id)
        ..bytes(bytes);
    }
    _pending.clear();
    return w.takeBytes();
  }

  /// Font families referenced for the first time since the last call.
  List<String> takeNewFamilies() {
    if (_newFamilies.isEmpty) return const [];
    final out = List.of(_newFamilies);
    _newFamilies.clear();
    return out;
  }

  void reset() {
    _ids.clear();
    _pending.clear();
    _families.clear();
    _newFamilies.clear();
    generation++;
  }
}
