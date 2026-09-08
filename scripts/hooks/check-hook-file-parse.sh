#!/usr/bin/env bash
# PostToolUse guard for Edit|Write|MultiEdit — a hook file that does not parse
# (HIMMEL-2230).
#
# WHY: every OTHER lint layer in this repo runs at COMMIT time, and for a hook
# file that is already too late by construction. A file under scripts/hooks/ is
# LIVE the instant it is saved: the next tool call executes it. The motivating
# incident put a prose apostrophe inside a single-quoted awk program, the
# apostrophe ended the shell string, the hook stopped parsing, and it denied
# EVERY command fleet-wide — benign ones included. It never reached a commit, so
# neither the pre-commit shellcheck gate nor `bash scripts/lint/shell-lint.sh`
# was ever in the path. Scanning every reachable revision of that file in git
# confirms it: zero committed revisions ever failed `bash -n`.
#
# This hook closes that timing gap and nothing else. It runs the SAME checks as
# shell-lint's [parse] / [quote-break] — one implementation, in
# scripts/lint/hook-parse-check.sh — the moment the file is written.
#
# Scope: tool_input.file_path AT OR BELOW scripts/hooks/ ending in .sh (the
# case glob below matches a nested subdirectory too, not just a direct child).
# Everything else exits 0 immediately; this is not a general-purpose linter
# and must stay cheap enough to run on every write.
#
# Contract: PostToolUse, so the write has ALREADY happened — exit 2 does not
# prevent it, it puts the failure in front of the model while the context to fix
# it is still loaded. That is the whole value: without it the next tool call is
# a mystery fleet-wide denial.
#
# FAILS OPEN on anything unevaluable (no jq, unparseable stdin, missing checker,
# path outside scope): a hygiene guard that blocked edits whenever a dependency
# was absent would be worse than the problem. The security fences fail CLOSED;
# this one does not, deliberately.
#
# Exit: 0 allow/not-applicable; 2 the written hook file does not parse (or its
# awk program is truncated). Bash 3.2-safe.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="$SCRIPT_DIR/../lint/hook-parse-check.sh"

command -v jq >/dev/null 2>&1 || exit 0
[ -f "$CHECKER" ] || exit 0

input=$(cat)

tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)
case "$tool" in
    Edit|Write|MultiEdit|NotebookEdit) ;;
    *) exit 0 ;;
esac

path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
[ -n "$path" ] || exit 0

# Scope test on the PATH TEXT, so it works for an absolute Windows path, an
# absolute POSIX path, a worktree path, or a repo-relative one alike. Backslash
# separators are folded first (134 octal = the backslash): on the Windows lane the same file arrives as
# scripts\hooks\x.sh.
norm=$(printf '%s' "$path" | tr '\134' '/')
case "$norm" in
    */scripts/hooks/*.sh|scripts/hooks/*.sh) ;;
    *) exit 0 ;;
esac

# Resolve against the SEPARATOR-FOLDED form when the raw one does not exist:
# the Windows lane hands us C:\...\scripts\hooks\x.sh, which passes the scope
# test above but is not a path this shell can stat. Prefer the raw form so a
# filename that legitimately contains a backslash is never rewritten.
target="$path"
[ -f "$target" ] || target="$norm"
[ -f "$target" ] || exit 0

if ! findings="$(bash "$CHECKER" "$target" 2>&1)"; then
    {
        printf 'check-hook-file-parse: the hook file you just wrote is BROKEN.\n\n'
        printf '%s\n\n' "$findings"
        printf 'A file under scripts/hooks/ is live the moment it is saved. A hook that\n'
        printf 'does not parse exits non-zero on every invocation, which DENIES EVERY\n'
        printf 'COMMAND for this session and every other one on this machine — benign\n'
        printf 'commands included. Fix it now, before the next tool call.\n\n'
        printf 'Commonest cause: an apostrophe in prose inside a single-quoted awk/sed/perl\n'
        printf 'program body. The apostrophe ends the shell string early; the rest of the\n'
        printf 'program becomes stray shell text. Reword it, or double-quote the program.\n'
    } >&2
    exit 2
fi

exit 0
