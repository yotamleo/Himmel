#!/usr/bin/env bash
# scripts/lanes/bench/scorecard/lib/scorecard-lib.sh - shared reader helpers for
# the transcript-reading scorecard scripts (HIMMEL-3269).
#
# Platform guard: no .ps1 twin, by design. POSIX bash 3.2+ / grep / find / awk;
# it runs under git bash unchanged.
#
# Sourced, never executed. It is the ONE site for the three things every
# transcript reader must agree on, because a copy that drifts is how a metric
# ends up reported over an input set it never had (HIMMEL-3269):
#   1. which transcript roots a default run reads       (sc_transcript_roots)
#   2. which session title is a leg / relay / console   (role_of)
#   3. how much of the discovered input a number covers (sc_cov / sc_cov_line)
#
# Users: agg-burn.sh, agg-postpin.sh, extra-metrics.sh, leg-over-by-day.sh
# (all three parts); leg-relaunch.sh, ready-go-latency.sh (part 3 only).
# ledger-metrics.sh and merged-count.sh read `gh`/git, not transcripts, and print
# their own `coverage:` lines in the same shape.

# The transcript roots, one per line; the FIRST is the one that must exist.
#
# An explicit SCORECARD_PROJECTS_DIR is an explicit scope choice: exactly that
# one root, never widened. The default is the primary himmel project dir UNION
# every `<primary>--claude-worktrees-<slug>` sibling. Legs run in worktrees by
# design and each worktree gets its own project dir, so a primary-only default
# silently drops the session class the program is trying to make cheaper (253
# dirs, 21-29 % of ctx x calls measured on 2026-09-20). The glob is anchored on
# `--claude-worktrees-`, so an unrelated `<primary>foo` sibling is not swept in.
#
# ponytail: the primary dir name is this machine's himmel checkout path
# (`-home-overlord-Documents-github-himmel`), inherited from the original
# scorecard scripts - a checkout elsewhere must set SCORECARD_PROJECTS_DIR.
sc_transcript_roots() {
    if [ -n "${SCORECARD_PROJECTS_DIR:-}" ]; then
        printf '%s\n' "$SCORECARD_PROJECTS_DIR"
        return 0
    fi
    _sc_primary="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/-home-overlord-Documents-github-himmel"
    printf '%s\n' "$_sc_primary"
    for _sc_d in "$_sc_primary"--claude-worktrees-*; do
        [ -d "$_sc_d" ] && printf '%s\n' "$_sc_d"
    done
    return 0
}

# sc_roots_check <tool>: the primary root must exist, else exit-2 wording.
sc_roots_check() {
    _sc_first=$(sc_transcript_roots | head -1)
    [ -d "$_sc_first" ] || { echo "$1: transcript root not found: $_sc_first" >&2; return 2; }
}

# sc_discover <out-file> <err-file>: every *.jsonl under every root into
# <out-file>; find's stderr into <err-file>. Returns find's status so the
# caller can refuse a partial total, and sets SC_ROOT_COUNT for the coverage line.
sc_discover() {
    _sc_roots=()
    while IFS= read -r _sc_r; do _sc_roots+=("$_sc_r"); done <<EOF
$(sc_transcript_roots)
EOF
    # shellcheck disable=SC2034  # read by the sourcing script's sc_cov_line call
    SC_ROOT_COUNT=${#_sc_roots[@]}
    find "${_sc_roots[@]}" -name '*.jsonl' -type f >"$1" 2>"$2"
}

title_of() { grep -o '"customTitle":"[^"]*"' "$1" 2>/dev/null | tail -1 | sed 's/.*:"//; s/"$//'; }

# Session title -> role. A leg's title has been minted two ways: the early
# `...legN<k>...` scheme and the current `<TICKET>-N<k>-<slug>` scheme
# (e.g. HIMMEL-3270-N189-launch-logs-writer). The `legN` pattern alone matched
# 0 of the current legs, so `--role leg` returned a header row and no sessions.
# console and relay win over both (a `...legN..-relay` title is a relay).
#
# ponytail: the older `leg<Letter><k>` titles (legG3, legS1 ...) still fall to
# `other`; widening to them would move the 2026-09-05 control window's numbers.
role_of() {
    case "$1" in
        *-console*) echo console ;;
        *-relay*) echo relay ;;
        *legN*) echo leg ;;
        *) if [[ $1 =~ -N[0-9]+- ]]; then echo leg; else echo other; fi ;;
    esac
}

# sc_launch_context <launch-log-dir> <session-title>: prints the launch context
# mode the session actually received, `1m` or `standard`, read from the DURABLE
# console launch record (headed-arm.sh, HIMMEL-3279) - or `unknown`. Never a
# proxy from the session's own token counts (a pinned session that never grew
# past 175k and an unpinned one look identical). `unknown` covers no record,
# an unreadable one, ANY headed-arm row that does not carry exactly one usable
# context= field (a torn or doubled row is evidence of trouble, so it is never
# dropped in favour of a valid row beside it), and records that DISAGREE on the
# mode (the log is
# append-only with no attempt id, same reason as agg-postpin.sh's MULTI-LINE
# RULE: neither first nor last is provable).
sc_launch_context() {
    case "$2" in ""|*/*) echo unknown; return 0 ;; esac
    [ -r "$1/$2.log" ] || { echo unknown; return 0; }
    _sc_modes=$(awk '/^headed-arm:/ {n=0; v=""; for(i=1;i<=NF;i++) if($i ~ /^context=/) {n++; if($i ~ /^context=(1m|standard)$/) v=substr($i, 9)} m=(n==1 && v!="") ? v : "bad"; print m}' "$1/$2.log" | sort -u)
    case "$_sc_modes" in
        1m|standard) echo "$_sc_modes" ;;
        *) echo unknown ;;
    esac
}

# Coverage: every discovered input is either parsed into the metric or skipped
# for a NAMED reason, so a reader can tell an honest exclusion (out-of-window,
# other-role) from a loss (unreadable, bad-timestamp, leg-burn-failed).
SC_COV=""
sc_cov_init() { SC_COV=$(mktemp "${TMPDIR:-/tmp}/scorecard-cov.XXXXXX") || { echo "scorecard: mktemp failed" >&2; return 1; }; }
sc_cov() { printf '%s\n' "$1" >> "$SC_COV"; }

# sc_cov_line <discovered> [<roots>]: one stdout line. skipped is always
# discovered - parsed, so the triple sums; if the itemised reasons do not add
# up to it (a code path forgot to call sc_cov), the gap prints as `unclassified`
# rather than vanishing.
sc_cov_line() {
    _sc_p=$(grep -c '^parsed$' "$SC_COV" 2>/dev/null); _sc_p=${_sc_p:-0}
    _sc_k=$(grep -vc '^parsed$' "$SC_COV" 2>/dev/null); _sc_k=${_sc_k:-0}
    _sc_skipped=$(($1 - _sc_p))
    _sc_bk=$(grep -v '^parsed$' "$SC_COV" 2>/dev/null | sort | uniq -c | awk '{printf "%s%s=%s", (n++ ? " " : ""), $2, $1}')
    if [ "$_sc_skipped" -ne "$_sc_k" ]; then
        _sc_bk="${_sc_bk:+$_sc_bk }unclassified=$((_sc_skipped - _sc_k))"
    fi
    printf 'coverage:%s discovered=%s parsed=%s skipped=%s%s\n' \
        "${2:+ roots=$2}" "$1" "$_sc_p" "$_sc_skipped" "${_sc_bk:+ ($_sc_bk)}"
}
