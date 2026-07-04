#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUSLINE="$SCRIPT_DIR/../bin/statusline.sh"

# ── Inline deps from original script ──────────────────────
iso_to_epoch() {
    local iso_str="$1"
    local epoch stripped
    epoch=$(date -d "${iso_str}" +%s 2>/dev/null)
    [ -n "$epoch" ] && echo "$epoch" && return 0
    stripped="${iso_str%%.*}"; stripped="${stripped%%Z}"; stripped="${stripped%%+*}"
    stripped="${stripped%%-[0-9][0-9]:[0-9][0-9]}"
    if [[ "$iso_str" == *"Z"* ]] || [[ "$iso_str" == *"+00:00"* ]]; then
        epoch=$(env TZ=UTC date -d "${stripped/T/ }" +%s 2>/dev/null)
    else
        epoch=$(date -d "${stripped/T/ }" +%s 2>/dev/null)
    fi
    [ -n "$epoch" ] && echo "$epoch" && return 0
    return 1
}

red='\033[38;2;255;85;85m'; green='\033[38;2;0;175;80m'
orange='\033[38;2;255;176;85m'; yellow='\033[38;2;230;200;0m'
white='\033[38;2;220;220;220m'; dim='\033[2m'; reset='\033[0m'

color_for_pct() {
    local pct=$1
    if   [ "$pct" -ge 90 ]; then printf "$red"
    elif [ "$pct" -ge 70 ]; then printf "$yellow"
    elif [ "$pct" -ge 50 ]; then printf "$orange"
    else printf "$green"; fi
}

build_bar() {
    local pct=$1 width=$2 filled empty bar_color fs="" es=""
    [ "$pct" -lt 0 ] 2>/dev/null && pct=0
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100
    filled=$(( pct * width / 100 )); empty=$(( width - filled ))
    bar_color=$(color_for_pct "$pct")
    for ((i=0; i<filled; i++)); do fs+="●"; done
    for ((i=0; i<empty; i++)); do es+="○"; done
    printf "${bar_color}${fs}${dim}${es}${reset}"
}

# ── Source cache functions from statusline.sh ──────────────
eval "$(sed -n '/^# ── Cache metrics functions/,/^# ── End cache metrics functions/p' "$STATUSLINE")"
if ! declare -f format_tokens >/dev/null 2>&1; then
    echo "ERROR: failed to source cache functions from $STATUSLINE" >&2; exit 1
fi

# ── Test framework ─────────────────────────────────────────
PASS=0; FAIL=0
assert_eq() {
    local desc="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
        echo "PASS: $desc"; PASS=$(( PASS + 1 ))
    else
        echo "FAIL: $desc"; echo "  got:  '$got'"; echo "  want: '$want'"; FAIL=$(( FAIL + 1 ))
    fi
}

# ── format_tokens tests ────────────────────────────────────
assert_eq "format 0"       "$(format_tokens 0)"       "0"
assert_eq "format 999"     "$(format_tokens 999)"     "999"
assert_eq "format 1000"    "$(format_tokens 1000)"    "1k"
assert_eq "format 45321"   "$(format_tokens 45321)"   "45k"
assert_eq "format 1000000" "$(format_tokens 1000000)" "1.0M"
assert_eq "format 1234567" "$(format_tokens 1234567)" "1.2M"
assert_eq "format empty"   "$(format_tokens '')"      "0"
assert_eq "format bad"     "$(format_tokens abc)"     "0"
# B (billions) tier (HIMMEL-704) + the just-under-1B boundary staying M.
assert_eq "format 999999999"  "$(format_tokens 999999999)"  "1000.0M"
assert_eq "format 1000000000" "$(format_tokens 1000000000)" "1.0B"
assert_eq "format 2500000000" "$(format_tokens 2500000000)" "2.5B"

# ── format_usd tests (HIMMEL-704) ──────────────────────────
# Below $1000 keeps the raw %.4f (so the byte-exact golden fixture and small
# net/cost displays are unchanged); >= $1000 scales to K/M/B.
assert_eq "usd 0"       "$(format_usd 0)"        "0.0000"
assert_eq "usd 0.0876"  "$(format_usd 0.0876)"   "0.0876"
assert_eq "usd 69.465"  "$(format_usd 69.4650)"  "69.4650"
assert_eq "usd 999"     "$(format_usd 999)"      "999.0000"
assert_eq "usd 1000"    "$(format_usd 1000)"     "1.0K"
assert_eq "usd 1500"    "$(format_usd 1500)"     "1.5K"
assert_eq "usd 1234567" "$(format_usd 1234567)"  "1.2M"
assert_eq "usd 2.5e9"   "$(format_usd 2500000000)" "2.5B"

# ── get_model_savings_rate tests ───────────────────────────
get_model_savings_rate "claude-sonnet-4-6"
assert_eq "sonnet read_savings_rate"   "$read_savings_rate"   "0.00000270"
assert_eq "sonnet write_overhead_rate" "$write_overhead_rate" "0.00000300"

get_model_savings_rate "claude-opus-4-7"
assert_eq "opus read_savings_rate"     "$read_savings_rate"   "0.00000450"
assert_eq "opus write_overhead_rate"   "$write_overhead_rate" "0.00000500"

get_model_savings_rate "claude-haiku-4-5"
assert_eq "haiku read_savings_rate"    "$read_savings_rate"   "0.00000090"
assert_eq "haiku write_overhead_rate"  "$write_overhead_rate" "0.00000100"

# Fable red-path: must NOT fall through to the sonnet default (0.00000270).
# (10 - 1) / 1e6 = 0.00000900 read; (20 - 10) / 1e6 = 0.00001000 write.
get_model_savings_rate "claude-fable-5"
assert_eq "fable read_savings_rate"    "$read_savings_rate"   "0.00000900"
assert_eq "fable write_overhead_rate"  "$write_overhead_rate" "0.00001000"

# Mythos shares fable's rates; assert the branch is not a silent fallthrough.
get_model_savings_rate "claude-mythos-5"
assert_eq "mythos read_savings_rate"   "$read_savings_rate"   "0.00000900"
assert_eq "mythos write_overhead_rate" "$write_overhead_rate" "0.00001000"

