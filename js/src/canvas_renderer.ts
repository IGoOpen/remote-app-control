import {
  decodeDisplayList,
  type DisplayListSink,
  type Paint,
  type PathData,
  type RRect,
  type Rect,
  type TextRun,
} from './display_list.ts';
import { BlendMode, PlaceholderKind } from './protocol.ts';
import type { Resources, TextStyle } from './resources.ts';

type Context2D = CanvasRenderingContext2D | OffscreenCanvasRenderingContext2D;
type LayerCanvas = HTMLCanvasElement | OffscreenCanvas;

const COMPOSITE: Record<string, GlobalCompositeOperation> = {
  clear: 'copy',
  src: 'copy',
  dst: 'destination-over',
  srcOver: 'source-over',
  dstOver: 'destination-over',
  srcIn: 'source-in',
  dstIn: 'destination-in',
  srcOut: 'source-out',
  dstOut: 'destination-out',
  srcATop: 'source-atop',
  dstATop: 'destination-atop',
  xor: 'xor',
  plus: 'lighter',
  modulate: 'multiply',
  screen: 'screen',
  overlay: 'overlay',
  darken: 'darken',
  lighten: 'lighten',
  colorDodge: 'color-dodge',
  colorBurn: 'color-burn',
  hardLight: 'hard-light',
  softLight: 'soft-light',
  difference: 'difference',
  exclusion: 'exclusion',
  multiply: 'multiply',
  hue: 'hue',
  saturation: 'saturation',
  color: 'color',
  luminosity: 'luminosity',
};

const colorCache = new Map<number, string>();

/** ARGB integer to a CSS color. */
export function cssColor(argb: number): string {
  let css = colorCache.get(argb);
  if (css === undefined) {
    const a = (argb >>> 24) & 0xff;
    css = `rgba(${(argb >>> 16) & 0xff},${(argb >>> 8) & 0xff},${argb & 0xff},${a / 255})`;
    if (colorCache.size > 4096) colorCache.clear();
    colorCache.set(argb, css);
  }
  return css;
}

function compositeFor(blendMode: number): GlobalCompositeOperation {
  return COMPOSITE[BlendMode[blendMode] ?? 'srcOver'] ?? 'source-over';
}

function rrectPath(p: Path2D, r: RRect): void {
  const [tlx, tly, trx, try_, brx, bry, blx, bly] = r.radii;
  const { left: l, top: t, right: rt, bottom: b } = r;
  p.moveTo(l + tlx, t);
  p.lineTo(rt - trx, t);
  if (trx > 0 && try_ > 0) p.ellipse(rt - trx, t + try_, trx, try_, 0, -Math.PI / 2, 0);
  p.lineTo(rt, b - bry);
  if (brx > 0 && bry > 0) p.ellipse(rt - brx, b - bry, brx, bry, 0, 0, Math.PI / 2);
  p.lineTo(l + blx, b);
  if (blx > 0 && bly > 0) p.ellipse(l + blx, b - bly, blx, bly, 0, Math.PI / 2, Math.PI);
  p.lineTo(l, t + tly);
  if (tlx > 0 && tly > 0) p.ellipse(l + tlx, t + tly, tlx, tly, 0, Math.PI, Math.PI * 1.5);
  p.closePath();
}

function toPath2D(path: PathData): Path2D {
  const p = new Path2D();
  for (const { closed, points } of path.contours) {
    if (points.length < 2) continue;
    p.moveTo(points[0], points[1]);
    for (let i = 2; i < points.length; i += 2) p.lineTo(points[i], points[i + 1]);
    if (closed) p.closePath();
  }
  return p;
}

function fillRule(path: PathData): CanvasFillRule {
  return path.fillType === 1 ? 'evenodd' : 'nonzero';
}

interface Layer {
  parent: Context2D;
  canvas: LayerCanvas;
  alpha: number;
  composite: GlobalCompositeOperation;
}

export interface RenderOptions {
  /** Fill color for masked regions. */
  maskColor?: string;
  /** Fill color for platform views and textures that cannot be streamed. */
  placeholderColor?: string;
}

/**
 * Draws display lists with the Canvas 2D API.
 *
 * Text arrives already laid out, so each run is drawn at its box and, if the
 * local font measures differently, stretched to the host's width to keep
 * lines exactly where they were.
 */
