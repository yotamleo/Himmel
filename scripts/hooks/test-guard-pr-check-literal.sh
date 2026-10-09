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
# HIMMEL-4609: fixture paths sit under a FIXED leaf, so a random mktemp suffix that
# ends in "cr" can never read as a `cr/` path word to the guard's handover scan.
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/guard-pr-check-literal.XXXXXX")" || { echo "FAIL mktemp"; exit 1; }
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir "$TMP_ROOT/fx" || exit 1
TMP="$(cd "$TMP_ROOT/fx" && pwd -P)"

g() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main -c commit.gpgsign=false "$@"; }

# ---- fixture ---------------------------------------------------------------
ORIGIN="$TMP/origin"
PRIMARY="$TMP/himmel"
WT="$TMP/wt"
mkdir -p "$ORIGIN/scripts/cr" "$ORIGIN/scripts/guardrails" "$ORIGIN/scripts/lib" "$ORIGIN/docs" \
    "$ORIGIN/scripts/handover/console-kit"
g init -q "$ORIGIN"
echo 'echo anchor' >"$ORIGIN/scripts/cr/pr-check-context.sh"
# HIMMEL-3798 codex-1: the sentinel file the guard's himmel_anchor_prefix
# exemption checks for before trusting HIMMEL_REPO's runtime value.
echo 'echo step0' >"$ORIGIN/scripts/cr/pr-check-step0.sh"
echo ': lib' >"$ORIGIN/scripts/guardrails/lib.sh"
echo 'echo env' >"$ORIGIN/scripts/cr/pr-check-env.sh"
echo ': dotenv' >"$ORIGIN/scripts/lib/load-dotenv.sh"
echo ': other lib' >"$ORIGIN/scripts/lib/other.sh"
# HIMMEL-3495: every gate-allowed scripts/cr entry, and the hand-off each sources.
for t in anchor-handoff.sh clear-cr-marker.sh \
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

# codex-1 (round 2 critic panel, HIMMEL-3798): the anchor-prefix exemption
# above trusted the COMMAND TEXT shape alone, never the hook's own actual
# HIMMEL_REPO runtime value - so an unset or empty HIMMEL_REPO (the Git Bash
# hazard main's pr-check.md documents: "$HIMMEL_REPO/..." then resolves to a
# root-relative, user-plantable path) still hit the exemption and allowed.
# shellcheck disable=SC2016 # the literal `$HIMMEL_REPO` text, never expanded here
run 'control: HIMMEL_REPO unset -> anchor-prefix step0 call still denies (HIMMEL-3798 codex-1)' 2 \
    "$(payload 'bash "$HIMMEL_REPO/scripts/cr/pr-check-step0.sh"' "$WT")"
# shellcheck disable=SC2016 # the literal `$HIMMEL_REPO` text, never expanded here
run 'control: HIMMEL_REPO empty -> anchor-prefix step0 call still denies (HIMMEL-3798 codex-1)' 2 \
    "$(payload 'bash "$HIMMEL_REPO/scripts/cr/pr-check-step0.sh"' "$WT")" "HIMMEL_REPO="
# shellcheck disable=SC2016 # the literal `$HIMMEL_REPO` text, never expanded here
run 'HIMMEL_REPO correctly set to the anchor -> step0 call still allows (HIMMEL-3798 codex-1)' 0 \
    "$(payload 'bash "$HIMMEL_REPO/scripts/cr/pr-check-step0.sh"' "$WT")" "$HR"

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

# ---- HIMMEL-1813: deny-on-unresolvable for an env -S mention ---------------
# On a clean tree. $flat drops every backslash, so GNU env -S's \c ("ignore
# the rest") hid the target from the text scan (merge-on-green.shc). An env
# -S command that mentions a target and carries a backslash, '#' or '$' is
# not resolvable by its text, and denies; outside that intersection nothing
# changes.
for v in \
    "env -S 'ARMAUTOMERGE=1 bash scripts/handover/merge-on-green.sh\\c ignored'" \
    "env -S 'ARMAUTOMERGE=1 bash scripts/handover/merge-on-green.sh\\c'" \
    "env -vS 'bash scripts/handover/merge-on-green.sh\\c'" \
    "env --split-string='bash scripts/handover/merge-on-green.sh\\c'" \
    "env -S 'bash scripts/handover/merge-on-green.sh\\t'" \
    "env -S 'bash scripts/handover/merge-on-green.sh#'" \
    "env -S 'bash scripts/cr/clear-cr-marker.sh\\c'" \
    "env -S 'bash scripts/handover/console-kit/go.sh\\c'" \
    "env -S 'ARMAUTOMERGE=1 bash"$'\n'"scripts/handover/merge-on-green.sh\\c'" \
    "env -S 'true;bash scripts/handover/merge-on-green.sh\\c'" \
    "env -S 'true|bash scripts/handover/merge-on-green.sh\\c'" \
    "(env -S 'bash scripts/cr/pr-check-context.sh\\c')" \
    "echo \$(env -S 'bash scripts/cr/pr-check-context.sh\\c')" \
    "\\env -S 'bash scripts/cr/pr-check-context.sh\\c'" \
    "{ env -S 'bash scripts/cr/pr-check-context.sh\\c'; }" \
    "env -u X -S 'bash scripts/handover/merge-on-green.sh\\c'" \
    "env -u 'X Y' -S 'bash scripts/handover/merge-on-green.sh\\c'" \
    "env 'A=1 B' -S 'bash scripts/handover/merge-on-green.sh\\c'" \
    "env \\-S 'bash scripts/handover/merge-on-green.sh\\c'" \
    "env -\\S 'bash scripts/handover/merge-on-green.sh\\c'" \
    "env --split\\-string='bash scripts/handover/merge-on-green.sh\\c'"; do
    run "1813: [$v] clean root -> deny" 2 "$(payload "$v" "$WT")" "$HR"
    need_in_err "1813: [$v] deny names the unresolvable split string" "cannot be fully resolved"
done
# These already deny through an earlier rule (hit=1: the glued word does not
# resolve), which pre-empts the 1813 check; pinned as denies only.
for v in \
    "echo \`env -S 'bash scripts/cr/pr-check-context.sh\\c'\`" \
    "env -S 'bash"$'\v'"scripts/handover/merge-on-green.sh'" \
    "env -S 'bash"$'\f'"scripts/handover/merge-on-green.sh'" \
    "env -S 'bash"$'\r'"scripts/handover/merge-on-green.sh'" \
    "env -S 'bash scripts/handover/merge-\${Z}on-green.sh'" \
    "env -S 'bash scripts/cr/clear-\${Z}cr-marker.sh\\c'" \
    "env -S 'bash scripts/hand\${Z}over/merge-on-green.sh'" \
    "env -S 'bash scripts/c\${Z}r/clear-cr-marker.sh\\c'" \
    "env >|/dev/null -S 'bash scripts/handover/merge-on-green.sh\\c'" \
    "env {fd}>&1 -S 'bash scripts/handover/merge-on-green.sh\\c'"; do
    run "1813: [$v] clean root -> deny" 2 "$(payload "$v" "$WT")" "$HR"
done
# A here-string is a script unless a non-executing reader consumes it.
for v in \
    "source /dev/stdin <<< \"env -S 'bash scripts/handover/merge-on-green.sh\\c'\"" \
    ". /dev/stdin <<< \"env -S 'bash scripts/handover/merge-on-green.sh\\c'\"" \
    "mksh <<< \"env -S 'bash scripts/handover/merge-on-green.sh\\c'\"" \
    "mksh <<< 'echo ok' <<< \"env -S 'bash scripts/handover/merge-on-green.sh\\c'\"" \
    "cat <<< \"env -S 'bash scripts/handover/merge-on-green.sh\\c'\" | bash" \
    "source <(cat <<< \"env -S 'bash scripts/handover/merge-on-green.sh\\c'\")" \
    "<<< x bash <<< \"env -S 'bash scripts/handover/merge-on-green.sh\\c'\""; do
    run "1813: [$v] clean root -> deny" 2 "$(payload "$v" "$WT")" "$HR"
    # HIMMEL-3913: the raw backstop runs first, so a reader/shell here-string that
    # also carries an executor now denies with its message; either is a deny.
    if grep -qF -- "cannot be fully resolved" <<<"$LAST_ERR" || grep -qF -- "can write text to a file" <<<"$LAST_ERR"; then
        echo "PASS 1813: [$v] deny names the unresolvable split string or the 3913/3917 backstop"
    else
        echo "FAIL 1813: [$v] deny names neither message: $LAST_ERR"
        FAILED=$((FAILED + 1))
    fi
done
run "1813: redirect-only here-string (no command word) -> no-op" 0 \
    "$(payload "<<< hello" "$WT")" "$HR"
run "1813/3917: cat of a here-string naming a target -> deny (any <<< beside a target, HIMMEL-3917)" 2 \
    "$(payload "cat <<< \"env -S 'bash scripts/handover/merge-on-green.sh\\c'\"" "$WT")" "$HR"
