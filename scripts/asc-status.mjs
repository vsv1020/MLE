// Read-only: prints where the app stands in App Store Connect — version and review state,
// the attached build, the in-app purchase, and the newest TestFlight builds.
import crypto from 'node:crypto';
import fs from 'node:fs';

const env = (n) => { const v = process.env[n]; if (!v) throw new Error(`missing env ${n}`); return v; };
const KEY_ID = env('ASC_KEY_ID'), ISSUER = env('ASC_ISSUER_ID'), KEY = fs.readFileSync(env('KEY_PATH'), 'utf8');
const BUNDLE_ID = 'com.vocabloop.app';

function token() {
  const b64 = (x) => Buffer.from(x).toString('base64url');
  const now = Math.floor(Date.now() / 1000);
  const h = b64(JSON.stringify({ alg: 'ES256', kid: KEY_ID, typ: 'JWT' }));
  const b = b64(JSON.stringify({ iss: ISSUER, iat: now, exp: now + 19 * 60, aud: 'appstoreconnect-v1' }));
  const s = crypto.sign('sha256', Buffer.from(`${h}.${b}`), { key: KEY, dsaEncoding: 'ieee-p1363' });
  return `${h}.${b}.${b64(s)}`;
}
async function get(path) {
  const res = await fetch(`https://api.appstoreconnect.apple.com${path}`, { headers: { Authorization: `Bearer ${token()}` } });
  const text = await res.text();
  if (!res.ok) throw new Error(`GET ${path} → ${res.status} ${text.slice(0, 300)}`);
  return JSON.parse(text);
}
const safe = async (label, fn) => { try { await fn(); } catch (e) { console.log(`${label}: ${e.message}`); } };

const app = (await get(`/v1/apps?filter[bundleId]=${BUNDLE_ID}&limit=1`)).data[0];
console.log(`App: ${app.attributes.name} (${app.id})`);

await safe('versions', async () => {
  const vs = await get(`/v1/apps/${app.id}/appStoreVersions?limit=5&include=build`);
  for (const v of vs.data) {
    const a = v.attributes;
    const buildId = v.relationships?.build?.data?.id;
    const build = (vs.included || []).find((x) => x.id === buildId);
    console.log(`Version ${a.versionString}: appStoreState=${a.appStoreState} appVersionState=${a.appVersionState ?? '-'} build=${build ? build.attributes.version : 'none'} created=${a.createdDate}`);
  }
});

await safe('review submissions', async () => {
  const rs = await get(`/v1/reviewSubmissions?filter[app]=${app.id}&limit=5`);
  if (!rs.data.length) console.log('Review submissions: none (not submitted yet)');
  for (const r of rs.data) console.log(`Review submission ${r.id}: state=${r.attributes.state} submitted=${r.attributes.submittedDate ?? '-'}`);
});

await safe('in-app purchases', async () => {
  const iaps = await get(`/v1/apps/${app.id}/inAppPurchasesV2?limit=10`);
  for (const p of iaps.data) {
    console.log(`IAP ${p.attributes.productId}: ${JSON.stringify(p.attributes)}`);
    // Everything App Review needs on the purchase, so a "cannot be reviewed" says which part.
    await safe('  localizations', async () => {
      for (const l of (await get(`/v2/inAppPurchases/${p.id}/inAppPurchaseLocalizations?limit=20`)).data) {
        console.log(`  localization ${JSON.stringify(l.attributes)}`);
      }
    });
    await safe('  review screenshot', async () => {
      const s = await get(`/v2/inAppPurchases/${p.id}/appStoreReviewScreenshot`).catch(() => null);
      const a = s?.data?.attributes;
      console.log(a
        ? `  review screenshot: ${a.fileName} ${a.fileSize}B ${a.imageAsset?.width ?? '?'}x${a.imageAsset?.height ?? '?'} delivery=${JSON.stringify(a.assetDeliveryState)}`
        : '  review screenshot: none');
    });
    await safe('  price', async () => {
      const ps = await get(`/v2/inAppPurchases/${p.id}/iapPriceSchedule?include=baseTerritory,manualPrices`);
      console.log(`  price schedule: base=${ps.data.relationships?.baseTerritory?.data?.id ?? '-'} manual=${(ps.included || []).filter((x) => x.type === 'inAppPurchasePrices').length}`);
    });
    await safe('  availability', async () => {
      const av = await get(`/v2/inAppPurchases/${p.id}/inAppPurchaseAvailability`);
      console.log(`  availability: ${JSON.stringify(av.data.attributes)}`);
    });
    await safe('  content', async () => {
      const c = await get(`/v2/inAppPurchases/${p.id}/content`).catch(() => null);
      if (c) console.log(`  content: ${JSON.stringify(c.data.attributes)}`);
    });
  }
});

await safe('review detail', async () => {
  const vs = await get(`/v1/apps/${app.id}/appStoreVersions?limit=1`);
  const v = vs.data[0];
  const d = await get(`/v1/appStoreVersions/${v.id}/appStoreReviewDetail`).catch(() => null);
  const a = d?.data?.attributes;
  console.log(a ? `Review contact: name=${a.contactFirstName ?? '-'} ${a.contactLastName ?? '-'}, email=${a.contactEmail ? 'set' : 'missing'}, phone=${a.contactPhone ? 'set' : 'missing'}` : 'Review contact: not created yet');
});

await safe('builds', async () => {
  const bs = await get(`/v1/builds?filter[app]=${app.id}&sort=-uploadedDate&limit=3&include=preReleaseVersion`);
  for (const b of bs.data) {
    const pre = (bs.included || []).find((x) => x.id === b.relationships?.preReleaseVersion?.data?.id);
    console.log(`Build ${pre?.attributes?.version ?? '?'} (${b.attributes.version}): ${b.attributes.processingState}`);
  }
});
