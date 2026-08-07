#!/usr/bin/env bash
# scripts/lib/git-test-env.sh -- pin git settings for throwaway test fixtures.
#
# SOURCED, never executed. bash 3.2-safe (no mapfile, no associative arrays).
#
# SAFETY ARGUMENT: this lib touches ONLY git's GIT_CONFIG_COUNT /
# GIT_CONFIG_KEY_n / GIT_CONFIG_VALUE_n environment block -- the inline-config
# mechanism `git` reads at the start of every process. It makes NO `git config`
# call and writes NO config FILE anywhere, so the pins are PROCESS-SCOPED: they
# apply to the sourcing shell and the subprocesses it spawns (the test fixtures)
# and CANNOT leak into a real repo's stored .git/config. A fixture repo is free
# to call `git config` of its own; that writes the repo's config as usual and is
# unaffected by these env pins, which is exactly the separation a hermetic suite
# wants.
#
# WHY (HIMMEL-1589): himmel's shell suites build throwaway git repos
# (init/commit/clone) by the dozen, and git's fsync-per-object dominates their
# runtime. Measured on Windows over 15 init+commit+clone cycles: default 84.8s
# -> core.fsync=none + core.fsyncMethod=batch 32.9s -> plus empty
# init.templateDir 28.2s (3.0x). Process spawn is NOT the cost; fsync is.
# Pinning those three settings here lets every suite inherit them by sourcing
# this lib once, with no suite having to know the trick.
#
# USAGE (source it, then call):
#   . scripts/lib/git-test-env.sh
#   git_test_env_pin_perf        # fsync=none + fsyncMethod=batch + empty templateDir
#   git_test_env_append core.autocrlf false   # add one more pin on top

# git_test_env_append <key> <value>
# Appends ONE setting to git's GIT_CONFIG_* env block: reads the current count,
# writes KEY_n/VALUE_n at index n=count, then increments the count.
#
# APPENDS, never assigns: a caller that already pinned a setting must not lose
# it. The old hardcode in scripts/test-propagate-public.sh
# (`export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.autocrlf ...`) would silently
# discard anything a caller pinned above it; this function is the fix.
#
# GIT_CONFIG_COUNT may be inherited, unset, empty, or (if some caller hand-rolled
# the block wrong) non-numeric. A non-numeric count is treated as 0 rather than
# handed to arithmetic -- `$(( $x ))` on a bad value errors under `set -e` and
# `$(( 08 ))` dies as an invalid octal, both of which would make a fixture fail
# for a reason unrelated to what it tests. `10#` forces base 10 on the good path.
git_test_env_append() {
  local key="$1" value="$2" _n
  case "${GIT_CONFIG_COUNT:-}" in
    ''|*[!0-9]*)
      _n=0
      ;;
    *)
      _n=$(( 10#${GIT_CONFIG_COUNT} ))
      ;;
  esac
  export "GIT_CONFIG_KEY_${_n}=${key}"
  export "GIT_CONFIG_VALUE_${_n}=${value}"
  export GIT_CONFIG_COUNT=$(( _n + 1 ))
}

# git_test_env_pin_perf
# Appends the three settings that make throwaway test fixtures fast:
#   core.fsync=none        -- skip fsync-per-object (the dominant cost on Windows)
#   core.fsyncMethod=batch -- fsync once per batched group instead of per object
#   init.templateDir=      -- empty template dir; do not copy the default hook
#                             samples into every fixture's .git/hooks
#
# Idempotent: guarded by an EXPORTED marker so a runner pins once and every
# suite it spawns inherits BOTH the settings and the marker without appending a
# duplicate (a duplicate would still be harmless -- git applies the last value
# for a key -- but the marker keeps the count honest and the intent readable).
git_test_env_pin_perf() {
  [ "${HIMMEL_GIT_TEST_ENV_PERF:-0}" = "1" ] && return 0
  git_test_env_append core.fsync none
  git_test_env_append core.fsyncMethod batch
  git_test_env_append init.templateDir ''
  export HIMMEL_GIT_TEST_ENV_PERF=1
}
