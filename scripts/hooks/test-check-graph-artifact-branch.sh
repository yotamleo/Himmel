#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-graph-artifact-branch.sh (HIMMEL-2167).
# The hook reads the current branch + `git diff --cached` of the cwd, so each
# case stages fixtures in a throwaway git repo and runs the hook there,
# asserting the exit code.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/hooks/check-graph-artifact-branch.sh"
# shellcheck source=scripts/lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$ROOT/scripts/lib/fixture-tempdir.sh"
fails=0
ok() { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

# 1. Syntax.
if bash -n "$SCRIPT"; then ok "syntax (bash -n)"; else bad "syntax"; fi

# Fresh throwaway repo per run. Staging needs no identity/commit.
TMP="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" init -q
git -C "$TMP" symbolic-ref HEAD refs/heads/feat/some-feature
mkdir -p "$TMP/graphify-out"

# Run the hook in the repo (optionally with GRAPH_COMMIT_OK set), assert its
# exit code. $1 = expected rc, $2 = label, $3 = optional GRAPH_COMMIT_OK value.
expect() {
    local want="$1" label="$2" env_val="${3:-}" got
    got=$( cd "$TMP" && GRAPH_COMMIT_OK="$env_val" bash "$SCRIPT" >/dev/null 2>&1; echo $? )
    if [ "$got" = "$want" ]; then ok "$label"; else bad "$label (want rc=$want, got rc=$got)"; fi
}

# 2. Feature branch, no graph files staged -> 0 (allow, nothing to gate).
mkdir -p "$TMP/src" && echo 'export const x = 1' > "$TMP/src/foo.ts"
git -C "$TMP" add src/foo.ts
expect 0 "feature branch, no graph files staged -> 0"
git -C "$TMP" reset -q

# 3. Feature branch, graph.json staged -> blocked (deny).
echo '{}' > "$TMP/graphify-out/graph.json"
git -C "$TMP" add graphify-out/graph.json
expect 1 "feature branch staging graph.json -> blocked"

# 4. Feature branch, graph.json staged, GRAPH_COMMIT_OK=1 -> allow.
expect 0 "feature branch + GRAPH_COMMIT_OK=1 -> allow" "1"

# 5. chore/graph-publish-* branch, graph.json staged -> allow.
git -C "$TMP" symbolic-ref HEAD refs/heads/chore/graph-publish-20260827
expect 0 "chore/graph-publish-* branch staging graph.json -> allow"
git -C "$TMP" reset -q

# 6. Deletion-only: `files:` in pre-commit-config excludes deleted paths from
#    its match, so this hook must catch a deletion on its own (always_run).
#    Commit graph.json, branch off (real checkout -- HEAD now has a commit,
#    so index/working-tree must move with it, unlike the unborn-branch
#    symbolic-ref switches above), then `git rm` it -> blocked.
git -C "$TMP" add graphify-out/graph.json
git -C "$TMP" -c user.email=t@t -c user.name=t commit -q -m "seed graphify-out/graph.json"
git -C "$TMP" checkout -q -b feat/some-feature-2
git -C "$TMP" rm -q graphify-out/graph.json
expect 1 "feature branch, graph.json deletion staged -> blocked"

echo ""
if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed."; exit 1; fi
echo "all checks passed."
