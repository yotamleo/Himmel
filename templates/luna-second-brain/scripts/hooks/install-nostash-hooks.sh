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

# `--show-prefix` is empty exactly when $computed_root IS the repo's own
# toplevel -- unlike comparing `--show-toplevel`'s own output against
# $computed_root as strings (the previous approach), this doesn't depend on
# both sides spelling the same directory the same way: on Git-Bash, `pwd -P`
# prints `/c/...` while git's own toplevel output prints `C:/...` for that
# identical directory, so the old string compare failed there even when
# $computed_root genuinely was the toplevel. A non-empty prefix means
# `--show-toplevel` resolved an ENCLOSING repo instead -- a copy of this
# script nested inside some other repo (no .git of its own where the vault
# expects one) -- which would otherwise install this vault's hooks into that
# unrelated repo.
prefix=$(git -C "$computed_root" rev-parse --show-prefix)
if [ -n "$prefix" ]; then
  echo "error: $computed_root (derived from this script's own location) is not itself a git repository root -- it resolved to an enclosing repository instead (prefix: $prefix)." >&2
  echo "hint: run this installer from its own vault's checked-out copy, not a copy nested inside an unrelated repo." >&2
  exit 1
fi
root="$computed_root"

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
# `--path-format=absolute` makes git itself emit an absolute path in
# whatever spelling it uses on this platform, instead of this script
# sniffing whether the (unqualified) output already looked absolute by
# checking for a leading `/` -- a check that silently misfires on Windows,
# where an absolute path spells `C:/...`, not `/...`.
hooks_dir=$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)
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

# Resolved and baked the same way as pre-commit above (not left to a
# runtime PATH lookup): a restricted commit-time PATH (GUI/Obsidian-Git)
# must still find it.
if ! xargs_bin=$(command -v xargs); then
  echo "error: no working xargs found (needed to batch a large commit's staged-file list)." >&2
  exit 1
fi

# Back up a pre-existing hook we didn't generate, instead of silently
# discarding it -- a re-run over our OWN generated hook still overwrites
# freely (that's the idempotency this script promises). Done only AFTER
# pre-commit resolved successfully above, so a resolution failure leaves
# any existing hook untouched.
backup_foreign_hook() {
  local f="$1"
  # -e alone is false for a DANGLING symlink, which would then let the later
  # `cat > "$f"` follow the link and write the generated hook wherever it
  # points -- possibly outside the vault. -L also catches that case.
  if { [ -e "$f" ] || [ -L "$f" ]; } && ! grep -q "Generated by scripts/hooks/install-nostash-hooks.sh" "$f" 2>/dev/null; then
    if [ -e "$f.bak-preinstall" ] || [ -L "$f.bak-preinstall" ]; then
      echo "error: $f is not ours and $f.bak-preinstall already exists from an earlier install -- refusing to overwrite that backup." >&2
      echo "hint: move or remove $f.bak-preinstall, then re-run this script." >&2
      exit 1
    fi
    mv "$f" "$f.bak-preinstall"
    echo "note: existing $f was not ours; backed up to $f.bak-preinstall" >&2
  fi
  # A symlink judged "ours" above (grep matched THROUGH the link, against
  # whatever it points at) is left untouched by the branch above -- but the
  # generation step below writes via `cat >`, which follows any symlink and
  # would overwrite that link's target, inside or outside the vault. Drop the
  # link itself so the write always lands on a fresh regular file at $f.
  if [ -L "$f" ]; then
    rm -f "$f"
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
printf -v xargs_q '%q' "$xargs_bin"

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
# A deletion-only, --allow-empty, or message-only-amend commit leaves \$files
# empty. pre-commit only skips its stash when --all-files or --files is
# given (see the top-of-file comment) -- an empty --files array is the same
# as omitting it (an empty args.files is falsy) and silently re-enables the
# stash, while --all-files (the previous approach here) runs every fixer
# over the WHOLE vault, touching unrelated unstaged files and reintroducing
# the exact stash-loss failure this wrapper exists to avoid. A single
# --files path that cannot exist keeps args.files truthy (no stash) while
# pre-commit's own Classifier drops it via a lexists() check before any
# hook's file pattern is matched, so file-pattern hooks see zero files --
# and always_run/pass_filenames:false hooks (e.g. worktree-isolation) still
# run, exactly like stock pre-commit on an empty diff.
if [ "\${#files[@]}" -eq 0 ]; then
  files=(".git/NOSTASH-EMPTY-SENTINEL")
fi
# Batched via xargs, not one argv -- a large commit's staged-file list can
# exceed the platform's command-line length limit (Windows: ~32K chars).
printf '%s\0' "\${files[@]}" | $xargs_q -0 "\${pc[@]}" run --hook-stage pre-commit --files
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
