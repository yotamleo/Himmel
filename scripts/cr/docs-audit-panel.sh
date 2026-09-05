#!/usr/bin/env bash
# scripts/cr/docs-audit-panel.sh - the /pr-check docs-audit lane's cross-model
# critic path (HIMMEL-2226), extracted verbatim out of the step-2.5 fence in
# .claude/commands/pr-check.md.
#
# WHY THIS IS A SCRIPT AND NOT AN INLINE FENCE: the interactive /pr-check
# runbook is prose with ```bash fences that the orchestrating Claude session
# runs verbatim through the Bash tool. Claude Code's worktree-isolation guard
# (check-worktree-isolation.sh) statically screens every bash command run in a
# worktree-isolated session and refuses several shapes the old inline fence
# depended on: any "${CLAUDE_PROJECT_DIR:?}" reference (CLAUDE_PROJECT_DIR is
# genuinely UNSET in Bash-tool shells), any unresolvable env var, a runtime
# value passed as a dash-flag operand, and ${var} braced expansion. Shipping
# the fence as a real script file removes the parse surface entirely: only the
# runbook's own command LINE is screened, never a script's contents.
#
# BEHAVIOUR: byte-equivalent to the fence it replaces (same message text on
# the same streams, same exit codes) with two unavoidable differences, both
# required because a script cannot inherit shell state the way an inline
# fence in the same session can:
#   1. The fence consumed step-1's captured $head/$branch (HIMMEL-1175: this
#      lane must review the SHA the ledger will certify, never live HEAD).
#      A script cannot inherit those, so they arrive as REQUIRED --head/
#      --branch flags instead of being re-derived (re-deriving them would be
#      exactly the drift HIMMEL-1175 closed).
#   2. The fence left docs_audit_panel_avail_lines / docs_audit_panel_findings
#      as session-local shell variables for later runbook steps to read. A
#      script cannot leak variables into its caller's shell, so findings go to
#      stdout and the critic-panel.sh panel-availability lines go to stderr -
#      the exact split the fence already produced on those two streams, just
#      captured by the caller (redirection/capture) instead of by variable.
#
# Usage: docs-audit-panel.sh --head <sha> --branch <name>
#
# Arguments (both REQUIRED; missing either is a usage error, exit 2):
#   --head <sha>      the SHA step 1 of /pr-check captured (HIMMEL-1175/1984).
#   --branch <name>   the branch name step 1 captured.
#
# Env (same as the fence):
#   CR_REQUIRE_CROSS_MODEL - truthy (1/true/on/yes) required to run this lane
#                            at all; loaded from .env if not already live.
#   CR_PROFILE              - "none" disables the panel even when
#                              CR_REQUIRE_CROSS_MODEL is set (same precedence
#                              as step 3.0 - an explicit claude-only opt-out
#                              wins).
#
# stdout/stderr contract (do not merge these streams):
#   stdout - ONLY the panel's findings text (docs_audit_panel_findings in the
#            old fence), when non-empty. Nothing else is ever written to
#            stdout.
#   stderr - every advisory/diagnostic line the fence printed (claude-only
#            note, empty-diff skip, git-diff-failed note, all-critics-failed
#            note), the ABORT heredocs on exit 7, and critic-panel.sh's own
#            "panel-availability: ..." lines (captured from the panel's
#            stderr and re-emitted here so step 4.5 can still record them).
#
# Exit codes:
#   0 - lane completed (including the CR_PROFILE=none / empty-diff / disabled
#       / fail-open-degrade cases - none of those are aborts).
#   2 - usage error: --head or --branch missing.
#   7 - ABORT, never a degrade. Two causes: HIMMEL-2542 - the --head given
#       here names no commit in this repo (checked before any git command
#       consumes it); or critic-panel.sh's --head/--branch/--base-sha pin
#       mismatch (HIMMEL-1175, HIMMEL-1984), on the first attempt OR the rtk
#       retry.
#
# bash 3.2-safe (Git Bash on Windows and Linux).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HIMMEL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

