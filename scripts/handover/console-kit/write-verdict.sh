#!/usr/bin/env bash
# scripts/handover/console-kit/write-verdict.sh - HIMMEL-4689: the sanctioned
# writer for a judge's verdict file. A console-judge CALL has no Write tool,
# and the Bash text guards refuse the exact line go.sh --trust-reviewed needs
# (`**GO** for head <sha>`), so before this a judge call could not record its
# own ruling and the console wrote the judge's file for it. This script
# generates that line itself; the judge's prose comes from a file it wrote to
# its scratch, so the command a judge types names nothing the guards key on.
#
# Usage: write-verdict.sh <qid> <GO|NO-GO> <head> --pr <n> --evidence-file <path> [--judge <name>] [--branch <name>]
#
# Writes <root>/<user>/<bucket>/verdicts/<qid>/<name>.md (name defaults to
# `judge`; <name>-<head>.md beside a NO-GO for another head), where <root>
# and <user>/<bucket> are what go.sh resolves for this checkout (go-gate.sh's
# go_resolve_root and go_verdict_scope, so the writer and the reader can never
# disagree on the directory):
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
#     pr: <n>
#     branch: <name>            (only when --branch is given)
#
#     <the evidence file, verbatim>
#     mac: <64 hex>
#
# HIMMEL-4984: the last line signs everything above it with the GO key
# (go-gate.sh's go_verdict_mac, the himmel-verdict-v1 domain), bound to the
# record's <user>/<bucket>, qid and name. review-round.sh's scope and NO-GO paths
# and go.sh --trust-reviewed accept a record only when that mac verifies, so a
# hand-written exact-format file buys nothing. A GO needs a readable GO key
# (exit 3 without one); a NO-GO without one is written unsigned: it still vetoes,
# it buys no delta round.
#
# HIMMEL-4928: the `pr:` line sits at a fixed place, two lines after the verdict
# line, where go.sh --trust-reviewed reads it and refuses a verdict naming
# another PR. review-round.sh reads only the first eight lines, so it is
# unaffected. A verdict file with no `pr:` line (written before this field
# existed) is refused by go.sh; the judge rewrites it with --pr.
#
# The writer-session stamp is a breadcrumb, not authentication: an in-process
# judge call shares the console's environment, so it names the session the
# writer ran in, nothing more. Anything outside [A-Za-z0-9-] is stamped
# `invalid` (a newline must not inject a line above the real verdict).
#
# Refuses, writing nothing:
#   - <qid> or <name> not a path segment ([A-Za-z0-9][A-Za-z0-9._-]*, the
#     go_trust_verdict rule), <head> not 40 lowercase hex, an answer other
#     than GO / NO-GO, an evidence file that is missing, not a regular file
#     or empty, not an absolute path under /tmp/claude-<uid>/, carrying a
#     `.` or `..` segment, or reached through a symlink (so a secret is never
#     copied into the handover state repo);
#   - a console leg (HIMMEL_CONSOLE_LEG) that is not a judge session
#     (HIMMEL_CONSOLE_JUDGE=1): a leg must not certify its own trust-path PR;
#     and a console relay (HIMMEL_CONSOLE_RELAY), as go.sh refuses one;
#   - any directory from <root>/<user> down to the target file that is a
#     symlink, so the write cannot leave verdicts/<qid>/;
#   - a GO when verdicts/<qid>/ already holds a NO-GO for the same head, or a
#     verdict that does not parse (go.sh refuses on either anyway).
# HIMMEL-4885: a new NO-GO evidence file must carry exactly one class: field,
# one value or a comma set from option-parsing, cwd-indirection, shell-parsing,
# tool-defaults, reader-allowlist, other; missing or invalid classes exit 2.
# A valid NO-GO is always written past those last two (HIMMEL-4714): go.sh treats
# any NO-GO as a veto, so it only narrows, and refusing it would leave a
# forged or mistaken GO alone on disk. The same answer again, or a verdict
# for another head, is written. When <name>.md holds a NO-GO for another
# head, the new ruling is written to <name>-<head>.md instead, so that veto
# survives the PR returning to its head (HIMMEL-4731). A name over 150 bytes is
# shortened with a hash suffix so no redirect target can exceed 255 (HIMMEL-4753).
# ponytail: same-uid ceiling - the symlink and conflict checks run before an
# atomic rename, so a same-uid process racing the directory can still swap it
# between check and rename; a separate-uid verdict store is the upgrade path
# (HIMMEL-3578, the GO signer's twin).
#
# HIMMEL-5109: a judge often rules on a head that follows the last reviewed one
# by a test-only or comment-only commit. `--bind-reviewed <sha>` (NO-GO only)
# checks, with review-round.sh's own `trivial-descendant` verb run in the cwd's
# repo, that <head> is a strict descendant of <sha> and the delta changes only
# test paths or comment lines, then writes the NO-GO for <head> as usual and
# records <sha> in a signed `reviewed-head:` annotation; any other delta exits 2,
# nothing written. The verdict line keeps naming the judged head, so every veto
# reader (go_trust_verdict, the GO-over-NO-GO scan, the scope round) still keys
# on it; the round gate binds such a NO-GO to the reviewed head at read time.
# A `layer-decision:` evidence line without its text|os|classifier|accept
# keyword draws a stderr warning (review-round.sh would silently ignore it).
#
# Exit codes:
#   0  written (the path on stdout)
#   2  usage / validation
#   3  refused: a console leg or relay, or the root / <user>/<bucket> scope is unresolved
#   4  refused: symlink, conflicting or unparsed verdict
#   5  write failed
#
# Platform guard (gitbash-only): POSIX bash 3.2+.
set -u
# HIMMEL-3437: a relative-entry copy that is not the anchor's hands off to it.
case "${BASH_SOURCE[0]}" in */*) _ah_d="${BASH_SOURCE[0]%/*}" ;; *) _ah_d=. ;; esac
. "$_ah_d/../../cr/anchor-handoff.sh" || exit 2

usage() {
    echo "usage: write-verdict.sh <qid> <GO|NO-GO> <head> --pr <n> --evidence-file <path> [--judge <name>] [--branch <name>] [--bind-reviewed <sha>]" >&2
    exit 2
}
seg_ok() {
    case "$1" in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

[ "$#" -ge 3 ] || usage
QID=$1 ANSWER=$2 HEAD=$3
shift 3
EVIDENCE="" NAME=judge PR="" BRANCH="" BIND=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --bind-reviewed)
            [ "$#" -ge 2 ] || usage
            [ -n "$2" ] || { echo "write-verdict: --bind-reviewed needs the full 40-char lowercase hex sha (got an empty value)" >&2; exit 2; }
            BIND=$2; shift 2 ;;
        --pr) [ "$#" -ge 2 ] || usage; PR=$2; shift 2 ;;
        --branch) [ "$#" -ge 2 ] || usage; BRANCH=$2; shift 2 ;;
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
# HIMMEL-5109: --bind-reviewed binds a NO-GO the judge ruled on a later head to
# the last reviewed head; the delta check itself runs once the repo is known.
if [ -n "$BIND" ]; then
    case "$BIND" in *[!0123456789abcdef]*) BIND_OK=0 ;; *) BIND_OK=1 ;; esac
    if [ "$BIND_OK" -ne 1 ] || [ "${#BIND}" -ne 40 ]; then
        echo "write-verdict: --bind-reviewed must be the full 40-char lowercase hex sha (got '$BIND')" >&2
        exit 2
    fi
    if [ "$ANSWER" != NO-GO ]; then
        echo "write-verdict: --bind-reviewed binds a NO-GO only (a GO is never moved to another head)" >&2
        exit 2
    fi
    if [ "$BIND" = "$HEAD" ]; then
        echo "write-verdict: --bind-reviewed names the judged head itself; give the earlier reviewed head" >&2
        exit 2
    fi
fi
[ -n "$EVIDENCE" ] || { echo "write-verdict: --evidence-file <path> is required" >&2; exit 2; }
# HIMMEL-4928: the verdict names its PR, as go.sh's PR argument is spelled
# (no leading zero), so two PRs on one head are told apart.
case "$PR" in
    ''|0*|*[!0-9]*) echo "write-verdict: --pr <n> is required and must be a PR number without a leading zero (got '$PR')" >&2; exit 2 ;;
esac
case "$BRANCH" in
    *[!A-Za-z0-9._/-]*|*..*|/*|*/) echo "write-verdict: --branch '$BRANCH' is not a plain branch name ([A-Za-z0-9._/-], no '..')" >&2; exit 2 ;;
