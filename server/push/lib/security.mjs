// HTTP Basic auth (constant-time) and a small fixed-window per-IP rate limiter.
import crypto from 'node:crypto';

const sha256 = (s) => crypto.createHash('sha256').update(String(s), 'utf8').digest();

/** Constant-time string compare: hash both sides so lengths never leak through timing. */
export function safeEqual(a, b) {
  return crypto.timingSafeEqual(sha256(a), sha256(b));
}

export function parseBasicAuth(header) {
  if (typeof header !== 'string') return null;
  const m = /^Basic\s+([A-Za-z0-9+/=]+)\s*$/i.exec(header);
  if (!m) return null;
  const decoded = Buffer.from(m[1], 'base64').toString('utf8');
  const i = decoded.indexOf(':');
  if (i < 0) return null;
  return { user: decoded.slice(0, i), password: decoded.slice(i + 1) };
}

export function checkBasicAuth(header, expectedUser, expectedPassword) {
  const c = parseBasicAuth(header);
  // Evaluate both comparisons unconditionally (no short-circuit on the user name).
  const userOk = safeEqual(c ? c.user : '', expectedUser);
  const passOk = safeEqual(c ? c.password : '', expectedPassword);
  return Boolean(c) && userOk && passOk;
}

export class RateLimiter {
  constructor({ limit = 30, windowMs = 60_000, clock = () => Date.now() } = {}) {
    this.limit = limit;
    this.windowMs = windowMs;
    this.clock = clock;
    this.hits = new Map(); // key -> { start, count }
  }

  /** Returns true if the request is allowed. */
  hit(key) {
    const now = this.clock();
    let e = this.hits.get(key);
    if (!e || now - e.start >= this.windowMs) {
      e = { start: now, count: 0 };
      this.hits.set(key, e);
    }
    e.count++;
    if (this.hits.size > 10_000) this.sweep(now);
    return e.count <= this.limit;
  }

  sweep(now = this.clock()) {
    for (const [k, e] of this.hits) if (now - e.start >= this.windowMs) this.hits.delete(k);
  }
}
