#!/usr/bin/env bash
# Tests for scripts/lib/cr-review-freshness.sh (HIMMEL-1824 / HIMMEL-1949).
#
# Scope: OUR classification of fixture payloads. These tests never reach
# GitHub — `gh` is stubbed and every fixture is a literal recorded from the
# shapes the tickets measured (PR #1708 / #1728). What is pinned is what this
# lib DECIDES about a payload, not what GitHub would return for one.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }
check() { if [ "$2" = "$3" ]; then pass; else fail "$1: got [$2] want [$3]"; fi; }

HEAD=67b9e0d1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OLD=67439ad6bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# ── stub gh ─────────────────────────────────────────────────────────────────
# Dispatches on the request shape: the GraphQL reviews query vs the issue
# comments REST call. Each arm echoes the file named by an env var, so a case
# sets only the fixtures it cares about.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"reviews(last:"*)  cat "${STUB_REVIEWS:?}" ;;
  *"/issues/"*"/comments"*)
      # Serve a per-page fixture when one exists so pagination is exercised for
      # real; fall back to the single-page fixture every other case sets.
      _args="$*"; _pg="${_args##*page=}"; _pg="${_pg%%&*}"
      case "$_pg" in ''|*[!0-9]*) _pg=1 ;; esac
      echo "$_pg" >> "${STUB_PAGE_LOG:-/dev/null}"
      if [ -n "${STUB_PAGES_DIR:-}" ] && [ -f "$STUB_PAGES_DIR/$_pg.json" ]; then
          cat "$STUB_PAGES_DIR/$_pg.json"
      elif [ -n "${STUB_PAGES_DIR:-}" ]; then
          echo '[]'
      else
          cat "${STUB_COMMENTS:-/dev/null}"
      fi ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/gh"
export GH_CMD="$TMP/bin/gh"

# shellcheck source=scripts/lib/cr-review-freshness.sh
# shellcheck disable=SC1091  # pre-commit runs shellcheck WITHOUT -x, so the
# source cannot be followed when this file is committed on its own
. "$SCRIPT_DIR/cr-review-freshness.sh"

review_json() {  # review_json <oid> <state> <body> <comment-count>
    printf '{"data":{"repository":{"pullRequest":{"reviews":{"totalCount":1,"nodes":[{"author":{"login":"coderabbitai","__typename":"Bot"},"commit":{"oid":"%s"},"state":"%s","body":"%s","comments":{"totalCount":%s}}]}}}}}' \
        "$1" "$2" "$3" "$4"
}

# The walkthrough's machine-readable shape, verbatim from HIMMEL-1824's
# measurement on PR #1708 (marker comment + recent_review block).
walkthrough_json() {  # walkthrough_json <reviewed-to-oid> <clean|dirty>
    local verdict="1 actionable comment was generated"
    [ "$2" = clean ] && verdict="No actionable comments were generated in the recent review"
    # shellcheck disable=SC2016  # literal backticks: CodeRabbit fixture text
    printf '[{"user":{"login":"coderabbitai[bot]","type":"Bot"},"body":"<!-- This is an auto-generated comment: summarize by coderabbit.ai -->\\n%s\\n\\nReviewing files that changed from the base of the PR and between af89948c1111111111111111111111111111111 and %s\\n\\nMerge Risk: Low - up to `%s`"}]' \
        "$verdict" "$1" "${1:0:5}"
}

# ── 1. the object anchor still decides when there IS an object ──────────────
review_json "$HEAD" COMMENTED "looks fine" 1 > "$TMP/r.json"
export STUB_REVIEWS="$TMP/r.json" STUB_COMMENTS=/dev/null
out=$(cr_review_freshness o r 1 "$HEAD"); rc=$?
check "anchored review reads fresh" "$out" "fresh coderabbitai $HEAD"
check "anchored review rc 0" "$rc" "0"

# ── 2. HIMMEL-1824: a clean pass mints NO object — the walkthrough decides ──
# The object sits on an older commit, which is exactly what a clean re-review
# leaves behind. This used to be an unconditional BLOCK and an infinite remedy.
review_json "$OLD" COMMENTED "found something earlier" 2 > "$TMP/r.json"
walkthrough_json "$HEAD" clean > "$TMP/c.json"
export STUB_COMMENTS="$TMP/c.json"
out=$(cr_review_freshness o r 1 "$HEAD")
check "stale object + clean walkthrough at head -> fresh-clean-no-object" \
    "$out" "fresh-clean-no-object coderabbitai $OLD"

