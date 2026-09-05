#!/usr/bin/env bash
# Smoke test for scripts/himmel-doctor.sh (hermetic — temp CLAUDE_DIR/HOME).
# Usage: bash scripts/test-himmel-doctor.sh
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

REPO_ROOT="$(git rev-parse --show-toplevel)"
DOC="$REPO_ROOT/scripts/himmel-doctor.sh"
[ -f "$DOC" ] || { echo "FAIL: $DOC not found"; exit 1; }
CADENCE_VER="$(sed -n 's/^CADENCE_RUNNER_FORMAT_VERSION=//p' "$REPO_ROOT/scripts/lib/cadence-format.sh" | head -1)"
STALE_CADENCE_VER=$((CADENCE_VER - 1))

# Hermeticity: never let an inherited LUNA_VAULT_PATH point C3 at the operator's
# real vault (HOME is redirected per-case, but C3 probes $LUNA_VAULT_PATH first).
export LUNA_VAULT_PATH=""

# Hermeticity: same reasoning for C26 and SALUS_VAULT_PATH — HOME is redirected
# per-case, but C26 probes $SALUS_VAULT_PATH first and would otherwise pick up
# an inherited value pointing at the operator's real salus vault.
export SALUS_VAULT_PATH=""

# Hermeticity: same reasoning for C27 and CLAUDE_GLM_CONFIG_DIR — HOME is
# redirected per-case so the default ~/.config/claude-glm already resolves
# under the per-case temp HOME, but an inherited CLAUDE_GLM_CONFIG_DIR from the
# launching shell would otherwise point C27 at the operator's real config dir.
export CLAUDE_GLM_CONFIG_DIR=""

# Hermeticity (HIMMEL-2176): C28 reads himmelctl's own state.json (recorded
# guardrail-block-global consent) at ${HIMMELCTL_CACHE_DIR:-$HOME/.claude/himmel}
# — HOME is redirected per-case so the default already resolves under the
# per-case temp HOME, but an inherited HIMMELCTL_CACHE_DIR from the launching
# shell would otherwise point C28 at the operator's real himmelctl state.
export HIMMELCTL_CACHE_DIR=""

# Hermeticity: C14 reads OLLAMA_NO_CLOUD from the live env — never let an
# inherited value from the launching shell leak into the default test runs.
unset OLLAMA_NO_CLOUD

# C19 performs local HTTP probes and reads the installed observability tree.
# Keep every unrelated case hermetic; dedicated C19 cases opt back in.
export DOCTOR_OBSERVABILITY_SKIP=1

# Hermeticity (HIMMEL-2010): C20 now FAILS on node-major drift, and it reads the
# REAL node/.nvmrc in every case that does not seam them — so on a drifted host
# it would flip the exit code of every unrelated case here. Bypass it globally;
# the C20 cases set NODE_MAJOR_DRIFT_OK=0 (and CI/GITHUB_ACTIONS empty) per-case.
export NODE_MAJOR_DRIFT_OK=1

# Hermeticity (HIMMEL-2024): C21 reads the operator's REAL hermes install
# (LOCALAPPDATA/hermes) unless seamed — point it at a nonexistent dir globally
# (check_c21's `[ ! -d ]` guard) so unrelated cases get a deterministic
# "no hermes install found" INFO instead of leaking this machine's actual
# active profile. Dedicated C21 cases seam it per-case with their own fixture.
DOCTOR_HERMES_HOME_EMPTY="$(mktemp -d)/no-hermes"
export DOCTOR_HERMES_HOME="$DOCTOR_HERMES_HOME_EMPTY"

# C25 (HIMMEL-1820) performs a live platform process scan (PowerShell CIM on
# Windows, ps on POSIX). Keep every unrelated case hermetic and
# host-independent -- what real processes run must never flip a test verdict;
# dedicated C25 cases opt back in via the shim seam.
export DOCTOR_ORPHAN_SCAN_SKIP=1

# Hermeticity (HIMMEL-2545): C29 scans the REAL /proc tree for claude
# child-session launchers unless seamed -- this dev box routinely has several
# such legs running right now (the exact HIMMEL-2545 bug), and every
# unrelated case would otherwise pick up a WARN C29-child-session it is not
# testing. Point at a nonexistent dir globally (check_c29's `[ ! -d ]` guard
# reads that as a clean procfs-absent skip, never a false WARN); dedicated
# C29 cases seam it per-case with their own stub tree.
HIMMEL_DOCTOR_PROC_BASE="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-noproc.XXXXXX")" || { echo "FAIL: mktemp -d failed"; exit 1; }
export HIMMEL_DOCTOR_PROC="$HIMMEL_DOCTOR_PROC_BASE/no-proc"

# Hermeticity (HIMMEL-969): C8's runner-home defaults resolve via
# cadence_user_home (USERPROFILE via cygpath on Windows) — per-case HOME
# redirection does NOT cover that, so pin all four seams to empty dirs
# globally; C8 cases override them per-case. EVERY seam in C8's table must be
# pinned here: an unpinned one falls through to the operator's REAL
# ~/.claude/<cadence> dir, so an armed cadence on the dev box would leak into
# the "no armed cadence runners" and "no false nudges" cases (HIMMEL-568 added
# the qmd seam).
C8_EMPTY="$(mktemp -d)"
export PIPELINE_BAT_DIR="$C8_EMPTY/pipeline" SWEEP_BAT_DIR="$C8_EMPTY/sweep" GRAPHMAP_BAT_DIR="$C8_EMPTY/graphmap" QMD_CADENCE_BAT_DIR="$C8_EMPTY/qmd"

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

# Keep unrelated cases from scanning the operator's real worktree garden (and
# making live forge calls). Dedicated C7 cases override this seam per invocation.
DOCTOR_WT_EMPTY="$FAKEROOT/doctor-wt-empty"; mkdir -p "$DOCTOR_WT_EMPTY"
export DOCTOR_WORKTREE_ROOT="$DOCTOR_WT_EMPTY"

# Keep unrelated cases from scanning this checkout's own local branches for
# C23 (and making live gh calls). Dedicated C23 cases override this seam.
DOCTOR_UNLANDED_EMPTY="$FAKEROOT/doctor-unlanded-empty"; mkdir -p "$DOCTOR_UNLANDED_EMPTY"
export DOCTOR_UNLANDED_DIR="$DOCTOR_UNLANDED_EMPTY"

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

# $1=claude dir, $2=JSON-encoded SessionStart hook command
write_settings() {
    mkdir -p "$1"
    cat > "$1/settings.json" <<EOF
{ "hooks": {
  "SessionStart": [ { "hooks": [ { "type": "command", "command": $2 } ] } ],
  "UserPromptSubmit": [] } }
EOF
}
WRAPPER='"bash \"/x/scripts/lib/run-node.sh\" \"/y/hooks/session-start.js\""'

# write_guardrail_settings <claude-dir> <node-path> — writes a settings.json
# whose hooks.PreToolUse carries the 3 user-level guardrail entries in the
# EXACT shape guardrail-block.mjs generates for --guardrail-mode global
# (HIMMEL-2013), pointed at <node-path>; SessionStart/UserPromptSubmit stay empty.
write_guardrail_settings() {
    local claude_dir="$1" node_path="$2" bash_path wrapper
    mkdir -p "$claude_dir"
    bash_path="$(command -v bash)"
    if command -v cygpath >/dev/null 2>&1; then bash_path="$(cygpath -m "$bash_path")"; fi
    wrapper="$REPO_ROOT/scripts/hooks/guardrail-skip-in-himmel.js"
    # MSYS_NO_PATHCONV: jq is a native exe; Git Bash would rewrite the C:/... node path inside --arg into a C;C:\... path list.
    MSYS_NO_PATHCONV=1 jq -n \
        --arg c1 "GUARDRAIL_BASH=\"$bash_path\" \"$node_path\" \"$wrapper\" \"$REPO_ROOT/scripts/hooks/auto-approve-safe-bash.sh\"" \
        --arg c2 "GUARDRAIL_BASH=\"$bash_path\" \"$node_path\" \"$wrapper\" \"$REPO_ROOT/scripts/hooks/block-edit-on-main.sh\"" \
        --arg c3 "GUARDRAIL_BASH=\"$bash_path\" \"$node_path\" \"$wrapper\" \"$REPO_ROOT/scripts/hooks/block-read-secrets.sh\"" \
        '{ hooks: {
            SessionStart: [],
            UserPromptSubmit: [],
            PreToolUse: [
                { matcher: "Bash", hooks: [ { type: "command", command: $c1 } ] },
                { matcher: "Edit|Write|MultiEdit|NotebookEdit", hooks: [ { type: "command", command: $c2 } ] },
                { matcher: "Bash|PowerShell|Read|Grep", hooks: [ { type: "command", command: $c3 } ] }
            ]
        } }' > "$claude_dir/settings.json"
}

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

echo "== clean settings (node resolvable) -> exit 0 =="
t="$(mktemp -d)"; write_settings "$t/claude" "$WRAPPER"
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then pass "clean -> rc0"; else fail "clean -> rc=$rc; $(printf '%s' "$out" | grep FAIL)"; fi
# write_settings' fixture carries no PreToolUse block at all -> guardrail-block.mjs
# detects mode=project -> C1-guardrail has nothing to check (HIMMEL-2013).
if grepq "$out" 'OK   C1-guardrail'; then pass "clean -> C1-guardrail OK (no guardrail block)"; else fail "clean -> $(printf '%s' "$out" | grep C1-guardrail)"; fi
rm -rf "$t"

echo "== --file-issue with gh stub -> creates with resolved repo =="
t="$(mktemp -d)"; write_guardrail_settings "$t/claude" "$t/gone/node"; make_gh "$t/gh" create
out="$(PATH="$t/gh:$PATH" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --file-issue --repo me/repo --no-color 2>&1)"
if grepq "$out" 'CREATE me/repo'; then pass "file-issue -> created"; else fail "file-issue -> $(printf '%s' "$out" | tail -3)"; fi
rm -rf "$t"

echo "== --file-issue dedup (existing open issue) -> skip create =="
t="$(mktemp -d)"; write_guardrail_settings "$t/claude" "$t/gone/node"; make_gh "$t/gh" exists
out="$(PATH="$t/gh:$PATH" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --file-issue --repo me/repo --no-color 2>&1)"
if grepq "$out" 'already exists' && ! grepq "$out" 'CREATE'; then pass "dedup -> skipped"; else fail "dedup -> $(printf '%s' "$out" | tail -3)"; fi
rm -rf "$t"

