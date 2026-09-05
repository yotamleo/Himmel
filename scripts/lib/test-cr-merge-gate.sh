#!/usr/bin/env bash
# Tests for scripts/lib/cr-merge-gate.sh (HIMMEL-936). Hermetic: gh is stubbed.
set -uo pipefail

# HIMMEL-1495 — an --automerge-armed launching shell carries ARMAUTOMERGE=1 +
# CR_MERGE_GATE_OK=1 by design; an ambient value in the operator's shell must
# not decide the result (the 34e/34f precedent in test-check-ci.sh,
# generalized). cr_merge_gate short-circuits to allow on CR_MERGE_GATE_OK=1
# (cr-merge-gate.sh:166) before any gh call, so without this scrub every
# block-case below inherits the bypass and reads rc 0.
unset ARMAUTOMERGE CR_MERGE_GATE_OK

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
# CodeRabbit's review-FRESHNESS query (HIMMEL-1181) — a SEPARATE GraphQL query
# from the reviewThreads one below (both are `gh api graphql`), so this is
# intercepted on QUERY TEXT, before the "$1 $2" dispatch (which would
# otherwise route every graphql call through the reviewThreads fixtures keyed
# on GH_STUB_MODE). Driven by GH_STUB_FRESHNESS, default 'fresh' (anchored to
# abc123, this suite's head) so every UNRELATED case below is unaffected —
# same "default keeps old assertions" convention cr-body-findings.sh's tests
# use for the reviews REST endpoint.
#
# Every BOT node carries a non-empty `body` and a non-zero `comments.totalCount`
# on purpose: HIMMEL-1824 taught the reader to DROP empty review shells
# (`chat.auto_reply` and incremental passes mint COMMENTED objects with neither),
# so a bodyless fixture classifies as `none` no matter which oid it names. That
# is what silently disarmed the `fresh`/`stale` fixtures here — the stale-anchor
# BLOCK stopped firing and the suite went red (HIMMEL-1374, found 2026-08-20).
case "$*" in
  *"reviews(last:"*)
    case "${GH_STUB_FRESHNESS:-fresh}" in
      fresh)   echo '{"data":{"repository":{"pullRequest":{"reviews":{"totalCount":1,"nodes":[{"author":{"login":"coderabbitai","__typename":"Bot"},"commit":{"oid":"abc123"},"state":"COMMENTED","body":"looks fine","comments":{"totalCount":1}}]}}}}}' ;;
      stale)   echo '{"data":{"repository":{"pullRequest":{"reviews":{"totalCount":1,"nodes":[{"author":{"login":"coderabbitai","__typename":"Bot"},"commit":{"oid":"shaOLD"},"state":"COMMENTED","body":"found something earlier","comments":{"totalCount":2}}]}}}}}' ;;
      none)    echo '{"data":{"repository":{"pullRequest":{"reviews":{"totalCount":1,"nodes":[{"author":{"login":"human","__typename":"User"},"commit":{"oid":"abc123"},"state":"COMMENTED","body":"a human review","comments":{"totalCount":1}}]}}}}}' ;;
      paged)   echo '{"data":{"repository":{"pullRequest":{"reviews":{"totalCount":150,"nodes":[]}}}}}' ;;
      fail)    echo "reviews boom" >&2; exit 1 ;;
    esac
    exit 0 ;;
