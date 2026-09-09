#!/usr/bin/env bash
# scripts/handover/console/console.sh — start or hand over a console session
# (HIMMEL-2873).
#
# A console is a long-running headed Claude session that holds a queue lock
# on its own handover document, runs monitors, dispatches implementation
# legs, rules on their questions, relays merges, and arms its own successor
# when its context fills. This script packages what an operator used to do
# by hand:
#   console.sh new  — write the console doc + acquire its queue lock, print
#                     the launch line.
#   console.sh next — write the successor's doc stub, write the predecessor's
#                     HANDOFF skeleton, print the launch line.
#
# Env seams: HANDOVER_DIR / USER_SLUG / JIRA_PROJECT_KEY (via .env, see
# load-dotenv.sh); CONSOLE_BUCKET, CONSOLE_DOC, CONSOLE_MODEL,
# CONSOLE_FILL_PERCENT, CONSOLE_TEMPLATE_DIR, CONSOLE_WORK_DIR (default:
# ${TMPDIR:-/tmp}/himmel-console-<uid>, per-uid rather than a predictable
# shared path), CONSOLE_HEADED_ARM, CONSOLE_ARM_FOREGROUND (test seam: run
# the arm in the foreground instead of detaching it).
# Flag seams: --name (both commands; on next it selects which chain to
# continue) --arm --dry-run --model --bucket --prefix --deadline-min --doc
# (next only). See `-h`/`--help` for the full surface.
#
# Exit codes: 0 ok; 1 usage/state error (letters A-Z exhausted, no
# predecessor found, an unresolved {{PLACEHOLDER}} survived a render); 2
# unresolved handover root / user slug / a missing template file.
#
# Platform guard (gitbash-only): POSIX bash 3.2+; --arm launches through
# konsole (Linux/KDE, via headed-arm.sh), so no .ps1 twin — the Windows
# station arms via scripts/handover/arm-resume.sh's schtasks backend.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/load-dotenv.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/load-dotenv.sh"
# shellcheck source=../../lib/user-slug.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/user-slug.sh"
# shellcheck source=../../lib/handover-path.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/handover-path.sh"
load_dotenv HANDOVER_DIR USER_SLUG JIRA_PROJECT_KEY

ALPHABET="ABCDEFGHIJKLMNOPQRSTUVWXYZ"

usage() {
    cat <<'USAGE'
usage: console.sh new  [--name <slug>] [--arm] [--dry-run] [--model <m>]
                       [--bucket <b>] [--prefix <P>] [--deadline-min <n>]
       console.sh next [--doc <path>] [--name <slug>] [--arm] [--dry-run]
                       [--model <m>] [--bucket <b>] [--prefix <P>]
                       [--deadline-min <n>]
       console.sh -h|--help

--name on next selects which chain to continue; defaults to the name
implied by --doc's own basename when --doc is given and --name is not,
else "console".
USAGE
}

err() { echo "console: $*" >&2; }

# slugify <value> -- lowercase, non-alnum runs -> '-', trim leading/trailing
# '-'. Mirrors user-slug.sh's _user_slug_slugify (bucket-name convention).
slugify() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

# resolve_repo -- the primary checkout root (parent of the shared git-common
# dir), which resolves correctly from a plain checkout OR a linked worktree.
resolve_repo() {
    local common
    if common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
        (cd "$(dirname "$common")" && pwd)
        return 0
    fi
    (cd "$HERE/../../.." && pwd)
}

# next_letter <A-Y> -- the following letter in the alphabet.
next_letter() {
    local cur="$1" before
    before="${ALPHABET%%"$cur"*}"
    printf '%s' "${ALPHABET:$((${#before} + 1)):1}"
}

# render_template <template> <out> KEY VALUE [KEY VALUE ...] -- literal
# {{KEY}} -> VALUE substitution over the whole file (bash parameter
# expansion, not sed s///, so a VALUE containing '/' — every path here —
# never needs escaping). Fails loudly, naming the placeholder, if any
# {{...}} survives in the written output.
render_template() {
    local template="$1" out="$2" content leftover
    shift 2
    content="$(cat "$template")"
    while [ "$#" -gt 0 ]; do
        content="${content//"{{$1}}"/$2}"
        shift 2
    done
    printf '%s\n' "$content" > "$out"
    leftover="$(grep -oE '\{\{[A-Za-z_]+\}\}' "$out" 2>/dev/null | sort -u | head -n 1)" || leftover=""
    if [ -n "$leftover" ]; then
        rm -f "$out"
        err "unresolved placeholder $leftover in $template"
        exit 1
    fi
}

