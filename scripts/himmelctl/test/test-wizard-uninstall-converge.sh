#!/usr/bin/env bash
# test-wizard-uninstall-converge.sh — hermetic tests for the manifest-driven
# uninstall advisory + completeness check (HIMMEL-755 sub-ticket E,
# uninstall-completeness). Companion to test-wizard-uninstall.sh (which
# covers the pre-existing thin-wrapper confirm/dry-run/flag behavior
# unchanged by this sub-ticket) — this suite covers the NEW manifest-aware
# behavior added to cmdUninstall: partitioning items by `offboard`
# (unwire/advise/keep), printing the advisory plan, and the post-teardown
# residue WARN.
#
# Same hermetic conventions as test-wizard-uninstall.sh: a stub PATH via
# scripts/lib/hermetic-path.sh, a fake HOME, node launched by absolute path,
# HIMMELCTL_REPO_ROOT pointed at a throwaway fixture carrying a no-op
# uninstall.sh/uninstall.ps1 (so a real uninstall is never triggered) plus a
# minimal scripts/install/manifest.json exercising all three `offboard`
# values.
#
# Covers:
#   A. --dry-run prints the full plan (owned/unwire, shared/advise, keep) and
#      executes nothing (mirrors test-wizard-uninstall.sh caseB, plus the new
#      advisory content).
#   B. an accepted run with nothing pre-wired: the advisory lists the shared
#      items (never removed — no code path in cmdUninstall touches them) and
#      the keep item is reported as left-untouched; completeness reads clean
#      (no WARN) since nothing was wired to begin with.
#   C. an accepted run with the tracked owned item's backing state PRE-WIRED
#      (a `statusLine` key in the fake $HOME/.claude/settings.json): since
#      the fixture's uninstall.sh stub is a no-op (never actually unwires
#      anything), the post-teardown completeness probe finds it still
#      present and WARNs — proving the residue check actually fires, not
#      just prints an empty summary every time.
#   D. manifest-lint.mjs still passes on the REAL manifest.json (the
#      `offboard` field this sub-ticket added must stay lint-clean).
#   E. the teardown itself FAILS (uninstall.sh/uninstall.ps1 exits 1, same
#      pre-wired owned state as case C): cmdUninstall must propagate the
#      teardown's rc=1 out as its own return value — never swallow/mask a
#      failed teardown behind rc=0 — AND still run the completeness check
#      (which still WARNs, since a failed no-op stub never actually unwired
#      fixture-owned, same residue signal as case C).
#   F. project-scope residue: fixture-owned's PROJECT-scope settings.json
#      (<fixture>/.claude/settings.json, not $HOME's) is pre-wired while
#      $HOME stays clean. Proves the completeness check probes EVERY scope
#      an item declares (not just 'user') and labels the residue with the
#      scope it was found in ("fixture-owned (present, project)") — the
#      CodeRabbit finding this case guards against.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
wizard="$repo_root/scripts/himmelctl/bin.js"
lint="$repo_root/scripts/install/manifest-lint.mjs"
[ -f "$wizard" ] || { echo "FAIL: $wizard not found" >&2; exit 1; }
[ -f "$lint" ] || { echo "FAIL: $lint not found" >&2; exit 1; }
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

# build_path <stub_dir> <present_tools...>
build_path() {
  local _stub="$1"; shift
  local _t
  for _t in "$@"; do
    link_hermetic_tool "$_t" "$_stub"
  done
  printf '%s:%s' "$_stub" "$PATH"
}

