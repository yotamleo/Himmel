#!/usr/bin/env bash
# Smoke test for scripts/hooks/auto-approve-safe-bash.sh.
#
# Usage: bash scripts/hooks/test-auto-approve-safe-bash.sh
#
# Contract under test (NOTE: inverted vs the block-* hooks):
#   * ALLOW  → stdout contains "permissionDecision":"allow"  (auto-approved)
#   * PASS   → no such decision on stdout                    (falls through to
#                                                             normal prompt)
#   The hook ALWAYS exits 0 and NEVER blocks/denies.
#
# Exit codes:
#   0 — all cases passed
#   1 — at least one case failed
# Single-quoted $t / $(…) / `…` below are deliberate literal test payloads —
# the hook must see them unexpanded, so do not "fix" them to double quotes.
# shellcheck disable=SC2016
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/auto-approve-safe-bash.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK"

FAILED=0

j_bash() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }
j_pwsh() { printf '{"tool_name":"PowerShell","tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }

# Returns ALLOW if the hook emitted an allow decision, else PASS.
decide() {
    local out
    out=$(printf '%s' "$1" | bash "$HOOK" 2>/dev/null)
    if printf '%s' "$out" | grep -q '"permissionDecision":"allow"'; then
        echo "ALLOW"
    else
        echo "PASS"
    fi
}

assert() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label ($actual)"
    else
        echo "FAIL $label — expected $expected, got $actual"
        FAILED=$((FAILED + 1))
    fi
}

# --- ALLOW: the simple_expansion cases that motivate this hook ---
assert "jira get literal"          ALLOW "$(decide "$(j_bash 'node scripts/jira/dist/index.js get LUNA-57')")"
assert "jira get loop with \$t"    ALLOW "$(decide "$(j_bash 'for t in LUNA-57 LUNA-58; do node scripts/jira/dist/index.js get $t; done')")"
assert "jira write (transition)"   ALLOW "$(decide "$(j_bash 'node scripts/jira/dist/index.js transition LUNA-60 Done')")"
assert "cat \$f loop"              ALLOW "$(decide "$(j_bash 'for f in a b c; do cat $f; done')")"
assert "git log oneline"           ALLOW "$(decide "$(j_bash 'git log --oneline -1')")"
assert "git -C path status"        ALLOW "$(decide "$(j_bash 'git -C /some/repo status')")"
assert "git log piped grep head"   ALLOW "$(decide "$(j_bash 'git log | grep fix | head -5')")"
assert "git diff piped head"       ALLOW "$(decide "$(j_bash 'git diff HEAD~1 | head')")"
assert "cat README"                ALLOW "$(decide "$(j_bash 'cat README.md')")"
assert "grep wc pipe"              ALLOW "$(decide "$(j_bash 'grep -rn TODO src | wc -l')")"
assert "ls && cat"                 ALLOW "$(decide "$(j_bash 'ls -la && cat foo.txt')")"
assert "find -name"                ALLOW "$(decide "$(j_bash "find . -name '*.sh'")")"
assert "gh pr list"                ALLOW "$(decide "$(j_bash 'gh pr list')")"
assert "gh pr view N"              ALLOW "$(decide "$(j_bash 'gh pr view 201')")"
assert "printf var"                ALLOW "$(decide "$(j_bash 'printf "%s" "$x"')")"
assert "redirect to /dev/null"     ALLOW "$(decide "$(j_bash 'cat foo 2>/dev/null')")"
assert "fd-dup 2>&1 piped"         ALLOW "$(decide "$(j_bash 'grep x f 2>&1 | head')")"
assert "echo to /dev/null"         ALLOW "$(decide "$(j_bash 'echo hi > /dev/null')")"
assert "if grep then echo"         ALLOW "$(decide "$(j_bash 'if grep -q x f; then echo y; fi')")"
assert "while read loop"           ALLOW "$(decide "$(j_bash 'while read l; do grep $l f; done < input')")"
assert "tr cut pipe"               ALLOW "$(decide "$(j_bash 'cat f | tr a-z A-Z | cut -c1-5')")"
assert "git show piped"            ALLOW "$(decide "$(j_bash 'git show HEAD:README.md | head -20')")"

