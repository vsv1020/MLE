import test from 'node:test';
import assert from 'node:assert/strict';
import { startApp, post, basic, registration, tok, fakeTransport } from './helpers.mjs';
import { RateLimiter, checkBasicAuth, safeEqual } from '../lib/security.mjs';

const send = (over = {}) => ({ title: '该复习啦', body: '今天还有 20 个单词等你。', environment: 'production', ...over });

test('register → 204, upsert, unregister idempotent, health counts', async (t) => {
  const app = await startApp();
  t.after(app.close);
  assert.equal((await post(app.base, '/api/push/register', registration(1))).status, 204);
  assert.equal((await post(app.base, '/api/push/register', registration(1, { language: 'fr' }))).status, 204);
  assert.equal((await post(app.base, '/api/push/register', registration(2, { environment: 'sandbox' }))).status, 204);
  assert.equal(app.store.size, 2);
  assert.equal(app.store.get(tok(1)).language, 'fr');

  let h = await (await fetch(app.base + '/api/push/health')).json();
  assert.deepEqual(h.tokens, { production: 1, sandbox: 1 });
  assert.equal(h.ok, true);
  assert.equal(JSON.stringify(h).includes(tok(1)), false, 'health exposes no tokens');

  assert.equal((await post(app.base, '/api/push/unregister', { token: tok(1) })).status, 204);
  assert.equal((await post(app.base, '/api/push/unregister', { token: tok(1) })).status, 204);
  h = await (await fetch(app.base + '/api/push/health')).json();
  assert.deepEqual(h.tokens, { production: 0, sandbox: 1 });

  // Logs never contain a full token.
  assert.ok(app.logs.length > 0);
  for (const line of app.logs) assert.equal(line.includes(tok(1)) || line.includes(tok(2)), false, line);
});

test('register: bad input → 400, wrong method → 405, non-JSON → 415, big body → 413', async (t) => {
  const app = await startApp();
  t.after(app.close);
  assert.equal((await post(app.base, '/api/push/register', registration(1, { token: 'nothex' }))).status, 400);
  const unk = await post(app.base, '/api/push/register', { ...registration(1), foo: 1 });
  assert.equal(unk.status, 204, 'a newer app may send fields this server does not know');
  assert.equal((await post(app.base, '/api/push/register', '{not json')).status, 400);
  assert.equal((await post(app.base, '/api/push/register', registration(1), { 'content-type': 'text/plain' })).status, 415);
  assert.equal((await fetch(app.base + '/api/push/register')).status, 405);
  const big = await post(app.base, '/api/push/register', { ...registration(1), locale: 'x'.repeat(5000) });
  assert.equal(big.status, 413);
  assert.equal((await fetch(app.base + '/nope')).status, 404);
  // Only the registration with an extra (ignored) field was stored.
  assert.equal(app.store.size, 1);
});

test('rate limit: 30 requests per minute per IP, then 429', async (t) => {
  let now = 0;
  const app = await startApp({ rateLimit: new RateLimiter({ limit: 30, windowMs: 60_000, clock: () => now }) });
  t.after(app.close);
  for (let i = 0; i < 30; i++) assert.equal((await post(app.base, '/api/push/register', registration(i))).status, 204);
  const r = await post(app.base, '/api/push/register', registration(99));
  assert.equal(r.status, 429);
  assert.equal(r.headers.get('retry-after'), '60');
  // Health is never rate limited.
  assert.equal((await fetch(app.base + '/api/push/health')).status, 200);
  // A different client IP (X-Real-IP from the loopback proxy) has its own bucket.
  assert.equal((await post(app.base, '/api/push/register', registration(98), { 'x-real-ip': '203.0.113.9' })).status, 204);
  now += 60_000;
  assert.equal((await post(app.base, '/api/push/register', registration(99))).status, 204);
});

test('rate limiter unit', () => {
  let now = 0;
  const rl = new RateLimiter({ limit: 2, windowMs: 1000, clock: () => now });
  assert.equal(rl.hit('a'), true);
  assert.equal(rl.hit('a'), true);
  assert.equal(rl.hit('a'), false);
  assert.equal(rl.hit('b'), true);
  now = 1000;
  assert.equal(rl.hit('a'), true);
});

