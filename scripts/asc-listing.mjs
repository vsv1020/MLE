// Fills in the App Store listing and the "VocabLoop Plus Lifetime" in-app purchase through the
// App Store Connect API, from appstore/listing.json (which encodes docs/APP-STORE-LISTING.md).
//
// Runs on the GitHub runner (.github/workflows/appstore-listing.yml), which can reach
// api.appstoreconnect.apple.com. No dependencies: Node's own crypto signs the ES256 token.
//
// Idempotent: every step reads the current state first, PATCHes only the attributes that differ
// and creates only what is missing, so rerunning it is safe and prints "unchanged" for what is
// already right. It NEVER submits anything for review.
//
// Steps (each one reports its own failure with Apple's error text; independent steps keep going,
// and the process exits non-zero at the end if any step failed):
//   1. App info: localizations (name, subtitle, privacy policy URL), categories, age rating.
//   2. Version: the editable iOS version (created when missing, versionString from RELEASE),
//      copyright, release type, localizations, build, App Review details.
//   3. Screenshots (6.9" iPhone) from docs/appstore/screenshots/0[1-5]-*.png when present.
//   4. In-app purchase: product, localizations, price (¥198, base territory CHN), availability,
//      review screenshot docs/appstore/screenshots/06-plus.png when present.
//   5. Checklist of what only the owner can do in the web UI.
//
// env: ASC_KEY_ID, ASC_ISSUER_ID, KEY_PATH, optional APP_VERSION (default: first line of RELEASE),
//      LISTING (default appstore/listing.json).
// `node scripts/asc-listing.mjs --check` validates the JSON and the local files without any
// network access or credentials.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

// ---------------------------------------------------------------------------------------------
// Pure helpers (exported for local tests; no network).

/// Apple's limits, counted in characters (code points).
export const LIMITS = {
  name: 30,
  subtitle: 30,
  promotionalText: 170,
  description: 4000,
  keywords: 100,
  reviewNotes: 4000,
  iapName: 30,
  iapDescription: 45,
  iapReviewNote: 4000,
  referenceName: 64,
};

const PLACEHOLDERS = [/YOUR-DOMAIN/i, /你的域名/, /你的法定姓名/, /example\.(com|org)/i, /TODO/, /XXX/];
const EMOJI = /\p{Extended_Pictographic}/u;

export const charCount = (s) => [...(s ?? '')].length;

export const md5 = (buf) => crypto.createHash('md5').update(buf).digest('hex');

/// Validates the listing; returns a list of problems (empty when fine).
export function validateListing(l) {
  const problems = [];
  const need = (cond, msg) => { if (!cond) problems.push(msg); };
  const limit = (label, value, max) => {
    const n = charCount(value);
    need(typeof value === 'string' && n > 0, `${label} is empty`);
    need(n <= max, `${label} is ${n} characters (limit ${max})`);
  };
  const url = (label, value) => need(typeof value === 'string' && /^https:\/\/[^\s]+$/.test(value), `${label} is not an https URL: ${value}`);
  const scan = (label, value) => {
    if (typeof value !== 'string') return;
    for (const p of PLACEHOLDERS) need(!p.test(value), `${label} still contains a placeholder (${p})`);
  };

  need(l && typeof l === 'object', 'listing is not an object');
  if (!l) return problems;
  need(/^[\w.-]+$/.test(l.bundleId ?? ''), 'bundleId missing');
  need(l.locales && Object.keys(l.locales).length > 0, 'no locales');
  for (const [locale, v] of Object.entries(l.locales ?? {})) {
    limit(`${locale} name`, v.name, LIMITS.name);
    limit(`${locale} subtitle`, v.subtitle, LIMITS.subtitle);
    limit(`${locale} promotionalText`, v.promotionalText, LIMITS.promotionalText);
    limit(`${locale} description`, v.description, LIMITS.description);
    limit(`${locale} keywords`, v.keywords, LIMITS.keywords);
    for (const f of ['name', 'subtitle', 'keywords']) need(!EMOJI.test(v[f] ?? ''), `${locale} ${f} contains an emoji, which Apple rejects`);
    need(!/,\s/.test(v.keywords ?? ''), `${locale} keywords: no spaces after commas (they count against the limit)`);
    url(`${locale} privacyPolicyUrl`, v.privacyPolicyUrl);
    url(`${locale} supportUrl`, v.supportUrl);
    url(`${locale} marketingUrl`, v.marketingUrl);
    if (v.privacyChoicesUrl != null) url(`${locale} privacyChoicesUrl`, v.privacyChoicesUrl);
    for (const [k, val] of Object.entries(v)) scan(`${locale} ${k}`, val);
  }
  need(typeof l.copyright === 'string' && l.copyright.length > 0, 'copyright missing');
  scan('copyright', l.copyright);
  need(/^[A-Z_]+$/.test(l.primaryCategory ?? ''), 'primaryCategory missing');
  need(['AFTER_APPROVAL', 'MANUAL', 'SCHEDULED'].includes(l.releaseType), `releaseType ${l.releaseType} invalid`);
  limit('review notes', l.review?.notes, LIMITS.reviewNotes);
  scan('review notes', l.review?.notes);
  for (const f of ['contactFirstName', 'contactLastName', 'contactEmail']) {
    need(typeof l.review?.[f] === 'string', `review.${f} must be a string (empty = leave to the owner)`);
  }
  // The repository is public: the phone number comes only from the REVIEW_CONTACT_PHONE secret.
  need(l.review?.contactPhone === undefined, 'review.contactPhone must not be in the JSON (public repo) — use the REVIEW_CONTACT_PHONE secret');
  if (l.review?.contactEmail) need(/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(l.review.contactEmail), 'review.contactEmail is not an email address');

  const iap = l.inAppPurchase;
  need(iap, 'inAppPurchase missing');
  if (iap) {
    need(/^[\w.]+$/.test(iap.productId ?? ''), 'IAP productId missing');
    need(['NON_CONSUMABLE', 'CONSUMABLE', 'NON_RENEWING_SUBSCRIPTION'].includes(iap.type), `IAP type ${iap.type} invalid`);
    limit('IAP referenceName', iap.referenceName, LIMITS.referenceName);
    limit('IAP reviewNote', iap.reviewNote, LIMITS.iapReviewNote);
    for (const [locale, v] of Object.entries(iap.localizations ?? {})) {
      limit(`IAP ${locale} name`, v.name, LIMITS.iapName);
      limit(`IAP ${locale} description`, v.description, LIMITS.iapDescription);
    }
    need(Object.keys(iap.localizations ?? {}).length > 0, 'IAP localizations missing');
    need(/^[A-Z]{3}$/.test(iap.price?.baseTerritory ?? ''), 'IAP price.baseTerritory missing');
    need(Number(iap.price?.customerPrice) > 0, 'IAP price.customerPrice missing');
  }
  return problems;
}

