#!/usr/bin/env bash
# Tests for scripts/lib/cr-merge-gate.sh (HIMMEL-936). Hermetic: gh is stubbed.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"

# ── stub gh ──────────────────────────────────────────────────────────────────
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${GH_STUB_LOG:?}"
case "${GH_STUB_MODE:?}" in
  error) exit 1 ;;
esac
case "$1 $2" in
  "pr view")
    # api-error mode: pr view SUCCEEDS, later api calls fail (distinguishes
    # rc=3 selector-unresolvable from rc=0 downstream-API fail-open).
    echo '{"number":42,"headRefOid":"abc123","url":"https://github.com/o/r/pull/42"}' ;;
  "api graphql")
    case "$GH_STUB_MODE" in
      api-error) exit 1 ;;
      # pageInfo mirrors the real API: the gate's query requests it, so GitHub
      # always returns it (HIMMEL-994 — fixtures without it hit the 980-r3
      # page-completeness BLOCK and mis-fail the allow cases).
      unresolved|cr-degraded-unresolved) echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"coderabbitai"}}]}}]}}}}}' ;;
      other-author) echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"someuser"}}]}}]}}}}}' ;;
      paged) echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true},"nodes":[{"isResolved":true,"comments":{"nodes":[{"author":{"login":"coderabbitai"}}]}}]}}}}}' ;;
      *) echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":true,"comments":{"nodes":[{"author":{"login":"coderabbitai"}}]}}]}}}}}' ;;
    esac ;;
  # CodeRabbit publishes a commit STATUS, never a check-run (HIMMEL-1072).
  # These fixtures previously mocked it as a check-run, which is why the suite
  # stayed green over a gate that could not fire: nothing in production ever
  # matched `select(.name=="CodeRabbit")` on .check_runs. Shape below is copied
  # from a live /statuses response (newest-first; creator.id 136622811 =
  # coderabbitai[bot]).
  "api repos/o/r/commits/abc123/statuses"*)
    case "$GH_STUB_MODE" in
      api-error) exit 1 ;;
      # The verdict query flakes (a real 503 was observed live on this endpoint)
      # WHILE a coderabbit thread sits unresolved. The degraded verdict must not
      # short-circuit past that evidence (codex-1).
      cr-degraded-unresolved) echo "statuses boom" >&2; exit 1 ;;
      inflight) echo '[{"context":"CodeRabbit","state":"pending","created_at":"2026-07-16T19:08:46Z","creator":{"id":136622811,"login":"coderabbitai[bot]","type":"Bot"}}]' ;;
      cr-absent) echo '[]' ;;
      cr-failure) echo '[{"context":"CodeRabbit","state":"failure","created_at":"2026-07-16T19:10:05Z","creator":{"id":136622811,"login":"coderabbitai[bot]","type":"Bot"}}]' ;;
      # An impostor: right context + right login, WRONG creator.id. The whole
      # point of HIMMEL-1058's identity match — display names are spoofable,
      # the bot's user id is not.
      cr-spoofed) echo '[{"context":"CodeRabbit","state":"success","created_at":"2026-07-16T19:10:05Z","creator":{"id":999999,"login":"coderabbitai[bot]","type":"Bot"}}]' ;;
      # Superseded pending: newest-first, so the success at the head wins.
      cr-superseded) echo '[{"context":"CodeRabbit","state":"success","created_at":"2026-07-16T19:10:05Z","creator":{"id":136622811,"login":"coderabbitai[bot]","type":"Bot"}},{"context":"CodeRabbit","state":"pending","created_at":"2026-07-16T19:08:46Z","creator":{"id":136622811,"login":"coderabbitai[bot]","type":"Bot"}}]' ;;
      # A FULL page (100) of unrelated statuses and no CodeRabbit among them —
      # its verdict may be on page two, so this is indeterminate, NOT absent
      # (coderabbit-2). Must block rather than degrade (a degrade fails open).
      cr-paged) jq -nc '[range(100) | {context: "ci/ctx\(.)", state: "success", created_at: "2026-07-16T19:10:05Z", creator: {id: 1, login: "ci", type: "Bot"}}]' ;;
      # 100 unrelated statuses but CodeRabbit IS on the page: newest-first means
      # a match on page one is the newest by construction — no paging needed.
      cr-paged-found) jq -nc '[{context: "CodeRabbit", state: "success", created_at: "2026-07-16T19:10:05Z", creator: {id: 136622811, login: "coderabbitai[bot]", type: "Bot"}}] + [range(99) | {context: "ci/ctx\(.)", state: "success", created_at: "2026-07-16T19:09:00Z", creator: {id: 1, login: "ci", type: "Bot"}}]' ;;
      *) echo '[{"context":"CodeRabbit","state":"success","created_at":"2026-07-16T19:10:05Z","creator":{"id":136622811,"login":"coderabbitai[bot]","type":"Bot"}}]' ;;
    esac ;;
  # CodeRabbit's review-BODY findings (HIMMEL-1126/1147) — a separate
  # endpoint from the commit status above. Default '[]' (no review posted
  # yet at this head) keeps every UNRELATED test case above reaching this
  # point rc-0/all-zero, so their assertions stay exactly as they were before
  # this gate existed.
  "api repos/o/r/pulls/42/reviews"*)
    case "$GH_STUB_MODE" in
      body-outside) echo '[{"user":{"id":136622811,"login":"coderabbitai[bot]"},"commit_id":"abc123","body":"Outside diff range comments (2)"}]' ;;
      body-nitpick) echo '[{"user":{"id":136622811,"login":"coderabbitai[bot]"},"commit_id":"abc123","body":"Nitpick comments (1)"}]' ;;
      body-drift)   echo '[{"user":{"id":136622811,"login":"coderabbitai[bot]"},"commit_id":"abc123","body":"Outside diff range comments were noted but the count did not survive a format change"}]' ;;
      body-error)   exit 1 ;;
      *)            echo '[]' ;;
    esac ;;
  *) echo '{}' ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# shellcheck disable=SC1091
