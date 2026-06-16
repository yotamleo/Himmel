#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-no-headless-gemini.sh.
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/check-no-headless-gemini.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/scripts/hooks" "$TMP/docs" "$TMP/handovers" "$TMP/.agents" "$TMP/.claude/commands"

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

run_hook() {
    (cd "$TMP" && bash "$HOOK" "$@" >/dev/null 2>&1)
    echo "$?"
}

FAILED=0

# T1: script with gemini -p → BLOCK
cat > "$TMP/run.sh" <<'EOF'
#!/usr/bin/env bash
gemini -p "summarize this"
EOF
rc=$(run_hook "run.sh")
assert_rc "T1 gemini -p in script" 1 "$rc"

# T2: script with gemini --prompt → BLOCK
cat > "$TMP/prompt.sh" <<'EOF'
#!/usr/bin/env bash
gemini --prompt "summarize this"
EOF
rc=$(run_hook "prompt.sh")
assert_rc "T2 gemini --prompt" 1 "$rc"

# T3: script with gemini --bg → BLOCK
cat > "$TMP/bg.sh" <<'EOF'
#!/usr/bin/env bash
gemini --bg "summarize this"
EOF
rc=$(run_hook "bg.sh")
assert_rc "T3 gemini --bg" 1 "$rc"

# T4: interactive `gemini "$prompt"` (no flag) → CLEAN
cat > "$TMP/interactive.sh" <<'EOF'
#!/usr/bin/env bash
gemini "$prompt"
EOF
rc=$(run_hook "interactive.sh")
assert_rc "T4 interactive gemini" 0 "$rc"

# T5: same-line opt-in marker → CLEAN
cat > "$TMP/optin_inline.sh" <<'EOF'
#!/usr/bin/env bash
gemini -p "$prompt"  # headless-gemini-ok: quota billing intentional
EOF
rc=$(run_hook "optin_inline.sh")
assert_rc "T5 same-line opt-in" 0 "$rc"

# T6: preceding-line opt-in marker → CLEAN
cat > "$TMP/optin_above.sh" <<'EOF'
#!/usr/bin/env bash
# headless-gemini-ok: scripted batch job, quota accepted
gemini --prompt "$prompt"
EOF
rc=$(run_hook "optin_above.sh")
assert_rc "T6 preceding-line opt-in" 0 "$rc"

# T7: opt-in 2 lines above (TOO FAR) → BLOCK
cat > "$TMP/optin_far.sh" <<'EOF'
#!/usr/bin/env bash
# headless-gemini-ok: scripted batch job
# unrelated comment
gemini --prompt "$prompt"
EOF
rc=$(run_hook "optin_far.sh")
assert_rc "T7 opt-in 2 lines above does NOT cover" 1 "$rc"

# T8: docs/ exempt → CLEAN
cat > "$TMP/docs/billing.md" <<'EOF'
Avoid `gemini -p` in scripts unless you've accepted the quota implications.
EOF
rc=$(run_hook "docs/billing.md")
assert_rc "T8 docs/ exempt" 0 "$rc"

# T9: handovers/ exempt → CLEAN
cat > "$TMP/handovers/note.md" <<'EOF'
TODO: audit `gemini --prompt` call sites.
EOF
rc=$(run_hook "handovers/note.md")
assert_rc "T9 handovers/ exempt" 0 "$rc"

# T10: .agents/ exempt (vendored) → CLEAN
cat > "$TMP/.agents/compress.py" <<'EOF'
subprocess.run(["gemini", "--prompt"], input=prompt)
EOF
rc=$(run_hook ".agents/compress.py")
assert_rc "T10 .agents/ exempt" 0 "$rc"

# T11: .claude/commands/*.md exempt → CLEAN
cat > "$TMP/.claude/commands/oz-offload.md" <<'EOF'
Offload target is `warp agent run`, NOT `gemini -p`. `gemini -p` is not in normal usage.
EOF
rc=$(run_hook ".claude/commands/oz-offload.md")
assert_rc "T11 .claude/commands/*.md exempt" 0 "$rc"

# T12: CLAUDE.md exempt → CLEAN
cat > "$TMP/CLAUDE.md" <<'EOF'
Headless mode (`gemini -p`) eats quota silently.
EOF
rc=$(run_hook "CLAUDE.md")
assert_rc "T12 CLAUDE.md exempt" 0 "$rc"

# T13: self-exempt hook + test → CLEAN
cat > "$TMP/scripts/hooks/check-no-headless-gemini.sh" <<'EOF'
PATTERN='gemini -p'
EOF
rc=$(run_hook "scripts/hooks/check-no-headless-gemini.sh")
assert_rc "T13 self-exempt hook" 0 "$rc"

cat > "$TMP/scripts/hooks/test-check-no-headless-gemini.sh" <<'EOF'
echo "gemini -p test"
EOF
rc=$(run_hook "scripts/hooks/test-check-no-headless-gemini.sh")
assert_rc "T13b self-exempt test" 0 "$rc"

# T14: ATTACKER PATH — basename matches exempt but path doesn't → BLOCK
mkdir -p "$TMP/vendor/evil"
cat > "$TMP/vendor/evil/check-no-headless-gemini.sh" <<'EOF'
gemini --prompt "$prompt"
EOF
rc=$(run_hook "vendor/evil/check-no-headless-gemini.sh")
assert_rc "T14 attacker basename wrong path BLOCKS" 1 "$rc"

# T15: word-boundary — `gemini --prompts` (not a real flag) → CLEAN
cat > "$TMP/prompts.sh" <<'EOF'
gemini --prompts "$prompt"
EOF
rc=$(run_hook "prompts.sh")
assert_rc "T15 --prompts does NOT match --prompt" 0 "$rc"

# T16: word-boundary — `mygemini -p` (different command) → CLEAN
cat > "$TMP/mygemini.sh" <<'EOF'
mygemini -p "$prompt"
EOF
rc=$(run_hook "mygemini.sh")
assert_rc "T16 mygemini not matched as gemini" 0 "$rc"

# T17: no files passed → CLEAN
rc=$(run_hook)
assert_rc "T17 no files" 0 "$rc"

# T18: stderr names file + line
out=$(cd "$TMP" && bash "$HOOK" "run.sh" 2>&1 1>/dev/null) || true
case "$out" in
    *"run.sh:"*) echo "PASS T18 stderr names file:line" ;;
    *) echo "FAIL T18 stderr did not name file:line"; FAILED=$((FAILED + 1)) ;;
esac

if [ "$FAILED" -gt 0 ]; then
    echo "---"
    echo "FAIL $FAILED case(s)"
    exit 1
fi
echo "---"
echo "PASS all cases"
exit 0
