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
mkdir -p "$ORIGIN/scripts/cr" "$ORIGIN/scripts/guardrails" "$ORIGIN/scripts/lib" "$ORIGIN/docs" \
    "$ORIGIN/scripts/handover/console-kit"
g init -q "$ORIGIN"
echo 'echo anchor' >"$ORIGIN/scripts/cr/pr-check-context.sh"
echo ': lib' >"$ORIGIN/scripts/guardrails/lib.sh"
echo 'echo env' >"$ORIGIN/scripts/cr/pr-check-env.sh"
echo ': dotenv' >"$ORIGIN/scripts/lib/load-dotenv.sh"
echo ': other lib' >"$ORIGIN/scripts/lib/other.sh"
# HIMMEL-3495: every gate-allowed scripts/cr entry, and the hand-off each sources.
for t in anchor-handoff.sh clear-cr-marker.sh codex-adv-harvest.sh codex-adv-kickoff.sh \
    cr-scores.sh doc-freshness-advisory.sh docs-audit-panel.sh impacted-suites.sh \
    known-findings.sh ledger-append.sh orphan-check.sh panel-first-pass.sh \
    review-round.sh write-verdicts.sh; do
    echo "echo $t" >"$ORIGIN/scripts/cr/$t"
done
# HIMMEL-3437: the two scripts/handover/ gate-writer entries this hook also
# targets, held to the entry + scripts/cr/anchor-handoff.sh (narrower family) -
# plus go.sh's own sibling-sourced libs (go-gate.sh, handover-path.sh), which
# it reads via a branch-relative path even after the hand-off's re-exec lands
# it in the anchor's own console-kit/, so they must be guarded too.
echo 'echo mog' >"$ORIGIN/scripts/handover/merge-on-green.sh"
echo 'echo go' >"$ORIGIN/scripts/handover/console-kit/go.sh"
echo ': go-gate' >"$ORIGIN/scripts/lib/go-gate.sh"
echo ': handover-path' >"$ORIGIN/scripts/lib/handover-path.sh"
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

# ---- HIMMEL-3495: every gate-allowed scripts/cr script is a target ------------
# The set is DERIVED from every `Bash(...` allow row in both permission files
# that names scripts/cr/<name>.sh ANYWHERE (a `./scripts/cr/x.sh` row too), so a
# new row the hook does not guard fails here.
REPO_ROOT="$(cd "$(dirname "$HOOK")/../.." && pwd)"
cr_rows() {
    grep -ohE '"Bash\([^"]*scripts/cr/[A-Za-z0-9._-]+\.sh' "$@" \
        | grep -oE 'scripts/cr/[A-Za-z0-9._-]+\.sh' | sed 's|.*/||' | LC_ALL=C sort -u
}
printf '{"allow": ["Bash(./scripts/cr/newgate.sh *)"]}\n' >"$TMP/rows.json"
if [ "$(cr_rows "$TMP/rows.json")" = "newgate.sh" ]; then
    echo "PASS a ./scripts/cr/ row is derived"
else
    echo "FAIL a ./scripts/cr/ row is not derived: $(cr_rows "$TMP/rows.json")"
    FAILED=$((FAILED + 1))
fi
derived=$(cr_rows "$REPO_ROOT/.claude/settings.json" "$REPO_ROOT/scripts/lanes/plugin-profiles.json")
declared=$(sed -n "/^TARGETS='/,/'\$/p" "$HOOK" | sed "s/^TARGETS=//; s/'//g" | tr ' ' '\n' | grep . | LC_ALL=C sort -u)
if [ -n "$derived" ] && [ "$derived" = "$declared" ]; then
    echo "PASS hook TARGETS equal the allow rows' scripts/cr entries ($(printf '%s\n' "$derived" | wc -l | tr -d ' '))"
else
    echo "FAIL hook TARGETS drift from the allow rows - rows: $(printf '%s' "$derived" | tr '\n' ' ') - hook: $(printf '%s' "$declared" | tr '\n' ' ')"
    FAILED=$((FAILED + 1))
fi
for t in $derived; do
    run "clean tree, bash scripts/cr/$t -> allow" 0 "$(payload "bash scripts/cr/$t" "$WT")" "$HR"
    echo ': edited' >>"$WT/scripts/cr/$t"
    run "edited entry, bash scripts/cr/$t -> deny" 2 "$(payload "bash scripts/cr/$t" "$WT")" "$HR"
    g -C "$WT" checkout -q -- "scripts/cr/$t"
