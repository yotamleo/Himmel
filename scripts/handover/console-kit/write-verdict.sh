#!/usr/bin/env bash
# scripts/handover/console-kit/write-verdict.sh - HIMMEL-4689: the sanctioned
# writer for a judge's verdict file. A console-judge CALL has no Write tool,
# and the Bash text guards refuse the exact line go.sh --trust-reviewed needs
# (`**GO** for head <sha>`), so before this a judge call could not record its
# own ruling and the console wrote the judge's file for it. This script
# generates that line itself; the judge's prose comes from a file it wrote to
# its scratch, so the command a judge types names nothing the guards key on.
#
# Usage: write-verdict.sh <qid> <GO|NO-GO> <head> --evidence-file <path> [--judge <name>]
#
# Writes <root>/<user>/<bucket>/verdicts/<qid>/<name>.md (name defaults to
# `judge`), where <root> and <user>/<bucket> are what go.sh resolves for this
# checkout (go-gate.sh's go_resolve_root and go_verdict_scope, so the writer
# and the reader can never disagree on the directory):
#
#     # VERDICT <qid> - <name>
#
#     writer-session: <CLAUDE_CODE_SESSION_ID>
#     written-at: <UTC time>
#
#     ## Verdict
#
#     **GO** for head `<head>`.
#
#     <the evidence file, verbatim>
#
# Refuses, writing nothing:
#   - <qid> or <name> not a path segment ([A-Za-z0-9][A-Za-z0-9._-]*, the
#     go_trust_verdict rule), <head> not 40 lowercase hex, an answer other
#     than GO / NO-GO, an evidence file that is missing, not a regular file
#     or empty;
#   - a console leg (HIMMEL_CONSOLE_LEG) that is not a judge session
#     (HIMMEL_CONSOLE_JUDGE=1): a leg must not certify its own trust-path PR;
#   - any directory from <root>/<user> down to the target file that is a
#     symlink, so the write cannot leave verdicts/<qid>/;
#   - an existing verdict in verdicts/<qid>/ for the same head with the other
#     answer, or one that does not parse (go.sh refuses on either anyway).
# The same answer again, or a verdict for another head, is written.
# ponytail: same-uid ceiling - the symlink and conflict checks run before an
# atomic rename, so a same-uid process racing the directory can still swap it
# between check and rename; a separate-uid verdict store is the upgrade path
# (HIMMEL-3578, the GO signer's twin).
#
# Exit codes:
#   0  written (the path on stdout)
#   2  usage / validation
#   3  refused: a console leg, or the root / <user>/<bucket> scope is unresolved
#   4  refused: symlink, conflicting or unparsed verdict
#   5  write failed
#
# Platform guard (gitbash-only): POSIX bash 3.2+.
set -u
# HIMMEL-3437: a relative-entry copy that is not the anchor's hands off to it.
case "${BASH_SOURCE[0]}" in */*) _ah_d="${BASH_SOURCE[0]%/*}" ;; *) _ah_d=. ;; esac
. "$_ah_d/../../cr/anchor-handoff.sh" || exit 2

usage() {
    echo "usage: write-verdict.sh <qid> <GO|NO-GO> <head> --evidence-file <path> [--judge <name>]" >&2
    exit 2
}
seg_ok() {
    case "$1" in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

[ "$#" -ge 3 ] || usage
QID=$1 ANSWER=$2 HEAD=$3
shift 3
EVIDENCE="" NAME=judge
while [ "$#" -gt 0 ]; do
    case "$1" in
        --evidence-file) [ "$#" -ge 2 ] || usage; EVIDENCE=$2; shift 2 ;;
        --judge) [ "$#" -ge 2 ] || usage; NAME=$2; shift 2 ;;
        *) usage ;;
    esac
done
seg_ok "$QID" || { echo "write-verdict: qid '$QID' is not a path segment ([A-Za-z0-9][A-Za-z0-9._-]*)" >&2; exit 2; }
seg_ok "$NAME" || { echo "write-verdict: judge name '$NAME' is not a path segment ([A-Za-z0-9][A-Za-z0-9._-]*)" >&2; exit 2; }
case "$ANSWER" in GO|NO-GO) ;; *) echo "write-verdict: the answer must be GO or NO-GO (got '$ANSWER')" >&2; exit 2 ;; esac
case "$HEAD" in *[!0123456789abcdef]*) HEAD_OK=0 ;; *) HEAD_OK=1 ;; esac
if [ "$HEAD_OK" -ne 1 ] || [ "${#HEAD}" -ne 40 ]; then
    echo "write-verdict: head must be the full 40-char lowercase hex sha (got '$HEAD')" >&2
    exit 2
fi
[ -n "$EVIDENCE" ] || { echo "write-verdict: --evidence-file <path> is required" >&2; exit 2; }
if [ ! -f "$EVIDENCE" ] || [ ! -r "$EVIDENCE" ] || [ ! -s "$EVIDENCE" ]; then
    echo "write-verdict: evidence file '$EVIDENCE' is missing, unreadable, not a regular file or empty" >&2
    exit 2
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/go-gate.sh
# shellcheck disable=SC1091
if ! . "$HERE/../../lib/go-gate.sh" 2>/dev/null || ! declare -F console_leg >/dev/null 2>&1 \
        || ! declare -F go_resolve_root >/dev/null 2>&1 || ! declare -F go_verdict_scope >/dev/null 2>&1; then
    echo "write-verdict: cannot load scripts/lib/go-gate.sh - refusing" >&2
    exit 3
fi
if console_leg && [ "${HIMMEL_CONSOLE_JUDGE:-}" != "1" ]; then
    echo "write-verdict: refusing - this is a console-spawned leg (HIMMEL_CONSOLE_LEG is set) and not a judge session; a leg never writes the verdict for its own PR." >&2
    exit 3
fi
# shellcheck source=scripts/lib/handover-path.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/handover-path.sh" || { echo "write-verdict: cannot load scripts/lib/handover-path.sh" >&2; exit 3; }
ANCHOR="$(cd "$HERE/../../.." && pwd)"
ROOT=$(go_resolve_root "$ANCHOR") || { echo "write-verdict: cannot resolve the handover root go.sh reads" >&2; exit 3; }
SCOPE=$(go_verdict_scope "$ANCHOR") || { echo "write-verdict: cannot resolve this repo's <user>/<bucket> verdict scope" >&2; exit 3; }
[ -d "$ROOT" ] || { echo "write-verdict: handover root '$ROOT' is not a directory" >&2; exit 3; }

# Walk <root>/<user>/<bucket>/verdicts/<qid>, refusing a symlink at any step.
dir=$ROOT
for seg in "${SCOPE%%/*}" "${SCOPE#*/}" verdicts "$QID"; do
    dir="$dir/$seg"
    if [ -L "$dir" ]; then
        echo "write-verdict: refusing - '$dir' is a symlink" >&2
        exit 4
    fi
    if [ ! -d "$dir" ]; then
        mkdir "$dir" 2>/dev/null || { echo "write-verdict: cannot create '$dir'" >&2; exit 5; }
    fi
