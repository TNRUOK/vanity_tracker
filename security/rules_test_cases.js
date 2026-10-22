// Security-rule test cases for Vanity Tracker (authorized and unauthorized users).
//
// Run with `node security/run_rules_tests.js <project> <rules file>`. The runner sends these
// cases to the Firebase Rules API `projects.test` method, which evaluates them with Google's
// rules engine WITHOUT deploying the rules and WITHOUT reading or writing any data
// (get()/exists() results are mocked below). This is not the Firestore emulator: list
// queries are approximated by per-document reads, and batched writes by their parts.

const DB = '/databases/(default)/documents';
const NOW = '2026-10-18T12:00:00Z';
const NOW_MS = Date.parse(NOW);

const user = (uid, email, verified = true) => ({ uid, token: { email, email_verified: verified } });
const ALICE = user('alice', 'alice@example.com'); // household owner
const BOB = user('bob', 'bob@example.com'); // household member
const CAROL = user('carol', 'carol@example.com'); // not a member
const CAROL_UNVERIFIED = user('carol2', 'carol@example.com', false); // registered carol's address, unverified

const household = {
  household_id: 'h1',
  name: 'Flat',
  created_by: 'alice',
  created_at: '2026-10-01T00:00:00.000',
  member_uids: ['alice', 'bob'],
  member_emails: { alice: 'alice@example.com', bob: 'bob@example.com' },
  last_join_invitation_id: 'inv_bob',
};
const otherHousehold = { ...household, household_id: 'h2', created_by: 'carol', member_uids: ['carol'], member_emails: { carol: 'carol@example.com' } };
const soloHousehold = { ...household, household_id: 'h3', member_uids: ['alice'], member_emails: { alice: 'alice@example.com' } };

const invitation = {
  invitation_id: 'inv1',
  household_id: 'h1',
  household_name: 'Flat',
  invited_email: 'carol@example.com',
  invited_by_uid: 'alice',
  status: 'pending',
  expires_at_ms: NOW_MS + 3 * 86400000,
  email_delivery_status: 'queued',
};

const mocks = [
  { function: 'exists', args: [{ exactValue: `${DB}/households/h1` }], result: { value: true } },
  { function: 'get', args: [{ exactValue: `${DB}/households/h1` }], result: { value: { data: household } } },
  { function: 'exists', args: [{ exactValue: `${DB}/households/h2` }], result: { value: true } },
  { function: 'get', args: [{ exactValue: `${DB}/households/h2` }], result: { value: { data: otherHousehold } } },
  { function: 'exists', args: [{ exactValue: `${DB}/households/h3` }], result: { value: true } },
  { function: 'get', args: [{ exactValue: `${DB}/households/h3` }], result: { value: { data: soloHousehold } } },
  { function: 'get', args: [{ exactValue: `${DB}/household_invitations/inv1` }], result: { value: { data: invitation } } },
  { function: 'getAfter', args: [{ exactValue: `${DB}/household_invitations/inv1` }], result: { value: { data: { ...invitation, status: 'accepted', accepted_by_uid: 'carol' } } } },
  {
    function: 'get',
    args: [{ exactValue: `${DB}/household_invitations/inv_other` }],
    result: { value: { data: { ...invitation, invited_email: 'someone@example.com' } } },
  },
  {
    function: 'getAfter',
    args: [{ exactValue: `${DB}/household_invitations/inv_other` }],
    result: { value: { data: { ...invitation, invited_email: 'someone@example.com', status: 'accepted' } } },
  },
];

const item = (owner, extra = {}) => ({
  vanity_item_id: 'i1',
  product_id: 'p1',
  user_id: owner,
  status: 'unopened',
  price: 15,
  notes: 'private note',
  is_shared_with_household: false,
  shared_household_id: null,
  ...extra,
});
const receipt = (owner) => ({ receipt_id: 'r1', user_id: owner, merchant: 'Shop', total_amount: 68, currency: '$', items: [] });

