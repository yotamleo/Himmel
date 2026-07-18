#!/usr/bin/env bash
# test-wizard-config.sh — hermetic tests for the himmelctl `config` subcommand
# (HIMMEL-758, epic HIMMEL-755 sub-ticket D). Mirrors test-wizard-uninstall.sh/
# test-wizard-derive.sh conventions: node launched by absolute path, a fake
# HOME, HIMMELCTL_REPO_ROOT pointed at a throwaway fixture carrying real copies
# of the primitive scripts config shells out to (set-env-var.sh,
# set-lane-override.mjs, lanes.json) so nothing ever touches the real repo's
# .env / scripts/lanes/lanes.json / scripts/lanes/lanes.local.json.
#
# Non-interactive path only (the brief's own scoping: "Keep the interactive
# TUI thin so most logic is exercised via the setters") — the interactive TUI
# is a thin caller over the exact same functions these cases exercise via
# `config set`/`config get`.
#
# Covers:
#   A. initiative.<leg> — set on/off toggles HIMMEL_INITIATIVE in the fixture
#      .env; multiple legs coexist; unknown leg -> rc=2, no write.
#   B. initiative get (whole + single leg).
#   C. lanes.<id> — set on/off writes ONLY lanes.local.json (probe.kind
#      always/never); the fixture's lanes.json (repo-registry stand-in) is
#      NEVER modified; unknown id -> rc=2.
#   D. lanes get (whole + single id, override vs no-override).
#   E. --dry-run — set initiative AND set lanes write NOTHING (no .env, no
#      lanes.local.json).
#   F. hooks.improveOnSubmit — advisory only: prints the manual instructions,
#      writes nothing (no .env mutation at all).
#   G. hooks.plugin.<name> — stubbed `claude` on PATH: on/off invoke
#      `claude plugin enable/disable <name>`; --dry-run invokes nothing;
#      unknown plugin name -> rc=2.
#   H. value validation — anything other than on/off -> rc=2 for every
#      surface; an unknown top-level path -> rc=2.
#   I. interactive with closed stdin (`config` with no args, `</dev/null`)
#      quits immediately (rc=0), never hangs.
#   J. the lanes overlay MERGE itself (resolve.mjs's mergeLocalOverlay wired
#      into loadRegistry()): base lanes.json + a local override -> the
#      overridden lane is force-on/off in the RESOLVED set, every other lane
#      unaffected, and the base lanes.json fixture file is byte-unchanged.
#   K. Windows robustness (HIMMEL-758): a native BACKSLASH HIMMELCTL_REPO_ROOT
#      (cygpath -w) still resolves the initiative set write to the INTENDED
#      fixture .env, not a misresolved sibling. Git-Bash/MSYS/Cygwin only —
#      self-skips on posix (no backslash separator).

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
wizard="$repo_root/scripts/himmelctl/bin.js"
resolve_mjs="$repo_root/scripts/lanes/resolve.mjs"
probe_mjs="$repo_root/scripts/lanes/probe.mjs"
[ -f "$wizard" ] || { echo "FAIL: $wizard not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

node_bin=$(command -v node)

# shellcheck source=lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$repo_root/scripts/lib/hermetic-path.sh"

work=$(mktemp -d)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# winpath <path> — echo <path> unchanged on posix, or its Windows form on
# git-bash/MSYS/Cygwin (node.exe misresolves MSYS /tmp-style paths).
winpath() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) cygpath -m "$1" 2>/dev/null || printf '%s' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

# build_fixture <dir> — a throwaway HIMMELCTL_REPO_ROOT target carrying REAL
# copies of the primitives `config` shells out to, so a live run against the
# fixture exercises the actual write logic without ever touching the real
# repo's own .env / scripts/lanes/*.json.
build_fixture() {
  local _d="$1"
  mkdir -p "$_d/scripts/lib" "$_d/scripts/lanes"
  cp "$repo_root/scripts/lib/set-env-var.sh" "$_d/scripts/lib/set-env-var.sh"
  cp "$repo_root/scripts/lanes/set-lane-override.mjs" "$_d/scripts/lanes/set-lane-override.mjs"
  cp "$repo_root/scripts/lanes/lanes.json" "$_d/scripts/lanes/lanes.json"
}

