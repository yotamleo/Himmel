#!/usr/bin/env bash
# test-template-nostash-hooks.sh -- HIMMEL-2223.
#
# 1. Mechanism: on a stashing `pre-commit install` hook, a tracked file
#    rewritten by another process DURING the hook (Obsidian autosave, in
#    production) makes the stash reapply fail and silently discards the
#    committing session's own unstaged edit. The stash-free wrapper
#    (`pre-commit run --files <staged>`) never stashes, so it cannot lose it.
#    This exercises the REAL `pre-commit` binary and the REAL
#    install-nostash-hooks.sh output -- not a hand-rolled stand-in for
#    either -- so a regression in either one is actually caught.
#
#    Caveat that both RED and GREEN below demonstrate: pre-commit's own
#    whole-tree `_get_diff()` check in pre_commit/commands/run.py reports
#    "files were modified by this hook" and fails the commit whenever ANY
#    tracked file changes during the hook's run, independent of the
#    stash/no-stash mechanism. So the wrapper does not make the race-losing
#    commit succeed -- it only stops the STASH from destroying the
#    concurrent writer's edit. The adopter-facing behaviour is: the write
#    survives, but the commit attempt fails and must be retried.
#
# 2. Wiring: a vault freshly scaffolded from templates/luna-second-brain/
#    must install the wrapper for pre-commit/commit-msg, not the stashing
#    `pre-commit install`.
#
# Usage: bash scripts/test-template-nostash-hooks.sh
# Exit 0 if all cases pass, 1 otherwise.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
TEMPLATE="$REPO_ROOT/templates/luna-second-brain"
INSTALLER="$TEMPLATE/scripts/hooks/install-nostash-hooks.sh"
fails=0
check() {
  if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); fi
}

# shellcheck source=lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$HERE/lib/fixture-tempdir.sh"

if ! command -v pre-commit >/dev/null 2>&1 && ! python3 -c 'import pre_commit' >/dev/null 2>&1; then
  echo "SKIP - pre-commit is not installed; cannot exercise the real stash/no-stash hooks"
  exit 0
fi

# mk_seed_repo <dir> -- a git repo with a real pre-commit local hook (`hold`,
# just sleeps) wired via .pre-commit-config.yaml, one commit in.
mk_seed_repo() {
  local dir="$1"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@t
  git -C "$dir" config user.name t
  touch "$dir/.single-writer"
  printf '{"pristine":true}\n' > "$dir/data.json"
  printf 'pristine\n' > "$dir/commit-file.txt"
  mkdir -p "$dir/.git-hook-hold"
  cat > "$dir/.git-hook-hold/hold.sh" <<'HOLD'
#!/usr/bin/env bash
sleep 1.5
HOLD
  chmod +x "$dir/.git-hook-hold/hold.sh"
  cat > "$dir/.pre-commit-config.yaml" <<'CFG'
repos:
  - repo: local
    hooks:
      - id: hold
        name: hold
        entry: bash .git-hook-hold/hold.sh
        language: system
        pass_filenames: false
        always_run: true
CFG
  git -C "$dir" add data.json commit-file.txt .git-hook-hold/hold.sh .pre-commit-config.yaml
  git -C "$dir" commit -qm seed
}

# assert_toplevel_is <dir> -- confirms git resolves <dir> itself as the repo
# toplevel before an installer is allowed to touch it (HIMMEL-2223 incident:
# install-nostash-hooks.sh infers its target from cwd via
# `git rev-parse --show-toplevel`, with no target argument -- a stray cd
# elsewhere silently installs into the WRONG repo's shared .git/hooks/).
assert_toplevel_is() {
  local dir="$1" top
  top=$(cd "$dir" && git rev-parse --show-toplevel 2>/dev/null)
  [ "$top" = "$dir" ]
}

# run_race <repo> -- stage ONLY commit-file.txt, leave data.json dirty and
# UNSTAGED, fire a background writer that clobbers it 0.5s into the hook's
# 1.5s hold, commit through whatever hook is installed. Prints data.json's
# final content and the tail of the commit's output.
run_race() {
  local repo="$1"
  printf '{"pending-edit":true}\n' > "$repo/data.json"
  printf 'staged-change\n' > "$repo/commit-file.txt"
  git -C "$repo" add commit-file.txt >/dev/null 2>&1
  (sleep 0.5; printf '{"external-write":true}\n' > "$repo/data.json") & disown
  git -C "$repo" commit -qm race > "$repo/.race-commit.log" 2>&1
  wait 2>/dev/null
  cat "$repo/data.json"
}