run "1813: unresolvable env -S with no target mention -> no-op" 0 \
    "$(payload "env -S 'bash scripts/other/x.sh\\c'" "$WT")" "$HR"
run "1813: \${VAR} split of a target name outside env -S -> no-op" 0 \
    "$(payload "echo scripts/c\${Z}r/clear-cr-marker.sh" "$WT")" "$HR"
run "1813: \${VAR} in an env -S string naming no target -> no-op" 0 \
    "$(payload "env -S 'echo \${HOME}/x'" "$WT")" "$HR"
run "1813: \\c in a non-env mention of the target -> no-op" 0 \
    "$(payload "printf '%s\\c' scripts/handover/merge-on-green.sh" "$WT")" "$HR"
run "1813: env grep of a pr-check pattern with a backslash (no -S) -> no-op" 0 \
    "$(payload "env LC_ALL=C grep -n 'pr-check\\|x' docs/a.md" "$WT")" "$HR"
run "1813: the program's own -S-like flag is not env's (git log --stat) -> no-op" 0 \
    "$(payload "env GIT_PAGER=cat git log --stat --grep='pr-check\\|x'" "$WT")" "$HR"

# ---- HIMMEL-4491: env -S inside a nested shell body -----------------------
# A `bash|sh -c <body>` or `eval <words>` body is ONE quoted word to the outer
# tokenizer, so its `env` was never a word env_split_option saw, and the 1813
# deny never fired. Clean root: every deny below is the 1813 message.
while IFS= read -r v; do
    run "4491: [$v] clean root -> deny" 2 "$(payload "$v" "$WT")" "$HR"
    need_in_err "4491: [$v] deny names the unresolvable split string" "cannot be fully resolved"
done <<'NESTEDSPLIT'
bash -c "env -S 'bash scripts/handover/merge-on-green.sh\c'"
sh -c "env -S 'bash scripts/handover/merge-on-green.sh\c'"
eval "env -S 'bash scripts/handover/merge-on-green.sh\c'"
eval env -S 'bash scripts/handover/merge-on-green.sh\c'
bash -c "env -S 'bash scripts/cr/clear-cr-marker.sh\c'"
sh -c "env -S 'bash scripts/cr/clear-cr-marker.sh\c'"
eval "env -S 'bash scripts/cr/clear-cr-marker.sh\c'"
eval env -S 'bash scripts/cr/clear-cr-marker.sh\c'
bash -c "env -S 'bash scripts/handover/console-kit/go.sh\c'"
sh -c "env -S 'bash scripts/handover/console-kit/go.sh\c'"
eval "env -S 'bash scripts/handover/console-kit/go.sh\c'"
eval env -S 'bash scripts/handover/console-kit/go.sh\c'
bash -c "env -S 'bash scripts/cr/pr-check-context.sh\c'"
sh -c "env -S 'bash scripts/cr/pr-check-context.sh\c'"
eval "env -S 'bash scripts/cr/pr-check-context.sh\c'"
eval env -S 'bash scripts/cr/pr-check-context.sh\c'
bash -c "env --split-string='bash scripts/handover/merge-on-green.sh\c'"
bash -c "env --split-string 'bash scripts/handover/merge-on-green.sh\c'"
bash -c 'env -S "bash scripts/handover/merge-on-green.sh\c"'
bash -lc "env -S 'bash scripts/handover/merge-on-green.sh\c'"
bash -e -c "env -vS 'bash scripts/handover/merge-on-green.sh\c'"
/bin/sh -c "\env -S 'bash scripts/handover/merge-on-green.sh\c'"
bash -c "'env' -S 'bash scripts/handover/merge-on-green.sh\c'"
bash -c "true; /usr/bin/env -S 'bash scripts/handover/merge-on-green.sh\c'"
zsh -c "env -S 'bash scripts/handover/merge-on-green.sh\c'"
eval "true; env -S 'bash scripts/handover/merge-on-green.sh\c'"
sh -c "bash -c \"env -S 'bash scripts/handover/merge-on-green.sh\\c'\""
eval "bash -c \"env -S 'bash scripts/handover/merge-on-green.sh\\c'\""
NESTEDSPLIT
# Controls: a nested env -S naming no target, a nested body with no env -S,
# and env -S text in an argument no shell re-reads keep their verdicts.
while IFS= read -r v; do
    run "4491 control: [$v] clean root -> allow" 0 "$(payload "$v" "$WT")" "$HR"
done <<'NESTEDOK'
bash -c "env -S 'bash scripts/other/x.sh\c'"
eval "env -S 'echo hi\c'"
sh -c 'env -S "echo ${HOME}/x"'
bash -c 'bash scripts/cr/pr-check-context.sh'
eval 'bash scripts/cr/pr-check-context.sh'
git commit -m "note: env -S 'bash scripts/handover/merge-on-green.sh\c'"
bash scripts/other/x.sh "env -S 'bash scripts/handover/merge-on-green.sh\c'"
NESTEDOK

# ---- HIMMEL-3913: raw-text backstop - a reader writes text to a file, a later ----
# ---- executor runs it. The tokenizer reads the quoted here-string as inert, so
# ---- only the raw scan can see it. Clean root: every deny below is the backstop's.
while IFS= read -r v; do
    run "3913: [$v] clean root -> deny" 2 "$(payload "$v" "$WT")" "$HR"
    need_in_err "3913: [$v] deny points at the move-into-a-file route" "can write text to a file"
done <<'BACKSTOP'
tee /tmp/f <<< "env -S 'bash scripts/handover/merge-on-green.sh\c'"; bash /tmp/f
cat <<< "env -S 'bash scripts/handover/merge-on-green.sh\c'" > /tmp/f && sh /tmp/f
tee /tmp/f <<< "env -S 'bash scripts/cr/clear-cr-marker.sh\c'"; source /tmp/f
tee /tmp/f <<< "env -S 'bash scripts/cr/clear-cr-marker.sh\c'"; . /tmp/f
tee /tmp/f <<< "env -S 'bash scripts/handover/console-kit/go.sh\c'"; eval "$(cat /tmp/f)"
cat <<< "env -S 'bash scripts/cr/clear-cr-marker.sh\c'" > /tmp/f; exec bash /tmp/f
cat <<< "env -S 'bash scripts/cr/clear-cr-marker.sh\c'" >> /tmp/f; /bin/bash /tmp/f
cat <<< "env -S 'bash scripts/cr/clear-cr-marker.sh\c'" > /tmp/f; env bash /tmp/f
tee /tmp/f <<< "env -S 'bash scripts/cr/clear-cr-marker.sh\c'"; (bash /tmp/f)
tee /tmp/f <<< "env -S 'bash scripts/cr/clear-cr-marker.sh\c'"; if true; then bash /tmp/f; fi
tee /tmp/f <<< 'bash scripts/cr/write-verdicts.sh'; bash /tmp/f
cat() { bash "$@"; }; cat <<< "env -S 'bash scripts/cr/clear-cr-marker.sh\c'"
tee() { sh "$@"; }; tee /tmp/f <<< 'scripts/cr/clear-cr-marker.sh'
function cat { bash "$@"; }; cat <<< "env -S 'bash scripts/cr/clear-cr-marker.sh\c'"
alias cat=bash; cat <<< "env -S 'bash scripts/cr/clear-cr-marker.sh\c'"
tee /tmp/f <<< 'bash scripts/cr/write-verdicts.sh'; </dev/null bash /tmp/f
tee /tmp/f <<< 'bash scripts/cr/write-verdicts.sh'; 2>/dev/null sh /tmp/f
tee /tmp/f <<< 'bash scripts/cr/write-verdicts.sh'; X=1 bash /tmp/f
tee /tmp/f <<< 'bash scripts/cr/write-verdicts.sh'; ! bash /tmp/f
tee /tmp/f <<< 'bash scripts/cr/write-verdicts.sh'; <<< 'a b' bash /tmp/f
tee /tmp/f <<< 'bash scripts/cr/write-verdicts.sh'; "bash" /tmp/f
tee /tmp/f <<< 'bash scripts/cr/write-verdicts.sh'; env -i bash /tmp/f
tee /tmp/f <<< 'bash scripts/cr/write-verdicts.sh'; sudo -E sh /tmp/f
tee /tmp/f <<< 'bash scripts/cr/write-verdicts.sh'; "source" /tmp/f
tee /tmp/f <<< 'bash scripts/cr/write-verdicts.sh'; exec -a x bash /tmp/f
tee /tmp/scripts/cr/f.sh <<< 'bash scripts/cr/write-verdicts.sh'; bash /tmp/scripts/cr/f.sh
tee /tmp/scripts/cr/f.sh <<< 'bash scripts/cr/write-verdicts.sh'; bash /tmp//scripts/cr/f.sh
tee ./scripts/cr/f.sh <<< 'bash scripts/cr/write-verdicts.sh'; bash scripts/cr/f.sh
tee /tmp/f <<< 'bash scripts/cr/write-verdicts.sh'; command -p source /tmp/f
tee /tmp/f <<< 'bash scripts/cr/write-verdicts.sh'; builtin source /tmp/f
tee /tmp/f <<< 'bash scripts/cr/write-verdicts.sh'; ba''sh /tmp/f
tee /tmp/f <<< 'bash scripts/cr/write-verdicts.sh'; b\ash /tmp/f
tee /tmp/f <<< 'bash scripts/cr/write-verdicts.sh'; s""h /tmp/f
BACKSTOP
run "3913: [tee ...<<< then newline then bash] clean root -> deny" 2 \
    "$(payload "tee /tmp/f <<< \"env -S 'bash scripts/handover/merge-on-green.sh\\c'\""$'\n'"bash /tmp/f" "$WT")" "$HR"
