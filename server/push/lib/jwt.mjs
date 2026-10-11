// APNs provider authentication token (JWT, ES256). Apple rejects tokens older than one hour and
// throttles tokens refreshed more often than every 20 minutes, so we cache for 50 minutes.
import crypto from 'node:crypto';

export const JWT_TTL_MS = 50 * 60 * 1000;

const b64url = (x) => Buffer.from(x).toString('base64url');

export function signProviderToken({ key, keyId, teamId, now = Date.now() }) {
  const header = b64url(JSON.stringify({ alg: 'ES256', kid: keyId }));
  const claims = b64url(JSON.stringify({ iss: teamId, iat: Math.floor(now / 1000) }));
  const sig = crypto.sign('sha256', Buffer.from(`${header}.${claims}`), { key, dsaEncoding: 'ieee-p1363' });
  return `${header}.${claims}.${b64url(sig)}`;
}

export class ProviderToken {
  /** key: PEM string or KeyObject (the .p8 contents). */
  constructor({ key, keyId, teamId, clock = () => Date.now() }) {
    this.key = typeof key === 'string' ? crypto.createPrivateKey(key) : key;
    if (this.key.asymmetricKeyType !== 'ec') throw new Error('APNs key must be an EC (P-256) private key (.p8)');
    this.keyId = keyId;
    this.teamId = teamId;
    this.clock = clock;
    this.cached = null;
    this.issuedAt = 0;
  }

  get() {
    const now = this.clock();
    if (!this.cached || now - this.issuedAt >= JWT_TTL_MS) {
      this.cached = signProviderToken({ key: this.key, keyId: this.keyId, teamId: this.teamId, now });
      this.issuedAt = now;
    }
    return this.cached;
  }

  /**
   * Force a new token on the next get() (after APNs says ExpiredProviderToken). Ignored if the
   * current token is younger than 20 minutes, because refreshing faster makes APNs answer
   * 429 TooManyProviderTokenUpdates.
   */
  invalidate() {
    if (this.clock() - this.issuedAt >= 20 * 60 * 1000) this.cached = null;
  }
}
