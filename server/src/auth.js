import { createRemoteJWKSet, jwtVerify } from 'jose';

// Google's public keys for Firebase Auth ID tokens. No service-account key is needed
// to verify a token, only these public certificates.
const FIREBASE_JWKS_URL =
  'https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com';

export class AuthError extends Error {
  constructor(message) {
    super(message);
    this.name = 'AuthError';
  }
}

/**
 * Returns an async function that verifies a Firebase ID token for [projectId] and
 * resolves to `{ uid, email, emailVerified }`.
 * [keySet] can be injected for tests (e.g. jose.createLocalJWKSet).
 */
export function createFirebaseTokenVerifier(projectId, keySet = createRemoteJWKSet(new URL(FIREBASE_JWKS_URL))) {
  if (!projectId) throw new Error('FIREBASE_PROJECT_ID is required to verify sign-in tokens.');

  return async function verifyIdToken(token) {
    if (typeof token !== 'string' || token.split('.').length !== 3) {
      throw new AuthError('Missing or malformed sign-in token.');
    }
    let payload;
    try {
      ({ payload } = await jwtVerify(token, keySet, {
        issuer: `https://securetoken.google.com/${projectId}`,
        audience: projectId,
        algorithms: ['RS256'],
      }));
    } catch (e) {
      throw new AuthError(`Sign-in token rejected (${e.code || e.name}).`);
    }

    const nowSec = Math.floor(Date.now() / 1000);
    if (typeof payload.sub !== 'string' || payload.sub.length === 0 || payload.sub.length > 128) {
      throw new AuthError('Sign-in token has no valid user id.');
    }
    if (typeof payload.auth_time === 'number' && payload.auth_time > nowSec + 300) {
      throw new AuthError('Sign-in token has an invalid auth_time.');
    }
    return {
      uid: payload.sub,
      email: typeof payload.email === 'string' ? payload.email.trim().toLowerCase() : '',
      emailVerified: payload.email_verified === true,
    };
  };
}

/** Extracts the bearer token from an Authorization header value. */
export function bearerToken(headerValue) {
  if (typeof headerValue !== 'string') return null;
  const m = /^Bearer\s+(\S+)$/i.exec(headerValue.trim());
  return m ? m[1] : null;
}
