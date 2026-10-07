#!/usr/bin/env bash
# guard-leg-context-handoff.sh — PreToolUse hook (matcher "*") and PreCompact
# hook: a console-spawned leg that was launched with the guard ON, once past its
# context threshold, is denied every NON-hand-off tool call, and its
# auto-compaction is refused, until it has checkpointed or handed off
# (HIMMEL-4569). Its job: a pushed checkpoint before a lossy compaction.
# OFF BY DEFAULT (operator ruling 2026-10-07, HIMMEL-4710): legs auto-compact
# anyway, so the guard runs only when the launch turned it on. Reference:
# docs/internals/leg-context-guard.md.
#
# Scope: a console-spawned leg only — HIMMEL_CONSOLE_LEG=1 AND a non-empty
# HIMMEL_CONSOLE_NAME, both exported by headed-arm-leg.sh (HIMMEL-2919,
# HIMMEL-3435). Anything else returns at once with no output. The leg's
# in-process subagents (a non-empty string agent_id) are exempt.
#
# Two modes, HIMMEL_LEG_CONTEXT_MODE, set at launch by
# `headed-arm-leg.sh --context-guard compact|handoff` and read only from this
# hook's own process env, so a leg cannot flip it mid-session (an export or a
# per-call prefix never reaches a hook process). Unset, empty or `none` = the
# guard is off (exit 0, no output); any other unknown value is compact, with
# one stderr line (someone asked for the guard).
#   compact  unlock = a `CHECKPOINT <full sha> pushed` Results bullet
#            whose sha is the worktree's HEAD and equals its upstream, or a
#            `CHECKPOINT <full sha> clean` bullet whose sha is HEAD while the
#            tree is clean and nothing is unpushed (HEAD = its upstream, or
#            HEAD is in origin/main); the session then compacts at its
#            ceiling and carries on.
#   handoff  unlock = a RESUME doc for this leg (the leg stops; a successor
#            resumes from the doc).
# In both modes a last marker of WRAPPED frees the leg. A last marker of
# BLOCKED frees only the hand-off calls and reads (Read, Grep, Glob): BLOCKED
# is a hand-off to the console, not an unlock (N1383 wrote BLOCKED and then
# went on editing, HIMMEL-4710), and while it is the last marker neither
# unlock above reopens ordinary work; a saved state still lets PreCompact pass.
#
# The threshold is 75 % of the leg's autocompact ceiling, not of the model
# window: an opus leg launched with --autocompact 200000 reports a 1000000-token
# window, so the ceiling sits at 20 % fill and a flat % of the window never
# fired. Ceiling = CLAUDE_CODE_AUTO_COMPACT_WINDOW if numeric (it outranks the
# flag), else HIMMEL_LEG_AUTOCOMPACT (the launcher's resolved --autocompact;
# unset = the 200000 pin, `auto` = the window), clamped to the window. The share
# is HIMMEL_LEG_CONTEXT_SHARE (1-100, launch env only; anything else = 75).
# 75 % of 200000 is 150000 tokens (15 % fill on a 1M window). Compactions were
# observed firing from 157k of a 200k ceiling (HIMMEL-4089: 157k-176k over 349
# compactions), so 75 % leaves 7000 tokens (3.5 pp of the ceiling) before the
# earliest one for commit + push + the CHECKPOINT bullet. The deny must land
# BEFORE the earliest compaction: a higher share (85 % = 170000) would let a
# compaction fire first and be refused blind (ruling 2026-10-07). 65 % (130000)
# left 27000 but stopped every opus leg at 13 % fill. More headroom than 7000
# comes from a higher launcher ceiling, an operator decision.
#
# The decision (PreToolUse), in order:
#   1. fill = scripts/context-fill.sh --percent on the hook's transcript_path.
#      Below the threshold -> allow.
#   2. A hand-off call -> allow, always: Write/Edit/MultiEdit of a *-RESUME.md,
#      SendMessage, ListAgents (the preface's name check before a send),
#      ToolSearch (SendMessage is a deferred tool), TaskStop (the wrap reaps
#      background tasks), and a bare `bash <...>/append-results.sh`,
#      `queue-lock.sh release`, `wrap-subtree-check.sh` or `context-fill.sh`,
#      a bare `git [-C <dir>] add|commit|push|status|rev-parse`, and a bare
#      `cd [<dir>]` (a leg whose cwd drifted is checked against the wrong HEAD).
#   3. The leg's own doc is the `.md` path named in the transcript's first user
#      turn — the launcher's `load <brief> and continue`. Its last marker
#      WRAPPED -> allow; BLOCKED -> allow a Read, Grep or Glob only.
#   4. The mode's unlock holds -> allow. A RESUME doc counts when it sits beside
#      the doc, is not the doc itself, carries the doc's leg id (N1364, J1950b
#      ...) with any one-letter suffix, and was modified after this session's
#      first user turn — so an older link of the same chain never counts. A
#      CHECKPOINT counts from the doc's newest CHECKPOINT bullet only.
#   5. Otherwise deny, naming the mode, the fill and exactly what unlocks it.
# PreCompact: a manual /compact passes; an auto one past the threshold passes
# only on steps 3-4, with EITHER unlock (a CHECKPOINT or a RESUME doc).
#
# ponytail: fail-OPEN on every infrastructure gap (fill UNKNOWN or STALE, no
# transcript_path, leg doc not found, no jq, junk stdin, junk ceiling), with one
# stderr line. A false block strands a leg in a window nobody watches, while a
# false allow only costs the pre-hook status quo (the autocompact backstop still
# fires); upgrade path: if the fail-open warnings show up in leg logs, fix the
# probe (HIMMEL-3081, HIMMEL-2342), never flip this to fail-closed.
# ponytail: the Bash hand-off allow-list matches command TEXT and refuses only
# `&&`, `||`, `$(` and newlines — a `;`-chained tail after an allowed script
# slips through, because a bullet's quoted text may itself carry `;`; this is a
# workflow nudge, not a fence (scripts/hooks/CLAUDE.md), and the permission
# matcher already refuses compound shapes; upgrade path: parse the command
# with the shell-word splitter auto-approve-safe-bash.sh uses if a leg abuses it.
# ponytail: a CHECKPOINT proves HEAD was pushed, not that the tree is clean — a
# clean-tree check would re-block every edit made between the checkpoint and the
# compaction it exists to allow; and one still matching HEAD after a compaction
# with no new commit keeps counting; upgrade path: key it to the transcript's
# compact_boundary if a leg is seen coasting on an old checkpoint.
# ponytail: Claude Code does not document what follows a refused auto-compaction
# (retry, error, overflow), which is why the threshold sits below the earliest
# observed compaction and the PreCompact refusal is only the second line, past
# the threshold only (below it the leg was never told to checkpoint); upgrade
# path: measure it on a VM leg (HIMMEL-4710 item 7) and re-derive the share.
#
# Bypass: LEG_CONTEXT_HANDOFF_OK=1 in the launching shell (session-sticky; a
# per-call prefix does not reach this hook process).
#
# Platform guard (gitbash-only): env vars, jq, git, stat -c/-f, sed; bash
# 3.2-safe, runs unchanged under Git Bash. No .ps1 twin needed.
#
# Hook I/O: JSON on stdin. exit 0 = allow, exit 2 = deny (stderr plus, for
# PreToolUse, a structured hookSpecificOutput.permissionDecision on stdout —
# same idiom as guard-leg-wakeup.sh; for PreCompact, {"decision":"block"}).
set -uo pipefail

