#!/usr/bin/env bash
# Tests for scripts/handover/resume-slot.sh (HIMMEL-204).
# Cross-platform: pure bash + python3, no scheduler. Synthetic cache fixtures.
set -uo pipefail

SLOT="$(cd "$(dirname "$0")" && pwd)/resume-slot.sh"
[ -x "$SLOT" ] || chmod +x "$SLOT"

# Hermetic run (HIMMEL-1271): the operator may have RESUME_SLOT_THRESHOLD
# exported. Every case below asserts against the SHIPPED default unless it sets
# the var itself, so clear it for the whole suite.
unset RESUME_SLOT_THRESHOLD

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAILED=0

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then echo "PASS $label (rc=$actual)"
    else echo "FAIL $label — expected rc=$expected, got rc=$actual"; FAILED=$((FAILED+1)); fi
}
assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in *"$needle"*) echo "PASS $label" ;;
        *) echo "FAIL $label — missing: $needle | got: $haystack"; FAILED=$((FAILED+1)) ;; esac
}
assert_true() {
    local label="$1" cond="$2"
    if [ "$cond" = "1" ]; then echo "PASS $label"; else echo "FAIL $label"; FAILED=$((FAILED+1)); fi
}
assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in *"$needle"*) echo "FAIL $label — unexpectedly contains: $needle"; FAILED=$((FAILED+1)) ;;
        *) echo "PASS $label" ;; esac
}

# Write a cache fixture with given utils + resets, fresh mtime (now).
# Usage: mk_cache <path> <five_util> <five_reset_iso> <seven_util> <seven_reset_iso>
mk_cache() {
    printf '{"five_hour":{"utilization":%s,"resets_at":"%s"},"seven_day":{"utilization":%s,"resets_at":"%s"}}' \
        "$2" "$3" "$4" "$5" > "$1"
}
# ISO 8601 UTC string for now + N seconds (python3).
iso_in() { python3 -c 'import sys,datetime; print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(seconds=int(sys.argv[1]))).isoformat())' "$1"; }

NOW=$(date +%s)

# ---------------------------------------------------------------------------
# T1: bank free (both windows below threshold) -> ASAP (now + buffer)
# ---------------------------------------------------------------------------
mk_cache "$TMP/free.json" 0.0 "$(iso_in 18000)" 21.0 "$(iso_in 604800)"
out=$(bash "$SLOT" --cache "$TMP/free.json" --max-age 0 --buffer-min 4 --emit all 2>&1); rc=$?
assert_rc "T1 free-bank exits 0" 0 "$rc"
assert_contains "T1 reason says bank free + ASAP" "bank free" "$out"
ep=$(printf '%s' "$out" | cut -f1)
# epoch must be in (now, now + 5min] — i.e. the +4m ASAP slot, allowing skew.
in_window=$(python3 -c 'import sys; n,e=int(sys.argv[1]),int(sys.argv[2]); print(1 if n < e <= n+360 else 0)' "$NOW" "$ep")
assert_true "T1 ASAP epoch ~ now+4m" "$in_window"

# ---------------------------------------------------------------------------
# T2: five_hour exhausted (>= threshold) -> wait for its reset
# ---------------------------------------------------------------------------
FIVE_RESET=$(iso_in 9000)   # 2.5h out
mk_cache "$TMP/five.json" 96.0 "$FIVE_RESET" 30.0 "$(iso_in 604800)"
out=$(bash "$SLOT" --cache "$TMP/five.json" --max-age 0 --emit all 2>&1); rc=$?
assert_rc "T2 five-exhausted exits 0" 0 "$rc"
assert_contains "T2 waits for five-hour reset" "wait for five-hour reset" "$out"
ep=$(printf '%s' "$out" | cut -f1)
match=$(python3 -c 'import sys,datetime; want=int(datetime.datetime.fromisoformat(sys.argv[1]).timestamp()); print(1 if abs(int(sys.argv[2])-want)<=1 else 0)' "$FIVE_RESET" "$ep")
assert_true "T2 epoch == five_hour reset" "$match"

