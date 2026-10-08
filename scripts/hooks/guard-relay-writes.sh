#!/usr/bin/env bash
# guard-relay-writes.sh — PreToolUse hook (matchers "Bash" and
# "Edit|Write|MultiEdit|NotebookEdit"): [HIMMEL-2975] Guard D.
#
# HIMMEL-2975 splits a console's duties: a Sonnet RELAY carries its tokenless
# traffic, and a JUDGE only advises -- the console alone sends token-quoting
# messages.
# headed-arm-leg.sh --relay (Task 25, #752) exports HIMMEL_CONSOLE_RELAY=1
# into the relay leg. Guard D denies the relay every write channel into
# console state — the inbox dir, every leg handover doc, the console rundir
# under /run/user or $TMPDIR — and denies the Bash shapes that would defeat
# Guard B (env-prefix override of the identity/marker vars this leg's own
# session-name resolution and inbox-send.sh's relay check read) and Guard C
# (inbox-send.sh --token, reserved for the console).
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Not ported to native PowerShell — the console relay lane
# (headed-arm-leg.sh --relay, scripts/handover/console-kit/) is Linux-only,
# same as inbox-send.sh's own platform guard.
#
# TRIP CONDITION: HIMMEL_CONSOLE_RELAY=1 in this process's environment AND
# one of:
#   Write|Edit|MultiEdit|NotebookEdit — the resolved file_path (notebook_path
#     for NotebookEdit) contains an unresolved ".." path segment (denied
#     outright, fail-closed, before any guarded-path match); or
#     <handover_root> fails to resolve, or the path itself fails to resolve
#     (`readlink -f`, every "./" segment and every symlink including the
#     final component included — denied fail-closed rather than silently
#     skipping the guarded-path match; on a BSD readlink, detected by a
#     one-time probe, a missing FINAL component alone is resolved through its
#     parent, fail-closed — HIMMEL-3872); or the PHYSICALLY resolved path is under
#     <handover_root>/inbox/, under a .../himmel-console/... rundir, under
#     ${TMPDIR:-/tmp}/himmel-console-*, or its basename matches
#     *-legN*-RESUME.md.
#   Bash — the command text contains HIMMEL_CONSOLE_RELAY, HIMMEL_CONSOLE_LEG,
#     SESSION_NAME_CMDLINE_FILE, CLAUDE_PID or CONSOLE_SESSION_NAME (an
#     env-prefix override, `unset`, or `env -u` of an identity/marker
#     variable); or contains "inbox-send" AND "--token"; or contains a
#     write-shaped verb (">", or the command WORD "tee", "cp", "cpio", "mv",
#     "rm", "rmdir", "rsync", "dd", "ddrescue", "truncate", "sed", "install",
#     "chmod", "chown" —
#     a word is bounded by the string edge or any char outside [[:alnum:]_])
#     AND text naming "/inbox/", "himmel-console", or both "-legN" and
#     "-RESUME.md".
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
# RESIDUAL (false-deny, fail-safe direction): the write verb is matched as a
# command WORD (HIMMEL-3202 — it was an unanchored substring, which denied
# `grep -c address <inbox-path>` on "dd" and a read under a random mktemp dir
# whose name spelled a verb). A verb that is a whole word anywhere in the text
# still counts, whether or not it is in command position, so a pure READ that
# names a guarded path and carries the verb as a standalone word is denied:
# `sed -n 1,20p <inbox-path>` (sed IS the verb), or a path with a whole
# component `/rm/` or `/dd/` (e.g. a macOS $TMPDIR `/var/folders/dd/...`).
# Over-denying a read is the safe direction; ask the console to relay the
# content instead. The opposite direction is unchanged and still open: a verb
# glued into a longer command name (`gsed`, `gdd`, a wrapper `mycp`) is not a
# word here — same fixed-vocabulary residual (R2) as an uncommon utility.
#
# Bash 3.2-compatible. Exit codes: 0 allow (no output); 2 deny (JSON
# hookSpecificOutput with permissionDecision "deny" on stdout,
# permissionDecisionReason starting "relay write-deny: ").
set -uo pipefail