[ "${HIMMEL_CONSOLE_LEG:-0}" = "1" ] || exit 0
[ -n "${HIMMEL_CONSOLE_NAME:-}" ] || exit 0
[ "${LEG_CONTEXT_HANDOFF_OK:-0}" = "1" ] && exit 0

CEILING_SHARE=75
case "${HIMMEL_LEG_CONTEXT_SHARE:-}" in
    [1-9]|[1-9][0-9]|100) CEILING_SHARE="$HIMMEL_LEG_CONTEXT_SHARE" ;;
esac
PIN_AUTOCOMPACT=200000
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

warn_allow() {
    printf 'guard-leg-context-handoff: allowing - %s (fail-open)\n' "$1" >&2
    exit 0
}

MODE="${HIMMEL_LEG_CONTEXT_MODE:-}"
case "$MODE" in
    ''|none) exit 0 ;;
    compact|handoff) ;;
    *)
        printf 'guard-leg-context-handoff: unknown HIMMEL_LEG_CONTEXT_MODE %s - using compact\n' "$MODE" >&2
        MODE=compact
        ;;
esac

command -v jq >/dev/null 2>&1 || warn_allow "jq not on PATH"

input=$(cat)
# An in-process subagent (worker, judge call) inherits the leg's env and its
# transcript_path, so it would read the parent's fill and be denied too. It is
# never the one to hand off: exempt it, keyed on a NON-EMPTY STRING agent_id
# (the block-subagent-park.sh idiom; `// empty` would read `false` as absent).
if printf '%s' "$input" | jq -e '(.agent_id | type) == "string" and .agent_id != ""' >/dev/null 2>&1; then
    exit 0
