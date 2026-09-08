#!/usr/bin/env bash
# test-uninstall-plugins-scope.sh — Platform guard: POSIX-only bash test (no
# .ps1 twin; mirrors test-install-plugins-verify.sh, which also ships
# POSIX-only) for the HIMMEL-2694 --scope fix in
# scripts/machine-setup/uninstall-plugins.sh.
#
# HIMMEL-2694: a project/local-scope plugin install could never be
# uninstalled — uninstall-plugins.sh never passed --scope to `claude plugin
# uninstall`/`marketplace remove`, so every call ran at the CLI's default
# scope and every plugin refused removal ("Plugin ... is enabled at project
# scope ..."). Also covers the sibling defect: uninstall-plugins.sh used to
# attempt EVERY settings-template.json key regardless of its true/false
# flag, so a lean install (13 true-flagged entries) produced 18 spurious
# "not found" failures for the false-flagged entries it never installed.
#
# Stubs `claude` on PATH to RECORD its argv (never a real plugin
# uninstall) and drives the real script (no --dry-run — dry-run never
# invokes the stub, and the whole point here is to inspect the recorded
# argv) against a temp template with a marketplace + 2 true-flagged +
# 1 false-flagged plugin. Covers:
#   1. default (no --scope)  -> every claude call carries --scope user
#   2. --scope project       -> every claude call carries --scope project
#   3. --scope bogus         -> exit 2, validation runs before preflight
#   4. false-flagged entry   -> never uninstalled (mirrors install's own
#      select(.value == true) filter)
#   6. HIMMEL-2733 two-tier profile: a `false`-flagged entry that IS listed in
#      onDemandPlugins IS still uninstalled (it mirrors what install-
#      plugins.sh actually installs — the ALWAYS tier UNION the ON-DEMAND
#      tier), while a plain `false` entry absent from onDemandPlugins stays
#      excluded (same as case 4).
#   5. RED control: the SAME drive against a FROZEN inline reproduction of
#      the pre-HIMMEL-2694 call shape (a heredoc stub written by this test,
#      NOT `git show HEAD:...`) proves it (a) still uninstalls the
#      true-flagged plugins, (b) also attempts the false-flagged one (the
#      31-vs-13 noise), and (c) never passes --scope at all. A git-history
#      read of uninstall-plugins.sh cannot serve as this control: the
#      instant this branch's fix is committed, `HEAD:...` IS the fixed
#      script, and the "never passes --scope" assertion would flip to a
#      false pass forever after — the control must outlive its own fix.

set -uo pipefail

repo_root=$(git rev-parse --show-toplevel)
script="$repo_root/scripts/machine-setup/uninstall-plugins.sh"
[ -f "$script" ] || { echo "FAIL: $script not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; echo "$(basename "$0"): SKIPPED — 0 cases ran (jq not on PATH)"; exit 0; }

FAILED=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-uninstall-plugins-scope.XXXXXX") || { echo "FAIL: mktemp -d failed — cannot create the scratch dir this suite needs" >&2; exit 1; }
[ -n "$TMP" ] || { echo "FAIL: mktemp -d produced an empty path" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# WHY (HIMMEL-2754): answer enumeration so this suite exercises per-row
# scope resolution rather than the degraded template fallback. Record each
# full argv on one line without ever touching a real plugin.
STUB_DIR="$TMP/bin"
mkdir -p "$STUB_DIR"
REAL_CAT=$(command -v cat)
ARGV_LOG="$TMP/argv.log"
: > "$ARGV_LOG"
cat > "$STUB_DIR/claude" <<'STUB'
#!/usr/bin/env bash
[ -n "${ARGV_LOG:-}" ] || exit 0
if [ ! -s "$ARGV_LOG" ]; then
    rm -f "${ARGV_LOG%/*}/marketplaces.json" "${ARGV_LOG%/*}/registrations" \
        "${ARGV_LOG%/*}/successes" "${ARGV_LOG%/*}/repaired"
    : > "${ARGV_LOG%/*}/successes"
fi
echo "$*" >> "$ARGV_LOG"
scope="${STUB_SCOPE:-user}"
state="${ARGV_LOG%/*}/plugins-$scope.json"
default_mkt='[{"name":"mp"}]'
case "$*" in
    'plugin list --json')
        if [ ! -f "$state" ]; then
            if [ -n "${STUB_PLUGINS:-}" ]; then
                printf '%s\n' "$STUB_PLUGINS" > "$state"
            else
                jq -n --arg scope "$scope" --arg p "$(pwd -P)" '[{id:"good-a@mp",scope:$scope,projectPath:$p},{id:"good-b@mp",scope:$scope,projectPath:$p}]' > "$state"
            fi
        fi
        cat "$state"
        ;;
    'plugin marketplace list --json')
        if [ -f "${ARGV_LOG%/*}/marketplaces.json" ]; then
            cat "${ARGV_LOG%/*}/marketplaces.json"
        else
            printf '%s\n' "${STUB_MARKETPLACES:-$default_mkt}"
        fi
        ;;
    'plugin marketplace remove '*)
        [[ "${STUB_REMOVE_NOOP:-0}" == 0 ]] || exit 0
        mkt_state="${ARGV_LOG%/*}/marketplaces.json"
        if [[ -n "${STUB_REGISTRATION_SCOPES:-}" ]]; then
            [[ "${STUB_REMOVE_FAIL:-0}" == 0 ]] || exit 1
            registrations="${ARGV_LOG%/*}/registrations"
            [ -f "$registrations" ] || printf '%s\n' "$STUB_REGISTRATION_SCOPES" > "$registrations"
            grep -Fxq "${6:-user}" "$registrations" || exit 1
            grep -Fxv "${6:-user}" "$registrations" > "$registrations.next" || true
            mv "$registrations.next" "$registrations"
            printf 'removed %s\n' "${6:-user}" >> "${ARGV_LOG%/*}/successes"
            [ ! -s "$registrations" ] || exit 0
        fi
        [ -f "$mkt_state" ] || printf '%s\n' "${STUB_MARKETPLACES:-$default_mkt}" > "$mkt_state"
        jq --arg m "$4" '[.[] | select(.name != $m)]' "$mkt_state" > "$mkt_state.next"
        mv "$mkt_state.next" "$mkt_state"
        ;;
    'plugin marketplace add '*)
        if [[ -n "${STUB_REQUIRE_REPAIR_SCOPE:-}" ]]; then
            printf '%s\n' "${6:-user}" >> "${ARGV_LOG%/*}/repaired"
        fi
        ;;
    'plugin uninstall '*)
        if [[ -n "${STUB_REQUIRE_REPAIR_SCOPE:-}" && "${5:-user}" == "$STUB_REQUIRE_REPAIR_SCOPE" ]]; then
            grep -Fxq "$STUB_REQUIRE_REPAIR_SCOPE" "${ARGV_LOG%/*}/repaired" 2>/dev/null || exit 1
        fi
        if [[ "$3" == "good-b@mp" && -n "${SCOPE_MAP_WATCH:-}" && -n "${SCOPE_MAP_SNAPSHOT:-}" ]]; then
            cp "$SCOPE_MAP_WATCH" "$SCOPE_MAP_SNAPSHOT" 2>/dev/null || true
        fi
        if [ -f "$state" ]; then
            jq --arg id "$3" --arg scope "${5:-user}" '[.[] | select(.id != $id or .scope != $scope)]' \
                "$state" > "$state.next"
            mv "$state.next" "$state"
        fi
        ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/claude"

