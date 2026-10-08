#!/usr/bin/env bash
# qmd-auth-headers.sh - MCP `headersHelper` for the qmd HTTP daemon (HIMMEL-5002).
#
# The daemon requires `Authorization: Bearer <token>`; the token lives in a
# 0600 file the daemon generates on first start. This prints the headers JSON
# Claude Code merges into each request, reading the file at call time so the
# secret never enters .mcp.json, the repo, or a process env.
#
#   qmd-auth-headers.sh           -> {"Authorization":"Bearer <token>"}  (or {} when no token yet)
#   qmd-auth-headers.sh --token   -> the bare token (empty when absent)
#
# Token path: $QMD_HTTP_TOKEN_FILE, else ${XDG_CONFIG_HOME:-$HOME/.config}/qmd/http-token
# - the same resolution the daemon uses. A group/world-readable file is not
# trusted (the daemon refuses it too): print no token, never the secret.
set -u

token_file="${QMD_HTTP_TOKEN_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/qmd/http-token}"
token=""
if [ -f "$token_file" ]; then
  mode="$(stat -c '%a' "$token_file" 2>/dev/null || stat -f '%Lp' "$token_file" 2>/dev/null || echo 777)"
  case "$mode" in
    600|400) token="$(tr -d '[:space:]' <"$token_file")" ;;
  esac
fi

if [ "${1:-}" = "--token" ]; then
  printf '%s' "$token"
  exit 0
fi
if [ -n "$token" ]; then
  printf '{"Authorization":"Bearer %s"}\n' "$token"
else
  printf '{}\n'
fi
