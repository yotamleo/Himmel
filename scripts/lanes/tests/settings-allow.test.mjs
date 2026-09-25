// scripts/lanes/tests/settings-allow.test.mjs
// HIMMEL-3402 — the project permissions.allow list must not auto-approve a
// trust-root script (scripts/cr/, scripts/guardrails/, scripts/hooks/) by
// prefix. A prefix or glob rule approves every spelling the shell accepts —
// `//`, `./`, brace lists, `..` traversal out of an allowed directory, a
// quiet-run wrapper around a second command — without the classifier or the
// operator ever seeing it. Only per-script literal rules are safe, plus the
// two exact /pr-check step-0 literals and quiet-run's enumerated `suite` rules
// (quiet-run.sh refuses a `..` argv component itself, HIMMEL-2967).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const SETTINGS = JSON.parse(readFileSync(join(REPO_ROOT, '.claude', 'settings.json'), 'utf8'));
const REG = JSON.parse(readFileSync(join(REPO_ROOT, 'scripts', 'lanes', 'plugin-profiles.json'), 'utf8'));
const ALLOW = SETTINGS.permissions.allow.filter((r) => r.startsWith('Bash('));
// What a leg-profile session sees: the project list plus the profile's gateAllow.
const LEG_ALLOW = [...ALLOW, ...REG.gateAllow];

const STEP0 = [
  'bash scripts/cr/pr-check-context.sh',
  'bash scripts/cr/pr-check-env.sh CR_CLAUDE_AGENTS',
];

// HIMMEL-3462: exact (no wildcard-tail) per-script literals beyond STEP0 —
// each is a genuinely fixed invocation (no leg-supplied variable argument),
// so the LITERAL_FILE wildcard-tail shape below does not apply to them.
const EXACT_LITERALS = [
  'bash scripts/cr/doc-freshness-advisory.sh',
  'bash scripts/cr/known-findings.sh --diff',
  'bash scripts/cr/codex-adv-kickoff.sh',
  'bash scripts/cr/codex-adv-harvest.sh',
  'bash scripts/cr/cr-scores.sh',
];

// HIMMEL-3548: the PROJECT and leg-profile relative merge-on-green rules
// were retired — only the anchored spelling (ANCHOR_LITERALS below) is
// pre-approved by those registries now. A user-scope settings rule (outside
// this repo, per-station) may still admit the relative spelling; this test
// asserts against the project/profile registries only.
const RETIRED_LITERALS = [
  'bash scripts/handover/merge-on-green.sh',
  'bash scripts/handover/merge-on-green.sh --jira-transition',
];

// HIMMEL-3491: the merge-gate ENTRY runs from the $HIMMEL_REPO anchor, not
// branch-controlled bytes. This is a `:*`-tail rule (unlike the two exact
// literals above), so it covers both the bare and --jira-transition spellings.
const ANCHOR_LITERALS = [
  'bash "$HIMMEL_REPO/scripts/handover/merge-on-green.sh"',
  'bash "$HIMMEL_REPO/scripts/handover/merge-on-green.sh" --jira-transition',
];

// A model of the documented rule forms, not the harness matcher: `X:*` = X or
// X plus a space-separated tail; a body with `*` is a glob whose `*` matches
// any characters (slashes and spaces included), and a trailing ` *` also
// matches the bare prefix; anything else is exact. It can UNDER-match the
// real harness — a command that differs only by a run of extra whitespace
// (a double space the harness may still treat as a separator), or one that
// reaches a guarded literal through an indirection the harness's own matcher
// may still resolve (e.g. `xargs bash scripts/cr/x.sh`), can read here as "no
// rule matches" even though the real matcher would catch it. That is the
// UNSAFE direction for a "matches nothing" RED assertion: a false negative
// hides a gap instead of manufacturing one. Treat a RED row that passes here
// as a lower bound on what the harness refuses, not proof of it.
function ruleMatches(rule, command) {
  const body = /^Bash\(([\s\S]*)\)$/.exec(rule)?.[1];
  if (body === undefined) return false;
  if (body.endsWith(':*')) {
    const prefix = body.slice(0, -2);
    return command === prefix || command.startsWith(`${prefix} `);
  }
  if (!body.includes('*')) return command === body;
  const esc = (s) => s.replace(/[.+?^${}()|[\]\\]/g, '\\$&');
  const glob = new RegExp(`^${body.split('*').map(esc).join('[\\s\\S]*')}$`);
  return glob.test(command) || (body.endsWith(' *') && command === body.slice(0, -2));
}
const matching = (rules, command) => rules.filter((r) => ruleMatches(r, command));

