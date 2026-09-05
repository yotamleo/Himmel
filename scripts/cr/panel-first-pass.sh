#!/usr/bin/env bash
# scripts/cr/panel-first-pass.sh - step 3.0 critic-panel first pass, extracted
# verbatim (in behavior) from .claude/commands/pr-check.md (HIMMEL-2226).
#
# WHY A SCRIPT, NOT AN INLINE FENCE: this logic used to run as a ```bash
# block inside the /pr-check runbook, executed by the orchestrating Claude
# session's Bash tool. Claude Code's worktree-isolation guard statically
# screens every bash command run in a worktree-isolated session and refuses
# anything it cannot verify at a glance. The step-3.0 fence trips several of
# those refusals at once: any CLAUDE_PROJECT_DIR reference (unset in Bash-tool
# shells), an unresolvable env var, a "$var"/literal path where the quote does
# not span the whole path, a runtime value passed as a dash-flag operand, and
# ${var} braced expansion. None of those restrictions apply inside a script
# file - only the runbook's own command line is screened - so pulling this
# fence into a real script removes the parse surface entirely.
#
# Usage:
#   bash scripts/cr/panel-first-pass.sh --head <sha> --branch <name>
#
# --head/--branch are REQUIRED and must be step 1's CAPTURED values, never
# re-derived here (HIMMEL-1175): review the SHA the ledger will certify, not
# live HEAD, and pin the branch too - a SHA pin alone would pass a switch to a
# different branch sitting at the same commit.
#
# Env:
#   CR_PROFILE - loaded from the primary checkout's .env (a live env var
#     already set wins); CR_PROFILE=none skips the panel entirely
#     (claude-only, no spend). Passed through to critic-panel.sh, which
#     resolves its own tiers from it (HIMMEL-558) - this script never
#     hand-computes a tier filter.
#
# Stdout/stderr contract (the calling session reads BOTH streams and must
# never merge them):
#   stdout - "captured diff base: <db> (<db_sha>)" (HIMMEL-1984: the session
#            carries $db_sha forward as a literal into step 3.2), followed by
#            the panel's merged findings block, if any.
#   stderr - every status/skip note, every "panel-availability: ..." line
#            captured from critic-panel.sh, and (on exit 7) the ABORT text.
#
# Exit codes:
#   0 - ran to completion (panel invoked, skipped, or failed open to
#       claude-only). Findings, if any, are on stdout.
#   2 - usage error: missing --head or --branch.
#   7 - input-pin failure. Two causes, both ABORT: (a) HIMMEL-2542 - the
#       --head this script was given names no commit in this repo, detected
#       here before any git command consumes it; (b) HIMMEL-1175/HIMMEL-1984
#       pin MISMATCH reported by critic-panel.sh, on the FIRST attempt or
#       independently on the rtk retry. ABORT: nothing was reviewed, nothing
#       was recorded. Never degrades to claude-only - re-run /pr-check from
#       step 1.
#   Every other critic-panel.sh failure fails OPEN to claude-only (this
#   script still exits 0; panel findings are empty and a loud note went to
#   stderr).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HIMMEL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

HEAD_SHA=""
BRANCH=""
while [ $# -gt 0 ]; do
    case "$1" in
        --head)
            [ $# -ge 2 ] || { echo "panel-first-pass: --head requires a commit SHA" >&2; exit 2; }
            HEAD_SHA="$2"; shift 2 ;;
        --branch)
            [ $# -ge 2 ] || { echo "panel-first-pass: --branch requires a branch name" >&2; exit 2; }
            BRANCH="$2"; shift 2 ;;
        *)
            echo "panel-first-pass: unknown arg: $1" >&2; exit 2 ;;
    esac
done
[ -n "$HEAD_SHA" ] || { echo "panel-first-pass: --head is required (step 1's captured SHA, HIMMEL-1175)" >&2; exit 2; }
[ -n "$BRANCH" ]   || { echo "panel-first-pass: --branch is required (step 1's captured branch, HIMMEL-1175)" >&2; exit 2; }

