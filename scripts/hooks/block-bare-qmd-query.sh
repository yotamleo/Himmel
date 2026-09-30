#!/usr/bin/env bash
# PreToolUse hook for Bash.
#
# HIMMEL-3956 / HIMMEL-3960: an agent's bare `qmd query|search|vsearch` in Bash
# can orphan a GPU-bound bun process for hours. The qmd launcher is a node
# trampoline that forwards no signals, so whatever kills it — the Bash tool's
# own timeout, a `timeout 60` prefix, the session ending — leaves the bun child
# running, reparented to init. Five such orphans ran at ~99 % CPU and up to
# 4.4 GB of VRAM for ~15 h. The himmel scripts route qmd through
# scripts/lib/qmd-bounded.sh, which kills the whole process group; this guard
# sends ad-hoc agent calls there too.
#
# REFUSED: the search verbs (`query`, `search`, `vsearch` — the ones that load
# models) when qmd is the invoked program, reached directly or through the
# launcher chain (`bun …/qmd.ts`, `node …/bin/qmd`, `bunx @tobilu/qmd`), behind
# any of the wrappers below. `timeout`, `nice`, `env` and the like are wrappers,
# NOT bounds: plain timeout(1) is exactly what fails to reap bun.
# ALLOWED: every other qmd verb (`status`, `update`, `embed`, `collection`,
# `get`, …); `bash …/qmd-bounded.sh <verb> …`, whose program is the wrapper
# script; a `qmd_bounded <secs> qmd query …` call inside a sourced script, where
# qmd is an argument and not the program; and a mere mention (`grep "qmd
# query"`, `echo qmd query`).
#
# The grammar is block-git-stash.sh's command-position shape (HIMMEL-851), with
# a wider wrapper set because the wrapper is the evasion here. It is a regex,
# not a shell parser, with the siblings' residuals in both directions: a
# separator inside quoted data (`git commit -m "a; qmd query b"`) reads as a
# command boundary and is a false DENY — the safe direction — and variable
# indirection (`q=qmd; $q query`) is a miss.
#
# ponytail: Bash only — a PowerShell `qmd query` is unguarded; wire a
# PowerShell twin if a Windows station starts running qmd ad hoc (HIMMEL-3960).
#
# Hook input arrives on stdin as JSON. Exit codes:
#   0 - allow
#   2 - block; stderr is shown to the model/user
#
# Bypass: set QMD_UNBOUNDED_OK=1 in the shell that launched the agent.
# Session-sticky; restart without it to re-enable the guard.
set -euo pipefail

# Security hook: any unexpected top-level failure must deny, not fail open as a
# plain rc=1 hook error.
# shellcheck disable=SC2154 # rc is assigned inside the trap string.
trap 'rc=$?; if [ "$rc" != 0 ] && [ "$rc" != 2 ]; then exit 2; fi' EXIT

if [ "${QMD_UNBOUNDED_OK:-0}" = "1" ]; then
    exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "block-bare-qmd-query: jq not on PATH - refusing to evaluate; install jq" >&2
    exit 2
fi

# Input handling is block-git-stash.sh's (HIMMEL-2123): builtin `read` rather
# than a `cat` substitution, blank or malformed stdin fails closed, and a
# present non-string `command` is an error rather than a silent allow.
input=""
IFS= read -r -d '' input 2>/dev/null || true
case "$input" in
    *[![:space:]]*) ;;
    *) echo "block-bare-qmd-query: empty/blank stdin - failing closed" >&2; exit 2 ;;
esac
if ! result=$(jq -r 'if (. == null or . == false) then error("bad-shape") else ((try (.tool_input.command // .tool_input.cmd) catch null) as $c | if ($c != null and ($c|type) != "string") then error("non-string-command") else (((try (.tool_name) catch null) // "" | tostring) + "\n" + ($c // "")) end) end' <<<"$input" 2>/dev/null); then
    echo "block-bare-qmd-query: malformed/truncated JSON on stdin - failing closed" >&2
    exit 2
fi
tool="${result%%$'\n'*}"
tool="${tool%$'\r'}"
cmd="${result#*$'\n'}"
case "$tool" in
    Bash|"") ;;
    *) exit 0 ;;
esac

[ -z "$cmd" ] && exit 0

# Lower-case and fold newlines to ';' so the anchors below see one line.
cmd_lc=$(printf '%s' "$cmd" | LC_ALL=C tr '[:upper:]\n\r' '[:lower:];;')

# Cheap pre-filter: no `qmd` anywhere, nothing to check.
case "$cmd_lc" in
    *qmd*) ;;
    *) exit 0 ;;
esac

# EXEPFX / ASSIGN / SEP are block-git-stash.sh's, verbatim.
EXEPFX='["'\'']?([a-z]:)?([^[:space:]|;&`"'\'']*[/\\])?'
ASSIGN='[[:alnum:]_]+=('\''[^'\'']*'\''|"[^"]*"|[^[:space:]|;&]*)'
SEP='([[:space:]]|\\[[:space:]]*;+)+[[:space:]]*'
# A run of options, each optionally taking ONE non-dash value (`-n 10`, `-k 5`).
OPTV='([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*'
# Wrappers that run their argument as a program. timeout takes its duration.
WRAP='(sudo|doas|nice|ionice|chrt|taskset|stdbuf|setsid|nohup|command|exec|time|xargs|(ba|z|da|k)?sh(\.exe)?)'"$OPTV"
WRAP="($WRAP|timeout${OPTV}[[:space:]]+[0-9.]+[smhd]?|env([[:space:]]+(-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?|$ASSIGN))*|if|then|else|elif|do|while|until|!)"
CMDPOS='(^|[|;&(`{])[[:space:]]*(('"$ASSIGN"'|'"$EXEPFX$WRAP"')[[:space:]]+)*'"$EXEPFX"
# The program: qmd itself, or a JS runtime handed qmd's entry point.
RUNTIME='((bun|node|bunx|npx|deno)(\.exe)?["'\'']?'"$OPTV"'[[:space:]]+((run|x)[[:space:]]+)?'"$EXEPFX"')?'
QMDPROG="${RUNTIME}"'qmd(\.(ts|js|mjs|cjs|exe|cmd))?["'\'']?'
# qmd's global options (`--index <name>`) sit between the program and the verb.
QMDOPTVAL='('\''[^'\'']*'\''|"[^"]*"|[^-[:space:]][^[:space:]]*)'
QMDOPTS='('"${SEP}"'-[^[:space:]]+('"${SEP}${QMDOPTVAL}"')?)*'
BARE="${CMDPOS}${QMDPROG}${QMDOPTS}${SEP}"'(query|search|vsearch)([^[:alnum:]_-]|$)'

if [[ $cmd_lc =~ $BARE ]]; then
    bounded="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" 2>/dev/null && pwd)/qmd-bounded.sh"
    cat >&2 <<DENY
block-bare-qmd-query: a bare qmd query/search/vsearch is refused (HIMMEL-3956).

The qmd launcher forwards no signals, so when this call is killed — by the Bash
tool's timeout, a timeout(1) prefix or the session ending — its bun child keeps
running on the GPU, orphaned. Five such queries ran for ~15 h.

Run it under the group deadline instead (default ${QMD_TIMEOUT_SECS:-300} s, set QMD_TIMEOUT_SECS):
    bash $bounded query -c <collection> "<question>"
or use the qmd MCP tool (mcp__qmd__query), which the harness manages.

Non-search verbs (status, update, embed, collection, get) are not refused.
Bypass (deliberate, session-sticky): launch with QMD_UNBOUNDED_OK=1.
DENY
    exit 2
fi

exit 0
