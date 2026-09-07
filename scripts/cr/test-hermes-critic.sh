#!/usr/bin/env bash
# scripts/cr/test-hermes-critic.sh — stub-based tests for hermes-critic.sh
# (HIMMEL-273). The critic model is stubbed via HERMES_PY (see
# scripts/hermes/test-invoke.sh); a throwaway git repo provides the diff.
#
# Proves the four contract points:
#   1. clean review        → exit 0, passed=true JSON on stdout
#   2. fail-closed         → model says passed=true but lists a security
#                            concern → forced passed=false, exit 1
#   3. garbage response    → exit 3 (fail-open to other review routes)
#   4. transport failure   → exit 3
#
# Cases 1-7 pass NO --route/--implementer: they assert the DEFAULT route is
# hermes (HIMMEL-2017 operator ruling), which is what keeps them on the stub.
# Cases 8-9 cover the opt-in `--route claude` path with `claude` stubbed on
# PATH — never the real binary, which would spend the subscription bank.
#
# Bash 3.2 safe.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRITIC="$SCRIPT_DIR/hermes-critic.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$CRITIC" ] || fail "hermes-critic.sh not found at $CRITIC"
command -v node >/dev/null 2>&1 || fail "node is required for these tests"

work="$(mktemp -d "${TMPDIR:-/tmp}/critic-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# HIMMEL-2241: hermes-critic.sh spawns the REAL scripts/hermes/invoke.sh, which
# appends flow-run lifecycle rows. HERMES_PY stubs the MODEL, not the wrapper,
# so without this the rows land in the PRODUCTION ledger
# (~/.himmel/flow-runs.jsonl) and the outcome=error cases below page
# HimmelFlowRunError for runs that never happened. Redirect into this test's
# own scratch dir — the HIMMEL-2130 pattern.
export HIMMEL_FLOW_RUNS_LEDGER="$work/flow-runs.jsonl"

# ── stub interpreter: emits $STUB_RESPONSE, exits $STUB_RC ──────────────────
stub="$work/fake-python"
cat > "$stub" <<'EOF'
#!/usr/bin/env bash
if [ -n "${STUB_PROMPT_CAPTURE:-}" ] && [ -n "${HERMES_PROMPT_FILE:-}" ]; then
  pf="$HERMES_PROMPT_FILE"
  command -v cygpath >/dev/null 2>&1 && pf="$(cygpath -u "$pf")"
  cp "$pf" "$STUB_PROMPT_CAPTURE"
fi
if [ -n "${STUB_MODEL_CAPTURE:-}" ]; then
  printf '%s\t%s' "${HERMES_ONESHOT_MODEL:-}" "${HERMES_ONESHOT_PROVIDER:-}" > "$STUB_MODEL_CAPTURE"
fi
printf '%s' "${STUB_RESPONSE:-}"
exit "${STUB_RC:-0}"
EOF
chmod +x "$stub"
export HERMES_PY="$stub"

# ── throwaway repo with a base commit + one change on a branch ──────────────
repo="$work/repo"
mkdir -p "$repo"
git -C "$repo" init -q -b main
git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
printf 'echo hello\n' > "$repo/app.sh"
git -C "$repo" add app.sh
git -C "$repo" -c user.email=t@t -c user.name=t commit -q -m change
base="$(git -C "$repo" rev-parse HEAD~1)"

run_critic() {  # $1 = canned response, $2 = stub rc; echoes critic stdout; returns critic rc
    STUB_RESPONSE="$1" STUB_RC="${2:-0}" bash "$CRITIC" --repo "$repo" --base "$base" --goal "test goal"
}

# 1. Clean verdict → exit 0.
echo "test: clean pass" >&2
out="$(run_critic '{"passed": true, "security_concerns": [], "logic_errors": [], "architectural_mismatches": [], "suggestions": ["fine"], "summary": "ok"}')"
rc=$?
[ "$rc" -eq 0 ] || fail "clean pass: expected exit 0, got $rc"
printf '%s' "$out" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{const j=JSON.parse(d); if(j.passed!==true)process.exit(1)})' \
    || fail "clean pass: stdout JSON did not have passed=true"
