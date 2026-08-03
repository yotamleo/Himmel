#!/usr/bin/env bash
# Unit tests for scripts/lib/render-lease.sh (HIMMEL-1509). Hermetic: the
# registry lives in a mktemp dir and the proc-tree identity primitives are
# stubbed, so no real process is probed or signaled and no shared state is
# touched. Launcher integration is covered by
# scripts/cr/test-run-codex-adversarial.sh.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/himmel-render-lease.XXXXXX")"
fails=0

cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

check() {
    if [ "$2" = "$3" ]; then
        echo "ok - $1"
    else
        echo "FAIL - $1: got [$2] want [$3]"
        fails=$((fails + 1))
    fi
}

# Stub proc-tree primitives BEFORE sourcing the lib (it requires them sourced
# first). Liveness: the current shell and one magic pid are alive, everything
# else is confirmed dead. Identity: driven by STUB_IDENTITY_RC.
STUB_IDENTITY_RC=1
proc_tree_process_alive() {
    [ "$1" = "$$" ] && return 0
    [ "$1" = "424242" ] && return 0
    return 1
}
proc_tree_process_identity_matches() {
    return "$STUB_IDENTITY_RC"
}

# shellcheck source=render-lease.sh
# shellcheck disable=SC1091
. "$HERE/render-lease.sh"

export RENDER_LEASE_LOCK_ATTEMPTS=2
export RENDER_LEASE_LOCK_DELAY_SECS=0

# --- slug + dir mapping (r6: INJECTIVE +HH byte encoding) ---------------------
check "slash branch slugs to +2F" "$(render_lease_slug 'feat/himmel-1509-x')" "feat+2Fhimmel-1509-x"
check "hostile chars hex-encode per byte" "$(render_lease_slug 'a b!c')" "a+20b+21c"
check "literal plus escapes the escape" "$(render_lease_slug 'feat/a+b')" "feat+2Fa+2Bb"
check "aliasing branches stay distinct" "$(render_lease_slug 'feat/a/b')" "feat+2Fa+2Fb"
check "slug map is deterministic" "$(render_lease_slug 'feat/a+b')" "$(render_lease_slug 'feat/a+b')"
rc=0; render_lease_dir_for '' >/dev/null 2>&1 || rc=$?
check "empty branch has no lease dir" "$rc" "1"
rc=0; render_lease_dir_for '.' >/dev/null 2>&1 || rc=$?
check "dot branch has no lease dir" "$rc" "1"

# --- claim / probe / bind / release lifecycle ---------------------------------
export RENDER_LEASE_DIR="$tmp/reg-lifecycle"
rc=0; render_lease_claim 'feat/leg' "$tmp/wt" 2>/dev/null || rc=$?
check "fresh claim acquires" "$rc" "0"
lease_dir="$RENDER_LEASE_DIR/feat+2Fleg"
check "claim writes branch field" "$(render_lease_field "$lease_dir" branch)" "feat/leg"
check "claim writes worktree field" "$(render_lease_field "$lease_dir" worktree)" "$tmp/wt"
check "claim records launching status" "$(render_lease_field "$lease_dir" status)" "launching"
check "claim releases the registry lock" "$(test -e "$RENDER_LEASE_DIR/.registry.lock" && echo held || echo released)" "released"

rc=0; render_lease_probe 'feat/leg' || rc=$?
check "probe sees the fresh lease as held" "$rc" "1"
rc=0; render_lease_claim 'feat/leg' "$tmp/wt" 2>/dev/null || rc=$?
check "second claim on a fresh lease refuses" "$rc" "1"
check "refused claim leaves the record intact" "$(render_lease_field "$lease_dir" status)" "launching"

