#!/usr/bin/env bash
# test-wizard-update.sh — hermetic tests for the himmelctl `update` subcommand
# (HIMMEL-893). Mirrors test-wizard-uninstall.sh's conventions: a stub PATH
# via scripts/lib/hermetic-path.sh, a fake HOME, node launched by absolute
# path, HIMMELCTL_REPO_ROOT pointed at a throwaway fixture carrying a no-op
# himmel-update.sh stub so a real update (git pull, marketplace re-sync,
# jira/qmd/hermes/luna chain) is never triggered against the real machine.
#
# Covers:
#   A. --dry-run -> prints the derived plan (bash .../scripts/himmel-update.sh)
#      without executing anything (the stub's call log stays absent).
#   B. no --dry-run -> the derived command IS invoked verbatim, no confirm
#      prompt (unlike uninstall — update has none, matching /himmel-update's
#      own established no-confirm behavior), its exit code propagates, and
#      it is invoked with EXACTLY the expected args (none — deriveUpdateCommand
#      passes only [<bash>, script], nothing extra).
#   C. a failing update propagates its exact (non-standard) exit code
#      unchanged back through himmelctl, not just "any" non-zero.
#   D. `update` rejects options not in its own whitelist (e.g. --items),
#      same validation posture as every other subcommand.
#   E. deriveUpdateCommand forward-slashes the script path (toBashPath) so the
#      resolved Git Bash doesn't MSYS-mangle a backslash Windows path (part 2
#      of the HIMMEL-1192 Windows fix).
#   F. resolveBash() picks a Windows-native Git Bash DETERMINISTICALLY from
#      %ProgramFiles% instead of trusting PATH order — part 1, the REOPENED
#      HIMMEL-1192 root cause: bare `bash` on the operator's PowerShell PATH is
#      C:\Windows\System32\bash.exe (WSL), which cannot run a Windows-path
#      script AT ALL. The s2 fix (toBashPath only) targeted the wrong bash.
#
# Cases A–E pin HIMMELCTL_BASH=bash so they exercise the update WRAPPER +
# toBashPath in isolation — argv[0] stays the bare 'bash' those assertions
# expect, independent of whichever Git Bash resolveBash would pick on the host.
# Case F drops the pin to exercise resolveBash()'s real resolution.

set -euo pipefail

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

# build_fixture <dir> <exit-code> — a throwaway HIMMELCTL_REPO_ROOT target: a
# no-op scripts/himmel-update.sh stub logging its argv, exiting <exit-code>.
# Args are recorded ONE PER LINE (not a "$*"-joined string) so an exact-args
# assertion can't be fooled by word-splitting/quoting — each received arg is
# its own line in update-args.log, with a leading "argc:" line so a call with
# zero args is still distinguishable from the file simply not existing.
build_fixture() {
  local _d="$1" _rc="${2:-0}"
  mkdir -p "$_d/scripts"
  cat > "$_d/scripts/himmel-update.sh" <<STUB
#!/usr/bin/env bash
printf 'himmel-update.sh: %s\n' "\$*" >> "$_d/update-calls.log"
{ printf 'argc:%s\n' "\$#"; for a in "\$@"; do printf '%s\n' "\$a"; done; } >> "$_d/update-args.log"
exit $_rc
STUB
  chmod +x "$_d/scripts/himmel-update.sh"
}

