import { FrameFlag, MessageType, PointerPhase, RemoteKey } from './protocol.ts';
import { ByteReader, ByteWriter } from './reader.ts';
import { Resources, type ResourceOptions } from './resources.ts';

export type ViewerStatus = 'idle' | 'connecting' | 'waitingForDevice' | 'connected' | 'disconnected';

export interface Frame {
  /** Logical size of the app. */
  width: number;
  height: number;
  /** Root of the chunk tree; chunks live in {@link Resources.chunks}. */
  root: number;
}

export interface LogEntry {
  time: Date;
  isError: boolean;
  message: string;
}

export interface DeviceInfo {
  protocol?: number;
  platform?: string;
  devicePixelRatio?: number;
  [key: string]: unknown;
}

export interface ViewerEvents {
  status: ViewerStatus;
  frame: Frame;
  /** Images or fonts changed; the current frame should be redrawn. */
  resources: void;
  logs: LogEntry[];
}

export interface RemoteViewerOptions extends ResourceOptions {
  /** Relay server, e.g. `wss://support.example.com`. */
  server: string;
  /** Keep at most this many log entries. Default 2000. */
  logLimit?: number;
}

type Listener<T> = (value: T) => void;

/**
 * A connection to an app shared through the relay server.
 *
 * ```ts
 * const viewer = new RemoteViewer({ server: 'wss://support.example.com' });
 * viewer.on('frame', () => ...);
 * await viewer.connect('123456');
 * ```
 */
export class RemoteViewer {
  readonly resources: Resources;
  status: ViewerStatus = 'idle';
  error: string | null = null;
  frame: Frame | null = null;
  deviceInfo: DeviceInfo = {};
  readonly logs: LogEntry[] = [];

  private readonly options: RemoteViewerOptions;
  private socket: WebSocket | null = null;
  private generation = 0;
  private readonly listeners = new Map<keyof ViewerEvents, Set<Listener<never>>>();

  constructor(options: RemoteViewerOptions) {
    this.options = options;
    this.resources = new Resources(options);
  }

  on<K extends keyof ViewerEvents>(event: K, listener: Listener<ViewerEvents[K]>): () => void {
    let set = this.listeners.get(event);
    if (!set) this.listeners.set(event, (set = new Set()));
    set.add(listener as Listener<never>);
    return () => set.delete(listener as Listener<never>);
  }

  private emit<K extends keyof ViewerEvents>(event: K, value: ViewerEvents[K]): void {
    for (const listener of this.listeners.get(event) ?? []) (listener as Listener<ViewerEvents[K]>)(value);
  }

  private setStatus(status: ViewerStatus): void {
    this.status = status;
    this.emit('status', status);
  }

  /** Joins the session with [code]. Resolves once the socket is open. */
  connect(code: string): Promise<void> {
    this.disconnect();
    const generation = ++this.generation;
    this.error = null;
    this.setStatus('connecting');
    const url = new URL(this.options.server);
    url.pathname = `${url.pathname.replace(/\/$/, '')}/ws/viewer`;
    url.searchParams.set('code', code);

    return new Promise((resolve, reject) => {
      const socket = new WebSocket(url);
      socket.binaryType = 'arraybuffer';
      this.socket = socket;
      socket.onopen = () => {
        this.setStatus('waitingForDevice');
        resolve();
      };
      socket.onmessage = (event) => {
        if (generation === this.generation && event.data instanceof ArrayBuffer) {
          this.onMessage(new Uint8Array(event.data), generation);
        }
      };
      socket.onclose = (event) => {
        if (generation !== this.generation) return;
        this.socket = null;
        this.error = event.reason || this.error || 'Connection closed';
        this.setStatus('disconnected');
        reject(new Error(this.error));
      };
    });
  }

  disconnect(): void {
    this.generation++;
    this.socket?.close();
    this.socket = null;
    this.frame = null;
    this.resources.clear();
    if (this.status !== 'idle') this.setStatus('idle');
  }

