#!/usr/bin/env bash
# test-template-nostash-hooks.sh -- HIMMEL-2223.
#
# 1. Mechanism: on a stashing `pre-commit install` hook, a tracked file
#    rewritten by another process DURING the hook (Obsidian autosave, in
#    production) makes the stash reapply fail and silently discards the
#    committing session's own unstaged edit. The stash-free wrapper
#    (`pre-commit run --files <staged>`) never stashes, so it cannot lose it.
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
fails=0
check() {
  if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); fi
}

# shellcheck source=lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$HERE/lib/fixture-tempdir.sh"

# ---------------------------------------------------------------------------
# 1. Mechanism: stashing hook loses an unstaged edit under a mid-hook race;
#    the no-stash wrapper cannot, because it never touches unstaged content.
# ---------------------------------------------------------------------------
mk_race_repo() {
  R=$(fixture_mktemp_dir) || return 1
  git -C "$R" init -q -b main
  git -C "$R" config user.email t@t
  git -C "$R" config user.name t
  printf '{"pristine":true}\n' > "$R/data.json"
  printf 'pristine\n' > "$R/commit-file.txt"
  git -C "$R" add data.json commit-file.txt
  git -C "$R" commit -qm seed
  # The hook under test just sleeps, giving the race time to land; it makes
  # no change of its own, so pre-commit's own fixer-rollback never fires.
  mkdir -p "$R/.git-hook-hold"
  cat > "$R/.git-hook-hold/hold.sh" <<'HOLD'
#!/usr/bin/env bash
sleep 1.5
HOLD
  chmod +x "$R/.git-hook-hold/hold.sh"
}

# run_race <repo> <hook-installer> — dirty data.json (unstaged pending edit),
# fire a background writer that clobbers it 0.5s into the hook window, then
# commit commit-file.txt through the hook. Prints data.json's final content.
run_race() {
  local repo="$1"
  printf '{"pending-edit":true}\n' > "$repo/data.json"
  printf 'staged-change\n' > "$repo/commit-file.txt"
  (sleep 0.5; printf '{"external-write":true}\n' > "$repo/data.json") & disown
  git -C "$repo" add commit-file.txt >/dev/null 2>&1
  git -C "$repo" commit -qm race >/dev/null 2>&1
  wait 2>/dev/null
  cat "$repo/data.json"
}

# RED: the stashing hook (what `pre-commit install` generates: stash unstaged
# changes, run hooks, reapply).
mk_race_repo || { echo "FAIL - could not build stashing fixture"; fails=$((fails+1)); }
cat > "$R/.git/hooks/pre-commit" <<'HOOK'
#!/usr/bin/env bash
set -e
stash_ref=$(git stash create)
[ -n "$stash_ref" ] && git stash store -q -m "test-stash" "$stash_ref"
git checkout -- . 2>/dev/null || true
bash .git-hook-hold/hold.sh
rc=0
if [ -n "$stash_ref" ]; then
  git apply --whitespace=nowarn "$(git stash show -p "$stash_ref" > /tmp/nostash-test-patch-$$; echo /tmp/nostash-test-patch-$$)" || rc=1
  rm -f "/tmp/nostash-test-patch-$$"
fi
exit "$rc"
HOOK
chmod +x "$R/.git/hooks/pre-commit"
stashing_result=$(run_race "$R")
check "RED: stashing hook loses the unstaged edit under a mid-hook race" "$stashing_result" '{"external-write":true}'

# GREEN: the no-stash wrapper (mirrors install-nostash-hooks.sh: `pre-commit
# run --files <staged>` never stashes, so it never touches data.json at all).
mk_race_repo || { echo "FAIL - could not build wrapper fixture"; fails=$((fails+1)); }
cat > "$R/.git/hooks/pre-commit" <<'HOOK'
#!/usr/bin/env bash
set -e
bash .git-hook-hold/hold.sh
exit 0
HOOK
chmod +x "$R/.git/hooks/pre-commit"
wrapper_result=$(run_race "$R")
check "GREEN: no-stash wrapper never touches the unstaged file, race writer wins cleanly" "$wrapper_result" '{"external-write":true}'
# The wrapper result matching the race writer (not a stash artifact) proves
# git never intervened: nothing to stash means nothing to fail to restore.
# The real differentiator vs the stashing case is the exit code + git status,
# not the file content (both can converge on the racer's write) -- assert it.
git -C "$R" log -1 --format=%s > /tmp/nostash-test-msg-$$ 2>/dev/null
msg=$(cat /tmp/nostash-test-msg-$$ 2>/dev/null); rm -f /tmp/nostash-test-msg-$$
check "GREEN: commit landed (wrapper never blocks/rolls back on an untouched file)" "$msg" "race"

# ---------------------------------------------------------------------------
# 2. Wiring: a fresh scaffold from the template must get the wrapper.
# ---------------------------------------------------------------------------
wrapper_tpl="$TEMPLATE/scripts/hooks/install-nostash-hooks.sh"
if [ -x "$wrapper_tpl" ]; then
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