esac
# The evidence must live in this uid's Claude scratch root, reached without a
# symlink at any step from that root down.
SCRATCH="/tmp/claude-$(id -u)"
case "$EVIDENCE" in
    "$SCRATCH"/*) ;;
    *) echo "write-verdict: evidence file '$EVIDENCE' must be an absolute path under $SCRATCH/" >&2; exit 2 ;;
esac
case "/$EVIDENCE/" in
    */./*|*/../*) echo "write-verdict: evidence file '$EVIDENCE' carries a . or .. segment" >&2; exit 2 ;;
esac
if [ -L "$SCRATCH" ] || [ ! -d "$SCRATCH" ] || [ ! -O "$SCRATCH" ]; then
    echo "write-verdict: '$SCRATCH' is not a directory this uid owns (or is a symlink)" >&2
    exit 2
fi
# No other user may reach anything below the root: under a root only this uid
# can enter, nobody else can swap a path segment between these checks and the
# cat, however a descendant is permissioned. The mode is read with stat
# (GNU `-c %a`, else BSD `-f %Lp`), not `ls -ld`, whose macOS `@` suffix for
# extended attributes refused every write (HIMMEL-4723). A `+` after the mode
# in `ls -ld` (an ACL that may grant others access) is still refused.
# ponytail: macOS ls prints `@` in place of `+` when a directory has both
# xattrs and an ACL, so an ACL behind xattrs passes there; the upgrade path is
# an `ls -lde` ACL read on BSD (HIMMEL-4742).
#
# HIMMEL-4753: an `ls -ld` that fails or prints nothing cannot show the root
# free of an ACL, so it refuses like the stat branch does.
ev_mode=$(stat -c %a "$SCRATCH" 2>/dev/null) || ev_mode=$(stat -f %Lp "$SCRATCH" 2>/dev/null) || ev_mode=""
ev_ls=$(ls -ld "$SCRATCH" 2>/dev/null) || ev_ls=""
# HIMMEL-4962: an `ls` that exits 0 with a non-mode line (garbage, a space) is
# no better, so the first field must be a directory mode string, `d` and nine
# permission characters, optionally followed by `+`, `.` or `@`.
ev_modestr=${ev_ls%%[[:space:]]*}
[[ $ev_modestr =~ ^d[-rwxsStT]{9}[+.@]?$ ]] || ev_mode=unreadable
case "$ev_mode:$ev_modestr" in
    700:*+) ev_mode=acl ;;
esac
if [ "$ev_mode" != 700 ]; then
    echo "write-verdict: '$SCRATCH' is accessible to group or other users (want 0700) - refusing" >&2
    exit 2
fi
ev_dir=$SCRATCH
ev_rest=${EVIDENCE#"$SCRATCH"/}
while :; do
    case "$ev_rest" in */*) ev_seg=${ev_rest%%/*}; ev_rest=${ev_rest#*/} ;; *) ev_seg=$ev_rest; ev_rest="" ;; esac
    [ -n "$ev_seg" ] && ev_dir="$ev_dir/$ev_seg"
    if [ -L "$ev_dir" ]; then
        echo "write-verdict: evidence path '$ev_dir' is a symlink - refusing" >&2
        exit 2
    fi
    [ -n "$ev_rest" ] || break
