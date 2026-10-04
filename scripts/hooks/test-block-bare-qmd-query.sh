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
# ... and so does a QUOTED verb ending it (J1666d).
deny "bash -c 'qmd \"query\"'"
deny 'sh -c "qmd '"'search'"'"'
deny 'echo "x; qmd '"'query'"'"'
deny "zsh -c 'qmd \"vsearch\"'"
deny 'bash -c "qmd '"'vsearch'"'"'
deny "sh -c 'qmd \"search\"'"
deny "timeout 5 bash -c 'qmd \"query\"'"
deny "env FOO=1 sh -c 'qmd --index foo \"search\"'"
deny "nice -n 5 bash -c 'qmd \"vsearch\"'"
deny "cd /tmp && bash -c 'qmd \"query\"'"
deny "x=ü bash -c 'qmd \"query\"'"
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
U8=$(locale -a 2>/dev/null | grep -iE -m1 '^(c|en_us)\.utf-?8$')
deny_u8() {
    if [ -z "$U8" ]; then echo "SKIP deny (no UTF-8 locale): $1"; return; fi
    assert_rc "deny ($U8): $1" 2 "$(run_case "$(j_bash "$1")" "LC_ALL=$U8")"
}
deny_u8 "echo é; bash -c 'qmd query'"
deny_u8 'bash -c "echo ü; qmd search"'
deny_u8 "bash -c 'echo 日本; qmd query'"
deny_u8 "x=ü bash -c 'qmd query'"
# HIMMEL-4140: more program positions — zsh's =cmd, a case arm, eval.
deny '=qmd query x'
deny 'env =qmd search x'
deny 'case a in a) qmd query x;; esac'
deny 'case a in (a|b) qmd vsearch x;; esac'
deny 'eval qmd query x'
deny "eval 'qmd \"qu\"ery x'"
deny 'command eval "qmd \"search\" x"'
# HIMMEL-4140 / HIMMEL-4151: a nested -c string is decoded like a top-level
# word (ANSI-C, backslash, adjacent quotes) and read again as a command.
deny "sh -c 'qmd \"qu\"ery x'"
deny "bash -c \$'qmd query'"
deny "bash -c \$'qmd \\x71uery x'"
deny 'bash -c qmd\ query'
deny 'bash -ec "qmd q\"uery\" x"'
deny "bash -c \"bash -c 'qmd \\\"qu\\\"ery'\""
deny 'sh -c "$(echo qmd) query"'
deny 'sh -c "`echo qmd` query"'
# The same substitution in program position at the top level (J1684b).
deny '$(echo qmd) query x'
deny '`echo qmd` query x'
deny '$(printf qmd) query x'
deny 'true; $(echo qmd) search y'
allow 'cd "$(git rev-parse --show-toplevel)" && qmd status'
allow 'echo "$(date)"; qmd status'
deny 'case a in a) $(echo qmd) query x;; esac'
# The `)` or backtick closing one substitution is not a boundary for the next.
allow 'printf "%s %s" "$(grep -c a qmd.sh)" "$(grep -c b qmd.sh)"'
allow 'echo qmd; x `a` `b`'
allow 'echo qmd; x $(a) `b`'
# coproc runs its command like any wrapper.
deny 'coproc qmd query x'
deny 'coproc foo { qmd query x; }'
allow 'coproc qmd status'
# A nested string naming qmd that the normaliser cannot read is refused.
deny "bash -c 'cat <<E
x
E
qmd q\"uery\" x'"
# J1666e: nested spellings both base and #1666 allowed, each ran a bare verb.
deny "nice sh -c 'qmd \\vse'\"arch;echo\""
deny "bash -c \$'qmd --index foo query\"\";'"
deny "bash -c 'echo é; qmd '\\''search'\\'';echo'"
deny "env bash -c \$'qmd --index foo query\"\";'; echo é"
deny_u8 "bash -c 'echo é; qmd '\\''search'\\'';echo'"
# zsh's ANSI-C escapes: \C-<end>, a bare \C or \M give nothing, and \c<x> is
# a plain `c<x>` (the J1666d corpus, run under zsh).
deny "cd /tmp && q\"md\" \$'\\C-'query x"
deny "qmd \$'\\M'search x"
deny "qmd \$'\\C-'\"vsearch\""
deny "qmd \$'sear\\ch' x"
deny "bash -c \$'qmd sear\\ch'"
deny "qmd \$'sear\\c'h"
# zsh's \C-i is a tab: a word break in a nested string.
deny "zsh -c \$'qmd\\C-iquery x'"
deny "zsh -c \$'qmd\\C-Iquery x'"
deny "zsh -c \$'qmd \\C-iquery x'"
allow "zsh -c \$'echo \\C-i hi'; qmd status"
# A redirection between the shell and its -c does not end the scan.
deny "bash <\"\$(bash -c 'qmd \"qu\"ery x')\" -c true"
deny "bash </dev/null -c 'qmd \"qu\"ery x'"
deny "bash < /dev/null -c 'qmd \"qu\"ery x'"
deny "bash 2>/dev/null -c 'qmd \"qu\"ery x'"
deny "bash &>/dev/null -c 'qmd \"qu\"ery x'"
deny "bash >&2 -c 'qmd \"qu\"ery x'"
deny "bash -e <<<x -c 'qmd \"qu\"ery x'"
deny "eval </dev/null 'qmd \"qu\"ery x'"
deny "eval 2>/dev/null 'qmd \"qu\"ery x'"
deny "eval {fd}>/dev/null 'qmd \"qu\"ery x'"
deny "eval 2>/dev/null qmd query x"
deny "eval -- 'qmd \"qu\"ery x'"
deny "eval -- qmd query x"
deny "bash 2>/dev/null -c 2>&1 'qmd \"qu\"ery x'"
# A substitution among the words before -c runs in the outer shell.
deny "bash \"\$(bash -c 'qmd \"qu\"ery')\""
deny "bash -x \"\$(sh -c 'qmd q\"uery\"')\""
deny "bash -o pipefail \`sh -c 'qmd q\"uery\"'\` -c true"
# bash runs its first operand as a script, found on PATH, so a substitution
# there is a program: `bash "$(printf qmd)" query x` runs qmd.
deny "bash -o pipefail \"\$(printf x)\" -c 'qmd status'"
deny 'bash "$(printf qmd)" query x'
# HIMMEL-4166: other shells and launchers run a nested string too.
deny "rbash -c 'qmd query x'"
deny "mksh -c 'qmd query x'"
deny "ash -c 'qmd query x'"
deny "fish -c 'qmd query x'"
deny "fish --command='qmd query x'"
deny "fish -c 'qmd \"qu\"ery x'"
deny "su -c 'qmd query x'"
deny "su - u -c 'qmd \"qu\"ery x'"
deny "su u --command='qmd query x'"
deny "su -C 'qmd query x'"
deny "su u --session-command 'qmd query x'"
deny "runuser u --session-command='qmd \"qu\"ery x'"
deny "script -c 'qmd query x' /dev/null"
deny "script -qc 'qmd query x' /dev/null"
deny "script -q -c 'qmd \"qu\"ery x' /dev/null"
deny "env -S'qmd query x'"
deny "env -S'qmd' query x"
deny "env --split-string='qmd \"qu\"ery x'"
# A shell reading its program from stdin: a here-string, or a pipe.
deny "bash <<< 'qmd query x'"
deny "sh <<<'qmd \"qu\"ery x'"
deny "echo 'qmd query x' | sh"
deny "printf '%s\\n' 'qmd \"qu\"ery x' | bash"
deny 'echo qmd query x | sh -s'
deny "echo 'qmd query x' |& sh"
deny "echo 'qmd query x' | cat | sh"
deny "echo 'qmd query x' | tr a a |& tee /dev/null | bash"
deny "bash -c sh <<< 'qmd query x'"
deny "echo 'qmd query x' | timeout 5 bash"
deny "source /dev/stdin <<< 'qmd query x'"
deny "env -i -S'qmd query x'"
# "$@" indirection: the program or the verb in a positional parameter.
deny 'set -- qmd query x; "$@"'
deny 'f() { "$@"; }; f qmd query x'
deny 'set -- query x; qmd "$@"'
# HIMMEL-4218: wrappers that run their arguments as a program.
deny 'watch qmd query x'
deny 'watch -n 5 qmd query x'
deny "watch 'qmd query x'"
deny "watch -n 5 'qmd \"qu\"ery x'"
deny 'flock /tmp/l qmd query x'
deny 'flock -w 5 /tmp/l qmd query x'
deny 'flock -x /tmp/l qmd query x'
deny "flock /tmp/l -c 'qmd query x'"
deny 'systemd-run --user qmd query x'
deny 'systemd-run --user --scope -p MemoryMax=1G qmd query x'
deny 'unbuffer qmd query x'
deny 'unbuffer -p qmd search x'
deny 'parallel qmd query ::: x y'
deny "parallel 'qmd query {}' ::: x y"
deny "parallel -j 2 'qmd \"qu\"ery {}' ::: x"
# An alias for qmd, and sourcing a substitution, fail closed.
deny 'alias q=qmd; q query x'
deny "alias q='qmd'; q search x"
deny 'source <(echo qmd query x)'
deny '. <(echo qmd query x)'
deny 'bash <(echo qmd query x)'
# HIMMEL-4244: the residual launchers. A -c string, a group operand, a
# detached session, a job read from stdin, and prefix wrappers.
deny "sg users -c 'qmd query x'"
deny "sg users 'qmd \"qu\"ery x'"
deny 'sg users qmd query x'
deny "elvish -c 'qmd query x'"
deny "nu -c 'qmd query x'"
deny "xonsh -c 'qmd query x'"
deny "pwsh -c 'qmd query x'"
deny "pwsh -Command 'qmd \"qu\"ery x'"
deny "tmux new -d 'qmd query x'"
deny "tmux new-session -d -s s 'qmd \"qu\"ery x'"
deny 'tmux new -d qmd query x'
deny 'tmux -L sock new-window qmd search x'
deny 'screen -dm qmd query x'
deny 'screen -dmS s qmd query x'
deny "echo 'qmd query x' | at now"
deny "echo 'qmd query x' | batch"
deny "at now <<< 'qmd query x'"
deny 'builtin exec qmd query x'
deny 'setpriv qmd query x'
deny 'setpriv --reuid 1000 --init-groups qmd query x'
deny 'unshare -r qmd query x'
deny 'nsenter -t 1 qmd query x'
deny 'nsenter -t 1 -m -u qmd query x'
deny 'chroot / qmd query x'
deny 'chroot --userspec=u:g / qmd query x'
deny 'firejail qmd query x'
deny 'firejail --noprofile -- qmd query x'
deny 'bwrap --bind / / qmd query x'
deny 'bwrap --ro-bind / / --dev /dev qmd query x'
deny 'xvfb-run qmd query x'
deny 'xvfb-run -a -s "-screen 0 1x1x8" qmd query x'
deny 'strace -f qmd query x'
deny 'strace -f -o /tmp/t qmd query x'
deny 'ltrace qmd query x'
deny 'chpst -u u qmd query x'
deny 'cgexec -g cpu:x qmd query x'
deny 'systemd-inhibit qmd query x'
deny 'systemd-inhibit --what=idle qmd query x'
deny 'pkexec qmd query x'
deny 'pkexec --user root qmd query x'
deny '/usr/bin/strace -f qmd query x'
deny "bwrap --bind / / sh -c 'qmd query x'"
# HIMMEL-4245: a shell that is the consumer's program, behind a wrapper.
deny "echo 'qmd query x' | xargs bash"
deny "echo 'qmd query x' | env sh"
deny "echo 'qmd query x' | nice bash"
deny "echo 'qmd query x' | 2>/dev/null sh"
deny "echo 'qmd query x' | { sh; }"
deny "echo 'qmd query x' | /bin/sh"
deny "echo 'qmd query x' | busybox sh"
deny "echo 'qmd query x' | sg users sh"
deny "echo 'qmd query x' | sudo -u u sh"
# A remote or container launcher consumer stays fail-closed on a shell word.
deny "echo 'qmd query x' | ssh host sh"
deny "echo 'qmd query x' | docker exec -i c sh"
deny "echo 'qmd query x' | podman exec -i c bash"
deny "echo 'qmd query x' | kubectl exec -i p -- sh"
deny "echo 'qmd query x' | docker run -i img sh"
deny "echo 'qmd query x' | /usr/bin/ssh -p 22 host bash"
# ... while a shell named as a later operand of the consumer is no program.
allow 'grep -rn "qmd search" docs | grep -v sh'
allow 'grep -rn "qmd search" docs | grep -c bash'
allow 'grep -rln "qmd search" docs | xargs grep -n "search" .'
allow "tmux new -d 'qmd status'"
allow 'strace -f qmd status'
allow "sg users -c 'qmd status'"
allow "echo 'qmd status' | at now"
# HIMMEL-4245 (judge J1784g): a consumer stage is cleared of its shell word
# only when its program is a known non-executing filter. Every other launcher
# — modelled or not, with operands or not — keeps the shell word fail-closed.
deny 'echo qmd query x | chrt 10 sh'
deny 'echo qmd query x | taskset 0x1 sh'
deny 'echo qmd query x | fakeroot sh'
deny 'echo qmd query x | eatmydata sh'
deny 'echo qmd query x | proot sh'
deny 'echo qmd query x | dbus-run-session sh'
deny 'echo qmd query x | caffeinate sh'
deny 'echo qmd query x | torsocks sh'
deny 'echo qmd query x | faketime now sh'
deny 'echo qmd query x | chronic sh'
deny 'echo qmd query x | ifne sh'
deny 'echo qmd query x | sshpass -p pw ssh host sh'
deny 'echo qmd query x | lxc exec c -- sh'
deny 'echo qmd query x | incus exec c -- sh'
deny 'echo qmd query x | nerdctl exec -i c sh'
deny 'echo qmd query x | oc exec -i p -- sh'
deny 'echo qmd query x | ionice -c 3 sh'
deny 'echo qmd query x | prlimit --nofile=64 sh'
deny 'echo qmd query x | numactl -N 0 sh'
deny 'echo qmd query x | flatpak-spawn --host sh'
deny 'echo qmd query x | distrobox enter c -- sh'
deny 'echo qmd query x | toolbox run sh'
deny 'echo qmd query x | lxc-attach -n c -- sh'
deny 'echo qmd query x | systemd-nspawn -D d sh'
deny 'echo qmd query x | valgrind sh'
deny 'echo qmd query x | rlwrap sh'
# A subshell, a group, a loop or a substitution in the consumer stage
# inherits the pipe; so does a process substitution's reader.
deny 'echo qmd query x | (sh)'
deny 'echo qmd query x | tee >(sh)'
deny 'echo qmd query x | grep "$(sh)"'
deny 'echo qmd query x | grep `sh`'
deny 'echo qmd query x | (cat) | sh'
deny '(echo qmd query x) | sh'
deny '(echo qmd query x; true) | sh'
deny 'echo qmd query x | { grep -q x; sh; }'
deny 'echo qmd query x | while read l; do sh; done'
# A filter reached through a wrapper, decorated, redefined, or given an
# option that runs a program or a script that executes.
deny 'echo qmd query x | command grep -v sh'
deny 'echo qmd query x | env grep -v sh'
deny 'echo qmd query x | nice grep -v sh'
deny 'echo qmd query x | "grep" -v sh'
deny 'echo qmd query x | \grep -v sh'
deny 'echo qmd query x | $g -v sh'
deny 'echo qmd query x | ./grep -v sh'
deny 'echo qmd query x | /tmp/grep -v sh'
deny 'echo qmd query x | =grep -v sh'
deny 'alias grep=sh; echo qmd query x | grep -v sh'
deny 'grep() { sh; }; echo qmd query x | grep -v sh'
deny 'PATH=/tmp/x:$PATH; echo qmd query x | grep -v sh'
deny 'hash -p /bin/sh grep; echo qmd query x | grep -v sh'
deny '. ./defs.sh; echo qmd query x | grep -v sh'
deny "bash -c 'source f; echo qmd query x | grep -v sh'"
deny 'echo qmd query x | xargs -a f grep -v sh'
# HIMMEL-4244: a pipe continues across a newline, so a stage span holding a
# newline or CR is never a filter (the next line's shell goes unclassified).
deny $'echo qmd query x | grep -v sh |\nsh'
deny $'echo qmd query x | grep -v sh | \nsh'
deny $'echo qmd query x |& grep -v sh |&\nsh'
deny $'echo qmd query x | grep -v sh |\r\nsh'
deny $'echo qmd query x | grep -v sh | cat |\nsh'
deny $'echo qmd query x | grep -v sh | tee /dev/null |\nsh'
deny $'echo qmd query x | grep -v sh | cat |&\nsh'
deny $'echo qmd query x | grep -v sh | cat | cat |\nsh'
deny $'echo qmd query x | grep -v sh |\n\nsh'
deny $'echo qmd query x | grep -v sh | # c\nsh'
deny $'echo qmd query x | grep -v sh |  \t\nsh'
deny $'echo qmd query x | grep -v sh | \\\nsh'
deny $'echo qmd query x | grep -v sh \\\n| sh'
deny $'echo qmd query x | grep -v sh\\\n | sh'
deny $'echo qmd query x | grep -v sh |&\n sh'
deny $'echo qmd query x | grep -v sh |\n# c\nsh'
deny $'echo qmd query x | sed -n /x/p sh | cat |\nsh'
deny $'echo qmd query x | grep -v sh | cat | cat |&\r\nsh'
deny $'echo qmd query x | grep -v sh && cat |\nsh'
deny $'echo qmd query x | grep -v sh | cat | cat |\n\n sh'
deny $'echo qmd query x | grep -v sh | cat\t|\nsh'
deny $'echo qmd query x | grep -v sh | cat |\nsh -s'
deny $'echo qmd query x | grep -v sh | cat | (cat) |\nsh'
deny $'echo qmd query x | grep -v sh | head -1 |\r\n\r\nsh'
deny $'echo qmd query x | grep -v sh | cat |\n  \nsh'
deny 'echo qmd query x | sort --compress-program sh'
deny 'echo qmd query x | rg --pre sh x'
deny 'echo qmd query x | sed e sh'
deny 'echo qmd query x | sed s/x/y/w sh'
deny 'echo qmd query x | sed -f f.sed sh'
deny "echo qmd query x | awk '{system(\$0)}' sh"
deny "echo qmd query x | awk '{print | \"cat\"}' sh"
deny "echo qmd query x | awk 'BEGIN{\"date\" | getline d}' sh"
deny 'echo qmd query x | awk -f p.awk sh'
deny 'echo qmd query x | less sh'
deny 'echo qmd query x | more sh'
# A sed script bundled into or after an option word: `-ee` is `-e e`.
deny "echo 'qmd query x' | sed -ee - sh"
deny 'echo qmd query x | sed -ne e sh'
deny 'echo qmd query x | sed -Ee sh'
deny 'echo qmd query x | sed -nEe sh'
deny 'echo qmd query x | sed -e e sh'
deny 'echo qmd query x | sed -e 1e sh'
deny 'echo qmd query x | sed -n sh -e'
deny 'echo qmd query x | sed -fp.sed sh'
deny 'echo qmd query x | sed -i e sh'
deny 'echo qmd query x | sed -l 5 sh'
deny 'echo qmd query x | sed -s -e w sh'
deny 'echo qmd query x | awk -fp.awk sh'
deny 'echo qmd query x | awk -e 1 sh'
deny 'echo qmd query x | gawk -E p.awk sh'
# Behind xargs the producer's bytes become the filter's options.
deny 'echo qmd query x | xargs sed -n p sh'
deny 'echo qmd query x | xargs awk 1 sh'
deny 'echo qmd query x | xargs rg -v sh'
deny 'echo qmd query x | xargs sort sh'
# A case-folded name is no filter.
deny 'echo qmd query x | SED -n p sh'
deny 'echo qmd query x | GREP -v sh'
# An expansion hides the word the filter checks read: no filter.
deny 'X=e; echo qmd query x | sed $X - sh'
deny "P='{system(\$0)}'; echo qmd query x | awk \$P - sh"
deny 'echo qmd query x | sed "$X" - sh'
deny 'echo qmd query x | sed -n -e p -e $X - sh'
deny "echo qmd query x | sed 's/^/x/'\$X - sh"
deny 'echo qmd query x | sed -n $1 - sh'
deny 'echo qmd query x |& sed $X - sh'
deny 'echo qmd query x | head -1 | sed $X - sh'
deny 'echo qmd query x | awk "$P" - sh'
deny 'echo qmd query x | grep -v $X sh'
deny 'echo qmd query x | grep -v ${X} sh'
deny "echo qmd query x | grep -v \$'\\x73' sh"
deny 'echo qmd query x | grep -v "\$X" sh'
deny 'echo qmd query x | jq -r $X sh'
deny "echo qmd query x | grep -v \$\"x\" sh"
deny 'echo qmd query x | grep -v <(true) sh'
# The grep-operand class 4245 opened stays allowed, through plain filters.
allow 'grep -rn "qmd search" docs | /usr/bin/grep -v sh'
allow 'grep -rn "qmd search" docs |& grep -v sh'
allow 'grep -rn "qmd search" docs | grep -v -e sh -e bash'
allow 'grep -rn "qmd search" docs | rg -v zsh'
allow 'grep -rn "qmd search" docs | head -n 5 | grep -c sh'
allow "grep -rn 'qmd search' docs | awk -F: '{print \$1}' | sort | uniq -c | grep -v bash"
allow 'grep -rn "qmd search" docs | cut -d: -f1 | grep zsh'
allow 'grep -rn "qmd search" docs | sed -n /x/p sh'
allow 'grep -rn "qmd search" docs | sed -nE /x/p sh'
allow 'grep -rn "qmd search" docs | sed -n -e /x/p - sh'
allow 'grep -rln "qmd search" docs | xargs -0 -n 1 grep -c sh'
allow "grep -rn 'qmd query' . | awk '{print \$1}' | grep -v source"
# ponytail: a filter that runs its input with no shell word in the stage
# (sed e, awk system, sort --compress-program=PROG), and a consumer redefined
# as a function, are unread; residual launchers → HIMMEL-4305.
allow 'echo qmd query x | sed e'
allow "echo qmd query x | awk '{system(\$0)}'"
allow 'echo qmd query x | sort --compress-program=sh'
allow 'cat() { sh; }; echo qmd query x | cat'
# ... while the same launchers running anything else stay allowed.
allow "fish -c 'qmd status'"
allow "su -c 'qmd status'"
allow "script -qc 'qmd status' /dev/null"
allow "env -S'qmd status'"
allow "bash <<< 'qmd status'"
allow "echo 'qmd status' | sh"
allow 'echo qmd query x | grep qmd'
allow 'watch -n 5 qmd status'
allow 'flock /tmp/l qmd update'
allow 'systemd-run --user qmd embed'
allow "parallel 'qmd get {}' ::: a b"
allow "alias s='qmd status'; s"
allow 'source <(echo qmd status)'
allow 'set -- a b; "$@"; qmd status'
allow 'env -- printf "%s %s" "$(grep -c a qmd.sh)" "$(grep -c b qmd.sh)"'

