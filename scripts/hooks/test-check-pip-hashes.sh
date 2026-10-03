#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-pip-hashes.sh (HIMMEL-4137).
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/check-pip-hashes.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/pip-hashes-test.XXXXXX") || exit 1
trap 'chmod 644 "$TMP/unreadable.txt" 2>/dev/null; rm -rf "$TMP"' EXIT

FAILED=0
H='--hash=sha256:0000000000000000000000000000000000000000000000000000000000000000'

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

# run_hook <args...> — runs from $TMP, stdout+stderr to $TMP/out, prints rc.
run_hook() {
    (cd "$TMP" && bash "$HOOK" "$@" >"$TMP/out" 2>&1 </dev/null)
    echo "$?"
}

assert_out() {
    local label="$1" present="$2" pattern="$3"
    grep -q -- "$pattern" "$TMP/out"
    case $? in
        0) got=yes ;;
        1) got=no ;;
        *) echo "FAIL $label — grep errored on $TMP/out"; FAILED=$((FAILED + 1)); return 0 ;;
    esac
    if [ "$got" = "$present" ]; then
        echo "PASS $label"
    else
        echo "FAIL $label — pattern '$pattern' present=$got, wanted $present"
        FAILED=$((FAILED + 1))
    fi
}

# T1: hashed → ok
printf 'requests==2.0 %s\n' "$H" > "$TMP/hashed.txt"
assert_rc "T1 hashed" 0 "$(run_hook hashed.txt)"

# T2: unhashed → BLOCK, with the regenerate hint
printf 'requests==2.0\n' > "$TMP/unhashed.txt"
assert_rc "T2 unhashed" 1 "$(run_hook unhashed.txt)"
assert_out "T2 unhashed prints the regenerate hint" yes 'Regenerate the file with hashes'

# T3: hashed continuation → ok
printf 'requests==2.0 \\\n    %s\n' "$H" > "$TMP/cont.txt"
assert_rc "T3 hashed continuation" 0 "$(run_hook cont.txt)"

# T4: unhashed continuation dangling at EOF → BLOCK
printf 'requests==2.0 \\\n' > "$TMP/eof.txt"
assert_rc "T4 unhashed continuation at EOF" 1 "$(run_hook eof.txt)"

# T5: mixed hashed + unhashed → BLOCK
printf 'a==1 %s\nb==2\n' "$H" > "$TMP/mixed.txt"
assert_rc "T5 mixed" 1 "$(run_hook mixed.txt)"

# T6: CRLF line endings, hashed → ok
printf 'requests==2.0 %s\r\n' "$H" > "$TMP/crlf.txt"
assert_rc "T6 CRLF hashed" 0 "$(run_hook crlf.txt)"

# T7: directives, comments and blanks only → ok
printf -- '-r base.txt\n--index-url https://x\n# c\n\n' > "$TMP/directives.txt"
assert_rc "T7 directives" 0 "$(run_hook directives.txt)"

# T8: empty file → ok
: > "$TMP/empty.txt"
assert_rc "T8 empty" 0 "$(run_hook empty.txt)"

# T9: no args → ok
assert_rc "T9 no args" 0 "$(run_hook)"

# T10: unreadable → BLOCK, and NO regenerate hint (the file was never read)
printf 'requests==2.0 %s\n' "$H" > "$TMP/unreadable.txt"
chmod 000 "$TMP/unreadable.txt"
if [ -r "$TMP/unreadable.txt" ]; then
    echo "SKIP T10 unreadable (running as a user that can read mode 000)"
else
    assert_rc "T10 unreadable" 1 "$(run_hook unreadable.txt)"
    assert_out "T10 unreadable says so" yes 'is unreadable'
    assert_out "T10 unreadable prints no regenerate hint" no 'Regenerate the file with hashes'
fi
chmod 644 "$TMP/unreadable.txt"

# T11: dangling symlink → BLOCK, naming the file (HIMMEL-4144)
ln -s "$TMP/nowhere" "$TMP/dangling.txt"
assert_rc "T11 dangling symlink blocks" 1 "$(run_hook dangling.txt)"
assert_out "T11 names the file" yes 'dangling.txt does not exist'

