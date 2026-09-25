import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../protocol/byte_buffer.dart';
import '../protocol/wire.dart';

/// Offers the app's bundled fonts (custom fonts, icon fonts) to viewers.
///
/// Fonts are identified by the SHA-256 of their file. Viewers cache them by
/// hash across sessions and only request the files they do not have, so a
/// font crosses the network once per viewer, not once per session.
///
/// System fonts are not bundled and are left to the viewer's fallbacks.
class FontRegistry {
  FontRegistry({AssetBundle? bundle}) : _bundle = bundle ?? rootBundle;

  final AssetBundle _bundle;
  Future<Map<String, List<_FontAsset>>>? _manifest;

  // Hashes are computed once per app run; viewers come and go.
  static final Map<String, Future<_HashedFont?>> _hashes = {};

  final Set<String> _offered = {};
  final Map<String, _HashedFont> _byHash = {};

  void reset() => _offered.clear();

  /// Yields a `fontOffer` message for each file of each family not yet
  /// offered: `string family`, `string familyKey`, `u16 weight` (0 if
  /// unspecified), `u8 italic`, `32 bytes sha256`, `varuint size`.
  ///
  /// `familyKey` identifies the family's exact set of files, so viewers can
  /// register it under a name that never clashes with another app's fonts.
  Stream<Uint8List> offersFor(List<String> families) async* {
    final manifest = await (_manifest ??= _loadManifest());
    for (final family in families) {
      if (!_offered.add(family)) continue;
      final assets = manifest[family];
      if (assets == null) continue;
      final hashed = [for (final font in await Future.wait(assets.map(_hash))) ?font];
      if (hashed.isEmpty) continue;
      final familyKey = sha256.convert([for (final font in hashed) ...font.hash]).toString().substring(0, 16);
      for (final font in hashed) {
        _byHash[hex(font.hash)] = font;
        yield (ByteWriter(96)
              ..u8(MessageType.fontOffer)
              ..string(family)
              ..string(familyKey)
              ..u16(font.asset.weight)
              ..boolean(font.asset.italic)
              ..bytes(font.hash)
              ..varUint(font.size))
            .takeBytes();
      }
    }
  }

  /// A `font` message (`32 bytes sha256`, file bytes) answering a viewer's
  /// request, or null if the hash was never offered.
  Future<Uint8List?> fontFor(List<int> hash) async {
    final font = _byHash[hex(hash)];
    if (font == null) return null;
    final data = await _bundle.load(font.asset.asset);
    return (ByteWriter(data.lengthInBytes + 40)
          ..u8(MessageType.font)
          ..bytes(font.hash)
          ..bytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes)))
        .takeBytes();
  }

  Future<_HashedFont?> _hash(_FontAsset asset) => _hashes['${identityHashCode(_bundle)}:${asset.asset}'] ??= () async {
    try {
      final data = await _bundle.load(asset.asset);
      final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      // Icon fonts can be over a megabyte; keep hashing off the UI thread.
      final digest = await compute(_sha256, bytes);
      return _HashedFont(asset, digest, bytes.length);
    } catch (error) {
      debugPrint('remote_app_control: could not load font ${asset.asset}: $error');
      return null;
    }
  }();

  Future<Map<String, List<_FontAsset>>> _loadManifest() async {
    try {
      final json = jsonDecode(await _bundle.loadString('FontManifest.json')) as List<Object?>;
      return {
        for (final entry in json.cast<Map<String, Object?>>())
          entry['family'] as String: [
            for (final font in (entry['fonts'] as List<Object?>).cast<Map<String, Object?>>())
              _FontAsset(font['asset'] as String, (font['weight'] as num?)?.toInt() ?? 0, font['style'] == 'italic'),
          ],
      };
    } catch (_) {
      return const {};
    }
  }

  static String hex(List<int> bytes) => [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();
}

Uint8List _sha256(Uint8List bytes) => Uint8List.fromList(sha256.convert(bytes).bytes);

class _FontAsset {
  const _FontAsset(this.asset, this.weight, this.italic);

  final String asset;
  final int weight;
  final bool italic;
}

class _HashedFont {
  const _HashedFont(this.asset, this.hash, this.size);

  final _FontAsset asset;
  final Uint8List hash;
  final int size;
}
