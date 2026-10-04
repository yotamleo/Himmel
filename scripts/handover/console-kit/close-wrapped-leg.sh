#!/usr/bin/env bash
# scripts/handover/console-kit/close-wrapped-leg.sh - console-run wrapped-leg
# window close (HIMMEL-3572 row 7). A console's `kill <konsole pid>` is
# classifier-denied [Interfere With Workloads] when typed as a bare literal -
# this script wraps the same TERM under a literal the classifier allowlists,
# but ONLY after verifying the leg is actually done: the queue lock on its
# doc is free AND its own last Results marker-bullet is WRAPPED. It never
# kills a pid it cannot independently prove belongs to that leg.
#
# Usage: close-wrapped-leg.sh [--fleet <manifest>] <leg-doc>
# --fleet removes the doc after a successful close, including benign prune skips.
# A manifest update failure returns 1 after the session has already closed.
#
# Refuses (nothing signaled) unless:
#   - `queue-lock.sh status <leg-doc>` reports free (rc=0);
#   - the doc's last `## Results` marker-bullet (one of LIVE/FINDING/
#     RESOLVED/READY/BLOCKED/HALTED/WRAPPED, leading token of the newest
#     such bullet) is WRAPPED;
#   - exactly one live `claude` session's real argv (via
#     scripts/lanes/lib/claude-sessions.sh's claude_sessions, /proc-argv
#     based, never a flattened pgrep -af scan) carries a `-n <name>` naming
#     the leg (names derived by scripts/lib/leg-identity.sh's leg_identity -
#     the doc stem, its undated form, and any legacy-family derived name).
# TERM goes to that one pid only - it never signals a non-matching pid, and
# 0 or >1 matches is a refusal, not a best guess.
#
# After the signal, the leg's own /tmp scratch (its judge dirs, and its session
# scratch dir) is archived then reaped via tmp-reap.sh, scoped to this leg only
# (HIMMEL-4235); a reap failure warns and never fails the close.
#
# Then, if the doc names exactly one worktree path (a
# `.claude/worktrees/...` path appearing once), runs
# `scripts/clean.sh --only <worktree> --only-allow-unmerged` and reports (not
# fails) a "not pruned" skip. That flag (HIMMEL-3747) makes clean-garden.sh
# itself resolve the worktree's branch's PR by branch (via gh, independent of
# whatever the doc's own Results bullets say) and prune when: the PR is
# MERGED with a head match (the original, unwidened case -- also covers a doc
# with no MERGED/READY bullet at all, since the branch lookup does not depend
# on one), OR the PR is CLOSED unmerged or there is no PR, the working tree is
# clean, and the branch's head is either pushed to origin or carries no
# commits beyond main. An OPEN PR (a parked leg) or an unresolvable PR state
# (gh/cache failure) are never pruned. Never guesses a worktree: 0 or >1
# candidates in the doc skips the prune with a report.
#
# Before signalling (HIMMEL-3747), reuses scripts/handover/wrap-subtree-check.sh
# on the matched pid: a non-harness descendant still alive (a leg mid an
# operator command, a tool call in flight) refuses the TERM rather than
# killing it out from under that work - never guessed, never overridden.
# A withheld subtree is not a failure: the console re-runs this script later,
# same as any other "retry shortly" refusal here.
#
# Exit codes:
#   0  signaled (prune ran, skipped, or reported "in use" - all non-fatal)
#   1  gh/git/queue-lock plumbing failure, or the TERM signal itself failed
#   2  usage (missing/unreadable doc)
#   3  refused - the queue lock is not free
#   4  refused - the doc's last marker-bullet is not WRAPPED
#   5  refused - 0 or >1 live sessions matched the leg's names
#   6  refused - the matched session still has a non-harness process alive
#      (wrap-subtree-check.sh reported WITHHELD, or could not prove CLOSABLE)
#
# Platform guard: Linux bash 3.2+ (depends on /proc via claude-sessions.sh;
# no .ps1 twin - konsole legs are Linux/KDE-only, same guard as
# headed-arm-leg.sh's konsole launch path).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
KILL="${KILL_BIN:-kill}"
CLEAN_SH="${CLEAN_SH_BIN:-$HERE/../../clean.sh}"
WRAP_SUBTREE_CHECK="${WRAP_SUBTREE_CHECK_BIN:-$HERE/../wrap-subtree-check.sh}"
TMP_REAP="${TMP_REAP_BIN:-$HERE/../../tmp-reap.sh}"