done
RR='bash scripts/cr/review-round.sh start --branch feat/x'
echo ': edited' >>"$WT/scripts/cr/anchor-handoff.sh"
run "edited anchor-handoff.sh, review-round -> deny" 2 "$(payload "$RR" "$WT")" "$HR"
need_in_err "deny names the hand-off" "scripts/cr/anchor-handoff.sh"
g -C "$WT" checkout -q -- scripts/cr/anchor-handoff.sh
# Per-file scope: a sibling's edit leaves review-round's own bytes (and the
# hand-off that execs the anchor's copy) unchanged; pr-check-context keeps the
# whole directory.
echo ': edited' >>"$WT/scripts/cr/cr-scores.sh"
run "sibling cr-scores.sh edited, review-round -> allow" 0 "$(payload "$RR" "$WT")" "$HR"
run "sibling cr-scores.sh edited, pr-check-context -> deny" 2 "$(payload "$LITERAL" "$WT")" "$HR"
g -C "$WT" checkout -q -- scripts/cr/cr-scores.sh
chmod +x "$WT/scripts/cr/review-round.sh"
run "chmod +x on review-round.sh -> deny" 2 "$(payload "$RR" "$WT")" "$HR"
chmod -x "$WT/scripts/cr/review-round.sh"
# Per-file mode: a symlinked entry or hand-off is refused even when the bytes
# it points at match the anchor's.
for f in review-round.sh anchor-handoff.sh; do
    mv "$WT/scripts/cr/$f" "$TMP/$f.real"
    ln -s "$TMP/$f.real" "$WT/scripts/cr/$f"
    run "symlinked $f, review-round -> deny" 2 "$(payload "$RR" "$WT")" "$HR"
    rm "$WT/scripts/cr/$f"
    mv "$TMP/$f.real" "$WT/scripts/cr/$f"
done
run "entry and hand-off restored, review-round -> allow" 0 "$(payload "$RR" "$WT")" "$HR"
# A symlinked scripts/cr directory is refused even when every byte matches.
mv "$WT/scripts/cr" "$WT/scripts/cr-real"
ln -s cr-real "$WT/scripts/cr"
run "symlinked scripts/cr dir, review-round -> deny" 2 "$(payload "$RR" "$WT")" "$HR"
run "symlinked scripts/cr dir, pr-check-context -> deny" 2 "$(payload "$LITERAL" "$WT")" "$HR"
rm "$WT/scripts/cr"
mv "$WT/scripts/cr-real" "$WT/scripts/cr"
run "scripts/cr dir restored, review-round -> allow" 0 "$(payload "$RR" "$WT")" "$HR"

