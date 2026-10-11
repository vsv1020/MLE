// APNs credentials (the .p8 key, Key ID, Team ID) set from the admin page.
//
// - ApnsSettingsStore: DATA_DIR/apns.json, written atomically with mode 600.
// - ApnsCredentials: the credentials in use. Settings saved from the admin page win over the
//   environment (APNS_KEY_PATH / APNS_KEY_P8 / APNS_KEY_ID / APPLE_TEAM_ID); reload() swaps them
//   in without a restart (new ProviderToken = no cached JWT, and the HTTP/2 sessions are closed).
// - checkWithApple: the same test as scripts/apns-check.mjs — a push to a made-up device token on
//   both environments. Apple checks the provider token first, so 400 BadDeviceToken = accepted.
//
// The key itself is never logged and never returned by any endpoint.
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import { atomicWriteJSON, readJSONFile } from './storage.mjs';
import { ProviderToken, signProviderToken } from './jwt.mjs';
import { Http2Transport, APNS_TOPIC } from './apns.mjs';

export const KEY_P8_MAX = 4096;
export const ID_RE = /^[A-Z0-9]{10}$/;
export const CHECK_TOKEN = '0'.repeat(64);
const ENVS = ['production', 'sandbox'];

const isPlainObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const fail = (error) => ({ ok: false, error });

/** Last 4 characters of the Key ID, for log lines. */
export const keyTail = (keyId) => `…${String(keyId || '').slice(-4)}`;

/** Parses the .p8 text. Returns a KeyObject or throws an Error with a Chinese message. */
export function parseApnsKey(pem) {
  let key;
  try {
    key = crypto.createPrivateKey({ key: pem, format: 'pem' });
  } catch {
    throw new Error('.p8 内容无法识别：请用文本编辑器打开 AuthKey_XXXXXXXXXX.p8，把全部内容（包括 BEGIN 和 END 两行）原样粘贴进来');
  }
  if (key.asymmetricKeyType !== 'ec' || key.asymmetricKeyDetails?.namedCurve !== 'prime256v1') {
    throw new Error('这不是 Apple 推送用的密钥（需要 EC P-256 私钥，也就是 AuthKey_XXXXXXXXXX.p8）');
  }
  return key;
}

/** Validates the POST body. Returns { ok, value: { keyP8, keyId, teamId, key } } or { ok: false, error }. */
export function validateApnsSettings(obj) {
  if (!isPlainObject(obj)) return fail('请求格式不对（需要 JSON 对象）');
  for (const k of Object.keys(obj)) if (!['keyP8', 'keyId', 'teamId'].includes(k)) return fail(`不认识的字段：${k.slice(0, 40)}`);
  const keyId = typeof obj.keyId === 'string' ? obj.keyId.trim() : '';
  if (!ID_RE.test(keyId)) return fail('Key ID 必须正好是 10 位大写字母或数字（例如 ABC123DEFG）');
  const teamId = typeof obj.teamId === 'string' ? obj.teamId.trim() : '';
  if (!ID_RE.test(teamId)) return fail('Team ID 必须正好是 10 位大写字母或数字（例如 TEAM123456）');
  if (typeof obj.keyP8 !== 'string' || !obj.keyP8.trim()) return fail('请粘贴 .p8 文件的全部内容');
  if (Buffer.byteLength(obj.keyP8, 'utf8') > KEY_P8_MAX) return fail('.p8 内容太长（最多 4 KB），请确认粘贴的是 AuthKey_XXXXXXXXXX.p8');
  const keyP8 = obj.keyP8.replace(/\r\n?/g, '\n').trim() + '\n';
  if (!keyP8.startsWith('-----BEGIN ')) return fail('.p8 内容要从 -----BEGIN PRIVATE KEY----- 这一行开始');
  let key;
  try { key = parseApnsKey(keyP8); } catch (e) { return fail(e.message); }
  return { ok: true, value: { keyP8, keyId, teamId, key } };
}