echo "  ok" >&2

# 2. Fail-closed: model lies passed=true with a security concern → exit 1, passed=false.
echo "test: fail-closed override" >&2
out="$(run_critic '{"passed": true, "security_concerns": ["RCE via curl|bash"], "logic_errors": [], "architectural_mismatches": [], "suggestions": [], "summary": "looks fine to me"}')"
rc=$?
[ "$rc" -eq 1 ] || fail "fail-closed: expected exit 1, got $rc"
printf '%s' "$out" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{const j=JSON.parse(d); if(j.passed!==false)process.exit(1)})' \
    || fail "fail-closed: passed was not forced to false"
echo "  ok" >&2

# 3. Garbage response → exit 3 (fail-open). Diagnostic must reach stderr.
echo "test: garbage response fail-open" >&2
run_critic 'I cannot review this right now, sorry.' >/dev/null 2>"$work/err3"
rc=$?
[ "$rc" -eq 3 ] || fail "garbage: expected exit 3, got $rc"
echo "  ok" >&2

# 4. Transport failure (stub rc!=0) → exit 3 with a WARN naming the rc.
echo "test: transport failure fail-open" >&2
run_critic '' 9 >/dev/null 2>"$work/err4"
rc=$?
[ "$rc" -eq 3 ] || fail "transport: expected exit 3, got $rc"
grep -q "WARN hermes route failed (rc=9)" "$work/err4" || fail "transport: stderr did not carry the WARN + rc"
echo "  ok" >&2

# 5. Empty diff → exit 2.
echo "test: empty diff rejected" >&2
STUB_RESPONSE='{}' bash "$CRITIC" --repo "$repo" --base HEAD >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] || fail "empty diff: expected exit 2, got $rc"
echo "  ok" >&2

# 6. Pack truncation: tiny budget → run still succeeds (SIGPIPE tolerated)
#    and the pack carries the truncation sentinel.
echo "test: pack truncation sentinel" >&2
export STUB_PROMPT_CAPTURE="$work/pack-capture"
out="$(STUB_RESPONSE='{"passed": true, "security_concerns": [], "logic_errors": [], "architectural_mismatches": [], "suggestions": [], "summary": "ok"}' \
    bash "$CRITIC" --repo "$repo" --base "$base" --goal "test goal" --max-pack-bytes 200)"
rc=$?
unset STUB_PROMPT_CAPTURE
[ "$rc" -eq 0 ] || fail "truncation: expected exit 0, got $rc"
grep -q "CONTEXT PACK TRUNCATED AT 200 BYTES" "$work/pack-capture" || fail "truncation: sentinel missing from pack"
echo "  ok" >&2

# 7. Master-default repo, NO --base → auto-resolves the diff base via the
#    master arm of the merge-base fallback chain (HIMMEL-297). With no `main`
#    anywhere, origin/main / origin/master / main all miss and `master` is the
#    arm that resolves; reaching the stub at all (exit 0) proves a base was
#    found rather than the "could not resolve a diff base" exit 2.
echo "test: master-default auto-resolve base" >&2
mrepo="$work/mrepo"
mkdir -p "$mrepo"
git -C "$mrepo" init -q -b master
git -C "$mrepo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
git -C "$mrepo" checkout -q -b feat/x
printf 'echo hi\n' > "$mrepo/app.sh"
git -C "$mrepo" add app.sh
git -C "$mrepo" -c user.email=t@t -c user.name=t commit -q -m change
out="$(STUB_RESPONSE='{"passed": true, "security_concerns": [], "logic_errors": [], "architectural_mismatches": [], "suggestions": [], "summary": "ok"}' \
    bash "$CRITIC" --repo "$mrepo" --goal "test goal")"
rc=$?
[ "$rc" -eq 0 ] || fail "master-default auto-resolve: expected exit 0 (base resolved via master arm), got $rc"
echo "  ok" >&2

