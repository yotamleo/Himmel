#!/usr/bin/env bash
# Platform guard: bash suite for the shell uninstaller and its stateful CLI
# stub; no .ps1 twin because this tests the bash implementation directly.
# WHY (HIMMEL-2694/2754): installed scopes, safe marketplace removal, and
# repair must be measured against a stateful CLI, never the operator's CLI.
set -uo pipefail

CLI="$(cd "$(dirname "$0")" && pwd)/machine-setup/uninstall-plugins.sh"

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

assert_has() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) echo "PASS $label" ;;
        *)
            echo "FAIL $label — output missing: $needle"
            FAILED=$((FAILED + 1))
            ;;
    esac
}

assert_not_has() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*)
            echo "FAIL $label — output unexpectedly contains: $needle"
            FAILED=$((FAILED + 1))
            ;;
        *) echo "PASS $label" ;;
    esac
}


FAILED=0
TMP=$(mktemp -d "${TMPDIR:-/tmp}/uninstall-plugins-suite.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home"
export HOME="$TMP/home"
export CLAUDE_CALL_LOG="$TMP/claude.log"
export STUB_PLUGINS_JSON="$TMP/plugins.json"
export STUB_MARKETPLACES_JSON="$TMP/marketplaces.json"
export STUB_FAIL_IDS="" STUB_ADD_NAME="himmel"
cat > "$TMP/bin/claude" <<'STUB_EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CLAUDE_CALL_LOG"
json_list() {
    if [ ! -s "$1" ]; then echo '[]'
    elif [ "$(cat "$1")" = "DEGRADED" ]; then exit 1
    else cat "$1"
    fi
}
case "$*" in
    'plugin list --json') json_list "$STUB_PLUGINS_JSON" ;;
    'plugin marketplace list --json') json_list "$STUB_MARKETPLACES_JSON" ;;
    'plugin uninstall '* )
        [ "$#" -eq 5 ] && [ "$4" = '--scope' ] || exit 2
        if grep -qxF -- "$3" <<< "${STUB_FAIL_IDS:-}"; then exit 1; fi
        if [ "$(cat "$STUB_PLUGINS_JSON")" != DEGRADED ]; then
            jq --arg id "$3" --arg scope "$5" '[.[] | select(.id != $id or .scope != $scope)]' \
                "$STUB_PLUGINS_JSON" > "$STUB_PLUGINS_JSON.next"
            mv "$STUB_PLUGINS_JSON.next" "$STUB_PLUGINS_JSON"
        fi
        ;;
    'plugin marketplace remove '* )
        [ "$#" -eq 6 ] && [ "$5" = '--scope' ] || exit 2
        if grep -qxF -- "$4" <<< "${STUB_FAIL_IDS:-}"; then exit 1; fi
        jq --arg name "$4" '[.[] | select(.name != $name)]' \
            "$STUB_MARKETPLACES_JSON" > "$STUB_MARKETPLACES_JSON.next"
        mv "$STUB_MARKETPLACES_JSON.next" "$STUB_MARKETPLACES_JSON"
        ;;
    'plugin marketplace add '* )
        [ "$#" -eq 6 ] && [ "$5" = '--scope' ] || exit 2
        jq --arg name "${STUB_ADD_NAME:-himmel}" '. + [{name: $name}]' \
            "$STUB_MARKETPLACES_JSON" > "$STUB_MARKETPLACES_JSON.next"
        mv "$STUB_MARKETPLACES_JSON.next" "$STUB_MARKETPLACES_JSON"
        ;;
    *) exit 2 ;;
