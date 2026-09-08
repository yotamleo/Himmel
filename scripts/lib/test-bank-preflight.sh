#!/usr/bin/env bash
# test-bank-preflight.sh — HIMMEL-1841. Hermetic: fixture caches, stub producer.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SUT="$REPO/scripts/lib/bank-preflight.sh"
PASS=0; FAIL=0
W="$(mktemp -d -t bank-preflight.XXXXXX)"; trap 'rm -rf "$W"' EXIT

# NO_FLEET: an empty-output ps stub, isolating every bank-only case below
# from this machine's OWN running fleet (a real `ps -eo args` would count
# whatever HIMMEL-/LUNA-named sessions genuinely happen to be running here
# and could trip the HIMMEL-2765 fleet cap for reasons unrelated to what
# these cases test) — the fleet cap gets its own dedicated cases further
# down, with a real stub feeding FLEET_PS_CMD.
NO_FLEET="$W/no-fleet-ps.sh"; printf '%s\n' '#!/usr/bin/env bash' 'true' > "$NO_FLEET"; chmod +x "$NO_FLEET"

verdict() {
  printf '%s' "$1" > "$W/c.json"
  CADENCE_BANK_CACHE="$W/c.json" CADENCE_BANK_SKIP_REFRESH=1 \
  CADENCE_BANK_LEDGER="$W/ledger.jsonl" CADENCE_BANK_LEG=testleg \
  FLEET_PS_CMD="$NO_FLEET" \
    bash "$SUT" </dev/null 2>"$W/err.log"
}
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok - $1";
  else FAIL=$((FAIL+1)); echo "FAIL - $1: expected '$2' got '$3'"; fi; }
NOW=$(date +%s)

check "below threshold -> PROCEED" PROCEED \
 "$(verdict "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":20},\"primaries_refreshed_at\":$NOW}")"
check "at threshold -> SKIPPED-BANK" SKIPPED-BANK \
 "$(verdict "{\"five_hour\":{\"utilization\":85},\"seven_day\":{\"utilization\":20},\"primaries_refreshed_at\":$NOW}")"
check "mixed, seven_day over -> SKIPPED-BANK" SKIPPED-BANK \
 "$(verdict "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":93},\"primaries_refreshed_at\":$NOW}")"
check "extra_usage high, primaries low -> PROCEED" PROCEED \
 "$(verdict "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":20},\"extra_usage\":{\"utilization\":99},\"primaries_refreshed_at\":$NOW}")"
check "one primary null, other below -> PROCEED" PROCEED \
 "$(verdict "{\"five_hour\":{\"utilization\":null},\"seven_day\":{\"utilization\":20},\"primaries_refreshed_at\":$NOW}")"
check "one primary null, other over -> SKIPPED-BANK" SKIPPED-BANK \
 "$(verdict "{\"five_hour\":{\"utilization\":null},\"seven_day\":{\"utilization\":91},\"primaries_refreshed_at\":$NOW}")"
check "both primaries null -> BANK-UNKNOWN" BANK-UNKNOWN \
 "$(verdict "{\"five_hour\":{\"utilization\":null},\"seven_day\":{\"utilization\":null},\"primaries_refreshed_at\":$NOW}")"
check "bare dot utilization -> BANK-UNKNOWN" BANK-UNKNOWN \
 "$(verdict "{\"five_hour\":{\"utilization\":\".\"},\"seven_day\":{\"utilization\":null},\"primaries_refreshed_at\":$NOW}")"
check "stamp absent -> BANK-STALE" BANK-STALE \
 "$(verdict "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":20}}")"
check "non-numeric max age -> BANK-UNKNOWN" BANK-UNKNOWN \
 "$(CADENCE_BANK_MAX_AGE=abc verdict "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":20},\"primaries_refreshed_at\":$NOW}")"
check "non-numeric max pct -> BANK-UNKNOWN" BANK-UNKNOWN \
 "$(CADENCE_BANK_MAX_PCT=abc verdict "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":20},\"primaries_refreshed_at\":$NOW}")"
check "valid max age, stamp too old -> BANK-STALE" BANK-STALE \
 "$(CADENCE_BANK_MAX_AGE=600 verdict "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":20},\"primaries_refreshed_at\":$((NOW-99999))}")"
