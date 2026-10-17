#!/usr/bin/env bash
# scripts/ci/test-shellcheck-pr-range.sh -- regression suite for
# scripts/ci/shellcheck-pr-range.sh, the PR-path selector of CI's
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

# chain3: a three-level source chain -- only the closure reaches the third consumer
reset; w scripts/zzc/c0.sh '#!/usr/bin/env bash
ZZC=1
'; w scripts/zzc/c1.sh '#!/usr/bin/env bash
. scripts/zzc/c0.sh
'; w scripts/zzc/c2.sh '#!/usr/bin/env bash
. scripts/zzc/c1.sh
'; w scripts/zzc/c3.sh '#!/usr/bin/env bash
. scripts/zzc/c2.sh
'; git add -A && git commit -q -m chain_base; CBASE=$(git rev-parse HEAD)
printf '# touched\n' >> scripts/zzc/c0.sh; commit_case chain3
BASE=$CBASE verdict chain3 FILES scripts/zzc/c0.sh scripts/zzc/c1.sh scripts/zzc/c2.sh scripts/zzc/c3.sh

# glued_brace / glued_bare: a .sh token glued to a variable expansion is dynamic
reset; w scripts/zzg.sh '#!/usr/bin/env bash
. "${ZZ_DIR}zzjlib.sh"
'; commit_case glued_brace
verdict glued_brace ALL
reset; w scripts/zzg.sh '#!/usr/bin/env bash
. "$ZZ_NAME.sh"
'; commit_case glued_bare
verdict glued_bare ALL

# slash_var: `$X/name.sh` keeps a literal basename, which the tracked-name match resolves
reset; w scripts/zzg.sh '#!/usr/bin/env bash
. "$ZZ_DIR/zzjlib.sh"
'; commit_case slash_var
verdict slash_var FILES scripts/zzg.sh scripts/zzj/zzjlib.sh

# quoted_dot: a `.` inside a quoted jq program is not a source command (filter copied verbatim
# from scripts/handover/merge-on-green.sh, whose false "dynamic source line" forced ALL FILES)
reset; w scripts/zzq.sh '#!/usr/bin/env bash
. scripts/zzj/zzjlib.sh
rules=$("$GH" api "repos/$nwo/rules/branches/$branch" \
        --jq '"'"'(if type == "array" then . else [] end) | [.[] | select(.type == "required_status_checks")] as $r | "\([$r[] | .parameters.required_status_checks | if type == "array" then length else 0 end] | add | if . == null then 0 else . end)|\([$r[] | .ruleset_id] | unique | join(","))"'"'"' 2>/dev/null || true)
'; commit_case quoted_dot
verdict quoted_dot FILES scripts/zzq.sh scripts/zzj/zzjlib.sh

# dyn_real: the genuine dynamic source line from merge-on-green.sh still forces the fallback
reset; w scripts/zzd.sh '#!/usr/bin/env bash
if ! { [ -r "$_csg_lib" ] && . "$_csg_lib"; }; then
    echo refuse >&2
fi
'; commit_case dyn_real
verdict dyn_real ALL

# dyn_cmdsub: a dynamic source inside a double-quoted command substitution is executable, not text
reset; w scripts/zzc.sh '#!/usr/bin/env bash
out="$(. "$lib")"
'; commit_case dyn_cmdsub
verdict dyn_cmdsub ALL

# dyn_mixq: apostrophes inside a double-quoted span do not open a single-quoted span
reset; w scripts/zzm.sh '#!/usr/bin/env bash
out="'"'"'$(. "$lib")'"'"'"
'; commit_case dyn_mixq
verdict dyn_mixq ALL
# dyn_escq: an escaped quote outside a span opens nothing, so the real source after it counts
reset; w scripts/zze.sh '#!/usr/bin/env bash
echo \" ; . "$lib"
'; commit_case dyn_escq
verdict dyn_escq ALL

# dyn_dir: a dynamic source directly under a `# shellcheck source=<x>.sh` directive is static
reset; w scripts/zzy.sh '#!/usr/bin/env bash
# shellcheck source=scripts/zzj/zzjlib.sh
if ! { [ -r "$_csg_lib" ] && . "$_csg_lib"; }; then
    echo refuse >&2
fi
'; commit_case dyn_dir
verdict dyn_dir FILES scripts/zzy.sh scripts/zzj/zzjlib.sh
# dyn_stack: a stacked `# shellcheck disable=` between directive and source keeps the cover
reset; w scripts/zzy.sh '#!/usr/bin/env bash
# shellcheck source=scripts/zzj/zzjlib.sh
# shellcheck disable=SC1091
if ! { [ -r "$_csg_lib" ] && . "$_csg_lib"; }; then
    echo refuse >&2
