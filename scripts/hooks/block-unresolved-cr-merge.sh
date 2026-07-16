#!/usr/bin/env bash
# PreToolUse hook: block-unresolved-cr-merge.sh
#
# Blocks `gh pr merge` on TWO independent gates, run in order:
#   1. CR gate (HIMMEL-936): unresolved CodeRabbit review threads or a
#      CodeRabbit check-run still running on the head SHA (except a proven old
#      zombie backed by success status + zero unresolved threads, HIMMEL-980;
#      operator rule 2026-07-11: never merge over unresolved CodeRabbit remarks).
#   2. CI-green gate (HIMMEL-1043): the PR's head SHA must have green overall
#      CI — no failing/pending check-run, no failing/pending combined status.
#      This repo has NO branch protection, so GitHub will not otherwise block a
#      merge over red/pending CI (operator rule: "ready to merge" requires green).
# Sibling of check-cr-marker-on-pr-create.sh / block-merged-pr-commit.sh.
#
# Exit: 0 allow (incl. every fail-open path), 2 block (stderr shown to model).
# Bypass: CR_MERGE_GATE_OK=1 and/or CI_MERGE_GATE_OK=1 in the LAUNCHING shell
# (each gates its own check independently). CR_PROFILE=none skips the CR gate.
set -uo pipefail
# NOT set -e: fail-open hook, must never abort on a sub-call's rc 1.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The CR-gate bypasses (CR_MERGE_GATE_OK=1 / CR_PROFILE=none) are handled
# INSIDE cr_merge_gate (self-bypass → rc 0), NOT with an early exit here — an
# early `exit 0` would also skip the independent CI-green gate below, letting a
# red/pending-CI merge through whenever a CR bypass is set (CodeRabbit, #1230).
# The CI gate has its OWN bypass (CI_MERGE_GATE_OK=1) inside ci_green_gate. So
# both gates are always reached; each self-bypasses its own check.
command -v jq >/dev/null 2>&1 || exit 0   # cannot parse stdin: fail open

payload=$(cat) || exit 0

# Fast path: skip the jq spawn unless the raw payload could contain a merge.
# Deliberately LOOSE (`merge` anywhere, not the exact phrase): a double-spaced
# `gh  pr  merge` must NOT dodge the gate via the fast path (plan-critic #2);
# non-merge commands mentioning "merge" fall through to the cheap regex below.
case "$payload" in
    *merge*) ;;
    *) exit 0 ;;
esac

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -z "$cmd" ] && exit 0

# Quote-blindness guard (coderabbit CR round): match + tokenize on a copy with
# each QUOTED SPAN replaced by the placeholder token Q - text inside quotes can
# neither look like a command boundary (`git commit -m "done; gh pr merge 42"`
# is NOT a merge - false-block vector) nor smuggle a quoted selector, while
# token POSITIONS survive so value-taking flags (`--repo "o/r" 42`) still
# consume exactly one token (coderabbit app round: full deletion collapsed
# positions and let --repo eat the selector). An unbalanced quote leaves
# residue whose worst case is a mis-extracted selector -> rc=3 re-anchor ->
# fail-open, never a false block on quoted text.
cmd_stripped=$(printf '%s' "$cmd" | sed -e "s/'[^']*'/Q/g" -e 's/"[^"]*"/Q/g')

# Command-position anchor (POSIX classes - BSD grep lacks \s/\b; coderabbit
# app round). `merge` must be followed by whitespace or end-of-string.
# shellcheck disable=SC2016  # literal backtick/$( in the class - intentional
if ! printf '%s' "$cmd_stripped" | grep -qE '(^|[;&|`$(][[:space:]]*)gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'; then
    exit 0
fi

