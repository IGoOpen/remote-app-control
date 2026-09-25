import { CanvasRenderer, type RenderOptions } from './canvas_renderer.ts';
import { PointerPhase, RemoteKey } from './protocol.ts';
import type { RemoteViewer } from './viewer.ts';

export interface RemoteScreenOptions extends RenderOptions {
  /** When false the screen is view-only. Default true. */
  interactive?: boolean;
  /** Largest zoom when the container is bigger than the app. Default 3. */
  maxScale?: number;
}

const KEYS: Record<string, number> = {
  Backspace: RemoteKey.backspace,
  Enter: RemoteKey.enter,
  Delete: RemoteKey.delete,
  ArrowLeft: RemoteKey.arrowLeft,
  ArrowRight: RemoteKey.arrowRight,
  Tab: RemoteKey.tab,
  Escape: RemoteKey.back,
};

/**
 * Shows a {@link RemoteViewer}'s app inside [container], scaled to fit, and
 * forwards input: the mouse acts as a finger, the wheel scrolls, typing goes
 * to the focused field and Escape is the system back button.
 *
 * Works with any framework: create it when the container mounts and call
 * {@link destroy} when it unmounts.
 */
export class RemoteScreen {
  readonly canvas: HTMLCanvasElement;
  private readonly container: HTMLElement;
  private readonly viewer: RemoteViewer;
  private readonly renderer: CanvasRenderer;
  private readonly options: RemoteScreenOptions;
  private readonly ctx: CanvasRenderingContext2D;
  private readonly cleanup: (() => void)[] = [];
  private scale = 1;
  private scheduled = 0;
  private readonly down = new Set<number>();

  constructor(container: HTMLElement, viewer: RemoteViewer, options: RemoteScreenOptions = {}) {
    this.container = container;
    this.viewer = viewer;
    this.options = options;
    this.renderer = new CanvasRenderer(options);
    this.canvas = document.createElement('canvas');
    this.canvas.style.display = 'block';
    this.canvas.style.touchAction = 'none';
    this.canvas.style.outline = 'none';
    this.canvas.tabIndex = 0;
    container.appendChild(this.canvas);
    this.ctx = this.canvas.getContext('2d')!;

    this.cleanup.push(
      viewer.on('frame', () => this.invalidate()),
      viewer.on('resources', () => {
        this.renderer.invalidateText();
        this.invalidate();
      }),
      viewer.on('status', () => this.invalidate()),
    );
    const resize = new ResizeObserver(() => this.invalidate());
    resize.observe(container);
    this.cleanup.push(() => resize.disconnect());
    if (options.interactive !== false) this.attachInput();
    this.invalidate();
  }

  destroy(): void {
    cancelAnimationFrame(this.scheduled);
    for (const fn of this.cleanup) fn();
    this.canvas.remove();
  }

  /** Schedules a redraw on the next animation frame. */
  invalidate(): void {
    if (this.scheduled) return;
    this.scheduled = requestAnimationFrame(() => {
      this.scheduled = 0;
      this.draw();
    });
  }

  private draw(): void {
    const frame = this.viewer.frame;
    if (!frame) {
      this.canvas.style.visibility = 'hidden';
      return;
    }
    this.canvas.style.visibility = 'visible';
    const bounds = this.container.getBoundingClientRect();
    const fit = Math.min(bounds.width / frame.width, bounds.height / frame.height);
    this.scale = Math.max(0.1, Math.min(this.options.maxScale ?? 3, fit || 1));
    const cssWidth = Math.round(frame.width * this.scale);
    const cssHeight = Math.round(frame.height * this.scale);
    const dpr = window.devicePixelRatio || 1;
    const width = Math.round(cssWidth * dpr);
    const height = Math.round(cssHeight * dpr);
    if (this.canvas.width !== width || this.canvas.height !== height) {
      this.canvas.width = width;
      this.canvas.height = height;
      this.canvas.style.width = `${cssWidth}px`;
      this.canvas.style.height = `${cssHeight}px`;
    }
    const c = this.ctx;
    c.setTransform(1, 0, 0, 1, 0, 0);
    c.fillStyle = '#000';
    c.fillRect(0, 0, width, height);
    c.setTransform(this.scale * dpr, 0, 0, this.scale * dpr, 0, 0);
    this.renderer.render(c, frame.root, this.viewer.resources);
  }

  private toApp(e: MouseEvent): [number, number] {
    const rect = this.canvas.getBoundingClientRect();
    return [(e.clientX - rect.left) / this.scale, (e.clientY - rect.top) / this.scale];
  }

  private attachInput(): void {
    const canvas = this.canvas;
    const viewer = this.viewer;
    const listen = <K extends keyof HTMLElementEventMap>(
      type: K,
      handler: (e: HTMLElementEventMap[K]) => void,
      options?: AddEventListenerOptions,
    ) => {
      canvas.addEventListener(type, handler as EventListener, options);
      this.cleanup.push(() => canvas.removeEventListener(type, handler as EventListener, options));
    };

    listen('pointerdown', (e) => {
      canvas.focus();
      canvas.setPointerCapture(e.pointerId);
      this.down.add(e.pointerId);
      viewer.sendPointer(PointerPhase.down, e.pointerId, ...this.toApp(e));
      e.preventDefault();
    });
    listen('pointermove', (e) => {
      // Only drags count: a hovering mouse is not a touch.
      if (!this.down.has(e.pointerId)) return;
      for (const event of e.getCoalescedEvents?.() ?? [e]) {
        viewer.sendPointer(PointerPhase.move, e.pointerId, ...this.toApp(event));
      }
    });
    const end = (phase: typeof PointerPhase.up | typeof PointerPhase.cancel) => (e: PointerEvent) => {
      if (!this.down.delete(e.pointerId)) return;
      viewer.sendPointer(phase, e.pointerId, ...this.toApp(e));
    };
    listen('pointerup', end(PointerPhase.up));
    listen('pointercancel', end(PointerPhase.cancel));
    listen('contextmenu', (e) => e.preventDefault());

    listen('wheel', (e) => {
      e.preventDefault();
      const unit = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? canvas.clientHeight / this.scale : 1;
      viewer.sendScroll(...this.toApp(e), (e.deltaX * unit) / this.scale, (e.deltaY * unit) / this.scale);
    }, { passive: false });

    listen('keydown', (e) => {
      const key = KEYS[e.key];
      if (key !== undefined) {
        viewer.sendKey(key as (typeof RemoteKey)[keyof typeof RemoteKey]);
        e.preventDefault();
        return;
      }
      if (e.key.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey) {
        viewer.sendText(e.key);
        e.preventDefault();
      }
    });
    listen('paste', (e) => {
      const text = e.clipboardData?.getData('text/plain');
      if (text) viewer.sendText(text);
      e.preventDefault();
    });
  }
}
