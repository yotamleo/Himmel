#!/usr/bin/env bash
# check-ci.sh — token-free PR merge-gate watcher (HIMMEL-949).
#
# Friction this prevents: merge-on-green sessions burn tokens re-running
# `gh pr checks` in an agent poll loop. This wraps the whole wait in ONE
# process — all polling happens inside `gh pr checks --watch --fail-fast` —
# so a session launches it once (background Bash) and reads a single exit
# code when it finishes. Exit 0 means BOTH gates passed: every check green
# AND zero unresolved PR review threads (a CR comment left unresolved is a
# merge blocker, same as a red check).
#
# Usage: check-ci.sh [<pr-number|branch|url>] [--grace <sec>] [--settle <sec>] [--threads-only]
#   selector        optional; defaults to the PR for the current branch
#   --threads-only  skip the checks watch entirely and run just the
#                   review-thread gate (used by /pr-check step 4.8 so both
#                   enforcement points share ONE implementation)
#   --grace <sec>   how long to wait for checks to REGISTER before giving up
#                   (default 180). Right after `git push` / `gh pr create`,
#                   `gh pr checks` errors with "no checks reported" until the
#                   CI provider picks up the commit — that window is not a
#                   failure, so we retry through it.
#   --settle <sec>  after the first green verdict, wait this long and watch
#                   once more (default 30; 0 disables). Guards the codex-adv-1
#                   race: check runs register at different times, so the first
#                   watch can go green before a slower workflow has created
#                   its check run at all. One settle round bounds that window;
#                   a workflow that registers even later is out of scope.
#   --max-wait <sec> bound on each `gh pr checks --watch` round (default 900,
#                   HIMMEL-2907 — the measured slowest shell-unit shard runs
#                   12m16s-12m45s; 0 = unbounded, today's behaviour). HIMMEL-2062: CodeRabbit
#                   leaves its rollup row "pending"/"Review queued" long after
#                   every other check — and, when armed, its own gate status —
#                   is decidable, so the watch keeps polling well past a 10-
#                   minute foreground tool timeout even though the verdict is
#                   already known. The watch is supervised in the background
#                   and stopped early the moment the verdict is decidable
#                   (see watch_decidable), or at this cap, whichever comes
#                   first; either way the verdict is then derived structurally
#                   instead of waited out.
#
# The green verdict is bound to the PR head SHA: headRefOid is captured before
# the first watch and re-read before exit 0 — a concurrent push (another live
# session, automation) during the run means the certified commit is not the
# mergeable one, so the script fails closed with exit 2 (re-run).
#
# HIMMEL-3360: CodeRabbit is best effort. Its commit STATUS (cr_signal_gate)
# is read and printed, but pending/failure/error/absent/skipped/unrecognized
# states are advisory ONLY — never a block, never a wait. A green verdict
# still REQUIRES zero unresolved PR review threads (any author, CodeRabbit
# included — review_state_gate, generic, NOT availability-gated) and zero
# undispositioned outside-diff-range CodeRabbit body findings (HIMMEL-1126/
# 1147, S1 + HIMMEL-3124 — see cr_body_gate / _cr_outside_gate, in
# scripts/lib/cr-body-findings.sh). Runs on BOTH the full path and
# --threads-only (the latter binds its own head to do so).
#
# CodeRabbit's status is read only when AVAILABILITY-GATED armed (HIMMEL-1125):
# it arms only on a repo that declares CodeRabbit (scripts/lib/cr-available.sh).
# On a repo without it, cr_signal_gate is a silent no-op — an adopter without
# CodeRabbit must not notice a CodeRabbit gate exists.
#
# Exit codes:
#   0 — all checks green AND all review threads resolved AND no outside-diff-
#       range body finding left undispositioned (an exact-head ledger
#       deferred/disproved disposition counts, HIMMEL-3124 — see exit 3).
#       CodeRabbit's own status, when armed, is printed as an advisory NOTE on
#       any state other than success — it never changes this exit code
#       (HIMMEL-3360).
#   1 — at least one check failed (--fail-fast: returns on the first red)
#   64 — usage error (sysexits EX_USAGE, HIMMEL-3317): an unknown flag, a flag
#       missing its value, a non-numeric --grace/--settle/--max-wait, or more
#       than one PR selector. NO gate ran, so it is deliberately not 2 — a caller
#       reading only `$?` cannot mistake a mistyped command line (e.g.
#       `--pr 1003`; the PR number is POSITIONAL) for a verdict. --help is not a
#       usage error: it exits 0.
#   2 — cannot evaluate: no PR found / no checks registered
#       within --grace / gh error on the probe or the watch / thread-state
#       query failed or returned a malformed page / PR head moved during the run
#       / the review-body-findings reader could not evaluate (infra failure
#       or an anti-drift canary — both fail closed here, see cr-body-findings.sh)
#       (CodeRabbit's own commit status never lands here: unreadable, paged,
#       absent and every other non-success state are advisory, HIMMEL-3360)
#   3 — checks green but the review state blocks the merge: unresolved review
#       threads remain, a review requests changes, or CodeRabbit's review body
#       reports an outside-diff-range finding with no exact-head ledger
#       disposition (HIMMEL-3124) — address, resolve, or record the disposition
#       recipe the message prints (deferred needs a tracked ticket AND a reason,
#       disproved needs a reason; a disposition never carries to a new head),
#       then re-run
#   4 — retired (HIMMEL-3360) — no longer emitted.
#   5 — GitHub will BLOCK this merge and waiting cannot fix it (HIMMEL-3381): a
#       check the base branch REQUIRES (rulesets via rules/branches, unioned
#       with classic protection contexts) never reported within --grace, or the
#       required set itself could not be read ("required-set unreadable" — read
#       failure fails CLOSED, never as an empty set). A required entry carrying a
#       producer id (ruleset integration_id / classic app_id, HIMMEL-3385) is met
#       only by a check run from THAT app — a same-named check from another app
#       reads as never reported — and an unreadable check-runs read ("producers
#       unreadable") fails closed too; an entry with no id stays a name match. A
#       pinned check the app publishes as a commit STATUS reads as never
#       reported too (a status carries no app id to verify, HIMMEL-3391); the
#       refusal names that "status-only producer" cause. A
#       required check that is FAILED exits 1, as any red does. Each of these prints one MERGE-BLOCKED
#       line naming the rule and sends ONE operator DM per (repo, PR, head)
#       (scripts/lib/merge-block-alert.sh); a delivery failure never changes the
#       exit code. Sits ABOVE 3 in severity: 3 is "fix the review state and
#       re-run", 5 is "a rule GitHub enforces will refuse this until it changes".
#
# Env:
#   CHECK_CI_POLL_INTERVAL — seconds between grace-window probes (default 10;
#                            tests set 0; non-numeric falls back to default)
#   CHECK_CI_SETTLE        — default for --settle (flag wins)
#   CHECK_CI_SLEEP_CMD     — the command every wall-clock wait in this script
#                            goes through (default `sleep`); hermetic suites set
#                            it to `:` so a simulated poll costs no real seconds
#   CHECK_CI_MAX_WAIT      — default for --max-wait (flag wins; default 900, 0 =
#                            unbounded; HIMMEL-2062, raised in HIMMEL-2907)
#   CHECK_CI_WATCH_INTERVAL — seconds between `gh pr checks --watch` polls
#                            (default 30; gh's own default is 10). HIMMEL-3190.
#   CHECK_CI_PROBE_INTERVAL — seconds between watch_decidable probes (default 60;
#                            the first probe is immediate). Each probe is 4
#                            GraphQL calls; at 10 s it was ~80% of a watcher's
#                            ~30 calls/min. Tests export 1.
#   GH_BUDGET_FLOOR / GH_BUDGET_JITTER_MAX / GH_BUDGET_PREFLIGHT — the shared
#                            GraphQL-budget preflight, see lib/gh-graphql-budget.sh
#   CR_PROFILE=none        — this repo has no CodeRabbit: skip the CodeRabbit
#                            status read entirely. Still honored, but no
#                            longer something an adopter must discover — see
#                            the availability gate below.
#   CR_APP=1|0             — force the CodeRabbit status read on/off, overriding
#                            the probe (see scripts/lib/cr-available.sh)
#   CR_BOT_USER_ID         — creator.id to trust as CodeRabbit (see cr-signal.sh
#                            and cr-body-findings.sh; REST identity)
#
# The HIMMEL-980 zombie-check-run override is GONE: it keyed off a CodeRabbit
# CHECK-RUN, which CodeRabbit never posts (it posts a commit STATUS), so it had
# never once fired. Reading the status directly makes it moot.
#
# Un-maskable verdict (HIMMEL-974): every exit path additionally prints
# "check-ci: verdict exit=N" to STDOUT via an EXIT trap installed before arg
# parsing, so usage errors (exit 64) carry it too (HIMMEL-3317); only --help,
# which is not a gate result, stays clean. A caller that pipes the run
# (`check-ci.sh | tail`) gets the PIPE's exit code, not this script's — the
# verdict line keeps the real status readable in any captured output.
set -uo pipefail

