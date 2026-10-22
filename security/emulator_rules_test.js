// Firestore EMULATOR tests for firestore.rules, using the same operations the app performs
// (queries, partial updates, the batched invitation acceptance with array transforms).
//
// Run (the emulator loads firestore.rules via firebase.json; "demo-" projects are offline):
//   firebase emulators:exec --only firestore --project demo-vanity-test "node security/emulator_rules_test.js"
//
// No packages needed: talks to the emulator's REST API with unsigned test tokens, which
// only the emulator accepts. Data is reset and re-seeded before every case.
const HOST = process.env.FIRESTORE_EMULATOR_HOST || '127.0.0.1:8080';
const PROJECT = process.env.GCLOUD_PROJECT || 'demo-vanity-test';
const DOCS = `projects/${PROJECT}/databases/(default)/documents`;
const BASE = `http://${HOST}/v1/${DOCS}`;
const NOW = Date.now();

// ── tokens ──
const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
function token(uid, email, verified = true) {
  const t = Math.floor(NOW / 1000);
  return `${b64({ alg: 'none', typ: 'JWT' })}.${b64({
    iss: `https://securetoken.google.com/${PROJECT}`, aud: PROJECT, sub: uid, user_id: uid,
    iat: t, exp: t + 3600, auth_time: t, email, email_verified: verified,
    firebase: { sign_in_provider: 'password', identities: { email: [email] } },
  })}.`;
}
const ALICE = token('alice', 'alice@example.com');
const BOB = token('bob', 'bob@example.com');
const CAROL = token('carol', 'carol@example.com');
const CAROL_UNVERIFIED = token('carol', 'carol@example.com', false);
const DAVE = token('dave', 'dave@example.com');
const ADMIN = 'owner'; // emulator-only: bypasses rules (used for seeding and checking)

// ── value encoding ──
function v(x) {
  if (x === null) return { nullValue: null };
  if (Array.isArray(x)) return { arrayValue: { values: x.map(v) } };
  if (typeof x === 'boolean') return { booleanValue: x };
  if (typeof x === 'number') return Number.isInteger(x) ? { integerValue: String(x) } : { doubleValue: x };
  if (typeof x === 'object') return { mapValue: { fields: fields(x) } };
  return { stringValue: String(x) };
}
const fields = (o) => Object.fromEntries(Object.entries(o).map(([k, x]) => [k, v(x)]));
function unv(val) {
  if ('stringValue' in val) return val.stringValue;
  if ('integerValue' in val) return Number(val.integerValue);
  if ('doubleValue' in val) return val.doubleValue;
  if ('booleanValue' in val) return val.booleanValue;
  if ('nullValue' in val) return null;
  if ('arrayValue' in val) return (val.arrayValue.values || []).map(unv);
  if ('mapValue' in val) return Object.fromEntries(Object.entries(val.mapValue.fields || {}).map(([k, x]) => [k, unv(x)]));
  return undefined;
}

async function call(method, url, auth, body) {
  const headers = { 'Content-Type': 'application/json' };
  if (auth) headers.Authorization = `Bearer ${auth}`;
  const res = await fetch(url, { method, headers, body: body ? JSON.stringify(body) : undefined });
  const text = await res.text();
  let json = null;
  try { json = JSON.parse(text); } catch { /* not json */ }
  return { status: res.status, json };
}
const get = (path, auth) => call('GET', `${BASE}/${path}`, auth);
const setDoc = (path, data, auth) => call('PATCH', `${BASE}/${path}`, auth, { fields: fields(data) });
const update = (path, data, maskPaths, auth) => {
  const q = maskPaths.map((p) => `updateMask.fieldPaths=${encodeURIComponent(p)}`).join('&');
  return call('PATCH', `${BASE}/${path}?${q}&currentDocument.exists=true`, auth, { fields: fields(data) });
};
const del = (path, auth) => call('DELETE', `${BASE}/${path}`, auth);
const commit = (writes, auth) => call('POST', `${BASE}:commit`, auth, { writes });
const eq = (field, value) => ({ fieldFilter: { field: { fieldPath: field }, op: 'EQUAL', value: v(value) } });
const contains = (field, value) => ({ fieldFilter: { field: { fieldPath: field }, op: 'ARRAY_CONTAINS', value: v(value) } });
function query(collection, filters, auth) {
  const where = filters.length === 0 ? undefined
    : filters.length === 1 ? filters[0] : { compositeFilter: { op: 'AND', filters } };
  return call('POST', `${BASE}:runQuery`, auth, { structuredQuery: { from: [{ collectionId: collection }], ...(where ? { where } : {}) } });
}
const docName = (path) => `${DOCS}/${path}`;
const ids = (r) => (Array.isArray(r.json) ? r.json.filter((x) => x.document).map((x) => x.document.name.split('/').pop()) : []);

// ── seed ──
const household = {
  household_id: 'h1', name: 'Flat', created_by: 'alice', created_at: '2026-10-01T00:00:00.000',
  member_uids: ['alice', 'bob'], member_emails: { alice: 'alice@example.com', bob: 'bob@example.com' },
  last_join_invitation_id: 'inv_bob',
};
const invitation = (id, extra = {}) => ({
  invitation_id: id, household_id: 'h1', household_name: 'Flat', invited_email: 'carol@example.com',
  invited_by_uid: 'alice', invited_by_name: 'Alice', created_at: new Date(NOW).toISOString(),
  expires_at: new Date(NOW + 3 * 86400000).toISOString(), expires_at_ms: NOW + 3 * 86400000,
  status: 'pending', email_delivery_status: 'queued', email_delivery_error: null, ...extra,
});
const item = (owner, extra = {}) => ({
  vanity_item_id: 'x', product_id: 'p', user_id: owner, status: 'unopened', price: 15, notes: 'private note',
  routine_tags: ['AM'], is_shared_with_household: false, shared_household_id: null, ...extra,
});

async function reset() {
  await call('DELETE', `http://${HOST}/emulator/v1/projects/${PROJECT}/databases/(default)/documents`);
  const seed = {
    'households/h1': household,
    'households/h2': { ...household, household_id: 'h2', created_by: 'erin', member_uids: ['erin'], member_emails: { erin: 'erin@example.com' } },
    'household_invitations/inv1': invitation('inv1'),
    'household_invitations/inv_exp': invitation('inv_exp', { expires_at_ms: NOW - 60000 }),
    'vanity_items/a_private': item('alice'),
    'vanity_items/a_shared': item('alice', { is_shared_with_household: true, shared_household_id: 'h1' }),
    'vanity_items/b_shared': item('bob', { is_shared_with_household: true, shared_household_id: 'h1' }),
    'receipts/r_alice': { receipt_id: 'r_alice', user_id: 'alice', merchant: 'Shop', total_amount: 68, currency: '$', items: [] },
    'wishlists/w_alice': { wishlist_id: 'w_alice', user_id: 'alice', name: 'Toner' },
    'users/alice': { household_id: 'h1' },
    'products/p_alice': { name: 'Gel', created_by: 'alice' },
    'products/p_legacy': { name: 'Old' },
    'categories/serum': { category_name: 'Serum' },
    'mail/m1': { to: 'carol@example.com' },
  };
  for (const [p, d] of Object.entries(seed)) {
    const r = await setDoc(p, d, ADMIN);
    if (r.status !== 200) throw new Error(`seed ${p} failed: ${r.status}`);
  }
}

