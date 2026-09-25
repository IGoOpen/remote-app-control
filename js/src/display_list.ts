import { Op, PaintFlag, RunFlag } from './protocol.ts';
import { ByteReader } from './reader.ts';

export interface Rect {
  left: number;
  top: number;
  right: number;
  bottom: number;
}

/** A rounded rectangle; radii are elliptical, clockwise from top-left. */
export interface RRect extends Rect {
  radii: Float32Array; // tlx, tly, trx, try, brx, bry, blx, bly
}

export interface PathData {
  /** 0 nonzero, 1 even-odd. */
  fillType: number;
  contours: { closed: boolean; points: Float32Array }[];
}

/**
 * A decoded paint. The decoder reuses one instance, so sinks must not keep
 * a reference after the call returns.
 */
export interface Paint {
  /** ARGB, 32 bits. */
  color: number;
  stroke: boolean;
  antiAlias: boolean;
  strokeWidth: number;
  /** 0 butt, 1 round, 2 square. */
  strokeCap: number;
  /** 0 miter, 1 round, 2 bevel. */
  strokeJoin: number;
  strokeMiterLimit: number;
  /** Index into {@link BlendMode}; 3 is srcOver. */
  blendMode: number;
  /** 0 when there is no blur. */
  blurSigma: number;
  /** 0 normal, 1 solid, 2 outer, 3 inner. */
  blurStyle: number;
  /** 0 none, 1 low, 2 medium, 3 high. */
  filterQuality: number;
  invertColors: boolean;
}

export interface TextRun {
  style: number;
  text: string;
  /** Box and baseline are absolute, in the frame's logical coordinates. */
  box: Rect;
  baseline: number;
  rtl: boolean;
}

/** Receives display list operations in order. */
export interface DisplayListSink {
  save(): void;
  saveLayer(bounds: Rect | null, paint: Paint): void;
  restore(): void;
  translate(dx: number, dy: number): void;
  scale(sx: number, sy: number): void;
  rotate(radians: number): void;
  skew(sx: number, sy: number): void;
  /** Column-major 4x4 matrix. */
  transform(matrix: Float32Array): void;
  clipRect(rect: Rect, difference: boolean, antiAlias: boolean): void;
  clipRRect(rrect: RRect, antiAlias: boolean): void;
  clipRSuperellipse(rrect: RRect, antiAlias: boolean): void;
  clipPath(path: PathData, antiAlias: boolean): void;
  drawColor(color: number, blendMode: number): void;
  drawLine(x1: number, y1: number, x2: number, y2: number, paint: Paint): void;
  drawPaint(paint: Paint): void;
  drawRect(rect: Rect, paint: Paint): void;
  drawRRect(rrect: RRect, paint: Paint): void;
  drawDRRect(outer: RRect, inner: RRect, paint: Paint): void;
  drawRSuperellipse(rrect: RRect, paint: Paint): void;
  drawOval(rect: Rect, paint: Paint): void;
  drawCircle(cx: number, cy: number, radius: number, paint: Paint): void;
  drawArc(rect: Rect, start: number, sweep: number, useCenter: boolean, paint: Paint): void;
  drawPath(path: PathData, paint: Paint): void;
  /** `src` is in the image's original pixel coordinates. */
  drawImageRect(imageId: number, src: Rect, dst: Rect, paint: Paint): void;
  drawImageNine(imageId: number, center: Rect, dst: Rect, paint: Paint): void;
  /** Mode 0 points, 1 lines, 2 polygon; points are x, y pairs. */
  drawPoints(mode: number, points: Float32Array, paint: Paint): void;
  drawShadow(path: PathData, color: number, elevation: number, transparentOccluder: boolean): void;
  drawText(runs: TextRun[]): void;
  placeholder(rect: Rect, kind: number): void;
  /**
   * Draws another chunk (a retained part of the screen) with its origin at
   * ([dx], [dy]). Sinks usually decode it recursively.
   */
  drawChunk(id: number, dx: number, dy: number): void;
}

const paint: Paint = {
  color: 0,
  stroke: false,
  antiAlias: true,
  strokeWidth: 0,
  strokeCap: 0,
  strokeJoin: 0,
  strokeMiterLimit: 4,
  blendMode: 3,
  blurSigma: 0,
  blurStyle: 0,
  filterQuality: 0,
  invertColors: false,
};

function readPaint(r: ByteReader): Paint {
  paint.color = r.u32();
  const flags = r.u8();
  paint.stroke = (flags & PaintFlag.stroke) !== 0;
  paint.antiAlias = (flags & PaintFlag.noAntiAlias) === 0;
  paint.strokeWidth = 0;
  paint.strokeCap = 0;
  paint.strokeJoin = 0;
  paint.strokeMiterLimit = 4;
  if (flags & PaintFlag.strokeDetails) {
    paint.strokeWidth = r.f32();
    paint.strokeCap = r.u8();
    paint.strokeJoin = r.u8();
    paint.strokeMiterLimit = r.f32();
  }
  paint.blendMode = flags & PaintFlag.blendMode ? r.u8() : 3;
  paint.blurSigma = 0;
  paint.blurStyle = 0;
  if (flags & PaintFlag.blur) {
    paint.blurStyle = r.u8();
    paint.blurSigma = r.f32();
  }
  paint.filterQuality = flags & PaintFlag.filterQuality ? r.u8() : 0;
  paint.invertColors = (flags & PaintFlag.invertColors) !== 0;
  return paint;
}

