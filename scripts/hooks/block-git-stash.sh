#!/usr/bin/env bash
# PreToolUse hook for Bash/PowerShell.
#
# HIMMEL-1755: `git stash` is a CROSS-WORKTREE hazard. Every worktree of this
# checkout (~50 of them) shares ONE `refs/stash`, so a stash created in one
# session is popped/dropped by another. Measured twice in a single leg
# (2026-08-12, HIMMEL-1734 P1 chain): a `git stash drop` from one worker
# destroyed a different session's entry, hand-recovered only because it had been
# tagged (`recovered-leg15-graphify-stash`).
#
# Guards the MUTATIONS, not the reads. REFUSED: a bare `git stash` (which git
# treats as `push`, including its option/pathspec forms) and the verbs `push`,
# `save`, `pop`, `drop`, `clear`, `branch`, `store`. ALLOWED: `list`, `show`,
# `apply` (apply leaves the entry in place for its owner), `create` (prints a
# dangling commit, writes no ref) and the VERB-LESS help forms (`git stash -h`,
# `git stash --help`). `git stash push --help` is refused WITH its verb: the
# rule keys on the verb, and a false deny on a help page is the safe direction
# (codex-3 r5).
#
# NOT a hermes/parity_guard floor rule: `parity_guard.py` ports the
# catastrophic/shared-machine terminal shapes, and this is fleet policy about
# ONE checkout's shared ref namespace, not a machine-destroying command.
#
# Hook input arrives on stdin as JSON. Exit codes:
#   0 - allow
#   2 - block; stderr is shown to the model/user
#
# Bypass: set GIT_STASH_OK=1 in the shell that launched the agent. Session-
# sticky; restart without it to re-enable the guard.
set -euo pipefail

# Security hook: any unexpected top-level failure must deny, not fail open as a
# plain rc=1 hook error.
# shellcheck disable=SC2154 # rc is assigned inside the trap string.
trap 'rc=$?; if [ "$rc" != 0 ] && [ "$rc" != 2 ]; then exit 2; fi' EXIT

if [ "${GIT_STASH_OK:-0}" = "1" ]; then
    exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "block-git-stash: jq not on PATH - refusing to evaluate; install jq" >&2
    exit 2
fi

# HIMMEL-2123: bash builtin `read` instead of `$(cat)` drops one spawn per
# call; the three separate `printf | jq` pipelines below (validate + extract
# tool_name + extract command) collapse into ONE jq call via `<<<` (no printf
# fork). The filter reproduces the old two-step semantics (see
# block-destructive-commands.sh's identical shape, HIMMEL-2123, for the
# null/false/malformed-vs-truthy-non-object case analysis this mirrors):
# top-level null/false or unparsable JSON -> jq exits non-zero -> fail-closed;
# anything else -> field access wrapped in `try/catch empty` so a non-object
# top-level value yields empty tool/cmd exactly like the old per-field
# `|| true` fallbacks did. Windows jq.exe writes CRLF, so the embedded "\n"
# separator can arrive as "\r\n" -- strip the stray CR off $tool (same shape
# as require-quiet-run.sh, HIMMEL-2060).
input=""
IFS= read -r -d '' input 2>/dev/null || true
# HIMMEL-2123 RETASK R2123A: empty/whitespace-only stdin must fail CLOSED,
# same as the old `printf | jq -e .` did on it. `read -d ''` on EOF leaves
# $input empty with no error to catch, and `jq <<<""` emits zero values
# with zero errors, so the `if ! result=$(...)` guard below never fires ->
# silent fail-OPEN on a security fence. Catch it here, before jq ever runs.
case "$input" in
    *[![:space:]]*) ;;
    *) echo "block-git-stash: empty/blank stdin - failing closed" >&2; exit 2 ;;
esac
# RETASK R2123A (independent review): a NON-STRING but present
# `command`/`cmd` (e.g. `"command":["git stash drop"]`) made jq's `+` a
# type error, swallowed by `catch empty`, silently blanking tool AND cmd
# and falling through to ALLOW. A `|tostring` fix was tried first but
# rejected: it renders arrays/objects COMPACT, while old's `jq -r` rendered
# them pretty-printed multi-line, and THOSE embedded newlines (folded to
# `;` by cmd_lc below) accidentally created a command-position separator
# that let the match still fire on old -- `tostring` doesn't reproduce
# that fluke (verified: stayed allowed). See block-destructive-commands.sh
# for the full analysis; same fix here: explicitly error (fail closed,
# MORE conservative than old's incidental behavior) when `command`/`cmd`
# is present with a non-string, non-null type -- a shape no real harness
# payload produces.
if ! result=$(jq -r 'if (. == null or . == false) then error("bad-shape") else ((try (.tool_input.command // .tool_input.cmd) catch null) as $c | if ($c != null and ($c|type) != "string") then error("non-string-command") else (((try (.tool_name) catch null) // "" | tostring) + "\n" + ($c // "")) end) end' <<<"$input" 2>/dev/null); then
    echo "block-git-stash: malformed/truncated JSON on stdin - failing closed" >&2
    exit 2