usage() {
    cat >&2 <<'EOF'
usage: check-ci.sh [<pr-number|branch|url>] [--grace <sec>] [--settle <sec>] [--max-wait <sec>] [--threads-only]
exit codes: 0 = checks green + all review threads resolved
                + no outside-diff-range body finding left undispositioned (an exact-head ledger
                  deferred/disproved disposition counts, HIMMEL-3124 — see exit 3).
                CodeRabbit is best effort (HIMMEL-3360): if armed, its own status is read and printed
                  as an advisory NOTE on any state other than success — it never changes this exit code,
            1 = a check failed,
            64 = usage error — bad flag / missing or non-numeric value / two PR selectors; NO gate ran (the PR
                number is POSITIONAL: `check-ci.sh 1003`, not `--pr 1003`),
            2 = cannot evaluate (no PR / no checks within --grace / thread query failed / PR head moved
                / body-findings reader failed — CodeRabbit's own status never produces this code),
            3 = checks green but unresolved review threads remain, a review requests changes, or (if armed)
                CodeRabbit's review body reports an outside-diff-range finding with no exact-head ledger
                disposition (HIMMEL-3124; the message prints the deferred/disproved recipe, and a
                disposition never carries to a new head),
            4 = retired (HIMMEL-3360) — no longer emitted,
            5 = GitHub will block this merge (HIMMEL-3381): a required check never reported within --grace, or the
                required-check set could not be read (fails closed). One MERGE-BLOCKED line + one operator DM.
env: CR_PROFILE=none skips reading CodeRabbit's status + body findings entirely (repos without CodeRabbit)
     CR_APP=1|0 forces that same read on/off, overriding the automatic probe (see scripts/lib/cr-available.sh)
     CHECK_CI_SLEEP_CMD replaces the command every wall-clock wait runs (default sleep; hermetic suites set it to :)
     CHECK_CI_MAX_WAIT sets --max-wait's default (default 900 seconds, 0 = unbounded; HIMMEL-2062, raised in HIMMEL-2907)
     CHECK_CI_WATCH_INTERVAL / CHECK_CI_PROBE_INTERVAL set the watch poll (default 30 s) and the early-stop probe (default 60 s)
       cadence — the GitHub GraphQL budget is shared by every leg on the box (HIMMEL-3190)
     GraphQL budget exhausted: check-ci sleeps until X-Ratelimit-Reset (bounded by --max-wait) instead of failing; exit
       codes keep their meaning (a reset beyond --max-wait is exit 2). GH_BUDGET_PREFLIGHT=0 skips the one preflight call.
note: "armed" above means CodeRabbit's status + body findings are read at the head — DISARMED by default. On a
      repo that has the CodeRabbit App, arm it once:  git config --local himmel.coderabbit true
      CR_APP=1|0 overrides; CR_PROFILE=none outranks both. On a disarmed repo the CodeRabbit-conditional
      clauses above simply do not apply, and exit 0 requires no CodeRabbit status at all. The
      unresolved-review-thread requirement (exit 3) is NOT keyed on this and applies to everyone.
      A repo that never arms is SILENT about CodeRabbit — nothing was configured, so nothing is
      missing, and an adopter who does not use CodeRabbit is never told about it. The ONE exception
      (HIMMEL-2380) is a marker set to a value git cannot parse as a boolean: that repo meant to have
      the gates, silently lost them, and would otherwise certify greens asserting a review nobody
      checked for. It gets a loud WARNING naming the fix — and still exits 0, because a config typo
      must not wedge a merge.
      MACHINE-GENERATED PRs (HIMMEL-2278) tolerate an ABSENT App review, and only that: a dependabot-authored
      PR, or one whose every changed path is a tracked graphify-out artifact. The App never reviews that class,
      so silence is its expected state — but a FAILED or PENDING App status, any body finding the App does
      post, checks-green, CHANGES_REQUESTED and unresolved threads all still gate it, and no other PR class is
      affected.
EOF
}

THREADS_ONLY=0
GRACE=180
SETTLE="${CHECK_CI_SETTLE:-30}"
# Default 900s (HIMMEL-2907): the measured slowest shell-unit shard runs
# 12m16s-12m45s, over the prior 540s default.
MAX_WAIT="${CHECK_CI_MAX_WAIT:-900}"
POLL="${CHECK_CI_POLL_INTERVAL:-10}"
# HIMMEL-3190: the GraphQL budget (5000/h) is shared by every leg on the box and
# ~7 watchers each spending ~30 calls/min ran it dry twice in three hours. Both
# cadences are per-watcher GraphQL spend, so they are knobs — defaults chosen so
# a watcher costs ~6 calls/min: gh's own poll (3 setup + 1 status per poll) every
# 30 s = ~2/min, and the 4-call watch_decidable probe every 60 s = ~4/min.
WATCH_INTERVAL="${CHECK_CI_WATCH_INTERVAL:-30}"
PROBE_INTERVAL="${CHECK_CI_PROBE_INTERVAL:-60}"
case "$WATCH_INTERVAL" in
    ''|*[!0-9]*|0) echo "check-ci: CHECK_CI_WATCH_INTERVAL='$WATCH_INTERVAL' is not a positive integer — using 30" >&2
        WATCH_INTERVAL=30 ;;
esac
case "$PROBE_INTERVAL" in
    ''|*[!0-9]*|0) echo "check-ci: CHECK_CI_PROBE_INTERVAL='$PROBE_INTERVAL' is not a positive integer — using 60" >&2
        PROBE_INTERVAL=60 ;;
esac
# Sleep seam (HIMMEL-1953). EVERY wall-clock wait below goes through this one
# command word so a hermetic suite can inject `:` and never burn real seconds on
# a simulated poll — a test that sleeps is a test that can hang, and a hang is
# indistinguishable from a slow suite.
#
# A single command word by design — no argument splitting, so `sleep 0.5` here
# would not work and is not meant to. It widens no trust boundary: a caller who
# can set this can already set PATH, which decides what `sleep` itself resolves
# to.
CHECK_CI_SLEEP_CMD="${CHECK_CI_SLEEP_CMD:-sleep}"
case "$POLL" in
    ''|*[!0-9]*)
        echo "check-ci: CHECK_CI_POLL_INTERVAL='$POLL' is not a non-negative integer — using 10" >&2
        POLL=10 ;;
esac

# Un-maskable verdict line (HIMMEL-974) — installed BEFORE arg parsing
# (HIMMEL-3317) so a usage error (exit 64) prints its marker too: a caller that
# read only `$?` used to record a gate result for a gate that never ran. Prints
# on EVERY exit path but --help: a piped caller's pipeline exit code is the LAST
# command's, not this script's, so the numeric verdict must survive in the
# output text. --help clears the trap below — asking for help is not a gate result.
trap 'echo "check-ci: verdict exit=$?"' EXIT

selector=""
while [ $# -gt 0 ]; do
    case "$1" in
        --grace)
            if [ $# -lt 2 ]; then echo "check-ci: --grace needs a value" >&2; usage; exit 64; fi
            GRACE="$2"; shift 2 ;;
        --settle)
            if [ $# -lt 2 ]; then echo "check-ci: --settle needs a value" >&2; usage; exit 64; fi
            SETTLE="$2"; shift 2 ;;
        --max-wait)
            if [ $# -lt 2 ]; then echo "check-ci: --max-wait needs a value" >&2; usage; exit 64; fi
            MAX_WAIT="$2"; shift 2 ;;
        --threads-only)
            THREADS_ONLY=1; shift ;;
        -h|--help) trap - EXIT; usage; exit 0 ;;
        -*) echo "check-ci: unknown option: $1" >&2; usage; exit 64 ;;
        *)
            if [ -n "$selector" ]; then echo "check-ci: only one PR selector allowed (got '$selector' and '$1')" >&2; usage; exit 64; fi
            selector="$1"; shift ;;
    esac
done

case "$GRACE" in
    ''|*[!0-9]*) echo "check-ci: --grace must be a non-negative integer, got '$GRACE'" >&2; exit 64 ;;
esac
case "$SETTLE" in
    ''|*[!0-9]*) echo "check-ci: --settle must be a non-negative integer, got '$SETTLE'" >&2; exit 64 ;;
esac
case "$MAX_WAIT" in
    ''|*[!0-9]*) echo "check-ci: --max-wait must be a non-negative integer, got '$MAX_WAIT'" >&2; exit 64 ;;
esac

if ! command -v gh >/dev/null 2>&1; then
    echo "check-ci: gh CLI not found on PATH" >&2
    exit 2
fi

# GraphQL budget preflight (HIMMEL-3190). The shared helper reads the
# X-Ratelimit-* headers of ONE real call (`gh api rate_limit` misreports) and,
# when the budget is under its floor, sleeps until the reset instead of letting
# the first gh call fail generically. Called once here and again only after a
# rate-limit error (_rl_recover) — never per poll round: the preflight is a
# request too. Bounded by --max-wait; a reset further away than that is exit 2,
# the same "cannot evaluate" every other unreadable gate already reports.
# shellcheck source=scripts/lib/gh-graphql-budget.sh
# shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
. "$(cd "$(dirname "$0")" && pwd)/lib/gh-graphql-budget.sh"
RL_RECOVERIES=0
# _rl_recover — after a gh failure that reads as a rate limit: wait for the
# reset and tell the caller to retry (rc 0), at most 3 times per run. rc 1 =
# do not retry (recovery budget spent, the reset is beyond --max-wait, or the
# preflight saw a healthy budget so waiting would not help): the caller keeps
# its original fail-closed exit.
_rl_recover() {
    [ "$RL_RECOVERIES" -ge 3 ] && return 1
    ghb_wait_for_budget "$MAX_WAIT" "$CHECK_CI_SLEEP_CMD" || return 1
    [ "$GHB_WAITED" -eq 1 ] || return 1
    RL_RECOVERIES=$((RL_RECOVERIES + 1))
    return 0
}
if ! ghb_wait_for_budget "$MAX_WAIT" "$CHECK_CI_SLEEP_CMD"; then
    echo "check-ci: GitHub GraphQL budget exhausted and the reset is beyond --max-wait (${MAX_WAIT}s) — cannot evaluate the gate; re-run after the reset" >&2
    exit 2
fi
# jq is needed to read CodeRabbit's status + review-body findings, so require
# it only when the CodeRabbit signal gate is ARMED (coderabbit-7, extended by
# HIMMEL-1126/HIMMEL-1125): --threads-only USED to be a pure GraphQL+gh path,
# but it now also runs cr_signal_gate + cr_body_gate (S1 — a body-only finding
# is exactly as invisible to /pr-check step 4.8's threads-only call as it is
# to the full run), so it needs jq too whenever CodeRabbit is in play.
# Is the CodeRabbit App configured for this repo at all (HIMMEL-1125)? The
# signal + body gates below are armed ONLY when it is: on a repo without
# CodeRabbit, "absent" is the permanent steady state — but HIMMEL-3360 made
# "absent" advisory rather than blocking, so this now only controls whether
# the gates run at all, not a fail-closed exit. Probed once here;
# cr_signal_gate/cr_body_gate read the result.
# shellcheck source=scripts/lib/cr-available.sh
# shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
. "$(cd "$(dirname "$0")" && pwd)/lib/cr-available.sh"
CR_ARMED=0
# ONE probe, read twice (HIMMEL-2380): the rc arms the gates below exactly as it
# always did, and CR_STATE names WHY — which is the difference between an
# adopter who never had CodeRabbit and a repo that just lost its gate to a typo.
CR_STATE=$(cr_app_state "$PWD")
[ "$CR_STATE" = armed ] && CR_ARMED=1

# The ONE merge-block alert (HIMMEL-3381): a MERGE-BLOCKED line + one operator DM.
# shellcheck source=scripts/lib/merge-block-alert.sh
# shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
. "$(cd "$(dirname "$0")" && pwd)/lib/merge-block-alert.sh"

