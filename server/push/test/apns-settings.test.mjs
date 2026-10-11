// APNs settings from the admin page: validation, storage, precedence over the environment,
// hot reload, the Apple check (faked — no network) and the endpoints' auth / CSRF.
import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import http2 from 'node:http2';
import {
  validateApnsSettings, ApnsSettingsStore, ApnsCredentials, checkWithApple, checkOutcome, explainCheck,
  normalizeCheck, CHECK_TOKEN, KEY_P8_MAX,
} from '../lib/apns-settings.mjs';
import { Http2Transport } from '../lib/apns.mjs';
import {
  startApp, post, basic, registration, tok, newKey, tempDir, fakeCheck, fakeTransport, ENV_KEY_ID, ENV_TEAM_ID,
} from './helpers.mjs';

const pemOf = (privateKey) => privateKey.export({ type: 'pkcs8', format: 'pem' });
const newPem = () => pemOf(newKey().privateKey);
const decode = (part) => JSON.parse(Buffer.from(part, 'base64url').toString('utf8'));
const kidOf = (authorization) => decode(authorization.replace(/^bearer /, '').split('.')[0]).kid;
const keyBody = (pem) => pem.split('\n').filter((l) => l && !l.startsWith('-----')).join('');

const NEW_KEY_ID = 'NEWKEY7890';
const NEW_TEAM_ID = 'NEWTEAM123';
const settingsBody = (pem, over = {}) => ({ keyP8: pem, keyId: NEW_KEY_ID, teamId: NEW_TEAM_ID, ...over });
const rejected = () => ({ production: { status: 403, reason: 'InvalidProviderToken' }, sandbox: { status: 403, reason: 'InvalidProviderToken' } });
const unreachable = () => ({ production: { status: 0, reason: 'network: getaddrinfo ENOTFOUND' }, sandbox: { status: 0, reason: 'network: getaddrinfo ENOTFOUND' } });
const sendBody = { title: '该复习啦', body: '今天还有 20 个单词等你。', environment: 'production' };

const admin = (base, method = 'GET') => fetch(base + '/api/push/admin/apns', { method, headers: { authorization: basic() } });

/** Asserts no key material (PEM text or its base64 body) appears in s. */
function assertNoKey(s, pem, what, { pemText = true } = {}) {
  assert.equal(s.includes(keyBody(pem)), false, `${what} must not contain the key`);
  if (pemText) assert.equal(s.includes('PRIVATE KEY'), false, `${what} must not contain PEM text`);
}

// ------------------------------------------------------------------------------------ validation

test('validate: accepts the .p8 with surrounding whitespace and CRLF; normalises it', () => {
  const pem = newPem();
  const v = validateApnsSettings(settingsBody(`\n\n  ${pem.replace(/\n/g, '\r\n')}  \n`));
  assert.equal(v.ok, true, v.error);
  assert.equal(v.value.keyP8, pem);
  assert.equal(v.value.keyId, NEW_KEY_ID);
  assert.equal(v.value.key.asymmetricKeyType, 'ec');
  assert.equal(validateApnsSettings(settingsBody(pem, { keyId: ` ${NEW_KEY_ID} ` })).ok, true, 'pasted IDs may have spaces around them');
});

test('validate: rejects bad IDs, unknown fields, non-P-256 keys, garbage and oversize input', () => {
  const pem = newPem();
  const bad = (over, re) => {
    const v = validateApnsSettings(typeof over === 'function' ? over() : settingsBody(pem, over));
    assert.equal(v.ok, false, String(JSON.stringify(over)).slice(0, 80));
    if (re) assert.match(v.error, re);
    return v;
  };
  bad({ keyId: 'abc123defg' }, /Key ID/);
  bad({ keyId: 'ABC123DEF' }, /Key ID/);
  bad({ keyId: 'ABC123DEFGH' }, /Key ID/);
  bad({ keyId: 'ABC-23DEFG' }, /Key ID/);
  bad({ keyId: 1234567890 }, /Key ID/);
  bad({ teamId: 'team123456' }, /Team ID/);
  bad({ teamId: undefined }, /Team ID/);
  bad({ keyP8: '' }, /\.p8/);
  bad({ keyP8: 42 }, /\.p8/);
  bad({ keyP8: 'hello' }, /BEGIN/);
  bad({ keyP8: '-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----' }, /无法识别/);
  bad({ keyP8: pem + 'x'.repeat(KEY_P8_MAX) }, /4 KB/);
  bad({ extra: 1 }, /不认识的字段/);
  bad(() => null, /JSON/);
  bad(() => [pem], /JSON/);
  // Other key types parse but are not APNs keys.
  bad({ keyP8: pemOf(crypto.generateKeyPairSync('ed25519').privateKey) }, /P-256/);
  bad({ keyP8: pemOf(crypto.generateKeyPairSync('ec', { namedCurve: 'P-384' }).privateKey) }, /P-256/);
  bad({ keyP8: pemOf(crypto.generateKeyPairSync('rsa', { modulusLength: 1024 }).privateKey) }, /P-256/);
  // A public key is not a private key.
  bad({ keyP8: newKey().publicKey.export({ type: 'spki', format: 'pem' }) });
  // Error messages never echo the key.
  const v = bad({ keyId: 'nope' });
  assert.equal(v.error.includes(keyBody(pem)), false);
});

