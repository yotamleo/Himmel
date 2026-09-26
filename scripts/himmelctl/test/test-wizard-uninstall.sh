#!/usr/bin/env bash
# test-wizard-uninstall.sh — hermetic tests for the himmelctl `uninstall`
# subcommand (HIMMEL-887, §5.5 locked decision). Mirrors
# test-wizard-derive.sh conventions: a stub PATH via scripts/lib/hermetic-path.sh,
# a fake HOME, node launched by absolute path, HIMMELCTL_REPO_ROOT pointed at a
# throwaway fixture carrying no-op uninstall.sh/uninstall.ps1 stubs so a real
# uninstall (killing the telegram bridge, removing scheduled tasks, uninstalling
# plugins/hooks, unwiring ~/.claude/settings.json) is never triggered against
# the real machine. The flag-assertion case is the one that deliberately reads
# the REAL uninstall.sh/uninstall.ps1.
#
# Covers:
#   A. flag-assertion guard: uninstall.sh's --help / uninstall.ps1's usage
#      comment both still document the --yes/-Yes flag the wizard always
#      derives (script-flag drift guard).
#   B. --dry-run -> prints the derived plan (the platform-appropriate
#      launcher + --yes/-Yes) without asking or executing anything.
#   C. piped "n" without --yes -> the uninstall script is NOT invoked,
#      rc=2, non-interactive fail-closed refusal (HIMMEL-2755).
#   D. explicit --yes with closed stdin -> the uninstall script IS invoked
#      with --yes/-Yes; this tests forwarding, not the interactive prompt.
#   E. non-interactive, closed stdin without --yes -> rc=2 fail-closed
#      refusal, not a human decline; the uninstall script is NEVER run.

set -euo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

repo_root=$(git rev-parse --show-toplevel)
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"  # HIMMEL-2350: shared winpath() -- dies loud on empty input/output instead of silently falling through to the operator's real home
wizard="$repo_root/scripts/himmelctl/bin.js"
[ -f "$wizard" ] || { echo "FAIL: $wizard not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

node_bin=$(command -v node)

# shellcheck source=lib/hermetic-path.sh
# shellcheck disable=SC1091
. "$repo_root/scripts/lib/hermetic-path.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/wiz-uninst.XXXXXX") || exit 1
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# HIMMEL-1446 r2 (glm-1): cmdUninstall now removes PATH launchers from binDir.
# Isolate binDir for the WHOLE suite so an accept-case never touches the
# operator's real ~/.local/bin (on win32 himmelctlBinDir() ignores HOME and
# would otherwise resolve to the real home). A per-case inline HIMMELCTL_BIN_DIR
# still overrides this (see caseF). winpath'd so win32 node resolves it cleanly.
HIMMELCTL_BIN_DIR="$(winpath "$work/isolated-bin")"
export HIMMELCTL_BIN_DIR

# build_path <stub_dir> <present_tools...> -- <absent_tools...>
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

# is_win32 — true iff the platform branch bin.js's deriveUninstallCommand()
# will take is the powershell one (mirrors test-wizard-derive.sh's caseE
# platform switch).
is_win32() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

# build_fixture <dir> — a throwaway HIMMELCTL_REPO_ROOT target: no-op
# uninstall.sh/uninstall.ps1 stubs, each logging its argv to
# <dir>/uninstall-calls.log, PLUS a minimal scripts/install/manifest.json
# (HIMMEL-755 sub-ticket E: cmdUninstall now loadManifest()s + partitions by
# `offboard` before asking/executing — without this file that load throws
# and every case below would fail closed on an unrelated ENOENT).
build_fixture() {
  local _d="$1"
  mkdir -p "$_d/scripts/install"
  cat > "$_d/scripts/uninstall.sh" <<STUB
#!/usr/bin/env bash
printf 'uninstall.sh: %s HIMMEL_UNINSTALL_REAL_HOME=%s\n' "\$*" "\${HIMMEL_UNINSTALL_REAL_HOME:-unset}" >> "$_d/uninstall-calls.log"
exit 0
STUB
  chmod +x "$_d/scripts/uninstall.sh"
  # PowerShell is a native Windows process — it needs the Windows-form path
  # (winpath), not the MSYS /tmp-style path bash sees for the same file.
  local _dw; _dw="$(winpath "$_d")"
  cat > "$_d/scripts/uninstall.ps1" <<STUB
param([switch]\$Yes,[switch]\$DryRun)
Add-Content -Path '$_dw/uninstall-calls.log' -Value "uninstall.ps1: Yes=\$Yes DryRun=\$DryRun"
exit 0
STUB
  cat > "$_d/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    { "id": "fixture-unwire", "kind": "wiring", "scopes": ["project"], "profiles": ["core", "all"], "deps": [], "probe": { "type": "file-exists", "path": "untracked.marker" }, "removable": "full-offboard-only" },
    { "id": "fixture-advise", "kind": "dep", "scopes": ["user"], "profiles": ["core", "all"], "deps": [], "probe": { "type": "dep", "cmd": "node" }, "removable": "full-offboard-only", "offboard": "advise" },
    { "id": "fixture-keep", "kind": "vault", "scopes": ["user"], "profiles": ["luna", "all"], "deps": [], "probe": { "type": "file-exists", "path": "{vaultPath}/.marker" }, "removable": "full-offboard-only", "offboard": "keep" }
  ]
}
JSON
}

