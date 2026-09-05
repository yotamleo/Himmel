#!/usr/bin/env bash
# scripts/context-fill.sh - print THIS session's CONTEXT WINDOW FILL (HIMMEL-2212).
#
# WHAT THIS IS: the fraction of the model's context window the current Claude
# Code session has consumed. WHAT THIS IS NOT: the <total_tokens> spend budget
# visible in-session (a multi-million-token account allowance). Four legs
# conflated the two on 2026-08-29, which is why every readout here says so.
#
# Source of truth is the claude-hud statusline's per-session snapshot
# (marketplace/plugins/claude-hud/src/context-cache.ts). The HUD computes the
# figure every statusline tick and persists it under
# <claude-config>/plugins/claude-hud/context-cache/<sha256(transcript)>.json.
# himmel only CONSUMES that file; the vendored plugin is never edited from here.
#
# Snapshots are keyed by sha256 of the platform-native absolute transcript path
# (Node's path.resolve output - backslashes on Windows), so a session can only
# ever read its OWN entry.
#
# Exit codes: 0 = fresh readout printed on stdout. 3 = STALE - either the
# snapshot is older than the freshness window, or (HIMMEL-2342) its saved_at
# lags the session transcript's own mtime by more than the lag window. The
# latter catches a frozen snapshot: Claude Code can emit
# context_window.used_percentage=0 while current_usage is non-zero (a
# documented in-flight tick); the HUD's render path falls back to a live
# token-based number, but its cache-write gate skips the write entirely, so
# the on-disk snapshot freezes at its last genuine reading. A frozen snapshot
# can sit comfortably inside the age window - age alone cannot distinguish it
# from a quiet session - so the lag against the transcript's mtime is the only
# externally visible signal. 4 = UNKNOWN (no session id, no transcript, no
# snapshot, or a malformed one). On 3 and 4 stdout stays EMPTY - a caller
# capturing "$(context-fill.sh --percent)" gets nothing rather than a
# fabricated or stale number - the verdict, snapshot age, and (when known) the
# transcript lag go to stderr.
#
# bash 3.2-safe (no mapfile, no associative arrays); ASCII only. No .ps1 twin:
# himmel's scripts/ shell runs under Git Bash on Windows, and the only consumer
# is an agent's Bash tool.
#
# Parsing is deliberately regex-based rather than a JSON parser: the writer is a
# single writeFileSync of JSON.stringify over a flat object, so the shape is
# fixed and known. Every field is validated (delimiter-anchored key, terminated
# value, 0-100 range on percentages, integer-only saved_at) and the payload must
# be a `{...}` object. Note the threat model is CORRUPTION, not an adversary:
# the cache lives in a 0700 dir with 0600 files, and anyone able to write it
# could write perfectly valid JSON carrying any number they liked, so a JSON
# parser would add a dependency without adding a control.
set -euo pipefail

# A non-numeric or non-positive value would make the -gt comparison below error
# out and read as FALSE, silently disabling the staleness check - the fail-OPEN
# direction this script exists to avoid. Same fallback convention as
# critic-panel.sh's CRITIC_TIMEOUT_SECS: warn and use the default, never die.
MAX_AGE_SECONDS="${CONTEXT_FILL_MAX_AGE_SECONDS:-900}"
case "$MAX_AGE_SECONDS" in
  ''|*[!0-9]*)
    printf 'context-fill: ignoring non-numeric CONTEXT_FILL_MAX_AGE_SECONDS=%s - using 900s\n' "$MAX_AGE_SECONDS" >&2
    MAX_AGE_SECONDS=900
    ;;
esac
[ "$MAX_AGE_SECONDS" -gt 0 ] || MAX_AGE_SECONDS=900

# Same fail-safe convention: a frozen-snapshot lag beyond this many seconds is
# STALE (HIMMEL-2342). Default 60s sits comfortably above the HUD's own
# WRITE_TTL_MS=3000 write-throttle plus its 300ms tick debounce, and far below
# the 900s freshness window above.
MAX_LAG_SECONDS="${CONTEXT_FILL_MAX_LAG_SECONDS:-60}"
case "$MAX_LAG_SECONDS" in
  ''|*[!0-9]*)
    printf 'context-fill: ignoring non-numeric CONTEXT_FILL_MAX_LAG_SECONDS=%s - using 60s\n' "$MAX_LAG_SECONDS" >&2
    MAX_LAG_SECONDS=60
    ;;
