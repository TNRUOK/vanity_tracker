import { createApp } from './app.js';
import { createFirebaseTokenVerifier } from './auth.js';
import { buildConfig, loadDotEnv, maskEmail } from './config.js';
import { createFirestoreRestClient } from './firestore.js';
import { createInvitationEmailService } from './invitationService.js';
import { createMailer } from './mailer.js';

const hadEnv = loadDotEnv();
const config = buildConfig();

if (!config.projectId) {
  console.error('FIREBASE_PROJECT_ID is not set. Copy server/.env.example to server/.env and fill it in.');
  process.exit(1);
}

const mailer = createMailer(config);
const app = createApp({
  config,
  mailer,
  verifyIdToken: createFirebaseTokenVerifier(config.projectId),
  invitationService: createInvitationEmailService({
    config,
    mailer,
    firestore: createFirestoreRestClient(config.projectId),
  }),
});

app.listen(config.port, config.host, () => {
  console.log(`Vanity Tracker invite server listening on http://${config.host}:${config.port}`);
  console.log(`  .env loaded: ${hadEnv ? 'yes' : 'no (using environment only)'}`);
  console.log(`  Firebase project: ${config.projectId}`);
  console.log(mailer.configured
    ? `  Email sender: ${maskEmail(config.mail.user)} via ${config.mail.host}:${config.mail.port}`
    : `  Email sender: NOT CONFIGURED (missing ${mailer.missing.join(', ')}) - invitations stay in-app only`);
  console.log(`  Email "Open Vanity Tracker" link: ${config.appUrl ?? 'NONE'}`);
  if (config.appUrlWarning) console.warn(`  WARNING: ${config.appUrlWarning}`);
  if (config.host === '0.0.0.0') {
    console.warn('  SECURITY WARNING: Server is listening on 0.0.0.0 (all interfaces). Only use this on a trusted private Wi-Fi network.');
  }
});