fi
event=$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null) || warn_allow "unparseable hook input"
if [ "$event" = "PreCompact" ]; then
    # An operator's own /compact is never refused.
    [ "$(printf '%s' "$input" | jq -r '.trigger // empty' 2>/dev/null)" = "manual" ] && exit 0
    tool=""
else
    tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null) || warn_allow "unparseable hook input"
    [ -n "$tool" ] || warn_allow "no tool_name in hook input"
fi
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
if [ -z "$transcript" ] || [ ! -f "$transcript" ] || [ ! -r "$transcript" ]; then
    warn_allow "no readable transcript_path, context fill unknown"
fi
wd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$wd" ] && [ -d "$wd" ] || wd="$PWD"

fill=$(CONTEXT_FILL_TRANSCRIPT="$transcript" bash "$HERE/../context-fill.sh" --percent 2>/dev/null)
fill_rc=$?
case "$fill_rc:$fill" in
    0:[0-9]|0:[0-9][0-9]|0:100) ;;
    3:*) warn_allow "context fill STALE (context-fill.sh rc 3)" ;;
    *) warn_allow "context fill UNKNOWN (context-fill.sh rc $fill_rc)" ;;
esac

# --- the threshold, as a % of the window, from the autocompact ceiling ------
snap=$(CONTEXT_FILL_TRANSCRIPT="$transcript" bash "$HERE/../context-fill.sh" --cache-path 2>/dev/null)
window=$(jq -r '.context_window_size // empty | floor' "$snap" 2>/dev/null)
case "$window" in ''|*[!0-9]*|0) window="" ;; esac
ceiling=""
case "${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}" in
    ''|*[!0-9]*) ;;
    *) ceiling="$CLAUDE_CODE_AUTO_COMPACT_WINDOW" ;;
esac
if [ -z "$ceiling" ]; then
    case "${HIMMEL_LEG_AUTOCOMPACT:-$PIN_AUTOCOMPACT}" in
        auto) ceiling="$window" ;;
        ''|*[!0-9]*)
            printf 'guard-leg-context-handoff: HIMMEL_LEG_AUTOCOMPACT %s is not a token count - using the window (fail-open)\n' \
                "${HIMMEL_LEG_AUTOCOMPACT:-}" >&2
            ceiling="$window"
            ;;
        *) ceiling="${HIMMEL_LEG_AUTOCOMPACT:-$PIN_AUTOCOMPACT}" ;;
    esac
fi
if [ -n "$window" ] && [ -n "$ceiling" ] && [ "$ceiling" -gt 0 ]; then
    [ "$ceiling" -gt "$window" ] && ceiling="$window"
    threshold=$(( (CEILING_SHARE * ceiling + window - 1) / window ))
    basis="${CEILING_SHARE} % of the ${ceiling}-token autocompact ceiling on a ${window}-token window"
else
    # No window in the snapshot: the fill cannot be turned into tokens.
    threshold=$CEILING_SHARE
    basis="${CEILING_SHARE} % of the window (window size unknown)"
fi
[ "$fill" -ge "$threshold" ] || exit 0

# --- hand-off calls always pass -------------------------------------------
case "$tool" in
    SendMessage|ListAgents|ToolSearch|TaskStop) exit 0 ;;
    Write|Edit|MultiEdit)
        path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
        case "$path" in *-RESUME.md) exit 0 ;; esac
        ;;
    Bash)
        cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
        # shellcheck disable=SC2016 # literal $( is the pattern, not an expansion
        case "$cmd" in
            *'&&'*|*'||'*|*'$('*|*"
"*) ;;
            *)
                if grep -qE '^[[:space:]]*bash[[:space:]]+([^[:space:]]*/)?(scripts/handover/console-kit/append-results\.sh|scripts/handover/queue-lock\.sh[[:space:]]+release|scripts/handover/wrap-subtree-check\.sh|scripts/context-fill\.sh)([[:space:]]|$)' <<< "$cmd"; then
                    exit 0
                fi
                # WIP add/commit/push, and the status/rev-parse reads a
                # checkpoint needs, so the hand-off leaves nothing uncommitted.
                if grep -qE '^[[:space:]]*git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?(add|commit|push|status|rev-parse)([[:space:]]|$)' <<< "$cmd"; then
                    exit 0
                fi
                # Back to the worktree: one bare cd, nothing chained after it.
                if grep -qE '^[[:space:]]*cd([[:space:]]+[^[:space:];&|<>]+)?[[:space:]]*$' <<< "$cmd"; then
                    exit 0
                fi
                ;;
        esac
        ;;
