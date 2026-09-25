import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_app_control/src/capture/font_registry.dart';
import 'package:remote_app_control/src/protocol/byte_buffer.dart';
import 'package:remote_app_control/src/protocol/wire.dart';
import 'package:remote_app_control/viewer.dart';

/// A real font from the Flutter SDK, so the engine accepts it.
Uint8List _robotoBytes() {
  final root = Platform.environment['FLUTTER_ROOT'];
  final file = File('$root/bin/cache/artifacts/material_fonts/roboto-regular.ttf');
  return file.readAsBytesSync();
}

class _FakeBundle extends CachingAssetBundle {
  _FakeBundle(this.assets);

  final Map<String, Uint8List> assets;

  @override
  Future<ByteData> load(String key) async {
    final bytes = assets[key];
    if (bytes == null) throw StateError('missing $key');
    return ByteData.sublistView(bytes);
  }
}

void main() {
  final font = _robotoBytes();
  final bundle = _FakeBundle({
    'FontManifest.json': utf8.encode(
      jsonEncode([
        {
          'family': 'Brand',
          'fonts': [
            {'asset': 'fonts/brand.ttf'},
          ],
        },
      ]),
    ),
    'fonts/brand.ttf': font,
  });

  testWidgets('host offers fonts by hash and serves them on request', (tester) async {
    await tester.runAsync(() async {
      final registry = FontRegistry(bundle: bundle);
      final offers = await registry.offersFor(['Brand', 'NotBundled']).toList();
      expect(offers, hasLength(1));

      final r = ByteReader(offers.single, 1);
      expect(offers.single[0], MessageType.fontOffer);
      expect(r.string(), 'Brand');
      expect(r.string(), hasLength(16));
      r
        ..u16()
        ..u8();
      final hash = r.bytes(32);
      expect(hash, sha256.convert(font).bytes);
      expect(r.varUint(), font.length);

      final message = await registry.fontFor(hash);
      expect(message![0], MessageType.font);
      expect(message.sublist(1, 33), hash);
      expect(message.sublist(33), font);

      expect(await registry.fontFor(Uint8List(32)), isNull);
      // A second offer in the same session is not repeated.
      expect(await registry.offersFor(['Brand']).toList(), isEmpty);
    });
  });

  testWidgets('viewer verifies, caches and reuses fonts', (tester) async {
    await tester.runAsync(() async {
      final registry = FontRegistry(bundle: bundle);
      final offer = (await registry.offersFor(['Brand']).toList()).single;
      final hash = offer.sublist(offer.length - 32 - 3, offer.length - 3);
      final cache = MemoryFontCache();

      // First session: nothing cached, so the viewer asks for the file.
      final first = RemoteResources(fontCache: cache);
      final missing = await first.addFontOffer(ByteReader(offer, 1));
      expect(missing, isNotNull);

      // A file that does not match its hash is rejected and not cached.
      final tampered =
          (ByteWriter()
                ..u8(MessageType.font)
                ..bytes(missing!)
                ..bytes(Uint8List.fromList(font)..[100] ^= 0xff))
              .takeBytes();
      await first.addFont(ByteReader(tampered, 1));
      expect(await cache.get(FontRegistry.hex(hash)), isNull);

      final response = (await registry.fontFor(missing))!;
      await first.addFont(ByteReader(response, 1));
      expect(await cache.get(FontRegistry.hex(hash)), font);

      // Later session, fresh process state aside: the cache answers.
      final second = RemoteResources(fontCache: cache);
      expect(await second.addFontOffer(ByteReader(offer, 1)), isNull);
    });
  });
}
