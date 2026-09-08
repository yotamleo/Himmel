#!/usr/bin/env bash
# scripts/lib/test-bank-attribution.sh -- fixture test for bank-attribution.sh
# (HIMMEL-2764). Builds synthetic sessions under mktemp -d projects roots
# (never a live vault) covering: a named session (customTitle) with all three
# wake sources plus a streamed turn with a duplicate usage row plus an inline
# sidechain turn; an ai-title-only session; a fully unnamed session; a
# session (second root) using the real `<sessionId>/subagents/*.jsonl`
# layout plus a wake source set BEFORE a --since cutoff that must still
# classify an in-window turn; a session (same root) with an ORPHANED
# subagents/ dir and no top-level file at all; and a session (third root)
# whose --since cutoff carries less fractional precision than its own
# transcript row; and a session (fourth root) alongside a malformed
# transcript file, which must not suppress the good session's row but must
# make the run exit 2 and report the skip on stderr. Also checks --top
# rejects a negative value. Asserts exact expected numbers, including a
# deliberately-wrong RED control so a silently-vacuous assertion would be
# caught.
#
# Platform guard (gitbash-only): pure bash 3.2-safe + jq, no .ps1 twin needed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/bank-attribution.sh"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-bank-attribution.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

SLUG_DIR="$ROOT/test-slug"
mkdir -p "$SLUG_DIR"

FAIL=0
assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  local hit
  hit=$(printf '%s' "$haystack" | grep -F "$needle") || true
  if [ -z "$hit" ]; then
    echo "FAIL: $label -- expected to find: $needle" >&2
    FAIL=1
  fi
}

# --- Session A: named, all 3 wake sources, a duplicate-usage streamed turn,
#     one sidechain (subagent) turn. -------------------------------------
SID_A="aaaaaaaa-0000-0000-0000-000000000001"
cat > "$SLUG_DIR/$SID_A.jsonl" <<EOF
{"type":"custom-title","customTitle":"Session-A","sessionId":"$SID_A"}
{"type":"bridge-session","sessionId":"$SID_A","ownerAccountUuid":"11111111-aaaa-bbbb-cccc-111111111111"}
{"type":"user","sessionId":"$SID_A","isSidechain":false,"timestamp":"2026-01-01T00:00:01.000Z","message":{"content":"do the thing"}}
{"type":"assistant","sessionId":"$SID_A","isSidechain":false,"timestamp":"2026-01-01T00:00:02.000Z","requestId":"reqA1","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":5,"output_tokens":20}}}
{"type":"assistant","sessionId":"$SID_A","isSidechain":false,"timestamp":"2026-01-01T00:00:02.000Z","requestId":"reqA1","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":5,"output_tokens":20}}}
{"type":"user","sessionId":"$SID_A","isSidechain":false,"timestamp":"2026-01-01T00:00:03.000Z","message":{"content":"<cross-session-message from=\"x\">hello</cross-session-message>"}}
{"type":"assistant","sessionId":"$SID_A","isSidechain":false,"timestamp":"2026-01-01T00:00:04.000Z","requestId":"reqA2","message":{"usage":{"input_tokens":11,"cache_read_input_tokens":101,"cache_creation_input_tokens":6,"output_tokens":21}}}
{"type":"user","sessionId":"$SID_A","isSidechain":false,"timestamp":"2026-01-01T00:00:05.000Z","message":{"content":"<task-notification>\n<task-id>t1</task-id>\n</task-notification>"}}
{"type":"assistant","sessionId":"$SID_A","isSidechain":false,"timestamp":"2026-01-01T00:00:06.000Z","requestId":"reqA3","message":{"usage":{"input_tokens":12,"cache_read_input_tokens":102,"cache_creation_input_tokens":7,"output_tokens":22}}}
{"type":"user","sessionId":"$SID_A","isSidechain":true,"timestamp":"2026-01-01T00:00:07.000Z","message":{"content":"subagent prompt"}}
{"type":"assistant","sessionId":"$SID_A","isSidechain":true,"timestamp":"2026-01-01T00:00:08.000Z","requestId":"reqA4","message":{"usage":{"input_tokens":50,"cache_read_input_tokens":500,"cache_creation_input_tokens":25,"output_tokens":100}}}
EOF

# --- Session B: ai-title only (not "named") -------------------------------
SID_B="bbbbbbbb-0000-0000-0000-000000000002"
cat > "$SLUG_DIR/$SID_B.jsonl" <<EOF
{"type":"ai-title","aiTitle":"Session-B-ai","sessionId":"$SID_B"}
{"type":"user","sessionId":"$SID_B","isSidechain":false,"timestamp":"2026-01-01T00:00:01.000Z","message":{"content":"hi"}}
{"type":"assistant","sessionId":"$SID_B","isSidechain":false,"timestamp":"2026-01-01T00:00:02.000Z","requestId":"reqB1","message":{"usage":{"input_tokens":1,"cache_read_input_tokens":2,"cache_creation_input_tokens":3,"output_tokens":4}}}
EOF

