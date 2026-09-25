import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { decodeDisplayList, type DisplayListSink, type TextRun } from '../src/display_list.ts';
import { FrameFlag, MessageType } from '../src/protocol.ts';
import { ByteReader, ByteWriter } from '../src/reader.ts';
import { Resources } from '../src/resources.ts';

const dir = new URL('./vectors/', import.meta.url);

function readMessages(name: string): Uint8Array[] {
  const bytes = new Uint8Array(readFileSync(new URL(name, dir)));
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const out: Uint8Array[] = [];
  for (let offset = 0; offset < bytes.length; ) {
    const length = view.getUint32(offset, true);
    out.push(bytes.subarray(offset + 4, offset + 4 + length));
    offset += 4 + length;
  }
  return out;
}

/** A sink that records what a renderer would be asked to draw. */
function recordingSink(chunks: Map<number, Uint8Array>) {
  const counts = new Map<string, number>();
  const runs: TextRun[] = [];
  const images: number[] = [];
  let depth = 0;
  const sink = new Proxy({} as DisplayListSink, {
    get(_, name: string) {
      return (...args: unknown[]) => {
        counts.set(name, (counts.get(name) ?? 0) + 1);
        if (name === 'save' || name === 'saveLayer') depth++;
        if (name === 'restore') depth--;
        if (name === 'drawText') runs.push(...(args[0] as TextRun[]));
        if (name === 'drawImageRect' || name === 'drawImageNine') images.push(args[0] as number);
        if (name === 'drawChunk') {
          const ops = chunks.get(args[0] as number);
          assert.ok(ops, `chunk ${args[0]} is defined`);
          decodeDisplayList(ops, sink);
        }
      };
    },
  });
  return { sink, counts, runs, images, depth: () => depth };
}

test('decodes the Material screen vector', () => {
  const expected = JSON.parse(readFileSync(new URL('material_screen.json', dir), 'utf8'));
  const messages = readMessages('material_screen.bin');
  const resources = new Resources();
  const imageIds = new Set<number>();
  const chunks = new Map<number, Uint8Array>();
  let root: number | null = null;
  let size: [number, number] = [0, 0];

  for (const message of messages) {
    const r = new ByteReader(message, 1);
    switch (message[0]) {
      case MessageType.styles:
        resources.addStyles(r);
        break;
      case MessageType.frame: {
        assert.equal(r.u8() & FrameFlag.keyframe, FrameFlag.keyframe);
        size = [r.f32(), r.f32()];
        root = r.varUint();
        for (let n = r.varUint(); n > 0; n--) {
          const id = r.varUint();
          chunks.set(id, r.take(r.varUint()));
        }
        assert.equal(r.varUint(), 0, 'a keyframe releases nothing');
        break;
      }
      case MessageType.image:
        imageIds.add(r.varUint());
        break;
    }
  }
  assert.ok(root !== null && chunks.has(root), 'vector contains a frame and its root chunk');
  assert.ok(chunks.size > 1, 'the screen is split into chunks');
  assert.deepEqual(size, expected.size);
  assert.equal(imageIds.size, expected.images);

  const { sink, counts, runs, images, depth } = recordingSink(chunks);
  decodeDisplayList(chunks.get(root!)!, sink);

  assert.equal(depth(), 0, 'saves and restores are balanced');
  assert.ok((counts.get('drawText') ?? 0) > 0);
  assert.ok((counts.get('placeholder') ?? 0) > 0, 'masked widget is a placeholder');

  const texts = runs.map((run) => run.text);
  for (const text of expected.texts) assert.ok(texts.includes(text), `missing run "${text}" in ${JSON.stringify(texts)}`);
  for (const hidden of expected.hidden) assert.ok(!texts.some((t) => t.includes(hidden)), `"${hidden}" leaked`);
  assert.ok(texts.some((t) => t.endsWith('…')), 'ellipsized run ends with an ellipsis');
  assert.ok(runs.some((run) => run.rtl), 'right-to-left run is flagged');

  for (const run of runs) {
    assert.ok(resources.styles.has(run.style), `style ${run.style} is defined`);
    assert.ok(run.box.right >= run.box.left && run.box.bottom > run.box.top);
    assert.ok(run.baseline > run.box.top && run.baseline <= run.box.bottom + 1);
  }
  for (const id of images) assert.ok(imageIds.has(id), `image ${id} was uploaded`);
});

test('byte writer and reader round-trip', () => {
  const bytes = new ByteWriter().u8(7).varUint(300).varUint(2 ** 35).f32(1.5).string('héllo').finish();
  const r = new ByteReader(bytes);
  assert.equal(r.u8(), 7);
  assert.equal(r.varUint(), 300);
  assert.equal(r.varUint(), 2 ** 35);
  assert.equal(r.f32(), 1.5);
  assert.equal(r.string(), 'héllo');
  assert.equal(r.hasMore, false);
});