// [name, expected, request]  request: { auth, method, path, data (request.resource), existing (resource) }
const cases = [
  // ── Unauthenticated (anyone with the public project id) ──
  ['unauth: read an inventory item', 'DENY', { method: 'get', path: 'vanity_items/i1', existing: item('alice') }],
  ['unauth: overwrite a receipt', 'DENY', { method: 'update', path: 'receipts/r1', existing: receipt('alice'), data: receipt('alice') }],
  ['unauth: delete a household', 'DENY', { method: 'delete', path: 'households/h1', existing: household }],
  ['unauth: read a receipt', 'DENY', { method: 'get', path: 'receipts/r1', existing: receipt('alice') }],

  // ── Personal inventory ──
  ['owner reads own private item', 'ALLOW', { auth: ALICE, method: 'get', path: 'vanity_items/i1', existing: item('alice') }],
  ['household member reads owner\'s PRIVATE item', 'DENY', { auth: BOB, method: 'get', path: 'vanity_items/i1', existing: item('alice') }],
  ['stranger reads private item', 'DENY', { auth: CAROL, method: 'get', path: 'vanity_items/i1', existing: item('alice') }],
  ['member reads item shared with their household', 'ALLOW',
    { auth: BOB, method: 'get', path: 'vanity_items/i1', existing: item('alice', { is_shared_with_household: true, shared_household_id: 'h1' }) }],
  ['non-member reads item shared with another household', 'DENY',
    { auth: CAROL, method: 'get', path: 'vanity_items/i1', existing: item('alice', { is_shared_with_household: true, shared_household_id: 'h1' }) }],
  ['owner creates own item', 'ALLOW', { auth: ALICE, method: 'create', path: 'vanity_items/i1', data: item('alice') }],
  ['create an item owned by someone else', 'DENY', { auth: ALICE, method: 'create', path: 'vanity_items/i1', data: item('bob') }],
  ['create an item shared into a household you are not in', 'DENY',
    { auth: ALICE, method: 'create', path: 'vanity_items/i1', data: item('alice', { is_shared_with_household: true, shared_household_id: 'h2' }) }],
  ['owner shares own item with own household', 'ALLOW',
    { auth: ALICE, method: 'update', path: 'vanity_items/i1', existing: item('alice'),
      data: item('alice', { is_shared_with_household: true, shared_household_id: 'h1' }) }],
  ['owner shares own item into a foreign household', 'DENY',
    { auth: ALICE, method: 'update', path: 'vanity_items/i1', existing: item('alice'),
      data: item('alice', { is_shared_with_household: true, shared_household_id: 'h2' }) }],
  ['member edits another member\'s shared item', 'DENY',
    { auth: BOB, method: 'update', path: 'vanity_items/i1',
      existing: item('alice', { is_shared_with_household: true, shared_household_id: 'h1' }),
      data: item('alice', { is_shared_with_household: true, shared_household_id: 'h1', status: 'active' }) }],
  ['member stops sharing another member\'s item', 'DENY',
    { auth: BOB, method: 'update', path: 'vanity_items/i1',
      existing: item('alice', { is_shared_with_household: true, shared_household_id: 'h1' }), data: item('alice') }],
  ['owner transfers item ownership', 'DENY',
    { auth: ALICE, method: 'update', path: 'vanity_items/i1', existing: item('alice'), data: item('bob') }],
  ['member deletes another member\'s shared item', 'DENY',
    { auth: BOB, method: 'delete', path: 'vanity_items/i1', existing: item('alice', { is_shared_with_household: true, shared_household_id: 'h1' }) }],
  ['owner deletes own item', 'ALLOW', { auth: ALICE, method: 'delete', path: 'vanity_items/i1', existing: item('alice') }],
  ['owner edits item still marked shared with a household they left', 'ALLOW',
    { auth: ALICE, method: 'update', path: 'vanity_items/i1',
      existing: item('alice', { is_shared_with_household: true, shared_household_id: 'h2' }),
      data: item('alice', { is_shared_with_household: true, shared_household_id: 'h2', status: 'active' }) }],
  ['owner unshares item from a household they left', 'ALLOW',
    { auth: ALICE, method: 'update', path: 'vanity_items/i1',
      existing: item('alice', { is_shared_with_household: true, shared_household_id: 'h2' }), data: item('alice') }],

  // ── Receipts / spending ──
  ['owner reads own receipt', 'ALLOW', { auth: ALICE, method: 'get', path: 'receipts/r1', existing: receipt('alice') }],
  ['household member reads owner\'s receipt', 'DENY', { auth: BOB, method: 'get', path: 'receipts/r1', existing: receipt('alice') }],
  ['create a receipt for someone else', 'DENY', { auth: ALICE, method: 'create', path: 'receipts/r1', data: receipt('bob') }],
  ['owner creates own receipt', 'ALLOW', { auth: ALICE, method: 'create', path: 'receipts/r1', data: receipt('alice') }],
  ['owner re-assigns receipt to another user', 'DENY',
    { auth: ALICE, method: 'update', path: 'receipts/r1', existing: receipt('alice'), data: receipt('bob') }],
  ['stranger deletes a receipt', 'DENY', { auth: CAROL, method: 'delete', path: 'receipts/r1', existing: receipt('alice') }],

  // ── Wishlists / users ──
  ['stranger reads a wishlist entry', 'DENY',
    { auth: CAROL, method: 'get', path: 'wishlists/w1', existing: { wishlist_id: 'w1', user_id: 'alice', name: 'Toner' } }],
  ['owner creates wishlist entry', 'ALLOW',
    { auth: ALICE, method: 'create', path: 'wishlists/w1', data: { wishlist_id: 'w1', user_id: 'alice', name: 'Toner' } }],
  ['user writes own profile pointer', 'ALLOW', { auth: ALICE, method: 'update', path: 'users/alice', existing: {}, data: { household_id: 'h1' } }],
  ['user reads someone else\'s profile', 'DENY', { auth: BOB, method: 'get', path: 'users/alice', existing: { household_id: 'h1' } }],

  // ── Households ──
  ['member reads household', 'ALLOW', { auth: BOB, method: 'get', path: 'households/h1', existing: household }],
  ['non-member reads household', 'DENY', { auth: CAROL, method: 'get', path: 'households/h1', existing: household }],
  ['create household as sole member', 'ALLOW',
    { auth: CAROL, method: 'create', path: 'households/h9',
      data: { ...otherHousehold, household_id: 'h9' } }],
  ['create household listing another user as member', 'DENY',
    { auth: CAROL, method: 'create', path: 'households/h9',
      data: { ...otherHousehold, household_id: 'h9', member_uids: ['carol', 'bob'] } }],
  ['create household with a fake e-mail entry', 'DENY',
    { auth: CAROL, method: 'create', path: 'households/h9',
      data: { ...otherHousehold, household_id: 'h9', member_emails: { carol: 'ceo@bank.example' } } }],
  ['owner adds a member without any invitation', 'DENY',
    { auth: ALICE, method: 'update', path: 'households/h1', existing: household,
      data: { ...household, member_uids: ['alice', 'bob', 'carol'], member_emails: { ...household.member_emails, carol: 'carol@example.com' } } }],
  ['owner renames household', 'ALLOW',
    { auth: ALICE, method: 'update', path: 'households/h1', existing: household, data: { ...household, name: 'Home' } }],
  ['owner leaves and hands ownership to a remaining member', 'ALLOW',
    { auth: ALICE, method: 'update', path: 'households/h1', existing: household,
      data: { ...household, created_by: 'bob', member_uids: ['bob'], member_emails: { bob: 'bob@example.com' } } }],
  ['owner hands ownership to a non-member', 'DENY',
    { auth: ALICE, method: 'update', path: 'households/h1', existing: household,
      data: { ...household, created_by: 'carol', member_uids: ['bob'], member_emails: { bob: 'bob@example.com' } } }],
  ['member leaves (only own entries removed)', 'ALLOW',
    { auth: BOB, method: 'update', path: 'households/h1', existing: household,
      data: { ...household, member_uids: ['alice'], member_emails: { alice: 'alice@example.com' } } }],
  ['member leaves with a full rewrite that drops last_join_invitation_id (old app code)', 'DENY',
    { auth: BOB, method: 'update', path: 'households/h1', existing: household,
      data: (() => { const d = { ...household, member_uids: ['alice'], member_emails: { alice: 'alice@example.com' } }; delete d.last_join_invitation_id; return d; })() }],
  ['member removes the owner', 'DENY',
    { auth: BOB, method: 'update', path: 'households/h1', existing: household,
      data: { ...household, member_uids: ['bob'], member_emails: { bob: 'bob@example.com' } } }],
  ['invited, verified user joins with the accepted invitation', 'ALLOW',
    { auth: CAROL, method: 'update', path: 'households/h1', existing: household,
      data: { ...household, member_uids: ['alice', 'bob', 'carol'], member_emails: { ...household.member_emails, carol: 'carol@example.com' }, last_join_invitation_id: 'inv1' } }],
  ['UNVERIFIED account with the invitee\'s e-mail joins', 'DENY',
    { auth: CAROL_UNVERIFIED, method: 'update', path: 'households/h1', existing: household,
      data: { ...household, member_uids: ['alice', 'bob', 'carol2'], member_emails: { ...household.member_emails, carol2: 'carol@example.com' }, last_join_invitation_id: 'inv1' } }],
  ['user joins using an invitation addressed to someone else', 'DENY',
    { auth: CAROL, method: 'update', path: 'households/h1', existing: household,
      data: { ...household, member_uids: ['alice', 'bob', 'carol'], member_emails: { ...household.member_emails, carol: 'carol@example.com' }, last_join_invitation_id: 'inv_other' } }],
  ['owner deletes household that still has members', 'DENY', { auth: ALICE, method: 'delete', path: 'households/h1', existing: household }],
  ['last remaining owner deletes household', 'ALLOW', { auth: ALICE, method: 'delete', path: 'households/h3', existing: soloHousehold }],

  // ── Invitations ──
  ['owner creates an invitation', 'ALLOW', { auth: ALICE, method: 'create', path: 'household_invitations/inv2', data: { ...invitation, invitation_id: 'inv2' } }],
  ['non-owner member creates an invitation', 'DENY',
    { auth: BOB, method: 'create', path: 'household_invitations/inv2', data: { ...invitation, invitation_id: 'inv2', invited_by_uid: 'bob' } }],
  ['invited verified user reads invitation', 'ALLOW', { auth: CAROL, method: 'get', path: 'household_invitations/inv1', existing: invitation }],
  ['UNVERIFIED account with invitee e-mail reads invitation', 'DENY',
    { auth: CAROL_UNVERIFIED, method: 'get', path: 'household_invitations/inv1', existing: invitation }],
  ['unrelated user reads invitation', 'DENY', { auth: user('dave', 'dave@example.com'), method: 'get', path: 'household_invitations/inv1', existing: invitation }],
  ['invited verified user accepts', 'ALLOW',
    { auth: CAROL, method: 'update', path: 'household_invitations/inv1', existing: invitation,
      data: { ...invitation, status: 'accepted', responded_at: NOW, accepted_by_uid: 'carol' } }],
  ['invitee accepts and rewrites the household id', 'DENY',
    { auth: CAROL, method: 'update', path: 'household_invitations/inv1', existing: invitation,
      data: { ...invitation, status: 'accepted', responded_at: NOW, accepted_by_uid: 'carol', household_id: 'h2' } }],
  ['invitee accepts an expired invitation', 'DENY',
    { auth: CAROL, method: 'update', path: 'household_invitations/inv1', existing: { ...invitation, expires_at_ms: NOW_MS - 1000 },
      data: { ...invitation, expires_at_ms: NOW_MS - 1000, status: 'accepted', responded_at: NOW, accepted_by_uid: 'carol' } }],
  ['inviter records e-mail delivery', 'ALLOW',
    { auth: ALICE, method: 'update', path: 'household_invitations/inv1', existing: invitation,
      data: { ...invitation, email_delivery_status: 'sent', email_sent_at: NOW } }],
  ['inviter changes the invited e-mail afterwards', 'DENY',
    { auth: ALICE, method: 'update', path: 'household_invitations/inv1', existing: invitation,
      data: { ...invitation, invited_email: 'other@example.com' } }],

  ['VERIFIED user with a different e-mail accepts', 'DENY',
    { auth: user('dave', 'dave@example.com'), method: 'update', path: 'household_invitations/inv1', existing: invitation,
      data: { ...invitation, status: 'accepted', responded_at: NOW, accepted_by_uid: 'dave' } }],
  ['invitee accepts an already-accepted invitation again', 'DENY',
    { auth: CAROL, method: 'update', path: 'household_invitations/inv1', existing: { ...invitation, status: 'accepted', accepted_by_uid: 'carol' },
      data: { ...invitation, status: 'accepted', responded_at: NOW, accepted_by_uid: 'carol' } }],
  ['invitee accepts a revoked invitation', 'DENY',
    { auth: CAROL, method: 'update', path: 'household_invitations/inv1', existing: { ...invitation, status: 'revoked' },
      data: { ...invitation, status: 'accepted', responded_at: NOW, accepted_by_uid: 'carol' } }],
  ['invitee accepts a legacy invitation without expires_at_ms', 'DENY',
    { auth: CAROL, method: 'update', path: 'household_invitations/inv1',
      existing: (() => { const d = { ...invitation }; delete d.expires_at_ms; return d; })(),
      data: (() => { const d = { ...invitation, status: 'accepted', responded_at: NOW, accepted_by_uid: 'carol' }; delete d.expires_at_ms; return d; })() }],
  ['UNVERIFIED invitee declines', 'DENY',
    { auth: CAROL_UNVERIFIED, method: 'update', path: 'household_invitations/inv1', existing: invitation,
      data: { ...invitation, status: 'declined', responded_at: NOW } }],
  ['owner creates an invitation pre-marked as accepted', 'DENY',
    { auth: ALICE, method: 'create', path: 'household_invitations/inv2',
      data: { ...invitation, invitation_id: 'inv2', accepted_by_uid: 'carol' } }],
  ['owner creates an invitation whose id does not match the document', 'DENY',
    { auth: ALICE, method: 'create', path: 'household_invitations/inv2', data: { ...invitation, invitation_id: 'inv1' } }],
  ['owner creates an invitation for a household they do not own', 'DENY',
    { auth: ALICE, method: 'create', path: 'household_invitations/inv2', data: { ...invitation, invitation_id: 'inv2', household_id: 'h2' } }],

  // ── Exact app write: member leaves with arrayRemove + field delete (app fix) ──
  ['member leaves via the app\'s field-level update (keeps last_join_invitation_id)', 'ALLOW',
    { auth: BOB, method: 'update', path: 'households/h1', existing: household,
      data: { ...household, member_uids: ['alice'], member_emails: { alice: 'alice@example.com' } } }],
  ['member leaves and also renames the household', 'DENY',
    { auth: BOB, method: 'update', path: 'households/h1', existing: household,
      data: { ...household, name: 'Mine now', member_uids: ['alice'], member_emails: { alice: 'alice@example.com' } } }],
  ['member adds another UID while leaving', 'DENY',
    { auth: BOB, method: 'update', path: 'households/h1', existing: household,
      data: { ...household, member_uids: ['alice', 'carol'], member_emails: { alice: 'alice@example.com' } } }],
  ['member modifies another member\'s email while leaving', 'DENY',
    { auth: BOB, method: 'update', path: 'households/h1', existing: household,
      data: { ...household, member_uids: ['alice'], member_emails: { alice: 'attacker@example.com' } } }],
  ['member adds another user without invitation', 'DENY',
    { auth: BOB, method: 'update', path: 'households/h1', existing: household,
      data: { ...household, member_uids: ['alice', 'bob', 'carol'], member_emails: { ...household.member_emails, carol: 'carol@example.com' } } }],
  ['non-member joins household without invitation', 'DENY',
    { auth: CAROL, method: 'update', path: 'households/h1', existing: household,
      data: { ...household, member_uids: ['alice', 'bob', 'carol'], member_emails: { ...household.member_emails, carol: 'carol@example.com' } } }],

  // ── Profiles, overlapping and nested paths ──
  ['user stores an extra field in their profile', 'DENY',
    { auth: ALICE, method: 'update', path: 'users/alice', existing: { household_id: 'h1' }, data: { household_id: 'h1', is_admin: true } }],
  ['user clears own household pointer', 'ALLOW', { auth: ALICE, method: 'update', path: 'users/alice', existing: { household_id: 'h1' }, data: {} }],
  ['owner reads a nested path under own item (no rule)', 'DENY',
    { auth: ALICE, method: 'get', path: 'vanity_items/i1/history/x', existing: { a: 1 } }],
  ['member writes a nested path under a shared item', 'DENY',
    { auth: BOB, method: 'create', path: 'vanity_items/i1/notes/x', data: { text: 'x' } }],
  ['household member writes a nested path under the household', 'DENY',
    { auth: BOB, method: 'create', path: 'households/h1/members/carol', data: { uid: 'carol' } }],
  ['create receipt with a non-numeric total', 'DENY',
    { auth: ALICE, method: 'create', path: 'receipts/r1', data: { ...receipt('alice'), total_amount: 'lots' } }],
  ['create item with a non-boolean sharing flag', 'DENY',
    { auth: ALICE, method: 'create', path: 'vanity_items/i1', data: item('alice', { is_shared_with_household: 'yes', shared_household_id: 'h1' }) }],

  // ── Product catalog ──
  ['signed-in user reads catalog product', 'ALLOW', { auth: BOB, method: 'get', path: 'products/p1', existing: { name: 'Gel', created_by: 'alice' } }],
  ['unauthenticated reads catalog product', 'DENY', { method: 'get', path: 'products/p1', existing: { name: 'Gel', created_by: 'alice' } }],
  ['create product recording yourself as creator', 'ALLOW', { auth: ALICE, method: 'create', path: 'products/p9', data: { name: 'Gel', created_by: 'alice' } }],
  ['create product without a creator', 'DENY', { auth: ALICE, method: 'create', path: 'products/p9', data: { name: 'Gel' } }],
  ['overwrite another user\'s product', 'DENY',
    { auth: BOB, method: 'update', path: 'products/p1', existing: { name: 'Gel', created_by: 'alice' }, data: { name: 'Spam', created_by: 'bob' } }],
  ['delete another user\'s product', 'DENY', { auth: BOB, method: 'delete', path: 'products/p1', existing: { name: 'Gel', created_by: 'alice' } }],
  ['creator updates own product', 'ALLOW',
    { auth: ALICE, method: 'update', path: 'products/p1', existing: { name: 'Gel', created_by: 'alice' }, data: { name: 'Gel 2', created_by: 'alice' } }],
  ['update a legacy product with no creator', 'DENY',
    { auth: ALICE, method: 'update', path: 'products/p0', existing: { name: 'Old' }, data: { name: 'Old', created_by: 'alice' } }],

  // ── Other collections ──
  ['write categories', 'DENY', { auth: ALICE, method: 'create', path: 'categories/c1', data: { name: 'x' } }],
  ['read categories', 'ALLOW', { auth: ALICE, method: 'get', path: 'categories/serum', existing: { category_name: 'Serum' } }],
  ['use legacy mail queue', 'DENY', { auth: ALICE, method: 'create', path: 'mail/m1', data: { to: 'x@example.com' } }],
  ['write an unknown collection', 'DENY', { auth: ALICE, method: 'create', path: 'anything/x', data: { a: 1 } }],
];

function toTestCase([, expectation, r]) {
  const request = { method: r.method, path: `${DB}/${r.path}`, time: NOW };
  if (r.auth) request.auth = r.auth;
  if (r.data) request.resource = { data: r.data };
  const tc = { expectation, request, functionMocks: mocks };
  if (r.existing) tc.resource = { data: r.existing };
  return tc;
}

module.exports = { cases, toTestCase };
