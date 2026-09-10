#!/usr/bin/env bash
# Focused TDD acceptance tests for stable finding fingerprints and durable
# branch-scoped re-raise dispositions (HIMMEL-2896). No critic/API calls.
# Platform guard: requires Bash (Git Bash on Windows), Git and Node; invoke
# with bash rather than PowerShell. Verified locally on Linux.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PANEL="$HERE/critic-panel.sh"
LEDGER_APPEND="$HERE/ledger-append.sh"
ROUND="$HERE/review-round.sh"
# shellcheck source=../lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$HERE/../lib/fixture-tempdir.sh"
tmp="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$tmp"' EXIT
fails=0

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1" >&2; fails=$((fails + 1)); }
assert_eq() {
    if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (got '$1', want '$2')"; fi
}
assert_has() {
    case "$1" in *"$2"*) pass "$3" ;; *) fail "$3 (missing '$2')" ;; esac
}
assert_lacks() {
    case "$1" in *"$2"*) fail "$3 (unexpected '$2')" ;; *) pass "$3" ;; esac
}
assert_fingerprint() {
    if grep -qE '^fp3:[0-9a-f]{64}$' <<< "$1"; then
        pass "$2"
    else
        fail "$2 (got '$1', want fp3:<64 lowercase hex>)"
    fi
}

repo="$tmp/repo"
mkdir -p "$repo"
(
    fixture_enter_git_init_dir "$repo" || exit 1
    git -c init.defaultBranch=main init -q
    git config user.name tester
    git config user.email tester@example.invalid
    git config commit.gpgsign false
    printf 'base\n' > src.txt
    git add src.txt
    git commit -q -m base
) || { fail "fixture repository setup"; exit 1; }

git_dir="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)"
ledger="$git_dir/cr-critic-scores.jsonl"
: > "$ledger"

stub="$tmp/stub-cfp.sh"
cat > "$stub" <<'STUB'
#!/usr/bin/env bash
slug="critic"
while [ $# -gt 0 ]; do
    case "$1" in
        --slug) slug="$2"; shift 2 ;;
        *) shift ;;
    esac
done
cat >/dev/null
printf '# %s First-Pass Review\n\n' "$slug"
case "${FINDING_SEVERITY:-imp}" in
    crit)
        printf '## Critical Issues (1 found)\n- [%s-1]: %s\n## Important Issues (0 found)\n## Suggestions (0 found)\n' "$slug" "$FINDING_CLAIM"
        ;;
    imp)
        printf '## Critical Issues (0 found)\n## Important Issues (1 found)\n- [%s-1]: %s\n## Suggestions (0 found)\n' "$slug" "$FINDING_CLAIM"
        ;;
    sug)
        printf '## Critical Issues (0 found)\n## Important Issues (0 found)\n## Suggestions (1 found)\n- [%s-1]: %s\n' "$slug" "$FINDING_CLAIM"
        ;;
    clean)
        printf '## Critical Issues (0 found)\n## Important Issues (0 found)\n## Suggestions (0 found)\n'
        ;;
esac
STUB
chmod +x "$stub"

registry="$tmp/critics.json"
set_registry() {
    printf '{"panel":[{"slug":"%s","model":"fake/model","tier":"free"}]}\n' "$1" > "$registry"
}

DIFF='diff --git a/src.txt b/src.txt
index 0000000..1111111 100644
--- a/src.txt
+++ b/src.txt
@@ -1 +1,2 @@
 base
+change'

checkout_branch() {
    branch="$1"
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
        git -C "$repo" checkout -q "$branch"
    else
        git -C "$repo" checkout -q -b "$branch" main
    fi
}

advance_head() {
    marker="$1"
    printf '%s\n' "$marker" >> "$repo/src.txt"
    git -C "$repo" add src.txt
    git -C "$repo" commit -q -m "$marker"
    git -C "$repo" rev-parse HEAD
}

run_panel() {
    round="$1"
    claim="$2"
    severity="$3"
    out_file="$4"
    err_file="$5"
    (
        cd "$repo" || exit 1
        printf '%s' "$DIFF" | CR_PROFILE=free CR_LEDGER="$ledger" CRITIC_LEDGER_APPEND="$LEDGER_APPEND" \
            CRITICS_JSON="$registry" CRITIC_FIRST_PASS="$stub" \
            CR_REVIEW_ROUND="$round" FINDING_CLAIM="$claim" FINDING_SEVERITY="$severity" \
            bash "$PANEL" --head "$(git rev-parse HEAD)" --branch "$(git branch --show-current)" \
            > "$out_file" 2> "$err_file"
    )
}

ledger_value() {
    branch="$1" head="$2" field="$3"
    BRANCH="$branch" HEAD_="$head" FIELD="$field" LEDGER="$ledger" node -e '
const fs=require("fs"),e=process.env;
const rows=fs.readFileSync(e.LEDGER,"utf8").split("\n").filter(Boolean).map(JSON.parse);
const row=rows.filter(r=>r.kind==="finding"&&r.branch===e.BRANCH&&r.head===e.HEAD_).pop()||{};
const value=row[e.FIELD];
process.stdout.write(value===undefined?"<absent>":String(value));
'
}

finding_id_at() {
    branch="$1" head="$2"
    BRANCH="$branch" HEAD_="$head" LEDGER="$ledger" node -e '
const fs=require("fs"),e=process.env;
const rows=fs.readFileSync(e.LEDGER,"utf8").split("\n").filter(Boolean).map(JSON.parse);
const row=rows.filter(r=>r.kind==="finding"&&r.branch===e.BRANCH&&r.head===e.HEAD_).pop()||{};
process.stdout.write(String(row.finding_id||""));
'
}

finding_count_at() {
    branch="$1" head="$2"
    BRANCH="$branch" HEAD_="$head" LEDGER="$ledger" node -e '
const fs=require("fs"),e=process.env;
const rows=fs.readFileSync(e.LEDGER,"utf8").split("\n").filter(Boolean).map(JSON.parse);
process.stdout.write(String(rows.filter(r=>r.kind==="finding"&&r.branch===e.BRANCH&&r.head===e.HEAD_).length));
'
}

# Stable fingerprint + durable disproved re-raise. Citation line movement,
# claim case, and whitespace fold; meaningful claim numbers remain identity.
checkout_branch reraised
head_r4="$(advance_head r4)"
set_registry critic-a
claim_r4='N117 retry 3 times can duplicate the ledger row [scripts/cr/example.sh:117]'
run_panel 4 "$claim_r4" imp "$tmp/r4.out" "$tmp/r4.err"
assert_eq "$?" "0" "r4 producer panel run succeeds"
id_r4="$(finding_id_at reraised "$head_r4")"
assert_eq "$id_r4" "critic-a-1" "r4 fixture produces the expected finding id"
fp_r4="$(ledger_value reraised "$head_r4" fingerprint)"
assert_fingerprint "$fp_r4" "r4 finding persists a stable fingerprint"
assert_eq "$(ledger_value reraised "$head_r4" round)" "4" "r4 finding persists its review round"
(
    cd "$repo" || exit 1
    CR_LEDGER="$ledger" bash "$LEDGER_APPEND" amend --branch reraised --head "$head_r4" \
        --id "$id_r4" --set verdict=disproved --reason 'N117 premise disproved'
) >/dev/null 2>"$tmp/r4-amend.err"
assert_eq "$?" "0" "initial finding accepts a durable disproved disposition"