run_cfg() {
  # run_cfg <fixture> [args...] — invoke `himmelctl config <args...>` against
  # <fixture> with a fake HOME, capturing combined stdout+stderr and rc into
  # the caller's own `out`/`rc` locals via `local -n`-free convention (bash
  # 3.2-safe: assign globals `CFG_OUT`/`CFG_RC` instead of nameref).
  local _fixture="$1"; shift
  local _h="$work/home-$$-$RANDOM"; mkdir -p "$_h"
  set +e
  CFG_OUT=$(HOME="$_h" HIMMELCTL_REPO_ROOT="$(winpath "$_fixture")" \
    "$node_bin" "$wizard" config "$@" 2>&1)
  CFG_RC=$?
  set -e
}

# ── Case A: initiative.<leg> set on/off ─────────────────────────────────────
fxA="$work/fixtureA"; build_fixture "$fxA"
run_cfg "$fxA" set initiative.execute on
[ "$CFG_RC" -eq 0 ] || fail "caseA: set initiative.execute on should exit 0 (got rc=$CFG_RC): $CFG_OUT"
printf '%s' "$CFG_OUT" | grep -qF 'HIMMEL_INITIATIVE -> execute' \
  || fail "caseA: expected confirmation line (got: $CFG_OUT)"
grep -qE '^HIMMEL_INITIATIVE=execute$' "$fxA/.env" \
  || fail "caseA: fixture .env should carry HIMMEL_INITIATIVE=execute (got: $(cat "$fxA/.env" 2>&1))"
run_cfg "$fxA" set initiative.pr on
grep -qE '^HIMMEL_INITIATIVE=execute,pr$' "$fxA/.env" \
  || fail "caseA: a second leg should APPEND, not replace (got: $(cat "$fxA/.env" 2>&1))"
run_cfg "$fxA" set initiative.execute off
grep -qE '^HIMMEL_INITIATIVE=pr$' "$fxA/.env" \
  || fail "caseA: toggling execute off should remove ONLY execute (got: $(cat "$fxA/.env" 2>&1))"
run_cfg "$fxA" set initiative.bogus on
[ "$CFG_RC" -eq 2 ] || fail "caseA: unknown leg should exit 2 (got rc=$CFG_RC): $CFG_OUT"
printf '%s' "$CFG_OUT" | grep -qF 'unknown initiative leg' \
  || fail "caseA: expected 'unknown initiative leg' message (got: $CFG_OUT)"
grep -qE '^HIMMEL_INITIATIVE=pr$' "$fxA/.env" \
  || fail "caseA: an unknown-leg rejection must not touch the .env (got: $(cat "$fxA/.env" 2>&1))"
echo "ok: caseA initiative.<leg> set on/off toggles HIMMEL_INITIATIVE; unknown leg rejected without a write"

# ── Case B: initiative get ──────────────────────────────────────────────────
run_cfg "$fxA" get initiative
[ "$CFG_RC" -eq 0 ] || fail "caseB: get initiative should exit 0 (got rc=$CFG_RC): $CFG_OUT"
printf '%s' "$CFG_OUT" | grep -qF 'active legs: pr' \
  || fail "caseB: expected 'active legs: pr' (got: $CFG_OUT)"
run_cfg "$fxA" get initiative.pr
printf '%s' "$CFG_OUT" | grep -qF 'initiative.pr: on' \
  || fail "caseB: expected 'initiative.pr: on' (got: $CFG_OUT)"
run_cfg "$fxA" get initiative.execute
printf '%s' "$CFG_OUT" | grep -qF 'initiative.execute: off' \
  || fail "caseB: expected 'initiative.execute: off' (got: $CFG_OUT)"
echo "ok: caseB initiative get (whole + single leg) reports the persisted .env state"