usage() {
    echo "usage: close-wrapped-leg.sh [--fleet <manifest>] <leg-doc>" >&2
}

FLEET_MANIFEST=""
if [ "${1:-}" = --fleet ]; then
    if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then usage; exit 2; fi
    FLEET_MANIFEST="$2"; shift 2
fi

# Only successful close exits retire the leg; refusals and failed pruning keep it.
close_success() {
    if [ -n "$FLEET_MANIFEST" ] && ! bash "$HERE/fleet-manifest.sh" remove "$FLEET_MANIFEST" "$DOC"; then
        echo "close-wrapped-leg: session closed but fleet manifest update failed: $FLEET_MANIFEST" >&2
        exit 1
    fi
    exit 0
}

if [ "$#" -ne 1 ]; then
    usage
    exit 2
fi
DOC="$1"
if [ ! -f "$DOC" ] || [ ! -r "$DOC" ]; then
    usage
    echo "close-wrapped-leg: cannot read doc '$DOC'" >&2
    exit 2
fi

if ! bash "$HERE/../queue-lock.sh" status "$DOC" >/dev/null 2>&1; then
    echo "close-wrapped-leg: refusing - the queue lock on $DOC is not free" >&2
    exit 3
fi

# shellcheck source=scripts/lib/leg-tail-status.sh
# shellcheck disable=SC1091
if ! . "$HERE/../../lib/leg-tail-status.sh"; then
    echo "close-wrapped-leg: cannot load scripts/lib/leg-tail-status.sh" >&2
    exit 1
fi

last_marker=$(leg_tail_status "$DOC")
if [ "$last_marker" != "WRAPPED" ]; then
    echo "close-wrapped-leg: refusing - the doc's last Results marker-bullet is '${last_marker:-<none>}', not WRAPPED" >&2
    exit 4
fi

# shellcheck source=scripts/lib/leg-identity.sh
# shellcheck disable=SC1091
if ! . "$HERE/../../lib/leg-identity.sh"; then
    echo "close-wrapped-leg: cannot load scripts/lib/leg-identity.sh" >&2
    exit 1
fi
# shellcheck source=scripts/lanes/lib/claude-sessions.sh
# shellcheck disable=SC1091
if ! . "$HERE/../../lanes/lib/claude-sessions.sh"; then
    echo "close-wrapped-leg: cannot load scripts/lanes/lib/claude-sessions.sh" >&2
    exit 1
fi

ident=$(leg_identity "$DOC")
# HIMMEL-3638 console add-on: leg_identity's names strip -RESUME, but a
# console may launch a leg's session under the FULL doc stem (-RESUME and
# date intact) - accept that shape too, locally here (not in leg-identity.sh,
# which other callers rely on for the stripped forms).
doc_stem="$(basename "$DOC" .md)"
names=",${ident#*$'\t'},${doc_stem},"

sessions=$(claude_sessions)
census_rc=$?
if [ "$census_rc" -gt 1 ]; then
    echo "close-wrapped-leg: claude_sessions census failed (rc=$census_rc)" >&2
    exit 1
fi

matched=""
match_count=0
while IFS=$'\t' read -r pid name _model _ac; do
    [ -n "$pid" ] || continue
    case "$name" in
        '#'*) continue ;;
    esac
    case "$names" in
        *",${name},"*)
            matched="$pid"
            match_count=$((match_count + 1)) ;;
    esac
done <<EOF
$sessions
EOF

if [ "$match_count" -ne 1 ]; then
    echo "close-wrapped-leg: refusing - $match_count live session(s) matched leg names [${ident#*$'\t'}] (need exactly 1)" >&2
    exit 5
fi

