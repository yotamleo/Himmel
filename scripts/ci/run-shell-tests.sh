#!/usr/bin/env bash
# scripts/ci/run-shell-tests.sh — discover + run himmel's hermetic shell suites.
#
# Runs every `<scan-root>/**/test-*.sh` EXCEPT the suites listed in SKIP_LIST,
# which need the full agent stack (claude / hermes / docker), a live VM, or
# network / git-remote access — none of which exist on a bare CI runner. That
# SKIP_LIST is the ledger of "what we can't test here"; everything else is
# "what we can".
#
# Finer-grained tables refine that binary. SUITE_CONDITIONAL (HIMMEL-1589)
# holds a suite back only under --changed-since when nothing it guards changed,
# SUITE_REQUIRE_TOOL (HIMMEL-1792) is capability-conditional: a suite there
# RUNS on every host that has the tool and is [SKIP]ped loudly with its reason
# where the tool is absent — never dead weight in SKIP_LIST on hosts that DO
# have the capability, the exact blind spot that let a PowerShell-only
# regression ship green (HIMMEL-1774) — and SUITE_TIER (HIMMEL-2120) is a
# declarative corpus-reduction table gated by env SUITE_TIER_MODE
# (fast|extended|all; unset = all = byte-identical to no filter).
#
# Docs-only fast lane (HIMMEL-2166): an extension of the --changed-since
# trigger, not a new flag. When the filter is active and EVERY changed path
# (tracked + untracked) is a *.md file or lives under docs/, no suite here can
# exercise it — the whole corpus is [SKIP]ped, not just the leak-barrier
# suites SUITE_CONDITIONAL guards — and a zero-suites-ran run is reported as a
# genuine pass instead of the HIMMEL-1128 false-green refusal. A MIXED diff
# (any non-docs path) does not qualify and falls through to the ordinary
# SKIP_LIST/tier/conditional/capability filtering unchanged.
#
# Phased-CI intent (HIMMEL-494): the first runs are a discovery instrument. A
# suite that fails only because of a missing runner capability gets moved into
# SKIP_LIST (with a reason) until the job is green; a suite that fails for a
# real bug stays red. Keep SKIP_LIST minimal and justified.
#
# Usage:
#   scripts/ci/run-shell-tests.sh                        # run all non-skipped suites under scripts/
#   scripts/ci/run-shell-tests.sh [scan-root]            # run under a different root
#   scripts/ci/run-shell-tests.sh --list [scan-root]     # print run/skip plan, run nothing
#   scripts/ci/run-shell-tests.sh --skip-extra <relpath> # add an ad-hoc skip (repeatable)
#   scripts/ci/run-shell-tests.sh --changed-since <ref>  # additionally skip conditional suites
#                                                        # whose scope is unchanged since <ref>
#   scripts/ci/run-shell-tests.sh --pr <N>               # ALSO post the SUMMARY block as a
#                                                        # comment on PR <N> (opt-in, or env
#                                                        # SUITE_REPORT_PR=N; HIMMEL-2383) —
#                                                        # never default-on, never posted
#                                                        # without one of these set
#
#   Flags may appear before or after the scan-root.
#   scan-root defaults to "scripts" when omitted.
#
#   --changed-since <ref> (or env SUITE_CHANGED_SINCE) is OPT-IN: without it,
#   every suite runs exactly as today. With it, a suite listed in
#   SUITE_CONDITIONAL runs only if a changed path (git diff --name-only <ref>
#   plus untracked) matches its ERE; a non-matching conditional suite is SKIPped
#   with a reason. A default-on filter would silently drop a leak-barrier suite
#   from a clean CI checkout, and silently reduced coverage is worse than a slow
#   run. Not a git repo / unresolvable ref / failing diff -> fail-open: run all.
#
# Exit codes: 0 — one or more suites ran and all passed, OR zero ran because
#             --changed-since proved the diff docs-only (HIMMEL-2166); 1 — at
#             least one suite failed, OR zero suites ran for any OTHER reason
#             (a resolved-to-nothing scan root is a misconfiguration, not a
#             pass — HIMMEL-1128), OR the run budget expired with suites still
#             unrun; 2 — REFUSED, either another full-suite run already holds
#             the machine lock (HIMMEL-1338) or SUITE_TIER_MODE was set to
#             something other than fast/extended/all (HIMMEL-2120);
#             3 — ABORTED, the scan root vanished or was replaced under the
#             live run (HIMMEL-2517); 4 — ABORTED, an rc=127 storm means
#             almost nothing here could execute (HIMMEL-2517). 3 and 4 are
#             NOT test verdicts: no tally is a result and no after-report is
#             posted, so a caller must not read either as "some suites
#             failed" — 1 remains the only code that means that.
#
# CONCURRENCY (HIMMEL-1338): on 2026-07-28 five sessions had this runner going
# at once on one workstation; the oldest had been at it for 150 minutes. The
# runs were not deadlocked — they were starving each other. Every concurrent
# run multiplies the process churn (~1000 processes / 200 live bash at the
# sample), each suite then takes 5-20x longer, and the per-suite cap starts
# firing on suites that are merely slow. The runs test the SAME TREE, so all
# but one of them is pure waste. Hence a machine-wide advisory lock: the
# second concurrent run REFUSES (rc 2) and says who holds it, rather than
# piling on. Knobs, all env:
#
#   SUITE_TIMEOUT      per-suite wall-clock cap, seconds (default 600)
#   SUITE_RUN_BUDGET   whole-run wall-clock cap, seconds (default 7200); the
#                      runner stops BETWEEN suites once it is spent and names
#                      what did not run, instead of running until morning
#   SUITE_LOCK         0 disables the machine lock entirely
#   SUITE_LOCK_DIR     override the lock path (tests use their own sandbox);
#                      by default the path is keyed by SCAN ROOT, so a scoped
#                      subtree run does not queue behind a full-tree one
#   SUITE_LOCK_TTL     seconds after which a held lock is presumed abandoned
#                      (default 14400 = 4h) even if its pid still answers
#   SUITE_LOCK_WAIT    seconds to WAIT for a held lock instead of refusing on
#                      sight (default 0 = refuse immediately, the historical
#                      behaviour). While waiting the runner prints a repeating
#                      WAITING: line naming the current holder — see
#                      VISIBILITY below
#   SUITE_LOCK_WAIT_INTERVAL
#                      seconds between those WAITING: lines (default 60)
#   SUITE_ROTATE       1 (default): a budget-truncated run records the first
#                      suite it did not reach, so the NEXT run over the same
#                      scan root starts there and wraps to the top. The fixed
#                      sort order otherwise drops the SAME tail forever
#                      (HIMMEL-2243). 0 always starts at the top.
#   SUITE_ROTATE_STATE override the cursor path (the self-test uses its own
#                      sandbox); default
#                      $HOME/.himmel/himmel-shell-suite-<scan-slug>.cursor
#
# COVERAGE (HIMMEL-2243): the run budget above bounds an ORDINARY full run on
# this hardware, not just a runaway one — 397 suites are discovered, 381 run
# after SKIP_LIST, and the 2026-08-29 reference run spent its whole 7200s on
# real work while reaching only 174 of them. Because discovery is sorted, the
# other 207 were not a random sample: they were the same tail, every run,
# forever. SUITE_ROTATE makes a truncated run leave a cursor so the next run
# RESUMES from that tail and wraps, covering the whole ring across ~3 budget
# windows. It reorders, never filters — a run's suite set is untouched — and a
# truncated run still exits 1, so this makes the blind spot temporary without
# making a partial run look like a pass.
#
# bash 3.2-safe (macOS ships 3.2): no mapfile, no associative arrays.
set -uo pipefail

# REPO_ROOT is used only to source libs the runner itself needs; it is NOT
# used for discovery. Discovery uses $scan (the positional scan-root arg).
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$REPO_ROOT" || exit 1

# Captured HERE, before the (potentially hours-long) suite run below, not
# after it (HIMMEL-2383 CR finding codex-2, round 9): resolving it only at
# report-post time meant a worktree pruned out from under a still-running
# suite (merge-on-green.sh's HIMMEL-1970 prune, guarded by its own
# HIMMEL-2227 in-use check but not airtight against every timing) could
# turn "the head that was tested" into "unknown" — and the SHA this
# process actually ran the suites against never changes mid-run regardless.
REPORT_HEAD=$(git rev-parse HEAD 2>/dev/null || echo unknown)

# shellcheck source=../lib/proc-tree.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/proc-tree.sh"

# Pin git fsync/template settings for the throwaway repos the suites build, so
# the exports flow to EVERY suite subprocess the loop below spawns. Sourced here
# (not in each suite) so a single pin covers the whole tree; idempotent via its
# own marker, so a suite that re-sources the lib inherits without duplicating.
# shellcheck source=../lib/git-test-env.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/git-test-env.sh"

# _suite_num <name> <value> <default> — a POSITIVE integer, or the default with
# a warning. Every knob below feeds arithmetic or `sleep`, where a bad value
# does not fail loudly: SUITE_TIMEOUT=abc makes `sleep abc` complain and return
# immediately (no cap at all), and SUITE_RUN_BUDGET=08 dies as an invalid octal
# constant. Both disable a guard while looking configured, which is the failure
# mode this file exists to remove. `10#` forces base 10 so a zero-padded value
# is read as decimal rather than octal — the same fix critic-panel.sh applies
# to its own timeout knob.
#
# Zero is rejected, not accepted as "no limit". Every one of these knobs reads
# a 0 as "already expired": SUITE_LOCK_TTL=0 makes `age -ge 0` true for a lock
# created microseconds ago, so EVERY live lock is instantly reclaimable and the
# concurrency guard silently ceases to exist; SUITE_TIMEOUT=0 kills every suite
# on sight. A knob whose zero value disables the thing it configures is a
# footgun, so the only way to turn a guard off is the explicit switch
# (SUITE_LOCK=0), never a quiet 0 in a duration.
_suite_num() {
  local _v
  case "$2" in
    ''|*[!0-9]*)
      printf 'WARN: %s="%s" is not a positive integer — using %s\n' "$1" "$2" "$3" >&2
      printf '%s' "$3"
      return 0
      ;;
  esac
  _v=$(( 10#$2 ))
  if [ "$_v" -lt 1 ]; then
    printf 'WARN: %s="%s" must be >= 1 (0 would disable the guard it configures) — using %s\n' \
      "$1" "$2" "$3" >&2
    printf '%s' "$3"
    return 0
  fi
  printf '%s' "$_v"
}

# Per-suite wall-clock cap so a hung suite can't stall the whole job. An
# explicit value remains a global override; otherwise the small table below
# gives only measured slow suites more room while the default stays tight.
# Explicit means SUPPLIED AND VALID, not merely present. `${SUITE_TIMEOUT+x}`
# marks presence, so an empty / zero / non-numeric value used to count as an
# explicit global override while _suite_num quietly fell back to 600 -- pinning
# every slow suite to 600s and recreating the exact rc=124 failures this table
# exists to prevent (the 1363s identity suite would get 600s, not 1800s). A
# malformed knob must fall back to the path-specific defaults, matching the
# malformed-knob invariant _suite_num already implements.
SUITE_TIMEOUT_EXPLICIT=''
case "${SUITE_TIMEOUT:-}" in
  ''|*[!0-9]*) ;;                                        # unset, empty, or non-numeric
  *) [ "$SUITE_TIMEOUT" -ge 1 ] && SUITE_TIMEOUT_EXPLICIT=x ;;