need_in_err "3913: newline form deny points at the move-into-a-file route" "can write text to a file"
run "3913: [cat <<< > f then newline then . f] clean root -> deny" 2 \
    "$(payload "cat <<< \"env -S 'bash scripts/cr/clear-cr-marker.sh\\c'\" > /tmp/f"$'\n'". /tmp/f" "$WT")" "$HR"
# A variable-named write target is invisible to the backstop, but the parser still
# refuses an absolute path outside the root, so the run half denies (rc only).
run "3913: [variable write target then run of an outside scripts/cr path] clean root -> deny" 2 \
    "$(payload "out=/tmp/scripts/cr/f.sh; tee \"\$out\" <<< 'bash scripts/cr/write-verdicts.sh'; bash /tmp/scripts/cr/f.sh" "$WT")" "$HR"
# The literal allowed spellings, and a mention that nothing runs, stay as they were.
while IFS= read -r v; do
    run "3913: allowed spelling [$v] clean root -> no-op" 0 "$(payload "$v" "$WT")" "$HR"
done <<'BACKSTOP_ALLOW'
bash scripts/handover/console-kit/go.sh GO 1 abc
bash scripts/handover/merge-on-green.sh --jira-transition
bash scripts/cr/write-verdicts.sh --from-file /tmp/v.txt
BACKSTOP_ALLOW
for v in \
    "bash \"$PRIMARY/scripts/handover/merge-on-green.sh\" --jira-transition" \
    "bash \"$PRIMARY/scripts/handover/console-kit/go.sh\" GO 1 abc" \
    "bash \"$PRIMARY/scripts/cr/write-verdicts.sh\" --from-file /tmp/v.txt" \
    "bash \"$PRIMARY/scripts/cr/pr-check-step0.sh\"" \
    "bash \"$PRIMARY/scripts/cr/pr-check-env.sh\" CR_CLAUDE_AGENTS"; do
    run "3913: anchored spelling [$v] clean root -> no-op" 0 "$(payload "$v" "$WT")" "$HR"
done

# ---- HIMMEL-3917: the backstop denies the WRITE CHANNEL, never an executor ------
# No executor is recognised any more, so each row writes with a plain `>` (no
# here-string) and runs the file through something the old executor grammar
# never listed - or never runs it in this command at all (a later tool call).
# Clean root: every deny below is the backstop's.
while IFS= read -r v; do
    run "3917: [$v] clean root -> deny" 2 "$(payload "$v" "$WT")" "$HR"
    need_in_err "3917: [$v] deny is the write-channel backstop's" "can write text to a file"
done <<'CHANNEL'
echo 'bash scripts/cr/write-verdicts.sh' > /tmp/f; command -p source /tmp/f
echo 'bash scripts/cr/write-verdicts.sh' > /tmp/f; builtin source /tmp/f
echo 'bash scripts/cr/write-verdicts.sh' > /tmp/f; exec -a x bash /tmp/f
out=/tmp/f; echo 'bash scripts/cr/write-verdicts.sh' >"$out"; bash "$out"
echo 'bash scripts/cr/write-verdicts.sh' >$F
echo 'bash scripts/cr/write-verdicts.sh' > /tmp/f; eval "$(cat /tmp/f)"
echo 'bash scripts/cr/write-verdicts.sh' > /tmp/f; $(cat /tmp/f)
echo 'bash scripts/cr/write-verdicts.sh' > /tmp/f; xargs -a /tmp/f env
echo 'bash scripts/cr/write-verdicts.sh' > /tmp/f; awk '{system($0)}' /tmp/f
echo 'bash scripts/cr/write-verdicts.sh' > /tmp/f; chmod +x /tmp/f; /tmp/f
echo 'bash scripts/cr/write-verdicts.sh' > /tmp/f; "$SHELL" /tmp/f
echo 'bash scripts/cr/write-verdicts.sh' > /tmp/f; python3 /tmp/f
echo 'bash scripts/cr/write-verdicts.sh' > /tmp/f
echo 'run bash scripts/cr/pr-check-context.sh later' > /tmp/note
printf '%s\n' 'bash scripts/cr/write-verdicts.sh' >> ~/.bashrc
echo 'bash scripts/cr/write-verdicts.sh' &>/tmp/f
echo 'bash scripts/cr/write-verdicts.sh' >&/tmp/f
echo 'bash scripts/cr/write-verdicts.sh' >&2x
>/tmp/f echo 'bash scripts/cr/write-verdicts.sh'
echo 'bash scripts/cr/write-verdicts.sh'->/tmp/f
echo 'bash scripts/cr/write-verdicts.sh'=>/tmp/f
echo 'bash scripts/cr/write-verdicts.sh' >|/tmp/f
echo 'bash scripts/cr/write-verdicts.sh' 1<>/tmp/f
echo 'bash scripts/cr/write-verdicts.sh' > >(cat)
echo 'bash scripts/cr/write-verdicts.sh' >/dev/nullx
echo 'bash scripts/cr/write-verdicts.sh' >/dev/null.d/f
echo 'bash scripts/cr/write-verdicts.sh' >/dev/stdout
echo 'bash scripts/cr/write-verdicts.sh' >/dev/fd/3
echo 'bash scripts/cr/write-verdicts.sh' >/proc/self/fd/1
echo 'bash scripts/cr/write-verdicts.sh' >>/dev/null
echo 'bash scripts/cr/write-verdicts.sh' | t''ee /tmp/f
echo 'bash scripts/cr/write-verdicts.sh' | "tee" /tmp/f
echo 'bash scripts/cr/write-verdicts.sh' | /usr/bin/tee /tmp/f
git commit -m 'fix scripts/cr/review-round.sh -> deny'
CHANNEL
# Writers the backstop does not spell (dd, an ANSI-C-quoted tee) sit in a second
# pipeline segment, which switches both exemptions off: the main path denies.
while IFS= read -r v; do
    run "3917: [$v] other writer beside a target -> deny" 2 "$(payload "$v" "$WT")" "$HR"
done <<'OTHERWRITER'
echo 'bash scripts/cr/write-verdicts.sh' | dd of=/tmp/f
echo 'bash scripts/cr/write-verdicts.sh' | $'t\145e' /tmp/f
OTHERWRITER
# The Results-bullet case the console ruling measured: an arrow in the text of a
# bullet naming a guarded writer denies, and the deny names the remedy.
run "3917: [append-results bullet naming merge-on-green with an arrow] -> deny" 2 \
    "$(payload "bash scripts/handover/console-kit/append-results.sh /tmp/d.md 'MERGED via scripts/handover/merge-on-green.sh -> abc'" "$WT")" "$HR"
need_in_err "3917: arrow deny names the Write-tool remedy" "write it with the Write tool and pass the file"
need_in_err "3917: arrow deny names the arrow remedy" "use '→' / 'to' instead"
# Only an fd dup or a redirect to exactly /dev/null is inert: the backstop stays
# silent on these (the main path decides, as before HIMMEL-3917).
while IFS= read -r v; do
    run "3917: inert redirect [$v] clean root -> no-op" 0 "$(payload "$v" "$WT")" "$HR"
done <<'INERT'
echo 'bash scripts/cr/write-verdicts.sh' 2>&1
echo 'bash scripts/cr/write-verdicts.sh' 2>& 1
echo 'bash scripts/cr/write-verdicts.sh' >&2
echo 'bash scripts/cr/write-verdicts.sh' 3>&-
echo 'bash scripts/cr/write-verdicts.sh' >/dev/null
echo 'bash scripts/cr/write-verdicts.sh' > /dev/null
echo 'bash scripts/cr/write-verdicts.sh' 2>/dev/null
echo 'bash scripts/cr/write-verdicts.sh' 2> /dev/null
echo 'bash scripts/cr/write-verdicts.sh' &>/dev/null
echo 'bash scripts/cr/write-verdicts.sh' &> /dev/null
echo 'bash scripts/cr/write-verdicts.sh' >/dev/null 2>&1
git commit -m 'fix scripts/cr/review-round.sh to deny'
INERT
# A real run with an inert redirect: the main path still refuses it as not one
# simple command (HIMMEL-3458), but the backstop must stay silent.
while IFS= read -r v; do
    run "3917: inert redirect on a run [$v] -> main-path deny" 2 "$(payload "$v" "$WT")" "$HR"
    if grep -qF -- "HIMMEL-3917" <<<"$LAST_ERR"; then
        echo "FAIL 3917: [$v] the write-channel backstop fired on an inert redirect: $LAST_ERR"
        FAILED=$((FAILED + 1))
    else
        echo "PASS 3917: [$v] backstop silent on an inert redirect"
    fi