# build_fixture <dir> — a throwaway HIMMELCTL_REPO_ROOT target: no-op
# uninstall.sh/uninstall.ps1 stubs (never actually unwire anything — that's
# the point: it lets case C prove the completeness check notices), plus a
# 3-item manifest exercising all three `offboard` values:
#   fixture-owned  — default (absent -> 'unwire'), carries an `unwire`
#                    descriptor + removable:'per-item' so it's in the
#                    completeness check's convergeable set. Its probe reads
#                    a statusLine key from ".claude/settings.json" and
#                    declares scopes:["project","user"] — the same shape
#                    the real wiring-statusline item uses, so it exercises
#                    the per-scope completeness probing (project ->
#                    <fixture>/.claude/settings.json, user ->
#                    $HOME/.claude/settings.json).
#   fixture-advise — offboard:'advise' (a shared dep, e.g. 'node' stand-in).
#   fixture-keep   — offboard:'keep' (user content stand-in).
build_fixture() {
  local _d="$1"
  mkdir -p "$_d/scripts/install"
  cat > "$_d/scripts/uninstall.sh" <<STUB
#!/usr/bin/env bash
printf 'uninstall.sh: %s\n' "\$*" >> "$_d/uninstall-calls.log"
exit 0
STUB
  chmod +x "$_d/scripts/uninstall.sh"
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
    {
      "id": "fixture-owned",
      "kind": "wiring",
      "scopes": ["project", "user"],
      "profiles": ["core", "all"],
      "deps": [],
      "probe": { "type": "settings-key", "file": ".claude/settings.json", "key": "statusLine.command" },
      "unwire": { "type": "wire", "target": "statusline" },
      "removable": "per-item"
    },
    {
      "id": "fixture-advise",
      "kind": "dep",
      "scopes": ["user"],
      "profiles": ["core", "all"],
      "deps": [],
      "probe": { "type": "dep", "cmd": "node" },
      "removable": "full-offboard-only",
      "offboard": "advise"
    },
    {
      "id": "fixture-keep",
      "kind": "vault",
      "scopes": ["user"],
      "profiles": ["luna", "all"],
      "deps": [],
      "probe": { "type": "file-exists", "path": "{vaultPath}/.marker" },
      "removable": "full-offboard-only",
      "offboard": "keep"
    }
  ]
}
JSON
}

# build_fixture_failing <dir> — same fixture as build_fixture, except
# uninstall.sh/uninstall.ps1 exit 1 instead of 0 (still logging the call
# first, so a failed-invocation assertion has the same log-file signal to
# check as the passing cases). Used by case E to prove a failed teardown's
# rc propagates out of cmdUninstall rather than being masked by the
# (non-fatal, by design) completeness check that runs after it.
build_fixture_failing() {
  local _d="$1"
  build_fixture "$_d"
  local _dw; _dw="$(winpath "$_d")"
  cat > "$_d/scripts/uninstall.sh" <<STUB
#!/usr/bin/env bash
printf 'uninstall.sh: %s\n' "\$*" >> "$_d/uninstall-calls.log"
exit 1
STUB
  chmod +x "$_d/scripts/uninstall.sh"
  cat > "$_d/scripts/uninstall.ps1" <<STUB
param([switch]\$Yes,[switch]\$DryRun)
Add-Content -Path '$_dw/uninstall-calls.log' -Value "uninstall.ps1: Yes=\$Yes DryRun=\$DryRun"
exit 1
STUB
}

