#!/usr/bin/env bash
# test-bank-preflight-fleet.sh — HIMMEL-2774. RED-first suite for the atomic
# admission + reservation mechanism that closes the arm-time TOCTOU race:
# two concurrent declared launches both observing the fleet under cap and
# both proceeding, pushing the fleet over HIMMEL_FLEET_CAP (deferred from
# HIMMEL-2765's /pr-check).
#
# SUT is a variable (FLEET_SUT) — not a hardcoded path — so this SAME suite
# can run unmodified against the pre-fix script to produce genuine RED
# evidence (both concurrent launches PROCEED there: no reservation mechanism
# exists to make the second call see the first's claim) and against the
# fixed script for GREEN. Console ruling (HIMMEL-nextleg-2026-09-13D,
# 2026-09-13): write case (a) first, run it RED against the pre-fix copy,
# THEN implement — RED and GREEN both go in the PR body side by side.
#
# No .ps1 twin: the atomic mkdir admission/reservation mechanism it exercises
# is a POSIX tmpfs (${XDG_RUNTIME_DIR:-/tmp}/himmel-fleet-<uid>) construct
# with no Windows equivalent in bank-preflight.sh (project convention: a
# documented platform guard suffices for a test harness).
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SUT="${FLEET_SUT:-$REPO/scripts/lib/bank-preflight.sh}"
PASS=0; FAIL=0
# codex-7 (this round): an unchecked mktemp failure leaves $W empty under
# `set -u`-adjacent `-o pipefail` (no `-e` here) — every later fixture path
# would then target the filesystem root instead of failing loudly.
W="$(mktemp -d -t bank-preflight-fleet.XXXXXX)" || { echo "FAIL - could not create scratch dir via mktemp" >&2; exit 1; }
if [ -z "$W" ] || [ ! -d "$W" ]; then echo "FAIL - mktemp returned an empty/invalid scratch dir" >&2; exit 1; fi
trap 'rm -rf "$W"' EXIT
NOW="$(date +%s)"
HEALTHY_CACHE="{\"five_hour\":{\"utilization\":10},\"seven_day\":{\"utilization\":20},\"primaries_refreshed_at\":$NOW}"
printf '%s' "$HEALTHY_CACHE" > "$W/c.json"

check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok - $1";
  else FAIL=$((FAIL+1)); echo "FAIL - $1: expected '$2' got '$3'"; fi; }

# mk_ps_stub <dir> <pid:comm:argv> ... — same shape as test-bank-preflight.sh's
# own fixture builder, kept independent here (this suite must run standalone
# and unmodified against the pre-fix script, which predates that helper's
# current form).
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

# run_pf <slots-dir> <proc-dir> <extra env assignments...> — invokes the SUT
# with a healthy bank cache (so a PROCEED/SKIPPED-FLEET verdict is never
# masked by an unrelated BANK-* verdict) and prints its stdout verdict.
run_pf() {
  local slots="$1" dir="$2"; shift 2
  # codex-6 (HIMMEL-2774, 4th panel round): FLEET_CAP_OK/CADENCE_BANK_LAUNCH
  # default to empty here, BEFORE "$@" — an ambient export of either in the
  # invoking shell/CI would otherwise leak through `env`'s inherited
  # environment and silently invalidate a refusal case or turn an
  # informational case into a launch. "$@" comes after, so a case's own
  # explicit assignment still overrides these defaults (env: later
  # duplicate assignments win).
  env FLEET_CAP_OK= CADENCE_BANK_LAUNCH= "$@" HIMMEL_FLEET_SLOTS="$slots" FLEET_PS_CMD="$dir/ps" FLEET_PROC="$dir/proc" \
    CADENCE_BANK_CACHE="$W/c.json" CADENCE_BANK_SKIP_REFRESH=1 CADENCE_BANK_LEDGER="$W/ledger.jsonl" \
    bash "$SUT" </dev/null 2>>"$W/err.log"
}

p0="$W/ps0"; mk_ps_stub "$p0"
p3="$W/ps3"; mk_ps_stub "$p3" \
  '9001:claude:--model claude-opus-5 -n HIMMEL-1000-leg load doc' \
  '9002:claude:--model claude-opus-5 -n HIMMEL-1001-leg load doc' \
  '9003:claude:--model claude-opus-5 -n HIMMEL-1002-leg load doc'

# --- (a) cap 4, 3 live, TWO CONCURRENT declared launches -> exactly one
# PROCEED, one SKIPPED-FLEET. This is the case the console asked to see RED
# first: on the pre-fix script there is no serialisation/reservation at all,
# so both concurrent calls independently read the SAME static 3-live count,
# both find it under cap, and both PROCEED — the fleet then actually lands
# at 5 once both go live. The fixed script's atomic `.admit` critical section
# makes the SECOND caller observe the FIRST caller's reservation.
slots_a="$(mktemp -d "$W/slots-a.XXXXXX")" || { echo "FAIL - could not create slots-a scratch dir" >&2; exit 1; }
out_a="$W/out_a"; out_b="$W/out_b"
( run_pf "$slots_a" "$p3" CADENCE_BANK_LAUNCH=1 CADENCE_BANK_LEG=HIMMEL-9001-fleetA HIMMEL_FLEET_CAP=4 > "$out_a" ) &
pid_a=$!
( run_pf "$slots_a" "$p3" CADENCE_BANK_LAUNCH=1 CADENCE_BANK_LEG=HIMMEL-9002-fleetB HIMMEL_FLEET_CAP=4 > "$out_b" ) &
pid_b=$!
wait "$pid_a" "$pid_b"
va="$(cat "$out_a")"; vb="$(cat "$out_b")"
proceeds=0; skips=0
for v in "$va" "$vb"; do
  case "$v" in
    PROCEED) proceeds=$((proceeds+1)) ;;
    SKIPPED-FLEET) skips=$((skips+1)) ;;
  esac
done
check "(a) cap 4, 3 live, two concurrent declared launches -> exactly one PROCEED, one SKIPPED-FLEET (leg-a=$va leg-b=$vb)" "1 1" "$proceeds $skips"