usage() {
    cat <<'EOF'
Usage: docs-audit-panel.sh --head <sha> --branch <name>

Runs the /pr-check docs-audit lane's cross-model critic path
(CR_REQUIRE_CROSS_MODEL) over the given head SHA and branch name. --head and
--branch are the values step 1 of /pr-check captured; this script never
re-derives them.
EOF
}

HEAD_ARG=""
BRANCH_ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --head)   [ $# -ge 2 ] || { echo "docs-audit-panel: --head needs an argument" >&2; exit 2; }; HEAD_ARG="$2"; shift 2 ;;
        --branch) [ $# -ge 2 ] || { echo "docs-audit-panel: --branch needs an argument" >&2; exit 2; }; BRANCH_ARG="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "docs-audit-panel: unknown arg: $1" >&2; usage >&2; exit 2 ;;
    esac
done
[ -n "$HEAD_ARG" ] || { echo "docs-audit-panel: --head is required" >&2; usage >&2; exit 2; }
[ -n "$BRANCH_ARG" ] || { echo "docs-audit-panel: --branch is required" >&2; usage >&2; exit 2; }
head="$HEAD_ARG"
branch="$BRANCH_ARG"

# Same truthiness as clear-cr-marker.sh gate 3b. Process env wins; .env is
# loaded from the primary checkout by load-dotenv.sh, same convention as the
# full lane's CR_PROFILE bridge.
# shellcheck source=../lib/load-dotenv.sh
# shellcheck disable=SC1091
. "$HIMMEL_ROOT/scripts/lib/load-dotenv.sh"
load_dotenv --root "$(_load_dotenv_primary_for "$HIMMEL_ROOT")" CR_REQUIRE_CROSS_MODEL CR_PROFILE || true
export CR_REQUIRE_CROSS_MODEL CR_PROFILE
case "$(printf '%s' "${CR_REQUIRE_CROSS_MODEL:-}" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')" in
    1|true|on|yes) docs_audit_require_cross_model=1 ;;
    *) docs_audit_require_cross_model=0 ;;
esac

# $head and $branch are the values STEP 1 captured - this fence runs
# independently (see step 3.0's identical note): substitute those literals
# here, never re-derive them in this fence.
# HIMMEL-2542 - validate the INPUT PIN first. `git rev-parse` WITHOUT
# --verify happily echoes a well-formed 40-hex string back that names no
# object, so the bare call below cannot tell a real pin from a hand-expanded
# short hash; the bad value then reaches `git diff`, which fails rc=128, and
# the lane reports "cross-model critic unavailable" - a caller error wearing
# a reviewer outage's clothes, at exit 0. Same class as the panel's own pin
# mismatch, so the same exit: 7, ABORT.
if ! git rev-parse --verify --quiet "$head^{commit}" >/dev/null 2>&1; then
    echo "docs-audit-panel ABORT - --head $head does not resolve to a commit in this repo (HIMMEL-2542). This is an input-pin failure, NOT a critic outage: nothing was reviewed and nothing was recorded. Re-check the SHA step 0 printed and re-run /pr-check from step 1." >&2
    exit 7
fi
docs_audit_head=$(git rev-parse "$head")
docs_audit_panel_avail_lines=""
docs_audit_panel_findings=""
if [ "$docs_audit_require_cross_model" = "1" ]; then
    if [ "${CR_PROFILE:-}" = "none" ]; then
        # Same precedence as step 3.0: an explicit claude-only opt-out wins
        # even under CR_REQUIRE_CROSS_MODEL. The marker stays closed under
        # the cross-model floor until CR_PROFILE is unset (the two settings
        # are genuinely contradictory; we do not spend the paid critic to
        # satisfy one at the expense of the other).
        echo "docs-audit: claude-only (CR_PROFILE=none) - cross-model critic not launched; marker stays closed under CR_REQUIRE_CROSS_MODEL until a non-Claude responder exists or CR_PROFILE is unset" >&2
    else
        # shellcheck disable=SC1091
        db=$(. "$HIMMEL_ROOT/scripts/guardrails/lib.sh" 2>/dev/null && default_branch || echo main)
        db_sha=$(git rev-parse "$db")
        diff_rc=0
        diff_out=$(git diff "$db_sha...$docs_audit_head") || diff_rc=$?
        if [ "$diff_rc" -ne 0 ]; then
            echo "docs-audit cross-model critic unavailable - git diff failed rc=$diff_rc: $diff_out" >&2
        elif [ -z "$diff_out" ]; then
            echo "docs-audit cross-model critic skipped: empty diff (marker will stay closed under CR_REQUIRE_CROSS_MODEL unless another non-Claude avail-ok row exists)" >&2
        else
            panel_tmp=$(mktemp -t cr-docs-audit-panel-avail.XXXXXX)
            docs_audit_panel_findings=$(printf '%s' "$diff_out" | CR_USAGE_LOG=1 bash "$HIMMEL_ROOT/scripts/cr/critic-panel.sh" --head "$docs_audit_head" --branch "$branch" --base "$db" --base-sha "$db_sha" 2>"$panel_tmp")
            panel_rc=$?
            docs_audit_panel_avail_lines=$(cat "$panel_tmp"); rm -f "$panel_tmp"
            if [ "$panel_rc" -eq 7 ]; then
                cat >&2 <<'PINABORT'
