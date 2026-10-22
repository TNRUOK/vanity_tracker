// Automated tests use a MOCK mail transport. They prove the authorization and
// status logic, NOT that Gmail delivers mail. Real delivery is verified manually.
import assert from 'node:assert/strict';
import { afterEach, describe, it } from 'node:test';
import { OTHER, OWNER, baseDocs, fakeTransport, startTestServer } from './helpers.js';

let srv;
afterEach(async () => { if (srv) await srv.close(); srv = null; });

describe('authentication and CORS', () => {
  it('rejects requests without a sign-in token', async () => {
    srv = await startTestServer();
    const r = await srv.send('inv_1', { user: null });
    assert.equal(r.status, 401);
    assert.equal(srv.transport.sent.length, 0);
  });

  it('rejects invalid tokens', async () => {
    srv = await startTestServer();
    const r = await srv.send('inv_1', { user: null, headers: { Authorization: 'Bearer forged' } });
    assert.equal(r.status, 401);
    assert.equal(srv.transport.sent.length, 0);
  });

  it('allows localhost web origins and answers preflight', async () => {
    srv = await startTestServer();
    const res = await fetch(`${srv.base}/api/invitations/inv_1/send`, {
      method: 'OPTIONS',
      headers: { Origin: 'http://localhost:53211', 'Access-Control-Request-Method': 'POST' },
    });
    assert.equal(res.status, 204);
    assert.equal(res.headers.get('access-control-allow-origin'), 'http://localhost:53211');
    assert.match(res.headers.get('access-control-allow-headers'), /Authorization/);
  });

  it('blocks other browser origins', async () => {
    srv = await startTestServer();
    const r = await srv.send('inv_1', { headers: { Origin: 'https://evil.example' } });
    assert.equal(r.status, 403);
    assert.equal(srv.transport.sent.length, 0);
  });

  it('honours an explicit ALLOWED_ORIGINS list', async () => {
    srv = await startTestServer({ env: { ALLOWED_ORIGINS: 'http://localhost:5000' } });
    assert.equal((await srv.send('inv_1', { headers: { Origin: 'http://localhost:6000' } })).status, 403);
    assert.equal((await srv.send('inv_1', { headers: { Origin: 'http://localhost:5000' } })).status, 200);
  });

  it('health endpoint reports configuration without secrets', async () => {
    srv = await startTestServer();
    const body = await (await fetch(`${srv.base}/api/health`)).json();
    assert.equal(body.emailConfigured, true);
    assert.ok(!JSON.stringify(body).includes('abcd'));
  });
});

describe('authorization', () => {
  it('only the inviter can send the invitation email', async () => {
    srv = await startTestServer();
    const r = await srv.send('inv_1', { user: OTHER });
    assert.equal(r.status, 403);
    assert.equal(srv.transport.sent.length, 0);
  });

  it('only the household owner can send invitations', async () => {
    const docs = baseDocs({
      household: { created_by: OTHER.uid, member_uids: [OTHER.uid, OWNER.uid] },
    });
    srv = await startTestServer({ docs });
    const r = await srv.send('inv_1');
    assert.equal(r.status, 403);
    assert.match(r.body.error.message, /owner/);
    assert.equal(srv.transport.sent.length, 0);
  });

  it('maps Firestore permission errors to 403', async () => {
    srv = await startTestServer();
    srv.firestore.deny.add('household_invitations/inv_1');
    const r = await srv.send('inv_1');
    assert.equal(r.status, 403);
  });

  it('returns 404 for unknown invitations and rejects malformed ids', async () => {
    srv = await startTestServer();
    assert.equal((await srv.send('inv_missing')).status, 404);
    assert.equal((await srv.send('bad%20id')).status, 400);
  });

  it('ignores any recipient or content supplied in the request body', async () => {
    srv = await startTestServer();
    const r = await srv.send('inv_1', { body: { to: 'victim@example.com', subject: 'spam', html: '<b>x</b>' } });
    assert.equal(r.status, 200);
    assert.equal(srv.transport.sent.length, 1);
    assert.equal(srv.transport.sent[0].to, 'friend@gmail.com');
    assert.doesNotMatch(srv.transport.sent[0].subject, /spam/);
  });
});

describe('invitation validation', () => {
  it('refuses expired invitations', async () => {
    srv = await startTestServer({ docs: baseDocs({ invitation: { expires_at: new Date(Date.now() - 1000).toISOString() } }) });
    const r = await srv.send('inv_1');
    assert.equal(r.status, 409);
    assert.equal(r.body.error.code, 'expired');
    assert.equal(srv.transport.sent.length, 0);
  });

  for (const status of ['accepted', 'declined', 'revoked']) {
    it(`refuses ${status} invitations`, async () => {
      srv = await startTestServer({ docs: baseDocs({ invitation: { status } }) });
      const r = await srv.send('inv_1');
      assert.equal(r.status, 409);
      assert.equal(srv.transport.sent.length, 0);
    });
  }

  it('refuses invitations to existing members', async () => {
    srv = await startTestServer({
      docs: baseDocs({ household: { member_emails: { [OWNER.uid]: OWNER.email, x: 'friend@gmail.com' } } }),
    });
    assert.equal((await srv.send('inv_1')).status, 409);
  });

  it('refuses invalid recipient addresses', async () => {
    srv = await startTestServer({ docs: baseDocs({ invitation: { invited_email: 'not-an-email' } }) });
    assert.equal((await srv.send('inv_1')).status, 400);
  });
});

