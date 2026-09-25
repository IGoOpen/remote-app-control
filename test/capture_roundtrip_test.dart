import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_app_control/remote_app_control.dart';
import 'package:remote_app_control/src/capture/jpeg_encoder.dart';
import 'package:remote_app_control/src/protocol/wire.dart';

import 'support/recorder.dart';

void main() {
  testWidgets('records a Material app, masking private content', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('Title')),
          body: ListView(
            children: [
              const ListTile(leading: Icon(Icons.star), title: Text('Hello remote')),
              Opacity(
                opacity: 0.5,
                child: ElevatedButton(onPressed: () {}, child: const Text('Button')),
              ),
              Container(
                height: 40,
                decoration: const BoxDecoration(gradient: LinearGradient(colors: [Colors.red, Colors.blue])),
              ),
              const RemoteMask(child: Text('4111 1111 1111 1111')),
              const TextField(obscureText: true),
            ],
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'secret');
    await tester.pump();

    final recorder = TestRecorder()..capture(tester);
    final bytes = recorder.allBytes;
    final text = String.fromCharCodes(bytes);
    expect(text, contains('Hello remote'));
    expect(text, isNot(contains('4111')));
    expect(text, isNot(contains('secret')));
    expect(bytes, contains(Op.placeholder));
    // The gradient is rasterized into an image.
    expect(recorder.pendingImages, isNotEmpty);

    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('replayed text matches the original rendering', (tester) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(400, 300);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: ColoredBox(
          color: Colors.white,
          child: Padding(
            padding: EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Plain text that wraps onto a second line in this box',
                  style: TextStyle(fontSize: 16, color: Colors.black),
                ),
                Text.rich(
                  TextSpan(
                    style: TextStyle(fontSize: 14, color: Colors.black),
                    children: [
                      TextSpan(text: 'Mixed '),
                      TextSpan(
                        text: 'bold',
                        style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red),
                      ),
                      TextSpan(text: ' and '),
                      TextSpan(
                        text: 'big',
                        style: TextStyle(fontSize: 24, color: Colors.blue),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 150,
                  child: Text(
                    'Ellipsized text that is far too long',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, color: Colors.black),
                  ),
                ),
                SizedBox(
                  width: 200,
                  child: Text(
                    'Right aligned',
                    textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 14, color: Colors.black),
                  ),
                ),
                Text(
                  'שלום עולם',
                  textDirection: TextDirection.rtl,
                  style: TextStyle(fontSize: 14, color: Colors.black),
                ),
                // Opacity is applied by a composited layer, not in paint().
                Opacity(
                  opacity: 0.4,
                  child: SizedBox(width: 120, height: 30, child: ColoredBox(color: Colors.red)),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final recorder = TestRecorder()..capture(tester);
    final diff = await recorder.difference(tester);
    expect(diff, lessThan(0.005), reason: '${(diff * 100).toStringAsFixed(2)}% of pixels differ');
  });

  test('JPEG encoder output decodes close to the source', () async {
    const w = 67, h = 45; // Not a multiple of the 16px block size.
    final rgba = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = (y * w + x) * 4;
        rgba[i] = x * 255 ~/ w;
        rgba[i + 1] = y * 255 ~/ h;
        rgba[i + 2] = 128 + ((x - y) * 2).clamp(-100, 100);
        rgba[i + 3] = 255;
      }
    }
    final jpeg = encodeJpeg(rgba, w, h, quality: 90);
    expect(jpeg.sublist(0, 2), [0xFF, 0xD8]);

    final codec = await ui.instantiateImageCodec(jpeg);
    final image = (await codec.getNextFrame()).image;
    expect((image.width, image.height), (w, h));
    final decoded = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    var error = 0;
    for (var i = 0; i < rgba.length; i += 4) {
      for (var c = 0; c < 3; c++) {
        error += (rgba[i + c] - decoded.getUint8(i + c)).abs();
      }
    }
    final meanError = error / (w * h * 3);
    expect(meanError, lessThan(3));
  });
}
