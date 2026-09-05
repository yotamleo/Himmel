#!/usr/bin/env bash
# Smoke test for scripts/cr/doc-freshness-advisory.sh (HIMMEL-2226).
#
# Builds a throwaway fixture git repo under mktemp (never the real repo, never
# the network) that doubles as the script's own HIMMEL_ROOT: it holds a copy
# of doc-freshness-advisory.sh plus the real scripts/guardrails/lib.sh and
# scripts/lib/{load-dotenv,doc-freshness,doc-guard-map,commit-class}.sh, so
# the script's SCRIPT_DIR-relative sourcing resolves inside the fixture. The
# script is always run with CWD = the fixture repo, since default_branch()
# and df_detect() resolve against the process CWD, not HIMMEL_ROOT.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/doc-freshness-advisory.sh"
LIBDIR="$DIR/../lib"
GUARDDIR="$DIR/../guardrails"

pass=0
fail=0
check() {
    # $1 = got  $2 = want  $3 = label
    if [ "$1" = "$2" ]; then
        pass=$((pass + 1))
        echo "PASS: $3"
    else
        fail=$((fail + 1))
        echo "FAIL: $3 -- got '$1' want '$2'"
    fi
}

tmp="$(mktemp -d -t test-doc-freshness-advisory.XXXXXX)"; trap 'rm -rf "$tmp"' EXIT

# --- fixture_repo: full script tree + a real git history with a mapped-doc
# drift on one branch and no drift on another. ---------------------------
repo="$tmp/fixture_repo"
mkdir -p "$repo/scripts/cr" "$repo/scripts/guardrails" "$repo/scripts/lib" "$repo/scripts/hooks" "$repo/docs" "$repo/src"
cp "$SCRIPT" "$repo/scripts/cr/doc-freshness-advisory.sh"
cp "$GUARDDIR/lib.sh" "$repo/scripts/guardrails/lib.sh"
cp "$LIBDIR/load-dotenv.sh" "$repo/scripts/lib/load-dotenv.sh"
cp "$LIBDIR/doc-freshness.sh" "$repo/scripts/lib/doc-freshness.sh"
cp "$LIBDIR/doc-guard-map.sh" "$repo/scripts/lib/doc-guard-map.sh"
cp "$LIBDIR/commit-class.sh" "$repo/scripts/lib/commit-class.sh"
printf 'advise\tmodify\t^src/thing\\.txt$\tdocs/thing.md\n' >"$repo/scripts/hooks/doc-guard-map.tsv"
printf 'Doc v1\n' >"$repo/docs/thing.md"
printf 'v1\n' >"$repo/src/thing.txt"

(
    cd "$repo" || exit 1
    git init -q -b main .
    git config user.email t@t
    git config user.name t
    git config commit.gpgsign false
    git add -A
    git commit -q -m "chore: init fixture"

    git checkout -q -b feature
    printf 'v2\n' >src/thing.txt
    git add -A
    git commit -q -m "feat: change thing"

    git checkout -q main
    git checkout -q -b feature-nodrift
    printf 'other v2\n' >src/other.txt
    git add -A
    git commit -q -m "feat: change other"
)

# 1. Leg inactive (HIMMEL_DOC_FRESHNESS unset) -> no drift output at all,
# even on a branch that WOULD show drift if the leg were on.
out1="$(cd "$repo" && git checkout -q feature && env -u HIMMEL_DOC_FRESHNESS bash scripts/cr/doc-freshness-advisory.sh)"
rc1=$?
check "$out1" "" "T1 leg inactive: no output"
check "$rc1" "0" "T1 leg inactive: exit 0"

# 2. Leg active with drift -> the drift lines are printed AND exit is still 0.
want2='Doc-freshness (advisory) - mapped sources changed without their docs:
  - src/thing.txt -> update docs/thing.md
(Advisory only - does not block this PR.)'
out2="$(cd "$repo" && git checkout -q feature && env HIMMEL_DOC_FRESHNESS=advise bash scripts/cr/doc-freshness-advisory.sh)"
rc2=$?
check "$out2" "$want2" "T2 leg active with drift: drift lines printed"
check "$rc2" "0" "T2 leg active with drift: exit 0 (never blocks)"

# 3. Leg active with no drift -> the no-drift line, exit 0.
out3="$(cd "$repo" && git checkout -q feature-nodrift && env HIMMEL_DOC_FRESHNESS=advise bash scripts/cr/doc-freshness-advisory.sh)"
rc3=$?
check "$out3" "Doc-freshness: no mapped-source-vs-doc drift in range." "T3 leg active, no drift: no-drift line"
check "$rc3" "0" "T3 leg active, no drift: exit 0"

# --- fixture_nolib: same script tree, minus scripts/lib/doc-freshness.sh ---
nolib="$tmp/fixture_nolib"
mkdir -p "$nolib/scripts/cr" "$nolib/scripts/guardrails" "$nolib/scripts/lib"
cp "$SCRIPT" "$nolib/scripts/cr/doc-freshness-advisory.sh"
cp "$GUARDDIR/lib.sh" "$nolib/scripts/guardrails/lib.sh"
cp "$LIBDIR/load-dotenv.sh" "$nolib/scripts/lib/load-dotenv.sh"
# doc-freshness.sh deliberately NOT copied.

# 4. Missing doc-freshness.sh lib -> exit 0, no crash, no output.
out4="$(cd "$nolib" && env HIMMEL_DOC_FRESHNESS=advise bash scripts/cr/doc-freshness-advisory.sh)"
rc4=$?
check "$out4" "" "T4 missing lib: no output"
check "$rc4" "0" "T4 missing lib: exit 0, no crash"

[ "$fail" -eq 0 ] && echo "PASS test-doc-freshness-advisory ($pass/$((pass + fail)))"
[ "$fail" -eq 0 ] || { echo "FAIL test-doc-freshness-advisory ($fail/$((pass + fail)) failed)"; exit 1; }
