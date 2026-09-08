#!/usr/bin/env bash
# test-inject-initiative.sh — smoke test for scripts/hooks/inject-initiative.sh.
#
# Covers (HIMMEL-425):
#   1. Default (env unset) → exits 0 with empty stdout (no directive injected).
#   2. HIMMEL_INITIATIVE=1 → exits 0, prints the initiative directive.
#   3. Other truthy values (true/on/yes/all/...) also activate (all four steps).
#   4. Falsy values (0/false/empty/no/off) do NOT activate.
#   5. No stdin payload still works (SessionStart may pipe a JSON body or not).
#   6. The injected directive must NOT instruct merging (operator gate).
#   7. Hook always exits 0 (never blocks session start).
#
# Per-part toggles (HIMMEL-425 extension — mirrors CRITIC_PANEL_TIERS):
#   8.  A single-token subset lists only that step and omits the others.
#   9.  A multi-token subset lists exactly the named steps.
#   10. Steps render in canonical order regardless of input order.
#   11. Unknown tokens mixed with valid ones are ignored, valid ones still fire.
#   12. Tokens parse case-insensitively and tolerate surrounding whitespace.
#   13. The directive echoes the recognized tokens (Active steps: ...).
#   14. Safety invariants (no-merge, no-rail-relaxation) appear in EVERY subset.
#   15. `all` activates all four steps.
#   16. Duplicate / trailing-comma tokens collapse to a single rendered step.
#
# Pointer form (HIMMEL-2036): the hook emits a ~370 B POINTER, not the 3,150 B
# runbook. Per-leg assertions therefore run against the `Active steps:` CSV
# (assert_step / assert_no_step) rather than step prose, and three cases guard
# the new contract:
#   26. The emitted runbook path resolves AND that file still carries the bodies.
#   27. Injected output stays within the 400-byte budget (every leg set).
#   28. No runbook body has crept back inline.

set -euo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

repo_root=$(git rev-parse --show-toplevel)
hook="$repo_root/scripts/hooks/inject-initiative.sh"

if [ ! -f "$hook" ]; then
    echo "FAIL: $hook not found" >&2
    exit 1
fi

pass=0
fail=0

# Hermetic isolation (HIMMEL-460): the hook now sources the himmel clone's .env
# for HIMMEL_INITIATIVE*. Point HIMMEL_REPO at an EMPTY temp dir so the existing
# process-env cases are unaffected by whatever .env exists on the test machine.
# The SC3 cases below override HIMMEL_REPO per-case to a fixture with a real .env.
TMPII=$(mktemp -d)
trap 'rm -rf "$TMPII"' EXIT
mkdir -p "$TMPII/noenv"
export HIMMEL_REPO="$TMPII/noenv"

# Isolate the HIMMEL-813 dedup markers (${TMPDIR:-/tmp}/himmel-inject-initiative-*)
# inside this test's own scratch dir so runs never collide with a real session's
# markers (or each other, across re-runs) and get swept by the trap above.
export TMPDIR="$TMPII/markers"
mkdir -p "$TMPDIR"

assert_pass() {
    pass=$((pass + 1))
    echo "  PASS: $1"
}

assert_fail() {
    fail=$((fail + 1))
    echo "  FAIL: $1"
}

# assert_has <desc> <bre-needle> <haystack> — haystack must contain the needle.
assert_has() {
    if grepq "$3" "$2"; then
        assert_pass "$1"
    else
        assert_fail "$1 (missing: $2)"
    fi
}

# assert_lacks <desc> <bre-needle> <haystack> — haystack must NOT contain it.
assert_lacks() {
    if grepq "$3" "$2"; then
        assert_fail "$1 (unexpected: $2)"
    else
        assert_pass "$1"
    fi
}

# ---------- 1. Default OFF ----------
echo "Test 1: default OFF (env unset)"
out=$(unset HIMMEL_INITIATIVE; printf '{"source":"startup"}' | bash "$hook")
if [ -z "$out" ]; then
    assert_pass "no directive injected when env unset"