esac
# HIMMEL-2233: 180s sat inside the noise band of real suites -- measured idle
# on 2026-08-29: scripts/cr/test-install-cr-gate.sh 112s,
# scripts/hooks/test-block-mcp-when-plugin-exists.sh 78s, and the suite that
# triggered the ticket is 152-165s idle. That left under 20% headroom, and any
# fleet load pushed them over, producing rc=124 rows that rendered
# indistinguishable from assertion failures. 600s matches the posture the
# per-suite table below already takes for two suites with the SAME idle
# profile -- test-graphify-fence.sh (157s idle) and test-lesson-write-fence.sh
# (143-172s idle) are both given 600s -- so the default now agrees with its
# own table instead of contradicting it. This is NOT the HIMMEL-2091
# load-aware approach: load-aware sizing was considered and rejected, because
# HIMMEL-2091's load-aware hook-chain budget was itself closed as SUPERSEDED
# in favour of static numbers (docs/internals/script-runtime-practices.md,
# "Chain budgets") -- a measured static default is the in-repo precedent, not
# a load multiplier. The runaway backstop is unchanged: SUITE_RUN_BUDGET
# (7200s) still bounds the whole run, and a genuinely hung suite is now
# labelled CAP EXCEEDED rather than mistaken for a failing assertion.
SUITE_TIMEOUT=$(_suite_num SUITE_TIMEOUT "${SUITE_TIMEOUT:-600}" 600)
_suite_timeout_for() {
  if [ -n "$SUITE_TIMEOUT_EXPLICIT" ]; then
    printf '%s' "$SUITE_TIMEOUT"
    return 0
  fi

  case "${1#./}" in
    scripts/handover/test-arm-resume-identity.sh|*/scripts/handover/test-arm-resume-identity.sh)
      # HIMMEL-2120 Task-6 fresh-boot idle benchmark (2026-08-27): new idle
      # 814s, rc=0 (reproduced at 802s, rc=0, same day). The prior 08-26 idle
      # row (636s) was an rc=1 failing run -- invalid as a timing baseline.
      # Ratio-preserved: 814 * (1800/636) = 2304, rounded up to 2350. Also
      # covers the worst observed loaded run (1992s, Task 0 under harness
      # load) with headroom.
      printf '2350' ;;
    scripts/test-check-ci.sh|*/scripts/test-check-ci.sh)
      # HIMMEL-1978. ~110 cases, each spawning dozens of gh-stub processes, so
      # it is the most load-sensitive suite here: measured 1009s on a swept box
      # under six concurrent workers, and HIMMEL-1953 clocked it at ~51 min
      # (3060s) on the same box before the /tmp sweep. It was in neither this
      # table nor SKIP_LIST, so the 180s default killed it rc=124 in every full
      # pass. 3600s covers the worst figure ever observed with headroom;
      # SUITE_RUN_BUDGET stays the runaway backstop.
      printf '3600' ;;
    scripts/test-propagate-public.sh|*/scripts/test-propagate-public.sh)
      # HIMMEL-2267. HIMMEL-2243's coverage-validation window B was killed by
      # the runner watchdog: "CAP EXCEEDED after 603s, cap 600s" -- a 3s
      # overshoot of the 600s default. A standalone re-run on this box
      # (overlord8, Git Bash, Windows 11) on 2026-08-30 finished healthy: rc=0
      # in 1761s, summary line PASS, 124 ok: lines, zero failures. That 1761s
      # was taken under moderate concurrent load.
      #
      # A second attempt at a clean idle figure was INVALIDATED, not red: it
      # aborted at 1423s, rc=128, when the machine's global core.hooksPath
      # tokensave watcher raced the suite's own `git add -A` ("unable to
      # index file '.tokensave/.branch-meta.json...tmp'" / "fatal: adding
      # files failed"). That is an environment defect, tracked separately as
      # HIMMEL-2281, not a suite defect -- noted explicitly so a future reader
      # does not mistake it for a red run.
      #
      # The 1423s partial and the 1761s complete run bracket the same place,
      # so load turned out to be noise for this suite: it lands around
      # 1700-1800s either way, making 1761s the honest figure rather than an
      # inflated one. No clean idle benchmark exists yet. 2700s is 1761 + ~50%
      # headroom. This is a LEAK-BARRIER suite (SUITE_CONDITIONAL, never
      # SKIP_LIST) that must keep running in full passes, so a false CAP
      # EXCEEDED is the exact failure class this entry deletes;
      # SUITE_RUN_BUDGET stays the runaway backstop.
      printf '2700' ;;
    scripts/ci/test-run-shell-tests.sh|*/scripts/ci/test-run-shell-tests.sh)
      # HIMMEL-2267. This is the runner's own self-test, and it grew past the
      # 600s default today: three separate changes landed in it (#2038's
      # W-cases, #2036, and HIMMEL-2260's Case 18, the last worth ~53s alone).
      # Measured standalone by the HIMMEL-2260 leg on 2026-08-30, 18:39-18:50:
      # 712s, rc=0, 104 PASS. That measurement was taken on 2260's own branch
      # and already includes its Case 18 additions, so it is current for
      # post-merge main. 712 * ~1.5 -> 1200s.
      printf '1200' ;;
    scripts/ci/test-suite-concurrency.sh|*/scripts/ci/test-suite-concurrency.sh)
      # HIMMEL-2267. New today (landed via #2038). It had been seen only as
      # "CAP EXCEEDED at 604s" in a scoped run -- a truncation floor, never a
      # completed measurement. Measured standalone TO COMPLETION by the
      # HIMMEL-2260 leg on 2026-08-30, 19:20:28-19:35:52: 924s, rc=0, 158
      # PASS, summary line "OK: all cases passed". That window overlapped
      # another suite run on this box (a test-propagate-public.sh
      # measurement), so 924s is a possibly-loaded / worst-observed figure,
      # not an idle benchmark. 1500s is ~62% headroom over 924s.
      printf '1500' ;;
    scripts/cr/test-clear-cr-marker.sh|*/scripts/cr/test-clear-cr-marker.sh)
      # HIMMEL-2401 loaded re-benchmark (2026-09-02): worst observed loaded
      # 854s (854s cited in the ticket, 844s reproduced here), against the
      # stale 850 cap derived from a 2026-08-27 idle benchmark whose headroom
      # the suite has since outgrown. Rule: loaded x2 -- 854 * 2 = 1708,
      # rounded up to 1750.
      printf '1750' ;;
    scripts/guardrails/test-graphify-fence.sh|*/scripts/guardrails/test-graphify-fence.sh)
      # HIMMEL-2120 Task-6 fresh-boot idle benchmark (2026-08-27): idle 157s.
      # Ratio-preserved: 157 * (600/161) = 586, rounded up to 600 -- unchanged.
      # Floor >= 344s (worst loaded run observed).
      printf '600' ;;
    scripts/guardrails/test-lesson-write-fence.sh|*/scripts/guardrails/test-lesson-write-fence.sh)
      # HIMMEL-2120 Task-6 fresh-boot idle benchmark (2026-08-27): idle
      # 143-172s. A fresh 2026-08-27 re-measure (HIMMEL-2169) agrees - idle
      # stays well under the SUITE_TIER_DEFAULT ">300s idle => extended" rule
      # below, so this suite correctly stays off that list (fast tier). The
      # old "measured 304s" comment here was a LOADED-box figure, not idle -
      # it is a different measurement entirely and is NOT compared against
      # the 300s idle rule; 600s keeps headroom for a loaded box, same
      # posture as the neighboring entries' timeout values.
      printf '600' ;;
    scripts/cr/test-critic-panel.sh|*/scripts/cr/test-critic-panel.sh)
      # HIMMEL-2401 loaded re-benchmark (2026-09-02): worst observed loaded
      # 846s (HIMMEL-2401 reported 454/454/455s on a lighter box; reproduced
      # at 846s here under 8 concurrent sessions), against the stale 450 cap
      # derived from a 2026-08-27 idle benchmark whose headroom the suite has
      # since outgrown (86 panel invocations today, up from the benchmark's
      # count). Rule: loaded x2 -- 846 * 2 = 1692, rounded up to 1700.
      printf '1700' ;;
    scripts/cr/test-critic-first-pass.sh|*/scripts/cr/test-critic-first-pass.sh)
      # HIMMEL-2069. ~50 CFP invocations, ~31 of them through the real
      # scripts/hermes/invoke.sh chokepoint (mktemp x4, a `set -m` watchdog
      # subshell, a `>(tee)` process substitution, an exec'd python3 stub) --
      # each one costs several seconds of pure MSYS process-spawn overhead, no
      # single case hangs. Verified by isolating the case that looked "stuck"
      # under a short bound and re-running it 25x standalone (every run
      # returned, ~10-15s each, no runaway trend) and by full-suite runs
      # bookended with `date`: completed at RC=0 in <900s once, in 1129s once,
      # and was still mid-run (not stuck, just slow) when a 900s bound killed
      # it rc=124 under concurrent load from other worktrees on the same box.
      # The previous default (180s) killed it rc=124 on every run, which reads
      # identically to a genuine hang -- that WAS the reported wedge symptom.
      # 3600s gives ~3x headroom over the worst completion actually observed.
      printf '3600' ;;
    scripts/handover/test-pr-merge.sh|*/scripts/handover/test-pr-merge.sh)
      # HIMMEL-2401/HIMMEL-2418 loaded re-benchmark (2026-09-02): the suite is
      # healthy (PASSES 49/0 every time) but was capped below its real
      # runtime by a stale 2026-08-27 idle benchmark. Worst observed loaded
      # 1071s (HIMMEL-2418, standalone under heavier load; 959s reproduced
      # here). Rule: loaded x2 -- 1071 * 2 = 2142, rounded up to 2150.
      printf '2150' ;;
    scripts/handover/test-auto-commit.sh|*/scripts/handover/test-auto-commit.sh)
      # HIMMEL-2401 loaded re-benchmark (2026-09-02): no dedicated entry
      # existed -- the generic 600s SUITE_TIMEOUT default was tripped
      # (CAP EXCEEDED after 606s, cap 600s, HIMMEL-2401 comment). Worst
      # observed loaded 606s (398s reproduced here on a lighter moment of the
      # same box). Rule: loaded x2 -- 606 * 2 = 1212, rounded up to 1250.
      printf '1250' ;;
    scripts/hooks/test-check-security-reviewed.sh|*/scripts/hooks/test-check-security-reviewed.sh)
      # HIMMEL-2401 loaded re-benchmark (2026-09-02): worst observed loaded
      # 743s, against the stale 500 cap derived from a 2026-08-27 idle
      # benchmark (238s). Rule: loaded x2 -- 743 * 2 = 1486, rounded up to
      # 1500.
      printf '1500' ;;
    scripts/graphify/test-refresh-graph-map.sh|*/scripts/graphify/test-refresh-graph-map.sh)
      printf '550' ;;  # measured 251s idle 2026-08-27 (rc=1 unrelated, HIMMEL-2160)
    scripts/hooks/test-guard-implementor-dispatch.sh|*/scripts/hooks/test-guard-implementor-dispatch.sh)
      # HIMMEL-2401 loaded re-benchmark (2026-09-02): worst observed loaded
      # 344s (155/0 passing, alone under 8 concurrent sessions), against the
      # stale 450 cap derived from a 2026-08-27 idle benchmark (204s). Rule:
      # loaded x2 -- 344 * 2 = 688, rounded up to 700.
      printf '700' ;;
    scripts/hooks/test-block-glm-external-writes.sh|*/scripts/hooks/test-block-glm-external-writes.sh)
      # HIMMEL-2401 loaded re-benchmark (2026-09-02): no dedicated entry
      # existed -- the generic 600s SUITE_TIMEOUT default was tripped
      # (CAP EXCEEDED after 606s, cap 600s, HIMMEL-2401 comment). Worst
      # observed loaded 1192s here. Rule: loaded x2 -- 1192 * 2 = 2384,
      # rounded up to 2400.
      printf '2400' ;;
    scripts/handover/test-arm-resume-queue-lock.sh|*/scripts/handover/test-arm-resume-queue-lock.sh)
      printf '650' ;;  # measured 307s idle 2026-08-27 (rc=1 was the HIMMEL-1329 ticket-mutex
      # false-positive fixed by HIMMEL-2165, not HIMMEL-1796 -- that ticket is about two
      # unrelated hook suites and never mentions queue-lock; the earlier citation here was wrong)
    *)
      printf '%s' "$SUITE_TIMEOUT" ;;
  esac
}
# Whole-run cap. A run that overruns this stops cleanly and reports, so an
# unattended session cannot leave one grinding for hours.
#
# Deliberately generous. This is a backstop against a runaway run, not a
# performance target: the nightly matrix runs this on a windows-latest runner
# where MSYS forks are slow and the job has no timeout-minutes of its own, so a
# tight default would turn a merely slow CI leg red. Lower it per-run when you
# want a tighter leash.
#
# HIMMEL-2243 corrects what this comment used to claim. "Two hours is
# implausible for a healthy run on any platform" was FALSE by the time it was
# written: the corpus is 397 discovered suites (381 runnable after SKIP_LIST)
# and a healthy full pass on the dev workstation needs roughly 15000s -- the
# 2026-08-29 reference run spent all 7200s on real work and finished only 174
# of the 381, and a 12024s run is on record from the 2026-08-28 shift. So the
# budget does NOT bound a runaway; on this hardware it bounds an ORDINARY run,
# and it always will on some box. Raising the number only moves the ceiling and
# makes every unattended run grind longer, so the number is unchanged and the
# COVERAGE consequence is fixed instead -- see SUITE_ROTATE below, which makes
# the truncated tail resume rather than repeat.
SUITE_RUN_BUDGET=$(_suite_num SUITE_RUN_BUDGET "${SUITE_RUN_BUDGET:-7200}" 7200)

# Resume rotation (HIMMEL-2243). The walk order is `sort`ed, hence FIXED, so a
# budget-truncated run drops the SAME tail every time: on the reference run
# that was 207 of 381 runnable suites -- everything from
# scripts/hooks/test-check-no-headless-gemini.sh onward, i.e. the whole of
# scripts/lib, scripts/luna, scripts/machine-setup, scripts/parity,
# scripts/statusline and scripts/upstreams -- permanently unexecuted rather
# than merely slow. The runtime was never the defect; the PERMANENCE was.
#
# So a truncated run records the first suite it did not reach, and the next run
# over the same scan root starts THERE and wraps around to the top. The set of
# suites a single run would execute is untouched -- this reorders, it never
# filters -- so nothing is narrowed to make the run "fit", which is the failure
# mode HIMMEL-2243 explicitly rated worse than the loud truncation. Successive
# runs therefore cover the whole ring (~3 budget windows here) instead of
# re-running the same front half forever, and a truncated run STILL exits 1
# (HIMMEL-1128): this makes the blind spot temporary, it does not make a
# partial run a pass.
#
# Inert until a run actually truncates: with no cursor on disk the order is
# byte-identical to the plain sort, so an untruncated box never sees this.
# The cursor is keyed by SCAN ROOT for the same reason the lock is, and lives
# under $HOME/.himmel (where the other cross-session ledgers live) rather than
# in TMPDIR, which tmp-sweep.sh clears -- a swept cursor would silently restore
# the permanent blind spot this exists to remove.
SUITE_ROTATE="${SUITE_ROTATE:-1}"

# Machine-wide lock over full-suite runs. A DIRECTORY, because mkdir is atomic
# on NTFS/Git-Bash without relying on O_EXCL semantics -- the same primitive
# scripts/handover/queue-lock.sh uses, and for the same reason.
#
# KEYED BY SCAN ROOT, so the refusal message's advice ("scope this run to the
# subtree you changed") is actually actionable — with one global lock it was
# not: a scoped run took the same lock and got the same refusal, which would
# have pushed people to SUITE_LOCK=0 and defeated the whole thing.
#
# The key is the scan root AS GIVEN — deliberately NOT its absolute path. The
# runs this bounds come from sessions in DIFFERENT worktrees, so keying on an
# absolute path would hand each worktree its own lock and bound nothing at
# all. Every default full-suite run resolves to "scripts" wherever it is
# launched from, which is exactly the set that must serialise.
SUITE_LOCK="${SUITE_LOCK:-1}"
SUITE_LOCK_TTL=$(_suite_num SUITE_LOCK_TTL "${SUITE_LOCK_TTL:-14400}" 14400)
# Resolved after arg parsing (it depends on $scan); an explicit env value is
# honoured verbatim, which is how the tests get their own sandboxed lock.
SUITE_LOCK_DIR="${SUITE_LOCK_DIR:-}"

# Optional wait budget over a HELD lock (HIMMEL-2215). Default 0 keeps the
# historical BEHAVIOUR: a held lock refuses on sight, same decision and same
# exit 2. Not byte-identical OUTPUT, though — the refusal gained three lines
# naming this knob as the way to queue instead, so a caller asserting on the
# exact refusal text sees them. With a
# budget set, the runner queues instead — and says so, repeatedly, so a queued
# leg is distinguishable from a parked one without forensics (that ambiguity,
# not the waiting, is what cost a coordinator a near-miss on 2026-08-29).
#
# This knob is a BUDGET, not a guard, so it cannot go through _suite_num,
# which rejects a 0 by design: here 0 is the meaningful OFF value, exactly as
# SUITE_LOCK=0 is for the lock itself. A malformed value falls back to 0 (no
# wait) rather than to an unbounded one — a typo must not silently convert a
# refusal into an hours-long block.
case "${SUITE_LOCK_WAIT:-0}" in
  ''|*[!0-9]*)
    printf 'WARN: SUITE_LOCK_WAIT="%s" is not a non-negative integer — using 0 (no wait)\n' \
      "${SUITE_LOCK_WAIT:-}" >&2
    SUITE_LOCK_WAIT=0
    ;;
  *)
    # All-digit is necessary but NOT sufficient. Bash arithmetic WRAPS past
    # intmax instead of failing (measured: 99999999999999999999 ->
    # 7766279631452241919 at rc=0; 9223372036854775808 -> negative), so a
    # fat-fingered digit run survives the test above and lands as an
    # effectively unbounded wait — the exact hours-long block this fallback
    # exists to prevent. Canonicalise (strip leading zeros) and require the
    # arithmetic result to round-trip: any wrap, in either direction, changes
    # the value and is caught here.
    #
    # A local default-guarded copy, not a bare $SUITE_LOCK_WAIT reference:
    # this script runs under `set -u`, and when SUITE_LOCK_WAIT is unset
    # entirely (not merely empty) the case selector's own "${SUITE_LOCK_WAIT:-0}"
    # default is what routed here — a later bare reference to the unset
    # variable itself still aborts the whole run.
    _slw_raw="${SUITE_LOCK_WAIT:-0}"
    _slw_canon="${_slw_raw#"${_slw_raw%%[!0]*}"}"
    [ -z "$_slw_canon" ] && _slw_canon=0
    _slw=$(( 10#$_slw_raw ))
    # 31536000 = 365 days. A wait budget beyond that is meaningless for a test
    # lock whose own TTL is four hours, and the ceiling is what makes the
    # round-trip check complete: a value near intmax round-trips fine, then
    # overflows `start + SUITE_LOCK_WAIT` into a NEGATIVE deadline, so the run
    # refuses instantly instead of waiting the requested time. Bounding the
    # input keeps every downstream sum far inside intmax.
    if [ "$_slw" != "$_slw_canon" ] || [ "$_slw" -gt 31536000 ]; then
      printf 'WARN: SUITE_LOCK_WAIT="%s" is out of range (max 31536000 = 365d) — using 0 (no wait)\n' \
        "$_slw_raw" >&2
      SUITE_LOCK_WAIT=0
    else
      SUITE_LOCK_WAIT="$_slw"
    fi
    unset _slw _slw_canon _slw_raw
    ;;
esac
# The interval DOES go through _suite_num: a 0 here would busy-spin the box
# this whole file exists to keep from being hammered, so its zero-rejection is
# exactly right.
SUITE_LOCK_WAIT_INTERVAL=$(_suite_num SUITE_LOCK_WAIT_INTERVAL "${SUITE_LOCK_WAIT_INTERVAL:-60}" 60)

# Suites that cannot run on a bare runner. One SCAN-ROOT-RELATIVE path per
# entry. Each: "<relpath>   # <reason>". Keep the reason — it documents the gap.
#
# CI policy (HIMMEL-594): CI runs UNIT tests only — no API keys, no secrets, no
# 3rd-party/network (claude / hermes / codex-OAuth / Jira-API). Suites needing
# those are INTEGRATION tests and belong on the VM e2e (host .env keys copied in,
# codex via OAuth), not here. The VM-e2e-with-keys harness + per-skill/plugin
# test reorg are tracked as a follow-up epic; until then these are skipped on CI.
#
# Entries are REPO-ROOT-relative ("scripts/handover/test-arm-resume.sh"), the
# same spelling SUITE_TIER_DEFAULT already uses, and are matched on a "/"
# boundary against each suite's FULL discovered path. Two properties follow,
# and both are asserted by Case 18 of the self-test (HIMMEL-2260):
#
#   Root-invariance — an entry holds its suite back identically in a full
#   `scripts` run, in a scoped `scripts/handover` run, and under any nested or
#   absolute spelling of either. Matching the SCAN-ROOT-relative path instead
#   is what made every directory-qualified entry inert under its own subtree.
#
#   No basename over-reach — writing the full path is what keeps a bare
#   `test-adopt.sh` from also matching some future `scripts/foo/test-adopt.sh`.
#   A suffix match on an under-qualified entry would silently skip an
#   unrelated suite, which is the same class of false evidence in the other
#   direction. Qualify every new entry the same way.
#
# See suite_entry_matches() for the predicate itself.
SKIP_LIST="
scripts/test-install-symmetry-vm.sh  # drives a real VM over SSH
scripts/test-luna-upgrade-vm.sh      # drives a real (Ubuntu or Windows) VM over SSH
scripts/test-himmel-update.sh        # live git pull + marketplace re-sync
scripts/test-himmel-update-hermes.sh  # needs the hermes runtime
scripts/hermes/test-invoke.sh        # needs the hermes runtime
scripts/gemini/test-invoke.sh        # needs the gemini-cli binary
scripts/cr/test-hermes-critic.sh     # integration: needs the hermes runtime (no keys on CI) — VM e2e covers it
scripts/handover/test-hop.sh         # integration: needs a live 'claude' (--print relaunch) — VM e2e covers it
scripts/handover/test-resume-armed.sh  # integration: needs the bun runtime + armed-resume flow — VM e2e covers it
scripts/handover/test-arm-resume.sh  # timing-heavy Windows scheduler lifecycle suite: measured 2775s standalone-green (637/0/1, HIMMEL-2254) against the runner's 600s per-suite default (600s since HIMMEL-2233, not the 180s this entry used to cite); runnable individually, no VM e2e coverage
scripts/luna/test-pipeline-cadence.sh  # integration: drives a live 'claude' (--settings fragment) — VM e2e covers it
scripts/statusline/test-usage-fetch-scheduled.sh  # needs network + OAuth credential; GATE probe run manually (HIMMEL-1841)
scripts/test-plugin-test.sh          # integration: self-bootstraps a plugin's deps over npm/network — VM e2e covers it
scripts/test-adopt.sh                # timing-heavy full adoption matrix exceeds the hermetic runner's per-suite cap on Windows (600s default since HIMMEL-2233; the exceedance was last measured against the older 180s cap and has not been re-measured); runnable individually, no VM e2e coverage
scripts/handover/test-arm-resume-probe.sh  # MEASUREMENT tool, not an assertion suite — times a dry-run/real arm and reports python3 spawn counts; always exits 0, so collecting it would spend ~20s per full run to assert nothing (HIMMEL-2125)
scripts/test-check-ci-forks-probe.sh  # MEASUREMENT tool, not an assertion suite — re-runs the full test-check-ci.sh suite instrumented to report gh-stub fork counts + wall time per case; always exits 0 and duplicates the suite's own run, so collecting it would double the extended-tier cost to assert nothing (HIMMEL-2169)
"

# Conditional suites (HIMMEL-1589). Unlike SKIP_LIST (always skipped), a
# conditional suite runs by default and is only held back when --changed-since
# is active AND no changed path matches its ERE. One entry per line:
#   <repo-root-relative suite path>  <ERE over repo-relative changed paths>  # <reason>
# The ERE is matched (grep -E, unanchored unless you anchor it) against each
# repo-relative changed path from `git diff --name-only <ref>` + untracked.
# test-propagate-public.sh is a LEAK-BARRIER suite: it must NOT move into
# SKIP_LIST (that would drop it from every full run); it is conditional instead,
# so a change unrelated to the propagation path skips it under --changed-since
# while a full run still always exercises it.
SUITE_CONDITIONAL="
scripts/test-propagate-public.sh  ^scripts/(propagate-public|lib/public-clone-paths|test-propagate-public)\.sh$  # leak-barrier suite; only the propagation path can break it
"

# Tier suites (HIMMEL-2120). A declarative corpus-reduction table, distinct
# from SKIP_LIST (never runs here) and SUITE_CONDITIONAL (change-scoped): a
# suite listed here as "extended" is heavier/slower work that belongs in a
# nightly or pre-release pass, not every per-PR/agent invocation. One entry
# per line:
#   <repo-root-relative suite path>  extended  # <reason>
# SUITE_TIER_MODE (env) selects which tier(s) run: unset or "all" runs every
# suite regardless of tier (byte-identical to no filter at all — the safe
# default); "fast" runs everything NOT listed here, loud-skipping the
# extended-listed suites; "extended" runs ONLY the listed suites, loud-
# skipping everything else. Any other value is a loud misconfiguration, not a
# silent fallback to "all" — exit 2 immediately.
# Entries assigned by HIMMEL-2120 Task 6 from the 2026-08-27 fresh-boot serial
# idle benchmark (rule: new post-reduction idle > 300s => extended).
# Env-overridable (SUITE_TIER), same seam as SUITE_REQUIRE_TOOL below, so the
# self-test can drive fast/extended deterministically without touching the
# production table.
SUITE_TIER_DEFAULT="
scripts/test-check-ci.sh  extended  # measured 559s idle 2026-08-27 (>300s rule)
scripts/handover/test-arm-resume-identity.sh  extended  # measured 814s idle 2026-08-27, 802s repro (>300s rule)
scripts/handover/test-arm-resume-queue-lock.sh  extended  # measured 307s idle 2026-08-27 (>300s rule)
"
SUITE_TIER="${SUITE_TIER:-$SUITE_TIER_DEFAULT}"
SUITE_TIER_MODE="${SUITE_TIER_MODE:-all}"
case "$SUITE_TIER_MODE" in
  fast|extended|all) ;;
  *)
    printf 'ERROR: SUITE_TIER_MODE="%s" is invalid — must be fast, extended, or all.\n' \
      "$SUITE_TIER_MODE" >&2
    exit 2
    ;;
