// JSON-file storage with atomic writes: write a temp file in the same directory, fsync it, then
// rename() over the real file (atomic on POSIX), then fsync the directory. A crash mid-write
// leaves either the old file or the new one, never a half-written file.
import fs from 'node:fs/promises';
import path from 'node:path';

export async function atomicWriteJSON(file, data) {
  const dir = path.dirname(file);
  const tmp = path.join(dir, `.${path.basename(file)}.${process.pid}.${Date.now()}.${Math.random().toString(36).slice(2)}.tmp`);
  const text = JSON.stringify(data, null, 1) + '\n'; // serialise first: a failure here touches no file
  try {
    const fh = await fs.open(tmp, 'w', 0o600);
    try {
      await fh.writeFile(text, 'utf8');
      await fh.sync();
    } finally {
      await fh.close();
    }
    await fs.rename(tmp, file);
  } catch (e) {
    await fs.rm(tmp, { force: true });
    throw e;
  }
  try {
    const dh = await fs.open(dir, 'r');
    try { await dh.sync(); } finally { await dh.close(); }
  } catch { /* directory fsync is best effort (not supported everywhere) */ }
}

async function readJSON(file) {
  let text;
  try {
    text = await fs.readFile(file, 'utf8');
  } catch (e) {
    if (e.code === 'ENOENT') return null;
    throw e;
  }
  try {
    return JSON.parse(text);
  } catch (e) {
    // Refuse to start rather than silently overwrite (and lose) all registered tokens.
    throw new Error(`${file} is not valid JSON (${e.message}). Restore it from a backup or move it away.`);
  }
}

/** Serialises saves: concurrent save() calls coalesce, and each resolves once its state is on disk. */
class Persister {
  constructor(file, snapshot) {
    this.file = file;
    this.snapshot = snapshot;
    this.running = null;
    this.pending = null;
  }
  save() {
    if (this.pending) return this.pending;
    const run = async () => {
      // Always yield first so `this.pending` is assigned before it is cleared below.
      await (this.running ? this.running.catch(() => {}) : null);
      while (this.running) await this.running.catch(() => {});
      this.pending = null;
      this.running = atomicWriteJSON(this.file, this.snapshot());
      try { await this.running; } finally { this.running = null; }
    };
    this.pending = run();
    return this.pending;
  }
}

export class TokenStore {
  constructor(dataDir) {
    this.file = path.join(dataDir, 'tokens.json');
    this.tokens = new Map();
    this.persister = new Persister(this.file, () => ({ version: 1, tokens: Object.fromEntries(this.tokens) }));
  }

  async load() {
    await fs.mkdir(path.dirname(this.file), { recursive: true, mode: 0o700 });
    const data = await readJSON(this.file);
    this.tokens = new Map(Object.entries(data?.tokens ?? {}));
    return this;
  }

  get size() { return this.tokens.size; }
  get(token) { return this.tokens.get(token); }

  async upsert({ token, environment, language, appVersion, locale }, now = new Date()) {
    const prev = this.tokens.get(token);
    const iso = now.toISOString();
    this.tokens.set(token, {
      environment, language, appVersion, locale,
      createdAt: prev?.createdAt ?? iso,
      updatedAt: iso,
    });
    await this.persister.save();
    return !prev;
  }

  async remove(token) {
    if (!this.tokens.delete(token)) return false;
    await this.persister.save();
    return true;
  }

  /** Remove many tokens with a single write. */
  async removeMany(list) {
    let n = 0;
    for (const t of list) if (this.tokens.delete(t)) n++;
    if (n) await this.persister.save();
    return n;
  }

  /** [{ token, ...record }] matching the filter (language null = everyone). */
  select({ environment, language = null }) {
    const out = [];
    for (const [token, r] of this.tokens) {
      if (r.environment !== environment) continue;
      if (language && r.language !== language) continue;
      out.push({ token, ...r });
    }
    return out;
  }

  counts() {
    const c = { production: 0, sandbox: 0 };
    for (const r of this.tokens.values()) if (r.environment in c) c[r.environment]++;
    return c;
  }

  /** Counts per environment and learning language, for the admin page. */
  breakdown() {
    const b = {};
    for (const r of this.tokens.values()) {
      b[r.environment] ??= { total: 0, en: 0, fr: 0, th: 0 };
      b[r.environment].total++;
      if (r.language in b[r.environment]) b[r.environment][r.language]++;
    }
    return b;
  }
}

export const HISTORY_MAX = 100;

export class HistoryStore {
  constructor(dataDir) {
    this.file = path.join(dataDir, 'history.json');
    this.sends = [];
    this.persister = new Persister(this.file, () => ({ version: 1, sends: this.sends }));
  }

  async load() {
    await fs.mkdir(path.dirname(this.file), { recursive: true, mode: 0o700 });
    const data = await readJSON(this.file);
    this.sends = Array.isArray(data?.sends) ? data.sends.slice(0, HISTORY_MAX) : [];
    return this;
  }

  /** Newest first, capped at HISTORY_MAX. */
  async add(entry) {
    this.sends.unshift(entry);
    if (this.sends.length > HISTORY_MAX) this.sends.length = HISTORY_MAX;
    await this.persister.save();
  }

  list(limit = HISTORY_MAX) { return this.sends.slice(0, limit); }
}