check "non-integer stamp -> BANK-STALE" BANK-STALE \
 "$(verdict "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":20},\"primaries_refreshed_at\":\"1.2.3\"}")"
# CADENCE_BANK_LEDGER is required here too — without it the SUT falls back to
# its default and this "hermetic" suite appends a row outside $W on every run.
check "missing cache -> BANK-UNKNOWN" BANK-UNKNOWN \
 "$(CADENCE_BANK_CACHE="$W/gone.json" CADENCE_BANK_SKIP_REFRESH=1 CADENCE_BANK_LEDGER="$W/ledger.jsonl" FLEET_PS_CMD="$NO_FLEET" bash "$SUT" </dev/null 2>/dev/null)"

home_unset_out=$(env -u HOME -u CADENCE_BANK_LEDGER CADENCE_BANK_CACHE="$W/gone-home.json" \
  CADENCE_BANK_SKIP_REFRESH=1 FLEET_PS_CMD="$NO_FLEET" bash "$SUT" </dev/null 2>/dev/null)
home_unset_rc=$?
case "$home_unset_out" in
  PROCEED|SKIPPED-BANK|BANK-STALE|BANK-UNKNOWN) home_unset_token=true ;;
  *) home_unset_token=false ;;
esac
if [ "$home_unset_rc" -eq 0 ] && [ "$home_unset_token" = true ]; then
  PASS=$((PASS+1)); echo "ok - HOME unset still yields a verdict"
else
  FAIL=$((FAIL+1)); echo "FAIL - HOME unset returned rc=$home_unset_rc output='$home_unset_out'"
fi

# Ledger row written
if grep -q '"verdict":"PROCEED"' "$W/ledger.jsonl" 2>/dev/null; then
  PASS=$((PASS+1)); echo "ok - ledger row written"
else
  FAIL=$((FAIL+1)); echo "FAIL - no ledger row"
fi

# Ledger preserves whether the verdict used one primary or both.
rm -f "$W/ledger.jsonl"
verdict "{\"five_hour\":{\"utilization\":null},\"seven_day\":{\"utilization\":20},\"primaries_refreshed_at\":$NOW}" >/dev/null
single_degraded=false; grep -q '"degraded":true' "$W/ledger.jsonl" && single_degraded=true
rm -f "$W/ledger.jsonl"
verdict "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":20},\"primaries_refreshed_at\":$NOW}" >/dev/null
two_healthy=false; grep -q '"degraded":false' "$W/ledger.jsonl" && two_healthy=true
if [ "$single_degraded" = true ] && [ "$two_healthy" = true ]; then
  PASS=$((PASS+1)); echo "ok - ledger records degraded state"
else
  FAIL=$((FAIL+1)); echo "FAIL - ledger does not record degraded state"
fi

future=$(( $(date +%s) + 86400 ))
printf '%s' "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":20},\"primaries_refreshed_at\":$future}" > "$W/c.json"
future_out=$(CADENCE_BANK_CACHE="$W/c.json" CADENCE_BANK_SKIP_REFRESH=1 \
  CADENCE_BANK_LEDGER="$W/ledger.jsonl" FLEET_PS_CMD="$NO_FLEET" bash "$SUT" 2>/dev/null || true)
if [ "$future_out" = "BANK-STALE" ]; then
  PASS=$((PASS+1)); echo "ok - future-dated stamp is stale"
else
  FAIL=$((FAIL+1)); echo "FAIL - future-dated stamp did not yield BANK-STALE"
fi

# Held-open stdin via a FIFO, refresh ENABLED against a stub producer that reads
# stdin. A FIFO opened read-write never EOFs and has no writer to wait on, so a
# correct SUT returns at once and only a blocked one pays the timeout. This
# replaces `sleep N | timeout M`: sleep itself bounds stdin, so no timeout value
# can distinguish a correct SUT from one blocked on stdin. The watchdog is
# bash 3.2-compatible; GNU timeout is absent on macOS and Windows timeout.exe
# has incompatible semantics.
watchdog_after_25s() {
  local watched_pid="$1" sleeper_pid
  sleep 25 &
  sleeper_pid=$!
  trap 'kill "$sleeper_pid" 2>/dev/null; wait "$sleeper_pid" 2>/dev/null; exit 0' TERM INT
  wait "$sleeper_pid"
  kill -TERM "-$watched_pid" 2>/dev/null
}