else
    assert_fail "expected empty stdout, got: $out"
fi

# ---------- 2. HIMMEL_INITIATIVE=1 → active ----------
echo "Test 2: HIMMEL_INITIATIVE=1 → active"
out=$(printf '{}' | HIMMEL_INITIATIVE=1 bash "$hook")
if grepq "$out" "HIMMEL_INITIATIVE is active"; then
    assert_pass "directive injected when env=1"
else
    assert_fail "expected 'HIMMEL_INITIATIVE is active' in output, got: $out"
fi

# ---------- 3. Other truthy values ----------
echo "Test 3: other truthy values activate"
for val in true TRUE on ON yes YES; do
    out=$(printf '{}' | HIMMEL_INITIATIVE="$val" bash "$hook")
    if grepq "$out" "HIMMEL_INITIATIVE is active"; then
        assert_pass "truthy value '$val' activates"
    else
        assert_fail "truthy value '$val' should activate but did not"
    fi
done

# ---------- 4. Falsy / unrecognized values stay off ----------
# Includes garbage tokens (maybe/2/enabled) to lock in the contract that
# "truthy" is an explicit allow-list — anything NOT on it is off, not merely
# the known-falsy words. ',,,' exercises the subset path that resolves to no
# recognized part (the explicit `[ -n "$active" ] || exit 0` branch).
echo "Test 4: falsy and unrecognized values stay off"
for val in 0 false "" no off maybe 2 enabled ",,,"; do
    out=$(printf '{}' | HIMMEL_INITIATIVE="$val" bash "$hook")
    if [ -z "$out" ]; then
        assert_pass "falsy/unrecognized value '$val' stays off"
    else
        assert_fail "value '$val' should be off but injected: $out"
    fi
done

# ---------- 5. No stdin payload ----------
echo "Test 5: no stdin payload still works"
out=$(HIMMEL_INITIATIVE=1 bash "$hook" </dev/null)
if grepq "$out" "HIMMEL_INITIATIVE is active"; then
    assert_pass "no stdin payload tolerated"
else
    assert_fail "expected activation even without stdin, got: $out"
fi

# ---------- 6. Directive does not authorize merge ----------
echo "Test 6: directive does not instruct merge (operator gate preserved)"
out=$(HIMMEL_INITIATIVE=1 bash "$hook" </dev/null)
if grepq "$out" -i "do NOT merge"; then
    assert_pass "directive explicitly excludes merge"
else
    assert_fail "directive must explicitly exclude merge, got: $out"
fi

# ---------- 7. Always exits 0 (never blocks session start) ----------
# The load-bearing safety property: a SessionStart hook must never block the
# session, so it must exit 0 on every path — active, off, and unset.
echo "Test 7: hook always exits 0 (never blocks session start)"
printf '{}' | bash "$hook" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then
    assert_pass "exit 0 when env unset"
else
    assert_fail "expected exit 0 when unset, got rc=$rc"
fi
printf '{}' | HIMMEL_INITIATIVE=0 bash "$hook" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then
    assert_pass "exit 0 on falsy value"
else
    assert_fail "expected exit 0 on falsy, got rc=$rc"
fi
printf '{}' | HIMMEL_INITIATIVE=1 bash "$hook" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ]; then
    assert_pass "exit 0 when active"
else
    assert_fail "expected exit 0 when active, got rc=$rc"
fi

# HIMMEL-2036 — the hook now emits a POINTER, not the runbook. The step BODIES
# live in scripts/hooks/initiative-runbook.md, so the only per-leg signal in the
# output is the `Active steps:` CSV. These helpers assert membership in THAT
# CSV, matched on comma boundaries so `pr` can never be satisfied by `prcheck`.
steps_csv() { printf '%s\n' "$1" | sed -n 's/.*Active steps: //p' | head -1; }

