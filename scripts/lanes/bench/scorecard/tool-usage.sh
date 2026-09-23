#!/usr/bin/env bash
# scripts/lanes/bench/scorecard/tool-usage.sh - tool/skill usage, error rates
# and guardrail friction over a transcript window (HIMMEL-3513).
#
# Platform guard: no .ps1 twin, by design, same as every sibling in this dir.
# POSIX bash 3.2+ plus jq and node; the transcripts and skill/command trees it
# reads are the same on every platform.
#
# Usage: tool-usage.sh --since <ISO8601> [--until <ISO8601>]
#            [--memory-traps <path>] [--skill-cwd <path>] [--skill-config-dir <path>]
#
# SCORECARD_PROJECTS_DIR: an explicit one-root transcript scope (default: the
# primary dir plus its worktree siblings, lib/scorecard-lib.sh).
# SCORECARD_MEMORY_DIR: the auto-memory directory to join against and to count
# Read hits under (default: the live memory dir beside this repo's projects
# entry - tests always override this to a fixture directory).
#
# Sections 1-4 and 6 share ONE discovery+parse pass over the transcript
# window (they read the same enriched tool_use/tool_result join), so they
# share a single `coverage:` line rather than repeating an identical one five
# times - a deliberate simplification (CLAUDE.md "surgical changes"), unlike
# extra-metrics.sh's two genuinely-independent metrics which do print two.
# Section 5 (never-used) and section 7 (memory join) draw from different
# inputs (skill-cost.mjs discovery; the traps file) and print their own line.
#
# ponytail: guardrail-friction "hook" denials are every is_error text starting
# `Pre/PostToolUse:` (the himmel hook-wrapper shape) - confirmed against a real
# 7-day run that some hooks (e.g. block-jira-compound-write) never emit the
# `\xe2\x9b\x94` glyph, so the hook name is pulled from right after the
# wrapper's closing `]:` instead of anchoring on the glyph. "classifier"
# denials require one of the two confirmed real Stage-2 wrapper phrases
# (`Stage 2 classifier error:` or `Permission for this action was denied by
# the Claude Code auto mode classifier`), not merely a bracketed tag - a real
# 7-day run showed plenty of unrelated is_error text carrying a bracketed
# Title-Case-ish token with neither phrase (test-runner `[PASS]`/`[FAIL]`,
# `--help` usage `[OPTIONS]`, pre-commit `[WARNING]`, a regex literal
# `[A-Za-z]`) that the old bracket-only heuristic misread as a classifier
# category. The category name itself is still pulled via the same bracket
# regex, now scoped to text already confirmed to be a classifier denial.
set -u

usage() { echo "usage: tool-usage.sh --since <ISO8601> [--until <ISO8601>] [--memory-traps <path>] [--skill-cwd <path>] [--skill-config-dir <path>]" >&2; }

SINCE=""; UNTIL=""
HERE="$(cd "$(dirname "$0")" && pwd)"
MEMORY_TRAPS="$HERE/memory-traps.json"
SKILL_CWD=""
SKILL_CONFIG_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --since) SINCE="${2:?--since needs a value}"; shift 2 ;;
        --until) UNTIL="${2:?--until needs a value}"; shift 2 ;;
        --memory-traps) MEMORY_TRAPS="${2:?--memory-traps needs a value}"; shift 2 ;;
        --skill-cwd) SKILL_CWD="${2:?--skill-cwd needs a value}"; shift 2 ;;
        --skill-config-dir) SKILL_CONFIG_DIR="${2:?--skill-config-dir needs a value}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "tool-usage: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done
[ -n "$SINCE" ] || { usage; exit 2; }

# shellcheck source=lib/scorecard-lib.sh
. "$HERE/lib/scorecard-lib.sh"
sc_roots_check tool-usage || exit 2
RUN=""
trap 'rm -rf "$RUN" "$SC_COV"' EXIT
RUN=$(mktemp -d "${TMPDIR:-/tmp}/tool-usage.XXXXXX") || { echo "tool-usage: mktemp failed" >&2; exit 1; }
sc_cov_init || exit 1

