import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import '../protocol/byte_buffer.dart';
import '../protocol/codec.dart';
import '../protocol/wire.dart';
import 'image_registry.dart';
import 'text_layout.dart';
import 'text_source.dart';

/// Largest edge, in physical pixels, of an image produced by [RasterCache].
const int _maxRasterEdge = 1024;

/// A [Canvas] that serializes every call into the display list format.
///
/// A real canvas shadows all state changes so queries such as
/// [getTransform] and [getLocalClipBounds] keep returning correct answers to
/// the render objects being painted.
class RecordingCanvas implements Canvas {
  RecordingCanvas({
    required Rect bounds,
    required this.devicePixelRatio,
    required this.images,
    required this.rasterCache,
    required this.textLayout,
    this.baseScale = 1,
  }) : _shadowRecorder = ui.PictureRecorder() {
    _shadow = Canvas(_shadowRecorder, bounds);
  }

  final double devicePixelRatio;

  /// Magnification of this canvas's origin on screen, for chunks recorded
  /// inside scaled content.
  final double baseScale;
  final ImageRegistry images;
  final RasterCache rasterCache;
  final TextLayoutEncoder textLayout;
  final ByteWriter out = ByteWriter(16 * 1024);

  final ui.PictureRecorder _shadowRecorder;
  late final Canvas _shadow;

  /// Text of the paragraph about to be drawn, set by the capture context.
  TextSource? pendingText;

  /// Paint bounds of the render object being painted, used to size fallback
  /// rasterizations of draw calls that carry no bounds of their own.
  Rect? currentObjectBounds;

  /// A canvas for recording one repaint boundary, sharing this canvas's
  /// registries. [scale] is how much the boundary is magnified on screen,
  /// as returned by [absoluteScale].
  ///
  /// Chunks are reused wherever the boundary moves, so they are not clipped
  /// to the screen: the canvas bounds are effectively unlimited.
  RecordingCanvas forChunk(double scale) => RecordingCanvas(
    bounds: const Rect.fromLTRB(-1e5, -1e5, 1e5, 1e5),
    devicePixelRatio: devicePixelRatio,
    baseScale: scale,
    images: images,
    rasterCache: rasterCache,
    textLayout: textLayout,
  );

  /// How much one logical pixel at the current transform is magnified on
  /// screen.
  double get absoluteScale => baseScale * _currentScale();

  /// References another chunk, drawn with its origin at [offset].
  void drawChunk(int id, Offset offset) {
    out
      ..u8(Op.drawChunk)
      ..varUint(id)
      ..point(offset);
  }

  Uint8List finish() {
    _shadowRecorder.endRecording().dispose();
    return out.takeBytes();
  }

  // State.

  @override
  void save() {
    _shadow.save();
    out.u8(Op.save);
  }

  @override
  void saveLayer(Rect? bounds, Paint paint) {
    _shadow.saveLayer(bounds, Paint());
    out
      ..u8(Op.saveLayer)
      ..boolean(bounds != null);
    if (bounds != null) out.rect(bounds);
    // Color and image filters on layers are not representable yet; the
    // content is still drawn, just unfiltered.
    out.paint(paint);
  }

  @override
  void restore() {
    if (_shadow.getSaveCount() <= 1) return;
    _shadow.restore();
    out.u8(Op.restore);
  }

  @override
  void restoreToCount(int count) {
    final target = math.max(1, count);
    while (_shadow.getSaveCount() > target) {
      restore();
    }
  }

  @override
  int getSaveCount() => _shadow.getSaveCount();

  @override
  void translate(double dx, double dy) {
    _shadow.translate(dx, dy);
    out
      ..u8(Op.translate)
      ..f32(dx)
      ..f32(dy);
  }

  @override
  void scale(double sx, [double? sy]) {
    _shadow.scale(sx, sy);
    out
      ..u8(Op.scale)
      ..f32(sx)
      ..f32(sy ?? sx);
  }

  @override
  void rotate(double radians) {
    _shadow.rotate(radians);
    out
      ..u8(Op.rotate)
      ..f32(radians);
  }

  @override
  void skew(double sx, double sy) {
    _shadow.skew(sx, sy);
    out
      ..u8(Op.skew)
      ..f32(sx)
      ..f32(sy);
  }

  @override
  void transform(Float64List matrix4) {
    _shadow.transform(matrix4);
    out.u8(Op.transform);
    for (final v in matrix4) {
      out.f32(v);
    }
  }

  @override
  Float64List getTransform() => _shadow.getTransform();