echo "== --file-issue with gh ABSENT -> graceful, no crash =="
# Only run where the curated symlink PATH genuinely works (Linux) — Windows
# Git Bash symlinks to .exe tools don't execute, so skip there cleanly.
if PATH="$NOGH" bash -c 'git --version >/dev/null 2>&1 && jq --version >/dev/null 2>&1 && ! command -v gh >/dev/null 2>&1' 2>/dev/null; then
    t="$(mktemp -d)"; write_guardrail_settings "$t/claude" "$t/gone/node"
    out="$(PATH="$NOGH" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --file-issue --repo me/repo --no-color 2>&1)"; rc=$?
    if grepq "$out" 'gh not found' && { [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; }; then pass "gh-absent -> graceful (rc=$rc)"; else fail "gh-absent -> rc=$rc; $(printf '%s' "$out" | tail -3)"; fi
    rm -rf "$t"
else
    pass "gh-absent -> (skipped: could not build a gh-less PATH on this host)"
fi

echo "== C1-guardrail: guardrail block baked to a missing node -> FAIL C1-guardrail, rc 1 =="
t="$(mktemp -d)"
write_guardrail_settings "$t/claude" "$t/gone/node"
out="$(CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" 'FAIL C1-guardrail'; then pass "guardrail stale node -> rc1, FAIL C1-guardrail"; else fail "guardrail stale node -> rc=$rc; $(printf '%s' "$out" | grep C1-guardrail)"; fi
rm -rf "$t"

echo "== C1-guardrail: guardrail block baked to a present node -> OK C1-guardrail =="
_real_node="$(command -v node 2>/dev/null || true)"
if [ -n "$_real_node" ]; then
    if command -v cygpath >/dev/null 2>&1; then _real_node="$(cygpath -m "$_real_node")"; fi
    t="$(mktemp -d)"
    write_guardrail_settings "$t/claude" "$_real_node"
    out="$(CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
    if grepq "$out" 'OK   C1-guardrail'; then pass "guardrail present node -> OK C1-guardrail"; else fail "guardrail present node -> $(printf '%s' "$out" | grep C1-guardrail)"; fi
    rm -rf "$t"
else
    pass "guardrail present node -> (skipped: no node on PATH here)"
fi

echo "== C1-guardrail: --fix re-bakes the stale guardrail node (faked Linux uname) =="
t="$(mktemp -d)"
write_guardrail_settings "$t/claude" "$t/gone/node"
PATH="$FAKEBIN:$PATH" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --fix --no-color >/dev/null 2>&1
# On a Windows host with a faked-Linux uname, setup-hooks.sh bakes a /c/...
# node path that node's fs.existsSync can't see, so the post-fix re-check may
# still FAIL here — the honest assertion is just that the STALE path is gone.
if grep -q "$t/gone/node" "$t/claude/settings.json"; then
    fail "--fix -> stale node path still present in settings.json"
else
    pass "--fix -> stale node path replaced"
fi
if grep -q 'guardrail-skip-in-himmel.js' "$t/claude/settings.json"; then pass "--fix -> guardrail wiring still present"; else fail "--fix -> guardrail wiring missing after re-bake"; fi
rm -rf "$t"

echo "== C2: shadowed claude-obsidian marketplace -> WARN =="
t="$(mktemp -d)"; mkdir -p "$t/claude/plugins/cache/claude-obsidian-marketplace"; write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C2-obsidian'; then pass "C2 -> WARN (shadow)"; else fail "C2 -> $(printf '%s' "$out" | grep C2)"; fi
rm -rf "$t"

echo "== C3: dirty single-writer luna vault -> WARN =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; v="$t/home/Documents/luna"; mkdir -p "$v"
git -C "$v" init -q 2>/dev/null; git -C "$v" config user.email t@t; git -C "$v" config user.name t
: > "$v/.single-writer"; echo dirty > "$v/note.md"
write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C3-luna'; then pass "C3 -> WARN (dirty single-writer)"; else fail "C3 -> $(printf '%s' "$out" | grep C3)"; fi
rm -rf "$t"

echo "== C26: no salus vault -> OK skipped =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c26.XXXXXX")"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C26-salus-marker' && grepq "$out" 'no salus vault found'; then pass "C26 -> OK (no vault)"; else fail "C26 no-vault -> $(printf '%s' "$out" | grep C26)"; fi
rm -rf "$t"

echo "== C26: salus vault with no .salus-profile -> OK skipped (not a salus deployment) =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c26.XXXXXX")"; mkdir -p "$t/claude"; v="$t/home/Documents/salus"; mkdir -p "$v"
write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C26-salus-marker' && grepq "$out" 'not a salus-profile deployment'; then pass "C26 -> OK (no .salus-profile)"; else fail "C26 no-profile -> $(printf '%s' "$out" | grep C26)"; fi
rm -rf "$t"

echo "== C26: .salus-profile present, .salus absent -> WARN (armed-but-inert) =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c26.XXXXXX")"; mkdir -p "$t/claude"; v="$t/home/Documents/salus"; mkdir -p "$v"
: > "$v/.salus-profile"
write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C26-salus-marker' && grepq "$out" 'armed-but-inert'; then pass "C26 -> WARN (profile without .salus)"; else fail "C26 profile-only -> $(printf '%s' "$out" | grep C26)"; fi
rm -rf "$t"

echo "== C26: both .salus-profile and .salus present -> OK armed =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c26.XXXXXX")"; mkdir -p "$t/claude"; v="$t/home/Documents/salus"; mkdir -p "$v"
: > "$v/.salus-profile"; : > "$v/.salus"
write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C26-salus-marker' && grepq "$out" 'PHI guards are armed'; then pass "C26 -> OK (both markers present)"; else fail "C26 both-markers -> $(printf '%s' "$out" | grep C26)"; fi
rm -rf "$t"

echo "== C27: no claude-glm config dir -> OK skipped =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c27.XXXXXX")"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C27-guard-signals' && grepq "$out" 'declared here'; then pass "C27 -> OK (no config dir)"; else fail "C27 no-dir -> $(printf '%s' "$out" | grep C27)"; fi
rm -rf "$t"

echo "== C27: config dir present, no phi-roots/egress-denylist files -> OK skipped =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c27.XXXXXX")"; mkdir -p "$t/claude"; mkdir -p "$t/home/.config/claude-glm"
write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C27-guard-signals' && grepq "$out" 'readable regular files'; then pass "C27 -> OK (nothing declared)"; else fail "C27 empty-dir -> $(printf '%s' "$out" | grep C27)"; fi
rm -rf "$t"

echo "== C27: readable phi-roots + egress-denylist -> OK =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c27.XXXXXX")"; mkdir -p "$t/claude"; mkdir -p "$t/home/.config/claude-glm"
: > "$t/home/.config/claude-glm/phi-roots"; : > "$t/home/.config/claude-glm/egress-denylist"
write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C27-guard-signals' && grepq "$out" 'readable regular files'; then pass "C27 -> OK (both readable)"; else fail "C27 readable -> $(printf '%s' "$out" | grep C27)"; fi
rm -rf "$t"

echo "== C27: phi-roots exists but is a directory (not a readable regular file) -> WARN (inert signal) =="
# A directory is the portable unreadable-policy fixture (same trick as
# scripts/graphify/test-refresh-graph-map.sh T43e): [-f] fails on a directory
# on every platform, unlike chmod 000 which does not reliably deny read to the
# owner on Windows.
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c27.XXXXXX")"; mkdir -p "$t/claude"
mkdir -p "$t/home/.config/claude-glm/phi-roots"
write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C27-guard-signals' && grepq "$out" 'not a readable regular file'; then pass "C27 -> WARN (phi-roots is a directory)"; else fail "C27 unreadable -> $(printf '%s' "$out" | grep C27)"; fi
rm -rf "$t"

echo "== C6: bare-interpreter MCP server -> WARN =="
t="$(mktemp -d)"; mkdir -p "$t/claude"
cat > "$t/claude/settings.json" <<'EOF'
{ "mcpServers": { "obsidian-vault": { "command": "uvx", "args": ["mcp-obsidian"] } }, "hooks": {} }
EOF
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C6-mcp' && grepq "$out" 'obsidian-vault(uvx)'; then pass "C6 -> WARN (uvx)"; else fail "C6 -> $(printf '%s' "$out" | grep C6)"; fi
rm -rf "$t"

echo "== C6: absolute-command MCP server -> OK =="
t="$(mktemp -d)"; mkdir -p "$t/claude"
cat > "$t/claude/settings.json" <<'EOF'
{ "mcpServers": { "x": { "command": "/usr/local/bin/foo" } }, "hooks": {} }
EOF
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C6-mcp'; then pass "C6 -> OK (absolute)"; else fail "C6 -> $(printf '%s' "$out" | grep C6)"; fi
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
    if grepq "$out" 'WARN C6-hooks' && grepq "$out" 'pwsh'; then pass "C6-hooks -> WARN (pwsh absent)"; else fail "C6-hooks -> $(printf '%s' "$out" | grep C6-hooks)"; fi
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
if grepq "$out" 'OK   C6-hooks'; then pass "C6-hooks -> OK (wrapper-routed)"; else fail "C6-hooks -> $(printf '%s' "$out" | grep C6-hooks)"; fi
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
if grepq "$out" 'WARN' && grepq "$out" 'C7-shipped' && grepq "$out" 'feat/shipped'; then
    pass "C7 -> WARN (merged branch flagged)"
else
    fail "C7 -> expected WARN C7-shipped feat/shipped; got: $(printf '%s' "$out" | grep C7)"
fi
rm -rf "$t"

echo "== C7: untracked-only merged-PR worktree -> WARN C7-shipped with the UNTRACKED remediation =="
t="$(mktemp -d)"
make_wt_repo "$t/repo"
_defbranch1c="$(git -C "$t/repo" rev-parse --abbrev-ref HEAD)"
git -C "$t/repo" checkout -q -b feat/shipped-untracked
git -C "$t/repo" checkout -q "$_defbranch1c"
git -C "$t/repo" worktree add -q "$t/wt-shipped-untracked" "feat/shipped-untracked"
# The HIMMEL-1692 headline shape: nothing tracked is modified, but a forgotten
# untracked file (the real incident was a 502-line spec) sits in a merged
# worktree. A tracked-only probe would call this clean and hand back the flat
# "prune with /clean", which clean-garden may well refuse as forgotten work.
printf 'a forgotten spec\n' > "$t/wt-shipped-untracked/FORGOTTEN-SPEC.md"
make_gh_stub "$t/stub" "feat/shipped-untracked"
write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_WORKTREE_ROOT="$t/repo" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    FORGE=github GH_CMD="$t/stub/gh" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" \
    bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN' && grepq "$out" 'C7-shipped' && grepq "$out" 'feat/shipped-untracked' \
    && grepq "$out" 'has UNTRACKED files' && grepq "$out" 'dry-run'; then
    pass "C7 -> WARN (untracked-only merged branch gets the UNTRACKED remediation)"
else
    fail "C7 -> expected the UNTRACKED remediation for feat/shipped-untracked; got: $(printf '%s' "$out" | grep C7)"
fi
rm -rf "$t"

echo "== C7: dirty merged-PR worktree -> WARN C7-shipped with 'will refuse' remediation =="
t="$(mktemp -d)"
make_wt_repo "$t/repo"
_defbranch1b="$(git -C "$t/repo" rev-parse --abbrev-ref HEAD)"
git -C "$t/repo" checkout -q -b feat/shipped-dirty
git -C "$t/repo" checkout -q "$_defbranch1b"
git -C "$t/repo" worktree add -q "$t/wt-shipped-dirty" "feat/shipped-dirty"
# Dirty the worktree (HIMMEL-1692): /clean will refuse to prune this one, so
# the C7 remediation must say so instead of pointing at /clean as if it works.
printf 'uncommitted\n' >> "$t/wt-shipped-dirty/README.md"
make_gh_stub "$t/stub" "feat/shipped-dirty"
write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_WORKTREE_ROOT="$t/repo" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    FORGE=github GH_CMD="$t/stub/gh" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" \
    bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN' && grepq "$out" 'C7-shipped' && grepq "$out" 'feat/shipped-dirty' \
    && grepq "$out" 'refuses to prune it' && grepq "$out" 'do NOT just commit in place'; then
    pass "C7 -> WARN (dirty merged branch gets the 'will refuse' remediation)"
else
    fail "C7 -> expected WARN C7-shipped feat/shipped-dirty with dirty-worktree remediation; got: $(printf '%s' "$out" | grep C7)"
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
if grepq "$out" 'OK   C7-shipped'; then
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
if grepq "$out" 'INFO' && grepq "$out" 'C7-shipped' && grepq "$out" 'skipped'; then
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
if grepq "$(printf '%s' "$out" | grep 'WARN')" 'C7-shipped'; then
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
    if grepq "$_c7_body" -F "$_verb"; then
        fail "C7 STATIC: found forbidden verb '$_verb' in check_c7 body"
        _static_fail=1
    fi
done
if [ "$_static_fail" -eq 0 ]; then
    pass "C7 STATIC: no destructive verbs in check_c7 body"
fi

# ── C8: stale cadence runner detection (HIMMEL-588/HIMMEL-969) ───────────────
echo "== C8: no armed cadence runners -> OK C8-cadence =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" PIPELINE_BAT_DIR="$t/pipeline-empty" \
    SWEEP_BAT_DIR="$t/sweep-empty" GRAPHMAP_BAT_DIR="$t/graphmap-empty" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" \
    bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C8-cadence: no armed cadence runners (skipped)'; then pass "C8 -> OK (no runners)"; else fail "C8 -> $(printf '%s' "$out" | grep C8)"; fi
rm -rf "$t"

echo "== C8: stale codex-sweep runner -> WARN + codex re-arm hint =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/sweep"; write_settings "$t/claude" "$WRAPPER"
printf 'rem himmel-cadence-runner-format: %s\r\n' "$STALE_CADENCE_VER" > "$t/sweep/codex-sweep.bat"
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" PIPELINE_BAT_DIR="$t/pipeline-empty" \
    SWEEP_BAT_DIR="$t/sweep" GRAPHMAP_BAT_DIR="$t/graphmap-empty" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" \
    bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C8-cadence: codex-sweep-cadence runners are stale' \
    && grepq "$out" 'bash scripts/cleanup/codex-sweep-cadence.sh arm --force'; then
    pass "C8 -> WARN (stale codex-sweep runner)"