// ------------------------------------------------------------------------------------ storage

test('store: persists apns.json with mode 600 and survives reload; clear() removes it', async () => {
  const dir = await tempDir();
  const pem = newPem();
  const s = await new ApnsSettingsStore(dir).load();
  assert.equal(s.get(), null);
  await s.save({ keyP8: pem, keyId: NEW_KEY_ID, teamId: NEW_TEAM_ID }, new Date('2026-10-11T00:00:00Z'));
  const file = path.join(dir, 'apns.json');
  const st = await fs.stat(file);
  assert.equal(st.mode & 0o777, 0o600);
  const again = await new ApnsSettingsStore(dir).load();
  assert.equal(again.get().keyP8, pem);
  assert.equal(again.get().updatedAt, '2026-10-11T00:00:00.000Z');
  await again.setLastCheck({ at: 'x' });
  assert.equal((await fs.stat(file)).mode & 0o777, 0o600, 'still 600 after a rewrite');
  assert.deepEqual((await new ApnsSettingsStore(dir).load()).get().lastCheck, { at: 'x' });
  await again.clear();
  await assert.rejects(fs.stat(file), { code: 'ENOENT' });
  assert.equal((await new ApnsSettingsStore(dir).load()).get(), null);
});

test('credentials: saved settings win over the environment, also after a restart', async () => {
  const dir = await tempDir();
  const env = { key: newKey().privateKey, keyId: ENV_KEY_ID, teamId: ENV_TEAM_ID };
  const settings = await new ApnsSettingsStore(dir).load();
  const c = new ApnsCredentials({ settings, env });
  assert.equal(c.source, 'env');
  assert.equal(kidOf(`bearer ${c.providerToken.get()}`), ENV_KEY_ID);
  await c.save({ keyP8: newPem(), keyId: NEW_KEY_ID, teamId: NEW_TEAM_ID }, null);
  assert.equal(c.source, 'admin');
  // "Restart": a fresh process reads apns.json and still prefers it.
  const restarted = new ApnsCredentials({ settings: await new ApnsSettingsStore(dir).load(), env });
  assert.equal(restarted.source, 'admin');
  assert.equal(restarted.status().keyId, NEW_KEY_ID);
  assert.equal(kidOf(`bearer ${restarted.providerToken.get()}`), NEW_KEY_ID);
  // Without env credentials the saved ones still work.
  assert.equal(new ApnsCredentials({ settings: await new ApnsSettingsStore(dir).load() }).source, 'admin');
});

test('credentials: an unusable apns.json falls back to the environment (with a warning, no key in the log)', async () => {
  const dir = await tempDir();
  await fs.writeFile(path.join(dir, 'apns.json'), JSON.stringify({ keyP8: '-----BEGIN PRIVATE KEY-----\nbroken\n-----END PRIVATE KEY-----\n', keyId: NEW_KEY_ID, teamId: NEW_TEAM_ID }));
  const logs = [];
  const c = new ApnsCredentials({ settings: await new ApnsSettingsStore(dir).load(), env: { key: newKey().privateKey, keyId: ENV_KEY_ID, teamId: ENV_TEAM_ID }, log: (m) => logs.push(m) });
  assert.equal(c.source, 'env');
  assert.match(logs.join('\n'), /unusable/);
  assert.equal(logs.join('\n').includes('broken'), false);
});

