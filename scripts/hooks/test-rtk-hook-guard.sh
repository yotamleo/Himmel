#!/usr/bin/env bash
# test-rtk-hook-guard.sh — smoke test for scripts/hooks/rtk-hook-guard.sh.
#
# Uses a STUB rtk on PATH (deterministic — no dependency on an installed
# rtk or its version). The stub mirrors the observed rtk 0.40.0 hook
# contract: bare `find …` / `git …` / `ls …` / `sort …` commands are
# rewritten to `rtk <cmd>` with permissionDecision allow; compound shell
# commands (pipes etc.) get NO output. The stub parses + emits via jq
# (HIMMEL-264 — the old }}-anchored sed silently emitted nothing when a
# trailing field followed tool_input.command, false-passing the suite).
# The rejected-predicate set the guard screens for was verified against
# the real rtk 0.40.0:
#   rejected: -not -exec -o -a -delete ! \( \)
#   silently ignored (semantics change): -prune
#   accepted: -type -maxdepth -name -path -mtime
#
# Covers:
#   1.  Simple find → rtk rewrite forwarded verbatim.
#   2.  Compound finds (-not/-exec/-o/-delete/-prune/!/\() → suppressed
#       (empty output, exit 0) — the LUNA runbook scan among them.
#   3.  Non-find rewrites forwarded, even when the command contains
#       tokens like `-o` (sort -o) — the guard only screens `rtk find`.
#   4.  rtk emits nothing (compound shell command) → empty, exit 0.
#   5.  rtk missing from PATH → empty, exit 0 (fail-open).
#   6.  rtk crashes → empty, exit 0 (fail-open).
#   7.  Empty stdin → empty, exit 0.
#   8.  permissionDecisionReason containing "-not" must NOT suppress a
#       safe rewrite (HIMMEL-264 — guard scans only the command value).
#   9.  jq broken → grep+sed fallback still suppresses compound finds
#       and forwards simple ones (no-jq fail-open contract).
#   10. Payload with a trailing field after command → stub still parses,
#       rewrite forwarded (jq-stub regression for the old sed anchor).
#   11. Output-shape drift (command field renamed) → extraction-failure
#       contract: output containing `rtk find ` is SUPPRESSED (an
#       unscanned rewrite is never forwarded), non-find output is
#       forwarded verbatim.
#   12. No jq + drifted output whose FIRST "command" pair is the
#       ORIGINAL command → the anchored fallback still finds the
#       rtk-find rewrite and suppresses its compound predicate.

set -euo pipefail

# The stub (and the guard's primary extraction path) needs jq.
if ! command -v jq >/dev/null 2>&1; then
    echo "FAIL: jq not on PATH — required by the test stub" >&2
    exit 1
fi

repo_root=$(git rev-parse --show-toplevel)
hook="$repo_root/scripts/hooks/rtk-hook-guard.sh"

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

# ---------- stub rtk ----------
stub_dir=$(mktemp -d)
trap 'rm -rf "$stub_dir"' EXIT

cat > "$stub_dir/rtk" <<'STUB'
#!/usr/bin/env bash
# Stub of `rtk hook claude` (contract observed on rtk 0.40.0).
# jq-based parse + emit (HIMMEL-264): robust to trailing payload fields
# and always emits valid JSON regardless of quoting in the command.
[ "${1:-}" = "hook" ] && [ "${2:-}" = "claude" ] || exit 1
payload=$(cat)
cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')
case "$cmd" in
    *\|*) ;; # real rtk leaves piped/compound shell commands alone
    find\ *|git\ *|ls\ *|sort\ *)
        jq -nc --arg cmd "rtk $cmd" \
            '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecisionReason:"RTK auto-rewrite",updatedInput:{command:$cmd},permissionDecision:"allow"}}'
        ;;
    *) ;; # compound shell command etc. — rtk stays silent
esac
STUB
chmod +x "$stub_dir/rtk"

run_hook() { # $1 = command string (JSON-escaped); stdout = hook output
    printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1" \
        | PATH="$stub_dir:$PATH" bash "$hook"
}

# ---------- 1. Simple find → rewrite forwarded ----------
echo "Test 1: simple find keeps the rtk rewrite"
for cmd in 'find . -name \"*.md\" -type f' 'find /tmp -maxdepth 1 -name x'; do
    out=$(run_hook "$cmd")
    if printf '%s' "$out" | grep -q '"rtk find '; then
        assert_pass "rewrite forwarded: $cmd"
    else
        assert_fail "expected rtk rewrite for '$cmd', got: $out"
    fi
done

# ---------- 2. Compound finds → suppressed ----------
echo "Test 2: compound finds pass through unrewritten (empty output)"
compound_cmds=(
    'find Clippings -name \"*.md\" -not -path \"*/_synthesis/*\" -not -path \"*/_done/*\" -not -name _deferred.md'
    'find . -name \"*.tmp\" -exec rm {} ;'
    'find . -name a -o -name b'
    'find . -name a -a -type f'
    'find . -name \"*.bak\" -delete'
    'find . -path ./skip -prune'
    'find . ! -name keep.md'
    'find . \\\\( -name a -o -name b \\\\)'
    'find . -name \"*.tmp\" -execdir rm {} ;'
)
for cmd in "${compound_cmds[@]}"; do
    set +e
    out=$(run_hook "$cmd")
    rc=$?
    set -e
    if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
        assert_pass "suppressed: $cmd"
    else
        assert_fail "expected empty output rc=0 for '$cmd', got rc=$rc: $out"
    fi