# ── Case C: lanes.<id> set on/off — lanes.local.json only, lanes.json untouched ─
fxC="$work/fixtureC"; build_fixture "$fxC"
lanes_json_before=$(cat "$fxC/scripts/lanes/lanes.json")
run_cfg "$fxC" set lanes.haiku off
[ "$CFG_RC" -eq 0 ] || fail "caseC: set lanes.haiku off should exit 0 (got rc=$CFG_RC): $CFG_OUT"
[ -f "$fxC/scripts/lanes/lanes.local.json" ] \
  || fail "caseC: expected lanes.local.json to be created (out: $CFG_OUT)"
grep -qF '"kind": "never"' "$fxC/scripts/lanes/lanes.local.json" \
  || fail "caseC: expected probe.kind=never for haiku (got: $(cat "$fxC/scripts/lanes/lanes.local.json"))"
lanes_json_after=$(cat "$fxC/scripts/lanes/lanes.json")
[ "$lanes_json_before" = "$lanes_json_after" ] \
  || fail "caseC: scripts/lanes/lanes.json must NEVER be modified by config set lanes.*"
run_cfg "$fxC" set lanes.sonnet on
grep -qF '"kind": "always"' "$fxC/scripts/lanes/lanes.local.json" \
  || fail "caseC: expected probe.kind=always for sonnet (got: $(cat "$fxC/scripts/lanes/lanes.local.json"))"
grep -qF '"id": "haiku"' "$fxC/scripts/lanes/lanes.local.json" \
  || fail "caseC: a second lane's override must not drop the first (got: $(cat "$fxC/scripts/lanes/lanes.local.json"))"
run_cfg "$fxC" set lanes.bogus-lane on
[ "$CFG_RC" -eq 2 ] || fail "caseC: unknown lane id should exit 2 (got rc=$CFG_RC): $CFG_OUT"
printf '%s' "$CFG_OUT" | grep -qF 'unknown lane id' \
  || fail "caseC: expected 'unknown lane id' message (got: $CFG_OUT)"
echo "ok: caseC lanes.<id> set on/off writes ONLY lanes.local.json (repo lanes.json byte-unchanged); unknown id rejected"

# ── Case D: lanes get ────────────────────────────────────────────────────────
run_cfg "$fxC" get lanes.haiku
printf '%s' "$CFG_OUT" | grep -qF 'probe.kind=never' \
  || fail "caseD: expected haiku override to report probe.kind=never (got: $CFG_OUT)"
run_cfg "$fxC" get lanes.opus
printf '%s' "$CFG_OUT" | grep -qF 'no override' \
  || fail "caseD: opus has no override -- expected 'no override' (got: $CFG_OUT)"
run_cfg "$fxC" get lanes
printf '%s' "$CFG_OUT" | grep -qF '"id": "sonnet"' \
  || fail "caseD: whole-namespace get should print the full overlay file (got: $CFG_OUT)"
echo "ok: caseD lanes get (whole + single id) distinguishes override vs no-override"

# ── Case E: --dry-run writes NOTHING (initiative AND lanes) ────────────────
fxE="$work/fixtureE"; build_fixture "$fxE"
run_cfg "$fxE" set initiative.execute on --dry-run
[ "$CFG_RC" -eq 0 ] || fail "caseE: dry-run initiative set should exit 0 (got rc=$CFG_RC): $CFG_OUT"
printf '%s' "$CFG_OUT" | grep -qF 'DRY:' \
  || fail "caseE: expected a DRY: preview line (got: $CFG_OUT)"
[ -f "$fxE/.env" ] \
  && fail "caseE: --dry-run must not create/write the fixture .env (got: $(cat "$fxE/.env" 2>&1))"
run_cfg "$fxE" set lanes.haiku off --dry-run
[ "$CFG_RC" -eq 0 ] || fail "caseE: dry-run lanes set should exit 0 (got rc=$CFG_RC): $CFG_OUT"
[ -f "$fxE/scripts/lanes/lanes.local.json" ] \
  && fail "caseE: --dry-run must not create lanes.local.json (got: $(cat "$fxE/scripts/lanes/lanes.local.json" 2>&1))"
