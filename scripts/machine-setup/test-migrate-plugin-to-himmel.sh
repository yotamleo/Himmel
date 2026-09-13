#!/usr/bin/env bash
# Hermetic migration regression tests (HIMMEL-3039). Bash 3.2 compatible.
# CI discovers test-*.sh; every claude invocation uses a PATH stub and fixture.
# Platform guard (gitbash-only): POSIX bash 3.2+ / Git Bash on Windows.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/machine-setup/migrate-plugin-to-himmel.sh"
command -v jq >/dev/null || { echo 'FAIL: jq required'; exit 1; }
TMP="$(mktemp -d "$REPO_ROOT/.test-migrate.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/live project+wt"
export HIMMEL_INSTALLED_PLUGINS_JSON="$TMP/installed_plugins.json"
export MIGRATE_CALLS="$TMP/calls.jsonl" MIGRATE_SCOPE_HELP=0 MIGRATE_PROJECT_INSTALL_FAIL=0
export PATH="$TMP/bin:$PATH"
SPEC='plannotator-effective-html@effective-html'
SECOND_SPEC='second@effective-html'
LIVE="$TMP/live project+wt"
GONE="$TMP/deleted project+wt"

cat > "$TMP/bin/claude" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
jq -cn --arg cwd "$PWD" --args '{cwd:$cwd, argv:$ARGS.positional}' -- "$@" >> "$MIGRATE_CALLS"
case "$*" in
    'plugin uninstall --help')
        if [ "$MIGRATE_SCOPE_HELP" = 1 ]; then
            printf 'Options:\r\n  --scope <scope>  Installation scope\r\n'
        else
            echo 'Usage: plugin uninstall <plugin>'
        fi
        ;;
    'plugin uninstall '*)
        spec="$3"; scope=user
        if [ "$#" -gt 3 ]; then
            [ "$#" -eq 5 ] && [ "$4" = --scope ] && [ "$5" = project ]
            scope=project
        fi
        jq --arg spec "$spec" --arg scope "$scope" --arg cwd "$PWD" '
            .plugins[$spec] |= ((. // []) | map(select(
                (.scope == $scope and ($scope == "user" or .projectPath == $cwd)) | not)))
            | if .plugins[$spec] == [] then del(.plugins[$spec]) else . end
        ' "$HIMMEL_INSTALLED_PLUGINS_JSON" > "$HIMMEL_INSTALLED_PLUGINS_JSON.stub"
        mv "$HIMMEL_INSTALLED_PLUGINS_JSON.stub" "$HIMMEL_INSTALLED_PLUGINS_JSON"
        ;;
    'plugin install '*)
        scope=user
        if [ "$#" -gt 3 ]; then
            [ "$#" -eq 5 ] && [ "$4" = --scope ] && [ "$5" = project ]
            scope=project
            [ "$MIGRATE_PROJECT_INSTALL_FAIL" = 0 ] || exit 1
        fi
        jq --arg spec "$3" --arg scope "$scope" --arg cwd "$PWD" '
            .plugins[$spec] |= ((. // []) | map(select(
                (.scope == $scope and ($scope == "user" or .projectPath == $cwd)) | not)))
            | .plugins[$spec] += [if $scope == "project" then
                {scope:$scope,projectPath:$cwd} else {scope:$scope} end]
        ' "$HIMMEL_INSTALLED_PLUGINS_JSON" > "$HIMMEL_INSTALLED_PLUGINS_JSON.stub"
        mv "$HIMMEL_INSTALLED_PLUGINS_JSON.stub" "$HIMMEL_INSTALLED_PLUGINS_JSON"
        ;;
    'plugin marketplace remove effective-html') ;;
    *) echo "Unexpected stub command: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$TMP/bin/claude"

failures=0
check() {
    local label="$1"; shift
    if "$@" >/dev/null; then
        echo "PASS: $label"
    else
        echo "FAIL: $label"
        failures=$((failures + 1))
    fi
}
fixture() {
    rm -f "$HIMMEL_INSTALLED_PLUGINS_JSON".bak-*
    : > "$MIGRATE_CALLS"
    jq -n --arg spec "$SPEC" --arg project "$1" '{version:2, plugins:{
        ($spec):[{scope:"user"},
                 {scope:"project", projectPath:$project, installPath:"cached copy", version:"d95debbaef15"}],
        "unrelated@elsewhere":[{scope:"user"}]
    }}' > "$HIMMEL_INSTALLED_PLUGINS_JSON"
    cp "$HIMMEL_INSTALLED_PLUGINS_JSON" "$TMP/before.json"
}
has_removal() {
    jq -se 'any(.[]; .argv == ["plugin","marketplace","remove","effective-html"])' "$MIGRATE_CALLS" >/dev/null
}
source_absent() {
    jq -e --arg spec "$SPEC" '.plugins | has($spec) | not' "$HIMMEL_INSTALLED_PLUGINS_JSON" >/dev/null
}
run_case() {
    if ! bash "$SCRIPT" "$@" "$SPEC" > "$TMP/output" 2>&1; then
        cat "$TMP/output"
        echo 'FAIL: migration exited nonzero'
        failures=$((failures + 1))
    fi
}

echo '== user plus orphan project records =='
fixture "$GONE"
# Multiple orphans/specs ensure one backup; the project-only key must disappear.
jq --arg spec "$SPEC" --arg second "$SECOND_SPEC" --arg gone "$GONE/second" \
    '.plugins[$spec] += [{scope:"project",projectPath:$gone}]
     | .plugins[$second] = [{scope:"project",projectPath:$gone}]' \
    "$TMP/before.json" > "$HIMMEL_INSTALLED_PLUGINS_JSON"