# --- (b) a reservation is consumed once a live session with its name
# appears — the count must not double (live session + its own now-stale
# reservation both counted would silently shrink real headroom).
slots_b="$(mktemp -d "$W/slots-b.XXXXXX")" || { echo "FAIL - could not create slots-b scratch dir" >&2; exit 1; }
p2="$W/ps2"; mk_ps_stub "$p2" \
  '9001:claude:--model claude-opus-5 -n HIMMEL-1000-leg load doc' \
  '9002:claude:--model claude-opus-5 -n HIMMEL-1001-leg load doc'
before_b="$(run_pf "$slots_b" "$p2" CADENCE_BANK_LAUNCH=1 CADENCE_BANK_LEG=HIMMEL-9003-consumeme HIMMEL_FLEET_CAP=4)"
check "(b) setup: declared launch under cap -> PROCEED, reservation created" PROCEED "$before_b"
p3live="$W/ps3live"; mk_ps_stub "$p3live" \
  '9001:claude:--model claude-opus-5 -n HIMMEL-1000-leg load doc' \
  '9002:claude:--model claude-opus-5 -n HIMMEL-1001-leg load doc' \
  '9003:claude:--model claude-opus-5 -n HIMMEL-9003-consumeme load doc'
: > "$W/err.log"
after_b="$(run_pf "$slots_b" "$p3live" HIMMEL_FLEET_CAP=4)"
check "(b) informational read after the reserved leg goes live -> PROCEED" PROCEED "$after_b"
if grep -q 'FLEET native=3 claudex=0 reserved=0 total=3/4' "$W/err.log" 2>/dev/null; then
  PASS=$((PASS+1)); echo "ok - (b) live session consumes its own reservation (reserved=0, not double-counted)"
else
  FAIL=$((FAIL+1)); echo "FAIL - (b) reservation not consumed by the matching live session"; grep 'FLEET ' "$W/err.log" || true
fi

# --- (c) an expired reservation is pruned, not counted forever.
slots_c="$(mktemp -d "$W/slots-c.XXXXXX")" || { echo "FAIL - could not create slots-c scratch dir" >&2; exit 1; }
mkdir -p "$slots_c/HIMMEL-9004-expiredleg"
printf '%s\n' "$((NOW - 10))" > "$slots_c/HIMMEL-9004-expiredleg/expires"
printf '%s\n' "$$" > "$slots_c/HIMMEL-9004-expiredleg/pid"
: > "$W/err.log"
c_out="$(run_pf "$slots_c" "$p0" HIMMEL_FLEET_CAP=4)"
check "(c) expired reservation present, 0 live, cap 4 -> PROCEED" PROCEED "$c_out"
if grep -q 'FLEET native=0 claudex=0 reserved=0 total=0/4' "$W/err.log" 2>/dev/null; then
  PASS=$((PASS+1)); echo "ok - (c) expired reservation pruned from the count"
else
  FAIL=$((FAIL+1)); echo "FAIL - (c) expired reservation still counted"; grep 'FLEET ' "$W/err.log" || true
fi
if [ -d "$slots_c/HIMMEL-9004-expiredleg" ]; then
  FAIL=$((FAIL+1)); echo "FAIL - (c) expired reservation directory not removed from disk"
else
  PASS=$((PASS+1)); echo "ok - (c) expired reservation directory removed from disk"
fi

# --- (d) a stale .admit (mtime > FLEET_ADMIT_STALE_SECS) is reclaimed via
# rename-then-verify, not left to wedge every future call permanently.
slots_d="$(mktemp -d "$W/slots-d.XXXXXX")" || { echo "FAIL - could not create slots-d scratch dir" >&2; exit 1; }
mkdir -p "$slots_d/.admit"
printf '%s\n' "$((NOW - 61))" > "$slots_d/.admit/acquired"
: > "$W/err.log"
d_out="$(run_pf "$slots_d" "$p0" HIMMEL_FLEET_CAP=4)"
check "(d) stale .admit (61s old), 0 live, cap 4 -> PROCEED (reclaimed, not wedged)" PROCEED "$d_out"
if grep -q 'could not acquire the fleet admission lock' "$W/err.log" 2>/dev/null; then
  FAIL=$((FAIL+1)); echo "FAIL - (d) stale .admit was not reclaimed (lock-acquire failure logged)"
else
  PASS=$((PASS+1)); echo "ok - (d) stale .admit reclaimed without a lock-acquire failure"
fi
if [ -d "$slots_d/.admit" ]; then
  FAIL=$((FAIL+1)); echo "FAIL - (d) .admit left behind after the call completed"
else
  PASS=$((PASS+1)); echo "ok - (d) .admit released after the call completed"
fi

