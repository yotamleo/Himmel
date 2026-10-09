// HIMMEL-4985: launcher fixtures. Dummy key and a stub claude only: no provider
// call, no real credential. Breaks caught: native-bank coupling, A/B fallback,
// credential/selector mismatch, provider-flag precedence, key leakage to
// non-API children, lost source metadata, settling unverified cost.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const LAUNCH = join(HERE, 'claude-api.sh');
const STRIP = join(HERE, 'strip-env.sh');
const STATE = join(HERE, '..', 'lib', 'api-credit-state.mjs');
const T = mkdtempSync(join(tmpdir(), 'claude-api-'));
process.on('exit', () => rmSync(T, { recursive: true, force: true }));
const DUMMY = 'sk-ant-dummy-not-a-real-key-0000';

const STUB = `#!/bin/bash
echo called >> "$STUB_LOG"
{ echo "key_present=$([ -n "\${ANTHROPIC_API_KEY:-}" ] && echo 1 || echo 0)"
  echo "base_url=\${ANTHROPIC_BASE_URL:-}"; echo "oauth=\${CLAUDE_CODE_OAUTH_TOKEN:-}"
  echo "use_bedrock=\${CLAUDE_CODE_USE_BEDROCK:-}"; echo "auth_token=\${ANTHROPIC_AUTH_TOKEN:-}"
  echo "lq_api=$(env | grep -c '^LQ_API_')"
  echo "lane_on=\${HIMMEL_API_LANE:-}"; echo "scrub=\${CLAUDE_CODE_SUBPROCESS_ENV_SCRUB:-}"
  echo "args=$*"; } > "$STUB_ENV"
printf '%s' "$STUB_OUT"
`;

function fixture() {
  const dir = mkdtempSync(join(T, 'case-'));
  const now = Math.floor(Date.now() / 1000);
  const state = join(dir, 'ledger.json');
  const config = { version: 1, ledger_path: state, accounts: {
    A: { organization_id: 'org-a', cycle_id: 'cycle-a', cap_usd: '1.00', key_id: 'key-a' },
    B: { organization_id: 'org-b', cycle_id: 'cycle-b', cap_usd: '2.00', key_id: 'key-b' },
  } };
  const snapshot = { version: 1, accounts: Object.fromEntries(['A', 'B'].map((account) => [account, {
    organization_id: config.accounts[account].organization_id, cycle_id: config.accounts[account].cycle_id,
    grant_usd: '2.00', remaining_usd: '2.00', reconciled_spent_usd: '0',
    starts_at: now - 1000, expires_at: now + 3600, observed_at: now,
    source: 'operator-console-snapshot', exclusive_org: true, discrepancy: false,
  }])) };
  const paths = { config: join(dir, 'config.json'), snapshot: join(dir, 'snapshot.json'), state,
    stub: join(dir, 'claude-stub'), log: join(dir, 'stub.log'), env: join(dir, 'stub.env'), ps: join(dir, 'ps') };
  const save = () => {
    writeFileSync(paths.config, JSON.stringify(config));
    writeFileSync(paths.snapshot, JSON.stringify(snapshot));
  };
  save();
  writeFileSync(paths.stub, STUB, { mode: 0o700 });
  writeFileSync(paths.ps, '#!/bin/bash\nexit 0\n', { mode: 0o700 });
  const ok = JSON.stringify({ type: 'result', is_error: false, total_cost_usd: 0.012345, result: 'hi' });
  const env = { PATH: process.env.PATH, HOME: dir, TMPDIR: dir,
    HIMMEL_API_CREDIT_CONFIG: paths.config, HIMMEL_API_CREDIT_SNAPSHOT: paths.snapshot,
    HIMMEL_API_CREDIT_STATE: state, HIMMEL_API_LANE: 'on', HIMMEL_API_ACCOUNT: 'A',
    HIMMEL_API_KEY_ID: 'key-a', ANTHROPIC_API_KEY: DUMMY, HIMMEL_API_CLAUDE_BIN: paths.stub,
    HIMMEL_API_JOB_ID: 'job-1', STUB_LOG: paths.log, STUB_ENV: paths.env, STUB_OUT: ok,
    HIMMEL_FLEET_CAP: '4', HIMMEL_FLEET_SLOTS: join(dir, 'slots'), FLEET_PS_CMD: paths.ps, FLEET_PROC: dir,
    CADENCE_BANK_LEDGER: join(dir, 'bank-ledger'), CADENCE_BANK_SKIP_REFRESH: '1',
    CADENCE_BANK_CACHE: join(dir, 'native-cache.json') };
  writeFileSync(env.CADENCE_BANK_CACHE, JSON.stringify({ five_hour: { utilization: 100 }, seven_day: { utilization: 100 } }));
  const good = ['-p', 'say hi', '--model', 'claude-haiku-5-5', '--permission-mode', 'plan', '--max-budget-usd', '0.10'];
  const run = (args = good, extra = {}) => spawnSync('bash', [LAUNCH, ...args], { env: { ...env, ...extra }, encoding: 'utf8' });
  const status = (account = 'A') => {
    const r = spawnSync(process.execPath, [STATE, 'status'], { env: { ...env, HIMMEL_API_ACCOUNT: account }, encoding: 'utf8' });
    return JSON.parse(r.stdout);
  };
  const called = () => existsSync(paths.log);
  const record = () => readFileSync(join(dir, 'launches.jsonl'), 'utf8');
  return { dir, config, snapshot, paths, save, env, good, run, status, called, record };
}