esac
STUB_EOF
chmod 755 "$TMP/bin/claude"
export PATH="$TMP/bin:$PATH"
TEMPLATE="$TMP/template.json"
cat > "$TEMPLATE" <<'JSON'
{
  "enabledPlugins": {
    "handover@himmel": true, "ops@himmel": true,
    "review@claude-plugins-official": true, "notes@obsidian-skills": true,
    "extra@himmel": true, "spare@himmel": true
  },
  "extraKnownMarketplaces": {
    "obsidian-skills": {"source": {"source":"github", "repo":"kepano/obsidian-skills"}},
    "himmel": {"source": {"source":"directory", "path":"<himmel-path>/marketplace"}},
    "claude-plugins-official": {"source": {"source":"github", "repo":"anthropics/claude-plugins-official"}}
  }
}
JSON
reset_case() {
    : > "$CLAUDE_CALL_LOG"
    printf '[]\n' > "$STUB_PLUGINS_JSON"
    printf '[{"name":"himmel"},{"name":"obsidian-skills"},{"name":"claude-plugins-official"}]\n' > "$STUB_MARKETPLACES_JSON"
    STUB_FAIL_IDS=""
}
run_case() {
    out=$(bash "$CLI" --template "$TEMPLATE" "$@" 2>&1); rc=$?
    calls=$(cat "$CLAUDE_CALL_LOG")
}

# P1 — RED HIMMEL-2694: template-at-user ignored the installed scope.
reset_case
jq -n --arg p "$PWD" '["handover@himmel", "notes@obsidian-skills", "review@claude-plugins-official"]
    | map({id:., scope:"project", projectPath:$p})' > "$STUB_PLUGINS_JSON"
run_case
assert_rc "P1 project plugins removed" 0 "$rc"
for spec in handover@himmel notes@obsidian-skills review@claude-plugins-official; do
    assert_has "P1 $spec uses project scope" "plugin uninstall $spec --scope project" "$calls"
    assert_not_has "P1 $spec never uninstalls at user scope" "plugin uninstall $spec --scope user" "$calls"
done
assert_has "P1 marketplace also tries install-profile scope (HIMMEL-2796)" 'plugin marketplace remove himmel --scope user' "$calls"

# WHY (HIMMEL-2694): local installs belong to their physical project too.
reset_case
mkdir -p "$TMP/local-other"
jq -n --arg here "$PWD" --arg other "$TMP/local-other" '[
    {id:"handover@himmel",scope:"local",projectPath:$here},
    {id:"ops@himmel",scope:"local",projectPath:$other}
]' > "$STUB_PLUGINS_JSON"
run_case --plugins-only
if [ "$rc" -eq 0 ] && grep -qxF 'plugin uninstall handover@himmel --scope local' <<< "$calls" &&
    ! grep -qF 'plugin uninstall ops@himmel' <<< "$calls"; then
    echo 'ok - P1b local selection keeps other projects and removes current project'
else
    echo 'FAIL - P1b: local selection crossed projects or missed current project'; FAILED=$((FAILED + 1))
fi

# P2 — RED HIMMEL-2694: never-installed template entries are notes, not calls.
reset_case
printf '[{"id":"handover@himmel","scope":"user"},{"id":"ops@himmel","scope":"user"}]\n' > "$STUB_PLUGINS_JSON"
run_case
assert_rc "P2 clean subset exits 0" 0 "$rc"
assert_rc "P2 exactly two uninstalls" 2 "$(grep -c '^plugin uninstall ' "$CLAUDE_CALL_LOG")"
assert_rc "P2 four absent-template notes" 4 "$(printf '%s\n' "$out" | grep -c 'note: .* — not installed, nothing to remove')"
assert_has "P2 roll-up" '2 installed plugin(s) targeted; 4 template entry(ies) not installed' "$out"

# P3 — RED HIMMEL-2754: a failed plugin must retain its marketplace.
reset_case
printf '[{"id":"handover@himmel","scope":"user"},{"id":"ops@himmel","scope":"user"}]\n' > "$STUB_PLUGINS_JSON"
STUB_FAIL_IDS='ops@himmel'
run_case
assert_rc "P3 failed plugin exits 1" 1 "$rc"
assert_has "P3 dependent marketplace blocked" 'SKIP: marketplace himmel' "$out"
assert_not_has "P3 marketplace not stranded" 'plugin marketplace remove himmel' "$calls"
assert_has "P3 independent marketplace removed" 'plugin marketplace remove obsidian-skills' "$calls"