esac

# --- this leg's doc, from the launcher's first turn -----------------------
first=$(head -n 400 "$transcript" 2>/dev/null | jq -rc '
    select(.type == "user" and (.isMeta | not))
    | [.timestamp // "", (.message.content
        | if type == "string" then . else ([.[]? | .text? // empty] | join(" ")) end)]
    | @tsv' 2>/dev/null | head -n 1)
started_iso=${first%%	*}
first_text=${first#*	}
doc=$(printf '%s' "$first_text" | grep -oE '/[^[:space:]"'"'"'`]+\.md' | head -n 1)
if [ -z "$doc" ] || [ ! -f "$doc" ] || [ ! -r "$doc" ]; then
    warn_allow "leg handover doc not found or unreadable in the first turn"
fi

blocked=0
tail_lib="$HERE/../lib/leg-tail-status.sh"
# shellcheck source=../lib/leg-tail-status.sh
if { [ -r "$tail_lib" ] && . "$tail_lib"; } 2>/dev/null; then
    case "$(leg_tail_status "$doc")" in
        WRAPPED) exit 0 ;;
        BLOCKED)
            case "$tool" in Read|Grep|Glob) exit 0 ;; esac
            blocked=1
            ;;
    esac
fi

# --- compact's unlock: the newest CHECKPOINT bullet names a pushed HEAD, or
# HEAD on a clean tree with nothing unpushed ----------------------------------
checkpoint_ok() {
    local line cp head up porcelain
    # An inherited GIT_DIR/GIT_WORK_TREE would read another repo's HEAD.
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
    # shellcheck disable=SC2016  # the backticks are literal Markdown
    line=$(grep -E '^- .*CHECKPOINT `?[0-9a-f]{40}`? (pushed|clean)' "$doc" 2>/dev/null | tail -n 1)
    # shellcheck disable=SC2016
    cp=$(printf '%s' "$line" | grep -oE 'CHECKPOINT `?[0-9a-f]{40}' | grep -oE '[0-9a-f]{40}')
    [ -n "$cp" ] || return 1
    head=$(git -C "$wd" rev-parse HEAD 2>/dev/null) || return 1
    [ "$cp" = "$head" ] || return 1
    up=$(git -C "$wd" rev-parse '@{u}' 2>/dev/null) || up=""
    # shellcheck disable=SC2016
    if grep -qE 'CHECKPOINT `?[0-9a-f]{40}`? pushed' <<< "$line"; then
        [ -n "$up" ] && [ "$up" = "$head" ]
        return
    fi
    # `clean` (HIMMEL-4710): a leg that has only read has nothing to commit, and
    # the pre-push CR gate refuses an empty push (N1386). It needs a clean tree
    # and nothing unpushed: HEAD is its upstream, or HEAD is already in
    # origin/main (a fresh branch at its base).
    porcelain=$(git -C "$wd" status --porcelain 2>/dev/null) || return 1
    [ -z "$porcelain" ] || return 1
    [ -n "$up" ] && [ "$up" = "$head" ] && return 0
    git -C "$wd" merge-base --is-ancestor HEAD refs/remotes/origin/main 2>/dev/null
}

# --- handoff's unlock: a RESUME doc written by this session -----------------
dir=$(dirname "$doc")
stem=$(basename "$doc" .md)
started=""
if [ -n "$started_iso" ]; then
    started=$(jq -rn --arg t "$started_iso" '$t | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601' 2>/dev/null) || started=""
fi
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }  # gnu-ok: GNU -c paired with BSD -f on this line

# The leg id is the first `-`-separated part shaped like N1364 / J1950b.
leg_id=$(printf '%s\n' "$stem" | tr '-' '\n' | grep -E '^[A-Z][0-9]+[a-z]?$' | head -n 1)
leg_base=$(printf '%s' "$leg_id" | sed -E 's/[a-z]$//')
next_stem="${stem%-RESUME}"
if [ -n "$leg_id" ]; then
    suffix=${leg_id#"$leg_base"}
    case "$suffix" in
        '') next=b ;;
        *) next=$(printf '%s' "$suffix" | tr 'a-y' 'b-z') ;;
    esac
    next_stem=$(printf '%s' "$next_stem" | sed -E "s/(^|-)$leg_id(-|\$)/\\1$leg_base$next\\2/")
fi
want="$dir/$next_stem-RESUME.md"