done <<'INERTRUN'
bash scripts/handover/merge-on-green.sh --jira-transition >/dev/null 2>&1
bash scripts/cr/pr-check-context.sh 2>&1
INERTRUN

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
bash scripts/cr/ledger-append.sh --reason 'a|b & c → d'
INERT
# HIMMEL-3917: a quoted '>' beside a target is a write channel to the raw-text
# backstop even as inert data - the ruled remedy is '→' / 'to' or a file.
run "3917: quoted '>' in a guarded script's argument -> deny" 2 \
    "$(payload "bash scripts/cr/ledger-append.sh --reason 'a|b & c > d'" "$WT")" "$HR"
need_in_err "3917: quoted '>' deny names the arrow remedy" "use '→' / 'to' instead"
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

# ---- HIMMEL-3707: pr-check.md's own 4.6/4.7 item-resolution fence ----------
# The runbook's literal `case "$item_rc" in ... esac` rc-branching fence (base
# pr-check.md 4.6/4.7) denies: the same simple command also mentions
# scripts/handover/ (the resolve-active-item.sh call), which routes it into
# full classification, and the tokenizer there misreads the case subject
# `$item_rc` as an unresolvable writer-path operand. Left denied here on
# purpose - the guard itself is unchanged - because the fix moved this rc
# branching into a script instead (scripts/handover/resolve-active-item-
# report.sh), replacing the fence with the one-line literal in the row below.
# shellcheck disable=SC2016 # the literal `$item_rc`/`$item_dir` text, never expanded here
OLD_ITEM_FENCE='item_rc=0
item_dir=$(bash "'"$PRIMARY"'/scripts/handover/resolve-active-item.sh" --branch '"'"'feat/x'"'"') || item_rc=$?
case "$item_rc" in
    0) printf '"'"'%s\n'"'"' "$item_dir" ;;
    3) echo '"'"'4.6/4.7: no active handover item for feat/x — handover bridges SKIPPED (not a failure)'"'"' ;;
    *) echo "4.6/4.7: resolve-active-item.sh errored (rc=$item_rc) — handover bridges skipped, best-effort" >&2 ;;
esac'
run "base pr-check.md 4.6/4.7 case-fence literal, clean tree -> still denied (HIMMEL-3707, guard unchanged)" 2 \
    "$(payload "$OLD_ITEM_FENCE" "$WT")" "$HR"
need_in_err "deny names the unresolvable operand" "does not resolve to this root's"

# The rewritten pr-check.md 4.6/4.7 literal (HIMMEL-3707 fix): one plain bash
# call, no case statement left for the tokenizer to misread -> allow.
NEW_ITEM_LITERAL='bash "'"$PRIMARY"'/scripts/handover/resolve-active-item-report.sh" --branch '"'"'feat/x'"'"''
run "rewritten pr-check.md 4.6/4.7 one-line wrapper literal, clean tree -> allow" 0 \
    "$(payload "$NEW_ITEM_LITERAL" "$WT")" "$HR"

# ---- HIMMEL-3798 round 3 (Rule 5, "CUT, do not patch"): three rounds of the
# same regex-approximates-bash-grammar mechanism finding a new bypass means
# the mechanism itself is wrong, not the regex. The heredoc and `< <file>`
# acceptance shapes are REMOVED entirely; every one of these must now deny,
# falling back to the pre-existing "not one simple command" check exactly as
# it behaved before HIMMEL-3798 round 1. The sanctioned replacement is
# --from-file <literal-path>, tested further below.
WV_HEREDOC=$(cat <<'ENVELOPE'
bash scripts/cr/write-verdicts.sh prior-blocking --branch 'feat/x' <<'WV_STDIN_EOF'
VERDICT [f1] = agreed
WV_STDIN_EOF
ENVELOPE
)
run "write-verdicts.sh heredoc shape denies post-cut (HIMMEL-3798 round 3)" 2 \
    "$(payload "$WV_HEREDOC" "$WT")" "$HR"

IS_HEREDOC=$(cat <<'ENVELOPE'
bash scripts/cr/impacted-suites.sh --check aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa..bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb <<'IS_STDIN_EOF'
SUITE scripts/hooks/test-foo.sh = PASS
IS_STDIN_EOF
ENVELOPE
)
run "impacted-suites.sh --check heredoc shape denies post-cut (HIMMEL-3798 round 3)" 2 \
    "$(payload "$IS_HEREDOC" "$WT")" "$HR"

WV_EMPTY_HEREDOC=$(cat <<'ENVELOPE'
bash scripts/cr/write-verdicts.sh prior-blocking --branch 'feat/x' <<'WV_STDIN_EOF'
WV_STDIN_EOF
ENVELOPE
)
run "write-verdicts.sh empty heredoc denies post-cut (HIMMEL-3798 round 3)" 2 \
    "$(payload "$WV_EMPTY_HEREDOC" "$WT")" "$HR"

run "write-verdicts.sh via < file redirect denies post-cut (HIMMEL-3798 round 3)" 2 \
    "$(payload "bash scripts/cr/write-verdicts.sh prior-blocking --branch 'feat/x' < /dev/null" "$WT")" "$HR"
run "impacted-suites.sh --check via < file redirect denies post-cut (HIMMEL-3798 round 3)" 2 \
    "$(payload "bash scripts/cr/impacted-suites.sh --check aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa..bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb < /dev/null" "$WT")" "$HR"

# case (ii) is moot post-cut: a heredoc body is never parsed as a heredoc
# body any more, since there is no heredoc-acceptance path left to reach it -
# this shape now denies for the same "not one simple command" reason as any
# other heredoc, not because of what its body mentions.
IS_HEREDOC_MENTIONS=$(cat <<'ENVELOPE'
bash scripts/cr/impacted-suites.sh --check aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa..bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb <<'IS_STDIN_EOF'
SUITE scripts/cr/write-verdicts.sh = BLOCKED denial mentioning scripts/cr/write-verdicts.sh
IS_STDIN_EOF
ENVELOPE
)
run "impacted-suites.sh heredoc body mentions another script's name still denies post-cut (HIMMEL-3798 round 3)" 2 \
    "$(payload "$IS_HEREDOC_MENTIONS" "$WT")" "$HR"

# ---- HIMMEL-3798 round 3: --from-file <literal-path> replaces the cut
# heredoc/redirect shapes. Guard-side: the --from-file VALUE must be a
# single literal token with no shell metacharacters, quotes or globs (the
# guard checks the RAW command text, not the quote-stripped flat form, so a
# quoted metacharacter cannot slip through invisibly). Script-side
# fail-closed validation (missing/symlink/unreadable/empty) is exercised in
# the writer scripts' own test suites, not here - this hook only judges the
# command SHAPE.
run "write-verdicts.sh --from-file with a clean literal path -> allow (HIMMEL-3798 round 3)" 0 \
    "$(payload "bash scripts/cr/write-verdicts.sh prior-blocking --branch 'feat/x' --from-file /tmp/wv-verdicts.txt" "$WT")" "$HR"
run "impacted-suites.sh --check --from-file with a clean literal path -> allow (HIMMEL-3798 round 3)" 0 \
    "$(payload "bash scripts/cr/impacted-suites.sh --check aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa..bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb --from-file /tmp/is-suites.txt" "$WT")" "$HR"
run "control: --from-file value with a trailing ;id denies (HIMMEL-3798 round 3)" 2 \
    "$(payload "bash scripts/cr/write-verdicts.sh prior-blocking --branch 'feat/x' --from-file /tmp/x;id" "$WT")" "$HR"
# shellcheck disable=SC2016 # the literal $(id) text, never expanded here
run "control: --from-file value containing \$(id) denies (HIMMEL-3798 round 3)" 2 \
    "$(payload 'bash scripts/cr/write-verdicts.sh prior-blocking --branch '"'"'feat/x'"'"' --from-file /tmp/x$(id)' "$WT")" "$HR"