# glm-* / gpt-5*: cache_write == input, so write_overhead must be exactly 0
# (z.ai free-write / no-write-premium boundary). Guard the zero-diff case.
get_model_savings_rate "glm-4.6"
assert_eq "glm read_savings_rate"      "$read_savings_rate"   "0.00000114"
assert_eq "glm write_overhead_rate"    "$write_overhead_rate" "0.00000000"

get_model_savings_rate "gpt-5.5"
assert_eq "gpt5 read_savings_rate"     "$read_savings_rate"   "0.00000450"
assert_eq "gpt5 write_overhead_rate"   "$write_overhead_rate" "0.00000000"

get_model_savings_rate "unknown-model"
assert_eq "fallback read_savings_rate" "$read_savings_rate"   "0.00000270"

# ── compute_cache_ttl tests ────────────────────────────────
NOW=$(date +%s)

# 1h cache: wrote 30 minutes ago → ~30m remaining, pct ~50%
WROTE_30M_AGO=$(date -d "@$(( NOW - 1800 ))" -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -r $(( NOW - 1800 )) +"%Y-%m-%dT%H:%M:%SZ")
compute_cache_ttl "$WROTE_30M_AGO" 3600
if [ "$cache_ttl_pct" -ge 45 ] && [ "$cache_ttl_pct" -le 55 ]; then
    echo "PASS: 1h cache 30m ago pct ~50% (got ${cache_ttl_pct}%)"; PASS=$(( PASS + 1 ))
else
    echo "FAIL: 1h cache 30m ago pct want 45-55%, got ${cache_ttl_pct}%"; FAIL=$(( FAIL + 1 ))
fi
if [ "$cache_ttl_str" != "expired" ] && [ -n "$cache_ttl_str" ]; then
    echo "PASS: 1h cache 30m ago not expired (got $cache_ttl_str)"; PASS=$(( PASS + 1 ))
else
    echo "FAIL: 1h cache 30m ago should not be expired, got '$cache_ttl_str'"; FAIL=$(( FAIL + 1 ))
fi

# 5m cache: wrote 6 minutes ago → expired
WROTE_6M_AGO=$(date -d "@$(( NOW - 360 ))" -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -r $(( NOW - 360 )) +"%Y-%m-%dT%H:%M:%SZ")
compute_cache_ttl "$WROTE_6M_AGO" 300
assert_eq "5m cache expired str" "$cache_ttl_str" "expired"
assert_eq "5m cache expired pct" "$cache_ttl_pct" "0"

# Empty ISO → silent skip (str stays empty)
compute_cache_ttl "" 3600
assert_eq "empty iso: ttl_str empty" "$cache_ttl_str" ""

# "null" ISO → silent skip
compute_cache_ttl "null" 3600
assert_eq "null iso: ttl_str empty" "$cache_ttl_str" ""

# Fresh write (2s ago) → pct >= 99
WROTE_2S_AGO=$(date -d "@$(( NOW - 2 ))" -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -r $(( NOW - 2 )) +"%Y-%m-%dT%H:%M:%SZ")
compute_cache_ttl "$WROTE_2S_AGO" 3600
if [ "$cache_ttl_pct" -ge 99 ]; then
    echo "PASS: fresh 1h write pct>=99 (got ${cache_ttl_pct}%)"; PASS=$(( PASS + 1 ))
else
    echo "FAIL: fresh write want pct>=99, got ${cache_ttl_pct}%"; FAIL=$(( FAIL + 1 ))
fi

# ── read_session_cache_stats tests ────────────────────────
TMPDIR_TEST=$(mktemp -d)
TRANSCRIPT="$TMPDIR_TEST/session.jsonl"

cat > "$TRANSCRIPT" <<'EOF'
{"type":"user","message":{"role":"user","content":"hello"}}
{"type":"assistant","timestamp":"2026-05-16T10:00:00.000Z","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":100,"cache_creation_input_tokens":5000,"cache_read_input_tokens":0,"output_tokens":50,"cache_creation":{"ephemeral_1h_input_tokens":5000,"ephemeral_5m_input_tokens":0}}}}
{"type":"assistant","timestamp":"2026-05-16T10:05:00.000Z","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":18000,"output_tokens":80,"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0}}}}
{"type":"assistant","timestamp":"2026-05-16T10:10:00.000Z","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":20,"cache_creation_input_tokens":2000,"cache_read_input_tokens":22000,"output_tokens":60,"cache_creation":{"ephemeral_1h_input_tokens":2000,"ephemeral_5m_input_tokens":0}}}}
EOF

read_session_cache_stats "$TRANSCRIPT"
assert_eq "sess_reads"   "$sess_reads"   "40000"
assert_eq "sess_writes"  "$sess_writes"  "7000"
assert_eq "sess_inputs"  "$sess_inputs"  "170"
assert_eq "last_1h_iso"  "$last_1h_iso"  "2026-05-16T10:10:00.000Z"
assert_eq "last_5m_iso"  "$last_5m_iso"  ""

read_session_cache_stats "/nonexistent/path.jsonl"
assert_eq "missing file reads"  "$sess_reads"  "0"
assert_eq "missing file writes" "$sess_writes" "0"

read_session_cache_stats ""
assert_eq "empty path reads"  "$sess_reads"  "0"

rm -rf "$TMPDIR_TEST"

# ── read_all_sessions_cache_stats tests ───────────────────
TMPDIR_ALL=$(mktemp -d)

mkdir -p "$TMPDIR_ALL/.claude/projects/proj-a" "$TMPDIR_ALL/.claude/projects/proj-b"
cat > "$TMPDIR_ALL/.claude/projects/proj-a/sess1.jsonl" <<'EOF'
{"type":"assistant","timestamp":"2026-05-16T09:00:00.000Z","message":{"usage":{"input_tokens":200,"cache_creation_input_tokens":10000,"cache_read_input_tokens":5000,"output_tokens":100}}}
EOF
cat > "$TMPDIR_ALL/.claude/projects/proj-b/sess2.jsonl" <<'EOF'
{"type":"assistant","timestamp":"2026-05-16T10:00:00.000Z","message":{"usage":{"input_tokens":50,"cache_creation_input_tokens":3000,"cache_read_input_tokens":30000,"output_tokens":40}}}
EOF

