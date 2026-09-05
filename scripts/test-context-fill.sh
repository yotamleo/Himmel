#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check()/contains(), as in scripts/cr/test-known-findings.sh
# Test harness for context-fill.sh (HIMMEL-2212). Builds a throwaway
# CLAUDE_CONFIG_DIR holding fake session transcripts + fake claude-hud
# snapshots, then asserts the three verdicts the ticket asks for: a fresh
# snapshot reads back exactly, a missing/stale/malformed one fails LOUD with
# an empty stdout, and one session never reads another session's snapshot.
#
# Fixtures are placed via the script's own --cache-path resolver so the suite
# stays platform-neutral (the HUD hashes a Windows path under Git Bash and a
# POSIX path elsewhere). The end-to-end proof against a REAL running HUD is
# recorded in the HIMMEL-2212 PR body, not here - a hermetic suite must not
# depend on a live statusline.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"; SCRIPT="$HERE/context-fill.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/ctxfill-test.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT
fails=0
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }
check()        { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains()     { grepq "$2" -F -e "$3" && echo "ok - $1" || { echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)); }; }
not_contains() { grepq "$2" -F -e "$3" && { echo "FAIL - $1: output must NOT contain [$3]"; fails=$((fails+1)); } || echo "ok - $1"; }

# --- fixture config dir -----------------------------------------------------
CFG="$tmp/claude"; export CLAUDE_CONFIG_DIR="$CFG"
mkdir -p "$CFG/projects/C--fixture-repo" "$CFG/plugins/claude-hud/context-cache"
SID_A="aaaaaaaa-1111-2222-3333-444444444444"
SID_B="bbbbbbbb-5555-6666-7777-888888888888"
: > "$CFG/projects/C--fixture-repo/$SID_A.jsonl"
: > "$CFG/projects/C--fixture-repo/$SID_B.jsonl"

# now_ms - epoch milliseconds, the unit the HUD writes saved_at in.
now_ms() { awk -v s="$(date +%s)" 'BEGIN{printf "%.0f", s*1000}'; }

# backdate <file> <epoch-seconds> - set a file's mtime to an exact epoch time.
# GNU touch takes `-d @<epoch>` directly; BSD/macOS touch has no epoch form,
# so fall back through BSD `date -r <epoch>` into touch's -t timestamp, the
# same GNU-first/BSD-fallback shape as transcript_mtime() in the script under
# test (and sha256sum -> shasum below it). Fails LOUDLY rather than silently
# no-op-ing: a fixture that silently fails to backdate makes whatever it feeds
# pass for the wrong reason, which is worse than a clean failure.
backdate() {
  local file="$1" epoch="$2" ts
  touch -d "@$epoch" "$file" 2>/dev/null && return 0
  ts="$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null)" && touch -t "$ts" "$file" 2>/dev/null && return 0
  echo "backdate: cannot set mtime on this platform (neither GNU 'touch -d @' nor BSD 'date -r' + 'touch -t' worked)" >&2
  exit 1
}

# snapshot <used> <window> <remaining> <saved_at_ms> <session_name> [usage_json]
snapshot() {
  # The default is assigned in a plain `if`, NOT via ${6-...}: the nested
  # current_usage object's closing brace terminates a ${...} expansion early,
  # which silently emitted `,}` instead of `},` and made every fixture built
  # here invalid JSON. The old permissive extractor matched a key anywhere in
  # the text and never noticed; the delimiter-anchored one does.
  # `$# -ge 6`, not `-n "$6"`: an explicitly EMPTY 6th arg means "no
  # current_usage block", which is a case the suite exercises.
  local usage
  if [ "$#" -ge 6 ]; then
    usage="$6"
  else
    usage='"current_usage":{"input_tokens":10,"output_tokens":20,"cache_creation_input_tokens":30,"cache_read_input_tokens":40},'
  fi
  printf '{"used_percentage":%s,"remaining_percentage":%s,%s"context_window_size":%s,"saved_at":%s,"session_name":"%s"}' \
    "$1" "$3" "$usage" "$2" "$4" "$5"
}