. "$SCRIPT_DIR/cr-merge-gate.sh"

pass=0; fail=0
t() { # t <name> <expected-rc> — runs cr_merge_gate 42 o/r with current env
  local name="$1" want="$2" rc=0
  export GH_STUB_LOG="$TMP/calls-$name.log"; : > "$GH_STUB_LOG"
  cr_merge_gate 42 o/r >"$TMP/out-$name" 2>"$TMP/err-$name" || rc=$?
  if [ "$rc" = "$want" ]; then pass=$((pass+1)); echo "ok   $name"
  else fail=$((fail+1)); echo "FAIL $name (rc=$rc want=$want)"; sed 's/^/  err: /' "$TMP/err-$name"; fi
}

GH_STUB_MODE=unresolved   t unresolved-cr-thread-blocks 2
GH_STUB_MODE=clean        t resolved-threads-allow 0
GH_STUB_MODE=other-author t other-author-unresolved-allows 0
# zero unresolved on page one + hasNextPage:true = threads the single-page
# query never counted -> BLOCK, not a pass (980-r3)
GH_STUB_MODE=paged        t incomplete-page-blocks 2
# CodeRabbit's signal on the head SHA (HIMMEL-1072). It is a commit STATUS —
# the check-run these cases used to mock never existed.
GH_STUB_MODE=inflight      t cr-status-pending-blocks 2
# The regression that got #1243 merged: no CodeRabbit signal at all read as a
# pass. An unreviewed head must BLOCK, not allow.
GH_STUB_MODE=cr-absent     t cr-status-absent-blocks 2
GH_STUB_MODE=cr-failure    t cr-status-failure-blocks 2
# Identity, not display name (HIMMEL-1058): a status carrying the CodeRabbit
# context + login but a foreign creator.id must NOT satisfy the gate.
GH_STUB_MODE=cr-spoofed    t cr-status-wrong-creator-id-blocks 2
# Newest-first ordering: an older pending superseded by success is a pass.
GH_STUB_MODE=cr-superseded t cr-status-superseded-pending-allows 0
# coderabbit-2: a full page with no CodeRabbit on it is INDETERMINATE — its
# verdict may be on page two. Must block, not read as absent-but-degraded.
GH_STUB_MODE=cr-paged       t cr-status-page-limit-blocks 2
# ...but a match ON the full page is the newest by construction -> allow.
GH_STUB_MODE=cr-paged-found t cr-status-found-on-full-page-allows 0

# ORDER: the verdict must be read BEFORE the thread query (coderabbit-10).
# Threads-first loses a race — snapshot threads (clean) -> CodeRabbit posts
# findings and flips to success -> read verdict (success) -> pass over threads
# never seen. Assert the ORDER on the gh call log, not just the rc: a
# threads-first gate returns the SAME rc on every fixture here, so only the
# call sequence can catch a regression.
GH_STUB_MODE=inflight t cr-order-probe 2
statuses_ln=$(grep -n 'commits/abc123/statuses' "$TMP/calls-cr-order-probe.log" | head -1 | cut -d: -f1)
graphql_ln=$(grep -n 'api graphql' "$TMP/calls-cr-order-probe.log" | head -1 | cut -d: -f1)
if [ -n "$statuses_ln" ] && { [ -z "$graphql_ln" ] || [ "$statuses_ln" -lt "$graphql_ln" ]; }; then
  pass=$((pass+1)); echo "ok   cr-verdict-read-before-threads"
