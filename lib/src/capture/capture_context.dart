import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import '../protocol/wire.dart';
import '../widgets/remote_mask.dart';
import 'chunk_cache.dart';
import 'recording_canvas.dart';
import 'text_source.dart';

/// A [PaintingContext] that re-paints the render tree into a
/// [RecordingCanvas] instead of the compositor's layer tree.
///
/// Layers are flattened into canvas operations, and nothing here may touch
/// the layers owned by the live render tree: every `push*` override returns
/// the `oldLayer` it was given so render objects keep their layer handles.
class CaptureContext extends PaintingContext {
  CaptureContext._(this._recording, Rect bounds, this._chunks, this._layer) : super(_layer, bounds);

  final RecordingCanvas _recording;
  final ChunkCache _chunks;

  /// Child boundaries this chunk references, and their layers.
  final Set<Layer> _childLayers = {};
  final List<(RenderObject, double)> _children = [];

  // PaintingContext requires a container layer; nothing is ever added to it.
  final ContainerLayer _layer;

  static bool _reportedError = false;

  @override
  Canvas get canvas => _recording;

  @override
  void paintChild(RenderObject child, Offset offset) {
    if (child is RenderRemoteMask) {
      _recording.placeholder(child.paintBounds.shift(offset), PlaceholderKind.masked);
      return;
    }

    if (child.isRepaintBoundary) {
      _paintBoundary(child, offset);
      return;
    }

    final previousText = _recording.pendingText;
    final previousBounds = _recording.currentObjectBounds;
    final source = TextSource.of(child);
    if (source != null) _recording.pendingText = source;
    _recording.currentObjectBounds = child.paintBounds.shift(offset);
    final saveCount = _recording.getSaveCount();
    try {
      child.paint(this, offset);
    } catch (error, stack) {
      // A capture bug must never break the host app; log once and keep going.
      if (!_reportedError) {
        _reportedError = true;
        debugPrint('remote_app_control: failed to capture ${child.runtimeType}: $error\n$stack');
      }
    } finally {
      _recording.restoreToCount(saveCount);
      _recording.pendingText = previousText;
      _recording.currentObjectBounds = previousBounds;
    }
  }

  /// Draws a repaint boundary as a reference to its chunk, recording the
  /// chunk only if the boundary repainted since it was last recorded.
  void _paintBoundary(RenderObject child, Offset offset) {
    final layer = ChunkCache.layerOf(child);
    if (layer != null) _childLayers.add(layer);
    final scale = (_recording.absoluteScale * 100).roundToDouble() / 100;
    _children.add((child, scale));
    final chunk = _ensureChunk(child, scale, _chunks, (s) => _recording.forChunk(s));

    // Opacity on a boundary lives in its composited layer, not in paint().
    final alpha = layer is OpacityLayer ? layer.alpha : null;
    if (alpha != null && alpha < 255) {
      _recording
        ..save()
        ..translate(offset.dx, offset.dy)
        ..saveLayer(null, Paint()..color = Color.fromARGB(alpha, 0, 0, 0))
        ..drawChunk(chunk.id, Offset.zero)
        ..restore()
        ..restore();
    } else {
      _recording.drawChunk(chunk.id, offset);
    }
  }

  /// Returns an up-to-date chunk for [boundary]: its previous recording if
  /// it did not repaint (after bringing its children up to date), or a new
  /// one recorded on a canvas from [canvasFor].
  static Chunk _ensureChunk(
    RenderObject boundary,
    double scale,
    ChunkCache chunks,
    RecordingCanvas Function(double scale) canvasFor,
  ) {
    final reused = chunks.reusable(boundary, scale);
    if (reused == null) return _recordChunk(canvasFor(scale), boundary, scale, chunks);
    _refreshChildren(reused, chunks, canvasFor);
    return reused;
  }

  /// A reused chunk keeps its bytes, but the child chunks it references
  /// may have repainted independently.
  static void _refreshChildren(Chunk chunk, ChunkCache chunks, RecordingCanvas Function(double scale) canvasFor) {
    for (final (child, scale) in chunk.children) {
      _ensureChunk(child, scale, chunks, canvasFor);
    }
  }

  static Chunk _recordChunk(RecordingCanvas canvas, RenderObject boundary, double scale, ChunkCache chunks) {
    final context = CaptureContext._(canvas, boundary.paintBounds, chunks, ContainerLayer());
    canvas.currentObjectBounds = boundary.paintBounds;
    try {
      boundary.paint(context, Offset.zero);
    } catch (error, stack) {
      if (!_reportedError) {
        _reportedError = true;
        debugPrint('remote_app_control: failed to capture ${boundary.runtimeType}: $error\n$stack');
      }
    } finally {
      canvas.restoreToCount(1);
      context._layer.dispose();
    }
    return chunks.store(boundary, scale, canvas.finish(), context._childLayers, context._children);
  }