# ---------- Pre-signal session-note capture (HIMMEL-3629) --------------------
# A wrapped leg's SessionEnd hook never runs: Claude Code cancels it the
# instant our TERM below lands, so no luna session note is written. Reproduce
# the hook's input here, from what we already resolved above (the leg's
# session names) - never a guess: resolve those names to EXACTLY ONE
# transcript file (same customTitle-grep precedent as leg-burn.sh's
# session-name lookup, but refusing instead of picking "newest" on
# ambiguity), pull cwd straight from that transcript (every row carries a
# "cwd" field), derive session_id from the transcript's own filename, and
# feed end-session-wiki.sh the same SessionEnd JSON shape Claude Code would
# have. 0 or >1 matching transcripts: say so on stderr and still close -
# never guess which one. The hook itself dedups by session_id (HIMMEL-3629),
# so it is harmless if the leg's own SessionEnd ALSO manages to fire.
TRANSCRIPT=""
END_SESSION_WIKI="${END_SESSION_WIKI_BIN:-$HERE/../../hooks/end-session-wiki.sh}"
PROJECTS_DIR="${CLOSE_WRAPPED_LEG_PROJECTS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects}"
if [ -r "$END_SESSION_WIKI" ] && [ -d "$PROJECTS_DIR" ]; then
    # HIMMEL-3638: a plain `grep -rlF ... "$PROJECTS_DIR"` reads every byte of
    # every transcript ever written across the whole projects tree (5.6 GB) -
    # minutes per close. A wrapped leg's own transcript is always from TODAY,
    # and customTitle (when set) is near the top of the file, so bound both
    # axes: only today's files (mtime), only their first N lines (head) -
    # same "exactly one match, else skip" semantics as before.
    mtime_window="${CLOSE_WRAPPED_LEG_MTIME_DAYS:-1}"
    head_window="${CLOSE_WRAPPED_LEG_CUSTOMTITLE_HEAD:-40}"
    candidates=$(printf '%s\n%s\n' "${ident#*$'\t'}" "$doc_stem" | tr ',' '\n' | sed '/^$/d')
    match_transcripts() {
        local files="$1" hw="$2" matches="" f hit cand
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            if [ "$hw" -eq 0 ]; then
                # codex-2: the all-time fallback scans whole-repo-age
                # transcripts, so grep the file directly per candidate
                # instead of slurping it into a shell variable first --
                # a multi-GB transcript otherwise loads entirely into memory
                # just to be thrown away after one match.
                while IFS= read -r cand; do
                    [ -n "$cand" ] || continue
                    if grep -qF "\"customTitle\":\"$cand\"" "$f" 2>/dev/null; then
                        matches="${matches}
${f}"
                        break
                    fi
                done <<EOF
$candidates
EOF
            else
                hit=$(head -n "$hw" "$f" 2>/dev/null)
                while IFS= read -r cand; do
                    [ -n "$cand" ] || continue
                    if printf '%s' "$hit" | grep -qF "\"customTitle\":\"$cand\""; then  # pipefail-ok: no pipefail here (set -u only); $hit is an already-captured small string, not a live producer
                        matches="${matches}
${f}"
                        break
                    fi
                done <<EOF
$candidates
EOF
            fi
        done <<EOF
$files
EOF
        printf '%s\n' "$matches" | sed '/^$/d' | sort -u
    }
    scan_files=$(find "$PROJECTS_DIR" -type f -name '*.jsonl' -mtime "-${mtime_window}" 2>/dev/null)
    transcript_matches=$(match_transcripts "$scan_files" "$head_window")
    tcount=$(printf '%s\n' "$transcript_matches" | grep -c . || true)
    if [ "$tcount" -eq 0 ]; then
        # F3/codex-3: -mtime is a rolling window, not "today", and a target
        # transcript outside it can be missed even while OTHER, unrelated
        # transcripts fall inside it (an empty-scan_files check alone would
        # miss that case). Retry against the full tree whenever the SCOPED
        # search found no MATCH, not only when it found no files at all.
        # codex-2 (round 4): the fallback must also drop the head-window
        # bound - a customTitle past line $head_window is unmatchable in
        # either pass otherwise. Pass 0 = unbounded (whole file).
        scan_files=$(find "$PROJECTS_DIR" -type f -name '*.jsonl' 2>/dev/null)
        transcript_matches=$(match_transcripts "$scan_files" 0)
        tcount=$(printf '%s\n' "$transcript_matches" | grep -c . || true)
    fi
    if [ "$tcount" -eq 1 ]; then
        TRANSCRIPT="$transcript_matches"
        cap_cwd=$(jq -r 'select(.cwd != null) | .cwd' "$TRANSCRIPT" 2>/dev/null | head -1)
        cap_sid=$(basename "$TRANSCRIPT" .jsonl)
        if [ -n "$cap_cwd" ]; then
            cap_payload=$(jq -n --arg t "$TRANSCRIPT" --arg s "$cap_sid" --arg c "$cap_cwd" --arg r "leg-close" \
                '{transcript_path:$t, session_id:$s, cwd:$c, reason:$r}')
            if printf '%s' "$cap_payload" | bash "$END_SESSION_WIKI" >/dev/null 2>&1; then
                echo "close-wrapped-leg: captured session note for $cap_sid before signalling"
            else
                echo "close-wrapped-leg: end-session-wiki failed for $cap_sid - closing anyway, never blocking on it" >&2
            fi
        else
            echo "close-wrapped-leg: resolved transcript $TRANSCRIPT has no 'cwd' field - skipping the pre-signal capture, never guessing" >&2
        fi
    else
        echo "close-wrapped-leg: $tcount transcript(s) matched leg names [${ident#*$'\t'}] - cannot resolve unambiguously, skipping the pre-signal capture, never guessing" >&2
    fi
