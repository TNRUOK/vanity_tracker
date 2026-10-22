// Minimal Firestore REST client that acts AS THE SIGNED-IN USER (their ID token),
// so every read/write is still subject to the project's Firestore security rules.
// This avoids storing a privileged service-account key on the laptop.

export class FirestoreError extends Error {
  constructor(message, status) {
    super(message);
    this.name = 'FirestoreError';
    this.status = status;
  }
}

function decodeValue(v) {
  if (v === null || typeof v !== 'object') return null;
  if ('stringValue' in v) return v.stringValue;
  if ('integerValue' in v) return Number(v.integerValue);
  if ('doubleValue' in v) return Number(v.doubleValue);
  if ('booleanValue' in v) return v.booleanValue;
  if ('nullValue' in v) return null;
  if ('timestampValue' in v) return v.timestampValue;
  if ('mapValue' in v) return decodeFields(v.mapValue.fields || {});
  if ('arrayValue' in v) return (v.arrayValue.values || []).map(decodeValue);
  return null;
}

export function decodeFields(fields) {
  const out = {};
  for (const [k, v] of Object.entries(fields || {})) out[k] = decodeValue(v);
  return out;
}

export function encodeValue(v) {
  if (v === null || v === undefined) return { nullValue: null };
  if (typeof v === 'boolean') return { booleanValue: v };
  if (typeof v === 'number') return Number.isInteger(v) ? { integerValue: String(v) } : { doubleValue: v };
  if (typeof v === 'string') return { stringValue: v };
  if (Array.isArray(v)) return { arrayValue: { values: v.map(encodeValue) } };
  return { mapValue: { fields: Object.fromEntries(Object.entries(v).map(([k, x]) => [k, encodeValue(x)])) } };
}

/** Creates a REST client bound to one project. `fetchImpl` is injectable for tests. */
export function createFirestoreRestClient(projectId, fetchImpl = globalThis.fetch) {
  const base = `https://firestore.googleapis.com/v1/projects/${encodeURIComponent(projectId)}/databases/(default)/documents`;

  async function call(url, idToken, init = {}) {
    const res = await fetchImpl(url, {
      ...init,
      headers: { Authorization: `Bearer ${idToken}`, 'Content-Type': 'application/json', ...(init.headers || {}) },
    });
    if (res.status === 404) return null;
    if (!res.ok) {
      let detail = '';
      try {
        const body = await res.json();
        detail = body?.error?.status || body?.error?.message || '';
      } catch (_) {
        /* ignore */
      }
      throw new FirestoreError(`Firestore request failed (${res.status}${detail ? ` ${detail}` : ''}).`, res.status);
    }
    return res.json();
  }

  return {
    /** Returns the document's fields as a plain object, or null if it does not exist. */
    async getDoc(collection, id, idToken) {
      const body = await call(`${base}/${collection}/${encodeURIComponent(id)}`, idToken);
      return body ? decodeFields(body.fields) : null;
    },

    /** Updates only the given top-level fields of an existing document. */
    async updateFields(collection, id, fields, idToken) {
      const params = new URLSearchParams();
      for (const key of Object.keys(fields)) params.append('updateMask.fieldPaths', key);
      params.append('currentDocument.exists', 'true');
      const body = { fields: Object.fromEntries(Object.entries(fields).map(([k, v]) => [k, encodeValue(v)])) };
      const res = await call(`${base}/${collection}/${encodeURIComponent(id)}?${params}`, idToken, {
        method: 'PATCH',
        body: JSON.stringify(body),
      });
      if (res === null) throw new FirestoreError('Document not found.', 404);
      return decodeFields(res.fields);
    },
  };
}
