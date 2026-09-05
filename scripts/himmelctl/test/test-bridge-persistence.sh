#!/usr/bin/env bash
# test-bridge-persistence.sh — hermetic coverage for
# scripts/himmelctl/lib/bridge-persistence.js (HIMMEL-2176 Task 9).
# Stubs systemctl/loginctl via a PATH shim directory — NEVER invokes the real
# ones, never touches a real ~/.config/systemd/user.
#
# Covers: install/uninstall round-trip with dryRun (exact action list,
# including the @HIMMEL_REPO@ substitution named in the dry-run detail); the
# non-Linux graceful path (systemctl/loginctl genuinely absent from PATH);
# and, best-effort, the read-only probes (lingerEnabled/systemdUnitInstalled)
# against a real stub — DYNAMICALLY: the stub logs every invocation it
# actually receives, and the Node assertions below check that log to decide
# whether a real spawn happened before asserting on its stdout-parsing
# outcome, SKIPping (never faking a pass) when it didn't. On this repo's
# Windows Git Bash dev host it genuinely can't: Node 24 refuses to
# spawnSync() a .bat/.cmd without shell:true (CVE-2024-27980), and a bare
# extensionless file is not CreateProcess-able at all — so a placeholder
# `systemctl`/`loginctl` satisfies `which()`'s PATH-presence check (proving
# the "found" branch, not the "absent" branch, is taken) but the actual
# spawn ENOENTs, same as it would if genuinely absent. On real Linux this
# exact same stub is a real, executable script and the full parsing
# assertions run for real, with no SKIP.
#
# Also covers (CR round 1): the codex-5 fix — uninstallSystemdUnit() must
# refuse to remove the unit file when `disable --now` fails, never report
# ok:true regardless. That case needs no SKIP anywhere: a stub-forced
# non-zero exit (Linux) and a genuinely unspawnable stub (Windows, status
# null) both hit the same "disable did not succeed" branch. And the two new
# Windows persistence primitives (installWindowsLogonTask /
# uninstallWindowsLogonTask): dryRun action lists run everywhere; the real
# non-Windows graceful path is exercised for real only where
# process.platform !== 'win32' (WSL/Linux) — never attempted on the real
# Windows dev host, where it would genuinely spawn pwsh and register a real
# scheduled task (SKIP there instead, honestly named).
#
# CR round 5: codex-1 — an absent unit file alone is never proof of
# uninstall; is-enabled/is-active must ALSO give a CONFIRMED negative (never
# an inconclusive spawn error) before the no-op shortcut fires. The
# "shortcut did not fire" assertion runs unconditionally on both platforms
# (an inconclusive probe can never confirm the negative, so Windows's own
# unspawnable stub correctly never takes the shortcut either); confirming
# the fall-through actually reached a REAL disable call needs the stub log,
# so that one sub-assertion SKIPs on Windows same as every other
# spawn-dependent case here. codex-2 — a failed `enable --now` that left
# the unit stuck enabled reports that partial state (+ remediation) rather
# than a flat failure.
#
# CR round 10: codex-1 — generalizes round 5's partial-state honesty to
# EVERY install failure after the first durable side effect (file written
# -> reload -> enable -> start), not just the enable/start split: a
# daemon-reload failure, and an outright (not just stuck-enabled) enable
# failure, both now report `partial:true` too. codex-2 — the Windows
# logon-task primitives take an injectable `spawnFn` (default the real
# spawnSync); this repo's own Windows dev host reports process.platform
# 'win32' too, so injecting a fake spawn genuinely exercises the win32
# branch's pwsh argv construction for real, verified with NO process ever
# spawned — closing the "unverified on the primary platform" gap without
# registering a real scheduled task.
#
# CR round 11: codex-1 — closes the sibling gap round 10 named but didn't
# fix: uninstallSystemdUnit() now carries the SAME `partial:true` contract
# as install, shared via one `partialFail()` helper. Its durable-side-effect
# boundary is `disable --now` succeeding (not the file write) — a genuine
# disable failure stays a flat ok:false (nothing of ours landed yet); a
# later remove/reload failure after disable succeeds is partial:true.
#
# CR round 12: codex-1, third pass on the same absent-file shortcut — round
# 3 introduced it, round 5 required a confirmed negative from is-enabled/
# is-active, and this closes the gap THAT confirmation still had: both
# probes exit non-zero identically for "systemd never heard of this" and
# "systemd knows it fine, it's merely disabled/stopped" — so a stale LOADED
# definition could take the shortcut, skip the required daemon-reload, and
# report itself fully uninstalled. Replaced with a single
# `systemctl --user show <unit> --property=LoadState` probe, which actually
# distinguishes not-found from loaded/masked; the round-5
# inconclusive-is-not-negative rule carries over unchanged.
#
# CR round 13: codex-1 — repoRoot is now escaped before rendering into the
# systemd unit: `%` doubled (systemd's specifier-prefix escape, verified
# live against systemd 255 to otherwise crash the unit at start), and every
# Environment=/ExecStart=/ExecStop= occurrence quote-escaped and wrapped in
# literal double quotes (those directives tokenize their line; an unquoted
# space split one argument into several, verified live). WorkingDirectory=
# deliberately stays UNQUOTED — verified live that it takes the raw
# rest-of-line with no tokenization, and that literal quote characters
# there are REJECTED, not stripped. Not covered, named rather than silent:
# control characters and systemd's own unit-file line-length limits — a
# checkout path is operator-chosen, not attacker input.
#
# CR round 14: codex-1 — a repoRoot carrying CR/LF is now REFUSED outright
# (ok:false, no write, before dryRun even), never escaped: unlike `%`/space/
# quote/backslash, a newline has no correct in-directive rendering — it
# creates an ADDITIONAL unit directive, not a corrupted string. NUL is
# untested (structurally impossible in a real path) and other control
# characters stay an accepted, named residual.
set -uo pipefail

