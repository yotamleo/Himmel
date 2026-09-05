#!/usr/bin/env bash
# Per-session tool-call / error / denial census from Claude Code transcripts
# (HIMMEL-1462, the MVP slice of the Jarvis tool-call observability epic).
#
# Pure reader over `~/.claude/projects/<slug>/<session-id>.jsonl`. It never
# writes a transcript, never starts a probe, never talks to a network: the
# only thing it produces is one JSON line per session appended to
# `~/.himmel/tool-call-census.jsonl`, which the flow exporter reads passively.
#
# Transcript shape this relies on (verified against live transcripts,
# 2026-08-20):
#   - assistant records carry `message.content[]` blocks of `type:"tool_use"`
#     with `.name` (MCP tools arrive pre-namespaced, e.g. `mcp__qmd__query`)
#     and `.id`.
#   - user records carry `message.content[]` blocks of `type:"tool_result"`
#     with `.tool_use_id` and `.is_error`; `.content` is either a string or an
#     array of `{type:"text",text}` blocks.
#   - a PreToolUse hook denial arrives as one of those error results, its text
#     starting `PreToolUse:<Tool> hook error: [<hook cmd>]: <hook-name>: ...`.
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: tool-call-census.sh [options]

  --since <dur>        only scan transcripts modified within <dur> (default 24h).
                       Accepts Ns / Nm / Nh / Nd, or a bare number of seconds.
  --project <slug>     restrict to one project slug (the ~/.claude/projects
                       directory name), instead of every project.
  --projects-dir <dir> transcript root (default $CLAUDE_PROJECTS_DIR or
                       ~/.claude/projects).
  --out <file>         census file (default $HIMMEL_TOOL_CENSUS or
                       ~/.himmel/tool-call-census.jsonl).
  --stdout             print the rows instead of merging them into --out.
  -h, --help           this text.

Rows are keyed by session_id: a re-run replaces a session's previous row in
place rather than appending a duplicate, so the census stays correct for a
session that was still growing when it was last scanned.
USAGE
}

SINCE="24h"
PROJECT=""
PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
OUT="${HIMMEL_TOOL_CENSUS:-$HOME/.himmel/tool-call-census.jsonl}"
TO_STDOUT=0

require_value() {
    if [ $# -lt 2 ] || [ -z "$2" ]; then
        printf 'ERR tool-call-census: %s requires a value\n' "$1" >&2
        exit 2
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --since) require_value "$@"; SINCE="$2"; shift 2 ;;
        --project) require_value "$@"; PROJECT="$2"; shift 2 ;;
        --projects-dir) require_value "$@"; PROJECTS_DIR="$2"; shift 2 ;;
        --out) require_value "$@"; OUT="$2"; shift 2 ;;
        --stdout) TO_STDOUT=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'ERR tool-call-census: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

command -v jq >/dev/null 2>&1 || { echo "ERR tool-call-census: jq is required" >&2; exit 2; }

# Retention for the census file itself, deliberately wider than the 24h the
# exporter folds so a longer window stays available without a data migration.
RETAIN_DAYS="${HIMMEL_TOOL_CENSUS_RETAIN_DAYS:-14}"
case "$RETAIN_DAYS" in
    ''|*[!0-9]*|0) printf 'ERR tool-call-census: HIMMEL_TOOL_CENSUS_RETAIN_DAYS must be a positive integer: %s\n' "$RETAIN_DAYS" >&2; exit 2 ;;