# --- (e) an informational run (no CADENCE_BANK_LAUNCH) counts reservations
# in the FLEET line but must never CREATE one of its own.
slots_e="$(mktemp -d "$W/slots-e.XXXXXX")" || { echo "FAIL - could not create slots-e scratch dir" >&2; exit 1; }
e_out="$(run_pf "$slots_e" "$p3" CADENCE_BANK_LEG=HIMMEL-9005-infoleg HIMMEL_FLEET_CAP=4)"
check "(e) informational read (no CADENCE_BANK_LAUNCH), 3 live, cap 4 -> PROCEED" PROCEED "$e_out"
# Portable count of reservation dirs (no find -mindepth/-maxdepth): the
# glob's default no-dotglob behaviour already excludes .admit, matching
# bank-preflight.sh's own `for … in "$SLOTS"/*/` census idiom (~line 299).
e_entries=0
for _e_dir in "$slots_e"/*/; do
  [ -d "$_e_dir" ] || continue
  e_entries=$((e_entries + 1))
done
check "(e) informational read creates no reservation directory" 0 "$e_entries"

# --- (f) a second declared launch of the SAME name is refused as a
# duplicate — with HEADROOM available (distinct from the at/over-cap
# refusal in case (a)), exercising the dedicated `mkdir $SLOTS/$LEG`
# duplicate-name branch specifically.
slots_f="$(mktemp -d "$W/slots-f.XXXXXX")" || { echo "FAIL - could not create slots-f scratch dir" >&2; exit 1; }
f_first="$(run_pf "$slots_f" "$p0" CADENCE_BANK_LAUNCH=1 CADENCE_BANK_LEG=HIMMEL-9006-dupleg HIMMEL_FLEET_CAP=4)"
check "(f) setup: first declared launch, 0 live, cap 4 -> PROCEED" PROCEED "$f_first"
: > "$W/err.log"
f_second="$(run_pf "$slots_f" "$p0" CADENCE_BANK_LAUNCH=1 CADENCE_BANK_LEG=HIMMEL-9006-dupleg HIMMEL_FLEET_CAP=4)"
check "(f) same-name second declared launch, well under cap -> SKIPPED-FLEET (duplicate)" SKIPPED-FLEET "$f_second"
if grep -q 'already exists — refusing as a duplicate declared launch' "$W/err.log" 2>/dev/null; then
  PASS=$((PASS+1)); echo "ok - (f) refused via the duplicate-reservation-name branch, not the at/over-cap branch"
else
  FAIL=$((FAIL+1)); echo "FAIL - (f) duplicate refusal did not name the duplicate-reservation reason"
fi

# --- (g) codex-5 (HIMMEL-2774, 2nd panel round): `mkdir "$SLOTS/$LEG"`
# failing does NOT mean "already exists" — a name exceeding the filesystem's
# per-component NAME_MAX (ENAMETOOLONG) reads identically to EEXIST unless
# distinguished, and misclassified a legitimate, unique launch as a refused
# duplicate. On the pre-fix script this is genuine RED: mkdir fails, the
# lone `else` branch assumes duplication and emits SKIPPED-FLEET with the
# "already exists" message even though `$SLOTS/$LEG` never existed. codex-3
# (4th panel round): the fix now retries under a bounded hashed key rather
# than proceeding with no reservation at all — still not misread as a
# duplicate, but now actually counted against the cap.
slots_g="$(mktemp -d "$W/slots-g.XXXXXX")" || { echo "FAIL - could not create slots-g scratch dir" >&2; exit 1; }
g_longleg="$(printf 'x%.0s' $(seq 1 300))"
: > "$W/err.log"
g_out="$(run_pf "$slots_g" "$p0" CADENCE_BANK_LAUNCH=1 CADENCE_BANK_LEG="$g_longleg" HIMMEL_FLEET_CAP=4)"
check "(g) mkdir fails on an over-length leg name (ENAMETOOLONG), 0 live, cap 4 -> PROCEED (not misread as a duplicate)" PROCEED "$g_out"
if grep -q 'already exists — refusing as a duplicate declared launch' "$W/err.log" 2>/dev/null; then
  FAIL=$((FAIL+1)); echo "FAIL - (g) ENAMETOOLONG was misreported as a duplicate reservation"
else
  PASS=$((PASS+1)); echo "ok - (g) ENAMETOOLONG not misreported as a duplicate reservation"
fi
if [ -e "$slots_g/$g_longleg" ]; then
  FAIL=$((FAIL+1)); echo "FAIL - (g) an over-length reservation dir should never exist on disk"
else
  PASS=$((PASS+1)); echo "ok - (g) no reservation directory left behind for the over-length name"
fi
# codex-3 (HIMMEL-2774, 4th panel round): ENAMETOOLONG no longer means
# "proceed without a reservation" — a bounded hash of the leg name is always
# a valid mkdir target, so this launch still gets counted against the cap.
g_hashkey="$(printf '%s' "$g_longleg" | cksum | awk '{print $1}')"
if [ -f "$slots_g/$g_hashkey/expires" ]; then
  PASS=$((PASS+1)); echo "ok - (g) reserves under a bounded hashed key instead of proceeding uncounted"
else
  FAIL=$((FAIL+1)); echo "FAIL - (g) no hashed-key reservation created for the over-length name"
fi

# --- (h) codex-1/codex-2 (HIMMEL-2774, 3rd panel round): a stale .admit
# (age past FLEET_ADMIT_STALE_SECS) whose recorded pid is still LIVE must
# never be reclaimed by age alone — reclaiming out from under a still-running
# holder loses mutual exclusion outright. Use the test's own $$ (guaranteed
# live for the duration of this call) as the "held" pid, and shrink the retry
# budget so the call fails fast instead of waiting out the default
# 100 x 0.05s window.
slots_h="$(mktemp -d "$W/slots-h.XXXXXX")" || { echo "FAIL - could not create slots-h scratch dir" >&2; exit 1; }
mkdir -p "$slots_h/.admit"
printf '%s\n' "$((NOW - 61))" > "$slots_h/.admit/acquired"
printf '%s\n' "$$" > "$slots_h/.admit/pid"
admit_before="$(cat "$slots_h/.admit/acquired") $(cat "$slots_h/.admit/pid")"
: > "$W/err.log"
h_out="$(run_pf "$slots_h" "$p0" CADENCE_BANK_LAUNCH=1 CADENCE_BANK_LEG=HIMMEL-9007-livepid HIMMEL_FLEET_CAP=4 FLEET_ADMIT_RETRY_ITERS=3 FLEET_ADMIT_RETRY_SLEEP=0.01)"
check "(h) stale .admit (61s old) held by a LIVE pid -> not reclaimed, SKIPPED-FLEET after retries" SKIPPED-FLEET "$h_out"
admit_after="$(cat "$slots_h/.admit/acquired" 2>/dev/null) $(cat "$slots_h/.admit/pid" 2>/dev/null)"
check "(h) .admit acquired/pid files untouched (no steal attempted against a live holder)" "$admit_before" "$admit_after"

# --- (i) / (i2) codex-5 (HIMMEL-2774, 3rd panel round): a transient failure
# of the IN-LOCK re-census (the second _fleet_census call, made after the
# pre-lock snapshot already succeeded) used to fall back to the pre-lock
# snapshot silently and admit on it. A ps stub that succeeds on its first
# invocation (the pre-lock census) and fails on its second (the in-lock
# re-census) reproduces exactly that gap.
mk_ps_fail_second_stub() {
  local dir="$1" cnt="$2"
  mkdir -p "$dir/proc"
  printf '0\n' > "$cnt"
  cat > "$dir/ps" <<STUB_EOF
#!/usr/bin/env bash
n=\$(cat '$cnt' 2>/dev/null || echo 0)
n=\$((n + 1))
printf '%s\n' "\$n" > '$cnt'
if [ "\$n" -ge 2 ]; then
  echo "stub: simulated ps failure on invocation \$n" >&2
  exit 1
fi
exit 0
STUB_EOF
  chmod +x "$dir/ps"
}

slots_i="$(mktemp -d "$W/slots-i.XXXXXX")" || { echo "FAIL - could not create slots-i scratch dir" >&2; exit 1; }
cnt_i="$W/ps-count-i"
pi="$W/ps-i"; mk_ps_fail_second_stub "$pi" "$cnt_i"
: > "$W/err.log"
i_out="$(run_pf "$slots_i" "$pi" CADENCE_BANK_LAUNCH=1 CADENCE_BANK_LEG=HIMMEL-9008-censusfail HIMMEL_FLEET_CAP=4)"
check "(i) in-lock census failure, 0 live, cap 4 -> SKIPPED-FLEET (refuses rather than admit on the stale pre-lock snapshot)" SKIPPED-FLEET "$i_out"
if grep -q 'in-lock fleet census failed' "$W/err.log" 2>/dev/null; then
  PASS=$((PASS+1)); echo "ok - (i) reports the in-lock-census-failed diagnosis"
else
  FAIL=$((FAIL+1)); echo "FAIL - (i) missing the in-lock-census-failed diagnosis"; grep 'bank-preflight' "$W/err.log" || true
fi
i_entries=0
for _i_dir in "$slots_i"/*/; do
  [ -d "$_i_dir" ] || continue
  [ "$(basename "$_i_dir")" = .admit ] && continue
  i_entries=$((i_entries + 1))
