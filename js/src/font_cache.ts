/** Stores font files by SHA-256 (lowercase hex) across sessions. */
export interface FontCache {
  get(hash: string): Promise<Uint8Array | undefined>;
  put(hash: string, bytes: Uint8Array): Promise<void>;
}

export class MemoryFontCache implements FontCache {
  private readonly fonts = new Map<string, Uint8Array>();

  async get(hash: string): Promise<Uint8Array | undefined> {
    return this.fonts.get(hash);
  }

  async put(hash: string, bytes: Uint8Array): Promise<void> {
    this.fonts.set(hash, bytes);
  }
}

interface Entry {
  hash: string;
  bytes: Uint8Array;
  size: number;
  lastUsed: number;
}

const STORE = 'fonts';

/**
 * Persists fonts in IndexedDB so they survive reloads and are shared by all
 * sessions on this origin. The least recently used fonts are evicted once
 * the cache grows past [maxBytes].
 */
export class IndexedDbFontCache implements FontCache {
  private readonly db: Promise<IDBDatabase>;
  private readonly maxBytes: number;

  constructor(name = 'remote-app-control', maxBytes = 64 * 1024 * 1024) {
    this.maxBytes = maxBytes;
    this.db = new Promise((resolve, reject) => {
      const request = indexedDB.open(name, 1);
      request.onupgradeneeded = () => {
        request.result.createObjectStore(STORE, { keyPath: 'hash' }).createIndex('lastUsed', 'lastUsed');
      };
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
    });
  }

  async get(hash: string): Promise<Uint8Array | undefined> {
    const store = (await this.db).transaction(STORE, 'readwrite').objectStore(STORE);
    const entry = await promise<Entry | undefined>(store.get(hash));
    if (!entry) return undefined;
    entry.lastUsed = Date.now();
    store.put(entry);
    return entry.bytes;
  }

  async put(hash: string, bytes: Uint8Array): Promise<void> {
    const db = await this.db;
    const store = db.transaction(STORE, 'readwrite').objectStore(STORE);
    await promise(store.put({ hash, bytes, size: bytes.byteLength, lastUsed: Date.now() } satisfies Entry));
    await this.evict(db);
  }

  private async evict(db: IDBDatabase): Promise<void> {
    const store = db.transaction(STORE, 'readwrite').objectStore(STORE);
    const entries = await promise<Entry[]>(store.index('lastUsed').getAll());
    let total = entries.reduce((sum, e) => sum + e.size, 0);
    // getAll on the index returns entries oldest first.
    for (const entry of entries) {
      if (total <= this.maxBytes) break;
      store.delete(entry.hash);
      total -= entry.size;
    }
  }
}

function promise<T>(request: IDBRequest): Promise<T> {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result as T);
    request.onerror = () => reject(request.error);
  });
}

/** IndexedDB when available, otherwise in memory. */
export function defaultFontCache(): FontCache {
  return typeof indexedDB !== 'undefined' ? new IndexedDbFontCache() : new MemoryFontCache();
}

/**
 * SHA-256 as lowercase hex, or null where WebCrypto is unavailable (it
 * requires a secure context: https or localhost).
 */
export async function sha256Hex(bytes: Uint8Array): Promise<string | null> {
  if (!globalThis.crypto?.subtle) return null;
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes as Uint8Array<ArrayBuffer>));
  return toHex(digest);
}

export function toHex(bytes: Uint8Array): string {
  let out = '';
  for (const b of bytes) out += b.toString(16).padStart(2, '0');
  return out;
}