else
    fail "C8 -> $(printf '%s' "$out" | grep C8)"
fi
rm -rf "$t"

echo "== C8: stale graphmap runner -> WARN + graphmap re-arm hint =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/graphmap"; write_settings "$t/claude" "$WRAPPER"
printf '#!/bin/sh\n# himmel-cadence-runner-format: %s\necho old graphmap\n' "$STALE_CADENCE_VER" > "$t/graphmap/graphmap-luna.sh"
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" PIPELINE_BAT_DIR="$t/pipeline-empty" \
    SWEEP_BAT_DIR="$t/sweep-empty" GRAPHMAP_BAT_DIR="$t/graphmap" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" \
    bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C8-cadence: graphmap-cadence runners are stale' \
    && grepq "$out" 'bash scripts/luna/graphmap-cadence.sh arm --force'; then
    pass "C8 -> WARN (stale graphmap runner)"
else
    fail "C8 -> $(printf '%s' "$out" | grep C8)"
fi
rm -rf "$t"

echo "== C8: stale qmd runner -> WARN + qmd re-arm hint =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/qmd"; write_settings "$t/claude" "$WRAPPER"
printf '#!/bin/sh\n# himmel-cadence-runner-format: %s\necho old qmd\n' "$STALE_CADENCE_VER" > "$t/qmd/qmd-reindex.sh"
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" PIPELINE_BAT_DIR="$t/pipeline-empty" \
    SWEEP_BAT_DIR="$t/sweep-empty" GRAPHMAP_BAT_DIR="$t/graphmap-empty" \
    QMD_CADENCE_BAT_DIR="$t/qmd" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" \
    bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C8-cadence: qmd-cadence runners are stale' \
    && grepq "$out" 'bash scripts/luna/qmd-cadence.sh arm --force'; then
    pass "C8 -> WARN (stale qmd runner)"
else
    fail "C8 -> $(printf '%s' "$out" | grep C8)"
fi
rm -rf "$t"

echo "== C8: pipeline-only current runner -> OK, no false nudges =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/pipeline"; write_settings "$t/claude" "$WRAPPER"
printf '#!/bin/sh\n# himmel-cadence-runner-format: %s\necho current runner\n' "$CADENCE_VER" > "$t/pipeline/pipeline-harvest.sh"
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" PIPELINE_BAT_DIR="$t/pipeline" \
    SWEEP_BAT_DIR="$t/sweep-empty" GRAPHMAP_BAT_DIR="$t/graphmap-empty" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" \
    bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C8-cadence: pipeline-cadence runners current' \
    && ! grepq "$out" 'WARN C8-cadence'; then
    pass "C8 -> OK (pipeline-only current runner)"
else
    fail "C8 -> $(printf '%s' "$out" | grep C8)"
fi
rm -rf "$t"

echo "== C9 linux at+atd live -> OK =="
t="$(mktemp -d)"; b="$t/bin"; mkdir -p "$b"
printf '#!/bin/sh\nexit 0\n' > "$b/at"; chmod +x "$b/at"
out="$(SCHEDULER_BACKEND_OS=linux SCHEDULER_BACKEND_ATD_ACTIVE=1 PATH="$b:$TOOLS_PATH" \
       CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C9-scheduler'; then pass "C9 linux ok"; else fail "C9 linux ok: $(printf '%s' "$out" | grep C9)"; fi
rm -rf "$t"

echo "== C9 linux at+atd dead -> WARN + remediation =="
t="$(mktemp -d)"; b="$t/bin"; mkdir -p "$b"
printf '#!/bin/sh\nexit 0\n' > "$b/at"; chmod +x "$b/at"
out="$(SCHEDULER_BACKEND_OS=linux SCHEDULER_BACKEND_ATD_ACTIVE=0 PATH="$b:$TOOLS_PATH" \
       CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C9-scheduler'; then pass "C9 linux disabled WARN"; else fail "C9 disabled: $(printf '%s' "$out" | grep C9)"; fi
if grepq "$out" 'systemctl enable --now atd'; then pass "C9 remediation shown"; else fail "C9 remediation missing"; fi
rm -rf "$t"

echo "== C9 macos crontab -> WARN ok-cron, NOT 'install at' =="
t="$(mktemp -d)"; b="$t/bin"; mkdir -p "$b"
printf '#!/bin/sh\nexit 0\n' > "$b/crontab"; chmod +x "$b/crontab"
out="$(SCHEDULER_BACKEND_OS=macos PATH="$b:$TOOLS_PATH" \
       CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C9-scheduler'; then pass "C9 macos warn"; else fail "C9 macos: $(printf '%s' "$out" | grep C9)"; fi
if grepq "$out" 'apt install'; then fail "C9 macos wrongly suggests apt"; else pass "C9 macos no apt advice"; fi
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
if grepq "$out" 'OK   C10-propagation' && [ "$rc" -eq 0 ]; then pass "C10 -> OK (skip, no clone)"; else fail "C10 -> rc=$rc; $(printf '%s' "$out" | grep C10)"; fi
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
    if grepq "$out" 'WARN C10-propagation' && grepq "$out" 'onlypriv.md'; then pass "C10 -> WARN (seeded drift, MISSING flagged)"; else fail "C10 -> $(printf '%s' "$out" | grep -A6 C10)"; fi
else
    if grepq "$out" 'OK   C10-propagation' && grepq "$out" 'skipped (no private mirror tooling)'; then pass "C10 -> skip (public checkout, no mirror tooling)"; else fail "C10 -> $(printf '%s' "$out" | grep -A6 C10)"; fi
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
    if grepq "$out" 'WARN C10-propagation' && ! grepq "$out" 'OK   C10-propagation'; then pass "C10 -> WARN (unreadable refs, not false-clean)"; else fail "C10 unreadable -> $(printf '%s' "$out" | grep -A4 C10)"; fi
else
    if grepq "$out" 'OK   C10-propagation' && grepq "$out" 'skipped (no private mirror tooling)'; then pass "C10 -> skip (public checkout, no mirror tooling)"; else fail "C10 unreadable -> $(printf '%s' "$out" | grep -A4 C10)"; fi
fi
rm -rf "$t"

echo "== C13: himmel-ops hooks.json target missing -> WARN C13-plugin-hooks =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/plugin-hooks"; write_settings "$t/claude" "$WRAPPER"
cat > "$t/plugin-hooks/hooks.json" <<'EOF'
{ "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "bash -c 'h=\"$CLAUDE_PROJECT_DIR/scripts/hooks/no-such-hook.sh\"; if [ -f \"$h\" ]; then exec bash \"$h\"; fi'" } ] } ] } } }
EOF
out="$(DOCTOR_HIMMEL_OPS_HOOKS_JSON="$t/plugin-hooks/hooks.json" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C13-plugin-hooks' && grepq "$out" 'scripts/hooks/no-such-hook.sh'; then pass "C13 -> WARN (missing hook target)"; else fail "C13 -> $(printf '%s' "$out" | grep C13)"; fi
rm -rf "$t"

echo "== C13: shipped himmel-ops hooks.json targets exist -> OK C13-plugin-hooks =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C13-plugin-hooks'; then pass "C13 -> OK (shipped hook targets exist)"; else fail "C13 -> $(printf '%s' "$out" | grep C13)"; fi
rm -rf "$t"

# ── C14: ollama zero-egress defense-in-depth pin (OLLAMA_NO_CLOUD) ────────────
FAKEOLLAMA="$FAKEROOT/ollamabin"; mkdir -p "$FAKEOLLAMA"
printf '#!/bin/sh\necho ollama version fake\n' > "$FAKEOLLAMA/ollama"; chmod +x "$FAKEOLLAMA/ollama"

# Scope DOCTOR_WORKTREE_ROOT at a plain (non-git) empty dir so C7's `git
# worktree list` finds nothing and short-circuits to OK immediately, instead
# of scanning this checkout's real worktrees/branches — a real worktree
# branch forces a live gh/forge call that can hang well past its own timeout
# on some hosts (HIMMEL-784 investigation; filed separately), unrelated to
# C14 itself.
C14_WT_ROOT="$FAKEROOT/c14-empty"; mkdir -p "$C14_WT_ROOT"

echo "== C14: ollama not on PATH -> OK C14-ollama-no-cloud (skipped) =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
out="$(PATH="$TOOLS_PATH" DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C14-ollama-no-cloud' && grepq "$out" 'not on PATH'; then pass "C14 -> OK (ollama absent, skipped)"; else fail "C14 absent -> $(printf '%s' "$out" | grep C14)"; fi
rm -rf "$t"

echo "== C14: ollama present, OLLAMA_NO_CLOUD unset -> WARN C14-ollama-no-cloud =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
out="$(PATH="$FAKEOLLAMA:$TOOLS_PATH" DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" env -u OLLAMA_NO_CLOUD bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C14-ollama-no-cloud' && grepq "$out" 'pin unset'; then pass "C14 -> WARN (ollama present, pin unset)"; else fail "C14 unset -> $(printf '%s' "$out" | grep C14)"; fi
rm -rf "$t"

echo "== C14: ollama present, OLLAMA_NO_CLOUD=1 -> OK C14-ollama-no-cloud =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
out="$(PATH="$FAKEOLLAMA:$TOOLS_PATH" OLLAMA_NO_CLOUD=1 DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C14-ollama-no-cloud' && grepq "$out" 'pin is set'; then pass "C14 -> OK (pin set)"; else fail "C14 set -> $(printf '%s' "$out" | grep C14)"; fi
rm -rf "$t"

# ── C16: delegate to `himmelctl status --json` for install/wiring truth (HIMMEL-755 F) ──
# winpath <path> — MSYS/cygwin path -> Windows form (node.exe misresolves
# MSYS /tmp-style paths for HIMMELCTL_REPO_ROOT/HIMMELCTL_CACHE_DIR), mirrors
# scripts/himmelctl/test/test-wizard-status-cmd.sh's own helper.
winpath() {
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) cygpath -m "$1" 2>/dev/null || printf '%s' "$1" ;;
        *) printf '%s' "$1" ;;
    esac
}

echo "== C16: no himmelctl install profile -> INFO graceful skip, exit 0 =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
EMPTYCACHE="$t/cache-empty"; mkdir -p "$EMPTYCACHE"
out="$(HIMMELCTL_CACHE_DIR="$(winpath "$EMPTYCACHE")" DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'INFO C16-status' && grepq "$out" 'no himmelctl install profile found' && [ "$rc" -eq 0 ]; then
    pass "C16 -> INFO (no profile, graceful skip, rc0)"
else
    fail "C16 no-profile -> rc=$rc; $(printf '%s' "$out" | grep C16)"
fi
rm -rf "$t"

if command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    echo "== C16: himmelctl status reports a red item -> WARN C16-status surfaces it =="
    t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"

    # A minimal himmelctl fixture repo (real manifest.json + the repoRoot-
    # relative files its file-exists probes read), mirroring
    # test-wizard-status-cmd.sh's fixtureRepo.
    fixtureRepo="$t/fixture-repo"
    mkdir -p "$fixtureRepo/scripts/install" "$fixtureRepo/scripts/jira/dist" "$fixtureRepo/scripts/bitbucket/dist" "$fixtureRepo/scripts/lib"
    cp "$REPO_ROOT/scripts/install/manifest.json" "$fixtureRepo/scripts/install/manifest.json"
    : > "$fixtureRepo/scripts/jira/dist/index.js"
    : > "$fixtureRepo/scripts/bitbucket/dist/index.js"
    : > "$fixtureRepo/scripts/lib/doc-guard-map.sh"

    targetC16="$t/target"
    mkdir -p "$targetC16/.claude" "$targetC16/scripts/guardrails"
    : > "$targetC16/scripts/guardrails/lib.sh"
    # Deliberately NO .pre-commit-config.yaml — the known-red item this case
    # asserts gets surfaced (mirrors test-wizard-status-cmd.sh case b).
    cat > "$targetC16/.claude/settings.json" <<'JSON'
{"statusLine":{"command":"bash foo.sh"},"enabledPlugins":{"foo@bar":true}}
JSON
    cacheC16="$t/cache"; mkdir -p "$cacheC16"
    cat > "$cacheC16/install-profile.json" <<'JSON'
{"role":"adopter","tier":"standard","scope":"project","vault":{"mode":"none","path":""},"handover":{"mode":"inline","path":""},"pluginSet":"lean","lanes":[],"lanesMeaningful":true,"alwaysOn":false}
JSON

    out="$(cd "$targetC16" && HIMMELCTL_REPO_ROOT="$(winpath "$fixtureRepo")" HIMMELCTL_CACHE_DIR="$(winpath "$cacheC16")" \
        DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
        CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
    # Assert both within the SAME C16 block: capture from the WARN C16-status
    # line up to (but not including) the next severity-prefixed check line, and
    # require pre-commit-hooks to appear as one of its detail rows (rather than
    # matching the two strings independently anywhere in the full doctor output,
    # or slurping trailing lines past the C16 block — robust even if a check is
    # ever added after C16).
    c16block="$(printf '%s\n' "$out" | awk '
        /WARN[[:space:]]+C16-status/ { capture = 1; next }
        capture && /^(FAIL|WARN|INFO|OK)[[:space:]]/ { exit }
        capture { print }
    ')"
    if [ -n "$c16block" ] && grepq "$c16block" 'pre-commit-hooks'; then
        pass "C16 -> WARN (delegated red item surfaced)"
    else
        fail "C16 red-item -> $(printf '%s' "$out" | grep -A6 C16-status)"
    fi
    rm -rf "$t"