# --- PASS-THROUGH: must NOT auto-approve (falls to normal prompt) ---
assert "rm -rf"                    PASS "$(decide "$(j_bash 'rm -rf foo')")"
assert "git push"                  PASS "$(decide "$(j_bash 'git push origin main')")"
assert "git commit"                PASS "$(decide "$(j_bash 'git commit -m x')")"
assert "git branch -d"             PASS "$(decide "$(j_bash 'git branch -d feature')")"
assert "git config write"          PASS "$(decide "$(j_bash 'git config user.name x')")"
assert "mv"                        PASS "$(decide "$(j_bash 'mv a b')")"
assert "npm install"               PASS "$(decide "$(j_bash 'npm install')")"
assert "bash script"               PASS "$(decide "$(j_bash 'bash deploy.sh')")"
assert "bare node"                 PASS "$(decide "$(j_bash 'node server.js')")"
assert "gh pr merge"               PASS "$(decide "$(j_bash 'gh pr merge 201')")"
assert "command substitution"     PASS "$(decide "$(j_bash 'cat $(echo .env)')")"
assert "backtick"                  PASS "$(decide "$(j_bash 'echo `whoami`')")"
assert "process substitution"     PASS "$(decide "$(j_bash 'diff <(ls a) <(ls b)')")"
assert "awk system()"             PASS "$(decide "$(j_bash "awk 'BEGIN{system(\"rm -rf /\")}'")")"
assert "output redirect to file"  PASS "$(decide "$(j_bash 'cat foo > bar.txt')")"
assert "find -delete"             PASS "$(decide "$(j_bash 'find . -delete')")"
assert "find -exec rm"            PASS "$(decide "$(j_bash 'find . -exec rm {} ;')")"
assert "variable as binary"       PASS "$(decide "$(j_bash 'for c in rm; do $c foo; done')")"
assert "if rm then"               PASS "$(decide "$(j_bash 'if rm -rf /; then echo y; fi')")"
assert "xargs runner"             PASS "$(decide "$(j_bash 'ls | xargs rm')")"
assert "PowerShell not handled"   PASS "$(decide "$(j_pwsh 'Get-ChildItem')")"
assert "empty input"              PASS "$(decide '{}')"
assert "tee write"                PASS "$(decide "$(j_bash 'cat f | tee out.txt')")"

# --- Regression locks for review-found CRITICAL/MEDIUM bypasses ---
# node marker must be the script node RUNS, not just present somewhere (RCE).
assert "node -e with marker arg"  PASS "$(decide "$(j_bash 'node -e code scripts/jira/dist/index.js')")"
assert "node other script+marker" PASS "$(decide "$(j_bash 'node /tmp/evil.js x/scripts/jira/dist/index.js')")"
assert "node --eval"              PASS "$(decide "$(j_bash 'node --eval code')")"
# interpreters drop from the safe set (write-in-place / shell-out capable).
assert "sed -i write"             PASS "$(decide "$(j_bash 'sed -i s/a/b/ /tmp/victim')")"
assert "sed bare"                 PASS "$(decide "$(j_bash 'sed s/a/b/ f')")"
assert "awk bare"                 PASS "$(decide "$(j_bash 'awk {print} f')")"
# sort -o writes a file without a > redirect.
assert "sort -o write"            PASS "$(decide "$(j_bash 'sort -o /tmp/pwned f')")"
assert "sort --output write"      PASS "$(decide "$(j_bash 'sort --output=/tmp/pwned f')")"
# /dev/null sink must be token-anchored.
assert "devnull suffix write"     PASS "$(decide "$(j_bash 'cat foo >/dev/null.bak')")"
# sort/find without write flags still ALLOW.
assert "sort plain pipe"          ALLOW "$(decide "$(j_bash 'cat f | sort | uniq -c')")"
# node running the jira CLI (any subcommand) is operator-allow-listed → ALLOW.
assert "node jira after flags"    ALLOW "$(decide "$(j_bash 'node --no-warnings scripts/jira/dist/index.js list')")"

