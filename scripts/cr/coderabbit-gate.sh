#!/usr/bin/env bash
# scripts/cr/coderabbit-gate.sh - /pr-check step 3.2 phase B (conserve-or-run
# CodeRabbit) as a real script, extracted verbatim in behaviour from
# .claude/commands/pr-check.md (HIMMEL-2226).
#
# WHY THIS IS A SCRIPT NOW: /pr-check's ```bash fences are run verbatim by the
# orchestrating Claude session through the Bash tool, and a worktree-isolated
# session screens every one of those commands with a static guard
# (check-worktree-isolation, HIMMEL-... family) that refuses shapes it cannot
# verify: any "${CLAUDE_PROJECT_DIR:?}" reference (unset in Bash-tool shells),
# an unresolvable env var, `cd "$var"`, a runtime value as a dash-flag operand,
# and more. The phase-B fence trips several of these and cannot be made
# reliably guard-clean inline. None of those restrictions apply inside a
# script file - only the runbook's own command LINE is screened - so this
# extraction removes the parse surface entirely instead of contorting the
# fence to satisfy a static guard it was never designed against.
#
# Usage:
#   bash scripts/cr/coderabbit-gate.sh --head <sha> --branch <name> --base-sha <sha>
#
# Arguments (all REQUIRED - step 1's captured $head/$branch and step 3.0's
# captured $db_sha; this script does not re-derive them, HIMMEL-1175/HIMMEL-1984):
#   --head <sha>      the HEAD sha the ledger stamps (step 1)
#   --branch <name>   the branch name the ledger stamps (step 1)
#   --base-sha <sha>  the base-end sha pin for the reviewed range (step 3.0)
#
# The base branch NAME ($db) is still re-derived internally here, exactly as
# the fence did - only the base SHA is a caller-supplied pin.
#
# stdout: CodeRabbit findings ONLY - the captured $coderabbit_findings
#   passthrough at the bottom of this file and nothing else. Step 4.5 / the
#   aggregate step turns every line on this stream into a [coderabbit-N]
#   blocking candidate, so an advisory printed here becomes a PHANTOM
#   CodeRabbit finding. Inline this was safe (the fence's stdout was the
#   transcript, and $coderabbit_findings was captured separately from
#   coderabbit-review.sh); as a script it is not - hence every echo below is
#   >&2 except that one passthrough.
# stderr: every advisory/diagnostic message this script emits - the ones the
#   fence already sent to stderr AND the rc=3 "CLI not configured" skip
#   notices the fence wrote to the transcript, PLUS
#   one deliberate addition not in the original prose: the
#   `panel-availability: coderabbit ...` line the fence only captured into a
#   shell variable ($coderabbit_avail) for step 4.5 to read out of session
#   state. A script cannot leak a shell variable back to the orchestrating
#   session, so this line is printed to stderr instead (including the
#   synthesised "(conserved)" line) whenever the fence would have set it.
#   The two streams are never merged.
#
# Exit codes:
#   0  ran to completion (CodeRabbit may have run, been conserved, or been
#      skipped - see stderr for which)
#   2  usage error - a required flag is missing
#   5  ABORT - nothing was reviewed. Either (a) HIMMEL-2542: --head or
#      --base-sha names no commit in this repo, caught by this gate before
#      the reviewer is spent; or (b) coderabbit-review.sh REFUSED before
#      reviewing anything - an input-pin mismatch (the checkout or diff base
#      moved since capture) or a setup failure that would have made such a
#      refusal, or the review's own output, silently degrade. All are aborts,
#      never degrades, and all want the same response - re-run /pr-check from
#      step 1. For (b) the specific cause is on the review's stderr, which
#      this gate relays.
#
# Load-bearing specifics carried over unchanged from the fence (see the
# comments inline below for the WHY on each):
#   - the conservation count is DERIVED by awk from the phase-A verdicts file,
#     never asserted; {disproved, unaddressed} for the same id BLOCKS.
#   - empty/missing/unreadable/non-numeric verdicts file -> 0 blockers -> RUN
#     CodeRabbit (fail-open).
#   - a CONSERVED run records reason=conserved, never `ok`.
#   - rc=5 from coderabbit-review.sh is an ABORT, never a degrade.
#   - rc=3 (CLI absent) branches on cr_app_configured; a missing
#     scripts/lib/cr-available.sh degrades to the generic skip message
#     (fail-open) instead of breaking the handler.
#   - rc=4 (rate-limited) records unavailable; any other non-zero clears
#     findings and continues.
#   - the cr_trigger_repo_armed unarmed check (HIMMEL-2034/2035) is reused
#     verbatim, not re-derived.
#   - CR_PROFILE=none skips the pass entirely.
#   - the scratch-file branch is the CAPTURED --branch, the same value the
#     CodeRabbit call is pinned to (HIMMEL-1175 as amended by HIMMEL-2226) -
#     phase A writes that file under the captured branch, so a reader that
#     re-derived the live branch would read a different file.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HIMMEL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