head_r5="$(advance_head r5)"
claim_r5='  n117   RETRY  3 TIMES can duplicate the ledger row   [scripts/cr/example.sh:204]'
run_panel 5 "$claim_r5" imp "$tmp/r5.out" "$tmp/r5.err"
assert_eq "$?" "0" "r5 producer panel run succeeds"
r5_out="$(cat "$tmp/r5.out")"
assert_has "$r5_out" "## Important Issues (0 found)" "r5 disproved re-raise is excluded from the severity tally"
assert_has "$r5_out" "## Already Dispositioned Re-raises (1 found)" "r5 re-raise stays visible in a separate block"
assert_has "$r5_out" "RE-RAISE (r4 disproved)" "r5 re-raise names the original round and verdict"
assert_eq "$(ledger_value reraised "$head_r5" fingerprint)" "$fp_r4" "line/case/whitespace changes keep the fingerprint stable"
assert_eq "$(ledger_value reraised "$head_r5" verdict)" "disproved" "r5 re-raise persists the inherited disposition"
# HIMMEL-2901: this fixture amends with no adjudication round, so disposition_round
# stays the producer round — the documented fallback that keeps pre-2901 rows rendering.
assert_eq "$(ledger_value reraised "$head_r5" disposition_round)" "4" "r5 re-raise preserves the original disposition round"

# A later explicit fixed disposition supersedes the old disproof. Fixed never
# suppresses a fresh occurrence, which is treated as a regression.
(
    cd "$repo" || exit 1
    CR_LEDGER="$ledger" bash "$LEDGER_APPEND" amend --branch reraised --head "$head_r4" \
        --id critic-a-1 --set verdict=fixed --reason 'the implementation was repaired after r5'
) >/dev/null 2>"$tmp/fixed-amend.err"
assert_eq "$?" "0" "fixed is a durable explicit disposition"
head_r6="$(advance_head r6)"
run_panel 6 "$claim_r4" imp "$tmp/r6.out" "$tmp/r6.err"
assert_eq "$?" "0" "r6 fixed-regression panel run succeeds"
r6_out="$(cat "$tmp/r6.out")"
assert_has "$r6_out" "## Important Issues (1 found)" "latest fixed disposition does not suppress a regression"
assert_lacks "$r6_out" "RE-RAISE (" "fixed regression remains in the normal findings block"
assert_eq "$(ledger_value reraised "$head_r6" verdict)" "" "fixed regression lands as a fresh unadjudicated row"

# Different claim at the same anchor: changing a meaningful claim number must
# change identity; citation line numbers alone were the only numbers removed.
head_r7="$(advance_head r7)"
claim_r7='N118 retry 3 times can duplicate the ledger row [scripts/cr/example.sh:117]'
run_panel 7 "$claim_r7" imp "$tmp/r7.out" "$tmp/r7.err"
assert_eq "$?" "0" "r7 changed-claim panel run succeeds"
assert_has "$(cat "$tmp/r7.out")" "## Important Issues (1 found)" "different claim at the same anchor stays visible"
if [ "$(ledger_value reraised "$head_r7" fingerprint)" != "$fp_r4" ]; then
    pass "meaningful N117/N118 claim numbers remain fingerprint-significant"
else
    fail "meaningful N117/N118 claim numbers remain fingerprint-significant"
fi

# A non-verdict amendment to an older row must not revive its adjudication
# after a newer row superseded the fingerprint to fixed.
checkout_branch disposition-order
head_order3="$(advance_head order-r3)"
set_registry critic-a
order_claim='Stable ordering claim [scripts/cr/order.sh:30]'
run_panel 3 "$order_claim" imp "$tmp/order3.out" "$tmp/order3.err"
assert_eq "$?" "0" "ordering seed panel run succeeds"
id_order3="$(finding_id_at disposition-order "$head_order3")"
(
    cd "$repo" || exit 1
    CR_LEDGER="$ledger" bash "$LEDGER_APPEND" amend --branch disposition-order --head "$head_order3" \
        --id "$id_order3" --set verdict=disproved --reason 'initial ordering claim disproved'
) >/dev/null 2>"$tmp/order3-amend.err"
assert_eq "$?" "0" "ordering fixture accepts initial disproof"
head_order4="$(advance_head order-r4)"
run_panel 4 "$order_claim" imp "$tmp/order4.out" "$tmp/order4.err"
assert_eq "$?" "0" "ordering re-raise panel run succeeds"
id_order4="$(finding_id_at disposition-order "$head_order4")"
(
    cd "$repo" || exit 1
    CR_LEDGER="$ledger" bash "$LEDGER_APPEND" amend --branch disposition-order --head "$head_order4" \
        --id "$id_order4" --set verdict=fixed --reason 'newer occurrence was fixed'
    CR_LEDGER="$ledger" bash "$LEDGER_APPEND" amend --branch disposition-order --head "$head_order3" \
        --id "$id_order3" --set 'reason=older bookkeeping correction' --reason 'clarify old row only'
) >/dev/null 2>"$tmp/order-latest.err"
assert_eq "$?" "0" "non-verdict amendment fixture writes successfully"
advance_head order-r5 >/dev/null
run_panel 5 "$order_claim" imp "$tmp/order5.out" "$tmp/order5.err"
assert_eq "$?" "0" "post-amend ordering panel run succeeds"
assert_has "$(cat "$tmp/order5.out")" "## Important Issues (1 found)" "older non-verdict amend does not revive superseded disproof"
assert_lacks "$(cat "$tmp/order5.out")" "RE-RAISE (" "newer fixed disposition remains authoritative"

# Changing the file identity through an amendment invalidates the old
# fingerprint. The full original claim may have been truncated, so the reader
# must fail active rather than recompute a potentially false new identity.
checkout_branch amended-anchor
head_anchor3="$(advance_head anchor-r3)"
set_registry critic-a
anchor_claim='Anchor-specific claim [scripts/cr/old-anchor.sh:40]'
run_panel 3 "$anchor_claim" imp "$tmp/anchor3.out" "$tmp/anchor3.err"
assert_eq "$?" "0" "anchor seed panel run succeeds"
id_anchor3="$(finding_id_at amended-anchor "$head_anchor3")"
(
    cd "$repo" || exit 1
    CR_LEDGER="$ledger" bash "$LEDGER_APPEND" amend --branch amended-anchor --head "$head_anchor3" \
        --id "$id_anchor3" --set verdict=disproved --reason 'old anchor disposition'
    CR_LEDGER="$ledger" bash "$LEDGER_APPEND" amend --branch amended-anchor --head "$head_anchor3" \
        --id "$id_anchor3" --set file=scripts/cr/new-anchor.sh --reason 'correct the finding anchor'
) >/dev/null 2>"$tmp/anchor-amend.err"
assert_eq "$?" "0" "file-identity amendment fixture writes successfully"
advance_head anchor-r4 >/dev/null
run_panel 4 "$anchor_claim" imp "$tmp/anchor4.out" "$tmp/anchor4.err"
assert_eq "$?" "0" "post-file-amend panel run succeeds"
assert_has "$(cat "$tmp/anchor4.out")" "## Important Issues (1 found)" "file amendment invalidates the old fingerprint disposition"
assert_lacks "$(cat "$tmp/anchor4.out")" "RE-RAISE (" "changed identity fails active instead of inheriting old anchor"

# Deferred disposition carries its valid ticket and original round through
# repeated r8/r9 re-raises. The r9 row must still point to r7, not chain to r8.
checkout_branch deferred
head_d7="$(advance_head d7)"
set_registry critic-a
deferred_claim='Cache cleanup must retain 2 generations [scripts/cr/cache.sh:70]'
run_panel 7 "$deferred_claim" sug "$tmp/d7.out" "$tmp/d7.err"
assert_eq "$?" "0" "r7 deferred producer panel run succeeds"
id_d7="$(finding_id_at deferred "$head_d7")"
assert_eq "$id_d7" "critic-a-1" "r7 deferred fixture produces the expected finding id"
(
    cd "$repo" || exit 1
    CR_LEDGER="$ledger" bash "$LEDGER_APPEND" amend --branch deferred --head "$head_d7" \
        --id "$id_d7" --set verdict=deferred --set deferred_to=HIMMEL-9007 \
        --set 'reason=Tracked outside this branch.' --reason 'defer the accepted follow-up'
) >/dev/null 2>"$tmp/d7-amend.err"
assert_eq "$?" "0" "r7 finding accepts a tracked deferred disposition"

