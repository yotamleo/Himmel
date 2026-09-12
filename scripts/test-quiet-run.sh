#!/usr/bin/env bash
# Tests for scripts/quiet-run.sh's argv path guard (HIMMEL-2967): refuses
# ".." path components in any argv element, and (label "suite" only) requires
# a git-tracked test-*.sh when argv is `bash <path> ...`.
#
# Usage: bash scripts/test-quiet-run.sh
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Pure bash + coreutils + git; no .ps1 twin needed.
#
# Exit codes:
#   0 - all cases passed
#   1 - at least one case failed
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QUIET_RUN="$REPO_ROOT/scripts/quiet-run.sh"
PRE_FIX_BASE="541a866b34d8b93942b1556145e2e5d97c4ee390"

FAILED=0
SCRATCH="$(mktemp -d)"
UNTRACKED_ABS=""
# shellcheck disable=SC2329,SC2317
cleanup() {
    rm -rf "$SCRATCH"
    [ -n "$UNTRACKED_ABS" ] && rm -f "$UNTRACKED_ABS"
}
trap cleanup EXIT

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label - expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*)
            echo "PASS $label (message matches)"
            ;;
        *)
            echo "FAIL $label - message did not contain: $needle"
            echo "  got: $haystack"
            FAILED=$((FAILED + 1))
            ;;
    esac
}

# 1. RED control: the traversal shape against the PRE-FIX script (base
# 541a866b34d8b93942b1556145e2e5d97c4ee390) executes - proves the control
# can actually fail before asserting the fixed script blocks it.
PRE_FIX="$SCRATCH/quiet-run-prefix.sh"
git -C "$REPO_ROOT" show "$PRE_FIX_BASE:scripts/quiet-run.sh" > "$PRE_FIX"
chmod +x "$PRE_FIX"
mkdir -p "$SCRATCH/red-log" "$SCRATCH/green-log"

OUT=$(cd "$REPO_ROOT" && TMPDIR="$SCRATCH/red-log" bash "$PRE_FIX" suite -- bash scripts/hooks/test-x/../../evil.sh 2>&1)
RC=$?
assert_rc "RED: traversal executes against pre-fix script" 127 "$RC"
assert_contains "RED: traversal exit=127 surfaced (i.e. it ran)" "exit=127" "$OUT"

# 2. GREEN: same shape against the FIXED script is refused before exec -
# rc=2, refusal line, and no log file created (proves it never reached exec).
OUT=$(cd "$REPO_ROOT" && TMPDIR="$SCRATCH/green-log" bash "$QUIET_RUN" suite -- bash scripts/hooks/test-x/../../evil.sh 2>&1)
RC=$?
assert_rc "GREEN: traversal refused by fixed script" 2 "$RC"
assert_contains "GREEN: refusal message" "refusing '..' path component" "$OUT"
if [ -n "$(ls -A "$SCRATCH/green-log" 2>/dev/null)" ]; then
    echo "FAIL GREEN: refused traversal must not create a log file"
    FAILED=$((FAILED + 1))
else
    echo "PASS GREEN: no log file created for refused traversal"
fi

# 3. A ".." element under a non-suite label is refused too - the guard
# applies to every label, not just suite.
OUT=$(cd "$REPO_ROOT" && bash "$QUIET_RUN" npm-install -- bash scripts/foo/../bar.sh 2>&1)
RC=$?
assert_rc "non-suite label with '..' component" 2 "$RC"
assert_contains "non-suite '..' refusal message" "refusing '..' path component" "$OUT"

# 4. A literal ".." inside a filename (not a path component) is not a
# traversal and must stay accepted.
OUT=$(cd "$REPO_ROOT" && bash "$QUIET_RUN" mylabel -- printf 'a..b' 2>&1)
RC=$?
assert_rc "'a..b' filename-shaped element accepted" 0 "$RC"

# 5. label "suite" with an untracked test-*.sh is refused (created under the
# repo tree, never git-added).
UNTRACKED_REL="scripts/hooks/test-untracked-quiet-run-2967-$$.sh"
UNTRACKED_ABS="$REPO_ROOT/$UNTRACKED_REL"
printf '#!/usr/bin/env bash\necho hi\n' > "$UNTRACKED_ABS"
OUT=$(cd "$REPO_ROOT" && bash "$QUIET_RUN" suite -- bash "$UNTRACKED_REL" 2>&1)
RC=$?
assert_rc "suite with untracked test-*.sh" 2 "$RC"
assert_contains "untracked suite refusal message" "requires a tracked test-*.sh" "$OUT"

# 6. label "suite" with a tracked test-*.sh passes.
OUT=$(cd "$REPO_ROOT" && bash "$QUIET_RUN" suite -- bash scripts/hooks/test-require-quiet-run.sh 2>&1)
RC=$?
assert_rc "suite with tracked test-*.sh" 0 "$RC"

# 7. label "suite" with `node --test <tracked file>` is unaffected - the
# tracked-file check applies only when argv is `bash <path> ...`; node
# suites stay on the classifier path exactly as before this change.
OUT=$(cd "$REPO_ROOT" && bash "$QUIET_RUN" suite -- node --test scripts/lanes/tests/plugin-profiles.test.mjs 2>&1)
RC=$?
assert_rc "suite with node --test <tracked file> unaffected" 0 "$RC"

# 8. Outside a git repo, the tracked-file check is skipped (does not break
# non-repo callers) but the '..' guard still applies.
NOTREPO="$SCRATCH/notrepo"
mkdir -p "$NOTREPO/scripts"
cp "$QUIET_RUN" "$NOTREPO/quiet-run.sh"
printf '#!/usr/bin/env bash\necho hi\n' > "$NOTREPO/scripts/test-x.sh"
OUT=$(cd "$NOTREPO" && bash quiet-run.sh suite -- bash scripts/test-x.sh 2>&1)
RC=$?
assert_rc "outside git repo: tracked check skipped" 0 "$RC"
assert_contains "outside git repo: skip note" "skipping tracked-file check" "$OUT"
OUT=$(cd "$NOTREPO" && bash quiet-run.sh suite -- bash scripts/../evil.sh 2>&1)
RC=$?
assert_rc "outside git repo: '..' still refused" 2 "$RC"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "All quiet-run.sh guard cases passed."
    exit 0
else
    echo "$FAILED case(s) failed."
    exit 1
fi
