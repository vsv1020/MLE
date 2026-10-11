// HTTP routing. createApp() takes all collaborators as arguments (store, history, APNs transport,
// provider token) so the tests can run it without network access or real Apple credentials.
import crypto from 'node:crypto';
import { validateRegister, validateUnregister, validateSend, tokenTail } from './validate.mjs';
import { checkBasicAuth, RateLimiter } from './security.mjs';
import { sendToAll } from './apns.mjs';
import { adminPage } from './admin-page.mjs';

export const BODY_LIMIT = 4096;

class HttpError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

function readBody(req, limit = BODY_LIMIT) {
  return new Promise((resolve, reject) => {
    const declared = Number(req.headers['content-length']);
    if (declared > limit) return reject(new HttpError(413, 'body too large'));
    const chunks = [];
    let size = 0, failed = false;
    req.on('data', (c) => {
      if (failed) return;
      size += c.length;
      if (size > limit) { failed = true; reject(new HttpError(413, 'body too large')); req.resume(); return; }
      chunks.push(c);
    });
    req.on('end', () => { if (!failed) resolve(Buffer.concat(chunks).toString('utf8')); });
    req.on('error', (e) => { if (!failed) { failed = true; reject(e); } });
  });
}

async function readJSON(req) {
  const type = String(req.headers['content-type'] || '').split(';')[0].trim().toLowerCase();
  if (type !== 'application/json') throw new HttpError(415, 'Content-Type must be application/json');
  const text = await readBody(req);
  try {
    return JSON.parse(text);
  } catch {
    throw new HttpError(400, 'invalid JSON');
  }
}

const SECURITY_HEADERS = {
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
  'Cache-Control': 'no-store',
};