head=""
branch=""
db_sha=""
while [ $# -gt 0 ]; do
    case "$1" in
        --head)
            [ $# -ge 2 ] || { echo "coderabbit-gate.sh: --head requires a value" >&2; exit 2; }
            head="$2"; shift 2 ;;
        --branch)
            [ $# -ge 2 ] || { echo "coderabbit-gate.sh: --branch requires a value" >&2; exit 2; }
            branch="$2"; shift 2 ;;
        --base-sha)
            [ $# -ge 2 ] || { echo "coderabbit-gate.sh: --base-sha requires a value" >&2; exit 2; }
            db_sha="$2"; shift 2 ;;
        *)
            echo "coderabbit-gate.sh: unknown arg $1" >&2; exit 2 ;;
    esac
done
[ -n "$head" ] || { echo "coderabbit-gate.sh: --head is required" >&2; exit 2; }
[ -n "$branch" ] || { echo "coderabbit-gate.sh: --branch is required" >&2; exit 2; }
[ -n "$db_sha" ] || { echo "coderabbit-gate.sh: --base-sha is required" >&2; exit 2; }

# HIMMEL-2542 - both SHA pins must name a real commit HERE, checked before the
# scarce reviewer is spent on them. A well-formed 40-hex value that names no
# object is a caller error (a short hash expanded by hand is the observed
# case); passed through, it reaches coderabbit-review.sh's own range
# construction and degrades there into something that reads as a reviewer
# problem. Same disposition as the reviewer's own pre-review refusal, so the
# same documented exit: 5, ABORT, never a degrade. --branch is deliberately
# NOT checked: it is a pin on a NAME (HIMMEL-1175) whose whole job is to be
# comparable to a value captured earlier, and the captured branch may
# legitimately no longer exist in this checkout.
if ! git rev-parse --verify --quiet "$head^{commit}" >/dev/null 2>&1; then
    echo "coderabbit-gate.sh ABORT - --head $head does not resolve to a commit in this repo (HIMMEL-2542). This is an input-pin failure, NOT a reviewer outage: CodeRabbit was not called, nothing was reviewed and nothing was recorded. Re-check the SHA step 0 printed and re-run /pr-check from step 1." >&2
    exit 5
fi
if ! git rev-parse --verify --quiet "$db_sha^{commit}" >/dev/null 2>&1; then
    echo "coderabbit-gate.sh ABORT - --base-sha $db_sha does not resolve to a commit in this repo (HIMMEL-2542). This is an input-pin failure, NOT a reviewer outage: CodeRabbit was not called, nothing was reviewed and nothing was recorded. Re-check the base SHA step 3.0 printed and re-run /pr-check from step 1." >&2
    exit 5
fi

# HIMMEL-2035 / HIMMEL-2034 predicate, sourced lazily and only here (the
# unarmed branch below) - a shell function so the two `.` sources can each
# carry their own shellcheck directive without splicing comments into a
# backslash-continued command (which would corrupt it).
_coderabbit_gate_repo_armed() {
    # shellcheck source=../lib/nwo.sh
    # shellcheck disable=SC1091
    . "$HIMMEL_ROOT"/scripts/lib/nwo.sh 2>/dev/null || return 1
    # shellcheck source=../lib/cr-trigger-ledger.sh
    # shellcheck disable=SC1091
    . "$HIMMEL_ROOT"/scripts/lib/cr-trigger-ledger.sh 2>/dev/null || return 1
    _cmg_canon_nwo "$(_cmg_local_nwo || true)" || return 1
    cr_trigger_repo_armed "$_CMG_CANON"
}

