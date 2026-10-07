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

# mk <n> <statusCategory> <fixVersions json> <title> [status name]; writes into $mdir. A status name is the Jira status
# (HIMMEL-3990); without one the frontmatter has no `status:` line and the page falls back to the category.
mdir="$mir"
mk() {
    {
        printf '%s\n' '---' "key: \"HIMMEL-$1\"" 'updated: "2026-09-30T10:00:00.000+0000"' "statusCategory: \"$2\""
        [ -n "${5:-}" ] && printf 'status: "%s"\n' "$5"
        printf '%s\n' "fixVersions: $3" 'type: "Bug"' '---' "# HIMMEL-$1: $4"
    } > "$mdir/HIMMEL-$1.md"
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
        --mirror-dir "$mir" --luna-root "$W/luna" --handovers "$W/luna/handovers/tester/himmel" "$@" 2>&1
}
stdout="$(render)"
render_rc=$?
html="$(cat "$out" 2>/dev/null)"
if [ "$render_rc" -eq 0 ]; then pass 'tracker.py exits 0'; else fail "tracker.py exited $render_rc"; fi

# HIMMEL-4468: every file tracker.py writes ends in exactly one newline (luna's end-of-file-fixer rewrites it otherwise).
for f in "$W/luna-map.json" "$out" "$out.fp"; do
    if [ -s "$f" ] && [ "$(tail -c 1 "$f" | od -An -tx1 | tr -d ' ')" = '0a' ] \
        && [ "$(tail -c 2 "$f" | od -An -tx1 | tr -d ' ')" != '0a0a' ]; then
        pass "$(basename "$f") ends in exactly one newline (HIMMEL-4468)"
    else
        fail "$(basename "$f") does not end in exactly one newline (HIMMEL-4468)"
    fi