run "control: --from-file value with a glob denies (HIMMEL-3798 round 3)" 2 \
    "$(payload "bash scripts/cr/write-verdicts.sh prior-blocking --branch 'feat/x' --from-file /tmp/*.txt" "$WT")" "$HR"
run "control: quoted --from-file value denies, unquoted-literal only (HIMMEL-3798 round 3)" 2 \
    "$(payload 'bash scripts/cr/write-verdicts.sh prior-blocking --branch '"'"'feat/x'"'"' --from-file "/tmp/wv-verdicts.txt"' "$WT")" "$HR"

# case (iii): a plain node .../jira call whose --summary happens to mention a
# writer's name never reaches this hook's runner detection at all (no bash/sh
# interpreter word, no scripts/cr candidate as the command word) - allow,
# unaffected by this fix; this hook is not what denies that shape in
# production (a different hook, block-jira-compound-write.sh, is).
run "node jira --summary mentions a writer's name -> allow, not this hook's concern (HIMMEL-3798)" 0 \
    "$(payload "node $PRIMARY/scripts/jira/dist/index.js create --type Bug --summary 'guard denies scripts/cr/write-verdicts.sh heredoc'" "$WT")" "$HR"

# ---- controls: must stay denied ---------------------------------------------
run "control: pipe into write-verdicts.sh still denies (HIMMEL-3798)" 2 \
    "$(payload "printf '' | bash scripts/cr/write-verdicts.sh prior-blocking --branch 'feat/x'" "$WT")" "$HR"
run "control: pipe into impacted-suites.sh --check still denies (HIMMEL-3798)" 2 \
    "$(payload "printf '' | bash scripts/cr/impacted-suites.sh --check aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa..bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "$WT")" "$HR"
# shellcheck disable=SC2016 # the literal `$X` text inside the payload, never expanded here
run "control: \$VAR path with a heredoc still denies (HIMMEL-3798)" 2 \
    "$(payload 'X="scripts/cr/write-verdicts.sh"; bash "$X" prior-blocking --branch feat/x <<'"'"'WV_STDIN_EOF'"'"'
VERDICT [f1] = agreed
WV_STDIN_EOF' "$WT")" "$HR"
# shellcheck disable=SC2016 # the literal `$F` text inside the payload, never expanded here
run "control: \$VAR redirect file still denies (HIMMEL-3798)" 2 \
    "$(payload 'F=/dev/null; bash scripts/cr/write-verdicts.sh prior-blocking --branch feat/x < "$F"' "$WT")" "$HR"
run "control: trailing command after the heredoc closes still denies (HIMMEL-3798)" 2 \
    "$(payload "$WV_HEREDOC"'
rm -rf /' "$WT")" "$HR"
run "control: trailing command after the redirect target still denies (HIMMEL-3798)" 2 \
    "$(payload "bash scripts/cr/write-verdicts.sh prior-blocking --branch 'feat/x' < /dev/null; rm -rf /" "$WT")" "$HR"

# codex-2 (round 2 critic panel, HIMMEL-3798): the unquoted redirect-file
# alternative did not exclude shell separators, so a trailing `;id` etc. was
# captured as part of the "filename" and passed validation - the guard
# classified a two-command line as one simple redirect, letting the second
# command run unguarded. Each of these must deny.
run "control: redirect file with trailing ;id still denies (HIMMEL-3798 codex-2)" 2 \
    "$(payload "bash scripts/cr/write-verdicts.sh prior-blocking --branch 'feat/x' < /dev/null;id" "$WT")" "$HR"
run "control: redirect file with trailing &&id still denies (HIMMEL-3798 codex-2)" 2 \
    "$(payload "bash scripts/cr/write-verdicts.sh prior-blocking --branch 'feat/x' < /dev/null&&id" "$WT")" "$HR"
run "control: redirect file with trailing |id still denies (HIMMEL-3798 codex-2)" 2 \
    "$(payload "bash scripts/cr/write-verdicts.sh prior-blocking --branch 'feat/x' < /dev/null|id" "$WT")" "$HR"
run "control: redirect file with trailing ) still denies (HIMMEL-3798 codex-2)" 2 \
    "$(payload "bash scripts/cr/write-verdicts.sh prior-blocking --branch 'feat/x' < /dev/null)" "$WT")" "$HR"
run "control: redirect file with trailing >g still denies (HIMMEL-3798 codex-2)" 2 \
    "$(payload "bash scripts/cr/write-verdicts.sh prior-blocking --branch 'feat/x' < /dev/null>g" "$WT")" "$HR"
# shellcheck disable=SC2016 # the literal backtick-id-backtick text, never expanded here
run "control: redirect file with trailing backtick-id-backtick still denies (HIMMEL-3798 codex-2)" 2 \
    "$(payload 'bash scripts/cr/write-verdicts.sh prior-blocking --branch '"'"'feat/x'"'"' < /dev/null`id`' "$WT")" "$HR"
# shellcheck disable=SC2016 # the literal $(id) text, never expanded here
run "control: redirect file with trailing \$(id) still denies (HIMMEL-3798 codex-2)" 2 \
    "$(payload 'bash scripts/cr/write-verdicts.sh prior-blocking --branch '"'"'feat/x'"'"' < /dev/null$(id)' "$WT")" "$HR"
# codex-1 (round 3 critic panel, HIMMEL-3798): the line1 regexes' exclusion
# class [^;&|()<>`] does not exclude '#'. A '#' starting a new word makes
# real bash treat everything from there to end-of-line as a COMMENT, so bash
# never parses the trailing <<'WV_STDIN_EOF'/<<'IS_STDIN_EOF' as a heredoc
# redirect at all - yet the guard's regex still matches the line as a valid
# heredoc header. With no real heredoc, the "body" lines that follow in $cmd
# are not swallowed as stdin data: bash parses them as SEPARATE COMMANDS,
# so a $(...) on one of those lines is executed for real. Each of these
# must deny.
WV_COMMENT_SWALLOWS_HEREDOC=$(cat <<'ENVELOPE'
bash scripts/cr/write-verdicts.sh prior-blocking --branch 'feat/x' # <<'WV_STDIN_EOF'
VERDICT [f1] = $(id)
WV_STDIN_EOF
ENVELOPE
)
run "control: '#' before <<'WV_STDIN_EOF' swallows the heredoc op, still denies (HIMMEL-3798 codex-1)" 2 \
    "$(payload "$WV_COMMENT_SWALLOWS_HEREDOC" "$WT")" "$HR"
IS_COMMENT_SWALLOWS_HEREDOC=$(cat <<'ENVELOPE'
bash scripts/cr/impacted-suites.sh --check aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa..bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb # <<'IS_STDIN_EOF'
SUITE $(id)
IS_STDIN_EOF
ENVELOPE
)
run "control: '#' before <<'IS_STDIN_EOF' swallows the heredoc op, still denies (HIMMEL-3798 codex-1)" 2 \
    "$(payload "$IS_COMMENT_SWALLOWS_HEREDOC" "$WT")" "$HR"
# Same exclusion gap on the file-redirect regexes: a trailing '#' before the
# ` < <file>` should not be able to swallow the redirect either (defense in
# depth - no trailing extra command follows here, but the exclusion class
# should be consistent across both alternatives).
run "control: '#' before < file redirect still denies (HIMMEL-3798 codex-1)" 2 \
    "$(payload "bash scripts/cr/write-verdicts.sh prior-blocking --branch 'feat/x' # < /dev/null" "$WT")" "$HR"

# A worktree whose write-verdicts.sh copy differs from the anchor's still
# denies at the existing byte-equality tail, unaffected by this fix. Vehicle
# switched from the (now pre-empted) heredoc shape to a clean --from-file
# invocation post-cut (HIMMEL-3798 round 3): a heredoc now denies earlier, at
# the unconditional "not one simple command" fallback, before ever reaching
# the byte-equality check this control means to exercise.
echo tampered >>"$WT/scripts/cr/write-verdicts.sh"
run "control: --from-file shape on a tampered worktree copy still denies (HIMMEL-3798)" 2 \
    "$(payload "bash scripts/cr/write-verdicts.sh prior-blocking --branch 'feat/x' --from-file /tmp/wv-verdicts.txt" "$WT")" "$HR"
need_in_err "deny names the byte mismatch, not the shape" "differs from the HIMMEL_REPO anchor's"
g -C "$WT" checkout -q -- scripts/cr/write-verdicts.sh

# ---- HIMMEL-4367 item 5: only a command that can run a target is judged -----
# On an edited branch, so every deny control below would run edited bytes. A
# brace group with no comma and no `..` is literal text to bash ({url}), never
# a brace list; a quoted-delimiter heredoc read only by a data reader is data
# when nothing outside the bodies can run a file.
echo 'echo edited-4367' >>"$WT/scripts/cr/pr-check-context.sh"
while IFS= read -r v; do
    run "HIMMEL-4367 no target run [$v] -> allow" 0 "$(payload "$v" "$WT")" "$HR"
done <<'ALLOW4367'
ssh -p 2222 h 'bash vm-run-local.sh camofox "python3 local_adapters.py camofox {url}"'
bash -c 'echo {name} done'
ALLOW4367
H4367_PY=$(cat <<'ENVELOPE'
python3 - <<'EOF'
import os
s = "a" * 3
exec("print(s)")
print({k: v for k, v in {}.items()})
EOF
ENVELOPE
)
run "HIMMEL-4367 python3 heredoc with '*' and exec stays judged (python runs its body) -> deny" 2 "$(payload "$H4367_PY" "$WT")" "$HR"
H4367_CD_PY=$(cat <<'ENVELOPE'
cd /tmp && python3 - <<'PY'
import glob
print(glob.glob('*/node_modules/*'))
PY
ENVELOPE
)
run "HIMMEL-4367 cd + python3 heredoc with a */ glob stays judged (python runs its body) -> deny" 2 "$(payload "$H4367_CD_PY" "$WT")" "$HR"
H4367_CAT=$(cat <<'ENVELOPE'
cat > /tmp/rows.txt <<'EOF'
echo x | xargs -I{} sh -c 'y {}'
ls *
EOF
ENVELOPE
)
run "HIMMEL-4367 cat heredoc of shell text to a file stays judged (a later call can run it) -> deny" 2 "$(payload "$H4367_CAT" "$WT")" "$HR"
# Deny controls: a shell reads the body, the body names a target, a runner
# sits outside the body, the body is live, or a brace list is real.
while IFS= read -r v; do
    run "HIMMEL-4367 control [$v] -> deny" 2 "$(payload "$v" "$WT")" "$HR"
