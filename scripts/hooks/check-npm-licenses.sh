#!/usr/bin/env bash
# Pre-push hook: enforce production-dependency license allowlist.
# Enumerates EVERY committed package.json via `git ls-files` (tracked files
# only), so plugins under marketplace/ and plugins/ are covered too — not just
# the packages under scripts/. The node_modules pathspec exclude is defensive:
# `git ls-files` already omits untracked nested worktrees + dependency trees.
# Uses npx license-checker (downloaded on first run, cached afterwards).
set -euo pipefail

# Python-2.0 (the PSF License) is permissive + GPL-compatible; added when the
# broadened enumeration surfaced argparse@2.0.1 (transitive via js-yaml) in
# marketplace/plugins/obsidian-triage/tools (HIMMEL-179).
ALLOWED="MIT;ISC;BSD-2-Clause;BSD-3-Clause;Apache-2.0;CC0-1.0;Unlicense;0BSD;Python-2.0"

if ! pkgs_raw=$(git ls-files '*package.json' ':(exclude)*/node_modules/*'); then
    echo "ERROR: 'git ls-files' failed — cannot enumerate packages to license-check." >&2
    exit 1
fi
if [ -n "$pkgs_raw" ]; then
    mapfile -t pkgs <<<"$pkgs_raw"
else
    pkgs=()
fi

if [ ${#pkgs[@]} -eq 0 ]; then
    echo "→ license-checker: no committed package.json found — nothing to check"
    exit 0
fi

fail=0
for pkg in "${pkgs[@]}"; do
    dir=$(dirname "$pkg")
    # HIMMEL-523: skip bun-managed packages. A package with a bun lockfile
    # (bun.lock / bun.lockb) and NO package-lock.json is bun-managed (e.g.
    # scripts/luna-vitals — only a @types/bun devDep). For such a package
    # `npm install --omit=dev` installs nothing and `license-checker --production`
    # then errors "No packages found in this path", failing this always-run gate
    # on EVERY push (forcing SKIP=npm-licenses, which disables the check for ALL
    # packages). bun packages carry no npm production deps to license-check here
    # and are covered by the bun-suites CI; skip them. A package that ALSO has a
    # package-lock.json is treated as npm-managed (not skipped).
    if { [ -f "$dir/bun.lock" ] || [ -f "$dir/bun.lockb" ]; } && [ ! -f "$dir/package-lock.json" ]; then
        echo "→ license-checker: $dir is bun-managed (bun lockfile, no package-lock.json) — skipping npm license check (bun deps covered by bun-suites)"
        continue
    fi
    # Self-install prod deps when node_modules is missing (e.g. fresh worktree).
    # --ignore-scripts is critical: never execute third-party postinstall scripts in a pre-push gate.
    if [ ! -d "$dir/node_modules" ]; then
        if [ -f "$dir/package-lock.json" ]; then
            echo "→ license-checker: node_modules missing in $dir — running 'npm ci --omit=dev --ignore-scripts'"
            if ! (cd "$dir" && npm ci --omit=dev --ignore-scripts); then
                echo "ERROR: 'npm ci --omit=dev --ignore-scripts' failed in $dir — cannot license-check." >&2
                echo "       The install itself broke; fix it (e.g. lockfile drift, registry auth) before pushing." >&2
                fail=1
                continue
            fi
        else
            echo "→ license-checker: node_modules + package-lock.json missing in $dir — falling back to 'npm install --omit=dev --ignore-scripts'"
            if ! (cd "$dir" && npm install --omit=dev --ignore-scripts); then
                echo "ERROR: 'npm install --omit=dev --ignore-scripts' failed in $dir — cannot license-check." >&2
                echo "       The install itself broke; fix it before pushing." >&2
                fail=1
                continue
            fi
        fi
    fi
    echo "→ license-checker in $dir (allowed: $ALLOWED)"
    if ! (cd "$dir" && npx --yes license-checker --production --excludePrivatePackages --onlyAllow="$ALLOWED"); then
        fail=1
    fi
done

if [ $fail -ne 0 ]; then
    echo ""
    echo "ERROR: license check failed (see per-package output above)." >&2
    echo "       For an unknown license: remove the dep, or update the allowlist" >&2
    echo "       in scripts/hooks/check-npm-licenses.sh after confirming it is acceptable." >&2
fi

exit $fail