# ---------------------------------------------------------------------------
# T3: both exhausted -> wait for the LATEST reset (seven_day here)
# ---------------------------------------------------------------------------
SEVEN_RESET=$(iso_in 200000)
mk_cache "$TMP/both.json" 99.0 "$(iso_in 9000)" 95.0 "$SEVEN_RESET"
out=$(bash "$SLOT" --cache "$TMP/both.json" --max-age 0 --emit reason 2>&1); rc=$?
assert_rc "T3 both-exhausted exits 0" 0 "$rc"
assert_contains "T3 waits for the latest (seven-day) reset" "wait for seven-day reset" "$out"

# ---------------------------------------------------------------------------
# T4: clock-skew — exhausted window whose reset already passed -> ASAP fallback
# ---------------------------------------------------------------------------
mk_cache "$TMP/skew.json" 99.0 "$(iso_in -600)" 10.0 "$(iso_in 604800)"
out=$(bash "$SLOT" --cache "$TMP/skew.json" --max-age 0 --emit reason 2>&1); rc=$?
assert_rc "T4 skew exits 0" 0 "$rc"
assert_contains "T4 past reset falls back to ASAP" "ASAP" "$out"

# ---------------------------------------------------------------------------
# T5: threshold boundary — util exactly == threshold counts as exhausted
# ---------------------------------------------------------------------------
mk_cache "$TMP/eq.json" 90.0 "$(iso_in 9000)" 10.0 "$(iso_in 604800)"
out=$(bash "$SLOT" --cache "$TMP/eq.json" --max-age 0 --threshold 90 --emit reason 2>&1)
assert_contains "T5 util == threshold is exhausted" "wait for five-hour reset" "$out"

# ---------------------------------------------------------------------------
# T6: missing cache -> rc 2
# ---------------------------------------------------------------------------
bash "$SLOT" --cache "$TMP/nope.json" --emit epoch >/dev/null 2>&1
assert_rc "T6 missing cache exits 2" 2 "$?"

# ---------------------------------------------------------------------------
# T7: stale cache (old mtime, default max-age) -> rc 2
# ---------------------------------------------------------------------------
mk_cache "$TMP/stale.json" 0.0 "$(iso_in 18000)" 0.0 "$(iso_in 604800)"
python3 -c 'import os,sys,time; os.utime(sys.argv[1],(time.time()-100000,time.time()-100000))' "$TMP/stale.json"
bash "$SLOT" --cache "$TMP/stale.json" --emit epoch >/dev/null 2>&1
assert_rc "T7 stale cache exits 2" 2 "$?"
# ...but --max-age 0 bypasses the freshness check.
bash "$SLOT" --cache "$TMP/stale.json" --max-age 0 --emit epoch >/dev/null 2>&1
assert_rc "T7b --max-age 0 bypasses staleness" 0 "$?"

# ---------------------------------------------------------------------------
# T8: bad args -> rc 1
# ---------------------------------------------------------------------------
bash "$SLOT" --emit bogus --cache "$TMP/free.json" --max-age 0 >/dev/null 2>&1
assert_rc "T8 bad --emit exits 1" 1 "$?"
bash "$SLOT" --threshold abc --cache "$TMP/free.json" --max-age 0 >/dev/null 2>&1
assert_rc "T8 bad --threshold exits 1" 1 "$?"

# ---------------------------------------------------------------------------
# T9: exhausted window with NULL resets_at -> fail loud (rc 2), NOT silent ASAP
# ---------------------------------------------------------------------------
printf '{"five_hour":{"utilization":99.0,"resets_at":null},"seven_day":{"utilization":10.0,"resets_at":"%s"}}' "$(iso_in 604800)" > "$TMP/nullreset.json"
err=$(bash "$SLOT" --cache "$TMP/nullreset.json" --max-age 0 --emit epoch 2>&1); rc=$?
assert_rc "T9 exhausted+null-reset exits 2" 2 "$rc"
assert_contains "T9 surfaces the unsafe-slot reason" "cannot pick a safe slot" "$err"