WORK=$(mktemp -d "${TMPDIR:-/tmp}/bridge-persistence-test.XXXXXX") || exit 1
[ -n "$WORK" ] || exit 1
trap 'rm -rf "$WORK"' EXIT

# to_node_path <path> — every path handed to `node` (as a require() arg or an
# env var it later fs.*/path.joins) must be Windows-native on Windows: MSYS
# `mktemp`/`pwd` output (/c/Users/...) is NOT resolvable by node's own module
# loader or fs calls on native Windows Node, even though bash itself accepts
# it fine (MODULE_NOT_FOUND / silently-wrong fs paths otherwise). `cygpath -m`
# (Git Bash) gives a mixed forward-slash Windows path node accepts; a no-op
# pass-through on real POSIX hosts, where cygpath doesn't exist and isn't
# needed.
to_node_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

REPO_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
LIB="$REPO_ROOT/scripts/himmelctl/lib/bridge-persistence.js"
LIB_NODE=$(to_node_path "$LIB")
[ -f "$LIB" ] || { echo "FAIL: $LIB not found" >&2; exit 1; }

REQUIRE_ERR=$(node -e "require('$LIB_NODE')" 2>&1) || {
  echo "FAIL: $LIB does not load cleanly under node -e require() -- $REQUIRE_ERR" >&2
  exit 1
}

UNIT_DIR="$WORK/unitdir"
EMPTY_DIR="$WORK/emptybin"
STUB_DIR="$WORK/stubbin"
STUB_STATE="$WORK/stub-state"
STUB_LOG="$WORK/stub.log"
mkdir -p "$UNIT_DIR" "$EMPTY_DIR" "$STUB_DIR" "$STUB_STATE"

cat > "$STUB_DIR/systemctl" <<'EOF'
#!/usr/bin/env bash
: "${BRIDGE_PERSISTENCE_STUB_LOG:?}"
echo "systemctl $*" >> "$BRIDGE_PERSISTENCE_STUB_LOG"
case "$*" in
  "--user daemon-reload")
    if [ -f "${BRIDGE_PERSISTENCE_STUB_STATE:?}/reload-fail" ]; then exit 9; else exit 0; fi
    ;;
  "--user enable --now telegram-bridge.service")
    if [ -f "${BRIDGE_PERSISTENCE_STUB_STATE:?}/enable-now-fail" ]; then exit 7; else exit 0; fi
    ;;
  "--user disable --now telegram-bridge.service")
    if [ -f "${BRIDGE_PERSISTENCE_STUB_STATE:?}/disable-fail" ]; then exit 5; else exit 0; fi
    ;;
  "--user is-enabled telegram-bridge.service")
    if [ -f "${BRIDGE_PERSISTENCE_STUB_STATE:?}/enabled" ]; then echo enabled; exit 0; else echo disabled; exit 1; fi
    ;;
  "--user is-active telegram-bridge.service")
    if [ -f "${BRIDGE_PERSISTENCE_STUB_STATE:?}/active" ]; then echo active; exit 0; else echo inactive; exit 3; fi
    ;;
  "--user show telegram-bridge.service --property=LoadState")
    if [ -f "${BRIDGE_PERSISTENCE_STUB_STATE:?}/loadstate-loaded" ]; then echo "LoadState=loaded"; else echo "LoadState=not-found"; fi
    exit 0
    ;;
  *) exit 0 ;;
esac
EOF
cat > "$STUB_DIR/loginctl" <<'EOF'
#!/usr/bin/env bash
: "${BRIDGE_PERSISTENCE_STUB_LOG:?}"
echo "loginctl $*" >> "$BRIDGE_PERSISTENCE_STUB_LOG"
case "$*" in
  "enable-linger "*) exit 0 ;;
  *"--property=Linger")
    if [ -f "${BRIDGE_PERSISTENCE_STUB_STATE:?}/linger-yes" ]; then echo "Linger=yes"; exit 0
    elif [ -f "${BRIDGE_PERSISTENCE_STUB_STATE:?}/linger-no" ]; then echo "Linger=no"; exit 0
    else exit 3; fi
    ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$STUB_DIR/systemctl" "$STUB_DIR/loginctl"

cat > "$WORK/check.js" <<'EOF_JS'
'use strict';
const fs = require('fs');
const path = require('path');

const LIB = process.env.BRIDGE_TEST_LIB;
const REPO_FIXTURE = process.env.BRIDGE_TEST_REPO_FIXTURE;
const UNIT_DIR = process.env.BRIDGE_TEST_UNIT_DIR;
const EMPTY_DIR = process.env.BRIDGE_TEST_EMPTY_DIR;
const STUB_DIR = process.env.BRIDGE_TEST_STUB_DIR;
const STUB_LOG = process.env.BRIDGE_TEST_STUB_LOG;
const STUB_STATE = process.env.BRIDGE_TEST_STUB_STATE;
// Captured BEFORE any case below mutates process.env.PATH — the "stub
// present" case's shim must prepend onto the REAL PATH (so the stub's own
// `#!/usr/bin/env bash` shebang can still resolve `bash`), never onto
// whatever an earlier case already overwrote process.env.PATH to.
const REAL_PATH = process.env.PATH || '';