# ── 3. a genuinely unreviewed head still BLOCKS ────────────────────────────
# Same stale object, but the walkthrough names a DIFFERENT commit: it says
# nothing about this head, so the stale verdict must survive untouched.
walkthrough_json cccccccc2222222222222222222222222222222 clean > "$TMP/c.json"
out=$(cr_review_freshness o r 1 "$HEAD")
check "walkthrough about another commit does not certify this head" \
    "$out" "stale coderabbitai $OLD"

# A walkthrough AT this head that reports findings is not a clean pass either.
walkthrough_json "$HEAD" dirty > "$TMP/c.json"
out=$(cr_review_freshness o r 1 "$HEAD")
check "walkthrough with actionable comments stays stale" "$out" "stale coderabbitai $OLD"

# No walkthrough at all -> unchanged verdict (fail-closed).
printf '[]' > "$TMP/c.json"
out=$(cr_review_freshness o r 1 "$HEAD")
check "absent walkthrough leaves the stale verdict alone" "$out" "stale coderabbitai $OLD"

# ── 4. HIMMEL-1824: empty auto-reply shells must not fake a review ──────────
# chat.auto_reply mints COMMENTED objects with body "" and zero comments. One
# sitting AT the head must not read as a fresh review.
review_json "$HEAD" COMMENTED "" 0 > "$TMP/r.json"
printf '[]' > "$TMP/c.json"
out=$(cr_review_freshness o r 1 "$HEAD")
check "empty shell at head does not count as a review" "$out" "none"

# ...and one sitting at the head must not bury the real, older review either.
printf '{"data":{"repository":{"pullRequest":{"reviews":{"totalCount":2,"nodes":[{"author":{"login":"coderabbitai","__typename":"Bot"},"commit":{"oid":"%s"},"state":"COMMENTED","body":"real findings","comments":{"totalCount":3}},{"author":{"login":"coderabbitai","__typename":"Bot"},"commit":{"oid":"%s"},"state":"COMMENTED","body":"","comments":{"totalCount":0}}]}}}}}' \
    "$OLD" "$HEAD" > "$TMP/r.json"
out=$(cr_review_freshness o r 1 "$HEAD")
check "empty shell does not mask the latest substantive review" "$out" "stale coderabbitai $OLD"

# ── 5. walkthrough reader in isolation ─────────────────────────────────────
walkthrough_json "$HEAD" clean > "$TMP/c.json"
check "walkthrough clean at head" "$(cr_review_walkthrough o r 1 "$HEAD")" "clean"
# The "up to `<short-oid>`" marker alone must bind the head — that is the only
# head reference in a walkthrough whose file list names no full oid.
# shellcheck disable=SC2016  # literal backticks: CodeRabbit fixture text
printf '[{"user":{"login":"coderabbitai[bot]","type":"Bot"},"body":"<!-- This is an auto-generated comment: summarize by coderabbit.ai -->  No actionable comments were generated in the recent review.  Merge Risk: Low - up to `%s`"}]' \
    "${HEAD:0:7}" > "$TMP/c.json"
check "short-oid marker alone binds the head" \
    "$(cr_review_walkthrough o r 1 "$HEAD")" "clean"

# ...and an abbreviation of a DIFFERENT commit must not.
# shellcheck disable=SC2016  # literal backticks: CodeRabbit fixture text
printf '[{"user":{"login":"coderabbitai[bot]","type":"Bot"},"body":"<!-- This is an auto-generated comment: summarize by coderabbit.ai -->  No actionable comments were generated in the recent review.  Merge Risk: Low - up to `deadbee`"}]' \
    > "$TMP/c.json"
check "short-oid of another commit does not bind the head" \
    "$(cr_review_walkthrough o r 1 "$HEAD")" "none"
walkthrough_json "$HEAD" dirty > "$TMP/c.json"
check "walkthrough dirty at head" "$(cr_review_walkthrough o r 1 "$HEAD")" "dirty"
printf '[{"user":{"login":"someone","type":"User"},"body":"just a human comment"}]' > "$TMP/c.json"
check "non-walkthrough comments read none" "$(cr_review_walkthrough o r 1 "$HEAD")" "none"

