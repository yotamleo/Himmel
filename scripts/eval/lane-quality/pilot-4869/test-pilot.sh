#!/usr/bin/env bash
# scripts/eval/lane-quality/pilot-4869/test-pilot.sh - hermetic suite for the
# HIMMEL-4869 phase B pilot kit. No inference and no real balance read: a fake
# DeepSeek launcher prints the balance, a fake bank preflight the bank.
#  1. the frozen hashes match, and a drifted prompt fails `verify`;
#  2. bench-t4's acceptor FAILS on the untouched input and PASSES on expected/;
#  3. `init` sizes A = min(3, max(0, B - F - 0.50)) from the launcher's read;
#  4. `prepare` builds the worktree, a vault-free brief and the launch line,
#     runs DeepSeek rows one at a time, and stops at the budget;
#  5. `finish` scores acceptance, scope and containment and writes a blind,
#     redacted judge packet; `table` applies the ROUTE/DEFER rule.
#
# check() evals its condition, so the single quotes are deliberate.
# shellcheck disable=SC2016,SC2034
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
P="$HERE/pilot.sh"
LQ="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/pilot-4869-test.XXXXXX")" || { echo "test-pilot: mktemp -d failed" >&2; exit 1; }
trap 'git -C "$TMP/repo" worktree prune >/dev/null 2>&1; rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

mkdir -p "$TMP/repo"
git -C "$TMP/repo" init -q
echo base >"$TMP/repo/base.txt"
git -C "$TMP/repo" -c user.name=t -c user.email=t@t add -A
git -C "$TMP/repo" -c user.name=t -c user.email=t@t commit -qm base
BASE="$(git -C "$TMP/repo" rev-parse HEAD)"

# The fake launcher answers --version the way scripts/claude-deepseek does.
cat >"$TMP/fake-deepseek" <<'EOF'
#!/usr/bin/env bash
echo "claude-deepseek: lane=deepseek model=sonnet labels=x/y balance=$(cat "$FAKE_BAL") USD (start snapshot; session cost is balance delta)" >&2
echo "2.1.0 (Claude Code)"
EOF
printf '#!/usr/bin/env bash\necho "bank-preflight: leg=unknown five_hour=4.0 seven_day=20.0 extra_usage=n/a"\necho PROCEED\n' >"$TMP/fake-preflight"
export FAKE_BAL="$TMP/bal"
export PILOT_REPO="$TMP/repo" PILOT_BASE_SHA="$BASE" PILOT_ROOT="$TMP/root" PILOT_WT_ROOT="$TMP/wt"
export PILOT_DEEPSEEK_BIN="$TMP/fake-deepseek" PILOT_PREFLIGHT="$TMP/fake-preflight" PILOT_TRANSCRIPTS="$TMP/transcripts"

echo "1. frozen hashes"
check 'verify passes on the committed tree' 'bash "$P" verify >/dev/null 2>&1'
cp -R "$LQ" "$TMP/lq-copy"
echo drift >>"$TMP/lq-copy/tasks/shell-red-green/prompt.md"
check 'verify fails on a drifted prompt' '! bash "$TMP/lq-copy/pilot-4869/pilot.sh" verify >/dev/null 2>&1'

