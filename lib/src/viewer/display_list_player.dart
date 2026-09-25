import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../protocol/byte_buffer.dart';
import '../protocol/codec.dart';
import '../protocol/wire.dart';
import 'remote_resources.dart';

/// Replays a recorded display list onto a canvas.
class DisplayListPlayer {
  static final Paint _maskPaint = Paint()..color = const Color(0xFF37474F);
  static final Paint _placeholderPaint = Paint()..color = const Color(0xFF9E9E9E);

  /// Draws [ops] onto [canvas], following references to other chunks.
  /// Images that have not arrived yet are skipped; the caller repaints once
  /// they do.
  static void play(Canvas canvas, Uint8List ops, RemoteResources resources) {
    final r = ByteReader(ops);
    final baseCount = canvas.getSaveCount();
    try {
      while (r.hasMore) {
        _step(canvas, r, resources);
      }
    } finally {
      canvas.restoreToCount(baseCount);
    }
  }

  static void _step(Canvas canvas, ByteReader r, RemoteResources resources) {
    final op = r.u8();
    switch (op) {
      case Op.save:
        canvas.save();
      case Op.saveLayer:
        final bounds = r.boolean() ? r.rect() : null;
        canvas.saveLayer(bounds, r.paint());
      case Op.restore:
        canvas.restore();
      case Op.translate:
        canvas.translate(r.f32(), r.f32());
      case Op.scale:
        canvas.scale(r.f32(), r.f32());
      case Op.rotate:
        canvas.rotate(r.f32());
      case Op.skew:
        canvas.skew(r.f32(), r.f32());
      case Op.transform:
        canvas.transform(Float64List.fromList(List.generate(16, (_) => r.f32())));
      case Op.clipRect:
        canvas.clipRect(r.rect(), clipOp: ui.ClipOp.values[r.u8()], doAntiAlias: r.boolean());
      case Op.clipRRect:
        canvas.clipRRect(r.rrect(), doAntiAlias: r.boolean());
      case Op.clipRSuperellipse:
        canvas.clipRSuperellipse(r.rsuperellipse(), doAntiAlias: r.boolean());
      case Op.clipPath:
        canvas.clipPath(r.path(), doAntiAlias: r.boolean());
      case Op.drawColor:
        canvas.drawColor(r.color(), BlendMode.values[r.u8()]);
      case Op.drawLine:
        canvas.drawLine(r.point(), r.point(), r.paint());
      case Op.drawPaint:
        canvas.drawPaint(r.paint());
      case Op.drawRect:
        canvas.drawRect(r.rect(), r.paint());
      case Op.drawRRect:
        canvas.drawRRect(r.rrect(), r.paint());
      case Op.drawDRRect:
        canvas.drawDRRect(r.rrect(), r.rrect(), r.paint());
      case Op.drawRSuperellipse:
        canvas.drawRSuperellipse(r.rsuperellipse(), r.paint());
      case Op.drawOval:
        canvas.drawOval(r.rect(), r.paint());
      case Op.drawCircle:
        canvas.drawCircle(r.point(), r.f32(), r.paint());
      case Op.drawArc:
        canvas.drawArc(r.rect(), r.f32(), r.f32(), r.boolean(), r.paint());
      case Op.drawPath:
        canvas.drawPath(r.path(), r.paint());
      case Op.drawImageRect:
        final image = resources.images[r.varUint()];
        final src = r.rect();
        final dst = r.rect();
        final paint = r.paint();
        if (image != null) canvas.drawImageRect(image.image, image.mapSource(src), dst, paint);
      case Op.drawImageNine:
        final image = resources.images[r.varUint()];
        final center = r.rect();
        final dst = r.rect();
        final paint = r.paint();
        if (image != null) canvas.drawImageNine(image.image, image.mapSource(center), dst, paint);
      case Op.drawPoints:
        canvas.drawRawPoints(ui.PointMode.values[r.u8()], r.float32List(), r.paint());
      case Op.drawShadow:
        canvas.drawShadow(r.path(), r.color(), r.f32(), r.boolean());
      case Op.drawText:
        _drawText(canvas, r, resources);
      case Op.placeholder:
        final rect = r.rect();
        final kind = r.u8();
        canvas.drawRect(rect, kind == PlaceholderKind.masked ? _maskPaint : _placeholderPaint);
      case Op.drawChunk:
        final chunk = resources.chunks[r.varUint()];
        final offset = r.point();
        if (chunk != null) {
          final count = canvas.getSaveCount();
          canvas
            ..save()
            ..translate(offset.dx, offset.dy);
          final nested = ByteReader(chunk);
          while (nested.hasMore) {
            _step(canvas, nested, resources);
          }
          canvas.restoreToCount(count);
        }
      default:
        throw FormatException('Unknown display list op 0x${op.toRadixString(16)}');
    }
  }

  static void _drawText(Canvas canvas, ByteReader r, RemoteResources resources) {
    final origin = r.point();
    final count = r.varUint();
    for (var i = 0; i < count; i++) {
      final styleId = r.varUint();
      final text = r.string();
      final box = r.rect().shift(origin);
      final baseline = r.f32() + origin.dy;
      final rtl = r.u8() & RunFlag.rtl != 0;

      final background = resources.styles[styleId]?.background;
      if (background != null) canvas.drawRect(box, Paint()..color = background);
      final paragraph = resources.paragraph(styleId, text, rtl);
      if (paragraph == null) continue;
      final width = paragraph.maxIntrinsicWidth;
      final top = baseline - paragraph.alphabeticBaseline;
      // Same engine, but fonts can differ slightly from the host's; stretch
      // the run to its measured box so line layout stays exact.
      if (width > 0 && (width - box.width).abs() > 0.5) {
        final anchor = rtl ? box.right : box.left;
        canvas
          ..save()
          ..translate(anchor, top)
          ..scale(box.width / width, 1)
          ..drawParagraph(paragraph, Offset(rtl ? -paragraph.width : 0, 0))
          ..restore();
      } else {
        canvas.drawParagraph(paragraph, Offset(rtl ? box.right - paragraph.width : box.left, top));
      }
    }
  }
}