stub="$W/prod.sh"; printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' > "$stub"; chmod +x "$stub"
printf '%s' "{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":20},\"primaries_refreshed_at\":$NOW}" > "$W/c.json"
# Monitor mode gives the SUT a dedicated process group so the watchdog also
# terminates a blocked producer descendant, not just its waiting parent shell.
set -m
if mkfifo "$W/fifo" 2>/dev/null; then
  exec 3<>"$W/fifo"
  CADENCE_BANK_CACHE="$W/c.json" CADENCE_BANK_PRODUCER="$stub" FLEET_PS_CMD="$NO_FLEET" \
    CADENCE_BANK_LEDGER="$W/ledger.jsonl" bash "$SUT" <&3 >/dev/null 2>&1 &
  sut_pid=$!
else
  # Fallback where mkfifo is unavailable: keep stdin open with a separate holder.
  (
    set +m
    exec 4< <(sleep 60)
    holder_pid=$!
    CADENCE_BANK_CACHE="$W/c.json" CADENCE_BANK_PRODUCER="$stub" FLEET_PS_CMD="$NO_FLEET" \
      CADENCE_BANK_LEDGER="$W/ledger.jsonl" bash "$SUT" <&4 >/dev/null 2>&1
    rc=$?
    exec 4<&-
    kill "$holder_pid" 2>/dev/null || true
    wait "$holder_pid" 2>/dev/null || true
    exit "$rc"
  ) &
  sut_pid=$!
fi
set +m
watchdog_after_25s "$sut_pid" &
watchdog_pid=$!
if wait "$sut_pid"; then rc=0; else rc=$?; fi
kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true
[ -e "$W/fifo" ] && exec 3>&-
if [ "$rc" -eq 0 ]; then PASS=$((PASS+1)); echo "ok - does not block on held-open stdin"
else FAIL=$((FAIL+1)); echo "FAIL - blocked on held-open stdin (missing </dev/null?)"; fi

# --- HIMMEL-2765: fleet-size cap --------------------------------------------
# mk_ps_stub <dir> <pid>:<comm>:<argv-line>... - writes a FLEET_PS_CMD stub
# (matching the real `ps -eo pid=,args=` default: headerless "PID ARGV"
# lines) AND a FLEET_PROC fixture tree with one comm file per pid, so the
# codex-3 comm-confirmation step below has something real to read. <comm>
# is settable PER ENTRY so a case can plant a non-claude WRAPPER (e.g.
# konsole) whose own argv happens to embed the claude invocation as text,
# without it being counted twice (codex-3 review finding).
mk_ps_stub() {
  local dir="$1"; shift
  mkdir -p "$dir/proc"
  local data="$dir/ps.data" entry pid comm argv
  : > "$data"
  for entry in "$@"; do
    pid="${entry%%:*}"; entry="${entry#*:}"
    comm="${entry%%:*}"; argv="${entry#*:}"
    printf '%s %s\n' "$pid" "$argv" >> "$data"
    mkdir -p "$dir/proc/$pid"
    printf '%s' "$comm" > "$dir/proc/$pid/comm"
  done
  printf '%s\n' '#!/usr/bin/env bash' "cat '$data'" > "$dir/ps"
  chmod +x "$dir/ps"
}

HEALTHY_CACHE="{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":20},\"primaries_refreshed_at\":$NOW}"

