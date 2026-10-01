#!/usr/bin/env bash
# test-tracker.sh — HIMMEL-3954. Hermetic tests for tracker.py's outside-the-plan
# sections and the ledger's unplanned count: no "Closed by roadmap" section, park-ns
# closures render in "Parked / unplaced", and only OPEN unplanned tickets are counted.
# HIMMEL-3957: row fields, legend, ledger wording, plan-sourced caps, Done off-plan
# work counting in its version, and distinct load / layer palettes.
# HIMMEL-3990: the redesign — rows lead with user impact, numbers drill down, a
# remaining-only switch, live legs; tracker-model-check.js runs the page's model.
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
# write_meta <ticket cap> <total cap> [extra json members] — synthetic placement-rule notes in the plan's shapes (HIMMEL-3957).
write_meta() {
    printf '{"main_sha_at_build":"abcdef123456","notes":["effort S-eq: XS .44 S 1 M 2.2 L 5 XL 11.1; synthetic","load (bank) = committed: effort_mid x 0.009; plan-first: slice S-eq x 0.009","v2/v3 is deferred","first fit: earliest version whose ticket count < %s, layer load within cap and total load within %s"]%s}\n' \
        "$1" "$2" "${3:-}" > "$plan/stage3/meta.json"
}
write_caps() {  # write_caps <bugs cap>
    printf '%s\n' '# synthetic placer' "CAPS = {'features': 0.10, 'bugs': $1, 'enhancements': 0.12, 'audit': 0.03, 'misc': 0.05}" \
        > "$plan/tools/stage3/place.py"
}
write_meta 20 0.6
write_caps 0.30
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' version load_bugs load_enhancements load_features load_misc load_audit load_total est_legs \
    v1.0.1 0.1 0 0 0 0 0.1 1 v2/v3 0 0 0 0 0 0 0 > "$plan/stage3/versions.tsv"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' key version layer effort_mid commit slice_effort reason \
    HIMMEL-1 v1.0.1 bugs 1 committed '' 'P1; pinned to v1.0.1 (ruling)' > "$plan/stage3/placement.tsv"
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
contains 'a ticket the plan pins to its version is listed as pinned (HIMMEL-3990)' "$html" '"PIN":[1]'
not_contains 'a non-park closure is not rendered' "$html" 'fixed evidence text'
contains 'summary counts 2 unplaced (1 unplaced + 1 parked)' "$stdout" '2 unplaced'
# Done HIMMEL-5 is unplanned but not counted; open HIMMEL-6 and in-progress HIMMEL-7 are.
contains 'summary counts only open unplanned tickets (HIMMEL-3954)' "$stdout" ', 2 unplanned,'
contains 'the Done unplanned ticket still renders in its version tab data' "$html" '"done unplanned"'

# --- HIMMEL-3957: design pass.
# Ask 1: a row carries user impact, the effort range, readiness, impact, issue_plain and its load (P columns).
contains 'a row carries user impact, effort range, readiness, impact, plain issue, load (HIMMEL-3990)' "$html" \
    '"operators lose the synthetic widget on restart","M–L",3,4,"","plain text",0.009]'
contains 'the row leads with the user impact (HIMMEL-3990)' "$html" 'add(tx,impactText(p,el("span","ui")),sub)'
contains 'readiness reads in words (HIMMEL-3990)' "$html" '"fix named, not yet checked"'
contains 'impact is a secondary 5-dot tag (HIMMEL-3990)' "$html" '"impact "+n+" of 5"'
contains 'the notes list is labelled vault notes (HIMMEL-3990)' "$html" 'Vault notes that mention it:'
# Ask 2: the terms name every scale.
for s in 'Status' 'Leg chip' 'Size' 'Impact' 'Ready to build' 'Budget' 'No cap' 'Remaining only'; do
    contains "the terms name $s (HIMMEL-3990)" "$html" "[\"$s\","
done
contains 'the size scale comes from the plan (HIMMEL-3957)' "$html" 'XS 0.44 · S 1 · M 2.2 · L 5 · XL 11.1'
# Ask 3: the ledger wording, built in Python (Done unplanned HIMMEL-5 counts in v1.0.1: ask 5).
contains 'the ledger names the running version with its progress; Done unplanned counts (HIMMEL-3957)' "$stdout" \
    'Running now: v1.0.1 — 1 of 4 done (25 %), 1 in progress, 2 to do.'