cp "$HIMMEL_INSTALLED_PLUGINS_JSON" "$TMP/before.json"
run_case --apply "$SECOND_SPEC"
check 'source key removed after orphan cleanup' source_absent
# shellcheck disable=SC2016 # This variable belongs to jq.
check 'project-only source key removed' jq -e --arg spec "$SECOND_SPEC" \
    '.plugins | has($spec) | not' "$HIMMEL_INSTALLED_PLUGINS_JSON"
check 'orphaned marketplace removed' has_removal
set -- "$HIMMEL_INSTALLED_PLUGINS_JSON".bak-*
check 'exactly one registry backup matches' test "$#" -eq 1
check 'registry backup exists' test -f "$1"
check 'backup preserves registry before orphan cleanup' cmp -s "$TMP/before.json" "$1"
check 'unrelated plugin preserved' jq -e '.plugins["unrelated@elsewhere"] == [{scope:"user"}]' "$HIMMEL_INSTALLED_PLUGINS_JSON"

echo '== existing project without scoped CLI support =='
fixture "$LIVE"
run_case --apply
# shellcheck disable=SC2016 # These variables belong to jq.
check 'existing project record preserved' jq -e --arg spec "$SPEC" --arg live "$LIVE" \
    '.plugins[$spec] == [{scope:"project",projectPath:$live,installPath:"cached copy",version:"d95debbaef15"}]' "$HIMMEL_INSTALLED_PLUGINS_JSON"
check 'project keep notice printed' grep -Fq \
    "keep: $SPEC still installed at project scope in $LIVE — uninstall it from that project" "$TMP/output"
if has_removal; then check 'marketplace retained for existing project' false; else check 'marketplace retained for existing project' true; fi

echo '== dry-run preserves fixture bytes =='
fixture "$GONE"
run_case
check 'dry-run registry byte-identical' cmp -s "$TMP/before.json" "$HIMMEL_INSTALLED_PLUGINS_JSON"
check 'dry-run orphan notice printed' grep -Fq \
    "DRY: drop orphaned project-scope record $SPEC (projectPath gone: $GONE)" "$TMP/output"
check 'dry-run invokes no mutations' jq -se 'all(.[]; .argv == ["plugin","uninstall","--help"])' "$MIGRATE_CALLS"
set -- "$HIMMEL_INSTALLED_PLUGINS_JSON".bak-*
check 'dry-run creates no backup' test ! -e "$1"

echo '== existing project with scoped CLI support =='
fixture "$LIVE"
export MIGRATE_SCOPE_HELP=1
run_case --apply
# shellcheck disable=SC2016 # These variables belong to jq.
check 'scoped uninstall runs inside project with intact arguments' jq -se --arg live "$LIVE" --arg spec "$SPEC" \
    'any(.[]; .cwd == $live and .argv == ["plugin","uninstall",$spec,"--scope","project"])' "$MIGRATE_CALLS"
# shellcheck disable=SC2016 # These variables belong to jq.
check 'project install precedes scoped uninstall in project cwd' jq -se --arg live "$LIVE" --arg spec "$SPEC" \
    '[.[] | select(.cwd == $live and .argv[3:] == ["--scope","project"]) | .argv] ==
     [["plugin","install","plannotator-effective-html@himmel","--scope","project"],
      ["plugin","uninstall",$spec,"--scope","project"]]' "$MIGRATE_CALLS"
# shellcheck disable=SC2016 # This variable belongs to jq.
check 'target retains both project and user records' jq -e --arg live "$LIVE" \
    '.plugins["plannotator-effective-html@himmel"] == [{scope:"project",projectPath:$live},{scope:"user"}]' "$HIMMEL_INSTALLED_PLUGINS_JSON"
check 'scoped uninstall removes source key' source_absent
check 'marketplace removed after scoped uninstall' has_removal

echo '== failed project install preserves source =='
fixture "$LIVE"
export MIGRATE_PROJECT_INSTALL_FAIL=1
run_case --apply
check 'failed project install does not invoke scoped uninstall' jq -se \
    'all(.[]; .argv[0:2] != ["plugin","uninstall"] or .argv[3:] != ["--scope","project"])' "$MIGRATE_CALLS"
check 'failed project install prints keep notice naming project' grep -Fq \
    "keep: $SPEC still installed at project scope in $LIVE — project install failed" "$TMP/output"
# shellcheck disable=SC2016 # These variables belong to jq.
check 'failed project install preserves source project record' jq -e --arg spec "$SPEC" --arg live "$LIVE" \
    '.plugins[$spec] == [{scope:"project",projectPath:$live,installPath:"cached copy",version:"d95debbaef15"}]' "$HIMMEL_INSTALLED_PLUGINS_JSON"
if has_removal; then check 'marketplace retained after failed project install' false; else check 'marketplace retained after failed project install' true; fi
export MIGRATE_PROJECT_INSTALL_FAIL=0

echo '== scoped dry-run preserves fixture bytes =='
fixture "$LIVE"
run_case
check 'scoped dry-run registry byte-identical' cmp -s "$TMP/before.json" "$HIMMEL_INSTALLED_PLUGINS_JSON"
check 'scoped dry-run prints project install' grep -Fq \
    'DRY: claude plugin install plannotator-effective-html@himmel --scope project' "$TMP/output"
check 'scoped dry-run prints project uninstall' grep -Fq \
    "DRY: claude plugin uninstall $SPEC --scope project" "$TMP/output"
check 'scoped dry-run invokes no mutations' jq -se 'all(.[]; .argv == ["plugin","uninstall","--help"])' "$MIGRATE_CALLS"
set -- "$HIMMEL_INSTALLED_PLUGINS_JSON".bak-*
check 'scoped dry-run creates no backup' test ! -e "$1"

echo "$failures FAILURE(S)"
[ "$failures" -eq 0 ]
