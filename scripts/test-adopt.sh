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

# Normalize a path the same way wire-luna-vault.sh stores it: passing a path as a
# jq arg triggers MSYS POSIX->Windows path mangling on Git-Bash (e.g.
# /tmp/x -> C:/Users/.../x) and is an identity on Linux. Normalizing the EXPECTED
# value through the same jq hop makes the LUNA_VAULT_PATH assertions below
# cross-platform without hard-coding either path form.
norm() { jq -rn --arg v "$1" '$v'; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Stub claude so adopt's install-plugins step is a no-op. `plugin list` must echo
# the enabled plugin specs so install-plugins.sh's presence-verify (HIMMEL-361)
# passes offline — without it `set -e` aborts adopt at the first core install.
mkdir -p "$work/bin"
cat > "$work/bin/claude" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "plugin" ] && [ "\$2" = "list" ]; then
  jq -r '.enabledPlugins | keys[]' "$repo_root/docs/setup/settings-template.json"
fi
exit 0
STUB
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
# F1 (HIMMEL-458): project scope wires LUNA_VAULT_PATH into $TARGET/.claude.
lv=$(jq -r '.env.LUNA_VAULT_PATH' "$vault/.claude/settings.json" 2>/dev/null)
[ "$lv" = "$(norm "$vault")" ] || fail "luna/project did not persist LUNA_VAULT_PATH ([$lv] != [$(norm "$vault")])"
echo "ok: luna scaffolds the vault + persists LUNA_VAULT_PATH (project scope)"

# ── 6. all — core→--target, vault→--luna-target (no leak) ────────────────────
allrepo="$work/allrepo"; allvault="$work/allvault"; mkdir -p "$allrepo"
bash "$adopt" --profile all --scope project --target "$allrepo" --luna-target "$allvault" >/dev/null
[ -f "$allrepo/scripts/worktree.sh" ] || fail "all: core did not land in --target"
[ -f "$allvault/README.md" ] || fail "all: vault did not land in --luna-target"
[ ! -f "$allrepo/README.md" ] || fail "all: vault scaffold leaked into the core --target"
# F1 (HIMMEL-458): project scope wires LUNA_VAULT_PATH=$allvault into $allrepo/.claude.
lv=$(jq -r '.env.LUNA_VAULT_PATH' "$allrepo/.claude/settings.json" 2>/dev/null)
[ "$lv" = "$(norm "$allvault")" ] || fail "all/project did not persist LUNA_VAULT_PATH ([$lv] != [$(norm "$allvault")])"
echo "ok: all routes core→--target, vault→--luna-target (no leak) + persists LUNA_VAULT_PATH"

# ── 7. core/user idempotency (re-run into populated ~/.claude keeps 3) ────────
HOME="$home" bash "$adopt" --profile core --scope user --target "$work/ignored" >/dev/null
[ "$(jq '.hooks.PreToolUse | length' "$us")" = "3" ] || fail "core/user not idempotent on re-run"
echo "ok: core/user idempotent on re-run"

# ── 8. F1 (HIMMEL-458): user-scope persists LUNA_VAULT_PATH to ~/.claude ──────
# 8a. F1-SC1(a): all/user --luna-target -> env.LUNA_VAULT_PATH in ~/.claude.
fh="$work/f1a-home"; mkdir -p "$fh"; fv="$work/f1a-vault"
HOME="$fh" bash "$adopt" --profile all --scope user --target "$work/ign-a" --luna-target "$fv" >/dev/null
got=$(jq -r '.env.LUNA_VAULT_PATH' "$fh/.claude/settings.json")
[ "$got" = "$(norm "$fv")" ] || fail "F1-SC1(a) all/user: LUNA_VAULT_PATH=[$got] != [$(norm "$fv")]"
echo "ok: F1-SC1(a) all/user --luna-target persists LUNA_VAULT_PATH"

# 8b. F1-SC1(b): luna/user --target -> env.LUNA_VAULT_PATH in ~/.claude.
fh2="$work/f1b-home"; mkdir -p "$fh2"; fv2="$work/f1b-vault"
HOME="$fh2" bash "$adopt" --profile luna --scope user --target "$fv2" >/dev/null
got=$(jq -r '.env.LUNA_VAULT_PATH' "$fh2/.claude/settings.json")
[ "$got" = "$(norm "$fv2")" ] || fail "F1-SC1(b) luna/user --target: LUNA_VAULT_PATH=[$got] != [$(norm "$fv2")]"
echo "ok: F1-SC1(b) luna/user --target persists LUNA_VAULT_PATH"

