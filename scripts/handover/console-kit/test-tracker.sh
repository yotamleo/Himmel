#!/usr/bin/env bash
# test-tracker.sh — HIMMEL-3954. Hermetic tests for tracker.py's outside-the-plan
# sections and the ledger's unplanned count: no "Closed by roadmap" section, park-ns
# closures render in "Parked / unplaced", and only OPEN unplanned tickets are counted.
# Synthetic plan dir + mirror under a mktemp dir; no real plan data, no network.
#
# PLATFORM GUARD: no .ps1 twin, by design. The console kit is Linux-only
# (see test-tick.sh); this suite renders one static page with python3.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/tracker-test.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
contains() {
    case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3')" ;; esac
}
not_contains() {
    case "$2" in *"$3"*) fail "$1 (found '$3')" ;; *) pass "$1" ;; esac
}

if ! command -v python3 >/dev/null 2>&1; then
    printf 'skip - python3 not available\n'
    exit 0
fi

plan="$W/plan"
mir="$W/mirror"
mkdir -p "$plan/stage1" "$plan/stage3" "$mir"
printf '%s\n' '{"main_sha_at_build":"abcdef123456"}' > "$plan/stage3/meta.json"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' version load_bugs load_enhancements load_features load_misc load_audit load_total est_legs \
    v1.0.1 0.1 0 0 0 0 0.1 1 > "$plan/stage3/versions.tsv"
printf '%s\t%s\t%s\t%s\n' key version layer effort_mid HIMMEL-1 v1.0.1 bugs 1 > "$plan/stage3/placement.tsv"
# HIMMEL-2 is parked by the roadmap, HIMMEL-3 is closed-by-roadmap (likely-fixed).
printf '%s\t%s\t%s\n' key close_flag close_evidence \
    HIMMEL-2 park-ns 'parked evidence text' \
    HIMMEL-3 likely-fixed 'fixed evidence text' > "$plan/stage3/closures.tsv"
printf '%s\t%s\n' key reason HIMMEL-4 'unplaced reason text' > "$plan/stage3/unplaced.tsv"
printf '%s\t%s\n' key theme HIMMEL-1 tooling > "$plan/stage1/C01.tsv"

# mk <n> <statusCategory> <fixVersions json> <title>
mk() {
    printf '%s\n' '---' "key: \"HIMMEL-$1\"" 'updated: "2026-09-30T10:00:00.000+0000"' "statusCategory: \"$2\"" \
        "fixVersions: $3" 'type: "Bug"' '---' "# HIMMEL-$1: $4" > "$mir/HIMMEL-$1.md"
}
mk 1 'To Do' '["v1.0.1"]' 'planned bug'
mk 2 'To Do' '[]' 'parked ticket'
mk 3 'To Do' '[]' 'likely fixed ticket'
mk 4 'To Do' '[]' 'unplaced ticket'
mk 5 'Done' '["v1.0.1"]' 'done unplanned'
mk 6 'To Do' '["v1.0.1"]' 'open unplanned'
mk 7 'In Progress' '["v1.0.1"]' 'active unplanned'

out="$W/out.html"
stdout="$(python3 "$HERE/tracker.py" --plan-dir "$plan" --out "$out" --luna-map "$W/luna-map.json" \
    --mirror-dir "$mir" --luna-root "$W/luna" 2>&1)"
render_rc=$?
html="$(cat "$out" 2>/dev/null)"
if [ "$render_rc" -eq 0 ]; then pass 'tracker.py exits 0'; else fail "tracker.py exited $render_rc"; fi

not_contains 'no Closed-by-roadmap section (HIMMEL-3954)' "$html" 'Closed by roadmap'
contains 'the park-ns key renders in the page data (HIMMEL-3954)' "$html" '"parked ticket"'
contains 'the park-ns evidence is the parked reason (HIMMEL-3954)' "$html" 'parked evidence text'
contains 'the unplaced row still renders' "$html" 'unplaced reason text'
not_contains 'a non-park closure is not rendered' "$html" 'fixed evidence text'
contains 'summary counts 2 unplaced (1 unplaced + 1 parked)' "$stdout" '2 unplaced'
# Done HIMMEL-5 is unplanned but not counted; open HIMMEL-6 and in-progress HIMMEL-7 are.
contains 'summary counts only open unplanned tickets (HIMMEL-3954)' "$stdout" ', 2 unplanned,'
contains 'the ledger JS counts only non-Done unplanned rows (HIMMEL-3954)' "$html" 'p[7]==2&&p[2]!=2'
contains 'the Done unplanned ticket still renders in its version tab data' "$html" '"done unplanned"'

printf '%s\n' "$fails failure(s)"
[ "$fails" -eq 0 ]
