import { createApp } from '../src/app.js';
import { createFirebaseTokenVerifier } from '../src/auth.js';
import { buildConfig, loadDotEnv } from '../src/config.js';
import { createFirestoreRestClient } from '../src/firestore.js';
import { createInvitationEmailService } from '../src/invitationService.js';
import { createMailer } from '../src/mailer.js';

loadDotEnv();
const config = buildConfig();

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

export default app;
