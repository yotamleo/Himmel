#!/usr/bin/env bash
# doctor-counts.sh — the one writer of the statusline's doctor counts file
# (HIMMEL-4363). Sourced by himmel-doctor.sh (full runs only) and
# doctor-cadence.sh. The HUD segment (scripts/statusline/hud-custom-lines.sh)
# reads `<state dir>/counts` and shows its mtime age once it is over 24 h.
#
#   doctor_counts_write <state-dir> <fail> <warn>
#
# Atomic (tmp in the same dir, then mv) so a HUD read never sees a torn file.
# Returns non-zero on any failure; callers treat that as best-effort.
# bash 3.2-safe; sourced, no side effects.
doctor_counts_write() {
    local dir="${1:-}" f="${2:-}" w="${3:-}" tmp
    [ -n "$dir" ] || return 2
    case "$f" in ''|*[!0-9]*) return 2 ;; esac
    case "$w" in ''|*[!0-9]*) return 2 ;; esac
    mkdir -p "$dir" || return 1
    tmp="$(mktemp "$dir/.counts.XXXXXX")" || return 1
    if printf 'fail=%s warn=%s\n' "$f" "$w" > "$tmp" && mv -f "$tmp" "$dir/counts"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}