done <<'DENY4367'
bash scripts/c{r,}/pr-chec{k,}-context.sh
bash scripts/cr/pr-che{c..c}k-context.sh
bash scripts/cr/{pr-check-context.sh}
find . -exec bash {} +
cd scripts/cr; bash *
DENY4367
for body in \
    'bash <<'\''EOF'\''' \
    'sh -s <<'\''EOF'\''' \
    'ssh h <<'\''EOF'\''' \
    'at now <<'\''EOF'\''' \
    'cat <<'\''EOF'\'' | bash'; do
    v="$body"$'\n''bash scripts/c[r]/pr-chec[k]-context.sh'$'\n''EOF'
    run "HIMMEL-4367 control [$body + glob target body] -> deny" 2 "$(payload "$v" "$WT")" "$HR"
done
v='cat > /tmp/f <<'\''EOF'\'''$'\n''bash scripts/c[r]/pr-chec[k]-context.sh'$'\n''EOF'$'\n''bash /tmp/f'
run "HIMMEL-4367 control [cat body to a file, then bash it] -> deny" 2 "$(payload "$v" "$WT")" "$HR"
# shellcheck disable=SC2016 # the $( ) is payload text, not for this shell
v='python3 - <<EOF'$'\n''$(bash scripts/c[r]/pr-chec[k]-context.sh)'$'\n''EOF'
run "HIMMEL-4367 control [unquoted heredoc with a live \$( )] -> deny" 2 "$(payload "$v" "$WT")" "$HR"
v='python3 - <<'\''EOF'\'''$'\n''import os; os.system("bash scripts/cr/pr-check-context.sh")'$'\n''EOF'
run "HIMMEL-4367 control [python body naming the target] -> deny" 2 "$(payload "$v" "$WT")" "$HR"
# Outside the body: an unquoted glob that can spell a target, and a python -c
# body (code on the command line, not stdin) beside a decoy heredoc.
v='tee scripts/c?/pr-check-context.sh <<'\''EOF'\'''$'\n''x'$'\n''EOF'
run "HIMMEL-4367 control [tee to a glob target, heredoc input] -> deny" 2 "$(payload "$v" "$WT")" "$HR"
v='python3 -c "import os; os.system('\''bash scripts/c[r]/pr-chec[k]-context.sh'\'')" <<'\''EOF'\'''$'\n''x'$'\n''EOF'
run "HIMMEL-4367 control [python3 -c glob target beside a heredoc] -> deny" 2 "$(payload "$v" "$WT")" "$HR"
# Parent probe of df4e2d33: a heredoc written to a file (a later call can run
# it) or read by an interpreter (python/node run their body as code) is not
# data, and a pattern reader (grep -f -) stays judged.
NL=$'\n'
for v in \
    "cat > /tmp/x.sh <<EOF${NL}bash scripts/c?/clear-cr-marker.sh b${NL}EOF" \
    "tee /tmp/x.sh <<EOF${NL}bash scripts/c[r]/clear-cr-marker.sh b${NL}EOF" \
    "cat <<EOF > /tmp/x.sh${NL}bash scripts/{cr,x}/clear-cr-marker.sh b${NL}EOF" \
    "python3 - <<EOF${NL}import os; os.system('bash scripts/c?/clear-cr-marker.sh b')${NL}EOF" \
    "node - <<EOF${NL}require('child_process').execSync('bash scripts/c?/clear-cr-marker.sh b')${NL}EOF" \
    "grep -f - /tmp/f <<EOF${NL}scripts/c?/clear*${NL}EOF" \
    "cat <<'EOF' | bash${NL}bash scripts/c?/clear-cr-marker.sh b${NL}EOF" \
    "bash scripts/c?/clear-cr-marker.sh b" \
    "echo {url}; bash scripts/c?/clear-cr-marker.sh b" \
    "cat <<EOF${NL}a*b${NL}EOF${NL}bash scripts/c?/clear-cr-marker.sh b"; do
    run "HIMMEL-4367 probe control [${v%%"$NL"*}] -> deny" 2 "$(payload "$v" "$WT")" "$HR"
done
for v in \
    "ssh vm 'curl {url}/x'" \
    "cat <<EOF${NL}print([x*2 for x in range(3)])${NL}EOF"; do
    run "HIMMEL-4367 probe [${v%%"$NL"*}] -> allow" 0 "$(payload "$v" "$WT")" "$HR"
done
g -C "$WT" checkout -q -- scripts/cr/pr-check-context.sh

# HIMMEL-4574: a message argument (gh pr/issue comment|create|edit|review|view,
# the anchor's Jira CLI) is data that mentions a target, not a run of it -
# allowed outside any checkout too.
JIRA_CLI=$PRIMARY/scripts/jira/dist/index.js
for v in \
    'gh pr comment 1 --body "ran: bash scripts/handover/console-kit/go.sh 12 abc"' \
    'gh pr create --title "x" --body "a; bash scripts/cr/clear-cr-marker.sh | b"' \
    "gh issue comment 5 --body 'then bash scripts/cr/write-verdicts.sh sweep'" \
    "node $JIRA_CLI comment HIMMEL-1 \"see bash scripts/cr/clear-cr-marker.sh; then go.sh\""; do
    run "HIMMEL-4574 mention [${v%%"$NL"*}] -> allow" 0 "$(payload "$v" "$TMP")" "$HR"
done
# j2064 NO-GO: printf -v can write BASH_CMDS (rebinding cat/grep to bash) or a
# variable later run by ${x@P} / $[x] arithmetic, and cd can plant a
# $(...) in PWD for ${PWD@P}; so printf, echo and cd are not readers, and a
# heredoc naming a target is never data-only (the first shape would otherwise
# run bash on the body).
# shellcheck disable=SC2016 # the literal `$(...)` text, never expanded here
for v in \
    "printf -v 'BASH_CMDS[cat]' %s /bin/bash; cat scripts/cr/write-verdicts.sh sweep" \
    "printf -v 'BASH_CMDS[grep]' %s /bin/bash; grep scripts/cr/write-verdicts.sh sweep" \
    "printf -v x %s '\$(bash scripts/cr/write-verdicts.sh sweep)'; echo \"\${x@P}\"" \
    "printf -v x %s 'a[\$(bash scripts/cr/write-verdicts.sh sweep)]'; echo \$[x]" \
    "printf -v x %s '\$(bash scripts/cr/write-verdicts.sh sweep)'; cat <<EOF${NL}\${x@P}${NL}EOF" \
    "printf -v 'BASH_CMDS[cat]' %s /bin/bash; cat <<'EOF'${NL}bash scripts/cr/write-verdicts.sh sweep${NL}EOF" \
    "cd '/tmp/\$(bash scripts/cr/write-verdicts.sh)' && echo \"\${PWD@P}\"" \
    "cat <<'EOF'${NL}then run bash scripts/cr/write-verdicts.sh sweep${NL}EOF" \
    "cat <<'EOF' | head -3${NL}run bash scripts/handover/console-kit/go.sh 12 abc${NL}EOF" \
    "node /tmp/x/scripts/jira/dist/index.js comment HIMMEL-1 \"bash scripts/cr/write-verdicts.sh sweep\""; do
    run "HIMMEL-4574 j2064 control [${v%%"$NL"*}] -> deny" 2 "$(payload "$v" "$TMP")" "$HR"
done
# A list or pipeline of readers (grep, cat, sed with inert scripts, git
# grep/log/show/diff, ...) runs nothing, whatever its patterns and file
# operands name.
for v in \
    "grep -n 'write-verdicts\\|ledger-append.sh' .claude/commands/pr-check.md | head -30" \
    'grep -nE "avail --branch|--status ok" /x/.claude/commands/pr-check.md | head -12' \
    'cat scripts/cr/write-verdicts.sh | wc -l' \
    'grep -n x scripts/cr/*.sh 2>/dev/null | cut -c1-80' \
    'sed -n 60,96p scripts/cr/write-verdicts.sh; sed -n 1,9p scripts/cr/clear-cr-marker.sh' \
    'git grep -n "bash scripts/cr/write-verdicts.sh" -- docs | head' \
    'git log --oneline -3 -- scripts/handover/console-kit/go.sh' \
    'git show HEAD:scripts/cr/clear-cr-marker.sh | head -5'; do
    run "HIMMEL-4574 readers [$v] -> allow" 0 "$(payload "$v" "$TMP")" "$HR"
