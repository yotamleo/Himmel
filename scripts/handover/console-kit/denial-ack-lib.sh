#!/usr/bin/env bash
# denial-ack-lib.sh — HIMMEL-3724 phase 2b. Sourced by console-wait.sh (writes a
# page record when it pages a denial), ack-denial.sh (writes an ack record) and
# headed-arm-leg.sh (refuses a re-dispatch while a page is un-acked). Never
# executed directly. bash 3.2-safe.
#
# Records live in ONE directory, ${HIMMEL_DENIAL_ACK_DIR:-~/.himmel/state/denial-acks}
# (dir 0700, files 0600), one pair of files per leg key:
#   <key>.page   written by console-wait.sh when it pages a SHIP-STEP/PAUSE-RISK rise
#   <key>.ack    written by ack-denial.sh when the operator has looked
# Both are `name=value` lines: leg=, count=, class=, ts= (epoch seconds).
#
# The records hold the leg label, count and class ONLY -- exactly what the
# Telegram page carries. Nothing here reads the classifier-denial log (its
# command and reason fields stay on the host, in the four files the reader-pin
# test allows); the class arrives from tick.sh's `denials=` field via
# console-wait.sh, which is the only writer of a page record.
#
# A leg is un-acked when its .page ts is newer than its .ack ts (or no .ack
# exists) and the page class is SHIP-STEP or PAUSE-RISK. Every reader FAILS OPEN:
# a missing dir, a missing or garbled record, a non-numeric ts = not un-acked.
#
# ponytail: 1 s timestamp granularity (a page landing in the same second as an
#   ack reads as acked), and a page is only recorded for a rise a RUNNING
#   console-wait saw; upgrade path: a page sequence number in both records if a
#   same-second miss is ever observed, HIMMEL-3724.
# ponytail: a leg keyed `<dir>#<sid8>` (a non-worktree cwd) can be paged and
#   acked but never matched to a launch, because a launch has no session id
#   yet; upgrade path: key launches by the resume_cwd's dir label if such legs
#   appear, HIMMEL-3724.

denial_ack_dir() { printf '%s' "${HIMMEL_DENIAL_ACK_DIR:-$HOME/.himmel/state/denial-acks}"; }

# denial_key <label>: a filename-safe key. Path separators and anything outside
# [A-Za-z0-9._#+-] become `_`, so a hostile label can never leave the dir; an
# empty or all-dots result (`.`, `..`) is refused (rc 1).
denial_key() {
    local k
    k="$(printf '%s' "$1" | tr -c 'A-Za-z0-9._#+-' '_' | cut -c1-120)"
    [ -n "$(printf '%s' "$k" | tr -d '.')" ] || return 1
    printf '%s' "$k"
}

# denial_doc_label <handover-doc>: the leg's worktree slug from the doc's
# frontmatter `resume_cwd:` (the segment after /worktrees/, else the cwd's
# basename). rc 1 when the doc is unreadable or names no resume_cwd.
denial_doc_label() {
    local cwd
    [ -r "$1" ] || return 1
    cwd="$(awk 'NR==1 { if ($0 != "---") exit; next } /^---[[:space:]]*$/ { exit } /^resume_cwd:/ { sub(/^resume_cwd:[[:space:]]*/, ""); print; exit }' "$1" 2>/dev/null)"
    cwd="${cwd%\"}"; cwd="${cwd#\"}"; cwd="${cwd%/}"
    [ -n "$cwd" ] || return 1
    case "$cwd" in
        */worktrees/*) cwd="${cwd#*/worktrees/}"; printf '%s' "${cwd%%/*}" ;;
        *) printf '%s' "${cwd##*/}" ;;
    esac
}

# denial_field <file> <name>: the first `name=` value in a record.
denial_field() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1; }

# denial_record_write <file> <label> <count> <class> <ts>: atomic, 0600 file in
# a 0700 dir. rc 1 when the dir or file cannot be written.
denial_record_write() {
    local dir tmp
    dir="$(dirname "$1")"
    # Created 0700; an existing dir is left as the operator set it.
    [ -d "$dir" ] || { ( umask 077; mkdir -p "$dir" ) 2>/dev/null && chmod 700 "$dir" 2>/dev/null; } || return 1
    tmp="$( umask 077; mktemp "$dir/.rec.XXXXXX" 2>/dev/null )" || return 1
    if printf 'leg=%s\ncount=%s\nclass=%s\nts=%s\n' "$2" "$3" "$4" "$5" > "$tmp" 2>/dev/null \
        && chmod 600 "$tmp" 2>/dev/null \
        && mv -f "$tmp" "$1" 2>/dev/null; then
        return 0
    fi
    rm -f "$tmp" 2>/dev/null
    return 1
}

# denial_page_write <label> <count> <class>: record that a page was sent (or
# attempted) for this rise. rc 1 on any write failure; callers ignore it.
denial_page_write() {
    local key
    key="$(denial_key "$1")" || return 1
    denial_record_write "$(denial_ack_dir)/$key.page" "$key" "$2" "$3" "$(date +%s)"
}

# denial_unacked <key>: rc 0 (and prints "<class> <count>") only when a
# SHIP-STEP/PAUSE-RISK page record is newer than the key's latest ack.
denial_unacked() {
    local d pg ak class count pts ats
    d="$(denial_ack_dir)"; pg="$d/$1.page"; ak="$d/$1.ack"
    [ -r "$pg" ] || return 1
    class="$(denial_field "$pg" class)"
    case "$class" in SHIP-STEP|PAUSE-RISK) ;; *) return 1 ;; esac
    pts="$(denial_field "$pg" ts)"
    case "$pts" in ''|*[!0-9]*) return 1 ;; esac
    count="$(denial_field "$pg" count)"
    if [ -r "$ak" ]; then
        ats="$(denial_field "$ak" ts)"
        case "$ats" in ''|*[!0-9]*) ats=0 ;; esac
        [ "$ats" -ge "$pts" ] && return 1
    fi
    printf '%s %s' "$class" "${count:-?}"
}
