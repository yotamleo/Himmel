#!/usr/bin/env bash
# PreToolUse hook: block-unresolved-cr-merge.sh
#
# Blocks `gh pr merge` on THREE independent gates, run in order:
#   1. CR gate (HIMMEL-936): unresolved CodeRabbit review threads or a
#      CodeRabbit check-run still running on the head SHA (except a proven old
#      zombie backed by success status + zero unresolved threads, HIMMEL-980;
#      operator rule 2026-07-11: never merge over unresolved CodeRabbit remarks).
#   2. CI-green gate (HIMMEL-1043): the PR's head SHA must have green overall
#      CI — no failing/pending check-run, no failing/pending combined status.
#      This repo has NO branch protection, so GitHub will not otherwise block a
#      merge over red/pending CI (operator rule: "ready to merge" requires green).
#   3. Console-GO gate (HIMMEL-2919/HIMMEL-3142): when this is a console-spawned
#      leg (HIMMEL_CONSOLE_LEG truthy, exported by headed-arm-leg.sh), the PR's
#      head SHA must have a matching GO file under the handover root's
#      `.locks/go/` (console-kit/go.sh writes it — "the file IS the GO"). Before
#      this gate existed, a leg merging via `gh pr merge` directly (instead of
#      merge-on-green.sh) never consulted `.locks/go/` at all, so the GO was
#      advisory rather than binding on that path (PR #798). No bypass env var —
#      same as merge-on-green.sh's own console-GO gate, which this one shares
#      its predicate with (scripts/lib/go-gate.sh) so the two cannot drift.
#      Untouched for a non-leg session (HIMMEL_CONSOLE_LEG unset/falsy skips it
#      whole, no extra gh call).
# Sibling of check-cr-marker-on-pr-create.sh / block-merged-pr-commit.sh.
#
# Exit: 0 allow (incl. every fail-open path), 2 block (stderr shown to model).
# Bypass: CR_MERGE_GATE_OK=1 and/or CI_MERGE_GATE_OK=1 in the LAUNCHING shell
# (each gates its own check independently). CR_PROFILE=none skips the CR gate.
# The console-GO gate has no bypass (see gate 3 above).
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
sel=""; repo=""; match_head=""
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
        # --match-head-commit is captured (not just consumed) so gate 3 can
        # verify a leg's merge pins the head its GO was bound to (HIMMEL-3142
        # CR round). Both spellings: the space form below, and =-form here.
        --match-head-commit=*) match_head="${1#--match-head-commit=}" ;;
        --match-head-commit)
            if [ "$#" -ge 2 ]; then match_head="$2"; shift; fi ;;
        # gh pr merge's own value-taking flags: consume the value token so it
        # is never mistaken for the selector (coderabbit CR round; the rc=3
        # re-anchor still backstops flags this list misses).
        -b|--body|-F|--body-file|-t|--subject|-A|--author-email)
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
match_head="${match_head#\"}"; match_head="${match_head%\"}"
match_head="${match_head#\'}"; match_head="${match_head%\'}"

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

# ── Console-GO merge gate (HIMMEL-2919/HIMMEL-3142) — runs THIRD, after CR
# and CI — see the header comment for gate 3. Only binds a console-spawned leg
# (console_leg truthy, scripts/lib/go-gate.sh — HIMMEL-3149); a non-leg
# session (HIMMEL_CONSOLE_LEG unset/empty, by far the common case) never
# reaches the `. go-gate.sh` below, so it costs an ordinary merge nothing —
# including the case where go-gate.sh itself is missing or broken; this gate
# must never turn a broken library into a blocker for sessions it was never
# meant to bind.
#
# console_leg lives in scripts/lib/go-gate.sh beside go_gate() itself, shared
# with merge-on-green.sh's own console-GO gate and go.sh's own refusal, so
# none of the three can drift on "is this a leg". The five-spelling
# interpretation (empty/0/false/off/no, case-insensitive, whitespace-stripped)
# is console_leg's alone — this outer check is only "is the var non-empty at
# all", cheap enough not to duplicate that logic, so an explicitly-set falsy
# value (e.g. HIMMEL_CONSOLE_LEG=0) still sources go-gate.sh and gets the
# real, shared interpretation.
is_leg=1
if [ -n "${HIMMEL_CONSOLE_LEG:-}" ]; then
    # Drop any go_gate/console_leg already in scope first (a PATH executable
    # or an inherited `export -f` would otherwise survive the source below
    # undetected) so only the file's own definitions can satisfy the
    # declare -F checks below.
    unset -f go_gate console_leg go_mac go_key_file go_resolve_root _go_in_harness 2>/dev/null || true
    # shellcheck source=scripts/lib/go-gate.sh
    # shellcheck disable=SC1091
    if ! . "$SCRIPT_DIR/../lib/go-gate.sh" 2>/dev/null || ! declare -F console_leg >/dev/null 2>&1; then
        echo "block-unresolved-cr-merge: cannot load scripts/lib/go-gate.sh — refusing (the console-leg marker check must fail closed, not silently no-op)" >&2
        exit 2
    fi
    console_leg || is_leg=0
