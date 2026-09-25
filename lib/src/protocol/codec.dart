import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'byte_buffer.dart';
import 'wire.dart';

/// Spacing between sampled points when a path's curves are flattened.
const double _pathSampleStep = 1.0;
const int _maxPointsPerContour = 2000;

/// Maximum distance, in logical pixels, a simplified path may deviate from
/// the original. Well below what is visible after anti-aliasing.
const double _pathTolerance = 0.2;

/// Paths reused across frames (cached by painters) are only flattened once.
final Expando<Uint8List> _encodedPaths = Expando('encoded path');

Float32List _flatten(ui.PathMetric metric) {
  final length = metric.length;
  final count = (length / _pathSampleStep).ceil().clamp(1, _maxPointsPerContour);
  final xs = Float64List(count + 1);
  final ys = Float64List(count + 1);
  for (var i = 0; i <= count; i++) {
    final position = metric.getTangentForOffset(length * i / count)?.position ?? Offset.zero;
    xs[i] = position.dx;
    ys[i] = position.dy;
  }
  final keep = _simplify(xs, ys, _pathTolerance);
  final out = Float32List(keep.length * 2);
  for (var i = 0; i < keep.length; i++) {
    out[i * 2] = xs[keep[i]];
    out[i * 2 + 1] = ys[keep[i]];
  }
  return out;
}

/// Ramer-Douglas-Peucker, iterative. Returns the indices of points to keep.
List<int> _simplify(Float64List xs, Float64List ys, double tolerance) {
  final n = xs.length;
  if (n <= 2) return List.generate(n, (i) => i);
  final keep = List.filled(n, false);
  keep[0] = keep[n - 1] = true;
  final stack = <(int, int)>[(0, n - 1)];
  final tolerance2 = tolerance * tolerance;
  while (stack.isNotEmpty) {
    final (start, end) = stack.removeLast();
    final dx = xs[end] - xs[start];
    final dy = ys[end] - ys[start];
    final lengthSquared = dx * dx + dy * dy;
    var maxDistance = 0.0;
    var index = -1;
    for (var i = start + 1; i < end; i++) {
      final px = xs[i] - xs[start];
      final py = ys[i] - ys[start];
      final double distance;
      if (lengthSquared == 0) {
        distance = px * px + py * py;
      } else {
        final cross = px * dy - py * dx;
        distance = cross * cross / lengthSquared;
      }
      if (distance > maxDistance) {
        maxDistance = distance;
        index = i;
      }
    }
    if (index != -1 && maxDistance > tolerance2) {
      keep[index] = true;
      stack
        ..add((start, index))
        ..add((index, end));
    }
  }
  return [
    for (var i = 0; i < n; i++)
      if (keep[i]) i,
  ];
}

extension GeometryWriter on ByteWriter {
  void point(Offset o) {
    f32(o.dx);
    f32(o.dy);
  }

  void rect(Rect r) {
    f32(r.left);
    f32(r.top);
    f32(r.right);
    f32(r.bottom);
  }

  void rrect(RRect r) => _rrectLike(
    r.left,
    r.top,
    r.right,
    r.bottom, //
    r.tlRadiusX,
    r.tlRadiusY,
    r.trRadiusX,
    r.trRadiusY,
    r.brRadiusX,
    r.brRadiusY,
    r.blRadiusX,
    r.blRadiusY,
  );

  void rsuperellipse(RSuperellipse r) => _rrectLike(
    r.left,
    r.top,
    r.right,
    r.bottom, //
    r.tlRadiusX,
    r.tlRadiusY,
    r.trRadiusX,
    r.trRadiusY,
    r.brRadiusX,
    r.brRadiusY,
    r.blRadiusX,
    r.blRadiusY,
  );

  void _rrectLike(
    double a,
    double b,
    double c,
    double d,
    double e,
    double f,
    double g,
    double h,
    double i,
    double j,
    double k,
    double l,
  ) {
    for (final v in [a, b, c, d, e, f, g, h, i, j, k, l]) {
      f32(v);
    }
  }

  void color(Color c) => u32(c.toARGB32());

  /// Paths are opaque in `dart:ui`, so they are flattened into polylines and
  /// simplified; a rounded rectangle ends up as a few dozen points.
  void path(Path p) {
    final cached = _encodedPaths[p];
    if (cached != null) return bytes(cached);
    final w = ByteWriter(256)..u8(p.fillType.index);
    final contours = [for (final metric in p.computeMetrics()) (metric.isClosed, _flatten(metric))];
    w.varUint(contours.length);
    for (final (closed, points) in contours) {
      w
        ..boolean(closed)
        ..float32List(points);
    }
    final encoded = w.takeBytes();
    _encodedPaths[p] = encoded;
    bytes(encoded);
  }