started_before=$(render_lease_field "$lease_dir" started_at)
rc=0; render_lease_bind 'feat/leg' 4242 5252 'win:5252:637000000000000000' || rc=$?
check "bind succeeds on a held lease" "$rc" "0"
check "bind records running status" "$(render_lease_field "$lease_dir" status)" "running"
check "bind records leader pid" "$(render_lease_field "$lease_dir" leader_pid)" "4242"
check "bind records leader winpid" "$(render_lease_field "$lease_dir" leader_winpid)" "5252"
check "bind records leader identity" "$(render_lease_field "$lease_dir" leader_identity)" "win:5252:637000000000000000"
check "bind preserves started_at" "$(render_lease_field "$lease_dir" started_at)" "$started_before"

render_lease_release 'feat/leg'
check "release removes the lease dir" "$(test -e "$lease_dir" && echo present || echo gone)" "gone"
rc=0; render_lease_probe 'feat/leg' || rc=$?
check "probe after release reports free" "$rc" "0"
rc=0; render_lease_bind 'feat/leg' 1 2 x 2>/dev/null || rc=$?
check "bind without a held lease fails" "$rc" "1"

# --- staleness adjudication (fail-closed: only CONFIRMED dead is reclaimed) ---
make_stale_lease() {
    # <registry> <slug> <leader_pid> <leader_identity>
    local dir="$1/$2"
    mkdir -p "$dir"
    printf 'branch\tfeat/stale\nworktree\t%s\nacquired_by\t999999\nstarted_at\t2020-01-01T00:00:00Z\nleader_pid\t%s\nleader_winpid\t\nleader_identity\t%s\nstatus\trunning\n' \
        "$tmp/wt" "$3" "$4" > "$dir/lease.record"
    touch -t 202001010000 "$dir/lease.record"
}

export RENDER_LEASE_DIR="$tmp/reg-stale-dead"
make_stale_lease "$RENDER_LEASE_DIR" feat+2Fstale 999999 'win:999999:1'
STUB_IDENTITY_RC=1
rc=0; render_lease_probe 'feat/stale' || rc=$?
check "probe reports a confirmed-dead stale lease free" "$rc" "0"
rc=0; render_lease_claim 'feat/stale' "$tmp/wt" 2>"$tmp/reclaim.stderr" || rc=$?
check "claim reclaims a confirmed-dead stale lease" "$rc" "0"
check "reclaim announces itself" "$(grep -Fc 'reclaiming stale lease' "$tmp/reclaim.stderr" 2>/dev/null)" "1"
check "reclaimed lease has a fresh record" "$(render_lease_field "$RENDER_LEASE_DIR/feat+2Fstale" status)" "launching"

export RENDER_LEASE_DIR="$tmp/reg-stale-unverifiable"
make_stale_lease "$RENDER_LEASE_DIR" feat+2Fstale 999999 'win:999999:1'
STUB_IDENTITY_RC=2
rc=0; render_lease_probe 'feat/stale' || rc=$?
check "probe treats an unverifiable holder as held" "$rc" "1"
rc=0; render_lease_claim 'feat/stale' "$tmp/wt" 2>/dev/null || rc=$?
check "claim refuses an unverifiable holder" "$rc" "1"
check "unverifiable lease record is preserved" "$(render_lease_field "$RENDER_LEASE_DIR/feat+2Fstale" status)" "running"

export RENDER_LEASE_DIR="$tmp/reg-stale-live"
make_stale_lease "$RENDER_LEASE_DIR" feat+2Fstale 999999 'win:999999:1'
STUB_IDENTITY_RC=0
rc=0; render_lease_claim 'feat/stale' "$tmp/wt" 2>/dev/null || rc=$?
check "claim refuses a live-leader stale-heartbeat lease" "$rc" "1"
STUB_IDENTITY_RC=1

