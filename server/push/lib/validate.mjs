// Strict input validation. Every validator returns { ok: true, value } or { ok: false, error }.
// Unknown fields are rejected with a clear message instead of being silently stored.

export const ENVIRONMENTS = ['sandbox', 'production'];
export const LANGUAGES = ['en', 'fr', 'th'];
export const TITLE_MAX = 50;
export const BODY_MAX = 200;

const TOKEN_RE = /^[0-9a-f]{64,200}$/;
const APP_VERSION_RE = /^[0-9A-Za-z.+\-_ ()]{1,32}$/;
const LOCALE_RE = /^[A-Za-z0-9_\-@=.;]{1,35}$/;
// C0/C1 control characters except TAB and LF (allowed in the body only).
const CONTROL_RE = /[\u0000-\u0008\u000B-\u001F\u007F-\u009F]/;

const isPlainObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const fail = (error) => ({ ok: false, error });

function checkFields(obj, allowed) {
  if (!isPlainObject(obj)) return 'body must be a JSON object';
  for (const k of Object.keys(obj)) if (!allowed.includes(k)) return `unknown field: ${k.slice(0, 40)}`;
  return null;
}

/** Number of user-visible characters (code points), so emoji / Thai / Chinese count sensibly. */
export const charLength = (s) => [...s].length;

export function normalizeToken(token) {
  if (typeof token !== 'string') return null;
  const t = token.trim().toLowerCase();
  return TOKEN_RE.test(t) ? t : null;
}

export function validateRegister(obj) {
  const bad = checkFields(obj, ['token', 'environment', 'language', 'appVersion', 'locale']);
  if (bad) return fail(bad);
  const token = normalizeToken(obj.token);
  if (!token) return fail('token must be 64-200 hex characters');
  if (!ENVIRONMENTS.includes(obj.environment)) return fail('environment must be "sandbox" or "production"');
  if (!LANGUAGES.includes(obj.language)) return fail('language must be "en", "fr" or "th"');
  let appVersion = null;
  if (obj.appVersion !== undefined && obj.appVersion !== null) {
    if (typeof obj.appVersion !== 'string' || !APP_VERSION_RE.test(obj.appVersion)) return fail('appVersion is invalid');
    appVersion = obj.appVersion;
  }
  let locale = null;
  if (obj.locale !== undefined && obj.locale !== null) {
    if (typeof obj.locale !== 'string' || !LOCALE_RE.test(obj.locale)) return fail('locale is invalid');
    locale = obj.locale;
  }
  return { ok: true, value: { token, environment: obj.environment, language: obj.language, appVersion, locale } };
}

export function validateUnregister(obj) {
  const bad = checkFields(obj, ['token']);
  if (bad) return fail(bad);
  const token = normalizeToken(obj.token);
  if (!token) return fail('token must be 64-200 hex characters');
  return { ok: true, value: { token } };
}

function cleanText(v, name, max, allowNewlines) {
  if (typeof v !== 'string') return { error: `${name} is required` };
  const s = v.replace(/\r\n?/g, '\n').trim();
  if (!s) return { error: `${name} must not be empty` };
  if (CONTROL_RE.test(s) || (!allowNewlines && /[\n\t]/.test(s))) return { error: `${name} contains control characters` };
  if (charLength(s) > max) return { error: `${name} must be at most ${max} characters` };
  return { value: s };
}

export function validateSend(obj) {
  const bad = checkFields(obj, ['title', 'body', 'language', 'environment', 'dryRun']);
  if (bad) return fail(bad);
  const title = cleanText(obj.title, 'title', TITLE_MAX, false);
  if (title.error) return fail(title.error);
  const body = cleanText(obj.body, 'body', BODY_MAX, true);
  if (body.error) return fail(body.error);
  let language = null;
  if (obj.language !== undefined && obj.language !== null && obj.language !== '' && obj.language !== 'all') {
    if (!LANGUAGES.includes(obj.language)) return fail('language must be "en", "fr", "th" or omitted');
    language = obj.language;
  }
  if (!ENVIRONMENTS.includes(obj.environment)) return fail('environment must be "sandbox" or "production"');
  if (obj.dryRun !== undefined && typeof obj.dryRun !== 'boolean') return fail('dryRun must be a boolean');
  return {
    ok: true,
    value: { title: title.value, body: body.value, language, environment: obj.environment, dryRun: obj.dryRun === true },
  };
}

/** Last 6 characters only — full device tokens never go to the log. */
export const tokenTail = (t) => `…${String(t).slice(-6)}`;
