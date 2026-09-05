#!/usr/bin/env bash
# shellcheck disable=SC2034 # CAF_* globals configure sourced filter calls.
# Hermetic tests for codex-arg-filter.sh (HIMMEL-999). The filter cases are
# cross-checked against test-dispatch-codex-exec.sh — the exec lane's
# messages must stay byte-identical (that suite is the extraction proof);
# THIS suite pins the lib's own contract + the WSL-lane parameterization.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/codex-arg-filter.sh"

fails=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; fails=$((fails + 1)); }

run_filter() {  # run_filter <args...> — runs in a subshell, prints RC + globals
  (
    # shellcheck disable=SC1090
    . "$LIB"
    if codex_filter_passthrough_args "$@" 2>"$TMP/err"; then
      echo "rc=0"
      echo "model=$CAF_HAVE_MODEL sandbox=$CAF_HAVE_SANDBOX effort=$CAF_REASONING_EFFORT"
      if [ "${#CAF_NEW_ARGS[@]}" -gt 0 ]; then printf 'arg:%s\n' "${CAF_NEW_ARGS[@]}"; fi
    else
      echo "rc=1"
    fi
  )
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "test: clean prompt words pass through"
OUT="$(run_filter "do" the task --json)"
case "$OUT" in *"rc=0"*) pass "clean args accepted";; *) fail "clean args refused: $OUT";; esac
case "$OUT" in *"arg:do"*"arg:--json"*) pass "args preserved in order";; *) fail "args mangled: $OUT";; esac

echo "test: resume refused"
OUT="$(run_filter resume --all)"
case "$OUT" in *"rc=1"*) pass "resume refused";; *) fail "resume allowed";; esac
grep -q "the lane dispatches fresh runs only" "$TMP/err" || fail "resume message missing"

echo "test: --background refused"
OUT="$(run_filter --background hi)"
case "$OUT" in *"rc=1"*) pass "--background refused";; *) fail "--background allowed";; esac

echo "test: -c/--config refused"
OUT="$(run_filter -c model_reasoning_effort=high hi)"
case "$OUT" in *"rc=1"*) pass "-c refused";; *) fail "-c allowed";; esac

echo "test: danger-full-access refused (two-token form)"
OUT="$(run_filter --sandbox danger-full-access hi)"
case "$OUT" in *"rc=1"*) pass "danger sandbox refused";; *) fail "danger sandbox allowed";; esac

echo "test: --model detected"
OUT="$(run_filter --model gpt-5.5-codex hi)"
case "$OUT" in *"model=1"*) pass "model detected";; *) fail "model not detected: $OUT";; esac

echo "test: --reasoning-effort validated + stripped"
OUT="$(run_filter --reasoning-effort xhigh "do" it)"
case "$OUT" in *"effort=xhigh"*) pass "effort captured";; *) fail "effort not captured: $OUT";; esac
case "$OUT" in *"arg:--reasoning-effort"*) fail "effort flag leaked into args";; *) pass "effort flag stripped";; esac

echo "test: bad --reasoning-effort refused"
OUT="$(run_filter --reasoning-effort turbo hi)"
case "$OUT" in *"rc=1"*) pass "bad effort refused";; *) fail "bad effort allowed";; esac

echo "test: trailing bare --reasoning-effort refused"
OUT="$(run_filter hi --reasoning-effort)"
case "$OUT" in *"rc=1"*) pass "trailing effort refused";; *) fail "trailing effort allowed";; esac

echo "test: unknown dash flag hits the allow-list catch-all"
OUT="$(run_filter --frobnicate hi)"
case "$OUT" in *"rc=1"*) pass "catch-all refused";; *) fail "catch-all allowed";; esac

echo "test: message parameterization (WSL-lane hints)"
(
  # shellcheck disable=SC1090
  . "$LIB"
  CAF_SELF_NAME="dispatch-codex-wsl.sh"
  CAF_SCOPE_NOUN="clone"
  CAF_CONTAINER_FLAG="--clone"
  CAF_ADDDIR_HINT="the containment check covers only the dispatched clone"
  codex_filter_passthrough_args --cd /tmp hi 2>"$TMP/err2"
) || true
if grep -q "^dispatch-codex-wsl.sh: workspace-redirect flag '--cd' refused - the wrapper owns the clone (pass it via --clone)$" "$TMP/err2"; then
  pass "parameterized redirect message"
else
  fail "parameterized redirect message wrong: $(cat "$TMP/err2")"
fi

echo "test: default messages are the exec lane's exact text"
(
  # shellcheck disable=SC1090
  . "$LIB"
  codex_filter_passthrough_args --add-dir /x hi 2>"$TMP/err3"
) || true
if grep -q "^dispatch-codex-exec.sh: --add-dir refused - the ACL preflight covers only the dispatched worktree$" "$TMP/err3"; then
  pass "default add-dir message byte-identical"
else
  fail "default add-dir message drifted: $(cat "$TMP/err3")"
fi

echo
if [ "$fails" -gt 0 ]; then echo "$fails failure(s)" >&2; exit 1; fi
echo "all tests passed"
