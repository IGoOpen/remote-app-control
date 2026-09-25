import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../protocol/byte_buffer.dart';
import '../protocol/codec.dart';
import '../protocol/wire.dart';
import '../protocol/wire_text_style.dart';
import 'style_registry.dart';
import 'text_source.dart';

/// Converts laid-out paragraphs into positioned text runs.
///
/// The host has already done line breaking, alignment, bidi and ellipsis,
/// so the viewer only has to draw each run at its box: no text layout engine
/// is needed on the other side, and a browser canvas reproduces the result.
class TextLayoutEncoder {
  TextLayoutEncoder(this.styles);

  final StyleRegistry styles;

  // Paragraph objects are reused by TextPainter until the text changes, so
  // most frames hit this cache.
  final Expando<_CachedRuns> _cache = Expando('text runs');

  /// Returns the encoded runs of [paragraph], relative to its paint offset:
  /// `varuint count`, then per run `varuint style`, `string text`,
  /// `rect box`, `f32 baseline`, `u8 flags`.
  Uint8List encode(ui.Paragraph paragraph, TextSource source) {
    final cached = _cache[paragraph];
    if (cached != null &&
        cached.generation == styles.generation &&
        cached.width == paragraph.width &&
        cached.height == paragraph.height) {
      return cached.bytes;
    }
    final runs = _layout(paragraph, source);
    final w = ByteWriter(64 + runs.length * 32)..varUint(runs.length);
    for (final run in runs) {
      w
        ..varUint(run.style)
        ..string(run.text)
        ..rect(run.box)
        ..f32(run.baseline)
        ..u8(run.rtl ? RunFlag.rtl : 0);
    }
    final bytes = w.takeBytes();
    _cache[paragraph] = _CachedRuns(styles.generation, paragraph.width, paragraph.height, bytes);
    return bytes;
  }

  List<_Run> _layout(ui.Paragraph p, TextSource source) {
    final segments = <_Segment>[];
    final buffer = StringBuffer();
    _flatten(source.text, null, source.textScaler, segments, buffer);
    final text = buffer.toString();
    final justify = source.textAlign == TextAlign.justify;
    final ellipsized = source.ellipsis && p.didExceedMaxLines;
    final lastLine = p.numberOfLines - 1;

    final runs = <_Run>[];
    for (final segment in segments) {
      var position = segment.start;
      while (position < segment.end) {
        final line = p.getLineNumberAt(position);
        final boundary = p.getLineBoundary(TextPosition(offset: position));
        // Text past the last visible line (maxLines) has no line.
        if (line == null) break;
        if (boundary.end <= position) {
          position++; // A line break character.
          continue;
        }
        final pieceEnd = segment.end < boundary.end ? segment.end : boundary.end;
        final metrics = p.getLineMetricsAt(line)!;
        var end = pieceEnd;
        if (ellipsized && line == lastLine) end = _visibleEnd(p, position, end);
        final pieces = justify ? _words(text, position, end) : [(position, end)];
        for (final (start, stop) in pieces) {
          _addRuns(p, text, start, stop, segment.style, metrics.baseline, runs);
        }
        position = pieceEnd;
      }
    }
    if (ellipsized && runs.isNotEmpty) {
      // The ellipsis glyph is laid out inside the last visible cluster's box.
      final last = runs.removeLast();
      runs.add(_Run(last.style, '${last.text}…', last.box, last.baseline, last.rtl));
    }
    return runs;
  }

  void _flatten(InlineSpan span, TextStyle? inherited, TextScaler scaler, List<_Segment> out, StringBuffer text) {
    if (span is TextSpan) {
      final style = inherited == null ? span.style : inherited.merge(span.style);
      final value = span.text;
      if (value != null && value.isNotEmpty) {
        final start = text.length;
        text.write(value);
        out.add(_Segment(start, text.length, styles.idFor(WireTextStyle.resolve(style, scaler))));
      }
      for (final child in span.children ?? const <InlineSpan>[]) {
        _flatten(child, style, scaler, out, text);
      }
    } else {
      // Placeholders occupy one object replacement character; the widget
      // itself is painted separately.
      text.write('￼');
    }
  }

  /// Glyphs hidden by an ellipsis report no boxes.
  static int _visibleEnd(ui.Paragraph p, int start, int end) {
    while (end > start && p.getBoxesForRange(end - 1, end).isEmpty) {
      end--;
    }
    return end;
  }

  /// Justified lines stretch the spaces, so each word keeps its own box.
  static List<(int, int)> _words(String text, int start, int end) {
    final out = <(int, int)>[];
    var wordStart = start;
    for (var i = start; i < end; i++) {
      if (text.codeUnitAt(i) == 0x20) {
        if (i > wordStart) out.add((wordStart, i));
        wordStart = i + 1;
      }
    }
    if (end > wordStart) out.add((wordStart, end));
    return out;
  }

  static void _addRuns(ui.Paragraph p, String text, int start, int end, int style, double baseline, List<_Run> runs) {
    // Trailing whitespace and line breaks draw nothing.
    while (end > start && _isTrailingSpace(text.codeUnitAt(end - 1))) {
      end--;
    }
    if (end <= start) return;
    final boxes = p.getBoxesForRange(start, end);
    if (boxes.isEmpty) return;
    final direction = boxes.first.direction;
    if (boxes.every((b) => b.direction == direction)) {
      var box = boxes.first.toRect();
      for (final b in boxes.skip(1)) {
        box = box.expandToInclude(b.toRect());
      }
      runs.add(_Run(style, text.substring(start, end), box, baseline, direction == TextDirection.rtl));
      return;
    }
    // Mixed direction within one piece: fall back to one run per cluster.
    var i = start;
    while (i < end) {
      final glyph = p.getGlyphInfoAt(i);
      if (glyph == null) {
        i++;
        continue;
      }
      final range = glyph.graphemeClusterCodeUnitRange;
      final clusterEnd = range.end > end ? end : range.end;
      runs.add(
        _Run(
          style,
          text.substring(i, clusterEnd),
          glyph.graphemeClusterLayoutBounds,
          baseline,
          glyph.writingDirection == TextDirection.rtl,
        ),
      );
      i = clusterEnd > i ? clusterEnd : i + 1;
    }
  }

  static bool _isTrailingSpace(int c) => c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09;
}

class _Segment {
  _Segment(this.start, this.end, this.style);

  final int start;
  final int end;
  final int style;
}

class _Run {
  _Run(this.style, this.text, this.box, this.baseline, this.rtl);

  final int style;
  final String text;
  final Rect box;
  final double baseline;
  final bool rtl;
}

class _CachedRuns {
  _CachedRuns(this.generation, this.width, this.height, this.bytes);

  final int generation;
  final double width;
  final double height;
  final Uint8List bytes;
}