let PASS = 0, FAIL = 0, SKIP = 0;
function pass(name) { console.log('PASS ' + name); PASS++; }
function fail(name, detail) { console.error('FAIL ' + name + ' -- ' + detail); FAIL++; }
function skip(name, detail) { console.error('SKIP ' + name + ' -- ' + detail); SKIP++; }
function check(name, expected, actual) {
  const e = JSON.stringify(expected), a = JSON.stringify(actual);
  if (e === a) pass(name); else fail(name, `expected ${e}, got ${a}`);
}
function stubLogHas(needle) {
  if (!fs.existsSync(STUB_LOG)) return false;
  return fs.readFileSync(STUB_LOG, 'utf8').indexOf(needle) !== -1;
}
function stubLogCount(needle) {
  if (!fs.existsSync(STUB_LOG)) return 0;
  return fs.readFileSync(STUB_LOG, 'utf8').split('\n').filter((l) => l.indexOf(needle) !== -1).length;
}

const m = require(LIB);
const unitPath = path.join(UNIT_DIR, m.SYSTEMD_UNIT_NAME);

// ── dryRun round-trip: exact action list, including the @HIMMEL_REPO@
// substitution (named in the dry-run detail — dryRun writes nothing) ───────
{
  const r = m.installSystemdUnit({ repoRoot: REPO_FIXTURE, dryRun: true });
  check('install dryRun: ok=true', true, r.ok);
  check('install dryRun: actions (exact)', [
    `write ${unitPath}`,
    'systemctl --user daemon-reload',
    `systemctl --user enable --now ${m.SYSTEMD_UNIT_NAME}`,
  ], r.actions);
  if (r.detail.indexOf(`@HIMMEL_REPO@ -> ${REPO_FIXTURE}`) !== -1) {
    pass('install dryRun: detail names the @HIMMEL_REPO@ -> repoRoot substitution');
  } else {
    fail('install dryRun: detail names the @HIMMEL_REPO@ -> repoRoot substitution', r.detail);
  }
  check('install dryRun: no file written', false, fs.existsSync(unitPath));

  const ru = m.uninstallSystemdUnit({ dryRun: true });
  check('uninstall dryRun: ok=true', true, ru.ok);
  check('uninstall dryRun: actions (exact, codex-4: includes daemon-reload)', [
    `systemctl --user disable --now ${m.SYSTEMD_UNIT_NAME}`,
    `remove ${unitPath}`,
    'systemctl --user daemon-reload',
  ], ru.actions);

  const rl = m.enableLinger({ user: 'op', dryRun: true });
  check('enableLinger dryRun: ok=true', true, rl.ok);
  check('enableLinger dryRun: actions (exact)', ['loginctl enable-linger op'], rl.actions);

  const rw = m.installWindowsLogonTask({ repoRoot: REPO_FIXTURE, dryRun: true });
  check('installWindowsLogonTask dryRun: ok=true', true, rw.ok);
  check('installWindowsLogonTask dryRun: actions (exact)', 1, rw.actions.length);
  if (rw.actions[0].indexOf('install-logon-task.ps1') !== -1 && rw.actions[0].indexOf(`-Repo ${REPO_FIXTURE}`) !== -1) {
    pass('installWindowsLogonTask dryRun: action names install-logon-task.ps1 -Repo <repoRoot>');
  } else {
    fail('installWindowsLogonTask dryRun: action names install-logon-task.ps1 -Repo <repoRoot>', JSON.stringify(rw.actions));
  }

  const ruw = m.uninstallWindowsLogonTask({ dryRun: true });
  check('uninstallWindowsLogonTask dryRun: ok=true', true, ruw.ok);
  check('uninstallWindowsLogonTask dryRun: actions (exact)', 1, ruw.actions.length);
  if (ruw.actions[0].indexOf('install-logon-task.ps1') !== -1 && ruw.actions[0].indexOf('-Remove') !== -1) {
    pass('uninstallWindowsLogonTask dryRun: action names install-logon-task.ps1 -Remove');
  } else {
    fail('uninstallWindowsLogonTask dryRun: action names install-logon-task.ps1 -Remove', JSON.stringify(ruw.actions));
  }

  check('installWindowsLogonTask: repoRoot required', false, m.installWindowsLogonTask({}).ok);
}

// ── Windows logon-task primitives: non-Windows graceful path. Exercised for
// real ONLY off Windows (process.platform !== 'win32') — never attempted on
// the real Windows dev host, where it would genuinely spawn pwsh and
// register a real scheduled task (requirement: never touch real machine
// state from a test). Honestly SKIPped there instead. ──────────────────────
if (process.platform !== 'win32') {
  const r = m.installWindowsLogonTask({ repoRoot: REPO_FIXTURE });
  check('installWindowsLogonTask (non-Windows): ok=false', false, r.ok);
  if (/not a Windows host/.test(r.detail)) {
    pass('installWindowsLogonTask (non-Windows): detail names a non-Windows host');
  } else {
    fail('installWindowsLogonTask (non-Windows): detail names a non-Windows host', r.detail);
  }

  const ru = m.uninstallWindowsLogonTask({});
  check('uninstallWindowsLogonTask (non-Windows): ok=false', false, ru.ok);
  if (/not a Windows host/.test(ru.detail)) {
    pass('uninstallWindowsLogonTask (non-Windows): detail names a non-Windows host');
  } else {
    fail('uninstallWindowsLogonTask (non-Windows): detail names a non-Windows host', ru.detail);
  }
} else {
  skip('installWindowsLogonTask/uninstallWindowsLogonTask (non-Windows graceful path)', 'this host IS Windows (process.platform===win32) — exercising the real-invocation branch here would genuinely spawn pwsh and register a real scheduled task; verified for real on WSL/Linux instead');
}

