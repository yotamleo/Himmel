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
# Usage: check-ci.sh [<pr-number|branch|url>] [--grace <sec>] [--settle <sec>] [--threads-only] [--escalate]
#   selector        optional; defaults to the PR for the current branch
#   --threads-only  skip the checks watch entirely and run just the
#                   review-thread gate (used by /pr-check step 4.8 so both
#                   enforcement points share ONE implementation)
#   --escalate      if an incremental CodeRabbit pass produced no review object
#                   while a prior head had outside-diff findings, or the latest
#                   bot review is stale-anchored, request ONE @coderabbitai full
#                   review and poll for its review object
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
#   --max-wait <sec> bound on each `gh pr checks --watch` round (default 540;
#                   0 = unbounded, today's behaviour). HIMMEL-2062: CodeRabbit
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
# A green verdict additionally REQUIRES CodeRabbit to have concluded on that head
# SHA (HIMMEL-1072). An absent review is not a passing one: the watch only waits
# on checks that already exist, so a review that registers later was never waited
# on, and "green" got reported over a PR nobody had reviewed. See cr_signal_gate.
#
# A green verdict ALSO requires CodeRabbit's review-BODY to carry zero
# outside-diff-range findings (HIMMEL-1126/1147, S1): CodeRabbit posts some
# findings only in the review body's collapsible sections, never as a
# resolvable thread — the thread gate above is blind to them by construction.
# See cr_body_gate (in scripts/lib/cr-body-findings.sh). Runs on BOTH the full
# path and --threads-only (the latter now binds its own head to do so).
#
# A green verdict ALSO requires the latest bot REVIEW OBJECT to be anchored to
# the head SHA (HIMMEL-1181, B2): GitHub auto-resolves (outdates) a review
# thread when a later commit changes its lines, so "0 unresolved threads" is
# NOT proof the head was ever reviewed — a concluded STATUS (cr_signal_gate)
# is a different claim than an anchored REVIEW (this reader). See
# review_freshness_gate (in scripts/lib/cr-review-freshness.sh). Runs on BOTH
# the full path and --threads-only, same as the body-findings gate.
#
# That CodeRabbit requirement is AVAILABILITY-GATED (HIMMEL-1125): it arms only
# on a repo that declares CodeRabbit (scripts/lib/cr-available.sh). On a repo
# without it, "absent" is the permanent steady state, so the armed gate exited 2
# on every merge forever unless the adopter discovered CR_PROFILE=none. The
# unresolved-THREAD gate below is NOT availability-gated — it is generic (it
# blocks on any reviewer's unresolved thread, human included) and is unchanged.
#
# Exit codes (the CodeRabbit clauses below apply ONLY when the signal gate is
# ARMED — see the availability note above; on a disarmed repo they simply do not
# fire, and the checks + thread verdicts stand on their own):
#   0 — all checks green AND all review threads resolved AND, WHEN ARMED,
#       CodeRabbit concluded success on the head SHA AND zero outside-diff-range
#       body findings AND the latest bot review is anchored to the head SHA, OR
#       a stale-anchor diff is carried by a clean exact-head critic panel —
#       the DEFAULT for that shape regardless of risk classification, HIMMEL-2162
#       (safe to merge; nitpick/additional body findings are surfaced,
#       non-blocking)
#   1 — at least one check failed (--fail-fast: returns on the first red), or —
#       when armed — CodeRabbit's own status is failure/error
#   2 — cannot evaluate: usage error / no PR found / no checks registered
#       within --grace / gh error on the probe or the watch / thread-state
#       query failed or returned a malformed page / PR head moved during the run
#       / (when armed) CodeRabbit's status is absent or still pending on the head
#       SHA / the review-body-findings reader could not evaluate (infra failure
#       or an anti-drift canary — both fail closed here, see cr-body-findings.sh)
#       / the review-freshness query failed, or the review window is
#       indeterminate ("paged" — see cr-review-freshness.sh) / CodeRabbit's
#       status reads a COMPLETED review while the PR carries no CodeRabbit
#       review object at ANY head and no walkthrough certifies this head —
#       a "completed" review with nothing to be incremental to (HIMMEL-1374)
#   3 — checks green but the review state blocks the merge: unresolved review
#       threads remain, a review requests changes, or CodeRabbit's review body
#       reports an outside-diff-range finding — address, resolve, re-run
#   4 — (when armed) either: CodeRabbit concluded incrementally on the head but
#       posted no review object there while a prior head had outside-diff
#       findings (request @coderabbitai full review, or opt in with --escalate);
#       or the latest bot review is anchored to a NON-head commit and no clean
#       exact-head critic panel carries it. FAIL-CLOSED PRESERVED: no panel row
#       at this head still exits 4, high-risk diff or not (HIMMEL-2162).
#
# Env:
#   CHECK_CI_POLL_INTERVAL — seconds between grace-window probes (default 10;
#                            tests set 0; non-numeric falls back to default)
#   CHECK_CI_SETTLE        — default for --settle (flag wins)
#   CHECK_CI_SLEEP_CMD     — the command every wall-clock wait in this script
#                            goes through (default `sleep`); hermetic suites set
#                            it to `:` so a simulated poll costs no real seconds
#   CHECK_CI_MAX_WAIT      — default for --max-wait (flag wins; default 540, 0 =
#                            unbounded; HIMMEL-2062)
#   CR_ESCALATE_WAIT       — --escalate total wait budget (default 600)
#   CR_ESCALATE_POLL       — --escalate seconds between re-reads (default 120)
#   CR_PROFILE=none        — this repo has no CodeRabbit: skip the required-signal
#                            gate. Still honored, but no longer something an
#                            adopter must discover — see the availability gate
#                            below.
#   CR_APP=1|0             — force the required-signal gate on/off, overriding
#                            the probe (see scripts/lib/cr-available.sh)
#   CR_BOT_USER_ID         — creator.id to trust as CodeRabbit (see cr-signal.sh
#                            and cr-body-findings.sh; REST identity)
#   CR_BOT_LOGINS          — review-author logins that count as the bot for the
#                            review-freshness gate only (default coderabbitai;
#                            a trailing "[bot]" suffix is optional — see
#                            cr-review-freshness.sh; GraphQL identity)
#
# The HIMMEL-980 zombie-check-run override is GONE: it keyed off a CodeRabbit
# CHECK-RUN, which CodeRabbit never posts (it posts a commit STATUS), so it had
# never once fired. Reading the status directly makes it moot.
#
# Un-maskable verdict (HIMMEL-974): every exit path additionally prints
# "check-ci: verdict exit=N" to STDOUT via an EXIT trap installed after arg
# parsing (--help / usage errors stay clean). A caller that pipes the run
# (`check-ci.sh | tail`) gets the PIPE's exit code, not this script's — the
# verdict line keeps the real status readable in any captured output.
set -uo pipefail