esac
case "$1 $2" in
  "pr view")
    # A malformed --repo value (quotes survived tokenization) is what real gh
    # REJECTS — reproduce that so the malformed-repo case exercises the actual
    # rc=3 re-anchor path instead of an incidental success (coderabbit-10).
    case "$*" in *'"'*) exit 1 ;; esac
    # api-error mode: pr view SUCCEEDS, later api calls fail (distinguishes
    # rc=3 selector-unresolvable from rc=0 downstream-API fail-open).
    # GH_STUB_HEAD lets a case pick a REAL 40-hex head (HIMMEL-1374): the
    # walkthrough reader only accepts a >=7-hex commit token, which this
    # suite's default 6-char "abc123" can never satisfy. Every other case
    # keeps the default, and the statuses arm below matches on the "abc123"
    # PREFIX so both spellings reach the same fixtures.
    printf '{"number":42,"headRefOid":"%s","url":"https://github.com/o/r/pull/42"}\n' "${GH_STUB_HEAD:-abc123}" ;;
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
  "api repos/o/r/commits/abc123"*)
    case "$GH_STUB_MODE" in
      api-error) exit 1 ;;
      # HIMMEL-1374: the status read DEGRADES while threads/body stay clean —
      # the fail-open half of the zero-PR-wide-reviews composition. Distinct
      # from cr-degraded-unresolved, which also carries blocking thread
      # evidence and would mask the fail-open with a legitimate block.
      cr-degraded-clean) echo "statuses boom" >&2; exit 1 ;;
      # The verdict query flakes (a real 503 was observed live on this endpoint)
      # WHILE a coderabbit thread sits unresolved. The degraded verdict must not
      # short-circuit past that evidence (codex-1).
      cr-degraded-unresolved) echo "statuses boom" >&2; exit 1 ;;
      inflight) echo '[{"context":"CodeRabbit","state":"pending","created_at":"2026-07-16T19:08:46Z","creator":{"id":136622811,"login":"coderabbitai[bot]","type":"Bot"}}]' ;;
      cr-absent) echo '[]' ;;
      # HIMMEL-1317: what a repo with automatic reviews DISABLED posts on every
      # untriggered PR — state=success, refusal only in .description. Reading
      # .state alone made a declined review identical to a clean one, and this
      # gate's case statement had no catch-all, so the unhandled state fell
      # straight through to the merge path: fail-open by omission.
      cr-skipped) echo '[{"context":"CodeRabbit","state":"success","description":"Review skipped: automatic reviews are disabled","created_at":"2026-07-16T19:10:05Z","creator":{"id":136622811,"login":"coderabbitai[bot]","type":"Bot"}}]' ;;
      # Positive control: same state, a real review — must still ALLOW, so the
      # block above cannot be satisfied by breaking `success` wholesale.
      cr-completed) echo '[{"context":"CodeRabbit","state":"success","description":"Review completed","created_at":"2026-07-16T19:10:05Z","creator":{"id":136622811,"login":"coderabbitai[bot]","type":"Bot"}}]' ;;
      # glm-1 (round 2): the false-positive guard must exist in BOTH gate suites.
      # check-ci and cr-merge-gate consume the same reader, so a loosened skip
      # regex would be caught by only one of them — and the merge gate is the one
      # that actually stops a merge. A completed review whose wording merely
      # CONTAINS skip-ish words must not block.
      cr-nearmiss) echo '[{"context":"CodeRabbit","state":"success","description":"No review changes requested","created_at":"2026-07-16T19:10:05Z","creator":{"id":136622811,"login":"coderabbitai[bot]","type":"Bot"}}]' ;;
      cr-failure) echo '[{"context":"CodeRabbit","state":"failure","created_at":"2026-07-16T19:10:05Z","creator":{"id":136622811,"login":"coderabbitai[bot]","type":"Bot"}}]' ;;
      # HIMMEL-1465: the rate-limit decline — same skipped-state projection as
      # cr-skipped. It was the ONE wording a clean critic panel could carry
      # until HIMMEL-1760 gave this gate check-ci.sh's every-skip-wording parity.
      cr-ratelimited) echo '[{"context":"CodeRabbit","state":"success","description":"Review rate limited","created_at":"2026-07-16T19:10:05Z","creator":{"id":136622811,"login":"coderabbitai[bot]","type":"Bot"}}]' ;;
      # HIMMEL-1760: a THIRD skip wording, matching neither the rate-limit nor
      # the automatic-reviews-disabled label arm ("review disabled" is its own
      # _CRS_SKIP_RE alternative). Pins the contract as "every skip-classified
      # description is panel-carriable" rather than "these two are" — the exact
      # over-narrowing this ticket exists to undo. A future CodeRabbit skip
      # phrasing lands here, and must behave like the enumerated ones.
      cr-skipped-other) echo '[{"context":"CodeRabbit","state":"success","description":"Review disabled for this repository","created_at":"2026-07-16T19:10:05Z","creator":{"id":136622811,"login":"coderabbitai[bot]","type":"Bot"}}]' ;;
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
  # CodeRabbit's WALKTHROUGH issue comment (HIMMEL-1824) — its second delivery
  # channel, the one a CLEAN pass uses when it mints no review object at all.
  # Default 'none' (an empty comment list) leaves every unrelated case exactly
  # as it was; only the HIMMEL-1374 zero-PR-wide-reviews arm reads it.
  "api repos/o/r/issues/42/comments"*)
    case "${GH_STUB_WALKTHROUGH:-none}" in
      clean) echo '[{"user":{"login":"coderabbitai[bot]","type":"Bot"},"body":"<!-- This is an auto-generated comment: summarize by coderabbit.ai -->\nNo actionable comments were generated in the recent review.\n\nMerge Risk: Low - up to `abc123d`"}]' ;;
      *)     echo '[]' ;;
    esac ;;
  *) echo '{}' ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# shellcheck disable=SC1091
