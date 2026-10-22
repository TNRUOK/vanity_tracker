import { validateAppUrl } from './config.js';

const HTML_ESCAPES = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };

export function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => HTML_ESCAPES[c]);
}

/** Collapses whitespace/control characters and limits length of user-supplied text. */
export function cleanText(s, max = 80) {
  const t = String(s ?? '')
    .replace(/[\u0000-\u001f\u007f]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  return t.length > max ? `${t.slice(0, max - 1)}…` : t;
}

/**
 * Builds the fixed invitation email. Only the household name and inviter name are
 * user-controlled, and both are cleaned and escaped. No caller can supply free-form content.
 * [appUrl] comes from the APP_URL setting; it is re-validated here and the button/link is
 * omitted (never invented) when it is missing or invalid.
 */
export function buildInvitationEmail({ householdName, inviterName, recipientEmail, expiresAt, appUrl }) {
  const hh = cleanText(householdName || 'a household');
  const inviter = cleanText(inviterName || 'A Vanity Tracker user', 60);
  const expires = expiresAt instanceof Date && !Number.isNaN(expiresAt.getTime())
    ? expiresAt.toUTCString().replace(/ \d\d:\d\d:\d\d GMT$/, '')
    : 'in 7 days';
  const link = validateAppUrl(appUrl).url;

  const subject = cleanText(`${inviter} invited you to join "${hh}" on Vanity Tracker`, 150);

  const text = [
    'Hi,',
    '',
    `${inviter} has invited you to join the household "${hh}" on Vanity Tracker.`,
    '',
    ...(link ? ['Open Vanity Tracker:', link, ''] : []),
    'To accept:',
    `1. Open Vanity Tracker${link ? ' using the link above' : ''}.`,
    `2. Sign in or sign up with this exact email address: ${recipientEmail}`,
    '   (invitations can only be accepted by the invited email address).',
    '3. Go to Household Sharing and tap Accept on the invitation.',
    '',
    `This invitation expires on ${expires}.`,
    "If you weren't expecting this email, you can ignore it.",
  ].join('\n');

  const safeLink = link ? escapeHtml(link) : '';
  const button = link
    ? '<table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:24px 0">' +
      '<tr><td align="center" bgcolor="#be185d" style="border-radius:8px">' +
      `<a href="${safeLink}" target="_blank" rel="noopener" ` +
      'style="display:inline-block;padding:14px 28px;font-family:Arial,sans-serif;font-size:16px;' +
      'font-weight:bold;color:#ffffff;text-decoration:none;border-radius:8px;background:#be185d">' +
      'Open Vanity Tracker</a></td></tr></table>' +
      '<p style="color:#6b7280;font-size:13px">If the button does not work, copy this link into your browser:<br>' +
      `<a href="${safeLink}" style="color:#be185d;word-break:break-all">${safeLink}</a></p>`
    : '';

  const html =
    '<div style="font-family:Arial,sans-serif;max-width:560px;margin:0 auto;padding:20px;color:#1f2937">' +
    '<h2 style="color:#be185d;margin-top:0">Vanity Tracker household invitation</h2>' +
    `<p><strong>${escapeHtml(inviter)}</strong> has invited you to join the household <strong>"${escapeHtml(hh)}"</strong>.</p>` +
    button +
    '<p>To accept:</p><ol>' +
    `<li>Open Vanity Tracker${link ? ' using the button above' : ''}.</li>` +
    `<li>Sign in or sign up with this exact email address: <strong>${escapeHtml(recipientEmail)}</strong> ` +
    '(invitations can only be accepted by the invited email address).</li>' +
    '<li>Go to <strong>Household Sharing</strong> and tap <strong>Accept</strong> on the invitation.</li></ol>' +
    `<p style="color:#6b7280;font-size:13px">This invitation expires on ${escapeHtml(expires)}. ` +
    "If you weren't expecting this email, you can ignore it.</p></div>";

  return { subject, text, html };
}