done
TARGET="$dir/$NAME.md"

# Hold the qid's lock across the scan and the publish: two writers racing on
# one qid could otherwise both pass the scan, and the last mv erase a NO-GO.
# mkdir is the portable atomic test-and-set (no flock on macOS).
lockd="$dir/.write-verdict.lock"
tmpf=""
tries=0
until mkdir "$lockd" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge 50 ]; then
        echo "write-verdict: '$lockd' is held by another writer (or left by a killed one: remove it only if no writer is running)" >&2
        exit 5
    fi
    sleep 0.1
done
trap 'rm -f "$tmpf"; rmdir "$lockd" 2>/dev/null' EXIT

if [ -L "$TARGET" ] || { [ -e "$TARGET" ] && [ ! -f "$TARGET" ]; }; then
    echo "write-verdict: refusing - '$TARGET' is a symlink or not a regular file" >&2
    exit 4
fi

# Every verdict already here must parse; none may rule the other way on HEAD.
# The parse is go_trust_verdict's, line for line.
# shellcheck disable=SC2016  # the backticks are the verdict line's literal text
for f in "$dir"/*.md; do
    [ -f "$f" ] || continue
    line=$(tr -d '\r' < "$f" 2>/dev/null | awk '/^## Verdict[[:space:]]*$/ { p = 1; next } p && NF { print; exit }')
    word=$(printf '%s\n' "$line" | sed -nE 's/^\*\*(GO|NO-GO)\*\* for head `[0-9a-f]{40}`\.?$/\1/p')
    head=$(printf '%s\n' "$line" | sed -nE 's/^\*\*(GO|NO-GO)\*\* for head `([0-9a-f]{40})`\.?$/\2/p')
    if [ -z "$word" ] || [ -z "$head" ]; then
        echo "write-verdict: refusing - '$f' does not parse as a verdict (go.sh would refuse the qid); fix or remove it first" >&2
        exit 4
    fi
    if [ "$head" = "$HEAD" ] && [ "$word" != "$ANSWER" ]; then
        echo "write-verdict: refusing - '$f' already rules $word for head $HEAD; a verdict is not rewritten the other way" >&2
        exit 4
    fi
done

tmpf=$(mktemp "$dir/.write-verdict.XXXXXX") || { echo "write-verdict: cannot create a temp file in '$dir'" >&2; exit 5; }
# Each write is checked: a failed header must not publish a partial verdict.
# shellcheck disable=SC2016  # the backticks are the verdict line's literal text
if ! {
    printf '# VERDICT %s - %s\n\n' "$QID" "$NAME" &&
    printf 'writer-session: %s\n' "${CLAUDE_CODE_SESSION_ID:-unknown}" &&
    printf 'written-at: %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" &&
    printf '## Verdict\n\n**%s** for head `%s`.\n\n' "$ANSWER" "$HEAD" &&
    cat "$EVIDENCE"
} > "$tmpf" || ! mv -f "$tmpf" "$TARGET"; then
    echo "write-verdict: writing '$TARGET' failed" >&2
    exit 5
fi
printf '%s\n' "$TARGET"
