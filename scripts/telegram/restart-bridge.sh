#!/usr/bin/env bash
# restart-bridge.sh — POSIX twin of restart-bridge.ps1 (HIMMEL-2176 Task 9, A12).
# Safely (re)starts the Telegram bun bridge on Linux/macOS.
#
# PARITY HONESTY (spec-mandated — do not silently overclaim, and equally: do
# not keep disclaiming what we now have). This script ships happy-path
# start/run/stop/status, the stale-lock recovery flock gives for free (see
# below), AND — since HIMMEL-2551 — a pidfile ledger consulted as an identity
# source WITH a staleness refusal: a recorded pid whose process started after
# the ledger was written is refused, the same class of guard as the PS1's
# Test-LedgerPidValid. That much is no longer a parity gap.
#
# Still NOT implemented, and still tracked as HIMMEL-2268 (not silently
# dropped): the `-FromLedger` VERB itself (a ledger-driven dry-run/kill mode),
# orphan `bun server.ts` detection, and the offset/heartbeat progress-proof
# verify after launch — so this script still does not prove no-409/real
# progress once the supervisor is up (HIMMEL-1509/1510/1519/1520).
#
# Usage:
#   restart-bridge.sh [start|stop|status|run] [--repo <path>]
#   restart-bridge.sh --print-lock-path      # print the lock path, do nothing else
#
# `run` is `start` without the detach: it takes the same lock and does the same
# instance-scoped stale sweep, then EXECs the supervisor in the foreground so a
# process supervisor (systemd Type=simple) tracks the supervisor itself as the
# unit's MAINPID and can restart it when it dies. `start` remains the detached
# launcher an interactive operator wants.
#
# LOCK PATH FORMULA (pinned — a sibling TypeScript consumer, onboard.ts task
# 10, cross-checks its own derivation against this exact formula):
#   ${BRIDGE_LOCK_DIR:-<bridgeRoot>}/bridge-<first 16 hex chars of sha256(token)>.lock
#   where <bridgeRoot> = ${BRIDGE_ROOT:-$HOME/.claude/handover/bridge}
# The token is read from $TELEGRAM_BOT_TOKEN if set (test seam), else parsed
# from $HOME/.claude/channels/telegram/.env. The lock is TOKEN-scoped, never
# the raw token: only its hash appears on disk/in the path.
#
# STALE-LOCK RECOVERY: flock(2) ties a lock to the fd/process holding it. If
# that process is killed — even SIGKILL — the kernel closes its fds and the
# advisory lock is released immediately; the next start/stop's `flock 200`
# acquires it right away. Nothing here proactively unlinks the lock FILE
# (only the lock, not the file, matters) — the leftover file is harmless
# (empty, no content, re-opened/re-locked next time) and unlinking it would
# open a create/flock race with a concurrent acquirer.
#
# flock ABSENCE (macOS ships none by default; also absent on this repo's
# Windows Git Bash dev host): degrades LOUDLY (one WARNING to stderr naming
# the limitation), never silently. Stale-proc kill and start/stop/status
# still work — only the concurrent-start serialization is lost.
#
# Stale-PROC kill (INSTANCE-SCOPED — HIMMEL-2551): `start`/`run` sweep, and
# `stop` kills, ONLY processes belonging to THIS instance. Entrypoint-name
# matching (`supervisor.ts` / `poller.ts`) narrows the CANDIDATE set; it is not
# by itself an ownership test — every himmel checkout on a machine runs the
# same two entrypoint names, so name-matching alone made a sandboxed test
# fixture's first `start` SIGKILL the operator's live production bridge (proven
# 2026-09-05: test-restart-bridge.sh killed supervisor/poller and still
# reported "17 passed, 0 failed"). A candidate is killed only when it is
# also OURS, by either of two independent identity sources:
#   1. the pidfile ledger <bridgeRoot>/supervisor.pid, which supervisor.ts
#      writes as {"supervisor":<pid>,"poller":<pid|null>} — honoured only when
#      the entry is not STALE (see ledger_entry_fresh);
#   2. its working directory == this instance's $BRIDGE_DIR (start/run launch
#      the supervisor with `cd "$BRIDGE_DIR"`, and the poller child inherits
#      that cwd) — which is what preserves stale-ORPHAN recovery, since an
#      orphan predates the current pidfile but still carries the cwd.
# A candidate whose cwd cannot be read and which is not in the pidfile is NOT
# killed: it degrades LOUDLY (a named stderr WARNING), never silently, and
# never fails open.
#
# WHAT THIS COSTS. Read it off the rule, not off an intuition about
# "instances". A process is OURS iff its cwd is our $BRIDGE_DIR
# (= <repo>/scripts/telegram), OR it is recorded in our pidfile ledger (under
# bridgeRoot = ${BRIDGE_ROOT:-$HOME/.claude/handover/bridge}) and that entry is
# not STALE — the process did not start after the pidfile was written. Three
# consequences, all of them intended:
#
#   * Same CHECKOUT (any roots) => one instance to each other, via the cwd.
#     They sweep each other; one-poller-per-token preserved.
#   * Same ROOT (any checkouts) => one instance to each other, via a live,
#     non-stale ledger entry. This is the ordinary local case: a git worktree
#     and the primary checkout under one $HOME have DIFFERENT bridge dirs but
#     ONE supervisor.pid. They sweep each other; one-poller-per-token
#     preserved.
#   * Only when the roots AND the checkouts BOTH differ are the two isolated.
#     They can then run concurrently, and on the SAME TELEGRAM_BOT_TOKEN both
#     will poll getUpdates and Telegram will return 409 Conflict to one of
#     them. That is a real, narrow behaviour change, and it is deliberate: the
#     only thing that previously "prevented" it was the indiscriminate
#     machine-wide kill this ticket removes — silently killing a process we
#     cannot attribute, to paper over an operator misconfiguration. Instead the
#     mutating verbs print ONE non-destructive WARNING naming how many foreign
#     bridge processes were left alone (see list_bridge_pids). The shared token
#     itself cannot be detected: there is no portable way to read another
#     process's environment.
#
# The STALENESS check is what makes both halves safe at once, and it is not
# novel here: restart-bridge.ps1's Test-LedgerPidValid already refuses any
# ledger pid whose process was created after the ledger was written. Without
# it, honouring the ledger across checkouts would license SIGKILLing another
# checkout's supervisor that merely inherited a recycled pid; without honouring
# the ledger at all, a worktree and the primary checkout stop seeing each other
# and both poll one token. Staleness, not cwd, separates those two cases.
#
# LAUNCH HANDOFF (HIMMEL-2556) — why a marker file exists. The lock is
# released before the process we just launched is VISIBLE to process discovery,
# and closing that gap by holding the lock is not available: `run` execs into
# the supervisor (fd 200 must be closed first or a later blocking `stop`
# deadlocks — see run_verb), and `start`'s own lock dies with the script
# process milliseconds after `nohup … &`. During that interval the future
# supervisor is not yet a `bun supervisor.ts`, so list_bridge_pids — whose
# candidate set is `ps`-derived — cannot see it, and a concurrent `start` finds
# nothing to sweep and launches a DUPLICATE. Two pollers on one token means
# Telegram returns 409 Conflict to one of them.
#
# So both verbs write <bridgeRoot>/supervisor.launching = "<pid> <epoch>" while
# still under the lock, naming the pid that is ABOUT to become the supervisor
# (`$$` for `run`, which execs and keeps its pid; the backgrounded child's pid
# for `start`, which likewise keeps its pid through nohup's exec). A launcher
# that takes the lock and finds an ACTIVE marker neither sweeps nor launches:
# it reports the in-flight launch and exits rc=4.
#
# ACTIVE means all three, and each one is a way the marker refuses to wedge a
# later start (a marker that outlives its launch must never be able to lock the
# bridge out permanently):
#   * the pid is still alive (`ps -p`) — a crashed launcher's marker is dead on
#     arrival;
#   * its age can be COMPUTED and is younger than LAUNCH_MARKER_MAX_AGE_SEC —
#     the backstop for a launcher that hangs before exec'ing, or a recycled
#     pid. An age that CANNOT be computed — a non-numeric epoch, an
#     unreadable clock, or a NEGATIVE age from a clock stepped backwards —
#     retires the marker rather than extending it: it reads INACTIVE, exactly
#     as if it had aged out, not active-forever (CR round 2 [codex-1] — an
#     earlier version of this bound SKIPPED the test instead when it could
#     not be computed, which left the marker active for as long as its pid
#     stayed alive and undiscovered; that is precisely the hang-before-exec
#     case this bound exists to catch, since pid-liveness and the discovery
#     check both hold for a hung launcher too). The direction — INACTIVE, not
#     ACTIVE, when unboundable — is the same asymmetry this file has already
#     decided twice elsewhere (list_bridge_pids' mtime-before-contents read
#     order, the foreign-candidate refusal): a duplicate poller costs a
#     recoverable, visible `409`; a marker that can never age out could wedge
#     the bridge PERMANENTLY, which is worse and is not recoverable by
#     retrying. Degrades LOUDLY when it fires — one named WARNING — matching
#     write_launch_marker's own CR round 1 degrade below;
#   * the pid is NOT already in the discovery set — the moment the supervisor
#     is visible the marker has done its job and stops blocking, which is what
#     keeps `start` twice in a row still meaning "sweep and relaunch".
# An inactive marker is IGNORED and REMOVED by the next mutating verb. If the
# marker cannot be WRITTEN at all (an unwritable bridge root, a full disk),
# write_launch_marker degrades LOUDLY — one named WARNING — rather than
# silently: the launch still proceeds (this file never aborts a launch for a
# lost guard), but handoff protection is disabled for that one launch, so a
# concurrent start during the window could create a duplicate bridge.
#
# ORDERING, not just pid-liveness, is what keeps a REFUSED or FAILED launch
# from leaving an active marker sitting around for up to
# LAUNCH_MARKER_MAX_AGE_SEC. Both verbs write the marker AFTER every early
# `exit` they can still take (bun resolution, sweep_stale) — so a launch that
# fails before that point never writes a marker at all — but the two verbs
# place the write differently, for a reason each one's own comment states:
#   * `start_verb` writes it immediately after the `nohup … &` line that
#     backgrounds the child — i.e. immediately AFTER the detach, with nothing
#     failable in between, since the detach already happened by the time the
#     write runs;
#   * `run_verb` writes it immediately BEFORE the lock fd is closed — i.e.
#     BEFORE, not adjacent to, its own `exec` — because that is the one point
#     still under the lock (fd 200 still open), which is what makes the
#     marker visible to a launcher that is *already blocked waiting* on that
#     same lock the instant it acquires it. Writing it later, after the fd
#     close, would release the lock BEFORE the marker exists — reopening
#     exactly the race this ticket closes, and widening it past the closed
#     `flock`'s own release, since a `run` that failed anywhere between the
#     fd close and the final `exec` would leave no marker at all for a
#     concurrent launcher already inside the (now unlocked) critical section.
# Pid-liveness (the ACTIVE rule's first bullet) alone does NOT substitute for
# either placement: a marker written before some in-between step that then
# fails would name a pid that stays alive but was never going to become a
# supervisor — liveness alone would hold that marker ACTIVE, and therefore
# block launches, for the full age window. The ordering rule is what prevents
# such a marker from being written too early or too late; once a marker DOES
# exist, pid-liveness is what retires it promptly if its process dies outright
# (e.g. this shell dying between the marker write and the final `exec`, or a
# launch that failed AFTER exec, such as a bad `bun supervisor.ts`
# invocation) — the two are complementary, not substitutes for each other.
# refuse_if_launch_in_progress itself never writes a marker on its own
# refusal path (only start_verb/run_verb do, around their own launch), so a
# launcher refused with rc=4 cannot disturb the very marker that caused the
# refusal.
#
# The marker is consulted by the VERBS, deliberately not folded into
# list_bridge_pids' output: that output feeds kill_bridge_pids, so a marker pid
# there would be a licence to SIGKILL a process we have not yet confirmed is a
# bridge at all. Refusing to launch is fail-safe; killing is not.
#
# Marker scope is the bridge ROOT, exactly like supervisor.pid — so two
# instances sharing a root serialise their handoffs, and two that share neither
# root nor checkout do not, which is the same isolation (and the same accepted
# 409) the ledger already documents above.
#
# Exit codes: 0 = ok · 1 = env/usage error · 2 = unknown argument ·
# 3 = refused under HIMMEL_TEST_FIXTURE=1, for EITHER of two reasons: no
#     BRIDGE_ROOT is set, or --repo points at a REAL checkout (any directory
#     inside a git work tree, the launcher's own included) — see the guard
#     below. ·
# 4 = refused because another launcher's handoff is still in flight (see
#     LAUNCH HANDOFF above); nothing was swept and nothing was launched.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: restart-bridge.sh [start|stop|status|run] [--repo <path>]
       restart-bridge.sh --print-lock-path

  start   kill this instance's stale bridge procs, then launch ONE detached supervisor
  run     same, but exec the supervisor in the FOREGROUND (systemd Type=simple)
  stop    kill this instance's bridge procs
  status  report this instance's bridge procs; touches nothing

