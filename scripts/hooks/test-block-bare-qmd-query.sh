#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2088  # the literal ~ and $(...) are the payloads under test
# Tests for scripts/hooks/block-bare-qmd-query.sh (HIMMEL-3956 / HIMMEL-3960).
#
# Usage: bash scripts/hooks/test-block-bare-qmd-query.sh
#
# Exit codes:
#   0 - all cases passed
#   1 - at least one case failed
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/block-bare-qmd-query.sh"

FAILED=0

run_case() {
    local input="$1"
    local env_assign="${2:-}"
    if [ -n "$env_assign" ]; then
        printf '%s' "$input" | env -u QMD_UNBOUNDED_OK "$env_assign" bash "$HOOK" >/dev/null 2>&1
    else
        printf '%s' "$input" | env -u QMD_UNBOUNDED_OK bash "$HOOK" >/dev/null 2>&1
    fi
    echo "$?"
}

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label - expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

j_bash() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }
deny() { assert_rc "deny: $1" 2 "$(run_case "$(j_bash "$1")")"; }
allow() { assert_rc "allow: $1" 0 "$(run_case "$(j_bash "$1")")"; }

# --- DENY: a qmd search verb reached without the group deadline ---
deny 'qmd query "why does the reindex hang"'
deny 'qmd search reindex'
deny 'qmd vsearch reindex'
deny 'qmd query -c luna "HIMMEL-3956 orphaned qmd query"'
deny '~/.local/bin/qmd query x'
deny '/home/u/.himmel/qmd-fork/bin/qmd search x'
deny '"qmd" query x'
deny 'qmd.cmd query x'
deny 'qmd --index luna query x'
deny 'qmd --json query x'
# The launcher chain itself: the bun child is what orphans.
deny 'bun ~/.himmel/qmd-fork/src/cli/qmd.ts query -c luna x'
deny '~/.bun/bin/bun run /opt/qmd/src/cli/qmd.ts search x'
deny 'node ~/.himmel/qmd-fork/bin/qmd vsearch x'
deny 'bunx @tobilu/qmd query x'
# Wrappers: plain timeout is exactly what fails to reap bun, so it is no bound.
deny 'timeout 60 qmd query x'
deny 'timeout -k 5 60 qmd query x'
deny 'timeout --signal=KILL 2m qmd search x'
deny 'env FOO=1 qmd query x'
deny 'QMD_TIMEOUT_SECS=5 qmd query x'
deny 'nice -n 10 qmd query x'
deny 'nohup qmd query x'
deny 'setsid qmd query x'
deny 'command qmd query x'
deny 'exec qmd query x'
deny 'time qmd query x'
deny 'sudo qmd query x'
deny 'bash -c "qmd query x"'
deny "sh -lc 'qmd search x'"
deny 'printf x | xargs qmd query'
# Command positions.
deny 'cd /tmp && qmd query x'
deny 'git status; qmd search x'
deny 'out=$(qmd query x)'
deny '(qmd query x)'
deny 'if qmd query x; then echo y; fi'
deny 'git status
qmd query x'
deny 'qmd \
  query x'
# HIMMEL-4011: a quoted verb is still the verb.
deny 'qmd "query" x'
deny "qmd 'search' x"
deny 'qmd "vsearch" x'
deny "qmd --index luna 'query' x"
deny "timeout 60 qmd 'query' x"
deny 'bun ~/.himmel/qmd-fork/src/cli/qmd.ts "search" x'
# HIMMEL-4121: bash removes quotes and escapes before qmd sees a word, so a
# verb or program spelled through them is still the verb or program.
deny 'qmd "qu"ery x'
deny 'qmd q"uery" x'
deny "qmd qu''ery x"
deny "qmd \$'query' x"
deny "qmd \$'\\x71uery' x"
deny "qmd \$'q\\165ery' x"
deny "qmd \$'\\u0071uery' x"
deny "qmd \$'query\\x00 notes' x"
deny "qmd \$'query\\c@ notes' x"
deny "qmd \$'query\\c\` notes' x"
deny "qmd \$'query\\c  notes' x"
deny 'qmd \query x'
deny 'qmd Q\UERY x'
deny 'q"md" query x'
deny 'q\
md query x'
deny "\\qmd search x"
deny "\$'qmd' vsearch x"
deny 'qmd query"" x'
deny "qmd query'' x"
deny 'qmd "query"$(true) x'
deny 'qmd --index "lu"na q"uery" x'
deny "timeout 60 q'md' qu\"ery\" x"
deny 'cd /tmp && q"md" "qu"ery x'
deny 'echo "$(qmd q"uery" x)"'
deny 'out="`qmd q"uery" x`"'
deny 'bun ~/.himmel/qmd-fork/src/cli/q"md".ts "se"arch x'
deny "echo don't # it's a comment
qmd q\"uery\" x"
deny 'qmd qu\
ery x'
# A `#` that continues a word after a quote or a substitution is no comment.
deny 'echo "$(true)"#x; qmd q"uery" x'
deny 'echo $(true)#x; qmd q"uery" x'
deny 'echo `true`#x; qmd q"uery" x'
deny 'echo "a"#x; qmd q"uery" x'
# zsh (the Bash tool's shell here) drops the backslash of an unknown $'\X'.
deny "qmd \$'\\query' x"
deny "qmd \$'quer\\y' x"
deny "qmd \$'v\\search' x"
# A command qmd_words declines must not fall back to a text blind to $'…'/$"…".
deny "cat <<E
hi
E
qmd \$'\\x71uery' x"
deny "cat <<E
hi
E
qmd \$'\\161uery' x"
deny 'cat <<E
hi
E
qmd $"query" x'
deny "echo \$((1<<2)); qmd \$'\\x71uery' x"
deny "echo $(printf 'a%.0s' $(seq 1 17000)); qmd \$'\\x71uery' x"
# A verb ending a nested -c string: its closing quote ends the word (J1666b).
deny "bash -c 'qmd query'"
deny 'bash -c "qmd search"'
deny "sh -c 'qmd vsearch'"
deny "timeout 5 bash -c 'qmd query'"
deny "zsh -c \"qmd query''\""
deny "sh -c 'qmd --index foo query'"
deny 'echo "x; qmd query"'
deny "qmd query\"x\"; bash -c 'qmd query'"
deny "echo \"\$(echo \"'\")\"; bash -c 'qmd query'"
# \$"…" is a quote too, in every reading.
deny 'q$"m"d query x'
deny 'q$"md" query x'
deny 'cat <<E
hi
E
q$"md" query x'
deny 'echo $((1<<2)); q$"md" query x'
deny "echo $(printf 'a%.0s' $(seq 1 17000)); q\$\"md\" query x"
# Quote offsets are bytes: a multibyte character before them must not shift
# them under a UTF-8 locale (J1666c).
U8=$(locale -a 2>/dev/null | grep -i -m1 '^c\.utf-\{0,1\}8$\|^en_us\.utf-\{0,1\}8$')
deny_u8() {
    if [ -z "$U8" ]; then echo "SKIP deny (no UTF-8 locale): $1"; return; fi
    assert_rc "deny ($U8): $1" 2 "$(run_case "$(j_bash "$1")" "LC_ALL=$U8")"
}
deny_u8 "echo é; bash -c 'qmd query'"
deny_u8 'bash -c "echo ü; qmd search"'
deny_u8 "bash -c 'echo 日本; qmd query'"
deny_u8 "x=ü bash -c 'qmd query'"