esac
[ "$MAX_LAG_SECONDS" -gt 0 ] || MAX_LAG_SECONDS=60

usage() {
  cat <<'USAGE'
usage: context-fill.sh [--percent | --cache-path | --help]

Prints the current session's CONTEXT WINDOW FILL (not the <total_tokens>
spend budget).

  (no flag)      human-readable readout on stdout
  --percent      the integer percent alone, for threshold checks
  --cache-path   the resolved snapshot path (debug / test seam)

exit 0 = fresh   exit 3 = STALE   exit 4 = UNKNOWN
stdout is empty on 3 and 4 by design.

env:
  CONTEXT_FILL_MAX_AGE_SECONDS   freshness window in seconds, default 900
  CONTEXT_FILL_MAX_LAG_SECONDS   max seconds a snapshot's saved_at may lag the
                                  session transcript's mtime before it is
                                  refused as a frozen HUD snapshot
                                  (HIMMEL-2342), default 60
  CONTEXT_FILL_TRANSCRIPT        override the resolved transcript path
  CLAUDE_CONFIG_DIR              honoured the same way the HUD honours it
USAGE
}

die_unknown() {
  printf 'context-fill: UNKNOWN - %s\n' "$1" >&2
  printf 'context-fill: refusing to guess. (This is context-window FILL, not the <total_tokens> spend budget.)\n' >&2
  exit 4
}

# Mirror of the HUD's getClaudeConfigDir(): CLAUDE_CONFIG_DIR wins, with a
# leading ~ expanded; otherwise $HOME/.claude.
config_dir() {
  local d="${CLAUDE_CONFIG_DIR:-}"
  if [ -z "$d" ]; then
    printf '%s\n' "$HOME/.claude"
    return 0
  fi
  # shellcheck disable=SC2088  # matching/stripping a literal '~/' prefix, not expanding one
  case "$d" in
    '~') d="$HOME" ;;
    '~/'*) d="$HOME/${d#\~/}" ;;
  esac
  printf '%s\n' "$d"
}

# Node's path.resolve() form of a path, which is what the HUD hashes: a Windows
# drive path under Git Bash, the POSIX path everywhere else.
native_path() {
  local p="$1" d
  # The HUD hashes path.resolve() output, which is always absolute. Canonicalise
  # the directory first so a relative CLAUDE_CONFIG_DIR or CONTEXT_FILL_TRANSCRIPT
  # cannot hash a relative path that could never match the HUD's key. `cd`+`pwd`
  # collapses '.' and '..' the way path.resolve does; it is a no-op on the
  # already-absolute path the session-id lookup produces.
  if d=$(cd "$(dirname "$p")" 2>/dev/null && pwd); then
    p="$d/$(basename "$p")"
  fi
  case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*) cygpath -w "$p" ;;
    *) printf '%s\n' "$p" ;;
  esac
}

# Portable mtime in epoch seconds: GNU stat (Git Bash/Linux) first, then
# BSD/macOS stat. Prints nothing and returns nonzero when neither works or the
# path is unreadable - callers must treat that as "cannot determine", not "0".
transcript_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null  # gnu-ok: GNU -c paired with BSD -f on this line
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
  else
    return 1
  fi
}

