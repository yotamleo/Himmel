#!/usr/bin/env bash
# test-launcher-context-env-parity.sh — the claude-codex twins must BOTH feed
# the context-window env pair from the CODEX_CONTEXT_WINDOW variable
# (HIMMEL-1887), and BOTH default the per-dispatch effort to `medium`, the value
# lanes.json declares (HIMMEL-2772).
#
# test-launcher-twin-parity.sh compares only embedded node JS between twins —
# by its own design — so it is blind to a plain export: a .ps1 twin missing
# the CLAUDE_CODE_MAX_CONTEXT_TOKENS export ships green there. This guard
# closes that gap for the one pair where the export is load-bearing: Claude
# Code resolves the effective compact window as min(modelWindow, configured),
# and for an out-of-catalog model (gpt-5.6-sol) modelWindow falls back to a
# hardcoded 200000 — without the export, CODEX_CONTEXT_WINDOW is silently
# clamped and never takes effect.
#
# The variable-not-literal assertion is the load-bearing one: a hardcoded
# number reintroduces the clamp the moment a caller overrides
# CODEX_CONTEXT_WINDOW. End-of-line is deliberately unanchored (CRLF-safe);
# matching the VARIABLE reference is what excludes a numeric literal.
#
# bash 3.2-safe; grep + coreutils only.
# shellcheck disable=SC2016  # literal $VAR text IS the assertion — never expand
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"          # scripts/parity
SCRIPTS="$(cd "$HERE/.." && pwd)"              # scripts/
BASH_TWIN="$SCRIPTS/claude-codex"
PS_TWIN="$SCRIPTS/claude-codex.ps1"
LANES_JSON="$SCRIPTS/lanes/lanes.json"

fails=0
for f in "$BASH_TWIN" "$PS_TWIN" "$LANES_JSON"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: missing twin $f"
    fails=$((fails + 1))
  fi
done

check() {  # check <desc> <file> <ERE>
  if grep -qE "$3" "$2" 2>/dev/null; then
    echo "ok: $1"
  else
    echo "FAIL: $1 (no line matching /$3/ in $2)"
    fails=$((fails + 1))
  fi
}

# 1. bash: MAX_CONTEXT_TOKENS exported from the VARIABLE, not a literal.
check 'claude-codex exports CLAUDE_CODE_MAX_CONTEXT_TOKENS="$CODEX_CONTEXT_WINDOW"' \
  "$BASH_TWIN" '^export CLAUDE_CODE_MAX_CONTEXT_TOKENS="\$CODEX_CONTEXT_WINDOW"'
# 2. ps1 twin: same export, from the $CodexContextWindow VARIABLE.
check 'claude-codex.ps1 sets $env:CLAUDE_CODE_MAX_CONTEXT_TOKENS = $CodexContextWindow' \
  "$PS_TWIN" '^\$env:CLAUDE_CODE_MAX_CONTEXT_TOKENS[[:space:]]*=[[:space:]]*\$CodexContextWindow'
# 3. both twins still feed AUTO_COMPACT_WINDOW from the SAME variable.
check 'claude-codex exports CLAUDE_CODE_AUTO_COMPACT_WINDOW="$CODEX_CONTEXT_WINDOW"' \
  "$BASH_TWIN" '^export CLAUDE_CODE_AUTO_COMPACT_WINDOW="\$CODEX_CONTEXT_WINDOW"'
check 'claude-codex.ps1 sets $env:CLAUDE_CODE_AUTO_COMPACT_WINDOW = $CodexContextWindow' \
  "$PS_TWIN" '^\$env:CLAUDE_CODE_AUTO_COMPACT_WINDOW[[:space:]]*=[[:space:]]*\$CodexContextWindow'

# 5. HIMMEL-2772: the per-dispatch effort default is `medium` (Astra on low/medium
#    beats the old high pin; `low` is the first lever for mechanical chunks), in
#    BOTH twins and in the lanes.json prose that documents it. Still overridable:
#    the bash default stays the `${VAR:-x}` form, the ps1 the `-not $env:VAR` form.
check 'claude-codex defaults CLAUDE_CODE_EFFORT_LEVEL to medium (overridable)' \
  "$BASH_TWIN" '^export CLAUDE_CODE_EFFORT_LEVEL="\$\{CLAUDE_CODE_EFFORT_LEVEL:-medium\}"'
check 'claude-codex.ps1 defaults $env:CLAUDE_CODE_EFFORT_LEVEL to medium (overridable)' \
  "$PS_TWIN" '^if \(-not \$env:CLAUDE_CODE_EFFORT_LEVEL\) \{ \$env:CLAUDE_CODE_EFFORT_LEVEL = .medium. \}'
check 'lanes.json claudex row says the launcher defaults effort to medium' \
  "$LANES_JSON" 'launcher defaults effort to medium'
if grep -qE 'launcher defaults effort to high' "$LANES_JSON" 2>/dev/null; then
  echo 'FAIL: lanes.json still says the launcher defaults effort to high'
  fails=$((fails + 1))
else
  echo 'ok: lanes.json no longer claims a high launcher default'
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "ALL PASS"
  exit 0
fi
echo "context-env parity FAILED"
exit 1
