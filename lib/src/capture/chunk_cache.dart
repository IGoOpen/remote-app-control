import 'dart:typed_data';

import 'package:flutter/rendering.dart';

/// The recorded display list of one repaint boundary.
class Chunk {
  Chunk(this.id, this.scale, this.bytes, this.fingerprint, this.childLayers, this.children);

  final int id;

  /// Canvas scale the chunk was recorded at; rasterized content depends on it.
  final double scale;
  final Uint8List bytes;

  /// Snapshot of the boundary's layer subtree when it was recorded. Null
  /// when the boundary had no layer, which forces re-recording.
  final List<Object?>? fingerprint;

  /// Layers of the child boundaries referenced from this chunk. The
  /// fingerprint stops at them: a child changing does not invalidate us.
  final Set<Layer> childLayers;

  /// Child boundaries referenced from this chunk, with their scale. Reusing
  /// this chunk still requires checking each of them.
  final List<(RenderObject, double)> children;

  bool released = false;
}

/// Retains the recording of every repaint boundary between frames.
///
/// Flutter gives a repaint boundary fresh picture layers whenever it
/// repaints and leaves them untouched otherwise, so comparing the layer
/// subtree (identities plus clip, transform and opacity values) tells us
/// whether its previous recording is still valid, without calling `paint`.
///
/// Chunks reference their child boundaries by id, so a change deep in the
/// tree only re-records and re-sends the chunks on the path that changed.
class ChunkCache {
  Expando<Chunk> _byObject = Expando('remote chunk');
  final Map<int, Chunk> _live = {};
  final Set<int> _used = {};
  final List<Chunk> _changed = [];
  int _nextId = 1;

  /// Chunks recorded and reused during the last frame, for diagnostics.
  int recorded = 0;
  int reused = 0;

  Iterable<Chunk> get live => _live.values;

  void beginFrame() {
    _used.clear();
    _changed.clear();
    recorded = 0;
    reused = 0;
  }

  /// The previous recording of [object] if nothing it paints itself has
  /// changed. Its child boundaries must still be checked by the caller.
  Chunk? reusable(RenderObject object, double scale) {
    final chunk = _byObject[object];
    if (chunk == null || chunk.released || chunk.scale != scale) return null;
    final fingerprint = chunk.fingerprint;
    final layer = layerOf(object);
    if (fingerprint == null || layer == null) return null;
    if (!_matches(fingerprint, layer, chunk.childLayers)) return null;
    _used.add(chunk.id);
    reused++;
    return chunk;
  }

  Chunk store(
    RenderObject object,
    double scale,
    Uint8List bytes,
    Set<Layer> childLayers,
    List<(RenderObject, double)> children,
  ) {
    final previous = _byObject[object];
    // Keep the id so viewers replace the chunk in place.
    final id = previous != null && !previous.released ? previous.id : _nextId++;
    final layer = layerOf(object);
    final chunk = Chunk(
      id,
      scale,
      bytes,
      layer == null ? null : fingerprintOf(layer, childLayers),
      childLayers,
      children,
    );
    _byObject[object] = chunk;
    _live[id] = chunk;
    _used.add(id);
    _changed.add(chunk);
    recorded++;
    return chunk;
  }

  /// Chunks recorded this frame, and ids of chunks no longer painted.
  (List<Chunk>, List<int>) endFrame() {
    final released = <int>[];
    _live.removeWhere((id, chunk) {
      if (_used.contains(id)) return false;
      chunk.released = true;
      released.add(id);
      return true;
    });
    return (List.of(_changed), released);
  }

  void clear() {
    for (final chunk in _live.values) {
      chunk.released = true;
    }
    _live.clear();
    _byObject = Expando('remote chunk');
  }

  // Render objects keep their composited layer protected; reading it does
  // not modify the tree.
  // ignore: invalid_use_of_protected_member
  static ContainerLayer? layerOf(RenderObject object) => object.layer;

  static List<Object?> fingerprintOf(ContainerLayer layer, Set<Layer> boundaries) {
    final out = <Object?>[];
    _collect(layer, boundaries, out);
    return out;
  }

  static bool _matches(List<Object?> fingerprint, ContainerLayer layer, Set<Layer> boundaries) {
    final current = fingerprintOf(layer, boundaries);
    if (current.length != fingerprint.length) return false;
    for (var i = 0; i < current.length; i++) {
      final a = current[i];
      final b = fingerprint[i];
      if (a is Layer ? !identical(a, b) : a != b) return false;
    }
    return true;
  }

  static void _collect(ContainerLayer parent, Set<Layer> boundaries, List<Object?> out) {
    for (Layer? layer = parent.firstChild; layer != null; layer = layer.nextSibling) {
      out.add(layer);
      if (boundaries.contains(layer)) {
        // A child boundary: only where and how it is composited matters here.
        out.add((layer as OffsetLayer).offset);
        if (layer is OpacityLayer) out.add(layer.alpha);
        continue;
      }
      switch (layer) {
        case TransformLayer():
          out
            ..add(layer.transform)
            ..add(layer.offset);
        case OpacityLayer():
          out
            ..add(layer.alpha)
            ..add(layer.offset);
        case ImageFilterLayer():
          out
            ..add(layer.imageFilter)
            ..add(layer.offset);
        case OffsetLayer():
          out.add(layer.offset);
        case ClipRectLayer():
          out
            ..add(layer.clipRect)
            ..add(layer.clipBehavior);
        case ClipRRectLayer():
          out
            ..add(layer.clipRRect)
            ..add(layer.clipBehavior);
        case ClipRSuperellipseLayer():
          out
            ..add(layer.clipRSuperellipse)
            ..add(layer.clipBehavior);
        case ClipPathLayer():
          out
            ..add(layer.clipPath)
            ..add(layer.clipBehavior);
        case ColorFilterLayer():
          out.add(layer.colorFilter);
        case BackdropFilterLayer():
          out
            ..add(layer.filter)
            ..add(layer.blendMode);
        case ShaderMaskLayer():
          out
            ..add(layer.shader)
            ..add(layer.maskRect)
            ..add(layer.blendMode);
        case LeaderLayer():
          out
            ..add(layer.offset)
            ..add(layer.link);
        case FollowerLayer():
          // Positioned at composite time from its leader.
          out
            ..add(layer.getLastTransform())
            ..add(layer.unlinkedOffset);
        case TextureLayer():
          out
            ..add(layer.rect)
            ..add(layer.textureId);
        case PlatformViewLayer():
          out
            ..add(layer.rect)
            ..add(layer.viewId);
        default:
          break;
      }
      if (layer is ContainerLayer) _collect(layer, boundaries, out);
    }
  }
}