# shellcheck source=../guardrails/lib.sh
# shellcheck disable=SC1091
db=$(. "$HIMMEL_ROOT"/scripts/guardrails/lib.sh 2>/dev/null && default_branch || echo main)
# shellcheck source=../lib/load-dotenv.sh
# shellcheck disable=SC1091
. "$HIMMEL_ROOT"/scripts/lib/load-dotenv.sh; load_dotenv --root "$(_load_dotenv_primary_for "$HIMMEL_ROOT")" CR_PROFILE || true
# Phase B - DERIVE the adjudicated blocking count from the phase-A
# verdicts file, NOT a raw candidate count. Each bash fence here is
# independent; the verdicts file is the bridge. Apply the SAME exclusion
# rule step 4 uses (ONE rule, stated once, HIMMEL-1219 round 5): a
# candidate is EXCLUDED only when EVERY collected verdict for its ID is
# `disproved` OR `deferred`. Any `agreed`, `conflict`, or `unaddressed`
# verdict keeps it a blocker - so `{disproved, unaddressed}` BLOCKS (one
# reviewer's "no" does NOT cancel another's "cannot confirm or refute"),
# which is the fail-closed direction step 4's own `unaddressed` bullet
# demands. `deferred` (HIMMEL-2375) is a REAL finding, tracked onto another
# ticket rather than fixed on this branch - conserving CodeRabbit for it
# would mean an all-deferred round can NEVER let CodeRabbit run again (the
# panel re-raises the same deferred residuals every round, so the branch
# would livelock at 0 CodeRabbit calls forever); excluding it from the
# blocking count here does not un-track it - the CR ledger still carries the
# finding, its ticket and its reason via ledger-append.sh's own `deferred`
# verdict, which is a separate, unaffected mechanism. (One verdict per
# candidate at this point - agents have not run yet - but the rule handles
# the multi-verdict case identically.) Empty /
# missing / unreadable file -> 0 blockers -> RUN CodeRabbit (fail-open): a
# forgotten phase-A write OR a clean diff both run CodeRabbit, never
# silently conserve. The scratch file is scoped per-branch (round 1b) so
# concurrent runs on different worktrees do not race on ONE shared file, and
# the branch it is scoped to is the CAPTURED --branch. HIMMEL-1175 originally
# split this lookup off as a RE-DERIVED $prior_branch, so the scratch file
# tracked the checkout as it stands NOW; since HIMMEL-2226 the WRITER (step
# 3.2 phase A's write-verdicts.sh call) passes the captured branch literal, so
# a re-derived reader would read a DIFFERENT file than phase A wrote. A reader
# scoped differently from its writer is strictly worse than one that matches
# it: a mid-run same-SHA branch switch - precisely the case HIMMEL-1175 exists
# for, and the one the SHA pins cannot catch - would conserve the scarce
# CodeRabbit call on ANOTHER branch's surviving blockers and let the captured
# branch clear with no CodeRabbit review at all. Writer and reader therefore
# name ONE value by construction. The CodeRabbit call below uses that same
# CAPTURED $branch/$head (the values the ledger stamps) for the same reason.
# HIMMEL-1984 applies the same rule to the BASE: this fence
# re-derives $db (a NAME, harmless), but --base-sha below must carry STEP
# 3.0's captured $db_sha LITERAL. Fences do not share variables, so a
# `git rev-parse "$db"` here would capture the base as it stands NOW and pin
# the run to the very drift the flag exists to catch.
prior_file="$(git rev-parse --git-common-dir)/cr-prior-blocking/$branch"
prior_count=$(awk '
    /^VERDICT \[/ {
        id = $(0)
        sub(/^VERDICT \[/, "", id); sub(/\].*/, "", id)
        v = $(0)
        sub(/.*=[[:space:]]*/, "", v); sub(/[^a-z].*/, "", v)
        seen[id] = 1
        # HIMMEL-2375: deferred survivors never conserve, same as disproved.
        if (v != "disproved" && v != "deferred") nondisproved[id] = 1
    }
    END {
        n = 0
        for (id in seen)
            if (id in nondisproved) n++
        print n + 0
    }
' "$prior_file" 2>/dev/null || echo "")
case "$prior_count" in
    ''|*[!0-9]*)
        echo "prior-blocking signal UNKNOWN ($prior_file missing/unreadable/empty: '${prior_count:-<empty>}') - running CodeRabbit (fail-open, HIMMEL-1219)" >&2
        prior_blocking=0
        ;;
    *)
        if [ "$prior_count" -gt 0 ]; then prior_blocking=1; else prior_blocking=0; fi
        ;;