done
# ... and a runner after or among the readers, a reader's output written to a
# file, a substitution, and git grep's -O (it runs its argument on the matched
# files) keep the classification.
# shellcheck disable=SC2016 # the literal `$(...)` text, never expanded here
for v in \
    'grep -n x scripts/cr/write-verdicts.sh | bash' \
    'cat scripts/cr/write-verdicts.sh | sh' \
    'grep -l x scripts/cr/*.sh | xargs bash' \
    'cat scripts/cr/write-verdicts.sh; bash scripts/cr/write-verdicts.sh sweep' \
    'cat scripts/cr/write-verdicts.sh 2>/tmp/f' \
    'cat "$(bash scripts/cr/write-verdicts.sh)"' \
    'git grep -O bash -e x -- scripts/cr/write-verdicts.sh' \
    'git grep -O bash -e x -- scripts/cr/write-verdicts.sh | head' \
    'rg --pre bash x scripts/cr/write-verdicts.sh'; do
    run "HIMMEL-4574 readers control [$v] -> deny" 2 "$(payload "$v" "$TMP")" "$HR"
done
# ... but the same text piped or substituted into an interpreter, a real
# separator outside the quotes, a non-message gh/node, a VAR= prefix, a write
# and git commit's message (it lands in .git/COMMIT_EDITMSG; -F is the remedy)
# all stay denied. The python3 heredoc is a deliberate keep: python runs its
# body as code.
# shellcheck disable=SC2016 # the literal `$(...)` text, never expanded here
for v in \
    "cat <<'EOF' | bash${NL}bash scripts/cr/write-verdicts.sh sweep${NL}EOF" \
    "cat <<'EOF' | sh${NL}bash scripts/cr/write-verdicts.sh sweep${NL}EOF" \
    "cat <<'EOF' | xargs bash${NL}scripts/cr/write-verdicts.sh${NL}EOF" \
    "bash -c \"\$(cat <<'EOF'${NL}bash scripts/cr/write-verdicts.sh sweep${NL}EOF${NL})\"" \
    "eval \"\$(cat <<'EOF'${NL}bash scripts/cr/write-verdicts.sh sweep${NL}EOF${NL})\"" \
    "cat <<'EOF'; bash scripts/cr/write-verdicts.sh sweep${NL}x${NL}EOF" \
    "python3 - <<'EOF'${NL}print('bash scripts/handover/console-kit/go.sh 1 abc')${NL}EOF" \
    "cat > /tmp/x.md <<'EOF'${NL}then run bash scripts/cr/write-verdicts.sh sweep${NL}EOF" \
    'gh pr comment 1 --body "x"; bash scripts/cr/write-verdicts.sh sweep' \
    'gh pr comment 1 --body "x" | bash scripts/cr/write-verdicts.sh sweep' \
    'gh pr comment 1 --body "a; bash scripts/cr/write-verdicts.sh" | sh' \
    'gh pr comment 1 --body "a; bash scripts/cr/write-verdicts.sh" | xargs' \
    'gh pr comment 1 --body "$(bash scripts/cr/write-verdicts.sh sweep)"' \
    'gh pr comment 1 --body "bash scripts/cr/write-verdicts.sh" > /tmp/f' \
    'eval "gh pr comment 1 --body x; bash scripts/cr/write-verdicts.sh"' \
    'node -e "require(1)" "bash scripts/cr/write-verdicts.sh"' \
    'node /tmp/evil.js comment X "bash scripts/cr/write-verdicts.sh"' \
    'X=1 gh pr comment 1 --body "bash scripts/cr/write-verdicts.sh"' \
    'git commit -m "fix: x; bash scripts/cr/write-verdicts.sh"'; do
    run "HIMMEL-4574 control [${v%%"$NL"*}] -> deny" 2 "$(payload "$v" "$TMP")" "$HR"
done

# HIMMEL-4916: staging/pathspec operands mention a changed policy file;
# exempting a git segment must never exempt an executor beside or inside it.
echo ': changed policy' >>"$WT/scripts/cr/pr-check-env.sh"
for v in \
    'git add scripts/cr/pr-check-env.sh docs/a.md' \
    "git -C $WT add -- scripts/cr/pr-check-env.sh docs/a.md" \
    '/usr/bin/git add scripts/cr/pr-check-env.sh docs/a.md' \
    'git restore --staged scripts/cr/pr-check-env.sh' \
    'git diff -- scripts/cr/pr-check-env.sh' \
    'git rm --cached scripts/cr/pr-check-env.sh' \
    'git log -- scripts/cr/pr-check-env.sh' \
    'git show HEAD:scripts/cr/pr-check-env.sh' \
    'git add "scripts/cr/pr-check-env.sh" docs/a.md' \
    'git add -- -config.md scripts/cr/pr-check-env.sh' \
    'git diff -- --ext-diff scripts/cr/pr-check-env.sh' \
    'git diff --name-only -- scripts/cr/pr-check-env.sh' \
    'git diff --name-status -- scripts/cr/pr-check-env.sh' \
    'git log --follow -- scripts/cr/pr-check-env.sh' \
    'git diff -w -- scripts/cr/pr-check-env.sh' \
    'git diff --stat=80 -- scripts/cr/pr-check-env.sh'; do
    run "HIMMEL-4916 pathspec [$v] -> allow" 0 "$(payload "$v" "$WT")" "$HR"
done
# shellcheck disable=SC2016 # literal attack payloads, never expanded here
for v in \
    'bash scripts/cr/pr-check-env.sh' \
    'git add x && bash scripts/cr/pr-check-env.sh' \
    "git -c alias.x='!bash scripts/cr/pr-check-env.sh' x" \
    'git add $(bash scripts/cr/pr-check-env.sh)' \
    'git add <(bash scripts/cr/pr-check-env.sh)' \
    'git add x | xargs bash scripts/cr/pr-check-env.sh' \
    "env -S 'bash scripts/cr/pr-check-env.sh'" \
    'git --exec-path=scripts/cr/pr-check-env.sh add x' \
    'git -c core.hooksPath=scripts/cr/pr-check-env.sh add x' \
    "git -c filter.x.clean='bash scripts/cr/pr-check-env.sh' add x" \
    "git -c filter.x.smudge='bash scripts/cr/pr-check-env.sh' restore x" \
    "git -c diff.x.textconv='bash scripts/cr/pr-check-env.sh' show HEAD:x" \
    'git --config-env=core.pager=RUN show scripts/cr/pr-check-env.sh' \
    'git diff --ext-diff -- scripts/cr/pr-check-env.sh' \
    'git diff --upload-pack=scripts/cr/pr-check-env.sh x' \
    'git log ext::scripts/cr/pr-check-env.sh' \
    'git grep -O bash -- scripts/cr/pr-check-env.sh' \
    'git grep -e -- -O bash -- scripts/cr/pr-check-env.sh' \
    'git diff -S -- --ext-diff scripts/cr/pr-check-env.sh'; do
    run "HIMMEL-4916 exec control [$v] -> deny" 2 "$(payload "$v" "$WT")" "$HR"
done
# HIMMEL-4950: a brace- or glob-expanded option word before a guarded pathspec
# can expand into an exec-capable git option; the early expansion return in
# git_mentions_only must flag it unsafe, not let it pass as a mention.
# shellcheck disable=SC2016 # literal attack payloads, never expanded here
for v in \
    'git grep -O{bash,x} -- scripts/cr/pr-check-env.sh' \
    'git grep --open-files-in-pager={bash,x} -- scripts/cr/pr-check-env.sh' \
    'git log -p --ext-d{iff,iff} -- scripts/cr/pr-check-env.sh' \
    'git diff --ext-di?f -- scripts/cr/pr-check-env.sh' \
    'git grep -e echo$IFS-O{x,bash} -- scripts/cr/pr-check-env.sh' \
    'git grep -e echo$IFS-Obash -- scripts/cr/pr-check-env.sh' \
    'git log HEAD$IFS--output=scripts/cr/pr-check-env.sh -- scripts/cr/pr-check-env.sh' \
    'git grep -e echo${=IFS}-Obash -- scripts/cr/pr-check-env.sh' \
    'git grep -e docs/{a,b} -O{bash,x} -- scripts/cr/pr-check-env.sh' \
    'git grep -e docs/{a,b} -Obash -- scripts/cr/pr-check-env.sh'; do
    run "HIMMEL-4950 brace option [$v] -> deny" 2 "$(payload "$v" "$WT")" "$HR"
done
# After --, an expanded operand is a pathspec, not an option: not flagged unsafe.
run "HIMMEL-4950 brace operand after -- keeps prior verdict" 0 \
    "$(payload 'git add -- --foo{a,b} scripts/cr/pr-check-env.sh' "$WT")" "$HR"