# Template: one marketplace, two true-flagged plugins, one false-flagged
# plugin (the HIMMEL-816 lean-profile shape — install-plugins.sh never
# installs it, so uninstall must never attempt it either).
TEMPLATE="$TMP/settings-template.json"
cat > "$TEMPLATE" <<'JSON'
{
  "enabledPlugins": {
    "good-a@mp": true,
    "good-b@mp": true,
    "lean-off@mp": false
  },
  "extraKnownMarketplaces": {
    "mp": { "source": { "source": "url", "url": "https://example.invalid/mp.json" } }
  }
}
JSON

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"; FAILED=$((FAILED + 1))
    fi
}

assert_has() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) echo "PASS $label" ;;
        *) echo "FAIL $label — output/log missing: $needle"; FAILED=$((FAILED + 1)) ;;
    esac
}

assert_not_has() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) echo "FAIL $label — unexpectedly present: $needle"; FAILED=$((FAILED + 1)) ;;
        *) echo "PASS $label" ;;
    esac
}

# ── 1. default scope (no --scope) -> every call carries --scope user ────────
: > "$ARGV_LOG"
out=$(PATH="$STUB_DIR:$PATH" ARGV_LOG="$ARGV_LOG" \
      bash "$script" --template "$TEMPLATE" 2>&1); rc=$?
log=$(cat "$ARGV_LOG")
assert_rc "default scope exits 0" 0 "$rc"
assert_has "default: uninstall good-a carries --scope user" "plugin uninstall good-a@mp --scope user" "$log"
assert_has "default: uninstall good-b carries --scope user" "plugin uninstall good-b@mp --scope user" "$log"
assert_has "default: marketplace remove carries --scope user" "plugin marketplace remove mp --scope user" "$log"
assert_not_has "default: false-flagged plugin never uninstalled" "lean-off@mp" "$log"
assert_not_has "default: the marketplace list is parseable (verified path, not the degraded one)" "cannot verify registered marketplaces" "$out"

# ── 2. --scope project -> every call carries --scope project ────────────────
: > "$ARGV_LOG"
out=$(PATH="$STUB_DIR:$PATH" ARGV_LOG="$ARGV_LOG" STUB_SCOPE=project \
      bash "$script" --template "$TEMPLATE" --scope project 2>&1); rc=$?
log=$(cat "$ARGV_LOG")
assert_rc "project scope exits 0" 0 "$rc"
assert_has "project: uninstall good-a carries --scope project" "plugin uninstall good-a@mp --scope project" "$log"
assert_has "project: uninstall good-b carries --scope project" "plugin uninstall good-b@mp --scope project" "$log"
assert_has "project: marketplace remove carries --scope project" "plugin marketplace remove mp --scope project" "$log"
assert_not_has "project: no call falls back to user scope" "--scope user" "$log"
assert_not_has "project: false-flagged plugin never uninstalled" "lean-off@mp" "$log"

# ── 6. HIMMEL-2733: on-demand union — a `false`-flagged entry LISTED in
#      onDemandPlugins is uninstalled too; a plain `false` entry absent from
#      it stays excluded (same lean-profile guarantee as case 4) ────────────
TEMPLATE_ONDEMAND="$TMP/settings-template-ondemand.json"
cat > "$TEMPLATE_ONDEMAND" <<'JSON'
{
  "enabledPlugins": {
    "good-a@mp": true,
    "ondemand-x@mp": false,
    "lean-off@mp": false
  },
  "extraKnownMarketplaces": {
    "mp": { "source": { "source": "url", "url": "https://example.invalid/mp.json" } }
  },
  "onDemandPlugins": {
    "ondemand-x@mp": { "neededBy": "test coverage" }
  }
}
JSON

# The earlier user-scope case consumed its inventory; seed this case separately.
rm -f "$TMP/plugins-user.json"
: > "$ARGV_LOG"
out=$(PATH="$STUB_DIR:$PATH" ARGV_LOG="$ARGV_LOG" \
      STUB_PLUGINS='[{"id":"good-a@mp","scope":"user"},{"id":"ondemand-x@mp","scope":"user"}]' \
      bash "$script" --template "$TEMPLATE_ONDEMAND" 2>&1); rc=$?