# Launching-phase record: no leader anchor yet, wrapper pid is the authority.
export RENDER_LEASE_DIR="$tmp/reg-launching"
mkdir -p "$RENDER_LEASE_DIR/feat+2Fyoung"
printf 'branch\tfeat/young\nworktree\t%s\nacquired_by\t999999\nstarted_at\t2020-01-01T00:00:00Z\nleader_pid\t\nleader_winpid\t\nleader_identity\t\nstatus\tlaunching\n' \
    "$tmp/wt" > "$RENDER_LEASE_DIR/feat+2Fyoung/lease.record"
touch -t 202001010000 "$RENDER_LEASE_DIR/feat+2Fyoung/lease.record"
rc=0; render_lease_probe 'feat/young' || rc=$?
check "stale launching record with dead wrapper is free" "$rc" "0"
mkdir -p "$RENDER_LEASE_DIR/feat+2Falive"
printf 'branch\tfeat/alive\nworktree\t%s\nacquired_by\t424242\nstarted_at\t2020-01-01T00:00:00Z\nleader_pid\t\nleader_winpid\t\nleader_identity\t\nstatus\tlaunching\n' \
    "$tmp/wt" > "$RENDER_LEASE_DIR/feat+2Falive/lease.record"
touch -t 202001010000 "$RENDER_LEASE_DIR/feat+2Falive/lease.record"
rc=0; render_lease_probe 'feat/alive' || rc=$?
check "stale launching record with live wrapper stays held" "$rc" "1"

# --- heartbeat freshness ------------------------------------------------------
mkdir -p "$tmp/hb-lease"
printf 'x' > "$tmp/hb-lease/heartbeat"
rc=0; render_lease_heartbeat_fresh "$tmp/hb-lease" 600 || rc=$?
check "just-written heartbeat is fresh" "$rc" "0"
touch -t 202001010000 "$tmp/hb-lease/heartbeat"
rc=0; render_lease_heartbeat_fresh "$tmp/hb-lease" 600 || rc=$?
check "2020 heartbeat is stale" "$rc" "1"

# --- registry failure + lock behavior (fail-closed) ---------------------------
printf 'not a dir' > "$tmp/blocker"
export RENDER_LEASE_DIR="$tmp/blocker/reg"
rc=0; render_lease_claim 'feat/x' "$tmp/wt" 2>/dev/null || rc=$?
check "unusable registry refuses with rc 2" "$rc" "2"

export RENDER_LEASE_DIR="$tmp/reg-lock-held"
mkdir -p "$RENDER_LEASE_DIR/.registry.lock"
printf 'msys:%s\n' "$$" > "$RENDER_LEASE_DIR/.registry.lock/owner.pid"
rc=0; render_lease_claim 'feat/x' "$tmp/wt" 2>/dev/null || rc=$?
check "live-owner lock contention refuses with rc 1" "$rc" "1"
check "contended lock is preserved" "$(test -d "$RENDER_LEASE_DIR/.registry.lock" && echo held || echo broken)" "held"

export RENDER_LEASE_DIR="$tmp/reg-lock-dead"
mkdir -p "$RENDER_LEASE_DIR/.registry.lock"
printf 'msys:999999\n' > "$RENDER_LEASE_DIR/.registry.lock/owner.pid"
rc=0; render_lease_claim 'feat/x' "$tmp/wt" 2>"$tmp/lock-dead.stderr" || rc=$?
check "dead-owner lock is broken and claim proceeds" "$rc" "0"
check "dead-owner break names its disposition" "$(grep -Fc 'confirmed-dead owner' "$tmp/lock-dead.stderr" 2>/dev/null)" "1"

export RENDER_LEASE_DIR="$tmp/reg-lock-foreign"
mkdir -p "$RENDER_LEASE_DIR/.registry.lock"
printf 'win:12345\n' > "$RENDER_LEASE_DIR/.registry.lock/owner.pid"
rc=0; render_lease_claim 'feat/x' "$tmp/wt" 2>/dev/null || rc=$?
check "fresh cross-space lock is never pid-broken" "$rc" "1"

