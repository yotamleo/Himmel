#!/usr/bin/env bash
# Smoke suite for scripts/hooks/redirect-webfetch-walled-hosts.sh (HIMMEL-4908):
# WebFetch on a walled host (x.com / instagram.com ...) is denied with a
# paste-ready scripts/web/fetch-url.sh command; any other host is allowed;
# malformed input fails open.
# Platform guard (gitbash-only): jq + bash string ops only; no .ps1 twin needed.
# ok/bad never fail, so `[ ] && ok || bad` is the if/else it reads as.
# shellcheck disable=SC2015
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HOOKS/redirect-webfetch-walled-hosts.sh"
# A leg's launching shell may export the bypass; clear it before any case runs.
# shellcheck source=../lib/override-env.sh
# shellcheck disable=SC1091
. "$HOOKS/../lib/override-env.sh"
scrub_override_env
[ -f "$HOOK" ] || { echo "hook not found: $HOOK" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# run <json> -> sets rc, out (stdout)
run() {
    out="$(printf '%s' "$1" | bash "$HOOK" 2>/dev/null)"; rc=$?
}
wf() { jq -nc --arg u "$1" '{tool_name:"WebFetch",tool_input:{url:$u,prompt:"p"}}'; }

echo "== x-link-denied-with-command =="
run "$(wf 'https://x.com/Voxyz_ai/status/2107939019091005836')"
[ "$rc" = 2 ] && ok "x.com denied (rc=2)" || bad "x.com expected rc=2 got $rc"
reason="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision + "|" + .hookSpecificOutput.permissionDecisionReason' 2>/dev/null)"
case "$reason" in
    deny\|*"bash scripts/web/fetch-url.sh 'https://x.com/Voxyz_ai/status/2107939019091005836'"*) ok "deny reason carries the paste-ready command" ;;
    *) bad "reason missing command: $reason" ;;
esac
for u in 'https://twitter.com/a/status/1' 'https://mobile.twitter.com/a/status/1' 'https://www.instagram.com/p/ABC/' 'https://WWW.X.COM/a/status/1'; do
    run "$(wf "$u")"
    [ "$rc" = 2 ] && ok "denied: $u" || bad "expected deny for $u got rc=$rc"
done

echo "== other-host-allowed =="
for u in 'https://example.com/x.com' 'https://notx.com/a' 'https://x.com.evil.example/a' 'https://docs.python.org/3/'; do
    run "$(wf "$u")"
    if [ "$rc" = 0 ] && [ -z "$out" ]; then ok "allowed silently: $u"; else bad "expected silent allow for $u got rc=$rc out=$out"; fi
done
run '{"tool_name":"Bash","tool_input":{"command":"echo https://x.com/a"}}'
[ "$rc" = 0 ] && ok "other tool allowed" || bad "other tool rc=$rc"

echo "== quote-in-url-safely-quoted =="
want="https://x.com/a/status/1?q=it's'; touch /tmp/pwned #"
run "$(wf "$want")"
[ "$rc" = 2 ] && ok "quote url denied" || bad "quote url rc=$rc"
reason_txt="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
args="${reason_txt#*bash scripts/web/fetch-url.sh }"
args="${args%  (HIMMEL-4908*}"
# The quoted arg must round-trip to the exact URL through the shell's own parser.
rt="$(eval "set -- $args; printf '%s' \"\$1\"" 2>/dev/null)"
[ "$rt" = "$want" ] && ok "quoted arg round-trips to the exact URL" || bad "round-trip mismatch: [$rt]"

echo "== malformed-input-allows =="
for j in '' 'not json' '{}' '{"tool_name":"WebFetch"}' '{"tool_name":"WebFetch","tool_input":{"url":42}}' '{"tool_name":"WebFetch","tool_input":{"url":"::::"}}'; do
    run "$j"
    [ "$rc" = 0 ] && ok "fail-open on: ${j:-<empty>}" || bad "expected allow for '${j}' got rc=$rc"
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
