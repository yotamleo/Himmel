#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2181,SC2016 # compact status assertions; SC2016: raw-shape command strings are intentionally single-quoted literals.
# Tests for block-rogue-codex-exec.sh (HIMMEL-2023). Mirrors
# test-block-rogue-codex-wsl.sh case-for-case where the shapes correspond.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/block-rogue-codex-exec.sh"

fails=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; fails=$((fails + 1)); }

ERR="$(mktemp)"
trap 'rm -f "$ERR"' EXIT

run_hook() {  # run_hook <tool_name> <command-string>
  # node first: it is a guaranteed repo dependency; python3 on this fleet
  # can be the flaky Windows Store stub.
  printf '{"tool_name":"%s","tool_input":{"command":%s}}' "$1" "$(printf '%s' "$2" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>console.log(JSON.stringify(d)))' 2>/dev/null || printf '%s' "$2" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" | bash "$HOOK" >/dev/null 2>"$ERR"
  RC=$?
}

run_hook Bash 'codex exec --sandbox workspace-write "do the thing"'
[ "$RC" -eq 2 ] && pass "raw codex exec blocked" || fail "raw shape allowed (rc=$RC)"
grep -q "dispatch-codex-exec.sh" "$ERR" || fail "refusal does not name the chokepoint"
grep -q "CODEX_EXEC_RAW_OK=1" "$ERR" || fail "refusal does not name the bypass"

# THE case this guard exists for: the chokepoint must stay usable. Its path
# contains "codex" twice (dir + script name) and neither ends a token.
run_hook Bash 'bash scripts/codex/dispatch-codex-exec.sh --worktree .claude/worktrees/wt do-it'
[ "$RC" -eq 0 ] && pass "chokepoint invocation allowed" || fail "chokepoint blocked (rc=$RC)"
run_hook Bash 'bash /c/Users/y/Documents/github/himmel/scripts/codex/dispatch-codex-exec.sh --worktree wt exec-something'
[ "$RC" -eq 0 ] && pass "absolute-path chokepoint invocation allowed" || fail "absolute chokepoint blocked (rc=$RC)"

run_hook Bash 'codex exec do-it # dispatch-codex-exec.sh'
[ "$RC" -eq 2 ] && pass "comment-spoofed chokepoint name still blocked" || fail "comment spoof bypassed the guard (rc=$RC)"

run_hook Bash 'codex --version'
[ "$RC" -eq 0 ] && pass "codex without exec allowed" || fail "diagnostics blocked (rc=$RC)"

run_hook Bash 'codex login status'
[ "$RC" -eq 0 ] && pass "codex login allowed" || fail "codex login blocked (rc=$RC)"

run_hook Bash 'git commit -m "feat: block rogue codex exec dispatch"'
[ "$RC" -eq 0 ] && pass "tokens in quoted commit message allowed" || fail "commit message false positive (rc=$RC)"

run_hook Bash 'grep -rn "codex exec" scripts/hooks/'
[ "$RC" -eq 0 ] && pass "tokens in grep pattern allowed" || fail "grep pattern false positive (rc=$RC)"

run_hook Bash 'echo hello'
[ "$RC" -eq 0 ] && pass "token-free command allowed" || fail "token-free blocked (rc=$RC)"

# Benign ARGUMENTS (not command position) must not block - bare whitespace is
# not a command-position separator.
run_hook Bash 'echo codex exec'
[ "$RC" -eq 0 ] && pass "benign echo with codex/exec args allowed" || fail "echo codex exec false-positive blocked (rc=$RC)"

# ...but a real separator before codex lands it in command position.
run_hook Bash 'true && codex exec do it'
[ "$RC" -eq 2 ] && pass "codex after && separator still blocked" || fail "codex after && bypassed (rc=$RC)"
run_hook Bash 'echo hi | codex exec do it'
[ "$RC" -eq 2 ] && pass "codex after a pipe still blocked" || fail "codex after pipe bypassed (rc=$RC)"

run_hook PowerShell 'codex exec do it'
[ "$RC" -eq 2 ] && pass "PowerShell raw shape blocked" || fail "PowerShell raw shape allowed (rc=$RC)"

run_hook Bash 'CODEX.exe exec do it'
[ "$RC" -eq 2 ] && pass "uppercase CODEX.exe raw shape blocked" || fail "uppercase CODEX bypassed the guard (rc=$RC)"

# Command-position bypasses: subshell / command-subst / backtick /
# path-qualified basename.
run_hook Bash '(codex exec do it)'
[ "$RC" -eq 2 ] && pass "subshell-grouped raw shape blocked" || fail "subshell (codex bypassed (rc=$RC)"
run_hook Bash 'out=$(codex exec do it)'
[ "$RC" -eq 2 ] && pass "command-substituted raw shape blocked" || fail "command-subst codex bypassed (rc=$RC)"
run_hook Bash '/c/Users/y/AppData/Local/codex/codex.exe exec do it'
[ "$RC" -eq 2 ] && pass "path-qualified codex.exe raw shape blocked" || fail "path-qualified codex bypassed (rc=$RC)"