# The session's transcript: an explicit override, else
# <claude-config>/projects/<any project slug>/<CLAUDE_CODE_SESSION_ID>.jsonl.
resolve_transcript() {
  if [ -n "${CONTEXT_FILL_TRANSCRIPT:-}" ]; then
    printf '%s\n' "$CONTEXT_FILL_TRANSCRIPT"
    return 0
  fi
  local sid="${CLAUDE_CODE_SESSION_ID:-}"
  [ -n "$sid" ] || return 1
  local f
  for f in "$(config_dir)"/projects/*/"$sid".jsonl; do
    if [ -f "$f" ]; then
      printf '%s\n' "$f"
      return 0
    fi
  done
  return 1
}

# HIMMEL-2545: name the cause when resolution fails, instead of leaving the
# reader with "fill is blind on this station" (five console handovers carried
# that note through one night; it was never a station property).
#
# THE TRAP: claude exports CLAUDE_CODE_CHILD_SESSION=1 into EVERY process it
# spawns - this script included - so our OWN environment says nothing about how
# the claude session we belong to was launched. Keying the hint off our own
# $CLAUDE_CODE_CHILD_SESSION would print it in perfectly healthy sessions too.
# The honest source is the claude PROCESS's own environ, and claude hands us
# its pid in CLAUDE_PID. comm is checked because a stale CLAUDE_PID may have
# been recycled onto some unrelated process.
#
# FORCE_SESSION_PERSISTENCE on the claude process means the launcher already
# did the right thing, so whatever broke resolution here it is not this bug.
# Silent (rc 1) whenever the answer cannot be established: no CLAUDE_PID, no
# procfs (macOS, Git Bash), an unreadable environ. A wrong hint is worse than
# none - the whole point of this script is refusing to guess.
# CONTEXT_FILL_PROC is the test seam: a stubbed process tree.
launched_as_child_session() {
  local proc_root="${CONTEXT_FILL_PROC:-/proc}"
  local pid="${CLAUDE_PID:-}" comm environ
  [ -n "$pid" ] || return 1
  # A pid is a number - reject anything else (e.g. a path-traversal payload
  # like ../../something) before it ever reaches the filesystem.
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -r "$proc_root/$pid/comm" ] || return 1
  comm="$(cat "$proc_root/$pid/comm" 2>/dev/null)" || return 1
  [ "$comm" = "claude" ] || return 1
  [ -r "$proc_root/$pid/environ" ] || return 1
  environ="$(tr '\0' '\n' < "$proc_root/$pid/environ" 2>/dev/null)" || return 1
  # An EMPTY value (CLAUDE_CODE_FORCE_SESSION_PERSISTENCE= with nothing
  # after the =) is treated as absent, not present: every launcher in this
  # ticket sets it to "1", so an empty value is meaningless, never a
  # deliberate spelling of "on". The `.` requires at least one character
  # after `=`. Deliberately asymmetric the OTHER way too: any NON-EMPTY
  # value (not just "1") still counts as persistence-on - requiring
  # exactly "=1" would flip a session persisting under some other truthy
  # spelling into a false "broken child session" hint, which is the exact
  # failure mode this whole ticket exists to prevent. A missed hint (rare:
  # only an explicitly empty value) is cheap; a false hint is not.
  if grep -q '^CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=.' <<< "$environ"; then
    return 1
  fi
  if grep -q '^CLAUDE_CODE_CHILD_SESSION=1$' <<< "$environ"; then
    return 0
  fi
  return 1
}

resolve_cache_path() {
  local transcript hash hint=""
  if ! transcript="$(resolve_transcript)"; then
    # HIMMEL-2545: only when the claude PROCESS itself carries the marker -
    # see launched_as_child_session() for why our own env cannot be trusted.
    if launched_as_child_session; then
      hint='
context-fill: hint: this session inherited CLAUDE_CODE_CHILD_SESSION - transcripts are off; relaunch through env -u CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 (HIMMEL-2545)'
    fi
    die_unknown "cannot resolve this session (CLAUDE_CODE_SESSION_ID unset, or no transcript under <claude-config>/projects)$hint"
  fi
  hash="$(sha256_of "$(native_path "$transcript")")" \
    || die_unknown 'no sha256sum or shasum on PATH - cannot derive the snapshot key'
  printf '%s/plugins/claude-hud/context-cache/%s.json\n' "$(config_dir)" "$hash"
}

# The snapshot is compact JSON.stringify output of a flat object whose only
# nested value (current_usage) shares no key names with the fields read here,
# so a scalar-key extraction is exact for this writer.
# Both anchors are load-bearing. The trailing [,}] rejects a value with trailing
# junk (`"used_percentage":42junk`). The LEADING [{,] rejects a key that is not
# actually a key: without it, `{GARBAGE"used_percentage":42,...}` passed the
# object check and was reported as a real 42% measurement. In the object the HUD
# writes, every key is immediately preceded by `{` or `,`, so a "key" lacking
# that delimiter is text that merely looks like one.
json_num() { sed -n 's/.*[{,][[:space:]]*"'"$1"'":\(-\{0,1\}[0-9][0-9.]*\)[,}].*/\1/p' <<<"$2" | head -n 1; }
json_str() { sed -n 's/.*[{,][[:space:]]*"'"$1"'":"\([^"]*\)".*/\1/p' <<<"$2" | head -n 1; }

round() { awk -v n="$1" 'BEGIN{printf "%.0f", n}'; }

# True when $1 is a plain decimal percentage in 0-100. Used for every percentage
# this script reports: a number it cannot vouch for is not a measurement.
valid_pct() { awk -v v="$1" 'BEGIN{ exit !(v ~ /^[0-9]+(\.[0-9]+)?$/ && v+0 >= 0 && v+0 <= 100) }'; }

mode="human"
case "${1:-}" in
  '') ;;
  --percent) mode="percent" ;;
  --cache-path) mode="cache-path" ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