/pr-check ABORT - docs-audit critic-panel.sh exit 7: the checkout or the diff
base moved since step 1, so the review inputs no longer match the branch/SHA/base
the ledger would stamp (HIMMEL-1175, HIMMEL-1984). Nothing was reviewed and
nothing was recorded. Re-run /pr-check from step 1.
PINABORT
                exit 7
            fi
            if [ "$panel_rc" -ne 0 ] && command -v rtk >/dev/null 2>&1; then
                retry_diff=$(rtk proxy git diff "$db_sha...$docs_audit_head" 2>/dev/null) || retry_diff=""
                if [ -n "$retry_diff" ]; then
                    retry_tmp=$(mktemp -t cr-docs-audit-panel-avail.XXXXXX)
                    docs_audit_panel_findings=$(printf '%s' "$retry_diff" | CR_USAGE_LOG=1 bash "$HIMMEL_ROOT/scripts/cr/critic-panel.sh" --head "$docs_audit_head" --branch "$branch" --base "$db" --base-sha "$db_sha" 2>"$retry_tmp")
                    panel_rc=$?
                    docs_audit_panel_avail_lines=$(cat "$retry_tmp"); rm -f "$retry_tmp"
                    if [ "$panel_rc" -eq 7 ]; then
                        cat >&2 <<'PINABORTRETRY'
/pr-check ABORT - docs-audit critic-panel.sh exit 7 on the rtk retry: the
checkout or diff base moved mid-run, so the review inputs no longer match the
branch/SHA/base the ledger would stamp. Nothing was reviewed. Re-run /pr-check
from step 1.
PINABORTRETRY
                        exit 7
                    fi
                fi
            fi
            if [ "$panel_rc" -ne 0 ]; then
                echo "docs-audit cross-model critic unavailable (all critics failed) - record any panel-availability unavailable rows; under CR_REQUIRE_CROSS_MODEL the marker will stay closed until a non-Claude critic records avail ok" >&2
                docs_audit_panel_findings=""
            fi
        fi
        # critic-panel.sh's own "panel-availability: ..." lines were captured
        # off its stderr above (docs_audit_panel_avail_lines); re-emit them to
        # OUR stderr now so a caller capturing this script's stderr (step 4.5
        # in the old fence, a test fixture here) still sees them - the fence
        # left them in a variable for the same session to read later; a
        # script has no variable to leave them in, so stderr is the channel.
        [ -n "$docs_audit_panel_avail_lines" ] && printf '%s\n' "$docs_audit_panel_avail_lines" >&2
        [ -n "$docs_audit_panel_findings" ] && printf '%s\n' "$docs_audit_panel_findings"
    fi
fi

# The fence above ends with `[ -n "$docs_audit_panel_findings" ] && printf ...`,
# whose own exit status (1 when there are no findings) would otherwise become
# THIS script's exit status. The inline fence never cared because later
# runbook steps ran after it regardless; a standalone script must not report
# an empty-findings SUCCESS path as a failure, so pin the exit code
# explicitly for every non-abort path.
exit 0