# A HUMAN comment carrying the walkthrough marker must NOT certify the head.
# The marker string is public — it appears in every CodeRabbit walkthrough on
# every PR — so selecting on it alone would let any commenter turn a genuine
# stale-anchor BLOCK into a pass (HIMMEL-1058 spoof-resistance stance).
# shellcheck disable=SC2016  # literal backticks: CodeRabbit fixture text
printf '[{"user":{"login":"coderabbitai","type":"User"},"body":"<!-- This is an auto-generated comment: summarize by coderabbit.ai -->  No actionable comments were generated in the recent review.  Merge Risk: Low - up to `%s`"}]' \
    "${HEAD:0:7}" > "$TMP/c.json"
check "a human-authored fake walkthrough does not certify the head" \
    "$(cr_review_walkthrough o r 1 "$HEAD")" "none"

# ...and it must not launder a stale anchor into a pass through the verdict either.
review_json "$OLD" COMMENTED "found something earlier" 2 > "$TMP/r.json"
out=$(cr_review_freshness o r 1 "$HEAD")
check "spoofed walkthrough cannot flip a stale verdict" "$out" "stale coderabbitai $OLD"

# A malformed payload is cannot-evaluate (rc 1), never a verdict — the caller
# fails closed on it.
printf '{"message":"Not Found"}' > "$TMP/c.json"
cr_review_walkthrough o r 1 "$HEAD" >/dev/null 2>&1
check "error object is cannot-evaluate" "$?" "1"

# CR round 4: the head must be named by the reviewed-to FIELD, not merely
# mentioned somewhere in the prose. A walkthrough for an OLDER pass that happens
# to cite this commit in passing must not certify it — an incidental mention is
# not a claim that the head was reviewed.
# shellcheck disable=SC2016  # literal backticks: CodeRabbit fixture text
printf '[{"user":{"login":"coderabbitai[bot]","type":"Bot"},"body":"<!-- This is an auto-generated comment: summarize by coderabbit.ai -->  No actionable comments were generated in the recent review.  See commit %s for background on this refactor.  Reviewing files that changed from the base of the PR and between af89948c1111111111111111111111111111111 and cccccccc2222222222222222222222222222222  Merge Risk: Low - up to `ccccccc`"}]' \
    "$HEAD" > "$TMP/c.json"
check "an incidental mention of the head does not certify it" \
    "$(cr_review_walkthrough o r 1 "$HEAD")" "none"

# ...and the same body must not launder a stale anchor either.
review_json "$OLD" COMMENTED "found something earlier" 2 > "$TMP/r.json"
check "incidental mention cannot flip a stale verdict" \
    "$(cr_review_freshness o r 1 "$HEAD")" "stale coderabbitai $OLD"

# ── 5b. CR round 3: the walkthrough is not always on page one ─────────────
# The per-issue comments endpoint IGNORES sort/direction (measured against the
# live API: the id order is byte-identical with and without them), so ordering
# cannot be used to pull the walkthrough forward — the lookup must paginate.
# Page 1 is a FULL 100 comments of noise; the walkthrough sits on page 2.
mkdir -p "$TMP/pages"
jq -n '[range(100) | {user:{login:"someone",type:"User"}, body:"noise"}]' > "$TMP/pages/1.json"
walkthrough_json "$HEAD" clean > "$TMP/pages/2.json"
export STUB_PAGES_DIR="$TMP/pages" STUB_PAGE_LOG="$TMP/pagelog"
: > "$TMP/pagelog"
check "walkthrough on page 2 is still found" "$(cr_review_walkthrough o r 1 "$HEAD")" "clean"
check "it took exactly two page fetches" "$(wc -l < "$TMP/pagelog" | tr -d ' ')" "2"

# A SHORT page is the last one: stop there instead of spending the whole cap.
: > "$TMP/pagelog"
jq -n '[range(3) | {user:{login:"someone",type:"User"}, body:"noise"}]' > "$TMP/pages/1.json"
rm -f "$TMP/pages/2.json"
check "short first page reads none" "$(cr_review_walkthrough o r 1 "$HEAD")" "none"
check "a short page stops the walk" "$(wc -l < "$TMP/pagelog" | tr -d ' ')" "1"

