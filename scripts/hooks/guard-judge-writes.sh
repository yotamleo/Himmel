#!/usr/bin/env bash
# guard-judge-writes.sh — PreToolUse hook (matcher
# "Bash|Edit|Write|MultiEdit|NotebookEdit|mcp__.*"): [HIMMEL-4564].
#
# A console judge only advises: it reads, writes its verdict, appends Results
# bullets to its own doc, and reports by SendMessage. headed-arm-leg.sh --judge
# exports HIMMEL_CONSOLE_JUDGE=1 into the judge session; this guard denies that
# session every outward or mutating transition a judge has no business making.
#
# Delivered by the himmel-ops PLUGIN lane, not the project lane: a judge's cwd
# is its resume_cwd under ~/.cache/himmel/verdicts/<qid>/scratch, outside any
# checkout, so project settings (and a $CLAUDE_PROJECT_DIR-anchored hook) never
# load there. The plugin copy is byte-identical to this file and sources
# nothing, for the same reason.
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Not ported to native PowerShell — the judge lane (headed-arm-leg.sh --judge)
# is Linux-only.
#
# TRIP CONDITION: HIMMEL_CONSOLE_JUDGE=1 in this process's environment AND one
# of:
#   Bash — the command text names HIMMEL_CONSOLE_JUDGE (an override or unset
#     of the marker); or names leg-pr-open, merge-on-green, console-kit/go.sh,
#     inbox-send or leg-jira-status; or has the word "git" and a mutating git
#     verb (push, commit, merge, rebase, reset, cherry-pick, revert); or the
#     word "gh" and a write verb (create, comment, review, merge, edit, close,
#     reopen, ready, delete, lock, unlock, transfer); or "gh api" with a
#     method or body flag (-X, --method, -f, -F, --field, --raw-field,
#     --input); or the Jira CLI (a word ending in "jira" or naming
#     scripts/jira/) with a write op (create, comment, transition, update,
#     edit, assign, link, delete, worklog, attach).
#   mcp__* — any MCP tool other than qmd (mcp__qmd__*, mcp__plugin_qmd_qmd__*).
#   Write|Edit|MultiEdit|NotebookEdit — the path is relative or has a ".."
#     segment; or it cannot be resolved (readlink -f, then parent + missing
#     leaf); or the RESOLVED path is outside every allowed place:
#       - $HOME/.cache/himmel/verdicts/ (the judge's scratch),
#       - under $HANDOVER_DIR but not its inbox/, inside a verdicts/ dir or a
#         file whose basename matches *-judge-*.md (the verdict, its own doc).
#     With HANDOVER_DIR unset only the cache is allowed.
#
# DEFAULT ACTION: with the marker unset this hook is a silent no-op — the
# marker check is the FIRST statement, before stdin is read. With the marker
# set it is a SECURITY FENCE and fails CLOSED: missing jq, an unparseable
# payload or a field of the wrong type all DENY.
#
# RESIDUAL (deliberate): the Bash checks are textual, over whitespace and
# shell-separator words, not a shell parser — eval, a wrapper script that does
# the write itself, curl to an API, or a write verb this vocabulary does not
# list still pass. Over-matching (a read whose text merely carries a verb word,
# e.g. `gh pr view 12 --comments` is fine but `git log --grep push` denies) is
# the safe direction. Any verdicts/ dir under the handover root is writable,
# not only this judge's own qid.
#
# BYPASS: launch the session without --judge (the marker is then unset). There
# is no per-call bypass.
#
# Bash 3.2-compatible. Exit codes: 0 allow (no output); 2 deny (JSON
# hookSpecificOutput with permissionDecision "deny" on stdout,
# permissionDecisionReason starting "judge write-deny: ").
# git-env-ok: no git invocation; "git" is only a word matched in the screened command text
set -uo pipefail

# Zero-cost no-op for every non-judge session.
[ "${HIMMEL_CONSOLE_JUDGE:-}" = "1" ] || exit 0

deny() {
    # deny <rule> <fragment>
    local reason
    reason=$(printf '%s' "judge write-deny: $1 ($2) — a judge reports by SendMessage and writes only its verdict, its own doc and its cache scratch" | jq -Rs . 2>/dev/null) \
        || reason='"judge write-deny: denied"'
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$reason"
    exit 2
}

command -v jq >/dev/null 2>&1 || deny "unparseable-payload" "jq not on PATH"

input=$(cat 2>/dev/null || true)
[ -n "$input" ] || deny "unparseable-payload" "empty stdin"

if ! tool=$(printf '%s' "$input" | jq -r '.tool_name | select(type == "string") // empty' 2>/dev/null); then
    deny "unparseable-payload" "cannot parse JSON stdin"
fi
[ -n "$tool" ] || deny "unparseable-payload" "no tool_name"

