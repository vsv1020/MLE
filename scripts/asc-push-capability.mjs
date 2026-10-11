// Makes sure the app's App ID has Push Notifications enabled, for the opt-in
// 活动和新功能通知 (the app signs with `aps-environment` since then).
//
// Runs in release.yml before any Xcode step, on the same ASC API key and whatever VL_WIDGETS
// says: without the capability the distribution profile lacks `aps-environment` and the archive
// fails on signing, after the expensive part.
//
//   - Looks up APP_BUNDLE_ID with its capabilities.
//   - POSTs PUSH_NOTIFICATIONS when it is missing (409 = already there, which is fine).
//
// Idempotent. Exits non-zero only when the App ID does not exist or the capability could not be
// enabled for a reason other than "already enabled" (409) or "refused by policy" (422, reported
// as a warning and left to Xcode's own provisioning).
//
// env: ASC_KEY_ID, ASC_ISSUER_ID, KEY_PATH, APP_BUNDLE_ID
import crypto from 'node:crypto';
import fs from 'node:fs';

const env = (n, fallback) => {
  const v = process.env[n] || fallback;
  if (!v) throw new Error(`missing env ${n}`);
  return v;
};
const KEY_ID = env('ASC_KEY_ID');
const ISSUER = env('ASC_ISSUER_ID');
const KEY = fs.readFileSync(env('KEY_PATH'), 'utf8');
const APP_BUNDLE_ID = env('APP_BUNDLE_ID', 'com.vocabloop.app');
const CAPABILITY = 'PUSH_NOTIFICATIONS';

function token() {
  const b64 = (x) => Buffer.from(x).toString('base64url');
  const now = Math.floor(Date.now() / 1000);
  const head = b64(JSON.stringify({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' }));
  const body = b64(JSON.stringify({ iss: ISSUER, iat: now, exp: now + 19 * 60, aud: 'appstoreconnect-v1' }));
  const sig = crypto.sign('sha256', Buffer.from(`${head}.${body}`), { key: KEY, dsaEncoding: 'ieee-p1363' });
  return `${head}.${body}.${b64(sig)}`;
}

async function api(method, path, payload) {
  const res = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${token()}`,
      ...(payload ? { 'Content-Type': 'application/json' } : {}),
    },
    body: payload ? JSON.stringify(payload) : undefined,
  });
  const text = await res.text();
  let json = {};
  try { json = text ? JSON.parse(text) : {}; } catch { json = { raw: text }; }
  return { status: res.status, ok: res.ok, json };
}

const describe = (r) => (r.json.errors || []).map((e) => `${e.status} ${e.code}: ${e.detail || e.title}`).join('; ') || JSON.stringify(r.json).slice(0, 300);

// The API's identifier filter is a prefix match, so pick the exact record.
const query = new URLSearchParams({
  'filter[identifier]': APP_BUNDLE_ID,
  include: 'bundleIdCapabilities',
  limit: '200',
});
const found = await api('GET', `/v1/bundleIds?${query}`);
if (!found.ok) {
  console.log(`::error::GET bundleIds ${APP_BUNDLE_ID} → ${describe(found)}`);
  process.exit(1);
}
const record = (found.json.data || []).find((b) => b.attributes?.identifier === APP_BUNDLE_ID);
if (!record) {
  console.log(`::error::App ID ${APP_BUNDLE_ID} does not exist — register it in App Store Connect first.`);
  process.exit(1);
}
const capabilityIDs = new Set((record.relationships?.bundleIdCapabilities?.data || []).map((c) => c.id));
const capabilities = (found.json.included || [])
  .filter((x) => x.type === 'bundleIdCapabilities' && capabilityIDs.has(x.id))
  .map((x) => x.attributes?.capabilityType);

if (capabilities.includes(CAPABILITY)) {
  console.log(`${APP_BUNDLE_ID} (${record.id}): ${CAPABILITY} already enabled — nothing to do`);
  process.exit(0);
}

const r = await api('POST', '/v1/bundleIdCapabilities', {
  data: {
    type: 'bundleIdCapabilities',
    attributes: { capabilityType: CAPABILITY },
    relationships: { bundleId: { data: { type: 'bundleIds', id: record.id } } },
  },
});
if (r.ok) {
  console.log(`${APP_BUNDLE_ID} (${record.id}): enabled ${CAPABILITY}`);
  console.log('Editing an App ID\'s capabilities invalidates its profiles; this run regenerates them.');
} else if (r.status === 409) {
  console.log(`${APP_BUNDLE_ID} (${record.id}): ${CAPABILITY} already enabled (409)`);
} else if (r.status === 422) {
  console.log(`::warning::${CAPABILITY} on ${APP_BUNDLE_ID} refused (422): ${describe(r)} — enable Push Notifications on the App ID by hand in developer.apple.com > Identifiers if the archive fails on aps-environment.`);
} else {
  console.log(`::error::${CAPABILITY} on ${APP_BUNDLE_ID} failed: ${describe(r)}`);
  process.exit(1);
}