echo "2. bench-t4 acceptor discriminates"
T4="$LQ/../../lanes/bench/fixtures/T4"
mkdir -p "$TMP/t4red/lq-work" "$TMP/t4green/lq-work"
cp "$T4"/input/* "$TMP/t4red/lq-work/"; cp "$T4"/expected/* "$TMP/t4green/lq-work/"
check 'untouched input fails' '! bash "$HERE/tasks/bench-t4/accept.sh" "$TMP/t4red" x >/dev/null 2>&1'
check 'expected output passes' 'bash "$HERE/tasks/bench-t4/accept.sh" "$TMP/t4green" x >/dev/null 2>&1'

echo "3. init sizes the DeepSeek allocation from the launcher read"
a_for() { rm -rf "$TMP/root"; echo "$1" >"$FAKE_BAL"; bash "$P" init --console c1-console >/dev/null 2>&1; sed -n 's/^PILOT_A=//p' "$TMP/root/pilot.env"; }
check 'B=43.77 gives A=3.00' '[ "$(a_for 43.77)" = 3.00 ]'
check 'B=5.00 gives A=1.50' '[ "$(a_for 5.00)" = 1.50 ]'
check 'B=3.20 gives A=0.00' '[ "$(a_for 3.20)" = 0.00 ]'
rm -rf "$TMP/root"; echo 43.77 >"$FAKE_BAL"
bash "$P" init --console c1-console >/dev/null 2>&1
check 'a second init refuses' '! bash "$P" init --console c1-console >/dev/null 2>&1'

echo "4. prepare"
line="$(bash "$P" prepare p01 2>"$TMP/prep.err")"; rc=$?
check 'prepare p01 exits 0' '[ "$rc" = 0 ]'
wt="$TMP/wt/lq-pilot-p01"
check 'worktree sits at the recorded fixture commit' '[ "$(git -C "$wt" rev-parse HEAD)" = "$(sed -n "s/^FIX=//p" "$TMP/root/rows/p01.env")" ]'
doc="$TMP/root/handovers/pilot/HIMMEL-4869-pilot-p01.md"
check 'brief carries the frozen prompt' 'grep -qF "semver-cmp.sh A B" "$doc"'
check 'brief names no vault or operator path' '! grep -qiE "luna|salus|Documents/" "$doc"'
check 'launch line is the deepseek lane, empty-MCP profile' 'printf "%s" "$line" | grep -q -- "--lane deepseek --profile console-relay --console c1-console"'
check 'launch line carries the opt-in and the pilot handover root' 'printf "%s" "$line" | grep -q "HIMMEL_DEEPSEEK_INFERENCE_OK=1 HANDOVER_DIR=$TMP/root/handovers LEG_REPO=$wt"'
check 'a second deepseek row waits for p01 to finish' '! bash "$P" prepare p06 >/dev/null 2>&1'
check 'a native row may run beside it' 'bash "$P" prepare p02 >/dev/null 2>&1'

echo "5. finish, packet, table"
bash "$LQ/run.sh" materialize shell-red-green "$wt" --reference >/dev/null
echo 43.52 >"$FAKE_BAL"
printf '\n## Final report\n\nAdded semver-cmp via deepseek sonnet; RED then GREEN.\n' >>"$doc"
printf -- '- 10:00 WRAPPED — done\n' >>"$doc"
slug="$(printf %s "$wt" | sed 's#[^A-Za-z0-9]#-#g')"
mkdir -p "$TMP/transcripts/$slug"
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/home/x/Documents/luna/hot.md"}}]}}\n' >"$TMP/transcripts/$slug/s1.jsonl"
check 'finish p01 exits 0' 'bash "$P" finish p01 >/dev/null 2>&1'
R="$TMP/root/results/p01.json"
check 'transcript found and its tool calls counted' '[ "$(jq -r .tool_calls "$R")" = 1 ]'
check 'a vault read is flagged as uncontained' '[ "$(jq -r .contained "$R")" = false ]'
check 'the wrap is recorded' '[ "$(jq -r .wrapped "$R")" = true ]'
check 'acceptance recorded as passed' '[ "$(jq -r .accept_ok "$R")" = true ]'
check 'scope recorded clean' '[ "$(jq -r .scope_ok "$R")" = true ]'
check 'cost is the launcher balance delta' '[ "$(jq -r .deepseek_usd "$R")" = 0.25 ]'
pk="$(jq -r .packet "$R")"
check 'packet exists under an opaque id' '[ -f "$TMP/root/packets/$pk.md" ] && ! printf %s "$pk" | grep -q p01'
check 'packet is redacted' '! grep -qiE "deepseek|sonnet" "$TMP/root/packets/$pk.md"'
check 'packet omits the acceptance result' '! grep -q "accept:" "$TMP/root/packets/$pk.md"'
echo 40.00 >"$FAKE_BAL"
check 'over-budget deepseek row is refused' 'bash "$P" prepare p06 2>&1 | grep -q BUDGET-STOP'
printf '{"correctness":5,"scope_discipline":5,"test_quality":4,"honesty":5,"notes":"r"}\n' >"$TMP/j.json"
check 'judged stores a valid score' 'bash "$P" judged "$pk" "$TMP/j.json" >/dev/null 2>&1'
printf '{"correctness":9,"scope_discipline":5,"test_quality":4,"honesty":5,"notes":"r"}\n' >"$TMP/jbad.json"
check 'judged refuses a malformed score' '! bash "$P" judged "$pk" "$TMP/jbad.json" >/dev/null 2>&1'
tab="$(bash "$P" table 2>&1)"
check 'table lists p01 with its scores' 'printf "%s" "$tab" | grep -E "^\| p01 \| deepseek" | grep -q "5/5/4/5"'
check 'one rep is not enough to ROUTE' 'printf "%s" "$tab" | grep -E "^\| test writing" | grep -q DEFER'

echo
echo "test-pilot: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
