#!/usr/bin/env bash
# test-tracker.sh — HIMMEL-3954. Hermetic tests for tracker.py's outside-the-plan
# sections and the ledger's unplanned count: no "Closed by roadmap" section, park-ns
# closures render in "Parked / unplaced", and only OPEN unplanned tickets are counted.
# HIMMEL-3957: row fields, legend, ledger wording, plan-sourced caps, Done off-plan
# work counting in its version, and distinct load / layer palettes.
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
mkdir -p "$plan/stage1" "$plan/stage2" "$plan/stage3" "$plan/tools/stage3" "$mir"
# write_meta <ticket cap> <total cap> — synthetic placement-rule notes in the plan's shapes (HIMMEL-3957).
write_meta() {
    printf '{"main_sha_at_build":"abcdef123456","notes":["effort S-eq: XS .44 S 1 M 2.2 L 5 XL 11.1; synthetic","load (bank) = committed: effort_mid x 0.009; plan-first: slice S-eq x 0.009","v2/v3 is deferred","first fit: earliest version whose ticket count < %s, layer load within cap and total load within %s"]}\n' \
        "$1" "$2" > "$plan/stage3/meta.json"
}
write_caps() {  # write_caps <bugs cap>
    printf '%s\n' '# synthetic placer' "CAPS = {'features': 0.10, 'bugs': $1, 'enhancements': 0.12, 'audit': 0.03, 'misc': 0.05}" \
        > "$plan/tools/stage3/place.py"
}
write_meta 20 0.6
write_caps 0.30
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' version load_bugs load_enhancements load_features load_misc load_audit load_total est_legs \
    v1.0.1 0.1 0 0 0 0 0.1 1 v2/v3 0 0 0 0 0 0 0 > "$plan/stage3/versions.tsv"
printf '%s\t%s\t%s\t%s\t%s\t%s\n' key version layer effort_mid commit slice_effort HIMMEL-1 v1.0.1 bugs 1 committed '' \
    > "$plan/stage3/placement.tsv"
printf '%s\t%s\t%s\n' key user_impact issue_plain HIMMEL-1 'operators lose the synthetic widget on restart' 'plain text' \
    > "$plan/stage1/C01.explain.tsv"
printf '%s\t%s\t%s\t%s\n' key readiness effort_low effort_high HIMMEL-1 3 M L > "$plan/stage2/C01.tsv"
# HIMMEL-2 is parked by the roadmap, HIMMEL-3 is closed-by-roadmap (likely-fixed).
printf '%s\t%s\t%s\n' key close_flag close_evidence \
    HIMMEL-2 park-ns 'parked evidence text' \
    HIMMEL-3 likely-fixed 'fixed evidence text' > "$plan/stage3/closures.tsv"
printf '%s\t%s\n' key reason HIMMEL-4 'unplaced reason text' > "$plan/stage3/unplaced.tsv"
printf '%s\t%s\t%s\n' key theme impact HIMMEL-1 tooling 4 > "$plan/stage1/C01.tsv"

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
render() {
    python3 "$HERE/tracker.py" --plan-dir "$plan" --out "$out" --luna-map "$W/luna-map.json" \
        --mirror-dir "$mir" --luna-root "$W/luna" "$@" 2>&1
}
stdout="$(render)"
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
contains 'the Done unplanned ticket still renders in its version tab data' "$html" '"done unplanned"'

# --- HIMMEL-3957: design pass.
# Ask 1: a row carries user impact, the effort range, readiness and impact (appended P columns).
contains 'a row carries user impact, effort range, readiness, impact (HIMMEL-3957)' "$html" \
    '"operators lose the synthetic widget on restart","M–L",3,4,""]'
contains 'the card labels readiness out of 4 (HIMMEL-3957)' "$html" '"ready "+p[11]+"/4"'
contains 'the card labels impact out of 5 (HIMMEL-3957)' "$html" '"impact "+p[12]+"/5"'
contains 'the notes chip is labelled vault notes (HIMMEL-3957)' "$html" '"vault notes ("'
not_contains 'the ambiguous notes: N label is gone (HIMMEL-3957)' "$html" '"notes: "'
# Ask 2: the legend names every scale.
contains 'the page has a legend (HIMMEL-3957)' "$html" 'How to read this page'
for s in 'Status' 'Readiness 0–4' 'Impact 1–5' 'Effort XS–XL' 'Layers' 'drift' 'off-plan' 'plan first' 'vault notes'; do
    contains "the legend names $s (HIMMEL-3957)" "$html" "<dt>$s"
done
contains 'the legend effort scale comes from the plan (HIMMEL-3957)' "$html" 'XS 0.44 · S 1 · M 2.2 · L 5 · XL 11.1'
# Ask 3: the ledger wording, built in Python (Done unplanned HIMMEL-5 counts in v1.0.1: ask 5).
contains 'the ledger names the running version with its progress; Done unplanned counts (HIMMEL-3957)' "$stdout" \
    'Running now: v1.0.1 — 1 of 4 done (25 %), 1 in progress, 2 to do.'
