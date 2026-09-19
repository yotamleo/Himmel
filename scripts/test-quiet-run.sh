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

# 9. A broken/invalid git repository pointer (codex-1, round 6) must fail
# closed, not be treated as "no repo, skip the check" - git's diagnostic for
# an invalid gitdir also contains the substring "not a git repository", but
# with a different, more specific shape ("not a git repository: <path>")
# than genuine absence ("not a git repository (or any parent/of the parent
# directories)"). A caller with corrupted git metadata must not be able to
# smuggle an untracked suite past the tracked-file check.
BROKENGIT="$SCRATCH/brokengit"
mkdir -p "$BROKENGIT/scripts"
cp "$QUIET_RUN" "$BROKENGIT/quiet-run.sh"
printf '#!/usr/bin/env bash\necho hi\n' > "$BROKENGIT/scripts/test-x.sh"
OUT=$(cd "$BROKENGIT" && GIT_DIR="$SCRATCH/does-not-exist" bash quiet-run.sh suite -- bash scripts/test-x.sh 2>&1)
RC=$?
assert_rc "broken GIT_DIR: fails closed, not skipped" 2 "$RC"
assert_contains "broken GIT_DIR: unexpected-failure message" "failed unexpectedly" "$OUT"

# 10. Directory-pathspec bypass (codex-1, round 7): `git ls-files -- <path>`
# matches a pathspec against index entries by directory-prefix too, not just
# exact file paths. If the tracked history once held a directory literally
# named like a test-*.sh file (e.g. "test-x.sh/inner.sh" tracked), an
# attacker who replaces that directory in the working tree with an untracked
# plain file of the same name could pass the old --error-unmatch check
# (prefix match still succeeds) while the file bash actually executes is
# untracked. Requiring the ls-files output to equal SUITE_PATH exactly closes
# this. Built as a throwaway nested repo, not the real himmel history.
DIRBYPASS="$SCRATCH/dirbypass"
mkdir -p "$DIRBYPASS"
git -C "$DIRBYPASS" init -q
git -C "$DIRBYPASS" config user.email test@example.com
git -C "$DIRBYPASS" config user.name test
mkdir -p "$DIRBYPASS/test-x.sh"
printf 'tracked\n' > "$DIRBYPASS/test-x.sh/inner.sh"
git -C "$DIRBYPASS" add test-x.sh/inner.sh
git -C "$DIRBYPASS" commit -q -m "tracked dir named like a test-*.sh file"
rm -rf "${DIRBYPASS:?}/test-x.sh"
printf '#!/usr/bin/env bash\necho pwned\n' > "$DIRBYPASS/test-x.sh"
chmod +x "$DIRBYPASS/test-x.sh"
cp "$QUIET_RUN" "$DIRBYPASS/quiet-run.sh"
OUT=$(cd "$DIRBYPASS" && bash quiet-run.sh suite -- bash test-x.sh 2>&1)
RC=$?
assert_rc "directory-pathspec bypass refused" 2 "$RC"
assert_contains "directory-pathspec bypass refusal message" "requires a tracked test-*.sh" "$OUT"

# 11. label "suite" with a `./`-prefixed path to a tracked test-*.sh must
# still pass - the same file that passes as a bare repo-relative path
# (case 6) is illegitimately refused today because the tracked-file check
# requires `git ls-files` output to equal SUITE_PATH byte-for-byte, and
# ls-files normalizes away a leading "./" (HIMMEL-2970).
OUT=$(cd "$REPO_ROOT" && bash "$QUIET_RUN" suite -- bash ./scripts/hooks/test-require-quiet-run.sh 2>&1)
RC=$?
assert_rc "suite with tracked test-*.sh via ./-prefixed path" 0 "$RC"

