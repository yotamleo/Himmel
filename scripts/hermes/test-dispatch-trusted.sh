#!/usr/bin/env bash
# Tests for scripts/hermes/dispatch-trusted.sh (HIMMEL-654 escape hatch).
# Stubs invoke.sh via HERMES_INVOKE; asserts env opt-in + profile defaulting.
set -uo pipefail

WRAP="$(cd "$(dirname "$0")" && pwd)/dispatch-trusted.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAILED=0

check() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then echo "PASS $label"
    else echo "FAIL $label — expected [$expected], got [$actual]"; FAILED=$((FAILED+1)); fi
}
check_contains() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in *"$needle"*) echo "PASS $label" ;;
        *) echo "FAIL $label — missing: $needle | got: $haystack"; FAILED=$((FAILED+1)) ;; esac
}

# Stub invoke: record env + argv, exit 0.
STUB="$TMP/invoke-stub.sh"
cat > "$STUB" <<EOS
#!/usr/bin/env bash
printf '%s\n' "WRITES_OK=\${HERMES_EXTERNAL_WRITES_OK:-unset}" > "$TMP/env.out"
printf '%s\n' "\$@" > "$TMP/args.out"
exit 0
EOS
chmod +x "$STUB"

# T1: opt-in env var reaches the invoke child.
HERMES_INVOKE="$STUB" bash "$WRAP" "PONG" >/dev/null 2>&1
check "T1 wrapper exits 0" 0 $?
check "T1 HERMES_EXTERNAL_WRITES_OK=1 in child env" "WRITES_OK=1" "$(cat "$TMP/env.out")"

# T2: default profile injected when caller passes none.
check_contains "T2 default --profile himmel_agent injected" "--profile
himmel_agent" "$(cat "$TMP/args.out")"

# T3: explicit --profile passes through, NOT duplicated.
HERMES_INVOKE="$STUB" bash "$WRAP" --profile free_junior "PONG" >/dev/null 2>&1
profile_count=$(grep -c -- "--profile" "$TMP/args.out")
check "T3 explicit profile not duplicated" "1" "$profile_count"
check_contains "T3 explicit profile preserved" "free_junior" "$(cat "$TMP/args.out")"

# T4: missing invoke chokepoint -> rc 2, clean error.
err=$(HERMES_INVOKE="$TMP/nope.sh" bash "$WRAP" "PONG" 2>&1); rc=$?
check "T4 missing invoke exits 2" 2 "$rc"
check_contains "T4 names the missing path" "invoke chokepoint not found" "$err"

if [ "$FAILED" -gt 0 ]; then echo "---"; echo "FAIL $FAILED case(s)"; exit 1; fi
echo "---"; echo "PASS all cases"; exit 0