. "$SCRIPT_DIR/cr-merge-gate.sh"

pass=0; fail=0
# ── the repo the gate runs IN (HIMMEL-1125) ──────────────────────────────────
# Availability is now a repo-scoped, non-versioned git config, and the gate only
# answers for the repo it is standing in (codex-adv-2). Every case below calls
# `cr_merge_gate 42 o/r`, so the cwd must BE o/r and must be armed — otherwise
# the gate short-circuits to "allow" and every block-case would pass vacuously.
# Pinned explicitly rather than inherited from the real checkout: the suite must
# not change meaning with the ambient repo's config.
mkdir -p "$TMP/repo"
git -C "$TMP/repo" init --quiet >/dev/null 2>&1
git -C "$TMP/repo" remote add origin https://github.com/o/r.git
git -C "$TMP/repo" config --local himmel.coderabbit true
cd "$TMP/repo" || { echo "FATAL: cannot cd to the test repo"; exit 1; }

# HIMMEL-1495 hermeticity probe — when this suite re-execs itself under the
# armed bypass env (see the guard at the end), short-circuit here: the startup
# unset has already scrubbed ARMAUTOMERGE/CR_MERGE_GATE_OK, so a block fixture
# must STILL block. Exit 0 = scrub held (rc EXACTLY 2, the block code); any
# other rc — 0 = the bypass leaked and cr_merge_gate failed open, else = a
# broken fixture/gate — exits 1 so an errored probe can never falsely validate
# the guard. Keeps the reinvoked copy to ONE gate call.
if [ "${HIMMEL_1495_SELF:-0}" = "1" ]; then
    export GH_STUB_LOG="$TMP/armed-probe.log"; : > "$GH_STUB_LOG"
    export GH_STUB_MODE=unresolved
    probe_rc=0
    cr_merge_gate 42 o/r >/dev/null 2>&1 || probe_rc=$?
    [ "$probe_rc" = "2" ] || exit 1
    exit 0