export class CanvasRenderer implements DisplayListSink {
  private ctx!: Context2D;
  private resources!: Resources;
  private width = 0;
  private height = 0;
  // One entry per save: null for a plain save, a Layer for saveLayer.
  private readonly stack: (Layer | null)[] = [];
  private readonly layerPool: LayerCanvas[] = [];
  private readonly measureCache = new Map<string, number>();
  private readonly options: Required<RenderOptions>;

  constructor(options: RenderOptions = {}) {
    this.options = {
      maskColor: options.maskColor ?? '#37474f',
      placeholderColor: options.placeholderColor ?? '#9e9e9e',
    };
  }

  /**
   * Renders the chunk tree rooted at [root] onto [ctx], whose current
   * transform maps the frame's logical coordinates to the canvas.
   */
  render(ctx: CanvasRenderingContext2D, root: number, resources: Resources): void {
    const ops = resources.chunks.get(root);
    if (!ops) return;
    this.ctx = ctx;
    this.resources = resources;
    this.width = ctx.canvas.width;
    this.height = ctx.canvas.height;
    ctx.save();
    try {
      decodeDisplayList(ops, this);
    } finally {
      while (this.stack.length > 0) this.restore();
      ctx.restore();
    }
    if (this.measureCache.size > 8192) this.measureCache.clear();
  }

  /** Call when fonts change so cached text measurements are dropped. */
  invalidateText(): void {
    this.measureCache.clear();
  }

  // State.

  save(): void {
    this.ctx.save();
    this.stack.push(null);
  }

  saveLayer(_bounds: Rect | null, paint: Paint): void {
    const alpha = ((paint.color >>> 24) & 0xff) / 255;
    const composite = compositeFor(paint.blendMode);
    if (alpha >= 1 && composite === 'source-over') {
      // Nothing to composite; a plain save is equivalent and far cheaper.
      this.save();
      return;
    }
    const canvas = this.takeLayerCanvas();
    const layerCtx = canvas.getContext('2d') as Context2D;
    layerCtx.setTransform(this.ctx.getTransform());
    this.stack.push({ parent: this.ctx, canvas, alpha, composite });
    this.ctx = layerCtx;
  }

  restore(): void {
    const entry = this.stack.pop();
    if (entry === undefined) return;
    if (entry === null) {
      this.ctx.restore();
      return;
    }
    const parent = entry.parent;
    parent.save();
    parent.setTransform(1, 0, 0, 1, 0, 0);
    parent.globalAlpha = entry.alpha;
    parent.globalCompositeOperation = entry.composite;
    parent.drawImage(entry.canvas, 0, 0);
    parent.restore();
    this.ctx = parent;
    this.layerPool.push(entry.canvas);
  }

  private takeLayerCanvas(): LayerCanvas {
    const pooled = this.layerPool.pop();
    let canvas: LayerCanvas;
    if (pooled && pooled.width === this.width && pooled.height === this.height) {
      canvas = pooled;
      const c = canvas.getContext('2d') as Context2D;
      c.setTransform(1, 0, 0, 1, 0, 0);
      c.clearRect(0, 0, this.width, this.height);
    } else {
      canvas = typeof OffscreenCanvas !== 'undefined'
        ? new OffscreenCanvas(this.width, this.height)
        : Object.assign(document.createElement('canvas'), { width: this.width, height: this.height });
    }
    return canvas;
  }

  translate(dx: number, dy: number): void {
    this.ctx.translate(dx, dy);
  }

  scale(sx: number, sy: number): void {
    this.ctx.scale(sx, sy);
  }

  rotate(radians: number): void {
    this.ctx.rotate(radians);
  }

  skew(sx: number, sy: number): void {
    this.ctx.transform(1, sy, sx, 1, 0, 0);
  }

  transform(m: Float32Array): void {
    // 2D affine part of the column-major 4x4 matrix.
    this.ctx.transform(m[0], m[1], m[4], m[5], m[12], m[13]);
  }

  clipRect(rect: Rect, difference: boolean): void {
    const p = new Path2D();
    if (difference) {
      p.rect(-1e6, -1e6, 2e6, 2e6);
      p.rect(rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top);
      this.ctx.clip(p, 'evenodd');
    } else {
      p.rect(rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top);
      this.ctx.clip(p);
    }
  }

  clipRRect(rrect: RRect): void {
    const p = new Path2D();
    rrectPath(p, rrect);
    this.ctx.clip(p);
  }

  clipRSuperellipse(rrect: RRect): void {
    this.clipRRect(rrect);
  }

  clipPath(path: PathData): void {
    this.ctx.clip(toPath2D(path), fillRule(path));
  }

  // Drawing.