  @override
  void clipRect(Rect rect, {ui.ClipOp clipOp = ui.ClipOp.intersect, bool doAntiAlias = true}) {
    _shadow.clipRect(rect, clipOp: clipOp, doAntiAlias: doAntiAlias);
    out
      ..u8(Op.clipRect)
      ..rect(rect)
      ..u8(clipOp.index)
      ..boolean(doAntiAlias);
  }

  @override
  void clipRRect(RRect rrect, {bool doAntiAlias = true}) {
    _shadow.clipRRect(rrect, doAntiAlias: doAntiAlias);
    out
      ..u8(Op.clipRRect)
      ..rrect(rrect)
      ..boolean(doAntiAlias);
  }

  @override
  void clipRSuperellipse(RSuperellipse rsuperellipse, {bool doAntiAlias = true}) {
    _shadow.clipRSuperellipse(rsuperellipse, doAntiAlias: doAntiAlias);
    out
      ..u8(Op.clipRSuperellipse)
      ..rsuperellipse(rsuperellipse)
      ..boolean(doAntiAlias);
  }

  @override
  void clipPath(Path path, {bool doAntiAlias = true}) {
    _shadow.clipPath(path, doAntiAlias: doAntiAlias);
    out
      ..u8(Op.clipPath)
      ..path(path)
      ..boolean(doAntiAlias);
  }

  @override
  Rect getLocalClipBounds() => _shadow.getLocalClipBounds();

  @override
  Rect getDestinationClipBounds() => _shadow.getDestinationClipBounds();

  // Drawing.

  static bool _needsRaster(Paint paint) =>
      paint.shader != null || paint.colorFilter != null || paint.imageFilter != null;

  void _writePaint(Paint paint) => out.paint(paint, blur: MaskFilterInfo.parse(paint.maskFilter));

  @override
  void drawColor(Color color, BlendMode blendMode) {
    out
      ..u8(Op.drawColor)
      ..color(color)
      ..u8(blendMode.index);
  }

  @override
  void drawLine(Offset p1, Offset p2, Paint paint) {
    if (_needsRaster(paint)) {
      final bounds = Rect.fromPoints(p1, p2).inflate(paint.strokeWidth);
      return _raster(paint.shader ?? paint, bounds, (c) => c.drawLine(p1, p2, paint));
    }
    out
      ..u8(Op.drawLine)
      ..point(p1)
      ..point(p2);
    _writePaint(paint);
  }

  @override
  void drawPaint(Paint paint) {
    if (_needsRaster(paint)) {
      return _raster(paint.shader ?? paint, getLocalClipBounds(), (c) => c.drawPaint(paint));
    }
    out.u8(Op.drawPaint);
    _writePaint(paint);
  }

  @override
  void drawRect(Rect rect, Paint paint) {
    if (_needsRaster(paint)) {
      return _raster(paint.shader ?? paint, rect, (c) => c.drawRect(rect, paint));
    }
    out
      ..u8(Op.drawRect)
      ..rect(rect);
    _writePaint(paint);
  }

  @override
  void drawRRect(RRect rrect, Paint paint) {
    if (_needsRaster(paint)) {
      return _raster(paint.shader ?? paint, rrect.outerRect, (c) => c.drawRRect(rrect, paint));
    }
    out
      ..u8(Op.drawRRect)
      ..rrect(rrect);
    _writePaint(paint);
  }

  @override
  void drawDRRect(RRect outer, RRect inner, Paint paint) {
    if (_needsRaster(paint)) {
      return _raster(paint.shader ?? paint, outer.outerRect, (c) => c.drawDRRect(outer, inner, paint));
    }
    out
      ..u8(Op.drawDRRect)
      ..rrect(outer)
      ..rrect(inner);
    _writePaint(paint);
  }

  @override
  void drawRSuperellipse(RSuperellipse rsuperellipse, Paint paint) {
    if (_needsRaster(paint)) {
      return _raster(paint.shader ?? paint, rsuperellipse.outerRect, (c) => c.drawRSuperellipse(rsuperellipse, paint));
    }
    out
      ..u8(Op.drawRSuperellipse)
      ..rsuperellipse(rsuperellipse);
    _writePaint(paint);
  }

  @override
  void drawOval(Rect rect, Paint paint) {
    if (_needsRaster(paint)) {
      return _raster(paint.shader ?? paint, rect, (c) => c.drawOval(rect, paint));
    }
    out
      ..u8(Op.drawOval)
      ..rect(rect);
    _writePaint(paint);
  }