test('the matcher model itself: prefix, glob and exact forms', () => {
  assert.ok(ruleMatches('Bash(bash scripts/*)', 'bash scripts/lanes/../cr/x.sh'));
  assert.ok(ruleMatches('Bash(ls *)', 'ls'));
  assert.ok(ruleMatches('Bash(bash scripts/a.sh:*)', 'bash scripts/a.sh --x'));
  assert.ok(!ruleMatches('Bash(bash scripts/a.sh:*)', 'bash scripts/a.sh/../cr/x.sh'));
  assert.ok(!ruleMatches('Bash(bash scripts/a.sh)', 'bash scripts/a.sh --x'));
});

// RED rows: every one of these reaches a trust-root script (or runs an
// arbitrary second command) and must match NO rule a session auto-allows.
const TRUST_SPELLINGS = [
  // HIMMEL-3462 grants scripts/cr/impacted-suites.sh:*, orphan-check.sh:* and
  // review-round.sh:* via plugin-profiles.json's gateAllow (safety rationale
  // in the PR body), never in .claude/settings.json itself (TRUST_DIR forbids
  // a wildcard-tail trust-root rule there) — so a bare/space-tailed
  // invocation of any of the three is sanctioned for a LEG session only, see
  // LEG_SANCTIONED below. These two prove the wildcard tail cannot be ridden
  // past the granted script's own filename into a trust-root escape.
  'bash scripts/cr/impacted-suites.sh/../clear-cr-marker.sh',
  'bash scripts/cr/review-round.sh/../clear-cr-marker.sh',
  'bash scripts//cr/clear-cr-marker.sh',
  'bash ./scripts/cr/clear-cr-marker.sh',
  'bash scripts/{cr,x}/clear-cr-marker.sh',
  'bash scripts/c?/clear-cr-marker.sh',
  'CR_X=1 bash scripts/cr/clear-cr-marker.sh',
  'bash scripts/lanes/../cr/clear-cr-marker.sh',
  'bash scripts/check-ci.sh/../cr/clear-cr-marker.sh',
  'bash scripts/handover/test-x/../../cr/clear-cr-marker.sh',
  'bash scripts/hooks/test-x/../../evil.sh',
  'bash scripts/hooks/guard-pr-check-literal.sh',
  'bash scripts/guardrails/leak-classes.sh',
  'bash scripts/quiet-run.sh x -- bash scripts/cr/y.sh',
  'bash scripts/quiet-run.sh suite -- bash scripts/cr/y.sh',
  'bash scripts/cr/pr-check-context.sh --x',
  'bash scripts/cr/pr-check-env.sh CR_PROFILE',
  'bash tests/../scripts/cr/clear-cr-marker.sh',
  'bash marketplace/plugins/../../scripts/cr/clear-cr-marker.sh',
];

for (const command of TRUST_SPELLINGS) {
  test(`no project allow rule matches: ${command}`, () => {
    assert.deepEqual(matching(ALLOW, command), []);
  });
}

// The gateAllow scripts/cr/ writers are literal `:*` rules, so only a
// spelling that is not their literal prefix must stay unmatched for a leg.
for (const command of TRUST_SPELLINGS.filter((c) => !/^bash scripts\/cr\/(clear-cr-marker|write-verdicts|ledger-append|panel-first-pass|docs-audit-panel)\.sh( |$)/.test(c))) {
  test(`no leg-profile allow rule matches: ${command}`, () => {
    assert.deepEqual(matching(LEG_ALLOW, command), []);
  });
}

// HIMMEL-3495: an exact scripts/cr literal with a second command riding
// behind it must match no rule either - the literal grants that one command,
// never a compound. (The `:*` gateAllow rules, including ledger-append.sh and
// clear-cr-marker.sh, are left out: this text model lets a `:*` tail absorb
// anything after a space, including a `; rider`, while the harness matches
// each subcommand. Both scripts are TARGETS of guard-pr-check-literal.sh
// (HIMMEL-3383/3495), which denies any command naming them that is not one
// simple command - no `;`/`&`/`|`/backtick/`()`/redirect/embedded newline -
// BEFORE gateAllow is ever consulted, IN A HIMMEL-PROJECT SESSION (the hook
// is registered only in this repo's own hook chain, not at user scope - a
// leg launched against a non-himmel target repo does not load it, tracked in
// HIMMEL-3558) - so within a himmel-project session a rider can never
// actually reach these two scripts' wildcard tail. This is a MODEL claim, not
// proof: gate-allow-hook-survival.test.mjs spawns the real hook binary with
// real rider payloads for both scripts and asserts its actual exit code. The
// full audit is in plugin-profiles.json's _comment_gateAllow, HIMMEL-3469/70,
// including the gate-evidence-forgery caveat (HIMMEL-3557) this rider-only
// check does not cover.)
const RIDERS = ['; evil', ' && evil', ' || evil', ' | sh', ' $(evil)', ' `evil`', '\nevil', ' & evil'];
for (const literal of [...STEP0, ...EXACT_LITERALS].filter((c) => c.startsWith('bash scripts/cr/'))) {
  for (const rider of RIDERS) {
    const command = `${literal}${rider}`;
    test(`no allow rule matches a literal with a rider: ${JSON.stringify(command)}`, () => {
      assert.deepEqual(matching(LEG_ALLOW, command), []);
    });
  }
}