done
check "(i) no reservation created when the in-lock census fails" 0 "$i_entries"

# --- (i2) the same in-lock census failure, but with the documented
# FLEET_CAP_OK=1 bypass in effect -> must still PROCEED.
slots_i2="$(mktemp -d "$W/slots-i2.XXXXXX")" || { echo "FAIL - could not create slots-i2 scratch dir" >&2; exit 1; }
cnt_i2="$W/ps-count-i2"
pi2="$W/ps-i2"; mk_ps_fail_second_stub "$pi2" "$cnt_i2"
i2_out="$(run_pf "$slots_i2" "$pi2" CADENCE_BANK_LAUNCH=1 CADENCE_BANK_LEG=HIMMEL-9009-censusfailbypass HIMMEL_FLEET_CAP=4 FLEET_CAP_OK=1)"
check "(i2) in-lock census failure with FLEET_CAP_OK=1 -> PROCEED (bypass still applies)" PROCEED "$i2_out"

# --- (j) codex-7 (HIMMEL-2774, 3rd panel round): a leg name beginning with
# '.' is a valid `mkdir` target but invisible to the reservation census glob
# ("$SLOTS"/*/, no dotglob) — such a reservation would exist on disk yet
# never count against the cap. codex-3 (4th panel round): rather than
# proceeding with NO reservation (which reopened the over-admission race this
# mechanism exists to close), it is now reserved under a bounded hashed key —
# never the raw dot-prefixed name, so it stays invisible to the same glob
# for the right reason (it isn't stored there at all), while still counting
# against the cap and expiring by TTL.
slots_j="$(mktemp -d "$W/slots-j.XXXXXX")" || { echo "FAIL - could not create slots-j scratch dir" >&2; exit 1; }
: > "$W/err.log"
j_out="$(run_pf "$slots_j" "$p0" CADENCE_BANK_LAUNCH=1 CADENCE_BANK_LEG=.hidden-leg HIMMEL_FLEET_CAP=4)"
check "(j) dot-prefixed CADENCE_BANK_LEG, 0 live, cap 4 -> PROCEED (rejected, not reserved)" PROCEED "$j_out"
if [ -e "$slots_j/.hidden-leg" ]; then
  FAIL=$((FAIL+1)); echo "FAIL - (j) a dot-prefixed reservation dir should never exist on disk"
else
  PASS=$((PASS+1)); echo "ok - (j) no reservation directory left behind for the dot-prefixed name"
fi
# codex-3 (HIMMEL-2774, 4th panel round): a dot-prefixed name is likewise
# reserved under its bounded hash now, rather than proceeding uncounted.
j_hashkey="$(printf '%s' .hidden-leg | cksum | awk '{print $1}')"
if [ -f "$slots_j/$j_hashkey/expires" ]; then
  PASS=$((PASS+1)); echo "ok - (j) reserves under a bounded hashed key instead of proceeding uncounted"
else
  FAIL=$((FAIL+1)); echo "FAIL - (j) no hashed-key reservation created for the dot-prefixed name"
fi

# --- (k) CodeRabbit (PR #858, outside-diff): the `pid` write is what
# arm-resume.sh's release verifies ownership against, so a reservation whose
# pid write failed can never be released by its owner and lingers to its TTL
# (the HIMMEL-3017 failure shape). It is now gated like `expires`: refuse and
# clean up. The failure is injected with an exported `printf` function that
# fails only for the caller-pid line (the redirect still opens the file; the
# function's status is what the `&&` chain reads) and defers to the builtin
# for every other call.
slots_k="$(mktemp -d "$W/slots-k.XXXXXX")" || { echo "FAIL - could not create slots-k scratch dir" >&2; exit 1; }
: > "$W/err.log"
k_out="$(
  # shellcheck disable=SC2317,SC2059  # exported into run_pf's bash; shadows the builtin only inside this subshell
  printf() { if [ "${1:-}" = '%s\n' ] && [ "${2:-}" = 424242 ]; then return 1; fi; builtin printf "$@"; }
  export -f printf
  run_pf "$slots_k" "$p0" CADENCE_BANK_LAUNCH=1 CADENCE_BANK_LEG=HIMMEL-9020-pidwritefail HIMMEL_FLEET_CAP=4 CADENCE_BANK_CALLER_PID=424242
)"
check "(k) a failed pid write is a reservation failure -> SKIPPED-FLEET, not PROCEED" SKIPPED-FLEET "$k_out"
if [ -e "$slots_k/HIMMEL-9020-pidwritefail" ]; then
  FAIL=$((FAIL+1)); echo "FAIL - (k) a reservation with no pid was left behind (unreleasable until TTL)"
