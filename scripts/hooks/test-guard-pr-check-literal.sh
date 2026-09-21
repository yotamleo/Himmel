#!/usr/bin/env bash
# Smoke test for scripts/hooks/guard-pr-check-literal.sh (HIMMEL-3383).
#
# Builds a throwaway himmel-shaped fixture — an "origin" repo carrying
# scripts/cr/pr-check-context.sh and scripts/guardrails/lib.sh on main, a
# primary clone (the HIMMEL_REPO anchor) and a linked worktree off it — then
# feeds the hook PreToolUse payloads for the bare /pr-check step-0 literal
# under each of the three runbook conditions, failing one at a time.
#
# Usage: bash scripts/hooks/test-guard-pr-check-literal.sh
#
# Exit codes:
#   0 - all cases passed
#   1 - at least one case failed
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/guard-pr-check-literal.sh"
LITERAL='bash scripts/cr/pr-check-context.sh'
ENV_LITERAL='bash scripts/cr/pr-check-env.sh CR_CLAUDE_AGENTS'

# A suite run from inside a git hook inherits GIT_DIR/GIT_INDEX_FILE, which
# would point every fixture git call at the outer repo.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

FAILED=0
TMP="$(mktemp -d "${TMPDIR:-/tmp}/guard-pr-check-literal.XXXXXX")" || { echo "FAIL mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"

g() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main -c commit.gpgsign=false "$@"; }

# ---- fixture ---------------------------------------------------------------
ORIGIN="$TMP/origin"
PRIMARY="$TMP/himmel"
WT="$TMP/wt"
mkdir -p "$ORIGIN/scripts/cr" "$ORIGIN/scripts/guardrails" "$ORIGIN/scripts/lib" "$ORIGIN/docs"
g init -q "$ORIGIN"
echo 'echo anchor' >"$ORIGIN/scripts/cr/pr-check-context.sh"
echo ': lib' >"$ORIGIN/scripts/guardrails/lib.sh"
echo 'echo env' >"$ORIGIN/scripts/cr/pr-check-env.sh"
echo ': dotenv' >"$ORIGIN/scripts/lib/load-dotenv.sh"
echo ': other lib' >"$ORIGIN/scripts/lib/other.sh"
echo 'doc' >"$ORIGIN/docs/a.md"
g -C "$ORIGIN" add -A
g -C "$ORIGIN" commit -qm base
g clone -q "$ORIGIN" "$PRIMARY"
g -C "$PRIMARY" worktree add -q -b feat/x "$WT" refs/remotes/origin/main
# An unrelated non-himmel repo, for the wrong-lane case.
OTHER="$TMP/other"
mkdir -p "$OTHER/scripts/cr"
g init -q "$OTHER"
echo x >"$OTHER/scripts/cr/pr-check-context.sh"
g -C "$OTHER" add -A
g -C "$OTHER" commit -qm o

payload() { # payload <command> <cwd>
    jq -cn --arg c "$1" --arg d "$2" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}'
}

# run <label> <expected-rc> <payload> [env assignments...]
run() {
    local label="$1" want="$2" input="$3" rc err
    shift 3
    err="$(printf '%s' "$input" | env -u HIMMEL_REPO "$@" bash "$HOOK" 2>&1 >/dev/null)"
    rc=$?
    if [ "$rc" = "$want" ]; then
        echo "PASS $label (rc=$rc)"
    else
        echo "FAIL $label - expected rc=$want, got rc=$rc; stderr: $err"
        FAILED=$((FAILED + 1))
    fi
    LAST_ERR="$err"
}

need_in_err() { # need_in_err <label> <fixed-string>
    if grep -qF -- "$2" <<<"$LAST_ERR"; then
        echo "PASS $1"
    else
        echo "FAIL $1 - stderr lacks '$2': $LAST_ERR"
        FAILED=$((FAILED + 1))
    fi
}

HR="HIMMEL_REPO=$PRIMARY"

# ---- allow: every condition holds -----------------------------------------
run "clean himmel-lane worktree root, no cr/lib diff -> allow" 0 "$(payload "$LITERAL" "$WT")" "$HR"
[ -z "$LAST_ERR" ] || { echo "FAIL allow is silent - stderr: $LAST_ERR"; FAILED=$((FAILED + 1)); }
run "pr-check-env literal on a clean root -> allow" 0 "$(payload "$ENV_LITERAL" "$WT")" "$HR"
echo ': edited' >>"$WT/scripts/lib/other.sh"
run "an unguarded scripts/lib/ diff -> allow" 0 "$(payload "$LITERAL" "$WT")" "$HR"
g -C "$WT" checkout -q -- scripts/lib/other.sh
run "primary checkout root -> allow" 0 "$(payload "$LITERAL" "$PRIMARY")" "$HR"
run "HIMMEL_REPO with a trailing slash -> allow" 0 "$(payload "$LITERAL" "$WT")" "HIMMEL_REPO=$PRIMARY/"
echo doc2 >"$WT/docs/a.md"
run "an unrelated (docs) diff -> allow" 0 "$(payload "$LITERAL" "$WT")" "$HR"
g -C "$WT" checkout -q -- docs/a.md