# The one state that must NOT stay silent (HIMMEL-2380, console ruling 88).
# `not-configured` is the adopter and gets no line at all — "an adopter must not
# notice it exists" (scripts/test-check-ci.sh case 57 pins that, and it still
# passes). `broken` is different in kind: the marker IS set, so this repo was
# meant to have the CodeRabbit gates, and a value git cannot parse as a boolean
# silently disarms them. Every green below would then assert a review nobody
# ever checked for — the one genuinely vacuous pass in this design. Warn, do not
# block: HIMMEL-1125 exists to stop blocking on CodeRabbit's absence, and a
# config typo must not wedge a merge at 3am.
if [ "$CR_STATE" = broken ]; then
    echo "check-ci: WARNING - this repo's himmel.coderabbit marker holds a value git cannot parse as a boolean, so the CodeRabbit gates are DISARMED and any green below certifies a CodeRabbit review that was never checked for. If this repo HAS CodeRabbit: git config --local himmel.coderabbit true. If it does not: git config --local --unset himmel.coderabbit (HIMMEL-2380)." >&2
fi

# HIMMEL-2769: `not-configured` is silently correct for the adopter with no
# CodeRabbit at all (case 17's whole point) — but a repo that carries a
# COMMITTED `.coderabbit.yaml`/`.yml` has declared it wants CodeRabbit, so an
# unarmed marker here is not the adopter's steady state, it is a clone nobody
# ever ran `git config --local himmel.coderabbit true` on. Every green below
# would then certify a review that was never armed to run. Fail loud instead
# of silently certifying it, same as the vacuous-green class this ticket
# names (HIMMEL-1317/2062). CR_APP=0 is the sole bypass, and it already is
# one: CR_APP=0 makes cr_app_state report `disabled`, never `not-configured`,
# so this block cannot fire while it is set.
if [ "$CR_STATE" = not-configured ]; then
    cr_repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || cr_repo_root="$PWD"
    # codex-1 (round 1): read the COMMITTED tree at HEAD, not the working
    # tree — an untracked local .coderabbit.yaml must not arm this gate, and
    # a tracked one a caller merely deleted locally must not disarm it.
    if git -C "$cr_repo_root" cat-file -e HEAD:.coderabbit.yaml 2>/dev/null || git -C "$cr_repo_root" cat-file -e HEAD:.coderabbit.yml 2>/dev/null; then
        echo "check-ci: CR-UNARMED - this repo carries .coderabbit.yaml/.yml (it expects CodeRabbit) but no clone has ever armed the gate, so no green here can certify a CodeRabbit review. Arm it: git config --local himmel.coderabbit true. If this repo genuinely has no CodeRabbit App, bypass for this run with CR_APP=0." >&2
        exit 2
    fi
fi

if [ "$CR_ARMED" -eq 1 ]; then
    if ! command -v jq >/dev/null 2>&1; then
        echo "check-ci: jq not found on PATH (required to read CodeRabbit's status)" >&2
        exit 2
    fi
    # The ONE reader for CodeRabbit's verdict (HIMMEL-1072).
    # shellcheck source=scripts/lib/cr-signal.sh
    # shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
    . "$(cd "$(dirname "$0")" && pwd)/lib/cr-signal.sh"
    # The ONE reader for CodeRabbit's review-BODY findings (HIMMEL-1126/1147) —
    # outside-diff-range / nitpick / additional comments the thread gate below
    # cannot see (S1: no thread, no isResolved, unresolvable by construction).
    # shellcheck source=scripts/lib/cr-body-findings.sh
    # shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
    . "$(cd "$(dirname "$0")" && pwd)/lib/cr-body-findings.sh"
    # The CR-ledger evidence reader (HIMMEL-3124): tells _cr_outside_gate below
    # whether an outside-diff-range finding has a recorded exact-head
    # disposition (deferred/disproved). HIMMEL-3360 removed this lib's OTHER
    # function, cr_ledger_carries_gate (the rate-limited/absent-signal panel
    # carry) — that reader is now unused, but the lib stays sourced for
    # cr_ledger_outside_dispositioned.
    # shellcheck source=scripts/lib/cr-ledger-evidence.sh
    # shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
    . "$(cd "$(dirname "$0")" && pwd)/lib/cr-ledger-evidence.sh"
fi

pr_checks() {
    if [ -n "$selector" ]; then gh pr checks "$selector" "$@"; else gh pr checks "$@"; fi
}

pr_view() {
    if [ -n "$selector" ]; then gh pr view "$selector" "$@"; else gh pr view "$@"; fi
}

# HIMMEL-3381 — the required-check gate. GitHub refuses a merge while a check the
# base branch REQUIRES is failed or has never reported; watching cannot fix
# either, so neither is waited on past --grace. `gh pr checks --watch` knows
# nothing about the required set, which is why a required check that never
# registers used to read as green (or wait out --max-wait twice).
_alert() { merge_block_alert "${owner:-?}/${repo:-?}" "${num:-?}" "${head0:-}" "$@"; }

# required_set — one required check context per line. The EFFECTIVE set is the
# union of rulesets (rules/branches/<base>, which covers protect-main's ruleset
# checks) and classic branch protection. A failed read returns 1: the caller
# fails CLOSED — an unreadable set must never be mistaken for an empty one. Only
# a 404 on the classic endpoint ("Branch not protected" / "Required status
# checks not enabled") means "no classic rule".
#
# ponytail: a token without admin cannot read the classic endpoint (403), so it
# reads as unreadable and refuses every merge (exit 5) rather than guessing —
# there is no opt-out knob; the fail-closed choice is deliberate (HIMMEL-3381).
required_set() {
    local base rules classic
    base=$(pr_view --json baseRefName --jq .baseRefName 2>/dev/null) || return 1
    [ -n "$base" ] || return 1
    rules=$(gh api "repos/$owner/$repo/rules/branches/$base" \
        --jq '.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[]? | "\(.context)\t\(.integration_id // "")"' 2>&1) || return 1
    if ! classic=$(gh api "repos/$owner/$repo/branches/$base/protection/required_status_checks" \
        --jq '((.contexts // [])[] | "\(.)\t"), ((.checks // [])[]? | "\(.context)\t\(.app_id // "")")' 2>&1); then
        case "$classic" in *"(HTTP 404)"*) classic="" ;; *) return 1 ;; esac
    fi
    printf '%s\n%s\n' "$rules" "$classic" | sed '/^$/d' | sort -u | _required_normalize
}

# _required_normalize — "<name>\t<producer id>" in, the same out. An id of -1 is
# classic protection's "any source" (HIMMEL-3385), so it is no id. When a name
# carries an id anywhere, its id-less rows drop: a producer-pinned requirement is
# stricter, and the deprecated classic `contexts` list repeats every name id-less,
# which must not weaken the pinned one back to a name-only match.
_required_normalize() {
    awk -F'\t' '
        { n[NR] = $1; i[NR] = ($2 == "-1" ? "" : $2); if (i[NR] != "") pinned[$1] = 1 }
        END { for (j = 1; j <= NR; j++) if (i[j] != "" || !(n[j] in pinned)) print n[j] "\t" i[j] }' | sort -u
}

# _required_rows — "<bucket>\t<name>" for every check on the PR.
_required_rows() {
    pr_checks --json bucket,name --jq '.[] | "\(.bucket)\t\(.name)"' 2>/dev/null
}

# _has_producer_ids <reqs> — true when any required entry names a producer.
_has_producer_ids() {
    printf '%s\n' "$1" | awk -F'\t' '$2 != "" { f = 1 } END { exit !f }'
}

# _producer_rows — "<bucket>\t<name>\t<app id>" for every check run on the head.
# `gh pr checks --json` exposes no app id, so a producer-pinned requirement is
# read from the check-runs API instead (HIMMEL-3385). --paginate: a busy head has
# more than one page of runs, and an unread page would read as "missing".
_producer_rows() {
    gh api "repos/$owner/$repo/commits/$head0/check-runs?per_page=100" --paginate \
        --jq '.check_runs[] | "\(if .status != "completed" then "pending" elif (.conclusion == "success" or .conclusion == "neutral" or .conclusion == "skipped") then "pass" elif .conclusion == "cancelled" then "cancel" else "fail" end)\t\(.name)\t\(.app.id // "")"' 2>/dev/null
}

# _required_status <reqs> <rows> <producer rows> — "<fail|seen|missing>\t<label>"
# per required check. A cancelled required check blocks a merge exactly as a
# failed one does. An entry with no id matches by name over <rows>; one with an id
# matches name AND app id over <producer rows>.
_required_status() {
    local name id
    while IFS=$'\t' read -r name id; do
        [ -n "$name" ] || continue
        if [ -z "$id" ]; then
            printf '%s\t%s\n' "$(printf '%s\n' "$2" | awk -F'\t' -v n="$name" \
                '$2 == n { f = 1; if ($1 == "fail" || $1 == "cancel") bad = 1 } END { print (bad ? "fail" : (f ? "seen" : "missing")) }')" "$name"
        else
            printf '%s\t%s\n' "$(printf '%s\n' "$3" | awk -F'\t' -v n="$name" -v a="$id" \
                '$2 == n && $3 == a { f = 1; if ($1 == "fail" || $1 == "cancel") bad = 1 } END { print (bad ? "fail" : (f ? "seen" : "missing")) }')" "$name (app $id)"
        fi
    done <<<"$1"
}

# _status_only <required status rows> — HIMMEL-3391: of the MISSING producer-pinned
# labels ("<name> (app <id>)"), the ones a commit STATUS by that name exists for,
# comma-joined ("" when none, or when the status read fails — no cause is guessed).
# Naming the cause is all this does: a missing check stays missing either way.
#
# ponytail: a commit status carries no app id — the REST payload has none and
# GraphQL StatusContext exposes only `creator`, a login, not the app — so a
# producer-pinned check published as a status can never be verified here. It is
# NEVER accepted by name alone (a false pass); a pinned check whose app publishes
# statuses stays refused (exit 5) until the pin is dropped or the app publishes a
# check run. himmel's own required checks are all GitHub Actions (app 15368) check
# runs, so this fires only on another repo's pin.
_status_only() {
    local ctx label name hit=""
    ctx=$(gh api "repos/$owner/$repo/commits/$head0/status?per_page=100" --paginate \
        --jq '.statuses[].context' 2>/dev/null) || return 0
    while IFS= read -r label; do
        name=${label% (app *)}
        [ "$name" != "$label" ] || continue
        if printf '%s\n' "$ctx" | grep -qxF -- "$name"; then hit="${hit:+$hit, }$label"; fi
    done < <(printf '%s\n' "$1" | awk -F'\t' '$1 == "missing" { print $2 }')
    printf '%s' "$hit"
}

_join_by_status() { printf '%s\n' "$2" | awk -F'\t' -v s="$1" '$1 == s { print $2 }' | paste -sd, - | sed 's/,/, /g'; }

