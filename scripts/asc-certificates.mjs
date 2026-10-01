// Lists (and, when asked, prunes) the signing certificates on the developer account.
//
// Why this exists: every release runs on a fresh GitHub runner with an empty keychain, so
// automatic signing creates a new Apple Development certificate each time. After enough
// releases the account hits Apple's certificate limit and archiving fails with "Your account
// has reached the maximum number of certificates".
//
//   MODE=list   — print every certificate (read-only, the default)
//   MODE=prune  — revoke only *development* certificates that were created through the API
//                 (the ones CI made). Distribution certificates and anything made on a Mac
//                 are never touched.
import crypto from 'node:crypto';
import fs from 'node:fs';

const env = (n) => { const v = process.env[n]; if (!v) throw new Error(`missing env ${n}`); return v; };
const KEY_ID = env('ASC_KEY_ID');
const ISSUER = env('ASC_ISSUER_ID');
const KEY = fs.readFileSync(env('KEY_PATH'), 'utf8');
const MODE = (process.env.MODE || 'list').trim();

function token() {
  const b64 = (x) => Buffer.from(x).toString('base64url');
  const now = Math.floor(Date.now() / 1000);
  const head = b64(JSON.stringify({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' }));
  const body = b64(JSON.stringify({ iss: ISSUER, iat: now, exp: now + 19 * 60, aud: 'appstoreconnect-v1' }));
  const sig = crypto.sign('sha256', Buffer.from(`${head}.${body}`), { key: KEY, dsaEncoding: 'ieee-p1363' });
  return `${head}.${body}.${b64(sig)}`;
}

async function api(method, path) {
  const res = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    method, headers: { Authorization: `Bearer ${token()}` },
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${path} → ${res.status} ${text}`);
  return text ? JSON.parse(text) : {};
}

const isCIDevelopment = (c) =>
  ['DEVELOPMENT', 'IOS_DEVELOPMENT'].includes(c.attributes.certificateType) &&
  /created via api/i.test(`${c.attributes.name} ${c.attributes.displayName}`);

const certs = (await api('GET', '/v1/certificates?limit=200&fields[certificates]=name,displayName,certificateType,expirationDate,platform')).data;
console.log(`${certs.length} certificates:`);
for (const c of certs) {
  const a = c.attributes;
  console.log(`  ${c.id}  ${a.certificateType.padEnd(22)} ${a.displayName || a.name}  (expires ${a.expirationDate?.slice(0, 10)})${isCIDevelopment(c) ? '  ← made by CI' : ''}`);
}

if (MODE === 'prune') {
  const doomed = certs.filter(isCIDevelopment);
  console.log(`\nrevoking ${doomed.length} CI development certificate(s)`);
  for (const c of doomed) {
    await api('DELETE', `/v1/certificates/${c.id}`);
    console.log(`  revoked ${c.id}`);
  }
}