resume_ok() {
    local cand m
    for cand in "$dir"/*-RESUME.md; do
        [ -f "$cand" ] || continue
        [ "$cand" = "$doc" ] && continue
        if [ -n "$leg_id" ]; then
            grep -qE "^${leg_base}[a-z]?\$" <<< "$(basename "$cand" .md | tr '-' '\n')" || continue
        else
            [ "$cand" = "$want" ] || continue
        fi
        # An unknown session start cannot tell this session's RESUME doc from a
        # stale one, so no doc counts.
        [ -n "$started" ] || continue
        m=$(mtime "$cand") || continue
        [ "$m" -ge "$started" ] || continue
        return 0
    done
    return 1
}

if [ "$event" = "PreCompact" ]; then
    checkpoint_ok && exit 0
    resume_ok && exit 0
elif [ "$blocked" = 1 ]; then
    # BLOCKED is a hand-off: neither unlock reopens ordinary work after it.
    :
elif [ "$MODE" = "compact" ]; then
    checkpoint_ok && exit 0
else
    resume_ok && exit 0
fi

allowed="SendMessage, ListAgents, ToolSearch, TaskStop, append-results.sh, queue-lock.sh release, wrap-subtree-check.sh, context-fill.sh, git add/commit/push/status/rev-parse, a bare cd"
commit_form='A commit is one line (a newline in the command is denied): git commit -m "<subject>" -m "<body>" --trailer "Platforms tested: <os>" --trailer "Security reviewed: <token> - <what>".'
stuck_note="If you cannot push or commit (a moved upstream, a refused attestation or pre-commit gate), do not work around it: SendMessage your console ${HIMMEL_CONSOLE_NAME} what blocks you, then bash scripts/handover/console-kit/append-results.sh ${doc} \"BLOCKED — <why>\" and stop. BLOCKED frees only these hand-off calls and reads (Read, Grep, Glob), not your work; WRAPPED (after the merge) frees everything."
mode_note="The mode is set at launch by the console (HIMMEL_LEG_CONTEXT_MODE); it cannot be changed in-session."
if [ "$MODE" = "compact" ]; then
    deny_msg="leg context checkpoint (mode compact): this session is at ${fill} % context fill (threshold ${threshold} % = ${basis}). Ordinary tool calls stay denied until you checkpoint. Do exactly this: 1) git add and git commit your WIP, then git push. ${commit_form} 2) git rev-parse HEAD. 3) bash scripts/handover/console-kit/append-results.sh ${doc} \"LIVE — CHECKPOINT <full sha of HEAD> pushed\". 4) Carry on with your work: the session compacts at its ceiling and continues. A new commit after the checkpoint needs a push and a fresh CHECKPOINT bullet. Nothing to commit and nothing unpushed (git status clean, HEAD on its upstream or in origin/main)? Skip 1 and write \"LIVE — CHECKPOINT <full sha of HEAD> clean\" instead. ${stuck_note} Still allowed meanwhile: ${allowed}. ${mode_note} Bypass: LEG_CONTEXT_HANDOFF_OK=1 in the launching shell."
else
    deny_msg="leg context hand-off (mode handoff): this session is at ${fill} % context fill (threshold ${threshold} % = ${basis}). Ordinary tool calls stay denied until you hand off. Do exactly this: 1) Write your resume brief to ${want} (ticket, branch, worktree, committed-vs-dirty, PR/CR state, remaining ordered steps). 2) SendMessage your console ${HIMMEL_CONSOLE_NAME}: context ${fill} %, RESUME at that path. 3) bash scripts/handover/console-kit/append-results.sh ${doc} \"BLOCKED — context ${fill} %, RESUME written: <path>\". 4) Stop. Still allowed meanwhile: ${allowed}. ${commit_form} ${mode_note} Bypass: LEG_CONTEXT_HANDOFF_OK=1 in the launching shell."
fi

if [ "$event" = "PreCompact" ]; then
    deny_msg="refusing auto-compaction: no CHECKPOINT or RESUME yet. ${deny_msg}"
    reason=$(printf '%s' "$deny_msg" | jq -Rs . 2>/dev/null) || reason='"leg context guard: checkpoint before compacting"'
    printf '{"decision":"block","reason":%s}\n' "$reason"
else
    reason=$(printf '%s' "$deny_msg" | jq -Rs . 2>/dev/null) \
        || reason='"leg context guard: past the context threshold - checkpoint or hand off"'
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$reason"
fi
printf '%s\n' "$deny_msg" >&2
exit 2