esac
RETAIN_DAYS=$((10#$RETAIN_DAYS))

PROJECTS_DIR="${PROJECTS_DIR%/}"

# duration -> seconds. Rejects anything that is not <digits>[smhd].
parse_duration() {
    local raw="$1" num unit
    case "$raw" in
        *[!0-9smhd]*|"") return 1 ;;
        *[smhd]) num="${raw%?}"; unit="${raw#"$num"}" ;;
        *) num="$raw"; unit="s" ;;
    esac
    case "$num" in ""|*[!0-9]*) return 1 ;; esac
    # 10# forces base 10: bare `08`/`09` are invalid octal to $(( )), which
    # would abort the script instead of accepting a legal duration.
    num=$((10#$num))
    case "$unit" in
        s) echo "$num" ;;
        m) echo $((num * 60)) ;;
        h) echo $((num * 3600)) ;;
        d) echo $((num * 86400)) ;;
        *) return 1 ;;
    esac
}

SINCE_SECONDS=$(parse_duration "$SINCE") || {
    printf 'ERR tool-call-census: bad --since value: %s\n' "$SINCE" >&2
    exit 2
}

if [ ! -d "$PROJECTS_DIR" ]; then
    printf 'ERR tool-call-census: transcript root not found: %s\n' "$PROJECTS_DIR" >&2
    exit 2
fi

# find(1) is the portable filter here: `-mmin` is in both GNU and BSD find,
# while `-newermt "@<epoch>"` is a GNU-only date spec that macOS find rejects.
# Minute granularity is plenty for a window measured in hours; a sub-minute
# --since still scans at least the last minute.
SINCE_MINUTES=$(( (SINCE_SECONDS + 59) / 60 ))
[ "$SINCE_MINUTES" -ge 1 ] || SINCE_MINUTES=1

SCAN_ROOT="$PROJECTS_DIR"
if [ -n "$PROJECT" ]; then
    SCAN_ROOT="$PROJECTS_DIR/$PROJECT"
    if [ ! -d "$SCAN_ROOT" ]; then
        printf 'ERR tool-call-census: no such project slug: %s\n' "$PROJECT" >&2
        exit 2
    fi
fi

TMP_DIR=$(mktemp -d)
LOCK=""
# shellcheck disable=SC2329,SC2317
cleanup() {
    rm -rf "$TMP_DIR" 2>/dev/null || true
    if [ -n "$LOCK" ]; then rmdir "$LOCK" 2>/dev/null || true; fi
}
trap cleanup EXIT