# ---- HIMMEL-3437: scripts/handover/ gate writers are targets too --------------
# merge-on-green.sh and console-kit/go.sh are gate-allowed RELATIVE literals
# too (scripts/lanes/plugin-profiles.json gateAllow), outside scripts/cr/ -
# held to the same narrower condition as the other thirteen: the entry script
# and scripts/cr/anchor-handoff.sh byte-equal the anchor's.
MOG='bash scripts/handover/merge-on-green.sh'
GO='bash scripts/handover/console-kit/go.sh'
run "clean tree, bash scripts/handover/merge-on-green.sh -> allow" 0 "$(payload "$MOG" "$WT")" "$HR"
run "clean tree, bash scripts/handover/console-kit/go.sh -> allow" 0 "$(payload "$GO" "$WT")" "$HR"
echo ': edited' >>"$WT/scripts/handover/merge-on-green.sh"
run "edited merge-on-green.sh -> deny" 2 "$(payload "$MOG" "$WT")" "$HR"
need_in_err "deny names merge-on-green.sh" "scripts/handover/merge-on-green.sh"
g -C "$WT" checkout -q -- scripts/handover/merge-on-green.sh
echo ': edited' >>"$WT/scripts/handover/console-kit/go.sh"
run "edited go.sh -> deny" 2 "$(payload "$GO" "$WT")" "$HR"
need_in_err "deny names go.sh" "scripts/handover/console-kit/go.sh"
g -C "$WT" checkout -q -- scripts/handover/console-kit/go.sh
echo ': edited' >>"$WT/scripts/cr/anchor-handoff.sh"
run "edited anchor-handoff.sh, merge-on-green -> deny" 2 "$(payload "$MOG" "$WT")" "$HR"
need_in_err "deny names the hand-off" "scripts/cr/anchor-handoff.sh"
run "edited anchor-handoff.sh, go.sh -> deny" 2 "$(payload "$GO" "$WT")" "$HR"
g -C "$WT" checkout -q -- scripts/cr/anchor-handoff.sh
# Per-file scope: editing one handover writer must not deny the other, or an
# unrelated scripts/cr entry.
echo ': edited' >>"$WT/scripts/handover/merge-on-green.sh"
run "merge-on-green.sh edited, go.sh -> allow" 0 "$(payload "$GO" "$WT")" "$HR"
run "merge-on-green.sh edited, review-round -> allow" 0 "$(payload "$RR" "$WT")" "$HR"
g -C "$WT" checkout -q -- scripts/handover/merge-on-green.sh
chmod +x "$WT/scripts/handover/console-kit/go.sh"
run "chmod +x on go.sh -> deny" 2 "$(payload "$GO" "$WT")" "$HR"
chmod -x "$WT/scripts/handover/console-kit/go.sh"
# A symlinked entry is refused even when the bytes it points at match.
mv "$WT/scripts/handover/merge-on-green.sh" "$TMP/mog.real"
ln -s "$TMP/mog.real" "$WT/scripts/handover/merge-on-green.sh"
run "symlinked merge-on-green.sh -> deny" 2 "$(payload "$MOG" "$WT")" "$HR"
rm "$WT/scripts/handover/merge-on-green.sh"
mv "$TMP/mog.real" "$WT/scripts/handover/merge-on-green.sh"
# A symlinked scripts/handover/ or console-kit/ directory is refused even when
# every byte underneath matches (same class as the symlinked scripts/cr dir
# case above).
mv "$WT/scripts/handover" "$WT/scripts/handover-real"
ln -s handover-real "$WT/scripts/handover"
run "symlinked scripts/handover dir, merge-on-green -> deny" 2 "$(payload "$MOG" "$WT")" "$HR"
rm "$WT/scripts/handover"
mv "$WT/scripts/handover-real" "$WT/scripts/handover"
mv "$WT/scripts/handover/console-kit" "$WT/scripts/handover/console-kit-real"
ln -s console-kit-real "$WT/scripts/handover/console-kit"
run "symlinked console-kit dir, go.sh -> deny" 2 "$(payload "$GO" "$WT")" "$HR"
rm "$WT/scripts/handover/console-kit"
mv "$WT/scripts/handover/console-kit-real" "$WT/scripts/handover/console-kit"
run "handover writers restored, merge-on-green -> allow" 0 "$(payload "$MOG" "$WT")" "$HR"
run "handover writers restored, go.sh -> allow" 0 "$(payload "$GO" "$WT")" "$HR"

# ---- console-O NO-GO finding 1: the $HIMMEL_REPO-prefixed anchor spelling -----
# HIMMEL-3491's documented anchored spelling for merge-on-green.sh, gate-
# allowed at scripts/lanes/plugin-profiles.json:7 and .claude/settings.json,
# is a LITERAL `$HIMMEL_REPO` (or `${HIMMEL_REPO}`) prefix - never evaluated
# by this hook (it only sees the raw command text), so it is exactly as
# trusted as any other absolute path once resolved: the shell, not a branch,
# picks the anchor. Denying it left a leg with no allow-listed way to merge.
# shellcheck disable=SC2016 # the literal `$HIMMEL_REPO` text, never expanded here
run 'literal $HIMMEL_REPO/ prefix, clean tree -> allow' 0 \
    "$(payload 'bash "$HIMMEL_REPO/scripts/handover/merge-on-green.sh"' "$WT")" "$HR"
echo ': edited' >>"$WT/scripts/handover/merge-on-green.sh"
# shellcheck disable=SC2016 # the literal `$HIMMEL_REPO` text, never expanded here
run 'literal $HIMMEL_REPO/ prefix, edited branch -> still allow (anchor spelling)' 0 \
    "$(payload 'bash "$HIMMEL_REPO/scripts/handover/merge-on-green.sh"' "$WT")" "$HR"
# shellcheck disable=SC2016 # the literal `${HIMMEL_REPO}` text, never expanded here
run 'literal ${HIMMEL_REPO}/ braced prefix, edited branch -> still allow' 0 \
    "$(payload 'bash "${HIMMEL_REPO}/scripts/handover/merge-on-green.sh"' "$WT")" "$HR"
g -C "$WT" checkout -q -- scripts/handover/merge-on-green.sh
# The exemption is general (not handover-specific): a clean scripts/cr/
# target and go.sh through the same literal prefix must also allow.
# shellcheck disable=SC2016 # the literal `$HIMMEL_REPO` text, never expanded here
run 'literal $HIMMEL_REPO/ prefix onto a scripts/cr/ target -> allow' 0 \
    "$(payload 'bash "$HIMMEL_REPO/scripts/cr/pr-check-context.sh"' "$WT")" "$HR"
