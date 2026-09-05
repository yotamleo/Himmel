#!/usr/bin/env bash
# synth-input-check.sh — HIMMEL-2045. Free precondition for the nightly
# Pipeline-Synthesize cadence leg: is there anything new to synthesize?
#
# WHY: /synthesize-clips wrote 0, 1, 0 pages on 2026-08-21/22/23 — two of three
# sonnet sessions bought nothing. The decision "is there new triaged input?" is
# a filesystem question, so it must never cost a model call. This script answers
# it; the generated runner branches on the token and skips the claude launch.
#
# CONTRACT (deliberately the bank-preflight.sh shape — the cadence already has
# one verdict-token helper and a second dialect would be a trap):
#   * Prints exactly ONE token to stdout: NEW or NONE.
#   * Diagnostics to stderr.
#   * ALWAYS exits 0. Callers branch on the TOKEN, never the exit code — a
#     non-zero exit is indistinguishable from a crash to the schtasks/cron
#     wrapper.
#   * FAIL-OPEN: anything this script cannot determine yields NEW. A broken
#     checker must never be the reason the pipeline silently stops
#     synthesizing; the cost of a wrong NEW is one session, the cost of a
#     wrong NONE is unbounded silence.
#
# REFERENCE POINT, in order of preference:
#   1. <stamp-file>, written by the runner ONLY after a leg that actually
#      completed. This is the load-bearing one: on a night where synthesis
#      legitimately wrote 0 pages, the newest _synthesis/ page does NOT move,
#      so keying off that page alone would re-fire every night forever on the
#      same already-considered clips — the exact waste this script exists to
#      stop.
#   2. the newest Clippings/_synthesis/*.md page, when no stamp exists yet
#      (a freshly armed cadence that has never completed a leg).
#   3. nothing — then any triaged clip at all counts as new.
#
# WHAT COUNTS AS INPUT: a top-level Clippings/*.md carrying `triaged_at:` and
# newer than the reference. Top-level only (-maxdepth 1): _synthesis/ is the
# output and _done/ is the archive, and a clip graduating into _done/ is not
# new input. The `triaged_at:` filter is what keeps the daily byte-identical
# _deferred.md regeneration from reading as new work.
#
# Usage:
#   synth-input-check.sh [vault-root] [stamp-file]   -> print NEW | NONE
#   synth-input-check.sh --stamp [vault-root] [stamp-file]
#                                                   -> record "a leg completed"
#
# The runner calls it as `synth-input-check.sh .` because it has already cd'd
# into the vault: the cadence crosses a cmd.exe -> bash boundary on Windows,
# where a Windows-form path (C:\...) reaching a bash argument has its
# backslashes eaten as escapes. `.` is the one spelling that is correct in both
# shells. The stamp defaults inside the vault for the same reason -- no second
# path form has to be plumbed through the emitters.
set -u

STAMP_MODE=0
if [ "${1:-}" = "--stamp" ]; then
    STAMP_MODE=1
    shift
fi

VAULT="${1:-.}"
STAMP="${2:-$VAULT/Clippings/_synthesis/.cadence-last-synth}"
# The stamp records when the GATE ran, not when the leg finished. A synthesis
# session takes 8-39 minutes, and a clip triaged inside that window is older
# than a completion-time stamp but was never part of what the session read --
# so a completion-time stamp would skip it on the next gate. The gate writes
# this pending file at check time and --stamp PROMOTES it (a same-directory
# `mv`, which preserves mtime), so the reference is always the check instant.
PENDING="$STAMP.pending"

emit() { printf '%s\n' "$1"; exit 0; }

