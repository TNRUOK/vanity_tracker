import { buildInvitationEmail } from './emailTemplate.js';
import { describeSmtpError } from './mailer.js';
import { maskEmail } from './config.js';

export class HttpError extends Error {
  constructor(status, code, message, extra = {}) {
    super(message);
    this.status = status;
    this.code = code;
    this.extra = extra;
  }
}

const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const ID_RE = /^[A-Za-z0-9_-]{1,128}$/;

function parseExpiry(inv) {
  if (typeof inv.expires_at_ms === 'number') return new Date(inv.expires_at_ms);
  const d = new Date(inv.expires_at ?? '');
  return Number.isNaN(d.getTime()) ? null : d;
}

/** Sliding-window counters kept in memory (the backend is a single local process). */
export class RateLimiter {
  constructor(now = () => Date.now()) {
    this.now = now;
    this.events = new Map();
  }
  count(key, windowMs) {
    const cutoff = this.now() - windowMs;
    const list = (this.events.get(key) || []).filter((t) => t > cutoff);
    this.events.set(key, list);
    return list.length;
  }
  record(key) {
    const list = this.events.get(key) || [];
    list.push(this.now());
    this.events.set(key, list);
  }
}

/**
 * Validates that the authenticated caller may email this invitation and, if so,
 * sends exactly one fixed-template email and records the outcome on the invitation.
 *
 * deps: { config, firestore, mailer, limiter, now, log }
 */