# ── Case A: --dry-run -> prints the plan, executes nothing ─────────────────
stubA="$work/caseA"; mkdir -p "$stubA"
cA=$(build_path "$stubA" bash git jq python3 npm -- )
hA="$work/hA"; mkdir -p "$hA"
fixtureA="$work/caseA-fixture"; build_fixture "$fixtureA" 0
set +e
out=$(PATH="$cA" HOME="$hA" HIMMELCTL_INTERACTIVE=0 HIMMELCTL_BASH=bash \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureA")" \
      "$node_bin" "$wizard" update --dry-run \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseA: dry-run should exit 0 (got rc=$rc): $out"
printf '%s' "$out" | grep -qE 'derived:.*bash .*himmel-update\.sh$' \
  || fail "caseA: expected 'derived: bash .../himmel-update.sh' (got: $out)"
[ -f "$fixtureA/update-calls.log" ] \
  && fail "caseA: --dry-run must NOT execute himmel-update.sh (got: $(cat "$fixtureA/update-calls.log"))"
echo "ok: caseA --dry-run -> derived plan printed, nothing executed"

# ── Case B: no --dry-run -> the derived command IS invoked, no confirm ─────
stubB="$work/caseB"; mkdir -p "$stubB"
cB=$(build_path "$stubB" bash git jq python3 npm -- )
hB="$work/hB"; mkdir -p "$hB"
fixtureB="$work/caseB-fixture"; build_fixture "$fixtureB" 0
set +e
out=$(PATH="$cB" HOME="$hB" HIMMELCTL_INTERACTIVE=1 HIMMELCTL_BASH=bash \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureB")" \
      "$node_bin" "$wizard" update \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseB: exit 0 on a successful update (got rc=$rc): $out"
printf '%s' "$out" | grep -q 'Proceed?' \
  && fail "caseB: update must NOT show a confirm prompt (got: $out)"
[ -f "$fixtureB/update-calls.log" ] \
  || fail "caseB: expected himmel-update.sh to be invoked (out: $out)"
# Exact-args check: deriveUpdateCommand (bin.js) derives ONLY ['bash', script]
# — no extra argv — so the stub must have received zero args (argc:0, no
# further lines). A future regression that starts passing e.g. --yes or
# --items would flip this from "argc:0" to a non-empty argc, catching drift
# between bin.js's deriveUpdateCommand and this test's expectation.
args_logged=$(cat "$fixtureB/update-args.log")
[ "$args_logged" = "argc:0" ] \
  || fail "caseB: expected himmel-update.sh invoked with exactly zero args (got: '$args_logged')"
echo "ok: caseB no --dry-run -> himmel-update.sh invoked verbatim with exact (zero) args, no confirm prompt"

# ── Case C: a failing update propagates its EXACT exit code ────────────────
# A non-standard code (42, not 1) proves himmelctl forwards the real rc
# rather than collapsing any failure to a generic 1 — 1 alone wouldn't catch
# a wrapper that just does `return cmd_failed ? 1 : 0`.
stubC="$work/caseC"; mkdir -p "$stubC"
cC=$(build_path "$stubC" bash git jq python3 npm -- )
hC="$work/hC"; mkdir -p "$hC"
fixtureC="$work/caseC-fixture"; build_fixture "$fixtureC" 42
set +e
out=$(PATH="$cC" HOME="$hC" HIMMELCTL_INTERACTIVE=1 HIMMELCTL_BASH=bash \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureC")" \
      "$node_bin" "$wizard" update \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 42 ] || fail "caseC: expected rc=42 to propagate unchanged from a failing update (got rc=$rc): $out"
[ -f "$fixtureC/update-calls.log" ] \
  || fail "caseC: expected himmel-update.sh to still be invoked (out: $out)"
echo "ok: caseC failing update -> exact non-standard rc (42) propagates through himmelctl"

# ── Case D: option whitelist rejects options update doesn't take ───────────
stubD="$work/caseD"; mkdir -p "$stubD"
cD=$(build_path "$stubD" bash git jq python3 npm -- )
hD="$work/hD"; mkdir -p "$hD"
fixtureD="$work/caseD-fixture"; build_fixture "$fixtureD" 0
set +e
out=$(PATH="$cD" HOME="$hD" HIMMELCTL_INTERACTIVE=1 HIMMELCTL_BASH=bash \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureD")" \
      "$node_bin" "$wizard" update --items foo \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 2 ] || fail "caseD: expected rc=2 for an unsupported option (got rc=$rc): $out"
printf '%s' "$out" | grep -q -- '--items is not valid' \
  || fail "caseD: expected an option-not-valid diagnostic naming --items (got: $out)"
[ -f "$fixtureD/update-args.log" ] \
  && fail "caseD: --items rejection must NOT invoke himmel-update.sh (got: $(cat "$fixtureD/update-args.log"))"
echo "ok: caseD update rejects options outside its whitelist (--items), stub never invoked"

# ── Case E (HIMMEL-1192): a backslash repo root is forward-slashed for bash ──
# deriveUpdateCommand must run the script path through toBashPath so Git Bash
# does not eat the backslashes ('\U'->'U', '\D'->'D' ...) and collapse
# C:\Users\...\himmel-update.sh into a nonexistent C:Users...himmel-update.sh.
# Feed a Windows-style backslash HIMMELCTL_REPO_ROOT and assert the printed
# derived command carries NO backslash (every separator forward-slashed) — the
# tell that toBashPath was applied. --dry-run prints without executing, and
# repoRoot() returns HIMMELCTL_REPO_ROOT verbatim, so the fake root needs no
# real himmel-update.sh on disk. The assertion holds on posix too: path.join
# leaves the input backslashes as literals there, and toBashPath still maps
# them to '/'. HIMMELCTL_BASH=bash pins argv[0] to the bare 'bash' so the
# no-backslash assertion below scopes cleanly to the SCRIPT path (a resolved
# Git-Bash launcher would itself carry backslashes — that is Case F's concern).
stubE="$work/caseE"; mkdir -p "$stubE"
cE=$(build_path "$stubE" bash git jq python3 npm -- )
hE="$work/hE"; mkdir -p "$hE"
set +e
out=$(PATH="$cE" HOME="$hE" HIMMELCTL_INTERACTIVE=0 HIMMELCTL_BASH=bash \
      HIMMELCTL_REPO_ROOT='C:\Users\test\himmel' \
      "$node_bin" "$wizard" update --dry-run \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseE: dry-run should exit 0 (got rc=$rc): $out"
derived_line=$(printf '%s\n' "$out" | grep 'derived:')
case "$derived_line" in
  *\\*) fail "caseE: derived command still contains a backslash — toBashPath not applied: $derived_line" ;;
esac
printf '%s' "$derived_line" | grep -qE 'bash C:/Users/test/himmel/scripts/himmel-update\.sh' \
  || fail "caseE: expected forward-slashed script path in derived command (got: $derived_line)"
echo "ok: caseE backslash repo root -> derived command forward-slashed (toBashPath applied)"

# ── Case F (HIMMEL-1192 REOPENED): resolveBash picks a deterministic Git Bash ─
# The real, reopened root cause: bare `bash` on the operator's PowerShell PATH
# resolves to C:\Windows\System32\bash.exe (WSL) because Git Bash is LAST on
# PATH — and WSL cannot run a Windows-path script in ANY form. resolveBash()
# must therefore pick a Windows-native Git Bash DETERMINISTICALLY from
# %ProgramFiles%\Git\..., ignoring PATH order — NEVER a bare `bash`.
#
# Host-aware, because %ProgramFiles% cannot be overridden for a node child from
# an MSYS shell (Windows re-injects the real system value regardless of an
# inline/`env` assignment — verified), so a fake-ProgramFiles fixture is
# impossible here; the REAL host resolution IS the assertion:
#   - win32 (this suite runs under Git Bash, so a standard Git-for-Windows
#     install is present): the derived launcher must be a concrete
#     ...\Git\...\bash.exe, NOT bare 'bash'. The candidate list never contains
#     System32\bash.exe, so resolving to Git\...\bash.exe IS proof WSL is never
#     chosen. A revert to `argv: ['bash', script]` flips this to bare 'bash' and
#     trips the guard. (The operator additionally validates from a real
#     PowerShell shell, where bare `bash` would be WSL — the handover's ask.)
#   - posix: no %ProgramFiles%/Git, so resolveBash falls through to bare 'bash'
#     — assert exactly that (unchanged behavior off-Windows).
# No HIMMELCTL_BASH — that seam would short-circuit the resolution under test.
stubF="$work/caseF"; mkdir -p "$stubF"
cF=$(build_path "$stubF" bash git jq python3 npm -- )
hF="$work/hF"; mkdir -p "$hF"
fixtureF="$work/caseF-fixture"; build_fixture "$fixtureF" 0
set +e
out=$(PATH="$cF" HOME="$hF" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureF")" \
      "$node_bin" "$wizard" update --dry-run \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseF: dry-run should exit 0 (got rc=$rc): $out"
derived_lineF=$(printf '%s\n' "$out" | grep 'derived:')
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    printf '%s' "$derived_lineF" | grep -qE '[/\\]Git[/\\](usr[/\\])?bin[/\\]bash\.exe' \
      || fail "caseF(win32): resolveBash should resolve a concrete Git Bash (…\\Git\\…\\bash.exe), not bare 'bash' — is Git for Windows installed under %ProgramFiles%? (got: $derived_lineF)"
    printf '%s' "$derived_lineF" | grep -qE 'derived: bash ' \
      && fail "caseF(win32): derived launcher is bare 'bash' — resolveBash fell back to PATH instead of Git Bash, which on a PowerShell PATH is WSL (got: $derived_lineF)"
    ;;
  *)
    printf '%s' "$derived_lineF" | grep -qE 'derived: bash .*himmel-update\.sh$' \
      || fail "caseF(posix): resolveBash should fall through to bare 'bash' off-Windows (got: $derived_lineF)"
    ;;
esac
[ -f "$fixtureF/update-calls.log" ] \
  && fail "caseF: --dry-run must NOT execute himmel-update.sh (got: $(cat "$fixtureF/update-calls.log"))"
echo "ok: caseF resolveBash -> deterministic Git Bash on win32 / bare 'bash' fallback on posix (never WSL)"

echo "PASS"
