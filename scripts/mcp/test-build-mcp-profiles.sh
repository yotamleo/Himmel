#!/usr/bin/env bash
# test-build-mcp-profiles.sh — HIMMEL-5002: the generated MCP profiles must not
# carry secret env values; they live in 0600 files the launcher shim reads.
# Platforms tested: linux
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/build-mcp-profiles.XXXXXX")" || exit 1; trap 'rm -rf "$T"' EXIT
FAKE="fake-key-$$-not-real"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; }
# lacks <needle> <file>...: true only when grep exits 1 (no match); an error (2) is not "clean".
lacks() { grep -q -- "$@"; [ $? -eq 1 ]; }

mkdir -p "$T/home" "$T/out"
cat >"$T/home/.claude.json" <<EOF
{"mcpServers":{"obsidian-vault":{"type":"stdio","command":"node","args":["-e","process.stdout.write(process.env.OBSIDIAN_API_KEY+'|'+process.env.OBSIDIAN_HOST)"],"env":{"OBSIDIAN_API_KEY":"$FAKE","OBSIDIAN_HOST":"127.0.0.1"}}}}
EOF
unset HIMMEL_MCP_SECRETS_DIR # an inherited override could point at the real secret store
export HOME="$T/home" HIMMEL_MCP_PROFILES_OUT="$T/out"

node "$HERE/build-mcp-profiles.mjs" >"$T/gen.log" 2>&1
P="$T/out/local.vault.json"

if [ -f "$P" ] && lacks "$FAKE" "$P" "$T/gen.log"; then ok "profile and log carry no secret value"; else bad "secret value leaked into profile or log"; fi
S="$T/home/.config/himmel/mcp-secrets/obsidian-vault/OBSIDIAN_API_KEY"
mode="$(stat -c %a "$S")" # gnu-ok: linux-only test
if [ -f "$S" ] && [ "$mode" = "600" ] && [ "$(cat "$S")" = "$FAKE" ]; then ok "secret stored 0600 under ~/.config"; else bad "secret file missing or not 0600"; fi
if [ -f "$P" ] && grep -q '"OBSIDIAN_HOST": "127.0.0.1"' "$P"; then ok "non-secret env stays in the profile"; else bad "non-secret env dropped"; fi

# The launcher still hands the secret to the server process.
out="$(node -e '
const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).mcpServers["obsidian-vault"];
const {spawnSync}=require("child_process");
const r=spawnSync(p.command,p.args,{env:{...process.env,...(p.env||{})},encoding:"utf8"});
process.stdout.write(r.stdout||"")' "$P")"
if [ "$out" = "$FAKE|127.0.0.1" ]; then ok "launcher injects the secret into the server env"; else bad "launcher did not inject secret (got '${out:0:20}')"; fi

# A loosened secret file is refused.
chmod 644 "$S"
out="$(node -e '
const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).mcpServers["obsidian-vault"];
const {spawnSync}=require("child_process");
const r=spawnSync(p.command,p.args,{env:{...process.env,...(p.env||{})},encoding:"utf8"});
process.stdout.write(String(r.status))' "$P")"
if [ "$out" = "1" ]; then ok "launcher refuses a 0644 secret file"; else bad "launcher accepted a 0644 secret file (status $out)"; fi

# Removing the last secret from the source config removes its file on regeneration.
cat >"$T/home/.claude.json" <<EOF
{"mcpServers":{"obsidian-vault":{"type":"stdio","command":"node","args":["-e","0"],"env":{"OBSIDIAN_HOST":"127.0.0.1"}}}}
EOF
node "$HERE/build-mcp-profiles.mjs" >"$T/gen2.log" 2>&1
if [ ! -e "$S" ]; then ok "stale secret file removed when the last secret is dropped"; else bad "stale secret file survived"; fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
