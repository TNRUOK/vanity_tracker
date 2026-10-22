import express from 'express';
import { AuthError, bearerToken } from './auth.js';
import { FirestoreError } from './firestore.js';
import { HttpError } from './invitationService.js';

const LOCAL_ORIGIN_RE = /^http:\/\/(localhost|127\.0\.0\.1)(:\d{1,5})?$/;

export function isOriginAllowed(origin, allowedOrigins) {
  if (!origin) return true; // non-browser clients (curl, the Android app) send no Origin
  if (allowedOrigins.length > 0) return allowedOrigins.includes(origin);
  return LOCAL_ORIGIN_RE.test(origin);
}

/**
 * Builds the Express app. All collaborators are injected so tests can run without
 * network access: { config, verifyIdToken, invitationService, mailer, log }.
 */
export function createApp({ config, verifyIdToken, invitationService, mailer, log = console }) {
  const app = express();
  app.disable('x-powered-by');

  // CORS: only the Flutter web app's origin(s) may call the API from a browser.
  app.use((req, res, next) => {
    const origin = req.headers.origin;
    if (!isOriginAllowed(origin, config.allowedOrigins)) {
      return res.status(403).json({ error: { code: 'origin-not-allowed', message: 'Origin not allowed.' } });
    }
    if (origin) {
      res.setHeader('Access-Control-Allow-Origin', origin);
      res.setHeader('Vary', 'Origin');
      res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
      res.setHeader('Access-Control-Allow-Headers', 'Authorization, Content-Type');
      res.setHeader('Access-Control-Max-Age', '600');
      if (req.headers['access-control-request-private-network'] === 'true') {
        res.setHeader('Access-Control-Allow-Private-Network', 'true');
      }
    }
    if (req.method === 'OPTIONS') return res.status(204).end();
    next();
  });

  app.use(express.json({ limit: '4kb' }));

  app.get('/api/health', (_req, res) => {
    res.json({
      ok: true,
      projectId: config.projectId,
      emailConfigured: mailer.configured,
      missingSettings: mailer.missing,
      appUrl: config.appUrl ?? null,
      appUrlWarning: config.appUrlWarning ?? null,
    });
  });

  // Authentication: every /api/invitations call must carry a valid Firebase ID token.
  async function requireUser(req, res, next) {
    try {
      const token = bearerToken(req.headers.authorization);
      if (!token) throw new AuthError('Sign in required.');
      req.caller = await verifyIdToken(token);
      req.idToken = token;
      next();
    } catch (e) {
      const message = e instanceof AuthError ? e.message : 'Sign-in token could not be verified.';
      res.status(401).json({ error: { code: 'unauthenticated', message } });
    }
  }

  // The ONLY email-sending route: it emails an existing invitation the caller owns.
  // The recipient, subject, and body come from Firestore + a fixed template, never from the request.
  app.post('/api/invitations/:invitationId/send', requireUser, async (req, res) => {
    try {
      const result = await invitationService.sendInvitationEmail({
        caller: req.caller,
        invitationId: req.params.invitationId,
        resend: req.body?.resend === true,
        idToken: req.idToken,
      });
      res.status(result.status).json(result.body);
    } catch (e) {
      if (e instanceof HttpError) {
        return res.status(e.status).json({ error: { code: e.code, message: e.message }, ...e.extra });
      }
      if (e instanceof FirestoreError) {
        const status = e.status === 403 ? 403 : 502;
        const message = e.status === 403
          ? 'Firestore denied access to this invitation or household for your account.'
          : 'Could not reach Firestore to validate the invitation.';
        return res.status(status).json({ error: { code: status === 403 ? 'permission-denied' : 'firestore-unavailable', message } });
      }
      log.error(`Unexpected error: ${e?.message}`);
      res.status(500).json({ error: { code: 'internal', message: 'Unexpected server error.' } });
    }
  });

  app.use((_req, res) => res.status(404).json({ error: { code: 'not-found', message: 'Not found.' } }));
  // Malformed JSON etc.
  // eslint-disable-next-line no-unused-vars
  app.use((err, _req, res, _next) => {
    res.status(err.status && err.status < 500 ? err.status : 400).json({ error: { code: 'bad-request', message: 'Invalid request.' } });
  });

  return app;
}