# --- Session C: fully unnamed ---------------------------------------------
SID_C="cccccccc-0000-0000-0000-000000000003"
cat > "$SLUG_DIR/$SID_C.jsonl" <<EOF
{"type":"user","sessionId":"$SID_C","isSidechain":false,"timestamp":"2026-01-01T00:00:01.000Z","message":{"content":"hi"}}
{"type":"assistant","sessionId":"$SID_C","isSidechain":false,"timestamp":"2026-01-01T00:00:02.000Z","requestId":"reqC1","message":{"usage":{"input_tokens":100,"cache_read_input_tokens":200,"cache_creation_input_tokens":300,"output_tokens":400}}}
EOF

OUT="$(bash "$SCRIPT" "$ROOT")"

# Session A: 3 main turns (duplicate reqA1 row counted once), wake 1/1/1,
# main totals input=33 cache_read=303 cache_create=18 output=63; sub turn=1
# input=50 cache_read=500 cache_create=25 output=100.
assert_contains "$OUT" "| Session-A | test-slug | 11111111 | 3 | 33 | 303 | 18 | 63 | 1/1/1 | 1 |" "session A main row"
assert_contains "$OUT" "| Session-A (subagents) | test-slug | 11111111 | 1 | 50 | 500 | 25 | 100 | - | - |" "session A subagent row"

# Session B: ai-title used as name, single operator turn.
assert_contains "$OUT" "| Session-B-ai | test-slug | n/a | 1 | 1 | 2 | 3 | 4 | 1/0/0 | 0 |" "session B row"

# Session C: falls back to the sessionId prefix.
assert_contains "$OUT" "| cccccccc | test-slug | n/a | 1 | 100 | 200 | 300 | 400 | 1/0/0 | 0 |" "session C row"

# Grand total across all 3 sessions (main + sub):
# A: 33+303+18+63 + 50+500+25+100 = 417 + 675 = 1092
# B: 1+2+3+4 = 10
# C: 100+200+300+400 = 1000
# grand = 2102; attributed (named=true, session A only) = 1092
# 1092*10000/2102 = 5195.05... round -> 5195 -> 51.95
assert_contains "$OUT" "attributed 51.95 % of tokens to named sessions (main + subagent tokens combined)" "attributed percentage"

# Total (subagents) row: only session A contributed sub tokens.
assert_contains "$OUT" "| **total (subagents)** | | | 1 | 50 | 500 | 25 | 100 | | |" "total (subagents) row"

# RED control: a deliberately wrong expectation must NOT be found in the
# output -- proves the output itself isn't vacuously matching anything.
red_hit=$(printf '%s' "$OUT" | grep -F "attributed 99.99 % of tokens to named sessions") || true
if [ -n "$red_hit" ]; then
  echo "FAIL: RED control did not fail -- assertion harness is vacuous" >&2
  FAIL=1
fi

# RED control on the helper itself (HIMMEL-2764 CR round 5, codex-2): prove
# assert_contains can actually detect a missing needle, not just that grep
# can. Runs in a subshell so its deliberate failure never leaks into the
# real $FAIL.
if ( FAIL=0
     assert_contains "$OUT" "this needle absolutely does not appear anywhere" "assert_contains self-test" >/dev/null 2>&1
     exit "$FAIL" ); then
  echo "FAIL: assert_contains did not detect a missing needle -- assertion helper is vacuous" >&2
  FAIL=1
fi

# --since filters out everything (all fixture rows predate the cutoff).
OUT_SINCE="$(bash "$SCRIPT" "$ROOT" --since 2099-01-01T00:00:00)"
assert_contains "$OUT_SINCE" "attributed 0 % of tokens to named sessions (main + subagent tokens combined)" "--since excludes all fixture rows"

# --project filters to the given slug (no-op here, single slug, but must not error).
OUT_PROJECT="$(bash "$SCRIPT" "$ROOT" --project test-slug)"
assert_contains "$OUT_PROJECT" "Session-A" "--project keeps the matching slug"

# --top limits the number of session groups shown.
OUT_TOP1="$(bash "$SCRIPT" "$ROOT" --top 1)"
assert_contains "$OUT_TOP1" "Session-A" "--top 1 keeps the highest-token session"
top1_hit=$(printf '%s' "$OUT_TOP1" | grep -F "Session-B-ai") || true
if [ -n "$top1_hit" ]; then
  echo "FAIL: --top 1 did not limit output" >&2
  FAIL=1
