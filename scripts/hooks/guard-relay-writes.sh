#!/usr/bin/env bash
# guard-relay-writes.sh — PreToolUse hook (matchers "Bash" and
# "Edit|Write|MultiEdit|NotebookEdit"): [HIMMEL-2975] Guard D.
#
# HIMMEL-2975 splits a console into a Sonnet RELAY and a Fable JUDGE.
# headed-arm-leg.sh --relay (Task 25, #752) exports HIMMEL_CONSOLE_RELAY=1
# into the relay leg. Guard D denies the relay every write channel into
# console state — the inbox dir, every leg handover doc, the console rundir
# under /run/user or $TMPDIR — and denies the Bash shapes that would defeat
# Guard B (env-prefix override of the identity/marker vars this leg's own
# session-name resolution and inbox-send.sh's relay check read) and Guard C
# (inbox-send.sh --token, reserved for the judge).
#
# TRIP CONDITION: HIMMEL_CONSOLE_RELAY=1 in this process's environment AND
# one of:
#   Write|Edit|MultiEdit|NotebookEdit — the resolved file_path (notebook_path
#     for NotebookEdit) contains an unresolved ".." path segment (denied
#     outright, fail-closed, before any guarded-path match); or
#     <handover_root> fails to resolve, or the path itself fails to resolve
#     (`readlink -f`, every "./" segment and every symlink including the
#     final component included — denied fail-closed rather than silently
#     skipping the guarded-path match); or the PHYSICALLY resolved path is under
#     <handover_root>/inbox/, under a .../himmel-console/... rundir, under
#     ${TMPDIR:-/tmp}/himmel-console-*, or its basename matches
#     *-legN*-RESUME.md.
#   Bash — the command text contains HIMMEL_CONSOLE_RELAY, HIMMEL_CONSOLE_LEG,
#     SESSION_NAME_CMDLINE_FILE, CLAUDE_PID or CONSOLE_SESSION_NAME (an
#     env-prefix override, `unset`, or `env -u` of an identity/marker
#     variable); or contains "inbox-send" AND "--token"; or contains a
#     write-shaped verb (">", "tee",
#     "cp", "mv", "rm", "rsync", "dd", "truncate", "sed", "install", "chmod",
#     "chown") AND text naming "/inbox/", "himmel-console", or both "-legN"
#     and "-RESUME.md".
#
# DEFAULT ACTION: with the marker unset this hook is a silent no-op — the
# marker check is the FIRST statement, before stdin is even read, so it costs
# nothing on every non-relay session. With the marker set, this is a SECURITY
# FENCE and fails CLOSED: an unparseable payload, missing jq, a field of the
# wrong type, an unresolved ".." path segment, or a handover_root resolution
# failure all DENY (opposite of a workflow-nudge hook's fail-open default —
# see scripts/hooks/CLAUDE.md's fail-open-vs-closed rule).
#
# RESIDUAL (spec R2, deliberately not closed here): these are textual checks
# over the tool_input fields, not a shell parser — a command built through
# `eval`, a wrapper script file that itself performs the write, or a
# heredoc-assembled command string can still reach a guarded path without
# ever containing the literal substrings this hook matches on. The Bash
# write-verb list is a fixed vocabulary, not a shell grammar — a write
# performed through an uncommon utility not on that list (e.g. `tar`,
# `ln`, `cat >>` masked some other way) is not caught either.
#
# RESIDUAL (guarded-prefix canonicalization, deliberately not closed this
# round — HIMMEL-2975 follow-up): the DESTINATION path is fully resolved
# (readlink -f, symlinks included), but the guarded PREFIXES it is compared
# against are not independently re-resolved — <handover_root> is, but
# "$root_resolved/inbox" itself, ${TMPDIR:-/tmp}, and /run are taken as
# literal strings after that. If any of those three is ITSELF a symlink
# (e.g. handover_root/inbox aliased elsewhere, or /run -> /var/run on a
# host where that isn't already canonical), a write through the symlinked
# alias resolves to a physical path outside the literal guarded prefix and
# is not denied. Left open deliberately this round rather than widening the
# hook a further time on the same seam; track under HIMMEL-2975.
#
# RESIDUAL (false-deny, fail-safe direction, not fixed here): the write-verb
# glob (*cp*|*mv*|*rm*|*dd*|*sed*|...) matches as an unanchored SUBSTRING, not
# a shell word, so a pure READ command whose text happens to contain one of
# those letter sequences is denied too when it also names a guarded path —
# e.g. `sed -n 1,20p <inbox-path>`, `grep -c address <inbox-path>` (matches
# "dd" in "address"), `grep form <leg-doc-path>` (matches "rm" in "form"). A
# relay that needs to read a guarded path should use cat/head/tail/grep with
# wording that avoids these substrings, or accept the deny and ask the judge
# to relay the content instead — over-denying a read is the safe direction
# for this guard and is left uncorrected rather than widening the match logic
# further.
#
# Bash 3.2-compatible. Exit codes: 0 allow (no output); 2 deny (JSON
# hookSpecificOutput with permissionDecision "deny" on stdout,
# permissionDecisionReason starting "relay write-deny: ").
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Not ported to native PowerShell — the console relay lane
# (headed-arm-leg.sh --relay, scripts/handover/console-kit/) is Linux-only,
# same as inbox-send.sh's own platform guard.
set -uo pipefail

