#!/usr/bin/env bash
# kill-tree.sh — HIMMEL-2514. Sourceable process-tree killer, split out of
# claude-headless.sh's inline `kill_tree` so it is independently testable
# (claude-headless.sh itself is not sourceable — it validates argv and exits
# on failure at parse time).
#
# The original inline version forked a FRESH `ps -eo pid=,ppid=` at every
# recursion level, each fork sitting inside its own `| while` pipeline
# subshell, with no visited set and no depth bound. Under a busy process
# table (the exact conditions of the 2026-09-04 incidents this ticket
# tracks) that meant dozens of `ps` forks per kill plus unbounded recursion
# on any cyclic/racing ppid entry — and is what produced the bash SIGSEGV
# observed both times.
#
# CR round 1 (verified): a SINGLE snapshot fixes the fork-storm and the
# cycle/depth hazards, but narrows correctness — a process forked after the
# snapshot but before its parent is signalled is invisible to that one
# snapshot and survives. So this walks in bounded SWEEPS: each sweep takes
# ONE fresh `ps -eo pid=,ppid=` snapshot and walks the tree from the root
# again, via a here-string (never a `|` pipeline — a pipeline puts the walk
# in a subshell, which would silently drop the visited set the moment the
# loop exits). The cycle-guard visited set is reset at the START of every
# sweep, not shared across sweeps: sweep 2 must be free to re-descend
# through pids sweep 1 already walked, so it can reach a newly-forked
# grandchild visible only in sweep 2's snapshot. Re-signalling an
# already-dead pid is a harmless `kill -TERM ... || true` no-op, so no
# separate "already signalled" set is needed. Total `ps` forks per
# kill_tree() call is therefore exactly KILL_TREE_SWEEPS (default 2),
# independent of tree size — that bound is the property this ticket cares
# about.
#
# CR round 2 (verified, deferred as HIMMEL-2523, NOT fixed here): sweeping
# NARROWS the late-fork window, it does not CLOSE it. Signalling is
# post-order, so an earlier sweep can already have killed an intermediate
# parent by the time the next sweep re-snapshots; a child forked after that
# parent died has reparented (typically to init) and is no longer reachable
# by walking down from the root at all. Closing this needs freeze-then-reap
# (SIGSTOP the tree, walk, then SIGTERM+SIGCONT) and a test built on a real
# nested process tree — a synthetic `ps` table cannot reproduce reparenting.
# Not a regression: the pre-fix inline version on main had the identical
# exposure.
#
# Bash 3.2 safe: no associative arrays, visited-set membership is a plain
# space-delimited string tested with a `case` glob.
#
# Depth 0 is the root itself; KILL_TREE_MAX_DEPTH=2 kills the root plus its
# first two generations and leaves deeper descendants alone, in EVERY
# sweep. Default 32 is a backstop against a cyclic/corrupt table, not a
# real-world ceiling.

KILL_TREE_MAX_DEPTH="${KILL_TREE_MAX_DEPTH:-32}"
KILL_TREE_SWEEPS="${KILL_TREE_SWEEPS:-2}"

_kill_tree_visited=""

# Validates a small numeric knob: rejects empty/non-digit values outright,
# and rejects anything longer than the ceiling's own digit count — checked
# by STRING LENGTH first so an arbitrarily long digit string (confirmed on
# this host: `[ 0 -lt 99999999999999999999 ]` errors, and an erroring `if`
# reads as false) never reaches a numeric `[ -gt ]`/`-lt` test itself. Only
# once the lengths are equal (both small) does it fall through to an actual
# numeric compare. A value below $5=minimum is rejected too (CR round 2:
# KILL_TREE_SWEEPS=0 validated clean under a ceiling-only check, so the
# sweep loop ran zero times and kill_tree signalled NOTHING, silently — the
# same failure class the ceiling exists to close, just from the other
# side); by this point `stripped` is already bounded by the ceiling check
# above, so the floor compare cannot itself error either. $1=name (for the
# warning) $2=value $3=ceiling $4=fallback $5=minimum. Echoes the validated
# value on stdout; warns once on stderr.
_kill_tree_validate_uint() {
  local name="$1" value="$2" ceiling="$3" fallback="$4" minimum="$5" stripped
  case "$value" in
    ''|*[!0-9]*)
      echo "kill-tree.sh: invalid $name '$value', falling back to $fallback" >&2
      printf '%s' "$fallback"
      return
      ;;
  esac
  stripped="${value#"${value%%[!0]*}"}"
  [ -n "$stripped" ] || stripped=0
  if [ "${#stripped}" -gt "${#ceiling}" ] || { [ "${#stripped}" -eq "${#ceiling}" ] && [ "$stripped" -gt "$ceiling" ]; }; then
    echo "kill-tree.sh: invalid $name '$value' (exceeds $ceiling), falling back to $fallback" >&2
    printf '%s' "$fallback"
    return
  fi
  if [ "$stripped" -lt "$minimum" ]; then
    echo "kill-tree.sh: invalid $name '$value' (below $minimum), falling back to $fallback" >&2
    printf '%s' "$fallback"
    return
  fi
  printf '%s' "$value"
}