  private onMessage(bytes: Uint8Array, generation: number): void {
    if (bytes.length === 0) return;
    const r = new ByteReader(bytes, 1);
    switch (bytes[0]) {
      case MessageType.hello:
        this.deviceInfo = r.json<DeviceInfo>();
        this.resources.clear();
        this.resources.platform = this.deviceInfo.platform ?? '';
        this.setStatus('connected');
        break;
      case MessageType.frame: {
        const flags = r.u8();
        const width = r.f32();
        const height = r.f32();
        const root = r.varUint();
        const chunks = this.resources.chunks;
        if (flags & FrameFlag.keyframe) chunks.clear();
        for (let n = r.varUint(); n > 0; n--) {
          const id = r.varUint();
          // Copy so a chunk does not keep its whole message alive.
          chunks.set(id, r.take(r.varUint()).slice());
        }
        for (let n = r.varUint(); n > 0; n--) chunks.delete(r.varUint());
        this.frame = { width, height, root };
        if (this.status !== 'connected') this.setStatus('connected');
        this.emit('frame', this.frame);
        break;
      }
      case MessageType.styles:
        this.resources.addStyles(r);
        break;
      case MessageType.image:
        this.resources.addImage(r).then(
          () => generation === this.generation && this.emit('resources', undefined),
          (e) => console.warn('remote-app-control: image decode failed', e),
        );
        break;
      case MessageType.imageRelease:
        for (let n = r.varUint(); n > 0; n--) this.resources.releaseImage(r.varUint());
        break;
      case MessageType.fontOffer:
        this.resources.addFontOffer(r).then(
          (missing) => {
            if (generation !== this.generation) return;
            if (missing) this.send(new Uint8Array([MessageType.fontRequest, ...missing]));
            else this.emit('resources', undefined);
          },
          (e) => console.warn('remote-app-control: font offer failed', e),
        );
        break;
      case MessageType.font:
        this.resources.addFont(r).then(
          () => generation === this.generation && this.emit('resources', undefined),
          (e) => console.warn('remote-app-control: font load failed', e),
        );
        break;
      case MessageType.log:
        this.addLogs(r.json<{ t: number; l: string; m: string }[]>());
        break;
      case MessageType.control: {
        const message = r.json<{ event: string; message?: string }>();
        if (message.event === 'device_left') {
          this.frame = null;
          this.setStatus('waitingForDevice');
        } else if (message.event === 'error') {
          this.error = message.message ?? 'Server error';
        }
        break;
      }
    }
  }

  private addLogs(entries: { t: number; l: string; m: string }[]): void {
    const limit = this.options.logLimit ?? 2000;
    const added = entries.map((e) => ({ time: new Date(e.t), isError: e.l === 'error', message: e.m }));
    this.logs.push(...added);
    if (this.logs.length > limit) this.logs.splice(0, this.logs.length - limit);
    this.emit('logs', added);
  }

  clearLogs(): void {
    this.logs.length = 0;
  }

  private send(bytes: Uint8Array): void {
    if (this.status === 'connected' && this.socket?.readyState === WebSocket.OPEN) {
      this.socket.send(bytes);
    }
  }

  /** [x], [y] are in the app's logical coordinates. */
  sendPointer(phase: (typeof PointerPhase)[keyof typeof PointerPhase], pointer: number, x: number, y: number): void {
    this.send(new ByteWriter().u8(MessageType.pointer).u8(phase).u8(pointer & 0xff).f32(x).f32(y).finish());
  }

  sendScroll(x: number, y: number, dx: number, dy: number): void {
    this.send(new ByteWriter().u8(MessageType.scroll).f32(x).f32(y).f32(dx).f32(dy).finish());
  }

  /** Types [text] into the focused field of the app. */
  sendText(text: string): void {
    this.send(new ByteWriter().u8(MessageType.textInput).string(text).finish());
  }

  sendKey(key: (typeof RemoteKey)[keyof typeof RemoteKey]): void {
    this.send(new ByteWriter().u8(MessageType.key).u8(key).finish());
  }

  /** Presses the system back button. */
  back(): void {
    this.sendKey(RemoteKey.back);
  }
}
