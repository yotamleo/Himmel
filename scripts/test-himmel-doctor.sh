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

echo "== STATIC: shipped settings-template.json carries no dangling <node-path> (HIMMEL-614) =="
# A literal copy of the template must not leave a dangling <node-path> that C1
# flags as fail-dangling. The caveman hooks ship in the run-node.sh wrapper form.
_tmpl="$REPO_ROOT/docs/setup/settings-template.json"
_cav_cmds="$(jq -r '[.hooks.UserPromptSubmit[]?.hooks[]?, .hooks.SessionStart[]?.hooks[]?]
    | map(.command // "") | map(select(test("caveman-(activate|mode-tracker)\\.js"))) | .[]' "$_tmpl")"
if printf '%s' "$_cav_cmds" | grep -q '<node-path>'; then
    fail "template caveman cmd still carries <node-path>"
elif [ -z "$_cav_cmds" ]; then
    fail "template has no caveman hook commands to check"
elif printf '%s' "$_cav_cmds" | grep -q 'run-node.sh'; then
    pass "template caveman cmds are wrapper-form (no <node-path>)"
else
    fail "template caveman cmds are neither wrapper-form nor dangling: $_cav_cmds"
fi

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

# C6-hooks (HIMMEL-611): a hook command leading with a bare interpreter that is
# absent on THIS host. Use $TOOLS_PATH (real coreutils dirs — keeps bash + its
# DLLs working on MINGW) which excludes pwsh; guard the WARN assertion in case a
# host genuinely has pwsh on that path.
echo "== C6-hooks: bare pwsh hook on a host without pwsh -> WARN =="
if PATH="$TOOLS_PATH" bash -c '! command -v pwsh >/dev/null 2>&1' 2>/dev/null; then
    t="$(mktemp -d)"; mkdir -p "$t/claude"
    cat > "$t/claude/settings.json" <<'EOF'
{ "mcpServers": {}, "hooks": { "SessionEnd": [ { "hooks": [ { "type": "command", "command": "pwsh -NoProfile -File \"/x/end-session-wiki.ps1\"", "shell": "powershell" } ] } ] } }
EOF
    out="$(PATH="$TOOLS_PATH" RESOLVE_NODE_PROBE_DIRS="" RESOLVE_NODE_NVM_ROOT="$t/none" FNM_DIR="$t/none" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
    if printf '%s' "$out" | grep -q 'WARN C6-hooks' && printf '%s' "$out" | grep -q 'pwsh'; then pass "C6-hooks -> WARN (pwsh absent)"; else fail "C6-hooks -> $(printf '%s' "$out" | grep C6-hooks)"; fi
    rm -rf "$t"
else
    pass "C6-hooks -> WARN (skipped: pwsh present under TOOLS_PATH on this host)"
fi

echo "== C6-hooks: wrapper-routed pwsh twin (leading bash) -> OK =="
t="$(mktemp -d)"; mkdir -p "$t/claude"
cat > "$t/claude/settings.json" <<'EOF'
{ "mcpServers": {}, "hooks": { "SessionEnd": [ { "hooks": [ { "type": "command", "command": "bash \"/x/scripts/lib/run-pwsh.sh\" \"/x/end-session-wiki.ps1\"", "shell": "bash" } ] } ] } }
EOF
out="$(PATH="$TOOLS_PATH" RESOLVE_NODE_PROBE_DIRS="" RESOLVE_NODE_NVM_ROOT="$t/none" FNM_DIR="$t/none" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if printf '%s' "$out" | grep -q 'OK   C6-hooks'; then pass "C6-hooks -> OK (wrapper-routed)"; else fail "C6-hooks -> $(printf '%s' "$out" | grep C6-hooks)"; fi
rm -rf "$t"

# ── C7: merged-PR worktree detective check ───────────────────────────────────
# Build a real temp git repo with real worktrees; stub the forge via GH_CMD.

# make_wt_repo <dir> — init a minimal git repo + first commit so worktrees work.
make_wt_repo() {
    local d="$1"
    mkdir -p "$d"
    git -C "$d" init -q
    git -C "$d" config user.email t@t
    git -C "$d" config user.name t
    printf 'init\n' > "$d/README.md"
    git -C "$d" add README.md
    git -C "$d" commit -q -m "init"
}

# make_gh_stub <dir> <merged_branch> — creates a gh stub that echoes 1 merged PR for
# the given branch and 0 for everything else.  If merged_branch is "FAIL", the stub
# exits 1 for every call.
# The real call shape from forge-github.sh gh_forge_pr_has_merged is:
#   gh pr list --head <branch> --state merged --json number --jq 'length'
# So args: $1=pr $2=list $3=--head $4=BRANCH $5=--state $6=merged $7=--json $8=number $9=--jq $10=length
make_gh_stub() {
    local d="$1" merged_branch="$2"
    mkdir -p "$d"
    if [ "$merged_branch" = "FAIL" ]; then
        printf '#!/bin/sh\nexit 1\n' > "$d/gh"
    else
        cat > "$d/gh" <<EOF
#!/bin/sh
# Stub for: gh pr list --head BRANCH --state merged --json number --jq length
if [ "\$4" = "$merged_branch" ]; then echo 1; else echo 0; fi
EOF
    fi
    chmod +x "$d/gh"
}

echo "== C7: merged-PR worktree -> WARN C7-shipped =="
t="$(mktemp -d)"
make_wt_repo "$t/repo"
# Capture default branch name before creating the feature branch.
_defbranch="$(git -C "$t/repo" rev-parse --abbrev-ref HEAD)"
git -C "$t/repo" checkout -q -b feat/shipped
git -C "$t/repo" checkout -q "$_defbranch"
git -C "$t/repo" worktree add -q "$t/wt-shipped" "feat/shipped"
make_gh_stub "$t/stub" "feat/shipped"
write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_WORKTREE_ROOT="$t/repo" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    FORGE=github GH_CMD="$t/stub/gh" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" \
    bash "$DOC" --no-color 2>&1)"
if printf '%s' "$out" | grep -q 'WARN' && printf '%s' "$out" | grep -q 'C7-shipped' && printf '%s' "$out" | grep -q 'feat/shipped'; then
    pass "C7 -> WARN (merged branch flagged)"
else
    fail "C7 -> expected WARN C7-shipped feat/shipped; got: $(printf '%s' "$out" | grep C7)"
fi
rm -rf "$t"

echo "== C7: no merged worktrees -> OK C7-shipped =="
t="$(mktemp -d)"
make_wt_repo "$t/repo"
_defbranch2="$(git -C "$t/repo" rev-parse --abbrev-ref HEAD)"
git -C "$t/repo" checkout -q -b feat/not-merged
git -C "$t/repo" checkout -q "$_defbranch2"
git -C "$t/repo" worktree add -q "$t/wt-live" "feat/not-merged"
make_gh_stub "$t/stub" "__no_match__"
write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_WORKTREE_ROOT="$t/repo" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    FORGE=github GH_CMD="$t/stub/gh" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" \
    bash "$DOC" --no-color 2>&1)"
if printf '%s' "$out" | grep -q 'OK   C7-shipped'; then
    pass "C7 -> OK (no merged worktrees)"
else
    fail "C7 -> expected OK C7-shipped; got: $(printf '%s' "$out" | grep C7)"
fi
rm -rf "$t"

echo "== C7: forge-error -> INFO C7-shipped skipped =="
t="$(mktemp -d)"
make_wt_repo "$t/repo"
_defbranch3="$(git -C "$t/repo" rev-parse --abbrev-ref HEAD)"
git -C "$t/repo" checkout -q -b feat/unreachable
git -C "$t/repo" checkout -q "$_defbranch3"
git -C "$t/repo" worktree add -q "$t/wt-unreachable" "feat/unreachable"
make_gh_stub "$t/stub" "FAIL"
write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_WORKTREE_ROOT="$t/repo" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    FORGE=github GH_CMD="$t/stub/gh" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" \
    bash "$DOC" --no-color 2>&1)"
if printf '%s' "$out" | grep -q 'INFO' && printf '%s' "$out" | grep -q 'C7-shipped' && printf '%s' "$out" | grep -q 'skipped'; then
    pass "C7 -> INFO (forge unreachable)"
else
    fail "C7 -> expected INFO C7-shipped skipped; got: $(printf '%s' "$out" | grep C7)"
fi
rm -rf "$t"

echo "== C7: locked worktree with merged branch -> NOT flagged =="
t="$(mktemp -d)"
make_wt_repo "$t/repo"
_defbranch4="$(git -C "$t/repo" rev-parse --abbrev-ref HEAD)"
git -C "$t/repo" checkout -q -b feat/locked-merged
git -C "$t/repo" checkout -q "$_defbranch4"
git -C "$t/repo" worktree add -q "$t/wt-locked" "feat/locked-merged"
git -C "$t/repo" worktree lock "$t/wt-locked" 2>/dev/null || true
make_gh_stub "$t/stub" "feat/locked-merged"
write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_WORKTREE_ROOT="$t/repo" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    FORGE=github GH_CMD="$t/stub/gh" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" \
    bash "$DOC" --no-color 2>&1)"
# Locked worktree must NOT produce a WARN for feat/locked-merged.
if printf '%s' "$out" | grep 'WARN' | grep -q 'C7-shipped'; then
    fail "C7 -> locked worktree must not be flagged; got WARN"
else
    pass "C7 -> locked worktree not flagged"
fi
rm -rf "$t"

echo "== C7 STATIC: check_c7 body must not contain destructive git verbs =="
# Extract only the check_c7 function body from himmel-doctor.sh and assert
# none of the forbidden verbs appear.  Mechanically checkable without shimming git.
_c7_body="$(awk '/^check_c7\(\)/{found=1} found{print} found && /^\}$/{exit}' "$DOC")"
_static_fail=0
for _verb in "worktree remove" "branch -D" " push " " reset " " checkout " "rm " "git clean" "clean -"; do
    if printf '%s' "$_c7_body" | grep -qF "$_verb"; then
        fail "C7 STATIC: found forbidden verb '$_verb' in check_c7 body"
        _static_fail=1
    fi
done
if [ "$_static_fail" -eq 0 ]; then
    pass "C7 STATIC: no destructive verbs in check_c7 body"
fi

# ── C8: stale pipeline-cadence runner detection (HIMMEL-588) ──────────────────
echo "== C8: no armed cadence runners -> OK C8-cadence =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" PIPELINE_BAT_DIR="$t/cadence-empty" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" \
    bash "$DOC" --no-color 2>&1)"
if printf '%s' "$out" | grep -q 'OK   C8-cadence'; then pass "C8 -> OK (no runners)"; else fail "C8 -> $(printf '%s' "$out" | grep C8)"; fi
rm -rf "$t"

echo "== C8: stale runner (no format stamp) -> WARN C8-cadence =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/cadence"; write_settings "$t/claude" "$WRAPPER"
# A runner with NO format marker simulates a cadence armed before HIMMEL-588.
printf '#!/bin/sh\necho old runner\n' > "$t/cadence/pipeline-harvest.sh"
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" PIPELINE_BAT_DIR="$t/cadence" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" \
    bash "$DOC" --no-color 2>&1)"