contains 'the ledger gives whole-train progress (HIMMEL-3957)' "$stdout" \
    'Whole v1.0.x train: 1 of 4 done (25 %), 1 in progress, 2 to do.'
contains 'the ledger names open unplanned work when non-zero (HIMMEL-3957)' "$stdout" \
    'Needs attention: 2 open tickets sit in a version but not in the plan.'
not_contains 'the ledger omits drift when it is zero (HIMMEL-3957)' "$stdout" 'drifted'
contains 'the page carries the same ledger (HIMMEL-3957)' "$html" 'Running now: v1.0.1 — 1 of 4 done (25 %)'
# Ask 5: a Done ticket with the version's fixVersion but no placement lands in the Done column.
contains 'the board keeps Done off-plan tickets (HIMMEL-3957)' "$html" 'return p[7]!=2||p[2]==2'
contains 'an off-plan chip marks them (HIMMEL-3957)' "$html" '"chip off","off-plan"'
# Ask 4: the capacity text comes from the plan, never a constant.
contains 'cap text: ticket cap from the plan (HIMMEL-3957)' "$html" 'at most 20 tickets'
contains 'cap text: total cap from the plan (HIMMEL-3957)' "$html" 'at most 0.6 bank of load'
contains 'cap text: layer caps from the plan (HIMMEL-3957)' "$html" 'bugs 0.30'
contains 'cap text: load derivation from the plan (HIMMEL-3957)' "$html" '× 0.009 bank'
not_contains 'the JS no longer hardcodes the cap (HIMMEL-3957)' "$html" 'CAP=0.6'
write_meta 15 0.45
write_caps 0.25
render >/dev/null
html2="$(cat "$out" 2>/dev/null)"
contains 'a changed ticket cap changes the text (HIMMEL-3957)' "$html2" 'at most 15 tickets'
contains 'a changed total cap changes the text (HIMMEL-3957)' "$html2" 'at most 0.45 bank of load'
contains 'a changed layer cap changes the text (HIMMEL-3957)' "$html2" 'bugs 0.25'
rm -f "$plan/tools/stage3/place.py"
printf '%s\n' '{"main_sha_at_build":"abcdef123456"}' > "$plan/stage3/meta.json"
render >/dev/null
html3="$(cat "$out" 2>/dev/null)"
contains 'a cap the plan does not record says so (HIMMEL-3957)' "$html3" 'not recorded in the plan'
write_meta 20 0.6
write_caps 0.30
# Ask 6: the two Overview charts draw from different palette tokens.
lc="${html#*function loadChart}"; lc="${lc%%function layerChart*}"
lb="${html#*function loadBar}"; lb="${lb%%function themeList*}"
contains 'the load chart uses the load palette (HIMMEL-3957)' "$lc" 'LD['
not_contains 'the load chart does not use the layer palette (HIMMEL-3957)' "$lc" 'LC['
not_contains 'the version load bar does not use the layer palette (HIMMEL-3957)' "$lb" 'LC['
contains 'the load palette is its own token set (HIMMEL-3957)' "$html" '--ld1:'
not_contains 'the load cap line is not the drift colour (HIMMEL-3957)' "$html" 'dashed var(--drift)'
contains 'a bar clipped by the load scale is marked (HIMMEL-3957)' "$lc" 'off the scale'
# With no running version (whole train done) the default tab is not labelled "running now".
not_contains 'no running version falls back without a running-now label (HIMMEL-3957)' "$html" 'var cur=D.CUR==null?LAST:D.CUR'
contains 'the default tab is chosen apart from the running version (HIMMEL-3957)' "$html" 'sel=cur==null?LAST:cur'
# The new plan inputs move the freshness fingerprint.
fp1="$(render --emit-fp)"
printf '%s\t%s\t%s\t%s\n' key readiness effort_low effort_high HIMMEL-1 4 M L > "$plan/stage2/C01.tsv"
fp2="$(render --emit-fp)"
if [ -n "$fp1" ] && [ "$fp1" != "$fp2" ]; then pass 'a stage2 change moves the fingerprint (HIMMEL-3957)'; else fail "a stage2 change left the fingerprint at '$fp1'"; fi
printf '%s\t%s\t%s\n' key user_impact issue_plain HIMMEL-1 'changed impact' 'plain' > "$plan/stage1/C01.explain.tsv"
fp3="$(render --emit-fp)"
if [ "$fp2" != "$fp3" ]; then pass 'an explain change moves the fingerprint (HIMMEL-3957)'; else fail "an explain change left the fingerprint at '$fp2'"; fi

printf '%s\n' "$fails failure(s)"
[ "$fails" -eq 0 ]
