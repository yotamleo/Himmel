#!/usr/bin/env bash
# PreToolUse hook: block-unresolved-cr-merge.sh
#
# Blocks `gh pr merge` while the PR has unresolved CodeRabbit review threads
# or a CodeRabbit check-run still running on the head SHA (HIMMEL-936), except
# a proven old zombie backed by success status + zero unresolved threads (HIMMEL-980;
# operator rule 2026-07-11: never merge over unresolved CodeRabbit remarks).
# Sibling of check-cr-marker-on-pr-create.sh / block-merged-pr-commit.sh.
#
# Exit: 0 allow (incl. every fail-open path), 2 block (stderr shown to model).
# Bypass: CR_MERGE_GATE_OK=1 in the LAUNCHING shell. CR_PROFILE=none skips.
set -uo pipefail
# NOT set -e: fail-open hook, must never abort on a sub-call's rc 1.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ "${CR_MERGE_GATE_OK:-0}" = "1" ] && exit 0
[ "${CR_PROFILE:-}" = "none" ] && exit 0

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
exit 0
