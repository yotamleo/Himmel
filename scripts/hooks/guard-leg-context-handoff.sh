#!/usr/bin/env bash
# guard-leg-context-handoff.sh — PreToolUse hook (matcher "*"): a console-spawned
# leg at >= 75 % context-window fill is denied every NON-hand-off tool call until
# it has handed off (HIMMEL-4569). The leg preface's "Context >= 75 %: write a
# RESUME brief, message the console, stop" was prose only; the --autocompact
# ceiling is a backstop that compacts the leg, it never hands off.
#
# Scope: a console-spawned leg only — HIMMEL_CONSOLE_LEG=1 AND a non-empty
# HIMMEL_CONSOLE_NAME, both exported by headed-arm-leg.sh (HIMMEL-2919,
# HIMMEL-3435). Anything else returns at once with no output.
#
# The decision, in order:
#   1. fill = scripts/context-fill.sh --percent on the hook's transcript_path.
#      Below 75 -> allow.
#   2. A hand-off call -> allow, always: Write/Edit/MultiEdit of a *-RESUME.md,
#      SendMessage, ListAgents (the preface's name check before a send),
#      ToolSearch (SendMessage is a deferred tool), TaskStop (the wrap reaps
#      background tasks), and a bare `bash <...>/append-results.sh`,
#      `queue-lock.sh release`, `wrap-subtree-check.sh` or `context-fill.sh`.
#   3. The leg's own doc is the `.md` path named in the transcript's first user
#      turn — the launcher's `load <brief> and continue`. Its last marker
#      WRAPPED or BLOCKED -> allow.
#   4. A RESUME doc for this leg exists -> allow: a *-RESUME.md beside the doc,
#      not the doc itself, carrying the doc's leg id (N1364, J1950b ...) with any
#      one-letter suffix, and modified after this session's first user turn — so
#      an older link of the same chain never counts.
#   5. Otherwise deny, naming the fill, the RESUME path to write, the console and
#      the marker command.
#
# ponytail: fail-OPEN on every infrastructure gap (fill UNKNOWN or STALE, no
# transcript_path, leg doc not found, no jq, junk stdin), with one stderr line.
# A false block strands a leg in a window nobody watches, while a false allow
# only costs the pre-hook status quo (the autocompact backstop still fires);
# upgrade path: if the fail-open warnings show up in leg logs, fix the probe
# (HIMMEL-3081, HIMMEL-2342), never flip this to fail-closed.
# ponytail: the Bash hand-off allow-list matches command TEXT and refuses only
# `&&`, `||`, `$(` and newlines — a `;`-chained tail after an allowed script
# slips through, because a bullet's quoted text may itself carry `;`; this is a
# workflow nudge, not a fence (scripts/hooks/CLAUDE.md), and the permission
# matcher already refuses compound shapes; upgrade path: parse the command
# with the shell-word splitter auto-approve-safe-bash.sh uses if a leg abuses it.
#
# Bypass: LEG_CONTEXT_HANDOFF_OK=1 in the launching shell (session-sticky; a
# per-call prefix does not reach this hook process).
#
# Platform guard (gitbash-only): env vars, jq, stat -c/-f, sed; bash 3.2-safe,
# runs unchanged under Git Bash. No .ps1 twin needed.
#
# Hook I/O: JSON on stdin. exit 0 = allow, exit 2 = deny (stderr plus a
# structured hookSpecificOutput.permissionDecision on stdout — same idiom as
# guard-leg-wakeup.sh).
set -uo pipefail

[ "${HIMMEL_CONSOLE_LEG:-0}" = "1" ] || exit 0
[ -n "${HIMMEL_CONSOLE_NAME:-}" ] || exit 0
[ "${LEG_CONTEXT_HANDOFF_OK:-0}" = "1" ] && exit 0

THRESHOLD=75
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

warn_allow() {
    printf 'guard-leg-context-handoff: allowing - %s (fail-open)\n' "$1" >&2
    exit 0
}

command -v jq >/dev/null 2>&1 || warn_allow "jq not on PATH"

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null) || warn_allow "unparseable hook input"
[ -n "$tool" ] || warn_allow "no tool_name in hook input"
transcript=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
if [ -z "$transcript" ] || [ ! -f "$transcript" ] || [ ! -r "$transcript" ]; then
    warn_allow "no readable transcript_path, context fill unknown"
fi

fill=$(CONTEXT_FILL_TRANSCRIPT="$transcript" bash "$HERE/../context-fill.sh" --percent 2>/dev/null)
fill_rc=$?
case "$fill_rc:$fill" in
    0:[0-9]|0:[0-9][0-9]|0:100) ;;
    3:*) warn_allow "context fill STALE (context-fill.sh rc 3)" ;;
    *) warn_allow "context fill UNKNOWN (context-fill.sh rc $fill_rc)" ;;
esac
[ "$fill" -ge "$THRESHOLD" ] || exit 0

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
                if printf '%s' "$cmd" | grep -qE '^[[:space:]]*bash[[:space:]]+([^[:space:]]*/)?(scripts/handover/console-kit/append-results\.sh|scripts/handover/queue-lock\.sh[[:space:]]+release|scripts/handover/wrap-subtree-check\.sh|scripts/context-fill\.sh)([[:space:]]|$)'; then
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
if [ -z "$doc" ] || [ ! -f "$doc" ]; then
    warn_allow "leg handover doc not found in the first turn"
fi

tail_lib="$HERE/../lib/leg-tail-status.sh"
# shellcheck source=../lib/leg-tail-status.sh
if { [ -r "$tail_lib" ] && . "$tail_lib"; } 2>/dev/null; then
    case "$(leg_tail_status "$doc")" in
        WRAPPED|BLOCKED) exit 0 ;;
    esac
fi

# --- a RESUME doc written by this session ----------------------------------
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

for cand in "$dir"/*-RESUME.md; do
    [ -f "$cand" ] || continue
    [ "$cand" = "$doc" ] && continue
    if [ -n "$leg_id" ]; then
        printf '%s\n' "$(basename "$cand" .md)" | tr '-' '\n' | grep -qE "^${leg_base}[a-z]?\$" || continue
    else
        [ "$cand" = "$want" ] || continue
    fi
    if [ -n "$started" ]; then
        m=$(mtime "$cand") || continue
        [ "$m" -ge "$started" ] || continue
    fi
    exit 0
done

deny_msg="leg context hand-off: this session is at ${fill} % context fill (threshold ${THRESHOLD} %). Ordinary tool calls stay denied until you hand off. Do exactly this: 1) Write your resume brief to ${want} (ticket, branch, worktree, committed-vs-dirty, PR/CR state, remaining ordered steps). 2) SendMessage your console ${HIMMEL_CONSOLE_NAME}: context ${fill} %, RESUME at that path. 3) bash scripts/handover/console-kit/append-results.sh ${doc} \"BLOCKED — context ${fill} %, RESUME written: <path>\". 4) Stop. Still allowed meanwhile: SendMessage, ListAgents, ToolSearch, TaskStop, append-results.sh, queue-lock.sh release, wrap-subtree-check.sh, context-fill.sh. Bypass: LEG_CONTEXT_HANDOFF_OK=1 in the launching shell."

reason=$(printf '%s' "$deny_msg" | jq -Rs . 2>/dev/null) \
    || reason='"leg context hand-off: past 75 % context fill - write the RESUME doc, message the console, stop"'
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$reason"
printf '%s\n' "$deny_msg" >&2
exit 2
