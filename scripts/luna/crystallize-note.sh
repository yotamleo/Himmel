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
# Optional operator rules/context file: 3rd positional arg, overridden by env
# CRYSTALLIZE_RULES_FILE (env wins — same precedence as CRYSTALLIZE_MODEL). When
# set and readable its content is appended to the crystallizer prompt; an
# unreadable / missing file appends nothing (fail-open, matches the contract).
RULES_FILE="${CRYSTALLIZE_RULES_FILE:-${3:-}}"
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
# SETTINGS_TMP is the per-run `claude --settings` fragment (set below); SNAP_TMP
# is the refresh-mode pre-run snapshot; both cleaned up here so they never leak
# even on early exit.
SETTINGS_TMP=""
SNAP_TMP=""
# shellcheck disable=SC2317,SC2329  # invoked via trap
_cleanup() {
    rm -f "$MY_PID" 2>/dev/null || true
    if [ -n "$SETTINGS_TMP" ]; then rm -f "$SETTINGS_TMP" 2>/dev/null || true; fi
    if [ -n "$SNAP_TMP" ]; then rm -f "$SNAP_TMP" 2>/dev/null || true; fi
}
trap _cleanup EXIT

# Retry-read: the live hook may have just written the note via the Obsidian REST
# API, which flushes to disk asynchronously.
i=0
while [ ! -r "$NOTE_PATH" ] && [ "$i" -lt 3 ]; do
    sleep 1
    i=$((i + 1))
done
[ -r "$NOTE_PATH" ] || exit 0

# Already crystallized -> nothing to do, UNLESS refresh (re-consolidation) mode
# (CRYSTALLIZE_REFRESH=1) deliberately re-runs an already-synthesized note.
if [ "${CRYSTALLIZE_REFRESH:-}" != "1" ]; then
    grep -q '^crystallized: true$' "$NOTE_PATH" 2>/dev/null && exit 0
else
    # Loss-proofing (refresh only): a refresh rewrites PREVIOUSLY-GOOD synthesis,
    # so a partial/failed claude edit (quota kill, permission-EOF) must never be
    # accepted as a "refresh". Snapshot the note pre-run; the result is validated
    # structurally below and restored from this snapshot if it fails. Can't
    # snapshot -> can't roll back -> don't run (fail-open, note untouched).
    SNAP_TMP="${NOTE_PATH}.snap.$$"
    if ! cp "$NOTE_PATH" "$SNAP_TMP" 2>/dev/null; then
        SNAP_TMP=""
        exit 0
    fi
fi

# Structural validity of a refreshed note: frontmatter intact (first line is
# `---` and a second `---` delimiter exists), all four body section headers
# present, and the Raw Conversation callout the renderer emits
# (scripts/lib/session-note.sh) still there. Refresh-mode only.
# shellcheck disable=SC2317,SC2329  # invoked only on the refresh path
_refresh_valid() { # <note>
    [ "$(head -n 1 "$1" 2>/dev/null)" = "---" ] || return 1
    [ "$(grep -c '^---$' "$1" 2>/dev/null)" -ge 2 ] || return 1
    grep -q '^## Summary$' "$1" 2>/dev/null || return 1
    grep -q '^## Decisions$' "$1" 2>/dev/null || return 1
    grep -q '^## Files Touched$' "$1" 2>/dev/null || return 1
    grep -q '^## Follow-ups$' "$1" 2>/dev/null || return 1
    grep -qF '> [!note]- Raw conversation' "$1" 2>/dev/null || return 1
    return 0
}

# The note lives in the luna vault, OUTSIDE the himmel repo. The original
# crystallizer ran `claude` in HIMMEL_ROOT, but `--permission-mode acceptEdits`
# only auto-approves edits to files INSIDE the spawned run's workspace — so the
# out-of-workspace note Edit fell through to a permission prompt, `</dev/null`
# EOFed it, and the note was left BYTE-UNCHANGED with `crystallized: false`
# (HIMMEL-590 F1; confirmed by capturing the spawned run's stdout: "each write to
# the note is waiting on your permission grant"). The stub-based suite masked it
# because the stub edits the note directly.
#
# Fix (same class as HIMMEL-575): put the note's directory in the workspace by
# running `claude` with cwd = the note's directory, add the transcript's
# directory via `--add-dir`, and inject himmel's `auto-approve-safe-bash`
# PreToolUse hook by ABSOLUTE path via `--settings` (the vault cwd carries no
# himmel project settings, so any bash the run does would otherwise stall on the
# HIMMEL-203 compound-bash prompt). The LLM rewrites only the four body sections;
# the `crystallized` flag is owned DETERMINISTICALLY by this script, set only
# when the note body actually changed (T1d) — so a no-op never falsely flags and
# a real synthesis always does, regardless of what the model touched.
if [ "${CRYSTALLIZE_REFRESH:-}" = "1" ]; then
    # Refresh (re-consolidation): the note was already synthesized. CONSOLIDATE —
    # update/extend the four sections, preserving prior synthesis still correct.
    PROMPT="You are re-consolidating an already-synthesized Claude Code session note for an Obsidian vault.
Read the session transcript at: ${TRANSCRIPT_PATH}
Read the note at: ${NOTE_PATH}
This note was already synthesized. Re-read the transcript and the existing sections;
UPDATE/EXTEND the four sections below, preserving prior synthesis content that is
still correct — do not discard it:
- ## Summary       (3-6 lines: what was done and the outcome)
- ## Decisions     (bullet list of decisions made, or _None._)
- ## Files Touched (keep the existing list; do not invent files)
- ## Follow-ups    (bullet list of open items, or _None._)
Do NOT touch the frontmatter or the Raw Conversation callout. Make the edit with
your file tools, then stop."
else
    PROMPT="You are crystallizing a Claude Code session note for an Obsidian vault.
