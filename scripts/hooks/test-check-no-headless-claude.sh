#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-no-headless-claude.sh.
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/check-no-headless-claude.sh"
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

# T1: script with claude -p → BLOCK
cat > "$TMP/run.sh" <<'EOF'
#!/usr/bin/env bash
claude -p "summarize this"
EOF
rc=$(run_hook "run.sh")
assert_rc "T1 claude -p in script" 1 "$rc"

# T2: script with claude --print → BLOCK
cat > "$TMP/print.sh" <<'EOF'
#!/usr/bin/env bash
claude --print "summarize this"
EOF
rc=$(run_hook "print.sh")
assert_rc "T2 claude --print" 1 "$rc"

# T3: script with claude --bg → BLOCK
cat > "$TMP/bg.sh" <<'EOF'
#!/usr/bin/env bash
claude --bg "summarize this"
EOF
rc=$(run_hook "bg.sh")
assert_rc "T3 claude --bg" 1 "$rc"

# T4: interactive `claude "$prompt"` (no flag) → CLEAN
cat > "$TMP/interactive.sh" <<'EOF'
#!/usr/bin/env bash
claude "$prompt"
EOF
rc=$(run_hook "interactive.sh")
assert_rc "T4 interactive claude" 0 "$rc"

# T5: same-line opt-in marker → CLEAN
cat > "$TMP/optin_inline.sh" <<'EOF'
#!/usr/bin/env bash
claude -p "$prompt"  # headless-claude-ok: agent-sdk billing intentional
EOF
rc=$(run_hook "optin_inline.sh")
assert_rc "T5 same-line opt-in" 0 "$rc"

# T6: preceding-line opt-in marker → CLEAN
cat > "$TMP/optin_above.sh" <<'EOF'
#!/usr/bin/env bash
# headless-claude-ok: scripted batch job, separate bucket accepted
claude --print "$prompt"
EOF
rc=$(run_hook "optin_above.sh")
assert_rc "T6 preceding-line opt-in" 0 "$rc"

# T7: opt-in 2 lines above (TOO FAR) → BLOCK
cat > "$TMP/optin_far.sh" <<'EOF'
#!/usr/bin/env bash
# headless-claude-ok: scripted batch job
# unrelated comment
claude --print "$prompt"
EOF
rc=$(run_hook "optin_far.sh")
assert_rc "T7 opt-in 2 lines above does NOT cover" 1 "$rc"

# T8: docs/ exempt → CLEAN
cat > "$TMP/docs/billing.md" <<'EOF'
Avoid `claude -p` in scripts unless you've accepted the post-2026-06-15 billing split.
EOF
rc=$(run_hook "docs/billing.md")
assert_rc "T8 docs/ exempt" 0 "$rc"

# T9: handovers/ exempt → CLEAN
cat > "$TMP/handovers/note.md" <<'EOF'
TODO: audit `claude --print` call sites before 2026-06-15.
EOF
rc=$(run_hook "handovers/note.md")
assert_rc "T9 handovers/ exempt" 0 "$rc"

# T10: .agents/ exempt (vendored) → CLEAN
cat > "$TMP/.agents/compress.py" <<'EOF'
subprocess.run(["claude", "--print"], input=prompt)
EOF
rc=$(run_hook ".agents/compress.py")
assert_rc "T10 .agents/ exempt" 0 "$rc"

# T11: .claude/commands/*.md exempt → CLEAN
cat > "$TMP/.claude/commands/oz-offload.md" <<'EOF'
Offload target is `warp agent run`, NOT `claude -p`. `claude -p` is not in normal usage.
EOF
rc=$(run_hook ".claude/commands/oz-offload.md")
assert_rc "T11 .claude/commands/*.md exempt" 0 "$rc"

# T12: CLAUDE.md exempt → CLEAN
cat > "$TMP/CLAUDE.md" <<'EOF'
Headless mode (`claude -p`) bills on the Agent SDK bucket from 2026-06-15.
EOF
rc=$(run_hook "CLAUDE.md")
assert_rc "T12 CLAUDE.md exempt" 0 "$rc"

# T13: self-exempt hook + test → CLEAN
cat > "$TMP/scripts/hooks/check-no-headless-claude.sh" <<'EOF'
PATTERN='claude -p'
EOF
rc=$(run_hook "scripts/hooks/check-no-headless-claude.sh")
assert_rc "T13 self-exempt hook" 0 "$rc"

cat > "$TMP/scripts/hooks/test-check-no-headless-claude.sh" <<'EOF'
echo "claude -p test"
EOF
rc=$(run_hook "scripts/hooks/test-check-no-headless-claude.sh")
assert_rc "T13b self-exempt test" 0 "$rc"

# T14: ATTACKER PATH — basename matches exempt but path doesn't → BLOCK
mkdir -p "$TMP/vendor/evil"
cat > "$TMP/vendor/evil/check-no-headless-claude.sh" <<'EOF'
claude --print "$prompt"
EOF
rc=$(run_hook "vendor/evil/check-no-headless-claude.sh")
assert_rc "T14 attacker basename wrong path BLOCKS" 1 "$rc"

# T15: word-boundary — `claude --printer` (not a real flag) → CLEAN
cat > "$TMP/printer.sh" <<'EOF'
claude --printer "$prompt"
EOF
rc=$(run_hook "printer.sh")
assert_rc "T15 --printer does NOT match --print" 0 "$rc"

# T16: word-boundary — `myclaude -p` (different command) → CLEAN
cat > "$TMP/myclaude.sh" <<'EOF'
myclaude -p "$prompt"
EOF
rc=$(run_hook "myclaude.sh")
assert_rc "T16 myclaude not matched as claude" 0 "$rc"

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
