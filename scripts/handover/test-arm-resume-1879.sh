#!/usr/bin/env bash
# scripts/handover/test-arm-resume-1879.sh — the one section of
# test-arm-resume.sh that a 600s per-suite cap genuinely cannot fit
# (HIMMEL-3132), dispatched via the `--only` seam (HIMMEL-1637).
#
# Section "1879" (HIMMEL-1879: idempotency against an arm that already
# FIRED, and the create-said-yes-but-registered-nothing verify) covers its
# race windows with real `while [ "$(date +%s)" -le $deadline ]; do sleep 1;
# done` waits -- there is no dry-run shortcut for "did the scheduler's own
# probe still see the entry after the target passed" that stays faithful to
# what it tests. Timed alone (2026-09-18) it ran several minutes past the
# 600s default; every OTHER section in test-arm-resume.sh's --list is 0-58s
# and lives in the sibling test-arm-resume-fast.sh instead.
#
# So this suite is SUITE_TIER_DEFAULT `extended` in run-shell-tests.sh, not
# SKIP_LIST: it runs nightly (SUITE_TIER_MODE=all, the schedule/force_all_os
# leg of shell-unit-shard), same mechanism already proven by the sibling
# extended suites test-arm-resume-identity.sh / test-arm-resume-queue-lock.sh.
# A nightly-only red is covered by scripts/ci/shell-extended-nightly-issue.sh
# (HIMMEL-3132's non-silence requirement, same upsert-one-issue shape as
# scripts/ci/windows-nightly-issue.sh) -- it is not a silent gap.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
exec bash test-arm-resume.sh --only "1879"