usage() {
    cat >&2 <<'EOF'
usage: check-ci.sh [<pr-number|branch|url>] [--grace <sec>] [--settle <sec>] [--max-wait <sec>] [--threads-only] [--escalate]
exit codes: 0 = checks green + all review threads resolved
                + (if CodeRabbit is armed) CodeRabbit concluded success on the head SHA
                + zero outside-diff-range body findings
                + the latest bot review is anchored to the head SHA, or a clean exact-head panel
                  carries an ordinary stale-anchor diff,
            1 = a check failed, or (if armed) CodeRabbit's status is failure/error,
            2 = cannot evaluate (usage / no PR / no checks within --grace / thread query failed / PR head moved
                / (if armed) CodeRabbit's status absent or still pending on the head SHA / body-findings
                reader failed / review-freshness query failed or indeterminate "paged" / the status says
                the review COMPLETED but the PR carries no CodeRabbit review object at any head and no
                walkthrough certifies this head — nothing to be incremental to, HIMMEL-1374),
            3 = checks green but unresolved review threads remain, a review requests changes, or (if armed)
                CodeRabbit's review body reports an outside-diff-range finding,
            4 = (if armed) CodeRabbit concluded incrementally but posted no review object at the head while a
                prior head had outside-diff findings (request @coderabbitai full review or use --escalate); or
                the latest bot review is anchored to a NON-head commit and no clean exact-head panel carries it
                (use --escalate for a full review; a clean panel at THIS head carries by default, HIMMEL-2162 —
                no panel row at this head still exits 4)
env: CR_PROFILE=none skips the required-CodeRabbit-signal + body-findings + review-freshness gates (repos
     without CodeRabbit)
     CR_APP=1|0 forces those same gates on/off, overriding the automatic probe (see scripts/lib/cr-available.sh)
     CR_BOT_LOGINS sets the review-author logins the freshness gate treats as the bot (default coderabbitai)
     CR_ESCALATE_WAIT / CR_ESCALATE_POLL tune --escalate for absent or stale-anchor reviews (defaults 600 / 120 seconds)
     CHECK_CI_SLEEP_CMD replaces the command every wall-clock wait runs (default sleep; hermetic suites set it to :)
     CHECK_CI_MAX_WAIT sets --max-wait's default (default 540 seconds, 0 = unbounded; HIMMEL-2062)
note: "armed" above means the required-CodeRabbit-signal + body-findings + review-freshness gates are active —
      DISARMED by default. On a repo that has the CodeRabbit App, arm it once:  git config --local himmel.coderabbit true
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
ESCALATE=0
# HIMMEL-1698: unconditional init — cr_signal_gate is the only writer (success
# arm), and it early-returns when CR_ARMED=0 and is skipped entirely on some
# paths, so under `set -u` review_freshness_gate's read of this diagnostic
# flag would otherwise trip on an unset variable.
_cr_head_status_ok=0
GRACE=180
SETTLE="${CHECK_CI_SETTLE:-30}"
MAX_WAIT="${CHECK_CI_MAX_WAIT:-540}"
POLL="${CHECK_CI_POLL_INTERVAL:-10}"
# Sleep seam (HIMMEL-1953). EVERY wall-clock wait below goes through this one
# command word so a hermetic suite can inject `:` and never burn real seconds on
# a simulated poll. That matters most for the --escalate nap: a case that leaves
# CR_ESCALATE_POLL at 0 while CR_ESCALATE_WAIT is positive gets the 120s
# validated fallback (see below) and used to sleep two REAL minutes — a test
# that sleeps is a test that can hang, and a hang is indistinguishable from a
# slow suite. Keeping the fallback's nap on this seam is the point: the
# validation stays (0 would worsen rate-limit pressure in production), while
# tests pay nothing for it.
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

selector=""
while [ $# -gt 0 ]; do
    case "$1" in
        --grace)
            if [ $# -lt 2 ]; then echo "check-ci: --grace needs a value" >&2; usage; exit 2; fi
            GRACE="$2"; shift 2 ;;
        --settle)
            if [ $# -lt 2 ]; then echo "check-ci: --settle needs a value" >&2; usage; exit 2; fi
            SETTLE="$2"; shift 2 ;;
        --max-wait)
            if [ $# -lt 2 ]; then echo "check-ci: --max-wait needs a value" >&2; usage; exit 2; fi
            MAX_WAIT="$2"; shift 2 ;;
        --threads-only)
            THREADS_ONLY=1; shift ;;
        --escalate)
            ESCALATE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "check-ci: unknown option: $1" >&2; usage; exit 2 ;;
        *)
            if [ -n "$selector" ]; then echo "check-ci: only one PR selector allowed (got '$selector' and '$1')" >&2; usage; exit 2; fi
            selector="$1"; shift ;;
    esac
done

case "$GRACE" in
    ''|*[!0-9]*) echo "check-ci: --grace must be a non-negative integer, got '$GRACE'" >&2; exit 2 ;;
esac
case "$SETTLE" in
    ''|*[!0-9]*) echo "check-ci: --settle must be a non-negative integer, got '$SETTLE'" >&2; exit 2 ;;
esac
case "$MAX_WAIT" in
    ''|*[!0-9]*) echo "check-ci: --max-wait must be a non-negative integer, got '$MAX_WAIT'" >&2; exit 2 ;;
esac