fi

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
# HIMMEL-1317: a DECLINED review must block for the same reason an absent one
# does. Paired with its positive control so the block cannot be satisfied by
# breaking `success` outright. Runs before any ledger fixture is written, so it
# is also the no-panel-evidence negative control for the HIMMEL-1760 carry below.
GH_STUB_MODE=cr-skipped    t cr-status-skipped-blocks 2
GH_STUB_MODE=cr-completed  t cr-status-completed-allows 0
# glm-1 (round 2): mirror check-ci's 34d near-miss guard here. Both gates read
# the same cr-signal.sh, so a loosened skip regex must fail in BOTH suites —
# and this is the gate that actually stops a merge.
GH_STUB_MODE=cr-nearmiss   t cr-status-skipish-wording-allows 0
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
# HIMMEL-1465: a rate-limited decline with NO panel evidence in this repo's CR
# ledger keeps the block — evidence-gated, never a free pass.
GH_STUB_MODE=cr-ratelimited t cr-status-ratelimited-no-panel-blocks 2
# ...and the SAME decline with a clean panel avail-ok recorded at the head is
# panel-carried: it falls through to the thread + body gates (clean here) and
# allows. Head "abc123" is 6 chars — below atHead's 7-char isHex floor — so it
# matches ONLY by atHead's equality-first check, never by prefix resolution.
printf '%s\n' '{"kind":"avail","ts":"2026-08-03T00:00:00Z","branch":"feat/x","head":"abc123","model":"codex","status":"ok","artifact":"diff","perspective":"off","responding_model":"gpt-5.5"}' > "$TMP/repo/.git/cr-critic-scores.jsonl"
GH_STUB_MODE=cr-ratelimited t cr-status-ratelimited-panel-carried-allows 0
# HIMMEL-1760: the SAME evidence bar for the OTHER skip wording. check-ci.sh
# carries every skip-classified description on a clean exact-head panel
# (HIMMEL-1506); this gate carried only the rate-limit shape, so the
# adaptive-limit lockout presentation ("automatic reviews are disabled")
# hard-blocked merges check-ci had already certified. Parity, not relaxation —
# the two gates must accept and refuse the same shapes.
GH_STUB_MODE=cr-skipped t cr-status-autoreviews-disabled-panel-carried-allows 0
# ...and a wording in NEITHER label arm behaves identically — the verdict comes
# from the exact-head panel, never from the description (codex-1, panel r2).
GH_STUB_MODE=cr-skipped-other t cr-status-other-skip-wording-panel-carried-allows 0
# scrub the scratch ledger so no later case inherits the carry evidence
rm -f "$TMP/repo/.git/cr-critic-scores.jsonl"
GH_STUB_MODE=cr-skipped-other t cr-status-other-skip-wording-no-panel-blocks 2
# ...and the evidence must be at the EXACT head: a clean panel recorded on a
# DIFFERENT commit is not evidence about this one, so the block stands. (Both
# heads are 6 chars — below atHead's 7-char isHex floor — so "def456" cannot
# match "abc123" by prefix resolution either.)
printf '%s\n' '{"kind":"avail","ts":"2026-08-03T00:00:00Z","branch":"feat/x","head":"def456","model":"codex","status":"ok","artifact":"diff","perspective":"off","responding_model":"gpt-5.5"}' > "$TMP/repo/.git/cr-critic-scores.jsonl"
GH_STUB_MODE=cr-skipped     t cr-status-autoreviews-disabled-panel-other-head-blocks 2
GH_STUB_MODE=cr-ratelimited t cr-status-ratelimited-panel-other-head-blocks 2
rm -f "$TMP/repo/.git/cr-critic-scores.jsonl"

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

# HIMMEL-1125 — the adopter WITHOUT CodeRabbit, at the surface that actually
# blocks `gh pr merge`. This whole gate is CodeRabbit-specific, so with no
# CodeRabbit it must be a NO-OP: allow, and (like the other two short-circuits
# above) do not spend a single gh call proving what the probe already knows.
# Pre-1125 this shape BLOCKED every merge on "absent", forever, until the
# adopter discovered CR_PROFILE=none.
GH_STUB_MODE=unresolved CR_APP=0 t cr-app-absent-allows 0
[ -s "$TMP/calls-cr-app-absent-allows.log" ] && { echo "FAIL cr-app-absent called gh"; fail=$((fail+1)); }
unset CR_APP

# HIMMEL-1125 — the marker is what arms this suite, so prove the gate is really
# keyed on it: same blocking fixture, marker off -> allow. Default-disarmed is
# the posture, and an unarmed repo is now the DEFAULT an adopter lands on.
git -C "$TMP/repo" config --local --unset himmel.coderabbit
GH_STUB_MODE=unresolved t unarmed-repo-allows 0
[ -s "$TMP/calls-unarmed-repo-allows.log" ] && { echo "FAIL unarmed repo called gh"; fail=$((fail+1)); }
git -C "$TMP/repo" config --local himmel.coderabbit true

# codex-adv-2 — availability describes THIS clone, so it must not be applied to a
# foreign --repo target. Local is armed (o/r); the merge targets other/thing,
# which we hold no signal for -> no gate, and no gh call spent guessing. Before
# this, the local answer leaked onto any --repo target: it would falsely BLOCK a
# target without CodeRabbit and falsely PASS one that uses it.
GH_STUB_LOG="$TMP/calls-foreign.log"; : > "$GH_STUB_LOG"
export GH_STUB_LOG
foreign_rc=0
GH_STUB_MODE=unresolved cr_merge_gate 42 other/thing >/dev/null 2>&1 || foreign_rc=$?
if [ "$foreign_rc" = 0 ]; then pass=$((pass+1)); echo "ok   foreign-repo-target-not-gated"
else fail=$((fail+1)); echo "FAIL foreign-repo-target-not-gated (rc=$foreign_rc want=0)"; fi
[ -s "$TMP/calls-foreign.log" ] && { echo "FAIL foreign target called gh"; fail=$((fail+1)); }