# P4 — RED HIMMEL-2754: re-add before uninstall; remove the transient on EXIT.
reset_case
printf '[{"id":"handover@himmel","scope":"user"}]\n' > "$STUB_PLUGINS_JSON"
printf '[]\n' > "$STUB_MARKETPLACES_JSON"
run_case
assert_rc "P4 repair succeeds" 0 "$rc"
add_line=$(grep -n '^plugin marketplace add ' "$CLAUDE_CALL_LOG" | cut -d: -f1)
uninstall_line=$(grep -n '^plugin uninstall handover@himmel ' "$CLAUDE_CALL_LOG" | cut -d: -f1)
if [ -n "$add_line" ] && [ -n "$uninstall_line" ] && [ "$add_line" -lt "$uninstall_line" ]; then
    echo 'PASS P4 repair precedes uninstall'
else
    echo 'FAIL P4 repair did not precede uninstall'; FAILED=$((FAILED + 1))
fi
assert_has "P4 transient removed" 'plugin marketplace remove himmel --scope user' "$calls"
assert_has "P4 cleanup reported" 'repair: removed transient marketplace himmel' "$out"

# WHY (HIMMEL-2754): cleanup residue must propagate to the caller.
reset_case
printf '[{"id":"handover@himmel","scope":"user"}]\n' > "$STUB_PLUGINS_JSON"
printf '[]\n' > "$STUB_MARKETPLACES_JSON"
STUB_FAIL_IDS='himmel'
run_case
if [ "$rc" -ne 0 ] && grep -qF 'WARN: could not remove transient marketplace himmel' <<< "$out"; then
    echo 'ok - P4b transient cleanup failure exits nonzero and warns'
else
    echo 'FAIL - P4b: transient cleanup failure did not exit nonzero and warn'; FAILED=$((FAILED + 1))
fi

# P5 — RED HIMMEL-2754: degraded enumeration blocks even when all uninstalls succeed.
reset_case
printf 'DEGRADED\n' > "$STUB_PLUGINS_JSON"
run_case
assert_rc "P5 successful degraded uninstalls still block marketplaces" 1 "$rc"
assert_has "P5 fallback warning" "WARN: \`claude plugin list --json\` unavailable — falling back to the template set at scope user (HIMMEL-2694)" "$out"
assert_rc "P5 all six template plugins attempted" 6 "$(grep -c '^plugin uninstall .* --scope user$' "$CLAUDE_CALL_LOG")"
for spec in handover@himmel ops@himmel review@claude-plugins-official notes@obsidian-skills extra@himmel spare@himmel; do
    assert_has "P5 $spec uses user scope" "plugin uninstall $spec --scope user" "$calls"
done
assert_not_has "P5 no marketplace removals" 'plugin marketplace remove' "$calls"
assert_has "P5 skip names enumeration failure" 'SKIP: marketplace himmel — cannot verify remaining plugins (enumeration unavailable); removing it could strand plugins (HIMMEL-2754)' "$out"

# P5b — RED HIMMEL-2754: degraded enumeration plus a failed plugin never strands.
reset_case
printf 'DEGRADED\n' > "$STUB_PLUGINS_JSON"
STUB_FAIL_IDS='handover@himmel'
run_case
assert_rc "P5b failed degraded run exits 1" 1 "$rc"
assert_not_has "P5b no marketplace removals" 'plugin marketplace remove' "$calls"
assert_has "P5b skip names the cause" 'SKIP: marketplace himmel — cannot verify remaining plugins (enumeration unavailable); removing it could strand plugins (HIMMEL-2754)' "$out"

# WHY (HIMMEL-2754): a separate process has no successful plugin phase evidence.
reset_case
printf 'DEGRADED\n' > "$STUB_PLUGINS_JSON"
run_case --marketplaces-only
if [ "$rc" -eq 1 ] && ! grep -qF 'plugin marketplace remove' <<< "$calls" &&
    grep -qF 'SKIP: marketplace himmel — cannot verify remaining plugins (enumeration unavailable); removing it could strand plugins (HIMMEL-2754)' <<< "$out" &&
    ! grep -qF 'proceeding with marketplace removal' <<< "$out"; then
    echo 'ok - P5c degraded marketplaces-only refuses unverified removal'