Read the session transcript at: ${TRANSCRIPT_PATH}
Read the note at: ${NOTE_PATH}
Rewrite ONLY these sections of that note, in place, distilling the session:
- ## Summary       (3-6 lines: what was done and the outcome)
- ## Decisions     (bullet list of decisions made, or _None._)
- ## Files Touched (keep the existing list; do not invent files)
- ## Follow-ups    (bullet list of open items, or _None._)
Do NOT touch the frontmatter or the Raw Conversation callout. Make the edit with
your file tools, then stop."
fi

# Operator rules/context injection: when a readable rules file was supplied,
# append its content as a clearly delimited block. Unreadable / missing / empty
# -> append nothing (fail-open). Trim whitespace before the emptiness guard to
# ensure parity with PowerShell (Get-Content -Raw keeps trailing newline, but
# bash `$(cat)` strips it; both must skip on whitespace-only files).
if [ -n "$RULES_FILE" ] && [ -r "$RULES_FILE" ]; then
    _rules_content="$(cat "$RULES_FILE" 2>/dev/null)"
    # Trim whitespace (spaces, tabs, newlines) before the emptiness check
    _rules_trimmed="${_rules_content//[$'\t\r\n ']/}"
    if [ -n "$_rules_trimmed" ]; then
        PROMPT="$PROMPT

Additionally apply these operator rules when synthesizing:
--- begin operator rules ---
${_rules_content}
--- end operator rules ---"
    fi
fi

HIMMEL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)"
AUTO_APPROVE_HOOK="$HIMMEL_ROOT/scripts/hooks/auto-approve-safe-bash.sh"

# Settings fragment wiring auto-approve-safe-bash by absolute path (HIMMEL-575).
# HIMMEL_ROOT comes from `pwd`, so it is already forward-slash (JSON-safe and
# bash-readable) on Git Bash / macOS / Linux alike.
SETTINGS_TMP="$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/crys-settings-$$.json")"
cat > "$SETTINGS_TMP" <<JSON
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "bash ${AUTO_APPROVE_HOOK}" }
        ]
      }
    ]
  }
}
JSON

# Optional model pin + transcript --add-dir. bash 3.2-safe empty-array guard.
EXTRA_ARGS=()
[ -n "${CRYSTALLIZE_MODEL:-}" ] && EXTRA_ARGS=(--model "$CRYSTALLIZE_MODEL")
NOTE_DIR="$(cd "$(dirname "$NOTE_PATH")" 2>/dev/null && pwd)"
TR_DIR=""
[ -n "$TRANSCRIPT_PATH" ] && TR_DIR="$(cd "$(dirname "$TRANSCRIPT_PATH")" 2>/dev/null && pwd)"
[ -n "$TR_DIR" ] && EXTRA_ARGS=(${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} --add-dir "$TR_DIR")

# Pre-hash: the edit-confirmed flag-set keys off whether the body actually moved.
_hash() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1" 2>/dev/null; } | awk '{print $1}'; }
HASH_BEFORE="$(_hash "$NOTE_PATH")"

(
    cd "$NOTE_DIR" 2>/dev/null || exit 0
    CRYSTALLIZE_NOTE="$NOTE_PATH" CRYSTALLIZE_TRANSCRIPT="$TRANSCRIPT_PATH" \
        "$CLAUDE_BIN" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} \
        --settings "$SETTINGS_TMP" \
        --permission-mode acceptEdits "$PROMPT" </dev/null >/dev/null 2>&1
) || true

# Edit-confirmed flag-set (T1d): only stamp crystallized:true when the note body
# actually changed. A failed/no-op run leaves the note byte-unchanged and the
# flag stays false; a real synthesis always flips it, with a deterministic UTC
# timestamp this script owns (CRYSTALLIZE_NOW overridable for hermetic tests).
HASH_AFTER="$(_hash "$NOTE_PATH")"
# Both hashes must be measurable (errs toward leaving the flag false when a hash
# can't be taken — never fabricates a crystallized:true) — matches the .ps1 twin.
if [ -n "$HASH_BEFORE" ] && [ -n "$HASH_AFTER" ] && [ "$HASH_BEFORE" != "$HASH_AFTER" ]; then
    # Refresh loss-proofing: a changed-but-structurally-broken result (truncated
    # note, lost frontmatter/sections — the shape of a half-applied edit) is
    # ROLLED BACK to the pre-run snapshot and NOT re-stamped. The note ends
    # byte-identical to before, so a hash-based caller naturally counts a skip.
    # Non-refresh runs are untouched by this branch (no snapshot exists).
    if [ "${CRYSTALLIZE_REFRESH:-}" = "1" ] && ! _refresh_valid "$NOTE_PATH"; then
        if [ -n "$SNAP_TMP" ] && [ -r "$SNAP_TMP" ]; then
            mv -f "$SNAP_TMP" "$NOTE_PATH" 2>/dev/null || true
            SNAP_TMP=""
        fi
    else
        NOW="${CRYSTALLIZE_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
        STAMP_TMP="${NOTE_PATH}.stamp.$$"
        if awk -v now="$NOW" '
            /^---$/ { fmc++; print; next }
            fmc==1 && /^crystallized: / { print "crystallized: true"; next }
            fmc==1 && /^crystallized_at:/ { print "crystallized_at: " now; next }
            { print }
        ' "$NOTE_PATH" > "$STAMP_TMP" 2>/dev/null; then
            mv -f "$STAMP_TMP" "$NOTE_PATH" 2>/dev/null || rm -f "$STAMP_TMP" 2>/dev/null || true
        else
            rm -f "$STAMP_TMP" 2>/dev/null || true
        fi
    fi
fi

exit 0