contains 'the ledger gives whole-train progress (HIMMEL-3957)' "$stdout" \
    'Whole v1.0.x train: 1 of 4 done (25 %), 1 in progress, 2 to do.'
contains 'the ledger names open unplanned work when non-zero (HIMMEL-3957)' "$stdout" \
    'Needs attention: 2 open tickets sit in a version but not in the plan.'
not_contains 'the ledger omits drift when it is zero (HIMMEL-3957)' "$stdout" 'drifted'
contains 'the page data carries the same ledger (HIMMEL-3957)' "$html" 'Running now: v1.0.1 — 1 of 4 done (25 %)'
# Ask 5: a Done off-plan ticket still counts in its version; off-plan work adds no budget.
contains 'off-plan tickets add no budget (HIMMEL-3990)' "$html" 'function ld(p){return p[7]==2?0:(p[15]||0)}'
contains 'off-plan tickets are named in words (HIMMEL-3990)' "$html" '"Not in the plan: Jira puts it in "'
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
# HIMMEL-3990: the page contract — tokens for both themes, phone layout, keyboard-reachable drill-downs.
contains 'dark tokens follow the system (HIMMEL-3990)' "$html" '@media (prefers-color-scheme:dark){:root:not([data-theme="light"])'
contains 'dark tokens follow the toggle (HIMMEL-3990)' "$html" ':root[data-theme="dark"]{'
contains 'the phone layout has its own rules (HIMMEL-3990)' "$html" '@media (max-width:560px)'
contains 'every number is a button (HIMMEL-3990)' "$html" 'var b=el("button","n",label);b.type="button";'
contains 'the drill-down is a modal dialog (HIMMEL-3990)' "$html" 'role="dialog" aria-modal="true"'
contains 'Escape closes the drill-down (HIMMEL-3990)' "$html" 'if(e.key=="Escape"){e.preventDefault();closeDrill();return}'
contains 'closing returns focus to the number (HIMMEL-3990)' "$html" 'opener.focus()'
contains 'the pulse respects reduced motion (HIMMEL-3990)' "$html" '@media (prefers-reduced-motion:no-preference)'
contains 'caps are tested by null, never truthiness: a cap of 0 is a cap (HIMMEL-3957)' "$html" 'cap==null?null:r4(cap-u)'
contains 'the dashboard renders tiles, the decisions menu, the version rail and the board (HIMMEL-3990)' "$html" 'renderTiles();renderDecisions(ds);renderRail();renderBoard();renderAcc();renderThemes();renderGains()'
not_contains 'the rail is the only version overview: no column chart (HIMMEL-3990)' "$html" 'renderChart'
contains 'the dark theme is the Watchfloor hull (HIMMEL-3990)' "$html" '--bg:#0b1120'
contains 'a status legend names the hollow circle (HIMMEL-3990)' "$html" '["todo","not started"]'
contains 'the decisions open with a per-band summary (HIMMEL-3990)' "$html" 'function decSummary(ds)'
contains 'gains name work done ahead of schedule (HIMMEL-3990)' "$html" '"Also done ahead of schedule: "'
contains 'a wide screen gets a side column (HIMMEL-3990)' "$html" '@media (min-width:1500px)'
contains 'the budget rules say what a bank is (HIMMEL-3990)' "$html" 'Bank = '
not_contains 'the steer panel waits for the UI phase (HIMMEL-3990)' "$html" 'renderSteer'
contains 'a done card says what it took against its estimate (HIMMEL-3990)' "$html" '"est "+(p[10]||"?")+" · took "+pl(ac[0],"leg","legs")'
contains 'the decisions open as a menu from the masthead (HIMMEL-3990)' "$html" 'aria-controls="decp"'
contains 'a lever words its console instruction (HIMMEL-3990)' "$html" 'lines.push("open trail "+toName)'
contains 'a nested drill keeps the first opener (HIMMEL-3990)' "$html" '"drawer").hidden)opener=from;'
# The new plan inputs move the freshness fingerprint; each render must itself succeed (HIMMEL-3979).
# fp_ok <label> <var> -- render --emit-fp into <var>, failing the test when the render exits non-zero.
fp_ok() {
    local o rc
    o="$(render --emit-fp)"
    rc=$?
    if [ "$rc" -eq 0 ]; then pass "$1: --emit-fp exits 0 (HIMMEL-3979)"; else fail "$1: --emit-fp exited $rc"; fi
    printf -v "$2" '%s' "$o"
}
fp1='' fp2='' fp3='' fp4='' fp5='' fp6='' fp7=''  # each set by fp_ok through printf -v
fp_ok 'base' fp1
printf '%s\t%s\t%s\t%s\n' key readiness effort_low effort_high HIMMEL-1 4 M L > "$plan/stage2/C01.tsv"
fp_ok 'stage2 edit' fp2
if [ -n "$fp1" ] && [ "$fp1" != "$fp2" ]; then pass 'a stage2 change moves the fingerprint (HIMMEL-3957)'; else fail "a stage2 change left the fingerprint at '$fp1'"; fi
printf '%s\t%s\t%s\n' key user_impact issue_plain HIMMEL-1 'changed impact' 'plain' > "$plan/stage1/C01.explain.tsv"
fp_ok 'explain edit' fp3
if [ "$fp2" != "$fp3" ]; then pass 'an explain change moves the fingerprint (HIMMEL-3957)'; else fail "an explain change left the fingerprint at '$fp2'"; fi