# Zero-cost no-op for every non-relay session: no stdin read, no jq, no
# sourcing — before anything else runs.
[ "${HIMMEL_CONSOLE_RELAY:-}" = "1" ] || exit 0

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# HIMMEL-4449: handover_root reads only the live env; feed it the .env HANDOVER_DIR first.
# shellcheck disable=SC1091
if . "$HERE/../lib/load-dotenv.sh" 2>/dev/null; then load_dotenv HANDOVER_DIR 2>/dev/null || true; fi
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

# HIMMEL-3872 one-time capability probe: does this readlink -f resolve a
# missing final component under an existing directory (GNU) or refuse it
# (BSD/macOS realpath(3))? Succeeds only on an exact, positive GNU answer;
# any error or ambiguity is "no", which merely lets the fail-closed fallback
# below run. Called at most once, and only after readlink -f has failed.
readlink_resolves_missing_leaf() {
    local d d_resolved got
    d="$(mktemp -d "${TMPDIR:-/tmp}/relay-probe.XXXXXX" 2>/dev/null)" || return 1
    [ -n "$d" ] || return 1
    d_resolved="$(readlink -f -- "$d" 2>/dev/null)" || d_resolved=""
    got="$(readlink -f -- "$d/probe-leaf" 2>/dev/null)" || got=""
    rmdir -- "$d" 2>/dev/null
    [ -n "$d_resolved" ] && [ "$got" = "$d_resolved/probe-leaf" ]
}