esac
coderabbit_findings=""; coderabbit_rc=0; coderabbit_avail=""
if [ "${CR_PROFILE:-}" = "none" ]; then
    : # claude-only - the coderabbit pass is ALSO skipped under none.
elif [ "$prior_blocking" = "1" ]; then
    # CONSERVED, not failed and not skipped-for-unconfigured: phase A left a
    # panel/codex candidate that survived adjudication, so a CodeRabbit pass
    # now is a wasted scarce call (the diff will change and need a fresh pass
    # after the fixes). Record unavailable-by-conservation (never ok) - a
    # conserved reviewer never ran; clear-cr-marker.sh gate 3 requires >=1
    # avail status=ok at the SHA, which the panel/codex passes that FOUND
    # the surviving blocker already provide.
    echo "coderabbit pass CONSERVED - phase A adjudication left $prior_count surviving panel/codex blocker(s); holding the scarce CodeRabbit call for the next pass after fixes (conserved, NOT failed)" >&2
    coderabbit_avail="panel-availability: coderabbit unavailable (conserved) reason=conserved"
elif ! _coderabbit_gate_repo_armed; then
    # HIMMEL-2035 / HIMMEL-2034 - CodeRabbit runs only on a repo this harness
    # owns the CR gate for. Reuse 2034's `cr_trigger_repo_armed` predicate
    # verbatim (git config --local himmel.coderabbit true on this clone whose
    # origin is that nwo, OR the nwo named in CR_TRIGGER_REPOS) rather than
    # re-deriving it. With step 0 the cwd may be an ADOPTER's repo or a
    # throwaway upstream clone; spending a scarce CodeRabbit call there - or
    # summoning a reviewer bot on someone else's PR - is exactly what 2034
    # closed. Unarmed is NOT a failure: advisory + continue, the panel and
    # the codex pass carry the gate.
    echo "coderabbit pass skipped: coderabbit=unarmed for $(git remote get-url origin 2>/dev/null || echo '<no origin>') - the critic panel carries the gate (HIMMEL-2034/2035)" >&2
    coderabbit_avail=""
else
    cr_tmp=$(mktemp -t coderabbit-avail.XXXXXX)
    # HIMMEL-1175/HIMMEL-1984 - pin the review to STEP 1's captured $branch +
    # $head and STEP 3.0's captured base SHA (this script's --branch/--head/
    # --base-sha flags). $db_sha is the literal caller passed via --base-sha.
    # (The scratch-file lookup above is scoped to that SAME captured $branch,
    # so the conservation reader and its phase-A writer cannot diverge.)
    # Without the pin the wrapper reviewed
    # whatever refs/heads/<current branch> pointed at when it ran, while step
    # 4.5 stamped the row with the captured $head. rc=5 = REFUSED before
    # anything was reviewed - the checkout moved, or the refusal channel /
    # stdout relay could not be created; the handler below relays which.
    coderabbit_findings=$(bash "$HIMMEL_ROOT"/scripts/cr/coderabbit-review.sh --base "$db" --base-sha "$db_sha" --branch "$branch" --head "$head" 2>"$cr_tmp") || coderabbit_rc=$?
    coderabbit_avail=$(grep '^panel-availability:' "$cr_tmp" || true)
    case "$coderabbit_rc" in
        0) ;;  # review completed - findings (possibly none) captured
        5)
            # REFUSED before anything was reviewed - same ABORT contract as
            # panel exit 7: every later step would certify a review that never
            # happened. Two causes share rc=5 (see this file's header): the
            # captured branch/SHA/base no longer describe this checkout, or a
            # setup failure that would have made that refusal - or the review's
            # own output - silently degrade. Relay the review's stderr BEFORE
            # the summary: it is the only place the specific cause appears, and
            # this branch used to discard it, leaving an operator to re-run for
            # a moved checkout when nothing had moved (HIMMEL-2321 CR).
            cat "$cr_tmp" >&2 || true
            cat >&2 <<'CRPINABORT'