if printf '%s' "$out" | grep -q 'WARN C8-cadence'; then pass "C8 -> WARN (stale runner)"; else fail "C8 -> $(printf '%s' "$out" | grep C8)"; fi
rm -rf "$t"

echo "== C8: current runner (stamped) -> OK C8-cadence =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/cadence"; write_settings "$t/claude" "$WRAPPER"
printf '#!/bin/sh\n# himmel-cadence-runner-format: 1\necho current runner\n' > "$t/cadence/pipeline-harvest.sh"
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" PIPELINE_BAT_DIR="$t/cadence" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" \
    bash "$DOC" --no-color 2>&1)"
if printf '%s' "$out" | grep -q 'OK   C8-cadence' && printf '%s' "$out" | grep -q 'current'; then pass "C8 -> OK (current runner)"; else fail "C8 -> $(printf '%s' "$out" | grep C8)"; fi
rm -rf "$t"

echo "== C9 linux at+atd live -> OK =="
t="$(mktemp -d)"; b="$t/bin"; mkdir -p "$b"
printf '#!/bin/sh\nexit 0\n' > "$b/at"; chmod +x "$b/at"
out="$(SCHEDULER_BACKEND_OS=linux SCHEDULER_BACKEND_ATD_ACTIVE=1 PATH="$b:$TOOLS_PATH" \
       CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if printf '%s' "$out" | grep -q 'OK   C9-scheduler'; then pass "C9 linux ok"; else fail "C9 linux ok: $(printf '%s' "$out" | grep C9)"; fi