# A brace word that is not option-shaped keeps its prior verdict (allow).
run "HIMMEL-4950 non-option brace word keeps prior verdict" 0 \
    "$(payload 'git add docs/{a,b}.md scripts/cr/pr-check-env.sh' "$WT")" "$HR"
# HIMMEL-4953: the git exec/write-option check runs for EVERY git segment and
# fails closed on a bailed walk. Each payload used to exit 0 because
# readers_only returned before it reached the git word.
# shellcheck disable=SC2016 # literal attack payloads, never expanded here
for v in \
    'true; git grep -Obash -- scripts/cr/pr-check-env.sh' \
    'true; git grep -O{bash,x} -- scripts/cr/pr-check-env.sh' \
    'sort | git grep -O{bash,x} -- scripts/cr/pr-check-env.sh' \
    'git grep -O{bash,x} -- scripts/cr/pr-check-env.sh # c' \
    "git grep \$'-O'bash -- scripts/cr/pr-check-env.sh" \
    "git grep \$'-O'{bash,x} -- scripts/cr/pr-check-env.sh" \
    "git grep \$'\\x2dObash' -- scripts/cr/pr-check-env.sh" \
    'git -p grep -Obash -- scripts/cr/pr-check-env.sh' \
    'git -p grep -O{bash,x} -- scripts/cr/pr-check-env.sh' \
    'git --no-pager grep -O{bash,x} -- scripts/cr/pr-check-env.sh' \
    'git {grep,x} -Obash -- scripts/cr/pr-check-env.sh' \
    'case x in x) git grep -Obash -- scripts/cr/pr-check-env.sh ;; esac' \
    'case x in x) git grep -O{bash,x} -- scripts/cr/pr-check-env.sh ;; esac' \
    'git grep -O$(echo bash) -- scripts/cr/pr-check-env.sh' \
    'git grep -O`echo bash` -- scripts/cr/pr-check-env.sh' \
    'git grep -O$((1+1)) -- scripts/cr/pr-check-env.sh' \
    'echo $(true); git grep -Obash -- scripts/cr/pr-check-env.sh' \
    'git grep -e x a$IFS-Obash -- scripts/cr/pr-check-env.sh' \
    'git grep x${=IFS}-Obash -- scripts/cr/pr-check-env.sh' \
    'git log HEAD$IFS--output=scripts/cr/pr-check-env.sh # c' \
    'git grep -e x $(printf %s -Obash) -- scripts/cr/pr-check-env.sh' \
    'git grep -e x "$(printf %s -Obash)" -- scripts/cr/pr-check-env.sh' \
    'git grep -e x `printf %s -Obash` -- scripts/cr/pr-check-env.sh' \
    'git grep -e echo$(printf " ")-Obash -- scripts/cr/pr-check-env.sh' \
    'git grep -e echo`printf " "`-Obash -- scripts/cr/pr-check-env.sh' \
    'git grep -e echo$((IFS=1))-Obash -- scripts/cr/pr-check-env.sh' \
    'G=git; $G grep -Obash -- scripts/cr/pr-check-env.sh' \
    '${G:-git} grep -Obash -- scripts/cr/pr-check-env.sh' \
    '$(echo git) grep -Obash -- scripts/cr/pr-check-env.sh' \
    '$(printf %s g i t) grep -Obash -- scripts/cr/pr-check-env.sh' \
    '$(echo g)it grep -Obash -- scripts/cr/pr-check-env.sh' \
    'g$(echo i)t grep -Obash -- scripts/cr/pr-check-env.sh' \
    'g`echo i`t grep -Obash -- scripts/cr/pr-check-env.sh'; do
    run "HIMMEL-4953 unwalked git segment [$v] -> deny" 2 "$(payload "$v" "$WT")" "$HR"
done
# Pathspec mentions and the HIMMEL-4950 allow cases stay allowed.
for v in \
    'git log -- scripts/cr/pr-check-env.sh' \
    'git log --oneline -- scripts/cr/pr-check-env.sh' \
    'git grep foo -- scripts/cr/pr-check-env.sh' \
    'git diff --cached -- scripts/cr/pr-check-env.sh' \
    'git rm --cached scripts/cr/pr-check-env.sh' \
    'git show HEAD -- scripts/cr/pr-check-env.sh' \
    'git add docs/{a,b}.md scripts/cr/pr-check-env.sh' \
    'git add -- --foo{a,b} scripts/cr/pr-check-env.sh'; do
    run "HIMMEL-4953 control [$v] -> allow" 0 "$(payload "$v" "$WT")" "$HR"
done
# HIMMEL-4958: a directory or empty pathspec matches the guarded scripts
# without naming them; a git exec/write option is denied whatever the pathspec.
# shellcheck disable=SC2016 # literal attack payloads, never expanded here
for v in \
    'git grep -Obash -e . -- scripts/cr/' \
    'git grep -Obash -e .' \
    'git grep -Obash -e . -- scripts/handover/' \
    'git grep --open-files-in-pager=bash -e .' \
    'git -c core.pager=bash grep -e . -- scripts/cr/' \
    'git -c core.pager=bash grep -e .' \
    "git -c alias.x='!bash' x" \
    "git -c alias.x='!bash' x scripts/cr/" \
    'git diff --ext-diff' \
    'git diff --ext-diff -- scripts/cr/' \
    'git log --output=out.txt' \
    'git log --output=out.txt -- scripts/cr/' \
    "git -c diff.x.command=bash diff" \
    'git -c core.PAGER=bash grep -e .' \
    'git --config-env=alias.x=V x' \
    'git --config-env alias.x=V x' \
    'git --config-env=core.pager=V grep -e .' \
    'git log --out=out.txt' \
    'git grep --open=bash -e .' \
    'git grep -cObash -e .'; do
    run "HIMMEL-4958 exec option any pathspec [$v] -> deny" 2 "$(payload "$v" "$WT")" "$HR"
done
for v in \
    'git grep -e . -- scripts/cr/' \
    'git grep -e .' \
    'git log --oneline -3' \
    'git diff --stat' \
    'git diff -Oorderfile' \
    "git -c user.name='pager duty' grep -e ." \
    'git log -Oorderfile --oneline' \
    'git grep --only-matching -e .' \
    'git -c user.name=t -c user.email=t@t commit -m x' \
    'git ls-files --others' \
    'git ls-files --others -- scripts/cr/ scripts/lib/ scripts/check-ci.sh' \
    'git checkout --ours -- docs/x.md' \
    'git rev-list --objects HEAD' \
    'git log --output-indicator-new=+ --oneline' \
    'git -cuser.name=Overlord commit -m x' \
    'git grep --extended-regexp -e .'; do
    run "HIMMEL-4958 control [$v] -> allow" 0 "$(payload "$v" "$WT")" "$HR"
done
# HIMMEL-5095: a capital O after a value-taking short option in a cluster is
# part of that option's value (git's parse-options), not the pager flag.
# shellcheck disable=SC2016 # literal payloads, never expanded here
for v in \
    'git grep -ceFOO' \
    'git grep -eOverflow' \
    'git commit -m"Fix Overflow"' \
    'git commit -mOops' \
    'git commit -CORIG_HEAD' \
    'git commit -tOther' \
    'git merge -sOurs' \
    'git merge -XOurs' \
    'git push -oOpt' \
    'git stash push -mOld' \
    'git checkout -bOld-fix' \
    'git branch -DOld' \
    'git grep --extended' \
    'git grep --extended -e . -- scripts/cr/pr-check-env.sh'; do
    run "HIMMEL-5095 attached O in a value [$v] -> allow" 0 "$(payload "$v" "$WT")" "$HR"
done
for v in \
    'git grep -iO -e x' \
    'git grep -iOe x' \
    'git grep -Obash -e x' \
    'git grep -ciObash -e x' \
    'git grep -ObashO -e x' \
    'git grep -iOe x -- scripts/cr/pr-check-env.sh' \
    'git commit -Obash' \
    'git --namespace add grep -oObash x' \
    'git --namespace rm grep -cObash x' \
    'git --namespace restore grep -FObash x' \
    'git --namespace log grep -Obash x' \
    'git --namespace show grep -Obash x' \
    'git --git-dir=.git --namespace add grep -oObash x' \
    'git --unknown-opt add grep -oObash x'; do
    run "HIMMEL-5095 O before any value letter [$v] -> deny" 2 "$(payload "$v" "$WT")" "$HR"
done
# Accepted over-deny (HIMMEL-4953 judge ruling): any substitution beside a
# guarded mention is unsafe, since it can assemble the git word; split the command.
# shellcheck disable=SC2016 # the $( is literal hook input
run "HIMMEL-4953 accepted over-deny [wc + unrelated substitution] -> deny" 2 \
    "$(payload 'wc -l scripts/cr/pr-check-env.sh; echo $(date)' "$WT")" "$HR"
g -C "$WT" checkout -q -- scripts/cr/pr-check-env.sh

echo
if [ "$FAILED" -eq 0 ]; then
    echo "all guard-pr-check-literal cases passed"
    exit 0
fi
echo "$FAILED guard-pr-check-literal case(s) failed"
exit 1