# Guard the fixture builder itself: a malformed fixture silently weakens every
# assertion built on it (this exact `,}` bug hid for five review rounds).
fixture_probe="$(snapshot 42 500000 58 1788089693000 "leg-A")"
not_contains "fixture builder: no ,} malformation" "$fixture_probe" ',}"'
contains     "fixture builder: closes current_usage then commas" "$fixture_probe" '},"context_window_size"'

# Ask the script where a given session's snapshot belongs, then write it there.
place() { # place <session-id> <json>
  local path
  path="$(CLAUDE_CODE_SESSION_ID="$1" bash "$SCRIPT" --cache-path)" || return 1
  printf '%s' "$2" > "$path"
  printf '%s\n' "$path"
}

# --- key derivation ---------------------------------------------------------
pa="$(CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SCRIPT" --cache-path)"
pb="$(CLAUDE_CODE_SESSION_ID="$SID_B" bash "$SCRIPT" --cache-path)"
[ "$pa" != "$pb" ] && echo "ok - distinct sessions get distinct cache keys" \
  || { echo "FAIL - distinct sessions collided on one cache key"; fails=$((fails+1)); }
base_a="$(basename "$pa" .json)"
grep -Eq '^[0-9a-f]{64}$' <<<"$base_a" && echo "ok - cache key is a sha256 hex digest" \
  || { echo "FAIL - cache key is not 64 hex chars: [$base_a]"; fails=$((fails+1)); }
contains "cache path lands in the claude-hud plugin dir" "$pa" "plugins/claude-hud/context-cache"

# --- 1. missing snapshot -> loud UNKNOWN, empty stdout ----------------------
out="$(CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SCRIPT" 2>/dev/null)"; rc=$?
check "missing snapshot: exit 4" "$rc" "4"
check "missing snapshot: stdout is EMPTY" "$out" ""
err="$(CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SCRIPT" 2>&1 >/dev/null)"
contains "missing snapshot: says UNKNOWN" "$err" "UNKNOWN"
contains "missing snapshot: names the HUD"  "$err" "claude-hud"
contains "missing snapshot: refuses to guess" "$err" "refusing to guess"
outp="$(CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SCRIPT" --percent 2>/dev/null)"; rcp=$?
check "missing snapshot: --percent exit 4"        "$rcp" "4"
check "missing snapshot: --percent stdout EMPTY"  "$outp" ""

# --- 2. fresh snapshot -> the exact number ----------------------------------
place "$SID_A" "$(snapshot 42 500000 58 "$(now_ms)" "leg-A")" > /dev/null
out="$(CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SCRIPT" 2>&1)"; rc=$?
check "fresh snapshot: exit 0" "$rc" "0"
contains "fresh: reports 42%"                "$out" "42% of the CONTEXT WINDOW used"
contains "fresh: reports the window size"    "$out" "500000-token window"
contains "fresh: reports free percent"       "$out" "58% free"
contains "fresh: sums resident tokens"       "$out" "100 tokens resident"
contains "fresh: names the session"          "$out" "leg-A"
contains "fresh: disclaims the spend budget" "$out" "NOT the <total_tokens> spend budget"
outp="$(CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SCRIPT" --percent 2>/dev/null)"
check "fresh: --percent prints the bare integer" "$outp" "42"

# A threshold check is the whole point of the ticket - prove it composes.
if [ "$outp" -ge 40 ]; then echo "ok - --percent is usable in an arithmetic threshold test"
else echo "FAIL - --percent not usable as a number"; fails=$((fails+1)); fi

# --- 3. wrong-session snapshot is never returned ----------------------------
place "$SID_B" "$(snapshot 91 500000 9 "$(now_ms)" "leg-B")" > /dev/null
out="$(CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SCRIPT" 2>&1)"
contains     "isolation: session A still reads its own 42%" "$out" "42%"
not_contains "isolation: session A never sees B's 91%"      "$out" "91%"
not_contains "isolation: session A never sees B's name"     "$out" "leg-B"
outb="$(CLAUDE_CODE_SESSION_ID="$SID_B" bash "$SCRIPT" --percent 2>/dev/null)"
check "isolation: session B reads its own 91" "$outb" "91"

