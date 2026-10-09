#!/usr/bin/env bash
# HIMMEL-4985: run a non-API child with every API-lane credential removed.
# Usage: strip-env.sh -- <cmd> [args...]
# Anything that is not the API launcher (subagents, tools, hooks it spawns) must
# not inherit the API key or the lane selectors, or it would bill the API org.
[ "${1:-}" = "--" ] && shift
[ "$#" -gt 0 ] || { echo "usage: strip-env.sh -- <cmd> [args...]" >&2; exit 2; }
exec env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
  -u HIMMEL_API_LANE -u HIMMEL_API_ACCOUNT -u HIMMEL_API_KEY_ID \
  -u HIMMEL_API_CREDIT_CONFIG -u HIMMEL_API_CREDIT_SNAPSHOT -u HIMMEL_API_CREDIT_STATE \
  -u LQ_API_KEY -u LQ_API_ACCOUNT -u LQ_API_KEY_ID -u LQ_API_LANE \
  -u HIMMEL_API_CREDIT_FORMAT -u HIMMEL_API_CLAUDE_BIN -u HIMMEL_API_JOB_ID "$@"