esac

# Capability-conditional suites (HIMMEL-1792). Neither table above can say
# "runs exactly where the host has the tool": SKIP_LIST is a NEVER, which made
# the pwsh smoke suite dead weight on every host that HAS pwsh — reproducing
# the never-executed blind spot the suite exists to close — and SUITE_CONDITIONAL
# keys on changed paths, not host capabilities. One entry per line:
#   <repo-root-relative suite path>  <tool>  # <reason>
# The suite RUNS wherever <tool> is on PATH; where it is not, the runner
# [SKIP]s it loudly with this reason — a runner-level [SKIP] line is the only
# skip surface visible in a green full run, because a PASSED suite's own stdout
# is captured to a log and discarded. The suite's own runtime guard stays as
# the second layer for direct invocation (belt and braces, HIMMEL-1788).
# Env-overridable (SUITE_REQUIRE_TOOL) so the self-test can drive the skip
# branch deterministically on hosts that DO have the tool.
SUITE_REQUIRE_TOOL_DEFAULT="
scripts/test-claude-openrouter-pwsh.sh  pwsh  # PowerShell twin smoke suite for claude-openrouter.ps1 (HIMMEL-1792); runs wherever pwsh exists, loud-skips where it does not
scripts/lib/test-native-auth-pin-pwsh.sh  pwsh  # PowerShell twin suite for native-auth-pin.ps1 (HIMMEL-1867); runs wherever pwsh exists, loud-skips where it does not
scripts/telegram/test-glm-guard-parity.sh  bun  # cross-language phi-egress-lib.sh/glm-guard.ts parity check (HIMMEL-2204); runs wherever bun exists, loud-skips where it does not
"
SUITE_REQUIRE_TOOL="${SUITE_REQUIRE_TOOL:-$SUITE_REQUIRE_TOOL_DEFAULT}"

# extra_skips accumulates paths added via --skip-extra flags.
# Each entry is a newline-terminated scan-root-relative path.
extra_skips=""

# --------------------------------------------------------------------------
# suite_entry_matches <table-entry> <suite-path>
#
# The one path-matching predicate every suite table shares (HIMMEL-2260).
# Returns 0 when the entry designates that suite.
#
# Table entries are written repo-root-relative
# ("scripts/handover/test-arm-resume.sh"), but the scan root is a RUNTIME
# choice: a scoped run of scripts/handover discovers that same suite with a
# scan-root-relative path of "test-arm-resume.sh". Matching entries against THAT made
# every directory-qualified entry inert under its own subtree -- the runner ran
# suites the ledger says can never run here, and a scoped scan's evidence was
# red-washed by them (measured: 2254's scoped scripts/handover scan executed
# the SKIP_LISTed handover/test-arm-resume.sh to CAP EXCEEDED). Every table
# below had the defect; SUITE_TIER only escaped it by hand-rolling a
# bidirectional version of this predicate inline.
#
# Matching the full path is what makes the verdict root-invariant: the scan
# root only ever contributes a PREFIX to it, so a suffix match ignores it --
# full, scoped, nested, relative, "./"-spelled, trailing-slashed and absolute
# scan roots all agree. The caller passes the suite under the RESOLVED (symlink-
# free) scan root rather than the spelling typed on the command line, which is
# what extends that agreement to a root reached through a symlink or junction:
# such a root makes `find` drop the "scripts/" component the entry carries, and
# the entry would otherwise miss. The "/" boundary is what keeps it honest:
# "scripts/test-adopt.sh" matches ".../scripts/test-adopt.sh" and never
# ".../scripts/pre-test-adopt.sh" or ".../scripts/test-adopt.sh.bak".
#
# The boundary bounds the match; it does NOT make an under-qualified entry
# safe. A bare "test-adopt.sh" would match EVERY nested suite with that
# basename -- silently skipping an unrelated one. That is why the tables spell
# their entries out in full; the predicate cannot recover specificity the
# entry never carried. EVERY built-in table follows that rule -- SKIP_LIST,
# SUITE_CONDITIONAL, SUITE_TIER and SUITE_REQUIRE_TOOL all spell their entries
# repo-root-relative, so a namesake under another directory can never inherit
# another suite's conditional rule or tool gate. `--skip-extra` does not use
# this predicate AT ALL -- it is scan-root-relative by definition and compares
# exactly; see is_skipped.
#
# BOTH occurrences of the entry are QUOTED inside the case patterns, and that
# is load-bearing, not style: an unquoted expansion in a case pattern is
# GLOB-expanded, so a table entry of `*` would turn into a wildcard that skips
# the entire corpus and reports it as a clean green run. Quoting makes the
# entry match literally; only the leading `*` stays a wildcard, which is the
# prefix-tolerance this predicate is for. Case 18f asserts it through
# SUITE_TIER -- a table that really does route through here. (It used to cite
# `--skip-extra '*'`, which stopped being true when --skip-extra got its own
# exact comparison above: that probe would pass no matter what this predicate
# did. Case 18f2 covers --skip-extra's own literalness separately.)
# --------------------------------------------------------------------------
suite_entry_matches() {
  case "$2" in
    "$1"|*"/$1") return 0 ;;
  esac
  return 1
}

# --------------------------------------------------------------------------
# is_skipped <suite-key> <relpath>
# Returns 0 (true = skip) and prints the reason; returns 1 (false = run).
#
# TWO arguments because the two skip sources are anchored differently, and
# collapsing them is a silent widening (HIMMEL-2260):
#
#   SKIP_LIST   is a repo-wide ledger whose entries must mean the same thing
#               under every scan root, so it matches <suite-key> -- the suite
#               under the RESOLVED scan root -- via suite_entry_matches.
#   extra_skips (--skip-extra) is documented as SCAN-ROOT-RELATIVE and is
#               supplied per run by a caller who just named that scan root.
#               It compares EXACTLY against <relpath>. Routing it through the
#               suffix matcher would make `--skip-extra test.sh` skip every
#               nested suite with that basename instead of only
#               <scan-root>/test.sh -- omitting unrelated tests from a run the
#               caller believed it had scoped precisely.
# --------------------------------------------------------------------------
is_skipped() {
  local needle="$1" relneedle="$2"
  local _line _path
  while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    _path=${_line%%#*}
    _path=$(printf '%s' "$_path" | tr -d '[:space:]')
    [ -n "$_path" ] || continue
    if suite_entry_matches "$_path" "$needle"; then
      printf '%s' "${_line#*# }"
      return 0
    fi
  done <<EOF
$SKIP_LIST
EOF
  # Also check extra_skips (no inline reason; just the path).
  if [ -n "$extra_skips" ]; then
    while IFS= read -r _path; do
      [ -n "$_path" ] || continue
      if [ "$_path" = "$relneedle" ]; then
        printf '%s' "skipped via --skip-extra"
        return 0
      fi
    done <<EOF2
$extra_skips
EOF2
  fi
  return 1
}

# --------------------------------------------------------------------------
# Conditional-suite helpers (HIMMEL-1589). See SUITE_CONDITIONAL above. These
# are inert unless --changed-since resolved a changed set (conditional_filter_active=1).
# --------------------------------------------------------------------------

# conditional_ere <suite-path> -> echoes the ERE for that suite and returns 0;
# returns 1 when the suite is not in SUITE_CONDITIONAL. Parses one table line
# "<relpath>  <ERE>  # <reason>" via `read` (bash 3.2-safe; collapses the
# whitespace between the fields and strips the trailing comment).
conditional_ere() {
  local needle="$1" _line _path _ere
  while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    _line=${_line%%#*}                 # drop trailing "# reason" -> "<relpath>  <ERE>"
    read -r _path _ere <<< "$_line"    # first token = suite path, rest = ERE
    [ -n "$_path" ] || continue
    if suite_entry_matches "$_path" "$needle"; then
      printf '%s' "$_ere"
      return 0
    fi
  done <<EOF
$SUITE_CONDITIONAL
EOF
  return 1
}

# conditional_matches <ERE> -> 0 if any path in the global $changed_set matches
# the ERE, 1 otherwise. Here-string (not a pipeline) so a grep -q match can't
# take SIGPIPE under `set -o pipefail` — the same trap grepq elsewhere documents.
conditional_matches() {
  local ere="$1" _p
  while IFS= read -r _p; do
    [ -n "$_p" ] || continue
    if grep -Eq "$ere" <<< "$_p"; then
      return 0
    fi
  done <<EOF
$changed_set
EOF
  return 1
}

# --------------------------------------------------------------------------
# Tier helpers (HIMMEL-2120). See SUITE_TIER above.
# --------------------------------------------------------------------------

# tier_lookup <suite-path> — returns 0 when the suite is listed in SUITE_TIER
# (currently always tier "extended" — the grammar carries a value column for
# forward compat) and sets _tier_reason; returns 1 when unlisted. Same
# table-parse shape as capability_lookup: two tokens before the comment
# (path + tier value), so the whitespace-stripped path alone would glue them
# into a key that never matches. An unrecognized tier value is a malformed
# table entry, not a suite to silently run as extended — same fail-loud
# convention as the SUITE_TIER_MODE case above: exit 2 immediately.
#
# Matching is suite_entry_matches, like every other table (HIMMEL-2260). This
# lookup used to hand-roll a bidirectional version of it against the scan-root-
# relative path, because the production table's entries are repo-root-relative
# ("scripts/handover/...") while the old caller passed a path missing that
# prefix -- an exact-only match NEVER hit for any listed suite, in a full scan
# OR a subtree one (verified: SUITE_TIER_MODE=fast on a default full scan ran
# all three extended-listed suites instead of skipping them). The caller now
# passes the full discovered path, so the shared predicate covers both entry
# spellings and the hand-rolled arms are gone. A miss must stay impossible for
# listed suites, since it fails open to the fast tier.
tier_lookup() {
  _tier_value=''
  _tier_reason=''
  local needle="$1" _line _path
  while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    read -r _path _tier_value <<< "${_line%%#*}"
    [ -n "$_path" ] || continue
    case "$_tier_value" in
      extended) ;;
      *)
        printf 'ERROR: SUITE_TIER entry for "%s" has unknown tier "%s" — must be extended.\n' \
          "$_path" "$_tier_value" >&2
        exit 2
        ;;
    esac
    suite_entry_matches "$_path" "$needle" || continue
    _tier_reason=${_line#*# }
    return 0
  done <<EOF
$SUITE_TIER
EOF
  return 1
}

# --------------------------------------------------------------------------
# Capability-conditional helpers (HIMMEL-1792). See SUITE_REQUIRE_TOOL above.
# --------------------------------------------------------------------------

# capability_lookup <suite-path> — sets _cap_tool/_cap_reason when the suite is
# listed in SUITE_REQUIRE_TOOL and returns 0; returns 1 when it is not. The
# globals (not locals — the caller reads them) follow the table-parse shape of
# conditional_ere, EXCEPT the path is the first `read` TOKEN, not the
# whitespace-stripped pre-comment text: this table carries TWO tokens before
# the comment (path + tool), and stripping whitespace wholesale would glue
# them into a key that never matches. Everything after "# " is the reason for
# the loud [SKIP] line.
capability_lookup() {
  _cap_tool=''
  _cap_reason=''
  local needle="$1" _line _path
  while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    read -r _path _cap_tool <<< "${_line%%#*}"
    [ -n "$_path" ] || continue
    if suite_entry_matches "$_path" "$needle"; then
      _cap_reason=${_line#*# }
      return 0
    fi
  done <<EOF
$SUITE_REQUIRE_TOOL
EOF
  return 1
}

# --------------------------------------------------------------------------
# Machine-wide lock over full-suite runs (HIMMEL-1338).
#
# Only the EXECUTION path takes it: `--list` reads the tree and runs nothing,
# so making it queue behind a live run would be friction with no payoff.
#
# RE-ENTRANCY is not optional. scripts/ci/test-run-shell-tests.sh invokes this
# runner fifteen times, and the full suite runs that test — so a lock that did
# not recognise its own descendants would deadlock the very suite it protects.
# The holder exports HIMMEL_SUITE_LOCK_HELD with the lock path it owns; a
# nested invocation targeting that same path passes through. Comparing the
# PATH rather than a bare "am I nested" flag keeps a nested run that was
# pointed at a DIFFERENT lock (the regression test does exactly this) honest —
# it still has to acquire.
# --------------------------------------------------------------------------
suite_lock_owned=0

# When 1, suite_lock_acquire suppresses its multi-line REFUSED block (and only
# that block — NOTE: and RECLAIM ERROR: lines still print). Set by the wait
# loop for its silent retries: with a wait budget in effect a held lock is the
# EXPECTED state, not a refusal, and printing the full verdict once a minute
# would bury the heartbeat it exists to make visible. The final attempt is
# always loud, so a run that genuinely gives up still emits the full verdict.
suite_lock_quiet=0

# Set by suite_lock_acquire when its refusal is PERMANENT — a safety refusal
# that retrying cannot clear (a symlinked lock path, a directory that is not a
# lock, a failed reclaim) as opposed to the ordinary "someone else holds it"
# refusal, which is exactly what waiting is for. The wait loop reads it to stop
# burning a budget on a condition no amount of waiting resolves; without it a
# mis-set SUITE_LOCK_DIR spends the whole SUITE_LOCK_WAIT emitting heartbeats
# that claim a holder which does not exist.
suite_lock_permanent=0

# bash already knows the hostname; shelling out for it costs a fork and, on
# Windows, can stall on a name lookup. `hostname` stays as the last resort for
# a shell that set neither variable.
_suite_lock_host() {
  printf '%s' "${HOSTNAME:-${COMPUTERNAME:-$(hostname 2>/dev/null || echo unknown)}}"
}

# _suite_lock_same_host <owner-host> <this-host> — 0 when the two strings
# name the same machine, judged case-insensitively. Hostnames are
# case-insensitive in every namespace that can name this box (DNS, NetBIOS,
# Windows), and the sources _suite_lock_host draws from DISAGREE in case on
# Windows: bash's own HOSTNAME=overlord8 vs the COMPUTERNAME=OVERLORD8
# fallback. An inherited or differently-cased HOSTNAME (it survives into
# child bash) made the strict compare silently skip the liveness probe for a
# same-MACHINE holder, which then refused its provably-dead pid until the TTL
# (HIMMEL-1805). Folding case does not reach a foreign host: a different name
# still mismatches, and the pid probe stays skipped for it by design. The
# this-host string is a PARAMETER, not a fresh resolution: the caller captured
# it once for everything downstream, and a second resolution here could
# disagree with that capture mid-judgement.
_suite_lock_same_host() {
  [ "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" = \
    "$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" ]
}

# _suite_lock_probe_pid <pid> — classify a `kill -0` liveness probe without
# over-reading it. rc 0: the pid answered, which proves it EXISTS — never
# that it is still the original holder (pids recycle). rc 1: the probe was
# refused with the one refusal that proves the pid is gone — ESRCH, "No such
# process". rc 2: refused for any OTHER reason, EPERM being the canonical
# one — a LIVE holder this account may not signal (run under another user or
# a service account) — and a probe whose failure has more than one possible
# cause distinguishes nothing, so the caller must treat the holder as UNKNOWN
# and let it fall through to the TTL rather than reclaim it (HIMMEL-1805
# round 4: reading every failure as ESRCH took a live foreign-account
# holder's lock — a fail-OPEN, where every other defect in this arc merely
# withheld a warning). bash cannot read errno; ESRCH is recognised by the
# shell's own error text, and any other wording — including a localized one —
# lands in UNKNOWN, the safe direction.
_suite_lock_probe_pid() {
  local _err='' _rc=0
  _err=$(kill -0 "$1" 2>&1) || _rc=$?
  [ "$_rc" -eq 0 ] && return 0
  case "$_err" in
    *"No such process"*) return 1 ;;
    *) return 2 ;;
  esac
}