# Escalation is an explicit write path, never a default gate side effect: both
# clear-cr-marker.sh and merge-on-green.sh call this script as pure observers.
# These knobs are therefore read only when --escalate opts into the action.
if [ "$ESCALATE" -eq 1 ]; then
    CR_ESCALATE_WAIT="${CR_ESCALATE_WAIT-600}"
    CR_ESCALATE_POLL="${CR_ESCALATE_POLL-120}"
    case "$CR_ESCALATE_WAIT" in
        ''|*[!0-9]*)
            echo "check-ci: CR_ESCALATE_WAIT='$CR_ESCALATE_WAIT' is not a non-negative integer — using 600" >&2
            CR_ESCALATE_WAIT=600 ;;
    esac
    case "$CR_ESCALATE_POLL" in
        ''|*[!0-9]*)
            echo "check-ci: CR_ESCALATE_POLL='$CR_ESCALATE_POLL' is not a non-negative integer — using 120" >&2
            CR_ESCALATE_POLL=120 ;;
    esac
    # Leading-zero values like 08 / 007 PASS the all-digits guard above but
    # poison the budget arithmetic in _cr_body_escalate: bash reads a leading
    # 0 as OCTAL inside $(( )), so $((08 - elapsed)) throws "value too great
    # for base" and aborts the script, while $((007 ...)) silently evaluates
    # as octal 7 (coincidentally right for 007, wrong for any 01x value). The
    # [ -gt ] / -ge tests happen to be base-10, but the one $(()) site is not,
    # so normalize at the source — force base-10 and every downstream use is
    # safe (HIMMEL-1219).
    CR_ESCALATE_WAIT=$((10#$CR_ESCALATE_WAIT))
    CR_ESCALATE_POLL=$((10#$CR_ESCALATE_POLL))
    if [ "$CR_ESCALATE_WAIT" -gt 0 ] && [ "$CR_ESCALATE_POLL" -eq 0 ]; then
        # CR_ESCALATE_WAIT=0 is the immediate-timeout lever. With a positive
        # budget, zero would worsen the rate-limit pressure this path reduces.
        echo "check-ci: CR_ESCALATE_POLL=0 is invalid when CR_ESCALATE_WAIT > 0 — using 120" >&2
        CR_ESCALATE_POLL=120
    fi
fi

# Un-maskable verdict line (HIMMEL-974) — installed only now, after arg
# parsing, so --help and usage errors above stay clean. Prints on EVERY later
# exit path: a piped caller's pipeline exit code is the LAST command's, not
# this script's, so the numeric verdict must survive in the output text.
trap 'echo "check-ci: verdict exit=$?"' EXIT

if ! command -v gh >/dev/null 2>&1; then
    echo "check-ci: gh CLI not found on PATH" >&2
    exit 2
fi
# jq is needed to read CodeRabbit's status + review-body findings + review
# freshness, so require it only when the CodeRabbit signal gate is ARMED
# (coderabbit-7, extended by HIMMEL-1126/HIMMEL-1125, and again by
# HIMMEL-1181): --threads-only USED to be a pure GraphQL+gh path, but it now
# also runs cr_signal_gate + cr_body_gate + review_freshness_gate (S1/B2 — a
# body-only finding or a stale review anchor is exactly as invisible to
# /pr-check step 4.8's threads-only call as it is to the full run), so it
# needs jq too whenever CodeRabbit is in play.
# Is the CodeRabbit App configured for this repo at all (HIMMEL-1125)? The
# signal + body + freshness gates below are armed ONLY when it is: on a repo
# without CodeRabbit, "absent" is the permanent steady state, so an armed
# gate exits 2 on every merge forever. Probed once here; cr_signal_gate/
# cr_body_gate/review_freshness_gate read the result.
# shellcheck source=scripts/lib/cr-available.sh
# shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
. "$(cd "$(dirname "$0")" && pwd)/lib/cr-available.sh"
CR_ARMED=0
# ONE probe, read twice (HIMMEL-2380): the rc arms the gates below exactly as it
# always did, and CR_STATE names WHY — which is the difference between an
# adopter who never had CodeRabbit and a repo that just lost its gate to a typo.
CR_STATE=$(cr_app_state "$PWD")
[ "$CR_STATE" = armed ] && CR_ARMED=1

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

if [ "$CR_ARMED" -eq 1 ]; then
    if ! command -v jq >/dev/null 2>&1; then
        echo "check-ci: jq not found on PATH (required to read CodeRabbit's status)" >&2
        exit 2
    fi
    # The ONE reader for CodeRabbit's verdict (HIMMEL-1072).
    # shellcheck source=scripts/lib/cr-signal.sh
    # shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
    . "$(cd "$(dirname "$0")" && pwd)/lib/cr-signal.sh"
    # The ONE reader for "is the latest bot REVIEW OBJECT anchored to the head
    # SHA?" (HIMMEL-1181, B2) — independent of both the status verdict above
    # and the body-findings reader below; see cr-review-freshness.sh header.
    # shellcheck source=scripts/lib/cr-review-freshness.sh
    # shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
    . "$(cd "$(dirname "$0")" && pwd)/lib/cr-review-freshness.sh"
    # The ONE reader for CodeRabbit's review-BODY findings (HIMMEL-1126/1147) —
    # outside-diff-range / nitpick / additional comments the thread gate below
    # cannot see (S1: no thread, no isResolved, unresolvable by construction).
    # shellcheck source=scripts/lib/cr-body-findings.sh
    # shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
    . "$(cd "$(dirname "$0")" && pwd)/lib/cr-body-findings.sh"
    # The CR-ledger evidence reader (HIMMEL-1465): tells cr_signal_gate below
    # whether a CLEAN critic panel carried the gate at the head, so a
    # rate-limited CodeRabbit App need not block when the panel already reviewed.
    # shellcheck source=scripts/lib/cr-ledger-evidence.sh
    # shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
    . "$(cd "$(dirname "$0")" && pwd)/lib/cr-ledger-evidence.sh"
    # Diagnostic risk classifier for the stale-anchor panel-carry audit line
    # (HIMMEL-1718); no longer gates whether the carry applies (HIMMEL-2162).
    # shellcheck source=scripts/lib/cr-high-risk-diff.sh
    # shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
    . "$(cd "$(dirname "$0")" && pwd)/lib/cr-high-risk-diff.sh"
fi

pr_checks() {
    if [ -n "$selector" ]; then gh pr checks "$selector" "$@"; else gh pr checks "$@"; fi
}

pr_view() {
    if [ -n "$selector" ]; then gh pr view "$selector" "$@"; else gh pr view "$@"; fi
}

red_exit() {
    # $1 = gh rc, $2 = elapsed seconds of the failing watch round
    echo "check-ci: checks FAILED (gh rc=$1 after ${2}s)" >&2
    if [ "$2" -le 20 ]; then
        echo "check-ci: hint — all-red within seconds is usually a GitHub Actions billing/permissions block, not a code failure; check the run annotations before debugging the diff" >&2
    fi
    exit 1
}

# watch_decidable — HIMMEL-2062: is the watch's verdict already decidable
# without waiting out CodeRabbit's pending rollup row? True only when every
# check NOT named CodeRabbit is terminal (not in the "pending" bucket) AND,
# when the CodeRabbit signal gate is armed, its own gate status is no longer
# `pending`. Waiting on CodeRabbit's ROLLUP row buys nothing once its gate
# status is terminal, because cr_signal_gate / cr_body_gate /
# review_freshness_gate below read the status directly, not the rollup row —
# but while the gate status genuinely reads `pending` we must KEEP waiting:
# that window is what turns a would-be exit 2 into exit 0 today, and losing
# it would be the regression this function must not cause.
#
# Fail-SAFE by construction: any unreadable/unparsable probe returns 1 (keep
# watching) — this can only ever shorten a wait, never fabricate a verdict.
watch_decidable() {
    local rows first n low state
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

    if [ "${CR_ARMED:-0}" -eq 1 ]; then
        state=$(cr_signal_state "$owner" "$repo" "$head0" 2>/dev/null) || return 1
        [ "$state" = pending ] && return 1
    fi
    return 0
}

watch_round() {
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
            if [ -n "$selector" ]; then exec gh pr checks "$selector" --watch --fail-fast
            else exec gh pr checks --watch --fail-fast
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
    # wedge on Windows Git-Bash. Probe at most once per real second; between
    # probes the loop body is builtins only (a file existence test +
    # arithmetic), which costs nothing and stays correct because the rc
    # sentinel appears on its own once gh exits (HIMMEL-2206).
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
        if [ "$SECONDS" != "$last_probe" ]; then
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
    # decidable verdict — refuse rather than certify green over an unfinished
    # check. The "decidable" stop already proved this true, so it never hits.
    if [ "$stopped" = cap ] && ! watch_decidable; then
        echo "check-ci: watch cap reached with non-CodeRabbit checks still pending — cannot evaluate the gate; re-run (raise --max-wait). Do NOT infer state from log absence — verify directly: gh pr view <PR> --json state (HIMMEL-2206)" >&2
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

# machine_pr_gate — HIMMEL-2278, the MACHINE-GENERATED PR class.
#
# Some PRs never receive a CodeRabbit App review at all: bot-authored
# dependency bumps (precedent #2013) and pure regenerated-artifact publishes
# (precedent #2035 — graphify-out/graph.json + GRAPH_REPORT.md, zero code).
# On those, the three App gates below fail closed FOREVER on "no status /
# no review object at head": a console parks on a review that is never
# coming, merge-on-green exits 14, and the operator merges by hand. That
# happened twice, so per the structural-over-instructional rule this is a
# classifier, not stronger prose.
#
# WHAT IT DISARMS is exactly what an operator already disarms by hand with
# CR_APP=0 for one run — the three CodeRabbit-App gates (cr_signal_gate,
# cr_body_gate, review_freshness_gate), all keyed on CR_ARMED. It is NOT a
# merge bypass and NOT a general CR bypass: the checks-green watch,
# review_state_gate's CHANGES_REQUESTED blocker, and its paginated
# unresolved-thread gate all run unchanged here exactly as on every other
# PR. Every non-machine PR keeps today's fail-closed behaviour untouched —
# the classifier's only effect on that class is to return 1.
#
# SPOOF RESISTANCE — why neither arm is a label, a title marker or a body
# token. A marker an arbitrary PR author can set would be a one-line CR
# bypass for any code PR, which is strictly worse than the drift it fixes.
# So each arm is derived from something a code PR cannot cheaply fake:
#   * dependabot — GitHub's own author.is_bot AND a dependabot login. A
#     human account cannot set is_bot, and cannot open a PR as an App.
#   * graph-publish — the DIFF SHAPE, not a marker: every changed path must
#     be one of the two tracked graphify-out artifacts. A PR carrying any
#     code touches at least one path outside that two-element set and is
#     therefore never in the class, whatever it labels or titles itself.
#     (The literal artifact paths are the case PATTERNS and $p is the
#     subject, never the reverse — a file named `*` must not glob-match its
#     way into the class.)
# Fail-CLOSED throughout: an unreadable, truncated or unparsable probe
# returns 1 and leaves the gates armed, which is today's behaviour.
#
# Kept in sync with GRAPH_PATH/REPORT_PATH in scripts/graphify/graph-publish.sh.
machine_pr_class() {
    local meta first author is_bot count paths p
    # ONE probe. The "MPR_OK" sentinel is load-bearing: an empty response or
    # a gh error must never parse as "no files, bot author".
    meta=$(pr_view --json author,files --jq \
        '"MPR_OK", (.author.login // ""), (.author.is_bot // false), ((.files // []) | length), ((.files // [])[] | .path)' 2>/dev/null) || return 1
    first=${meta%%$'\n'*}
    [ "$first" = "MPR_OK" ] || return 1
    meta=${meta#*$'\n'}
    author=${meta%%$'\n'*}
    meta=${meta#*$'\n'}
    is_bot=${meta%%$'\n'*}
    meta=${meta#*$'\n'}
    count=${meta%%$'\n'*}
    case "$count" in
        ''|*[!0-9]*) return 1 ;;
    esac
    if [ "$count" -eq 0 ]; then paths=""; else paths=${meta#*$'\n'}; fi

    # Arm 1 — dependabot. is_bot is GitHub's, not the author's.
    if [ "$is_bot" = "true" ]; then
        case "$author" in
            dependabot|'dependabot[bot]'|app/dependabot|\
            dependabot-preview|'dependabot-preview[bot]'|app/dependabot-preview)
                printf 'dependabot dependency bump'
                return 0 ;;
        esac
    fi

    # Arm 2 — a graph-publish artifact PR, recognized by diff shape alone.
    # An empty file list is not evidence of anything: fail closed.
    [ "$count" -ge 1 ] || return 1
    # …and the path lines must actually match the advertised count (codex-1,
    # HIMMEL-2278 CR round 1). Without this, a probe that reported 3 files but
    # was TRUNCATED after emitting only its two artifact paths would classify
    # as the class while the third, unseen path was code — a fail-closed gate
    # reading a partial file list as a complete one.
    [ "$(printf '%s\n' "$paths" | grep -c .)" -eq "$count" ] || return 1
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        case "$p" in
            graphify-out/graph.json|graphify-out/GRAPH_REPORT.md) ;;
            *) return 1 ;;
        esac
    done <<<"$paths"
    printf 'regenerated graphify-out artifacts only'
    return 0
}

machine_pr_gate() {
    local class
    [ "$CR_ARMED" -eq 1 ] || return 0
    class=$(machine_pr_class) || return 0
    # NOT `CR_ARMED=0` (codex-1, HIMMEL-2278 CR round 2). Blanket-disarming
    # also silenced cr_body_gate and review_freshness_gate, so on the day the
    # App DOES review a machine-class PR its outside-diff-range body findings
    # — which carry no thread, and are therefore invisible to every other gate
    # — would have been dropped. The class licenses tolerating an ABSENT
    # review, nothing more: this flag is read by exactly the two cr_signal_gate
    # arms that mean "the App said nothing" (`absent` and the skip-classified
    # family). `pending`, `failure`/`error`, `paged`, cr_body_gate and
    # review_freshness_gate all stay armed here exactly as on any other PR.
    MACHINE_PR_CLASS=1
    echo "check-ci: PR #$num is a machine-generated PR ($class) — the CodeRabbit App does not review this class, so an absent App review is the EXPECTED state for it (HIMMEL-2278; precedents #2013, #2035). Every other signal still gates: checks-green, CHANGES_REQUESTED, unresolved threads, a FAILED App status, and any body findings the App does post."
}
MACHINE_PR_CLASS=0
machine_pr_gate

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
_cr_panel_carries_absent_signal() {
    local absent_signal="$1" stale_anchor="${2:-}"
    if _cr_panel_evidence=$(cr_ledger_carries_gate "$head0"); then
        case "$absent_signal" in
            rate-limited)
                # Preserve the HIMMEL-1465 audit line byte-for-byte.
                echo "check-ci: CodeRabbit is rate-limited on head $head0 of PR #$num; the critic panel carries the gate ($_cr_panel_evidence) — not failing the verdict on the App (HIMMEL-1465)." ;;
            review-object)
                echo "check-ci: review object absent at head $head0 of PR #$num; threads resolved; panel carries — HIMMEL-1502/1506 ($_cr_panel_evidence)." ;;
            freshness)
                echo "check-ci: FRESHNESS panel carry stale_anchor=$stale_anchor head=$head0 PR #$num; threads resolved; $_cr_panel_evidence (HIMMEL-1718)." ;;
            *)
                echo "check-ci: CodeRabbit $absent_signal on head $head0 of PR #$num; the critic panel carries the gate ($_cr_panel_evidence) — not failing the verdict on the absent App signal (HIMMEL-1506)." ;;
        esac
        return 0
    fi
    return 1
}

cr_signal_gate() {
    # Availability gate (HIMMEL-1125): no CodeRabbit App on this repo -> no-op.
    # Silent on purpose — an adopter without CodeRabbit must not notice that a
    # CodeRabbit gate exists. Note this turns OFF only the CodeRabbit-status
    # requirement; review_state_gate above is a generic unresolved-THREAD gate
    # (human reviewers included) and stays armed for everyone, unchanged.
    [ "$CR_ARMED" -eq 1 ] || return 0

    local state
    state=$(cr_signal_state "$owner" "$repo" "$head0") || {
        echo "check-ci: could not read CodeRabbit's status on head $head0 — cannot evaluate the gate; re-run" >&2
        exit 2
    }
    case "$state" in
        # HIMMEL-1698 CR round: record that the head carries a CONCLUDED review
        # status, for the B2 escalation note in review_freshness_gate. This is
        # DIAGNOSTIC ONLY and must never become a gate condition — see that
        # gate's header: a concluded status does not imply a review object was
        # posted, which is the entire HIMMEL-1181 contract.
        success) _cr_head_status_ok=1 ;;
        pending)
            echo "check-ci: CodeRabbit is still reviewing head $head0 of PR #$num — not green yet; re-run when it concludes" >&2
            exit 2 ;;
        failure|error)
            echo "check-ci: CodeRabbit reported '$state' on head $head0 of PR #$num — its review did not complete" >&2
            exit 1 ;;
        absent)
            # HIMMEL-2278 — on a machine-generated PR (dependabot, or a diff of
            # nothing but the tracked graphify-out artifacts) an absent status
            # IS the steady state, not a missing review: see machine_pr_gate.
            # This is the ONLY thing the class licenses; every other arm of this
            # case, cr_body_gate and review_freshness_gate stay armed for it.
            if [ "${MACHINE_PR_CLASS:-0}" -eq 1 ]; then
                echo "check-ci: CodeRabbit posted no status on head $head0 of PR #$num — expected for a machine-generated PR (HIMMEL-2278); not failing the verdict on it."
                return 0
            fi
            # Remediation names CR_APP=0, not CR_PROFILE=none (coderabbit-7):
            # reaching this line means the gate is ARMED, so the fix is to
            # disarm availability — and CR_PROFILE=none would ALSO silently
            # change the critic-panel profile (it is overloaded; see
            # .env.example). CR_APP=0 says only the thing meant here.
            echo "check-ci: CodeRabbit has posted NO status on head $head0 of PR #$num — an unreviewed head is not a green one (HIMMEL-1072). Wait for the review and re-run; if this repo has no CodeRabbit, it should not be armed: unset it with 'git config --local --unset himmel.coderabbit' (or CR_APP=0 for this run)." >&2
            exit 2 ;;
        paged)
            # Indeterminate, not absent (coderabbit-2) — see cr-signal.sh.
            echo "check-ci: head $head0 of PR #$num has more commit statuses than one API page (100) and none is CodeRabbit's — cannot certify the review; check manually" >&2
            exit 2 ;;
        skipped)
            # HIMMEL-2278 — the #2035 shape, verbatim: the App posted
            # state=success with a skip-classified description (rate limited).
            # Every skip wording means the App's review signal is absent, which
            # for this class is expected rather than missing. Placed ahead of
            # the panel-carry logic because a machine PR has no panel evidence
            # to carry it and never will — a critic panel over a 17 MB
            # regenerated graph.json is review theater, which is the whole
            # reason the class exists.
            if [ "${MACHINE_PR_CLASS:-0}" -eq 1 ]; then
                echo "check-ci: CodeRabbit SKIPPED the review on head $head0 of PR #$num — expected for a machine-generated PR (HIMMEL-2278); not failing the verdict on it."
                return 0
            fi
            # HIMMEL-1317. Distinct from `absent`: CodeRabbit DID post, and posted
            # state=success — it just said in the description that it did not
            # review. Until this arm existed that success was indistinguishable
            # from a clean review, and this gate certified exit 0 on a PR nobody
            # had looked at (reproduced on PR #1429, 2026-07-27). Actionable
            # rather than merely closed: the operator's next move is one comment.
            #
            # HIMMEL-1506: every skip-classified description means the App's
            # review signal is absent. A CLEAN critic panel (>=1 `avail ... ok`,
            # no blocking finding) at THIS exact head carries each shape; absent
            # or dirty evidence keeps the existing fail-closed verdict/message.
            local skip_desc skip_low
            if skip_desc=$(cr_signal_description "$owner" "$repo" "$head0"); then
                skip_low=$(printf '%s' "$skip_desc" | tr '[:upper:]' '[:lower:]')
            else
                if _cr_panel_carries_absent_signal "description is unreadable"; then return 0; fi
                echo "check-ci: CodeRabbit SKIPPED the review on head $head0 of PR #$num and its description could not be read to tell rate-limiting from a disabled review — cannot evaluate the panel-carried allowance; re-run. If this repo has no CodeRabbit, set CR_PROFILE=none." >&2
                exit 2
            fi
            # Rate-limit vocabulary (mirrors cr-signal.sh's _CRS_SKIP_RE
            # `rate.?limit` arm): "rate limit" / "rate-limit" / "ratelimit".
            case "$skip_low" in
                *rate?limit*|*ratelimit*)
                    if _cr_panel_carries_absent_signal "rate-limited"; then return 0; fi
                    echo "check-ci: CodeRabbit is rate-limited on head $head0 of PR #$num and the critic panel did NOT carry the gate at this head (ledger: $_cr_panel_evidence) — a rate-limited App with no clean panel is not a green one. Wait for the App's limit to reset, or run /pr-check on this HEAD so a panel reviews it. Bypass: CR_APP=0 (or CR_PROFILE=none)." >&2
                    exit 2 ;;
                '')
                    if _cr_panel_carries_absent_signal "description is absent"; then return 0; fi ;;
                *automatic*reviews*disabled*)
                    if _cr_panel_carries_absent_signal "reports automatic reviews are disabled"; then return 0; fi ;;
                *)
                    if _cr_panel_carries_absent_signal "posted skip-classified wording"; then return 0; fi ;;
            esac
            echo "check-ci: CodeRabbit SKIPPED the review on head $head0 of PR #$num — it posted state=success, but its description does not say the review completed. A DECLINED review is not a clean one. Known causes: automatic reviews are disabled on this repo (trigger one with a '@coderabbitai review' comment, wait for it to conclude, then re-run), or CodeRabbit is RATE LIMITED (HIMMEL-1354 — wait for the limit to reset; do NOT re-trigger in a loop, and note the CLI lane 'bash scripts/cr/coderabbit-review.sh --branch <b> --base main' is a separate, independently-limited path). A clean exact-head critic panel carries every skip-classified state (HIMMEL-1506) — run /pr-check on this HEAD if no panel evidence exists yet. If CodeRabbit merely RENAMED its success wording (an OK review misclassified as a skip), widen the OK allow-list for one run with CR_OK_DESC_RE — keep both default alternatives and the ^(...)\$ anchors (HIMMEL-1354 R2); the knob does NOT apply to genuine skip wordings. If this repo has no CodeRabbit, set CR_PROFILE=none." >&2
            exit 2 ;;
        *)
            echo "check-ci: unrecognized CodeRabbit state '$state' on head $head0 — cannot evaluate the gate; re-run" >&2
            exit 2 ;;
    esac
}

