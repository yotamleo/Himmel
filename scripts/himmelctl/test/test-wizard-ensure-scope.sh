#!/usr/bin/env bash
# test-wizard-ensure-scope.sh — `himmelctl ensure --items <id>` runs ONLY that
# item (HIMMEL-4267). himmel-update calls `ensure --items pre-commit-hooks
# --yes`; that used to run a full adopt, persist every other recorded-profile
# item into the target's state, and fail on an unrelated step.
#
# Sandboxed HOME, cache dir, repo root and target only. The fixture's stub
# adopt.sh logs its argv to ENSURE_LOG.
#
# Covers:
#   a. a single-item ensure leaves state.json byte-identical, never turns
#      another recorded item on, runs adopt.sh with --only-hooks, exits 0.
#   b. a bare ensure on the same fixture DOES enable + converge the other item
#      (the additive reconcile is kept for the bare verb).
#   c. an installer that exits non-zero AFTER placing the requested item
#      (unrelated step failing) does not fail the item: exit 0 + a warning.
#   d. the requested item still red after a failing installer stays a failure.

set -euo pipefail

grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

repo_root=$(git rev-parse --show-toplevel)
# shellcheck disable=SC1091
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"
wizard="$repo_root/scripts/himmelctl/bin.js"
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }
fail() { echo "FAIL: $1" >&2; exit 1; }
node_bin=$(command -v node)

work=$(mktemp -d "${TMPDIR:-/tmp}/ensure-scope.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

fixture_repo="$work/repo"
mkdir -p "$fixture_repo/scripts/install" "$fixture_repo/scripts"
cat > "$fixture_repo/scripts/install/manifest.json" <<'JSON'
{
  "schemaVersion": 2,
  "harness": "claude",
  "items": [
    { "id": "pre-commit-hooks", "kind": "hook", "scopes": ["project"], "profiles": ["core", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "hooks.marker" }, "install": { "type": "adopt" } },
    { "id": "other-item", "kind": "hook", "scopes": ["project"], "profiles": ["core", "all"], "deps": [],
      "probe": { "type": "file-exists", "path": "other.marker" }, "install": { "type": "adopt" } }
  ]
}
JSON
# Stub adopt.sh: --only-hooks places only the hooks marker; a full adopt also
# places the other marker. STUB_FAIL=1 makes it exit 1 after placing (an
# unrelated step failing); STUB_FAIL=2 exits 1 WITHOUT placing anything.
cat > "$fixture_repo/scripts/adopt.sh" <<'SH'
#!/usr/bin/env bash
ALLARGS="$*"
echo "adopt $ALLARGS" >> "$ENSURE_LOG"
T=""; prev=""
for a in "$@"; do [ "$prev" = --target ] && T="$a"; prev="$a"; done
[ "${STUB_FAIL:-0}" = 2 ] && exit 1
touch "$T/hooks.marker"
case " $ALLARGS " in *" --only-hooks "*) ;; *) touch "$T/other.marker" ;; esac
[ "${STUB_FAIL:-0}" = 1 ] && exit 1
exit 0
SH

home="$work/home"; mkdir -p "$home"
cache="$work/cache"; mkdir -p "$cache"
cat > "$cache/install-profile.json" <<'JSON'
{"role":"adopter","tier":"standard","scope":"project","vault":{"mode":"none","path":""},"handover":{"mode":"inline","path":""},"pluginSet":"lean","lanes":[],"lanesMeaningful":true,"alwaysOn":false}
JSON

# fresh_target <name> — a target dir whose recorded state has pre-commit-hooks
# on and other-item recorded-but-off (what the operator's station looked like).
fresh_target() {
  local t="$work/$1"; mkdir -p "$t"
  jq -n --arg t "$t" '{schemaVersion:1,harness:"claude",targets:{($t):{profile:"core",scope:"project",lastEnsured:null,items:{"pre-commit-hooks":{enabled:true,overrides:{}},"other-item":{enabled:false,overrides:{}}}}}}' > "$cache/state.json"
  echo "$t"
}

run_ensure() { # <target> <stub-fail> args...
  local t="$1" sf="$2"; shift 2
  ( cd "$t" && ENSURE_LOG="$work/log" STUB_FAIL="$sf" HIMMELCTL_REPO_ROOT="$(winpath "$fixture_repo")" HIMMELCTL_CACHE_DIR="$(winpath "$cache")" \
      HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cache")-luna-config.json" HOME="$home" USERPROFILE="$(winpath "$home")" \
      "$node_bin" "$wizard" ensure "$@" </dev/null 2>&1 )
}

# ── a: single-item ensure ──────────────────────────────────────────────────
t=$(fresh_target ta); : > "$work/log"
before=$(cksum < "$cache/state.json")
rc=0; out=$(run_ensure "$t" 0 --items pre-commit-hooks --yes) || rc=$?
[ "$rc" -eq 0 ] || fail "a: expected exit 0 (rc=$rc): $out"
[ "$before" = "$(cksum < "$cache/state.json")" ] || fail "a: --items changed state.json"
grepq "$out" -F 'recorded install-profile enables' && fail "a: --items must not persist other items: $out"
grepq "$(cat "$work/log")" -F 'adopt' || fail "a: adopt.sh never ran"
grepq "$(cat "$work/log")" -F -- '--only-hooks' || fail "a: adopt.sh ran without --only-hooks: $(cat "$work/log")"
[ -e "$t/hooks.marker" ] || fail "a: requested item not placed"
[ ! -e "$t/other.marker" ] || fail "a: another item was installed"
echo "ok: a — single-item ensure: state byte-identical, hooks-only, nothing else installed"

# ── b: bare ensure keeps the additive reconcile ────────────────────────────
t=$(fresh_target tb); : > "$work/log"
rc=0; out=$(run_ensure "$t" 0 --yes) || rc=$?
[ "$rc" -eq 0 ] || fail "b: bare ensure rc=$rc: $out"
grepq "$out" -F 'recorded install-profile enables 1 item(s)' || fail "b: bare ensure lost the additive reconcile: $out"
[ -e "$t/other.marker" ] || fail "b: bare ensure did not converge other-item"
echo "ok: b — bare ensure still enables + converges recorded items"

# ── c: unrelated failing step does not fail the requested item ─────────────
t=$(fresh_target tc); : > "$work/log"
rc=0; out=$(run_ensure "$t" 1 --items pre-commit-hooks --yes) || rc=$?
[ "$rc" -eq 0 ] || fail "c: failing unrelated step failed the requested item (rc=$rc): $out"
grepq "$out" -F 'post-checks green' || fail "c: expected the warning: $out"
echo "ok: c — installer failure after the item converged is a warning"

# ── d: item still red after a failing installer stays a failure ────────────
t=$(fresh_target td); : > "$work/log"
rc=0; out=$(run_ensure "$t" 2 --items pre-commit-hooks --yes) || rc=$?
[ "$rc" -eq 1 ] || fail "d: a genuinely failed item must exit 1 (rc=$rc): $out"
echo "ok: d — a genuinely unconverged item still fails"