head_d8="$(advance_head d8)"
run_panel 8 'cache cleanup must retain 2 generations [scripts/cr/cache.sh:80]' sug "$tmp/d8.out" "$tmp/d8.err"
assert_eq "$?" "0" "r8 deferred re-raise panel run succeeds"
assert_has "$(cat "$tmp/d8.out")" "RE-RAISE (r7 deferred)" "r8 reports the original deferred disposition"
assert_has "$(cat "$tmp/d8.out")" "## Suggestions (0 found)" "r8 deferred re-raise is excluded from suggestion tally"
assert_eq "$(ledger_value deferred "$head_d8" deferred_to)" "HIMMEL-9007" "r8 durable row carries the defer ticket"

head_d9="$(advance_head d9)"
run_panel 9 'CACHE cleanup must retain 2 generations [scripts/cr/cache.sh:90]' sug "$tmp/d9.out" "$tmp/d9.err"
assert_eq "$?" "0" "r9 deferred re-raise panel run succeeds"
assert_has "$(cat "$tmp/d9.out")" "RE-RAISE (r7 deferred)" "r9 still reports r7 rather than chaining through r8"
assert_has "$(cat "$tmp/d9.out")" "## Suggestions (0 found)" "r9 deferred re-raise remains outside suggestion tally"
# HIMMEL-2901: same no-adjudication-round fallback, carried across two re-raises.
assert_eq "$(ledger_value deferred "$head_d9" disposition_round)" "7" "r9 durable row preserves r7 as disposition source"

advance_head d10-changed-claim >/dev/null
run_panel 10 'CACHE cleanup must retain 3 generations [scripts/cr/cache.sh:90]' sug "$tmp/d10.out" "$tmp/d10.err"
assert_eq "$?" "0" "changed deferred-claim panel run succeeds"
assert_has "$(cat "$tmp/d10.out")" "## Suggestions (1 found)" "different claim at a settled anchor remains active"
assert_lacks "$(cat "$tmp/d10.out")" "RE-RAISE (" "different claim is not inherited from the settled fingerprint"

# The HIMMEL-2780 consumer is review-round.sh, not critic-panel.sh. A settled
# current-head suggestion must not consume the round-4 suggestion cap or demand
# a fresh ticket. Seed only the branch counter; no marker/clear path is reached
# when the current finding is already resolved.
mkdir -p "$git_dir/cr-review-rounds"
printf '4\n' > "$git_dir/cr-review-rounds/deferred.round"
(
    cd "$repo" || exit 1
    bash "$ROUND" defer --branch deferred --head "$head_d9"
) >"$tmp/cap.out" 2>"$tmp/cap.err"
assert_eq "$?" "0" "settled deferred re-raise does not consume the HIMMEL-2780 cap"
assert_lacks "$(cat "$tmp/cap.err")" "no valid defer ticket" "settled cap path does not request another ticket"

# A disposition at Suggestion severity does not authorize silently suppressing
# the same claim when a later critic raises it as Important.
checkout_branch deferred
advance_head d11-severity-escalation >/dev/null
run_panel 11 "$deferred_claim" imp "$tmp/d11.out" "$tmp/d11.err"
assert_eq "$?" "0" "severity-escalated deferred panel run succeeds"
assert_has "$(cat "$tmp/d11.out")" "## Important Issues (1 found)" "deferred Suggestion re-raised as Important requires adjudication"
assert_lacks "$(cat "$tmp/d11.out")" "RE-RAISE (" "severity escalation remains in the active findings block"

# Same/lower severities remain suppressed against the ORIGINAL adjudicated
# ceiling. An inherited lower-severity row must not narrow that ceiling for the
# next round; only a later increase above it becomes active.
checkout_branch severity-ceiling
head_sc3="$(advance_head severity-ceiling-r3)"
set_registry critic-a
severity_claim='Severity ceiling claim [scripts/cr/severity.sh:30]'
run_panel 3 "$severity_claim" imp "$tmp/sc3.out" "$tmp/sc3.err"
assert_eq "$?" "0" "severity ceiling seed panel run succeeds"
id_sc3="$(finding_id_at severity-ceiling "$head_sc3")"
(
    cd "$repo" || exit 1
    CR_LEDGER="$ledger" bash "$LEDGER_APPEND" amend --branch severity-ceiling --head "$head_sc3" \
        --id "$id_sc3" --set verdict=disproved --reason 'Important claim disproved'
) >/dev/null 2>"$tmp/sc3-amend.err"
assert_eq "$?" "0" "severity ceiling fixture accepts Important disproof"
head_sc4="$(advance_head severity-ceiling-r4)"
run_panel 4 "$severity_claim" sug "$tmp/sc4.out" "$tmp/sc4.err"
assert_eq "$?" "0" "lower severity panel run succeeds"
assert_has "$(cat "$tmp/sc4.out")" "## Suggestions (0 found)" "lower Suggestion remains suppressed"
assert_eq "$(ledger_value severity-ceiling "$head_sc4" disposition_severity)" "imp" "lower re-raise persists original Important severity ceiling"
advance_head severity-ceiling-r5 >/dev/null
run_panel 5 "$severity_claim" imp "$tmp/sc5.out" "$tmp/sc5.err"
assert_eq "$?" "0" "same severity panel run succeeds"
assert_has "$(cat "$tmp/sc5.out")" "## Important Issues (0 found)" "same Important severity remains suppressed after lower inherited row"
advance_head severity-ceiling-r6 >/dev/null
run_panel 6 "$severity_claim" crit "$tmp/sc6.out" "$tmp/sc6.err"
assert_eq "$?" "0" "higher severity panel run succeeds"
assert_has "$(cat "$tmp/sc6.out")" "## Critical Issues (1 found)" "Critical escalation above original Important ceiling is active"
assert_lacks "$(cat "$tmp/sc6.out")" "RE-RAISE (" "Critical escalation requires renewed adjudication"

# Missing or unknown adjudicated severity is conservative: there is no safe
# ceiling to compare, so a current canonical finding remains active.
checkout_branch severity-unknown
head_su3="$(advance_head severity-unknown-seed)"
unknown_claim='Unknown severity claim [scripts/cr/severity.sh:70]'
(
    cd "$repo" || exit 1
    CR_LEDGER="$ledger" bash "$LEDGER_APPEND" finding --branch severity-unknown --head "$head_su3" \
        --model critic-a --id severity-unknown-1 --severity mystery --file scripts/cr/severity.sh --line 70 \
        --verdict disproved --round 3 --text "- [severity-unknown-1]: $unknown_claim"
) >/dev/null 2>"$tmp/severity-unknown-seed.err"
assert_eq "$?" "0" "unknown severity fixture writes"
advance_head severity-unknown-current >/dev/null
run_panel 4 "$unknown_claim" imp "$tmp/severity-unknown.out" "$tmp/severity-unknown.err"
assert_eq "$?" "0" "unknown prior severity panel run succeeds"
assert_has "$(cat "$tmp/severity-unknown.out")" "## Important Issues (1 found)" "unknown prior severity fails active"
assert_lacks "$(cat "$tmp/severity-unknown.out")" "RE-RAISE (" "unknown prior severity is not inherited"