# ── Case A: --dry-run -> full plan printed, nothing asked or executed ──────
stubA="$work/caseA"; mkdir -p "$stubA"
cA=$(build_path "$stubA" bash git jq python3 npm node)
hA="$work/hA"; mkdir -p "$hA"
fixtureA="$work/caseA-fixture"; build_fixture "$fixtureA"
set +e
out=$(PATH="$cA" HOME="$hA" HIMMELCTL_INTERACTIVE=0 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureA")" \
      "$node_bin" "$wizard" uninstall --dry-run \
      </dev/null 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseA: dry-run should exit 0 (got rc=$rc): $out"
printf '%s' "$out" | grep -qF 'himmel-owned wiring & repo-local artifacts' \
  || fail "caseA: expected the owned/unwire plan header (got: $out)"
printf '%s' "$out" | grep -qF 'fixture-owned' \
  || fail "caseA: expected fixture-owned in the owned/unwire plan (got: $out)"
printf '%s' "$out" | grep -qF "Shared tools himmel installed or requires (NOT removed" \
  || fail "caseA: expected the shared-tools advisory header (got: $out)"
printf '%s' "$out" | grep -qF 'fixture-advise' \
  || fail "caseA: expected fixture-advise in the advisory (got: $out)"
printf '%s' "$out" | grep -qF 'left untouched (your data): fixture-keep' \
  || fail "caseA: expected fixture-keep reported as left-untouched (got: $out)"
printf '%s' "$out" | grep -q 'Proceed?' \
  && fail "caseA: --dry-run must NOT show the confirm prompt (got: $out)"
[ -f "$fixtureA/uninstall-calls.log" ] \
  && fail "caseA: --dry-run must NOT execute uninstall.sh/uninstall.ps1 (got: $(cat "$fixtureA/uninstall-calls.log"))"
echo "ok: caseA --dry-run -> full advisory plan printed (owned/advise/keep), nothing asked or executed"

# ── Case B: accepted run, nothing pre-wired -> advisory shown, shared/keep
# items untouched, completeness reads clean (nothing was wired to begin
# with, so there's nothing for the residue check to catch) ─────────────────
stubB="$work/caseB"; mkdir -p "$stubB"
cB=$(build_path "$stubB" bash git jq python3 npm node)
hB="$work/hB"; mkdir -p "$hB"
fixtureB="$work/caseB-fixture"; build_fixture "$fixtureB"
set +e
out=$(PATH="$cB" HOME="$hB" HIMMELCTL_INTERACTIVE=1 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureB")" \
      "$node_bin" "$wizard" uninstall \
      <<<"" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseB: accept should exit 0 (got rc=$rc): $out"
[ -f "$fixtureB/uninstall-calls.log" ] \
  || fail "caseB: a blank-Enter accept should invoke uninstall.sh/uninstall.ps1 (out: $out)"
printf '%s' "$out" | grep -qF 'fixture-advise' \
  || fail "caseB: expected fixture-advise listed in the advisory (got: $out)"
printf '%s' "$out" | grep -qF 'left untouched (your data): fixture-keep' \
  || fail "caseB: expected fixture-keep reported as left-untouched (got: $out)"
printf '%s' "$out" | grep -qi 'WARN' \
  && fail "caseB: nothing was pre-wired — the completeness check must NOT WARN (got: $out)"
[ -f "$hB/.claude/settings.json" ] \
  && fail "caseB: cmdUninstall must never WRITE a settings.json for an advise/keep item (got a file at $hB/.claude/settings.json)"
echo "ok: caseB accepted run (nothing pre-wired) -> advisory + keep reported, shared items untouched, no false WARN"

# ── Case C: accepted run, the owned item's backing state IS pre-wired ─────
# (a statusLine key in the fake HOME's settings.json). The fixture's
# uninstall.sh stub is a no-op — it never actually unwires anything — so the
# post-teardown completeness probe must still find fixture-owned present and
# WARN. This proves the residue check is a real signal, not a check that
# only ever prints "0 residue".
stubC="$work/caseC"; mkdir -p "$stubC"
cC=$(build_path "$stubC" bash git jq python3 npm node)
hC="$work/hC"; mkdir -p "$hC/.claude"
cat > "$hC/.claude/settings.json" <<'JSON'
{ "statusLine": { "command": "echo hi" } }
JSON
fixtureC="$work/caseC-fixture"; build_fixture "$fixtureC"
set +e
out=$(PATH="$cC" HOME="$hC" HIMMELCTL_INTERACTIVE=1 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureC")" \
      "$node_bin" "$wizard" uninstall \
      <<<"" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseC: accept should exit 0 even with a residue WARN (got rc=$rc): $out"
[ -f "$fixtureC/uninstall-calls.log" ] \
  || fail "caseC: a blank-Enter accept should invoke uninstall.sh/uninstall.ps1 (out: $out)"
printf '%s' "$out" | grep -qE 'WARN.*fixture-owned' \
  || fail "caseC: expected a single completeness WARN line naming fixture-owned since the stub never actually unwired it (got: $out)"
echo "ok: caseC accepted run with pre-wired owned state -> completeness WARN fires naming the residue, rc still 0"

# ── Case D: the REAL manifest.json still lints clean (the `offboard` field
# this sub-ticket added must not break manifest-lint.mjs) ─────────────────
set +e
outD=$("$node_bin" "$lint" 2>&1); rcD=$?
set -e
[ "$rcD" -eq 0 ] || fail "caseD: the real manifest.json should lint clean after adding 'offboard' (got rc=$rcD): $outD"
echo "ok: caseD — the real manifest.json (with the new 'offboard' field) still lints clean"

# ── Case E: the teardown itself FAILS (uninstall.sh/.ps1 exit 1), with the
# same pre-wired owned state as case C. The overall `himmelctl uninstall` rc
# must be 1 (the teardown's rc propagated, never masked by the non-fatal
# completeness check that runs after it) — and the completeness check must
# still fire, still finding fixture-owned present and WARNing (the failed
# no-op stub never actually unwired anything, same residue signal as case C).
stubE="$work/caseE"; mkdir -p "$stubE"
cE=$(build_path "$stubE" bash git jq python3 npm node)
hE="$work/hE"; mkdir -p "$hE/.claude"
cat > "$hE/.claude/settings.json" <<'JSON'
{ "statusLine": { "command": "echo hi" } }
JSON
fixtureE="$work/caseE-fixture"; build_fixture_failing "$fixtureE"
set +e
out=$(PATH="$cE" HOME="$hE" HIMMELCTL_INTERACTIVE=1 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureE")" \
      "$node_bin" "$wizard" uninstall \
      <<<"" 2>&1); rc=$?
set -e
[ "$rc" -eq 1 ] || fail "caseE: a failed teardown (uninstall.sh exit 1) should propagate rc=1 (got rc=$rc): $out"
[ -f "$fixtureE/uninstall-calls.log" ] \
  || fail "caseE: a blank-Enter accept should still invoke uninstall.sh/uninstall.ps1 even though it fails (out: $out)"
printf '%s' "$out" | grep -qE 'WARN.*fixture-owned' \
  || fail "caseE: expected a single completeness WARN line naming fixture-owned — the failed stub never actually unwired it (got: $out)"
echo "ok: caseE a failed teardown propagates rc=1 (not masked), and the completeness WARN still fires"

# ── Case F: PROJECT-scope residue, $HOME clean. fixture-owned declares
# scopes:["project","user"] (same as the real wiring-statusline item) — this
# case pre-wires ONLY the project-scope settings.json (<fixture>/.claude/
# settings.json, i.e. HIMMELCTL_REPO_ROOT's own .claude, the "project" target
# for a machine offboard) and leaves the fake $HOME untouched. Before this
# fix, checkUninstallCompleteness hardcoded scope:'user' and would have read
# this as fully converged (no WARN) even though the project-scope wiring is
# still there. It must now WARN, and the residue label must say "project" so
# the operator knows which scope still carries it.
stubF="$work/caseF"; mkdir -p "$stubF"
cF=$(build_path "$stubF" bash git jq python3 npm node)
hF="$work/hF"; mkdir -p "$hF"
fixtureF="$work/caseF-fixture"; build_fixture "$fixtureF"
mkdir -p "$fixtureF/.claude"
cat > "$fixtureF/.claude/settings.json" <<'JSON'
{ "statusLine": { "command": "echo hi" } }
JSON
set +e
out=$(PATH="$cF" HOME="$hF" HIMMELCTL_INTERACTIVE=1 \
      HIMMELCTL_REPO_ROOT="$(winpath "$fixtureF")" \
      "$node_bin" "$wizard" uninstall \
      <<<"" 2>&1); rc=$?
set -e
[ "$rc" -eq 0 ] || fail "caseF: accept should exit 0 even with a project-scope residue WARN (got rc=$rc): $out"
[ -f "$fixtureF/uninstall-calls.log" ] \
  || fail "caseF: a blank-Enter accept should invoke uninstall.sh/uninstall.ps1 (out: $out)"
printf '%s' "$out" | grep -qE 'WARN.*fixture-owned \(present, project\)' \
  || fail "caseF: expected the completeness WARN to name fixture-owned's PROJECT-scope residue specifically (got: $out)"
[ -f "$hF/.claude/settings.json" ] \
  && fail "caseF: nothing should have written the fake HOME's settings.json (got a file at $hF/.claude/settings.json)"
echo "ok: caseF project-scope residue (fixture-owned pre-wired only at <fixture>/.claude/settings.json, HOME clean) -> completeness WARN names it 'project', not silently missed"

echo "PASS"