# fleet_verdict <ps-stub-dir> [extra env assignments...] - same shape as
# verdict(), but with FLEET_PS_CMD/FLEET_PROC pointed at the given stub
# fixture instead of NO_FLEET, and a healthy cache (these cases test the
# fleet gate, not the bank thresholds it runs ahead of).
# codex-3 (CR review, 4th panel round, Suggestion): `env "$@" ... VAR=val
# bash "$SUT"` only ADDS/overrides vars, it does not clear the rest of the
# inherited environment - a launching shell that already has FLEET_CAP_OK
# set (plausible: an operator debugging a fleet refusal) would silently
# bypass every ordinary refusal case below, unless a case's own "$@"
# happens to override it. Default it to unset here, BEFORE "$@" is
# applied, so only a case that explicitly asks for the bypass gets it.
# HIMMEL-2789: these cases simulate an actual ARM attempt, so
# CADENCE_BANK_LAUNCH defaults on via the FLEET_VERDICT_LAUNCH shell
# variable (bash's prefix-assignment-to-function scoping - visible inside
# fleet_verdict, restored after) rather than an env "$@" override, since
# env's own -u/NAME=VALUE parsing requires every -u option to precede every
# assignment and this helper already emits CADENCE_BANK_CACHE=... etc. The
# launch-intent gate itself gets its own dedicated case further below, via
# `FLEET_VERDICT_LAUNCH= fleet_verdict ...`.
fleet_verdict() {
  local dir="$1"; shift
  printf '%s' "$HEALTHY_CACHE" > "$W/c.json"
  env -u FLEET_CAP_OK "$@" CADENCE_BANK_LAUNCH="${FLEET_VERDICT_LAUNCH-1}" \
    CADENCE_BANK_CACHE="$W/c.json" CADENCE_BANK_SKIP_REFRESH=1 \
    CADENCE_BANK_LEDGER="$W/ledger.jsonl" CADENCE_BANK_LEG=testleg \
    FLEET_PS_CMD="$dir/ps" FLEET_PROC="$dir/proc" \
    bash "$SUT" </dev/null 2>"$W/err.log"
}

# 4 fake legs, cap 4 (n >= CAP) -> SKIPPED-FLEET.
p4="$W/ps4"; mk_ps_stub "$p4" \
  '9001:claude:--model claude-opus-5 -n HIMMEL-1000-leg load doc' \
  '9002:claude:--model claude-opus-5 -n HIMMEL-1001-leg load doc' \
  '9003:claude:--model claude-opus-5 -n HIMMEL-1002-leg load doc' \
  '9004:claude:--model claude-opus-5 -n HIMMEL-1003-leg load doc'
check "4 legs, cap=4 -> SKIPPED-FLEET" SKIPPED-FLEET \
  "$(fleet_verdict "$p4" HIMMEL_FLEET_CAP=4)"

# 3 fake legs, cap 4 (n < CAP) -> falls through to the (healthy) bank check.
p3="$W/ps3"; mk_ps_stub "$p3" \
  '9001:claude:--model claude-opus-5 -n HIMMEL-1000-leg load doc' \
  '9002:claude:--model claude-opus-5 -n HIMMEL-1001-leg load doc' \
  '9003:claude:--model claude-opus-5 -n LUNA-2000-leg load doc'
check "3 legs (HIMMEL+LUNA), cap=4 -> PROCEED" PROCEED \
  "$(fleet_verdict "$p3" HIMMEL_FLEET_CAP=4)"

# Same 4-leg fixture as the first case, but FLEET_CAP_OK=1 bypasses the cap.
check "4 legs, cap=4, FLEET_CAP_OK=1 -> PROCEED (bypass)" PROCEED \
  "$(fleet_verdict "$p4" HIMMEL_FLEET_CAP=4 FLEET_CAP_OK=1)"

# Consoles are not legs: 3 real legs + 1 console (named to collide on prefix
# if the exclusion were substring-only) still counts as 3, under cap 4.
pconsole="$W/psconsole"; mk_ps_stub "$pconsole" \
  '9001:claude:--model claude-opus-5 -n HIMMEL-1000-leg load doc' \
  '9002:claude:--model claude-opus-5 -n HIMMEL-1001-leg load doc' \
  '9003:claude:--model claude-opus-5 -n HIMMEL-1002-leg load doc' \
  '9004:claude:--model claude-fable-5-1 -n HIMMEL-nextleg-2026-09-05V-console load doc'
check "3 legs + 1 console, cap=4 -> PROCEED (console excluded)" PROCEED \
  "$(fleet_verdict "$pconsole" HIMMEL_FLEET_CAP=4)"

# HIMMEL_FLEET_CAP is configurable: the same 3-leg fixture trips a cap of 2.
check "3 legs, cap=2 (HIMMEL_FLEET_CAP override) -> SKIPPED-FLEET" SKIPPED-FLEET \
  "$(fleet_verdict "$p3" HIMMEL_FLEET_CAP=2)"