test('funded API account proceeds while the native bank is exhausted; child sees an isolated env', () => {
  const f = fixture();
  const r = f.run(f.good, { CLAUDE_CODE_OAUTH_TOKEN: 'oauth-dummy', ANTHROPIC_BASE_URL: 'https://evil.example' });
  assert.equal(r.status, 0, r.stderr);
  const seen = readFileSync(f.paths.env, 'utf8');
  assert.match(seen, /^key_present=1$/m);
  assert.match(seen, /^base_url=https:\/\/api\.anthropic\.com$/m);
  assert.match(seen, /^oauth=$/m);
  assert.match(seen, /^lane_on=$/m);
  assert.match(seen, /^scrub=1$/m);
  assert.match(seen, /--max-budget-usd 0\.10/);
  assert.match(seen, /--output-format json/);
  const row = f.status();
  assert.equal(row.reserved_usd, '0.000000');
  assert.equal(row.spent_est_usd, '0.012345');
});

test('judge j2229c: the harness hand-off names (LQ_API_*) never reach claude', () => {
  const f = fixture();
  const r = f.run(f.good, { LQ_API_KEY: DUMMY, LQ_API_ACCOUNT: 'B', LQ_API_KEY_ID: 'key-b', LQ_API_LANE: 'on' });
  assert.equal(r.status, 0, r.stderr);
  assert.match(readFileSync(f.paths.env, 'utf8'), /^lq_api=0$/m);
});

test('HIMMEL-5073: the scrub forces default permission mode, so the launcher declares the tools the fixtures need', () => {
  const f = fixture();
  assert.equal(f.run().status, 0);
  const seen = readFileSync(f.paths.env, 'utf8');
  assert.match(seen, /--allowedTools Read,Edit,Write,Glob,Grep,Bash/);
  assert.match(seen, /--tools Read,Edit,Write,Glob,Grep,Bash/);
  assert.match(seen, /--permission-mode plan/);
});

test('source metadata is preserved in the secret-free launch record', () => {
  const f = fixture();
  assert.equal(f.run().status, 0);
  const rec = JSON.parse(f.record().trim());
  assert.equal(rec.source, 'operator-console-snapshot');
  assert.deepEqual([rec.account, rec.organization_id, rec.key_id, rec.cycle_id, rec.model, rec.outcome],
    ['A', 'org-a', 'key-a', 'cycle-a', 'claude-haiku-5-5', 'settled']);
  for (const text of [f.record(), readFileSync(f.paths.state, 'utf8')]) assert.ok(!text.includes(DUMMY));
});

test('empty API account refuses even though native is funded, and never spawns claude', () => {
  const f = fixture();
  f.snapshot.accounts.A.remaining_usd = '0';
  f.save();
  writeFileSync(f.env.CADENCE_BANK_CACHE, JSON.stringify({ five_hour: { utilization: 1 }, seven_day: { utilization: 1 } }));
  const r = f.run();
  assert.equal(r.status, 2);
  assert.match(r.stderr, /api bank gate said SKIPPED-BANK/);
  assert.equal(f.called(), false);
});