# review_freshness_gate — HIMMEL-1181 (B2 / PR #1273): bind the latest bot
# REVIEW's commit anchor to the head SHA. "0 unresolved threads" is not proof
# of review — GitHub auto-resolves a thread when a later commit changes its
# lines, so a head CodeRabbit never re-reviewed can read App-clean. This is
# INDEPENDENT of cr_signal_gate above (which certifies the bot's commit
# STATUS concluded on this SHA) — a concluded incremental status does not
# imply a new review OBJECT was posted.
#
# Runs AFTER cr_body_gate (called below) on purpose: cr_body_gate's own A2
# case (prior_outside>0 && zero reviews AT head, HIMMEL-1126) already exits 4
# with an escalate-eligible message for the subset it covers, and that
# subset is a STRICT SUBSET of "stale" here (a prior outside-diff finding
# with no head review implies the latest review is anchored elsewhere).
# Running freshness second means A2's own message and --escalate path stay
# reachable for that case; this gate only fires for the genuinely uncovered
# remainder — a stale latest review that never had an outside-diff finding
# recorded (e.g. only ordinary thread comments, later auto-resolved), the
# exact PR #1273 shape.
review_freshness_gate() {
    [ "$CR_ARMED" -eq 1 ] || return 0
    local fr state login oid
    fr=$(cr_review_freshness "$owner" "$repo" "$num" "$head0") || {
        echo "check-ci: ${ctx}the review-freshness query failed on PR #$num — cannot certify the review anchor; re-run" >&2
        exit 2
    }
    state=${fr%% *}
    case "$state" in
        none)
            # `none` = ZERO CodeRabbit reviews on the whole PR, at any head,
            # ever (empty incremental shells do not count — see the reader).
            #
            # HIMMEL-1374. That is benign only while nothing else CLAIMS a
            # review happened. When cr_signal_gate certified a genuine
            # `success` on this head — the "Review completed" description —
            # the two readings contradict each other: an incremental pass
            # needs a prior review to be incremental TO, and there is none.
            # Live instance PR #1463 @ d89dd41b (2026-07-29): status
            # "Review completed", zero review objects at any head, and this
            # gate self-skipped straight to exit 0 over a PR nobody had
            # reviewed. Same class as HIMMEL-1354, one layer up: the pieces
            # were each individually right and nothing asked "was there ever
            # a review at all?".
            #
            # HOW THIS COMPOSES with the two signals it must NOT break:
            #  1. THE PANEL CARRY. A rate-limited (or otherwise
            #     skip-classified) App reaches here with _cr_head_status_ok=0
            #     — cr_signal_gate sets that flag ONLY on its `success` arm,
            #     and every skip shape leaves the gate through
            #     _cr_panel_carries_absent_signal instead. So the sanctioned
            #     "rate-limited App + clean exact-head critic panel" allowance
            #     (HIMMEL-1465/1506) still self-skips here, unchanged: the
            #     App never claimed a completed review in that shape.
            #  2. HIMMEL-1824. A CLEAN pass mints NO review object at all and
            #     delivers its verdict through the walkthrough comment, so a
            #     PR whose only pass was clean legitimately has zero review
            #     objects PR-wide. Ask that second channel before refusing —
            #     the same reader, with the same fail-closed posture the
            #     `stale` arm below uses (unreadable walkthrough → refuse).
            #     Without this, every clean-first-pass PR would block.
            if [ "$_cr_head_status_ok" -eq 1 ]; then
                local walk
                walk=$(cr_review_walkthrough "$owner" "$repo" "$num" "$head0" 2>/dev/null || true)
                if [ "$walk" != "clean" ]; then
                    echo "check-ci: ${ctx}CodeRabbit's status on head $head0 of PR #$num reads a COMPLETED review, but this PR carries NO CodeRabbit review object at any head — ever — and no walkthrough certifies this head either. A completed review with nothing to be incremental to is not evidence that a review happened; cannot evaluate the gate (HIMMEL-1374). Request '@coderabbitai full review' ONCE, wait for it to conclude, then re-run." >&2
                    exit 2
                fi
                echo "check-ci: PR #$num carries no CodeRabbit review object at all, but its WALKTHROUGH certifies head $head0 was reviewed with no actionable comments — a clean pass mints no object (HIMMEL-1824). This is App evidence, not a carry; do NOT request another review for this head."
                FRESHNESS_NOTE="no review object PR-wide; walkthrough certifies head $head0"
            else
                # Absence of a bot review is not evidence of staleness, and no
                # signal here claims otherwise — self-skip, as before.
                FRESHNESS_NOTE="no bot review — freshness self-skipped"
            fi ;;
        paged)
            echo "check-ci: ${ctx}PR #$num has more reviews than one query window (100) and none of the newest 100 is the bot's — cannot certify freshness; check manually" >&2
            exit 2 ;;
        stale)
            # fr = "stale <login> <oid>" — word-split is safe: the lib's
            # output is a controlled single line (cr-review-freshness.sh).
            # shellcheck disable=SC2086
            set -- $fr; login=$2; oid=$3

            if [ "$ESCALATE" -eq 1 ] && [ "$_cbg_head_reviews" -eq 0 ]; then
                # Explicit --escalate spends the useful full-review attempt before
                # the stale-anchor tolerance arms: success leaves no risk or panel
                # carry to decide. The head-review guard protects scarce account-
                # wide capacity; that contradictory shape is not fixable by a post.
                # Posts `@coderabbitai full review` once per head behind its idempotency
                # marker and polls; exits 4 itself if no review object lands in budget.
                #
                # HIMMEL-1698: a concluded head status is COMPATIBLE with this
                # stale anchor — CodeRabbit posts (or edits in place) an EMPTY
                # review object on an incremental pass and carries the real
                # verdict in the per-SHA status instead (PR #1728: status
                # "Review completed" at head, latest review object five commits
                # back, body_len=0). That does not make the anchor a false
                # positive: this gate is deliberately INDEPENDENT of the status
                # (see the header above — HIMMEL-1181, a concluded status never
                # implies a review object was posted), so it still escalates.
                # This is diagnostic context for the spend about to happen, not
                # a guard — do not let it skip the call below.
                if [ "$_cr_head_status_ok" -eq 1 ]; then
                    echo "check-ci: NOTE — CodeRabbit's status on head $head0 already reads a completed review, so this stale anchor may be benign incremental behaviour (it posts an empty review object on incrementals). Escalating anyway: a concluded status is not proof a review object was posted (HIMMEL-1181). This spends ONE full review, bounded by the per-head marker." >&2
                fi
                _cr_body_escalate
                # The fresh review can carry outside-diff findings the earlier
                # cr_body_gate pass could not see. Re-run it: its own A2 arm cannot
                # re-fire (the escalation above returns only once a SUBSTANTIVE
                # review is visible, and A2 is gated on substantive==0 —
                # HIMMEL-1959), so this only re-enforces the body-findings block.
                cr_body_gate
                fr=$(cr_review_freshness "$owner" "$repo" "$num" "$head0") || {
                    echo "check-ci: ${ctx}the review-freshness re-query failed on PR #$num after escalation — cannot certify the review anchor; re-run" >&2
                    exit 2
                }
                # BOTH terminal states, not just "fresh" (CR round 3). The
                # escalation now returns success when the walkthrough certifies
                # the head — and in exactly that case the review OBJECT is still
                # anchored old, so this re-query answers fresh-clean-no-object.
                # Accepting only "fresh" made the gate cancel its own escalation
                # and exit 4 on the head CodeRabbit had just certified: the very
                # loop this change exists to end, moved one line down.
                case "${fr%% *}" in
                    fresh|fresh-clean-no-object)
                        # shellcheck disable=SC2086
                        set -- $fr; login=$2
                        FRESHNESS_NOTE="${fr%% *} $login review @ $head0 (escalated)"
                        return 0 ;;
                esac
                echo "check-ci: DO-NOT-MERGE — a CodeRabbit full review landed at head $head0 of PR #$num but the latest $login review is STILL not anchored there (freshness: $fr); cannot certify" >&2
                exit 4
            fi

            local risk_detail="" risk_rc=0 risk_text=""
            risk_detail=$(cr_diff_is_high_risk "$owner" "$repo" "$num") || risk_rc=$?
            case "$risk_rc" in
                0) risk_text="the diff touches a high-risk surface: $risk_detail" ;;
                1) risk_text="the diff is ordinary" ;;
                2) risk_text="the diff's high-risk classification cannot be determined ($risk_detail), which is treated as high risk" ;;
                *) risk_rc=2; risk_detail="classifier-rc"; risk_text="the diff's high-risk classification cannot be determined (classifier-rc), which is treated as high risk" ;;
            esac

            # HIMMEL-2162: exact-head panel-carry is the DEFAULT for a stale
            # anchor now, regardless of risk classification — a clean critic
            # panel that already reviewed THIS head is the same evidence a
            # fresh CodeRabbit review would be, whether or not the diff LOOKS
            # risky. The prior HIMMEL-1718 knob (CHECK_CI_FRESHNESS_CARRY_HIGH_RISK)
            # gated only whether a high-risk diff was even ALLOWED to reach
            # this check; it never bypassed the requirement for real panel
            # evidence (see _cr_panel_carries_absent_signal below), so once the
            # gate itself is unconditional the knob has no remaining job — it
            # is retired. Fail-closed is unchanged: no panel row at this head
            # still exits 4 below, high-risk or not.
            if _cr_panel_carries_absent_signal "freshness" "$oid"; then
                if [ "$risk_rc" -ne 1 ]; then
                    echo "check-ci: LOUD — stale bot review superseded by exact-head panel despite $risk_text (HIMMEL-2162)."
                fi
                FRESHNESS_NOTE="freshness panel-carried stale $oid -> head $head0"
                return 0
            fi

            echo "check-ci: ${ctx}the latest $login review on PR #$num is anchored to ${oid}, not head ${head0} — this head was NEVER re-reviewed (auto-resolved threads can mask this); $risk_text, and the critic panel did NOT carry the gate at this head (ledger: $_cr_panel_evidence). Request @coderabbitai full review ONCE, then re-run — the plain incremental \"@coderabbitai review\" NO-OPS on an already-reviewed commit, and NEVER poll a trigger: read its reply. If the walkthrough already certifies this head clean, re-requesting cannot change the verdict (HIMMEL-1824)." >&2
            exit 4 ;;
        fresh-clean-no-object)
            # HIMMEL-1824. CodeRabbit reviewed THIS head and found nothing, so
            # it minted no review object — its verdict came through the
            # walkthrough comment instead. That is the App's own evidence about
            # this head, not a substitute for it: no panel carry is consulted
            # and CHECK_CI_FRESHNESS_CARRY_HIGH_RISK stays irrelevant, so this
            # passes a high-risk diff too. Loud on stdout because a gate that
            # passes on a second channel must say which channel it read.
            # shellcheck disable=SC2086
            set -- $fr; login=$2; oid=$3
            echo "check-ci: freshness satisfied by CodeRabbit's WALKTHROUGH at head $head0 of PR #$num — the head was reviewed with no actionable comments, which mints no review object (latest object still sits at $oid). This is App evidence, not a carry; do NOT request another full review for this head."
            FRESHNESS_NOTE="fresh-clean-no-object $login @ $head0 (walkthrough; latest object $oid)" ;;
        fresh)
            # fr = "fresh <login> <oid>"
            # shellcheck disable=SC2086
            set -- $fr; login=$2
            FRESHNESS_NOTE="fresh $login review @ $head0" ;;
        *)
            echo "check-ci: ${ctx}unrecognized freshness state '$state' — cannot evaluate; re-run" >&2
            exit 2 ;;
    esac
    return 0
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