fi

subtree_out=$(bash "$WRAP_SUBTREE_CHECK" "$matched" 2>&1)
subtree_rc=$?
if [ "$subtree_rc" -ne 0 ]; then
    echo "$subtree_out"
    echo "close-wrapped-leg: refusing to signal pid $matched - wrap-subtree-check.sh did not report CLOSABLE (see above); retry shortly" >&2
    exit 6
fi

# ---------- Leg cost ledger (HIMMEL-4217) ----------------------------------------
# One JSONL row per wrapped leg, from the transcript resolved above. Never
# fatal: a meter or ledger failure WARNs and the close proceeds. A retry of the
# same transcript (a refused or failed close re-run) never writes a second row.
if [ -n "$TRANSCRIPT" ]; then
    if ! . "$HERE/../../lanes/lib/leg-cost-row.sh"; then
        echo "close-wrapped-leg: WARN cannot load leg-cost-row.sh - no cost ledger row" >&2
    elif ! ledger=$(leg_cost_ledger_path "$DOC"); then
        echo "close-wrapped-leg: WARN cannot resolve the cost ledger path - no cost ledger row" >&2
    elif [ -f "$ledger" ] && grep -qF "\"session\":\"$(basename "$TRANSCRIPT" .jsonl)\"" "$ledger"; then
        echo "close-wrapped-leg: cost ledger already has a row for this transcript"
    elif ! row=$(leg_cost_row "$TRANSCRIPT" "$DOC"); then
        echo "close-wrapped-leg: WARN leg-burn failed - no cost ledger row" >&2
    elif mkdir -p "$(dirname "$ledger")" 2>/dev/null && printf '%s\n' "$row" >> "$ledger" 2>/dev/null; then
        echo "close-wrapped-leg: cost ledger row appended to $ledger"
    else
        echo "close-wrapped-leg: WARN cannot write $ledger - no cost ledger row" >&2
    fi
fi

if ! "$KILL" -TERM "$matched"; then
    echo "close-wrapped-leg: failed to send TERM to pid $matched" >&2
    exit 1
fi
echo "close-wrapped-leg: sent TERM to pid $matched (leg $(leg_label "$DOC"))"

