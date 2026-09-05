#!/usr/bin/env bash
# test-wizard-probes.sh — hermetic tests for scripts/himmelctl/lib/probes.js
# (HIMMEL-756 T1.4, extended HIMMEL-1093): the probe-type engine, run against
# the REAL scripts/install/manifest.json descriptors (so a manifest authoring
# drift breaks THIS suite, not silently). Mirrors sibling test-wizard-*.sh
# conventions: scripts/lib/hermetic-path.sh's link_hermetic_tool/scrub_path
# for curated stub PATHs, node launched by absolute path, winpath for
# node.exe's MSYS-path blindness.
#
# Covers, present AND absent (plus degraded where the probe type supports a
# tri-state result):
#   file-exists    targetPath-relative (guardrail-scope), the repoRoot-
#                  relative exception (jira-cli-dist-build — proves it
#                  ignores a targetPath that DOES carry the file), and the
#                  {vaultPath} placeholder (luna-vault-scaffold).
#   git-hooks      pre-commit-hooks absent (none installed) / degraded
#                  (partial install) / present (pre-commit + commit-msg +
#                  pre-push), including linked-worktree commondir resolution.
#   settings-key   dot-path single key (wiring-statusline), simple
#                  non-dotted key (claude-plugins-pluginSet), and the .env
#                  ALL-keys-required union resolving against repoRoot for
#                  BOTH scopes (jira-env-keys).
#   settings-hooks present (all 3 himmel PreToolUse markers) / degraded
#                  (1 of 3) / absent (none) (wiring-pretooluse).
#   cmd:has_qmd    qmd-binary, via a stubbed `qmd` on PATH.
#   qmd-index      present (all 4 collections) / degraded (2 of 4) / absent
#                  (no qmd on PATH).
#   mcp-registered tokensave-mcp present / server missing / file missing
#                  (ENOENT, clean) / malformed JSON / unexpected shape
#                  (the latter two carry configError:true), resolving
#                  .claude.json from ctx.env.HOME; graphify-mcp
#                  scope-awareness — project scope resolves <targetPath>/
#                  .mcp.json, user scope resolves ~/.claude.json, no
#                  cross-scope bleed (HIMMEL-1017 CR round); (HIMMEL-1093)
#                  the bin/initMarker deepening against the REAL tokensave-mcp
#                  descriptor — registered-but-broken (unresolved binary /
#                  uninitialized project) reads degraded, not present;
#                  (HIMMEL-1093 round 2, codex-2) the bin check resolves via
#                  ctx.env.PATH, proven DIVERGING from process.env.PATH (the
#                  outer shell's PATH is scrubbed of the stub, ctx.env's
#                  carries an extra dir process.env.PATH lacks); every fixture
#                  above pins a REGISTERED `command` that resolves (round 3,
#                  codex-adv-1's registered-command check is now
#                  unconditional — see the dedicated block further down for
#                  the wrong/missing/nonexistent-command coverage itself,
#                  including round 5's POSIX executability distinction —
#                  win32-reachable paths only; see that block's skip note).
#   which()        (helpers.js, round 5, codex-1) key-PRESENCE beats
#                  truthiness — a deliberately scrubbed PATH:'' must not fall
#                  through to a present Path, and Path alone (PATH key
#                  genuinely absent) still resolves.
#   handover-dir   handover-wiring — HANDOVER_DIR set (ctx.env pass-through,
#                  not process.env mutation) / unset with a non-repo cwd.
#   dep            single-cmd (rtk), the win32/posix platform union
#                  (scheduler-backend), and (HIMMEL-1093) graphify — each
#                  present/absent via stub PATH.
#   cmd:has_hermes (HIMMEL-1093) hermes-lanes, sourcing (via a resolver path
#                  passed through the spawned env, not string-interpolated
#                  into the command — round 6, codex-1) a stub resolve-
#                  hermes-py.sh — present/absent; resolver missing (rc 3,
#                  probe wiring broken) and a spawn error (bash unresolvable)
#                  both reading degraded (round 4, mirroring cmd:is_himmel_
#                  dev's round-2 fix); plus (round 6, codex-2) an UNEXPECTED
#                  rc (127 — resolver sourced but the function was never
#                  defined) also reading degraded, not the same absent as
#                  resolve_hermes_py's own clean "not installed" (rc 1).
#   cmd:is_himmel_dev (HIMMEL-1093) doc-guard-map, sourcing (same env-passed-
#                  path shape as cmd:has_hermes — round 6, codex-1) a stub
#                  guardrails/lib.sh — present (rc 0) / absent (rc 1, the
#                  ordinary non-contributor case) / degraded (rc 2, repo root
#                  unresolvable); plus (round 2, codex-1) rc 3 (resolver
#                  itself fails to source — probe wiring broken, must NOT
#                  read the same 'absent' as a clean marker-not-present), a
#                  spawn error (bash itself unresolvable via ctx.env.PATH),
#                  and (round 6, codex-2) an UNEXPECTED rc (127 — resolver
#                  sourced but the function was never defined) also reading
#                  degraded, never the same absent as is_himmel_dev_repo's
#                  own clean "not a dev checkout" (rc 1).
#   telegram-access (HIMMEL-1093 round 3, codex-adv-3) telegram-bridge — no
#                  token (absent); token + access.json missing/unparseable/
#                  no usable allow rule (degraded, would gate out every DM/
#                  group); token + a real allowFrom or a groups-only
#                  access.json (present).
#   file-exists {homePath} (HIMMEL-1100) obsidian-second-brain — present/
#                  absent, mirroring {vaultPath}'s existing pattern.
#   cmd:codex_provisioned (HIMMEL-1100) codex-cli — pure JS, no spawn: CODEX_BIN
#                  override semantics (unusable override = absent, no PATH
#                  fallback) / plain PATH resolution / binary-resolves-but-
#                  never-provisioned (no plugin cache dir) reads degraded, not
#                  present — the same false-green class HIMMEL-1093 killed for
#                  tokensave-mcp, applied here proactively; plus (round 3,
#                  codex-adv-2) a cache dir with OTHER marketplaces cached
#                  but no himmel/ subdir also reads degraded — ANY cache dir
#                  is not himmel-specific evidence, only a cache entry for
#                  the himmel marketplace itself is.
#   cmd:cadence_armed (HIMMEL-1100) pipeline-cadence (full matrix: armed /
#                  not-armed / resolver-missing / spawn-error / unexpected-rc,
#                  the round-6 discipline applied from the start) plus
#                  codex-sweep-cadence/graphmap-cadence envVar-wiring sanity.
#   cmd:guardrail_block_status (HIMMEL-1100) guardrail-block-global —
#                  project-mode (absent) / rotted node path, unparseable
#                  output, nonzero exit (all degraded); plus (round 3,
#                  codex-adv-1) a 1-of-3-hooks partial install (mode=global,
#                  node-resolves=yes for the ONE wired hook) reads degraded,
#                  NEVER present — status output cannot attest all 3
#                  guardrail hooks, only that at least one is wired, so
#                  'present' is bounded to unreachable via this data source.
#                  (HIMMEL-1427, CR round 1) 'present' additionally requires
#                  the v2 attestation layer (contentIntegrityComplete /
#                  auditAnchorComplete / attestationComplete + per-hook
#                  wrapperIntegrity/scriptIntegrity and *MatchesAuditAnchor),
#                  recomputed from the payload's own parts for self-consistency;
#                  a content-tampered wrapper or divergent audit anchor reads
#                  degraded naming the dimension, and (CR round 2) a payload
#                  with NO v2 fields (stale checkout or stripped/tampered
#                  output) OR a PARTIAL v2 set FAILS CLOSED — degraded, never
#                  the v1 'present' (round 1's fail-OPEN back-compat re-opened
#                  the downgrade path the attestation exists to close).
#   dep            (HIMMEL-1100) gemini-cli — present/absent via stub PATH.
#   cmd:hermes_checkout (HIMMEL-1100 round 3, codex-adv-3) hermes-checkout —
#                  pure fs, no git spawn: resolves update_hermes()'s OWN
#                  root/src, reads .git/config directly for the origin
#                  remote — present (genuine NousResearch/hermes-agent
#                  checkout, exact ssh AND https origin forms) / absent (no
#                  .git at all) / degraded (checkout present but wrong/
#                  missing/unreadable origin); distinct from cmd:has_hermes
#                  (a usable venv python), kept unchanged on hermes-lanes for
#                  runtime health. Round 4: (codex-1) an EXACT owner/repo
#                  path match, not a substring — a spoofed origin that merely
#                  CONTAINS "NousResearch/hermes-agent" (e.g. evil/
#                  NousResearch-hermes-agent-mirror) reads degraded, never a
#                  false present; (codex-2) .git as a gitlink FILE (worktree/
#                  submodule "gitdir: <path>") is honored too, following the
#                  pointer one level — a broken pointer reads degraded
#                  (a checkout genuinely exists, just unverifiable), never a
#                  crash or a silent absent. Round 5: (codex-1) a NORMAL
#                  linked worktree (gitdir -> .git/worktrees/<name>, which
#                  carries no remotes of its own) resolves via that dir's
#                  `commondir` file, followed ONE level to the common config
#                  with the origin — reads present, not falsely degraded.
#   purity         a full sweep over every manifest.json item leaves the
#                  fixture repo + vault trees byte-identical (sha256
#                  snapshot before/after).
#   telegram-access — HIMMEL-2176 Task 6 formal-schema extension: a
#                  semantically-usable access.json (non-empty allowFrom) that
#                  ALSO carries a wrong-typed field elsewhere (dmPolicy as a
#                  number, a per-group requireMention as a string) now reads
#                  degraded — the schema check runs BEFORE the pre-existing
#                  usable-allow-rule check, so a previously-passing shape
#                  can't mask a formal violation.
#   cmd:telegram_getme (HIMMEL-2176 Task 6) — no token (absent) / stub `bun`
#                  ok (present, detail carries the returned username, never
#                  the token) / stub `bun` rejects (degraded) / bun absent
#                  from PATH (degraded); a dedicated assertion greps the full
#                  JSON result for a distinctive fake token value and expects
#                  zero matches, across every one of these cases. Plus (CR fix,
#                  HIMMEL-2176 retask stage1-build-6d2e): a child that dumps
#                  the raw token straight to stderr, and a child whose stderr
#                  echoes a request URL with the token embedded in its path
#                  (getMe()'s own URL shape) — both still read degraded, and
#                  neither leaks the token into the result; the redacted
#                  detail keeps a `[REDACTED]` marker in its place, proving
#                  the diagnostic text was scrubbed, not silently dropped.
#                  Plus (CR round 9, retask stage1-build-6d2e): a
#                  runtime-observed network/API failure (the real script's
#                  own `runtime:`-tagged stderr) reads as a connectivity
#                  problem, never "probe wiring broken", while an
#                  import-stage (`wiring:`-tagged) failure still does —
#                  proving the two are told apart, not that everything
#                  became "runtime".
#   cmd:whisper_ready (HIMMEL-2176 Task 6, hardened by CR fix codex-2) —
#                  binary+model both present (present) / binary present,
#                  model missing (degraded) / binary missing (absent);
#                  platform-branched default binary name proven both ways via
#                  ctx.platform (whisper-cli.exe on a simulated win32,
#                  whisper-cli elsewhere); ALSO a plain DIRECTORY at the
#                  binary path (absent, never present), a 0-byte binary
#                  (absent) and a 0-byte model (degraded) — a truncated
#                  download must never read ready. Plus (CR fix, HIMMEL-2176
#                  retask stage1-build-6d2e): the exec-bit check is proven to
#                  be driven by ctx.platform, not the real host
#                  process.platform — process.platform is overridden to a
#                  non-win32 value while ctx.platform stays 'win32' and
#                  fs.accessSync is instrumented to count X_OK calls, so the
#                  win32-simulated fixtures above are shown to pass because
#                  of the platform routing, not by accident of this test host
#                  already being win32.
#   cmd:python_interpreter (HIMMEL-2176 Task 6) — absent (nothing on PATH,
#                  via bash's own rc=127 "command not found"), present (a
#                  stub interpreter that runs the given script and echoes the
#                  marker), degraded (a stub that mimics the REAL Windows
#                  Store python.exe app-execution alias: resolves on PATH,
#                  exits non-zero without running the script).
#   distinct-tokens (HIMMEL-2176 Task 6) — both unconfigured / only one
#                  configured / two distinct values (all present, nothing to
#                  collide with) vs. two IDENTICAL non-empty values
#                  (degraded, the one and only failure shape).
#   luna-sources   (HIMMEL-2176 Task 6, corrected under retask
#                  stage1-build-6d2e) — all configured sources ok (present);
#                  one auth-expired among others ok (degraded, names the
#                  source + reason); one source unrecognized by
#                  fetch-health.py (argparse exit code 2, matched against its
#                  own literal 'unknown probe source' stderr wording — NOT
#                  the bare rc alone) among others ok reads DEGRADED, never
#                  present (HIMMEL-1128 loud-degradation: a source not being
#                  monitored at all must not hide behind a green verdict); a
#                  DIFFERENT rc=2 usage error not carrying that wording folds
#                  into the unhealthy list instead, proving the two aren't
#                  conflated; every source unrecognized (nothing evaluated)
#                  reads DEGRADED too (CR round 3, retask stage1-build-6d2e —
#                  nothing being monitored at all can't be a lesser signal
#                  than one bad entry among healthy ones), distinguishable
#                  from genuinely-nothing-configured (empty list / every
#                  source merely unconfigured), which stays absent/warn.
#                  Subprocess faked via a stub
#                  `python` script keyed on the `--probe <source>` argument,
#                  never a JS mock. ALSO (CR fix codex-3, retask
#                  stage1-build-6d2e): a source whose reason names a simply
#                  ABSENT credential/artifact (matches fetch-health.py's own
#                  "...missing" wording) reads absent (unconfigured, warn
#                  tier), distinguishable in detail from a configured-but-
#                  broken source (degraded/fail tier) and from the
#                  "unrecognized" bucket above; a MIX of both in one sweep
#                  reads degraded (fail wins) and names both groups.
#   bridge-persistence (HIMMEL-2176 Stage-1 PR-C, status item S6) —
#                  bridge.enabled:false reads absent/cleanAbsence:true; Linux
#                  (unit+linger via a stubbed systemctl/loginctl on PATH,
#                  HIMMELCTL_SYSTEMD_USER_UNIT_DIR sandboxed): unit+linger ok
#                  reads present, linger OFF reads degraded naming linger
#                  specifically, unit absent reads degraded naming the unit;
#                  a unit file present but systemctl is-enabled reports it
#                  disabled reads degraded, never present (existence is not
#                  enablement — retask stage1-build-6d2e round 6); a unit file
#                  present but is-enabled exiting with an UNRECOGNIZED code
#                  (the null/undetermined tri-state, distinct from a confirmed
#                  not-enabled) also reads degraded but must NOT claim "not
#                  enabled" — it must name the undetermined condition instead;
#                  Windows (a stubbed powershell/Get-ScheduledTask on PATH, never a
#                  file-on-disk inference — the S1 false-green class; schtasks'
#                  LOCALIZED text output replaced with the culture-invariant
#                  .State enum — retask stage1-build-6d2e round 7): task
#                  registered AND State=Ready/Running reads present, a task
#                  that EXISTS but is State=Disabled (the query still
#                  succeeds) reads degraded naming the Disabled state, never
#                  present (the same existence-is-not-enablement CRITICAL
#                  fix), NOT registered at all reads degraded (with an
#                  explicit anti-false-green case: a plausible runner file on
#                  disk must not flip this), a failed scheduler query reads
#                  degraded/unknown, never present; an unsupported platform
#                  (darwin) reads a loud degraded naming the launchd/Stage-2
#                  limitation; a malformed config.json degrades cleanly,
#                  never crashes. Part B (bridge.envPath /
#                  bridge.whisper.{cli,model} — previously read by nothing):
#                  a configured envPath resolves the token from THAT path
#                  when set (no TELEGRAM_ENV override); TELEGRAM_ENV wins
#                  over a different configured value; no config file at all
#                  behaves identically to before this ticket (regression
#                  guard, both for the envPath and the whisper cli/model
#                  resolution); a malformed config degrades cleanly, never
#                  crashes cmd:whisper_ready either.

set -euo pipefail

# git rev-parse is the primary resolution (unchanged on a normal checkout);
# the path-based fallback (3 levels up from this file) is what the sibling
# suites (test-restart-bridge.sh, test-bridge-persistence.sh) already use, and
# is what makes this suite runnable under WSL against this worktree — its
# .git is a FILE pointing at a Windows-absolute `gitdir: C:/Users/...` path
# WSL cannot follow, so `git rev-parse --show-toplevel` fails there (retask
# stage1-build-6d2e). Deliberately NOT an exported GIT_DIR/GIT_WORK_TREE: that
# leaks into every probe fixture spawned below (proven — it broke the
# git-hooks case, which resolved hooks against the Windows .git instead of a
# fixture repo), where a plain path never can.
repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || repo_root=$(cd "$(dirname "$0")/../../.." && pwd)
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"  # HIMMEL-2350: shared winpath() -- dies loud on empty input/output instead of silently falling through to the operator's real home
probes_lib="$repo_root/scripts/himmelctl/lib/probes.js"
helpers_lib="$repo_root/scripts/himmelctl/lib/helpers.js"
manifest_path="$repo_root/scripts/install/manifest.json"
[ -f "$probes_lib" ] || { echo "FAIL: $probes_lib not found" >&2; exit 1; }
[ -f "$helpers_lib" ] || { echo "FAIL: $helpers_lib not found" >&2; exit 1; }
[ -f "$manifest_path" ] || { echo "FAIL: $manifest_path not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "FAIL: sha256sum required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

node_bin=$(command -v node)

# shellcheck source=lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$repo_root/scripts/lib/hermetic-path.sh"

work=$(mktemp -d)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

is_win32() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

# build_path <stub_dir> <present_tools...> -- <absent_tools...> (copied from
# the sibling suites: link the named present tools off the CURRENT PATH into
# <stub_dir>, then echo a PATH with the stub prepended and the named absent
# tools scrubbed).
build_path() {
  local _stub="$1"; shift
  local _present=() _absent=() _stage=0 _t
  for _t in "$@"; do
    if [ "$_t" = "--" ]; then _stage=1; continue; fi
    if [ "$_stage" -eq 0 ]; then _present+=("$_t"); else _absent+=("$_t"); fi
  done
  for _t in "${_present[@]}"; do
    link_hermetic_tool "$_t" "$_stub"
  done
  local _scrubbed="$PATH"
  if [ "${#_absent[@]}" -gt 0 ]; then
    _scrubbed=$(scrub_path "$PATH" "${_absent[@]}")
  fi
  printf '%s:%s' "$_stub" "$_scrubbed"
}

# snapshot_dir <dir> — sorted "relpath sha256" pairs, for a before/after
# byte-identity check that doesn't depend on tar's metadata quirks. Portable
# across bash 3.2 + BSD sort (no -z/-print0/xargs -0 on macOS's base sort).
snapshot_dir() {
  ( cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do sha256sum "$f"; done )
}

probes_lib_w="$(winpath "$probes_lib")"
helpers_lib_w="$(winpath "$helpers_lib")"
manifest_w="$(winpath "$manifest_path")"
repo_root_w="$(winpath "$repo_root")"

# HIMMEL-2289: a path under $work that is never created — pins HIMMELCTL_BASH
# to a genuinely unresolvable bash. A bare `env: { PATH: '' }` used to be
# enough to un-resolve bash for a spawn-error case, but resolveProbeBash()
# (probes.js) now falls through to resolveBash() (scripts/hooks/
# run-hook-with-bash.js), which also probes canonical Git-for-Windows
# locations on win32 (hardcoded, e.g. C:\Program Files\Git\bin\bash.exe) and
# /bin/bash, /usr/bin/bash on posix REGARDLESS of PATH — so an empty PATH
# alone is now vacuous on both platforms and no longer proves a spawn error.
no_such_bash_w="$(winpath "$work/no-such-bash/bash")"

# ── which() (helpers.js): key-PRESENCE, not truthiness — HIMMEL-1093 round 5
# CR fix (codex-1): `e.PATH || e.Path || ''` treated a DELIBERATELY scrubbed
# `PATH: ''` as falsy and fell through to `e.Path` — so a hermetic caller
# that explicitly empties PATH (to prove "nothing on it resolves") silently
# resolved from an inherited Windows `Path` instead, defeating the scrub.
# Proven directly against helpers.js (not through a probe), with a
# real-looking `Path` value present alongside the empty `PATH` — the exact
# shape that used to slip through.
whichEnvTest="$work/which-env-test-bin"; mkdir -p "$whichEnvTest"
: > "$whichEnvTest/probe-tool"
outWhichScrubbed=$("$node_bin" -e "
const { which } = require('$helpers_lib_w');
// PATH explicitly empty (the scrub); Path carries a REAL, resolvable dir —
// the pre-fix code would fall through to it and find 'probe-tool'.
const env = { PATH: '', Path: '$(winpath "$whichEnvTest")' };
console.log(JSON.stringify(which('probe-tool', env)));
")
echo "$outWhichScrubbed" | jq -e '. == null' >/dev/null \
  || fail "which(): an explicitly-empty PATH must NOT fall through to a present Path (got: $outWhichScrubbed)"
echo "ok: which() honors key-presence — a deliberately scrubbed PATH:'' is NOT treated as absent-so-fall-through-to-Path"

# ── which() positive control: Path alone (PATH key genuinely ABSENT) still
# resolves — proves the fix didn't just make which() always fail. ─────────
outWhichPathFallback=$("$node_bin" -e "
const { which } = require('$helpers_lib_w');
const env = { Path: '$(winpath "$whichEnvTest")' };
console.log(JSON.stringify(which('probe-tool', env)));
")
echo "$outWhichPathFallback" | jq -e '. != null' >/dev/null \
  || fail "which(): PATH key genuinely absent should still fall back to Path (got: $outWhichPathFallback)"
echo "ok: which() — PATH key genuinely absent still falls back to Path (the fallback itself still works)"

# ── file-exists: targetPath-relative (guardrail-scope) ──────────────────────
feA_present="$work/feA-present"; mkdir -p "$feA_present/scripts/guardrails"
: > "$feA_present/scripts/guardrails/lib.sh"
feA_absent="$work/feA-absent"; mkdir -p "$feA_absent"

outA1=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'guardrail-scope');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$(winpath "$feA_present")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outA1" | jq -e '.actual == "present"' >/dev/null || fail "file-exists targetPath-relative present: (got: $outA1)"
outA2=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'guardrail-scope');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$(winpath "$feA_absent")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outA2" | jq -e '.actual == "absent"' >/dev/null || fail "file-exists targetPath-relative absent: (got: $outA2)"
echo "ok: file-exists targetPath-relative (guardrail-scope) present/absent"

# ── file-exists: repoRoot-relative exception (jira-cli-dist-build) ─────────
# The target ALSO carries the file, at the identical relative path — proves
# the probe resolves against repoRoot, not targetPath, for this item.
feB_repo_absent="$work/feB-repo-absent"; mkdir -p "$feB_repo_absent"
feB_repo_present="$work/feB-repo-present"; mkdir -p "$feB_repo_present/scripts/jira/dist"
: > "$feB_repo_present/scripts/jira/dist/index.js"
feB_target_with_file="$work/feB-target"; mkdir -p "$feB_target_with_file/scripts/jira/dist"
: > "$feB_target_with_file/scripts/jira/dist/index.js"

outB1=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'jira-cli-dist-build');
const ctx = { repoRoot: '$(winpath "$feB_repo_absent")', targetPath: '$(winpath "$feB_target_with_file")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outB1" | jq -e '.actual == "absent"' >/dev/null \
  || fail "file-exists repoRoot-relative exception: expected absent (repoRoot lacks the file even though targetPath has it) (got: $outB1)"
outB2=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'jira-cli-dist-build');
const ctx = { repoRoot: '$(winpath "$feB_repo_present")', targetPath: '$(winpath "$work/feB-nonexistent-target")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outB2" | jq -e '.actual == "present"' >/dev/null \
  || fail "file-exists repoRoot-relative exception: expected present (repoRoot has the file; targetPath doesn't exist at all) (got: $outB2)"
echo "ok: file-exists repoRoot-relative exception (jira-cli-dist-build) ignores targetPath"

# ── git-hooks: all configured pre-commit hook types ────────────────────────
hooks_repo="$work/hooks-repo"; mkdir -p "$hooks_repo/.git/hooks"
hooks_common="$work/hooks-common"; mkdir -p "$hooks_common/hooks" "$hooks_common/worktrees/dev"
printf '../..\n' > "$hooks_common/worktrees/dev/commondir"
hooks_linked="$work/hooks-linked"; mkdir -p "$hooks_linked"
printf 'gitdir: %s\n' "$(winpath "$hooks_common/worktrees/dev")" > "$hooks_linked/.git"

probe_hooks() {
  local _target="$1"
  "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'pre-commit-hooks');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$(winpath "$_target")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
"
}

outHooksAbsent=$(probe_hooks "$hooks_repo")
echo "$outHooksAbsent" | jq -e '.actual == "absent"' >/dev/null \
  || fail "git-hooks none installed should read absent: (got: $outHooksAbsent)"
echo "$outHooksAbsent" | jq -e '.detail | contains("pre-commit") and contains("commit-msg") and contains("pre-push")' >/dev/null \
  || fail "git-hooks absent detail should name all missing hook types: (got: $outHooksAbsent)"

printf '#!/usr/bin/env bash\nexit 0\n' > "$hooks_repo/.git/hooks/pre-commit"
chmod +x "$hooks_repo/.git/hooks/pre-commit"
outHooksPartial=$(probe_hooks "$hooks_repo")
echo "$outHooksPartial" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "git-hooks partial install should read degraded: (got: $outHooksPartial)"
echo "$outHooksPartial" | jq -e '.detail | contains("commit-msg") and contains("pre-push")' >/dev/null \
  || fail "git-hooks partial detail should name the two missing hook types: (got: $outHooksPartial)"

for _hook in pre-commit commit-msg pre-push; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$hooks_common/hooks/$_hook"
  chmod +x "$hooks_common/hooks/$_hook"
done
outHooksPresent=$(probe_hooks "$hooks_linked")
echo "$outHooksPresent" | jq -e '.actual == "present"' >/dev/null \
  || fail "git-hooks linked-worktree commondir with all hooks should read present: (got: $outHooksPresent)"
echo "$outHooksPresent" | jq -e '.detail | contains("pre-commit, commit-msg, pre-push")' >/dev/null \
  || fail "git-hooks present detail should attest all configured hook types: (got: $outHooksPresent)"
echo "ok: git-hooks verifies absent/partial/all-three states and linked-worktree commondir resolution"

# ── git-hooks: core.hooksPath override (HIMMEL-1470) ───────────────────────
# A legitimate LOCAL `git config core.hooksPath <dir>` (the in-repo layout
# check-commit-msg.ps1 documents and check-hookspath validates) must resolve at
# that dir, NOT fall through to .git/hooks (left intentionally empty here) and
# read a false absent.
hooks_hp_repo="$work/hooks-hp-repo"; mkdir -p "$hooks_hp_repo/custom-hooks"
( cd "$hooks_hp_repo" && git init -q && git config core.hooksPath custom-hooks )
for _hook in pre-commit commit-msg pre-push; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$hooks_hp_repo/custom-hooks/$_hook"
  chmod +x "$hooks_hp_repo/custom-hooks/$_hook"
done
outHooksHP=$(probe_hooks "$hooks_hp_repo")
echo "$outHooksHP" | jq -e '.actual == "present"' >/dev/null \
  || fail "git-hooks core.hooksPath override should read present (got: $outHooksHP)"
echo "$outHooksHP" | jq -e '.detail | contains("custom-hooks")' >/dev/null \
  || fail "git-hooks core.hooksPath detail should name the configured dir (got: $outHooksHP)"
echo "ok: git-hooks honors a local core.hooksPath override instead of defaulting to .git/hooks (HIMMEL-1470)"

# ── file-exists: {vaultPath} placeholder (luna-vault-scaffold) ─────────────
feC_present="$work/feC-vault-present"; mkdir -p "$feC_present"
: > "$feC_present/.vault-template.json"
feC_absent="$work/feC-vault-absent"; mkdir -p "$feC_absent"

outC1=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'luna-vault-scaffold');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$(winpath "$feC_present")', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outC1" | jq -e '.actual == "present"' >/dev/null || fail "file-exists {vaultPath} present: (got: $outC1)"
outC2=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'luna-vault-scaffold');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$(winpath "$feC_absent")', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outC2" | jq -e '.actual == "absent"' >/dev/null || fail "file-exists {vaultPath} absent: (got: $outC2)"
echo "ok: file-exists {vaultPath} placeholder (luna-vault-scaffold) present/absent"

# ── settings-key: dot-path single key (wiring-statusline) ─────────────────
sk1_present="$work/sk1-present"; mkdir -p "$sk1_present/.claude"
printf '{"statusLine":{"command":"bash foo.sh"}}' > "$sk1_present/.claude/settings.json"
sk1_absent="$work/sk1-absent"; mkdir -p "$sk1_absent/.claude"
printf '{"statusLine":{}}' > "$sk1_absent/.claude/settings.json"

outSK1p=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'wiring-statusline');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$(winpath "$sk1_present")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outSK1p" | jq -e '.actual == "present"' >/dev/null || fail "settings-key dot-path present: (got: $outSK1p)"
outSK1a=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'wiring-statusline');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$(winpath "$sk1_absent")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outSK1a" | jq -e '.actual == "absent"' >/dev/null || fail "settings-key dot-path absent: (got: $outSK1a)"
echo "ok: settings-key dot-path single key (wiring-statusline) present/absent"

# ── settings-key: simple non-dotted key (claude-plugins-pluginSet) ─────────
sk2_present="$work/sk2-present"; mkdir -p "$sk2_present/.claude"
printf '{"enabledPlugins":{"foo@bar":true}}' > "$sk2_present/.claude/settings.json"
sk2_absent="$work/sk2-absent"; mkdir -p "$sk2_absent/.claude"
printf '{"enabledPlugins":{}}' > "$sk2_absent/.claude/settings.json"

outSK2p=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'claude-plugins-pluginSet');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$(winpath "$sk2_present")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outSK2p" | jq -e '.actual == "present"' >/dev/null || fail "settings-key simple key present: (got: $outSK2p)"
outSK2a=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'claude-plugins-pluginSet');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$(winpath "$sk2_absent")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outSK2a" | jq -e '.actual == "absent"' >/dev/null || fail "settings-key simple key absent (empty object): (got: $outSK2a)"
echo "ok: settings-key simple non-dotted key (claude-plugins-pluginSet) present/absent"

# ── settings-key: .env ALL-keys-required union (jira-env-keys) ────────────
# Resolves against repoRoot for BOTH scopes (CLAUDE.md / adopt.sh
# fill_env_core convention) — proven by using scope 'user' here too.
sk3_repo_present="$work/sk3-repo-present"; mkdir -p "$sk3_repo_present"
cat > "$sk3_repo_present/.env" <<'ENV'
JIRA_BASE_URL=https://example.atlassian.net
JIRA_EMAIL=me@example.com
JIRA_API_TOKEN=tok123
JIRA_PROJECT_KEY=HIMMEL
ENV
sk3_repo_missing="$work/sk3-repo-missing"; mkdir -p "$sk3_repo_missing"
cat > "$sk3_repo_missing/.env" <<'ENV'
JIRA_BASE_URL=https://example.atlassian.net
JIRA_EMAIL=me@example.com
JIRA_PROJECT_KEY=HIMMEL
ENV

outSK3p=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'jira-env-keys');
const ctx = { repoRoot: '$(winpath "$sk3_repo_present")', targetPath: '$repo_root_w', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outSK3p" | jq -e '.actual == "present"' >/dev/null || fail "settings-key .env all-keys present: (got: $outSK3p)"
outSK3a=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'jira-env-keys');
const ctx = { repoRoot: '$(winpath "$sk3_repo_missing")', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outSK3a" | jq -e '.actual == "absent"' >/dev/null || fail "settings-key .env missing-one-key absent: (got: $outSK3a)"
echo "$outSK3a" | jq -e '.detail | contains("JIRA_API_TOKEN")' >/dev/null \
  || fail "settings-key .env absent detail should name the missing key JIRA_API_TOKEN (got: $outSK3a)"
echo "ok: settings-key .env ALL-keys-required (jira-env-keys), resolves against repoRoot for both scopes"

# ── settings-hooks: present (3/3) / degraded (1/3) / absent (0) ────────────
sh_present="$work/sh-present"; mkdir -p "$sh_present/.claude"
cat > "$sh_present/.claude/settings.json" <<'JSON'
{"hooks":{"PreToolUse":[
  {"matcher":"Bash","hooks":[{"type":"command","command":"bash \"/x/scripts/hooks/auto-approve-safe-bash.sh\""}]},
  {"matcher":"Edit","hooks":[{"type":"command","command":"bash \"/x/scripts/hooks/block-edit-on-main.sh\""}]},
  {"matcher":"Read","hooks":[{"type":"command","command":"bash \"/x/scripts/hooks/block-read-secrets.sh\""}]}
]}}
JSON
sh_degraded="$work/sh-degraded"; mkdir -p "$sh_degraded/.claude"
cat > "$sh_degraded/.claude/settings.json" <<'JSON'
{"hooks":{"PreToolUse":[
  {"matcher":"Bash","hooks":[{"type":"command","command":"bash \"/x/scripts/hooks/auto-approve-safe-bash.sh\""}]}
]}}
JSON
sh_absent="$work/sh-absent"; mkdir -p "$sh_absent/.claude"
printf '{"hooks":{"PreToolUse":[]}}' > "$sh_absent/.claude/settings.json"

outSHp=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'wiring-pretooluse');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$(winpath "$sh_present")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outSHp" | jq -e '.actual == "present"' >/dev/null || fail "settings-hooks present (3/3): (got: $outSHp)"
outSHd=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'wiring-pretooluse');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$(winpath "$sh_degraded")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outSHd" | jq -e '.actual == "degraded"' >/dev/null || fail "settings-hooks degraded (1/3): (got: $outSHd)"
echo "$outSHd" | jq -e '.detail | contains("block-edit-on-main")' >/dev/null \
  || fail "settings-hooks degraded detail should name a missing marker (got: $outSHd)"
outSHa=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'wiring-pretooluse');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$(winpath "$sh_absent")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outSHa" | jq -e '.actual == "absent"' >/dev/null || fail "settings-hooks absent (0/3): (got: $outSHa)"
echo "ok: settings-hooks (wiring-pretooluse) present/degraded/absent"

# ── cmd:has_qmd (qmd-binary) ────────────────────────────────────────────────
hq_present_stub="$work/hq-present-bin"; mkdir -p "$hq_present_stub"
pathHQpresent=$(build_path "$hq_present_stub" bash git jq -- bun)
cat > "$hq_present_stub/qmd" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$hq_present_stub/qmd"

outHQp=$(PATH="$pathHQpresent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'qmd-binary');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHQp" | jq -e '.actual == "present"' >/dev/null || fail "cmd:has_qmd present: (got: $outHQp)"

hq_absent_stub="$work/hq-absent-bin"; mkdir -p "$hq_absent_stub"
pathHQabsent=$(build_path "$hq_absent_stub" bash git jq -- bun qmd)
outHQa=$(PATH="$pathHQabsent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'qmd-binary');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHQa" | jq -e '.actual == "absent"' >/dev/null || fail "cmd:has_qmd absent: (got: $outHQa)"
echo "ok: cmd:has_qmd (qmd-binary) present/absent"

# ── qmd-index: present (4/4) / degraded (2/4) / absent (no qmd) ───────────
qi_present_stub="$work/qi-present-bin"; mkdir -p "$qi_present_stub"
pathQIpresent=$(build_path "$qi_present_stub" bash git jq -- bun)
cat > "$qi_present_stub/qmd" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "collection" ] && [ "$2" = "list" ]; then
  printf 'himmel\nluna\n'
  exit 0
fi
exit 0
STUB
chmod +x "$qi_present_stub/qmd"
outQIp=$(PATH="$pathQIpresent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'qmd-index');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outQIp" | jq -e '.actual == "present"' >/dev/null || fail "qmd-index present (4/4): (got: $outQIp)"

qi_degraded_stub="$work/qi-degraded-bin"; mkdir -p "$qi_degraded_stub"
pathQIdegraded=$(build_path "$qi_degraded_stub" bash git jq -- bun)
cat > "$qi_degraded_stub/qmd" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = "collection" ] && [ "$2" = "list" ]; then
  printf 'himmel\n'
  exit 0
fi
exit 0
STUB
chmod +x "$qi_degraded_stub/qmd"
outQId=$(PATH="$pathQIdegraded" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'qmd-index');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outQId" | jq -e '.actual == "degraded"' >/dev/null || fail "qmd-index degraded (2/4): (got: $outQId)"
echo "$outQId" | jq -e '.detail | contains("luna")' >/dev/null \
  || fail "qmd-index degraded detail should name a missing collection (got: $outQId)"

qi_absent_stub="$work/qi-absent-bin"; mkdir -p "$qi_absent_stub"
pathQIabsent=$(build_path "$qi_absent_stub" bash git jq -- bun qmd)
outQIa=$(PATH="$pathQIabsent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'qmd-index');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outQIa" | jq -e '.actual == "absent"' >/dev/null || fail "qmd-index absent (no qmd on PATH): (got: $outQIa)"
echo "ok: qmd-index present/degraded/absent"

# ── mcp-registered: present / server missing / file missing / malformed ────
# HIMMEL-1093 round 3: the registered entry's OWN `command` is now ALWAYS
# validated (codex-adv-1) — the fixture's registered command must actually
# resolve for the 'present' case, so it points at a real stub FILE by
# absolute path (fs.existsSync, not PATH-dependent).
mcp_present_home="$work/mcp-present-home"; mkdir -p "$mcp_present_home"
: > "$mcp_present_home/tokensave-mcp-stub"
chmod +x "$mcp_present_home/tokensave-mcp-stub"
printf '{"mcpServers":{"tokensave":{"command":"%s"}}}' "$(winpath "$mcp_present_home/tokensave-mcp-stub")" > "$mcp_present_home/.claude.json"
mcp_server_missing_home="$work/mcp-server-missing-home"; mkdir -p "$mcp_server_missing_home"
printf '{"mcpServers":{"graphify":{"command":"graphify-mcp"}}}' > "$mcp_server_missing_home/.claude.json"
mcp_file_missing_home="$work/mcp-file-missing-home"; mkdir -p "$mcp_file_missing_home"
mcp_null_root_home="$work/mcp-null-root-home"; mkdir -p "$mcp_null_root_home"
printf 'null' > "$mcp_null_root_home/.claude.json"
# CR fix (HIMMEL-1017 CR round): a present-but-UNPARSEABLE config is a
# genuinely different case from a MISSING one — both used to read identically
# (actual:absent, generic "cannot read/parse" detail); configError now
# distinguishes them (see probes.js's probeMcpRegistered).
mcp_malformed_json_home="$work/mcp-malformed-json-home"; mkdir -p "$mcp_malformed_json_home"
printf '{not valid json' > "$mcp_malformed_json_home/.claude.json"

outMCP=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
// A SYNTHETIC descriptor (registration only, no bin/initMarker) — this block
// pins the pre-HIMMEL-1093 registration matrix (present/server-missing/
// file-missing/malformed/configError) in isolation from the HIMMEL-1093
// bin/initMarker deepening, which gets its own dedicated block below against
// the REAL tokensave-mcp descriptor.
const item = { id: 'tokensave-mcp', probe: { type: 'mcp-registered', server: 'tokensave' } };
const probeHome = (home) => runProbe(item, {
  repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: home }),
});
console.log(JSON.stringify([
  probeHome('$(winpath "$mcp_present_home")'),
  probeHome('$(winpath "$mcp_server_missing_home")'),
  probeHome('$(winpath "$mcp_file_missing_home")'),
  probeHome('$(winpath "$mcp_null_root_home")'),
  probeHome('$(winpath "$mcp_malformed_json_home")'),
]));
")
echo "$outMCP" | jq -e '.[0].actual == "present" and .[1].actual == "absent" and .[2].actual == "absent" and .[3].actual == "absent" and .[4].actual == "absent"' >/dev/null \
  || fail "mcp-registered present/server-missing/file-missing/null-root/malformed: (got: $outMCP)"
echo "$outMCP" | jq -e '.[2].detail | contains("does not exist")' >/dev/null \
  || fail "mcp-registered file-missing (ENOENT) detail should report 'does not exist' (got: $outMCP)"
echo "$outMCP" | jq -e '.[3].detail | contains("unexpected JSON shape")' >/dev/null \
  || fail "mcp-registered null-root detail should report unexpected JSON shape (got: $outMCP)"
echo "$outMCP" | jq -e '.[4].detail | contains("cannot read/parse")' >/dev/null \
  || fail "mcp-registered malformed-JSON detail should report cannot read/parse (got: $outMCP)"
# CR fix (HIMMEL-1017 CR round): configError distinguishes a genuinely BROKEN
# config (malformed JSON, unexpected shape) from a clean absence (present-
# but-server-missing, OR the file simply doesn't exist yet — ENOENT is the
# ORDINARY case for project-scope .mcp.json, never an error by itself).
echo "$outMCP" | jq -e '(.[0].configError // false) == false and (.[1].configError // false) == false and (.[2].configError // false) == false' >/dev/null \
  || fail "mcp-registered present/server-missing/file-missing (ENOENT) should carry NO configError (got: $outMCP)"
echo "$outMCP" | jq -e '.[3].configError == true and .[4].configError == true' >/dev/null \
  || fail "mcp-registered null-root/malformed-JSON should carry configError:true (got: $outMCP)"
echo "ok: mcp-registered (tokensave-mcp) present/server-missing/file-missing/null-root/malformed via ctx.env.HOME, configError distinguishes broken config from clean absence"

# ── mcp-registered: scope-aware file resolution (CR fix, HIMMEL-1017 round) ─
# project scope reads <targetPath>/.mcp.json, NOT ~/.claude.json — proven in
# both directions: a project-scope registration in .mcp.json reads present
# even with a DIFFERENT server registered in ~/.claude.json (never bleeds
# across scopes), and a user-scope-only registration is correctly invisible
# to a project-scope probe.
mcp_project_target="$work/mcp-project-target"; mkdir -p "$mcp_project_target"
: > "$mcp_project_target/graphify-mcp-stub"
chmod +x "$mcp_project_target/graphify-mcp-stub"
printf '{"mcpServers":{"graphify":{"command":"%s"}}}' "$(winpath "$mcp_project_target/graphify-mcp-stub")" > "$mcp_project_target/.mcp.json"
mcp_scope_home="$work/mcp-scope-home"; mkdir -p "$mcp_scope_home"
printf '{"mcpServers":{"tokensave":{"command":"tokensave-mcp"}}}' > "$mcp_scope_home/.claude.json"

outScope=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
// Synthetic descriptor again (see the outMCP comment above) — isolates the
// scope-resolution behavior from the HIMMEL-1093 bin deepening on the REAL
// graphify-mcp item.
const graphifyItem = { id: 'graphify-mcp', probe: { type: 'mcp-registered', server: 'graphify' } };
const env = Object.assign({}, process.env, { HOME: '$(winpath "$mcp_scope_home")' });
const projectHit = runProbe(graphifyItem, { repoRoot: '$repo_root_w', targetPath: '$(winpath "$mcp_project_target")', scope: 'project', env });
const userMiss = runProbe(graphifyItem, { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env });
console.log(JSON.stringify({ projectHit, userMiss }));
")
echo "$outScope" | jq -e '.projectHit.actual == "present"' >/dev/null \
  || fail "mcp-registered project-scope should read <targetPath>/.mcp.json, not ~/.claude.json (got: $outScope)"
echo "$outScope" | jq -e '.userMiss.actual == "absent"' >/dev/null \
  || fail "mcp-registered user-scope probe for graphify should NOT see the project-scope .mcp.json registration (got: $outScope)"
echo "ok: mcp-registered is scope-aware — project scope resolves .mcp.json, user scope resolves ~/.claude.json, never cross-bleeding"

# ── mcp-registered: HIMMEL-1093 deepening (bin + initMarker) ───────────────
# Registration alone used to read 'present' even when the wrapped binary is
# gone or the consuming project was never initialized — a registered-but-
# broken server looked identical to a working one. Proven against the REAL
# tokensave-mcp descriptor (bin:"tokensave" + initMarker:".tokensave"), so a
# manifest authoring drift on these fields breaks this suite too. The
# registered command itself is pinned to an absolute-path stub that always
# resolves (round 3's unconditional registered-command check — see below —
# is not what this block is isolating; it only wants bin/initMarker to be
# the thing that varies across the three sub-cases).
mcp_deep_home="$work/mcp-deep-home"; mkdir -p "$mcp_deep_home"
: > "$mcp_deep_home/tokensave-mcp-stub"
chmod +x "$mcp_deep_home/tokensave-mcp-stub"
printf '{"mcpServers":{"tokensave":{"command":"%s"}}}' "$(winpath "$mcp_deep_home/tokensave-mcp-stub")" > "$mcp_deep_home/.claude.json"
mcp_deep_target_init="$work/mcp-deep-target-init"; mkdir -p "$mcp_deep_target_init/.tokensave"
mcp_deep_target_noinit="$work/mcp-deep-target-noinit"; mkdir -p "$mcp_deep_target_noinit"

deep_bin_present="$work/deep-bin-present"; mkdir -p "$deep_bin_present"
pathDeepPresent=$(build_path "$deep_bin_present" bash git jq -- tokensave)
cat > "$deep_bin_present/tokensave" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$deep_bin_present/tokensave"

deep_bin_absent="$work/deep-bin-absent"; mkdir -p "$deep_bin_absent"
pathDeepAbsent=$(build_path "$deep_bin_absent" bash git jq -- tokensave)

outDeepP=$(PATH="$pathDeepPresent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'tokensave-mcp');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$(winpath "$mcp_deep_target_init")', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$mcp_deep_home")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outDeepP" | jq -e '.actual == "present"' >/dev/null \
  || fail "mcp-registered deepened (tokensave-mcp) fully satisfied (bin resolvable + .tokensave present) should read present: (got: $outDeepP)"

outDeepBinMissing=$(PATH="$pathDeepAbsent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'tokensave-mcp');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$(winpath "$mcp_deep_target_init")', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$mcp_deep_home")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outDeepBinMissing" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "mcp-registered deepened (tokensave-mcp) missing binary should read degraded, not present: (got: $outDeepBinMissing)"
echo "$outDeepBinMissing" | jq -e '.detail | contains("not resolvable on PATH")' >/dev/null \
  || fail "mcp-registered deepened missing-bin detail should name the unresolved binary (got: $outDeepBinMissing)"

outDeepNoInit=$(PATH="$pathDeepPresent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'tokensave-mcp');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$(winpath "$mcp_deep_target_noinit")', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$mcp_deep_home")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outDeepNoInit" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "mcp-registered deepened (tokensave-mcp) missing initMarker (no .tokensave/ in target) should read degraded: (got: $outDeepNoInit)"
echo "$outDeepNoInit" | jq -e '.detail | contains("project not initialized")' >/dev/null \
  || fail "mcp-registered deepened missing-initMarker detail should name it (got: $outDeepNoInit)"
echo "ok: mcp-registered deepening (HIMMEL-1093) — registered-but-broken (unresolved bin / uninitialized project) reads degraded, never silently present"

# ── mcp-registered: bin check honors ctx.env, not just process.env ─────────
# CR fix (HIMMEL-1093 round 2, codex-2): which(item.probe.bin) used to read
# process.env.PATH directly, ignoring ctx.env entirely — a hermetic caller
# that already threads a fully-controlled ctx.env (this probe reads
# ctx.env.HOME for its own file resolution) got a WRONG answer if ctx.env's
# PATH differed from the real process env. Proven by DIVERGING the two: the
# OUTER shell's PATH is scrubbed of any real `tokensave` (so node's own
# process.env.PATH, inherited unmodified, cannot resolve it), while ctx.env
# is built with an EXTRA stub dir prepended that process.env.PATH lacks —
# only a fix that actually reads ctx.env.PATH (not process.env.PATH) resolves
# it as present.
deep_bin_ctxonly="$work/deep-bin-ctxonly"; mkdir -p "$deep_bin_ctxonly"
cat > "$deep_bin_ctxonly/tokensave" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$deep_bin_ctxonly/tokensave"
scrub_stub="$work/scrub-stub-bin"; mkdir -p "$scrub_stub"
pathScrubbedOfTokensave=$(build_path "$scrub_stub" bash git jq -- tokensave)
outDeepCtxEnvPath=$(PATH="$pathScrubbedOfTokensave" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'tokensave-mcp');
// ctx.env.PATH carries an EXTRA stub dir process.env.PATH does not.
const ctxOnlyPath = '$(winpath "$deep_bin_ctxonly")' + require('path').delimiter + process.env.PATH;
const ctx = { repoRoot: '$repo_root_w', targetPath: '$(winpath "$mcp_deep_target_init")', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$mcp_deep_home")', PATH: ctxOnlyPath }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outDeepCtxEnvPath" | jq -e '.actual == "present"' >/dev/null \
  || fail "mcp-registered bin check should resolve via ctx.env.PATH (not just process.env.PATH, which lacks the stub here): (got: $outDeepCtxEnvPath)"
echo "ok: mcp-registered bin check honors ctx.env.PATH for a hermetic caller with a fully-controlled env, diverging from process.env.PATH"

# ── mcp-registered: the REGISTERED command itself must resolve ─────────────
# CR fix (HIMMEL-1093 round 3, codex-adv-1, high): a descriptor-named `bin`
# is a GUESS at what the MCP server wraps — it can name the WRONG binary
# entirely (found live: graphify's real registered command is the MCP
# entrypoint graphify-mcp[.exe], not the bare `graphify` CLI the old
# descriptor checked). The registered entry's OWN `command` is now ALWAYS
# validated, unconditionally, with no descriptor opt-in — using a SYNTHETIC
# descriptor (server only, no bin/initMarker) to isolate this from the
# bin/initMarker deepening tested above.
mcpCmdItem() {
  cat <<'JS'
const item = { id: 'cmd-check', probe: { type: 'mcp-registered', server: 'srv' } };
JS
}

# absolute path, resolves (fs.existsSync) -> present.
mcpcmd_abs_home="$work/mcpcmd-abs-home"; mkdir -p "$mcpcmd_abs_home"
: > "$mcpcmd_abs_home/entrypoint-stub"
chmod +x "$mcpcmd_abs_home/entrypoint-stub"
printf '{"mcpServers":{"srv":{"command":"%s"}}}' "$(winpath "$mcpcmd_abs_home/entrypoint-stub")" > "$mcpcmd_abs_home/.claude.json"
outCmdAbs=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
$(mcpCmdItem)
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$mcpcmd_abs_home")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outCmdAbs" | jq -e '.actual == "present"' >/dev/null \
  || fail "mcp-registered: an absolute registered command that exists should read present: (got: $outCmdAbs)"

# absolute path, does NOT exist -> degraded, naming the configured command.
mcpcmd_abs_missing_home="$work/mcpcmd-abs-missing-home"; mkdir -p "$mcpcmd_abs_missing_home"
missingAbsCmd="$(winpath "$mcpcmd_abs_missing_home")/does-not-exist-entrypoint"
printf '{"mcpServers":{"srv":{"command":"%s"}}}' "$missingAbsCmd" > "$mcpcmd_abs_missing_home/.claude.json"
outCmdAbsMissing=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
$(mcpCmdItem)
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$mcpcmd_abs_missing_home")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outCmdAbsMissing" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "mcp-registered: an absolute registered command that does NOT exist should read degraded (got: $outCmdAbsMissing)"
echo "$outCmdAbsMissing" | jq -e '.detail | contains("does not resolve")' >/dev/null \
  || fail "mcp-registered: nonexistent-command detail should say it does not resolve (got: $outCmdAbsMissing)"

# bare name, resolves via PATH (which()) -> present. Reuses the deep-bin
# stub dir from the bin/initMarker block above (already has 'tokensave').
mcpcmd_bare_home="$work/mcpcmd-bare-home"; mkdir -p "$mcpcmd_bare_home"
printf '{"mcpServers":{"srv":{"command":"tokensave"}}}' > "$mcpcmd_bare_home/.claude.json"
outCmdBare=$(PATH="$pathDeepPresent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
$(mcpCmdItem)
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$mcpcmd_bare_home")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outCmdBare" | jq -e '.actual == "present"' >/dev/null \
  || fail "mcp-registered: a bare registered command resolvable via PATH should read present: (got: $outCmdBare)"

# bare name, NOT on PATH -> degraded.
outCmdBareMissing=$(PATH="$pathDeepAbsent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
$(mcpCmdItem)
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$mcpcmd_bare_home")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outCmdBareMissing" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "mcp-registered: a bare registered command NOT on PATH should read degraded: (got: $outCmdBareMissing)"

# null/missing command -> degraded, naming the gap (not a crash).
mcpcmd_null_home="$work/mcpcmd-null-home"; mkdir -p "$mcpcmd_null_home"
printf '{"mcpServers":{"srv":{"command":null}}}' > "$mcpcmd_null_home/.claude.json"
outCmdNull=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
$(mcpCmdItem)
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$mcpcmd_null_home")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outCmdNull" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "mcp-registered: a null registered command should read degraded, not crash: (got: $outCmdNull)"
echo "$outCmdNull" | jq -e '.detail | contains("no usable command")' >/dev/null \
  || fail "mcp-registered: null-command detail should say no usable command (got: $outCmdNull)"

mcpcmd_no_command_home="$work/mcpcmd-no-command-home"; mkdir -p "$mcpcmd_no_command_home"
printf '{"mcpServers":{"srv":{}}}' > "$mcpcmd_no_command_home/.claude.json"
outCmdNone=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
$(mcpCmdItem)
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$mcpcmd_no_command_home")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outCmdNone" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "mcp-registered: a registered entry with NO command field should read degraded: (got: $outCmdNone)"
echo "ok: mcp-registered — the registered entry's OWN command is validated (absolute-path resolution / bare-name PATH lookup), unconditionally; a wrong, missing, or nonexistent command reads degraded, never silently present"

# SKIP NOTE (HIMMEL-1093 round 5, codex-2): registeredCommandCheck()'s POSIX
# branch (fs.accessSync(cmd, X_OK) distinguishing "exists but not executable"
# from "does not exist") is gated behind `process.platform === 'win32'` and
# so is STRUCTURALLY UNREACHABLE on this dev/CI machine (win32) — the outCmdAbs/
# outCmdAbsMissing cases above already exercise the win32 existsSync branch
# (unchanged from round 3) for both the resolve/does-not-resolve outcomes,
# but the executability distinction itself has no path to run here. Per the
# CR's own guidance, this is a comment+skip note rather than a fake test:
# stubbing process.platform to force the POSIX branch on a win32 CI runner
# would test a code path that can never actually execute on this box (a
# platform hack producing a false sense of coverage, not a real one). The
# logic itself is a 6-line try/catch around a single documented Node API
# (fs.accessSync + fs.constants.X_OK) with no himmel-specific branching to
# get wrong; real coverage should come from a POSIX runner in CI/a Linux dev
# box, not a Windows-side simulation.

# ── graphify-mcp: bin field DROPPED, relying on the registered-command
# check alone (least-redundant design — see manifest.json's comment on this
# item). Proven live: the REAL server registered under a bare "graphify-mcp"
# name (the actual entrypoint) reads present without any bin field at all.
gmcp_home="$work/gmcp-home"; mkdir -p "$gmcp_home"
printf '{"mcpServers":{"graphify":{"command":"graphify-mcp-entry"}}}' > "$gmcp_home/.claude.json"
gmcp_bin_dir="$work/gmcp-bin"; mkdir -p "$gmcp_bin_dir"
pathGmcp=$(build_path "$gmcp_bin_dir" bash git jq -- graphify-mcp-entry)
cat > "$gmcp_bin_dir/graphify-mcp-entry" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$gmcp_bin_dir/graphify-mcp-entry"
outGmcp=$(PATH="$pathGmcp" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'graphify-mcp');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$gmcp_home")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGmcp" | jq -e '.actual == "present"' >/dev/null \
  || fail "graphify-mcp (no bin field): registered command resolvable via PATH should read present on the registered-command check alone: (got: $outGmcp)"
echo "ok: graphify-mcp's dropped bin field is redundant — the registered-command check alone correctly validates its REAL entrypoint"

# ── handover-dir (handover-wiring) ──────────────────────────────────────────
# HIMMEL-2298: these two cases run the REAL scripts/lib/handover-path.sh
# against the real checkout, and that resolver is slow on Windows — measured
# 4.8-13.0s wall for 1.2s of user time, i.e. MSYS syscall-bound rather than
# blocked on anything. Under this suite's OWN load (it spawns hundreds of bash
# processes) it has been seen to exceed even the 60s family budget, which made
# these long-standing cases latently flaky: they assert WIRING, not latency, so
# a slow host must not turn them red. Pin a generous-but-bounded budget via
# HIMMELCTL_PROBE_TIMEOUT_SECS — a genuine hang still fails them. The
# underlying resolver latency is HIMMEL-2312, not a budget problem.
hd_present_dir="$work/hd-present-handoverdir"; mkdir -p "$hd_present_dir"
outHDp=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'handover-wiring');
const env = Object.assign({}, process.env, { HANDOVER_DIR: '$(winpath "$hd_present_dir")', HIMMELCTL_PROBE_TIMEOUT_SECS: '180' });
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'project', env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHDp" | jq -e '.actual == "present"' >/dev/null || fail "handover-dir present (HANDOVER_DIR set via ctx.env): (got: $outHDp)"

hd_absent_cwd="$work/hd-absent-not-a-repo"; mkdir -p "$hd_absent_cwd"
outHDa=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'handover-wiring');
const env = Object.assign({}, process.env, { HIMMELCTL_PROBE_TIMEOUT_SECS: '180' });
delete env.HANDOVER_DIR;
const ctx = { repoRoot: '$(winpath "$hd_absent_cwd")', targetPath: '$(winpath "$hd_absent_cwd")', scope: 'project', env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHDa" | jq -e '.actual == "absent"' >/dev/null \
  || fail "handover-dir absent (HANDOVER_DIR unset, cwd not a git repo, no inline handovers/): (got: $outHDa)"
echo "ok: handover-dir (handover-wiring) present/absent, exercising ctx.env pass-through"

# ── dep: single-cmd (rtk) ────────────────────────────────────────────────────
dep_present_stub="$work/dep-present-bin"; mkdir -p "$dep_present_stub"
pathDeppresent=$(build_path "$dep_present_stub" bash git jq -- rtk)
cat > "$dep_present_stub/rtk" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$dep_present_stub/rtk"
outDepP=$(PATH="$pathDeppresent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'rtk');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outDepP" | jq -e '.actual == "present"' >/dev/null || fail "dep single-cmd (rtk) present: (got: $outDepP)"

dep_absent_stub="$work/dep-absent-bin"; mkdir -p "$dep_absent_stub"
pathDepabsent=$(build_path "$dep_absent_stub" bash git jq -- rtk)
outDepA=$(PATH="$pathDepabsent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'rtk');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outDepA" | jq -e '.actual == "absent"' >/dev/null || fail "dep single-cmd (rtk) absent: (got: $outDepA)"
echo "ok: dep single-cmd (rtk) present/absent"

# ── dep: win32/posix platform union (scheduler-backend) ────────────────────
if is_win32; then sched_name="schtasks"; else sched_name="at"; fi

dep_sched_present="$work/dep-sched-present-bin"; mkdir -p "$dep_sched_present"
pathSchedPresent=$(build_path "$dep_sched_present" bash git jq -- "$sched_name")
cat > "$dep_sched_present/$sched_name" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$dep_sched_present/$sched_name"
outSchedP=$(PATH="$pathSchedPresent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'scheduler-backend');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outSchedP" | jq -e '.actual == "present"' >/dev/null \
  || fail "dep platform-branch (scheduler-backend, $sched_name) present: (got: $outSchedP)"

dep_sched_absent="$work/dep-sched-absent-bin"; mkdir -p "$dep_sched_absent"
pathSchedAbsent=$(build_path "$dep_sched_absent" bash git jq -- "$sched_name")
outSchedA=$(PATH="$pathSchedAbsent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'scheduler-backend');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outSchedA" | jq -e '.actual == "absent"' >/dev/null \
  || fail "dep platform-branch (scheduler-backend, $sched_name) absent: (got: $outSchedA)"
echo "ok: dep platform-branch (scheduler-backend) picks '$sched_name' on this platform, present/absent"

# ── dep (graphify) — HIMMEL-1093 ─────────────────────────────────────────────
# Used to be file-exists on scripts/graphify/check-graph-freshness.sh, a
# git-TRACKED script — always 'present' on any himmel checkout regardless of
# whether graphify is actually installed. Now a plain PATH lookup, like
# tokensave-binary/rtk/every other real dep item.
gp_present_stub="$work/gp-present-bin"; mkdir -p "$gp_present_stub"
pathGPpresent=$(build_path "$gp_present_stub" bash git jq -- graphify)
cat > "$gp_present_stub/graphify" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$gp_present_stub/graphify"
outGPp=$(PATH="$pathGPpresent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'graphify');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGPp" | jq -e '.actual == "present"' >/dev/null || fail "dep (graphify) present: (got: $outGPp)"

gp_absent_stub="$work/gp-absent-bin"; mkdir -p "$gp_absent_stub"
pathGPabsent=$(build_path "$gp_absent_stub" bash git jq -- graphify)
outGPa=$(PATH="$pathGPabsent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'graphify');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGPa" | jq -e '.actual == "absent"' >/dev/null || fail "dep (graphify) absent: (got: $outGPa)"
echo "ok: dep (graphify) present/absent — no longer a tautological file-exists on a tracked script"

# ── cmd:has_hermes (hermes-lanes) — HIMMEL-1093 ──────────────────────────────
# Used to be file-exists on scripts/lanes/lanes.json (also git-TRACKED,
# always present). Now runs `. resolver || exit 3; resolve_hermes_py`,
# mirroring cmd:is_himmel_dev's shape exactly (round 4 CR fix: this branch
# INTRODUCED cmd:has_hermes with the same absent-vs-degraded conflation
# cmd:is_himmel_dev already got fixed in round 2 — ships consistent instead
# of repeating the bug): rc 0 present, rc 3 degraded (resolver itself failed
# to source — probe wiring broken), resolve_hermes_py's own nonzero ->
# absent (sourced fine, hermes genuinely not installed — the ordinary case).
hh_repo_present="$work/hh-repo-present"; mkdir -p "$hh_repo_present/scripts/lib"
cat > "$hh_repo_present/scripts/lib/resolve-hermes-py.sh" <<'SH'
resolve_hermes_py() { printf '%s\n' "/fake/venv/python"; return 0; }
SH
outHHp=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'hermes-lanes');
const ctx = { repoRoot: '$(winpath "$hh_repo_present")', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHHp" | jq -e '.actual == "present"' >/dev/null || fail "cmd:has_hermes present: (got: $outHHp)"

hh_repo_absent="$work/hh-repo-absent"; mkdir -p "$hh_repo_absent/scripts/lib"
cat > "$hh_repo_absent/scripts/lib/resolve-hermes-py.sh" <<'SH'
resolve_hermes_py() { return 1; }
SH
outHHa=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'hermes-lanes');
const ctx = { repoRoot: '$(winpath "$hh_repo_absent")', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHHa" | jq -e '.actual == "absent"' >/dev/null || fail "cmd:has_hermes absent: (got: $outHHa)"
echo "ok: cmd:has_hermes (hermes-lanes) present/absent — no longer a tautological file-exists on a tracked registry file"

# ── cmd:has_hermes: resolver missing -> degraded, NOT absent (CR fix, ──────
# HIMMEL-1093 round 4). No scripts/lib/resolve-hermes-py.sh at all — `.`
# fails to source it, hitting the `|| exit 3` guard. Must not read the same
# 'absent' as hermes genuinely-not-installed.
hh_no_resolver="$work/hh-no-resolver"; mkdir -p "$hh_no_resolver/scripts/lib"
outHHnr=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'hermes-lanes');
const ctx = { repoRoot: '$(winpath "$hh_no_resolver")', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHHnr" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:has_hermes degraded (resolver missing — probe wiring broken, not a clean absence): (got: $outHHnr)"
echo "$outHHnr" | jq -e '.detail | contains("cannot source resolver")' >/dev/null \
  || fail "cmd:has_hermes missing-resolver detail should name the sourcing failure (got: $outHHnr)"
echo "ok: cmd:has_hermes — a missing/unreadable resolver reads degraded, distinguished from hermes genuinely not installed"

# ── cmd:has_hermes: spawn error -> degraded, NOT absent (CR fix, ───────────
# HIMMEL-1093 round 4). HIMMEL-2289: PATH:'' alone no longer un-resolves
# bash (resolveProbeBash()'s Git-for-Windows/posix fallback candidates below
# aren't PATH-gated — see the no_such_bash_w comment above) — HIMMELCTL_BASH
# pinned to a path that is never created is what actually forces the spawn
# error and exercises the r.error branch.
outHHse=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'hermes-lanes');
const ctx = { repoRoot: '$(winpath "$hh_repo_present")', targetPath: '$repo_root_w', scope: 'user', env: { PATH: '', HIMMELCTL_BASH: '$no_such_bash_w' } };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHHse" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:has_hermes degraded (spawn error, bash unresolvable): (got: $outHHse)"
echo "$outHHse" | jq -e '.detail | contains("spawn error")' >/dev/null \
  || fail "cmd:has_hermes spawn-error detail should name it (got: $outHHse)"
echo "ok: cmd:has_hermes — a spawn error (bash unresolvable via a pinned-nonexistent HIMMELCTL_BASH) reads degraded, not absent"

# ── cmd:has_hermes: unexpected rc (127 — resolver sourced fine but never ───
# defined resolve_hermes_py) -> degraded, NOT absent (CR fix, HIMMEL-1093
# round 6, codex-2). A stale/mismatched resolver is a WIRING problem, never
# a clean "hermes not installed" (resolve_hermes_py's own rc 1) — the old
# fallback-to-absent conflated ANY nonzero rc, including this one.
hh_no_fn="$work/hh-no-fn"; mkdir -p "$hh_no_fn/scripts/lib"
cat > "$hh_no_fn/scripts/lib/resolve-hermes-py.sh" <<'SH'
# sources cleanly but deliberately does NOT define resolve_hermes_py
SH
outHHnf=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'hermes-lanes');
const ctx = { repoRoot: '$(winpath "$hh_no_fn")', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHHnf" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:has_hermes degraded (unexpected rc — resolver sourced but resolve_hermes_py undefined, rc 127): (got: $outHHnf)"
echo "$outHHnf" | jq -e '.detail | contains("unexpected rc")' >/dev/null \
  || fail "cmd:has_hermes unexpected-rc detail should name it (got: $outHHnf)"
echo "ok: cmd:has_hermes — an unexpected rc (127, resolver sourced but the function was never defined) reads degraded, never a clean absent"

# ── cmd:is_himmel_dev (doc-guard-map) — HIMMEL-1093 ──────────────────────────
# Used to be file-exists on scripts/lib/doc-guard-map.sh (repoRoot-forced,
# also git-TRACKED — always present). Now runs `. resolver || exit 3;
# is_himmel_dev_repo`: rc 0 present, rc 1 absent (sourced fine, not a dev
# checkout — the ordinary case), rc 2 degraded (repo root unresolvable),
# rc 3 degraded (resolver itself failed to source — CR fix, HIMMEL-1093
# round 2: this used to be indistinguishable from rc 1's clean absence, so a
# genuinely broken probe wiring read as "gate off by choice").
idh_present="$work/idh-present"; mkdir -p "$idh_present/scripts/guardrails"
cat > "$idh_present/scripts/guardrails/lib.sh" <<'SH'
is_himmel_dev_repo() { return 0; }
SH
outIDHp=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'doc-guard-map');
const ctx = { repoRoot: '$(winpath "$idh_present")', targetPath: '$(winpath "$idh_present")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outIDHp" | jq -e '.actual == "present"' >/dev/null || fail "cmd:is_himmel_dev present (marker present): (got: $outIDHp)"

idh_absent="$work/idh-absent"; mkdir -p "$idh_absent/scripts/guardrails"
cat > "$idh_absent/scripts/guardrails/lib.sh" <<'SH'
is_himmel_dev_repo() { return 1; }
SH
outIDHa=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'doc-guard-map');
const ctx = { repoRoot: '$(winpath "$idh_absent")', targetPath: '$(winpath "$idh_absent")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outIDHa" | jq -e '.actual == "absent"' >/dev/null || fail "cmd:is_himmel_dev absent (marker absent, the common case): (got: $outIDHa)"

idh_error="$work/idh-error"; mkdir -p "$idh_error/scripts/guardrails"
cat > "$idh_error/scripts/guardrails/lib.sh" <<'SH'
is_himmel_dev_repo() { return 2; }
SH
outIDHe=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'doc-guard-map');
const ctx = { repoRoot: '$(winpath "$idh_error")', targetPath: '$(winpath "$idh_error")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outIDHe" | jq -e '.actual == "degraded"' >/dev/null || fail "cmd:is_himmel_dev degraded (rc=2, cannot resolve repo root): (got: $outIDHe)"
echo "ok: cmd:is_himmel_dev (doc-guard-map) present/absent/degraded — no longer a tautological file-exists on a tracked script"

# ── cmd:is_himmel_dev: resolver missing -> degraded, NOT absent (CR fix, ────
# HIMMEL-1093 round 2, codex-1). No scripts/guardrails/lib.sh at all — `.`
# fails to source it, hitting the `|| exit 3` guard. Must not read the same
# 'absent' as a genuinely-not-a-dev-checkout marker, or status-report.js's
# opt-in downgrade would swallow a broken probe into a friendly "gate off".
idh_no_resolver="$work/idh-no-resolver"; mkdir -p "$idh_no_resolver/scripts/guardrails"
outIDHnr=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'doc-guard-map');
const ctx = { repoRoot: '$(winpath "$idh_no_resolver")', targetPath: '$(winpath "$idh_no_resolver")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outIDHnr" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:is_himmel_dev degraded (resolver missing — probe wiring broken, not a clean absence): (got: $outIDHnr)"
echo "$outIDHnr" | jq -e '.detail | contains("cannot source resolver")' >/dev/null \
  || fail "cmd:is_himmel_dev missing-resolver detail should name the sourcing failure (got: $outIDHnr)"
echo "ok: cmd:is_himmel_dev — a missing/unreadable resolver reads degraded, distinguished from a genuinely absent marker"

# ── cmd:is_himmel_dev: spawn error -> degraded, NOT absent (CR fix, ─────────
# HIMMEL-1093 round 2, codex-1). HIMMEL-2289: PATH:'' alone no longer
# un-resolves bash (resolveProbeBash()'s Git-for-Windows/posix fallback
# candidates below aren't PATH-gated — see the no_such_bash_w comment above)
# — HIMMELCTL_BASH pinned to a path that is never created is what actually
# forces the spawn error and exercises the r.error branch.
outIDHse=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'doc-guard-map');
const ctx = { repoRoot: '$(winpath "$idh_present")', targetPath: '$(winpath "$idh_present")', scope: 'project', env: { PATH: '', HIMMELCTL_BASH: '$no_such_bash_w' } };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outIDHse" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:is_himmel_dev degraded (spawn error, bash unresolvable): (got: $outIDHse)"
echo "$outIDHse" | jq -e '.detail | contains("spawn error")' >/dev/null \
  || fail "cmd:is_himmel_dev spawn-error detail should name it (got: $outIDHse)"

# ── cmd:is_himmel_dev: unexpected rc (127 — resolver sourced fine but ──────
# never defined is_himmel_dev_repo) -> degraded, NOT absent (CR fix,
# HIMMEL-1093 round 6, codex-2). A stale/mismatched resolver is a WIRING
# problem, never a clean "not a dev checkout" (is_himmel_dev_repo's own
# rc 1) — the old fallback-to-absent conflated ANY nonzero rc, including
# this one, which status-report.js's opt-in handler would then have
# silently downgraded to a friendly "gate off" n/a.
idh_no_fn="$work/idh-no-fn"; mkdir -p "$idh_no_fn/scripts/guardrails"
cat > "$idh_no_fn/scripts/guardrails/lib.sh" <<'SH'
# sources cleanly but deliberately does NOT define is_himmel_dev_repo
SH
outIDHnf=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'doc-guard-map');
const ctx = { repoRoot: '$(winpath "$idh_no_fn")', targetPath: '$(winpath "$idh_no_fn")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outIDHnf" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:is_himmel_dev degraded (unexpected rc — resolver sourced but is_himmel_dev_repo undefined, rc 127): (got: $outIDHnf)"
echo "$outIDHnf" | jq -e '.detail | contains("unexpected rc")' >/dev/null \
  || fail "cmd:is_himmel_dev unexpected-rc detail should name it (got: $outIDHnf)"
echo "ok: cmd:is_himmel_dev — an unexpected rc (127, resolver sourced but the function was never defined) reads degraded, never a clean absent"
echo "ok: cmd:is_himmel_dev — a spawn error (bash unresolvable) reads degraded, not absent"

# ── telegram-access (telegram-bridge) — HIMMEL-1093 round 3 (codex-adv-3) ──
# Used to be a plain settings-key check on TELEGRAM_BOT_TOKEN — green for a
# bridge that would reject every DM/group (gate.ts's isAllowed()/
# isAllowedGroup() fail CLOSED on a missing/empty allowFrom with no groups).
# Now checks both the token AND access.json's usable-allow-rule shape: token
# absent -> absent; token present but access.json missing / unparseable /
# no usable allow rule -> degraded; both -> present.
telegramHome() {
  local name="$1"; mkdir -p "$work/$name/.claude/channels/telegram"; printf '%s' "$work/$name"
}

# HIMMEL_LUNA_CONFIG_PATH points every telegram-access/cmd:telegram_getme
# invocation in this section at a deliberately nonexistent path
# (resolveBridgeEnvFilePath now consults ~/.himmel/config.json for
# bridge.envPath — HIMMEL-2176 Stage-1 PR-C, Part B) — never the real file. A
# nonexistent path makes loadConfigIfPresent() skip load() entirely, so this
# whole section's pre-existing, unaffected HOME-based fixture resolution is
# unchanged.
tg_no_config="$work/tg-no-config.json"
tg_no_config_w="$(winpath "$tg_no_config")"

# no token at all -> absent, regardless of access.json.
tb_no_token=$(telegramHome "tb-no-token")
cat > "$tb_no_token/.claude/channels/telegram/access.json" <<'JSON'
{"allowFrom":["12345"]}
JSON
outTBnoToken=$(HIMMEL_LUNA_CONFIG_PATH="$tg_no_config_w" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'telegram-bridge');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$tb_no_token")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outTBnoToken" | jq -e '.actual == "absent"' >/dev/null \
  || fail "telegram-access: no TELEGRAM_BOT_TOKEN should read absent regardless of access.json: (got: $outTBnoToken)"
echo "ok: telegram-access — no token reads absent"

# token present, access.json MISSING entirely -> degraded.
tb_token_only=$(telegramHome "tb-token-only")
cat > "$tb_token_only/.claude/channels/telegram/.env" <<'ENV'
TELEGRAM_BOT_TOKEN=123:abc
ENV
outTBtokenOnly=$(HIMMEL_LUNA_CONFIG_PATH="$tg_no_config_w" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'telegram-bridge');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$tb_token_only")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outTBtokenOnly" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "telegram-access: token present but access.json missing should read degraded (would gate out everything): (got: $outTBtokenOnly)"
echo "$outTBtokenOnly" | jq -e '.detail | test("gated out"; "i")' >/dev/null \
  || fail "telegram-access: missing-access.json detail should warn everything gets gated out (got: $outTBtokenOnly)"
echo "ok: telegram-access — token present, access.json missing reads degraded"

# token present, access.json MALFORMED (unparseable) -> degraded.
tb_malformed=$(telegramHome "tb-malformed")
cat > "$tb_malformed/.claude/channels/telegram/.env" <<'ENV'
TELEGRAM_BOT_TOKEN=123:abc
ENV
printf '{not valid json' > "$tb_malformed/.claude/channels/telegram/access.json"
outTBmalformed=$(HIMMEL_LUNA_CONFIG_PATH="$tg_no_config_w" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'telegram-bridge');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$tb_malformed")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outTBmalformed" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "telegram-access: token present but access.json unparseable should read degraded: (got: $outTBmalformed)"
echo "ok: telegram-access — token present, access.json malformed reads degraded"

# token present, access.json parses but carries NO usable allow rule (empty
# allowFrom, no groups) -> degraded.
tb_empty_rules=$(telegramHome "tb-empty-rules")
cat > "$tb_empty_rules/.claude/channels/telegram/.env" <<'ENV'
TELEGRAM_BOT_TOKEN=123:abc
ENV
cat > "$tb_empty_rules/.claude/channels/telegram/access.json" <<'JSON'
{"dmPolicy":"allowlist","allowFrom":[],"groups":{}}
JSON
outTBemptyRules=$(HIMMEL_LUNA_CONFIG_PATH="$tg_no_config_w" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'telegram-bridge');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$tb_empty_rules")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outTBemptyRules" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "telegram-access: empty allowFrom and no groups should read degraded (nothing would ever be allowed): (got: $outTBemptyRules)"
echo "$outTBemptyRules" | jq -e '.detail | test("no usable allow rule"; "i")' >/dev/null \
  || fail "telegram-access: empty-rules detail should name the missing allow rule (got: $outTBemptyRules)"
echo "ok: telegram-access — token present, access.json with no usable allow rule reads degraded"

# token present, access.json carries a real allowFrom -> present.
tb_valid=$(telegramHome "tb-valid")
cat > "$tb_valid/.claude/channels/telegram/.env" <<'ENV'
TELEGRAM_BOT_TOKEN=123:abc
ENV
cat > "$tb_valid/.claude/channels/telegram/access.json" <<'JSON'
{"dmPolicy":"allowlist","allowFrom":["12345"]}
JSON
outTBvalid=$(HIMMEL_LUNA_CONFIG_PATH="$tg_no_config_w" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'telegram-bridge');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$tb_valid")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outTBvalid" | jq -e '.actual == "present"' >/dev/null \
  || fail "telegram-access: token + a real allowFrom should read present: (got: $outTBvalid)"
echo "ok: telegram-access — token + valid access.json (non-empty allowFrom) reads present"

# token present, access.json has NO allowFrom but a real groups entry ->
# present too (gate.ts admits a present group key with no per-group
# allowFrom — see the module comment in probes.js).
tb_group_only=$(telegramHome "tb-group-only")
cat > "$tb_group_only/.claude/channels/telegram/.env" <<'ENV'
TELEGRAM_BOT_TOKEN=123:abc
ENV
cat > "$tb_group_only/.claude/channels/telegram/access.json" <<'JSON'
{"groups":{"-100123":{}}}
JSON
outTBgroupOnly=$(HIMMEL_LUNA_CONFIG_PATH="$tg_no_config_w" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'telegram-bridge');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$tb_group_only")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outTBgroupOnly" | jq -e '.actual == "present"' >/dev/null \
  || fail "telegram-access: token + a groups-only access.json (no top-level allowFrom) should read present: (got: $outTBgroupOnly)"
echo "ok: telegram-access — token + a groups-only access.json reads present, no longer a tautological file-exists on a tracked script"

# ── telegram-access: formal JSON-schema extension (HIMMEL-2176 Task 6) ─────
# A semantically-usable access.json (non-empty allowFrom) that ALSO carries a
# wrong-typed field elsewhere must now read degraded — proves the schema
# check runs BEFORE (not instead of) the pre-existing usable-allow-rule check.
tb_schema_bad_dmpolicy=$(telegramHome "tb-schema-bad-dmpolicy")
cat > "$tb_schema_bad_dmpolicy/.claude/channels/telegram/.env" <<'ENV'
TELEGRAM_BOT_TOKEN=123:abc
ENV
cat > "$tb_schema_bad_dmpolicy/.claude/channels/telegram/access.json" <<'JSON'
{"dmPolicy":42,"allowFrom":["12345"]}
JSON
outTBschemaDm=$(HIMMEL_LUNA_CONFIG_PATH="$tg_no_config_w" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'telegram-bridge');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$tb_schema_bad_dmpolicy")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outTBschemaDm" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "telegram-access schema: dmPolicy as a number (non-empty allowFrom notwithstanding) should read degraded: (got: $outTBschemaDm)"
echo "$outTBschemaDm" | jq -e '.detail | test("schema"; "i")' >/dev/null \
  || fail "telegram-access schema: detail should name the formal-schema failure (got: $outTBschemaDm)"
echo "ok: telegram-access — formal schema catches a wrong-typed dmPolicy even with an otherwise-usable allowFrom"

tb_schema_bad_group=$(telegramHome "tb-schema-bad-group")
cat > "$tb_schema_bad_group/.claude/channels/telegram/.env" <<'ENV'
TELEGRAM_BOT_TOKEN=123:abc
ENV
cat > "$tb_schema_bad_group/.claude/channels/telegram/access.json" <<'JSON'
{"allowFrom":["12345"],"groups":{"-100123":{"requireMention":"yes"}}}
JSON
outTBschemaGroup=$(HIMMEL_LUNA_CONFIG_PATH="$tg_no_config_w" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'telegram-bridge');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$tb_schema_bad_group")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outTBschemaGroup" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "telegram-access schema: a per-group requireMention as a string should read degraded: (got: $outTBschemaGroup)"
echo "$outTBschemaGroup" | jq -e '.detail | contains("requireMention")' >/dev/null \
  || fail "telegram-access schema: detail should name the offending field (got: $outTBschemaGroup)"
echo "ok: telegram-access — formal schema recurses into per-group fields (requireMention type-checked)"

# Regression: a previously-valid, schema-clean fixture (groups-only, no
# top-level allowFrom) must still read present now that the schema check
# runs first.
tb_schema_ok=$(telegramHome "tb-schema-ok")
cat > "$tb_schema_ok/.claude/channels/telegram/.env" <<'ENV'
TELEGRAM_BOT_TOKEN=123:abc
ENV
cat > "$tb_schema_ok/.claude/channels/telegram/access.json" <<'JSON'
{"dmPolicy":"allowlist","groups":{"-100123":{"requireMention":true,"allowFrom":["1"]}}}
JSON
outTBschemaOk=$(HIMMEL_LUNA_CONFIG_PATH="$tg_no_config_w" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'telegram-bridge');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$tb_schema_ok")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outTBschemaOk" | jq -e '.actual == "present"' >/dev/null \
  || fail "telegram-access schema: a schema-clean groups-only access.json should still read present: (got: $outTBschemaOk)"
echo "ok: telegram-access — a schema-clean access.json is unaffected by the new formal check"

# ── cmd:telegram_getme (HIMMEL-2176 Task 6) ─────────────────────────────────
# no token at all -> absent, bun never even invoked.
gm_no_token=$(telegramHome "gm-no-token")
outGMnoToken=$(HIMMEL_LUNA_CONFIG_PATH="$tg_no_config_w" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'telegram-getme', probe: { type: 'cmd:telegram_getme', envFile: '.claude/channels/telegram/.env', tokenKey: 'TELEGRAM_BOT_TOKEN', apiModule: 'scripts/telegram/telegram-api.ts' } };
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$gm_no_token")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGMnoToken" | jq -e '.actual == "absent"' >/dev/null \
  || fail "cmd:telegram_getme: no token should read absent: (got: $outGMnoToken)"
echo "ok: cmd:telegram_getme — no token reads absent"

# stub `bun`: HIMMEL_PROBE_TOKEN == GOODTOKEN999 -> "ok:testbot"; else "fail".
# Fakes the SUBPROCESS boundary (this file's own convention), never the JS
# import boundary — the real telegram-api.ts is never touched by this suite.
gm_bun_stub="$work/gm-bun-stub"; mkdir -p "$gm_bun_stub"
cat > "$gm_bun_stub/bun" <<'STUB'
#!/usr/bin/env bash
if [ "$HIMMEL_PROBE_TOKEN" = "GOODTOKEN999" ]; then
  echo "ok:testbot"
else
  echo "fail"
fi
STUB
chmod +x "$gm_bun_stub/bun"
pathGMpresent=$(build_path "$gm_bun_stub" bash git jq --)

gm_valid=$(telegramHome "gm-valid")
printf 'TELEGRAM_BOT_TOKEN=GOODTOKEN999\n' > "$gm_valid/.claude/channels/telegram/.env"
outGMvalid=$(HIMMEL_LUNA_CONFIG_PATH="$tg_no_config_w" PATH="$pathGMpresent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'telegram-getme', probe: { type: 'cmd:telegram_getme', envFile: '.claude/channels/telegram/.env', tokenKey: 'TELEGRAM_BOT_TOKEN', apiModule: 'scripts/telegram/telegram-api.ts' } };
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$gm_valid")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGMvalid" | jq -e '.actual == "present"' >/dev/null \
  || fail "cmd:telegram_getme: stub bun 'ok' should read present: (got: $outGMvalid)"
echo "$outGMvalid" | jq -e '.detail | contains("testbot")' >/dev/null \
  || fail "cmd:telegram_getme: present detail should name the returned username: (got: $outGMvalid)"
if echo "$outGMvalid" | grep -qF "GOODTOKEN999"; then
  fail "cmd:telegram_getme: the raw token must NEVER appear in probe output (got: $outGMvalid)"
fi
echo "ok: cmd:telegram_getme — a valid token (stub bun) reads present, token never leaks into the result"

gm_rejected=$(telegramHome "gm-rejected")
printf 'TELEGRAM_BOT_TOKEN=BADTOKEN000\n' > "$gm_rejected/.claude/channels/telegram/.env"
outGMrejected=$(HIMMEL_LUNA_CONFIG_PATH="$tg_no_config_w" PATH="$pathGMpresent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'telegram-getme', probe: { type: 'cmd:telegram_getme', envFile: '.claude/channels/telegram/.env', tokenKey: 'TELEGRAM_BOT_TOKEN', apiModule: 'scripts/telegram/telegram-api.ts' } };
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$gm_rejected")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGMrejected" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:telegram_getme: stub bun 'fail' (unauthorized) should read degraded: (got: $outGMrejected)"
if echo "$outGMrejected" | grep -qF "BADTOKEN000"; then
  fail "cmd:telegram_getme: the raw REJECTED token must NEVER appear in probe output (got: $outGMrejected)"
fi
echo "ok: cmd:telegram_getme — an unauthorized/rejected token reads degraded, never leaks into the result"

# CR fix (codex-5, retask stage1-build-6d2e): probes.js hands the checkout's
# apiModule path to the child `bun` process via HIMMEL_PROBE_TELEGRAM_API for
# a dynamic import() -- a native Windows path there is runtime-dependent as
# an ESM specifier and can be rejected as an unsupported URL scheme. Every
# other test in this block stubs `bun` itself (this file's own established
# convention, never the JS import boundary), so the real import() call is
# never exercised anywhere in this suite -- that is exactly why the bug
# shipped. This pins the SHAPE of what's handed to the child instead: the
# stub asserts on its own received env (HIMMEL_PROBE_TELEGRAM_API must start
# with `file://`, never a bare native path) without needing a real bun.
gm_urlshape_stub="$work/gm-urlshape-stub"; mkdir -p "$gm_urlshape_stub"
cat > "$gm_urlshape_stub/bun" <<'STUB'
#!/usr/bin/env bash
case "$HIMMEL_PROBE_TELEGRAM_API" in
  file://*) echo "ok:urlshape" ;;
  *) echo "fail" ;;
esac
STUB
chmod +x "$gm_urlshape_stub/bun"
pathGMurlshape=$(build_path "$gm_urlshape_stub" bash git jq --)

gm_urlshape=$(telegramHome "gm-urlshape")
printf 'TELEGRAM_BOT_TOKEN=URLSHAPETOKEN222\n' > "$gm_urlshape/.claude/channels/telegram/.env"
outGMurlshape=$(HIMMEL_LUNA_CONFIG_PATH="$tg_no_config_w" PATH="$pathGMurlshape" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'telegram-getme', probe: { type: 'cmd:telegram_getme', envFile: '.claude/channels/telegram/.env', tokenKey: 'TELEGRAM_BOT_TOKEN', apiModule: 'scripts/telegram/telegram-api.ts' } };
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$gm_urlshape")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGMurlshape" | jq -e '.actual == "present"' >/dev/null \
  || fail "cmd:telegram_getme: HIMMEL_PROBE_TELEGRAM_API handed to the child must be a file:// URL, not a native path (got: $outGMurlshape)"
echo "ok: cmd:telegram_getme — HIMMEL_PROBE_TELEGRAM_API handed to the child is a file:// URL (pathToFileURL), not a native Windows path"

# bun absent from PATH entirely -> degraded (probe wiring / prerequisite gap,
# never conflated with 'no token configured').
gm_no_bun_stub="$work/gm-no-bun-bin"; mkdir -p "$gm_no_bun_stub"
pathGMabsent=$(build_path "$gm_no_bun_stub" bash git jq -- bun)
gm_no_bun=$(telegramHome "gm-no-bun")
printf 'TELEGRAM_BOT_TOKEN=SOMETOKEN111\n' > "$gm_no_bun/.claude/channels/telegram/.env"
outGMnoBun=$(HIMMEL_LUNA_CONFIG_PATH="$tg_no_config_w" PATH="$pathGMabsent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'telegram-getme', probe: { type: 'cmd:telegram_getme', envFile: '.claude/channels/telegram/.env', tokenKey: 'TELEGRAM_BOT_TOKEN', apiModule: 'scripts/telegram/telegram-api.ts' } };
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$gm_no_bun")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGMnoBun" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:telegram_getme: bun absent from PATH should read degraded: (got: $outGMnoBun)"
if echo "$outGMnoBun" | grep -qF "SOMETOKEN111"; then
  fail "cmd:telegram_getme: the raw token must NEVER appear even on a bun-missing wiring failure (got: $outGMnoBun)"
fi
echo "ok: cmd:telegram_getme — bun missing from PATH reads degraded, token still never leaks"

# CR fix (HIMMEL-2176, retask stage1-build-6d2e): every case above only ever
# exercised a stub `bun` that prints "ok:"/"fail" to STDOUT — none of them
# covered a child that writes something raw to STDERR containing the token,
# which is exactly the shape that leaked in production (getMe()'s own
# request URL embeds the token in its path: https://api.telegram.org/
# bot<TOKEN>/getMe, and any fetch failure/stack trace naming that URL used to
# be folded into the probe's detail verbatim). These two cases prove the
# redaction independently of what the tests above already cover.
gm_stderr_token_stub="$work/gm-stderr-token-stub"; mkdir -p "$gm_stderr_token_stub"
cat > "$gm_stderr_token_stub/bun" <<'STUB'
#!/usr/bin/env bash
echo "child crashed, raw token dump: $HIMMEL_PROBE_TOKEN" >&2
exit 1
STUB
chmod +x "$gm_stderr_token_stub/bun"
pathGMstderrToken=$(build_path "$gm_stderr_token_stub" bash git jq --)

gm_stderr_token=$(telegramHome "gm-stderr-token")
printf 'TELEGRAM_BOT_TOKEN=LEAKPROBE99887766\n' > "$gm_stderr_token/.claude/channels/telegram/.env"
outGMstderrToken=$(HIMMEL_LUNA_CONFIG_PATH="$tg_no_config_w" PATH="$pathGMstderrToken" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'telegram-getme', probe: { type: 'cmd:telegram_getme', envFile: '.claude/channels/telegram/.env', tokenKey: 'TELEGRAM_BOT_TOKEN', apiModule: 'scripts/telegram/telegram-api.ts' } };
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$gm_stderr_token")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGMstderrToken" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:telegram_getme: a child dumping the raw token to stderr should still read degraded: (got: $outGMstderrToken)"
if echo "$outGMstderrToken" | grep -qF "LEAKPROBE99887766"; then
  fail "cmd:telegram_getme: a child that writes the raw token to stderr must NOT leak it into the probe result (got: $outGMstderrToken)"
fi
echo "ok: cmd:telegram_getme — a child dumping the raw token to stderr never leaks it into the probe result"

gm_stderr_url_stub="$work/gm-stderr-url-stub"; mkdir -p "$gm_stderr_url_stub"
cat > "$gm_stderr_url_stub/bun" <<'STUB'
#!/usr/bin/env bash
echo "TypeError: fetch failed: https://api.telegram.org/bot$HIMMEL_PROBE_TOKEN/getMe: getaddrinfo ENOTFOUND api.telegram.org" >&2
exit 1
STUB
chmod +x "$gm_stderr_url_stub/bun"
pathGMstderrUrl=$(build_path "$gm_stderr_url_stub" bash git jq --)

gm_stderr_url=$(telegramHome "gm-stderr-url")
printf 'TELEGRAM_BOT_TOKEN=LEAKPROBE99887766\n' > "$gm_stderr_url/.claude/channels/telegram/.env"
outGMstderrUrl=$(HIMMEL_LUNA_CONFIG_PATH="$tg_no_config_w" PATH="$pathGMstderrUrl" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'telegram-getme', probe: { type: 'cmd:telegram_getme', envFile: '.claude/channels/telegram/.env', tokenKey: 'TELEGRAM_BOT_TOKEN', apiModule: 'scripts/telegram/telegram-api.ts' } };
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$gm_stderr_url")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGMstderrUrl" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:telegram_getme: a child echoing a token-bearing URL to stderr should still read degraded: (got: $outGMstderrUrl)"
if echo "$outGMstderrUrl" | grep -qF "LEAKPROBE99887766"; then
  fail "cmd:telegram_getme: a child that echoes a token-bearing request URL to stderr must NOT leak the token into the probe result (got: $outGMstderrUrl)"
fi
echo "$outGMstderrUrl" | jq -e '.detail | contains("[REDACTED]")' >/dev/null \
  || fail "cmd:telegram_getme: the redacted detail should still carry a [REDACTED] marker in place of the token, proving the diagnostic text was scrubbed rather than dropped (got: $outGMstderrUrl)"
echo "ok: cmd:telegram_getme — a child echoing a token-bearing request URL to stderr never leaks the token; diagnostic text otherwise preserved"

# CR round 9 fix (HIMMEL-2176, retask stage1-build-6d2e): every failure case
# above reads as "probe wiring broken" -- correct for a script that never
# even got to import telegram-api.ts, but WRONG for a genuine network/API
# failure the getMe() call itself observed (DNS, connectivity, Telegram
# unreachable). The real inline script tags that case's stderr with
# "runtime:" before this suite's own redaction step ever sees it; this stub
# reproduces exactly that shape (never touching the real JS import boundary,
# same convention as every other case in this block) to prove probes.js
# routes it to a connectivity-flavoured detail instead of "wiring broken",
# while still never leaking the token.
gm_runtime_network_stub="$work/gm-runtime-network-stub"; mkdir -p "$gm_runtime_network_stub"
cat > "$gm_runtime_network_stub/bun" <<'STUB'
#!/usr/bin/env bash
echo "runtime:TypeError: fetch failed: getaddrinfo ENOTFOUND api.telegram.org (token was $HIMMEL_PROBE_TOKEN)" >&2
exit 1
STUB
chmod +x "$gm_runtime_network_stub/bun"
pathGMruntimeNetwork=$(build_path "$gm_runtime_network_stub" bash git jq --)

gm_runtime_network=$(telegramHome "gm-runtime-network")
printf 'TELEGRAM_BOT_TOKEN=NETFAILTOKEN555\n' > "$gm_runtime_network/.claude/channels/telegram/.env"
outGMruntimeNetwork=$(HIMMEL_LUNA_CONFIG_PATH="$tg_no_config_w" PATH="$pathGMruntimeNetwork" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'telegram-getme', probe: { type: 'cmd:telegram_getme', envFile: '.claude/channels/telegram/.env', tokenKey: 'TELEGRAM_BOT_TOKEN', apiModule: 'scripts/telegram/telegram-api.ts' } };
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$gm_runtime_network")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGMruntimeNetwork" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:telegram_getme: a runtime-observed network failure should read degraded: (got: $outGMruntimeNetwork)"
echo "$outGMruntimeNetwork" | jq -e '.detail | (contains("wiring broken") | not)' >/dev/null \
  || fail "cmd:telegram_getme: a runtime-observed network failure must NOT be reported as probe wiring broken: (got: $outGMruntimeNetwork)"
echo "$outGMruntimeNetwork" | jq -e '.detail | (contains("connectivity") or contains("ENOTFOUND"))' >/dev/null \
  || fail "cmd:telegram_getme: a runtime-observed network failure detail should carry a connectivity-flavoured hint: (got: $outGMruntimeNetwork)"
if echo "$outGMruntimeNetwork" | grep -qF "NETFAILTOKEN555"; then
  fail "cmd:telegram_getme: a runtime-observed network failure must NOT leak the token (got: $outGMruntimeNetwork)"
fi
echo "ok: cmd:telegram_getme — a runtime-observed network failure reads degraded with a connectivity detail, not 'probe wiring broken', and never leaks the token"

# The wiring side of the same distinction: an import-stage failure (tagged
# "wiring:" by the real script) must still read as a probe wiring problem —
# proving the fix routes on the tag rather than defaulting everything to
# "runtime" now that both are possible.
gm_wiring_stub="$work/gm-wiring-stub"; mkdir -p "$gm_wiring_stub"
cat > "$gm_wiring_stub/bun" <<'STUB'
#!/usr/bin/env bash
echo "wiring:Error: Cannot find module 'telegram-api.ts'" >&2
exit 1
STUB
chmod +x "$gm_wiring_stub/bun"
pathGMwiring=$(build_path "$gm_wiring_stub" bash git jq --)

gm_wiring=$(telegramHome "gm-wiring")
printf 'TELEGRAM_BOT_TOKEN=WIRINGTOKEN333\n' > "$gm_wiring/.claude/channels/telegram/.env"
outGMwiring=$(HIMMEL_LUNA_CONFIG_PATH="$tg_no_config_w" PATH="$pathGMwiring" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'telegram-getme', probe: { type: 'cmd:telegram_getme', envFile: '.claude/channels/telegram/.env', tokenKey: 'TELEGRAM_BOT_TOKEN', apiModule: 'scripts/telegram/telegram-api.ts' } };
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$gm_wiring")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGMwiring" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:telegram_getme: an import-stage (wiring) failure should read degraded: (got: $outGMwiring)"
echo "$outGMwiring" | jq -e '.detail | contains("wiring")' >/dev/null \
  || fail "cmd:telegram_getme: an import-stage failure should still be reported as probe wiring broken: (got: $outGMwiring)"
if echo "$outGMwiring" | grep -qF "WIRINGTOKEN333"; then
  fail "cmd:telegram_getme: an import-stage failure must NOT leak the token (got: $outGMwiring)"
fi
echo "ok: cmd:telegram_getme — an import-stage (wiring) failure still reads as probe wiring broken, never leaks the token"

# ── cmd:whisper_ready (HIMMEL-2176 Task 6) ──────────────────────────────────
# HIMMEL_LUNA_CONFIG_PATH points every invocation below at a deliberately
# nonexistent path (probeWhisperReady now consults ~/.himmel/config.json for
# bridge.whisper.{cli,model} — HIMMEL-2176 Stage-1 PR-C, Part B) — never the
# real file. A nonexistent path makes loadConfigIfPresent() skip load()
# entirely, matching this whole block's pre-existing, unaffected behavior.
wr_no_config="$work/wr-no-config.json"

wr_absent="$work/wr-absent-dir"; mkdir -p "$wr_absent"
outWRabsent=$(HIMMEL_LUNA_CONFIG_PATH="$(winpath "$wr_no_config")" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'whisper-transcription', probe: { type: 'cmd:whisper_ready' } };
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { WHISPER_DIR: '$(winpath "$wr_absent")', WHISPER_CLI: undefined, WHISPER_MODEL: undefined }), platform: 'linux' };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outWRabsent" | jq -e '.actual == "absent"' >/dev/null \
  || fail "cmd:whisper_ready: empty WHISPER_DIR should read absent: (got: $outWRabsent)"
echo "$outWRabsent" | jq -e '.detail | contains("whisper-cli") and (contains("whisper-cli.exe") | not)' >/dev/null \
  || fail "cmd:whisper_ready: absent detail on a simulated POSIX platform should name the POSIX default binary name 'whisper-cli' (not .exe): (got: $outWRabsent)"
echo "ok: cmd:whisper_ready — no binary reads absent, POSIX default binary name has no .exe"

wr_degraded="$work/wr-degraded-dir"; mkdir -p "$wr_degraded"
printf 'stub-binary' > "$wr_degraded/whisper-cli.exe"
outWRdegraded=$(HIMMEL_LUNA_CONFIG_PATH="$(winpath "$wr_no_config")" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'whisper-transcription', probe: { type: 'cmd:whisper_ready' } };
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { WHISPER_DIR: '$(winpath "$wr_degraded")', WHISPER_CLI: undefined, WHISPER_MODEL: undefined }), platform: 'win32' };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outWRdegraded" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:whisper_ready: binary present (simulated win32 default name), model missing should read degraded: (got: $outWRdegraded)"
echo "$outWRdegraded" | jq -e '.detail | contains("whisper-cli.exe") and contains("ggml-small.bin")' >/dev/null \
  || fail "cmd:whisper_ready: degraded detail should name both the win32 binary default and the missing model (got: $outWRdegraded)"
echo "ok: cmd:whisper_ready — binary present (win32 default name), model missing reads degraded"

wr_present="$work/wr-present-dir"; mkdir -p "$wr_present"
printf 'stub-binary' > "$wr_present/whisper-cli.exe"
printf 'stub-model' > "$wr_present/ggml-small.bin"
outWRpresent=$(HIMMEL_LUNA_CONFIG_PATH="$(winpath "$wr_no_config")" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'whisper-transcription', probe: { type: 'cmd:whisper_ready' } };
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { WHISPER_DIR: '$(winpath "$wr_present")', WHISPER_CLI: undefined, WHISPER_MODEL: undefined }), platform: 'win32' };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outWRpresent" | jq -e '.actual == "present"' >/dev/null \
  || fail "cmd:whisper_ready: binary + model both present should read present: (got: $outWRpresent)"
echo "ok: cmd:whisper_ready — binary + model both present reads present"

# CR fix (HIMMEL-2176, codex-2): a DIRECTORY sitting at the binary path (a
# stray same-named folder, or a broken/partial install) must never read
# present or degraded from bare fs.existsSync() — it must read absent, same
# as a genuinely missing binary. Ambient WHISPER_CLI/WHISPER_MODEL/
# WHISPER_DIR are explicitly nulled per the task brief's own warning (a real
# operator env value on this machine previously produced a false pass).
wr_dir_binary="$work/wr-dir-binary-dir"; mkdir -p "$wr_dir_binary/whisper-cli.exe"
outWRdirBinary=$(HIMMEL_LUNA_CONFIG_PATH="$(winpath "$wr_no_config")" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'whisper-transcription', probe: { type: 'cmd:whisper_ready' } };
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { WHISPER_DIR: '$(winpath "$wr_dir_binary")', WHISPER_CLI: undefined, WHISPER_MODEL: undefined }), platform: 'win32' };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outWRdirBinary" | jq -e '.actual == "absent"' >/dev/null \
  || fail "cmd:whisper_ready: a DIRECTORY at the binary path must read absent, never present/degraded: (got: $outWRdirBinary)"
echo "$outWRdirBinary" | jq -e '.detail | test("directory"; "i")' >/dev/null \
  || fail "cmd:whisper_ready: a directory-at-binary-path detail should name the actual problem (got: $outWRdirBinary)"
echo "ok: cmd:whisper_ready — a plain directory at the binary path reads absent, never ready"

# CR fix (HIMMEL-2176, codex-2): a 0-byte binary (a truncated/interrupted
# download) must read absent, never present.
wr_empty_binary="$work/wr-empty-binary-dir"; mkdir -p "$wr_empty_binary"
: > "$wr_empty_binary/whisper-cli.exe"
outWRemptyBinary=$(HIMMEL_LUNA_CONFIG_PATH="$(winpath "$wr_no_config")" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'whisper-transcription', probe: { type: 'cmd:whisper_ready' } };
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { WHISPER_DIR: '$(winpath "$wr_empty_binary")', WHISPER_CLI: undefined, WHISPER_MODEL: undefined }), platform: 'win32' };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outWRemptyBinary" | jq -e '.actual == "absent"' >/dev/null \
  || fail "cmd:whisper_ready: a 0-byte binary must read absent, never present: (got: $outWRemptyBinary)"
echo "$outWRemptyBinary" | jq -e '.detail | test("0-byte"; "i")' >/dev/null \
  || fail "cmd:whisper_ready: a 0-byte binary detail should name it a 0-byte file (got: $outWRemptyBinary)"
echo "ok: cmd:whisper_ready — a 0-byte binary (truncated download) reads absent, never ready"

# CR fix (HIMMEL-2176, codex-2): binary usable, but a 0-byte MODEL (a
# truncated model download — the design's own checklist item warns about
# exactly this) must read degraded, never present.
wr_empty_model="$work/wr-empty-model-dir"; mkdir -p "$wr_empty_model"
printf 'not-empty' > "$wr_empty_model/whisper-cli.exe"
: > "$wr_empty_model/ggml-small.bin"
outWRemptyModel=$(HIMMEL_LUNA_CONFIG_PATH="$(winpath "$wr_no_config")" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'whisper-transcription', probe: { type: 'cmd:whisper_ready' } };
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { WHISPER_DIR: '$(winpath "$wr_empty_model")', WHISPER_CLI: undefined, WHISPER_MODEL: undefined }), platform: 'win32' };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outWRemptyModel" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:whisper_ready: a 0-byte model (binary usable) must read degraded, never present: (got: $outWRemptyModel)"
echo "$outWRemptyModel" | jq -e '.detail | test("0-byte"; "i")' >/dev/null \
  || fail "cmd:whisper_ready: a 0-byte model detail should name it a 0-byte file (got: $outWRemptyModel)"
echo "ok: cmd:whisper_ready — a 0-byte model (truncated download) reads degraded, never ready"

# CR fix (HIMMEL-2176, retask stage1-build-6d2e): isUsableFile()'s exec-bit
# check used to read the REAL process.platform directly instead of the
# effective platform (ctx.platform || process.platform) this file's own
# convention threads everywhere else — a win32-simulated probe running on an
# actual POSIX host would silently fall back to that host's own exec check
# instead of skipping it (Windows has no exec-bit concept). The
# wr_present/wr_degraded fixtures above pin ctx.platform:'win32', but on
# THIS test host the real process.platform already happens to read 'win32'
# too, so they could not tell the fix apart from the pre-fix bug — the exec
# check would be skipped either way, for the wrong reason. This test forces
# the two apart: process.platform is overridden (a real, JS-visible
# override — libuv's own X_OK enforcement is unaffected either way, since
# this only changes what isUsableFile() itself reads to decide whether to
# even ATTEMPT the check) to a non-win32 value while ctx.platform stays
# 'win32', and fs.accessSync is instrumented to count X_OK calls. The pre-fix
# code (reading the overridden process.platform) would attempt the exec
# check anyway; the fixed code (reading ctx.platform) must skip it entirely —
# proving the win32-simulated fixtures above now pass because of the
# effective-platform routing, not by accident of the real host OS.
outWRplatformRouting=$(HIMMEL_LUNA_CONFIG_PATH="$(winpath "$wr_no_config")" "$node_bin" -e "
const fs = require('fs');
let xOkCalls = 0;
const origAccessSync = fs.accessSync;
fs.accessSync = function (p, mode) {
  if (mode === fs.constants.X_OK) xOkCalls += 1;
  return origAccessSync.call(fs, p, mode);
};
Object.defineProperty(process, 'platform', { value: 'linux', configurable: true });
const { runProbe } = require('$probes_lib_w');
const item = { id: 'whisper-transcription', probe: { type: 'cmd:whisper_ready' } };
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { WHISPER_DIR: '$(winpath "$wr_present")', WHISPER_CLI: undefined, WHISPER_MODEL: undefined }), platform: 'win32' };
const result = runProbe(item, ctx);
console.log(JSON.stringify({ result, xOkCalls }));
")
echo "$outWRplatformRouting" | jq -e '.result.actual == "present"' >/dev/null \
  || fail "cmd:whisper_ready: ctx.platform:'win32' should still read present even with the real process.platform overridden to non-win32: (got: $outWRplatformRouting)"
echo "$outWRplatformRouting" | jq -e '.xOkCalls == 0' >/dev/null \
  || fail "cmd:whisper_ready: ctx.platform:'win32' must skip the exec-bit check entirely (fs.accessSync X_OK must not be called), even when the real process.platform reads non-win32 (got: $outWRplatformRouting)"
echo "ok: cmd:whisper_ready — the exec-bit check is driven by ctx.platform, not the real host process.platform (HIMMEL-2176 CR fix)"

# CR fix (retask stage1-build-6d2e): loadConfigIfPresent() used to read
# HIMMEL_LUNA_CONFIG_PATH from the real process.env directly, ignoring
# ctx.env — the same shape as the HOME bug expandHomeForCtx already fixed a
# few files up ("would have resolved against the real operator's
# ~/.claude/channels/telegram/.env in production for any caller not using
# ctx.env.HOME"). Proven the SAME way the pre-existing "cmd:codex_provisioned
# honors ctx.env.HOME" case above proves its own fix: a MINIMAL ctx.env (no
# process.env spread at all) carrying its OWN HIMMEL_LUNA_CONFIG_PATH, set
# alongside a DIFFERENT value on the real subprocess env var. The two
# configs are engineered to disagree on the RESULT, not just wording — the
# ambient config's model file doesn't exist in the whisper dir (would read
# degraded), the ctx config's does (present) — so only a genuine ctx.env
# read, not an accidental string match, can make this pass.
wr_ctxenv_dir="$work/wr-ctxenv-dir"; mkdir -p "$wr_ctxenv_dir"
printf 'stub-binary' > "$wr_ctxenv_dir/whisper-cli"; chmod +x "$wr_ctxenv_dir/whisper-cli"
printf 'stub-model' > "$wr_ctxenv_dir/ctx-model.bin"
wr_ctxenv_cfg="$work/wr-ctxenv-config.json"
cat > "$wr_ctxenv_cfg" <<'JSON'
{"version":1,"luna":{"vaultPath":"/x","cadence":{"enabled":false,"schedules":{"fetchHealth":{"time":"01:30"},"harvest":{"time":"02:00"},"synthesize":{"time":"03:00"},"health":{"time":"04:00","day":"SUN"}},"models":{"harvest":"sonnet","synthesize":"sonnet","health":"haiku"}},"phi":{"declared":false}},"bridge":{"enabled":true,"envPath":"~/x/.env","whisper":{"cli":null,"model":"ctx-model.bin"}}}
JSON
wr_ambient_cfg="$work/wr-ambient-config.json"
cat > "$wr_ambient_cfg" <<'JSON'
{"version":1,"luna":{"vaultPath":"/x","cadence":{"enabled":false,"schedules":{"fetchHealth":{"time":"01:30"},"harvest":{"time":"02:00"},"synthesize":{"time":"03:00"},"health":{"time":"04:00","day":"SUN"}},"models":{"harvest":"sonnet","synthesize":"sonnet","health":"haiku"}},"phi":{"declared":false}},"bridge":{"enabled":true,"envPath":"~/x/.env","whisper":{"cli":null,"model":"ambient-model.bin"}}}
JSON
outWRctxEnvConfig=$(HIMMEL_LUNA_CONFIG_PATH="$(winpath "$wr_ambient_cfg")" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'whisper-transcription', probe: { type: 'cmd:whisper_ready' } };
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: { WHISPER_DIR: '$(winpath "$wr_ctxenv_dir")', HIMMEL_LUNA_CONFIG_PATH: '$(winpath "$wr_ctxenv_cfg")' },
  platform: 'linux' };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outWRctxEnvConfig" | jq -e '.actual == "present"' >/dev/null \
  || fail "cmd:whisper_ready: a ctx.env.HIMMEL_LUNA_CONFIG_PATH override must be honored over the ambient process.env one (got: $outWRctxEnvConfig)"
echo "$outWRctxEnvConfig" | jq -e '.detail | test("ambient-model"; "i") | not' >/dev/null \
  || fail "cmd:whisper_ready: must not have consulted the ambient process.env config at all (got: $outWRctxEnvConfig)"
echo "ok: cmd:whisper_ready — a ctx.env HIMMEL_LUNA_CONFIG_PATH override is honored, not the ambient process.env one (HIMMEL-2176 CR fix)"

# ── cmd:python_interpreter (HIMMEL-2176 Task 6) ─────────────────────────────
pi_absent_stub="$work/pi-absent-bin"; mkdir -p "$pi_absent_stub"
pathPIabsent=$(build_path "$pi_absent_stub" bash git jq -- python python3)
outPIabsent=$(PATH="$pathPIabsent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'python-interpreter', probe: { type: 'cmd:python_interpreter', cmd: 'python' } };
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outPIabsent" | jq -e '.actual == "absent"' >/dev/null \
  || fail "cmd:python_interpreter: nothing on PATH should read absent: (got: $outPIabsent)"
echo "ok: cmd:python_interpreter — absent when nothing resolves on PATH"

# present: a stub interpreter that actually RUNS the given script (not just
# resolves) and echoes the marker back — also proves PYTHONHOME is threaded
# to the child (named in the detail), not just read from the real process env.
pi_present_stub="$work/pi-present-bin"; mkdir -p "$pi_present_stub"
cat > "$pi_present_stub/python" <<'STUB'
#!/usr/bin/env bash
echo HIMMEL_PY_OK
exit 0
STUB
chmod +x "$pi_present_stub/python"
pathPIpresent=$(build_path "$pi_present_stub" bash git jq --)
outPIpresent=$(PATH="$pathPIpresent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'python-interpreter', probe: { type: 'cmd:python_interpreter', cmd: 'python' } };
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { PYTHONHOME: '$(winpath "$pi_present_stub")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outPIpresent" | jq -e '.actual == "present"' >/dev/null \
  || fail "cmd:python_interpreter: a working stub interpreter should read present: (got: $outPIpresent)"
echo "$outPIpresent" | jq -e '.detail | contains("PYTHONHOME")' >/dev/null \
  || fail "cmd:python_interpreter: present detail should name the PYTHONHOME actually threaded to the child (got: $outPIpresent)"
echo "ok: cmd:python_interpreter — a working interpreter that runs the script reads present, PYTHONHOME threaded through"

# degraded: mimics the REAL Windows Store python.exe app-execution alias —
# resolves on PATH but exits non-zero without ever running the given script.
pi_stub_stub="$work/pi-stub-bin"; mkdir -p "$pi_stub_stub"
cat > "$pi_stub_stub/python" <<'STUB'
#!/usr/bin/env bash
echo "Python was not found; run without arguments to install from the Microsoft Store." >&2
exit 9009
STUB
chmod +x "$pi_stub_stub/python"
pathPIstub=$(build_path "$pi_stub_stub" bash git jq --)
outPIstub=$(PATH="$pathPIstub" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'python-interpreter', probe: { type: 'cmd:python_interpreter', cmd: 'python' } };
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outPIstub" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:python_interpreter: a Windows-Store-alias-shaped stub should read degraded, not absent: (got: $outPIstub)"
echo "ok: cmd:python_interpreter — a resolved-but-stub interpreter (Windows Store alias shape) reads degraded, never absent"

# ── distinct-tokens (HIMMEL-2176 Task 6) ────────────────────────────────────
dt_both_absent="$work/dt-both-absent"; mkdir -p "$dt_both_absent/.claude/channels/telegram"
outDTbothAbsent=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'telegram-distinct-tokens', probe: { type: 'distinct-tokens', envFileA: '.claude/channels/telegram/.env', tokenKeyA: 'TELEGRAM_BOT_TOKEN', envFileB: '.env', tokenKeyB: 'TELEGRAM_BOT_TOKEN' } };
const ctx = { repoRoot: '$(winpath "$dt_both_absent")', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$dt_both_absent")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outDTbothAbsent" | jq -e '.actual == "present"' >/dev/null \
  || fail "distinct-tokens: both unconfigured should read present (nothing to collide): (got: $outDTbothAbsent)"
echo "ok: distinct-tokens — both tokens unconfigured reads present"

dt_only_a="$work/dt-only-a"; mkdir -p "$dt_only_a/.claude/channels/telegram"
printf 'TELEGRAM_BOT_TOKEN=AAA111\n' > "$dt_only_a/.claude/channels/telegram/.env"
outDTonlyA=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'telegram-distinct-tokens', probe: { type: 'distinct-tokens', envFileA: '.claude/channels/telegram/.env', tokenKeyA: 'TELEGRAM_BOT_TOKEN', envFileB: '.env', tokenKeyB: 'TELEGRAM_BOT_TOKEN' } };
const ctx = { repoRoot: '$(winpath "$dt_only_a")', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$dt_only_a")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outDTonlyA" | jq -e '.actual == "present"' >/dev/null \
  || fail "distinct-tokens: only the bridge token configured should read present: (got: $outDTonlyA)"
echo "ok: distinct-tokens — only one side configured reads present"

dt_distinct="$work/dt-distinct"; mkdir -p "$dt_distinct/.claude/channels/telegram"
printf 'TELEGRAM_BOT_TOKEN=AAA111\n' > "$dt_distinct/.claude/channels/telegram/.env"
printf 'TELEGRAM_BOT_TOKEN=BBB222\n' > "$dt_distinct/.env"
outDTdistinct=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'telegram-distinct-tokens', probe: { type: 'distinct-tokens', envFileA: '.claude/channels/telegram/.env', tokenKeyA: 'TELEGRAM_BOT_TOKEN', envFileB: '.env', tokenKeyB: 'TELEGRAM_BOT_TOKEN' } };
const ctx = { repoRoot: '$(winpath "$dt_distinct")', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$dt_distinct")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outDTdistinct" | jq -e '.actual == "present"' >/dev/null \
  || fail "distinct-tokens: two DIFFERENT tokens should read present: (got: $outDTdistinct)"
echo "ok: distinct-tokens — two distinct tokens reads present"

dt_collision="$work/dt-collision"; mkdir -p "$dt_collision/.claude/channels/telegram"
printf 'TELEGRAM_BOT_TOKEN=SAMETOKEN999\n' > "$dt_collision/.claude/channels/telegram/.env"
printf 'TELEGRAM_BOT_TOKEN=SAMETOKEN999\n' > "$dt_collision/.env"
outDTcollision=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'telegram-distinct-tokens', probe: { type: 'distinct-tokens', envFileA: '.claude/channels/telegram/.env', tokenKeyA: 'TELEGRAM_BOT_TOKEN', envFileB: '.env', tokenKeyB: 'TELEGRAM_BOT_TOKEN' } };
const ctx = { repoRoot: '$(winpath "$dt_collision")', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$dt_collision")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outDTcollision" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "distinct-tokens: two IDENTICAL tokens should read degraded: (got: $outDTcollision)"
echo "$outDTcollision" | jq -e '.detail | test("IDENTICAL")' >/dev/null \
  || fail "distinct-tokens: degraded detail should call out the collision (got: $outDTcollision)"
echo "ok: distinct-tokens — two identical non-empty tokens (bridge vs jira-nudge relay) reads degraded"

# ── luna-sources (HIMMEL-2176 Task 6) ───────────────────────────────────────
# Stub `python`: dispatches on the LAST argv (the --probe SOURCE value),
# mimicking fetch-health.py's own --probe <source> contract exactly (JSON on
# stdout + rc 0/1; argparse's fixed rc 2 for a genuinely unrecognized source,
# with the EXACT stderr wording run_single_probe's own ValueError produces —
# "unknown probe source: '<name>' (valid sources: ...)" — since the probe
# disambiguates rc=2 by matching that literal text, not the bare code; a
# SEPARATE rc=2 case (bad-flag-source) deliberately does NOT carry that text,
# proving an unrelated usage error is never misclassified as "unrecognized
# source") — fakes the SUBPROCESS boundary, never a JS mock of the aggregator.
luna_stub="$work/luna-py-bin"; mkdir -p "$luna_stub"
cat > "$luna_stub/python" <<'STUB'
#!/usr/bin/env bash
source_name="${@: -1}"
case "$source_name" in
  reddit|x-fxtwitter)
    printf '{"status":"ok","reason":"reachable"}\n'
    exit 0
    ;;
  firecrawl)
    printf '{"status":"auth-or-cookie-expired","reason":"Firecrawl API key rejected"}\n'
    exit 1
    ;;
  cookie-missing-source)
    printf '{"status":"auth-or-cookie-expired","reason":"reddit cookie file missing"}\n'
    exit 1
    ;;
  ghost-source)
    echo "fetch-health.py: error: unknown probe source: 'ghost-source' (valid sources: bitbucket, firecrawl, github, reddit, ...)" >&2
    exit 2
    ;;
  bad-flag-source)
    echo "fetch-health.py: error: unrecognized arguments: --some-future-flag" >&2
    exit 2
    ;;
  *)
    exit 1
    ;;
esac
STUB
chmod +x "$luna_stub/python"
pathLuna=$(build_path "$luna_stub" bash git jq --)

outLunaAllOk=$(PATH="$pathLuna" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'luna-sources', probe: { type: 'luna-sources', script: 'scripts/luna/fetch-health.py', sources: ['reddit', 'x-fxtwitter'], pythonCmd: 'python' } };
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outLunaAllOk" | jq -e '.actual == "present"' >/dev/null \
  || fail "luna-sources: all configured sources ok should read present: (got: $outLunaAllOk)"
echo "ok: luna-sources — all configured sources healthy reads present"

outLunaOneAuth=$(PATH="$pathLuna" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'luna-sources', probe: { type: 'luna-sources', script: 'scripts/luna/fetch-health.py', sources: ['reddit', 'firecrawl'], pythonCmd: 'python' } };
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outLunaOneAuth" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "luna-sources: one CONFIGURED-but-broken source (rejected key, not a missing one) among others ok should read degraded: (got: $outLunaOneAuth)"
echo "$outLunaOneAuth" | jq -e '.detail | contains("firecrawl") and contains("auth-or-cookie-expired")' >/dev/null \
  || fail "luna-sources: degraded detail should name the failing source + status (got: $outLunaOneAuth)"
echo "$outLunaOneAuth" | jq -e '.detail | test("not configured"; "i") | not' >/dev/null \
  || fail "luna-sources: a REJECTED (not missing) credential must be bucketed as unhealthy, never as unconfigured (got: $outLunaOneAuth)"
echo "ok: luna-sources — one CONFIGURED-but-broken source among others ok reads degraded, naming it, never bucketed as unconfigured"

# CR fix (HIMMEL-2176, codex-3, retask stage1-build-6d2e): a source the
# adopter simply never CONFIGURED (fetch-health.py's reason names an absent
# credential/artifact — e.g. "reddit cookie file missing") must warn
# (actual:absent, remapped to severity:degraded by status-report.js's S2
# block), NOT fail like a genuinely broken configured source. Distinguishable
# in detail from the configured-but-broken case above ("not configured yet"
# vs. "unhealthy").
outLunaOneUnconfigured=$(PATH="$pathLuna" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'luna-sources', probe: { type: 'luna-sources', script: 'scripts/luna/fetch-health.py', sources: ['reddit', 'cookie-missing-source'], pythonCmd: 'python' } };
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outLunaOneUnconfigured" | jq -e '.actual == "absent"' >/dev/null \
  || fail "luna-sources: one UNCONFIGURED source (credential/artifact simply missing) among others ok must read absent (warn), not degraded (fail): (got: $outLunaOneUnconfigured)"
echo "$outLunaOneUnconfigured" | jq -e '.detail | contains("cookie-missing-source") and test("not configured"; "i")' >/dev/null \
  || fail "luna-sources: unconfigured detail should name the source and say it is not configured yet (got: $outLunaOneUnconfigured)"
echo "$outLunaOneUnconfigured" | jq -e '.detail | test("unhealthy"; "i") | not' >/dev/null \
  || fail "luna-sources: an unconfigured source must not be worded like a broken/unhealthy one (got: $outLunaOneUnconfigured)"
echo "ok: luna-sources — one unconfigured source among others ok reads absent (warn), distinguishable from a configured-but-broken source"

# Nothing configured at all: every named source is unconfigured (no problems,
# no healthy sources either) — still warn (absent), same tier as the mixed
# case above, never a fail.
outLunaAllUnconfigured=$(PATH="$pathLuna" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'luna-sources', probe: { type: 'luna-sources', script: 'scripts/luna/fetch-health.py', sources: ['cookie-missing-source'], pythonCmd: 'python' } };
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outLunaAllUnconfigured" | jq -e '.actual == "absent"' >/dev/null \
  || fail "luna-sources: every configured source unconfigured (nothing configured at all) should read absent (warn): (got: $outLunaAllUnconfigured)"
echo "ok: luna-sources — nothing configured at all (every source unconfigured) reads absent (warn), never a fail"

# Mixed: a configured-but-broken source AND an unconfigured one in the SAME
# sweep — the broken one must still force the fail tier (degraded), and both
# groups must remain distinguishable in the one combined detail.
outLunaMixed=$(PATH="$pathLuna" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'luna-sources', probe: { type: 'luna-sources', script: 'scripts/luna/fetch-health.py', sources: ['firecrawl', 'cookie-missing-source'], pythonCmd: 'python' } };
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outLunaMixed" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "luna-sources: a configured-but-broken source alongside an unconfigured one must still read degraded (fail wins): (got: $outLunaMixed)"
echo "$outLunaMixed" | jq -e '.detail | contains("firecrawl") and test("unhealthy"; "i") and contains("cookie-missing-source") and test("not configured"; "i")' >/dev/null \
  || fail "luna-sources: the mixed detail must name BOTH the broken source (unhealthy) and the unconfigured one (not configured), distinguishably (got: $outLunaMixed)"
echo "ok: luna-sources — a configured-but-broken source alongside an unconfigured one reads degraded (fail wins), naming both groups distinguishably"

# CR fix (HIMMEL-2176 Task 6, retask stage1-build-6d2e): a profile naming a
# source fetch-health.py has never heard of (typo, renamed, dropped upstream)
# used to fold into a footnote and still read 'present' — a fail-open-
# silently shape (HIMMEL-1128's loud-degradation rule): a source that isn't
# being monitored at all must never hide behind an otherwise-green verdict.
# Pins the fix: one healthy + one unrecognized must NOT report present.
outLunaOneUnrecognized=$(PATH="$pathLuna" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'luna-sources', probe: { type: 'luna-sources', script: 'scripts/luna/fetch-health.py', sources: ['reddit', 'ghost-source'], pythonCmd: 'python' } };
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outLunaOneUnrecognized" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "luna-sources: one unrecognized source among others ok must NOT read present (fail-open-silently, HIMMEL-1128): (got: $outLunaOneUnrecognized)"
echo "$outLunaOneUnrecognized" | jq -e '.detail | contains("ghost-source") and test("not recognized"; "i") and test("not being monitored"; "i")' >/dev/null \
  || fail "luna-sources: degraded detail should name the unrecognized source and say plainly it is not being monitored (got: $outLunaOneUnrecognized)"
echo "ok: luna-sources — one unrecognized-by-fetch-health.py source among others ok reads degraded, never present"

# The ambiguity check: a DIFFERENT rc=2 usage error (not the documented
# 'unknown probe source' wording) must fold into `problems` (a wiring
# problem), never be silently treated as the same "unrecognized source" case.
outLunaAmbiguousRc2=$(PATH="$pathLuna" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'luna-sources', probe: { type: 'luna-sources', script: 'scripts/luna/fetch-health.py', sources: ['reddit', 'bad-flag-source'], pythonCmd: 'python' } };
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outLunaAmbiguousRc2" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "luna-sources: a rc=2 usage error NOT worded 'unknown probe source' must still read degraded: (got: $outLunaAmbiguousRc2)"
echo "$outLunaAmbiguousRc2" | jq -e '.detail | contains("unexpected usage error") and (test("not recognized"; "i") | not)' >/dev/null \
  || fail "luna-sources: an ambiguous rc=2 must be labeled a wiring problem, NOT misclassified as 'unrecognized source' (got: $outLunaAmbiguousRc2)"
echo "ok: luna-sources — an rc=2 NOT matching the documented 'unknown probe source' wording is never misclassified as an unrecognized source"

# CR round 3 fix (HIMMEL-2176, retask stage1-build-6d2e): every named source
# unrecognized means NOTHING is being monitored at all — a profile
# configuration error, not a lesser signal than the "one bad entry among
# healthy ones" case above. Must read degraded (fail), never absent (warn) —
# it must not collapse into the same benign verdict as "genuinely nothing
# configured" (empty sources list / every source merely unconfigured, both
# tested elsewhere in this file).
outLunaAllSkip=$(PATH="$pathLuna" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'luna-sources', probe: { type: 'luna-sources', script: 'scripts/luna/fetch-health.py', sources: ['ghost-source'], pythonCmd: 'python' } };
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outLunaAllSkip" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "luna-sources: every configured source unrecognized (nothing evaluated) should read degraded (fail — nothing is monitored at all): (got: $outLunaAllSkip)"
echo "$outLunaAllSkip" | jq -e '.detail | contains("ghost-source") and test("not recognized"; "i")' >/dev/null \
  || fail "luna-sources: all-unrecognized detail should name the source and say it is not recognized (got: $outLunaAllSkip)"
echo "ok: luna-sources — every configured source unrecognized (nothing evaluated) reads degraded (fail), never warn"

outLunaEmpty=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'luna-sources', probe: { type: 'luna-sources', script: 'scripts/luna/fetch-health.py', sources: [], pythonCmd: 'python' } };
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outLunaEmpty" | jq -e '.actual == "absent"' >/dev/null \
  || fail "luna-sources: an empty sources list should read absent: (got: $outLunaEmpty)"
echo "ok: luna-sources — an empty configured-sources list reads absent"

# ── file-exists: {homePath} placeholder (obsidian-second-brain) — HIMMEL-1100
osb_home_present="$work/osb-home-present"; mkdir -p "$osb_home_present/.claude/plugins/obsidian-second-brain/.git"
outOSBp=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'obsidian-second-brain');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$osb_home_present")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outOSBp" | jq -e '.actual == "present"' >/dev/null || fail "file-exists {homePath} (obsidian-second-brain) present: (got: $outOSBp)"

osb_home_absent="$work/osb-home-absent"; mkdir -p "$osb_home_absent"
outOSBa=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'obsidian-second-brain');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$osb_home_absent")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outOSBa" | jq -e '.actual == "absent"' >/dev/null || fail "file-exists {homePath} (obsidian-second-brain) absent: (got: $outOSBa)"
echo "ok: file-exists {homePath} placeholder (obsidian-second-brain) present/absent"

# ── cmd:codex_provisioned (codex-cli) — HIMMEL-1100 ─────────────────────────
# CR fix (round 3, codex-adv-2): the fixture must plant a himmel-marketplace
# cache ENTRY (matching install-himmel-codex.sh's own MARKET="himmel"
# constant), not just an empty plugins/cache dir — see the probe's own
# comment for why a bare cache dir is not himmel-specific evidence.
codex_home_present="$work/codex-home-present"; mkdir -p "$codex_home_present/plugins/cache/himmel/himmel-ops/0.1.0"
codex_bin_stub="$work/codex-bin-stub"
: > "$codex_bin_stub"
chmod +x "$codex_bin_stub"

outCodexP=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'codex-cli');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { CODEX_BIN: '$(winpath "$codex_bin_stub")', CODEX_HOME: '$(winpath "$codex_home_present")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outCodexP" | jq -e '.actual == "present"' >/dev/null || fail "cmd:codex_provisioned present (bin resolves + himmel-marketplace plugin cache exists): (got: $outCodexP)"

# CR fix (round 3, codex-adv-2): a NON-empty cache dir with entries for OTHER
# marketplaces only (no himmel/ subdir at all) must NOT read present — codex
# itself is clearly in real use, but the himmel companion specifically was
# never provisioned.
codex_home_other_market="$work/codex-home-other-market"; mkdir -p "$codex_home_other_market/plugins/cache/openai-bundled/some-plugin/1.0.0"
outCodexOM=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'codex-cli');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { CODEX_BIN: '$(winpath "$codex_bin_stub")', CODEX_HOME: '$(winpath "$codex_home_other_market")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outCodexOM" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:codex_provisioned degraded (cache has OTHER marketplaces only, no himmel/ subdir): (got: $outCodexOM)"
echo "$outCodexOM" | jq -e '.detail | contains("himmel companion is not provisioned")' >/dev/null \
  || fail "cmd:codex_provisioned other-marketplace-only detail should name the himmel-specific gap (got: $outCodexOM)"

codex_home_no_cache="$work/codex-home-no-cache"; mkdir -p "$codex_home_no_cache"
outCodexD=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'codex-cli');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { CODEX_BIN: '$(winpath "$codex_bin_stub")', CODEX_HOME: '$(winpath "$codex_home_no_cache")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outCodexD" | jq -e '.actual == "degraded"' >/dev/null || fail "cmd:codex_provisioned degraded (bin resolves, no plugin cache — never provisioned): (got: $outCodexD)"
echo "$outCodexD" | jq -e '.detail | contains("never provisioned")' >/dev/null || fail "cmd:codex_provisioned degraded detail should say never provisioned (got: $outCodexD)"

codex_scrub_stub="$work/codex-scrub-bin"; mkdir -p "$codex_scrub_stub"
pathCodexScrubbed=$(build_path "$codex_scrub_stub" bash git jq -- codex)
outCodexA=$(PATH="$pathCodexScrubbed" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'codex-cli');
const env = Object.assign({}, process.env);
delete env.CODEX_BIN;
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outCodexA" | jq -e '.actual == "absent"' >/dev/null || fail "cmd:codex_provisioned absent (codex not on PATH, no CODEX_BIN): (got: $outCodexA)"

outCodexAoverride=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'codex-cli');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { CODEX_BIN: '$(winpath "$work")/nonexistent-codex' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outCodexAoverride" | jq -e '.actual == "absent"' >/dev/null || fail "cmd:codex_provisioned absent (CODEX_BIN set but unusable, no PATH fallback): (got: $outCodexAoverride)"
echo "$outCodexAoverride" | jq -e '.detail | contains("CODEX_BIN set but")' >/dev/null || fail "cmd:codex_provisioned CODEX_BIN-unusable detail should name it (got: $outCodexAoverride)"
echo "ok: cmd:codex_provisioned (codex-cli) present/degraded/absent, including CODEX_BIN override semantics"

# ── cmd:codex_provisioned: ctx.env HOME/CODEX_HOME divergence — HIMMEL-1100 ─
# CR fix (round 2, codex-1): the codexHome resolution used to read the REAL
# os.homedir() whenever CODEX_HOME was unset, ignoring ctx.env.HOME entirely
# — the same hermeticity class as which()'s HIMMEL-1093 round-5 fix. Proven
# with a MINIMAL ctx.env (no process.env spread at all) carrying only
# CODEX_BIN + a HOME that diverges from the real process env — only a fix
# that actually reads ctx.env.HOME can find the plugin cache planted there.
codex_ctxenv_home="$work/codex-ctxenv-home"; mkdir -p "$codex_ctxenv_home/.codex/plugins/cache/himmel/himmel-ops/0.1.0"
codex_ctxenv_bin="$work/codex-ctxenv-bin"; : > "$codex_ctxenv_bin"; chmod +x "$codex_ctxenv_bin"
outCodexCtxEnv=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'codex-cli');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: { CODEX_BIN: '$(winpath "$codex_ctxenv_bin")', HOME: '$(winpath "$codex_ctxenv_home")' } };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outCodexCtxEnv" | jq -e '.actual == "present"' >/dev/null \
  || fail "cmd:codex_provisioned should resolve the plugin cache via ctx.env.HOME (not process.env/os.homedir()): (got: $outCodexCtxEnv)"
echo "ok: cmd:codex_provisioned honors ctx.env.HOME for a hermetic caller with a fully-controlled env, diverging from process.env"

# An explicit ctx.env.CODEX_HOME wins over the HOME-derived default — the
# fixture HOME here deliberately carries NO .codex/plugins/cache, so a fix
# that fell back to the HOME-derived path instead of the explicit CODEX_HOME
# would misread this as degraded.
codex_ctxenv_home2="$work/codex-ctxenv-home2"; mkdir -p "$codex_ctxenv_home2"
codex_ctxenv_codexhome="$work/codex-ctxenv-codexhome"; mkdir -p "$codex_ctxenv_codexhome/plugins/cache/himmel/himmel-ops/0.1.0"
outCodexCtxEnv2=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'codex-cli');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: { CODEX_BIN: '$(winpath "$codex_ctxenv_bin")', HOME: '$(winpath "$codex_ctxenv_home2")', CODEX_HOME: '$(winpath "$codex_ctxenv_codexhome")' } };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outCodexCtxEnv2" | jq -e '.actual == "present"' >/dev/null \
  || fail "cmd:codex_provisioned: explicit ctx.env.CODEX_HOME should win over the HOME-derived default (got: $outCodexCtxEnv2)"
echo "ok: cmd:codex_provisioned honors an explicit ctx.env.CODEX_HOME over the HOME-derived default"

# CodeRabbit fix (HIMMEL-1100 round 6, coderabbit-1): CODEX_HOME PRESENT
# but set to an EMPTY STRING — path.join('', 'plugins', 'cache') produces a
# RELATIVE path, which existsSync would resolve against the wrong thing
# (the current process's cwd) if not guarded. Must read degraded, naming
# the bad value — never silently probe cwd.
outCodexEmptyHome=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'codex-cli');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: { CODEX_BIN: '$(winpath "$codex_ctxenv_bin")', HOME: '$(winpath "$codex_ctxenv_home2")', CODEX_HOME: '' } };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outCodexEmptyHome" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:codex_provisioned degraded (CODEX_HOME present but empty-string -> relative path, must not probe cwd): (got: $outCodexEmptyHome)"
echo "$outCodexEmptyHome" | jq -e '.detail | contains("non-absolute")' >/dev/null \
  || fail "cmd:codex_provisioned empty-CODEX_HOME detail should name the non-absolute path (got: $outCodexEmptyHome)"
echo "ok: cmd:codex_provisioned degraded when CODEX_HOME is present but empty (relative-path guard)"

# ── cmd:cadence_armed (pipeline-cadence) — HIMMEL-1100 ──────────────────────
pc_armed_dir="$work/pc-armed-dir"; mkdir -p "$pc_armed_dir"
cat > "$pc_armed_dir/pipeline-harvest.sh" <<'SH'
# himmel-cadence-runner-format: 7
SH
outPCp=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'pipeline-cadence');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { PIPELINE_BAT_DIR: '$(winpath "$pc_armed_dir")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outPCp" | jq -e '.actual == "present"' >/dev/null || fail "cmd:cadence_armed present (pipeline-cadence armed): (got: $outPCp)"

pc_unarmed_dir="$work/pc-unarmed-dir"; mkdir -p "$pc_unarmed_dir"
outPCa=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'pipeline-cadence');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { PIPELINE_BAT_DIR: '$(winpath "$pc_unarmed_dir")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outPCa" | jq -e '.actual == "absent"' >/dev/null || fail "cmd:cadence_armed absent (pipeline-cadence not armed): (got: $outPCa)"
echo "$outPCa" | jq -e '.detail | contains("not armed")' >/dev/null || fail "cmd:cadence_armed absent detail should say not armed (got: $outPCa)"

pc_no_resolver="$work/pc-no-resolver"; mkdir -p "$pc_no_resolver/scripts/lib"
outPCnr=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'pipeline-cadence');
const ctx = { repoRoot: '$(winpath "$pc_no_resolver")', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { PIPELINE_BAT_DIR: '$(winpath "$pc_unarmed_dir")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outPCnr" | jq -e '.actual == "degraded"' >/dev/null || fail "cmd:cadence_armed degraded (resolver missing — probe wiring broken): (got: $outPCnr)"
echo "$outPCnr" | jq -e '.detail | contains("cannot source resolver")' >/dev/null || fail "cmd:cadence_armed missing-resolver detail should name the sourcing failure (got: $outPCnr)"

# ── cmd:cadence_armed: spawn error -> degraded, NOT absent. HIMMEL-2289:
# PATH:'' alone no longer un-resolves bash (resolveProbeBash()'s
# Git-for-Windows/posix fallback candidates below aren't PATH-gated — see
# the no_such_bash_w comment above) — HIMMELCTL_BASH pinned to a path that is
# never created is what actually forces the spawn error and exercises the
# r.error branch.
outPCse=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'pipeline-cadence');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: { PATH: '', PIPELINE_BAT_DIR: '$(winpath "$pc_unarmed_dir")', HIMMELCTL_BASH: '$no_such_bash_w' } };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outPCse" | jq -e '.actual == "degraded"' >/dev/null || fail "cmd:cadence_armed degraded (spawn error, bash unresolvable): (got: $outPCse)"
echo "$outPCse" | jq -e '.detail | contains("spawn error")' >/dev/null || fail "cmd:cadence_armed spawn-error detail should name it (got: $outPCse)"

pc_bad_fn="$work/pc-bad-fn"; mkdir -p "$pc_bad_fn/scripts/lib"
cat > "$pc_bad_fn/scripts/lib/cadence-format.sh" <<'SH'
cadence_runner_stamp() { return 5; }
SH
outPCnf=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'pipeline-cadence');
const ctx = { repoRoot: '$(winpath "$pc_bad_fn")', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { PIPELINE_BAT_DIR: '$(winpath "$pc_unarmed_dir")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outPCnf" | jq -e '.actual == "degraded"' >/dev/null || fail "cmd:cadence_armed degraded (unexpected rc=5 from cadence_runner_stamp): (got: $outPCnf)"
echo "$outPCnf" | jq -e '.detail | contains("unexpected rc")' >/dev/null || fail "cmd:cadence_armed unexpected-rc detail should name it (got: $outPCnf)"
echo "ok: cmd:cadence_armed (pipeline-cadence) present/absent/degraded (resolver missing / spawn error / unexpected rc)"

# CodeRabbit fix (HIMMEL-1100 round 6, coderabbit-3): cadence_runner_stamp
# conflates "genuinely unarmed" and "dir exists but unreadable" into the
# SAME rc 1 — the absent-vs-degraded conflation this whole ticket exists to
# kill. Pre-checked in the probe script via a distinct exit code (4). On
# Windows/NTFS, chmod 000 does not reliably deny the OWNING user read
# access the way it does on POSIX — detected here (not assumed) via a real
# bash `[ -r ... ]` probe against the fixture BEFORE asserting anything, so
# this skips cleanly (with a note) instead of false-failing on a platform
# where the fixture itself can't be constructed; POSIX CI exercises it.
pc_unreadable_dir="$work/pc-unreadable-dir"; mkdir -p "$pc_unreadable_dir"
chmod 000 "$pc_unreadable_dir" 2>/dev/null || true
if bash -c "[ -r \"$(winpath "$pc_unreadable_dir")\" ]" 2>/dev/null; then
  chmod 755 "$pc_unreadable_dir" 2>/dev/null || true
  echo "ok: cmd:cadence_armed unreadable-dir case SKIPPED — chmod 000 is not enforced for the owning user on this platform (Windows/NTFS); POSIX CI exercises it"
else
  outPCur=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'pipeline-cadence');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { PIPELINE_BAT_DIR: '$(winpath "$pc_unreadable_dir")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
  chmod 755 "$pc_unreadable_dir" 2>/dev/null || true
  echo "$outPCur" | jq -e '.actual == "degraded"' >/dev/null \
    || fail "cmd:cadence_armed degraded (dir exists but is not readable — distinct from genuinely unarmed): (got: $outPCur)"
  echo "$outPCur" | jq -e '.detail | contains("not readable")' >/dev/null \
    || fail "cmd:cadence_armed unreadable-dir detail should name it (got: $outPCur)"
  echo "ok: cmd:cadence_armed — an existing-but-unreadable dir reads degraded, distinguished from genuinely unarmed (absent)"
fi

# ── cmd:cadence_armed: envVar/defaultSubdir wiring sanity for the other two ──
# cadences (codex-sweep-cadence, graphmap-cadence) — the full present/absent/
# degraded matrix is pinned once above for the shared probe TYPE; this
# confirms each item's OWN envVar override actually routes to ITS OWN dir,
# not a shared/copy-pasted one.
csc_armed_dir="$work/csc-armed-dir"; mkdir -p "$csc_armed_dir"
cat > "$csc_armed_dir/codex-sweep.bat" <<'BAT'
rem himmel-cadence-runner-format: 7
BAT
outCSCp=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'codex-sweep-cadence');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { SWEEP_BAT_DIR: '$(winpath "$csc_armed_dir")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outCSCp" | jq -e '.actual == "present"' >/dev/null || fail "cmd:cadence_armed (codex-sweep-cadence) present via SWEEP_BAT_DIR: (got: $outCSCp)"

gc_armed_dir="$work/gc-armed-dir"; mkdir -p "$gc_armed_dir"
cat > "$gc_armed_dir/graphmap-luna.sh" <<'SH'
# himmel-cadence-runner-format: 7
SH
outGCp=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'graphmap-cadence');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { GRAPHMAP_BAT_DIR: '$(winpath "$gc_armed_dir")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGCp" | jq -e '.actual == "present"' >/dev/null || fail "cmd:cadence_armed (graphmap-cadence) present via GRAPHMAP_BAT_DIR: (got: $outGCp)"
echo "ok: cmd:cadence_armed envVar wiring — codex-sweep-cadence/graphmap-cadence each route to their OWN dir"

# ── cmd:guardrail_block_status (guardrail-block-global) — HIMMEL-1100/1418 ──
# HIMMEL-1418: guardrail-block.mjs grew a `status --json` verb enumerating
# all 3 expected GUARDRAILS hooks with per-hook presence + node/wrapper/
# script resolution, and the probe now consumes it instead of the plain
# `guardrail-mode=<mode> node-resolves=<yes|no>` text line (which only ever
# proved "at least one owned hook exists and ITS node path resolves" —
# detectMode()'s `.some()`, nodeResolves()'s first-match return). This
# fixture is DELIBERATELY a 1-of-3 partial install (only auto-approve-safe-
# bash.sh wired, and even that one hook's wrapper/script paths are FAKE
# /x/... paths that don't resolve) — exactly what used to false-green as
# 'present' pre-HIMMEL-1100, and what the round-3 fix could only bound to
# 'degraded' for lack of per-hook data. It must still read degraded — the
# genuine 'present' path is proven separately below (full-install fixture).
gb_node_stub="$work/gb-node-stub"; : > "$gb_node_stub"; chmod +x "$gb_node_stub"
# A REAL, RUNNABLE stub file for the baked bash path too (CR fix, codex-adv-2
# then codex-adv-3): every fixture below that hardcoded the literal string
# "/bin/bash" was a POSIX-only path that never resolves on native Windows
# (fs.existsSync('/bin/bash') is false here) — harmless before bashResolves
# existed, but now feeds directly into `complete`. `chmod +x` on both stubs
# (round 3, codex-adv-3): the new node/bash usability check requires X_OK —
# a POSIX CI run would otherwise fail the full-install fixture below on a
# plain non-executable stub file (Windows' X_OK is a no-op, so this was
# masked here, but not on POSIX).
gb_bash_stub="$work/gb-bash-stub"; : > "$gb_bash_stub"; chmod +x "$gb_bash_stub"
gb_settings_present="$work/gb-settings-present/.claude"; mkdir -p "$gb_settings_present"
# CR fix (glm-2-r6, round 6): this fixture used to hardcode the literal
# string "/bin/bash" for GUARDRAIL_BASH — which RESOLVES on POSIX (ubuntu
# CI has a real /bin/bash) but never resolves on native Windows. The
# assertion below names the EXACT combination of broken parts
# ("bash/wrapper/script"), so a platform where bash happens to resolve
# would drop the "bash/" prefix and string-mismatch — red on the public
# mirror's ubuntu shell-unit job while staying green here. Fixed by baking
# a DELIBERATELY dead bash path instead (this fixture already wants
# everything about the one wired hook to be broken, so a genuinely
# nonexistent bash path is thematically consistent, not just a workaround):
# now bashResolves is false on EVERY platform, and the asserted detail
# string is identical everywhere.
gb_dead_bash_present="$(winpath "$work")/nonexistent-bash-for-partial-install"
"$node_bin" -e "
const fs = require('fs');
const nodePath = '$(winpath "$gb_node_stub")';
const deadBashPath = '$gb_dead_bash_present';
const command = 'GUARDRAIL_BASH=' + JSON.stringify(deadBashPath) + ' ' + JSON.stringify(nodePath) + ' \"/x/scripts/hooks/guardrail-skip-in-himmel.js\" \"/x/scripts/hooks/auto-approve-safe-bash.sh\"';
const settings = { hooks: { PreToolUse: [ { matcher: 'Bash', hooks: [ { type: 'command', command } ] } ] } };
fs.writeFileSync('$(winpath "$gb_settings_present")/settings.json', JSON.stringify(settings, null, 2));
"
outGBp=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'guardrail-block-global');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { CLAUDE_USER_SETTINGS: '$(winpath "$gb_settings_present")/settings.json' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGBp" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:guardrail_block_status: a 1-of-3-hooks partial install (mode=global, node-resolves=yes for the one wired hook, but its bash/wrapper/script paths are fake) must read degraded, NEVER present: (got: $outGBp)"
echo "$outGBp" | jq -e '.detail | contains("block-edit-on-main.sh: missing")' >/dev/null \
  || fail "cmd:guardrail_block_status partial-install detail should name the missing hooks (got: $outGBp)"
echo "$outGBp" | jq -e '.detail | contains("auto-approve-safe-bash.sh: bash/wrapper/script path does not resolve")' >/dev/null \
  || fail "cmd:guardrail_block_status partial-install detail should name the wired hook's own broken paths, including its (now deliberately dead, platform-invariant) bash path (got: $outGBp)"
echo "ok: cmd:guardrail_block_status — a partial (1-of-3) install reads degraded, never a false present, with per-hook detail"

# ── full (3-of-3) install, every hook's matcher CORRECT and every path
# (bash/node/wrapper/script) genuinely resolving → present ─────────────────
# HIMMEL-1418's whole point: `complete` in status --json can only be true
# when EVERY GUARDRAILS hook is present, its ACTUAL matcher exactly matches
# what it needs for full tool coverage, and bash/node/wrapper/script paths
# ALL resolve — so a genuinely fully-armed machine now reads present instead
# of being permanently bounded to degraded. HIMMEL-1422: this fixture bakes
# wrapper/script paths under $repo_root_w, so its ctx.env below PINS
# HIMMEL_REPO to that same $repo_root_w — hermetic against whatever
# HIMMEL_REPO the ambient shell running this suite happens to carry (a real
# operator machine auto-sets it in ~/.claude/settings.json, typically
# pointing at the PRIMARY checkout, not necessarily this worktree); without
# the pin, guardrail-block.mjs's trust-anchor check would compare this
# fixture's baked paths against a DIFFERENT checkout and read a false
# anchor mismatch.
gb_settings_full="$work/gb-settings-full/.claude"; mkdir -p "$gb_settings_full"
"$node_bin" -e "
const fs = require('fs');
const nodePath = '$(winpath "$gb_node_stub")';
const bashPath = '$(winpath "$gb_bash_stub")';
const repoRoot = '$repo_root_w';
const basenames = ['auto-approve-safe-bash.sh', 'block-edit-on-main.sh', 'block-read-secrets.sh'];
const matchers = { 'auto-approve-safe-bash.sh': 'Bash', 'block-edit-on-main.sh': 'Edit|Write|MultiEdit|NotebookEdit', 'block-read-secrets.sh': 'Bash|PowerShell|Read|Grep' };
const wrapper = repoRoot + '/scripts/hooks/guardrail-skip-in-himmel.js';
const groups = basenames.map((basename) => ({
  matcher: matchers[basename],
  hooks: [ { type: 'command', command: 'GUARDRAIL_BASH=' + JSON.stringify(bashPath) + ' ' + JSON.stringify(nodePath) + ' ' + JSON.stringify(wrapper) + ' ' + JSON.stringify(repoRoot + '/scripts/hooks/' + basename) } ],
}));
fs.writeFileSync('$(winpath "$gb_settings_full")/settings.json', JSON.stringify({ hooks: { PreToolUse: groups } }, null, 2));
"
outGBf=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'guardrail-block-global');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { CLAUDE_USER_SETTINGS: '$(winpath "$gb_settings_full")/settings.json', HIMMEL_REPO: '$repo_root_w' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGBf" | jq -e '.actual == "present"' >/dev/null \
  || fail "cmd:guardrail_block_status: a genuine 3-of-3 install (every hook wired under its correct matcher, bash/node/wrapper/script all resolving, HIMMEL-1422 trust anchor matching) must read present: (got: $outGBf)"
echo "$outGBf" | jq -e '.detail | contains("3 guardrail hooks present, correctly matched, and resolving")' >/dev/null \
  || fail "cmd:guardrail_block_status present detail should confirm all 3 hooks (got: $outGBf)"
echo "ok: cmd:guardrail_block_status — a genuine full (3-of-3) install now reads present via status --json"

# ── HIMMEL-1422: same-basename, WRONG-checkout wiring → degraded, never
# present, even though every other check (basename ownership, matcher,
# bash/node/wrapper/script resolution) is genuinely fine. This is the
# ticket's motivating scenario: a stale/moved checkout (or an unrelated
# same-named stub elsewhere) that ownsGuardrail()'s basename-only identity
# check alone cannot distinguish from the real thing. auto-approve-safe-
# bash.sh's wrapper+script here live under a SEPARATE, real, non-empty
# checkout ($gb_wrong_checkout) — not $repo_root_w, the pinned trust
# anchor — so the probe must flag it, not the wrapper/script *Resolves
# checks (which stay true: the files genuinely exist and are readable). ───
gb_wrong_checkout="$work/gb-wrong-checkout"; mkdir -p "$gb_wrong_checkout/scripts/hooks"
: > "$gb_wrong_checkout/scripts/hooks/guardrail-skip-in-himmel.js"
printf '// real content, not a truncated stub\n' > "$gb_wrong_checkout/scripts/hooks/guardrail-skip-in-himmel.js"
printf '# real content, not a truncated stub\n' > "$gb_wrong_checkout/scripts/hooks/auto-approve-safe-bash.sh"
gb_settings_wrong_checkout="$work/gb-settings-wrong-checkout/.claude"; mkdir -p "$gb_settings_wrong_checkout"
"$node_bin" -e "
const fs = require('fs');
const nodePath = '$(winpath "$gb_node_stub")';
const bashPath = '$(winpath "$gb_bash_stub")';
const wrongRepo = '$(winpath "$gb_wrong_checkout")';
const command = 'GUARDRAIL_BASH=' + JSON.stringify(bashPath) + ' ' + JSON.stringify(nodePath) + ' ' + JSON.stringify(wrongRepo + '/scripts/hooks/guardrail-skip-in-himmel.js') + ' ' + JSON.stringify(wrongRepo + '/scripts/hooks/auto-approve-safe-bash.sh');
const settings = { hooks: { PreToolUse: [ { matcher: 'Bash', hooks: [ { type: 'command', command } ] } ] } };
fs.writeFileSync('$(winpath "$gb_settings_wrong_checkout")/settings.json', JSON.stringify(settings, null, 2));
"
outGBwc=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'guardrail-block-global');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { CLAUDE_USER_SETTINGS: '$(winpath "$gb_settings_wrong_checkout")/settings.json', HIMMEL_REPO: '$repo_root_w' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGBwc" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:guardrail_block_status: a same-basename wrapper/script wired from a WRONG checkout (not the pinned trust anchor) must read degraded, never present (HIMMEL-1422): (got: $outGBwc)"
echo "$outGBwc" | jq -e '.detail | contains("does not match trust anchor")' >/dev/null \
  || fail "cmd:guardrail_block_status wrong-checkout detail should name the trust-anchor mismatch (got: $outGBwc)"
echo "ok: cmd:guardrail_block_status — same-basename wiring from a wrong checkout reads degraded with the trust-anchor mismatch named, never present (HIMMEL-1422)"

# ── HIMMEL-1422: correct-checkout, correct path, but a TRUNCATED (empty)
# script file → degraded, never present. Uses its OWN fake anchor checkout
# ($gb_truncated_anchor, HIMMEL_REPO pinned to it) rather than truncating a
# file under the real $repo_root_w scripts/hooks/ (which would break this
# very test run's own guardrail wiring) — the wrapper/script paths baked
# into settings.json live UNDER that anchor, so wrapperMatchesAnchor/
# scriptMatchesAnchor stay true (this is NOT the wrong-checkout case above);
# only the script's CONTENT is a no-op, exactly the empty-guardrail-skip-
# in-himmel.js scenario from the ticket's motivating report. ───────────────
gb_truncated_anchor="$work/gb-truncated-anchor"; mkdir -p "$gb_truncated_anchor/scripts/hooks"
printf '// real content, not a truncated stub\n' > "$gb_truncated_anchor/scripts/hooks/guardrail-skip-in-himmel.js"
: > "$gb_truncated_anchor/scripts/hooks/auto-approve-safe-bash.sh"
gb_settings_empty_script="$work/gb-settings-empty-script/.claude"; mkdir -p "$gb_settings_empty_script"
"$node_bin" -e "
const fs = require('fs');
const nodePath = '$(winpath "$gb_node_stub")';
const bashPath = '$(winpath "$gb_bash_stub")';
const anchorRepo = '$(winpath "$gb_truncated_anchor")';
const wrapper = anchorRepo + '/scripts/hooks/guardrail-skip-in-himmel.js';
const command = 'GUARDRAIL_BASH=' + JSON.stringify(bashPath) + ' ' + JSON.stringify(nodePath) + ' ' + JSON.stringify(wrapper) + ' ' + JSON.stringify(anchorRepo + '/scripts/hooks/auto-approve-safe-bash.sh');
const settings = { hooks: { PreToolUse: [ { matcher: 'Bash', hooks: [ { type: 'command', command } ] } ] } };
fs.writeFileSync('$(winpath "$gb_settings_empty_script")/settings.json', JSON.stringify(settings, null, 2));
"
outGBes=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'guardrail-block-global');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { CLAUDE_USER_SETTINGS: '$(winpath "$gb_settings_empty_script")/settings.json', HIMMEL_REPO: '$(winpath "$gb_truncated_anchor")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGBes" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:guardrail_block_status: an anchor-matching but EMPTY script file must read degraded, never present (HIMMEL-1422 truncation floor): (got: $outGBes)"
echo "$outGBes" | jq -e '.detail | contains("does not match trust anchor") | not' >/dev/null \
  || fail "cmd:guardrail_block_status empty-script detail should be a content problem, NOT an anchor mismatch — the path IS the anchor's own copy (got: $outGBes)"
echo "$outGBes" | jq -e '.detail | contains("script")' >/dev/null \
  || fail "cmd:guardrail_block_status empty-script detail should name script as the broken part (got: $outGBes)"
echo "ok: cmd:guardrail_block_status — an anchor-matching but empty (truncated) script file reads degraded, never present (HIMMEL-1422 content-sanity floor)"

# ── codex-adv-1: all 3 hooks wired, every path resolving, but under the
# WRONG matcher (all 3 crammed into a single 'Bash' group) → degraded, never
# present. Without this check, block-edit-on-main.sh would never fire on
# Edit/Write/MultiEdit/NotebookEdit and block-read-secrets.sh would never
# fire on PowerShell/Read/Grep, while status --json still claimed complete. ─
gb_settings_bad_matcher="$work/gb-settings-bad-matcher/.claude"; mkdir -p "$gb_settings_bad_matcher"
"$node_bin" -e "
const fs = require('fs');
const nodePath = '$(winpath "$gb_node_stub")';
const bashPath = '$(winpath "$gb_bash_stub")';
const repoRoot = '$repo_root_w';
const basenames = ['auto-approve-safe-bash.sh', 'block-edit-on-main.sh', 'block-read-secrets.sh'];
const wrapper = repoRoot + '/scripts/hooks/guardrail-skip-in-himmel.js';
const hooks = basenames.map((basename) => ({ type: 'command', command: 'GUARDRAIL_BASH=' + JSON.stringify(bashPath) + ' ' + JSON.stringify(nodePath) + ' ' + JSON.stringify(wrapper) + ' ' + JSON.stringify(repoRoot + '/scripts/hooks/' + basename) }));
fs.writeFileSync('$(winpath "$gb_settings_bad_matcher")/settings.json', JSON.stringify({ hooks: { PreToolUse: [ { matcher: 'Bash', hooks } ] } }, null, 2));
"
outGBm=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'guardrail-block-global');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { CLAUDE_USER_SETTINGS: '$(winpath "$gb_settings_bad_matcher")/settings.json' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGBm" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:guardrail_block_status: all 3 hooks wired, every path resolving, but under the WRONG matcher must read degraded, never present (codex-adv-1): (got: $outGBm)"
echo "$outGBm" | jq -e '.detail | contains("matcher mismatch")' >/dev/null \
  || fail "cmd:guardrail_block_status wrong-matcher detail should name the matcher mismatch (got: $outGBm)"
echo "$outGBm" | jq -e '.detail | contains("block-edit-on-main.sh")' >/dev/null \
  || fail "cmd:guardrail_block_status wrong-matcher detail should name block-edit-on-main.sh specifically (got: $outGBm)"
echo "ok: cmd:guardrail_block_status — all-paths-resolving under the WRONG matcher reads degraded, never present (codex-adv-1)"

# ── codex-adv-2: all 3 hooks wired under their CORRECT matcher, node/
# wrapper/script all resolving, but the baked GUARDRAIL_BASH executable is
# missing → degraded, never present. The wrapper fails closed on a missing
# bash at runtime; a status --json that ignored bash would claim complete
# while the guardrail is machine-wide broken. ──────────────────────────────
gb_settings_dead_bash="$work/gb-settings-dead-bash/.claude"; mkdir -p "$gb_settings_dead_bash"
"$node_bin" -e "
const fs = require('fs');
const nodePath = '$(winpath "$gb_node_stub")';
const repoRoot = '$repo_root_w';
const basenames = ['auto-approve-safe-bash.sh', 'block-edit-on-main.sh', 'block-read-secrets.sh'];
const matchers = { 'auto-approve-safe-bash.sh': 'Bash', 'block-edit-on-main.sh': 'Edit|Write|MultiEdit|NotebookEdit', 'block-read-secrets.sh': 'Bash|PowerShell|Read|Grep' };
const wrapper = repoRoot + '/scripts/hooks/guardrail-skip-in-himmel.js';
const deadBash = repoRoot + '/scripts/hooks/NONEXISTENT-bash.exe';
const groups = basenames.map((basename) => ({
  matcher: matchers[basename],
  hooks: [ { type: 'command', command: 'GUARDRAIL_BASH=' + JSON.stringify(deadBash) + ' ' + JSON.stringify(nodePath) + ' ' + JSON.stringify(wrapper) + ' ' + JSON.stringify(repoRoot + '/scripts/hooks/' + basename) } ],
}));
fs.writeFileSync('$(winpath "$gb_settings_dead_bash")/settings.json', JSON.stringify({ hooks: { PreToolUse: groups } }, null, 2));
"
outGBb=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'guardrail-block-global');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { CLAUDE_USER_SETTINGS: '$(winpath "$gb_settings_dead_bash")/settings.json' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGBb" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:guardrail_block_status: all 3 hooks correctly wired but the baked bash executable is missing must read degraded, never present (codex-adv-2): (got: $outGBb)"
echo "$outGBb" | jq -e '.detail | contains("bash")' >/dev/null \
  || fail "cmd:guardrail_block_status dead-bash detail should name bash as unresolved (got: $outGBb)"
echo "$outGBb" | jq -e '.detail | contains("path does not resolve")' >/dev/null \
  || fail "cmd:guardrail_block_status dead-bash detail should say the path does not resolve (got: $outGBb)"
echo "ok: cmd:guardrail_block_status — a genuinely wired install with a dead baked bash path reads degraded, never present (codex-adv-2)"

# ── codex-adv-3 (round 3): fs.existsSync() alone accepts a DIRECTORY as
# "resolves" — all 3 hooks wired, matcher correct, but the baked node path
# is a DIRECTORY (not a file) → degraded, never present, even though
# fs.existsSync() on that path would return true. ──────────────────────────
gb_node_dir="$work/gb-node-is-a-directory"; mkdir -p "$gb_node_dir"
gb_settings_node_dir="$work/gb-settings-node-dir/.claude"; mkdir -p "$gb_settings_node_dir"
"$node_bin" -e "
const fs = require('fs');
const nodePath = '$(winpath "$gb_node_dir")';
const bashPath = '$(winpath "$gb_bash_stub")';
const repoRoot = '$repo_root_w';
const basenames = ['auto-approve-safe-bash.sh', 'block-edit-on-main.sh', 'block-read-secrets.sh'];
const matchers = { 'auto-approve-safe-bash.sh': 'Bash', 'block-edit-on-main.sh': 'Edit|Write|MultiEdit|NotebookEdit', 'block-read-secrets.sh': 'Bash|PowerShell|Read|Grep' };
const wrapper = repoRoot + '/scripts/hooks/guardrail-skip-in-himmel.js';
const groups = basenames.map((basename) => ({
  matcher: matchers[basename],
  hooks: [ { type: 'command', command: 'GUARDRAIL_BASH=' + JSON.stringify(bashPath) + ' ' + JSON.stringify(nodePath) + ' ' + JSON.stringify(wrapper) + ' ' + JSON.stringify(repoRoot + '/scripts/hooks/' + basename) } ],
}));
fs.writeFileSync('$(winpath "$gb_settings_node_dir")/settings.json', JSON.stringify({ hooks: { PreToolUse: groups } }, null, 2));
"
outGBnd=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'guardrail-block-global');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { CLAUDE_USER_SETTINGS: '$(winpath "$gb_settings_node_dir")/settings.json' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGBnd" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:guardrail_block_status: a DIRECTORY at the baked node path must read degraded, never present, even though fs.existsSync() would call it present (codex-adv-3): (got: $outGBnd)"
echo "$outGBnd" | jq -e '.detail | contains("node")' >/dev/null \
  || fail "cmd:guardrail_block_status directory-at-node-path detail should name node as unresolved (got: $outGBnd)"
echo "ok: cmd:guardrail_block_status — a DIRECTORY at the baked node path reads degraded, never present (codex-adv-3)"

# ── codex-adv-4 (round 3): duplicate owned entries per basename were
# invisible past the first match — 6 configured entries (one valid + one
# dead-node duplicate per guardrail) used to report only the 3 valid ones
# and read complete:true, even though the dead duplicate is still
# independently wired and can fail closed at runtime. ──────────────────────
gb_dup_dead_node="$work/gb-dup-dead-node"
gb_settings_dup="$work/gb-settings-dup/.claude"; mkdir -p "$gb_settings_dup"
"$node_bin" -e "
const fs = require('fs');
const nodePath = '$(winpath "$gb_node_stub")';
const deadNodePath = '$(winpath "$gb_dup_dead_node")';
const bashPath = '$(winpath "$gb_bash_stub")';
const repoRoot = '$repo_root_w';
const basenames = ['auto-approve-safe-bash.sh', 'block-edit-on-main.sh', 'block-read-secrets.sh'];
const matchers = { 'auto-approve-safe-bash.sh': 'Bash', 'block-edit-on-main.sh': 'Edit|Write|MultiEdit|NotebookEdit', 'block-read-secrets.sh': 'Bash|PowerShell|Read|Grep' };
const wrapper = repoRoot + '/scripts/hooks/guardrail-skip-in-himmel.js';
const cmdFor = (node, basename) => 'GUARDRAIL_BASH=' + JSON.stringify(bashPath) + ' ' + JSON.stringify(node) + ' ' + JSON.stringify(wrapper) + ' ' + JSON.stringify(repoRoot + '/scripts/hooks/' + basename);
// ONE valid group per guardrail (the genuine install) PLUS one extra group
// per guardrail wired to a dead node path — 6 owned entries total, exactly
// the reproduced shape.
const validGroups = basenames.map((basename) => ({ matcher: matchers[basename], hooks: [ { type: 'command', command: cmdFor(nodePath, basename) } ] }));
const dupGroups = basenames.map((basename) => ({ matcher: matchers[basename], hooks: [ { type: 'command', command: cmdFor(deadNodePath, basename) } ] }));
fs.writeFileSync('$(winpath "$gb_settings_dup")/settings.json', JSON.stringify({ hooks: { PreToolUse: [ ...validGroups, ...dupGroups ] } }, null, 2));
"
outGBdup=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'guardrail-block-global');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { CLAUDE_USER_SETTINGS: '$(winpath "$gb_settings_dup")/settings.json' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGBdup" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:guardrail_block_status: a valid entry PLUS a dead-node duplicate per guardrail (6 entries total) must read degraded, never present (codex-adv-4): (got: $outGBdup)"
echo "$outGBdup" | jq -e '.detail | contains("duplicate entries wired")' >/dev/null \
  || fail "cmd:guardrail_block_status duplicate-entry detail should name the duplication (got: $outGBdup)"
echo "ok: cmd:guardrail_block_status — a valid entry plus a dead-node duplicate per guardrail reads degraded, never present (codex-adv-4)"

# ── codex-adv-5 (round 4): ownership by whole-string substring search let a
# DECOY command through — the real (4th quoted) script arg for all 3 groups
# is a stub file, and each guardrail's actual basename appears ONLY in a
# trailing shell comment. The pre-fix isOwnedHook()/parseOwnedCommand() pair
# would have reported this as "owned, script resolves" per guardrail. Fixed
# semantic: NOT owned by any guardrail at all (present:false/entryCount:0 —
# reads identically to "never wired"), so this must read degraded (mode
# still reads global off the decoy — detectMode()'s loose match is
# unchanged/out of scope — but no guardrail has a genuine owned entry). ────
gb_decoy_script="$work/gb-decoy-script.sh"; : > "$gb_decoy_script"
gb_settings_decoy="$work/gb-settings-decoy/.claude"; mkdir -p "$gb_settings_decoy"
"$node_bin" -e "
const fs = require('fs');
const nodePath = '$(winpath "$gb_node_stub")';
const bashPath = '$(winpath "$gb_bash_stub")';
const decoyScript = '$(winpath "$gb_decoy_script")';
const repoRoot = '$repo_root_w';
const basenames = ['auto-approve-safe-bash.sh', 'block-edit-on-main.sh', 'block-read-secrets.sh'];
const matchers = { 'auto-approve-safe-bash.sh': 'Bash', 'block-edit-on-main.sh': 'Edit|Write|MultiEdit|NotebookEdit', 'block-read-secrets.sh': 'Bash|PowerShell|Read|Grep' };
const wrapper = repoRoot + '/scripts/hooks/guardrail-skip-in-himmel.js';
// Real script arg is the SAME decoy for all 3; the guardrail's own basename
// sits ONLY in a trailing comment — no quoted-argument parse ever sees it.
const groups = basenames.map((basename) => ({
  matcher: matchers[basename],
  hooks: [ { type: 'command', command: 'GUARDRAIL_BASH=' + JSON.stringify(bashPath) + ' ' + JSON.stringify(nodePath) + ' ' + JSON.stringify(wrapper) + ' ' + JSON.stringify(decoyScript) + ' # ' + basename } ],
}));
fs.writeFileSync('$(winpath "$gb_settings_decoy")/settings.json', JSON.stringify({ hooks: { PreToolUse: groups } }, null, 2));
"
outGBdecoy=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'guardrail-block-global');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { CLAUDE_USER_SETTINGS: '$(winpath "$gb_settings_decoy")/settings.json' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGBdecoy" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:guardrail_block_status: a decoy script arg with the real basename only in a trailing comment must read degraded, never present (codex-adv-5): (got: $outGBdecoy)"
echo "$outGBdecoy" | jq -e '.detail | contains("auto-approve-safe-bash.sh: missing")' >/dev/null \
  || fail "cmd:guardrail_block_status decoy detail should report the guardrail as missing (not owned by a comment mention) (got: $outGBdecoy)"
echo "$outGBdecoy" | jq -e '.detail | contains("block-edit-on-main.sh: missing")' >/dev/null \
  || fail "cmd:guardrail_block_status decoy detail should report block-edit-on-main.sh as missing too (got: $outGBdecoy)"
echo "$outGBdecoy" | jq -e '.detail | contains("block-read-secrets.sh: missing")' >/dev/null \
  || fail "cmd:guardrail_block_status decoy detail should report block-read-secrets.sh as missing too (got: $outGBdecoy)"
echo "ok: cmd:guardrail_block_status — a decoy script with the real guardrail basename only in a trailing comment reads degraded (not owned by any guardrail), never present (codex-adv-5)"

# ── codex-adv-7 (round 5): a canonical (fully valid) entry for all 3
# guardrails PLUS a SAME-IDENTITY duplicate with a TRAILING EXTRA ARGUMENT
# on auto-approve-safe-bash.sh — guardrail-skip-in-himmel.js reads only
# process.argv[2] (the script path) and ignores anything after it, so this
# duplicate is RUNTIME-RELEVANT (Claude still executes it identically to
# the canonical one), not a decoy. Round 4's anchored regex alone would make
# it invisible entirely (entryCount would stay 1, complete:true) even
# though it's wired with a DEAD node path — reopening round 3's own blind
# spot via a different command shape. Must read degraded, never present. ──
gb_noncanon_dead_node="$work/gb-noncanon-dead-node"
gb_settings_noncanon="$work/gb-settings-noncanon/.claude"; mkdir -p "$gb_settings_noncanon"
"$node_bin" -e "
const fs = require('fs');
const nodePath = '$(winpath "$gb_node_stub")';
const deadNodePath = '$(winpath "$gb_noncanon_dead_node")';
const bashPath = '$(winpath "$gb_bash_stub")';
const repoRoot = '$repo_root_w';
const basenames = ['auto-approve-safe-bash.sh', 'block-edit-on-main.sh', 'block-read-secrets.sh'];
const matchers = { 'auto-approve-safe-bash.sh': 'Bash', 'block-edit-on-main.sh': 'Edit|Write|MultiEdit|NotebookEdit', 'block-read-secrets.sh': 'Bash|PowerShell|Read|Grep' };
const wrapper = repoRoot + '/scripts/hooks/guardrail-skip-in-himmel.js';
const cmdFor = (node, basename, trailing) => 'GUARDRAIL_BASH=' + JSON.stringify(bashPath) + ' ' + JSON.stringify(node) + ' ' + JSON.stringify(wrapper) + ' ' + JSON.stringify(repoRoot + '/scripts/hooks/' + basename) + (trailing ? ' \"extra-trailing-arg\"' : '');
// ONE canonical, fully-valid entry per guardrail, PLUS a non-canonical
// (trailing-arg) duplicate on auto-approve-safe-bash.sh alone, wired to a
// dead node path.
const canonicalGroups = basenames.map((basename) => ({ matcher: matchers[basename], hooks: [ { type: 'command', command: cmdFor(nodePath, basename, false) } ] }));
const noncanonGroup = { matcher: 'Bash', hooks: [ { type: 'command', command: cmdFor(deadNodePath, 'auto-approve-safe-bash.sh', true) } ] };
fs.writeFileSync('$(winpath "$gb_settings_noncanon")/settings.json', JSON.stringify({ hooks: { PreToolUse: [ ...canonicalGroups, noncanonGroup ] } }, null, 2));
"
outGBnc=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'guardrail-block-global');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { CLAUDE_USER_SETTINGS: '$(winpath "$gb_settings_noncanon")/settings.json' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGBnc" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:guardrail_block_status: a canonical entry PLUS a same-identity trailing-arg duplicate must read degraded, never present (codex-adv-7): (got: $outGBnc)"
echo "$outGBnc" | jq -e '.detail | contains("non-canonical entr")' >/dev/null \
  || fail "cmd:guardrail_block_status non-canonical-duplicate detail should name the anomaly (got: $outGBnc)"
echo "$outGBnc" | jq -e '.detail | contains("auto-approve-safe-bash.sh")' >/dev/null \
  || fail "cmd:guardrail_block_status non-canonical-duplicate detail should name auto-approve-safe-bash.sh specifically (got: $outGBnc)"
echo "ok: cmd:guardrail_block_status — a canonical entry plus a same-identity trailing-arg duplicate reads degraded, never present (codex-adv-7)"

# ── full install but the WRAPPER itself has rotted (a moved/deleted himmel
# checkout — exactly the drift class report_guardrail_block exists to
# catch) → degraded, never present, even though all 3 hooks are wired. ────
gb_settings_dead_wrapper="$work/gb-settings-dead-wrapper/.claude"; mkdir -p "$gb_settings_dead_wrapper"
"$node_bin" -e "
const fs = require('fs');
const nodePath = '$(winpath "$gb_node_stub")';
const repoRoot = '$repo_root_w';
const basenames = ['auto-approve-safe-bash.sh', 'block-edit-on-main.sh', 'block-read-secrets.sh'];
const matchers = { 'auto-approve-safe-bash.sh': 'Bash', 'block-edit-on-main.sh': 'Edit|Write|MultiEdit|NotebookEdit', 'block-read-secrets.sh': 'Bash|PowerShell|Read|Grep' };
// Basename stays 'guardrail-skip-in-himmel.js' (isOwnedHook matches on that
// substring) but lives under a directory that doesn't exist — the file
// itself does not resolve.
const wrapper = repoRoot + '/scripts/hooks/NONEXISTENT-DIR/guardrail-skip-in-himmel.js';
const groups = basenames.map((basename) => ({
  matcher: matchers[basename],
  hooks: [ { type: 'command', command: 'GUARDRAIL_BASH=\"/bin/bash\" ' + JSON.stringify(nodePath) + ' ' + JSON.stringify(wrapper) + ' ' + JSON.stringify(repoRoot + '/scripts/hooks/' + basename) } ],
}));
fs.writeFileSync('$(winpath "$gb_settings_dead_wrapper")/settings.json', JSON.stringify({ hooks: { PreToolUse: groups } }, null, 2));
"
outGBw=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'guardrail-block-global');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { CLAUDE_USER_SETTINGS: '$(winpath "$gb_settings_dead_wrapper")/settings.json' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGBw" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:guardrail_block_status: all 3 hooks wired but the shared wrapper path is dead must read degraded, not present: (got: $outGBw)"
echo "$outGBw" | jq -e '.detail | contains("wrapper")' >/dev/null \
  || fail "cmd:guardrail_block_status dead-wrapper detail should name the wrapper as unresolved (got: $outGBw)"
echo "$outGBw" | jq -e '.detail | contains("path does not resolve")' >/dev/null \
  || fail "cmd:guardrail_block_status dead-wrapper detail should say the path does not resolve (got: $outGBw)"
echo "ok: cmd:guardrail_block_status — a rotted wrapper path on an otherwise-3-of-3 install reads degraded, never present"

gb_settings_absent="$work/gb-settings-absent"; mkdir -p "$gb_settings_absent"
outGBa=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'guardrail-block-global');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { CLAUDE_USER_SETTINGS: '$(winpath "$gb_settings_absent")/settings.json' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGBa" | jq -e '.actual == "absent"' >/dev/null || fail "cmd:guardrail_block_status absent (no settings file -> project/default mode): (got: $outGBa)"

gb_settings_degraded="$work/gb-settings-degraded/.claude"; mkdir -p "$gb_settings_degraded"
"$node_bin" -e "
const fs = require('fs');
const nodePath = '$(winpath "$work")/nonexistent-node-path';
const command = 'GUARDRAIL_BASH=\"/bin/bash\" ' + JSON.stringify(nodePath) + ' \"/x/scripts/hooks/guardrail-skip-in-himmel.js\" \"/x/scripts/hooks/auto-approve-safe-bash.sh\"';
const settings = { hooks: { PreToolUse: [ { matcher: 'Bash', hooks: [ { type: 'command', command } ] } ] } };
fs.writeFileSync('$(winpath "$gb_settings_degraded")/settings.json', JSON.stringify(settings, null, 2));
"
outGBd=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'guardrail-block-global');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { CLAUDE_USER_SETTINGS: '$(winpath "$gb_settings_degraded")/settings.json' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGBd" | jq -e '.actual == "degraded"' >/dev/null || fail "cmd:guardrail_block_status degraded (global mode, node path rotted): (got: $outGBd)"
echo "$outGBd" | jq -e '.detail | contains("path does not resolve")' >/dev/null || fail "cmd:guardrail_block_status degraded detail should say a path no longer resolves (got: $outGBd)"

gb_bad_script_dir="$work/gb-bad-script"; mkdir -p "$gb_bad_script_dir/scripts/hooks"
cat > "$gb_bad_script_dir/scripts/hooks/guardrail-block.mjs" <<'JS'
process.stdout.write('not-the-expected-format\n');
JS
outGBu=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'guardrail-block-global');
const ctx = { repoRoot: '$(winpath "$gb_bad_script_dir")', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGBu" | jq -e '.actual == "degraded"' >/dev/null || fail "cmd:guardrail_block_status degraded (unparseable output): (got: $outGBu)"
echo "$outGBu" | jq -e '.detail | contains("unparseable")' >/dev/null || fail "cmd:guardrail_block_status unparseable-output detail should name it (got: $outGBu)"

# HIMMEL-1418: mode is valid JSON and present, but the 'hooks' array is
# MISSING entirely (a wiring/shape break in guardrail-block.mjs's own
# output, distinct from the plain-unparseable case above) — must NOT be
# treated as a confirmed install; same "missing field is not proof" stance
# as HIMMEL-1100 round 2's node-resolves check, now against the richer verb.
gb_missing_field_dir="$work/gb-missing-field"; mkdir -p "$gb_missing_field_dir/scripts/hooks"
cat > "$gb_missing_field_dir/scripts/hooks/guardrail-block.mjs" <<'JS'
process.stdout.write(JSON.stringify({ mode: 'global' }) + '\n');
JS
outGBmf=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'guardrail-block-global');
const ctx = { repoRoot: '$(winpath "$gb_missing_field_dir")', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGBmf" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:guardrail_block_status degraded (mode=global but 'hooks' array missing — must NOT fall through to present): (got: $outGBmf)"
echo "$outGBmf" | jq -e '.detail | contains("missing expected")' >/dev/null \
  || fail "cmd:guardrail_block_status missing-hooks-field detail should name it (got: $outGBmf)"
echo "ok: cmd:guardrail_block_status degraded when mode=global but the 'hooks' array is missing from status --json output"

# CR fix (codex-1-r6, round 6): mode=global, complete=TRUE, but 'hooks' is a
# genuinely present, well-typed EMPTY array. Array.isArray([]) is true, so
# without an explicit non-empty check this would sail straight past the
# shape guard and into the `complete === true` branch, trusted as 'present'
# despite attesting ZERO guardrails — a malformed/truncated producer output
# read as a clean, complete install. Raised as a suggestion in round 2,
# re-raised as Important in round 6.
gb_empty_hooks_dir="$work/gb-empty-hooks"; mkdir -p "$gb_empty_hooks_dir/scripts/hooks"
cat > "$gb_empty_hooks_dir/scripts/hooks/guardrail-block.mjs" <<'JS'
process.stdout.write(JSON.stringify({ mode: 'global', complete: true, hooks: [] }) + '\n');
JS
outGBeh=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'guardrail-block-global');
const ctx = { repoRoot: '$(winpath "$gb_empty_hooks_dir")', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGBeh" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:guardrail_block_status degraded (mode=global, complete=true, but hooks=[] — must NOT be trusted as present): (got: $outGBeh)"
echo "$outGBeh" | jq -e '.detail | contains("missing expected")' >/dev/null \
  || fail "cmd:guardrail_block_status empty-hooks-array detail should name the shape problem (got: $outGBeh)"
echo "ok: cmd:guardrail_block_status degraded when mode=global, complete=true, but the 'hooks' array is empty (codex-1-r6)"

# ── codex-1-r7 (round 7 — third raise, each stricter): round 6 closed the
# EMPTY hooks[] case, but a TRUNCATED payload — complete:true with FEWER
# hook objects than the real contract enumerates, that one object itself
# fully healthy — still sailed through on parsed.complete alone, since
# nothing recomputed completeness FROM the entries. The probe now requires
# parsed.complete AND an independent per-entry recomputation to AGREE. ────

# Case 1 (the accepted floor, DOCUMENTED not fixed — a residual gap distinct
# from HIMMEL-1422's trust-anchor scope, which this fixture's payload now
# also satisfies via wrapperMatchesAnchor/scriptMatchesAnchor: true): a
# non-empty, INTERNALLY CONSISTENT array with only 1 (of the real 3) hook
# objects, that one fully healthy (including anchor-matching) — complete:true
# and the recomputation over the given entries agree (both say "healthy"),
# so this reads present. This is the accepted limit: detecting "too few
# entries" needs the EXPECTED count, which only the producer owns; asserting
# a count here would duplicate producer vocabulary the same way round 6
# already rejected. (CR round 2: the payload now also carries the FULL v2
# attestation set, so the round-2 fail-closed-on-v2-absence gate does NOT
# trip it — isolating the COUNT question this case exists to document.)
gb_truncated_dir="$work/gb-truncated"; mkdir -p "$gb_truncated_dir/scripts/hooks"
cat > "$gb_truncated_dir/scripts/hooks/guardrail-block.mjs" <<'JS'
process.stdout.write(JSON.stringify({
  mode: 'global',
  anchor: { repo: '/fake/repo', source: 'HIMMEL_REPO' },
  auditAnchor: { repo: '/fake/repo', source: 'self-checkout' },
  anchorMatchesAudit: true,
  complete: true,
  contentIntegrityComplete: true,
  auditAnchorComplete: true,
  attestationComplete: true,
  hooks: [
    {
      basename: 'auto-approve-safe-bash.sh', matcher: 'Bash', expectedMatcher: 'Bash', matcherMatches: true,
      present: true, entryCount: 1,
      bashPath: '/fake/bash', bashResolves: true,
      nodePath: '/fake/node', nodeResolves: true,
      wrapperPath: '/fake/wrapper.js', wrapperResolves: true,
      anchorWrapperPath: '/fake/repo/scripts/hooks/guardrail-skip-in-himmel.js', wrapperMatchesAnchor: true,
      auditWrapperPath: '/fake/repo/scripts/hooks/guardrail-skip-in-himmel.js', wrapperMatchesAuditAnchor: true,
      wrapperIntegrity: { verdict: 'healthy', reason: 'matches-git-object', sha256: 'abc', reference: 'git:HEAD:scripts/hooks/guardrail-skip-in-himmel.js', referenceSha256: 'abc' },
      scriptPath: '/fake/script.sh', scriptResolves: true,
      anchorScriptPath: '/fake/repo/scripts/hooks/auto-approve-safe-bash.sh', scriptMatchesAnchor: true,
      auditScriptPath: '/fake/repo/scripts/hooks/auto-approve-safe-bash.sh', scriptMatchesAuditAnchor: true,
      scriptIntegrity: { verdict: 'healthy', reason: 'matches-git-object', sha256: 'def', reference: 'git:HEAD:scripts/hooks/auto-approve-safe-bash.sh', referenceSha256: 'def' },
      duplicates: [], nonCanonicalCount: 0, nonCanonical: [],
    },
  ],
}) + '\n');
JS
outGBtr=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'guardrail-block-global');
const ctx = { repoRoot: '$(winpath "$gb_truncated_dir")', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGBtr" | jq -e '.actual == "present"' >/dev/null \
  || fail "cmd:guardrail_block_status: an internally-consistent TRUNCATED payload (1 of 3 real hooks, that one fully healthy) reads present under the documented floor (got: $outGBtr)"
echo "ok: cmd:guardrail_block_status — an internally-consistent truncated payload (fewer entries than the real contract, all healthy) reads present under the documented accepted floor (codex-1-r7, case 1)"

# Case 2 (the NON-NEGOTIABLE case): complete:true, but the ONE hook entry's
# OWN fields say it is NOT healthy (wrapperResolves:false) — the payload
# contradicts itself. Must read degraded, never present.
gb_contradiction_dir="$work/gb-contradiction"; mkdir -p "$gb_contradiction_dir/scripts/hooks"
cat > "$gb_contradiction_dir/scripts/hooks/guardrail-block.mjs" <<'JS'
process.stdout.write(JSON.stringify({
  mode: 'global',
  complete: true,
  hooks: [
    {
      basename: 'auto-approve-safe-bash.sh', matcher: 'Bash', expectedMatcher: 'Bash', matcherMatches: true,
      present: true, entryCount: 1,
      bashPath: '/fake/bash', bashResolves: true,
      nodePath: '/fake/node', nodeResolves: true,
      wrapperPath: '/fake/wrapper.js', wrapperResolves: false,
      scriptPath: '/fake/script.sh', scriptResolves: true,
      duplicates: [], nonCanonicalCount: 0, nonCanonical: [],
    },
  ],
}) + '\n');
JS
outGBcon=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'guardrail-block-global');
const ctx = { repoRoot: '$(winpath "$gb_contradiction_dir")', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGBcon" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:guardrail_block_status: complete=true with an entry whose OWN fields say it is unhealthy (wrapperResolves:false) is self-contradictory and must read degraded, never present (got: $outGBcon)"
echo "$outGBcon" | jq -e '.detail | contains("self-contradictory")' >/dev/null \
  || fail "cmd:guardrail_block_status self-contradictory-payload detail should name it as such (got: $outGBcon)"
echo "ok: cmd:guardrail_block_status — complete=true contradicted by its own hooks[] entry reads degraded, never present (codex-1-r7, case 2, non-negotiable)"

# ── HIMMEL-1427 (attestation v2 binding, CR round 1; fail-closed in round 2
# — codex-adv finding 1): the probe requires the v2 attestation layer —
# top-level contentIntegrityComplete / auditAnchorComplete /
# attestationComplete plus per-hook wrapperIntegrity / scriptIntegrity and
# wrapperMatchesAuditAnchor / scriptMatchesAuditAnchor — for 'present'. The
# probe spawns the checkout's OWN guardrail-block.mjs, so producer and
# consumer ship in lockstep: a payload with NO v2 fields (stale checkout or
# stripped/tampered output) OR a PARTIAL v2 set reads DEGRADED, never the v1
# 'present' verdict — round 1's fail-OPEN back-compat re-opened the downgrade
# path the attestation exists to close. Five cases, each a STUB
# guardrail-block.mjs emitting a hand-crafted status --json payload (same
# harness as the codex-1-r7 self-consistency fixtures above) so the probe's v2
# binding is exercised directly, isolated from the producer's git-blob
# mechanics. The motivating gap: a content-tampered wrapper or a divergent
# audit anchor yields attestationComplete:false while the legacy v1 `complete`
# flag still reads true — so WITHOUT this binding the attestation exists in
# the payload but never reaches the health surface (doctor still reports the
# guardrails 'present').

# Case 1: a fully healthy v2 payload (complete + content-integrity +
# audit-anchor all green, flags internally consistent) → present.
gb_v2_healthy_dir="$work/gb-v2-healthy"; mkdir -p "$gb_v2_healthy_dir/scripts/hooks"
cat > "$gb_v2_healthy_dir/scripts/hooks/guardrail-block.mjs" <<'JS'
process.stdout.write(JSON.stringify({
  mode: 'global',
  anchor: { repo: '/fake/repo', source: 'HIMMEL_REPO' },
  auditAnchor: { repo: '/fake/repo', source: 'self-checkout' },
  anchorMatchesAudit: true,
  complete: true,
  contentIntegrityComplete: true,
  auditAnchorComplete: true,
  attestationComplete: true,
  hooks: [
    {
      basename: 'auto-approve-safe-bash.sh', matcher: 'Bash', expectedMatcher: 'Bash', matcherMatches: true,
      present: true, entryCount: 1,
      bashPath: '/fake/bash', bashResolves: true,
      nodePath: '/fake/node', nodeResolves: true,
      wrapperPath: '/fake/wrapper.js', wrapperResolves: true,
      anchorWrapperPath: '/fake/repo/scripts/hooks/guardrail-skip-in-himmel.js', wrapperMatchesAnchor: true,
      auditWrapperPath: '/fake/repo/scripts/hooks/guardrail-skip-in-himmel.js', wrapperMatchesAuditAnchor: true,
      wrapperIntegrity: { verdict: 'healthy', reason: 'matches-git-object', sha256: 'abc', reference: 'git:HEAD:scripts/hooks/guardrail-skip-in-himmel.js', referenceSha256: 'abc' },
      scriptPath: '/fake/script.sh', scriptResolves: true,
      anchorScriptPath: '/fake/repo/scripts/hooks/auto-approve-safe-bash.sh', scriptMatchesAnchor: true,
      auditScriptPath: '/fake/repo/scripts/hooks/auto-approve-safe-bash.sh', scriptMatchesAuditAnchor: true,
      scriptIntegrity: { verdict: 'healthy', reason: 'matches-git-object', sha256: 'def', reference: 'git:HEAD:scripts/hooks/auto-approve-safe-bash.sh', referenceSha256: 'def' },
      duplicates: [], nonCanonicalCount: 0, nonCanonical: [],
    },
  ],
}) + '\n');
JS
outGBv2h=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'guardrail-block-global');
const ctx = { repoRoot: '$(winpath "$gb_v2_healthy_dir")', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGBv2h" | jq -e '.actual == "present"' >/dev/null \
  || fail "cmd:guardrail_block_status: a fully healthy v2 payload (complete + content-integrity + audit-anchor all green) must read present (HIMMEL-1427): (got: $outGBv2h)"
echo "$outGBv2h" | jq -e '.detail | contains("attestation v2 complete")' >/dev/null \
  || fail "cmd:guardrail_block_status healthy-v2 detail should name attestation v2 complete (got: $outGBv2h)"
echo "ok: cmd:guardrail_block_status — a fully healthy v2 attestation payload reads present (HIMMEL-1427)"

# Case 2: a content-tampered wrapper — v1 complete stays true, but
# wrapperIntegrity.verdict is 'degraded', so contentIntegrityComplete:false and
# attestationComplete:false. The probe must NOT rubber-stamp 'present' on the v1
# flag alone; it reads degraded and names the content-integrity dimension.
gb_v2_content_dir="$work/gb-v2-content-tampered"; mkdir -p "$gb_v2_content_dir/scripts/hooks"
cat > "$gb_v2_content_dir/scripts/hooks/guardrail-block.mjs" <<'JS'
process.stdout.write(JSON.stringify({
  mode: 'global',
  anchor: { repo: '/fake/repo', source: 'HIMMEL_REPO' },
  auditAnchor: { repo: '/fake/repo', source: 'self-checkout' },
  anchorMatchesAudit: true,
  complete: true,
  contentIntegrityComplete: false,
  auditAnchorComplete: true,
  attestationComplete: false,
  hooks: [
    {
      basename: 'auto-approve-safe-bash.sh', matcher: 'Bash', expectedMatcher: 'Bash', matcherMatches: true,
      present: true, entryCount: 1,
      bashPath: '/fake/bash', bashResolves: true,
      nodePath: '/fake/node', nodeResolves: true,
      wrapperPath: '/fake/wrapper.js', wrapperResolves: true,
      anchorWrapperPath: '/fake/repo/scripts/hooks/guardrail-skip-in-himmel.js', wrapperMatchesAnchor: true,
      auditWrapperPath: '/fake/repo/scripts/hooks/guardrail-skip-in-himmel.js', wrapperMatchesAuditAnchor: true,
      wrapperIntegrity: { verdict: 'degraded', reason: 'content-mismatch', sha256: 'tampered', reference: 'git:HEAD:scripts/hooks/guardrail-skip-in-himmel.js', referenceSha256: 'abc' },
      scriptPath: '/fake/script.sh', scriptResolves: true,
      anchorScriptPath: '/fake/repo/scripts/hooks/auto-approve-safe-bash.sh', scriptMatchesAnchor: true,
      auditScriptPath: '/fake/repo/scripts/hooks/auto-approve-safe-bash.sh', scriptMatchesAuditAnchor: true,
      scriptIntegrity: { verdict: 'healthy', reason: 'matches-git-object', sha256: 'def', reference: 'git:HEAD:scripts/hooks/auto-approve-safe-bash.sh', referenceSha256: 'def' },
      duplicates: [], nonCanonicalCount: 0, nonCanonical: [],
    },
  ],
}) + '\n');
JS
outGBv2c=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'guardrail-block-global');
const ctx = { repoRoot: '$(winpath "$gb_v2_content_dir")', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGBv2c" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:guardrail_block_status: a content-tampered wrapper (wrapperIntegrity degraded, attestationComplete:false) must read degraded, NEVER present, even though v1 complete stays true (HIMMEL-1427): (got: $outGBv2c)"
echo "$outGBv2c" | jq -e '.detail | contains("content integrity")' >/dev/null \
  || fail "cmd:guardrail_block_status content-tampered detail should name the content-integrity dimension (got: $outGBv2c)"
echo "ok: cmd:guardrail_block_status — a content-tampered wrapper reads degraded naming content integrity, never a v1-flag-only present (HIMMEL-1427)"

# Case 3: a divergent audit anchor — content integrity is healthy, but the
# configured wrapper points at a DIFFERENT checkout than the audit anchor
# (wrapperMatchesAuditAnchor:false), so auditAnchorComplete:false and
# attestationComplete:false. Reads degraded, naming the audit-anchor dimension.
gb_v2_anchor_dir="$work/gb-v2-anchor-divergent"; mkdir -p "$gb_v2_anchor_dir/scripts/hooks"
cat > "$gb_v2_anchor_dir/scripts/hooks/guardrail-block.mjs" <<'JS'
process.stdout.write(JSON.stringify({
  mode: 'global',
  anchor: { repo: '/fake/repo', source: 'HIMMEL_REPO' },
  auditAnchor: { repo: '/fake/repo', source: 'self-checkout' },
  anchorMatchesAudit: true,
  complete: true,
  contentIntegrityComplete: true,
  auditAnchorComplete: false,
  attestationComplete: false,
  hooks: [
    {
      basename: 'auto-approve-safe-bash.sh', matcher: 'Bash', expectedMatcher: 'Bash', matcherMatches: true,
      present: true, entryCount: 1,
      bashPath: '/fake/bash', bashResolves: true,
      nodePath: '/fake/node', nodeResolves: true,
      wrapperPath: '/fake/wrapper.js', wrapperResolves: true,
      anchorWrapperPath: '/fake/repo/scripts/hooks/guardrail-skip-in-himmel.js', wrapperMatchesAnchor: true,
      auditWrapperPath: '/different/repo/scripts/hooks/guardrail-skip-in-himmel.js', wrapperMatchesAuditAnchor: false,
      wrapperIntegrity: { verdict: 'healthy', reason: 'matches-git-object', sha256: 'abc', reference: 'git:HEAD:scripts/hooks/guardrail-skip-in-himmel.js', referenceSha256: 'abc' },
      scriptPath: '/fake/script.sh', scriptResolves: true,
      anchorScriptPath: '/fake/repo/scripts/hooks/auto-approve-safe-bash.sh', scriptMatchesAnchor: true,
      auditScriptPath: '/fake/repo/scripts/hooks/auto-approve-safe-bash.sh', scriptMatchesAuditAnchor: true,
      scriptIntegrity: { verdict: 'healthy', reason: 'matches-git-object', sha256: 'def', reference: 'git:HEAD:scripts/hooks/auto-approve-safe-bash.sh', referenceSha256: 'def' },
      duplicates: [], nonCanonicalCount: 0, nonCanonical: [],
    },
  ],
}) + '\n');
JS
outGBv2a=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'guardrail-block-global');
const ctx = { repoRoot: '$(winpath "$gb_v2_anchor_dir")', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGBv2a" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:guardrail_block_status: a divergent audit anchor (wrapperMatchesAuditAnchor:false, attestationComplete:false) must read degraded, NEVER present, even with healthy content integrity (HIMMEL-1427): (got: $outGBv2a)"
echo "$outGBv2a" | jq -e '.detail | contains("audit anchor")' >/dev/null \
  || fail "cmd:guardrail_block_status audit-anchor-divergent detail should name the audit-anchor dimension (got: $outGBv2a)"
echo "ok: cmd:guardrail_block_status — a divergent audit anchor reads degraded naming the audit anchor, never present (HIMMEL-1427)"

# Case 4 (fail-closed on absence — CR round 2, finding 1): a payload that
# emits NO attestation v2 fields at all (a stale checkout aimed at an older
# guardrail-block.mjs, OR deliberately stripped/tampered output) — complete:true,
# internally consistent, but no attestationComplete / contentIntegrityComplete /
# auditAnchorComplete and no per-hook wrapperIntegrity / scriptIntegrity. Round 1
# kept the v1 'present' verdict here (back-compat); round 2 fails CLOSED: this
# re-opens the downgrade path the attestation exists to close, so it reads
# degraded naming the situation, never a silent v1 'present'.
gb_v1_no_v2_dir="$work/gb-v1-no-v2"; mkdir -p "$gb_v1_no_v2_dir/scripts/hooks"
cat > "$gb_v1_no_v2_dir/scripts/hooks/guardrail-block.mjs" <<'JS'
process.stdout.write(JSON.stringify({
  mode: 'global',
  complete: true,
  hooks: [
    {
      basename: 'auto-approve-safe-bash.sh', matcher: 'Bash', expectedMatcher: 'Bash', matcherMatches: true,
      present: true, entryCount: 1,
      bashPath: '/fake/bash', bashResolves: true,
      nodePath: '/fake/node', nodeResolves: true,
      wrapperPath: '/fake/wrapper.js', wrapperResolves: true,
      anchorWrapperPath: '/fake/repo/scripts/hooks/guardrail-skip-in-himmel.js', wrapperMatchesAnchor: true,
      scriptPath: '/fake/script.sh', scriptResolves: true,
      anchorScriptPath: '/fake/repo/scripts/hooks/auto-approve-safe-bash.sh', scriptMatchesAnchor: true,
      duplicates: [], nonCanonicalCount: 0, nonCanonical: [],
    },
  ],
}) + '\n');
JS
outGBv1=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'guardrail-block-global');
const ctx = { repoRoot: '$(winpath "$gb_v1_no_v2_dir")', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGBv1" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:guardrail_block_status: a payload with NO v2 fields must read degraded (fail-closed on absence — stale checkout or stripped output re-opens the downgrade path), NEVER present (HIMMEL-1427 CR round 2): (got: $outGBv1)"
echo "$outGBv1" | jq -e '.detail | contains("producer emitted no attestation-v2 fields")' >/dev/null \
  || fail "cmd:guardrail_block_status v1-no-v2 detail should name the fail-closed situation (got: $outGBv1)"
echo "ok: cmd:guardrail_block_status — a payload without v2 fields reads degraded (fail-closed), never a silent v1 present (HIMMEL-1427 CR round 2)"

# Case 5 (fail-closed on a PARTIAL v2 set — CR round 2, finding 1, panel sug
# codex-1): a payload whose per-hook integrity fields ARE present but whose
# summary booleans (attestationComplete / contentIntegrityComplete /
# auditAnchorComplete) and anchorMatchesAudit are MISSING — some v2 fields
# present, the set not whole. This is self-contradictory/incomplete and must
# NOT silently fall back to a v1 classification: degraded, never 'present'.
gb_v2_partial_dir="$work/gb-v2-partial"; mkdir -p "$gb_v2_partial_dir/scripts/hooks"
cat > "$gb_v2_partial_dir/scripts/hooks/guardrail-block.mjs" <<'JS'
process.stdout.write(JSON.stringify({
  mode: 'global',
  complete: true,
  hooks: [
    {
      basename: 'auto-approve-safe-bash.sh', matcher: 'Bash', expectedMatcher: 'Bash', matcherMatches: true,
      present: true, entryCount: 1,
      bashPath: '/fake/bash', bashResolves: true,
      nodePath: '/fake/node', nodeResolves: true,
      wrapperPath: '/fake/wrapper.js', wrapperResolves: true,
      anchorWrapperPath: '/fake/repo/scripts/hooks/guardrail-skip-in-himmel.js', wrapperMatchesAnchor: true,
      auditWrapperPath: '/fake/repo/scripts/hooks/guardrail-skip-in-himmel.js', wrapperMatchesAuditAnchor: true,
      wrapperIntegrity: { verdict: 'healthy', reason: 'matches-git-object', sha256: 'abc', reference: 'git:HEAD:scripts/hooks/guardrail-skip-in-himmel.js', referenceSha256: 'abc' },
      scriptPath: '/fake/script.sh', scriptResolves: true,
      anchorScriptPath: '/fake/repo/scripts/hooks/auto-approve-safe-bash.sh', scriptMatchesAnchor: true,
      auditScriptPath: '/fake/repo/scripts/hooks/auto-approve-safe-bash.sh', scriptMatchesAuditAnchor: true,
      scriptIntegrity: { verdict: 'healthy', reason: 'matches-git-object', sha256: 'def', reference: 'git:HEAD:scripts/hooks/auto-approve-safe-bash.sh', referenceSha256: 'def' },
      duplicates: [], nonCanonicalCount: 0, nonCanonical: [],
    },
  ],
}) + '\n');
JS
outGBv2p=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'guardrail-block-global');
const ctx = { repoRoot: '$(winpath "$gb_v2_partial_dir")', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGBv2p" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:guardrail_block_status: a PARTIAL v2 payload (per-hook integrity present, summary booleans missing) must read degraded, NEVER silently v1-classified as present (HIMMEL-1427 CR round 2): (got: $outGBv2p)"
echo "$outGBv2p" | jq -e '.detail | contains("incomplete")' >/dev/null \
  || fail "cmd:guardrail_block_status partial-v2 detail should name the payload as incomplete (got: $outGBv2p)"
echo "ok: cmd:guardrail_block_status — a partial v2 payload (some fields present, set not whole) reads degraded, never a silent v1 present (HIMMEL-1427 CR round 2)"

gb_bad_exit_dir="$work/gb-bad-exit"; mkdir -p "$gb_bad_exit_dir/scripts/hooks"
cat > "$gb_bad_exit_dir/scripts/hooks/guardrail-block.mjs" <<'JS'
process.stderr.write('boom\n');
process.exit(2);
JS
outGBe=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'guardrail-block-global');
const ctx = { repoRoot: '$(winpath "$gb_bad_exit_dir")', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGBe" | jq -e '.actual == "degraded"' >/dev/null || fail "cmd:guardrail_block_status degraded (script exits nonzero): (got: $outGBe)"
echo "$outGBe" | jq -e '.detail | contains("rc=2")' >/dev/null || fail "cmd:guardrail_block_status nonzero-exit detail should name the rc (got: $outGBe)"
echo "ok: cmd:guardrail_block_status (guardrail-block-global) absent/degraded (rotted node path / unparseable output / missing hooks field / nonzero exit) — 'present' is reserved for the genuine full-install case proven above"
# SKIP NOTE: a spawn-error path (process.execPath itself unresolvable) is not
# exercised — this probe spawns by ABSOLUTE execPath, never a bash/PATH
# lookup for node, so the r.error branch has no realistic trigger here (unlike
# the bash-spawned probes above, where 'bash' itself can go missing from
# PATH). The branch stays defensive (matches every other probe's shape) but
# is not artificially forced — per the CR-established "comment + skip note,
# not a fake test" standard (HIMMEL-1093 round 5, codex-2).

# ── dep (gemini-cli) — HIMMEL-1100 ──────────────────────────────────────────
gem_present_stub="$work/gem-present-bin"; mkdir -p "$gem_present_stub"
pathGemPresent=$(build_path "$gem_present_stub" bash git jq -- gemini)
cat > "$gem_present_stub/gemini" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$gem_present_stub/gemini"
outGemP=$(PATH="$pathGemPresent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'gemini-cli');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGemP" | jq -e '.actual == "present"' >/dev/null || fail "dep (gemini-cli) present: (got: $outGemP)"

gem_absent_stub="$work/gem-absent-bin"; mkdir -p "$gem_absent_stub"
pathGemAbsent=$(build_path "$gem_absent_stub" bash git jq -- gemini)
outGemA=$(PATH="$pathGemAbsent" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'gemini-cli');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outGemA" | jq -e '.actual == "absent"' >/dev/null || fail "dep (gemini-cli) absent: (got: $outGemA)"
echo "ok: dep (gemini-cli) present/absent"

# ── cmd:hermes_checkout (hermes-checkout) — HIMMEL-1100 round 3, codex-adv-3
# hermes-checkout no longer reuses cmd:has_hermes (that proves a usable venv
# python, kept unchanged on hermes-lanes for runtime health) — it now checks
# the CHECKOUT itself: pure fs, no git spawn, resolving update_hermes()'s
# OWN root/src and reading .git/config directly for the origin remote.
hc_home_present="$work/hc-home-present"; mkdir -p "$hc_home_present/hermes-agent/.git"
cat > "$hc_home_present/hermes-agent/.git/config" <<'CFG'
[core]
	repositoryformatversion = 0
[remote "origin"]
	url = https://github.com/NousResearch/hermes-agent.git
	fetch = +refs/heads/*:refs/remotes/origin/*
[branch "main"]
	remote = origin
	merge = refs/heads/main
CFG
outHCp=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'hermes-checkout');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HERMES_HOME: '$(winpath "$hc_home_present")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHCp" | jq -e '.actual == "present"' >/dev/null \
  || fail "cmd:hermes_checkout present (genuine NousResearch/hermes-agent checkout): (got: $outHCp)"
echo "$outHCp" | jq -e '.detail | contains("NousResearch/hermes-agent")' >/dev/null \
  || fail "cmd:hermes_checkout present detail should name the verified origin (got: $outHCp)"

# absent: no .git at all under either root/hermes-agent or root — never
# installed as a checkout, the ordinary case for most operators.
hc_home_absent="$work/hc-home-absent"; mkdir -p "$hc_home_absent"
outHCa=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'hermes-checkout');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HERMES_HOME: '$(winpath "$hc_home_absent")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHCa" | jq -e '.actual == "absent"' >/dev/null \
  || fail "cmd:hermes_checkout absent (no .git checkout at all): (got: $outHCa)"
echo "$outHCa" | jq -e '.detail | contains("not installed as a git checkout")' >/dev/null \
  || fail "cmd:hermes_checkout absent detail should say not installed as a git checkout (got: $outHCa)"

# degraded: .git present but the origin points at a DIFFERENT repo entirely
# — update_hermes() would silently skip this checkout too (its own remote
# grep), so this is genuinely NOT a working hermes install.
hc_home_wrong_origin="$work/hc-home-wrong-origin"; mkdir -p "$hc_home_wrong_origin/hermes-agent/.git"
cat > "$hc_home_wrong_origin/hermes-agent/.git/config" <<'CFG'
[remote "origin"]
	url = https://github.com/someone-else/not-hermes.git
CFG
outHCw=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'hermes-checkout');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HERMES_HOME: '$(winpath "$hc_home_wrong_origin")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHCw" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:hermes_checkout degraded (checkout present but wrong origin): (got: $outHCw)"
echo "$outHCw" | jq -e '.detail | contains("not a NousResearch/hermes-agent checkout")' >/dev/null \
  || fail "cmd:hermes_checkout wrong-origin detail should name it (got: $outHCw)"

# degraded: a SPOOFED origin whose owner/repo merely CONTAINS
# "NousResearch/hermes-agent" as a substring — CR fix (HIMMEL-1100 round 4,
# codex-1): the previous bare substring match would have false-greened this.
hc_home_spoof="$work/hc-home-spoof"; mkdir -p "$hc_home_spoof/hermes-agent/.git"
cat > "$hc_home_spoof/hermes-agent/.git/config" <<'CFG'
[remote "origin"]
	url = git@github.com:evil/NousResearch-hermes-agent-mirror.git
CFG
outHCs=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'hermes-checkout');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HERMES_HOME: '$(winpath "$hc_home_spoof")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHCs" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:hermes_checkout degraded (spoofed origin owner/repo CONTAINS the real name as a substring but is not an exact match): (got: $outHCs)"
echo "$outHCs" | jq -e '.detail | contains("not a NousResearch/hermes-agent checkout")' >/dev/null \
  || fail "cmd:hermes_checkout spoof detail should name it (got: $outHCs)"
echo "ok: cmd:hermes_checkout — a substring-spoofed origin (evil/NousResearch-hermes-agent-mirror) reads degraded, never a false present"

# degraded: .git present but NO [remote "origin"] section at all.
hc_home_no_origin="$work/hc-home-no-origin"; mkdir -p "$hc_home_no_origin/hermes-agent/.git"
cat > "$hc_home_no_origin/hermes-agent/.git/config" <<'CFG'
[core]
	repositoryformatversion = 0
CFG
outHCn=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'hermes-checkout');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HERMES_HOME: '$(winpath "$hc_home_no_origin")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHCn" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:hermes_checkout degraded (checkout present but no origin remote configured): (got: $outHCn)"

# HERMES_HOME pointing straight AT the checkout (venv + .git at root, no
# hermes-agent/ subdir) — the tolerance fallback update_hermes() itself has.
hc_home_at_root="$work/hc-home-at-root"; mkdir -p "$hc_home_at_root/.git"
cat > "$hc_home_at_root/.git/config" <<'CFG'
[remote "origin"]
	url = git@github.com:NousResearch/hermes-agent.git
CFG
outHCr=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'hermes-checkout');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HERMES_HOME: '$(winpath "$hc_home_at_root")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHCr" | jq -e '.actual == "present"' >/dev/null \
  || fail "cmd:hermes_checkout present (HERMES_HOME pointing straight at the checkout, root/.git tolerance, SSH-form origin url): (got: $outHCr)"

# CodeRabbit fix (HIMMEL-1100 round 6, coderabbit-2): an ssh:// origin with
# an EXPLICIT PORT (a normal, real-world form) used to false-degrade — the
# combined regex couldn't parse past the port segment.
hc_home_ssh_port="$work/hc-home-ssh-port"; mkdir -p "$hc_home_ssh_port/hermes-agent/.git"
cat > "$hc_home_ssh_port/hermes-agent/.git/config" <<'CFG'
[remote "origin"]
	url = ssh://git@github.com:22/NousResearch/hermes-agent.git
CFG
outHCp2=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'hermes-checkout');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HERMES_HOME: '$(winpath "$hc_home_ssh_port")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHCp2" | jq -e '.actual == "present"' >/dev/null \
  || fail "cmd:hermes_checkout present (ssh:// origin with an explicit port — ssh://git@github.com:22/NousResearch/hermes-agent.git): (got: $outHCp2)"
echo "ok: cmd:hermes_checkout — an ssh:// origin with an explicit port resolves present, not falsely degraded"

# .git as a gitlink FILE (worktree/submodule shape: "gitdir: <path>") must
# still count as a valid checkout indicator — CR fix (HIMMEL-1100 round 4,
# codex-2). Follows the pointer ONE level to find the real config.
hc_home_gitdir_file="$work/hc-home-gitdir-file"; mkdir -p "$hc_home_gitdir_file/hermes-agent"
hc_real_gitdir="$work/hc-real-gitdir"; mkdir -p "$hc_real_gitdir"
cat > "$hc_real_gitdir/config" <<'CFG'
[remote "origin"]
	url = https://github.com/NousResearch/hermes-agent.git
CFG
printf 'gitdir: %s\n' "$(winpath "$hc_real_gitdir")" > "$hc_home_gitdir_file/hermes-agent/.git"
outHCg=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'hermes-checkout');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HERMES_HOME: '$(winpath "$hc_home_gitdir_file")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHCg" | jq -e '.actual == "present"' >/dev/null \
  || fail "cmd:hermes_checkout present (.git is a gitlink FILE — worktree/submodule shape — following the gitdir: pointer): (got: $outHCg)"

# gitdir: pointer target missing -> degraded (a .git entry genuinely exists,
# just unverifiable) — never absent, never a crash.
hc_home_gitdir_broken="$work/hc-home-gitdir-broken"; mkdir -p "$hc_home_gitdir_broken/hermes-agent"
printf 'gitdir: %s\n' "$(winpath "$work")/does-not-exist" > "$hc_home_gitdir_broken/hermes-agent/.git"
outHCgb=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'hermes-checkout');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HERMES_HOME: '$(winpath "$hc_home_gitdir_broken")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHCgb" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cmd:hermes_checkout degraded (gitdir: pointer target missing — genuinely a checkout, just unverifiable, not a crash): (got: $outHCgb)"
echo "$outHCgb" | jq -e '.detail | contains("gitdir:")' >/dev/null \
  || fail "cmd:hermes_checkout broken-gitdir detail should mention the gitdir pointer (got: $outHCgb)"
echo "ok: cmd:hermes_checkout — a .git gitlink FILE (worktree/submodule) is honored, following the pointer one level; a broken pointer reads degraded, never absent or a crash"

# Worktree-shaped fixture — CR fix (HIMMEL-1100 round 5, codex-1): a NORMAL
# linked worktree's gitdir (.git/worktrees/<name>/) carries no remotes of
# its own — they live in the COMMON dir, reached via that dir's own
# `commondir` file (relative paths resolve against the gitdir, per git's own
# contract). Without the fallback, this legitimate install shape read
# falsely degraded.
hc_home_worktree="$work/hc-home-worktree"
hc_wt_main_git="$hc_home_worktree/hermes-agent-main/.git"
mkdir -p "$hc_wt_main_git/worktrees/hermes-agent"
cat > "$hc_wt_main_git/config" <<'CFG'
[remote "origin"]
	url = https://github.com/NousResearch/hermes-agent.git
CFG
printf '../..\n' > "$hc_wt_main_git/worktrees/hermes-agent/commondir"
mkdir -p "$hc_home_worktree/hermes-agent"
printf 'gitdir: %s\n' "$(winpath "$hc_wt_main_git/worktrees/hermes-agent")" > "$hc_home_worktree/hermes-agent/.git"
outHCwt=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'hermes-checkout');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HERMES_HOME: '$(winpath "$hc_home_worktree")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHCwt" | jq -e '.actual == "present"' >/dev/null \
  || fail "cmd:hermes_checkout present (NORMAL worktree shape: gitdir -> worktrees/<name> -> commondir -> common config with the origin): (got: $outHCwt)"
echo "$outHCwt" | jq -e '.detail | contains("NousResearch/hermes-agent")' >/dev/null \
  || fail "cmd:hermes_checkout worktree-shape detail should name the verified origin (got: $outHCwt)"
echo "ok: cmd:hermes_checkout — a NORMAL linked-worktree checkout (gitdir -> worktrees/<name>, no local remotes) resolves via the commondir fallback, reads present"

echo "ok: cmd:hermes_checkout (hermes-checkout) present/absent/degraded (wrong origin / no origin / spoofed origin), including the root/.git tolerance fallback and SSH-form origin urls"

# HIMMEL-2437: no HERMES_HOME override and no LOCALAPPDATA (the Linux/macOS
# station shape) must resolve the default root to $HOME/.hermes — NOT
# $HOME/AppData/Local/hermes (a Windows %LOCALAPPDATA% layout rendered under a
# POSIX $HOME, the ticket's own repro). HOME is faked ONLY inside ctx.env
# passed to runProbe (never at the bash level), matching the mcp-registered
# cases above.
hc_home_linux_default="$work/hc-home-linux-default"; mkdir -p "$hc_home_linux_default/.hermes/hermes-agent/.git"
cat > "$hc_home_linux_default/.hermes/hermes-agent/.git/config" <<'CFG'
[remote "origin"]
	url = https://github.com/NousResearch/hermes-agent.git
CFG
outHClx=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'hermes-checkout');
const env = Object.assign({}, process.env, { HOME: '$(winpath "$hc_home_linux_default")' });
delete env.HERMES_HOME;
delete env.LOCALAPPDATA;
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHClx" | jq -e '.actual == "present"' >/dev/null \
  || fail "cmd:hermes_checkout present (Linux/macOS default root \$HOME/.hermes, no HERMES_HOME/LOCALAPPDATA): (got: $outHClx)"
echo "$outHClx" | jq -e '.detail | contains("NousResearch/hermes-agent")' >/dev/null \
  || fail "cmd:hermes_checkout Linux-default detail should name the verified origin (got: $outHClx)"

# Windows shape must stay unchanged: LOCALAPPDATA set (no HERMES_HOME) still
# resolves to $LOCALAPPDATA/hermes/hermes-agent.
hc_home_winpath_lad="$work/hc-home-winpath-lad"; mkdir -p "$hc_home_winpath_lad/hermes/hermes-agent/.git"
cat > "$hc_home_winpath_lad/hermes/hermes-agent/.git/config" <<'CFG'
[remote "origin"]
	url = https://github.com/NousResearch/hermes-agent.git
CFG
outHCwlad=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'hermes-checkout');
const env = Object.assign({}, process.env, { LOCALAPPDATA: '$(winpath "$hc_home_winpath_lad")' });
delete env.HERMES_HOME;
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHCwlad" | jq -e '.actual == "present"' >/dev/null \
  || fail "cmd:hermes_checkout present (Windows LOCALAPPDATA/hermes/hermes-agent, no HERMES_HOME): (got: $outHCwlad)"
echo "$outHCwlad" | jq -e '.detail | contains("NousResearch/hermes-agent")' >/dev/null \
  || fail "cmd:hermes_checkout LOCALAPPDATA-default detail should name the verified origin (got: $outHCwlad)"
echo "ok: cmd:hermes_checkout — default root resolution: no HERMES_HOME/LOCALAPPDATA reads \$HOME/.hermes (Linux/macOS), LOCALAPPDATA set still reads \$LOCALAPPDATA/hermes (Windows unchanged) (HIMMEL-2437)"

depsCheck=$(jq -r '.items[] | select(.id=="hermes-lanes") | .deps | join(",")' "$manifest_path")
[ "$depsCheck" = "hermes-checkout" ] || fail "manifest: hermes-lanes.deps should be exactly [\"hermes-checkout\"] (got: $depsCheck)"
echo "ok: hermes-lanes correctly deps on hermes-checkout (distinct probes: checkout provenance vs runtime venv health)"

# ── cadence-coherence (cadence-armed) — HIMMEL-2176 Task 7, status item S1 ──
# CR fix (HIMMEL-2176 CR round 10, retask stage1-build-6d2e): this probe used
# to trust a generated RUNNER FILE's mere existence as proof a scheduler task
# is registered — but a runner file survives after its Task Scheduler entry
# is deleted, or after an `arm` that failed partway, so S1 (the ONE status
# item whose whole job is catching "not actually armed") could itself read a
# false green. It now shells out to pipeline-cadence.sh's own `status` (the
# single source of truth for scheduler state — the same posture
# engine-allowlist already applies to cadence-approve-engines.sh below) and
# parses ITS answer, rather than re-deriving a schtasks/cron query here.
#
# Scheduler responses are faked via a stub `schtasks` executable wired
# through pipeline-cadence.sh's own PIPELINE_SCHTASKS test seam (the same
# seam scripts/luna/test-pipeline-cadence.sh's own suite uses) — a real stub
# process on this suite's own hermetic-executable convention, never a JS
# mock. The Windows wscript smoke-probe cadence_registered_status runs
# underneath is neutralized the same way that suite does it
# (CADENCE_WSCRIPT_BIN / CADENCE_WSH_POWERSHELL fakes), so an ARMED read is
# deterministic instead of depending on this machine's real WSH policy.
# HIMMEL_LUNA_CONFIG_PATH points each case at its OWN fixture config.json (or
# a deliberately nonexistent path, exercising luna-config.js's defaultConfig()
# fallback) — never the real ~/.himmel/config.json.
cc_bat="$work/cc-batdir"; mkdir -p "$cc_bat"
cc_cfg_missing="$work/cc-config-missing.json"   # deliberately never created

cc_wscript="$work/cc-wscript-fake.sh"
printf '#!/bin/sh\nexit 0\n' > "$cc_wscript"
chmod +x "$cc_wscript"
cc_wsh_powershell="$work/cc-wsh-powershell-fake.sh"
printf '#!/bin/sh\necho ABSENT\n' > "$cc_wsh_powershell"
chmod +x "$cc_wsh_powershell"

# `touch $cc_sched_state/tasks/<name>` marks <name> registered — /query /tn
# answers TaskName/Next-Run-Time (rc 0) when the marker exists, the real
# schtasks NOT_FOUND stderr signature (rc 1) otherwise, matching query_one's
# own NOT_FOUND_RE. `touch $cc_sched_state/fail-query` makes every /query an
# untrusted access-denied, exercising the "scheduler unqueryable" path.
cc_sched_state="$work/cc-schtasks-state"; mkdir -p "$cc_sched_state/tasks"
cc_schtasks="$work/cc-schtasks-fake.sh"
cat > "$cc_schtasks" <<FAKE
#!/usr/bin/env bash
STATE="$cc_sched_state"
FAKE
cat >> "$cc_schtasks" <<'FAKE'
tn=""; mode=""
args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
    case "${args[$i]}" in
        /query) mode="/query" ;;
        /tn) i=$((i+1)); tn="${args[$i]}" ;;
    esac
    i=$((i+1))
done
if [ -e "$STATE/fail-query" ]; then
    echo "ERROR: Access is denied." >&2
    exit 1
fi
if [ "$mode" = "/query" ] && [ -n "$tn" ]; then
    if [ -f "$STATE/tasks/$tn" ]; then
        printf 'TaskName:      \\%s\nNext Run Time: 6/15/2026 3:00:00 AM\n' "$tn"
        exit 0
    fi
    echo "ERROR: The system cannot find the file specified." >&2
    exit 1
fi
exit 1
FAKE
chmod +x "$cc_schtasks"

run_cc() {
  local cfgPath="$1"
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cfgPath")" \
  PIPELINE_BAT_DIR="$(winpath "$cc_bat")" \
  PIPELINE_SCHTASKS="$cc_schtasks" \
  CADENCE_WSCRIPT_BIN="$cc_wscript" \
  CADENCE_WSH_POWERSHELL="$cc_wsh_powershell" \
  "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'cadence-armed');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
"
}

cat > "$work/cc-enabled.json" <<'JSON'
{"version":1,"luna":{"vaultPath":"/x","cadence":{"enabled":true,"schedules":{"fetchHealth":{"time":"01:30"},"harvest":{"time":"02:00"},"synthesize":{"time":"03:00"},"health":{"time":"04:00","day":"SUN"}},"models":{"harvest":"sonnet","synthesize":"sonnet","health":"haiku"}},"phi":{"declared":false}},"bridge":{"enabled":false,"envPath":"~/x/.env","whisper":{"cli":null,"model":"ggml-small.bin"}}}
JSON

# no config at all -> defaultConfig() (enabled:false), nothing registered -> absent, cleanAbsence:true.
outCCabs=$(run_cc "$cc_cfg_missing")
echo "$outCCabs" | jq -e '.actual == "absent" and .cleanAbsence == true' >/dev/null \
  || fail "cadence-coherence: no config + nothing registered should read absent with cleanAbsence:true (got: $outCCabs)"
echo "ok: cadence-coherence — no config document (defaults: disabled) + nothing registered reads absent, cleanAbsence:true"

# enabled:false but the scheduler still has a task registered -> degraded (unmanaged leftover), NOT cleanAbsence.
touch "$cc_sched_state/tasks/HIMMEL-Pipeline-Harvest"
outCCleft=$(run_cc "$cc_cfg_missing")
echo "$outCCleft" | jq -e '.actual == "degraded" and (.cleanAbsence // false) == false' >/dev/null \
  || fail "cadence-coherence: enabled:false + a leftover registered schedule should read degraded, no cleanAbsence (got: $outCCleft)"
echo "$outCCleft" | jq -e '.detail | contains("unmanaged leftovers")' >/dev/null \
  || fail "cadence-coherence: leftover detail should say unmanaged leftovers (got: $outCCleft)"
echo "ok: cadence-coherence — enabled:false with a scheduler task surviving reads degraded (unmanaged leftover), never cleanAbsence"
rm -f "$cc_sched_state/tasks/HIMMEL-Pipeline-Harvest"

# ── the CR round-10 finding itself: RED then GREEN ──────────────────────────
# A generated runner file for the harvest leg exists on disk, but the (fake)
# scheduler has NOTHING registered for it. Before this fix, this exact shape
# read present (the false green); it must now read a genuine fail.
: > "$cc_bat/pipeline-harvest.bat"
outCCbug=$(run_cc "$work/cc-enabled.json")
echo "$outCCbug" | jq -e '.actual == "absent" and (.cleanAbsence // false) == false' >/dev/null \
  || fail "cadence-coherence: enabled:true + a runner file present but NO scheduler task registered must read absent, never present (got: $outCCbug)"
echo "ok: cadence-coherence — RED: a runner file's mere presence, with nothing actually registered in the scheduler, does not read green (the CR round-10 finding)"

# Same runner file, unchanged — only the scheduler now genuinely has all 4
# tasks registered. That, and only that, is what flips this to present.
: > "$cc_bat/pipeline-fetch-health.bat"
: > "$cc_bat/pipeline-synthesize.bat"
: > "$cc_bat/pipeline-health.bat"
touch "$cc_sched_state/tasks/HIMMEL-Pipeline-FetchHealth" "$cc_sched_state/tasks/HIMMEL-Pipeline-Harvest" \
  "$cc_sched_state/tasks/HIMMEL-Pipeline-Synthesize" "$cc_sched_state/tasks/HIMMEL-Pipeline-Health"
outCCok=$(run_cc "$work/cc-enabled.json")
echo "$outCCok" | jq -e '.actual == "present"' >/dev/null \
  || fail "cadence-coherence: enabled:true + all 4 schedules actually registered in the scheduler should read present (got: $outCCok)"
echo "ok: cadence-coherence — GREEN: once the scheduler genuinely has all 4 tasks registered, the same runner files now read present"

# partial drift: only 1/4 actually registered -> degraded, naming the fraction.
rm -f "$cc_sched_state/tasks/HIMMEL-Pipeline-FetchHealth" "$cc_sched_state/tasks/HIMMEL-Pipeline-Synthesize" "$cc_sched_state/tasks/HIMMEL-Pipeline-Health"
outCCpartial=$(run_cc "$work/cc-enabled.json")
echo "$outCCpartial" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cadence-coherence: enabled:true + 1/4 registered should read degraded (got: $outCCpartial)"
echo "$outCCpartial" | jq -e '.detail | contains("3/4")' >/dev/null \
  || fail "cadence-coherence: partial-drift detail should name the fraction (got: $outCCpartial)"
echo "ok: cadence-coherence — enabled:true with a partial schedule/task match reads degraded, naming the drift"
rm -f "$cc_sched_state/tasks/HIMMEL-Pipeline-Harvest"
rm -f "$cc_bat"/*.bat

# enabled:true, nothing registered at all (and no decoy runner files) -> absent, genuine fail (no cleanAbsence).
outCCfail=$(run_cc "$work/cc-enabled.json")
echo "$outCCfail" | jq -e '.actual == "absent" and (.cleanAbsence // false) == false' >/dev/null \
  || fail "cadence-coherence: enabled:true + nothing registered should read absent, no cleanAbsence (got: $outCCfail)"
echo "ok: cadence-coherence — enabled:true with nothing registered reads absent, a genuine fail (never cleanAbsence)"

# scheduler unqueryable (every /query answers an untrusted access-denied) ->
# loud degraded naming the limitation, never a silent pass or an
# assumed-healthy default (HIMMEL-1128).
touch "$cc_sched_state/fail-query"
outCCunq=$(run_cc "$work/cc-enabled.json")
echo "$outCCunq" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "cadence-coherence: an unqueryable scheduler should read degraded, never present/absent (got: $outCCunq)"
echo "$outCCunq" | jq -e '.detail | contains("scheduler")' >/dev/null \
  || fail "cadence-coherence: unqueryable-scheduler detail should name the limitation (got: $outCCunq)"
echo "ok: cadence-coherence — a scheduler that refuses every query reads a loud degraded naming the limitation, never assumed-healthy"
rm -f "$cc_sched_state/fail-query"

# ── phi-coherence — HIMMEL-2176 Task 7, status item S3 ──────────────────────
phi_vault="$work/phi-vault"; mkdir -p "$phi_vault"
phi_home="$work/phi-home"; mkdir -p "$phi_home/.config/claude-glm"
phi_cfg="$work/phi-config.json"
cat > "$phi_cfg" <<JSON
{"version":1,"luna":{"vaultPath":"$(winpath "$phi_vault")","cadence":{"enabled":false,"schedules":{"fetchHealth":{"time":"01:30"},"harvest":{"time":"02:00"},"synthesize":{"time":"03:00"},"health":{"time":"04:00","day":"SUN"}},"models":{"harvest":"sonnet","synthesize":"sonnet","health":"haiku"}},"phi":{"declared":false}},"bridge":{"enabled":false,"envPath":"~/x/.env","whisper":{"cli":null,"model":"ggml-small.bin"}}}
JSON

run_phi() {
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$phi_cfg")" HOME="$(winpath "$phi_home")" USERPROFILE="$(winpath "$phi_home")" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'phi-coherence');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
"
}

outPHIneither=$(run_phi)
echo "$outPHIneither" | jq -e '.actual == "present"' >/dev/null \
  || fail "phi-coherence: neither a .salus marker nor a phi-roots entry should read present (pass when both absent): (got: $outPHIneither)"
echo "ok: phi-coherence — neither marker nor phi-roots entry reads present (coherent: neither claims PHI)"

: > "$phi_vault/.salus"
outPHImarkerOnly=$(run_phi)
echo "$outPHImarkerOnly" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "phi-coherence: a .salus marker with no phi-roots entry should read degraded (partial): (got: $outPHImarkerOnly)"
echo "ok: phi-coherence — a .salus marker with no phi-roots entry reads degraded (egress enforcement may not see it)"

printf '%s\n' "$(winpath "$phi_vault")" > "$phi_home/.config/claude-glm/phi-roots"
outPHIboth=$(run_phi)
echo "$outPHIboth" | jq -e '.actual == "present"' >/dev/null \
  || fail "phi-coherence: a .salus marker AND a matching phi-roots entry should read present (coherent): (got: $outPHIboth)"
echo "ok: phi-coherence — a .salus marker AND a matching phi-roots entry reads present (coherent)"

rm -f "$phi_vault/.salus"
outPHIrootsOnly=$(run_phi)
echo "$outPHIrootsOnly" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "phi-coherence: a phi-roots entry with no .salus marker should read degraded (stale entry?): (got: $outPHIrootsOnly)"
echo "ok: phi-coherence — a phi-roots entry with no local .salus marker reads degraded (stale entry?)"
rm -f "$phi_home/.config/claude-glm/phi-roots"

# ── phi-coherence: platform-driven case-folding (HIMMEL-2176 CR round 5,
# retask stage1-build-6d2e) — POSIX filesystems are case-sensitive, so two
# paths differing only in case must NOT compare equal there; win32
# filesystems default to case-insensitive, so they MUST compare equal there.
# Driven through ctx.platform (not the real host process.platform) so this
# is meaningful on any host — a previous fix in this file was passing only
# because the dev box happens to be Windows, and that trap is worth not
# repeating here.
phi_case_vault="$work/PHI-Case-Vault"; mkdir -p "$phi_case_vault"
: > "$phi_case_vault/.salus"
phi_case_cfg="$work/phi-case-config.json"
cat > "$phi_case_cfg" <<JSON
{"version":1,"luna":{"vaultPath":"$(winpath "$phi_case_vault")","cadence":{"enabled":false,"schedules":{"fetchHealth":{"time":"01:30"},"harvest":{"time":"02:00"},"synthesize":{"time":"03:00"},"health":{"time":"04:00","day":"SUN"}},"models":{"harvest":"sonnet","synthesize":"sonnet","health":"haiku"}},"phi":{"declared":false}},"bridge":{"enabled":false,"envPath":"~/x/.env","whisper":{"cli":null,"model":"ggml-small.bin"}}}
JSON
# phi-roots lists the SAME path with different case in its last segment
# (phi-vault -> PHI-VAULT-style casing) — a case-sensitive (POSIX) compare
# must treat this as a DIFFERENT path (no listing, degraded); a
# case-insensitive (win32) compare must treat it as the SAME path (listed,
# present).
printf '%s\n' "$(winpath "$phi_case_vault" | tr '[:lower:]' '[:upper:]')" > "$phi_home/.config/claude-glm/phi-roots"

run_phi_platform() {
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$phi_case_cfg")" HOME="$(winpath "$phi_home")" USERPROFILE="$(winpath "$phi_home")" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'phi-coherence');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env, platform: '$1' };
console.log(JSON.stringify(runProbe(item, ctx)));
"
}

outPHIposix=$(run_phi_platform linux)
echo "$outPHIposix" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "phi-coherence: ctx.platform=linux (POSIX) must treat differently-cased paths as DIFFERENT — expected degraded (got: $outPHIposix)"
echo "ok: phi-coherence — ctx.platform=linux (POSIX) treats case-differing paths as DIFFERENT (degraded, no false coherence)"

outPHIwin32=$(run_phi_platform win32)
echo "$outPHIwin32" | jq -e '.actual == "present"' >/dev/null \
  || fail "phi-coherence: ctx.platform=win32 must treat differently-cased paths as the SAME — expected present (got: $outPHIwin32)"
echo "ok: phi-coherence — ctx.platform=win32 treats case-differing paths as the SAME (present)"
rm -f "$phi_home/.config/claude-glm/phi-roots"

# ── phi-coherence: ~-prefixed vaultPath (CodeRabbit App finding, HIMMEL-2176
# retask stage1-build-6d2e) — luna-config.js's schema accepts any string for
# vaultPath, and bridge.envPath's own default is itself `~`-prefixed, so this
# is a realistic document shape. path.resolve('~/...') resolves against CWD,
# not $HOME, so an unexpanded vaultPath used to misread fs.existsSync's
# marker check as false AND normalizeForPhiMatch's comparison as a
# CWD-relative path — both landing on false coincided with an empty
# phi-roots file also reading false, so the probe read a WRONG 'present'
# instead of the correct 'degraded' (marker present, not listed). $HOME is
# driven through this fixture's own temp dir — never the real home.
phi_tilde_home="$work/phi-tilde-home"; mkdir -p "$phi_tilde_home/Documents/luna" "$phi_tilde_home/.config/claude-glm"
: > "$phi_tilde_home/Documents/luna/.salus"
phi_tilde_cfg="$work/phi-tilde-config.json"
cat > "$phi_tilde_cfg" <<JSON
{"version":1,"luna":{"vaultPath":"~/Documents/luna","cadence":{"enabled":false,"schedules":{"fetchHealth":{"time":"01:30"},"harvest":{"time":"02:00"},"synthesize":{"time":"03:00"},"health":{"time":"04:00","day":"SUN"}},"models":{"harvest":"sonnet","synthesize":"sonnet","health":"haiku"}},"phi":{"declared":false}},"bridge":{"enabled":false,"envPath":"~/x/.env","whisper":{"cli":null,"model":"ggml-small.bin"}}}
JSON

run_phi_tilde() {
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$phi_tilde_cfg")" HOME="$(winpath "$phi_tilde_home")" USERPROFILE="$(winpath "$phi_tilde_home")" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'phi-coherence');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
"
}

outPHItildeVault=$(run_phi_tilde)
echo "$outPHItildeVault" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "phi-coherence: a ~-prefixed vaultPath must expand against \$HOME before the marker check — expected degraded (marker present via the real path, not listed) (got: $outPHItildeVault)"
echo "$outPHItildeVault" | jq -e '.detail | contains("~") | not' >/dev/null \
  || fail "phi-coherence: ~-prefixed vaultPath detail still carries a literal '~' — expansion did not happen (got: $outPHItildeVault)"
echo "ok: phi-coherence — a ~-prefixed vaultPath expands against \$HOME and reads the correct (degraded) verdict, not a false 'present'"

# ── phi-coherence: ~-prefixed phi-roots entry (same finding — either side of
# the coherence check can carry a `~`) — vaultPath here is already a fully-
# expanded absolute path; the phi-roots entry is the one that's `~`-prefixed,
# and it must resolve to the SAME home-relative path as the vault for the
# probe to see them as coherent.
phi_tilde2_vault="$phi_tilde_home/Documents/luna2"; mkdir -p "$phi_tilde2_vault"
: > "$phi_tilde2_vault/.salus"
phi_tilde2_cfg="$work/phi-tilde2-config.json"
cat > "$phi_tilde2_cfg" <<JSON
{"version":1,"luna":{"vaultPath":"$(winpath "$phi_tilde2_vault")","cadence":{"enabled":false,"schedules":{"fetchHealth":{"time":"01:30"},"harvest":{"time":"02:00"},"synthesize":{"time":"03:00"},"health":{"time":"04:00","day":"SUN"}},"models":{"harvest":"sonnet","synthesize":"sonnet","health":"haiku"}},"phi":{"declared":false}},"bridge":{"enabled":false,"envPath":"~/x/.env","whisper":{"cli":null,"model":"ggml-small.bin"}}}
JSON
# shellcheck disable=SC2088  # deliberate literal '~' — the fixture proves the
# probe's OWN expandHome() call expands it, not the shell
printf '%s\n' '~/Documents/luna2' > "$phi_tilde_home/.config/claude-glm/phi-roots"

run_phi_tilde2() {
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$phi_tilde2_cfg")" HOME="$(winpath "$phi_tilde_home")" USERPROFILE="$(winpath "$phi_tilde_home")" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'phi-coherence');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
"
}

outPHItildeRoots=$(run_phi_tilde2)
echo "$outPHItildeRoots" | jq -e '.actual == "present"' >/dev/null \
  || fail "phi-coherence: a ~-prefixed phi-roots entry must expand against \$HOME to match a fully-expanded vaultPath — expected present (coherent) (got: $outPHItildeRoots)"
echo "ok: phi-coherence — a ~-prefixed phi-roots entry expands against \$HOME and matches the expanded vault path (present)"
rm -f "$phi_tilde_home/.config/claude-glm/phi-roots"

# ── phi-coherence: ~\ -prefixed vaultPath (backslash form — CodeRabbit App
# finding, HIMMEL-2176 retask stage1-build-6d2e): the ~/ fix above left `~\`
# (the separator a Windows-authored config value actually writes, e.g.
# `~\Documents\luna`) still falling through expandHome()'s bare `return p`,
# same false 'present' this suite already proved for the ~/ form. Quoted
# heredoc (<<'JSON') below — an UNQUOTED heredoc's backslash-collapsing rule
# (POSIX: `\\` -> a single `\`) would corrupt the double-backslash JSON
# escaping this fixture needs. $HOME is driven through this fixture's own
# temp dir — never the real home.
phi_tildebs_home="$work/phi-tildebs-home"; mkdir -p "$phi_tildebs_home/Documents/luna" "$phi_tildebs_home/.config/claude-glm"
: > "$phi_tildebs_home/Documents/luna/.salus"
phi_tildebs_cfg="$work/phi-tildebs-config.json"
cat > "$phi_tildebs_cfg" <<'JSON'
{"version":1,"luna":{"vaultPath":"~\\Documents\\luna","cadence":{"enabled":false,"schedules":{"fetchHealth":{"time":"01:30"},"harvest":{"time":"02:00"},"synthesize":{"time":"03:00"},"health":{"time":"04:00","day":"SUN"}},"models":{"harvest":"sonnet","synthesize":"sonnet","health":"haiku"}},"phi":{"declared":false}},"bridge":{"enabled":false,"envPath":"~/x/.env","whisper":{"cli":null,"model":"ggml-small.bin"}}}
JSON

run_phi_tildebs() {
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$phi_tildebs_cfg")" HOME="$(winpath "$phi_tildebs_home")" USERPROFILE="$(winpath "$phi_tildebs_home")" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'phi-coherence');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
"
}

outPHItildebsVault=$(run_phi_tildebs)
echo "$outPHItildebsVault" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "phi-coherence: a ~\\-prefixed vaultPath must expand against \$HOME before the marker check — expected degraded (marker present via the real path, not listed) (got: $outPHItildebsVault)"
echo "$outPHItildebsVault" | jq -e '.detail | contains("~") | not' >/dev/null \
  || fail "phi-coherence: ~\\-prefixed vaultPath detail still carries a literal '~' — expansion did not happen (got: $outPHItildebsVault)"
echo "ok: phi-coherence — a ~\\-prefixed vaultPath expands against \$HOME and reads the correct (degraded) verdict, not a false 'present'"

# ── phi-coherence: ~\ -prefixed phi-roots entry (same finding, backslash
# form) — vaultPath here is already a fully-expanded absolute path; the
# phi-roots entry is the one that's `~\`-prefixed, and it must resolve to the
# SAME home-relative path as the vault for the probe to see them as coherent.
phi_tildebs2_vault="$phi_tildebs_home/Documents/luna2"; mkdir -p "$phi_tildebs2_vault"
: > "$phi_tildebs2_vault/.salus"
phi_tildebs2_cfg="$work/phi-tildebs2-config.json"
cat > "$phi_tildebs2_cfg" <<JSON
{"version":1,"luna":{"vaultPath":"$(winpath "$phi_tildebs2_vault")","cadence":{"enabled":false,"schedules":{"fetchHealth":{"time":"01:30"},"harvest":{"time":"02:00"},"synthesize":{"time":"03:00"},"health":{"time":"04:00","day":"SUN"}},"models":{"harvest":"sonnet","synthesize":"sonnet","health":"haiku"}},"phi":{"declared":false}},"bridge":{"enabled":false,"envPath":"~/x/.env","whisper":{"cli":null,"model":"ggml-small.bin"}}}
JSON
# shellcheck disable=SC2088  # deliberate literal '~' — the fixture proves the
# probe's OWN expandHome() call expands it, not the shell
printf '%s\n' '~\Documents\luna2' > "$phi_tildebs_home/.config/claude-glm/phi-roots"

run_phi_tildebs2() {
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$phi_tildebs2_cfg")" HOME="$(winpath "$phi_tildebs_home")" USERPROFILE="$(winpath "$phi_tildebs_home")" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'phi-coherence');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
"
}

outPHItildebsRoots=$(run_phi_tildebs2)
echo "$outPHItildebsRoots" | jq -e '.actual == "present"' >/dev/null \
  || fail "phi-coherence: a ~\\-prefixed phi-roots entry must expand against \$HOME to match a fully-expanded vaultPath — expected present (coherent) (got: $outPHItildebsRoots)"
echo "ok: phi-coherence — a ~\\-prefixed phi-roots entry expands against \$HOME and matches the expanded vault path (present)"
rm -f "$phi_tildebs_home/.config/claude-glm/phi-roots"

# ── engine-allowlist — HIMMEL-2176 Task 7, status item S4 ───────────────────
# Exercised against the REAL repo + the REAL cadence-approve-engines.sh
# script (never a copied literal), only PIPELINE_BAT_DIR is faked — proving
# the real manifest's `legs[].requiredSuffixes` genuinely stay covered by the
# real hook's live ENGINE_LIST (a drift here is a real bug, not a fixture
# artifact). The MISSING-suffix (fail) case below uses a deliberately
# fabricated item descriptor (never the real one) naming a suffix the real
# hook could never grant, so the failure path is exercised without needing a
# custom stub script.
ea_bat="$work/ea-batdir"; mkdir -p "$ea_bat"

outEAnone=$(PIPELINE_BAT_DIR="$(winpath "$ea_bat")" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'engine-allowlist');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outEAnone" | jq -e '.actual == "absent" and .cleanAbsence == true' >/dev/null \
  || fail "engine-allowlist: no known leg armed should read absent, cleanAbsence:true (got: $outEAnone)"
echo "ok: engine-allowlist — no luna cadence leg with a known engine requirement armed reads absent, cleanAbsence:true"

: > "$ea_bat/pipeline-health.bat"
outEAok=$(PIPELINE_BAT_DIR="$(winpath "$ea_bat")" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'engine-allowlist');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outEAok" | jq -e '.actual == "present"' >/dev/null \
  || fail "engine-allowlist: health armed, its real required suffix present in the live allow-list, should read present (got: $outEAok)"
echo "ok: engine-allowlist — an armed leg whose required engine(s) ARE present in the real cadence-approve-engines.sh allow-list reads present"

outEAmissing=$(PIPELINE_BAT_DIR="$(winpath "$ea_bat")" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = {
  id: 'engine-allowlist-fixture', probe: {
    type: 'engine-allowlist', script: 'scripts/hooks/cadence-approve-engines.sh',
    envVar: 'PIPELINE_BAT_DIR', defaultSubdir: '.claude/pipeline-cadence',
    legs: [{ schedule: 'health', requiredSuffixes: ['no/such/engine-script-exists.py'] }],
  },
};
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(require('$probes_lib_w').runProbe(item, ctx)));
")
echo "$outEAmissing" | jq -e '.actual == "absent" and (.cleanAbsence // false) == false' >/dev/null \
  || fail "engine-allowlist: an armed leg missing its required suffix from the live allow-list should read absent, a genuine fail (got: $outEAmissing)"
echo "$outEAmissing" | jq -e '.detail | contains("health") and contains("no/such/engine-script-exists.py")' >/dev/null \
  || fail "engine-allowlist: missing-suffix detail should name the leg + the missing suffix (got: $outEAmissing)"
echo "ok: engine-allowlist — an armed leg missing a required engine from the live allow-list reads absent (the silent-04:00-stall class), never cleanAbsence"
rm -f "$ea_bat"/*.bat

# ── bridge-health — HIMMEL-2176 Task 7, status item S5 ──────────────────────
# S5's binding rulings (probes.js's own header comment): (1) counts poller.ts
# CONSUMER processes only, never the combined supervisor-or-poller regex
# restart-bridge.ps1 uses for a different purpose; (2) Windows-CIM-only —
# EVERY other platform reads a LOUD degraded naming the limitation, never a
# silent pass. The poller-count check is routed through `bash -c` (this
# file's own established cross-platform seam), so a stub `powershell`
# EXECUTABLE on PATH fakes it here, never a JS mock.
bh_dir="$work/bh-dir"; mkdir -p "$bh_dir/.claude/channels/telegram"

# no token at all -> absent, cleanAbsence:true, short-circuited before any
# getMe/poller-count check runs at all. HIMMEL_LUNA_CONFIG_PATH points at a
# deliberately nonexistent path (defaultConfig() -> bridge.enabled:false)
# now that the token-absent branch itself consults ~/.himmel/config.json —
# never the real file.
outBHabs=$(HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/bh-config-missing.json")" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'bridge-health');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$(winpath "$bh_dir")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outBHabs" | jq -e '.actual == "absent" and .cleanAbsence == true' >/dev/null \
  || fail "bridge-health: no token configured should read absent, cleanAbsence:true (got: $outBHabs)"
echo "ok: bridge-health — no token configured (bridge never set up) reads absent, cleanAbsence:true, short-circuited"

# CR fix (HIMMEL-2176 round 6): a missing token alone used to mark
# cleanAbsence regardless of bridge.enabled — an adopter who explicitly set
# bridge.enabled:true in ~/.himmel/config.json got the same silent n/a
# downgrade as someone who never opted in. Pin both directions against
# lunaConfig.js's own HIMMEL_LUNA_CONFIG_PATH seam (never the real file), in
# a fresh dir carrying no telegram .env/access.json at all.
bh_cfg_dir="$work/bh-cfg-dir"; mkdir -p "$bh_cfg_dir/.claude/channels/telegram"

bh_cfg_enabled="$work/bh-config-enabled.json"
cat > "$bh_cfg_enabled" <<'JSON'
{"version":1,"luna":{"vaultPath":"/x","cadence":{"enabled":false,"schedules":{"fetchHealth":{"time":"01:30"},"harvest":{"time":"02:00"},"synthesize":{"time":"03:00"},"health":{"time":"04:00","day":"SUN"}},"models":{"harvest":"sonnet","synthesize":"sonnet","health":"haiku"}},"phi":{"declared":false}},"bridge":{"enabled":true,"envPath":"~/x/.env","whisper":{"cli":null,"model":"ggml-small.bin"}}}
JSON

bh_cfg_disabled="$work/bh-config-disabled.json"
cat > "$bh_cfg_disabled" <<'JSON'
{"version":1,"luna":{"vaultPath":"/x","cadence":{"enabled":false,"schedules":{"fetchHealth":{"time":"01:30"},"harvest":{"time":"02:00"},"synthesize":{"time":"03:00"},"health":{"time":"04:00","day":"SUN"}},"models":{"harvest":"sonnet","synthesize":"sonnet","health":"haiku"}},"phi":{"declared":false}},"bridge":{"enabled":false,"envPath":"~/x/.env","whisper":{"cli":null,"model":"ggml-small.bin"}}}
JSON

run_bh_cfg() {
  local cfgPath="$1"
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cfgPath")" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'bridge-health');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$(winpath "$bh_cfg_dir")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
"
}

# bridge.enabled:true + no token configured -> loud absent, NEVER
# cleanAbsence — the adopter explicitly asked for this subsystem and it
# cannot work without a token; status-report.js's opt-in downgrade must
# never fire here.
outBHenabledNoToken=$(run_bh_cfg "$bh_cfg_enabled")
echo "$outBHenabledNoToken" | jq -e '.actual == "absent" and (.cleanAbsence // false) == false' >/dev/null \
  || fail "bridge-health: bridge.enabled=true + no token should read absent, never cleanAbsence (got: $outBHenabledNoToken)"
echo "ok: bridge-health — bridge.enabled=true with no token configured reads a loud absent, never cleanAbsence"

# bridge.enabled:false (explicit) + no token -> absent, cleanAbsence:true —
# unchanged from the ordinary never-opted-in case.
outBHdisabledNoToken=$(run_bh_cfg "$bh_cfg_disabled")
echo "$outBHdisabledNoToken" | jq -e '.actual == "absent" and .cleanAbsence == true' >/dev/null \
  || fail "bridge-health: bridge.enabled=false + no token should read absent, cleanAbsence:true (got: $outBHdisabledNoToken)"
echo "ok: bridge-health — bridge.enabled=false (explicit) with no token configured reads absent, cleanAbsence:true"

cat > "$bh_dir/.claude/channels/telegram/.env" <<'ENV'
TELEGRAM_BOT_TOKEN=fake-bridge-health-token-marker
ENV
cat > "$bh_dir/.claude/channels/telegram/access.json" <<'JSON'
{"allowFrom": ["111"]}
JSON

bh_stub="$work/bh-stub"; mkdir -p "$bh_stub"
cat > "$bh_stub/bun" <<'STUB'
#!/usr/bin/env bash
echo "ok:testbot"
STUB
chmod +x "$bh_stub/bun"

# CR fix (codex-4, retask stage1-build-6d2e): probeBridgePollerCount now emits
# each matching process's own CommandLine (not a bare Count) so it can anchor
# to THIS checkout's own scripts/telegram/poller.ts — the stub `powershell`
# below therefore echoes raw CommandLine fixture lines (one per line), never a
# number; the real anchor/count logic lives in probes.js and is exercised
# here exactly as production would drive it.
repo_root_native_w=$(printf '%s' "$repo_root_w" | sed 's#/#\\#g')
other_checkout_native="C:\\Users\\testuser\\Documents\\github\\himmel\\.claude\\worktrees\\feat-some-other-checkout"

run_bh() {
  local lines="$1" platform="${2:-win32}" repoRootOverride="${3:-$repo_root_w}"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' "cat <<'PSOUT'"
    printf '%s\n' "$lines"
    printf '%s\n' 'PSOUT'
  } > "$bh_stub/powershell"
  chmod +x "$bh_stub/powershell"
  # Scrub any REAL powershell off the inherited PATH first (never assumed
  # absent by luck), then prepend the stub dir so ours is the one resolved.
  local pathVal
  pathVal="$bh_stub:$(scrub_path "$PATH" powershell)"
  PATH="$pathVal" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'bridge-health');
const ctx = { repoRoot: '$repoRootOverride', targetPath: '$(winpath "$bh_dir")', scope: 'project', platform: '$platform', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
"
}

# Bare, unpathed token — the genuine shape supervisor.ts's own
# `spawn(["bun","poller.ts"], {cwd})` produces (restart-bridge.ps1's own
# Test-BridgeCoreProc comment: "the genuine command lines carry NO path") —
# unattributable to any checkout by path alone, so it is still counted.
outBH1=$(run_bh 'bun.exe poller.ts' win32)
echo "$outBH1" | jq -e '.actual == "present"' >/dev/null \
  || fail "bridge-health: token getMe ok + access.json schema ok + exactly 1 bare-token poller should read present (got: $outBH1)"
echo "$outBH1" | jq -e '.detail | contains("fake-bridge-health-token-marker") | not' >/dev/null \
  || fail "bridge-health: the raw token must never appear in the result (got: $outBH1)"
echo "ok: bridge-health — token getMe ok + access.json schema ok + exactly 1 bare-token poller.ts process reads present, token never leaked"

outBH0=$(run_bh '' win32)
echo "$outBH0" | jq -e '.actual == "absent"' >/dev/null \
  || fail "bridge-health: 0 poller.ts processes should read absent (fail) (got: $outBH0)"
echo "ok: bridge-health — 0 poller.ts processes reads absent (fail)"

outBH2=$(run_bh "$(printf 'bun.exe poller.ts\nbun.exe poller.ts')" win32)
echo "$outBH2" | jq -e '.actual == "absent"' >/dev/null \
  || fail "bridge-health: 2 poller.ts processes (a supervisor+2 pollers or a duplicate) should read absent (fail) (got: $outBH2)"
echo "ok: bridge-health — 2 poller.ts processes (never exactly 1) reads absent (fail), never a false present"

outBHposix=$(run_bh 'bun.exe poller.ts' linux)
echo "$outBHposix" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "bridge-health: a non-win32 platform must read a LOUD degraded (HIMMEL-1128), never a silent present just because the token/access checks pass (got: $outBHposix)"
echo "$outBHposix" | jq -e '.detail | test("not implemented"; "i")' >/dev/null \
  || fail "bridge-health: the POSIX-degraded detail should name the limitation explicitly (got: $outBHposix)"
echo "ok: bridge-health — a non-Windows platform reads a LOUD degraded naming the poller-count limitation, never a silent pass"

# CR fix (codex-4, retask stage1-build-6d2e): a poller.ts token explicitly
# PATHED to THIS checkout's own root (mixed-slash form, matching winpath's
# cygpath -m output — HIMMEL-2176's own documented "mixed or native path
# form" reality) must still count as this checkout's poller.
outBHthisPathed=$(run_bh "bun.exe ${repo_root_w}/scripts/telegram/poller.ts" win32)
echo "$outBHthisPathed" | jq -e '.actual == "present"' >/dev/null \
  || fail "bridge-health: a poller.ts pathed to THIS checkout (mixed-slash) should still read present (got: $outBHthisPathed)"
echo "ok: bridge-health — a poller.ts token pathed to THIS checkout (mixed-slash form) reads present"

# Same checkout, but native backslashes and mismatched case — the anchor
# normalizes separators AND case (NTFS is case-insensitive; Win32_Process
# CommandLine has been observed in both separator forms).
outBHthisNativeUpper=$(run_bh "bun.exe $(printf '%s' "$repo_root_native_w" | tr '[:lower:]' '[:upper:]')\\SCRIPTS\\TELEGRAM\\POLLER.TS" win32)
echo "$outBHthisNativeUpper" | jq -e '.actual == "present"' >/dev/null \
  || fail "bridge-health: a poller.ts pathed to THIS checkout (native backslashes, upper-cased) should still read present (got: $outBHthisNativeUpper)"
echo "ok: bridge-health — a poller.ts token pathed to THIS checkout (native backslashes, mismatched case) reads present"

# CR round 3 fix (HIMMEL-2176, retask stage1-build-6d2e): [^\s"']* stopped at
# the first space, truncating a poller.ts path under a checkout with a space
# in it (e.g. 'C:\Users\John Doe\himmel\...') to a fragment that could never
# match the anchor — the healthy LOCAL poller then read as foreign and
# bridge-health falsely reported zero pollers. A real Win32_Process
# CommandLine quotes an argument containing a space, so the fixed extractor
# tries a QUOTED token first. This is the third of the three token shapes now
# covered: (1) bare, unpathed ('bun.exe poller.ts', outBH1 above); (2) an
# unquoted, space-free path (outBHthisPathed/outBHthisNativeUpper above); (3)
# this one — a quoted path containing a space.
bh_space_root_w='C:/Users/John Doe/himmel/.claude/worktrees/feat-space-checkout'
bh_space_root_native='C:\Users\John Doe\himmel\.claude\worktrees\feat-space-checkout'
outBHspaceQuoted=$(run_bh "bun.exe \"${bh_space_root_native}\\scripts\\telegram\\poller.ts\"" win32 "$bh_space_root_w")
echo "$outBHspaceQuoted" | jq -e '.actual == "present"' >/dev/null \
  || fail "bridge-health: a poller.ts path containing a space, quoted (the real Win32_Process shape), must still resolve to THIS checkout and read present (got: $outBHspaceQuoted)"
echo "ok: bridge-health — a quoted poller.ts path containing a space resolves to THIS checkout and reads present"

# The same space-containing checkout, but pathed to a DIFFERENT one — must
# still be excluded, proving the quoted extraction doesn't just always match.
outBHspaceQuotedForeign=$(run_bh "bun.exe \"${bh_space_root_native}\\scripts\\telegram\\poller.ts\"" win32 "$repo_root_w")
echo "$outBHspaceQuotedForeign" | jq -e '.actual == "absent"' >/dev/null \
  || fail "bridge-health: a quoted poller.ts path with a space, belonging to a DIFFERENT checkout, must not be counted as this one's (got: $outBHspaceQuotedForeign)"
echo "ok: bridge-health — a quoted poller.ts path with a space, pathed to a DIFFERENT checkout, is still excluded"

# CR fix (codex-4, retask stage1-build-6d2e): the exact gap this fix closes —
# a poller.ts token pathed to a DIFFERENT checkout must NOT be counted as
# this one's, even though the old bare-substring match would have counted it
# (false healthy, or a spurious duplicate alongside a real local poller).
outBHforeign=$(run_bh "bun.exe ${other_checkout_native}\\scripts\\telegram\\poller.ts" win32)
echo "$outBHforeign" | jq -e '.actual == "absent"' >/dev/null \
  || fail "bridge-health: a poller.ts pathed to a DIFFERENT checkout must not be counted as this one's (expected 0 -> absent, got: $outBHforeign)"
echo "$outBHforeign" | jq -e '.detail | contains("0 poller")' >/dev/null \
  || fail "bridge-health: a foreign-checkout poller must read as 0 for THIS checkout, not silently folded in (got: $outBHforeign)"
echo "ok: bridge-health — a poller.ts token pathed to a DIFFERENT checkout is excluded, never counted as this checkout's"

# A foreign-checkout poller alongside a genuinely healthy local one: the
# foreign one must not inflate the count into a spurious duplicate-poller
# failure on an otherwise-healthy bridge.
outBHmixedForeign=$(run_bh "bun.exe poller.ts"$'\n'"bun.exe ${other_checkout_native}\\scripts\\telegram\\poller.ts" win32)
echo "$outBHmixedForeign" | jq -e '.actual == "present"' >/dev/null \
  || fail "bridge-health: this checkout's healthy bare-token poller alongside an unrelated foreign-checkout poller should still read present, not a spurious duplicate (got: $outBHmixedForeign)"
echo "ok: bridge-health — a foreign-checkout poller alongside this checkout's healthy one does not force a spurious duplicate-poller failure"

# The existing supervisor-plus-child case, unchanged: the supervisor's own
# commandline never contains 'poller.ts' at all, so even if a defensive CIM
# query ever returned it alongside the real child, it must still read as
# exactly ONE consumer.
outBHsupervisorPlusChild=$(run_bh "$(printf 'bun.exe supervisor.ts\nbun.exe poller.ts')" win32)
echo "$outBHsupervisorPlusChild" | jq -e '.actual == "present"' >/dev/null \
  || fail "bridge-health: a supervisor.ts line alongside its poller.ts child must still read exactly 1 consumer (got: $outBHsupervisorPlusChild)"
echo "ok: bridge-health — a supervisor-plus-child pair still reads as exactly one poller.ts consumer"

# ── bridge-persistence — HIMMEL-2176 Stage-1 PR-C, status item S6 ───────────
# Contract (spec §3.5): logon task (win) / systemd unit + linger (linux)
# present when bridge.enabled; warn when enabled but persistence is absent.
# bridge.enabled:false is a clean opt-out (cleanAbsence:true), never red.
# Windows registration is verified by QUERYING THE SCHEDULER (stub schtasks
# on PATH), never inferred from a file on disk — the exact S1 false-green
# class this item exists to close. macOS/other reads a LOUD degraded naming
# the Stage-2 limitation (A12), never a silent pass.
bp_cfg_enabled="$work/bp-config-enabled.json"
cat > "$bp_cfg_enabled" <<'JSON'
{"version":1,"luna":{"vaultPath":"/x","cadence":{"enabled":false,"schedules":{"fetchHealth":{"time":"01:30"},"harvest":{"time":"02:00"},"synthesize":{"time":"03:00"},"health":{"time":"04:00","day":"SUN"}},"models":{"harvest":"sonnet","synthesize":"sonnet","health":"haiku"}},"phi":{"declared":false}},"bridge":{"enabled":true,"envPath":"~/x/.env","whisper":{"cli":null,"model":"ggml-small.bin"}}}
JSON
bp_cfg_disabled="$work/bp-config-disabled.json"
cat > "$bp_cfg_disabled" <<'JSON'
{"version":1,"luna":{"vaultPath":"/x","cadence":{"enabled":false,"schedules":{"fetchHealth":{"time":"01:30"},"harvest":{"time":"02:00"},"synthesize":{"time":"03:00"},"health":{"time":"04:00","day":"SUN"}},"models":{"harvest":"sonnet","synthesize":"sonnet","health":"haiku"}},"phi":{"declared":false}},"bridge":{"enabled":false,"envPath":"~/x/.env","whisper":{"cli":null,"model":"ggml-small.bin"}}}
JSON
bp_cfg_malformed="$work/bp-config-malformed.json"
printf '{not valid json' > "$bp_cfg_malformed"

run_bp() {
  # run_bp <configPath> <jsScript>
  local cfgPath="$1"; shift
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cfgPath")" "$node_bin" -e "$1"
}

bp_item_js='const { runProbe } = require("'"$probes_lib_w"'");
const manifest = JSON.parse(require("fs").readFileSync("'"$manifest_w"'", "utf8"));
const item = manifest.items.find((i) => i.id === "bridge-persistence");'

# ── case 1: bridge.enabled:false -> clean absence, opt-in, never red ───────
outBP1=$(run_bp "$bp_cfg_disabled" "
$bp_item_js
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outBP1" | jq -e '.actual == "absent" and .cleanAbsence == true' >/dev/null \
  || fail "bridge-persistence: bridge.enabled=false should read absent, cleanAbsence:true (got: $outBP1)"
echo "$outBP1" | jq -e '.detail | test("bridge.enabled"; "i")' >/dev/null \
  || fail "bridge-persistence: cleanAbsence detail should name bridge.enabled (got: $outBP1)"
echo "ok: bridge-persistence — bridge.enabled=false reads absent, cleanAbsence:true, never red"

# ── Linux branch: unit + linger, via stubbed systemctl/loginctl on PATH ────
# bridge-persistence.js calls spawnSync('systemctl'|'loginctl', ...) DIRECTLY
# (never through bash -c — its own module header: "every real command is run
# via spawnSync on the actual binary... never a spawned bash"). Sibling suite
# scripts/himmelctl/test/test-bridge-persistence.sh (Task 9) already
# documents this repo's Windows Git Bash dev host's exact limitation: Node
# refuses to spawnSync() a .bat/.cmd without shell:true (CVE-2024-27980), and
# an extensionless shebang script isn't CreateProcess-able at all — so the
# stub satisfies which()'s PATH-presence check (haveSystemctl()/
# haveLoginctl() read true) but the actual spawn ENOENTs, same shape as
# "genuinely absent". Same technique adopted here: the stub LOGS every
# invocation it actually receives; each spawn-dependent assertion below
# checks that log first and SKIPs (never fakes a pass) when the log shows the
# spawn never ran. On a real Linux/macOS host every assertion runs for real,
# no SKIP. The unit-ABSENT case (case 4 below) needs no such gate — fileExists
# is a pure fs.existsSync with no spawn dependency for its verdict, so it
# asserts unconditionally on every host.
bp_stub="$work/bp-stub"; mkdir -p "$bp_stub"
bp_stub_log="$work/bp-stub.log"
bp_stub_state="$work/bp-stub-state"; mkdir -p "$bp_stub_state"
bp_linux_unit_dir="$work/bp-linux-unit-dir"; mkdir -p "$bp_linux_unit_dir"

# On a real Linux host (retask stage1-build-6d2e — WSL) systemctl/loginctl
# live in /usr/bin ALONGSIDE bash itself (confirmed on this repo's WSL host).
# scrub_path drops a PATH dir WHOLESALE when it carries a scrubbed tool
# (HIMMEL-874/880's own documented hazard) — scrubbing systemctl/loginctl
# would therefore also drop bash, and the stub scripts' own
# `#!/usr/bin/env bash` shebang would then fail to resolve `bash` in the
# child's own PATH. link_hermetic_tool (hermetic-path.sh's documented
# convention: "link bash + whatever tools ... into a stub dir BEFORE calling
# scrub_path") keeps bash resolvable in $bp_stub regardless of what gets
# scrubbed. A no-op on Windows, where systemctl/loginctl are never on PATH at
# all — scrub_path drops nothing there and this stub is never actually
# spawned successfully anyway (see the file-header SKIP note above).
link_hermetic_tool bash "$bp_stub"

cat > "$bp_stub/systemctl" <<'STUB'
#!/usr/bin/env bash
: "${BP_STUB_LOG:?}"
echo "systemctl $*" >> "$BP_STUB_LOG"
case "$*" in
  "--user is-enabled telegram-bridge.service")
    if [ -f "${BP_STUB_STATE:?}/enabled" ]; then echo enabled; exit 0
    elif [ -f "${BP_STUB_STATE:?}/enabled-unknown" ]; then echo unknown; exit 3
    else echo disabled; exit 1; fi
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$bp_stub/systemctl"

cat > "$bp_stub/loginctl" <<'STUB'
#!/usr/bin/env bash
: "${BP_STUB_LOG:?}"
echo "loginctl $*" >> "$BP_STUB_LOG"
case "$*" in
  *"--property=Linger")
    if [ -f "${BP_STUB_STATE:?}/linger-yes" ]; then echo "Linger=yes"; exit 0
    elif [ -f "${BP_STUB_STATE:?}/linger-no" ]; then echo "Linger=no"; exit 0
    else exit 3; fi
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$bp_stub/loginctl"

bp_stub_log_has() { [ -f "$bp_stub_log" ] && grep -qF "$1" "$bp_stub_log"; }

run_bp_linux() {
  local unitDir="$1" cfgPath="$2"
  local pathVal
  pathVal="$bp_stub:$(scrub_path "$PATH" systemctl loginctl)"
  HIMMELCTL_SYSTEMD_USER_UNIT_DIR="$(winpath "$unitDir")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cfgPath")" \
    PATH="$pathVal" BP_STUB_LOG="$(winpath "$bp_stub_log")" BP_STUB_STATE="$(winpath "$bp_stub_state")" "$node_bin" -e "
$bp_item_js
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', platform: 'linux', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
"
}

# ── case 2: Linux, unit installed + linger on -> present ───────────────────
: > "$bp_linux_unit_dir/telegram-bridge.service"
rm -f "$bp_stub_log"; : > "$bp_stub_state/enabled"; rm -f "$bp_stub_state/linger-no"; : > "$bp_stub_state/linger-yes"
outBP2=$(run_bp_linux "$bp_linux_unit_dir" "$bp_cfg_enabled")
if bp_stub_log_has "is-enabled" && bp_stub_log_has "property=Linger"; then
  echo "$outBP2" | jq -e '.actual == "present"' >/dev/null \
    || fail "bridge-persistence: Linux unit installed+enabled, linger on should read present (got: $outBP2)"
  echo "ok: bridge-persistence — Linux: unit installed+enabled, linger on reads present"
else
  echo "SKIP: bridge-persistence — Linux unit+linger present case: no evidence in the stub log that systemctl/loginctl actually spawned on this host (see file header, CVE-2024-27980 / no-shebang-exec-on-Windows)"
fi

# ── case 3: Linux, unit installed + linger OFF -> warn, naming linger ──────
rm -f "$bp_stub_log"; : > "$bp_stub_state/enabled"; rm -f "$bp_stub_state/linger-yes"; : > "$bp_stub_state/linger-no"
outBP3=$(run_bp_linux "$bp_linux_unit_dir" "$bp_cfg_enabled")
if bp_stub_log_has "is-enabled" && bp_stub_log_has "property=Linger"; then
  echo "$outBP3" | jq -e '.actual == "degraded"' >/dev/null \
    || fail "bridge-persistence: Linux unit installed, linger OFF should read degraded (warn) (got: $outBP3)"
  echo "$outBP3" | jq -e '.detail | test("linger"; "i")' >/dev/null \
    || fail "bridge-persistence: linger-off detail should name linger specifically, not a generic absence (got: $outBP3)"
  echo "ok: bridge-persistence — Linux: unit installed, linger OFF reads degraded, naming linger specifically"
else
  echo "SKIP: bridge-persistence — Linux linger-OFF case: no evidence in the stub log that systemctl/loginctl actually spawned on this host (see file header, CVE-2024-27980 / no-shebang-exec-on-Windows)"
fi

# ── case 4: Linux, unit ABSENT -> warn, naming the unit. No SKIP gate here —
# fileExists is a pure fs.existsSync with no spawn dependency for the verdict
# (probeBridgePersistence short-circuits on !fileExists before ever calling
# lingerEnabled), so this is deterministic and testable on every host. ─────
bp_linux_no_unit_dir="$work/bp-linux-no-unit-dir"; mkdir -p "$bp_linux_no_unit_dir"
rm -f "$bp_stub_log"; rm -f "$bp_stub_state/enabled"; : > "$bp_stub_state/linger-yes"
outBP4=$(run_bp_linux "$bp_linux_no_unit_dir" "$bp_cfg_enabled")
echo "$outBP4" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "bridge-persistence: Linux unit ABSENT should read degraded (warn) (got: $outBP4)"
echo "$outBP4" | jq -e '.detail | test("telegram-bridge.service"; "i")' >/dev/null \
  || fail "bridge-persistence: unit-absent detail should name the unit (got: $outBP4)"
echo "ok: bridge-persistence — Linux: unit not installed reads degraded, naming the unit (deterministic, no spawn dependency)"

# ── case 4b (retask stage1-build-6d2e round 6): the unit FILE exists, but
# `systemctl --user is-enabled` reports it disabled/masked (rc!=0) — the
# SAME existence-is-not-enablement distinction as the Windows fix above.
# bridge-persistence.js's systemdUnitInstalled() already derives `enabled`
# from is-enabled's own exit code (never from file presence alone), so this
# closes a TEST gap, not a code gap — confirming that behavior end-to-end
# through this probe rather than just asserting it in prose. Same SKIP gate
# as cases 2/3: genuinely exercised only where the spawn can actually run
# (never on this repo's Windows dev host — see the file-header note above).
: > "$bp_linux_unit_dir/telegram-bridge.service"
rm -f "$bp_stub_log"; rm -f "$bp_stub_state/enabled"; : > "$bp_stub_state/linger-yes"
outBP4b=$(run_bp_linux "$bp_linux_unit_dir" "$bp_cfg_enabled")
if bp_stub_log_has "is-enabled"; then
  echo "$outBP4b" | jq -e '.actual == "degraded"' >/dev/null \
    || fail "bridge-persistence: Linux unit file present but is-enabled reports disabled must read degraded, never present (got: $outBP4b)"
  echo "$outBP4b" | jq -e '.detail | test("not enabled"; "i")' >/dev/null \
    || fail "bridge-persistence: disabled-unit detail should distinguish 'installed but not enabled' from 'not installed' (got: $outBP4b)"
  echo "ok: bridge-persistence — Linux: unit file present but systemctl is-enabled reports disabled reads degraded, never present"
else
  echo "SKIP: bridge-persistence — Linux unit-disabled case: no evidence in the stub log that systemctl actually spawned on this host"
fi

# ── case 4c (CR fix, retask stage1-build-6d2e round 6, CRITICAL): unit file
# exists but `systemctl --user is-enabled` exits with an UNRECOGNIZED code
# (neither 0 nor 1) — systemdUnitInstalled()'s `enabled` is a genuine
# tri-state (true/false/null) and this is the null/UNDETERMINED case, not a
# confirmed "not enabled". The pre-fix `enabled !== true` check folded this
# into the same "installed but not enabled" wording as case 4b's confirmed-
# disabled unit — telling an operator to `systemctl enable` a unit whose
# enablement was never actually established. The detail here must NOT claim
# "not enabled" and MUST name the undetermined condition, while the verdict
# stays degraded either way. Same SKIP gate as 4b (spawn-dependent).
: > "$bp_linux_unit_dir/telegram-bridge.service"
rm -f "$bp_stub_log"; rm -f "$bp_stub_state/enabled"; : > "$bp_stub_state/enabled-unknown"; : > "$bp_stub_state/linger-yes"
outBP4c=$(run_bp_linux "$bp_linux_unit_dir" "$bp_cfg_enabled")
rm -f "$bp_stub_state/enabled-unknown"
if bp_stub_log_has "is-enabled"; then
  echo "$outBP4c" | jq -e '.actual == "degraded"' >/dev/null \
    || fail "bridge-persistence: Linux unit file present, is-enabled UNDETERMINED must still read degraded (got: $outBP4c)"
  echo "$outBP4c" | jq -e '.detail | test("not enabled"; "i") | not' >/dev/null \
    || fail "bridge-persistence: undetermined-enablement detail must NOT claim 'not enabled' — that was never established (got: $outBP4c)"
  echo "$outBP4c" | jq -e '.detail | test("could not be determined"; "i")' >/dev/null \
    || fail "bridge-persistence: undetermined-enablement detail should name the undetermined condition (got: $outBP4c)"
  echo "ok: bridge-persistence — Linux: unit file present but is-enabled UNDETERMINED reads degraded without claiming 'not enabled'"
else
  echo "SKIP: bridge-persistence — Linux unit-enablement-undetermined case: no evidence in the stub log that systemctl actually spawned on this host"
fi

# ── case 4d (same sweep, retask stage1-build-6d2e): unit installed+enabled,
# but `loginctl show-user --property=Linger` fails (neither yes nor no) — the
# stub's existing else-branch (exit 3) already models this; lingerEnabled()
# treats any non-zero rc as null/UNDETERMINED, same tri-state shape as
# unitInfo.enabled above, and the pre-fix `linger !== true` check folded it
# into the same "linger is NOT enabled" wording as a confirmed-off linger.
# Detail here must NOT claim linger is confirmed off and MUST name the
# undetermined condition; verdict stays degraded either way.
: > "$bp_linux_unit_dir/telegram-bridge.service"
rm -f "$bp_stub_log"; : > "$bp_stub_state/enabled"; rm -f "$bp_stub_state/linger-yes" "$bp_stub_state/linger-no"
outBP4d=$(run_bp_linux "$bp_linux_unit_dir" "$bp_cfg_enabled")
if bp_stub_log_has "is-enabled" && bp_stub_log_has "property=Linger"; then
  echo "$outBP4d" | jq -e '.actual == "degraded"' >/dev/null \
    || fail "bridge-persistence: Linux unit installed+enabled, linger query UNDETERMINED must still read degraded (got: $outBP4d)"
  echo "$outBP4d" | jq -e '.detail | test("linger is NOT enabled"; "i") | not' >/dev/null \
    || fail "bridge-persistence: undetermined-linger detail must NOT claim linger is confirmed NOT enabled — that was never established (got: $outBP4d)"
  echo "$outBP4d" | jq -e '.detail | test("could not be determined"; "i")' >/dev/null \
    || fail "bridge-persistence: undetermined-linger detail should name the undetermined condition (got: $outBP4d)"
  echo "ok: bridge-persistence — Linux: unit installed+enabled, linger query UNDETERMINED reads degraded without claiming linger is confirmed off"
else
  echo "SKIP: bridge-persistence — Linux linger-undetermined case: no evidence in the stub log that systemctl/loginctl actually spawned on this host"
fi

# ── case 4e (CR fix, retask stage1-build-6d2e, final round): the SPAWN side
# of the class cases 4c/4d already proved for the config-path READ side —
# bridgePersistence.systemdUnitInstalled()/lingerEnabled() take no
# parameters and resolve+spawn systemctl/loginctl purely off the ambient
# process.env (which()'s PATH lookup, spawnSync's inherited env). A single
# node -e invocation drives it: the REAL subprocess PATH has systemctl AND
# loginctl scrubbed entirely (so a bug that ignores ctx.env would find
# nothing and read degraded/undetermined), while a MINIMAL ctx.env (no
# process.env spread) carries its OWN PATH pointing at a stub dir where
# systemctl/loginctl report the unit installed+enabled and linger on. Only a
# genuine ctx.env-scoped resolve+spawn can make this read present — same
# SKIP gate as every other Linux bridge-persistence spawn case (this stub
# never actually spawns on this repo's Windows dev host).
bp_ctxenv_stub="$work/bp-ctxenv-stub"; mkdir -p "$bp_ctxenv_stub"
link_hermetic_tool bash "$bp_ctxenv_stub"
cat > "$bp_ctxenv_stub/systemctl" <<'STUB'
#!/usr/bin/env bash
: "${BP_STUB_LOG:?}"
echo "systemctl $*" >> "$BP_STUB_LOG"
case "$*" in
  "--user is-enabled telegram-bridge.service") echo enabled; exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$bp_ctxenv_stub/systemctl"
cat > "$bp_ctxenv_stub/loginctl" <<'STUB'
#!/usr/bin/env bash
: "${BP_STUB_LOG:?}"
echo "loginctl $*" >> "$BP_STUB_LOG"
case "$*" in
  *"--property=Linger") echo "Linger=yes"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$bp_ctxenv_stub/loginctl"
bp_ctxenv_unit_dir="$work/bp-ctxenv-unit-dir"; mkdir -p "$bp_ctxenv_unit_dir"
: > "$bp_ctxenv_unit_dir/telegram-bridge.service"
bp_ctxenv_log="$work/bp-ctxenv-stub.log"; rm -f "$bp_ctxenv_log"
outBPctxEnvSpawn=$(HIMMELCTL_SYSTEMD_USER_UNIT_DIR="$(winpath "$bp_ctxenv_unit_dir")" \
  PATH="$(scrub_path "$PATH" systemctl loginctl)" "$node_bin" -e "
$bp_item_js
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', platform: 'linux',
  env: {
    PATH: '$(winpath "$bp_ctxenv_stub")',
    USER: 'ctxenv-user',
    HOME: '$(winpath "$work")',
    HIMMEL_LUNA_CONFIG_PATH: '$(winpath "$bp_cfg_enabled")',
    BP_STUB_LOG: '$(winpath "$bp_ctxenv_log")',
  } };
console.log(JSON.stringify(runProbe(item, ctx)));
")
if [ -s "$bp_ctxenv_log" ]; then
  echo "$outBPctxEnvSpawn" | jq -e '.actual == "present"' >/dev/null \
    || fail "bridge-persistence: ctx.env PATH must drive the systemctl/loginctl resolve+spawn, not the ambient process.env (got: $outBPctxEnvSpawn)"
  echo "ok: bridge-persistence — Linux: ctx.env (not ambient process.env) drives the systemctl/loginctl resolve+spawn (HIMMEL-2176 CR fix, retask stage1-build-6d2e)"
else
  echo "SKIP: bridge-persistence — ctx.env spawn-routing case: no evidence in the stub log that systemctl/loginctl actually spawned on this host"
fi

# ── Windows branch: scheduler registration via a stubbed powershell on PATH ──
# CR fix (codex-2, retask stage1-build-6d2e round 7): schtasks' text output
# is LOCALIZED (both the field label and the "Enabled" value translate on
# non-English Windows) — probes.js now queries Get-ScheduledTask and reads
# its `.State` enum via `.ToString()`, which is culture-invariant BY
# CONSTRUCTION (Ready/Disabled/Running/Queued — .NET enum member names, never
# translated). The stub therefore fakes `powershell`, not `schtasks`, and
# every case below drives it with the INVARIANT enum member name — exactly
# what a REAL non-English Windows would also produce, proving the fix
# without needing to fake an actual German/Japanese/etc. locale.
write_bp_powershell() {
  # $1: 0 (task found, emit STATE:$2, rc=0) | 1 (task genuinely not found —
  #     emit NOTFOUND, rc=0 — the real Get-ScheduledTask/FullyQualifiedErrorId
  #     match probes.js now performs, replacing the old -ErrorAction
  #     SilentlyContinue swallowed-error shape) | 2 (query fails at the
  #     process level — spawn/timeout/crash — nonzero rc, no output) |
  #     3 (query fails but PowerShell itself CATCHES the error, rc=0 — e.g.
  #     the ScheduledTasks module unavailable, access denied, a WinRM/CIM
  #     problem — retask stage1-build-6d2e: this must NOT read absent, since
  #     unlike mode 1 nothing ever confirmed the task doesn't exist)
  # $2: OPTIONAL — the State enum member to emit when $1=0 (default: Ready)
  local mode="$1" state="${2:-Ready}"
  # resolvePowershell() PREFERS pwsh over powershell — a leftover
  # $bp_stub/pwsh from an earlier case (write_bp_pwsh_only) would silently
  # shadow this fresh powershell write otherwise, since bp_stub is reused
  # across every Windows-branch case in this file.
  rm -f "$bp_stub/pwsh"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    if [ "$mode" = "0" ]; then
      printf 'echo "STATE:%s"\n' "$state"
    elif [ "$mode" = "1" ]; then
      printf 'echo "NOTFOUND"\n'
    elif [ "$mode" = "3" ]; then
      # A representative real FullyQualifiedErrorId for a CAUGHT, non-absent
      # failure — same shape confirmed on a real host for e.g. the
      # ScheduledTasks module missing (CommandNotFoundException), distinct
      # from the exact CmdletizationQuery_NotFound_TaskName match.
      printf 'echo "ERR:HResult 0x80070005,Get-ScheduledTask"\n'
    fi
    if [ "$mode" = "2" ]; then
      printf 'exit 2\n'
    else
      printf 'exit 0\n'
    fi
  } > "$bp_stub/powershell"
  chmod +x "$bp_stub/powershell"
}

run_bp_win() {
  local cfgPath="$1"
  local pathVal
  # Scrub BOTH names, not just 'powershell' (retask stage1-build-6d2e round
  # 12, caught here): resolvePowershell() PREFERS pwsh, so a real pwsh.exe
  # left on PATH shadows the $bp_stub/powershell stub below and this test
  # queries the REAL Windows Task Scheduler instead — exactly what happened
  # on this dev machine (it found a genuine 'HimmelTelegramBridge' task).
  pathVal="$bp_stub:$(scrub_path "$PATH" powershell pwsh)"
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cfgPath")" PATH="$pathVal" "$node_bin" -e "
$bp_item_js
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', platform: 'win32', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
"
}

# write_bp_pwsh_only <state> — a $bp_stub/pwsh stub only, NO powershell stub
# anywhere (retask stage1-build-6d2e round 12, codex-2): proves the probe
# resolves the interpreter via helpers.js's resolvePowershell() (which
# PREFERS pwsh) rather than a hardcoded 'powershell' binary name — the same
# helper bridge-persistence.js (the installer half of this feature) already
# uses, so a PowerShell-7-only machine doesn't have the installer succeed
# while the probe reports persistence as unknown forever.
write_bp_pwsh_only() {
  local state="${1:-Ready}"
  rm -f "$bp_stub/powershell"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'echo "STATE:%s"\n' "$state"
    printf 'exit 0\n'
  } > "$bp_stub/pwsh"
  chmod +x "$bp_stub/pwsh"
}

run_bp_win_pwsh_only() {
  local cfgPath="$1"
  local pathVal
  # Scrub BOTH names off the OUTER (real) PATH — bp_stub itself (prepended)
  # carries only `pwsh` (write_bp_pwsh_only above already removed any
  # leftover `powershell` stub from an earlier case), so `pwsh` is the ONLY
  # thing either name can resolve to.
  pathVal="$bp_stub:$(scrub_path "$PATH" powershell pwsh)"
  HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cfgPath")" PATH="$pathVal" "$node_bin" -e "
$bp_item_js
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', platform: 'win32', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
"
}

# ── case 5: Windows, scheduled task registered (State=Ready) -> present ────
write_bp_powershell 0 Ready
outBP5=$(run_bp_win "$bp_cfg_enabled")
echo "$outBP5" | jq -e '.actual == "present"' >/dev/null \
  || fail "bridge-persistence: Windows task registered (Ready) should read present (got: $outBP5)"
echo "ok: bridge-persistence — Windows: scheduled task registered (State=Ready) reads present"

# ── case 5b: State=Running is ALSO a healthy/active state, not just Ready —
# proves the classification isn't hardcoded to a single enum member. ───────
write_bp_powershell 0 Running
outBP5b=$(run_bp_win "$bp_cfg_enabled")
echo "$outBP5b" | jq -e '.actual == "present"' >/dev/null \
  || fail "bridge-persistence: Windows task registered (Running) should read present (got: $outBP5b)"
echo "ok: bridge-persistence — Windows: scheduled task registered (State=Running) reads present"

# ── case 5c (retask stage1-build-6d2e round 12, codex-2): only `pwsh`
# resolves — NO `powershell` anywhere on PATH — must still classify
# correctly (present), never 'unknown'. A machine with only PowerShell 7
# installed is a real, common shape; a hardcoded 'powershell' binary name
# would never find an interpreter there. ───────────────────────────────────
write_bp_pwsh_only Ready
outBP5c=$(run_bp_win_pwsh_only "$bp_cfg_enabled")
echo "$outBP5c" | jq -e '.actual == "present"' >/dev/null \
  || fail "bridge-persistence: with ONLY pwsh resolving (no powershell), an enabled task must still read present, not unknown (got: $outBP5c)"
echo "ok: bridge-persistence — Windows: only pwsh resolves (no powershell), task registered still reads present"

# ── case 6: Windows, task NOT registered -> warn. Anti-false-green: a
# plausible runner/launcher FILE existing on disk must NOT flip this to
# present — only the scheduler's own answer may. ───────────────────────────
bp_fake_runner_dir="$work/bp-fake-runner"; mkdir -p "$bp_fake_runner_dir"
: > "$bp_fake_runner_dir/restart-bridge.ps1"
: > "$bp_fake_runner_dir/HimmelTelegramBridge.xml"
write_bp_powershell 1
outBP6=$(run_bp_win "$bp_cfg_enabled")
echo "$outBP6" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "bridge-persistence: Windows task not registered should read degraded (warn), even with a plausible runner file present on disk (got: $outBP6)"
echo "$outBP6" | jq -e '.detail | test("HimmelTelegramBridge"; "i")' >/dev/null \
  || fail "bridge-persistence: not-registered detail should name the task (got: $outBP6)"
echo "ok: bridge-persistence — Windows: task not registered reads degraded (warn), never inferred present from a runner file on disk"

# ── case 6b (retask stage1-build-6d2e round 6, CRITICAL codex-1): the task
# EXISTS (State=Disabled) — a disabled task will not run at logon, so this
# must NOT read present. Existence is not enablement. ──────────────────────
write_bp_powershell 0 Disabled
outBP6b=$(run_bp_win "$bp_cfg_enabled")
echo "$outBP6b" | jq -e '.actual != "present"' >/dev/null \
  || fail "bridge-persistence: a task that exists but is Disabled must NEVER read present (got: $outBP6b)"
echo "$outBP6b" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "bridge-persistence: a Disabled task should read degraded (warn), not absent/unknown (got: $outBP6b)"
echo "$outBP6b" | jq -e '.detail | test("Disabled"; "i")' >/dev/null \
  || fail "bridge-persistence: disabled-task detail should name the Disabled state, not just 'exists' (got: $outBP6b)"
echo "ok: bridge-persistence — Windows: task exists but is Disabled reads degraded, never present (existence is not enablement)"

# ── case 7: Windows, scheduler query FAILS (unexpected rc) -> unknown/degraded, NEVER present ──
write_bp_powershell 2
outBP7=$(run_bp_win "$bp_cfg_enabled")
echo "$outBP7" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "bridge-persistence: a failed scheduler query should read degraded, never present (got: $outBP7)"
echo "$outBP7" | jq -e '.detail | test("unknown"; "i")' >/dev/null \
  || fail "bridge-persistence: a failed scheduler query detail should call the registration status unknown (got: $outBP7)"
echo "ok: bridge-persistence — Windows: a failed scheduler query reads degraded/unknown, never present"

# ── case 7b (CR fix, retask stage1-build-6d2e): Get-ScheduledTask query
# CAUGHT an error that is NOT the exact "no such task" identifier (e.g. the
# ScheduledTasks module unavailable, access denied, a WinRM/CIM problem) —
# PowerShell itself exits 0 here (the try/catch swallows it internally), so
# this is a DIFFERENT failure shape than case 7's process-level rc=2. The
# pre-fix `-ErrorAction SilentlyContinue` collapsed this into the same
# empty-stdout/rc=0 shape as a genuine not-found, reading it 'absent' — an
# operator would then be told to reinstall persistence when the truth is the
# scheduler could not be queried at all. Must read degraded/unknown, and the
# detail must NOT claim the task is absent/not registered. ──────────────────
write_bp_powershell 3
outBP7b=$(run_bp_win "$bp_cfg_enabled")
echo "$outBP7b" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "bridge-persistence: a caught (non-not-found) scheduler query error should read degraded, never present (got: $outBP7b)"
echo "$outBP7b" | jq -e '.detail | test("unknown"; "i")' >/dev/null \
  || fail "bridge-persistence: a caught scheduler query error detail should call the registration status unknown (got: $outBP7b)"
echo "$outBP7b" | jq -e '.detail | test("no scheduled task named"; "i") | not' >/dev/null \
  || fail "bridge-persistence: a caught (non-not-found) error must NOT be worded as a confirmed absence (got: $outBP7b)"
echo "ok: bridge-persistence — Windows: a caught scheduler query error (not the exact not-found identifier) reads degraded/unknown, never absent or present"

# ── case 8: unsupported platform (darwin) -> loud degraded naming Stage 2 ──
outBP8=$(run_bp "$bp_cfg_enabled" "
$bp_item_js
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', platform: 'darwin', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outBP8" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "bridge-persistence: an unsupported platform (darwin) should read a LOUD degraded, never a silent pass (got: $outBP8)"
echo "$outBP8" | jq -e '.detail | test("Stage 2"; "i") or (.detail | test("launchd"; "i"))' >/dev/null \
  || fail "bridge-persistence: the unsupported-platform detail should name the launchd/Stage-2 limitation explicitly (got: $outBP8)"
echo "ok: bridge-persistence — an unsupported platform (darwin) reads a LOUD degraded naming the launchd/Stage-2 limitation, never a silent pass"

# ── case: malformed config must not crash the probe (Part B #12, shared) ───
outBPmalformed=$(run_bp "$bp_cfg_malformed" "
$bp_item_js
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outBPmalformed" | jq -e '.actual == "degraded" and (.detail | test("luna config"; "i"))' >/dev/null \
  || fail "bridge-persistence: a malformed config.json must not crash the probe — degrades naming the config read failure (got: $outBPmalformed)"
echo "ok: bridge-persistence — a malformed config.json degrades cleanly, never crashes the probe"

# ── Part B — the inert-config wiring closes: bridge.envPath / bridge.whisper.{cli,model} ──
# HIMMEL-2176 Stage-1 PR-C, Part B: these config fields used to be read by
# NOTHING (probeTelegramAccess/probeTelegramGetMe only ever consulted the
# manifest's hardcoded envFile; probeWhisperReady only ever consulted
# WHISPER_*/hardcoded defaults). Precedence pinned here: explicit process-env
# override (TELEGRAM_ENV / WHISPER_CLI/WHISPER_MODEL) wins, else the
# adopter's configured value, else the hardcoded default.
pb_home="$work/pb-home"; mkdir -p "$pb_home/.claude/channels/telegram"
pb_configured_env_dir="$work/pb-configured-env"; mkdir -p "$pb_configured_env_dir"
cat > "$pb_configured_env_dir/bridge.env" <<'ENV'
TELEGRAM_BOT_TOKEN=configured-path-token-marker
ENV
cat > "$pb_home/.claude/channels/telegram/access.json" <<'JSON'
{"allowFrom": ["1"]}
JSON
# NOTE: the manifest default envFile ('.claude/channels/telegram/.env' under
# $pb_home) is deliberately left EMPTY/absent — only the CONFIGURED path
# carries a token, so a pass here proves resolution actually followed the
# configured value, not a coincidental fallback.
pb_cfg_envpath="$work/pb-config-envpath.json"
cat > "$pb_cfg_envpath" <<JSON
{"version":1,"luna":{"vaultPath":"/x","cadence":{"enabled":false,"schedules":{"fetchHealth":{"time":"01:30"},"harvest":{"time":"02:00"},"synthesize":{"time":"03:00"},"health":{"time":"04:00","day":"SUN"}},"models":{"harvest":"sonnet","synthesize":"sonnet","health":"haiku"}},"phi":{"declared":false}},"bridge":{"enabled":true,"envPath":"$(winpath "$pb_configured_env_dir/bridge.env")","whisper":{"cli":null,"model":"ggml-small.bin"}}}
JSON

# ── case 9: configured bridge.envPath, no TELEGRAM_ENV override -> resolves there ──
outPB9=$(HIMMEL_LUNA_CONFIG_PATH="$(winpath "$pb_cfg_envpath")" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'telegram-bridge');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$pb_home")', TELEGRAM_ENV: undefined }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outPB9" | jq -e '.actual == "present"' >/dev/null \
  || fail "Part B case 9: bridge.envPath configured (no TELEGRAM_ENV) should resolve the token from the configured path (got: $outPB9)"
echo "ok: Part B case 9 — bridge.envPath configured, no TELEGRAM_ENV override, resolves from the configured path"

# ── case 10: TELEGRAM_ENV override present AND a different configured value -> env wins ──
pb_override_env_dir="$work/pb-override-env"; mkdir -p "$pb_override_env_dir"
cat > "$pb_override_env_dir/override.env" <<'ENV'
TELEGRAM_BOT_TOKEN=env-override-token-marker
ENV
outPB10=$(HIMMEL_LUNA_CONFIG_PATH="$(winpath "$pb_cfg_envpath")" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'telegram-bridge');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$pb_home")', TELEGRAM_ENV: '$(winpath "$pb_override_env_dir/override.env")' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outPB10" | jq -e '.actual == "present"' >/dev/null \
  || fail "Part B case 10: TELEGRAM_ENV override should win over a different configured envPath (got: $outPB10)"
echo "$outPB10" | jq -e '.detail | contains("configured-path-token-marker")' >/dev/null \
  && fail "Part B case 10: the configured-path env file must NOT have been read once TELEGRAM_ENV overrides it (got: $outPB10)"
echo "ok: Part B case 10 — TELEGRAM_ENV process-env override wins over a different configured bridge.envPath"

# ── case 10b (retask stage1-build-6d2e round 9, codex-3): TELEGRAM_ENV set
# to a ~/-prefixed path must expand against HOME before resolving — the
# configured-envPath branch already expanded `~`, the override branch used
# to return the raw value verbatim, so the HIGHEST-priority input was the
# one most likely to fail for an adopter who set it the natural way. ──────
pb_tilde_env_dir="$pb_home/tilde-env-dir"; mkdir -p "$pb_tilde_env_dir"
cat > "$pb_tilde_env_dir/tilde.env" <<'ENV'
TELEGRAM_BOT_TOKEN=tilde-slash-override-token-marker
ENV
outPB10b=$(HIMMEL_LUNA_CONFIG_PATH="$(winpath "$pb_cfg_envpath")" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'telegram-bridge');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$pb_home")', TELEGRAM_ENV: '~/tilde-env-dir/tilde.env' }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outPB10b" | jq -e '.actual == "present"' >/dev/null \
  || fail "Part B case 10b: TELEGRAM_ENV=~/... must expand against HOME before resolving (got: $outPB10b)"
echo "ok: Part B case 10b — TELEGRAM_ENV with a ~/-prefixed path expands against HOME and resolves"

# ── case 10c: TELEGRAM_ENV set to a ~\-prefixed (backslash) path — the
# documented HIMMEL-2263 gap class — must ALSO expand correctly. The raw
# value is passed through a real env var (never interpolated into the JS
# source string) so neither bash's nor JS's own backslash-escape handling
# can corrupt it — same convention this suite already uses for any fixture
# value that might carry a backslash or apostrophe. Windows-only assertion:
# expandHomeForCtx's path.join(home, p.slice(2)) only SPLITS on `\` as a
# separator on win32 — on POSIX, Node's path.join keeps a `\` as a literal
# filename character (the exact, already-ticketed HIMMEL-2275 class the
# EXISTING phi-coherence `~\` test already hits on this suite's WSL run) —
# so this stays a Windows-only proof rather than adding a 13th Linux
# failure to a bucket the coordinator is tracking as a fixed count of 12.
pb_tildebs_env_dir="$pb_home/tildebs-env-dir"; mkdir -p "$pb_tildebs_env_dir"
cat > "$pb_tildebs_env_dir/tildebs.env" <<'ENV'
TELEGRAM_BOT_TOKEN=tilde-backslash-override-token-marker
ENV
if is_win32; then
  outPB10c=$(HIMMEL_LUNA_CONFIG_PATH="$(winpath "$pb_cfg_envpath")" PB_TILDEBS_RAW='~\tildebs-env-dir\tildebs.env' "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'telegram-bridge');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { HOME: '$(winpath "$pb_home")', TELEGRAM_ENV: process.env.PB_TILDEBS_RAW }) };
console.log(JSON.stringify(runProbe(item, ctx)));
")
  echo "$outPB10c" | jq -e '.actual == "present"' >/dev/null \
    || fail "Part B case 10c: TELEGRAM_ENV=~\\... (backslash, HIMMEL-2263 gap class) must expand against HOME before resolving (got: $outPB10c)"
  printf '%s\n' "ok: Part B case 10c — TELEGRAM_ENV with a ~\\-prefixed (backslash) path expands against HOME and resolves"
else
  # printf, not echo (SC2028): this message's text carries a literal
  # backslash, and echo's escape-interpretation behavior is shell-dependent —
  # printf '%s' never re-interprets its argument, portable everywhere, the
  # same convention the rest of this repo's shell already uses for anything
  # containing a backslash.
  printf '%s\n' "SKIP: Part B case 10c — ~\\-prefixed TELEGRAM_ENV is a Windows-only path shape (path.join doesn't split on '\\' on POSIX — the same known HIMMEL-2275 class as the existing phi-coherence ~\\ test)"
fi

# ── case: no config at all -> whisper_ready behaves identically to today (regression guard) ──
pb_no_config="$work/pb-no-config.json"
pb_whisper_dir="$work/pb-whisper-dir"; mkdir -p "$pb_whisper_dir"
printf 'stub-binary' > "$pb_whisper_dir/whisper-cli.exe"
printf 'stub-model' > "$pb_whisper_dir/ggml-small.bin"
outPBnoConfig=$(HIMMEL_LUNA_CONFIG_PATH="$(winpath "$pb_no_config")" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'whisper-transcription', probe: { type: 'cmd:whisper_ready' } };
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { WHISPER_DIR: '$(winpath "$pb_whisper_dir")', WHISPER_CLI: undefined, WHISPER_MODEL: undefined }), platform: 'win32' };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outPBnoConfig" | jq -e '.actual == "present"' >/dev/null \
  || fail "Part B regression: whisper_ready with NO config file at all should behave exactly as before this ticket (got: $outPBnoConfig)"
echo "ok: Part B regression — cmd:whisper_ready with no config file at all resolves exactly as before this ticket"

# ── case: malformed config -> whisper_ready degrades, never crashes ────────
outPBwhisperMalformed=$(HIMMEL_LUNA_CONFIG_PATH="$(winpath "$bp_cfg_malformed")" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'whisper-transcription', probe: { type: 'cmd:whisper_ready' } };
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user',
  env: Object.assign({}, process.env, { WHISPER_DIR: '$(winpath "$pb_whisper_dir")', WHISPER_CLI: undefined, WHISPER_MODEL: undefined }), platform: 'win32' };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outPBwhisperMalformed" | jq -e '.actual == "degraded" and (.detail | test("luna config"; "i"))' >/dev/null \
  || fail "Part B: cmd:whisper_ready with a malformed config.json must degrade cleanly, never crash (got: $outPBwhisperMalformed)"
echo "ok: Part B — cmd:whisper_ready with a malformed config.json degrades cleanly, never crashes"

# ── HIMMEL-2289 regression: bash-backed probes must resolve via HIMMELCTL_BASH,
# never the bare `bash` name — a sabotage-stub `bash` FIRST on PATH stands in
# for Windows System32's WSL launcher (the exact binary that broke
# doc-guard-map / handover-wiring / hermes-lanes on a fully healthy host
# before this fix — see probes.js's resolveProbeBash/spawnBashProbe header
# comment). Each positive case proves the probe still reads its healthy
# verdict when HIMMELCTL_BASH points at a real bash despite the sabotage stub
# shadowing PATH (this fails against the pre-fix bare-`bash` spawn); each
# negative control pins HIMMELCTL_BASH AT the sabotage stub instead, proving
# the positive assertion isn't vacuous. ─────────────────────────────────────
real_bash_w="$(winpath "$(command -v bash)")"

# HIMMEL-2289: when this stub is PINNED directly as HIMMELCTL_BASH (the
# negative controls, and the toolchain-row non-vacuous case below) it is
# spawned DIRECTLY (never via a real bash's own shebang exec) — and this
# host's own documented Windows limitation (see the bridge-persistence
# "Linux branch" comment above, CVE-2024-27980 / no-shebang-exec-on-Windows)
# means a plain extensionless `#!/usr/bin/env bash` script isn't
# CreateProcess-able as a directly-spawned `bin` there at all (ENOENT, not a
# controlled nonzero exit) — that would make the negative control vacuously
# "pass" via a spawn error instead of actually exercising "resolves fine but
# can't source". On win32 the stand-in is therefore a COPY of Git for
# Windows' own coreutils false.exe — a real PE binary that ignores every
# argument and always exits 1 — never a script; on posix a plain shebang
# script (exec-able directly there) is exactly the "always fails" bash a
# sabotage stub needs to be.
sabotage_bash_dir="$work/sabotage-bash-bin"; mkdir -p "$sabotage_bash_dir"
if is_win32; then
  sabotage_bash="$sabotage_bash_dir/bash.exe"
  false_exe="$(command -v false.exe || true)"
  [ -n "$false_exe" ] || fail "HIMMEL-2289 setup: no false.exe on PATH — the win32 sabotage-bash stand-in needs a real PE binary that always exits nonzero (Git for Windows ships one at /usr/bin/false.exe)"
  cp "$false_exe" "$sabotage_bash"
else
  sabotage_bash="$sabotage_bash_dir/bash"
  cat > "$sabotage_bash" <<'STUB'
#!/usr/bin/env bash
exit 127
STUB
fi
chmod +x "$sabotage_bash"
sabotage_path="$sabotage_bash_dir:$PATH"

# handover-wiring (handover-dir), reusing hd_present_dir from the happy-path
# case above (same repoRoot/targetPath shape).
outHWreg=$(PATH="$sabotage_path" HIMMELCTL_BASH="$real_bash_w" HANDOVER_DIR="$(winpath "$hd_present_dir")" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'handover-wiring');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHWreg" | jq -e '.actual == "present"' >/dev/null \
  || fail "HIMMEL-2289 regression: handover-wiring should read present via HIMMELCTL_BASH despite a sabotage 'bash' shadowing PATH (got: $outHWreg)"
echo "ok: HIMMEL-2289 regression — handover-wiring reads present via HIMMELCTL_BASH even with a WSL-launcher-shaped sabotage bash first on PATH"

outHWnc=$(HIMMELCTL_BASH="$(winpath "$sabotage_bash")" HANDOVER_DIR="$(winpath "$hd_present_dir")" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'handover-wiring');
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHWnc" | jq -e '.actual != "present"' >/dev/null \
  || fail "HIMMEL-2289 negative control: handover-wiring must NOT read present when HIMMELCTL_BASH is pinned at the sabotage stub (got: $outHWnc)"
echo "ok: HIMMEL-2289 negative control — handover-wiring does NOT read present when HIMMELCTL_BASH points at the sabotage stub (proves the positive case is not vacuous)"

# hermes-lanes (cmd:has_hermes), reusing hh_repo_present from the happy-path
# case above.
outHLreg=$(PATH="$sabotage_path" HIMMELCTL_BASH="$real_bash_w" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'hermes-lanes');
const ctx = { repoRoot: '$(winpath "$hh_repo_present")', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHLreg" | jq -e '.actual == "present"' >/dev/null \
  || fail "HIMMEL-2289 regression: hermes-lanes should read present via HIMMELCTL_BASH despite a sabotage 'bash' shadowing PATH (got: $outHLreg)"
echo "ok: HIMMEL-2289 regression — hermes-lanes (cmd:has_hermes) reads present via HIMMELCTL_BASH even with a WSL-launcher-shaped sabotage bash first on PATH"

outHLnc=$(HIMMELCTL_BASH="$(winpath "$sabotage_bash")" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'hermes-lanes');
const ctx = { repoRoot: '$(winpath "$hh_repo_present")', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHLnc" | jq -e '.actual != "present"' >/dev/null \
  || fail "HIMMEL-2289 negative control: hermes-lanes must NOT read present when HIMMELCTL_BASH is pinned at the sabotage stub (got: $outHLnc)"
echo "ok: HIMMEL-2289 negative control — hermes-lanes does NOT read present when HIMMELCTL_BASH points at the sabotage stub"

# doc-guard-map (cmd:is_himmel_dev), reusing idh_present from the happy-path
# case above.
outDGreg=$(PATH="$sabotage_path" HIMMELCTL_BASH="$real_bash_w" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'doc-guard-map');
const ctx = { repoRoot: '$(winpath "$idh_present")', targetPath: '$(winpath "$idh_present")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outDGreg" | jq -e '.actual == "present"' >/dev/null \
  || fail "HIMMEL-2289 regression: doc-guard-map should read present via HIMMELCTL_BASH despite a sabotage 'bash' shadowing PATH (got: $outDGreg)"
echo "ok: HIMMEL-2289 regression — doc-guard-map (cmd:is_himmel_dev) reads present via HIMMELCTL_BASH even with a WSL-launcher-shaped sabotage bash first on PATH"

outDGnc=$(HIMMELCTL_BASH="$(winpath "$sabotage_bash")" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'doc-guard-map');
const ctx = { repoRoot: '$(winpath "$idh_present")', targetPath: '$(winpath "$idh_present")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outDGnc" | jq -e '.actual != "present"' >/dev/null \
  || fail "HIMMEL-2289 negative control: doc-guard-map must NOT read present when HIMMELCTL_BASH is pinned at the sabotage stub (got: $outDGnc)"
echo "ok: HIMMEL-2289 negative control — doc-guard-map does NOT read present when HIMMELCTL_BASH points at the sabotage stub"

# ── HIMMEL-2289: toolchain bash row (probeBashDep — dep item cmd:'bash') ────
# The manifest carries no dep/bash item — probeDep() only routes to
# probeBashDep() when item.probe.cmd === 'bash' (probes.js) — so the item is
# constructed inline, mirroring this file's established inline-item idiom
# (engine-allowlist-fixture above).
outBDhealthy=$(HIMMELCTL_BASH="$real_bash_w" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'bash', probe: { type: 'dep', cmd: 'bash' } };
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outBDhealthy" | jq -e '.actual == "present"' >/dev/null \
  || fail "toolchain bash (probeBashDep) present (HIMMELCTL_BASH = real bash, repo root carries scripts/guardrails/lib.sh): (got: $outBDhealthy)"
echo "$outBDhealthy" | jq -e --arg b "$real_bash_w" '.detail == $b' >/dev/null \
  || fail "toolchain bash present detail should be the resolved bash path (got: $outBDhealthy, expected: $real_bash_w)"
echo "ok: toolchain bash (probeBashDep) reads present with the resolved bash path as detail when it can source scripts/guardrails/lib.sh"

# Non-vacuous: the resolved bash EXISTS (which() would have called this
# 'ok bash ready') but can't source the proof file — the exact false-green
# the operator hit (a present-but-broken WSL bash.exe), reproduced here with
# a stub that always exits nonzero regardless of what it's asked to run.
outBDstub=$(HIMMELCTL_BASH="$(winpath "$sabotage_bash")" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'bash', probe: { type: 'dep', cmd: 'bash' } };
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outBDstub" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "toolchain bash (probeBashDep) degraded (HIMMELCTL_BASH resolves but cannot source scripts/guardrails/lib.sh — the exact false-\"ok bash ready\" class this probe exists to catch): (got: $outBDstub)"
echo "$outBDstub" | jq -e '.detail | contains("cannot source")' >/dev/null \
  || fail "toolchain bash non-vacuous detail should name the sourcing failure (got: $outBDstub)"
echo "ok: toolchain bash (probeBashDep) reads degraded, naming 'cannot source', when the resolved bash exists but can't source scripts/guardrails/lib.sh — proves presence alone is not enablement"

# Unresolvable: HIMMELCTL_BASH pinned to a nonexistent path, PATH scrubbed
# too. resolveProbeBash() trusts a set HIMMELCTL_BASH unconditionally (it
# never existsSync-checks it), so this does NOT hit probeBashDep's own
# '!bash -> no usable bash found' branch — it is spawnSync's own ENOENT on
# the bogus path that produces r.error, read here via probeBashDep's
# spawn-error branch (confirmed against probes.js, not assumed).
outBDunresolv=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'bash', probe: { type: 'dep', cmd: 'bash' } };
const ctx = { repoRoot: '$repo_root_w', targetPath: '$repo_root_w', scope: 'user', env: { PATH: '', HIMMELCTL_BASH: '$no_such_bash_w' } };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outBDunresolv" | jq -e '.actual == "absent"' >/dev/null \
  || fail "toolchain bash (probeBashDep) absent (HIMMELCTL_BASH pinned nonexistent, PATH scrubbed): (got: $outBDunresolv)"
echo "$outBDunresolv" | jq -e '.detail | contains("spawn error")' >/dev/null \
  || fail "toolchain bash unresolvable detail should name the spawn error (got: $outBDunresolv)"
echo "ok: toolchain bash (probeBashDep) reads absent naming 'spawn error' when HIMMELCTL_BASH is pinned nonexistent"

# Proof file absent: a checkout that predates scripts/guardrails/lib.sh (or a
# stripped fixture) must not read the interpreter itself as broken.
bd_no_proof="$work/bd-no-proof"; mkdir -p "$bd_no_proof"
outBDnoproof=$(HIMMELCTL_BASH="$real_bash_w" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const item = { id: 'bash', probe: { type: 'dep', cmd: 'bash' } };
const ctx = { repoRoot: '$(winpath "$bd_no_proof")', targetPath: '$(winpath "$bd_no_proof")', scope: 'user', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outBDnoproof" | jq -e '.actual == "present"' >/dev/null \
  || fail "toolchain bash (probeBashDep) present (repoRoot carries no scripts/guardrails/lib.sh — presence-only skip): (got: $outBDnoproof)"
echo "$outBDnoproof" | jq -e '.detail | contains("presence only")' >/dev/null \
  || fail "toolchain bash presence-only detail should name the skip (got: $outBDnoproof)"
echo "ok: toolchain bash (probeBashDep) reads present with a 'presence only' detail when the checkout carries no scripts/guardrails/lib.sh to prove against — a missing repo file is not a statement about the interpreter"

# ── HIMMEL-2298: the probe spawn budget is a FAMILY default, not a per-probe
# constant. HIMMEL-2289 measured that a probe launching a process on Windows
# legitimately occupies 8-18s and raised ONE probe (cadence-coherence) from the
# 10s default to 60s — leaving its 14 siblings at 10s. The operator's next
# wizard run then hit the SAME false DEGRADED one probe over: "handover state —
# DEGRADED, timed out after 10s" on a healthy host (measured here at 3.5-8.1s
# even IDLE, i.e. a 20% margin, which ~4 concurrent sessions erase). The budget
# now lives on spawnProbeSync/spawnBashProbe as PROBE_TIMEOUT_MS, so a probe
# cannot be left behind on the old one. ────────────────────────────────────
#
# The budget is exercised through HIMMELCTL_PROBE_TIMEOUT_SECS rather than by
# sleeping past the real 60s default — a suite that waits a minute to prove one
# number is its own defect (CR [codex-1] on this ticket). The override is the
# same env-seam class as HIMMELCTL_BASH and the sibling of install-engine's
# INSTALL_TIMEOUT_SECS, so this drives the SHIPPED code path, not a test-only
# branch. The 60s default itself is pinned structurally further down, where
# asserting it costs nothing. Real bash, real resolver-sourcing path: none of
# the win32 shebang-exec caveats from the 2289 cases apply here.
#
# Case 1 — a resolver slower than the budget reads degraded, and the message
# reports the budget ACTUALLY applied (2s here, not a hardcoded figure). That
# second assertion is the drift half of this ticket: before it, every probe
# said "10s" no matter what budget it ran under.
hd_slow_repo="$work/hd-slow-resolver"; mkdir -p "$hd_slow_repo/scripts/lib"
hd_slow_root="$work/hd-slow-root"; mkdir -p "$hd_slow_root"
cat > "$hd_slow_repo/scripts/lib/handover-path.sh" <<SLOWHD
sleep 4
handover_root() { printf '%s\n' '$(winpath "$hd_slow_root")'; }
SLOWHD
outHDover=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'handover-wiring');
const env = Object.assign({}, process.env, { HIMMELCTL_PROBE_TIMEOUT_SECS: '2' });
const ctx = { repoRoot: '$(winpath "$hd_slow_repo")', targetPath: '$(winpath "$hd_slow_repo")', scope: 'project', env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHDover" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "HIMMEL-2298: a resolver slower than the configured budget must read degraded (got: $outHDover)"
echo "$outHDover" | jq -e '.detail | contains("timed out after 2s")' >/dev/null \
  || fail "HIMMEL-2298: the timeout message must report the budget ACTUALLY applied (2s via HIMMELCTL_PROBE_TIMEOUT_SECS), never a hardcoded figure — that drift is what put the wrong number in the operator's bug report (got: $outHDover)"
echo "ok: HIMMEL-2298 — the spawn budget is honoured end-to-end and the timeout message reports the budget actually applied, not a hardcoded one"

# Case 2 — the SAME 4s resolver under the shipped default reads present, with
# no timeout reported. Deliberately NOT called the regression proof (CR round 4
# [codex-2], agreed): 4s clears the old 10s default too on an idle box, so this
# case does not by itself demonstrate the reported failure — it pins the
# complement of case 1 (a probe inside its budget must come back clean, and
# must not acquire a timeout row from the budget plumbing).
#
# The old-vs-new proof is case 1 plus the 60s pin below: case 1 shows a
# resolver slower than its budget producing exactly the operator's false
# DEGRADED, and the pin shows the shipped budget is now 60s rather than the 10s
# that probe legitimately exceeded. The direct measurement against shipped main
# (degraded "timed out after 10s" at 10016ms, vs present at 12080ms on this
# branch, same fixture) is recorded in the PR body — a 12s sleep in the suite
# to re-derive it every run was the round-1 finding.
outHDunder=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'handover-wiring');
const ctx = { repoRoot: '$(winpath "$hd_slow_repo")', targetPath: '$(winpath "$hd_slow_repo")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHDunder" | jq -e '.actual == "present"' >/dev/null \
  || fail "HIMMEL-2298: a resolver well inside the shipped family budget must read present, never a timed-out degraded (got: $outHDunder)"
echo "$outHDunder" | jq -e '.detail | contains("timed out") | not' >/dev/null \
  || fail "HIMMEL-2298: a resolver well inside the budget must not report a timeout at all (got: $outHDunder)"
echo "ok: HIMMEL-2298 — a resolver inside the shipped family budget reads present with no timeout row (the complement of the over-budget case above)"

# CR round 2 [codex-1]: a sub-millisecond override must NOT disable the guard.
# `secs > 0` accepted 0.0004, which rounds to 0 ms — and Node reads timeout:0
# as NO TIMEOUT, so the probe would run unbounded while looking configured.
# The 4s resolver must therefore still be bounded by the DEFAULT budget (it
# completes, reading present) rather than silently losing its hang guard.
outHDsubms=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'handover-wiring');
const env = Object.assign({}, process.env, { HIMMELCTL_PROBE_TIMEOUT_SECS: '0.0004' });
const ctx = { repoRoot: '$(winpath "$hd_slow_repo")', targetPath: '$(winpath "$hd_slow_repo")', scope: 'project', env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHDsubms" | jq -e '.actual == "present"' >/dev/null \
  || fail "HIMMEL-2298 CR[codex-1]: a sub-millisecond HIMMELCTL_PROBE_TIMEOUT_SECS must fall back to the default budget, not round to 0ms (which Node reads as NO timeout, disabling the hang guard) (got: $outHDsubms)"
echo "ok: HIMMEL-2298 CR[codex-1] — a sub-millisecond budget override falls back to the default instead of rounding to 0ms and disabling the hang guard"

# CR round 3 [codex-1]: the other end of the same class. A huge-but-finite
# override overflows `secs * 1000` to Infinity, which passed the round-2
# `ms >= 1` check and reached spawnSync as an out-of-range timeout. Both ends
# now take the one safe-integer predicate, so the probe still runs (and, here,
# completes) instead of throwing.
outHDhuge=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'handover-wiring');
const env = Object.assign({}, process.env, { HIMMELCTL_PROBE_TIMEOUT_SECS: '1e308' });
const ctx = { repoRoot: '$(winpath "$hd_slow_repo")', targetPath: '$(winpath "$hd_slow_repo")', scope: 'project', env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHDhuge" | jq -e '.actual == "present"' >/dev/null \
  || fail "HIMMEL-2298 CR round 3 [codex-1]: a huge-but-finite HIMMELCTL_PROBE_TIMEOUT_SECS must fall back to the default budget, not overflow to Infinity and reach spawnSync as an out-of-range timeout (got: $outHDhuge)"
echo "ok: HIMMEL-2298 CR[codex-1 r3] — a huge-but-finite budget override falls back to the default instead of overflowing to Infinity"

# CR round 2 [codex-2]: a fractional budget must be reported accurately. This
# ticket exists because a timeout message disagreed with its budget; reporting
# 1.5s as "2s" is the same defect in miniature.
outHDfrac=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'handover-wiring');
const env = Object.assign({}, process.env, { HIMMELCTL_PROBE_TIMEOUT_SECS: '1.5' });
const ctx = { repoRoot: '$(winpath "$hd_slow_repo")', targetPath: '$(winpath "$hd_slow_repo")', scope: 'project', env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHDfrac" | jq -e '.actual == "degraded"' >/dev/null \
  || fail "HIMMEL-2298 CR[codex-2]: a 1.5s budget against a 4s resolver must read degraded (got: $outHDfrac)"
echo "$outHDfrac" | jq -e '.detail | contains("timed out after 1.5s")' >/dev/null \
  || fail "HIMMEL-2298 CR[codex-2]: a fractional budget must be reported exactly (1.5s), never rounded to a figure that disagrees with the budget actually applied (got: $outHDfrac)"
echo "ok: HIMMEL-2298 CR[codex-2] — a fractional budget is reported exactly, never rounded into disagreement with itself"

# Negative control: the SAME harness, but handover_root itself fails. Proves
# case 2 is not passing vacuously — if the probe read present regardless of
# what the resolver did, this would read present too.
hd_slow_fail_repo="$work/hd-slow-resolver-fail"; mkdir -p "$hd_slow_fail_repo/scripts/lib"
cat > "$hd_slow_fail_repo/scripts/lib/handover-path.sh" <<'SLOWHDFAIL'
handover_root() { return 1; }
SLOWHDFAIL
outHDslowNc=$("$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const item = manifest.items.find((i) => i.id === 'handover-wiring');
const ctx = { repoRoot: '$(winpath "$hd_slow_fail_repo")', targetPath: '$(winpath "$hd_slow_fail_repo")', scope: 'project', env: process.env };
console.log(JSON.stringify(runProbe(item, ctx)));
")
echo "$outHDslowNc" | jq -e '.actual != "present"' >/dev/null \
  || fail "HIMMEL-2298 negative control: handover-dir must NOT read present when handover_root itself fails (got: $outHDslowNc)"
echo "ok: HIMMEL-2298 negative control — handover-dir does NOT read present when the resolver's handover_root fails (proves the regression case is not vacuous)"

# ── HIMMEL-2298 family invariants (structural — these are what stop a THIRD
# report of this same sibling-branch defect). Both are textual assertions over
# probes.js, so a probe added later cannot quietly opt out of the budget.
probes_src="$repo_root/scripts/himmelctl/lib/probes.js"

# (1) EVERY process-spawning probe routes through the shared helper. Exactly
# one spawnSync call may exist in the file, and it must be the one inside
# spawnProbeSync — that is what makes PROBE_TIMEOUT_MS a family default rather
# than a value 15 call sites each have to remember. A new probe calling
# spawnSync directly would get NO budget at all (the shape configuredHooksPath
# carried until this ticket: a wedged git blocked `status` indefinitely).
spawnsync_count=$(grep -c 'spawnSync(' "$probes_src")
[ "$spawnsync_count" -eq 1 ] \
  || fail "HIMMEL-2298: probes.js must contain exactly ONE spawnSync( call (the one inside spawnProbeSync, which applies PROBE_TIMEOUT_MS + SIGKILL to the whole family); found $spawnsync_count — a new spawn site is bypassing the shared budget"
awk '/^function spawnProbeSync/,/^}/' "$probes_src" | grep -q 'spawnSync(' \
  || fail "HIMMEL-2298: the single spawnSync( call is no longer inside spawnProbeSync — the family budget is not being applied"
echo "ok: HIMMEL-2298 family invariant — every process-spawning probe routes through spawnProbeSync, so PROBE_TIMEOUT_MS applies to all of them"

# (1b) The shipped DEFAULT is 60s. The functional cases above drive the budget
# through HIMMELCTL_PROBE_TIMEOUT_SECS so they cost seconds instead of a
# minute, which means nothing there pins the number an operator actually gets —
# this does, for free. 10s was the value that manufactured false DEGRADED rows
# on healthy Windows hosts twice (HIMMEL-2289, HIMMEL-2298); dropping back
# under ~20s reopens that.
grep -q 'const PROBE_TIMEOUT_MS = 60000;' "$probes_src" \
  || fail "HIMMEL-2298: the shipped family budget must remain 60s (const PROBE_TIMEOUT_MS = 60000) — the functional cases drive an override for speed and cannot pin the default an operator gets"
echo "ok: HIMMEL-2298 family invariant — the shipped default budget is pinned at 60s"

# (2) No probe hardcodes a stale budget in its own timeout message. The 15
# "timed out after 10s" strings that survived 2289's one-probe raise are
# exactly how a reader (and the operator's bug report) learns the wrong number;
# details now interpolate the budget the result was actually run under.
! grep -q 'timed out after 10s' "$probes_src" \
  || fail "HIMMEL-2298: probes.js still hardcodes 'timed out after 10s' — a timeout message must report the budget actually applied (probeTimeoutSecs(r)), or it drifts the moment the budget changes"
echo "ok: HIMMEL-2298 family invariant — no probe hardcodes a timeout figure; every message reports the budget actually applied"

# ── purity: full sweep over every manifest item, fixture tree byte-identical ─
purity_root="$work/purity-repo"
mkdir -p "$purity_root/scripts/jira/dist" "$purity_root/scripts/bitbucket/dist" \
  "$purity_root/scripts/guardrails" "$purity_root/scripts/lanes" "$purity_root/scripts/telegram" \
  "$purity_root/scripts/graphify" "$purity_root/scripts/lib" "$purity_root/handovers" "$purity_root/.claude"
: > "$purity_root/scripts/jira/dist/index.js"
: > "$purity_root/scripts/bitbucket/dist/index.js"
: > "$purity_root/scripts/guardrails/lib.sh"
: > "$purity_root/scripts/lanes/lanes.json"
: > "$purity_root/scripts/telegram/telegram-api.ts"
: > "$purity_root/scripts/graphify/check-graph-freshness.sh"
: > "$purity_root/scripts/lib/doc-guard-map.sh"
: > "$purity_root/.pre-commit-config.yaml"
cat > "$purity_root/.env" <<'ENV'
JIRA_BASE_URL=https://example.atlassian.net
JIRA_EMAIL=me@example.com
JIRA_API_TOKEN=tok123
JIRA_PROJECT_KEY=HIMMEL
ENV
cat > "$purity_root/.claude/settings.json" <<'JSON'
{"statusLine":{"command":"bash foo.sh"},"enabledPlugins":{"foo@bar":true},
 "hooks":{"PreToolUse":[
   {"matcher":"Bash","hooks":[{"type":"command","command":"bash \"/x/scripts/hooks/auto-approve-safe-bash.sh\""}]},
   {"matcher":"Edit","hooks":[{"type":"command","command":"bash \"/x/scripts/hooks/block-edit-on-main.sh\""}]},
   {"matcher":"Read","hooks":[{"type":"command","command":"bash \"/x/scripts/hooks/block-read-secrets.sh\""}]}
 ]}}
JSON
purity_vault="$work/purity-vault"; mkdir -p "$purity_vault"
: > "$purity_vault/.vault-template.json"

purity_before=$(snapshot_dir "$purity_root")
purity_vault_before=$(snapshot_dir "$purity_vault")

# HIMMEL-2176 Task 7: cadence-coherence/phi-coherence read the adopter's
# shared config document via luna-config.js's OWN HIMMEL_LUNA_CONFIG_PATH
# seam (not ctx.env — see that module's header) — pointed at a path under
# $work that is never created, so load() takes its safe defaultConfig()
# fallback rather than the sweep silently reading the REAL
# ~/.himmel/config.json.
sweepOut=$(HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/purity-luna-config.json")" "$node_bin" -e "
const { runProbe } = require('$probes_lib_w');
const manifest = JSON.parse(require('fs').readFileSync('$manifest_w', 'utf8'));
const repoRoot = '$(winpath "$purity_root")';
const targetPath = '$(winpath "$purity_root")';
const vaultPath = '$(winpath "$purity_vault")';
const results = [];
for (const item of manifest.items) {
  const scope = item.scopes.includes('project') ? 'project' : 'user';
  const tp = item.id === 'luna-vault-scaffold' ? vaultPath : targetPath;
  const ctx = { repoRoot, targetPath: tp, scope, env: process.env };
  results.push(Object.assign({ id: item.id }, runProbe(item, ctx)));
}
console.log(JSON.stringify(results));
")

purity_after=$(snapshot_dir "$purity_root")
purity_vault_after=$(snapshot_dir "$purity_vault")

[ "$purity_before" = "$purity_after" ] || fail "purity: fixture repo/target tree was mutated by the probe sweep"
[ "$purity_vault_before" = "$purity_vault_after" ] || fail "purity: fixture vault tree was mutated by the probe sweep"

sweepCount=$(echo "$sweepOut" | jq 'length')
manifestCount=$(jq '.items | length' "$manifest_path")
[ "$sweepCount" -eq "$manifestCount" ] || fail "purity: expected $manifestCount probe results (one per manifest item), got $sweepCount"
echo "ok: purity — full probe sweep over all $manifestCount manifest items left every fixture tree byte-identical"

echo "PASS"