/pr-check ABORT - coderabbit-review.sh exit 5: it refused before reviewing
anything, so the review inputs no longer match the branch/SHA/base the ledger
would stamp, or could not be proven to (HIMMEL-1175, HIMMEL-1984, HIMMEL-2321).
The REFUSING line above names which. Nothing was reviewed. Re-run /pr-check
from step 1.
CRPINABORT
            rm -f "$cr_tmp"
            exit 5
            ;;
        3)
            # CLI absent. For an App-less repo this CLI pass is the ONLY
            # pre-CI CodeRabbit signal (HIMMEL-1164) - reuse cr-available.sh's
            # cr_app_configured (HIMMEL-1125) rather than inventing another
            # probe, so the message escalates only when it's actually true
            # that nothing will review this PR. Guard the source (codex-1,
            # CR round 3): a missing helper must degrade to the generic skip
            # message, never break the handler itself (fail-open).
            if [ ! -f "$HIMMEL_ROOT"/scripts/lib/cr-available.sh ]; then
                echo "coderabbit pass skipped (CLI not configured)" >&2
            else
                # shellcheck source=scripts/lib/cr-available.sh
                # shellcheck disable=SC1091
                . "$HIMMEL_ROOT"/scripts/lib/cr-available.sh
                # shellcheck disable=SC2119  # no-arg call means "this checkout" (the function defaults $1 to $PWD)
                if cr_app_configured; then
                    echo "coderabbit pass skipped (CLI not configured) - the CodeRabbit App is armed for this repo, so CI still reviews this PR" >&2
                else
                    echo "coderabbit pass skipped (CLI not configured) AND the CodeRabbit App is not armed here - this PR will ship with NO CodeRabbit signal. Install the CLI for the sanctioned pre-CI path (docs/internals/enforcement.md#coderabbit-pre-ci-path--app-present-vs-app-absent-himmel-1164), or arm the App with \`git config --local himmel.coderabbit true\` if one is installed." >&2
                fi
            fi
            ;;
        4) echo "coderabbit pass RATE-LIMITED/quota-exhausted (rc=4) - retry later; recording unavailable (a rate-limited reviewer is a MISSING signal, NOT clean)" >&2 ;;
        *) echo "coderabbit pass failed (rc=$coderabbit_rc) - continuing without it" >&2; coderabbit_findings="" ;;
    esac
    rm -f "$cr_tmp"
fi
# Deliberate addition vs the fence (not in the original prose): the fence only
# captured this line into $coderabbit_avail for step 4.5 to read out of
# session state. A script has no shell variable to hand back, so print it to
# stderr here - including the synthesised "(conserved)" line - whenever the
# fence would have set one non-empty.
[ -n "$coderabbit_avail" ] && printf '%s\n' "$coderabbit_avail" >&2
[ -n "$coderabbit_findings" ] && printf '%s\n' "$coderabbit_findings"
# Explicit exit 0 (deliberate addition vs the fence): unlike a runbook fence,
# THIS script's own exit code is a signal callers branch on. Without this, the
# `[ -n ... ] && printf ...` line above would leak ITS OWN test result (1 when
# there were no findings to print - the common CONSERVED/skipped/none case) as
# the script's exit code, silently reporting failure on a clean run.
exit 0