// ── Windows logon-task primitives: argv verification via an injected
// spawnFn (codex-2, round 10) — the REAL win32 branch, minus the actual
// spawn. Node's process.platform reports 'win32' for THIS repo's own Git
// Bash dev host too (native Windows node, not an MSYS thing), so this
// genuinely exercises PowerShell invocation/argument construction — the
// primary-platform code path round-1's own tests never reached — without
// ever touching a real process or registering a real scheduled task. Off
// Windows this branch is correctly unreachable regardless of injection
// (the platform gate fires first, same as the graceful-path block above),
// so it SKIPs there instead of asserting nothing. ──────────────────────────
if (process.platform === 'win32') {
  const installCalls = [];
  const fakeInstallSpawn = (cmd, args, opts) => { installCalls.push({ cmd, args, opts }); return { status: 0, stdout: '', stderr: '' }; };
  const ri = m.installWindowsLogonTask({ repoRoot: REPO_FIXTURE, spawnFn: fakeInstallSpawn });
  check('installWindowsLogonTask (injected spawn): ok=true, never touched a real process', true, ri.ok);
  check('installWindowsLogonTask (injected spawn): spawned exactly once', 1, installCalls.length);
  if (installCalls.length === 1) {
    const args = installCalls[0].args;
    check('installWindowsLogonTask argv: -NoProfile present', true, args.includes('-NoProfile'));
    check('installWindowsLogonTask argv: -File present', true, args.includes('-File'));
    check('installWindowsLogonTask argv: script path names install-logon-task.ps1', true, args.some((a) => typeof a === 'string' && a.indexOf('install-logon-task.ps1') !== -1));
    check('installWindowsLogonTask argv: -Repo <repoRoot> present', true, args.includes('-Repo') && args.includes(REPO_FIXTURE));
  }

  const uninstallCalls = [];
  const fakeUninstallSpawn = (cmd, args, opts) => { uninstallCalls.push({ cmd, args, opts }); return { status: 0, stdout: '', stderr: '' }; };
  const ru2 = m.uninstallWindowsLogonTask({ spawnFn: fakeUninstallSpawn });
  check('uninstallWindowsLogonTask (injected spawn): ok=true, never touched a real process', true, ru2.ok);
  check('uninstallWindowsLogonTask (injected spawn): spawned exactly once', 1, uninstallCalls.length);
  if (uninstallCalls.length === 1) {
    const args = uninstallCalls[0].args;
    check('uninstallWindowsLogonTask argv: -Remove present', true, args.includes('-Remove'));
    check('uninstallWindowsLogonTask argv: script path names install-logon-task.ps1', true, args.some((a) => typeof a === 'string' && a.indexOf('install-logon-task.ps1') !== -1));
  }

  // A failing spawn (real pwsh exit code) must still propagate honestly
  // through the injected path — proves the injection wires into the SAME
  // status/stderr handling the real spawnSync path uses, not a shortcut.
  const failCalls = [];
  const fakeFailSpawn = () => { failCalls.push(1); return { status: 1, stdout: '', stderr: 'boom' }; };
  const rFail = m.installWindowsLogonTask({ repoRoot: REPO_FIXTURE, spawnFn: fakeFailSpawn });
  check('installWindowsLogonTask (injected spawn, forced failure): ok=false', false, rFail.ok);
  if (/boom/.test(rFail.detail)) {
    pass('installWindowsLogonTask (injected spawn, forced failure): detail carries the real stderr');
  } else {
    fail('installWindowsLogonTask (injected spawn, forced failure): detail carries the real stderr', rFail.detail);
  }
} else {
  skip('installWindowsLogonTask/uninstallWindowsLogonTask (injected-spawn argv verification)', `this host is not win32 (platform=${process.platform}) — the win32 branch is correctly unreachable here regardless of injection; verified for real on the Windows dev host instead`);
}

// ── non-Linux graceful path: systemctl/loginctl genuinely absent from PATH ─
process.env.PATH = EMPTY_DIR;
{
  const r = m.installSystemdUnit({ repoRoot: REPO_FIXTURE });
  check('install (no systemctl on PATH): ok=false', false, r.ok);
  if (/not a systemd\/Linux host/.test(r.detail)) {
    pass('install (no systemctl on PATH): detail names a non-Linux host');
  } else {
    fail('install (no systemctl on PATH): detail names a non-Linux host', r.detail);
  }
  check('install (no systemctl on PATH): no file written', false, fs.existsSync(unitPath));

  const ru = m.uninstallSystemdUnit({});
  check('uninstall (no systemctl on PATH): ok=false', false, ru.ok);

  const rl = m.enableLinger({ user: 'op' });
  check('enableLinger (no loginctl on PATH): ok=false', false, rl.ok);

  check('lingerEnabled (no loginctl on PATH): null', null, m.lingerEnabled({ user: 'op' }));

  const s = m.systemdUnitInstalled();
  check('systemdUnitInstalled (no systemctl on PATH): enabled=null', null, s.enabled);
  check('systemdUnitInstalled (no systemctl on PATH): fileExists=false', false, s.fileExists);
}