log=$(cat "$ARGV_LOG")
assert_rc "on-demand union exits 0" 0 "$rc"
assert_has "on-demand union: uninstalls the always-true plugin" "plugin uninstall good-a@mp --scope user" "$log"
assert_has "on-demand union: ALSO uninstalls the on-demand plugin" "plugin uninstall ondemand-x@mp --scope user" "$log"
assert_not_has "on-demand union: plain-false, non-on-demand entry stays excluded" "lean-off@mp" "$log"

# ── 3. invalid --scope -> exit 2, validation before preflight ───────────────
out=$(PATH="$STUB_DIR:$PATH" bash "$script" --template "$TEMPLATE" --scope bogus 2>&1); rc=$?
assert_rc "invalid scope exits 2" 2 "$rc"
assert_has "invalid scope names the diagnostic" "invalid --scope: bogus" "$out"

# ── 5. RED control: a FROZEN reproduction of the pre-HIMMEL-2694 call shape ──
# This is a frozen reproduction written by this test, NOT the historical
# file (no `git show HEAD:...`). A git-history read would only be correct
# until the parent commits this branch's fix — at that point
# `HEAD:scripts/machine-setup/uninstall-plugins.sh` IS the fixed script, so
# a "never passes --scope" assertion sourced from HEAD would silently flip
# to a false pass forever after, on every run, in CI and on every adopter
# clone. Freezing the pre-fix SHAPE inline instead — unfiltered
# `.enabledPlugins | keys[]` (every template key, true- and false-flagged
# alike) and bare `claude plugin uninstall "$SPEC"` /
# `claude plugin marketplace remove "$NAME"` calls with no --scope — means
# this control keeps proving the OLD bug regardless of what HEAD contains.
PRE_FIX="$TMP/pre-2694-uninstall-plugins.sh"
cat > "$PRE_FIX" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
TEMPLATE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --template) TEMPLATE="$2"; shift 2 ;;
    *) shift ;;
  esac
done
PLUGIN_SPECS="$(jq -r '.enabledPlugins | keys[]' "$TEMPLATE")"
MARKETPLACES="$(jq -r '.extraKnownMarketplaces | keys[]' "$TEMPLATE")"
while IFS= read -r SPEC; do
  [[ -z "$SPEC" ]] && continue
  claude plugin uninstall "$SPEC" || true
done <<EOF
$PLUGIN_SPECS
EOF
while IFS= read -r NAME; do
  [[ -z "$NAME" ]] && continue
  claude plugin marketplace remove "$NAME" || true
done <<EOF
$MARKETPLACES
EOF
SH
chmod +x "$PRE_FIX"

: > "$ARGV_LOG"
PATH="$STUB_DIR:$PATH" ARGV_LOG="$ARGV_LOG" \
    bash "$PRE_FIX" --template "$TEMPLATE" >/dev/null 2>&1
prelog=$(cat "$ARGV_LOG")
assert_has "RED: pre-2694 shape still uninstalls the true-flagged plugins" "plugin uninstall good-a@mp" "$prelog"
assert_has "RED: pre-2694 shape ALSO attempts the false-flagged plugin (31-vs-13 noise)" "plugin uninstall lean-off@mp" "$prelog"
assert_not_has "RED: pre-2694 shape NEVER passes --scope to any claude call" "--scope" "$prelog"

# ── 6. RED control (HIMMEL-2754): a standalone FULL run must honour scopes a
#       PRIOR halted run persisted into --scope-map, not just this run's own.
cat > "$TMP/settings-template-2mp.json" <<'JSON'
{
  "enabledPlugins": {
    "good-a@mp1": true,
    "good-b@mp2": true
  },
  "extraKnownMarketplaces": {
    "mp1": { "source": { "source": "url", "url": "https://example.invalid/mp1.json" } },
    "mp2": { "source": { "source": "url", "url": "https://example.invalid/mp2.json" } }
  }
}
JSON
printf 'mp2\tproject\t%s\n' "$(pwd -P)" > "$TMP/scope-map-prior"
# Start a fresh inventory after the earlier cases consumed the user seed.
rm -f "$TMP/plugins-user.json"
: > "$ARGV_LOG"
out=$(PATH="$STUB_DIR:$PATH" ARGV_LOG="$ARGV_LOG" \
      STUB_MARKETPLACES='[{"name":"mp1"},{"name":"mp2"}]' \
      STUB_PLUGINS='[{"id":"good-a@mp1","scope":"user"}]' \
      bash "$script" --template "$TMP/settings-template-2mp.json" --scope-map "$TMP/scope-map-prior" 2>&1); rc=$?
log=$(cat "$ARGV_LOG")
assert_rc "full run with a prior scope map exits 0" 0 "$rc"
assert_has "full run: this run's own plugin still carries --scope user" "plugin uninstall good-a@mp1 --scope user" "$log"
assert_has "full run: mp1 removed at this run's scope" "plugin marketplace remove mp1 --scope user" "$log"
assert_has "full run: mp2 removed at the PRIOR run's persisted project scope" "plugin marketplace remove mp2 --scope project" "$log"
assert_has "full run: mp2 also tries the install-profile scope (HIMMEL-2796)" "plugin marketplace remove mp2 --scope user" "$log"
map_scopes=$(cat "$TMP/scope-map-prior")
if printf '%s\n' "$map_scopes" | grep -qx "$(printf 'mp2\tproject\t%s' "$(pwd -P)")"; then
    echo "PASS full run: prior scope-map row survives"
else
    echo "FAIL full run: prior scope-map row lost"; FAILED=$((FAILED + 1))
fi

