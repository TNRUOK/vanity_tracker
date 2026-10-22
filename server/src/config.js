import path from 'node:path';
import { fileURLToPath } from 'node:url';

const serverRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

/** Loads server/.env into process.env if it exists (Node >= 20.12). */
export function loadDotEnv(file = path.join(serverRoot, '.env')) {
  try {
    process.loadEnvFile(file);
    return true;
  } catch (e) {
    if (e && e.code === 'ENOENT') return false;
    throw e;
  }
}

function intFrom(env, key, fallback) {
  const raw = env[key];
  if (raw === undefined || raw === '') return fallback;
  const n = Number.parseInt(raw, 10);
  return Number.isFinite(n) && n >= 0 ? n : fallback;
}

/** Builds the runtime configuration. Secrets stay inside this object and are never logged. */
export function buildConfig(env = process.env) {
  const gmailUser = (env.GMAIL_USER || '').trim();
  // Google shows App Passwords in groups of four ("abcd efgh ..."); spaces are not part of it.
  const gmailAppPassword = (env.GMAIL_APP_PASSWORD || '').replace(/\s+/g, '');
  const allowedOrigins = (env.ALLOWED_ORIGINS || '')
    .split(',')
    .map((o) => o.trim())
    .filter(Boolean);

  const appUrlCheck = validateAppUrl(env.APP_URL);

  return {
    projectId: (env.FIREBASE_PROJECT_ID || '').trim(),
    host: (env.HOST || '127.0.0.1').trim(),
    port: intFrom(env, 'PORT', 8787),
    allowedOrigins,
    // Validated, normalized URL for the email button (null when missing/invalid).
    appUrl: appUrlCheck.url,
    appUrlWarning: appUrlCheck.warning,
    mail: {
      user: gmailUser,
      appPassword: gmailAppPassword,
      fromName: (env.MAIL_FROM_NAME || 'Vanity Tracker').replace(/[\r\n"]/g, '').trim(),
      host: (env.SMTP_HOST || 'smtp.gmail.com').trim(),
      port: intFrom(env, 'SMTP_PORT', 465),
    },
    limits: {
      perUserPerHour: intFrom(env, 'MAX_SENDS_PER_USER_PER_HOUR', 10),
      perDay: intFrom(env, 'MAX_SENDS_PER_DAY', 100),
      resendCooldownMs: intFrom(env, 'RESEND_COOLDOWN_SECONDS', 60) * 1000,
      maxAttemptsPerInvitation: intFrom(env, 'MAX_ATTEMPTS_PER_INVITATION', 5),
    },
  };
}

/**
 * Validates APP_URL (the public address of the web app linked from invitation emails).
 * Returns { url, warning }: `url` is a normalized http(s) URL or null; `warning` explains
 * a missing/invalid/unreachable value. Never invents a URL.
 */
export function validateAppUrl(raw) {
  const value = String(raw ?? '').trim();
  if (!value) {
    return { url: null, warning: 'APP_URL is not set, so invitation emails will not include an "Open Vanity Tracker" link. Set APP_URL in server/.env to the public address of the web app.' };
  }
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    return { url: null, warning: `APP_URL "${value}" is not a valid URL, so invitation emails will not include a link. Use a full address such as https://your-app.web.app` };
  }
  if (!['http:', 'https:'].includes(parsed.protocol) || !parsed.hostname || parsed.username || parsed.password || /[\s"'<>]/.test(value)) {
    return { url: null, warning: `APP_URL "${value}" must be a plain http(s) address without credentials, so invitation emails will not include a link.` };
  }
  const url = parsed.href;
  if (['localhost', '127.0.0.1', '[::1]', '0.0.0.0'].includes(parsed.hostname)) {
    return { url, warning: `APP_URL (${url}) points to this laptop; recipients on other devices cannot open it. Use the public address of the web app for real invitations.` };
  }
  if (parsed.protocol === 'http:') {
    return { url, warning: `APP_URL (${url}) uses http://; email clients may flag it as unsafe. Prefer https://.` };
  }
  return { url, warning: null };
}

/** Human-readable list of missing settings; empty when email sending is configured. */
export function missingMailSettings(config) {
  const missing = [];
  if (!config.mail.user || config.mail.user === 'your.address@gmail.com') missing.push('GMAIL_USER');
  if (!config.mail.appPassword) missing.push('GMAIL_APP_PASSWORD');
  return missing;
}

/** Masks an email for logs: karthick@gmail.com -> k***@gmail.com */
export function maskEmail(email) {
  if (typeof email !== 'string' || !email.includes('@')) return '***';
  const [local, domain] = email.split('@');
  return `${local.slice(0, 1)}***@${domain}`;
}
