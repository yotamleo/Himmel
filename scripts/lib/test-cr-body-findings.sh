#!/usr/bin/env bash
# Tests for scripts/lib/cr-body-findings.sh (HIMMEL-1126/1147). Hermetic: gh
# is stubbed. Mirrors test-cr-merge-gate.sh's hermetic-stub / t() shape.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"

FIXDIR="$SCRIPT_DIR/fixtures/cr-body"
OUTSIDE_BODY="$FIXDIR/pr-1261-outside-diff-2.body.txt"   # real: outside=2 nitpick=0 additional=0 markers=2
NITPICK_BODY="$FIXDIR/pr-466-nitpick.body.txt"           # real: outside=0 nitpick=1 additional=0 markers=1

# ── synthetic fixtures (kept inline — small, one-off; NOT captured CodeRabbit
# output like the two files above) ──────────────────────────────────────────
# CLEAN: no Outside/Nitpick/Additional sections and no markers at all.
CLEAN_BODY='**Actionable comments posted: 0**'
# DRIFT-CANARY: contains the literal phrase "Outside diff" but the count never
# parses (no "(N)" immediately after "range comments") — the anti-silent-
# regression guard this reader exists to enforce (see cr-body-findings.sh
# header). Must read as cannot-evaluate, never a silent outside=0.
DRIFT_BODY='Something changed. Outside diff range comments were noted but the section header lost its count during a CodeRabbit format change.'
# MARKERS-WITHOUT-SECTION: a per-comment cr-comment:v1:<id> marker present
# with NO section header at all — second canary (format drift: CodeRabbit
# said something, this reader parsed nothing).
MARKERS_NO_SECTION_BODY='All good. <!-- cr-comment:v1:deadbeef01 --> nothing else to report.'
# HIMMEL-1582: a substantive head body carrying ONE outside-diff finding + one
# marker (outside=1, markers=1, no drift). Seeds the "older review had a
# finding" side of the latest-substantive-wins cases below.
BODY_OUTSIDE1='**⚠️ Outside diff range comments (1)**

- <!-- cr-comment:v1:out1abc --> this finding is outside the diff hunk.'

UID_OK=136622811
UID_WRONG=999999
HEAD=abc123
PRIOR=oldsha1

RESP_DIR="$TMP/resp"; mkdir -p "$RESP_DIR"
export RESP_DIR

# mk_json_from_file/_str <out> <uid> <commit> <body-source> — build a
# one-review `pulls/.../reviews` payload the way GitHub actually shapes it
# (`.user.id`, `.commit_id`, `.body`).
mk_json_from_file() {
    jq -n --argjson uid "$2" --arg commit "$3" --rawfile body "$4" \
        '[{user:{id:$uid,login:"coderabbitai[bot]"}, commit_id:$commit, body:$body}]' > "$1"
}
mk_json_from_str() {
    jq -n --argjson uid "$2" --arg commit "$3" --arg body "$4" \
        '[{user:{id:$uid,login:"coderabbitai[bot]"}, commit_id:$commit, body:$body}]' > "$1"
}
# mk_two_page_reviews <out> <uid> <commit-a> <bodyfile-a> <commit-b> <bodyfile-b>
# — TWO separate top-level JSON-array documents concatenated in one file, the
# real `gh api ... --paginate` shape for a PR with more reviews than fit on
# one page (>30): each page is its own array on the stream, NOT one
# pre-merged array. Regression fixture for the codex CR finding that the
# reader's `type=="array"` canary read a multi-page stream as cannot-evaluate.
# submitted_at/id are seeded (page 2 LATER than page 1) so the latest-wins
# derivation (HIMMEL-1582) is deterministic, the way a real payload always
# carries both fields.
mk_two_page_reviews() {
    jq -n --argjson uid "$2" --arg commit "$3" --rawfile body "$4" \
        '[{user:{id:$uid,login:"coderabbitai[bot]"}, commit_id:$commit, submitted_at:"2024-01-01T00:00:00Z", id:1001, body:$body}]' > "$1"
    jq -n --argjson uid "$2" --arg commit "$5" --rawfile body "$6" \
        '[{user:{id:$uid,login:"coderabbitai[bot]"}, commit_id:$commit, submitted_at:"2024-01-01T00:00:01Z", id:1002, body:$body}]' >> "$1"
}
# mk_two_head_reviews <out> <uid> <commit> <body1> <body2> — TWO bot reviews at
# the SAME head in ONE array (review 1 earlier id 2001, review 2 LATER id 2002,
# so review 2 is the "latest"). Inline body STRINGS (not files). Exercises the
# latest-SUBSTANTIVE-wins derivation (HIMMEL-1582): the older review's findings
# must NOT bleed into the chosen review's counts.
mk_two_head_reviews() {
    jq -n --argjson uid "$2" --arg commit "$3" --arg b1 "$4" --arg b2 "$5" \
        '[{user:{id:$uid,login:"coderabbitai[bot]"},commit_id:$commit,submitted_at:"2024-01-01T00:00:00Z",id:2001,body:$b1},
          {user:{id:$uid,login:"coderabbitai[bot]"},commit_id:$commit,submitted_at:"2024-01-01T00:00:01Z",id:2002,body:$b2}]' > "$1"
}

