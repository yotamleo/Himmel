#!/usr/bin/env bash
# test-reconcile-rtk-hook.sh — smoke test for
# scripts/lib/reconcile-rtk-hook.sh (HIMMEL-399).
#
# The standalone "reconcile now" path: after an operator runs `rtk init -g`
# OUTSIDE full machine-setup (which appends a bare `rtk hook claude`
# PreToolUse entry without checking for an existing one), this helper makes
# the rtk hook registration idempotent + duplicate-safe — swap every bare
# entry to the rtk-hook-guard wrapper AND collapse the result to EXACTLY ONE
# guard entry, with re-runs a no-op.
#
# bash 3.2-safe (no mapfile / associative arrays). Requires jq.
#
# Covers:
#   1.  Fresh: one bare `rtk hook claude` → exactly ONE guard entry, zero bare.
#   2.  Idempotency: re-running case 1 changes nothing (no-op, rc 0).
#   3.  Guard + bare coexist (HIMMEL-264 leftover) → collapse to ONE guard.
#   4.  Two bare entries (rtk init -g run twice) → ONE guard.
#   5.  Two guard entries already present → collapse to ONE.
#   6.  Unrelated PreToolUse hooks + sibling keys preserved.
#   7.  Missing settings file → no-op, rc 0, file NOT created.
#   8.  Invalid JSON → refuse (rc 1), file left byte-for-byte unchanged.
#   9.  No rtk entry at all → no-op, rc 0, unchanged.
#   10. Empty / whitespace-only file → no-op, rc 0 (nothing to reconcile).
#   11. Scope isolation: reconciling one settings file never touches another
#       (the "no cross-scope dup" guarantee is per-file — user vs project are
#       reconciled independently).
#   12. No hooks.PreToolUse key → byte-for-byte unchanged (no spurious []).
#   13. Two guards in the SAME hooks array → collapse (intra-array branch).
#   14. Bare entry beside a non-rtk hook → matcher + sibling preserved.
#   15. Stale-path guard + fresh bare → ONE guard at the CURRENT path.
#   16. Custom command mentioning the guard path → never rewritten.
#   17. Custom command BEFORE a real guard → custom kept verbatim, ONE guard.
#   18. Custom command AFTER a real guard → custom kept verbatim, ONE guard.

set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
    echo "FAIL: jq not on PATH — required by these fixtures" >&2
    exit 1
fi

repo_root=$(git rev-parse --show-toplevel)
helper="$repo_root/scripts/lib/reconcile-rtk-hook.sh"
HIMMEL='/opt/himmel'
GUARD="bash \"$HIMMEL/scripts/hooks/rtk-hook-guard.sh\""

[ -f "$helper" ] || { echo "FAIL: $helper not found" >&2; exit 1; }

pass=0
fail=0
assert_pass() { pass=$((pass + 1)); echo "  PASS: $1"; }
assert_fail() { fail=$((fail + 1)); echo "  FAIL: $1"; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# guard_count <file>  — number of PreToolUse hook objects pointing at the guard
guard_count() {
    jq '[.hooks.PreToolUse[]?.hooks[]? | select((.command // "") | contains("rtk-hook-guard.sh"))] | length' "$1"
}
# bare_count <file>  — number of PreToolUse hook objects still bare `rtk hook claude`
bare_count() {
    jq '[.hooks.PreToolUse[]?.hooks[]?
         | select((.command // "") | test("^[[:space:]]*rtk[[:space:]]+hook[[:space:]]+claude([[:space:]]|$)"))]
        | length' "$1"
}
reconcile() { bash "$helper" "$1" "$HIMMEL" >/dev/null 2>&1; }

# ---------- 1. Fresh: one bare entry → one guard ----------
echo "Test 1: a single bare 'rtk hook claude' becomes one guard entry"
f="$work/fresh.json"
jq -n '{hooks:{PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:"rtk hook claude"}]}]}}' > "$f"
reconcile "$f"
if [ "$(guard_count "$f")" -eq 1 ] && [ "$(bare_count "$f")" -eq 0 ]; then
    assert_pass "1 guard, 0 bare after reconcile"
else
    assert_fail "expected 1 guard / 0 bare, got guard=$(guard_count "$f") bare=$(bare_count "$f")"
fi

# ---------- 2. Idempotency ----------
echo "Test 2: re-running on an already-reconciled file is a no-op"
before=$(jq -S . "$f")
reconcile "$f"
after=$(jq -S . "$f")
if [ "$before" = "$after" ] && [ "$(guard_count "$f")" -eq 1 ]; then
    assert_pass "second run left the document unchanged (still 1 guard)"
else
    assert_fail "re-run changed the document or count drifted (guard=$(guard_count "$f"))"
fi

# ---------- 3. Guard + bare coexist → collapse to one ----------
echo "Test 3: a guard entry next to a bare entry collapses to ONE guard"
f="$work/mixed.json"
jq -n --arg g "$GUARD" '{hooks:{PreToolUse:[
    {matcher:"Bash",hooks:[{type:"command",command:$g}]},
    {matcher:"Bash",hooks:[{type:"command",command:"rtk hook claude"}]}
]}}' > "$f"
reconcile "$f"
if [ "$(guard_count "$f")" -eq 1 ] && [ "$(bare_count "$f")" -eq 0 ]; then
    assert_pass "collapsed to exactly 1 guard (bare swapped, dup dropped)"
