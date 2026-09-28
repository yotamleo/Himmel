#!/usr/bin/env bash
# Smoke test for scripts/cr/pr-check-step0.sh (HIMMEL-3798).
#
# Runs the script under test against an isolated mktemp fixture only - never
# the real repo. The fixture's scripts/cr/pr-check-context.sh is a stub, so
# this test exercises pr-check-step0.sh's own HIMMEL_REPO handling and
# hand-off, not pr-check-context.sh's own logic (that has its own suite).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/pr-check-step0.sh"

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
check_rc() {
    # $1 = got  $2 = want  $3 = label
    if [ "$1" -eq "$2" ]; then
        pass=$((pass + 1))
        echo "PASS: $3"
    else
        fail=$((fail + 1))
        echo "FAIL: $3 -- got rc=$1 want rc=$2"
    fi
}

tmp="$(mktemp -d -t test-pr-check-step0.XXXXXX)" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$tmp"' EXIT

fixture="$tmp/fixture"
mkdir -p "$fixture/scripts/cr"
cp "$SCRIPT" "$fixture/scripts/cr/pr-check-step0.sh"
cat >"$fixture/scripts/cr/pr-check-context.sh" <<'EOF'
#!/usr/bin/env bash
echo "stub-pr-check-context: HIMMEL_REPO=$HIMMEL_REPO"
EOF
chmod +x "$fixture/scripts/cr/pr-check-context.sh"
run="$fixture/scripts/cr/pr-check-step0.sh"

# T1: HIMMEL_REPO unset -> fail closed, exit 2, remedy on stderr.
out1="$(env -u HIMMEL_REPO bash "$run" 2>&1)"
rc1=$?
check "$out1" "pr-check: HIMMEL_REPO is unset or empty — cannot locate himmel from a trusted source outside the repo under review; adopt/setup wires it into settings.json env, or export it non-empty in your launching shell, then re-run" "T1 unset HIMMEL_REPO prints remedy"
check_rc "$rc1" 2 "T1 unset HIMMEL_REPO exits 2"

# T2: HIMMEL_REPO set but empty -> same fail-closed remedy as unset.
out2="$(HIMMEL_REPO="" bash "$run" 2>&1)"
rc2=$?
check "$out2" "pr-check: HIMMEL_REPO is unset or empty — cannot locate himmel from a trusted source outside the repo under review; adopt/setup wires it into settings.json env, or export it non-empty in your launching shell, then re-run" "T2 empty HIMMEL_REPO prints remedy"
check_rc "$rc2" 2 "T2 empty HIMMEL_REPO exits 2"

# T3: HIMMEL_REPO set -> hands off to the anchor's pr-check-context.sh with
# HIMMEL_REPO still in its environment.
out3="$(HIMMEL_REPO="$fixture" bash "$run" 2>&1)"
rc3=$?
check "$out3" "stub-pr-check-context: HIMMEL_REPO=$fixture" "T3 set HIMMEL_REPO hands off to pr-check-context.sh"
check_rc "$rc3" 0 "T3 set HIMMEL_REPO exits 0 (stub's own exit)"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