# --- 4. stale snapshot -> loud STALE, empty stdout, no fabricated number -----
# Backdate the transcript's mtime to match: this fixture represents a session
# that has genuinely been quiet for 4000s (transcript untouched, not just the
# snapshot), so only the AGE check - not the HIMMEL-2342 lag check - should
# fire here.
now_s="$(date +%s)"
stale_ms="$(awk -v s="$now_s" 'BEGIN{printf "%.0f", (s-4000)*1000}')"
backdate "$CFG/projects/C--fixture-repo/$SID_A.jsonl" "$((now_s - 4000))"
place "$SID_A" "$(snapshot 42 500000 58 "$stale_ms" "leg-A")" > /dev/null
out="$(CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SCRIPT" 2>/dev/null)"; rc=$?
check "stale snapshot: exit 3"              "$rc" "3"
check "stale snapshot: stdout is EMPTY"     "$out" ""
err="$(CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SCRIPT" 2>&1 >/dev/null)"
contains "stale: says STALE"                     "$err" "STALE"
contains "stale: says treat as UNKNOWN"          "$err" "treat it as UNKNOWN"
contains "stale: labels the last-known number"   "$err" "last known fill was 42%"
outp="$(CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SCRIPT" --percent 2>/dev/null)"; rcp=$?
check "stale: --percent exit 3"               "$rcp" "3"
check "stale: --percent stdout EMPTY"         "$outp" ""

# The freshness window is tunable, and the SAME snapshot reads fresh under a
# wider one - so exit 3 is a staleness verdict, not an unrelated failure.
outp="$(CLAUDE_CODE_SESSION_ID="$SID_A" CONTEXT_FILL_MAX_AGE_SECONDS=99999 bash "$SCRIPT" --percent 2>/dev/null)"; rcp=$?
check "stale: widened freshness window reads 42" "$outp" "42"
check "stale: widened freshness window exit 0"   "$rcp" "0"

# --- 5. malformed / partial snapshots ---------------------------------------
printf '%s' 'not json at all' > "$pa"
out="$(CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SCRIPT" 2>/dev/null)"; rc=$?
check "malformed snapshot: exit 4"          "$rc" "4"
check "malformed snapshot: stdout is EMPTY" "$out" ""
err="$(CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SCRIPT" 2>&1 >/dev/null)"
contains "non-JSON payload: says not a JSON object" "$err" "not a JSON object"

# A well-formed object with no usable used_percentage: the ONLY route to the
# per-field malformed branch now that a non-object is rejected earlier.
printf '%s' '{"context_window_size":500000,"saved_at":1}' > "$pa"
out="$(CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SCRIPT" 2>/dev/null)"; rc=$?
check "object without used_percentage: exit 4"          "$rc" "4"
check "object without used_percentage: stdout is EMPTY" "$out" ""
err="$(CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SCRIPT" 2>&1 >/dev/null)"
contains "object without used_percentage: says malformed" "$err" "malformed"

# Plausible fragments inside a non-object payload are not a measurement:
# per-field validation alone cannot see that the whole thing is not JSON.
printf '%s' 'GARBAGE"used_percentage":42,"saved_at":'"$(now_ms)"',xx' > "$pa"
out="$(CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SCRIPT" 2>/dev/null)"; rc=$?
check "non-object payload: exit 4"          "$rc" "4"
check "non-object payload: stdout is EMPTY" "$out" ""
err="$(CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SCRIPT" 2>&1 >/dev/null)"
contains "non-object payload: says not a JSON object" "$err" "not a JSON object"
not_contains "non-object payload: never reports the fragment as current" "$out" "42"