# find_free_letter -- first letter A-Z with no existing doc for today+name.
find_free_letter() {
    local l
    for l in {A..Z}; do
        [ -e "$state_dir/${prefix}-nextleg-${date}${l}-${name}.md" ] || { printf '%s' "$l"; return 0; }
    done
    return 1
}

# do_arm <session> <doc> <fill-signal> <log> -- launch (or foreground-run,
# under CONSOLE_ARM_FOREGROUND=1) the headed-arm target and print the armed
# lines. deadline_epoch/model/workdir are read from the outer resolution
# (constant for the whole invocation), not passed positionally.
do_arm() {
    local session="$1" doc="$2" fill_signal="$3" log="$4" arm
    mkdir -p "$(dirname "$log")"
    arm="${CONSOLE_HEADED_ARM:-$HERE/../headed-arm.sh}"
    if [ "${CONSOLE_ARM_FOREGROUND:-0}" = "1" ]; then
        bash "$arm" "$session" "$doc" "$fill_signal" "$deadline_epoch" "$log" "$model"
    elif command -v setsid >/dev/null 2>&1; then
        setsid nohup bash "$arm" "$session" "$doc" "$fill_signal" "$deadline_epoch" "$log" "$model" >/dev/null 2>&1 &
    else
        nohup bash "$arm" "$session" "$doc" "$fill_signal" "$deadline_epoch" "$log" "$model" >/dev/null 2>&1 &
    fi
    echo "armed: name=$session doc=$doc signal=$fill_signal deadline=$deadline_epoch log=$log"
    echo "arm-log: $log"
}

CMD="${1:-}"
case "$CMD" in
    -h|--help) usage; exit 0 ;;
    new|next) shift ;;
    "") usage >&2; exit 1 ;;
    *) err "unknown command: $CMD"; usage >&2; exit 1 ;;
esac

NAME="console"
NAME_GIVEN=0
ARM=0
DRY_RUN=0
MODEL=""
BUCKET=""
PREFIX=""
DEADLINE_MIN=480
DOC_ARG=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --name)
            [ "$#" -ge 2 ] || { usage >&2; exit 1; }
            NAME="$2"; NAME_GIVEN=1; shift 2 ;;
        --name=*)
            NAME="${1#--name=}"; NAME_GIVEN=1; shift ;;
        --doc)
            [ "$CMD" = next ] || { err "--doc is only valid for 'next'"; usage >&2; exit 1; }
            [ "$#" -ge 2 ] || { usage >&2; exit 1; }
            DOC_ARG="$2"; shift 2 ;;
        --doc=*)
            [ "$CMD" = next ] || { err "--doc is only valid for 'next'"; usage >&2; exit 1; }
            DOC_ARG="${1#--doc=}"; shift ;;
        --arm) ARM=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --model) [ "$#" -ge 2 ] || { usage >&2; exit 1; }; MODEL="$2"; shift 2 ;;
        --model=*) MODEL="${1#--model=}"; shift ;;
        --bucket) [ "$#" -ge 2 ] || { usage >&2; exit 1; }; BUCKET="$2"; shift 2 ;;
        --bucket=*) BUCKET="${1#--bucket=}"; shift ;;
        --prefix) [ "$#" -ge 2 ] || { usage >&2; exit 1; }; PREFIX="$2"; shift 2 ;;
        --prefix=*) PREFIX="${1#--prefix=}"; shift ;;
        --deadline-min) [ "$#" -ge 2 ] || { usage >&2; exit 1; }; DEADLINE_MIN="$2"; shift 2 ;;
        --deadline-min=*) DEADLINE_MIN="${1#--deadline-min=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) err "unknown arg: $1"; usage >&2; exit 1 ;;
    esac
done

case "$DEADLINE_MIN" in
    ''|*[!0-9]*) err "--deadline-min must be a positive integer, got '$DEADLINE_MIN'"; exit 1 ;;
esac

# --- resolve root / slug / bucket / repo / prefix / state dir -------------
if ! root="$(handover_root)"; then
    err "set HANDOVER_DIR or run /handover-setup."
    exit 2
fi
if ! slug="$(user_slug)"; then
    err "cannot resolve USER_SLUG. Set USER_SLUG or configure your forge login / git user.name."
    exit 2
fi
repo="$(resolve_repo)"
if [ -n "$BUCKET" ]; then
    bucket="$(slugify "$BUCKET")"
elif [ -n "${CONSOLE_BUCKET:-}" ]; then
    bucket="$(slugify "$CONSOLE_BUCKET")"
