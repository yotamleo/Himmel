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
        echo "PASS $label (rc=$rc)${err:+ - ${err%%$'\n'*}}"
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
run "a ./ spelling on a clean root -> allow" 0 "$(payload "bash ./scripts/cr/pr-check-context.sh" "$WT")" "$HR"

# ---- C2: the base is the ANCHOR's working-tree bytes, not a ref ---------------
# A primary whose scripts/cr/ differs from the worktree (lagging or ahead of
# the branch's base) denies: the anchor's bytes are what the hand-off runs.
echo 'echo newer' >"$PRIMARY/scripts/cr/pr-check-context.sh"
run "anchor's scripts/cr/ differs from the worktree -> deny" 2 "$(payload "$LITERAL" "$WT")" "$HR"
need_in_err "deny names the anchor as the base" "HIMMEL_REPO"
g -C "$PRIMARY" checkout -q -- scripts/cr/pr-check-context.sh
# I4: the mode is compared too - chmod +x is a change.
chmod +x "$WT/scripts/cr/pr-check-context.sh"
run "chmod +x on pr-check-context.sh -> deny" 2 "$(payload "$LITERAL" "$WT")" "$HR"
chmod -x "$WT/scripts/cr/pr-check-context.sh"
# S5: a missing tool must not collapse both sides to "" and compare equal.
mkdir -p "$TMP/nosort-bin"
for t in bash env jq git awk find paste wc tr comm cat realpath basename dirname grep sed; do
    tp=$(command -v "$t") && ln -sf "$tp" "$TMP/nosort-bin/$t"
done
run "a PATH without sort -> deny (fail closed)" 2 "$(payload "$LITERAL" "$WT")" "$HR" "PATH=$TMP/nosort-bin"
need_in_err "deny names the missing tool" "'sort' is not on PATH"
# Round 6: classification itself must not need a tool - a missing tr once
# emptied the command into a silent no-op.
mkdir -p "$TMP/notr-bin"
for t in bash env jq git awk find paste wc sort comm cat realpath basename dirname grep sed; do
    tp=$(command -v "$t") && ln -sf "$tp" "$TMP/notr-bin/$t"
done
run "a PATH without tr -> deny (fail closed)" 2 "$(payload "$LITERAL" "$WT")" "$HR" "PATH=$TMP/notr-bin"
need_in_err "deny names the missing tr" "'tr' is not on PATH"
# Round 6: the path must resolve against the cwd the conditions are checked
# in - a clean root proves nothing about the copy a cd or ../ reaches.
mkdir -p "$TMP/elsewhere/scripts/cr"
run "cd elsewhere && the literal, clean root -> deny" 2 \
    "$(payload "cd $TMP/elsewhere && $LITERAL" "$WT")" "$HR"
need_in_err "deny names the directory change" "changes directory"
run "pushd elsewhere; the literal, clean root -> deny" 2 \
    "$(payload "pushd $TMP/elsewhere; $LITERAL" "$WT")" "$HR"
run "a ../ path out of the root, clean root -> deny" 2 \
    "$(payload "bash ../elsewhere/scripts/cr/pr-check-context.sh" "$WT")" "$HR"
run "a path under another directory, clean root -> deny" 2 \
    "$(payload "bash docs/scripts/cr/pr-check-context.sh" "$WT")" "$HR"
# Round 7: .. resolves after symlinks, so it is never taken lexically.
ln -s "$TMP/elsewhere/scripts" "$WT/scripts/x"
run "scripts/x/../cr/ through a symlinked dir, clean root -> deny" 2 \
    "$(payload "bash scripts/x/../cr/pr-check-context.sh" "$WT")" "$HR"
rm "$WT/scripts/x"
run "env -C elsewhere and the literal, clean root -> deny" 2 \
    "$(payload "env -C $TMP/elsewhere $LITERAL" "$WT")" "$HR"
need_in_err "deny names the directory change" "changes directory"
# Round 9: a relative wrapper operand hides the command word, and a second
# command can rewrite the checked bytes before the script runs.
run "env -C with a relative dir and the literal, clean root -> deny" 2 \
    "$(payload "env -C elsewhere $LITERAL" "$WT")" "$HR"
