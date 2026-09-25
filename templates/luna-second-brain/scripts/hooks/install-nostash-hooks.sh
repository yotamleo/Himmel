#!/usr/bin/env bash
# Install stash-free git hooks for this single-writer vault.
#
# Why not `pre-commit install`? Its generated hook stashes every unstaged change
# to a tracked file before running, then re-applies the stash afterwards. With
# Obsidian running, .obsidian/plugins/*/{data.json,main.js,...} are rewritten
# under it, the re-apply fails ("patch does not apply") and pre-commit rolls
# back — reverting OTHER unstaged files on disk (see _CLAUDE.md, "pre-commit trap").
#
# `pre-commit run --files ...` never stashes (pre_commit/commands/run.py:
# `stash = not args.all_files and not args.files`), so these wrappers pass the
# staged file list explicitly. Trade-off: hooks see the WORKTREE content of a
# partially-staged file, not the index — acceptable for a single-writer vault.
#
# Only pre-commit and commit-msg are installed. pre-push is deliberately left
# out: the two pre-push checks are no-ops on a .single-writer repo, and hooking
# the Obsidian Git plugin's push path adds failure surface for zero benefit.
#
# Idempotent. Re-run after a fresh clone (.git/hooks is not versioned).
set -euo pipefail

# Target the vault THIS script lives in, not the caller's cwd (HIMMEL-2223:
# `bash <vault>/scripts/hooks/install-nostash-hooks.sh` run with a cwd inside
# a DIFFERENT repo used to install into that other repo's shared .git/hooks).
script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
computed_root=$(cd -- "$script_dir/../.." && pwd -P)
if ! git -C "$computed_root" rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "error: $computed_root (derived from this script's own location) is not a git repository" >&2
  exit 1
fi
root=$(git -C "$computed_root" rev-parse --show-toplevel)

# `rev-parse --show-toplevel` accepts an ENCLOSING repo, not only one rooted
# exactly at $computed_root -- a copy of this script nested inside some other
# repo (no .git of its own where the vault expects one) would otherwise
# resolve here and install this vault's hooks into that unrelated repo.
if [ "$root" != "$computed_root" ]; then
  echo "error: $computed_root (derived from this script's own location) is not itself a git repository root -- it resolved to the enclosing repository $root instead." >&2
  echo "hint: run this installer from its own vault's checked-out copy, not a copy nested inside an unrelated repo." >&2
  exit 1
fi

# Match stock `pre-commit install`'s own refusal. `core.hooksPath` can point
# anywhere -- a global one hijacks every repo for that user -- and honoring
# it here would install this vault's hooks into that shared location instead
# of this vault's own .git/hooks.
if [ -n "$(git -C "$root" config --get core.hooksPath 2>/dev/null || true)" ]; then
  echo "Cowardly refusing to install hooks with \`core.hooksPath\` set." >&2
  echo "hint: git config --unset-all core.hooksPath (--local or --global, as appropriate), then re-run this script." >&2
  exit 1
fi