# shellcheck disable=SC2016 # the literal `$HIMMEL_REPO` text, never expanded here
run 'literal $HIMMEL_REPO/ prefix onto go.sh -> allow' 0 \
    "$(payload 'bash "$HIMMEL_REPO/scripts/handover/console-kit/go.sh"' "$WT")" "$HR"

# ---- console-O NO-GO round 2: the exemption must not survive a re-point ------
# A `$HIMMEL_REPO` re-point earlier in the SAME command, any wrapper, or any
# separator must still deny - the exemption is sound only when HIMMEL_REPO
# is the command's sole reference to itself, on a genuinely single simple
# command (finding 1). A quoted or backslash-escaped `$HIMMEL_REPO` never
# expands either, so it must deny too, decided from the RAW command text,
# never the quote-stripped one (finding 2).
# shellcheck disable=SC2016 # the literal `$HIMMEL_REPO` text, never expanded here
run 'HIMMEL_REPO re-pointed with export; before the literal prefix -> deny' 2 \
    "$(payload 'export HIMMEL_REPO=.; bash "$HIMMEL_REPO/scripts/cr/pr-check-context.sh"' "$WT")" "$HR"
# shellcheck disable=SC2016 # the literal `$HIMMEL_REPO` text, never expanded here
run 'bare HIMMEL_REPO=. before the literal prefix -> deny' 2 \
    "$(payload 'HIMMEL_REPO=.; bash "$HIMMEL_REPO/scripts/cr/pr-check-context.sh"' "$WT")" "$HR"
# shellcheck disable=SC2016 # the literal `$HIMMEL_REPO` text, never expanded here
run 'env HIMMEL_REPO=. wrapper around the literal prefix -> deny' 2 \
    "$(payload "env HIMMEL_REPO=. bash -c 'bash \"\$HIMMEL_REPO/scripts/cr/pr-check-context.sh\"'" "$WT")" "$HR"
# shellcheck disable=SC2016 # the literal `$HIMMEL_REPO` text, never expanded here
run 'source before the literal prefix (compound) -> deny' 2 \
    "$(payload 'source /dev/null; bash "$HIMMEL_REPO/scripts/handover/merge-on-green.sh"' "$WT")" "$HR"
# shellcheck disable=SC2016 # the literal `$HIMMEL_REPO` text, never expanded here
run "single-quoted \$HIMMEL_REPO never expands -> deny" 2 \
    "$(payload 'bash '"'"'$HIMMEL_REPO/scripts/cr/pr-check-context.sh'"'"'' "$WT")" "$HR"
# shellcheck disable=SC2016 # the literal `$HIMMEL_REPO` text, never expanded here
run 'backslash-escaped $HIMMEL_REPO never expands -> deny' 2 \
    "$(payload 'bash \$HIMMEL_REPO/scripts/cr/pr-check-context.sh' "$WT")" "$HR"
# shellcheck disable=SC2016 # the literal `${HIMMEL_REPO:-.}` text, never expanded here
run '${HIMMEL_REPO:-.} default-value form is not the plain prefix -> deny' 2 \
    "$(payload 'bash "${HIMMEL_REPO:-.}/scripts/cr/pr-check-context.sh"' "$WT")" "$HR"
# shellcheck disable=SC2016 # the literal `$HIMMEL_REPO_X` text, never expanded here
run '$HIMMEL_REPO_X is a different variable, not a prefix match -> deny' 2 \
    "$(payload 'bash "$HIMMEL_REPO_X/scripts/cr/pr-check-context.sh"' "$WT")" "$HR"
# shellcheck disable=SC2016 # the literal `$HIMMEL_REPO` text, never expanded here
run 'literal prefix followed by a second scripts/cr/ command -> deny (compound)' 2 \
    "$(payload 'bash "$HIMMEL_REPO/scripts/cr/pr-check-context.sh"; bash scripts/cr/review-round.sh start --branch feat/x' "$WT")" "$HR"

# ---- console-O NO-GO round 3 (F1): a stray quote/backslash ANYWHERE denies ---
# Round 2 only checked the character immediately before the reference; a
# quote or backslash elsewhere in the command still changes how a real
# shell groups tokens even though $flat has already stripped it by the
# time any later check runs. Decided from the raw command, so the
# exemption now requires NO quote or backslash anywhere in it at all.
# shellcheck disable=SC2016 # the literal `$HIMMEL_REPO` text, never expanded here
run "stray single-quote before the dollar, inside double quotes -> deny" 2 \
    "$(payload 'bash "'"'"'$HIMMEL_REPO/scripts/cr/pr-check-context.sh"' "$WT")" "$HR"