else
  PASS=$((PASS+1)); echo "ok - (k) no half-written reservation left behind"
fi
# Control: the SAME injection with a different caller pid must not trip the
# shim, so the case above fails for the pid write and not for the harness.
slots_k2="$(mktemp -d "$W/slots-k2.XXXXXX")" || { echo "FAIL - could not create slots-k2 scratch dir" >&2; exit 1; }
k2_out="$(
  # shellcheck disable=SC2317,SC2059  # exported into run_pf's bash; shadows the builtin only inside this subshell
  printf() { if [ "${1:-}" = '%s\n' ] && [ "${2:-}" = 424242 ]; then return 1; fi; builtin printf "$@"; }
  export -f printf
  run_pf "$slots_k2" "$p0" CADENCE_BANK_LAUNCH=1 CADENCE_BANK_LEG=HIMMEL-9020-pidwriteok HIMMEL_FLEET_CAP=4 CADENCE_BANK_CALLER_PID=424243
)"
check "(k) control: a different caller pid, same shim -> PROCEED" PROCEED "$k2_out"

# --- (l) HIMMEL-3012: a live session CONSUMES its reservation by NAME, but the
# reservation's directory name is not always the name the census sees — a name
# with a space (the census reads the first whitespace token of `-n`) and a
# name that cannot be one directory component ('/' or over NAME_MAX, so the
# key is a hash) never matched, and the slot was counted twice until the TTL.
# The reservation now also records the raw leg name in `name` and the consume
# check matches the live name against it too — but ONLY for a name with no
# whitespace, where the census's first token IS the whole name (exact identity).
# A name WITH whitespace is deliberately not consumed (see (l1)): the census
# cannot tell it from another leg sharing its first token.
count_resv() { local n=0 d; for d in "$1"/*/; do [ -d "$d" ] && n=$((n+1)); done; echo "$n"; }
# reserve_then_live <case> <leg> <live -n value> [counted]: reserve <leg> with
# no live session, then an informational read with one live `claude -n <live>`.
# Default: the live session must CONSUME the reservation. With `counted`: it
# must NOT — the reservation stays on disk and is counted alongside the live one.
reserve_then_live() {
  local label="$1" leg="$2" live="$3" mode="${4:-consumed}" slots pl out
  slots="$(mktemp -d "$W/slots-l.XXXXXX")" || { echo "FAIL - could not create slots-l scratch dir" >&2; exit 1; }
  out="$(run_pf "$slots" "$p0" CADENCE_BANK_LAUNCH=1 CADENCE_BANK_LEG="$leg" HIMMEL_FLEET_CAP=4)"
  check "($label) setup: declared launch -> PROCEED, reservation created" PROCEED "$out"
  check "($label) reservation records the raw leg name" "$leg" "$(cat "$slots"/*/name 2>/dev/null)"
  pl="$(mktemp -d "$W/ps-l.XXXXXX")"; mk_ps_stub "$pl" "9001:claude:--model claude-opus-5 -n $live load doc"
  : > "$W/err.log"
  run_pf "$slots" "$pl" HIMMEL_FLEET_CAP=4 >/dev/null
  if [ "$mode" = counted ]; then
    if grep -q 'FLEET native=1 claudex=0 reserved=1 total=2/4' "$W/err.log" 2>/dev/null; then
      PASS=$((PASS+1)); echo "ok - ($label) whitespace-name reservation NOT consumed by a first-token match (reserved=1, over-counts to the TTL)"
    else
      FAIL=$((FAIL+1)); echo "FAIL - ($label) whitespace-name reservation was consumed by a first-token match"; grep 'FLEET ' "$W/err.log" || true
    fi
    check "($label) unconsumed reservation directory stays on disk" 1 "$(count_resv "$slots")"
    return 0
  fi
  if grep -q 'FLEET native=1 claudex=0 reserved=0 total=1/4' "$W/err.log" 2>/dev/null; then
    PASS=$((PASS+1)); echo "ok - ($label) live session consumes the reservation (reserved=0, not double-counted)"
  else
    FAIL=$((FAIL+1)); echo "FAIL - ($label) reservation not consumed by the matching live session"; grep 'FLEET ' "$W/err.log" || true
  fi
  check "($label) consumed reservation directory removed from disk" 0 "$(count_resv "$slots")"
}
# A name with whitespace is a documented over-count, not a fix: the census only
# exposes the first token, which two different legs can share.
reserve_then_live "l1 space in name (documented over-count)" "HIMMEL-9500-foo bar" "HIMMEL-9500-foo bar" counted
reserve_then_live "l2 slash in name (hashed key)" "HIMMEL-9501/x" "HIMMEL-9501/x"
l3_long="HIMMEL-9502-$(printf 'x%.0s' $(seq 1 300))"
reserve_then_live "l3 over NAME_MAX (hashed key)" "$l3_long" "$l3_long"
# Control: the plain same-name shape (b) still consumes — it must stay green.
reserve_then_live "l0 control same name" "HIMMEL-9503-plain" "HIMMEL-9503-plain"

# --- (m) a reservation written by the OLD code has no `name` file, and legs
# launched from older worktrees share $SLOTS — it must still be consumed by
# the directory-name match.
slots_m="$(mktemp -d "$W/slots-m.XXXXXX")" || { echo "FAIL - could not create slots-m scratch dir" >&2; exit 1; }
mkdir -p "$slots_m/HIMMEL-9504-oldcode"
printf '%s\n' "$((NOW + 600))" > "$slots_m/HIMMEL-9504-oldcode/expires"
printf '%s\n' "$$" > "$slots_m/HIMMEL-9504-oldcode/pid"
pm="$W/ps-m"; mk_ps_stub "$pm" '9001:claude:--model claude-opus-5 -n HIMMEL-9504-oldcode load doc'
: > "$W/err.log"
run_pf "$slots_m" "$pm" HIMMEL_FLEET_CAP=4 >/dev/null
if grep -q 'FLEET native=1 claudex=0 reserved=0 total=1/4' "$W/err.log" 2>/dev/null; then
  PASS=$((PASS+1)); echo "ok - (m) a name-file-less (old-code) reservation is still consumed by the dir-name match"