  private currentScale(): number {
    const m = this.ctx.getTransform();
    return Math.max(Math.hypot(m.a, m.b), Math.hypot(m.c, m.d)) || 1;
  }

  /** Applies [paint] and returns whether to stroke. The caller must call [endPaint]. */
  private beginPaint(paint: Paint): boolean {
    const c = this.ctx;
    c.save();
    const css = cssColor(paint.color);
    if (paint.blendMode !== 3) c.globalCompositeOperation = compositeFor(paint.blendMode);
    if (paint.blurSigma > 0) c.filter = `blur(${paint.blurSigma * this.currentScale()}px)`;
    if (paint.stroke) {
      c.strokeStyle = css;
      c.lineWidth = paint.strokeWidth > 0 ? paint.strokeWidth : 1 / this.currentScale();
      c.lineCap = paint.strokeCap === 1 ? 'round' : paint.strokeCap === 2 ? 'square' : 'butt';
      c.lineJoin = paint.strokeJoin === 1 ? 'round' : paint.strokeJoin === 2 ? 'bevel' : 'miter';
      c.miterLimit = paint.strokeMiterLimit;
      return true;
    }
    c.fillStyle = css;
    return false;
  }

  private endPaint(): void {
    this.ctx.restore();
  }

  private paintPath(p: Path2D, paint: Paint, rule: CanvasFillRule = 'nonzero'): void {
    const stroke = this.beginPaint(paint);
    if (stroke) this.ctx.stroke(p);
    else this.ctx.fill(p, rule);
    this.endPaint();
  }

  drawColor(color: number, blendMode: number): void {
    const c = this.ctx;
    c.save();
    c.setTransform(1, 0, 0, 1, 0, 0);
    c.globalCompositeOperation = compositeFor(blendMode);
    c.fillStyle = cssColor(color);
    c.fillRect(0, 0, this.width, this.height);
    c.restore();
  }

  drawPaint(paint: Paint): void {
    this.beginPaint(paint);
    this.ctx.setTransform(1, 0, 0, 1, 0, 0);
    this.ctx.fillRect(0, 0, this.width, this.height);
    this.endPaint();
  }

  drawLine(x1: number, y1: number, x2: number, y2: number, paint: Paint): void {
    const p = new Path2D();
    p.moveTo(x1, y1);
    p.lineTo(x2, y2);
    const wasStroke = paint.stroke;
    paint.stroke = true; // Lines are always stroked.
    this.paintPath(p, paint);
    paint.stroke = wasStroke;
  }

  drawRect(rect: Rect, paint: Paint): void {
    const p = new Path2D();
    p.rect(rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top);
    this.paintPath(p, paint);
  }

  drawRRect(rrect: RRect, paint: Paint): void {
    const p = new Path2D();
    rrectPath(p, rrect);
    this.paintPath(p, paint);
  }

  drawDRRect(outer: RRect, inner: RRect, paint: Paint): void {
    const p = new Path2D();
    rrectPath(p, outer);
    rrectPath(p, inner);
    this.paintPath(p, paint, 'evenodd');
  }

  drawRSuperellipse(rrect: RRect, paint: Paint): void {
    this.drawRRect(rrect, paint);
  }

  drawOval(rect: Rect, paint: Paint): void {
    const p = new Path2D();
    const rx = (rect.right - rect.left) / 2;
    const ry = (rect.bottom - rect.top) / 2;
    p.ellipse(rect.left + rx, rect.top + ry, Math.abs(rx), Math.abs(ry), 0, 0, Math.PI * 2);
    this.paintPath(p, paint);
  }

  drawCircle(cx: number, cy: number, radius: number, paint: Paint): void {
    const p = new Path2D();
    p.arc(cx, cy, Math.abs(radius), 0, Math.PI * 2);
    this.paintPath(p, paint);
  }

  drawArc(rect: Rect, start: number, sweep: number, useCenter: boolean, paint: Paint): void {
    const p = new Path2D();
    const rx = (rect.right - rect.left) / 2;
    const ry = (rect.bottom - rect.top) / 2;
    const cx = rect.left + rx;
    const cy = rect.top + ry;
    if (useCenter) p.moveTo(cx, cy);
    p.ellipse(cx, cy, Math.abs(rx), Math.abs(ry), 0, start, start + sweep, sweep < 0);
    if (useCenter) p.closePath();
    this.paintPath(p, paint);
  }

  drawPath(path: PathData, paint: Paint): void {
    this.paintPath(toPath2D(path), paint, fillRule(path));
  }