echo "ok: caseE --dry-run makes ZERO writes for both initiative and lanes surfaces"

# ── Case L: a global flag BEFORE `config` still routes to config ─────────────
# Regression: main() used to dispatch on argv[0] only, so `--dry-run config …`
# (flag ahead of the subcommand — the order-independent form every other
# subcommand accepts) fell through to parseArgs and died "unknown argument:
# config". main() now detects `config` as the first non-flag token.
fxL="$work/fixtureL"; build_fixture "$fxL"
_hL="$work/home-L-$$-$RANDOM"; mkdir -p "$_hL"
set +e
outL=$(HOME="$_hL" HIMMELCTL_REPO_ROOT="$(winpath "$fxL")" \
  "$node_bin" "$wizard" --dry-run config set initiative.execute on 2>&1)
rcL=$?
set -e
[ "$rcL" -eq 0 ] || fail "caseL: '--dry-run config set …' should exit 0 (got rc=$rcL): $outL"
printf '%s' "$outL" | grep -qF 'DRY:' \
  || fail "caseL: leading --dry-run must reach config AND be honored — expected a DRY: line (got: $outL)"
[ -f "$fxL/.env" ] \
  && fail "caseL: --dry-run before config must not write the fixture .env (got: $(cat "$fxL/.env" 2>&1))"
echo "ok: caseL a global flag before 'config' (--dry-run config set …) routes to config and is honored"

# ── Case M: an option VALUE equal to 'config' must NOT route to config ───────
# Regression (CodeRabbit): the leading-flag scan must skip only arity-0
# --dry-run, NOT value-taking flags. `himmelctl --items config status` is the
# `status` subcommand with --items=config; the value 'config' must never be
# mistaken for the config subcommand. If it misroutes to cmdConfig, cmdConfig
# rejects the stray '--items' as `config: unknown argument` — assert that
# symptom is absent (i.e. it reached status, which validates --items itself).
fxM="$work/fixtureM"; build_fixture "$fxM"
_hM="$work/home-M-$$-$RANDOM"; mkdir -p "$_hM"
set +e
outM=$(HOME="$_hM" HIMMELCTL_REPO_ROOT="$(winpath "$fxM")" \
  "$node_bin" "$wizard" --items config status 2>&1)
set -e
printf '%s' "$outM" | grep -qF 'config: unknown argument' \
  && fail "caseM: '--items config status' misrouted to cmdConfig (got: $outM)"
printf '%s' "$outM" | grep -qF 'what would you like to configure' \
  && fail "caseM: '--items config status' wrongly entered the config TUI (got: $outM)"
echo "ok: caseM an --items VALUE of 'config' routes to status, never the config subcommand"

# ── Case F: hooks.improveOnSubmit — not settable/readable via config (rc 2) ──
# CodeRabbit (Major): a `set` that changes nothing must NOT report success, and
# `get` must not return instructions in place of a value. improveOnSubmit is a
# launching-shell-only env var config cannot persist or read, so both reject
# with rc 2 while still printing the how-to guidance.
fxF="$work/fixtureF"; build_fixture "$fxF"
run_cfg "$fxF" set hooks.improveOnSubmit on
[ "$CFG_RC" -eq 2 ] || fail "caseF: set hooks.improveOnSubmit must exit 2 (no-op write), got rc=$CFG_RC: $CFG_OUT"
printf '%s' "$CFG_OUT" | grep -qF 'not settable via config' \
  || fail "caseF: expected the 'not settable via config' rejection (got: $CFG_OUT)"
printf '%s' "$CFG_OUT" | grep -qF 'export IMPROVE_ON_SUBMIT=1' \
  || fail "caseF: expected the manual enable instruction (got: $CFG_OUT)"
[ -f "$fxF/.env" ] \
  && fail "caseF: hooks.improveOnSubmit must NEVER write the fixture .env (got: $(cat "$fxF/.env" 2>&1))"