# --- r4 stale-break disposition (verified-live owner is NEVER age-broken) -----
export RENDER_LEASE_DIR="$tmp/reg-lock-live-aged"
mkdir -p "$RENDER_LEASE_DIR/.registry.lock"
printf 'msys:%s\n' "$$" > "$RENDER_LEASE_DIR/.registry.lock/owner.pid"
touch -t 202001010000 "$RENDER_LEASE_DIR/.registry.lock"
rc=0; render_lease_claim 'feat/x' "$tmp/wt" 2>/dev/null || rc=$?
check "aged lock with verified-live owner refuses, never breaks" "$rc" "1"
check "verified-live owner's aged lock is preserved" "$(test -d "$RENDER_LEASE_DIR/.registry.lock" && echo held || echo broken)" "held"

export RENDER_LEASE_DIR="$tmp/reg-lock-foreign-aged"
mkdir -p "$RENDER_LEASE_DIR/.registry.lock"
printf 'win:12345\n' > "$RENDER_LEASE_DIR/.registry.lock/owner.pid"
touch -t 202001010000 "$RENDER_LEASE_DIR/.registry.lock"
rc=0; render_lease_claim 'feat/x' "$tmp/wt" 2>"$tmp/lock-foreign-aged.stderr" || rc=$?
check "aged cross-space lock is age-broken and claim proceeds" "$rc" "0"
check "cross-space age-break names its disposition" "$(grep -Fc 'age-breaking registry lock' "$tmp/lock-foreign-aged.stderr" 2>/dev/null)" "1"

export RENDER_LEASE_DIR="$tmp/reg-lock-unverifiable-aged"
mkdir -p "$RENDER_LEASE_DIR/.registry.lock"
printf 'msys:not-a-pid\n' > "$RENDER_LEASE_DIR/.registry.lock/owner.pid"
touch -t 202001010000 "$RENDER_LEASE_DIR/.registry.lock"
rc=0; render_lease_claim 'feat/x' "$tmp/wt" 2>/dev/null || rc=$?
check "aged unverifiable-owner lock is age-broken" "$rc" "0"

export RENDER_LEASE_DIR="$tmp/reg-lock-unverifiable-fresh"
mkdir -p "$RENDER_LEASE_DIR/.registry.lock"
printf 'msys:not-a-pid\n' > "$RENDER_LEASE_DIR/.registry.lock/owner.pid"
rc=0; render_lease_claim 'feat/x' "$tmp/wt" 2>/dev/null || rc=$?
check "fresh unverifiable-owner lock refuses" "$rc" "1"

# --- r7: owner-verified release (a broken-then-superseded holder must never
# delete a successor's lock) --------------------------------------------------
export RENDER_LEASE_DIR="$tmp/reg-release-foreign"
mkdir -p "$RENDER_LEASE_DIR/.registry.lock"
printf 'msys:424242\n' > "$RENDER_LEASE_DIR/.registry.lock/owner.pid"
render_lease_lock_release 2>"$tmp/release-foreign.stderr"
check "release leaves a successor's lock intact" "$(test -d "$RENDER_LEASE_DIR/.registry.lock" && echo held || echo removed)" "held"
check "refused release names the owner mismatch" "$(grep -Fc 'NOT releasing registry lock' "$tmp/release-foreign.stderr" 2>/dev/null)" "1"
mkdir -p "$RENDER_LEASE_DIR/self-lock-probe"
rm -rf "$RENDER_LEASE_DIR/.registry.lock"
mkdir -p "$RENDER_LEASE_DIR/.registry.lock"
printf 'msys:%s\n' "$$" > "$RENDER_LEASE_DIR/.registry.lock/owner.pid"
render_lease_lock_release 2>/dev/null
check "release removes this process's own lock" "$(test -e "$RENDER_LEASE_DIR/.registry.lock" && echo held || echo removed)" "removed"