# assert_step <desc> <token> <haystack>
assert_step() {
    local csv
    csv=",$(steps_csv "$3"),"
    case "$csv" in
        *",$2,"*) assert_pass "$1" ;;
        *)        assert_fail "$1 (step $2 missing from: $csv)" ;;
    esac
}

# assert_no_step <desc> <token> <haystack>
assert_no_step() {
    local csv
    csv=",$(steps_csv "$3"),"
    case "$csv" in
        *",$2,"*) assert_fail "$1 (unexpected step $2 in: $csv)" ;;
        *)        assert_pass "$1" ;;
    esac
}

# ---------- 8. Single-token subset → only that step ----------
echo "Test 8: subset prcheck lists only the pr-check step"
out=$(printf '{}' | HIMMEL_INITIATIVE=prcheck bash "$hook")
assert_step    "prcheck step present"  "prcheck"  "$out"
assert_no_step "pr step omitted"       "pr"       "$out"
assert_no_step "ticket step omitted"   "ticket"   "$out"
assert_no_step "handover step omitted" "handover" "$out"

# ---------- 9. Multi-token subset → exactly the named steps ----------
echo "Test 9: subset prcheck,pr lists prcheck + pr only"
out=$(printf '{}' | HIMMEL_INITIATIVE=prcheck,pr bash "$hook")
assert_step    "prcheck step present"  "prcheck"  "$out"
assert_step    "pr step present"       "pr"       "$out"
assert_no_step "ticket step omitted"   "ticket"   "$out"
assert_no_step "handover step omitted" "handover" "$out"

# ---------- 10. Canonical order regardless of input order ----------
echo "Test 10: handover,prcheck renders prcheck first (canonical order)"
out=$(printf '{}' | HIMMEL_INITIATIVE=handover,prcheck bash "$hook")
assert_has "canonical order in the CSV" "Active steps: prcheck,handover" "$out"

# ---------- 11. Unknown token ignored, valid one still fires ----------
echo "Test 11: prcheck,bogus ignores bogus, keeps prcheck"
out=$(printf '{}' | HIMMEL_INITIATIVE=prcheck,bogus bash "$hook")
assert_step  "prcheck step present"    "prcheck" "$out"
assert_lacks "no bogus echoed as step" "bogus"   "$out"

# ---------- 12. Case-insensitive + whitespace-tolerant ----------
echo "Test 12: 'PR, ticket' parses case-insensitively, trims spaces"
out=$(printf '{}' | HIMMEL_INITIATIVE="PR, ticket" bash "$hook")
assert_has "normalized to canonical lowercase CSV" "Active steps: pr,ticket" "$out"

# ---------- 13. Directive echoes recognized tokens ----------
echo "Test 13: directive echoes the active tokens (typo visibility)"
out=$(printf '{}' | HIMMEL_INITIATIVE=prcheck,pr bash "$hook")
assert_has "active-steps line present" "Active steps:"          "$out"
# Exact match (not "...pr") so a dropped pr token can't hide behind prcheck.
assert_has "active-steps lists both tokens in order" "Active steps: prcheck,pr" "$out"

# ---------- 14. Safety invariants present in EVERY subset ----------
# The load-bearing property: no subset may ever drop the no-merge / no-rail-
# relaxation guards. HIMMEL-2036 moved the step bodies into the runbook file but
# deliberately kept BOTH of these INLINE in the pointer — losing a step list
# costs a file read, losing "this does not relax any rail" costs a rail.
echo "Test 14: safety invariants present in every subset"
for val in prcheck pr pr,ticket handover all 1; do
    out=$(printf '{}' | HIMMEL_INITIATIVE="$val" bash "$hook")
    assert_has "[$val] excludes merge"       "Do NOT merge"                  "$out"
    assert_has "[$val] no rail relaxation"   "does NOT relax any safety rail" "$out"
done

# ---------- 15. `all` activates all four steps ----------
echo "Test 15: all activates the full chain"
out=$(printf '{}' | HIMMEL_INITIATIVE=all bash "$hook")
assert_has "all → the legacy four-leg CSV" "Active steps: prcheck,pr,ticket,handover" "$out"

