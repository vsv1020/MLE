// Checks the APNs auth key without a real device: sends a push to a made-up device token on both
// APNs environments. Apple checks the provider token before the device token, so
//   400 BadDeviceToken      → the key, key ID, team ID and topic are all accepted
//   403 InvalidProviderToken / 403 ... → the key is wrong (or revoked)
//
//   APNS_KEY_P8 (contents), APNS_KEY_ID, APPLE_TEAM_ID, [APNS_TOPIC=com.vocabloop.app]
import crypto from 'node:crypto';
import http2 from 'node:http2';

const env = (n) => { const v = process.env[n]; if (!v) { console.error(`::error::missing ${n}`); process.exit(1); } return v.trim(); };
const KEY = env('APNS_KEY_P8'), KEY_ID = env('APNS_KEY_ID'), TEAM_ID = env('APPLE_TEAM_ID');
const TOPIC = process.env.APNS_TOPIC || 'com.vocabloop.app';

function providerToken() {
  const b64 = (x) => Buffer.from(x).toString('base64url');
  const h = b64(JSON.stringify({ alg: 'ES256', kid: KEY_ID }));
  const c = b64(JSON.stringify({ iss: TEAM_ID, iat: Math.floor(Date.now() / 1000) }));
  const s = crypto.sign('sha256', Buffer.from(`${h}.${c}`), { key: KEY, dsaEncoding: 'ieee-p1363' });
  return `${h}.${c}.${b64(s)}`;
}

function send(host) {
  return new Promise((resolve) => {
    const client = http2.connect(`https://${host}`);
    client.on('error', (e) => resolve({ host, status: 0, body: e.message }));
    const req = client.request({
      ':method': 'POST',
      ':path': `/3/device/${'0'.repeat(64)}`,
      authorization: `bearer ${providerToken()}`,
      'apns-topic': TOPIC,
      'apns-push-type': 'alert',
      'content-type': 'application/json',
    });
    let status = 0, body = '';
    req.on('response', (h) => { status = h[':status']; });
    req.on('data', (d) => { body += d; });
    req.on('end', () => { client.close(); resolve({ host, status, body }); });
    req.end(JSON.stringify({ aps: { alert: 'check' } }));
  });
}

console.log(`key ID ${KEY_ID}, team ${TEAM_ID}, topic ${TOPIC}`);
let ok = true;
for (const host of ['api.sandbox.push.apple.com', 'api.push.apple.com']) {
  const r = await send(host);
  const reason = (() => { try { return JSON.parse(r.body).reason; } catch { return r.body; } })();
  const good = r.status === 400 && reason === 'BadDeviceToken';
  console.log(`${host}: ${r.status} ${reason} → ${good ? 'key accepted' : 'PROBLEM'}`);
  if (!good) ok = false;
}
if (!ok) { console.error('::error::APNs did not accept the key (see the reasons above)'); process.exit(1); }
console.log('APNs key works on both environments.');
