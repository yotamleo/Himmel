#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-new-shell-platform-guard.sh (HIMMEL-2682).
#
# Builds throwaway git repos, stages a newly-added scripts/**/*.sh in each,
# exercises each rc case, asserts exact rc. Modeled on test-doc-guard.sh:
# only the git repo is a tempdir -- the checked script runs IN PLACE from
# the real tree (it sources scripts/lib/platform-guard.sh via its own
# SCRIPT_DIR, and resolves the repo-to-check via `git rev-parse
# --show-toplevel`, which is CWD-relative).
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
#
# Usage: bash scripts/hooks/test-check-new-shell-platform-guard.sh
# Exit 0 if all cases pass, 1 otherwise.
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HOOKS/check-new-shell-platform-guard.sh"
REPO_ROOT="$(cd "$HOOKS/../.." && pwd)"

# shellcheck source=scripts/lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$HOOKS/../lib/fixture-tempdir.sh"

# setup_repo: temp git repo with an initial commit (so `git diff --cached`
# has a HEAD to diff against).
setup_repo() {
    R=$(fixture_mktemp_dir) || return 1
    git -C "$R" init -q
    git -C "$R" config user.email t@t
    git -C "$R" config user.name t
    git -C "$R" commit -q --allow-empty -m init
}

_failures=0

run_case() {
    local name="$1" want="$2" rc=0
    ( cd "$R" && bash "$SCRIPT" >/dev/null 2>&1 )
    rc=$?
    if [ "$rc" -eq "$want" ]; then
        printf '  PASS  %s (rc=%s)\n' "$name" "$rc"
    else
        printf '  FAIL  %s -- expected rc=%s, got rc=%s\n' "$name" "$want" "$rc"
        _failures=$((_failures + 1))
    fi
}

# A1 RED control -- a staged new scripts/x/foo.sh with no header -> refused.
setup_repo
mkdir -p "$R/scripts/x"
printf '#!/usr/bin/env bash\necho hi\n' > "$R/scripts/x/foo.sh"
git -C "$R" add scripts/x/foo.sh
run_case "A1 new .sh with no twin/marker -> refused" 1

# A2 -- the same file, now carrying the marker in its first 60 lines -> passes.
setup_repo
mkdir -p "$R/scripts/x"
printf '#!/usr/bin/env bash\n# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.\necho hi\n' > "$R/scripts/x/foo.sh"
git -C "$R" add scripts/x/foo.sh
run_case "A2 new .sh with platform-guard marker -> passes" 0

# A3 -- the same file, now with a .ps1 twin instead -> passes.
setup_repo
mkdir -p "$R/scripts/x"
printf '#!/usr/bin/env bash\necho hi\n' > "$R/scripts/x/foo.sh"
printf 'Write-Host "hi"\n' > "$R/scripts/x/foo.ps1"
git -C "$R" add scripts/x/foo.sh scripts/x/foo.ps1
run_case "A3 new .sh with .ps1 twin -> passes" 0

# A3b RED control -- an UNTRACKED .ps1 sitting next to a markerless staged
# .sh must NOT satisfy the twin check (codex-1): the gate validates the
# STAGED index, not the working tree, so this stays refused.
setup_repo
mkdir -p "$R/scripts/x"
printf '#!/usr/bin/env bash\necho hi\n' > "$R/scripts/x/foo.sh"
git -C "$R" add scripts/x/foo.sh
printf 'Write-Host "hi"\n' > "$R/scripts/x/foo.ps1"
run_case "A3b untracked .ps1 twin (not staged) -> still refused" 1

# A4 -- nothing staged under scripts/**/*.sh -> vacuous pass.
setup_repo
: > "$R/README.md"
git -C "$R" add README.md
run_case "A4 no new scripts/**/*.sh staged -> vacuous pass" 0

# A5 -- an EXISTING (already-committed) scripts/**/*.sh with no marker is
# NOT flagged -- only ADDED files (--diff-filter=A) are in scope.
setup_repo
mkdir -p "$R/scripts/x"
printf '#!/usr/bin/env bash\necho hi\n' > "$R/scripts/x/foo.sh"
git -C "$R" add scripts/x/foo.sh
git -C "$R" commit -q -m "add foo.sh"
printf '#!/usr/bin/env bash\necho hi again\n' > "$R/scripts/x/foo.sh"
git -C "$R" add scripts/x/foo.sh
run_case "A5 modified (not added) .sh with no marker -> not flagged" 0

# A6 -- NEW_SHELL_PLATFORM_GUARD_OK=1 bypasses an otherwise-refused violation.
setup_repo
mkdir -p "$R/scripts/x"
printf '#!/usr/bin/env bash\necho hi\n' > "$R/scripts/x/foo.sh"
git -C "$R" add scripts/x/foo.sh
( cd "$R" && NEW_SHELL_PLATFORM_GUARD_OK=1 bash "$SCRIPT" >/dev/null 2>&1 )
rc=$?
if [ "$rc" -eq 0 ]; then
    printf '  PASS  %s (rc=%s)\n' "A6 NEW_SHELL_PLATFORM_GUARD_OK=1 bypasses a refused fixture" "$rc"
else
    printf '  FAIL  %s -- expected rc=0, got rc=%s\n' "A6 NEW_SHELL_PLATFORM_GUARD_OK=1 bypasses a refused fixture" "$rc"
    _failures=$((_failures + 1))
fi

# B1 -- the real ws5-invariants T15 predicate on this checkout still passes,
# via the SHARED platform_guard_ok predicate this change points it at.
t15_out="$(cd "$REPO_ROOT" && bash scripts/parity/test-ws5-invariants.sh 2>&1)"
rc=$?
# Captured into a variable rather than piped into `grep -q` (HIMMEL-1430):
# this file runs under `set -o pipefail`, where grep -q exits at its first
# match and the producer's SIGPIPE can flip the pipeline's status.
# Require the PASS line specifically (codex-6): a bare 'T15 x-platform'
# match would also accept a SKIP line (propagation-snapshot mode), which
# would report "still passes" even though T15 never actually ran.
t15_match="$(printf '%s' "$t15_out" | grep -E '^PASS T15 x-platform' || true)"
if [ "$rc" -eq 0 ] && [ -n "$t15_match" ]; then
    printf '  PASS  %s (rc=%s)\n' "B1 ws5 T15 on this checkout -> still passes" "$rc"
else
    printf '  FAIL  %s -- expected rc=0 with a T15 line, got rc=%s\n' "B1 ws5 T15 on this checkout -> still passes" "$rc"
    _failures=$((_failures + 1))
fi

if [ "$_failures" -eq 0 ]; then
    echo "PASS: test-check-new-shell-platform-guard.sh (all cases)"
    exit 0
fi
echo "FAIL: test-check-new-shell-platform-guard.sh ($_failures case(s) failed)"
exit 1
