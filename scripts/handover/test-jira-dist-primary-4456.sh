#!/usr/bin/env bash
# HIMMEL-4456: arm-resume.sh and breadcrumb.sh must resolve the Jira CLI dist
# from the PRIMARY checkout (git common dir), not script-relative.
# scripts/jira/dist/ is an untracked build artifact: a worktree lacks it (the
# call silently no-ops), or carries branch bytes if it happens to have one.
#
# Hermetic: builds a fixture primary repo holding a copy of the scripts these
# two files need, plus a git worktree of it. The fake dist exists ONLY in the
# primary; the worktree copy of each script is the one under test.
#   1. breadcrumb.sh from the worktree enriches via the primary's dist.
#   2. a stale dist inside the worktree is NOT used (primary wins).
#   3. arm-resume.sh from the worktree refuses a Done ticket via the primary's dist.
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/jira-dist-primary-4456.XXXXXX") || exit 1; TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 'rm -rf "$TMP_ROOT"' EXIT
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; [ $# -ge 2 ] && printf '    %s\n' "$2"; FAIL=$((FAIL+1)); }
has() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "missing '$2' in: $3" ;; esac; }
hasnt() { case "$3" in *"$2"*) fail "$1" "unexpected '$2' in: $3" ;; *) pass "$1" ;; esac; }

command -v node >/dev/null 2>&1 || { echo "PASS skipped — node not available"; exit 0; }

PRIMARY="$TMP_ROOT/primary"; WT="$TMP_ROOT/wt"
mkdir -p "$PRIMARY"
tar -C "$SRC" -cf - scripts/handover scripts/lib scripts/lanes scripts/worktree.sh | tar -x -C "$PRIMARY"
git -C "$PRIMARY" init -q -b main
git -C "$PRIMARY" config user.email t@e.x; git -C "$PRIMARY" config user.name t
git -C "$PRIMARY" config commit.gpgsign false
git -C "$PRIMARY" add -A >/dev/null 2>&1; git -C "$PRIMARY" commit -qm seed
git -C "$PRIMARY" worktree add -q -b feat/x "$WT" >/dev/null 2>&1

# fake CLI: `get <key>` -> key<TAB>summary<TAB>status ; status/marker per dist
mkdir -p "$PRIMARY/scripts/jira/dist"
cat > "$PRIMARY/scripts/jira/dist/index.js" <<'EOF'
if (process.argv[2] === 'get') console.log(process.argv[3] + '\tPRIMARY-DIST-MARK\tDone');
EOF

export HANDOVER_DIR="$TMP_ROOT/ho"; mkdir -p "$HANDOVER_DIR"
REPO="$TMP_ROOT/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b feat/himmel-9004-x
git -C "$REPO" config user.email t@e.x; git -C "$REPO" config user.name t
git -C "$REPO" config commit.gpgsign false
git -C "$REPO" commit -q --allow-empty -m "feat: [HIMMEL-9004] seed"

echo "TEST 1: breadcrumb.sh in a worktree uses the primary's dist"
out=$(bash "$WT/scripts/handover/breadcrumb.sh" resolve --ticket HIMMEL-9004 --cwd "$REPO" 2>&1 || true)
has "jira line comes from primary dist" "PRIMARY-DIST-MARK" "$out"

echo "TEST 2: a dist inside the worktree is not used"
mkdir -p "$WT/scripts/jira/dist"
echo "console.log('WORKTREE-DIST-MARK');" > "$WT/scripts/jira/dist/index.js"
out=$(bash "$WT/scripts/handover/breadcrumb.sh" resolve --ticket HIMMEL-9004 --cwd "$REPO" 2>&1 || true)
hasnt "worktree dist ignored" "WORKTREE-DIST-MARK" "$out"
has "primary dist still used" "PRIMARY-DIST-MARK" "$out"
rm -rf "$WT/scripts/jira"

echo "TEST 3: arm-resume.sh in a worktree refuses a Done ticket via the primary's dist"
HO="$TMP_ROOT/handover.md"
printf -- '---\nticket: HIMMEL-9004\nresume_cwd: %s\n---\n\n# HIMMEL-9004 thing\n' "$REPO" > "$HO"
t=$(python3 -c "import datetime,time; print(datetime.datetime.fromtimestamp(time.time()+1800).strftime('%H:%M'))")
# Scheduler stubs: if the preflight no-ops (the bug), the arm must not reach a
# REAL at/cron. --dry-run is no use here: it skips the preflight entirely.
STUBS="$TMP_ROOT/stubs"; mkdir -p "$STUBS"
printf '#!/bin/sh\ncat >/dev/null\necho "job 1 at stub"\n' > "$STUBS/at"
printf '#!/bin/sh\nexit 0\n' > "$STUBS/atq"; cp "$STUBS/atq" "$STUBS/atrm"; cp "$STUBS/atq" "$STUBS/crontab"
chmod +x "$STUBS"/*
rc=0; out=$(PATH="$STUBS:$PATH" FLEET_CAP_OK=1 ARM_FIXTURE_OK=1 GH_CMD=/nonexistent/gh bash "$WT/scripts/handover/arm-resume.sh" --time "$t" --handover "$HO" 2>&1) || rc=$?
case "$rc" in 11) pass "rc=11 shipped-work refusal" ;; *) fail "want rc=11, got $rc" "$out" ;; esac
has "ERR names the ticket" "HIMMEL-9004" "$out"

echo "test summary: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
