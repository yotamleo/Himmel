#!/usr/bin/env bash
# Regression guard for HIMMEL-3608: the deterministic ship tail
# (merge-on-green.sh, ready-check.sh, tick.sh, check-ci.sh) must never gain a
# headless `claude -p`/`--print`/`--bg` call. See docs/internals/ship-tail-model-free.md
# for the ruling this test encodes.
#
# Distinct in intent from scripts/hooks/check-no-headless-claude.sh (a general
# billing gate over ALL staged files, opt-in-markable): this test names the
# ship-tail file set specifically and has no opt-in escape, because the
# invariant it protects is not billing but "this path never needs a model."
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$DIR/../.."

SHIP_TAIL_FILES=(
    "scripts/handover/merge-on-green.sh"
    "scripts/handover/console-kit/ready-check.sh"
    "scripts/handover/console-kit/tick.sh"
    "scripts/check-ci.sh"
)

# Same detection pattern as scripts/hooks/check-no-headless-claude.sh
# (word-bounded `claude -p`/`--print`/`--bg`), kept independent here rather
# than sourced so this test's failure mode doesn't depend on that gate's file.
PATTERN='(^|[^A-Za-z0-9_-])claude[[:space:]]+(-p|--print|--bg)($|[^A-Za-z0-9_-])'

pass=0
fail=0
check() {
    # $1 = got  $2 = want  $3 = label
    if [ "$1" = "$2" ]; then
        pass=$((pass + 1))
        echo "PASS: $3"
    else
        fail=$((fail + 1))
        echo "FAIL: $3 -- got '$1' want '$2'"
    fi
}

tmp="$(mktemp -d -t test-ship-tail-model-free.XXXXXX)"; trap 'rm -rf "$tmp"' EXIT

# --- RED proof: an injected headless call in a fixture copy of a real
# ship-tail file must trip the pattern, so a future regression here would
# actually fail this test rather than pass vacuously. -----------------------
fixture="$tmp/merge-on-green.sh"
cp "$REPO/scripts/handover/merge-on-green.sh" "$fixture"
printf '\nclaude -p "drive the merge"\n' >>"$fixture"

if grep -En "$PATTERN" -- "$fixture" >/dev/null 2>&1; then
    got="matched"
else
    got="no-match"
fi
check "$got" "matched" "T1 injected headless call in fixture is caught"

# --- Real assertion: none of the named ship-tail files contain a headless
# call today. -----------------------------------------------------------
violations=()
for f in "${SHIP_TAIL_FILES[@]}"; do
    path="$REPO/$f"
    if [ ! -f "$path" ]; then
        violations+=("$f:missing")
        continue
    fi
    while IFS=: read -r line_no _; do
        [ -z "$line_no" ] && continue
        violations+=("$f:$line_no")
    done < <(grep -En "$PATTERN" -- "$path" 2>/dev/null)
done

if [ "${#violations[@]}" -eq 0 ]; then
    got="clean"
else
    got="${violations[*]}"
fi
check "$got" "clean" "T2 ship-tail files stay model-free"

[ "$fail" -eq 0 ] && echo "PASS test-ship-tail-model-free ($pass/$((pass + fail)))"
[ "$fail" -eq 0 ] || { echo "FAIL test-ship-tail-model-free ($fail/$((pass + fail)) failed)"; exit 1; }
