#!/usr/bin/env bash
# scripts/cr/write-verdicts.sh — classifier-sanctioned writer for the
# /pr-check runbook's branch-scoped verdict scratch files (HIMMEL-2131).
#
# WHY: the runbook's structural-persistence contract (HIMMEL-1219 rounds 3-5)
# has the orchestrating session persist adjudication VERDICT lines to
# <git-common-dir>/cr-prior-blocking/<branch> (step 3.2 phase A) and
# <git-common-dir>/cr-aggregate-verdicts/<branch> (step 4), so phase B's
# conserve-or-run decision and step 4's orphan-check DERIVE their blocking
# counts from a file instead of trusting the session's own prose. In
# auto-mode the classifier denies the inline `cat > ... <<EOF` heredoc write
# shape those fences used, so the structural signal silently degraded to
# fail-open (nothing written, both fences read "0 blockers"). This helper is
# the sanctioned single-purpose write path for that contract — the same role
# scripts/cr/ledger-append.sh plays for the CR critic ledger.
#
# Usage:
#   bash scripts/cr/write-verdicts.sh <prior-blocking|aggregate> [--branch <branch>]
#   Verdict lines come from STDIN ONLY (HIMMEL-2131 review round 2: this
#   helper carries a standing auto-approve rule, so a `--file <path>` option
#   would be a sanctioned arbitrary-file-READ primitive for anything the
#   caller can name — no such option exists).
#   --branch defaults to `git branch --show-current`.
#
# Every non-blank input line must match EXACTLY ONE of:
#   VERDICT [<id>] = agreed|disproved|conflict|unaddressed
#   VERDICT [<id>] = deferred -> <TICKET>
# (id: non-empty, no ']'; TICKET: the same shape ledger-append.sh's
# valid_ticket() requires, e.g. HIMMEL-1294 — HIMMEL-2375: a bare `deferred`
# with no ticket is untracked and indistinguishable from a free pass around
# conservation, so it is REJECTED like any other malformed line, not silently
# accepted as a 5th bare verdict). ANY other non-blank line refuses the WHOLE
# write (rc=2) — nothing is written, so a malformed line can never land a
# partial/corrupt file the runbook's awk parsers then misread. The refusal
# reports only the LINE NUMBER and the expected grammar, NEVER the offending
# line's content (HIMMEL-2131 review round 2: echoing it back would disclose
# whatever the caller piped in — secrets included — to this script's stderr).
# Zero verdict lines is a VALID input (the runbook's own fail-open
# "no candidates" state) and writes an empty file, rc=0.
#
# TRUNCATE-then-write only, matching the heredocs it replaces (both runbook
# fences REPLACE the file's contents every run) — no append mode; YAGNI, the
# runbook never needs one.
#
# Exit codes:
#   0  wrote the target file (verdict lines, or empty)
#   2  usage error / malformed verdict line / unresolvable or unsafe branch — NOTHING written
#   3  not inside a git repo (cannot resolve --git-common-dir)
#
# Operator note: the standing allow-rule is a post-merge OPERATOR step (this
# change does not touch .claude/settings.json). Permission-rule prefix
# matching is LITERAL, and the runbook invokes this script by its ABSOLUTE
# path (cwd may be an adopter repo, not this checkout) — so the relative rule
# `Bash(bash scripts/cr/write-verdicts.sh:*)` never matches that invocation.
# The operator needs BOTH rules: the relative form above, for any repo-root
# invocation, AND the absolute form for their primary checkout —
# `Bash(bash <primary-checkout>/scripts/cr/write-verdicts.sh:*)`.
set -uo pipefail

mode="${1:-}"; shift || true
case "$mode" in
  prior-blocking|aggregate) ;;
  *) echo "write-verdicts.sh: first arg must be prior-blocking|aggregate (got '$mode')" >&2; exit 2 ;;
esac

branch=""
while [ $# -gt 0 ]; do case "$1" in
  # codex-3, HIMMEL-2131 round 2: check $# BEFORE consuming "$2" — a trailing
  # `--branch` with nothing after it must hit this rc=2 usage error, not a
  # `set -u` crash on "$2" NOR (the ${2:-}-only fix's own bug) a `shift 2`
  # that silently no-ops when only 1 positional arg remains, leaving "--branch"
  # as $1 forever and infinite-looping the arg parser.
  --branch)
    [ $# -ge 2 ] || { echo "write-verdicts.sh: --branch requires a value" >&2; exit 2; }
    branch="$2"; shift 2 ;;
  *) echo "write-verdicts.sh: unknown arg $1" >&2; exit 2 ;;
esac; done

# Derived EXACTLY like the runbook fences: $(git rev-parse --git-common-dir)
# is the SHARED git dir across every worktree in the checkout.
git_dir=$(git rev-parse --git-common-dir 2>/dev/null) || git_dir=""
[ -n "$git_dir" ] || { echo "write-verdicts.sh: not a git repository (cannot resolve --git-common-dir) — refusing." >&2; exit 3; }

[ -n "$branch" ] || branch=$(git branch --show-current 2>/dev/null || true)
[ -n "$branch" ] || { echo "write-verdicts.sh: cannot resolve the branch (detached HEAD?) — pass --branch explicitly." >&2; exit 2; }