# Pre-populate cache file with known data (tests the cache-read path;
# background refresh is async so we can't assert on a cold-cache write in tests)
mkdir -p /tmp/claude
echo '{"reads":35000,"writes":13000,"inputs":250}' > /tmp/claude/cache-all-stats.json

HOME="$TMPDIR_ALL" read_all_sessions_cache_stats
assert_eq "all_reads"  "$all_reads"  "35000"
assert_eq "all_writes" "$all_writes" "13000"
assert_eq "all_inputs" "$all_inputs" "250"

rm -rf "$TMPDIR_ALL"

# ── build_cache_lines integration test ────────────────────
TMPDIR_BL=$(mktemp -d)
BL_TRANSCRIPT="$TMPDIR_BL/sess.jsonl"
NOW_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

cat > "$BL_TRANSCRIPT" <<EOF
{"type":"assistant","timestamp":"${NOW_ISO}","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":100,"cache_creation_input_tokens":5000,"cache_read_input_tokens":20000,"output_tokens":50,"cache_creation":{"ephemeral_1h_input_tokens":5000,"ephemeral_5m_input_tokens":0}}}}
EOF

mkdir -p "$TMPDIR_BL/.claude/projects/test"
cp "$BL_TRANSCRIPT" "$TMPDIR_BL/.claude/projects/test/sess.jsonl"
rm -f /tmp/claude/cache-all-stats.json

HOME="$TMPDIR_BL" build_cache_lines "$BL_TRANSCRIPT" "claude-sonnet-4-6" "0.05"

# Strip ANSI codes for assertion
plain=$(printf "%b" "$cache_lines" | sed 's/\x1b\[[0-9;]*m//g')

echo "$plain" | grep -q "session" && { echo "PASS: session line present"; PASS=$(( PASS + 1 )); } || \
    { echo "FAIL: session line missing"; FAIL=$(( FAIL + 1 )); }
echo "$plain" | grep -q "r:20k" && { echo "PASS: reads shown as 20k"; PASS=$(( PASS + 1 )); } || \
    { echo "FAIL: reads not 20k in: $plain"; FAIL=$(( FAIL + 1 )); }
echo "$plain" | grep -q "w:5k" && { echo "PASS: writes shown as 5k"; PASS=$(( PASS + 1 )); } || \
    { echo "FAIL: writes not 5k"; FAIL=$(( FAIL + 1 )); }
echo "$plain" | grep -q "hit:" && { echo "PASS: hit rate present"; PASS=$(( PASS + 1 )); } || \
    { echo "FAIL: hit rate missing"; FAIL=$(( FAIL + 1 )); }
echo "$plain" | grep -q "cache" && { echo "PASS: TTL line present"; PASS=$(( PASS + 1 )); } || \
    { echo "FAIL: TTL line missing"; FAIL=$(( FAIL + 1 )); }
echo "$plain" | grep -q "cost" && { echo "PASS: cost present"; PASS=$(( PASS + 1 )); } || \
    { echo "FAIL: cost missing"; FAIL=$(( FAIL + 1 )); }

rm -rf "$TMPDIR_BL"

# ── rebuild_all_sessions_index: argv-safe + incremental ───
# Regression: the old glob `cat .../projects/*/*.jsonl` overflowed the argv
# limit at scale → empty input → 0/0/0. This scans with find and memoizes
# per-file sums, recomputing only files newer than the index.
TMPDIR_RB=$(mktemp -d)
RB_PROJ="$TMPDIR_RB/.claude/projects"
mkdir -p "$RB_PROJ/proj-a" "$RB_PROJ/proj-b"
cat > "$RB_PROJ/proj-a/s1.jsonl" <<'EOF'
{"type":"assistant","message":{"usage":{"input_tokens":100,"cache_creation_input_tokens":1000,"cache_read_input_tokens":2000}}}
EOF
cat > "$RB_PROJ/proj-b/s2.jsonl" <<'EOF'
{"type":"assistant","message":{"usage":{"input_tokens":50,"cache_creation_input_tokens":3000,"cache_read_input_tokens":4000}}}
EOF
RB_CACHE="$TMPDIR_RB/cache.json"
RB_INDEX="$TMPDIR_RB/index.json"

rebuild_all_sessions_index "$RB_PROJ" "$RB_CACHE" "$RB_INDEX" || true
assert_eq "rebuild totals reads"   "$(jq -r '.reads'  "$RB_CACHE" 2>/dev/null)" "6000"
assert_eq "rebuild totals writes"  "$(jq -r '.writes' "$RB_CACHE" 2>/dev/null)" "4000"
assert_eq "rebuild totals inputs"  "$(jq -r '.inputs' "$RB_CACHE" 2>/dev/null)" "150"
assert_eq "rebuild index has 2 files" "$(jq -r 'length' "$RB_INDEX" 2>/dev/null)" "2"

# Incremental: a new session newer than the index is folded in; unchanged
# files are carried from the index, not re-read.
sleep 1
cat > "$RB_PROJ/proj-a/s3.jsonl" <<'EOF'
{"type":"assistant","message":{"usage":{"input_tokens":10,"cache_creation_input_tokens":500,"cache_read_input_tokens":700}}}
EOF
rebuild_all_sessions_index "$RB_PROJ" "$RB_CACHE" "$RB_INDEX" || true
assert_eq "incremental reads include new file"  "$(jq -r '.reads'  "$RB_CACHE" 2>/dev/null)" "6700"
assert_eq "incremental writes include new file" "$(jq -r '.writes' "$RB_CACHE" 2>/dev/null)" "4500"
assert_eq "incremental index has 3 files" "$(jq -r 'length' "$RB_INDEX" 2>/dev/null)" "3"

