#!/usr/bin/env bash
# scripts/cr/pr-check-step0.sh - HIMMEL-3798: /pr-check step 0 as a no-arg
# script, so the runbook's step-0 fence collapses to one bare literal
# (`bash "$HIMMEL_REPO/scripts/cr/pr-check-step0.sh"`) instead of the inline
# `if himmel_repo=$(printenv HIMMEL_REPO | grep .); then ... fi` compound -
# the single highest-rate classifier-denial shape (HIMMEL-3724 4a row 2): the
# permission matcher splits a compound on its shell separators and matches
# each simple command independently, so no exact-literal allow rule for the
# whole `if...fi` string ever fires, and legs fell through to the classifier.
#
# This script IS the fence's logic, moved inside a file the guard trusts by
# its anchor-prefixed invocation alone (guard-pr-check-literal.sh's
# himmel_anchor_prefix exemption, HIMMEL-3437 finding 1) - never by adding
# this script to TARGETS, since the invoking word is always
# "$HIMMEL_REPO/scripts/cr/pr-check-step0.sh": HIMMEL_REPO is anchor-
# controlled, never branch-controlled, so the guard skips checking it at all.
set -uo pipefail

if himmel_repo=$(printenv HIMMEL_REPO | grep .); then
    exec bash "$himmel_repo/scripts/cr/pr-check-context.sh"
else
    echo "pr-check: HIMMEL_REPO is unset or empty — cannot locate himmel from a trusted source outside the repo under review; adopt/setup wires it into settings.json env, or export it non-empty in your launching shell, then re-run" >&2
    exit 2
fi