# ---------------------------------------------------------------------------
# T10: malformed (non-JSON) cache -> rc 2, clean ERR (no python traceback)
# ---------------------------------------------------------------------------
printf 'not json at all {' > "$TMP/bad.json"
err=$(bash "$SLOT" --cache "$TMP/bad.json" --max-age 0 --emit epoch 2>&1); rc=$?
assert_rc "T10 malformed JSON exits 2" 2 "$rc"
assert_contains "T10 clean ERR line" "ERR resume-slot: cannot parse usage cache" "$err"
assert_not_contains "T10 no python traceback leaks" "Traceback (most recent call last)" "$err"

# ---------------------------------------------------------------------------
# T11: structurally-empty but valid JSON ({}) -> schema-mismatch rc 2,
#      NOT a silent 0%-coerced ASAP.
# ---------------------------------------------------------------------------
printf '{}' > "$TMP/empty.json"
err=$(bash "$SLOT" --cache "$TMP/empty.json" --max-age 0 --emit epoch 2>&1); rc=$?
assert_rc "T11 schema-empty cache exits 2" 2 "$rc"
assert_contains "T11 surfaces schema mismatch" "schema mismatch" "$err"

# ---------------------------------------------------------------------------
# T12: only seven_day exhausted (five_hour has headroom) -> wait seven_day
# ---------------------------------------------------------------------------
mk_cache "$TMP/sevenonly.json" 10.0 "$(iso_in 9000)" 97.0 "$(iso_in 200000)"
out=$(bash "$SLOT" --cache "$TMP/sevenonly.json" --max-age 0 --emit reason 2>&1)
assert_contains "T12 single seven_day exhausted waits for its reset" "wait for seven-day reset" "$out"

# ---------------------------------------------------------------------------
# T13: wedged python3 stub (HIMMEL-249) — the verdict block must fail
#      BOUNDED + visible (armor kill rc), never hang the smart resolver.
# ---------------------------------------------------------------------------
if timeout --version 2>/dev/null | grep -qi coreutils; then
    mkdir -p "$TMP/wedged-bin"
    cat > "$TMP/wedged-bin/python3" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
sleep 30
EOF
    chmod +x "$TMP/wedged-bin/python3"
    mk_cache "$TMP/wedge.json" 0.0 "$(iso_in 18000)" 21.0 "$(iso_in 604800)"
    start=$(date +%s)
    err=$(PATH="$TMP/wedged-bin:$PATH" PY_ARMOR_TIMEOUT=1 PY_ARMOR_KILL_AFTER=1 \
        bash "$SLOT" --cache "$TMP/wedge.json" --max-age 0 --emit epoch 2>&1 >/dev/null)
    rc=$?
    elapsed=$(( $(date +%s) - start ))
    bounded=0; [ "$elapsed" -lt 15 ] && bounded=1
    assert_true "T13 wedged stub returns bounded (${elapsed}s)" "$bounded"
    killed=0; { [ "$rc" = "124" ] || [ "$rc" = "137" ]; } && killed=1
    assert_true "T13 wedged stub surfaces the armor kill rc (got $rc)" "$killed"
    # The armor kill must NOT be silent — python never ran, so the wrapper
    # owns the ERR line ("block OWNS its error reporting" contract).
    assert_contains "T13 armor kill emits an ERR line on stderr" \
        "ERR resume-slot: python3 timed out/killed" "$err"
else
    echo "SKIP T13 (no GNU coreutils timeout on this runner)"
fi

# ---------------------------------------------------------------------------
# T14: null utilization on one window (HIMMEL-279) — fail loud (rc 2), NOT
#      silent 0%-coerce into ASAP. Covers the statusline-PR-#2 null path.
# ---------------------------------------------------------------------------
printf '{"five_hour":{"utilization":null,"resets_at":"%s"},"seven_day":{"utilization":30.0,"resets_at":"%s"}}' \
    "$(iso_in 18000)" "$(iso_in 604800)" > "$TMP/null-five.json"