checkout_branch severity-missing
head_sm3="$(advance_head severity-missing-seed)"
missing_claim='Missing severity claim [scripts/cr/severity.sh:80]'
missing_fp="$(MODEL=critic-a FILE_=scripts/cr/severity.sh TEXT_="- [severity-missing-1]: $missing_claim" HELPER="$HERE/finding-fingerprint.js" node -e '
const {findingFingerprint}=require(process.env.HELPER);
process.stdout.write(findingFingerprint(process.env.MODEL,process.env.FILE_,process.env.TEXT_));
')"
printf '{"kind":"finding","ts":"2020-01-01T00:00:00Z","branch":"severity-missing","head":"%s","model":"critic-a","finding_id":"severity-missing-1","file":"scripts/cr/severity.sh","line":80,"verdict":"disproved","round":3,"disposition_round":3,"fingerprint":"%s","artifact":"diff","perspective":"off","text":"- [severity-missing-1]: %s"}\n' \
    "$head_sm3" "$missing_fp" "$missing_claim" >> "$ledger"
advance_head severity-missing-current >/dev/null
run_panel 4 "$missing_claim" imp "$tmp/severity-missing.out" "$tmp/severity-missing.err"
assert_eq "$?" "0" "missing prior severity panel run succeeds"
assert_has "$(cat "$tmp/severity-missing.out")" "## Important Issues (1 found)" "missing prior severity fails active"
assert_lacks "$(cat "$tmp/severity-missing.out")" "RE-RAISE (" "missing prior severity is not inherited"

# Branch, critic, and artifact/perspective are controls outside the fingerprint
# equality itself. Each mismatch must leave the current finding active.
checkout_branch other-branch
advance_head other >/dev/null
set_registry critic-a
run_panel 10 "$deferred_claim" sug "$tmp/other.out" "$tmp/other.err"
assert_eq "$?" "0" "other-branch panel run succeeds"
assert_has "$(cat "$tmp/other.out")" "## Suggestions (1 found)" "same fingerprint on another branch stays visible"

checkout_branch other-critic
head_oc_seed="$(advance_head oc-seed)"
set_registry critic-a
run_panel 3 "$deferred_claim" sug "$tmp/oc-seed.out" "$tmp/oc-seed.err"
assert_eq "$?" "0" "other-critic seed panel run succeeds"
id_oc_seed="$(finding_id_at other-critic "$head_oc_seed")"
assert_eq "$id_oc_seed" "critic-a-1" "other-critic seed produces the expected id"
(
    cd "$repo" || exit 1
    CR_LEDGER="$ledger" bash "$LEDGER_APPEND" amend --branch other-critic --head "$head_oc_seed" \
        --id "$id_oc_seed" --set verdict=disproved --reason 'critic-a claim disproved'
) >/dev/null 2>&1
advance_head oc-current >/dev/null
set_registry critic-b
run_panel 4 "$deferred_claim" sug "$tmp/oc.out" "$tmp/oc.err"
assert_eq "$?" "0" "different-critic panel run succeeds"
assert_has "$(cat "$tmp/oc.out")" "## Suggestions (1 found)" "same claim from a different critic stays visible"

checkout_branch controls
head_control_seed="$(advance_head control-seed)"
set_registry critic-a
# Use the real writer so the spec/on row gets the same production fingerprint.
(
    cd "$repo" || exit 1
    CR_LEDGER="$ledger" bash "$LEDGER_APPEND" finding --branch controls --head "$head_control_seed" \
        --model critic-a --id control-1 --severity sug --file scripts/cr/cache.sh --line 70 \
        --verdict disproved --artifact spec --perspective on --round 3 \
        --text "- [control-1]: $deferred_claim"
) >/dev/null 2>"$tmp/control-seed.err"
assert_eq "$?" "0" "control fixture writes a fingerprinted spec/perspective row"
advance_head control-current >/dev/null
run_panel 4 "$deferred_claim" sug "$tmp/control.out" "$tmp/control.err"
assert_eq "$?" "0" "artifact/perspective control panel run succeeds"
assert_has "$(cat "$tmp/control.out")" "## Suggestions (1 found)" "different artifact/perspective controls stay visible"

# File systems and Git can distinguish path case. Claim/slug case still folds,
# but Foo.js and foo.js are different fingerprint anchors.
checkout_branch path-case
head_case_seed="$(advance_head path-case-seed)"
set_registry critic-a
(
    cd "$repo" || exit 1
    CR_LEDGER="$ledger" bash "$LEDGER_APPEND" finding --branch path-case --head "$head_case_seed" \
        --model critic-a --id case-1 --severity imp --file scripts/cr/Foo.js --line 10 \
        --verdict disproved --round 3 --text '- [case-1]: Case-sensitive anchor claim [scripts/cr/Foo.js:10]'
) >/dev/null 2>"$tmp/path-case-seed.err"
assert_eq "$?" "0" "path-case fixture writes the uppercase anchor"
advance_head path-case-current >/dev/null
run_panel 4 'case-sensitive anchor claim [scripts/cr/foo.js:80]' imp "$tmp/path-case.out" "$tmp/path-case.err"
assert_eq "$?" "0" "different path-case panel run succeeds"
assert_has "$(cat "$tmp/path-case.out")" "## Important Issues (1 found)" "Foo.js and foo.js remain distinct anchors"
assert_lacks "$(cat "$tmp/path-case.out")" "RE-RAISE (" "different path case does not inherit disposition"

checkout_branch path-case-parity
head_case_parity="$(advance_head path-case-parity-seed)"
(
    cd "$repo" || exit 1
    CR_LEDGER="$ledger" bash "$LEDGER_APPEND" finding --branch path-case-parity --head "$head_case_parity" \
        --model critic-a --id case-parity-1 --severity imp --file ./scripts/cr/Foo.js --line 10 \
        --verdict disproved --round 3 --text '- [case-parity-1]: Case-sensitive anchor claim [./scripts/cr/Foo.js:10]'
) >/dev/null 2>"$tmp/path-case-parity-seed.err"
assert_eq "$?" "0" "same-case parity fixture writes through the standalone writer"
advance_head path-case-parity-current >/dev/null
run_panel 4 'CASE-sensitive   anchor CLAIM [scripts/cr/Foo.js:90]' imp "$tmp/path-case-parity.out" "$tmp/path-case-parity.err"
assert_eq "$?" "0" "same-case parity panel run succeeds"
assert_has "$(cat "$tmp/path-case-parity.out")" "RE-RAISE (r3 disproved)" "same path case normalizes identically across writer and panel helper"

