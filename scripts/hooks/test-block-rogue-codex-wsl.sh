#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2181,SC2016 # compact status assertions; SC2016: raw-shape command strings are intentionally single-quoted literals.
# Tests for block-rogue-codex-wsl.sh (HIMMEL-999 B3).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/block-rogue-codex-wsl.sh"

fails=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; fails=$((fails + 1)); }

run_hook() {  # run_hook <tool_name> <command-string>
  # node first: it is a guaranteed repo dependency; python3 on this fleet
  # can be the flaky Windows Store stub.
  printf '{"tool_name":"%s","tool_input":{"command":%s}}' "$1" "$(printf '%s' "$2" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>console.log(JSON.stringify(d)))' 2>/dev/null || printf '%s' "$2" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" | bash "$HOOK" >/dev/null 2>"$ERR"
  RC=$?
}
ERR="$(mktemp)"
trap 'rm -f "$ERR"' EXIT

run_hook Bash 'wsl -d Ubuntu -- bash -lc "cd /home/u/work && codex exec -s workspace-write do it"'
[ "$RC" -eq 2 ] && pass "raw wsl codex exec blocked" || fail "raw shape allowed (rc=$RC)"
grep -q "dispatch-codex-wsl.sh" "$ERR" || fail "refusal does not name the chokepoint"

run_hook Bash 'bash scripts/codex/dispatch-codex-wsl.sh --distro Ubuntu --clone /home/u/work/himmel --brief-file b.md'
[ "$RC" -eq 0 ] && pass "chokepoint invocation allowed" || fail "chokepoint blocked (rc=$RC)"

run_hook Bash 'wsl -d Ubuntu -- bash -lc "codex exec evil" # dispatch-codex-wsl.sh'
[ "$RC" -eq 2 ] && pass "comment-spoofed chokepoint name still blocked" || fail "comment spoof bypassed the guard (rc=$RC)"

run_hook Bash 'wsl.exe -d Ubuntu -- codex --version'
[ "$RC" -eq 0 ] && pass "codex without exec allowed" || fail "diagnostics blocked (rc=$RC)"

run_hook Bash 'git commit -m "feat: block rogue wsl codex exec dispatch"'
[ "$RC" -eq 0 ] && pass "tokens in quoted commit message allowed" || fail "commit message false positive (rc=$RC)"

run_hook Bash 'grep -rn "wsl codex exec" scripts/hooks/testdata/'
[ "$RC" -eq 0 ] && pass "tokens in grep pattern allowed" || fail "grep pattern false positive (rc=$RC)"

run_hook Bash 'echo hello'
[ "$RC" -eq 0 ] && pass "token-free command allowed" || fail "token-free blocked (rc=$RC)"

# panel codex-2: wsl/codex/exec as benign ARGUMENTS (not command position)
# must NOT block - bare whitespace is no longer a command-position separator.
run_hook Bash 'echo wsl codex exec'
[ "$RC" -eq 0 ] && pass "benign echo with wsl/codex args allowed" || fail "echo wsl codex exec false-positive blocked (rc=$RC)"
# ...but a real separator (&&, |, ;) before wsl still lands in command position.
run_hook Bash 'true && wsl -d Ubuntu -- bash -lc "codex exec do it"'
[ "$RC" -eq 2 ] && pass "wsl after && separator still blocked" || fail "wsl after && bypassed (rc=$RC)"

run_hook PowerShell 'wsl -d Ubuntu -- bash -lc "codex exec do it"'
[ "$RC" -eq 2 ] && pass "PowerShell raw shape blocked" || fail "PowerShell raw shape allowed (rc=$RC)"

run_hook Bash 'WSL.exe -d Ubuntu -- bash -lc "codex exec do it"'
[ "$RC" -eq 2 ] && pass "uppercase WSL.exe raw shape blocked" || fail "uppercase WSL bypassed the guard (rc=$RC)"