Exit codes: 0 ok · 1 env/usage error · 2 unknown argument · 3 refused under
HIMMEL_TEST_FIXTURE=1 (no BRIDGE_ROOT set, or --repo pointing at a real
checkout — any directory inside a git work tree) · 4 refused: another
launcher's handoff is in flight.
EOF
}

VERB="start"
REPO_OVERRIDE=""
PRINT_LOCK_PATH=0
while [ $# -gt 0 ]; do
  case "$1" in
    start|stop|status|run) VERB="$1"; shift ;;
    --repo) REPO_OVERRIDE="${2:-}"; shift 2 ;;
    --repo=*) REPO_OVERRIDE="${1#--repo=}"; shift ;;
    --print-lock-path) PRINT_LOCK_PATH=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[restart-bridge] unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

bridge_root() { printf '%s' "${BRIDGE_ROOT:-$HOME/.claude/handover/bridge}"; }
lock_dir()    { printf '%s' "${BRIDGE_LOCK_DIR:-$(bridge_root)}"; }

# resolve_token — $TELEGRAM_BOT_TOKEN wins (test/override seam); else parsed
# from the bridge's own .env. Prints the token on stdout, rc=1 if none found.
resolve_token() {
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
    printf '%s' "$TELEGRAM_BOT_TOKEN"
    return 0
  fi
  local env_file="$HOME/.claude/channels/telegram/.env" line val
  [ -f "$env_file" ] || return 1
  line=$(grep -E '^TELEGRAM_BOT_TOKEN=' "$env_file" | tail -n1) || true
  [ -n "$line" ] || return 1
  val="${line#TELEGRAM_BOT_TOKEN=}"
  val="${val%\"}"; val="${val#\"}"
  val="${val%\'}"; val="${val#\'}"
  [ -n "$val" ] || return 1
  printf '%s' "$val"
  return 0
}