# ── 7. RED control 1a (HIMMEL-2754): unresolved selection must halt. ────────
cat > "$TMP/settings-template-malformed.json" <<'JSON'
{
  "enabledPlugins": {"good-a@mp": true},
  "extraKnownMarketplaces": {
    "mp": { "source": { "source": "url", "url": "https://example.invalid/mp.json" } }
  }
}
JSON
rm -f "$TMP/plugins-user.json"
: > "$ARGV_LOG"
out=$(PATH="$STUB_DIR:$PATH" ARGV_LOG="$ARGV_LOG" \
      STUB_PLUGINS='[{"id":"good-a@mp","scope":"project","projectPath":{"nested":1}}]' \
      bash "$script" --template "$TMP/settings-template-malformed.json" --plugins-only 2>&1); rc=$?
log=$(cat "$ARGV_LOG")
assert_rc "RED 1a: unresolved plugin selection exits 1" 1 "$rc"
assert_has "RED 1a: unresolved selection named" "could not determine which installed plugins are ours" "$out"
assert_not_has "RED 1a: no clean-phase summary" "0 failed call(s)" "$out"
assert_not_has "RED 1a: no plugin uninstall issued" "plugin uninstall" "$log"

# ── 8. RED control 1b (HIMMEL-2754): preview subtraction must halt too. ────
printf 'mp\tproject\t%s\n' "$(pwd -P)" > "$TMP/scope-map-preview"
rm -f "$TMP/plugins-user.json"
: > "$ARGV_LOG"
out=$(PATH="$STUB_DIR:$PATH" ARGV_LOG="$ARGV_LOG" \
      STUB_PLUGINS='[{"id":"good-a@mp","scope":"project","projectPath":{"nested":1}}]' \
      bash "$script" --template "$TMP/settings-template-malformed.json" \
      --dry-run --marketplaces-only --scope-map "$TMP/scope-map-preview" 2>&1); rc=$?
assert_rc "RED 1b: unresolved dry-run subtraction exits 1" 1 "$rc"
assert_not_has "RED 1b: never reaches the marketplace loop" "SKIP: marketplace" "$out"
assert_has "RED 1b: unresolved dry-run subtraction named" "could not compute the dry-run plugin subtraction" "$out"

# ── 9. RED control 2 (HIMMEL-2754): persisted scopes belong to a project. ─
mkdir -p "$TMP/other-project"
printf 'mp1\tproject\t%s\nmp2\tproject\t%s\n' \
    "$(pwd -P)" "$TMP/other-project" > "$TMP/scope-map-projects"
rm -f "$TMP/plugins-user.json"
: > "$ARGV_LOG"
out=$(PATH="$STUB_DIR:$PATH" ARGV_LOG="$ARGV_LOG" \
      STUB_PLUGINS='[]' STUB_MARKETPLACES='[{"name":"mp1"},{"name":"mp2"}]' \
      bash "$script" --template "$TMP/settings-template-2mp.json" \
      --marketplaces-only --scope-map "$TMP/scope-map-projects" 2>&1); rc=$?
log=$(cat "$ARGV_LOG")
assert_has "RED 2: current-project scope replayed" "plugin marketplace remove mp1 --scope project" "$log"
assert_not_has "RED 2: other-project scope never replayed" "plugin marketplace remove mp2 --scope project" "$log"
assert_has "RED 2: other-project row falls back to user scope" "plugin marketplace remove mp2 --scope user" "$log"

# ── 10. RED control 3 (HIMMEL-2754): scope-map writes bind project rows. ──
rm -f "$TMP/plugins-user.json"
: > "$ARGV_LOG"
out=$(PATH="$STUB_DIR:$PATH" ARGV_LOG="$ARGV_LOG" \
      STUB_PLUGINS="$(jq -nc --arg p "$(pwd -P)" '[{id:"good-a@mp",scope:"project",projectPath:$p}]')" \
      bash "$script" --template "$TMP/settings-template-malformed.json" \
      --plugins-only --scope-map "$TMP/scope-map-write" 2>&1); rc=$?
assert_rc "RED 3: project scope-map write exits 0" 0 "$rc"
if grep -qx "$(printf 'mp\tproject\t%s' "$(pwd -P)")" "$TMP/scope-map-write"; then
    echo "PASS RED 3: project scope-map row records the current project"
else
    echo "FAIL RED 3: project scope-map row missing the current project"; FAILED=$((FAILED + 1))
fi

rm -f "$TMP/plugins-user.json"
: > "$ARGV_LOG"
out=$(PATH="$STUB_DIR:$PATH" ARGV_LOG="$ARGV_LOG" \
      STUB_PLUGINS='[{"id":"good-a@mp","scope":"user"}]' \
      bash "$script" --template "$TMP/settings-template-malformed.json" \
      --plugins-only --scope-map "$TMP/scope-map-write-user" 2>&1); rc=$?
assert_rc "RED 3: user scope-map write exits 0" 0 "$rc"
if grep -qx "$(printf 'mp\tuser')" "$TMP/scope-map-write-user"; then
    echo "PASS RED 3: user scope-map row stays two fields"
else
    echo "FAIL RED 3: user scope-map row is not two fields"; FAILED=$((FAILED + 1))
fi

# ── 11. RED control 4 (HIMMEL-2754): legacy rows have no project identity. ─
printf 'mp1\tproject\n' > "$TMP/scope-map-legacy"
rm -f "$TMP/plugins-user.json"
: > "$ARGV_LOG"
out=$(PATH="$STUB_DIR:$PATH" ARGV_LOG="$ARGV_LOG" \
      STUB_PLUGINS='[]' STUB_MARKETPLACES='[{"name":"mp1"},{"name":"mp2"}]' \
      bash "$script" --template "$TMP/settings-template-2mp.json" \
      --marketplaces-only --scope-map "$TMP/scope-map-legacy" 2>&1); rc=$?