t14_out="$TMP/t14-stdout"
err=$(bash "$SLOT" --cache "$TMP/null-five.json" --max-age 0 --emit epoch 2>&1 >"$t14_out"); rc=$?
assert_rc "T14 null five_hour util exits 2" 2 "$rc"
assert_contains "T14 surfaces null-utilization reason" "utilization is null" "$err"
# The die path must produce no stdout — no epoch/timestamp emitted on error.
t14_stdout=$(cat "$t14_out" 2>/dev/null || echo "")
t14_empty=0; [ -z "$t14_stdout" ] && t14_empty=1
assert_true "T14 no epoch/timestamp emitted on null-util die path (stdout is empty)" "$t14_empty"

# ---------------------------------------------------------------------------
# T15: null utilization on BOTH windows (HIMMEL-279) — fail loud (rc 2),
#      the 0%-coerce would have silently scheduled ASAP into a stalled cap.
# ---------------------------------------------------------------------------
printf '{"five_hour":{"utilization":null,"resets_at":"%s"},"seven_day":{"utilization":null,"resets_at":"%s"}}' \
    "$(iso_in 18000)" "$(iso_in 604800)" > "$TMP/null-both.json"
err=$(bash "$SLOT" --cache "$TMP/null-both.json" --max-age 0 --emit epoch 2>&1); rc=$?
assert_rc "T15 null both-windows util exits 2" 2 "$rc"
assert_contains "T15 surfaces null-utilization reason" "utilization is null" "$err"

# ---------------------------------------------------------------------------
# T16: EPOCH resets_at (HIMMEL-732 schema drift, missed here until HIMMEL-738)
#      — exhausted window with a raw epoch string like "1783760400" must pick
#      that reset, not die "resets_at missing/unparseable" (the live failure
#      that tore auto-arm-on-cap at seven_day=95%).
# ---------------------------------------------------------------------------
SEVEN_EPOCH=$((NOW + 200000))
mk_cache "$TMP/epoch.json" 10.0 "$((NOW + 9000))" 95.0 "$SEVEN_EPOCH"
out=$(bash "$SLOT" --cache "$TMP/epoch.json" --max-age 0 --emit all 2>&1); rc=$?
assert_rc "T16 epoch resets_at exits 0" 0 "$rc"
assert_contains "T16 waits for seven-day reset" "wait for seven-day reset" "$out"
ep=$(printf '%s' "$out" | cut -f1)
match=$(python3 -c 'import sys; print(1 if abs(int(sys.argv[1])-int(sys.argv[2]))<=1 else 0)' "$ep" "$SEVEN_EPOCH")
assert_true "T16 epoch == seven_day epoch reset" "$match"
# ...and a numeric (unquoted JSON number) resets_at is accepted too.
printf '{"five_hour":{"utilization":10.0,"resets_at":%s},"seven_day":{"utilization":95.0,"resets_at":%s}}' \
    "$((NOW + 9000))" "$SEVEN_EPOCH" > "$TMP/epochnum.json"
out=$(bash "$SLOT" --cache "$TMP/epochnum.json" --max-age 0 --emit reason 2>&1); rc=$?
assert_rc "T16b numeric resets_at exits 0" 0 "$rc"
assert_contains "T16b waits for seven-day reset" "wait for seven-day reset" "$out"

