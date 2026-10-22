import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { SignJWT, createLocalJWKSet, exportJWK, generateKeyPair } from 'jose';
import { bearerToken, createFirebaseTokenVerifier } from '../src/auth.js';
import { buildConfig, maskEmail, missingMailSettings } from '../src/config.js';
import { buildInvitationEmail, cleanText } from '../src/emailTemplate.js';
import { createFirestoreRestClient, decodeFields, encodeValue } from '../src/firestore.js';
import { describeSmtpError } from '../src/mailer.js';

describe('Firebase ID token verification', async () => {
  const { publicKey, privateKey } = await generateKeyPair('RS256');
  const jwk = { ...(await exportJWK(publicKey)), kid: 'k1', alg: 'RS256' };
  const verify = createFirebaseTokenVerifier('vanity-tracker', createLocalJWKSet({ keys: [jwk] }));
  const sign = (claims, { project = 'vanity-tracker', exp = '1h' } = {}) =>
    new SignJWT(claims)
      .setProtectedHeader({ alg: 'RS256', kid: 'k1' })
      .setIssuer(`https://securetoken.google.com/${project}`)
      .setAudience(project)
      .setSubject('uid_123')
      .setIssuedAt()
      .setExpirationTime(exp)
      .sign(privateKey);

  it('accepts a valid token and normalizes the email', async () => {
    const u = await verify(await sign({ email: 'Me@Gmail.com', email_verified: true }));
    assert.deepEqual(u, { uid: 'uid_123', email: 'me@gmail.com', emailVerified: true });
  });

  it('rejects tokens for another Firebase project', async () => {
    await assert.rejects(verify(await sign({}, { project: 'vanitytracker' })), /rejected/);
  });

  it('rejects expired tokens', async () => {
    await assert.rejects(verify(await sign({}, { exp: Math.floor(Date.now() / 1000) - 60 })), /rejected/);
  });

  it('rejects garbage', async () => {
    await assert.rejects(verify('abc'), /malformed/);
  });

  it('parses bearer headers', () => {
    assert.equal(bearerToken('Bearer a.b.c'), 'a.b.c');
    assert.equal(bearerToken('Basic x'), null);
    assert.equal(bearerToken(undefined), null);
  });
});

describe('config', () => {
  it('strips spaces from app passwords and flags placeholders', () => {
    const c = buildConfig({ GMAIL_USER: 'your.address@gmail.com', GMAIL_APP_PASSWORD: 'ab cd' });
    assert.equal(c.mail.appPassword, 'abcd');
    assert.deepEqual(missingMailSettings(c), ['GMAIL_USER']);
    assert.deepEqual(missingMailSettings(buildConfig({})), ['GMAIL_USER', 'GMAIL_APP_PASSWORD']);
  });
  it('masks emails', () => assert.equal(maskEmail('karthick@gmail.com'), 'k***@gmail.com'));
});

describe('email template', () => {
  it('escapes user-controlled text and strips header-breaking characters', () => {
    const m = buildInvitationEmail({
      householdName: 'Evil\r\nBcc: x@y.com <script>',
      inviterName: 'Al"ice',
      recipientEmail: 'f@gmail.com',
      expiresAt: new Date('2030-01-02T00:00:00Z'),
      appUrl: 'javascript:alert(1)',
    });
    assert.doesNotMatch(m.subject, /[\r\n]/);
    assert.doesNotMatch(m.html, /<script>/);
    assert.doesNotMatch(m.html, /javascript:/);
    assert.match(m.text, /f@gmail\.com/);
    assert.equal(cleanText('a'.repeat(100), 10).length, 10);
  });
});

describe('SMTP error descriptions', () => {
  it('never echoes provider text that may contain secrets', () => {
    const msg = describeSmtpError({ code: 'EAUTH', message: 'pw=hunter2' });
    assert.doesNotMatch(msg, /hunter2/);
    assert.match(describeSmtpError({ code: 'ETIMEDOUT' }), /connect/);
  });
});

describe('Firestore REST client', () => {
  it('encodes/decodes values', () => {
    const fields = { a: encodeValue('x'), b: encodeValue(3), c: encodeValue(null), d: encodeValue(['u']), e: encodeValue({ k: 'v' }) };
    assert.deepEqual(decodeFields(fields), { a: 'x', b: 3, c: null, d: ['u'], e: { k: 'v' } });
  });

  it('sends the user token and an update mask', async () => {
    const calls = [];
    const fetchImpl = async (url, init) => {
      calls.push({ url, init });
      return { ok: true, status: 200, json: async () => ({ fields: { status: { stringValue: 'pending' } } }) };
    };
    const c = createFirestoreRestClient('vanity-tracker', fetchImpl);
    await c.updateFields('household_invitations', 'inv_1', { email_delivery_status: 'sent' }, 'tok');
    assert.match(calls[0].url, /updateMask.fieldPaths=email_delivery_status/);
    assert.match(calls[0].url, /currentDocument.exists=true/);
    assert.equal(calls[0].init.headers.Authorization, 'Bearer tok');
    assert.equal(calls[0].init.method, 'PATCH');
  });

  it('returns null for missing documents and throws with status otherwise', async () => {
    const c404 = createFirestoreRestClient('p', async () => ({ ok: false, status: 404 }));
    assert.equal(await c404.getDoc('x', 'y', 't'), null);
    const c403 = createFirestoreRestClient('p', async () => ({ ok: false, status: 403, json: async () => ({ error: { status: 'PERMISSION_DENIED' } }) }));
    await assert.rejects(c403.getDoc('x', 'y', 't'), (e) => e.status === 403);
  });
});
