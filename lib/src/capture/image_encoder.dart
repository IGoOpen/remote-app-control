import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../protocol/byte_buffer.dart';
import '../protocol/wire.dart';
import 'image_registry.dart';
import 'jpeg_encoder.dart';

/// Images below this many pixels stay PNG; JPEG only pays off for larger ones.
const int _jpegMinPixels = 64 * 64;
const int _jpegQuality = 80;

/// Encodes [pending] into an `image` message: `varuint id`,
/// `varuint originalWidth`, `varuint originalHeight`, then PNG or JPEG bytes.
///
/// The original size lets viewers map source rectangles when the image was
/// downscaled. Disposes the pending image.
Future<Uint8List?> encodeImageMessage(PendingImage pending) async {
  final original = pending.image;
  final width = original.width;
  final height = original.height;
  ui.Image? scaled;
  try {
    var target = original;
    // Leave a margin so small layout changes do not force a re-upload.
    final scale = math.min(1.0, pending.scale * 1.25);
    if (scale < 0.8) {
      final w = math.max(1, (width * scale).round());
      final h = math.max(1, (height * scale).round());
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawImageRect(
        original,
        ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.medium,
      );
      final picture = recorder.endRecording();
      scaled = picture.toImageSync(w, h);
      picture.dispose();
      target = scaled;
    }

    final Uint8List encoded;
    final raw = await target.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (raw == null) return null;
    final rgba = raw.buffer.asUint8List(raw.offsetInBytes, raw.lengthInBytes);
    if (target.width * target.height >= _jpegMinPixels && _isOpaque(rgba)) {
      encoded = await compute(encodeJpegJob, JpegJob(rgba, target.width, target.height, _jpegQuality));
    } else {
      final png = await target.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) return null;
      encoded = png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
    }

    return (ByteWriter(encoded.length + 16)
          ..u8(MessageType.image)
          ..varUint(pending.id)
          ..varUint(width)
          ..varUint(height)
          ..bytes(encoded))
        .takeBytes();
  } finally {
    scaled?.dispose();
    original.dispose();
  }
}

bool _isOpaque(Uint8List rgba) {
  for (var i = 3; i < rgba.length; i += 4) {
    if (rgba[i] != 255) return false;
  }
  return true;
}