done
if [ ! -f "$EVIDENCE" ] || [ ! -r "$EVIDENCE" ] || [ ! -s "$EVIDENCE" ]; then
    echo "write-verdict: evidence file '$EVIDENCE' is missing, unreadable, not a regular file or empty" >&2
    exit 2
fi
# HIMMEL-4984: a record is text. A NUL or other control byte (tab, LF and CR
# stay) would make every consumer's whole-file read refuse the record.
if [ "$(wc -c < "$EVIDENCE")" != "$(LC_ALL=C tr -d '\000-\010\013\014\016-\037\177' < "$EVIDENCE" | wc -c)" ]; then
    echo "write-verdict: evidence file '$EVIDENCE' holds a NUL or non-text control byte - refusing (HIMMEL-4984)" >&2
    exit 2
fi
# HIMMEL-4885: every new NO-GO names the finding class before it can buy
# a delta round. GO evidence need not carry a class. Keep one unambiguous
# field; unknown labels and empty members cannot become a fresh class.
if [ "$ANSWER" = NO-GO ]; then
    classes=$(awk '/^class:/ { sub(/^class:[ \t]*/, ""); sub(/[ \t\r]+$/, ""); print }' "$EVIDENCE")
    class_word='(option-parsing|cwd-indirection|shell-parsing|tool-defaults|reader-allowlist|other)'
    class_re="^$class_word([[:blank:]]*,[[:blank:]]*$class_word)*$"
    if [ "$(grep -c '^class:' "$EVIDENCE")" != 1 ] || ! [[ $classes =~ $class_re ]]; then
        echo "write-verdict: NO-GO requires one class: field, a comma set from option-parsing, cwd-indirection, shell-parsing, tool-defaults, reader-allowlist, other" >&2
        exit 2
    fi