# _suite_lock_drop — remove a lock directory, deleting NOTHING until the
# directory has been proven to be one.
#
# SUITE_LOCK_DIR is env-overridable, so every delete here is aimed by a
# variable a typo can point anywhere. Leaning on `rmdir` to refuse a non-empty
# directory is not enough on its own: the `owner` file is unlinked FIRST, so a
# mis-set path at a real directory that happens to contain a file of that name
# loses it before rmdir ever gets a say — the guard fires after the damage.
#
# The invariant is checked up front instead: a lock this script created holds
# exactly one entry, named `owner`. A directory holding anything else is not
# ours, so nothing in it is touched and the caller refuses. Returns non-zero
# when the directory was not dropped, for either reason.
_suite_lock_drop() {
  local _f
  # A symlink is never a lock this script made. Globbing through one inspects
  # the TARGET while `rm` writes through it, so every content check above would
  # be answered by one directory and acted on in another.
  [ -L "$1" ] && return 1
  for _f in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    if [ -e "$_f" ] || [ -L "$_f" ]; then
      case "$_f" in
        "$1"/owner) ;;
        *) return 1 ;;
      esac
    fi
  done
  rm -f "$1/owner" 2>/dev/null
  rmdir "$1" 2>/dev/null
}

# _suite_lock_dir_empty <dir> — 0 when the directory holds nothing at all.
# Globs, not `ls`: parsing ls output is unsafe, and this needs no forks.
_suite_lock_dir_empty() {
  local _f
  for _f in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    # Spelled out rather than `[ … ] || [ … ] && return 1`: that parses
    # correctly by left-associativity, but it reads as a conditional-return and
    # is a well-known way to introduce a bug during a later edit.
    if [ -e "$_f" ] || [ -L "$_f" ]; then
      return 1
    fi
  done
  return 0
}

# _suite_lock_owner_raw <dir> — the whole owner file, or "" when absent. The
# CAS token for a takeover: comparing the full generation catches a lock that
# changed hands between judging it and acting on that judgement.
_suite_lock_owner_raw() {
  cat "$1/owner" 2>/dev/null || printf ''
}

# _suite_lock_wait_brand <dir> — 0 when an owner file exists in <dir>, giving
# a racer that just won a mkdir the same brand window the first-arrival path
# already grants before judging it. The mkdir is not a reliable mutex
# everywhere (uutils resolves two concurrent mkdirs to BOTH rc=0, HIMMEL-966),
# so "mkdir failed / brand failed" is not a verdict until the winner has had
# its moment to brand: classifying before the window closes reads a live
# winner as an operational failure (HIMMEL-1805 round 5).
_suite_lock_wait_brand() {
  local _s=0
  while [ ! -f "$1/owner" ] && [ "$_s" -lt 20 ]; do
    sleep 0.05
    _s=$((_s + 1))
  done
  [ -f "$1/owner" ]
}

# _suite_lock_reclaim <expected-owner-raw> — take over a lock judged abandoned.
#
# Dropping-then-claiming is NOT safe on its own, and the comment that used to
# sit here ("exactly one mkdir wins the reopened race") was wrong. Two runs
# that both judge the same lock stale interleave like this:
#
#   A: drop → mkdir → brand          B: (already decided stale) drop
#
# B's drop removes A's FRESH brand and then rmdir's A's now-empty directory,
# so B claims too and both believe they hold the lock — the lock admitting
# exactly the concurrency it exists to prevent.
#
# So the right to take over is itself an exclusive resource, claimed with the
# one primitive that is atomic here: mkdir. This mirrors the takeover protocol
# in scripts/handover/queue-lock.sh, which arrived at the same design after
# the same class of race (and after finding `mv` unreliable on MSYS).
#
#   1. mkdir <lock>.claim — exactly one contender wins the right to take over.
#   2. CAS re-verify UNDER the claim: the lock's owner must still be the
#      generation we judged. Anything else means it changed hands while we
#      deliberated — it is LIVE, so abort rather than destroy it.
#   3. Only then drop and re-acquire.
#
# Returns 0 when this process now holds the lock. Returns 1 for CONFIRMED
# contention only — another taker holds a fresh claim, the CAS caught the
# lock changing hands under the judgement, or a failed mkdir / brand /
# re-acquire was answered by a live winner's owner file at that moment (the
# check, not the return code, is the evidence: every one of those steps has
# more than one failure cause, and reading the code alone asserted "operational"
# for three ordinary races — HIMMEL-1805 round 5) — the one failure a retry
# can legitimately hope to clear. Returns 2 for an OPERATIONAL failure (an
# invariant refusal, or an I/O error where NO winner could be shown to exist),
# after printing the concrete reason to stderr prefixed RECLAIM ERROR: the
# caller must not relabel those as a race, or an unattended job retries forever
# on advice that never applied (HIMMEL-1805 round 4).
_suite_lock_reclaim() {
  local expected="$1" claim="${SUITE_LOCK_DIR}.claim" rc=1 c_started c_age

  if ! mkdir "$claim" 2>/dev/null; then
    # A crashed taker must not wedge takeovers forever. The claim is branded
    # immediately after its mkdir, so give that a moment before judging —
    # otherwise a legitimate taker gets clobbered inside its own brand window.
    local _cs=0
    while [ ! -f "$claim/owner" ] && [ "$_cs" -lt 20 ]; do
      sleep 0.05
      _cs=$((_cs + 1))
    done
    c_started=$(_suite_lock_owner_field "$claim/owner" started)
    c_age=-1
    case "$c_started" in
      ''|*[!0-9]*) ;;
      *) c_age=$(( $(date +%s) - 10#$c_started )) ;;
    esac
    # A claim is only honoured when it can be shown to be FRESH. Anything else
    # — no owner file at all, an unparseable timestamp, or simply old — is
    # abandoned and gets cleared.
    #
    # "Cannot be dated, so treat it as live" is the wrong default HERE, and
    # this is the same mistake the lock directory already had fixed one level
    # up: an unbranded husk left by a crash in the microsecond window between
    # mkdir and brand would otherwise block every future takeover of this lock
    # forever, with no path back except a human deleting a directory in /tmp.
    # A claim is held for milliseconds by construction, so failing open here
    # costs a rare double-takeover; failing closed costs the guard entirely.
    if [ "$c_age" -ge 0 ] && [ "$c_age" -lt 120 ]; then
      return 1
    fi
    printf 'NOTE: clearing a stranded takeover claim (age %ss) at %s\n' "$c_age" "$claim" >&2
    if ! _suite_lock_drop "$claim"; then
      printf 'RECLAIM ERROR: could not clear the stranded takeover claim at %s\n' "$claim" >&2
      return 2
    fi
    if ! mkdir "$claim" 2>/dev/null; then
      # The freed slot was taken between the drop and this mkdir: a branded
      # claim EXISTS, which is contention, not an operational failure.
      if _suite_lock_wait_brand "$claim"; then
        return 1
      fi
      printf 'RECLAIM ERROR: could not create a takeover claim at %s\n' "$claim" >&2
      return 2
    fi
  fi
  # Brand the claim so its age is readable and a co-winner of a non-atomic
  # mkdir (uutils, HIMMEL-966) loses here instead. Losing that brand to the
  # co-winner is exactly the race the sentence above anticipates — an owner
  # file already present means a LIVE claim, so it is contention (the claim
  # is the co-winner's and is left alone), not an operational failure.
  if ! ( set -C; printf 'pid=%s\nstarted=%s\n' "$$" "$(date +%s)" > "$claim/owner" ) 2>/dev/null; then
    if [ -f "$claim/owner" ]; then
      return 1
    fi
    rmdir "$claim" 2>/dev/null
    printf 'RECLAIM ERROR: could not brand the takeover claim at %s\n' "$claim" >&2
    return 2
  fi

  if [ "$(_suite_lock_owner_raw "$SUITE_LOCK_DIR")" = "$expected" ]; then
    if _suite_lock_drop "$SUITE_LOCK_DIR"; then
      if _suite_lock_claim; then
        rc=0
      elif _suite_lock_wait_brand "$SUITE_LOCK_DIR"; then
        # The freed lock was won by a normal acquirer in the drop-to-reclaim
        # gap: a branded owner EXISTS, which is contention, not an
        # operational failure.
        rc=1
      else
        printf 'RECLAIM ERROR: dropped the abandoned lock at %s but could not re-acquire it\n' \
          "$SUITE_LOCK_DIR" >&2
        rc=2
      fi
    else
      printf 'RECLAIM ERROR: %s holds more than a lone owner file — not a suite lock; refusing to delete it\n' \
        "$SUITE_LOCK_DIR" >&2
      rc=2
    fi
  fi

  _suite_lock_drop "$claim"
  return "$rc"
}

_suite_lock_owner_field() {
  # $1 file, $2 key -> value (empty when absent). No forks: read builtin.
  local _k _v
  while IFS='=' read -r _k _v; do
    if [ "$_k" = "$2" ]; then
      printf '%s' "$_v"
      return 0
    fi
  done < "$1" 2>/dev/null
  return 0
}

# _suite_lock_claim — mkdir the lock dir and brand it. Prints nothing.
# Returns 0 only when THIS process is the branded owner.
_suite_lock_claim() {
  mkdir "$SUITE_LOCK_DIR" 2>/dev/null || return 1
  # mkdir is not a reliable mutex everywhere: uutils coreutils 0.8.0 resolves
  # two concurrent mkdir of the same path to BOTH rc=0 (HIMMEL-966). So the
  # owner-file create is the real arbiter — `set -C` makes it a single
  # open(O_CREAT|O_EXCL) performed by bash itself, atomic on every POSIX fs.
  if ! ( set -C; printf 'pid=%s\nhost=%s\nstarted=%s\nscan=%s\n' \
      "$$" "$(_suite_lock_host)" "$(date +%s)" "$scan" \
      > "$SUITE_LOCK_DIR/owner" ) 2>/dev/null; then
    # No winner branded at all = an IO/permission failure, not a lost race;
    # rmdir (never rm -rf) is race-safe — it refuses a dir a racer has since
    # branded — so a genuine loser leaves the winner's lock intact.
    [ -e "$SUITE_LOCK_DIR/owner" ] || rmdir "$SUITE_LOCK_DIR" 2>/dev/null
    return 1
  fi
  suite_lock_owned=1
  export HIMMEL_SUITE_LOCK_HELD="$SUITE_LOCK_DIR"
  return 0
}

# suite_lock_acquire — 0 to proceed, 1 to refuse (caller exits 2).
suite_lock_acquire() {
  suite_lock_permanent=0
  [ "$SUITE_LOCK" = "0" ] && return 0
  [ "${HIMMEL_SUITE_LOCK_HELD:-}" = "$SUITE_LOCK_DIR" ] && return 0

  # Validate the path ONCE, here, before any code path below can delete inside
  # it. Successive reviews kept finding new shapes of the same bug — a lock
  # path that is not a lock, reached through a different branch — so the class
  # is closed at the entrance rather than patched per branch. A symlink is the
  # sharpest case: every content check inspects the TARGET while every write
  # goes through the link, so the thing examined and the thing modified are
  # different directories. This script only ever creates real directories, so
  # a symlink here is always a mis-set override.
  if [ -L "$SUITE_LOCK_DIR" ]; then
    {
      printf 'REFUSED: %s is a symlink — the suite lock must be a real directory.\n' \
        "$SUITE_LOCK_DIR"
      printf '  Refusing to touch it, because what gets checked and what gets written would differ. Check SUITE_LOCK_DIR.\n'
    } >&2
    suite_lock_permanent=1
    return 1
  fi

  mkdir -p "$(dirname "$SUITE_LOCK_DIR")" 2>/dev/null
  _suite_lock_claim && return 0

  # Lost the mkdir — but the winner brands the dir in a separate step, so a
  # loser arriving inside that window sees a lock with no owner yet. Give it a
  # moment before concluding anything.
  local _spin=0
  while [ ! -f "$SUITE_LOCK_DIR/owner" ] && [ "$_spin" -lt 20 ]; do
    sleep 0.05
    _spin=$((_spin + 1))
  done
  # Still nothing: a crash between the mkdir and the brand left a husk. This
  # is an ADVISORY lock over test scheduling, not a data-integrity lock, so it
  # fails OPEN with a loud trail — refusing every future run until a human
  # notices a stray directory in /tmp would be a worse outage than the
  # contention it exists to prevent.
  if [ ! -f "$SUITE_LOCK_DIR/owner" ]; then
    # A non-empty directory with no owner file is not a lock husk — it is
    # whatever SUITE_LOCK_DIR was mis-pointed at. Say so before going near it.
    if ! _suite_lock_dir_empty "$SUITE_LOCK_DIR"; then
      {
        printf 'REFUSED: %s exists, has no owner file, and is NOT empty — this does not look like a suite lock.\n' \
          "$SUITE_LOCK_DIR"
        printf '  Refusing to touch it. Check SUITE_LOCK_DIR; remove the directory yourself if it really is a stale lock.\n'
      } >&2
      suite_lock_permanent=1
      return 1
    fi
    # Expected generation is "no owner file" — the CAS re-check inside
    # _suite_lock_reclaim fails if anyone branded it while we spun above.
    if _suite_lock_reclaim ""; then
      printf 'NOTE: cleared an unbranded suite lock (no owner file) at %s\n' \
        "$SUITE_LOCK_DIR" >&2
      return 0
    fi
  fi

  # ONE raw read; every field below AND the takeover's CAS check derive from
  # this single generation, so the staleness judgement and the act on it can
  # never straddle a concurrent rewrite.
  local o_raw o_pid o_host o_started now age=-1 dated=0
  o_raw=$(_suite_lock_owner_raw "$SUITE_LOCK_DIR")
  o_pid=$(_suite_lock_owner_field "$SUITE_LOCK_DIR/owner" pid)
  # Invalid owner metadata is no pid at all: never probe it, and let an undated
  # lock follow the same abandoned path as one whose pid is missing.
  case "$o_pid" in *[!0-9]*) o_pid='' ;; esac
  o_host=$(_suite_lock_owner_field "$SUITE_LOCK_DIR/owner" host)
  o_started=$(_suite_lock_owner_field "$SUITE_LOCK_DIR/owner" started)
  now=$(date +%s)
  case "$o_started" in
    ''|*[!0-9]*) ;;
    *) age=$(( now - 10#$o_started )); dated=1 ;;
  esac
  # An undated owner has age=-1, which is a sentinel, not a duration. Print it
  # as "unknown" rather than "-1s" — a negative age reads as a measurement and
  # invites TTL arithmetic that can never come true (HIMMEL-1805 round 6).
  local age_disp="unknown"
  [ "$dated" -eq 1 ] && age_disp="${age}s"

  # Two independent staleness signals, because neither alone is sound. A pid
  # whose probe was refused with ESRCH is a crashed run — but pids get
  # recycled, so an answering pid is not proof of life, and kill -0 is
  # refused for EPERM as well (a live holder under another account), so ONLY
  # the ESRCH refusal may be read as death; the TTL is the backstop for a
  # recycled pid, a refused probe, and a lock left by a host that is not
  # this one.
  #
  # pid_present records WHICH of those we are in — the probe answered, which
  # proves the pid EXISTS, never that it is the original holder — so the
  # refusal below can say exactly that instead of guessing: the original one
  # blanket message counselled "wait for it" at a holder that was provably
  # dead (HIMMEL-1805), and the first verdict shipped for it overclaimed in
  # the other direction ("ALIVE") on a probe that cannot show identity.
  # pid_unknown is the third outcome: the probe was refused for a reason
  # other than "no such process", which proves nothing either way.
  local stale=0 this_host same_host=0 pid_present=0 pid_unknown=0 lost_race=0 reclaim_failed=0 probe_rc
  this_host=$(_suite_lock_host)
  if _suite_lock_same_host "$o_host" "$this_host"; then same_host=1; fi
  if [ -n "$o_pid" ] && [ "$same_host" -eq 1 ]; then
    probe_rc=0
    _suite_lock_probe_pid "$o_pid" || probe_rc=$?
    case "$probe_rc" in
      0) pid_present=1 ;;
      1) stale=1 ;;
      *) pid_unknown=1 ;;
    esac
  fi
  [ "$age" -ge "$SUITE_LOCK_TTL" ] && stale=1
  # A lock we could neither date nor probe is abandoned, not held: a foreign
  # host whose `started` is missing or corrupt, or any owner carrying no pid at
  # all. Neither signal above can show it fresh, so — same policy as the
  # takeover claim a level up, where an undated owner is treated as abandoned —
  # it gets cleared. Without this, a foreign-hosted lock with an unparseable
  # timestamp is unreclaimable forever: the pid probe is skipped by design on a
  # foreign host, and age=-1 can never exceed the TTL. A genuinely held lock is
  # safe here — a live pid on this host, or a datable timestamp inside the TTL,
  # already cleared the bar above.
  if [ "$dated" -eq 0 ]; then
    [ -z "$o_pid" ] && stale=1
    [ "$same_host" -eq 0 ] && stale=1
  fi

  if [ "$stale" -eq 1 ]; then
    # Guarded by the takeover claim + a CAS on the generation we just judged.
    # rc 1 (someone else got the freed slot, or the lock turned out to be
    # live after all) is an ordinary refusal; rc 2 is an operational failure
    # with its concrete reason already printed.
    local reclaim_rc=0
    _suite_lock_reclaim "$o_raw" || reclaim_rc=$?
    if [ "$reclaim_rc" -eq 0 ]; then
      printf 'NOTE: cleared an abandoned suite lock (pid=%s host=%s age=%s) at %s\n' \
        "${o_pid:-?}" "${o_host:-?}" "$age_disp" "$SUITE_LOCK_DIR" >&2
      return 0
    fi
    if [ "$reclaim_rc" -eq 1 ]; then
      # A lost race means the generation read above — and every field derived
      # from it — is KNOWN stale: the CAS exists precisely to catch a lock
      # changing hands under a judgement, and it just did (HIMMEL-1805). The
      # refusal must not present that snapshot as the current holder, nor
      # counsel TTL arithmetic out of an age that no longer describes anything.
      lost_race=1
    else
      # An OPERATIONAL failure, not confirmed contention: a directory that is
      # not a lock, a permission or I/O error — and no live winner could be
      # shown at the moment of the failure. Reporting this as a race would
      # counsel "re-run in a moment" at a condition re-running cannot clear
      # (HIMMEL-1805 round 4); but the classification is a CHECK, not proof —
      # a winner branding a moment after the check is invisible to it — so the
      # refusal below says what to VERIFY before touching anything, never what
      # to delete (HIMMEL-1805 round 5).
      reclaim_failed=1
      suite_lock_permanent=1
    fi
  fi

  if [ "$suite_lock_quiet" -eq 0 ]; then
  {
    if [ "$reclaim_failed" -eq 1 ]; then
      printf 'REFUSED: could not take over the machine lock of scan root "%s" — the reclaim failed.\n' \
        "$scan"
      printf '  lock: %s\n' "$SUITE_LOCK_DIR"
      printf '  Concurrent runs test the same tree and starve each other (HIMMEL-1338).\n'
      printf '  RECLAIM FAILED: this lock was judged abandoned, but taking it over did\n'
      printf '  not succeed and no live winner could be shown for it at that moment\n'
      printf '  (the concrete reason is printed above, prefixed RECLAIM ERROR: a\n'
      printf '  directory that is not a lock, a permission or an I/O error). That\n'
      printf '  READS like an operational failure rather than a race — but the check\n'
      printf '  that found no winner cannot exclude one arriving a moment later, so\n'
      printf '  treat this as what was observed, not proven. Re-running will not\n'
      printf '  clear an operational failure. If manual intervention seems needed,\n'
      printf '  verify FIRST that no live holder exists — read the owner file in the\n'
      printf '  lock above, confirm its pid is not running on its host and its age is\n'
      printf '  past the %ss TTL — and only a lock that fails every one of those\n' "$SUITE_LOCK_TTL"
      printf '  checks is safe to remove by hand.\n'
    elif [ "$lost_race" -eq 1 ]; then
      printf 'REFUSED: lost the race to take over the machine lock of scan root "%s".\n' "$scan"
      printf '  lock: %s\n' "$SUITE_LOCK_DIR"
      printf '  Concurrent runs test the same tree and starve each other (HIMMEL-1338).\n'
      printf '  TAKEOVER IN PROGRESS: this run judged the lock abandoned (last observed\n'
      printf '  pid=%s host=%s age=%s), but the takeover lost the race — another run\n' \
        "${o_pid:-unknown}" "${o_host:-unknown}" "$age_disp"
      printf '  claimed the lock, or the holder released it mid-flight. That snapshot is\n'
      printf '  what was OBSERVED, not the current holder, so no TTL is quoted from it.\n'
      printf '  Nothing is wedged — an ordinary race: re-run in a moment and it re-reads\n'
      printf '  the lock as it is then.\n'
    else
      printf 'REFUSED: another run of scan root "%s" holds the machine lock (pid=%s host=%s age=%s).\n' \
        "$scan" "${o_pid:-unknown}" "${o_host:-unknown}" "$age_disp"
      printf '  lock: %s\n' "$SUITE_LOCK_DIR"
      printf '  Concurrent runs test the same tree and starve each other (HIMMEL-1338).\n'
      # Say WHICH case this is (HIMMEL-1805). One message used to cover a live
      # holder and an unverifiable one, so its "wait for it" advice was wrong
      # half the time — counselling up to four hours of waiting for a corpse,
      # with nothing in the output to tell the two apart (a nightly cadence saw
      # only an unexplained rc=2). The PRESENT verdict deliberately stops
      # short of "alive": kill -0 proves the pid exists, and pids recycle.
      if [ "$pid_present" -eq 1 ]; then
        printf '  Holder PID PRESENT (identity unverified): pid %s answered a liveness probe\n' \
          "$o_pid"
        printf '  on this host (this host=%s). kill -0 proves the pid exists, not that it\n' "$this_host"
        printf '  is still the original holder — pids recycle; the TTL backstop covers\n'
        printf '  that case. Wait for it to finish.\n'
      else
        printf '  Holder UNVERIFIABLE from here (this host=%s): ' "$this_host"
        if [ "$pid_unknown" -eq 1 ]; then
          printf 'the liveness probe of\n'
          printf '  pid %s was refused for a reason other than "no such process" — commonly\n' "$o_pid"
          printf '  EPERM, a live holder this account may not signal (run under another\n'
          printf '  user or a service account). A refused probe does not show the holder\n'
          printf '  is gone, so the lock is honoured, not reclaimed.\n'
        elif [ "$same_host" -eq 1 ]; then
          printf 'the owner records no pid, so there is nothing to probe.\n'
        else
          printf 'the holder is on a different host, and a pid from\n'
          printf '  another machine says nothing about liveness here — the probe is skipped\n'
          printf '  by design for a foreign host.\n'
        fi
        if [ "$dated" -eq 1 ]; then
          printf '  The TTL backstop reclaims this lock at age %ss (now %ss).\n' \
            "$SUITE_LOCK_TTL" "$age"
        else
          printf '  The owner file records no usable "started" timestamp, so the %ss TTL\n' "$SUITE_LOCK_TTL"
          printf '  backstop cannot fire for it — its age is unknown, not zero. Inspect the\n'
          printf '  owner file in the lock above.\n'
        fi
      fi
    fi
    printf '  To run now rather than behind this lock, scope this run to the subtree you\n'
    printf '  changed — the lock is keyed by scan root, so e.g. "%s/<subdir>" takes a\n' "$scan"
    printf '  different lock. SUITE_LOCK=0 opts out entirely. To QUEUE for it instead of\n'
    printf '  refusing, set SUITE_LOCK_WAIT=<seconds>: the run then waits, reporting this\n'
    printf '  holder every SUITE_LOCK_WAIT_INTERVAL seconds (default 60) so the wait is\n'
    printf '  visible in the log rather than silent.\n'
  } >&2
  fi
  return 1
}

