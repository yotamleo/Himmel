#!/usr/bin/env bash
# scripts/hooks/check-new-shell-platform-guard.sh -- Guard B (HIMMEL-2682).
#
# Pre-commit gate for ws5's T15 x-platform invariant
# (scripts/parity/test-ws5-invariants.sh): three PRs in one night discovered
# a missing .ps1 twin / platform-guard marker only from a paid after-report
# or an in-guest VM run, after a paid cross-model gate row had already been
# spent at a head that then had to move. T15 runs in ~1s and needs no lane,
# VM or model call -- catching it here, for free, at commit time removes the
# wasted row entirely.
#
# Refuses a commit that ADDS any scripts/**/*.sh (staged index vs HEAD)
# whose first 60 lines carry neither a .ps1 twin nor a documented
# platform-guard marker. Predicate shared with T15 via
# scripts/lib/platform-guard.sh so the two cannot drift.
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Pure git + the shared predicate; no .ps1 twin needed.
#
# Fail-closed. A missing twin/marker is exactly the invisible, Windows-blind
# gap this gate exists to catch before it reaches a paid after-report or VM
# run, so an infrastructure error here (a repo-root resolution failure)
# refuses the commit rather than waving it through. Single-run bypass:
# NEW_SHELL_PLATFORM_GUARD_OK=1.
#
# Exit codes: 0 = clean (nothing added, or every addition passes), 1 = a new
# scripts/**/*.sh fails the predicate.
set -uo pipefail

if [ "${NEW_SHELL_PLATFORM_GUARD_OK:-0}" = 1 ]; then
    echo "check-new-shell-platform-guard: NEW_SHELL_PLATFORM_GUARD_OK=1 -- skipping (bypass used)" >&2
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Repo root is resolved from the CWD's git context (not SCRIPT_DIR) so this
# gate can be exercised in place against a throwaway fixture repo -- same
# pattern as check-doc-guard.sh / check-doctor-check-ids.sh.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$REPO_ROOT" ]; then
    echo "FAIL: check-new-shell-platform-guard: not inside a git repository" >&2
    exit 1
fi
cd "$REPO_ROOT" || { echo "FAIL: check-new-shell-platform-guard: cannot cd to repo root $REPO_ROOT" >&2; exit 1; }

# shellcheck source=scripts/lib/platform-guard.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/platform-guard.sh"

# `git diff`'s own failure is distinguished from "found nothing" (a CR
# finding, codex-2): the old form piped stderr to /dev/null and neutralized
# the whole pipeline with `|| true`, so a genuine git error (unreadable
# index, detached-HEAD oddity) silently read as "nothing added" -- a
# fail-OPEN hole in a gate that documents itself as fail-closed. Capture the
# command's own output/rc first; only a subsequent, separate `grep` on that
# already-known-good text is allowed to legitimately return "no match".
if ! diff_names="$(git diff --cached --diff-filter=A --name-only -- 'scripts/' 2>&1)"; then
    echo "FAIL: check-new-shell-platform-guard: git diff --cached failed: $diff_names" >&2
    exit 1
fi

# Staging area for the STAGED content of each candidate (codex-1): reading
# straight off the working tree let an untracked .ps1 sitting next to a
# markerless staged .sh satisfy the twin check without either safeguard
# actually being committed. Materialize what will actually land in the
# commit -- the staged .sh blob, and an empty placeholder for the twin only
# when the twin itself is present in the INDEX (staged or already
# committed) -- and run the shared predicate against that, never the disk.
stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/new-shell-platform-guard.XXXXXX")" || {
    echo "FAIL: check-new-shell-platform-guard: mktemp -d failed" >&2
    exit 1
}
trap 'rm -rf "$stage_dir"' EXIT

fail=0
n=0
while IFS= read -r sh_path; do
    [ -n "$sh_path" ] || continue
    n=$((n + 1))
    # Prefixed with $n: two staged paths can share a basename
    # (scripts/a/foo.sh, scripts/b/foo.sh), and this dir is flat.
    stage_sh="$stage_dir/$n-$(basename "$sh_path")"
    if ! git show ":$sh_path" > "$stage_sh" 2>/dev/null; then
        fail=1
        echo "⛔ check-new-shell-platform-guard: cannot read the staged content of $sh_path (fail-closed)." >&2
        continue
    fi
    twin="${sh_path%.sh}.ps1"
    if git cat-file -e ":$twin" 2>/dev/null; then
        : > "${stage_sh%.sh}.ps1"
    fi
    if platform_guard_ok "$stage_sh"; then
        continue
    fi
    fail=1
    echo "⛔ check-new-shell-platform-guard: $sh_path is a NEW shell script with neither a .ps1 twin nor a platform-guard marker." >&2
    echo "   Remedy: add a .ps1 twin, or mention 'platform guard' (or gitbash/git bash) in its first 60 lines." >&2
    echo "   Bypass (single run, leaves the script Windows-blind): NEW_SHELL_PLATFORM_GUARD_OK=1 git commit ..." >&2
done < <(printf '%s\n' "$diff_names" | grep -E '\.sh$' || true)

if [ "$fail" -ne 0 ]; then
    exit 1
fi
if [ "$n" -eq 0 ]; then
    exit 0
fi
echo "OK: check-new-shell-platform-guard: $n new scripts/**/*.sh, all carry a .ps1 twin or platform-guard marker."
exit 0
