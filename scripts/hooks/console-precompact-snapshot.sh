#!/usr/bin/env bash
# console-precompact-snapshot.sh — PreCompact hook: snapshot a CONSOLE's
# authority-bearing state to disk at the moment of compaction (HIMMEL-2973 S3),
# so scripts/handover/console-kit/compacted-check.sh (G11) can prove the
# console's post-compaction COMPACTED bullet matches what it held before.
#
# Sibling of console-compact-reinject.sh (SessionStart:compact, S1): that hook
# restores the state INTO the transcript after compaction; this one records
# what the state WAS at compaction time, out of band, so the restoration can be
# audited rather than trusted.
#
# PreCompact contract (Claude Code hooks reference, `PreCompact`): matchers
# `manual` and `auto` (it fires for automatic compaction too); stdin carries the
# common fields (`session_id`, `transcript_path`, `cwd`, `hook_event_name`, ...)
# and a `trigger` field. This hook needs NONE of them to do its job: it reads the
# console doc named by HIMMEL_CONSOLE_DOC, and only records `trigger` when present.
#
# WRITES <HIMMEL_CONSOLE_WORKDIR>/precompact-<n>.snap, n = highest existing + 1:
#   sha256=<hex of everything after this line>
#   lock=<queue-lock owner token>       (read from <root>/.locks/queue/, never written)
#   legs= / queue= / last-go= / acked=  (the doc's `## Live state` lines, backticks stripped)
#   go-file=<pr>.<sha7>                 (newest file in <root>/.locks/go/)
#   trigger=<manual|auto>               (from stdin when present)
#   [--- tick]                          (verbatim <workdir>/last-tick.txt, when present)
# A snap is IMMUTABLE: written to a temp name and hard-linked into place, so an
# existing precompact-<n>.snap is never overwritten and a torn write is never
# visible under the final name.
#
# SILENT NO-OP for every non-console session (HIMMEL_CONSOLE_DOC unset, or the
# doc/workdir unusable): exit 0, no output, no file. This fires on every
# compaction fleet-wide. Console launch paths export HIMMEL_CONSOLE_DOC and
# HIMMEL_CONSOLE_WORKDIR (headed-arm.sh, arm-resume.sh); a console launched by a
# hand-pasted line has neither and is simply not snapshotted, which the checker
# then reports as `no snapshot` (rc 2), never as a false pass.
#
# EXIT 0 ALWAYS — a PreCompact failure must never block a compaction (workflow
# nudge, not a security fence, scripts/hooks/CLAUDE.md). No bypass env var:
# nothing is ever refused, so there is nothing to bypass. Deliberately no `set -u`
# / `set -e`: an unbound variable or a failed command in here must degrade to "no
# snapshot", never to a non-zero exit.
#
# The snap holds RETASK nonces and lock tokens, so the workdir is created 0700,
# must be owned by the caller and must not be a symlink (same posture as
# console.sh's HIMMEL-2881 work-dir checks).
#
# ponytail: `## Live state` is read with a plain ``` fence toggle and single-line
# `key: value` lines; it does not replicate console-compact-reinject.sh's
# marker-matched fence tracking or unterminated-fence fallback, and a value that
# wraps onto a second line is truncated to its first line. The template writes one
# line per key, and G11 would report the resulting mismatch as LOSS, not hide it.
# ponytail: `tick.sh` does not persist its output today, so the `--- tick` tail is
# only populated when something writes <workdir>/last-tick.txt; nothing does yet.
#
# Platform guard (gitbash-only): POSIX bash 3.2+, no .ps1 twin (the checker and
# the launch-path exports are the only consumers, all bash).
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

sha_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
    else shasum -a 256 | cut -d' ' -f1; fi
}

