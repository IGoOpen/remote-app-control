import { defaultFontCache, sha256Hex, toHex, type FontCache } from './font_cache.ts';
import { StyleFlag } from './protocol.ts';
import { ByteReader } from './reader.ts';

export interface TextShadow {
  color: number;
  dx: number;
  dy: number;
  blur: number;
}

/** A resolved text style, as defined by the host. */
export interface TextStyle {
  color: number;
  fontSize: number;
  fontWeight: number;
  italic: boolean;
  /** Empty for the host platform's default font. */
  family: string;
  fallback: string[];
  letterSpacing: number | null;
  wordSpacing: number | null;
  /** Bits: 1 underline, 2 overline, 4 line-through. */
  decoration: number;
  decorationColor: number;
  /** 0 solid, 1 double, 2 dotted, 3 dashed, 4 wavy. */
  decorationStyle: number;
  decorationThickness: number;
  background: number | null;
  shadows: TextShadow[];
  /** CSS `font` shorthand, rebuilt when fonts arrive. */
  font: string;
}

export interface RemoteImage {
  source: CanvasImageSource;
  width: number;
  height: number;
  /** Size before the host downscaled it; frame coordinates refer to this. */
  originalWidth: number;
  originalHeight: number;
}

export interface ResourceOptions {
  /** Families to try after the host's own fonts, per host platform. */
  defaultFonts?: Partial<Record<string, string>>;
  /** Maps host font families to fonts available on the page. */
  familyAliases?: Record<string, string>;
  /** Where fonts are kept between sessions. Defaults to IndexedDB. */
  fontCache?: FontCache;
}

const DEFAULT_FONTS: Record<string, string> = {
  android: 'Roboto, "Noto Sans", system-ui, sans-serif',
  iOS: '-apple-system, "SF Pro Text", system-ui, sans-serif',
  macOS: '-apple-system, "SF Pro Text", system-ui, sans-serif',
  windows: '"Segoe UI", system-ui, sans-serif',
  linux: 'Ubuntu, Cantarell, "Noto Sans", system-ui, sans-serif',
  fuchsia: 'Roboto, system-ui, sans-serif',
};

const DEFAULT_ALIASES: Record<string, string> = {
  // Same codepoints as Flutter's bundled icon font, if the page loads it.
  MaterialIcons: 'Material Icons',
};

let sharedFontCache: FontCache | undefined;

// Font faces are registered once per page and shared by every session.
const registeredFiles = new Set<string>();
const registeredFamilies = new Set<string>();

/**
 * Host fonts are registered under a name derived from the family's content,
 * so they never clash with the page's fonts or another app's font of the
 * same name.
 */
function remoteFamily(familyKey: string): string {
  return `rac-${familyKey}`;
}

/** Images, text styles and fonts sent by the host during a session. */
export class Resources {
  readonly images = new Map<number, RemoteImage>();
  /** Retained parts of the screen by id; frames are trees of these. */
  readonly chunks = new Map<number, Uint8Array>();
  readonly styles = new Map<number, TextStyle>();
  platform = '';
  private readonly options: ResourceOptions;
  private readonly fontCache: FontCache;
  // Per session: family name -> family key, and offered files by hash.
  private readonly familyKeys = new Map<string, string>();
  private readonly offeredFiles = new Map<string, { familyKey: string; weight: number; italic: boolean }>();

  constructor(options: ResourceOptions = {}) {
    this.options = options;
    this.fontCache = options.fontCache ?? (sharedFontCache ??= defaultFontCache());
  }

  addStyles(r: ByteReader): void {
    const count = r.varUint();
    for (let i = 0; i < count; i++) {
      const id = r.varUint();
      const style = readStyle(r);
      style.font = this.fontFor(style);
      this.styles.set(id, style);
    }
  }

  async addImage(r: ByteReader): Promise<number> {
    const id = r.varUint();
    const originalWidth = r.varUint();
    const originalHeight = r.varUint();
    // Copy: the blob must not alias the socket's buffer.
    const bitmap = await createImageBitmap(new Blob([r.rest().slice()]));
    this.releaseImage(id);
    this.images.set(id, {
      source: bitmap,
      width: bitmap.width,
      height: bitmap.height,
      originalWidth,
      originalHeight,
    });
    return id;
  }

  releaseImage(id: number): void {
    const image = this.images.get(id);
    if (image && 'close' in image.source) (image.source as ImageBitmap).close();
    this.images.delete(id);
  }

