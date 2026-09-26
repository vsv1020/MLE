// Puts a freshly uploaded build in front of testers.
//
// Uploading is not enough: a TestFlight build is invisible until it belongs to a testing group.
// 1.0.0 (2) uploaded successfully and nobody could see it for exactly that reason. This script
// waits for App Store Connect to finish processing the build, makes sure an internal group with
// access to every build exists, adds the build and the testers to it, sets "What to Test" from
// the RELEASE notes, and sends each tester an invitation email.
//
// Runs on the GitHub runner, which can reach api.appstoreconnect.apple.com. No dependencies:
// Node's own crypto signs the ES256 token.
import crypto from 'node:crypto';
import fs from 'node:fs';

const env = (name) => {
  const v = process.env[name];
  if (!v) throw new Error(`missing env ${name}`);
  return v;
};
const KEY_ID = env('ASC_KEY_ID');
const ISSUER = env('ASC_ISSUER_ID');
const KEY = fs.readFileSync(env('KEY_PATH'), 'utf8');
const BUNDLE_ID = env('BUNDLE_ID');
const VERSION = env('APP_VERSION');
// Optional: without it, the newest build of APP_VERSION is used (the distribute-only workflow).
const BUILD = process.env.BUILD_NUMBER || '';
const TESTERS = env('TESTFLIGHT_TESTERS').split(/[\s,]+/).filter(Boolean);
const GROUP_NAME = process.env.TESTFLIGHT_GROUP || 'Internal';
const NOTES = process.env.WHATS_NEW || '';

