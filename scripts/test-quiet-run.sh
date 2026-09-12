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

FAILED=0
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/test-quiet-run.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
UNTRACKED_ABS=""
GLOB_UNTRACKED_ABS=""
GLOB_CREATED=0
# shellcheck disable=SC2329,SC2317
cleanup() {
    rm -rf "$SCRATCH"
    [ -n "$UNTRACKED_ABS" ] && rm -f "$UNTRACKED_ABS"
    [ "$GLOB_CREATED" -eq 1 ] && rm -f "$GLOB_UNTRACKED_ABS"
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

# 1. RED control: the traversal shape against a SELF-CONTAINED pre-fix
# fixture (no argv path validation at all, matching the guard's absence
# before HIMMEL-2967) executes - proves the control can actually fail
# before asserting the fixed script blocks it. Self-contained rather than
# extracted from a historical commit (codex-1, round 4): a `git show
# <sha>:path` extraction depends on that object being reachable, which a
# shallow clone or squash-merged checkout may not have.
PRE_FIX="$SCRATCH/quiet-run-prefix.sh"
mkdir -p "$SCRATCH/red-log" "$SCRATCH/green-log"
cat > "$PRE_FIX" <<'PRE_FIX_EOF'
#!/usr/bin/env bash
set -euo pipefail
LABEL="$1"; shift
shift
LOG="${TMPDIR:-/tmp}/quiet-run-prefix-red.log"
if "$@" >>"$LOG" 2>&1; then
    echo "OK quiet-run $LABEL (log: $LOG)"
    exit 0
else
    RC=$?
    echo "ERR quiet-run $LABEL exit=$RC (log: $LOG)" >&2
    exit $RC
fi
PRE_FIX_EOF
chmod +x "$PRE_FIX"

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

# 6b. RED/GREEN: git ls-files pathspec-glob bypass (codex-1 finding, round 2).
# A literal argv path containing pathspec-glob metacharacters (e.g. a filename
# that is literally "test-*.sh") can satisfy a bare
# `git ls-files --error-unmatch -- "$SUITE_PATH"` by glob-matching some OTHER
# tracked test-*.sh file, even though the literal path bash actually executes
# is an untracked, attacker-controlled file. --literal-pathspecs disables the
# wildcard interpretation. RED runs against a SELF-CONTAINED fixture that
# reproduces the pre-this-fix tracked-file check (same logic, minus
# --literal-pathspecs) to prove the bypass is real; GREEN proves the fixed
# script refuses it. Self-contained rather than extracted from a historical
# commit (codex-1, round 4): a `git show <sha>:path` extraction depends on
# that object being reachable, which a shallow clone or squash-merged
# checkout may not have.
GLOB_VULN="$SCRATCH/quiet-run-globvuln.sh"
cat > "$GLOB_VULN" <<'GLOB_VULN_EOF'
#!/usr/bin/env bash
set -euo pipefail
LABEL="$1"; shift
shift
if [ "$LABEL" = "suite" ] && [ "${1:-}" = "bash" ]; then
    SUITE_PATH="${2:-}"
    BASENAME="${SUITE_PATH##*/}"
    case "$BASENAME" in
        test-*.sh) : ;;
        *)
            echo "ERR quiet-run: label 'suite' requires a tracked test-*.sh, got: $SUITE_PATH" >&2
            exit 2
            ;;
    esac
    if ! git ls-files --error-unmatch -- "$SUITE_PATH" >/dev/null 2>&1; then
        echo "ERR quiet-run: label 'suite' requires a tracked test-*.sh, got: $SUITE_PATH" >&2
        exit 2
    fi
fi
echo "OK quiet-run $LABEL"
exit 0
GLOB_VULN_EOF
chmod +x "$GLOB_VULN"

GLOB_UNTRACKED_REL="scripts/hooks/test-*.sh"
GLOB_UNTRACKED_ABS="$REPO_ROOT/$GLOB_UNTRACKED_REL"
if [ -e "$GLOB_UNTRACKED_ABS" ]; then
    echo "FAIL: $GLOB_UNTRACKED_ABS already exists - refusing to clobber a pre-existing file for this test" >&2
    FAILED=$((FAILED + 1))
elif ! printf '#!/usr/bin/env bash\necho hi\n' > "$GLOB_UNTRACKED_ABS" 2>/dev/null; then
    echo "SKIP: filesystem rejects a literal '*' in a filename (e.g. Windows/NTFS) - glob-pathspec bypass fixture not applicable here" >&2
else
    chmod +x "$GLOB_UNTRACKED_ABS"
    GLOB_CREATED=1

    OUT=$(cd "$REPO_ROOT" && bash "$GLOB_VULN" suite -- bash "$GLOB_UNTRACKED_REL" 2>&1)
    RC=$?
    assert_rc "RED: glob-pathspec bypass executes against pre-fix guard" 0 "$RC"

    OUT=$(cd "$REPO_ROOT" && bash "$QUIET_RUN" suite -- bash "$GLOB_UNTRACKED_REL" 2>&1)
    RC=$?
    assert_rc "GREEN: glob-pathspec bypass refused by --literal-pathspecs fix" 2 "$RC"
    assert_contains "GREEN: glob-pathspec refusal message" "requires a tracked test-*.sh" "$OUT"
fi

# 7. label "suite" with `node --test <tracked file>` is unaffected - the
# tracked-file check applies only when argv is `bash <path> ...`; node
# suites stay on the classifier path exactly as before this change.
OUT=$(cd "$REPO_ROOT" && bash "$QUIET_RUN" suite -- node --test scripts/lanes/tests/plugin-profiles.test.mjs 2>&1)
RC=$?
assert_rc "suite with node --test <tracked file> unaffected" 0 "$RC"

# 8. Outside a git repo, the tracked-file check is skipped (does not break
# non-repo callers) but the '..' guard still applies. GIT_CEILING_DIRECTORIES
# pins discovery to SCRATCH itself (codex-2, round 4): without it, a TMPDIR
# that happens to live inside a checkout lets git discover that ANCESTOR
# repo instead of finding none, so this case would fail despite quiet-run.sh
# behaving correctly.
NOTREPO="$SCRATCH/notrepo"
mkdir -p "$NOTREPO/scripts"
cp "$QUIET_RUN" "$NOTREPO/quiet-run.sh"
printf '#!/usr/bin/env bash\necho hi\n' > "$NOTREPO/scripts/test-x.sh"
OUT=$(cd "$NOTREPO" && GIT_CEILING_DIRECTORIES="$SCRATCH" bash quiet-run.sh suite -- bash scripts/test-x.sh 2>&1)
RC=$?
assert_rc "outside git repo: tracked check skipped" 0 "$RC"
assert_contains "outside git repo: skip note" "skipping tracked-file check" "$OUT"
OUT=$(cd "$NOTREPO" && GIT_CEILING_DIRECTORIES="$SCRATCH" bash quiet-run.sh suite -- bash scripts/../evil.sh 2>&1)
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
