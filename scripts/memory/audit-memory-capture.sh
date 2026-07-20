#!/usr/bin/env bash
# Decoupled audit of the auto-memory capture discipline (HIMMEL-570 / HIMMEL-1090).
#
# Runs OFF the compound cadence on purpose: compound now runs weeks-to-months
# apart, so a detector riding it would grow its own latency in proportion to
# the design working (D1). This script is the standalone detector for the
# design's worst failure mode — silent fact loss — plus the index hygiene the
# capture hook (scripts/hooks/guard-memory-capture.sh) enforces structurally.
#
# Reads the capture log the hook appends to MEMORY_CAPTURE_LOG (default
# $MEMDIR/.capture-log.jsonl): one JSON object per line, fields
# {ts,event,rule,hash,excerpt,target,lines_delta,lane}. 'deny' = a capture the
# hook rejected; 'write' = an allowed MEMORY.md pointer-line delta.
#
# Checks (Rev2-amended — base was PRE-Rev2, do NOT ship the plan's base as-is):
#   1. ORPHANED DENIES (P2-13/P2-14) — a fact the model was denied and never
#      re-landed in the substrate. Windowed to a trailing epoch window so a
#      reworded/re-landed fact stops ringing once its deny ages out. If denies
#      exist but the substrate is genuinely unresolvable, emits a WARN rather
#      than silently reporting 'clean'.
#   2. ORPHAN TOPIC FILES (Rev2 INVERTS the old '>2 topic files = drift' check
#      — topic files ARE the design now, accumulation is expected) — a topic
#      file in $MEMDIR whose basename (sans .md) is not referenced by any
#      routing line in MEMORY.md.
#   3. LINE-COUNT TRIPWIRE — net MEMORY.md pointer-line growth over the
#      trailing window.
#   4. INDEX BUDGET + over-length-line discipline.
#   5. COLLECTION FRESHNESS (best-effort, Rev2 D8) — if the qmd CLI is on
#      PATH, warn when the luna-curated collection is absent; skip cleanly
#      otherwise (never hard-fails on qmd absence).
#
# Exit: 0 clean, 1 findings. bash 3.2-safe; no `date -d` (Git-Bash-unreliable).
set -uo pipefail

MEMDIR="${MEMDIR:-$HOME/.claude/projects/C--Users-yotam-Documents-github-himmel/memory}"
LOG="${MEMORY_CAPTURE_LOG:-$MEMDIR/.capture-log.jsonl}"
LINE_MAX="${MEMORY_LINE_MAX:-200}"
BUDGET="${MEMORY_BUDGET_BYTES:-24400}"
WINDOW_DAYS="${MEMORY_AUDIT_WINDOW_DAYS:-7}"
QMD_SKIP="${MEMORY_AUDIT_SKIP_QMD:-0}"
findings=0

# Fail fast on a non-numeric override before it reaches the arithmetic below
# (a garbage WINDOW_DAYS would break the epoch cutoff; a garbage LINE_MAX/BUDGET
# the [ -gt ] comparisons). These are operator-set env knobs — reject, don't guess.
is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
if ! is_uint "$LINE_MAX" || ! is_uint "$BUDGET" || ! is_uint "$WINDOW_DAYS"; then
    printf '%s\n' 'memory-capture audit: LINE_MAX / BUDGET / WINDOW_DAYS must be non-negative integers' >&2
    exit 1
fi

# Fail CLOSED when jq is unavailable: the orphaned-deny (check 1) and tripwire
# (check 3) detectors parse the JSONL log with jq. Without jq those `jq … 2>/dev/null`
# calls yield empty, and the audit would report "clean" having never run its two
# most important silent-fact-loss detectors — the exact false-clean this script exists
# to prevent. Refuse rather than pass blind.
command -v jq >/dev/null 2>&1 || {
    printf '%s\n' 'memory-capture audit: jq not found — the orphaned-deny and tripwire detectors cannot run; refusing to report clean (fail-closed)' >&2
    exit 1
}

note() { printf '%s\n' "$1"; findings=$((findings+1)); }

