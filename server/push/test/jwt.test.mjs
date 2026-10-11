import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { signProviderToken, ProviderToken, JWT_TTL_MS } from '../lib/jwt.mjs';
import { loadConfig } from '../lib/config.mjs';
import { newKey } from './helpers.mjs';

const decode = (part) => JSON.parse(Buffer.from(part, 'base64url').toString('utf8'));

test('provider token is an ES256 JWT with kid / iss / iat and a valid signature', () => {
  const { privateKey, publicKey } = newKey();
  const now = Date.UTC(2026, 9, 11, 12, 0, 0);
  const jwt = signProviderToken({ key: privateKey, keyId: 'ABC123DEFG', teamId: 'TEAM123456', now });
  const [h, c, s] = jwt.split('.');
  assert.deepEqual(decode(h), { alg: 'ES256', kid: 'ABC123DEFG' });
  assert.deepEqual(decode(c), { iss: 'TEAM123456', iat: now / 1000 });
  const sig = Buffer.from(s, 'base64url');
  assert.equal(sig.length, 64, 'ES256 signatures are raw r||s (64 bytes), not DER');
  assert.ok(crypto.verify('sha256', Buffer.from(`${h}.${c}`), { key: publicKey, dsaEncoding: 'ieee-p1363' }, sig));
  assert.doesNotMatch(jwt, /[+/=]/, 'base64url without padding');
});

test('provider token accepts the .p8 PEM text', () => {
  const { privateKey } = newKey();
  const pem = privateKey.export({ type: 'pkcs8', format: 'pem' });
  const p = new ProviderToken({ key: pem, keyId: 'ABC123DEFG', teamId: 'TEAM123456' });
  assert.equal(p.get().split('.').length, 3);
});

test('provider token is cached for 50 minutes, then refreshed', () => {
  const { privateKey } = newKey();
  let now = 1_000_000_000_000;
  const p = new ProviderToken({ key: privateKey, keyId: 'ABC123DEFG', teamId: 'TEAM123456', clock: () => now });
  const first = p.get();
  now += JWT_TTL_MS - 1;
  assert.equal(p.get(), first);
  now += 1;
  const second = p.get();
  assert.notEqual(second, first);
  assert.equal(decode(second.split('.')[1]).iat, Math.floor(now / 1000));
  // invalidate() is ignored for a token younger than 20 minutes (APNs throttles refreshes).
  p.invalidate();
  assert.equal(p.get(), second);
  now += 20 * 60 * 1000;
  p.invalidate();
  assert.notEqual(p.get(), second);
});

test('rejects non-EC keys', () => {
  const { privateKey } = crypto.generateKeyPairSync('ed25519');
  assert.throws(() => new ProviderToken({ key: privateKey, keyId: 'A', teamId: 'B' }), /EC/);
});

test('config: refuses a missing or short ADMIN_PASSWORD', () => {
  assert.match(loadConfig({}).errors.join(), /ADMIN_PASSWORD is not set/);
  assert.match(loadConfig({ ADMIN_PASSWORD: 'short' }).errors.join(), /at least 12/);
  const ok = loadConfig({ ADMIN_PASSWORD: 'x'.repeat(12) });
  assert.deepEqual(ok.errors, []);
  assert.equal(ok.config.port, 8787);
  assert.equal(ok.config.dataDir, '/var/lib/mashu-push');
  assert.equal(ok.config.apns, null);
  assert.match(ok.warnings.join(), /APNs is not configured/);
});

test('config: loads APNS_KEY_P8 with escaped newlines and checks IDs', () => {
  const { privateKey } = newKey();
  const pem = privateKey.export({ type: 'pkcs8', format: 'pem' }).replace(/\n/g, '\\n');
  const base = { ADMIN_PASSWORD: 'x'.repeat(16), APNS_KEY_P8: pem };
  const good = loadConfig({ ...base, APNS_KEY_ID: 'ABC123DEFG', APPLE_TEAM_ID: 'TEAM123456' });
  assert.deepEqual(good.errors, []);
  assert.equal(good.config.apns.keyId, 'ABC123DEFG');
  assert.match(loadConfig({ ...base, APNS_KEY_ID: 'abc', APPLE_TEAM_ID: 'TEAM123456' }).errors.join(), /APNS_KEY_ID/);
  assert.match(loadConfig({ ...base, APNS_KEY_P8: 'garbage', APNS_KEY_ID: 'ABC123DEFG', APPLE_TEAM_ID: 'TEAM123456' }).errors.join(), /could not be parsed/);
  assert.match(loadConfig({ ADMIN_PASSWORD: 'x'.repeat(16), APNS_KEY_PATH: '/nonexistent/AuthKey.p8', APNS_KEY_ID: 'ABC123DEFG', APPLE_TEAM_ID: 'TEAM123456' }).errors.join(), /cannot read APNS_KEY_PATH/);
});