# Only one option is ever meaningful; a trailing argument means the caller
# expected something this script does not do, so fail the documented way
# (exit 2) rather than silently ignoring it.
if [ "$#" -gt 1 ]; then
  printf 'context-fill: unexpected extra argument: %s\n' "$2" >&2
  usage >&2
  exit 2
fi

cache_path="$(resolve_cache_path)" || exit $?

if [ "$mode" = "cache-path" ]; then
  printf '%s\n' "$cache_path"
  exit 0
fi

[ -f "$cache_path" ] \
  || die_unknown "no HUD snapshot for this session ($cache_path). Is the claude-hud statusline running?"

snapshot="$(cat "$cache_path")"
# Every field below is individually validated, but that is not sufficient on its
# own: a file that is not JSON at all - GARBAGE"used_percentage":42,"saved_at":N,xx
# - offers plausible fragments to a regex extractor and was reported as a real
# 42% measurement. Require the payload to be the object the HUD writes before
# reading anything out of it. (Truncated writes already fail on the per-field
# checks; this closes the non-object shape those checks cannot see.)
case "$snapshot" in
  '{'*'}') ;;
  *) die_unknown "snapshot is not a JSON object - refusing to read a measurement out of it ($cache_path)" ;;
esac
# A top-level `}{` means more than one object in the file. That matters more
# than it looks: sed's `.*` is greedy, so each extractor takes the LAST match of
# a key - a two-object file reported the SECOND object's percentage, i.e. a real
# number from the wrong snapshot. Nested objects always close with `},` or `}}`,
# never `}{`, so this cannot fire on a well-formed payload.
case "$snapshot" in
  *'}'[[:space:]]*'{'*|*'}{'*)
    die_unknown "snapshot contains more than one top-level object - it is corrupt, and a greedy extractor would report the wrong one ($cache_path)" ;;
esac
used="$(json_num used_percentage "$snapshot")"
[ -n "$used" ] || die_unknown "snapshot is malformed - no used_percentage in $cache_path"
valid_pct "$used" \
  || die_unknown "snapshot reports an implausible used_percentage ($used) in $cache_path"

window="$(json_num context_window_size "$snapshot")"
remaining="$(json_num remaining_percentage "$snapshot")"
saved_at_ms="$(json_num saved_at "$snapshot")"
# Epoch milliseconds is an integer. json_num permits dots (percentages can be
# fractional), so a corrupt "saved_at":<ms>.1.2 would reach awk, parse as a
# plausible current timestamp, and certify a corrupt snapshot as fresh.
case "$saved_at_ms" in
  ''|*[!0-9]*) die_unknown "snapshot has a malformed saved_at ('$saved_at_ms') - its age cannot be established, so it cannot be certified current ($cache_path)" ;;
esac
session_name="$(json_str session_name "$snapshot")"

used_pct="$(round "$used")"
if [ -n "$remaining" ] && valid_pct "$remaining"; then
  free_pct="$(round "$remaining")"
else
  free_pct=$((100 - used_pct))
fi