# ---- no-op: anything that is not the literal -------------------------------
run "unrelated command, no HIMMEL_REPO -> no-op" 0 "$(payload 'git status' "$TMP")"
[ -z "$LAST_ERR" ] || { echo "FAIL no-op is silent - stderr: $LAST_ERR"; FAILED=$((FAILED + 1)); }
# shellcheck disable=SC2016 # the fence text, verbatim
run "the anchored fence itself -> no-op" 0 "$(payload 'bash "$himmel_repo/scripts/cr/pr-check-context.sh"' "$TMP")"
run "literal with an argument -> no-op (no allow rule matches it)" 0 "$(payload "$LITERAL --x" "$TMP")"
run "non-Bash tool -> no-op" 0 "$(jq -cn --arg c "$LITERAL" '{tool_name:"Read",tool_input:{command:$c},cwd:"/"}')"

# ---- deny: a branch-edited pr-check-context.sh -----------------------------
echo 'echo branch' >"$WT/scripts/cr/pr-check-context.sh"
g -C "$WT" commit -qam 'edit pr-check-context'
run "branch-edited pr-check-context.sh -> deny" 2 "$(payload "$LITERAL" "$WT")" "$HR"
need_in_err "deny names the changed file" "scripts/cr/pr-check-context.sh"
# shellcheck disable=SC2016 # the fence text, verbatim
need_in_err "deny names the canonical anchored fence" 'bash "$himmel_repo/scripts/cr/pr-check-context.sh"'
run "branch-edited + surrounding whitespace -> deny" 2 "$(payload "  $LITERAL  " "$WT")" "$HR"
# A local replace ref can swap origin/main's commit for the edited one; the
# hook must read the real object, not the replacement.
g -C "$WT" replace "$(g -C "$WT" rev-parse refs/remotes/origin/main)" HEAD
run "branch edit hidden by a git replace of origin/main -> deny" 2 "$(payload "$LITERAL" "$WT")" "$HR"
g -C "$WT" replace -d "$(g -C "$WT" rev-parse refs/remotes/origin/main)"
g -C "$WT" reset -q --hard refs/remotes/origin/main

# ---- deny: a lib.sh-only diff (uncommitted counts) -------------------------
echo ': edited' >>"$WT/scripts/guardrails/lib.sh"
run "lib.sh-only uncommitted diff -> deny" 2 "$(payload "$LITERAL" "$WT")" "$HR"
need_in_err "deny names lib.sh" "scripts/guardrails/lib.sh"
g -C "$WT" checkout -q -- scripts/guardrails/lib.sh

# ---- deny: a load-dotenv.sh-only diff (pr-check-env.sh sources it) ---------
echo ': edited' >>"$WT/scripts/lib/load-dotenv.sh"
run "load-dotenv.sh-only diff, pr-check-env literal -> deny" 2 "$(payload "$ENV_LITERAL" "$WT")" "$HR"
need_in_err "deny names load-dotenv.sh" "scripts/lib/load-dotenv.sh"
need_in_err "env deny names its own canonical spelling" 'scripts/cr/pr-check-env.sh" CR_CLAUDE_AGENTS'
run "load-dotenv.sh-only diff, pr-check-context literal -> deny" 2 "$(payload "$LITERAL" "$WT")" "$HR"
g -C "$WT" checkout -q -- scripts/lib/load-dotenv.sh
run "pr-check-env literal with another argument -> no-op" 0 "$(payload "bash scripts/cr/pr-check-env.sh CR_PROFILE" "$TMP")"

# ---- deny: index flags that hide a working-tree edit from git diff ----------
g -C "$WT" update-index --assume-unchanged scripts/cr/pr-check-context.sh
echo 'echo hidden' >"$WT/scripts/cr/pr-check-context.sh"
run "assume-unchanged edit to pr-check-context.sh -> deny" 2 "$(payload "$LITERAL" "$WT")" "$HR"
g -C "$WT" update-index --no-assume-unchanged scripts/cr/pr-check-context.sh
g -C "$WT" checkout -q -- scripts/cr/pr-check-context.sh
g -C "$WT" update-index --skip-worktree scripts/guardrails/lib.sh
echo ': hidden' >>"$WT/scripts/guardrails/lib.sh"
run "skip-worktree edit to lib.sh -> deny" 2 "$(payload "$LITERAL" "$WT")" "$HR"
g -C "$WT" update-index --no-skip-worktree scripts/guardrails/lib.sh
g -C "$WT" checkout -q -- scripts/guardrails/lib.sh
run "flags cleared again -> allow" 0 "$(payload "$LITERAL" "$WT")" "$HR"