mk_json_from_file "$RESP_DIR/outside-1261.json"       "$UID_OK"    "$HEAD"  "$OUTSIDE_BODY"
mk_json_from_file "$RESP_DIR/nitpick-466.json"        "$UID_OK"    "$HEAD"  "$NITPICK_BODY"
mk_json_from_str  "$RESP_DIR/clean.json"              "$UID_OK"    "$HEAD"  "$CLEAN_BODY"
mk_json_from_str  "$RESP_DIR/drift-canary.json"       "$UID_OK"    "$HEAD"  "$DRIFT_BODY"
mk_json_from_str  "$RESP_DIR/markers-no-section.json" "$UID_OK"    "$HEAD"  "$MARKERS_NO_SECTION_BODY"
# prior-only: the outside-diff body attached to a review at an OLDER head
# (commit_id != HEAD) and NO review at HEAD at all.
mk_json_from_file "$RESP_DIR/prior-only.json"         "$UID_OK"    "$PRIOR" "$OUTSIDE_BODY"
echo '[]' > "$RESP_DIR/zero-reviews.json"
echo '{}' > "$RESP_DIR/non-array.json"
# identity: right body, WRONG user.id at head -> must be treated as no review.
mk_json_from_file "$RESP_DIR/identity-wrong-id.json"  "$UID_WRONG" "$HEAD"  "$OUTSIDE_BODY"
# two-page: a >30-review PR's --paginate output is TWO top-level arrays on
# the stream (page 1: the nitpick review, page 2: the outside-diff review),
# both at HEAD -> the flatten must combine them into one review set, not
# read the multi-document stream as cannot-evaluate.
mk_two_page_reviews "$RESP_DIR/two-page.json" "$UID_OK" "$HEAD" "$NITPICK_BODY" "$HEAD" "$OUTSIDE_BODY"
# ── HIMMEL-1582 latest-substantive-wins fixtures ───────────────────────────
# (1) two head reviews: OLDER carries outside(1)+marker, LATER is substantive
#     but clean -> latest SUBSTANTIVE (the clean one) wins -> outside=0. This
#     is the false-BLOCK fix: the old SUM gave outside=1 and could never clear.
mk_two_head_reviews "$RESP_DIR/two-head-clean-latest.json" "$UID_OK" "$HEAD" "$BODY_OUTSIDE1" "$CLEAN_BODY"
# (2) two head reviews: OLDER carries outside(1)+marker, LATER has an EMPTY
#     body (the PR #1583 shape) -> the empty LATER review is NOT substantive,
#     so the OLDER substantive one wins -> outside=1. Naive latest-wins would
#     read the empty body and false-GREEN to outside=0; the filter stops that.
mk_two_head_reviews "$RESP_DIR/two-head-empty-latest.json" "$UID_OK" "$HEAD" "$BODY_OUTSIDE1" ""
# (3) all head reviews empty (NONE substantive) -> counts 0 but a stderr NOTE
#     flags it (NOT silently green). head_reviews still counts the reviews.
mk_two_head_reviews "$RESP_DIR/two-head-all-empty.json" "$UID_OK" "$HEAD" "" ""
# (4) prior_outside unchanged alongside the new head derivation: an OLDER-head
#     outside-diff review (outside=2) + a clean substantive review AT head ->
#     outside=0 (head clean), prior_outside=2 (summed across non-head commits,
#     untouched by the head change).
jq -n --argjson uid "$UID_OK" --arg head "$HEAD" --arg prior "$PRIOR" \
    --rawfile pbody "$OUTSIDE_BODY" --arg hbody "$CLEAN_BODY" \
    '[{user:{id:$uid,login:"coderabbitai[bot]"},commit_id:$prior,submitted_at:"2024-01-01T00:00:00Z",id:3001,body:$pbody},
      {user:{id:$uid,login:"coderabbitai[bot]"},commit_id:$head,submitted_at:"2024-01-01T00:00:01Z",id:3002,body:$hbody}]' \
    > "$RESP_DIR/prior-plus-clean-head.json"