# Re-key amendments remain addressed by the original append-only target key.
# A later verdict invoked through the corrected effective head still stores the
# original target_head, so the reader must not move its working map.
checkout_branch rekey-map
rekey_old="1111111111111111111111111111111111111111"
rekey_new="2222222222222222222222222222222222222222"
rekey_claim='Re-keyed finding remains fixed [scripts/cr/rekey.sh:10]'
(
    cd "$repo" || exit 1
    CR_LEDGER="$ledger" bash "$LEDGER_APPEND" finding --branch rekey-map --head "$rekey_old" \
        --model critic-a --id rekey-1 --severity imp --file scripts/cr/rekey.sh --line 10 \
        --verdict disproved --round 3 --text "- [rekey-1]: $rekey_claim"
    CR_LEDGER="$ledger" bash "$LEDGER_APPEND" amend --branch rekey-map --head "$rekey_old" \
        --id rekey-1 --set head="$rekey_new" --reason 'correct effective head'
    CR_LEDGER="$ledger" bash "$LEDGER_APPEND" amend --branch rekey-map --head "$rekey_new" \
        --id rekey-1 --set verdict=fixed --reason 'fix through effective head'
) >/dev/null 2>"$tmp/rekey-map.err"
assert_eq "$?" "0" "re-key plus effective-head fixed amendments succeed"
rekey_target="$(LEDGER="$ledger" node -e '
const rows=require("fs").readFileSync(process.env.LEDGER,"utf8").trim().split("\n").map(JSON.parse);
const row=rows.filter(r=>r.kind==="amend"&&r.finding_id==="rekey-1"&&r.set&&r.set.verdict==="fixed").pop()||{};
process.stdout.write(String(row.target_head||""));
')"
assert_eq "$rekey_target" "$rekey_old" "effective-head verdict persists the original target_head"
advance_head rekey-map-current >/dev/null
run_panel 4 "$rekey_claim" imp "$tmp/rekey-map.out" "$tmp/rekey-map-panel.err"
assert_eq "$?" "0" "re-key regression panel run succeeds"
assert_has "$(cat "$tmp/rekey-map.out")" "## Important Issues (1 found)" "re-keyed latest fixed disposition remains active"
assert_lacks "$(cat "$tmp/rekey-map.out")" "RE-RAISE (" "re-key map is not moved away from original target key"

# Legacy/textless findings have no fingerprint and are ignored safely rather
# than guessed into a match.
checkout_branch legacy
head_legacy_seed="$(advance_head legacy-seed)"
printf '{"kind":"finding","ts":"2020-01-01T00:00:00Z","branch":"legacy","head":"%s","model":"critic-a","finding_id":"legacy-1","severity":"sug","file":"scripts/cr/cache.sh","line":70,"verdict":"disproved","artifact":"diff","perspective":"off"}\n' "$head_legacy_seed" >> "$ledger"
advance_head legacy-current >/dev/null
set_registry critic-a
run_panel 4 "$deferred_claim" sug "$tmp/legacy.out" "$tmp/legacy.err"
assert_eq "$?" "0" "legacy-textless panel run succeeds"
assert_has "$(cat "$tmp/legacy.out")" "## Suggestions (1 found)" "legacy textless input is safe and remains visible"

# Additive fingerprint/round fields must not alter the existing dedup key or
# break a textless verdict-only reappend. Same (head,id,artifact,perspective)
# still dedups; an incoming adjudication omitting additive fields auto-amends.
checkout_branch ledger-compat
head_lc="$(advance_head ledger-compat)"
compat="$tmp/compat.jsonl"
: > "$compat"
(
    cd "$repo" || exit 1
    CR_LEDGER="$compat" bash "$LEDGER_APPEND" finding --branch ledger-compat --head "$head_lc" \
        --model critic-a --id critic-a-1 --severity imp --file scripts/cr/example.sh --line 117 \
        --verdict '' --round 4 --text "- [critic-a-1]: $claim_r4"
    CR_LEDGER="$compat" bash "$LEDGER_APPEND" finding --branch ledger-compat --head "$head_lc" \
        --model critic-a --id critic-a-1 --severity imp --file scripts/cr/example.sh --line 117 \
        --verdict '' --round 4 --text "- [critic-a-1]: $claim_r4"
) >/dev/null 2>"$tmp/compat-dedup.err"
assert_eq "$(wc -l < "$compat" | tr -d ' ')" "1" "additive fields leave the finding dedup key unchanged"
(
    cd "$repo" || exit 1
    CR_LEDGER="$compat" bash "$LEDGER_APPEND" finding --branch ledger-compat --head "$head_lc" \
        --model critic-a --id critic-a-1 --severity imp --file scripts/cr/example.sh --line 117 \
        --verdict disproved
) >/dev/null 2>"$tmp/compat-verdict.err"
assert_eq "$?" "0" "textless verdict-only reappend remains compatible"
compat_shape="$(LEDGER="$compat" node -e '
const rows=require("fs").readFileSync(process.env.LEDGER,"utf8").split("\n").filter(Boolean).map(JSON.parse);
process.stdout.write(rows.filter(r=>r.kind==="finding").length+","+rows.filter(r=>r.kind==="amend").length);
')"
compat_fp="$(LEDGER="$compat" node -e '
const rows=require("fs").readFileSync(process.env.LEDGER,"utf8").split("\n").filter(Boolean).map(JSON.parse);
const finding=rows.find(r=>r.kind==="finding")||{};
process.stdout.write(String(finding.fingerprint||""));
')"
assert_eq "$compat_shape" "1,1" "verdict-only compatibility uses an amend, not a duplicate finding"
assert_fingerprint "$compat_fp" "original fingerprint survives verdict-only adjudication"

# HIMMEL-2901 item 1: the round a verdict was ADJUDICATED in is its own field.
# The finding keeps its first-seen observation round; the amend that sets the
# verdict records the round of the /pr-check pass that wrote it, explicitly via
# --disposition-round or from CR_REVIEW_ROUND. "First seen" is derived by the
# reader as the earliest observation round across rows sharing this
# branch+fingerprint, so an inherited re-raise never reports itself as first
# seen. Rendering names both rounds only when they differ.
checkout_branch adjudication-round
head_ar4="$(advance_head adjudication-r4)"
set_registry critic-a
ar_claim='Adjudication round claim [scripts/cr/adjudication.sh:12]'
run_panel 4 "$ar_claim" imp "$tmp/ar4.out" "$tmp/ar4.err"
assert_eq "$?" "0" "adjudication-round seed panel run succeeds"
id_ar4="$(finding_id_at adjudication-round "$head_ar4")"
(
    cd "$repo" || exit 1
    CR_LEDGER="$ledger" bash "$LEDGER_APPEND" amend --branch adjudication-round --head "$head_ar4" \
        --id "$id_ar4" --set verdict=disproved --disposition-round 5 \
        --reason 'disproved in the r5 pass'
) >/dev/null 2>"$tmp/ar-amend.err"
assert_eq "$?" "0" "amend accepts an explicit adjudication round"
head_ar6="$(advance_head adjudication-r6)"
run_panel 6 "$ar_claim" imp "$tmp/ar6.out" "$tmp/ar6.err"
assert_eq "$?" "0" "adjudication-round re-raise panel run succeeds"
ar6_out="$(cat "$tmp/ar6.out")"
assert_has "$ar6_out" "RE-RAISE (first seen r4 · dispositioned r5 disproved)" \
    "re-raise names the first-seen round and the adjudication round when they differ"
assert_has "$ar6_out" "## Important Issues (0 found)" "explicit adjudication round still suppresses the re-raise"
assert_eq "$(ledger_value adjudication-round "$head_ar6" disposition_round)" "5" \
    "durable re-raise row carries the adjudication round, not the producer round"
assert_eq "$(ledger_value adjudication-round "$head_ar6" round)" "6" \
    "durable re-raise row keeps its own observation round"

# The next round must not report the r6 re-raise as first seen: first-seen is
# the earliest observation of the fingerprint, r4.
advance_head adjudication-r7 >/dev/null
run_panel 7 "$ar_claim" imp "$tmp/ar7.out" "$tmp/ar7.err"
assert_eq "$?" "0" "adjudication-round second re-raise panel run succeeds"
assert_has "$(cat "$tmp/ar7.out")" "RE-RAISE (first seen r4 · dispositioned r5 disproved)" \
    "first-seen round does not chain through the inherited re-raise"