  @override
  void drawCircle(Offset c, double radius, Paint paint) {
    if (_needsRaster(paint)) {
      final bounds = Rect.fromCircle(center: c, radius: radius + paint.strokeWidth);
      return _raster(paint.shader ?? paint, bounds, (canvas) => canvas.drawCircle(c, radius, paint));
    }
    out
      ..u8(Op.drawCircle)
      ..point(c)
      ..f32(radius);
    _writePaint(paint);
  }

  @override
  void drawArc(Rect rect, double startAngle, double sweepAngle, bool useCenter, Paint paint) {
    if (_needsRaster(paint)) {
      return _raster(
        paint.shader ?? paint,
        rect.inflate(paint.strokeWidth),
        (c) => c.drawArc(rect, startAngle, sweepAngle, useCenter, paint),
      );
    }
    out
      ..u8(Op.drawArc)
      ..rect(rect)
      ..f32(startAngle)
      ..f32(sweepAngle)
      ..boolean(useCenter);
    _writePaint(paint);
  }

  @override
  void drawPath(Path path, Paint paint) {
    if (_needsRaster(paint)) {
      return _raster(
        paint.shader ?? paint,
        path.getBounds().inflate(paint.strokeWidth),
        (c) => c.drawPath(path, paint),
      );
    }
    out
      ..u8(Op.drawPath)
      ..path(path);
    _writePaint(paint);
  }

  @override
  void drawImage(ui.Image image, Offset offset, Paint paint) {
    final size = Size(image.width.toDouble(), image.height.toDouble());
    drawImageRect(image, Offset.zero & size, offset & size, paint);
  }

  @override
  void drawImageRect(ui.Image image, Rect src, Rect dst, Paint paint) {
    if (_needsRaster(paint)) {
      return _raster(
        image,
        dst,
        (c) => c.drawImageRect(image, src, dst, paint),
        signature: '${paint.colorFilter}|$src',
      );
    }
    // How much of the source resolution survives on screen.
    final onScreen = absoluteScale * devicePixelRatio;
    final scale = math.max(
      src.width == 0 ? 1.0 : dst.width.abs() * onScreen / src.width,
      src.height == 0 ? 1.0 : dst.height.abs() * onScreen / src.height,
    );
    out
      ..u8(Op.drawImageRect)
      ..varUint(images.idFor(image, scale: scale))
      ..rect(src)
      ..rect(dst);
    _writePaint(paint);
  }

  @override
  void drawImageNine(ui.Image image, Rect center, Rect dst, Paint paint) {
    if (_needsRaster(paint)) {
      return _raster(
        image,
        dst,
        (c) => c.drawImageNine(image, center, dst, paint),
        signature: '${paint.colorFilter}|$center',
      );
    }
    out
      ..u8(Op.drawImageNine)
      ..varUint(images.idFor(image))
      ..rect(center)
      ..rect(dst);
    _writePaint(paint);
  }

  @override
  void drawPicture(ui.Picture picture) {
    final bounds = currentObjectBounds ?? getLocalClipBounds();
    _raster(picture, bounds, (c) => c.drawPicture(picture));
  }

  @override
  void drawParagraph(ui.Paragraph paragraph, Offset offset) {
    final source = pendingText;
    if (source == null) {
      final width = paragraph.width.isFinite ? paragraph.width : paragraph.longestLine;
      return _raster(paragraph, offset & Size(width, paragraph.height), (c) => c.drawParagraph(paragraph, offset));
    }
    pendingText = null;
    out
      ..u8(Op.drawText)
      ..point(offset)
      ..bytes(textLayout.encode(paragraph, source));
  }

  @override
  void drawPoints(ui.PointMode pointMode, List<Offset> points, Paint paint) {
    final raw = Float32List(points.length * 2);
    for (var i = 0; i < points.length; i++) {
      raw[i * 2] = points[i].dx;
      raw[i * 2 + 1] = points[i].dy;
    }
    drawRawPoints(pointMode, raw, paint);
  }

  @override
  void drawRawPoints(ui.PointMode pointMode, Float32List points, Paint paint) {
    out
      ..u8(Op.drawPoints)
      ..u8(pointMode.index)
      ..float32List(points);
    _writePaint(paint);
  }

  @override
  void drawVertices(ui.Vertices vertices, BlendMode blendMode, Paint paint) {
    final bounds = currentObjectBounds ?? getLocalClipBounds();
    _raster(vertices, bounds, (c) => c.drawVertices(vertices, blendMode, paint));
  }

