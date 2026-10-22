import nodemailer from 'nodemailer';
import { missingMailSettings } from './config.js';

/** Turns a Nodemailer/SMTP error into a message that is safe to show and store (no secrets). */
export function describeSmtpError(err) {
  const code = err?.code || '';
  const responseCode = err?.responseCode;
  if (code === 'EAUTH' || responseCode === 535 || responseCode === 534) {
    return 'Gmail rejected the login. Check GMAIL_USER and that GMAIL_APP_PASSWORD is a valid App Password (not your normal password).';
  }
  if (['ECONNECTION', 'ETIMEDOUT', 'ESOCKET', 'EDNS', 'ECONNREFUSED'].includes(code)) {
    return 'Could not connect to Gmail SMTP. Check this laptop\'s internet connection or firewall.';
  }
  if (code === 'EENVELOPE' || (responseCode >= 550 && responseCode < 560)) {
    return 'Gmail refused the recipient address.';
  }
  if (responseCode === 421 || responseCode === 454 || responseCode === 452) {
    return 'Gmail temporarily refused the message (rate limit or temporary error). Try again later.';
  }
  return `Email sending failed${code ? ` (${code})` : ''}.`;
}

/**
 * Wraps a Nodemailer transport. `transport` is injectable so tests never touch the network.
 * Returns { configured, missing, send(message) }.
 */
export function createMailer(config, transport) {
  const missing = missingMailSettings(config);
  const configured = missing.length === 0;
  const tx = transport ?? (configured
    ? nodemailer.createTransport({
        host: config.mail.host,
        port: config.mail.port,
        secure: config.mail.port === 465,
        auth: { user: config.mail.user, pass: config.mail.appPassword },
        connectionTimeout: 15000,
        greetingTimeout: 15000,
        socketTimeout: 30000,
      })
    : null);

  return {
    configured,
    missing,
    fromAddress: config.mail.user,
    async verify() {
      if (!tx) throw new Error(`Email is not configured. Missing: ${missing.join(', ')}`);
      return tx.verify();
    },
    /** Sends one message; resolves with the provider's info (accepted/rejected/response/messageId). */
    async send({ to, subject, text, html }) {
      if (!tx) throw new Error(`Email is not configured. Missing: ${missing.join(', ')}`);
      return tx.sendMail({
        from: { name: config.mail.fromName, address: config.mail.user },
        to,
        subject,
        text,
        html,
      });
    },
  };
}