else
    bucket="$(slugify "$(basename "$repo")")"
fi
if [ -n "$PREFIX" ]; then
    prefix="$PREFIX"
elif [ -n "${JIRA_PROJECT_KEY:-}" ]; then
    prefix="$JIRA_PROJECT_KEY"
else
    prefix="$(printf '%s' "$bucket" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z0-9')"
fi
# `next` without an explicit --name derives the chain name from --doc's own
# basename (<PREFIX>-nextleg-<DATE><LETTER>-<NAME>.md) — a cross-bucket
# --doc flow must not force the operator to also repeat --name.
if [ "$CMD" = next ] && [ "$NAME_GIVEN" -ne 1 ]; then
    _doc_for_name="${DOC_ARG:-${CONSOLE_DOC:-}}"
    if [ -n "$_doc_for_name" ]; then
        _stem_for_name="$(basename "$_doc_for_name")"
        _stem_for_name="${_stem_for_name%.md}"
        if [[ "$_stem_for_name" =~ ^"$prefix"-nextleg-[0-9]{4}-[0-9]{2}-[0-9]{2}[A-Z]-(.+)$ ]]; then
            NAME="${BASH_REMATCH[1]}"
        fi
    fi
fi

# slugify --name too: it lands in a file path and a session name, so a raw
# '--name ../evil' or a name with spaces must not reach either verbatim.
name="$(slugify "$NAME")"
if [ -z "$name" ]; then
    err "--name resolved to an empty slug (got '$NAME')"
    exit 1