else
    is_leg=0
fi
if [ "$is_leg" -eq 1 ]; then
    # Resolve pr-number + head-sha the same way cr_merge_gate/ci_green_gate
    # do above (own `gh pr view`, same $sel/$repo, same re-anchor to
    # $cwd_branch on an unresolvable selector) — an unresolvable selector
    # here would also fail the `gh pr merge` this hook is gating, so it
    # fails OPEN like its siblings. Only the GO FILE check below is
    # fail-closed (GATE INTEGRITY): once the PR and head are known, an
    # ambiguous or missing GO must never read as "no gate".
    go_meta=""
    if [ -n "$repo" ]; then
        go_meta=$(gh pr view "$sel" --repo "$repo" --json number,headRefOid 2>/dev/null) || go_meta=""
    else
        go_meta=$(gh pr view "$sel" --json number,headRefOid 2>/dev/null) || go_meta=""
    fi
    go_num=$(printf '%s' "$go_meta" | jq -r '.number // empty' 2>/dev/null || true)
    go_sha=$(printf '%s' "$go_meta" | jq -r '.headRefOid // empty' 2>/dev/null || true)
    if { [ -z "$go_num" ] || [ -z "$go_sha" ]; } && [ -n "$cwd_branch" ] && { [ "$cwd_branch" != "$sel" ] || [ -n "$repo" ]; }; then
        go_meta=$(gh pr view "$cwd_branch" --json number,headRefOid 2>/dev/null) || go_meta=""
        go_num=$(printf '%s' "$go_meta" | jq -r '.number // empty' 2>/dev/null || true)
        go_sha=$(printf '%s' "$go_meta" | jq -r '.headRefOid // empty' 2>/dev/null || true)
    fi
    if [ -z "$go_num" ] || [ -z "$go_sha" ]; then
        exit 0
    fi

    go_root=""
    # shellcheck source=scripts/lib/handover-path.sh
    # shellcheck disable=SC1091
    # HIMMEL-3573 row 1: go_resolve_root is the same resolver go.sh writes
    # through, so a leg running `gh pr merge` directly with no HANDOVER_DIR in
    # its own env still lands on the anchor's .env-configured root, the one a
    # valid console GO was actually written under — a plain handover_root()
    # here fell back to the harness repo's inline stub instead and falsely
    # refused a valid GO.
    if . "$SCRIPT_DIR/../lib/handover-path.sh" 2>/dev/null && declare -F go_resolve_root >/dev/null 2>&1; then
        go_root=$(go_resolve_root "$SCRIPT_DIR/../.." 2>/dev/null) || go_root=""
    fi
    # go-gate.sh is already sourced above (console_leg check) — only confirm
    # go_gate and go_mac are defined (a truncated file could define
    # console_leg but not the rest).
    if ! declare -F go_gate >/dev/null 2>&1 || ! declare -F go_mac >/dev/null 2>&1; then
        echo "block-unresolved-cr-merge: scripts/lib/go-gate.sh sourced but go_gate is not defined (truncated file?) — refusing (a console-spawned leg's GO gate must fail closed, not silently no-op)" >&2
        exit 2
    fi
    # HIMMEL-3578: the GO mac binds the repo, so resolve nwo the same way
    # merge-on-green.sh does — from an explicit --repo/-R on the merge command
    # itself when given (already extracted into $repo above), else the
    # current checkout. `gh repo view` is timeout-bounded: this hook runs on
    # a budget, and a hang here must read as a refusal, never as an allow.
    go_nwo="$repo"
    if [ -z "$go_nwo" ]; then
        # HIMMEL-3578 (round 2): resolve the GNU-semantics `timeout` through
        # the shared resolver, which also tries `gtimeout` — a bare `timeout`
        # check alone left every merge refused on stock macOS (no coreutils),
        # since the block below was skipped whole and go_nwo stayed empty.
        # shellcheck disable=SC1091
        # shellcheck source=../lib/timeout-bin.sh
        . "$SCRIPT_DIR/../lib/timeout-bin.sh"
        if [ -n "${_TIMEOUT_BIN:-}" ]; then
            go_nwo=$("$_TIMEOUT_BIN" 5 gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || go_nwo=""
        else
            # HIMMEL-3585: neither `timeout` nor `gtimeout` is on PATH, so the
            # bound above is unavailable — a bare `gh repo view` here would run
            # UNBOUNDED and a hang would fail this fail-closed hook OPEN via
            # Claude Code's own hook timeout instead of reading as a refusal.
            # Bash-native bound: background `gh`, poll for up to 5s, then
            # kill it and treat that exactly like a timeout (empty go_nwo).
            _gh_out="$(mktemp "${TMPDIR:-/tmp}/block-unresolved-cr-merge-gh.XXXXXX" 2>/dev/null)" || _gh_out=""
            if [ -z "$_gh_out" ]; then
                go_nwo=""
            else
                gh repo view --json nameWithOwner --jq .nameWithOwner >"$_gh_out" 2>/dev/null &
                _gh_pid=$!
                _gh_waited=0
                while [ "$_gh_waited" -lt 5 ] && kill -0 "$_gh_pid" 2>/dev/null; do
                    sleep 1
                    _gh_waited=$((_gh_waited + 1))
                done
                if kill -0 "$_gh_pid" 2>/dev/null; then
                    kill -9 "$_gh_pid" 2>/dev/null
                    go_nwo=""
                else
                    go_nwo="$(cat "$_gh_out" 2>/dev/null)"
                fi
                wait "$_gh_pid" 2>/dev/null
                rm -f "$_gh_out"
            fi
        fi
    fi
    if [ -z "$go_nwo" ]; then
        echo "block-unresolved-cr-merge: cannot resolve this repo's owner/name for PR #$go_num — refusing (GATE INTEGRITY: the GO mac binds the repo). Pass --repo <owner>/<name>, or run from a checkout gh can resolve." >&2
        exit 2
    fi
    go_reason=""
    go_rc=0
    go_reason=$(go_gate "$go_num" "$go_sha" "$go_root" "$go_nwo") || go_rc=$?
    if [ "$go_rc" -ne 0 ]; then
        if [ -z "$go_reason" ]; then
            go_reason="go_gate for PR #$go_num at $go_sha returned an unexpected exit code ($go_rc) — this is a console-spawned leg; send READY to your console and wait for GO"
        fi
        echo "block-unresolved-cr-merge: $go_reason" >&2
        exit 2
    fi

    # A confirmed GO is bound to $go_sha, but that is THIS hook's own
    # `gh pr view` read, not a property of the merge command that
    # follows — a separate `gh pr merge` invocation can land a different
    # commit unless it pins one itself (coderabbit CR round). Only this
    # half is fail-closed (GATE INTEGRITY, same boundary as the GO-file
    # check above): the resolution above still fails OPEN on an
    # unresolvable selector like its siblings, but once a GO is
    # confirmed valid, an unpinned or mismatched merge command must
    # never pass.
    if [ -z "$match_head" ]; then
        echo "block-unresolved-cr-merge: a console-spawned leg's merge must pin --match-head-commit $go_sha (the head the GO for PR #$go_num was bound to) — none was given" >&2
        exit 2
    fi
    if [ "$match_head" != "$go_sha" ]; then
        echo "block-unresolved-cr-merge: --match-head-commit $match_head does not match the GO-bound head $go_sha for PR #$go_num — refusing" >&2
        exit 2
    fi
fi
exit 0