# Path-escape refusal (HIMMEL-2131 review round 1): $branch — whether typed
# via --branch or read back from `git branch --show-current` — becomes a path
# segment below with no further checks. An unvalidated `../../evil`, a
# leading `/` or `\`, or a `C:`-style drive-absolute value escapes
# <git-common-dir>/cr-prior-blocking/ entirely, turning the future standing
# allow-rule (`Bash(bash scripts/cr/write-verdicts.sh:*)`) into an
# arbitrary-file-truncate primitive an auto-approved caller could ride. Refuse
# before $target is ever built.
case "$branch" in
  /*|\\*) echo "write-verdicts.sh: --branch must not be an absolute path (got '$branch')" >&2; exit 2 ;;
  [A-Za-z]:*) echo "write-verdicts.sh: --branch must not be a drive-absolute path (got '$branch')" >&2; exit 2 ;;
esac
case "$branch" in
  *\\*) echo "write-verdicts.sh: --branch must not contain a backslash (got '$branch')" >&2; exit 2 ;;
esac
case "/$branch/" in
  */../*) echo "write-verdicts.sh: --branch must not contain a '..' path segment (got '$branch')" >&2; exit 2 ;;
esac

case "$mode" in
  prior-blocking) subdir="cr-prior-blocking" ;;
  aggregate)      subdir="cr-aggregate-verdicts" ;;
esac
target="$git_dir/$subdir/$branch"

# Exact grammar: VERDICT [<id>] = agreed|disproved|conflict|unaddressed.
# `[^]]+` is a valid POSIX bracket expression (a leading ']' right after '^'
# is a literal member, not a syntax error) matching "one or more non-']'".
verdict_re='^VERDICT \[[^]]+\] = (agreed|disproved|conflict|unaddressed)$'
# HIMMEL-2375: `deferred` is a 5th verdict, accepted ONLY with a trailing
# ` -> <TICKET>` — a real finding dispositioned onto another ticket rather
# than fixed on this branch. Ticket shape mirrors ledger-append.sh's
# valid_ticket() exactly (scripts/cr/ledger-append.sh), so any line accepted
# here is also a ticket ledger-append.sh's --deferred-to would accept. A line
# with the bare word `deferred` and no ticket matches NEITHER regex and falls
# through to the generic malformed-line refusal below.
deferred_re='^VERDICT \[[^]]+\] = deferred -> [A-Z][A-Z0-9]*-[0-9]+$'

lines=""
nr=0
while IFS= read -r line || [ -n "$line" ]; do
  nr=$((nr + 1))
  # known-findings grep-q-pipe-under-pipefail (HIMMEL-2131 round 2): a
  # `<producer> | grep -q` under `set -o pipefail` lets grep's early exit on
  # first match SIGPIPE the producer, and pipefail then reports that SIGPIPE
  # as the pipeline's failure — a here-string feeds grep directly with no
  # producer process to SIGPIPE.
  trimmed="$line"
  case "$trimmed" in *[![:space:]]*) ;; *) continue ;; esac   # blank line — skipped, not an error
  if ! grep -qE "$verdict_re" <<< "$line" && ! grep -qE "$deferred_re" <<< "$line"; then
    echo "write-verdicts.sh: malformed verdict line at line $nr (want 'VERDICT [<id>] = agreed|disproved|conflict|unaddressed' or 'VERDICT [<id>] = deferred -> <TICKET>') — refusing the whole write" >&2
    exit 2
  fi
  lines="$lines$line"$'\n'
done

# Symlink-through truncate defense (codex-2 round 2 + codex-1 round 3,
# HIMMEL-2131): an auto-approved writer following a pre-planted symlink at the
# target OR at ANY path component under the git dir (a nested branch like
# feat/x means cr-prior-blocking/feat is itself a walkable component) would
# truncate/create whatever the link points to instead of the intended scratch
# file. Walk every component from $git_dir/$subdir down to the target and
# refuse on the first symlink — BEFORE mkdir -p, so a symlinked ancestor
# component is never followed to create directories outside the intended
# subtree in the first place (round 4 codex-1: mkdir -p running first let a
# planted parent-component symlink get walked before this check ever ran).
# `[ -L ]` on a not-yet-existing path is simply false, so the walk tolerates
# components mkdir -p has not created yet. Lexical belt within the
# local-write-access trust boundary, not a TOCTOU-proof boundary (bash cannot
# open O_NOFOLLOW; a racing local writer already owns the hook stack).
_walk="$git_dir/$subdir"
_rel="$branch"
while :; do
  if [ -L "$_walk" ]; then
    echo "write-verdicts.sh: refusing to write through a symlinked path component at $_walk" >&2
    exit 2
  fi
  [ -n "$_rel" ] || break
  case "$_rel" in
    */*) _walk="$_walk/${_rel%%/*}"; _rel="${_rel#*/}" ;;
    *)   _walk="$_walk/$_rel"; _rel="" ;;
  esac
done
if [ -L "$target" ]; then
  echo "write-verdicts.sh: refusing to write through a symlink at $target" >&2
  exit 2
fi

mkdir -p "$(dirname "$target")"
printf '%s' "$lines" > "$target"