describe('delivery status tracking', () => {
  it('sends once, records queued then sent with the provider response', async () => {
    srv = await startTestServer();
    const r = await srv.send('inv_1');
    assert.equal(r.status, 200);
    assert.equal(r.body.emailStatus, 'sent');
    assert.match(r.body.providerResponse, /^250/);
    const statuses = srv.firestore.writes.map((w) => w.fields.email_delivery_status);
    assert.deepEqual(statuses, ['queued', 'sent']);
    const inv = srv.firestore.store.household_invitations.inv_1;
    assert.equal(inv.email_attempts, 1);
    assert.ok(inv.email_sent_at);
    // HTML is escaped
    assert.match(srv.transport.sent[0].html, /Sunny &lt;b&gt;Villa&lt;\/b&gt;/);
  });

  it('a repeated request does not send a second email', async () => {
    srv = await startTestServer();
    await srv.send('inv_1');
    const again = await srv.send('inv_1');
    assert.equal(again.status, 200);
    assert.equal(again.body.alreadySent, true);
    assert.equal(srv.transport.sent.length, 1);
  });

  it('concurrent double-clicks send only one email', async () => {
    srv = await startTestServer({ transport: fakeTransport({ delayMs: 100 }) });
    const [a, b] = await Promise.all([srv.send('inv_1'), srv.send('inv_1')]);
    assert.deepEqual([a.status, b.status].sort(), [200, 409]);
    assert.equal(srv.transport.sent.length, 1);
  });

  it('resend is subject to a cooldown', async () => {
    srv = await startTestServer();
    await srv.send('inv_1');
    const r = await srv.send('inv_1', { body: { resend: true } });
    assert.equal(r.status, 429);
    assert.equal(srv.transport.sent.length, 1);
  });

  it('resend works after the cooldown and counts attempts', async () => {
    srv = await startTestServer({ env: { RESEND_COOLDOWN_SECONDS: '0' } });
    await srv.send('inv_1');
    const r = await srv.send('inv_1', { body: { resend: true } });
    assert.equal(r.status, 200);
    assert.equal(srv.transport.sent.length, 2);
    assert.equal(srv.firestore.store.household_invitations.inv_1.email_attempts, 2);
  });

  it('stops after the per-invitation attempt limit', async () => {
    srv = await startTestServer({ docs: baseDocs({ invitation: { email_attempts: 5, email_delivery_status: 'failed' } }) });
    assert.equal((await srv.send('inv_1')).status, 429);
  });

  it('records a failed state with a safe message when Gmail rejects the login', async () => {
    const err = Object.assign(new Error('Invalid login: 535 secret details'), { code: 'EAUTH', responseCode: 535 });
    srv = await startTestServer({ transport: fakeTransport({ fail: err }) });
    const r = await srv.send('inv_1');
    assert.equal(r.status, 502);
    assert.equal(r.body.emailStatus, 'failed');
    assert.match(r.body.error.message, /App Password/);
    const inv = srv.firestore.store.household_invitations.inv_1;
    assert.equal(inv.email_delivery_status, 'failed');
    assert.doesNotMatch(inv.email_delivery_error, /secret/);
  });

  it('records failure when the recipient is rejected', async () => {
    srv = await startTestServer({ transport: fakeTransport({ reject: true }) });
    const r = await srv.send('inv_1');
    assert.equal(r.status, 502);
    assert.equal(srv.firestore.store.household_invitations.inv_1.email_delivery_status, 'failed');
  });

  it('reports notConfigured (and sends nothing) when the App Password is missing', async () => {
    srv = await startTestServer({ env: { GMAIL_APP_PASSWORD: '' } });
    const r = await srv.send('inv_1');
    assert.equal(r.status, 503);
    assert.equal(r.body.emailStatus, 'notConfigured');
    assert.match(r.body.error.message, /GMAIL_APP_PASSWORD/);
    assert.equal(srv.firestore.store.household_invitations.inv_1.email_delivery_status, 'notConfigured');
  });

  it('enforces the per-user hourly limit', async () => {
    const docs = baseDocs();
    docs.household_invitations.inv_2 = { ...docs.household_invitations.inv_1, invitation_id: 'inv_2', invited_email: 'b@gmail.com' };
    srv = await startTestServer({ docs, env: { MAX_SENDS_PER_USER_PER_HOUR: '1' } });
    assert.equal((await srv.send('inv_1')).status, 200);
    assert.equal((await srv.send('inv_2')).status, 429);
    assert.equal(srv.transport.sent.length, 1);
  });
});