# ── HIMMEL-1964: the escalation claim ────────────────────────────────────────
# The per-head marker used to be BOTH the lock and the request — one comment
# carrying `@coderabbitai full review` plus the marker — which made it neither:
#   * NOT single-flight. The marker scan and the POST are two API calls with
#     nothing between them, so two callers on the same head both read "no
#     marker" and both spend a full review out of account-wide capacity.
#   * NOT retryable. Once the POST lands the marker is permanent for that head,
#     so a request CodeRabbit never honours (dropped, failed, rate-limited at
#     its end) strands the head: every later run reads "already requested",
#     polls, and times out until someone pushes a new commit.
# The claim is now its own comment, posted FIRST, carrying `attempt=N`:
#   * single-flight — every caller posts a claim and then re-reads the claims
#     at its own attempt; the LOWEST comment id wins and is the only one that
#     posts the request. GitHub allocates the ids, so the tie-break is
#     server-side and total: no lease, no branch state, no clock.
#   * bounded retry — attempt 1 is the first request. An invocation that
#     entered on an EXISTING attempt-1 claim and then watched its whole poll
#     window expire with no substantive review claims attempt 2 and re-requests
#     ONCE; an attempt-2 window expiring is a strand, reported with its manual
#     remedy. Never more than two requests per head, ever.
# Markers written before this change carry no `attempt=` and read as attempt 1.
#
# TWO CEILINGS THIS DELIBERATELY KEEPS (codex panel r1), both pre-existing and
# both fail-CLOSED — they cost liveness, never a bad merge:
#   1. A claim's AUTHOR is not validated, exactly as the grep-for-marker it
#      replaces did not. Anyone who can comment on the PR can forge a marker and
#      suppress the automated request for that head. Filtering to the
#      authenticated login would break the case this whole mechanism exists for
#      — two callers running as DIFFERENT accounts would stop seeing each
#      other's claims and would both post. The strand message names the manual
#      remedy, so a forged marker never blocks a human.
#   2. Claim-then-read is not atomic. If GitHub does not yet expose a
#      concurrent claim on our re-read, both callers post. That window is the
#      medium's, not this design's, and the worst case inside it is TWO full
#      reviews — precisely what happened on EVERY concurrent run before this
#      change, so the floor only rises.