# ---------- Wrapped leg's own /tmp scratch (HIMMEL-4235) ----------------------
# Archive-then-reap THIS leg's judge dirs (j<N>, j<N>[a-z]) and its session
# scratch dir, scoped through tmp-reap.sh --judge <pr>/--session: never a fleet-wide
# sweep (other legs are live). Dry-run first; apply only after a clean dry-run.
# Never fatal: any failure WARNs and the close carries on.
reap_leg_scratch() {
    local pr sid args=() i PROC_ROOT="${CLAUDE_SESSIONS_PROC:-/proc}"
    # judge dirs are named for the PR they judged, never the leg label: take the
    # PR from the doc's newest READY/MERGED bullet; no PR means no judge scope
    pr="$(grep -E '^- [0-9:]+ (READY|MERGED)' "$DOC" | grep -oE '(READY|MERGED)[ #-]+(PR[ #]+)?[0-9]+' | tail -n 1 | grep -oE '[0-9]+$')"
    if [ -n "$pr" ]; then args+=(--judge "$pr")
    else echo "close-wrapped-leg: no PR in the leg doc - reaping no judge dir, never guessing"; fi
    if [ -n "$TRANSCRIPT" ]; then
        sid="$(basename "$TRANSCRIPT" .jsonl)"
        case "$sid" in
            ????????-????-????-????-????????????) args+=(--session "$sid") ;;
        esac
    fi
    if [ "${#args[@]}" -eq 0 ]; then
        echo "close-wrapped-leg: no judge number or session id for this leg - skipping the /tmp reap, never guessing"
        return 0
    fi
    # the TERM is asynchronous: give the session a moment to exit so its scratch is not "live"
    for ((i = 0; i < ${CLOSE_WRAPPED_LEG_REAP_WAIT:-5}; i++)); do
        [ -d "$PROC_ROOT/$matched" ] || break
        sleep 1
    done
    # a session that outlives the TERM still owns its scratch: reap nothing now
    if [ -d "$PROC_ROOT/$matched" ]; then
        echo "close-wrapped-leg: pid $matched still running after TERM - leaving its /tmp scratch for a later reap"
        return 0
    fi
    if ! bash "$TMP_REAP" "${args[@]}"; then
        echo "close-wrapped-leg: WARN tmp-reap dry-run failed for ${args[*]} - not applying; close continues" >&2
        return 0
    fi
    bash "$TMP_REAP" --apply "${args[@]}" || echo "close-wrapped-leg: WARN tmp-reap --apply failed for ${args[*]} - close continues" >&2
    return 0
}
reap_leg_scratch || echo "close-wrapped-leg: WARN /tmp reap errored - close continues" >&2

worktrees=$(grep -oE "/[^\` ]*/\.claude/worktrees/[^\`) ]+" "$DOC" | sort -u)
wt_count=$(printf '%s\n' "$worktrees" | grep -c . || true)
if [ "$wt_count" -ne 1 ]; then
    echo "close-wrapped-leg: doc names $wt_count worktree path(s) - skipping the prune, never guessing" >&2
    close_success
fi
WT="$worktrees"

out=$(bash "$CLEAN_SH" --only "$WT" --only-allow-unmerged 2>&1)
rc=$?
echo "$out"
if [ "$rc" -ne 0 ]; then
    # clean-garden.sh's own --only failure text always contains "not a prune
    # candidate" (its wording is shared across a benign skip AND a PARTIAL or
    # FAILED removal - codex-2, HIMMEL-3747 CR round 1), so a substring match
    # on that text alone can't tell a benign skip apart from a dangerous
    # partial/gutted-tree removal. Read its "prune summary" counts instead:
    # only a summary with 0 partial and 0 failed is a benign skip.
    summary_line=$(printf '%s\n' "$out" | grep -F 'clean-garden: prune summary' | tail -n 1)
    partial_n=$(printf '%s' "$summary_line" | sed -nE 's/.*, ([0-9]+) partial,.*/\1/p')
    failed_n=$(printf '%s' "$summary_line" | sed -nE 's/.* ([0-9]+) failed$/\1/p')
    benign=0
    if [ "$partial_n" = "0" ] && [ "$failed_n" = "0" ]; then
        case "$out" in
            *'in use'*|*'not a prune candidate'*)
                benign=1 ;;
        esac
    fi
    if [ "$benign" -eq 1 ]; then
        echo "close-wrapped-leg: worktree $WT not pruned (see message above) - not a failure, retry --only shortly"
        close_success
    fi
    echo "close-wrapped-leg: clean.sh --only $WT --only-allow-unmerged failed (rc=$rc)" >&2
    exit 1
fi
close_success