# CR_REVIEW_ROUND supplies the adjudication round when the flag is omitted:
# an adjudication written during an r5 pass is an r5 disposition.
checkout_branch adjudication-env
head_ae3="$(advance_head adjudication-env-r3)"
set_registry critic-a
ae_claim='Ambient adjudication round claim [scripts/cr/adjudication.sh:40]'
run_panel 3 "$ae_claim" imp "$tmp/ae3.out" "$tmp/ae3.err"
assert_eq "$?" "0" "ambient adjudication seed panel run succeeds"
id_ae3="$(finding_id_at adjudication-env "$head_ae3")"
(
    cd "$repo" || exit 1
    CR_LEDGER="$ledger" CR_REVIEW_ROUND=5 bash "$LEDGER_APPEND" amend --branch adjudication-env \
        --head "$head_ae3" --id "$id_ae3" --set verdict=disproved --reason 'disproved during the r5 pass'
) >/dev/null 2>"$tmp/ae-amend.err"
assert_eq "$?" "0" "amend accepts an ambient adjudication round"
head_ae6="$(advance_head adjudication-env-r6)"
run_panel 6 "$ae_claim" imp "$tmp/ae6.out" "$tmp/ae6.err"
assert_eq "$?" "0" "ambient adjudication re-raise panel run succeeds"
assert_has "$(cat "$tmp/ae6.out")" "RE-RAISE (first seen r3 · dispositioned r5 disproved)" \
    "CR_REVIEW_ROUND supplies the adjudication round when --disposition-round is omitted"
assert_eq "$(ledger_value adjudication-env "$head_ae6" disposition_round)" "5" \
    "ambient adjudication round reaches the durable row"

# HIMMEL-2901 item 2: a severity correction to the ORIGINAL adjudication must
# reach the inherited re-raise that now carries the ceiling. Without it, an
# Important corrected to Suggestion keeps its Important ceiling forever and a
# genuine later Important occurrence is wrongly suppressed.
checkout_branch inherited-severity
head_is3="$(advance_head inherited-severity-r3)"
set_registry critic-a
is_claim='Inherited ceiling claim [scripts/cr/inherit.sh:15]'
run_panel 3 "$is_claim" imp "$tmp/is3.out" "$tmp/is3.err"
assert_eq "$?" "0" "inherited-severity seed panel run succeeds"
id_is3="$(finding_id_at inherited-severity "$head_is3")"
(
    cd "$repo" || exit 1
    CR_LEDGER="$ledger" bash "$LEDGER_APPEND" amend --branch inherited-severity --head "$head_is3" \
        --id "$id_is3" --set verdict=disproved --reason 'Important claim disproved'
) >/dev/null 2>"$tmp/is3-amend.err"
assert_eq "$?" "0" "inherited-severity fixture accepts the Important disproof"
head_is4="$(advance_head inherited-severity-r4)"
run_panel 4 "$is_claim" imp "$tmp/is4.out" "$tmp/is4.err"
assert_eq "$?" "0" "inherited-severity re-raise panel run succeeds"
assert_has "$(cat "$tmp/is4.out")" "## Important Issues (0 found)" "the re-raise inherits the Important disproof"
assert_eq "$(ledger_value inherited-severity "$head_is4" disposition_severity)" "imp" \
    "the inherited row carries the Important ceiling"
(
    cd "$repo" || exit 1
    CR_LEDGER="$ledger" bash "$LEDGER_APPEND" amend --branch inherited-severity --head "$head_is3" \
        --id "$id_is3" --set severity=sug --reason 'the original was over-rated; it is a Suggestion'
) >/dev/null 2>"$tmp/is-severity-amend.err"
assert_eq "$?" "0" "severity correction to the original adjudication writes"
advance_head inherited-severity-r5 >/dev/null
run_panel 5 "$is_claim" imp "$tmp/is5.out" "$tmp/is5.err"
assert_eq "$?" "0" "corrected-ceiling panel run succeeds"
assert_has "$(cat "$tmp/is5.out")" "## Important Issues (1 found)" \
    "a severity correction to the original adjudication lowers the inherited ceiling"
assert_lacks "$(cat "$tmp/is5.out")" "RE-RAISE (" \
    "an Important above the corrected Suggestion ceiling requires renewed adjudication"

# Negative control: an amend to a DIFFERENT row of the same fingerprint that is
# not the origin of the active disposition must leave the ceiling alone.
checkout_branch unrelated-severity
head_us3="$(advance_head unrelated-severity-r3)"
set_registry critic-a
us_claim='Unrelated ceiling claim [scripts/cr/inherit.sh:60]'
run_panel 3 "$us_claim" imp "$tmp/us3.out" "$tmp/us3.err"
assert_eq "$?" "0" "unrelated-severity seed panel run succeeds"
id_us3="$(finding_id_at unrelated-severity "$head_us3")"
us_head_other="3333333333333333333333333333333333333333"
(
    cd "$repo" || exit 1
    CR_LEDGER="$ledger" bash "$LEDGER_APPEND" amend --branch unrelated-severity --head "$head_us3" \
        --id "$id_us3" --set verdict=disproved --reason 'Important claim disproved'
    CR_LEDGER="$ledger" bash "$LEDGER_APPEND" finding --branch unrelated-severity --head "$us_head_other" \
        --model critic-a --id unrelated-1 --severity imp --file scripts/cr/inherit.sh --line 60 \
        --verdict '' --round 3 --text "- [unrelated-1]: $us_claim"
) >/dev/null 2>"$tmp/us-seed.err"
assert_eq "$?" "0" "unrelated-severity fixture seeds a same-fingerprint bystander row"
advance_head unrelated-severity-r4 >/dev/null
run_panel 4 "$us_claim" imp "$tmp/us4.out" "$tmp/us4.err"
assert_eq "$?" "0" "unrelated-severity re-raise panel run succeeds"
assert_has "$(cat "$tmp/us4.out")" "## Important Issues (0 found)" "the bystander does not disturb the inheritance"
(
    cd "$repo" || exit 1
    CR_LEDGER="$ledger" bash "$LEDGER_APPEND" amend --branch unrelated-severity --head "$us_head_other" \
        --id unrelated-1 --set severity=sug --reason 'correct an unrelated row of the same claim'
) >/dev/null 2>"$tmp/us-severity-amend.err"
assert_eq "$?" "0" "bystander severity amendment writes"
advance_head unrelated-severity-r5 >/dev/null
run_panel 5 "$us_claim" imp "$tmp/us5.out" "$tmp/us5.err"
assert_eq "$?" "0" "bystander-amend panel run succeeds"
assert_has "$(cat "$tmp/us5.out")" "## Important Issues (0 found)" \
    "amending a row that is not the origin leaves the inherited ceiling intact"

# HIMMEL-2901 item 3: case inside code-bearing fragments is identity. Folding
# the whole claim to lowercase made `Foo` and `foo` at the same anchor one
# fingerprint, so each inherited the other's disposition. Prose case still
# folds — that is the dedup value the fold exists for.
checkout_branch code-case
head_cc3="$(advance_head code-case-r3)"
set_registry critic-a
# shellcheck disable=SC2016  # backticks here are markdown code spans in the claim text, not command substitution
cc_claim='Check the `Foo` handler [scripts/cr/case.sh:10]'
run_panel 3 "$cc_claim" imp "$tmp/cc3.out" "$tmp/cc3.err"
assert_eq "$?" "0" "code-case seed panel run succeeds"
id_cc3="$(finding_id_at code-case "$head_cc3")"
fp_cc3="$(ledger_value code-case "$head_cc3" fingerprint)"
assert_fingerprint "$fp_cc3" "code-case seed persists a versioned fingerprint"
(
    cd "$repo" || exit 1
    CR_LEDGER="$ledger" bash "$LEDGER_APPEND" amend --branch code-case --head "$head_cc3" \
        --id "$id_cc3" --set verdict=disproved --reason 'the Foo handler claim is disproved'
) >/dev/null 2>"$tmp/cc3-amend.err"
assert_eq "$?" "0" "code-case fixture accepts the disproof"