# ---------------------------------------------------------------------------
# T17: RESUME_SLOT_THRESHOLD env override (HIMMEL-1271). The --time smart wall
#      used to be hardcoded at 90, so an operator who considers a 95% bank
#      usable still got parked at the window reset. Four contracts:
#      env honoured / explicit flag beats env / bad env falls back silently /
#      bad flag still errors.
# ---------------------------------------------------------------------------
# Default (no env, no flag): 95% counts as exhausted -> wait for the reset.
mk_cache "$TMP/at95.json" 10.0 "$(iso_in 9000)" 95.0 "$(iso_in 200000)"
out=$(bash "$SLOT" --cache "$TMP/at95.json" --max-age 0 --emit reason 2>&1); rc=$?
assert_rc "T17 default threshold exits 0" 0 "$rc"
assert_contains "T17 default (90) treats 95% as exhausted" "wait for seven-day reset" "$out"
assert_contains "T17 default threshold is 90 in the reason" ">= 90%" "$out"

# Env override 97: the same 95% cache now has headroom -> ASAP.
out=$(RESUME_SLOT_THRESHOLD=97 bash "$SLOT" --cache "$TMP/at95.json" --max-age 0 --emit reason 2>&1); rc=$?
assert_rc "T17b env override exits 0" 0 "$rc"
assert_contains "T17b env 97 makes 95% headroom -> ASAP" "bank free" "$out"
assert_contains "T17b reason reports the env threshold" "< 97%" "$out"

# ...and 98% is still exhausted under the same env value.
mk_cache "$TMP/at98.json" 10.0 "$(iso_in 9000)" 98.0 "$(iso_in 200000)"
out=$(RESUME_SLOT_THRESHOLD=97 bash "$SLOT" --cache "$TMP/at98.json" --max-age 0 --emit reason 2>&1); rc=$?
assert_rc "T17c env-97 exhausted path exits 0" 0 "$rc"
assert_contains "T17c env 97 still treats 98% as exhausted" "wait for seven-day reset" "$out"

# Explicit --threshold WINS over the env var.
out=$(RESUME_SLOT_THRESHOLD=97 bash "$SLOT" --cache "$TMP/at95.json" --max-age 0 --threshold 90 --emit reason 2>&1); rc=$?
assert_rc "T17d explicit --threshold exits 0" 0 "$rc"
assert_contains "T17d explicit --threshold beats the env var" "wait for seven-day reset" "$out"
assert_contains "T17d flag value (90) is the one applied" ">= 90%" "$out"

# A typo'd env value falls back to the shipped default SILENTLY — this sits on
# the resume-critical path (auto-arm -> arm-resume -> resume-slot), so it must
# not error the way a bad FLAG does. Mirrors auto-arm-on-cap.sh:186.
err=$(RESUME_SLOT_THRESHOLD=ninetyseven bash "$SLOT" --cache "$TMP/at95.json" --max-age 0 --emit reason 2>&1 >"$TMP/t17e-out"); rc=$?
assert_rc "T17e non-numeric env exits 0 (no crash)" 0 "$rc"
assert_contains "T17e non-numeric env falls back to 90" ">= 90%" "$(cat "$TMP/t17e-out")"
assert_not_contains "T17e fallback is silent (no ERR line)" "ERR resume-slot" "$err"
# Multi-dot and empty are the same class of typo — same rc-0 + silent contract
# as T17e, asserted explicitly so a future regression that starts ERRing on one
# of these shapes cannot hide behind the fallback-reason check alone.
err=$(RESUME_SLOT_THRESHOLD=9..7 bash "$SLOT" --cache "$TMP/at95.json" --max-age 0 --emit reason 2>&1 >"$TMP/t17f-out"); rc=$?
assert_rc "T17f multi-dot env exits 0 (no crash)" 0 "$rc"
assert_contains "T17f multi-dot env falls back to 90" ">= 90%" "$(cat "$TMP/t17f-out")"
assert_not_contains "T17f fallback is silent (no ERR line)" "ERR resume-slot" "$err"
err=$(RESUME_SLOT_THRESHOLD='' bash "$SLOT" --cache "$TMP/at95.json" --max-age 0 --emit reason 2>&1 >"$TMP/t17g-out"); rc=$?
assert_rc "T17g empty env exits 0 (no crash)" 0 "$rc"
assert_contains "T17g empty env falls back to 90" ">= 90%" "$(cat "$TMP/t17g-out")"
assert_not_contains "T17g fallback is silent (no ERR line)" "ERR resume-slot" "$err"