  @override
  void pushLayer(ContainerLayer childLayer, PaintingContextCallback painter, Offset offset, {Rect? childPaintBounds}) {
    final c = _recording..save();
    switch (childLayer) {
      case ClipRectLayer(:final clipRect?, :final clipBehavior):
        c.clipRect(clipRect, doAntiAlias: clipBehavior != Clip.hardEdge);
      case ClipRRectLayer(:final clipRRect?, :final clipBehavior):
        c.clipRRect(clipRRect, doAntiAlias: clipBehavior != Clip.hardEdge);
      case ClipRSuperellipseLayer(:final clipRSuperellipse?, :final clipBehavior):
        c.clipRSuperellipse(clipRSuperellipse, doAntiAlias: clipBehavior != Clip.hardEdge);
      case ClipPathLayer(:final clipPath?, :final clipBehavior):
        c.clipPath(clipPath, doAntiAlias: clipBehavior != Clip.hardEdge);
      case TransformLayer(:final transform?, offset: final layerOffset):
        c
          ..translate(layerOffset.dx, layerOffset.dy)
          ..transform(transform.storage);
      case OpacityLayer(:final alpha, offset: final layerOffset):
        c.translate(layerOffset.dx, layerOffset.dy);
        if (alpha != null && alpha < 255) {
          c.saveLayer(null, Paint()..color = Color.fromARGB(alpha, 0, 0, 0));
        }
      case FollowerLayer():
        final transform = childLayer.getLastTransform();
        if (transform != null) {
          c.transform(transform.storage);
        } else {
          c.translate(childLayer.unlinkedOffset?.dx ?? 0, childLayer.unlinkedOffset?.dy ?? 0);
        }
      case LeaderLayer(offset: final layerOffset):
        c.translate(layerOffset.dx, layerOffset.dy);
      case OffsetLayer(offset: final layerOffset):
        c.translate(layerOffset.dx, layerOffset.dy);
      default:
        // Color filters, backdrop filters and shader masks: paint the content
        // unfiltered rather than dropping it.
        break;
    }
    painter(this, offset);
    c.restore();
  }

  @override
  PaintingContext createChildContext(ContainerLayer childLayer, Rect bounds) => this;

  @override
  void addLayer(Layer layer) {
    switch (layer) {
      case PlatformViewLayer(:final rect):
        _recording.placeholder(rect, PlaceholderKind.platformView);
      case TextureLayer(:final rect):
        _recording.placeholder(rect, PlaceholderKind.texture);
      case PictureLayer(:final picture?):
        _recording.drawPicture(picture);
      default:
        break;
    }
  }

  @override
  void stopRecordingIfNeeded() => super.stopRecordingIfNeeded();

  @override
  void setIsComplexHint() {}

  @override
  void setWillChangeHint() {}

  @override
  ClipRectLayer? pushClipRect(
    bool needsCompositing,
    Offset offset,
    Rect clipRect,
    PaintingContextCallback painter, {
    Clip clipBehavior = Clip.hardEdge,
    ClipRectLayer? oldLayer,
  }) {
    super.pushClipRect(false, offset, clipRect, painter, clipBehavior: clipBehavior);
    return oldLayer;
  }

  @override
  ClipRRectLayer? pushClipRRect(
    bool needsCompositing,
    Offset offset,
    Rect bounds,
    RRect clipRRect,
    PaintingContextCallback painter, {
    Clip clipBehavior = Clip.antiAlias,
    ClipRRectLayer? oldLayer,
  }) {
    super.pushClipRRect(false, offset, bounds, clipRRect, painter, clipBehavior: clipBehavior);
    return oldLayer;
  }

  @override
  ClipRSuperellipseLayer? pushClipRSuperellipse(
    bool needsCompositing,
    Offset offset,
    Rect bounds,
    RSuperellipse clipRSuperellipse,
    PaintingContextCallback painter, {
    Clip clipBehavior = Clip.antiAlias,
    ClipRSuperellipseLayer? oldLayer,
  }) {
    super.pushClipRSuperellipse(false, offset, bounds, clipRSuperellipse, painter, clipBehavior: clipBehavior);
    return oldLayer;
  }

  @override
  ClipPathLayer? pushClipPath(
    bool needsCompositing,
    Offset offset,
    Rect bounds,
    Path clipPath,
    PaintingContextCallback painter, {
    Clip clipBehavior = Clip.antiAlias,
    ClipPathLayer? oldLayer,
  }) {
    super.pushClipPath(false, offset, bounds, clipPath, painter, clipBehavior: clipBehavior);
    return oldLayer;
  }

  @override
  TransformLayer? pushTransform(
    bool needsCompositing,
    Offset offset,
    Matrix4 transform,
    PaintingContextCallback painter, {
    TransformLayer? oldLayer,
  }) {
    super.pushTransform(false, offset, transform, painter);
    return oldLayer;
  }

  @override
  OpacityLayer pushOpacity(Offset offset, int alpha, PaintingContextCallback painter, {OpacityLayer? oldLayer}) {
    final c = _recording
      ..save()
      ..translate(offset.dx, offset.dy);
    if (alpha < 255) c.saveLayer(null, Paint()..color = Color.fromARGB(alpha, 0, 0, 0));
    painter(this, Offset.zero);
    c.restoreToCount(c.getSaveCount() - (alpha < 255 ? 2 : 1));
    return oldLayer ?? OpacityLayer();
  }

  @override
  ColorFilterLayer pushColorFilter(
    Offset offset,
    ColorFilter colorFilter,
    PaintingContextCallback painter, {
    ColorFilterLayer? oldLayer,
  }) {
    painter(this, offset);
    return oldLayer ?? ColorFilterLayer();
  }

  /// Records [view] as chunks, reusing the ones that did not change, and
  /// returns the root chunk's id. Returns null if the view has not been
  /// laid out yet.
  static int? record(RenderView view, RecordingCanvas canvas, ChunkCache chunks) {
    if (view.size.isEmpty) return null;
    // The root is recorded on the screen-sized canvas; nested chunks get
    // their own unbounded canvases.
    final reused = chunks.reusable(view, 1);
    if (reused == null) return _recordChunk(canvas, view, 1, chunks).id;
    _refreshChildren(reused, chunks, canvas.forChunk);
    return reused.id;
  }

  @visibleForTesting
  static void resetErrorReporting() => _reportedError = false;
}