else
    pass "C16 -> WARN (skipped: node/jq not both available on this host)"
fi

# ── C17: dependency readiness -- enabled skill vs required API key (HIMMEL-1393) ──
echo "== C17: skill not enabled -> OK (nothing to check, no false-positive) =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/claude/commands"; write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'OK   C17-dep-readiness' && [ "$rc" -eq 0 ]; then
    pass "C17 -> OK (no declared skill enabled)"
else
    fail "C17 not-enabled -> rc=$rc; $(printf '%s' "$out" | grep C17)"
fi
rm -rf "$t"

echo "== C17: enabled + keyed + doc clean -> OK C17-dep-readiness =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/claude/commands" "$t/home/.config/obsidian-second-brain"
write_settings "$t/claude" "$WRAPPER"
printf 'x-read command\n' > "$t/claude/commands/x-read.md"
printf 'XAI_API_KEY=abc123\n' > "$t/home/.config/obsidian-second-brain/.env"
printf 'nothing stale here\n' > "$t/catalog.md"
out="$(DEP_READY_CATALOG="$t/catalog.md" DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'OK   C17-dep-readiness' && [ "$rc" -eq 0 ]; then
    pass "C17 -> OK (enabled, keyed, doc clean)"
else
    fail "C17 clean -> rc=$rc; $(printf '%s' "$out" | grep C17)"
fi
rm -rf "$t"

echo "== C17: enabled but key absent -> WARN C17-dep-readiness (key-missing) =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/claude/commands" "$t/home/.config/obsidian-second-brain"
write_settings "$t/claude" "$WRAPPER"
printf 'x-read command\n' > "$t/claude/commands/x-read.md"
printf 'SOME_OTHER_KEY=x\n' > "$t/home/.config/obsidian-second-brain/.env"
printf 'nothing stale here\n' > "$t/catalog.md"
out="$(DEP_READY_CATALOG="$t/catalog.md" DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'WARN C17-dep-readiness' && grepq "$out" 'x-read is enabled but XAI_API_KEY is absent/blank' && [ "$rc" -eq 0 ]; then
    pass "C17 -> WARN (key-missing, never-fatal)"
else
    fail "C17 key-missing -> rc=$rc; $(printf '%s' "$out" | grep -A4 C17)"
fi
rm -rf "$t"

echo "== C17: enabled + keyed but catalog still says disabled -> WARN (doc-disabled) =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/claude/commands" "$t/home/.config/obsidian-second-brain"
write_settings "$t/claude" "$WRAPPER"
printf 'x-read command\n' > "$t/claude/commands/x-read.md"
printf 'XAI_API_KEY=abc123\n' > "$t/home/.config/obsidian-second-brain/.env"
printf '**Research toolkit:** disabled (needs XAI + Perplexity API keys)\n' > "$t/catalog.md"
out="$(DEP_READY_CATALOG="$t/catalog.md" DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'WARN C17-dep-readiness' && grepq "$out" 'x-read is enabled+keyed but a doc still marks its toolkit disabled' && [ "$rc" -eq 0 ]; then
    pass "C17 -> WARN (doc-disabled, never-fatal)"
else
    fail "C17 doc-disabled -> rc=$rc; $(printf '%s' "$out" | grep -A4 C17)"
fi
rm -rf "$t"

echo "== C17: enabled but key is quoted-empty (KEY=\"\") -> WARN (key-missing) =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/claude/commands" "$t/home/.config/obsidian-second-brain"
write_settings "$t/claude" "$WRAPPER"
printf 'x-read command\n' > "$t/claude/commands/x-read.md"
printf 'XAI_API_KEY=""\n' > "$t/home/.config/obsidian-second-brain/.env"
printf 'nothing stale here\n' > "$t/catalog.md"
out="$(DEP_READY_CATALOG="$t/catalog.md" DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'WARN C17-dep-readiness' && grepq "$out" 'x-read is enabled but XAI_API_KEY is absent/blank' && [ "$rc" -eq 0 ]; then
    pass "C17 -> WARN (quoted-empty value treated as missing)"
else
    fail "C17 quoted-empty -> rc=$rc; $(printf '%s' "$out" | grep -A4 C17)"
fi
rm -rf "$t"

echo "== C17: enabled but key is quoted whitespace-only (KEY=\"   \") -> WARN (key-missing) =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/claude/commands" "$t/home/.config/obsidian-second-brain"
write_settings "$t/claude" "$WRAPPER"
printf 'x-read command\n' > "$t/claude/commands/x-read.md"
printf 'XAI_API_KEY="   "\n' > "$t/home/.config/obsidian-second-brain/.env"
printf 'nothing stale here\n' > "$t/catalog.md"
out="$(DEP_READY_CATALOG="$t/catalog.md" DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'WARN C17-dep-readiness' && grepq "$out" 'x-read is enabled but XAI_API_KEY is absent/blank' && [ "$rc" -eq 0 ]; then
    pass "C17 -> WARN (quoted whitespace-only value treated as missing)"
else
    fail "C17 quoted-whitespace -> rc=$rc; $(printf '%s' "$out" | grep -A4 C17)"
fi
rm -rf "$t"

# ── C18: monitored zero-usage command cluster (2026-07-29 skill-hygiene spec) ──
echo "== C18: monitored command absent (removed) -> OK, never flagged =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/c18cmds"; write_settings "$t/claude" "$WRAPPER"
OLD="$(date -d '-90 days' +%Y-%m-%d 2>/dev/null || date -v-90d +%Y-%m-%d 2>/dev/null)"
out="$(DOCTOR_C18_COMMANDS_DIR="$t/c18cmds" DOCTOR_C18_MONITORED_OVERRIDE="removed-tool|$OLD|99" \
    DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'OK   C18-skill-usage' && [ "$rc" -eq 0 ]; then
    pass "C18 -> OK (removed command silently drops out)"
else
    fail "C18 removed -> rc=$rc; $(printf '%s' "$out" | grep C18)"
fi
rm -rf "$t"

echo "== C18: present + fresh (age<30d) -> OK, not flagged =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/c18cmds"; write_settings "$t/claude" "$WRAPPER"
FRESH="$(date -d '-10 days' +%Y-%m-%d 2>/dev/null || date -v-10d +%Y-%m-%d 2>/dev/null)"
printf 'fresh command\n' > "$t/c18cmds/fresh-tool.md"
out="$(DOCTOR_C18_COMMANDS_DIR="$t/c18cmds" DOCTOR_C18_MONITORED_OVERRIDE="fresh-tool|$FRESH|99" \
    DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'OK   C18-skill-usage' && [ "$rc" -eq 0 ]; then
    pass "C18 -> OK (fresh, under both thresholds)"
else
    fail "C18 fresh -> rc=$rc; $(printf '%s' "$out" | grep C18)"
fi
rm -rf "$t"

echo "== C18: present + age>60d -> WARN C18-skill-usage =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/c18cmds"; write_settings "$t/claude" "$WRAPPER"
STALE="$(date -d '-70 days' +%Y-%m-%d 2>/dev/null || date -v-70d +%Y-%m-%d 2>/dev/null)"
printf 'stale command\n' > "$t/c18cmds/stale-tool.md"
out="$(DOCTOR_C18_COMMANDS_DIR="$t/c18cmds" DOCTOR_C18_MONITORED_OVERRIDE="stale-tool|$STALE|10" \
    DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'WARN C18-skill-usage' && grepq "$out" 'stale-tool' && [ "$rc" -eq 0 ]; then
    pass "C18 -> WARN (age>60d, never-fatal)"
else
    fail "C18 stale -> rc=$rc; $(printf '%s' "$out" | grep -A4 C18)"
fi
rm -rf "$t"

echo "== C18: present + age>30d AND cost>50 -> WARN C18-skill-usage (pricier caught sooner) =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/c18cmds"; write_settings "$t/claude" "$WRAPPER"
MID="$(date -d '-40 days' +%Y-%m-%d 2>/dev/null || date -v-40d +%Y-%m-%d 2>/dev/null)"
printf 'pricier command\n' > "$t/c18cmds/pricier-tool.md"
out="$(DOCTOR_C18_COMMANDS_DIR="$t/c18cmds" DOCTOR_C18_MONITORED_OVERRIDE="pricier-tool|$MID|71" \
    DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'WARN C18-skill-usage' && grepq "$out" 'pricier-tool' && [ "$rc" -eq 0 ]; then
    pass "C18 -> WARN (age>30d + cost>50, never-fatal)"
else
    fail "C18 pricier -> rc=$rc; $(printf '%s' "$out" | grep -A4 C18)"
fi
rm -rf "$t"

echo "== C18: present + age>30d, cost<=50 -> OK, not flagged (below both thresholds) =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/c18cmds"; write_settings "$t/claude" "$WRAPPER"
MID="$(date -d '-40 days' +%Y-%m-%d 2>/dev/null || date -v-40d +%Y-%m-%d 2>/dev/null)"
printf 'cheap command\n' > "$t/c18cmds/cheap-tool.md"
out="$(DOCTOR_C18_COMMANDS_DIR="$t/c18cmds" DOCTOR_C18_MONITORED_OVERRIDE="cheap-tool|$MID|10" \
    DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'OK   C18-skill-usage' && [ "$rc" -eq 0 ]; then
    pass "C18 -> OK (age>30d but cost<=50, below both thresholds)"
else
    fail "C18 cheap-mid-age -> rc=$rc; $(printf '%s' "$out" | grep C18)"
fi
rm -rf "$t"

# ── C19: installed observability drift + local endpoint readiness ──────────────
# The rule-group assertions below depend on check_c19 successfully parsing the
# stub Prometheus response with jq (codex-1 CR finding, HIMMEL-1676) — on a
# jq-less host check_c19 takes its own "jq unavailable" fallback path instead,
# so both C19 cases branch their expectation on the SAME probe check_c19 itself
# uses, rather than assuming jq is present.
have_jq_c19=0
command -v jq >/dev/null 2>&1 && have_jq_c19=1

echo "== C19: stale assets + empty rules + unset delivery + dead exporter -> WARNs, rc0 =="
t="$(mktemp -d -t himmel-doctor-c19.XXXXXX)"; mkdir -p "$t/claude" "$t/install/grafana-provisioning" "$t/bin"; write_settings "$t/claude" "$WRAPPER"
printf 'stale prometheus\n' > "$t/install/prometheus.yml"
printf 'stale rules\n' > "$t/install/alerts.rules.yml"
printf 'stale provisioning\n' > "$t/install/grafana-provisioning/stale.yaml"
cat > "$t/bin/curl" <<'EOF'
#!/bin/sh
url=''
for arg in "$@"; do url="$arg"; done
case "$url" in
  */api/v1/rules) printf '%s\n' '{"status":"success","data":{"groups":[]}}' ;;
  *:9877/metrics) exit 7 ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$t/bin/curl"
