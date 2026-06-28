#!/usr/bin/env bash
# crystallize-note.sh — upgrade a mechanical session note into an LLM synthesis
# (HIMMEL-576). Reads the session transcript + the just-written note and asks a
# bounded `claude` run to rewrite the four body sections (Summary / Decisions /
# Files Touched / Follow-ups), preserving frontmatter identity and setting
# `crystallized: true`. Billed to the operator's Max plan — this is an
# INTERACTIVE bounded run (`claude "<prompt>" </dev/null`), NOT headless `-p`,
# so it is HIMMEL-128-safe and needs no API key.
#
# Usage: crystallize-note.sh <note_path> <transcript_path>
#
# Best-effort + fail-open: any unavailability (no `claude`, over the concurrency
# cap, note not yet on disk) -> exit 0, leaving the mechanical note
# (`crystallized: false`). The reheal sweep (`backfill-sessions.sh --reheal`)
# recovers anything a backgrounded run missed.
#
# Test seam: CRYSTALLIZE_CLAUDE_BIN overrides the `claude` binary with a stub so
# the suite stays hermetic. CRYSTALLIZE_PID_DIR / CRYSTALLIZE_MAX_CONCURRENCY
# tune the concurrency cap. bash 3.2-safe.
set -uo pipefail

NOTE_PATH="${1:-}"
TRANSCRIPT_PATH="${2:-}"
[ -n "$NOTE_PATH" ] || exit 0

# Recursion guards: the throwaway claude session we spawn must not itself re-fire
# the session-end hooks. CLAUDE_END_SESSION_WIKI=0 silences end-session-wiki;
# HIMMEL_WHERE_ARE_WE=0 silences the where-are-we session-end refresh
# (refresh-where-are-we-on-end.sh, HIMMEL-572) so a crystallizer subsession does
# not kick off a synchronous jira/gh/git ledger refresh.
export CLAUDE_END_SESSION_WIKI=0
export HIMMEL_WHERE_ARE_WE=0

# Resolve the claude binary (test override wins). No claude -> leave the
# mechanical note untouched.
CLAUDE_BIN="${CRYSTALLIZE_CLAUDE_BIN:-}"
[ -n "$CLAUDE_BIN" ] || CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"
[ -n "$CLAUDE_BIN" ] || exit 0

# Concurrency cap — never pile up N full claude processes for N simultaneous
# session-ends. Best-effort pidfile counting; stale entries are pruned.
MAX="${CRYSTALLIZE_MAX_CONCURRENCY:-2}"
PID_DIR="${CRYSTALLIZE_PID_DIR:-${TMPDIR:-/tmp}/himmel-crystallize}"
mkdir -p "$PID_DIR" 2>/dev/null || true
live=0
for pf in "$PID_DIR"/*.pid; do
    [ -e "$pf" ] || continue
    pid="$(cat "$pf" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        live=$((live + 1))
    else
        rm -f "$pf" 2>/dev/null || true
    fi
done
[ "$live" -ge "$MAX" ] && exit 0
MY_PID="$PID_DIR/$$.pid"
printf '%s' "$$" > "$MY_PID" 2>/dev/null || true
# shellcheck disable=SC2317  # invoked via trap
_cleanup() { rm -f "$MY_PID" 2>/dev/null || true; }
trap _cleanup EXIT

# Retry-read: the live hook may have just written the note via the Obsidian REST
# API, which flushes to disk asynchronously.
i=0
while [ ! -r "$NOTE_PATH" ] && [ "$i" -lt 3 ]; do
    sleep 1
    i=$((i + 1))
done
[ -r "$NOTE_PATH" ] || exit 0

# Already crystallized -> nothing to do.
grep -q '^crystallized: true$' "$NOTE_PATH" 2>/dev/null && exit 0

PROMPT="You are crystallizing a Claude Code session note for an Obsidian vault.
Read the session transcript at: ${TRANSCRIPT_PATH}
Read the note at: ${NOTE_PATH}
Rewrite ONLY these sections of that note, in place, distilling the session:
- ## Summary       (3-6 lines: what was done and the outcome)
- ## Decisions     (bullet list of decisions made, or _None._)
- ## Files Touched (keep the existing list; do not invent files)
- ## Follow-ups    (bullet list of open items, or _None._)
Set frontmatter 'crystallized: true' and 'crystallized_at:' to the current UTC
ISO-8601 time. Preserve every other frontmatter field (date, session_id, repo,
branch, worktree, source) verbatim, and do NOT touch the Raw Conversation
callout. Make the edit with your file tools, then stop."

# Run in the himmel repo root so the spawned claude inherits himmel's project
# settings (auto-approve-safe-bash active -> no compound-bash stall, the
# HIMMEL-575 posture). --permission-mode acceptEdits lets the single note Edit
# land without a prompt (narrow; the prompt scopes the run to one file).
# </dev/null bounds the run (a stray prompt EOFs out instead of hanging).
HIMMEL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"

# Optional model pin. bash 3.2-safe empty-array expansion guard under `set -u`.
MODEL_ARGS=()
[ -n "${CRYSTALLIZE_MODEL:-}" ] && MODEL_ARGS=(--model "$CRYSTALLIZE_MODEL")

(
    cd "$HIMMEL_ROOT" 2>/dev/null || cd "$(dirname "$NOTE_PATH")" || exit 0
    CRYSTALLIZE_NOTE="$NOTE_PATH" CRYSTALLIZE_TRANSCRIPT="$TRANSCRIPT_PATH" \
        "$CLAUDE_BIN" ${MODEL_ARGS[@]+"${MODEL_ARGS[@]}"} \
        --permission-mode acceptEdits "$PROMPT" </dev/null >/dev/null 2>&1
) || true

exit 0
