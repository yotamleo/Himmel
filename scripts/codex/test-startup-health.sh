#!/usr/bin/env bash
# Hermetic tests for startup-health.sh (HIMMEL-747).
# No real Codex install: each case builds a temp CODEX_HOME with a synthetic
# rollout .jsonl (names the session thread_id) + a synthetic logs_2.sqlite. The
# detector reads logs_2.sqlite by printable-run byte extraction (grep -aoE), NOT
# via a sqlite driver, so a plain text file carrying the real WARN message shapes
# is a faithful fixture. Asserts: healthy -> 0; each signal detected -> 1 + its
# WARN line; a marker under an OLD (non-current) thread_id does NOT fire (session
# scoping); oversized _where-are-we -> 1; missing CODEX_HOME -> 2; bad arg -> 2.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECT="$SCRIPT_DIR/startup-health.sh"
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }

fails=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

NEW_TID="019f3c01-afbf-7ef3-a689-c5be6d9afde0"
OLD_TID="019f0000-0000-7000-8000-000000000000"

# make_home <name> <tid> <waw_text> -> echoes the CODEX_HOME path (no logs_2.sqlite yet)
make_home() {
  local home="$TMP/$1" tid="$2" waw="$3"
  local dir="$home/sessions/2026/07/07"
  mkdir -p "$dir"
  # Rollout filename ends in the thread_id; lexical sort picks the newest.
  local f="$dir/rollout-2026-07-07T11-56-16-$tid.jsonl"
  # A token_count line (noise) + the where-are-we injection line.
  printf '%s\n' '{"type":"event_msg","payload":{"type":"token_count"}}' > "$f"
  jq -cn --arg t "$waw" '{type:"response_item",payload:{type:"message",content:[{type:"text",text:$t}]}}' >> "$f"
  echo "$home"
}

# A real-shape WARN row body (level+target+span+message on one printable line).
db_hook_row()  { printf 'WARN codex_core_plugins::manifest session_loop{thread_id=%s}:submission_dispatch{}:turn: load_plugins_from_layer_stack: ignoring hooks: expected a string, string array, object, or object array; found object\n' "$1"; }
db_skill_row() { printf 'WARN codex_core_plugins::manifest session_loop{thread_id=%s}:built_tools: ignoring interface.defaultPrompt[0]: prompt must be at most 128 characters path=X/.codex-plugin/plugin.json\n' "$1"; }
db_noise_row() { printf 'INFO codex_core_skills::service session_loop{thread_id=%s}: skills cache cleared (0 entries)\n' "$1"; }

SMALL_WAW="<system-reminder>
_where-are-we

# Where are we

## In flight
(none)"

# check_rc <want> <got> <msg>  /  want_line <needle> <text> <msg>
check_rc()   { if [ "$2" -eq "$1" ]; then pass "$3"; else fail "$3 (got exit $2)"; fi; }
want_line()  { if printf '%s\n' "$2" | grep -q "$1"; then pass "$3"; else fail "$3 (out: $2)"; fi; }

# --- 1. healthy: current session, no warn rows, small where-are-we -> exit 0 ----
H="$(make_home healthy "$NEW_TID" "$SMALL_WAW")"
db_noise_row "$NEW_TID" > "$H/logs_2.sqlite"
rc=0; out="$(CODEX_HOME="$H" bash "$DETECT" 2>&1)" || rc=$?
check_rc 0 "$rc" "healthy -> exit 0"
if [ -z "$out" ]; then pass "healthy -> no findings printed"; else fail "healthy printed: $out"; fi

# --- 2. hook-failure detected (scoped to current tid) -> exit 1 -----------------
H="$(make_home hookfail "$NEW_TID" "$SMALL_WAW")"
{ db_noise_row "$NEW_TID"; db_hook_row "$NEW_TID"; } > "$H/logs_2.sqlite"
rc=0; out="$(CODEX_HOME="$H" bash "$DETECT" 2>&1)" || rc=$?
check_rc 1 "$rc" "hook-failure -> exit 1"
want_line '^WARN hook-failure:' "$out" "hook-failure WARN line present"

# --- 3. skill-truncation detected -> exit 1 ------------------------------------
H="$(make_home skilltrunc "$NEW_TID" "$SMALL_WAW")"
{ db_skill_row "$NEW_TID"; db_skill_row "$NEW_TID"; } > "$H/logs_2.sqlite"
rc=0; out="$(CODEX_HOME="$H" bash "$DETECT" 2>&1)" || rc=$?
check_rc 1 "$rc" "skill-truncation -> exit 1"
want_line '^WARN skill-truncation:.*2 skill' "$out" "skill-truncation counts 2"

# --- 4. session scoping: marker under an OLD tid must NOT fire -> exit 0 --------
# Newest session is NEW_TID (healthy); the DB carries hook+skill rows but only for
# the OLD tid (a since-fixed misconfig whose stale rows persist append-only).
H="$(make_home scoping "$NEW_TID" "$SMALL_WAW")"
# add an older session file so the dir has two; NEW_TID sorts later (newest).
mkdir -p "$H/sessions/2026/07/01"
printf '%s\n' '{"type":"event_msg","payload":{"type":"token_count"}}' > "$H/sessions/2026/07/01/rollout-2026-07-01T00-00-00-$OLD_TID.jsonl"
{ db_hook_row "$OLD_TID"; db_skill_row "$OLD_TID"; } > "$H/logs_2.sqlite"
rc=0; out="$(CODEX_HOME="$H" bash "$DETECT" 2>&1)" || rc=$?
check_rc 0 "$rc" "stale-only markers (old tid) -> exit 0 (scoped out)"

# --- 5. oversized _where-are-we -> exit 1 --------------------------------------
BIG_WAW="<system-reminder>
# Where are we
$(printf 'x%.0s' $(seq 1 400))"
H="$(make_home bigwaw "$NEW_TID" "$BIG_WAW")"
db_noise_row "$NEW_TID" > "$H/logs_2.sqlite"
rc=0; out="$(CODEX_HOME="$H" WHERE_ARE_WE_BUDGET_BYTES=200 bash "$DETECT" 2>&1)" || rc=$?
check_rc 1 "$rc" "oversized where-are-we -> exit 1"
want_line '^WARN where-are-we-oversized:' "$out" "where-are-we-oversized line present"
# same big block stays healthy under a generous budget (proves it is the size, not presence)
rc=0; out="$(CODEX_HOME="$H" WHERE_ARE_WE_BUDGET_BYTES=100000 bash "$DETECT" 2>&1)" || rc=$?
check_rc 0 "$rc" "big block under generous budget -> exit 0"

# --- 6. missing CODEX_HOME -> exit 2 -------------------------------------------
rc=0; out="$(CODEX_HOME="$TMP/nope/.codex" bash "$DETECT" 2>&1)" || rc=$?
check_rc 2 "$rc" "missing CODEX_HOME -> exit 2"

# --- 7. unknown arg -> exit 2 --------------------------------------------------
rc=0; CODEX_HOME="$H" bash "$DETECT" --bogus >/dev/null 2>&1 || rc=$?
check_rc 2 "$rc" "unknown arg -> exit 2"

echo ""
if [ "$fails" -eq 0 ]; then echo "PASS"; else echo "FAIL ($fails)"; exit 1; fi