# A brace-wrapped payload whose "key" is not actually a key (no {/, delimiter
# before it) must not be read as a real field - it falls through to the
# no-used_percentage malformed branch, not a fabricated 42%.
printf '%s' '{GARBAGE"used_percentage":42,"saved_at":'"$(now_ms)"'}' > "$pa"
out="$(CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SCRIPT" 2>/dev/null)"; rc=$?
check "unanchored key inside braces: exit 4"          "$rc" "4"
check "unanchored key inside braces: stdout is EMPTY" "$out" ""
err="$(CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SCRIPT" 2>&1 >/dev/null)"
contains "unanchored key inside braces: says malformed" "$err" "malformed"
not_contains "unanchored key inside braces: never reports the fragment as current" "$out" "42"

# Two concatenated objects must never report either one - a greedy extractor
# would silently take the LAST occurrence of a key, i.e. a real number from
# the wrong snapshot.
printf '%s%s' "$(snapshot 42 500000 58 "$(now_ms)" "leg-A")" "$(snapshot 99 500000 1 "$(now_ms)" "leg-B")" > "$pa"
out="$(CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SCRIPT" 2>/dev/null)"; rc=$?
check "concatenated objects: exit 4"          "$rc" "4"
check "concatenated objects: stdout is EMPTY" "$out" ""
err="$(CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SCRIPT" 2>&1 >/dev/null)"
contains "concatenated objects: says more than one top-level object" "$err" "more than one top-level object"
not_contains "concatenated objects: never reports the first object's number"  "$out" "42"
not_contains "concatenated objects: never reports the second object's number" "$out" "99"

# A snapshot with no current_usage still yields the percent, minus the token sum.
place "$SID_A" "$(snapshot 7 200000 93 "$(now_ms)" "leg-A" "")" > /dev/null
out="$(CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SCRIPT" 2>&1)"; rc=$?
check "no current_usage: exit 0" "$rc" "0"
contains     "no current_usage: percent still reported" "$out" "7% of the CONTEXT WINDOW used"
not_contains "no current_usage: no partial token sum"   "$out" "tokens resident"

# A fractional used_percentage rounds to a usable integer.
place "$SID_A" "$(snapshot 64.6 200000 35.4 "$(now_ms)" "leg-A")" > /dev/null
outp="$(CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SCRIPT" --percent 2>/dev/null)"
check "fractional percent rounds to an integer" "$outp" "65"

# Trailing junk on a number is rejected, not truncated to a plausible prefix.
printf '%s' '{"used_percentage":42junk,"remaining_percentage":58,"context_window_size":500000,"saved_at":'"$(now_ms)"',"session_name":"leg-A"}' > "$pa"
out="$(CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SCRIPT" 2>/dev/null)"; rc=$?
check "trailing junk on a number: exit 4"          "$rc" "4"
check "trailing junk on a number: stdout is EMPTY" "$out" ""
err="$(CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SCRIPT" 2>&1 >/dev/null)"
contains "trailing junk on a number: says malformed" "$err" "malformed"

# An out-of-range percentage is not a fill measurement, whatever the file says.
place "$SID_A" "$(snapshot 150 500000 58 "$(now_ms)" "leg-A")" > /dev/null
out="$(CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SCRIPT" 2>/dev/null)"; rc=$?
check "out-of-range percentage: exit 4"          "$rc" "4"
check "out-of-range percentage: stdout is EMPTY" "$out" ""
err="$(CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SCRIPT" 2>&1 >/dev/null)"
contains "out-of-range percentage: says implausible" "$err" "implausible"

# A snapshot with no saved_at can never be certified fresh - UNKNOWN, never a
# happy-path readout of the number it happens to carry.
printf '%s' '{"used_percentage":42,"remaining_percentage":58,"context_window_size":500000,"session_name":"leg-A"}' > "$pa"
out="$(CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SCRIPT" 2>/dev/null)"; rc=$?
check "no saved_at: exit 4"          "$rc" "4"
check "no saved_at: stdout is EMPTY" "$out" ""
err="$(CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SCRIPT" 2>&1 >/dev/null)"
contains "no saved_at: says saved_at" "$err" "saved_at"
not_contains "no saved_at: never reports the number as current" "$out" "42"

