# Vanity Tracker – local invitation email server

A small Node.js backend (Express + Nodemailer) that runs **on your laptop** and emails
household invitations through **your Gmail account** using a Gmail **App Password**.
No Firebase billing, Cloud Functions, or paid email service is needed.

```
Flutter app (Invite) ──► Firestore: invitation saved (status pending)
        │
        └─► POST http://localhost:8787/api/invitations/<id>/send
              Authorization: Bearer <Firebase ID token>
                 │
                 ├─ verifies the token signature with Google's public keys
                 ├─ reads the invitation + household from Firestore AS YOU (rules apply)
                 ├─ checks: you created it, you own the household, pending, not expired,
                 │          recipient not already a member, retry/rate limits
                 ├─ sends ONE fixed-template email via smtp.gmail.com
                 └─ records queued → sent / failed (+ Gmail's SMTP response) on the invitation
```

There is no "send any email" endpoint: the recipient, subject and body always come from the
stored invitation and a fixed template.

## One-time setup

1. **Install Node.js 20.12 or newer** (this laptop has Node 24).
2. **Create a Gmail App Password** (requires 2-Step Verification on the Google account):
   - Open <https://myaccount.google.com/apppasswords>, sign in with the Gmail account
     that should *send* the invitations.
   - If the page says App Passwords are unavailable, turn on 2-Step Verification first
     (<https://myaccount.google.com/signinoptions/twosv>). Some work/school accounts
     do not allow App Passwords; use a personal Gmail account.
   - Name it "Vanity Tracker" and copy the 16-character password that is shown.
3. **Create `server/.env`** from the template, then edit it **yourself** in a text editor:
   ```powershell
   cd server
   Copy-Item .env.example .env
   notepad .env
   ```
   Set `GMAIL_USER=` to the sending Gmail address and `GMAIL_APP_PASSWORD=` to the App
   Password. Keep `FIREBASE_PROJECT_ID=vanitytracker` (the project the web app uses).
   **Never paste the App Password into chat, the Flutter code, or Git.** `.env` is git-ignored.
   Optionally set `APP_URL=` to the **public** address of the web app (e.g.
   `https://your-app.web.app`). Invitation emails then show an **Open Vanity Tracker**
   button plus the same link as plain text. If `APP_URL` is empty or invalid, emails are sent
   without a link and `npm start` / `npm run verify-smtp` print a warning. A `localhost` URL
   only works for people using this laptop.
4. **Install dependencies:**
   ```powershell
   npm install
   ```
5. **Check the Gmail login without sending anything:**
   ```powershell
   npm run verify-smtp
   ```
   Expected: `OK: Gmail SMTP accepted the login for y***@gmail.com. No email was sent.`

## Every time you demo

Terminal 1 – the email server (leave it running):
```powershell
cd server
npm start
```
Terminal 2 – the app:
```powershell
flutter run -d chrome
```
The web app calls `http://localhost:8787` by default. To use another address:
`flutter run -d chrome --dart-define=INVITE_API_BASE_URL=http://127.0.0.1:9000`.

## What the app shows

| Badge | Meaning |
|---|---|
| **Email Sent** | Gmail's SMTP server accepted the message (e.g. `250 2.0.0 OK`). This does **not** guarantee Inbox placement – ask the recipient to check **Spam**/Promotions. |
| **Email Queue Failed** | Not sent; the reason is shown (wrong App Password, server not running, refused recipient, …). Use **Retry email**. |
| **In-App Only** | Email not configured (no `.env` / offline mode). The recipient can still accept inside the app. |

The recipient always accepts **inside the app**: sign up / sign in with the invited email
address → Household Sharing → **Accept**.

## Limits and safety

- Only the household **owner** can send invitations; only the inviter can (re)send the email.
- One email per invitation; **Retry/Resend** is allowed after 60 s, max 5 attempts.
- Per user: 10 emails/hour; whole server: 100/day (Gmail's own limit is ~500/day).
- Bound to `127.0.0.1` so only this laptop can reach it. Browser calls are only accepted
  from `http://localhost:*` / `http://127.0.0.1:*` (configure `ALLOWED_ORIGINS` otherwise).
- Logs mask email addresses and never print the App Password.

## Tests

```powershell
npm test
```
These use a **mock** mail transport and in-memory Firestore. They prove the authorization
and status logic, not real delivery. Real delivery is verified by sending one invitation to
a Gmail inbox you control.

## Android & Mobile Testing

Both the Android build and the Web app use the same Firebase project (`vanitytracker`).

- **Android Emulator**: Reaches this server at `http://10.0.2.2:8787` by default without extra configuration.
- **Physical Phone**:
  1. In `server/.env`, set `HOST=0.0.0.0` so the server listens on all network interfaces.
     > **Warning**: Only bind to `0.0.0.0` while connected to a trusted private Wi-Fi network.
  2. Find your laptop's LAN IP address (e.g. `ipconfig` on Windows -> IPv4 Address, e.g. `192.168.1.50`).
  3. Start the server:
     ```powershell
     cd server
     npm start
     ```
  4. Run Flutter with the laptop's LAN IP:
     ```powershell
     flutter run -d <device-id> --dart-define=INVITE_API_BASE_URL=http://<YOUR_LAPTOP_IP>:8787
     ```
  5. Cleartext HTTP is permitted for development in debug builds via `android/app/src/debug/res/xml/network_security_config.xml`. Release builds strictly require HTTPS.
