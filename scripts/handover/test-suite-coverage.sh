#!/usr/bin/env bash
# scripts/handover/test-suite-coverage.sh — HIMMEL-4112. Covers suite-coverage.sh:
# fixture runner for each verdict branch, then the real run-shell-tests.sh for
# the three suites the ticket names.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SC="$HERE/suite-coverage.sh"
REAL="$HERE/../ci/run-shell-tests.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/suite-coverage.XXXXXX")" || exit 1; trap 'rm -rf "$tmp"' EXIT
fail=0
pass() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; [ -n "${2:-}" ] && printf '    got: %s\n' "$2"; fail=1; }
expect() {  # <desc> <ere> <actual>
  if grep -Eq -- "$2" <<< "$3"; then pass "$1"; else bad "$1" "$3"; fi
}

cat > "$tmp/runner.sh" <<'EOF'
SUITE_TIMEOUT=$(_suite_num SUITE_TIMEOUT "${SUITE_TIMEOUT:-600}" 600)
_suite_timeout_for() {
  case "${1#./}" in
    scripts/slow/test-slow.sh|*/scripts/slow/test-slow.sh)
      printf '1700' ;;
    *)
      printf '%s' "$SUITE_TIMEOUT" ;;
  esac
}
SKIP_LIST="
scripts/vm/test-vm.sh  # drives a real VM over SSH
scripts/big/test-big.sh  # superseded by its two --only wrappers below: test-big-fast.sh and test-big-slow.sh
"
SUITE_TIER_DEFAULT="
scripts/slow/test-slow.sh  extended  # measured 843s
"
EOF

out=$(bash "$SC" --runner "$tmp/runner.sh" scripts/vm/test-vm.sh 2>&1)
expect "SKIP_LIST suite is uncovered, never verified" 'not run in CI.*uncovered' "$out"
out=$(bash "$SC" --runner "$tmp/runner.sh" scripts/big/test-big.sh 2>&1)
expect "superseded suite names its wrappers" 'superseded by .*test-big-fast.sh.*test-big-slow.sh' "$out"
out=$(bash "$SC" --runner "$tmp/runner.sh" scripts/slow/test-slow.sh 2>&1)
expect "extended tier is nightly only with its cap" 'nightly only.*1700' "$out"
out=$(bash "$SC" --runner "$tmp/runner.sh" scripts/plain/test-plain.sh 2>&1)
expect "unlisted suite runs in PR CI" 'runs in PR CI' "$out"
out=$(bash "$SC" --runner "$tmp/runner.sh" ./scripts/vm/test-vm.sh 2>&1)
expect "./-spelled path matches" 'not run in CI' "$out"
out=$(bash "$SC" --runner "$tmp/runner.sh" scripts/vm/pre-test-vm.sh 2>&1)
expect "suffix match respects the / boundary" 'runs in PR CI' "$out"
bash "$SC" --runner "$tmp/none.sh" scripts/x/test-x.sh >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then pass "missing runner exits 2"; else bad "missing runner exits 2"; fi

timeout 5 bash "$SC" scripts/x/test-x.sh --runner >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then pass "trailing --runner without a value exits 2 (no hang)"; else bad "trailing --runner without a value exits 2 (rc=$rc)"; fi
out=$(bash "$SC" scripts/nope/test-nonexistent.sh 2>&1)
expect "real: a nonexistent suite is unknown, not 'runs in PR CI'" 'unknown' "$out"
printf 'not a runner\n' > "$tmp/junk.sh"
bash "$SC" --runner "$tmp/junk.sh" scripts/x/test-x.sh >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then pass "incompatible runner exits 2"; else bad "incompatible runner exits 2 (rc=$rc)"; fi

out=$(bash "$SC" --runner "$REAL" scripts/test-install-symmetry-vm.sh 2>&1)
expect "real: install-symmetry-vm not run in CI" 'not run in CI' "$out"
out=$(bash "$SC" --runner "$REAL" scripts/handover/test-arm-resume.sh 2>&1)
expect "real: arm-resume superseded by both wrappers" 'superseded by .*test-arm-resume-fast.sh.*test-arm-resume-1879.sh' "$out"
out=$(bash "$SC" --runner "$REAL" scripts/handover/test-arm-resume-1879.sh 2>&1)
expect "real: arm-resume-1879 runs with a 1700s cap" '1700' "$out"

[ "$fail" -eq 0 ] && echo "PASS: suite-coverage" || echo "FAIL: suite-coverage"
exit "$fail"
