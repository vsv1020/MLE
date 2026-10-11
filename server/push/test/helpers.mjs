// Shared test helpers: temp dirs, a fake APNs transport and an in-process HTTP server.
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import crypto from 'node:crypto';
import { TokenStore, HistoryStore } from '../lib/storage.mjs';
import { ApnsSettingsStore, ApnsCredentials } from '../lib/apns-settings.mjs';
import { createApp } from '../lib/app.mjs';
import { RateLimiter } from '../lib/security.mjs';

export const ADMIN_USER = 'admin';
export const ADMIN_PASSWORD = 'correct-horse-battery';

export const tok = (n) => n.toString(16).padStart(2, '0').repeat(32); // 64 hex chars

export async function tempDir() {
  return fs.mkdtemp(path.join(os.tmpdir(), 'mashu-push-test-'));
}

export function newKey() {
  return crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' });
}

/** Fake APNs: responses[token] = { status, reason, timestamp } (default 200). Records every call. */
export function fakeTransport(responses = {}) {
  const calls = [];
  return {
    calls,
    closes: 0,
    async send(req) {
      calls.push(req);
      return responses[req.token] ?? { status: 200, apnsId: 'x' };
    },
    close() { this.closes++; },
  };
}

export const ENV_KEY_ID = 'ABC123DEFG';
export const ENV_TEAM_ID = 'TEAM123456';

/** Fake Apple check: answer(creds) → { production, sandbox }; records the credentials it saw. */
export function fakeCheck(answer = () => ({ production: { status: 400, reason: 'BadDeviceToken' }, sandbox: { status: 400, reason: 'BadDeviceToken' } })) {
  const fn = async (creds) => { fn.calls.push(creds); return answer(creds); };
  fn.calls = [];
  return fn;
}

/** withApns: credentials from the "environment" (as loadConfig would give them). */
export async function startApp({ transport = fakeTransport(), withApns = true, rateLimit, dir, apnsCheck = fakeCheck() } = {}) {
  dir ??= await tempDir();
  const store = await new TokenStore(dir).load();
  const history = await new HistoryStore(dir).load();
  const { privateKey } = newKey();
  const logs = [];
  const log = (m) => logs.push(m);
  const settings = await new ApnsSettingsStore(dir).load();
  const env = withApns ? { key: privateKey, keyId: ENV_KEY_ID, teamId: ENV_TEAM_ID } : null;
  const apns = new ApnsCredentials({ settings, env, transport, log });
  const handler = createApp({
    adminUser: ADMIN_USER,
    adminPassword: ADMIN_PASSWORD,
    store, history, transport, apns, apnsCheck, log,
    rateLimit: rateLimit ?? new RateLimiter({ limit: 1000 }),
  });
  const server = http.createServer(handler);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  return {
    base, store, history, transport, logs, dir, apns, settings, apnsCheck,
    close: () => new Promise((r) => { server.closeAllConnections?.(); server.close(r); }),
  };
}

export const basic = (u = ADMIN_USER, p = ADMIN_PASSWORD) => `Basic ${Buffer.from(`${u}:${p}`).toString('base64')}`;

export async function post(base, p, body, headers = {}, method = 'POST') {
  const res = await fetch(base + p, {
    method,
    headers: { 'content-type': 'application/json', ...headers },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
  const text = await res.text();
  let json = null;
  try { json = JSON.parse(text); } catch { /* empty */ }
  return { status: res.status, json, text, headers: res.headers };
}

export function registration(n, over = {}) {
  return { token: tok(n), environment: 'production', language: 'en', appVersion: '1.2.0', locale: 'zh-Hans_CN', ...over };
}