# --- ALLOW: the bounded paths, the non-search verbs, and mere mentions ---
allow 'bash scripts/lib/qmd-bounded.sh query -c luna "x"'
allow 'bash /home/u/himmel/scripts/lib/qmd-bounded.sh search x'
allow 'QMD_TIMEOUT_SECS=60 bash scripts/lib/qmd-bounded.sh vsearch x'
allow "bash -c '. scripts/lib/qmd-bounded.sh; qmd_bounded 60 qmd query x'"
allow 'qmd status'
allow 'qmd update'
allow 'qmd embed'
allow 'qmd collection list'
allow 'qmd get notes/query.md'
allow 'qmd --version'
allow 'bash scripts/luna/qmd-reindex.sh'
allow 'grep -rn "qmd query" scripts/'
allow "git log --grep 'qmd search'"
allow 'echo qmd query'
allow 'git status'
allow 'qmd queryx'
# HIMMEL-4011 counter-examples: quoting must not widen the match past the verb.
allow 'qmd "status"'
allow "qmd 'queryx' y"
allow 'qmd "query-notes" y'
allow 'qmd "query notes" y'
allow "qmd 'search the vault' y"
allow 'echo qmd "query" x'
allow 'grep -rn "qmd \"query\"" scripts/'
allow "bash scripts/lib/qmd-bounded.sh 'query' -c luna x"
# HIMMEL-4121: a word that only STARTS with a quoted verb is a longer word.
allow 'qmd "query"" notes" y'
allow "qmd 'query'' notes' y"
allow 'qmd query" notes" y'
allow "qmd \$'query notes' y"
allow "qmd \$'query\\tnotes' y"
allow 'qmd "query"x y'
allow 'echo q"md" "qu"ery x'
allow 'grep -rn "q\"md\" q\"uery\"" scripts/'
allow 'printf "%s\n" "a; qmd" status'
# `<<` inside $((…)) is a shift, not a heredoc: the words are still read.
allow "echo \$((1<<2)); qmd \$'query notes' y"
assert_rc "allow: non-Bash tool" 0 \
    "$(run_case '{"tool_name":"Read","tool_input":{"file_path":"/tmp/qmd query"}}')"
assert_rc "allow: bypass QMD_UNBOUNDED_OK=1" 0 \
    "$(run_case "$(j_bash 'qmd query x')" QMD_UNBOUNDED_OK=1)"

# --- FAIL CLOSED: an unreadable payload denies, like the sibling guards ---
assert_rc "deny: empty stdin" 2 "$(run_case '')"
assert_rc "deny: malformed JSON" 2 "$(run_case '{"tool_name":')"
# A present `command: false` must not fall through `//` to a benign `cmd`.
assert_rc "deny: command false beside a string cmd" 2 \
    "$(run_case '{"tool_name":"Bash","tool_input":{"command":false,"cmd":"ls"}}')"
assert_rc "deny: non-string command" 2 \
    "$(run_case '{"tool_name":"Bash","tool_input":{"command":7}}')"
# A present `command: null` must not read as empty while `cmd` carries the verb.
assert_rc "deny: command null beside a qmd query cmd" 2 \
    "$(run_case '{"tool_name":"Bash","tool_input":{"command":null,"cmd":"qmd query x"}}')"

# The deny text names the bounded replacement.
msg=$(printf '%s' "$(j_bash 'qmd query x')" | env -u QMD_UNBOUNDED_OK bash "$HOOK" 2>&1 >/dev/null)
case "$msg" in
    *qmd-bounded.sh*) echo "PASS deny text names qmd-bounded.sh" ;;
    *) echo "FAIL deny text does not name qmd-bounded.sh: $msg"; FAILED=$((FAILED + 1)) ;;
esac

if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "$FAILED FAILED"
exit 1
