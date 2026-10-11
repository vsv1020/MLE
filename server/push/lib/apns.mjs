// APNs HTTP/2 transport and the fan-out sender.
//
// The transport is the only part that touches the network. It is injected into the app so the
// tests can replace it with a fake: transport.send({ environment, token, headers, payload })
// resolves to { status, reason?, timestamp?, apnsId? } (status 0 = network error, never sent).
import http2 from 'node:http2';
import { tokenTail } from './validate.mjs';

export const APNS_TOPIC = 'com.vocabloop.app';
export const APNS_HOSTS = {
  production: 'api.push.apple.com',
  sandbox: 'api.sandbox.push.apple.com',
};
export const CONCURRENCY = 20;
const REQUEST_TIMEOUT_MS = 15_000;
const IDLE_CLOSE_MS = 5 * 60 * 1000;

const DEFAULT_ORIGINS = Object.fromEntries(Object.entries(APNS_HOSTS).map(([env, host]) => [env, `https://${host}:443`]));

export class Http2Transport {
  /** origins: environment -> origin URL (overridable for tests). */
  constructor({ origins = DEFAULT_ORIGINS, log = () => {} } = {}) {
    this.origins = origins;
    this.log = log;
    this.sessions = new Map(); // origin -> ClientHttp2Session (one per host, reused)
  }

  session(host) {
    let s = this.sessions.get(host);
    if (s && !s.closed && !s.destroyed) return s;
    s = http2.connect(host);
    const forget = () => { if (this.sessions.get(host) === s) this.sessions.delete(host); };
    s.on('error', (e) => { this.log(`apns ${host} session error: ${e.message}`); forget(); });
    // GOAWAY: APNs is closing the connection (e.g. maintenance). Stop using it; in-flight
    // streams finish or fail and get retried on a fresh session.
    s.on('goaway', (code) => { this.log(`apns ${host} GOAWAY (code ${code}), reconnecting on next request`); forget(); });
    s.on('close', forget);
    s.setTimeout(IDLE_CLOSE_MS, () => { forget(); s.close(); });
    s.unref?.();
    this.sessions.set(host, s);
    return s;
  }

  requestOnce(host, path, headers, body) {
    return new Promise((resolve) => {
      let settled = false;
      const done = (r) => { if (!settled) { settled = true; resolve(r); } };
      let req;
      try {
        req = this.session(host).request({ ':method': 'POST', ':path': path, ...headers });
      } catch (e) {
        return done({ status: 0, reason: `network: ${e.message}` });
      }
      let status = 0, apnsId, data = '';
      req.setTimeout(REQUEST_TIMEOUT_MS, () => { req.close(http2.constants.NGHTTP2_CANCEL); done({ status: 0, reason: 'network: timeout' }); });
      req.on('response', (h) => { status = h[':status']; apnsId = h['apns-id']; });
      req.setEncoding('utf8');
      req.on('data', (d) => { if (data.length < 4096) data += d; });
      req.on('end', () => {
        let reason, timestamp;
        if (data) { try { ({ reason, timestamp } = JSON.parse(data)); } catch { reason = data.slice(0, 200); } }
        done({ status, reason, timestamp, apnsId });
      });
      req.on('error', (e) => done({ status: 0, reason: `network: ${e.message}` }));
      req.on('close', () => done({ status, reason: status ? undefined : 'network: stream closed' }));
      req.end(body);
    });
  }

  async send({ environment, token, headers, payload }) {
    const host = this.origins[environment];
    const body = JSON.stringify(payload);
    const path = `/3/device/${token}`;
    let r = await this.requestOnce(host, path, headers, body);
    if (r.status === 0 && r.reason !== 'network: timeout') {
      // Connection-level failure (GOAWAY, reset, refused): retry once on a fresh session.
      // Timeouts are not retried: APNs may have delivered it, and a duplicate alert is worse.
      const s = this.sessions.get(host);
      if (s) { this.sessions.delete(host); s.close(); }
      r = await this.requestOnce(host, path, headers, body);
    }
    return r;
  }

  close() {
    for (const s of this.sessions.values()) s.close();
    this.sessions.clear();
  }
}

/** APNs answers that mean the token will never work again → delete it. */
export function shouldRemoveToken(result, record) {
  if (result.status === 410) {
    // Apple: only remove if the token was not re-registered after APNs saw it become invalid.
    if (typeof result.timestamp === 'number' && record?.updatedAt) {
      return result.timestamp >= Date.parse(record.updatedAt);
    }
    return true;
  }
  return result.status === 400 && (result.reason === 'BadDeviceToken' || result.reason === 'DeviceTokenNotForTopic');
}

export function buildPayload(title, body) {
  return { aps: { alert: { title, body }, sound: 'default' } };
}

/**
 * Send one alert to many tokens with bounded concurrency.
 * targets: [{ token, updatedAt, ... }]. Returns { sent, failed, removedTokens, reasons }.
 */
export async function sendToAll({ transport, providerToken, targets, environment, title, body, topic = APNS_TOPIC, concurrency = CONCURRENCY, log = () => {} }) {
  const payload = buildPayload(title, body);
  let sent = 0, failed = 0, next = 0;
  const removedTokens = [];
  const reasons = {};

  async function one(target) {
    const headers = {
      authorization: `bearer ${providerToken.get()}`,
      'apns-topic': topic,
      'apns-push-type': 'alert',
      'apns-priority': '5',
      'content-type': 'application/json',
    };
    let r;
    try {
      r = await transport.send({ environment, token: target.token, headers, payload });
    } catch (e) {
      r = { status: 0, reason: `network: ${e.message}` };
    }
    if (r.status === 200) { sent++; return; }
    failed++;
    const reason = r.reason || `HTTP ${r.status}`;
    reasons[reason] = (reasons[reason] || 0) + 1;
    if (r.status === 403 && r.reason === 'ExpiredProviderToken') providerToken.invalidate?.();
    if (shouldRemoveToken(r, target)) removedTokens.push(target.token);
    log(`apns ${environment} ${tokenTail(target.token)} -> ${r.status} ${reason}`);
  }

  async function worker() {
    while (next < targets.length) await one(targets[next++]);
  }
  await Promise.all(Array.from({ length: Math.min(concurrency, targets.length) }, worker));
  return { sent, failed, removedTokens, reasons };
}