export class ApnsSettingsStore {
  constructor(dataDir) {
    this.file = path.join(dataDir, 'apns.json');
    this.data = null;
  }

  async load() {
    await fs.mkdir(path.dirname(this.file), { recursive: true, mode: 0o700 });
    const d = await readJSONFile(this.file);
    this.data = isPlainObject(d) && typeof d.keyP8 === 'string' ? d : null;
    return this;
  }

  get() { return this.data; }

  async save({ keyP8, keyId, teamId, lastCheck = null }, now = new Date()) {
    const d = { version: 1, keyP8, keyId, teamId, updatedAt: now.toISOString(), lastCheck };
    await atomicWriteJSON(this.file, d);
    this.data = d;
  }

  async setLastCheck(lastCheck) {
    if (!this.data) return;
    const d = { ...this.data, lastCheck };
    await atomicWriteJSON(this.file, d);
    this.data = d;
  }

  async clear() {
    await fs.rm(this.file, { force: true });
    this.data = null;
  }
}

export class ApnsCredentials {
  /**
   * settings: ApnsSettingsStore (or null); env: { key, keyId, teamId } from the environment or null;
   * transport: its close() drops the HTTP/2 sessions on reload.
   */
  constructor({ settings = null, env = null, transport = null, log = () => {}, clock } = {}) {
    this.settings = settings;
    this.env = env;
    this.transport = transport;
    this.log = log;
    this.clock = clock;
    this.envLastCheck = null;
    this.active = null;
    this.providerToken = null;
    this.reload();
  }

  /** Recomputes the active credentials: saved settings first, then the environment. */
  reload() {
    this.active = null;
    const s = this.settings?.get();
    if (s) {
      try {
        if (!ID_RE.test(s.keyId) || !ID_RE.test(s.teamId)) throw new Error('Key ID / Team ID 格式不对');
        this.active = { source: 'admin', key: parseApnsKey(s.keyP8), keyId: s.keyId, teamId: s.teamId };
      } catch {
        this.log('warning: the APNs settings saved in apns.json are unusable; falling back to the environment');
      }
    }
    if (!this.active && this.env) this.active = { source: 'env', ...this.env };
    const opts = this.active ? { key: this.active.key, keyId: this.active.keyId, teamId: this.active.teamId } : null;
    if (opts && this.clock) opts.clock = this.clock;
    this.providerToken = opts ? new ProviderToken(opts) : null; // fresh token cache
    try { this.transport?.close?.(); } catch { /* nothing to close */ }
    return this;
  }

  get configured() { return Boolean(this.providerToken); }
  get source() { return this.active?.source ?? null; }

  /** { key, keyId, teamId } in use, for the Apple check. */
  current() {
    return this.active ? { key: this.active.key, keyId: this.active.keyId, teamId: this.active.teamId } : null;
  }

  lastCheck() {
    if (this.source === 'admin') return this.settings.get()?.lastCheck ?? null;
    if (this.source === 'env') return this.envLastCheck;
    return null;
  }

  /** What the admin page may see. Never contains the key. */
  status() {
    return {
      configured: this.configured,
      source: this.source,
      keyId: this.active?.keyId ?? null,
      teamId: this.active?.teamId ?? null,
      updatedAt: this.source === 'admin' ? this.settings.get()?.updatedAt ?? null : null,
      lastCheck: this.lastCheck(),
    };
  }

  async save({ keyP8, keyId, teamId }, lastCheck, now) {
    await this.settings.save({ keyP8, keyId, teamId, lastCheck }, now);
    this.reload();
    this.log(`apns settings updated (key ${keyTail(keyId)})`);
  }

  async clear() {
    const had = Boolean(this.settings?.get());
    await this.settings.clear();
    this.envLastCheck = null;
    this.reload();
    if (had) this.log(`apns settings removed (now ${this.source === 'env' ? `using the environment, key ${keyTail(this.active.keyId)}` : 'not configured'})`);
  }

