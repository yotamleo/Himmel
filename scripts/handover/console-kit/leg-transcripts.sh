#!/usr/bin/env bash
# scripts/handover/console-kit/leg-transcripts.sh - sourced library: resolve a
# leg's transcript by its session names (HIMMEL-3629, HIMMEL-3638; moved out of
# close-wrapped-leg.sh by HIMMEL-4670 P3 so the close and the leg-digest-step
# --doc fallback share one matcher).
#
#   match_transcripts <files> <head-window> <candidates>
#       Every file (newline list) whose `"customTitle":"<candidate>"` appears in
#       its first <head-window> lines (0 = the whole file), sorted and unique.
#   resolve_leg_transcripts <dir> <candidates> [mtime-days] [head-window]
#       The two-pass search close-wrapped-leg.sh has always used: *.jsonl under
#       <dir> changed in the last [mtime-days] (default 1), first [head-window]
#       lines (default 40); on no MATCH, the whole tree, whole files.
#
# <candidates> is a newline list of session names. Never guesses: callers
# treat anything but exactly one match as unresolved.
#
# Platform guard: Linux bash 3.2+ (console kit; no .ps1 twin).

match_transcripts() {
    local files="$1" hw="$2" candidates="$3" matches="" f hit cand
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

resolve_leg_transcripts() {
    local dir="$1" candidates="$2" mtime_window="${3:-1}" head_window="${4:-40}" scan_files found
    # HIMMEL-3638: a plain `grep -rlF ... "$dir"` reads every byte of every
    # transcript ever written across the whole projects tree (5.6 GB) -
    # minutes per close. A wrapped leg's own transcript is always from TODAY,
    # and customTitle (when set) is near the top of the file, so bound both
    # axes: only today's files (mtime), only their first N lines (head).
    scan_files=$(find "$dir" -type f -name '*.jsonl' -mtime "-${mtime_window}" 2>/dev/null)
    found=$(match_transcripts "$scan_files" "$head_window" "$candidates")
    if [ -z "$found" ]; then
        # F3/codex-3: -mtime is a rolling window, not "today", and a target
        # transcript outside it can be missed even while OTHER, unrelated
        # transcripts fall inside it (an empty-scan_files check alone would
        # miss that case). Retry against the full tree whenever the SCOPED
        # search found no MATCH, not only when it found no files at all.
        # codex-2 (round 4): the fallback must also drop the head-window
        # bound - a customTitle past line $head_window is unmatchable in
        # either pass otherwise. Pass 0 = unbounded (whole file).
        scan_files=$(find "$dir" -type f -name '*.jsonl' 2>/dev/null)
        found=$(match_transcripts "$scan_files" 0 "$candidates")
    fi
    [ -z "$found" ] || printf '%s\n' "$found"
}