rm -rf "$t"

echo "== C9 linux at+atd dead -> WARN + remediation =="
t="$(mktemp -d)"; b="$t/bin"; mkdir -p "$b"
printf '#!/bin/sh\nexit 0\n' > "$b/at"; chmod +x "$b/at"
out="$(SCHEDULER_BACKEND_OS=linux SCHEDULER_BACKEND_ATD_ACTIVE=0 PATH="$b:$TOOLS_PATH" \
       CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if printf '%s' "$out" | grep -q 'WARN C9-scheduler'; then pass "C9 linux disabled WARN"; else fail "C9 disabled: $(printf '%s' "$out" | grep C9)"; fi
if printf '%s' "$out" | grep -q 'systemctl enable --now atd'; then pass "C9 remediation shown"; else fail "C9 remediation missing"; fi
rm -rf "$t"

echo "== C9 macos crontab -> WARN ok-cron, NOT 'install at' =="
t="$(mktemp -d)"; b="$t/bin"; mkdir -p "$b"
printf '#!/bin/sh\nexit 0\n' > "$b/crontab"; chmod +x "$b/crontab"
out="$(SCHEDULER_BACKEND_OS=macos PATH="$b:$TOOLS_PATH" \
       CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if printf '%s' "$out" | grep -q 'WARN C9-scheduler'; then pass "C9 macos warn"; else fail "C9 macos: $(printf '%s' "$out" | grep C9)"; fi