test('hot reload drops the cached JWT and closes the HTTP/2 sessions', async (t) => {
  const server = http2.createServer();
  const sessions = new Set();
  server.on('session', (s) => sessions.add(s));
  server.on('stream', (stream) => { stream.respond({ ':status': 200 }); stream.end(); });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const origin = `http://127.0.0.1:${server.address().port}`;
  const transport = new Http2Transport({ origins: { production: origin, sandbox: origin } });
  t.after(() => new Promise((r) => { transport.close(); for (const s of sessions) s.destroy(); server.close(r); }));

  const dir = await tempDir();
  const c = new ApnsCredentials({ settings: await new ApnsSettingsStore(dir).load(), env: { key: newKey().privateKey, keyId: ENV_KEY_ID, teamId: ENV_TEAM_ID }, transport });
  const before = c.providerToken;
  const jwt = before.get();
  assert.equal((await transport.send({ environment: 'production', token: tok(1), headers: {}, payload: {} })).status, 200);
  assert.equal(transport.sessions.size, 1);

  await c.save({ keyP8: newPem(), keyId: NEW_KEY_ID, teamId: NEW_TEAM_ID }, null);
  assert.equal(transport.sessions.size, 0, 'sessions closed');
  assert.notEqual(c.providerToken, before, 'new token cache');
  assert.notEqual(c.providerToken.get(), jwt);
  assert.equal(kidOf(`bearer ${c.providerToken.get()}`), NEW_KEY_ID);
  assert.equal((await transport.send({ environment: 'production', token: tok(1), headers: {}, payload: {} })).status, 200, 'reconnects');
});

// ------------------------------------------------------------------------------------ the Apple check

test('checkWithApple: pushes to a 64-zero token on both environments; 400 BadDeviceToken = accepted', async () => {
  const transport = fakeTransport({ [CHECK_TOKEN]: { status: 400, reason: 'BadDeviceToken' } });
  const { privateKey } = newKey();
  const r = await checkWithApple({ key: privateKey, keyId: NEW_KEY_ID, teamId: NEW_TEAM_ID, transport });
  assert.deepEqual(r.production, { ok: true, status: 400, reason: 'BadDeviceToken' });
  assert.deepEqual(r.sandbox, { ok: true, status: 400, reason: 'BadDeviceToken' });
  assert.deepEqual(transport.calls.map((c) => c.environment).sort(), ['production', 'sandbox']);
  for (const c of transport.calls) {
    assert.equal(c.token, '0'.repeat(64));
    assert.equal(c.headers['apns-topic'], 'com.vocabloop.app');
    assert.equal(kidOf(c.headers.authorization), NEW_KEY_ID);
    assert.equal(decode(c.headers.authorization.split('.')[1]).iss, NEW_TEAM_ID);
  }
  const bad = await checkWithApple({ key: privateKey, keyId: NEW_KEY_ID, teamId: NEW_TEAM_ID, transport: fakeTransport({ [CHECK_TOKEN]: { status: 403, reason: 'InvalidProviderToken' } }) });
  assert.equal(bad.production.ok, false);
  const thrown = await checkWithApple({ key: privateKey, keyId: NEW_KEY_ID, teamId: NEW_TEAM_ID, transport: { async send() { throw new Error('boom'); }, close() {} } });
  assert.equal(thrown.sandbox.status, 0);
});

test('check outcome and Chinese explanations', () => {
  const at = '2026-10-11T00:00:00.000Z';
  const ok = normalizeCheck({ production: { status: 400, reason: 'BadDeviceToken' }, sandbox: { status: 400, reason: 'BadDeviceToken' } }, at);
  assert.equal(checkOutcome(ok), 'ok');
  assert.match(explainCheck(ok), /Apple 接受了/);
  const no = normalizeCheck(rejected(), at);
  assert.equal(checkOutcome(no), 'rejected');
  assert.match(explainCheck(no), /Key ID、Team ID 和 \.p8 对不上/);
  assert.match(explainCheck(no), /403 InvalidProviderToken/);
  assert.match(explainCheck(normalizeCheck({ production: { status: 400, reason: 'TopicDisallowed' }, sandbox: { status: 400, reason: 'BadDeviceToken' } }, at)), /com\.vocabloop\.app/);
  assert.equal(checkOutcome(normalizeCheck({ production: { status: 400, reason: 'BadDeviceToken' }, sandbox: { status: 403, reason: 'Forbidden' } }, at)), 'rejected', 'both environments must accept');
  const net = normalizeCheck(unreachable(), at);
  assert.equal(checkOutcome(net), 'network');
  assert.match(explainCheck(net), /连不上 Apple/);
  assert.equal(checkOutcome(normalizeCheck(undefined, at)), 'network');
});