else
  fail=$((fail+1)); echo "FAIL cr-verdict-read-before-threads (statuses@${statuses_ln:-none} graphql@${graphql_ln:-none})"
fi
# pr view itself fails -> rc=3 (selector unresolvable; still an allow, but
# lets the hook retry with a better anchor - codex-1/codex-adv-1 CR round)
GH_STUB_MODE=error        t gh-error-selector-unresolvable 3
# pr view succeeds, downstream graphql fails -> plain rc=0 fail-open
GH_STUB_MODE=api-error    t downstream-api-error-fails-open 0
# codex-1: a DEGRADED verdict query must not short-circuit past the independent
# thread evidence. Verdict-first ordering (coderabbit-10) introduced exactly that
# regression — the early `return 0` on a status-query failure skipped the thread
# check and failed open over an unresolved coderabbit thread. A broken query is
# not evidence; an unresolved thread is.
GH_STUB_MODE=cr-degraded-unresolved t degraded-verdict-still-blocks-on-threads 2

# bypass env short-circuits BEFORE any gh call
GH_STUB_MODE=unresolved CR_MERGE_GATE_OK=1 t bypass-env-allows 0
[ -s "$TMP/calls-bypass-env-allows.log" ] && { echo "FAIL bypass called gh"; fail=$((fail+1)); }
unset CR_MERGE_GATE_OK

GH_STUB_MODE=unresolved CR_PROFILE=none t cr-profile-none-allows 0
[ -s "$TMP/calls-cr-profile-none-allows.log" ] && { echo "FAIL profile-none called gh"; fail=$((fail+1)); }
unset CR_PROFILE

# ── HIMMEL-1126/1147: review-BODY findings (S1) — checks/threads clean on
# every mode below (default graphql/statuses fixtures), so these exercise
# the body gate in isolation ────────────────────────────────────────────────
GH_STUB_MODE=body-outside t body-outside-diff-blocks 2
GH_STUB_MODE=body-nitpick t body-nitpick-allows-with-note 0
# rc 2 anti-drift canary: the body SHOWS "Outside diff" but the count won't
# parse — positive evidence of an unparseable finding, BLOCKS (spec §4),
# unlike the rc 1 infra case below which fails OPEN.
GH_STUB_MODE=body-drift   t body-drift-canary-blocks 2
# rc 1 infrastructure failure (the reviews query itself errors) fails OPEN,
# mirroring cr_degraded — a broken query is not evidence.
GH_STUB_MODE=body-error   t body-infra-error-fails-open 0

grep -qi "outside-diff-range finding" "$TMP/out-body-outside-diff-blocks" || { echo "FAIL body-outside block reason missing"; fail=$((fail+1)); }
# the note rides stderr, NOT stdout (codex CR round): block-unresolved-
# cr-merge.sh only captures+prints `reason=$(cr_merge_gate ...)` on a BLOCK
# (rc 2) — a stdout echo on the allow path would be captured into $reason
# and silently dropped on every allow.
grep -qi "nitpick=1" "$TMP/err-body-nitpick-allows-with-note" || { echo "FAIL body-nitpick ALLOW note missing on stderr"; fail=$((fail+1)); }
[ -s "$TMP/out-body-nitpick-allows-with-note" ] && { echo "FAIL body-nitpick note leaked onto stdout"; fail=$((fail+1)); }
grep -qi "format drift\|cannot count" "$TMP/out-body-drift-canary-blocks" || { echo "FAIL body-drift block reason missing"; fail=$((fail+1)); }
grep -qi "degraded" "$TMP/err-body-infra-error-fails-open" || { echo "FAIL body-infra degradation note missing"; fail=$((fail+1)); }

# block reason lands on stdout
grep -qi "unresolved" "$TMP/out-unresolved-cr-thread-blocks" || { echo "FAIL block reason missing"; fail=$((fail+1)); }
# degradation notes land on stderr on both fail-open shapes
grep -qi "degraded" "$TMP/err-gh-error-selector-unresolvable" || { echo "FAIL degradation note missing (rc3)"; fail=$((fail+1)); }
grep -qi "degraded" "$TMP/err-downstream-api-error-fails-open" || { echo "FAIL degradation note missing (rc0)"; fail=$((fail+1)); }

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
