#!/usr/bin/env bash
# scripts/hooks/check-new-shell-platform-guard.sh -- Guard B (HIMMEL-2682),
# downgraded to ADVISORY by HIMMEL-3125 (Windows -> alpha tier).
#
# Originally a pre-commit gate for ws5's T15 x-platform invariant
# (scripts/parity/test-ws5-invariants.sh, which still runs and still gates
# where it runs today -- HIMMEL-2642's propagation-snapshot rules are
# untouched by this change). That coupling is HISTORICAL, not the reason
# this file exists any more: with Windows now alpha (not CI-gated per-PR,
# best effort), a missing .ps1 twin is no longer a commit-blocking defect --
# it is a choice most new scripts should make, since nobody develops on
# Windows here. This gate now WARNS instead, so the signal survives (the
# comment below still names exactly which scripts are Windows-blind) without
# taxing every new script with a mandatory twin/marker.
#
# Reports (never refuses solely on the predicate) every ADDED scripts/**/*.sh
# (staged index vs HEAD) whose first 60 lines carry neither a .ps1 twin nor a
# documented platform-guard marker. Predicate shared with T15 via
# scripts/lib/platform-guard.sh so the two cannot drift -- T15 keeps its own
# (unchanged) pass/fail semantics; this hook only reports.
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Pure git + the shared predicate; no .ps1 twin needed.
#
# Still fails closed on an INFRASTRUCTURE error (a repo-root resolution
# failure, an unreadable staged blob, a mktemp failure) -- those mean the
# gate itself is broken, not that a script lacks a twin, and a broken gate
# should not silently report "all clear". Single-run bypass (now only
# relevant to suppress the advisory output): NEW_SHELL_PLATFORM_GUARD_OK=1.
#
# Exit codes: 0 = ran (nothing added, every addition passes, or a violation
# was only WARNED about), 1 = an infrastructure error, not a policy miss.
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
    warned=1
    echo "⚠️  check-new-shell-platform-guard (advisory): $sh_path is a NEW shell script with neither a .ps1 twin nor a platform-guard marker." >&2
    echo "   Windows is alpha -- this no longer blocks the commit. Add a .ps1 twin (or mention 'platform guard' / gitbash / git bash in its first 60 lines) only if you're actually working the Windows path." >&2
done < <(printf '%s\n' "$diff_names" | grep -E '\.sh$' || true)

# `fail` here means an INFRASTRUCTURE error (unreadable staged blob) -- that
# still refuses the commit. A missing twin/marker (`warned`) does not.
if [ "$fail" -ne 0 ]; then
    exit 1
fi
if [ "$n" -eq 0 ]; then
    exit 0
fi
if [ "${warned:-0}" -ne 0 ]; then
    echo "OK (advisory): check-new-shell-platform-guard: $n new scripts/**/*.sh, some without a .ps1 twin or platform-guard marker -- not blocking (Windows is alpha)."
else
    echo "OK: check-new-shell-platform-guard: $n new scripts/**/*.sh, all carry a .ps1 twin or platform-guard marker."
fi
exit 0
