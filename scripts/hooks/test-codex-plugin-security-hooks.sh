#!/usr/bin/env bash
# Regression test (HIMMEL-589): the two plugin-delivered SECURITY guards
# (block-docker-privesc.sh, block-merged-pr-commit.sh) must FIRE under Codex.
#
# Background. Both guards ship via the himmel-ops plugin hooks.json with a
# wrapper `h="$CLAUDE_PROJECT_DIR/scripts/hooks/<guard>.sh"; [ -f "$h" ] && exec
# bash "$h"`. Codex injects CLAUDE_PLUGIN_ROOT for plugin hooks but NOT
# CLAUDE_PROJECT_DIR, so under Codex `$h` resolves empty, `[ -f "$h" ]` is false,
# and the guard SILENTLY NO-OPS (root-equivalent docker mounts + merged-PR
# commits go unguarded). Fix: wire both into .codex/hooks.json via
# run-hook.cmd --sandbox (the wrapper derives the repo root from its OWN
# location, harness-agnostically), like the other already-wired security hooks.
#
# This suite asserts, for BOTH guards:
#   1) they are wired into .codex/hooks.json through run-hook.cmd, under a
#      Bash-inclusive matcher (static — RED before the fix);
#   2) invoking that wired command with the Codex plugin-hook env simulated
#      (CLAUDE_PROJECT_DIR UNSET, CLAUDE_PLUGIN_ROOT set) actually FIRES the
#      guard end-to-end — a privesc / merged-PR-commit input yields Codex's
#      JSON deny, while a benign input does not (behavioral).
#
# Hermetic: docker/podman are never invoked (the guard only inspects the
# command string); the forge is stubbed (GH_CMD), so no network. bash 3.2-safe.
#
# The Windows (cmd.exe) branch of run-hook.cmd is covered by the .ps1 twin.
set -uo pipefail

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HOOKS_DIR/../.." && pwd)"
HOOKS_JSON="$REPO_ROOT/.codex/hooks.json"
BOGUS_PLUGIN="/nonexistent/codex/plugin-root"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

if ! command -v jq >/dev/null 2>&1; then
  echo "jq not on PATH — required for this test" >&2; exit 1
fi
[ -f "$HOOKS_JSON" ] || { echo ".codex/hooks.json not found: $HOOKS_JSON" >&2; exit 1; }

# Extract the (first) PreToolUse hook command wiring a given guard filename.
wired_cmd() {
  jq -r --arg g "$1" \
    '.hooks.PreToolUse[]?.hooks[]?.command // empty | select(contains($g))' \
    "$HOOKS_JSON" 2>/dev/null | head -1
}
# Extract the matcher of the PreToolUse block containing that guard.
wired_matcher() {
  jq -r --arg g "$1" \
    '.hooks.PreToolUse[]? | select(([.hooks[]?.command // ""] | join(" ")) | contains($g)) | .matcher' \
    "$HOOKS_JSON" 2>/dev/null | head -1
}

# Run a guard via its WIRED .codex/hooks.json command, simulating the Codex
# plugin-hook env (CLAUDE_PROJECT_DIR unset, CLAUDE_PLUGIN_ROOT set). Extra
# args are passed as env overrides (e.g. FORGE=github GH_CMD=...). Prints the
# command's stdout (Codex decision JSON, when blocked).
run_codex_hook() {
  local guard="$1" json="$2"; shift 2
  local cmd; cmd="$(wired_cmd "$guard")"
  if [ -z "$cmd" ]; then printf '__NOT_WIRED__'; return; fi
  # shellcheck disable=SC2086
  ( cd "$REPO_ROOT" && printf '%s' "$json" \
      | env -u CLAUDE_PROJECT_DIR CLAUDE_PLUGIN_ROOT="$BOGUS_PLUGIN" "$@" \
        bash $cmd 2>/dev/null )
}

assert_deny() {
  local label="$1" out="$2"
  case "$out" in
    *'"permissionDecision":"deny"'*) ok "$label";;
    *) bad "$label (out=${out:-<empty>})";;
  esac
}
assert_no_deny() {
  local label="$1" out="$2"
  case "$out" in
    *'"permissionDecision":"deny"'*) bad "$label (unexpected deny: $out)";;
    *) ok "$label";;
  esac
}

# ── 1) Static wiring: both guards routed through run-hook.cmd, Bash matcher ──
for g in block-docker-privesc.sh block-merged-pr-commit.sh; do
  c="$(wired_cmd "$g")"
  if [ -n "$c" ]; then ok "$g wired into .codex/hooks.json"; else bad "$g wired into .codex/hooks.json"; fi
  case "$c" in *run-hook.cmd*) ok "$g routed through run-hook.cmd";; *) bad "$g routed through run-hook.cmd (got: ${c:-<none>})";; esac
  m="$(wired_matcher "$g")"
  case "$m" in
    *Bash*PowerShell*|*PowerShell*Bash*) ok "$g matches both Bash and PowerShell";;
    *) bad "$g matches both Bash and PowerShell (got: ${m:-<none>})";;
  esac
done

# ── 2a) block-docker-privesc fires under the Codex env ──────────────────────
PRIVESC='{"tool_name":"Bash","tool_input":{"command":"docker run --rm -v /etc:/host-etc:rw ubuntu:22.04 cat /host-etc/shadow"}}'
BENIGN='{"tool_name":"Bash","tool_input":{"command":"echo hello"}}'
assert_deny    "docker-privesc: root-equiv mount denied (CLAUDE_PROJECT_DIR unset)" \
               "$(run_codex_hook block-docker-privesc.sh "$PRIVESC")"
assert_no_deny "docker-privesc: benign command allowed" \
               "$(run_codex_hook block-docker-privesc.sh "$BENIGN")"

# ── 2b) block-merged-pr-commit fires under the Codex env ────────────────────
SANDBOX="$(mktemp -d)"; trap 'rm -rf "$SANDBOX"' EXIT
STUB="$SANDBOX/gh-merged"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
echo "1"
EOF
chmod +x "$STUB"
STUB_CLEAN="$SANDBOX/gh-clean"
cat > "$STUB_CLEAN" <<'EOF'
#!/usr/bin/env bash
echo "0"
EOF
chmod +x "$STUB_CLEAN"

mkrepo() {
  local path="$1" branch="$2"
  mkdir -p "$path"
  git -C "$path" init -q
  git -C "$path" symbolic-ref HEAD "refs/heads/$branch"
  git -C "$path" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
}
TESTREPO="$SANDBOX/repo"
mkrepo "$TESTREPO" "feat/codex-589"

# JSON payload with the repo as cwd (the guard targets the repo via cwd, not
# CLAUDE_PROJECT_DIR — so this is unaffected by it being unset).
repo_esc="$(printf '%s' "$TESTREPO" | sed 's/\\/\\\\/g; s/"/\\"/g')"
COMMIT_JSON="$(printf '{"tool_name":"Bash","tool_input":{"command":"git commit -m x"},"cwd":"%s"}' "$repo_esc")"

assert_deny    "merged-pr: commit onto merged branch denied (CLAUDE_PROJECT_DIR unset)" \
               "$(run_codex_hook block-merged-pr-commit.sh "$COMMIT_JSON" FORGE=github GH_CMD="$STUB")"
assert_no_deny "merged-pr: commit onto un-merged branch allowed" \
               "$(run_codex_hook block-merged-pr-commit.sh "$COMMIT_JSON" FORGE=github GH_CMD="$STUB_CLEAN")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