  drawImageRect(imageId: number, src: Rect, dst: Rect, paint: Paint): void {
    const image = this.resources.images.get(imageId);
    if (!image) return;
    const sx = image.width / image.originalWidth;
    const sy = image.height / image.originalHeight;
    const c = this.ctx;
    c.save();
    c.globalAlpha = ((paint.color >>> 24) & 0xff) / 255;
    if (paint.blendMode !== 3) c.globalCompositeOperation = compositeFor(paint.blendMode);
    c.imageSmoothingEnabled = paint.filterQuality > 0;
    if (paint.filterQuality > 1) c.imageSmoothingQuality = paint.filterQuality === 3 ? 'high' : 'medium';
    c.drawImage(
      image.source,
      src.left * sx, src.top * sy, (src.right - src.left) * sx, (src.bottom - src.top) * sy,
      dst.left, dst.top, dst.right - dst.left, dst.bottom - dst.top,
    );
    c.restore();
  }

  drawImageNine(imageId: number, center: Rect, dst: Rect, paint: Paint): void {
    const image = this.resources.images.get(imageId);
    if (!image) return;
    const w = image.originalWidth;
    const h = image.originalHeight;
    const xs = [0, center.left, center.right, w];
    const ys = [0, center.top, center.bottom, h];
    const dxs = [dst.left, dst.left + center.left, dst.right - (w - center.right), dst.right];
    const dys = [dst.top, dst.top + center.top, dst.bottom - (h - center.bottom), dst.bottom];
    for (let row = 0; row < 3; row++) {
      for (let col = 0; col < 3; col++) {
        if (xs[col + 1] <= xs[col] || ys[row + 1] <= ys[row]) continue;
        this.drawImageRect(
          imageId,
          { left: xs[col], top: ys[row], right: xs[col + 1], bottom: ys[row + 1] },
          { left: dxs[col], top: dys[row], right: dxs[col + 1], bottom: dys[row + 1] },
          paint,
        );
      }
    }
  }

  drawPoints(mode: number, points: Float32Array, paint: Paint): void {
    const p = new Path2D();
    if (mode === 0) {
      // Points are dots of the stroke width.
      const r = Math.max(paint.strokeWidth, 1 / this.currentScale()) / 2;
      for (let i = 0; i + 1 < points.length; i += 2) {
        if (paint.strokeCap === 1) {
          p.moveTo(points[i] + r, points[i + 1]);
          p.arc(points[i], points[i + 1], r, 0, Math.PI * 2);
        } else {
          p.rect(points[i] - r, points[i + 1] - r, r * 2, r * 2);
        }
      }
      const wasStroke = paint.stroke;
      paint.stroke = false;
      this.paintPath(p, paint);
      paint.stroke = wasStroke;
      return;
    }
    for (let i = 0; i + 3 < points.length; i += mode === 1 ? 4 : 2) {
      if (mode === 1 || i === 0) p.moveTo(points[i], points[i + 1]);
      p.lineTo(points[i + 2], points[i + 3]);
    }
    const wasStroke = paint.stroke;
    paint.stroke = true;
    this.paintPath(p, paint);
    paint.stroke = wasStroke;
  }

  /**
   * Approximates Flutter's material elevation shadow with canvas shadows:
   * a soft ambient shadow plus an offset key shadow. The shape itself is
   * drawn far off-screen so only its shadow lands on the canvas.
   */
  drawShadow(path: PathData, color: number, elevation: number, _transparentOccluder: boolean): void {
    if (elevation <= 0) return;
    const c = this.ctx;
    const p = toPath2D(path);
    const scale = this.currentScale();
    const alpha = ((color >>> 24) & 0xff) / 255;
    const rgb = color & 0xffffff;
    const far = 1e5;
    for (const [shadowAlpha, blur, dy] of [
      [0.12, elevation * 1.0, elevation * 0.5],
      [0.1, elevation * 0.5, elevation * 0.15],
    ]) {
      c.save();
      c.translate(far, 0);
      c.shadowColor = cssColor((Math.round(shadowAlpha * alpha * 255) << 24) | rgb);
      c.shadowBlur = blur * scale;
      c.shadowOffsetX = -far * scale;
      c.shadowOffsetY = dy * scale;
      c.fillStyle = '#000';
      c.fill(p, fillRule(path));
      c.restore();
    }
  }