head_cc4="$(advance_head code-case-r4)"
# shellcheck disable=SC2016  # backticks here are markdown code spans in the claim text, not command substitution
run_panel 4 'Check the `foo` handler [scripts/cr/case.sh:20]' imp "$tmp/cc4.out" "$tmp/cc4.err"
assert_eq "$?" "0" "backtick-case panel run succeeds"
assert_has "$(cat "$tmp/cc4.out")" "## Important Issues (1 found)" \
    "a different identifier case inside backticks is a different claim"
assert_lacks "$(cat "$tmp/cc4.out")" "RE-RAISE (" "backtick case does not inherit the other claim's disposition"
if [ "$(ledger_value code-case "$head_cc4" fingerprint)" != "$fp_cc3" ]; then
    pass "backtick identifier case is fingerprint-significant"
else
    fail "backtick identifier case is fingerprint-significant"
fi

head_cc5="$(advance_head code-case-r5)"
# shellcheck disable=SC2016  # backticks here are markdown code spans in the claim text, not command substitution
run_panel 5 'CHECK   the `Foo` HANDLER [scripts/cr/case.sh:30]' imp "$tmp/cc5.out" "$tmp/cc5.err"
assert_eq "$?" "0" "prose-case panel run succeeds"
assert_has "$(cat "$tmp/cc5.out")" "RE-RAISE (r3 disproved)" \
    "prose case and whitespace still fold onto the same fingerprint"
assert_eq "$(ledger_value code-case "$head_cc5" fingerprint)" "$fp_cc3" \
    "prose-only case changes keep the fingerprint stable"

# Identifier shapes outside backticks are code too: camelCase and snake_case
# carry meaning that lowercasing destroys.
checkout_branch bare-identifier-case
head_bi3="$(advance_head bare-identifier-r3)"
set_registry critic-a
bi_claim='The fooBar token and FOO_BAR constant disagree [scripts/cr/case.sh:50]'
run_panel 3 "$bi_claim" imp "$tmp/bi3.out" "$tmp/bi3.err"
assert_eq "$?" "0" "bare-identifier seed panel run succeeds"
id_bi3="$(finding_id_at bare-identifier-case "$head_bi3")"
(
    cd "$repo" || exit 1
    CR_LEDGER="$ledger" bash "$LEDGER_APPEND" amend --branch bare-identifier-case --head "$head_bi3" \
        --id "$id_bi3" --set verdict=disproved --reason 'the identifier claim is disproved'
) >/dev/null 2>"$tmp/bi3-amend.err"
assert_eq "$?" "0" "bare-identifier fixture accepts the disproof"
advance_head bare-identifier-r4 >/dev/null
run_panel 4 'The foobar token and foo_bar constant disagree [scripts/cr/case.sh:60]' imp \
    "$tmp/bi4.out" "$tmp/bi4.err"
assert_eq "$?" "0" "bare-identifier case panel run succeeds"
assert_has "$(cat "$tmp/bi4.out")" "## Important Issues (1 found)" \
    "camelCase and snake_case identifier case is fingerprint-significant"
assert_lacks "$(cat "$tmp/bi4.out")" "RE-RAISE (" "differing identifiers do not inherit a disposition"
advance_head bare-identifier-r5 >/dev/null
run_panel 5 'the fooBar token and FOO_BAR constant DISAGREE [scripts/cr/case.sh:70]' imp \
    "$tmp/bi5.out" "$tmp/bi5.err"
assert_eq "$?" "0" "bare-identifier prose-case panel run succeeds"
assert_has "$(cat "$tmp/bi5.out")" "RE-RAISE (r3 disproved)" \
    "identical identifiers with different prose case still fold onto one fingerprint"

# A dotted identifier that ENDS a sentence is still an identifier: the trailing
# period is prose punctuation, not part of the name (codex-1, round 1).
checkout_branch dotted-sentence-end
head_ds3="$(advance_head dotted-sentence-r3)"
set_registry critic-a
ds_claim='The handler reads config.LOGLEVEL. [scripts/cr/case.sh:80]'
run_panel 3 "$ds_claim" imp "$tmp/ds3.out" "$tmp/ds3.err"
assert_eq "$?" "0" "dotted-sentence seed panel run succeeds"
id_ds3="$(finding_id_at dotted-sentence-end "$head_ds3")"
(
    cd "$repo" || exit 1
    CR_LEDGER="$ledger" bash "$LEDGER_APPEND" amend --branch dotted-sentence-end --head "$head_ds3" \
        --id "$id_ds3" --set verdict=disproved --reason 'the LOGLEVEL claim is disproved'
) >/dev/null 2>"$tmp/ds3-amend.err"
assert_eq "$?" "0" "dotted-sentence fixture accepts the disproof"
advance_head dotted-sentence-r4 >/dev/null
run_panel 4 'The handler reads config.loglevel. [scripts/cr/case.sh:90]' imp "$tmp/ds4.out" "$tmp/ds4.err"
assert_eq "$?" "0" "dotted-sentence case panel run succeeds"
assert_has "$(cat "$tmp/ds4.out")" "## Important Issues (1 found)" \
    "a sentence-ending dotted identifier keeps its case-significance"
assert_lacks "$(cat "$tmp/ds4.out")" "RE-RAISE (" \
    "a differing dotted identifier does not inherit a disposition through trailing punctuation"
advance_head dotted-sentence-r5 >/dev/null
run_panel 5 'THE HANDLER reads config.LOGLEVEL. [scripts/cr/case.sh:95]' imp "$tmp/ds5.out" "$tmp/ds5.err"
assert_eq "$?" "0" "dotted-sentence prose-case panel run succeeds"
assert_has "$(cat "$tmp/ds5.out")" "RE-RAISE (r3 disproved)" \
    "prose case around an identical dotted identifier still folds onto one fingerprint"

# HIMMEL-2906: an identifier embedded in an expression is still an identifier —
# isCodeToken classified the WHOLE token, so the trailing `)` in
# `config.LOGLEVEL(value)` broke the anchored dotted-name regex and both cases
# folded together (fp2). fp3 classifies components split on non-identifier
# characters instead.
checkout_branch expression-identifier-case
head_ei3="$(advance_head expression-identifier-r3)"
set_registry critic-a
ei_claim='The handler reads config.LOGLEVEL(value) [scripts/cr/case.sh:100]'
run_panel 3 "$ei_claim" imp "$tmp/ei3.out" "$tmp/ei3.err"
assert_eq "$?" "0" "expression-identifier seed panel run succeeds"
id_ei3="$(finding_id_at expression-identifier-case "$head_ei3")"
(
    cd "$repo" || exit 1
    CR_LEDGER="$ledger" bash "$LEDGER_APPEND" amend --branch expression-identifier-case --head "$head_ei3" \
        --id "$id_ei3" --set verdict=disproved --reason 'the LOGLEVEL(value) claim is disproved'
) >/dev/null 2>"$tmp/ei3-amend.err"
assert_eq "$?" "0" "expression-identifier fixture accepts the disproof"
advance_head expression-identifier-r4 >/dev/null
run_panel 4 'The handler reads config.loglevel(value) [scripts/cr/case.sh:110]' imp "$tmp/ei4.out" "$tmp/ei4.err"
assert_eq "$?" "0" "expression-identifier case panel run succeeds"
assert_has "$(cat "$tmp/ei4.out")" "## Important Issues (1 found)" \
    "an identifier embedded in a call expression is fingerprint-significant"
assert_lacks "$(cat "$tmp/ei4.out")" "RE-RAISE (" \
    "a differing embedded identifier does not inherit a disposition through the call expression"