run "cp over the script; the literal, clean root -> deny" 2 \
    "$(payload "cp $TMP/x.sh scripts/cr/pr-check-context.sh; $LITERAL" "$WT")" "$HR"
need_in_err "deny names the compound" "not one simple command"
run "timeout 60 and the literal, clean root -> deny" 2 \
    "$(payload "timeout 60 $LITERAL" "$WT")" "$HR"
# Round 11: BASH_ENV (or any VAR= prefix) runs code before the checked bytes.
run "BASH_ENV= and the literal, clean root -> deny" 2 \
    "$(payload "BASH_ENV=$TMP/x.sh $LITERAL" "$WT")" "$HR"
need_in_err "deny names the VAR= prefix" "VAR= prefix"
echo doc2 >"$WT/docs/a.md"
run "an unrelated (docs) diff -> allow" 0 "$(payload "$LITERAL" "$WT")" "$HR"
g -C "$WT" checkout -q -- docs/a.md

# ---- no-op: anything that is not the literal -------------------------------
run "unrelated command, no HIMMEL_REPO -> no-op" 0 "$(payload 'git status' "$TMP")"
[ -z "$LAST_ERR" ] || { echo "FAIL no-op is silent - stderr: $LAST_ERR"; FAILED=$((FAILED + 1)); }
# shellcheck disable=SC2016 # the fence text, verbatim
FENCE_TEXT='if himmel_repo=$(printenv HIMMEL_REPO | grep .); then
    bash "$himmel_repo/scripts/cr/pr-check-context.sh"
else
    echo "pr-check: HIMMEL_REPO is unset or empty" >&2
    exit 2
fi'
run "the anchored fence itself -> no-op" 0 "$(payload "$FENCE_TEXT" "$TMP")"
run "non-Bash tool -> no-op" 0 "$(jq -cn --arg c "$LITERAL" '{tool_name:"Read",tool_input:{command:$c},cwd:"/"}')"

# ---- deny: a branch-edited pr-check-context.sh -----------------------------
echo 'echo branch' >"$WT/scripts/cr/pr-check-context.sh"
g -C "$WT" commit -qam 'edit pr-check-context'
run "branch-edited pr-check-context.sh -> deny" 2 "$(payload "$LITERAL" "$WT")" "$HR"
need_in_err "deny names the changed file" "scripts/cr/pr-check-context.sh"
# shellcheck disable=SC2016 # the fence text, verbatim
need_in_err "deny names the canonical anchored fence" 'bash "$himmel_repo/scripts/cr/pr-check-context.sh"'
run "branch-edited + surrounding whitespace -> deny" 2 "$(payload "  $LITERAL  " "$WT")" "$HR"

# ---- review C1: the anchor's working tree is forgeable by a git write -------
# A leg can copy its edit into the primary (checkout <branch> -- <path>, a
# detached HEAD, another branch); the anchor then equals the branch, so the
# anchor must itself be main's committed bytes.
g -C "$PRIMARY" checkout -q feat/x -- scripts/cr/pr-check-context.sh
run "anchor working tree forged from the branch -> deny" 2 "$(payload "$LITERAL" "$WT")" "$HR"
need_in_err "deny names the anchor's uncommitted bytes" "not refs/heads/main's committed"
g -C "$PRIMARY" checkout -q HEAD -- scripts/cr/pr-check-context.sh
g -C "$PRIMARY" checkout -q --detach feat/x
run "anchor on a detached HEAD at the branch -> deny" 2 "$(payload "$LITERAL" "$WT")" "$HR"
need_in_err "deny names the anchor's HEAD" "refs/heads/main"
g -C "$PRIMARY" checkout -q -b forged
run "anchor on another branch at the branch's commit -> deny" 2 "$(payload "$LITERAL" "$WT")" "$HR"
g -C "$PRIMARY" checkout -q main
g -C "$PRIMARY" branch -q -D forged

# ---- C1: spelling variants the Bash(bash scripts/*) allow rule also matches --
# Classified by the script they run, not by the text: each runs the branch's
# edited pr-check-context.sh / pr-check-env.sh, so each must deny.
while IFS= read -r v; do
    run "variant [$v] on an edited branch -> deny" 2 "$(payload "$v" "$WT")" "$HR"