run_cfg "$fxF" set hooks.improveOnSubmit off
[ "$CFG_RC" -eq 2 ] || fail "caseF: set hooks.improveOnSubmit off must exit 2, got rc=$CFG_RC: $CFG_OUT"
printf '%s' "$CFG_OUT" | grep -qF 'unset IMPROVE_ON_SUBMIT' \
  || fail "caseF: expected the manual disable instruction (got: $CFG_OUT)"
run_cfg "$fxF" get hooks.improveOnSubmit
[ "$CFG_RC" -eq 2 ] || fail "caseF: get hooks.improveOnSubmit must exit 2 (not a readable value), got rc=$CFG_RC: $CFG_OUT"
printf '%s' "$CFG_OUT" | grep -qF 'does not report hook state' \
  || fail "caseF: get hooks.* must reject with the 'no hook state' message (got: $CFG_OUT)"
run_cfg "$fxF" get hooks
[ "$CFG_RC" -eq 2 ] || fail "caseF: get hooks (whole) must exit 2, got rc=$CFG_RC: $CFG_OUT"
echo "ok: caseF hooks.improveOnSubmit set/get reject with rc 2 (no-op write / unreadable), guidance still printed"

# ── Case G: hooks.plugin.<name> — stubbed claude CLI ────────────────────────
stubG="$work/stubG"; mkdir -p "$stubG"
callsG="$work/plugin-calls.log"
cat > "$stubG/claude" <<STUB
#!/usr/bin/env bash
printf 'claude: %s\n' "\$*" >> "$callsG"
exit 0
STUB
chmod +x "$stubG/claude"
fxG="$work/fixtureG"; build_fixture "$fxG"
_hG="$work/homeG"; mkdir -p "$_hG"
_pathG="$stubG:$PATH"
set +e
outG=$(PATH="$_pathG" HOME="$_hG" HIMMELCTL_REPO_ROOT="$(winpath "$fxG")" \
  "$node_bin" "$wizard" config set hooks.plugin.github on 2>&1); rcG=$?
set -e
[ "$rcG" -eq 0 ] || fail "caseG: hooks.plugin.github on should exit 0 (got rc=$rcG): $outG"
[ -f "$callsG" ] || fail "caseG: expected claude to be invoked (out: $outG)"
grep -qF 'claude: plugin enable github' "$callsG" \
  || fail "caseG: expected 'plugin enable github' (got: $(cat "$callsG"))"
: > "$callsG"
set +e
outG=$(PATH="$_pathG" HOME="$_hG" HIMMELCTL_REPO_ROOT="$(winpath "$fxG")" \
  "$node_bin" "$wizard" config set hooks.plugin.github off 2>&1); rcG=$?
set -e
[ "$rcG" -eq 0 ] || fail "caseG: hooks.plugin.github off should exit 0 (got rc=$rcG): $outG"
grep -qF 'claude: plugin disable github' "$callsG" \
  || fail "caseG: expected 'plugin disable github' (got: $(cat "$callsG"))"
: > "$callsG"
set +e
outG=$(PATH="$_pathG" HOME="$_hG" HIMMELCTL_REPO_ROOT="$(winpath "$fxG")" \
  "$node_bin" "$wizard" config set hooks.plugin.github on --dry-run 2>&1); rcG=$?
set -e
[ "$rcG" -eq 0 ] || fail "caseG: dry-run hooks.plugin should exit 0 (got rc=$rcG): $outG"
[ -s "$callsG" ] \
  && fail "caseG: --dry-run must NOT invoke claude (got: $(cat "$callsG"))"
run_cfg "$fxG" set hooks.plugin.bogus-plugin on
[ "$CFG_RC" -eq 2 ] || fail "caseG: unknown plugin name should exit 2 (got rc=$CFG_RC): $CFG_OUT"
echo "ok: caseG hooks.plugin.<name> invokes 'claude plugin enable/disable <name>'; --dry-run invokes nothing; unknown name rejected"

# ── Case H: value/path validation ───────────────────────────────────────────
run_cfg "$fxA" set initiative.execute maybe
[ "$CFG_RC" -eq 2 ] || fail "caseH: non on/off value should exit 2 (got rc=$CFG_RC): $CFG_OUT"
printf '%s' "$CFG_OUT" | grep -qF "must be 'on' or 'off'" \
  || fail "caseH: expected the on/off validation message (got: $CFG_OUT)"
