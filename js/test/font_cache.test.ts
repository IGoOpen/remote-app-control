import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { test } from 'node:test';

import { MemoryFontCache, sha256Hex } from '../src/font_cache.ts';
import { MessageType } from '../src/protocol.ts';
import { ByteReader, ByteWriter } from '../src/reader.ts';
import { Resources } from '../src/resources.ts';

// Node has WebCrypto but no FontFace; record registrations instead.
const registered: string[] = [];
Object.assign(globalThis, {
  FontFace: class {
    family: string;
    constructor(family: string) {
      this.family = family;
    }
    async load() {}
  },
  document: { fonts: { add: (face: { family: string }) => registered.push(face.family) } },
});

const font = new Uint8Array(4096).map((_, i) => (i * 31) & 0xff);
const hash = new Uint8Array(createHash('sha256').update(font).digest());

function offer(): ByteReader {
  const bytes = new ByteWriter()
    .u8(MessageType.fontOffer)
    .string('Brand')
    .string('0123456789abcdef')
    .u16(400)
    .u8(0)
    .bytes(hash)
    .varUint(font.length)
    .finish();
  return new ByteReader(bytes, 1);
}

function fontMessage(content: Uint8Array): ByteReader {
  return new ByteReader(new ByteWriter().u8(MessageType.font).bytes(hash).bytes(content).finish(), 1);
}

test('sha256Hex matches node crypto', async () => {
  assert.equal(await sha256Hex(font), createHash('sha256').update(font).digest('hex'));
});

test('fonts are requested once, verified, cached and reused', async () => {
  const fontCache = new MemoryFontCache();

  const first = new Resources({ fontCache });
  const missing = await first.addFontOffer(offer());
  assert.deepEqual(missing, hash, 'uncached font is requested');

  const tampered = font.slice();
  tampered[10] ^= 0xff;
  await first.addFont(fontMessage(tampered));
  assert.equal(await fontCache.get(await sha256Hex(font) as string), undefined, 'tampered file is not cached');
  assert.equal(registered.length, 0);

  await first.addFont(fontMessage(font));
  assert.deepEqual(await fontCache.get(await sha256Hex(font) as string), font);
  assert.deepEqual(registered, ['rac-0123456789abcdef']);

  // A later session on the same page needs nothing.
  const second = new Resources({ fontCache });
  assert.equal(await second.addFontOffer(offer()), null);
  assert.equal(registered.length, 1, 'already registered faces are reused');
});