function readRect(r: ByteReader): Rect {
  return { left: r.f32(), top: r.f32(), right: r.f32(), bottom: r.f32() };
}

function readRRect(r: ByteReader): RRect {
  const rect = readRect(r) as RRect;
  const radii = new Float32Array(8);
  for (let i = 0; i < 8; i++) radii[i] = r.f32();
  rect.radii = radii;
  return rect;
}

function readPath(r: ByteReader): PathData {
  const fillType = r.u8();
  const count = r.varUint();
  const contours = new Array<{ closed: boolean; points: Float32Array }>(count);
  for (let i = 0; i < count; i++) {
    const closed = r.bool();
    contours[i] = { closed, points: r.float32List() };
  }
  return { fillType, contours };
}

function readRuns(r: ByteReader): TextRun[] {
  const ox = r.f32();
  const oy = r.f32();
  const count = r.varUint();
  const runs = new Array<TextRun>(count);
  for (let i = 0; i < count; i++) {
    const style = r.varUint();
    const text = r.string();
    const box = readRect(r);
    box.left += ox;
    box.right += ox;
    box.top += oy;
    box.bottom += oy;
    const baseline = r.f32() + oy;
    const rtl = (r.u8() & RunFlag.rtl) !== 0;
    runs[i] = { style, text, box, baseline, rtl };
  }
  return runs;
}

/** Decodes a frame's display list, calling [sink] for each operation. */
export function decodeDisplayList(ops: Uint8Array, sink: DisplayListSink): void {
  const r = new ByteReader(ops);
  while (r.hasMore) {
    const op = r.u8();
    switch (op) {
      case Op.save:
        sink.save();
        break;
      case Op.saveLayer: {
        const bounds = r.bool() ? readRect(r) : null;
        sink.saveLayer(bounds, readPaint(r));
        break;
      }
      case Op.restore:
        sink.restore();
        break;
      case Op.translate:
        sink.translate(r.f32(), r.f32());
        break;
      case Op.scale:
        sink.scale(r.f32(), r.f32());
        break;
      case Op.rotate:
        sink.rotate(r.f32());
        break;
      case Op.skew:
        sink.skew(r.f32(), r.f32());
        break;
      case Op.transform: {
        const m = new Float32Array(16);
        for (let i = 0; i < 16; i++) m[i] = r.f32();
        sink.transform(m);
        break;
      }
      case Op.clipRect: {
        const rect = readRect(r);
        sink.clipRect(rect, r.u8() === 0, r.bool());
        break;
      }
      case Op.clipRRect:
        sink.clipRRect(readRRect(r), r.bool());
        break;
      case Op.clipRSuperellipse:
        sink.clipRSuperellipse(readRRect(r), r.bool());
        break;
      case Op.clipPath:
        sink.clipPath(readPath(r), r.bool());
        break;
      case Op.drawColor:
        sink.drawColor(r.u32(), r.u8());
        break;
      case Op.drawLine:
        sink.drawLine(r.f32(), r.f32(), r.f32(), r.f32(), readPaint(r));
        break;
      case Op.drawPaint:
        sink.drawPaint(readPaint(r));
        break;
      case Op.drawRect:
        sink.drawRect(readRect(r), readPaint(r));
        break;
      case Op.drawRRect:
        sink.drawRRect(readRRect(r), readPaint(r));
        break;
      case Op.drawDRRect:
        sink.drawDRRect(readRRect(r), readRRect(r), readPaint(r));
        break;
      case Op.drawRSuperellipse:
        sink.drawRSuperellipse(readRRect(r), readPaint(r));
        break;
      case Op.drawOval:
        sink.drawOval(readRect(r), readPaint(r));
        break;
      case Op.drawCircle:
        sink.drawCircle(r.f32(), r.f32(), r.f32(), readPaint(r));
        break;
      case Op.drawArc:
        sink.drawArc(readRect(r), r.f32(), r.f32(), r.bool(), readPaint(r));
        break;
      case Op.drawPath:
        sink.drawPath(readPath(r), readPaint(r));
        break;
      case Op.drawImageRect:
        sink.drawImageRect(r.varUint(), readRect(r), readRect(r), readPaint(r));
        break;
      case Op.drawImageNine:
        sink.drawImageNine(r.varUint(), readRect(r), readRect(r), readPaint(r));
        break;
      case Op.drawPoints:
        sink.drawPoints(r.u8(), r.float32List(), readPaint(r));
        break;
      case Op.drawShadow:
        sink.drawShadow(readPath(r), r.u32(), r.f32(), r.bool());
        break;
      case Op.drawText:
        sink.drawText(readRuns(r));
        break;
      case Op.placeholder:
        sink.placeholder(readRect(r), r.u8());
        break;
      case Op.drawChunk:
        sink.drawChunk(r.varUint(), r.f32(), r.f32());
        break;
      default:
        throw new Error(`Unknown display list op 0x${op.toString(16)} at ${r.offset - 1}`);
    }
  }
}