function send(res, status, body, headers = {}) {
  if (res.headersSent) return;
  const h = { ...SECURITY_HEADERS, ...headers };
  if (body === undefined || status === 204) { res.writeHead(status, h); res.end(); return; }
  if (typeof body === 'string') { res.writeHead(status, h); res.end(body); return; }
  res.writeHead(status, { ...h, 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(body));
}

/** Behind nginx the TCP peer is 127.0.0.1; trust X-Real-IP only from a loopback peer. */
export function clientIp(req) {
  const peer = req.socket?.remoteAddress || '';
  const loopback = peer === '127.0.0.1' || peer === '::1' || peer === '::ffff:127.0.0.1';
  if (loopback) {
    const real = req.headers['x-real-ip'];
    if (typeof real === 'string' && real.length <= 64 && real.trim()) return real.trim();
  }
  return peer || 'unknown';
}

export function createApp({
  adminUser,
  adminPassword,
  store,
  history,
  transport,
  providerToken,   // null when APNs credentials are not configured → sending is refused
  log = () => {},
  rateLimit = new RateLimiter({ limit: 30, windowMs: 60_000 }),
  authFailLimit = new RateLimiter({ limit: 10, windowMs: 60_000 }),
  clock = () => new Date(),
}) {
  let sending = false;

  function requireAdmin(req, ip) {
    if (checkBasicAuth(req.headers.authorization, adminUser, adminPassword)) return;
    if (req.headers.authorization) {
      log(`admin auth failed from ${ip}`);
      if (!authFailLimit.hit(ip)) throw new HttpError(429, 'too many failed logins, wait a minute');
    }
    const e = new HttpError(401, 'authentication required');
    e.headers = { 'WWW-Authenticate': 'Basic realm="mashu-push", charset="UTF-8"' };
    throw e;
  }

  /** Browsers always send Origin on cross-origin POSTs; refuse any that is not this host. */
  function requireSameOrigin(req) {
    const origin = req.headers.origin;
    if (origin === undefined) return;
    let host;
    try { host = new URL(origin).host; } catch { host = null; }
    if (!host || host !== req.headers.host) throw new HttpError(403, 'cross-origin request refused');
  }

  async function handleSend(req) {
    requireSameOrigin(req);
    const v = validateSend(await readJSON(req));
    if (!v.ok) throw new HttpError(400, v.error);
    const { title, body, language, environment, dryRun } = v.value;
    const targets = store.select({ environment, language });
    if (dryRun) return { targeted: targets.length, sent: 0, failed: 0, removed: 0, dryRun: true };
    if (!providerToken) throw new HttpError(503, 'APNs is not configured (APNS_KEY_PATH / APNS_KEY_ID / APPLE_TEAM_ID)');
    if (sending) throw new HttpError(409, 'another send is in progress');
    sending = true;
    try {
      log(`send start: ${environment} language=${language || 'all'} targets=${targets.length}`);
      const r = await sendToAll({ transport, providerToken, targets, environment, title, body, log });
      const removed = await store.removeMany(r.removedTokens);
      const result = { targeted: targets.length, sent: r.sent, failed: r.failed, removed, reasons: r.reasons };
      await history.add({ time: clock().toISOString(), title, body, environment, language, ...result });
      log(`send done: sent=${r.sent} failed=${r.failed} removed=${removed}`);
      return result;
    } finally {
      sending = false;
    }
  }

  async function route(req, res) {
    const url = new URL(req.url, 'http://localhost');
    const path = url.pathname;
    const ip = clientIp(req);

    if (path === '/api/push/health') {
      if (req.method !== 'GET' && req.method !== 'HEAD') throw new HttpError(405, 'method not allowed');
      return send(res, 200, { ok: true, apns: Boolean(providerToken), tokens: store.counts() });
    }

    const known = ['/api/push/register', '/api/push/unregister', '/api/push/send', '/api/push/admin/overview', '/push-admin'];
    if (!known.includes(path)) throw new HttpError(404, 'not found');
    if (!rateLimit.hit(ip)) throw Object.assign(new HttpError(429, 'too many requests'), { headers: { 'Retry-After': '60' } });

    if (path === '/api/push/register') {
      if (req.method !== 'POST') throw new HttpError(405, 'method not allowed');
      const v = validateRegister(await readJSON(req));
      if (!v.ok) throw new HttpError(400, v.error);
      const isNew = await store.upsert(v.value, clock());
      log(`${isNew ? 'register' : 'refresh'} ${v.value.environment} ${v.value.language} ${tokenTail(v.value.token)}`);
      return send(res, 204);
    }

    if (path === '/api/push/unregister') {
      if (req.method !== 'POST') throw new HttpError(405, 'method not allowed');
      const v = validateUnregister(await readJSON(req));
      if (!v.ok) throw new HttpError(400, v.error);
      if (await store.remove(v.value.token)) log(`unregister ${tokenTail(v.value.token)}`);
      return send(res, 204);
    }

    // Everything below is the admin area.
    requireAdmin(req, ip);

    if (path === '/push-admin') {
      if (req.method !== 'GET' && req.method !== 'HEAD') throw new HttpError(405, 'method not allowed');
      const nonce = crypto.randomBytes(16).toString('hex');
      return send(res, 200, adminPage(nonce), {
        'Content-Type': 'text/html; charset=utf-8',
        'Content-Security-Policy': `default-src 'none'; script-src 'nonce-${nonce}'; style-src 'nonce-${nonce}'; connect-src 'self'; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'`,
        'X-Frame-Options': 'DENY',
      });
    }

    if (path === '/api/push/admin/overview') {
      if (req.method !== 'GET') throw new HttpError(405, 'method not allowed');
      return send(res, 200, { breakdown: store.breakdown(), apns: Boolean(providerToken), history: history.list(30) });
    }

    if (path === '/api/push/send') {
      if (req.method !== 'POST') throw new HttpError(405, 'method not allowed');
      return send(res, 200, await handleSend(req));
    }
  }

  return async function handler(req, res) {
    try {
      await route(req, res);
    } catch (e) {
      const status = e instanceof HttpError ? e.status : 500;
      if (status === 500) log(`error: ${e.stack || e.message}`);
      const headers = status === 413 ? { ...e.headers, Connection: 'close' } : e.headers;
      send(res, status, { error: status === 500 ? 'internal error' : e.message }, headers);
    }
  };
}