log=$(cat "$ARGV_LOG")
assert_not_has "RED 4: legacy project scope never replayed" "plugin marketplace remove mp1 --scope project" "$log"
assert_has "RED 4: legacy row falls back to user scope" "plugin marketplace remove mp1 --scope user" "$log"
assert_has "RED 4: legacy row diagnostic named" "carries no recorded project" "$out"

# ── 12. RED control 5 (HIMMEL-2754): persist before the next uninstall. ──
rm -f "$TMP/plugins-user.json"
: > "$ARGV_LOG"
out=$(PATH="$STUB_DIR:$PATH" ARGV_LOG="$ARGV_LOG" \
      SCOPE_MAP_WATCH="$TMP/scope-map-mid-loop" SCOPE_MAP_SNAPSHOT="$TMP/scope-map-snapshot" \
      bash "$script" --template "$TEMPLATE" --plugins-only \
      --scope-map "$TMP/scope-map-mid-loop" 2>&1); rc=$?
assert_rc "RED 5: two-plugin scope-map run exits 0" 0 "$rc"
if grep -Fxq "$(printf 'mp\tuser')" "$TMP/scope-map-snapshot" 2>/dev/null; then
    echo "PASS RED 5: first plugin scope persisted before second uninstall"
else
    echo "FAIL RED 5: first plugin scope missing before second uninstall"; FAILED=$((FAILED + 1))
fi

# ── 13. RED control 6 (HIMMEL-2754): decode a backslash in projectPath. ──
backslash_project="$TMP/"'project\name'
mkdir -p "$backslash_project"
backslash_plugins=$(jq -nc --arg p "$backslash_project" '[{id:"good-a@mp",scope:"project",projectPath:$p}]')
if [[ "$(printf '%s\n' "$backslash_plugins" | jq -r '.[0].projectPath')" == "$backslash_project" && -d "$backslash_project" ]]; then
    echo "PASS RED 6: fixture reports the created backslash directory"
else
    echo "FAIL RED 6: fixture does not report the created backslash directory"; FAILED=$((FAILED + 1))
fi
rm -f "$TMP/plugins-user.json"
: > "$ARGV_LOG"
out=$(cd -- "$backslash_project" && PATH="$STUB_DIR:$PATH" ARGV_LOG="$ARGV_LOG" \
      STUB_PLUGINS="$backslash_plugins" \
      bash "$script" --template "$TEMPLATE" --plugins-only 2>&1); rc=$?
log=$(cat "$ARGV_LOG")
assert_rc "RED 6: backslash project run exits 0" 0 "$rc"
assert_has "RED 6: backslash project plugin uninstalled" "plugin uninstall good-a@mp --scope project" "$log"

# ── 14. RED control 7 (HIMMEL-2754): failed writes preserve prior scopes. ──
mkdir -p "$TMP/scope-map-atomic"
printf 'mp2\tproject\t%s\n' "$(pwd -P)" > "$TMP/scope-map-atomic/map"
# The only awk invocation on this path is persist_scope_map's deduplication.
cat > "$STUB_DIR/awk" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$STUB_DIR/awk"
rm -f "$TMP/plugins-user.json"
: > "$ARGV_LOG"
out=$(PATH="$STUB_DIR:$PATH" ARGV_LOG="$ARGV_LOG" \
      STUB_PLUGINS='[{"id":"good-a@mp1","scope":"user"}]' \
      bash "$script" --template "$TMP/settings-template-2mp.json" \
      --plugins-only --scope-map "$TMP/scope-map-atomic/map" 2>&1); rc=$?
rm "$STUB_DIR/awk"
assert_has "RED 7: plugin uninstalled before failed map write" "plugin uninstall good-a@mp1 --scope user" "$(cat "$ARGV_LOG")"
if grep -Fxq "$(printf 'mp2\tproject\t%s' "$(pwd -P)")" "$TMP/scope-map-atomic/map"; then
    echo "PASS RED 7: failed scope-map write preserves prior row"
else
    echo "FAIL RED 7: failed scope-map write lost prior row"; FAILED=$((FAILED + 1))
fi

rm -f "$TMP/plugins-user.json"
: > "$ARGV_LOG"
out=$(PATH="$STUB_DIR:$PATH" ARGV_LOG="$ARGV_LOG" \
      STUB_PLUGINS='[{"id":"good-a@mp1","scope":"user"}]' \
      bash "$script" --template "$TMP/settings-template-2mp.json" \
      --plugins-only --scope-map "$TMP/scope-map-atomic/map" 2>&1); rc=$?
assert_rc "RED 7: normal scope-map write exits 0" 0 "$rc"
if [ "$(ls -A "$TMP/scope-map-atomic")" = map ]; then
    echo "PASS RED 7: scope-map directory has no leftover temp file"
else
    echo "FAIL RED 7: scope-map directory has a leftover temp file"; FAILED=$((FAILED + 1))
fi

# ── 15. RED control 10a (HIMMEL-2754): failed persist is recoverable. ─────
printf 'mp2\tproject\t%s\n' "$(pwd -P)" > "$TMP/scope-map-failed"
cat > "$STUB_DIR/awk" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$STUB_DIR/awk"
rm -f "$TMP/plugins-user.json"
: > "$ARGV_LOG"
out=$(PATH="$STUB_DIR:$PATH" ARGV_LOG="$ARGV_LOG" \
      STUB_PLUGINS='[{"id":"good-a@mp1","scope":"user"},{"id":"good-b@mp2","scope":"user"}]' \
      bash "$script" --template "$TMP/settings-template-2mp.json" \
      --plugins-only --scope-map "$TMP/scope-map-failed" 2>&1); rc=$?
