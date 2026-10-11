import test from 'node:test';
import assert from 'node:assert/strict';
import { validateRegister, validateUnregister, validateSend, tokenTail } from '../lib/validate.mjs';
import { tok, registration } from './helpers.mjs';

test('register: accepts a valid registration and lowercases the token', () => {
  const r = validateRegister(registration(1, { token: 'AB'.repeat(32) }));
  assert.equal(r.ok, true);
  assert.equal(r.value.token, 'ab'.repeat(32));
  assert.equal(r.value.environment, 'production');
});

test('register: appVersion and locale are optional', () => {
  const r = validateRegister({ token: tok(2), environment: 'sandbox', language: 'th' });
  assert.equal(r.ok, true);
  assert.equal(r.value.appVersion, null);
  assert.equal(r.value.locale, null);
});

test('register: rejects bad tokens', () => {
  for (const token of ['', 'zz'.repeat(32), 'a'.repeat(63), 'a'.repeat(201), 123, null, undefined, ['a'.repeat(64)]]) {
    assert.equal(validateRegister(registration(1, { token })).ok, false, `token ${String(token).slice(0, 10)}`);
  }
  assert.equal(validateRegister(registration(1, { token: 'a'.repeat(200) })).ok, true);
});

test('register: rejects bad environment, language, appVersion, locale', () => {
  assert.equal(validateRegister(registration(1, { environment: 'prod' })).ok, false);
  assert.equal(validateRegister(registration(1, { language: 'de' })).ok, false);
  assert.equal(validateRegister(registration(1, { language: undefined })).ok, false);
  assert.equal(validateRegister(registration(1, { appVersion: '<script>' })).ok, false);
  assert.equal(validateRegister(registration(1, { appVersion: 'x'.repeat(33) })).ok, false);
  assert.equal(validateRegister(registration(1, { locale: 'en US' })).ok, false);
  assert.equal(validateRegister(registration(1, { locale: 5 })).ok, false);
});

test('register: ignores unknown fields (newer apps), rejects non-objects', () => {
  const r = validateRegister({ ...registration(1), admin: true });
  assert.equal(r.ok, true);
  assert.equal(r.value.admin, undefined);
  assert.equal(validateRegister([registration(1)]).ok, false);
  assert.equal(validateRegister(null).ok, false);
  assert.equal(validateRegister('x').ok, false);
});

test('unregister: needs a token, ignores anything else', () => {
  assert.equal(validateUnregister({ token: tok(3) }).ok, true);
  assert.deepEqual(validateUnregister({ token: tok(3), x: 1 }).value, { token: tok(3) });
  assert.equal(validateUnregister({}).ok, false);
});

test('send: limits and trimming', () => {
  const ok = validateSend({ title: '  你好  ', body: '第一行\r\n第二行', environment: 'sandbox', dryRun: true });
  assert.equal(ok.ok, true);
  assert.equal(ok.value.title, '你好');
  assert.equal(ok.value.body, '第一行\n第二行');
  assert.equal(ok.value.language, null);
  assert.equal(validateSend({ title: '字'.repeat(50), body: 'b', environment: 'production' }).ok, true);
  assert.equal(validateSend({ title: '字'.repeat(51), body: 'b', environment: 'production' }).ok, false);
  assert.equal(validateSend({ title: 't', body: '😀'.repeat(200), environment: 'production' }).ok, true);
  assert.equal(validateSend({ title: 't', body: '😀'.repeat(201), environment: 'production' }).ok, false);
  assert.equal(validateSend({ title: '', body: 'b', environment: 'production' }).ok, false);
  assert.equal(validateSend({ title: 'a\nb', body: 'b', environment: 'production' }).ok, false);
  assert.equal(validateSend({ title: 't', body: 'b\u0007', environment: 'production' }).ok, false);
  assert.equal(validateSend({ title: 't', body: 'b', environment: 'staging' }).ok, false);
  assert.equal(validateSend({ title: 't', body: 'b', environment: 'production', language: 'de' }).ok, false);
  assert.equal(validateSend({ title: 't', body: 'b', environment: 'production', dryRun: 'yes' }).ok, false);
  assert.equal(validateSend({ title: 't', body: 'b', environment: 'production', extra: 1 }).ok, false);
  assert.equal(validateSend({ title: 't', body: 'b', environment: 'production', language: 'fr' }).value.language, 'fr');
});

test('tokenTail shows only the last 6 characters', () => {
  assert.equal(tokenTail('0123456789abcdef'), '…abcdef');
});