# A bad --threshold FLAG still errors loudly, even with a valid env value set —
# loudly meaning a diagnostic on stderr, not just a nonzero rc.
err=$(RESUME_SLOT_THRESHOLD=97 bash "$SLOT" --threshold abc --cache "$TMP/at95.json" --max-age 0 2>&1 >/dev/null); rc=$?
assert_rc "T17h bad --threshold flag still exits 1 under a valid env" 1 "$rc"
assert_contains "T17h bad --threshold flag reports the value it rejected" "ERR resume-slot: --threshold must be a number in 0-100, got: abc" "$err"

# ---------------------------------------------------------------------------
# T18: RANGE guard (codex-adv, HIMMEL-1271). A syntactically-numeric but
#      out-of-range value — 970, the fat-finger for 97 — would make every
#      window's 0-100% utilization compare as headroom, so `--time smart`
#      would pick ASAP and relaunch straight back into a walled bank. As an
#      env var that misconfiguration PERSISTS across every arm, so it must be
#      caught, not trusted.
# ---------------------------------------------------------------------------
err=$(RESUME_SLOT_THRESHOLD=970 bash "$SLOT" --cache "$TMP/at95.json" --max-age 0 --emit reason 2>&1 >"$TMP/t18-out"); rc=$?
assert_rc "T18 out-of-range env exits 0 (no crash)" 0 "$rc"
assert_contains "T18 out-of-range env falls back to 90 (not treated as headroom)" ">= 90%" "$(cat "$TMP/t18-out")"
assert_not_contains "T18 env fallback is silent (no ERR line)" "ERR resume-slot" "$err"
# The 95% window must still be EXHAUSTED — proving 970 never reached the compare.
assert_contains "T18 95% still parks at the reset under a 970 typo" "wait for seven-day reset" "$(cat "$TMP/t18-out")"

# An out-of-range explicit FLAG errors loudly (rc 1), like any other bad flag.
err=$(bash "$SLOT" --threshold 101 --cache "$TMP/at95.json" --max-age 0 --emit reason 2>&1); rc=$?
assert_rc "T18b --threshold 101 exits 1" 1 "$rc"
assert_contains "T18b surfaces the 0-100 range in the error" "must be a number in 0-100" "$err"

# Boundaries stay VALID: 0 and 100 are legal thresholds.
out=$(bash "$SLOT" --threshold 100 --cache "$TMP/at95.json" --max-age 0 --emit reason 2>&1); rc=$?
assert_rc "T18c --threshold 100 is valid" 0 "$rc"
assert_contains "T18c at 100 a 95% window has headroom" "bank free" "$out"
out=$(bash "$SLOT" --threshold 0 --cache "$TMP/at95.json" --max-age 0 --emit reason 2>&1); rc=$?
assert_rc "T18d --threshold 0 is valid" 0 "$rc"
assert_contains "T18d at 0 every window is exhausted" "wait for seven-day reset" "$out"

# ...and the SAME boundaries via the env path — the range guard must ACCEPT
# 0/100 there too, not quietly fall back to 90 (which would still produce a
# plausible-looking slot and hide the bug).
out=$(RESUME_SLOT_THRESHOLD=100 bash "$SLOT" --cache "$TMP/at95.json" --max-age 0 --emit reason 2>&1); rc=$?
assert_rc "T18e env threshold 100 is valid" 0 "$rc"
assert_contains "T18e env 100 leaves a 95% window with headroom" "bank free" "$out"
assert_contains "T18e env 100 was applied, not the 90 fallback" "< 100%" "$out"
out=$(RESUME_SLOT_THRESHOLD=0 bash "$SLOT" --cache "$TMP/at95.json" --max-age 0 --emit reason 2>&1); rc=$?
assert_rc "T18f env threshold 0 is valid" 0 "$rc"
assert_contains "T18f env 0 exhausts every window" "wait for seven-day reset" "$out"
assert_contains "T18f env 0 was applied, not the 90 fallback" ">= 0%" "$out"