# 8. --route claude drives the claude CLI with the isolation + billing flags.
#    `claude` is STUBBED on PATH: the real binary would spend the subscription
#    bank on every suite run (HIMMEL-128) and review the fixture for real.
echo "test: claude route uses the claude CLI with isolation flags" >&2
bindir="$work/bin"
mkdir -p "$bindir"
cat > "$bindir/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CLAUDE_ARGV_CAPTURE"
printf '%s' '{"type":"result","subtype":"success","result":"{\"passed\": true, \"security_concerns\": [], \"logic_errors\": [], \"architectural_mismatches\": [], \"suggestions\": [], \"summary\": \"ok\"}"}'
EOF
chmod +x "$bindir/claude"
# The claude route bank-preflights before spending (HIMMEL-128). Point it at a
# healthy fixture cache and skip the producer refresh, so the suite stays
# offline and fast; case 8b drives the exhausted-bank branch.
# primaries_refreshed_at must be a LIVE stamp: a stale cache yields BANK-STALE,
# which is a fail-open verdict and would let case 8b pass for the wrong reason.
bank_now="$(date +%s)"
bank_cache="$work/bank-ok.json"
printf '{"five_hour":{"utilization":5},"seven_day":{"utilization":5},"primaries_refreshed_at":%s}' "$bank_now" > "$bank_cache"
export CADENCE_BANK_SKIP_REFRESH=1 CADENCE_BANK_CACHE="$bank_cache"
export CADENCE_BANK_LEDGER="$work/bank-ledger.jsonl"

out="$(CLAUDE_ARGV_CAPTURE="$work/claude-argv" PATH="$bindir:$PATH" \
    bash "$CRITIC" --repo "$repo" --base "$base" --goal "test goal" --route claude)"
rc=$?
[ "$rc" -eq 0 ] || fail "claude route: expected exit 0, got $rc"
printf '%s' "$out" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{const j=JSON.parse(d); if(j.passed!==true)process.exit(1)})' \
    || fail "claude route: envelope unwrap did not yield passed=true"
# Assert the security-critical flags AND their values, paired and in order —
# the flag name alone would pass on a reordered or wrongly-valued argv.
argv_joined="$(tr '\n' ' ' < "$work/claude-argv")"
for pair in "-p" "--output-format json" "--permission-mode plan" "--max-turns 1" "--strict-mcp-config" '--mcp-config {"mcpServers":{}}'; do
    case "$argv_joined" in
        *"$pair "*) ;;
        *) fail "claude route: expected '$pair' in claude argv, got: $argv_joined" ;;
    esac
done
# --tools must be present AND its value empty (the whole built-in toolset off).
# Checked on the raw one-arg-per-line capture, since an empty arg vanishes in
# the joined form.
awk 'p==1{ if($0!="") exit 1; p=2; next } /^--tools$/{ p=1 } END{ if(p!=2) exit 1 }' "$work/claude-argv" \
    || fail "claude route: --tools missing or non-empty (built-in tools not disabled)"

# A --model value containing spaces must arrive as ONE argv entry, never split
# into extra flags — flags appended after the isolation ones could override them.
: > "$work/claude-argv"
CLAUDE_ARGV_CAPTURE="$work/claude-argv" PATH="$bindir:$PATH" \
    bash "$CRITIC" --repo "$repo" --base "$base" --goal "test goal" --route claude \
    --model 'evil --tools default --permission-mode bypassPermissions' >/dev/null 2>&1
grep -qx -- "evil --tools default --permission-mode bypassPermissions" "$work/claude-argv" \
    || fail "claude route: a spaced --model value was not passed as a single argv entry"
grep -qx -- "bypassPermissions" "$work/claude-argv" \
    && fail "claude route: a crafted --model value injected extra CLI flags"
echo "  ok" >&2

# 8b. Exhausted bank → the claude route refuses BEFORE launching claude, and
#     fails open at exit 3 so the caller falls back to another reviewer.
echo "test: claude route refuses an exhausted bank" >&2
printf '{"five_hour":{"utilization":99},"seven_day":{"utilization":99},"primaries_refreshed_at":%s}' "$(date +%s)" > "$work/bank-full.json"
: > "$work/claude-argv"
CADENCE_BANK_CACHE="$work/bank-full.json" CLAUDE_ARGV_CAPTURE="$work/claude-argv" PATH="$bindir:$PATH" \
    bash "$CRITIC" --repo "$repo" --base "$base" --goal "test goal" --route claude >/dev/null 2>"$work/err8b"