test('no automatic A/B rotation: empty A refuses and B stays untouched', () => {
  const f = fixture();
  f.snapshot.accounts.A.remaining_usd = '0';
  f.save();
  assert.equal(f.run().status, 2);
  assert.equal(f.called(), false);
  assert.equal(f.status('B').reserved_usd, '0.000000');
  assert.equal(f.status('B').spent_est_usd, '0.000000');
});

test('absent key and selector/credential mismatch refuse before any spawn', () => {
  const f = fixture();
  const absent = f.run(f.good, { ANTHROPIC_API_KEY: '' });
  assert.equal(absent.status, 2);
  assert.match(absent.stderr, /ANTHROPIC_API_KEY is absent/);
  const mismatch = f.run(f.good, { HIMMEL_API_KEY_ID: 'key-b' });
  assert.equal(mismatch.status, 2);
  assert.match(mismatch.stderr, /key id does not match account A/);
  const noId = f.run(f.good, { HIMMEL_API_KEY_ID: '' });
  assert.equal(noId.status, 2);
  assert.equal(f.called(), false);
  assert.equal(f.status().reserved_usd, '0.000000');
});

for (const [name, extra, pattern] of [
  ['bedrock flag', { CLAUDE_CODE_USE_BEDROCK: '1' }, /conflicting provider flag CLAUDE_CODE_USE_BEDROCK/],
  ['vertex flag', { CLAUDE_CODE_USE_VERTEX: '1' }, /conflicting provider flag CLAUDE_CODE_USE_VERTEX/],
  ['auth token', { ANTHROPIC_AUTH_TOKEN: 'tok-dummy' }, /conflicting provider ANTHROPIC_AUTH_TOKEN/],
  ['openrouter lane', { HIMMEL_CLAUDE_LANE: 'openrouter' }, /conflicting lane/],
  ['claudex lane', { HIMMEL_CLAUDE_LANE: 'claudex' }, /conflicting lane/],
]) {
  test(`conflicting provider (${name}) refuses`, () => {
    const f = fixture();
    const r = f.run(f.good, extra);
    assert.equal(r.status, 2);
    assert.match(r.stderr, pattern);
    assert.equal(f.called(), false);
  });
}

test('lane is OFF without the opt-in and invalid accounts refuse', () => {
  const f = fixture();
  assert.match(f.run(f.good, { HIMMEL_API_LANE: '' }).stderr, /api lane is OFF/);
  assert.match(f.run(f.good, { HIMMEL_API_ACCOUNT: 'C' }).stderr, /must be A or B/);
  assert.match(f.run(f.good, { HIMMEL_API_ACCOUNT: '' }).stderr, /must be A or B/);
  assert.equal(f.called(), false);
});

test('argument policy: print only, no bg/cloud/bypass, explicit mode, model and budget', () => {
  const f = fixture();
  const cases = [
    [['say hi', '--model', 'm', '--permission-mode', 'plan', '--max-budget-usd', '1'], /only -p/],
    [[...f.good, '--bg'], /not allowed/],
    [[...f.good, '--cloud'], /not allowed/],
    [[...f.good, '--dangerously-skip-permissions'], /not allowed/],
    [['-p', 'x', '--model', 'm', '--permission-mode', 'bypassPermissions', '--max-budget-usd', '1'], /bypassPermissions/],
    [['-p', 'x', '--model', 'm', '--max-budget-usd', '1'], /--permission-mode is required/],
    [['-p', 'x', '--permission-mode', 'plan', '--max-budget-usd', '1'], /--model is required/],
    [['-p', 'x', '--model', 'm', '--permission-mode', 'plan'], /--max-budget-usd is required/],
    [[...f.good, '--output-format', 'text'], /must be json/],
  ];
  for (const [args, pattern] of cases) {
    const r = f.run(args);
    assert.equal(r.status, 2, args.join(' '));
    assert.match(r.stderr, pattern);
  }
  assert.equal(f.called(), false);
  assert.equal(f.status().reserved_usd, '0.000000');
});

