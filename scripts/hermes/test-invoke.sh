#!/usr/bin/env bash
# scripts/hermes/test-invoke.sh — stub-based tests for invoke.sh (HIMMEL-273).
#
# No live hermes calls: a fake interpreter is injected via HERMES_PY (the
# repo pattern from scripts/gemini/test-invoke.sh, adapted — gemini stubs via
# PATH, but invoke.sh resolves an absolute interpreter, so the override env
# var is the stub seam). Runs anywhere, including machines without hermes.
#
# Set HERMES_LIVE_TEST=1 to additionally run one real one-shot through the
# installed hermes (costs one NIM free-tier call).
#
# Bash 3.2 safe.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INVOKE="$SCRIPT_DIR/invoke.sh"
fail() { echo "FAIL: $1" >&2; exit 1; }

[ -f "$INVOKE" ] || fail "invoke.sh not found at $INVOKE"

# ── stub interpreter ────────────────────────────────────────────────────────
# Records its argv + the HERMES_* env contract to a file, then prints a canned
# response. invoke.sh treats it exactly like the hermes venv python.
stub_dir="$(mktemp -d "${TMPDIR:-/tmp}/hermes-test.XXXXXX")"
trap 'rm -rf "$stub_dir"' EXIT
stub="$stub_dir/fake-python"
cat > "$stub" <<'EOF'
#!/usr/bin/env bash
{
  echo "argv:$*"
  echo "model:${HERMES_ONESHOT_MODEL:-}"
  echo "toolsets:${HERMES_ONESHOT_TOOLSETS:-}"
  echo "promptfile:${HERMES_PROMPT_FILE:-}"
  if [ -n "${HERMES_PROMPT_FILE:-}" ]; then
    pf="${HERMES_PROMPT_FILE}"
    command -v cygpath >/dev/null 2>&1 && pf="$(cygpath -u "$pf")"
    echo "prompt:$(cat "$pf")"
  fi
} > "${STUB_CAPTURE:?}"
printf '%s' "${STUB_RESPONSE:-stub-ok}"
exit "${STUB_RC:-0}"
EOF
chmod +x "$stub"
export HERMES_PY="$stub"

# 1. Positional prompt reaches the interpreter via the prompt file.
echo "test: positional prompt" >&2
export STUB_CAPTURE="$stub_dir/cap1"
out="$(bash "$INVOKE" "hello critic")" || fail "positional prompt: non-zero exit"
[ "$out" = "stub-ok" ] || fail "positional prompt: unexpected stdout: $out"
grep -q "^prompt:hello critic$" "$STUB_CAPTURE" || fail "positional prompt: prompt not delivered via file"
grep -q "^toolsets:todo$" "$STUB_CAPTURE" || fail "positional prompt: default toolsets is not todo"
echo "  ok" >&2

# 2. Stdin prompt.
echo "test: stdin prompt" >&2
export STUB_CAPTURE="$stub_dir/cap2"
out="$(printf 'from stdin' | bash "$INVOKE" -)" || fail "stdin prompt: non-zero exit"
grep -q "^prompt:from stdin$" "$STUB_CAPTURE" || fail "stdin prompt: prompt not delivered"
echo "  ok" >&2

# 3. --prompt-file pass-through (no copy through argv).
echo "test: --prompt-file" >&2
export STUB_CAPTURE="$stub_dir/cap3"
printf 'big pack payload' > "$stub_dir/pack.txt"
bash "$INVOKE" --prompt-file "$stub_dir/pack.txt" >/dev/null || fail "--prompt-file: non-zero exit"
grep -q "^prompt:big pack payload$" "$STUB_CAPTURE" || fail "--prompt-file: payload not delivered"
echo "  ok" >&2

# 4. --model + --toolsets reach the env contract.
echo "test: --model/--toolsets passthrough" >&2
export STUB_CAPTURE="$stub_dir/cap4"
bash "$INVOKE" --model some/model --toolsets coding "x" >/dev/null || fail "passthrough: non-zero exit"
grep -q "^model:some/model$" "$STUB_CAPTURE" || fail "passthrough: model missing"
grep -q "^toolsets:coding$" "$STUB_CAPTURE" || fail "passthrough: toolsets missing"
echo "  ok" >&2

# 5. Empty prompt errors out (exit 2), interpreter never invoked.
echo "test: empty prompt rejected" >&2
export STUB_CAPTURE="$stub_dir/cap5"
printf '' | bash "$INVOKE" - >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] || fail "empty prompt: expected exit 2, got $rc"
[ ! -f "$STUB_CAPTURE" ] || fail "empty prompt: interpreter was invoked"
echo "  ok" >&2

# 6. Stub failure rc propagates.
echo "test: interpreter rc propagates" >&2
export STUB_CAPTURE="$stub_dir/cap6"
STUB_RC=7 bash "$INVOKE" "x" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 7 ] || fail "rc propagation: expected 7, got $rc"
echo "  ok" >&2

# 7. Optional live smoke (one NIM free-tier call) — opt-in only.
if [ "${HERMES_LIVE_TEST:-0}" = "1" ]; then
    echo "test: LIVE one-shot (nemotron nano)" >&2
    unset HERMES_PY
    out="$(bash "$INVOKE" --model nvidia/nemotron-3-nano-30b-a3b "Reply with exactly the single word PONG and nothing else.")" \
        || fail "live: non-zero exit"
    case "$out" in
        *PONG*) echo "  ok: live response contained PONG" >&2 ;;
        *) fail "live: response did not contain PONG (got: $out)" ;;
    esac
fi

echo "PASS: all invoke.sh tests passed." >&2
exit 0
