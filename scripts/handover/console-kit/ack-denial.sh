#!/usr/bin/env bash
# ack-denial.sh — HIMMEL-3724 phase 2b. Acknowledge a paged classifier denial so
# the leg it parked can be re-dispatched.
#
# usage: ack-denial.sh <leg-label-or-handover-doc>
#
#   <leg-label>      the label the page named (the leg's worktree slug, or the
#                    session name), e.g. feat+himmel-3724-denial-page-ack
#   <handover-doc>   a leg handover doc; its frontmatter resume_cwd names the
#                    worktree, and the slug after /worktrees/ is the label
#
# When console-wait.sh pages a SHIP-STEP or PAUSE-RISK denial it also writes a
# page record. headed-arm-leg.sh refuses to launch a leg (exit 14) while its
# page is newer than its ack. This script writes the ack: leg, the paged class
# and count, and a timestamp, to
#   ${HIMMEL_DENIAL_ACK_DIR:-~/.himmel/state/denial-acks}/<key>.ack
# (dir 0700, file 0600). See denial-ack-lib.sh for the record format.
#
# Idempotent: a second ack with no newer page changes nothing and says so. A
# newer page (a rise the console paged after your ack) needs a fresh ack. Acking
# a leg that was never paged is a no-op (exit 0), not an error.
#
# Only the leg label, count and class are ever recorded; this script never
# reads the classifier-denial log.
#
# Exit codes:
#   0  acked, already acked, or nothing to ack
#   1  the record dir or file could not be written
#   2  usage error, unusable label, or a doc that names no resume_cwd
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/denial-ack-lib.sh"
# shellcheck source=scripts/handover/console-kit/denial-ack-lib.sh
if ! { [ -r "$LIB" ] && . "$LIB"; } 2>/dev/null; then
    echo "ack-denial: cannot read $LIB" >&2
    exit 1
fi

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
    echo "usage: ack-denial.sh <leg-label-or-handover-doc>" >&2
    exit 2
fi

arg="$1"
if [ -f "$arg" ]; then
    label="$(denial_doc_label "$arg")" || {
        echo "ack-denial: $arg has no resume_cwd in its frontmatter; pass the leg label instead" >&2
        exit 2
    }
else
    label="$arg"
fi
key="$(denial_key "$label")" || { echo "ack-denial: unusable leg label: $label" >&2; exit 2; }

dir="$(denial_ack_dir)"
page="$dir/$key.page"
if [ ! -r "$page" ]; then
    echo "ack-denial: nothing to ack for $key (no page on record)"
    exit 0
fi
class="$(denial_field "$page" class)"
count="$(denial_field "$page" count)"
pts="$(denial_field "$page" ts)"
case "$pts" in ''|*[!0-9]*) echo "ack-denial: nothing to ack for $key (unreadable page record)"; exit 0 ;; esac

ack="$dir/$key.ack"
if [ -r "$ack" ]; then
    ats="$(denial_field "$ack" ts)"
    case "$ats" in ''|*[!0-9]*) ats=0 ;; esac
    if [ "$ats" -ge "$pts" ]; then
        echo "ack-denial: $key already acked ($class x$count paged at $pts, acked at $ats)"
        exit 0
    fi
fi

denial_record_write "$ack" "$key" "${count:-0}" "${class:-unknown}" "$(date +%s)" || {
    echo "ack-denial: cannot write $ack" >&2
    exit 1
}
echo "ack-denial: acked $key ($class x$count)"