# Isolate the SEGMENT containing `gh pr merge` before tokenizing. A whole-
# command token walk trips on earlier `merge` words: `git merge main && gh pr
# merge 42` would take "main" as the selector (plan-critic #1). Split on
# ; && || and newlines (NOT |) with bash-native expansion - BSD sed leaves
# \n LITERAL in replacements, which silently broke this split on macOS
# (coderabbit app round) - then pick the first matching segment.
merge_segment=""
normalised=${cmd_stripped//&&/$'\n'}
normalised=${normalised//||/$'\n'}
normalised=${normalised//;/$'\n'}
while IFS= read -r segment || [ -n "$segment" ]; do
    # shellcheck disable=SC2016  # literal backtick/$( in the class - intentional
    if printf '%s' "$segment" | grep -qE '(^|[`$(])[[:space:]]*gh[[:space:]]+pr[[:space:]]+merge([[:space:]]|$)'; then
        merge_segment="$segment"
        break
    fi
done <<EOF
$normalised
EOF
[ -z "$merge_segment" ] && exit 0

# Extract the selector + --repo from the merge segment only;
# selector = first non-flag token after the `merge` verb.
sel=""; repo=""
set -f
# shellcheck disable=SC2086
set -- $merge_segment
set +f
seen_merge=0
while [ "$#" -gt 0 ]; do
    if [ "$seen_merge" = "0" ]; then
        [ "$1" = "merge" ] && seen_merge=1
        shift; continue
    fi
    case "$1" in
        --repo=*) repo="${1#--repo=}" ;;
        --repo|-R) if [ "$#" -ge 2 ]; then repo="$2"; shift; fi ;;
        # gh pr merge's own value-taking flags: consume the value token so it
        # is never mistaken for the selector (coderabbit CR round; the rc=3
        # re-anchor still backstops flags this list misses).
        -b|--body|-F|--body-file|-t|--subject|--match-head-commit|-A|--author-email)
            if [ "$#" -ge 2 ]; then shift; fi ;;
        --*|-*) ;;             # other flags: ignore (an unknown value-taking
                               # flag may feed a value token; a wrong selector
                               # only fails gh pr view = rc 3 -> re-anchor,
                               # never a false block)
        *) [ -z "$sel" ] && sel="$1" ;;
    esac
    shift
done

# Strip surrounding quotes the tokenizer preserved: `gh pr merge "42"` must
# not hand the literal `"42"` to gh (codex-adv-1 — quoted selector dodged the
# gate via the pr-view fail-open).
sel="${sel#\"}"; sel="${sel%\"}"; sel="${sel#\'}"; sel="${sel%\'}"
repo="${repo#\"}"; repo="${repo%\"}"; repo="${repo#\'}"; repo="${repo%\'}"

# The cwd branch — fallback anchor when no/bad selector was extracted.
cwd_branch=""
cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null || true)
if [ -n "$cwd" ] && command -v git >/dev/null 2>&1; then
    cwd_branch=$(git -C "$cwd" branch --show-current 2>/dev/null || true)
fi

# No explicit selector: gh infers the current branch; do the same.
[ -z "$sel" ] && sel="$cwd_branch"
[ -z "$sel" ] && exit 0   # cannot resolve target: fail open

# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/cr-merge-gate.sh" 2>/dev/null || exit 0

reason=""
rc=0
reason=$(cr_merge_gate "$sel" "$repo") || rc=$?
if [ "$rc" = "3" ] && [ -n "$cwd_branch" ]; then
    # The extracted token did not resolve to a PR (a value-taking flag's
    # argument or leftover quoting mistaken for the selector — codex-1).
    # Re-anchor to the cwd branch IN THE CWD REPO (drop the extracted repo:
    # it may itself be a quote placeholder — coderabbit app round) so
    # ordinary CLI syntax cannot dodge the gate; if this ALSO fails to
    # resolve, the gate stays fail-open. Guard against re-running the
    # identical lookup (same branch, no repo override).
    if [ "$cwd_branch" != "$sel" ] || [ -n "$repo" ]; then
        rc=0
        reason=$(cr_merge_gate "$cwd_branch" "") || rc=$?
    fi
fi
if [ "$rc" = "2" ]; then
    echo "block-unresolved-cr-merge: $reason" >&2
    exit 2
fi

# ── CI-green merge gate (HIMMEL-1043) — runs SECOND, after the CR gate ──
# Same extracted selector ($sel)/$repo + rc=3 re-anchor pattern as the CR gate
# above; the CI gate is independent (its own bypass CI_MERGE_GATE_OK=1) and
# never coupled to CR_PROFILE. A guard bug must NEVER block a legit merge, so
# every unresolvable/degraded path fails open (rc 0/3) inside ci_green_gate.
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/ci-green-gate.sh" 2>/dev/null || exit 0

ci_reason=""
ci_rc=0
ci_reason=$(ci_green_gate "$sel" "$repo") || ci_rc=$?
if [ "$ci_rc" = "3" ] && [ -n "$cwd_branch" ]; then
    # Mirror the CR gate's re-anchor: the extracted token did not resolve to a
    # PR, so retry once on the cwd branch (in the cwd repo) so ordinary CLI
    # syntax cannot dodge the gate; if this also fails, ci_green_gate fails open.
    if [ "$cwd_branch" != "$sel" ] || [ -n "$repo" ]; then
        ci_rc=0
        ci_reason=$(ci_green_gate "$cwd_branch" "") || ci_rc=$?
    fi
fi
if [ "$ci_rc" = "2" ]; then
    echo "block-red-ci-merge: $ci_reason" >&2
    exit 2
fi
exit 0