fi
# HIMMEL-5109: review-round.sh honours a layer-decision line only as
# `layer-decision: text|os|classifier|accept <reason>`; one without the keyword
# is silently dropped and the repeated-class stop stays. Warn at write time
# (not refuse: a NO-GO only narrows, HIMMEL-4714) with the same two patterns.
if awk '/^layer-decision:/ && (!/^layer-decision: (text|os|classifier|accept)[ \t]+[^ \t]/ || /\r$/) { bad = 1 } END { exit !bad }' "$EVIDENCE"; then
    echo "write-verdict: warning - a layer-decision line lacks a layer keyword; review-round.sh will not honour it. Write: layer-decision: text|os|classifier|accept <reason> (HIMMEL-5109)" >&2
fi
case "$(printf '%s' "${HIMMEL_CONSOLE_RELAY:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
    ''|0|false|off|no) ;;
    *)
        echo "write-verdict: refusing - this is a console relay (HIMMEL_CONSOLE_RELAY is set); a relay never writes a verdict." >&2
        exit 3 ;;
esac
SESSION=${CLAUDE_CODE_SESSION_ID:-unknown}
case "$SESSION" in *[!A-Za-z0-9-]*) SESSION=invalid ;; esac

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/go-gate.sh
# shellcheck disable=SC1091
if ! . "$HERE/../../lib/go-gate.sh" 2>/dev/null || ! declare -F console_leg >/dev/null 2>&1 \
        || ! declare -F go_resolve_root >/dev/null 2>&1 || ! declare -F go_verdict_scope >/dev/null 2>&1 \
        || ! declare -F go_verdict_mac >/dev/null 2>&1 || ! declare -F go_key_file >/dev/null 2>&1; then
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