# FLEET n/CAP is printed on EVERY call, including a PROCEED (below cap).
# HIMMEL-2782: the line now names the lane breakdown too - p3's fixture has
# no environ files (mk_ps_stub only writes comm), so every candidate falls
# back to "native" (the safe default for an unreadable/missing environ).
fleet_verdict "$p3" HIMMEL_FLEET_CAP=4 >/dev/null
if grep -q 'FLEET native=3 claudex=0 total=3/4' "$W/err.log" 2>/dev/null; then
  PASS=$((PASS+1)); echo "ok - FLEET n/CAP printed on a PROCEED call"
else
  FAIL=$((FAIL+1)); echo "FAIL - FLEET n/CAP not printed on a PROCEED call"
fi

# HIMMEL-2782: a claudex candidate (CLAUDEX_LANE_OK=1 in its own
# /proc/<pid>/environ) is named separately from native ones in the FLEET
# line - mk_ps_stub_environ below extends mk_ps_stub with a per-entry
# environ file so this can be asserted directly.
mk_ps_stub_environ() {
  local dir="$1"; shift
  mkdir -p "$dir/proc"
  local data="$dir/ps.data" entry pid comm argv env_body
  : > "$data"
  for entry in "$@"; do
    pid="${entry%%:*}"; entry="${entry#*:}"
    comm="${entry%%:*}"; entry="${entry#*:}"
    env_body="${entry%%:*}"; argv="${entry#*:}"
    printf '%s %s\n' "$pid" "$argv" >> "$data"
    mkdir -p "$dir/proc/$pid"
    printf '%s' "$comm" > "$dir/proc/$pid/comm"
    printf '%s' "$env_body" | tr ',' '\0' > "$dir/proc/$pid/environ"
  done
  printf '%s\n' '#!/usr/bin/env bash' "cat '$data'" > "$dir/ps"
  chmod +x "$dir/ps"
}
pclaudex="$W/psclaudex"; mk_ps_stub_environ "$pclaudex" \
  '9001:claude:HOME=/home/x,CLAUDEX_LANE_OK=1:--model gpt-6-astra -n HIMMEL-1000-leg load doc' \
  '9002:claude:HOME=/home/x:--model claude-opus-5 -n HIMMEL-1001-leg load doc'
fleet_verdict "$pclaudex" HIMMEL_FLEET_CAP=4 >/dev/null
if grep -q 'FLEET native=1 claudex=1 total=2/4' "$W/err.log" 2>/dev/null; then
  PASS=$((PASS+1)); echo "ok - claudex candidate named separately in the FLEET line"
else
  FAIL=$((FAIL+1)); echo "FAIL - claudex candidate not named separately in the FLEET line"
fi

# codex-1 (CR review): a session with NO argument between "claude" and "-n"
# (e.g. `claude -n HIMMEL-1000-leg ...`) must still be counted - the old
# `claude .* -n ...` pattern required TWO separate whitespace runs and
# silently missed this shape, undercounting the fleet.
pminimal="$W/psminimal"; mk_ps_stub "$pminimal" \
  '9001:claude:-n HIMMEL-1000-leg load doc' \
  '9002:claude:-n HIMMEL-1001-leg load doc' \
  '9003:claude:-n HIMMEL-1002-leg load doc' \
  '9004:claude:-n HIMMEL-1003-leg load doc'
check "4 legs with NO args before -n, cap=4 -> SKIPPED-FLEET (codex-1)" SKIPPED-FLEET \
  "$(fleet_verdict "$pminimal" HIMMEL_FLEET_CAP=4)"