else
  FAIL=$((FAIL+1)); echo "FAIL - (m) old-code reservation not consumed"; grep 'FLEET ' "$W/err.log" || true
fi
check "(m) consumed old-code reservation removed from disk" 0 "$(count_resv "$slots_m")"

# --- (n) the `name` file changes nothing about pruning or the census glob: a
# STALE reservation that has one is still pruned (and not counted), and a live
# reservation that has one and matches no live session still counts once.
slots_n="$(mktemp -d "$W/slots-n.XXXXXX")" || { echo "FAIL - could not create slots-n scratch dir" >&2; exit 1; }
mkdir -p "$slots_n/HIMMEL-9505-stale" "$slots_n/HIMMEL-9506-fresh"
printf '%s\n' "$((NOW - 10))" > "$slots_n/HIMMEL-9505-stale/expires"; printf '%s\n' "$$" > "$slots_n/HIMMEL-9505-stale/pid"
printf '%s\n' "HIMMEL-9505-stale" > "$slots_n/HIMMEL-9505-stale/name"
printf '%s\n' "$((NOW + 600))" > "$slots_n/HIMMEL-9506-fresh/expires"; printf '%s\n' "$$" > "$slots_n/HIMMEL-9506-fresh/pid"
printf '%s\n' "HIMMEL-9506-fresh" > "$slots_n/HIMMEL-9506-fresh/name"
: > "$W/err.log"
run_pf "$slots_n" "$p0" HIMMEL_FLEET_CAP=4 >/dev/null
if grep -q 'FLEET native=0 claudex=0 reserved=1 total=1/4' "$W/err.log" 2>/dev/null; then
  PASS=$((PASS+1)); echo "ok - (n) stale reservation with a name file pruned, unmatched live one counted once"
else
  FAIL=$((FAIL+1)); echo "FAIL - (n) prune/count changed by the name file"; grep 'FLEET ' "$W/err.log" || true
fi
if [ -e "$slots_n/HIMMEL-9505-stale" ]; then
  FAIL=$((FAIL+1)); echo "FAIL - (n) stale reservation with a name file was not removed from disk"
else
  PASS=$((PASS+1)); echo "ok - (n) stale reservation with a name file removed from disk"
fi
check "(n) unmatched unexpired reservation with a name file stays on disk" 1 "$(count_resv "$slots_n")"

# --- (o) a first token carried by TWO pending reservations is ambiguous: one
# live `-n HIMMEL-9507-shared` names neither "HIMMEL-9507-shared a" nor "... b",
# so it consumes NEITHER — whitespace names are never consumed by the name-file
# match; the census may over-count but must never under-count. Stateless, so it
# must hold on every later preflight too (a consume-one-per-run rule eats the
# sibling on the second run). Regression for the panel's first-token class.
slots_o="$(mktemp -d "$W/slots-o.XXXXXX")" || { echo "FAIL - could not create slots-o scratch dir" >&2; exit 1; }
for sfx in a b; do
  mkdir -p "$slots_o/HIMMEL-9507-shared_$sfx"
  printf '%s\n' "$((NOW + 600))" > "$slots_o/HIMMEL-9507-shared_$sfx/expires"
  printf '%s\n' "$$" > "$slots_o/HIMMEL-9507-shared_$sfx/pid"
  printf '%s\n' "HIMMEL-9507-shared $sfx" > "$slots_o/HIMMEL-9507-shared_$sfx/name"
done
po="$W/ps-o"; mk_ps_stub "$po" '9001:claude:--model claude-opus-5 -n HIMMEL-9507-shared load doc'
for o_run in first second; do
  : > "$W/err.log"
  run_pf "$slots_o" "$po" HIMMEL_FLEET_CAP=4 >/dev/null
  if grep -q 'FLEET native=1 claudex=0 reserved=2 total=3/4' "$W/err.log" 2>/dev/null; then
    PASS=$((PASS+1)); echo "ok - (o) $o_run preflight: ambiguous first token consumes neither reservation (reserved=2, total=3)"
  else
    FAIL=$((FAIL+1)); echo "FAIL - (o) $o_run preflight: an ambiguous first token consumed a reservation"; grep 'FLEET ' "$W/err.log" || true
  fi
  check "(o) $o_run preflight: both same-first-token reservations stay on disk" 2 "$(count_resv "$slots_o")"
done

