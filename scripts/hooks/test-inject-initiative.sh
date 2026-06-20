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
echo "Test 18: 'prcheck,merge' points at pr-merge.sh, guards --admin, no no-merge line"
out=$(printf '{}' | HIMMEL_INITIATIVE=prcheck,merge bash "$hook")
assert_has   "merge step names pr-merge.sh" "pr-merge.sh"       "$out"
assert_has   "merge step guards --admin"    "never .*--admin"   "$out"
assert_lacks "no-merge line dropped when merge active" "Do NOT merge" "$out"

# ---------- 19. public leg renders a PREP-ONLY step --------------------------
echo "Test 19: 'merge,public' renders a prep-only public step (stops before push)"
out=$(printf '{}' | HIMMEL_INITIATIVE=merge,public bash "$hook")
assert_has "public step is prep-only" "PREP"                    "$out"
assert_has "public step says do not push" "DO NOT push"         "$out"

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

echo
echo "RESULTS: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
exit 0