# codex-3 (CR review): a WRAPPER process (e.g. konsole, comm != claude)
# whose own argv EMBEDS the claude invocation it launched as literal text
# must not be counted ALONGSIDE the real claude child it wraps - that would
# double-count ONE leg (HIMMEL-1000-leg here) as two. pid 9001 is konsole
# wrapping HIMMEL-1000-leg (its argv embeds the full claude command as
# text, same shape headed-arm.sh launches with); pid 9002 is the REAL
# claude child for that SAME leg; pid 9003 is a second, distinct real leg.
# Two genuine legs total. cap=3 differentiates: the FIXED (comm-filtered)
# count is 2 -> PROCEED; the OLD buggy (argv-text-only) count would have
# been 3 (double-counting 9001+9002 as separate legs) -> SKIPPED-FLEET.
pwrapper="$W/pswrapper"; mk_ps_stub "$pwrapper" \
  '9001:konsole:--workdir /repo -e env -u X claude --model claude-opus-5 -n HIMMEL-1000-leg load doc' \
  '9002:claude:--model claude-opus-5 -n HIMMEL-1000-leg load doc' \
  '9003:claude:--model claude-opus-5 -n HIMMEL-1001-leg load doc'
check "wrapper + its real child count as ONE leg, cap=3 -> PROCEED (comm-filtered, codex-3)" PROCEED \
  "$(fleet_verdict "$pwrapper" HIMMEL_FLEET_CAP=3)"

# codex-2 (CR review, 2nd panel round): a host with NO usable procfs at
# FLEET_PROC must not silently report fleet_n=0 forever (which would
# NEVER enforce the cap there) - it falls back to argv-only matching
# instead. Reuses the wrapper fixture: WITHOUT comm confirmation the
# konsole wrapper line (9001) counts alongside its own real child (9002),
# so the fallback count is 3 (not the comm-filtered 2 case "wrapper..."
# above asserts) - cap=3 still trips SKIPPED-FLEET, proving the cap keeps
# enforcing (less precisely) rather than silently going permanently dark.
fleet_verdict_no_procfs() {
  local dir="$1"; shift
  printf '%s' "$HEALTHY_CACHE" > "$W/c.json"
  # CodeRabbit finding: this helper is a separate function from
  # fleet_verdict() and needs the SAME FLEET_CAP_OK isolation - a
  # launching shell that already has it set would silently make this
  # helper's own refusal cases pass through the bypass branch instead of
  # exercising the fallback logic they are meant to test.
  env -u FLEET_CAP_OK "$@" CADENCE_BANK_LAUNCH="${FLEET_VERDICT_LAUNCH-1}" \
    CADENCE_BANK_CACHE="$W/c.json" CADENCE_BANK_SKIP_REFRESH=1 \
    CADENCE_BANK_LEDGER="$W/ledger.jsonl" CADENCE_BANK_LEG=testleg \
    FLEET_PS_CMD="$dir/ps" FLEET_PROC="$dir/no-such-proc-dir" \
    bash "$SUT" </dev/null 2>"$W/err.log"
}
check "no procfs at FLEET_PROC, cap=3 -> SKIPPED-FLEET (argv-only fallback, codex-2)" SKIPPED-FLEET \
  "$(fleet_verdict_no_procfs "$pwrapper" HIMMEL_FLEET_CAP=3)"
if grep -q 'comm unreadable for at least one fleet candidate' "$W/err.log" 2>/dev/null; then
  PASS=$((PASS+1)); echo "ok - no-procfs fallback logs the degradation loudly"
else
  FAIL=$((FAIL+1)); echo "FAIL - no-procfs fallback did not log the degradation"
fi

# codex-2 (CR review, 3rd panel round): the procfs ROOT existing does not
# establish that an INDIVIDUAL candidate's own comm file is readable (a
# partial/unsupported procfs, or the pid already exited) - decide per
# candidate, not once for the whole host. pid 9003's comm file is
# deliberately absent even though $dir/proc itself exists (unlike the
# no-procfs case above, which points FLEET_PROC at a directory that does
# not exist at all); the fallback must still count it. 2 legs with a
# readable comm (9001, 9002) + 1 with an unreadable one (9003, counted via
# the argv fallback) = 3 -> cap=3 trips SKIPPED-FLEET.
ppartial="$W/pspartial"; mk_ps_stub "$ppartial" \
  '9001:claude:--model claude-opus-5 -n HIMMEL-1000-leg load doc' \
  '9002:claude:--model claude-opus-5 -n HIMMEL-1001-leg load doc' \
  '9003:claude:--model claude-opus-5 -n HIMMEL-1002-leg load doc'
