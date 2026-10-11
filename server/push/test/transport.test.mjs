// Exercises the real Http2Transport against a local plaintext HTTP/2 server on 127.0.0.1
// (no internet): session reuse, error-body parsing and reconnect after GOAWAY.
import test from 'node:test';
import assert from 'node:assert/strict';
import http2 from 'node:http2';
import { Http2Transport } from '../lib/apns.mjs';
import { tok } from './helpers.mjs';

async function fakeApns(handler) {
  const server = http2.createServer();
  const sessions = new Set();
  server.on('session', (s) => sessions.add(s));
  server.on('stream', handler);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  return {
    origin: `http://127.0.0.1:${server.address().port}`,
    sessions,
    close: () => new Promise((r) => { for (const s of sessions) s.destroy(); server.close(r); }),
  };
}

const headers = { authorization: 'bearer x', 'apns-topic': 'com.vocabloop.app', 'apns-push-type': 'alert', 'apns-priority': '5', 'content-type': 'application/json' };

test('transport: reuses one session, parses APNs errors, reconnects after GOAWAY', async (t) => {
  const seen = [];
  const apns = await fakeApns((stream, h) => {
    let body = '';
    stream.setEncoding('utf8');
    stream.on('data', (d) => { body += d; });
    stream.on('end', () => {
      seen.push({ path: h[':path'], topic: h['apns-topic'], type: h['apns-push-type'], body: JSON.parse(body) });
      if (h[':path'].endsWith(tok(2))) {
        stream.respond({ ':status': 400, 'content-type': 'application/json' });
        stream.end(JSON.stringify({ reason: 'BadDeviceToken' }));
      } else {
        stream.respond({ ':status': 200, 'apns-id': 'abc' });
        stream.end();
      }
    });
  });
  const transport = new Http2Transport({ origins: { production: apns.origin, sandbox: apns.origin } });
  t.after(async () => { transport.close(); await apns.close(); });

  const payload = { aps: { alert: { title: 't', body: 'b' }, sound: 'default' } };
  const ok = await transport.send({ environment: 'production', token: tok(1), headers, payload });
  assert.equal(ok.status, 200);
  assert.equal(ok.apnsId, 'abc');
  const bad = await transport.send({ environment: 'production', token: tok(2), headers, payload });
  assert.deepEqual([bad.status, bad.reason], [400, 'BadDeviceToken']);
  assert.equal(apns.sessions.size, 1, 'one HTTP/2 connection reused for both requests');
  assert.deepEqual(seen[0], { path: `/3/device/${tok(1)}`, topic: 'com.vocabloop.app', type: 'alert', body: payload });

  // Server says GOAWAY (as APNs does before maintenance): the next send must use a new session.
  for (const s of apns.sessions) s.goaway();
  await new Promise((r) => setTimeout(r, 50));
  const after = await transport.send({ environment: 'production', token: tok(3), headers, payload });
  assert.equal(after.status, 200);
  assert.equal(apns.sessions.size, 2, 'reconnected after GOAWAY');
});

test('transport: unreachable host → status 0 (not thrown)', async () => {
  const transport = new Http2Transport({ origins: { production: 'http://127.0.0.1:1' } });
  const r = await transport.send({ environment: 'production', token: tok(1), headers, payload: {} });
  assert.equal(r.status, 0);
  assert.match(r.reason, /^network:/);
  transport.close();
});