// ------------------------------------------------------------------------------------ endpoints

test('GET /api/push/admin/apns: env source, and the shape never contains the key', async (t) => {
  const app = await startApp();
  t.after(app.close);
  const r = await admin(app.base);
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), { configured: true, source: 'env', keyId: ENV_KEY_ID, teamId: ENV_TEAM_ID, updatedAt: null, lastCheck: null });

  const none = await startApp({ withApns: false });
  t.after(none.close);
  assert.deepEqual(await (await admin(none.base)).json(), { configured: false, source: null, keyId: null, teamId: null, updatedAt: null, lastCheck: null });
});

test('POST saves after Apple accepts: persisted (600), hot-reloaded, never returned or logged', async (t) => {
  const transport = fakeTransport();
  const app = await startApp({ transport });
  t.after(app.close);
  await post(app.base, '/api/push/register', registration(1));
  // A send with the env credentials first, so there is a cached JWT to drop.
  await post(app.base, '/api/push/send', sendBody, { authorization: basic() });
  assert.equal(kidOf(transport.calls[0].headers.authorization), ENV_KEY_ID);
  const closesBefore = transport.closes;

  const pem = newPem();
  const host = new URL(app.base).host;
  const r = await post(app.base, '/api/push/admin/apns', settingsBody(`  ${pem}\n\n`), { authorization: basic(), origin: `http://${host}` });
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.configured, true);
  assert.equal(r.json.source, 'admin');
  assert.equal(r.json.keyId, NEW_KEY_ID);
  assert.equal(r.json.teamId, NEW_TEAM_ID);
  assert.ok(Date.parse(r.json.updatedAt));
  assert.equal(r.json.lastCheck.production.ok, true);
  assert.equal(r.json.lastCheck.sandbox.ok, true);
  assert.match(r.json.message, /Apple 接受了/);
  assertNoKey(r.text, pem, 'POST response');

  // The check ran with the submitted credentials.
  assert.equal(app.apnsCheck.calls.length, 1);
  assert.equal(app.apnsCheck.calls[0].keyId, NEW_KEY_ID);
  assert.equal(app.apnsCheck.calls[0].teamId, NEW_TEAM_ID);

  // Persisted with mode 600.
  const file = path.join(app.dir, 'apns.json');
  assert.equal((await fs.stat(file)).mode & 0o777, 0o600);
  const saved = JSON.parse(await fs.readFile(file, 'utf8'));
  assert.equal(saved.keyP8, pem);
  assert.equal(saved.keyId, NEW_KEY_ID);

  // Hot reload: the next send signs with the new key ID; sessions were dropped.
  assert.ok(transport.closes > closesBefore, 'HTTP/2 sessions closed');
  await post(app.base, '/api/push/send', sendBody, { authorization: basic() });
  assert.equal(kidOf(transport.calls.at(-1).headers.authorization), NEW_KEY_ID);

  // GET, overview, health and the admin page never contain the key.
  const g = await (await admin(app.base)).text();
  assertNoKey(g, pem, 'GET');
  assert.equal(JSON.parse(g).source, 'admin');
  assertNoKey(await (await fetch(app.base + '/api/push/admin/overview', { headers: { authorization: basic() } })).text(), pem, 'overview');
  assertNoKey(await (await fetch(app.base + '/push-admin', { headers: { authorization: basic() } })).text(), pem, 'admin page', { pemText: false });
  const h = await (await fetch(app.base + '/api/push/health')).json();
  assert.equal(h.apns, true);
  assertNoKey(JSON.stringify(h), pem, 'health');

  // Logs: the update line with the Key ID's last 4, never the key.
  assert.ok(app.logs.includes('apns settings updated (key …7890)'), app.logs.join('\n'));
  for (const line of app.logs) assertNoKey(line, pem, 'log line');
});

test('POST: a key Apple rejects is not saved → 400 with the reasons in Chinese', async (t) => {
  const app = await startApp({ apnsCheck: fakeCheck(rejected) });
  t.after(app.close);
  const pem = newPem();
  const r = await post(app.base, '/api/push/admin/apns', settingsBody(pem), { authorization: basic() });
  assert.equal(r.status, 400);
  assert.match(r.json.error, /Apple 没有接受这把密钥/);
  assert.match(r.json.error, /InvalidProviderToken/);
  assert.match(r.json.error, /没有保存/);
  assert.equal(r.json.check.production.ok, false);
  assertNoKey(r.text, pem, 'error response');
  await assert.rejects(fs.stat(path.join(app.dir, 'apns.json')), { code: 'ENOENT' });
  assert.equal((await (await admin(app.base)).json()).source, 'env', 'still the environment credentials');
  for (const line of app.logs) assertNoKey(line, pem, 'log line');
});