# shellcheck disable=SC2016 # the literal `$HIMMEL_REPO` text, never expanded here
run "stray single-quote after the path, same word -> deny" 2 \
    "$(payload 'bash "$HIMMEL_REPO/scripts/cr/pr-check-context.sh'"'"'"' "$WT")" "$HR"
# shellcheck disable=SC2016 # the literal `$HIMMEL_REPO` text, never expanded here
run "stray backslash right before the dollar -> deny" 2 \
    "$(payload 'bash "\$HIMMEL_REPO/scripts/cr/pr-check-context.sh"' "$WT")" "$HR"
# shellcheck disable=SC2016 # the literal `$HIMMEL_REPO` text, never expanded here
run "fully single-quoted \$HIMMEL_REPO never expands -> deny" 2 \
    "$(payload "bash '\$HIMMEL_REPO/scripts/cr/pr-check-context.sh'" "$WT")" "$HR"
# shellcheck disable=SC2016 # the literal `$HIMMEL_REPO` text, never expanded here
run "single-quoted with leading junk before the dollar -> deny" 2 \
    "$(payload "bash 'x \$HIMMEL_REPO/scripts/handover/console-kit/go.sh'" "$WT")" "$HR"
# Console round 4 (evidence request): byte-exact reproductions of the
# original report's probes 4 and 6, built with $'...' ANSI-C quoting so
# no character is reinterpreted along the way - $'...' processes only
# backslash escapes and never expands a $VAR, so $HIMMEL_REPO here stays
# literal text, exactly like every other case in this file.
PROBE4=$'bash \\\'"$HIMMEL_REPO/scripts/cr/pr-check-context.sh"'
run 'probe 4: backslash then double-quote before the dollar -> deny' 2 \
    "$(payload "$PROBE4" "$WT")" "$HR"
PROBE6=$'bash \'"$HIMMEL_REPO/scripts/cr/pr-check-context.sh"\''
run 'probe 6: the whole double-quoted prefix wrapped in single quotes -> deny' 2 \
    "$(payload "$PROBE6" "$WT")" "$HR"

# ---- console-O NO-GO round 3 (F2): the tail must resolve as a plain path -----
# A `..` or a second `$` after the exempted prefix must still deny - the
# word must resolve to exactly the anchor's own file, not somewhere else
# the substitution can be steered to.
# shellcheck disable=SC2016 # the literal `$HIMMEL_REPO`/`$PWD` text, never expanded here
run 'traversal plus a second $ after the prefix -> deny' 2 \
    "$(payload 'bash "$HIMMEL_REPO/../../../../../../..$PWD/scripts/cr/pr-check-context.sh"' "$WT")" "$HR"

# ---- console-O NO-GO round 4: the merge-on-green remedy must not loop --------
# F1 denies ANY quote/backslash anywhere in the command, so a leg that reaches
# for the remedy with a quoted argument (`--branch 'x'`) would trip F1 again.
# The remedy text itself must say so, and name a fallback that never needs
# quoting args at all.
run 'quoted arg on the anchored spelling -> deny (would loop without the fix)' 2 \
    "$(payload "bash \"\$HIMMEL_REPO/scripts/handover/merge-on-green.sh\" --branch 'x'" "$WT")" "$HR"
need_in_err "remedy says args must be unquoted" "unquoted"
need_in_err "remedy offers the himmel_dir fallback" "<himmel_dir>/scripts/handover/merge-on-green.sh"

# ---- console-O NO-GO finding 2: go.sh's own sibling-sourced libs -------------
# go.sh sources scripts/lib/go-gate.sh and scripts/lib/handover-path.sh via a
# branch-relative $HERE, so they must be in its GUARDED set too - a byte-equal
# go.sh (+ anchor-handoff.sh) with an edited sibling lib must still deny.
echo ': edited' >>"$WT/scripts/lib/go-gate.sh"
run "go-gate.sh edited, go.sh clean -> deny" 2 "$(payload "$GO" "$WT")" "$HR"
need_in_err "deny names go-gate.sh" "scripts/lib/go-gate.sh"
g -C "$WT" checkout -q -- scripts/lib/go-gate.sh
echo ': edited' >>"$WT/scripts/lib/handover-path.sh"
run "handover-path.sh edited, go.sh clean -> deny" 2 "$(payload "$GO" "$WT")" "$HR"
need_in_err "deny names handover-path.sh" "scripts/lib/handover-path.sh"
g -C "$WT" checkout -q -- scripts/lib/handover-path.sh
run "go.sh's sibling libs restored -> allow" 0 "$(payload "$GO" "$WT")" "$HR"
# Sibling-lib edit must not deny an unrelated target (merge-on-green.sh never
# sources these two - it resolves its own helpers from $himmel_repo instead).
echo ': edited' >>"$WT/scripts/lib/go-gate.sh"
run "go-gate.sh edited, merge-on-green unaffected -> allow" 0 "$(payload "$MOG" "$WT")" "$HR"
g -C "$WT" checkout -q -- scripts/lib/go-gate.sh