// The app's acceptInvitation batch (invitation + household arrayUnion + users merge).
const acceptBatch = (uid, email, invId) => [
  {
    update: { name: docName(`household_invitations/${invId}`), fields: fields({ status: 'accepted', responded_at: new Date().toISOString(), accepted_by_uid: uid }) },
    updateMask: { fieldPaths: ['status', 'responded_at', 'accepted_by_uid'] },
    currentDocument: { exists: true },
  },
  {
    update: { name: docName('households/h1'), fields: fields({ member_emails: { [uid]: email }, last_join_invitation_id: invId }) },
    updateMask: { fieldPaths: [`member_emails.${uid}`, 'last_join_invitation_id'] },
    updateTransforms: [{ fieldPath: 'member_uids', appendMissingElements: { values: [v(uid)] } }],
    currentDocument: { exists: true },
  },
  { update: { name: docName(`users/${uid}`), fields: fields({ household_id: 'h1' }) }, updateMask: { fieldPaths: ['household_id'] } },
];
// The app's leaveHousehold update (arrayRemove + delete own e-mail entry).
const leaveWrite = (uid, newOwner) => [{
  update: { name: docName('households/h1'), fields: fields(newOwner ? { created_by: newOwner } : {}) },
  updateMask: { fieldPaths: [`member_emails.${uid}`, ...(newOwner ? ['created_by'] : [])] },
  updateTransforms: [{ fieldPath: 'member_uids', removeAllFromArray: { values: [v(uid)] } }],
  currentDocument: { exists: true },
}];

const ok = (r) => r.status === 200;
const denied = (r) => r.status === 403;

