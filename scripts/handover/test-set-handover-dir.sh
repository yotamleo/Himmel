#!/usr/bin/env bash
# Tests for scripts/handover/set-handover-dir.sh (HIMMEL-335).
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/set-handover-dir.sh"

FAILED=0
assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then echo "PASS $label"
    else echo "FAIL $label — expected '$expected', got '$actual'"; FAILED=$((FAILED + 1)); fi
}
assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then echo "PASS $label (rc=$actual)"
    else echo "FAIL $label — expected rc=$expected, got rc=$actual"; FAILED=$((FAILED + 1)); fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
HDIR="$TMP/state/handovers"
mkdir -p "$HDIR"
HDIR_CANON="$(cd "$HDIR" && pwd)"

# T1: appended to a .env that lacks the key (other lines preserved).
ENV="$TMP/a.env"
printf 'USER_SLUG=tester\nJIRA_PROJECT_KEY=HIMMEL\n' > "$ENV"
bash "$SCRIPT" "$HDIR" --env-file "$ENV" >/dev/null 2>&1
assert_rc "T1 append rc=0" 0 "$?"
assert_eq "T1 key value" "HANDOVER_DIR=$HDIR_CANON" "$(grep '^HANDOVER_DIR=' "$ENV")"
assert_eq "T1 preserved other lines" "2" "$(grep -cE '^(USER_SLUG|JIRA_PROJECT_KEY)=' "$ENV")"

# T2: idempotent — second identical run keeps exactly one line.
bash "$SCRIPT" "$HDIR" --env-file "$ENV" >/dev/null 2>&1
assert_eq "T2 single HANDOVER_DIR line" "1" "$(grep -cE '^[[:space:]]*HANDOVER_DIR=' "$ENV")"

# T3: update in place — new value replaces old, line count unchanged.
OTHER="$TMP/state2/handovers"
mkdir -p "$OTHER"
OTHER_CANON="$(cd "$OTHER" && pwd)"
bash "$SCRIPT" "$OTHER" --env-file "$ENV" >/dev/null 2>&1
assert_eq "T3 updated value" "HANDOVER_DIR=$OTHER_CANON" "$(grep '^HANDOVER_DIR=' "$ENV")"
assert_eq "T3 still one line" "1" "$(grep -cE '^[[:space:]]*HANDOVER_DIR=' "$ENV")"

# T4: creates the .env when missing.
ENV2="$TMP/new-dir/fresh.env"
bash "$SCRIPT" "$HDIR" --env-file "$ENV2" >/dev/null 2>&1
assert_rc "T4 create .env rc=0" 0 "$?"
assert_eq "T4 created with key" "HANDOVER_DIR=$HDIR_CANON" "$(grep '^HANDOVER_DIR=' "$ENV2" 2>/dev/null)"

# T5: non-existent handover dir → fail-closed rc=2.
bash "$SCRIPT" "$TMP/nope" --env-file "$ENV" >/dev/null 2>&1
assert_rc "T5 missing dir rc=2" 2 "$?"

# T6: no arg → usage error rc=1.
bash "$SCRIPT" --env-file "$ENV" >/dev/null 2>&1
assert_rc "T6 usage rc=1" 1 "$?"

# T7b: stored path is forward-slash normalized (no backslashes).
case "$(grep '^HANDOVER_DIR=' "$ENV")" in
    *\\*) echo "FAIL T7b no backslashes in stored path"; FAILED=$((FAILED + 1)) ;;
    *)    echo "PASS T7b no backslashes in stored path" ;;
esac

# T7: a commented example line is left intact; an active line is appended.
ENV3="$TMP/commented.env"
printf '# HANDOVER_DIR=/c/example/path\n' > "$ENV3"
bash "$SCRIPT" "$HDIR" --env-file "$ENV3" >/dev/null 2>&1
assert_eq "T7 comment preserved" "1" "$(grep -c '^# HANDOVER_DIR=' "$ENV3")"
assert_eq "T7 active line added" "HANDOVER_DIR=$HDIR_CANON" "$(grep '^HANDOVER_DIR=' "$ENV3")"

# T8: --env-file=<path> equals form parses the same as the space form.
ENV4="$TMP/eq.env"
bash "$SCRIPT" "$HDIR" --env-file="$ENV4" >/dev/null 2>&1
assert_eq "T8 equals-form --env-file" "HANDOVER_DIR=$HDIR_CANON" "$(grep '^HANDOVER_DIR=' "$ENV4" 2>/dev/null)"

# T9: unknown flag → usage error rc=1.
bash "$SCRIPT" "$HDIR" --bogus >/dev/null 2>&1
assert_rc "T9 unknown flag rc=1" 1 "$?"

# T10: target exists but is not a regular file (a directory) → refuse rc=1
# with the specific guard diagnostic (asserting the message, not just rc=1,
# locks in the guard — a bare set -e fall-through would also yield rc=1).
mkdir -p "$TMP/envdir"
t10_out=$(bash "$SCRIPT" "$HDIR" --env-file "$TMP/envdir" 2>&1); t10_rc=$?
assert_rc "T10 non-regular-file target rc=1" 1 "$t10_rc"
case "$t10_out" in
    *"not a regular file"*) echo "PASS T10 emits guard diagnostic" ;;
    *) echo "FAIL T10 emits guard diagnostic — got: $t10_out"; FAILED=$((FAILED + 1)) ;;
esac

echo
if [ "$FAILED" -eq 0 ]; then echo "All set-handover-dir tests passed."
else echo "$FAILED set-handover-dir test(s) failed."; exit 1; fi