  /// Writes the serializable parts of [p]. Shaders and color or image
  /// filters are not representable and must be handled by the caller.
  void paint(Paint p, {MaskFilterInfo? blur}) {
    color(p.color);
    var flags = 0;
    if (p.style == PaintingStyle.stroke) flags |= PaintFlag.stroke;
    if (!p.isAntiAlias) flags |= PaintFlag.noAntiAlias;
    final hasStroke =
        p.style == PaintingStyle.stroke &&
        (p.strokeWidth != 0 || p.strokeCap != StrokeCap.butt || p.strokeJoin != StrokeJoin.miter);
    if (hasStroke) flags |= PaintFlag.strokeDetails;
    if (p.blendMode != BlendMode.srcOver) flags |= PaintFlag.blendMode;
    if (blur != null) flags |= PaintFlag.blur;
    if (p.filterQuality != FilterQuality.none) flags |= PaintFlag.filterQuality;
    if (p.invertColors) flags |= PaintFlag.invertColors;
    u8(flags);
    if (hasStroke) {
      f32(p.strokeWidth);
      u8(p.strokeCap.index);
      u8(p.strokeJoin.index);
      f32(p.strokeMiterLimit);
    }
    if (flags & PaintFlag.blendMode != 0) u8(p.blendMode.index);
    if (blur != null) {
      u8(blur.style.index);
      f32(blur.sigma);
    }
    if (flags & PaintFlag.filterQuality != 0) u8(p.filterQuality.index);
  }
}

/// `MaskFilter` has no public getters; its `toString` is the only way in.
class MaskFilterInfo {
  const MaskFilterInfo(this.style, this.sigma);

  final BlurStyle style;
  final double sigma;

  static final RegExp _pattern = RegExp(r'MaskFilter\.blur\(BlurStyle\.(\w+), ([\d.]+)\)');

  static MaskFilterInfo? parse(MaskFilter? filter) {
    if (filter == null) return null;
    final match = _pattern.firstMatch(filter.toString());
    if (match == null) return null;
    final style = BlurStyle.values.asNameMap()[match.group(1)];
    final sigma = double.tryParse(match.group(2)!);
    if (style == null || sigma == null) return null;
    return MaskFilterInfo(style, sigma);
  }
}

extension GeometryReader on ByteReader {
  Offset point() => Offset(f32(), f32());

  Rect rect() => Rect.fromLTRB(f32(), f32(), f32(), f32());

  RRect rrect() {
    final l = f32(), t = f32(), r = f32(), b = f32();
    return RRect.fromLTRBAndCorners(
      l,
      t,
      r,
      b,
      topLeft: Radius.elliptical(f32(), f32()),
      topRight: Radius.elliptical(f32(), f32()),
      bottomRight: Radius.elliptical(f32(), f32()),
      bottomLeft: Radius.elliptical(f32(), f32()),
    );
  }

  RSuperellipse rsuperellipse() {
    final l = f32(), t = f32(), r = f32(), b = f32();
    return RSuperellipse.fromLTRBAndCorners(
      l,
      t,
      r,
      b,
      topLeft: Radius.elliptical(f32(), f32()),
      topRight: Radius.elliptical(f32(), f32()),
      bottomRight: Radius.elliptical(f32(), f32()),
      bottomLeft: Radius.elliptical(f32(), f32()),
    );
  }

  Color color() => Color(u32());

  Path path() {
    final path = Path()..fillType = PathFillType.values[u8()];
    final contours = varUint();
    for (var c = 0; c < contours; c++) {
      final closed = boolean();
      final points = float32List();
      if (points.length < 2) continue;
      path.moveTo(points[0], points[1]);
      for (var i = 2; i < points.length; i += 2) {
        path.lineTo(points[i], points[i + 1]);
      }
      if (closed) path.close();
    }
    return path;
  }

  Paint paint() {
    final p = Paint()..color = color();
    final flags = u8();
    if (flags & PaintFlag.stroke != 0) p.style = PaintingStyle.stroke;
    if (flags & PaintFlag.noAntiAlias != 0) p.isAntiAlias = false;
    if (flags & PaintFlag.strokeDetails != 0) {
      p
        ..strokeWidth = f32()
        ..strokeCap = StrokeCap.values[u8()]
        ..strokeJoin = StrokeJoin.values[u8()]
        ..strokeMiterLimit = f32();
    }
    if (flags & PaintFlag.blendMode != 0) p.blendMode = BlendMode.values[u8()];
    if (flags & PaintFlag.blur != 0) {
      p.maskFilter = MaskFilter.blur(BlurStyle.values[u8()], f32());
    }
    if (flags & PaintFlag.filterQuality != 0) {
      p.filterQuality = FilterQuality.values[u8()];
    }
    if (flags & PaintFlag.invertColors != 0) p.invertColors = true;
    return p;
  }
}