# Fixed once: the trailing-window cutoff. Epoch math without `date -d`.
now_s="$(date -u +%s)"
cutoff=$((now_s - WINDOW_DAYS * 24 * 3600))

# Resolve the substrate to grep for re-landed facts. Mirrors graphmap-cadence /
# pipeline-cadence default_vault: LUNA_VAULT_PATH first, else <home>/Documents/luna.
# Empty when genuinely unresolvable — drives the P2-13 WARN path (never silent).
SUB=""
if [ -n "${LUNA_VAULT_PATH:-}" ]; then
    SUB="$LUNA_VAULT_PATH"
else
    _h="${HOME:-}"; [ -n "$_h" ] || _h="${USERPROFILE:-}"
    [ -n "$_h" ] && SUB="$_h/Documents/luna"
fi
substrate_ok=0
{ [ -n "$SUB" ] && [ -d "$SUB" ]; } && substrate_ok=1

# 1. Orphaned denies — the ONLY detector for silent fact loss: a capture the
#    hook denied and the model never re-landed.
if [ -f "$LOG" ]; then
    n_inwin=0
    while IFS= read -r rec; do
        [ -n "$rec" ] || continue
        # P2-14: window to the trailing N days. jq fromdateiso8601 parses the
        # hook's `date -u +%Y-%m-%dT%H:%M:%SZ`; `try` drops a malformed ts
        # (null >= number is false in jq, so bad rows are skipped, not rung).
        ex="$(printf '%s' "$rec" | jq -r --argjson c "$cutoff" '
            select(.event=="deny")
            | (.ts | try fromdateiso8601) as $t
            | select($t >= $c)
            | .excerpt // empty' 2>/dev/null)"
        [ -n "$ex" ] || continue
        n_inwin=$((n_inwin+1))
        [ "$substrate_ok" -eq 1 ] || continue
        # -F: excerpts carry regex metachars (em-dashes, ../..).
        #
        # KNOWN MATCHING LIMIT (P2-14): the hook stores the excerpt of the
        # DENIED capture (the attempted memory line); rewording on re-landing
        # changes the wording, so a substring match CAN MISS a genuinely
        # re-landed fact. The time window above bounds how long such a miss
        # rings — it does not eliminate it.
        #
        # Why `hash` is written by the hook but never read here: it is the
        # sha256 of the denied CONTENT. There is no re-landed body to hash-match
        # against, and a reword changes any would-be hash too — so hash cannot
        # confirm resolution. Resolution is detected by substance (substring),
        # which is inherently fuzzy; the window — not the hash — is the
        # resolution-aging mechanism.
        if ! grep -rqF -- "$ex" "$SUB" 2>/dev/null; then
            note "ORPHANED DENY (in-window): $ex"
        fi
    done < "$LOG"
    # P2-13: denies exist but the substrate is genuinely unresolvable -> WARN,
    # never a silent 'clean'. The check must NOT disable itself when
    # LUNA_VAULT_PATH is unset; it surfaces that re-landing could not be verified.
    if [ "$substrate_ok" -eq 0 ] && [ "$n_inwin" -gt 0 ]; then
        note "WARN: $n_inwin in-window deny(ies) but substrate unresolvable (LUNA_VAULT_PATH unset and no <home>/Documents/luna) — cannot verify re-landing"
    fi
fi