fi

# --- Session D (separate root): real subagent-file layout
#     (<sessionId>/subagents/*.jsonl, isSidechain:true throughout, HIMMEL-2764
#     CR round 1 codex-1) plus a wake source set BEFORE the --since cutoff
#     whose classification must still carry forward to an in-window turn
#     (codex-2: title/account/wake tracking must never be gated by --since,
#     only the counted usage rows are). --------------------------------
ROOT2="$(mktemp -d "${TMPDIR:-/tmp}/test-bank-attribution-2.XXXXXX")"
SLUG_DIR2="$ROOT2/test-slug"
SID_D="dddddddd-0000-0000-0000-000000000004"
mkdir -p "$SLUG_DIR2" "$SLUG_DIR2/$SID_D/subagents"

cat > "$SLUG_DIR2/$SID_D.jsonl" <<EOF
{"type":"custom-title","customTitle":"Session-D","sessionId":"$SID_D"}
{"type":"user","sessionId":"$SID_D","isSidechain":false,"timestamp":"2026-02-01T00:00:01.000Z","message":{"content":"<cross-session-message from=\"x\">before cutoff</cross-session-message>"}}
{"type":"assistant","sessionId":"$SID_D","isSidechain":false,"timestamp":"2026-02-01T00:00:10.000Z","requestId":"reqD1","message":{"usage":{"input_tokens":7,"cache_read_input_tokens":8,"cache_creation_input_tokens":9,"output_tokens":10}}}
EOF

cat > "$SLUG_DIR2/$SID_D/subagents/agent-1.jsonl" <<EOF
{"type":"user","sessionId":"$SID_D","isSidechain":true,"timestamp":"2026-02-01T00:00:11.000Z","message":{"content":"subagent prompt"}}
{"type":"assistant","sessionId":"$SID_D","isSidechain":true,"timestamp":"2026-02-01T00:00:12.000Z","requestId":"reqDsub1","message":{"usage":{"input_tokens":20,"cache_read_input_tokens":21,"cache_creation_input_tokens":22,"output_tokens":23}}}
EOF

# --- Session F (same root): an ORPHANED subagents/ directory -- its own
#     top-level <sid>.jsonl does not exist (pruned/rotated), but the
#     subagents/ tree survives. Confirmed on this station (HIMMEL-2764 CR
#     round 6, codex-2): subagent directories must be discovered
#     independently of the top-level file, not only alongside it. --------
SID_F="ffffffff-0000-0000-0000-000000000006"
mkdir -p "$SLUG_DIR2/$SID_F/subagents"
cat > "$SLUG_DIR2/$SID_F/subagents/agent-1.jsonl" <<EOF
{"type":"assistant","sessionId":"$SID_F","isSidechain":true,"timestamp":"2026-02-01T00:00:01.000Z","requestId":"reqFsub1","message":{"usage":{"input_tokens":30,"cache_read_input_tokens":31,"cache_creation_input_tokens":32,"output_tokens":33}}}
EOF

trap 'rm -rf "$ROOT" "$ROOT2"' EXIT

# The wake-setting user row (00:00:01) is itself BEFORE the cutoff (00:00:05)
# and would be excluded from the counted window, but its "cs" classification
# must still apply to the in-window assistant turn at 00:00:10.
OUT_D="$(bash "$SCRIPT" "$ROOT2" --since 2026-02-01T00:00:05.000Z)"
assert_contains "$OUT_D" "| Session-D | test-slug | n/a | 1 | 7 | 8 | 9 | 10 | 0/1/0 | 1 |" "session D wake carries across --since cutoff"
assert_contains "$OUT_D" "| Session-D (subagents) | test-slug | n/a | 1 | 20 | 21 | 22 | 23 | - | - |" "session D real subagent-file layout is scanned"

# Session F has no top-level file at all, so it is excluded by the
# --since 00:00:05 cutoff run above (its row is at 00:00:01). Run unfiltered
# to confirm the orphaned subagent directory is scanned regardless.
OUT_F="$(bash "$SCRIPT" "$ROOT2")"
assert_contains "$OUT_F" "| ffffffff (subagents) | test-slug | n/a | 1 | 30 | 31 | 32 | 33 | - | - |" "orphaned subagents/ dir (no sibling top-level file) is scanned"

