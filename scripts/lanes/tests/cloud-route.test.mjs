// scripts/lanes/tests/cloud-route.test.mjs — HIMMEL-4262
// Fixture tickets + stubbed Jira/gh: no live calls, no real bucket.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, existsSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { classifyTicket, buildBrief, launchLine, parseJiraGet } from '../cloud-route.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const CLI = join(HERE, '..', 'cloud-route.mjs');
const TRUST = [/^scripts\/ci\//, /^scripts\/lib\//, /^scripts\/hooks\/lib\//, /^\.github\//];

const tk = (over = {}) => ({
  key: 'HIMMEL-9001', type: 'Task', status: 'To Do', title: 'tick relayed results only',
  description: 'Fix the sed in scripts/lanes/example.sh.\nAdd a case to scripts/lanes/tests/example.test.sh.',
  ...over,
});
const ctx = (over = {}) => ({ trust: TRUST, held: [], ...over });

test('CLOUD-OK: small, one ask, plain files, nothing held', () => {
  const v = classifyTicket(tk(), ctx());
  assert.equal(v.class, 'CLOUD-OK');
  assert.ok(v.reason.length > 0);
  assert.deepEqual(v.files, ['scripts/lanes/example.sh', 'scripts/lanes/tests/example.test.sh']);
});

test('LOCAL-NATIVE: more than 3 asks', () => {
  const d = 'Asks:\n1. one in scripts/a.sh\n2. two\n3. three\n4. four';
  const v = classifyTicket(tk({ description: d }), ctx());
  assert.equal(v.class, 'LOCAL-NATIVE');
  assert.match(v.reason, /4 asks/);
});

test('exactly 3 asks is still cloud-eligible', () => {
  const d = 'Asks:\n1. one in scripts/a.sh\n2. two\n3. three';
  assert.equal(classifyTicket(tk({ description: d }), ctx()).class, 'CLOUD-OK');
});

test('LOCAL-NATIVE: run-time need (luna / vault / handover state / qmd query, vector, embed)', () => {
  for (const need of ['It reads the luna vault.', 'It reads the vault notes.', 'It reads handover state.', 'It writes under $HANDOVER_DIR.', 'It runs qmd query -c luna.', 'It calls qmd query -c himmel at run time.', 'It needs qmd vector search.', 'It runs qmd embed.', 'It runs qmd  query twice.', 'It runs /graphify on the docs.', 'It needs a semantic graphify extraction.', 'It runs graphify extract --backend gemini.', 'It runs graphify extract ./docs --backend gemini.', 'It runs qmd search "x" -c salus.', 'It runs qmd search -c himmel -c luna x.', 'It runs qmd get --collection station-ops x.', 'It runs qmd search -c himmel-old x.']) {
    const v = classifyTicket(tk({ description: `Edit scripts/a.sh. ${need}` }), ctx());
    assert.equal(v.class, 'LOCAL-NATIVE', need);
    assert.match(v.reason, /run-time/);
  }
});

// HIMMEL-4969: fixture text of the real tickets (no live Jira).
const T4660 = {
  key: 'HIMMEL-4660', type: 'Task', status: 'To Do', title: 'qmd-quality: backfill baselines into live ledger and arm cadence on a test VM',
  description: 'Follow-up to HIMMEL-4650 (its Ask items 3 live part and 4).\n1. Run scripts/eval/qmd-quality/backfill-ledger.sh on the stored gemma and qwen outputs under ~/.himmel/eval/qmd-index/out/ (and the wiring-proof run) against the LIVE eval-runs ledger. HIMMEL-4650 rehearsed it on scratch copies and a scratch ledger only, so no live ledger row was written.\n2. Arm the qmd-quality cadence on a test VM first (himmel-ops:vm); the station arm stays an operator step.\nBoth need an operator go (live ledger / VM arming), so they were out of the HIMMEL-4650 PR.',
};
const CLOUD_FIXTURES = [
  { key: 'HIMMEL-4639', title: 'test-check-ci: HIMMEL-4630 comment omits case 104 budget exception', description: 'The HIMMEL-4630 comment block in scripts/test-check-ci.sh (near line 1819) says every cap case uses a 4s budget, but case 104 uses --max-wait 6 (with GH_STUB_CAP_SLEEP=8). Add the case-104 exception to the comment. Comment-only change; no behaviour impact.' },
  { key: 'HIMMEL-4665', title: 'lane-quality calibration: collision-free second-judge cache key', description: 'What. scripts/eval/lane-quality/run.sh calibration names a stored second-judge result <stem>.judge2.<label>.json.\nAsk. Make the cache key collision-free.\nDone when. A test shows the two colliding configurations each make their own call.' },
  { key: 'HIMMEL-4673', title: 'trajectory scorer: union test targets across a passing && chain', description: 'scripts/eval/lane-quality/trajectory.py test_target() returns the targets of the first test command in a Bash call only. A passing bash test-a.sh && bash test-b.sh therefore backs a claim about test-a.sh but not test-b.sh.\nAcceptance:\n- A fixture with bash test-a.sh && bash test-b.sh passing scores verify_before_claim true.\n- A failing chain still proves no RED.' },
  { key: 'HIMMEL-4688', title: 'Scrapling YT/X extraction refinements from PR 1982 round 3', description: 'Follow-up from PR #1982.\n1. Unavailable video without videoDetails (codex-2)\nmarketplace/plugins/obsidian-triage/tools/yt-scrapling-meta.py player_response() accepts a ytInitialPlayerResponse only when its videoDetails.videoId matches.\n2. Non-English caption tracks (codex-3)\nfetch_transcript asks yt-dlp for en.*,en only.\n3. Focal-post media after a quoted post (codex-4)\nmarketplace/plugins/obsidian-triage/tools/x-scrapling-media.py main_article() keeps the focal article only up to its first nested article.' },
];

test('LOCAL-NATIVE: station-bound ticket (HIMMEL-4660: ~/.himmel state, live ledger, test VM, cadence arming)', () => {
  const v = classifyTicket(T4660, ctx());
  assert.equal(v.class, 'LOCAL-NATIVE');
  assert.match(v.reason, /run-time/);
});

test('LOCAL-NATIVE: each station-bound shape alone routes local and the reason names the match', () => {
  const cases = [['reads ~/.himmel/eval/out', '~/.himmel/'], ['reads $HOME/.himmel/x', '$HOME/.himmel/'], ['reads ~/.cache/qmd', '~/.cache/'], ['writes the LIVE eval-runs ledger', 'LIVE eval-runs ledger'], ['runs on a test VM', 'test VM'], ['via himmel-ops:vm', 'himmel-ops:vm'], ['uses vmsdk', 'vmsdk'], ['calls VBoxManage', 'VBoxManage'], ['arm the nightly cadence', 'arm the nightly cadence'], ['arming a cadence', 'arming a cadence'], ['a systemd timer fires it', 'systemd timer'], ['runs atrm on the job', 'atrm']];
  for (const [need, match] of cases) {
    const v = classifyTicket(tk({ description: `Edit scripts/a.sh. It ${need}.` }), ctx());
    assert.equal(v.class, 'LOCAL-NATIVE', need);
    assert.ok(v.reason.includes(match), `${need}: ${v.reason}`);
  }
});

test('CLOUD-OK: the tickets launched with HIMMEL-4660 and a passing VM-suite mention stay cloud', () => {
  for (const f of CLOUD_FIXTURES) assert.equal(classifyTicket({ type: 'Task', status: 'To Do', ...f }, ctx()).class, 'CLOUD-OK', f.key);
  for (const t of ['Edit scripts/vm/test-vm-e2e.sh.', 'Fix the cadence field in scripts/a.sh output.', 'It is a live-reload hook in scripts/a.sh.']) assert.equal(classifyTicket(tk({ description: t }), ctx()).class, 'CLOUD-OK', t);
});

test('CLOUD-OK: graphify and repo-only qmd search no longer route local (HIMMEL-4726: the cloud setup installs both)', () => {
  for (const need of ['It runs graphify update.', 'It calls graphify query at run time.', 'It uses qmd search over the repo docs.', 'It reads the skills/graphify/SKILL.md text.', 'It runs qmd search "cloud" -c himmel.', "It runs qmd search -c 'himmel' x."]) {
    const v = classifyTicket(tk({ description: `Edit scripts/a.sh. ${need}` }), ctx());
    assert.equal(v.class, 'CLOUD-OK', need);
  }
});

test('CLOUD-OK: a Jira need no longer routes local (Atlassian MCP is connected in the cloud)', () => {
  const v = classifyTicket(tk({ description: 'Edit scripts/a.sh. It posts a Jira comment and files a Jira issue.' }), ctx());
  assert.equal(v.class, 'CLOUD-OK');
});

test('LOCAL-NATIVE: a trust path (scripts/ci) needs a trust-reviewed GO', () => {
  const v = classifyTicket(tk({ description: 'Edit scripts/ci/run-shell-tests.sh.' }), ctx());
  assert.equal(v.class, 'LOCAL-NATIVE');
  assert.match(v.reason, /trust/);
});

test('HOOK-BYPASS: scripts/hooks/ is never cloud (hooks do not run there)', () => {
  const v = classifyTicket(tk({ description: 'Edit scripts/hooks/block-x.sh.' }), ctx());
  assert.equal(v.class, 'HOOK-BYPASS');
  assert.match(v.reason, /hook/);
});

test('HOOK-BYPASS wins over trust path for scripts/hooks/lib', () => {
  const v = classifyTicket(tk({ description: 'Edit scripts/hooks/lib/shell-tokenize.sh.' }), ctx());
  assert.equal(v.class, 'HOOK-BYPASS');
});

test('BLOCKED: a held file (open PR or console list), file or directory overlap', () => {
  const v = classifyTicket(tk(), ctx({ held: [{ file: 'scripts/lanes/example.sh', why: 'PR 1' }] }));
  assert.equal(v.class, 'BLOCKED');
  assert.match(v.reason, /PR 1/);
  const d = classifyTicket(tk(), ctx({ held: [{ file: 'scripts/lanes/', why: 'live leg' }] }));
  assert.equal(d.class, 'BLOCKED');
});

test('BLOCKED wins over a hook path (one writer per file)', () => {
  const v = classifyTicket(tk({ description: 'Edit scripts/hooks/a.sh.' }), ctx({ held: [{ file: 'scripts/hooks/a.sh', why: 'PR 2' }] }));
  assert.equal(v.class, 'BLOCKED');
});

test('BLOCKED: ticket not To Do (already in flight or done)', () => {
  const v = classifyTicket(tk({ status: 'Done' }), ctx());
  assert.equal(v.class, 'BLOCKED');
});

test('LOCAL-NATIVE: no file named, so no brief can be scoped', () => {
  const v = classifyTicket(tk({ description: 'Make it better.' }), ctx());
  assert.equal(v.class, 'LOCAL-NATIVE');
  assert.match(v.reason, /no file/);
});

test('a dotted spec path is normalized, so it cannot dodge the hook class', () => {
  const v = classifyTicket(tk({ files: ['scripts/lanes/../hooks/x.sh'] }), ctx());
  assert.equal(v.class, 'HOOK-BYPASS');
});

test('bulleted asks under an Asks: header count toward the 3-ask limit', () => {
  const d = 'Asks:\n- one in scripts/a.sh\n- two\n- three\n- four';
  assert.equal(classifyTicket(tk({ description: d }), ctx()).class, 'LOCAL-NATIVE');
});

test('explicit files override text extraction', () => {
  const v = classifyTicket(tk({ description: 'Make it better.', files: ['docs/x.md'] }), ctx());
  assert.equal(v.class, 'CLOUD-OK');
  assert.deepEqual(v.files, ['docs/x.md']);
});

test('brief uses bounded repo-only search and the session checkout graph', () => {
  const brief = buildBrief(tk({ files: ['docs/x.md'], raw: 'ticket' }), { date: '2026-10-07' });
  assert.match(brief, /bash scripts\/lib\/qmd-bounded\.sh search "<terms>" -c himmel/);
  assert.match(brief, /bash scripts\/cloud\/setup-env\.sh/);
  assert.match(brief, /--graph graphify-out\/graph\.json/);
  assert.doesNotMatch(brief, /--graph \/tmp\/himmel-setup/);
});

test('parseJiraGet splits the header and keeps the body verbatim', () => {
  const raw = 'HIMMEL-9001\tBug\tTo Do\tA title\n\nBody line\nLabels: cloud\nFix versions: v1.0.1\n';
  const p = parseJiraGet(raw);
  assert.equal(p.key, 'HIMMEL-9001'); assert.equal(p.type, 'Bug'); assert.equal(p.status, 'To Do'); assert.equal(p.title, 'A title');
  assert.equal(p.raw, raw.trimEnd());
  assert.match(p.description, /Body line/);
});

test('brief does not promise the context7 MCP (HIMMEL-4971: not enabled in a cloud session)', () => {
  const t = { ...parseJiraGet('HIMMEL-9001\tTask\tTo Do\tt\n\nFix versions: v1.0.1'), files: ['a.sh'] };
  const b = buildBrief(t, { date: '2026-10-08' });
  assert.doesNotMatch(b, /Use the context7 MCP for current library docs\./);
  assert.match(b, /If the context7 MCP tools are listed in this session, use them for current library docs; otherwise WebFetch the library's own docs\./);
});

test('brief carries every template section, in order', () => {
  const raw = 'HIMMEL-9001\tTask\tTo Do\ttick relayed results only\n\nFix scripts/lanes/example.sh.\nFix versions: v1.0.1';
  const t = { ...parseJiraGet(raw), files: ['scripts/lanes/example.sh'] };
  const b = buildBrief(t, { consoleId: 'AD', change: 'Do the thing.', date: '2026-10-04', completes: 'yes' });
  const order = [
    'You are working in a cloud clone of the GitHub repo yotamleo/Himmel.',
    'Atlassian MCP connector (the local jira CLI is absent in the cloud)',
    'context7 MCP tools are listed',
    '## Ticket HIMMEL-9001 (verbatim from Jira)',
    raw,
    '## The change',
    'verified against main on 2026-10-04',
    'Do the thing.',
    '## How to do it',
    'Read `CLAUDE.md`',
    'transition HIMMEL-9001 to `In Progress`',
    'git worktree add -b feat/himmel-9001-tick-relayed-results-only .claude/worktrees/himmel-9001 origin/main',
    'Edit ONLY these files: scripts/lanes/example.sh',
    'RED',
    'never amend',
    'scripts/cr/impacted-suites.sh origin/main..HEAD --shell',
    'Platforms tested: linux',
    'Security reviewed: manual',
    'cloud-pilot: HIMMEL-9001 (console AD)',
    'completes-ticket: yes',
    '## Ticket coverage',
    '/autofix-pr',
    'Do NOT merge',
    'CLOUD-DONE',
    'comment on HIMMEL-9001',
    'CLOUD-BLOCKED',
    'print the PR URL, the branch, the commit SHA, and a 3-line summary',
  ];
  let at = -1;
  for (const s of order) {
    const i = b.indexOf(s, at + 1);
    assert.ok(i > at, `missing or out of order: ${s}`);
    at = i;
  }
});

test('launch line is exactly the konsole shape and quotes odd paths', () => {
  assert.equal(launchLine('/b/cloud-brief-HIMMEL-1.md'), 'konsole --separate -e claude --cloud "$(cat /b/cloud-brief-HIMMEL-1.md)" --permission-mode auto');
  assert.match(launchLine('/b dir/x.md'), /cat '\/b dir\/x\.md'/);
});

// ---- CLI end to end with stubbed jira + gh ----
function stub(dir, name, body) {
  const p = join(dir, name);
  writeFileSync(p, `#!/usr/bin/env bash\n${body}\n`);
  chmodSync(p, 0o755);
  return p;
}

function setup() {
  const dir = mkdtempSync(join(tmpdir(), 'cloud-route-'));
  const bucket = join(dir, 'bucket');
  spawnSync('mkdir', ['-p', bucket]);
  const jira = stub(dir, 'jira', `
key="$2"
case "$key" in
  HIMMEL-9001) printf 'HIMMEL-9001\\tTask\\tTo Do\\tsmall fix\\n\\nEdit scripts/lanes/example.sh.\\nFix versions: v1.0.1\\n';;
  HIMMEL-9002) printf 'HIMMEL-9002\\tTask\\tTo Do\\tbig one\\n\\nAsks:\\n1. a scripts/b.sh\\n2. b\\n3. c\\n4. d\\n';;
  HIMMEL-9003) printf 'HIMMEL-9003\\tTask\\tTo Do\\tguard\\n\\nEdit scripts/hooks/x.sh.\\n';;
  HIMMEL-9004) printf 'HIMMEL-9004\\tTask\\tTo Do\\theld\\n\\nEdit scripts/held/file.sh.\\n';;
  *) exit 1;;
esac`);
  const gh = stub(dir, 'gh', `
if [ "$1 $2" = "pr list" ]; then echo 77; exit 0; fi
if [ "$1 $2" = "pr diff" ]; then echo scripts/held/file.sh; exit 0; fi
exit 1`);
  return { dir, bucket, jira, gh };
}

test('CLI: routes four tickets, writes one brief, one launch line, one JSONL record each', () => {
  const { bucket, jira, gh } = setup();
  const r = spawnSync(process.execPath, [CLI, '--bucket', bucket, '--console', 'AD', 'HIMMEL-9001', 'HIMMEL-9002', 'HIMMEL-9003', 'HIMMEL-9004'], {
    encoding: 'utf8', env: { ...process.env, CLOUD_ROUTE_JIRA_CMD: jira, CLOUD_ROUTE_GH_CMD: gh },
  });
  assert.equal(r.status, 0, r.stderr);
  const brief = join(bucket, 'cloud-brief-HIMMEL-9001.md');
  assert.ok(existsSync(brief));
  for (const k of ['9002', '9003', '9004']) assert.ok(!existsSync(join(bucket, `cloud-brief-HIMMEL-${k}.md`)), k);
  const launches = r.stdout.split('\n').filter((l) => l.startsWith('konsole '));
  assert.deepEqual(launches, [`konsole --separate -e claude --cloud "$(cat ${brief})" --permission-mode auto`]);
  const recs = readFileSync(join(bucket, 'cloud-route.jsonl'), 'utf8').trim().split('\n').map((l) => JSON.parse(l));
  assert.deepEqual(recs.map((x) => [x.ticket, x.class]), [
    ['HIMMEL-9001', 'CLOUD-OK'], ['HIMMEL-9002', 'LOCAL-NATIVE'], ['HIMMEL-9003', 'HOOK-BYPASS'], ['HIMMEL-9004', 'BLOCKED'],
  ]);
  assert.equal(recs[0].brief, brief);
  assert.equal(recs[1].brief, null);
  for (const x of recs) { assert.ok(x.reason); assert.ok(!Number.isNaN(Date.parse(x.time))); }
  assert.match(readFileSync(brief, 'utf8'), /cloud-pilot: HIMMEL-9001 \(console AD\)/);
});

test('CLI: a CLOUD-OK ticket holds its files, so a second ticket on them is BLOCKED', () => {
  const { bucket, jira, gh } = setup();
  const r = spawnSync(process.execPath, [CLI, '--classify-only', '--bucket', bucket, '--console', 'AD', 'HIMMEL-9001', 'HIMMEL-9001'], {
    encoding: 'utf8', env: { ...process.env, CLOUD_ROUTE_JIRA_CMD: jira, CLOUD_ROUTE_GH_CMD: gh },
  });
  assert.equal(r.status, 0, r.stderr);
  assert.deepEqual(r.stdout.split('\n').filter(Boolean).map((l) => l.split('\t')[1]), ['CLOUD-OK', 'BLOCKED']);
});

test('CLI: --held file blocks without gh, and --classify-only writes nothing', () => {
  const { dir, bucket, jira } = setup();
  const held = join(dir, 'held.txt');
  writeFileSync(held, 'scripts/lanes/example.sh\n');
  const noGh = stub(dir, 'gh2', 'echo "gh unavailable" >&2; exit 1');
  const r = spawnSync(process.execPath, [CLI, '--bucket', bucket, '--console', 'AD', '--held', held, '--classify-only', 'HIMMEL-9001'], {
    encoding: 'utf8', env: { ...process.env, CLOUD_ROUTE_JIRA_CMD: jira, CLOUD_ROUTE_GH_CMD: noGh },
  });
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /HIMMEL-9001\s+BLOCKED/);
  assert.ok(!existsSync(join(bucket, 'cloud-route.jsonl')));
});

// HIMMEL-4996: fixture text of the real tickets (no live Jira).
const STATE_SPEC = 'Spec, threat model, token budget and plan: state repo handovers/yotamleo/himmel/specs/HIMMEL-4818/.';
const T4827 = { key: 'HIMMEL-4827', type: 'Task', status: 'To Do', title: 'himmel-bus T4: MCP server', description: `Add the server in scripts/bus/server.mjs.\n${STATE_SPEC}` };
const T4836 = { key: 'HIMMEL-4836', type: 'Task', status: 'To Do', title: 'himmel-bus T13: docs', description: `Document it in docs/internals/bus.md.\n${STATE_SPEC}` };

test('LOCAL-NATIVE: a ticket that cites the state-repo spec (HIMMEL-4827, HIMMEL-4836)', () => {
  for (const t of [T4827, T4836]) {
    const v = classifyTicket(t, ctx());
    assert.equal(v.class, 'LOCAL-NATIVE', t.key);
    assert.match(v.reason, /run-time/);
  }
});

test('LOCAL-NATIVE: each state-repo reference alone routes local', () => {
  for (const need of ['See the state repo for the plan.', 'Plan is in the state-repo.', 'Read handovers/yotamleo/himmel/x.md.', 'Spec at specs/HIMMEL-4818/plan.md.', 'Read /home/u/state/handovers/yotamleo/himmel/specs/HIMMEL-4818/plan.md.']) {
    assert.equal(classifyTicket(tk({ description: `Edit scripts/a.sh. ${need}` }), ctx()).class, 'LOCAL-NATIVE', need);
  }
});

test('CLOUD-OK: repo paths that merely resemble handover state stay cloud', () => {
  for (const t of ['Edit scripts/handover/console-kit/tick.sh.', 'Edit docs/handover/overnight-mode.md.', 'Edit scripts/a.sh and scripts/lanes/specs/foo.sh.']) assert.equal(classifyTicket(tk({ description: t }), ctx()).class, 'CLOUD-OK', t);
});
