#!/usr/bin/env bash
# preflight-sim.sh — Pre-flight guardrail simulator (HIMMEL-475, C1).
#
# Given a batch of planned Bash commands (one per line on stdin), flag or rewrite
# the predictable himmel guardrail collisions BEFORE execution, so an autonomous
# run does not stall on a denial/hang it could have avoided. Static analysis only
# — it never executes a command and relaxes NO rail (advisory / rewrite only).
#
# Usage:
#   printf '%s\n' "cmd1" "cmd2" | bash scripts/guardrails/preflight-sim.sh
#   bash scripts/guardrails/preflight-sim.sh --learnings <file> < cmds.txt
#   bash scripts/guardrails/preflight-sim.sh --help
#
# Built-in rules:
#   [wsl-bash]      bare `bash ...` on Windows hits the WSL System32 stub — rewrite
#                   to the explicit Git Bash path.
#   [compound]      `&& || | ; $() backtick $var` makes the native permission
#                   matcher bail (HIMMEL-203) and hang in auto/headless.
#   [destructive-git] `git reset --hard` / `git checkout --` discard work.
#   [on-main-write] a redirect into an in-repo path is block-edit-on-main territory.
#
# Curated learnings: a checked-in file (default scripts/guardrails/preflight-learnings.txt)
# of `PATTERN|||VERDICT|||MESSAGE` lines, read on every invocation. Append a new
# block->fix pattern there and it applies next run (a deliberate act, not always-on
# observation). The fixtures under fixtures/preflight/ are the definition of correct;
# the boundary disclaims live-classifier parity.
#
# Exit: 0 = no collision predicted, 1 = at least one flag/rewrite, 2 = usage error.
# bash 3.2-safe; shellcheck-clean; cross-platform (Git Bash / macOS / Linux).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEARNINGS="$SCRIPT_DIR/preflight-learnings.txt"

usage() {
    # Header block only — stop at the first non-# line.
    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --learnings) [ $# -ge 2 ] || { printf 'preflight-sim: --learnings requires a value\n' >&2; exit 2; }
                     LEARNINGS="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) printf 'preflight-sim: unexpected argument: %s (commands are read from stdin)\n' "$1" >&2; exit 2 ;;
    esac
done

ANY_HIT=0
HIT=0

# Bare path to Git Bash on Windows — the explicit target for the WSL rewrite.
GITBASH='"C:\Program Files\Git\bin\bash.exe"'

apply_learnings() {
    [ -f "$LEARNINGS" ] || return 0
    while IFS= read -r _lline; do
        case "$_lline" in ''|'#'*) continue ;; esac
        # Fail closed on a malformed line (a typo missing a delimiter) — a curated
        # line must have BOTH `|||` separators, else skip it rather than emit garbage.
        case "$_lline" in *'|||'*'|||'*) : ;; *) continue ;; esac
        _pat="${_lline%%'|||'*}"
        _rest="${_lline#*'|||'}"
        _verdict="${_rest%%'|||'*}"
        _msg="${_rest#*'|||'}"
        [ -n "$_pat" ] || continue
        if printf '%s' "$1" | grep -qE -- "$_pat"; then
            printf '  %s[learned]: %s\n' "$_verdict" "$_msg"
            HIT=1
        fi
    done < "$LEARNINGS"
}

while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    printf '$ %s\n' "$cmd"
    HIT=0

    # [wsl-bash] — bare `bash` (or `& bash`) hits the WSL System32 stub on Windows.
    # Rewrite via parameter expansion, NOT sed: sed mangles the backslashes in the
    # Git Bash path (it treats `\X` specially in the replacement).
    if printf '%s' "$cmd" | grep -qE '^(& )?bash([[:space:]]|$)'; then
        if [ "${cmd#& bash}" != "$cmd" ]; then
            rewrite="& $GITBASH${cmd#& bash}"
        else
            rewrite="$GITBASH${cmd#bash}"
        fi
        printf "  REWRITE[wsl-bash]: bare 'bash' hits the WSL System32 stub on Windows (cannot read C:/, exit 127) — call Git Bash explicitly.\n"
        printf '  -> %s\n' "$rewrite"
        HIT=1
    fi

    # [compound] — a shell operator that makes the native matcher bail (HIMMEL-203).
    if printf '%s' "$cmd" | grep -qE '&&|[|]|;|`|[$][(]|<[(]|>[(]|[$][A-Za-z_{]'; then
        printf "  FLAG[compound]: a shell operator (&& || | ; \$() backtick \$var) makes the native permission matcher bail (HIMMEL-203) and hang in auto/headless — split into literal single commands.\n"
        HIT=1
    fi

    # [destructive-git] — reset --hard / checkout -- discard work irreversibly.
    if printf '%s' "$cmd" | grep -qE 'git[[:space:]]+reset[[:space:]]+--hard'; then
        printf "  FLAG[destructive-git]: 'git reset --hard' discards commits/working changes irreversibly — prefer a recoverable op (git stash) or confirm intent.\n"
        HIT=1
    elif printf '%s' "$cmd" | grep -qE 'git[[:space:]]+checkout[[:space:]]+(--([[:space:]]|$)|\.)'; then
        printf "  FLAG[destructive-git]: 'git checkout --' discards uncommitted changes to the named paths irreversibly — prefer 'git stash' or confirm intent.\n"
        HIT=1
    fi

    # [on-main-write] — a > / >> redirect into an in-repo (relative) path.
    redir="$(printf '%s' "$cmd" | grep -oE '>>?[[:space:]]*[^[:space:]&|;<>]+' | tail -1)"
    if [ -n "$redir" ]; then
        target="$(printf '%s' "$redir" | sed -E 's/^>>?[[:space:]]*//')"
        case "$target" in
            /dev/null|/*|'$'*|'"$'*) : ;;
            *)
                printf "  FLAG[on-main-write]: redirects into an in-repo path ('%s') — on main this is block-edit-on-main territory; send report output to a temp dir.\n" "$target"
                HIT=1 ;;
        esac
    fi

    apply_learnings "$cmd"

    if [ "$HIT" -eq 0 ]; then
        printf '  OK: no predicted guardrail collision.\n'
    else
        ANY_HIT=1
    fi
done

[ "$ANY_HIT" -eq 0 ] && exit 0 || exit 1
