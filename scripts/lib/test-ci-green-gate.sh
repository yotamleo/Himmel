#!/usr/bin/env bash
# Tests for scripts/lib/ci-green-gate.sh (HIMMEL-1043). Hermetic: gh is stubbed.
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
  error) exit 1 ;;   # gh pr view itself fails -> rc=3 selector-unresolvable
esac
case "$1 $2" in
  "pr view")
    echo '{"number":42,"headRefOid":"abc123","url":"https://github.com/o/r/pull/42"}' ;;
  "api repos/o/r/commits/abc123/check-runs"*)
    case "$GH_STUB_MODE" in
      api-error)    exit 1 ;;                                  # downstream API fail -> rc=0 fail-open
      red-run)     echo '{"check_runs":[{"name":"CI Build","status":"completed","conclusion":"failure"}]}' ;;
      pending-run) echo '{"check_runs":[{"name":"CI Lint","status":"in_progress","conclusion":null}]}' ;;
      many-runs)   echo '{"check_runs":[{"name":"CI","status":"completed","conclusion":"success"}],"total_count":150}' ;;
      checkless)   echo '{"check_runs":[]}' ;;
      *)           echo '{"check_runs":[{"name":"CI","status":"completed","conclusion":"success"}]}' ;;
    esac ;;
  # The LIST endpoint, not the combined one (HIMMEL-1072): the combined /status
  # folds every context into one aggregate .state, which silently dragged
  # CodeRabbit's own pending review into this gate's verdict — false-blocking on
  # the very signal this gate documents that it excludes. The list carries
  # creator identity, so CodeRabbit can actually be excluded. Newest-first.
  "api repos/o/r/commits/abc123/statuses"*)
    case "$GH_STUB_MODE" in
      red-status)   echo '[{"context":"ci/legacy","state":"failure","created_at":"2026-07-16T19:10:05Z","creator":{"id":1,"login":"ci","type":"Bot"}}]' ;;
      pend-status)  echo '[{"context":"ci/a","state":"pending","created_at":"2026-07-16T19:10:05Z","creator":{"id":1,"login":"ci","type":"Bot"}},{"context":"ci/b","state":"pending","created_at":"2026-07-16T19:10:05Z","creator":{"id":1,"login":"ci","type":"Bot"}}]' ;;
      error-status) echo '[{"context":"ci/legacy","state":"error","created_at":"2026-07-16T19:10:05Z","creator":{"id":1,"login":"ci","type":"Bot"}}]' ;;
      checkless)    echo '[]' ;;
      # A full page of statuses: a failing/pending one may sit on an unread
      # page 2, so a single page cannot certify green (coderabbit-1).
      many-statuses) jq -nc '[range(100) | {context: "ci/ctx\(.)", state: "success", created_at: "2026-07-16T19:10:05Z", creator: {id: 1, login: "ci", type: "Bot"}}]' ;;
      # CodeRabbit pending + real CI green: the CR gate owns CodeRabbit, so this
      # gate must NOT block. Pre-1072 the combined aggregate made it block here.
      cr-pending-only) echo '[{"context":"CodeRabbit","state":"pending","created_at":"2026-07-16T19:10:05Z","creator":{"id":136622811,"login":"coderabbitai[bot]","type":"Bot"}},{"context":"ci/legacy","state":"success","created_at":"2026-07-16T19:10:05Z","creator":{"id":1,"login":"ci","type":"Bot"}}]' ;;
      # The exclusion is by creator IDENTITY, not by context string (coderabbit-14):
      # a pending status wearing the "CodeRabbit" context but posted by a FOREIGN
      # creator is NOT CodeRabbit's, so it is ordinary CI and must BLOCK. Without
      # this case a context-string exclusion would pass the suite — and would let
      # anyone silence the CI gate by naming their status "CodeRabbit".
      cr-foreign-context) echo '[{"context":"CodeRabbit","state":"pending","created_at":"2026-07-16T19:10:05Z","creator":{"id":999999,"login":"impostor","type":"Bot"}},{"context":"ci/legacy","state":"success","created_at":"2026-07-16T19:10:05Z","creator":{"id":1,"login":"ci","type":"Bot"}}]' ;;
      # A stale pending superseded by a newer success on the SAME context is
      # green. Two contexts INTERLEAVED newest-first (codex-1): a single-context
      # fixture cannot catch a per-context reduction that picks the wrong
      # element, since any ordering yields the same answer. `z/` sorts AFTER
      # `ci/` so a key-sorted reduction reorders them — if the reduction ever
      # returns a group's older entry, `z/late`'s stale pending blocks and this
      # case flips to 2.
      superseded)   echo '[{"context":"z/late","state":"success","created_at":"2026-07-16T19:10:06Z","creator":{"id":1,"login":"ci","type":"Bot"}},{"context":"ci/legacy","state":"success","created_at":"2026-07-16T19:10:05Z","creator":{"id":1,"login":"ci","type":"Bot"}},{"context":"z/late","state":"pending","created_at":"2026-07-16T19:08:01Z","creator":{"id":1,"login":"ci","type":"Bot"}},{"context":"ci/legacy","state":"pending","created_at":"2026-07-16T19:08:00Z","creator":{"id":1,"login":"ci","type":"Bot"}}]' ;;
      *)            echo '[{"context":"ci/legacy","state":"success","created_at":"2026-07-16T19:10:05Z","creator":{"id":1,"login":"ci","type":"Bot"}}]' ;;
    esac ;;
  *) echo '{}' ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# shellcheck disable=SC1091
. "$SCRIPT_DIR/ci-green-gate.sh"