advance_head expression-identifier-r5 >/dev/null
run_panel 5 'THE HANDLER reads config.LOGLEVEL(value) [scripts/cr/case.sh:100]' imp "$tmp/ei5.out" "$tmp/ei5.err"
assert_eq "$?" "0" "expression-identifier prose-case panel run succeeds"
assert_has "$(cat "$tmp/ei5.out")" "RE-RAISE (r3 disproved)" \
    "prose case around an identical embedded identifier still folds onto one fingerprint"

# Bracket/comma-joined components each keep their own case verdict — a
# separator between two identifier-shaped fragments must not merge their case
# decisions into one whole-token classification.
checkout_branch bracket-comma-identifier-case
head_bc3="$(advance_head bracket-comma-r3)"
set_registry critic-a
bc_claim='items[0].fooBar, other_Thing disagree [scripts/cr/case.sh:120]'
run_panel 3 "$bc_claim" imp "$tmp/bc3.out" "$tmp/bc3.err"
assert_eq "$?" "0" "bracket-comma seed panel run succeeds"
id_bc3="$(finding_id_at bracket-comma-identifier-case "$head_bc3")"
(
    cd "$repo" || exit 1
    CR_LEDGER="$ledger" bash "$LEDGER_APPEND" amend --branch bracket-comma-identifier-case --head "$head_bc3" \
        --id "$id_bc3" --set verdict=disproved --reason 'the fooBar/other_Thing claim is disproved'
) >/dev/null 2>"$tmp/bc3-amend.err"
assert_eq "$?" "0" "bracket-comma fixture accepts the disproof"
advance_head bracket-comma-r4 >/dev/null
run_panel 4 'items[0].foobar, other_thing disagree [scripts/cr/case.sh:130]' imp "$tmp/bc4.out" "$tmp/bc4.err"
assert_eq "$?" "0" "bracket-comma case panel run succeeds"
assert_has "$(cat "$tmp/bc4.out")" "## Important Issues (1 found)" \
    "each bracket/comma-joined component is fingerprint-significant on its own"
assert_lacks "$(cat "$tmp/bc4.out")" "RE-RAISE (" \
    "differing bracket/comma-joined components do not inherit a disposition"
advance_head bracket-comma-r5 >/dev/null
run_panel 5 'ITEMS[0].fooBar, other_Thing DISAGREE [scripts/cr/case.sh:140]' imp "$tmp/bc5.out" "$tmp/bc5.err"
assert_eq "$?" "0" "bracket-comma prose-case panel run succeeds"
assert_has "$(cat "$tmp/bc5.out")" "RE-RAISE (r3 disproved)" \
    "prose case around identical bracket/comma-joined components still folds onto one fingerprint"

# The deliberate 2901 rule stands: an ALL-CAPS word outside backticks is
# indistinguishable from prose emphasis, so it still folds even under fp3.
checkout_branch prose-caps-still-fold
head_pc3="$(advance_head prose-caps-r3)"
set_registry critic-a
run_panel 3 'CACHE cleanup needed [scripts/cr/case.sh:150]' imp "$tmp/pc3.out" "$tmp/pc3.err"
assert_eq "$?" "0" "prose-caps seed panel run succeeds"
id_pc3="$(finding_id_at prose-caps-still-fold "$head_pc3")"
(
    cd "$repo" || exit 1
    CR_LEDGER="$ledger" bash "$LEDGER_APPEND" amend --branch prose-caps-still-fold --head "$head_pc3" \
        --id "$id_pc3" --set verdict=disproved --reason 'the CACHE claim is disproved'
) >/dev/null 2>"$tmp/pc3-amend.err"
assert_eq "$?" "0" "prose-caps fixture accepts the disproof"
advance_head prose-caps-r4 >/dev/null
run_panel 4 'cache cleanup needed [scripts/cr/case.sh:160]' imp "$tmp/pc4.out" "$tmp/pc4.err"
assert_eq "$?" "0" "prose-caps lowercase panel run succeeds"
assert_has "$(cat "$tmp/pc4.out")" "RE-RAISE (r3 disproved)" \
    "an ALL-CAPS prose word outside backticks still folds onto the lowercase claim"

# codex-1, HIMMEL-2906 round 1: a non-ASCII letter is itself outside
# [A-Za-z0-9_$.], so leaving component-splitting's separator spans unfolded
# let case-only Unicode prose escape the fold entirely.
checkout_branch unicode-prose-still-folds
head_up3="$(advance_head unicode-prose-r3)"
set_registry critic-a
run_panel 3 'Échec critique detected [scripts/cr/case.sh:170]' imp "$tmp/up3.out" "$tmp/up3.err"
assert_eq "$?" "0" "unicode-prose seed panel run succeeds"
id_up3="$(finding_id_at unicode-prose-still-folds "$head_up3")"
(
    cd "$repo" || exit 1
    CR_LEDGER="$ledger" bash "$LEDGER_APPEND" amend --branch unicode-prose-still-folds --head "$head_up3" \
        --id "$id_up3" --set verdict=disproved --reason 'the Echec claim is disproved'
) >/dev/null 2>"$tmp/up3-amend.err"
assert_eq "$?" "0" "unicode-prose fixture accepts the disproof"
advance_head unicode-prose-r4 >/dev/null
run_panel 4 'échec critique detected [scripts/cr/case.sh:180]' imp "$tmp/up4.out" "$tmp/up4.err"
assert_eq "$?" "0" "unicode-prose lowercase panel run succeeds"
assert_has "$(cat "$tmp/up4.out")" "RE-RAISE (r3 disproved)" \
    "a non-ASCII prose word outside backticks still folds onto the lowercase claim"

# The writer's standalone fingerprint copy must agree with the shared helper on
# the case rules too, or a row it writes never matches a claim the panel reads.
checkout_branch code-case-parity
head_ccp="$(advance_head code-case-parity-seed)"
(
    cd "$repo" || exit 1
    CR_LEDGER="$ledger" bash "$LEDGER_APPEND" finding --branch code-case-parity --head "$head_ccp" \
        --model critic-a --id code-case-parity-1 --severity imp --file scripts/cr/case.sh --line 10 \
        --verdict disproved --round 3 \
        --text '- [code-case-parity-1]: Check the `Foo` handler in fooBar [scripts/cr/case.sh:10]'
) >/dev/null 2>"$tmp/code-case-parity-seed.err"
assert_eq "$?" "0" "code-case parity fixture writes through the standalone writer"
advance_head code-case-parity-current >/dev/null
# shellcheck disable=SC2016  # backticks here are markdown code spans in the claim text, not command substitution
run_panel 4 'CHECK the `Foo` HANDLER in fooBar [scripts/cr/case.sh:90]' imp \
    "$tmp/ccp.out" "$tmp/ccp.err"
assert_eq "$?" "0" "code-case parity panel run succeeds"
assert_has "$(cat "$tmp/ccp.out")" "RE-RAISE (r3 disproved)" \
    "writer and panel helper agree on which fragments keep their case"

# Sanity: every current panel run wrote one durable finding row; none was
# silently dropped merely because it rendered in the already-dispositioned block.
assert_eq "$(finding_count_at reraised "$head_r5")" "1" "disproved re-raise remains a durable current-head row"
assert_eq "$(finding_count_at deferred "$head_d8")" "1" "deferred r8 re-raise remains a durable current-head row"
assert_eq "$(finding_count_at deferred "$head_d9")" "1" "deferred r9 re-raise remains a durable current-head row"

if [ "$fails" -gt 0 ]; then
    printf 'FAIL test-finding-reraise (%s failures)\n' "$fails" >&2
    exit 1
fi
printf 'PASS test-finding-reraise\n'