# --- Round-2 locks: git/gh command-execution sinks (config + env vars) ---
assert "git -c diff.external"     PASS  "$(decide "$(j_bash 'git -c diff.external=touch diff HEAD~1')")"
assert "git -c core.pager"        PASS  "$(decide "$(j_bash 'git -c core.pager=sh log')")"
assert "git --exec-path"          PASS  "$(decide "$(j_bash 'git --exec-path=/tmp/evil log')")"
assert "GIT_EXTERNAL_DIFF env"    PASS  "$(decide "$(j_bash 'GIT_EXTERNAL_DIFF=touch git diff HEAD~1')")"
assert "GIT_PAGER env"            PASS  "$(decide "$(j_bash 'GIT_PAGER=sh git log')")"
assert "PAGER env"                PASS  "$(decide "$(j_bash 'PAGER=sh git log')")"
assert "LD_PRELOAD env"           PASS  "$(decide "$(j_bash 'LD_PRELOAD=/tmp/x.so grep foo f')")"
assert "NODE_OPTIONS env"         PASS  "$(decide "$(j_bash 'NODE_OPTIONS=--require=/tmp/x node scripts/jira/dist/index.js get X')")"
assert "gh pr view --web"         PASS  "$(decide "$(j_bash 'gh pr view --web 1')")"
# git read subcommands with exec/write flags must NOT auto-approve.
assert "git grep open-in-pager"   PASS  "$(decide "$(j_bash 'git grep --open-files-in-pager=sh foo')")"
assert "git grep -Ocmd"           PASS  "$(decide "$(j_bash 'git grep -Osh foo')")"
assert "git diff --output write"  PASS  "$(decide "$(j_bash 'git diff --output=/tmp/clobber HEAD~1')")"
assert "git log --output write"   PASS  "$(decide "$(j_bash 'git log --output=/tmp/clobber')")"
assert "git show --ext-diff"      PASS  "$(decide "$(j_bash 'git show --ext-diff HEAD')")"
# git ls-remote runs arbitrary cmds via ext:: transport / --upload-pack (ACE).
assert "git ls-remote ext::"      PASS  "$(decide "$(j_bash 'git ls-remote ext::sh -c id')")"
assert "git ls-remote upload-pack" PASS "$(decide "$(j_bash 'git ls-remote --upload-pack=touch origin')")"
# git symbolic-ref 2-arg form REWRITES HEAD (mutating); query form is read-only.
assert "git symbolic-ref write"   PASS  "$(decide "$(j_bash 'git symbolic-ref HEAD refs/heads/evil')")"
assert "git symbolic-ref query"   ALLOW "$(decide "$(j_bash 'git symbolic-ref HEAD')")"
# bare & is a real separator: the segment after it must be vetted too.
assert "bare & separator (rm)"    PASS  "$(decide "$(j_bash 'cat a & rm b')")"
assert "bare & glued (rm)"        PASS  "$(decide "$(j_bash 'cat a&rm b')")"
# xxd writes a file given a 2nd positional or -r (reverse to binary).
assert "xxd outfile write"        PASS  "$(decide "$(j_bash 'xxd in out')")"
assert "xxd -r write"             PASS  "$(decide "$(j_bash 'xxd -r in out')")"
assert "xxd read single file"     ALLOW "$(decide "$(j_bash 'xxd file | head')")"
# fd-dups / background must still parse as one safe segment.
assert "2>&1 fd-dup safe"         ALLOW "$(decide "$(j_bash 'grep x f 2>&1 | head')")"
assert "trailing & background"    ALLOW "$(decide "$(j_bash 'cat a &')")"
assert "git grep plain"           ALLOW "$(decide "$(j_bash 'git grep -n TODO | head')")"

# --- Round-4 locks: git filter exec + & digit-redirect splitter evasion ---
assert "git show --textconv"      PASS  "$(decide "$(j_bash 'git -C /tmp/r show --textconv HEAD:f')")"
assert "git log --textconv"       PASS  "$(decide "$(j_bash 'git log --textconv')")"
assert "git diff --filters"       PASS  "$(decide "$(j_bash 'git diff --filters')")"
assert "amp digit redirect run"   PASS  "$(decide "$(j_bash 'cat a &2</tmp/a touch /tmp/ranit')")"
# fd-dups must STILL survive the tightened splitter.
assert "2>&1 still intact"        ALLOW "$(decide "$(j_bash 'grep x f 2>&1 | head')")"
assert "amp-redirect &>devnull"   ALLOW "$(decide "$(j_bash 'grep x f &>/dev/null')")"

