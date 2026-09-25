#!/usr/bin/env bash
# test-template-commit-msg-hook.sh -- HIMMEL-3642.
#
# The luna-second-brain template wires its conventional-commit-msg hook with
# `pass_filenames: false` (a commit-msg-stage hook). pre-commit only appends
# the commit-message file path to a hook's argv when pass_filenames is true
# (the default) -- with it false, check-commit-msg.sh's $1 is empty, its
# `cat "${COMMIT_MSG_FILE}"` reads nothing, COMMIT_MSG comes out empty, and
# the script's own empty-message skip lets EVERY commit through regardless
# of its message.
#
# This exercises the REAL template files (.pre-commit-config.yaml, the
# scripts/hooks/*.sh it ships, and its own install-nostash-hooks.sh
# installer) against the REAL pre-commit binary and REAL git commit -- not a
# hand-rolled stand-in for any of them -- copied byte-for-byte into a scratch
# repo, never the live vault.
#
# Usage: bash scripts/test-template-commit-msg-hook.sh
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

if ! command -v pre-commit >/dev/null 2>&1; then
  echo "SKIP - the pre-commit COMMAND is not on PATH; cannot exercise the real commit-msg hook"
  exit 0
fi

dir=$(fixture_mktemp_dir) || exit 1
fixture_enter_git_init_dir "$dir" || exit 1

git init -q -b main
git config user.email t@t
git config user.name t
touch .single-writer
mkdir -p scripts
cp -r "$TEMPLATE/scripts/hooks" scripts/hooks
cp -r "$TEMPLATE/scripts/guardrails" scripts/guardrails
cp "$TEMPLATE/.pre-commit-config.yaml" .pre-commit-config.yaml
printf 'seed\n' > seed.txt
git add seed.txt .pre-commit-config.yaml scripts/hooks scripts/guardrails .single-writer
git commit -qm 'chore: seed'

install_out=$(bash scripts/hooks/install-nostash-hooks.sh 2>&1)
install_rc=$?
check "install-nostash-hooks.sh succeeds" "$install_rc" "0"
[ "$install_rc" -ne 0 ] && echo "  installer output: $install_out"

bad_out=$(git commit -q --allow-empty -m 'wip stuff' 2>&1)
bad_rc=$?
check "a non-conventional commit message is REJECTED by the commit-msg hook" "$bad_rc" "1"
[ "$bad_rc" -eq 0 ] && echo "  accepted bad message; commit output: $bad_out"

good_out=$(git commit -q --allow-empty -m 'fix(vault): HIMMEL-3642 add note' 2>&1)
good_rc=$?
check "a conventional commit message is accepted by the commit-msg hook" "$good_rc" "0"
[ "$good_rc" -ne 0 ] && echo "  rejected good message; commit output: $good_out"

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
