import test from 'node:test';
import assert from 'node:assert/strict';
import { sendToAll, shouldRemoveToken, buildPayload, CONCURRENCY } from '../lib/apns.mjs';
import { tok } from './helpers.mjs';

const providerToken = { get: () => 'h.c.s', invalidations: 0, invalidate() { this.invalidations++; } };

test('concurrency is bounded (~20 in flight)', async () => {
  let inFlight = 0, peak = 0;
  const transport = {
    async send() {
      inFlight++; peak = Math.max(peak, inFlight);
      await new Promise((r) => setTimeout(r, 2));
      inFlight--;
      return { status: 200 };
    },
  };
  const targets = Array.from({ length: 200 }, (_, i) => ({ token: tok(i % 256) + i.toString(16).padStart(4, '0') }));
  const r = await sendToAll({ transport, providerToken, targets, environment: 'production', title: 't', body: 'b' });
  assert.equal(r.sent, 200);
  assert.equal(peak, CONCURRENCY);
});

test('transport exceptions count as failures and do not remove tokens', async () => {
  const transport = { async send() { throw new Error('boom'); } };
  const r = await sendToAll({ transport, providerToken, targets: [{ token: tok(1) }], environment: 'sandbox', title: 't', body: 'b' });
  assert.equal(r.failed, 1);
  assert.deepEqual(r.removedTokens, []);
  assert.deepEqual(r.reasons, { 'network: boom': 1 });
});

test('ExpiredProviderToken asks the JWT cache to refresh', async () => {
  const p = { ...providerToken, invalidations: 0 };
  const transport = { async send() { return { status: 403, reason: 'ExpiredProviderToken' }; } };
  await sendToAll({ transport, providerToken: p, targets: [{ token: tok(1) }], environment: 'production', title: 't', body: 'b' });
  assert.equal(p.invalidations, 1);
});

test('shouldRemoveToken', () => {
  assert.equal(shouldRemoveToken({ status: 410, reason: 'Unregistered' }, {}), true);
  assert.equal(shouldRemoveToken({ status: 400, reason: 'BadDeviceToken' }), true);
  assert.equal(shouldRemoveToken({ status: 400, reason: 'DeviceTokenNotForTopic' }), true);
  assert.equal(shouldRemoveToken({ status: 400, reason: 'PayloadTooLarge' }), false);
  assert.equal(shouldRemoveToken({ status: 403, reason: 'InvalidProviderToken' }), false);
  assert.equal(shouldRemoveToken({ status: 500, reason: 'InternalServerError' }), false);
  assert.equal(shouldRemoveToken({ status: 0 }), false);
});

test('payload shape', () => {
  assert.deepEqual(buildPayload('T', 'B'), { aps: { alert: { title: 'T', body: 'B' }, sound: 'default' } });
});