const cases = [
  // ── unauthenticated ──
  ['unauth: read private item', 'DENY', () => get('vanity_items/a_private')],
  ['unauth: list all receipts', 'DENY', () => query('receipts', [])],
  ['unauth: change a receipt', 'DENY', () => update('receipts/r_alice', { total_amount: 1 }, ['total_amount'])],
  ['unauth: delete household', 'DENY', () => del('households/h1')],
  // ── the app's real queries ──
  ['owner: query own inventory (user_id == me)', 'ALLOW', () => query('vanity_items', [eq('user_id', 'alice')], ALICE)],
  ['query another user\'s inventory', 'DENY', () => query('vanity_items', [eq('user_id', 'alice')], BOB)],
  ['member: query items shared with the household', 'ALLOW',
    () => query('vanity_items', [eq('shared_household_id', 'h1'), eq('is_shared_with_household', true)], BOB),
    async (r) => { const got = ids(r).sort().join(','); return got === 'a_shared,b_shared' || `got ${got}`; }],
  ['non-member: query items shared with the household', 'DENY',
    () => query('vanity_items', [eq('shared_household_id', 'h1'), eq('is_shared_with_household', true)], CAROL)],
  ['member: query all inventory without filters', 'DENY', () => query('vanity_items', [], BOB)],
  ['owner: query own receipts', 'ALLOW', () => query('receipts', [eq('user_id', 'alice')], ALICE)],
  ['member: query another member\'s receipts', 'DENY', () => query('receipts', [eq('user_id', 'alice')], BOB)],
  ['owner: query own wishlist', 'ALLOW', () => query('wishlists', [eq('user_id', 'alice')], ALICE)],
  ['member: find own household (array-contains)', 'ALLOW', () => query('households', [contains('member_uids', 'alice')], ALICE)],
  ['verified invitee: query own pending invitations', 'ALLOW',
    () => query('household_invitations', [eq('invited_email', 'carol@example.com'), eq('status', 'pending')], CAROL),
    async (r) => ids(r).includes('inv1') || 'inv1 missing'],
  ['UNVERIFIED invitee: query invitations', 'DENY',
    () => query('household_invitations', [eq('invited_email', 'carol@example.com'), eq('status', 'pending')], CAROL_UNVERIFIED)],
  ['other verified user: query someone else\'s invitations', 'DENY',
    () => query('household_invitations', [eq('invited_email', 'carol@example.com'), eq('status', 'pending')], DAVE)],
  ['member: query the household\'s sent invitations', 'ALLOW', () => query('household_invitations', [eq('household_id', 'h1')], BOB)],
  ['invitee reads household before joining', 'DENY', () => get('households/h1', CAROL)],
  // ── inventory ownership ──
  ['member edits another member\'s shared item', 'DENY', () => update('vanity_items/a_shared', { status: 'active' }, ['status'], BOB)],
  ['member deletes another member\'s shared item', 'DENY', () => del('vanity_items/a_shared', BOB)],
  ['owner shares own item with own household', 'ALLOW',
    () => update('vanity_items/a_private', { is_shared_with_household: true, shared_household_id: 'h1' }, ['is_shared_with_household', 'shared_household_id'], ALICE)],
  ['owner shares own item into a foreign household', 'DENY',
    () => update('vanity_items/a_private', { is_shared_with_household: true, shared_household_id: 'h2' }, ['is_shared_with_household', 'shared_household_id'], ALICE)],
  ['owner marks own item opened (routine/PAO edit)', 'ALLOW',
    () => update('vanity_items/a_shared', { opened_date: '2026-10-18T09:00:00.000', routine_tags: ['AM', 'PM'] }, ['opened_date', 'routine_tags'], ALICE)],
  ['create an item owned by someone else', 'DENY', () => setDoc('vanity_items/new1', item('bob'), ALICE)],
  ['owner creates own item', 'ALLOW', () => setDoc('vanity_items/new1', item('alice'), ALICE)],
  // Currency / category provenance fields (added 2026-10-18; no rule change needed)
  ['owner records a price currency and category source', 'ALLOW',
    () => update('vanity_items/a_private', { price_currency: 'INR', product: { category_id: 'cleanser', category_source: 'user' } }, ['price_currency', 'product'], ALICE)],
  ['owner confirms a legacy receipt currency code', 'ALLOW',
    () => update('receipts/r_alice', { currency_code: 'USD' }, ['currency_code'], ALICE)],
  ['another user sets a receipt currency code', 'DENY',
    () => update('receipts/r_alice', { currency_code: 'USD' }, ['currency_code'], BOB)],
  // ── households ──
  ['owner adds a member without invitation', 'DENY',
    () => commit([{ update: { name: docName('households/h1'), fields: {} }, updateMask: { fieldPaths: [] },
      updateTransforms: [{ fieldPath: 'member_uids', appendMissingElements: { values: [v('carol')] } }], currentDocument: { exists: true } }], ALICE)],
  ['owner renames household', 'ALLOW', () => update('households/h1', { name: 'Home' }, ['name'], ALICE)],
  ['owner deletes household that still has members', 'DENY', () => del('households/h1', ALICE)],
  // ── invitation acceptance (the app's batch) ──
  ['UNVERIFIED invitee accepts (batch); nothing changes', 'DENY', () => commit(acceptBatch('carol', 'carol@example.com', 'inv1'), CAROL_UNVERIFIED),
    async () => {
      const inv = await get('household_invitations/inv1', ADMIN);
      const hh = await get('households/h1', ADMIN);
      const status = unv(inv.json.fields.status);
      const members = unv(hh.json.fields.member_uids);
      return (status === 'pending' && members.join(',') === 'alice,bob') || `status ${status}, members ${members}`;
    }],
  ['verified user with a different e-mail accepts', 'DENY', () => commit(acceptBatch('dave', 'dave@example.com', 'inv1'), DAVE)],
  ['verified invitee accepts; membership and access follow', 'ALLOW', () => commit(acceptBatch('carol', 'carol@example.com', 'inv1'), CAROL),
    async () => {
      const hh = await get('households/h1', ADMIN);
      const f = hh.json.fields;
      const shared = await query('vanity_items', [eq('shared_household_id', 'h1'), eq('is_shared_with_household', true)], CAROL);
      const inv = await get('household_invitations/inv1', ADMIN);
      const good = unv(f.member_uids).includes('carol') && unv(f.last_join_invitation_id) === 'inv1' &&
        unv(inv.json.fields.status) === 'accepted' && ok(shared) && ids(shared).length === 2;
      return good || 'state after join not as expected';
    }],
  ['invitee accepts an already-accepted invitation again', 'DENY', async () => {
    await commit(acceptBatch('carol', 'carol@example.com', 'inv1'), CAROL);
    return commit(acceptBatch('carol', 'carol@example.com', 'inv1'), CAROL);
  }],
  ['invitee accepts an expired invitation', 'DENY', () => commit(acceptBatch('carol', 'carol@example.com', 'inv_exp'), CAROL)],
  ['invitee accepts a revoked invitation', 'DENY', async () => {
    const r = await update('household_invitations/inv1', { status: 'revoked', responded_at: 'now' }, ['status', 'responded_at'], ALICE);
    if (!ok(r)) return { status: 0 };
    return commit(acceptBatch('carol', 'carol@example.com', 'inv1'), CAROL);
  }],
  ['UNVERIFIED invitee reads the invitation', 'DENY', () => get('household_invitations/inv1', CAROL_UNVERIFIED)],
  // ── leaving (the app's field-level update) ──
  ['member leaves with the app\'s partial update (metadata kept)', 'ALLOW', () => commit(leaveWrite('bob'), BOB),
    async () => {
      const f = (await get('households/h1', ADMIN)).json.fields;
      const good = unv(f.member_uids).join(',') === 'alice' && !('bob' in unv(f.member_emails)) &&
        unv(f.last_join_invitation_id) === 'inv_bob' && unv(f.created_by) === 'alice' && unv(f.name) === 'Flat';
      return good || 'household fields changed unexpectedly';
    }],
  ['owner leaves and hands ownership to the remaining member', 'ALLOW', () => commit(leaveWrite('alice', 'bob'), ALICE)],
  ['member leaves by rewriting the whole document (old code)', 'DENY', () => {
    const d = { ...household, member_uids: ['alice'], member_emails: { alice: 'alice@example.com' } };
    delete d.last_join_invitation_id;
    return setDoc('households/h1', d, BOB);
  }],
  ['member removes the owner', 'DENY', () => commit([{
    update: { name: docName('households/h1'), fields: {} }, updateMask: { fieldPaths: ['member_emails.alice'] },
    updateTransforms: [{ fieldPath: 'member_uids', removeAllFromArray: { values: [v('alice')] } }], currentDocument: { exists: true },
  }], BOB)],
  ['member adds another UID while leaving', 'DENY', () => commit([
    {
      update: { name: docName('households/h1'), fields: {} },
      updateMask: { fieldPaths: ['member_emails.bob'] },
      updateTransforms: [
        { fieldPath: 'member_uids', removeAllFromArray: { values: [v('bob')] } },
        { fieldPath: 'member_uids', appendMissingElements: { values: [v('carol')] } },
      ],
      currentDocument: { exists: true },
    },
  ], BOB)],
  ['member modifies another member\'s email while leaving', 'DENY', () => commit([
    {
      update: { name: docName('households/h1'), fields: fields({ member_emails: { alice: 'attacker@example.com' } }) },
      updateMask: { fieldPaths: ['member_emails.alice', 'member_emails.bob'] },
      updateTransforms: [{ fieldPath: 'member_uids', removeAllFromArray: { values: [v('bob')] } }],
      currentDocument: { exists: true },
    },
  ], BOB)],
  ['member adds another user without invitation', 'DENY', () => commit([
    {
      update: { name: docName('households/h1'), fields: fields({ member_emails: { carol: 'carol@example.com' } }) },
      updateMask: { fieldPaths: ['member_emails.carol'] },
      updateTransforms: [{ fieldPath: 'member_uids', appendMissingElements: { values: [v('carol')] } }],
      currentDocument: { exists: true },
    },
  ], BOB)],
  ['non-member joins household without invitation', 'DENY', () => commit([
    {
      update: { name: docName('households/h1'), fields: fields({ member_emails: { carol: 'carol@example.com' } }) },
      updateMask: { fieldPaths: ['member_emails.carol'] },
      updateTransforms: [{ fieldPath: 'member_uids', appendMissingElements: { values: [v('carol')] } }],
      currentDocument: { exists: true },
    },
  ], CAROL)],
  // ── invitations ──
  ['owner creates an invitation', 'ALLOW', () => setDoc('household_invitations/inv2', invitation('inv2'), ALICE)],
  ['non-owner member creates an invitation', 'DENY', () => setDoc('household_invitations/inv2', invitation('inv2', { invited_by_uid: 'bob' }), BOB)],
  ['owner creates a pre-accepted invitation', 'DENY',
    () => setDoc('household_invitations/inv2', invitation('inv2', { accepted_by_uid: 'carol' }), ALICE)],
  ['inviter records e-mail delivery', 'ALLOW',
    () => update('household_invitations/inv1', { email_delivery_status: 'sent', email_sent_at: 'now' }, ['email_delivery_status', 'email_sent_at'], ALICE)],
  // ── catalog / other / nested ──
  ['overwrite another user\'s product', 'DENY', () => update('products/p_alice', { name: 'Spam' }, ['name'], BOB)],
  ['update a legacy product with no creator', 'DENY', () => update('products/p_legacy', { name: 'X', created_by: 'alice' }, ['name', 'created_by'], ALICE)],
  ['create product as its creator', 'ALLOW', () => setDoc('products/p_new', { name: 'Gel', created_by: 'alice' }, ALICE)],
  ['read categories', 'ALLOW', () => get('categories/serum', BOB)],
  ['write categories', 'DENY', () => setDoc('categories/x', { a: 1 }, ALICE)],
  ['read the legacy mail queue', 'DENY', () => get('mail/m1', ALICE)],
  ['read someone else\'s profile', 'DENY', () => get('users/alice', BOB)],
  ['store an extra field in own profile', 'DENY', () => setDoc('users/alice', { household_id: 'h1', is_admin: true }, ALICE)],
  ['nested path under own item', 'DENY', () => setDoc('vanity_items/a_private/history/x', { a: 1 }, ALICE)],
  ['nested path under the household', 'DENY', () => setDoc('households/h1/members/carol', { a: 1 }, BOB)],
];

(async () => {
  let failures = 0;
  for (const [name, expected, run, check] of cases) {
    await reset();
    let r;
    try { r = await run(); } catch (e) { r = { status: -1, json: String(e) }; }
    const actual = ok(r) ? 'ALLOW' : denied(r) ? 'DENY' : `HTTP ${r.status}`;
    let pass = actual === expected;
    let note = '';
    if (pass && check) {
      const c = await check(r);
      if (c !== true) { pass = false; note = ` (${c})`; }
    }
    if (!pass) failures++;
    console.log(`${pass ? 'PASS' : 'FAIL'}  expected ${expected.padEnd(5)} got ${actual.padEnd(5)}  ${name}${note}`);
  }
  console.log(`\n${cases.length - failures}/${cases.length} emulator cases passed`);
  process.exit(failures ? 1 : 0);
})().catch((e) => { console.error('ERR', e); process.exit(2); });