if printf '%s' "$out" | grep -q 'apt install'; then fail "C9 macos wrongly suggests apt"; else pass "C9 macos no apt advice"; fi
rm -rf "$t"

# ── C10: private→public propagation drift (HIMMEL-640) ────────────────────────
# mk10 <seed> <bare> <clone> — commit seed contents on main, bare-clone, work-clone.
mk10() {
    git -C "$1" init -q; git -C "$1" config user.email t@t; git -C "$1" config user.name t
    git -C "$1" config core.autocrlf false
    git -C "$1" add -A; git -C "$1" commit -qm x; git -C "$1" branch -M main
    git clone -q --bare "$1" "$2"; git clone -q "$2" "$3"
}

echo "== C10: no public clone -> OK C10-propagation (skip-clean) =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
out="$(HIMMEL_PUBLIC_CLONE="$t/none" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if printf '%s' "$out" | grep -q 'OK   C10-propagation' && [ "$rc" -eq 0 ]; then pass "C10 -> OK (skip, no clone)"; else fail "C10 -> rc=$rc; $(printf '%s' "$out" | grep C10)"; fi
rm -rf "$t"

# Public/adopter clones lack the private-only mirror tooling
# (scripts/propagate-public.sh + scripts/lib/propagation-drift.sh), so the doctor's
# C10 check short-circuits to a clean "skipped (no private mirror tooling)" OK
# BEFORE it ever consults HIMMEL_PRIV_ROOT (see check_c10() in himmel-doctor.sh). On such a
# checkout the seeded-drift / unreadable-refs fixtures can never surface a WARN —
# so the assertion is gated on whether this checkout actually carries the tooling.
if [ -f "$REPO_ROOT/scripts/propagate-public.sh" ] && [ -f "$REPO_ROOT/scripts/lib/propagation-drift.sh" ]; then C10_TOOLING=1; else C10_TOOLING=0; fi

