#!/usr/bin/env bash
# scripts/handover/test-arm-resume-fast.sh — the fast-tier 91/92 of
# test-arm-resume.sh's sections, restored to per-PR CI via the `--only`
# seam (HIMMEL-1637).
#
# HIMMEL-3132: test-arm-resume.sh (637 asserts) sits on run-shell-tests.sh's
# SKIP_LIST -- measured 2775s standalone (HIMMEL-2254) against the runner's
# 600s per-suite default (HIMMEL-2233) -- so it never runs in CI and a
# regression shipped straight into it (PR #787 / HIMMEL-3118 case (h)) went
# unwatched the same day it landed.
#
# Per-section timing (2026-09-18) found the 2775s is NOT spread evenly: 91 of
# the 92 `--list`-reported sections sum to ~200s total (each 0-58s; the two
# outliers, V6/V6c, are real `sleep`-past-target scheduler-probe simulations).
# Only ONE section -- "1879" -- is genuinely incompatible with a 600s cap (its
# own real `while ... sleep 1 ...` wait loops run several minutes with no
# shortcut available without weakening the race it tests); that section stays
# out of this file and instead runs nightly-only via the sibling
# test-arm-resume-1879.sh (SUITE_TIER_DEFAULT `extended`).
#
# This file is a thin dispatcher, not a rewrite: every assertion still lives
# in test-arm-resume.sh, and a bare invocation of that file (no --only) still
# runs everything, byte-identical to before -- this wrapper only narrows which
# sections one particular run selects. Keep it in sync with test-arm-resume.sh
# --list minus "1879": a section added there and forgotten here silently drops
# back out of per-PR coverage.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
exec bash test-arm-resume.sh \
    --only "T1" \
    --only "T2" \
    --only "T3" \
    --only "T4" \
    --only "T5" \
    --only "T6" \
    --only "T7" \
    --only "T8" \
    --only "T9" \
    --only "T10" \
    --only "T11" \
    --only "T12" \
    --only "T13" \
    --only "T14" \
    --only "T15" \
    --only "T16" \
    --only "T17" \
    --only "T18" \
    --only "T19" \
    --only "T20" \
    --only "T21" \
    --only "T22" \
    --only "T23" \
    --only "T23b" \
    --only "T24" \
    --only "T25" \
    --only "T26" \
    --only "T27" \
    --only "T28" \
    --only "T29" \
    --only "T30" \
    --only "T31" \
    --only "T32" \
    --only "T33" \
    --only "T33c" \
    --only "T38" \
    --only "W1-W8" \
    --only "T33-collision" \
    --only "T34" \
    --only "T35" \
    --only "T36" \
    --only "T37" \
    --only "N1-N8" \
    --only "S1-S5" \
    --only "N9-N13" \
    --only "macOS" \
    --only "T-awkfail" \
    --only "T-wsl" \
    --only "V1" \
    --only "V2" \
    --only "V3" \
    --only "V4" \
    --only "V5" \
    --only "V6" \
    --only "V6b" \
    --only "V6c" \
    --only "V7" \
    --only "V8" \
    --only "V8b" \
    --only "V9" \
    --only "FIND2" \
    --only "1365" \
    --only "1331" \
    --only "1331b" \
    --only "1329" \
    --only "1330" \
    --only "1337" \
    --only "1603" \
    --only "T_SEAM" \
    --only "T_PRUNE" \
    --only "T_PRUNE_REAL" \
    --only "T1287" \
    --only "1640" \
    --only "1719" \
    --only "1674" \
    --only "1879-1365" \
    --only "812" \
    --only "1830" \
    --only "1636" \
    --only "2113c" \
    --only "2113d" \
    --only "2113e" \
    --only "2113f" \
    --only "2113g" \
    --only "2128" \
    --only "2147" \
    --only "2192" \
    --only "2199" \
    --only "2177" \
    --only "2545" \
    --only "3118" \
    --only "2973"