# --- HIMMEL-3979: neutral swatch for no-cap load, per-version caps from the plan's overrides.
contains 'no-cap load has its own neutral token (HIMMEL-3979)' "$html" '--ldn:'
contains 'the legend names the no-cap swatch (HIMMEL-3979)' "$html" '"no cap — deferred bucket"'
printf '%s\n' "VERSION_CAP_OVERRIDES = {'v1.0.1': {'tickets': 30, 'bugs': 0.45}}" > "$plan/tools/stage3/common.py"
render >/dev/null
html4="$(cat "$out" 2>/dev/null)"
contains 'a version cap override sets that version ticket cap (HIMMEL-3979)' "$html4" '"VC":[{"t":30,'
contains 'a version cap override sets that version layer cap (HIMMEL-3979)' "$html4" '"l":[0.45,'
contains 'the cap text names the override (HIMMEL-3979)' "$html4" 'v1.0.1 holds at most 30 tickets'
contains 'the deferred bucket has no caps (HIMMEL-3979)' "$html4" '},null]'
fp_ok 'override edit' fp4
if [ "$fp3" != "$fp4" ]; then pass 'a cap override change moves the fingerprint (HIMMEL-3979)'; else fail 'a cap override change left the fingerprint'; fi
# Multi-line dict literals parse too, as the old [^}]* pattern allowed for CAPS.
printf '%s\n' '# synthetic placer' 'CAPS = {' "    'features': 0.10, 'bugs': 0.33," "    'enhancements': 0.12, 'audit': 0.03, 'misc': 0.05," '}' \
    > "$plan/tools/stage3/place.py"
printf '%s\n' 'VERSION_CAP_OVERRIDES = {' "    'v1.0.1': {'tickets': 31}," '}' > "$plan/tools/stage3/common.py"
render >/dev/null
html5="$(cat "$out" 2>/dev/null)"
contains 'a multi-line CAPS literal still sets the layer caps (HIMMEL-3990)' "$html5" '"l":[0.33,'
contains 'a multi-line override literal still sets the ticket cap (HIMMEL-3990)' "$html5" '"VC":[{"t":31,'
write_caps 0.30
printf '%s\n' "VERSION_CAP_OVERRIDES = {'v1.0.1': {'tickets': 30, 'bugs': 0.45}}" > "$plan/tools/stage3/common.py"