# A non-numeric freshness window falls back to the default rather than
# silently disabling staleness detection.
stale_ms="$(awk -v s="$(date +%s)" 'BEGIN{printf "%.0f", (s-4000)*1000}')"
place "$SID_A" "$(snapshot 42 500000 58 "$stale_ms" "leg-A")" > /dev/null
outp="$(CLAUDE_CODE_SESSION_ID="$SID_A" CONTEXT_FILL_MAX_AGE_SECONDS=abc bash "$SCRIPT" --percent 2>/dev/null)"; rcp=$?
check "non-numeric freshness window: still STALE (exit 3)" "$rcp" "3"
check "non-numeric freshness window: stdout is EMPTY"      "$outp" ""
err="$(CLAUDE_CODE_SESSION_ID="$SID_A" CONTEXT_FILL_MAX_AGE_SECONDS=abc bash "$SCRIPT" --percent 2>&1 >/dev/null)"
contains "non-numeric freshness window: falls back to 900" "$err" "900"

# A future saved_at is clock skew or a corrupt timestamp, not a fresh reading.
future_ms="$(awk -v s="$(date +%s)" 'BEGIN{printf "%.0f", (s+4000)*1000}')"
place "$SID_A" "$(snapshot 42 500000 58 "$future_ms" "leg-A")" > /dev/null
out="$(CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SCRIPT" 2>/dev/null)"; rc=$?
check "future saved_at: exit 4"          "$rc" "4"
check "future saved_at: stdout is EMPTY" "$out" ""
err="$(CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SCRIPT" 2>&1 >/dev/null)"
contains "future saved_at: says future" "$err" "future"
not_contains "future saved_at: never reports the number as current" "$out" "42"

# A saved_at with trailing junk (e.g. a doubled decimal) is malformed, not a
# plausible-looking timestamp prefix awk would happily parse.
printf '%s' '{"used_percentage":42,"remaining_percentage":58,"context_window_size":500000,"saved_at":'"$(now_ms)"'.1.2,"session_name":"leg-A"}' > "$pa"
out="$(CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SCRIPT" 2>/dev/null)"; rc=$?
check "malformed saved_at: exit 4"          "$rc" "4"
check "malformed saved_at: stdout is EMPTY" "$out" ""
err="$(CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SCRIPT" 2>&1 >/dev/null)"
contains "malformed saved_at: says saved_at" "$err" "saved_at"

# An out-of-range remaining_percentage falls back to 100-used rather than
# being printed as-is.
place "$SID_A" "$(snapshot 40 500000 999 "$(now_ms)" "leg-A")" > /dev/null
out="$(CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SCRIPT" 2>&1)"; rc=$?
check "out-of-range remaining_percentage: exit 0" "$rc" "0"
contains     "out-of-range remaining_percentage: falls back to 100-used" "$out" "60% free"
not_contains "out-of-range remaining_percentage: never prints the bogus value" "$out" "999"

# --- 6. unresolvable session ------------------------------------------------
out="$(env -u CLAUDE_CODE_SESSION_ID bash "$SCRIPT" 2>/dev/null)"; rc=$?
check "no session id: exit 4"          "$rc" "4"
check "no session id: stdout is EMPTY" "$out" ""
err="$(env -u CLAUDE_CODE_SESSION_ID bash "$SCRIPT" 2>&1 >/dev/null)"
contains "no session id: says UNKNOWN" "$err" "UNKNOWN"

out="$(CLAUDE_CODE_SESSION_ID="no-such-session-id" bash "$SCRIPT" 2>/dev/null)"; rc=$?
check "unknown session id: exit 4"          "$rc" "4"
check "unknown session id: stdout is EMPTY" "$out" ""