test('basic auth helpers', () => {
  assert.equal(safeEqual('abc', 'abc'), true);
  assert.equal(safeEqual('abc', 'abcd'), false);
  assert.equal(checkBasicAuth(basic(), 'admin', 'correct-horse-battery'), true);
  assert.equal(checkBasicAuth(basic('admin', 'wrong'), 'admin', 'correct-horse-battery'), false);
  assert.equal(checkBasicAuth(basic('root', 'correct-horse-battery'), 'admin', 'correct-horse-battery'), false);
  assert.equal(checkBasicAuth('Bearer x', 'admin', 'correct-horse-battery'), false);
  assert.equal(checkBasicAuth(undefined, 'admin', 'correct-horse-battery'), false);
  // Passwords may contain ":".
  assert.equal(checkBasicAuth(basic('admin', 'a:b:c-123456789'), 'admin', 'a:b:c-123456789'), true);
});

test('admin endpoints require Basic auth', async (t) => {
  const app = await startApp();
  t.after(app.close);
  const page = await fetch(app.base + '/push-admin');
  assert.equal(page.status, 401);
  assert.match(page.headers.get('www-authenticate'), /^Basic /);
  assert.equal((await fetch(app.base + '/push-admin', { headers: { authorization: basic('admin', 'nope-nope-nope') } })).status, 401);
  assert.equal((await post(app.base, '/api/push/send', send({ dryRun: true }))).status, 401);
  assert.equal((await post(app.base, '/api/push/send', send({ dryRun: true }), { authorization: basic('admin', 'wrong-password!') })).status, 401);
  assert.equal((await fetch(app.base + '/api/push/admin/overview')).status, 401);

  const ok = await fetch(app.base + '/push-admin', { headers: { authorization: basic() } });
  assert.equal(ok.status, 200);
  assert.match(ok.headers.get('content-type'), /text\/html/);
  const csp = ok.headers.get('content-security-policy');
  assert.match(csp, /default-src 'none'/);
  assert.match(csp, /frame-ancestors 'none'/);
  const html = await ok.text();
  assert.match(html, /发送对象/);
  assert.match(html, /先预览人数/);
  const nonce = /script-src 'nonce-([0-9a-f]+)'/.exec(csp)[1];
  assert.ok(html.includes(`<script nonce="${nonce}">`));
  assert.equal(/innerHTML/.test(html), false, 'admin page renders data with textContent only');
});

test('failed logins are throttled', async (t) => {
  const app = await startApp();
  t.after(app.close);
  let last;
  for (let i = 0; i < 11; i++) last = await post(app.base, '/api/push/send', send({ dryRun: true }), { authorization: basic('admin', `guess-${i}-xxxxxxxx`) });
  assert.equal(last.status, 429);
});

test('cross-origin POST to /api/push/send is refused even with credentials', async (t) => {
  const app = await startApp();
  t.after(app.close);
  const evil = await post(app.base, '/api/push/send', send({ dryRun: true }), { authorization: basic(), origin: 'https://evil.example' });
  assert.equal(evil.status, 403);
  const host = new URL(app.base).host;
  const same = await post(app.base, '/api/push/send', send({ dryRun: true }), { authorization: basic(), origin: `http://${host}` });
  assert.equal(same.status, 200);
  // A form post (text/plain) can never reach the handler.
  assert.equal((await post(app.base, '/api/push/send', JSON.stringify(send()), { authorization: basic(), 'content-type': 'text/plain' })).status, 415);
});

test('dry run counts targets by environment and language and sends nothing', async (t) => {
  const transport = fakeTransport();
  const app = await startApp({ transport });
  t.after(app.close);
  const regs = [
    registration(1, { language: 'en' }),
    registration(2, { language: 'fr' }),
    registration(3, { language: 'fr' }),
    registration(4, { language: 'th' }),
    registration(5, { language: 'fr', environment: 'sandbox' }),
  ];
  for (const r of regs) await post(app.base, '/api/push/register', r);
  const dry = async (over) => (await post(app.base, '/api/push/send', send({ dryRun: true, ...over }), { authorization: basic() })).json;
  assert.deepEqual(await dry({}), { targeted: 4, sent: 0, failed: 0, removed: 0, dryRun: true });
  assert.equal((await dry({ language: 'fr' })).targeted, 2);
  assert.equal((await dry({ language: 'th' })).targeted, 1);
  assert.equal((await dry({ environment: 'sandbox' })).targeted, 1);
  assert.equal((await dry({ environment: 'sandbox', language: 'en' })).targeted, 0);
  assert.equal(transport.calls.length, 0);
  assert.equal(app.history.list().length, 0, 'dry runs are not recorded');
  // Validation of the send body.
  const bad = await post(app.base, '/api/push/send', send({ title: 'x'.repeat(51) }), { authorization: basic() });
  assert.equal(bad.status, 400);
});