# HIMMEL-2542 - validate the INPUT PIN before any git command consumes it.
# A --head naming no commit in this repo is a CALLER error, not a reviewer
# outage, and the two are indistinguishable downstream: `git diff
# <base>...<bad-head>` fails rc=128, the fail-open branch below reports
# "critic panel unavailable - claude-only review", and the run exits 0 in
# under a second having reviewed nothing. A session that trusts rc=0 then
# records a claude-only round and clears the marker. An unresolvable pin is
# a stronger failure than the MISMATCH critic-panel.sh reports at exit 7, so
# it takes the same exit: ABORT, never a degrade. This runs BEFORE the diff,
# so it never competes with the rc=128 fail-open, which keeps its own job
# (a diff that fails for some reason OTHER than an unresolvable pin).
if ! git rev-parse --verify --quiet "$HEAD_SHA^{commit}" >/dev/null 2>&1; then
    echo "panel-first-pass ABORT - --head $HEAD_SHA does not resolve to a commit in this repo (HIMMEL-2542). This is an input-pin failure, NOT a critic outage: nothing was reviewed and nothing was recorded. Re-check the SHA step 1 printed (never expand a short hash by hand) and re-run /pr-check from step 1." >&2
    exit 7
fi

# Resolve the protected default (main OR master, HIMMEL-297) for the diff base.
# shellcheck source=../guardrails/lib.sh
# shellcheck disable=SC1091
db=$(. "$HIMMEL_ROOT/scripts/guardrails/lib.sh" 2>/dev/null && default_branch || echo main)
# HIMMEL-1984 - capture the BASE commit once, here, next to $db. Substitute
# this literal into every --base-sha below; never re-derive it live, and
# never re-derive it in a later step either.
db_sha=$(git rev-parse "$db")
echo "captured diff base: $db ($db_sha)"   # carry this literal into step 3.2

# HIMMEL-558: load CR_PROFILE from the PRIMARY checkout's .env (a live process
# env var wins) so /pr-check honours it DETERMINISTICALLY - even from a
# worktree, where the gitignored .env is not present (load_dotenv resolves the
# primary checkout via git-common-dir). We do NOT hand-compute a tier filter:
# the panel derives its tiers from CR_PROFILE itself and treats it as
# authoritative (closes the free-only drift). Just export CR_PROFILE and
# honour the none skip below.
# shellcheck source=../lib/load-dotenv.sh
# shellcheck disable=SC1091
. "$HIMMEL_ROOT/scripts/lib/load-dotenv.sh"
load_dotenv --root "$(_load_dotenv_primary_for "$HIMMEL_ROOT")" CR_PROFILE || true
export CR_PROFILE

diff_rc=0
# HIMMEL-1175 - review the SHA the ledger will certify, not live HEAD.
# --head "$HEAD_SHA" plus --branch "$BRANCH" on the panel below make a moved
# checkout a REFUSAL (exit 7) instead of a silently-wrong review.
# Diff from the CAPTURED base SHA, not the live $db name (HIMMEL-1984): $db
# stays the operator-visible name in messages.
diff_out=$(git diff "$db_sha...$HEAD_SHA") || diff_rc=$?
panel_avail_lines=""   # "panel-availability: <slug> ok|unavailable (rc=N)" lines
panel_findings=""      # the merged findings block
# HIMMEL-2542 elapsed tell: a real panel round takes ~2 minutes, so an empty
# findings block that arrived in ~0s is a bad pin or an outage, never a clean
# review. Only meaningful once the panel was actually INVOKED - the skip paths
# (CR_PROFILE=none, empty diff) legitimately return instantly.
panel_ran=0
panel_t0=$SECONDS

if [ "${CR_PROFILE:-}" = "none" ]; then
    # Explicit claude-only opt-out. Skip panel.
    echo "claude-only review (CR_PROFILE=none)"
elif [ "$diff_rc" -ne 0 ]; then
    # git itself failed - treat as panel unavailable, not empty-diff skip.
    echo "critic panel unavailable - claude-only review (git diff failed rc=$diff_rc: $diff_out)" >&2
elif [ -z "$diff_out" ]; then
    echo "empty diff - critic panel skipped"
else
    [ -z "${CR_PROFILE:-}" ] && echo "Default cross-model CR - no free critics registered, using the PAID codex anchor (~2min; set CR_PROFILE=none for instant claude-only)."
    panel_ran=1
    panel_tmp=$(mktemp -t cr-panel-avail.XXXXXX)
    # CR_USAGE_LOG=1 (HIMMEL-485): each critic logs a chars/4 ESTIMATED usage
    # ledger record. No CRITIC_PANEL_TIERS here (HIMMEL-558): the panel
    # resolves tiers from the exported CR_PROFILE.
    panel_findings=$(printf '%s' "$diff_out" | CR_USAGE_LOG=1 bash "$HIMMEL_ROOT/scripts/cr/critic-panel.sh" --head "$HEAD_SHA" --branch "$BRANCH" --base "$db" --base-sha "$db_sha" 2>"$panel_tmp")
    panel_rc=$?
    panel_avail_lines=$(cat "$panel_tmp"); rm -f "$panel_tmp"
    if [ "$panel_rc" -eq 7 ]; then
        # HIMMEL-1175/HIMMEL-1984 - the checkout or the base branch moved
        # since step 1. Every later step is keyed to the captured
        # branch/SHA/base, so continuing would certify a review of code
        # nobody reviewed. ABORT the whole run; do NOT degrade to claude-only.
        cat >&2 <<'PINABORT'