test('unverified completion keeps the full reservation as unknown', () => {
  const f = fixture();
  const r = f.run(f.good, { STUB_OUT: 'not json' });
  assert.equal(r.status, 0);
  assert.equal(f.status().reserved_usd, '0.100000');
  assert.equal(JSON.parse(f.record().trim()).outcome, 'unknown');
  const error = fixture();
  error.run(error.good, { STUB_OUT: JSON.stringify({ type: 'result', is_error: true, total_cost_usd: 0.01 }) });
  assert.equal(error.status().reserved_usd, '0.100000');
});

test('judge: bypass flags in any spelling and caller-supplied tool/settings/mcp flags are refused', () => {
  const f = fixture();
  const flags = ['--dangerously-skip-permissions=true', '--dangerously-skip-permissions=anything', '--allow-dangerously-skip-permissions=false',
    '--allowedTools', '--allowedTools=Bash', '--allowed-tools', '--allowed-tools=Bash', '--settings', '--settings={}', '--mcp-config', '--mcp-config=x.json',
    '--Dangerously-Skip-Permissions=true', '--dangerously_skip_permissions', '--ALLOWEDTOOLS=Bash', '--allowed_tools', '--MCP_CONFIG',
    '--tools', '--tools=Bash', '--TOOLS=Bash',
    '--plugin-dir', '--plugin-dir=x', '--plugin_dir', '--add-dir', '--add-dir=x', '@args.txt',
    '--plugin-url', '--plugin-url=x', '--environment', '--environment=x', '--remote-control', '--remote_control',
    '--agent', '--agent=x', '--agents', '--agents={}'];
  for (const flag of flags) {
    const r = f.run([...f.good, flag, ...(flag.includes('=') ? [] : ['x'])]);
    assert.equal(r.status, 2, flag);
    assert.match(r.stderr, /not allowed/, flag);
  }
  assert.equal(f.called(), false);
  assert.equal(f.status().reserved_usd, '0.000000');
});

test('HIMMEL-5093: only allowlisted caller flags pass; an unknown, attached or clustered flag is refused with no spawn or reservation', () => {
  const f = fixture();
  const flags = ['--some-future-flag', '--some-future-flag=1', '--SOME_FUTURE_FLAG', '-x', '-pc', '-pp', '-c', '-r', '-', '--print=x',
    '--resume', '--continue', '--fork-session', '--system-prompt', '--append-system-prompt', '--disallowedTools', '--strict-mcp-config',
    '--setting-sources', '--betas', '--fallback-model', '--debug-file', '--ide', '--chrome', '--teleport', '--session-id', '--MODEL=x', '--Effort'];
  for (const flag of flags) {
    const r = f.run([...f.good, flag, ...(flag.includes('=') ? [] : ['x'])]);
    assert.equal(r.status, 2, flag);
    assert.match(r.stderr, /not allowed/, flag);
  }
  assert.equal(f.called(), false);
  assert.equal(f.status().reserved_usd, '0.000000');
});

test('HIMMEL-5093: --effort, in both spellings, and the positional prompt still pass', () => {
  for (const [spelled, seen] of [[['--effort', 'high'], /--effort high/], [['--effort=low'], /--effort low/]]) {
    const ok = fixture();
    assert.equal(ok.run([...ok.good, ...spelled]).status, 0);
    assert.match(readFileSync(ok.paths.env, 'utf8'), seen);
  }
  const f = fixture();
  for (const bad of [['--effort'], ['--effort', '--settings'], ['--effort=a b']]) {
    const r = f.run([...f.good, ...bad]);
    assert.equal(r.status, 2, bad.join(' '));
  }
});