fi
'; commit_case dyn_stack
verdict dyn_stack FILES scripts/zzy.sh scripts/zzj/zzjlib.sh
# dyn_nodir: the same line with a blank line between directive and source still forces the fallback
reset; w scripts/zzy.sh '#!/usr/bin/env bash
# shellcheck source=scripts/zzj/zzjlib.sh

if ! { [ -r "$_csg_lib" ] && . "$_csg_lib"; }; then
    echo refuse >&2
fi
'; commit_case dyn_nodir
verdict dyn_nodir ALL

# absent <name> <file>: the dry-run list must NOT carry <file>
absent() {
  local out
  out=$(bash "$SPR" --dry-run "$BASE" 2>/dev/null) || { bad "$1: dry-run failed"; return; }
  if printf '%s\n' "$out" | grep -Fxq -- "$2"; then bad "$1: list wrongly carries $2"; else ok "$1: list omits $2"; fi
}

# merge_ref: CI's pull_request checkout is GitHub's merge ref (^1 = base branch tip, ^2 = PR head)
# and a rerun reuses the event's STALE base.sha, so base..HEAD spans every main commit since. Shape
# copied from lint job 117489260636 (run 39059106090, PR 2997): $BASE stale, main moved on, the PR
# adds one file. Only the PR's own file may be linted, not the main-side file.
reset; w scripts/zzmain.sh '#!/usr/bin/env bash
echo main
'; commit_case mr_main; MR_MAIN=$(git rev-parse HEAD)
reset; w scripts/zzpr.sh '#!/usr/bin/env bash
echo pr
'; commit_case mr_pr; MR_PR=$(git rev-parse HEAD)
git checkout -q "$MR_MAIN" && git merge -q --no-ff -m mergeref "$MR_PR" || bad "merge_ref: fixture merge failed"
export GITHUB_EVENT_NAME=pull_request
verdict merge_ref FILES scripts/zzpr.sh
absent merge_ref scripts/zzmain.sh
unset GITHUB_EVENT_NAME

# one_pass: the closure must not re-grep the tree once per file (a 324-file closure ran past the
# job cap). A git shim logs every call; the 4-deep chain needs at most the one up-front grep.
mkdir -p "$T/gshim"
RGIT=$(command -v git)
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/git.log"\nexec %s "$@"\n' "$T" "$RGIT" > "$T/gshim/git"
chmod +x "$T/gshim/git"
git checkout -q -f "$CBASE" && git clean -fdxq
printf '# touched again\n' >> scripts/zzc/c0.sh; commit_case one_pass
: > "$T/git.log"
PATH="$T/gshim:$PATH" BASE=$CBASE verdict one_pass FILES scripts/zzc/c3.sh
greps=$(grep -c ' grep ' "$T/git.log")
[ "$greps" -le 2 ] && ok "one_pass: $greps git grep call(s) for a 4-deep closure" || bad "one_pass: $greps git grep calls, want at most 2"

# timings: a slow run must be diagnosable from the job log
out=$(bash "$SPR" --dry-run "$CBASE" 2>&1 >/dev/null)
printf '%s' "$out" | grep -q 'selection took' && ok "timings: selection time is printed" || bad "timings: no selection time in: $out"

# sweep_*: the non-dry fallback shards the full sweep in parallel through a stub pre-commit.
# A stub shard fails when handed a file named *bad*; it records every invocation's file list.
mkdir -p "$T/bin"
cat > "$T/bin/pre-commit" <<'STUB'
#!/usr/bin/env bash
# stub: pre-commit run shellcheck [--show-diff-on-failure] [--all-files | --files f...]
if [ "$*" = "run shellcheck --all-files --show-diff-on-failure" ]; then
  echo "STUB serial"; exit 0
fi
shift 3
[ "${1:-}" = "--files" ] && shift
printf '%s\n' "$*" >> "$STUB_LOG"
echo "STUB shard: $#"
case "$*" in *bad*) exit 1 ;; esac
exit 0
STUB
chmod +x "$T/bin/pre-commit"
sweep() { STUB_LOG="$T/stub.log" PATH="$T/bin:$PATH" bash "$SPR" "$BASE" >"$T/sweep.out" 2>&1; }
reset; w .shellcheckrc 'external-sources=true
# touched
'; commit_case sweep_ok; : > "$T/stub.log"
sweep; rc=$?
[ "$rc" -eq 0 ] && ok "sweep_ok: rc 0 when every shard passes" || bad "sweep_ok: want rc 0, got $rc"
grep -q 'STUB shard' "$T/sweep.out" && ok "sweep_ok: shard output is preserved" || bad "sweep_ok: no shard output: $(head -3 "$T/sweep.out" | tr '\n' '|')"
grep -E 'gh-ci-cache.sh' "$T/stub.log" | grep -q 'check-ci-watch.sh' \
  && ok "sweep_ok: a lib and its consumer share one shard" || bad "sweep_ok: lib and consumer split: $(tr '\n' '|' < "$T/stub.log")"
