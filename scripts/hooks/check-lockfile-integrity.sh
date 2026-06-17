#!/usr/bin/env bash
# Pre-commit hook: enforce lockfile integrity (npm + bun).
#
# For every package.json under scripts/ (same scoping as check-npm-audit.sh):
#   1. A sibling package-lock.json (npm) or bun.lock (bun) must exist.
#   2. That lockfile must be tracked in git.
#   3. Package manager ci/install verification succeeds (catches lock drift).
#
# Blocks the commit on any failure. See docs/security/npm-policy.md.
set -euo pipefail

# Scoped to scripts/ so we don't recurse into nested worktrees under .claude/.
mapfile -t pkgs < <(find scripts -maxdepth 3 -name package.json -not -path '*/node_modules/*')

if [ ${#pkgs[@]} -eq 0 ]; then
    echo "→ lockfile-integrity: no npm/bun projects under scripts/, skipping"
    exit 0
fi

fail=0
for pkg in "${pkgs[@]}"; do
    dir=$(dirname "$pkg")

    # Determine lockfile type (bun.lock takes precedence). Warn if both are
    # present so a stray package-lock.json during an npm→bun migration can't
    # silently drop npm validation without anyone noticing.
    if [ -f "$dir/bun.lock" ]; then
        lock="$dir/bun.lock"
        pm="bun"
        if [ -f "$dir/package-lock.json" ]; then
            echo "→ lockfile-integrity: WARNING: both bun.lock and package-lock.json in $dir — using bun.lock" >&2
        fi
    else
        lock="$dir/package-lock.json"
        pm="npm"
    fi

    if [ ! -f "$lock" ]; then
        echo "ERROR: missing lockfile: $lock" >&2
        echo "       Every package.json must ship a committed sibling package-lock.json (npm) or bun.lock (bun)." >&2
        fail=1
        continue
    fi

    if ! git ls-files --error-unmatch "$lock" >/dev/null 2>&1; then
        echo "ERROR: lockfile not tracked in git: $lock" >&2
        echo "       Run: git add $lock" >&2
        fail=1
        continue
    fi

    if [ "$pm" = "npm" ]; then
        echo "→ lockfile-integrity: npm ci --dry-run in $dir"
        if ! (cd "$dir" && npm ci --dry-run --ignore-scripts); then
            echo "ERROR: lockfile drift detected in $dir" >&2
            echo "       package-lock.json is out of sync with package.json." >&2
            echo "       Run 'npm install' in $dir, then commit the updated lockfile." >&2
            fail=1
        fi
    else
        # bun: --frozen-lockfile errors if the lockfile is out of sync with
        # package.json; --dry-run resolves without installing. This is the bun
        # analogue of `npm ci --dry-run` — same drift-detection guarantee.
        echo "→ lockfile-integrity: bun install --frozen-lockfile --dry-run in $dir"
        if ! (cd "$dir" && bun install --frozen-lockfile --dry-run); then
            echo "ERROR: lockfile drift detected in $dir" >&2
            echo "       bun.lock is out of sync with package.json." >&2
            echo "       Run 'bun install' in $dir, then commit the updated bun.lock." >&2
            fail=1
        fi
    fi
done

if [ $fail -ne 0 ]; then
    echo "" >&2
    echo "ERROR: lockfile-integrity check failed. Commit blocked." >&2
fi

exit $fail
