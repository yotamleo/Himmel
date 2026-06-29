#!/usr/bin/env bash
# salus posture-A EGRESS FLOOR (PreToolUse, all tools).
#
# This repo holds medical PHI. Posture A = Anthropic/Claude (in-session) is the
# ONLY processor that may see the content. This hook is the STRUCTURAL floor that
# the prose guardrails alone could not provide: it hard-DENIES (exit 2) any tool
# call that could move PHI off-machine to a non-Anthropic service, plus any
# network/push/remote command. The medical pipeline never needs these — it runs
# on local tools (PyMuPDF/Docling) + the in-session Claude vision read.
#
# Posture: default-ALLOW with a specific DENYLIST (failing closed on every tool
# would break the local pipeline). On its own parse error it allows — but the
# denylist patterns are literal substrings of well-known tool names, so a real
# egress call cannot be missed by a parse slip.
#
# Exit: 0 allow · 2 BLOCK (stderr shown to the model).
set -euo pipefail

payload="$(cat 2>/dev/null || true)"
tn="$(printf '%s' "$payload" | grep -oE '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]*)"$/\1/' || true)"

deny() { echo "posture-A FLOOR: '$1' blocked — medical PHI must not leave the machine (no cloud/web/non-Anthropic egress). The pipeline uses local tools + in-session Claude vision only." >&2; exit 2; }

case "$tn" in
  WebSearch|WebFetch|gemini-subagent) deny "$tn" ;;
  Skill)
    # Block research/social/cloud skills that egress to Perplexity/Grok/NotebookLM/etc.
    sk="$(printf '%s' "$payload" | grep -oE '"(skill|command|name)"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]*)"$/\1/' || true)"
    case "$sk" in
      research|research-deep|x-read|x-pulse|notebooklm|youtube|deep-research|autoresearch) deny "Skill:$sk" ;;
    esac ;;
  # LOCAL MCPs are allowed (operator-authorized): obsidian-vault = localhost Obsidian REST
  # API (127.0.0.1), qmd = local on-disk index + local GGUF embeddings. Neither egresses
  # PHI off-machine, so both are consistent with Posture A. All OTHER mcp__* (cloud:
  # Gmail/Drive/Calendar/Atlassian/Telegram/context7/playwright/etc.) stay HARD-DENIED.
  mcp__obsidian-vault__*|mcp__plugin_qmd_qmd__*) ;;
  mcp__*) deny "$tn (cloud MCP disabled in the medical-PHI session; only localhost obsidian-vault + local qmd are allowed)" ;;
  Bash)
    cmd="$(printf '%s' "$payload" | grep -oE '"command"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' | head -1 || true)"
    case "$cmd" in
      *"git push"*|*"git remote add"*|*"git remote set-url"*|*"curl "*|*"curl.exe"*|*"wget "*|*"Invoke-WebRequest"*|*"Invoke-RestMethod"*|*"scp "*|*"rclone "*) deny "network/push command" ;;
    esac ;;
esac
exit 0
