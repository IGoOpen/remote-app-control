import 'package:flutter/rendering.dart';

/// The styled text behind a paragraph.
///
/// `ui.Paragraph` does not expose its text or styles, so they are captured
/// from the render object that owns it right before it paints, and matched
/// with the next `drawParagraph`.
class TextSource {
  const TextSource({required this.text, required this.textAlign, required this.textScaler, required this.ellipsis});

  final InlineSpan text;
  final TextAlign textAlign;
  final TextScaler textScaler;
  final bool ellipsis;

  static TextSource? of(RenderObject object) {
    if (object is RenderParagraph) {
      return TextSource(
        text: object.text,
        textAlign: object.textAlign,
        textScaler: object.textScaler,
        ellipsis: object.overflow == TextOverflow.ellipsis,
      );
    }
    if (object is RenderEditable) {
      final text = object.text;
      if (text == null) return null;
      return TextSource(text: text, textAlign: object.textAlign, textScaler: object.textScaler, ellipsis: false);
    }
    return null;
  }
}