# --- (p) HIMMEL-3216: the census used to expose only the FIRST whitespace token
# of a live `-n` value, so a reservation keyed on that token was consumed by a
# DIFFERENT live leg sharing it. Where /proc/<pid>/cmdline is readable the census
# now reads the exact argv element after `-n`, and consumption compares the FULL
# name. mk_argv_stub writes BOTH views a real box has: the ps line (argv joined
# by spaces, control characters shown as `?` like ps does) and the NUL-separated
# cmdline. The suites above build ps-only stubs (no cmdline file) — that is the
# fallback path (no procfs), still first-token, and stays covered by (b)/(l)/(m)/(o).
mk_argv_stub() { # <dir> <pid> <ps-visible -n value> <exact -n value>
  local dir="$1" pid="$2" shown="$3" exact="$4"
  mkdir -p "$dir/proc/$pid"
  printf '%s' claude > "$dir/proc/$pid/comm"
  printf '%s %s\n' "$pid" "--model claude-opus-5 -n $shown load doc" > "$dir/ps.data"
  printf '%s\0' claude --model claude-opus-5 -n "$exact" load doc > "$dir/proc/$pid/cmdline"
  printf '%s\n' '#!/usr/bin/env bash' "cat '$dir/ps.data'" > "$dir/ps"
  chmod +x "$dir/ps"
}
# p_live <slots> <ps-visible> <exact>: informational read with one live session.
p_live() {
  local pp
  pp="$(mktemp -d "$W/ps-p.XXXXXX")" || { echo "FAIL - could not create ps-p scratch dir" >&2; exit 1; }
  mk_argv_stub "$pp" 9001 "$2" "$3"
  : > "$W/err.log"
  run_pf "$1" "$pp" HIMMEL_FLEET_CAP=4 >/dev/null
}
p_expect() { # <label> <slots> consumed|kept
  if [ "$3" = kept ]; then
    if grep -q 'FLEET native=1 claudex=0 reserved=1 total=2/4' "$W/err.log" 2>/dev/null; then
      PASS=$((PASS+1)); echo "ok - ($1) not consumed by a different live full name (reserved=1)"
    else
      FAIL=$((FAIL+1)); echo "FAIL - ($1) reservation consumed by a live session with a different full name"; grep 'FLEET ' "$W/err.log" || true
    fi
    check "($1) unconsumed reservation stays on disk" 1 "$(count_resv "$2")"
  else
    if grep -q 'FLEET native=1 claudex=0 reserved=0 total=1/4' "$W/err.log" 2>/dev/null; then
      PASS=$((PASS+1)); echo "ok - ($1) consumed by the live session with the identical full name (reserved=0)"
    else
      FAIL=$((FAIL+1)); echo "FAIL - ($1) not consumed by the identical live full name"; grep 'FLEET ' "$W/err.log" || true
    fi
    check "($1) consumed reservation removed from disk" 0 "$(count_resv "$2")"
  fi
}
# p_case <label> <leg> <ps-visible live> <exact live> consumed|kept
p_case() {
  local slots out
  slots="$(mktemp -d "$W/slots-p.XXXXXX")" || { echo "FAIL - could not create slots-p scratch dir" >&2; exit 1; }
  out="$(run_pf "$slots" "$p0" CADENCE_BANK_LAUNCH=1 CADENCE_BANK_LEG="$2" HIMMEL_FLEET_CAP=4)"
  check "($1) setup: declared launch -> PROCEED, reservation created" PROCEED "$out"
  p_live "$slots" "$3" "$4"
  p_expect "$1" "$slots" "$5"
}
# p1: the plain-name shape the ticket names (pre-#920 too): a live
# `-n "HIMMEL-9600 anything"` shares the first token with a HIMMEL-9600 reservation.
p_case "p1 plain reservation, live shares the first token" "HIMMEL-9600" "HIMMEL-9600 anything" "HIMMEL-9600 anything" kept
# p2: a hashed-key (slash) name, live `-n "<name> other"`.
p_case "p2 slash reservation, live shares the first token" "HIMMEL-9601/x" "HIMMEL-9601/x other" "HIMMEL-9601/x other" kept
# p3: a whitespace name is now exact — consumed by the identical full name.
p_case "p3 whitespace reservation, identical live full name" "HIMMEL-9602-foo bar" "HIMMEL-9602-foo bar" "HIMMEL-9602-foo bar" consumed
# p4 control: the plain same-name shape still consumes with a cmdline present.
p_case "p4 control same name, cmdline present" "HIMMEL-9603-plain" "HIMMEL-9603-plain" "HIMMEL-9603-plain" consumed
# p5 guards: a live name with a control character is never a list entry, so it
# can neither be stripped down to a plain name (a trailing newline lost to `$(...)`)
# nor forge a second line that consumes another leg's reservation.
p5a_nl=$'\n'
p_case "p5a live name with a trailing newline" "HIMMEL-9604-x" "HIMMEL-9604-x?" "HIMMEL-9604-x$p5a_nl" kept
p5b_exact="$(printf 'HIMMEL-9605-a\nHIMMEL-9606-b')"
p_case "p5b live name embedding a second line" "HIMMEL-9606-b" "HIMMEL-9605-a?HIMMEL-9606-b" "$p5b_exact" kept

# p6: a reservation name with a newline or any control character is refused at
# reserve time — the name file is read as one line, so it could otherwise forge
# an identity ("foo/bar<LF>other" read as "foo/bar").
for p6 in "$(printf 'HIMMEL-9607/x\nother')" "$(printf 'HIMMEL-9608\tx')" "$(printf 'HIMMEL-9609\rx')"; do
  slots_p6="$(mktemp -d "$W/slots-p6.XXXXXX")" || { echo "FAIL - could not create slots-p6 scratch dir" >&2; exit 1; }
  : > "$W/ledger.jsonl"
  p6_out="$(run_pf "$slots_p6" "$p0" CADENCE_BANK_LAUNCH=1 CADENCE_BANK_LEG="$p6" HIMMEL_FLEET_CAP=4)"
  check "(p6) a control character in the leg name -> SKIPPED-FLEET, not PROCEED" SKIPPED-FLEET "$p6_out"
  check "(p6) no reservation left behind for a control-character name" 0 "$(count_resv "$slots_p6")"
  # The refusal is recorded in the JSONL ledger: the rejected name must not split
  # the record (newline) or put a raw control character inside the JSON string.
  check "(p6) the ledger gets exactly one record for the refused name" 1 "$(grep -c '' "$W/ledger.jsonl")"
  check "(p6) the ledger record carries no raw control character" 0 "$(tr -d '\n' < "$W/ledger.jsonl" | tr -cd '[:cntrl:]' | wc -c | tr -d ' ')"
