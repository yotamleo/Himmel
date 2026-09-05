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
# git_test_env_repair
# Fail-safe self-repair for the GIT_CONFIG_* block. HIMMEL-2231: the originally
# reported failure -- `fatal: unable to parse command-line config` /
# `missing config value GIT_CONFIG_VALUE_n` -- has exactly ONE producer:
# GIT_CONFIG_COUNT names N entries but some index < N is missing its KEY or
# VALUE. THE ACTOR WAS NOT IDENTIFIED: environment variables cannot cross
# processes, so the ticket's "a racing `git -c` from a sibling process writes
# our git env" hypothesis is impossible, and six spawn paths were probed for
# an empty-value drop (bash->git, node->git, powershell->git,
# node->powershell->git, python subprocess->git, git->pre-commit-hook->git) --
# all six preserved it. So this is a DEFENSE at the one chokepoint every
# suite already routes through (git_test_env_pin_perf / git_test_env_append),
# not a diagnosis: it repairs the symptom regardless of what caused it.
#
# A SECOND producer (codex-2 review, this ticket): GIT_CONFIG_COUNT itself can
# be SET but not a value git will accept -- empty, or containing a non-digit
# (`GIT_CONFIG_COUNT=abc` -> `error: bogus count in GIT_CONFIG_COUNT`). The
# truncation walk below needs a valid integer to walk UP TO, so it cannot
# repair this case -- treating it as count=0 (the old behaviour) made the walk
# a no-op and left the malformed value exported, so every later `git` call in
# the process still fatals. See the malformed-count branch below.
#
# Presence, not non-emptiness: an eval'd `${VAR+set}` check (bash-3.2-safe
# indirection -- no namerefs), so a LEGITIMATELY empty value (the historical
# init.templateDir='' fallback below) still counts as present.
#
# On the first missing index, truncates the block there -- drops the corrupt
# tail by setting GIT_CONFIG_COUNT to that index and unsetting every
# KEY_n/VALUE_n at or above it -- and prints ONE line to stderr. LOUD, never
# silent: a run that quietly lost a pin is a run whose timings nobody can
# explain. Always returns 0 -- this is a repair, not a gate.
git_test_env_repair() {
  local _count _i _keyname _valname _missing=-1 _bound

  # UNSET entirely is the normal first-call state -- no suite has pinned
  # anything yet, so there is nothing to repair. Return quietly: printing here
  # would make the repair noisy on every clean invocation, and this is not
  # corruption.
  if [ -z "${GIT_CONFIG_COUNT+set}" ]; then
    return 0
  fi

  case "${GIT_CONFIG_COUNT}" in
    ''|*[!0-9]*)
      # SET but malformed -- git itself rejects this value outright, before
      # it ever gets to per-index config parsing, so there is no count to
      # truncate to. Blow the whole block away instead of guessing: unsetting
      # GIT_CONFIG_COUNT is the pristine no-inline-config state (identical to
      # a shell that never pinned anything), which is a cleaner target than
      # exporting 0 -- 0 is still a value git has to parse, unset is not.
      printf 'WARN (HIMMEL-2231): GIT_CONFIG_COUNT is malformed (%s) -- unsetting the GIT_CONFIG block\n' \
        "$GIT_CONFIG_COUNT" >&2
      unset GIT_CONFIG_COUNT
      # A malformed COUNT gives no int to bound a walk by, so we cannot know
      # how many KEY_n/VALUE_n indices it meant to cover. Walk upward from 0,
      # unsetting whichever of KEY_n/VALUE_n is present at each index, and
      # stop at the first index where NEITHER is present -- deterministic and
      # conservative. Bounded at 1000 so a pathological environment (e.g. a
      # stray GIT_CONFIG_KEY_99999) cannot spin this forever; an unbounded
      # walk has no natural stopping point once COUNT itself can't be trusted.
      _i=0
      _bound=1000
      while [ "$_i" -lt "$_bound" ]; do
        _keyname="GIT_CONFIG_KEY_${_i}"
        _valname="GIT_CONFIG_VALUE_${_i}"
        if eval "[ \"\${${_keyname}+set}\" = set ]" || eval "[ \"\${${_valname}+set}\" = set ]"; then
          unset "$_keyname" "$_valname"
        else
          break
        fi
        _i=$(( _i + 1 ))
      done
      # A blown-away block may have dropped a pin git_test_env_pin_perf
      # already believes it applied -- clear the marker so the next
      # git_test_env_pin_perf call re-pins instead of returning early on a
      # marker whose pins no longer exist. (git_test_env_pin_perf calls this
      # function BEFORE checking the marker, so clearing it here does result
      # in a re-pin on that same call.)
      unset HIMMEL_GIT_TEST_ENV_PERF
      return 0
      ;;
    *)
      _count=$(( 10#${GIT_CONFIG_COUNT} ))
      ;;
  esac
  _i=0
  while [ "$_i" -lt "$_count" ]; do
    _keyname="GIT_CONFIG_KEY_${_i}"
    _valname="GIT_CONFIG_VALUE_${_i}"
    if ! eval "[ \"\${${_keyname}+set}\" = set ]" || ! eval "[ \"\${${_valname}+set}\" = set ]"; then
      _missing=$_i
      break
    fi
    _i=$(( _i + 1 ))
  done

  if [ "$_missing" -ge 0 ]; then
    printf 'WARN (HIMMEL-2231): GIT_CONFIG block corrupt -- GIT_CONFIG_COUNT=%s but index %s is missing its KEY or VALUE; truncating to GIT_CONFIG_COUNT=%s\n' \
      "$GIT_CONFIG_COUNT" "$_missing" "$_missing" >&2
    export GIT_CONFIG_COUNT="$_missing"
    _i=$_missing
    while [ "$_i" -lt "$_count" ]; do
      unset "GIT_CONFIG_KEY_${_i}" "GIT_CONFIG_VALUE_${_i}"
      _i=$(( _i + 1 ))
    done
    # A truncated block may have dropped a pin git_test_env_pin_perf already
    # believes it applied -- its marker only proves it RAN once, not that the
    # block it produced survived -- so clear the marker to force the next
    # git_test_env_pin_perf call to re-append instead of skipping.
    unset HIMMEL_GIT_TEST_ENV_PERF
  fi
  return 0
}

git_test_env_append() {
  local key="$1" value="$2" _n
  git_test_env_repair
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
#   init.templateDir=<dir> -- an empty directory; do not copy the default hook
#                             samples into every fixture's .git/hooks
#
# Idempotent: guarded by an EXPORTED marker so a runner pins once and every
# suite it spawns inherits BOTH the settings and the marker without appending a
# duplicate (a duplicate would still be harmless -- git applies the last value
# for a key -- but the marker keeps the count honest and the intent readable).
git_test_env_pin_perf() {
  git_test_env_repair
  [ "${HIMMEL_GIT_TEST_ENV_PERF:-0}" = "1" ] && return 0
  git_test_env_append core.fsync none
  git_test_env_append core.fsyncMethod batch
  # HIMMEL-2231: init.templateDir used to be pinned to '' -- the ONLY entry in
  # this block with an EMPTY value, and an empty-valued entry is the fragile
  # member of a count-indexed contract (git_test_env_repair above exists
  # because SOME actor, never identified, drops or normalises an entry). A
  # real, empty directory gets git the identical behaviour (no hook samples
  # copied in) with a non-empty value, removing the one entry a drop could
  # eat. Falls back to the historical '' only if the directory cannot be
  # created -- a hygiene nicety must never break a suite -- and only AFTER
  # trying, never silently preferring the fallback.
  #
  # REVIEW FINDING (codex critic, this branch): the first cut of this fix used
  # a FIXED, PREDICTABLE path (${TMPDIR:-/tmp}/himmel-git-empty-template),
  # never cleaned up. `git init` COPIES init.templateDir's contents into every
  # new repo's .git/ -- including hooks/, where anything executable becomes a
  # git hook that runs on ordinary git operations. A guessable name in a
  # shared, world-writable temp dir means any other process, or a stale
  # leftover, could pre-populate it, and that gets copied into every
  # throwaway fixture repo every suite builds. Fixed by making the directory
  # unpredictable AND fresh: mktemp -d creates it atomically with a random
  # suffix nothing can guess or pre-seed, so it is empty by construction.
  #
  # Lifetime: this directory intentionally OUTLIVES git_test_env_pin_perf --
  # it must still exist for every child process this runner spawns (they
  # inherit the pinned path and run `git init` against it), so nothing here
  # traps or deletes it. That leaks one empty directory per pinning process;
  # accepted trade-off (the alternative is a templateDir that goes missing
  # mid-run). scripts/ci/tmp-sweep.sh already collects leftovers like this.
  local _tmpl_dir _tmpl_val
  if _tmpl_dir=$(mktemp -d "${TMPDIR:-/tmp}/himmel-git-empty-template.XXXXXX" 2>/dev/null); then
    _tmpl_val="$_tmpl_dir"
    # Mixed form (C:/Users/...), same convention as
    # scripts/hooks/test-ci-doc-invariants.sh's `cygpath -m` -- git on
    # Windows accepts a POSIX-style path here too, but the mixed form is the
    # local idiom for a path handed to git config.
    if command -v cygpath >/dev/null 2>&1; then
      _tmpl_val=$(cygpath -m "$_tmpl_dir" 2>/dev/null) || _tmpl_val="$_tmpl_dir"
    fi
    git_test_env_append init.templateDir "$_tmpl_val"
  else
    git_test_env_append init.templateDir ''
  fi
  export HIMMEL_GIT_TEST_ENV_PERF=1
}
