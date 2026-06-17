#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-artifact-leakage.sh (HIMMEL-371).
# The hook reads `git diff --cached` of the cwd, so each case stages fixtures in
# a throwaway git repo and runs the hook there, asserting the exit code.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/hooks/check-artifact-leakage.sh"
fails=0
ok() { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

# 1. Syntax.
if bash -n "$SCRIPT"; then ok "syntax (bash -n)"; else bad "syntax"; fi

# Fresh throwaway repo per run. Staging needs no identity/commit; the modify
# case below sets identity inline.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" init -q

# Stage the already-set-up fixtures, run the hook in the repo, assert its exit
# code, then unstage. $1 = expected rc, $2 = label.
expect() {
    local want="$1" label="$2" got
    got=$( cd "$TMP" && bash "$SCRIPT" >/dev/null 2>&1; echo $? )
    if [ "$got" = "$want" ]; then ok "$label"; else bad "$label (want rc=$want, got rc=$got)"; fi
    git -C "$TMP" reset -q
}

# 2. Nothing staged -> exit 0.
expect 0 "empty staged set -> 0"

# 3. A normal new source file -> exit 0.
mkdir -p "$TMP/src" && echo 'export const x = 1' > "$TMP/src/foo.ts"
git -C "$TMP" add src/foo.ts
expect 0 "normal new file -> 0"

# 4. node_modules/ -> blocked (force-add, since real gitignore would skip it).
mkdir -p "$TMP/node_modules/pkg" && echo '{}' > "$TMP/node_modules/pkg/package.json"
git -C "$TMP" add -f node_modules/pkg/package.json
expect 1 "node_modules -> blocked"

# 5. OS junk -> blocked.
echo junk > "$TMP/.DS_Store"
git -C "$TMP" add -f .DS_Store
expect 1 ".DS_Store -> blocked"

# 6. *.tsbuildinfo -> blocked.
echo '{}' > "$TMP/tsconfig.tsbuildinfo"
git -C "$TMP" add -f tsconfig.tsbuildinfo
expect 1 "*.tsbuildinfo -> blocked"

# 7. Wrong-PM lockfile: package-lock.json in a dir WITH bun.lock -> blocked.
mkdir -p "$TMP/bunpkg" && echo '{}' > "$TMP/bunpkg/bun.lock" && echo '{}' > "$TMP/bunpkg/package-lock.json"
git -C "$TMP" add -f bunpkg/package-lock.json
expect 1 "package-lock.json next to bun.lock -> blocked"

# 8. Legit npm: package-lock.json in a dir WITHOUT bun.lock -> exit 0.
mkdir -p "$TMP/npmpkg" && echo '{}' > "$TMP/npmpkg/package-lock.json"
git -C "$TMP" add npmpkg/package-lock.json
expect 0 "package-lock.json without bun.lock -> 0 (legit npm)"

# 8a/8b. The wrong-PM arm is shared across three lockfile names — pin yarn.lock
#        and pnpm-lock.yaml too, so narrowing/mistyping the glob can't ship green.
mkdir -p "$TMP/bunpkg2" && echo '{}' > "$TMP/bunpkg2/bun.lock"
echo '{}' > "$TMP/bunpkg2/yarn.lock"
git -C "$TMP" add -f bunpkg2/yarn.lock
expect 1 "yarn.lock next to bun.lock -> blocked"
echo '{}' > "$TMP/bunpkg2/pnpm-lock.yaml"
git -C "$TMP" add -f bunpkg2/pnpm-lock.yaml
expect 1 "pnpm-lock.yaml next to bun.lock -> blocked"

# 8c. The alternate bun marker (binary bun.lockb) also triggers the wrong-PM arm.
mkdir -p "$TMP/bunpkg3" && echo 'bin' > "$TMP/bunpkg3/bun.lockb"
echo '{}' > "$TMP/bunpkg3/package-lock.json"
git -C "$TMP" add -f bunpkg3/package-lock.json
expect 1 "package-lock.json next to bun.lockb -> blocked"

# 8d. OS-junk other arm: Thumbs.db (the Windows half of the .DS_Store|Thumbs.db arm).
echo junk > "$TMP/Thumbs.db"
git -C "$TMP" add -f Thumbs.db
expect 1 "Thumbs.db -> blocked"

# 8e. NUL-safe parsing: a path containing a space must still be caught (the hook
#     reads `git diff -z` via `read -r -d ''` precisely for this).
mkdir -p "$TMP/node_modules/scoped pkg"
echo '{}' > "$TMP/node_modules/scoped pkg/package.json"
git -C "$TMP" add -f "node_modules/scoped pkg/package.json"
expect 1 "node_modules path with a space -> blocked (NUL-safe read)"

# 9. Only MODIFYING an already-tracked artifact-named file is not leakage
#    (the hook only inspects NEW adds, diff-filter=A). Commit one, then modify.
echo first > "$TMP/legacy.tsbuildinfo"
git -C "$TMP" add -f legacy.tsbuildinfo
git -C "$TMP" -c user.email=t@t -c user.name=t commit -q -m "legacy artifact (pre-existing)"
echo second > "$TMP/legacy.tsbuildinfo"
git -C "$TMP" add legacy.tsbuildinfo
expect 0 "modifying a pre-tracked artifact -> 0 (only NEW adds blocked)"

echo ""
if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed."; exit 1; fi
echo "all checks passed."