# ---------------------------------------------------------------------------
# T19: a two-arg option with NO value must fail with a MESSAGE, not silently
#      (CodeRabbit). `shift 2` with one arg left returns nonzero, and under
#      `set -e` that killed the script with rc 1 and empty stderr — which
#      arm-resume then relayed as an empty error, the exact shape this
#      script's "the block OWNS its error reporting" contract forbids.
# ---------------------------------------------------------------------------
for _opt in --threshold --buffer-min --cache --max-age --emit; do
    err=$(bash "$SLOT" "$_opt" 2>&1 >/dev/null); rc=$?
    assert_rc "T19 $_opt with no value exits 1" 1 "$rc"
    assert_contains "T19 $_opt with no value says so" "ERR resume-slot: $_opt needs a value" "$err"
done
# The =VALUE form is unaffected, and a present-but-invalid value still takes the
# normal validation path (a message about the VALUE, not about a missing one).
err=$(bash "$SLOT" --threshold=abc --cache "$TMP/at95.json" --max-age 0 2>&1 >/dev/null); rc=$?
assert_rc "T19b --threshold=abc exits 1" 1 "$rc"
assert_contains "T19b --threshold=abc is a value error, not a missing-value error" "must be a number in 0-100" "$err"

# A following OPTION is a missing value too — otherwise it is swallowed as the
# value and the error points at the wrong (next) token.
err=$(bash "$SLOT" --threshold --emit epoch 2>&1 >/dev/null); rc=$?
assert_rc "T19c --threshold followed by an option exits 1" 1 "$rc"
assert_contains "T19c blames the option, not the token after it" "--threshold needs a value (got the option '--emit')" "$err"
assert_not_contains "T19c does not misreport the next arg as unknown" "unknown arg: epoch" "$err"

# ---------------------------------------------------------------------------
# T20: near-wall WARN (HIMMEL-1968). Under an operator-raised threshold a 96%
#      weekly is headroom by the rule and resolves ASAP (the 2026-08-19 19:37
#      arm, RESUME_SLOT_THRESHOLD=97) — the slot stays ASAP, but stderr must
#      carry a loud WARN naming the near-wall window. A genuinely free bank
#      emits no WARN.
# ---------------------------------------------------------------------------
mk_cache "$TMP/at96.json" 6.0 "$(iso_in 9000)" 96.0 "$(iso_in 200000)"
out=$(RESUME_SLOT_THRESHOLD=97 bash "$SLOT" --cache "$TMP/at96.json" --max-age 0 --emit reason 2>"$TMP/at96.err"); rc=$?
err=$(cat "$TMP/at96.err")
assert_rc "T20 96% under threshold 97 still exits 0" 0 "$rc"
assert_contains "T20 slot is still ASAP (bank free by the rule)" "bank free" "$out"
assert_contains "T20 stderr carries the near-wall WARN" "WARN resume-slot: seven-day=96%" "$err"
assert_contains "T20 WARN names the threshold" "under the 97% threshold" "$err"
assert_contains "T20 WARN offers the remedy" "pass --time HH:MM" "$err"
assert_not_contains "T20 WARN stays off stdout (emit contract)" "WARN resume-slot" "$out"
mk_cache "$TMP/at16.json" 2.0 "$(iso_in 9000)" 16.0 "$(iso_in 200000)"
out=$(RESUME_SLOT_THRESHOLD=97 bash "$SLOT" --cache "$TMP/at16.json" --max-age 0 --emit reason 2>&1); rc=$?
assert_rc "T20b free bank exits 0" 0 "$rc"
assert_not_contains "T20b free bank emits no near-wall WARN" "WARN resume-slot" "$out"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [ "$FAILED" -gt 0 ]; then echo "---"; echo "FAIL $FAILED case(s)"; exit 1; fi
echo "---"; echo "PASS all cases"; exit 0