# T16: missing file → BLOCK, naming it. A deleted file never reaches the hook
# (pre-commit passes only existing staged files), so its siblings still pass.
assert_rc "T16 missing file blocks" 1 "$(run_hook missing.txt)"
assert_out "T16 names the file" yes 'missing.txt does not exist'
assert_out "T16 prints no regenerate hint" no 'Regenerate the file with hashes'
assert_rc "T16 missing + hashed still blocks" 1 "$(run_hook hashed.txt missing.txt)"
assert_rc "T16 hashed alone (deleted sibling not passed) passes" 0 "$(run_hook hashed.txt)"

# T17: a hash only inside a comment does not count (HIMMEL-4144)
printf 'requests==2.0 # %s\n' "$H" > "$TMP/trail-comment.txt"
assert_rc "T17 trailing-comment hash blocks" 1 "$(run_hook trail-comment.txt)"
printf 'requests==2.0 \\\n    # %s\n' "$H" > "$TMP/cont-comment.txt"
assert_rc "T17 comment-line hash in continuation blocks" 1 "$(run_hook cont-comment.txt)"
printf 'requests==2.0 %s # pinned\n' "$H" > "$TMP/real-and-comment.txt"
assert_rc "T17 real hash plus comment passes" 0 "$(run_hook real-and-comment.txt)"
printf 'requests==2.0 \\\n    %s \\\n    %s\n' "$H" "$H" > "$TMP/multi.txt"
assert_rc "T17 multi-hash continuation passes" 0 "$(run_hook multi.txt)"

# T18: a backslash followed by a comment is NOT a continuation (pip decides on
# the raw line), so the next line is its own, unhashed, requirement.
printf '%s \\\\ #c\nbar==2\n' "$H" > "$TMP/c1.txt"
assert_rc "T18 hash then double-backslash comment, bar unhashed" 1 "$(run_hook c1.txt)"
printf -- '--require-hashes \\\\ #c\nbar==2\n' > "$TMP/c2.txt"
assert_rc "T18 --require-hashes double-backslash comment, bar unhashed" 1 "$(run_hook c2.txt)"
printf 'foo==1 %s \\\\ #c\nbar==2\n' "$H" > "$TMP/c3.txt"
assert_rc "T18 foo hashed double-backslash comment, bar unhashed" 1 "$(run_hook c3.txt)"
printf 'foo==1 %s \\ #c\nbar==2\n' "$H" > "$TMP/c4.txt"
assert_rc "T18 single-backslash comment, bar unhashed" 1 "$(run_hook c4.txt)"
printf 'foo==1 %s \\ #c\nbar==2 %s\n' "$H" "$H" > "$TMP/c5.txt"
assert_rc "T18 same shape with bar hashed passes" 0 "$(run_hook c5.txt)"

# T12-T15: hostile names must be scanned, not read as awk assignment / stdin / option
printf 'requests==2.0\n' > "$TMP/x=1.txt"
assert_rc "T12 name=value filename unhashed" 1 "$(run_hook x=1.txt)"
assert_out "T12 names the missing hash" yes "without --hash=sha256"
printf 'requests==2.0\n' > "$TMP/-"
assert_rc "T13 file named - unhashed" 1 "$(run_hook -)"
assert_out "T13 names the missing hash" yes "without --hash=sha256"
rm -f "$TMP/-"
printf 'requests==2.0\n' > "$TMP/--"
assert_rc "T14 file named -- unhashed" 1 "$(run_hook --)"
assert_out "T14 names the missing hash" yes "without --hash=sha256"
rm -f "$TMP/--"
printf 'requests==2.0\n' > "$TMP/-lead.txt"
assert_rc "T15 file named -lead.txt unhashed" 1 "$(run_hook -lead.txt)"
assert_out "T15 names the missing hash" yes "without --hash=sha256"

if [ "$FAILED" -gt 0 ]; then
    echo "---"
    echo "FAIL $FAILED case(s)"
    exit 1
fi
echo "---"
echo "PASS all cases"
exit 0