reset; w .shellcheckrc 'external-sources=true
# touched
'; w scripts/zzbad.sh '#!/usr/bin/env bash
echo $x
'; commit_case sweep_fail; : > "$T/stub.log"
sweep; rc=$?
[ "$rc" -ne 0 ] && ok "sweep_fail: non-zero when one shard fails" || bad "sweep_fail: a failing shard was swallowed (rc 0)"

# sweep_E: a tracked root file named E (the planner's old in-band sentinel) must still be linted,
# and the shards must cover exactly git ls-files
reset; w .shellcheckrc 'external-sources=true
# touched
'; w E '#!/usr/bin/env bash
echo e
'; w T '#!/usr/bin/env bash
echo t
'; commit_case sweep_E; : > "$T/stub.log"
sweep; rc=$?
[ "$rc" -eq 0 ] && ok "sweep_E: rc 0" || bad "sweep_E: want rc 0, got $rc"
tr ' ' '\n' < "$T/stub.log" | grep -v '^$' | sort > "$T/shards.txt"
git ls-files | sort > "$T/tracked.txt"
cmp -s "$T/shards.txt" "$T/tracked.txt" \
  && ok "sweep_E: union of shard file lists equals git ls-files" || bad "sweep_E: shards differ from git ls-files: $(diff "$T/shards.txt" "$T/tracked.txt" | head -4 | tr '\n' '|')"
# sweep_norc: a shard that dies before writing its rc is a failure, not a pass
cat > "$T/bin/pre-commit" <<'STUB'
#!/usr/bin/env bash
if [ "$*" = "run shellcheck --all-files --show-diff-on-failure" ]; then echo "STUB serial"; exit 0; fi
kill -9 "$(ps -o ppid= -p $PPID)"
STUB
chmod +x "$T/bin/pre-commit"
sweep; rc=$?
[ "$rc" -ne 0 ] && ok "sweep_norc: a signalled shard fails the sweep" || bad "sweep_norc: signalled shard passed (rc 0)"

# The next rows break one inner tool through a shim dir ahead on PATH; the shim defers to the
# real tool for every other call, so only the shard path under test sees the fault.
cat > "$T/bin/pre-commit" <<'STUB'
#!/usr/bin/env bash
if [ "$*" = "run shellcheck --all-files --show-diff-on-failure" ]; then echo "STUB serial"; exit 0; fi
echo "STUB shard"
exit 0
STUB
RTR=$(command -v tr); RCAT=$(command -v cat); RAWK=$(command -v awk)
mkdir -p "$T/shim"
shimsweep() { STUB_LOG="$T/stub.log" PATH="$T/shim:$T/bin:$PATH" bash "$SPR" "$BASE" >"$T/sweep.out" 2>&1; }
reset; w .shellcheckrc 'external-sources=true
# touched
'; commit_case sweep_shim

# sweep_pipefail: the shard's tr dies, xargs still sees empty input and the stub passes; the shard
# must fail on the pipeline status, not on xargs alone
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = "\\0" ] && exit 1; done\nexec %s "$@"\n' "$RTR" > "$T/shim/tr"
chmod +x "$T/shim/tr"; : > "$T/stub.log"
shimsweep; rc=$?
[ "$rc" -ne 0 ] && ok "sweep_pipefail: a failing tr fails the shard" || bad "sweep_pipefail: failing tr passed (rc 0)"
rm -f "$T/shim/tr"

# sweep_short: a packer that drops a file would let a pass cover less than the tree; the
# count check must send the run to the serial sweep
printf '#!/bin/sh\nfor a in "$@"; do case "$a" in sd=*) sd=${a#sd=} ;; esac; done\n%s "$@"; r=$?\n[ -n "$sd" ] && [ -f "$sd/bin.1" ] && sed "$ d" "$sd/bin.1" > "$sd/bin.1.t" && mv "$sd/bin.1.t" "$sd/bin.1"\nexit $r\n' "$RAWK" > "$T/shim/awk"
chmod +x "$T/shim/awk"
shimsweep; rc=$?
grep -q 'STUB serial' "$T/sweep.out" && ok "sweep_short: a short shard set falls back to the serial sweep" || bad "sweep_short: ran sharded over a short plan: $(head -3 "$T/sweep.out" | tr '\n' '|')"
rm -f "$T/shim/awk"

# sweep_badrc: a non-numeric rc must not become the exit status (exit -0 would be a pass)
printf '#!/bin/sh\ncase "$1" in *.rc) echo -0; exit 0 ;; esac\nexec %s "$@"\n' "$RCAT" > "$T/shim/cat"
chmod +x "$T/shim/cat"
shimsweep; rc=$?
[ "$rc" -ne 0 ] && ok "sweep_badrc: a non-numeric rc fails the sweep" || bad "sweep_badrc: non-numeric rc passed (rc 0)"
rm -f "$T/shim/cat"

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