else
    assert_fail "expected 1 guard / 0 bare, got guard=$(guard_count "$f") bare=$(bare_count "$f")"
fi

# ---------- 4. Two bare entries (rtk init -g twice) → one guard ----------
echo "Test 4: two bare entries collapse to ONE guard"
f="$work/twobare.json"
jq -n '{hooks:{PreToolUse:[
    {matcher:"Bash",hooks:[{type:"command",command:"rtk hook claude"}]},
    {matcher:"Bash",hooks:[{type:"command",command:"rtk hook claude --foo"}]}
]}}' > "$f"
reconcile "$f"
if [ "$(guard_count "$f")" -eq 1 ] && [ "$(bare_count "$f")" -eq 0 ]; then
    assert_pass "two bare entries → 1 guard"
else
    assert_fail "expected 1 guard / 0 bare, got guard=$(guard_count "$f") bare=$(bare_count "$f")"
fi

# ---------- 5. Two guard entries already → collapse ----------
echo "Test 5: two pre-existing guard entries collapse to ONE"
f="$work/twoguard.json"
jq -n --arg g "$GUARD" '{hooks:{PreToolUse:[
    {matcher:"Bash",hooks:[{type:"command",command:$g}]},
    {matcher:"Bash",hooks:[{type:"command",command:$g}]}
]}}' > "$f"
reconcile "$f"
if [ "$(guard_count "$f")" -eq 1 ]; then
    assert_pass "two guards → 1 guard"
else
    assert_fail "expected 1 guard, got $(guard_count "$f")"
fi

# ---------- 6. Unrelated hooks + sibling keys preserved ----------
echo "Test 6: unrelated PreToolUse hooks and sibling keys survive"
f="$work/preserve.json"
jq -n '{hooks:{PreToolUse:[
    {matcher:"*",hooks:[{type:"command",command:"bash /x/auto-arm-on-cap.sh"}]},
    {matcher:"Bash",hooks:[{type:"command",command:"rtk hook claude"}]}
]},theme:"dark"}' > "$f"
reconcile "$f"
if jq -e '.theme == "dark"
          and ([.hooks.PreToolUse[]?.hooks[]?.command] | any(. == "bash /x/auto-arm-on-cap.sh"))' "$f" >/dev/null \
   && [ "$(guard_count "$f")" -eq 1 ]; then
    assert_pass "auto-arm hook + theme preserved, 1 guard added"
else
    assert_fail "unrelated content disturbed: $(jq -c . "$f")"
fi

# ---------- 7. Missing file → no-op, not created ----------
echo "Test 7: missing settings file → no-op, file not created"
f="$work/does-not-exist.json"
if reconcile "$f" && [ ! -e "$f" ]; then
    assert_pass "missing file tolerated, not created"
else
    assert_fail "missing-file path either errored or created the file"
fi

# ---------- 8. Invalid JSON → refuse, unchanged ----------
echo "Test 8: invalid JSON → refuse (rc 1), file unchanged"
f="$work/broken.json"
printf '{not valid json' > "$f"
orig=$(cat "$f")
set +e
reconcile "$f"
rc=$?
if [ "$rc" -ne 0 ] && [ "$(cat "$f")" = "$orig" ]; then
    assert_pass "refused invalid JSON, left file byte-for-byte"
else
    assert_fail "expected rc!=0 and unchanged file, got rc=$rc"
fi

# ---------- 9. No rtk entry → no-op ----------
echo "Test 9: settings with no rtk entry → no-op, rc 0, unchanged"
f="$work/nortk.json"
jq -n '{hooks:{PreToolUse:[{matcher:"*",hooks:[{type:"command",command:"bash /x/other.sh"}]}]}}' > "$f"
before=$(jq -S . "$f")
reconcile "$f"
if [ "$before" = "$(jq -S . "$f")" ] && [ "$(guard_count "$f")" -eq 0 ]; then
    assert_pass "no rtk entry → unchanged, no guard injected"
