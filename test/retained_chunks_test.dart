import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/recorder.dart';

class _Screen extends StatefulWidget {
  const _Screen();

  @override
  State<_Screen> createState() => _ScreenState();
}

class _ScreenState extends State<_Screen> {
  int counter = 0;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      // The banner's text is rasterized, and this harness does not upload images.
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        appBar: AppBar(title: Text('Counter $counter')),
        body: ListView.builder(
          itemCount: 100,
          itemBuilder: (context, i) => ListTile(
            leading: CircleAvatar(child: Text('$i')),
            title: Text('Item $i'),
            subtitle: const Text('Unchanged subtitle'),
          ),
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: () => setState(() => counter++),
          child: const Icon(Icons.add),
        ),
      ),
    );
  }
}

void main() {
  setUp(() {});

  testWidgets('an unchanged screen is not re-recorded', (tester) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(400, 700);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const _Screen());

    final recorder = TestRecorder()..capture(tester);
    final first = recorder.chunks.recorded;
    expect(first, greaterThan(5), reason: 'list items are separate chunks');

    recorder.capture(tester);
    expect(recorder.chunks.recorded, 0);
    expect(recorder.bytesSent, 0);
  });

  testWidgets('scrolling reuses every row that stays on screen', (tester) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(400, 700);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const _Screen());

    final recorder = TestRecorder()..capture(tester);
    final fullFrame = recorder.bytesSent;

    // The first scroll also repaints the app bar ("scrolled under" tint).
    await tester.drag(find.byType(ListView), const Offset(0, -150));
    await tester.pump();
    recorder.capture(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -150));
    await tester.pump();
    recorder.capture(tester);

    // Rows that scrolled in are new; the rows still visible are moved by
    // reference. The chunk holding the viewport is re-recorded because Flutter
    // repaints it too: the granularity is Flutter's own repaint boundaries.
    expect(recorder.chunks.reused, greaterThan(recorder.chunks.recorded * 2));
    expect(recorder.bytesSent, lessThan(fullFrame));
    expect(await recorder.difference(tester), lessThan(0.005));
  });

  testWidgets('a local change only re-records what changed', (tester) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(400, 700);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const _Screen());

    final recorder = TestRecorder()..capture(tester);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    recorder.capture(tester);

    expect(find.text('Counter 1'), findsOneWidget);
    expect(recorder.chunks.recorded, 1, reason: 'only the app bar repainted');
    expect(String.fromCharCodes(recorder.allBytes), contains('Counter 1'));
    expect(await recorder.difference(tester), lessThan(0.005));
  });
}