test('HIMMEL-5097: --model and --permission-mode refuse dash-led values and the mode is an allowlist, in both spellings', () => {
  const f = fixture();
  const without = (flag) => f.good.filter((_, i, a) => a[i] !== flag && a[i - 1] !== flag);
  const cases = [
    [['--model', '--anything'], /--model/], [['--model=--anything'], /--model/], [['--model', '-x'], /--model/],
    [['--permission-mode', '--dangerously-skip-permissions'], /permission mode/], [['--permission-mode=-x'], /permission mode/],
    [['--permission-mode', 'BypassPermissions'], /permission mode/], [['--permission-mode=BYPASSPERMISSIONS'], /permission mode/],
    [['--permission-mode', 'bypass_permissions'], /permission mode/], [['--permission-mode', 'nonsense'], /permission mode/],
  ];
  for (const [flag, re] of cases) {
    const r = f.run([...without(flag[0].split('=')[0]), ...flag]);
    assert.equal(r.status, 2, flag.join(' '));
    assert.match(r.stderr, re, flag.join(' '));
  }
  assert.equal(f.called(), false);
  assert.equal(f.status().reserved_usd, '0.000000');
  for (const mode of ['default', 'plan', 'acceptEdits', 'dontAsk', 'auto']) {
    const ok = fixture();
    assert.equal(ok.run([...without('--permission-mode'), `--permission-mode=${mode}`]).status, 0, mode);
  }
});

test('HIMMEL-5097: the exact argv shape scripts/eval/lane-quality/run.sh sends still passes', () => {
  const f = fixture();
  const r = f.run(['-p', 'do the task', '--model', 'claude-haiku-5-5', '--permission-mode', 'auto', '--output-format', 'json',
    '--max-budget-usd', '0.10', '--effort', 'high']);
  assert.equal(r.status, 0, r.stderr);
  assert.match(readFileSync(f.paths.env, 'utf8'), /--permission-mode auto/);
});

test('an argument terminator is refused so the enforced options stay options', () => {
  const f = fixture();
  const r = f.run(['-p', '--', 'x', '--model', 'm', '--permission-mode', 'plan', '--max-budget-usd', '0.10']);
  assert.equal(r.status, 2);
  assert.match(r.stderr, /argument terminator/);
  assert.equal(f.called(), false);
});

test('a cost above the reservation is recorded as overrun, never as settled', () => {
  const f = fixture();
  const r = f.run(f.good, { STUB_OUT: JSON.stringify({ type: 'result', is_error: false, total_cost_usd: 0.5 }) });
  assert.equal(r.status, 0);
  assert.match(r.stderr, /exceeded the reservation/);
  assert.equal(JSON.parse(f.record().trim()).outcome, 'overrun');
});

test('model and job id with JSON-unsafe characters refuse before any spawn', () => {
  const f = fixture();
  const bad = f.run(['-p', 'x', '--model', 'm"x', '--permission-mode', 'plan', '--max-budget-usd', '0.10']);
  assert.equal(bad.status, 2);
  assert.match(bad.stderr, /--model has characters/);
  const job = f.run(f.good, { HIMMEL_API_JOB_ID: 'j"1' });
  assert.equal(job.status, 2);
  assert.match(job.stderr, /job id has characters/);
  assert.equal(f.called(), false);
  assert.equal(existsSync(join(f.dir, 'launches.jsonl')), false);
});

test('a budget above the available credit refuses at reservation', () => {
  const f = fixture();
  const r = f.run(['-p', 'x', '--model', 'm', '--permission-mode', 'plan', '--max-budget-usd', '5.00']);
  assert.equal(r.status, 2);
  assert.match(r.stderr, /reservation refused|bank gate/);
  assert.equal(f.called(), false);
});

test('a non-API child is stripped of the key and every lane selector', () => {
  const f = fixture();
  const r = spawnSync('bash', [STRIP, '--', 'env'], { env: { ...f.env, HIMMEL_API_CREDIT_FORMAT: 'bank' }, encoding: 'utf8' });
  assert.equal(r.status, 0, r.stderr);
  assert.ok(!r.stdout.includes('ANTHROPIC_API_KEY'));
  assert.ok(!r.stdout.includes(DUMMY));
  assert.ok(!/^HIMMEL_API_/m.test(r.stdout));
  const lq = spawnSync('bash', [STRIP, '--', 'env'], { env: { ...f.env, LQ_API_KEY: DUMMY, LQ_API_ACCOUNT: 'B', LQ_API_KEY_ID: 'k', LQ_API_LANE: 'on' }, encoding: 'utf8' });
  assert.ok(!/^LQ_API_/m.test(lq.stdout), 'LQ_API_* survived strip-env');
  assert.match(r.stdout, /^PATH=/m);
});