  async recordCheck(lastCheck) {
    if (this.source === 'admin') await this.settings.setLastCheck(lastCheck);
    else if (this.source === 'env') this.envLastCheck = lastCheck;
  }
}

function summarize(r) {
  const status = Number(r?.status) || 0;
  const reason = r?.reason ? String(r.reason).slice(0, 200) : null;
  return { ok: status === 400 && reason === 'BadDeviceToken', status, reason };
}

/**
 * Asks Apple whether it accepts these credentials (both environments, in parallel).
 * Resolves to { production: { ok, status, reason }, sandbox: {...} }; status 0 = network failure.
 */
export async function checkWithApple({ key, keyId, teamId, topic = APNS_TOPIC, transport }) {
  const own = !transport;
  const t = transport ?? new Http2Transport();
  try {
    const headers = {
      authorization: `bearer ${signProviderToken({ key, keyId, teamId })}`,
      'apns-topic': topic,
      'apns-push-type': 'alert',
      'content-type': 'application/json',
    };
    const payload = { aps: { alert: 'check' } };
    const results = await Promise.all(ENVS.map((environment) =>
      t.send({ environment, token: CHECK_TOKEN, headers, payload }).catch((e) => ({ status: 0, reason: `network: ${e.message}` }))));
    return { production: summarize(results[0]), sandbox: summarize(results[1]) };
  } finally {
    if (own) t.close();
  }
}

/** Normalises whatever the (injected) check returned. */
export function normalizeCheck(raw, at) {
  return { at, production: summarize(raw?.production), sandbox: summarize(raw?.sandbox) };
}

/** 'ok' (both accepted), 'network' (Apple not reached) or 'rejected'. */
export function checkOutcome(check) {
  if (ENVS.every((e) => check[e].ok)) return 'ok';
  if (ENVS.some((e) => check[e].status === 0)) return 'network';
  return 'rejected';
}

const ENV_NAMES = { production: '正式环境', sandbox: '测试环境' };
const REASONS = {
  InvalidProviderToken: 'Apple 不认这把密钥：Key ID、Team ID 和 .p8 对不上，或者这把 Key 已被吊销 / 没有勾选 APNs',
  ExpiredProviderToken: '服务器时间不准，Apple 认为签名已过期（在服务器上执行 timedatectl set-ntp true）',
  MissingProviderToken: 'Apple 没有收到签名',
  TopicDisallowed: '这把 Key 所在的开发者团队没有 com.vocabloop.app 这个 App（Team ID 和 Key 要属于同一个团队）',
  BadTopic: 'Apple 不认 com.vocabloop.app 这个 App',
  TooManyProviderTokenUpdates: '短时间内换签名太频繁，过 20 分钟再试',
  Forbidden: 'Apple 拒绝了这次请求',
};

function explainOne(r) {
  if (r.ok) return '通过';
  if (r.status === 0) return `连不上 Apple（${r.reason || 'network'}）`;
  const why = REASONS[r.reason] || 'Apple 没有接受这把密钥';
  return `${why}（${r.status}${r.reason ? ' ' + r.reason : ''}）`;
}

/** One Chinese sentence for the admin page. */
export function explainCheck(check) {
  const outcome = checkOutcome(check);
  const detail = ENVS.map((e) => `${ENV_NAMES[e]}：${explainOne(check[e])}`).join('；');
  if (outcome === 'ok') return `Apple 接受了这把密钥（${detail}）。`;
  if (outcome === 'network') return `连不上 Apple 的推送服务器，没法检查。服务器需要能访问外网 443 端口（api.push.apple.com）。${detail}。`;
  return `Apple 没有接受这把密钥。${detail}。`;
}

export function describeCheckForLog(check) {
  return ENVS.map((e) => `${e} ${check[e].status} ${check[e].reason || ''}`.trim()).join(', ');
}
