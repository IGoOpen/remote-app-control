import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'package:crypto/crypto.dart';

import '../protocol/byte_buffer.dart';
import '../protocol/wire_text_style.dart';

/// An uploaded image. It may have been downscaled by the host, so source
/// rectangles from frames are mapped by [scaleX]/[scaleY].
class RemoteImage {
  RemoteImage(this.image, this.originalWidth, this.originalHeight);

  final ui.Image image;
  final int originalWidth;
  final int originalHeight;

  double get scaleX => image.width / originalWidth;
  double get scaleY => image.height / originalHeight;

  Rect mapSource(Rect src) =>
      Rect.fromLTRB(src.left * scaleX, src.top * scaleY, src.right * scaleX, src.bottom * scaleY);
}

/// Stores font files by their SHA-256 (lowercase hex) across sessions.
///
/// The default keeps fonts in memory for the lifetime of the process.
/// Implement this with a file or key-value store to persist them.
abstract class RemoteFontCache {
  Future<Uint8List?> get(String hash);
  Future<void> put(String hash, Uint8List bytes);
}

class MemoryFontCache implements RemoteFontCache {
  final Map<String, Uint8List> _fonts = {};

  @override
  Future<Uint8List?> get(String hash) async => _fonts[hash];

  @override
  Future<void> put(String hash, Uint8List bytes) async => _fonts[hash] = bytes;
}

/// Everything a session has sent besides frames: images, text styles and
/// fonts, plus a cache of laid-out text runs.
class RemoteResources {
  RemoteResources({RemoteFontCache? fontCache}) : fontCache = fontCache ?? _sharedFontCache;

  static const int _paragraphCacheSize = 4000;

  final Map<int, RemoteImage> images = {};

  /// Recorded repaint boundaries by id; frames are trees of these.
  final Map<int, Uint8List> chunks = {};
  final Map<int, WireTextStyle> styles = {};
  final Map<int, TextStyle> _flutterStyles = {};
  final LinkedHashMap<String, ui.Paragraph> _paragraphs = LinkedHashMap();

  /// Where fonts are cached between sessions. Shared in memory by default.
  final RemoteFontCache fontCache;

  static final RemoteFontCache _sharedFontCache = MemoryFontCache();

  // Font files registered with the engine. Registration is process-wide, so
  // this outlives sessions.
  static final Set<String> _registeredFiles = {};
  static final Set<String> _registeredFamilies = {};

  // Per session: family name -> family key, and offered files by hash.
  final Map<String, String> _familyKeys = {};
  final Map<String, String> _offeredFiles = {};

  /// Fonts from the host are registered under a name derived from the
  /// family's content, so they never clash with the viewer's own fonts or
  /// with another app's font of the same name.
  static String remoteFamily(String familyKey) => 'remote-$familyKey';

  void addStyles(ByteReader r) {
    final count = r.varUint();
    for (var i = 0; i < count; i++) {
      final id = r.varUint();
      styles[id] = WireTextStyle.read(r);
      _flutterStyles.remove(id);
    }
  }

  /// Handles a `fontOffer`. Returns the hash to request from the host when
  /// the file is not cached, or null when it is already available.
  Future<Uint8List?> addFontOffer(ByteReader r) async {
    final family = r.string();
    final familyKey = r.string();
    r
      ..u16() // Weight and style are read from the font file itself.
      ..u8();
    final hash = Uint8List.fromList(r.bytes(32));
    final hex = _hex(hash);
    _familyKeys[family] = familyKey;
    _offeredFiles[hex] = familyKey;
    if (_registeredFiles.contains('$familyKey/$hex')) {
      _onFamilyReady(familyKey);
      return null;
    }
    final cached = await fontCache.get(hex);
    if (cached != null && _hex(sha256.convert(cached).bytes) == hex) {
      await _register(familyKey, hex, cached);
      return null;
    }
    return hash;
  }

  /// Handles a `font` sent in answer to a request. Files whose content does
  /// not match the hash are dropped, so a host cannot poison the cache.
  Future<void> addFont(ByteReader r) async {
    final hex = _hex(r.bytes(32));
    final familyKey = _offeredFiles[hex];
    if (familyKey == null) return;
    final bytes = Uint8List.fromList(r.rest());
    if (_hex(sha256.convert(bytes).bytes) != hex) return;
    await fontCache.put(hex, bytes);
    await _register(familyKey, hex, bytes);
  }

  Future<void> _register(String familyKey, String hex, Uint8List bytes) async {
    if (_registeredFiles.add('$familyKey/$hex')) {
      await ui.loadFontFromList(bytes, fontFamily: remoteFamily(familyKey));
    }
    _onFamilyReady(familyKey);
  }

  void _onFamilyReady(String familyKey) {
    _registeredFamilies.add(familyKey);
    _flutterStyles.clear();
    _clearParagraphs();
  }

  String? _resolveFamily(String family) {
    final key = _familyKeys[family];
    return key != null && _registeredFamilies.contains(key) ? remoteFamily(key) : null;
  }

  static String _hex(List<int> bytes) => [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();

  TextStyle? textStyle(int id) {
    final cached = _flutterStyles[id];
    if (cached != null) return cached;
    final style = styles[id];
    if (style == null) return null;
    return _flutterStyles[id] = style.toTextStyle(resolveFamily: _resolveFamily);
  }

  /// A single-line paragraph for one run, laid out at its natural width.
  ui.Paragraph? paragraph(int styleId, String text, bool rtl) {
    final key = '$styleId\u0000${rtl ? 1 : 0}\u0000$text';
    final cached = _paragraphs.remove(key);
    if (cached != null) {
      _paragraphs[key] = cached;
      return cached;
    }
    final style = textStyle(styleId);
    if (style == null) return null;
    final builder =
        ui.ParagraphBuilder(ui.ParagraphStyle(textDirection: rtl ? TextDirection.rtl : TextDirection.ltr, maxLines: 1))
          ..pushStyle(style.getTextStyle())
          ..addText(text);
    final paragraph = builder.build()..layout(const ui.ParagraphConstraints(width: double.infinity));
    // Right-to-left text anchors to the right edge, which must be finite.
    paragraph.layout(ui.ParagraphConstraints(width: paragraph.maxIntrinsicWidth.ceilToDouble()));
    _paragraphs[key] = paragraph;
    if (_paragraphs.length > _paragraphCacheSize) {
      _paragraphs.remove(_paragraphs.keys.first)?.dispose();
    }
    return paragraph;
  }

  void setImage(int id, RemoteImage image) {
    images.remove(id)?.image.dispose();
    images[id] = image;
  }

  void releaseImage(int id) => images.remove(id)?.image.dispose();

  void _clearParagraphs() {
    for (final p in _paragraphs.values) {
      p.dispose();
    }
    _paragraphs.clear();
  }

  /// Drops per-session state. Loaded fonts stay registered with the engine.
  void clear() {
    for (final image in images.values) {
      image.image.dispose();
    }
    images.clear();
    chunks.clear();
    styles.clear();
    _flutterStyles.clear();
    _familyKeys.clear();
    _offeredFiles.clear();
    _clearParagraphs();
  }
}
