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
#   8.  A single-token subset injects only that step and omits the others.
#   9.  A multi-token subset injects exactly the named steps.
#   10. Steps render in canonical order regardless of input order.
#   11. Unknown tokens mixed with valid ones are ignored, valid ones still fire.
#   12. Tokens parse case-insensitively and tolerate surrounding whitespace.
#   13. The directive echoes the recognized tokens (Active steps: ...).
#   14. Safety invariants (no-merge, no-rail-relaxation) appear in EVERY subset.
#   15. `all` activates all four steps.
#   16. Duplicate / trailing-comma tokens collapse to a single rendered step.

set -euo pipefail

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
    if printf '%s' "$3" | grep -q "$2"; then
        assert_pass "$1"
    else
        assert_fail "$1 (missing: $2)"
    fi
}

# assert_has_fixed <desc> <fixed-needle> <haystack> — like assert_has, but the
# needle is matched as a literal string (grep -F), not a basic-regex pattern
# (CodeRabbit, HIMMEL-1080 round-1): use for needles containing regex
# metacharacters (e.g. `.`) that must match EXACTLY, not loosely.
assert_has_fixed() {
    if printf '%s' "$3" | grep -qF -- "$2"; then
        assert_pass "$1"
    else
        assert_fail "$1 (missing: $2)"
    fi
}