# The cap is a hard ceiling — a walkthrough beyond it reads none (fail-closed),
# and the walk never runs away.
: > "$TMP/pagelog"
jq -n '[range(100) | {user:{login:"someone",type:"User"}, body:"noise"}]' > "$TMP/pages/1.json"
cp "$TMP/pages/1.json" "$TMP/pages/2.json"
cp "$TMP/pages/1.json" "$TMP/pages/3.json"
out=$(CR_WALK_MAX_PAGES=2 cr_review_walkthrough o r 1 "$HEAD")
check "beyond the page cap reads none" "$out" "none"
check "the page cap is obeyed" "$(wc -l < "$TMP/pagelog" | tr -d ' ')" "2"

# An unreadable page is cannot-evaluate, never "absent" — a page we could not
# read must not be reported as a page with no walkthrough in it.
printf '{"message":"Bad credentials"}' > "$TMP/pages/1.json"
cr_review_walkthrough o r 1 "$HEAD" >/dev/null 2>&1
check "an unreadable page is cannot-evaluate" "$?" "1"
unset STUB_PAGES_DIR STUB_PAGE_LOG

# ── 6. HIMMEL-1949: every call is bounded ──────────────────────────────────
# The ceiling is what keeps this reader safe to call from an interactive flow.
# A gh that never returns must lose to CR_GH_TIMEOUT rather than hang.
if command -v timeout >/dev/null 2>&1; then
    cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
sleep 30
STUB
    chmod +x "$TMP/bin/gh"
    _t0=$SECONDS
    CR_GH_TIMEOUT=2 cr_review_freshness o r 1 "$HEAD" >/dev/null 2>&1
    _rc=$?
    _el=$((SECONDS - _t0))
    check "a wedged gh returns non-zero, does not hang" "$_rc" "1"
    if [ "$_el" -lt 10 ]; then pass; else fail "bounded call took ${_el}s (ceiling was 2s)"; fi

    # CR round 5: 0 passes a digit check but GNU `timeout 0` means NO limit —
    # the exact hang the wrapper exists to prevent, reachable by configuration.
    # 00 too: the guard has to be arithmetic, not a string compare.
    for _bad in 0 00; do
        _t0=$SECONDS
        CR_GH_TIMEOUT="$_bad" cr_review_freshness o r 1 "$HEAD" >/dev/null 2>&1
        _el=$((SECONDS - _t0))
        if [ "$_el" -lt 28 ]; then pass; else
            fail "CR_GH_TIMEOUT=$_bad disabled the ceiling (call ran ${_el}s against a 30s wedge)"; fi
    done
else
    echo "  SKIP: no timeout(1) here — the per-call ceiling is unverified on this platform" >&2
fi

# 7. Wiring canary — EVERY consumer, enumerated mechanically.
#
# The state name is a contract between this lib and everything that reads its
# output, and breaking it is silent in the worst way: an unhandled state falls
# to a catch-all that refuses ("unrecognized freshness state" -> exit 2 in
# check-ci, BLOCK in cr-merge-gate) on a head the App had certified clean.
#
# This trap has now bitten three separate consumers in one PR — the gate arm,
# the --escalate re-query, and cr-merge-gate.sh — each found by review rather
# than by a test, because the earlier canary hard-coded the one consumer it
# knew about. So DISCOVER the consumers instead of listing them: anything that
# calls cr_review_freshness must mention every state this lib can emit. A new
# consumer, or a new state, fails here rather than in production.
CRF_STATES="fresh fresh-clean-no-object stale none paged"
consumers=$(grep -rl 'cr_review_freshness' "$SCRIPT_DIR/.." --include='*.sh' 2>/dev/null \
    | grep -v '/test-' | grep -v 'cr-review-freshness\.sh$' | sort)

# A canary that discovers nothing passes vacuously — the failure mode this
# whole suite exists to refuse. Assert the discovery itself found consumers.
_n_consumers=$(printf '%s\n' "$consumers" | grep -c . || true)
if [ "${_n_consumers:-0}" -ge 2 ]; then pass; else
    fail "consumer discovery found ${_n_consumers:-0} consumer(s) of cr_review_freshness — expected at least check-ci.sh and cr-merge-gate.sh"; fi