# ...but ONLY a well-formed owner/name is a foreign target. A MIS-TOKENIZED repo
# value (here: the quotes survived extraction, HIMMEL-936 codex-1) must NOT be
# read as "some other repo" and waved through — treating garbage as foreign would
# let `--repo "o/r"` silently disable this gate, a worse bypass than the one the
# foreign check closes. Real gh rejects such a value, so the faithful outcome is
# the rc=3 re-anchor path (coderabbit-10): the gate did NOT wave it through, and
# the hook re-anchors on the cwd branch. The property under test is "not 0".
GH_STUB_LOG="$TMP/calls-malformed.log"; : > "$GH_STUB_LOG"
export GH_STUB_LOG
malformed_rc=0
GH_STUB_MODE=unresolved cr_merge_gate 42 '"o/r"' >/dev/null 2>&1 || malformed_rc=$?
if [ "$malformed_rc" = 3 ]; then pass=$((pass+1)); echo "ok   malformed-repo-value-reanchors-not-waved-through"
else fail=$((fail+1)); echo "FAIL malformed-repo-value-reanchors-not-waved-through (rc=$malformed_rc want=3)"; fi

# coderabbit-9 — a mere SPELLING of the local repo must not read as foreign and
# skip the gate. Both are `o/r`, gh's own accepted forms:
#   O/R            GitHub owner/name is case-INSENSITIVE
#   github.com/o/r gh accepts [HOST/]OWNER/REPO
# Each must still BLOCK on the unresolved thread (rc 2), not be waved through.
for spelling in 'O/R' 'github.com/o/r' 'GitHub.com/O/r'; do
    GH_STUB_LOG="$TMP/calls-spell.log"; : > "$GH_STUB_LOG"
    export GH_STUB_LOG
    spell_rc=0
    GH_STUB_MODE=unresolved cr_merge_gate 42 "$spelling" >/dev/null 2>&1 || spell_rc=$?
    if [ "$spell_rc" = 2 ]; then pass=$((pass+1)); echo "ok   local-repo-spelling-still-gated ($spelling)"
    else fail=$((fail+1)); echo "FAIL local-repo-spelling-still-gated ($spelling) (rc=$spell_rc want=2)"; fi
done

# coderabbit-11 — the flip side of coderabbit-9: same owner/name on a DIFFERENT
# host is a DIFFERENT repo. Origin is github.com/o/r (armed); a merge targeting
# ghe.example.com/o/r must be treated FOREIGN (no signal, no gate), not gated
# with the local github answer. Dropping the host made these collide.
GH_STUB_LOG="$TMP/calls-crosshost.log"; : > "$GH_STUB_LOG"
export GH_STUB_LOG
crosshost_rc=0
GH_STUB_MODE=unresolved cr_merge_gate 42 ghe.example.com/o/r >/dev/null 2>&1 || crosshost_rc=$?
if [ "$crosshost_rc" = 0 ]; then pass=$((pass+1)); echo "ok   cross-host-same-nwo-not-gated"
else fail=$((fail+1)); echo "FAIL cross-host-same-nwo-not-gated (rc=$crosshost_rc want=0)"; fi
[ -s "$TMP/calls-crosshost.log" ] && { echo "FAIL cross-host target called gh"; fail=$((fail+1)); }

# coderabbit-15 — an ssh://git@HOST/o/r origin must still identify the LOCAL
# repo, so a merge targeting its OWN o/r is gated, not waved through as foreign.
# The `git@` userinfo used to survive into the canonical form, whose `@` failed
# the charset check -> local unidentifiable -> every --repo bypassed the gate.
# Fresh armed repo with an ssh origin (the shared o/r stub repo uses https).
mkdir -p "$TMP/sshrepo"
git -C "$TMP/sshrepo" init --quiet >/dev/null 2>&1
git -C "$TMP/sshrepo" remote add origin ssh://git@github.com/o/r.git
git -C "$TMP/sshrepo" config --local himmel.coderabbit true
GH_STUB_LOG="$TMP/calls-ssh.log"; : > "$GH_STUB_LOG"
export GH_STUB_LOG
ssh_rc=0
( cd "$TMP/sshrepo" && GH_STUB_MODE=unresolved cr_merge_gate 42 o/r ) >/dev/null 2>&1 || ssh_rc=$?
if [ "$ssh_rc" = 2 ]; then pass=$((pass+1)); echo "ok   ssh-origin-identifies-local-repo (gated, not bypassed)"
else fail=$((fail+1)); echo "FAIL ssh-origin-identifies-local-repo (rc=$ssh_rc want=2)"; fi

