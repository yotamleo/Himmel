#!/usr/bin/env bash
# Smoke test for scripts/himmel-doctor.sh (hermetic — temp CLAUDE_DIR/HOME).
# Usage: bash scripts/test-himmel-doctor.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
DOC="$REPO_ROOT/scripts/himmel-doctor.sh"
[ -f "$DOC" ] || { echo "FAIL: $DOC not found"; exit 1; }

# Hermeticity: never let an inherited LUNA_VAULT_PATH point C3 at the operator's
# real vault (HOME is redirected per-case, but C3 probes $LUNA_VAULT_PATH first).
export LUNA_VAULT_PATH=""

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

# PATH that has every tool the doctor/scripts need EXCEPT node and gh (so the
# no-node and gh-absent branches are exercisable). node lives in its own dir.
tool_dirs() {
    local t d; for t in git jq sort sed cat date mktemp dirname uname wc tr head cp rm mv chmod; do
        d="$(command -v "$t" 2>/dev/null)" && dirname "$d"
    done | sort -u | tr '\n' ':'
}
TOOLS_PATH="$(tool_dirs)"

# fake uname=Linux (to exercise the non-Windows --fix path on this MINGW box)
FAKEROOT="$(mktemp -d)"; FAKEBIN="$FAKEROOT/bin"; mkdir -p "$FAKEBIN"
printf '#!/bin/sh\necho Linux\n' > "$FAKEBIN/uname"; chmod +x "$FAKEBIN/uname"

# A fake node so "node resolvable" cases are deterministic regardless of whether
# the host actually has node (a node-less Linux box would otherwise FAIL them).
FAKENODE="$FAKEROOT/nodebin"; mkdir -p "$FAKENODE"
printf '#!/bin/sh\necho v20\n' > "$FAKENODE/node"; chmod +x "$FAKENODE/node"

# A curated PATH with the tools the doctor needs but WITHOUT gh — for the
# gh-absent case. On Linux gh shares /usr/bin with coreutils, so excluding a dir
# won't drop it; symlink only the needed tools instead.
NOGH="$FAKEROOT/nogh"; mkdir -p "$NOGH"
for _tool in bash sh git jq sort tail sed cat date mktemp mkdir dirname uname wc tr head cp rm mv chmod grep basename; do
    _p="$(command -v "$_tool" 2>/dev/null)" && ln -sf "$_p" "$NOGH/$_tool" 2>/dev/null
done

# $1=claude dir, $2=JSON-encoded caveman SessionStart command
write_settings() {
    mkdir -p "$1"
    cat > "$1/settings.json" <<EOF
{ "hooks": {
  "SessionStart": [ { "hooks": [ { "type": "command", "command": $2 } ] } ],
  "UserPromptSubmit": [] } }
EOF
}
DANGLING='"\"<node-path>\" \"<claude-dir>/hooks/caveman-activate.js\""'
WRAPPER='"bash \"/x/scripts/lib/run-node.sh\" \"/y/hooks/caveman-activate.js\""'

make_gh() { # $1=dir, $2=create|exists
    mkdir -p "$1"
    if [ "$2" = exists ]; then LIST='echo "[{\"title\":\"[himmel-doctor] old\",\"url\":\"http://x/1\"}]"'; else LIST='echo "[]"'; fi
    cat > "$1/gh" <<EOF
#!/bin/sh
case "\$1 \$2" in
  "issue list") $LIST ;;
  "issue create") echo "CREATE \$4" ;;
esac
EOF
    chmod +x "$1/gh"
}

echo "== clean (wrapper-form, node resolvable) -> exit 0, C1 OK =="
t="$(mktemp -d)"; write_settings "$t/claude" "$WRAPPER"
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'OK   C1-node'; then pass "clean -> rc0, C1 OK"; else fail "clean -> rc=$rc; $(printf '%s' "$out" | grep C1-node)"; fi
rm -rf "$t"

echo "== dangling <node-path> -> C1 FAIL, exit 1 =="
t="$(mktemp -d)"; write_settings "$t/claude" "$DANGLING"
out="$(CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'FAIL C1-node'; then pass "dangling -> rc1, C1 FAIL"; else fail "dangling -> rc=$rc; $(printf '%s' "$out" | grep C1-node)"; fi
rm -rf "$t"

echo "== --fix heals dangling (faked Linux uname) -> C1 OK =="
t="$(mktemp -d)"; write_settings "$t/claude" "$DANGLING"
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" PATH="$FAKEBIN:$PATH" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --fix --no-color 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'OK   C1-node'; then pass "--fix -> healed, rc0"; else fail "--fix -> rc=$rc; $out"; fi
# confirm the settings file now points at the wrapper
if grep -q 'run-node.sh' "$t/claude/settings.json"; then pass "--fix wrote wrapper form"; else fail "--fix did not write wrapper"; fi
rm -rf "$t"

echo "== wrapper-form but NO node anywhere -> C1 FAIL (R4/P5) =="
t="$(mktemp -d)"; write_settings "$t/claude" "$WRAPPER"
out="$(PATH="$TOOLS_PATH" RESOLVE_NODE_PROBE_DIRS="" RESOLVE_NODE_NVM_ROOT="$t/none" FNM_DIR="$t/none" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'FAIL C1-node'; then pass "wrapper+no-node -> rc1 FAIL"; else fail "wrapper+no-node -> rc=$rc; $(printf '%s' "$out" | grep C1-node)"; fi
rm -rf "$t"