log=$(cat "$ARGV_LOG")
rm "$STUB_DIR/awk"
assert_has "RED 10a: first plugin uninstalled before failed persist" "plugin uninstall good-a@mp1 --scope user" "$log"
assert_has "RED 10a: uninstall loop continues after failed persist" "plugin uninstall good-b@mp2 --scope user" "$log"
assert_rc "RED 10a: failed persist exits non-zero" 1 "$rc"
assert_has "RED 10a: recovery names the scope-map path" "writing these rows to $TMP/scope-map-failed by hand restores the handoff" "$out"
assert_has "RED 10a: recovery prints the unpersisted row" "$(printf 'mp1\tuser')" "$out"
assert_has "RED 10a: repeated persist failures count once" "Done: 1 failed call(s)" "$out"

# ── 16. RED control 10b (HIMMEL-2754): stale map cannot win. ──────────────
printf 'mp2\tproject\t%s\n' "$(pwd -P)" > "$TMP/scope-map-stale"
cat > "$STUB_DIR/awk" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$STUB_DIR/awk"
rm -f "$TMP/plugins-user.json"
: > "$ARGV_LOG"
out=$(PATH="$STUB_DIR:$PATH" ARGV_LOG="$ARGV_LOG" \
      STUB_MARKETPLACES='[{"name":"mp1"},{"name":"mp2"}]' \
      STUB_PLUGINS="$(jq -nc --arg p "$(pwd -P)" '[{id:"good-a@mp1",scope:"project",projectPath:$p}]')" \
      bash "$script" --template "$TMP/settings-template-2mp.json" --scope user \
      --scope-map "$TMP/scope-map-stale" 2>&1); rc=$?
log=$(cat "$ARGV_LOG")
rm "$STUB_DIR/awk"
assert_has "RED 10b: plugin removed at its installed scope" "plugin uninstall good-a@mp1 --scope project" "$log"
assert_has "RED 10b: mp1 removed at this run's plugin scope" "plugin marketplace remove mp1 --scope project" "$log"
assert_has "RED 10b: install-profile scope supplements the retained plugin scope (HIMMEL-2796)" "plugin marketplace remove mp1 --scope user" "$log"

# ── 17. RED control 11 (HIMMEL-2694): exclusive paths cannot traverse up. ──
cat > "$TMP/settings-template-segments.json" <<'JSON'
{
  "enabledPlugins": {},
  "extraKnownMarketplaces": {
    "escaped": {"source": {"source":"directory", "path":"<himmel-path>/../shared"}},
    "bounded": {"source": {"source":"directory", "path":"<himmel-path>/..shared"}}
  }
}
JSON
rm -f "$TMP/plugins-user.json"
: > "$ARGV_LOG"
out=$(PATH="$STUB_DIR:$PATH" ARGV_LOG="$ARGV_LOG" \
      STUB_MARKETPLACES='[{"name":"escaped"},{"name":"bounded"}]' \
      STUB_PLUGINS='[{"id":"unnamed@escaped","scope":"user"},{"id":"unnamed@bounded","scope":"user"}]' \
      bash "$script" --template "$TMP/settings-template-segments.json" --plugins-only 2>&1); rc=$?
log=$(cat "$ARGV_LOG")
assert_rc "RED 11: segment-bound run exits 0" 0 "$rc"
assert_not_has "RED 11: traversal marketplace leaves unnamed plugin installed" "plugin uninstall unnamed@escaped --scope user" "$log"
assert_has "RED 11: two-dot name remains exclusive" "plugin uninstall unnamed@bounded --scope user" "$log"

# ── 18. RED control 13 (HIMMEL-2694): trailing flags require a value. ─────
for flag in --scope --template --scope-map; do
    out=$(bash "$script" "$flag" 2>&1); rc=$?
    assert_rc "RED 13: trailing $flag exits 2" 2 "$rc"
    assert_has "RED 13: trailing $flag names the required value" "$flag requires a value" "$out"
    assert_not_has "RED 13: trailing $flag has no unbound variable" "unbound variable" "$out"
done

# ── 19. RED control 14 (HIMMEL-2694): absent project identity is not ours. ──
rm -f "$TMP/plugins-user.json"
: > "$ARGV_LOG"
out=$(PATH="$STUB_DIR:$PATH" ARGV_LOG="$ARGV_LOG" \
      STUB_PLUGINS='[{"id":"good-a@mp","scope":"project"},{"id":"good-b@mp","scope":"user"}]' \
      bash "$script" --template "$TEMPLATE" --plugins-only 2>&1); rc=$?
log=$(cat "$ARGV_LOG")
assert_rc "RED 14: missing project path run exits 0" 0 "$rc"
assert_not_has "RED 14: missing project path is never selected" "plugin uninstall good-a@mp --scope project" "$log"
assert_has "RED 14: user row is still uninstalled" "plugin uninstall good-b@mp --scope user" "$log"

# ── 20. RED control 15 (HIMMEL-2754): failed map read degrades the handoff. ──
printf 'mp2\tuser\n' > "$TMP/scope-map-unreadable"
# Path-scoped read failure also works under root, where chmod 000 would not.
cat > "$STUB_DIR/cat" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
    [[ "$arg" != "$UNREADABLE_MAP" ]] || exit 1
done
exec "$REAL_CAT" "$@"
STUB
chmod +x "$STUB_DIR/cat"
rm -f "$TMP/plugins-user.json"
: > "$ARGV_LOG"
out=$(PATH="$STUB_DIR:$PATH" ARGV_LOG="$ARGV_LOG" REAL_CAT="$REAL_CAT" \
      UNREADABLE_MAP="$TMP/scope-map-unreadable" \
      STUB_PLUGINS='[{"id":"good-a@mp","scope":"user"},{"id":"good-b@mp","scope":"user"}]' \
      bash "$script" --template "$TEMPLATE" --plugins-only \
      --scope-map "$TMP/scope-map-unreadable" 2>&1); rc=$?