# ── stub gh ──────────────────────────────────────────────────────────────────
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${GH_STUB_LOG:?}"
case "${GH_STUB_MODE:?}" in
  error) exit 1 ;;
esac
case "$1 $2" in
  "api repos/o/r/pulls/42/reviews"*)
    cat "${RESP_DIR:?}/$GH_STUB_MODE.json" ;;
  *) echo '{}' ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# shellcheck disable=SC1091
. "$SCRIPT_DIR/cr-body-findings.sh"

pass=0; fail=0
t() { # t <name> <GH_STUB_MODE> <expected-rc> [<expected-stdout-line>]
    local name="$1" mode="$2" want="$3" want_out="${4:-}" rc=0 out
    export GH_STUB_MODE="$mode"
    export GH_STUB_LOG="$TMP/calls-$name.log"; : > "$GH_STUB_LOG"
    out=$(cr_body_findings o r 42 "$HEAD" 2>"$TMP/err-$name") || rc=$?
    if [ "$rc" != "$want" ]; then
        fail=$((fail+1)); echo "FAIL $name (rc=$rc want=$want) out='$out'"
        sed 's/^/  err: /' "$TMP/err-$name"
        return
    fi
    if [ -n "$want_out" ] && [ "$out" != "$want_out" ]; then
        fail=$((fail+1)); echo "FAIL $name (stdout mismatch) got='$out' want='$want_out'"
        return
    fi
    pass=$((pass+1)); echo "ok   $name"
}

t outside-diff-pr1261-parses-at-head          outside-1261        0 "outside=2 nitpick=0 additional=0 prior_outside=0 markers=2 head_reviews=1 substantive=1"
t nitpick-pr466-parses-at-head                nitpick-466         0 "outside=0 nitpick=1 additional=0 prior_outside=0 markers=1 head_reviews=1 substantive=1"
t clean-body-all-zero                         clean               0 "outside=0 nitpick=0 additional=0 prior_outside=0 markers=0 head_reviews=1 substantive=1"
# anti-drift canaries — the whole point of this reader. rc 2: POSITIVE
# evidence of an unparseable finding (the body SHOWS a section keyword but
# won't parse), never a false 0/"pass" (which would be rc 1's territory —
# reserved for INFRASTRUCTURE failures, see the gh-error/non-array cases
# below).
t drift-canary-no-count-blocks                drift-canary        2
t markers-without-section-blocks              markers-no-section  2
# HIMMEL-1126 delta A2: an older head's outside-diff findings feed
# prior_outside, not outside — there is no review AT head at all here.
t prior-head-only-outside-not-counted-at-head prior-only          0 "outside=0 nitpick=0 additional=0 prior_outside=2 markers=0 head_reviews=0 substantive=0"
t zero-reviews-at-head-allows                 zero-reviews        0 "outside=0 nitpick=0 additional=0 prior_outside=0 markers=0 head_reviews=0 substantive=0"
# INFRASTRUCTURE cannot-evaluate (rc 1) — the query itself gave nothing to
# parse, distinct from the rc 2 canaries above which DID have a body to read.
t non-array-payload-blocks                    non-array           1
t gh-api-error-blocks                         error               1
# HIMMEL-1058: right body, wrong creator id -> not CodeRabbit, all zero.
t identity-wrong-user-id-treated-as-no-review identity-wrong-id   0 "outside=0 nitpick=0 additional=0 prior_outside=0 markers=0 head_reviews=0 substantive=0"
# codex CR: `--paginate` on a >30-review PR emits TWO top-level arrays on the
# stream, not one merged array — the flatten (`jq -s 'add // []'`) must
# combine both pages' reviews into one result, not read the multi-document
# stream as cannot-evaluate. Both reviews here are at HEAD and substantive, so
# under HIMMEL-1582 the LATER page (the outside-diff review, id 1002) is the
# chosen one; head_reviews=2 still proves both pages were flattened in.
t two-page-reviews-flatten-and-pick-latest    two-page            0 "outside=2 nitpick=0 additional=0 prior_outside=0 markers=2 head_reviews=2 substantive=2"
# HIMMEL-1582: latest SUBSTANTIVE head review wins, not the sum.
# (1) false-BLOCK fix: older review outside(1), later substantive+clean ->
#     outside=0 (the old SUM gave 1 and could never clear without moving head).
t two-head-clean-latest-wins                  two-head-clean-latest   0 "outside=0 nitpick=0 additional=0 prior_outside=0 markers=0 head_reviews=2 substantive=2"
# (2) false-GREEN guard (PR #1583 shape): older outside(1), later EMPTY body ->
#     the empty later review is skipped, the older substantive one wins ->
#     outside=1. Naive latest-wins on the empty body would false-GREEN to 0.
t two-head-empty-latest-keeps-finding         two-head-empty-latest  0 "outside=1 nitpick=0 additional=0 prior_outside=0 markers=1 head_reviews=2 substantive=1"
# (3) prior_outside unchanged alongside the new head derivation: older-head
#     outside=2 + a clean substantive review at head -> outside=0, prior_outside=2.
t prior-plus-clean-head-prior-outside         prior-plus-clean-head  0 "outside=0 nitpick=0 additional=0 prior_outside=2 markers=0 head_reviews=1 substantive=1"
# (4) all head reviews empty (none substantive) -> counts 0, head_reviews counts
#     them, rc 0 — NOT silently green (a stderr note flags it; checked below).
t two-head-all-empty-note                     two-head-all-empty     0 "outside=0 nitpick=0 additional=0 prior_outside=0 markers=0 head_reviews=2 substantive=0"