# Zero-cost no-op for every non-relay session: no stdin read, no jq, no
# sourcing — before anything else runs.
[ "${HIMMEL_CONSOLE_RELAY:-}" = "1" ] || exit 0

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/handover-path.sh
. "$HERE/../lib/handover-path.sh"

deny() {
    # deny <rule> <fragment>
    local rule="$1" frag="$2" reason
    reason=$(printf '%s' "relay write-deny: ${rule} (${frag})" | jq -Rs . 2>/dev/null) \
        || reason='"relay write-deny: denied"'
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$reason"
    exit 2
}

command -v jq >/dev/null 2>&1 || deny "unparseable-payload" "jq not on PATH"

input=$(cat 2>/dev/null || true)
[ -n "$input" ] || deny "unparseable-payload" "empty stdin"

if ! tool=$(printf '%s' "$input" | jq -r '.tool_name | select(type == "string") // empty' 2>/dev/null); then
    deny "unparseable-payload" "cannot parse JSON stdin"
fi

tool_input_type=$(printf '%s' "$input" | jq -r '.tool_input | type' 2>/dev/null) \
    || deny "unparseable-payload" "cannot read tool_input"

case "$tool" in
    Write | Edit | MultiEdit | NotebookEdit)
        [ "$tool_input_type" = "object" ] || deny "unparseable-payload" "tool_input not an object"

        if [ "$tool" = "NotebookEdit" ]; then
            path=$(printf '%s' "$input" | jq -r '.tool_input.notebook_path // .tool_input.file_path // empty' 2>/dev/null) \
                || deny "unparseable-payload" "cannot read notebook_path"
        else
            path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null) \
                || deny "unparseable-payload" "cannot read file_path"
        fi
        [ -n "$path" ] || deny "unparseable-payload" "no file_path resolved for $tool"

        case "$path" in
            */../* | ../* | */.. | ..) deny "unresolved-path" "$path" ;;
        esac

        root="$(handover_root 2>/dev/null)" || deny "handover-root-unresolved" "handover_root failed"
        [ -n "$root" ] || deny "handover-root-unresolved" "handover_root returned empty"
        root_resolved="$(readlink -f -- "$root" 2>/dev/null)" || deny "handover-root-unresolved" "handover_root does not resolve: $root"
        [ -n "$root_resolved" ] || deny "handover-root-unresolved" "handover_root does not resolve: $root"

        # Physically resolve the WHOLE path — every "./" segment, and every
        # symlink in every component including the final one (`readlink -f`,
        # GNU coreutils, Linux-only per this hook's platform guard) — before
        # matching against a guarded prefix. A dir-only resolution still lets
        # an innocuously-named symlink whose FINAL component points into a
        # guarded dir slip past a literal-string glob (codex-1); readlink -f
        # only requires the path up to the last component to exist, so a
        # brand-new file under an existing directory still resolves cleanly.
        path_resolved="$(readlink -f -- "$path" 2>/dev/null)" || deny "unresolved-path" "$path"
        [ -n "$path_resolved" ] || deny "unresolved-path" "$path"
        path_base=$(basename -- "$path_resolved")

        case "$path_resolved" in
            "$root_resolved"/inbox/*) deny "inbox-write" "$path" ;;
        esac

        case "$path_resolved" in
            /run/user/*/himmel-console/*) deny "console-rundir-write" "$path" ;;
        esac

        case "$path_resolved" in
            "${TMPDIR:-/tmp}/himmel-console-"*) deny "console-rundir-write" "$path" ;;
        esac

        case "$path_base" in
            *-legN*-RESUME.md) deny "leg-doc-write" "$path" ;;
        esac

        exit 0
        ;;
    Bash)
        [ "$tool_input_type" = "object" ] || deny "unparseable-payload" "tool_input not an object"
        cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) \
            || deny "unparseable-payload" "cannot read command"
        [ -n "$cmd" ] || exit 0

        for needle in HIMMEL_CONSOLE_RELAY HIMMEL_CONSOLE_LEG SESSION_NAME_CMDLINE_FILE CLAUDE_PID CONSOLE_SESSION_NAME; do
            case "$cmd" in
                *"$needle"*) deny "env-override" "$needle" ;;
            esac
        done

        case "$cmd" in
            *inbox-send*)
                case "$cmd" in
                    *--token*) deny "inbox-send-token" "$cmd" ;;
                esac
                ;;
        esac

        case "$cmd" in
            *'>'* | *tee* | *cp* | *mv* | *rm* | *rsync* | *dd* | *truncate* | *sed* | *install* | *chmod* | *chown*)
                case "$cmd" in
                    *"/inbox"* | *himmel-console*) deny "redirect-into-console-state" "$cmd" ;;
                esac
                case "$cmd" in
                    *-legN*)
                        case "$cmd" in
                            *-RESUME.md*) deny "redirect-into-console-state" "$cmd" ;;
                        esac
                        ;;
                esac
                ;;
        esac

        exit 0
        ;;
    *)
        exit 0
        ;;
esac