# 12. label "suite" with an absolute path (resolving under the repo root) to
# the same tracked test-*.sh must also pass - ls-files output is always
# repo-relative, so an absolute SUITE_PATH can never equal it under the
# current exact-match check (HIMMEL-2970).
ABS_TRACKED="$REPO_ROOT/scripts/hooks/test-require-quiet-run.sh"
OUT=$(cd "$REPO_ROOT" && bash "$QUIET_RUN" suite -- bash "$ABS_TRACKED" 2>&1)
RC=$?
assert_rc "suite with tracked test-*.sh via absolute path" 0 "$RC"

# 13. label "suite" with an absolute path, invoked from a repo SUBDIRECTORY
# cwd, must also pass - stripping REPO_TOPLEVEL leaves a root-relative
# pathspec, and `git ls-files` resolves a pathspec relative to the current
# directory, not the repo root, so the lookup must be pinned to
# REPO_TOPLEVEL for this case (HIMMEL-2989).
OUT=$(cd "$REPO_ROOT/scripts/lanes" && bash "$QUIET_RUN" suite -- bash "$ABS_TRACKED" 2>&1)
RC=$?
assert_rc "suite with tracked test-*.sh via absolute path from a subdirectory cwd" 0 "$RC"

# 14. Git-Bash on Windows: `git rev-parse --show-toplevel` prints the MIXED
# form (D:/a/repo) while a caller's absolute path is POSIX (/a/repo). The
# guard must also strip the `cygpath -u` form of the toplevel, or a tracked
# suite is refused rc=2 (HIMMEL-3181). Emulated with a git stub that prefixes
# `D:` (and strips it back from `-C`) plus a cygpath stub; skipped on a real
# Windows host, where the native cases above already exercise the real forms.
case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
        echo "SKIP 14: real Windows host - native cases above cover the mixed toplevel form"
        ;;
    *)
        WINSTUB="$SCRATCH/winstub"
        mkdir -p "$WINSTUB"
        REAL_GIT=$(command -v git)
        cat > "$WINSTUB/git" <<GITSTUB
#!/bin/sh
REAL="$REAL_GIT"
if [ "\$1" = "-C" ]; then
  d="\${2#D:}"; shift 2
  exec "\$REAL" -C "\$d" "\$@"
fi
if [ "\$1" = "rev-parse" ] && [ "\$2" = "--show-toplevel" ]; then
  out=\$("\$REAL" rev-parse --show-toplevel) || exit \$?
  printf 'D:%s\n' "\$out"
  exit 0
fi
exec "\$REAL" "\$@"
GITSTUB
        cat > "$WINSTUB/cygpath" <<'CYGSTUB'
#!/bin/sh
case "$1" in
  -u) printf '%s\n' "${2#D:}" ;;
  *)  printf '%s\n' "$2" ;;
esac
CYGSTUB
        chmod +x "$WINSTUB/git" "$WINSTUB/cygpath"
        # RED control: same emulation with cygpath absent (the pre-fix shape:
        # nothing converts the D:/ toplevel back to POSIX) must still refuse.
        mkdir -p "$SCRATCH/winstub-nocyg"
        cp "$WINSTUB/git" "$SCRATCH/winstub-nocyg/git"
        OUT=$(cd "$REPO_ROOT" && PATH="$SCRATCH/winstub-nocyg:$PATH" bash "$QUIET_RUN" suite -- bash "$ABS_TRACKED" 2>&1)
        RC=$?
        assert_rc "RED: D:/-form toplevel without a cygpath conversion is refused" 2 "$RC"
        OUT=$(cd "$REPO_ROOT" && PATH="$WINSTUB:$PATH" bash "$QUIET_RUN" suite -- bash "$ABS_TRACKED" 2>&1)
        RC=$?
        assert_rc "suite with tracked test-*.sh via POSIX path under a D:/-form toplevel" 0 "$RC"
        ;;
esac