# --- 6b. HIMMEL-2545: the rc=4 hint names the child-session cause -----------
# A session launched from inside a claude tool call inherits
# CLAUDE_CODE_CHILD_SESSION=1, claude saves no transcript for it, and this
# script's honest rc=4 then reads as "fill is blind on this station". The hint
# turns that into a cause and a recovery.
#
# The FALSE-POSITIVE is the whole difficulty: claude exports the marker into
# every process it spawns, THIS SCRIPT INCLUDED, so a check against our own
# environment would fire in every healthy session. The hint must read the
# claude PROCESS's environ (CLAUDE_PID) instead. Each control below differs
# from the positive case by exactly ONE fixture bit, so a hint that appears
# for the wrong reason cannot pass them.
# Every case below unsets CLAUDE_CODE_CHILD_SESSION and
# CLAUDE_CODE_FORCE_SESSION_PERSISTENCE explicitly before setting only what it
# means to set. This suite runs INSIDE a claude session, which exports both
# into it - and they are the very variables under test, so inheriting them
# silently disarms the controls. Verified: without the unsets, a deliberately
# naive implementation (one reading our own env instead of the claude
# process's) passed control (c) purely because the launching session happened
# to carry FORCE_SESSION_PERSISTENCE=1.
mkproc() {
  local root="$1" pid="$2" comm="$3"; shift 3
  mkdir -p "$root/$pid"
  printf '%s\n' "$comm" > "$root/$pid/comm"
  : > "$root/$pid/environ"
  local v
  for v in "$@"; do printf '%s\0' "$v" >> "$root/$pid/environ"; done
}
PROC="$tmp/proc"
HINT_MARK="inherited CLAUDE_CODE_CHILD_SESSION"

# (a) POSITIVE: the claude process carries the marker and no persistence flag.
mkproc "$PROC" 4242 claude 'CLAUDE_CODE_SESSION_ID=zz' 'CLAUDE_CODE_CHILD_SESSION=1'
err="$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_FORCE_SESSION_PERSISTENCE CONTEXT_FILL_PROC="$PROC" CLAUDE_PID=4242 bash "$SCRIPT" 2>&1 >/dev/null)"; rc=$?
check    "2545 child session: still exit 4"        "$rc" "4"
contains "2545 child session: hint names the cause" "$err" "$HINT_MARK"
contains "2545 child session: hint names the fix"   "$err" "CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1"
contains "2545 child session: hint cites the ticket" "$err" "HIMMEL-2545"

# (b) CONTROL - the launcher already did the right thing. Same tree, one extra
# environ entry. This is the shape every session armed through the patched
# arm-resume.sh has, so a hint here would fire on every correct launch.
mkproc "$PROC" 4243 claude 'CLAUDE_CODE_CHILD_SESSION=1' 'CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1'
err="$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_FORCE_SESSION_PERSISTENCE CONTEXT_FILL_PROC="$PROC" CLAUDE_PID=4243 bash "$SCRIPT" 2>&1 >/dev/null)"; rc=$?
check        "2545 persistence forced: still exit 4" "$rc" "4"
not_contains "2545 persistence forced: NO hint"      "$err" "$HINT_MARK"

# (c) CONTROL - the false positive the fix exists to avoid: OUR OWN env carries
# the marker (claude exports it to every tool subprocess) while the claude
# PROCESS does not. A healthy human-launched session failing rc=4 for some
# other reason must not be told to relaunch.
mkproc "$PROC" 4244 claude 'CLAUDE_CODE_SESSION_ID=zz'
err="$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_FORCE_SESSION_PERSISTENCE CONTEXT_FILL_PROC="$PROC" CLAUDE_PID=4244 CLAUDE_CODE_CHILD_SESSION=1 bash "$SCRIPT" 2>&1 >/dev/null)"; rc=$?
check        "2545 marker only in OUR env: still exit 4" "$rc" "4"
not_contains "2545 marker only in OUR env: NO hint"      "$err" "$HINT_MARK"

# (d) CONTROL - a stale CLAUDE_PID recycled onto an unrelated process. The
# environ carries the marker, but the process is not claude, so the reading is
# not ours to report.
mkproc "$PROC" 4245 bash 'CLAUDE_CODE_CHILD_SESSION=1'
err="$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_FORCE_SESSION_PERSISTENCE CONTEXT_FILL_PROC="$PROC" CLAUDE_PID=4245 bash "$SCRIPT" 2>&1 >/dev/null)"; rc=$?
check        "2545 stale pid on a non-claude process: still exit 4" "$rc" "4"
not_contains "2545 stale pid on a non-claude process: NO hint"      "$err" "$HINT_MARK"