for _f in $consumers; do
    for _st in $CRF_STATES; do
        # Anchored to CASE-ARM position, not free text (CR round 7): a bare
        # substring match is satisfied by a comment or a diagnostic string, so
        # a consumer could mention the state in prose while never handling it.
        # A case arm is a line of pattern alternatives ending in ) or | — and
        # the leading character class excludes #, so comments cannot satisfy it.
        if grep -qE "^[[:space:]]*[a-z|*?-]*${_st}[)|]" "$_f"; then pass; else
            fail "$(basename "$_f") never mentions the '$_st' state this lib can emit — it would hit that file's catch-all and refuse a head the App certified"; fi
    done
done

# CR round 5: the walkthrough acceptance inside _cr_body_escalate must certify
# the SAME things the object path does, or it is a cheaper door into the same
# success — a failure/error status from the escalated pass would be invisible,
# and the caller would judge outside-diff findings from the PRE-escalation read.
# Structural, because reaching that branch for real needs the ~51min check-ci
# suite: assert the branch consults the raw status reader and re-reads the body.
_esc=$(sed -n '/cr_review_walkthrough/,/return 0 ;;/p' "$SCRIPT_DIR/../check-ci.sh")
if printf '%s' "$_esc" | grep -qF -- 'cr_signal_state'; then pass; else
    fail "the escalate walkthrough return does not re-check CodeRabbit's status"; fi
if printf '%s' "$_esc" | grep -qF -- '_cr_body_read'; then pass; else
    fail "the escalate walkthrough return does not re-read the review body"; fi
# ...and it must NOT call cr_signal_gate, which exits 2 on `pending` and would
# turn "keep waiting" into a spurious re-run mid-loop.
if printf '%s' "$_esc" | grep -qE '^[[:space:]]*cr_signal_gate[[:space:]]*$'; then
    fail "the escalate walkthrough return calls cr_signal_gate — it exits 2 on pending"
else pass; fi

# CR round 6: fresh-clean-no-object is minted from walkthrough TEXT, which
# cannot say the CURRENT pass concluded — a clean pass at H, then a re-review of
# H that FAILS, leaves the walkthrough still reading clean. So every consumer
# must certify the bot's head status before it can act on this state. All of
# them do today (check-ci runs cr_signal_gate before review_freshness_gate;
# cr-merge-gate blocks on the status in its section 1, catch-all included), and
# this keeps it structural rather than incidental — the same discovery approach
# the state-name canary above uses, applied to the precondition.
for _f in $consumers; do
    if grep -qE 'cr_signal_(gate|state)\b' "$_f"; then pass; else
        fail "$(basename "$_f") consumes cr_review_freshness but never certifies the bot head STATUS — fresh-clean-no-object would pass a failed/pending review as fresh"; fi
done

# HIMMEL-1374: `none` (zero bot reviews on the PR, at any head, ever) is no
# longer an unconditional self-skip in the consumers — an App status that reads
# "Review completed" over a PR with no review object at all is a contradiction,
# not a pass. But a CLEAN pass mints no object either (HIMMEL-1824, the state
# above), so a `none` arm that refuses WITHOUT consulting the walkthrough
# false-BLOCKS every PR whose only pass came back clean. Structural for the same
# reason as the canaries above: reaching check-ci's half for real needs the
# ~51min suite, and the walkthrough reader will not accept the short synthetic
# head SHAs those consumer suites are built on.
for _f in $consumers; do
    _none_arm=$(sed -n '/^[[:space:]]*none)/,/;;/p' "$_f")
    if printf '%s' "$_none_arm" | grep -qF -- 'cr_review_walkthrough'; then pass; else
        fail "$(basename "$_f")'s 'none' arm never consults cr_review_walkthrough — a clean pass mints no review object, so refusing on zero-reviews alone blocks a head the App certified"; fi
done

# The gate arm and the --escalate re-query live in the SAME file, so the
# mention scan above cannot tell them apart. Pin the escalate consumer
# explicitly: it is the one that broke in CR round 3, by accepting the literal
# "fresh" only while the walkthrough path returns fresh-clean-no-object.
if grep -qF -- "fresh|fresh-clean-no-object)" "$SCRIPT_DIR/../check-ci.sh"; then pass; else
    fail "check-ci.sh --escalate re-query does not accept fresh-clean-no-object as terminal"; fi

echo "cr-review-freshness: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