_cre_max=0   # highest attempt among this head's markers (0 = none)
_cre_low=""  # lowest comment id among this head's markers at the wanted attempt

# _cr_escalate_scan <wanted-attempt> — refresh _cre_max / _cre_low. Fails
# CLOSED on an unreadable or unparseable comment list: an unknown claim state
# must never be read as "nobody has claimed", which is the double-post.
# The SPACE after $head0 in the scan pattern is load-bearing — without it a
# marker for a head this one is a PREFIX of would read as a claim on this head,
# which the exact-match grep it replaces could not do.
_cr_escalate_scan() {
    local want="$1" list line id rest att _cre_v
    # shellcheck disable=SC2016  # $m is a jq variable — literal on purpose
    list=$(gh api "repos/$owner/$repo/issues/$num/comments" --paginate \
        --jq '.[] | ((.body // "") | [scan("<!-- himmel:cr-escalate:'"$head0"' [^>]*-->")]) as $m | select(($m | length) > 0) | "\(.id) \($m[0])"' 2>/dev/null) || {
        echo "check-ci: ${ctx}could not scan PR #$num comments for the CodeRabbit escalation marker — cannot evaluate the gate; re-run" >&2
        exit 2
    }
    _cre_max=0; _cre_low=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        id=${line%% *}
        rest=${line#* }
        att=1
        case "$rest" in
            *attempt=*) att=${rest#*attempt=}; att=${att%% *} ;;
        esac
        # Validate EACH field on its own, never the concatenation (the CR #1297
        # lesson one gate down): "$id$att" would let an empty attempt hide
        # behind a numeric id and then error in the comparisons below.
        for _cre_v in "$id" "$att"; do
            case "$_cre_v" in
                ''|*[!0-9]*)
                    echo "check-ci: ${ctx}PR #$num carries an unparseable CodeRabbit escalation marker ('$line') — cannot evaluate the gate; re-run" >&2
                    exit 2 ;;
            esac
        done
        if [ "$att" -gt "$_cre_max" ]; then _cre_max=$att; fi
        if [ "$att" -eq "$want" ]; then
            if [ -z "$_cre_low" ] || [ "$id" -lt "$_cre_low" ]; then _cre_low=$id; fi
        fi
    done <<EOF
$list
EOF
}

