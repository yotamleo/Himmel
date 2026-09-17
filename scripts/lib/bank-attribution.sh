#!/usr/bin/env bash
# scripts/lib/bank-attribution.sh -- per-session token/turn attribution table
# from Claude Code transcript JSONL (HIMMEL-2764). Read-only: attributes bank
# burn (turns x context size) to named sessions so it can be traced back to a
# leg/console instead of showing up as an unexplained account drain
# (HIMMEL-2750).
#
# Platform guard (gitbash-only): pure bash 3.2-safe + jq, no python/node/
# network; git-bash on Windows carries a working jq, so no .ps1 twin needed.
#
# Usage:
#   bank-attribution.sh <projects-root> [--since <iso>] [--project <slug>] [--top <n>]
#
# <projects-root> is a `~/.claude/projects` directory: one subdirectory per
# project slug, one *.jsonl file per top-level session inside each, plus (when
# the session forked subagents) a `<sessionId>/subagents/*.jsonl` per agent --
# a SEPARATE file, isSidechain:true throughout, sharing the parent's sessionId
# on every row (verified against real transcripts, HIMMEL-2764 CR round 1:
# subagent turns never appear inline in the parent's own top-level file).
# Subagent directories are discovered independently of the top-level
# session file, since a session's own <sid>.jsonl can be pruned/rotated
# while its <sid>/subagents/ tree survives -- confirmed on this station
# (CR round 6, codex-2).
#
# Method (see HIMMEL-2764 handover for the transcript facts this encodes):
#   - Pass 1a (per top-level file, streamed via `jq -n reduce inputs`): walks
#     the JSONL in order tracking the most recent wake-source classification
#     (cross-session / monitor / operator; a slash command counts as
#     operator) from either a `type:"user"` row (a rendered cross-session
#     string, or the older literal `<cross-session-message`/
#     `<task-notification>`/`[SYSTEM NOTIFICATION` prefixes) or a
#     `type:"attachment"` row with `attachment.type == "queued_command"` --
#     a skill body or CLI command-body row inserted as a side effect of a
#     Skill tool_use or slash command does NOT update this classification
#     (HIMMEL-2781) -- title/account/wake state updates from EVERY row
#     regardless of --since, since they only track state for later rows, not
#     counted output -- and accumulates usage per DISTINCT requestId,
#     counting ONLY rows inside the --since window (a streamed turn repeats
#     its usage across several rows sharing one requestId, so it is deduped
#     -- first-seen-WITHIN-THE-WINDOW wins, later dupes are skipped; a
#     duplicate outside the window is simply never considered, so a turn is
#     never double-counted regardless of how its copies straddle the cutoff
#     -- HIMMEL-2764 CR round 4, codex-2: verified against real transcripts
#     that duplicate rows for one requestId always carry identical usage, so
#     which copy is counted is immaterial). The FIRST counted response to
#     each wake-classification change also has its input tokens recorded
#     separately per wake class (`first-resp-input`, HIMMEL-2781 ask 2), so
#     the report can show what one wake actually cost instead of attributing
#     an entire multi-turn episode to it.
#   - Pass 1b (per `<sessionId>/subagents/*.jsonl` file, same dedup rule):
#     accumulates that agent's usage into the PARENT session's subagent
#     totals; never counted toward the parent's own turn total.
#   - Pass 2 (jq -s over the small per-file summaries): groups by sessionId
#     (a session may contribute one 1a summary plus several 1b summaries),
#     sums each group, sorts by input+cache_read descending, renders the
#     Markdown table plus the "attributed N %" line (named = customTitle
#     present). Session names are escaped for Markdown table safety (a
#     custom title carrying `|` or a newline cannot corrupt the table).
#
# A malformed/truncated JSONL file (Claude Code appends live, so a partial
# last line while this tool reads it is realistic) makes `jq -n reduce
# inputs` fail without emitting its summary object -- since that would
# otherwise silently drop the WHOLE file's contribution rather than just the
# bad row, the table still prints for every readable file, but the script
# then exits 2 and reports on stderr how many transcripts were skipped, so a
# caller cannot mistake an incomplete report for a complete one (HIMMEL-2764
# CR, post-CodeRabbit round).
#
# --since is validated up front to a canonical UTC form
# (YYYY-MM-DDTHH:MM:SS[.ffffff][Z], no timezone offset) so a genuinely
# different format fails loudly instead of comparing wrong silently
# (HIMMEL-2764 CR round 2). Both --since and every row timestamp are then
# normalized to a fixed 3-fractional-digit form before the lexicographic
# compare, so a --since value with different fractional precision than the
# transcript rows (e.g. "...:05Z" vs a row at "...:05.500Z") does not
# silently misclassify the boundary (CR round 3).
set -euo pipefail