done

# ---------- 3. Non-find rewrites forwarded even with -o-like tokens ----------
echo "Test 3: non-find rewrites untouched"
for cmd in 'git status' 'sort -o out.txt in.txt' 'ls -a /tmp'; do
    out=$(run_hook "$cmd")
    if printf '%s' "$out" | grep -q '"rtk '; then
        assert_pass "rewrite forwarded: $cmd"
    else
        assert_fail "expected rtk rewrite for '$cmd', got: $out"
    fi
done

# ---------- 4. rtk silent (compound shell command) ----------
echo "Test 4: rtk emits nothing → guard emits nothing"
set +e
out=$(run_hook 'find . -name \"*.md\" | head -5')
rc=$?
set -e
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    assert_pass "silent rtk handled"
else
    assert_fail "expected empty rc=0, got rc=$rc: $out"
fi

# ---------- 5. rtk missing → fail-open ----------
echo "Test 5: rtk missing from PATH → fail-open"
empty_dir=$(mktemp -d)
set +e
out=$(printf '{"tool_name":"Bash","tool_input":{"command":"find . -name x"}}' \
    | PATH="$empty_dir:/usr/bin:/bin" bash "$hook" 2>/dev/null)
rc=$?
set -e
rm -rf "$empty_dir"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    assert_pass "missing rtk → empty, exit 0"
else
    assert_fail "expected empty rc=0 without rtk, got rc=$rc: $out"
fi

# ---------- 6. rtk crashes → fail-open ----------
echo "Test 6: rtk crash → fail-open"
crash_dir=$(mktemp -d)
printf '#!/usr/bin/env bash\nexit 1\n' > "$crash_dir/rtk"
chmod +x "$crash_dir/rtk"
set +e
out=$(printf '{"tool_name":"Bash","tool_input":{"command":"find . -name x"}}' \
    | PATH="$crash_dir:$PATH" bash "$hook")
rc=$?
set -e
rm -rf "$crash_dir"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    assert_pass "crashing rtk → empty, exit 0"
else
    assert_fail "expected empty rc=0 on rtk crash, got rc=$rc: $out"
fi

# ---------- 7. Empty stdin ----------
echo "Test 7: empty stdin tolerated"
set +e
out=$(PATH="$stub_dir:$PATH" bash "$hook" </dev/null)
rc=$?
set -e
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    assert_pass "empty stdin → empty, exit 0"
else
    assert_fail "expected empty rc=0 on empty stdin, got rc=$rc: $out"
fi

# ---------- 8. reason text containing "-not" must not suppress ----------
# HIMMEL-264: the guard scans only the rewritten command VALUE. A
# permissionDecisionReason mentioning a rejected token (output-shape
# drift) must not cost the safe rewrite.
echo "Test 8: '-not' in permissionDecisionReason does not suppress a safe rewrite"
reason_dir=$(mktemp -d)
cat > "$reason_dir/rtk" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "hook" ] && [ "${2:-}" = "claude" ] || exit 1
cat >/dev/null
printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecisionReason":"rewrote find; rtk find rejects -not and -exec","updatedInput":{"command":"rtk find . -name x"},"permissionDecision":"allow"}}'
STUB
chmod +x "$reason_dir/rtk"
out=$(printf '{"tool_name":"Bash","tool_input":{"command":"find . -name x"}}' \
    | PATH="$reason_dir:$PATH" bash "$hook")
rm -rf "$reason_dir"
if printf '%s' "$out" | grep -q '"rtk find '; then
    assert_pass "reason-only token did not suppress the rewrite"
else
    assert_fail "expected forwarded rewrite despite '-not' in reason, got: $out"
fi

# ---------- 9. jq broken → grep+sed fallback ----------
# The guard's no-jq contract: extraction falls back to grep+sed on the
# JSON-escaped command value and the verdict must not change.
echo "Test 9: broken jq → fallback still suppresses compound, forwards simple"
nojq_dir=$(mktemp -d)
printf '#!/usr/bin/env bash\nexit 1\n' > "$nojq_dir/jq"
chmod +x "$nojq_dir/jq"
cat > "$nojq_dir/rtk" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "hook" ] && [ "${2:-}" = "claude" ] || exit 1
payload=$(cat)
case "$payload" in
    *_done*)
        printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecisionReason":"RTK auto-rewrite","updatedInput":{"command":"rtk find Clippings -name \"*.md\" -not -path \"*/_done/*\""},"permissionDecision":"allow"}}'
        ;;
    *)
        printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecisionReason":"RTK auto-rewrite","updatedInput":{"command":"rtk find . -name \"*.md\" -type f"},"permissionDecision":"allow"}}'
        ;;