# required_gate <wait> — 1 = a missing required check may register within
# --grace (the stated bound, the same one "no checks registered" already uses) and
# is deferred to the watch while any check is still pending; 0 = it had its
# window, refuse now. Runs BEFORE the watch (fail fast) and after
# the settle round.
required_gate() {
    local wait_ok="$1" reqs rows prows="" st missing status_only failed req_start tries=0 max_tries
    # Backstop beside the SECONDS bound: a no-op sleep seam (CHECK_CI_SLEEP_CMD=:)
    # or a POLL of 0 must not turn the bounded wait into a spin.
    max_tries=$(( GRACE / (POLL > 0 ? POLL : 1) + 1 ))
    if ! reqs=$(required_set); then
        echo "check-ci: BLOCKED — required-set unreadable: could not list the checks GitHub requires on this PR's base branch (rules/branches or branch-protection read failed). Refusing rather than treating it as an empty set; re-run once gh/API access recovers (HIMMEL-3381, exit 5)" >&2
        _alert "required-set unreadable — the required-check list for the base branch could not be read; nothing was assumed"
        exit 5
    fi
    [ -n "$reqs" ] || return 0
    req_start=$SECONDS
    while :; do
        if ! rows=$(_required_rows); then
            echo "check-ci: cannot read the PR's check rows for the required-check gate — cannot evaluate; re-run" >&2
            exit 2
        fi
        # HIMMEL-3385: an unreadable producer read fails CLOSED like the set itself —
        # falling back to the name-only rows would certify the wrong producer.
        if _has_producer_ids "$reqs" && ! prows=$(_producer_rows); then
            echo "check-ci: BLOCKED — required-check producers unreadable: could not read which app reported each check on this PR's head, so a required check pinned to an app cannot be verified. Refusing rather than matching by name alone; re-run once gh/API access recovers (HIMMEL-3385, exit 5)" >&2
            _alert "required-check producers unreadable — a required check pinned to an app could not be verified; nothing was assumed"
            exit 5
        fi
        st=$(_required_status "$reqs" "$rows" "$prows")
        failed=$(_join_by_status fail "$st")
        if [ -n "$failed" ]; then
            echo "check-ci: checks FAILED — required check(s) failed: $failed (HIMMEL-3381)" >&2
            _alert "required check(s) FAILED: $failed — GitHub will refuse this merge until they pass"
            exit 1
        fi
        missing=$(_join_by_status missing "$st")
        [ -n "$missing" ] || return 0
        # A required job held by `needs:` (an aggregator behind pending shards) is
        # not listed until its dependencies finish, so "missing" while another
        # check is still pending is not yet "never reported": leave it to the
        # watch; the post-settle call (wait 0) is the one that refuses.
        if [ "$wait_ok" -eq 1 ] && printf '%s\n' "$rows" | awk -F'\t' '$1 == "pending" { f = 1 } END { exit !f }'; then
            return 0
        fi
        tries=$((tries + 1))
        if [ "$wait_ok" -ne 1 ] || [ $((SECONDS - req_start)) -ge "$GRACE" ] || [ "$tries" -ge "$max_tries" ]; then
            echo "check-ci: BLOCKED — required check(s) never reported within ${GRACE}s: $missing. GitHub will refuse this merge; is the workflow configured for this branch, or did it not trigger? (HIMMEL-3381, exit 5)" >&2
            status_only=$(_status_only "$st")
            if [ -n "$status_only" ]; then
                echo "check-ci: BLOCKED — status-only producer: $status_only exist only as a commit status, not a check run. A commit status carries no app id, so the app this requirement pins cannot be verified; refusing rather than matching by name alone (HIMMEL-3391, exit 5)" >&2
                missing="$missing (status-only, producer unverifiable: $status_only)"
            fi
            _alert "required check(s) never reported within ${GRACE}s: $missing — GitHub will refuse this merge"
            exit 5
        fi
        "$CHECK_CI_SLEEP_CMD" "$POLL"
    done
}

# _red_alert — a red watch verdict is a merge block only when a REQUIRED check
# failed; name which. Best effort: an unreadable set/rows sends nothing (the
# exit-1 verdict stands either way).
_red_alert() {
    local reqs rows prows="" failed
    reqs=$(required_set 2>/dev/null) || return 0
    [ -n "$reqs" ] || return 0
    rows=$(_required_rows) || return 0
    if _has_producer_ids "$reqs"; then prows=$(_producer_rows) || return 0; fi
    failed=$(_join_by_status fail "$(_required_status "$reqs" "$rows" "$prows")")
    [ -z "$failed" ] || _alert "required check(s) FAILED: $failed — GitHub will refuse this merge until they pass"
}

red_exit() {
    # $1 = gh rc, $2 = elapsed seconds of the failing watch round
    echo "check-ci: checks FAILED (gh rc=$1 after ${2}s)" >&2
    if [ "$2" -le 20 ]; then
        echo "check-ci: hint — all-red within seconds is usually a GitHub Actions billing/permissions block, not a code failure; check the run annotations before debugging the diff" >&2
    fi
    _red_alert
    exit 1
}

# watch_decidable — HIMMEL-2062: is the watch's verdict already decidable
# without waiting out CodeRabbit's pending rollup row? True when every check
# NOT named CodeRabbit is terminal (not in the "pending" bucket). HIMMEL-3360:
# CodeRabbit is best effort — this never waits on CodeRabbit's own status to
# settle either; cr_signal_gate reads whatever state the head carries when the
# rest of the run reaches it and prints an advisory NOTE, it never blocks the
# watch.
#
# Fail-SAFE by construction: any unreadable/unparsable probe returns 1 (keep
# watching) — this can only ever shorten a wait, never fabricate a verdict.
watch_decidable() {
    local rows first n low
    rows=$(pr_checks --json bucket,name --jq '"CHECKCI_OK", (.[] | select(.bucket == "pending") | .name)' 2>/dev/null) || return 1
    first=${rows%%$'\n'*}
    [ "$first" = "CHECKCI_OK" ] || return 1
    # Every remaining line (if any) is a still-pending check name; all must be
    # CodeRabbit's. A pipe into `while read` runs the loop in a subshell and
    # swallows this function's `return` — iterate over a here-string instead
    # so `return 1` actually exits watch_decidable.
    while IFS= read -r n; do
        [ "$n" = "CHECKCI_OK" ] && continue
        [ -n "$n" ] || continue
        low=$(printf '%s' "$n" | tr '[:upper:]' '[:lower:]')
        # Exact match, not a substring (codex-2, HIMMEL-2062 CR round 1): the
        # rollup's own check name is exactly "CodeRabbit" — a substring glob
        # would also treat a hypothetical "CodeRabbit integration tests"
        # check as the ignorable rollup and certify green over it.
        case "$low" in
            coderabbit) ;;
            *) return 1 ;;
        esac
    done <<<"$rows"

    return 0
}

# _pending_checks_report — HIMMEL-2907: names (and counts) the checks still in
# the "pending" bucket, for the one-time cap-extension notice and the
# cannot-evaluate line below — a reader should see "shell-unit-shard (ubuntu-
# latest, 7)" instead of a bare "checks still pending". Fail-safe like
# watch_decidable: an unreadable/unparsable probe reports zero names rather
# than fabricating any; callers fall back to generic wording.
_pending_checks_report() {
    # shellcheck disable=SC2016  # jq expression, not a shell expansion
    pr_checks --json bucket,name --jq \
        '[.[] | select(.bucket == "pending")] as $p | "\($p | length)", ($p | map(.name) | join(", "))' \
        2>/dev/null
}

