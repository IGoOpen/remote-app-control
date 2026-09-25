import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_app_control/src/capture/capture_context.dart';
import 'package:remote_app_control/src/capture/chunk_cache.dart';
import 'package:remote_app_control/src/capture/image_registry.dart';
import 'package:remote_app_control/src/capture/recording_canvas.dart';
import 'package:remote_app_control/src/capture/style_registry.dart';
import 'package:remote_app_control/src/capture/text_layout.dart';
import 'package:remote_app_control/src/protocol/byte_buffer.dart';
import 'package:remote_app_control/src/protocol/wire.dart';
import 'package:remote_app_control/viewer.dart';

/// Runs the host capture pipeline and applies its output to viewer-side
/// resources, frame after frame, like a session without the network.
class TestRecorder {
  final images = ImageRegistry();
  final styles = StyleRegistry();
  final rasterCache = RasterCache();
  final chunks = ChunkCache();
  late final textLayout = TextLayoutEncoder(styles);
  final resources = RemoteResources();
  final List<PendingImage> pendingImages = [];

  int? root;

  /// Bytes of chunk data the last capture would have sent.
  int bytesSent = 0;

  void capture(WidgetTester tester, {double devicePixelRatio = 1}) {
    final view = tester.binding.renderViews.first;
    final canvas = RecordingCanvas(
      bounds: Offset.zero & view.size,
      devicePixelRatio: devicePixelRatio,
      images: images,
      rasterCache: rasterCache,
      textLayout: textLayout,
    );
    chunks.beginFrame();
    root = CaptureContext.record(view, canvas, chunks);
    expect(root, isNotNull);
    final (changed, released) = chunks.endFrame();

    final stylesMessage = styles.takePending(MessageType.styles);
    if (stylesMessage != null) resources.addStyles(ByteReader(stylesMessage, 1));
    bytesSent = 0;
    for (final chunk in changed) {
      resources.chunks[chunk.id] = chunk.bytes;
      bytesSent += chunk.bytes.length;
    }
    released.forEach(resources.chunks.remove);
    pendingImages.addAll(images.takePending());
  }

  /// All chunk bytes reachable from the root, for content assertions.
  Uint8List get allBytes => Uint8List.fromList([for (final c in resources.chunks.values) ...c]);

  /// Fraction of pixels that differ between the live rendering and the
  /// replayed frame.
  Future<double> difference(WidgetTester tester) async {
    final view = tester.binding.renderViews.first;
    late double result;
    await tester.runAsync(() async {
      final layer = view.debugLayer! as OffsetLayer;
      final original = await layer.toImage(Offset.zero & view.size);

      final recorder = ui.PictureRecorder();
      DisplayListPlayer.play(ui.Canvas(recorder), resources.chunks[root]!, resources);
      final replay = await recorder.endRecording().toImage(original.width, original.height);

      result = differenceOf(await _pixels(original), await _pixels(replay));
    });
    return result;
  }
}

Future<ByteData> _pixels(ui.Image image) async => (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;

/// Fraction of pixels whose channels differ by more than [tolerance].
double differenceOf(ByteData a, ByteData b, {int tolerance = 48}) {
  var different = 0;
  final pixels = a.lengthInBytes ~/ 4;
  for (var i = 0; i < a.lengthInBytes; i += 4) {
    for (var c = 0; c < 3; c++) {
      if ((a.getUint8(i + c) - b.getUint8(i + c)).abs() > tolerance) {
        different++;
        break;
      }
    }
  }
  return different / pixels;
}