# has_word <word>... — true if any listed word is a whole word of $words.
has_word() {
    local w t
    for w in "$@"; do
        for t in $words; do
            [ "$t" = "$w" ] && return 0
        done
    done
    return 1
}

# resolve <abs-path> — physical path; a missing final component resolves
# through its existing parent. Returns 1 when neither resolves.
resolve() {
    local p="$1" parent leaf r
    r=$(readlink -f -- "$p" 2>/dev/null) && [ -n "$r" ] && { printf '%s\n' "$r"; return 0; }
    case "$p" in */) return 1 ;; esac
    leaf="${p##*/}"
    parent="${p%/*}"
    [ -n "$parent" ] || parent="/"
    [ -d "$parent" ] || return 1
    r=$(readlink -f -- "$parent" 2>/dev/null) && [ -n "$r" ] || return 1
    [ "$r" = "/" ] && r=""
    printf '%s\n' "$r/$leaf"
}

case "$tool" in
    Bash)
        cmd_type=$(printf '%s' "$input" | jq -r '.tool_input.command | type' 2>/dev/null) \
            || deny "unparseable-payload" "cannot read command"
        [ "$cmd_type" = "string" ] || deny "unparseable-payload" "command not a string"
        cmd=$(printf '%s' "$input" | jq -r '.tool_input.command' 2>/dev/null) \
            || deny "unparseable-payload" "cannot read command"

        case "$cmd" in
            *HIMMEL_CONSOLE_JUDGE*) deny "marker-override" "command names HIMMEL_CONSOLE_JUDGE" ;;
            *leg-pr-open*) deny "pr-open" "leg-pr-open" ;;
            *merge-on-green*) deny "merge" "merge-on-green" ;;
            *console-kit/go.sh*) deny "go" "console-kit/go.sh" ;;
            *inbox-send*) deny "inbox-send" "inbox-send" ;;
            *leg-jira-status*) deny "jira-write" "leg-jira-status" ;;
        esac

        # Words: split on whitespace and shell separators, quotes dropped.
        words=$(printf '%s' "$cmd" | tr ';|&()<>`"'"'"'\n\t\r' '             ')

        if has_word git && has_word push commit merge rebase reset cherry-pick revert; then
            deny "git-write" "mutating git verb"
        fi
        if has_word gh; then
            has_word create comment review merge edit close reopen ready delete lock unlock transfer \
                && deny "gh-write" "gh write verb"
            if has_word api; then
                for t in $words; do
                    case "$t" in
                        -X* | --method* | -f* | -F* | --field* | --raw-field* | --input*)
                            deny "gh-write" "gh api $t" ;;
                    esac
                done
            fi
        fi
        jira=0
        for t in $words; do
            case "$t" in
                *jira | */scripts/jira/* | scripts/jira/*) jira=1 ;;
            esac
        done
        if [ "$jira" -eq 1 ] && has_word create comment transition update edit assign link delete worklog attach; then
            deny "jira-write" "Jira CLI write op"
        fi
        exit 0
        ;;
    mcp__qmd__* | mcp__plugin_qmd_qmd__*)
        exit 0
        ;;
    mcp__*)
        deny "mcp" "$tool"
        ;;
    Write | Edit | MultiEdit | NotebookEdit)
        field=file_path
        [ "$tool" = "NotebookEdit" ] && field=notebook_path
        path_type=$(printf '%s' "$input" | jq -r --arg f "$field" '(.tool_input[$f] // .tool_input.file_path) | type' 2>/dev/null) \
            || deny "unparseable-payload" "cannot read path"
        [ "$path_type" = "string" ] || deny "unparseable-payload" "path not a string"
        path=$(printf '%s' "$input" | jq -r --arg f "$field" '.tool_input[$f] // .tool_input.file_path' 2>/dev/null) \
            || deny "unparseable-payload" "cannot read path"

        case "$path" in
            /*) ;;
            *) deny "write-outside" "relative path" ;;
        esac
        case "/$path/" in
            */../*) deny "write-outside" "'..' segment" ;;
        esac
        resolved=$(resolve "$path") || deny "write-outside" "path does not resolve"

        cache=$(resolve "$HOME/.cache/himmel/verdicts") || cache="$HOME/.cache/himmel/verdicts"
        case "$resolved" in
            "$cache"/*) exit 0 ;;
        esac
        if [ -n "${HANDOVER_DIR:-}" ]; then
            root=$(resolve "$HANDOVER_DIR") || deny "write-outside" "handover root does not resolve"
            case "$resolved" in
                "$root"/inbox/*) ;;
                "$root"/*/verdicts/* | "$root"/verdicts/*) exit 0 ;;
                "$root"/*-judge-*.md)
                    case "${resolved##*/}" in
                        *-judge-*.md) exit 0 ;;
                    esac
                    ;;
            esac
        fi
        deny "write-outside" "$resolved"
        ;;
esac
exit 0