watch_round() {
    # $1 — extensions still allowed this call (HIMMEL-2907): 1 (default, the
    # outer caller) permits ONE more full --max-wait round on a cap-with-
    # pending verdict before refusing; the recursive self-call below passes 0
    # so a second cap-with-pending exits 2 instead of extending forever.
    local extend_ok="${1:-1}"
    # Runs one `gh pr checks --watch --fail-fast`, BOUNDED (HIMMEL-2062):
    # foreground would block a session's tool wrapper past its own timeout
    # even after the verdict is decidable, because CodeRabbit's rollup row can
    # sit "pending"/"Review queued" long after every other check (and, when
    # armed, CodeRabbit's own gate status) is terminal. Run it in the
    # background and supervise it — stop it early once the verdict no longer
    # depends on watching further (watch_decidable), or at --max-wait,
    # whichever comes first — and derive the verdict structurally either way.
    #
    # stdout stays connected to the terminal (it's the live progress display);
    # stderr is captured to a temp file so a gh-level failure (auth error,
    # cancellation, network) is distinguishable from a genuinely red check —
    # same convention as the probe loop above: a red check's failure list
    # prints to STDOUT with EMPTY stderr; a gh error writes to stderr. Nonzero
    # rc + non-empty stderr → cannot evaluate (exit 2); nonzero rc + empty
    # stderr → red_exit.
    local err_file err wpid stopped failed rc_file gh_pid_file gh_pid_recorded _gh_pid_wait
    err_file=$(mktemp) || { echo "check-ci: mktemp failed — cannot evaluate the gate" >&2; exit 2; }
    rc_file="$err_file.rc"
    gh_pid_file="$err_file.ghpid"
    watch_start=$SECONDS
    # HIMMEL-2206: `kill -0 "$wpid"` is NOT a valid liveness probe for a
    # backgrounded child under MSYS/Git-Bash — once gh exits it becomes a
    # zombie until something `wait`s on it, and `kill -0` on a zombie
    # SUCCEEDS. The loop below never observed gh actually finishing (reproduced
    # 4x via `tasklist` showing no live gh.exe while the probe stayed true), so
    # every round ran out the --max-wait cap and silently discarded gh's real
    # rc/stderr. `wait` itself is fine (it's the reaping call, not the broken
    # part) — the fix is to poll a child-written rc sentinel file for
    # liveness instead of kill -0. The inner `gh` runs inside a small subshell
    # so its own pid can be recorded (to $gh_pid_file) independently of the
    # subshell's pid ($wpid): the early-stop path below must be able to kill
    # the real gh process, not just the wrapper, or a stopped watch leaves gh
    # running detached. Both sidecars are written tmp-then-`mv -f` (same
    # directory, so the mv is atomic) so the poll loop below never observes a
    # half-written file.
    # codex-1, HIMMEL-2206 CR round 1 (this fallback replaces an earlier
    # kill-0-based one from the same round that codex-1 correctly rejected on
    # ITS OWN re-review: a wrapper wedged into a zombie by the exact MSYS
    # behavior this ticket exists to route around would ALSO answer kill -0
    # as "alive" forever, so that fallback could not actually fire in the
    # case it was written for. Fixed the right way instead — write-side, not
    # read-side: an EXIT trap makes the rc write UNCONDITIONAL on however the
    # subshell exits (normal fall-through, the explicit `exit`, or anything
    # else bash treats as a trap-worthy exit), rather than depending on one
    # specific line of the main body running. `gh_rc` defaults to 1 so a
    # truly abnormal exit (the trap firing before `gh_rc` is ever assigned)
    # reads as "cannot evaluate" downstream (rc=1 with no structural red
    # confirmed → exit 2), never a false green or a false red. This still
    # cannot survive a filesystem that rejects EVERY write (no file-based
    # signal can), but that is a different, unsolvable failure, not the one
    # under discussion.
    # codex-1, HIMMEL-2206 CR round 3 (verified, not theoretical — reproduced
    # directly with `ps -W`): backgrounding the `pr_checks` FUNCTION call
    # (`pr_checks --watch --fail-fast &`) does not exec into `gh` — bash
    # forks a process to run the function body, and calling `gh` from inside
    # an if/else keeps that wrapper alive as `gh`'s PARENT, one level below
    # $gh_pid. Killing $gh_pid then only killed that wrapper; the real `gh`
    # (confirmed with a live process tree: killing both $wpid and the
    # wrapper left `gh`'s PID alive, reparented) was left running detached —
    # exactly the orphan this rewrite must not introduce. Fixed by dropping
    # the shared `pr_checks` helper for THIS ONE background call and
    # `exec`-ing `gh` directly inside its own subshell: `exec` replaces that
    # subshell's image outright (never forks again), so $! after backgrounding
    # it IS gh's real pid — verified with the same live process tree (no
    # wrapper level; killing it killed `gh` directly, nothing orphaned).
    (
        gh_rc=1
        trap 'printf "%s\n" "$gh_rc" >"$rc_file.tmp" 2>/dev/null && mv -f "$rc_file.tmp" "$rc_file" 2>/dev/null' EXIT
        (
            if [ -n "$selector" ]; then exec gh pr checks "$selector" --watch --fail-fast --interval "$WATCH_INTERVAL"
            else exec gh pr checks --watch --fail-fast --interval "$WATCH_INTERVAL"
            fi
        ) 2>"$err_file" &
        gh_pid=$!
        # codex-1, HIMMEL-2206 CR round 5 (REJECTED deferral — the pid-sidecar
        # write below is a single unguarded line, not a trap: if it never
        # lands (write failure, or the outer subshell is killed inside the
        # 10s pid-write-race poll below before the write completes), the
        # early-stop path has no pid to read and gh survives reparented —
        # the exact orphan this rewrite exists to prevent, reached through
        # the error path instead of the happy path). Make the kill
        # independent of any file write: a TERM trap on the process that
        # actually knows gh's pid kills it directly. `wait` is interruptible
        # and traps run during it, so the parent's `kill "$wpid"` (which
        # sends TERM) reaches gh whether or not the sidecar ever landed.
        # `kill "$gh_pid"` with an empty/unset $gh_pid under 2>/dev/null is
        # harmless. The sidecar stays too — it is what covers the OTHER
        # half: the outer subshell already dead and unable to run its own
        # trap. Neither depends on the other.
        trap 'kill "$gh_pid" 2>/dev/null' TERM
        printf '%s\n' "$gh_pid" >"$gh_pid_file.tmp" && mv -f "$gh_pid_file.tmp" "$gh_pid_file"
        wait "$gh_pid"; gh_rc=$?
        exit "$gh_rc"
    ) &
    wpid=$!
    stopped=""            # "" = gh exited on its own; "cap" | "decidable" = we stopped it
    # Probe throttle (HIMMEL-2062 round 2). The wall-clock wait goes through the
    # CHECK_CI_SLEEP_CMD seam, which hermetic suites set to `:` — and
    # CHECK_CI_POLL_INTERVAL can legitimately be 0 — so this loop can spin with
    # no delay at all. watch_decidable forks a `gh` call, so an unthrottled spin
    # is a subprocess STORM: it made test-check-ci.sh crawl and intermittently
    # wedge on Windows Git-Bash. Probe at most once per $PROBE_INTERVAL seconds
    # (HIMMEL-3190: was once per real second, i.e. every loop pass, = 4 GraphQL
    # calls per probe and ~80% of the watcher's spend; the first probe is still
    # the first pass); between probes the loop body is builtins only (a file
    # existence test + arithmetic), which costs nothing and stays correct
    # because the rc sentinel appears on its own once gh exits (HIMMEL-2206).
    local last_probe=-1 elapsed remaining sleep_for
    while [ ! -f "$rc_file" ]; do
        # Cap check BEFORE sleeping + clamp the sleep to the remaining budget
        # (codex-1, HIMMEL-2062 CR round 1): sleeping the full $POLL first let
        # --max-wait overshoot by up to one whole CHECK_CI_POLL_INTERVAL —
        # arbitrarily long on a high POLL. Sleeping min(POLL, remaining)
        # instead means the cap fires within ~1s of the deadline regardless
        # of POLL, through the same CHECK_CI_SLEEP_CMD seam (hermetic suites
        # still see one no-op `:` call either way).
        sleep_for=$POLL
        if [ "$MAX_WAIT" -gt 0 ]; then
            elapsed=$((SECONDS - watch_start))
            if [ "$elapsed" -ge "$MAX_WAIT" ]; then stopped=cap; break; fi
            remaining=$((MAX_WAIT - elapsed))
            [ "$remaining" -lt "$sleep_for" ] && sleep_for=$remaining
        fi
        # Floor at 1s (codex-1, HIMMEL-2062 CR round 2): CHECK_CI_POLL_INTERVAL=0
        # is documented as legitimate, and the 1/s watch_decidable throttle above
        # does not gate this sleep call itself — an unfloored POLL=0 forks
        # "$CHECK_CI_SLEEP_CMD" 0 on every spin, a sleep-fork storm. Flooring
        # makes POLL=0 behave as a 1s poll, matching the round-1 throttle's
        # intent (no unthrottled spin). Only fires for POLL=0: remaining is
        # always >=1 once the MAX_WAIT clamp above applies. The `:` seam used by
        # hermetic suites is unaffected either way (its argument is a no-op).
        [ "$sleep_for" -lt 1 ] && sleep_for=1
        "$CHECK_CI_SLEEP_CMD" "$sleep_for"
        [ -f "$rc_file" ] && break
        if [ "$MAX_WAIT" -gt 0 ] && [ $((SECONDS - watch_start)) -ge "$MAX_WAIT" ]; then stopped=cap; break; fi
        if [ "$last_probe" -lt 0 ] || [ $((SECONDS - last_probe)) -ge "$PROBE_INTERVAL" ]; then
            last_probe=$SECONDS
            if watch_decidable; then stopped=decidable; break; fi
        fi
    done

    if [ -z "$stopped" ]; then
        # gh finished on its own — reap the wrapper subshell (it has already
        # exited or is about to, immediately after writing $rc_file) and read
        # gh's real rc from the sentinel rather than trust the wrapper's own
        # status blindly (HIMMEL-2206 edge case: validate the sentinel is
        # actually numeric before treating it as a verdict).
        wait "$wpid" 2>/dev/null
        rc=$(cat "$rc_file" 2>/dev/null)
        err=$(cat "$err_file" 2>/dev/null)
        rm -f "$err_file" "$rc_file" "$gh_pid_file"
        case "$rc" in
            ''|*[!0-9]*)
                echo "check-ci: gh pr checks --watch rc sentinel unreadable — cannot evaluate the gate; re-run" >&2
                exit 2 ;;
        esac
        if [ "$rc" -ne 0 ]; then
            if [ -n "$err" ]; then
                # HIMMEL-3190: a rate limit is not a verdict — wait for the
                # reset and re-run the round instead of exit 2.
                if ghb_is_rate_limited "$err" && _rl_recover; then
                    watch_round "$extend_ok"
                    return $?
                fi
                echo "check-ci: gh pr checks --watch failed — cannot evaluate the gate: $err" >&2
                exit 2
            fi
            # gh's documented red-check exit code is 1; anything else with
            # empty stderr (8 = pending after an interrupted watch,
            # cancellation codes, timeouts) is NOT a confirmed red — fail
            # closed as cannot-evaluate.
            if [ "$rc" -ne 1 ]; then
                echo "check-ci: gh pr checks --watch exited rc=$rc with no error output — cannot evaluate the gate; re-run" >&2
                exit 2
            fi
            # rc 1 is ALSO gh's generic failure code — confirm the red
            # structurally (at least one check in the "fail" bucket) before
            # reporting exit 1.
            failed=$(pr_checks --json bucket --jq '[.[] | select(.bucket == "fail")] | length' 2>/dev/null)
            case "$failed" in
                ''|*[!0-9]*)
                    echo "check-ci: watch reported failure but the structured confirm failed — cannot evaluate the gate; re-run" >&2
                    exit 2 ;;
            esac
            if [ "$failed" -eq 0 ]; then
                echo "check-ci: watch exited rc=1 but no check is in the fail bucket — cannot evaluate the gate; re-run" >&2
                exit 2
            fi
            red_exit "$rc" $((SECONDS - watch_start))
        fi
        return 0
    fi

    # We stopped the watch ourselves — gh never gave a verdict, so derive one
    # structurally, the same probe the rc==1 path above already uses.
    #
    # Kill BOTH the wrapper subshell ($wpid) AND the real gh pid recorded in
    # $gh_pid_file (HIMMEL-2206): the inner `gh pr checks --watch` runs one
    # process below the subshell now, so signaling only $wpid would leave gh
    # itself running detached — still writing to the terminal after this gate
    # has already moved on to a structural verdict.
    #
    # codex-1/codex-2, HIMMEL-2206 CR rounds 3-4: the pid write is the FIRST
    # thing the subshell does, but a stop requested in that same instant
    # could still race it — killing $wpid before the write lands would leave
    # gh already started with no recorded pid to terminate. A short bounded
    # poll here (real, not through CHECK_CI_SLEEP_CMD — a hermetic suite
    # pays nothing for it either way, since the write normally lands on the
    # very first check) closes that window before anything gets signaled.
    # 10s, matching the identical wait the codex-adv harvest in
    # .claude/commands/pr-check.md already uses for the same class of race —
    # any finite bound still has a "what if it takes even longer" edge in
    # principle, which is why that idiom's bound is what it is rather than
    # something tighter.
    # codex-1, HIMMEL-2206 CR rounds 8-9: $rc_file is checked twice below
    # (the poll's own loop condition, then again immediately before
    # signaling anything) rather than once, because gh can finish NATURALLY
    # at any point in this sequence — the poll can run up to 10 real
    # seconds, ample time for it to happen mid-poll, and the instant between
    # the poll ending and the kill is a race too. When gh finishes on its
    # own, $wpid exits normally, reaps gh via its own `wait`, and writes
    # $rc_file — signaling anything after that is not just redundant, it is
    # actively unsafe: $gh_pid_recorded would name an ALREADY-REAPED pid
    # that may have been reused by an unrelated process by the time a kill
    # reaches it. Each re-check narrows the window rather than claiming to
    # eliminate it (the codex-adv harvest's own bound in
    # .claude/commands/pr-check.md carries the same "what if it takes even
    # longer" edge in principle for the same class of race).
    #
    # codex-1/codex-2, HIMMEL-2206 CR rounds 3-4: the pid write is the FIRST
    # thing the subshell does, but a stop requested in that same instant
    # could still race it — killing $wpid before the write lands would leave
    # gh already started with no recorded pid to terminate. This poll (real,
    # not through CHECK_CI_SLEEP_CMD — a hermetic suite pays nothing for it
    # either way, since the write normally lands on the very first check)
    # closes that window before anything gets signaled. 10s, matching the
    # identical wait the codex-adv harvest uses for the same class of race.
    _gh_pid_wait=0
    while [ ! -s "$gh_pid_file" ] && [ ! -f "$rc_file" ] && [ "$_gh_pid_wait" -lt 10 ]; do
        sleep 1 2>/dev/null || :
        _gh_pid_wait=$((_gh_pid_wait + 1))
    done
    if [ ! -f "$rc_file" ]; then
        # codex-1, HIMMEL-2206 CR round 7: only fall back to killing the raw
        # recorded pid when $wpid was ALREADY gone (kill on it failed) —
        # when $wpid was alive, its own TERM trap (armed right after
        # $gh_pid was assigned) already signals the real gh directly, so
        # signaling $gh_pid_recorded a second time here is redundant AND,
        # if gh has since exited and been reaped, risks PID reuse aiming
        # that second signal at an unrelated process. This does not weaken
        # the fallback: $wpid already dead here (rather than exited
        # cleanly, which the check above already routes around) means its
        # trap never ran, so the explicit kill below is still the only
        # thing that can reach gh in that case.
        if ! kill "$wpid" 2>/dev/null; then
            if [ -s "$gh_pid_file" ]; then
                gh_pid_recorded=$(cat "$gh_pid_file" 2>/dev/null)
                case "$gh_pid_recorded" in
                    ''|*[!0-9]*) ;;
                    *) kill "$gh_pid_recorded" 2>/dev/null ;;
                esac
            fi
        fi
    fi
    wait "$wpid" 2>/dev/null || :
    rm -f "$err_file" "$rc_file" "$gh_pid_file" "$rc_file.tmp" "$gh_pid_file.tmp"
    if [ "$stopped" = cap ]; then
        echo "check-ci: watch cap reached (${MAX_WAIT}s) — evaluating now (HIMMEL-2062); if this repeats, verify state directly: gh pr view <PR> --json state" >&2
    else
        echo "check-ci: every non-CodeRabbit check is terminal — ending the watch early (HIMMEL-2062)" >&2
    fi

    failed=$(pr_checks --json bucket --jq '[.[] | select(.bucket == "fail")] | length' 2>/dev/null)
    case "$failed" in
        ''|*[!0-9]*)
            echo "check-ci: the structured check probe failed after the bounded watch — cannot evaluate the gate; re-run" >&2
            exit 2 ;;
    esac
    if [ "$failed" -gt 0 ]; then
        red_exit 1 $((SECONDS - watch_start))
    fi

    # Cap ONLY: a cap reached with non-CodeRabbit work still pending is not a
    # decidable verdict on its own. HIMMEL-2907: nothing failed here (the
    # check above already returned otherwise) — a slow-but-healthy shard
    # still mid-run must not read as "cannot evaluate" on the FIRST cap. So
    # extend once: run one more full --max-wait round before refusing. Only a
    # SECOND cap-with-pending (extend_ok=0, the recursive call below) exits 2
    # — the "decidable" stop already proved a bare terminal-check set never
    # hits this branch, so it never hits.
    if [ "$stopped" = cap ] && ! watch_decidable; then
        local report pending_n pending_names
        report=$(_pending_checks_report)
        pending_n=${report%%$'\n'*}
        case "$pending_n" in
            ''|*[!0-9]*) pending_n=0; pending_names="" ;;
            *) pending_names=${report#*$'\n'} ;;
        esac
        if [ "$extend_ok" -eq 1 ]; then
            echo "check-ci: WAITING ${pending_n} pending (${pending_names:-unnamed}) — extending once (HIMMEL-2907)" >&2
            watch_round 0
            return $?
        fi
        echo "check-ci: watch cap reached with non-CodeRabbit checks still pending (${pending_names:-unnamed}) — cannot evaluate the gate; re-run (raise --max-wait). Do NOT infer state from log absence — verify directly: gh pr view <PR> --json state (HIMMEL-2206)" >&2
        exit 2
    fi

    return 0
}