# ---------- 16. Duplicate / trailing-comma collapses to one step ----------
echo "Test 16: 'pr,pr,' renders a single pr step"
out=$(printf '{}' | HIMMEL_INITIATIVE=pr,pr, bash "$hook")
assert_has "duplicate collapses in the CSV" "Active steps: pr$" "$out"

# ---------- 17. execute leg is carried in the CSV (HIMMEL-443) ---------------
echo "Test 17: prcheck,execute carries the execute leg"
out=$(printf '{}' | HIMMEL_INITIATIVE=prcheck,execute bash "$hook")
assert_has "execute leg in canonical order" "Active steps: execute,prcheck" "$out"

# ---------- 18. merge leg drops the inline no-merge line ---------------------
echo "Test 18: prcheck,merge carries the merge leg and drops the no-merge line"
out=$(printf '{}' | HIMMEL_INITIATIVE=prcheck,merge bash "$hook")
assert_step  "merge leg present"                       "merge"        "$out"
assert_lacks "no-merge line dropped when merge active" "Do NOT merge" "$out"

# ---------- 19. public leg is carried in the CSV -----------------------------
echo "Test 19: merge,public carries both legs"
out=$(printf '{}' | HIMMEL_INITIATIVE=merge,public bash "$hook")
assert_has "merge,public in canonical order" "Active steps: merge,public" "$out"

# ---------- 20. overnight profile: selector reads the overnight var ----------
echo "Test 20: HIMMEL_OVERNIGHT=1 + HIMMEL_INITIATIVE_OVERNIGHT=all → 6-leg set"
out=$(printf '{}' | HIMMEL_OVERNIGHT=1 HIMMEL_INITIATIVE_OVERNIGHT=all bash "$hook")
assert_has "overnight six-leg CSV" "Active steps: execute,prcheck,pr,ticket,merge,handover" "$out"
assert_has "overnight header names the overnight var" "HIMMEL_INITIATIVE_OVERNIGHT is active" "$out"

# ---------- 21. plan token reserved → carried, but the runbook gives no step --
echo "Test 21: plan,prcheck → plan is echoed for typo visibility"
out=$(printf '{}' | HIMMEL_INITIATIVE=plan,prcheck bash "$hook")
assert_has "plan echoed in the CSV" "Active steps: plan,prcheck" "$out"

# ---------- SC3 (HIMMEL-460): legs sourced from the himmel clone's .env --------
# Fixture himmel root with an .env that activates a subset.
FIX="$TMPII/himmel"; mkdir -p "$FIX"
printf 'HIMMEL_INITIATIVE=prcheck,pr\n' > "$FIX/.env"

# 22. env var UNSET → legs come from .env.
echo "Test 22: HIMMEL_INITIATIVE unset → legs resolved from the himmel .env"
out=$(unset HIMMEL_INITIATIVE; printf '{}' | HIMMEL_REPO="$FIX" bash "$hook")
assert_has "active-steps echoes .env subset" "Active steps: prcheck,pr" "$out"

# 23. process env OVERRIDES .env (non-clobber: live value wins).
echo "Test 23: process env overrides the .env value"
out=$(printf '{}' | HIMMEL_REPO="$FIX" HIMMEL_INITIATIVE=handover bash "$hook")
assert_step    "process-env handover wins" "handover" "$out"
assert_no_step " .env prcheck suppressed"  "prcheck"  "$out"

# 24. CWD-safety: launched inside a DIFFERENT git repo with a decoy .env, the
# himmel .env (HIMMEL_REPO) is used — the decoy repo's .env is NEVER read.
echo "Test 24: a sibling repo .env is not read (CWD-safety)"
DECOY="$TMPII/decoy"; mkdir -p "$DECOY"; git -C "$DECOY" init --quiet
printf 'HIMMEL_INITIATIVE=ticket\n' > "$DECOY/.env"
out=$(cd "$DECOY" && unset HIMMEL_INITIATIVE; printf '{}' | HIMMEL_REPO="$FIX" bash "$hook")
assert_step    "himmel .env subset used"   "prcheck" "$out"
assert_no_step "decoy .env subset ignored" "ticket"  "$out"

