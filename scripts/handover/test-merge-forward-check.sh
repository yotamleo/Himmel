#!/usr/bin/env bash
# scripts/handover/test-merge-forward-check.sh — HIMMEL-4112. Fixture-driven
# coverage of both decision branches of merge-forward-check.sh.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MF="$HERE/merge-forward-check.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/merge-forward-check.XXXXXX")" || exit 1; trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; [ -n "${2:-}" ] && printf '    got: %s\n' "$2"; fail=1; }
# run <desc> <expected-rc> <expected-ere> -- uses $tmp/pr and $tmp/main
run() {
  local out rc
  out=$(bash "$MF" --pr "$tmp/pr" --main "$tmp/main" 2>&1); rc=$?
  if [ "$rc" -eq "$2" ] && grep -Eq -- "$3" <<< "$out"; then ok "$1"; else bad "$1 (rc=$rc, want $2)" "$out"; fi
}

printf 'shell-tests\tfailure\nlint\tsuccess\nbuild\tsuccess\n' > "$tmp/pr"
printf 'shell-tests\tsuccess\nlint\tsuccess\nbuild\tsuccess\n' > "$tmp/main"
run "red only on suites green on main: ALLOW" 0 'ALLOW.*shell-tests'

printf 'shell-tests\tfailure\nlint\tsuccess\n' > "$tmp/pr"
printf 'shell-tests\tfailure\nlint\tsuccess\n' > "$tmp/main"
run "a red suite also red on main: REFUSE" 1 'REFUSE.*shell-tests'

printf 'a\tfailure\nb\tfailure\n' > "$tmp/pr"
printf 'a\tsuccess\nb\tfailure\n' > "$tmp/main"
run "one of two reds also red on main: REFUSE" 1 'REFUSE.*b'

printf 'a\tfailure\n' > "$tmp/pr"
printf 'other\tsuccess\n' > "$tmp/main"
run "red suite absent from main run: REFUSE (cannot show green)" 1 'REFUSE.*a'

printf 'a\tsuccess\nb\tskipped\n' > "$tmp/pr"
printf 'a\tsuccess\n' > "$tmp/main"
run "nothing red: no merge-forward needed" 3 'nothing red'

printf 'a\ttimed_out\n' > "$tmp/pr"
printf 'a\tsuccess\n' > "$tmp/main"
run "timed_out counts as red: ALLOW" 0 'ALLOW.*a'

bash "$MF" --pr "$tmp/none" --main "$tmp/main" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 2 ]; then ok "unreadable input exits 2"; else bad "unreadable input exits 2"; fi

[ "$fail" -eq 0 ] && echo "PASS: merge-forward-check" || echo "FAIL: merge-forward-check"
exit "$fail"