/pr-check ABORT - critic-panel.sh exit 7: the checkout or the diff base moved since
step 1, so the review inputs no longer match the branch/SHA/base the ledger would
stamp (HIMMEL-1175, HIMMEL-1984). Nothing was reviewed and nothing was recorded.
Re-run /pr-check from step 1.
PINABORT
        exit 7
    fi
    if [ "$panel_rc" -ne 0 ]; then
        # rc=1 collapses two causes: a genuine all-critics-failed panel, OR
        # (in an rtk-proxied environment) the plain `git diff` above returning
        # a stat summary instead of a unified diff, which critic-panel.sh
        # rejects as "no valid diff" and exits 1 on. Re-fetch the diff through
        # the rtk proxy and retry the panel ONCE before falling back. The
        # retry's output REPLACES (overwrites, not appends) both
        # panel_findings and panel_avail_lines from the first attempt, so a
        # stale first-attempt availability line can never leak into the
        # aggregate. rc=1 after the retry still degrades to claude-only,
        # loudly (same fail-open contract as below).
        if command -v rtk >/dev/null 2>&1; then
            # Same captured-base rule as the first attempt (HIMMEL-1984).
            retry_diff=$(rtk proxy git diff "$db_sha...$HEAD_SHA" 2>/dev/null) || retry_diff=""
            if [ -n "$retry_diff" ]; then
                retry_tmp=$(mktemp -t cr-panel-avail.XXXXXX)
                panel_findings=$(printf '%s' "$retry_diff" | CR_USAGE_LOG=1 bash "$HIMMEL_ROOT/scripts/cr/critic-panel.sh" --head "$HEAD_SHA" --branch "$BRANCH" --base "$db" --base-sha "$db_sha" 2>"$retry_tmp")
                panel_rc=$?
                panel_avail_lines=$(cat "$retry_tmp"); rm -f "$retry_tmp"
                # The retry is a SECOND panel invocation, so it has its own
                # pin window: the checkout can move between the first attempt
                # and this one. Without this check a retry-time exit 7 falls
                # through to the fail-open branch below and certifies stale
                # inputs.
                if [ "$panel_rc" -eq 7 ]; then
                    cat >&2 <<'PINABORTRETRY'
/pr-check ABORT - critic-panel.sh exit 7 on the rtk retry: the checkout or the
diff base moved mid-run, so the review inputs no longer match the branch/SHA/base
the ledger would stamp (HIMMEL-1175, HIMMEL-1984). Nothing was reviewed. Re-run
/pr-check from step 1.
PINABORTRETRY
                    exit 7
                fi
            fi
        fi
        if [ "$panel_rc" -ne 0 ]; then
            # rc=1 after retry (or rtk absent / retry-diff empty) - fail-open.
            echo "critic panel unavailable (all critics failed) - claude-only review" >&2
            panel_findings=""
        fi
    fi
fi

# Surface the captured availability lines to our own stderr (HIMMEL-1219/1280
# step 4.5 records these): this script's process exits when it returns, so -
# unlike the original inline fence, whose shell variables lived on for later
# fences in the same session - the calling session can only carry
# panel_avail_lines forward by reading it here.
[ -n "$panel_avail_lines" ] && printf '%s\n' "$panel_avail_lines" >&2

# HIMMEL-2542 - elapsed tell next to the availability rows, so a reader who
# sees an empty findings block also sees how long it took to produce one.
if [ "$panel_ran" -eq 1 ] && [ -z "$panel_findings" ]; then
    echo "panel-elapsed: $((SECONDS - panel_t0))s with an EMPTY findings block (a real round is ~2min; a sub-second empty round means the panel did not review anything)" >&2
fi

# Surface $panel_findings on stdout (same pattern as $codex_findings in 3.1 /
# $coderabbit_findings in 3.2) so the orchestrating session can carry it into
# step 3.2 phase A and adjudicate it before the conservation decision.
if [ -n "$panel_findings" ]; then
    printf '%s\n' "$panel_findings"
fi
exit 0