# --- Session E (separate root): --since has LESS fractional precision than
#     the transcript row (HIMMEL-2764 CR round 3, codex-1) -- a cutoff of
#     "...:05Z" (implicitly .000) must not exclude a row at "...:05.500Z"
#     just because "." sorts before "Z" in an un-normalized lexicographic
#     compare. ------------------------------------------------------------
ROOT3="$(mktemp -d "${TMPDIR:-/tmp}/test-bank-attribution-3.XXXXXX")"
SLUG_DIR3="$ROOT3/test-slug"
SID_E="eeeeeeee-0000-0000-0000-000000000005"
mkdir -p "$SLUG_DIR3"
cat > "$SLUG_DIR3/$SID_E.jsonl" <<EOF
{"type":"custom-title","customTitle":"Session-E","sessionId":"$SID_E"}
{"type":"user","sessionId":"$SID_E","isSidechain":false,"timestamp":"2026-03-01T00:00:05.500Z","message":{"content":"hi"}}
{"type":"assistant","sessionId":"$SID_E","isSidechain":false,"timestamp":"2026-03-01T00:00:05.500Z","requestId":"reqE1","message":{"usage":{"input_tokens":1,"cache_read_input_tokens":1,"cache_creation_input_tokens":1,"output_tokens":1}}}
EOF

trap 'rm -rf "$ROOT" "$ROOT2" "$ROOT3"' EXIT

OUT_E="$(bash "$SCRIPT" "$ROOT3" --since 2026-03-01T00:00:05Z)"
assert_contains "$OUT_E" "| Session-E | test-slug | n/a | 1 | 1 | 1 | 1 | 1 | 1/0/0 | 0 |" "a lower-precision --since does not exclude a higher-precision in-window row"

# --top rejects a negative value (a jq slice-from-the-end index, not a count).
TOP_NEG_ERR="$(mktemp "${TMPDIR:-/tmp}/test-bank-attribution-top-neg.XXXXXX")"
top_neg_rc=0
bash "$SCRIPT" "$ROOT" --top -1 >/dev/null 2>"$TOP_NEG_ERR" || top_neg_rc=$?
if [ "$top_neg_rc" -eq 0 ]; then
  echo "FAIL: --top -1 was accepted instead of rejected" >&2
  FAIL=1
fi
assert_contains "$(cat "$TOP_NEG_ERR")" "non-negative integer" "--top -1 is rejected with a clear error"
rm -f "$TOP_NEG_ERR"

# --- Session G (separate root): a malformed transcript file alongside a good
#     one (HIMMEL-2764 CR, post-CodeRabbit round, codex-1) -- the good
#     session's row must still print, and the run must exit nonzero and
#     report on stderr that a transcript was skipped, so a caller cannot
#     mistake a partial report for a complete one. ------------------------
ROOT4="$(mktemp -d "${TMPDIR:-/tmp}/test-bank-attribution-4.XXXXXX")"
SLUG_DIR4="$ROOT4/test-slug"
SID_G="99999999-0000-0000-0000-000000000007"
SID_BAD="88888888-0000-0000-0000-000000000008"
mkdir -p "$SLUG_DIR4"
cat > "$SLUG_DIR4/$SID_G.jsonl" <<EOF
{"type":"custom-title","customTitle":"Session-G","sessionId":"$SID_G"}
{"type":"user","sessionId":"$SID_G","isSidechain":false,"timestamp":"2026-04-01T00:00:01.000Z","message":{"content":"hi"}}
{"type":"assistant","sessionId":"$SID_G","isSidechain":false,"timestamp":"2026-04-01T00:00:02.000Z","requestId":"reqG1","message":{"usage":{"input_tokens":5,"cache_read_input_tokens":6,"cache_creation_input_tokens":7,"output_tokens":8}}}
EOF
printf '{"type":"user"\n' > "$SLUG_DIR4/$SID_BAD.jsonl"

trap 'rm -rf "$ROOT" "$ROOT2" "$ROOT3" "$ROOT4"' EXIT

BAD_ERR="$(mktemp "${TMPDIR:-/tmp}/test-bank-attribution-bad.XXXXXX")"
bad_rc=0
OUT_G="$(bash "$SCRIPT" "$ROOT4" 2>"$BAD_ERR")" || bad_rc=$?
if [ "$bad_rc" -ne 2 ]; then
  echo "FAIL: a malformed transcript file did not exit 2 (rc=$bad_rc)" >&2
  FAIL=1
fi
assert_contains "$OUT_G" "| Session-G | test-slug | n/a | 1 | 5 | 6 | 7 | 8 | 1/0/0 | 0 |" "the good session's row still prints alongside a malformed file"
assert_contains "$(cat "$BAD_ERR")" "skipped unreadable transcript" "a malformed transcript is reported on stderr, not silently dropped"
rm -f "$BAD_ERR"

if [ "$FAIL" -eq 0 ]; then
  echo "OK: bank-attribution.sh fixture assertions passed"
else
  echo "FAIL: bank-attribution.sh fixture assertions failed" >&2
  exit 1
fi
