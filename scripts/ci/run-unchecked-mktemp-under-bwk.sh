#!/usr/bin/env bash
# shellcheck disable=SC2016  # the awk program below is single-quoted on
# purpose -- it must not be expanded by this shell.
# scripts/ci/run-unchecked-mktemp-under-bwk.sh — HIMMEL-3653: builds a pinned
# one-true-awk (BWK) from source, puts it first on PATH as `awk`, and runs
# scripts/lib/test-unchecked-mktemp.sh under it.
#
# WHY. HIMMEL-3624 fixed a bracket-expression bug in scripts/lib/
# unchecked-mktemp.sh that only failed under BWK (macOS /usr/bin/awk) —
# `gawk --posix`/`--lint=fatal` both accept the broken regex (J1288O),
# so a lint substitute would not have caught it. Only a real BWK run does.
# The only prior BWK coverage was the nightly macOS shell-unit-shard leg,
# which is continue-on-error (advisory). This gives the gate a PR-time,
# gating BWK run on ubuntu.
#
# The source is a PINNED commit, never a branch, so this step cannot start
# silently building a different awk.
set -euo pipefail

BWK_COMMIT="5739fd79bcfc75ba7526773d0cf634521f8aca3c"
BWK_REPO="https://github.com/onetrueawk/awk.git"

build_dir="$(mktemp -d "${TMPDIR:-/tmp}/bwk-awk-build.XXXXXX")" || exit 1
git clone --quiet "$BWK_REPO" "$build_dir"
git -C "$build_dir" checkout --quiet "$BWK_COMMIT"
make -C "$build_dir" >/dev/null

shim_dir="$(mktemp -d "${TMPDIR:-/tmp}/bwk-awk-shim.XXXXXX")" || exit 1
ln -s "$build_dir/a.out" "$shim_dir/awk"

# Confirm the built binary is genuinely BWK before trusting it: BWK is the
# only awk that fails "nonterminated character class" on a bare `/` inside a
# bracket expression (the exact HIMMEL-3624 trigger) — gawk accepts it.
if echo x | "$shim_dir/awk" '{ if ($0 ~ /^[^A-Za-z0-9_./-]/) print }' >/dev/null 2>&1; then
  echo "run-unchecked-mktemp-under-bwk: built awk did not reproduce the BWK bracket-class parse error at $BWK_COMMIT -- not a real one-true-awk build" >&2
  exit 1
fi

PATH="$shim_dir:$PATH" bash scripts/lib/test-unchecked-mktemp.sh