// Controls: the sanctioned literals and the common non-trust families a leg
// and a console run every session still auto-allow.
const SANCTIONED = [
  ...STEP0,
  ...EXACT_LITERALS,
  ...ANCHOR_LITERALS,
  'bash scripts/check-ci.sh 1090',
  'bash scripts/context-fill.sh',
  'bash scripts/handover/queue-lock.sh acquire /abs/doc.md',
  'bash scripts/handover/wrap-subtree-check.sh',
  'bash scripts/handover/console-kit/go.sh 1090 abc',
  'bash scripts/lanes/leg-burn.sh HIMMEL-1-N1-x',
  'bash scripts/lanes/leg-pr-open.sh /t/title /t/body',
  'bash scripts/lib/bank-preflight.sh',
  'bash scripts/git/restore-to-head.sh scripts/x.sh',
  'git push',
  'bash scripts/quiet-run.sh suite -- bash scripts/cr/test-clear-cr-marker.sh',
  'SUITE_LOCK_WAIT=60 bash scripts/quiet-run.sh suite -- bash scripts/hooks/test-guard-pr-check-literal.sh',
];

for (const command of SANCTIONED) {
  test(`a project allow rule still matches: ${command}`, () => {
    assert.ok(matching(ALLOW, command).length > 0, `no rule matches ${command}`);
  });
}

for (const command of RETIRED_LITERALS) {
  test(`the retired relative merge-on-green rule matches no rule: ${command}`, () => {
    assert.deepEqual(matching(LEG_ALLOW, command), []);
  });
}

// These six are wildcard-tail trust-root grants that live ONLY in
// plugin-profiles.json's gateAllow (TRUST_DIR forbids them in the project
// .claude/settings.json), so a leg session sees them via LEG_ALLOW but a bare
// console/user session does not.
const LEG_SANCTIONED = [
  'bash scripts/cr/docs-audit-panel.sh --head abc1234 --branch fix/x',
  'bash scripts/cr/panel-first-pass.sh --head abc1234 --branch fix/x',
  'bash scripts/cr/write-verdicts.sh prior-blocking --branch fix/x',
  // HIMMEL-3462: newly granted this PR (impacted-suites.sh full-file read,
  // orphan-check.sh read-only basis, review-round.sh full-file read — all in
  // the PR body).
  'bash scripts/cr/impacted-suites.sh abc1234..def5678',
  'bash scripts/cr/orphan-check.sh --head abc1234',
  'bash scripts/cr/review-round.sh start --branch fix/x',
];

for (const command of LEG_SANCTIONED) {
  test(`a leg-profile allow rule matches: ${command}`, () => {
    assert.ok(matching(LEG_ALLOW, command).length > 0, `no leg rule matches ${command}`);
  });
}

// Structural: enumerate every rule that names a repo path and fail on any
// shape that can reach a trust root by prefix.
const TRUST_DIR = /(^|\s)(\S*\/)?scripts\/(cr|guardrails|hooks)\//;
const QUIET_SUITE = /^(SUITE_LOCK_WAIT=60 )?bash scripts\/quiet-run\.sh suite -- bash (scripts|templates\/luna-second-brain\/scripts)(\/[a-z-]+)*\/test-\*\.sh$/;
const LITERAL_FILE = /^(bash|bun|nohup bun) [A-Za-z0-9_./-]+\.(sh|ts|mjs|js):\*$/;

test('every path-naming Bash allow rule is a per-file literal, a step-0 literal or an enumerated quiet-run suite rule', () => {
  const pathRules = ALLOW.map((r) => /^Bash\(([\s\S]*)\)$/.exec(r)[1])
    .filter((b) => /(^|\s)(\.\/)?(scripts|tests|marketplace|templates)\//.test(b));
  assert.ok(pathRules.length > 10, 'anti-vacuity: expected the per-script rules');
  for (const body of pathRules) {
    if (STEP0.includes(body) || EXACT_LITERALS.includes(body) || QUIET_SUITE.test(body)) continue;
    assert.match(body, LITERAL_FILE, `not a per-file literal rule: ${body}`);
    assert.ok(!body.includes('..') && !body.includes('//'), `path trick in rule: ${body}`);
    assert.ok(!TRUST_DIR.test(body), `trust-root prefix rule: ${body}`);
  }
});

test('the project list carries every gateAllow quiet-run suite rule, so a console runs suites as a leg does', () => {
  for (const rule of REG.gateAllow.filter((r) => r.includes('quiet-run.sh suite'))) {
    assert.ok(ALLOW.includes(rule), `missing from .claude/settings.json: ${rule}`);
  }
});
