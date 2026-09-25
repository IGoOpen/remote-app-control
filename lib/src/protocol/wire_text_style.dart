import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/painting.dart';

import 'byte_buffer.dart';
import 'codec.dart';
import 'wire.dart';

/// A fully resolved text style: no inheritance and no nulls for the fields a
/// renderer needs, so any viewer can draw it without Flutter's style rules.
@immutable
class WireTextStyle {
  const WireTextStyle({
    required this.color,
    required this.fontSize,
    required this.fontWeight,
    required this.italic,
    required this.family,
    this.fallback = const [],
    this.letterSpacing,
    this.wordSpacing,
    this.decoration = 0,
    this.decorationColor = const Color(0xFF000000),
    this.decorationStyle = TextDecorationStyle.solid,
    this.decorationThickness = 1,
    this.background,
    this.shadows = const [],
  });

  /// Resolves [style] as Flutter would paint it, with text scaling baked
  /// into the font size.
  factory WireTextStyle.resolve(TextStyle? style, TextScaler scaler) {
    final s = style ?? const TextStyle();
    final color = s.color ?? s.foreground?.color ?? const Color(0xFF000000);
    return WireTextStyle(
      color: color,
      fontSize: scaler.scale(s.fontSize ?? 14.0),
      fontWeight: (s.fontWeight ?? FontWeight.normal).value,
      italic: s.fontStyle == FontStyle.italic,
      family: s.fontFamily ?? '',
      fallback: s.fontFamilyFallback ?? const [],
      letterSpacing: s.letterSpacing,
      wordSpacing: s.wordSpacing,
      decoration: _decorationBits(s.decoration),
      decorationColor: s.decorationColor ?? color,
      decorationStyle: s.decorationStyle ?? TextDecorationStyle.solid,
      decorationThickness: s.decorationThickness ?? 1,
      background: s.backgroundColor ?? s.background?.color,
      shadows: s.shadows ?? const [],
    );
  }

  final Color color;
  final double fontSize;
  final int fontWeight;
  final bool italic;

  /// Empty for the platform default font.
  final String family;
  final List<String> fallback;
  final double? letterSpacing;
  final double? wordSpacing;

  /// Bits: 1 underline, 2 overline, 4 line-through.
  final int decoration;
  final Color decorationColor;
  final TextDecorationStyle decorationStyle;
  final double decorationThickness;
  final Color? background;
  final List<Shadow> shadows;

  void write(ByteWriter w) {
    var flags = 0;
    if (italic) flags |= StyleFlag.italic;
    if (letterSpacing != null) flags |= StyleFlag.letterSpacing;
    if (wordSpacing != null) flags |= StyleFlag.wordSpacing;
    if (decoration != 0) flags |= StyleFlag.decoration;
    if (background != null) flags |= StyleFlag.background;
    if (shadows.isNotEmpty) flags |= StyleFlag.shadows;
    w
      ..color(color)
      ..f32(fontSize)
      ..u16(fontWeight)
      ..u8(flags)
      ..string(family)
      ..varUint(fallback.length);
    fallback.forEach(w.string);
    if (letterSpacing != null) w.f32(letterSpacing!);
    if (wordSpacing != null) w.f32(wordSpacing!);
    if (decoration != 0) {
      w
        ..u8(decoration)
        ..color(decorationColor)
        ..u8(decorationStyle.index)
        ..f32(decorationThickness);
    }
    if (background != null) w.color(background!);
    if (shadows.isNotEmpty) {
      w.varUint(shadows.length);
      for (final shadow in shadows) {
        w
          ..color(shadow.color)
          ..point(shadow.offset)
          ..f32(shadow.blurRadius);
      }
    }
  }

  static WireTextStyle read(ByteReader r) {
    final color = r.color();
    final fontSize = r.f32();
    final weight = r.u16();
    final flags = r.u8();
    final family = r.string();
    final fallback = List.generate(r.varUint(), (_) => r.string());
    final letterSpacing = flags & StyleFlag.letterSpacing != 0 ? r.f32() : null;
    final wordSpacing = flags & StyleFlag.wordSpacing != 0 ? r.f32() : null;
    var decoration = 0;
    var decorationColor = color;
    var decorationStyle = TextDecorationStyle.solid;
    var decorationThickness = 1.0;
    if (flags & StyleFlag.decoration != 0) {
      decoration = r.u8();
      decorationColor = r.color();
      decorationStyle = TextDecorationStyle.values[r.u8()];
      decorationThickness = r.f32();
    }
    final background = flags & StyleFlag.background != 0 ? r.color() : null;
    final shadows = flags & StyleFlag.shadows != 0
        ? List.generate(r.varUint(), (_) => Shadow(color: r.color(), offset: r.point(), blurRadius: r.f32()))
        : const <Shadow>[];
    return WireTextStyle(
      color: color,
      fontSize: fontSize,
      fontWeight: weight,
      italic: flags & StyleFlag.italic != 0,
      family: family,
      fallback: fallback,
      letterSpacing: letterSpacing,
      wordSpacing: wordSpacing,
      decoration: decoration,
      decorationColor: decorationColor,
      decorationStyle: decorationStyle,
      decorationThickness: decorationThickness,
      background: background,
      shadows: shadows,
    );
  }

  /// [resolveFamily] maps a remote family to one available locally, e.g. a
  /// font the host has sent.
  TextStyle toTextStyle({String? Function(String family)? resolveFamily}) {
    String? map(String f) => resolveFamily?.call(f) ?? f;
    return TextStyle(
      color: color,
      fontSize: fontSize,
      fontWeight: FontWeight(fontWeight),
      fontStyle: italic ? FontStyle.italic : FontStyle.normal,
      fontFamily: family.isEmpty ? null : map(family),
      fontFamilyFallback: [if (family.isNotEmpty && map(family) != family) family, for (final f in fallback) ?map(f)],
      letterSpacing: letterSpacing,
      wordSpacing: wordSpacing,
      decoration: TextDecoration.combine([
        if (decoration & 1 != 0) TextDecoration.underline,
        if (decoration & 2 != 0) TextDecoration.overline,
        if (decoration & 4 != 0) TextDecoration.lineThrough,
      ]),
      decorationColor: decorationColor,
      decorationStyle: decorationStyle,
      decorationThickness: decorationThickness,
      shadows: shadows.isEmpty ? null : shadows,
    );
  }

  static int _decorationBits(TextDecoration? d) {
    if (d == null) return 0;
    var bits = 0;
    if (d.contains(TextDecoration.underline)) bits |= 1;
    if (d.contains(TextDecoration.overline)) bits |= 2;
    if (d.contains(TextDecoration.lineThrough)) bits |= 4;
    return bits;
  }
}