# hash_token — sha256 hex digest of stdin-free arg $1, via whichever hasher
# the host has (sha256sum, shasum -a 256, openssl dgst -sha256).
hash_token() {
  local token="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$token" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$token" | shasum -a 256 | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    printf '%s' "$token" | openssl dgst -sha256 -r | awk '{print $1}'
  else
    echo "[restart-bridge] FATAL: no sha256 utility found (sha256sum/shasum/openssl) — cannot derive the token-scoped lock path" >&2
    return 1
  fi
}

lock_path_for_token() {
  local token="$1" hash
  hash=$(hash_token "$token") || return 1
  printf '%s/bridge-%s.lock' "$(lock_dir)" "${hash:0:16}"
}

if [ "$PRINT_LOCK_PATH" -eq 1 ]; then
  token=$(resolve_token) || {
    echo "[restart-bridge] --print-lock-path: no TELEGRAM_BOT_TOKEN available (set TELEGRAM_BOT_TOKEN or populate \$HOME/.claude/channels/telegram/.env)" >&2
    exit 1
  }
  lock_path_for_token "$token"
  exit 0
fi

resolve_repo() {
  if [ -n "$REPO_OVERRIDE" ]; then printf '%s' "$REPO_OVERRIDE"; return 0; fi
  if [ -n "${HIMMEL_REPO:-}" ]; then printf '%s' "$HIMMEL_REPO"; return 0; fi
  local script_dir
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  (cd "$script_dir/../.." && pwd)
}

REPO=$(resolve_repo)
BRIDGE_DIR="$REPO/scripts/telegram"
LOG="$HOME/.claude/channels/telegram/supervisor.log"

if [ ! -f "$BRIDGE_DIR/supervisor.ts" ]; then
  echo "[restart-bridge] supervisor.ts not found under $BRIDGE_DIR — pass --repo <himmel root>." >&2
  exit 1
fi

# BRIDGE_DIR_REAL — the canonical (symlink-resolved) bridge dir this instance
# launches from, and therefore the cwd its supervisor/poller carry. The `-f`
# check just above guarantees the directory exists, so the `cd` succeeds; the
# fallback keeps a pathological failure from aborting under `set -e`.
BRIDGE_DIR_REAL=$(cd "$BRIDGE_DIR" 2>/dev/null && pwd -P) || BRIDGE_DIR_REAL=""
[ -n "$BRIDGE_DIR_REAL" ] || BRIDGE_DIR_REAL="$BRIDGE_DIR"

# path_inside_work_tree <dir> — rc=0 when <dir> sits inside a git work tree,
# found by walking up to the filesystem root looking for a `.git` entry. `-e`
# rather than `-d` on purpose: a normal clone has a `.git` DIRECTORY, while a
# linked worktree or a submodule has a `.git` FILE. Pure shell, bash 3.2-safe,
# no `git` binary — which is the point: the fixture guard that uses it must not
# have a host-dependent way to stop guarding (see there).
#
# Fail-closed by construction: if a scratch dir somehow sits under a git work
# tree (e.g. a TMPDIR inside a git-managed $HOME), a fixture is REFUSED with a
# message naming the directory, rather than quietly permitted. Loud and
# fixable beats silent and dangerous.
path_inside_work_tree() {
  local d="$1" parent
  [ -n "$d" ] || return 1
  while [ -n "$d" ]; do
    if [ -e "$d/.git" ]; then return 0; fi
    parent=$(dirname "$d")
    if [ "$parent" = "$d" ]; then break; fi
    d="$parent"
  done
  return 1
}

# SELF_BRIDGE_DIR_REAL — the bridge dir of the checkout THIS script file lives
# in, resolved from its own path and therefore independent of --repo /
# $HIMMEL_REPO. Used only by the fixture guard below.
SELF_BRIDGE_DIR_REAL=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || SELF_BRIDGE_DIR_REAL=""

# HIMMEL_TEST_FIXTURE guard (HIMMEL-2551) — belt and braces over the instance
# scoping above, covering the two ways a fixture can still land on real state.
# `status` is read-only and `--print-lock-path` never touches a process, so
# only the mutating verbs refuse. rc=3 is reserved for this refusal.
if [ "${HIMMEL_TEST_FIXTURE:-}" = "1" ]; then
  case "$VERB" in
    start|stop|run)
      # (1) No sandboxed bridge root: identity source (1), the pidfile, would
      # be the operator's real one. This is the exact class of mistake behind
      # HIMMEL-2551, where a fixture sandboxed HOME but the process matcher
      # still reached the operator's live bridge.
      if [ -z "${BRIDGE_ROOT:-}" ]; then
        echo "[restart-bridge] REFUSING '$VERB': HIMMEL_TEST_FIXTURE=1 but BRIDGE_ROOT is unset, so this run would use the DEFAULT bridge root $HOME/.claude/handover/bridge — a real operator bridge, not a sandbox. A test fixture must export BRIDGE_ROOT (and HOME) to a scratch directory before invoking start/stop/run." >&2
        exit 3
      fi
      # (2) A sandboxed root but --repo pointed at a REAL checkout: identity
      # source (2), the cwd, then selects that checkout's live bridge processes
      # and kills them. The own-checkout case is the likeliest mistake, so it
      # keeps its own pointed message; but the CLASS is "any real checkout",
      # not just ours — a fixture aimed at a DIFFERENT clone passes an
      # own-checkout comparison and still kills a live bridge.
      if [ -n "$SELF_BRIDGE_DIR_REAL" ] && [ "$BRIDGE_DIR_REAL" = "$SELF_BRIDGE_DIR_REAL" ]; then
        echo "[restart-bridge] REFUSING '$VERB': HIMMEL_TEST_FIXTURE=1 and the target bridge dir ($BRIDGE_DIR_REAL) is the checkout this script itself lives in ($SELF_BRIDGE_DIR_REAL) — a fixture pointing --repo at its own checkout would kill that checkout's REAL bridge processes, sandboxed BRIDGE_ROOT or not. Point --repo at a scratch repo root containing scripts/telegram/supervisor.ts instead." >&2
        exit 3
      fi
      # The general limb: a genuine himmel checkout is inside a git work tree;
      # a fixture's bridge dir is a stub under a scratch directory and is not.
      # UNCONDITIONAL — deliberately not gated on a `git` binary. This ran
      # through `git rev-parse` briefly and degraded to the own-checkout
      # comparison when git was missing, which left a fixture aimed at some
      # OTHER clone completely unguarded on such a host. The runner exports
      # HIMMEL_TEST_FIXTURE=1 for EVERY suite, so this guard reads as
      # protection on machines we do not control; one that silently stops
      # guarding is worse than none. path_inside_work_tree needs no external
      # binary, so there is nothing left to degrade around.
      if path_inside_work_tree "$BRIDGE_DIR_REAL"; then
        echo "[restart-bridge] REFUSING '$VERB': HIMMEL_TEST_FIXTURE=1 and the target bridge dir ($BRIDGE_DIR_REAL) is inside a git work tree, i.e. a real checkout — whose live bridge processes this run would match by working directory and kill. A fixture must point --repo at a scratch repo root (not a git repo) containing scripts/telegram/supervisor.ts." >&2
        exit 3
      fi
      ;;
  esac
fi

# capture_ps_ef — `ps -ef` with the widest CMD column available. BSD-derived
# ps (macOS) truncates the last (CMD) column to terminal width even when
# stdout is a pipe/file; `-ww` requests unlimited width there. Not every
# `ps` accepts `-w` (this repo's Git Bash MSYS ps rejects it) — probe by
# trying `-ww` first and falling back to a bare `ps -ef` when it errors.
capture_ps_ef() {
  local out
  if out=$(ps -ww -ef 2>/dev/null); then
    printf '%s\n' "$out"
    return 0
  fi
  ps -ef 2>/dev/null
}