# Classified by the script they run, not by the text - same spellings the
# scripts/cr/ family is held to.
echo ': edited' >>"$WT/scripts/handover/merge-on-green.sh"
for v in \
    'bash ./scripts/handover/merge-on-green.sh' \
    'bash scripts//handover/merge-on-green.sh' \
    'sh scripts/handover/merge-on-green.sh' \
    'source scripts/handover/merge-on-green.sh' \
    'env bash scripts/handover/merge-on-green.sh' \
    'bash scripts/handover/merge-on-green.s?' \
    'bash scripts/handover/merge-on-green.*'; do
    run "variant [$v] on an edited branch -> deny" 2 "$(payload "$v" "$WT")" "$HR"
done
run "the anchor's absolute path on an edited branch -> no-op" 0 \
    "$(payload "bash \"$PRIMARY/scripts/handover/merge-on-green.sh\"" "$WT")" "$HR"
run "mention (not run) of the edited file -> no-op" 0 \
    "$(payload "git diff -- scripts/handover/merge-on-green.sh" "$WT")" "$HR"
g -C "$WT" checkout -q -- scripts/handover/merge-on-green.sh

# ---- HIMMEL-3433 (d): an interpreter or find -exec word ANYWHERE runs ---------
# On a clean tree, so each deny comes from the shape, not from an edit.
run "2>&1 before the literal, clean root -> deny" 2 \
    "$(payload "2>&1 $LITERAL" "$WT")" "$HR"
run "find -exec env VAR= bash <target>, clean root -> deny" 2 \
    "$(payload "find . -maxdepth 0 -exec env HIMMEL_REPO=/evil bash scripts/cr/review-round.sh +" "$WT")" "$HR"
need_in_err "deny names the wrapper" "wrapper"
run "find -exec VAR= bash <target>, clean root -> deny" 2 \
    "$(payload "find . -maxdepth 0 -exec HIMMEL_REPO=/evil bash scripts/cr/review-round.sh +" "$WT")" "$HR"
run "find -execdir bash <target>, clean root -> deny" 2 \
    "$(payload "find . -maxdepth 0 -execdir bash scripts/cr/pr-check-context.sh +" "$WT")" "$HR"
need_in_err "deny names the directory change" "changes directory"
run "find -exec bash {} from the root, clean root -> deny" 2 \
    "$(payload "find . -exec bash {} +" "$WT")" "$HR"
run "find -exec {} (the found file itself), clean root -> deny" 2 \
    "$(payload "find . -perm -100 -exec {} +" "$WT")" "$HR"
run "bash * with the cwd in scripts/cr -> deny" 2 \
    "$(payload "bash *" "$WT/scripts/cr")" "$HR"

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