# --- Round-5 locks: safe-set binaries with file-write flags ---
assert "tree -o write"            PASS  "$(decide "$(j_bash 'tree -o out.html')")"
assert "tree --output write"      PASS  "$(decide "$(j_bash 'tree --output=out.html .')")"
assert "base64 -o write"          PASS  "$(decide "$(j_bash 'base64 -o /tmp/x in')")"
assert "file -C compile write"    PASS  "$(decide "$(j_bash 'file -C -m mymagic')")"
# plain forms of those binaries still ALLOW.
assert "tree plain"               ALLOW "$(decide "$(j_bash 'tree -L 2 src')")"
assert "base64 decode stdout"     ALLOW "$(decide "$(j_bash 'cat f | base64 -d')")"
assert "file plain"               ALLOW "$(decide "$(j_bash 'file README.md')")"

# --- Correctness-CR locks: false-negatives that should ALLOW ---
assert "xxd file + redirect"      ALLOW "$(decide "$(j_bash 'xxd file 2>/dev/null')")"
assert "git --git-dir= equals"    ALLOW "$(decide "$(j_bash 'git --git-dir=/repo log --oneline')")"
# innocuous locale/TZ env prefixes are still safe → ALLOW.
assert "LC_ALL locale prefix"     ALLOW "$(decide "$(j_bash 'LC_ALL=C sort f')")"
assert "TZ prefix"                ALLOW "$(decide "$(j_bash 'TZ=UTC date')")"
assert "git -C dir still ok"      ALLOW "$(decide "$(j_bash 'git -C /repo log --oneline')")"

# --- HIMMEL-205: cd/pushd/popd navigation so cd-prefixed safe cmds ALLOW ---
# The motivating bug: a `cd <repo> && node …/jira transition …` fell through
# (cd unrecognised) → auto-mode classifier denied the jira write.
assert "cd && jira transition"    ALLOW "$(decide "$(j_bash 'cd /c/repo && node scripts/jira/dist/index.js transition LUNA-65 Done')")"
assert "cd && jira (piped, 2 ops)" ALLOW "$(decide "$(j_bash 'cd /c/repo && node scripts/jira/dist/index.js transition LUNA-65 Done 2>&1 | tail -3 && node scripts/jira/dist/index.js transition LUNA-66 Done 2>&1 | tail -3')")"
assert "cd && cat"                ALLOW "$(decide "$(j_bash 'cd src && cat README.md')")"
assert "cd alone"                 ALLOW "$(decide "$(j_bash 'cd /some/dir')")"
assert "pushd && grep"            ALLOW "$(decide "$(j_bash 'pushd src && grep -rn TODO .')")"
assert "popd alone"              ALLOW "$(decide "$(j_bash 'popd')")"
# cd does NOT launder an unsafe later segment, nor a substituted target.
assert "cd && rm still PASS"       PASS  "$(decide "$(j_bash 'cd /tmp && rm -rf foo')")"
assert "cd \$(…) substitution"     PASS  "$(decide "$(j_bash 'cd $(cat target) && ls')")"

# --- HIMMEL-209: quote-aware split — separators INSIDE quotes are literal ---
# A jira comment/desc body containing newlines / ; / | / > must still ALLOW.
# The old quote-blind sed split shredded a multi-line body into junk segments
# (e.g. "LUNA-36 (catch-up) …") that failed is_safe_bin → whole write denied.
nl=$'\n'
assert "comment newline body"      ALLOW "$(decide "$(j_bash "node scripts/jira/dist/index.js comment LUNA-26 'first${nl}second'")")"
assert "comment semicolon body"    ALLOW "$(decide "$(j_bash "node scripts/jira/dist/index.js comment LUNA-26 'do x; then y'")")"
assert "comment pipe body"         ALLOW "$(decide "$(j_bash "node scripts/jira/dist/index.js comment LUNA-26 'a | b'")")"
assert "comment gt body"           ALLOW "$(decide "$(j_bash "node scripts/jira/dist/index.js comment LUNA-26 'fewer > more'")")"
assert "comment dq separators"     ALLOW "$(decide "$(j_bash 'node scripts/jira/dist/index.js comment LUNA-26 "a; b | c > d"')")"
# SAFETY: a real (UNQUOTED) separator after a safe write must still gate.
assert "jira then rm still PASS"   PASS  "$(decide "$(j_bash "node scripts/jira/dist/index.js get LUNA-1; rm -rf x")")"
# SAFETY: a real (UNQUOTED) redirect to a real file must still gate.
assert "real redirect still PASS"  PASS  "$(decide "$(j_bash 'cat foo > realfile.txt')")"
# SAFETY: unbalanced quotes → fail closed (never grant on an ambiguous parse).
assert "unbalanced quote fails"    PASS  "$(decide "$(j_bash "node scripts/jira/dist/index.js comment LUNA-26 'oops")")"