fi
tool="${result%%$'\n'*}"
tool="${tool%$'\r'}"
cmd="${result#*$'\n'}"
case "$tool" in
    Bash|PowerShell|"") ;;
    *) exit 0 ;;
esac

[ -z "$cmd" ] && exit 0

# Lower-case (git subcommands are case-sensitive, but the surrounding grammar is
# matched lower-cased for parity with the sibling guards) and fold newlines to
# ';' so the line-oriented anchors below see one line. HIMMEL-2123: one `tr`
# call (a single SET1/SET2 mapping covers both the case fold and the
# newline/CR fold) instead of two chained `tr` invocations. `printf`, not
# `<<<`, feeds it: several patterns below anchor on `$` and a herestring's
# synthetic trailing newline would fold to an unexpected trailing ';'.
cmd_lc=$(printf '%s' "$cmd" | LC_ALL=C tr '[:upper:]\n\r' '[:lower:];;')

# In-process ERE match, zero spawns per call -- see block-destructive-commands.sh
# for why this is `[[ =~ ]]` and not `grep -Eq` (HIMMEL-1741). The pattern MUST
# stay unquoted on the right of `=~`.
contains() {
    local re="$1"
    [[ $cmd_lc =~ $re ]]
}

# COMMAND-POSITION grammar, copied verbatim from block-destructive-commands.sh
# (shared shape, HIMMEL-851). It is what keeps `grep -rn "git stash drop" src/`
# and a `# git stash` comment ALLOWED: `git` only counts when it is the invoked
# program, i.e. at the start of the command or right after a separator, behind
# an optional bounded prefix of env assignments / launcher wrappers / an
# executable path. The documented residuals are the same ones the sibling
# carries, in BOTH directions and for the same reason -- this is not a shell
# parser: a quoted-payload wrapper (`bash -c "git stash drop"`) is a MISS, and a
# separator inside quoted DATA (`printf 'x; git stash drop'`) reads as a command
# boundary and is a false DENY. The false deny is the safe direction and costs
# one `GIT_STASH_OK=1` at worst. The wrapper set is likewise BOUNDED, not
# exhaustive: `command`/`exec`/`nohup`/`time git stash drop` are misses here
# exactly as `command rm -rf /` is a miss in the sibling — widening this copy
# alone would fork a grammar whose whole value is being identical. Closing any
# of these properly needs the HIMMEL-912 shared tokenizer, not a wider regex.
EXEPFX='["'\'']?([a-z]:)?([^[:space:]|;&`"'\'']*[/\\])?'
ASSIGN='[[:alnum:]_]+=('\''[^'\'']*'\''|"[^"]*"|[^[:space:]|;&]*)'
CMDPOS='(^|[|;&(`])[[:space:]]*(('"$ASSIGN"'|'"$EXEPFX"'(sudo([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*|env([[:space:]]+(-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?|'"$ASSIGN"'))*|cmd(\.exe)?([[:space:]]+/[[:alnum:]]+(:[[:alnum:]]+)?)*[[:space:]]+/c|(powershell|pwsh)(\.exe)?([[:space:]]+-[^[:space:]]+)*[[:space:]]+-c[[:alnum:]]*))[[:space:]]+)*'"$EXEPFX"

# git's own GLOBAL options sit between the program and the subcommand, and both
# `git -C <worktree> stash drop` and `git --git-dir=<d> stash pop` reach the very
# same shared ref -- so the prefix must be stepped over, not treated as a
# mismatch. A run of dash-tokens, each optionally consuming ONE following
# non-dash value (`-C <path>`, `-c <k=v>`, `--git-dir <d>`); the `=` spellings
# need no value token. Generic, no per-option table: it over-consumes at worst
# one benign token, which cannot turn a stash mutation into an allow because the
# verb allow-list below is applied to whatever token lands after `stash`.
#
# GITOPTVAL (codex-2 r4): the value may be QUOTED and then contains spaces --
# `git -c 'foo.bar=a b' stash drop` is a real, executable mutation, and an
# unquoted-only value token stopped at the space, dropped `stash` out of
# position and let it through. Same quoted/unquoted alternation ASSIGN above
# already uses for env assignments; the unquoted branch still refuses a leading
# `-` so it cannot swallow the NEXT option.
#
# SEP, not a bare `[[:space:]]+`, between every token of this rule (HIMMEL-851
# U3 / codex-1 r1): a backslash LINE CONTINUATION is whitespace to the shell,
# and the newline fold above leaves it as a literal `\` in front of the folded
# `;` -- so `git \<newline>stash drop` arrives here as `git \;stash drop` and a
# plain-whitespace separator would miss a real, executable mutation. `;+`
# because on Windows jq's text-mode stdout turns one decoded `\n` into `\r\n`,
# which folds to TWO semicolons. The `\` prefix is required, so a genuine
# `git ; stash` (two separate commands) still does not match.
SEP='([[:space:]]|\\[[:space:]]*;+)+[[:space:]]*'
GITOPTVAL='('\''[^'\'']*'\''|"[^"]*"|[^-[:space:]][^[:space:]]*)'
GITOPTS='('"${SEP}"'-[^[:space:]]+('"${SEP}${GITOPTVAL}"')?)*'
# codex-1 r5: EXEPFX opens with an OPTIONAL quote, so `"git" stash drop` enters
# at command position with the closing quote still in the stream -- and unlike
# the sibling's atoms (whose trailing `[^[:alnum:]_.-]` boundary happens to
# absorb it) this rule needs whitespace next, so the quoted spelling evaded it
# outright (measured: rc=0 here vs rc=2 for `"taskkill"` in the sibling).
# Allow the closing quote explicitly.
GITSTASH="${CMDPOS}"'git(\.exe)?["'\'']?'"${GITOPTS}${SEP}"'stash'