# ── Case A: flag-assertion guard — script-flag drift ───────────────────────
sh_help=$(bash "$repo_root/scripts/uninstall.sh" --help 2>&1)
grepq "$sh_help" -F -- '--yes' \
  || fail "flag-assertion: uninstall.sh --help is missing derivable flag '--yes' (script-flag drift)"
ps1_usage=$(head -n 20 "$repo_root/scripts/uninstall.ps1")
grepq "$ps1_usage" -F -- '-Yes' \
  || fail "flag-assertion: uninstall.ps1's usage comment is missing derivable flag '-Yes' (script-flag drift)"
echo "ok: caseA flag-assertion guard -- uninstall.sh/uninstall.ps1 usage surfaces carry the --yes/-Yes flag the wizard always derives"

# ── Case B: --dry-run -> prints the plan, asks/executes nothing ────────────
# HIMMEL-2126: win32 launches uninstall.ps1 through resolvePowershell(), which
# now PREFERS pwsh over PowerShell 5.1 — so pwsh is scrubbed from PATH here
# (this box's own pwsh must not leak in) to pin the loud-fallback branch;
# caseB2 below covers the pwsh-preferred branch with pwsh injected instead.
stubB="$work/caseB"; mkdir -p "$stubB"
cB=$(build_path "$stubB" bash git jq python3 npm -- pwsh)
hB="$work/hB"; mkdir -p "$hB"
fixtureB="$work/caseB-fixture"; build_fixture "$fixtureB"
set +e
out=$(PATH="$cB" HOME="$hB" USERPROFILE="$(winpath "$hB")" HIMMELCTL_CACHE_DIR="$(winpath "$hB.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hB.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureB")" \
      "$node_bin" "$wizard" uninstall --dry-run \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseB: dry-run should exit 0 (got rc=$rc): $out"
if is_win32; then
  grepq "$out" -iE 'derived:.*powershell' \
    || fail "caseB(win32): expected a PowerShell 5.1 fallback (pwsh scrubbed) (got: $out)"
  grepq "$out" -F -- '-ExecutionPolicy Bypass -File' \
    || fail "caseB(win32): expected -ExecutionPolicy Bypass -File (got: $out)"
  grepq "$out" -F -- 'uninstall.ps1 -DryRun' \
    || fail "caseB(win32): expected uninstall.ps1 -DryRun (got: $out)"
  grepq "$out" -F -- 'uninstall.ps1 -Yes' \
    && fail "caseB(win32): --dry-run must NOT derive -Yes (got: $out)"
else
  grepq "$out" -E 'derived:.*bash .*uninstall\.sh --dry-run$' \
    || fail "caseB(posix): expected 'bash .../uninstall.sh --dry-run' (got: $out)"
fi
grepq "$out" 'Proceed?' \
  && fail "caseB: --dry-run must NOT show the confirm prompt (got: $out)"
# HIMMEL-3058: --dry-run RUNS the executor in its own dry-run mode (the plan it
# prints is the script's, not a second copy) — never with --yes/-Yes, and
# never with HIMMEL_UNINSTALL_REAL_HOME (the wet-run fence's only opt-in).
[ -f "$fixtureB/uninstall-calls.log" ] \
  || fail "caseB: --dry-run must run the executor in dry-run mode (no call log)"
callsB=$(cat "$fixtureB/uninstall-calls.log")
if is_win32; then
  grepq "$callsB" -F -- 'DryRun=True' \
    || fail "caseB(win32): the executor must see -DryRun (got: $callsB)"
  grepq "$callsB" -F -- 'Yes=True' \
    && fail "caseB(win32): the executor must NOT see -Yes on a dry-run (got: $callsB)"
else
  grepq "$callsB" -F -- 'uninstall.sh: --dry-run HIMMEL_UNINSTALL_REAL_HOME=unset' \
    || fail "caseB(posix): expected exactly '--dry-run' with the real-home fence unset (got: $callsB)"
fi
echo "ok: caseB --dry-run -> derived plan printed, executor run with --dry-run only, nothing asked, HIMMEL_UNINSTALL_REAL_HOME never set"

# ── Case B2 (HIMMEL-2126): --dry-run on win32 prefers pwsh when it is
# resolvable — a stub pwsh is injected onto PATH (posix is a no-op: caseB
# already covers it, and there is no pwsh/powershell branch there).
if is_win32; then
  stubB2="$work/caseB2"; mkdir -p "$stubB2"
  cB2=$(build_path "$stubB2" bash git jq python3 npm pwsh -- )
  hB2="$work/hB2"; mkdir -p "$hB2"
  fixtureB2="$work/caseB2-fixture"; build_fixture "$fixtureB2"
  set +e
  outB2=$(PATH="$cB2" HOME="$hB2" USERPROFILE="$(winpath "$hB2")" HIMMELCTL_CACHE_DIR="$(winpath "$hB2.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hB2.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
        HIMMELCTL_REPO_ROOT="$(winpath "$fixtureB2")" \
        "$node_bin" "$wizard" uninstall --dry-run \
        </dev/null 2>&1); rcB2=$?
  set -e
  [ "$rcB2" -eq 0 ] || fail "caseB2: dry-run should exit 0 (got rc=$rcB2): $outB2"
  grepq "$outB2" -F -- 'pwsh' \
    || fail "caseB2(win32): expected pwsh to be preferred when resolvable (got: $outB2)"
  grepq "$outB2" -F -- '-ExecutionPolicy Bypass -File' \
    || fail "caseB2(win32): expected -ExecutionPolicy Bypass -File (got: $outB2)"
  grepq "$outB2" -F -- 'uninstall.ps1 -DryRun' \
    || fail "caseB2(win32): expected uninstall.ps1 -DryRun (got: $outB2)"
  echo "ok: caseB2 win32 -> pwsh preferred over PowerShell 5.1 when resolvable"
else
  echo "ok: caseB2 -> (skipped: posix has no pwsh/powershell branch, covered by caseB)"
fi

# ── Case C: piped n without --yes -> uninstall NOT invoked ───────────
stubC="$work/caseC"; mkdir -p "$stubC"
cC=$(build_path "$stubC" bash git jq python3 npm -- )
hC="$work/hC"; mkdir -p "$hC"
fixtureC="$work/caseC-fixture"; build_fixture "$fixtureC"
set +e
out=$(PATH="$cC" HOME="$hC" USERPROFILE="$(winpath "$hC")" HIMMELCTL_CACHE_DIR="$(winpath "$hC.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hC.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=1 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureC")" \
      "$node_bin" "$wizard" uninstall \
      <<<"n" 2>&1); rc=$?
set -e
[ "$rc" -eq 2 ] || fail "caseC: piped n without --yes should refuse with rc=2 (got rc=$rc): $out"
grepq "$out" 'Proceed?' \
  && fail "caseC: non-interactive input must NOT show the confirm prompt (got: $out)"
grepq "$out" -F 'non-interactive run without --yes — aborting (fail-closed)' \
  || fail "caseC: expected the fail-closed refusal message (got: $out)"
grepq "$out" -F 'declined; nothing run' \
  && fail "caseC: piped n must NOT be reported as a human decline (got: $out)"
[ -f "$fixtureC/uninstall-calls.log" ] \
  && fail "caseC: piped n must NOT invoke uninstall.sh/uninstall.ps1 (got: $(cat "$fixtureC/uninstall-calls.log"))"
echo "ok: caseC piped n without --yes -> uninstall script not invoked, rc=2"

# ── Case D: explicit --yes accept (closed stdin) -> uninstall invoked ──
stubD="$work/caseD"; mkdir -p "$stubD"
cD=$(build_path "$stubD" bash git jq python3 npm -- )
hD="$work/hD"; mkdir -p "$hD"
fixtureD="$work/caseD-fixture"; build_fixture "$fixtureD"
set +e
out=$(PATH="$cD" HOME="$hD" USERPROFILE="$(winpath "$hD")" HIMMELCTL_CACHE_DIR="$(winpath "$hD.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hD.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=1 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureD")" \
      "$node_bin" "$wizard" uninstall --yes \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseD: accept should exit 0 (got rc=$rc): $out"
[ -f "$fixtureD/uninstall-calls.log" ] \
  || fail "caseD: an explicit --yes accept should invoke uninstall.sh/uninstall.ps1 (out: $out)"
if is_win32; then
  grep -q 'Yes=True' "$fixtureD/uninstall-calls.log" \
    || fail "caseD(win32): expected uninstall.ps1 to be called with -Yes (got: $(cat "$fixtureD/uninstall-calls.log"))"
else
  grep -q -- '--yes' "$fixtureD/uninstall-calls.log" \
    || fail "caseD(posix): expected uninstall.sh to be called with --yes (got: $(cat "$fixtureD/uninstall-calls.log"))"
  # HIMMEL-2505: this confirmed WET spawn must pass HIMMEL_UNINSTALL_REAL_HOME=1
  # so uninstall.sh's own live-operator-HOME fence doesn't refuse the machine
  # the operator just confirmed offboarding.
  grep -q 'HIMMEL_UNINSTALL_REAL_HOME=1' "$fixtureD/uninstall-calls.log" \
    || fail "caseD(posix): expected HIMMEL_UNINSTALL_REAL_HOME=1 in the child env (got: $(cat "$fixtureD/uninstall-calls.log"))"
fi
echo "ok: caseD explicit --yes accept (closed stdin) -> uninstall script invoked with --yes/-Yes, HIMMEL_UNINSTALL_REAL_HOME=1"

# ── Case E: closed stdin (no answer) -> refuses with rc=2, never runs unattended ─
stubE="$work/caseE"; mkdir -p "$stubE"
cE=$(build_path "$stubE" bash git jq python3 npm -- )
hE="$work/hE"; mkdir -p "$hE"
fixtureE="$work/caseE-fixture"; build_fixture "$fixtureE"
set +e
out=$(PATH="$cE" HOME="$hE" USERPROFILE="$(winpath "$hE")" HIMMELCTL_CACHE_DIR="$(winpath "$hE.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hE.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureE")" \
      "$node_bin" "$wizard" uninstall \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 2 ] || fail "caseE: closed stdin without --yes should refuse with rc=2 (got rc=$rc): $out"
grepq "$out" -F 'non-interactive run without --yes — aborting (fail-closed)' \
  || fail "caseE: expected the fail-closed refusal message on EOF (got: $out)"
grepq "$out" -F 'declined; nothing run' \
  && fail "caseE: EOF must NOT be reported as a human decline (got: $out)"
[ -f "$fixtureE/uninstall-calls.log" ] \
  && fail "caseE: a closed stdin (no explicit answer) must NEVER run uninstall unattended (got: $(cat "$fixtureE/uninstall-calls.log"))"
echo "ok: caseE closed stdin (no answer) -> refuses with rc=2, uninstall never runs unattended"

# ── Case F: uninstall removes marked PATH launchers, leaves unmarked files ──
# HIMMEL-1446 r2 (glm-1): cmdUninstall now removes the PATH launchers that
# install/update wrote into binDir, but ONLY those carrying the ownership
# marker — an unmarked third-party file at a known launcher name is left
# byte-untouched. Inline HIMMELCTL_BIN_DIR points at a planted bin (overrides
# the suite-global isolation).
stubF="$work/caseF"; mkdir -p "$stubF"
cF=$(build_path "$stubF" bash git jq python3 npm -- )
hF="$work/hF"; mkdir -p "$hF"
fixtureF="$work/caseF-fixture"; build_fixture "$fixtureF"
binF="$work/caseF-bin"; mkdir -p "$binF"
# MARKED posix launcher + MARKED loader -> both removed.
cat > "$binF/himmelctl" <<'STUB'
#!/usr/bin/env sh
# generated by himmelctl (HIMMEL-1446)
exec node "/x/himmelctl.js" "$@"
STUB
cat > "$binF/himmelctl.js" <<'STUB'
'use strict';
// generated by himmelctl (HIMMEL-1446)
require('/x/himmelctl.js');
STUB
# UNMARKED third-party file at a known launcher name -> left untouched.
printf 'third-party\n' > "$binF/himmelctl.cmd"
set +e
out=$(PATH="$cF" HOME="$hF" USERPROFILE="$(winpath "$hF")" HIMMELCTL_CACHE_DIR="$(winpath "$hF.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hF.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=1 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureF")" \
      HIMMELCTL_BIN_DIR="$(winpath "$binF")" \
      "$node_bin" "$wizard" uninstall --yes \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseF: accept should exit 0 (got rc=$rc): $out"
[ -f "$fixtureF/uninstall-calls.log" ] \
  || fail "caseF: an explicit --yes accept should invoke the uninstall script (out: $out)"
[ ! -e "$binF/himmelctl" ] || fail "caseF: marked himmelctl launcher should be removed"
[ ! -e "$binF/himmelctl.js" ] || fail "caseF: marked himmelctl.js loader should be removed"
[ -f "$binF/himmelctl.cmd" ] || fail "caseF: unmarked himmelctl.cmd must NOT be removed"
[ "$(cat "$binF/himmelctl.cmd")" = 'third-party' ] || fail "caseF: unmarked himmelctl.cmd was mutated"
echo "ok: caseF uninstall removes marked PATH launchers, leaves unmarked files untouched"

# ── Case G: a FAILED teardown preserves the launchers (HIMMEL-1446 r4, Fix 1) ──
# removeHimmelctlLaunchers() now runs ONLY when rc===0, so a failed teardown
# (stub exits nonzero) must leave the marked launchers in place for the retry
# and print a retry warning naming the failure. Regression for the converged
# codex-1/codex-adv blocker — a failed uninstall must not strand the machine
# with no working `himmelctl`. Mirrors caseF's launcher plant + bin isolation.
stubG="$work/caseG"; mkdir -p "$stubG"
cG=$(build_path "$stubG" bash git jq python3 npm -- )
hG="$work/hG"; mkdir -p "$hG"
fixtureG="$work/caseG-fixture"; build_fixture "$fixtureG"
# Overwrite the platform-appropriate teardown stub to FAIL (exit 1) instead of
# build_fixture's default exit 0 — keep the call log so we can still prove it ran.
if is_win32; then
  cat > "$fixtureG/scripts/uninstall.ps1" <<STUB
param([switch]\$Yes,[switch]\$DryRun)
Add-Content -Path '$(winpath "$fixtureG")/uninstall-calls.log' -Value "uninstall.ps1: Yes=\$Yes DryRun=\$DryRun FAIL"
exit 1
STUB
else
  cat > "$fixtureG/scripts/uninstall.sh" <<STUB
#!/usr/bin/env bash
printf 'uninstall.sh FAIL: %s\n' "\$*" >> "$fixtureG/uninstall-calls.log"
exit 1
STUB
  chmod +x "$fixtureG/scripts/uninstall.sh"
fi
binG="$work/caseG-bin"; mkdir -p "$binG"
# MARKED launchers present — must survive the failed teardown (retry needs them).
cat > "$binG/himmelctl.js" <<'STUB'
'use strict';
// generated by himmelctl (HIMMEL-1446)
require('/x/himmelctl.js');
STUB
cat > "$binG/himmelctl" <<'STUB'
#!/usr/bin/env sh
# generated by himmelctl (HIMMEL-1446)
exec node "/x/himmelctl.js" "$@"
STUB
set +e
out=$(PATH="$cG" HOME="$hG" USERPROFILE="$(winpath "$hG")" HIMMELCTL_CACHE_DIR="$(winpath "$hG.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hG.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=1 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureG")" \
      HIMMELCTL_BIN_DIR="$(winpath "$binG")" \
      "$node_bin" "$wizard" uninstall --yes \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "caseG: a failed teardown must propagate nonzero rc (got rc=$rc): $out"
[ -f "$fixtureG/uninstall-calls.log" ] \
  || fail "caseG: the teardown stub should still have been invoked (out: $out)"
[ -f "$binG/himmelctl.js" ] || fail "caseG: a failed teardown must NOT remove the marked loader (it strands the machine with no himmelctl for the retry)"
[ -f "$binG/himmelctl" ] || fail "caseG: a failed teardown must NOT remove the marked launcher"
grepq "$out" 'launchers left in place' || fail "caseG: expected a retry warning preserving the launchers (got: $out)"
echo "ok: caseG failed teardown preserves marked PATH launchers + warns (no stranded machine)"

# ── Case H (HIMMEL-3244): the banner's operator-state claim is DERIVED from the
# manifest classes, the same per-row way uninstall.sh's step-2 plan is. A
# hand-edited manifest that re-classes a telegram row keep must not be
# described as "--purge-state removes it". posix only: uninstall.ps1 keeps its
# own targets and does not read the manifest, so win32 keeps the shipped text.
# banner_for <case> <purge:0|1> <sed-expr|""> — runs `uninstall --dry-run` against a
# fixture whose uninstall-manifest.tsv is the REAL one with <sed-expr> applied
# (empty = unedited; "none" = no manifest file at all) and prints the banner.
banner_for() {
  local _c="$1" _purge="$2" _sed="$3" _fx="$work/caseH-$1-fixture" _h
  _h=$(mktemp -d "$work/hH.XXXXXX") || exit 1
  build_fixture "$_fx"
  if [ "$_sed" != none ]; then
    if [ -n "$_sed" ]; then sed -e "$_sed" "$repo_root/scripts/install/uninstall-manifest.tsv" > "$_fx/scripts/install/uninstall-manifest.tsv"
    else cp "$repo_root/scripts/install/uninstall-manifest.tsv" "$_fx/scripts/install/uninstall-manifest.tsv"; fi
  fi
  local _stub="$work/caseH-$1-stub"; mkdir -p "$_stub"
  local _p; _p=$(build_path "$_stub" bash git jq python3 npm -- )
  local _args=(uninstall --dry-run); [ "$_purge" = 1 ] && _args+=(--purge-state)
  PATH="$_p" HOME="$_h" USERPROFILE="$(winpath "$_h")" HIMMELCTL_CACHE_DIR="$(winpath "$_h.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$_h.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
    HIMMELCTL_REPO_ROOT="$(winpath "$_fx")" \
    "$node_bin" "$wizard" "${_args[@]}" </dev/null 2>&1
}
if ! is_win32; then
  KEEP_CH=$'s/^telegram-channel\tstate/telegram-channel\tkeep/'
  # H1: channel re-classed keep, no --purge-state -> named keep, never "removes it".
  outH1=$(banner_for h1 0 "$KEEP_CH")
  grepq "$outH1" -F 'telegram pairing (telegram-channel): KEPT (manifest class keep)' \
    || fail "caseH1: a keep-classed telegram-channel must be named KEPT by class (got: $outH1)"
  grepq "$outH1" -F 'bridge state (telegram-bridge): KEPT (manifest class state; --purge-state removes it)' \
    || fail "caseH1: the state-classed bridge row must say --purge-state removes it (got: $outH1)"
  grepq "$outH1" -F 'is KEPT — pass --purge-state to remove it' \
    && fail "caseH1: the blanket 'pass --purge-state to remove it' claim must not survive a keep row (got: $outH1)"
  # H2: same manifest WITH --purge-state -> the keep row is still kept, never "REMOVED too".
  outH2=$(banner_for h2 1 "$KEEP_CH")
  grepq "$outH2" -F 'telegram pairing (telegram-channel): KEPT (manifest class keep)' \
    || fail "caseH2: --purge-state must not claim a keep row is removed (got: $outH2)"
  grepq "$outH2" -F 'bridge state (telegram-bridge): REMOVED (--purge-state)' \
    || fail "caseH2: the state row IS removed by --purge-state (got: $outH2)"
  grepq "$outH2" -F 'is REMOVED too' \
    && fail "caseH2: the blanket 'REMOVED too' claim must not survive a keep row (got: $outH2)"
  # H3: a code-classed row is removed with or without --purge-state.
  outH3=$(banner_for h3 0 $'s/^telegram-bridge\tstate/telegram-bridge\tcode/')
  grepq "$outH3" -F 'bridge state (telegram-bridge): REMOVED (manifest class code)' \
    || fail "caseH3: a code-classed row is always removed (got: $outH3)"
  # H4: the shipped manifest (both state) keeps the original two banner lines.
  outH4=$(banner_for h4 0 "")
  grepq "$outH4" -F 'operator state (telegram pairing, bridge state) is KEPT — pass --purge-state to remove it.' \
    || fail "caseH4: shipped default banner (no purge) changed (got: $outH4)"
  outH4p=$(banner_for h4p 1 "")
  grepq "$outH4p" -F -- '--purge-state: operator state (telegram pairing, bridge state) is REMOVED too.' \
    || fail "caseH4: shipped default banner (--purge-state) changed (got: $outH4p)"
  # H5: no readable manifest -> no per-class claim, points at the plan instead.
  outH5=$(banner_for h5 1 none)
  grepq "$outH5" -F 'see the plan uninstall.sh prints' \
    || fail "caseH5: an unreadable manifest must defer to the uninstall.sh plan (got: $outH5)"
  grepq "$outH5" -F 'is REMOVED too' \
    && fail "caseH5: an unreadable manifest must not produce a removal claim (got: $outH5)"
  echo "ok: caseH banner derives per-row telegram state from the manifest classes (keep/code/state/unreadable)"
else
  echo "ok: caseH -> (skipped: uninstall.ps1 does not read the manifest; win32 keeps the shipped banner)"
fi

# ── Case I (HIMMEL-3589): qmd ids in the dry-run advisory plan carry a
# resolved path + on-disk size. manifest.json's real qmd-binary defaults to
# offboard 'advise' and qmd-index to the 'unwire' default (no offboard field)
# — both land in printOffboardPlan's output, so the fixture mirrors that split
# rather than putting both under one bucket. The resolved location comes from
# scripts/install/uninstall-manifest.tsv's one 'qmd'-surface row (qmd-fork);
# a fixture tsv supplies it since build_fixture's manifest.json alone carries
# no paths. Non-qmd ids (fixture-unwire/-advise/-keep) are the control: they
# must print exactly as caseB/caseH already expect (bare id, no parens).
build_fixture_qmd() {
  local _d="$1"
  build_fixture "$_d"
  cat > "$_d/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    { "id": "fixture-unwire", "kind": "wiring", "scopes": ["project"], "profiles": ["core", "all"], "deps": [], "probe": { "type": "file-exists", "path": "untracked.marker" }, "removable": "full-offboard-only" },
    { "id": "fixture-advise", "kind": "dep", "scopes": ["user"], "profiles": ["core", "all"], "deps": [], "probe": { "type": "dep", "cmd": "node" }, "removable": "full-offboard-only", "offboard": "advise" },
    { "id": "qmd-binary", "kind": "dep", "scopes": ["user"], "profiles": ["luna", "all"], "deps": [], "probe": { "type": "cmd:has_qmd" }, "removable": "full-offboard-only", "offboard": "advise" },
    { "id": "qmd-index", "kind": "vault", "scopes": ["user"], "profiles": ["luna", "all"], "deps": ["qmd-binary"], "probe": { "type": "qmd-index", "collections": ["himmel"] }, "removable": "full-offboard-only" },
    { "id": "fixture-keep", "kind": "vault", "scopes": ["user"], "profiles": ["luna", "all"], "deps": [], "probe": { "type": "file-exists", "path": "{vaultPath}/.marker" }, "removable": "full-offboard-only", "offboard": "keep" }
  ]
}
JSON
  printf 'qmd-fork\tstate\tqmd\tfile\t-\t{HOME}/.himmel/qmd-fork\t8\tthe qmd fork checkout, its bun-global symlink and its index collection\tsymlink,file,collection\n' \
    > "$_d/scripts/install/uninstall-manifest.tsv"
}

# I1: the qmd-fork dir exists with a known 10-byte payload -> both qmd ids
# show the resolved path and '10 B'; the non-qmd ids are untouched.
stubI="$work/caseI"; mkdir -p "$stubI"
cI=$(build_path "$stubI" bash git jq python3 npm -- )
hI="$work/hI"; mkdir -p "$hI/.himmel/qmd-fork"
printf '0123456789' > "$hI/.himmel/qmd-fork/payload"
fixtureI="$work/caseI-fixture"; build_fixture_qmd "$fixtureI"
set +e
outI1=$(PATH="$cI" HOME="$hI" USERPROFILE="$(winpath "$hI")" HIMMELCTL_CACHE_DIR="$(winpath "$hI.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hI.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
       HIMMELCTL_REPO_ROOT="$(winpath "$fixtureI")" \
       "$node_bin" "$wizard" uninstall --dry-run \
       </dev/null 2>&1); rcI1=$?
set -e
[ "$rcI1" -eq 0 ] || fail "caseI1: dry-run should exit 0 (got rc=$rcI1): $outI1"
# separator-tolerant: node's path.join on the printed path may use '\' on
# win32 even though $hI is a forward-slash MSYS path (codex/coderabbit).
grepq "$outI1" -E -- "qmd-binary \\(${hI}[/\\\\]\\.himmel[/\\\\]qmd-fork, 10 B\\)" \
  || fail "caseI1: expected qmd-binary's resolved path + size (got: $outI1)"
grepq "$outI1" -E -- "qmd-index \\(${hI}[/\\\\]\\.himmel[/\\\\]qmd-fork, 10 B\\)" \
  || fail "caseI1: expected qmd-index's resolved path + size (got: $outI1)"
grepq "$outI1" -F -- 'fixture-unwire,' \
  || fail "caseI1: fixture-unwire must print bare, unchanged (got: $outI1)"
grepq "$outI1" -F -- 'fixture-advise' \
  || fail "caseI1: fixture-advise must print bare, unchanged (got: $outI1)"
grepq "$outI1" -F -- 'fixture-advise (' \
  && fail "caseI1: fixture-advise (non-qmd) must NOT gain a resolved-path suffix (got: $outI1)"
echo "ok: caseI1 dry-run advisory plan shows qmd-binary/qmd-index's resolved path + on-disk size, other items unchanged"

# I2: same fixture, qmd-fork dir absent -> both qmd ids show 'absent'.
hI2="$work/hI2"; mkdir -p "$hI2"
set +e
outI2=$(PATH="$cI" HOME="$hI2" USERPROFILE="$(winpath "$hI2")" HIMMELCTL_CACHE_DIR="$(winpath "$hI2.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hI2.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
       HIMMELCTL_REPO_ROOT="$(winpath "$fixtureI")" \
       "$node_bin" "$wizard" uninstall --dry-run \
       </dev/null 2>&1); rcI2=$?
set -e
[ "$rcI2" -eq 0 ] || fail "caseI2: dry-run should exit 0 (got rc=$rcI2): $outI2"
grepq "$outI2" -E -- "qmd-binary \\(${hI2}[/\\\\]\\.himmel[/\\\\]qmd-fork, absent\\)" \
  || fail "caseI2: expected qmd-binary to print 'absent' for a missing path (got: $outI2)"
grepq "$outI2" -E -- "qmd-index \\(${hI2}[/\\\\]\\.himmel[/\\\\]qmd-fork, absent\\)" \
  || fail "caseI2: expected qmd-index to print 'absent' for a missing path (got: $outI2)"
echo "ok: caseI2 dry-run advisory plan prints 'absent' when the qmd-fork path does not exist"

# I3: qmd-fork dir exists but is unreadable (EACCES, not ENOENT) -> 'size
# unknown', never 'absent' — a permission error is not a missing path.
# chmod 000 is a POSIX-only way to force that error: on Windows (MSYS/MINGW)
# it does not restrict access the same way, so this case would false-red a
# platform quirk rather than test the code (codex-1 round 2).
if is_win32; then
  echo "ok: caseI3 -> (skipped: chmod 000 does not deny access on win32, covered by caseI1/I2's non-error paths)"
elif [ "$(id -u)" = 0 ]; then
  echo "SKIP - caseI3 needs a non-root permission error (root reads mode-000 dirs)"
else
  hI3="$work/hI3"; mkdir -p "$hI3/.himmel/qmd-fork"
  printf '0123456789' > "$hI3/.himmel/qmd-fork/payload"
  chmod 000 "$hI3/.himmel"
  set +e
  outI3=$(PATH="$cI" HOME="$hI3" USERPROFILE="$(winpath "$hI3")" HIMMELCTL_CACHE_DIR="$(winpath "$hI3.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hI3.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
         HIMMELCTL_REPO_ROOT="$(winpath "$fixtureI")" \
         "$node_bin" "$wizard" uninstall --dry-run \
         </dev/null 2>&1); rcI3=$?
  set -e
  chmod 700 "$hI3/.himmel"
  [ "$rcI3" -eq 0 ] || fail "caseI3: dry-run should exit 0 (got rc=$rcI3): $outI3"
  grepq "$outI3" -F -- "qmd-binary ($hI3/.himmel/qmd-fork, size unknown)" \
    || fail "caseI3: expected qmd-binary to print 'size unknown' for a permission error (got: $outI3)"
  grepq "$outI3" -F -- "qmd-binary ($hI3/.himmel/qmd-fork, absent)" \
    && fail "caseI3: a permission error must not print 'absent' (got: $outI3)"
  echo "ok: caseI3 dry-run advisory plan prints 'size unknown' (not 'absent') when the qmd-fork path exists but is unreadable"
fi

# I4: qmd-fork dir holds more entries than the walk's entry bound -> 'size
# unknown', never a real byte count and never a hang on a huge tree
# (codex-1 round 4).
hI4="$work/hI4"; mkdir -p "$hI4/.himmel/qmd-fork"
i=0
while [ "$i" -le 5000 ]; do
  : > "$hI4/.himmel/qmd-fork/f$i"
  i=$((i + 1))
done
set +e
outI4=$(PATH="$cI" HOME="$hI4" USERPROFILE="$(winpath "$hI4")" HIMMELCTL_CACHE_DIR="$(winpath "$hI4.himmelctl-cache")" HIMMEL_LUNA_CONFIG_PATH="$(winpath "$hI4.himmelctl-cache/luna-config.json")" HIMMELCTL_INTERACTIVE=0 \
       HIMMELCTL_REPO_ROOT="$(winpath "$fixtureI")" \
       "$node_bin" "$wizard" uninstall --dry-run \
       </dev/null 2>&1); rcI4=$?
set -e
[ "$rcI4" -eq 0 ] || fail "caseI4: dry-run should exit 0 (got rc=$rcI4): $outI4"
grepq "$outI4" -E -- "qmd-binary \\(${hI4}[/\\\\]\\.himmel[/\\\\]qmd-fork, size unknown\\)" \
  || fail "caseI4: expected qmd-binary to print 'size unknown' once the walk exceeds its entry bound (got: $outI4)"
echo "ok: caseI4 dry-run advisory plan prints 'size unknown' (not a byte count) once the qmd-fork tree exceeds the walk's entry bound"

echo "PASS"