# _suite_lock_dur <seconds> — a duration a human reads at a glance AND a test
# can parse. Both forms, always: "2h14m" is what a coordinator scanning a log
# actually needs (the 2026-08-29 hold was reported as "held 100+ minutes now"
# by eye), while the raw seconds keep the line greppable and lossless.
_suite_lock_dur() {
  local _s="$1"
  if [ "$_s" -ge 3600 ]; then
    printf '%dh%02dm (%ss)' "$(( _s / 3600 ))" "$(( (_s % 3600) / 60 ))" "$_s"
  elif [ "$_s" -ge 60 ]; then
    printf '%dm%02ds (%ss)' "$(( _s / 60 ))" "$(( _s % 60 ))" "$_s"
  else
    printf '%ss' "$_s"
  fi
}

# _suite_lock_report_wait <waited-seconds> — ONE line, repeated every interval,
# naming the holder as it is RIGHT NOW.
#
# The owner file is re-read on every call rather than captured once: over a
# two-hour wait the lock can change hands, and a heartbeat still naming the
# original pid would be worse than no heartbeat — it would be confidently
# wrong about the one fact a coordinator acts on. An owner file that has just
# vanished (the holder released between our attempt and this read) reports
# "unknown" rather than inventing a value; the next attempt acquires anyway.
_suite_lock_report_wait() {
  local o_raw o_pid='' o_host='' o_started='' held='unknown' _k _v
  # ONE read of the owner file, parsed into all three fields — the same
  # single-generation discipline suite_lock_acquire states for its own read.
  # Three separate reads can straddle a handoff and pair one holder's pid with
  # another's start time, and the pid is the single fact a coordinator acts on:
  # a mixed line is confidently wrong exactly where being wrong costs the most
  # (nudging a healthy worker, the near-miss this ticket exists to prevent).
  # Re-reading per CALL is still deliberate — a lock that changes hands between
  # heartbeats must show the NEW holder; what must not happen is a single line
  # describing two of them.
  o_raw=$(_suite_lock_owner_raw "$SUITE_LOCK_DIR")
  while IFS='=' read -r _k _v; do
    case "$_k" in
      pid) o_pid="$_v" ;;
      host) o_host="$_v" ;;
      started) o_started="$_v" ;;
    esac
  done <<< "$o_raw"
  case "$o_started" in
    ''|*[!0-9]*) ;;
    *) held=$(_suite_lock_dur "$(( $(date +%s) - 10#$o_started ))") ;;
  esac
  printf 'WAITING: queued behind the machine lock of scan root "%s" — holder pid=%s host=%s held=%s; this run has waited %s of its %ss budget. lock: %s\n' \
    "$scan" "${o_pid:-unknown}" "${o_host:-unknown}" "$held" \
    "$(_suite_lock_dur "$1")" "$SUITE_LOCK_WAIT" "$SUITE_LOCK_DIR" >&2
}

# suite_lock_acquire_waiting — suite_lock_acquire, plus the optional
# SUITE_LOCK_WAIT budget (HIMMEL-2215). 0 to proceed, 1 to refuse.
#
# Every attempt is the UNMODIFIED suite_lock_acquire, so the whole staleness /
# CAS / takeover protocol is byte-identical to a non-waiting run — this adds a
# retry cadence and a heartbeat, never a second way to obtain the lock. With
# no budget it is a straight pass-through, which is why the default costs
# existing callers nothing.
#
# The retries are quiet and the LAST attempt is loud, deliberately: a refusal
# printed at the start of a wait describes a holder that may be long gone by
# the time anyone reads it, so the verdict that survives in the log is the one
# taken against the lock as it is when the budget runs out.
suite_lock_acquire_waiting() {
  [ "$SUITE_LOCK_WAIT" -le 0 ] && { suite_lock_acquire; return $?; }

  local start now waited=0 deadline nap _slw_remaining
  start=$(date +%s)
  deadline=$(( start + SUITE_LOCK_WAIT ))

  suite_lock_quiet=1
  while :; do
    if suite_lock_acquire; then
      suite_lock_quiet=0
      # Measure at the moment of ACQUISITION, not at the last failure. `waited`
      # is otherwise assigned only on the failure path below — i.e. BEFORE the
      # sleep — so it is stale by up to one interval here, and it is 0 outright
      # when the first attempt failed inside the same wall-clock second the run
      # started. That 0 silently suppressed this whole message via the guard
      # below, closing the log on silence for a run that had genuinely waited.
      waited=$(( $(date +%s) - start ))
      [ "$waited" -gt 0 ] && \
        printf 'ACQUIRED: got the machine lock of scan root "%s" after waiting %s.\n' \
          "$scan" "$(_suite_lock_dur "$waited")" >&2
      return 0
    fi
    now=$(date +%s)
    waited=$(( now - start ))
    if [ "$suite_lock_permanent" -eq 1 ]; then
      # Not a queue — a safety refusal no amount of waiting clears. Break out
      # and let the final loud attempt print the real verdict, instead of
      # spending the budget on heartbeats naming a holder that does not exist.
      break
    fi
    [ "$now" -ge "$deadline" ] && break
    _suite_lock_report_wait "$waited"
    # Never sleep past the deadline: a long interval must not turn a 90s
    # budget into a 60s-granular one that overshoots by most of a minute.
    #
    # Clamp against the REMAINING budget rather than testing `now + nap`.
    # The sum was the bug: SUITE_LOCK_WAIT_INTERVAL has no upper bound, and a
    # near-intmax value made `now + nap` wrap NEGATIVE, which is not greater
    # than the deadline — so the clamp was skipped and `sleep` got the
    # near-intmax value, blocking far past the budget the clamp exists to
    # enforce. `deadline - now` cannot overflow (SUITE_LOCK_WAIT is capped at
    # 31536000 above), so this form needs no ceiling on the interval at all:
    # an over-large interval simply clamps to what is left.
    nap="$SUITE_LOCK_WAIT_INTERVAL"
    _slw_remaining=$(( deadline - now ))
    [ "$nap" -gt "$_slw_remaining" ] && nap="$_slw_remaining"
    sleep "$nap"
  done

  suite_lock_quiet=0
  if suite_lock_acquire; then
    # The lock freed in the instant between the last polled attempt and this
    # one. It is still an acquisition after a wait, so it closes the log the
    # same way the in-loop path does — a run that waited and then succeeded
    # must never end on silence. Same fresh measurement as the in-loop path:
    # the carried value is the one taken at the last failure.
    waited=$(( $(date +%s) - start ))
    printf 'ACQUIRED: got the machine lock of scan root "%s" after waiting %s.\n' \
      "$scan" "$(_suite_lock_dur "$waited")" >&2
    return 0
  fi
  if [ "$suite_lock_permanent" -eq 1 ]; then
    printf 'NOT QUEUED: the refusal above is a safety refusal, not a held lock — waiting cannot clear it, so the %ss SUITE_LOCK_WAIT budget was not spent.\n' \
      "$SUITE_LOCK_WAIT" >&2
  else
    printf 'GAVE UP: waited %s for the machine lock of scan root "%s" and it is still held; refusing (the verdict above describes the lock as it is now).\n' \
      "$(_suite_lock_dur "$waited")" "$scan" >&2
  fi
  return 1
}

# COMPARE, then delete. "I acquired this once" is not the same claim as "I hold
# it now": a run that overruns the TTL gets reclaimed by another run, which
# rm -rf's this dir and creates its OWN. An unconditional release would then
# delete the successor's live lock on our way out and let a third run in
# alongside it — the exact concurrency this file exists to prevent, caused by
# the lock's own cleanup. queue-lock.sh refuses a token-less release for the
# same reason. Re-read the owner and only remove a lock still branded with our
# pid on this host.
#
# Residual (accepted, microseconds): a reclaim landing between the read and
# the rm. An owner file we cannot read leaves the dir alone — the next
# acquire treats an unbranded lock as abandoned and clears it immediately, so
# nothing wedges.
# Invoked from the EXIT trap, which shellcheck cannot see as a call site.
# SC2329 is the newer spelling of the same false positive (never-invoked
# function); both are needed or a shellcheck upgrade re-breaks the push gate on
# any change to this file (HIMMEL-1805).
# shellcheck disable=SC2317,SC2329
suite_lock_release() {
  [ "$suite_lock_owned" -eq 1 ] || return 0
  [ -f "$SUITE_LOCK_DIR/owner" ] || return 0
  local r_pid r_host
  r_pid=$(_suite_lock_owner_field "$SUITE_LOCK_DIR/owner" pid)
  r_host=$(_suite_lock_owner_field "$SUITE_LOCK_DIR/owner" host)
  if [ "$r_pid" != "$$" ] || [ "$r_host" != "$(_suite_lock_host)" ]; then
    printf 'NOTE: not releasing %s — it was taken over (now pid=%s host=%s); leaving the current holder alone\n' \
      "$SUITE_LOCK_DIR" "${r_pid:-?}" "${r_host:-?}" >&2
    return 0
  fi
  _suite_lock_drop "$SUITE_LOCK_DIR"
}

# --------------------------------------------------------------------------
# Arg parsing — single-pass, position-independent:
#   --list               set list-mode
#   --skip-extra <val>   append to extra_skips
#   --changed-since <ref> enable the conditional-suite filter against <ref>
#   --pr <N>             post the SUMMARY block as a PR comment (HIMMEL-2383)
#   first non-flag       scan-root (default: scripts)
# --------------------------------------------------------------------------
list_only=0
scan=""
# OPT-IN conditional filter (HIMMEL-1589). Env is the default; the flag overrides.
changed_since="${SUITE_CHANGED_SINCE:-}"
# OPT-IN after-report PR comment (HIMMEL-2383). Env is the default; the flag
# overrides. Never default-on and never posted without one of these set.
report_pr="${SUITE_REPORT_PR:-}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --list)
      list_only=1
      shift
      ;;
    --skip-extra)
      if [ "$#" -lt 2 ]; then
        echo "run-shell-tests.sh: --skip-extra requires an argument" >&2
        exit 1
      fi
      extra_skips="${extra_skips}${2}