# True if $1 is already in the visited set.
_kill_tree_seen() {
  case " $_kill_tree_visited " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# Walks the given sweep's snapshot in-process (post-order: descendants
# signalled before their parent). $1=pid $2=depth $3=snapshot.
_kill_tree_walk() {
  local pid="$1" depth="$2" snapshot="$3"
  local cpid ppid
  if [ "$depth" -lt "$KILL_TREE_MAX_DEPTH" ]; then
    while IFS=' ' read -r cpid ppid; do
      [ -n "$cpid" ] || continue
      [ "$ppid" = "$pid" ] || continue
      _kill_tree_seen "$cpid" && continue
      _kill_tree_visited="$_kill_tree_visited $cpid"
      _kill_tree_walk "$cpid" "$((depth + 1))" "$snapshot"
    done <<< "$snapshot"
  fi
  kill -TERM "$pid" 2>/dev/null || true
}

# Terminates the process tree rooted at $1, over KILL_TREE_SWEEPS sweeps.
# Refuses an implausible root (empty, non-numeric, or <= 1) without
# consulting `ps` at all — never walk from pid 0 or init. Always returns 0.
kill_tree() {
  local root="$1" snapshot sweep ps_status
  case "$root" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ "$root" -gt 1 ] || return 0

  # A non-numeric or absurdly large KILL_TREE_MAX_DEPTH/KILL_TREE_SWEEPS
  # makes the numeric tests below ERROR, and an erroring `if`/`while` reads
  # as false — the walk would silently degrade to killing only the root (or
  # running zero sweeps), leaving the whole descendant tree alive.
  # Validated here (not just at source time) so a value exported AFTER
  # sourcing this file is still caught.
  KILL_TREE_MAX_DEPTH="$(_kill_tree_validate_uint "KILL_TREE_MAX_DEPTH" "$KILL_TREE_MAX_DEPTH" 4096 32 0)"
  KILL_TREE_SWEEPS="$(_kill_tree_validate_uint "KILL_TREE_SWEEPS" "$KILL_TREE_SWEEPS" 16 2 1)"

  if command -v taskkill.exe >/dev/null 2>&1; then
    taskkill.exe //PID "$root" //T //F >/dev/null 2>&1 || true
  fi

  sweep=0
  while [ "$sweep" -lt "$KILL_TREE_SWEEPS" ]; do
    snapshot="$(ps -eo pid=,ppid= 2>/dev/null)"
    ps_status=$?
    # A missing/failing `ps` (nonzero status) or an empty snapshot both mean
    # the table could not be read — a `ps` that actually succeeded on a real
    # host is never empty (it lists at least itself and pid 1), so this
    # check cannot fire spuriously. Undetected, the walk below would just
    # find no children and read as a clean, complete kill of a childless
    # process; warn instead of silently discarding the whole descendant
    # tree along with the failure that hid it.
    if [ "$ps_status" -ne 0 ] || [ -z "$snapshot" ]; then
      echo "kill-tree.sh: ps snapshot failed for root pid $root, descendants may survive" >&2
    fi
    _kill_tree_visited="$root"
    _kill_tree_walk "$root" 0 "$snapshot"
    sweep=$((sweep + 1))
  done
  return 0
}