# Deleted files drop out (rebuild iterates only currently-present paths).
rm -f "$RB_PROJ/proj-b/s2.jsonl"
rebuild_all_sessions_index "$RB_PROJ" "$RB_CACHE" "$RB_INDEX" || true
assert_eq "deleted file removed from reads" "$(jq -r '.reads' "$RB_CACHE" 2>/dev/null)" "2700"
assert_eq "deleted index has 2 files" "$(jq -r 'length' "$RB_INDEX" 2>/dev/null)" "2"

rm -rf "$TMPDIR_RB"

# ── rebuild_all_sessions_index: backfill history predating the index (HIMMEL-698) ─
# Regression: recompute candidates were ONLY files `-newer` than the index, so a
# transcript that predates the index's first write and was never the active
# (freshly-written) transcript was never recomputed and never entered the
# carried-forward index — permanently dropped from the aggregate. Result: the
# "all" total reflected only the few files touched since the index appeared
# (observed 6 of 1812 → a stuck, implausibly-low number). The fix backfills
# files absent from the index (bounded per rebuild). Here we seed an index that
# postdates an OLD transcript (mtime set into the past) and prove the next
# rebuild pulls that old file into the totals.
TMPDIR_BF=$(mktemp -d)
BF_PROJ="$TMPDIR_BF/.claude/projects"
mkdir -p "$BF_PROJ/proj-old" "$BF_PROJ/proj-active"
BF_CACHE="$TMPDIR_BF/cache.json"
BF_INDEX="$TMPDIR_BF/index.json"

# An OLD historical transcript (never seen by the index) with known tokens.
cat > "$BF_PROJ/proj-old/hist.jsonl" <<'EOF'
{"type":"assistant","message":{"usage":{"input_tokens":11,"cache_creation_input_tokens":1111,"cache_read_input_tokens":9999}}}
EOF
touch -d "@$(( $(date +%s) - 86400 ))" "$BF_PROJ/proj-old/hist.jsonl" 2>/dev/null \
    || touch -t "$(date -r "$(( $(date +%s) - 86400 ))" +%Y%m%d%H%M.%S 2>/dev/null)" "$BF_PROJ/proj-old/hist.jsonl" 2>/dev/null

# Seed an index that ONLY knows the active file, and whose mtime is NEWER than
# the old transcript — so `-newer` alone would never surface hist.jsonl. This
# is exactly the stuck state the bug leaves behind.
cat > "$BF_PROJ/proj-active/cur.jsonl" <<'EOF'
{"type":"assistant","message":{"usage":{"input_tokens":5,"cache_creation_input_tokens":500,"cache_read_input_tokens":700}}}
EOF
echo '{"'"$BF_PROJ"'/proj-active/cur.jsonl":{"reads":700,"writes":500,"inputs":5}}' > "$BF_INDEX"
echo '{"reads":700,"writes":500,"inputs":5}' > "$BF_CACHE"
# Index mtime = now (well after the old file's mtime).
touch "$BF_INDEX"

rebuild_all_sessions_index "$BF_PROJ" "$BF_CACHE" "$BF_INDEX" || true
# Old file's 9999 reads must now be folded in (700 active + 9999 historical).
assert_eq "backfill: historical reads folded into total"  "$(jq -r '.reads'  "$BF_CACHE" 2>/dev/null)" "10699"
assert_eq "backfill: historical writes folded into total" "$(jq -r '.writes' "$BF_CACHE" 2>/dev/null)" "1611"
assert_eq "backfill: index now has both files"            "$(jq -r 'length'  "$BF_INDEX" 2>/dev/null)" "2"

# Bound honoured: HIMMEL_STATUSLINE_BACKFILL_MAX=0 disables backfill (old file
# stays excluded), proving the knob gates the new behaviour.
TMPDIR_BF0=$(mktemp -d)
BF0_PROJ="$TMPDIR_BF0/.claude/projects"
mkdir -p "$BF0_PROJ/proj-old" "$BF0_PROJ/proj-active"
cat > "$BF0_PROJ/proj-old/hist.jsonl" <<'EOF'
{"type":"assistant","message":{"usage":{"input_tokens":11,"cache_creation_input_tokens":1111,"cache_read_input_tokens":9999}}}
EOF
touch -d "@$(( $(date +%s) - 86400 ))" "$BF0_PROJ/proj-old/hist.jsonl" 2>/dev/null \
    || touch -t "$(date -r "$(( $(date +%s) - 86400 ))" +%Y%m%d%H%M.%S 2>/dev/null)" "$BF0_PROJ/proj-old/hist.jsonl" 2>/dev/null
cat > "$BF0_PROJ/proj-active/cur.jsonl" <<'EOF'
{"type":"assistant","message":{"usage":{"input_tokens":5,"cache_creation_input_tokens":500,"cache_read_input_tokens":700}}}
EOF
echo '{"'"$BF0_PROJ"'/proj-active/cur.jsonl":{"reads":700,"writes":500,"inputs":5}}' > "$TMPDIR_BF0/index.json"
echo '{"reads":700,"writes":500,"inputs":5}' > "$TMPDIR_BF0/cache.json"
touch "$TMPDIR_BF0/index.json"
HIMMEL_STATUSLINE_BACKFILL_MAX=0 rebuild_all_sessions_index "$BF0_PROJ" "$TMPDIR_BF0/cache.json" "$TMPDIR_BF0/index.json" || true
assert_eq "backfill disabled (MAX=0): historical file stays excluded" "$(jq -r '.reads' "$TMPDIR_BF0/cache.json" 2>/dev/null)" "700"
rm -rf "$TMPDIR_BF0"

rm -rf "$TMPDIR_BF"

# ── build_cache_lines: hide expired tier when the other is live ──
TMPDIR_T1=$(mktemp -d)
mkdir -p "$TMPDIR_T1/.claude/projects/x"
NOW2=$(date +%s)
ISO_NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
ISO_6M_AGO=$(date -d "@$(( NOW2 - 360 ))" -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -r $(( NOW2 - 360 )) +"%Y-%m-%dT%H:%M:%SZ")
ISO_1M_AGO=$(date -d "@$(( NOW2 - 60 ))" -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -r $(( NOW2 - 60 )) +"%Y-%m-%dT%H:%M:%SZ")