rm "$STUB_DIR/cat"
assert_rc "RED 15: failed map read exits 1" 1 "$rc"
assert_has "RED 15: warning names map and lost prior scopes" "WARN: could not read prior scopes from $TMP/scope-map-unreadable — prior scopes are lost from the handoff" "$out"
assert_has "RED 15: replacement contains this run's row" "$(printf 'mp\tuser')" "$(cat "$TMP/scope-map-unreadable")"
assert_has "RED 15: repeated map read failures count once" "Done: 1 failed call(s)" "$out"

# ── 21. RED control 16 (HIMMEL-2754): repair every installed scope. ──────
jq '.extraKnownMarketplaces.mp.source = {source:"github",repo:"example/mp"}' \
    "$TEMPLATE" > "$TMP/settings-template-repair.json"
rm -f "$TMP/plugins-user.json"
: > "$ARGV_LOG"
out=$(PATH="$STUB_DIR:$PATH" ARGV_LOG="$ARGV_LOG" \
      STUB_MARKETPLACES='[]' \
      STUB_PLUGINS="$(jq -nc --arg p "$(pwd -P)" '[{id:"good-a@mp",scope:"project",projectPath:$p},{id:"good-b@mp",scope:"user"}]')" \
      bash "$script" --template "$TMP/settings-template-repair.json" --plugins-only 2>&1); rc=$?
log=$(cat "$ARGV_LOG")
assert_rc "RED 16: multi-scope repair run exits 0" 0 "$rc"
assert_has "RED 16: marketplace repaired at project scope" "plugin marketplace add example/mp --scope project" "$log"
assert_has "RED 16: marketplace repaired at user scope" "plugin marketplace add example/mp --scope user" "$log"
assert_rc "RED 16: exactly two marketplace adds" 2 "$(grep -c '^plugin marketplace add ' "$ARGV_LOG")"
assert_has "RED 16: project plugin uninstalled" "plugin uninstall good-a@mp --scope project" "$log"
assert_has "RED 16: user plugin uninstalled" "plugin uninstall good-b@mp --scope user" "$log"
assert_has "RED 16: transient marketplace removed at project scope" "plugin marketplace remove mp --scope project" "$log"
assert_has "RED 16: transient marketplace removed at user scope" "plugin marketplace remove mp --scope user" "$log"

# ── HIMMEL-2796: verify removal outcomes, not per-scope exit codes. ──────
for plugins in \
    "$(jq -nc --arg p "$(pwd -P)" '[{id:"good-a@mp",scope:"project",projectPath:$p}]')" \
    "$(jq -nc --arg p "$(pwd -P)" '[{id:"good-a@mp",scope:"project",projectPath:$p},{id:"good-b@mp",scope:"user"}]')"; do
    rm -f "$TMP/plugins-user.json"
    : > "$ARGV_LOG"
    out=$(PATH="$STUB_DIR:$PATH" ARGV_LOG="$ARGV_LOG" STUB_REGISTRATION_SCOPES=user \
          STUB_PLUGINS="$plugins" bash "$script" --template "$TEMPLATE" 2>&1); rc=$?
    log=$(cat "$ARGV_LOG")
    assert_rc "2796: mismatched/spanning plugin scopes exit cleanly" 0 "$rc"
    assert_has "2796: install-profile scope attempted" "plugin marketplace remove mp --scope user" "$log"
    assert_rc "2796: exactly one successful removal" 1 "$(wc -l < "$TMP/successes" 2>/dev/null)"
    assert_has "2796: no inflated failures" "Done: 0 failed call(s)" "$out"
done
rm -f "$TMP/plugins-user.json"
: > "$ARGV_LOG"
out=$(PATH="$STUB_DIR:$PATH" ARGV_LOG="$ARGV_LOG" STUB_REGISTRATION_SCOPES=user \
      STUB_REMOVE_FAIL=1 STUB_PLUGINS='[]' bash "$script" --template "$TEMPLATE" 2>&1); rc=$?
assert_rc "2796: genuinely stuck registration exits 1" 1 "$rc"
assert_has "2796: stuck registration warns" "WARN:" "$out"
assert_has "2796: stuck registration counted once" "Done: 1 failed call(s)" "$out"

rm -f "$TMP/plugins-user.json"
: > "$ARGV_LOG"
out=$(PATH="$STUB_DIR:$PATH" ARGV_LOG="$ARGV_LOG" STUB_REMOVE_NOOP=1 \
      STUB_PLUGINS='[]' bash "$script" --template "$TEMPLATE" 2>&1); rc=$?
assert_rc "2796: successful no-op cannot claim removal" 1 "$rc"
assert_has "2796: successful no-op reports observed registration" "still registered" "$out"

# ── HIMMEL-2804: repair a missing scope without borrowing existing state. ─
rm -f "$TMP/plugins-user.json"
: > "$ARGV_LOG"
out=$(PATH="$STUB_DIR:$PATH" ARGV_LOG="$ARGV_LOG" STUB_REQUIRE_REPAIR_SCOPE=project \
      STUB_PLUGINS="$(jq -nc --arg p "$(pwd -P)" '[{id:"good-a@mp",scope:"project",projectPath:$p},{id:"good-b@mp",scope:"user"}]')" \
      bash "$script" --template "$TMP/settings-template-repair.json" --plugins-only 2>&1); rc=$?
log=$(cat "$ARGV_LOG")
assert_rc "2804: partially registered marketplace uninstalls cleanly" 0 "$rc"
assert_has "2804: missing project scope repaired" "plugin marketplace add example/mp --scope project" "$log"
assert_not_has "2804: pre-existing marketplace never transiently removed" "plugin marketplace remove" "$log"
assert_rc "2804: no plugin remains after scoped repair" 0 "$(jq length "$TMP/plugins-user.json")"

