#!/usr/bin/env bash
# rtk-hook-guard.sh — wrapper around `rtk hook claude` (HIMMEL-241).
#
# ROOT CAUSE this kills: the rtk PreToolUse hook rewrites `find …` to
# `rtk find …`, but `rtk find` REJECTS compound predicates/actions at
# runtime ("rtk find does not support compound predicates or actions
# (e.g. -not, -exec). Use `find` directly." — verified rtk 0.40.0).
# Every LUNA runbook scan (harvest/triage/synthesize/archive-clips)
# enumerates clips with `find … -not -path '*/_synthesis/*' -not -path
# '*/_done/*' -not -name _deferred.md`, so the rewrite silently breaks
# every pipeline run.
#
# Fix (HIMMEL-241 option 1): register THIS script as the PreToolUse hook
# instead of bare `rtk hook claude`. It delegates to rtk, and only when
# rtk rewrote the command to `rtk find …` AND that command uses a
# predicate rtk rejects (-not/-exec/-o/-a/-delete/!/\(…\)) or silently
# drops (-prune), it suppresses the rewrite — empty output means the
# original command runs unmodified through the normal permission flow.
# Simple finds and every other command keep rtk's rewrite verbatim:
# zero token regression.
#
# Rejected-token set verified against rtk 0.40.0 (see
# test-rtk-hook-guard.sh). -prune is included although rtk only warns
# ("unknown flag '-prune', ignored") — silently dropping a predicate
# changes find semantics, which is worse than losing the rewrite.
#
# FAIL-OPEN (deliberate — this directory's fail-closed convention does
# not apply): rtk is a token optimizer, not a guard. rtk missing,
# crashing, or silent must never block a tool call — those paths exit 0
# with empty output (= no rewrite, no opinion). One asymmetry: when rtk
# DID emit output but the command value can't be extracted (output-shape
# drift), output that still contains an `rtk find ` rewrite is
# SUPPRESSED rather than forwarded — forwarding a rewrite this guard
# could not scan resurrects the original bug. Non-find output carries no
# rewrite the guard acts on and is forwarded verbatim.
set -uo pipefail

payload=$(cat 2>/dev/null || true)
[ -n "$payload" ] || exit 0
command -v rtk >/dev/null 2>&1 || exit 0

out=$(printf '%s' "$payload" | rtk hook claude 2>/dev/null) || exit 0
[ -n "$out" ] || exit 0

# Extract the rewritten command VALUE and scan only that (HIMMEL-264).
# Scanning rtk's whole JSON output was brittle to output-shape drift: a
# future permissionDecisionReason containing "-not" would suppress a
# safe rewrite (lost savings), and a renamed command field would
# silently stop suppressing bad rewrites (the original bug returns).
# jq is the primary extractor (yields the unescaped command string);
# when jq is missing or fails, fall back to grep+sed (yields the
# JSON-escaped string — the token scan below anchors on both forms).
# If neither path extracts a command, see the extraction-failure branch
# below: rtk-find output is suppressed, anything else forwarded.
cmd=""
if command -v jq >/dev/null 2>&1; then
    cmd=$(printf '%s' "$out" \
        | jq -r '.hookSpecificOutput.updatedInput.command // empty' 2>/dev/null) || cmd=""
fi
if [ -z "$cmd" ]; then
    # No jq (or jq choked). Anchor on the only value this guard acts on:
    # a "command" key whose value starts with "rtk find " — an unanchored
    # first-match grab could extract the ORIGINAL command from a drifted
    # output shape (e.g. an echoed tool_input) and let a bad rewrite
    # through. The escape-aware value class (\\.|[^"\\])* stops at the
    # real closing quote (not an embedded \"); sed strips key + quotes.
    # Non-find command values stay unextracted on purpose — they fall to
    # the extraction-failure branch below, which forwards them verbatim.
    cmd=$(printf '%s' "$out" \
        | grep -oE '"command"[[:space:]]*:[[:space:]]*"rtk find (\\.|[^"\\])*"' 2>/dev/null \
        | head -n 1 \
        | sed 's/^"command"[[:space:]]*:[[:space:]]*"//; s/"$//') || cmd=""
fi

# Extraction failure (rtk output-shape drift, e.g. a renamed command
# field). If the unparsable output still mentions an `rtk find ` rewrite
# we could not scan it for rejected predicates — suppress instead of
# forwarding (forwarding unscanned output is exactly the original bug).
# Output with no rtk-find rewrite carries nothing this guard screens:
# forward it verbatim (no opinion, never block).
if [ -z "$cmd" ]; then
    case "$out" in
    *'"rtk find '*) exit 0 ;;
    esac
    printf '%s\n' "$out"
    exit 0
fi

# Only intervene when rtk decided to rewrite to `rtk find` — that is the
# exact case that can hit the runtime rejection. Everything else is
# forwarded verbatim.
case "$cmd" in
"rtk find "*)
    # Scan the rewritten command (rtk keeps the predicates verbatim) for
    # tokens `rtk find` cannot execute. Anchors: whitespace, a quote, a
    # backslash (start of a JSON escape like \" in the grep-fallback
    # form), or end of string. \\\\?\( matches an escaped paren in BOTH
    # extraction forms: `\(` (jq-unescaped) and `\\(` (JSON-escaped).
    # A false positive merely skips the rewrite (find runs directly,
    # token filtering lost); a false negative breaks the command — so
    # the token list errs broad.
    if printf '%s' "$cmd" | grep -qE -- \
        '[[:space:]]-(not|exec|execdir|ok|okdir|delete|prune|o|or|a|and)([[:space:]"\\]|$)|[[:space:]]!([[:space:]"\\]|$)|\\\\?\('; then
        exit 0
    fi
    ;;
esac

printf '%s\n' "$out"