function token() {
  const b64 = (x) => Buffer.from(x).toString('base64url');
  const now = Math.floor(Date.now() / 1000);
  const head = b64(JSON.stringify({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' }));
  // 19 minutes: Apple rejects tokens that live longer than 20.
  const body = b64(JSON.stringify({ iss: ISSUER, iat: now, exp: now + 19 * 60, aud: 'appstoreconnect-v1' }));
  const sig = crypto.sign('sha256', Buffer.from(`${head}.${body}`), { key: KEY, dsaEncoding: 'ieee-p1363' });
  return `${head}.${body}.${b64(sig)}`;
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
    const detail = (json.errors || []).map((e) => `${e.status} ${e.code}: ${e.detail}`).join('; ') || text;
    const err = new Error(`${method} ${path} → ${res.status} ${detail}`);
    err.status = res.status;
    throw err;
  }
  return json;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
  const apps = await api('GET', `/v1/apps?filter[bundleId]=${BUNDLE_ID}&limit=1`);
  if (!apps.data.length) throw new Error(`no App Store Connect app with bundle ID ${BUNDLE_ID}`);
  const appId = apps.data[0].id;
  console.log(`app ${appId}`);

  // Processing usually takes 5–20 minutes; the upload step returns as soon as it has started.
  let build;
  const deadline = Date.now() + 40 * 60 * 1000;
  while (Date.now() < deadline) {
    const q = `/v1/builds?filter[app]=${appId}` + (BUILD ? `&filter[version]=${BUILD}` : '') +
      `&filter[preReleaseVersion.version]=${VERSION}&sort=-uploadedDate&fields[builds]=processingState,version&limit=1`;
    const found = (await api('GET', q)).data[0];
    const state = found?.attributes.processingState ?? 'NOT_YET_VISIBLE';
    console.log(`build ${VERSION} (${found?.attributes.version ?? BUILD}): ${state}`);
    if (state === 'VALID') { build = found; break; }
    if (state === 'FAILED' || state === 'INVALID') {
      throw new Error(`App Store Connect rejected build ${VERSION} (${BUILD}) during processing: ${state}. Check the email Apple sent.`);
    }
    await sleep(30_000);
  }
  if (!build) throw new Error('timed out waiting for the build to finish processing');

  if (NOTES.trim()) {
    const locs = await api('GET', `/v1/builds/${build.id}/betaBuildLocalizations`);
    const existing = locs.data.find((l) => l.attributes.locale.startsWith('en')) || locs.data[0];
    if (existing) {
      await api('PATCH', `/v1/betaBuildLocalizations/${existing.id}`, {
        data: { type: 'betaBuildLocalizations', id: existing.id, attributes: { whatsNew: NOTES } },
      });
    } else {
      await api('POST', '/v1/betaBuildLocalizations', {
        data: { type: 'betaBuildLocalizations', attributes: { locale: 'en-US', whatsNew: NOTES },
          relationships: { build: { data: { type: 'builds', id: build.id } } } },
      });
    }
    console.log('what to test: set');
  }

  // An internal group with access to every build, so future uploads reach testers without this
  // step having to add each one. Internal testing needs no Beta App Review.
  let group = (await api('GET', `/v1/betaGroups?filter[app]=${appId}&filter[name]=${encodeURIComponent(GROUP_NAME)}&limit=1`)).data[0];
  if (!group) {
    group = (await api('POST', '/v1/betaGroups', {
      data: { type: 'betaGroups', attributes: { name: GROUP_NAME, isInternalGroup: true, hasAccessToAllBuilds: true },
        relationships: { app: { data: { type: 'apps', id: appId } } } },
    })).data;
    console.log(`created internal group "${GROUP_NAME}"`);
  }
  try {
    await api('POST', `/v1/betaGroups/${group.id}/relationships/builds`, { data: [{ type: 'builds', id: build.id }] });
    console.log('build added to group');
  } catch (e) {
    // A group with access to all builds already includes it; Apple answers that with a conflict.
    if (e.status !== 409 && e.status !== 422) throw e;
    console.log('build already available to group');
  }

  for (const email of TESTERS) {
    // Internal groups accept only members of the App Store Connect team, so say up front whether
    // this address is one — the second release run failed on exactly this, silently.
    try {
      const users = await api('GET', `/v1/users?filter[username]=${encodeURIComponent(email)}&fields[users]=username,roles,allAppsVisible&limit=1`);
      const u = users.data[0];
      console.log(u
        ? `${email}: team user, roles ${u.attributes.roles.join(', ')}`
        : `${email}: NOT a user of this App Store Connect team (Users and Access)`);
    } catch (e) {
      console.log(`${email}: could not check team membership (${e.message})`);
    }
    let tester = (await api('GET', `/v1/betaTesters?filter[email]=${encodeURIComponent(email)}&filter[apps]=${appId}&limit=1`)).data[0]
      ?? (await api('GET', `/v1/betaTesters?filter[email]=${encodeURIComponent(email)}&limit=1`)).data[0];
    console.log(`${email}: tester record ${tester ? tester.id : 'none'}`);
    if (!tester) {
      try {
        tester = (await api('POST', '/v1/betaTesters', {
          data: { type: 'betaTesters', attributes: { email },
            relationships: { betaGroups: { data: [{ type: 'betaGroups', id: group.id }] } } },
        })).data;
      } catch (e) {
        throw new Error(`could not add ${email} to the internal group: ${e.message}\n` +
          'Internal testers must be users of this App Store Connect team (Users and Access).');
      }
    } else {
      try {
        await api('POST', `/v1/betaGroups/${group.id}/relationships/betaTesters`, { data: [{ type: 'betaTesters', id: tester.id }] });
        console.log(`${email}: added to "${GROUP_NAME}"`);
      } catch (e) {
        // Print Apple's own words. This used to swallow 409 *and* 422 as "already a member", and
        // the 422 was the real refusal — the membership check below then caught it.
        console.log(`${email}: adding to "${GROUP_NAME}" was refused — ${e.message}`);
        if (e.status !== 409 && e.status !== 422) throw e;
      }
    }
    try {
      await api('POST', '/v1/betaTesterInvitations', {
        data: { type: 'betaTesterInvitations', relationships: {
          app: { data: { type: 'apps', id: appId } },
          betaTester: { data: { type: 'betaTesters', id: tester.id } } } },
      });
      console.log(`invitation sent to ${email}`);
    } catch (e) {
      // The invitation endpoint serves external testers. For a member of the App Store Connect
      // team it answers 404 for a tester the same API just returned — the first real run hit
      // exactly that. Internal testers are notified by TestFlight itself when a build reaches
      // their group, so this is not a failure; membership is verified below instead.
      if (![404, 409, 422].includes(e.status)) throw e;
      console.log(`${email}: internal tester, no invitation needed (TestFlight notifies on new builds)`);
    }
  }

  // Verify rather than assume: read the group back and confirm every tester is in it.
  const members = await api('GET', `/v1/betaGroups/${group.id}/betaTesters?limit=200&fields[betaTesters]=email,state`);
  const byEmail = new Map(members.data.map((m) => [m.attributes.email?.toLowerCase(), m.attributes.state]));
  for (const email of TESTERS) {
    if (!byEmail.has(email.toLowerCase())) {
      throw new Error(`${email} is not in group "${GROUP_NAME}" after adding — check App Store Connect ▸ TestFlight`);
    }
    console.log(`verified: ${email} is in "${GROUP_NAME}" (state: ${byEmail.get(email.toLowerCase()) ?? 'unknown'})`);
  }
  console.log(`\n${VERSION} (${build.attributes.version}) is available in TestFlight to group "${GROUP_NAME}".`);
}

main().catch((e) => { console.error(`::error::${e.message}`); process.exit(1); });