rc=$?
[ "$rc" -eq 3 ] || fail "exhausted bank: expected exit 3 (fail-open), got $rc"
[ ! -s "$work/claude-argv" ] || fail "exhausted bank: claude was launched anyway"
grep -q "bank preflight returned SKIPPED-BANK" "$work/err8b" || fail "exhausted bank: stderr did not name the bank refusal"
echo "  ok" >&2

# 9. --route claude, claude transport failure → exit 3 carrying CLAUDE's rc
#    (not the node unwrap's, which is always 0).
echo "test: claude route propagates the CLI rc" >&2
cat > "$bindir/claude" <<'EOF'
#!/usr/bin/env bash
echo "boom" >&2
exit 7
EOF
chmod +x "$bindir/claude"
CLAUDE_ARGV_CAPTURE="$work/claude-argv" PATH="$bindir:$PATH" \
    bash "$CRITIC" --repo "$repo" --base "$base" --goal "test goal" --route claude >/dev/null 2>"$work/err9"
rc=$?
[ "$rc" -eq 3 ] || fail "claude route failure: expected exit 3, got $rc"
grep -q "WARN claude route failed (rc=7)" "$work/err9" || fail "claude route failure: stderr did not carry the WARN + claude's rc"
echo "  ok" >&2

# 10. Implementer-derived routing. The two stubs make the chosen route
#     observable: the HERMES_PY stub answers the hermes route, the PATH `claude`
#     shim answers the claude route, and each records that it was the one called.
echo "test: implementer-derived routing picks the cross-family reviewer" >&2
cat > "$bindir/claude" <<'EOF'
#!/usr/bin/env bash
printf 'claude' > "$ROUTE_WITNESS"
printf '%s' '{"type":"result","result":"{\"passed\": true, \"security_concerns\": [], \"logic_errors\": [], \"architectural_mismatches\": [], \"suggestions\": [], \"summary\": \"claude\"}"}'
EOF
chmod +x "$bindir/claude"
hermes_witness_stub="$work/fake-python-witness"
cat > "$hermes_witness_stub" <<'EOF'
#!/usr/bin/env bash
printf 'hermes' > "$ROUTE_WITNESS"
printf '%s' '{"passed": true, "security_concerns": [], "logic_errors": [], "architectural_mismatches": [], "suggestions": [], "summary": "hermes"}'
EOF
chmod +x "$hermes_witness_stub"

route_of() {  # $1.. = extra critic args (plus any env already exported); echoes the route that ran
    : > "$work/route-witness"
    ROUTE_WITNESS="$work/route-witness" HERMES_PY="$hermes_witness_stub" PATH="$bindir:$PATH" \
        bash "$CRITIC" --repo "$repo" --base "$base" --goal "test goal" "$@" >/dev/null 2>&1
    cat "$work/route-witness"
}

got=$(route_of)
[ "$got" = "hermes" ] || fail "default route: expected hermes, got '${got:-<none>}'"
got=$(route_of --implementer hermes)
[ "$got" = "claude" ] || fail "--implementer hermes: expected claude, got '${got:-<none>}'"
# HIMMEL-2059: the hermes reviewer now defaults to the critics.json-pinned
# codex model (gpt-6-astra as of HIMMEL-2546; gpt-5.6-sol before it — codex
# family either way), so a codex implementer is SAME-family by default — the
# cross-family guarantee sends this to claude, not hermes (pre-HIMMEL-2059
# this asserted hermes, back when the default rode the ox-alpha profile
# default, a different family from codex).
got=$(route_of --implementer codex)
[ "$got" = "claude" ] || fail "--implementer codex (gpt-6-astra default, same-family): expected claude, got '${got:-<none>}'"
got=$(route_of --implementer other)
[ "$got" = "hermes" ] || fail "--implementer other: expected hermes, got '${got:-<none>}'"
echo "  ok" >&2

