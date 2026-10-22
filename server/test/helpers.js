import { createApp } from '../src/app.js';
import { AuthError } from '../src/auth.js';
import { buildConfig } from '../src/config.js';
import { FirestoreError } from '../src/firestore.js';
import { HttpError, RateLimiter, createInvitationEmailService } from '../src/invitationService.js';
import { createMailer } from '../src/mailer.js';

export const silentLog = { info() {}, warn() {}, error() {} };

/** In-memory stand-in for the user-scoped Firestore REST client. */
export function fakeFirestore(docs = {}) {
  const store = structuredClone(docs);
  const writes = [];
  return {
    store,
    writes,
    deny: new Set(),
    async getDoc(collection, id) {
      if (this.deny.has(`${collection}/${id}`)) throw new FirestoreError('denied', 403);
      const d = store[collection]?.[id];
      return d ? structuredClone(d) : null;
    },
    async updateFields(collection, id, fields) {
      writes.push({ collection, id, fields });
      store[collection][id] = { ...store[collection][id], ...fields };
      return store[collection][id];
    },
  };
}

/** Fake Nodemailer transport: records messages, can be told to fail. */
export function fakeTransport({ fail, reject, delayMs = 0 } = {}) {
  const sent = [];
  return {
    sent,
    async verify() { return true; },
    async sendMail(msg) {
      if (delayMs) await new Promise((r) => setTimeout(r, delayMs));
      if (fail) throw fail;
      sent.push(msg);
      return reject
        ? { accepted: [], rejected: [msg.to], response: '550 5.1.1 rejected', messageId: '<x@test>' }
        : { accepted: [msg.to], rejected: [], response: '250 2.0.0 OK test', messageId: '<abc@test>' };
    },
  };
}

export const OWNER = { uid: 'owner_uid', email: 'owner@gmail.com', emailVerified: true };
export const OTHER = { uid: 'other_uid', email: 'other@gmail.com', emailVerified: true };

export function baseDocs(overrides = {}) {
  const future = new Date(Date.now() + 7 * 86400_000).toISOString();
  return {
    households: {
      hh_1: {
        household_id: 'hh_1',
        name: 'Sunny <b>Villa</b>',
        created_by: OWNER.uid,
        member_uids: [OWNER.uid],
        member_emails: { [OWNER.uid]: OWNER.email },
        ...(overrides.household || {}),
      },
    },
    household_invitations: {
      inv_1: {
        invitation_id: 'inv_1',
        household_id: 'hh_1',
        household_name: 'Sunny Villa',
        invited_email: 'friend@gmail.com',
        invited_by_uid: OWNER.uid,
        invited_by_name: 'Owner',
        expires_at: future,
        status: 'pending',
        email_delivery_status: 'queued',
        ...(overrides.invitation || {}),
      },
    },
  };
}

/** Starts the app on an ephemeral port. Tokens are "token-<uid>" mapped to users. */
export async function startTestServer({ docs = baseDocs(), env = {}, transport = fakeTransport(), users = [OWNER, OTHER] } = {}) {
  const config = buildConfig({
    FIREBASE_PROJECT_ID: 'vanity-tracker',
    GMAIL_USER: 'sender@gmail.com',
    GMAIL_APP_PASSWORD: 'test-only-not-a-real-password',
    RESEND_COOLDOWN_SECONDS: '60',
    ...env,
  });
  const firestore = fakeFirestore(docs);
  const mailer = createMailer(config, config.mail.appPassword ? transport : undefined);
  const invitationService = createInvitationEmailService({
    config, firestore, mailer, limiter: new RateLimiter(), log: silentLog,
  });
  const verifyIdToken = async (token) => {
    const u = users.find((x) => token === `token-${x.uid}`);
    if (!u) throw new AuthError('bad token');
    return u;
  };
  const app = createApp({ config, verifyIdToken, invitationService, mailer, log: silentLog });
  const server = await new Promise((resolve) => {
    const s = app.listen(0, '127.0.0.1', () => resolve(s));
  });
  const base = `http://127.0.0.1:${server.address().port}`;

  async function send(id, { user = OWNER, body = {}, headers = {} } = {}) {
    const res = await fetch(`${base}/api/invitations/${id}/send`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...(user ? { Authorization: `Bearer token-${user.uid}` } : {}),
        ...headers,
      },
      body: JSON.stringify(body),
    });
    return { status: res.status, body: await res.json(), headers: res.headers };
  }

  return { base, server, firestore, transport, send, close: () => new Promise((r) => server.close(r)) };
}

export { HttpError };