rm -f "$TMP/plugins-user.json"
: > "$ARGV_LOG"
out=$(PATH="$STUB_DIR:$PATH" ARGV_LOG="$ARGV_LOG" \
      STUB_PLUGINS="$(jq -nc --arg p "$(pwd -P)" '[{id:"good-a@mp",scope:"project",projectPath:$p},{id:"good-b@mp",scope:"user"}]')" \
      bash "$script" --template "$TMP/settings-template-repair.json" --plugins-only 2>&1); rc=$?
log=$(cat "$ARGV_LOG")
assert_rc "2804: healthy registration uninstalls cleanly" 0 "$rc"
assert_not_has "2804: healthy registration needs no adds" "plugin marketplace add" "$log"
assert_not_has "2804: healthy registration needs no cleanup" "plugin marketplace remove" "$log"

# ── HIMMEL-2800: subtract only exact plugin rows recorded in the handoff. ─
printf 'mp\tuser\ngood-a@mp\tuser\n' > "$TMP/scope-map-partial"
for mode in wet dry; do
    rm -f "$TMP/plugins-user.json"
    : > "$ARGV_LOG"
    args=()
    [[ "$mode" != dry ]] || args+=(--dry-run)
    out=$(PATH="$STUB_DIR:$PATH" ARGV_LOG="$ARGV_LOG" \
          STUB_PLUGINS='[{"id":"good-b@mp","scope":"user"}]' \
          bash "$script" --template "$TEMPLATE" --marketplaces-only \
          --scope-map "$TMP/scope-map-partial" "${args[@]}" 2>&1); rc=$?
    assert_rc "2800: partial handoff blocks $mode run" 1 "$rc"
    assert_has "2800: partial handoff names remaining dependency in $mode run" "SKIP: marketplace mp" "$out"
done
rm -f "$TMP/plugins-user.json"
: > "$ARGV_LOG"
out=$(PATH="$STUB_DIR:$PATH" ARGV_LOG="$ARGV_LOG" STUB_PLUGINS='[]' \
      bash "$script" --template "$TEMPLATE" --marketplaces-only --dry-run \
      --scope-map "$TMP/scope-map-partial" 2>&1); rc=$?
assert_rc "2800: completed wet run previews cleanly" 0 "$rc"
assert_has "2800: completed wet run previews removal" "DRY: claude plugin marketplace remove mp" "$out"

rm -f "$TMP/plugins-user.json"
: > "$ARGV_LOG"
out=$(PATH="$STUB_DIR:$PATH" ARGV_LOG="$ARGV_LOG" STUB_PLUGINS='[{"id":"good-a@mp","scope":"user"}]' \
      bash "$script" --template "$TEMPLATE" --plugins-only --dry-run \
      --scope-map "$TMP/scope-map-simulated" 2>&1); rc=$?
assert_rc "2800: simulated plugin phase succeeds" 0 "$rc"
out=$(PATH="$STUB_DIR:$PATH" ARGV_LOG="$ARGV_LOG" \
      bash "$script" --template "$TEMPLATE" --marketplaces-only --dry-run \
      --scope-map "$TMP/scope-map-simulated" 2>&1); rc=$?
assert_rc "2800: complete simulated handoff previews cleanly" 0 "$rc"
assert_has "2800: complete simulated handoff previews removal" "DRY: claude plugin marketplace remove mp" "$out"

for map in none legacy; do
    printf 'mp\tuser\n' > "$TMP/scope-map-legacy-preview"
    args=()
    [[ "$map" != legacy ]] || args+=(--scope-map "$TMP/scope-map-legacy-preview")
    out=$(PATH="$STUB_DIR:$PATH" ARGV_LOG="$ARGV_LOG" \
          bash "$script" --template "$TEMPLATE" --marketplaces-only --dry-run "${args[@]}" 2>&1); rc=$?
    assert_rc "2800: $map handoff cannot hide installed plugins" 1 "$rc"
done

for recorded_scope in user project; do
    rm -f "$TMP/plugins-user.json"
    : > "$ARGV_LOG"
    printf 'mp\tuser\ngood-a@mp\t%s\t%s\n' "$recorded_scope" "$TMP/other-project" > "$TMP/scope-map-wrong-identity"
    out=$(PATH="$STUB_DIR:$PATH" ARGV_LOG="$ARGV_LOG" \
          STUB_PLUGINS="$(jq -nc --arg p "$(pwd -P)" '[{id:"good-a@mp",scope:"project",projectPath:$p}]')" \
          bash "$script" --template "$TEMPLATE" --marketplaces-only --dry-run \
          --scope-map "$TMP/scope-map-wrong-identity" 2>&1); rc=$?
    assert_rc "2800: wrong scope/project handoff ($recorded_scope) retains dependency" 1 "$rc"
done
rm -f "$TMP/plugins-user.json"
: > "$ARGV_LOG"
out=$(PATH="$STUB_DIR:$PATH" ARGV_LOG="$ARGV_LOG" \
      STUB_PLUGINS="$(jq -nc --arg p "$(pwd -P)" '[{id:"good-a@mp",scope:"project",projectPath:$p}]')" \
      bash "$script" --template "$TEMPLATE" --plugins-only --dry-run \
      --scope-map "$TMP/scope-map-project-simulated" 2>&1); rc=$?
assert_rc "2800: project plugin preview writes handoff" 0 "$rc"
out=$(PATH="$STUB_DIR:$PATH" ARGV_LOG="$ARGV_LOG" \
      bash "$script" --template "$TEMPLATE" --marketplaces-only --dry-run \
      --scope-map "$TMP/scope-map-project-simulated" 2>&1); rc=$?
assert_rc "2800: matching project handoff previews removal" 0 "$rc"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"; exit 0
else
    echo "$FAILED FAILURE(S)"; exit 1
fi