# Env-assignment prefix (panel codex-1) — `VAR=value codex exec` is a natural
# raw shape, not an evasion, and bare whitespace is not a command-position
# separator, so it slipped the opener rule entirely.
run_hook Bash 'CODEX_HOME=/tmp/x codex exec do it'
[ "$RC" -eq 2 ] && pass "env-assignment prefix still blocked" || fail "VAR=v codex exec bypassed (rc=$RC)"
run_hook Bash 'A=1 B=2 codex exec do it'
[ "$RC" -eq 2 ] && pass "multiple env assignments still blocked" || fail "A=1 B=2 codex exec bypassed (rc=$RC)"
run_hook Bash 'true && FOO=bar codex exec do it'
[ "$RC" -eq 2 ] && pass "env prefix after a separator still blocked" || fail "&& FOO=bar codex exec bypassed (rc=$RC)"
# ...and the env-prefix arm must not turn a benign argument list into a block.
run_hook Bash 'echo FOO=1 codex exec'
[ "$RC" -eq 0 ] && pass "env-looking ARGS to a benign command still allowed" || fail "echo FOO=1 codex exec false-positive blocked (rc=$RC)"

# Verb terminated by a shell metacharacter (panel codex-2) — an
# ([[:space:]]|$) tail let all three of these through.
run_hook Bash 'codex exec;'
[ "$RC" -eq 2 ] && pass "codex exec; (semicolon-terminated verb) blocked" || fail "codex exec; bypassed (rc=$RC)"
run_hook Bash 'codex exec|cat'
[ "$RC" -eq 2 ] && pass "codex exec|cat (pipe-terminated verb) blocked" || fail "codex exec|cat bypassed (rc=$RC)"
run_hook Bash 'codex exec>out.txt'
[ "$RC" -eq 2 ] && pass "codex exec>out (redirect-terminated verb) blocked" || fail "codex exec>out bypassed (rc=$RC)"
run_hook Bash '(codex exec)'
[ "$RC" -eq 2 ] && pass "codex exec) (subshell-close-terminated verb) blocked" || fail "(codex exec) bypassed (rc=$RC)"
# The metachar tail must not start matching a hyphenated word either.
run_hook Bash 'bash scripts/codex/dispatch-codex-exec.sh --worktree wt; echo done'
[ "$RC" -eq 0 ] && pass "chokepoint followed by ; still allowed" || fail "chokepoint with a trailing ; blocked (rc=$RC)"

# The verb must live in CODEX'S OWN segment (panel r2 codex-2) — matching a
# command-position codex and ANY later bare `exec` independently false-blocked
# benign compound commands.
run_hook Bash 'codex --version && echo exec'
[ "$RC" -eq 0 ] && pass "codex diagnostics followed by an unrelated exec word allowed" || fail "codex --version && echo exec false-positive blocked (rc=$RC)"
run_hook Bash 'codex login; bash scripts/foo.sh exec'
[ "$RC" -eq 0 ] && pass "codex verb-less command followed by an unrelated exec arg allowed" || fail "codex login; ... exec false-positive blocked (rc=$RC)"
# ...but flags between codex and its verb must still reach the verb.
run_hook Bash 'codex --sandbox workspace-write exec do it'
[ "$RC" -eq 2 ] && pass "flags between codex and exec still blocked" || fail "codex <flags> exec bypassed (rc=$RC)"

# A QUOTED command name (panel r3 codex-1) — the opener accepted it on the
# original text while the verb check ran on the quote-stripped text, where
# that same name had already been erased.
run_hook Bash "'codex' exec do it"
[ "$RC" -eq 2 ] && pass "single-quoted command name still blocked" || fail "'codex' exec bypassed (rc=$RC)"
run_hook Bash '"codex.exe" exec do it'
[ "$RC" -eq 2 ] && pass "double-quoted codex.exe command name still blocked" || fail '"codex.exe" exec bypassed (rc='"$RC"')'
# ...but a quoted DATA string that merely CONTAINS the pair must not block.
run_hook Bash 'git commit -m "codex exec is now guarded"'
[ "$RC" -eq 0 ] && pass "quoted data containing the codex/exec pair allowed" || fail "quoted data false-positive blocked (rc=$RC)"

# Command position and the verb must belong to the SAME codex (panel r3
# codex-2) — matching them independently blocked this benign compound.
run_hook Bash 'codex --version && echo codex exec'
[ "$RC" -eq 0 ] && pass "later benign codex/exec text does not block a diagnostics run" || fail "codex --version && echo codex exec false-positive blocked (rc=$RC)"

# The documented bypass.
CODEX_EXEC_RAW_OK=1 run_hook Bash 'codex exec do it'
[ "$RC" -eq 0 ] && pass "CODEX_EXEC_RAW_OK=1 bypasses the guard" || fail "bypass env ignored (rc=$RC)"

# A non-Bash tool payload with no .tool_input.command is a no-op, not a block.
printf '{"tool_name":"Read","tool_input":{"file_path":"scripts/codex/dispatch-codex-exec.sh"}}' | bash "$HOOK" >/dev/null 2>"$ERR"
[ "$?" -eq 0 ] && pass "payload without a command field allowed" || fail "command-less payload blocked"

echo
if [ "$fails" -ne 0 ]; then
  echo "FAILED: $fails test(s)"; exit 1
fi
echo "ALL PASS"