# zero-head-reviews note lands on stderr (both the truly-empty and the
# prior-only-no-head-review cases).
grep -qi "no CodeRabbit review at head" "$TMP/err-zero-reviews-at-head-allows" \
    || { echo "FAIL missing zero-head-review stderr note (zero-reviews)"; fail=$((fail+1)); }
grep -qi "no CodeRabbit review at head" "$TMP/err-prior-head-only-outside-not-counted-at-head" \
    || { echo "FAIL missing zero-head-review stderr note (prior-only)"; fail=$((fail+1)); }
# HIMMEL-1582: head reviews existed but NONE was substantive (all empty bodies)
# -> a stderr note must flag it so the all-zero output is not silently green.
grep -qi "none carried a substantive body" "$TMP/err-two-head-all-empty-note" \
    || { echo "FAIL missing all-empty-substantive stderr note"; fail=$((fail+1)); }

# ── HIMMEL-3124: per-finding outside-diff extraction ─────────────────────────
# cr_body_outside_findings emits one TSV row per outside-diff finding:
#   id <TAB> sev <TAB> file <TAB> line <TAB> title
# id = cr-od-<12 hex of sha256(file US line US title)>; the LINE is the literal
# token (a range like 80-91 stays a string); the FILE is the full path.
# The expected ids below were computed with an independent shell recipe
# (printf file US line US title | sha256sum | cut -c1-12), not by the reader.
OD_BQ="$FIXDIR/pr-777-outside-diff-blockquote.body.txt"       # real #777 80d070db: > layout, Minor
OD_RANGE="$FIXDIR/pr-777-outside-the-diff-range.body.txt"     # real #777 a9836768: plain layout, "Outside the diff (1)", range line, Major
OD_BASENAME="$FIXDIR/pr-888-outside-diff-basename.body.txt"   # real #888 3b7cd149: basename in <summary>, full path on the path line
OD_LEGACY="$FIXDIR/pr-1261-outside-diff-2.body.txt"           # real #1261: per-file <summary>, `7-20`: line form
TAB=$(printf '\t')
mk_json_from_file "$RESP_DIR/od-bq.json"       "$UID_OK" "$HEAD" "$OD_BQ"
mk_json_from_file "$RESP_DIR/od-range.json"    "$UID_OK" "$HEAD" "$OD_RANGE"
mk_json_from_file "$RESP_DIR/od-basename.json" "$UID_OK" "$HEAD" "$OD_BASENAME"
mk_json_from_file "$RESP_DIR/od-legacy.json"   "$UID_OK" "$HEAD" "$OD_LEGACY"
# The SAME finding rendered without the "> " blockquote prefix must yield the
# same id (R12): the id keys on file/line/title, never on the layout.
sed 's/^> \{0,1\}//' "$OD_BQ" > "$TMP/od-bq-dequoted.txt"
mk_json_from_file "$RESP_DIR/od-bq-dequoted.json" "$UID_OK" "$HEAD" "$TMP/od-bq-dequoted.txt"
mk_json_from_file "$RESP_DIR/od-wrong-id.json"    "$UID_WRONG" "$HEAD" "$OD_BQ"
# Header says (2) but only one finding parses out: count mismatch = format drift.
sed 's/Outside diff range comments (1)/Outside diff range comments (2)/' "$OD_BQ" > "$TMP/od-bq-count2.txt"
mk_json_from_file "$RESP_DIR/od-count-mismatch.json" "$UID_OK" "$HEAD" "$TMP/od-bq-count2.txt"
# Header present, but no finding body follows it: nothing extractable.
mk_json_from_str "$RESP_DIR/od-header-only.json" "$UID_OK" "$HEAD" '**⚠️ Outside diff range comments (1)**