to_epoch() {
    date -d "$1" +%s 2>/dev/null && return 0
    date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$(printf '%s' "$1" | sed 's/\.[0-9]*Z$/Z/')" +%s 2>/dev/null
}
SINCE_EPOCH=$(to_epoch "$SINCE") || { echo "tool-usage: bad --since: $SINCE" >&2; exit 2; }
UNTIL_EPOCH=""
if [ -n "$UNTIL" ]; then
    UNTIL_EPOCH=$(to_epoch "$UNTIL") || { echo "tool-usage: bad --until: $UNTIL" >&2; exit 2; }
fi
UNTIL_EPOCH_ARG="${UNTIL_EPOCH:-9999999999}"

ts_of() { grep -o '"timestamp":"[0-9TZ:.-]*"' "$1" 2>/dev/null | "$2" -1 | cut -d'"' -f4; }

FILES="$RUN/files.txt"
DISC_ERR="$RUN/disc-err.txt"
if ! sc_discover "$FILES" "$DISC_ERR"; then
    echo "tool-usage: transcript discovery failed under the transcript root(s) - refusing to print a partial count:" >&2
    cat "$DISC_ERR" >&2
    exit 1
fi

EVENTS="$RUN/events.ndjson"; : > "$EVENTS"
CMDS="$RUN/slashcmds.ndjson"; : > "$CMDS"
JQ_FAILS="$RUN/jq-fails.txt"; : > "$JQ_FAILS"

