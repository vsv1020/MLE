import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { TokenStore, HistoryStore, atomicWriteJSON, HISTORY_MAX } from '../lib/storage.mjs';
import { tempDir, tok } from './helpers.mjs';

const rec = (n, over = {}) => ({ token: tok(n), environment: 'production', language: 'en', appVersion: '1.0', locale: 'en_US', ...over });

test('token store round-trip: upsert, reload, remove', async () => {
  const dir = await tempDir();
  const a = await new TokenStore(dir).load();
  assert.equal(await a.upsert(rec(1), new Date('2026-01-01T00:00:00Z')), true);
  assert.equal(await a.upsert(rec(2, { environment: 'sandbox', language: 'fr' })), true);
  // Upsert of an existing token updates it, keeps createdAt, moves updatedAt.
  assert.equal(await a.upsert(rec(1, { language: 'th' }), new Date('2026-02-01T00:00:00Z')), false);

  const b = await new TokenStore(dir).load();
  assert.equal(b.size, 2);
  const r1 = b.get(tok(1));
  assert.equal(r1.language, 'th');
  assert.equal(r1.createdAt, '2026-01-01T00:00:00.000Z');
  assert.equal(r1.updatedAt, '2026-02-01T00:00:00.000Z');
  assert.deepEqual(b.counts(), { production: 1, sandbox: 1 });
  assert.deepEqual(b.breakdown().sandbox, { total: 1, en: 0, fr: 1, th: 0 });

  assert.equal(await b.remove(tok(1)), true);
  assert.equal(await b.remove(tok(1)), false); // idempotent
  const c = await new TokenStore(dir).load();
  assert.equal(c.size, 1);
  assert.equal(c.get(tok(2)).environment, 'sandbox');
});

test('token store: file is mode 600 and leaves no temp files', async () => {
  const dir = await tempDir();
  const s = await new TokenStore(dir).load();
  await Promise.all(Array.from({ length: 50 }, (_, i) => s.upsert(rec(i))));
  const files = await fs.readdir(dir);
  assert.deepEqual(files, ['tokens.json']);
  const st = await fs.stat(path.join(dir, 'tokens.json'));
  assert.equal(st.mode & 0o777, 0o600);
  // Concurrent upserts coalesce but none are lost.
  const again = await new TokenStore(dir).load();
  assert.equal(again.size, 50);
});

test('atomic write: a failed write never leaves a truncated file', async () => {
  const dir = await tempDir();
  const file = path.join(dir, 'tokens.json');
  await atomicWriteJSON(file, { version: 1, tokens: { a: 1 } });
  const circular = {}; circular.self = circular;
  await assert.rejects(atomicWriteJSON(file, circular));
  assert.deepEqual(JSON.parse(await fs.readFile(file, 'utf8')), { version: 1, tokens: { a: 1 } });
  assert.deepEqual(await fs.readdir(dir), ['tokens.json']);
});

test('atomic write: replaces via rename (readers see old or new, never partial)', async () => {
  const dir = await tempDir();
  const file = path.join(dir, 'x.json');
  await atomicWriteJSON(file, { n: 1 });
  const before = (await fs.stat(file)).ino;
  await atomicWriteJSON(file, { n: 2 });
  const after = (await fs.stat(file)).ino;
  assert.notEqual(before, after, 'new inode means the file was renamed into place, not rewritten');
  assert.deepEqual(JSON.parse(await fs.readFile(file, 'utf8')), { n: 2 });
});

test('a corrupt data file stops startup instead of being overwritten', async () => {
  const dir = await tempDir();
  await fs.writeFile(path.join(dir, 'tokens.json'), '{"tokens": {');
  await assert.rejects(new TokenStore(dir).load(), /not valid JSON/);
  assert.equal(await fs.readFile(path.join(dir, 'tokens.json'), 'utf8'), '{"tokens": {');
});

test('select filters by environment and language', async () => {
  const s = await new TokenStore(await tempDir()).load();
  await s.upsert(rec(1, { language: 'en' }));
  await s.upsert(rec(2, { language: 'fr' }));
  await s.upsert(rec(3, { language: 'fr', environment: 'sandbox' }));
  assert.equal(s.select({ environment: 'production' }).length, 2);
  assert.deepEqual(s.select({ environment: 'production', language: 'fr' }).map((t) => t.token), [tok(2)]);
  assert.deepEqual(s.select({ environment: 'sandbox', language: 'fr' }).map((t) => t.token), [tok(3)]);
  assert.equal(s.select({ environment: 'sandbox', language: 'th' }).length, 0);
});

test('history keeps the newest 100 and survives reload', async () => {
  const dir = await tempDir();
  const h = await new HistoryStore(dir).load();
  for (let i = 0; i < HISTORY_MAX + 5; i++) await h.add({ time: new Date(i * 1000).toISOString(), title: `t${i}` });
  const again = await new HistoryStore(dir).load();
  assert.equal(again.list().length, HISTORY_MAX);
  assert.equal(again.list()[0].title, `t${HISTORY_MAX + 4}`);
  assert.equal(again.list(3).length, 3);
});
