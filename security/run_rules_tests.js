// Evaluates security/rules_test_cases.js against a rules file with the Firebase Rules API
// `projects.test` method (Google's rules engine). It does NOT deploy rules and does NOT
// read or write any Firestore data. Uses the Firebase CLI login; never prints tokens.
//
//   node security/run_rules_tests.js vanity-tracker firestore.rules
//
// Exit code 0 only when every case matches its expected ALLOW/DENY.
const fs = require('fs');
const path = require('path');
const { cases, toTestCase } = require('./rules_test_cases');

const ft = path.join(process.env.APPDATA || '', 'npm', 'node_modules', 'firebase-tools', 'lib');
const { requireAuth } = require(path.join(ft, 'requireAuth.js'));
const { Client } = require(path.join(ft, 'apiv2.js'));
const { configstore } = require(path.join(ft, 'configstore.js'));

(async () => {
  const [project, file, ...flags] = process.argv.slice(2);
  if (!project || !file) throw new Error('usage: run_rules_tests.js <project> <rules file> [--quiet]');
  await requireAuth({ project, nonInteractive: true, user: configstore.get('user'), tokens: configstore.get('tokens') });
  const c = new Client({ urlPrefix: 'https://firebaserules.googleapis.com', apiVersion: 'v1' });
  const source = { files: [{ name: 'firestore.rules', content: fs.readFileSync(file, 'utf8') }] };
  const res = await c.post(`/projects/${project}:test`, { source, testSuite: { testCases: cases.map(toTestCase) } });

  for (const i of res.body.issues || []) {
    console.log(`COMPILE ${i.severity} line ${i.sourcePosition?.line}: ${i.description}`);
  }
  const results = res.body.testResults || [];
  let failed = 0;
  results.forEach((r, i) => {
    const [name, expected] = cases[i];
    const ok = r.state === 'SUCCESS';
    if (!ok) failed++;
    const actual = ok ? expected : (expected === 'ALLOW' ? 'DENY' : 'ALLOW');
    if (!ok || !flags.includes('--quiet')) {
      console.log(`${ok ? 'PASS' : 'FAIL'}  expected ${expected.padEnd(5)} got ${actual.padEnd(5)}  ${name}`);
      if (!ok && r.debugMessages?.length) console.log('      ' + r.debugMessages.join(' | '));
    }
  });
  console.log(`\n${results.length - failed}/${results.length} cases matched (${path.basename(file)})`);
  process.exit(failed === 0 && results.length === cases.length ? 0 : 1);
})().catch((e) => { console.error('ERR', e.status || '', e.message); process.exit(2); });