# 8c. arg fix: --profile luna honors --luna-target when --target is left default.
fh3="$work/f1c-home"; mkdir -p "$fh3"; fv3="$work/f1c-vault"
HOME="$fh3" bash "$adopt" --profile luna --scope user --luna-target "$fv3" >/dev/null
got=$(jq -r '.env.LUNA_VAULT_PATH' "$fh3/.claude/settings.json")
[ "$got" = "$(norm "$fv3")" ] || fail "luna --luna-target honored: LUNA_VAULT_PATH=[$got] != [$(norm "$fv3")]"
[ -f "$fv3/README.md" ] || fail "luna --luna-target did not scaffold to --luna-target"
echo "ok: --profile luna honors --luna-target (no longer a silent no-op)"

# 8d. unconditional wiring: a re-run over an EXISTING scaffold (copy skipped)
#     must STILL write the env key — fixes a previously-unwired install.
fh4="$work/f1d-home"; mkdir -p "$fh4"; fv4="$work/f1d-vault"; mkdir -p "$fv4"
HOME="$fh4" bash "$adopt" --profile luna --scope user --luna-target "$fv4" >/dev/null
got=$(jq -r '.env.LUNA_VAULT_PATH' "$fh4/.claude/settings.json")
[ "$got" = "$(norm "$fv4")" ] || fail "dest-preexists: LUNA_VAULT_PATH not written ([$got] != [$(norm "$fv4")])"
echo "ok: re-run over existing scaffold still wires LUNA_VAULT_PATH (unconditional)"

# ── 9. hook paths forward-slashed + quoted; re-wire REPLACES a
#       pre-existing broken backslash entry (basename dedup), keeps non-himmel ──
h9="$work/h9"; mkdir -p "$h9/.claude"
# seed a BROKEN backslash auto-approve entry (the adopt.ps1 bug) + a non-himmel hook
printf '%s' '{"hooks":{"PreToolUse":[
  {"matcher":"Bash","hooks":[{"type":"command","command":"bash C:\\Users\\me\\Himmel/scripts/hooks/auto-approve-safe-bash.sh"}]},
  {"matcher":"Bash","hooks":[{"type":"command","command":"bash \"C:/x/scripts/hooks/rtk-hook-guard.sh\""}]}
]}}' > "$h9/.claude/settings.json"
HOME="$h9" bash "$adopt" --profile core --scope user --target "$work/ign9" >/dev/null
s9="$h9/.claude/settings.json"
aa=$(jq -r '.hooks.PreToolUse[].hooks[].command | select(test("auto-approve-safe-bash"))' "$s9")
[ -n "$aa" ] || fail "hookpath: auto-approve hook missing after re-wire"
[ "$(printf '%s\n' "$aa" | wc -l)" = "1" ] || fail "hookpath: expected exactly ONE auto-approve entry (got: $aa)"
# shellcheck disable=SC1003  # '\' is a literal-backslash glob pattern, not a quote escape
case "$aa" in *'\'*) fail "hookpath: auto-approve command still contains a backslash: $aa" ;; esac
case "$aa" in 'bash "'*'/scripts/hooks/auto-approve-safe-bash.sh"') : ;; *) fail "hookpath: auto-approve not forward-slash+quoted: $aa" ;; esac
jq -e '.hooks.PreToolUse[].hooks[].command | select(test("rtk-hook-guard"))' "$s9" >/dev/null || fail "hookpath: rtk-hook-guard not preserved"
echo "ok: hooks forward-slash+quoted; broken entry replaced; rtk kept"

# 9b. hook-object granularity: a non-himmel hook co-located in the SAME hooks[]
#     array as a himmel hook must SURVIVE re-wire (not dropped with the stanza).
h9b="$work/h9b"; mkdir -p "$h9b/.claude"
printf '%s' '{"hooks":{"PreToolUse":[
  {"matcher":"Bash","hooks":[
    {"type":"command","command":"bash C:\\old\\Himmel/scripts/hooks/auto-approve-safe-bash.sh"},
    {"type":"command","command":"bash \"C:/x/scripts/hooks/rtk-hook-guard.sh\""}
  ]}
]}}' > "$h9b/.claude/settings.json"
HOME="$h9b" bash "$adopt" --profile core --scope user --target "$work/ign9b" >/dev/null
s9b="$h9b/.claude/settings.json"
jq -e '.hooks.PreToolUse[].hooks[].command | select(test("rtk-hook-guard"))' "$s9b" >/dev/null \
  || fail "hookpath(nested): co-located rtk-hook-guard dropped with the himmel stanza"
[ "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("auto-approve-safe-bash"))] | length' "$s9b")" = "1" ] \
  || fail "hookpath(nested): expected exactly one auto-approve after re-wire"
echo "ok: co-located non-himmel hook survives re-wire (hook-object granularity)"

echo "PASS"