echo "== C10: seeded drift fixture -> WARN C10-propagation =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
ps="$t/ps"; mkdir -p "$ps/scripts"; printf 'stub\n' > "$ps/scripts/propagate-public.sh"; printf 'new doc\n' > "$ps/onlypriv.md"
us="$t/us"; mkdir -p "$us"; printf 'base\n' > "$us/base.md"
mk10 "$ps" "$t/ps.git" "$t/pc"
mk10 "$us" "$t/us.git" "$t/uc"
out="$(HIMMEL_PRIV_ROOT="$t/pc" HIMMEL_PUBLIC_CLONE="$t/uc" HIMMEL_PUBLIC_REMOTE="us.git" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" \
    bash "$DOC" --no-color 2>&1)"
if [ "$C10_TOOLING" -eq 1 ]; then
    if printf '%s' "$out" | grep -q 'WARN C10-propagation' && printf '%s' "$out" | grep -q 'onlypriv.md'; then pass "C10 -> WARN (seeded drift, MISSING flagged)"; else fail "C10 -> $(printf '%s' "$out" | grep -A6 C10)"; fi
else
    if printf '%s' "$out" | grep -q 'OK   C10-propagation' && printf '%s' "$out" | grep -q 'skipped (no private mirror tooling)'; then pass "C10 -> skip (public checkout, no mirror tooling)"; else fail "C10 -> $(printf '%s' "$out" | grep -A6 C10)"; fi
fi
rm -rf "$t"

echo "== C10: unreadable origin/main -> WARN (stale/unreadable refs, not false-clean) =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
# priv has the marker but its default branch is NOT 'main' -> ls-tree origin/main
# is empty -> detector WARNs -> C10 must surface WARN, never OK "no drift".
ps="$t/ps"; mkdir -p "$ps/scripts"; printf 'stub\n' > "$ps/scripts/propagate-public.sh"
git -C "$ps" init -q; git -C "$ps" config user.email t@t; git -C "$ps" config user.name t
git -C "$ps" config core.autocrlf false
git -C "$ps" add -A; git -C "$ps" commit -qm x; git -C "$ps" branch -M notmain
us="$t/us"; mkdir -p "$us"; printf 'base\n' > "$us/base.md"
mk10 "$us" "$t/us.git" "$t/uc"
out="$(HIMMEL_PRIV_ROOT="$ps" HIMMEL_PUBLIC_CLONE="$t/uc" HIMMEL_PUBLIC_REMOTE="us.git" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" \
    bash "$DOC" --no-color 2>&1)"
if [ "$C10_TOOLING" -eq 1 ]; then
    if printf '%s' "$out" | grep -q 'WARN C10-propagation' && ! printf '%s' "$out" | grep -q 'OK   C10-propagation'; then pass "C10 -> WARN (unreadable refs, not false-clean)"; else fail "C10 unreadable -> $(printf '%s' "$out" | grep -A4 C10)"; fi
else
    if printf '%s' "$out" | grep -q 'OK   C10-propagation' && printf '%s' "$out" | grep -q 'skipped (no private mirror tooling)'; then pass "C10 -> skip (public checkout, no mirror tooling)"; else fail "C10 unreadable -> $(printf '%s' "$out" | grep -A4 C10)"; fi
fi
rm -rf "$t"

rm -rf "$FAKEROOT"
echo
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$failures FAILURE(S)"; exit 1; fi