# The nested scan is linear: padding with shell words must not push the hook
# past the chain's budget, where it would be skipped instead of deciding.
# timed RC LABEL CMD — assert the exit code and a wall time under 1 s
# (EPOCHREALTIME is bash 5; without it, SECONDS bounds it to 2 s).
timed() {
    local want=$1 label=$2 input t0 t1 rc ms
    input=$(j_bash "$3")
    t0=${EPOCHREALTIME:-$SECONDS}
    rc=$(run_case "$input")
    t1=${EPOCHREALTIME:-$SECONDS}
    assert_rc "$label" "$want" "$rc"
    if [ -n "${EPOCHREALTIME:-}" ]; then
        ms=$(( (${t1/[.,]/} - ${t0/[.,]/}) / 1000 ))
    else
        ms=$(( (t1 - t0) * 1000 ))
        if [ "$ms" -le 1000 ]; then ms=0; fi
    fi
    if [ "$ms" -lt 1000 ]; then
        echo "PASS $label in ${ms}ms"
    else
        echo "FAIL $label took ${ms}ms (budget 1000ms)"
        FAILED=$((FAILED + 1))
    fi
}
pad_sh=$(printf 'sh %.0s' $(seq 700))
pad_w=$(printf 'w %.0s' $(seq 2000))
timed 2 'deny: 700 sh words, then a nested -c' "echo ${pad_sh}; bash -ec \"qmd q\\\"uery\\\" x\""
timed 2 'deny: 700 sh words before a nested -c' "echo ${pad_sh}bash -c 'qmd \"qu\"ery x'"
timed 0 'allow: qmd status, then 700 sh words' "qmd status; echo ${pad_sh}"
timed 0 'allow: qmd status, then 2000 words' "qmd status; echo ${pad_w}"
timed 0 'allow: qmd status, bash -c and 2000 words' "qmd status; bash -c 'echo \$0' ${pad_w}"

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
# HIMMEL-4140 / HIMMEL-4151: a decoded nested string is still read as words.
allow "bash -c 'qmd status'"
allow "bash -c \$'qmd \\x73tatus'"
allow "eval 'qmd \"query notes\" y'"
allow 'case a in a) qmd status;; esac'
allow 'echo =qmd query'
# One it cannot read that does not name qmd gets the fallback readings.
allow "qmd status; bash -c 'echo \$(( \$(date +%s) - 1 ))'"
allow "qmd status; bash -c 'echo \"\$(( \$(date +%s) - 1 ))\"'"
allow "qmd status; printf \$'a\\cIb\\C-xc'"
allow "bash </dev/null -c 'qmd status' 2>&1"
allow "qmd status; bash -c 'IFS=\$'\"'\"'\\t'\"'\"' read -r a <<E
x
E'"
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