# 25. fail-open: HIMMEL_REPO points at a dir with no .env, env unset → OFF, exit 0.
echo "Test 25: no .env at the resolved root → fail-open OFF"
out=$(unset HIMMEL_INITIATIVE; printf '{}' | HIMMEL_REPO="$TMPII/noenv" bash "$hook"; echo "rc=$?")
assert_has  "fail-open exits 0" "rc=0" "$out"
# stdout should be only the rc marker (no directive).
body=$(unset HIMMEL_INITIATIVE; printf '{}' | HIMMEL_REPO="$TMPII/noenv" bash "$hook")
if [ -z "$body" ]; then assert_pass "no directive when no .env + env unset"; else assert_fail "expected OFF, got: $body"; fi

# ---------- 26. Runbook pointer resolves (HIMMEL-2036) -----------------------
# The pointer is only worth its bytes if the file it names exists and carries
# the content that left the hook. Assert BOTH: the emitted path, and that the
# file at that path still holds the moved bodies (including the HIMMEL-539
# tasklist-seed preamble and every leg the resolver can emit). HIMMEL_REPO is
# pinned to the real repo root so the pointer resolves regardless of which
# fixture root the SC3 cases above left in the environment.
echo "Test 26: the pointer names a runbook file that exists and carries the bodies"
out=$(printf '{}' | HIMMEL_REPO="$repo_root" HIMMEL_INITIATIVE=1 bash "$hook")
assert_has "pointer line present" "Step bodies (read then; or now if handover-resumed): " "$out"
# The emitted path is ABSOLUTE (resolved from the himmel root — the hook is
# wired at user scope too, so a session in another repo must still resolve it).
# Use it as-is; do not prepend anything.
runbook=$(printf '%s\n' "$out" | sed -n 's/^Step bodies (read then; or now if handover-resumed): //p' | head -1)
if [ -n "$runbook" ] && [ -f "$runbook" ]; then
    assert_pass "runbook path resolves to a file"
    rb=$(cat "$runbook")
    assert_has "runbook keeps the tasklist-seed preamble" "seed your native tasklist" "$rb"
    assert_has "runbook names TaskCreate"                 "TaskCreate"                "$rb"
    assert_has "runbook is handover-conditional"          "resumed from a handover"   "$rb"
    for tok in plan execute prcheck pr ticket merge public handover; do
        assert_has "runbook documents the $tok leg" "^- \*\*$tok\*\*" "$rb"
    done
    assert_has "runbook keeps the merge-on-green directive" "merge-on-green.sh"        "$rb"
    assert_has "runbook keeps the ship-mode public step"    "propagate-public.sh ship" "$rb"
else
    assert_fail "runbook path does not resolve to a file (got: $runbook)"
fi