# proc_cwd <pid> — prints the process's working directory; rc=1 when this host
# cannot tell us (no readable /proc/<pid>/cwd, no `lsof`). /proc first (Linux);
# `lsof -d cwd` is the macOS path, which has no /proc at all.
proc_cwd() {
  local pid="$1" cwd=""
  if [ -r "/proc/$pid/cwd" ]; then
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || cwd=""
    if [ -n "$cwd" ]; then printf '%s' "$cwd"; return 0; fi
  fi
  if command -v lsof >/dev/null 2>&1; then
    cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | tail -n1) || cwd=""
    if [ -n "$cwd" ]; then printf '%s' "$cwd"; return 0; fi
  fi
  return 1
}

# INSTANCE_WARN_DONE — "already warned" flag, so the fail-safe below degrades
# LOUDLY but once, in the same spirit as the `flock`-absent WARNING, rather
# than one line per candidate pid. Scope, stated honestly rather than
# overclaimed: most callers run `list_bridge_pids` inside `$(...)`, which is a
# SUBSHELL, so the flag resets between calls — the warning is once per
# list_bridge_pids call, not once per process invocation. That is a handful of
# lines in the worst case (start sweeps, then kills), which is the point.
INSTANCE_WARN_DONE=0

# WARN_FOREIGN — armed only by the mutating verbs (see sweep_stale/stop_verb),
# so `status` stays a silent report.
WARN_FOREIGN=0

# proc_in_this_instance <pid> — TRI-STATE, because "not ours" and "cannot
# tell" must not be conflated (that conflation is what made a stale ledger
# entry able to outvote direct evidence):
#   rc=0  cwd readable and == this instance's bridge dir  -> OURS
#   rc=1  cwd readable and != it                          -> NOT ours (a VETO)
#   rc=2  cwd unreadable                                  -> unknown; one named
#         WARNING, and the caller falls back to the pidfile ledger.
proc_in_this_instance() {
  local pid="$1" cwd
  if ! cwd=$(proc_cwd "$pid"); then
    if [ "$INSTANCE_WARN_DONE" -eq 0 ]; then
      INSTANCE_WARN_DONE=1
      echo "[restart-bridge] WARNING: cannot read the working directory of bridge-shaped pid $pid (no readable /proc/<pid>/cwd and no 'lsof' on this host) — falling back to this instance's pidfile to decide whether it is ours. If it is not recorded there it is left ALONE rather than killed; stop a genuinely stale bridge process by hand." >&2
    fi
    return 2
  fi
  [ "$cwd" = "$BRIDGE_DIR_REAL" ]
}

# pidfile_pids — the pids THIS instance recorded in <bridgeRoot>/supervisor.pid
# ({"supervisor":<pid>,"poller":<pid|null>}), one per line. Always rc=0: an
# absent or corrupt pidfile simply yields nothing, and `"poller":null` yields
# no poller line, which is exactly right.
# NOTE (why this is not two bare `sed -n ... "$pf"` calls): supervisor.ts
# writes the pidfile with JSON.stringify and NO trailing newline, and `sed -n
# p` does not add one to a final line that lacked it — so two direct seds
# printed "<supervisor><poller>" concatenated on ONE line, and every membership
# comparison silently failed. Reading the file into a variable and re-emitting
# each pid with printf makes the line discipline ours, not the writer's.
pidfile_pids() {
  local pf content sup pol
  pf="$(bridge_root)/supervisor.pid"
  [ -f "$pf" ] || return 0
  content=$(cat "$pf" 2>/dev/null) || return 0
  sup=$(printf '%s\n' "$content" | sed -n 's/.*"supervisor"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p') || sup=""
  pol=$(printf '%s\n' "$content" | sed -n 's/.*"poller"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p') || pol=""
  if [ -n "$sup" ]; then printf '%s\n' "$sup"; fi
  if [ -n "$pol" ]; then printf '%s\n' "$pol"; fi
  return 0
}

# LEDGER_FRESH_TOLERANCE_SEC — slack in the staleness comparison below. DERIVED,
# not chosen; see ledger_entry_fresh for the arithmetic. Errors in the two
# directions are NOT symmetric: too small and a legitimately current entry reads
# STALE, which loses one-poller-per-token (a worktree and the primary checkout
# stop sweeping each other and both poll one token). Too large only widens an
# already-bounded pid-recycling window. So the value is the smallest bound that
# provably cannot produce the first error.
LEDGER_FRESH_TOLERANCE_SEC=3

# pidfile_mtime — epoch seconds of <bridgeRoot>/supervisor.pid; rc=1 when it
# cannot be read. Same GNU-then-BSD `stat` shape as py-armor.sh's
# py_armor_mtime and render-lease.sh's _render_lease_mtime; both are private
# helpers inside libraries this script does not (and should not) source for
# two lines of `stat`.
pidfile_mtime() {
  local f m=""
  f="$(bridge_root)/supervisor.pid"
  m=$(stat -c %Y "$f" 2>/dev/null) || m=""              # GNU
  if [ -z "$m" ]; then m=$(stat -f %m "$f" 2>/dev/null) || m=""; fi   # BSD/macOS
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$m"
}

# proc_start_epoch <pid> — epoch seconds at which the process started; rc=1
# when this host cannot tell us. GNU procps has `-o etimes=` (elapsed seconds,
# so start = now - etimes); BSD/macOS has no etimes but does have `-o lstart=`,
# parsed by BSD `date -j -f`.
proc_start_epoch() {
  local pid="$1" et="" now="" lstart="" s=""
  et=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d '[:space:]') || et=""
  case "$et" in
    ''|*[!0-9]*) ;;
    *)
      now=$(date +%s 2>/dev/null) || now=""
      case "$now" in
        ''|*[!0-9]*) ;;
        *) printf '%s' "$((now - et))"; return 0 ;;
      esac
      ;;
  esac
  lstart=$(ps -o lstart= -p "$pid" 2>/dev/null) || lstart=""
  if [ -n "$lstart" ]; then
    s=$(date -j -f '%a %b %e %H:%M:%S %Y' "$lstart" +%s 2>/dev/null) || s=""
    case "$s" in
      ''|*[!0-9]*) ;;
      *) printf '%s' "$s"; return 0 ;;
    esac
  fi
  return 1
}

# pid_in_ledger <pid> <recorded-pids> — bare membership, no judgement.
pid_in_ledger() {
  local pid="$1" recorded="$2" rec
  [ -n "$recorded" ] || return 1
  while IFS= read -r rec; do
    if [ "$rec" = "$pid" ]; then return 0; fi
  done <<EOF_REC
$recorded
EOF_REC
  return 1
}