trim() { local t="$1"; t="${t#"${t%%[![:space:]]*}"}"; t="${t%"${t##*[![:space:]]}"}"; printf '%s' "$t"; }

# live_field <key> -- value of the first `<key>: ...` line inside `## Live state`
# (up to the next heading of level >= 2), backticks stripped, trimmed.
live_field() {
    local raw
    raw="$(awk -v k="$1" '
        $0 == "## Live state" { f = 1; next }
        !f { next }
        /^[[:space:]]*```/ { infence = !infence; next }
        infence { next }
        /^##+ / { exit }
        index($0, k ": ") == 1 { print substr($0, length(k) + 3); exit }
        $0 == k ":" { print ""; exit }
    ' "$DOC" 2>/dev/null)"
    trim "$(printf '%s' "$raw" | tr -d '`')"
}

main() {
    local DOC="${HIMMEL_CONSOLE_DOC:-}" WORK="${HIMMEL_CONSOLE_WORKDIR:-}"
    [ -n "$DOC" ] && [ -f "$DOC" ] || return 0
    [ -n "$WORK" ] || return 0

    local IN="" trigger=""
    [ -t 0 ] || IN="$(cat 2>/dev/null)"
    trigger="$(printf '%s' "$IN" | sed -n 's/.*"trigger"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' | head -n 1)"

    # Work dir: never a symlink, created 0700, owned by us.
    [ -L "$WORK" ] && return 0
    if [ ! -d "$WORK" ]; then
        ( umask 077; mkdir -p "$WORK" ) 2>/dev/null || return 0
    fi
    [ -d "$WORK" ] && [ ! -L "$WORK" ] && [ -O "$WORK" ] && [ -w "$WORK" ] || return 0

    # Locate the queue lock + GO dir. Same candidate roots queue-lock.sh
    # searches on a cross-root release (HANDOVER_DIR, then every registered
    # repo's handovers/), because a console is often launched with no exported
    # HANDOVER_DIR.
    local lock="" root="" lockroot="" gofile="" primary="" candidates="" slug="" owner="" r
    # shellcheck source=scripts/lib/handover-path.sh
    . "$REPO/scripts/lib/handover-path.sh" 2>/dev/null
    # shellcheck source=scripts/handover/queue-lock.sh
    . "$REPO/scripts/handover/queue-lock.sh" 2>/dev/null
    primary="$(handover_root 2>/dev/null)" || primary=""
    candidates="$primary
$(_ql_candidate_roots 2>/dev/null)"
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        slug="$(_ql_slug_for_root "$DOC" "$r" 2>/dev/null)"
        owner="$r/.locks/queue/$slug.lock/owner.json"
        if [ -n "$slug" ] && [ -f "$owner" ]; then
            lock="$(_ql_json_field "$owner" session 2>/dev/null)"
            lockroot="$r"
            break
        fi
    done <<EOF
$candidates
EOF
    root="${lockroot:-$primary}"
    if [ -n "$root" ] && [ -d "$root/.locks/go" ]; then
        local newest pr sha
        # shellcheck disable=SC2012  # GO filenames are <pr>.<sha>, always [0-9a-f.]
        newest="$(ls -t "$root/.locks/go" 2>/dev/null | head -n 1)"
        if [ -n "$newest" ]; then
            pr="${newest%%.*}"; sha="${newest#*.}"
            gofile="$pr.${sha:0:7}"
        fi
    fi

    local body
    body="lock=$lock
legs=$(live_field legs)
queue=$(live_field queue)
last-go=$(live_field 'last GO')
go-file=$gofile
acked=$(live_field acked)
trigger=$trigger"
    if [ -f "$WORK/last-tick.txt" ]; then
        body="$body
--- tick
$(cat "$WORK/last-tick.txt" 2>/dev/null)"
    fi

    # n = highest existing + 1 (numeric); publish by hard link so an existing
    # snap is never clobbered. Retry a few times against a concurrent fire.
    local tmp attempt=0 f n best=0
    tmp="$WORK/.precompact.$$.tmp"
    ( umask 077; { printf 'sha256=%s\n' "$(printf '%s\n' "$body" | sha_of)"; printf '%s\n' "$body"; } > "$tmp" ) 2>/dev/null || { rm -f "$tmp"; return 0; }
    while [ "$attempt" -lt 5 ]; do
        best=0
        for f in "$WORK"/precompact-*.snap; do
            [ -f "$f" ] || continue
            n="${f##*/precompact-}"; n="${n%.snap}"
            case "$n" in ''|*[!0123456789]*) continue ;; esac
            [ "$((10#$n))" -gt "$best" ] && best="$((10#$n))"
        done
        if ln "$tmp" "$WORK/precompact-$((best + 1)).snap" 2>/dev/null; then
            break
        fi
        attempt=$((attempt + 1))
    done
    rm -f "$tmp"
    return 0
}

main
exit 0