# --- HIMMEL-3990 ask 5: a live leg marks its ticket in progress, with its label and phase.
hb="$W/luna/handovers"
bk="$hb/yotamleo/himmel"
mkdir -p "$bk" "$hb/.locks/queue/live.lock" "$hb/.locks/queue/gone.lock" "$hb/.locks/queue/brief.lock"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '%s\n' '# leg' '- brief: follows PR 1999' '## Results' '- 10:00 LIVE — started' '- 10:20 LIVE — PR 1525 open, watching CI' '- a later note naming PR 1998' >"$bk/HIMMEL-1-N55-synthetic-leg-2026-10-01.md"
printf '%s\n' '# leg' '## Results' '- 09:00 READY 1600 abc GREEN' '- 09:30 WRAPPED — merged' > "$bk/HIMMEL-6-N56-wrapped-leg-2026-10-01.md"
printf '%s\n' '# leg' '## Results' '- 08:00 LIVE — started' > "$bk/HIMMEL-7-N57-released-leg-2026-10-01.md"
printf '%s\n' '# leg' '## Results' '- 08:00 LIVE — started' '- 12:00 LIVE — back after a night' '- 12:10 WRAPPED — merged' > "$bk/HIMMEL-6-N60-second-leg-2026-10-01.md"
printf '%s\n' '# leg' '- READY 1997 abc GREEN is the shape to send' '## Results' '- a note, no marker' > "$bk/HIMMEL-9-N59-brief-leg-2026-10-01.md"
printf '{"session":"s3","handover":"%s","heartbeat":"%s"}\n' "$bk/HIMMEL-9-N59-brief-leg-2026-10-01.md" "$now" > "$hb/.locks/queue/brief.lock/owner.json"
printf '{"session":"s1","handover":"%s","heartbeat":"%s"}\n' "$bk/HIMMEL-1-N55-synthetic-leg-2026-10-01.md" "$now" > "$hb/.locks/queue/live.lock/owner.json"
printf '{"session":"s2","handover":"%s","heartbeat":"%s"}\n' "$bk/HIMMEL-6-N56-wrapped-leg-2026-10-01.md" "$now" > "$hb/.locks/queue/gone.lock/owner.json"
fp_ok 'legs added' fp5
stdout6="$(render)"
html6="$(cat "$out" 2>/dev/null)"
cp "$out" "$W/legs.html"
contains 'a held-lock leg doc marks its ticket live with label, phase and PR (HIMMEL-3990)' "$html6" '"LEG":{"1":["N55","LIVE",1525]'
not_contains 'a WRAPPED leg is not live even while its lock lingers (HIMMEL-3990)' "$html6" '"6":["N56"'
not_contains 'a leg doc with no held lock is not live (HIMMEL-3990)' "$html6" '"7":["N57"'
contains 'a marker-shaped brief bullet above Results sets neither phase nor PR (HIMMEL-3990)' "$html6" '"9":["N59","LIVE",null]'
contains 'a wrapped leg counts toward what its ticket took; a gap over 3 h is idle (HIMMEL-3990)' "$html6" '"ACT":{"6":[2,40]}'
contains 'the live leg counts its ticket in progress in the ledger (HIMMEL-3990)' "$stdout6" '1 of 4 done (25 %), 2 in progress, 1 to do.'
if [ "$fp4" != "$fp5" ]; then pass 'a leg starting moves the fingerprint (HIMMEL-3990)'; else fail 'a leg starting left the fingerprint'; fi
printf '%s\n' '- 10:40 READY 1525 abc GREEN' >> "$bk/HIMMEL-1-N55-synthetic-leg-2026-10-01.md"
fp_ok 'leg phase moved' fp6
if [ "$fp5" != "$fp6" ]; then pass 'a leg phase change moves the fingerprint (HIMMEL-3990)'; else fail 'a leg phase change left the fingerprint'; fi
fp_ok 'leg phase unchanged' fp7
if [ "$fp6" = "$fp7" ]; then pass 'the fingerprint is stable when nothing moved (HIMMEL-3990)'; else fail 'the fingerprint moved with no input change'; fi
rm -rf "$hb/.locks/queue/live.lock"
render >/dev/null
not_contains 'a released lock clears the live leg (HIMMEL-3990)' "$(cat "$out")" '"1":["N55"'

# --- HIMMEL-3990 expansion: trail versions (<version>b, c, ...) and the effort model's P90 (cautious load).
# versions.tsv lists them out of order on purpose; the plan's order is v1.0.1 < v1.0.1b < v1.0.2 < v1.0.10.
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' version load_bugs load_enhancements load_features load_misc load_audit load_total est_legs \
    v1.0.2 0 0 0 0 0 0 0 v1.0.1b 0.01 0 0 0 0 0.01 1 v1.0.10 0 0 0 0 0 0 0 v1.0.1 0.1 0 0 0 0 0.1 1 v2/v3 0 0 0 0 0 0 0 \
    > "$plan/stage3/versions.tsv"
printf '%s\t%s\t%s\t%s\t%s\t%s\n' key version layer effort_mid commit slice_effort HIMMEL-1 v1.0.1 bugs 1 committed '' \
    HIMMEL-8 v1.0.1b bugs 1 committed '' > "$plan/stage3/placement.tsv"