# CodeRabbit port-normalization finding, PR #1470 — a scheme-style origin with
# an explicit PORT must still identify the LOCAL repo. `ssh://git@ghe.example.
# com:2222/o/r` left ":2222" glued onto the host segment; _cmg_canon_nwo's
# charset check rejects ':', so the local clone became unidentifiable and a
# matching `--repo ghe.example.com/o/r` was waved through as foreign. `--repo`
# itself never carries a port, so the two must still compare equal once the
# origin's port is stripped.
mkdir -p "$TMP/sshportrepo"
git -C "$TMP/sshportrepo" init --quiet >/dev/null 2>&1
git -C "$TMP/sshportrepo" remote add origin ssh://git@ghe.example.com:2222/o/r.git
git -C "$TMP/sshportrepo" config --local himmel.coderabbit true
GH_STUB_LOG="$TMP/calls-sshport.log"; : > "$GH_STUB_LOG"
export GH_STUB_LOG
sshport_rc=0
( cd "$TMP/sshportrepo" && GH_STUB_MODE=unresolved cr_merge_gate 42 ghe.example.com/o/r ) >/dev/null 2>&1 || sshport_rc=$?
if [ "$sshport_rc" = 2 ]; then pass=$((pass+1)); echo "ok   ssh-origin-with-port-identifies-local-repo (gated, not bypassed)"
else fail=$((fail+1)); echo "FAIL ssh-origin-with-port-identifies-local-repo (rc=$sshport_rc want=2)"; fi

# Same finding, https origin on a custom port (no userinfo, so this exercises
# the plain scheme-style path rather than the `@`-stripping added by
# coderabbit-15).
mkdir -p "$TMP/httpsportrepo"
git -C "$TMP/httpsportrepo" init --quiet >/dev/null 2>&1
git -C "$TMP/httpsportrepo" remote add origin https://ghe.example.com:8443/o/r.git
git -C "$TMP/httpsportrepo" config --local himmel.coderabbit true
GH_STUB_LOG="$TMP/calls-httpsport.log"; : > "$GH_STUB_LOG"
export GH_STUB_LOG
httpsport_rc=0
( cd "$TMP/httpsportrepo" && GH_STUB_MODE=unresolved cr_merge_gate 42 ghe.example.com/o/r ) >/dev/null 2>&1 || httpsport_rc=$?
if [ "$httpsport_rc" = 2 ]; then pass=$((pass+1)); echo "ok   https-origin-with-port-identifies-local-repo (gated, not bypassed)"
else fail=$((fail+1)); echo "FAIL https-origin-with-port-identifies-local-repo (rc=$httpsport_rc want=2)"; fi

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

