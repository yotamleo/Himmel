#!/usr/bin/env bash
# scripts/ci/test-shellcheck-pr-range.sh -- regression suite for
# scripts/ci/shellcheck-pr-range.sh (HIMMEL-4319), the PR-path selector of CI's
# lint job. Every case builds a commit in a throwaway repo (scratch HOME, no
# network, no pre-commit) and asserts the --dry-run verdict: ALL (fall back to
# --all-files) or FILES (+ the neighbours that must be linted). A selector that
# wrongly says FILES is a false-green lint on a PR, so each escape the judges
# found has a case here.
#
# An optional path argument (or SPR=<path>) runs the suite against another copy
# of the script (RED control).
# Usage: bash scripts/ci/test-shellcheck-pr-range.sh [script-copy]
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
# SC2016: the single-quoted bodies are literal fixture file contents, not expansions.
# SC2015: `|| bad` only reports; a failed commit still reaches the verdict check.
# shellcheck disable=SC2016,SC2015
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SPR="${1:-${SPR:-$ROOT/scripts/ci/shellcheck-pr-range.sh}}"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/spr-test.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" GIT_CONFIG_GLOBAL="$T/home/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
mkdir -p "$HOME"
R="$T/repo"
git init -q "$R" || exit 1
cd "$R" || exit 1
git config user.email t@example.com
git config user.name t
git config commit.gpgsign false

w() { mkdir -p "$(dirname "$1")"; printf '%s' "$2" > "$1"; }

w .shellcheckrc 'external-sources=true
'
w scripts/lib/gh-ci-cache.sh '#!/usr/bin/env bash
CIC_SLEEP_CMD=sleep
'
w scripts/lib/check-ci-watch.sh '#!/usr/bin/env bash
. scripts/lib/gh-ci-cache.sh
echo "$CIC_SLEEP_CMD"
'
w scripts/zzj/zzjlib.sh '#!/usr/bin/env bash
ZZJ_X=1
'
w scripts/zzj-consumer.sh '#!/usr/bin/env bash
# shellcheck source=scripts/zzj/zzjlib.sh
. "$ZZJ_LIB"
'
w scripts/zzj-revc.sh '#!/usr/bin/env bash
echo hi
'
git add -A && git commit -q -m base || exit 1
BASE=$(git rev-parse HEAD)

# case <name>: reset to BASE; the caller then edits the tree; commit_case commits it
reset() { git checkout -q -f "$BASE" && git clean -fdxq; }
commit_case() { git add -A && git commit -q --allow-empty -m "$1" || bad "$1: commit failed"; }

# verdict <name> <ALL|FILES> [expected file ...]: dry-run at HEAD against BASE
verdict() {
  local name="$1" want="$2" out first
  shift 2
  out=$(bash "$SPR" --dry-run "$BASE" 2>/dev/null)
  first=${out%%$'\n'*}
  first=${first%% *}
  if [ "$first" != "$want" ]; then
    bad "$name: want $want, got: $(printf '%s' "$out" | head -3 | tr '\n' '|')"
    return
  fi
  local f
  for f in "$@"; do
    printf '%s\n' "$out" | grep -Fxq -- "$f" || { bad "$name: $want list lacks $f"; return; }
  done
  ok "$name -> $want"
}

# rename_lib: a renamed lib is a delete + add, so its consumers are found
reset; git mv scripts/lib/gh-ci-cache.sh scripts/lib/gh-ci-cache-v2.sh; commit_case rename_lib
verdict rename_lib FILES scripts/lib/check-ci-watch.sh scripts/lib/gh-ci-cache-v2.sh

# rename_rc: moving the root rc away changes lint config
reset; mkdir -p docs; git mv .shellcheckrc docs/shellcheckrc.bak; commit_case rename_rc
verdict rename_rc ALL

# nonascii: a non-ASCII path reaches the lint verbatim (no quotePath mangling)
reset; w "scripts/café.sh" '#!/usr/bin/env bash
echo $x
'; commit_case nonascii
verdict nonascii FILES "scripts/café.sh"

# directive: a `# shellcheck source=` directive is a consumer edge
reset; w scripts/zzj/zzjlib.sh '#!/usr/bin/env bash
ZZJ_X=2
'; commit_case directive
verdict directive FILES scripts/zzj/zzjlib.sh scripts/zzj-consumer.sh

# directive_revc: ...and the directive target of a changed consumer is linted too
reset; w scripts/zzj-revc.sh '#!/usr/bin/env bash
# shellcheck source=scripts/zzj/zzjlib.sh
echo hi
'; commit_case directive_revc
verdict directive_revc FILES scripts/zzj-revc.sh scripts/zzj/zzjlib.sh

# selfedit: a PR that edits the selector never gets to narrow its own lint
reset; w scripts/ci/shellcheck-pr-range.sh '#!/usr/bin/env bash
exit 0
'; commit_case selfedit
verdict selfedit ALL

# noop: a comment-only touch of a lib still pulls in its consumer
reset; printf '# touched\n' >> scripts/lib/gh-ci-cache.sh; commit_case noop
verdict noop FILES scripts/lib/gh-ci-cache.sh scripts/lib/check-ci-watch.sh

# nested_rc / nested_rc2: a shellcheckrc at any depth shadows the root one
reset; w scripts/lib/.shellcheckrc 'enable=require-variable-braces
'; commit_case nested_rc
verdict nested_rc ALL
reset; w scripts/lib/shellcheckrc 'enable=require-variable-braces
'; commit_case nested_rc2
verdict nested_rc2 ALL

# nl_lead: a newline anywhere in a changed path (even leading) is uncertain
reset; w "$(printf '\nzzbad.sh')" '#!/usr/bin/env bash
echo $x
'; commit_case nl_lead
verdict nl_lead ALL

# script-absent-at-base: the workflow runs `git show <base>:<script>`; at a base
# that predates the script it must fail, which drives the --all-files branch
pre=$(git commit-tree "$(git rev-parse "$BASE^{tree}")" -m pre)
if git show "$pre:scripts/ci/shellcheck-pr-range.sh" >/dev/null 2>&1; then
  bad "script-absent-at-base: git show unexpectedly succeeded"
else
  ok "script-absent-at-base: git show fails, workflow takes --all-files"
fi

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed" >&2
exit 1
