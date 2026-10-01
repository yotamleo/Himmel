#!/usr/bin/env bash
# scripts/ci/classify-ci-red.sh — is this failed CI job the PR's fault, or MAIN-RED?
# (HIMMEL-4071). A leg owns a pre-READY red only when its own PR caused it; a
# GENERAL red (an advisory, an outage, a flake on main) is escalated to the
# console as `MAIN-RED <job> <case>` instead of being fixed in the PR.
#
#   bash scripts/ci/classify-ci-red.sh --log <job-log> --job <job> --case <case> [--pr N] [--head SHA]
#
# An ordered cascade of FREE checks, stopping at the first decisive answer:
#   1. MARKER     <handover root>/.locks/main-red/<job>__<case> exists: an earlier
#                 leg already classified this job+case MAIN-RED — stop, do not
#                 re-diagnose.
#   2. SIGNATURE  the log matches a pattern in scripts/ci/main-red-signatures.txt.
#   3. DIFF       the case string appears nowhere in `git diff <base>...HEAD`
#                 (file names included): the PR neither touches nor references it.
# A MAIN-RED from 2 or 3 writes the marker so the next leg stops at 1; the
# console clears it after the fix merges. Anything else is PR-RED: the leg's own.
#
# stdout: `MAIN-RED <job> <case> via <marker|signature|diff>: <evidence>` (rc 0)
#         `PR-RED <job> <case>: ...`                                        (rc 1)
# rc 64 = usage / unreadable log.
#
# Seams (hermetic suites): MAIN_RED_MARKER_DIR, CLASSIFY_DIFF_FILE (diff text),
# CLASSIFY_BASE (default origin/main), CLASSIFY_SIGNATURES (pattern file).
#
# ponytail: steps 1-3 only; a cross-PR comparison, an advisory-time check and a
# rerun of main's failed job are the costlier follow-ups, a red none of 1-3
# decides stays PR-RED (the leg looks at it, never silently skipped).
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
log="" job="" cs="" pr="" head=""
while [ $# -gt 0 ]; do
    case "$1" in
        --log) log="${2:-}"; shift 2 ;;
        --job) job="${2:-}"; shift 2 ;;
        --case) cs="${2:-}"; shift 2 ;;
        --pr) pr="${2:-}"; shift 2 ;;
        --head) head="${2:-}"; shift 2 ;;
        *) echo "classify-ci-red: unknown argument: $1" >&2; exit 64 ;;
    esac
done
if [ -z "$log" ] || [ ! -r "$log" ]; then
    echo "classify-ci-red: usage: --log <readable job log> --job <job> --case <case> [--pr N] [--head SHA]" >&2
    exit 64
fi

safe() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

mdir="${MAIN_RED_MARKER_DIR:-}"
if [ -z "$mdir" ]; then
    # shellcheck source=../lib/handover-path.sh
    # shellcheck disable=SC1091
    . "$DIR/../lib/handover-path.sh" 2>/dev/null && mdir="$(handover_root 2>/dev/null)/.locks/main-red"
fi
marker=""
[ -z "$mdir" ] || marker="$mdir/$(safe "$job")__$(safe "$cs")"

main_red() {  # <step> <evidence>
    echo "MAIN-RED $job $cs via $1: $2"
    exit 0
}
write_marker() {  # <evidence>
    [ -n "$marker" ] || return 0
    mkdir -p "$mdir" 2>/dev/null || return 0
    ( set -o noclobber
      printf 'evidence=%s\npr=%s\nhead=%s\ntime=%s\n' "$1" "$pr" "$head" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$marker" ) 2>/dev/null || true
}

# 1. MARKER — read before diagnosing anything.
if [ -n "$marker" ] && [ -r "$marker" ]; then
    main_red marker "$(tr '\n' ' ' < "$marker")"
fi

# 2. SIGNATURE
sigs="${CLASSIFY_SIGNATURES:-$DIR/main-red-signatures.txt}"
if [ -r "$sigs" ]; then
    pat=$(grep -vE '^[[:space:]]*(#|$)' "$sigs")
    if [ -n "$pat" ]; then
        hit=$(grep -iE -m1 -e "$pat" "$log" 2>/dev/null) || hit=""
        if [ -n "$hit" ]; then
            write_marker "signature: $hit"
            main_red signature "$hit"
        fi
    fi
fi

# 3. DIFF — only decidable with a case name and a readable diff.
if [ -n "$cs" ]; then
    if [ -n "${CLASSIFY_DIFF_FILE:-}" ]; then
        diff_text=$(cat "$CLASSIFY_DIFF_FILE" 2>/dev/null) || diff_text=""; have=$([ -r "$CLASSIFY_DIFF_FILE" ] && echo 1 || echo 0)
    else
        diff_text=$(git diff "${CLASSIFY_BASE:-origin/main}...HEAD" 2>/dev/null) && have=1 || have=0
    fi
    if [ "$have" = 1 ] && ! grep -qiF -e "$cs" <<< "$diff_text"; then
        write_marker "diff: case '$cs' untouched by and unreferenced from the PR diff"
        main_red diff "case '$cs' is untouched by and unreferenced from the PR diff"
    fi
fi

echo "PR-RED $job $cs: no signature, no marker, and the PR diff touches or references the case (or could not be read) — this red is yours; fix it"
exit 1