// ── stub present on PATH: real write+substitution always exercised; the
// spawn-dependent outcomes are asserted dynamically per stubLogHas() above ─
// PREPEND onto REAL_PATH, never replace and never build on whatever the
// prior case left process.env.PATH as: the stub's own `#!/usr/bin/env bash`
// shebang needs `bash` resolvable via ITS spawned process's PATH too (a
// plain `PATH = STUB_DIR`, or `STUB_DIR + (the now-EMPTY_DIR-only PATH the
// prior case left behind)`, both starve that lookup — `/usr/bin/env: 'bash':
// No such file or directory`, rc=127 — even though `which('systemctl')`
// genuinely found and invoked the stub). Putting STUB_DIR first still
// guarantees our stub shadows any real systemctl/loginctl later in PATH
// (never invoke the real ones).
process.env.PATH = STUB_DIR + path.delimiter + REAL_PATH;
process.env.BRIDGE_PERSISTENCE_STUB_LOG = STUB_LOG;
process.env.BRIDGE_PERSISTENCE_STUB_STATE = STUB_STATE;
{
  const r = m.installSystemdUnit({ repoRoot: REPO_FIXTURE });

  let content = '';
  try { content = fs.readFileSync(unitPath, 'utf8'); } catch (e) { /* not written */ }
  // codex-1 CR fix (round 13): the substitution is now LINE-AWARE (only
  // WorkingDirectory=/Environment=/ExecStart=/ExecStop= lines), not a
  // blanket template.split().join() over the whole file — so the
  // template's own header COMMENT, which mentions "@HIMMEL_REPO@" as PROSE
  // describing the placeholder mechanism, is deliberately left alone rather
  // than mangled into a repo-path-shaped sentence. The assertion now checks
  // the placeholder is gone from the DIRECTIVE lines specifically, not the
  // whole file.
  const directiveLines = content.split('\n').filter((l) => /^(WorkingDirectory|Environment|ExecStart|ExecStop)=/.test(l));
  const directivesSubstituted = directiveLines.length > 0 && directiveLines.every((l) => l.indexOf('@HIMMEL_REPO@') === -1);
  if (content && directivesSubstituted && content.indexOf(REPO_FIXTURE) !== -1) {
    pass('install (stub present): unit file written with @HIMMEL_REPO@ substituted for repoRoot');
  } else {
    fail('install (stub present): unit file written with @HIMMEL_REPO@ substituted for repoRoot', `content=${JSON.stringify(content)}`);
  }

  // codex-1 CR fix (round 13): a repoRoot containing systemd specifier `%`
  // (and, since we're in here, a space/`"`/`\`) must render LITERALLY, never
  // expanded (%h -> home) or corrupted (an unescaped `%` was verified live
  // to make the whole unit fail to start; an unquoted space was verified to
  // silently split one ExecStart argument into several). Runs
  // unconditionally on both platforms — the WRITE itself doesn't depend on
  // daemon-reload/enable ever succeeding, same as the plain-path check just
  // above.
  const trickyRepoRoot = '/tmp/repo"with\\backslash and space%h';
  const expectedPercentEscaped = trickyRepoRoot.replace(/%/g, '%%');
  const expectedQuoted = `"${expectedPercentEscaped.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
  m.installSystemdUnit({ repoRoot: trickyRepoRoot });
  let trickyContent = '';
  try { trickyContent = fs.readFileSync(unitPath, 'utf8'); } catch (e) { /* not written */ }
  check('install (repoRoot has %/space/"/\\): WorkingDirectory carries the raw, percent-escaped value', true, trickyContent.indexOf(`WorkingDirectory=${expectedPercentEscaped}`) !== -1);
  check('install (repoRoot has %/space/"/\\): Environment/ExecStart carry the quoted, fully-escaped value', true, trickyContent.indexOf(expectedQuoted) !== -1);
  check('install (repoRoot has %/space/"/\\): no unescaped single "%h" specifier survives', false, /(^|[^%])%h/.test(trickyContent));

  // codex-1 CR fix (round 14): a repoRoot containing CR/LF must be REFUSED
  // outright, not escaped — there is no correct rendering of a newline
  // inside a unit directive; the %/quote/backslash escaping above turns a
  // dangerous character into a safe STRING, but a newline would create an
  // additional, unintended unit DIRECTIVE instead. Removes whatever the
  // tricky-repoRoot case above left behind first, so "no file created" is
  // unambiguous; needs no systemctl/stub at all (refused before the
  // haveSystemctl() check) so this runs unconditionally on both platforms.
  try { fs.unlinkSync(unitPath); } catch (e) { /* already absent */ }
  const newlineRepoRoot = '/tmp/repo\nwith-newline';
  const rNewline = m.installSystemdUnit({ repoRoot: newlineRepoRoot });
  check('install (repoRoot has CR/LF): ok=false', false, rNewline.ok);
  check('install (repoRoot has CR/LF): no unit file created', false, fs.existsSync(unitPath));
  if (/CR or LF/.test(rNewline.detail)) {
    pass('install (repoRoot has CR/LF): detail names the cause');
  } else {
    fail('install (repoRoot has CR/LF): detail names the cause', rNewline.detail);
  }
  const rNewlineDry = m.installSystemdUnit({ repoRoot: newlineRepoRoot, dryRun: true });
  check('install (repoRoot has CR/LF, dryRun): also refuses', false, rNewlineDry.ok);
  const rCr = m.installSystemdUnit({ repoRoot: '/tmp/repo\rwith-cr' });
  check('install (repoRoot has bare CR): ok=false too', false, rCr.ok);

  // Restore the plain-path unit for the rest of this block's assertions
  // below (they read $unitPath's content/state assuming REPO_FIXTURE).
  m.installSystemdUnit({ repoRoot: REPO_FIXTURE });

  if (stubLogHas('daemon-reload')) {
    check('install (stub present, spawn works): ok=true (full happy path)', true, r.ok);
    check('install (stub present, spawn works): actions (exact happy-path list)', [
      `write ${unitPath}`,
      'systemctl --user daemon-reload',
      `systemctl --user enable --now ${m.SYSTEMD_UNIT_NAME}`,
    ], r.actions);
  } else {
    check('install (stub present, spawn did not run on this host): ok=false', false, r.ok);
    skip('install (stub present): full happy-path enable/daemon-reload exercise', 'no evidence in the stub log that the spawn actually ran on this host (see file header)');
  }

  // codex-1 CR fix (round 10): a `daemon-reload` failure AFTER the unit file
  // is already durably written must report partial:true, never a flat
  // failure — round 5's codex-2 covered enable-succeeded/start-failed;
  // this covers the branch immediately after the FIRST durable side
  // effect (the write itself).
  fs.writeFileSync(path.join(STUB_STATE, 'reload-fail'), '');
  const rReloadFail = m.installSystemdUnit({ repoRoot: REPO_FIXTURE });
  if (stubLogHas('daemon-reload')) {
    check('install (daemon-reload fails): ok=false', false, rReloadFail.ok);
    check('install (daemon-reload fails): partial=true (file IS on disk)', true, rReloadFail.partial);
    if (/unit file IS written/.test(rReloadFail.detail) && /daemon-reload failed/.test(rReloadFail.detail)) {
      pass('install (daemon-reload fails): detail names what actually landed');
    } else {
      fail('install (daemon-reload fails): detail names what actually landed', rReloadFail.detail);
    }
    check('install (daemon-reload fails): unit file genuinely written to disk', true, fs.existsSync(unitPath));
  } else {
    check('install (daemon-reload fails, spawn did not run on this host): ok=false', false, rReloadFail.ok);
    skip('install (daemon-reload fails): partial-state wording exercise', 'no evidence in the stub log that the spawn actually ran on this host (see file header)');
  }
  fs.unlinkSync(path.join(STUB_STATE, 'reload-fail'));

  // codex-1 CR fix (round 10), continued: `enable --now` failing OUTRIGHT
  // (genuinely not enabled, not just a stuck-enabled start failure) must
  // ALSO report partial:true — the write and the reload both already
  // landed durably regardless of whether enable itself took.
  fs.writeFileSync(path.join(STUB_STATE, 'enable-now-fail'), '');
  const rEnableFailClean = m.installSystemdUnit({ repoRoot: REPO_FIXTURE });
  if (stubLogHas('is-enabled')) {
    check('install (enable --now fails, genuinely not enabled): ok=false', false, rEnableFailClean.ok);
    check('install (enable --now fails, genuinely not enabled): partial=true (file+reload landed)', true, rEnableFailClean.partial);
    if (/IS written/.test(rEnableFailClean.detail) && /IS reloaded/.test(rEnableFailClean.detail) && /NOT enabled and NOT running/.test(rEnableFailClean.detail)) {
      pass('install (enable --now fails, genuinely not enabled): detail names what landed');
    } else {
      fail('install (enable --now fails, genuinely not enabled): detail names what landed', rEnableFailClean.detail);
    }
  } else {
    check('install (enable --now fails, spawn did not run on this host): ok=false', false, rEnableFailClean.ok);
    skip('install (enable --now fails, genuinely not enabled): partial-state wording exercise', 'no evidence in the stub log that the spawn actually ran on this host (see file header)');
  }
  fs.unlinkSync(path.join(STUB_STATE, 'enable-now-fail'));

  // codex-2 CR fix (round 5): `enable --now` failing to START must not
  // report a flat failure when the ENABLE half already stuck (systemd runs
  // enable then start as one combined call — a start failure doesn't undo
  // it). Forces `enable --now` to fail while `is-enabled` reports the unit
  // enabled anyway, and asserts the detail names the partial state +
  // remediation, never a plain "failed" — round 10 additionally asserts
  // partial:true itself, not just the wording.
  fs.writeFileSync(path.join(STUB_STATE, 'enable-now-fail'), '');
  fs.writeFileSync(path.join(STUB_STATE, 'enabled'), '');
  const rPartial = m.installSystemdUnit({ repoRoot: REPO_FIXTURE });
  if (stubLogHas('is-enabled')) {
    check('install (enable --now fails, but stuck enabled): ok=false', false, rPartial.ok);
    check('install (enable --now fails, but stuck enabled): partial=true', true, rPartial.partial);
    if (/IS now enabled/.test(rPartial.detail) && /NOT running/.test(rPartial.detail) && /systemctl --user start/.test(rPartial.detail)) {
      pass('install (enable --now fails, but stuck enabled): detail names the partial state + remediation');
    } else {
      fail('install (enable --now fails, but stuck enabled): detail names the partial state + remediation', rPartial.detail);
    }
  } else {
    check('install (enable --now fails, spawn did not run on this host): ok=false', false, rPartial.ok);
    skip('install (enable --now fails, but stuck enabled): partial-state wording exercise', 'no evidence in the stub log that the spawn actually ran on this host (see file header)');
  }
  fs.unlinkSync(path.join(STUB_STATE, 'enable-now-fail'));

  const s = m.systemdUnitInstalled();
  check('systemdUnitInstalled: fileExists=true after a real write', true, s.fileExists);
  if (stubLogHas('is-enabled')) {
    check('systemdUnitInstalled: enabled=true (is-enabled stdout "enabled")', true, s.enabled);
  } else {
    check('systemdUnitInstalled: enabled=null (spawn did not run on this host)', null, s.enabled);
    skip('systemdUnitInstalled: enabled=true/false stdout-parsing branches', 'no evidence in the stub log that the spawn actually ran on this host (see file header)');
  }
  fs.unlinkSync(path.join(STUB_STATE, 'enabled')); // done with it — must NOT leak "enabled" into the later uninstall/codex-1 cases below

  fs.writeFileSync(path.join(STUB_STATE, 'linger-yes'), '');
  const linger1 = m.lingerEnabled({ user: 'op' });
  if (stubLogHas('--property=Linger')) {
    check('lingerEnabled: true when loginctl reports Linger=yes', true, linger1);
    fs.unlinkSync(path.join(STUB_STATE, 'linger-yes'));
    fs.writeFileSync(path.join(STUB_STATE, 'linger-no'), '');
    check('lingerEnabled: false when loginctl reports Linger=no', false, m.lingerEnabled({ user: 'op' }));
  } else {
    check('lingerEnabled: null (spawn did not run on this host)', null, linger1);
    skip('lingerEnabled: Linger=yes/no stdout-parsing branches', 'no evidence in the stub log that the spawn actually ran on this host (see file header)');
  }

  // codex-5 CR fix: a failed `disable --now` must never report ok:true, and
  // the unit file must NOT be removed while the unit may still be running.
  // No SKIP needed on EITHER platform: the stub is forced to exit non-zero
  // on Linux (disable-fail marker) and genuinely fails to spawn at all on
  // Windows (status=null) — both trip the exact same refusal branch.
  fs.writeFileSync(path.join(STUB_STATE, 'disable-fail'), '');
  const ruFail = m.uninstallSystemdUnit({});
  check('uninstall (disable fails): ok=false, never a false-green', false, ruFail.ok);
  check('uninstall (disable fails): unit file NOT removed', true, fs.existsSync(unitPath));
  check('uninstall (disable fails): NOT partial — nothing of ours landed yet', undefined, ruFail.partial);
  if (/still be running/.test(ruFail.detail)) {
    pass('uninstall (disable fails): detail names the still-running unit');
  } else {
    fail('uninstall (disable fails): detail names the still-running unit', ruFail.detail);
  }
  fs.unlinkSync(path.join(STUB_STATE, 'disable-fail'));

  // codex-4 CR fix: uninstall must also reload the systemd user daemon after
  // removing the file (installSystemdUnit()'s own mirror step) — captured
  // before/after so this counts UNINSTALL's own reload call specifically,
  // not the one install already logged earlier in this same run.
  const reloadCountBefore = stubLogCount('daemon-reload');
  const ru = m.uninstallSystemdUnit({});
  if (stubLogHas('daemon-reload')) {
    check('uninstall (stub present, spawn works): ok=true', true, ru.ok);
    check('uninstall (stub present, spawn works): fileExists=false afterward', false, fs.existsSync(unitPath));
    check('uninstall (stub present, spawn works): daemon-reload actually invoked', reloadCountBefore + 1, stubLogCount('daemon-reload'));
  } else {
    check('uninstall (stub present, spawn did not run on this host): ok=false (disable never succeeded)', false, ru.ok);
    check('uninstall (stub present): unit file still NOT removed', true, fs.existsSync(unitPath));
    skip('uninstall (stub present): happy-path removal exercise', 'no evidence in the stub log that the spawn actually ran on this host (see file header)');
    fs.unlinkSync(unitPath); // manual cleanup — production code correctly refused to
  }

  // codex-1 CR fix (round 11): consistency — a `daemon-reload` failure AFTER
  // disable+remove already durably succeeded must ALSO report partial:true,
  // mirroring installSystemdUnit()'s own write-then-reload-fails branch
  // (round 10). Explicitly (re)writes the unit file first — the block above
  // always leaves it absent by design, so this can't rely on ambient state
  // from an earlier case; it sets up its own precondition.
  fs.writeFileSync(unitPath, 'stub-unit-file-for-reload-fail-test');
  fs.writeFileSync(path.join(STUB_STATE, 'reload-fail'), '');
  const ruReloadFail = m.uninstallSystemdUnit({});
  if (stubLogHas('daemon-reload')) {
    check('uninstall (daemon-reload fails after disable+remove succeed): ok=false', false, ruReloadFail.ok);
    check('uninstall (daemon-reload fails after disable+remove succeed): partial=true', true, ruReloadFail.partial);
    if (/disable --now telegram-bridge.service succeeded/.test(ruReloadFail.detail) && /daemon-reload failed/.test(ruReloadFail.detail)) {
      pass('uninstall (daemon-reload fails after disable+remove succeed): detail names what actually landed');
    } else {
      fail('uninstall (daemon-reload fails after disable+remove succeed): detail names what actually landed', ruReloadFail.detail);
    }
    check('uninstall (daemon-reload fails after disable+remove succeed): unit file WAS removed regardless', false, fs.existsSync(unitPath));
  } else {
    check('uninstall (daemon-reload fails, spawn did not run on this host): ok=false', false, ruReloadFail.ok);
    skip('uninstall (daemon-reload fails after disable+remove succeed): partial-state wording exercise', 'no evidence in the stub log that the spawn actually ran on this host (see file header)');
    fs.unlinkSync(unitPath); // manual cleanup — production code correctly refused to remove it (disable never spawned)
  }
  fs.unlinkSync(path.join(STUB_STATE, 'reload-fail'));

  // codex-1 CR fix (round 12): is-enabled/is-active are non-zero for BOTH
  // "systemd never heard of this" and "systemd knows it, disabled/stopped"
  // — the round-5 confirmed-negative check couldn't tell those apart, so a
  // unit systemd still had LOADED (just off) took the no-op shortcut,
  // skipped the required daemon-reload, and reported a stale definition as
  // fully uninstalled. Forces `LoadState=loaded` while the file is
  // genuinely absent (from the block just above) — the exact case that
  // would have caught this: file absent, is-enabled/is-active would BOTH
  // read non-zero too, but systemd still knows it.
  //
  // The "did NOT take the no-op shortcut" assertion runs UNCONDITIONALLY on
  // both platforms — the production fix treats an inconclusive probe (a
  // spawn error, this host's own Windows shape) the same as "systemd still
  // knows it", so the shortcut can only ever fire on a CONFIRMED
  // LoadState=not-found; on Windows that confirmation itself is
  // unreachable, so the shortcut correctly never fires there either,
  // without needing the stub to have actually run. Verifying the disable
  // call was a REAL spawn (via the stub log) is separately gated — SKIP
  // there, same as every other spawn-dependent case in this file.
  fs.writeFileSync(path.join(STUB_STATE, 'loadstate-loaded'), '');
  const disableCountBefore = stubLogCount('disable --now');
  const ruKnown = m.uninstallSystemdUnit({});
  if (/already absent and systemd reports LoadState=not-found/.test(ruKnown.detail)) {
    fail('uninstall (file absent, systemd still knows it): did NOT take the no-op shortcut', ruKnown.detail);
  } else {
    pass('uninstall (file absent, systemd still knows it): did NOT take the no-op shortcut');
  }
  if (stubLogHas('--property=LoadState')) {
    check('uninstall (file absent, systemd still knows it): invoked a REAL disable', disableCountBefore + 1, stubLogCount('disable --now'));
  } else {
    skip('uninstall (file absent, systemd still knows it): real disable-invocation exercise', 'no evidence in the stub log that the spawn actually ran on this host (see file header)');
  }
  fs.unlinkSync(path.join(STUB_STATE, 'loadstate-loaded')); // must NOT leak into the genuine no-op case below

  // codex-2 CR fix (round 3): uninstalling an already-uninstalled bridge
  // (unit file already absent) must be a clean idempotent no-op success,
  // never a false failure from `disable --now` on a unit that's already
  // gone. codex-1 tightened the shortcut twice since: round 5 required a
  // confirmed negative rather than a bare absent file; round 12 replaced
  // that confirmed-negative source with LoadState (is-enabled/is-active
  // couldn't distinguish "never heard of it" from "knows it, it's off") —
  // the no-op only fires on a genuinely-executed LoadState=not-found. On
  // this host's Windows placeholder stub that probe never spawns (same
  // class as every other spawn-dependent case here — a real Windows
  // adopter never reaches this code at all, since `haveSystemctl()` itself
  // is false there), so the confirmed-idempotency assertion is gated on
  // the same stub-log evidence as everything else and SKIPs there instead
  // of faking a pass.
  const ruAbsent = m.uninstallSystemdUnit({});
  if (stubLogHas('--property=LoadState')) {
    check('uninstall (already absent): ok=true, idempotent no-op', true, ruAbsent.ok);
    if (/already absent/.test(ruAbsent.detail)) {
      pass('uninstall (already absent): detail names nothing-to-uninstall');
    } else {
      fail('uninstall (already absent): detail names nothing-to-uninstall', ruAbsent.detail);
    }
  } else {
    skip('uninstall (already absent): confirmed idempotent no-op exercise', 'no evidence in the stub log that the LoadState probe actually ran on this host (see file header) — codex-1 correctly refuses to treat an inconclusive probe as a confirmed negative');
  }
}

console.log('');
if (FAIL === 0) {
  console.log(`OK test-bridge-persistence: ${PASS} passed, ${SKIP} skipped, 0 failed`);
  process.exit(0);
}
console.error(`ERR test-bridge-persistence: ${PASS} passed, ${SKIP} skipped, ${FAIL} failed`);
process.exit(1);
EOF_JS

BRIDGE_TEST_LIB="$LIB_NODE" \
BRIDGE_TEST_REPO_FIXTURE="/fixture/himmel-repo" \
BRIDGE_TEST_UNIT_DIR="$(to_node_path "$UNIT_DIR")" \
BRIDGE_TEST_EMPTY_DIR="$(to_node_path "$EMPTY_DIR")" \
BRIDGE_TEST_STUB_DIR="$(to_node_path "$STUB_DIR")" \
BRIDGE_TEST_STUB_LOG="$(to_node_path "$STUB_LOG")" \
BRIDGE_TEST_STUB_STATE="$(to_node_path "$STUB_STATE")" \
HIMMELCTL_SYSTEMD_USER_UNIT_DIR="$(to_node_path "$UNIT_DIR")" \
node "$(to_node_path "$WORK/check.js")"
exit $?