age="$(awk -v ms="$saved_at_ms" -v now="$(date +%s)" 'BEGIN{printf "%d", now - int(ms/1000)}')"
# A negative age means the snapshot claims to be from the future - clock skew or
# a corrupt timestamp. Neither can certify freshness, and accepting it would read
# as current indefinitely, so it is UNKNOWN like any other unusable timestamp.
[ "$age" -ge 0 ] \
  || die_unknown "snapshot timestamp is in the future (age ${age}s) - clock skew or a corrupt saved_at, so it cannot be certified current ($cache_path)"

if [ "$age" -gt "$MAX_AGE_SECONDS" ]; then
  printf 'context-fill: STALE - the newest snapshot for this session is %ss old (freshness window %ss).\n' \
    "$age" "$MAX_AGE_SECONDS" >&2
  printf 'context-fill: last known fill was %s%% of a %s-token window; treat it as UNKNOWN, not as the current fill.\n' \
    "$used_pct" "${window:-unknown}" >&2
  exit 3
fi

# The age check above cannot see a frozen snapshot (HIMMEL-2342): the HUD can
# skip a cache write on a documented in-flight used_percentage=0 tick, and a
# frozen-but-recent saved_at is indistinguishable from a genuinely quiet
# session by age alone. Compare saved_at against the transcript's own mtime -
# the transcript advances on every tool round and the HUD writes within its
# own 3s throttle on every tick, so a large lag means writes are being
# skipped. A transcript OLDER than the snapshot is normal (the write lands
# after the append that triggered it), so that case reads as zero lag rather
# than a negative that could read as a trip. Unreadable/undeterminable mtime
# SKIPS this check rather than fabricating a STALE verdict.
t_mtime=""
if lag_transcript="$(resolve_transcript)" \
  && t_mtime="$(transcript_mtime "$lag_transcript")" \
  && case "$t_mtime" in ''|*[!0-9]*) false ;; *) true ;; esac
then
  saved_at_s=$((saved_at_ms / 1000))
  if [ "$t_mtime" -gt "$saved_at_s" ]; then
    lag=$((t_mtime - saved_at_s))
  else
    lag=0
  fi
  # Informational only - the human-readable (no-flag) readout, not --percent:
  # a leg polling --percent in a loop must not gain a stderr line on every
  # healthy call. The STALE message below already carries both age and lag in
  # every mode, so that audit trail is not lost when this is skipped.
  if [ "$mode" = "human" ]; then
    printf 'context-fill: snapshot age %ss, transcript lag %ss (lag window %ss).\n' \
      "$age" "$lag" "$MAX_LAG_SECONDS" >&2
  fi
  if [ "$lag" -gt "$MAX_LAG_SECONDS" ]; then
    printf 'context-fill: STALE - the HUD snapshot is frozen: saved_at is %ss old and lags the session transcript by %ss (lag window %ss). The HUD appears to have skipped its cache write for this transcript (a known in-flight-zero condition, HIMMEL-2342) - the live HUD statusline column is the truthful number right now; this snapshot cannot be certified current.\n' \
      "$age" "$lag" "$MAX_LAG_SECONDS" >&2
    exit 3
  fi
fi

if [ "$mode" = "percent" ]; then
  printf '%s\n' "$used_pct"
  exit 0
fi

# Exact resident-token count when the HUD recorded the per-counter usage; the
# four counters together are the tokens sitting in the window. Printed only
# when all four are present, so the figure is never a partial sum.
tokens="$(awk '{
  split("input_tokens output_tokens cache_creation_input_tokens cache_read_input_tokens", f, " ")
  n = 0; c = 0
  for (k = 1; k <= 4; k++) {
    if (match($0, "\"" f[k] "\":[0-9]+")) {
      s = substr($0, RSTART, RLENGTH); sub(/.*:/, "", s); n += s; c++
    }
  }
  if (c == 4) print n
}' <<<"$snapshot")"

printf 'context-fill: %s%% of the CONTEXT WINDOW used' "$used_pct"
if [ -n "$window" ]; then printf ' (%s-token window)' "$window"; fi
printf ' - %s%% free' "$free_pct"
if [ -n "$tokens" ]; then printf ', %s tokens resident' "$tokens"; fi
printf '\n'
printf '  session: %s | snapshot age: %ss\n' "${session_name:-unnamed}" "$age"
printf '  NOTE: this is context-window FILL, NOT the <total_tokens> spend budget.\n'
