#!/usr/bin/env bash
# scripts/handover/test-merge-forward-check.sh — HIMMEL-4114. Fixture-driven
# coverage of merge-forward-check.sh: ALLOW only a red inherited from the
# merge-base and fixed on latest main; a red the PR introduced never passes.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MF="${MF:-$HERE/merge-forward-check.sh}"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/merge-forward-check.XXXXXX")" || exit 1; trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; [ -n "${2:-}" ] && printf '    got: %s\n' "$2"; fail=1; }
# run <desc> <expected-rc> <expected-ere> [extra args] -- uses $tmp/{pr,base,latest}
run() {
  local d="$1" want="$2" re="$3" out rc
  shift 3
  out=$(bash "$MF" --pr "$tmp/pr" --main-base "$tmp/base" --main-latest "$tmp/latest" "$@" 2>&1); rc=$?
  if [ "$rc" -eq "$want" ] && grep -Eq -- "$re" <<< "$out"; then ok "$d"; else bad "$d (rc=$rc, want $want)" "$out"; fi
}
set3() { printf '%b' "$1" > "$tmp/pr"; printf '%b' "$2" > "$tmp/base"; printf '%b' "$3" > "$tmp/latest"; }

# the defect (HIMMEL-4114): green at base, red on the PR, green on latest = the PR's own red
set3 'shell-tests\tfailure\nlint\tsuccess\n' 'shell-tests\tsuccess\nlint\tsuccess\n' 'shell-tests\tsuccess\nlint\tsuccess\n'
run "green at base + red on PR + green on latest: REFUSE (the PR's own red)" 1 'REFUSE.*shell-tests.*not inherited'

set3 'shell-tests\tfailure\nlint\tsuccess\n' 'shell-tests\tfailure\nlint\tsuccess\n' 'shell-tests\tsuccess\nlint\tsuccess\n'
run "red at base + red on PR + green on latest: ALLOW" 0 'ALLOW.*shell-tests'

set3 'a\ttimed_out\n' 'a\tstartup_failure\n' 'a\tsuccess\n'
run "timed_out on PR, startup_failure at base, green on latest: ALLOW" 0 'ALLOW.*a'

set3 'a\tfailure\nb\tfailure\n' 'a\tfailure\nb\tsuccess\n' 'a\tsuccess\nb\tsuccess\n'
run "one of two reds green at base: REFUSE" 1 'REFUSE.*b.*not inherited'

set3 'a\tfailure\n' 'other\tfailure\n' 'a\tsuccess\n'
run "red job absent from the base run: REFUSE" 1 'REFUSE.*a.*absent'

set3 'a\tfailure\n' 'a\tfailure\n' 'other\tsuccess\n'
run "red job absent from the latest run: REFUSE" 1 'REFUSE.*a.*absent'

set3 'a\tfailure\n' 'a\tfailure\n' 'a\tfailure\n'
run "red on latest main too: REFUSE" 1 'REFUSE.*a.*not proven fixed'

set3 'a\tsuccess\nb\tskipped\n' 'a\tsuccess\n' 'a\tsuccess\n'
run "nothing red: no merge-forward needed" 3 'nothing red'

# base run sha check
set3 'a\tfailure\n' 'a\tfailure\n' 'a\tsuccess\n'
run "base run sha equals the merge-base: ALLOW" 0 'ALLOW' --base-sha abc123 --main-base-sha abc123
run "base run sha differs from the merge-base: REFUSE" 1 'REFUSE.*merge-base' --base-sha abc123 --main-base-sha def456
run "--base-sha without --main-base-sha: usage" 2 'usage' --base-sha abc123

# input errors
rm -f "$tmp/base"
run "base file missing: usage error, never ALLOW" 2 'usage'
set3 'a\tfailure\n' 'a\tfailure\n' 'a\tsuccess\n'
rm -f "$tmp/latest"
run "latest file missing: usage error, never ALLOW" 2 'usage'

# shellcheck source=../lib/timeout-bin.sh
. "$HERE/../lib/timeout-bin.sh"
if [ -n "$_TIMEOUT_BIN" ]; then
  "$_TIMEOUT_BIN" 5 bash "$MF" --pr "$tmp/pr" --main-base "$tmp/pr" --main-latest >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 2 ]; then ok "trailing --main-latest without a value exits 2 (no hang)"; else bad "trailing --main-latest without a value exits 2 (rc=$rc)"; fi
else
  echo "SKIP: trailing --main-latest no-hang row (no timeout binary)"
fi

# a malformed PR row must not be silently ignored (it could hide a red)
set3 'a\tfailure\nb failure\n' 'a\tfailure\nb\tfailure\n' 'a\tsuccess\nb\tsuccess\n'
run "malformed PR row (no tab): usage error, never ALLOW" 2 'malformed'
set3 'a\tfailure\nb\tfailure \n' 'a\tfailure\nb\tfailure\n' 'a\tsuccess\nb\tsuccess\n'
run "malformed conclusion (trailing space): usage error, never ALLOW" 2 'malformed'
set3 'a\tfailure\nb\tfailed\n' 'a\tfailure\nb\tfailure\n' 'a\tsuccess\nb\tsuccess\n'
run "unknown conclusion value: usage error, never ALLOW" 2 'malformed'
set3 'a\tfailure\n' 'a\tfailure\n' 'a\tsuccess\tfailure\n'
run "malformed latest row (three fields): usage error, never ALLOW" 2 'malformed'
set3 'a\tfailure\n' 'a failure\n' 'a\tsuccess\n'
run "malformed base row (no tab): usage error, never REFUSE-by-accident" 2 'malformed'

# duplicate job names: one green row on latest must not hide a red one
set3 'a\tfailure\n' 'a\tfailure\n' 'a\tsuccess\na\tfailure\n'
run "duplicate job on latest, one row red: REFUSE" 1 'REFUSE.*a.*not proven fixed'
set3 'a\tfailure\n' 'a\tsuccess\na\tfailure\n' 'a\tsuccess\n'
run "duplicate job at base, one row red: inherited, ALLOW" 0 'ALLOW.*a'

bash "$MF" --pr "$tmp/pr" --main "$tmp/pr" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then ok "the old 2-file --main form is refused (exit 2)"; else bad "the old --main form exits 2 (rc=$rc)"; fi

[ "$fail" -eq 0 ] && echo "PASS: merge-forward-check" || echo "FAIL: merge-forward-check"
exit "$fail"
