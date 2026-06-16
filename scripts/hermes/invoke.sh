#!/usr/bin/env bash
# scripts/hermes/invoke.sh — single chokepoint for shelling out to hermes-agent.
#
# Mirror of scripts/gemini/invoke.sh (HIMMEL-158): all himmel entrypoints that
# need a hermes one-shot funnel through here so interpreter/model/toolset
# resolution lives in one place. Story 1 of the hermes critic pipeline
# (HIMMEL-273).
#
# Why not the `hermes` console script: the hermes.exe setuptools wrapper is
# unreliable under non-TTY shells on Windows (spike 2026-06-12 — wrapper runs
# >120s with no output where the module entry answers in seconds). We invoke
# the venv python directly and enter via hermes_cli.main.
#
# Why a prompt FILE (not argv, not stdin): argv hits the Windows spawn
# length limit on large diffs (same issue as HIMMEL-270 for gemini), and
# hermes one-shot runs hung in the spike when stdin was consumed/closed.
# The prompt travels via a temp file read inside the python snippet.
#
# Toolsets: DEFAULT `todo` — hermes -z sets HERMES_YOLO_MODE=1 (auto-approves
# every tool call), so an unconstrained one-shot may execute terminal/browser
# tools with no human in the loop. `todo` is the minimal harmless built-in
# bundle (no fs / terminal / network). Callers that genuinely want tools must
# opt in via --toolsets.
#
# Auth: defers ENTIRELY to hermes (its own .env + config.yaml provider chain,
# HIMMEL-278). No pre-flight credential check here.
#
# No retries, no internal timeout (cross-platform `timeout` semantics differ;
# same stance as the gemini chokepoint). Exits with hermes' return code.
#
# Usage:
#   invoke.sh "PONG"                                   # positional prompt
#   echo "hi" | invoke.sh -                            # read prompt from stdin
#   invoke.sh --model nvidia/nemotron-3-nano-30b-a3b "review this"
#   invoke.sh --prompt-file /tmp/big-pack.txt          # large prompt via file
#   invoke.sh --toolsets coding "do work with tools"
#   invoke.sh --log /tmp/run.log "PONG"
#
# Bash 3.2 safe (macOS / Git Bash on Windows).
set -uo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: invoke.sh [--model <name>] [--toolsets <list>] [--prompt-file <path>]
                 [--log <path>] [<prompt>|-]

  <prompt>           Prompt text. If `-` or omitted (and no --prompt-file),
                     read from stdin.
  --model <name>     Model override (hermes -m). Default: hermes config default.
  --toolsets <list>  Comma-separated hermes toolsets. Default: todo (minimal,
                     harmless — hermes one-shot auto-approves tool calls).
  --prompt-file <p>  Read the prompt from this file (large packs / diffs).
  --log <path>       Tee stdout + stderr to this log file.

Environment:
  HERMES_PY          Override the python interpreter used to run hermes
                     (default: %LOCALAPPDATA%/hermes/hermes-agent/venv python;
                     tests inject a stub through this).
EOF
}

model=""
toolsets="todo"
prompt_file=""
log=""
prompt=""
prompt_set=0

while [ $# -gt 0 ]; do
    case "$1" in
        --model)
            [ $# -ge 2 ] || { echo "invoke.sh: --model requires a value" >&2; exit 2; }
            model="$2"; shift 2 ;;
        --toolsets)
            [ $# -ge 2 ] || { echo "invoke.sh: --toolsets requires a value" >&2; exit 2; }
            toolsets="$2"; shift 2 ;;
        --prompt-file)
            [ $# -ge 2 ] || { echo "invoke.sh: --prompt-file requires a value" >&2; exit 2; }
            prompt_file="$2"; shift 2 ;;
        --log)
            [ $# -ge 2 ] || { echo "invoke.sh: --log requires a value" >&2; exit 2; }
            log="$2"; shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        -)
            prompt_set=0; shift ;;
        --)
            shift
            if [ $# -gt 0 ]; then prompt="$1"; prompt_set=1; shift; fi
            break ;;
        -*)
            echo "invoke.sh: unknown flag: $1" >&2; usage; exit 2 ;;
        *)
            prompt="$1"; prompt_set=1; shift ;;
    esac
done

# Resolve the prompt source: --prompt-file wins, else positional, else stdin.
tmp_prompt=""
# shellcheck disable=SC2317  # invoked indirectly via the EXIT trap
cleanup() { [ -n "$tmp_prompt" ] && rm -f "$tmp_prompt"; }
trap cleanup EXIT

if [ -n "$prompt_file" ]; then
    [ -f "$prompt_file" ] || { echo "invoke.sh: prompt file not found: $prompt_file" >&2; exit 2; }
    [ -s "$prompt_file" ] || { echo "invoke.sh: prompt file is empty: $prompt_file" >&2; exit 2; }
else
    if [ "$prompt_set" -eq 0 ]; then
        prompt="$(cat)"
    fi
    if [ -z "$prompt" ]; then
        echo "invoke.sh: empty prompt (none given and stdin was empty)" >&2
        exit 2
    fi
    tmp_prompt="$(mktemp "${TMPDIR:-/tmp}/hermes-prompt.XXXXXX")"
    printf '%s' "$prompt" > "$tmp_prompt"
    prompt_file="$tmp_prompt"
fi

# Resolve the hermes interpreter. HERMES_PY overrides (tests stub through it).
py="${HERMES_PY:-}"
if [ -z "$py" ]; then
    base="${LOCALAPPDATA:-$HOME/AppData/Local}/hermes/hermes-agent/venv/Scripts/python.exe"
    if [ -x "$base" ]; then
        py="$base"
    else
        # POSIX venv layout fallback
        alt="${LOCALAPPDATA:-$HOME/AppData/Local}/hermes/hermes-agent/venv/bin/python"
        [ -x "$alt" ] && py="$alt"
    fi
fi
if [ -z "$py" ]; then
    echo "invoke.sh: hermes interpreter not found (set HERMES_PY or install hermes)" >&2
    exit 3
fi

# Windows-native python needs a Windows path for the prompt file.
pf_native="$prompt_file"
if command -v cygpath >/dev/null 2>&1; then
    pf_native="$(cygpath -w "$prompt_file")"
fi

run_hermes() {
    HERMES_PROMPT_FILE="$pf_native" HERMES_ONESHOT_MODEL="$model" HERMES_ONESHOT_TOOLSETS="$toolsets" \
    "$py" -c '
import os, sys, io
with io.open(os.environ["HERMES_PROMPT_FILE"], encoding="utf-8") as fh:
    prompt = fh.read()
argv = ["hermes", "--cli"]
model = os.environ.get("HERMES_ONESHOT_MODEL", "")
toolsets = os.environ.get("HERMES_ONESHOT_TOOLSETS", "")
if model:
    argv += ["-m", model]
if toolsets:
    argv += ["-t", toolsets]
argv += ["-z", prompt]
sys.argv = argv
from hermes_cli.main import main
main()
'
}

if [ -n "$log" ]; then
    run_hermes 2>&1 | tee "$log"
    exit "${PIPESTATUS[0]}"
else
    run_hermes
    exit $?
fi
