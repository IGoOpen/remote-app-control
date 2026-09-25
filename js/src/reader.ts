const utf8 = new TextDecoder();

/** Little-endian reader over one wire message. */
export class ByteReader {
  readonly bytes: Uint8Array;
  offset: number;
  private readonly view: DataView;

  constructor(bytes: Uint8Array, offset = 0) {
    this.bytes = bytes;
    this.offset = offset;
    this.view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  }

  get hasMore(): boolean {
    return this.offset < this.bytes.length;
  }

  u8(): number {
    return this.bytes[this.offset++];
  }

  bool(): boolean {
    return this.bytes[this.offset++] !== 0;
  }

  u16(): number {
    const v = this.view.getUint16(this.offset, true);
    this.offset += 2;
    return v;
  }

  u32(): number {
    const v = this.view.getUint32(this.offset, true);
    this.offset += 4;
    return v;
  }

  f32(): number {
    const v = this.view.getFloat32(this.offset, true);
    this.offset += 4;
    return v;
  }

  /** Unsigned LEB128. */
  varUint(): number {
    let result = 0;
    let shift = 0;
    for (;;) {
      const b = this.bytes[this.offset++];
      result += (b & 0x7f) * 2 ** shift;
      if (b < 0x80) return result;
      shift += 7;
    }
  }

  take(length: number): Uint8Array {
    const v = this.bytes.subarray(this.offset, this.offset + length);
    this.offset += length;
    return v;
  }

  rest(): Uint8Array {
    return this.take(this.bytes.length - this.offset);
  }

  string(): string {
    return utf8.decode(this.take(this.varUint()));
  }

  float32List(): Float32Array {
    const n = this.varUint();
    const out = new Float32Array(n);
    for (let i = 0; i < n; i++) out[i] = this.f32();
    return out;
  }

  json<T>(): T {
    return JSON.parse(utf8.decode(this.rest())) as T;
  }
}

/** Growable little-endian writer for outgoing messages. */
export class ByteWriter {
  private buffer = new Uint8Array(64);
  private view = new DataView(this.buffer.buffer);
  private length = 0;

  private ensure(extra: number): void {
    if (this.length + extra <= this.buffer.length) return;
    const next = new Uint8Array(Math.max(this.buffer.length * 2, this.length + extra));
    next.set(this.buffer.subarray(0, this.length));
    this.buffer = next;
    this.view = new DataView(next.buffer);
  }

  u8(v: number): this {
    this.ensure(1);
    this.buffer[this.length++] = v;
    return this;
  }

  u16(v: number): this {
    this.ensure(2);
    this.view.setUint16(this.length, v, true);
    this.length += 2;
    return this;
  }

  bytes(v: Uint8Array): this {
    this.ensure(v.length);
    this.buffer.set(v, this.length);
    this.length += v.length;
    return this;
  }

  f32(v: number): this {
    this.ensure(4);
    this.view.setFloat32(this.length, v, true);
    this.length += 4;
    return this;
  }

  varUint(v: number): this {
    while (v >= 0x80) {
      this.u8((v & 0x7f) | 0x80);
      v = Math.floor(v / 128);
    }
    return this.u8(v);
  }

  string(v: string): this {
    const encoded = new TextEncoder().encode(v);
    this.varUint(encoded.length);
    this.ensure(encoded.length);
    this.buffer.set(encoded, this.length);
    this.length += encoded.length;
    return this;
  }

  finish(): Uint8Array {
    return this.buffer.slice(0, this.length);
  }
}