  drawText(runs: TextRun[]): void {
    const c = this.ctx;
    c.save();
    c.textBaseline = 'alphabetic';
    let lastStyle = -1;
    let style: TextStyle | undefined;
    for (const run of runs) {
      if (run.style !== lastStyle) {
        lastStyle = run.style;
        style = this.resources.styles.get(run.style);
        if (style) this.applyTextStyle(style);
      }
      if (!style) continue;
      const { box } = run;
      const width = box.right - box.left;
      if (style.background !== null) {
        c.fillStyle = cssColor(style.background);
        c.fillRect(box.left, box.top, width, box.bottom - box.top);
        c.fillStyle = cssColor(style.color);
      }
      c.direction = run.rtl ? 'rtl' : 'ltr';
      c.textAlign = run.rtl ? 'right' : 'left';
      const anchor = run.rtl ? box.right : box.left;

      const measured = this.measure(c, run, style);
      const stretch = measured > 0 && Math.abs(measured - width) > 0.5 ? width / measured : 1;
      for (const shadow of style.shadows) {
        c.save();
        c.shadowColor = cssColor(shadow.color);
        c.shadowBlur = shadow.blur * this.currentScale();
        c.shadowOffsetX = shadow.dx * this.currentScale();
        c.shadowOffsetY = shadow.dy * this.currentScale();
        this.fillText(c, run.text, anchor, run.baseline, stretch);
        c.restore();
      }
      this.fillText(c, run.text, anchor, run.baseline, stretch);
      if (style.decoration) this.drawDecorations(c, style, box, run.baseline);
    }
    c.restore();
  }

  private applyTextStyle(style: TextStyle): void {
    const c = this.ctx;
    c.font = style.font;
    c.fillStyle = cssColor(style.color);
    if ('letterSpacing' in c) {
      c.letterSpacing = `${style.letterSpacing ?? 0}px`;
      c.wordSpacing = `${style.wordSpacing ?? 0}px`;
    }
  }

  private measure(c: Context2D, run: TextRun, style: TextStyle): number {
    const key = `${style.font}\u0000${style.letterSpacing}\u0000${run.text}`;
    let width = this.measureCache.get(key);
    if (width === undefined) {
      width = c.measureText(run.text).width;
      this.measureCache.set(key, width);
    }
    return width;
  }

  private fillText(c: Context2D, text: string, x: number, y: number, stretch: number): void {
    if (stretch === 1) {
      c.fillText(text, x, y);
      return;
    }
    c.save();
    c.translate(x, y);
    c.scale(stretch, 1);
    c.fillText(text, 0, 0);
    c.restore();
  }

  private drawDecorations(c: Context2D, style: TextStyle, box: Rect, baseline: number): void {
    const size = style.fontSize;
    const thickness = Math.max(size / 14, 1 / this.currentScale()) * style.decorationThickness;
    const ys: number[] = [];
    if (style.decoration & 1) ys.push(baseline + size * 0.12);
    if (style.decoration & 2) ys.push(box.top + thickness / 2);
    if (style.decoration & 4) ys.push(baseline - size * 0.3);
    c.save();
    c.strokeStyle = cssColor(style.decorationColor);
    c.lineWidth = thickness;
    if (style.decorationStyle === 2) c.setLineDash([thickness, thickness]);
    if (style.decorationStyle === 3) c.setLineDash([thickness * 3, thickness * 2]);
    for (const y of ys) {
      c.beginPath();
      if (style.decorationStyle === 4) {
        // Wavy: a zigzag of half-waves.
        const step = thickness * 2;
        c.moveTo(box.left, y);
        for (let x = box.left, up = true; x < box.right; x += step, up = !up) {
          c.lineTo(Math.min(x + step, box.right), y + (up ? -thickness : thickness));
        }
      } else {
        c.moveTo(box.left, y);
        c.lineTo(box.right, y);
        if (style.decorationStyle === 1) {
          c.moveTo(box.left, y + thickness * 2);
          c.lineTo(box.right, y + thickness * 2);
        }
      }
      c.stroke();
    }
    c.restore();
  }

  drawChunk(id: number, dx: number, dy: number): void {
    const ops = this.resources.chunks.get(id);
    if (!ops) return;
    this.save();
    this.translate(dx, dy);
    const depth = this.stack.length;
    decodeDisplayList(ops, this);
    while (this.stack.length > depth) this.restore();
    this.restore();
  }

  placeholder(rect: Rect, kind: number): void {
    const c = this.ctx;
    c.save();
    c.fillStyle = kind === PlaceholderKind.masked ? this.options.maskColor : this.options.placeholderColor;
    c.fillRect(rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top);
    c.restore();
  }
}