# Derived from git-common-dir (never --git-path hooks, which follows
# core.hooksPath) so this can never write outside this vault's own hooks dir.
hooks_dir=$(git -C "$root" rev-parse --git-common-dir)
case "$hooks_dir" in
  /*) ;;
  *) hooks_dir="$root/$hooks_dir" ;;
esac
hooks_dir="$hooks_dir/hooks"
mkdir -p "$hooks_dir"

# Resolve pre-commit ONCE, here (BEFORE touching any existing hook -- HIMMEL-2223
# codex-1: resolving after backing up an existing hook left the vault with
# NO pre-commit/commit-msg hook at all whenever resolution then failed), and
# bake the verified choice into the generated hooks below -- the way
# pre-commit's own hook bakes INSTALL_PYTHON. Re-resolving from PATH at
# commit time (the previous approach) breaks under a GUI/Obsidian-Git
# commit, which often runs with a minimal PATH.
#
# `python3` is deliberately tried AFTER `python`: on a stock Windows machine
# an unqualified `python3` commonly resolves to the Microsoft Store stub, not
# a real interpreter. The `-m pre_commit --version` probe below (not just
# `--version`) also rejects a `python`/`python3` that runs but can't import
# pre_commit, so the stub is refused either way.
pc=()
resolve_pre_commit() {
  local candidate
  if candidate=$(command -v pre-commit 2>/dev/null) && "$candidate" --version >/dev/null 2>&1; then
    pc=("$candidate")
    return 0
  fi
  local py
  for py in python python3; do
    if candidate=$(command -v "$py" 2>/dev/null) && "$candidate" -m pre_commit --version >/dev/null 2>&1; then
      pc=("$candidate" -m pre_commit)
      return 0
    fi
  done
  return 1
}
if ! resolve_pre_commit; then
  echo "error: no working pre-commit found (tried \`pre-commit\`, \`python -m pre_commit\`, \`python3 -m pre_commit\`)." >&2
  echo "  Install pre-commit first (see scripts/setup.sh [3/6]), then re-run this script." >&2
  exit 1
fi

# Back up a pre-existing hook we didn't generate, instead of silently
# discarding it -- a re-run over our OWN generated hook still overwrites
# freely (that's the idempotency this script promises). Done only AFTER
# pre-commit resolved successfully above, so a resolution failure leaves
# any existing hook untouched.
backup_foreign_hook() {
  local f="$1"
  if [ -e "$f" ] && ! grep -q "Generated by scripts/hooks/install-nostash-hooks.sh" "$f" 2>/dev/null; then
    mv "$f" "$f.bak-preinstall"
    echo "note: existing $f was not ours; backed up to $f.bak-preinstall" >&2
  fi
}
backup_foreign_hook "$hooks_dir/pre-commit"
backup_foreign_hook "$hooks_dir/commit-msg"

pc_cmd=""
for _tok in "${pc[@]}"; do
  printf -v _q '%q' "$_tok"
  pc_cmd="$pc_cmd $_q"
done
pc_cmd="${pc_cmd# }"

cat >"$hooks_dir/pre-commit" <<HOOK
#!/usr/bin/env bash
# Generated by scripts/hooks/install-nostash-hooks.sh — do not edit by hand.
set -euo pipefail
cd "\$(git rev-parse --show-toplevel)"
pc=($pc_cmd)
files=()
while IFS= read -r -d '' f; do
  files+=("\$f")
done < <(git diff --cached --name-only --diff-filter=ACMR -z)
[ "\${#files[@]}" -eq 0 ] && exit 0
exec "\${pc[@]}" run --hook-stage pre-commit --files "\${files[@]}"
HOOK

cat >"$hooks_dir/commit-msg" <<HOOK
#!/usr/bin/env bash
# Generated by scripts/hooks/install-nostash-hooks.sh — do not edit by hand.
# --all-files, not --files: commit-msg hooks validate the MESSAGE, not staged
# file content, and pre-commit only skips its stash when --all-files or
# --files is given (see the top-of-file comment) -- a \`--diff-filter=ACMR\`
# files array can be legitimately empty (a deletion-only commit), and
# omitting both flags entirely would silently reintroduce the stash this
# wrapper exists to avoid, for every commit, not just deletion-only ones.
set -euo pipefail
cd "\$(git rev-parse --show-toplevel)"
pc=($pc_cmd)
exec "\${pc[@]}" run --hook-stage commit-msg --commit-msg-filename "\$1" --all-files
HOOK

chmod +x "$hooks_dir/pre-commit" "$hooks_dir/commit-msg"

# Warm the hook environments now, so the first real commit does not stall on
# network fetches (gitleaks, pre-commit-hooks, shellcheck-py). Reuses the
# same verified command resolved above.
(cd "$root" && "${pc[@]}" install-hooks)

echo "installed: $hooks_dir/pre-commit, $hooks_dir/commit-msg (stash-free)"