else
    assert_fail "no-rtk file was modified: $(jq -c . "$f")"
fi

# ---------- 10. Empty / whitespace-only file → no-op ----------
echo "Test 10: empty file → no-op, rc 0"
f="$work/empty.json"
printf '   \n' > "$f"
set +e
reconcile "$f"
rc=$?
if [ "$rc" -eq 0 ]; then
    assert_pass "empty file tolerated (nothing to reconcile)"
else
    assert_fail "expected rc 0 on empty file, got rc=$rc"
fi

# ---------- 11. Scope isolation ----------
echo "Test 11: reconciling one file never touches another (per-scope)"
user="$work/user.json"
proj="$work/project.json"
jq -n '{hooks:{PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:"rtk hook claude"}]}]}}' > "$user"
jq -n '{hooks:{PreToolUse:[{matcher:"Bash",hooks:[{type:"command",command:"bash /x/proj.sh"}]}]}}' > "$proj"
proj_before=$(jq -S . "$proj")
reconcile "$user"
if [ "$(guard_count "$user")" -eq 1 ] && [ "$proj_before" = "$(jq -S . "$proj")" ]; then
    assert_pass "user reconciled to 1 guard; project file untouched"
else
    assert_fail "scope isolation broken: project changed or user count wrong"
fi

# ---------- 12. No PreToolUse key at all → byte-for-byte unchanged ----------
# Regression: the DEDUP assignment must not inject a spurious "PreToolUse": []
# into a settings file that has none (non-destructive / no-op contract).
echo "Test 12: settings with no hooks.PreToolUse stays byte-for-byte"
for fixture in '{"theme":"dark"}' '{"hooks":{}}' \
    '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"rtk hook claude"}]}]}}'; do
    f="$work/noptu.json"
    printf '%s' "$fixture" > "$f"
    orig=$(cat "$f")
    reconcile "$f"
    if [ "$(cat "$f")" = "$orig" ]; then
        assert_pass "unchanged: $fixture"
    else
        assert_fail "spurious mutation of '$fixture' → $(cat "$f")"
    fi
done

# ---------- 13. Two guard entries in the SAME hooks array → collapse ----------
# Exercises the intra-array dedup branch (the across-group case is Test 5).
echo "Test 13: two guards inside one group's hooks array collapse to ONE"
f="$work/samegroup.json"
jq -n --arg g "$GUARD" '{hooks:{PreToolUse:[
    {matcher:"Bash",hooks:[{type:"command",command:$g},{type:"command",command:$g}]}
]}}' > "$f"
reconcile "$f"
if [ "$(guard_count "$f")" -eq 1 ]; then
    assert_pass "intra-array duplicate guard collapsed to 1"
else
    assert_fail "expected 1 guard, got $(guard_count "$f")"
fi

# ---------- 14. matcher + sibling hook preserved when bare swapped in place ----------
echo "Test 14: a bare entry beside a non-rtk hook keeps matcher + sibling"
f="$work/matcher.json"
jq -n '{hooks:{PreToolUse:[
    {matcher:"Bash",hooks:[
        {type:"command",command:"rtk hook claude"},
        {type:"command",command:"bash /x/sibling.sh"}
    ]}
]}}' > "$f"
reconcile "$f"
if [ "$(guard_count "$f")" -eq 1 ] \
   && jq -e '.hooks.PreToolUse[0].matcher == "Bash"
             and ([.hooks.PreToolUse[]?.hooks[]?.command] | any(. == "bash /x/sibling.sh"))' "$f" >/dev/null; then
    assert_pass "matcher 'Bash' + sibling hook preserved, 1 guard"
else
    assert_fail "matcher/sibling not preserved: $(jq -c . "$f")"
fi

# ---------- 15. Stale guard path + fresh bare → ONE guard at the CURRENT path ----------
# HIMMEL-985: settings restored from another machine/username/checkout carry a
# guard entry with an old absolute path. Dedup keeps the FIRST guard in
# document order, so without the normalize stage the stale entry would win and
# the freshly swapped one be dropped — setup would report success while the
# hook points at a missing wrapper.
echo "Test 15: stale-path guard + new bare entry normalize to the current guard path"
f="$work/stale.json"
jq -n '{hooks:{PreToolUse:[
    {matcher:"Bash",hooks:[{type:"command",command:"bash \"/old/checkout/scripts/hooks/rtk-hook-guard.sh\""}]},
    {matcher:"Bash",hooks:[{type:"command",command:"rtk hook claude"}]}
]}}' > "$f"
reconcile "$f"
if [ "$(guard_count "$f")" -eq 1 ] && [ "$(bare_count "$f")" -eq 0 ] \
   && jq -e --arg g "$GUARD" '[.hooks.PreToolUse[]?.hooks[]?.command] | any(. == $g)' "$f" >/dev/null \
   && ! jq -e '[.hooks.PreToolUse[]?.hooks[]?.command] | any(contains("/old/checkout/"))' "$f" >/dev/null; then
    assert_pass "1 guard at the current himmel path, stale path gone"