# codex-adv command-position bypasses (HIMMEL-999): subshell / command-subst /
# backtick / path-qualified basename must all still land in command position.
run_hook Bash '(wsl -d Ubuntu -- bash -lc "codex exec do it")'
[ "$RC" -eq 2 ] && pass "subshell-grouped raw shape blocked" || fail "subshell (wsl bypassed (rc=$RC)"

run_hook Bash 'out=$(wsl -d Ubuntu -- bash -lc "codex exec do it")'
[ "$RC" -eq 2 ] && pass "command-substitution raw shape blocked" || fail "command-subst wsl bypassed (rc=$RC)"

run_hook Bash 'echo `wsl -d Ubuntu -- bash -lc "codex exec do it"`'
[ "$RC" -eq 2 ] && pass "backtick raw shape blocked" || fail "backtick wsl bypassed (rc=$RC)"

run_hook Bash '/mnt/c/Windows/System32/wsl.exe -d Ubuntu -- bash -lc "codex exec do it"'
[ "$RC" -eq 2 ] && pass "path-qualified wsl.exe raw shape blocked" || fail "absolute-path wsl.exe bypassed (rc=$RC)"

# Quoted COMMAND NAME (panel HIMMEL-999): the quote-strip erases 'wsl'/"wsl",
# but the shell still runs it. The quoted-name checks must catch these while
# the quoted-DATA false-positive tests above (commit msg / grep pattern) stay
# allowed.
run_hook Bash "'wsl' -d Ubuntu -- bash -lc \"codex exec do it\""
[ "$RC" -eq 2 ] && pass "single-quoted command-name blocked" || fail "'wsl' quoted name bypassed (rc=$RC)"

run_hook Bash '"wsl" -d Ubuntu -- bash -lc "codex exec do it"'
[ "$RC" -eq 2 ] && pass "double-quoted command-name blocked" || fail "double-quoted wsl name bypassed (rc=$RC)"

run_hook PowerShell '& "C:\Windows\System32\wsl.exe" -d Ubuntu -- codex exec hi'
[ "$RC" -eq 2 ] && pass "PowerShell &-call quoted path wsl.exe blocked" || fail "PS call-operator wsl bypassed (rc=$RC)"

CODEX_WSL_RAW_OK=1 run_hook Bash 'wsl -d Ubuntu -- bash -lc "codex exec do it"'
[ "$RC" -eq 0 ] && pass "CODEX_WSL_RAW_OK bypass" || fail "bypass ignored (rc=$RC)"

# jq-missing behaviors: PATH stripped to a stub dir holding only the tools
# the hook needs minus jq. cp (not ln -s: MSYS symlinks are unreliable) +
# skip-guard when the stub dir cannot be materialized.
STUBBIN="$(mktemp -d)"
STUB_OK=1
for t in bash cat printf grep sed head tail tr; do
  p="$(command -v "$t" 2>/dev/null)" && cp "$p" "$STUBBIN/$t" 2>/dev/null || STUB_OK=0
done
if [ "$STUB_OK" = "1" ] && [ -x "$STUBBIN/bash" ]; then
  printf '{"tool_name":"Bash","tool_input":{"command":"echo hello"}}' | PATH="$STUBBIN" "$STUBBIN/bash" "$HOOK" >/dev/null 2>&1
  [ $? -eq 0 ] && pass "token-free + jq missing -> allowed via raw prefilter" || fail "token-free bricked without jq"
  printf '{"tool_name":"Bash","tool_input":{"command":"wsl -d U -- codex exec hi"}}' | PATH="$STUBBIN" "$STUBBIN/bash" "$HOOK" >/dev/null 2>&1
  [ $? -eq 2 ] && pass "token-bearing + jq missing -> fail closed" || fail "token-bearing allowed without jq"
else
  pass "jq-missing cases SKIPPED (cannot materialize stub PATH on this shell)"
fi
rm -rf "$STUBBIN"

echo
if [ "$fails" -gt 0 ]; then echo "$fails failure(s)" >&2; exit 1; fi
echo "all tests passed"