done <<'VARIANTS'
bash scripts/cr/pr-check-context.sh --x
bash scripts/cr/pr-check-context.sh '' # -
bash scripts//cr/pr-check-context.sh
bash ./scripts/cr/pr-check-context.sh
bash scripts/cr/./pr-check-context.sh
bash scripts/cr/../cr/pr-check-context.sh
bash scripts/x/../cr/pr-check-context.sh
bash scripts/cr/pr-check-env.sh  CR_CLAUDE_AGENTS
bash scripts/cr/pr-check-env.sh CR_CLAUDE_AGENTS extra
bash scripts/cr/pr-check-env.sh CR_PROFILE
bash 'scripts/cr/pr-check-context.sh'
bash scripts/cr/pr\-check-context.sh
bash $'scripts/cr/pr-check-context.sh'
sh scripts/cr/pr-check-context.sh
source scripts/cr/pr-check-context.sh
. scripts/cr/pr-check-context.sh
./scripts/cr/pr-check-context.sh
scripts/cr/pr-check-context.sh
env bash scripts/cr/pr-check-context.sh
X=1 bash scripts/cr/pr-check-context.sh
timeout 60 bash scripts/cr/pr-check-context.sh
(bash scripts/cr/pr-check-context.sh)
true && bash scripts/cr/pr-check-context.sh
true; bash scripts/cr/pr-check-context.sh
bash -c 'bash scripts/cr/pr-check-context.sh'
eval bash scripts/cr/pr-check-context.sh
echo scripts/cr/pr-check-context.sh | xargs bash
bash < scripts/cr/pr-check-context.sh
cd scripts/cr && bash pr-check-context.sh
bash scripts/cr/pr-check-*.sh
bash scripts/cr/pr-check-{context,env}.sh
bash scripts/cr/*
bash scripts/c[r]/pr-chec[k]-context.sh
bash scripts/c?/pr-*-context.sh
bash scripts/c{r,}/pr-chec{k,}-context.sh
bash scripts/c{r,{x,y}}/pr-chec{k,{x,y}}-context.sh
f=pr-check-context.sh; bash scripts/cr/$f
bash scripts/cr/$(echo pr-check-context.sh)
bash scripts/cr/pr-che{c,}k-context.sh
bash scripts/cr/pr-{check-context,}.sh
bash scripts/cr/pr-che{c..c}k-context.sh
bash -c "bash scripts/cr/pr-che{c,}k-context.sh"
bash scripts/cr/pr-che$'\x63'k-context.sh
bash scripts/cr/pr-che${X:-c}k-context.sh
bash scripts/cr/$X
bash ~+/scripts/cr/pr-check-context.sh
bash `pwd`/scripts/cr/pr-check-context.sh
bash $(pwd)/scripts/cr/pr-check-context.sh
bash scripts/cr/PR-CHECK-CONTEXT.SH
bash SCRIPTS/CR/PR-CHECK-CONTEXT.SH
bash scripts/C?/PR-CHECK-*.SH
busybox sh scripts/cr/pr-check-context.sh
toybox sh scripts/cr/pr-check-context.sh
bash scripts/cr/*.sh
sh -c 'bash scripts/cr/*.sh'
eval "bash scripts/cr/x*.sh"
VARIANTS
run "a line continuation inside the name on an edited branch -> deny" 2 \
    "$(payload "bash scripts/cr/pr-check-con\\
text.sh" "$WT")" "$HR"
# An interpreter that runs out of operand words denies fail-closed, even
# though the trailing text (needed only to pass the pre-filter) never
# resolves under scripts/cr/ itself.
# shellcheck disable=SC2016 # command text, verbatim
run "bash \$X with an unresolvable operand -> deny" 2 \
    "$(payload 'bash $X # scripts/cr/pr-check-context.sh' "$WT")" "$HR"
# shellcheck disable=SC2016 # command text, verbatim
run "a command substitution running the guarded glob -> deny" 2 \
    "$(payload 'echo $(bash scripts/cr/*.sh)' "$WT")" "$HR"
# Mentioning the file is not running it; the canonical forms stay usable.
while IFS= read -r v; do
    run "mention [$v] on an edited branch -> no-op" 0 "$(payload "$v" "$WT")" "$HR"
done <<'MENTIONS'
grep -n x scripts/cr/pr-check-context.sh
git diff -- scripts/cr/pr-check-context.sh
cat scripts/cr/pr-check-env.sh
bash scripts/cr/test-pr-check-context.sh
bash scripts/hooks/test-guard-pr-check-literal.sh
bash scripts/cr/panel-first-pass.sh --x
grep -n x scripts/cr/*
echo "see scripts/cr/*.sh"
jq '.[] | select(.path|test("scripts/cr/.*"))' f
MENTIONS
# A heredoc body is data, not a command: naming the guarded script only in the
# body must not deny (HIMMEL-3433).
run "heredoc body naming pr-check-context.sh on an edited branch -> no-op" 0 \
    "$(payload "cat > \$S/body.md <<'EOF'
see scripts/cr/pr-check-context.sh
EOF" "$WT")" "$HR"
run "the anchored fence on an edited branch -> no-op" 0 "$(payload "$FENCE_TEXT" "$WT")" "$HR"
run "HIMMEL_REPO re-pointed before the fence -> deny" 2 \
    "$(payload "export HIMMEL_REPO=.; $FENCE_TEXT" "$WT")" "$HR"
run "the anchor's absolute path on an edited branch -> no-op" 0 \
    "$(payload "bash \"$PRIMARY/scripts/cr/pr-check-env.sh\" CR_CLAUDE_AGENTS" "$WT")" "$HR"
# shellcheck disable=SC2016 # command text, verbatim
run "a read himmel_repo beside the fence -> deny" 2 \
    "$(payload "$FENCE_TEXT"'; read himmel_repo <<< .; bash "$himmel_repo/scripts/cr/pr-check-context.sh"' "$WT")" "$HR"
# shellcheck disable=SC2016 # command text, verbatim
run "the fence on one line with ; -> no-op" 0 \
    "$(payload 'if himmel_repo=$(printenv HIMMEL_REPO | grep .); then bash "$himmel_repo/scripts/cr/pr-check-context.sh"; else echo "pr-check: unset" >&2; exit 2; fi' "$WT")" "$HR"
# shellcheck disable=SC2016 # command text, verbatim
run "the fence with a \$ in its message -> deny" 2 \
    "$(payload 'if himmel_repo=$(printenv HIMMEL_REPO | grep .); then bash "$himmel_repo/scripts/cr/pr-check-context.sh"; else echo "$(himmel_repo=.)" >&2; exit 2; fi' "$WT")" "$HR"
# shellcheck disable=SC2016 # command text, verbatim
run "a second himmel_repo= beside the fence -> deny" 2 \
    "$(payload "$FENCE_TEXT"'; himmel_repo=.; bash "$himmel_repo/scripts/cr/pr-check-context.sh"' "$WT")" "$HR"

# C2: a leg can move its own refs/remotes/origin/main onto the edit; the base
# is the anchor's bytes, which that does not reach.
base_oid=$(g -C "$WT" rev-parse refs/remotes/origin/main)
g -C "$WT" update-ref refs/remotes/origin/main HEAD
run "origin/main forged onto the edit -> deny" 2 "$(payload "$LITERAL" "$WT")" "$HR"
g -C "$WT" update-ref refs/remotes/origin/main "$base_oid"
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
run "pr-check-env with another argument outside a repo -> deny" 2 "$(payload "bash scripts/cr/pr-check-env.sh CR_PROFILE" "$TMP")" "$HR"

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

# ---- deny: the anchor's scripts/cr/ unreadable ------------------------------
mv "$PRIMARY/scripts/cr" "$PRIMARY/scripts/cr.moved"
run "the anchor has no scripts/cr/ -> deny" 2 "$(payload "$LITERAL" "$WT")" "$HR"
need_in_err "deny names the anchor" "HIMMEL_REPO"
mv "$PRIMARY/scripts/cr.moved" "$PRIMARY/scripts/cr"
# origin/main plays no part any more: its absence changes nothing.
g -C "$PRIMARY" update-ref -d refs/remotes/origin/main
run "refs/remotes/origin/main missing, bytes equal the anchor's -> allow" 0 "$(payload "$LITERAL" "$WT")" "$HR"

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