# ledger_entry_fresh <pid> — rc=0 when this pid's ledger entry is NOT stale:
# the process did not start AFTER the pidfile was last written. Ported from
# restart-bridge.ps1's Test-LedgerPidValid, which refuses any ledger pid whose
# process CreationDate is later than the ledger's LastWriteTime — the
# recycled-pid guard. Our own supervisor rewrites the pidfile on every poller
# respawn, so for a genuinely current entry the mtime only ever moves FORWARD
# past the start time; a later start time means the pid was recycled after we
# recorded it.
#
# TRI-STATE, so "could not determine" is not silently collapsed into
# "determined fresh": rc=0 fresh · rc=1 stale · rc=2 undeterminable. What an
# undeterminable verdict is allowed to license is the CALLER's policy, not
# this helper's — see pid_belongs_to_instance.
#
# The mtime is a PARAMETER, captured once by the caller before the ledger's
# CONTENTS were read — see list_bridge_pids for why that ordering is
# load-bearing. Do not "simplify" this back to stat'ing the file here.
ledger_entry_fresh() {
  local pid="$1" mtime="$2" started fresh_cutoff
  [ -n "$mtime" ] || return 2
  started=$(proc_start_epoch "$pid") || return 2
  # TOLERANCE, derived. Both inputs truncate, and they truncate in directions
  # that ADD:
  #   * `stat` reports whole seconds, so the mtime we read is up to 1s BELOW
  #     the true mtime;
  #   * `ps -o etimes=` reports whole elapsed seconds, so `now - etimes`
  #     computes a start up to 1s LATER than the true start.
  # For a legitimately current entry (true start <= true mtime) those compose:
  # computed_start - reported_mtime < 2 + (the gap between the `ps` sample and
  # the `date +%s` read that follows it). That gap is two process spawns —
  # milliseconds — so one extra second covers it with room to spare. Hence 3;
  # 4 and 5 would only be slack.
  #
  # RESIDUAL, named rather than closed: a pid recycled INSIDE that 3-second
  # window still reads as fresh, so a same-numbered process could be claimed.
  # It is acceptable because pids are handed out sequentially — hitting one
  # specific pid again means wrapping the whole pid space
  # (/proc/sys/kernel/pid_max, 4194304 by default on Linux) within 3 seconds.
  fresh_cutoff=$((mtime + LEDGER_FRESH_TOLERANCE_SEC))
  [ "$started" -le "$fresh_cutoff" ]
}

# pid_belongs_to_instance <pid> <recorded-pids> — tri-state:
#   rc=0  ours     rc=1  foreign     rc=2  unknown (left alone)
#
# The two identity sources answer two DIFFERENT questions and both are needed;
# earlier rounds of this ticket each fixed one by breaking the other.
#   (1) cwd == our $BRIDGE_DIR  -> ours. Covers the same-CHECKOUT case, and is
#       what makes stale-ORPHAN recovery work (an orphan predates the pidfile).
#   (2) in our ledger AND that entry is not stale -> ours, EVEN when the cwd is
#       readable and different. Covers the same-BRIDGE_ROOT case: a worktree
#       and the primary checkout under one $HOME have different bridge dirs but
#       ONE supervisor.pid, and must still sweep each other or both poll the
#       same token. Skipping this (cwd only) loses one-poller-per-token;
#       trusting membership WITHOUT the staleness check licenses killing
#       another checkout's supervisor that merely inherited a recycled pid.
#       Staleness — not cwd — is the discriminator between those two.
# Only when neither holds does a readable, mismatching cwd mean FOREIGN.
#
# When freshness cannot be DETERMINED (no usable stat/ps timestamps), bare
# membership licenses ownership only where there is no cwd evidence against it
# — i.e. the cwd was unreadable too (rc=2), which is the macOS/no-lsof host the
# degrade was written for: such a host must still be able to stop its own
# bridge. A readable cwd that MISMATCHES is evidence, and an undeterminable
# freshness verdict does not override it. The honest consequence: on a host
# that can read cwds but not timestamps, a shared-root instance stops being
# swept — we accept a possible 409 conflict rather than possibly SIGKILLing a
# stranger's bridge. That is the right direction: a 409 is recoverable and
# visible; killing someone else's live bridge is neither.
pid_belongs_to_instance() {
  local pid="$1" recorded="$2" ledger_mtime="$3" rc=0 frc=0
  proc_in_this_instance "$pid" || rc=$?
  if [ "$rc" -eq 0 ]; then return 0; fi
  if pid_in_ledger "$pid" "$recorded"; then
    ledger_entry_fresh "$pid" "$ledger_mtime" || frc=$?
    if [ "$frc" -eq 0 ]; then return 0; fi
    if [ "$frc" -eq 2 ] && [ "$rc" -eq 2 ]; then return 0; fi
  fi
  if [ "$rc" -eq 1 ]; then return 1; fi
  # rc=2: cwd unreadable and no usable ledger entry — nothing to go on.
  return 2
}

# list_bridge_pids — prints "<pid> <role>" lines (role: supervisor|poller) for
# every LIVE bun process running one of the bridge's own entrypoints, matched
# by entrypoint NAME (token-anchored, path-prefix-tolerant) — never a bare
# `bun` name match — AND belonging to THIS instance (HIMMEL-2551; see the
# header's instance rule). Never fails the caller under `set -e` (always rc=0).
list_bridge_pids() {
  local ef line pid role recorded ledger_mtime brc foreign=0
  ef=$(capture_ps_ef) || { return 0; }
  # ORDER IS LOAD-BEARING — mtime FIRST, then contents, each read ONCE per scan.
  # supervisor.ts rewrites the pidfile on every poller respawn, so a rewrite can
  # land in the middle of a scan; what matters is which way that error falls.
  #   contents-then-mtime (the natural-looking order): OLD pids compared against
  #     a NEWER mtime, so a dead, recycled pid reads FRESH and gets SIGKILLed —
  #     precisely the cross-instance kill this ticket exists to prevent.
  #   mtime-then-contents (this order): NEW contents compared against an OLDER
  #     mtime, so a genuinely current entry can read STALE — we decline to sweep
  #     and accept a possible 409. A recycled pid can no longer read fresh.
  # Same asymmetry as everywhere else here: a 409 is recoverable and visible;
  # killing a stranger's live bridge is neither. Do not "tidy" this back.
  ledger_mtime=$(pidfile_mtime) || ledger_mtime=""
  recorded=$(pidfile_pids) || recorded=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      *bun*) ;;
      *) continue ;;
    esac
    pid=$(printf '%s\n' "$line" | awk '{print $2}')
    case "$pid" in
      ''|*[!0-9]*) continue ;;
    esac
    role=""
    # HIMMEL-1430 (grep-q-pipe-under-pipefail): a piped `grep -q` under this
    # script's `set -o pipefail` can read a genuine MATCH as a pipeline
    # failure (grep -q exits on first match, the producer gets SIGPIPE
    # writing the rest, pipeline status goes non-zero) — this feeds `kill
    # -9`, so a misread decides which processes get killed, not cosmetic.
    # Here-strings aren't pipelines; a single ps line is far under Git
    # Bash's 64 KiB here-string wedge.
    if grep -qE '(^|[/\[:space:]])supervisor\.ts([[:space:]]|$)' <<< "$line"; then
      role="supervisor"
    elif grep -qE '(^|[/\[:space:]])poller\.ts([[:space:]]|$)' <<< "$line"; then
      role="poller"
    fi
    if [ -n "$role" ]; then
      brc=0
      pid_belongs_to_instance "$pid" "$recorded" "$ledger_mtime" || brc=$?
      if [ "$brc" -eq 0 ]; then
        printf '%s %s\n' "$pid" "$role"
      elif [ "$brc" -eq 1 ]; then
        foreign=$((foreign + 1))
      fi
    fi
  done <<EOF_PS
$ef
EOF_PS
  # Non-destructive visible signal (HIMMEL-2551): a bridge belonging to some
  # OTHER root is now left running rather than swept, so say so once — the
  # launcher no longer silently "fixes" a shared-token misconfiguration by
  # killing a process it cannot attribute. Deliberately worded distinctly from
  # the unreadable-cwd WARNING above, so a reader can tell which one fired.
  # Only the mutating verbs arm it; `status` is a report, not an intervention.
  if [ "$foreign" -gt 0 ] && [ "${WARN_FOREIGN:-0}" = "1" ]; then
    echo "[restart-bridge] WARNING: left $foreign bridge-shaped process(es) alone — they run from a different bridge dir than this instance ($BRIDGE_DIR_REAL), so they are not ours to kill. If they are another checkout using the SAME bot token, both will poll it and Telegram will return 409 Conflict to one of them: run exactly one bridge per token." >&2
  fi
  return 0
}