# ---- deny: a clean filter that normalises an edit back to the base ----------
# git diff would run the filter (executing repo-configured commands) and see
# no change; the hook must hash raw bytes and never run it.
printf '%s\n' 'scripts/cr/*.sh filter=hide' >"$WT/.gitattributes"
g -C "$WT" config filter.hide.clean "touch '$TMP/filter-ran'; sed s/branch/anchor/"
echo 'echo branch' >"$WT/scripts/cr/pr-check-context.sh"
run "clean-filter-hidden edit to pr-check-context.sh -> deny" 2 "$(payload "$LITERAL" "$WT")" "$HR"
if [ -e "$TMP/filter-ran" ]; then
    echo "FAIL the hook ran a repo-configured clean filter"
    FAILED=$((FAILED + 1))
else
    echo "PASS the hook runs no repo-configured clean filter"
fi
g -C "$WT" config --unset filter.hide.clean
rm -f "$WT/.gitattributes" "$TMP/filter-ran"
g -C "$WT" checkout -q -- scripts/cr/pr-check-context.sh

# ---- deny: a symlink under scripts/cr/ -------------------------------------
ln -s pr-check-context.sh "$WT/scripts/cr/link.sh"
run "symlink under scripts/cr/ -> deny" 2 "$(payload "$LITERAL" "$WT")" "$HR"
rm -f "$WT/scripts/cr/link.sh"
run "tree restored after filter/symlink cases -> allow" 0 "$(payload "$LITERAL" "$WT")" "$HR"

# ---- deny: a cwd carrying a newline must not shift the command field --------
run "cwd with an embedded newline -> deny, not a no-op" 2 "$(payload "$LITERAL" "$WT"$'\n'"x")" "$HR"
# A trailing newline names a different directory; decoding must not strip it
# back into the clean worktree's path.
run "cwd with a trailing newline -> deny" 2 "$(payload "$LITERAL" "$WT"$'\n')" "$HR"

# ---- deny: an untracked file under scripts/cr/ -----------------------------
echo x >"$WT/scripts/cr/new.sh"
run "untracked scripts/cr/ file -> deny" 2 "$(payload "$LITERAL" "$WT")" "$HR"
rm -f "$WT/scripts/cr/new.sh"

# ---- deny: non-root cwd ----------------------------------------------------
run "cwd below the worktree root -> deny" 2 "$(payload "$LITERAL" "$WT/scripts")" "$HR"
need_in_err "deny names the root condition" "worktree root"

# ---- deny: non-himmel lane -------------------------------------------------
run "HIMMEL_REPO names another repo -> deny" 2 "$(payload "$LITERAL" "$WT")" "HIMMEL_REPO=$OTHER"
run "cwd in a non-himmel repo -> deny" 2 "$(payload "$LITERAL" "$OTHER")" "$HR"
run "HIMMEL_REPO unset -> deny" 2 "$(payload "$LITERAL" "$WT")"
run "HIMMEL_REPO empty -> deny" 2 "$(payload "$LITERAL" "$WT")" "HIMMEL_REPO="
run "cwd outside any repo -> deny" 2 "$(payload "$LITERAL" "$TMP")" "$HR"
run "payload without cwd -> deny" 2 "$(jq -cn --arg c "$LITERAL" '{tool_name:"Bash",tool_input:{command:$c}}')" "$HR"

# ---- deny: origin/main unreadable ------------------------------------------
g -C "$PRIMARY" update-ref -d refs/remotes/origin/main
run "refs/remotes/origin/main missing -> deny" 2 "$(payload "$LITERAL" "$WT")" "$HR"
need_in_err "deny names the missing ref" "refs/remotes/origin/main"
# A local BRANCH named origin/main must not stand in for the remote-tracking ref.
g -C "$PRIMARY" branch -q origin/main main
run "local branch origin/main only -> deny" 2 "$(payload "$LITERAL" "$WT")" "$HR"

# ---- deny: payload the hook cannot read ------------------------------------
run "malformed JSON -> deny" 2 '{"tool_name":"Bash","tool_input":{"command":'
run "empty stdin -> deny" 2 ''

echo
if [ "$FAILED" -eq 0 ]; then
    echo "all guard-pr-check-literal cases passed"
    exit 0
fi
echo "$FAILED guard-pr-check-literal case(s) failed"
exit 1