# HIMMEL-5109: the judged head must be a strict descendant of the reviewed head
# whose delta is test-path-only or comment-only - review-round.sh's own rule,
# asked through its read-only verb so the writer and the gate cannot disagree.
# It runs in the caller's cwd (the repo under review); the absolute script path
# is never handed off to the anchor. The verdict line stays on the judged head
# (moving it to the reviewed head would strip the judged head of its veto); the
# reviewed head is only annotated.
REVIEWED=""
if [ -n "$BIND" ]; then
    if ! bash "$ANCHOR/scripts/cr/review-round.sh" trivial-descendant "$BIND" "$HEAD" >/dev/null 2>&1; then
        echo "write-verdict: --bind-reviewed refused - $HEAD is not a strict descendant of $BIND whose delta changes only test paths or comment lines (run from the repo under review); nothing written" >&2
        exit 2
    fi
    REVIEWED=$BIND
fi

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
# HIMMEL-4753: a redirect appends -<40-hex head> to the name, so a long --judge
# name could push <name>.md past the 255-byte filename limit and lose the
# ruling. A name over 150 bytes is cut to 100 plus a hash of the full name, so
# the result is deterministic and every redirect target stays well under 255.
bound_name() {
    [ "${#NAME}" -gt 150 ] || return 0
    nb_h=$(printf '%s' "$NAME" | { sha256sum 2>/dev/null || shasum -a 256 2>/dev/null || cksum; } | tr -d ' ' | cut -c1-16)
    NAME="$(printf '%s' "$NAME" | cut -c1-100)-$nb_h"
}
bound_name
TARGET="$dir/$NAME.md"

# Hold the qid's lock across the scan and the publish: two writers racing on
# one qid could otherwise both pass the scan, and the last mv erase a NO-GO.
# mkdir is the portable atomic test-and-set (no flock on macOS).
# The lock records its owner (pid=<pid> at=<UTC time>) so a stale one says
# whose it was and whether that writer is still running.
lockd="$dir/.write-verdict.lock"
tmpf=""
tries=0
until mkdir "$lockd" 2>/dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge 50 ]; then
        owner=$(head -n 1 "$lockd/owner" 2>/dev/null)
        opid=$(printf '%s\n' "$owner" | sed -nE 's/^pid=([0-9]+) .*/\1/p')
        if [ -z "$owner" ]; then
            state="its owner is unrecorded (a writer killed before it recorded one)"
        elif [ -n "$opid" ] && ! kill -0 "$opid" 2>/dev/null; then
            state="held by $owner; pid $opid is not running, so the lock is stale"
        else
            state="held by $owner; that writer may still be running - wait for it"
        fi
        echo "write-verdict: '$lockd' is held: $state" >&2
        echo "write-verdict: once no writer is running, recover with: rm -r '$lockd'" >&2
        exit 5
    fi
    sleep 0.1
done
trap 'rm -f "$tmpf" "$lockd/owner"; rmdir "$lockd" 2>/dev/null' EXIT
printf 'pid=%s at=%s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$lockd/owner" 2>/dev/null || true

# HIMMEL-4731: a NO-GO in <name>.md for another head is never replaced - the
# PR may return to that head, where another judge's GO would then stand alone.
# The ruling goes to <name>-<head>.md beside it instead; its header names that
# file, as review-round.sh's judge_nogo_record requires. The check repeats on
# the new name, so a judge itself named <name>-<head> loses no veto either.
while [ -f "$TARGET" ] && [ ! -L "$TARGET" ]; do
    # shellcheck disable=SC2016  # the backticks are the verdict line's literal text
    old=$(tr -d '\r' < "$TARGET" 2>/dev/null | awk '/^## Verdict[[:space:]]*$/ { p = 1; next } p && NF { print; exit }' \
        | sed -nE 's/^\*\*NO-GO\*\* for head `([0-9a-f]{40})`\.?$/\1/p')
    if [ -z "$old" ] || [ "$old" = "$HEAD" ]; then
        break
    fi
    NAME="$NAME-$HEAD"
    bound_name
    TARGET="$dir/$NAME.md"
done
if [ -L "$TARGET" ] || { [ -e "$TARGET" ] && [ ! -f "$TARGET" ]; }; then
    echo "write-verdict: refusing - '$TARGET' is a symlink or not a regular file" >&2
    exit 4
fi