export function createInvitationEmailService({ config, firestore, mailer, limiter = new RateLimiter(), now = () => Date.now(), log = console }) {
  const inFlight = new Set();

  async function recordStatus(invitationId, fields, idToken) {
    try {
      await firestore.updateFields('household_invitations', invitationId, fields, idToken);
      return true;
    } catch (e) {
      log.warn(`[invite ${invitationId}] could not record delivery status: ${e.message}`);
      return false;
    }
  }

  const service = {
    async sendInvitationEmail({ caller, invitationId, resend = false, idToken }) {
      if (!ID_RE.test(invitationId || '')) throw new HttpError(400, 'invalid-argument', 'Invalid invitation id.');
      // Lock before any await so simultaneous requests cannot both pass the checks below.
      if (inFlight.has(invitationId)) {
        throw new HttpError(409, 'in-progress', 'This invitation email is already being sent.');
      }
      inFlight.add(invitationId);
      try {
        return await sendLocked({ caller, invitationId, resend, idToken });
      } finally {
        inFlight.delete(invitationId);
      }
    },
  };

  async function sendLocked({ caller, invitationId, resend, idToken }) {
    // 1. Load the invitation and household AS THE CALLER (rules still apply).
    const inv = await firestore.getDoc('household_invitations', invitationId, idToken);
    if (!inv) throw new HttpError(404, 'not-found', 'Invitation not found.');

    if (inv.invited_by_uid !== caller.uid) {
      throw new HttpError(403, 'permission-denied', 'Only the person who created this invitation can send its email.');
    }

    const householdId = inv.household_id;
    if (!ID_RE.test(householdId || '')) throw new HttpError(400, 'invalid-argument', 'Invitation has no valid household.');
    const household = await firestore.getDoc('households', householdId, idToken);
    if (!household) throw new HttpError(404, 'not-found', 'Household not found.');
    if (household.created_by !== caller.uid) {
      throw new HttpError(403, 'permission-denied', 'Only the household owner can send invitations.');
    }
    const members = Array.isArray(household.member_uids) ? household.member_uids : [];
    if (!members.includes(caller.uid)) {
      throw new HttpError(403, 'permission-denied', 'You are not a member of this household.');
    }

    // 2. Validate the invitation itself.
    const recipient = String(inv.invited_email || '').trim().toLowerCase();
    if (!EMAIL_RE.test(recipient) || recipient.length > 254) {
      throw new HttpError(400, 'invalid-argument', 'Invitation has an invalid recipient email.');
    }
    if (caller.email && recipient === caller.email) {
      throw new HttpError(400, 'invalid-argument', 'You cannot invite yourself.');
    }
    const memberEmails = Object.values(household.member_emails || {}).map((e) => String(e).toLowerCase());
    if (memberEmails.includes(recipient)) {
      throw new HttpError(409, 'already-member', 'That person is already a member of this household.');
    }
    if (inv.status !== 'pending') {
      throw new HttpError(409, 'not-pending', `Invitation is ${inv.status || 'not pending'}; no email was sent.`);
    }
    const expiresAt = parseExpiry(inv);
    if (!expiresAt || expiresAt.getTime() <= now()) {
      throw new HttpError(409, 'expired', 'Invitation has expired; create a new one.');
    }

    // 3. Idempotency: never email the same invitation twice unless explicitly resent.
    if (inv.email_delivery_status === 'sent' && !resend) {
      return {
        status: 200,
        body: { invitationId, emailStatus: 'sent', alreadySent: true, providerResponse: inv.email_provider_response ?? null },
      };
    }
    const attempts = Number(inv.email_attempts) || 0;
    if (attempts >= config.limits.maxAttemptsPerInvitation) {
      throw new HttpError(429, 'too-many-attempts', 'This invitation has reached its email retry limit.');
    }
    const lastAttempt = Date.parse(inv.email_last_attempt_at || '');
    if (!Number.isNaN(lastAttempt) && now() - lastAttempt < config.limits.resendCooldownMs) {
      const waitS = Math.ceil((config.limits.resendCooldownMs - (now() - lastAttempt)) / 1000);
      throw new HttpError(429, 'cooldown', `Please wait ${waitS}s before sending this invitation again.`);
    }

    // 4. Sender configured?
    if (!mailer.configured) {
      const message = `Email sending is not configured on the backend (missing ${mailer.missing.join(', ')}).`;
      await recordStatus(invitationId, { email_delivery_status: 'notConfigured', email_delivery_error: message }, idToken);
      throw new HttpError(503, 'email-not-configured', message, { emailStatus: 'notConfigured' });
    }

    // 5. Abuse limits.
    const userKey = `user:${caller.uid}`;
    if (limiter.count(userKey, 3600_000) >= config.limits.perUserPerHour) {
      throw new HttpError(429, 'rate-limited', 'Too many invitation emails sent recently. Try again later.');
    }
    if (limiter.count('global', 86_400_000) >= config.limits.perDay) {
      throw new HttpError(429, 'rate-limited', 'Daily invitation email limit reached for this backend.');
    }

    limiter.record(userKey);
    limiter.record('global');
    const attemptAt = new Date(now()).toISOString();
    await recordStatus(invitationId, {
      email_delivery_status: 'queued',
      email_delivery_error: null,
      email_attempts: attempts + 1,
      email_last_attempt_at: attemptAt,
    }, idToken);

    const message = buildInvitationEmail({
      householdName: household.name || inv.household_name,
      inviterName: inv.invited_by_name,
      recipientEmail: recipient,
      expiresAt,
      appUrl: config.appUrl,
    });

    let info;
    try {
      info = await mailer.send({ to: recipient, ...message });
    } catch (err) {
      const safe = describeSmtpError(err);
      log.warn(`[invite ${invitationId}] send to ${maskEmail(recipient)} failed: ${err?.code || err?.name || 'error'}`);
      await recordStatus(invitationId, { email_delivery_status: 'failed', email_delivery_error: safe }, idToken);
      throw new HttpError(502, 'email-failed', safe, { emailStatus: 'failed' });
    }

    const accepted = (info?.accepted || []).map((a) => String(typeof a === 'object' ? a.address : a).toLowerCase());
    const rejected = info?.rejected || [];
    const providerResponse = String(info?.response || '').slice(0, 200);
    if (!accepted.includes(recipient) || rejected.length > 0) {
      const safe = 'Gmail did not accept the recipient address.';
      await recordStatus(invitationId, {
        email_delivery_status: 'failed',
        email_delivery_error: safe,
        email_provider_response: providerResponse,
      }, idToken);
      throw new HttpError(502, 'email-failed', safe, { emailStatus: 'failed' });
    }

    const recorded = await recordStatus(invitationId, {
      email_delivery_status: 'sent',
      email_delivery_error: null,
      email_sent_at: new Date(now()).toISOString(),
      email_message_id: String(info?.messageId || '').slice(0, 200),
      email_provider_response: providerResponse,
    }, idToken);
    log.info(`[invite ${invitationId}] accepted by SMTP for ${maskEmail(recipient)}: ${providerResponse}`);
    return {
      status: 200,
      body: { invitationId, emailStatus: 'sent', alreadySent: false, providerResponse, statusRecorded: recorded },
    };
  }

  return service;
}