out="$(DOCTOR_OBSERVABILITY_SKIP=0 DOCTOR_OBSERVABILITY_INSTALL_DIR="$t/install" DOCTOR_CURL_BIN="$t/bin/curl" \
    GRAFANA_TELEGRAM_BOT_TOKEN="" GRAFANA_TELEGRAM_CHAT_ID="" \
    DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if [ "$have_jq_c19" -eq 1 ]; then
    rules_expect='Prometheus has zero rule groups'
else
    rules_expect='jq unavailable'
fi
if [ "$rc" -eq 0 ] \
    && grepq "$out" 'observability stack stale — re-run install-stack.ps1' \
    && grepq "$out" "$rules_expect" \
    && grepq "$out" 'Grafana Telegram delivery variable(s) unset' \
    && grepq "$out" 'flow exporter on http://127.0.0.1:9877/metrics is not answering' \
    && grepq "$out" 'Grafana on http://127.0.0.1:3000/api/health is not answering'; then
    pass "C19 -> all five observability drift/readiness WARNs, never-fatal"
else
    fail "C19 unhealthy -> rc=$rc; $(printf '%s' "$out" | grep C19)"
fi
rm -rf "$t"

echo "== C19: matching assets + nonempty rules + delivery vars + live exporter -> all OK =="
t="$(mktemp -d -t himmel-doctor-c19.XXXXXX)"; mkdir -p "$t/claude" "$t/install/grafana-provisioning" "$t/bin"; write_settings "$t/claude" "$WRAPPER"
cp "$REPO_ROOT/scripts/observability/prometheus.yml" "$t/install/prometheus.yml"
cp "$REPO_ROOT/scripts/observability/alerts.rules.yml" "$t/install/alerts.rules.yml"
cp -R "$REPO_ROOT/scripts/observability/provisioning/." "$t/install/grafana-provisioning/"
cat > "$t/bin/curl" <<'EOF'
#!/bin/sh
url=''
for arg in "$@"; do url="$arg"; done
case "$url" in
  */api/v1/rules) printf '%s\n' '{"status":"success","data":{"groups":[{"name":"himmel-observability"}]}}' ;;
  *:9877/metrics) printf '%s\n' 'flow_run_outcome_total 1' ;;
  *:3000/api/health) printf '%s\n' '{"database":"ok","version":"test"}' ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$t/bin/curl"
out="$(DOCTOR_OBSERVABILITY_SKIP=0 DOCTOR_OBSERVABILITY_INSTALL_DIR="$t/install" DOCTOR_CURL_BIN="$t/bin/curl" \
    GRAFANA_TELEGRAM_BOT_TOKEN="test-token" GRAFANA_TELEGRAM_CHAT_ID="123" \
    DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if [ "$have_jq_c19" -eq 1 ]; then
    rules_expect='Prometheus reports 1 rule group(s)'
else
    rules_expect='jq unavailable'
fi
if [ "$rc" -eq 0 ] \
    && ! grepq "$out" 'WARN C19-observability' \
    && grepq "$out" 'installed observability assets match the repo copies' \
    && grepq "$out" "$rules_expect" \
    && grepq "$out" 'flow exporter answers on http://127.0.0.1:9877/metrics' \
    && grepq "$out" 'Grafana answers on http://127.0.0.1:3000/api/health'; then
    pass "C19 -> matching stack and live endpoints report OK"
else
    fail "C19 healthy -> rc=$rc; $(printf '%s' "$out" | grep C19)"
fi
rm -rf "$t"

echo "== C19: cmp/diff unavailable -> INFO, never claims assets match (HIMMEL-1676 regression) =="
# A curated symlink PATH (NOGH's trick) doesn't run on Windows Git Bash (its
# .exe symlinks don't execute — see the gh-absent case above), and copying just
# the named tools leaves their MSYS/mingw DLL deps unresolved (colocated-DLL
# search fails once the tool is copied out of its own dir). Copy the whole
# /usr/bin + /mingw64/bin trees (DLLs travel with their tools) minus cmp/diff/
# diff3, plus jq (installed outside those trees on this box), so the doctor's
# OTHER checks still run normally while cmp/diff are genuinely absent from PATH.
NOCMPDIFF="$FAKEROOT/nocmpdiff"
if [ ! -d "$NOCMPDIFF" ]; then
    mkdir -p "$NOCMPDIFF"
    for _d in /usr/bin /mingw64/bin; do
        [ -d "$_d" ] && cp -r "$_d/." "$NOCMPDIFF/" 2>/dev/null
    done
    rm -f "$NOCMPDIFF/cmp" "$NOCMPDIFF/cmp.exe" "$NOCMPDIFF/diff" "$NOCMPDIFF/diff.exe" "$NOCMPDIFF/diff3" "$NOCMPDIFF/diff3.exe"
    _jq_src="$(command -v jq 2>/dev/null)" && cp "$_jq_src" "$NOCMPDIFF/jq.exe" 2>/dev/null
fi
if PATH="$NOCMPDIFF" bash -c 'git --version >/dev/null 2>&1 && ! command -v cmp >/dev/null 2>&1 && ! command -v diff >/dev/null 2>&1' 2>/dev/null; then
    t="$(mktemp -d -t himmel-doctor-c19.XXXXXX)"; mkdir -p "$t/claude" "$t/install/grafana-provisioning" "$t/bin"; write_settings "$t/claude" "$WRAPPER"
    cp "$REPO_ROOT/scripts/observability/prometheus.yml" "$t/install/prometheus.yml"
    cp "$REPO_ROOT/scripts/observability/alerts.rules.yml" "$t/install/alerts.rules.yml"
    cp -R "$REPO_ROOT/scripts/observability/provisioning/." "$t/install/grafana-provisioning/"
    cat > "$t/bin/curl" <<'EOF'
#!/bin/sh
url=''
for arg in "$@"; do url="$arg"; done
case "$url" in
  */api/v1/rules) printf '%s\n' '{"status":"success","data":{"groups":[{"name":"himmel-observability"}]}}' ;;
  *:9877/metrics) printf '%s\n' 'flow_run_outcome_total 1' ;;
  *:3000/api/health) printf '%s\n' '{"database":"ok","version":"test"}' ;;
  *) exit 22 ;;
esac
EOF
    chmod +x "$t/bin/curl"
    out="$(PATH="$NOCMPDIFF" DOCTOR_OBSERVABILITY_SKIP=0 DOCTOR_OBSERVABILITY_INSTALL_DIR="$t/install" DOCTOR_CURL_BIN="$t/bin/curl" \
        GRAFANA_TELEGRAM_BOT_TOKEN="test-token" GRAFANA_TELEGRAM_CHAT_ID="123" \
        DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
        CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] \
        && grepq "$out" 'cmp/diff unavailable — installed observability assets not compared' \
        && ! grepq "$out" 'installed observability assets match the repo copies'; then
        pass "C19 -> cmp/diff unavailable emits INFO, never claims a match it never checked"
    else
        fail "C19 cmp/diff-unavailable -> rc=$rc; $(printf '%s' "$out" | grep C19)"
    fi
    rm -rf "$t"
else
    pass "C19 cmp/diff-unavailable -> (skipped: could not build a cmp/diff-less PATH on this host)"
fi

# ── C20: running node major vs .nvmrc (HIMMEL-1986 / HIMMEL-2010) ─────────────
# The drift is a FAIL now (HIMMEL-2010) — the doctor still never edits .nvmrc or
# switches a runtime, it just refuses to let the two disagree silently. CI and
# NODE_MAJOR_DRIFT_OK=1 keep it visible as a non-fatal WARN.
C20_NODE="$FAKEROOT/c20node"; mkdir -p "$C20_NODE"
# Baked per case, not read from the env at run time: an env-expanding stub body
# has to be single-quoted, which shellcheck reads as SC2016.
c20_node_stub() { printf '#!/bin/sh\necho %s\n' "$1" > "$C20_NODE/node"; chmod +x "$C20_NODE/node"; }

echo "== C20: node major != .nvmrc -> FAIL C20-node, fatal =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
printf '24\n' > "$t/nvmrc"; c20_node_stub v26.7.0
out="$(DOCTOR_NVMRC="$t/nvmrc" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" NODE_MAJOR_DRIFT_OK=0 CI="" GITHUB_ACTIONS="" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" PATH="$C20_NODE:$PATH" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'FAIL C20-node' && grepq "$out" 'v26.7.0' && grepq "$out" 'pins 24' && [ "$rc" -eq 1 ]; then
    pass "C20 -> FAIL (running major != pin, exit 1)"
else
    fail "C20 drift -> rc=$rc; $(printf '%s' "$out" | grep -A2 C20)"
fi
# The bypass and CI both downgrade the same finding to a non-fatal WARN.
out="$(DOCTOR_NVMRC="$t/nvmrc" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" NODE_MAJOR_DRIFT_OK=1 CI="" GITHUB_ACTIONS="" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" PATH="$C20_NODE:$PATH" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'WARN C20-node' && grepq "$out" 'NODE_MAJOR_DRIFT_OK=1' && [ "$rc" -eq 0 ]; then
    pass "C20 -> WARN under NODE_MAJOR_DRIFT_OK=1 (bypass honoured, exit 0)"
else
    fail "C20 bypass -> rc=$rc; $(printf '%s' "$out" | grep -A2 C20)"
fi
out="$(DOCTOR_NVMRC="$t/nvmrc" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" NODE_MAJOR_DRIFT_OK=0 CI=true GITHUB_ACTIONS="" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" PATH="$C20_NODE:$PATH" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'WARN C20-node' && grepq "$out" -F 'CI — advisory here' && [ "$rc" -eq 0 ]; then
    pass "C20 -> WARN under \$CI (a runner's node is not this operator's to fix)"
else
    fail "C20 under CI -> rc=$rc; $(printf '%s' "$out" | grep -A2 C20)"
fi
# ...and it never edits the pin it complains about.
if [ "$(cat "$t/nvmrc")" = "24" ]; then
    pass "C20 left .nvmrc untouched (the bump is an operator decision)"
else
    fail "C20 rewrote .nvmrc to '$(cat "$t/nvmrc")'"
fi
rm -rf "$t"

echo "== C20: node major == .nvmrc -> OK (negative control) =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
printf 'v24\n' > "$t/nvmrc"; c20_node_stub v24.9.0
out="$(DOCTOR_NVMRC="$t/nvmrc" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" PATH="$C20_NODE:$PATH" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'OK   C20-node' && ! grepq "$out" 'WARN C20-node' && [ "$rc" -eq 0 ]; then
    pass "C20 -> OK (aligned major, no false drift)"
else
    fail "C20 aligned -> rc=$rc; $(printf '%s' "$out" | grep -A2 C20)"
fi
rm -rf "$t"

echo "== C20: a version-shaped-but-unreadable node is never reported as aligned =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
printf '24\n' > "$t/nvmrc"; c20_node_stub v24-corrupt
out="$(DOCTOR_NVMRC="$t/nvmrc" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" PATH="$C20_NODE:$PATH" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'INFO C20-node' && ! grepq "$out" 'matches the .nvmrc pin' && [ "$rc" -eq 0 ]; then
    pass "C20 -> INFO (unreadable version, never a false 'aligned')"
else
    fail "C20 unreadable -> rc=$rc; $(printf '%s' "$out" | grep -A2 C20)"
fi
rm -rf "$t"

# ── C21: hermes himmel_agent profile default vs lanes.json record ─────────────
LANES_JSON="$REPO_ROOT/scripts/lanes/lanes.json"
EXPECTED_MODEL="$(jq -r '.lanes[] | select(.id=="hermes-oneshot") | .profileDefaultModel // empty' "$LANES_JSON" 2>/dev/null)"

# CRLF, like the operator's real %LOCALAPPDATA%/hermes files, to prove the
# parser survives the only line ending the real fixture actually has.
echo "== C21: hermes profile default matches lanes.json (CRLF fixture) -> OK =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
h="$t/hermes"; mkdir -p "$h/profiles/himmel_agent"
printf 'himmel_agent\r\n' > "$h/active_profile"
printf 'model:\r\n  default: %s\r\nother:\r\n  key: val\r\n' "$EXPECTED_MODEL" > "$h/profiles/himmel_agent/config.yaml"
out="$(DOCTOR_HERMES_HOME="$h" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'OK   C21-hermes-profile' && [ "$rc" -eq 0 ]; then
    pass "C21 -> OK (profile default matches lanes.json, CRLF fixture)"