else
    echo 'FAIL - P5c: degraded marketplaces-only removed without plugin-phase evidence'; FAILED=$((FAILED + 1))
fi

# P6 — RED HIMMEL-2754: phases can be split around settings/hooks teardown.
reset_case
printf '[{"id":"handover@himmel","scope":"user"}]\n' > "$STUB_PLUGINS_JSON"
run_case --plugins-only
assert_rc "P6 plugins-only exits 0" 0 "$rc"
assert_has "P6 plugins-only uninstalls" 'plugin uninstall handover@himmel' "$calls"
assert_not_has "P6 plugins-only keeps marketplaces" 'plugin marketplace remove' "$calls"
reset_case
run_case --marketplaces-only
assert_rc "P6 marketplaces-only exits 0" 0 "$rc"
assert_has "P6 marketplaces-only removes" 'plugin marketplace remove himmel' "$calls"
assert_not_has "P6 marketplaces-only never uninstalls" 'plugin uninstall' "$calls"
run_case --plugins-only --marketplaces-only
assert_rc "P6 conflicting phases rejected" 2 "$rc"

# P7 — dry-run remains mutation-free (already true before these fixes).
reset_case
printf '[{"id":"handover@himmel","scope":"user"}]\n' > "$STUB_PLUGINS_JSON"
run_case --dry-run
assert_has "P7 dry-run prints commands" 'DRY:' "$out"
assert_not_has "P7 no uninstall mutation" 'plugin uninstall' "$calls"
assert_not_has "P7 no marketplace mutation" 'plugin marketplace remove' "$calls"

# WHY (HIMMEL-2754): previews discount selected plugins, including split phases.
for preview_case in P7b P7c; do
    reset_case
    printf '[{"id":"handover@himmel","scope":"user"}]\n' > "$STUB_PLUGINS_JSON"
    if [ "$preview_case" = P7b ]; then
        preview_label="full dry-run"
        run_case --dry-run
    else
        preview_label="marketplaces-only dry-run with handoff"
        run_case --plugins-only --dry-run --scope-map "$TMP/preview-scope-map"
        assert_rc "P7c simulated plugin phase writes exact handoff" 0 "$rc"
        run_case --marketplaces-only --dry-run --scope-map "$TMP/preview-scope-map"
    fi
    if [ "$rc" -eq 0 ] && ! grep -qF 'SKIP:' <<< "$out" &&
        grep -qF 'DRY: claude plugin marketplace remove himmel' <<< "$out" &&
        ! grep -qF 'plugin marketplace remove' <<< "$calls"; then
        echo "ok - $preview_case $preview_label previews marketplace removal"
    else
        echo "FAIL - $preview_case: $preview_label blocked marketplace preview"; FAILED=$((FAILED + 1))
    fi
done
reset_case
jq -n --arg p "$(pwd -P)" '[{id:"handover@himmel",scope:"project",projectPath:$p}]' > "$STUB_PLUGINS_JSON"
run_case --dry-run
preview_rc=$rc
mkdir -p "$TMP/dry-other"
jq -n --arg here "$PWD" --arg other "$TMP/dry-other" '[
    {id:"handover@himmel",scope:"project",projectPath:$here},
    {id:"handover@himmel",scope:"project",projectPath:$other}
]' > "$STUB_PLUGINS_JSON"
run_case --dry-run
if [ "$preview_rc" -eq 0 ] && [ "$rc" -eq 1 ] && grep -qF 'SKIP: marketplace himmel' <<< "$out" &&
    ! grep -qF 'DRY: claude plugin marketplace remove himmel' <<< "$out"; then
    echo 'ok - P7d dry-run discounts current project but keeps other-project blocker'
else
    echo 'FAIL - P7d: dry-run did not distinguish current and other projects'; FAILED=$((FAILED + 1))
fi