run_cfg "$fxA" set bogus.path on
[ "$CFG_RC" -eq 2 ] || fail "caseH: unknown top-level path should exit 2 (got rc=$CFG_RC): $CFG_OUT"
run_cfg "$fxA" get bogus.path
[ "$CFG_RC" -eq 2 ] || fail "caseH: unknown top-level get path should exit 2 (got rc=$CFG_RC): $CFG_OUT"
echo "ok: caseH invalid value / unknown path both rejected with rc=2"

# ── Case I: interactive, closed stdin -> quits immediately, never hangs ────
set +e
outI=$(HOME="$work/homeI" HIMMELCTL_REPO_ROOT="$(winpath "$fxA")" \
  "$node_bin" "$wizard" config </dev/null 2>&1); rcI=$?
set -e
[ "$rcI" -eq 0 ] || fail "caseI: closed-stdin interactive config should exit 0 (got rc=$rcI): $outI"
printf '%s' "$outI" | grep -qF 'what would you like to configure' \
  || fail "caseI: expected the top-level menu prompt (got: $outI)"
echo "ok: caseI interactive config with closed stdin quits immediately (rc=0), never hangs"

# ── Case J: the lanes overlay MERGE itself (resolve.mjs) ───────────────────
# An ISOLATED copy of resolve.mjs+probe.mjs+lanes.json (never the real repo's
# scripts/lanes/) so the merge behavior is proven independent of `config`'s
# own writer (case C already proved the writer never touches lanes.json;
# this proves the READ side actually applies the override).
fxJ="$work/fixtureJ"; mkdir -p "$fxJ"
cp "$resolve_mjs" "$fxJ/resolve.mjs"
cp "$probe_mjs" "$fxJ/probe.mjs"
cat > "$fxJ/lanes.json" <<'JSON'
{ "lanes": [
  { "id": "always-on", "label": "AlwaysOn", "class": "test", "probe": { "kind": "always" } },
  { "id": "other", "label": "Other", "class": "test", "probe": { "kind": "always" } }
] }
JSON
lanes_before=$(cat "$fxJ/lanes.json")
cat > "$fxJ/lanes.local.json" <<'JSON'
{ "lanes": [ { "id": "always-on", "probe": { "kind": "never" } } ] }
JSON
set +e
outJ=$("$node_bin" "$fxJ/resolve.mjs" --json 2>&1); rcJ=$?
set -e
[ "$rcJ" -eq 0 ] || fail "caseJ: resolve.mjs --json should exit 0 (got rc=$rcJ): $outJ"
printf '%s' "$outJ" | grep -q '"id": "other"' \
  || fail "caseJ: the un-overridden lane should still resolve (got: $outJ)"
printf '%s' "$outJ" | grep -q '"id": "always-on"' \
  && fail "caseJ: the never-overridden lane must NOT resolve despite its base probe being 'always' (got: $outJ)"
lanes_after=$(cat "$fxJ/lanes.json")
[ "$lanes_before" = "$lanes_after" ] \
  || fail "caseJ: resolve.mjs must never modify the base lanes.json"
echo "ok: caseJ lanes.local.json overlay (base + local, local wins) actually suppresses the overridden lane in resolve.mjs; base lanes.json unchanged"