# HIMMEL-2077: `refs/stash` is an ordinary ref, so it is also reachable through
# the low-level plumbing verbs, entirely bypassing the `stash` keyword grammar
# above -- `git update-ref -d refs/stash` drops it (equivalent to `stash
# clear`/`drop`) and `git update-ref refs/stash <sha>` overwrites it
# (equivalent to `stash push`/`store`), same shared-ref hazard either way.
# `git symbolic-ref -d refs/stash` is the same shape for the rarer case of a
# symbolic (rather than direct) ref at that path. Matched the same way as
# GITSTASH (verb at command position, options stepped over), then require
# `refs/stash` to appear later in the SAME clause -- bounded by `[^|;&`]*` so
# it cannot reach across a command separator into unrelated text (a stray
# match there is a false DENY, the guard's documented safe direction).
GITREFVERB="${CMDPOS}"'git(\.exe)?["'\'']?'"${GITOPTS}${SEP}"'(update-ref|symbolic-ref)'
# codex-1 (CR rounds 2+3, HIMMEL-2077): outside quotes, a shell removes a `\`
# before the NEXT character and passes it through literally, AND adjacent
# quoted/unquoted segments with NO separator between them concatenate into
# ONE shell word -- so `refs/sta\sh`, `refs/"stash"`, and `refs/'stash'` all
# reach git as the literal `refs/stash`, while looking different to a
# plain-string match (the same class of evasion SEP already accounts for
# around whitespace). QCHAR is "optional backslash, single-quote, or
# double-quote" -- tolerate one between every character of the literal
# (mirrors what the shell itself collapses); one QCHAR per letter, not a
# blanket repeat, so this stays anchored to the exact literal and cannot
# balloon into matching unrelated text. This is a bounded, pragmatic defense
# against the concrete evasions found so far, NOT a shell parser -- other
# word-concatenation tricks (ANSI-C `$'...'` quoting, brace expansion,
# variable indirection) remain an accepted residual, consistent with this
# file's other documented non-goals (see the CMDPOS comment above).
QCHAR='['\''"\]?'
REFSTASH_LIT="r${QCHAR}e${QCHAR}f${QCHAR}s${QCHAR}/${QCHAR}s${QCHAR}t${QCHAR}a${QCHAR}s${QCHAR}h"
REFSTASH_IN_CLAUSE='[^|;&`]*'"${REFSTASH_LIT}"'([^[:alnum:]_./-]|$)'
# codex-1 (CR round on HIMMEL-2077): `git update-ref --stdin` reads its ref
# commands (`delete refs/stash`, `update refs/stash <sha> ...`) from STDIN
# DATA, not from this argv string, so `printf 'delete refs/stash\n' | git
# update-ref --stdin` puts `refs/stash` on the far side of the `|` --
# outside REFSTASH_IN_CLAUSE's same-clause window -- and the rule above
# never sees it. The batch target is opaque to a command-string regex by
# design, so refuse `--stdin` unconditionally rather than try to peek into
# piped data: false-denying an update-ref --stdin batch that never touched
# refs/stash is the guard's documented safe direction, and nothing in this
# repo uses that flag (verified: no other caller). Same QCHAR tolerance as
# REFSTASH_LIT (codex-1 CR round 3): `--st\din` reaches git as `--stdin`.
STDIN_LIT="-${QCHAR}-${QCHAR}s${QCHAR}t${QCHAR}d${QCHAR}i${QCHAR}n"
GITUPDATEREF_STDIN="${CMDPOS}"'git(\.exe)?["'\'']?'"${GITOPTS}${SEP}"'update-ref[^|;&`]*'"${STDIN_LIT}"'([^[:alnum:]_-]|$)'

# The mutations, matched POSITIVELY in one pass. A two-step
# "matches stash AND NOT matches an allowed verb" would be wrong on a compound
# command: `git stash list; git stash drop` satisfies the allow-check on its
# FIRST clause and would let the drop through. Every alternative below is
# anchored to the text immediately after this occurrence of `stash`, so each
# clause is judged on its own verb.
#
#   1. a named ref-mutating verb. `store` is in the list because it WRITES
#      refs/stash; `create` is deliberately NOT -- it only prints a dangling
#      commit sha and touches no ref, so it stays allowed alongside the reads.
#   2. no verb at all -- which git treats as `git stash push`. "No verb" means
#      end of command, a command separator, a subshell close, a comment, or a
#      REDIRECTION (codex-1 r2: `git stash >/tmp/out`, `git stash 2>&1` and
#      `git stash # note` are all bare stashes, and recognizing only `|;&`
#      let them through). This one canNOT use SEP: a folded continuation is
#      `\;` or (Windows CRLF) `\;;`, and SEP's `;+` would backtrack to leave a
#      trailing `;` that reads as the separator, denying the READ
#      `git stash \<newline>list`. So the continuation form is spelled out with
#      an anchored `$` after `;+`, which forces the whole run to be consumed.
#   3. no verb, only options/pathspec (`git stash -u`, `git stash -m "wip"`,
#      `git stash -- path`): also `push`. The first-letter class excludes `h`,
#      so `git stash -h` / `git stash --help` stay allowed as documentation.
if contains "${GITSTASH}${SEP}"'(push|save|pop|drop|clear|branch|store)([^[:alnum:]_-]|$)' \
    || contains "${GITSTASH}"'[[:space:]]*(($|[|;&#)]|[0-9]*[<>])|\\[[:space:]]*;+[[:space:]]*$)' \
    || contains "${GITSTASH}${SEP}"'(--?[a-gi-z]|--([[:space:]]|$))' \
    || contains "${GITREFVERB}${REFSTASH_IN_CLAUSE}" \
    || contains "${GITUPDATEREF_STDIN}"; then
    cat >&2 <<'DENY'
block-git-stash: git stash MUTATION refused (HIMMEL-1755).

Every worktree of this checkout shares ONE refs/stash, so `push`/`pop`/`drop`/
`clear`/`branch` (and a bare `git stash`) act on entries other live sessions
own -- so does a low-level `update-ref`/`symbolic-ref` against `refs/stash`
directly. This has already destroyed another session's stash twice.

Use one of the sanctioned alternatives instead:
  * a checkpoint snapshot under refs/checkpoints/<slug> (checkpointWorktree --
    already wired into both spawners), which is per-worktree and never shared;
  * just commit on your branch -- a WIP commit is cheap and recoverable;
  * if you need a stash-SHAPED snapshot, take the race-free one:
        git tag wip-<slug> "$(git stash create)"
    `create` writes NO ref, so there is never an entry for another session to
    drop or clear; the tag is the durable handle and
    `git stash apply wip-<slug>` restores it. Both commands are ALLOWED here --
    no escape hatch needed. (`push` then `tag` is NOT equivalent: another
    session can drop the entry between the two.)

Reads stay allowed: `git stash list`, `git stash show`, `git stash apply`.
Bypass (deliberate, session-sticky): launch with GIT_STASH_OK=1.
DENY
    exit 2
fi

exit 0