done
# p6b: same class, no control character — a quote or backslash in the leg name
# must be escaped in the ledger record, not close the JSON string early.
slots_p6b="$(mktemp -d "$W/slots-p6b.XXXXXX")" || { echo "FAIL - could not create slots-p6b scratch dir" >&2; exit 1; }
: > "$W/ledger.jsonl"
run_pf "$slots_p6b" "$p0" CADENCE_BANK_LAUNCH=1 CADENCE_BANK_LEG='HIMMEL-9611"x\y' HIMMEL_FLEET_CAP=4 >/dev/null
check "(p6b) a quote/backslash in the leg name is escaped in the ledger record" 1 "$(grep -cF 'HIMMEL-9611\"x\\y' "$W/ledger.jsonl")"
# p7: a PRE-EXISTING (forged / older-copy) name file whose second line differs
# is not read as its first line: it must not consume the live `HIMMEL-9610/x`.
slots_p7="$(mktemp -d "$W/slots-p7.XXXXXX")" || { echo "FAIL - could not create slots-p7 scratch dir" >&2; exit 1; }
mkdir -p "$slots_p7/4242"
printf '%s\n' "$((NOW + 600))" > "$slots_p7/4242/expires"; printf '%s\n' "$$" > "$slots_p7/4242/pid"
printf '%s\n%s\n' "HIMMEL-9610/x" "other" > "$slots_p7/4242/name"
p_live "$slots_p7" "HIMMEL-9610/x" "HIMMEL-9610/x"
p_expect "p7 multi-line name file" "$slots_p7" kept
# p7b: extra trailing blank lines in a name file must not be normalised away
# ($(cat) strips ALL trailing newlines): only the single LF the writer emits is
# part of the file format, anything more is a multi-line identity.
slots_p7b="$(mktemp -d "$W/slots-p7b.XXXXXX")" || { echo "FAIL - could not create slots-p7b scratch dir" >&2; exit 1; }
mkdir -p "$slots_p7b/4243"
printf '%s\n' "$((NOW + 600))" > "$slots_p7b/4243/expires"; printf '%s\n' "$$" > "$slots_p7b/4243/pid"
printf '%s\n\n' "HIMMEL-9611-x" > "$slots_p7b/4243/name"
p_live "$slots_p7b" "HIMMEL-9611-x" "HIMMEL-9611-x"
p_expect "p7b name file with extra trailing blank lines" "$slots_p7b" kept
# p7c: a NUL byte in a name file is not a complete identity — `read -d ''`
# stops at it, so the prefix must not be accepted as the whole name.
slots_p7c="$(mktemp -d "$W/slots-p7c.XXXXXX")" || { echo "FAIL - could not create slots-p7c scratch dir" >&2; exit 1; }
mkdir -p "$slots_p7c/4244"
printf '%s\n' "$((NOW + 600))" > "$slots_p7c/4244/expires"; printf '%s\n' "$$" > "$slots_p7c/4244/pid"
printf 'HIMMEL-9612-x\0other\n' > "$slots_p7c/4244/name"
p_live "$slots_p7c" "HIMMEL-9612-x" "HIMMEL-9612-x"
p_expect "p7c name file with an embedded NUL" "$slots_p7c" kept
# p8: the reservation DIRECTORY name is an identity too. `$(basename)` strips a
# trailing newline ("HIMMEL-9613-x<LF>" -> "HIMMEL-9613-x") and a multi-line
# name handed to `grep -F` is a LIST of patterns, so either shape would consume
# a plain live name. A control-character directory name matches nothing.
p8_i=0
for p8 in $'HIMMEL-9613-x\n' $'HIMMEL-9614-y\nHIMMEL-9615-z'; do
  p8_i=$((p8_i + 1))
  slots_p8="$(mktemp -d "$W/slots-p8.XXXXXX")" || { echo "FAIL - could not create slots-p8 scratch dir" >&2; exit 1; }
  mkdir -p "$slots_p8/$p8"
  printf '%s\n' "$((NOW + 600))" > "$slots_p8/$p8/expires"; printf '%s\n' "$$" > "$slots_p8/$p8/pid"
  case $p8_i in
    1) p_live "$slots_p8" "HIMMEL-9613-x" "HIMMEL-9613-x" ;;
    2) p_live "$slots_p8" "HIMMEL-9615-z" "HIMMEL-9615-z" ;;
  esac
  p_expect "p8.$p8_i reservation directory name with a newline" "$slots_p8" kept
done

# --- (q) HIMMEL-3095: a leg that has WRAPPED (queue lock released, last
# status bullet WRAPPED) but whose process is still alive no longer counts
# against FLEET_CAP. mk_wrapped_stub builds the cmdline shape
# leg-claude-launcher.sh always uses (`load <DOC> and continue` as ONE argv
# element after `-n <name>`) so fleet_doc_for_pid resolves the doc without a
# glob; ql_stub writes a fake queue-lock.sh reporting free/held on demand.
# RED first (pre-fix): every case below reports native=1 — the unfixed
# census has no notion of WRAPPED at all.
mk_wrapped_stub() { # <dir> <pid> <name> <doc>
  local dir="$1" pid="$2" name="$3" doc="$4"
  mkdir -p "$dir/proc/$pid"
  printf '%s' claude > "$dir/proc/$pid/comm"
  printf '%s %s\n' "$pid" "--model claude-opus-5 -n $name load doc" > "$dir/ps.data"
  printf '%s\n' '#!/usr/bin/env bash' "cat '$dir/ps.data'" > "$dir/ps"
  chmod +x "$dir/ps"
  printf 'claude\0--model\0claude-opus-5\0-n\0%s\0load %s and continue\0' "$name" "$doc" > "$dir/proc/$pid/cmdline"
}
ql_stub() { # <path> free|held -- writes a fake queue-lock.sh at <path>
  case "$2" in
    free) printf '%s\n' '#!/usr/bin/env bash' 'echo free' > "$1" ;;
    held) printf '%s\n' '#!/usr/bin/env bash' 'echo "status: FRESH"' 'exit 11' > "$1" ;;
  esac
  chmod +x "$1"
}
q_run() { # <label> <doc-body> <lock-state> <expect: 0|1 native count>
  local label="$1" body="$2" lock="$3" expect="$4"
  local qdir="$W/q-$label"; mkdir -p "$qdir"
  local doc="$qdir/doc.md" ql="$qdir/queue-lock.sh"
  printf '%s\n' "$body" > "$doc"
  ql_stub "$ql" "$lock"
  local pdir="$W/q-$label-ps"
  mk_wrapped_stub "$pdir" 9701 "HIMMEL-9701-wrapped" "$doc"
  local slots; slots="$(mktemp -d "$W/q-$label-slots.XXXXXX")" || { echo "FAIL - could not create q-$label slots dir" >&2; exit 1; }
  : > "$W/err.log"
  run_pf "$slots" "$pdir" HIMMEL_FLEET_CAP=4 FLEET_QUEUE_LOCK="$ql" >/dev/null
  check "(q.$label) fleet_native" "$expect" "$(grep -oE 'native=[0-9]+' "$W/err.log" | head -1 | cut -d= -f2)"
}
q_run wrapped-free "- 10:00 WRAPPED — done." free 0
q_run held-not-wrapped "- 10:00 WRAPPED — done." held 1
q_run free-not-wrapped "- 10:00 READY — holding for GO." free 1
q_run no-status-bullet "- 10:00 some note with no marker." free 1

echo "--- $PASS passed, $FAIL failed ---"
[ "$FAIL" -eq 0 ]
