#!/usr/bin/env bash
# test-adopt-only-hooks.sh — adopt.sh --only-hooks (HIMMEL-4267).
#
# `himmelctl ensure --items pre-commit-hooks` used to run the whole adopt
# (settings wiring, plugins, marketplaces, CLAUDE.md, statusline). --only-hooks
# places the git gate hooks and nothing else. Sandboxed HOME + target only.
#
# Covers:
#   1. project scope: hooks placed, sandbox HOME byte-identical (user settings,
#      plugin + marketplace registries, CLAUDE.md), `claude` never invoked.
#   2. user scope (target = a scratch repo): same.
#   3. contradictory / unsupported flag combos exit 2.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
adopt="${ADOPT_SH:-$repo_root/scripts/adopt.sh}"
[ -f "$adopt" ] || { echo "FAIL: $adopt not found" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

snapshot_dir() {
  ( cd "$1" && find . \( -type f -o -type d -o -type l \) | LC_ALL=C sort | while IFS= read -r p; do
      if [ -L "$p" ]; then printf 'symlink %s -> %s\n' "$p" "$(readlink "$p")"
      elif [ -d "$p" ]; then printf 'dir %s\n' "$p"
      else cksum < "$p" | sed "s|\$| $p|"; fi
    done )
}

work=$(mktemp -d "${TMPDIR:-/tmp}/adopt-only-hooks.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT
export HIMMEL_PROVENANCE_DIR="$work/prov"

home="$work/home"
mkdir -p "$home/.claude/plugins" "$work/bin"
cat > "$home/.claude/settings.json" <<'JSON'
{"extraKnownMarketplaces":{"obsidian-skills":{"source":{"source":"github","repo":"x/y"}}},"hooks":{}}
JSON
echo '{}' > "$home/.claude/plugins/known_marketplaces.json"
echo '# mine' > "$home/.claude/CLAUDE.md"
# A `claude` that records any call and fails: --only-hooks must never reach it.
cat > "$work/bin/claude" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$work/claude-calls"
exit 1
SH
chmod +x "$work/bin/claude"

new_repo() { git init -q "$1"; git -C "$1" config user.email t@t; git -C "$1" config user.name t; }

for scope in project user; do
  t="$work/target-$scope"; new_repo "$t"
  before=$(snapshot_dir "$home")
  rc=0
  out=$(PATH="$work/bin:$PATH" HOME="$home" bash "$adopt" --profile core --scope "$scope" --target "$t" --only-hooks 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "$scope: --only-hooks exited $rc: $out"
  for h in pre-commit commit-msg pre-push; do
    [ -x "$t/.git/hooks/$h" ] || fail "$scope: git hook $h not placed: $out"
  done
  [ "$before" = "$(snapshot_dir "$home")" ] || fail "$scope: --only-hooks changed the sandbox HOME"
  # The hook scripts themselves land under scripts/ (user scope); nothing else
  # (no .claude/, settings, CLAUDE.md) may appear in the target.
  [ -z "$(find "$t" \( -path "$t/.git" -o -path "$t/scripts" \) -prune -o -type f -print)" ] || fail "$scope: --only-hooks wrote files outside .git and scripts/ into the target"
  [ ! -e "$work/claude-calls" ] || fail "$scope: --only-hooks invoked claude: $(cat "$work/claude-calls")"
  echo "ok: $scope scope — hooks placed, HOME byte-identical, claude never invoked"
done

t="$work/target-bad"; new_repo "$t"
rc=0; HOME="$home" bash "$adopt" --only-hooks --skip-hooks --target "$t" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "--only-hooks with --skip-hooks should exit 2 (got $rc)"
rc=0; HOME="$home" bash "$adopt" --only-hooks --profile luna --target "$t" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "--only-hooks with --profile luna should exit 2 (got $rc)"
echo "ok: contradictory flag combos exit 2"