done
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
for s in 'Status' 'Leg chip' 'Size' 'Impact' 'Ready to build' 'Budget' 'No cap' 'Hide done work'; do
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
contains 'light tokens follow the system (HIMMEL-3990)' "$html" '@media (prefers-color-scheme:light){:root:not([data-theme="dark"])'
contains 'light tokens follow the toggle (HIMMEL-3990)' "$html" ':root[data-theme="light"]{'
contains 'the phone layout has its own rules (HIMMEL-3990)' "$html" '@media (max-width:560px)'
contains 'every number is a button (HIMMEL-3990)' "$html" 'var b=el("button","n",label);b.type="button";'
contains 'the drill-down is a modal dialog (HIMMEL-3990)' "$html" 'role="dialog" aria-modal="true"'
contains 'Escape closes the drill-down (HIMMEL-3990)' "$html" 'if(e.key=="Escape"){e.preventDefault();closeDrill();return}'
contains 'closing returns focus to the number (HIMMEL-3990)' "$html" 'opener.focus()'
contains 'the pulse respects reduced motion (HIMMEL-3990)' "$html" '@media (prefers-reduced-motion:no-preference)'
contains 'caps are tested by null, never truthiness: a cap of 0 is a cap (HIMMEL-3957)' "$html" 'cap==null?null:r4(cap-u)'
not_contains 'the page has no column chart (HIMMEL-3990)' "$html" 'renderChart'
contains 'the status legend names the five Jira statuses (HIMMEL-3990)' "$html" '["todo","To Do"],["prog","In Progress"],["rev","In Review"],["ci","IN CI"],["done","Done"]'
not_contains 'the steer panel waits for the UI phase (HIMMEL-3990)' "$html" 'renderSteer'
contains 'the estimate-vs-actual fold shows each size against what finished work took (HIMMEL-3990)' "$html" 'fmtMin(x.med)+" · "+pl(x.legs,"leg","legs")'
contains 'the plan decisions sit in a folded section (HIMMEL-3990)' "$html" '<details class="fold" id="pdec"><summary id="decs">'
contains 'a lever words its console instruction (HIMMEL-3990)' "$html" 'lines.push("open trail "+toName)'
contains 'a nested drill keeps the first opener (HIMMEL-3990)' "$html" '"drawer").hidden)opener=from;'
# The new plan inputs move the freshness fingerprint; each render must itself succeed (HIMMEL-3979).
# fp_ok <label> <var> [render args] -- render --emit-fp into <var>, failing the test when the render exits non-zero.
fp_ok() {
    local o rc
    o="$(render --emit-fp "${@:3}")"
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
bk="$hb/tester/himmel"
mkdir -p "$bk" "$hb/.locks/queue/live.lock" "$hb/.locks/queue/gone.lock" "$hb/.locks/queue/brief.lock"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '%s\n' '# leg' '- brief: follows PR 1999' '## Results' '- 10:00 LIVE — started' '- 10:20 LIVE — PR 1525 open, watching CI' '- a later note naming PR 1998' >"$bk/HIMMEL-1-N55-synthetic-leg-2026-10-01.md"
printf '%s\n' '# leg' '## Results' '- 09:00 READY 1600 abc GREEN' '- 09:30 WRAPPED — merged' > "$bk/HIMMEL-6-N56-wrapped-leg-2026-10-01.md"
printf '%s\n' '# leg' '## Results' '- 08:00 LIVE — started' > "$bk/HIMMEL-7-N57-released-leg-2026-10-01.md"
printf '%s\n' '# leg' '## Results' '- 08:00 LIVE — started' '- 12:00 LIVE — back after a night' '- 12:10 WRAPPED — merged' > "$bk/HIMMEL-6-N60-second-leg-2026-10-01.md"
printf '%s\n' '# leg' '- 08:00 brief note, not a Results bullet' '## Results' '- 09:00 LIVE — started' '- 09:10 WRAPPED — merged' > "$bk/HIMMEL-8-N61-brief-stamp-leg-2026-10-01.md"
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
contains 'a wrapped leg counts toward what its ticket took; a gap over 3 h is idle (HIMMEL-3990)' "$html6" '"ACT":{"6":[2,40]'
contains 'a timestamped line above ## Results is not counted as work (HIMMEL-4441)' "$html6" '"8":[1,10]'
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
    if grep -qx '0 failure(s)' <<< "$mo"; then pass 'the model checks pass (HIMMEL-3990)'; else fail 'the model checks pass (HIMMEL-3990)'; fi
else
    printf 'skip - node not available: model checks\n'
fi
# --- HIMMEL-4026: trail versions (v1.0.1a, v1.0.2b) stay in the train, in train order.
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' version load_bugs load_enhancements load_features load_misc load_audit load_total est_legs \
    v1.0.1 0.1 0 0 0 0 0.1 1 v1.0.1a 0 0 0 0 0 0 0 v1.0.1b 0.01 0 0 0 0 0.01 1 v1.0.2 0 0 0 0 0 0 0 v1.0.2b 0 0 0 0 0 0 0 v2/v3 0 0 0 0 0 0 0 > "$plan/stage3/versions.tsv"
mk 12 'To Do' '["v1.0.1a"]' 'trail a ticket'
mk 13 'To Do' '["v1.0.2b"]' 'trail b ticket'
tstdout="$(render)"
thtml="$(cat "$out" 2>/dev/null)"
contains 'a v1.0.1a ticket renders (HIMMEL-4026)' "$thtml" '"trail a ticket"'
contains 'a v1.0.2b ticket renders (HIMMEL-4026)' "$thtml" '"trail b ticket"'
contains 'trail versions sit in train order (HIMMEL-4026)' "$thtml" '"v1.0.1","v1.0.1a","v1.0.1b","v1.0.2","v1.0.2b"'
contains 'the whole-train ledger counts trail tickets (HIMMEL-4026)' "$tstdout" 'Whole v1.0.x train: 1 of 8 done'
contains 'the JS train test accepts a trail suffix (HIMMEL-4026)' "$thtml" '\d+[a-z]?$/.test(V[i])'

# --- HIMMEL-4872: the v1.1.x line (ex v1.0.2b..h) is train, sorted right after v1.0.2 and before v1.0.3.
cp "$plan/stage3/versions.tsv" "$W/versions.tsv.keep"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' version load_bugs load_enhancements load_features load_misc load_audit load_total est_legs \
    v1.0.1 0.1 0 0 0 0 0.1 1 v1.0.1a 0 0 0 0 0 0 0 v1.0.1b 0.01 0 0 0 0 0.01 1 v1.0.2 0 0 0 0 0 0 0 v1.0.3 0 0 0 0 0 0 0 v1.1.0 0 0 0 0 0 0 0 v2/v3 0 0 0 0 0 0 0 > "$plan/stage3/versions.tsv"
mk 14 'To Do' '["v1.1.0"]' 'minor line ticket'
tstdout="$(render)"
thtml="$(cat "$out" 2>/dev/null)"
contains 'a v1.1.0 ticket renders (HIMMEL-4872)' "$thtml" '"minor line ticket"'
contains 'v1.1.x sits between v1.0.2 and v1.0.3 (HIMMEL-4872)' "$thtml" '"v1.0.2","v1.1.0","v1.0.3"'
contains 'the whole-train ledger counts v1.1.x (HIMMEL-4872)' "$tstdout" 'Whole v1.0.x train: 1 of 8 done'
cp "$W/versions.tsv.keep" "$plan/stage3/versions.tsv"; rm -f "$mdir/HIMMEL-14.md"

# --- HIMMEL-4873: the milestone minors v1.2.0..v1.7.0 are train too, in numeric order after the v1.1.x line.
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' version load_bugs load_enhancements load_features load_misc load_audit load_total est_legs \
    v1.0.1 0.1 0 0 0 0 0.1 1 v1.0.1a 0 0 0 0 0 0 0 v1.0.1b 0.01 0 0 0 0 0.01 1 v1.0.2b 0 0 0 0 0 0 0 v1.1.0 0 0 0 0 0 0 0 v1.7.0 0 0 0 0 0 0 0 v1.2.0 0 0 0 0 0 0 0 v1.2.0a 0 0 0 0 0 0 0 v1.2.1000000 0 0 0 0 0 0 0 v1.2.999999 0 0 0 0 0 0 0 v1.10.0 0 0 0 0 0 0 0 v2/v3 0 0 0 0 0 0 0 > "$plan/stage3/versions.tsv"
mk 15 'To Do' '["v1.2.0"]' 'milestone minor ticket'
tstdout="$(render)"
thtml="$(cat "$out" 2>/dev/null)"
contains 'a v1.2.0 ticket renders (HIMMEL-4873)' "$thtml" '"milestone minor ticket"'
contains 'minors sort numerically after the v1.1.x line (HIMMEL-4873)' "$thtml" '"v1.1.0","v1.2.0","v1.2.0a","v1.2.999999","v1.2.1000000","v1.7.0","v1.10.0"'
contains 'the whole-train ledger counts a minor (HIMMEL-4873)' "$tstdout" 'Whole v1.0.x train: 1 of 9 done'
contains 'the JS train test accepts every v1.N.x (HIMMEL-4873)' "$thtml" '/^v1\.\d+\.\d+[a-z]?$/'
cp "$W/versions.tsv.keep" "$plan/stage3/versions.tsv"; rm -f "$mdir/HIMMEL-15.md"

# --- HIMMEL-3990: version-first page. Versions and release state come from Jira (mirror fixVersions + a `jira versions`
# snapshot in <mirror-dir>.versions.tsv); the main view answers "which version are we working on".
# No versions file yet: no version counts as released and the page says so.
contains 'a missing versions file means release state unknown (HIMMEL-3990)' "$html" '"RU":true'
contains 'the hero says release state unknown (HIMMEL-3990)' "$html" '"release state unknown"'
jm="$W/jm"
mkdir -p "$jm"
mdir="$jm"
mk 30 'Done' '["v1.0.1"]' 'released done one' 'Done'
mk 31 'To Do' '["v1.0.1"]' 'released but open' 'To Do'
mk 32 'In Progress' '["v1.0.3","v1.0.2"]' 'review one' 'In Review'
mk 33 'In Progress' '["v1.0.2"]' 'ci one' 'IN CI'
mk 34 'To Do' '["v1.0.3"]' 'next one' 'To Do'
mk 35 'Done' '["v1.0.2"]' 'wont one' 'wont do'
mk 36 'In Progress' '["v1.0.2"]' 'category fallback one'
mk 37 'To Do' '["v1.0.0"]' 'zero version one' 'To Do'
mdir="$mir"
printf 'v1.0.0\ttrue\t2026-09-30\nv1.0.1\ttrue\t2026-10-04\nv1.0.2\tfalse\t\nv1.0.3\tfalse\t\n' > "$W/jm.versions.tsv"
render --mirror-dir "$jm" >/dev/null
jhtml="$(cat "$out" 2>/dev/null)"
contains 'the default versions file is <mirror-dir>.versions.tsv (HIMMEL-3990)' "$jhtml" \
    '"JV":[{"n":"v1.0.1","rel":true,"date":"2026-10-04"},{"n":"v1.0.2","rel":false,"date":""},{"n":"v1.0.3","rel":false,"date":""}]'
contains 'a versions file means release state is known (HIMMEL-3990)' "$jhtml" '"RU":false'
not_contains 'a ticket with only v1.0.0 is in no version (HIMMEL-3990)' "$jhtml" '"t":"zero version one"'
contains 'working on is the earliest unreleased version with open work, not a released one (HIMMEL-3990)' "$jhtml" '"JC":1,'
contains 'up next is the next unreleased version holding a ticket (HIMMEL-3990)' "$jhtml" '"JN":2,'
contains 'a released version holding an open ticket is alerted, naming the ticket (HIMMEL-3990)' "$jhtml" '"JA":[[0,[31]]]'
contains 'the alert text names the release date and the open tickets (HIMMEL-3990)' "$jhtml" ' but still holds '
contains 'the released-but-open alert still renders when no unreleased version is open (HIMMEL-3990)' "$jhtml" \
    's.textContent="Every unreleased version is done.";jalerts(-1);return}'
contains 'In Review is counted from the status name (HIMMEL-3990)' "$jhtml" '"k":32,"t":"review one","s":"In Review","b":"rev","v":1,'
contains 'IN CI is counted from the status name (HIMMEL-3990)' "$jhtml" '"k":33,"t":"ci one","s":"IN CI","b":"ci","v":1,'
contains 'wont do counts as done (HIMMEL-3990)' "$jhtml" '"s":"wont do","b":"wont"'
contains 'an unknown status falls back to the status category (HIMMEL-3990)' "$jhtml" '"t":"category fallback one","s":"In Progress","b":"prog"'
contains 'a released-only ticket keeps its released version (HIMMEL-3990)' "$jhtml" '"k":30,"t":"released done one","s":"Done","b":"done","v":0,'
contains 'hide done work is ON by default (HIMMEL-3990)' "$jhtml" 'var HIDE=true;try{var hs=localStorage.getItem("hide3990")'
contains 'the hide switch starts checked (HIMMEL-3990)' "$jhtml" 'role="switch" aria-checked="true"'
contains 'the switch is labelled Hide done work (HIMMEL-3990)' "$jhtml" 'Hide done work</button>'
contains 'the board caps a column at 6 cards (HIMMEL-3990)' "$jhtml" 'slice(0,6)'
contains 'a drill says where the plan places a ticket that Jira puts elsewhere (HIMMEL-3990)' "$jhtml" '"the plan places it in "'
contains 'every version is a keyboard-pickable row (HIMMEL-3990)' "$jhtml" 'e.key=="Enter"||e.key==" "'
contains 'the version table is titled Every version (HIMMEL-3990)' "$jhtml" '<h2 id="vh">Every version</h2>'
not_contains 'no tiles section (HIMMEL-3990)' "$jhtml" 'id="tiles"'
# an explicit --versions-file wins over the default path
printf 'v1.0.1\tfalse\t\nv1.0.2\ttrue\t2026-10-05\n' > "$W/alt.versions.tsv"
render --mirror-dir "$jm" --versions-file "$W/alt.versions.tsv" >/dev/null
althtml="$(cat "$out" 2>/dev/null)"
contains '--versions-file names the snapshot (HIMMEL-3990)' "$althtml" '"JV":[{"n":"v1.0.1","rel":false,"date":""},{"n":"v1.0.2","rel":true,"date":"2026-10-05"}]'
# an empty (truncated) versions file is no snapshot: it falls back like a missing one (HIMMEL-4441)
: > "$W/empty.versions.tsv"
render --mirror-dir "$jm" --versions-file "$W/empty.versions.tsv" >/dev/null
emhtml="$(cat "$out" 2>/dev/null)"
contains 'an empty versions file means release state unknown (HIMMEL-4441)' "$emhtml" '"RU":true'
contains 'an empty versions file still lists the mirror fixVersions (HIMMEL-4441)' "$emhtml" '"JV":[{"n":"v1.0.1","rel":false,"date":""},'
contains 'an empty versions file still shows the tickets (HIMMEL-4441)' "$emhtml" '"t":"released but open"'
# the versions file is a fingerprint input: a release moves tracker=
fpa='' fpb='' fpc='' fpd='' fpe=''
fp_ok 'versions base' fpa --mirror-dir "$jm"
printf 'v1.0.1\ttrue\t2026-10-04\nv1.0.2\ttrue\t2026-10-05\nv1.0.3\tfalse\t\n' > "$W/jm.versions.tsv"
fp_ok 'versions released' fpb --mirror-dir "$jm"
if [ -n "$fpa" ] && [ "$fpa" != "$fpb" ]; then pass 'a versions-file change moves the fingerprint (HIMMEL-3990)'; else fail "a versions-file change left the fingerprint at '$fpa'"; fi
fp_ok 'versions explicit' fpc --mirror-dir "$jm" --versions-file "$W/alt.versions.tsv"
if [ "$fpb" != "$fpc" ]; then pass '--emit-fp reads --versions-file (HIMMEL-3990)'; else fail '--emit-fp ignored --versions-file'; fi
rm -f "$W/jm.versions.tsv"
fp_ok 'versions missing' fpd --mirror-dir "$jm"
if [ "$fpb" != "$fpd" ]; then pass 'a missing versions file differs from a present one (HIMMEL-3990)'; else fail 'a missing versions file left the fingerprint'; fi
fp_ok 'versions missing again' fpe --mirror-dir "$jm"
if [ "$fpd" = "$fpe" ]; then pass 'the fingerprint is stable with the versions file missing (HIMMEL-3990)'; else fail 'the fingerprint moved with no input change'; fi

printf '%s\n' "$fails failure(s)"
[ "$fails" -eq 0 ]