# (e) CONTROL - no procfs entry at all (macOS, Git Bash, a dead pid). Silence,
# never a guess: this script's contract is refusing to invent a reading.
err="$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_FORCE_SESSION_PERSISTENCE CONTEXT_FILL_PROC="$PROC" CLAUDE_PID=999999 bash "$SCRIPT" 2>&1 >/dev/null)"; rc=$?
check        "2545 no procfs entry: still exit 4" "$rc" "4"
not_contains "2545 no procfs entry: NO hint"      "$err" "$HINT_MARK"

# (f) The hint belongs to the UNRESOLVABLE path only - a healthy session that
# reads its snapshot must never see it.
place "$SID_A" "$(snapshot 55 200000 45 "$(now_ms)" "leg-A")" > /dev/null
err="$(env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_FORCE_SESSION_PERSISTENCE CLAUDE_CODE_SESSION_ID="$SID_A" CONTEXT_FILL_PROC="$PROC" CLAUDE_PID=4242 bash "$SCRIPT" 2>&1 >/dev/null)"
not_contains "2545 resolvable session: NO hint" "$err" "$HINT_MARK"

# (g) SECURITY CONTROL - a non-numeric CLAUDE_PID must never reach the
# filesystem at all. A pid is a number; a value carrying path separators
# (e.g. ../../something) would otherwise let launched_as_child_session() walk
# OUTSIDE the intended proc root. The traversal TARGET is built to satisfy
# every check that follows it (comm=claude, CHILD_SESSION=1, no persistence)
# so this is only a real control if it fails on the CURRENT (unguarded) code
# and passes once the pid is validated first - see the mutant proof in the
# PR/scratchpad evidence log.
EVIL_PARENT="$(dirname "$PROC")"
mkproc "$EVIL_PARENT/outside-proc" 9999 claude 'CLAUDE_CODE_CHILD_SESSION=1'
err="$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_FORCE_SESSION_PERSISTENCE CONTEXT_FILL_PROC="$PROC" CLAUDE_PID="../outside-proc/9999" bash "$SCRIPT" 2>&1 >/dev/null)"; rc=$?
check        "2545 non-numeric pid rejected before filesystem access: still exit 4" "$rc" "4"
not_contains "2545 non-numeric pid rejected before filesystem access: NO hint"      "$err" "$HINT_MARK"

# (h) HIMMEL-2545 CR round-2 codex-5: an EMPTY CLAUDE_CODE_FORCE_SESSION_PERSISTENCE
# value is meaningless (no launcher in this diff ever sets it that way) and
# must be treated as ABSENT, not present - the hint must still fire.
mkproc "$PROC" 4246 claude 'CLAUDE_CODE_CHILD_SESSION=1' 'CLAUDE_CODE_FORCE_SESSION_PERSISTENCE='
err="$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_FORCE_SESSION_PERSISTENCE CONTEXT_FILL_PROC="$PROC" CLAUDE_PID=4246 bash "$SCRIPT" 2>&1 >/dev/null)"; rc=$?
check    "2545 empty persistence value: still exit 4"        "$rc" "4"
contains "2545 empty persistence value: hint STILL fires" "$err" "$HINT_MARK"

# (i) CONTROL - the asymmetric other direction: a NON-EMPTY value that is NOT
# literally "1" must still count as persistence-on. Requiring exactly "=1"
# would be the wrong fix - a session persisting under some other truthy
# spelling would then get told it is a broken child session, which is
# precisely the false positive every control in this file exists to prevent.
mkproc "$PROC" 4247 claude 'CLAUDE_CODE_CHILD_SESSION=1' 'CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=true'
err="$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_FORCE_SESSION_PERSISTENCE CONTEXT_FILL_PROC="$PROC" CLAUDE_PID=4247 bash "$SCRIPT" 2>&1 >/dev/null)"; rc=$?
check        "2545 non-'1' truthy persistence value: still exit 4" "$rc" "4"
not_contains "2545 non-'1' truthy persistence value: NO hint"      "$err" "$HINT_MARK"