# ── Case K: native BACKSLASH HIMMELCTL_REPO_ROOT still hits the intended .env ─
# Regression guard for HIMMEL-758: writeEnvVar passes its --env-file target to
# bash in forward-slice form (toBashPath) because Git-Bash can misresolve a
# backslashed/drive-letter path to the wrong file. Force a NATIVE Windows path
# (cygpath -w — the form path.join also emits on Windows node) as
# HIMMELCTL_REPO_ROOT and confirm the write lands in the INTENDED fixture .env,
# not a misresolved sibling. Git-Bash/MSYS/Cygwin only: posix has no backslash
# separator, so the case self-skips there.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    fxK="$work/fixtureK"; build_fixture "$fxK"
    winroot=$(cygpath -w "$fxK" 2>/dev/null || printf '%s' "$fxK")
    case "$winroot" in
      *\\*)
        _hK="$work/homeK"; mkdir -p "$_hK"
        set +e
        outK=$(HOME="$_hK" HIMMELCTL_REPO_ROOT="$winroot" \
          "$node_bin" "$wizard" config set initiative.execute on 2>&1); rcK=$?
        set -e
        [ "$rcK" -eq 0 ] || fail "caseK: backslash-root set should exit 0 (got rc=$rcK): $outK"
        [ -f "$fxK/.env" ] \
          || fail "caseK: the INTENDED fixture .env must exist after the write (out: $outK)"
        grep -qE '^HIMMEL_INITIATIVE=execute$' "$fxK/.env" \
          || fail "caseK: write must land in the intended fixture .env even under a backslash repoRoot (got: $(cat "$fxK/.env" 2>&1))"
        echo "ok: caseK a native backslash HIMMELCTL_REPO_ROOT still resolves the .env write to the intended fixture (Git-Bash)"
        ;;
      *)
        echo "ok: caseK skipped — cygpath emitted no backslashes (non-drive-letter tmp), nothing to prove"
        ;;
    esac
    ;;
  *)
    echo "ok: caseK skipped on posix (no backslash path separator)"
    ;;
esac

# ── Case N: an unreadable .env aborts, never silently drops tokens ───────────
# CodeRabbit (Major, data integrity): readEnvVarFile treated EVERY read error
# as '' (unset), so config set would derive a replacement from an empty base
# and DROP existing HIMMEL_INITIATIVE tokens. Only ENOENT means unset now; any
# other read error aborts before any write. Simulated by making .env a
# DIRECTORY — readFileSync then throws EISDIR (same non-ENOENT code path as the
# EACCES the finding named), portably on both posix and git-bash.
fxN="$work/fixtureN"; build_fixture "$fxN"
mkdir "$fxN/.env"
run_cfg "$fxN" set initiative.ticket on
[ "$CFG_RC" -ne 0 ] \
  || fail "caseN: an unreadable .env must abort (non-zero), not treat it as unset (got rc=$CFG_RC): $CFG_OUT"
printf '%s' "$CFG_OUT" | grep -qiE 'EISDIR|EACCES' \
  || fail "caseN: expected the underlying read error to surface (got: $CFG_OUT)"
echo "ok: caseN a non-ENOENT .env read error aborts before any write (no silent token drop)"

# ── Case O: a malformed lanes overlay aborts, never reports empty/crashes ────
# CodeRabbit (Minor, stability): readLanesLocal turned invalid JSON into
# {lanes:[]} (masking corruption), while valid-but-wrong-shape JSON (null,
# {"lanes":{}}) crashed at `.lanes.find`. Now ENOENT -> {lanes:[]}; bad JSON or
# a non-array `lanes` aborts with a clear message.
fxO="$work/fixtureO"; build_fixture "$fxO"
printf '%s' '{"lanes":{}}' > "$fxO/scripts/lanes/lanes.local.json"
run_cfg "$fxO" get lanes.haiku
[ "$CFG_RC" -ne 0 ] \
  || fail "caseO: a wrong-shape lanes overlay must abort, not report empty (got rc=$CFG_RC): $CFG_OUT"
printf '%s' "$CFG_OUT" | grep -qF 'malformed lanes overlay' \
  || fail "caseO: expected the 'malformed lanes overlay' message (got: $CFG_OUT)"
printf 'not json' > "$fxO/scripts/lanes/lanes.local.json"
run_cfg "$fxO" get lanes.haiku
[ "$CFG_RC" -ne 0 ] \
  || fail "caseO: invalid-JSON lanes overlay must abort, not be silently empty (got rc=$CFG_RC): $CFG_OUT"
echo "ok: caseO a malformed lanes overlay (bad JSON or wrong shape) aborts instead of reporting empty/crashing"

echo "PASS"