# 11. Family fallback: a codex-family hermes reviewer must NOT review a
#     codex-implemented diff — the cross-family guarantee sends it to claude.
echo "test: codex-family hermes reviewer flips a codex implementer to claude" >&2
got=$(HERMES_CRITIC_FAMILY=codex route_of --implementer codex)
[ "$got" = "claude" ] || fail "codex-family hermes + --implementer codex: expected claude, got '${got:-<none>}'"
got=$(HERMES_CRITIC_MODEL=gpt-5.6-sol route_of --implementer codex)
[ "$got" = "claude" ] || fail "gpt-5.6-sol hermes model + --implementer codex: expected claude (inferred family), got '${got:-<none>}'"
# Provider-qualified ids must infer the same family as their bare form.
got=$(HERMES_CRITIC_MODEL=openai-codex/gpt-5.6-sol route_of --implementer codex)
[ "$got" = "claude" ] || fail "provider-qualified codex model + --implementer codex: expected claude, got '${got:-<none>}'"
echo "  ok" >&2

# 12. Invalid combinations → exit 2, before any reviewer is called.
echo "test: invalid routing combinations are refused" >&2
: > "$work/route-witness"
ROUTE_WITNESS="$work/route-witness" HERMES_PY="$hermes_witness_stub" HERMES_CRITIC_FAMILY=claude PATH="$bindir:$PATH" \
    bash "$CRITIC" --repo "$repo" --base "$base" --goal "test goal" --implementer claude >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] || fail "claude implementer + claude-family hermes: expected exit 2 (no cross-family route), got $rc"
[ -z "$(cat "$work/route-witness")" ] || fail "claude implementer + claude-family hermes: a reviewer ran despite the refusal"
STUB_RESPONSE='{}' bash "$CRITIC" --repo "$repo" --base "$base" --implementer bogus >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] || fail "unknown --implementer: expected exit 2, got $rc"
STUB_RESPONSE='{}' bash "$CRITIC" --repo "$repo" --base "$base" --route bogus >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] || fail "unknown --route: expected exit 2, got $rc"
# An unrecognised HERMES_CRITIC_FAMILY must fail closed, not read as "some
# other family" and quietly satisfy the cross-family check.
STUB_RESPONSE='{}' HERMES_CRITIC_FAMILY=cdoex bash "$CRITIC" --repo "$repo" --base "$base" --implementer codex >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] || fail "unknown HERMES_CRITIC_FAMILY: expected exit 2, got $rc"
echo "  ok" >&2

# 12b. Every rc=3 path logs the raw head, malformed JSON included.
echo "test: malformed JSON reports the raw head too" >&2
run_critic '{"passed": true, "security_concerns": [oops]}' >/dev/null 2>"$work/err12b"
rc=$?
[ "$rc" -eq 3 ] || fail "malformed JSON: expected exit 3, got $rc"
grep -q "Raw head:" "$work/err12b" || fail "malformed JSON: stderr did not carry the raw head"
echo "  ok" >&2

# 13. --route both merges the two verdicts (union of findings, passed=false
#     wins), and a FAILED hermes second pass never alters the claude verdict.
echo "test: --route both merges, and drops a failed second pass" >&2
cat > "$bindir/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s' '{"type":"result","result":"{\"passed\": true, \"security_concerns\": [], \"logic_errors\": [], \"architectural_mismatches\": [], \"suggestions\": [\"from-claude\"], \"summary\": \"claude\"}"}'
EOF
chmod +x "$bindir/claude"
out="$(STUB_RESPONSE='{"passed": false, "security_concerns": [], "logic_errors": ["from-hermes"], "architectural_mismatches": [], "suggestions": [], "summary": "hermes"}' \
    PATH="$bindir:$PATH" bash "$CRITIC" --repo "$repo" --base "$base" --goal "test goal" --route both)"