# One enrichment pass per file: every tool_use joined with its tool_result
# (is_error/text, null if the tool never completed - e.g. a hook denial
# refused it before a result line existed... in practice himmel hooks still
# emit a tool_result carrying the denial, so null here means genuinely no
# result was ever recorded, not "denied").
while IFS= read -r f; do
    [ -r "$f" ] || { sc_cov unreadable; continue; }
    case "$f" in */subagents/*) sc_cov subagent; continue ;; esac

    first_ts=$(ts_of "$f" head)
    [ -n "$first_ts" ] || { sc_cov no-timestamp; continue; }
    last_ts=$(ts_of "$f" tail)
    first_epoch=$(to_epoch "$first_ts") || { sc_cov bad-timestamp; continue; }
    last_epoch=$(to_epoch "${last_ts:-$first_ts}") || { sc_cov bad-timestamp; continue; }
    [ "$last_epoch" -ge "$SINCE_EPOCH" ] || { sc_cov out-of-window; continue; }
    if [ -n "$UNTIL_EPOCH" ] && [ "$first_epoch" -ge "$UNTIL_EPOCH" ]; then sc_cov out-of-window; continue; fi

    role=$(role_of "$(title_of "$f")")

    uses_f="$RUN/uses.ndjson"; : > "$uses_f"
    results_f="$RUN/results.ndjson"; : > "$results_f"
    cmds_f="$RUN/cmds.ndjson"; : > "$cmds_f"
    events_f="$RUN/events-per-file.ndjson"; : > "$events_f"

    if ! jq -c '. as $m | select(.type=="assistant") | $m.message.content[]? | select(.type=="tool_use") |
        {id: .id, ts: $m.timestamp, tool: .name,
         key: (if .name=="Skill" then (.input.skill // "")
               elif .name=="Bash" then (.input.command // "")
               elif (.name=="Read" or .name=="Edit" or .name=="Write") then (.input.file_path // "")
               else "" end)}' "$f" > "$uses_f" 2>>"$JQ_FAILS"; then
        printf '%s\n' "$f" >> "$JQ_FAILS"; sc_cov jq-failed; continue
    fi
    if ! jq -c 'select(.type=="user") | .message.content[]? | select(.type=="tool_result") |
        {id: .tool_use_id, is_error: (.is_error // false),
         text: (if (.content|type)=="array" then ([.content[]? | .text? // ""] | join(" ")) else (.content // "" | tostring) end)}' \
        "$f" > "$results_f" 2>>"$JQ_FAILS"; then
        printf '%s\n' "$f" >> "$JQ_FAILS"; sc_cov jq-failed; continue
    fi
    if ! jq -c --arg role "$role" --arg file "$f" \
        --argjson since_epoch "$SINCE_EPOCH" --argjson until_epoch "$UNTIL_EPOCH_ARG" \
        '. as $m | select(.type=="user") | select(($m.message.content // "")|type=="string") |
         ($m.message.content) as $c | select($c | test("^<command-name>")) |
         select(($m.timestamp // null) != null and
           (($m.timestamp | sub("\\.[0-9]+Z$";"Z") | fromdateiso8601) >= $since_epoch) and
           (($m.timestamp | sub("\\.[0-9]+Z$";"Z") | fromdateiso8601) < $until_epoch)) |
         {cmd: ($c | capture("<command-name>(?<c>[^<]+)</command-name>").c // ""), ts: $m.timestamp, role: $role, file: $file}' \
        "$f" > "$cmds_f" 2>>"$JQ_FAILS"; then
        printf '%s\n' "$f" >> "$JQ_FAILS"; sc_cov jq-failed; continue
    fi

    if ! jq -n -c --slurpfile uses "$uses_f" --slurpfile results "$results_f" \
        --arg role "$role" --arg file "$f" \
        --argjson since_epoch "$SINCE_EPOCH" --argjson until_epoch "$UNTIL_EPOCH_ARG" '
        ($results | INDEX(.id)) as $ridx
        | $uses[]
        | select(.ts != null)
        | select((.ts | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) >= $since_epoch and (.ts | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) < $until_epoch)
        | . + {is_error: ($ridx[.id].is_error // null), text: ($ridx[.id].text // null), role: $role, file: $file}
    ' > "$events_f" 2>>"$JQ_FAILS"; then
        printf '%s\n' "$f" >> "$JQ_FAILS"; sc_cov jq-failed; continue
    fi
    # cmds_f and events_f are merged into $CMDS/$EVENTS only now - after every
    # extraction pass for this transcript has succeeded - so a later jq
    # failure never leaves a partial row behind for a file this loop
    # otherwise counts as skipped.
    cat "$cmds_f" >> "$CMDS"
    cat "$events_f" >> "$EVENTS"
    sc_cov parsed
done < "$FILES"

n_jq_fail=$(grep -c . "$JQ_FAILS" 2>/dev/null); n_jq_fail=${n_jq_fail:-0}
if [ "$n_jq_fail" -gt 0 ]; then
    echo "tool-usage: WARNING: transcript(s) skipped due to jq failure" >&2
fi

# himmel script / jira-op key extraction, added as a `.script` field. jira
# ops are keyed `jira:<op>` (never bare `<op>`, so a script literally named
# `get` can't collide with the jira `get` op); every other tracked script is
# keyed by its `scripts/...` path substring as it appeared in the command.
SCRIPTED="$RUN/scripted.ndjson"
jq -c '. + {script: (
    if .tool=="Bash" and (.key | test("scripts/jira/dist/index\\.js")) then
        "jira:" + (.key | capture("scripts/jira/dist/index\\.js\\s+(?<op>[A-Za-z0-9_:-]+)") .op // "unknown")
    elif .tool=="Bash" and (.key | test("scripts/[A-Za-z0-9_./-]+\\.(sh|mjs|js|py)")) then
        (.key | capture("(?<m>scripts/[A-Za-z0-9_./-]+\\.(?:sh|mjs|js|py))") | .m)
    else null end
)}' "$EVENTS" > "$SCRIPTED"

# guardrail-friction classification, added as `.friction` {kind, key, sample}.
FRICTION="$RUN/friction.ndjson"
jq -c 'select(.is_error==true and (.text // "")!="") | . + {friction: (
    if (.text | test("^(Pre|Post)ToolUse:")) then
        {kind: "hook", key: (.text | capture("\\]:\\s*(?:⛔\\s*)?(?<h>[A-Za-z0-9_-]+):") .h // "unknown")}
    elif (.text | test("Stage 2 classifier error:|Permission for this action was denied by the Claude Code auto mode classifier")) then
        {kind: "classifier", key: ("[" + (.text | capture("\\[(?<c>[A-Z][A-Za-z /-]{2,40})\\]") .c // "unknown") + "]")}
    else null end
)}' "$EVENTS" > "$FRICTION"

echo "--- 1. skill invocations"
jq -s -r '
    map(select(.tool=="Skill" and .key!=""))
    | group_by(.key)
    | map({key: .[0].key, count: length, sessions: (map(.file)|unique|length)})
    | sort_by(-.count)
    | .[] | "skill=\(.key) count=\(.count) sessions=\(.sessions)"
' "$EVENTS"

echo "--- 2. slash commands"
jq -s -r '
    if length==0 then empty else
    group_by(.cmd)
    | map({key: .[0].cmd, count: length, sessions: (map(.file)|unique|length)})
    | sort_by(-.count)
    | .[] | "slash=\(.key) count=\(.count) sessions=\(.sessions)"
    end
' "$CMDS"

echo "--- 3. himmel script + jira-op calls, with error rate"
jq -s -r '
    map(select(.script != null))
    | group_by(.script)
    | map({key: .[0].script, count: length, sessions: (map(.file)|unique|length),
           errors: (map(select(.is_error==true)) | length)})
    | sort_by(-.count)
    | .[] | "script=\(.key) count=\(.count) sessions=\(.sessions) errors=\(.errors) error_rate=\((if .count>0 then (.errors*1000/.count|round)/10 else 0 end))"
' "$SCRIPTED"

echo "--- 4. guardrail friction (hook denials, classifier denials)"
jq -s -r '
    map(select(.friction!=null and .friction.kind=="hook"))
    | group_by(.friction.key)
    | map({key: .[0].friction.key, count: length, sample: (
        (.[0].text // "" | gsub("\n"; " ")) as $t
        | ($t | index("]:")) as $i
        | (if $i then ($t[($i+2):] | ltrimstr(" ")) else $t end) as $s
        | $s[0:160]
    )})
    | sort_by(-.count)
    | .[] | "hook=\(.key) count=\(.count) sample=\"\(.sample)\""
' "$FRICTION"
jq -s -r '
    map(select(.friction!=null and .friction.kind=="classifier"))
    | group_by(.friction.key)
    | map({key: .[0].friction.key, count: length, sample: (.[0].text // "" | gsub("\n"; " ") | .[0:160])})
    | sort_by(-.count)
    | .[] | "classifier=\(.key) count=\(.count) sample=\"\(.sample)\""
' "$FRICTION"
sc_cov_line "$(wc -l < "$FILES" | tr -d ' ')" "$SC_ROOT_COUNT"

echo "--- 5. never-used skills and commands (skill-cost.mjs discovery)"
SKILL_JSON_ARGS=()
[ -n "$SKILL_CWD" ] && SKILL_JSON_ARGS+=(--cwd "$SKILL_CWD")
[ -n "$SKILL_CONFIG_DIR" ] && SKILL_JSON_ARGS+=(--config-dir "$SKILL_CONFIG_DIR")
node "$HERE/../../skill-cost.mjs" --json "${SKILL_JSON_ARGS[@]}" > "$RUN/skill-cost.json" 2>"$RUN/skill-cost.err" \
    || { echo "tool-usage: skill-cost.mjs discovery failed:" >&2; cat "$RUN/skill-cost.err" >&2; exit 1; }
# ponytail: a transcript's Skill tool_use may name a plugin-qualified skill
# (`plugin:name`) while skill-cost.mjs's discovered `name` is bare, so a used
# skill is matched by taking the suffix after the last `:`. This under-counts
# never-used if two different plugins install same-named skills (both would
# read as used once either is invoked) - accepted because that collision has
# not been observed in this repo's installed skill set.
jq -s -r --slurpfile events "$EVENTS" '
    ($events // []) as $ev
    | ($ev | map(select(.tool=="Skill" and .key!="")) | map(.key | split(":") | .[-1]) | unique) as $used_skills
    | .[0].entries[]
    | select(.scope | test("skills$"))
    | select((.name | IN($used_skills[])) | not)
    | "never-used: scope=\(.scope) name=\(.name)"
' "$RUN/skill-cost.json"
jq -s -r --slurpfile cmds "$CMDS" '
    ($cmds // []) as $c
    | ($c | map(.cmd | ltrimstr("/")) | unique) as $used_cmds
    | .[0].entries[]
    | select(.scope | test("commands$"))
    | select((.name | IN($used_cmds[])) | not)
    | "never-used: scope=\(.scope) name=\(.name)"
' "$RUN/skill-cost.json"

echo "--- 6. per-role split (skill invocations)"
jq -s -r '
    map(select(.tool=="Skill" and .key!=""))
    | group_by([.role, .key])
    | map({role: .[0].role, key: .[0].key, count: length})
    | sort_by(.role, -.count)
    | .[] | "role=\(.role) skill=\(.key) count=\(.count)"
' "$EVENTS"

echo "--- 7. memory-trap join"
TRAP_ROWS=""
if [ -r "$MEMORY_TRAPS" ]; then
    TRAP_ROWS=$(jq -r --slurpfile events "$EVENTS" '
        ($events | map(select(.is_error==true) | .text // "")) as $texts
        | .[]
        | (.pattern // "") as $p
        | if ($p == "") then "trap=\(.id) status=UNMATCHABLE hits=0 source=\(.source)"
          else
            ([$texts[] | select(test($p))] | length) as $hits
            | "trap=\(.id) status=\(if $hits>0 then "RECURRING" else "DORMANT" end) hits=\($hits) source=\(.source)"
          end
    ' "$MEMORY_TRAPS")
    printf '%s\n' "$TRAP_ROWS"
    N_TRAPS=$(printf '%s\n' "$TRAP_ROWS" | grep -c '^trap=')
    N_RECURRING=$(printf '%s\n' "$TRAP_ROWS" | grep -c 'status=RECURRING')
    N_DORMANT=$(printf '%s\n' "$TRAP_ROWS" | grep -c 'status=DORMANT')
    N_UNMATCHABLE=$(printf '%s\n' "$TRAP_ROWS" | grep -c 'status=UNMATCHABLE')
    echo "coverage: traps=$N_TRAPS recurring=$N_RECURRING dormant=$N_DORMANT unmatchable=$N_UNMATCHABLE"
else
    echo "tool-usage: memory-traps file not readable: $MEMORY_TRAPS" >&2
fi

# ponytail: the default MEM_DIR is hardcoded to this repo's own project-hash
# path (not portable to another checkout without --skill-cwd-style overriding
# via SCORECARD_MEMORY_DIR), and the `/memory/` substring test below matches
# any Read path containing that segment, not only this project's memory dir -
# both accepted since every real run on this station sets neither override and
# reads only this repo's own memory files.
MEM_DIR="${SCORECARD_MEMORY_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/-home-overlord-Documents-github-himmel/memory}"
if [ -d "$MEM_DIR" ]; then
    jq -s -r --arg memdir_marker "/memory/" '
        map(select(.tool=="Read" and (.key // "") != "" and (.key | test($memdir_marker))))
        | group_by(.key | split("/") | .[-1])
        | map({name: .[0].key | split("/") | .[-1], count: length, sessions: (map(.file)|unique|length)})
        | sort_by(-.count)
        | .[] | "memory-file-read: \(.name) reads=\(.count) sessions=\(.sessions)"
    ' "$EVENTS"
fi

echo "--- 8. eval-candidates"
# A hook/classifier denial is not itself a defect - it may be correct
# enforcement (e.g. a destructive-command block working as designed), so its
# proposed eval asks whether the denial is right, not that it should go away.
# A script error has no such ambiguity: "expect no error" is the correct ask.
jq -n -r --slurpfile hookfriction "$FRICTION" --slurpfile scripted "$SCRIPTED" '
    ($hookfriction | map(select(.friction!=null)) | group_by(.friction.key) |
      map({defect: .[0].friction.key, evidence: length,
           proposed_eval: "reproduce \(.[0].friction.key)'"'"'s trigger; confirm whether the denial is correct enforcement or a false-positive papercut"})) as $friction_rows
    | ($scripted | map(select(.script!=null and .is_error==true)) | group_by(.script) |
      map({defect: .[0].script, evidence: length,
           proposed_eval: "reproduce \(.[0].script); expect no error"})) as $error_rows
    | ($friction_rows + $error_rows) | sort_by(-.evidence)[]
    | "eval-candidates: defect=\(.defect) evidence_count=\(.evidence) proposed_eval=\"\(.proposed_eval)\" existing_suite=none"
'
if [ -n "$TRAP_ROWS" ]; then
    printf '%s\n' "$TRAP_ROWS" | while IFS= read -r _row; do
        case "$_row" in
            *"status=RECURRING"*)
                _id=$(printf '%s\n' "$_row" | sed -n 's/^trap=\([^ ]*\).*/\1/p')
                _hits=$(printf '%s\n' "$_row" | sed -n 's/.*hits=\([0-9]*\).*/\1/p')
                _src=$(printf '%s\n' "$_row" | sed -n 's/.*source=\(.*\)$/\1/p')
                echo "eval-candidates: defect=$_id evidence_count=$_hits proposed_eval=\"reproduce $_id (source: $_src); expect the harness to surface the same denial/error\" existing_suite=none"
                ;;
        esac
    done
fi
