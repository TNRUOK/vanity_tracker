// Checks that Gmail accepts the configured login WITHOUT sending any email.
// Usage: npm run verify-smtp
import { buildConfig, loadDotEnv, maskEmail } from '../src/config.js';
import { createMailer, describeSmtpError } from '../src/mailer.js';

loadDotEnv();
const config = buildConfig();
const mailer = createMailer(config);

console.log(`Invitation email link (APP_URL): ${config.appUrl ?? 'NONE'}`);
if (config.appUrlWarning) console.warn(`WARNING: ${config.appUrlWarning}`);

if (!mailer.configured) {
  console.error(`Not configured. Missing in server/.env: ${mailer.missing.join(', ')}`);
  process.exit(1);
}

try {
  await mailer.verify();
  console.log(`OK: Gmail SMTP accepted the login for ${maskEmail(config.mail.user)}. No email was sent.`);
} catch (e) {
  console.error(`FAILED: ${describeSmtpError(e)}`);
  process.exit(1);
}
