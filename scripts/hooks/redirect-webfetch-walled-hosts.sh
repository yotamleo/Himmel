#!/usr/bin/env bash
# redirect-webfetch-walled-hosts.sh — PreToolUse hook (matcher "WebFetch"):
# denies WebFetch on a login-walled host (x.com, instagram.com, ... — the list
# is the one line in scripts/web/walled-hosts.conf) and names the working
# replacement, `bash scripts/web/fetch-url.sh '<url>'` (HIMMEL-4908). Twice a
# session met an x.com link, got WebFetch HTTP 402 and asked the operator for a
# paste while the Scrapling stealth fetcher returns 200. Second drift on prose
# -> structural (root CLAUDE.md "Adding a rule").
#
# Workflow convenience, not a security fence (scripts/hooks/CLAUDE.md
# "Fail-open vs fail-closed"): fails OPEN on anything it cannot parse (missing
# jq or conf, malformed input, a non-string or control-char URL). No network.
#
# Bypass: HIMMEL_WEBFETCH_WALLED_OK=1 in the LAUNCHING shell (session-sticky; a
# per-call prefix does not reach this hook process).
#
# Platform guard (gitbash-only): jq + bash string ops only; no .ps1 twin needed.
#
# Hook I/O: JSON on stdin. exit 0 = allow, exit 2 = deny (stderr plus a
# structured hookSpecificOutput.permissionDecision on stdout).
set -uo pipefail

[ "${HIMMEL_WEBFETCH_WALLED_OK:-0}" = "1" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)
tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
[ "$tool" = "WebFetch" ] || exit 0
url=$(printf '%s' "$input" | jq -r '.tool_input.url // empty | strings' 2>/dev/null) || exit 0
[ -n "$url" ] || exit 0
case "$url" in *[[:cntrl:]]*) exit 0 ;; esac

conf="$(cd "$(dirname "$0")" && pwd)/../web/walled-hosts.conf"
[ -r "$conf" ] || exit 0
hosts=$(head -n 1 "$conf")

# authority = between "://" and the first / ? #; drop userinfo and port.
rest="${url#*://}"
[ "$rest" != "$url" ] || exit 0
auth="${rest%%[/?#]*}"
auth="${auth##*@}"
host="${auth%%:*}"
host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
[ -n "$host" ] || exit 0

hit=0
for h in $hosts; do
    case "$host" in "$h" | *".$h") hit=1; break ;; esac
done
[ "$hit" = 1 ] || exit 0

quoted="'$(printf '%s' "$url" | sed "s/'/'\\\\''/g")'"
deny_msg="WebFetch is walled on this host (HTTP 402/login wall). Fetch it with the stealth fetcher instead, then work from its output: bash scripts/web/fetch-url.sh $quoted  (HIMMEL-4908; bypass: HIMMEL_WEBFETCH_WALLED_OK=1 in the launching shell)"
reason=$(printf '%s' "$deny_msg" | jq -Rs . 2>/dev/null) \
    || reason='"redirect-webfetch-walled-hosts: use bash scripts/web/fetch-url.sh <url>"'
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$reason"
printf '%s\n' "$deny_msg" >&2
exit 2