/// Width and height from a PNG's IHDR chunk, or null when it is not a PNG.
export function pngSize(buf) {
  const sig = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  if (buf.length < 24 || !buf.subarray(0, 8).equals(sig) || buf.toString('ascii', 12, 16) !== 'IHDR') return null;
  return { width: buf.readUInt32BE(16), height: buf.readUInt32BE(20) };
}

/// The screenshots for a locale: <dir>/<locale>/ when that folder has any, else <dir>/. Sorted by
/// file name; each with its bytes, md5 and size. Wrong-sized files are reported, not uploaded.
export function localScreenshots(dir, pattern, sizes, locale) {
  const re = new RegExp(pattern);
  const pick = (d) => (fs.existsSync(d) ? fs.readdirSync(d).filter((f) => re.test(f)).sort().map((f) => path.join(d, f)) : []);
  let files = locale ? pick(path.join(dir, locale)) : [];
  if (!files.length) files = pick(dir);
  const ok = [];
  const rejected = [];
  for (const file of files) {
    const data = fs.readFileSync(file);
    const size = pngSize(data);
    const fits = size && sizes.some(([w, h]) => size.width === w && size.height === h);
    if (!fits) { rejected.push(`${path.relative(ROOT, file)}: ${size ? `${size.width}×${size.height}` : 'not a PNG'}`); continue; }
    ok.push({ file, fileName: path.basename(file), data, size: data.length, md5: md5(data) });
  }
  return { ok, rejected };
}

/// The attributes of `desired` whose value differs from `current` (undefined in desired = keep).
export function diff(current, desired) {
  const out = {};
  for (const [k, v] of Object.entries(desired)) {
    if (v === undefined) continue;
    const cur = current?.[k];
    const norm = (x) => (x === '' || x === undefined ? null : x);
    if (norm(cur) !== norm(v)) out[k] = v;
  }
  return out;
}

/// Content-level values of the age rating questionnaire, and attributes that are not content
/// descriptors (left alone even though the GET returns them).
const LEVELS = new Set(['NONE', 'INFREQUENT_OR_MILD', 'FREQUENT_OR_INTENSE', 'INFREQUENT', 'FREQUENT']);
const NOT_CONTENT = new Set([
  'kidsAgeBand', 'ageRatingOverride', 'ageRatingOverrideV2', 'koreaAgeRatingOverride',
  'developerAgeRatingInfoUrl', 'seventeenPlus', 'gamblingAndContests',
]);
/// Attributes Apple documents as level enums / booleans, used only to type an attribute the GET
/// returned as null. Names never come from here alone: only keys present in the GET are set.
const KNOWN_LEVEL = new Set([
  'alcoholTobaccoOrDrugUseOrReferences', 'contests', 'gamblingSimulated', 'gunsOrOtherWeapons',
  'horrorOrFearThemes', 'matureOrSuggestiveThemes', 'medicalOrTreatmentInformation',
  'profanityOrCrudeHumor', 'sexualContentGraphicAndNudity', 'sexualContentOrNudity',
  'violenceCartoonOrFantasy', 'violenceRealistic', 'violenceRealisticProlongedGraphicOrSadistic',
]);
const KNOWN_BOOL = new Set([
  'gambling', 'unrestrictedWebAccess', 'lootBox', 'messagingAndChat', 'parentalControls',
  'ageAssurance', 'userGeneratedContent', 'healthOrWellnessTopics', 'advertising',
]);

/// For an ageRatingDeclaration's attributes (as read), the PATCH that makes every content
/// descriptor "none"/false; plus the names it could not type.
export function ageRatingPatch(attrs) {
  const patch = {};
  const unknown = [];
  for (const [k, v] of Object.entries(attrs ?? {})) {
    if (k === 'kidsAgeBand') { if (v != null) patch[k] = null; continue; } // not Made for Kids
    if (k === 'ageRatingOverride' || k === 'ageRatingOverrideV2' || k === 'koreaAgeRatingOverride') {
      if (v != null && v !== 'NONE') patch[k] = 'NONE';
      continue;
    }
    if (NOT_CONTENT.has(k)) continue;
    if (typeof v === 'boolean' || (v == null && KNOWN_BOOL.has(k))) { if (v !== false) patch[k] = false; continue; }
    if ((typeof v === 'string' && LEVELS.has(v)) || (v == null && KNOWN_LEVEL.has(k))) { if (v !== 'NONE') patch[k] = 'NONE'; continue; }
    unknown.push(`${k}=${JSON.stringify(v)}`);
  }
  return { patch, unknown };
}

