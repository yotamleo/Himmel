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
mk_two_page_reviews() {
    jq -n --argjson uid "$2" --arg commit "$3" --rawfile body "$4" \
        '[{user:{id:$uid,login:"coderabbitai[bot]"}, commit_id:$commit, body:$body}]' > "$1"
    jq -n --argjson uid "$2" --arg commit "$5" --rawfile body "$6" \
        '[{user:{id:$uid,login:"coderabbitai[bot]"}, commit_id:$commit, body:$body}]' >> "$1"
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

t outside-diff-pr1261-parses-at-head          outside-1261        0 "outside=2 nitpick=0 additional=0 prior_outside=0 markers=2 head_reviews=1"
t nitpick-pr466-parses-at-head                nitpick-466         0 "outside=0 nitpick=1 additional=0 prior_outside=0 markers=1 head_reviews=1"
t clean-body-all-zero                         clean               0 "outside=0 nitpick=0 additional=0 prior_outside=0 markers=0 head_reviews=1"
# anti-drift canaries — the whole point of this reader. rc 2: POSITIVE
# evidence of an unparseable finding (the body SHOWS a section keyword but
# won't parse), never a false 0/"pass" (which would be rc 1's territory —
# reserved for INFRASTRUCTURE failures, see the gh-error/non-array cases
# below).
t drift-canary-no-count-blocks                drift-canary        2
t markers-without-section-blocks              markers-no-section  2
# HIMMEL-1126 delta A2: an older head's outside-diff findings feed
# prior_outside, not outside — there is no review AT head at all here.
t prior-head-only-outside-not-counted-at-head prior-only          0 "outside=0 nitpick=0 additional=0 prior_outside=2 markers=0 head_reviews=0"
t zero-reviews-at-head-allows                 zero-reviews        0 "outside=0 nitpick=0 additional=0 prior_outside=0 markers=0 head_reviews=0"
# INFRASTRUCTURE cannot-evaluate (rc 1) — the query itself gave nothing to
# parse, distinct from the rc 2 canaries above which DID have a body to read.
t non-array-payload-blocks                    non-array           1
t gh-api-error-blocks                         error               1
# HIMMEL-1058: right body, wrong creator id -> not CodeRabbit, all zero.
t identity-wrong-user-id-treated-as-no-review identity-wrong-id   0 "outside=0 nitpick=0 additional=0 prior_outside=0 markers=0 head_reviews=0"
# codex CR: `--paginate` on a >30-review PR emits TWO top-level arrays on the
# stream, not one merged array — the flatten (`jq -s 'add // []'`) must
# combine both pages' reviews into one result, not read the multi-document
# stream as cannot-evaluate.
t two-page-reviews-flatten-and-sum            two-page            0 "outside=2 nitpick=1 additional=0 prior_outside=0 markers=3 head_reviews=2"

# zero-head-reviews note lands on stderr (both the truly-empty and the
# prior-only-no-head-review cases).
grep -qi "no CodeRabbit review at head" "$TMP/err-zero-reviews-at-head-allows" \
    || { echo "FAIL missing zero-head-review stderr note (zero-reviews)"; fail=$((fail+1)); }
grep -qi "no CodeRabbit review at head" "$TMP/err-prior-head-only-outside-not-counted-at-head" \
    || { echo "FAIL missing zero-head-review stderr note (prior-only)"; fail=$((fail+1)); }

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
