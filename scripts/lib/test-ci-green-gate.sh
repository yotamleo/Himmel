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
  "api repos/o/r/commits/abc123/status")
    case "$GH_STUB_MODE" in
      red-status) echo '{"state":"failure","total_count":1,"statuses":[{"context":"ci/legacy","state":"failure"}]}' ;;
      pend-status) echo '{"state":"pending","total_count":2,"statuses":[{"context":"ci/a","state":"pending"},{"context":"ci/b","state":"pending"}]}' ;;
      error-status) echo '{"state":"error","total_count":1,"statuses":[{"context":"ci/legacy","state":"error"}]}' ;;
      checkless)  echo '{"state":"","total_count":0,"statuses":[]}' ;;
      *)          echo '{"state":"success","total_count":1,"statuses":[{"context":"ci/legacy","state":"success"}]}' ;;
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
GH_STUB_MODE=error-status  t status-error-blocks 2          # codex-1: combined status 'error' must block
GH_STUB_MODE=many-runs     t over-100-checkruns-blocks 2    # codex-2: >100 check-runs can't certify green -> block
GH_STUB_MODE=checkless     t checkless-pr-allows 0
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

# head-SHA binding: the gate must query check-runs + status on the head SHA
# from `gh pr view` (abc123), proving it binds to the head, not a stale ref.
grep -q "commits/abc123/check-runs" "$TMP/calls-all-green-allows.log" || { echo "FAIL head-SHA not bound (check-runs)"; fail=$((fail+1)); }
grep -q "commits/abc123/status"      "$TMP/calls-all-green-allows.log" || { echo "FAIL head-SHA not bound (status)"; fail=$((fail+1)); }

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
