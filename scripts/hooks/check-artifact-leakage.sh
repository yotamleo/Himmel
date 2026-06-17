#!/usr/bin/env bash
# Pre-commit hook: block stray generated artifacts from being committed
# (HIMMEL-371).
#
# Why: himmel runs concurrent sessions sharing one repo tree, and build/test
# steps (sometimes the wrong package manager) drop untracked artifacts. A
# blanket `git add -A` then sweeps them into a commit — on HIMMEL-366 an npm
# `package-lock.json` landed in the bun package scripts/luna-vitals/ and rode
# into a commit, caught only by reading `git show --stat` after the fact.
#
# The hardened .gitignore is the primary defense (it makes `git add -A` safe
# for the generated-artifact class). This hook is the defense-in-depth
# backstop for what .gitignore can't catch generically: a force-added artifact,
# or the wrong-PM lockfile case — a package-lock.json can't be globally ignored
# because 6 legit npm packages track theirs, so it's only leakage when it sits
# next to a bun.lock (i.e. the dir is a bun package).
#
# Only NEWLY-ADDED files (git status A) are checked — modifying an
# already-tracked file is never leakage. Fail-closed: a match blocks the commit.
# NOT a universal "any file" guard (a hook can't know intent); it covers the
# generated-artifact class only — arbitrary hand-written leakage stays staging
# discipline. bash 3.2-safe (no mapfile/associative arrays).
set -euo pipefail

# Newly-added staged paths (NUL-safe for paths with spaces).
bad=""
while IFS= read -r -d '' f; do
    base=$(basename "$f")
    dir=$(dirname "$f")

    case "$f" in
        node_modules/*|*/node_modules/*)
            bad="${bad}  $f  [node_modules — never commit]"$'\n'; continue ;;
    esac
    case "$base" in
        .DS_Store|Thumbs.db)
            bad="${bad}  $f  [OS junk — never commit]"$'\n'; continue ;;
        *.tsbuildinfo)
            bad="${bad}  $f  [TS build artifact — never commit]"$'\n'; continue ;;
    esac
    # Wrong-package-manager lockfile: an npm/yarn/pnpm lock staged inside a dir
    # that already has a bun lockfile (so the dir is a bun package).
    case "$base" in
        package-lock.json|yarn.lock|pnpm-lock.yaml)
            if [ -f "$dir/bun.lock" ] || [ -f "$dir/bun.lockb" ]; then
                bad="${bad}  $f  [wrong-PM lockfile next to bun.lock — $dir is a bun package]"$'\n'
                continue
            fi ;;
    esac
done < <(git diff --cached --name-only --diff-filter=A -z)

if [ -n "$bad" ]; then
    echo "ERROR: artifact-leakage — these staged NEW files look like stray/generated artifacts:" >&2
    printf '%s' "$bad" >&2
    echo "" >&2
    echo "If a concurrent session or build step dropped these, unstage them:" >&2
    echo "  git restore --staged <file>" >&2
    echo "If one is genuinely intended, stage it explicitly (use 'git add -f' if ignored) and re-commit." >&2
    echo "" >&2
    echo "Commit blocked." >&2
    exit 1
fi
exit 0