# 2. ORPHAN TOPIC FILES (Rev2: topic files ARE the design — the plan's base
#    '>2 live topic files = drift' check is WRONG under Rev2 and INVERTED here).
#    A topic file whose basename (sans .md) is not referenced by any routing
#    line in MEMORY.md is an orphan.
n_topic=0
# Iterate topic files whenever MEMDIR exists — NOT gated on MEMORY.md. A deleted
# index while topic files remain is the worst orphan case (nothing routes anything),
# and gating the loop on the index would skip the detector and return a false clean.
# A missing index therefore means EVERY topic file is unrouted.
if [ -d "$MEMDIR" ]; then
    for f in "$MEMDIR"/*.md; do
        [ -e "$f" ] || continue
        base="$(basename "$f")"
        case "$base" in MEMORY.md|*.bak) continue ;; esac
        n_topic=$((n_topic+1))
        stem="${base%.md}"
        # Match the link-target form "<stem>.md" as a fixed string (. is literal
        # under -F). A bare-stem substring match would false-clean a short stem
        # that is a substring of a longer routed file (e.g. "windows" inside
        # "windows-git-bash-traps"). No index file at all => unmatched => orphan.
        if [ ! -f "$MEMDIR/MEMORY.md" ] || ! grep -qF -- "${stem}.md" "$MEMDIR/MEMORY.md" 2>/dev/null; then
            note "ORPHAN TOPIC FILE: $base not routed by any MEMORY.md line"
        fi
    done
fi

# 3. Line-count tripwire — net MEMORY.md pointer-line growth over the trailing
#    window. >1 line of net growth means themes may be degenerating into
#    per-fact lines (the O(themes) guard).
if [ -f "$LOG" ]; then
    delta="$(jq -r --argjson c "$cutoff" '
        select(.event=="write")
        | (.ts | try fromdateiso8601) as $t
        | select($t >= $c)
        | .lines_delta // 0' "$LOG" 2>/dev/null | awk '{s+=$1} END{print s+0}')"
    if [ "${delta:-0}" -gt 1 ]; then
        note "TRIPWIRE: index grew ${delta} pointer lines in ${WINDOW_DAYS}d — themes may be degenerating into per-fact lines"
    fi
fi

# 4. Index budget + over-length-line discipline (criteria 1-2).
if [ -f "$MEMDIR/MEMORY.md" ]; then
    b="$(wc -c < "$MEMDIR/MEMORY.md" | tr -d ' ')"
    over="$(awk -v m="$LINE_MAX" '/^- /{if(length($0)>m) n++} END{print n+0}' "$MEMDIR/MEMORY.md")"
    printf 'index: %sB (budget %sB), over-length lines: %s, topic files: %s\n' "$b" "$BUDGET" "$over" "$n_topic"
    [ "$b" -gt "$BUDGET" ] && note "OVER BUDGET: ${b}B > ${BUDGET}B — content is being silently dropped"
    [ "$over" -gt 0 ] && note "LINE DISCIPLINE: $over line(s) exceed ${LINE_MAX} chars"
fi

# 5. Collection freshness (best-effort, Rev2 D8). The orphaned-deny verdict is
#    only as good as the substrate it greps; qmd findability of luna-curated is
#    the structural guarantee that re-landed facts are discoverable. If the qmd
#    CLI is present, warn when luna-curated is absent. Skips cleanly on any
#    failure or MEMORY_AUDIT_SKIP_QMD=1 (tests set the latter for hermeticity).
#    Staleness (updated-age parsing) is a future refinement — only absence here.
if [ "$QMD_SKIP" != "1" ] && command -v qmd >/dev/null 2>&1; then
    if qmd_status="$(qmd status 2>/dev/null)"; then
        if ! printf '%s\n' "$qmd_status" | grep -qF -- 'luna-curated (qmd://luna-curated/)'; then
            note "COLLECTION FRESHNESS: qmd is on PATH but the luna-curated collection is absent — re-landed facts may not be findable"
        fi
    fi
fi

# Deliberate omission (recorded, not forgotten — P2-12): criterion-3's
# NORMALIZED ratio (lines-added / facts-captured, valid only in a >=10-fact
# window) is NOT implemented. The raw weekly line-delta tripwire (check 3) is
# the primary degeneration signal; the normalized ratio is second-order, and
# its >=10-fact 7-day window is rarely met on this personal store, so it would
# be a mostly-dormant soft signal adding noise. Raw weekly delta only. (Mirrors
# the plan's existing omission note for criterion-5's after-day-30 sub-checks.)

[ "$findings" -eq 0 ] && { echo "memory-capture audit: clean"; exit 0; }
echo "memory-capture audit: $findings finding(s)"
exit 1