esac
STUB
chmod +x "$nojq_dir/rtk"
set +e
out=$(printf '{"tool_name":"Bash","tool_input":{"command":"find Clippings -name \\"*.md\\" -not -path \\"*/_done/*\\""}}' \
    | PATH="$nojq_dir:$PATH" bash "$hook")
rc=$?
set -e
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    assert_pass "fallback suppressed compound find"
else
    assert_fail "expected empty rc=0 via fallback, got rc=$rc: $out"
fi
out=$(printf '{"tool_name":"Bash","tool_input":{"command":"find . -name \\"*.md\\" -type f"}}' \
    | PATH="$nojq_dir:$PATH" bash "$hook")
if printf '%s' "$out" | grep -q '"rtk find '; then
    assert_pass "fallback forwarded simple find"
else
    assert_fail "expected forwarded rewrite via fallback, got: $out"
fi
rm -rf "$nojq_dir"

# ---------- 10. Trailing payload field after command ----------
# Regression for the old }}-anchored sed stub, which emitted nothing
# (and so false-passed every forwarding test) once the harness appended
# a field after tool_input.command.
echo "Test 10: payload with trailing field still parsed by the stub"
out=$(printf '{"tool_name":"Bash","tool_input":{"command":"find . -name x","description":"trailing field"}}' \
    | PATH="$stub_dir:$PATH" bash "$hook")
if printf '%s' "$out" | grep -q '"rtk find '; then
    assert_pass "trailing field tolerated, rewrite forwarded"
else
    assert_fail "expected forwarded rewrite with trailing field, got: $out"
fi

# ---------- 11. Output-shape drift: command field renamed ----------
# Extraction-failure contract (HIMMEL-264 CR): when neither jq nor the
# grep fallback can extract the command (field renamed/absent), output
# that still contains an `rtk find ` rewrite must be SUPPRESSED — the
# guard could not scan it, and forwarding an unscanned rewrite is the
# original bug. Drifted output with no rtk-find rewrite is forwarded
# verbatim (nothing the guard screens).
echo "Test 11: renamed command field → suppress rtk-find output, forward non-find"
drift_dir=$(mktemp -d)
cat > "$drift_dir/rtk" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "hook" ] && [ "${2:-}" = "claude" ] || exit 1
payload=$(cat)
case "$payload" in
    *find*)
        printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":{"cmd":"rtk find . -name x"},"permissionDecision":"allow"}}'
        ;;
    *)
        printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":{"cmd":"rtk git status"},"permissionDecision":"allow"}}'
        ;;
esac
STUB
chmod +x "$drift_dir/rtk"
set +e
out=$(printf '{"tool_name":"Bash","tool_input":{"command":"find . -name x"}}' \
    | PATH="$drift_dir:$PATH" bash "$hook")
rc=$?
set -e
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    assert_pass "drifted rtk-find output suppressed"
else
    assert_fail "expected empty rc=0 for drifted rtk-find output, got rc=$rc: $out"
fi
out=$(printf '{"tool_name":"Bash","tool_input":{"command":"git status"}}' \
    | PATH="$drift_dir:$PATH" bash "$hook")
if printf '%s' "$out" | grep -q '"rtk git status"'; then
    assert_pass "drifted non-find output forwarded verbatim"
else
    assert_fail "expected forwarded drifted non-find output, got: $out"
fi
rm -rf "$drift_dir"

# ---------- 12. No jq + original command as FIRST "command" pair ----------
# HIMMEL-264 CR: an unanchored first-match fallback would extract the
# ORIGINAL command from a drifted shape that echoes tool_input before
# the rewrite — the compound rtk-find rewrite would then be forwarded
# unscanned. The fallback anchors on `"command":"rtk find ` so it finds
# the rewrite regardless of position and suppresses it.
echo "Test 12: anchored fallback skips a leading original-command pair"
firstpair_dir=$(mktemp -d)
printf '#!/usr/bin/env bash\nexit 1\n' > "$firstpair_dir/jq"
chmod +x "$firstpair_dir/jq"
cat > "$firstpair_dir/rtk" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "hook" ] && [ "${2:-}" = "claude" ] || exit 1
cat >/dev/null
printf '%s' '{"toolInput":{"command":"find . -not -name x"},"hookSpecificOutput":{"hookEventName":"PreToolUse","updatedInput":{"command":"rtk find . -not -name x"},"permissionDecision":"allow"}}'
STUB
chmod +x "$firstpair_dir/rtk"
set +e
out=$(printf '{"tool_name":"Bash","tool_input":{"command":"find . -not -name x"}}' \
    | PATH="$firstpair_dir:$PATH" bash "$hook")
rc=$?
set -e
rm -rf "$firstpair_dir"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    assert_pass "compound rewrite behind a leading original-command pair suppressed"
else
    assert_fail "expected empty rc=0 (anchored fallback), got rc=$rc: $out"
fi

# ---------- summary ----------
echo ""
echo "rtk-hook-guard: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