# ── HIMMEL-1181: review-FRESHNESS (B2) — checks/threads/body all clean
# (GH_STUB_MODE=clean), so these exercise the freshness gate in isolation ───
GH_STUB_MODE=clean GH_STUB_FRESHNESS=stale t freshness-stale-blocks 2
# HIMMEL-2162: a clean exact-head critic panel carries a stale-anchor freshness
# review too — parity with check-ci.sh's twin arm (HIMMEL-1718/2162), and the
# DEFAULT behavior now (no knob needed). Same ledger fixture shape as the
# ratelimited-panel-carried case below.
printf '%s\n' '{"kind":"avail","ts":"2026-08-03T00:00:00Z","branch":"feat/x","head":"abc123","model":"codex","status":"ok","artifact":"diff","perspective":"off","responding_model":"gpt-5.5"}' > "$TMP/repo/.git/cr-critic-scores.jsonl"
GH_STUB_MODE=clean GH_STUB_FRESHNESS=stale t freshness-stale-panel-carried-allows 0
grep -qi "carries the gate" "$TMP/err-freshness-stale-panel-carried-allows" || { echo "FAIL freshness-stale panel-carry ALLOW-note missing"; fail=$((fail+1)); }
rm -f "$TMP/repo/.git/cr-critic-scores.jsonl"
# ...and evidence recorded at a DIFFERENT commit is not evidence about THIS
# head — the block stands (fail-closed preserved).
printf '%s\n' '{"kind":"avail","ts":"2026-08-03T00:00:00Z","branch":"feat/x","head":"def456","model":"codex","status":"ok","artifact":"diff","perspective":"off","responding_model":"gpt-5.5"}' > "$TMP/repo/.git/cr-critic-scores.jsonl"
GH_STUB_MODE=clean GH_STUB_FRESHNESS=stale t freshness-stale-panel-other-head-blocks 2
rm -f "$TMP/repo/.git/cr-critic-scores.jsonl"
GH_STUB_MODE=clean GH_STUB_FRESHNESS=paged t freshness-paged-blocks 2
# none = zero bot reviews on the PR at all, at any head, ever.
#
# HIMMEL-1374 — this used to be an unconditional self-skip ("absence of a bot
# review is not evidence of staleness"), which is what let PR #1463 read clean
# while the App's status said "Review completed" over a PR nobody had reviewed.
# With a genuine `success` status (GH_STUB_MODE=clean posts one) and no
# walkthrough, the two signals contradict each other: BLOCK.
GH_STUB_MODE=clean GH_STUB_FRESHNESS=none  t freshness-none-with-completed-status-blocks 2
grep -qi "no CodeRabbit review object at any head" "$TMP/out-freshness-none-with-completed-status-blocks" || { echo "FAIL freshness-none block reason missing the zero-reviews-ever shape"; fail=$((fail+1)); }
# ...but the three shapes that legitimately reach `none` still allow:
#  1. HIMMEL-1824 — a CLEAN pass mints no review object and reports through the
#     walkthrough instead, so zero-reviews-PR-wide is the NORMAL shape there.
#     Needs a real >=7-hex head: the walkthrough reader will not accept a
#     commit token shorter than git's own abbreviation floor.
GH_STUB_MODE=clean GH_STUB_FRESHNESS=none GH_STUB_WALKTHROUGH=clean \
  GH_STUB_HEAD=abc123def4567890abc123def4567890abc123de t freshness-none-clean-walkthrough-allows 0
#  2. HIMMEL-1465 — a RATE-LIMITED App never claims a completed review, so the
#     clean exact-head critic panel still carries it (the live 2026-08-20 shape
#     on PRs #1759/#1760). Ledger head matches this suite's default head.
printf '%s\n' '{"kind":"avail","ts":"2026-08-03T00:00:00Z","branch":"feat/x","head":"abc123","model":"codex","status":"ok","artifact":"diff","perspective":"off","responding_model":"gpt-5.5"}' > "$TMP/repo/.git/cr-critic-scores.jsonl"
GH_STUB_MODE=cr-ratelimited GH_STUB_FRESHNESS=none t freshness-none-ratelimited-panel-carried-allows 0
rm -f "$TMP/repo/.git/cr-critic-scores.jsonl"
#  3. a DEGRADED status read is not evidence of anything — this gate's stated
#     fail-open contract for infrastructure failures survives the new arm.
GH_STUB_MODE=cr-degraded-clean GH_STUB_FRESHNESS=none t freshness-none-degraded-status-fails-open 0
# rc 1 infrastructure failure (the reviews query itself errors) fails OPEN,
# mirroring cr_degraded/body_degraded — a broken query is not evidence.
GH_STUB_MODE=clean GH_STUB_FRESHNESS=fail  t freshness-infra-error-fails-open 0

grep -qi "anchored to shaOLD" "$TMP/out-freshness-stale-blocks" || { echo "FAIL freshness-stale block reason missing anchor"; fail=$((fail+1)); }
grep -qi "never re-reviewed" "$TMP/out-freshness-stale-blocks" || { echo "FAIL freshness-stale block reason missing remediation"; fail=$((fail+1)); }
grep -qi "one query window" "$TMP/out-freshness-paged-blocks" || { echo "FAIL freshness-paged block reason missing"; fail=$((fail+1)); }
grep -qi "degraded" "$TMP/err-freshness-infra-error-fails-open" || { echo "FAIL freshness-infra degradation note missing"; fail=$((fail+1)); }