fi
date="$(date +%F)"
state_dir="$root/$slug/$bucket"
model="${MODEL:-${CONSOLE_MODEL:-claude-fable-5-1}}"
fill_percent="${CONSOLE_FILL_PERCENT:-45}"
# The uid suffix prevents collision between DIFFERENT users on a shared
# host; it does NOT prevent deliberate pre-creation of this exact path by
# another local user (mkdir -p accepts an existing dir regardless of who
# made it). A stable path is required by design here — the arming side and
# the touching side must agree on the signal path across separate
# invocations — so a fresh mktemp per run is not available as a fix; real
# hardening (ownership + symlink checks, or XDG_RUNTIME_DIR) is tracked
# separately: HIMMEL-2881. CONSOLE_WORK_DIR still overrides this outright.
workdir="${CONSOLE_WORK_DIR:-${TMPDIR:-/tmp}/himmel-console-$(id -u)}"
# Namespaced by chain identity (slug+bucket), NOT just session name: the
# session name is keyed on <PREFIX>-nextleg-<date><letter>-<name> only (the
# established, fleet-wide convention — out of scope to change), so two
# chains that differ just by bucket but share prefix/date/letter/name would
# otherwise collide on the SAME signal/log path and touching one chain's
# signal could arm the other's successor.
chain_dir="$workdir/${slug}-${bucket}"
# 10# forces base-10: DEADLINE_MIN passed the digits-only check above, but a
# leading zero (e.g. "08") is otherwise read as octal in arithmetic context,
# and 8/9 are not valid octal digits.
deadline_epoch=$(( $(date +%s) + 10#$DEADLINE_MIN * 60 ))
template_dir="${CONSOLE_TEMPLATE_DIR:-$repo/docs/handover}"
console_template="$template_dir/console-template.md"
handoff_template="$template_dir/console-handoff-template.md"
kit="$repo/scripts/handover/console-kit"

# --- new --------------------------------------------------------------
cmd_new() {
    [ -f "$console_template" ] || { err "missing template $console_template"; exit 2; }

    if [ "$DRY_RUN" -eq 1 ]; then
        local letter
        letter="$(find_free_letter)" || { err "all 26 letters (A-Z) are taken for today's '$name' console in $state_dir"; exit 1; }
        local doc="$state_dir/${prefix}-nextleg-${date}${letter}-${name}.md"
        local session="${prefix}-nextleg-${date}${letter}-${name}"
        local fill_signal="$chain_dir/sig-$session"
        local log="$chain_dir/launch-$session.log"
        echo "would-doc: $doc"
        echo "would-session: $session"
        echo "would-kit: $kit"
        echo "would-launch: claude --model $model --autocompact auto -n $session \"load $doc and continue\""
        if [ "$ARM" -eq 1 ]; then
            echo "would-armed: name=$session doc=$doc signal=$fill_signal deadline=$deadline_epoch log=$log"
            echo "would-arm-log: $log"
        fi
        return 0
    fi

    mkdir -p "$state_dir"
    # Claim a letter by ATOMIC EXCLUSIVE CREATE, never scan-then-create (the
    # repo's own convention — see headed-arm.sh's codex-2 note): two
    # concurrent `new` runs racing a plain find_free_letter could both pick
    # the same free letter, and the second would truncate the first's doc
    # before either took its queue lock. `set -C` (noclobber) makes `: >`
    # refuse an existing target instead of overwriting it; on a collision
    # (either a real pre-existing doc or a losing race) this advances to the
    # next letter rather than failing.
    local letter doc claimed=0
    set -C
    for letter in {A..Z}; do
        doc="$state_dir/${prefix}-nextleg-${date}${letter}-${name}.md"
        if : 2>/dev/null > "$doc"; then
            claimed=1
            break
        fi
    done
    set +C
    [ "$claimed" -eq 1 ] || { err "all 26 letters (A-Z) are taken for today's '$name' console in $state_dir"; exit 1; }
    local session="${prefix}-nextleg-${date}${letter}-${name}"
    local fill_signal="$chain_dir/sig-$session"
    local log="$chain_dir/launch-$session.log"
    render_template "$console_template" "$doc" \
        LETTER "$letter" \
        PREDECESSOR "none — first console of the chain" \
        PREDECESSOR_HANDOFF "none" \
        SESSION_NAME "$session" \
        HANDOVER_ROOT "$root" \
        STATE_DIR "$state_dir" \
        REPO "$repo" \
        PREFIX "$prefix" \
        KIT "$kit" \
        FILL_SIGNAL "$fill_signal" \
        FILL_PERCENT "$fill_percent"

    echo "doc: $doc"
    echo "session: $session"
    echo "kit: $kit"

    # The lock is what makes a console single-writer — starting one without
    # it is exactly the failure the lock exists to prevent. Abort before the
    # launch line and before any arm; the written doc is left in place
    # (harmless — a later `new` bumps the letter).
    if ! HANDOVER_DIR="$root" bash "$repo/scripts/handover/queue-lock.sh" acquire "$doc"; then
        err "WARNING queue-lock acquire failed for $doc — refusing to launch without the lock (doc left in place)"
        exit 1
    fi

    echo "launch: claude --model $model --autocompact auto -n $session \"load $doc and continue\""

    if [ "$ARM" -eq 1 ]; then
        do_arm "$session" "$doc" "$fill_signal" "$log"
    fi
}

# --- next -------------------------------------------------------------

# resolve_predecessor -- print the predecessor doc path, per the precedence
# in the header: --doc, CONSOLE_DOC, today's highest letter, else the
# newest <PREFIX>-nextleg-*-<NAME>.md by name sort.
resolve_predecessor() {
    if [ -n "$DOC_ARG" ]; then
        printf '%s' "$DOC_ARG"
        return 0
    fi
    if [ -n "${CONSOLE_DOC:-}" ]; then
        printf '%s' "$CONSOLE_DOC"
        return 0
    fi
    local l cand
    for l in Z Y X W V U T S R Q P O N M L K J I H G F E D C B A; do
        cand="$state_dir/${prefix}-nextleg-${date}${l}-${name}.md"
        [ -f "$cand" ] && { printf '%s' "$cand"; return 0; }
    done
    # Glob instead of `find -maxdepth` (GNU-only): bash pathname expansion
    # already returns matches in sorted order, so the last one iterated is
    # the same "newest by name" `find | sort | tail -n 1` picked. An
    # unmatched glob expands to the literal pattern (no nullglob here), so
    # each candidate is existence-checked before it can win. The directory
    # and name stay QUOTED and only the wildcard is bare: building the whole
    # pattern into one variable and leaving `$pattern` unquoted word-splits
    # on IFS (a space in the handover root, say) before globbing ever runs.
    local newest="" cand
    for cand in "$state_dir/${prefix}-nextleg-"*"-${name}.md"; do
        [ -f "$cand" ] && newest="$cand"
    done
    [ -n "$newest" ] || return 1
    printf '%s' "$newest"
}

cmd_next() {
    [ -f "$console_template" ] || { err "missing template $console_template"; exit 2; }
    [ -f "$handoff_template" ] || { err "missing template $handoff_template"; exit 2; }

    local predecessor_doc predecessor_base predecessor_stem predecessor_prefix_part predecessor_letter
    predecessor_doc="$(resolve_predecessor)" || { err "no predecessor console doc found under $state_dir for '$name' — pass --doc <path>"; exit 1; }
    predecessor_base="$(basename "$predecessor_doc")"
    predecessor_stem="${predecessor_base%.md}"
    predecessor_prefix_part="${predecessor_stem%-"$name"}"
    if [ "$predecessor_prefix_part" = "$predecessor_stem" ]; then
        err "cannot parse predecessor doc name '$predecessor_base' (expected suffix '-$name.md')"
        exit 1
    fi
    predecessor_letter="${predecessor_prefix_part: -1}"
    case "$predecessor_letter" in
        Z) err "predecessor '$predecessor_base' is already at letter Z — no successor letter available"; exit 1 ;;
        [A-Y]) ;;
        *) err "cannot parse a letter from predecessor doc name '$predecessor_base'"; exit 1 ;;
    esac
    local successor_letter
    successor_letter="$(next_letter "$predecessor_letter")"

    local doc="$state_dir/${prefix}-nextleg-${date}${successor_letter}-${name}.md"
    local session="${prefix}-nextleg-${date}${successor_letter}-${name}"
    # HANDOFF sits beside the predecessor's OWN doc, not in $state_dir — a
    # --doc pointing outside $state_dir (a different bucket, a different
    # root entirely) must still get its HANDOFF written next to it.
    local predecessor_dir predecessor_handoff predecessor_handoff_ref
    predecessor_dir="$(dirname "$predecessor_doc")"
    predecessor_handoff="$predecessor_dir/${predecessor_stem}-HANDOFF.md"
    # The successor doc must be able to actually RESOLVE this reference: a
    # bare basename only works when the HANDOFF sits in the successor's own
    # state_dir (the common case); a cross-bucket --doc needs the absolute
    # path, since the successor would otherwise look for it next to itself
    # and never find it.
    if [ "$predecessor_dir" = "$state_dir" ]; then
        predecessor_handoff_ref="$(basename "$predecessor_handoff")"
    else
        predecessor_handoff_ref="$predecessor_handoff"
    fi
    local fill_signal="$chain_dir/sig-$session"
    local log="$chain_dir/launch-$session.log"

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "would-doc: $doc"
        echo "would-session: $session"
        if [ -f "$predecessor_handoff" ]; then
            echo "would-handoff: $predecessor_handoff (exists — left unchanged)"
        else
            echo "would-handoff: $predecessor_handoff"
        fi
        echo "would-launch: claude --model $model --autocompact auto -n $session \"load $doc and continue\""
        if [ "$ARM" -eq 1 ]; then
            echo "would-armed: name=$session doc=$doc signal=$fill_signal deadline=$deadline_epoch log=$log"
            echo "would-arm-log: $log"
        fi
        return 0
    fi

    # The successor doc is never re-rendered once it exists: unlike the
    # HANDOFF just below (existence-guarded) and `new` (which bumps the
    # letter), a second `next --doc <same predecessor>` would otherwise
    # silently destroy whatever the successor already wrote. Claimed the
    # same atomic-exclusive-create way `new` claims a letter (closes the
    # same check-then-write race), but a collision here is an ERROR, not an
    # advance — `next` computes exactly one successor letter, never a range
    # to retry across.
    mkdir -p "$state_dir"
    set -C
    if ! : 2>/dev/null > "$doc"; then
        set +C
        err "successor doc already exists, refusing to re-render it: $doc"
        exit 1
    fi
    set +C

    render_template "$console_template" "$doc" \
        LETTER "$successor_letter" \
        PREDECESSOR "$predecessor_base" \
        PREDECESSOR_HANDOFF "$predecessor_handoff_ref" \
        SESSION_NAME "$session" \
        HANDOVER_ROOT "$root" \
        STATE_DIR "$state_dir" \
        REPO "$repo" \
        PREFIX "$prefix" \
        KIT "$kit" \
        FILL_SIGNAL "$fill_signal" \
        FILL_PERCENT "$fill_percent"

    echo "doc: $doc"
    echo "session: $session"

    if [ -f "$predecessor_handoff" ]; then
        echo "handoff: $predecessor_handoff (exists — left unchanged)"
    else
        render_template "$handoff_template" "$predecessor_handoff" \
            PREDECESSOR_LETTER "$predecessor_letter" \
            LETTER "$successor_letter" \
            PREDECESSOR "$predecessor_base" \
            SUCCESSOR_DOC "$(basename "$doc")" \
            REPO "$repo" \
            KIT "$kit"
        echo "handoff: $predecessor_handoff"
    fi

    echo "launch: claude --model $model --autocompact auto -n $session \"load $doc and continue\""

    if [ "$ARM" -eq 1 ]; then
        do_arm "$session" "$doc" "$fill_signal" "$log"
    fi
}

case "$CMD" in
    new) cmd_new ;;
    next) cmd_next ;;
esac