mk 8 'To Do' '["v1.0.1b"]' 'planned trail bug'
mk 11 'To Do' '["v1.0.1b"]' 'trail unplanned'
write_meta 20 0.6 ',"effort_model":{"p90_cap":0.8},"version_p90_fw":{"v1.0.1":0.7,"v1.0.1b":0.05}'
render >/dev/null
html7="$(cat "$out" 2>/dev/null)"
contains 'trail versions sort after their parent, numerically (HIMMEL-3990)' "$html7" '"V":["v1.0.1","v1.0.1b","v1.0.2","v1.0.10","v2/v3"]'
contains 'a trail inherits its parent override (HIMMEL-3990)' "$html7" \
    '"VC":[{"t":30,"tot":0.6,"l":[0.45,0.12,0.1,0.05,0.03],"p9":0.8},{"t":30,"tot":0.6,"l":[0.45,0.12,0.1,0.05,0.03],"p9":0.8},{"t":20,'
contains 'a Jira fixVersion naming a trail counts in that trail (HIMMEL-3990)' "$html7" '[11,"trail unplanned",0,1,'
contains 'the cap text says a trail keeps its parent caps (HIMMEL-3990)' "$html7" 'takes the overflow of v1.0.1 and keeps its caps'
contains 'the page carries each version P90 (HIMMEL-3990)' "$html7" '"VP":[0.7,0.05,null,null,null]'
contains 'the cap text names the cautious-load cap (HIMMEL-3990)' "$html7" 'cautious load'
contains 'the drawer words P90 as cautious load (HIMMEL-3990)' "$html7" '"Cautious load "'
printf '%s\n' "VERSION_CAP_OVERRIDES = {'v1.0.1': {'tickets': 30, 'bugs': 0.45}, 'v1.0.1b': {'tickets': 5}}" > "$plan/tools/stage3/common.py"
render >/dev/null
contains 'a trail named in the overrides takes only its own (HIMMEL-3990)' "$(cat "$out")" '},{"t":5,"tot":0.6,"l":[0.3,'
printf '%s\n' "VERSION_CAP_OVERRIDES = {'v1.0.1': {'tickets': 30, 'bugs': 0.45}}" > "$plan/tools/stage3/common.py"
# Effort model B words its rules differently and carries the bank rate in effort_model.
printf '%s\n' '{"main_sha_at_build":"abcdef123456","effort_model":{"p90_cap":0.8,"bank_per_seq":0.009},"notes":["effort S-eq: XS .44 S 1 M 2.2 L 5 XL 11.1; synthetic","load (bank) = median x exp(sigma^2/2) x 0.009 bank per S-eq (the log-normal MEAN)","a version holds < 18 tickets, layer load within cap, total mean load within 0.55 and P90 within the model cap"]}' \
    > "$plan/stage3/meta.json"
# Under model B a plan-first row's effort_mid already holds its slice mean (XS 0.44 plus overrun = 0.49).
printf '%s\t%s\t%s\t%s\t%s\t%s\n' key version layer effort_mid commit slice_effort HIMMEL-1 v1.0.1 bugs 1 committed '' \
    HIMMEL-8 v1.0.1b bugs 0.49 plan-first XS > "$plan/stage3/placement.tsv"
render >/dev/null
html8="$(cat "$out" 2>/dev/null)"
contains 'model B: a plan-first row loads the placer slice mean, as the placer sums it (HIMMEL-3990)' "$html8" '"XS","",0.0044]'
contains 'model B wording: the ticket cap (HIMMEL-3990)' "$html8" 'at most 18 tickets'
contains 'model B wording: the mean load cap (HIMMEL-3990)' "$html8" 'at most 0.55 bank of load'
contains 'model B wording: the bank rate, overruns included (HIMMEL-3990)' "$html8" 'overruns included, × 0.009 bank'
contains 'model B wording: a row loads its mean effort (HIMMEL-3990)' "$html8" '"changed impact","M–L",4,4,"","plain",0.009]'
write_meta 20 0.6

# --- HIMMEL-3990: the page's model — drill-downs, budget by kind and ticket, summaries, remaining-only.
if command -v node >/dev/null 2>&1; then
    mo="$(node "$HERE/tracker-model-check.js" "$W/legs.html" 2>&1)"
    printf '%s\n' "$mo" | grep -v 'failure(s)$'
    if printf '%s\n' "$mo" | grep -qx '0 failure(s)'; then pass 'the model checks pass (HIMMEL-3990)'; else fail 'the model checks pass (HIMMEL-3990)'; fi
else
    printf 'skip - node not available: model checks\n'
fi

printf '%s\n' "$fails failure(s)"
[ "$fails" -eq 0 ]