test('send: APNs request shape, counts, token removal and history', async (t) => {
  const responses = {
    [tok(2)]: { status: 410, reason: 'Unregistered', timestamp: Date.now() + 1000 },
    [tok(3)]: { status: 400, reason: 'BadDeviceToken' },
    [tok(4)]: { status: 400, reason: 'DeviceTokenNotForTopic' },
    [tok(5)]: { status: 429, reason: 'TooManyRequests' },
    [tok(6)]: { status: 0, reason: 'network: timeout' },
  };
  const transport = fakeTransport(responses);
  const app = await startApp({ transport });
  t.after(app.close);
  for (let i = 1; i <= 7; i++) await post(app.base, '/api/push/register', registration(i));
  await post(app.base, '/api/push/register', registration(8, { environment: 'sandbox' }));

  const r = await post(app.base, '/api/push/send', send({ dryRun: false }), { authorization: basic() });
  assert.equal(r.status, 200);
  assert.equal(r.json.targeted, 7);
  assert.equal(r.json.sent, 2);
  assert.equal(r.json.failed, 5);
  assert.equal(r.json.removed, 3);
  assert.deepEqual(r.json.reasons, { Unregistered: 1, BadDeviceToken: 1, DeviceTokenNotForTopic: 1, TooManyRequests: 1, 'network: timeout': 1 });

  // Only the dead tokens are gone; the rate-limited and timed-out ones stay.
  for (const n of [2, 3, 4]) assert.equal(app.store.get(tok(n)), undefined);
  for (const n of [1, 5, 6, 7, 8]) assert.ok(app.store.get(tok(n)));

  // Request shape.
  assert.equal(transport.calls.length, 7);
  const c = transport.calls[0];
  assert.equal(c.environment, 'production');
  assert.equal(c.headers['apns-topic'], 'com.vocabloop.app');
  assert.equal(c.headers['apns-push-type'], 'alert');
  assert.equal(c.headers['apns-priority'], '5');
  assert.match(c.headers.authorization, /^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
  assert.deepEqual(c.payload, { aps: { alert: { title: '该复习啦', body: '今天还有 20 个单词等你。' }, sound: 'default' } });
  assert.equal(transport.calls.some((x) => x.token === tok(8)), false, 'sandbox token not sent to production');

  // History.
  const hist = app.history.list();
  assert.equal(hist.length, 1);
  assert.equal(hist[0].title, '该复习啦');
  assert.equal(hist[0].environment, 'production');
  assert.equal(hist[0].language, null);
  assert.equal(hist[0].sent, 2);
  assert.equal(hist[0].removed, 3);
  const ov = await (await fetch(app.base + '/api/push/admin/overview', { headers: { authorization: basic() } })).json();
  assert.equal(ov.history[0].title, '该复习啦');
  assert.equal(ov.breakdown.production.total, 4);
  assert.equal(JSON.stringify(ov).includes(tok(1)), false, 'overview exposes no tokens');
});

test('410 older than the latest registration does not remove the token', async (t) => {
  const transport = fakeTransport({ [tok(1)]: { status: 410, reason: 'Unregistered', timestamp: Date.parse('2000-01-01') } });
  const app = await startApp({ transport });
  t.after(app.close);
  await post(app.base, '/api/push/register', registration(1));
  const r = await post(app.base, '/api/push/send', send(), { authorization: basic() });
  assert.equal(r.json.removed, 0);
  assert.ok(app.store.get(tok(1)));
});

test('send without APNs credentials → 503 (dry run still works)', async (t) => {
  const app = await startApp({ withApns: false });
  t.after(app.close);
  await post(app.base, '/api/push/register', registration(1));
  assert.equal((await post(app.base, '/api/push/send', send({ dryRun: true }), { authorization: basic() })).json.targeted, 1);
  assert.equal((await post(app.base, '/api/push/send', send(), { authorization: basic() })).status, 503);
  const h = await (await fetch(app.base + '/api/push/health')).json();
  assert.equal(h.apns, false);
});