# 5m write 6min ago (expired) + 1h write now (live) → only the 1h tier shows
T1_TX="$TMPDIR_T1/sess.jsonl"
cat > "$T1_TX" <<EOF
{"type":"assistant","timestamp":"${ISO_6M_AGO}","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":10,"cache_creation_input_tokens":100,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":0}}}}
{"type":"assistant","timestamp":"${ISO_NOW}","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":20,"cache_creation_input_tokens":5000,"cache_read_input_tokens":1000,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":5000}}}}
EOF
rm -f /tmp/claude/cache-all-stats.json /tmp/claude/cache-all-stats-index.json
HOME="$TMPDIR_T1" build_cache_lines "$T1_TX" "claude-sonnet-4-6" ""
plain1=$(printf "%b" "$cache_lines" | sed 's/\x1b\[[0-9;]*m//g')
if echo "$plain1" | grep -q "5m-cache"; then
    echo "FAIL: expired 5m tier shown while 1h live"; echo "  got: $plain1"; FAIL=$(( FAIL + 1 ))
else
    echo "PASS: expired 5m tier hidden while 1h live"; PASS=$(( PASS + 1 ))
fi
echo "$plain1" | grep -q "cache" && { echo "PASS: live 1h tier shown"; PASS=$(( PASS + 1 )); } || \
    { echo "FAIL: live 1h tier missing in: $plain1"; FAIL=$(( FAIL + 1 )); }

# Both tiers live → both shown, with explicit 1h/5m labels
T1_TX2="$TMPDIR_T1/sess2.jsonl"
cat > "$T1_TX2" <<EOF
{"type":"assistant","timestamp":"${ISO_1M_AGO}","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":10,"cache_creation_input_tokens":100,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":0}}}}
{"type":"assistant","timestamp":"${ISO_NOW}","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":20,"cache_creation_input_tokens":5000,"cache_read_input_tokens":1000,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":5000}}}}
EOF
rm -f /tmp/claude/cache-all-stats.json /tmp/claude/cache-all-stats-index.json
HOME="$TMPDIR_T1" build_cache_lines "$T1_TX2" "claude-sonnet-4-6" ""
plain2=$(printf "%b" "$cache_lines" | sed 's/\x1b\[[0-9;]*m//g')
echo "$plain2" | grep -q "1h-cache" && { echo "PASS: both-live shows 1h-cache label"; PASS=$(( PASS + 1 )); } || \
    { echo "FAIL: 1h-cache label missing when both live: $plain2"; FAIL=$(( FAIL + 1 )); }
echo "$plain2" | grep -q "5m-cache" && { echo "PASS: both-live shows 5m-cache label"; PASS=$(( PASS + 1 )); } || \
    { echo "FAIL: 5m-cache label missing when both live: $plain2"; FAIL=$(( FAIL + 1 )); }

rm -rf "$TMPDIR_T1"

# ── stdin rate_limits → usage cache write (regression) ────
# Bug: the only usage-cache write lived in the API-fallback branch, so the
# cache froze for the whole session once stdin carried rate_limits.
USAGE_CACHE=/tmp/claude/statusline-usage-cache.json
USAGE_BACKUP=$(mktemp)
SL_ERR=$(mktemp)
USAGE_HAD_FILE=false
if [ -f "$USAGE_CACHE" ]; then
    USAGE_HAD_FILE=true
    cp "$USAGE_CACHE" "$USAGE_BACKUP"
fi
# Restore the live cache exactly as it was — trap so a mid-test failure
# under set -e can't destroy it. Presence flag (not -s) so an originally
# empty cache file is restored as an empty file, not deleted.
restore_usage_cache() {
    if $USAGE_HAD_FILE; then
        mv -f "$USAGE_BACKUP" "$USAGE_CACHE"
    else
        rm -f "$USAGE_CACHE" "$USAGE_BACKUP"
    fi
    rm -f "$SL_ERR"
}
trap restore_usage_cache EXIT

run_statusline() {  # $1 = stdin payload; stderr kept for FAIL output
    printf '%s' "$1" | bash "$STATUSLINE" >/dev/null 2>"$SL_ERR" || true
}
fail_with_stderr() {
    echo "FAIL: $1"
    [ -s "$SL_ERR" ] && sed 's/^/  stderr: /' "$SL_ERR"
    FAIL=$(( FAIL + 1 ))
}
age_cache() {  # push the cache mtime past the 60s write throttle
    local past=$(( $(date +%s) - 3600 ))
    touch -d "@${past}" "$USAGE_CACHE" 2>/dev/null \
        || touch -t "$(date -r "$past" +%Y%m%d%H%M.%S)" "$USAGE_CACHE"
}

# 1) Cold cache + full payload → write lands, numeric types, ISO resets_at
rm -f "$USAGE_CACHE"
RESET_EPOCH=$(( NOW + 7200 ))
WANT_ISO=$(date -u -d "@$RESET_EPOCH" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
    || date -u -r "$RESET_EPOCH" +"%Y-%m-%dT%H:%M:%SZ")
PAYLOAD_FULL=$(printf '{"model":{"display_name":"T","id":"claude-sonnet-4-6"},"cwd":"/tmp","rate_limits":{"five_hour":{"used_percentage":42.7,"resets_at":%s},"seven_day":{"used_percentage":63.2,"resets_at":%s}}}' \
    "$RESET_EPOCH" "$RESET_EPOCH")
run_statusline "$PAYLOAD_FULL"

if [ -f "$USAGE_CACHE" ]; then
    assert_eq "stdin rates: five_hour.utilization cached" \
        "$(jq -r '.five_hour.utilization' "$USAGE_CACHE")" "42.7"
    assert_eq "stdin rates: utilization is a JSON number" \
        "$(jq -r '.five_hour.utilization | type' "$USAGE_CACHE")" "number"
    assert_eq "stdin rates: seven_day.utilization cached" \
        "$(jq -r '.seven_day.utilization' "$USAGE_CACHE")" "63.2"
    assert_eq "stdin rates: five_hour.resets_at stored as ISO" \
        "$(jq -r '.five_hour.resets_at' "$USAGE_CACHE")" "$WANT_ISO"
    assert_eq "stdin rates: seven_day.resets_at stored as ISO" \
        "$(jq -r '.seven_day.resets_at' "$USAGE_CACHE")" "$WANT_ISO"
else
    fail_with_stderr "stdin rates did not create usage cache"
fi

# 2) 60s throttle: an immediate second render must NOT rewrite the cache
if [ -f "$USAGE_CACHE" ]; then
    MTIME_BEFORE=$(stat -c %Y "$USAGE_CACHE" 2>/dev/null || stat -f %m "$USAGE_CACHE")
    run_statusline "${PAYLOAD_FULL/42.7/55.5}"
    MTIME_AFTER=$(stat -c %Y "$USAGE_CACHE" 2>/dev/null || stat -f %m "$USAGE_CACHE")
    assert_eq "throttle: mtime unchanged within 60s" "$MTIME_AFTER" "$MTIME_BEFORE"
    assert_eq "throttle: utilization unchanged within 60s" \
        "$(jq -r '.five_hour.utilization' "$USAGE_CACHE")" "42.7"
fi

# 3) Merge semantics: extra_usage + prior seven_day survive a
#    five_hour-only stdin write (external consumers read extra_usage)
printf '{"five_hour":{"utilization":1,"resets_at":null},"seven_day":{"utilization":63.2,"resets_at":"%s"},"extra_usage":{"is_enabled":true}}' \
    "$WANT_ISO" > "$USAGE_CACHE"
age_cache
PAYLOAD_FH_ONLY='{"model":{"display_name":"T","id":"claude-sonnet-4-6"},"cwd":"/tmp","rate_limits":{"five_hour":{"used_percentage":48.1,"resets_at":'"$RESET_EPOCH"'}}}'
run_statusline "$PAYLOAD_FH_ONLY"
assert_eq "merge: five_hour updated from stdin" \
    "$(jq -r '.five_hour.utilization' "$USAGE_CACHE")" "48.1"
assert_eq "merge: extra_usage preserved across stdin write" \
    "$(jq -r '.extra_usage.is_enabled' "$USAGE_CACHE")" "true"
assert_eq "merge: prior seven_day retained when stdin lacks it" \
    "$(jq -r '.seven_day.utilization' "$USAGE_CACHE")" "63.2"

# 4a) Corrupt prev (invalid JSON) heals on next aged render
printf 'not json{{{' > "$USAGE_CACHE"
age_cache
run_statusline "$PAYLOAD_FULL"
if jq -e 'type == "object"' "$USAGE_CACHE" >/dev/null 2>&1; then
    assert_eq "heal invalid-JSON prev: five_hour written" \
        "$(jq -r '.five_hour.utilization' "$USAGE_CACHE")" "42.7"
else
    fail_with_stderr "invalid-JSON cache not healed to an object"
fi

# 4b) Corrupt prev (valid JSON but non-object) heals too
printf '"just a string"' > "$USAGE_CACHE"
age_cache
run_statusline "$PAYLOAD_FULL"
if jq -e 'type == "object"' "$USAGE_CACHE" >/dev/null 2>&1; then
    assert_eq "heal non-object prev: five_hour written" \
        "$(jq -r '.five_hour.utilization' "$USAGE_CACHE")" "42.7"
else
    fail_with_stderr "non-object cache not healed to an object"
fi

# 5) One malformed stdin field degrades to null, doesn't kill the write
rm -f "$USAGE_CACHE"
PAYLOAD_BAD_SD='{"model":{"display_name":"T","id":"claude-sonnet-4-6"},"cwd":"/tmp","rate_limits":{"five_hour":{"used_percentage":42.7,"resets_at":'"$RESET_EPOCH"'},"seven_day":{"used_percentage":"63%","resets_at":'"$RESET_EPOCH"'}}}'
run_statusline "$PAYLOAD_BAD_SD"
assert_eq "per-field guard: valid five_hour cached despite bad seven_day" \
    "$(jq -r '.five_hour.utilization' "$USAGE_CACHE" 2>/dev/null)" "42.7"
assert_eq "per-field guard: bad seven_day stored as null, not aborted" \
    "$(jq -r '.seven_day.utilization' "$USAGE_CACHE" 2>/dev/null)" "null"

# ── resolve_window: week/month/all + invalid (HIMMEL-617) ─────
# `now` is pinned via HIMMEL_STATUSLINE_NOW so boundaries are deterministic.
# Expected epochs are computed via `date` (not hardcoded) → tz-independent.
mkdate() { date -d "$1" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$1" +%s; }
NOW_WED=$(mkdate "2026-06-24 12:00:00")   # a Wednesday

HIMMEL_STATUSLINE_NOW="$NOW_WED" resolve_window week
assert_eq "week window_start = Monday 00:00" "$window_start" "$(mkdate "2026-06-22 00:00:00")"
assert_eq "week window spans exactly 7 days"  "$(( window_end - window_start ))" "604800"
assert_eq "week window_id labelled by Monday"  "$window_id" "week-20260622"

HIMMEL_STATUSLINE_NOW="$NOW_WED" resolve_window month
assert_eq "month window_start = 1st 00:00"   "$window_start" "$(mkdate "2026-06-01 00:00:00")"
assert_eq "month window_end = next 1st 00:00" "$window_end"   "$(mkdate "2026-07-01 00:00:00")"
assert_eq "month window_id"                   "$window_id"    "month-202606"

resolve_window all
assert_eq "all window_id keeps legacy name" "$window_id"    "all-stats"
assert_eq "all window_start unbounded"      "$window_start" "0"

# Invalid period → all window + a one-line stderr warning.
RW_ERR=$(mktemp)
HIMMEL_STATUSLINE_NOW="$NOW_WED" resolve_window "year" 2>"$RW_ERR"
assert_eq "invalid period → all-stats window" "$window_id"    "all-stats"
assert_eq "invalid period → start 0"          "$window_start" "0"
grep -q "falling back to all" "$RW_ERR" \
    && { echo "PASS: invalid period warns on stderr"; PASS=$(( PASS + 1 )); } \
    || { echo "FAIL: invalid period emitted no stderr warning"; FAIL=$(( FAIL + 1 )); }
rm -f "$RW_ERR"

# ── Boundary reset: window_id flips across the Monday boundary ────
SUN_LATE=$(mkdate "2026-06-21 23:59:00")   # Sunday → prior week
MON_EARLY=$(mkdate "2026-06-22 00:01:00")  # Monday → new week
HIMMEL_STATUSLINE_NOW="$SUN_LATE"  resolve_window week; WID_SUN="$window_id"
HIMMEL_STATUSLINE_NOW="$MON_EARLY" resolve_window week; WID_MON="$window_id"
if [ "$WID_SUN" != "$WID_MON" ]; then
    echo "PASS: week window_id resets at Monday boundary ($WID_SUN → $WID_MON)"; PASS=$(( PASS + 1 ))
else
    echo "FAIL: week window_id did not reset across Monday ($WID_SUN)"; FAIL=$(( FAIL + 1 ))
fi
WED_SAME=$(mkdate "2026-06-24 09:00:00")
HIMMEL_STATUSLINE_NOW="$WED_SAME" resolve_window week; WID_SAME="$window_id"
assert_eq "same-week now keeps one window_id (cache reused)" "$WID_SAME" "$WID_MON"

# ── Windowed aggregation: per-message timestamp re-sum (HIMMEL-617) ──
# A file with messages spanning two months; the window must count only the
# messages whose .timestamp falls in [start,end), not the whole-file sums the
# `all` immutable index would carry.
TMPDIR_WIN=$(mktemp -d)
WP="$TMPDIR_WIN/.claude/projects"
mkdir -p "$WP/proj"
cat > "$WP/proj/s.jsonl" <<'EOF'
{"type":"assistant","timestamp":"2026-05-10T10:00:00.000Z","message":{"usage":{"input_tokens":1,"cache_creation_input_tokens":111,"cache_read_input_tokens":222}}}
{"type":"assistant","timestamp":"2026-06-05T10:00:00.000Z","message":{"usage":{"input_tokens":2,"cache_creation_input_tokens":1000,"cache_read_input_tokens":2000}}}
{"type":"assistant","timestamp":"2026-06-20T10:00:00.000Z","message":{"usage":{"input_tokens":3,"cache_creation_input_tokens":3000,"cache_read_input_tokens":4000}}}
EOF
JUN_S=$(mkdate "2026-06-01 00:00:00"); JUN_E=$(mkdate "2026-07-01 00:00:00")
W_CACHE="$TMPDIR_WIN/c.json"; W_INDEX="$TMPDIR_WIN/i.json"
rebuild_all_sessions_index "$WP" "$W_CACHE" "$W_INDEX" "$JUN_S" "$JUN_E" || true
assert_eq "windowed reads = June messages only"  "$(jq -r '.reads'  "$W_CACHE" 2>/dev/null)" "6000"
assert_eq "windowed writes = June messages only" "$(jq -r '.writes' "$W_CACHE" 2>/dev/null)" "4000"
assert_eq "windowed inputs = June messages only" "$(jq -r '.inputs' "$W_CACHE" 2>/dev/null)" "5"

# Same file, May window → only the May message (proves the window, not the file,
# decides membership — the moving-window correctness the `all` index can't give).
MAY_S=$(mkdate "2026-05-01 00:00:00"); MAY_E=$(mkdate "2026-06-01 00:00:00")
W_CACHE5="$TMPDIR_WIN/c5.json"; W_INDEX5="$TMPDIR_WIN/i5.json"
rebuild_all_sessions_index "$WP" "$W_CACHE5" "$W_INDEX5" "$MAY_S" "$MAY_E" || true
assert_eq "windowed reads = May message only"  "$(jq -r '.reads'  "$W_CACHE5" 2>/dev/null)" "222"
assert_eq "windowed inputs = May message only" "$(jq -r '.inputs' "$W_CACHE5" 2>/dev/null)" "1"
rm -rf "$TMPDIR_WIN"

# ── mtime prefilter: bound the scan without dropping in-window files (HIMMEL-617) ─
# Regression guard for the "week/month row renders 0" bug: the windowed prefilter
# used a bash stat-per-file loop (one process per transcript). On a large history
# (1000+ files) that overran the render timeout, so the backgrounded rebuild never
# finished and the per-window cache stayed at 0. The fix moves the mtime filter
# into a single `find` (reference file + POSIX -newer). This test pins NOW via
# HIMMEL_STATUSLINE_NOW, resolves the real week window, then proves the prefilter
# (a) KEEPS a file whose mtime sits exactly on win_start (inclusive boundary — the
# ref mtime is win_start-1), and (b) DROPS a file modified before the window — and
# the resulting windowed sum is correct AND non-zero.
TMPDIR_PF=$(mktemp -d)
PF="$TMPDIR_PF/.claude/projects"; mkdir -p "$PF/proj"
WK_S=$(mkdate "2026-06-22 00:00:00")        # this week's Monday 00:00 (= win_start)
# In-window file: message inside [Mon,next Mon); mtime pinned to win_start exactly.
echo '{"type":"assistant","timestamp":"2026-06-24T10:00:00.000Z","message":{"usage":{"input_tokens":7,"cache_creation_input_tokens":300,"cache_read_input_tokens":900}}}' > "$PF/proj/cur.jsonl"
touch -d "@$WK_S" "$PF/proj/cur.jsonl" 2>/dev/null \
    || touch -t "$(date -r "$WK_S" +%Y%m%d%H%M.%S 2>/dev/null)" "$PF/proj/cur.jsonl" 2>/dev/null
# Out-of-window file: pre-window message AND mtime a day before win_start → dropped.
echo '{"type":"assistant","timestamp":"2026-05-01T10:00:00.000Z","message":{"usage":{"input_tokens":5,"cache_creation_input_tokens":5000,"cache_read_input_tokens":9999}}}' > "$PF/proj/old.jsonl"
touch -d "@$(( WK_S - 86400 ))" "$PF/proj/old.jsonl" 2>/dev/null \
    || touch -t "$(date -r "$(( WK_S - 86400 ))" +%Y%m%d%H%M.%S 2>/dev/null)" "$PF/proj/old.jsonl" 2>/dev/null
HIMMEL_STATUSLINE_NOW="$NOW_WED" resolve_window week
PF_C="$TMPDIR_PF/c.json"; PF_I="$TMPDIR_PF/i.json"
rebuild_all_sessions_index "$PF" "$PF_C" "$PF_I" "$window_start" "$window_end" || true
assert_eq "prefilter: windowed reads = in-window file only"  "$(jq -r '.reads'  "$PF_C" 2>/dev/null)" "900"
assert_eq "prefilter: windowed writes = in-window file only" "$(jq -r '.writes' "$PF_C" 2>/dev/null)" "300"
assert_eq "prefilter: windowed inputs = in-window file only" "$(jq -r '.inputs' "$PF_C" 2>/dev/null)" "7"
PF_READS=$(jq -r '.reads' "$PF_C" 2>/dev/null)
if [ "${PF_READS:-0}" -gt 0 ] 2>/dev/null; then
    echo "PASS: windowed reads non-zero (regression: timeout left it at 0)"; PASS=$(( PASS + 1 ))
else
    echo "FAIL: windowed reads is 0 — windowed aggregation regressed"; FAIL=$(( FAIL + 1 ))
fi
rm -rf "$TMPDIR_PF"

# ── period=all bottom rows are byte-exact vs committed golden ─────
# Guards the default path: my change must not alter a single byte of the `all`
# render. The golden was captured from the PRE-EDIT script on this fixture.
GOLDEN="$SCRIPT_DIR/golden-all-row.txt"
if [ -f "$GOLDEN" ]; then
    TMPDIR_G=$(mktemp -d)
    mkdir -p "$TMPDIR_G/.claude/projects/test"
    G_TX="$TMPDIR_G/sess.jsonl"
    cat > "$G_TX" <<'EOF'
{"type":"assistant","timestamp":"2026-05-16T10:00:00.000Z","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":100,"cache_creation_input_tokens":5000,"cache_read_input_tokens":20000,"output_tokens":50}}}
{"type":"assistant","timestamp":"2026-05-16T10:05:00.000Z","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":18000,"output_tokens":80}}}
EOF
    cp "$G_TX" "$TMPDIR_G/.claude/projects/test/sess.jsonl"
    mkdir -p /tmp/claude
    # Let any in-flight all-stats rebuild spawned by an earlier test finish — it
    # holds the lock dir while writing, and could otherwise clobber the pinned
    # cache between our write and read (the same shared-cache race the all_reads
    # test carries; a clean /tmp/claude with no live sessions has neither).
    for _w in 1 2 3 4 5 6 7 8 9 10; do
        [ -d /tmp/claude/cache-all-stats-index.json.lock ] || break
        sleep 0.3
    done
    rm -f /tmp/claude/cache-all-stats-index.json
    echo '{"reads":26800000,"writes":965000,"inputs":250000}' > /tmp/claude/cache-all-stats.json
    # Fresh cache (age 0 < 30s) → no rebuild spawns → the pinned totals are read.
    HOME="$TMPDIR_G" HIMMEL_STATUSLINE_PERIOD=all \
        build_cache_lines "$G_TX" "claude-sonnet-4-6" "0.0400"
    GOT_RENDER=$(printf "%b" "$cache_lines")
    WANT_RENDER=$(cat "$GOLDEN")
    assert_eq "period=all bottom rows match committed golden (byte-exact)" \
        "$GOT_RENDER" "$WANT_RENDER"
    rm -rf "$TMPDIR_G"
else
    echo "FAIL: golden fixture $GOLDEN missing"; FAIL=$(( FAIL + 1 ))
fi

# ── Label reflects the active period (HIMMEL-617) ────────────────
# End-to-end through build_cache_lines: period=month renders a "month" label and
# reads the per-window cache file (cache-month-202606.json — unique to this test,
# so no race with the shared all-stats cache).
TMPDIR_LBL=$(mktemp -d)
mkdir -p "$TMPDIR_LBL/.claude/projects/p"
LBL_TX="$TMPDIR_LBL/s.jsonl"
echo '{"type":"assistant","timestamp":"2026-06-20T10:00:00.000Z","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":5,"cache_creation_input_tokens":100,"cache_read_input_tokens":200}}}' > "$LBL_TX"
cp "$LBL_TX" "$TMPDIR_LBL/.claude/projects/p/s.jsonl"
mkdir -p /tmp/claude
echo '{"reads":6000,"writes":4000,"inputs":5}' > /tmp/claude/cache-month-202606.json
HOME="$TMPDIR_LBL" HIMMEL_STATUSLINE_PERIOD=month HIMMEL_STATUSLINE_NOW="$NOW_WED" \
    build_cache_lines "$LBL_TX" "claude-sonnet-4-6" ""
plain_lbl=$(printf "%b" "$cache_lines" | sed 's/\x1b\[[0-9;]*m//g')
echo "$plain_lbl" | grep -qE '^month ' \
    && { echo "PASS: period=month renders a 'month' label"; PASS=$(( PASS + 1 )); } \
    || { echo "FAIL: month label missing in: $plain_lbl"; FAIL=$(( FAIL + 1 )); }
echo "$plain_lbl" | grep -qE '^all ' \
    && { echo "FAIL: stale 'all' label present under period=month: $plain_lbl"; FAIL=$(( FAIL + 1 )); } \
    || { echo "PASS: no 'all' label under period=month"; PASS=$(( PASS + 1 )); }
echo "$plain_lbl" | grep -q "r:6k" \
    && { echo "PASS: month row reads from per-window cache (6k)"; PASS=$(( PASS + 1 )); } \
    || { echo "FAIL: month windowed totals missing in: $plain_lbl"; FAIL=$(( FAIL + 1 )); }
rm -f /tmp/claude/cache-month-202606.json
rm -rf "$TMPDIR_LBL"

echo ""; echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