export function loadListing(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

// ---------------------------------------------------------------------------------------------
// API plumbing.

let KEY_ID, ISSUER, KEY;
const BASE = 'https://api.appstoreconnect.apple.com';

function token() {
  const b64 = (x) => Buffer.from(x).toString('base64url');
  const now = Math.floor(Date.now() / 1000);
  const head = b64(JSON.stringify({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' }));
  // 19 minutes: Apple rejects tokens that live longer than 20.
  const body = b64(JSON.stringify({ iss: ISSUER, iat: now, exp: now + 19 * 60, aud: 'appstoreconnect-v1' }));
  const sig = crypto.sign('sha256', Buffer.from(`${head}.${body}`), { key: KEY, dsaEncoding: 'ieee-p1363' });
  return `${head}.${body}.${b64(sig)}`;
}

const describe = (json, text) => (json.errors || [])
  .map((e) => `${e.status} ${e.code}: ${e.title ?? ''}${e.detail ? ` — ${e.detail}` : ''}${e.source?.pointer ? ` [${e.source.pointer}]` : ''}${e.source?.parameter ? ` [${e.source.parameter}]` : ''}`)
  .join('; ') || (text || '').slice(0, 500);

/// The review phone number never reaches the log, even if Apple quotes it back in an error.
export const redact = (s, secret = process.env.REVIEW_CONTACT_PHONE) =>
  (secret && secret.trim() ? s.split(secret.trim()).join('[phone]') : s);

/// Throws on a non-2xx with Apple's error detail; err.status and err.errors carry the details.
async function api(method, p, payload) {
  const res = await fetch(p.startsWith('http') ? p : `${BASE}${p}`, {
    method,
    headers: { Authorization: `Bearer ${token()}`, ...(payload ? { 'Content-Type': 'application/json' } : {}) },
    body: payload ? JSON.stringify(payload) : undefined,
  });
  const text = await res.text();
  let json = {};
  try { json = text ? JSON.parse(text) : {}; } catch { json = { raw: text }; }
  if (!res.ok) {
    const err = new Error(redact(`${method} ${p.replace(BASE, '')} → ${res.status} ${describe(json, text)}`));
    err.status = res.status;
    err.errors = json.errors || [];
    throw err;
  }
  return json;
}

/// GET that answers null for 404 (a to-one relationship that does not exist yet).
async function getOrNull(p) {
  try {
    return (await api('GET', p)).data ?? null;
  } catch (e) {
    if (e.status === 404) return null;
    throw e;
  }
}

/// Every page of a collection; returns { data, included }.
async function getAll(p) {
  const data = [];
  const included = [];
  let next = p;
  while (next) {
    const r = await api('GET', next);
    data.push(...(r.data || []));
    included.push(...(r.included || []));
    next = r.links?.next || null;
  }
  return { data, included };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const rel = (type, id) => ({ data: { type, id } });

const failures = [];
async function step(name, fn) {
  console.log(`\n── ${name}`);
  try {
    return await fn();
  } catch (e) {
    failures.push(`${name}: ${e.message}`);
    console.log(`::error::${name}: ${e.message}`);
    return undefined;
  }
}
const log = (msg) => console.log(`   ${msg}`);

/// PATCH only what differs; logs the outcome.
async function patchIfChanged(type, id, current, desired, label) {
  const changes = diff(current, desired);
  if (!Object.keys(changes).length) { log(`${label}: unchanged`); return false; }
  await api('PATCH', `/v1/${type}/${id}`, { data: { type, id, attributes: changes } });
  log(`${label}: updated ${Object.keys(changes).join(', ')}`);
  return true;
}

/// The reservation upload flow shared by screenshots and the IAP review screenshot: POST the
/// reservation, PUT each chunk to Apple's storage with the headers it gives, then commit with the
/// MD5. Returns the committed resource.
async function upload(type, relationships, local, version = 'v1') {
  const reservation = (await api('POST', `/${version}/${type}`, {
    data: { type, attributes: { fileName: local.fileName, fileSize: local.size }, relationships },
  })).data;
  for (const op of reservation.attributes.uploadOperations || []) {
    const headers = Object.fromEntries((op.requestHeaders || []).map((h) => [h.name, h.value]));
    const res = await fetch(op.url, { method: op.method, headers, body: local.data.subarray(op.offset, op.offset + op.length) });
    if (!res.ok) throw new Error(`upload of ${local.fileName} chunk @${op.offset} → ${res.status} ${(await res.text()).slice(0, 300)}`);
  }
  const committed = (await api('PATCH', `/${version}/${type}/${reservation.id}`, {
    data: { type, id: reservation.id, attributes: { uploaded: true, sourceFileChecksum: local.md5 } },
  })).data;
  // Apple processes the image asynchronously; wait briefly so a broken file is reported here.
  for (let i = 0; i < 12; i++) {
    const cur = (await api('GET', `/${version}/${type}/${reservation.id}`)).data;
    const state = cur?.attributes?.assetDeliveryState?.state;
    if (state === 'COMPLETE') { log(`${local.fileName}: uploaded, processed`); return cur; }
    if (state === 'FAILED') throw new Error(`${local.fileName}: Apple failed to process it: ${JSON.stringify(cur.attributes.assetDeliveryState.errors)}`);
    await sleep(5000);
  }
  log(`${local.fileName}: uploaded, still processing`);
  return committed;
}

// ---------------------------------------------------------------------------------------------
// Steps.

const EDITABLE_VERSION_STATES = new Set([
  'PREPARE_FOR_SUBMISSION', 'DEVELOPER_REJECTED', 'REJECTED', 'METADATA_REJECTED', 'INVALID_BINARY', 'READY_FOR_REVIEW',
]);
const LIVE_INFO_STATES = new Set(['READY_FOR_DISTRIBUTION', 'READY_FOR_SALE', 'REPLACED_WITH_NEW_INFO']);

async function appInfoStep(app, L) {
  const infos = (await api('GET', `/v1/apps/${app.id}/appInfos?include=primaryCategory,secondaryCategory`)).data;
  for (const i of infos) log(`appInfo ${i.id}: state ${i.attributes.state ?? i.attributes.appStoreState}`);
  const info = infos.find((i) => !LIVE_INFO_STATES.has(i.attributes.state ?? i.attributes.appStoreState)) ?? infos[0];
  if (!info) throw new Error('the app has no appInfo');
  log(`editing appInfo ${info.id}`);

  const locs = (await getAll(`/v1/appInfos/${info.id}/appInfoLocalizations?limit=50`)).data;
  log(`existing app info locales: ${locs.map((x) => x.attributes.locale).join(', ') || 'none'}`);
  for (const [locale, v] of Object.entries(L.locales)) {
    const desired = { name: v.name, subtitle: v.subtitle, privacyPolicyUrl: v.privacyPolicyUrl, privacyChoicesUrl: v.privacyChoicesUrl ?? undefined };
    const cur = locs.find((x) => x.attributes.locale === locale);
    try {
      if (cur) {
        await patchIfChanged('appInfoLocalizations', cur.id, cur.attributes, desired, `app info ${locale}`);
      } else {
        await api('POST', '/v1/appInfoLocalizations', {
          data: { type: 'appInfoLocalizations', attributes: { locale, ...JSON.parse(JSON.stringify(desired)) },
            relationships: { appInfo: rel('appInfos', info.id) } },
        });
        log(`app info ${locale}: created`);
      }
    } catch (e) {
      failures.push(`app info ${locale}: ${e.message}`);
      console.log(`::error::app info ${locale}: ${e.message}`);
    }
  }

  const curPrimary = info.relationships?.primaryCategory?.data?.id ?? null;
  const curSecondary = info.relationships?.secondaryCategory?.data?.id ?? null;
  if (curPrimary === L.primaryCategory && curSecondary === (L.secondaryCategory ?? null)) {
    log(`categories: unchanged (${curPrimary} / ${curSecondary})`);
  } else {
    await api('PATCH', `/v1/appInfos/${info.id}`, {
      data: { type: 'appInfos', id: info.id, relationships: {
        primaryCategory: rel('appCategories', L.primaryCategory),
        secondaryCategory: L.secondaryCategory ? rel('appCategories', L.secondaryCategory) : { data: null },
      } },
    });
    log(`categories: ${curPrimary} / ${curSecondary} → ${L.primaryCategory} / ${L.secondaryCategory}`);
  }
  return info;
}

async function ageRatingStep(info, version) {
  let decl = await getOrNull(`/v1/appInfos/${info.id}/ageRatingDeclaration`);
  if (!decl && version) decl = await getOrNull(`/v1/appStoreVersions/${version.id}/ageRatingDeclaration`);
  if (!decl) throw new Error('no ageRatingDeclaration found on the appInfo (or the version)');
  log(`ageRatingDeclaration ${decl.id}, attributes returned by the API:`);
  for (const [k, v] of Object.entries(decl.attributes)) log(`  ${k} = ${JSON.stringify(v)}`);
  const { patch, unknown } = ageRatingPatch(decl.attributes);
  if (unknown.length) log(`left as they are (not a recognised content descriptor): ${unknown.join(', ')}`);
  if (!Object.keys(patch).length) { log('age rating: unchanged (all none)'); return; }
  const send = async (attrs) => api('PATCH', `/v1/ageRatingDeclarations/${decl.id}`, { data: { type: 'ageRatingDeclarations', id: decl.id, attributes: attrs } });
  try {
    await send(patch);
  } catch (e) {
    // Drop attributes Apple names as not writable (deprecated ones still come back in the GET).
    const bad = e.errors.map((x) => x.source?.pointer?.match(/\/data\/attributes\/(\w+)/)?.[1]).filter(Boolean);
    if (!bad.length) throw e;
    log(`Apple refused ${bad.join(', ')} (${e.message}); retrying without them`);
    for (const b of bad) delete patch[b];
    await send(patch);
  }
  log(`age rating: set ${Object.keys(patch).join(', ')}`);
}

async function versionStep(app, L, VERSION) {
  const versions = (await api('GET', `/v1/apps/${app.id}/appStoreVersions?filter[platform]=IOS&limit=50`)).data;
  const stateOf = (v) => v.attributes.appVersionState ?? v.attributes.appStoreState;
  for (const v of versions) log(`version ${v.attributes.versionString}: ${stateOf(v)}`);
  let version = versions.find((v) => EDITABLE_VERSION_STATES.has(stateOf(v)));
  if (!version) {
    version = (await api('POST', '/v1/appStoreVersions', {
      data: { type: 'appStoreVersions', attributes: { platform: 'IOS', versionString: VERSION, copyright: L.copyright, releaseType: L.releaseType },
        relationships: { app: rel('apps', app.id) } },
    })).data;
    log(`created version ${VERSION} (${version.id})`);
  } else {
    log(`editing version ${version.attributes.versionString} (${version.id}, ${stateOf(version)})`);
  }
  await patchIfChanged('appStoreVersions', version.id, version.attributes,
    { versionString: VERSION, copyright: L.copyright, releaseType: L.releaseType }, 'version');
  return version;
}

async function versionLocalizationsStep(version, L) {
  const locs = (await getAll(`/v1/appStoreVersions/${version.id}/appStoreVersionLocalizations?limit=50`)).data;
  log(`existing version locales: ${locs.map((x) => x.attributes.locale).join(', ') || 'none'}`);
  const out = {};
  for (const [locale, v] of Object.entries(L.locales)) {
    const desired = { description: v.description, keywords: v.keywords, promotionalText: v.promotionalText, supportUrl: v.supportUrl, marketingUrl: v.marketingUrl };
    const cur = locs.find((x) => x.attributes.locale === locale);
    try {
      if (cur) {
        await patchIfChanged('appStoreVersionLocalizations', cur.id, cur.attributes, desired, `version ${locale}`);
        out[locale] = cur;
      } else {
        out[locale] = (await api('POST', '/v1/appStoreVersionLocalizations', {
          data: { type: 'appStoreVersionLocalizations', attributes: { locale, ...desired },
            relationships: { appStoreVersion: rel('appStoreVersions', version.id) } },
        })).data;
        log(`version ${locale}: created`);
      }
    } catch (e) {
      failures.push(`version ${locale}: ${e.message}`);
      console.log(`::error::version ${locale}: ${e.message}`);
    }
  }
  return out;
}

async function buildStep(app, version, VERSION) {
  const q = `/v1/builds?filter[app]=${app.id}&filter[preReleaseVersion.version]=${encodeURIComponent(VERSION)}` +
    '&filter[processingState]=VALID&filter[expired]=false&sort=-uploadedDate&limit=1';
  const build = (await api('GET', q)).data[0];
  if (!build) throw new Error(`no VALID, unexpired build of ${VERSION} yet — upload one (release workflow), then rerun`);
  log(`newest valid build: ${VERSION} (${build.attributes.version}), uploaded ${build.attributes.uploadedDate}, usesNonExemptEncryption=${build.attributes.usesNonExemptEncryption}`);
  const current = await getOrNull(`/v1/appStoreVersions/${version.id}/build`);
  if (current?.id === build.id) { log('build: unchanged'); return; }
  await api('PATCH', `/v1/appStoreVersions/${version.id}/relationships/build`, { data: { type: 'builds', id: build.id } });
  log(`build: ${current ? current.attributes?.version : 'none'} → ${build.attributes.version}`);
}

/// The review-contact attributes to set: the JSON's non-empty names/email, and the phone from the
/// environment (never from the public repository). Empty values are left out, so whatever the
/// owner typed in App Store Connect stays.
export function reviewDesired(review, phone) {
  const desired = { notes: review.notes, demoAccountRequired: review.demoAccountRequired ?? false };
  for (const f of ['contactFirstName', 'contactLastName', 'contactEmail']) if (review[f]) desired[f] = review[f];
  if (phone && phone.trim()) desired.contactPhone = phone.trim();
  return desired;
}

async function reviewDetailStep(version, L) {
  const desired = reviewDesired(L.review, process.env.REVIEW_CONTACT_PHONE);
  log(`contact phone: ${desired.contactPhone ? 'from REVIEW_CONTACT_PHONE (not printed)' : 'REVIEW_CONTACT_PHONE not set — existing value left as it is'}`);
  const cur = await getOrNull(`/v1/appStoreVersions/${version.id}/appStoreReviewDetail`);
  if (cur) {
    await patchIfChanged('appStoreReviewDetails', cur.id, cur.attributes, desired, 'review details');
    return { ...cur.attributes, ...desired };
  }
  const created = (await api('POST', '/v1/appStoreReviewDetails', {
    data: { type: 'appStoreReviewDetails', attributes: desired, relationships: { appStoreVersion: rel('appStoreVersions', version.id) } },
  })).data;
  log('review details: created');
  return created.attributes;
}

async function screenshotsStep(versionLocs, L, S = L.screenshots) {
  const dir = path.join(ROOT, S.dir);
  for (const [locale, loc] of Object.entries(versionLocs)) {
    const { ok: ours, rejected } = localScreenshots(dir, S.pattern, S.sizes, locale);
    for (const r of rejected) log(`skipping wrong-sized screenshot ${r} (need ${S.sizes.map((s) => s.join('×')).join(' or ')})`);
    if (!ours.length) { log(`${locale}: no screenshots in ${S.dir} matching ${S.pattern} — skipped`); continue; }
    log(`${locale}: ${ours.length} screenshots: ${ours.map((s) => s.fileName).join(', ')}`);

    const sets = (await getAll(`/v1/appStoreVersionLocalizations/${loc.id}/appScreenshotSets?limit=50`)).data;
    log(`${locale}: existing sets: ${sets.map((s) => s.attributes.screenshotDisplayType).join(', ') || 'none'}`);
    let set = S.displayTypes.map((t) => sets.find((s) => s.attributes.screenshotDisplayType === t)).find(Boolean);
    for (const type of S.displayTypes) {
      if (set) break;
      try {
        set = (await api('POST', '/v1/appScreenshotSets', {
          data: { type: 'appScreenshotSets', attributes: { screenshotDisplayType: type },
            relationships: { appStoreVersionLocalization: rel('appStoreVersionLocalizations', loc.id) } },
        })).data;
        log(`${locale}: created set ${type}`);
      } catch (e) {
        // Apple's error lists the accepted values when the type is wrong; print it and try the next.
        log(`${locale}: display type ${type} refused: ${e.message}`);
      }
    }
    if (!set) throw new Error(`${locale}: could not create a screenshot set with any of ${S.displayTypes.join(', ')}`);
    log(`${locale}: using set ${set.attributes.screenshotDisplayType} (${set.id})`);

    const existing = (await getAll(`/v1/appScreenshotSets/${set.id}/appScreenshots?limit=50`)).data;
    const keep = new Map();
    for (const s of existing) {
      const a = s.attributes;
      const match = ours.find((o) => o.md5 === a.sourceFileChecksum && o.fileName === a.fileName);
      if (match && !keep.has(match.fileName) && a.assetDeliveryState?.state !== 'FAILED') {
        keep.set(match.fileName, s.id);
      } else {
        await api('DELETE', `/v1/appScreenshots/${s.id}`);
        log(`${locale}: deleted ${a.fileName} (${a.assetDeliveryState?.state ?? '?'}) — not one of ours`);
      }
    }
    for (const o of ours) {
      if (keep.has(o.fileName)) { log(`${locale}: ${o.fileName} unchanged`); continue; }
      const up = await upload('appScreenshots', { appScreenshotSet: rel('appScreenshotSets', set.id) }, o);
      keep.set(o.fileName, up.id);
    }
    const order = ours.map((o) => ({ type: 'appScreenshots', id: keep.get(o.fileName) }));
    const currentOrder = (await getAll(`/v1/appScreenshotSets/${set.id}/appScreenshots?limit=50`)).data.map((s) => s.id);
    if (currentOrder.join() !== order.map((x) => x.id).join()) {
      await api('PATCH', `/v1/appScreenshotSets/${set.id}/relationships/appScreenshots`, { data: order });
      log(`${locale}: order set`);
    } else {
      log(`${locale}: order unchanged`);
    }
  }
}

/// The app's own price (not the in-app purchase). App Store Connect will not accept a version for
/// review until one is set; the app is free, so this is the 0 price point in the base territory.
async function appPriceStep(app, L) {
  const P = L.appPrice ?? { baseTerritory: 'CHN', customerPrice: '0' };
  const existing = await api('GET', `/v1/apps/${app.id}/appPriceSchedule?include=manualPrices,baseTerritory`).catch(() => null);
  const manual = existing?.data?.relationships?.manualPrices?.data ?? [];
  if (existing?.data && manual.length) {
    log(`price schedule already set (base ${existing.data.relationships?.baseTerritory?.data?.id ?? '?'}, ${manual.length} manual price(s)) — unchanged`);
    return;
  }
  const points = (await getAll(`/v1/apps/${app.id}/appPricePoints?filter[territory]=${P.baseTerritory}&limit=200`)).data;
  const point = points.find((p) => Number(p.attributes.customerPrice) === Number(P.customerPrice));
  if (!point) throw new Error(`no ${P.baseTerritory} price point at ${P.customerPrice} among ${points.length}`);
  const localId = '${price-free}';
  await api('POST', '/v1/appPriceSchedules', {
    data: {
      type: 'appPriceSchedules',
      relationships: {
        app: rel('apps', app.id),
        baseTerritory: rel('territories', P.baseTerritory),
        manualPrices: { data: [{ type: 'appPrices', id: localId }] },
      },
    },
    included: [{
      type: 'appPrices', id: localId,
      attributes: { startDate: null },
      relationships: { appPricePoint: rel('appPricePoints', point.id) },
    }],
  });
  log(`price: set to ${P.customerPrice} (free) with base territory ${P.baseTerritory}`);
}

async function iapStep(app, L) {
  const I = L.inAppPurchase;
  let iap = (await api('GET', `/v1/apps/${app.id}/inAppPurchasesV2?filter[productId]=${encodeURIComponent(I.productId)}&limit=5`))
    .data.find((x) => x.attributes.productId === I.productId);
  const desired = { name: I.referenceName, reviewNote: I.reviewNote, familySharable: I.familySharable };
  if (!iap) {
    iap = (await api('POST', '/v2/inAppPurchases', {
      data: { type: 'inAppPurchases', attributes: { productId: I.productId, inAppPurchaseType: I.type, ...desired },
        relationships: { app: rel('apps', app.id) } },
    })).data;
    log(`created ${I.productId} (${iap.id})`);
  } else {
    log(`found ${I.productId} (${iap.id}), state ${iap.attributes.state}, type ${iap.attributes.inAppPurchaseType}`);
    if (iap.attributes.inAppPurchaseType !== I.type) log(`WARNING: type is ${iap.attributes.inAppPurchaseType}, listing says ${I.type} (type cannot be changed)`);
    const changes = diff(iap.attributes, desired);
    if (Object.keys(changes).length) {
      await api('PATCH', `/v2/inAppPurchases/${iap.id}`, { data: { type: 'inAppPurchases', id: iap.id, attributes: changes } });
      log(`updated ${Object.keys(changes).join(', ')}`);
    } else {
      log('product: unchanged');
    }
  }
  return iap;
}

async function iapLocalizationsStep(iap, L) {
  const locs = (await getAll(`/v2/inAppPurchases/${iap.id}/inAppPurchaseLocalizations?limit=50`)).data;
  for (const [locale, v] of Object.entries(L.inAppPurchase.localizations)) {
    const cur = locs.find((x) => x.attributes.locale === locale);
    if (cur) {
      await patchIfChanged('inAppPurchaseLocalizations', cur.id, cur.attributes, v, `IAP ${locale}`);
    } else {
      await api('POST', '/v1/inAppPurchaseLocalizations', {
        data: { type: 'inAppPurchaseLocalizations', attributes: { locale, ...v },
          relationships: { inAppPurchaseV2: rel('inAppPurchases', iap.id) } },
      });
      log(`IAP ${locale}: created`);
    }
  }
}

async function iapPriceStep(iap, L) {
  const { baseTerritory, customerPrice } = L.inAppPurchase.price;
  const points = (await getAll(`/v2/inAppPurchases/${iap.id}/pricePoints?filter[territory]=${baseTerritory}&limit=200`)).data;
  const point = points.find((p) => Number(p.attributes.customerPrice) === Number(customerPrice));
  if (!point) {
    const near = points.map((p) => Number(p.attributes.customerPrice)).sort((a, b) => Math.abs(a - customerPrice) - Math.abs(b - customerPrice)).slice(0, 5);
    throw new Error(`no ${baseTerritory} price point of ${customerPrice} among ${points.length}; closest: ${near.join(', ')}`);
  }
  log(`${baseTerritory} price point ${customerPrice}: ${point.id} (proceeds ${point.attributes.proceeds})`);

  const schedule = await getOrNull(`/v2/inAppPurchases/${iap.id}/iapPriceSchedule`);
  if (schedule) {
    const base = await getOrNull(`/v1/inAppPurchasePriceSchedules/${schedule.id}/baseTerritory`);
    const { data: prices, included } = await getAll(`/v1/inAppPurchasePriceSchedules/${schedule.id}/manualPrices?include=inAppPurchasePricePoint,territory&limit=200`);
    const now = new Date().toISOString().slice(0, 10);
    const current = prices.find((p) => p.relationships?.territory?.data?.id === baseTerritory &&
      (!p.attributes.startDate || p.attributes.startDate <= now) && (!p.attributes.endDate || p.attributes.endDate > now));
    const curPoint = current && included.find((x) => x.type === 'inAppPurchasePricePoints' && x.id === current.relationships.inAppPurchasePricePoint?.data?.id);
    const curPrice = curPoint ? Number(curPoint.attributes.customerPrice) : null;
    log(`current schedule: base ${base?.id ?? '?'}, ${baseTerritory} price ${curPrice ?? 'none'}`);
    if (base?.id === baseTerritory && (current?.relationships.inAppPurchasePricePoint?.data?.id === point.id || curPrice === Number(customerPrice))) {
      log('price: unchanged');
      return;
    }
  }
  await api('POST', '/v1/inAppPurchasePriceSchedules', {
    data: { type: 'inAppPurchasePriceSchedules', relationships: {
      inAppPurchase: rel('inAppPurchases', iap.id),
      baseTerritory: rel('territories', baseTerritory),
      manualPrices: { data: [{ type: 'inAppPurchasePrices', id: '${price1}' }] },
    } },
    included: [{ type: 'inAppPurchasePrices', id: '${price1}', attributes: { startDate: null },
      relationships: { inAppPurchaseV2: rel('inAppPurchases', iap.id), inAppPurchasePricePoint: rel('inAppPurchasePricePoints', point.id) } }],
  });
  log(`price: set to ${customerPrice} in ${baseTerritory} (other territories follow Apple's equalisation)`);
}

async function iapAvailabilityStep(iap, L) {
  const all = (await getAll('/v1/territories?limit=200')).data.map((t) => t.id).sort();
  log(`territories in the API: ${all.length}`);
  const cur = await getOrNull(`/v2/inAppPurchases/${iap.id}/inAppPurchaseAvailability`);
  if (cur) {
    const have = (await getAll(`/v1/inAppPurchaseAvailabilities/${cur.id}/availableTerritories?limit=200`)).data.map((t) => t.id).sort();
    log(`current availability: ${have.length} territories, availableInNewTerritories=${cur.attributes.availableInNewTerritories}`);
    if (cur.attributes.availableInNewTerritories === L.inAppPurchase.availability.availableInNewTerritories && have.join() === all.join()) {
      log('availability: unchanged');
      return;
    }
  }
  await api('POST', '/v1/inAppPurchaseAvailabilities', {
    data: { type: 'inAppPurchaseAvailabilities',
      attributes: { availableInNewTerritories: L.inAppPurchase.availability.availableInNewTerritories },
      relationships: {
        inAppPurchase: rel('inAppPurchases', iap.id),
        availableTerritories: { data: all.map((id) => ({ type: 'territories', id })) },
      } },
  });
  log(`availability: all ${all.length} territories, new territories included`);
}

async function iapScreenshotStep(iap, L) {
  const file = path.join(ROOT, L.inAppPurchase.reviewScreenshot);
  if (!fs.existsSync(file)) { log(`${L.inAppPurchase.reviewScreenshot} not present — skipped`); return false; }
  const data = fs.readFileSync(file);
  const local = { file, fileName: path.basename(file), data, size: data.length, md5: md5(data) };
  const cur = await getOrNull(`/v2/inAppPurchases/${iap.id}/appStoreReviewScreenshot`);
  if (cur) {
    const state = cur?.attributes?.assetDeliveryState?.state;
    if (state !== 'FAILED') { log(`review screenshot already present (${cur.attributes.fileName}, ${state}) — kept`); return true; }
    await api('DELETE', `/v1/inAppPurchaseAppStoreReviewScreenshots/${cur.id}`);
    log('deleted the failed review screenshot');
  }
  await upload('inAppPurchaseAppStoreReviewScreenshots', { inAppPurchaseV2: rel('inAppPurchases', iap.id) }, local);
  return true;
}

// ---------------------------------------------------------------------------------------------

async function main() {
  const listingFile = path.resolve(ROOT, process.env.LISTING || 'appstore/listing.json');
  const L = loadListing(listingFile);
  const problems = validateListing(L);
  console.log(`listing: ${path.relative(ROOT, listingFile)}`);
  if (problems.length) {
    for (const p of problems) console.log(`::error::${p}`);
    process.exit(1);
  }
  console.log('listing: valid (lengths, URLs, no placeholders)');

  if (process.argv.includes('--check')) {
    for (const locale of Object.keys(L.locales)) {
      const { ok, rejected } = localScreenshots(path.join(ROOT, L.screenshots.dir), L.screenshots.pattern, L.screenshots.sizes, locale);
      console.log(`${locale} screenshots: ${ok.map((s) => s.fileName).join(', ') || 'none'}${rejected.length ? `; wrong size: ${rejected.join(', ')}` : ''}`);
    }
    console.log(`IAP review screenshot: ${fs.existsSync(path.join(ROOT, L.inAppPurchase.reviewScreenshot)) ? 'present' : 'absent'}`);
    return;
  }

  const env = (n) => { const v = process.env[n]; if (!v) throw new Error(`missing env ${n}`); return v; };
  KEY_ID = env('ASC_KEY_ID');
  ISSUER = env('ASC_ISSUER_ID');
  KEY = fs.readFileSync(env('KEY_PATH'), 'utf8');
  const VERSION = (process.env.APP_VERSION || fs.readFileSync(path.join(ROOT, 'RELEASE'), 'utf8').split('\n')[0]).trim();
  if (!/^\d+(\.\d+){0,2}$/.test(VERSION)) throw new Error(`bad version "${VERSION}" (first line of RELEASE)`);

  const app = await step('App', async () => {
    const a = (await api('GET', `/v1/apps?filter[bundleId]=${L.bundleId}&limit=5`)).data.find((x) => x.attributes.bundleId === L.bundleId);
    if (!a) throw new Error(`no app with bundle ID ${L.bundleId}`);
    log(`${a.attributes.name} (${a.id}), bundle ${a.attributes.bundleId}, primary locale ${a.attributes.primaryLocale}`);
    if (L.appId && a.id !== L.appId) log(`WARNING: expected app id ${L.appId}`);
    if (!L.locales[a.attributes.primaryLocale]) log(`WARNING: primary locale ${a.attributes.primaryLocale} is not in the listing; its texts stay as they are`);
    return a;
  });
  if (!app) return finish(L, null);

  const info = await step('App information (localizations, categories)', () => appInfoStep(app, L));
  const version = await step(`App Store version ${VERSION}`, () => versionStep(app, L, VERSION));
  if (info) await step('Age rating', () => ageRatingStep(info, version));
  let versionLocs = null;
  let review = null;
  if (version) {
    versionLocs = await step('Version localizations', () => versionLocalizationsStep(version, L));
    await step('Build', () => buildStep(app, version, VERSION));
    review = await step('App Review information', () => reviewDetailStep(version, L));
    if (versionLocs) await step('Screenshots', () => screenshotsStep(versionLocs, L));
    if (versionLocs && L.screenshotsIpad) {
      await step('Screenshots (13" iPad)', () => screenshotsStep(versionLocs, L, L.screenshotsIpad));
    }
  }
  if (app) await step('App price', () => appPriceStep(app, L));
  const iap = await step('In-app purchase', () => iapStep(app, L));
  let iapShot = false;
  if (iap) {
    await step('In-app purchase localizations', () => iapLocalizationsStep(iap, L));
    await step('In-app purchase price', () => iapPriceStep(iap, L));
    await step('In-app purchase availability', () => iapAvailabilityStep(iap, L));
    iapShot = await step('In-app purchase review screenshot', () => iapScreenshotStep(iap, L));
  }
  finish(L, { review, iapShot, version });
}

function finish(L, state) {
  const r = state?.review ?? {};
  const todo = [
    'App Privacy (App Store Connect > VocabLoop > App Privacy): "No, we do not collect data from this app" > Publish. Not available in the public API.',
  ];
  const contact = ['contactFirstName', 'contactLastName', 'contactEmail', 'contactPhone'].filter((f) => !r[f]);
  if (contact.length) {
    todo.push(`App Review Information on the version page: fill in ${contact.join(', ')}` +
      (contact.includes('contactPhone') ? ' (or add the repository secret REVIEW_CONTACT_PHONE, e.g. +86 138 0000 0000, and rerun)' : '') + '.');
  }
  if (state && !state.iapShot) todo.push(`In-app purchase review screenshot: add ${L.inAppPurchase.reviewScreenshot} (Settings > VocabLoop Plus) and rerun, or upload it on the IAP page.`);
  todo.push('Paid Applications Agreement, bank and tax info (Business) — needed before the IAP can be sold or tested.');
  todo.push(`Version page > "In-App Purchases and Subscriptions": tick ${L.inAppPurchase.productId} (the first IAP must ship with a version).`);
  todo.push('Version page: check everything, then "Add for Review" > "Submit for Review". This script never submits.');
  console.log('\n── Still for the owner, in the App Store Connect web UI:');
  todo.forEach((t, i) => console.log(`   ${i + 1}. ${t}`));
  if (failures.length) {
    console.log(`\n${failures.length} step(s) failed:`);
    for (const f of failures) console.log(`   - ${f}`);
    process.exit(1);
  }
  console.log('\nAll steps succeeded.');
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch((e) => { console.error(`::error::${e.message}`); process.exit(1); });
}