# --- 7. explicit transcript override ----------------------------------------
ov="$CFG/projects/C--fixture-repo/$SID_A.jsonl"
p_ov="$(CONTEXT_FILL_TRANSCRIPT="$ov" env -u CLAUDE_CODE_SESSION_ID bash "$SCRIPT" --cache-path)"
check "CONTEXT_FILL_TRANSCRIPT resolves the same key as the session id" "$p_ov" "$pa"

# A relative CONTEXT_FILL_TRANSCRIPT must hash to the same absolute key as the
# equivalent absolute path - proof native_path() canonicalises on every platform.
p_rel="$(cd "$CFG/projects/C--fixture-repo" && CONTEXT_FILL_TRANSCRIPT="$SID_A.jsonl" env -u CLAUDE_CODE_SESSION_ID bash "$SCRIPT" --cache-path)"
check "relative CONTEXT_FILL_TRANSCRIPT resolves to the same key as absolute" "$p_rel" "$pa"

# --- 8a. frozen HUD snapshot: saved_at lags the session transcript (HIMMEL-2342) --
# The write-skip bug: when native used_percentage reads 0 while current_usage
# is non-zero (a documented in-flight tick), the HUD's cache-write gate
# (hasGoodContext) skips the write, but the render path still shows a live,
# higher number computed fresh from current_usage. The on-disk snapshot then
# freezes at its last genuine value while the transcript keeps growing. A
# frozen snapshot easily sits well inside the 900s age window - age alone
# cannot tell it apart from a quiet session - so only comparing saved_at
# against the transcript's own mtime exposes the freeze.
touch -m "$CFG/projects/C--fixture-repo/$SID_A.jsonl"
lag_ms="$(awk -v s="$(date +%s)" 'BEGIN{printf "%.0f", (s-300)*1000}')"
place "$SID_A" "$(snapshot 38 200000 62 "$lag_ms" "leg-A")" > /dev/null
out="$(CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SCRIPT" --percent 2>/dev/null)"; rc=$?
check "frozen snapshot: --percent exit 3"       "$rc" "3"
check "frozen snapshot: --percent stdout EMPTY" "$out" ""
err="$(CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SCRIPT" 2>&1 >/dev/null)"
contains "frozen snapshot: says STALE"            "$err" "STALE"
contains "frozen snapshot: names the freeze"      "$err" "frozen"
contains "frozen snapshot: names the HUD skip"    "$err" "skipped"
contains "frozen snapshot: reports the snapshot age" "$err" "age"
contains "frozen snapshot: reports the transcript lag" "$err" "lag"

# Negative control: a snapshot whose saved_at is AT/after the transcript's
# mtime must NOT trip the guard - a healthy session must still read.
fresh_ms="$(now_ms)"
place "$SID_A" "$(snapshot 55 200000 45 "$fresh_ms" "leg-A")" > /dev/null
out="$(CLAUDE_CODE_SESSION_ID="$SID_A" bash "$SCRIPT" --percent 2>/dev/null)"; rc=$?
check "healthy snapshot: --percent exit 0"    "$rc" "0"
check "healthy snapshot: --percent prints 55" "$out" "55"

# --- 8. usage contract ------------------------------------------------------
bash "$SCRIPT" --bogus >/dev/null 2>&1; check "unknown option -> exit 2" "$?" "2"
bash "$SCRIPT" --percent --bogus >/dev/null 2>&1; check "trailing argument after --percent -> exit 2" "$?" "2"
bash "$SCRIPT" --cache-path --bogus >/dev/null 2>&1; check "trailing argument after --cache-path -> exit 2" "$?" "2"
outh="$(bash "$SCRIPT" --help 2>&1)"; rc=$?
check "--help exit 0" "$rc" "0"
contains "--help names the spend-budget distinction" "$outh" "spend"
contains "--help documents the exit codes"           "$outh" "exit 3 = STALE"

[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