else
    assert_fail "stale guard survived or wrong path: $(jq -c . "$f")"
fi

# ---------- 16. Custom command MENTIONING the guard path is never rewritten ----------
# The normalize stage is deliberately narrower than dedup: only a PLAIN
# `bash "<path>/rtk-hook-guard.sh"` invocation is rewritten. An operator's
# custom wrapper that merely mentions the guard path keeps its exact text
# (non-destructive contract; CR round-5 finding).
echo "Test 16: a custom wrapper mentioning rtk-hook-guard.sh keeps its exact command"
f="$work/custom.json"
custom='bash /x/wrap.sh --then "/opt/other/scripts/hooks/rtk-hook-guard.sh"'
jq -n --arg c "$custom" '{hooks:{PreToolUse:[
    {matcher:"Bash",hooks:[{type:"command",command:$c}]}
]}}' > "$f"
if ! reconcile "$f"; then
    assert_fail "reconcile exited non-zero on the custom-wrapper fixture"
elif jq -e --arg c "$custom" '[.hooks.PreToolUse[]?.hooks[]?.command] | any(. == $c)' "$f" >/dev/null; then
    assert_pass "custom wrapper command preserved verbatim"
else
    assert_fail "custom wrapper was rewritten: $(jq -c . "$f")"
fi

# plain_guard_count <file>  — hook objects whose command IS the current guard
# (exact match; narrower than guard_count's contains(), which also counts a
# custom wrapper that mentions the guard path).
plain_guard_count() {
    jq --arg g "$GUARD" '[.hooks.PreToolUse[]?.hooks[]? | select((.command // "") == $g)] | length' "$1"
}

# ---------- 17. Custom wrapper BEFORE a real guard → both survive dedup ----------
# Dedup must collapse only PLAIN guard invocations. A custom wrapper listed
# first must not swallow the real guard (contains()-era dedup kept the first
# guard-ish entry in document order, deleting whichever came second).
echo "Test 17: custom wrapper before a real guard - custom kept verbatim, one plain guard"
f="$work/custom-first.json"
jq -n --arg c "$custom" --arg g "$GUARD" '{hooks:{PreToolUse:[
    {matcher:"Bash",hooks:[{type:"command",command:$c}]},
    {matcher:"Bash",hooks:[{type:"command",command:$g}]}
]}}' > "$f"
if ! reconcile "$f"; then
    assert_fail "reconcile exited non-zero on the custom-before-guard fixture"
elif [ "$(jq --arg c "$custom" '[.hooks.PreToolUse[]?.hooks[]?.command | select(. == $c)] | length' "$f")" -eq 1 ] \
   && [ "$(plain_guard_count "$f")" -eq 1 ]; then
    assert_pass "custom wrapper kept verbatim exactly once, exactly one plain guard remains"
else
    assert_fail "custom-before-guard mangled: $(jq -c . "$f")"
fi

# ---------- 18. Custom wrapper AFTER a real guard → both survive dedup ----------
echo "Test 18: custom wrapper after a real guard - custom kept verbatim, one plain guard"
f="$work/custom-second.json"
jq -n --arg c "$custom" --arg g "$GUARD" '{hooks:{PreToolUse:[
    {matcher:"Bash",hooks:[{type:"command",command:$g}]},
    {matcher:"Bash",hooks:[{type:"command",command:$c}]}
]}}' > "$f"
if ! reconcile "$f"; then
    assert_fail "reconcile exited non-zero on the custom-after-guard fixture"
elif [ "$(jq --arg c "$custom" '[.hooks.PreToolUse[]?.hooks[]?.command | select(. == $c)] | length' "$f")" -eq 1 ] \
   && [ "$(plain_guard_count "$f")" -eq 1 ]; then
    assert_pass "custom wrapper kept verbatim exactly once, exactly one plain guard remains"
else
    assert_fail "custom-after-guard mangled: $(jq -c . "$f")"
fi

# ---------- summary ----------
echo ""
echo "reconcile-rtk-hook: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