# ---------------------------------------------------------------------------
# RED: stock `pre-commit install` (the stash/rollback installer) reverts a
# concurrent writer's edit to an UNRELATED unstaged tracked file.
# ---------------------------------------------------------------------------
R=$(fixture_mktemp_dir) || { echo "FAIL - could not allocate RED fixture dir"; fails=$((fails+1)); }
if [ -n "${R:-}" ]; then
  mk_seed_repo "$R"
  if ! assert_toplevel_is "$R"; then
    echo "FAIL - RED fixture toplevel is not [$R]; refusing to install into it"
    fails=$((fails+1))
  else
    (cd "$R" && pre-commit install >/dev/null) || { echo "FAIL - stock pre-commit install failed"; fails=$((fails+1)); }
    red_result=$(run_race "$R")
    red_output=$(cat "$R/.race-commit.log" 2>/dev/null)
    check "RED: stock pre-commit stash/rollback reverts the concurrent writer's edit" "$red_result" '{"pending-edit":true}'
    red_msg=$(git -C "$R" log -1 --format=%s)
    check "RED: commit did not land" "$red_msg" "seed"
    case "$red_output" in
      *"files were modified by this hook"*) check "RED: pre-commit reports files were modified by this hook" yes yes ;;
      *) check "RED: pre-commit reports files were modified by this hook" no yes ;;
    esac
  fi
fi

# ---------------------------------------------------------------------------
# GREEN: the real install-nostash-hooks.sh wrapper (--files, no stash) never
# touches data.json, so the concurrent writer's edit survives. The commit
# STILL does not land -- pre-commit's own whole-tree modified-files check
# fires regardless of the stash mechanism -- but nothing is lost.
# ---------------------------------------------------------------------------
G=$(fixture_mktemp_dir) || { echo "FAIL - could not allocate GREEN fixture dir"; fails=$((fails+1)); }
if [ -n "${G:-}" ]; then
  mk_seed_repo "$G"
  if ! assert_toplevel_is "$G"; then
    echo "FAIL - GREEN fixture toplevel is not [$G]; refusing to install into it"
    fails=$((fails+1))
  else
    (cd "$G" && bash "$INSTALLER" >/dev/null) || { echo "FAIL - install-nostash-hooks.sh failed"; fails=$((fails+1)); }
    green_result=$(run_race "$G")
    green_output=$(cat "$G/.race-commit.log" 2>/dev/null)
    check "GREEN: the real no-stash wrapper never touches data.json, concurrent write survives" "$green_result" '{"external-write":true}'
    green_msg=$(git -C "$G" log -1 --format=%s)
    check "GREEN: commit did not land (pre-commit's own modified-files check, unrelated to stash)" "$green_msg" "seed"
    case "$green_output" in
      *"files were modified by this hook"*) check "GREEN: pre-commit reports files were modified by this hook" yes yes ;;
      *) check "GREEN: pre-commit reports files were modified by this hook" no yes ;;
    esac
  fi
fi

# ---------------------------------------------------------------------------
# 2. Wiring: a fresh scaffold from the template must get the wrapper.
# ---------------------------------------------------------------------------
if [ -x "$INSTALLER" ]; then
  check "template ships install-nostash-hooks.sh (executable)" yes yes
else
  check "template ships install-nostash-hooks.sh (executable)" "no" yes
fi

for twin in scripts/setup.sh scripts/setup.ps1; do
  f="$TEMPLATE/$twin"
  if grep -q "install-nostash-hooks.sh" "$f" 2>/dev/null; then
    check "$twin wires install-nostash-hooks.sh" yes yes
  else
    check "$twin wires install-nostash-hooks.sh" no yes
  fi
  # The stashing installer must not still be used for pre-commit/commit-msg
  # (pre-push staying on the framework installer is correct and expected).
  if grep -vE '^[[:space:]]*#' "$f" 2>/dev/null \
      | grep -E "(pre_commit|pre-commit) install( |$)" \
      | grep -v -- "--hook-type pre-push" | grep -q .; then
    check "$twin does not call the stashing installer for pre-commit/commit-msg" "still present" "removed"
  else
    check "$twin does not call the stashing installer for pre-commit/commit-msg" "removed" "removed"
  fi
done

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