else
    fail "C21 match -> rc=$rc; $(printf '%s' "$out" | grep -A2 C21)"
fi
rm -rf "$t"

# Quoted + commented scalar (a YAML dumper's cosmetic re-write of the same
# value) must not read as drift — an advisory check false-WARNing on a
# no-op re-dump is the exact noise this check exists to avoid.
echo "== C21: quoted + commented model.default (same value) -> OK, not a false WARN =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
h="$t/hermes"; mkdir -p "$h/profiles/himmel_agent"
printf 'himmel_agent\n' > "$h/active_profile"
printf 'model:\n  default: "%s"  # pinned\n' "$EXPECTED_MODEL" > "$h/profiles/himmel_agent/config.yaml"
out="$(DOCTOR_HERMES_HOME="$h" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'OK   C21-hermes-profile' && [ "$rc" -eq 0 ]; then
    pass "C21 -> OK (quoted + commented value parses to the same model)"
else
    fail "C21 quoted -> rc=$rc; $(printf '%s' "$out" | grep -A2 C21)"
fi
rm -rf "$t"

echo "== C21: SINGLE-quoted model.default (same value) -> OK, not a false WARN =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
h="$t/hermes"; mkdir -p "$h/profiles/himmel_agent"
printf 'himmel_agent\n' > "$h/active_profile"
printf "model:\n  default: '%s'\n" "$EXPECTED_MODEL" > "$h/profiles/himmel_agent/config.yaml"
out="$(DOCTOR_HERMES_HOME="$h" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'OK   C21-hermes-profile' && [ "$rc" -eq 0 ]; then
    pass "C21 -> OK (single-quoted value parses to the same model)"
else
    fail "C21 single-quoted -> rc=$rc; $(printf '%s' "$out" | grep -A2 C21)"
fi
rm -rf "$t"

echo "== C21: hermes profile default drifted from lanes.json -> WARN (never FAIL) =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
h="$t/hermes"; mkdir -p "$h/profiles/himmel_agent"
printf 'himmel_agent\n' > "$h/active_profile"
printf 'model:\n  default: some/other-model\n' > "$h/profiles/himmel_agent/config.yaml"
out="$(DOCTOR_HERMES_HOME="$h" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'WARN C21-hermes-profile' && grepq "$out" -F 'some/other-model' && [ "$rc" -eq 0 ]; then
    pass "C21 -> WARN on drift, advisory only (exit 0)"
else
    fail "C21 drift -> rc=$rc; $(printf '%s' "$out" | grep -A2 C21)"
fi
rm -rf "$t"

# HIMMEL-2437: with NO DOCTOR_HERMES_HOME/HERMES_HOME/LOCALAPPDATA override at
# all, check_c21's own default-root resolution must land on $HOME/.hermes —
# NEVER $HOME/AppData/Local/hermes (a Windows layout under a POSIX $HOME) and
# never $HOME/.local/share/hermes (the old non-hermes-upstream fallback). The
# suite's own global DOCTOR_HERMES_HOME hermeticity export is unset for this
# ONE invocation via `env -u`; no hermes install exists under the scratch
# HOME, so this stays the cheap "no hermes install found" INFO path while
# still proving the RESOLVED default path.
echo "== C21: no HERMES_HOME/LOCALAPPDATA override -> default root is \$HOME/.hermes =="
t="$(mktemp -d "${TMPDIR:-/tmp}/doctor-c21.XXXXXX")" || { echo "FAIL - mktemp -d failed"; exit 1; }
mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
out="$(env -u DOCTOR_HERMES_HOME -u HERMES_HOME -u LOCALAPPDATA \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" -F "no hermes install found ($t/home/.hermes)" && [ "$rc" -eq 0 ]; then
    pass "C21 -> default root resolves to \$HOME/.hermes when nothing overrides it (HIMMEL-2437)"
else
    fail "C21 default-root -> rc=$rc; $(printf '%s' "$out" | grep -A2 C21)"
fi
rm -rf "$t"

# codex-1 (round-2 /pr-check finding): a lanes.json where only ONE of the two
# hermes rows declares profileDefaultModel must WARN, not silently validate
# against the one row that happens to have it (the undeclared row's model
# would otherwise never be checked).
echo "== C21: only ONE hermes row declares profileDefaultModel -> WARN, not a silent OK =="
t="$(mktemp -d)"; mkdir -p "$t/claude"
lanes_one_missing="$t/lanes-one-missing.json"
printf '{"lanes":[{"id":"hermes-oneshot","profileDefaultModel":"%s"},{"id":"hermes-critics"}]}\n' "$EXPECTED_MODEL" > "$lanes_one_missing"
write_settings "$t/claude" "$WRAPPER"
h="$t/hermes"; mkdir -p "$h/profiles/himmel_agent"
printf 'himmel_agent\n' > "$h/active_profile"
printf 'model:\n  default: %s\n' "$EXPECTED_MODEL" > "$h/profiles/himmel_agent/config.yaml"
out="$(DOCTOR_HERMES_HOME="$h" DOCTOR_LANES_JSON="$lanes_one_missing" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'WARN C21-hermes-profile' && grepq "$out" -F 'only one of' && [ "$rc" -eq 0 ]; then
    pass "C21 -> WARN (one row missing profileDefaultModel is never a silent OK)"
else
    fail "C21 one-missing -> rc=$rc; $(printf '%s' "$out" | grep -A2 C21)"
fi
rm -rf "$t"

echo "== C21: no hermes install -> INFO, never a false OK/WARN =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_HERMES_HOME="$t/no-such-hermes-dir" \
    DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'INFO C21-hermes-profile' && ! grepq "$out" 'OK   C21-hermes-profile' && ! grepq "$out" 'WARN C21-hermes-profile' && [ "$rc" -eq 0 ]; then
    pass "C21 -> INFO (no hermes install, no false verdict)"
else
    fail "C21 no-install -> rc=$rc; $(printf '%s' "$out" | grep -A2 C21)"
fi
rm -rf "$t"

# ── C23: unlanded local work (HIMMEL-2070) ───────────────────────────────────
# make_c23_repo <dir> — a base "main" with an origin/main ref pointed at it
# (no real remote needed; unlanded-work.sh's default --base is origin/main).
make_c23_repo() {
    local d="$1"
    mkdir -p "$d"
    git -C "$d" init -q
    git -C "$d" config user.email t@t
    git -C "$d" config user.name t
    printf 'base\n' > "$d/base.md"
    git -C "$d" add base.md
    git -C "$d" commit -q -m init
    git -C "$d" branch -M main
    git -C "$d" update-ref refs/remotes/origin/main refs/heads/main
}

echo "== C23: no unlanded work -> OK C23-unlanded =="
t="$(mktemp -d)"; make_c23_repo "$t/repo"; write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_UNLANDED_DIR="$t/repo" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C23-unlanded'; then pass "C23 -> OK (no unlanded branches)"; else fail "C23 -> $(printf '%s' "$out" | grep C23)"; fi
rm -rf "$t"

echo "== C23: fresh UNLANDED-LIVE branch, no PR -> INFO (not aged) =="
t="$(mktemp -d)"; make_c23_repo "$t/repo"; write_settings "$t/claude" "$WRAPPER"
git -C "$t/repo" checkout -q -b feat/fresh-unlanded
printf 'work\n' > "$t/repo/work.md"; git -C "$t/repo" add work.md
# "@<unix-ts> +0000" — the one date form every git build parses unconditionally
# (this git build's GIT_AUTHOR_DATE rejects the approxidate keyword "now" outright:
# `fatal: invalid date format: now`).
GIT_AUTHOR_DATE="@$(date +%s) +0000" GIT_COMMITTER_DATE="@$(date +%s) +0000" git -C "$t/repo" commit -q -m "feat: add work"
git -C "$t/repo" checkout -q main
out="$(DOCTOR_UNLANDED_DIR="$t/repo" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    GH_CMD="$t/no-such-gh" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'INFO C23-unlanded' && grepq "$out" -F 'none aged' && ! grepq "$out" 'WARN C23-unlanded'; then
    pass "C23 -> INFO (fresh unlanded, not aged)"
else
    fail "C23 fresh -> $(printf '%s' "$out" | grep C23)"
fi
rm -rf "$t"

echo "== C23: AGED UNLANDED-LIVE branch, no PR -> WARN C23-unlanded =="
t="$(mktemp -d)"; make_c23_repo "$t/repo"; write_settings "$t/claude" "$WRAPPER"
git -C "$t/repo" checkout -q -b feat/aged-unlanded
printf 'work\n' > "$t/repo/work.md"; git -C "$t/repo" add work.md
GIT_AUTHOR_DATE="@$(( $(date +%s) - 50*3600 )) +0000" GIT_COMMITTER_DATE="@$(( $(date +%s) - 50*3600 )) +0000" git -C "$t/repo" commit -q -m "feat: add old work"
git -C "$t/repo" checkout -q main
out="$(DOCTOR_UNLANDED_DIR="$t/repo" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    GH_CMD="$t/no-such-gh" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C23-unlanded' && grepq "$out" -F 'aged unlanded'; then
    pass "C23 -> WARN (aged unlanded branch)"
else
    fail "C23 aged -> $(printf '%s' "$out" | grep C23)"
fi
rm -rf "$t"

echo "== C23: only a LANDED-ELSEWHERE branch (empty delta), no UNLANDED-LIVE -> INFO =="
t="$(mktemp -d)"; make_c23_repo "$t/repo"; write_settings "$t/claude" "$WRAPPER"
git -C "$t/repo" checkout -q -b feat/already-landed
printf 'extra\n' > "$t/repo/extra.md"; git -C "$t/repo" add extra.md; git -C "$t/repo" commit -q -m "add extra"
rm -f "$t/repo/extra.md"; git -C "$t/repo" add -A; git -C "$t/repo" commit -q -m "revert extra"
git -C "$t/repo" checkout -q main
out="$(DOCTOR_UNLANDED_DIR="$t/repo" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    GH_CMD="$t/no-such-gh" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'INFO C23-unlanded' && grepq "$out" -F 'landed-elsewhere' && ! grepq "$out" 'WARN C23-unlanded'; then
    pass "C23 -> INFO (landed-elsewhere only, no unlanded live work)"
else
    fail "C23 landed-elsewhere -> $(printf '%s' "$out" | grep C23)"
fi
rm -rf "$t"

# codex-3 (HIMMEL-2070 CR round 1): an unresolvable --base (or any scan
# failure) must not read as the same "no unlanded work" OK a genuinely clean
# repo gets — unlanded-work.sh always exits 0 by contract, writing its
# diagnostic to stderr instead, so a discarded stderr made an operational
# failure indistinguishable from "nothing to report" here.
echo "== C23: unresolvable base (no origin/main ref at all) -> INFO, not a false-clean OK =="
t="$(mktemp -d)"; make_wt_repo "$t/repo"; write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_UNLANDED_DIR="$t/repo" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    GH_CMD="$t/no-such-gh" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'INFO C23-unlanded' && grepq "$out" -F 'scan produced no data' && ! grepq "$out" 'OK   C23-unlanded'; then
    pass "C23 -> INFO (unresolvable base, never a false-clean OK)"
else
    fail "C23 unresolvable-base -> $(printf '%s' "$out" | grep C23)"
fi
rm -rf "$t"

# codex-3 (HIMMEL-2070 CR round 7): `cd` into a nonexistent scan_dir
# short-circuits before unlanded-work.sh ever runs, so nothing lands on
# stderr — the empty-TSV/empty-stderr combination must still read INFO, not
# a false-clean OK, driven by the cd's own exit status.
echo "== C23: DOCTOR_UNLANDED_DIR points at a nonexistent directory -> INFO, not a false-clean OK =="
t="$(mktemp -d)"; write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_UNLANDED_DIR="$t/no-such-dir" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    GH_CMD="$t/no-such-gh" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'INFO C23-unlanded' && grepq "$out" -F 'scan produced no data' && ! grepq "$out" 'OK   C23-unlanded'; then
    pass "C23 -> INFO (cd-into-scan_dir failure, never a false-clean OK)"
else
    fail "C23 cd-failure -> $(printf '%s' "$out" | grep C23)"
fi
rm -rf "$t"