  /**
   * Handles a `fontOffer`. Resolves to the hash to request from the host
   * when the file is not cached, or null when it is already available.
   */
  async addFontOffer(r: ByteReader): Promise<Uint8Array | null> {
    const family = r.string();
    const familyKey = r.string();
    const weight = r.u16();
    const italic = r.bool();
    const hash = r.take(32).slice();
    const hex = toHex(hash);
    this.familyKeys.set(family, familyKey);
    this.offeredFiles.set(hex, { familyKey, weight, italic });
    if (registeredFiles.has(`${familyKey}/${hex}`)) {
      this.onFamilyReady(familyKey);
      return null;
    }
    try {
      const cached = await this.fontCache.get(hex);
      if (cached && (await sha256Hex(cached)) === hex) {
        await this.register(hex, cached);
        return null;
      }
    } catch (e) {
      console.warn('remote-app-control: font cache unavailable', e);
    }
    return hash;
  }

  /**
   * Handles a `font` sent in answer to a request. Files that do not match
   * their hash are dropped, so a host cannot poison the cache.
   */
  async addFont(r: ByteReader): Promise<void> {
    const hex = toHex(r.take(32));
    if (!this.offeredFiles.has(hex)) return;
    const bytes = r.rest().slice();
    const actual = await sha256Hex(bytes);
    if (actual !== null && actual !== hex) return;
    // Without WebCrypto the file is used for this page only, never cached.
    if (actual !== null) this.fontCache.put(hex, bytes).catch(() => {});
    await this.register(hex, bytes);
  }

  private async register(hex: string, bytes: Uint8Array): Promise<void> {
    const file = this.offeredFiles.get(hex);
    if (!file) return;
    const key = `${file.familyKey}/${hex}`;
    if (!registeredFiles.has(key)) {
      const face = new FontFace(remoteFamily(file.familyKey), bytes as Uint8Array<ArrayBuffer>, {
        weight: file.weight ? String(file.weight) : 'normal',
        style: file.italic ? 'italic' : 'normal',
      });
      await face.load();
      document.fonts.add(face);
      registeredFiles.add(key);
    }
    this.onFamilyReady(file.familyKey);
  }

  private onFamilyReady(familyKey: string): void {
    registeredFamilies.add(familyKey);
    for (const style of this.styles.values()) style.font = this.fontFor(style);
  }

  /** Forgets images and styles. Fonts stay registered on the page. */
  clear(): void {
    for (const id of [...this.images.keys()]) this.releaseImage(id);
    this.chunks.clear();
    this.styles.clear();
    this.familyKeys.clear();
    this.offeredFiles.clear();
  }

  private fontFor(style: TextStyle): string {
    const families: string[] = [];
    const aliases = { ...DEFAULT_ALIASES, ...this.options.familyAliases };
    for (const family of [style.family, ...style.fallback]) {
      if (!family) continue;
      const key = this.familyKeys.get(family);
      if (key && registeredFamilies.has(key)) families.push(quote(remoteFamily(key)));
      if (aliases[family]) families.push(quote(aliases[family]));
      families.push(quote(family));
    }
    const defaults = this.options.defaultFonts?.[this.platform] ?? DEFAULT_FONTS[this.platform];
    families.push(defaults ?? 'system-ui, sans-serif');
    return `${style.italic ? 'italic ' : ''}${style.fontWeight} ${style.fontSize}px ${families.join(', ')}`;
  }
}

function quote(family: string): string {
  return `"${family.replace(/["\\]/g, '\\$&')}"`;
}

function readStyle(r: ByteReader): TextStyle {
  const color = r.u32();
  const fontSize = r.f32();
  const fontWeight = r.u16();
  const flags = r.u8();
  const family = r.string();
  const fallback: string[] = [];
  for (let n = r.varUint(); n > 0; n--) fallback.push(r.string());
  const letterSpacing = flags & StyleFlag.letterSpacing ? r.f32() : null;
  const wordSpacing = flags & StyleFlag.wordSpacing ? r.f32() : null;
  let decoration = 0;
  let decorationColor = color;
  let decorationStyle = 0;
  let decorationThickness = 1;
  if (flags & StyleFlag.decoration) {
    decoration = r.u8();
    decorationColor = r.u32();
    decorationStyle = r.u8();
    decorationThickness = r.f32();
  }
  const background = flags & StyleFlag.background ? r.u32() : null;
  const shadows: TextShadow[] = [];
  if (flags & StyleFlag.shadows) {
    for (let n = r.varUint(); n > 0; n--) {
      shadows.push({ color: r.u32(), dx: r.f32(), dy: r.f32(), blur: r.f32() });
    }
  }
  return {
    color,
    fontSize,
    fontWeight,
    italic: (flags & StyleFlag.italic) !== 0,
    family,
    fallback,
    letterSpacing,
    wordSpacing,
    decoration,
    decorationColor,
    decorationStyle,
    decorationThickness,
    background,
    shadows,
    font: '',
  };
}