# assert_lacks <desc> <bre-needle> <haystack> — haystack must NOT contain it.
assert_lacks() {
    if printf '%s' "$3" | grep -q "$2"; then
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
if echo "$out" | grep -q "HIMMEL_INITIATIVE is active"; then
    assert_pass "directive injected when env=1"
else
    assert_fail "expected 'HIMMEL_INITIATIVE is active' in output, got: $out"
fi

# ---------- 3. Other truthy values ----------
echo "Test 3: other truthy values activate"
for val in true TRUE on ON yes YES; do
    out=$(printf '{}' | HIMMEL_INITIATIVE="$val" bash "$hook")
    if echo "$out" | grep -q "HIMMEL_INITIATIVE is active"; then
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
if echo "$out" | grep -q "HIMMEL_INITIATIVE is active"; then
    assert_pass "no stdin payload tolerated"
else
    assert_fail "expected activation even without stdin, got: $out"
fi

# ---------- 6. Directive does not authorize merge ----------
echo "Test 6: directive does not instruct merge (operator gate preserved)"
out=$(HIMMEL_INITIATIVE=1 bash "$hook" </dev/null)
if echo "$out" | grep -qi "do NOT merge"; then
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

# Unique per-step markers (must not collide with the invariant trailer prose):
#   prcheck  → "fix every finding"
#   pr       → "open or refresh the PR"
#   ticket   → "Transition the Jira ticket"
#   handover → "Write the handover"

# ---------- 8. Single-token subset → only that step ----------
echo "Test 8: subset 'prcheck' injects only the pr-check step"
out=$(printf '{}' | HIMMEL_INITIATIVE=prcheck bash "$hook")
assert_has   "prcheck step present"  "fix every finding"        "$out"
assert_lacks "pr step omitted"       "open or refresh the PR"   "$out"
assert_lacks "ticket step omitted"   "Transition the Jira ticket" "$out"
assert_lacks "handover step omitted" "Write the handover"       "$out"

# ---------- 9. Multi-token subset → exactly the named steps ----------
echo "Test 9: subset 'prcheck,pr' injects prcheck + pr only"
out=$(printf '{}' | HIMMEL_INITIATIVE=prcheck,pr bash "$hook")
assert_has   "prcheck step present"  "fix every finding"        "$out"
assert_has   "pr step present"       "open or refresh the PR"   "$out"
assert_lacks "ticket step omitted"   "Transition the Jira ticket" "$out"
assert_lacks "handover step omitted" "Write the handover"       "$out"

# ---------- 10. Canonical order regardless of input order ----------
echo "Test 10: 'handover,prcheck' renders prcheck first (canonical order)"
out=$(printf '{}' | HIMMEL_INITIATIVE=handover,prcheck bash "$hook")
assert_has "prcheck numbered first"  "1\. Run"                  "$out"
assert_has "handover numbered second" "2\. Write the handover"  "$out"

# ---------- 11. Unknown token ignored, valid one still fires ----------
echo "Test 11: 'prcheck,bogus' ignores bogus, keeps prcheck"
out=$(printf '{}' | HIMMEL_INITIATIVE=prcheck,bogus bash "$hook")
assert_has   "prcheck step present"  "fix every finding"        "$out"
assert_lacks "no bogus echoed as step" "bogus"                  "$out"

# ---------- 12. Case-insensitive + whitespace-tolerant ----------
echo "Test 12: 'PR, ticket' parses case-insensitively, trims spaces"
out=$(printf '{}' | HIMMEL_INITIATIVE="PR, ticket" bash "$hook")
assert_has   "pr step present"       "open or refresh the PR"   "$out"
assert_has   "ticket step present"   "Transition the Jira ticket" "$out"
assert_lacks "prcheck step omitted"  "fix every finding"        "$out"
assert_lacks "handover step omitted" "Write the handover"       "$out"

# ---------- 13. Directive echoes recognized tokens ----------
echo "Test 13: directive echoes the active tokens (typo visibility)"
out=$(printf '{}' | HIMMEL_INITIATIVE=prcheck,pr bash "$hook")
assert_has "active-steps line present" "Active steps:"          "$out"
# Exact match (not "...pr") so a dropped pr token can't hide behind prcheck.
assert_has "active-steps lists both tokens in order" "Active steps: prcheck,pr" "$out"

# ---------- 14. Safety invariants present in EVERY subset ----------
# The load-bearing property: no subset may ever drop the no-merge / no-rail-
# relaxation guards. Parametrized so a renumber/assembly bug can't regress it.
echo "Test 14: safety invariants present in every subset"
for val in prcheck pr pr,ticket handover all 1; do
    out=$(printf '{}' | HIMMEL_INITIATIVE="$val" bash "$hook")
    assert_has "[$val] excludes merge"       "Do NOT merge"                  "$out"
    assert_has "[$val] no rail relaxation"   "does NOT relax any safety rail" "$out"
done

# ---------- 15. `all` activates all four steps ----------
echo "Test 15: 'all' activates the full chain"
out=$(printf '{}' | HIMMEL_INITIATIVE=all bash "$hook")
assert_has "prcheck step present"  "fix every finding"          "$out"
assert_has "pr step present"       "open or refresh the PR"     "$out"
assert_has "ticket step present"   "Transition the Jira ticket" "$out"
assert_has "handover step present" "Write the handover"         "$out"

# ---------- 16. Duplicate / trailing-comma collapses to one step ----------
echo "Test 16: 'pr,pr,' renders a single pr step"
out=$(printf '{}' | HIMMEL_INITIATIVE=pr,pr, bash "$hook")
assert_has   "pr step present"       "open or refresh the PR"   "$out"
assert_lacks "no second numbered step" "2\."                    "$out"

# ---------- 17. execute leg renders an execution-handoff step (HIMMEL-443) ----
echo "Test 17: 'prcheck,execute' renders the execute handoff"
out=$(printf '{}' | HIMMEL_INITIATIVE=prcheck,execute bash "$hook")
assert_has "execute step present" "subagent-driven-development" "$out"

# ---------- 18. merge leg renders a merge step + drops the no-merge line ------
echo "Test 18: 'prcheck,merge' points at pr-merge.sh, names the armed auto-merge path, guards --admin, no no-merge line"
out=$(printf '{}' | HIMMEL_INITIATIVE=prcheck,merge bash "$hook")
assert_has   "merge step names pr-merge.sh" "pr-merge.sh"       "$out"
# Pin BOTH the exact directive AND the ARMAUTOMERGE=1 opt-in on the SAME line
# (CodeRabbit round-2, HIMMEL-1080). The hook renders the merge step as a
# SINGLE line naming both (verified). Asserting each token against the whole
# $out would let two unrelated lines — or stray prose — satisfy them
# independently, never proving the merge step ITSELF names both. So first
# isolate that one line (grep the unique merge-on-green.sh mention), THEN
# assert each token against ONLY it. The fixed-string helper (round-1) is
# kept for the directive: its `.` chars are basic-regex metachars under
# assert_has's `grep -q` and must match literally.
merge_step=$(printf '%s\n' "$out" | grep -F "merge-on-green.sh" | head -1)
assert_has_fixed "merge step names the exact armed auto-merge directive (HIMMEL-1042)" \
             "\`bash scripts/handover/merge-on-green.sh\`" "$merge_step"
assert_has   "merge step names the ARMAUTOMERGE opt-in on the same line" "ARMAUTOMERGE=1" "$merge_step"
assert_has   "merge step guards --admin"    "never .*--admin"   "$out"
assert_lacks "no-merge line dropped when merge active" "Do NOT merge" "$out"

# ---------- 19. public leg renders a ship-mode step --------------------------
echo "Test 19: 'merge,public' renders a ship-mode public step (agent ships to PR-ready; merge stays human-authorized)"
out=$(printf '{}' | HIMMEL_INITIATIVE=merge,public bash "$hook")
assert_has   "public step ships via the leak-gated helper"  "propagate-public.sh ship" "$out"
assert_has   "public step keeps the merge human-authorized" "never run it yourself"    "$out"
assert_lacks "prep-only wording gone"                       "DO NOT push"              "$out"

# ---------- 20. overnight profile: selector reads the overnight var ----------
echo "Test 20: HIMMEL_OVERNIGHT=1 + HIMMEL_INITIATIVE_OVERNIGHT=all → 6-leg set"
out=$(printf '{}' | HIMMEL_OVERNIGHT=1 HIMMEL_INITIATIVE_OVERNIGHT=all bash "$hook")
assert_has "overnight has execute" "subagent-driven-development" "$out"
assert_has "overnight has merge"   "pr-merge.sh"                  "$out"
assert_has "overnight header names the overnight var" "HIMMEL_INITIATIVE_OVERNIGHT is active" "$out"

# ---------- 21. plan token reserved → no plan-specific prose -----------------
echo "Test 21: 'plan,prcheck' → plan emits no step, prcheck numbered first"
out=$(printf '{}' | HIMMEL_INITIATIVE=plan,prcheck bash "$hook")
assert_has   "prcheck numbered first (plan consumes no number)" "1\. Run" "$out"
assert_lacks "no second numbered step from plan"               "2\."     "$out"

# ---------- SC3 (HIMMEL-460): legs sourced from the himmel clone's .env --------
# Fixture himmel root with an .env that activates a subset.
FIX="$TMPII/himmel"; mkdir -p "$FIX"
printf 'HIMMEL_INITIATIVE=prcheck,pr\n' > "$FIX/.env"

# 22. env var UNSET → legs come from .env.
echo "Test 22: HIMMEL_INITIATIVE unset → legs resolved from the himmel .env"
out=$(unset HIMMEL_INITIATIVE; printf '{}' | HIMMEL_REPO="$FIX" bash "$hook")
assert_has "active from .env (prcheck)" "fix every finding"      "$out"
assert_has "active from .env (pr)"      "open or refresh the PR" "$out"
assert_has "active-steps echoes .env subset" "Active steps: prcheck,pr" "$out"

# 23. process env OVERRIDES .env (non-clobber: live value wins).
echo "Test 23: process env overrides the .env value"
out=$(printf '{}' | HIMMEL_REPO="$FIX" HIMMEL_INITIATIVE=handover bash "$hook")
assert_has   "process-env handover wins" "Write the handover"    "$out"
assert_lacks " .env prcheck suppressed"  "fix every finding"     "$out"

# 24. CWD-safety: launched inside a DIFFERENT git repo with a decoy .env, the
# himmel .env (HIMMEL_REPO) is used — the decoy repo's .env is NEVER read.
echo "Test 24: a sibling repo's .env is not read (CWD-safety)"
DECOY="$TMPII/decoy"; mkdir -p "$DECOY"; git -C "$DECOY" init --quiet
printf 'HIMMEL_INITIATIVE=ticket\n' > "$DECOY/.env"
out=$(cd "$DECOY" && unset HIMMEL_INITIATIVE; printf '{}' | HIMMEL_REPO="$FIX" bash "$hook")
assert_has   "himmel .env subset used"   "fix every finding"          "$out"
assert_lacks "decoy .env subset ignored" "Transition the Jira ticket" "$out"

# 25. fail-open: HIMMEL_REPO points at a dir with no .env, env unset → OFF, exit 0.
echo "Test 25: no .env at the resolved root → fail-open OFF"
out=$(unset HIMMEL_INITIATIVE; printf '{}' | HIMMEL_REPO="$TMPII/noenv" bash "$hook"; echo "rc=$?")
assert_has  "fail-open exits 0" "rc=0" "$out"
# stdout should be only the rc marker (no directive).
body=$(unset HIMMEL_INITIATIVE; printf '{}' | HIMMEL_REPO="$TMPII/noenv" bash "$hook")
if [ -z "$body" ]; then assert_pass "no directive when no .env + env unset"; else assert_fail "expected OFF, got: $body"; fi

# ---------- 26. tasklist-seed preamble (HIMMEL-539) --------------------------
# An armed/resumed session must be instructed at start to seed the native
# tasklist (TaskCreate/TaskUpdate) from the handover's ordered steps. The
# instruction is an UNNUMBERED, handover-conditional preamble inside the active
# block — so it renders whenever the directive renders, never when OFF, and does
# NOT perturb the numbered leg list.
echo "Test 26: tasklist-seed preamble present when active"
out=$(printf '{}' | HIMMEL_INITIATIVE=1 bash "$hook")
assert_has "tasklist-seed preamble present"   "seed your native tasklist" "$out"
assert_has "preamble names TaskCreate"        "TaskCreate"                "$out"
assert_has "preamble is handover-conditional" "resumed from a handover"   "$out"

echo "Test 27: preamble present for a single-leg subset (not leg-gated)"
out=$(printf '{}' | HIMMEL_INITIATIVE=prcheck bash "$hook")
assert_has   "preamble present for prcheck subset"  "seed your native tasklist" "$out"
# Belt: the preamble did not perturb leg numbering — prcheck is still leg 1, and
# no second numbered leg appears (mirrors tests 8/16).
assert_has   "prcheck still numbered first"         "1\. Run"            "$out"
assert_lacks "no second numbered leg from preamble" "2\."                "$out"
# Belt: the preamble is printed BEFORE the numbered legs, so it can never acquire
# a leg number. A refactor moving it after the legs would keep the assertions
# above green (preamble still present; legs still numbered) yet silently break
# the ordering contract — assert the position directly.
seed_ln=$(printf '%s\n' "$out" | grep -n "seed your native tasklist" | head -1 | cut -d: -f1)
leg1_ln=$(printf '%s\n' "$out" | grep -n "1\. Run" | head -1 | cut -d: -f1)
if [ -n "$seed_ln" ] && [ -n "$leg1_ln" ] && [ "$seed_ln" -lt "$leg1_ln" ]; then
    assert_pass "preamble precedes the numbered legs (pos $seed_ln < $leg1_ln)"
else
    assert_fail "preamble must precede leg 1 (seed_ln=$seed_ln leg1_ln=$leg1_ln)"
fi

echo "Test 28: preamble present in the overnight profile"
out=$(printf '{}' | HIMMEL_OVERNIGHT=1 HIMMEL_INITIATIVE_OVERNIGHT=all bash "$hook")
assert_has "preamble present in overnight profile" "seed your native tasklist" "$out"

# OFF-guard: tests 1/4/7/25 already assert empty stdout when unset/falsy, which
# is the structural proof the preamble cannot leak outside the active block.

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