echo "== --file-issue with gh stub -> creates with resolved repo =="
t="$(mktemp -d)"; write_settings "$t/claude" "$DANGLING"; make_gh "$t/gh" create
out="$(PATH="$t/gh:$PATH" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --file-issue --repo me/repo --no-color 2>&1)"
if printf '%s' "$out" | grep -q 'CREATE me/repo'; then pass "file-issue -> created"; else fail "file-issue -> $(printf '%s' "$out" | tail -3)"; fi
rm -rf "$t"

echo "== --file-issue dedup (existing open issue) -> skip create =="
t="$(mktemp -d)"; write_settings "$t/claude" "$DANGLING"; make_gh "$t/gh" exists
out="$(PATH="$t/gh:$PATH" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --file-issue --repo me/repo --no-color 2>&1)"
if printf '%s' "$out" | grep -q 'already exists' && ! printf '%s' "$out" | grep -q 'CREATE'; then pass "dedup -> skipped"; else fail "dedup -> $(printf '%s' "$out" | tail -3)"; fi
rm -rf "$t"

echo "== --file-issue with gh ABSENT -> graceful, no crash =="
# Only run where the curated symlink PATH genuinely works (Linux) — Windows
# Git Bash symlinks to .exe tools don't execute, so skip there cleanly.
if PATH="$NOGH" bash -c 'git --version >/dev/null 2>&1 && jq --version >/dev/null 2>&1 && ! command -v gh >/dev/null 2>&1' 2>/dev/null; then
    t="$(mktemp -d)"; write_settings "$t/claude" "$DANGLING"
    out="$(PATH="$NOGH" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --file-issue --repo me/repo --no-color 2>&1)"; rc=$?
    if printf '%s' "$out" | grep -q 'gh not found' && { [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; }; then pass "gh-absent -> graceful (rc=$rc)"; else fail "gh-absent -> rc=$rc; $(printf '%s' "$out" | tail -3)"; fi
    rm -rf "$t"
else
    pass "gh-absent -> (skipped: could not build a gh-less PATH on this host)"
fi

echo "== bare 'node' caveman cmd + node off PATH -> C1 WARN =="
t="$(mktemp -d)"; write_settings "$t/claude" '"node \"X/hooks/caveman-activate.js\""'
out="$(PATH="$TOOLS_PATH" RESOLVE_NODE_PROBE_DIRS="" RESOLVE_NODE_NVM_ROOT="$t/none" FNM_DIR="$t/none" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if printf '%s' "$out" | grep -q 'WARN C1-node'; then pass "bare-node -> C1 WARN"; else fail "bare-node -> $(printf '%s' "$out" | grep C1-node)"; fi
rm -rf "$t"

echo "== C2: shadowed claude-obsidian marketplace -> WARN =="
t="$(mktemp -d)"; mkdir -p "$t/claude/plugins/cache/claude-obsidian-marketplace"; write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if printf '%s' "$out" | grep -q 'WARN C2-obsidian'; then pass "C2 -> WARN (shadow)"; else fail "C2 -> $(printf '%s' "$out" | grep C2)"; fi
rm -rf "$t"

echo "== C3: dirty single-writer luna vault -> WARN =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; v="$t/home/Documents/luna"; mkdir -p "$v"
git -C "$v" init -q 2>/dev/null; git -C "$v" config user.email t@t; git -C "$v" config user.name t
: > "$v/.single-writer"; echo dirty > "$v/note.md"
write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if printf '%s' "$out" | grep -q 'WARN C3-luna'; then pass "C3 -> WARN (dirty single-writer)"; else fail "C3 -> $(printf '%s' "$out" | grep C3)"; fi
rm -rf "$t"

echo "== C6: bare-interpreter MCP server -> WARN =="
t="$(mktemp -d)"; mkdir -p "$t/claude"
cat > "$t/claude/settings.json" <<'EOF'
{ "mcpServers": { "obsidian-vault": { "command": "uvx", "args": ["mcp-obsidian"] } }, "hooks": {} }
EOF
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if printf '%s' "$out" | grep -q 'WARN C6-mcp' && printf '%s' "$out" | grep -q 'obsidian-vault(uvx)'; then pass "C6 -> WARN (uvx)"; else fail "C6 -> $(printf '%s' "$out" | grep C6)"; fi
rm -rf "$t"

echo "== C6: absolute-command MCP server -> OK =="
t="$(mktemp -d)"; mkdir -p "$t/claude"
cat > "$t/claude/settings.json" <<'EOF'
{ "mcpServers": { "x": { "command": "/usr/local/bin/foo" } }, "hooks": {} }
EOF
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if printf '%s' "$out" | grep -q 'OK   C6-mcp'; then pass "C6 -> OK (absolute)"; else fail "C6 -> $(printf '%s' "$out" | grep C6)"; fi
rm -rf "$t"

rm -rf "$FAKEROOT"
echo
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$failures FAILURE(S)"; exit 1; fi