# Regression guard for the ordering fix this gate required: an INDEPENDENT
# freshness-reader failure must NOT suppress the body-findings reader's own
# valid nitpick ALLOW note (they are two separate readers — see
# cr-review-freshness.sh header). Before the fix, folding fr_degraded into
# the SAME early-return as cr_degraded/body_degraded made this note vanish
# whenever the (unrelated) freshness query failed.
GH_STUB_MODE=body-nitpick GH_STUB_FRESHNESS=fail t freshness-degrade-does-not-suppress-nitpick-note 0
grep -qi "nitpick=1" "$TMP/err-freshness-degrade-does-not-suppress-nitpick-note" || { echo "FAIL nitpick note suppressed by an unrelated freshness degrade"; fail=$((fail+1)); }

# order: verdict -> freshness -> threads (1.5 sits between the two, per spec)
# — a stale freshness call still resolves the CodeRabbit status first
# (coderabbit-10's ordering rationale extends to this new step).
GH_STUB_MODE=clean GH_STUB_FRESHNESS=stale t freshness-order-probe 2
fr_statuses_ln=$(grep -n 'commits/abc123/statuses' "$TMP/calls-freshness-order-probe.log" | head -1 | cut -d: -f1)
fr_reviews_ln=$(grep -n 'reviews(last:' "$TMP/calls-freshness-order-probe.log" | head -1 | cut -d: -f1)
if [ -n "$fr_statuses_ln" ] && [ -n "$fr_reviews_ln" ] && [ "$fr_statuses_ln" -lt "$fr_reviews_ln" ]; then
  pass=$((pass+1)); echo "ok   freshness-read-after-verdict"
else
  fail=$((fail+1)); echo "FAIL freshness-read-after-verdict (statuses@${fr_statuses_ln:-none} reviews@${fr_reviews_ln:-none})"
fi

# bypass short-circuits BEFORE any gh call, so a stale freshness never runs
GH_STUB_MODE=clean GH_STUB_FRESHNESS=stale CR_MERGE_GATE_OK=1 t freshness-bypass-env-allows 0
[ -s "$TMP/calls-freshness-bypass-env-allows.log" ] && { echo "FAIL freshness bypass called gh"; fail=$((fail+1)); }
unset CR_MERGE_GATE_OK

# block reason lands on stdout
grep -qi "unresolved" "$TMP/out-unresolved-cr-thread-blocks" || { echo "FAIL block reason missing"; fail=$((fail+1)); }
# degradation notes land on stderr on both fail-open shapes
grep -qi "degraded" "$TMP/err-gh-error-selector-unresolvable" || { echo "FAIL degradation note missing (rc3)"; fail=$((fail+1)); }
grep -qi "degraded" "$TMP/err-downstream-api-error-fails-open" || { echo "FAIL degradation note missing (rc0)"; fail=$((fail+1)); }

# HIMMEL-1495 hermeticity guard — prove the startup scrub holds. Re-run this
# whole suite in a subprocess EXPORTING the exact armed bypass env an
# --automerge-armed shell carries; the reinvoked copy's own startup unset must
# neutralize it, so its block-cases still block and it exits 0. Remove the
# startup `unset ARMAUTOMERGE CR_MERGE_GATE_OK` and this reinvocation instead
# fails its block-cases (rc 0) and exits non-zero. Recursion-safe: the sentinel
# suppresses the guard in the reinvoked copy.
if [ "${HIMMEL_1495_SELF:-0}" != "1" ]; then
    if CR_MERGE_GATE_OK=1 ARMAUTOMERGE=1 HIMMEL_1495_SELF=1 bash "$SCRIPT_DIR/test-cr-merge-gate.sh" >"$TMP/armed.log" 2>&1; then
        pass=$((pass+1)); echo "ok   hermetic-to-armed-env (self-reinvoke exits 0)"
    else
        fail=$((fail+1)); echo "FAIL hermetic-to-armed-env (startup scrub missing?)"; sed 's/^/  armed: /' "$TMP/armed.log"
    fi
fi

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
