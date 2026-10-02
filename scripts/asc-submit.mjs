// Submits the editable iOS App Store version (with the Plus in-app purchase) for App Review.
//
// Run only on purpose: triggered by changing the SUBMIT file on main, after the owner asked
// for submission. Refuses to submit when the App Review contact is incomplete, and prints
// Apple's error detail for anything it rejects.
import crypto from 'node:crypto';
import fs from 'node:fs';

const env = (n) => { const v = process.env[n]; if (!v) throw new Error(`missing env ${n}`); return v; };
const KEY_ID = env('ASC_KEY_ID'), ISSUER = env('ASC_ISSUER_ID'), KEY = fs.readFileSync(env('KEY_PATH'), 'utf8');
const BUNDLE_ID = 'com.vocabloop.app';
const IAP_PRODUCT_ID = 'com.vocabloop.app.plus.lifetime';

function token() {
  const b64 = (x) => Buffer.from(x).toString('base64url');
  const now = Math.floor(Date.now() / 1000);
  const h = b64(JSON.stringify({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' }));
  const b = b64(JSON.stringify({ iss: ISSUER, iat: now, exp: now + 19 * 60, aud: 'appstoreconnect-v1' }));
  const s = crypto.sign('sha256', Buffer.from(`${h}.${b}`), { key: KEY, dsaEncoding: 'ieee-p1363' });
  return `${h}.${b}.${b64(s)}`;
}
async function api(method, path, payload) {
  const res = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    method,
    headers: { Authorization: `Bearer ${token()}`, 'Content-Type': 'application/json' },
    body: payload ? JSON.stringify(payload) : undefined,
  });
  const text = await res.text();
  const json = text ? JSON.parse(text) : {};
  if (!res.ok) {
    const detail = (json.errors || []).map((e) => `${e.code}: ${e.detail}`).join('; ') || text;
    throw new Error(`${method} ${path} → ${res.status} ${detail}`);
  }
  return json;
}

const app = (await api('GET', `/v1/apps?filter[bundleId]=${BUNDLE_ID}&limit=1`)).data[0];
console.log(`app ${app.attributes.name} (${app.id})`);

const editable = new Set(['PREPARE_FOR_SUBMISSION', 'DEVELOPER_REJECTED', 'REJECTED', 'METADATA_REJECTED', 'INVALID_BINARY']);
const versions = (await api('GET', `/v1/apps/${app.id}/appStoreVersions?filter[platform]=IOS&limit=10`)).data;
const version = versions.find((v) => editable.has(v.attributes.appStoreState));
if (!version) {
  console.log('No version waiting to be submitted:', versions.map((v) => `${v.attributes.versionString}=${v.attributes.appStoreState}`).join(', '));
  process.exit(0);
}
console.log(`version ${version.attributes.versionString} (${version.attributes.appStoreState})`);

// The contact is required; check it here so the failure says what to fix.
const detail = await api('GET', `/v1/appStoreVersions/${version.id}/appStoreReviewDetail`).catch(() => null);
const c = detail?.data?.attributes ?? {};
const missing = ['contactFirstName', 'contactLastName', 'contactEmail', 'contactPhone'].filter((k) => !c[k]);
if (missing.length) {
  console.error(`::error::App Review contact incomplete (${missing.join(', ')}). Add the REVIEW_CONTACT_PHONE secret or fill it in on the version page, then rerun.`);
  process.exit(1);
}

// One open review submission per platform; reuse it if a previous run created it.
const open = (await api('GET', `/v1/reviewSubmissions?filter[app]=${app.id}&filter[platform]=IOS&filter[state]=READY_FOR_REVIEW&limit=1`)).data[0];
const submission = open ?? (await api('POST', '/v1/reviewSubmissions', {
  data: { type: 'reviewSubmissions', attributes: { platform: 'IOS' }, relationships: { app: { data: { type: 'apps', id: app.id } } } },
})).data;
console.log(`review submission ${submission.id}`);

const items = (await api('GET', `/v1/reviewSubmissions/${submission.id}/items?include=appStoreVersion&limit=10`)).data;
if (!items.some((i) => i.relationships?.appStoreVersion?.data?.id === version.id)) {
  await api('POST', '/v1/reviewSubmissionItems', {
    data: {
      type: 'reviewSubmissionItems',
      relationships: {
        reviewSubmission: { data: { type: 'reviewSubmissions', id: submission.id } },
        appStoreVersion: { data: { type: 'appStoreVersions', id: version.id } },
      },
    },
  });
  console.log('version added to the submission');
}

// The first in-app purchase goes to review together with the version: attach it once the
// version is in the draft submission, and stop if Apple refuses — a version whose Plus page says
// "not available" would come back rejected.
const iap = (await api('GET', `/v1/apps/${app.id}/inAppPurchasesV2?filter[productId]=${IAP_PRODUCT_ID}&limit=1`)).data[0];
if (!iap) {
  console.error(`::error::In-app purchase ${IAP_PRODUCT_ID} not found`);
  process.exit(1);
}
if (iap.attributes.state === 'READY_TO_SUBMIT') {
  try {
    await api('POST', '/v1/inAppPurchaseSubmissions', {
      data: { type: 'inAppPurchaseSubmissions', relationships: { inAppPurchaseV2: { data: { type: 'inAppPurchases', id: iap.id } } } },
    });
    console.log('IAP added to the submission');
  } catch (e) {
    console.error(`::error::Could not add the in-app purchase: ${e.message}`);
    console.error('Nothing was submitted. On the version page, tick it under "In-App Purchases and Subscriptions", then "Add for Review".');
    process.exit(1);
  }
} else {
  console.log(`IAP state ${iap.attributes.state} — already on its way`);
}

const done = await api('PATCH', `/v1/reviewSubmissions/${submission.id}`, {
  data: { type: 'reviewSubmissions', id: submission.id, attributes: { submitted: true } },
});
console.log(`submitted for review: state=${done.data.attributes.state}`);