# kill_bridge_pids — SIGKILLs every pid list_bridge_pids currently finds;
# prints the count killed on stdout.
kill_bridge_pids() {
  local recs pid role killed=0
  recs=$(list_bridge_pids) || true
  if [ -n "$recs" ]; then
    while IFS=' ' read -r pid role; do
      [ -n "$pid" ] || continue
      if kill -9 "$pid" 2>/dev/null; then
        echo "[restart-bridge] killed stale $role pid $pid" >&2
        killed=$((killed + 1))
      fi
    done <<EOF_K
$recs
EOF_K
  fi
  printf '%s' "$killed"
  return 0
}

# LAUNCH_MARKER_MAX_AGE_SEC — the backstop half of launch_marker_active's
# ACTIVE rule (see the header's LAUNCH HANDOFF section). A plain constant: no
# env override, no test-only hook. This guard exists specifically to close a
# duplicate-bridge race, and a knob that let a caller shrink or disable the
# bound would be a knob that let a caller reopen exactly that race. 30s is
# generous on purpose — the real handoff is a fork+exec, sub-100ms: `nohup`
# execs bun immediately (`start`) or this process's own `exec` replaces its
# image immediately (`run`), and the cmdline `ps` reads is correct at exec
# time, before bun has done any initialisation. The bound is only ever reached
# by a launcher that hangs or dies before exec'ing — a case the pid-liveness
# check already mostly handles, so this is belt and braces, not the primary
# defense.
LAUNCH_MARKER_MAX_AGE_SEC=30

# launch_marker_path — <bridgeRoot>/supervisor.launching. Root-scoped, exactly
# like supervisor.pid: two instances sharing a root serialise their handoffs,
# two that share neither root nor checkout do not (see the header).
launch_marker_path() {
  printf '%s/supervisor.launching' "$(bridge_root)"
}

# write_launch_marker <pid> — records the pid ABOUT to become the supervisor
# as "<pid> <epoch>\n". `mkdir -p` on bridge_root, not just lock_dir:
# BRIDGE_LOCK_DIR may differ from BRIDGE_ROOT (see lock_dir()), so
# acquire_lock's own mkdir does not guarantee this directory exists. If `date`
# fails, the epoch field is written as "-" — launch_marker_active treats that
# as an unboundable age and retires the marker as INACTIVE (one WARNING),
# rather than extending it, so this launch simply runs without handoff
# protection; see launch_marker_active's own comment for why. Always rc=0: a
# marker we FAILED to write is a lost guard, not a reason to abort a launch we
# are already committed to (the lock is held and sweep_stale has already run)
# — the launch proceeds either way, just without the handoff protection on
# this one run.
#
# LOUD, not silent (CR round 1 [codex-1]): every other degrade in this file
# prints a named WARNING (flock absent, an unreadable cwd, an unattributable
# candidate left alone) — a silently-lost marker would be the one exception,
# and it is the exact degrade that disables the guard this file exists to
# add. So `mkdir`/the write are checked, and on EITHER failing this prints
# exactly one stderr WARNING naming the marker path and the concrete
# consequence, worded apart from the flock-absent and unreadable-cwd
# WARNINGs so a reader can tell which one fired. One warning per CALL, not
# per failed step, since a failed `mkdir` also fails the write that depends
# on it — printing for both would just be the same fact twice.
write_launch_marker() {
  local pid="$1" epoch marker mkdir_ok=1 write_ok=1
  marker="$(launch_marker_path)"
  # `|| mkdir_ok=0` (an assignment, always rc=0) rather than `|| true`: it
  # still swallows the failure for `set -e` purposes — nothing here may abort
  # the launch — but it also RECORDS that it happened, which `|| true`
  # cannot.
  mkdir -p "$(bridge_root)" 2>/dev/null || mkdir_ok=0
  epoch=$(date +%s 2>/dev/null) || epoch="-"
  if [ "$mkdir_ok" -eq 1 ]; then
    printf '%s %s\n' "$pid" "$epoch" > "$marker" 2>/dev/null || write_ok=0
  else
    write_ok=0
  fi
  if [ "$mkdir_ok" -eq 0 ] || [ "$write_ok" -eq 0 ]; then
    echo "[restart-bridge] WARNING: could not write the launch marker ($marker) — proceeding with the launch anyway, but handoff protection is DISABLED for this one launch: a concurrent start during the handoff window would find no marker there and could launch a DUPLICATE bridge (two pollers on one token → Telegram 409)." >&2
  fi
  return 0
}

# _launch_marker_age_unbound_warn <marker-path> <reason> — the CR round 2
# [codex-1] WARNING for launch_marker_active's age clause below: printed
# exactly once, only when (and because) an unboundable age is what makes a
# marker read INACTIVE rather than active-forever. A private helper so the
# three call sites below cannot drift out of the shared wording. Worded
# apart, deliberately, from write_launch_marker's CR round 1 WARNING (a
# failed WRITE) and from the flock-absent / unreadable-cwd WARNINGs
# elsewhere in this file, so a reader can tell which one fired.
_launch_marker_age_unbound_warn() {
  local marker="$1" reason="$2"
  echo "[restart-bridge] WARNING: the launch marker ($marker) has an unboundable age ($reason) — treating it as INACTIVE rather than leaving it active indefinitely: handoff protection for the launch that wrote it is disabled, so a concurrent start could now launch a duplicate bridge during that (unmeasurable) window. See the header's LAUNCH HANDOFF section for why an unboundable age retires the marker rather than extending it." >&2
}