pass=0; fail=0
t() { # t <name> <expected-rc> — runs ci_green_gate 42 o/r with current env
  local name="$1" want="$2" rc=0
  export GH_STUB_LOG="$TMP/calls-$name.log"; : > "$GH_STUB_LOG"
  ci_green_gate 42 o/r >"$TMP/out-$name" 2>"$TMP/err-$name" || rc=$?
  if [ "$rc" = "$want" ]; then pass=$((pass+1)); echo "ok   $name"
  else fail=$((fail+1)); echo "FAIL $name (rc=$rc want=$want)"; sed 's/^/  err: /' "$TMP/err-$name"; fi
}

GH_STUB_MODE=clean         t all-green-allows 0
GH_STUB_MODE=red-run       t failing-checkrun-blocks 2
GH_STUB_MODE=pending-run   t pending-checkrun-blocks 2
GH_STUB_MODE=red-status    t status-failure-blocks 2
GH_STUB_MODE=pend-status   t status-pending-blocks 2
GH_STUB_MODE=error-status  t status-error-blocks 2          # codex-1: a status 'error' must block
GH_STUB_MODE=many-runs     t over-100-checkruns-blocks 2    # codex-2: >100 check-runs can't certify green -> block
# coderabbit-1: the SAME page-limit stance for commit statuses — a red one may
# sit on an unread page 2, so a full page cannot certify green.
GH_STUB_MODE=many-statuses t over-100-statuses-blocks 2
GH_STUB_MODE=checkless     t checkless-pr-allows 0
# HIMMEL-1072: CodeRabbit is the CR gate's business. A pending CodeRabbit review
# alongside green CI must NOT block HERE — pre-1072 the combined /status
# aggregate folded it in and this gate blocked on it, defeating the exclusion it
# documents. Identity-matched on creator.id, so a foreign status keeping the
# CodeRabbit context still counts as real CI (and would block).
GH_STUB_MODE=cr-pending-only t coderabbit-pending-does-not-block-ci-gate 0
# ...but only CodeRabbit's OWN status is excluded: same context, foreign
# creator.id => ordinary CI => blocks (coderabbit-14). This is the assertion that
# makes the exclusion identity-based rather than context-based.
GH_STUB_MODE=cr-foreign-context t foreign-creator-in-coderabbit-context-blocks 2
# Newest-per-context: an old pending superseded by success is green.
GH_STUB_MODE=superseded    t superseded-pending-status-allows 0
# pr view itself fails -> rc=3 (selector unresolvable; still an allow, but lets
# the hook retry with a better anchor — mirrors cr_merge_gate, codex-1)
GH_STUB_MODE=error         t gh-pr-view-fails-rc3 3
# pr view succeeds, downstream check-runs API fails -> plain rc=0 fail-open
GH_STUB_MODE=api-error     t api-error-fails-open 0

# bypass env short-circuits BEFORE any gh call (independent of CR_PROFILE)
GH_STUB_MODE=red-run CI_MERGE_GATE_OK=1 t bypass-env-allows 0
[ -s "$TMP/calls-bypass-env-allows.log" ] && { echo "FAIL bypass called gh"; fail=$((fail+1)); }
unset CI_MERGE_GATE_OK
# CR_PROFILE must NOT affect the CI gate (it is independent of the CodeRabbit gate)
GH_STUB_MODE=red-run CR_PROFILE=none t cr-profile-none-still-blocks 2
unset CR_PROFILE

# block reasons land on stdout
grep -qi "failing checks" "$TMP/out-failing-checkrun-blocks" || { echo "FAIL block reason missing (red-run)"; fail=$((fail+1)); }
grep -qi "still running" "$TMP/out-pending-checkrun-blocks" || { echo "FAIL block reason missing (pending-run)"; fail=$((fail+1)); }
grep -qi "commit status" "$TMP/out-status-failure-blocks" || { echo "FAIL block reason missing (red-status)"; fail=$((fail+1)); }
# degradation notes land on stderr on the fail-open shapes
grep -qi "degraded" "$TMP/err-gh-pr-view-fails-rc3" || { echo "FAIL degradation note missing (rc3)"; fail=$((fail+1)); }
grep -qi "degraded" "$TMP/err-api-error-fails-open" || { echo "FAIL degradation note missing (rc0)"; fail=$((fail+1)); }
grep -qi "degraded" "$TMP/err-checkless-pr-allows" || { echo "FAIL degradation note missing (checkless)"; fail=$((fail+1)); }
# a real-green head is a SILENT pass (no degrade noise)
[ ! -s "$TMP/err-all-green-allows" ] || { echo "FAIL all-green emitted stderr"; cat "$TMP/err-all-green-allows"; fail=$((fail+1)); }
# Every allow-path must pass by EVALUATION, not by degrading (coderabbit-8):
# ci_green_gate fails OPEN, so a malformed fixture returns the same rc 0 as a
# genuine green — an assertion on rc alone cannot tell them apart, and these
# cases would silently stop testing what they name.
for ok_case in coderabbit-pending-does-not-block-ci-gate superseded-pending-status-allows; do
    if grep -qi "degraded" "$TMP/err-$ok_case" 2>/dev/null; then
        echo "FAIL $ok_case passed via a DEGRADE (fail-open), not real evaluation"
        sed 's/^/  err: /' "$TMP/err-$ok_case"
        fail=$((fail+1))
    fi
done

# head-SHA binding: the gate must query check-runs + status on the head SHA
# from `gh pr view` (abc123), proving it binds to the head, not a stale ref.
grep -q "commits/abc123/check-runs" "$TMP/calls-all-green-allows.log" || { echo "FAIL head-SHA not bound (check-runs)"; fail=$((fail+1)); }
grep -q "commits/abc123/status"      "$TMP/calls-all-green-allows.log" || { echo "FAIL head-SHA not bound (status)"; fail=$((fail+1)); }

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