  @override
  void drawAtlas(
    ui.Image atlas,
    List<RSTransform> transforms,
    List<Rect> rects,
    List<Color>? colors,
    BlendMode? blendMode,
    Rect? cullRect,
    Paint paint,
  ) {
    final bounds = cullRect ?? currentObjectBounds ?? getLocalClipBounds();
    _raster(
      atlas,
      bounds,
      (c) => c.drawAtlas(atlas, transforms, rects, colors, blendMode, cullRect, paint),
      signature: 'atlas${Object.hashAll(transforms)}',
    );
  }

  @override
  void drawRawAtlas(
    ui.Image atlas,
    Float32List rstTransforms,
    Float32List rects,
    Int32List? colors,
    BlendMode? blendMode,
    Rect? cullRect,
    Paint paint,
  ) {
    final bounds = cullRect ?? currentObjectBounds ?? getLocalClipBounds();
    _raster(
      atlas,
      bounds,
      (c) => c.drawRawAtlas(atlas, rstTransforms, rects, colors, blendMode, cullRect, paint),
      signature: 'rawAtlas${Object.hashAll(rstTransforms)}',
    );
  }

  @override
  void drawShadow(Path path, Color color, double elevation, bool transparentOccluder) {
    out
      ..u8(Op.drawShadow)
      ..path(path)
      ..color(color)
      ..f32(elevation)
      ..boolean(transparentOccluder);
  }

  double _currentScale() {
    final m = getTransform();
    return math.max(math.sqrt(m[0] * m[0] + m[1] * m[1]), math.sqrt(m[4] * m[4] + m[5] * m[5]));
  }

  /// Emits a region the viewer should draw as an opaque placeholder.
  void placeholder(Rect rect, int kind) {
    out
      ..u8(Op.placeholder)
      ..rect(rect)
      ..u8(kind);
  }

  /// Renders a draw call that has no wire representation (shaders, filters,
  /// pictures...) into an image and sends that instead.
  ///
  /// [key] identifies the source object; the result is reused for as long as
  /// the same object is drawn with the same bounds and scale.
  void _raster(Object key, Rect localBounds, void Function(Canvas canvas) draw, {String signature = ''}) {
    final clip = getLocalClipBounds();
    final bounds = localBounds.intersect(clip);
    if (bounds.isEmpty || !bounds.isFinite) return;

    var pixelScale = absoluteScale * devicePixelRatio;
    final longest = math.max(bounds.width, bounds.height) * pixelScale;
    if (longest > _maxRasterEdge) pixelScale *= _maxRasterEdge / longest;
    final width = math.max(1, (bounds.width * pixelScale).ceil());
    final height = math.max(1, (bounds.height * pixelScale).ceil());

    final fullSignature = '$bounds|${pixelScale.toStringAsFixed(3)}|$signature';
    final id =
        rasterCache.lookup(key, fullSignature) ??
        rasterCache.store(key, fullSignature, images, () {
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder)
            ..scale(pixelScale)
            ..translate(-bounds.left, -bounds.top);
          draw(canvas);
          final picture = recorder.endRecording();
          final image = picture.toImageSync(width, height);
          picture.dispose();
          return image;
        });

    out
      ..u8(Op.drawImageRect)
      ..varUint(id)
      ..rect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()))
      ..rect(bounds);
    _writePaint(Paint()..filterQuality = FilterQuality.medium);
  }
}

/// Remembers rasterized fallbacks across frames, keyed by the drawn object.
class RasterCache {
  Expando<_RasterEntry> _entries = Expando<_RasterEntry>('remote raster');
  final Finalizer<(ImageRegistry, int)> _finalizer = Finalizer<(ImageRegistry, int)>(
    (token) => token.$1.release(token.$2),
  );

  int? lookup(Object key, String signature) {
    final entry = _entries[key];
    return entry != null && entry.signature == signature ? entry.imageId : null;
  }

  int store(Object key, String signature, ImageRegistry images, ui.Image Function() render) {
    final previous = _entries[key];
    if (previous != null) {
      images.release(previous.imageId);
      _finalizer.detach(previous);
    }
    final id = images.register(render());
    final entry = _RasterEntry(signature, id);
    _entries[key] = entry;
    _finalizer.attach(key, (images, id), detach: entry);
    return id;
  }

  void clear() => _entries = Expando<_RasterEntry>('remote raster');
}

class _RasterEntry {
  _RasterEntry(this.signature, this.imageId);

  final String signature;
  final int imageId;
}