# P7e — standalone marketplace previews cannot assume a plugin phase ran.
reset_case
printf '[{"id":"handover@himmel","scope":"user"}]\n' > "$STUB_PLUGINS_JSON"
printf '[{"name":"himmel"}]\n' > "$STUB_MARKETPLACES_JSON"
run_case --marketplaces-only --dry-run
assert_rc "P7e standalone marketplace preview blocks" 1 "$rc"
assert_has "P7e installed dependency blocks preview" 'SKIP: marketplace himmel — 1 plugin(s) sourced from it are still installed' "$out"
assert_not_has "P7e dependent marketplace removal not previewed" 'DRY: claude plugin marketplace remove' "$out"
assert_not_has "P7e preview makes no marketplace removals" 'plugin marketplace remove' "$calls"

# WHY (HIMMEL-2694): canonical project filtering and de-duplication must not
# remove another project's copy or an unrelated marketplace's plugin.
reset_case
mkdir -p "$TMP/other-project"
ln -s "$PWD" "$TMP/project-link"
jq -n --arg here "$PWD" --arg alias "$TMP/project-link" --arg other "$TMP/other-project" --arg gone "$TMP/gone" '[
    {id:"handover@himmel",scope:"project",projectPath:$here},
    {id:"handover@himmel",scope:"project",projectPath:$alias},
    {id:"ops@himmel",scope:"project",projectPath:$other},
    {id:"extra@himmel",scope:"project",projectPath:$gone},
    {id:"foreign@unowned",scope:"user"},
    {id:"disabled@himmel",scope:"local",projectPath:$here,enabled:false}
]' > "$STUB_PLUGINS_JSON"
run_case --plugins-only
assert_rc "canonical selection exits 0" 0 "$rc"
assert_rc "canonical selection targets two unique pairs" 2 "$(grep -c '^plugin uninstall ' "$CLAUDE_CALL_LOG")"
assert_has "disabled installed plugin still targeted" 'plugin uninstall disabled@himmel --scope local' "$calls"
assert_not_has "other project untouched" 'plugin uninstall ops@himmel' "$calls"
assert_not_has "missing project untouched" 'plugin uninstall extra@himmel' "$calls"
assert_not_has "unowned plugin untouched" 'plugin uninstall foreign@unowned' "$calls"

# WHY (HIMMEL-2754): failed plugins still require transient cleanup even in
# --plugins-only; EXIT must retain the original failure code.
reset_case
jq -n --arg p "$(pwd -P)" '[{id:"handover@himmel",scope:"project",projectPath:$p}]' > "$STUB_PLUGINS_JSON"
printf '[]\n' > "$STUB_MARKETPLACES_JSON"
STUB_FAIL_IDS='handover@himmel'
run_case --plugins-only
assert_rc "failed repair run preserves rc" 1 "$rc"
assert_has "failed repair run cleans transient" 'plugin marketplace remove himmel --scope project' "$calls"

# P8 — a retry must merge its scopes into the handoff without duplicate rows.
P8_TEMPLATE="$TMP/p8-template.json"
cat > "$P8_TEMPLATE" <<'JSON'
{
  "enabledPlugins": {"a@m1": true, "b@m2": true},
  "extraKnownMarketplaces": {
    "m1": {"source": {"source":"github", "repo":"example/m1"}},
    "m2": {"source": {"source":"github", "repo":"example/m2"}}
  }
}
JSON
TEMPLATE="$P8_TEMPLATE"
P8_SCOPE_MAP="$TMP/p8-scope-map"
printf 'm1\tproject\n' > "$P8_SCOPE_MAP"
reset_case
printf '[{"id":"b@m2","scope":"user"}]\n' > "$STUB_PLUGINS_JSON"
printf '[{"name":"m1"},{"name":"m2"}]\n' > "$STUB_MARKETPLACES_JSON"
run_case --plugins-only --scope-map "$P8_SCOPE_MAP"
assert_rc "P8 first retry merge exits 0" 0 "$rc"
assert_rc "P8 preserves prior project scope" 1 "$(grep -xcF $'m1\tproject' "$P8_SCOPE_MAP")"
assert_rc "P8 records new user scope" 1 "$(grep -xcF $'m2\tuser' "$P8_SCOPE_MAP")"
printf '[{"id":"b@m2","scope":"user"}]\n' > "$STUB_PLUGINS_JSON"
run_case --plugins-only --scope-map "$P8_SCOPE_MAP"
assert_rc "P8 duplicate retry exits 0" 0 "$rc"
assert_rc "P8 deduplicates repeated scope record" 1 "$(grep -xcF $'m2\tuser' "$P8_SCOPE_MAP")"
printf 'm1\tproject\nm2\tuser\nb@m2\tuser\n' > "$TMP/p8-expected-scope-map"
cmp -s "$TMP/p8-expected-scope-map" "$P8_SCOPE_MAP"; p8_map_rc=$?
assert_rc "P8 keeps prior records before current records" 0 "$p8_map_rc"

