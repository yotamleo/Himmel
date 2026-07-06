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
Usage: invoke.sh [--model <name>] [--profile <name>] [--toolsets <list>]
                 [--prompt-file <path>] [--log <path>] [<prompt>|-]

  <prompt>           Prompt text. If `-` or omitted (and no --prompt-file),
                     read from stdin.
  --model <name>     Model override (hermes -m). Default: hermes config default.
  --profile <name>   Run under this hermes profile (hermes -p), i.e. its SOUL +
                     config (e.g. himmel_agent = senior main-tier reviewer). Fail-
                     open: if the profile does not exist, warn and use the default
                     profile rather than error (hermes itself exits 1 on a missing
                     profile, which must never break a CR one-shot).
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
profile=""
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
        --profile)
            [ $# -ge 2 ] || { echo "invoke.sh: --profile requires a value" >&2; exit 2; }
            profile="$2"; shift 2 ;;
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
# shellcheck disable=SC2317,SC2329  # invoked indirectly via the EXIT trap (SC2329 = the renamed "function never invoked" check)
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

# Resolve the hermes interpreter at RUNTIME via the shared resolver (HIMMEL-613):
# HERMES_PY overrides (tests stub through it) ONLY when it still points at an
# executable, else probe the venv — a moved/rebuilt venv re-resolves instead of
# breaking on a stale path.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/resolve-hermes-py.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/resolve-hermes-py.sh"
py="$(resolve_hermes_py)" || py=""
if [ -z "$py" ]; then
    echo "invoke.sh: hermes interpreter not found (set HERMES_PY or install hermes)" >&2
    exit 3
fi

# Windows-native python needs a Windows path for the prompt file.
pf_native="$prompt_file"
if command -v cygpath >/dev/null 2>&1; then
    pf_native="$(cygpath -w "$prompt_file")"
fi

# Profile selection (HIMMEL-558): pass `-p <profile>` so the one-shot runs under
# that profile's SOUL + config (e.g. himmel_agent = the senior main-tier reviewer
# persona, NOT the user-default junior SOUL). FAIL-OPEN guard: hermes exits 1 on a
# missing profile, which would break a CR one-shot — so only forward -p when the
# profile directory exists; otherwise warn and let hermes use its default profile.
# `default` is always valid (it is the hermes root itself, no profiles/ subdir).
profile_arg=""
if [ -n "$profile" ]; then
    _hh="${HERMES_HOME:-}"
    if [ -z "$_hh" ]; then
        if [ -n "${LOCALAPPDATA:-}" ]; then _hh="$LOCALAPPDATA/hermes"; else _hh="$HOME/.local/share/hermes"; fi
    fi
    if [ "$profile" = "default" ] || [ -d "$_hh/profiles/$profile" ]; then
        profile_arg="$profile"
    else
        echo "invoke.sh: hermes profile '$profile' not found under $_hh/profiles — using default profile" >&2
    fi
fi

run_hermes() {
    HERMES_PROMPT_FILE="$pf_native" HERMES_ONESHOT_MODEL="$model" HERMES_ONESHOT_PROFILE="$profile_arg" HERMES_ONESHOT_TOOLSETS="$toolsets" \
    "$py" -c '
import os, sys, io
with io.open(os.environ["HERMES_PROMPT_FILE"], encoding="utf-8") as fh:
    prompt = fh.read()
argv = ["hermes", "--cli"]
model = os.environ.get("HERMES_ONESHOT_MODEL", "")
profile = os.environ.get("HERMES_ONESHOT_PROFILE", "")
toolsets = os.environ.get("HERMES_ONESHOT_TOOLSETS", "")
if profile:
    argv += ["-p", profile]
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

# HIMMEL-729 wiring chunk B — best-effort Alibaba quota-gauge probe piggybacked
# on a qwen* dispatch. Fire-and-forget: backgrounded, all output to /dev/null,
# NEVER blocks or fails the dispatch (it cannot reach the dispatch rc). The
# runner self-throttles (60s freshness marker) and skips silently when the
# Alibaba env vars are unset. Invoke-only — no always-on surface. The shell edit
# stays minimal; the logic lives in the TS runner (scripts/telegram/alibaba-probe-once.ts).
alibaba_quota_piggyback() {
    [ -n "$model" ] || return 0
    case "$model" in
        [Qq][Ww][Ee][Nn]*) : ;;  # qwen* (qwen-plus, qwen3-coder-plus, …) — case-insensitive
        *) return 0 ;;
    esac
    command -v bun >/dev/null 2>&1 || return 0
    local runner="$SCRIPT_DIR/../telegram/alibaba-probe-once.ts"
    [ -f "$runner" ] || return 0
    ( bun "$runner" >/dev/null 2>&1 || true ) &   # detached; never affects the dispatch
    disown 2>/dev/null || true
}

if [ -n "$log" ]; then
    run_hermes 2>&1 | tee "$log"
    rc="${PIPESTATUS[0]}"
else
    run_hermes
    rc=$?
fi
alibaba_quota_piggyback   # best-effort, fire-and-forget, never touches rc
exit "$rc"
