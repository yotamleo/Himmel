#!/usr/bin/env bash
# nwo.sh — repo "name-with-owner" canonicalization + comparison (HIMMEL-2034).
#
# MOVED VERBATIM out of scripts/lib/cr-merge-gate.sh, which grew these helpers
# for the HIMMEL-936 merge gate. They are now shared: the CodeRabbit TRIGGER
# path (scripts/lib/cr-trigger-ledger.sh) has to answer the same question the
# merge gate does — "is this PR's repo OUR repo?" — and re-deriving origin-URL
# parsing there would be a second implementation of the ssh/https/userinfo/port
# cases these already handle.
#
# Sourced (not run); its own file rather than sourced-from-cr-merge-gate.sh
# because cr-merge-gate.sh pulls in five further libs, each behind a
# `$(cd … && pwd)` fork — ~1s each on Git Bash (see the perf note in
# _cmg_canon_nwo below) — and the trigger path runs inside a PostToolUse hook.
#
# The `_cmg_` prefix is DELIBERATELY retained: renaming would churn 16 call
# sites and comments in a load-bearing merge gate for zero behaviour change.
# bash 3.2-safe; uses only `return`, never `exit`.

# _cmg_canon_nwo <value> — canonical lowercase "owner/name", rc 1 if <value> is
# not one — as canonical "HOST/OWNER/NAME", host included. Two spellings would
# otherwise smuggle a merge past the gate (coderabbit-9), because anything that
# fails to compare equal to the local repo is treated as a foreign target and
# NOT gated:
#   - CASE: GitHub owner/name is case-insensitive, so `--repo O/R` is the SAME
#     repo as origin `o/r`. A bare string compare called it foreign.
#   - HOST: `gh` accepts `[HOST/]OWNER/REPO`, so `--repo github.com/o/r` is also
#     the same repo; the 3-segment form was being binned as malformed.
# The host is CARRIED, not dropped (coderabbit-11): `github.com/o/r` and
# `ghe.corp/o/r` are DIFFERENT repos that share an owner/name, and dropping the
# host made them compare equal — applying the local github availability answer to
# a GHE target. A bare `owner/repo` has no host, so it defaults to github.com
# (gh's own default host), which is what makes the common `--repo o/r` still
# match a `github.com/...` origin.
# Returns its answer in $_CMG_CANON rather than on stdout, and compares with a
# scoped `nocasematch` instead of lowercasing through `tr`. That is a
# PERFORMANCE contract, not a style choice: this gate runs in a PreToolUse hook
# on every `gh pr merge`, and on Git Bash a single fork costs ~1s. The first
# draft (`$(printf ... | tr ...)` twice per call) added ~3s to every merge and
# pushed the test suite past a 150s timeout. Parameter expansion forks nothing.
# (bash 3.2 has no ${v,,}, so nocasematch is the portable way to compare.)
_cmg_canon_nwo() {
    local v="${1:-}" host="github.com"
    _CMG_CANON=""
    case "$v" in
        ''|*[!A-Za-z0-9._/-]*) return 1 ;;      # empty or malformed charset
        */*/*/*) return 1 ;;                    # too many segments to be a repo spec
        */*/*) host=${v%%/*}; v=${v#*/} ;;      # HOST/OWNER/REPO -> host + OWNER/REPO
    esac
    case "$v" in
        /*|*/) return 1 ;;                      # leading/trailing slash
        */*) ;;                                 # OWNER/NAME — the only accepted shape
        *) return 1 ;;
    esac
    _CMG_CANON="$host/$v"
    return 0
}

# _cmg_nwo_eq <a> <b> — rc 0 iff both name the same repo, case-insensitively
# (GitHub owner/name is case-insensitive). nocasematch is saved and restored: a
# sourced lib must not leave shell options changed under its caller.
_cmg_nwo_eq() {
    local rc=0 had=0
    shopt -q nocasematch && had=1
    shopt -s nocasematch
    [[ "$1" == "$2" ]] || rc=1
    [ "$had" -eq 1 ] || shopt -u nocasematch
    return "$rc"
}

# _cmg_local_nwo — this clone's own <host>/<owner>/<name>, from origin. Empty
# when there is no origin or it is unparseable. Handles both URL shapes:
#   https://github.com/OWNER/NAME(.git)   git@github.com:OWNER/NAME(.git)
# The HOST is kept (coderabbit-11): _cmg_canon_nwo compares host + owner/name, so
# stripping it here would let a GHE origin be mistaken for its github.com
# namesake. The output feeds straight back into _cmg_canon_nwo (a HOST/OWNER/NAME
# is its 3-segment case), so both sides are canonicalized the same way.
_cmg_local_nwo() {
    local url rest host_nwo host path
    url=$(git config --get remote.origin.url 2>/dev/null) || return 1
    [ -n "$url" ] || return 1
    rest=${url%.git}
    case "$url" in
        # Strip userinfo in BOTH shapes (coderabbit-15): an `ssh://git@github.com/
        # o/r` origin otherwise yields `git@github.com/...`, whose `@` fails the
        # canon charset check, so the LOCAL clone becomes unidentifiable and every
        # `--repo` on it is waved through as foreign — a bypass on any ssh origin.
        *://*) host_nwo=${rest#*://}; host_nwo=${host_nwo#*@} ;; # scheme://[user@]host/owner/name
        *:*)   rest=${rest#*@};       host_nwo=${rest/://} ;;   # scp: [user@]host:owner/name -> host/owner/name
        *) return 1 ;;
    esac
    # Strip an optional :PORT off the HOST segment (CodeRabbit port-normalization
    # finding, PR #1470): a scheme-style origin with an explicit port —
    # `ssh://git@ghe.example.com:2222/o/r` or an https origin on a custom port —
    # leaves ":2222" glued onto host_nwo's host segment, and _cmg_canon_nwo's
    # charset check rejects ':'. That makes the LOCAL clone unidentifiable, so a
    # matching `--repo ghe.example.com/o/r` reads as foreign and the gate is
    # silently skipped. Applied AFTER the case above, on the already-split
    # host_nwo, so it is safe for BOTH branches: the scp branch's host_nwo can
    # never contain ':' here (an scp URL's one colon is the host/path separator,
    # already consumed by the `${rest/://}` substitution above), so this is a
    # no-op for it — only the scheme-style branch can carry a port.
    host=${host_nwo%%/*}
    path=${host_nwo#*/}
    host=${host%%:*}
    host_nwo="$host/$path"
    # host/owner/name (exactly three segments); reject anything else.
    case "$host_nwo" in
        */*/*/*|/*|*/) return 1 ;;
        */*/*) printf '%s\n' "$host_nwo" ;;
        *) return 1 ;;
    esac
}