if [ "$THREADS_ONLY" -eq 0 ]; then
    # Grace window: probe (non-watch) until the PR has registered checks. gh exit
    # codes on the probe: 0 = all pass, 8 = pending — both mean checks exist, so
    # hand off to the watch. "no checks reported" right after a push is the CI
    # provider not having picked up the head SHA yet — retry through it. "no pull
    # requests found" is terminal. A non-zero rc with EMPTY stderr is a red check
    # (the failure list went to the discarded stdout) — hand off to the watch,
    # which produces the authoritative verdict. Any OTHER stderr (auth, network,
    # rate-limit) is a gate we cannot evaluate — exit 2, never a fake red.
    start=$SECONDS
    while :; do
        err=$(pr_checks 2>&1 >/dev/null)
        rc=$?
        if [ "$rc" -eq 0 ] || [ "$rc" -eq 8 ]; then break; fi
        if [ -z "$err" ]; then break; fi
        if printf '%s' "$err" | grep -i 'no pull requests found' >/dev/null; then
            echo "check-ci: $err" >&2
            exit 2
        fi
        if ! printf '%s' "$err" | grep -i 'no checks reported' >/dev/null; then
            # HIMMEL-3190: budget exhaustion is a wait, not a verdict.
            if ghb_is_rate_limited "$err" && _rl_recover; then continue; fi
            echo "check-ci: gh pr checks failed — cannot evaluate the gate: $err" >&2
            exit 2
        fi
        if [ $((SECONDS - start)) -ge "$GRACE" ]; then
            echo "check-ci: no checks registered within ${GRACE}s — is CI configured for this branch, or did the push land?" >&2
            exit 2
        fi
        "$CHECK_CI_SLEEP_CMD" "$POLL"
    done

    # Bind the verdict to this head: a concurrent push during the run would
    # make the certified commit differ from the one a merge would take.
    head0=$(pr_view --json headRefOid --jq .headRefOid 2>/dev/null)
    if [ -z "$head0" ]; then
        echo "check-ci: cannot read the PR head SHA — cannot bind the verdict; re-run" >&2
        exit 2
    fi

fi

# Thread gate: checks green is not merge-safe while PR review comments sit
# unresolved — every addressed CR finding must have its thread resolved.
# Fail-closed on a query error (exit 2): a gate we cannot evaluate must not
# pass; re-run when gh/API recovers. Owner/repo/number come from the PR's own
# URL so a URL/branch selector pointing at another repo still gates the RIGHT
# repo (github.com only — a GHE host would need gh --hostname, out of scope).
ctx="checks green but "
[ "$THREADS_ONLY" -eq 1 ] && ctx=""
# url + reviewDecision in ONE query: url doubles as the success probe, so a
# failed call can never silently read as "no decision".
pr_json=$(pr_view --json url,reviewDecision --jq '"\(.url)|\(.reviewDecision)"' 2>/dev/null)
pr_url=${pr_json%%|*}
case "$pr_url" in
    https://github.com/*/pull/*) ;;
    *)
        echo "check-ci: ${ctx}cannot resolve the PR (gh pr view gave '${pr_url:-nothing}') — re-run, or verify with gh pr view" >&2
        exit 2 ;;
