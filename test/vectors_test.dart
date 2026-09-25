// Records a known screen into test vectors used by the other protocol
// implementations (see js/test). Regenerate with:
//
//   flutter test test/vectors_test.dart --dart-define=UPDATE_VECTORS=true

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_app_control/remote_app_control.dart';
import 'package:remote_app_control/src/capture/capture_context.dart';
import 'package:remote_app_control/src/capture/chunk_cache.dart';
import 'package:remote_app_control/src/capture/image_encoder.dart';
import 'package:remote_app_control/src/capture/image_registry.dart';
import 'package:remote_app_control/src/capture/recording_canvas.dart';
import 'package:remote_app_control/src/capture/style_registry.dart';
import 'package:remote_app_control/src/capture/text_layout.dart';
import 'package:remote_app_control/src/host/frame_capturer.dart';
import 'package:remote_app_control/src/protocol/wire.dart';

const _update = bool.fromEnvironment('UPDATE_VECTORS');
const _dir = 'js/test/vectors';

class _VectorApp extends StatelessWidget {
  const _VectorApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        appBar: AppBar(title: const Text('Vector screen')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              height: 60,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                gradient: const LinearGradient(colors: [Colors.teal, Colors.indigo]),
              ),
            ),
            const Card(
              child: ListTile(leading: Icon(Icons.star), title: Text('Hello remote')),
            ),
            const Opacity(opacity: 0.5, child: Text('Half transparent')),
            const Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: 'Rich '),
                  TextSpan(
                    text: 'bold',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  TextSpan(
                    text: ' underlined',
                    style: TextStyle(decoration: TextDecoration.underline),
                  ),
                ],
              ),
            ),
            const Text('שלום עולם', textDirection: TextDirection.rtl),
            const SizedBox(
              width: 120,
              child: Text('An ellipsized line of text', maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const RemoteMask(child: Text('4111 1111 1111 1111')),
            const Divider(),
            const CircularProgressIndicator(value: 0.6),
          ],
        ),
      ),
    );
  }
}

void main() {
  testWidgets('writes protocol test vectors', (tester) async {
    tester.view
      ..devicePixelRatio = 2
      ..physicalSize = const Size(720, 1280);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const _VectorApp());

    final view = tester.binding.renderViews.first;
    final images = ImageRegistry();
    final styles = StyleRegistry();
    final chunks = ChunkCache()..beginFrame();
    final canvas = RecordingCanvas(
      bounds: Offset.zero & view.size,
      devicePixelRatio: 2,
      images: images,
      rasterCache: RasterCache(),
      textLayout: TextLayoutEncoder(styles),
    );
    final root = CaptureContext.record(view, canvas, chunks);
    expect(root, isNotNull);
    chunks.endFrame();

    final messages = <Uint8List>[
      styles.takePending(MessageType.styles)!,
      FrameCapturer.encodeFrame(FrameFlag.keyframe, view.size, root!, chunks.live, const []),
    ];
    await tester.runAsync(() async {
      for (final pending in images.takePending()) {
        final message = await encodeImageMessage(pending);
        if (message != null) messages.add(message);
      }
    });

    final out = BytesBuilder();
    for (final m in messages) {
      out
        ..add((ByteData(4)..setUint32(0, m.length, Endian.little)).buffer.asUint8List())
        ..add(m);
    }
    final expected = {
      'size': [view.size.width, view.size.height],
      'texts': ['Vector screen', 'Hello remote', 'Half transparent', 'Rich', 'bold', 'שלום עולם'],
      'hidden': ['4111'],
      'images': messages.where((m) => m[0] == MessageType.image).length,
    };

    if (_update) {
      Directory(_dir).createSync(recursive: true);
      File('$_dir/material_screen.bin').writeAsBytesSync(out.takeBytes());
      File('$_dir/material_screen.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(expected));
    } else {
      expect(messages.first[0], MessageType.styles);
      expect(chunks.live, isNotEmpty);
    }
  });
}
