// Makes sure the App IDs the 1.0.8 widget extension needs exist, with App Groups enabled.
//
// Runs in release.yml before any Xcode step, on the same ASC API key, so a provisioning gap
// fails in seconds instead of after a macOS archive (docs/WIDGET-PLAN.md §3.1).
//
//   - Looks up APP_BUNDLE_ID and EXT_BUNDLE_ID (with their capabilities).
//   - Registers EXT_BUNDLE_ID ("VocabLoop Widgets", IOS) when it is missing.
//   - Enables the APP_GROUPS capability on either ID that lacks it (409 = already there).
//
// What it cannot do: create the group APP_GROUP itself or tick it on an App ID. The App Store
// Connect API has no endpoint for either (fastlane does it through the unofficial portal API with
// an Apple ID login, which CI must not use), so those stay one-time manual steps for the owner —
// printed below on every run, because this script cannot verify them.
//
// Idempotent. Exits non-zero only when a bundle ID is still missing afterwards, or APP_GROUPS
// could not be enabled for a reason other than "already enabled" / "refused by policy" (422,
// which is reported and left to Xcode's own provisioning and the manual checklist).
//
// env: ASC_KEY_ID, ASC_ISSUER_ID, KEY_PATH, APP_BUNDLE_ID, EXT_BUNDLE_ID, APP_GROUP
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
const EXT_BUNDLE_ID = env('EXT_BUNDLE_ID', 'com.vocabloop.app.widgets');
const APP_GROUP = env('APP_GROUP', 'group.com.vocabloop.app');

const CHECKLIST = `
Owner, once, in developer.apple.com > Certificates, Identifiers & Profiles > Identifiers:
  1. "+" > App Groups > register ${APP_GROUP} (description "VocabLoop").
  2. App IDs > ${APP_BUNDLE_ID} > App Groups > enable > Configure > tick ${APP_GROUP} > Save.
  3. App IDs > ${EXT_BUNDLE_ID} ("VocabLoop Widgets") > App Groups > Configure > tick ${APP_GROUP} > Save.
     (This script registers the App ID and enables the capability; only the tick cannot be scripted.)
Editing an App ID's capabilities invalidates its profiles; CI regenerates them on every run.
To ship without the widgets meanwhile: run the release with widgets = off (or set the
repository variable VL_WIDGETS=off).`;

function token() {
  const b64 = (x) => Buffer.from(x).toString('base64url');
  const now = Math.floor(Date.now() / 1000);
  const head = b64(JSON.stringify({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' }));
  const body = b64(JSON.stringify({ iss: ISSUER, iat: now, exp: now + 19 * 60, aud: 'appstoreconnect-v1' }));
  const sig = crypto.sign('sha256', Buffer.from(`${head}.${body}`), { key: KEY, dsaEncoding: 'ieee-p1363' });
  return `${head}.${body}.${b64(sig)}`;
}

/// Returns { status, json }; throws only on network failure. Callers decide what a status means.
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

/// The bundle ID record for exactly `identifier` (the API filter is a prefix match), plus the
/// capability types it has.
async function lookup(identifier) {
  const query = new URLSearchParams({
    'filter[identifier]': identifier,
    include: 'bundleIdCapabilities',
    limit: '200',
  });
  const r = await api('GET', `/v1/bundleIds?${query}`);
  if (!r.ok) throw new Error(`GET bundleIds ${identifier} → ${describe(r)}`);
  const record = (r.json.data || []).find((b) => b.attributes?.identifier === identifier);
  if (!record) return null;
  const capabilityIDs = new Set((record.relationships?.bundleIdCapabilities?.data || []).map((c) => c.id));
  const capabilities = (r.json.included || [])
    .filter((x) => x.type === 'bundleIdCapabilities' && capabilityIDs.has(x.id))
    .map((x) => x.attributes?.capabilityType);
  return { id: record.id, identifier, name: record.attributes?.name, capabilities };
}

async function register(identifier, name) {
  const r = await api('POST', '/v1/bundleIds', {
    data: { type: 'bundleIds', attributes: { identifier, name, platform: 'IOS' } },
  });
  if (r.ok) { console.log(`registered App ID ${identifier} ("${name}")`); return; }
  if (r.status === 409) { console.log(`App ID ${identifier} already registered`); return; }
  console.log(`::error::could not register ${identifier}: ${describe(r)}`);
}

/// 'enabled' | 'already' | 'refused' | 'failed'
async function enableAppGroups(bundle) {
  if (bundle.capabilities.includes('APP_GROUPS')) return 'already';
  const r = await api('POST', '/v1/bundleIdCapabilities', {
    data: {
      type: 'bundleIdCapabilities',
      attributes: { capabilityType: 'APP_GROUPS' },
      relationships: { bundleId: { data: { type: 'bundleIds', id: bundle.id } } },
    },
  });
  if (r.ok) return 'enabled';
  if (r.status === 409) return 'already';
  if (r.status === 422) {
    console.log(`::warning::APP_GROUPS on ${bundle.identifier} refused (422): ${describe(r)} — do it by hand, see below.`);
    return 'refused';
  }
  console.log(`::error::APP_GROUPS on ${bundle.identifier} failed: ${describe(r)}`);
  return 'failed';
}

let failed = false;
const rows = [];

let app = await lookup(APP_BUNDLE_ID);
let ext = await lookup(EXT_BUNDLE_ID);
if (!ext) {
  await register(EXT_BUNDLE_ID, 'VocabLoop Widgets');
  ext = await lookup(EXT_BUNDLE_ID);
}

for (const [identifier, bundle] of [[APP_BUNDLE_ID, app], [EXT_BUNDLE_ID, ext]]) {
  if (!bundle) {
    rows.push([identifier, 'MISSING', '-']);
    failed = true;
    continue;
  }
  const groups = await enableAppGroups(bundle);
  if (groups === 'failed') failed = true;
  rows.push([identifier, bundle.id, `APP_GROUPS ${groups}`]);
}

console.log('\n' + 'App ID'.padEnd(34) + 'record'.padEnd(14) + 'capability');
for (const [identifier, id, status] of rows) {
  console.log(`${identifier.padEnd(33)} ${String(id).padEnd(13)} ${status}`);
}
console.log(`\nNot verifiable from the API: that ${APP_GROUP} exists and is ticked on both App IDs.`);
console.log(CHECKLIST);

if (failed) {
  console.log('\n::error::App IDs for the widget extension are not ready — see the checklist above.');
  process.exit(1);
}