rc=$?
[ "$rc" -eq 1 ] || fail "route both: expected exit 1 (passed=false wins), got $rc"
printf '%s' "$out" | grep -q "from-claude" || fail "route both: the claude suggestions were dropped from the merge"
printf '%s' "$out" | grep -q "from-hermes" || fail "route both: the hermes logic_errors were dropped from the merge"
# Failed second pass (stub rc!=0) that still printed a body → verdict unchanged.
out="$(STUB_RESPONSE='{"passed": false, "security_concerns": [], "logic_errors": ["from-failed-hermes"], "architectural_mismatches": [], "suggestions": [], "summary": "hermes"}' STUB_RC=9 \
    PATH="$bindir:$PATH" bash "$CRITIC" --repo "$repo" --base "$base" --goal "test goal" --route both)"
rc=$?
[ "$rc" -eq 0 ] || fail "route both with a failed second pass: expected the claude verdict (exit 0), got $rc"
printf '%s' "$out" | grep -q "from-failed-hermes" && fail "route both: a transport-failed second pass altered the claude verdict"
# A parseable-but-empty second verdict ({}) is not a verdict: it must not be
# merged in, or the summary advertises a second pass that said nothing.
out="$(STUB_RESPONSE='{}' PATH="$bindir:$PATH" \
    bash "$CRITIC" --repo "$repo" --base "$base" --goal "test goal" --route both)"
rc=$?
[ "$rc" -eq 0 ] || fail "route both with an empty second verdict: expected the claude verdict (exit 0), got $rc"
printf '%s' "$out" | grep -q "hermes second pass" && fail "route both: an empty {} second verdict was merged as a real pass"
# A FAILED primary must skip the second pass entirely: the run exits 3 either
# way, so invoking hermes would be a paid call whose verdict is then discarded.
cat > "$bindir/claude" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
chmod +x "$bindir/claude"
: > "$work/route-witness"
ROUTE_WITNESS="$work/route-witness" HERMES_PY="$hermes_witness_stub" PATH="$bindir:$PATH" \
    bash "$CRITIC" --repo "$repo" --base "$base" --goal "test goal" --route both >/dev/null 2>&1
rc=$?
[ "$rc" -eq 3 ] || fail "route both with a failed primary: expected exit 3, got $rc"
[ -z "$(cat "$work/route-witness")" ] || fail "route both: the second pass ran despite a failed primary (paid call, discarded verdict)"
echo "  ok" >&2

# 14. HIMMEL-2059: default (no --model, no HERMES_CRITIC_MODEL) resolves to
#     the critics.json-pinned model (gpt-6-astra as of HIMMEL-2546), with
#     --provider openai-codex forced (family inference -> codex) — CR critics
#     no longer ride the himmel_agent hermes profile default.
echo "test: default hermes model pins gpt-6-astra (HIMMEL-2059/HIMMEL-2546)" >&2
STUB_MODEL_CAPTURE="$work/model-capture" \
    run_critic '{"passed": true, "security_concerns": [], "logic_errors": [], "architectural_mismatches": [], "suggestions": [], "summary": "ok"}' >/dev/null
rc=$?
[ "$rc" -eq 0 ] || fail "default model: expected exit 0, got $rc"
captured="$(cat "$work/model-capture" 2>/dev/null)"
expected="$(printf 'gpt-6-astra\topenai-codex')"
[ "$captured" = "$expected" ] \
    || fail "default model: expected '$expected' (model<TAB>provider), got '$captured'"
echo "  ok" >&2

# 15. HERMES_CRITIC_MODEL override still wins over the critics.json default,
#     and does not force a provider for a non-codex-family model id.
echo "test: HERMES_CRITIC_MODEL override wins over the pinned default" >&2
STUB_MODEL_CAPTURE="$work/model-capture2" HERMES_CRITIC_MODEL=some-other-model \
    run_critic '{"passed": true, "security_concerns": [], "logic_errors": [], "architectural_mismatches": [], "suggestions": [], "summary": "ok"}' >/dev/null
rc=$?
[ "$rc" -eq 0 ] || fail "override model: expected exit 0, got $rc"
captured2="$(cat "$work/model-capture2" 2>/dev/null)"
expected2="$(printf 'some-other-model\t')"
[ "$captured2" = "$expected2" ] \
    || fail "override model: expected '$expected2' (model<TAB>, no forced provider), got '$captured2'"
echo "  ok" >&2

echo "PASS: all hermes-critic.sh tests passed." >&2
exit 0