# ---------- 27. Byte budget (HIMMEL-2036 acceptance) -------------------------
# The whole point of the pointer: the pre-HIMMEL-2036 directive was 3,150 B on
# EVERY session start, on BOTH harnesses. Budget is asserted against the REAL
# repo root (not a short temp fixture) so the absolute runbook path is paid for
# honestly, and across the widest leg set the resolver can emit.
#
# The output has exactly ONE variable term: the absolute runbook path, whose
# length is a property of where this checkout happens to live, not of the
# pointer. A worktree under .claude/worktrees/<branch-slug>/ adds ~60 B over the
# primary checkout for byte-identical pointer content — so asserting the raw
# total would go red on a deep clone with no regression, and green on a shallow
# one that HAD regressed. Assert the checkout-independent part instead:
#
#   FIXED = total - (emitted path length)
#
# and budget it so that a CANONICAL install still fits the ticket's 400 B
# acceptance criterion. Canonical = a primary checkout, whose runbook path is
# the repo root plus /scripts/hooks/initiative-runbook.md; on the reference
# machine that is 74 B, so FIXED must stay at or under 400 - 74 = 326 B. The
# actual total for THIS checkout is reported alongside, so an unusually long
# path stays visible even though it does not fail the budget.
CANONICAL_PATH_B=74
FIXED_BUDGET=$(( 400 - CANONICAL_PATH_B ))
budget_check() {
    local label="$1" bytes="$2" out="$3" path fixed
    path=$(printf '%s\n' "$out" | sed -n 's/^Step bodies (read then; or now if handover-resumed): //p' | head -1)
    if [ -z "$path" ]; then
        assert_fail "[$label] could not find the step-bodies path line — budget not measurable"
        return
    fi
    fixed=$(( bytes - ${#path} ))
    if [ "$fixed" -le "$FIXED_BUDGET" ]; then
        assert_pass "[$label] fixed content $fixed B (budget $FIXED_BUDGET = 400 - $CANONICAL_PATH_B canonical path); total here $bytes B with a ${#path} B path"
    else
        assert_fail "[$label] fixed content $fixed B — over the $FIXED_BUDGET B budget, so a canonical install would exceed the 400 B acceptance criterion"
    fi
}
echo "Test 27: pointer output stays within the 400-byte budget"
for val in 1 all prcheck,pr plan,execute,prcheck,pr,ticket,public,handover; do
    out=$(printf '{}' | HIMMEL_REPO="$repo_root" HIMMEL_INITIATIVE="$val" bash "$hook")
    budget_check "$val" "$(printf '%s\n' "$out" | wc -c | tr -d '[:space:]')" "$out"
done
out=$(printf '{}' | HIMMEL_REPO="$repo_root" HIMMEL_OVERNIGHT=1 HIMMEL_INITIATIVE_OVERNIGHT=all bash "$hook")
budget_check "overnight all" "$(printf '%s\n' "$out" | wc -c | tr -d '[:space:]')" "$out"

# ---------- 28. Pointer does NOT re-inline the runbook bodies ----------------
# Guards the regression that would silently undo this change: someone pastes a
# step body back into the hook and the budget creeps until the pointer IS the
# runbook again. The byte budget alone would catch a big paste; this catches a
# small one, and names which body leaked.
echo "Test 28: the runbook bodies stay OUT of the injected pointer"
# Cover EVERY leg, not just the long ones: the four short bodies (prcheck / pr /
# ticket / handover) are each well under the byte budget's slack, so pasting one
# back inline would regress the contract without tripping test 27.
#
# The leg set is spelled out in full, NOT `all`: neither master switch resolves
# to all eight legs (interactive `all` is 4, overnight `all` is 6 and omits
# `public`), so a regression that re-inlined a body only under a leg the switch
# does not activate would never be exercised.
out=$(printf '{}' | HIMMEL_REPO="$repo_root" HIMMEL_INITIATIVE=plan,execute,prcheck,pr,ticket,merge,public,handover bash "$hook")
assert_lacks "no tasklist-seed body inline"  "seed your native tasklist"   "$out"
assert_lacks "no merge body inline"          "merge-on-green.sh"           "$out"
assert_lacks "no public body inline"         "propagate-public.sh"         "$out"
assert_lacks "no execute body inline"        "subagent-driven-development" "$out"
assert_lacks "no prcheck body inline"        "fix every finding"           "$out"
assert_lacks "no pr body inline"             "open or refresh the PR"      "$out"
assert_lacks "no ticket body inline"         "Transition the Jira ticket"  "$out"
assert_lacks "no handover body inline"       "[Ww]rite the handover"       "$out"


# ---------- HIMMEL-813: per-session-start dedup (double-fire fix) -----------
# The hook is wired at BOTH user scope and project scope, so a single
# SessionStart event fires it twice within seconds. Dedup is keyed on
# session_id with a freshness window (NOT once-per-session-id-ever), because a
# resume/clear later in the SAME session_id must still re-inject (compaction
# may have dropped the directive by then).

# ---------- 29. Second invocation within the window, same session_id -> silent
echo "Test 29: same session_id within the freshness window -> second call silent"
sid29="sid-dedup-$$-a"
out1=$(printf '{"session_id":"%s"}' "$sid29" | HIMMEL_INITIATIVE=1 bash "$hook")
assert_has "first call injects" "HIMMEL_INITIATIVE is active" "$out1"
out2=$(printf '{"session_id":"%s"}' "$sid29" | HIMMEL_INITIATIVE=1 bash "$hook")
if [ -z "$out2" ]; then
    assert_pass "second call within window stays silent"
else
    assert_fail "second call should be silent, got: $out2"
fi
printf '{"session_id":"%s"}' "$sid29" | HIMMEL_INITIATIVE=1 bash "$hook" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
    assert_pass "second call still exits 0"
else
    assert_fail "second call should exit 0, got rc=$rc"
fi

# ---------- 30. A different session_id injects independently -----------------
echo "Test 30: a different session_id injects independently"
sid30="sid-dedup-$$-b"
out=$(printf '{"session_id":"%s"}' "$sid30" | HIMMEL_INITIATIVE=1 bash "$hook")
assert_has "different session_id injects" "HIMMEL_INITIATIVE is active" "$out"

# ---------- 31. Stale marker (backdated timestamp) re-injects ----------------
echo "Test 31: a stale marker (backdated past the window) re-injects"
sid31="sid-dedup-$$-c"
marker_dir="$TMPDIR/himmel-inject-initiative-${sid31}"
mkdir -p "$marker_dir"
printf '%s\n' "$(($(date +%s) - 3600))" >"$marker_dir/ts"
out=$(printf '{"session_id":"%s"}' "$sid31" | HIMMEL_INITIATIVE=1 bash "$hook")
assert_has "stale marker re-injects" "HIMMEL_INITIATIVE is active" "$out"

# ---------- 32. Missing session_id skips dedup entirely (fail-open) ---------
echo "Test 32: missing session_id injects on every call (fail-open)"
out1=$(printf '{}' | HIMMEL_INITIATIVE=1 bash "$hook")
out2=$(printf '{}' | HIMMEL_INITIATIVE=1 bash "$hook")
assert_has "first call (no session_id) injects"  "HIMMEL_INITIATIVE is active" "$out1"
assert_has "second call (no session_id) injects" "HIMMEL_INITIATIVE is active" "$out2"

# ---------- 33. Orphaned marker (dir exists, ts missing) still injects -------
# CR round 1: a marker dir whose ts file is gone (winner killed pre-write, or
# a temp-cleaner swept the file but not the dir) must NOT permanently silence
# the directive for that session_id. After a one-shot retry the hook fails
# OPEN: refreshes the stamp and injects.
echo "Test 33: orphaned marker (no ts file) fails open and injects"
sid33="sid-dedup-$$-d"
marker_dir="$TMPDIR/himmel-inject-initiative-${sid33}"
mkdir -p "$marker_dir"
rm -f "$marker_dir/ts"
out=$(printf '{"session_id":"%s"}' "$sid33" | HIMMEL_INITIATIVE=1 bash "$hook")
assert_has "orphaned marker injects (fail-open)" "HIMMEL_INITIATIVE is active" "$out"
if [ -s "$marker_dir/ts" ]; then
    assert_pass "orphaned marker got a refreshed ts stamp"
else
    assert_fail "orphaned marker ts file was not refreshed"
fi
# ...and the refreshed stamp makes the NEXT call a normal fresh duplicate.
out=$(printf '{"session_id":"%s"}' "$sid33" | HIMMEL_INITIATIVE=1 bash "$hook")
if [ -z "$out" ]; then
    assert_pass "call after the refresh dedups normally"
else
    assert_fail "call after the refresh should be silent, got: $out"
fi

echo
echo "RESULTS: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
exit 0