esac
num=${pr_url##*/}
nwo=${pr_url#https://github.com/}
owner=${nwo%%/*}
repo_rest=${nwo#*/}
repo=${repo_rest%%/*}

# review_state_gate — the CHANGES_REQUESTED blocker + the paginated
# unresolved-thread gate, as one re-runnable unit. It runs BEFORE the zombie
# probe (fail-fast, and the override's zero-unresolved evidence) and AGAIN
# after the final watch/settle on every success path (codex-adv 980-r2):
# review state can change during a long watch WITHOUT moving the head SHA —
# a pre-watch snapshot must never be what gets certified.
review_state_gate() {
    local decision unresolved cursor pages sent_cursor page page_count rest has_next
    # Fresh reviewDecision each call (the module-top pr_json copy would be a
    # stale snapshot by the post-watch call). An explicit CHANGES_REQUESTED
    # review is a merge blocker. Approval is NOT required — single-operator
    # repos carry no GitHub approval objects (the CR flow is the approval
    # gate); only the affirmative "do not merge" signal blocks.
    # Fail CLOSED on a failed/malformed refresh (coderabbit 980-r3): an empty
    # snapshot would otherwise skip the CHANGES_REQUESTED check silently.
    decision=$(pr_view --json url,reviewDecision --jq '"\(.url)|\(.reviewDecision)"' 2>/dev/null)
    case "$decision" in
        https://github.com/*/pull/*"|"*) decision=${decision##*|} ;;
        *)
            echo "check-ci: ${ctx}could not refresh the PR review decision (gh pr view gave '${decision:-nothing}') — re-run" >&2
            exit 2 ;;
    esac
    if [ "$decision" = "CHANGES_REQUESTED" ]; then
        echo "check-ci: ${ctx}a review requests changes on this PR — address it (and resolve its threads), then re-run" >&2
        exit 3
    fi

    # Paginate: first:100 alone would let unresolved threads beyond page one slip
    # through the gate. Each page reports "<unresolved-count> <hasNextPage> <endCursor>".
    unresolved=0
    cursor=""
    pages=0
    while :; do
        # Hard page cap: bounds EVERY malformed-pagination shape (incl. non-adjacent
        # cursor cycles like A→B→A that a last-cursor comparison can't see) at
        # 50 pages = 5000 threads — far beyond any real PR. Fail closed past it.
        pages=$((pages + 1))
        if [ "$pages" -gt 50 ]; then
            echo "check-ci: ${ctx}the review-thread query did not terminate within 50 pages (cursor cycle?) — check threads manually on PR #$num" >&2
            exit 2
        fi
        # Positional args are free after option parsing — reuse them for the
        # conditional cursor without an unquoted expansion (function-local $@).
        sent_cursor="$cursor"
        set -- -f o="$owner" -f r="$repo" -F n="$num"
        [ -n "$cursor" ] && set -- "$@" -f c="$cursor"
        # shellcheck disable=SC2016  # $o/$r/$n/$c are GraphQL variables — literal on purpose
        page=$(gh api graphql \
            -f query='query($o:String!,$r:String!,$n:Int!,$c:String){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:100,after:$c){pageInfo{hasNextPage endCursor} nodes{isResolved}}}}}' \
            "$@" \
            --jq '.data.repository.pullRequest.reviewThreads | "\([.nodes[] | select(.isResolved | not)] | length) \(.pageInfo.hasNextPage) \(.pageInfo.endCursor)"' 2>/dev/null)
        page_count=${page%% *}
        rest=${page#* }
        has_next=${rest%% *}
        cursor=${rest#* }
        case "$page_count" in
            ''|*[!0-9]*)
                # HIMMEL-3190: stderr is discarded above, so ask the budget
                # itself: exhausted -> wait for the reset and retry THIS page;
                # healthy (or beyond --max-wait) -> the original fail-closed exit.
                if _rl_recover; then pages=$((pages - 1)); cursor="$sent_cursor"; continue; fi
                echo "check-ci: ${ctx}the review-thread query failed — re-run, or check threads manually on PR #$num" >&2
                exit 2 ;;
        esac
        case "$has_next" in
            true|false) ;;
            *)
                echo "check-ci: ${ctx}the review-thread query returned a malformed page (hasNextPage='$has_next') — re-run, or check threads manually on PR #$num" >&2
                exit 2 ;;
        esac
        if [ "$has_next" = "true" ] && { [ -z "$cursor" ] || [ "$cursor" = "null" ]; }; then
            echo "check-ci: ${ctx}the review-thread query returned a malformed page (hasNextPage=true with no cursor) — re-run, or check threads manually on PR #$num" >&2
            exit 2
        fi
        # A repeated cursor with hasNextPage=true would loop forever — fail closed.
        if [ "$has_next" = "true" ] && [ "$cursor" = "$sent_cursor" ]; then
            echo "check-ci: ${ctx}the review-thread query returned a malformed page (cursor did not advance) — re-run, or check threads manually on PR #$num" >&2
            exit 2
        fi
        unresolved=$((unresolved + page_count))
        [ "$has_next" = "true" ] || break
    done
    if [ "$unresolved" -gt 0 ]; then
        echo "check-ci: ${ctx}$unresolved unresolved review thread(s) on PR #$num — address each comment, resolve its thread, re-run" >&2
        exit 3
    fi
}

[ "$THREADS_ONLY" -eq 1 ] || required_gate 1
review_state_gate

# cr_signal_gate — HIMMEL-1072, the reason this file changed.
#
# `gh pr checks --watch` only waits on checks that EXIST when the watch starts.
# CodeRabbit registers seconds-to-minutes after a push, so a watch launched right
# after `git push` concluded "all checks green" over a rollup containing only
# `Mergeable` (title/message lint — not a review). Reproduced on PR #1249 @
# 80042b18: at T+0 `grep -c CodeRabbit` over the watch output was 0 and this
# script exited 0; at T+~4min the rollup showed CodeRabbit PENDING. The gate
# concluded before the reviewer arrived. That false green is what merged #1243
# with 6 unresolved threads.
#
# So the CodeRabbit signal is REQUIRED, not merely evaluated-if-present: it must
# be PRESENT and CONCLUDED on the exact head SHA we watched. "Whatever is in the
# rollup right now" cannot tell `not required` from `hasn't posted yet` from
# `passed` — only an explicit requirement can.
#
# Runs AFTER the watch + settle so the normal registration race resolves itself
# in the window that already exists; only a signal still missing by then fails.
cr_signal_gate() {
    # Availability gate (HIMMEL-1125): no CodeRabbit App on this repo -> no-op.
    # Silent on purpose — an adopter without CodeRabbit must not notice that a
    # CodeRabbit gate exists. Note this turns OFF only the CodeRabbit-status
    # requirement; review_state_gate above is a generic unresolved-THREAD gate
    # (human reviewers included) and stays armed for everyone, unchanged.
    [ "$CR_ARMED" -eq 1 ] || return 0

    local state
    # HIMMEL-3360: CodeRabbit is best effort. Every state but success
    # (pending, failure, error, absent, skipped, paged, anything this script
    # does not recognize) is advisory, never a block — and so is a status
    # read that FAILED: an unreadable advisory signal cannot be a gate
    # outcome either. The thread gate (review_state_gate) and the
    # body-findings gate (cr_body_gate) keep their own fail-closed reads and
    # are what still certify the merge.
    state=$(cr_signal_state "$owner" "$repo" "$head0") || state=unreadable
    case "$state" in
        success) : ;;
        *)
            echo "check-ci: NOTE — CodeRabbit $state on head $head0 of PR #$num: best effort (HIMMEL-3360), not gating; thread + body-findings gates still apply." >&2 ;;
    esac
}

# cr_body_gate — HIMMEL-1126/1147 (S1, see cr-body-findings.sh header):
# CodeRabbit posts findings the thread gate above cannot see at all — outside-
# diff-range / nitpick / additional comments living only in the review BODY
# text, never as a resolvable thread. Runs after cr_signal_gate (concluded)
# and review_state_gate (threads) — spec order concluded -> threads -> bodies
# -> head re-bind — so a body posted while CodeRabbit was still concluding is
# caught by the same re-verification window the other two gates already rely
# on.
#
# check-ci is the CERTIFIER (spec §4): it fails CLOSED everywhere, so the
# reader's rc 1 (infrastructure) and rc 2 (anti-drift canary) both mean
# "cannot certify" here, unlike cr-merge-gate's asymmetric fail-open/closed
# split on the same two codes.
#
# nitpick/additional counts are non-blocking; they ride the caller's final
# success line via body_nitpick/body_additional + _cbg_note (globals, not
# `local` — they must survive past this function's return).
# _cr_body_read — one fail-closed read+parse+validate unit, shared by the
# normal gate and the bounded escalation loop. The _cbg_* outputs are globals
# so a successful loop re-read becomes the normal evaluation below; duplicating
# this parser would risk drifting the load-bearing per-field validation.
_cr_body_read() {
    local line rc tok _v
    line=$(cr_body_findings "$owner" "$repo" "$num" "$head0")
    rc=$?
    case "$rc" in
        0) ;;
        1)
            echo "check-ci: ${ctx}could not read CodeRabbit's review-body findings on head $head0 of PR #$num (query/parse failure) — cannot evaluate the gate; re-run" >&2
            exit 2 ;;
        2)
            echo "check-ci: ${ctx}CodeRabbit's review body on head $head0 of PR #$num shows a finding the parser cannot count (format drift) — cannot evaluate the gate; check the PR body manually" >&2
            exit 2 ;;
        *)
            echo "check-ci: ${ctx}cr-body-findings returned an unrecognized rc=$rc on PR #$num — cannot evaluate the gate; re-run" >&2
            exit 2 ;;
    esac

    # Word-split + anchor on `case`, NOT a `.*key=` sed/grep regex: the line
    # carries both `outside=` and `prior_outside=`, and an unanchored
    # `.*outside=` regex greedily matches the LATTER. `case` patterns match
    # from the START of the token, so `outside=*` cannot match a token that
    # begins with `prior_outside=`.
    _cbg_outside=""; _cbg_nitpick=""; _cbg_additional=""; _cbg_prior_outside=""; _cbg_head_reviews=""; _cbg_substantive=""
    for tok in $line; do
        case "$tok" in
            outside=*) _cbg_outside=${tok#outside=} ;;
            nitpick=*) _cbg_nitpick=${tok#nitpick=} ;;
            additional=*) _cbg_additional=${tok#additional=} ;;
            prior_outside=*) _cbg_prior_outside=${tok#prior_outside=} ;;
            head_reviews=*) _cbg_head_reviews=${tok#head_reviews=} ;;
            substantive=*) _cbg_substantive=${tok#substantive=} ;;
        esac
    done
    # Validate EACH field independently, NOT the concatenation (CR #1297): a
    # missing/empty `outside` would be masked by the other numerics in the
    # joined string (nitpick=5 additional=3 -> "53" passes the all-digits test),
    # then `[ "$_cbg_outside" -gt 0 ]` below errors on the empty value, is
    # treated as false, and the outside-diff gate fails OPEN. Per-field guards
    # fail closed.
    for _v in "$_cbg_outside" "$_cbg_nitpick" "$_cbg_additional" "$_cbg_prior_outside" "$_cbg_head_reviews" "$_cbg_substantive"; do
        case "$_v" in
            ''|*[!0-9]*)
                echo "check-ci: ${ctx}cr-body-findings returned an unparseable line ('$line') on PR #$num — cannot evaluate the gate; re-run" >&2
                exit 2 ;;
        esac
    done
}

cr_body_gate() {
    # Availability gate (HIMMEL-1125), same posture as cr_signal_gate above:
    # cr_body_findings lives in cr-body-findings.sh, which is only SOURCED when
    # CR_ARMED=1 (see the sourcing block near the top of this script) — reaching
    # past this early return while disarmed would call an undefined function.
    [ "$CR_ARMED" -eq 1 ] || return 0

    _cr_body_read

    # HIMMEL-3360 operator ruling (2026-09-21): best effort covers ABSENCE
    # only — a rate-limited/silent/not-yet-posted CodeRabbit never waits or
    # re-triggers. It does NOT cover a finding CodeRabbit already POSTED: when
    # this head carries no review of its own (substantive=0, outside=0) but a
    # prior head DOES carry outside-diff findings (prior_outside>0), that
    # prior review still GOVERNS the gate — it must be dispositioned exactly
    # like a finding at this head, just keyed to the head that actually
    # carries it. EVERY prior head with a posted finding governs (HIMMEL-3365),
    # not only the latest one — a newer prior review must not mask an older
    # head's undispositioned finding.
    if [ "$_cbg_prior_outside" -gt 0 ] && [ "$_cbg_substantive" -eq 0 ] && [ "$_cbg_outside" -eq 0 ]; then
        _cr_prior_outside_gate
    fi

    body_outside_note=""
    if [ "$_cbg_outside" -gt 0 ]; then
        _cr_outside_gate "$head0" "$_cbg_outside"
    fi

    body_nitpick="$_cbg_nitpick"
    body_additional="$_cbg_additional"
}

# _cr_prior_outside_gate — HIMMEL-3365. head0 carries no review of its own, but
# prior head(s) carry posted outside-diff findings (prior_outside>0): run the
# outside gate over EVERY such head (cr_body_prior_outside_heads), each finding
# keyed to the head that raised it, and report every undispositioned one in ONE
# exit 3 — never just the latest prior head's (a newer prior review must not
# mask an older head's finding). `exit 2` is safe here: the reader runs in a
# `$(…)` only after `|| { …; exit 2; }`, so the exit lands in this shell.
_cr_prior_outside_gate() {
    local heads ph gated=""
    heads=$(cr_body_prior_outside_heads "$owner" "$repo" "$num" "$head0") || {
        echo "check-ci: ${ctx}could not resolve which prior heads carry CodeRabbit's outside-diff findings on PR #$num (query/parse failure) — cannot evaluate the gate; re-run" >&2
        exit 2
    }
    _cog_blocked=0
    while IFS= read -r ph; do
        [ -n "$ph" ] || continue
        _cr_outside_gate "$ph" "" defer
        gated="$gated $ph"
    done <<<"$heads"
    [ "$_cog_blocked" -eq 0 ] || exit 3
    if [ -n "$gated" ]; then
        echo "check-ci: NOTE — CodeRabbit posted no review at head $head0 of PR #$num; its outside-diff findings at prior head(s)$gated are all dispositioned (best effort, HIMMEL-3360: no wait, no re-trigger)" >&2
    fi
}

# _cr_outside_gate <gate_head> <expected_count> [defer] — HIMMEL-3124. An outside-diff-
# range finding has no thread, so it used to be clearable only by a commit
# (which moves the head and discards CodeRabbit's review, HIMMEL-1252 — an
# entire re-review over a Minor). Each one may instead carry an explicit,
# adjudicated ledger disposition AT THIS EXACT HEAD (cr_ledger_outside_
# dispositioned: deferred + tracked ticket + reason, or disproved + reason;
# never severity-gated). ANY undispositioned finding keeps the old exit 3; a
# list that cannot be trusted (query failure, or the header count differs from
# what parsed) is exit 2 and prints NO recording recipe.
#
# <gate_head> is head0 at the call site above, OR a PRIOR head that carries a
# posted finding (_cr_prior_outside_gate calls this once per such head;
# HIMMEL-3360 operator ruling: best effort covers ABSENCE at head0 only, not a
# finding CodeRabbit already posted at a prior head). A non-empty [defer] (3rd
# arg) turns the undispositioned exit 3 into `_cog_blocked=1` + return, after the
# message is printed, so the caller can gate every prior head and exit 3 once
# (exit 2, cannot-evaluate, still exits at once). <expected_count> is the reader's own header count, used for a
# format-drift cross-check; empty skips that check — on the prior-head path
# cr_body_outside_findings's own header-vs-parsed check (inside the reader)
# already covers it. On success sets body_outside_note for _cbg_note.
_cr_outside_gate() {
    local gate_head="$1" expected="$2" defer="${3:-}"
    local rows rc id sev file line title n_ok=0 n_all=0 c=0 i=0 s=0 msg="" q qf extra use_head0=0 dispositioned
    rows=$(cr_body_outside_findings "$owner" "$repo" "$num" "$gate_head")
    rc=$?
    case "$rc" in
        0) ;;
        1)
            echo "check-ci: ${ctx}could not read the outside-diff findings of CodeRabbit's review body on head $gate_head of PR #$num (query/parse failure) — cannot evaluate the gate; re-run" >&2
            exit 2 ;;
        2)
            echo "check-ci: ${ctx}CodeRabbit's review body on head $gate_head of PR #$num lists outside-diff findings the parser cannot fully read (format drift) — cannot evaluate the gate; check the PR body manually" >&2
            exit 2 ;;
        *)
            echo "check-ci: ${ctx}cr-body-findings returned an unrecognized rc=$rc on PR #$num — cannot evaluate the gate; re-run" >&2
            exit 2 ;;
    esac
    extra=""
    if [ "$gate_head" != "$head0" ]; then
        extra='   (or: --verdict fixed --reason "fixed in <sha>")'
        use_head0=1
    fi
    while IFS=$'\t' read -r id sev file line title; do
        [ -n "$id" ] || continue
        n_all=$((n_all + 1))
        dispositioned=1
        if [ "$use_head0" -eq 1 ]; then
            cr_ledger_outside_dispositioned "$gate_head" "$id" "$file" "$line" "$head0" && dispositioned=0
        else
            cr_ledger_outside_dispositioned "$gate_head" "$id" "$file" "$line" && dispositioned=0
        fi
        if [ "$dispositioned" -eq 0 ]; then
            n_ok=$((n_ok + 1))
            case "$sev" in crit) c=$((c + 1)) ;; imp) i=$((i + 1)) ;; *) s=$((s + 1)) ;; esac
        else
            # single-quote the reviewer-authored path and title for the paste-ready
            # recipe (either may hold a quote; id/sev/line/head are inert by shape)
            q=${title//\'/\'\\\'\'}
            qf=${file//\'/\'\\\'\'}
            msg="$msg
  - $id [$sev] $file:$line — $title
      bash scripts/cr/ledger-append.sh finding --head $gate_head --branch <pr-branch> --model coderabbit-outside --id $id --severity $sev --file '$qf' --line '$line' --text '$q' --verdict deferred --deferred-to <TICKET> --reason \"<why>\"   (or: --verdict disproved --reason \"<why>\")$extra"
        fi
    done <<<"$rows"
    if [ -n "$expected" ] && [ "$n_all" -ne "$expected" ]; then
        echo "check-ci: ${ctx}CodeRabbit's review body on head $gate_head of PR #$num counts $expected outside-diff finding(s) but $n_all parsed out (format drift) — cannot evaluate the gate; check the PR body manually" >&2
        exit 2
    fi
    if [ "$n_ok" -lt "$n_all" ]; then
        local prefix=""
        if [ "$gate_head" != "$head0" ]; then
            prefix="this head $head0 carries no CodeRabbit review (best effort, HIMMEL-3360: nothing waits or re-triggers), so the gate reads the latest review at prior head $gate_head: "
        fi
        echo "check-ci: ${ctx}${prefix}CodeRabbit's review body reports $n_all outside-diff-range finding(s) on head $gate_head of PR #$num, $((n_all - n_ok)) not dispositioned — these carry no thread to resolve; address them, or record an explicit disposition at head $gate_head (deferred needs a tracked ticket AND a reason; a disposition never carries to a new head), then re-run:$msg" >&2
        if [ -n "$defer" ]; then _cog_blocked=1; return 0; fi
        exit 3
    fi
    body_outside_note=" (outside-diff dispositioned=$n_ok (crit=$c imp=$i sug=$s))"
}

# _cbg_note — appended to the success line when non-blocking body findings
# exist (HIMMEL-1147: the failure mode was invisibility, not permissiveness —
# surface the count, never block on it alone).
_cbg_note() {
    printf '%s' "${body_outside_note:-}"
    if [ "${body_nitpick:-0}" -gt 0 ] || [ "${body_additional:-0}" -gt 0 ]; then
        printf ' (CodeRabbit body: nitpick=%s additional=%s, non-blocking)' "${body_nitpick:-0}" "${body_additional:-0}"
    fi
}

if [ "$THREADS_ONLY" -eq 1 ]; then
    # Bind + certify this path's own head (previously skipped entirely — S1
    # was invisible here too): cr_signal_gate/cr_body_gate both need a head0,
    # and /pr-check step 4.8 calling this path must get the SAME body-finding
    # protection as the full run, not just the thread gate.
    if [ "$CR_ARMED" -eq 1 ]; then
        head0=$(pr_view --json headRefOid --jq .headRefOid 2>/dev/null)
        if [ -z "$head0" ]; then
            echo "check-ci: cannot read the PR head SHA — cannot bind the verdict; re-run" >&2
            exit 2
        fi
        cr_signal_gate

        # Re-verify threads AFTER CodeRabbit has concluded (codex CR round;
        # mirrors the full path's post-watch re-verification, codex-adv
        # 980-r2): CodeRabbit can post an unresolved thread and THEN flip its
        # status to success WHILE cr_signal_gate ran above — the pre-conclude
        # snapshot from the earlier unconditional review_state_gate call
        # (before this if) must not be the one that gets certified.
        review_state_gate

        # Body findings (HIMMEL-3360: freshness is no longer gated here — a
        # body becoming visible during the thread re-verification must not
        # slip past on a pre-refresh read).
        cr_body_gate

        # Re-read the head: the verdict this path just certified (threads +
        # CodeRabbit concluded + body findings) only holds for the SHA it
        # queried — mirrors the full path's post-watch head1 re-bind below.
        head1=$(pr_view --json headRefOid --jq .headRefOid 2>/dev/null)
        if [ "$head1" != "$head0" ]; then
            echo "check-ci: PR head moved during the run (${head0} → ${head1:-unreadable}) — checks certified a different commit; re-run" >&2
            exit 2
        fi
    fi
    echo "check-ci: all review threads resolved (PR #$num)$(_cbg_note)"
    exit 0
fi

# Watch round 1: authoritative red/green for the checks registered so far.
watch_round

# Settle round (codex-adv-1): give slow-registering check runs time to appear,
# then watch again — round 2 waits for (or fails fast on) any late arrivals.
if [ "$SETTLE" -gt 0 ]; then
    "$CHECK_CI_SLEEP_CMD" "$SETTLE"
    watch_round
fi

# A required check that STILL has not reported after the watch + settle had its
# window (HIMMEL-3381): refuse now rather than certify a green GitHub will block.
required_gate 0

# CodeRabbit must be PRESENT + CONCLUDED on this head (HIMMEL-1072). It runs
# AFTER the watch/settle (that window is where a racing review posts) but BEFORE
# the thread re-verification below, and that order is load-bearing
# (coderabbit-11): threads-first loses a race — snapshot threads (clean) ->
# CodeRabbit posts its findings and flips to success -> read the verdict
# (success) -> exit 0 over threads never seen. Establishing that the reviewer
# CONCLUDED first makes the thread set below final.
cr_signal_gate

# Re-verify review state AFTER the watch/settle (codex-adv 980-r2) and after the
# verdict: a review can request changes or a new unresolved thread can land
# during a long watch without moving the head SHA — certifying the pre-watch
# snapshot would let merge-on-green proceed over fresh blocking feedback.
review_state_gate

# Body findings (HIMMEL-1126/1147, S1): runs after the concluded + threads
# re-verification above, before the final head re-bind (spec-ordered
# concluded -> threads -> bodies -> head re-bind) — a body becoming visible
# in the same post-watch window the other gates already re-check must not
# slip past on a stale pre-watch read. HIMMEL-3360: review freshness is no
# longer gated here — CodeRabbit is best effort.
cr_body_gate

# Re-read the head: the green verdict only holds for the SHA we watched.
head1=$(pr_view --json headRefOid --jq .headRefOid 2>/dev/null)
if [ "$head1" != "$head0" ]; then
    echo "check-ci: PR head moved during the run (${head0} → ${head1:-unreadable}) — checks certified a different commit; re-run" >&2
    exit 2
fi

echo "check-ci: all checks green + all review threads resolved (PR #$num @ $head0)$(_cbg_note)"
exit 0
