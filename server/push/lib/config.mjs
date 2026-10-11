// Reads configuration from environment variables (systemd loads them from /etc/mashu-push.env).
import fs from 'node:fs';
import crypto from 'node:crypto';

export const MIN_PASSWORD = 12;

export function loadConfig(env = process.env) {
  const errors = [];
  const warnings = [];

  const adminUser = (env.ADMIN_USER || 'admin').trim();
  const adminPassword = env.ADMIN_PASSWORD || '';
  if (!adminPassword) errors.push('ADMIN_PASSWORD is not set');
  else if (adminPassword.length < MIN_PASSWORD) errors.push(`ADMIN_PASSWORD must be at least ${MIN_PASSWORD} characters`);
  if (!adminUser || adminUser.includes(':')) errors.push('ADMIN_USER must be non-empty and must not contain ":"');

  const port = Number(env.PORT || 8787);
  if (!Number.isInteger(port) || port < 1 || port > 65535) errors.push('PORT must be a number between 1 and 65535');

  const dataDir = env.DATA_DIR || '/var/lib/mashu-push';

  // Optional: APNs credentials from the environment. Settings saved on /push-admin override these.
  // APNs key: APNS_KEY_PATH (file) wins over APNS_KEY_P8 (contents; "\n" escapes allowed).
  let apnsKey = null;
  const keyId = (env.APNS_KEY_ID || '').trim();
  const teamId = (env.APPLE_TEAM_ID || '').trim();
  let pem = null;
  if (env.APNS_KEY_PATH) {
    try { pem = fs.readFileSync(env.APNS_KEY_PATH, 'utf8'); }
    catch (e) { errors.push(`cannot read APNS_KEY_PATH ${env.APNS_KEY_PATH}: ${e.code || e.message}`); }
  } else if (env.APNS_KEY_P8) {
    pem = env.APNS_KEY_P8.replace(/\\n/g, '\n');
  }
  if (pem) {
    try {
      apnsKey = crypto.createPrivateKey(pem);
      if (apnsKey.asymmetricKeyType !== 'ec') { errors.push('the APNs key is not an EC key — use the AuthKey_XXXXXXXXXX.p8 file'); apnsKey = null; }
    } catch (e) {
      errors.push(`the APNs key could not be parsed (${e.message}) — use the AuthKey_XXXXXXXXXX.p8 file`);
    }
  }
  if (apnsKey || keyId || teamId) {
    if (!apnsKey && !errors.some((x) => x.includes('APNs key') || x.includes('APNS_KEY_PATH'))) errors.push('APNS_KEY_PATH (or APNS_KEY_P8) is not set');
    if (!/^[A-Z0-9]{10}$/.test(keyId) || keyId === 'XXXXXXXXXX') errors.push('APNS_KEY_ID must be the 10-character key ID (e.g. ABC123DEFG)');
    if (!/^[A-Z0-9]{10}$/.test(teamId) || teamId === 'XXXXXXXXXX') errors.push('APPLE_TEAM_ID must be the 10-character team ID');
  } else {
    warnings.push('APNs is not configured in the environment (it can be set on /push-admin → 推送设置; until then devices can register, but sending is disabled)');
  }

  return {
    errors,
    warnings,
    config: { adminUser, adminPassword, port, dataDir, apns: apnsKey ? { key: apnsKey, keyId, teamId } : null },
  };
}