# Before a GO, every verdict already here must parse and none may rule NO-GO
# on HEAD. A NO-GO skips the scan: it only narrows (HIMMEL-4714).
# The parse is go_trust_verdict's, line for line.
# shellcheck disable=SC2016  # the backticks are the verdict line's literal text
for f in "$dir"/*.md; do
    [ "$ANSWER" = GO ] || break
    [ -f "$f" ] || continue
    line=$(tr -d '\r' < "$f" 2>/dev/null | awk '/^## Verdict[[:space:]]*$/ { p = 1; next } p && NF { print; exit }')
    word=$(printf '%s\n' "$line" | sed -nE 's/^\*\*(GO|NO-GO)\*\* for head `[0-9a-f]{40}`\.?$/\1/p')
    head=$(printf '%s\n' "$line" | sed -nE 's/^\*\*(GO|NO-GO)\*\* for head `([0-9a-f]{40})`\.?$/\2/p')
    if [ -z "$word" ] || [ -z "$head" ]; then
        echo "write-verdict: refusing - '$f' does not parse as a verdict (go.sh would refuse the qid); fix or remove it first" >&2
        exit 4
    fi
    if [ "$head" = "$HEAD" ] && [ "$word" = NO-GO ]; then
        echo "write-verdict: refusing - '$f' already rules NO-GO for head $HEAD; a GO never overrides a veto" >&2
        exit 4
    fi
done

tmpf=$(mktemp "$dir/.write-verdict.XXXXXX") || { echo "write-verdict: cannot create a temp file in '$dir'" >&2; exit 5; }
# Each write is checked: a failed header must not publish a partial verdict.
# shellcheck disable=SC2016  # the backticks are the verdict line's literal text
if ! {
    printf '# VERDICT %s - %s\n\n' "$QID" "$NAME" &&
    printf 'writer-session: %s\n' "$SESSION" &&
    printf 'written-at: %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" &&
    printf '## Verdict\n\n**%s** for head `%s`.\n\n' "$ANSWER" "$HEAD" &&
    printf 'pr: %s\n' "$PR" &&
    { [ -z "$BRANCH" ] || printf 'branch: %s\n' "$BRANCH"; } &&
    printf '\n' &&
    { [ -z "$REVIEWED" ] || printf 'reviewed-head: %s\nbound-by: write-verdict --bind-reviewed; the delta from the reviewed head is test-path-only or comment-only\n\n' "$REVIEWED"; } &&
    cat "$EVIDENCE" &&
    # HIMMEL-4984: the body ends in a newline, so the mac line is a line of its own.
    { [ -z "$(tail -c 1 "$EVIDENCE")" ] || printf '\n'; }
} > "$tmpf"; then
    echo "write-verdict: writing '$TARGET' failed" >&2
    exit 5
fi
# HIMMEL-4984: sign every byte above the mac line with the GO key, bound to this
# record's scope, qid and name; a record without a valid mac buys no round and
# no merge trust, so a key that cannot sign refuses the write.
if MAC=$(go_verdict_mac "$SCOPE" "$QID" "$NAME" < "$tmpf"); then
    SIGNED=1
elif [ "$ANSWER" = NO-GO ]; then
    # A NO-GO only narrows (HIMMEL-4714): written unsigned it still vetoes, it just buys no round.
    echo "write-verdict: warning - NO-GO written without a mac (no readable GO key); it vetoes but buys no delta round" >&2
    SIGNED=0
else
    echo "write-verdict: cannot sign the verdict - no readable GO key at $(go_key_file) (go.sh mints it on the console's first GO), or openssl is missing; nothing written" >&2
    exit 3
fi
if { [ "$SIGNED" -ne 1 ] || printf 'mac: %s\n' "$MAC" >> "$tmpf"; } && mv -f "$tmpf" "$TARGET"; then
    :
else
    echo "write-verdict: writing '$TARGET' failed" >&2
    exit 5
fi
printf '%s\n' "$TARGET"