_stamp_dir() {
    _dir=${STAMP%/*}
    [ "$_dir" = "$STAMP" ] || mkdir -p "$_dir" 2>/dev/null
}

if [ "$STAMP_MODE" -eq 1 ]; then
    _stamp_dir
    if [ -f "$PENDING" ] && mv -f "$PENDING" "$STAMP" 2>/dev/null; then
        echo "synth-input-check: stamped $STAMP (at the gate instant, not leg end)" >&2
    else
        # NO fallback to `now`. Without a pending mark there is no evidence of
        # WHEN this leg's gate ran, and stamping completion time would advance
        # the reference past every clip triaged during the session — the exact
        # window the pending mark exists to close, reintroduced on the degraded
        # path. Leaving the reference where it is costs at most one redundant
        # session next night; advancing it blind drops clips no session read.
        # Never fatal either way: a leg that just succeeded is not failed over
        # a stamp.
        echo "synth-input-check: no pending gate mark — reference left unchanged (next run re-checks against the previous stamp / newest synthesis page)" >&2
    fi
    exit 0
fi

# Record the gate instant NOW — before the candidate scan, not on the way out
# through `emit NEW`. `find -newer` is STRICTLY newer, so anything sharing the
# mark's filesystem timestamp tick is excluded; marking afterwards made that
# exclusion window the whole scan (~1,300 files, seconds), while marking first
# narrows it to a single tick. Unconditional, so every path — including the two
# fail-open NEWs above the scan — leaves a mark, with no per-call-site rule to
# forget. A NONE night writes one too, which is harmless: --stamp only ever runs
# after a leg, and a leg only runs after NEW.
# (Residual, accepted: a clip triaged inside that one tick is still excluded.
# It is not lost — this gate is a TRIGGER, not a filter, and /synthesize-clips
# reads the whole inbox — so the next night with any new input picks it up.)
_stamp_dir
date -u +%Y-%m-%dT%H:%M:%SZ > "$PENDING" 2>/dev/null || true

command -v find >/dev/null 2>&1 || {
    echo "synth-input-check: find(1) missing — cannot decide, proceeding" >&2
    emit NEW
}

CLIPS="$VAULT/Clippings"
if [ ! -d "$CLIPS" ]; then
    # No inbox at all is a definite answer, not an unknown: there is nothing
    # for a synthesis session to read, so spending one cannot produce a page.
    echo "synth-input-check: no $CLIPS — nothing to synthesize" >&2
    emit NONE
fi

REF=""
REF_KIND=""
if [ -f "$STAMP" ]; then
    REF="$STAMP"
    REF_KIND="last completed leg"
else
    # Newest synthesis page. `ls -t` over one small directory; a glob that
    # matches nothing expands to the literal pattern, which `ls` reports as
    # missing on stderr — hence the redirect, and the -f guard below.
    # shellcheck disable=SC2012  # a newline in a synthesis filename would make
    # this line yield a path the -f guard then rejects, which lands on "no
    # reference" -> NEW: the same fail-open answer the rest of this script
    # gives for anything it cannot determine. `find -printf` is not portable
    # and sorting find output by mtime costs more than the failure mode.
    _newest=$(ls -t "$CLIPS/_synthesis"/*.md 2>/dev/null | head -1)
    if [ -n "$_newest" ] && [ -f "$_newest" ]; then
        REF="$_newest"
        REF_KIND="newest synthesis page"
    fi
fi

# find's exit status is CHECKED, not swallowed. A suppressed failure yields an
# empty candidate list, which reads identically to "nothing new" and emits NONE
# — silently inverting this script's fail-open contract into an indefinite
# suppression of synthesis. An error here is an UNKNOWN, and unknown means NEW.
_find_rc=0
if [ -n "$REF" ]; then
    _candidates=$(find "$CLIPS" -maxdepth 1 -type f -name '*.md' -newer "$REF" 2>/dev/null) || _find_rc=$?
else
    REF_KIND="no reference — every triaged clip counts"
    _candidates=$(find "$CLIPS" -maxdepth 1 -type f -name '*.md' 2>/dev/null) || _find_rc=$?
fi
if [ "$_find_rc" -ne 0 ]; then
    echo "synth-input-check: find failed (rc=$_find_rc) — cannot decide, proceeding" >&2
    emit NEW
fi

# Stop at the FIRST match: this is a boolean question and the inbox holds
# ~1,300 files. One awk per candidate, not one big argument list, so a long
# inbox cannot blow the command line.
#
# The match is scoped to the YAML FRONTMATTER, not the whole file: a plain
# `grep triaged_at:` also fires on a clip whose BODY happens to quote the
# string — and this vault clips articles about its own pipeline, so that is a
# realistic false NEW, not a hypothetical one.
#
# The opening fence must be LINE 1. Accepting a `---` anywhere as an opener
# reintroduced the same bug one layer down: a clip with no frontmatter, whose
# body has a horizontal rule followed by a line starting `triaged_at:`, would
# read as triaged. Frontmatter is line-1-or-nothing, so anchor it there.
# The status is set ONLY in END. A bare `exit` in a rule runs END, and an
# `exit <n>` there overrides whatever the rule asked for — so `exit 0` in the
# match rule would be silently rewritten to END's status. Flag, then decide once.
# Returns 0 = triaged, 1 = not triaged, 2 = COULD NOT INSPECT. The caller must
# treat 2 as fail-open (NEW): swallowing an unreadable clip as "not triaged" is
# the same contract inversion the find-rc check above closes — an inspection
# failure is an unknown, and unknown means NEW.
# awk's own fatal-error status is 2 in gawk/mawk/BSD awk, and a missing awk
# gives 127; anything above 1 is therefore "did not answer", not "answered no".
is_triaged() {
    [ -r "$1" ] || return 2
    awk '
        NR == 1 { if ($0 ~ /^---[[:space:]]*$/) { n = 1; next } exit }
        n == 1 && /^---[[:space:]]*$/ { exit }
        n == 1 && /^triaged_at:/ { found = 1; exit }
        END { exit !found }
    ' "$1" 2>/dev/null
    _awk_rc=$?
    [ "$_awk_rc" -le 1 ] || return 2
    return "$_awk_rc"
}
_found=""
_unreadable=""
while IFS= read -r _clip; do
    [ -n "$_clip" ] || continue
    is_triaged "$_clip"
    case $? in
        0) _found="$_clip"; break ;;
        2) _unreadable="$_clip"; break ;;
    esac
done <<EOF
$_candidates
EOF
if [ -n "$_unreadable" ]; then
    echo "synth-input-check: could not inspect $_unreadable — cannot decide, proceeding" >&2
    emit NEW
fi

echo "synth-input-check: reference=${REF:-none} (${REF_KIND})" >&2
if [ -n "$_found" ]; then
    echo "synth-input-check: new triaged input since the reference (first: $_found)" >&2
    emit NEW
fi
echo "synth-input-check: no triaged clip newer than the reference — skipping the leg" >&2
emit NONE
