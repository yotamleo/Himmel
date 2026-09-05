#!/usr/bin/env bash
# Smoke test for block-graphify-egress.sh's COMMAND-POSITION gate (HIMMEL-1180).
# Coverage for the corpus x provider policy decision itself lives in
# scripts/guardrails/test-graphify-fence.sh (invokes graphify-fence.sh
# directly); this file only pins the HOOK's own match/no-match boundary.
set -uo pipefail

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

T="$(mktemp -d "${TMPDIR:-/tmp}/himmel-block-graphify-egress.XXXXXX")"
trap 'rm -rf "$T"' EXIT
PROJECT="$T/project"
mkdir -p "$PROJECT/scripts/hooks" "$PROJECT/scripts/guardrails" "$T/luna"
: > "$T/luna/journal.md"
# block-graphify-egress.sh resolves its fence relative to its OWN location
# (${BASH_SOURCE[0]}), not $CLAUDE_PROJECT_DIR — so the hook AND lib.sh AND
# a fake fence all have to live together under one tree for a fixture fence
# to actually be the one reached. Copy the real hook + lib.sh (the code under
# test) alongside a fake fence that always allows and announces itself — this
# suite is about whether the HOOK reaches the fence at all, not what the
# fence decides once reached (that's test-graphify-fence.sh's job).
HOOK="$PROJECT/scripts/hooks/block-graphify-egress.sh"
cp "$HOOKS_DIR/block-graphify-egress.sh" "$HOOK"
cp "$HOOKS_DIR/../guardrails/lib.sh" "$PROJECT/scripts/guardrails/lib.sh"
cat > "$PROJECT/scripts/guardrails/graphify-fence.sh" <<'FENCE_EOF'
#!/usr/bin/env bash
echo "FENCE_INVOKED"
exit 0
FENCE_EOF
chmod +x "$PROJECT/scripts/guardrails/graphify-fence.sh"

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

run_hook() {
    local cmd="$1"
    local payload
    payload=$(jq -n --arg cmd "$cmd" '{tool_name:"Bash",tool_input:{command:$cmd}}')
    printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$PROJECT" bash "$HOOK"
}

out="$(run_hook "grep -rn graphify $T/luna" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q FENCE_INVOKED; then
    ok "a bare mention (grep -rn graphify .) does not reach the fence"
else
    bad "bare mention: rc=$rc out=$out"
fi

out="$(run_hook "graphify update $T/luna/journal.md --backend claude" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q FENCE_INVOKED; then
    ok "a direct invocation reaches the fence"
else
    bad "direct invocation: rc=$rc out=$out"
fi

# NOTE: CMDPOS's wrapper set (guard_cmdpos_grammar) is sudo/env/cmd/
# powershell|pwsh only -- NOT timeout (block-destructive-commands.sh never
# wrapped timeout either; that is graphify-fence.sh's own classify_clause,
# a separate, richer implementation, not this shared regex).
out="$(run_hook "env FOO=1 graphify update $T/luna/journal.md --backend claude" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q FENCE_INVOKED; then
    ok "an env-wrapped invocation reaches the fence"
else
    bad "env-wrapped invocation: rc=$rc out=$out"
fi

out="$(run_hook "sudo graphify update $T/luna/journal.md --backend claude" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q FENCE_INVOKED; then
    ok "a sudo-wrapped invocation reaches the fence"
else
    bad "sudo-wrapped invocation: rc=$rc out=$out"
fi

# CR round 1 regression pin (codex-1): `timeout` is not one of CMDPOS's
# shared wrappers (block-destructive-commands.sh never covered it either),
# so this hook rebuilds CMDPOS locally with a timeout alternative -- see its
# own comment. The OLD naive substring match caught this case; losing it
# would be a real regression, unlike the accepted bash -c residual below.
out="$(run_hook "timeout 10 graphify update $T/luna/journal.md --backend claude" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q FENCE_INVOKED; then
    ok "a timeout-wrapped invocation reaches the fence"
else
    bad "timeout-wrapped invocation: rc=$rc out=$out"
fi

out="$(run_hook "timeout -k 5 30 sudo graphify update $T/luna/journal.md --backend claude" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q FENCE_INVOKED; then
    ok "a timeout-with-flags + sudo wrapped invocation reaches the fence"
else
    bad "timeout+flags+sudo wrapped invocation: rc=$rc out=$out"
fi

# CR round 2 regression pin (codex-1): `command`/`exec` are transparent
# no-argument wrappers the OLD substring match also caught.
out="$(run_hook "command graphify update $T/luna/journal.md --backend claude" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q FENCE_INVOKED; then
    ok "a command-wrapped invocation reaches the fence"
else
    bad "command-wrapped invocation: rc=$rc out=$out"
fi

out="$(run_hook "exec graphify update $T/luna/journal.md --backend claude" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q FENCE_INVOKED; then
    ok "an exec-wrapped invocation reaches the fence"
else
    bad "exec-wrapped invocation: rc=$rc out=$out"
fi

# Documented, accepted residual (HIMMEL-1180): a quoted-payload wrapper is
# NOT unwrapped by this fast gate -- pinned here so the residual stays a
# known, intentional gap rather than an undocumented drift.
out="$(run_hook "bash -c 'graphify update $T/luna/journal.md --backend claude'" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q FENCE_INVOKED; then
    ok "a bash -c wrapped invocation does NOT reach the fence (documented residual)"
else
    bad "bash -c residual pin: rc=$rc out=$out"
fi

out="$(run_hook "cd $T/luna" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q FENCE_INVOKED; then
    ok "an unrelated command does not reach the fence"
else
    bad "unrelated command: rc=$rc out=$out"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
