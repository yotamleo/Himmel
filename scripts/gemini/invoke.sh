#!/usr/bin/env bash
# scripts/gemini/invoke.sh — single chokepoint for shelling out to gemini-cli.
#
# All himmel entrypoints (/gemini slash, gemini-subagent Agent) funnel
# through here so auth/model/flag resolution lives in one place. Story A of
# the gemini-cli integration (HIMMEL-158).
#
# Auth: defers ENTIRELY to gemini-cli. No pre-flight credential check.
# gemini-cli resolves auth itself (precedence: force-flags GOOGLE_GENAI_USE_*
# -> GEMINI_API_KEY -> OAuth creds -> GOOGLE_API_KEY). This script never
# inspects or asserts credentials.
#
# No retries. Exits with gemini-cli's return code. No --timeout (cross-platform
# `timeout` semantics differ; per spec review Y3).
#
# Prompt delivery: the resolved prompt is always piped to gemini via stdin
# (printf '%s' "$prompt" | gemini ...). gemini-cli reads the prompt from
# piped stdin, avoiding the Windows node-spawn argv-length limit that causes
# "Argument list too long" for large diffs (HIMMEL-270).
#
# Usage:
#   invoke.sh "PONG"                  # positional prompt
#   echo "hi" | invoke.sh -           # read prompt from stdin
#   echo "hi" | invoke.sh             # stdin (prompt omitted)
#   invoke.sh --model gemini-2.5-flash "PONG"
#   invoke.sh --json "list 3 fruits"
#   invoke.sh --yolo --cwd /some/dir "do work"
#   invoke.sh --log /tmp/run.log "PONG"
#
# Bash 3.2 safe (macOS / Git Bash on Windows).
set -uo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: invoke.sh [--model <name>] [--cwd <path>] [--json] [--yolo] [--log <path>] [<prompt>|-]

  <prompt>        Prompt text. If `-` or omitted, read from stdin.
  --model <name>  Pass-through to `gemini -m`. Only emitted when set; otherwise
                  gemini-cli picks the model based on auth tier.
  --cwd <path>    Run gemini-cli from this dir. Default: current dir.
  --json          Pass `-o json` to gemini-cli.
  --yolo          Pass `--approval-mode yolo` (no per-tool confirmations).
  --log <path>    Tee stdout + stderr to this log file.
EOF
}

model=""
cwd=""
json=0
yolo=0
log=""
prompt=""
prompt_set=0

while [ $# -gt 0 ]; do
    case "$1" in
        --model)
            [ $# -ge 2 ] || { echo "invoke.sh: --model requires a value" >&2; exit 2; }
            model="$2"; shift 2 ;;
        --cwd)
            [ $# -ge 2 ] || { echo "invoke.sh: --cwd requires a value" >&2; exit 2; }
            cwd="$2"; shift 2 ;;
        --json)
            json=1; shift ;;
        --yolo)
            yolo=1; shift ;;
        --log)
            [ $# -ge 2 ] || { echo "invoke.sh: --log requires a value" >&2; exit 2; }
            log="$2"; shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        -)
            # explicit stdin sentinel — leave prompt unset to trigger stdin read
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

# Read prompt from stdin when omitted or `-` was given.
if [ "$prompt_set" -eq 0 ]; then
    prompt="$(cat)"
fi

# Warn when a positional prompt is combined with piped stdin: the caller's
# stdin is silently discarded because the prompt travels via printf '%s'
# below. This combination is almost always a bug in the caller.
if [ "$prompt_set" -eq 1 ] && [ ! -t 0 ]; then
    echo "invoke.sh: warning: positional prompt given AND stdin is a pipe — caller's stdin is discarded (prompt travels via printf, not stdin read)" >&2
fi

if [ -z "$prompt" ]; then
    echo "invoke.sh: empty prompt (none given and stdin was empty)" >&2
    exit 2
fi

# Assemble gemini-cli argv. `-m` only when --model set (per spec A.1).
set --
if [ -n "$model" ]; then
    set -- "$@" -m "$model"
fi
if [ "$json" -eq 1 ]; then
    set -- "$@" -o json
fi
if [ "$yolo" -eq 1 ]; then
    set -- "$@" --approval-mode yolo
fi

# Run from --cwd when given. Subshell keeps the cd local.
# Prompt travels via piped stdin (not -p argv) to dodge the Windows
# argument-length limit for large diffs (HIMMEL-270).
run_gemini() {
    if [ -n "$cwd" ]; then
        ( cd "$cwd" || exit 1
          # headless-gemini-ok: sanctioned gemini-cli chokepoint (HIMMEL-158); prompt piped on stdin to dodge the Windows argv limit (HIMMEL-270)
          printf '%s' "$prompt" | gemini "$@" )
    else
        # headless-gemini-ok: sanctioned gemini-cli chokepoint (HIMMEL-158); prompt piped on stdin to dodge the Windows argv limit (HIMMEL-270)
        printf '%s' "$prompt" | gemini "$@"
    fi
}

if [ -n "$log" ]; then
    # tee stdout+stderr to the log while preserving gemini's rc (not tee's).
    run_gemini "$@" 2>&1 | tee "$log"
    exit "${PIPESTATUS[0]}"
else
    run_gemini "$@"
    exit $?
fi