# One reduce over the transcript's top-level records. `jq -n` + `inputs`
# streams them one at a time, so a multi-hundred-megabyte transcript does not
# have to be slurped into memory.
#
# ponytail: the denial classifier is a first-line prefix/keyword match, not a
# hook registry. It resolves the four shapes that actually occur (PreToolUse
# hook error, auto-mode classifier, operator rejection, and a hook whose deny
# reason leads with its own `name:` token) and files anything else it cannot
# name under `hook-unclassified` rather than guessing. The bare-token branch
# requires a HYPHENATED token — every himmel hook name is hyphenated, while
# the ordinary-failure prefixes that would otherwise collide (`error:`,
# `conflict:`, `warning:`) are single words — so a plain tool failure stays an
# error and never becomes a denial class. A hook that denies with free prose
# and no leading token is likewise counted as an error but not as a denial;
# upgrade path is emitting the hook name from the hook itself (a
# `himmel-deny: <hook>` prefix convention) rather than growing regexes here.
# shellcheck disable=SC2016  # jq program: $session/$project are jq --arg names.
JQ_PROGRAM='
def content_of($r):
  ($r.message? // null) | if type == "object" then (.content // null) else null end;

def result_text:
  if (.content | type) == "string" then .content
  elif (.content | type) == "array" then
    ([.content[] | if (type == "object" and (.text | type) == "string") then .text else "" end] | join("\n"))
  else "" end;

def token($re; $s): (try ($s | capture($re) | .n) catch null);

def deny_class($text):
  ($text | split("\n")[0]) as $l1
  | if ($l1 | test("^PreToolUse:[A-Za-z0-9_-]+ hook error:")) then
      (token(".*\\]:\\s*[^A-Za-z0-9]*(?<n>[a-z][a-z0-9-]{2,})"; $l1) // "hook-unclassified")
    elif ($l1 | test("denied by the Claude Code auto mode classifier")) then
      "auto-mode-classifier"
    elif ($l1 | test("^The user doesn.t want to proceed with this tool use")) then
      "user-rejected"
    elif (($l1 | test("^[^A-Za-z0-9]*[a-z][a-z0-9]*(-[a-z0-9]+)+:")) and ($text | test("refus|[Dd]enied|DENIED|[Bb]locked"))) then
      token("^[^A-Za-z0-9]*(?<n>[a-z][a-z0-9]*(?:-[a-z0-9]+)+)"; $l1)
    else null end;

reduce inputs as $r (
  {names: {}, calls: {}, errors: {}, denials: {}, first: null, last: null};
  (if ($r.timestamp | type) == "string" then
     .first = (if (.first == null or $r.timestamp < .first) then $r.timestamp else .first end)
     | .last = (if (.last == null or $r.timestamp > .last) then $r.timestamp else .last end)
   else . end)
  | (content_of($r)) as $c
  | if ($c | type) != "array" then .
    elif $r.type == "assistant" then
      reduce ($c[] | select((.type == "tool_use") and ((.name | type) == "string"))) as $t (.;
        .calls[$t.name] = ((.calls[$t.name] // 0) + 1)
        | (if ($t.id | type) == "string" then .names[$t.id] = $t.name else . end))
    elif $r.type == "user" then
      reduce ($c[] | select((.type == "tool_result") and (.is_error == true))) as $t (.;
        ((.names[$t.tool_use_id? // ""] // "unknown") as $name
         | ($t | result_text) as $text
         | .errors[$name] = ((.errors[$name] // 0) + 1)
         | (deny_class($text)) as $cls
         | if $cls == null then . else .denials[$cls] = ((.denials[$cls] // 0) + 1) end))
    else . end
)
| . as $s
| ((($s.calls | keys) + ($s.errors | keys)) | unique) as $tools
| {
    session_id: $session,
    project: $project,
    started_at: $s.first,
    ended_at: $s.last,
    tool_calls: ($tools | map({key: ., value: {calls: ($s.calls[.] // 0), errors: ($s.errors[.] // 0)}}) | from_entries),
    total_calls: ([$s.calls[]] | add // 0),
    total_errors: ([$s.errors[]] | add // 0),
    denials: $s.denials
  }
| select(.total_calls > 0)
# Retention applies to freshly scanned rows too, not only to the ones carried
# forward: a transcript can have a recent mtime (resumed, touched, copied) and
# a last activity timestamp well outside the window, and such a row would
# otherwise enter the census below the retention floor and never leave. A row
# with no usable `ended_at` is dropped for the same reason — the exporter
# windows on it, so it could never be folded anyway.
| select(((.ended_at // "") | sub("\\.[0-9]+Z$"; "Z") | (try fromdateiso8601 catch 0)) >= (now - ($retain_days * 86400)))
'

ROWS="$TMP_DIR/rows.jsonl"
: > "$ROWS"
SCANNED=0

find "$SCAN_ROOT" -name '*.jsonl' -mmin "-$SINCE_MINUTES" -print > "$TMP_DIR/files" 2>/dev/null || {
    echo "ERR tool-call-census: transcript discovery failed" >&2
    exit 2
}

while IFS= read -r file; do
    [ -n "$file" ] || continue
    session=$(basename "$file" .jsonl)
    # The project slug is the FIRST component under the transcript root, not
    # the transcript's immediate parent: newer Claude Code writes subagent
    # transcripts to `<slug>/<session-id>/subagents/agent-*.jsonl`, and a
    # `dirname` would file all of those under a phantom `subagents` project.
    # Their tool calls belong to the project that spawned them.
    rel="${file#"$PROJECTS_DIR"/}"
    slug="${rel%%/*}"
    if [ "$rel" = "$file" ] || [ -z "$slug" ] || [ "$slug" = "$rel" ]; then
        slug=$(basename "$(dirname "$file")")
    fi
    if jq -c -n --arg session "$session" --arg project "$slug" --argjson retain_days "$RETAIN_DAYS" "$JQ_PROGRAM" "$file" >> "$ROWS" 2>/dev/null; then
        SCANNED=$((SCANNED + 1))
    else
        # A truncated or half-written transcript must not fail the whole pass.
        printf 'WARN tool-call-census: unparseable transcript skipped: %s\n' "$file" >&2
    fi
done < "$TMP_DIR/files"

EMITTED=$(wc -l < "$ROWS" | tr -d ' ')

if [ "$TO_STDOUT" = "1" ]; then
    cat "$ROWS"
    printf 'ok tool-call-census: %s transcripts scanned, %s rows\n' "$SCANNED" "$EMITTED" >&2
    exit 0
fi

mkdir -p "$(dirname "$OUT")"

# The merge below is a read-modify-write of a shared file: two overlapping runs
# would each read the same old census and the second `mv` would drop the first
# one's rows. `mkdir` is the atomic claim (no flock on macOS, no lockfile(1)
# everywhere). ponytail: a run hard-killed past its EXIT trap leaves the dir
# behind and the next run refuses until it is removed by hand — acceptable for
# a lean-invoke extractor; if this ever gets a cadence, stamp the pid in the
# dir and let a later run reclaim a dead owner's lock.
LOCK="$OUT.lock"
lock_tries=0
until mkdir "$LOCK" 2>/dev/null; do
    lock_tries=$((lock_tries + 1))
    if [ "$lock_tries" -ge 50 ]; then
        LOCK=""   # not ours — the EXIT trap must not remove it
        printf 'ERR tool-call-census: another census run holds %s\n' "$OUT.lock" >&2
        exit 2
    fi
    sleep 0.2
done

MERGED="$TMP_DIR/merged.jsonl"
if [ -s "$OUT" ]; then
    # Drop the previous row for every session in this pass, then append the
    # fresh ones: dedup AND refresh of a session that grew. Rows are keyed by
    # project AND session id — a session basename is unique in practice (a
    # UUID, or `agent-<hex>`), but the composite key costs nothing and one
    # project's row can then never evict another's.
    #
    # Raw-line mode (-R + fromjson?) so ONE half-written row is dropped on its
    # own instead of aborting the merge and taking every other project's
    # history with it.
    #
    # The same pass prunes rows older than the retention window. The exporter
    # only folds a trailing 24h, so without this the file would grow forever
    # and every 60s scrape would re-parse the whole accumulated history. The
    # window is kept well wider than the exporter's so a longer fold stays
    # possible without a data migration. Date arithmetic lives in jq (`now`)
    # because `date -d` is GNU-only.
    jq -c -R -n --argjson retain_days "$RETAIN_DAYS" --slurpfile fresh "$ROWS" '
      def rowkey: ((.project // "") + "\u0000" + (.session_id // ""));
      ($fresh | INDEX(rowkey)) as $ids
      | (now - ($retain_days * 86400)) as $floor
      | inputs
      | (fromjson? // empty)
      | select(type == "object")
      | select(($ids[rowkey] // null) == null)
      | select(((.ended_at // "") | sub("\\.[0-9]+Z$"; "Z") | (try fromdateiso8601 catch 0)) >= $floor)
    ' "$OUT" > "$MERGED" 2>/dev/null || {
        printf 'WARN tool-call-census: existing census unreadable, rebuilding from this pass: %s\n' "$OUT" >&2
        : > "$MERGED"
    }
else
    : > "$MERGED"
fi
cat "$ROWS" >> "$MERGED"
mv "$MERGED" "$OUT"

printf 'ok tool-call-census: %s transcripts scanned, %s rows -> %s\n' "$SCANNED" "$EMITTED" "$OUT"