"
      shift 2
      ;;
    --changed-since)
      if [ "$#" -lt 2 ]; then
        echo "run-shell-tests.sh: --changed-since requires an argument" >&2
        exit 1
      fi
      changed_since="$2"
      shift 2
      ;;
    --pr)
      # Reject an option-looking or non-numeric value (HIMMEL-2383 CR
      # finding codex-2, round 6) — without this, `--pr --list` silently
      # CONSUMES --list as the PR number (never applying it) and later
      # passes the literal string "--list" to `gh pr comment`.
      case "${2:-}" in
        ''|0|-*|*[!0-9]*)
          # '0' is explicitly rejected too (HIMMEL-2383 CR finding
          # codex-3, round 9) — GitHub PR numbers start at 1.
          echo "run-shell-tests.sh: --pr requires a PR number argument, got '${2:-<missing>}'" >&2
          exit 1
          ;;
      esac
      report_pr="$2"
      shift 2
      ;;
    -*)
      echo "run-shell-tests.sh: unknown flag: $1" >&2
      exit 1
      ;;
    *)
      if [ -z "$scan" ]; then
        scan="$1"
      else
        echo "run-shell-tests.sh: unexpected argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

# Validate report_pr uniformly, regardless of source (HIMMEL-2383 CR
# finding codex-2, round 7): the --pr FLAG path validates its value inline,
# but SUITE_REPORT_PR sets report_pr's default before that loop even
# starts and never passes through it, so a malformed/option-looking env
# value would reach `gh pr comment` unvalidated. One check, both sources.
case "$report_pr" in
  ''|0|-*|*[!0-9]*)
    if [ -n "$report_pr" ]; then
      echo "run-shell-tests.sh: --pr/SUITE_REPORT_PR must be a PR number, got '$report_pr'" >&2
      exit 1
    fi
    ;;
esac

# Apply default scan root after parsing so a leading --list doesn't collide.
scan="${scan%/}"      # strip any trailing slash so the relpath prefix-strip works
scan="${scan:-scripts}"

# Physical (symlink-resolved) form of the scan root, resolved ONCE (HIMMEL-2260).
# Suite tables are matched against a path built from this, not from the spelling
# the caller typed, so the verdict cannot depend on HOW the same directory was
# named. Without it a scan root reached through a symlink or junction -- e.g. a
# repo-root "handover" link into scripts/handover -- makes `find` report
# "handover/test-arm-resume.sh", which drops the "scripts/" component the table
# entry carries, and the listed suite RUNS. That is the same silent-skip-failure
# the rest of this ticket closes, reached by a different spelling.
# Falls back to the literal scan root if the cd fails; discovery below reports
# the real error, so this must not exit here.
scan_resolved=$(cd "$scan" 2>/dev/null && pwd -P) || scan_resolved=""
[ -n "$scan_resolved" ] || scan_resolved="$scan"

# HIMMEL-2517 — the scan root can be DELETED while this run is live, and the
# loop below does not notice: every `bash "$suite"` against a vanished path
# exits 127, is counted as an ordinary failure, and the run renders a full FAIL
# tally that looks exactly like a catastrophic regression. Measured twice on
# 2026-09-05 (PRs #2133, #2134): `merge-on-green.sh` pruned the worktree these
# runs were executing inside, giving PASS 6 / SKIP 19 / FAIL 422 with 421 of the
# 422 failures at rc=127. Because --pr posts the SUMMARY from THIS process
# (HIMMEL-2383), the only thing that kept that artifact off the PR was `gh`
# failing too — for the same reason.
#
# So the run re-stats its own root at the two moments where a stale answer
# turns into a durable wrong one: after acquiring the lock (a queued run can
# have waited hours, which is precisely the window that widened the race) and
# again before the SUMMARY is written or posted. A vanished root is never a
# tally: it aborts, non-zero, saying what happened.
#
# $scan_resolved, not $scan: a relative spelling is resolved against a cwd that
# may itself be inside the deleted tree, where every path answer is meaningless.
#
# Existence alone is NOT the right question (round-1 CR finding codex-2): a tree
# that is pruned and then RECREATED at the same pathname — which is exactly what
# merge-on-green's own gutted-tree recovery recipe tells an operator to do, and
# what `git worktree add` does — passes a `-d` test while being a different
# checkout. The run would then publish, against the head it started with, a
# tally measured partly in one tree and partly in another. So the root's
# IDENTITY is pinned at start and re-checked alongside existence.
#
# Identity here is DEVICE + INODE, not inode alone (round-2 CR finding codex-1):
# an inode number is filesystem-local, so the bare number compares equal across a
# remount or a different mount presenting the same path. `stat` is the only tool
# that reports the device, and its formatting flag differs by userland, so both
# spellings are tried — GNU `-c` (Linux, Git Bash) then BSD `-f` (macOS).
#
# The residual, stated rather than glossed: within ONE filesystem an inode number
# is reusable, so a delete-and-recreate that happens to be handed the same inode
# still compares equal. Closing THAT needs a content fence over the tree, which is
# HIMMEL-2448's hash-fence and not this ticket. What matters here is the
# direction of the imperfection — this check only ever ADDS aborts to the plain
# existence test it replaced, and never removes one.
#
# Identity is a STRENGTHENING, never a new failure mode: if the id cannot be read
# at start or at check time (no `stat`, an unreadable parent), the check degrades
# to the existence test it always was rather than aborting on a value it lacks.
scan_root_identity() {
  stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1" 2>/dev/null || printf ''
}
scan_root_id=$(scan_root_identity "$scan_resolved")

scan_root_abort_if_vanished() {
  local _now
  if [ ! -d "$scan_resolved" ]; then
    printf 'ABORTED: scan root vanished (%s)\n' "$scan_resolved" >&2
    printf '  It existed when this run started and does not now — most likely the worktree was pruned underneath it (HIMMEL-2517).\n' >&2
    printf '  Refusing to print a FAIL tally or post an after-report: every suite path is gone, so any count would measure the deletion, not the tests.\n' >&2
    exit 3
  fi
  [ -n "$scan_root_id" ] || return 0
  _now=$(scan_root_identity "$scan_resolved")
  [ -n "$_now" ] || return 0
  [ "$_now" = "$scan_root_id" ] && return 0
  printf 'ABORTED: scan root replaced (%s)\n' "$scan_resolved" >&2
  printf '  A directory still exists at that path, but it is not the one this run started in (device:inode %s, now %s) — the tree was removed and recreated, or remounted, underneath it (HIMMEL-2517).\n' "$scan_root_id" "$_now" >&2
  printf '  Refusing to print a FAIL tally or post an after-report: the suites were measured across two different checkouts, so no tally describes either.\n' >&2
  exit 3
}

# Slug of the scan root, shared by the lock path and the rotation cursor
# (HIMMEL-2243) so both key on the same tree.
# "./scripts" and "scripts" are the same tree, so normalise the leading "./"
# before slugging or they would take two different locks and neither would
# serialise against the other.
_scan_key="${scan#./}"
# Fold "/" to "__" BEFORE collapsing the rest to "-", so the common case —
# two different subtree paths — cannot slug alike: without it "a/b" and "a-b"
# both became "a-b" and two unrelated scoped runs would share a lock.
#
# Residual, accepted: "a/b" still collides with a literal "a__b", the same
# theoretical-only caveat scripts/handover/queue-lock.sh documents for its
# own slug. It is also the SAFE direction for THIS lock — a collision
# over-serialises two runs, it never lets two runs both hold the lock. That
# tolerance is lock-specific: the rotation cursor below cannot accept the
# same collision and derives its own, different key (see there).
_scan_key=$(printf '%s' "$_scan_key" | sed 's#/#__#g' | tr -c 'A-Za-z0-9_-' '-')

# Derive the scan-keyed lock path now that $scan is known (an explicit
# SUITE_LOCK_DIR wins).
if [ -z "$SUITE_LOCK_DIR" ]; then
  SUITE_LOCK_DIR="${TMPDIR:-/tmp}/himmel-shell-suite-${_scan_key}.lock"
fi

# Rotation cursor path (HIMMEL-2243). Scan-keyed like the lock, for the same
# reason: the runs that must share it come from DIFFERENT worktrees over the
# same tree. It lives under $HOME/.himmel — where the other cross-session
# ledgers live — and deliberately NOT in TMPDIR, which scripts/ci/tmp-sweep.sh
# clears: a swept cursor would silently restore the permanent blind spot this
# exists to remove. An explicit SUITE_ROTATE_STATE wins, which is how the
# self-test drives a sandbox and never touches the real one.
#
# The cursor key deliberately DIVERGES from the lock's _scan_key ENCODING,
# while keeping the same INPUT (the scan root as given, "./" stripped) so
# worktrees still share one cursor. _scan_key's "/" -> "__" fold is lossy:
# "a/b" and a literal "a__b" slug alike (accepted above for the LOCK, where
# a collision only over-serialises two runs — it never lets two runs both
# hold it). For the CURSOR that same collision is destructive: a completed
# run over one root would clear or overwrite a different root's resume
# point, silently restoring the exact blind spot this branch removes. So
# the cursor key keeps _scan_key only as a human-readable prefix and
# appends a short hash of the normalised scan-root text — never the slug
# itself (would inherit the collision), never the absolute path (would
# break worktree sharing) — so two distinct roots can no longer collide.
_scan_hash=""
if command -v sha256sum >/dev/null 2>&1; then
  _scan_hash=$(printf '%s' "${scan#./}" | sha256sum | cut -c1-12)
elif command -v sha1sum >/dev/null 2>&1; then
  _scan_hash=$(printf '%s' "${scan#./}" | sha1sum | cut -c1-12)
elif command -v md5sum >/dev/null 2>&1; then
  _scan_hash=$(printf '%s' "${scan#./}" | md5sum | cut -c1-12)
elif command -v cksum >/dev/null 2>&1; then
  # cksum is POSIX-mandated and should exist even on a minimal image that
  # lacks the stronger sha*/md5 tools, so it is the last-resort fallback
  # rather than a hard failure. Its output is a decimal checksum, not hex,
  # but it is still enough to tell "a/b" and "a__b" apart.
  _scan_hash=$(printf '%s' "${scan#./}" | cksum | cut -d' ' -f1)
fi
if [ -z "$_scan_hash" ]; then
  # No hash tool at all (not even cksum) — fail SAFE and LOUD: keep
  # rotation working with the plain lossy slug rather than disabling it
  # outright, but say so, since the collision this hash exists to prevent
  # is back in play.
  echo "run-shell-tests.sh: no hash tool found (sha256sum/sha1sum/md5sum/cksum); rotation cursor key may collide across scan roots" >&2
  _cursor_key="$_scan_key"
else
  _cursor_key="${_scan_key}-${_scan_hash}"
fi
#
# HOME unset must DISABLE rotation, not degrade into a shared top-level path.
# A bare $HOME reference under `set -u` aborts the ENTIRE runner with
# "unbound variable" on any host that merely lacks a home directory (a bare
# container runner — exactly where this suite is meant to run), so ${HOME:-}
# is required just to keep the runner alive. But ${HOME:-} alone is NOT
# enough: with HOME empty, "$HOME/.himmel/..." collapses to "/.himmel/...",
# rooted at the filesystem root — and running as root (an ordinary CI
# container), `mkdir -p /.himmel` SUCCEEDS. That would silently create a
# top-level state directory shared across every user on the host instead of
# degrading, which is worse than the abort it replaces. So when HOME is
# empty, no path is synthesised at all: SUITE_ROTATE_STATE stays whatever an
# explicit env override supplied (still honoured, via ${SUITE_ROTATE_STATE:-})
# or empty — and every use site below treats an empty value as "rotation
# unavailable" rather than ever building a path out of it. Losing rotation
# must never cost you the run.
if [ -n "${HOME:-}" ]; then
  SUITE_ROTATE_STATE="${SUITE_ROTATE_STATE:-$HOME/.himmel/himmel-shell-suite-${_cursor_key}.cursor}"
else
  SUITE_ROTATE_STATE="${SUITE_ROTATE_STATE:-}"
fi

# --------------------------------------------------------------------------
# Discover suites via a temp file so counters survive the read-loop
# (piping into while would run in a subshell on some shells).
# --------------------------------------------------------------------------
suites_file=$(mktemp)
suites_raw=$(mktemp)
trap 'rm -f "$suites_file" "$suites_raw"; suite_lock_release' EXIT

# Check EVERY discovery stage so a partial-output-then-fail can't mask an
# incomplete scan (ran>0 with the guard below passing → green on a scan that
# never finished — the same false-green class HIMMEL-1128 closes). The two
# stages are `find` and `sort`; the earlier `grep -v /node_modules/` was
# redundant (find's `-path '*/node_modules' -prune` already excludes those
# subtrees) so it is dropped rather than status-checked.
#
# `-H` dereferences the COMMAND-LINE argument only (HIMMEL-2508 B). Without
# it, GNU find handed a scan root that is itself a symlink to a directory
# reports the link and stops — it never descends — so discovery comes back
# empty and the run dies at the "no test suites discovered" guard below. MSYS
# find followed the link, which is why this only ever surfaced once the fleet
# moved to a Linux station. `-H` is the narrow form deliberately: symlinks
# INSIDE the tree stay unfollowed exactly as before, so no scan root other
# than a symlinked one changes what it discovers. (The symlinked root's
# table-matching half is already handled by $scan_resolved, HIMMEL-2260.)
find -H "$scan" -path '*/node_modules' -prune -o -name 'test-*.sh' -print > "$suites_raw" 2>/dev/null
find_rc=$?
if [ "$find_rc" -ne 0 ]; then
  printf 'ERROR: suite discovery failed under scan root "%s" (find rc=%s) — refusing to report green.\n' "$scan" "$find_rc" >&2
  exit 1
fi
sort "$suites_raw" > "$suites_file"
sort_rc=$?
if [ "$sort_rc" -ne 0 ]; then
  printf 'ERROR: suite discovery sort failed (rc=%s) — refusing to report green.\n' "$sort_rc" >&2
  exit 1
fi

# Zero DISCOVERED suites = a resolved-to-nothing scan root (typo, empty dir, a
# file-valued root). Fail BEFORE the mode split so --list is guarded too: a
# --list of a bad root printing an empty plan and exiting 0 is the same
# false-green footgun as the execution path (HIMMEL-1128). (--list of a root
# whose suites are all SKIPPED is NOT failed here — listing a skip plan is the
# mode's purpose; only the execution path enforces run>0, at the ran==0 guard.)
# Test the completed discovery file directly with the `-s` builtin (non-empty)
# — no external `grep`/`wc` whose own failure could let an empty file slip past
# the guard and re-open the false-green.
if [ ! -s "$suites_file" ]; then
  printf 'ERROR: no test suites discovered under scan root "%s" — refusing to report green.\n' "$scan" >&2
  exit 1
fi

# Apply the resume rotation (HIMMEL-2243). See SUITE_ROTATE above. Execution
# only — `--list` prints the canonical sorted plan, and a cursor must not
# reorder a plan that nothing is about to execute.
rotate_start=""     # scan-root-relative suite this run actually started at
rotate_next=""      # first suite a budget expiry kept from running
suites_total=$(awk 'END { print NR }' "$suites_file")
if [ "$list_only" -eq 0 ] && [ "$SUITE_ROTATE" != "0" ] && [ -n "$SUITE_ROTATE_STATE" ] && [ -L "$SUITE_ROTATE_STATE" ]; then
  # Same posture as the SUITE_LOCK_DIR refusal above, and for the identical
  # reason: this code only ever creates a real regular file, so a symlink at
  # the cursor path is always either a mistake or an attack. `-f` follows
  # symlinks, so checking it FIRST would happily read straight through one to
  # whatever regular file it points at — never get there. Refuse, don't
  # delete or replace: touching it at all is the thing this guard exists to
  # avoid (HIMMEL-2243).
  printf 'WARN: %s is a symlink — the rotation cursor must be a real file.\n' "$SUITE_ROTATE_STATE" >&2
  printf '  Refusing to use it: what would be checked and what would be written are different files. Rotation is disabled for this run — fix or remove the symlink.\n' >&2