# ── C24: expected-but-absent cadence tasks (HIMMEL-1680) ─────────────────────
# fake_task_probe <dir> <existing-task-names...> — a scheduler-probe stub for
# WHICHEVER platform this test happens to run on: schtasks on Windows/MSYS
# (is_windows() true), crontab elsewhere. Only the "does <name> exist" shape
# is faked — good enough for check_c24, which only ever asks that question.
# shellcheck disable=SC2016  # single-quoted $1/$2/$3 are emitted literally for the fake binary's own /bin/sh
fake_task_probe() {
    local dir="$1"; shift
    mkdir -p "$dir"
    if case "$(uname -s 2>/dev/null || echo x)" in MINGW*|MSYS*|CYGWIN*) true ;; *) false ;; esac; then
        {
            printf '#!/bin/sh\n'
            printf 'if [ "$1" = "/query" ] && [ "$2" = "/tn" ]; then\n'
            printf '    case " %s " in\n' "$*"
            printf '        *" $3 "*) exit 0 ;;\n'
            printf '        *) exit 1 ;;\n'
            printf '    esac\n'
            printf 'fi\n'
            printf 'exit 0\n'
        } > "$dir/schtasks"
        chmod +x "$dir/schtasks"
    else
        {
            printf '#!/bin/sh\n'
            printf 'if [ "$1" = "-l" ]; then\n'
            for n in "$@"; do printf '    printf "%%s\\n" "0 0 * * * true # %s"\n' "$n"; done
            printf 'fi\n'
            printf 'exit 0\n'
        } > "$dir/crontab"
        chmod +x "$dir/crontab"
    fi
}

echo "== C24: no observability registry -> OK C24-cadence-registry =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C24-cadence-registry' && grepq "$out" -F 'no cadence observability registry yet'; then
    pass "C24 -> OK (no registry)"
else
    fail "C24 no-registry -> $(printf '%s' "$out" | grep C24)"
fi
rm -rf "$t"

echo "== C24: registry present, empty expected_tasks -> OK C24-cadence-registry =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/home/.himmel"; write_settings "$t/claude" "$WRAPPER"
printf '{"flows":[],"expected_tasks":[]}\n' > "$t/home/.himmel/observability.json"
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C24-cadence-registry' && grepq "$out" -F 'no cadence tasks expected'; then
    pass "C24 -> OK (empty expected_tasks)"
else
    fail "C24 empty-expected -> $(printf '%s' "$out" | grep C24)"
fi
rm -rf "$t"

echo "== C24: malformed registry (invalid JSON) -> INFO, not a false-clean OK (codex-3) =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/home/.himmel"; write_settings "$t/claude" "$WRAPPER"
printf '{not valid json\n' > "$t/home/.himmel/observability.json"
out="$(DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'INFO C24-cadence-registry' && grepq "$out" -F 'could not be parsed' && ! grepq "$out" 'OK   C24-cadence-registry'; then
    pass "C24 -> INFO (malformed registry, never a false-clean OK)"
else
    fail "C24 malformed -> $(printf '%s' "$out" | grep C24)"
fi
rm -rf "$t"

echo "== C24: expected task present on the live scheduler -> OK C24-cadence-registry =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/home/.himmel" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
printf '{"flows":[{"name":"codex-sweep","cadence_seconds":14400}],"expected_tasks":["HIMMEL-CodexOrphanSweep"]}\n' > "$t/home/.himmel/observability.json"
fake_task_probe "$t/probe" "HIMMEL-CodexOrphanSweep"
out="$(PATH="$t/probe:$PATH" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C24-cadence-registry' && grepq "$out" -F 'expected cadence task(s) present' && ! grepq "$out" 'WARN C24-cadence-registry'; then
    pass "C24 -> OK (expected task present)"
else
    fail "C24 present -> $(printf '%s' "$out" | grep C24)"
fi
rm -rf "$t"

echo "== C24: expected task ABSENT from the live scheduler -> WARN C24-cadence-registry =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/home/.himmel" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
printf '{"flows":[{"name":"codex-sweep","cadence_seconds":14400}],"expected_tasks":["HIMMEL-CodexOrphanSweep"]}\n' > "$t/home/.himmel/observability.json"
fake_task_probe "$t/probe"
out="$(PATH="$t/probe:$PATH" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C24-cadence-registry' && grepq "$out" -F 'expected-but-absent cadence task(s): HIMMEL-CodexOrphanSweep'; then
    pass "C24 -> WARN (expected task absent)"
else
    fail "C24 absent -> $(printf '%s' "$out" | grep C24)"
fi
rm -rf "$t"

echo "== C24: scheduler probe itself fails (access-denied/transient) -> INFO, not a false-mass-WARN (codex-1, CR round 3) =="
t="$(mktemp -d)"; mkdir -p "$t/claude" "$t/home/.himmel" "$t/probe"; write_settings "$t/claude" "$WRAPPER"
printf '{"flows":[{"name":"codex-sweep","cadence_seconds":14400}],"expected_tasks":["HIMMEL-CodexOrphanSweep"]}\n' > "$t/home/.himmel/observability.json"
if case "$(uname -s 2>/dev/null || echo x)" in MINGW*|MSYS*|CYGWIN*) true ;; *) false ;; esac; then
    printf '#!/bin/sh\nexit 1\n' > "$t/probe/schtasks"; chmod +x "$t/probe/schtasks"
else
    printf '#!/bin/sh\necho "crontab: permission denied" >&2\nexit 1\n' > "$t/probe/crontab"; chmod +x "$t/probe/crontab"
fi
out="$(PATH="$t/probe:$PATH" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'INFO C24-cadence-registry' && grepq "$out" -F 'unreachable' && ! grepq "$out" 'WARN C24-cadence-registry' && ! grepq "$out" 'OK   C24-cadence-registry'; then
    pass "C24 -> INFO (scheduler probe unavailable, never a false mass-WARN)"
else
    fail "C24 scheduler-unavailable -> $(printf '%s' "$out" | grep C24)"
fi
rm -rf "$t"

# ── C25: orphaned scratchpad watcher sweep (HIMMEL-1820) ──────────────────────
# The shim seam replaces the platform producer (PowerShell CIM / ps) with a
# fixture emitter of pid|ppid|cmdline lines, so the bash-side detection --
# scratchpad-pattern match, parent-liveness, dead-parent naming -- runs for
# real, identically on every host. No fixture row uses ppid 1: the
# reparented-to-init heuristic is POSIX-only and must stay deterministic here.
C25DIR="$FAKEROOT/c25"; mkdir -p "$C25DIR"
cat > "$C25DIR/fixture-orphans" <<'EOF'
100|99|bash /c/Users/x/.claude/projects/sess-1/watch-branches.sh
99|98|bash --live-session
4242|9999|bash /c/Users/x/.claude-glm/projects/sess-2/poll.sh
5150|4242|sleep 5
6200|6100|bash run.sh | tee C:\Users\x\.claude\projects\sess-3\watch.log
EOF
printf '#!/bin/sh\ncat "%s"\n' "$C25DIR/fixture-orphans" > "$C25DIR/shim-orphans"
chmod +x "$C25DIR/shim-orphans"

echo "== C25: scratchpad watcher with a dead parent -> WARN naming the dead parent =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" DOCTOR_ORPHAN_SCAN_SKIP=0 DOCTOR_ORPHAN_SCAN_SHIM="$C25DIR/shim-orphans" \
    DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" 'WARN C25-orphans' \
    && grepq "$out" 'pid 4242 (parent pid 9999 is dead)' \
    && grepq "$out" 'pid 6200 (parent pid 6100 is dead)' \
    && grepq "$out" 'sess-2/poll.sh'; then
    pass "C25 -> WARN names each dead parent (9999, 6100), never-fatal"
else
    fail "C25 orphan -> rc=$rc; $(printf '%s' "$out" | grep C25)"
fi
if grepq "$out" 'watch-branches.sh'; then
    fail "C25 flagged pid 100 whose parent (99) is alive"
else
    pass "C25 -> live-parent watcher (pid 100) not flagged"
fi
rm -rf "$t"

echo "== C25: a | inside the command line survives the field split =="
# Row 6200 above only MATCHES the scratchpad pattern after its first | -- if
# the pid|ppid|cmd split truncated the command at an embedded pipe, that row
# would silently vanish from the findings.
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" DOCTOR_ORPHAN_SCAN_SKIP=0 DOCTOR_ORPHAN_SCAN_SHIM="$C25DIR/shim-orphans" \
    DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'pid 6200' && grepq "$out" 'watch.log'; then
    pass "C25 -> text after an embedded | in a command line is still scanned"
else
    fail "C25 -> command line truncated at an embedded |: $(printf '%s' "$out" | grep C25)"
fi
rm -rf "$t"

echo "== C25: no scratchpad watchers -> OK =="
cat > "$C25DIR/fixture-clean" <<'EOF'
100|99|bash /usr/bin/top
200|199|node /opt/app/server.js
300|299|bash /c/Users/x/projects/himmel/scripts/lib/watch-loop.sh
EOF
printf '#!/bin/sh\ncat "%s"\n' "$C25DIR/fixture-clean" > "$C25DIR/shim-clean"
chmod +x "$C25DIR/shim-clean"
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" DOCTOR_ORPHAN_SCAN_SKIP=0 DOCTOR_ORPHAN_SCAN_SHIM="$C25DIR/shim-clean" \
    DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"; rc=$?
if grepq "$out" 'OK   C25-orphans' && ! grepq "$out" 'WARN C25-orphans' && [ "$rc" -eq 0 ]; then
    pass "C25 -> OK (no scratchpad references at all)"
else
    fail "C25 clean -> rc=$rc; $(printf '%s' "$out" | grep C25)"
fi
rm -rf "$t"

echo "== C25: scan failure -> loud WARN, never a false clean =="
printf '#!/bin/sh\nexit 3\n' > "$C25DIR/shim-fail"; chmod +x "$C25DIR/shim-fail"
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" DOCTOR_ORPHAN_SCAN_SKIP=0 DOCTOR_ORPHAN_SCAN_SHIM="$C25DIR/shim-fail" \
    DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C25-orphans' && grepq "$out" 'cannot evaluate'; then
    pass "C25 -> scan failure emits a loud cannot-evaluate WARN"
else
    fail "C25 scan-failure -> $(printf '%s' "$out" | grep C25)"
fi
rm -rf "$t"