nothing else survived a format change'
# The selector is SHARED with cr_body_findings: an older head review carrying an
# outside finding is superseded by a later substantive clean review.
mk_two_head_reviews "$RESP_DIR/od-two-head-clean-latest.json" "$UID_OK" "$HEAD" "$(cat "$OD_BQ")" "$CLEAN_BODY"
mk_json_from_str "$RESP_DIR/od-clean.json" "$UID_OK" "$HEAD" "$CLEAN_BODY"

# to <name> <GH_STUB_MODE> <expected-rc> <expected-stdout>
to() {
    local name="$1" mode="$2" want="$3" want_out="$4" rc=0 out
    export GH_STUB_MODE="$mode"
    export GH_STUB_LOG="$TMP/calls-$name.log"; : > "$GH_STUB_LOG"
    out=$(cr_body_outside_findings o r 42 "$HEAD" 2>"$TMP/err-$name") || rc=$?
    if [ "$rc" != "$want" ]; then
        fail=$((fail+1)); echo "FAIL $name (rc=$rc want=$want) out='$out'"
        sed 's/^/  err: /' "$TMP/err-$name"
        return
    fi
    if [ "$out" != "$want_out" ]; then
        fail=$((fail+1)); echo "FAIL $name (stdout mismatch)"
        echo "  got:  $(printf '%s' "$out" | tr '\n\t' '|~')"
        echo "  want: $(printf '%s' "$want_out" | tr '\n\t' '|~')"
        return
    fi
    pass=$((pass+1)); echo "ok   $name"
}
OD_BQ_ROW="cr-od-39c3193c8945${TAB}sug${TAB}.pre-commit-config.yaml${TAB}459${TAB}Keep \`context7-mcp\` in the description-cap gate."
OD_RANGE_ROW="cr-od-2b1a31ba0692${TAB}imp${TAB}marketplace/plugins/himmel-ops/README.md${TAB}80-91${TAB}Use the installed \`lean-skills\` namespace in Minerva hand-offs."
OD_BASENAME_ROW="cr-od-8ed0fb1cf579${TAB}imp${TAB}templates/luna-second-brain/scripts/upgrade.sh${TAB}427${TAB}Make the snapshot baseline support format equivalence."
OD_LEGACY_ROWS="cr-od-eeba561a5fa4${TAB}sug${TAB}scripts/codex/sanitize-plugin-hooks.ps1${TAB}7-20${TAB}Qualify the legacy parser behavior by Codex version.
cr-od-588006168ade${TAB}sug${TAB}scripts/codex/sanitize-plugin-hooks.sh${TAB}4-20${TAB}Qualify the legacy parser behavior by Codex version."
to od-blockquote-layout        od-bq             0 "$OD_BQ_ROW"
to od-plain-layout-same-id     od-bq-dequoted    0 "$OD_BQ_ROW"
to od-range-line-and-the-diff  od-range          0 "$OD_RANGE_ROW"
to od-full-path-not-basename   od-basename       0 "$OD_BASENAME_ROW"
to od-legacy-per-file-summary  od-legacy         0 "$OD_LEGACY_ROWS"
to od-header-count-mismatch    od-count-mismatch 2 ""
to od-header-without-finding   od-header-only    2 ""
to od-clean-body-no-rows       od-clean          0 ""
to od-shared-selector-later-clean-wins od-two-head-clean-latest 0 ""
to od-wrong-user-id-no-rows    od-wrong-id       0 ""
to od-infra-error-rc1          error             1 ""
# cr_body_findings itself: the header variant "Outside the diff (N)" is now
# COUNTED (before, outside read 0 and only the markers canary caught it).
t the-diff-header-counted      od-range          0 "outside=1 nitpick=0 additional=0 prior_outside=0 markers=1 head_reviews=1 substantive=1"
t legacy-layout-still-counts-2 od-legacy         0 "outside=2 nitpick=0 additional=0 prior_outside=0 markers=2 head_reviews=1 substantive=1"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