test('POST: Apple unreachable → 502 and nothing saved (also when the check throws)', async (t) => {
  for (const apnsCheck of [fakeCheck(unreachable), fakeCheck(() => { throw new Error('ETIMEDOUT'); })]) {
    const app = await startApp({ withApns: false, apnsCheck });
    t.after(app.close);
    const r = await post(app.base, '/api/push/admin/apns', settingsBody(newPem()), { authorization: basic() });
    assert.equal(r.status, 502);
    assert.match(r.json.error, /连不上 Apple/);
    await assert.rejects(fs.stat(path.join(app.dir, 'apns.json')), { code: 'ENOENT' });
    assert.equal((await (await admin(app.base)).json()).configured, false);
  }
});

test('POST: invalid input → 400 before Apple is asked', async (t) => {
  const app = await startApp();
  t.after(app.close);
  const pem = newPem();
  for (const body of [settingsBody(pem, { keyId: 'short' }), settingsBody('not a key'), settingsBody(pem, { more: 1 })]) {
    const r = await post(app.base, '/api/push/admin/apns', body, { authorization: basic() });
    assert.equal(r.status, 400, JSON.stringify(body).slice(0, 60));
  }
  assert.equal((await post(app.base, '/api/push/admin/apns', '{bad', { authorization: basic() })).status, 400);
  const big = await post(app.base, '/api/push/admin/apns', settingsBody('x'.repeat(9000)), { authorization: basic() });
  assert.equal(big.status, 413);
  assert.equal(app.apnsCheck.calls.length, 0);
});

test('DELETE removes the saved settings and falls back to the environment', async (t) => {
  const app = await startApp();
  t.after(app.close);
  assert.equal((await post(app.base, '/api/push/admin/apns', settingsBody(newPem()), { authorization: basic() })).status, 200);
  const d = await post(app.base, '/api/push/admin/apns', {}, { authorization: basic() }, 'DELETE');
  assert.equal(d.status, 200, d.text);
  assert.deepEqual(d.json, { configured: true, source: 'env', keyId: ENV_KEY_ID, teamId: ENV_TEAM_ID, updatedAt: null, lastCheck: null });
  await assert.rejects(fs.stat(path.join(app.dir, 'apns.json')), { code: 'ENOENT' });
  assert.match(app.logs.join('\n'), /apns settings removed/);

  // Without env credentials, DELETE leaves APNs unconfigured and sending is refused.
  const bare = await startApp({ withApns: false });
  t.after(bare.close);
  await post(bare.base, '/api/push/register', registration(1));
  await post(bare.base, '/api/push/admin/apns', settingsBody(newPem()), { authorization: basic() });
  assert.equal((await (await fetch(bare.base + '/api/push/health')).json()).apns, true);
  assert.equal((await post(bare.base, '/api/push/send', sendBody, { authorization: basic() })).status, 200);
  const d2 = await post(bare.base, '/api/push/admin/apns', {}, { authorization: basic() }, 'DELETE');
  assert.equal(d2.json.configured, false);
  assert.equal((await (await fetch(bare.base + '/api/push/health')).json()).apns, false);
  assert.equal((await post(bare.base, '/api/push/send', sendBody, { authorization: basic() })).status, 503);
});

