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

# HIMMEL-2615 regression pin: `setsid` and the repo's own quiet runner
# (scripts/quiet-run.sh <label> -- <cmd...>) previously carried a graphify
# invocation straight past this gate at rc=0 -- CMDPOS never listed `setsid`,
# and nothing here understood a runner's `--` tail, so `exec bash "$FENCE"`
# was never reached and the corpus x provider decision below (deny/allow) was
# never even asked. This suite only pins the fence-reached/not-reached
# boundary (see file header); the real deny verdict for these exact shapes is
# covered against the LIVE fence in test-graphify-fence.sh's own HIMMEL-2615
# block. These cases are the same "reaches the fence" idiom as the sudo/env/
# timeout/command/exec cases above -- a graphify command wrapped this way
# must reach the fence just like those, so the real fence gets the chance to
# deny it.
# HIMMEL-1430: every FENCE_INVOKED check in this block (and its negations)
# uses a here-string (`grep -q ... <<< "$out"`), not `producer | grep -q`.
# This file carries `set -uo pipefail`; under pipefail, `grep -q` exits on
# its first match, the producer takes SIGPIPE writing the rest, and the
# PIPELINE's status becomes the SIGPIPE failure rather than grep's match --
# `! producer | grep -q X` can then invert on a large `$out`. `$out` here is
# only a few lines of captured hook output, far below the here-string size
# cap that wedges Git Bash (HIMMEL-2027), so the here-string is the right
# remedy - same reasoning test-graphify-fence.sh's own grepq() helper exists
# for.
out="$(run_hook "setsid graphify update $T/luna/journal.md --backend claude" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q FENCE_INVOKED <<< "$out"; then
    ok "a setsid-wrapped invocation reaches the fence"
else
    bad "setsid-wrapped invocation: rc=$rc out=$out"
fi

out="$(run_hook "bash scripts/quiet-run.sh lbl -- graphify update $T/luna/journal.md --backend claude" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q FENCE_INVOKED <<< "$out"; then
    ok "a quiet-run.sh-tailed invocation reaches the fence"
else
    bad "quiet-run.sh-tailed invocation: rc=$rc out=$out"
fi

# The exact incident shape from the ticket: setsid + nohup + the quiet runner
# all stacked in front of the graphify invocation.
out="$(run_hook "setsid nohup bash scripts/quiet-run.sh lbl -- graphify update $T/luna/journal.md --backend claude" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q FENCE_INVOKED <<< "$out"; then
    ok "the setsid+nohup+quiet-run.sh incident shape reaches the fence"
else
    bad "setsid+nohup+quiet-run.sh incident shape: rc=$rc out=$out"
fi

# Negative controls: the HIMMEL-2615 widening above must not route a
# non-graphify command through either new path, and must not regress
# HIMMEL-1180's bare-mention exemption.
out="$(run_hook "setsid ls -la $T" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && ! grep -q FENCE_INVOKED <<< "$out"; then
    ok "a setsid-wrapped non-graphify command does not reach the fence"
else
    bad "setsid non-graphify: rc=$rc out=$out"
fi

out="$(run_hook "bash scripts/quiet-run.sh lbl -- ls $T" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && ! grep -q FENCE_INVOKED <<< "$out"; then
    ok "a quiet-run.sh-tailed non-graphify command does not reach the fence"
else
    bad "quiet-run.sh non-graphify tail: rc=$rc out=$out"
fi

out="$(run_hook "grep -rn graphify ." 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && ! grep -q FENCE_INVOKED <<< "$out"; then
    ok "a bare mention (grep -rn graphify .) does not reach the fence (HIMMEL-1180 survives the widening)"
else
    bad "bare mention (grep .): rc=$rc out=$out"
fi

# CR round-1 regression [codex-1]: QUIETRUN_TAIL originally required
# whitespace right after `.sh`, so a QUOTED script path (`bash
# "scripts/quiet-run.sh" ...`) had the closing quote sitting there instead of
# whitespace and matched neither prefilter - the hook exited 0 without ever
# asking the fence (which does strip quotes and would deny). Widened to drop
# the separator class; pin both quoting shapes here.
out="$(run_hook "bash \"scripts/quiet-run.sh\" lbl -- graphify update $T/luna/journal.md --backend claude" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q FENCE_INVOKED <<< "$out"; then
    ok "a double-quoted quiet-run.sh script path reaches the fence [codex-1]"
else
    bad "double-quoted quiet-run.sh script path: rc=$rc out=$out"
fi

out="$(run_hook "bash 'scripts/quiet-run.sh' lbl -- graphify update $T/luna/journal.md --backend claude" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q FENCE_INVOKED <<< "$out"; then
    ok "a single-quoted quiet-run.sh script path reaches the fence [codex-1]"
else
    bad "single-quoted quiet-run.sh script path: rc=$rc out=$out"
fi

# CR round 2 [codex-1]: this hook's own QUIETRUN_TAIL prefilter does not
# examine quote balance at all - it only asks whether a `quiet-run.sh` token
# is followed (anywhere later) by a graphify-shaped token, so the
# adjacent-quoted-segments label that broke the FENCE's per-quote-type parity
# guard (`'"'"a -- b"` - see graphify-fence.sh's own comment and
# test-graphify-fence.sh's S23 for the data-vs-operator explanation) never
# had to defeat anything here; it already reaches the fence unmodified. Pinned
# anyway so this exact incident shape has a standing regression test on BOTH
# layers, not just the fence side.
out="$(run_hook "bash scripts/quiet-run.sh '\"'\"a -- b\" -- graphify update $T/luna/journal.md --backend claude" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q FENCE_INVOKED <<< "$out"; then
    ok "the CR-round-2 adjacent-quoted-segments label reaches the fence [codex-1 round-2]"
else
    bad "adjacent-quoted-segments label: rc=$rc out=$out"
fi

# NEGATIVE control: dropping the whitespace requirement above must not widen
# QUIETRUN_TAIL into matching a bare MENTION of both words with no runner
# tail at all. Here `graphify` appears BEFORE `quiet-run.sh` in the text (no
# `--` tail follows quiet-run.sh), so this stays outside QUIETRUN_TAIL's own
# ordered shape (quiet-run.sh, THEN later a graphify token) - asserting the
# honest observed behaviour rather than forcing a shape the regex was never
# asked to produce.
out="$(run_hook "grep -n graphify scripts/quiet-run.sh" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && ! grep -q FENCE_INVOKED <<< "$out"; then
    ok "a quiet-run.sh + graphify MENTION with no runner tail does not reach the fence"
else
    bad "quiet-run.sh/graphify mention, no tail: rc=$rc out=$out"
fi

out="$(run_hook "echo \"graphify is cool\"" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && ! grep -q FENCE_INVOKED <<< "$out"; then
    ok "a bare mention (echo) does not reach the fence"
else
    bad "bare mention (echo): rc=$rc out=$out"
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