# P9 — shared-marketplace plugins not named by the template belong to the user.
TEMPLATE="$TMP/template.json"
reset_case
printf '[{"id":"personal@claude-plugins-official","scope":"user"}]\n' > "$STUB_PLUGINS_JSON"
run_case --plugins-only
assert_rc "P9 foreign plugin exits 0" 0 "$rc"
assert_not_has "P9 foreign plugin never uninstalled" 'plugin uninstall personal@claude-plugins-official' "$calls"
assert_has "P9 foreign plugin noted" "  note: personal@claude-plugins-official — installed from claude-plugins-official but not named by himmel's template; left installed" "$out"

# P10 — retaining the user's marketplace is successful teardown, not a block.
reset_case
printf '[{"id":"personal@claude-plugins-official","scope":"user"}]\n' > "$STUB_PLUGINS_JSON"
# WHY (HIMMEL-2754): even an erroneous uninstall must leave the foreign row
# present so this independently exposes the old marketplace-blocking branch.
STUB_FAIL_IDS='personal@claude-plugins-official'
run_case
assert_rc "P10 foreign dependency exits 0" 0 "$rc"
assert_has "P10 foreign marketplace kept" '  keep: marketplace claude-plugins-official' "$out"
assert_not_has "P10 foreign marketplace never removed" 'plugin marketplace remove claude-plugins-official' "$calls"
assert_has "P10 no blocked marketplaces" '0 blocked marketplace removal(s)' "$out"

# P11 — an owned plugin that fails removal must still block its marketplace.
reset_case
printf '[{"id":"review@claude-plugins-official","scope":"user"},{"id":"personal@claude-plugins-official","scope":"user"}]\n' > "$STUB_PLUGINS_JSON"
STUB_FAIL_IDS='review@claude-plugins-official'
run_case
assert_rc "P11 owned failure exits 1" 1 "$rc"
assert_has "P11 owned uninstall attempted" 'plugin uninstall review@claude-plugins-official --scope user' "$calls"
assert_has "P11 owned dependency blocks marketplace" 'SKIP: marketplace claude-plugins-official' "$out"
assert_not_has "P11 blocked marketplace never removed" 'plugin marketplace remove claude-plugins-official' "$calls"
assert_has "P11 one blocked marketplace" '1 blocked marketplace removal(s)' "$out"

# P12 — one marketplace must be removed at every recorded plugin scope.
TEMPLATE="$TMP/p12-template.json"
cat > "$TEMPLATE" <<'JSON'
{
  "enabledPlugins": {"a@m1": true, "b@m1": true},
  "extraKnownMarketplaces": {
    "m1": {"source": {"source":"github", "repo":"example/m1"}}
  }
}
JSON
reset_case
jq -n --arg p "$(pwd -P)" '[{id:"a@m1",scope:"project",projectPath:$p},{id:"b@m1",scope:"user"}]' > "$STUB_PLUGINS_JSON"
printf '[{"name":"m1"}]\n' > "$STUB_MARKETPLACES_JSON"
run_case
assert_rc "P12 both scopes exit 0" 0 "$rc"
assert_rc "P12 marketplace removed once at project scope" 1 "$(grep -xcF 'plugin marketplace remove m1 --scope project' "$CLAUDE_CALL_LOG")"
assert_rc "P12 marketplace removed once at user scope" 1 "$(grep -xcF 'plugin marketplace remove m1 --scope user' "$CLAUDE_CALL_LOG")"

echo ""
if [ "$FAILED" -eq 0 ]; then echo 'ALL PASS'; else echo "$FAILED FAILURE(S)"; fi
exit $((FAILED > 0))
