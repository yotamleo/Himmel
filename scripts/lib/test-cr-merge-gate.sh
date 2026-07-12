#!/usr/bin/env bash
# Tests for scripts/lib/cr-merge-gate.sh (HIMMEL-936). Hermetic: gh is stubbed.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"

# ── stub gh ──────────────────────────────────────────────────────────────────
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${GH_STUB_LOG:?}"
case "${GH_STUB_MODE:?}" in
  error) exit 1 ;;
esac
case "$1 $2" in
  "pr view")
    # api-error mode: pr view SUCCEEDS, later api calls fail (distinguishes
    # rc=3 selector-unresolvable from rc=0 downstream-API fail-open).
    echo '{"number":42,"headRefOid":"abc123","url":"https://github.com/o/r/pull/42"}' ;;
  "api graphql")
    case "$GH_STUB_MODE" in
      api-error) exit 1 ;;
      unresolved) echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"coderabbitai"}}]}}]}}}}}' ;;
      other-author) echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"someuser"}}]}}]}}}}}' ;;
      *) echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":true,"comments":{"nodes":[{"author":{"login":"coderabbitai"}}]}}]}}}}}' ;;
    esac ;;
  "api repos/o/r/commits/abc123/check-runs"*)
    case "$GH_STUB_MODE" in
      inflight) echo '{"check_runs":[{"name":"CodeRabbit","status":"in_progress","conclusion":null}]}' ;;
      *)        echo '{"check_runs":[{"name":"CodeRabbit","status":"completed","conclusion":"success"}]}' ;;
    esac ;;
  *) echo '{}' ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

# shellcheck disable=SC1091
. "$SCRIPT_DIR/cr-merge-gate.sh"

pass=0; fail=0
t() { # t <name> <expected-rc> — runs cr_merge_gate 42 o/r with current env
  local name="$1" want="$2" rc=0
  export GH_STUB_LOG="$TMP/calls-$name.log"; : > "$GH_STUB_LOG"
  cr_merge_gate 42 o/r >"$TMP/out-$name" 2>"$TMP/err-$name" || rc=$?
  if [ "$rc" = "$want" ]; then pass=$((pass+1)); echo "ok   $name"
  else fail=$((fail+1)); echo "FAIL $name (rc=$rc want=$want)"; sed 's/^/  err: /' "$TMP/err-$name"; fi
}

GH_STUB_MODE=unresolved   t unresolved-cr-thread-blocks 2
GH_STUB_MODE=clean        t resolved-threads-allow 0
GH_STUB_MODE=other-author t other-author-unresolved-allows 0
GH_STUB_MODE=inflight     t checkrun-in-flight-blocks 2
# pr view itself fails -> rc=3 (selector unresolvable; still an allow, but
# lets the hook retry with a better anchor - codex-1/codex-adv-1 CR round)
GH_STUB_MODE=error        t gh-error-selector-unresolvable 3
# pr view succeeds, downstream graphql fails -> plain rc=0 fail-open
GH_STUB_MODE=api-error    t downstream-api-error-fails-open 0

# bypass env short-circuits BEFORE any gh call
GH_STUB_MODE=unresolved CR_MERGE_GATE_OK=1 t bypass-env-allows 0
[ -s "$TMP/calls-bypass-env-allows.log" ] && { echo "FAIL bypass called gh"; fail=$((fail+1)); }
unset CR_MERGE_GATE_OK

GH_STUB_MODE=unresolved CR_PROFILE=none t cr-profile-none-allows 0
[ -s "$TMP/calls-cr-profile-none-allows.log" ] && { echo "FAIL profile-none called gh"; fail=$((fail+1)); }
unset CR_PROFILE

# block reason lands on stdout
grep -qi "unresolved" "$TMP/out-unresolved-cr-thread-blocks" || { echo "FAIL block reason missing"; fail=$((fail+1)); }
# degradation notes land on stderr on both fail-open shapes
grep -qi "degraded" "$TMP/err-gh-error-selector-unresolvable" || { echo "FAIL degradation note missing (rc3)"; fail=$((fail+1)); }
grep -qi "degraded" "$TMP/err-downstream-api-error-fails-open" || { echo "FAIL degradation note missing (rc0)"; fail=$((fail+1)); }

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