echo "== C25: skip seam -> OK skipped =="
t="$(mktemp -d)"; mkdir -p "$t/claude"; write_settings "$t/claude" "$WRAPPER"
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" DOCTOR_ORPHAN_SCAN_SKIP=1 \
    DOCTOR_WORKTREE_ROOT="$C14_WT_ROOT" DOCTOR_MCP_PLUGINS_GLOB="$t/none/*.mcp.json" \
    CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C25-orphans' && grepq "$out" 'skipped by test seam'; then
    pass "C25 -> skip seam reports OK skipped"
else
    fail "C25 skip -> $(printf '%s' "$out" | grep C25)"
fi
rm -rf "$t"

echo "== C25 STATIC: check_c25 body must not terminate processes itself =="
_c25_body="$(awk '/^check_c25\(\)/{found=1} found{print} found && /^\}$/{exit}' "$DOC")"
_static25=0
for _verb in "Stop-Process" "kill -"; do
    if grepq "$_c25_body" -F "$_verb"; then
        fail "C25 STATIC: found forbidden verb '$_verb' in check_c25 body"
        _static25=1
    fi
done
if [ "$_static25" -eq 0 ]; then
    pass "C25 STATIC: no self-terminate verbs in check_c25 body"
fi

# write_himmelctl_state <cache_dir> <consent> — writes <cache_dir>/state.json
# carrying ONLY the guardrail-block-global override C28 reads (HIMMEL-2176).
# <consent> is 'yes'/'no'/'' (empty -> overrides:{}, i.e. never asked).
write_himmelctl_state() {
    local cache_dir="$1" consent="$2"
    mkdir -p "$cache_dir"
    if [ -n "$consent" ]; then
        jq -n --arg c "$consent" '{schemaVersion:1,harness:"claude",targets:{user:{profile:"core",scope:"user",items:{"guardrail-block-global":{enabled:true,overrides:{consent:$c}}},lastEnsured:null}}}' > "$cache_dir/state.json"
    else
        jq -n '{schemaVersion:1,harness:"claude",targets:{user:{profile:"core",scope:"user",items:{"guardrail-block-global":{enabled:true,overrides:{}}},lastEnsured:null}}}' > "$cache_dir/state.json"
    fi
}

echo "== C28: guardrail-block-global wired -> OK (defers to C1-guardrail) =="
_real_node2="$(command -v node 2>/dev/null || true)"
if [ -n "$_real_node2" ]; then
    if command -v cygpath >/dev/null 2>&1; then _real_node2="$(cygpath -m "$_real_node2")"; fi
    t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c28.XXXXXX")" || { fail "C28 wired: mktemp -d failed"; exit 1; }
    write_guardrail_settings "$t/claude" "$_real_node2"
    out="$(CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
    if grepq "$out" 'OK   C28-guardrail-consent' && grepq "$out" 'is wired'; then
        pass "C28 -> OK (wired, defers to C1-guardrail)"
    else
        fail "C28 wired -> $(printf '%s' "$out" | grep C28)"
    fi
    rm -rf "$t"
else
    pass "C28 wired -> (skipped: no node on PATH here)"
fi

echo "== C28: not wired, no recorded consent -> WARN (never asked, the HIMMEL-2176 gap) =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c28.XXXXXX")" || { fail "C28 no-consent: mktemp -d failed"; exit 1; }
write_settings "$t/claude" "$WRAPPER"
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" HIMMELCTL_CACHE_DIR="$t/nostate" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C28-guardrail-consent' && grepq "$out" 'never asked'; then
    pass "C28 -> WARN (no recorded consent — the honest gap)"
else
    fail "C28 no-consent -> $(printf '%s' "$out" | grep C28)"
fi
rm -rf "$t"

echo "== C28: no user-level settings.json at all, no recorded consent -> WARN (HIMMEL-2176 panel finding — used to falsely OK this) =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c28.XXXXXX")" || { fail "C28 no-settings: mktemp -d failed"; exit 1; }
# Deliberately do NOT call write_settings — $t/claude/settings.json stays
# absent (gb is present: this checkout's own guardrail-block.mjs). A fresh
# machine with guardrails available but no settings.json and no recorded
# consent is exactly the never-asked gap C28 exists to report — it must
# not be conflated with the "$gb absent, nothing to check" OK case.
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" HIMMELCTL_CACHE_DIR="$t/nostate" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C28-guardrail-consent' && grepq "$out" 'never asked'; then
    pass "C28 -> WARN (no settings.json at all — the honest never-asked gap)"
else
    fail "C28 no-settings -> $(printf '%s' "$out" | grep C28)"
fi
rm -rf "$t"

echo "== C28: not wired, recorded decline -> OK (operator already decided) =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c28.XXXXXX")" || { fail "C28 declined: mktemp -d failed"; exit 1; }
write_settings "$t/claude" "$WRAPPER"
write_himmelctl_state "$t/state" no
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" HIMMELCTL_CACHE_DIR="$t/state" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C28-guardrail-consent' && grepq "$out" 'recorded decline'; then
    pass "C28 -> OK (recorded decline, no nag)"
else
    fail "C28 declined -> $(printf '%s' "$out" | grep C28)"
fi
rm -rf "$t"

echo "== C28: not wired, recorded consent=yes -> WARN (ensure should have converged it) =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c28.XXXXXX")" || { fail "C28 consent-yes: mktemp -d failed"; exit 1; }
write_settings "$t/claude" "$WRAPPER"
write_himmelctl_state "$t/state" yes
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" HIMMELCTL_CACHE_DIR="$t/state" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C28-guardrail-consent' && grepq "$out" 'still NOT wired'; then
    pass "C28 -> WARN (consent=yes but still unwired)"
else
    fail "C28 consent-yes -> $(printf '%s' "$out" | grep C28)"
fi
rm -rf "$t"

# c29_mkproc <root> <pid> <session-name> <comm> [environ-entries...] -- writes
# a fake /proc/<pid>/comm, /proc/<pid>/cmdline (a claude invocation naming
# <session-name> via `-n`, NUL-separated argv like the real kernel file), and
# /proc/<pid>/environ (NUL-separated KEY=VALUE entries, same shape
# context-fill.sh's own mkproc()/launched_as_child_session() test fixture
# uses). <comm> lets a case impersonate the konsole LAUNCHER (comm=konsole)
# whose cmdline also quotes `claude ... -n HIMMEL-...` (HIMMEL-2545 panel
# finding: that launcher process is not claude, and must never be flagged).
# HIMMEL-2545: the WARN must read THIS file, never the doctor's own
# environment.
c29_mkproc() {
    local root="$1" pid="$2" name="$3" comm="$4"; shift 4
    mkdir -p "$root/$pid"
    printf '%s\n' "$comm" > "$root/$pid/comm"
    printf 'claude\0--model\0claude-fable-5-1\0-n\0%s\0load doc.md and continue\0' "$name" > "$root/$pid/cmdline"
    : > "$root/$pid/environ"
    local v
    for v in "$@"; do printf '%s\0' "$v" >> "$root/$pid/environ"; done
}

echo "== C29: child-session marker with no persistence flag -> WARN, names the pid =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c29.XXXXXX")" || { fail "C29 positive: mktemp -d failed"; exit 1; }
write_settings "$t/claude" "$WRAPPER"
c29_mkproc "$t/proc" 5001 "HIMMEL-2545-leg" claude 'CLAUDE_CODE_CHILD_SESSION=1'
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" HIMMEL_DOCTOR_PROC="$t/proc" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C29-child-session' && grepq "$out" 'pid 5001' && grepq "$out" 'HIMMEL-2545-leg'; then
    pass "C29 -> WARN names pid 5001 and the session"
else
    fail "C29 positive -> $(printf '%s' "$out" | grep C29)"
fi
rm -rf "$t"

echo "== C29 CONTROL: same marker WITH persistence forced -> no WARN =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c29.XXXXXX")" || { fail "C29 control-persistence: mktemp -d failed"; exit 1; }
write_settings "$t/claude" "$WRAPPER"
c29_mkproc "$t/proc" 5002 "HIMMEL-2545-leg" claude 'CLAUDE_CODE_CHILD_SESSION=1' 'CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1'
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" HIMMEL_DOCTOR_PROC="$t/proc" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C29-child-session' && ! grepq "$out" 'WARN C29-child-session'; then
    pass "C29 -> OK (persistence already forced, no nag)"
else
    fail "C29 control-persistence -> $(printf '%s' "$out" | grep C29)"
fi
rm -rf "$t"

echo "== C29 CONTROL: claude process with NEITHER var -> no WARN =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c29.XXXXXX")" || { fail "C29 control-neither: mktemp -d failed"; exit 1; }
write_settings "$t/claude" "$WRAPPER"
c29_mkproc "$t/proc" 5003 "HIMMEL-2545-leg" claude
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" HIMMEL_DOCTOR_PROC="$t/proc" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C29-child-session' && ! grepq "$out" 'WARN C29-child-session'; then
    pass "C29 -> OK (a plain human-launched session, neither var set)"
else
    fail "C29 control-neither -> $(printf '%s' "$out" | grep C29)"
fi
rm -rf "$t"

echo "== C29 CONTROL: absent proc root -> clean skip, never a false WARN =="
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c29.XXXXXX")" || { fail "C29 control-absent: mktemp -d failed"; exit 1; }
write_settings "$t/claude" "$WRAPPER"
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" HIMMEL_DOCTOR_PROC="$t/no-such-proc" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C29-child-session' && ! grepq "$out" 'WARN C29-child-session'; then
    pass "C29 -> OK (no procfs on this platform, clean skip)"
else
    fail "C29 control-absent -> $(printf '%s' "$out" | grep C29)"
fi
rm -rf "$t"

echo "== C29 CONTROL: konsole LAUNCHER (not claude) whose cmdline quotes claude -n HIMMEL-... -> no WARN =="
# Live false positive (HIMMEL-2545 panel finding): headed-arm.sh's konsole
# process has a cmdline naming `claude ... -n HIMMEL-...` (that is the
# command it was told to run) and ALSO inherits CLAUDE_CODE_CHILD_SESSION=1
# from whatever armed it, with no persistence flag of its own -- identical
# environ shape to the genuinely-broken case above, differing ONLY in comm.
# Without the comm==claude gate this fires on every correctly-launched
# headed session via its own launcher.
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c29.XXXXXX")" || { fail "C29 control-launcher: mktemp -d failed"; exit 1; }
write_settings "$t/claude" "$WRAPPER"
c29_mkproc "$t/proc" 5004 "HIMMEL-2545-leg" konsole 'CLAUDE_CODE_CHILD_SESSION=1'
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" HIMMEL_DOCTOR_PROC="$t/proc" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'OK   C29-child-session' && ! grepq "$out" 'WARN C29-child-session'; then
    pass "C29 -> OK (konsole launcher, not claude, never flagged)"
else
    fail "C29 control-launcher -> $(printf '%s' "$out" | grep C29)"
fi
rm -rf "$t"

echo "== C29: EMPTY persistence value is absent, not present -> still WARN (HIMMEL-2545 r3-codex-4) =="
# Aligns C29 with context-fill.sh's launched_as_child_session() contract:
# CLAUDE_CODE_FORCE_SESSION_PERSISTENCE= with nothing after the = is
# meaningless (no launcher in this diff ever sets it that way) and must be
# treated as absent - the WARN must still fire, not be suppressed by a
# bare existence match.
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c29.XXXXXX")" || { fail "C29 empty-persistence: mktemp -d failed"; exit 1; }
write_settings "$t/claude" "$WRAPPER"
c29_mkproc "$t/proc" 5005 "HIMMEL-2545-leg" claude 'CLAUDE_CODE_CHILD_SESSION=1' 'CLAUDE_CODE_FORCE_SESSION_PERSISTENCE='
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" HIMMEL_DOCTOR_PROC="$t/proc" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C29-child-session' && grepq "$out" 'pid 5005'; then
    pass "C29 -> WARN fires on an empty persistence value"
else
    fail "C29 empty-persistence -> $(printf '%s' "$out" | grep C29)"
fi
rm -rf "$t"

echo "== C29 (r11-codex-3): a DECOY -n name inside prompt text, positioned BEFORE the genuine -n option -> WARN names the REAL session, never the decoy =="
# The old extraction (grep -Eo against the FLATTENED cmdline) would match
# "-n HIMMEL-decoy" the instant that substring appears anywhere in the
# space-joined text, including inside an earlier PROMPT argument that is
# not an option at all. The fixture below writes the decoy as ONE combined
# argv element (a prompt-shaped string containing "-n HIMMEL-decoy"),
# positioned BEFORE the genuine, POSITIONAL "-n" / "HIMMEL-real" pair - a
# fix that is still reading the flattened string would report the decoy;
# the positional NUL-separated walk must report the real session.
t="$(mktemp -d "${TMPDIR:-/tmp}/himmel-doctor-c29.XXXXXX")" || { fail "C29 decoy-name: mktemp -d failed"; exit 1; }
write_settings "$t/claude" "$WRAPPER"
mkdir -p "$t/proc/5006"
printf '%s\n' claude > "$t/proc/5006/comm"
printf 'claude\0--model\0claude-fable-5-1\0load context for -n HIMMEL-decoy and continue\0-n\0HIMMEL-real\0' > "$t/proc/5006/cmdline"
printf 'CLAUDE_CODE_CHILD_SESSION=1\0' > "$t/proc/5006/environ"
out="$(RESOLVE_NODE_PROBE_DIRS="$FAKENODE" HIMMEL_DOCTOR_PROC="$t/proc" CLAUDE_DIR="$t/claude" HOME="$t/home" bash "$DOC" --no-color 2>&1)"
if grepq "$out" 'WARN C29-child-session' && grepq "$out" 'pid 5006' && grepq "$out" 'HIMMEL-real' && ! grepq "$out" 'HIMMEL-decoy'; then
    pass "C29 -> WARN names the genuine session (HIMMEL-real), never the decoy prompt text"
else
    fail "C29 decoy-name -> $(printf '%s' "$out" | grep C29)"
fi
rm -rf "$t"

rm -rf "$FAKEROOT"
# r4-codex-4: HIMMEL_DOCTOR_PROC_BASE (the C29 procfs-absent hermeticity
# seam) was created near the top of this file and never removed, leaking a
# temp dir per run - cleaned up here alongside FAKEROOT, this file's own
# established end-of-run cleanup convention (it has no EXIT trap).
rm -rf "$HIMMEL_DOCTOR_PROC_BASE"
echo
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$failures FAILURE(S)"; exit 1; fi