# --- r7: env knobs validated before arithmetic --------------------------------
check "secs validator: garbage -> 600" "$(_render_lease_secs 'abc')" "600"
check "secs validator: empty -> 600" "$(_render_lease_secs '')" "600"
check "secs validator: zero -> 600" "$(_render_lease_secs '0')" "600"
check "secs validator: valid honored" "$(_render_lease_secs '1800')" "1800"

export RENDER_LEASE_DIR="$tmp/reg-lock-garbage-env-aged"
mkdir -p "$RENDER_LEASE_DIR/.registry.lock"
printf 'win:12345\n' > "$RENDER_LEASE_DIR/.registry.lock/owner.pid"
touch -t 202001010000 "$RENDER_LEASE_DIR/.registry.lock"
rc=0
RENDER_LEASE_LOCK_STALE_SECS='not-a-number' render_lease_claim 'feat/x' "$tmp/wt" 2>"$tmp/garbage-env.stderr" || rc=$?
check "garbage stale env falls back to default (aged lock still breaks)" "$rc" "0"
check "garbage stale env reports the default threshold" "$(grep -Fc 'older than 600s' "$tmp/garbage-env.stderr" 2>/dev/null)" "1"
export RENDER_LEASE_DIR="$tmp/reg-lock-garbage-env-fresh"
mkdir -p "$RENDER_LEASE_DIR/.registry.lock"
printf 'win:12345\n' > "$RENDER_LEASE_DIR/.registry.lock/owner.pid"
rc=0
RENDER_LEASE_LOCK_STALE_SECS='not-a-number' render_lease_claim 'feat/x' "$tmp/wt" 2>/dev/null || rc=$?
check "garbage stale env never collapses the threshold (fresh lock refuses)" "$rc" "1"

export RENDER_LEASE_DIR="$tmp/reg-ttl-honored"
mkdir -p "$RENDER_LEASE_DIR/feat+2Fttl"
printf 'branch\tfeat/ttl\nworktree\t%s\nacquired_by\t999999\nstarted_at\t2026-01-01T00:00:00Z\nleader_pid\t\nleader_winpid\t\nleader_identity\t\nstatus\tlaunching\n' \
    "$tmp/wt" > "$RENDER_LEASE_DIR/feat+2Fttl/lease.record"
sleep 2
rc=0; render_lease_probe 'feat/ttl' || rc=$?
check "fresh record under default TTL stays held" "$rc" "1"
rc=0; RENDER_LEASE_TTL_SECS=1 render_lease_probe 'feat/ttl' || rc=$?
check "valid short TTL is honored (dead-wrapper record frees)" "$rc" "0"
rc=0; RENDER_LEASE_TTL_SECS='garbage' render_lease_probe 'feat/ttl' || rc=$?
check "garbage TTL env falls back to the 600s default" "$rc" "1"

# --- r7: first-tab field split (PS twin parity on tab-bearing values) ---------
mkdir -p "$tmp/tab-lease"
printf 'worktree\tval\twith\ttabs\nstatus\trunning\n' > "$tmp/tab-lease/lease.record"
tab_expected=$(printf 'val\twith\ttabs')
check "field parse keeps everything after the FIRST tab" "$(render_lease_field "$tmp/tab-lease" worktree)" "$tab_expected"
check "field parse still isolates ordinary values" "$(render_lease_field "$tmp/tab-lease" status)" "running"

