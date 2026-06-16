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

# ── get_model_savings_rate tests ───────────────────────────
get_model_savings_rate "claude-sonnet-4-6"
assert_eq "sonnet read_savings_rate"   "$read_savings_rate"   "0.00000270"
assert_eq "sonnet write_overhead_rate" "$write_overhead_rate" "0.00000300"

get_model_savings_rate "claude-opus-4-7"
assert_eq "opus read_savings_rate"     "$read_savings_rate"   "0.00001350"
assert_eq "opus write_overhead_rate"   "$write_overhead_rate" "0.00001500"

get_model_savings_rate "claude-haiku-4-5"
assert_eq "haiku read_savings_rate"    "$read_savings_rate"   "0.00000072"
assert_eq "haiku write_overhead_rate"  "$write_overhead_rate" "0.00000080"

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

echo ""; echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
