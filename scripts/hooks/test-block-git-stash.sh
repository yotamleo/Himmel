#!/usr/bin/env bash
# Smoke test for scripts/hooks/block-git-stash.sh (HIMMEL-1755).
#
# Usage: bash scripts/hooks/test-block-git-stash.sh
#
# Exit codes:
#   0 - all cases passed
#   1 - at least one case failed
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/block-git-stash.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK" 2>/dev/null || true

FAILED=0

run_case() {
    local input="$1"
    local env_assign="${2:-}"
    if [ -n "$env_assign" ]; then
        printf '%s' "$input" | env "$env_assign" bash "$HOOK" >/dev/null 2>&1
    else
        printf '%s' "$input" | bash "$HOOK" >/dev/null 2>&1
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

# --- BLOCK cases (expect rc=2): every shape that writes the SHARED refs/stash ---
assert_rc "bare git stash"            2 "$(run_case "$(j_bash 'git stash')")"
assert_rc "git stash push"            2 "$(run_case "$(j_bash 'git stash push -m wip')")"
assert_rc "git stash save"            2 "$(run_case "$(j_bash 'git stash save wip')")"
assert_rc "git stash pop"             2 "$(run_case "$(j_bash 'git stash pop')")"
assert_rc "git stash drop"            2 "$(run_case "$(j_bash 'git stash drop stash@{0}')")"
assert_rc "git stash clear"           2 "$(run_case "$(j_bash 'git stash clear')")"
assert_rc "git stash branch"          2 "$(run_case "$(j_bash 'git stash branch wip stash@{0}')")"
assert_rc "git stash store"           2 "$(run_case "$(j_bash 'git stash store -m x deadbeef')")"
# Bare stash WITH options is still `push` — the option forms must not read as a
# verb-less allow.
assert_rc "git stash -u"              2 "$(run_case "$(j_bash 'git stash -u')")"
assert_rc "git stash --all"           2 "$(run_case "$(j_bash 'git stash --all')")"
assert_rc "git stash -- path"         2 "$(run_case "$(j_bash 'git stash -- scripts/x.sh')")"
# codex-1 (CR r2): a bare stash whose next token is a redirection, a comment or
# a subshell close is still a bare stash.
assert_rc "git stash >file"           2 "$(run_case "$(j_bash 'git stash >/tmp/out')")"
assert_rc "git stash 2>&1"            2 "$(run_case "$(j_bash 'git stash 2>&1 | cat')")"
assert_rc "git stash # comment"       2 "$(run_case "$(j_bash 'git stash # save wip')")"
assert_rc "(git stash)"               2 "$(run_case "$(j_bash '(git stash)')")"
# The cross-worktree shapes that make this guard necessary: an explicit
# repo/git-dir still lands on the SAME shared ref.
assert_rc "git -C <path> stash drop"  2 "$(run_case "$(j_bash 'git -C /c/repo/.claude/worktrees/other stash drop')")"
assert_rc "git --git-dir= stash pop"  2 "$(run_case "$(j_bash 'git --git-dir=/c/repo/.git stash pop')")"
assert_rc "git --git-dir <d> stash"   2 "$(run_case "$(j_bash 'git --git-dir /c/repo/.git stash')")"
assert_rc "git -c k=v stash pop"      2 "$(run_case "$(j_bash 'git -c core.pager=cat stash pop')")"
# codex-2 (CR r4): a git global option's value may be QUOTED and then carries
# spaces. An unquoted-only value token stopped at the space and dropped `stash`
# out of position, so these evaded the guard entirely.
assert_rc "git -c 'q=a b' stash drop"  2 "$(run_case "$(j_bash "git -c 'foo.bar=a b' stash drop")")"
assert_rc "git -c \"q=a b\" stash drop" 2 "$(run_case "$(j_bash 'git -c "foo.bar=a b" stash drop')")"
assert_rc "git -C 'p with space' pop"  2 "$(run_case "$(j_bash "git -C '/c/re po' stash pop")")"
# Command position, not first position: a chained clause and the .exe / path /
# wrapper spellings the sibling grammar also covers.
assert_rc "chained ; git stash drop"  2 "$(run_case "$(j_bash 'git status; git stash drop')")"
assert_rc "git.exe stash pop"         2 "$(run_case "$(j_bash 'git.exe stash pop')")"
# codex-1 (CR r5): a QUOTED executable token still executes; the sibling catches
# its analogue (`"taskkill" ...` = rc 2) and this rule must too.
assert_rc 'quoted "git" stash drop' 2 "$(run_case "$(j_bash '"git" stash drop')")"
assert_rc 'quoted "git" stash list' 0 "$(run_case "$(j_bash '"git" stash list')")"
assert_rc "/usr/bin/git stash clear"  2 "$(run_case "$(j_bash '/usr/bin/git stash clear')")"
assert_rc "env prefix git stash pop"  2 "$(run_case "$(j_bash 'GIT_PAGER=cat git stash pop')")"
assert_rc "uppercase GIT STASH DROP"  2 "$(run_case "$(j_bash 'GIT STASH DROP')")"
# An allowed read does NOT launder a mutation later in the same command line.
assert_rc "stash list; stash drop"    2 "$(run_case "$(j_bash 'git stash list; git stash drop')")"
# codex-1 (CR r1): a backslash line continuation is whitespace to the shell, and
# the guard folds newlines to ';' before matching — so `git \<newline>stash drop`
# must still be refused, at every token boundary of the rule.
assert_rc "continuation before stash" 2 "$(run_case "$(j_bash 'git \
stash drop')")"
assert_rc "continuation before verb"  2 "$(run_case "$(j_bash 'git stash \
pop')")"
assert_rc "continuation before flag"  2 "$(run_case "$(j_bash 'git stash \
-u')")"
assert_rc "continuation in -C value"  2 "$(run_case "$(j_bash 'git -C \
/c/repo stash clear')")"

# HIMMEL-2077: refs/stash is an ordinary ref, reachable through low-level
# plumbing that bypasses the `stash` keyword grammar entirely.
assert_rc "update-ref -d refs/stash"   2 "$(run_case "$(j_bash 'git update-ref -d refs/stash')")"
assert_rc "update-ref write refs/stash" 2 "$(run_case "$(j_bash 'git update-ref refs/stash deadbeef')")"
assert_rc "symbolic-ref -d refs/stash" 2 "$(run_case "$(j_bash 'git symbolic-ref -d refs/stash')")"
assert_rc "update-ref -d via -C worktree" 2 "$(run_case "$(j_bash 'git -C /c/repo/.claude/worktrees/other update-ref -d refs/stash')")"
# codex-1 (CR round on HIMMEL-2077): `update-ref --stdin` reads its ref
# commands from STDIN DATA, so `refs/stash` in a piped `printf` sits in a
# DIFFERENT clause than `update-ref` and the same-clause rule above never
# sees it — refuse `--stdin` unconditionally instead (the batch target is
# opaque to a command-string regex).
assert_rc "update-ref --stdin (refs/stash via piped data)" 2 "$(run_case "$(j_bash "printf 'delete refs/stash\n' | git update-ref --stdin")")"
assert_rc "update-ref --stdin (unrelated target, still refused)" 2 "$(run_case "$(j_bash "printf 'delete refs/heads/foo\n' | git update-ref --stdin")")"
# codex-1 (CR round 2, HIMMEL-2077): outside quotes, a shell removes a `\`
# before the NEXT character and passes that character through literally, so
# `refs/sta\sh` reaches git as `refs/stash` while looking different to a
# plain-string match.
assert_rc 'update-ref -d refs/sta\sh (backslash evasion)' 2 "$(run_case "$(j_bash 'git update-ref -d refs/sta\sh')")"
assert_rc 'symbolic-ref -d ref\s/stash (backslash evasion)' 2 "$(run_case "$(j_bash 'git symbolic-ref -d ref\s/stash')")"
# codex-1 (CR round 3, HIMMEL-2077): adjacent quoted/unquoted shell segments
# with NO separator between them concatenate into ONE word, so
# `refs/"stash"` and `refs/'stash'` also reach git as the literal
# `refs/stash` -- same evasion class as the backslash case, different
# mechanism (shell quote-removal on concatenation, not escape-removal).
assert_rc 'update-ref -d refs/"stash" (quote-concat evasion)' 2 "$(run_case "$(j_bash 'git update-ref -d refs/"stash"')")"
assert_rc "update-ref -d refs/'stash' (quote-concat evasion)" 2 "$(run_case "$(j_bash "git update-ref -d refs/'stash'")")"
# codex-1 (CR round 3, HIMMEL-2077): the SAME evasion classes apply to the
# `--stdin` literal, not just `refs/stash` -- `--st\din` and `--st"d"in`
# both reach git as `--stdin`.
assert_rc 'update-ref --st\din (stdin backslash evasion)' 2 "$(run_case "$(j_bash "printf 'delete refs/stash\n' | git update-ref --st\din")")"
assert_rc 'update-ref --st"d"in (stdin quote-concat evasion)' 2 "$(run_case "$(j_bash 'printf "delete refs/stash\n" | git update-ref --st"d"in')")"

# --- ALLOW cases (expect rc=0) ---
assert_rc "git stash list"            0 "$(run_case "$(j_bash 'git stash list')")"
assert_rc "git stash show -p"         0 "$(run_case "$(j_bash 'git stash show -p stash@{0}')")"
assert_rc "git stash apply"           0 "$(run_case "$(j_bash 'git stash apply stash@{0}')")"
assert_rc "git stash create"          0 "$(run_case "$(j_bash 'git stash create')")"
assert_rc "git stash --help"          0 "$(run_case "$(j_bash 'git stash --help')")"
assert_rc "git -C <path> stash list"  0 "$(run_case "$(j_bash 'git -C /c/repo stash list')")"
assert_rc "git -c 'q=a b' stash list" 0 "$(run_case "$(j_bash "git -c 'foo.bar=a b' stash list")")"
# The race-free snapshot the deny message prescribes must not be denied by the
# very guard that prescribes it: `create` writes no ref, and the `$(` puts it at
# command position, so both halves have to pass.
# shellcheck disable=SC2016  # the literal $(...) is the payload under test
assert_rc "tag \"$(git stash create)\""  0 "$(run_case "$(j_bash 'git tag wip-leg16 "$(git stash create)"')")"
assert_rc "git stash apply <tag>"     0 "$(run_case "$(j_bash 'git stash apply wip-leg16')")"
# The continuation tolerance must not swallow the verb: a continued READ is
# still a read. And SEP requires the backslash, so a plain `;` stays a command
# boundary — `stash` alone is not git.
assert_rc "continuation before list"  0 "$(run_case "$(j_bash 'git stash \
list')")"
assert_rc "git ; stash drop"          0 "$(run_case "$(j_bash 'git status; stash drop')")"
# The whole point of the COMMAND-POSITION anchor: reading/searching for the
# string must never be refused (this suite's own source contains it).
assert_rc "grep for 'git stash'"      0 "$(run_case "$(j_bash 'grep -rn "git stash" scripts/')")"
assert_rc "grep for git stash drop"   0 "$(run_case "$(j_bash 'grep -rn "git stash drop" scripts/hooks/')")"
assert_rc "comment mentions git stash" 0 "$(run_case "$(j_bash 'echo "# never git stash pop here"')")"
assert_rc "cat the guard itself"      0 "$(run_case "$(j_bash 'cat scripts/hooks/block-git-stash.sh')")"
# Neighbouring git verbs are none of this hook's business.
assert_rc "git status"                0 "$(run_case "$(j_bash 'git status -sb')")"
assert_rc "git push"                  0 "$(run_case "$(j_bash 'git push')")"
assert_rc "gitk stash"                0 "$(run_case "$(j_bash 'gitk stash')")"
# The sanctioned alternative must not be caught by its own deny message.
assert_rc "checkpoint ref update"     0 "$(run_case "$(j_bash 'git update-ref refs/checkpoints/leg16 HEAD')")"
# Non-shell tools are out of scope.
assert_rc "Read tool payload"         0 "$(run_case '{"tool_name":"Read","tool_input":{"command":"git stash drop"}}')"

# --- MALFORMED JSON case (expect rc=2, fail closed) ---
assert_rc "truncated JSON + stash drop" 2 "$(run_case '{"tool_name":"Bash","tool_input":{"command":"git stash drop"')"

# --- EMPTY/BLANK stdin (expect rc=2, fail closed) -- HIMMEL-2123 RETASK R2123A:
# `read -d ''` on EOF leaves $input empty with no error to catch, and `jq
# <<<""` emits zero values with zero errors, so the malformed-JSON guard
# never fired and this silently fell open (rc=0) before the explicit blank
# check was added.
assert_rc "empty stdin"      2 "$(run_case '')"
assert_rc "whitespace-only stdin" 2 "$(run_case '   ')"

# --- NON-STRING command field (expect rc=2, fail closed) -- HIMMEL-2123
# RETASK R2123A: jq's `+` is type-strict, so a present-but-non-string
# `command` (e.g. a JSON array) made the combined extraction throw a type
# error that the `catch empty` swallowed, silently blanking BOTH tool and
# cmd and falling through to allow. The hook now closes it by EXPLICITLY
# erroring (`error("non-string-command")`) whenever `command`/`cmd` is
# present with a non-string, non-null type -- caught by the same
# `if ! result=$(...)` branch as malformed JSON, so it fails CLOSED. (An
# earlier `|tostring` attempt was rejected: it renders arrays COMPACT,
# while old's `jq -r` rendered them pretty-printed multi-line, and that
# multi-line shape was what actually let the stash-mutation match still
# fire on old -- `tostring` doesn't reproduce it, so explicit fail-closed
# is the correct fix, not a tostring-based allow.)
assert_rc "array command + stash drop" 2 "$(run_case '{"tool_name":"Bash","tool_input":{"command":["git stash drop"]}}')"

# --- BYPASS case ---
assert_rc "GIT_STASH_OK bypass"       0 "$(run_case "$(j_bash 'git stash drop')" "GIT_STASH_OK=1")"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "All cases passed."
    exit 0
else
    echo "$FAILED case(s) failed."
    exit 1
fi
