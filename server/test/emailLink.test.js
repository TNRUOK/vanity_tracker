import assert from 'node:assert/strict';
import { afterEach, describe, it } from 'node:test';
import { buildConfig, validateAppUrl } from '../src/config.js';
import { buildInvitationEmail } from '../src/emailTemplate.js';
import { startTestServer } from './helpers.js';

const APP = 'https://vanity-demo.example.app/';
const base = {
  householdName: 'Sunny Villa',
  inviterName: 'Alice',
  recipientEmail: 'friend@gmail.com',
  expiresAt: new Date('2030-01-02T00:00:00Z'),
};

describe('APP_URL validation', () => {
  it('accepts a public https URL without a warning', () => {
    assert.deepEqual(validateAppUrl(' https://vanity-demo.example.app '), { url: APP, warning: null });
  });

  it('warns and returns no URL when missing or invalid (never invents one)', () => {
    for (const bad of ['', '   ', undefined, 'not a url', 'vanity.example.app', 'javascript:alert(1)',
      'ftp://x.example', 'https://user:pass@x.example', 'mailto:a@b.c']) {
      const r = validateAppUrl(bad);
      assert.equal(r.url, null, `expected no URL for ${bad}`);
      assert.ok(r.warning && r.warning.includes('APP_URL'), `expected a warning for ${bad}`);
    }
  });

  it('keeps localhost/http URLs but warns that recipients may not reach them', () => {
    const local = validateAppUrl('http://localhost:5000');
    assert.equal(local.url, 'http://localhost:5000/');
    assert.match(local.warning, /this laptop/);
    const http = validateAppUrl('http://vanity.example.app');
    assert.equal(http.url, 'http://vanity.example.app/');
    assert.match(http.warning, /https/);
  });

  it('exposes the validated value through buildConfig', () => {
    assert.equal(buildConfig({ APP_URL: 'https://vanity-demo.example.app' }).appUrl, APP);
    const c = buildConfig({});
    assert.equal(c.appUrl, null);
    assert.match(c.appUrlWarning, /APP_URL is not set/);
  });
});

describe('invitation email with APP_URL', () => {
  const m = buildInvitationEmail({ ...base, appUrl: APP });

  it('HTML has a prominent clickable "Open Vanity Tracker" button to APP_URL', () => {
    assert.match(m.html, new RegExp(`<a href="${APP}"[^>]*>Open Vanity Tracker</a>`));
    assert.match(m.html, /bgcolor="#be185d"/);
    // Fallback copy-paste link in the HTML too.
    assert.ok(m.html.split(`href="${APP}"`).length - 1 === 2);
  });

  it('plain text contains the same URL on its own line', () => {
    assert.ok(m.text.split('\n').includes(APP));
    assert.match(m.text, /Open Vanity Tracker:\n/);
  });

  it('keeps household, inviter, expiry and acceptance instructions in both bodies', () => {
    for (const body of [m.text, m.html]) {
      assert.match(body, /Sunny Villa/);
      assert.match(body, /Alice/);
      assert.match(body, /friend@gmail\.com/);
      assert.match(body, /Wed, 02 Jan 2030/);
      assert.match(body, /Household Sharing/);
      assert.match(body, /Accept/);
      assert.match(body, /exact email address/);
      assert.match(body, /only be accepted by the invited email address/);
    }
  });

  it('escapes query-string ampersands in HTML but not in plain text', () => {
    const q = buildInvitationEmail({ ...base, appUrl: 'https://vanity-demo.example.app/?a=1&b=2' });
    assert.match(q.html, /href="https:\/\/vanity-demo\.example\.app\/\?a=1&amp;b=2"/);
    assert.ok(q.text.includes('https://vanity-demo.example.app/?a=1&b=2'));
  });
});

describe('invitation email without a valid APP_URL', () => {
  for (const appUrl of ['', null, 'javascript:alert(1)']) {
    it(`has no button or link but keeps instructions (APP_URL=${JSON.stringify(appUrl)})`, () => {
      const m = buildInvitationEmail({ ...base, appUrl });
      assert.doesNotMatch(m.html, /<a /);
      assert.doesNotMatch(m.html, /Open Vanity Tracker<\/a>/);
      assert.doesNotMatch(m.text, /https?:\/\//);
      assert.match(m.text, /Household Sharing and tap Accept/);
      assert.match(m.html, /Household Sharing/);
    });
  }
});

describe('server sends the configured link', () => {
  let srv;
  afterEach(async () => { if (srv) await srv.close(); srv = null; });

  it('the email actually sent contains APP_URL in HTML and text', async () => {
    srv = await startTestServer({ env: { APP_URL: 'https://vanity-demo.example.app' } });
    const r = await srv.send('inv_1');
    assert.equal(r.status, 200);
    const sent = srv.transport.sent[0];
    assert.match(sent.html, new RegExp(`<a href="${APP}"[^>]*>Open Vanity Tracker</a>`));
    assert.ok(sent.text.includes(APP));
    // No credentials leak into the message.
    assert.doesNotMatch(sent.html + sent.text, /abcdefghijklmnop|abcd efgh/);
  });

  it('health endpoint reports a missing APP_URL as a configuration warning', async () => {
    srv = await startTestServer();
    const body = await (await fetch(`${srv.base}/api/health`)).json();
    assert.equal(body.appUrl, null);
    assert.match(body.appUrlWarning, /APP_URL is not set/);
  });
});