# ---- C1: spelling variants that must classify to the same guarded script --
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
bash scripts//cr/*
bash scripts/./cr/*
bash scripts/cr/./*
bash ./scripts/cr/*
bash scripts/hooks/../cr/*
bash Scripts/Cr/*
bash scripts/cr/*.sh
cd scripts/cr; bash *
find . -maxdepth 0 -exec bash scripts/cr/pr-check-context.sh {} +
2>&1 bash scripts/cr/pr-check-context.sh
VARIANTS
run "a line continuation inside the name on an edited branch -> deny" 2 \
    "$(payload "bash scripts/cr/pr-check-con\\
text.sh" "$WT")" "$HR"
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
grep -n block scripts/hooks/*.sh 2>/dev/null | head
find . -not -path './node_modules/*' 2>/dev/null
ls docs/* > /tmp/o.txt
rm -rf build/* 2>/dev/null
cat logs/* 2>/dev/null
cp marketplace/plugins/* /tmp/x 2>/dev/null
ls * > /tmp/o.txt
find . -name '*.md' -exec grep -l foo {} +
MENTIONS

# ---- HIMMEL-3517: a target's stem inside an unrelated test-*.sh filename
# must not flag $VAR tokens elsewhere in the same command as unresolved,
# and -execdir with a non-interpreter command word keeps the {} carve-out.
# shellcheck disable=SC2016 # command text, verbatim
run "bash scripts/cr/test-cr-scores.sh \"\$TMP\" -> allow (HIMMEL-3517)" 0 \
    "$(payload 'bash scripts/cr/test-cr-scores.sh "$TMP"' "$WT")" "$HR"
# shellcheck disable=SC2016 # command text, verbatim
run "CR_LEDGER=\$T/l.jsonl bash scripts/cr/test-ledger-append.sh -> allow (HIMMEL-3517)" 0 \
    "$(payload 'CR_LEDGER=$T/l.jsonl bash scripts/cr/test-ledger-append.sh' "$WT")" "$HR"
run "find -execdir grep (non-interpreter) -> allow (HIMMEL-3517)" 0 \
    "$(payload "find . -name '*.md' -execdir grep foo {} \\;" "$WT")" "$HR"

# codex-2 (/pr-check critic panel, Important, 2026-09-23): -execdir's
# next-word check only flagged a WORD that is_target recognized by name -
# an arbitrary path-qualified wrapper (./wrapper) matched neither the
# known-interpreter list nor is_target, so it fell through as "safe" even
# though it runs from find's changed cwd and can itself resolve and execute
# a guarded relative script there. Fixed by treating any path-qualified
# (contains /) next-word as unverifiable, same as a known wrapper -> deny.
run "find -execdir ./wrapper (path-qualified, unrecognized) -> deny (HIMMEL-3517, codex-2)" 2 \
    "$(payload "find . -maxdepth 0 -execdir ./wrapper {} \\;" "$WT")" "$HR"

# codex-1 (/pr-check critic panel round 4, Important, 2026-09-23): a BARE
# (no /) -execdir command word that codex-2's fix above did not deny fell
# through as safe whenever it was neither a known interpreter nor a guarded
# target's own name - an arbitrary PATH executable (randomtool) is exactly
# as unverifiable as a path-qualified wrapper, and it too runs from find's
# changed cwd. Fixed by requiring a bare word to match a SMALL, explicit,
# fixed-behavior read-only allowlist (grep, cat, head, tail, wc, ls, stat,
# file, sha256sum, md5sum) to keep the relaxed {} carve-out; any other bare
# word is now chdir-gated like a path-qualified one -> deny.
run "find -execdir randomtool (bare, unrecognized, not allowlisted) -> deny (HIMMEL-3517, codex-1 round 4)" 2 \
    "$(payload "find . -maxdepth 0 -execdir randomtool {} \\;" "$WT")" "$HR"
run "find -execdir sed -i (never allowlisted) -> deny (HIMMEL-3517, codex-1 round 4)" 2 \
    "$(payload "find . -maxdepth 0 -execdir sed -i s/a/b/ {} \\;" "$WT")" "$HR"

# codex-1 (/pr-check critic panel round 5, Important, 2026-09-23): an
# earlier version of this fix allowlisted sed/awk without -i/--in-place as
# "read-only". That is false - sed's `e` command and awk's `system()` can
# execute an arbitrary command, including a guarded relative script, from
# find's changed cwd with no in-place flag at all. Per the console's ruling
# on K-N431-7980c9b9 (option 2), sed and awk are dropped from the allowlist
# ENTIRELY - they now stay chdir-gated the same as every other bare word,
# in-place or not.
# No scripts/cr/ mention in either payload below - deliberately, so the
# deny can only come from the -execdir chdir-gate itself (same isolation as
# the "randomtool" row above), never from the unrelated direct-mention deny
# path. At the base (round-4) hook, sed/awk without -i/--in-place stayed
# off the chdir gate (is_target("sed"/"awk") is false), so these ALLOWED
# despite sed's `e` command / awk's `system()` being able to execute
# anything - the exact gap codex-1 flagged in round 5.
run "find -execdir sed e (no -i, but sed's e command executes) -> deny (HIMMEL-3517, codex-1 round 5)" 2 \
    "$(payload "find . -maxdepth 0 -execdir sed -n 'e ls' {} \\;" "$WT")" "$HR"
run "find -execdir awk system() (no -i, but system() executes) -> deny (HIMMEL-3517, codex-1 round 5)" 2 \
    "$(payload "find . -maxdepth 0 -execdir awk 'BEGIN{system(\"ls\")}' {} \\;" "$WT")" "$HR"
# Positive controls: the shapes these fixes must NOT widen stay denied.
# shellcheck disable=SC2016 # command text, verbatim
run "control: bash scripts/cr/\$X (real unresolved target) -> still deny" 2 \
    "$(payload 'bash scripts/cr/$X' "$WT")" "$HR"

# Console FINDING 2026-09-23 (K-N431-7980c9b9), fixed by HIMMEL-3546: a
# `sed -i` edit whose SINGLE-QUOTED sed script carries a backtick span naming
# a gate-script stem as markdown-style prose used to deny, because the quote
# strip made that backtick read like a real command substitution. The
# tokenizer now sees the span is quoted and st_sed_args proves the script is
# one `s` command with no `e`/`w` flag, so the script word is dropped as data
# and the command allows. The replacement must be a well-formed `s` command:
# with `/` as the delimiter, an unescaped `/` in the path ends the
# replacement early and leaves garbage flags, which is not provably inert
# and still denies. (Target is a literal path, not $TMP, so the deny is
# provably the backtick-span misread and not the unrelated unresolved-var
# check that a $VAR-suffixed path would also trip.)
run "sed-i backtick span in single-quoted replacement text allows (HIMMEL-3546 quote-aware)" 0 \
    "$(payload "sed -i 's|x|y \`bash scripts/cr/review-round.sh\` z|' handover.md" "$WT")" "$HR" # gnu-ok: fixture text fed to the hook as tool_input.command, never executed
run "control: same span but a malformed s command (unescaped / ends it) -> still deny (HIMMEL-3546)" 2 \
    "$(payload "sed -i 's/x/y \`bash scripts/cr/review-round.sh\` z/' handover.md" "$WT")" "$HR" # gnu-ok: fixture text fed to the hook as tool_input.command, never executed
# ---- HIMMEL-3546: quoted text that is provably inert is data, not a command.
# pr-check-context.sh is branch-edited here; ledger-append.sh is clean.
while IFS= read -r v; do
    run "inert quoted text [$v] on an edited branch -> allow (HIMMEL-3546)" 0 "$(payload "$v" "$WT")" "$HR"
done <<'INERT'
echo 'bash scripts/cr/pr-check-context.sh'
printf '%s\n' 'bash scripts/cr/pr-check-context.sh; x'
grep -E 'a|bash scripts/cr/pr-check-context.sh' docs/a.md
jq 'test("a|b") or .x == "scripts/cr/pr-check-context.sh"' docs/a.md
bash scripts/cr/ledger-append.sh amend --head abc --id codex-1 --set verdict=deferred --deferred-to HIMMEL-3547 --reason "same gap as prior round, already tracked via Jira comment; deferred to S18"
bash scripts/cr/ledger-append.sh --reason 'a|b & c > d'
INERT
# Controls: quoted text that reaches an interpreter, a substitution or a
# second command is not inert - every one still denies.
# HIMMEL-3458: the 2>&1 fd-dup forms stay denied too.
while IFS= read -r v; do
    run "not inert [$v] on an edited branch -> deny (HIMMEL-3546)" 2 "$(payload "$v" "$WT")" "$HR"
done <<'NOTINERT'
echo 'bash scripts/cr/pr-check-context.sh' | bash
cat 'scripts/cr/pr-check-context.sh' | bash
echo 'scripts/cr/pr-check-context.sh' && bash "$_"
bash -c 'bash scripts/cr/pr-check-context.sh'
sh -c 'bash scripts/cr/pr-check-context.sh; true'
eval 'bash scripts/cr/pr-check-context.sh'
bash scripts/cr/pr-check-context.sh 'a;b'
bash scripts/cr/ledger-append.sh "$(bash scripts/cr/pr-check-context.sh)"
bash scripts/cr/ledger-append.sh 'x'; bash scripts/cr/pr-check-context.sh
echo "$(bash scripts/cr/pr-check-context.sh)"
echo "`bash scripts/cr/pr-check-context.sh`"
printf 'VERDICT x' | bash scripts/cr/write-verdicts.sh
bash scripts/cr/ledger-append.sh --reason 'a;b' 2>&1
bash scripts/cr/pr-check-context.sh 2>&1
echo x 2>&1 && bash scripts/cr/pr-check-context.sh
2>&1 bash scripts/cr/pr-check-context.sh
1>&2 bash scripts/cr/pr-check-context.sh
bash scripts/cr/pr-check-context.sh 2>&1 >/dev/null
bash scripts/cr/ledger-append.sh --reason 'x' # ; y
NOTINERT
run "control: find -execdir bash <target> -> still deny" 2 \
    "$(payload "find . -maxdepth 0 -execdir bash scripts/cr/pr-check-context.sh +" "$WT")" "$HR" # gnu-ok: fixture text fed to the hook as tool_input.command, never executed

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
