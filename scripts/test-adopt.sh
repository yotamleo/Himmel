#!/usr/bin/env bash
# test-adopt.sh — smoke tests for scripts/adopt.sh (the one-click harness
# installer). Self-contained: stubs `claude` on PATH so the plugin-install
# step doesn't hit the network, and uses throwaway temp dirs + a fake HOME so
# nothing touches the real ~/.claude.
#
# adopt.ps1 carries the same profile/scope logic for PowerShell — that twin is
# NOT covered here; keep both in lockstep when changing either.
#
# Covers:
#   1. core/project — copies the portable files, wires 3 PreToolUse hooks
#      ($CLAUDE_PROJECT_DIR prefix), idempotent on re-run.
#   2. merge — pre-existing settings.json keys + hooks are preserved.
#   3. core/user — wires ~/.claude/settings.json to the himmel abs path,
#      copies NO scripts into a repo.
#   4. luna — copies the vault scaffold to the target.
#   5. invalid --profile / --scope exit 2.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
adopt="$repo_root/scripts/adopt.sh"
[ -f "$adopt" ] || { echo "FAIL: $adopt not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Stub claude so adopt's install-plugins step is a no-op.
mkdir -p "$work/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$work/bin/claude"
chmod +x "$work/bin/claude"
export PATH="$work/bin:$PATH"

# ── 5. invalid args (run first — validated before any tool preflight) ────────
set +e
out=$(bash "$adopt" --profile bogus --scope project 2>&1); rc=$?
set -e
[ "$rc" -eq 2 ] || fail "invalid --profile should exit 2 (got $rc)"
printf '%s' "$out" | grep -q "invalid --profile" || fail "missing invalid-profile diagnostic"
set +e
out=$(bash "$adopt" --profile core --scope bogus 2>&1); rc=$?
set -e
[ "$rc" -eq 2 ] || fail "invalid --scope should exit 2 (got $rc)"
echo "ok: invalid --profile / --scope rejected (exit 2)"

# ── 1. core/project ──────────────────────────────────────────────────────────
proj="$work/proj"; mkdir -p "$proj"
bash "$adopt" --profile core --scope project --target "$proj" >/dev/null
for f in scripts/hooks/block-edit-on-main.sh scripts/guardrails/lib.sh scripts/worktree.sh; do
  [ -f "$proj/$f" ] || fail "core/project did not copy $f"
done
s="$proj/.claude/settings.json"
[ -f "$s" ] || fail "core/project did not write $s"
[ "$(jq '.hooks.PreToolUse | length' "$s")" = "3" ] || fail "expected 3 PreToolUse hooks"
jq -e '.hooks.PreToolUse[].hooks[].command | select(contains("$CLAUDE_PROJECT_DIR"))' "$s" >/dev/null \
  || fail "project-scope hooks must use \$CLAUDE_PROJECT_DIR"
echo "ok: core/project copies portable files + wires 3 \$CLAUDE_PROJECT_DIR hooks"

# idempotency
cp "$s" "$work/before.json"
bash "$adopt" --profile core --scope project --target "$proj" >/dev/null
diff -q "$work/before.json" "$s" >/dev/null || fail "core/project not idempotent"
echo "ok: core/project idempotent on re-run"

# ── 2. merge preserves existing settings ─────────────────────────────────────
proj2="$work/proj2"; mkdir -p "$proj2/.claude"
printf '%s' '{"permissions":{"allow":["Bash(ls)"]},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash /pre/existing.sh"}]}]}}' > "$proj2/.claude/settings.json"
bash "$adopt" --profile core --scope project --target "$proj2" >/dev/null
[ "$(jq -r '.permissions.allow[0]' "$proj2/.claude/settings.json")" = "Bash(ls)" ] || fail "merge dropped existing permissions"
[ "$(jq '.hooks.PreToolUse | length' "$proj2/.claude/settings.json")" = "4" ] || fail "merge expected 4 PreToolUse hooks (1 existing + 3)"
echo "ok: merge preserves existing keys + hooks"

# ── 3. core/user (fake HOME) ─────────────────────────────────────────────────
home="$work/home"; mkdir -p "$home"
HOME="$home" bash "$adopt" --profile core --scope user --target "$work/ignored" >/dev/null
us="$home/.claude/settings.json"
[ -f "$us" ] || fail "core/user did not write ~/.claude/settings.json"
[ "$(jq '.hooks.PreToolUse | length' "$us")" = "3" ] || fail "core/user expected 3 PreToolUse hooks"
us_cmd=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$us")
# shellcheck disable=SC2016  # literal $CLAUDE_PROJECT_DIR globs below, not expansions
case "$us_cmd" in
  *'$CLAUDE_PROJECT_DIR'*) fail "user-scope must not use \$CLAUDE_PROJECT_DIR ($us_cmd)" ;;
  */scripts/hooks/*) : ;;  # absolute himmel path
  *) fail "user-scope hook command unexpected: $us_cmd" ;;
esac
[ ! -d "$work/ignored/scripts" ] || fail "core/user must NOT copy scripts into a repo"
echo "ok: core/user wires ~/.claude to himmel abs path, copies no scripts"

# ── 4. luna scaffold ─────────────────────────────────────────────────────────
vault="$work/vault"
bash "$adopt" --profile luna --target "$vault" >/dev/null
[ -f "$vault/README.md" ] || fail "luna profile did not scaffold the vault (README.md missing)"
echo "ok: luna scaffolds the vault to the target"

# ── 6. all — core→--target, vault→--luna-target (no leak) ────────────────────
allrepo="$work/allrepo"; allvault="$work/allvault"; mkdir -p "$allrepo"
bash "$adopt" --profile all --scope project --target "$allrepo" --luna-target "$allvault" >/dev/null
[ -f "$allrepo/scripts/worktree.sh" ] || fail "all: core did not land in --target"
[ -f "$allvault/README.md" ] || fail "all: vault did not land in --luna-target"
[ ! -f "$allrepo/README.md" ] || fail "all: vault scaffold leaked into the core --target"
echo "ok: all routes core→--target, vault→--luna-target (no leak)"

# ── 7. core/user idempotency (re-run into populated ~/.claude keeps 3) ────────
HOME="$home" bash "$adopt" --profile core --scope user --target "$work/ignored" >/dev/null
[ "$(jq '.hooks.PreToolUse | length' "$us")" = "3" ] || fail "core/user not idempotent on re-run"
echo "ok: core/user idempotent on re-run"

echo "PASS"
