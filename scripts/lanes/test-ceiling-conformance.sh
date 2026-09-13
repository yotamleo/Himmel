#!/usr/bin/env bash
# scripts/lanes/test-ceiling-conformance.sh - HIMMEL-2974. Hermetic tests for
# the live --autocompact-ceiling scan: PATH-stubbed pgrep, no real process
# table read.
#
# PLATFORM GUARD: no .ps1 twin, by design -- the SUT is Linux-only (pgrep).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/ceiling-conformance.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/ceiling-test.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
contains() {
    case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3' in '$2')" ;; esac
}

mkdir -p "$W/bin"

# (a) two pinned legs + one console -> ceiling=ok
cat > "$W/bin/pgrep" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' \
  '101 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-111-legN61-2026-09-13 work' \
  '102 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-222-legN62-2026-09-13 work' \
  '103 claude --model claude-fable-5-1 --autocompact auto -n HIMMEL-nextleg-2026-09-13A-console work'
STUB
chmod +x "$W/bin/pgrep"
out_a="$(PATH="$W/bin:$PATH" bash "$SUT")"; rc_a=$?
if [ "$rc_a" -eq 0 ]; then pass 'two pinned legs + one console exits 0'; else fail "exits 0 (rc=$rc_a)"; fi
contains 'two pinned legs + one console -> ceiling=ok' "$out_a" 'ceiling=ok'
contains 'per-session line for a pinned leg' "$out_a" 'HIMMEL-111-legN61-2026-09-13 200000'
contains 'per-session line for the console' "$out_a" 'HIMMEL-nextleg-2026-09-13A-console auto'

# (b) one leg with --autocompact auto -> DRIFT naming it
cat > "$W/bin/pgrep" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' \
  '104 claude --model claude-sonnet-5 --autocompact auto -n HIMMEL-333-legN63-2026-09-13 work'
STUB
out_b="$(PATH="$W/bin:$PATH" bash "$SUT")"
contains 'a leg with --autocompact auto is DRIFT' "$out_b" 'ceiling=DRIFT:HIMMEL-333-legN63-2026-09-13'

# (c) a leg with no --autocompact at all -> DRIFT
cat > "$W/bin/pgrep" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' \
  '105 claude --model claude-sonnet-5 -n HIMMEL-444-legN64-2026-09-13 work'
STUB
out_c="$(PATH="$W/bin:$PATH" bash "$SUT")"
contains 'a leg with no --autocompact at all is DRIFT' "$out_c" 'ceiling=DRIFT:HIMMEL-444-legN64-2026-09-13'
contains 'a leg with no --autocompact prints unset' "$out_c" 'HIMMEL-444-legN64-2026-09-13 unset'

# (d) a non-leg non-console `claude -n foo --autocompact auto` -> DRIFT
cat > "$W/bin/pgrep" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' \
  '106 claude --autocompact auto -n foo work'
STUB
out_d="$(PATH="$W/bin:$PATH" bash "$SUT")"
contains 'a non-leg non-console name with auto is DRIFT' "$out_d" 'ceiling=DRIFT:foo'

# (e) the console row alone -> ok
cat > "$W/bin/pgrep" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' \
  '107 claude --model claude-fable-5-1 --autocompact auto -n HIMMEL-nextleg-2026-09-13B-console work'
STUB
out_e="$(PATH="$W/bin:$PATH" bash "$SUT")"
contains 'the console row alone is ok' "$out_e" 'ceiling=ok'

if [ "$fails" -eq 0 ]; then
    printf '%s\n' 'PASS - test-ceiling-conformance.sh'
    exit 0
fi
printf 'FAIL - test-ceiling-conformance.sh (%s failure(s))\n' "$fails"
exit 1