# --- HIMMEL-212: git push --force-with-lease on a NON-main branch → ALLOW ---
# These cases depend on the CURRENT branch (the hook calls `git rev-parse
# --abbrev-ref HEAD`), so they run inside a throwaway repo whose HEAD we control
# rather than relying on the test's launch directory. decide_in cd's first.
decide_in() {
    local dir="$1" out
    out=$(cd "$dir" && printf '%s' "$2" | bash "$HOOK" 2>/dev/null)
    if printf '%s' "$out" | grep -q '"permissionDecision":"allow"'; then echo "ALLOW"; else echo "PASS"; fi
}

FWL_ROOT=$(mktemp -d); if command -v cygpath >/dev/null 2>&1; then FWL_ROOT=$(cygpath -m "$FWL_ROOT"); fi
# shellcheck disable=SC2329,SC2317
fwl_cleanup() {
    if [ -n "${FWL_ROOT:-}" ] && [ -d "$FWL_ROOT" ]; then
        rm -rf "$FWL_ROOT" 2>/dev/null || true
    fi
}
trap fwl_cleanup EXIT
FWL_REPO="$FWL_ROOT/repo"
git init -q --initial-branch=main "$FWL_REPO" 2>/dev/null || { git init -q "$FWL_REPO"; git -C "$FWL_REPO" symbolic-ref HEAD refs/heads/main; }
git -C "$FWL_REPO" -c user.email=t@test.com -c user.name=test commit -q --allow-empty -m c1
git -C "$FWL_REPO" checkout -q -b feat/x

# On a feature branch: the safe lease forms ALLOW.
assert "fwl bare on feat"          ALLOW "$(decide_in "$FWL_REPO" "$(j_bash 'git push --force-with-lease')")"
assert "fwl =val on feat"          ALLOW "$(decide_in "$FWL_REPO" "$(j_bash 'git push --force-with-lease=origin/feat origin feat/x')")"
assert "fwl with -C on feat"       ALLOW "$(decide_in "$FWL_REPO" "$(j_bash 'git -C . push --force-with-lease origin feat/x')")"
# Bare --force / -f (no lease) NEVER auto-approve — stay deny-listed.
assert "bare --force on feat"      PASS  "$(decide_in "$FWL_REPO" "$(j_bash 'git push --force origin feat/x')")"
assert "bare -f on feat"           PASS  "$(decide_in "$FWL_REPO" "$(j_bash 'git push -f origin feat/x')")"
assert "lease+bare force on feat"  PASS  "$(decide_in "$FWL_REPO" "$(j_bash 'git push --force-with-lease --force origin feat/x')")"
# Targeting main is refused even from a feature branch.
assert "fwl targets main ref"      PASS  "$(decide_in "$FWL_REPO" "$(j_bash 'git push --force-with-lease origin main')")"
assert "fwl targets origin/main"   PASS  "$(decide_in "$FWL_REPO" "$(j_bash 'git push --force-with-lease origin HEAD:main')")"
assert "fwl +main force refspec"   PASS  "$(decide_in "$FWL_REPO" "$(j_bash 'git push --force-with-lease origin +main')")"
# Exec-sink global flags refuse even with a lease push.
assert "fwl with -c pager sink"    PASS  "$(decide_in "$FWL_REPO" "$(j_bash 'git -c core.pager=sh push --force-with-lease')")"
# A plain (non-force) push still falls through — unchanged behavior.
assert "plain push still PASS"     PASS  "$(decide_in "$FWL_REPO" "$(j_bash 'git push origin feat/x')")"

# On main: even a lease push is NOT auto-approved (fail safe; pre-push refuses).
git -C "$FWL_REPO" checkout -q main
assert "fwl on main branch"        PASS  "$(decide_in "$FWL_REPO" "$(j_bash 'git push --force-with-lease')")"
# Detached HEAD: branch unresolvable → NOT granted.
git -C "$FWL_REPO" checkout -q --detach
assert "fwl detached HEAD"         PASS  "$(decide_in "$FWL_REPO" "$(j_bash 'git push --force-with-lease')")"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "All cases passed."
    exit 0
else
    echo "$FAILED case(s) failed."
    exit 1
fi