# launch_marker_active — rc=0 and prints "<pid> <age>" on stdout (age always a
# non-negative integer of seconds — see (c) below for why it can no longer be
# anything else) when a launch is genuinely still in flight; rc=1 otherwise.
# Parsed with plain parameter expansion — bash 3.2-safe, no arrays, no
# `mapfile`. ALL of the following must hold, in order, each one a way the
# marker refuses to wedge a later start:
#   (a) the file exists and parses: pid is non-empty and all-digits;
#   (b) the pid is ALIVE — `ps -p`, NOT `kill -0`: EPERM (a process owned by
#       another user) would make `kill -0` read a live process as dead;
#   (c) its age can be COMPUTED and is within LAUNCH_MARKER_MAX_AGE_SEC — an
#       age this function CANNOT compute (a non-numeric epoch, an unreadable
#       clock) or that comes out NEGATIVE (the epoch is ahead of "now" — a
#       backward NTP step, or a bridge root shared across machines with
#       skewed clocks) makes the marker read INACTIVE, not active-forever
#       (CR round 2 [codex-1]; an earlier version of this clause SKIPPED the
#       test in all three cases instead, reasoning that (b) and (d) alone
#       still prevented a wedge — wrong in exactly the case this bound
#       exists for: a launcher that HANGS before exec'ing bun stays alive and
#       never enters the discovery set, so (b) and (d) both hold and only
#       the age bound can retire it. Direction, stated rather than assumed:
#       an unboundable age costs the handoff guard for ONE launch (a
#       duplicate poller, a recoverable, visible 409); the alternative — an
#       ACTIVE marker with no way to ever age out — could wedge the bridge
#       PERMANENTLY. Same asymmetry this file has already decided twice
#       (list_bridge_pids' mtime-before-contents read order, the
#       foreign-candidate refusal): a 409 is recoverable and visible, a
#       bridge that will not start is neither. Emits one WARNING via
#       _launch_marker_age_unbound_warn when this is what makes the marker
#       read inactive;
#   (d) the pid is NOT already in list_bridge_pids' discovery set — the
#       moment the supervisor is visible the marker has done its job, which is
#       what keeps a SECOND `start` still meaning "sweep and relaunch" rather
#       than refusing forever.
# MUST NOT be called from inside list_bridge_pids — this is one-way only
# (list_bridge_pids -> ok; this -> list_bridge_pids -> infinite recursion).
launch_marker_active() {
  local f content pid epoch now age recs rec role
  f="$(launch_marker_path)"
  [ -f "$f" ] || return 1
  content=$(cat "$f" 2>/dev/null) || return 1
  pid="${content%% *}"
  epoch="${content#* }"
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  ps -p "$pid" >/dev/null 2>&1 || return 1
  case "$epoch" in
    ''|*[!0-9]*)
      _launch_marker_age_unbound_warn "$f" "the marker's epoch field is unreadable"
      return 1
      ;;
  esac
  now=$(date +%s 2>/dev/null) || now=""
  case "$now" in
    ''|*[!0-9]*)
      _launch_marker_age_unbound_warn "$f" "the current clock could not be read"
      return 1
      ;;
  esac
  # 10#$epoch (CR round 4 [codex-1]) — the all-digits `case` above accepts
  # "08"/"09", which is a genuine crash path, not merely a wrong number: bash
  # arithmetic treats a leading-zero literal as OCTAL, and 08/09 are invalid
  # octal digits, so plain `$((now - epoch))` raises a hard evaluation error
  # that bypasses this file's usual `if`-guarded error handling entirely
  # (reproduced: it silently unwinds the whole call stack back to the
  # top-level script and hits ITS `exit 0`, so `start` reports SUCCESS while
  # never launching anything — worse than a loud crash). `10#` forces base-10
  # reading regardless of leading zeros; the `case` above still rejects
  # genuinely non-numeric input, so the two checks are complementary, not
  # redundant. Deliberately NOT applied to `now`: it comes from our own
  # `date +%s` call and cannot carry a leading zero, whereas `epoch` is read
  # back from a FILE — external input a corrupted or hand-edited marker
  # controls — which is exactly why only one of the two operands needs this.
  age=$((now - 10#$epoch))
  if [ "$age" -lt 0 ]; then
    _launch_marker_age_unbound_warn "$f" "the marker's epoch is ahead of the current clock, which would make the age negative"
    return 1
  fi
  if [ "$age" -gt "$LAUNCH_MARKER_MAX_AGE_SEC" ]; then return 1; fi
  recs=$(list_bridge_pids) || recs=""
  if [ -n "$recs" ]; then
    while IFS=' ' read -r rec role; do
      [ -n "$rec" ] || continue
      if [ "$rec" = "$pid" ]; then return 1; fi
    done <<EOF_LM
$recs
EOF_LM
  fi
  printf '%s %s\n' "$pid" "$age"
  return 0
}

# prune_launch_marker — removes the marker file iff launch_marker_active says
# it is INACTIVE. Never removes an active marker.
prune_launch_marker() {
  local f
  f="$(launch_marker_path)"
  [ -f "$f" ] || return 0
  if ! launch_marker_active >/dev/null 2>&1; then
    # Guarded the same way write_launch_marker guards its own write (CR
    # round 1) — CR round 6 [codex-1]: removing a file needs WRITE
    # permission on its DIRECTORY; `-f` only suppresses a missing-FILE
    # error, not a permission error. An unguarded `rm -f` here is the
    # THEN-branch of the `if` above, not the `if`'s own condition, so — unlike
    # a command tested directly by `if`/`!` — it is NOT exempt from this
    # file's `set -euo pipefail`: on an unwritable bridge root the failed rm
    # used to abort start/run before they launched anything, contradicting
    # round 1's "unwritable marker storage is non-fatal" promise (stated
    # twice in the header) for the read/remove side of the SAME storage.
    # `|| true` would SILENCE it instead, which round 1 also ruled out for
    # this class of failure — loud AND non-fatal, never one or the other.
    rm -f "$f" 2>/dev/null || echo "[restart-bridge] WARNING: could not remove the stale launch marker ($f) — leaving it in place and proceeding with the launch anyway; it will be retried by the next mutating verb (start/run/stop)." >&2
  fi
  return 0
}

# refuse_if_launch_in_progress — called by start_verb/run_verb AFTER
# acquire_lock and BEFORE sweep_stale (see the header's LAUNCH HANDOFF
# section for why the lock alone does not close this window). When no launch
# is in flight: prunes a stale marker if one is lying around, returns 0. When
# one IS in flight: prints one named refusal to stderr and exits 4 — neither
# sweeping nor launching, so it cannot itself create the duplicate it exists
# to prevent.
refuse_if_launch_in_progress() {
  local info pid age
  if info=$(launch_marker_active); then
    pid="${info%% *}"
    age="${info#* }"
    echo "[restart-bridge] REFUSING '$VERB': a bridge launch is already in progress (launcher pid $pid, started ${age}s ago) and is not yet visible to process discovery — sweeping or launching now would create a duplicate bridge (two pollers on one token → Telegram 409). Retry in a few seconds; if this persists past ~30s the marker ages out on its own." >&2
    exit 4
  fi
  prune_launch_marker
  return 0
}

# acquire_lock — best-effort flock on the token-scoped lock file; a loud,
# named degrade (never silent) when flock is unavailable on this host. The
# lock is held for the lifetime of THIS process (fd 200), released
# automatically on exit — scoping the critical section to the kill+relaunch
# (or kill-on-stop) sequence, not the bridge's own running lifetime.
#
# NOT called via `$(...)` — a command substitution runs in a SUBSHELL, and
# `exec 200>...`/`flock 200` inside one would only hold the lock for that
# subshell's lifetime (released the instant it returns), silently defeating
# the whole point. Sets the global ACQUIRED_LOCK instead.
ACQUIRED_LOCK=""
acquire_lock() {
  local token lock lockdir
  token=$(resolve_token) || {
    echo "[restart-bridge] FATAL: no TELEGRAM_BOT_TOKEN available (set TELEGRAM_BOT_TOKEN or populate \$HOME/.claude/channels/telegram/.env)" >&2
    exit 1
  }
  lock=$(lock_path_for_token "$token") || exit 1
  lockdir=$(dirname "$lock")
  mkdir -p "$lockdir"
  if command -v flock >/dev/null 2>&1; then
    exec 200>"$lock"
    flock 200
  else
    echo "[restart-bridge] WARNING: 'flock' not found on this host — cannot serialize concurrent start/stop (documented Stage-1 limitation, see this script's header). Proceeding WITHOUT the lock." >&2
  fi
  ACQUIRED_LOCK="$lock"
}

# sweep_stale — the instance-scoped stale sweep both `start` and `run` do
# before launching: stop whatever of THIS instance's bridge is still alive, so
# exactly one supervisor/poller pair survives the relaunch.
sweep_stale() {
  local existing_count
  # Arm the foreign-candidate warning for the FIRST classification pass only,
  # so start/run report it once rather than once per list_bridge_pids call.
  WARN_FOREIGN=1
  existing_count=$(list_bridge_pids | { grep -c . || true; })
  WARN_FOREIGN=0
  if [ "$existing_count" -gt 0 ]; then
    echo "[restart-bridge] found $existing_count bridge process(es) — stopping before relaunch" >&2
    kill_bridge_pids >/dev/null
    sleep 1
  fi
}

start_verb() {
  local lock bun_bin
  acquire_lock
  lock="$ACQUIRED_LOCK"

  # refuse_if_launch_in_progress exits 4 (see there) BEFORE writing any marker
  # of its own — it only ever PRUNES a stale one or refuses; a refused launch
  # therefore never disturbs the marker the launch it is refusing already
  # wrote. Called before sweep_stale so a launch-in-progress refusal also
  # refuses to sweep (see the header's LAUNCH HANDOFF section).
  refuse_if_launch_in_progress

  sweep_stale

  bun_bin=$(command -v bun) || { echo "[restart-bridge] 'bun' not found on PATH" >&2; exit 1; }
  mkdir -p "$(dirname "$LOG")"
  (
    cd "$BRIDGE_DIR"
    # 200>&- closes the lock fd for THIS command before it execs — without
    # it, the detached supervisor (and its poller.ts child, which inherits
    # from it in turn) keeps fd 200 open forever, since bash does not set
    # close-on-exec on a user-opened `exec N>file` fd by default. That leaked
    # fd keeps the flock's open-file-description alive long after THIS
    # script's own process exits and releases its copy — so a later `stop`'s
    # blocking `flock 200` deadlocks against the still-running bridge
    # (reproduced: hangs to timeout under WSL/real flock; unreachable on a
    # host without flock, which is why this shipped unnoticed on Git Bash).
    nohup "$bun_bin" supervisor.ts >"$LOG" 2>&1 </dev/null 200>&- &
    # $! is the pid of the backgrounded `nohup` job. `nohup` execs straight
    # into bun without forking again, so this pid IS the one the future
    # supervisor keeps for its whole life. ORDERING (HIMMEL-2556, hardened):
    # write_launch_marker is called HERE, immediately after the launch above,
    # with nothing intervening — bun_bin resolution and sweep_stale, the two
    # places this verb can already have exited early, both ran BEFORE this
    # point, and everything from here on (a plain pid assignment, then the
    # write) cannot itself fail the launch. A marker is therefore written iff
    # the child was actually backgrounded — never for a pid that stays alive
    # but was never going to become a supervisor. Do not move this write
    # earlier: pid-liveness alone does not catch that failure mode (the pid
    # would still be alive, just never a bridge), only this ordering does.
    child=$!
    write_launch_marker "$child"
    echo "[restart-bridge] launched supervisor (pid $child)"
  )
  echo "[restart-bridge] start complete; lock=$lock"
}

# run_verb — `start` minus the detach. Takes the same lock, does the same
# instance-scoped stale sweep, then EXECs the supervisor in the FOREGROUND from
# $BRIDGE_DIR so a process supervisor (systemd Type=simple) tracks the
# supervisor itself as MAINPID and can restart it when it dies. Output is NOT
# redirected to $LOG here: under systemd stdout/stderr belong to the journal;
# $LOG stays the detached `start` path's business.
run_verb() {
  local bun_bin
  acquire_lock

  # See start_verb's identical call for why this is safe against the marker:
  # refuse_if_launch_in_progress exits 4 before writing anything of its own.
  refuse_if_launch_in_progress

  sweep_stale

  bun_bin=$(command -v bun) || { echo "[restart-bridge] 'bun' not found on PATH" >&2; exit 1; }
  cd "$BRIDGE_DIR"
  # ORDERING (HIMMEL-2556, hardened): write_launch_marker is called HERE,
  # immediately BEFORE the lock fd is closed below — this is the one place in
  # run_verb that is BOTH under the lock (fd 200 is still open; acquire_lock's
  # flock has not been released yet, which is the entire point of a marker
  # meant to be visible to a concurrent launcher that is WAITING on that same
  # lock) AND has nothing failable between the write and the actual launch:
  # bun_bin resolution and sweep_stale, the two places this verb can already
  # have exited early, both ran before this point, and what follows — the
  # guarded `exec 200>&-` and an `echo` — cannot itself fail the launch. If
  # this shell were to die at either of those two steps anyway, the pid named
  # by the marker dies with it, so launch_marker_active's pid-liveness check
  # (not the ordering) is what retires that marker immediately — the two
  # guards are complementary, see the header's ORDERING paragraph. $$ is
  # preserved across the later `exec` (it replaces the program image, not the
  # process), so the marker names exactly the pid that becomes the
  # supervisor. Do NOT move this write after the fd close: that would write
  # the marker with the lock already released, reopening (and, since an
  # `echo`/`mkdir -p`/`date`/`printf` sit between the close and the write,
  # WIDENING past a single syscall) the exact race this ticket exists to
  # close.
  write_launch_marker "$$"
  # Close the lock fd BEFORE exec, for the same reason start_verb closes it for
  # its detached child (see the long comment there): bash does not set
  # close-on-exec on a user-opened `exec N>file` fd, so the supervisor we are
  # about to become — and its poller child, which inherits in turn — would keep
  # fd 200 open for the bridge's whole lifetime and deadlock a later blocking
  # `stop`. Guarded: acquire_lock only opens fd 200 when `flock` exists.
  #
  # The race this used to leave open (HIMMEL-2556, formerly deferred): closing
  # the lock here opens a window before `exec` turns this process into a live
  # `bun supervisor.ts`, during which a concurrent `start` could take the
  # lock, see no bridge, and launch a duplicate. That window is now closed by
  # the launch marker written just above, while the lock was still held: a
  # concurrent launcher blocked on acquire_lock sees this pid, still alive and
  # not yet in the discovery set, the instant it gets the lock, and refuses
  # rather than sweeping/launching. See the header's LAUNCH HANDOFF section.
  if command -v flock >/dev/null 2>&1; then
    exec 200>&-
  fi
  echo "[restart-bridge] run: exec'ing supervisor in the foreground from $BRIDGE_DIR" >&2
  exec "$bun_bin" supervisor.ts
}

stop_verb() {
  local lock killed info pid age
  acquire_lock
  lock="$ACQUIRED_LOCK"
  # A launch marker (HIMMEL-2556) is a signal here, not something to sweep or
  # remove: this stop cannot see (and therefore cannot reap) a process that
  # has not yet become visible to process discovery, so a bridge may still
  # come up right after this stop returns. Warn once and leave it alone — do
  # NOT prune an ACTIVE marker; only an inactive one is stale enough to
  # remove (prune_launch_marker already refuses to remove an active one, but
  # the intent is stated here too so a reader does not go looking for a
  # missing prune call).
  if info=$(launch_marker_active); then
    pid="${info%% *}"
    age="${info#* }"
    echo "[restart-bridge] WARNING: a bridge launch is in progress (launcher pid $pid, started ${age}s ago) and is not yet visible to process discovery — this stop cannot reap it, so a bridge may come up right after this stop returns." >&2
  else
    prune_launch_marker
  fi
  WARN_FOREIGN=1          # see sweep_stale — one foreign-bridge notice per stop
  killed=$(kill_bridge_pids)
  WARN_FOREIGN=0
  echo "[restart-bridge] stop: killed $killed bridge process(es); lock=$lock"
}

status_verb() {
  local recs count info pid age
  recs=$(list_bridge_pids) || true
  # Read-only — never prune (status's "touches nothing" contract), just report.
  if info=$(launch_marker_active); then
    pid="${info%% *}"
    age="${info#* }"
    echo "[restart-bridge] status: a bridge launch is in progress (launcher pid $pid, ${age}s ago), not yet visible to process discovery"
  fi
  if [ -z "$recs" ]; then
    echo "[restart-bridge] status: no bridge process(es) found"
    return 0
  fi
  count=$(printf '%s\n' "$recs" | grep -c . || true)
  echo "[restart-bridge] status: $count bridge process(es):"
  printf '%s\n' "$recs" | while IFS=' ' read -r pid role; do
    [ -n "$pid" ] && echo "  $role pid $pid"
  done
  return 0
}

case "$VERB" in
  start) start_verb ;;
  run) run_verb ;;
  stop) stop_verb ;;
  status) status_verb ;;
esac
exit 0