# _cr_escalate_request <attempt> — claim first, then request only if the claim
# WON. The loser posts no request and simply waits on the winner's review, so
# concurrent callers spend exactly one full review per (PR, head, attempt).
_cr_escalate_request() {
    local attempt="$1" claim_id
    claim_id=$(gh api "repos/$owner/$repo/issues/$num/comments" \
        -f body="<!-- himmel:cr-escalate:$head0 attempt=$attempt -->" --jq '.id' 2>/dev/null) || claim_id=""
    case "$claim_id" in
        ''|*[!0-9]*)
            echo "check-ci: ${ctx}could not claim the CodeRabbit full review for head $head0 of PR #$num (attempt $attempt) — cannot evaluate the gate; re-run" >&2
            exit 2 ;;
    esac
    _cr_escalate_scan "$attempt"
    if [ -n "$_cre_low" ] && [ "$_cre_low" -lt "$claim_id" ]; then
        # Withdraw the losing claim (codex panel r2). A loser's claim records
        # nothing — the winner's does — but left behind it reads as a spent
        # attempt to every later invocation, which would survive the winner's
        # own rollback above and silently cost the head one of its two
        # requests. Best effort, same as the rollback.
        gh api -X DELETE "repos/$owner/$repo/issues/comments/$claim_id" >/dev/null 2>&1 || true
        echo "check-ci: another check-ci run claimed the CodeRabbit full review for head $head0 of PR #$num first (claim #$_cre_low beats #$claim_id) — NOT requesting a second one; waiting for that review" >&2
        return 0
    fi
    if ! gh api "repos/$owner/$repo/issues/$num/comments" -f body="@coderabbitai full review" >/dev/null 2>&1; then
        # Roll the claim BACK (codex panel r1). Without this a transient POST
        # failure consumes one of the two attempts while spending no request at
        # all — the ticket's own "not retryable after a partial failure" bug,
        # one layer in. Best effort: if the delete also fails the claim simply
        # stands, which is no worse than the state before this line existed.
        gh api -X DELETE "repos/$owner/$repo/issues/comments/$claim_id" >/dev/null 2>&1 || true
        echo "check-ci: ${ctx}could not post @coderabbitai full review for head $head0 of PR #$num — cannot evaluate the gate; re-run" >&2
        exit 2
    fi
    echo "check-ci: requested @coderabbitai full review for head $head0 of PR #$num (attempt $attempt)" >&2
}

# _cr_body_escalate — the ONLY write path in check-ci, reachable solely through
# --escalate. CodeRabbit's normal incremental command is a no-op after it has
# concluded, while `@coderabbitai full review` deliberately ignores incremental
# state. The per-head claim above makes retries idempotent and bounded; the
# bounded loop keeps a missing review object visibly fail-closed instead of
# waiting forever.
#
# WHY THE POLL WAITS ON `substantive`, NOT `head_reviews` (HIMMEL-1959).
# `head_reviews` counts EVERY bot review at the head, and CodeRabbit posts
# EMPTY review objects on incremental passes — measured on PR #1728, where the
# status at the merged head read "Review completed" while the latest review
# object sat five commits back with body_len=0. One such empty object landing
# after the escalation comment would satisfy a head_reviews>0 exit condition,
# so the loop could return success while the requested full review was still
# pending or had failed — and the caller would then evaluate `outside=0`
# derived from no substantive body at all. That is a false GREEN produced by
# an empty payload, the same shape HIMMEL-1582 fixed one layer down.
#
# Attribution is sound WITHOUT a recorded pre-request baseline because the
# caller's entry condition IS the baseline: cr_body_gate reaches here only
# when substantive==0, re-read immediately before the call. So at request time
# there is no substantive review at this head by construction, and any
# substantive review the loop below observes necessarily arrived after the
# request. Empty objects may already be sitting there — which is precisely why
# the baseline that matters is `substantive` and not a set of review IDs: an
# empty incremental object is not the review that was asked for, whether it
# predates the request or lands during it.
#
# The post-escalation re-check runs CodeRabbit's own status FIRST
# (cr_signal_gate), so a full review that FAILED or is still concluding
# cannot be read as a delivered review — then threads, then bodies, the same
# concluded -> threads -> bodies order the normal path certifies in.
_cr_body_escalate() {
    local start elapsed remaining nap prior
    _cr_escalate_scan 0
    prior=$_cre_max
    if [ "$prior" -gt 0 ]; then
        echo "check-ci: CodeRabbit full review was already requested for head $head0 of PR #$num (attempt $prior); waiting for its review object" >&2
    else
        _cr_escalate_request 1
    fi
    echo "check-ci: waiting up to ${CR_ESCALATE_WAIT}s for a substantive review at head $head0 of PR #$num" >&2

    start=$SECONDS
    while :; do
        _cr_body_read
        if [ "$_cbg_substantive" -gt 0 ]; then
            echo "check-ci: a substantive CodeRabbit review is visible at head $head0 of PR #$num; evaluating its findings" >&2
            # Status FIRST: a full review that failed or is still concluding
            # must not be certified as delivered just because a review object
            # exists. Then the thread gate — the full review can create inline
            # threads AFTER the normal pre-body thread gate ran — then refresh
            # the body once more, preserving the normal concluded -> threads ->
            # bodies order so escalation cannot launder any finding shape.
            cr_signal_gate
            review_state_gate
            _cr_body_read
            [ "$_cbg_substantive" -gt 0 ] && return 0
        fi
        # HIMMEL-1949 x HIMMEL-1824: waiting only for a substantive OBJECT is
        # unsatisfiable when the requested review comes back CLEAN — that pass
        # mints no object at all, so this loop burned its whole budget and then
        # exited 4 on a head CodeRabbit had already certified. Accept the
        # walkthrough as a terminal answer too. Read once per turn, bounded like
        # every other call in the lib; an unreadable walkthrough just keeps
        # waiting, so the fail-closed timeout below is untouched.
        if [ "$(cr_review_walkthrough "$owner" "$repo" "$num" "$head0" 2>/dev/null || true)" = "clean" ]; then
            # CR round 5: this return must certify the SAME things the object
            # return above does, or the walkthrough becomes a cheaper door into
            # the same success. Two holes it closed: a failure/error status
            # posted by the escalated pass was invisible here, and the caller
            # went on to judge $_cbg_outside from the PRE-escalation read.
            #
            # Status is checked with the RAW reader, never cr_signal_gate:
            # that gate exits 2 on `pending`, which inside this loop would turn
            # "keep waiting" into "re-run" and hand the caller a spurious
            # failure. So: success certifies, failure/error refuses outright,
            # and anything else (pending / absent / unreadable) falls through
            # to keep waiting — the fail-closed timeout below is untouched.
            _wt_st=$(cr_signal_state "$owner" "$repo" "$head0" 2>/dev/null || true)
            case "$_wt_st" in
                failure|error)
                    echo "check-ci: DO-NOT-MERGE — CodeRabbit reported '$_wt_st' on head $head0 of PR #$num; its walkthrough cannot certify a review that did not complete" >&2
                    exit 1 ;;
                success)
                    # Threads THEN body, the same order the object path uses:
                    # the full review can open inline threads, and the body
                    # re-read is what stops the caller evaluating outside-diff
                    # findings from before the escalation.
                    review_state_gate
                    _cr_body_read
                    echo "check-ci: CodeRabbit's walkthrough certifies head $head0 of PR #$num was reviewed with no actionable comments — a clean pass mints no review object, so no further object is coming. Escalation satisfied (status success, threads and body re-checked)." >&2
                    return 0 ;;
            esac
        fi
        elapsed=$((SECONDS - start))
        if [ "$elapsed" -ge "$CR_ESCALATE_WAIT" ]; then
            # HIMMEL-1964. A window that expires on a request THIS run just
            # posted is an ordinary timeout — the review may still be coming.
            # A window that expires on a claim a PREVIOUS run posted is the
            # strand: that request had a full budget and delivered nothing.
            # Attempt 1 stranded buys exactly one re-request; attempt 2
            # stranded is terminal and says so, with the manual remedy.
            if [ "$prior" -ge 2 ]; then
                echo "check-ci: DO-NOT-MERGE — head $head0 of PR #$num is STRANDED: $prior @coderabbitai full review requests have each gone a full ${CR_ESCALATE_WAIT}s window without producing a substantive review. check-ci will not request another (two per head is the cap). Push a new commit — a new head starts a fresh pair of attempts — or request '@coderabbitai full review' by hand and check CodeRabbit's own status on this PR." >&2
                exit 4
            fi
            if [ "$prior" -eq 1 ]; then
                _cr_escalate_request 2
                echo "check-ci: DO-NOT-MERGE — the full review requested earlier for head $head0 of PR #$num (attempt 1) never produced a substantive review, so a second one is now requested (attempt 2). Re-run to wait for it; if that window expires too the head is stranded and check-ci will say so." >&2
                exit 4
            fi
            echo "check-ci: DO-NOT-MERGE — no substantive CodeRabbit review is visible at head $head0 of PR #$num after ${CR_ESCALATE_WAIT}s (${_cbg_head_reviews} review object(s) at this head, none carrying a body — an empty incremental review is not the full review that was requested, and no walkthrough certifies this head clean either); cannot certify" >&2
            exit 4
        fi
        remaining=$((CR_ESCALATE_WAIT - elapsed))
        nap=$CR_ESCALATE_POLL
        [ "$nap" -gt "$remaining" ] && nap=$remaining
        [ "$nap" -gt 0 ] && "$CHECK_CI_SLEEP_CMD" "$nap"
    done
}