# HIMMEL-3872 BSD fallback: resolve <parent>/<leaf> when ONLY the final
# component is missing. Prints the resolved path, or returns 1 for every case
# it cannot prove: a relative path, a trailing slash, a newline anywhere in
# the path (command substitution would strip it), an empty/"."/".." leaf,
# a parent that is not an existing traversable directory (a missing
# intermediate dir, or a chmod-000 parent hiding a symlink), a leaf that
# exists in any form (a dangling symlink included), a leaf longer than
# NAME_MAX, or a result longer than PATH_MAX. Every path it resolves is one
# GNU readlink -f resolves to the same string, so even a probe that wrongly
# says "BSD" on GNU cannot widen an allow.
resolve_missing_leaf() {
    local p="$1" parent leaf parent_resolved name_max path_max leaf_len out out_len
    case "$p" in
        /*) ;;
        *) return 1 ;;
    esac
    case "$p" in
        */ | *$'\n'*) return 1 ;;
    esac
    leaf="${p##*/}"
    parent="${p%/*}"
    [ -n "$parent" ] || parent="/"
    case "$leaf" in
        "" | . | ..) return 1 ;;
    esac
    { [ -d "$parent" ] && [ -x "$parent" ]; } || return 1
    { [ ! -e "$p" ] && [ ! -L "$p" ]; } || return 1
    parent_resolved="$(readlink -f -- "$parent" 2>/dev/null)" || return 1
    { [ -n "$parent_resolved" ] && [ -d "$parent_resolved" ] && [ -x "$parent_resolved" ]; } || return 1
    name_max="$(getconf NAME_MAX "$parent_resolved" 2>/dev/null)" || return 1
    path_max="$(getconf PATH_MAX "$parent_resolved" 2>/dev/null)" || return 1
    leaf_len="$(printf '%s' "$leaf" | LC_ALL=C wc -c 2>/dev/null)" || return 1
    leaf_len="${leaf_len//[[:space:]]/}"
    case "$parent_resolved" in
        /) out="/$leaf" ;;
        *) out="$parent_resolved/$leaf" ;;
    esac
    out_len="$(printf '%s' "$out" | LC_ALL=C wc -c 2>/dev/null)" || return 1
    out_len="${out_len//[[:space:]]/}"
    case "$name_max$path_max$leaf_len$out_len" in
        *[!0-9]*) return 1 ;;
    esac
    { [ -n "$name_max" ] && [ -n "$path_max" ] && [ -n "$leaf_len" ] && [ -n "$out_len" ]; } || return 1
    [ "$leaf_len" -le "$name_max" ] || return 1
    [ "$out_len" -lt "$path_max" ] || return 1
    printf '%s\n' "$out"
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
            path_type=$(printf '%s' "$input" | jq -r '(.tool_input.notebook_path // .tool_input.file_path) | type' 2>/dev/null) \
                || deny "unparseable-payload" "cannot read notebook_path type"
            case "$path_type" in
                string | null) ;;
                *) deny "unparseable-payload" "notebook_path/file_path not a string" ;;
            esac
            path=$(printf '%s' "$input" | jq -r '.tool_input.notebook_path // .tool_input.file_path // empty' 2>/dev/null) \
                || deny "unparseable-payload" "cannot read notebook_path"
        else
            path_type=$(printf '%s' "$input" | jq -r '.tool_input.file_path | type' 2>/dev/null) \
                || deny "unparseable-payload" "cannot read file_path type"
            case "$path_type" in
                string | null) ;;
                *) deny "unparseable-payload" "file_path not a string" ;;
            esac
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
        # symlink in every component including the final one (`readlink -f`)
        # — before matching against a guarded prefix. A dir-only resolution
        # still lets an innocuously-named symlink whose FINAL component points
        # into a guarded dir slip past a literal-string glob (codex-1). GNU
        # readlink -f only requires the path up to the last component to
        # exist, so a brand-new file under an existing directory resolves
        # cleanly; BSD/macOS readlink -f (realpath(3)) refuses a missing final
        # component (HIMMEL-3872). Only when resolution fails AND the one-time
        # probe says this readlink is the BSD kind does the fallback run — on
        # GNU it never runs, so GNU enforcement is identical by construction.
        path_resolved=""
        if path_resolved="$(readlink -f -- "$path" 2>/dev/null)" && [ -n "$path_resolved" ]; then
            :
        elif readlink_resolves_missing_leaf; then
            deny "unresolved-path" "$path"
        else
            path_resolved="$(resolve_missing_leaf "$path")" || deny "unresolved-path" "$path"
            [ -n "$path_resolved" ] || deny "unresolved-path" "$path"
        fi
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
        cmd_type=$(printf '%s' "$input" | jq -r '.tool_input.command | type' 2>/dev/null) \
            || deny "unparseable-payload" "cannot read command type"
        case "$cmd_type" in
            string | null) ;;
            *) deny "unparseable-payload" "command not a string" ;;
        esac
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

        # A write verb counts only as a command WORD: not embedded in a longer
        # alphanumeric word (HIMMEL-3202 — "address", "form", a mktemp suffix
        # like "mVddVZ"). The boundary is "any char that is not [[:alnum:]_]"
        # (or the string edge), so `/bin/rm`, `sudo rm`, `xargs rm`, `(cp`,
        # `;mv` and a newline-separated `rm` all still match. Kept in a variable:
        # bash 3.2 needs the ERE unquoted on the right of =~. `rmdir`, `cpio`
        # and `ddrescue` are listed because each is a real write utility whose
        # name STARTS with a listed verb and so used to be caught only as a
        # substring of it — the word boundary would otherwise flip them to allow.
        write_verb_re='(^|[^[:alnum:]_])(tee|cp|cpio|mv|rm|rmdir|rsync|dd|ddrescue|truncate|sed|install|chmod|chown)([^[:alnum:]_]|$)'
        write_shaped=0
        case "$cmd" in
            *'>'*) write_shaped=1 ;;
        esac
        if [ "$write_shaped" = "0" ] && [[ "$cmd" =~ $write_verb_re ]]; then
            write_shaped=1
        fi

        if [ "$write_shaped" = "1" ]; then
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
        fi

        exit 0
        ;;
    *)
        exit 0
        ;;
esac
