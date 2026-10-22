# Firestore security-rule tests

## 1. Firestore emulator (primary)

`emulator_rules_test.js` runs 56 cases against `firestore.rules` in the local Firestore
emulator, using the app's real operations: its queries, the batched invitation acceptance
(with array transforms) and the field-level "leave household" update. Data is re-seeded
before every case. Requires Java 21+ (portable JDK at `C:\Users\Admin\jdk-21`) and the
Firebase CLI:

```powershell
$env:JAVA_HOME = "C:\Users\Admin\jdk-21"; $env:PATH = "C:\Users\Admin\jdk-21\bin;$env:PATH"
firebase emulators:exec --only firestore --project demo-vanity-test "node security/emulator_rules_test.js"
```

`demo-` project ids are offline-only: this never contacts the real Firebase project.

## 2. Rules API evaluation (secondary)

`rules_test_cases.js` / `run_rules_tests.js` evaluate 87 cases with the Firebase Rules API
`projects.test` method (Google's rules engine; no deployment, no data access; `get()` /
`exists()` mocked). Batched writes and queries are only approximated here.

```
node security/run_rules_tests.js vanity-tracker firestore.rules
```

Needs the Firebase CLI to be logged in with access to the project. (On Windows, Node may
print a libuv "Assertion failed ... async.c" line after the results; it is harmless.)

## 3. Emergency containment (NOT deployed)

`containment-deny-all.rules` denies every client request. It exists only for an approved
emergency containment step; deploying it stops all Firestore-backed app features until
`firestore.rules` is deployed.
