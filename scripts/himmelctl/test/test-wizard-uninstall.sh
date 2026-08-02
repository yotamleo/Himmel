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
#   C. interactive confirm decline ("n") -> the uninstall script is NOT
#      invoked, rc=0, "declined; nothing run".
#   D. interactive confirm accept (blank Enter = the [Y/n] default) -> the
#      uninstall script IS invoked with --yes/-Yes.
#   E. non-interactive, closed stdin (no answer at all, e.g. piped from
#      </dev/null) -> askConfirmSafe's EOF handling declines safely; the
#      uninstall script is NEVER run unattended (no bypass flag exists for
#      uninstall, unlike install's --from-profile).

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
wizard="$repo_root/scripts/himmelctl/bin.js"
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
printf 'uninstall.sh: %s\n' "\$*" >> "$_d/uninstall-calls.log"
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
stubB="$work/caseB"; mkdir -p "$stubB"
cB=$(build_path "$stubB" bash git jq python3 npm -- )
hB="$work/hB"; mkdir -p "$hB"
fixtureB="$work/caseB-fixture"; build_fixture "$fixtureB"
set +e
out=$(PATH="$cB" HOME="$hB" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureB")" \
      "$node_bin" "$wizard" uninstall --dry-run \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseB: dry-run should exit 0 (got rc=$rc): $out"
if is_win32; then
  grepq "$out" -E 'derived:.*powershell -ExecutionPolicy Bypass -File .*uninstall\.ps1 -Yes$' \
    || fail "caseB(win32): expected 'powershell -ExecutionPolicy Bypass -File ...uninstall.ps1 -Yes' (got: $out)"
else
  grepq "$out" -E 'derived:.*bash .*uninstall\.sh --yes$' \
    || fail "caseB(posix): expected 'bash .../uninstall.sh --yes' (got: $out)"
fi
grepq "$out" 'Proceed?' \
  && fail "caseB: --dry-run must NOT show the confirm prompt (got: $out)"
[ -f "$fixtureB/uninstall-calls.log" ] \
  && fail "caseB: --dry-run must NOT execute uninstall.sh/uninstall.ps1 (got: $(cat "$fixtureB/uninstall-calls.log"))"
echo "ok: caseB --dry-run -> derived plan printed, nothing asked or executed"

# ── Case C: interactive confirm decline -> uninstall NOT invoked ───────────
stubC="$work/caseC"; mkdir -p "$stubC"
cC=$(build_path "$stubC" bash git jq python3 npm -- )
hC="$work/hC"; mkdir -p "$hC"
fixtureC="$work/caseC-fixture"; build_fixture "$fixtureC"
set +e
out=$(PATH="$cC" HOME="$hC" HIMMELCTL_INTERACTIVE=1 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureC")" \
      "$node_bin" "$wizard" uninstall \
      <<<"n" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseC: decline should exit 0 (got rc=$rc): $out"
grepq "$out" 'Proceed? \[Y/n\]' \
  || fail "caseC: expected the confirm prompt to be shown (got: $out)"
grepq "$out" 'declined; nothing run' \
  || fail "caseC: expected the decline message (got: $out)"
[ -f "$fixtureC/uninstall-calls.log" ] \
  && fail "caseC: declining must NOT invoke uninstall.sh/uninstall.ps1 (got: $(cat "$fixtureC/uninstall-calls.log"))"
echo "ok: caseC interactive confirm decline -> uninstall script not invoked, rc=0"

# ── Case D: interactive confirm accept (blank Enter) -> uninstall invoked ──
stubD="$work/caseD"; mkdir -p "$stubD"
cD=$(build_path "$stubD" bash git jq python3 npm -- )
hD="$work/hD"; mkdir -p "$hD"
fixtureD="$work/caseD-fixture"; build_fixture "$fixtureD"
set +e
out=$(PATH="$cD" HOME="$hD" HIMMELCTL_INTERACTIVE=1 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureD")" \
      "$node_bin" "$wizard" uninstall \
      <<<"" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseD: accept should exit 0 (got rc=$rc): $out"
[ -f "$fixtureD/uninstall-calls.log" ] \
  || fail "caseD: a blank-Enter accept should invoke uninstall.sh/uninstall.ps1 (out: $out)"
if is_win32; then
  grep -q 'Yes=True' "$fixtureD/uninstall-calls.log" \
    || fail "caseD(win32): expected uninstall.ps1 to be called with -Yes (got: $(cat "$fixtureD/uninstall-calls.log"))"
else
  grep -q -- '--yes' "$fixtureD/uninstall-calls.log" \
    || fail "caseD(posix): expected uninstall.sh to be called with --yes (got: $(cat "$fixtureD/uninstall-calls.log"))"
fi
echo "ok: caseD interactive confirm accept (blank Enter) -> uninstall script invoked with --yes/-Yes"

# ── Case E: closed stdin (no answer) -> declines safely, never runs unattended ─
stubE="$work/caseE"; mkdir -p "$stubE"
cE=$(build_path "$stubE" bash git jq python3 npm -- )
hE="$work/hE"; mkdir -p "$hE"
fixtureE="$work/caseE-fixture"; build_fixture "$fixtureE"
set +e
out=$(PATH="$cE" HOME="$hE" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureE")" \
      "$node_bin" "$wizard" uninstall \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseE: closed-stdin decline should exit 0 (got rc=$rc): $out"
grepq "$out" 'declined; nothing run' \
  || fail "caseE: expected the decline message on EOF (got: $out)"
[ -f "$fixtureE/uninstall-calls.log" ] \
  && fail "caseE: a closed stdin (no explicit answer) must NEVER run uninstall unattended (got: $(cat "$fixtureE/uninstall-calls.log"))"
echo "ok: caseE closed stdin (no answer) -> declines safely, uninstall never runs unattended"

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
out=$(PATH="$cF" HOME="$hF" HIMMELCTL_INTERACTIVE=1 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureF")" \
      HIMMELCTL_BIN_DIR="$(winpath "$binF")" \
      "$node_bin" "$wizard" uninstall \
      <<<"" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseF: accept should exit 0 (got rc=$rc): $out"
[ -f "$fixtureF/uninstall-calls.log" ] \
  || fail "caseF: a blank-Enter accept should invoke the uninstall script (out: $out)"
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
out=$(PATH="$cG" HOME="$hG" HIMMELCTL_INTERACTIVE=1 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureG")" \
      HIMMELCTL_BIN_DIR="$(winpath "$binG")" \
      "$node_bin" "$wizard" uninstall \
      <<<"" 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail "caseG: a failed teardown must propagate nonzero rc (got rc=$rc): $out"
[ -f "$fixtureG/uninstall-calls.log" ] \
  || fail "caseG: the teardown stub should still have been invoked (out: $out)"
[ -f "$binG/himmelctl.js" ] || fail "caseG: a failed teardown must NOT remove the marked loader (it strands the machine with no himmelctl for the retry)"
[ -f "$binG/himmelctl" ] || fail "caseG: a failed teardown must NOT remove the marked launcher"
grepq "$out" 'launchers left in place' || fail "caseG: expected a retry warning preserving the launchers (got: $out)"
echo "ok: caseG failed teardown preserves marked PATH launchers + warns (no stranded machine)"

echo "PASS"