cr_body_gate() {
    # Availability gate (HIMMEL-1125), same posture as cr_signal_gate above:
    # cr_body_findings lives in cr-body-findings.sh, which is only SOURCED when
    # CR_ARMED=1 (see the sourcing block near the top of this script) — reaching
    # past this early return while disarmed would call an undefined function.
    [ "$CR_ARMED" -eq 1 ] || return 0

    _cr_body_read

    # A2's evidence is readable but incrementally silent: CodeRabbit concluded
    # on this head, yet its incremental pass produced no SUBSTANTIVE review
    # while a prior head still carries outside-diff findings. That is distinct
    # from rc 2 (the gate genuinely cannot be read) and has one known
    # resolution: force a full review. Default observers stay read-only and
    # return rc 4; --escalate opts into posting the command once and boundedly
    # re-reading.
    #
    # Gated on `substantive`, NOT `head_reviews` (HIMMEL-1959 CR round 1).
    # Hardening only the escalation POLL left this entry test keyed on
    # head_reviews, which displaced the false green by exactly one invocation
    # instead of removing it: run 1 escalates, an EMPTY review object lands at
    # the head, the poll correctly refuses and exits 4 — but that object
    # PERSISTS, so run 2 reads head_reviews=1 and skips A2 entirely. outside
    # then reads 0 (no substantive body to read it from) and the freshness gate
    # accepts the empty object as head-anchored, so the gate exits 0 while the
    # requested full review never arrived. Both ends must agree on what counts
    # as a review, or the guard is only as strong as its weaker test.
    if [ "$_cbg_prior_outside" -gt 0 ] && [ "$_cbg_substantive" -eq 0 ]; then
        # review_state_gate already proved the thread set resolved immediately
        # before this body read. Exact-head panel evidence may therefore carry
        # this otherwise-only missing review-object signal (HIMMEL-1502/1506).
        if [ "$_cbg_outside" -eq 0 ] && _cr_panel_carries_absent_signal "review-object"; then return 0; fi
        if [ "$ESCALATE" -eq 0 ]; then
            echo "check-ci: ${ctx}PR #$num had unresolved outside-diff findings at a prior head, but CodeRabbit's incremental pass posted no substantive review at current head $head0 (${_cbg_head_reviews} review object(s) there, none carrying a body) — request @coderabbitai full review, then re-run" >&2
            exit 4
        fi
        _cr_body_escalate
    fi

    if [ "$_cbg_outside" -gt 0 ]; then
        echo "check-ci: ${ctx}CodeRabbit's review body reports $_cbg_outside outside-diff-range finding(s) on head $head0 of PR #$num — these carry no thread to resolve; address them, then re-run" >&2
        exit 3
    fi

    body_nitpick="$_cbg_nitpick"
    body_additional="$_cbg_additional"
}

# _cbg_note — appended to the success line when non-blocking body findings
# exist (HIMMEL-1147: the failure mode was invisibility, not permissiveness —
# surface the count, never block on it alone).
_cbg_note() {
    if [ "${body_nitpick:-0}" -gt 0 ] || [ "${body_additional:-0}" -gt 0 ]; then
        printf ' (CodeRabbit body: nitpick=%s additional=%s, non-blocking)' "${body_nitpick:-0}" "${body_additional:-0}"
    fi
}

# _frn_note — appended to the success line so a "fresh" or self-skipped
# ("none") certification is visible in the output, not just its absence of a
# block (HIMMEL-1181). Set by review_freshness_gate; unset on every path that
# never reached it (CR_ARMED=0), hence the default expansion.
FRESHNESS_NOTE=""
_frn_note() {
    [ -n "${FRESHNESS_NOTE:-}" ] && printf '; %s' "$FRESHNESS_NOTE"
    return 0
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

        # Body findings, THEN freshness (HIMMEL-1181 — see review_freshness_gate's
        # own header for why this order, not the reverse): a body becoming
        # visible during the thread re-verification must not slip past on a
        # pre-refresh read, and cr_body_gate's own A2 exit-4 case must stay
        # reachable before the broader freshness check would otherwise
        # preempt it.
        cr_body_gate
        review_freshness_gate

        # Re-read the head: the verdict this path just certified (threads +
        # CodeRabbit concluded + body findings + review freshness) only holds
        # for the SHA it queried — mirrors the full path's post-watch head1
        # re-bind below.
        head1=$(pr_view --json headRefOid --jq .headRefOid 2>/dev/null)
        if [ "$head1" != "$head0" ]; then
            echo "check-ci: PR head moved during the run (${head0} → ${head1:-unreadable}) — checks certified a different commit; re-run" >&2
            exit 2
        fi
    fi
    echo "check-ci: all review threads resolved (PR #$num)$(_cbg_note)$(_frn_note)"
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

# Body findings, THEN review freshness (HIMMEL-1126/1147, S1 + HIMMEL-1181,
# B2): runs after the concluded + threads re-verification above, before the
# final head re-bind (spec-ordered concluded -> threads -> bodies ->
# freshness -> head re-bind) — a body or a stale review anchor becoming
# visible in the same post-watch window the other gates already re-check
# must not slip past on a stale pre-watch read. Body findings run first so
# cr_body_gate's own A2 exit-4 case (see review_freshness_gate's header)
# stays reachable before the broader freshness check would otherwise
# preempt it.
cr_body_gate
review_freshness_gate

# Re-read the head: the green verdict only holds for the SHA we watched.
head1=$(pr_view --json headRefOid --jq .headRefOid 2>/dev/null)
if [ "$head1" != "$head0" ]; then
    echo "check-ci: PR head moved during the run (${head0} → ${head1:-unreadable}) — checks certified a different commit; re-run" >&2
    exit 2
fi

echo "check-ci: all checks green + all review threads resolved (PR #$num @ $head0)$(_cbg_note)$(_frn_note)"
exit 0