elif [ "$list_only" -eq 0 ] && [ "$SUITE_ROTATE" != "0" ] && [ -n "$SUITE_ROTATE_STATE" ] && [ -f "$SUITE_ROTATE_STATE" ]; then
  _rot_want=""
  IFS= read -r _rot_want < "$SUITE_ROTATE_STATE" || true
  # Strip a trailing CR: a cursor written (or hand-edited) on Windows can carry
  # one, and left in place it makes _rot_want compare unequal to every
  # discovered path — a cursor that silently never matches (HIMMEL-2243).
  _rot_want="${_rot_want%$'\r'}"
  if [ -n "$_rot_want" ]; then
    # The cursor stores a SCAN-ROOT-RELATIVE path, so a run spelled "./scripts"
    # resumes a cursor left by one spelled "scripts" — find's output differs
    # between the two spellings, the relative path does not.
    _rot_idx=$(awk -v want="$_rot_want" -v pre="$scan/" '
      { p = $0
        if (index(p, pre) == 1) { p = substr(p, length(pre) + 1) }
        if (p == want) { print NR; exit } }' "$suites_file")
    if [ -n "$_rot_idx" ]; then
      # Reuse $suites_raw: discovery is finished with it and it is already in
      # the EXIT trap, so this costs no third mktemp. `cat` back into place
      # rather than `mv` — mv is unreliable on MSYS, as the lock code documents.
      { awk -v k="$_rot_idx" 'NR >= k' "$suites_file"
        awk -v k="$_rot_idx" 'NR <  k' "$suites_file"; } > "$suites_raw"
      cat "$suites_raw" > "$suites_file"
      rotate_start="$_rot_want"
      printf 'NOTE: rotation — resuming at %s (%s of %s discovered) and wrapping to the top; a previous budget-truncated run left this cursor at %s.\n' \
        "$_rot_want" "$_rot_idx" "$suites_total" "$SUITE_ROTATE_STATE"
    else
      # A cursor naming a suite this scan root no longer discovers is stale
      # (renamed, deleted, different branch), not a reason to refuse: say so
      # and fall back to the canonical order.
      printf 'NOTE: rotation — the cursor at %s names "%s", which this scan root no longer discovers; starting from the top.\n' \
        "$SUITE_ROTATE_STATE" "$_rot_want" >&2
    fi
  fi
fi

# Runtime preflight (HIMMEL-1991): say out loud, ONCE, what these suites are
# about to run on. A whole-suite pass on an unpinned Node major is not the
# evidence it looks like. Advisory by default; HIMMEL_RUNTIME_PREFLIGHT=strict
# turns it into a refusal, =0 silences it (CI images, adopters). Skipped in list
# mode, which executes nothing.
if [ "$list_only" -eq 0 ]; then
  # shellcheck source=../lib/runtime-preflight.sh
  # shellcheck disable=SC1091
  . "$REPO_ROOT/scripts/lib/runtime-preflight.sh"
  runtime_preflight "run-shell-tests.sh" || exit 1
fi

# Take the machine lock before executing anything (list mode runs nothing, so
# it does not contend). Discovery already happened — a refusal here has cost
# nothing but a directory scan.
if [ "$list_only" -eq 0 ]; then
  suite_lock_acquire_waiting || exit 2
  # HIMMEL-2517 — first re-stat. A queued run can sit in the wait loop for
  # hours before this line; the tree it is about to walk may not have survived.
  scan_root_abort_if_vanished
fi

pass=0 fail=0 skip=0 ran=0
# HIMMEL-2517 — how many failures were rc=127 (command or path not found).
rc127=0
failed_suites=""
timed_out=0
cap_exceeded_clean=0
unrun_suites=""
budget_expired=0
# $SECONDS is a bash builtin — no fork. `date +%s` twice per suite plus once
# per budget check is four processes a suite on a box where a fork costs a
# quarter-second, which is real money across ninety suites and an odd tax for
# a change whose point is that these runs take too long.
run_start=$SECONDS

# Pin git fsync/template settings for the throwaway repos the suites build.
# Called once here so the exports flow to every suite subprocess the loop below
# spawns; idempotent via its marker, so a suite that re-sources the lib inherits
# without appending a duplicate. (HIMMEL-1589.)
git_test_env_pin_perf

# Resolve the conditional-suite filter (HIMMEL-1589). FAIL-OPEN: if this is not
# a git repo, the ref does not resolve, or either git command fails, run EVERY
# suite and say why. Silently filtering on a broken diff would be the same
# false-green class the discovery guards above close one level up.
conditional_filter_active=0
changed_set=""
if [ -n "$changed_since" ]; then
  # Resolve the ref to a concrete commit BEFORE handing it to `git diff`. A raw
  # --changed-since value is interpolated straight into `git diff`, where git
  # parses an OPTION-shaped value as an OPTION, not a ref: `git diff --name-only
  # --exit-code` on a clean tree SUCCEEDS with EMPTY output, so this block would
  # set conditional_filter_active=1 over an empty changed_set and SILENTLY skip
  # every conditional suite — a false green, the exact inverse of the fail-open
  # contract this else-branch exists to enforce. --end-of-options makes git treat
  # the value as a ref literal; ^{commit} forces a commit-ish. Anything that does
  # not resolve still falls through to fail-open below, unchanged. (HIMMEL-1589.)
  if resolved=$(git rev-parse --verify --quiet --end-of-options "${changed_since}^{commit}" 2>/dev/null) && \
     changed_tracked=$(git diff --name-only "$resolved" 2>/dev/null) && \
     changed_untracked=$(git ls-files --others --exclude-standard 2>/dev/null); then
    changed_set="${changed_tracked}
${changed_untracked}"
    conditional_filter_active=1
  else
    printf 'NOTE: --changed-since "%s" did not resolve (not a git repo, bad ref, or git failed) — running every suite.\n' \
      "$changed_since" >&2
  fi
fi

# Docs-only fast lane (HIMMEL-2166). See the header comment. Inert unless the
# conditional filter above resolved a real changed_set; an EMPTY changed_set
# (no tracked or untracked paths at all) is not evidence of a docs-only diff,
# so it never sets this flag — same fail-safe posture as the conditional
# filter's own "unresolved -> run everything" branch.
docs_only_skip_active=0
if [ "$conditional_filter_active" -eq 1 ]; then
  docs_only_skip_active=1
  _docs_saw_path=0
  while IFS= read -r _docs_p; do
    [ -n "$_docs_p" ] || continue
    _docs_saw_path=1
    if ! grep -Eq '^docs/|\.md$' <<< "$_docs_p"; then
      docs_only_skip_active=0
      break
    fi
  done <<EOF
$changed_set
EOF
  [ "$_docs_saw_path" -eq 1 ] || docs_only_skip_active=0
fi

# plan_narrowed (HIMMEL-2243 FIX 8): true when THIS run's plan is a proper
# subset of the full scan-root plan, for a reason a DIFFERENT run over the
# same scan root would not share. "Reached the end without truncating" is NOT
# "covered the ring" -- a run narrowed by --skip-extra, --changed-since,
# SUITE_TIER_MODE, or the docs-only fast lane reaches its end just as cleanly
# as an unnarrowed one, but its "first unrun suite" and "the ring is closed"
# are both meaningless for the FULL plan; treating them as authoritative
# clears (or writes) the scan-root-wide cursor on a narrowed run's say-so,
# silently restoring the exact permanent blind spot this ticket exists to
# remove. See the persist/clear block below for what this gates.
#
# Deliberately NOT triggered by SKIP_LIST or SUITE_REQUIRE_TOOL: those are
# permanent/host properties -- part of what "the full plan" IS on this host,
# not a narrowing of it. Treating them as narrowing would mean the cursor
# could never clear on any host missing a tool, the opposite failure.
plan_narrowed=0
plan_narrowed_why=""
if [ -n "$extra_skips" ]; then
  plan_narrowed=1
  plan_narrowed_why="${plan_narrowed_why}--skip-extra, "
fi
if [ "$conditional_filter_active" -eq 1 ]; then
  plan_narrowed=1
  plan_narrowed_why="${plan_narrowed_why}--changed-since, "
fi
if [ "$SUITE_TIER_MODE" != "all" ]; then
  plan_narrowed=1
  plan_narrowed_why="${plan_narrowed_why}SUITE_TIER_MODE=${SUITE_TIER_MODE}, "
fi
if [ "$docs_only_skip_active" -eq 1 ]; then
  plan_narrowed=1
  plan_narrowed_why="${plan_narrowed_why}docs-only fast lane, "
fi
plan_narrowed_why="${plan_narrowed_why%, }"

# fd 3, not stdin. With `done < "$suites_file"` the loop BODY inherits the
# suite list as its stdin, so any suite that read from stdin consumed the
# remaining suite paths — the runner then reported OK over a list it had
# silently eaten. Suites now get /dev/null (below), which also means an
# unattended run can never block on a prompt.
while IFS= read -r suite <&3; do
  [ -n "$suite" ] || continue

  # Two derived paths, for two different jobs (HIMMEL-2260):
  #   relpath    — scan-root-relative, the CURSOR's spelling (see the budget
  #                block below). Keeps the caller's spelling on purpose.
  #   suite_key  — the same suite under the RESOLVED scan root. This is what
  #                every suite table matches against, so a verdict depends on
  #                neither the scan root's depth nor how it was spelled
  #                (symlink, junction, absolute, "./", trailing slash).
  relpath="${suite#"${scan}"/}"
  suite_key="${scan_resolved}/${relpath}"

  if reason=$(is_skipped "$suite_key" "$relpath"); then
    skip=$((skip + 1))
    printf '[SKIP] %s — %s\n' "$suite" "$reason"
    continue
  fi

  # Docs-only fast lane (HIMMEL-2166): the whole corpus is irrelevant to a
  # docs-only diff, so this outranks tier/conditional/capability — checked
  # right after SKIP_LIST (a suite's SKIP_LIST reason is more informative than
  # "docs-only" and still wins).
  if [ "$docs_only_skip_active" -eq 1 ]; then
    skip=$((skip + 1))
    printf '[SKIP] %s — docs-only diff (no code path changed)\n' "$suite"
    continue
  fi

  # Tier suites (HIMMEL-2120): SUITE_TIER_MODE gates which tier runs. Checked
  # right after SKIP_LIST and before SUITE_CONDITIONAL/SUITE_REQUIRE_TOOL —
  # the stated precedence (SKIP_LIST -> tier -> SUITE_CONDITIONAL ->
  # SUITE_REQUIRE_TOOL) — so a suite both extended-listed and SKIP_LISTed
  # never runs (SKIP_LIST already took it above), and an extended-listed
  # suite whose required tool is absent still loud-skips on the tool in
  # extended mode (this check only ever runs a suite forward to that check,
  # never around it). Inert when SUITE_TIER_MODE=all (the default), matching
  # a full run exactly regardless of table contents.
  if tier_lookup "$suite_key"; then
    if [ "$SUITE_TIER_MODE" = "fast" ]; then
      skip=$((skip + 1))
      printf '[SKIP] %s — tier: extended (SUITE_TIER_MODE=fast) — %s\n' "$suite" "$_tier_reason"
      continue
    fi
  elif [ "$SUITE_TIER_MODE" = "extended" ]; then
    skip=$((skip + 1))
    printf '[SKIP] %s — tier: not extended-listed (SUITE_TIER_MODE=extended runs only extended-tier suites)\n' "$suite"
    continue
  fi

  # Conditional suites (HIMMEL-1589): when --changed-since is active, a suite in
  # SUITE_CONDITIONAL runs only if a changed path matches its ERE. Inert without
  # the flag (conditional_filter_active=0), so a full run behaves exactly as
  # before. Runs through --list too, so the skip plan reflects the filter.
  if [ "$conditional_filter_active" -eq 1 ] && ere=$(conditional_ere "$suite_key"); then
    if ! conditional_matches "$ere"; then
      skip=$((skip + 1))
      printf '[SKIP] %s — conditional: no changed path matches %s\n' "$suite" "$ere"
      continue
    fi
  fi

  # Capability-conditional suites (HIMMEL-1792): RUNS where the tool is on
  # PATH, [SKIP]s loudly and attributed where it is not — never a silent
  # never-run. Checked in --list too, so the plan shows the real per-host
  # disposition.
  if capability_lookup "$suite_key" && ! command -v "$_cap_tool" >/dev/null 2>&1; then
    skip=$((skip + 1))
    printf '[SKIP] %s — capability: %s not on PATH — %s\n' "$suite" "$_cap_tool" "$_cap_reason"
    continue
  fi

  if [ "$list_only" -eq 1 ]; then
    printf '[RUN ] %s\n' "$suite"
    continue
  fi

  # Whole-run budget, checked BETWEEN suites so a cap can never truncate a
  # suite mid-assertion. Everything still on the list is named as unrun —
  # stopping quietly here would be the same false green the discovery guards
  # above exist to prevent.
  if [ "$budget_expired" -eq 1 ] || \
     [ $(( SECONDS - run_start )) -ge "$SUITE_RUN_BUDGET" ]; then
    if [ "$budget_expired" -eq 0 ]; then
      budget_expired=1
      # The first suite the budget kept from running: the next run resumes
      # HERE (HIMMEL-2243). Scan-root-relative so the spelling of the scan
      # root cannot invalidate the cursor.
      rotate_next="$relpath"
    fi
    unrun_suites="${unrun_suites}  ${suite}
"
    continue
  fi

  log=$(mktemp)
  # Derived, not a second mktemp: same directory, same lifetime, one less fork.
  rcfile="$log.rc"
  start=$SECONDS

  # Run the suite as a background job in its OWN process group (`set -m`), and
  # arm a watchdog beside it. `timeout` did the timing before, and it group-
  # signals too — but it has no --kill-after here, so a suite that ignores
  # TERM (any suite with a cleanup trap) ran to completion with the cap
  # silently doing nothing: measured 41s against a 5s cap. It is also guarded
  # by `command -v timeout`, so on a box without it there was no cap at all.
  #
  # The watchdog owns the whole escalation. The parent just `wait`s — no
  # polling, so a fast suite is not taxed for the privilege of being capped,
  # and one `sleep` per suite replaces one per second.
  #
  # The rc file, not the exit status, is the arbiter of what happened: a
  # watchdog that fires as the suite completes finds the file already written
  # and stands down, so that race resolves in favour of the real result.
  : > "$rcfile"
  suite_timeout=$(_suite_timeout_for "$suite")
  # Give the suite its OWN temp root under one sweepable name (HIMMEL-1978).
  # A suite the watchdog terminates never runs its own cleanup traps, so every
  # mktemp it made survived — /tmp on the dev box reached ~149,600 top-level
  # entries that way, and a reboot does not clear %TEMP% on Windows. With the
  # root per suite, the runner (which DOES regain control after a timeout)
  # deletes the whole tree below, so a killed suite costs one entry, not
  # hundreds. TMP/TEMP as well as TMPDIR: node's os.tmpdir() reads TEMP/TMP on
  # Windows, and several suites drive node/bun children.
  # Fails OPEN (the suite still runs, in the shared temp root) — a suite must
  # not be skipped because a hygiene nicety could not be set up — but never
  # SILENTLY: a run that quietly lost its isolation is a run whose leftovers
  # nobody expects.
  suite_tmp=$(mktemp -d "${TMPDIR:-/tmp}/himmel-suite.XXXXXX" 2>/dev/null) || suite_tmp=''
  if [ -z "$suite_tmp" ]; then
    printf '[NOTE] %s — could not create a per-suite temp root; running in the shared one\n' "$suite"
  fi
  set -m
  { if [ -n "$suite_tmp" ]; then export TMPDIR="$suite_tmp" TMP="$suite_tmp" TEMP="$suite_tmp"; fi
    # HIMMEL-2551: marks every suite as a test fixture, so a tool that can
    # reach real operator state (restart-bridge.sh) REFUSES when the suite
    # forgot to sandbox its root, instead of trusting it.
    export HIMMEL_TEST_FIXTURE=1
    bash "$suite" >"$log" 2>&1 </dev/null; printf '%s\n' "$?" > "$rcfile"; } &
  suite_pid=$!
  # Its own group as well, so cancelling it below takes its `sleep` too —
  # a watchdog that leaked one sleeper per suite would be its own churn bug.
  ( sleep "$suite_timeout"
    [ -s "$rcfile" ] && exit 0
    if proc_tree_terminate "$suite_pid"; then
      printf '[TIME] %s — exceeded %ss; suite and its descendants terminated\n' \
        "$suite" "$suite_timeout"
    else
      printf '[TIME] %s — exceeded %ss; WARNING: descendants survived termination\n' \
        "$suite" "$suite_timeout"
    fi ) &
  watch_pid=$!
  set +m

  wait "$suite_pid" 2>/dev/null

  capped=0
  if [ -s "$rcfile" ]; then
    read -r rc < "$rcfile"
    # Finished on its own: stand the watchdog down. Only in this branch — if
    # the watchdog is the reason the suite is gone, it may still be mid-
    # escalation, and cancelling it there could strand the survivor it was
    # about to deal with.
    kill -TERM -"$watch_pid" 2>/dev/null || kill -TERM "$watch_pid" 2>/dev/null
  else
    # 124 is the code `timeout` reported, so downstream readers of this log
    # keep the meaning they already had.
    rc=124
    capped=1
    timed_out=$((timed_out + 1))
  fi
  wait "$watch_pid" 2>/dev/null
  rm -f "$rcfile"
  # After the watchdog has stood down, so a survivor cannot be writing into a
  # tree we are deleting. Best-effort: on Windows a still-open handle makes
  # rm -rf fail, and that leftover is exactly what tmp-sweep.sh collects later.
  [ -n "$suite_tmp" ] && rm -rf "$suite_tmp" 2>/dev/null

  dur=$(( SECONDS - start ))
  ran=$((ran + 1))

  if [ "$rc" -eq 0 ]; then
    pass=$((pass + 1))
    printf '[PASS] %s (%ss)\n' "$suite" "$dur"
  else
    fail=$((fail + 1))
    # HIMMEL-2233: a suite the watchdog killed for exceeding its cap has NO
    # OBSERVED EXIT STATUS — it may have been merely slow, or it may have
    # failed an assertion and then hung during teardown, with the watchdog
    # killing it before that exit status was ever written. Rendering it
    # identically to a suite that failed on its own cost a leg 10-30 minutes
    # of adjudication (4 of 10 failures in the 2026-08-29 run were this, one
    # of them a suite that is 195/195 GREEN standalone). Key off `capped`,
    # NOT `[ "$rc" -eq 124 ]` — a suite is free to exit 124 on its own, and
    # that IS a real exit status that must keep rendering as a plain failure.
    if [ "$capped" -eq 1 ]; then
      # HIMMEL-2401: a suite the watchdog kills at its cap with every OBSERVED
      # assertion passing (only "ok" lines, no "not ok") is LIKELY a
      # cap-sizing problem rather than a test problem -- today it renders
      # identically to a genuine failure (FAIL: 1), which is what costs a leg
      # two extra full runs to disposition. Heuristic, not a universal
      # test-framework contract, and not proof of health: it only recognizes
      # the TAP-ish "ok"/"not ok" line convention some suites use. A suite on
      # a different convention still renders as plain CAP EXCEEDED even when
      # it was, in fact, healthy (a false negative). The reverse can also
      # happen (HIMMEL-2401 codex-1, round 2): a suite that emits an "ok"
      # token for reasons unrelated to TAP assertions (plain narration, e.g.
      # "ok - moving on") and then fails through a DIFFERENT, non-TAP
      # mechanism reads as clean here even though it is not -- there is no
      # way to rule that out in general across ~200 distinct pass/fail
      # conventions in this repo's suites. Treat the label as a strong
      # disposition HINT, not a guarantee: re-size first, but a suite that
      # keeps failing after its cap is raised still needs a look.
      #
      # HIMMEL-2401 codex-1: anchor on a whole "ok"/"not ok" TOKEN, not a bare
      # line prefix -- `^ok` alone also matches "okay ..." (a false positive:
      # a suite that never used TAP wording still gets called clean), and
      # `^not ok` alone misses TAP's own indented subtest lines (a false
      # negative: `  not ok - nested case` reads as no failure). Optional
      # leading whitespace plus a boundary (space or end of line) after the
      # token fixes both.
      if grep -qE '^[[:space:]]*not ok([[:space:]]|$)' "$log" 2>/dev/null; then
        assertions_passing=0
      elif grep -qE '^[[:space:]]*ok([[:space:]]|$)' "$log" 2>/dev/null; then
        assertions_passing=1
      else
        assertions_passing=0
      fi
      if [ "$assertions_passing" -eq 1 ]; then
        cap_exceeded_clean=$((cap_exceeded_clean + 1))
        failed_suites="${failed_suites}  ${suite} (CAP EXCEEDED after ${dur}s, cap ${suite_timeout}s — no exit status observed, assertions passing)
"
        printf '[CAP EXCEEDED] %s (ran %ss, cap %ss) — killed by the runner'"'"'s watchdog at the cap, no exit status observed, assertions passing\n' \
          "$suite" "$dur" "$suite_timeout"
      else
        failed_suites="${failed_suites}  ${suite} (CAP EXCEEDED after ${dur}s, cap ${suite_timeout}s — no exit status observed)
"
        printf '[CAP EXCEEDED] %s (ran %ss, cap %ss) — killed by the runner'"'"'s watchdog at the cap, no exit status observed\n' \
          "$suite" "$dur" "$suite_timeout"
      fi
      echo '----- last 100 lines (output at termination) -----'
    else
      # HIMMEL-2517: rc=127 is "command or path not found" — one is a suite bug,
      # a whole run of them is the tree having been deleted underneath us. Only
      # counted on this branch: a CAP EXCEEDED suite has NO observed exit
      # status (see above), so its synthetic 124 says nothing either way.
      [ "$rc" -eq 127 ] && rc127=$((rc127 + 1))
      failed_suites="${failed_suites}  ${suite} (rc=${rc})
"
      printf '[FAIL] %s (rc=%s, %ss)\n' "$suite" "$rc" "$dur"
      echo '----- last 100 lines -----'
    fi
    tail -n 100 "$log" | sed 's/^/    /'
    echo '--------------------------'
    # Preserve the FULL failed-suite log when FAIL_LOG_DIR is set (CI uploads
    # it as an artifact — HIMMEL-963: tail-only + rm made the failing
    # assertion unrecoverable from Actions logs). Injective escape (_ -> _u,
    # / -> _s) so distinct relpaths like a/b and a_b can't collide.
    if [ -n "${FAIL_LOG_DIR:-}" ]; then
      mkdir -p "$FAIL_LOG_DIR"
      safe_relpath=$(printf '%s' "$relpath" | sed 's/_/_u/g; s#/#_s#g')
      cp "$log" "$FAIL_LOG_DIR/$safe_relpath.log"
    fi
  fi
  rm -f "$log"
done 3< "$suites_file"

# HIMMEL-2517 — second re-stat, before even the Summary HEADER is written. This
# is the one that keeps the artifact off the PR: the --pr post below happens in
# THIS process, so a root that vanished mid-run must stop here rather than be
# rendered as a report and then published. Skipped under --list, which executed
# nothing and exits below on its own.
[ "$list_only" -eq 1 ] || scan_root_abort_if_vanished

echo
echo '== Summary =='
if [ "$list_only" -eq 1 ]; then
  echo "(--list: nothing executed)"
  exit 0
fi
printf ' PASS: %s\n SKIP: %s\n FAIL: %s\n' "$pass" "$skip" "$fail"
if [ "$timed_out" -gt 0 ]; then
  printf ' TIMED OUT: %s (counted in FAIL)\n' "$timed_out"
fi
if [ "$cap_exceeded_clean" -gt 0 ]; then
  # HIMMEL-2401: a subset of TIMED OUT (never a separate FAIL count) -- LIKELY
  # a cap problem rather than a test problem. Disposition: re-size the entry
  # in _suite_timeout_for first, but this is a heuristic over one line
  # convention, not proof of health (see the detector's own comment above).
  printf ' CAP EXCEEDED (assertions passing): %s\n' "$cap_exceeded_clean"
fi
if [ "$budget_expired" -eq 1 ]; then
  printf 'ERROR: run budget of %ss expired — these suites never ran:\n%s' \
    "$SUITE_RUN_BUDGET" "$unrun_suites" >&2
fi

# HIMMEL-2517 — the SECOND, independent signature of a run that measured its own
# environment rather than the tests. The scan-root re-stat above catches the
# deletion this ticket was filed for, but only while the root itself is gone; it
# does not catch a root that was replaced, a PATH or mount that collapsed
# mid-run, or any other way a run can end up unable to execute anything. An
# overwhelming majority of failures at rc=127 — "command or path not found" —
# is that class regardless of cause. In the filed incident it was 421 of 422.
#
# The denominator is what makes the inference sound, and getting it wrong was a
# round-1 CR finding (codex-1). Measured against FAILURES, the rule condemns a
# real regression: delete a shared helper ten suites call and 10-of-10 failures
# are rc=127, so a genuine, diff-caused red run would be refused and its
# after-report withheld from the PR — the exact loss HIMMEL-2383 exists to
# prevent. rc=127 alone proves only that a command was not found; it does not
# distinguish "this diff removed a dependency" from "nothing here can execute".
# What DOES distinguish them is scale relative to the whole run: in the filed
# incident 421 of the 427 suites that ran (98%) could not execute, whereas a
# deleted shared helper takes ten suites out of ~450 (2%) and leaves the rest
# running normally. So the ratio is over `ran`, not over `fail`. A broad but
# partial regression can never trip it, however lopsided its failure set is.
#
# The floor survives as a small-run guard: rc=127 is a legitimate verdict for a
# suite whose fixture is missing a binary, and in a three-suite sandbox one such
# suite is already most of the run. It counts rc=127 failures, not failures
# (round-4 CR finding codex-1): keyed on the total, a run of ten with nine
# rc=127 and one ordinary failure cleared a floor named for rc=127 while holding
# only nine of them. Both halves of the predicate now speak about the same
# quantity, and the correction can only make the refusal fire LESS — which is
# the safe direction for a rule whose failure mode is withholding a report.
#
# Placed BEFORE the --pr block on purpose: refusing to publish is the entire
# point. The tallies above are still printed — locally they are the forensic
# record of what happened; what must not happen is them becoming a PR's answer.
SUITE_RC127_FLOOR=10
if [ "$rc127" -ge "$SUITE_RC127_FLOOR" ] && [ $((rc127 * 100)) -ge $((ran * 90)) ]; then
  printf 'CONTAMINATED: %s of the %s suites that ran exited rc=127 (command or path not found).\n' "$rc127" "$ran" >&2
  printf '  A run this uniformly rc=127 measured its own environment, not the tests — nearly nothing here could be executed at all (HIMMEL-2517).\n' >&2
  printf '  Refusing to report this as a result or post an after-report. Re-run from a checkout you have verified is intact.\n' >&2
  exit 4
fi

# HIMMEL-2383 — post the after-report SUMMARY as a PR comment from the
# RUNNER PROCESS itself, opt-in via --pr/SUITE_REPORT_PR (never default-on,
# never posted without one of these set): a closed parent session must not
# lose the report (HIMMEL-2215 lineage — the incident this exists to close
# is a leg's after-report vanishing along with the session that would have
# posted it). Placed here, before every exit path below, so it runs whether
# this turns out to be a pass, a failure, or a budget-truncated run — the
# report is exactly as needed in each case. Best-effort: a post failure
# WARNs but never changes this run's own exit code.
if [ -n "$report_pr" ]; then
  # 'head: <sha>' binds the report to the exact commit tested (HIMMEL-2383
  # CR finding codex-3) — without it, a stale summary from an earlier
  # revision of the PR would satisfy a check against a LATER, unreviewed
  # head. base-status.sh requires this line to match the PR's headRefOid
  # exactly before treating the comment as covering that head. $REPORT_HEAD
  # was captured at startup, not re-resolved here (round 9, see its own
  # comment) — this process ran the suites against that sha regardless of
  # what happens to the worktree afterward.
  #
  # 'scope: <scan-root>' (round-12 CR finding codex-1) records WHAT was
  # tested — without it, a narrow `--pr` run (e.g. scoped to scripts/ci)
  # posts the same clean-looking SUMMARY shape as a full-tree run, and
  # base-status.sh has no way to tell the two apart: it would certify a
  # totally untested fence (e.g. scripts/handover) as clean just because
  # SOME scoped run against this head happened to pass. base-status.sh
  # requires this scope to be an ancestor of (or equal to) the fence it is
  # certifying before treating the SUMMARY as covering it.
  summary_block=$(printf '== Summary ==\n head: %s\n scope: %s\n PASS: %s\n SKIP: %s\n FAIL: %s' "$REPORT_HEAD" "$scan" "$pass" "$skip" "$fail")
  # $(...) strips the trailing newline each printf above would otherwise
  # end with (HIMMEL-2383 CR finding codex-3, round 4) — without the
  # explicit newline below, an optional TIMED OUT/TRUNCATED line lands
  # glued onto the end of the FAIL line instead of on its own line. Purely
  # cosmetic (base-status.sh's FAIL:/TRUNCATED: matching is glob-based and
  # unaffected either way), fixed for a readable posted comment.
  if [ "$timed_out" -gt 0 ]; then
    summary_block="${summary_block}
$(printf ' TIMED OUT: %s (counted in FAIL)' "$timed_out")"
  fi
  if [ "$cap_exceeded_clean" -gt 0 ]; then
    summary_block="${summary_block}
$(printf ' CAP EXCEEDED (assertions passing): %s' "$cap_exceeded_clean")"
  fi
  # A budget-truncated run is not evidence of clean, however green the
  # suites that DID run were (HIMMEL-2383 CR finding codex-4) — some
  # suites never ran. base-status.sh reads this marker as PENDING
  # regardless of the FAIL count above.
  if [ "$budget_expired" -eq 1 ]; then
    summary_block="${summary_block}
$(printf ' TRUNCATED: yes (run budget expired — not every suite ran)')"
  fi
  # A --changed-since run conditionally skips suites unrelated to that diff
  # (round-13 CR finding codex-2) — the `scope:` line above still names the
  # full scan root, but not every suite under it ran, so this is not full
  # coverage evidence either. base-status.sh reads this marker as PENDING
  # regardless of the FAIL count, same as TRUNCATED above.
  if [ -n "$changed_since" ]; then
    summary_block="${summary_block}
$(printf ' CHANGED-SINCE: %s (suites were conditionally filtered — not full scope coverage)' "$changed_since")"
  fi
  if command -v "${GH_CMD:-gh}" >/dev/null 2>&1; then
    # Bounded so a GitHub network stall can't hang the run after every suite
    # already finished (CodeRabbit round on PR #2099); skipped when `timeout`
    # isn't on PATH rather than failing the post outright.
    _gh_report_cmd=("${GH_CMD:-gh}" pr comment "$report_pr" --body "$summary_block")
    if command -v timeout >/dev/null 2>&1; then
      _gh_report_cmd=(timeout "${GH_TIMEOUT_SECS:-30}" "${_gh_report_cmd[@]}")
    fi
    if "${_gh_report_cmd[@]}" >/dev/null 2>&1; then
      echo "NOTE: after-report posted to PR #$report_pr"
    else
      echo "WARN: could not post the after-report to PR #$report_pr (gh pr comment failed) — the SUMMARY above is still the record." >&2
    fi
  else
    echo "WARN: --pr/SUITE_REPORT_PR given but 'gh' is not on PATH — could not post the after-report to PR #$report_pr." >&2
  fi
fi

# Persist or clear the rotation cursor (HIMMEL-2243). Placed above the fail>0
# branch on purpose: that branch exits, and a run that truncated AND had real
# failures must still record where to resume.
#
# CLEARED only when a run reached the end, actually executed suites, AND ran
# the UNNARROWED plan (HIMMEL-2243 FIX 8). "Reached the end and executed
# suites" used to be treated as sufficient, which is exactly the too-weak rule
# that let a --skip-extra / --changed-since / SUITE_TIER_MODE-narrowed run
# clear (or write) a scan-root-wide cursor on the strength of ITS plan, not
# the full one. A narrowed run has no authority over the full-plan cursor —
# it leaves the cursor exactly as it found it, in either direction.
if [ "$SUITE_ROTATE" != "0" ]; then
  if [ "$plan_narrowed" -eq 1 ]; then
    printf 'NOTE: rotation — left untouched: this run'"'"'s plan was narrowed (%s), so it has no authority over the full-plan cursor.\n' \
      "$plan_narrowed_why" >&2
  elif [ "$budget_expired" -eq 1 ] && [ -n "$rotate_next" ]; then
    # Empty SUITE_ROTATE_STATE means rotation is unavailable (no HOME, no
    # override — see the assignment above) — checked BEFORE `dirname`/the
    # write, both of which are live footguns on an empty path (`dirname ""`
    # prints "." and a redirect to "" is an error, but neither is a risk worth
    # taking when the skip is one line). Say so once, here, because this is
    # the one moment it actually costs the operator something: a truncated
    # run that cannot leave a resume point.
    if [ -z "$SUITE_ROTATE_STATE" ]; then
      printf 'NOTE: rotation — disabled (no HOME is set and no SUITE_ROTATE_STATE override was given); this truncated run leaves no resume point, so the next run starts from the top again.\n' >&2
    elif [ -L "$SUITE_ROTATE_STATE" ]; then
      # Same posture as the read/rotate block above and SUITE_LOCK_DIR: a
      # redirect FOLLOWS symlinks, so writing here without this check would
      # overwrite whatever the link points at, not the cursor. Refuse, don't
      # delete or replace it (HIMMEL-2243).
      printf 'WARN: %s is a symlink — refusing to write the rotation cursor there.\n' "$SUITE_ROTATE_STATE" >&2
      printf '  What would be checked and what would be written are different files; this truncated run leaves no resume point. Fix or remove the symlink.\n' >&2
    else
      mkdir -p "$(dirname "$SUITE_ROTATE_STATE")" 2>/dev/null
      if printf '%s\n' "$rotate_next" > "$SUITE_ROTATE_STATE" 2>/dev/null; then
        printf 'NOTE: rotation — the next run over "%s" resumes at %s (cursor: %s).\n' \
          "$scan" "$rotate_next" "$SUITE_ROTATE_STATE" >&2
      else
        printf 'WARN: rotation — could not write the cursor to %s, so the next run starts from the top and re-runs this same front section.\n' \
          "$SUITE_ROTATE_STATE" >&2
      fi
    fi
  elif [ "$budget_expired" -eq 0 ] && [ "$ran" -gt 0 ] && [ -n "$SUITE_ROTATE_STATE" ]; then
    # Same empty-path guard as above, for `rm -f ""` — a no-op in practice,
    # but the CLEARED-only comment above already draws the correct line, so
    # this stays consistent with it rather than relying on rm's leniency.
    if [ -L "$SUITE_ROTATE_STATE" ]; then
      # Refusing to touch it is the whole point — no `rm -f` on a symlink
      # either, matching the write branch's posture exactly (HIMMEL-2243).
      printf 'WARN: %s is a symlink — refusing to touch it while clearing the rotation cursor.\n' "$SUITE_ROTATE_STATE" >&2
      printf '  What would be checked and what would be deleted are different files; leaving it in place. Fix or remove the symlink.\n' >&2
    else
      if [ -n "$rotate_start" ]; then
        printf 'NOTE: rotation — this run started at %s and reached the end, closing the ring; clearing the cursor.\n' \
          "$rotate_start" >&2
      fi
      rm -f "$SUITE_ROTATE_STATE" 2>/dev/null
    fi
  fi
fi

if [ "$fail" -gt 0 ]; then
  printf 'Failed suites:\n%s' "$failed_suites"
  # HIMMEL-2231: a red suite's most likely cause, cheapest-to-rule-out first —
  # printed only on a real failure so a green run stays quiet.
  printf 'Disposition order for a red suite (HIMMEL-2231):\n'
  printf '  1. CAP EXCEEDED  -> the runner'"'"'s watchdog killed it; re-run that suite alone\n'
  printf '                      (or raise its entry in _suite_timeout_for) before reading it as a bug.\n'
  printf '  2. fails on main too -> pre-existing; not your diff.\n'
  printf '  3. passes on main    -> re-run it ALONE before blaming your diff.\n'
  exit 1
fi
# A budget-truncated run is not a pass, however green the suites that did run
# were — the ones that never ran are exactly the ones nobody has evidence for.
if [ "$budget_expired" -eq 1 ]; then
  exit 1
fi
# Suites were discovered (the discovered==0 guard above already passed) but
# every one was skipped, so nothing actually ran — not a pass. Reporting it
# green is a false green on a process-integrity gate (HIMMEL-1128).
#
# EXCEPT the docs-only fast lane (HIMMEL-2166): there every suite was skipped
# for the SAME evidence-based reason (the diff cannot touch any shell suite),
# not a misconfiguration — a genuine pass, unlike an accidental empty scan
# root or an over-broad --skip-extra.
if [ "$ran" -eq 0 ]; then
  if [ "$docs_only_skip_active" -eq 1 ]; then
    echo "OK: docs-only diff — 0 shell suites needed ($skip skipped)"
    exit 0
  fi
  printf 'ERROR: no suites ran under scan root "%s" (all discovered suites were skipped) — refusing to report green.\n' "$scan" >&2
  exit 1
fi
echo "OK: all $ran run suites passed ($skip skipped)"
exit 0