test('POST /api/push/admin/apns/check re-runs the check with the current credentials and records it', async (t) => {
  let answer = () => ({ production: { status: 400, reason: 'BadDeviceToken' }, sandbox: { status: 400, reason: 'BadDeviceToken' } });
  const apnsCheck = fakeCheck((c) => answer(c));
  const app = await startApp({ apnsCheck });
  t.after(app.close);
  const r = await post(app.base, '/api/push/admin/apns/check', {}, { authorization: basic() });
  assert.equal(r.status, 200, r.text);
  assert.equal(r.json.ok, true);
  assert.equal(r.json.source, 'env');
  assert.equal(apnsCheck.calls[0].keyId, ENV_KEY_ID);
  assert.equal(r.json.lastCheck.production.ok, true);
  assert.equal((await (await admin(app.base)).json()).lastCheck.sandbox.ok, true, 'recorded for env credentials');

  answer = rejected;
  const bad = await post(app.base, '/api/push/admin/apns/check', '', { authorization: basic() });
  assert.equal(bad.status, 200);
  assert.equal(bad.json.ok, false);
  assert.match(bad.json.message, /InvalidProviderToken/);

  // Saved settings: the check uses them and the result is persisted in apns.json.
  answer = () => ({ production: { status: 400, reason: 'BadDeviceToken' }, sandbox: { status: 400, reason: 'BadDeviceToken' } });
  await post(app.base, '/api/push/admin/apns', settingsBody(newPem()), { authorization: basic() });
  answer = () => ({ production: { status: 400, reason: 'BadDeviceToken' }, sandbox: { status: 403, reason: 'Forbidden' } });
  const again = await post(app.base, '/api/push/admin/apns/check', {}, { authorization: basic() });
  assert.equal(apnsCheck.calls.at(-1).keyId, NEW_KEY_ID);
  assert.equal(again.json.ok, false);
  const saved = JSON.parse(await fs.readFile(path.join(app.dir, 'apns.json'), 'utf8'));
  assert.equal(saved.lastCheck.sandbox.reason, 'Forbidden');

  const none = await startApp({ withApns: false });
  t.after(none.close);
  assert.equal((await post(none.base, '/api/push/admin/apns/check', {}, { authorization: basic() })).status, 409);
});

test('APNs settings endpoints: Basic auth, same-origin and JSON content type required', async (t) => {
  const app = await startApp();
  t.after(app.close);
  const pem = newPem();
  const body = settingsBody(pem);
  const P = '/api/push/admin/apns', C = '/api/push/admin/apns/check';

  // No / wrong credentials.
  assert.equal((await fetch(app.base + P)).status, 401);
  assert.equal((await post(app.base, P, body)).status, 401);
  assert.equal((await post(app.base, P, body, { authorization: basic('admin', 'wrong-password!') })).status, 401);
  assert.equal((await post(app.base, P, {}, {}, 'DELETE')).status, 401);
  assert.equal((await post(app.base, C, {})).status, 401);

  // Cross-origin, even with credentials.
  const evil = { authorization: basic(), origin: 'https://evil.example' };
  assert.equal((await post(app.base, P, body, evil)).status, 403);
  assert.equal((await post(app.base, P, {}, evil, 'DELETE')).status, 403);
  assert.equal((await post(app.base, C, {}, evil)).status, 403);

  // Form-style content types never reach the handlers.
  const plain = { authorization: basic(), 'content-type': 'text/plain' };
  assert.equal((await post(app.base, P, JSON.stringify(body), plain)).status, 415);
  assert.equal((await post(app.base, P, '{}', plain, 'DELETE')).status, 415);
  assert.equal((await post(app.base, C, '{}', { authorization: basic(), 'content-type': 'application/x-www-form-urlencoded' })).status, 415);
  assert.equal((await post(app.base, C, { x: 1 }, { authorization: basic() })).status, 400);

  // Wrong methods.
  assert.equal((await fetch(app.base + P, { method: 'PUT', headers: { authorization: basic() } })).status, 405);
  assert.equal((await fetch(app.base + C, { headers: { authorization: basic() } })).status, 405);

  // Nothing was checked or saved by any of these.
  assert.equal(app.apnsCheck.calls.length, 0);
  await assert.rejects(fs.stat(path.join(app.dir, 'apns.json')), { code: 'ENOENT' });
  assert.equal((await (await admin(app.base)).json()).source, 'env');
});

test('admin page has the 推送设置 card and keeps rendering with textContent only', async (t) => {
  const app = await startApp();
  t.after(app.close);
  const html = await (await fetch(app.base + '/push-admin', { headers: { authorization: basic() } })).text();
  assert.match(html, /推送设置（Apple 推送密钥）/);
  assert.match(html, /粘贴 \.p8 文件的全部内容（包括 BEGIN\/END 两行）/);
  assert.match(html, /保存并检查/);
  assert.match(html, /重新检查/);
  assert.match(html, /Certificates, IDs &amp; Profiles → Keys/);
  assert.ok(html.indexOf('id="apnsCard"') < html.indexOf('id="form"'), 'settings card is above the send form');
  assert.match(html, /id="send" class="primary" disabled/);
  assert.equal(/innerHTML/.test(html), false);
});