die() { echo "bank-attribution: $*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required"

PROJECTS_ROOT="${1:-}"
[ -n "$PROJECTS_ROOT" ] || die "usage: bank-attribution.sh <projects-root> [--since <iso>] [--project <slug>] [--top <n>]"
[ -d "$PROJECTS_ROOT" ] || die "not a directory: $PROJECTS_ROOT"
shift

SINCE=""
PROJECT_FILTER=""
TOP=""

while [ $# -gt 0 ]; do
  case "$1" in
    --since)
      SINCE="${2:-}"
      if ! [[ "$SINCE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,3})?Z?$ ]]; then
        die "--since must be a UTC timestamp (YYYY-MM-DDTHH:MM:SS[.fff][Z], at most 3 fractional digits, no timezone offset) -- transcript timestamps carry at most millisecond precision, and the comparison normalizes to that precision: $SINCE"
      fi
      shift 2 ;;
    --project)
      PROJECT_FILTER="${2:-}"
      [ -n "$PROJECT_FILTER" ] || die "--project requires a project slug"
      shift 2 ;;
    --top)
      TOP="${2:-}"
      if ! [[ "$TOP" =~ ^[0-9]+$ ]]; then
        die "--top must be a non-negative integer (a negative value is a jq slice-from-the-end index, not a session count): $TOP"
      fi
      shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/bank-attribution.XXXXXX")"
trap 'rm -rf "$WORKDIR"' EXIT

SUMMARIES="$WORKDIR/summaries.ndjson"
: > "$SUMMARIES"

# --- pass 1a: one summary object per top-level session file, streamed ----
# shellcheck disable=SC2016  # jq's own $vars, expanded by jq via --arg, not bash
PASS1_MAIN_PROGRAM='
def content_text($row):
  ($row.message.content) as $c
  | if ($c|type) == "string" then $c
    elif ($c|type) == "array" and (($c[0]|type) == "object") then (($c[0].text // $c[0].content // ""))
    else "" end;

def is_tool_result($row):
  ($row.toolUseResult != null)
  or (($row.message.content|type) == "array"
      and (($row.message.content[0]|type) == "object")
      and (($row.message.content[0].type // "") == "tool_result"));

def classify($s):
  if ($s | startswith("Another Claude session sent a message:")) or ($s | startswith("<cross-session-message")) then "cs"
  elif ($s | startswith("<task-notification>")) or ($s | startswith("[SYSTEM NOTIFICATION")) or ($s | startswith("[Cross-session idle notice]")) then "mon"
  else null end;

# A skill/slash-command body carrying the CLI own
# `<command-name>`/`<command-message>` wrapper. A genuine operator-typed slash
# command (e.g. /plugin, /exit) produces this exact text prefix with isMeta
# ABSENT and entrypoint:cli -- only an injected command/skill body carries
# isMeta:true on the same prefix (verified against real transcripts,
# HIMMEL-3006). The caller therefore gates this on isMeta:true as well, so a
# bare prefix with isMeta absent falls through to the real-wake op branch
# instead of being swallowed.
def is_command_body($s):
  ($s | startswith("<command-name>")) or ($s | startswith("<command-message>"));

def has_skill_tool_use($row):
  ($row.message.content // []) as $c
  | ($c | type) == "array"
  and ($c | any(.type == "tool_use" and .name == "Skill"));

# A monitor/task wake delivered as an `attachment` row (real shape:
# `type:"attachment"`, `attachment.type:"queued_command"` -- confirmed
# against the Claude Code binary, HIMMEL-2781), not as `type:"user"` text.
def is_queued_command($row):
  ($row.attachment.type // "") == "queued_command";

# Normalizes a UTC timestamp to a fixed 3-fractional-digit form (padding a
# shorter fraction, truncating a longer one) so lexicographic comparison is
# correct even when --since and a transcript row carry different fractional
# precision (HIMMEL-2764 CR round 3: "...:05Z" vs "...:05.500Z" compared
# wrong before this normalization -- the trailing "Z" sorts before ".500").
def norm_ts(s):
  if s == null or s == "" then null
  else
    (s | rtrimstr("Z") | split(".")) as $parts
    | ($parts[0] + "." + ((($parts[1] // "0") + "000000") | .[0:3]))
  end;

def in_window($row):
  ($row.timestamp == null) or ($since == "") or (norm_ts($row.timestamp) >= norm_ts($since));

reduce inputs as $row (
  {wake: "op", afterSkill: false, pendingEvent: false, seen: {}, name: null, aititle: null, named: false, account: null,
   main: {turns: 0, op: 0, cs: 0, mon: 0, input: 0, cache_read: 0, cache_create: 0, output: 0},
   firstResp: {op: 0, cs: 0, mon: 0},
   sub:  {turns: 0, input: 0, cache_read: 0, cache_create: 0, output: 0}};
  if $row.type == "custom-title" then (.name = $row.customTitle | .named = true)
  elif $row.type == "ai-title" then (if .name == null then .aititle = $row.aiTitle else . end)
  elif $row.type == "bridge-session" then .account = $row.ownerAccountUuid
  elif $row.type == "attachment" and is_queued_command($row) then
    (.wake = "mon" | .afterSkill = false | .pendingEvent = true)
  elif $row.type == "user" and ($row.isSidechain != true) and (is_tool_result($row) | not) then
    (content_text($row)) as $txt
    | (classify($txt)) as $c
    | if $c != null then
        (.wake = $c | .afterSkill = false | .pendingEvent = true)
      elif ($row.isMeta == true) and (.afterSkill or is_command_body($txt)) then
        (if is_command_body($txt) then .afterSkill = false else . end)
      else
        (.wake = "op" | .afterSkill = false | .pendingEvent = true)
      end
  elif $row.type == "assistant" then
    (if has_skill_tool_use($row) then .afterSkill = true else . end)
    | if (in_window($row)) and ($row.requestId != null)
         and ((.seen[$row.requestId] // false) | not) then
        (.seen[$row.requestId] = true)
        | ($row.message.usage // {}) as $u
        | if $row.isSidechain == true then
            .sub.turns += 1
            | .sub.input += ($u.input_tokens // 0)
            | .sub.cache_read += ($u.cache_read_input_tokens // 0)
            | .sub.cache_create += ($u.cache_creation_input_tokens // 0)
            | .sub.output += ($u.output_tokens // 0)
          else
            .main.turns += 1
            | .main[.wake] += 1
            | .main.input += ($u.input_tokens // 0)
            | .main.cache_read += ($u.cache_read_input_tokens // 0)
            | .main.cache_create += ($u.cache_creation_input_tokens // 0)
            | .main.output += ($u.output_tokens // 0)
            | if .pendingEvent then
                .firstResp[.wake] += ($u.input_tokens // 0)
                | .pendingEvent = false
              else . end
          end
      else . end
  else . end
)
| {sessionId: $sid, slug: $slug,
   name: (.name // .aititle // null), named: .named,
   account: (if .account then .account[0:8] else null end),
   turns: .main.turns, op: .main.op, cs: .main.cs, mon: .main.mon,
   input: .main.input, cache_read: .main.cache_read,
   cache_create: .main.cache_create, output: .main.output,
   first_resp_op: .firstResp.op, first_resp_cs: .firstResp.cs, first_resp_mon: .firstResp.mon,
   sub_turns: .sub.turns, sub_input: .sub.input, sub_cache_read: .sub.cache_read,
   sub_cache_create: .sub.cache_create, sub_output: .sub.output}
'

# --- pass 1b: one summary object per subagent file, streamed -------------
# shellcheck disable=SC2016  # jq's own $vars, expanded by jq via --arg, not bash
PASS1_SUB_PROGRAM='
def norm_ts(s):
  if s == null or s == "" then null
  else
    (s | rtrimstr("Z") | split(".")) as $parts
    | ($parts[0] + "." + ((($parts[1] // "0") + "000000") | .[0:3]))
  end;

def in_window($row):
  ($row.timestamp == null) or ($since == "") or (norm_ts($row.timestamp) >= norm_ts($since));

reduce inputs as $row (
  {seen: {}, sub: {turns: 0, input: 0, cache_read: 0, cache_create: 0, output: 0}};
  if $row.type == "assistant" and (in_window($row)) and ($row.requestId != null)
     and ((.seen[$row.requestId] // false) | not) then
    (.seen[$row.requestId] = true)
    | ($row.message.usage // {}) as $u
    | .sub.turns += 1
    | .sub.input += ($u.input_tokens // 0)
    | .sub.cache_read += ($u.cache_read_input_tokens // 0)
    | .sub.cache_create += ($u.cache_creation_input_tokens // 0)
    | .sub.output += ($u.output_tokens // 0)
  else . end
)
| {sessionId: $sid, slug: $slug, name: null, named: false, account: null,
   turns: 0, op: 0, cs: 0, mon: 0, input: 0, cache_read: 0, cache_create: 0, output: 0,
   first_resp_op: 0, first_resp_cs: 0, first_resp_mon: 0,
   sub_turns: .sub.turns, sub_input: .sub.input, sub_cache_read: .sub.cache_read,
   sub_cache_create: .sub.cache_create, sub_output: .sub.output}
'

SKIPPED=0
for slug_dir in "$PROJECTS_ROOT"/*/; do
  [ -d "$slug_dir" ] || continue
  slug="$(basename "$slug_dir")"
  if [ -n "$PROJECT_FILTER" ] && [ "$slug" != "$PROJECT_FILTER" ]; then
    continue
  fi
  for f in "$slug_dir"*.jsonl; do
    [ -e "$f" ] || continue
    sid="$(basename "$f" .jsonl)"
    if ! jq -nc --arg sid "$sid" --arg slug "$slug" --arg since "$SINCE" \
         "$PASS1_MAIN_PROGRAM" "$f" >> "$SUMMARIES"; then
      echo "bank-attribution: skipped unreadable transcript (its whole contribution is dropped, not just the bad row): $f" >&2
      SKIPPED=$((SKIPPED + 1))
    fi
  done
  # Subagent directories are discovered independently of the top-level
  # session file (HIMMEL-2764 CR round 6, codex-2): a session whose own
  # <sid>.jsonl was pruned/rotated but whose <sid>/subagents/ tree survives
  # would otherwise have its subagent tokens silently omitted.
  for sub_dir in "$slug_dir"*/subagents; do
    [ -d "$sub_dir" ] || continue
    sid="$(basename "$(dirname "$sub_dir")")"
    for sf in "$sub_dir"/*.jsonl; do
      [ -e "$sf" ] || continue
      if ! jq -nc --arg sid "$sid" --arg slug "$slug" --arg since "$SINCE" \
           "$PASS1_SUB_PROGRAM" "$sf" >> "$SUMMARIES"; then
        echo "bank-attribution: skipped unreadable subagent transcript (its whole contribution is dropped, not just the bad row): $sf" >&2
        SKIPPED=$((SKIPPED + 1))
      fi
    done
  done
done

# --- pass 2: group by session, aggregate, render --------------------------
# shellcheck disable=SC2016  # jq's own $vars, expanded by jq via --arg, not bash
PASS2_PROGRAM='
def md_safe(s): (s | gsub("\\|"; "\\|") | gsub("\r\n|\n|\r"; " "));

def tot(r): (r.input + r.cache_read + r.cache_create + r.output
             + r.sub_input + r.sub_cache_read + r.sub_cache_create + r.sub_output);

def merge(a; b):
  { sessionId: a.sessionId, slug: a.slug,
    name: (a.name // b.name), named: (a.named or b.named),
    account: (a.account // b.account),
    turns: (a.turns + b.turns), op: (a.op + b.op), cs: (a.cs + b.cs), mon: (a.mon + b.mon),
    input: (a.input + b.input), cache_read: (a.cache_read + b.cache_read),
    cache_create: (a.cache_create + b.cache_create), output: (a.output + b.output),
    first_resp_op: (a.first_resp_op + b.first_resp_op),
    first_resp_cs: (a.first_resp_cs + b.first_resp_cs),
    first_resp_mon: (a.first_resp_mon + b.first_resp_mon),
    sub_turns: (a.sub_turns + b.sub_turns), sub_input: (a.sub_input + b.sub_input),
    sub_cache_read: (a.sub_cache_read + b.sub_cache_read),
    sub_cache_create: (a.sub_cache_create + b.sub_cache_create),
    sub_output: (a.sub_output + b.sub_output) };

. as $rows
| (group_by(.sessionId) | map(reduce .[] as $r (.[0] | .turns=0|.op=0|.cs=0|.mon=0|.input=0|.cache_read=0|.cache_create=0|.output=0|.first_resp_op=0|.first_resp_cs=0|.first_resp_mon=0|.sub_turns=0|.sub_input=0|.sub_cache_read=0|.sub_cache_create=0|.sub_output=0|.name=null|.named=false|.account=null; merge(.; $r)))) as $sessions
| ($sessions | map(select(.turns > 0 or .sub_turns > 0)
    | .name = (.name // (.sessionId[0:8])))) as $active
| ($active | sort_by(-(.input + .cache_read))) as $sorted
| (if $top == "" then $sorted else $sorted[0:($top|tonumber)] end) as $shown
| ($active | map(tot(.)) | add // 0) as $grand
| ($active | map(select(.named) | tot(.)) | add // 0) as $attributed
| ($active | map(.input) | add // 0) as $tin
| ($active | map(.cache_read) | add // 0) as $tcr
| ($active | map(.cache_create) | add // 0) as $tcc
| ($active | map(.output) | add // 0) as $tout
| ($active | map(.turns) | add // 0) as $tturns
| ($active | map(.sub_turns) | add // 0) as $tsub
| ($active | map(.sub_input) | add // 0) as $tsin
| ($active | map(.sub_cache_read) | add // 0) as $tscr
| ($active | map(.sub_cache_create) | add // 0) as $tscc
| ($active | map(.sub_output) | add // 0) as $tsout
| ($active | map(.first_resp_op) | add // 0) as $tfr_op
| ($active | map(.first_resp_cs) | add // 0) as $tfr_cs
| ($active | map(.first_resp_mon) | add // 0) as $tfr_mon
| (
    "| session | slug | account | turns | input | cache_read | cache_create | output | wake (op/cs/mon) | subagent turns | first-resp-input (op/cs/mon) |",
    "|---|---|---|---|---|---|---|---|---|---|---|",
    ($shown[] | (
        (if .turns > 0 then
          "| \(md_safe(.name)) | \(md_safe(.slug)) | \(.account // "n/a") | \(.turns) | \(.input) | \(.cache_read) | \(.cache_create) | \(.output) | \(.op)/\(.cs)/\(.mon) | \(.sub_turns) | \(.first_resp_op)/\(.first_resp_cs)/\(.first_resp_mon) |"
        else empty end),
        (if .sub_turns > 0 then
          "| \(md_safe(.name)) (subagents) | \(md_safe(.slug)) | \(.account // "n/a") | \(.sub_turns) | \(.sub_input) | \(.sub_cache_read) | \(.sub_cache_create) | \(.sub_output) | - | - | - |"
        else empty end)
      )),
    "| **total** | | | \($tturns) | \($tin) | \($tcr) | \($tcc) | \($tout) | | \($tsub) | \($tfr_op)/\($tfr_cs)/\($tfr_mon) |",
    "| **total (subagents)** | | | \($tsub) | \($tsin) | \($tscr) | \($tscc) | \($tsout) | | | - |",
    "",
    "attributed \(if $grand == 0 then 0 else (($attributed * 10000 / $grand) | round / 100) end) % of tokens to named sessions (main + subagent tokens combined)"
  )
'

jq -s --arg top "$TOP" -r "$PASS2_PROGRAM" "$SUMMARIES"

if [ "$SKIPPED" -gt 0 ]; then
  echo "attributed totals are INCOMPLETE: $SKIPPED unreadable transcript(s) skipped (see stderr above for paths)" >&2
  exit 2
fi
