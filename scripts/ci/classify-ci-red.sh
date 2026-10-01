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
#                 re-diagnose. Ignored when THIS PR's diff references the case (a
#                 marker is keyed on job+case only, so another PR's verdict must
#                 not excuse a PR that touches the case).
#   2. SIGNATURE  the log matches a pattern in scripts/ci/main-red-signatures.txt.
#                 Skipped when the PR changes a dependency manifest or lockfile:
#                 an audit or registry failure may then be the PR's own.
#   3. DIFF       the case string appears nowhere in `git diff <base>...HEAD`
#                 (file names included): the PR neither touches nor references it.
#                 A heuristic (a shared dependency can break an unchanged case),
#                 so it never writes a marker.
# A signature MAIN-RED writes the marker so the next leg stops at 1; the console
# clears it after the fix merges. Anything else is PR-RED: the leg's own.
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
usage() {
    echo "classify-ci-red: usage: --log <readable job log> --job <job> --case <case> [--pr N] [--head SHA]" >&2
    exit 64
}
while [ $# -gt 0 ]; do
    case "$1" in
        --log|--job|--case|--pr|--head)
            [ $# -ge 2 ] || { echo "classify-ci-red: $1 needs a value" >&2; usage; }
            case "$1" in
                --log) log="$2" ;;
                --job) job="$2" ;;
                --case) cs="$2" ;;
                --pr) pr="$2" ;;
                --head) head="$2" ;;
            esac
            shift 2 ;;
        *) echo "classify-ci-red: unknown argument: $1" >&2; exit 64 ;;
    esac
done
if [ -z "$log" ] || [ ! -r "$log" ]; then
    usage
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

# The PR diff, read once: have=1 when it is readable; refs=1 when it mentions the
# case; deps=1 when it changes a dependency manifest or lockfile.
have=0 refs=0 deps=0 dfile=""
if [ -n "${CLASSIFY_DIFF_FILE:-}" ]; then
    [ -r "$CLASSIFY_DIFF_FILE" ] && { dfile="$CLASSIFY_DIFF_FILE"; have=1; }
else
    dfile=$(mktemp "${TMPDIR:-/tmp}/classify-ci-red-diff.XXXXXX") || dfile=""
    if [ -n "$dfile" ]; then
        trap 'rm -f "$dfile"' EXIT
        git diff "${CLASSIFY_BASE:-origin/main}...HEAD" > "$dfile" 2>/dev/null && have=1
    fi
fi
if [ "$have" = 1 ]; then
    [ -z "$cs" ] || ! grep -qiF -e "$cs" "$dfile" || refs=1
    ! grep -qE '^diff --git .*(package(-lock)?\.json|npm-shrinkwrap\.json|bun\.lockb?|yarn\.lock|pnpm-lock\.yaml)' "$dfile" || deps=1
fi

# 1. MARKER — read before diagnosing anything.
if [ -n "$marker" ] && [ -r "$marker" ] && [ "$refs" = 0 ]; then
    main_red marker "$(tr '\n' ' ' < "$marker")"
fi

# 2. SIGNATURE
sigs="${CLASSIFY_SIGNATURES:-$DIR/main-red-signatures.txt}"
if [ "$deps" = 0 ] && [ -r "$sigs" ]; then
    pat=$(grep -vE '^[[:space:]]*(#|$)' "$sigs")
    if [ -n "$pat" ]; then
        hit=$(grep -iE -m1 -e "$pat" "$log" 2>/dev/null) || hit=""
        if [ -n "$hit" ]; then
            write_marker "signature: $hit"
            main_red signature "$hit"
        fi
    fi
fi

# 3. DIFF — only decidable with a case name and a readable diff. No marker: the
#    verdict is a heuristic and a marker would carry it to every later PR.
if [ -n "$cs" ] && [ "$have" = 1 ] && [ "$refs" = 0 ]; then
    main_red diff "case '$cs' is untouched by and unreferenced from the PR diff (heuristic: confirm no shared dependency of the case changed)"
fi

echo "PR-RED $job $cs: no usable marker or signature, and the PR diff touches or references the case, changes a dependency manifest, or could not be read — this red is yours; fix it"
exit 1
