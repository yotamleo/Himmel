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
# Bash 3.2 safe.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRITIC="$SCRIPT_DIR/hermes-critic.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$CRITIC" ] || fail "hermes-critic.sh not found at $CRITIC"
command -v node >/dev/null 2>&1 || fail "node is required for these tests"

work="$(mktemp -d "${TMPDIR:-/tmp}/critic-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# ── stub interpreter: emits $STUB_RESPONSE, exits $STUB_RC ──────────────────
stub="$work/fake-python"
cat > "$stub" <<'EOF'
#!/usr/bin/env bash
if [ -n "${STUB_PROMPT_CAPTURE:-}" ] && [ -n "${HERMES_PROMPT_FILE:-}" ]; then
  pf="$HERMES_PROMPT_FILE"
  command -v cygpath >/dev/null 2>&1 && pf="$(cygpath -u "$pf")"
  cp "$pf" "$STUB_PROMPT_CAPTURE"
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

echo "PASS: all hermes-critic.sh tests passed." >&2
exit 0