# --- r9: nonce-verified lease release (a reclaimed-away holder must never
# delete a successor's live lease) ---------------------------------------------
export RENDER_LEASE_DIR="$tmp/reg-r9-release"
rc=0; render_lease_claim 'feat/r9' "$tmp/wt" 2>/dev/null || rc=$?
check "r9 claim acquires" "$rc" "0"
r9_dir="$RENDER_LEASE_DIR/feat+2Fr9"
r9_nonce=$(render_lease_field "$r9_dir" claim_nonce)
check "claim stamps a claim nonce" "$(test -n "$r9_nonce" && echo stamped || echo missing)" "stamped"
render_lease_bind 'feat/r9' 4242 5252 'win:5252:1' || true
check "bind preserves the claim nonce" "$(render_lease_field "$r9_dir" claim_nonce)" "$r9_nonce"
# A successor reclaims the branch (fresh record, its own nonce); the former
# holder's later clean exit must NOT delete it.
printf 'branch\tfeat/r9\nworktree\t%s\nacquired_by\t999999\nstarted_at\t2026-01-01T00:00:00Z\nleader_pid\t\nleader_winpid\t\nleader_identity\t\nstatus\tlaunching\nclaim_nonce\tsuccessor-nonce\n' \
    "$tmp/wt" > "$r9_dir/lease.record"
render_lease_release 'feat/r9' 2>"$tmp/r9-release.stderr"
check "release leaves a successor's reclaimed lease intact" "$(test -d "$r9_dir" && echo held || echo removed)" "held"
check "refused lease release names the reclaim" "$(grep -Fc 'NOT releasing lease' "$tmp/r9-release.stderr" 2>/dev/null)" "1"
# Restore our own acquisition record: the normal self-release still works.
printf 'branch\tfeat/r9\nworktree\t%s\nacquired_by\t%s\nstarted_at\t2026-01-01T00:00:00Z\nleader_pid\t\nleader_winpid\t\nleader_identity\t\nstatus\tlaunching\nclaim_nonce\t%s\n' \
    "$tmp/wt" "$$" "$r9_nonce" > "$r9_dir/lease.record"
render_lease_release 'feat/r9' 2>/dev/null
check "self-release still removes our own lease" "$(test -e "$r9_dir" && echo held || echo removed)" "removed"
# A process that never claimed anything can never release a lease.
mkdir -p "$RENDER_LEASE_DIR/feat+2Fr9b"
printf 'branch\tfeat/r9b\nworktree\t%s\nacquired_by\t999999\nstarted_at\t2026-01-01T00:00:00Z\nleader_pid\t\nleader_winpid\t\nleader_identity\t\nstatus\tlaunching\nclaim_nonce\tother-nonce\n' \
    "$tmp/wt" > "$RENDER_LEASE_DIR/feat+2Fr9b/lease.record"
unset _RENDER_LEASE_CLAIM_NONCE
render_lease_release 'feat/r9b' 2>/dev/null
check "claimless process cannot release any lease" "$(test -d "$RENDER_LEASE_DIR/feat+2Fr9b" && echo held || echo removed)" "held"

# --- r9: the delay knob is validated before it reaches sleep ------------------
check "delay validator: garbage -> 0.5" "$(_render_lease_delay 'abc')" "0.5"
check "delay validator: empty -> 0.5" "$(_render_lease_delay '')" "0.5"
check "delay validator: zero allowed" "$(_render_lease_delay '0')" "0"
check "delay validator: fraction allowed" "$(_render_lease_delay '0.25')" "0.25"
check "delay validator: double-dot -> 0.5" "$(_render_lease_delay '1.2.3')" "0.5"
check "delay validator: trailing dot -> 0.5" "$(_render_lease_delay '5.')" "0.5"
export RENDER_LEASE_DIR="$tmp/reg-delay-junk"
mkdir -p "$RENDER_LEASE_DIR/.registry.lock"
printf 'msys:%s\n' "$$" > "$RENDER_LEASE_DIR/.registry.lock/owner.pid"
rc=0
RENDER_LEASE_LOCK_DELAY_SECS='junk' RENDER_LEASE_LOCK_ATTEMPTS=2 render_lease_claim 'feat/x' "$tmp/wt" 2>/dev/null || rc=$?
check "garbage delay env falls back and still refuses cleanly" "$rc" "1"

if [ "$fails" -eq 0 ]; then
    echo "ALL PASS"
else
    echo "$fails FAILED"
    exit 1
fi