# 15. Killing quiet-run.sh must reap the command it wraps, grandchildren
# included - a TERM/INT/HUP to the wrapper used to leave the whole suite
# running with no owning session (HIMMEL-2221). The wrapped command spawns a
# long sleep and records its pid; after the signal that pid must be gone.
for SIG in TERM INT HUP; do
    PIDFILE="$SCRATCH/reap-$SIG.pid"
    rm -f "$PIDFILE"
    # A non-interactive `&` starts its child with INT ignored (and an ignored
    # signal cannot be trapped); job control gives it the default disposition.
    set -m
    (
        TMPDIR="$SCRATCH" exec bash "$QUIET_RUN" reap-$SIG -- \
            bash -c 'sleep 300 & echo $! > "$1"; wait' _ "$PIDFILE" >/dev/null 2>&1
    ) &
    QR_PID=$!
    set +m
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        [ -s "$PIDFILE" ] && break
        sleep 0.25
    done
    GRANDCHILD=$(cat "$PIDFILE" 2>/dev/null)
    if [ -z "$GRANDCHILD" ]; then
        echo "FAIL reap $SIG - wrapped command never recorded its grandchild pid"
        FAILED=$((FAILED + 1))
        kill -KILL "$QR_PID" 2>/dev/null
        continue
    fi
    kill -"$SIG" "$QR_PID" 2>/dev/null
    # Bounded: an unreaped wrapper (the pre-fix shape) sits out its child.
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        kill -0 "$QR_PID" 2>/dev/null || break
        sleep 0.25
    done
    kill -KILL "$QR_PID" 2>/dev/null
    wait "$QR_PID" 2>/dev/null
    GONE=0
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        if ! kill -0 "$GRANDCHILD" 2>/dev/null; then GONE=1; break; fi
        sleep 0.25
    done
    if [ "$GONE" -eq 1 ]; then
        echo "PASS reap $SIG - grandchild $GRANDCHILD gone after the wrapper was signalled"
    else
        echo "FAIL reap $SIG - grandchild $GRANDCHILD still running after the wrapper was signalled"
        FAILED=$((FAILED + 1))
        kill -KILL "$GRANDCHILD" 2>/dev/null
    fi
done

# 16. Running the command as its own process group must not cost it stdin: a
# suite that reads stdin still gets the caller's bytes and exits with its own
# rc. The control is the naive shape (a bare `&` with job control off), which
# hands the command /dev/null - it must read nothing, proving this case can
# fail.
NAIVE="$SCRATCH/quiet-run-naive-bg.sh"
cat > "$NAIVE" <<'NAIVE_EOF'
#!/usr/bin/env bash
shift; shift
"$@" >"$TMPDIR/naive.log" 2>&1 &
wait $!
NAIVE_EOF
mkdir -p "$SCRATCH/stdin-log"
printf 'stdin-payload\n' | TMPDIR="$SCRATCH/stdin-log" bash "$NAIVE" x -- bash -c 'cat; exit 3'
if grep -q 'stdin-payload' "$SCRATCH/stdin-log/naive.log"; then
    echo "FAIL RED: a bare-& wrapper was expected to lose stdin"
    FAILED=$((FAILED + 1))
else
    echo "PASS RED: a bare-& wrapper loses stdin (control can fail)"
fi
OUT=$(printf 'stdin-payload\n' | TMPDIR="$SCRATCH/stdin-log" bash "$QUIET_RUN" stdin -- bash -c 'cat; exit 3' 2>&1)
RC=$?
assert_rc "command's own rc survives the process-group wrapper" 3 "$RC"
LOGFILE=""
for f in "$SCRATCH"/stdin-log/quiet-run-stdin-*.log; do
    [ -f "$f" ] && { LOGFILE="$f"; break; }
done
if [ -n "$LOGFILE" ] && grep -q 'stdin-payload' "$LOGFILE"; then
    echo "PASS command reads the caller's stdin through quiet-run"
else
    echo "FAIL command did not receive the caller's stdin through quiet-run"
    FAILED=$((FAILED + 1))
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "All quiet-run.sh guard cases passed."
    exit 0
else
    echo "$FAILED case(s) failed."
    exit 1
fi