rm -f "$ppartial/proc/9003/comm"
check "readable procfs root, one unreadable comm file, cap=3 -> SKIPPED-FLEET (per-candidate fallback, codex-2 round 3)" SKIPPED-FLEET \
  "$(fleet_verdict "$ppartial" HIMMEL_FLEET_CAP=3)"

# codex-3 (CR review, 3rd panel round): a FAILED census command (ps
# missing, an unsupported FLEET_PS_CMD) must not be indistinguishable from
# "genuinely zero matching processes" - both would otherwise produce empty
# output and silently permit every launch. A non-zero exit refuses
# (SKIPPED-FLEET) rather than reading as a clean, empty fleet.
pbroken="$W/psbroken"; mkdir -p "$pbroken"
printf '%s\n' '#!/usr/bin/env bash' 'echo "ps: command not found" >&2' 'exit 127' > "$pbroken/ps"
chmod +x "$pbroken/ps"
check "census command fails (rc=127), cap=4 -> SKIPPED-FLEET (fail-safe, codex-3 round 3)" SKIPPED-FLEET \
  "$(fleet_verdict "$pbroken" HIMMEL_FLEET_CAP=4)"
if grep -q 'fleet process census failed' "$W/err.log" 2>/dev/null; then
  PASS=$((PASS+1)); echo "ok - failed census logs the reason loudly"
else
  FAIL=$((FAIL+1)); echo "FAIL - failed census did not log the reason"
fi

# codex-2 (CR review, 4th panel round, Suggestion): FLEET_CAP_OK=1 must
# recover a launch on a broken/unsupported census too - the override is
# not reachable only on the ordinary at/over-cap path.
check "census command fails, FLEET_CAP_OK=1 -> PROCEED (bypass reaches the census-failure path too, codex-2 round 4)" PROCEED \
  "$(fleet_verdict "$pbroken" HIMMEL_FLEET_CAP=4 FLEET_CAP_OK=1)"

# codex-3 (CR review, 2nd panel round, Suggestion): FLEET_CAP_OK=0 must
# NOT bypass the cap - only the exact value "1" does.
check "4 legs, cap=4, FLEET_CAP_OK=0 -> SKIPPED-FLEET (exact-match bypass)" SKIPPED-FLEET \
  "$(fleet_verdict "$p4" HIMMEL_FLEET_CAP=4 FLEET_CAP_OK=0)"

# --- HIMMEL-2789: the fleet cap's REFUSAL requires declared launch intent --
# Same over-cap fixture as "4 legs, cap=4 -> SKIPPED-FLEET" above, but with
# CADENCE_BANK_LAUNCH explicitly unset (FLEET_VERDICT_LAUNCH= overrides
# fleet_verdict()'s own default-on) - a plain bank READ, e.g. hermes-
# critic.sh's /pr-check pass or a statusline probe, must never be refused
# by a cap meant to gate NEW arms, not reads.
# shellcheck disable=SC1007  # deliberate empty-string prefix assignment, not a typo'd `VAR =`
check "4 legs, cap=4, no CADENCE_BANK_LAUNCH -> PROCEED (read-only, not refused)" PROCEED \
  "$(FLEET_VERDICT_LAUNCH= fleet_verdict "$p4" HIMMEL_FLEET_CAP=4)"

# The informational FLEET line still prints on a plain read - only the
# refusal is gated, never the visibility.
# shellcheck disable=SC1007  # deliberate empty-string prefix assignment, not a typo'd `VAR =`
FLEET_VERDICT_LAUNCH= fleet_verdict "$p4" HIMMEL_FLEET_CAP=4 >/dev/null
if grep -q 'FLEET native=4 claudex=0 total=4/4' "$W/err.log" 2>/dev/null; then
  PASS=$((PASS+1)); echo "ok - a plain read still prints the FLEET line"
else
  FAIL=$((FAIL+1)); echo "FAIL - a plain read suppressed the FLEET line"
fi

# --- HIMMEL-2782: CADENCE_BANK_LANE=claudex parks on the codex bank -------
# claudex_verdict <status-stub-output> - same shape as verdict(), but with
# CADENCE_BANK_LANE=claudex and CADENCE_BANK_STATUS_CMD pointed at a stub
# that just echoes the given line (mirroring scripts/lanes/bank-status.ts's
# own "<lane> <state> <detail>" stdout contract). NO_FLEET keeps this
# isolated from the fleet gate, which runs first regardless of lane.
claudex_verdict() {
  local status_line="$1"
  local stub="$W/claudex-status.sh"
  printf '%s\n' '#!/usr/bin/env bash' "printf '%s\n' '$status_line'" > "$stub"
  chmod +x "$stub"
  printf '%s' "$HEALTHY_CACHE" > "$W/c.json"
  CADENCE_BANK_CACHE="$W/c.json" CADENCE_BANK_SKIP_REFRESH=1 \
  CADENCE_BANK_LEDGER="$W/ledger.jsonl" CADENCE_BANK_LEG=testleg \
  FLEET_PS_CMD="$NO_FLEET" CADENCE_BANK_LANE=claudex CADENCE_BANK_STATUS_CMD="$stub" \
    bash "$SUT" </dev/null 2>"$W/err.log"
}

check "claudex lane, codex bank funded -> PROCEED" PROCEED \
  "$(claudex_verdict "claudex funded measured weekly used=10% free=90%")"
check "claudex lane, codex bank spent -> SKIPPED-BANK (parks on the codex bank, never the Claude check)" SKIPPED-BANK \
  "$(claudex_verdict "claudex spent measured weekly used=99% free=1%")"
check "claudex lane, codex bank unknown -> PROCEED (WARN, never refuses on an unmeasurable claudex bank)" PROCEED \
  "$(claudex_verdict "claudex unknown unmeasurable reason=probe-failure")"
if grep -q 'claudex lane state unmeasurable/unknown' "$W/err.log" 2>/dev/null; then
  PASS=$((PASS+1)); echo "ok - unmeasurable claudex bank WARNs by name"
else
  FAIL=$((FAIL+1)); echo "FAIL - unmeasurable claudex bank did not WARN by name"
fi

# A missing/empty status line (e.g. the probe crashed outright, bank-status.ts
# itself errored) must fall to the SAME unknown/WARN/PROCEED path, never a
# crash or a false refusal.
check "claudex lane, status command produces nothing -> PROCEED (WARN)" PROCEED \
  "$(claudex_verdict "")"

# native lane (the default) is completely unaffected by CADENCE_BANK_LANE
# being unset - the pre-existing Claude bank thresholds still govern, and a
# claudex-shaped healthy cache never leaks into the native path.
check "native lane (no CADENCE_BANK_LANE): still governed by the Claude bank check" PROCEED \
  "$(verdict "$HEALTHY_CACHE")"

# codex-3 (HIMMEL-2782 CR fix): a CADENCE_BANK_STATUS_CMD override whose
# path contains a space must not be word-split (same bug class as
# FLEET_PS_CMD's own quoting fix, applied here to the codex-bank command).
# HIMMEL-2799: spent distinguishes a successful call from the unknown-state
# PROCEED fallback that a word-split invocation would silently reach.
SPACE_DIR="$W/dir with space"
mkdir -p "$SPACE_DIR"
SPACE_STUB="$SPACE_DIR/bank-status.sh"
printf '%s\n' '#!/usr/bin/env bash' "printf '%s\n' 'claudex spent measured weekly used=99% free=1%'" > "$SPACE_STUB"
chmod +x "$SPACE_STUB"
printf '%s' "$HEALTHY_CACHE" > "$W/c.json"
check "claudex lane, CADENCE_BANK_STATUS_CMD path contains a space -> SKIPPED-BANK (not word-split into a bogus command)" SKIPPED-BANK \
  "$(CADENCE_BANK_CACHE="$W/c.json" CADENCE_BANK_SKIP_REFRESH=1 \
     CADENCE_BANK_LEDGER="$W/ledger.jsonl" CADENCE_BANK_LEG=testleg \
     FLEET_PS_CMD="$NO_FLEET" CADENCE_BANK_LANE=claudex CADENCE_BANK_STATUS_CMD="$SPACE_STUB" \
       bash "$SUT" </dev/null 2>"$W/err.log")"

echo "passed=$PASS failed=$FAIL"; [ "$FAIL" -eq 0 ]
