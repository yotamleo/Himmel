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

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

HOOK="$(cd "$(dirname "$0")" && pwd)/auto-approve-safe-bash.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK"

FAILED=0

j_bash() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }
j_pwsh() { printf '{"tool_name":"PowerShell","tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }

# Returns ALLOW/DENY if the hook emitted that decision, else PASS.
decide() {
    local out
    out=$(printf '%s' "$1" | bash "$HOOK" 2>/dev/null)
    if grepq "$out" '"permissionDecision":"deny"'; then
        echo "DENY"
    elif grepq "$out" '"permissionDecision":"allow"'; then
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
    if grepq "$out" '"permissionDecision":"allow"'; then echo "ALLOW"; else echo "PASS"; fi
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
# HIMMEL-297: master is a protected default too — targeting it is refused
# even from a feature branch, same as main.
assert "fwl targets master ref"    PASS  "$(decide_in "$FWL_REPO" "$(j_bash 'git push --force-with-lease origin master')")"
assert "fwl targets HEAD:master"   PASS  "$(decide_in "$FWL_REPO" "$(j_bash 'git push --force-with-lease origin HEAD:master')")"
assert "fwl +master force refspec" PASS  "$(decide_in "$FWL_REPO" "$(j_bash 'git push --force-with-lease origin +master')")"
assert "fwl targets origin/master" PASS  "$(decide_in "$FWL_REPO" "$(j_bash 'git push --force-with-lease origin/master')")"
assert "fwl master:* refspec"      PASS  "$(decide_in "$FWL_REPO" "$(j_bash 'git push --force-with-lease origin master:feat/x')")"
# Exec-sink global flags refuse even with a lease push.
assert "fwl with -c pager sink"    PASS  "$(decide_in "$FWL_REPO" "$(j_bash 'git -c core.pager=sh push --force-with-lease')")"
# A plain (non-force) push still falls through — unchanged behavior.
assert "plain push still PASS"     PASS  "$(decide_in "$FWL_REPO" "$(j_bash 'git push origin feat/x')")"

# On main: even a lease push is NOT auto-approved (fail safe; pre-push refuses).
git -C "$FWL_REPO" checkout -q main
assert "fwl on main branch"        PASS  "$(decide_in "$FWL_REPO" "$(j_bash 'git push --force-with-lease')")"
# On master: master is a protected default too (HIMMEL-297) — a lease push made
# while sitting on master is NOT auto-approved either.
git -C "$FWL_REPO" checkout -q -b master
assert "fwl on master branch"      PASS  "$(decide_in "$FWL_REPO" "$(j_bash 'git push --force-with-lease')")"
# Detached HEAD: branch unresolvable → NOT granted.
git -C "$FWL_REPO" checkout -q --detach
assert "fwl detached HEAD"         PASS  "$(decide_in "$FWL_REPO" "$(j_bash 'git push --force-with-lease')")"

# --- HIMMEL-2121: deny a root-anchored find with no -maxdepth ---
# Specimen: `find / -iname harvest-clips -not -path /node_modules/` survived
# its dead parent 20+ min and pinned the machine's saturated spawn path.
assert "find / no maxdepth"        DENY  "$(decide "$(j_bash 'find / -iname harvest-clips -not -path /node_modules/')")"
assert "find windows drive root"   DENY  "$(decide "$(j_bash 'find C:\ -name x')")"
assert "find \$HOME root"          DENY  "$(decide "$(j_bash 'find $HOME -name x')")"
assert "find ~ root"               DENY  "$(decide "$(j_bash 'find ~ -name x')")"
assert "find /c msys drive root"   DENY  "$(decide "$(j_bash 'find /c -iname y')")"
# Not root-anchored → unchanged (falls through to the pre-existing scan).
assert "find . still ALLOW"        ALLOW "$(decide "$(j_bash "find . -name '*.md'")")"
assert "find scripts still ALLOW"  ALLOW "$(decide "$(j_bash 'find scripts -type f')")"
assert "find /c/subpath ALLOW"     ALLOW "$(decide "$(j_bash 'find /c/Users/x/repo -iname y')")"
# Root-anchored but -maxdepth present → not the walker shape, still ALLOW.
assert "find / with maxdepth"      ALLOW "$(decide "$(j_bash 'find / -maxdepth 2 -name x')")"
# Bypass: FIND_ROOTWALK_OK=1 skips the deny entirely (allowed like a normal
# safe find would be — no -delete/-exec present).
assert "find / bypass env"         ALLOW "$(FIND_ROOTWALK_OK=1 decide "$(j_bash 'find / -iname x')")"
# Still-guarded shapes (existing behavior, unaffected by the new deny): not
# root-anchored, so segment_is_safe's own guard (not the new deny) applies.
assert "find . -delete still PASS" PASS  "$(decide "$(j_bash 'find . -delete')")"

# --- Round-2 locks (independent review): root-anchor strings in EXPRESSION
# arg positions must NOT deny — only a true PATH OPERAND counts.
assert "find . -name tilde-expr"   ALLOW "$(decide "$(j_bash 'find . -name "~"')")"
assert "find . -path HOME-expr"    ALLOW "$(decide "$(j_bash 'find . -path "$HOME"')")"
assert "find scripts -newer tilde" ALLOW "$(decide "$(j_bash 'find scripts -newer ~')")"
assert "find . -iname slash-expr"  ALLOW "$(decide "$(j_bash 'find . -iname "/"')")"
assert "find no path operand"      ALLOW "$(decide "$(j_bash 'find -iname x')")"
# Trailing-slash home variants must still DENY.
assert "find HOME/ trailing slash" DENY  "$(decide "$(j_bash 'find $HOME/ -iname x')")"

# --- Round-3 locks (cross-model critic panel): leading find OPTIONS hiding a
# root path, -maxdepth-as-a-VALUE evasion, pre-tripwire ordering, quoted
# -maxdepth, and a stricter FIND_ROOTWALK_OK bypass ---
assert "find -L / leading option"  DENY  "$(decide "$(j_bash 'find -L / -name x')")"
assert "find -name -maxdepth val"  DENY  "$(decide "$(j_bash 'find / -name -maxdepth')")"
# A root-anchored find carrying a substitution must STILL deny — the deny
# scan now runs before the global $(...) tripwire (codex-3).
assert "find w/ substitution DENY" DENY  "$(decide "$(j_bash 'find / -iname $(hostname)')")"
assert "find quoted -maxdepth"     ALLOW "$(decide "$(j_bash 'find / "-maxdepth" 2 -name x')")"
# FIND_ROOTWALK_OK is truthy-only now: "0" must NOT bypass, "1" still does.
assert "bypass=0 still DENIES"     DENY  "$(FIND_ROOTWALK_OK=0 decide "$(j_bash 'find / -iname x')")"
assert "bypass=1 still ALLOWS"     ALLOW "$(FIND_ROOTWALK_OK=1 decide "$(j_bash 'find / -iname x')")"

# --- Round-4 lock (cross-model critic panel, codex-2 round 2 confirmed): a
# -maxdepth+digits pair sitting inside an -exec action's own payload must
# NOT count as find's own -maxdepth flag.
assert "maxdepth inside -exec DENY" DENY  "$(decide "$(j_bash 'find / -exec echo -maxdepth 2 ;')")"
# Unchanged: a real top-level -maxdepth still ALLOWS.
assert "real -maxdepth still ALLOW" ALLOW "$(decide "$(j_bash 'find / -maxdepth 2 -name x')")"
# Unchanged: scoped path with -delete stays un-denied (segment_is_safe's own
# guard handles it, not the rootwalk deny).
assert "find . -delete still PASS2" PASS  "$(decide "$(j_bash 'find . -delete')")"

# --- Round-5 locks (cross-model critic panel, round 4): root-equivalent
# canonicalization, `--` option terminator, and resuming the -maxdepth scan
# after an action primary's payload ---
assert "find /// canonicalizes"    DENY  "$(decide "$(j_bash 'find /// -name x')")"
assert "find /. canonicalizes"     DENY  "$(decide "$(j_bash 'find /. -name x')")"
assert "find /./ canonicalizes"    DENY  "$(decide "$(j_bash 'find /./ -name x')")"
assert "find -- / honors terminator" DENY "$(decide "$(j_bash 'find -- / -name x')")"
# A genuinely bounded -exec (terminated with \; before -maxdepth) must not be
# denied by the rootwalk check — but -exec is ALSO its own unrelated
# unapproved shape in segment_is_safe (it can execute), so the overall
# decision is PASS (not denied, not auto-approved), same pattern as the
# -delete cases below. Verified directly: this is NOT a DENY.
assert "bounded -exec + -maxdepth" PASS  "$(decide "$(j_bash 'find / -exec echo {} \; -maxdepth 2')")"
# -delete takes no payload, so it never shields a real -maxdepth after it —
# but a `find /` with no -maxdepth at all is still a rootwalk regardless of
# -delete being present.
assert "find / -delete DENY"       DENY  "$(decide "$(j_bash 'find / -delete')")"
# -maxdepth after -delete is real → not denied; -delete's OWN guard in
# segment_is_safe still keeps this un-approved, so PASS (not ALLOW).
assert "find / -delete -maxdepth"  PASS  "$(decide "$(j_bash 'find / -delete -maxdepth 2')")"

# --- Round-6 locks (cross-model critic panel, round 5, FINAL): collapse
# backslash runs (double-backslash C:\\, common when an agent types "C:\\"
# inside double quotes) and add $USERPROFILE/${USERPROFILE} home anchors
# (Git Bash exports USERPROFILE) ---
assert "find C:\\\\ double backslash" DENY "$(decide "$(j_bash 'find C:\\ -name x')")"
assert "find \$USERPROFILE"        DENY  "$(decide "$(j_bash 'find $USERPROFILE -name x')")"
assert "find \${USERPROFILE}/"     DENY  "$(decide "$(j_bash 'find ${USERPROFILE}/ -name x')")"
# Unchanged: a real MSYS subpath under a drive root still ALLOWS.
assert "find /c/Users/x/repo ALLOW2" ALLOW "$(decide "$(j_bash 'find /c/Users/x/repo -iname y')")"

# --- HIMMEL-2122: shell-word quote semantics + dot-dot root equivalence ---
# Single quotes make variable-shaped text literal; find receives a path named
# `$HOME` / `${USERPROFILE}`, not either environment variable's value.
assert "find single-quoted HOME literal" ALLOW "$(decide "$(j_bash "find '\$HOME' -name x")")"
assert "find single-quoted USERPROFILE literal" ALLOW "$(decide "$(j_bash "find '\${USERPROFILE}' -name x")")"
# Adjacent quoted and unquoted fragments form one shell word. Both spellings
# below execute as `find /`, so they must not evade the rootwalk deny.
assert "find slash + empty quotes" DENY "$(decide "$(j_bash "find /'' -name x")")"
assert "find empty quotes + slash" DENY "$(decide "$(j_bash "find ''/ -name x")")"
# ANSI-C quotes can encode path values, so do not statically approve or deny
# any command containing one.
assert "find ANSI-C quoted slash"   PASS "$(decide "$(j_bash "find \$'/' -name x")")"
assert "find ANSI-C hex slash"      PASS "$(decide "$(j_bash "find \$'\x2f' -name x")")"
assert "find ANSI-C octal slash"    PASS "$(decide "$(j_bash "find \$'\57' -name x")")"
# Locale quotes may be translated by gettext, so do not statically approve or
# deny any command containing one.
assert "find locale-quoted slash"   PASS "$(decide "$(j_bash 'find $"/" -name x')")"
assert "locale-quoted binary"       PASS "$(decide "$(j_bash '$"cat" README.md')")"
# Backslash-newline is removed by Bash before tokenization. With indentation
# the path remains `/`; without it, the following text joins into `/-name`.
assert "find continued root"         DENY  "$(decide "$(j_bash "find /\\${nl} -name x")")"
assert "find continued non-root"     ALLOW "$(decide "$(j_bash "find /\\${nl}-name x")")"
# A backslash-escaped delimiter belongs to the binary word in real Bash; the
# hook must not cook `git\` down to `git` and approve `status` as a subcommand.
assert "escaped-space binary stays PASS" PASS "$(decide "$(j_bash 'git\ status')")"
# A path operand containing /.. can resolve to root and is denied unless a
# real find-level -maxdepth bounds it. Expression arguments remain non-paths.
assert "find /tmp/.. canonicalizes" DENY  "$(decide "$(j_bash 'find /tmp/.. -name x')")"
assert "find nested /.. to root"    DENY  "$(decide "$(j_bash 'find /tmp/foo/../.. -name x')")"
assert "find /tmp/.. with maxdepth" ALLOW "$(decide "$(j_bash 'find /tmp/.. -maxdepth 1 -name x')")"
assert "find /tmp/../var scoped"    ALLOW "$(decide "$(j_bash 'find /tmp/../var -name x')")"
assert "find /tmp/..hidden scoped"  ALLOW "$(decide "$(j_bash 'find /tmp/..hidden -name x')")"
assert "find /.. expression arg"    ALLOW "$(decide "$(j_bash 'find . -path /tmp/..')")"
# Tilde expansion occurs only when the leading tilde is unquoted/unescaped;
# the existing `find ~` case above remains the positive DENY control.
assert "find single-quoted tilde literal" ALLOW "$(decide "$(j_bash "find '~' -name x")")"
assert "find double-quoted tilde literal" ALLOW "$(decide "$(j_bash 'find "~" -name x')")"
assert "find escaped tilde literal"       ALLOW "$(decide "$(j_bash 'find \~ -name x')")"

# --- HIMMEL-3131: queue-lock.sh verbs are a sanctioned single-segment write ---
# `bash` is deliberately not a safe binary and a leading HANDOVER_DIR= is not an
# innocuous assignment, so `HANDOVER_DIR=<root> bash scripts/handover/queue-lock.sh
# release <doc> <token>` fell through to the auto-mode classifier, which read a
# just-landed merge in the narrative and denied it [Merge Without Review]. The
# hook can now approve exactly this shape — ONLY as the whole command (a lone
# segment), never as one segment of a compound. It cannot prove anything about
# the real classifier; these cases pin the hook's own decisions.
QL_R=/home/u/luna/handovers
QL_DOC="$QL_R/yotamleo/himmel/HIMMEL-1-legN1-2026-09-18.md"
QL_TOK='cachyos-x8664-pid3377422'
assert "queue-lock release (HANDOVER_DIR, rel script)" ALLOW "$(decide "$(j_bash "HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh release $QL_DOC $QL_TOK")")"
# An absolute script path is approved only inside a real checkout of THIS repo:
# the one the hook lives in, or a `git worktree list` sibling (the primary).
QL_HERE="$(cd "$(dirname "$HOOK")/../.." && pwd -P)"
QL_PRIMARY="$(git -C "$QL_HERE" worktree list --porcelain | sed -n '1s/^worktree //p')"
QL_FAKE="$(mktemp -d "${TMPDIR:-/tmp}/ql-fake.XXXXXX")"; mkdir -p "$QL_FAKE/scripts/handover" "$QL_FAKE/.git"; : > "$QL_FAKE/scripts/handover/queue-lock.sh"
assert "precondition: primary checkout resolved"  ALLOW "$([ -f "$QL_PRIMARY/scripts/handover/queue-lock.sh" ] && echo ALLOW || echo "PASS:$QL_PRIMARY")"
assert "queue-lock release (abs, own checkout)" ALLOW "$(decide "$(j_bash "HANDOVER_DIR=$QL_R bash $QL_HERE/scripts/handover/queue-lock.sh release $QL_DOC $QL_TOK")")"
assert "queue-lock release (abs, primary)"      ALLOW "$(decide "$(j_bash "HANDOVER_DIR=$QL_R bash $QL_PRIMARY/scripts/handover/queue-lock.sh release $QL_DOC $QL_TOK")")"
assert "ctl: lookalike abs path (absent)"       PASS  "$(decide "$(j_bash "HANDOVER_DIR=$QL_R bash /tmp/x-himmel-3131-absent/scripts/handover/queue-lock.sh release $QL_DOC $QL_TOK")")"
assert "ctl: lookalike abs path (exists + .git)" PASS "$(decide "$(j_bash "HANDOVER_DIR=$QL_R bash $QL_FAKE/scripts/handover/queue-lock.sh release $QL_DOC $QL_TOK")")"
# The RELATIVE script form resolves against the session cwd, so a fake
# scripts/handover/queue-lock.sh in a lookalike cwd must not be approved: the
# payload's `cwd` (else $PWD, when the payload has none) has to be a real
# checkout. j_bash_cwd puts a cwd field in the payload; decide_in runs the hook
# from a directory with no payload cwd (the $PWD fallback).
j_bash_cwd() { printf '{"tool_name":"Bash","cwd":%s,"tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)" "$(printf '%s' "$2" | jq -Rs .)"; }
QL_REL="HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh release $QL_DOC $QL_TOK"
assert "ctl: rel script, payload cwd = lookalike dir"  PASS  "$(decide "$(j_bash_cwd "$QL_FAKE" "$QL_REL")")"
assert "ctl: rel script, payload cwd = absent dir"     PASS  "$(decide "$(j_bash_cwd /tmp/x-himmel-3131-absent "$QL_REL")")"
assert "ctl: rel script, payload cwd = sub-dir"        PASS  "$(decide "$(j_bash_cwd "$QL_HERE/scripts" "$QL_REL")")"
assert "rel script, payload cwd = own checkout"        ALLOW "$(decide "$(j_bash_cwd "$QL_HERE" "$QL_REL")")"
assert "rel script, payload cwd = primary checkout"    ALLOW "$(decide "$(j_bash_cwd "$QL_PRIMARY" "$QL_REL")")"
assert "ctl: rel script, no payload cwd, PWD = lookalike"  PASS  "$(decide_in "$QL_FAKE" "$(j_bash "$QL_REL")")"
assert "rel script, no payload cwd, PWD = own checkout"    ALLOW "$(decide_in "$QL_HERE" "$(j_bash "$QL_REL")")"
assert "rel script, no payload cwd, PWD = primary"         ALLOW "$(decide_in "$QL_PRIMARY" "$(j_bash "$QL_REL")")"
assert "ctl: payload cwd (lookalike) beats PWD (real)" PASS  "$(decide_in "$QL_HERE" "$(j_bash_cwd "$QL_FAKE" "$QL_REL")")"
assert "payload cwd (real) beats PWD (lookalike)"      ALLOW "$(decide_in "$QL_FAKE" "$(j_bash_cwd "$QL_HERE" "$QL_REL")")"
rm -rf "$QL_FAKE"
assert "queue-lock release (no HANDOVER_DIR)"   ALLOW "$(decide "$(j_bash "bash scripts/handover/queue-lock.sh release $QL_DOC $QL_TOK")")"
assert "queue-lock acquire"                     ALLOW "$(decide "$(j_bash "HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh acquire $QL_DOC")")"
assert "queue-lock heartbeat"                   ALLOW "$(decide "$(j_bash "HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh heartbeat $QL_DOC $QL_TOK")")"
assert "queue-lock status"                      ALLOW "$(decide "$(j_bash "HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh status $QL_DOC")")"
assert "queue-lock status --sweep"              ALLOW "$(decide "$(j_bash "HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh status --sweep $QL_R")")"
# CONTROLS — none of these may be approved. Compound: the carve-out is the whole
# command only; a queue-lock segment after &&/;/| (or a pipe INTO it) falls through.
assert "ctl: git log && queue-lock release"     PASS "$(decide "$(j_bash "git log --oneline -1 && HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh release $QL_DOC $QL_TOK")")"
assert "ctl: queue-lock release && git log"     PASS "$(decide "$(j_bash "HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh release $QL_DOC $QL_TOK && git log")")"
assert "ctl: echo ; queue-lock release"         PASS "$(decide "$(j_bash "echo x; HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh release $QL_DOC $QL_TOK")")"
assert "ctl: pipe INTO queue-lock"              PASS "$(decide "$(j_bash "cat $QL_DOC | HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh release $QL_DOC $QL_TOK")")"
assert "ctl: queue-lock | tail"                 PASS "$(decide "$(j_bash "HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh status $QL_DOC | tail -1")")"
assert "ctl: queue-lock > file"                 PASS "$(decide "$(j_bash "HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh status $QL_DOC > /tmp/out")")"
assert "ctl: force-release env prefix"          PASS "$(decide "$(j_bash "QUEUE_LOCK_FORCE_RELEASE=1 bash scripts/handover/queue-lock.sh release $QL_DOC")")"
assert "ctl: second assignment"                 PASS "$(decide "$(j_bash "HANDOVER_DIR=$QL_R QUEUE_LOCK_FORCE_RELEASE=1 bash scripts/handover/queue-lock.sh release $QL_DOC")")"
assert "ctl: other script name"                 PASS "$(decide "$(j_bash "HANDOVER_DIR=$QL_R bash scripts/handover/other.sh release $QL_DOC $QL_TOK")")"
assert "ctl: bash flag before script"           PASS "$(decide "$(j_bash "HANDOVER_DIR=$QL_R bash -x scripts/handover/queue-lock.sh release $QL_DOC $QL_TOK")")"
assert "ctl: unknown verb"                      PASS "$(decide "$(j_bash "HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh force-release $QL_DOC")")"
assert "ctl: doc outside HANDOVER_DIR"          PASS "$(decide "$(j_bash "HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh release /etc/passwd.md $QL_TOK")")"
assert "ctl: dot-dot doc"                       PASS "$(decide "$(j_bash "HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh release $QL_R/../x.md $QL_TOK")")"
assert "ctl: variable doc"                      PASS "$(decide "$(j_bash "HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh release \$DOC $QL_TOK")")"
assert "ctl: variable HANDOVER_DIR"             PASS "$(decide "$(j_bash "HANDOVER_DIR=\$X bash scripts/handover/queue-lock.sh release $QL_DOC $QL_TOK")")"
assert "ctl: extra trailing arg"                PASS "$(decide "$(j_bash "HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh release $QL_DOC $QL_TOK extra")")"
assert "ctl: relative doc"                      PASS "$(decide "$(j_bash "bash scripts/handover/queue-lock.sh release yotamleo/x.md $QL_TOK")")"
assert "ctl: non-.md doc"                       PASS "$(decide "$(j_bash "HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh release $QL_R/x.txt $QL_TOK")")"
assert "ctl: other bash script"                 PASS "$(decide "$(j_bash "bash scripts/handover/merge-on-green.sh 1 --jira-transition")")"
# Whole-command means NO unquoted separator anywhere — not merely one non-empty
# segment. scan_cmd emits an EMPTY segment after a trailing separator and the
# segment count skips it, so these once counted as a lone command (CodeRabbit,
# round 2): a trailing `&` even backgrounds the lock op. The lone command above
# still approves; each of these is a control that must fall through.
QL_LONE="HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh status $QL_DOC"
assert "ctl: trailing &"                        PASS "$(decide "$(j_bash "$QL_LONE &")")"
assert "ctl: trailing ;"                        PASS "$(decide "$(j_bash "$QL_LONE;")")"
assert "ctl: trailing && (empty tail)"          PASS "$(decide "$(j_bash "$QL_LONE &&")")"
assert "ctl: trailing || (empty tail)"          PASS "$(decide "$(j_bash "$QL_LONE ||")")"
assert "ctl: trailing |  (empty tail)"          PASS "$(decide "$(j_bash "$QL_LONE |")")"
# A bare trailing newline never reaches the scanner (the hook's `$(jq …)` capture
# strips it), and `cmd\n` is the identical single command to the shell, so it
# approves; a newline that leaves ANYTHING behind it is a real separator.
assert "lone command + bare trailing newline"   ALLOW "$(decide "$(j_bash "$QL_LONE"$'\n')")"
assert "ctl: newline + whitespace tail"         PASS "$(decide "$(j_bash "$QL_LONE"$'\n  ')")"
assert "ctl: newline + second command"          PASS "$(decide "$(j_bash "$QL_LONE"$'\necho x')")"
assert "ctl: leading newline + command"         PASS "$(decide "$(j_bash $'\n'"$QL_LONE")")"
assert "ctl: trailing ;;"                       PASS "$(decide "$(j_bash "$QL_LONE ;;")")"
assert "ctl: leading ;"                         PASS "$(decide "$(j_bash "; $QL_LONE")")"
assert "ctl: leading &&"                        PASS "$(decide "$(j_bash "&& $QL_LONE")")"
assert "ctl: release trailing &"                PASS "$(decide "$(j_bash "HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh release $QL_DOC $QL_TOK &")")"
assert "the lone command still approves"        ALLOW "$(decide "$(j_bash "$QL_LONE")")"

# --- HIMMEL-3192: Windows Git Bash drive-letter spellings (C:/x, C:\x, /c/x) ---
# The carve-out took only `/`-prefixed paths, so on Git Bash a `C:/…` word fell
# through to the classifier (toward a prompt, never toward approval). ONE helper
# (ql_abs_path) now accepts slash-prefixed and drive-letter paths at all four
# positions: the HANDOVER_DIR value, the absolute script path, the status --sweep
# dir and the doc. Both sides of every containment comparison are normalised to
# the same `/<drive>/…` spelling (drive letter case-folded), so `C:/x` and `/c/x`
# are equal and a drive-letter spelling cannot dodge containment. This is Linux:
# the cases SIMULATE the spelling, they do not run Git Bash.
QD_R='C:/luna/handovers'
QD_DOC="$QD_R/yotamleo/himmel/HIMMEL-1-legN1-2026-09-18.md"
qd() { decide "$(j_bash_cwd "$QL_HERE" "$1")"; }   # relative script, cwd = own checkout
QD_S="bash scripts/handover/queue-lock.sh"
# Position 1 + 4 (HANDOVER_DIR value and doc), and both mixed spellings of one path
assert "drive: HANDOVER_DIR + doc, release"         ALLOW "$(qd "HANDOVER_DIR=$QD_R $QD_S release $QD_DOC $QL_TOK")"
assert "drive: HANDOVER_DIR C:/ + doc /c/"          ALLOW "$(qd "HANDOVER_DIR=$QD_R $QD_S release /c/luna/handovers/y/x.md $QL_TOK")"
assert "drive: HANDOVER_DIR /c/ + doc C:/"          ALLOW "$(qd "HANDOVER_DIR=/c/luna/handovers $QD_S release $QD_DOC $QL_TOK")"
assert "drive: lower-case drive vs upper-case doc"  ALLOW "$(qd "HANDOVER_DIR=c:/luna/handovers $QD_S release $QD_DOC $QL_TOK")"
assert "drive: upper-case HANDOVER_DIR, lower doc"  ALLOW "$(qd "HANDOVER_DIR=C:/luna/handovers $QD_S acquire c:/luna/handovers/y/x.md")"
assert "drive: HANDOVER_DIR with a trailing slash"  ALLOW "$(qd "HANDOVER_DIR=$QD_R/ $QD_S status $QD_DOC")"
assert "drive: single-quoted backslash spelling"    ALLOW "$(qd "HANDOVER_DIR='C:\\luna\\handovers' $QD_S heartbeat 'C:\\luna\\handovers\\y\\x.md' $QL_TOK")"
# Position 4 alone (no HANDOVER_DIR)
assert "drive: doc alone, acquire"                  ALLOW "$(qd "$QD_S acquire C:/luna/handovers/y/x.md")"
# Position 3 (status --sweep <dir>)
assert "drive: sweep dir"                           ALLOW "$(qd "$QD_S status --sweep $QD_R")"
assert "drive: sweep dir, HANDOVER_DIR"             ALLOW "$(qd "HANDOVER_DIR=$QD_R $QD_S status --sweep $QD_R")"
assert "drive: sweep dir, backslash"                ALLOW "$(qd "$QD_S status --sweep 'C:\\luna\\handovers'")"
# Position 2 (absolute script path). The script root is resolved with `cd`, so on
# Linux a `C:/…` word is simulated by a `C:` symlink in the hook's cwd that points
# at a real checkout (own = ALLOW) or at a lookalike (must fall through).
QD_DRV="$(mktemp -d "${TMPDIR:-/tmp}/qd-drv.XXXXXX")"
QD_FAKE="$(mktemp -d "${TMPDIR:-/tmp}/qd-fake.XXXXXX")"; mkdir -p "$QD_FAKE/scripts/handover" "$QD_FAKE/.git"; : > "$QD_FAKE/scripts/handover/queue-lock.sh"
ln -s "$QL_HERE" "$QD_DRV/C:" 2>/dev/null; ln -s "$QL_HERE" "$QD_DRV/c:" 2>/dev/null; ln -s "$QD_FAKE" "$QD_DRV/D:" 2>/dev/null
if [ -f "$QD_DRV/C:/scripts/handover/queue-lock.sh" ] && [ -f "$QD_DRV/c:/scripts/handover/queue-lock.sh" ] && [ -f "$QD_DRV/D:/scripts/handover/queue-lock.sh" ]; then
    qdd() { decide_in "$QD_DRV" "$(j_bash "$1")"; }   # no payload cwd → cwd = the symlink dir
    assert "drive: abs script C:/, own checkout"        ALLOW "$(qdd "HANDOVER_DIR=$QD_R bash C:/scripts/handover/queue-lock.sh release $QD_DOC $QL_TOK")"
    assert "drive: abs script c:/ (lower-case letter)"  ALLOW "$(qdd "HANDOVER_DIR=$QD_R bash c:/scripts/handover/queue-lock.sh release $QD_DOC $QL_TOK")"
    assert "drive: abs script, backslash spelling"      ALLOW "$(qdd "HANDOVER_DIR=$QD_R bash 'C:\\scripts\\handover\\queue-lock.sh' release $QD_DOC $QL_TOK")"
    assert "drive: abs script + doc + sweep together"   ALLOW "$(qdd "bash C:/scripts/handover/queue-lock.sh status --sweep $QD_R")"
    assert "ctl: drive abs script, lookalike checkout (exists + .git)" PASS "$(qdd "HANDOVER_DIR=$QD_R bash D:/scripts/handover/queue-lock.sh release $QD_DOC $QL_TOK")"
    assert "ctl: drive abs script, drive not present"   PASS "$(qdd "HANDOVER_DIR=$QD_R bash E:/scripts/handover/queue-lock.sh release $QD_DOC $QL_TOK")"
else
    echo "SKIP drive: abs script rows (cannot create C:/c:/D: symlinks here)"
fi
rm -rf "$QD_DRV" "$QD_FAKE"
assert "ctl: drive abs script, lookalike (absent)"  PASS "$(qd "HANDOVER_DIR=$QD_R bash C:/tmp/x-himmel-3192-absent/scripts/handover/queue-lock.sh release $QD_DOC $QL_TOK")"
assert "ctl: drive abs script, dot-dot root"        PASS "$(qd "HANDOVER_DIR=$QD_R bash C:/x/../scripts/handover/queue-lock.sh release $QD_DOC $QL_TOK")"
# CONTROLS — a drive-letter spelling must never dodge containment or a lexical guard
assert "ctl: drive doc, other drive"                PASS "$(qd "HANDOVER_DIR=$QD_R $QD_S release D:/luna/handovers/y/x.md $QL_TOK")"
assert "ctl: drive doc outside HANDOVER_DIR"        PASS "$(qd "HANDOVER_DIR=$QD_R $QD_S release C:/other/x.md $QL_TOK")"
assert "ctl: mixed spelling escape (C:/a vs /c/b)"  PASS "$(qd "HANDOVER_DIR=C:/a $QD_S release /c/b/x.md $QL_TOK")"
assert "ctl: mixed spelling escape (/c/a vs C:/b)"  PASS "$(qd "HANDOVER_DIR=/c/a $QD_S release C:/b/x.md $QL_TOK")"
assert "ctl: sibling with the root as a name prefix" PASS "$(qd "HANDOVER_DIR=$QD_R $QD_S release C:/luna/handovers-evil/x.md $QL_TOK")"
assert "ctl: drive doc, dot-dot"                    PASS "$(qd "HANDOVER_DIR=$QD_R $QD_S release C:/luna/handovers/../x.md $QL_TOK")"
assert "ctl: drive doc, dot-dot backslash"          PASS "$(qd "HANDOVER_DIR=$QD_R $QD_S release 'C:\\luna\\handovers\\..\\x.md' $QL_TOK")"
assert "ctl: drive HANDOVER_DIR, dot-dot"           PASS "$(qd "HANDOVER_DIR=C:/luna/../x $QD_S release C:/luna/../x/y.md $QL_TOK")"
assert "ctl: drive sweep dir, dot-dot"              PASS "$(qd "$QD_S status --sweep C:/luna/..")"
assert "ctl: drive doc, not .md"                    PASS "$(qd "HANDOVER_DIR=$QD_R $QD_S release C:/luna/handovers/x.txt $QL_TOK")"
assert "ctl: drive-relative doc (C:x)"              PASS "$(qd "$QD_S acquire C:luna/x.md")"
assert "ctl: unquoted backslash doc (bash eats \\)" PASS "$(qd "$QD_S acquire C:\\luna\\x.md")"
assert "ctl: variable in a drive path"              PASS "$(qd "$QD_S acquire C:/\$X/x.md")"
assert "ctl: drive doc, unknown verb"               PASS "$(qd "HANDOVER_DIR=$QD_R $QD_S force-release $QD_DOC")"
assert "ctl: drive doc, extra arg"                  PASS "$(qd "HANDOVER_DIR=$QD_R $QD_S release $QD_DOC $QL_TOK extra")"
assert "ctl: drive trailing &"                      PASS "$(qd "HANDOVER_DIR=$QD_R $QD_S status $QD_DOC &")"
assert "ctl: drive trailing ;"                      PASS "$(qd "HANDOVER_DIR=$QD_R $QD_S status $QD_DOC;")"
assert "ctl: drive doc, compound"                   PASS "$(qd "git log -1 && HANDOVER_DIR=$QD_R $QD_S status $QD_DOC")"
assert "ctl: POSIX doc with a backslash"            PASS "$(qd "HANDOVER_DIR=$QL_R $QD_S status '$QL_R/y/a\\..\\b.md'")"
# A slash-form UNC path (`//host/share`) is a remote share under Git Bash — no position accepts it
assert "ctl: UNC doc under a UNC HANDOVER_DIR"      PASS "$(qd "HANDOVER_DIR=//host/share/h $QD_S release //host/share/h/x.md $QL_TOK")"
assert "ctl: UNC doc alone"                         PASS "$(qd "$QD_S acquire //host/share/x.md")"
assert "ctl: UNC HANDOVER_DIR, POSIX doc"           PASS "$(qd "HANDOVER_DIR=//host/share $QD_S status /host/share/x.md")"
assert "ctl: UNC sweep dir"                         PASS "$(qd "$QD_S status --sweep //host/share/h")"
assert "ctl: UNC abs script path"                   PASS "$(qd "HANDOVER_DIR=$QL_R bash //host/share/scripts/handover/queue-lock.sh release $QL_DOC $QL_TOK")"
assert "the POSIX lone command still approves"      ALLOW "$(qd "HANDOVER_DIR=$QL_R $QD_S status $QL_DOC")"

# --- HIMMEL-3198: a root-only HANDOVER_DIR must not turn containment off ---
# `HANDOVER_DIR=/` strips to an empty `hd`, which the containment test reads as
# "no handover dir given" — so ANY absolute .md doc was approved. A bare drive
# root (`C:/`, canonical `/c`) contains a whole drive and is the same hole. The
# hook now refuses (falls through to the classifier) when the HANDOVER_DIR value
# is `/` or `/<letter>` in any spelling. Each ctl: row below was ALLOW before.
assert "ctl: HANDOVER_DIR=/ + any doc"              PASS "$(qd "HANDOVER_DIR=/ $QD_S status /etc/x.md")"
assert "ctl: HANDOVER_DIR=/ + doc, release"         PASS "$(qd "HANDOVER_DIR=/ $QD_S release /etc/x.md $QL_TOK")"
assert "ctl: HANDOVER_DIR=/ + sweep"                PASS "$(qd "HANDOVER_DIR=/ $QD_S status --sweep $QL_R")"
assert "ctl: HANDOVER_DIR=C:/ + drive doc"          PASS "$(qd "HANDOVER_DIR=C:/ $QD_S status C:/x.md")"
assert "ctl: HANDOVER_DIR=C:/ + any drive-C doc"    PASS "$(qd "HANDOVER_DIR=C:/ $QD_S status C:/Windows/x.md")"
assert "ctl: HANDOVER_DIR=/c + doc"                 PASS "$(qd "HANDOVER_DIR=/c $QD_S status /c/x.md")"
assert "ctl: HANDOVER_DIR=/c/ + doc"                PASS "$(qd "HANDOVER_DIR=/c/ $QD_S status /c/x.md")"
assert "ctl: HANDOVER_DIR=c:/ (lower) + doc"        PASS "$(qd "HANDOVER_DIR=c:/ $QD_S status /c/x.md")"
assert "ctl: HANDOVER_DIR='C:\\' (quoted) + doc"     PASS "$(qd "HANDOVER_DIR='C:\\' $QD_S status 'C:\\x.md'")"
assert "ctl: HANDOVER_DIR=/c// (repeated slash)"    PASS "$(qd "HANDOVER_DIR=/c// $QD_S status /c//x.md")"
assert "ctl: HANDOVER_DIR=// (slash-form UNC root)" PASS "$(qd "HANDOVER_DIR=// $QD_S status //x.md")"
assert "ctl: HANDOVER_DIR=// + POSIX doc"           PASS "$(qd "HANDOVER_DIR=// $QD_S status /etc/x.md")"
assert "ctl: HANDOVER_DIR=/// + doc"                PASS "$(qd "HANDOVER_DIR=/// $QD_S status /etc/x.md")"
# A `.` component spells the same root (`/.` is `/`, `/c/.` is `/c`).
assert "ctl: HANDOVER_DIR=/. + any doc"             PASS "$(qd "HANDOVER_DIR=/. $QD_S status /etc/x.md")"
assert "ctl: HANDOVER_DIR=/./ + any doc"            PASS "$(qd "HANDOVER_DIR=/./ $QD_S status /./etc/x.md")"
assert "ctl: HANDOVER_DIR=/c/. + drive doc"         PASS "$(qd "HANDOVER_DIR=/c/. $QD_S status /c/./x.md")"
assert "ctl: HANDOVER_DIR=C:/. + drive doc"         PASS "$(qd "HANDOVER_DIR=C:/. $QD_S status C:/./x.md")"
# An INTERIOR `.` spells a root too (`/./c` is `/c`), so `*/./*` must stay refused;
# the price is that `/tmp/./handovers` falls through (a prompt, never a wrong approve).
assert "ctl: HANDOVER_DIR=/./c + drive doc"         PASS "$(qd "HANDOVER_DIR=/./c $QD_S status /./c/x.md")"
assert "ctl: HANDOVER_DIR=/tmp/./h + contained doc" PASS "$(qd "HANDOVER_DIR=/tmp/./h $QD_S status /tmp/./h/x.md")"
# `/a` is indistinguishable from the drive root `A:/` (any single letter), so it
# is refused too (the ticket's own control: `/a` + a foreign doc falls through).
assert "ctl: HANDOVER_DIR=/a + doc outside it"      PASS  "$(qd "HANDOVER_DIR=/a $QD_S status /tmp/anywhere-else/x.md")"
assert "ctl: HANDOVER_DIR=/a + contained doc"       PASS  "$(qd "HANDOVER_DIR=/a $QD_S status /a/x.md")"
# Not a drive root: a two-letter dir (`/cc`), a subdirectory of a one-letter dir
# or of a drive — all still contain-checked and still approved.
assert "HANDOVER_DIR=/cc + contained doc"           ALLOW "$(qd "HANDOVER_DIR=/cc $QD_S status /cc/x.md")"
assert "HANDOVER_DIR=/a/b + contained doc"          ALLOW "$(qd "HANDOVER_DIR=/a/b $QD_S status /a/b/x.md")"
assert "HANDOVER_DIR=C:/a + contained doc"          ALLOW "$(qd "HANDOVER_DIR=C:/a $QD_S status /c/a/x.md")"
assert "ctl: HANDOVER_DIR=/a/b + doc outside it"    PASS  "$(qd "HANDOVER_DIR=/a/b $QD_S status /a/x.md")"

# --- HIMMEL-3486: /pr-check step 3.6's impacted-suites.sh literals ---
# The step is a required gate, yet `bash scripts/cr/impacted-suites.sh A..B`
# fell to the classifier and was denied [Out-of-Place Publication]. The hook
# approves exactly the two runbook shapes (the listing, and `--check` with its
# quoted heredoc), and only when the file that runs is byte-equal to the
# HIMMEL_REPO anchor's refs/heads/main blob. A throwaway anchor repo stands in
# for HIMMEL_REPO, so no case depends on the real primary's state.
IS_TMP="$(mktemp -d "${TMPDIR:-/tmp}/is-anchor.XXXXXX")" || { echo "FAIL mktemp for the impacted-suites anchor fixture"; exit 1; }
IS_A="$IS_TMP/anchor"; IS_W="$IS_TMP/wt"
isg() { env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.name=t -c user.email=t@t "$@" >/dev/null 2>&1; }
mkdir -p "$IS_A/scripts/cr"
printf 'echo impacted\n' > "$IS_A/scripts/cr/impacted-suites.sh"
printf 'echo other\n' > "$IS_A/scripts/cr/other.sh"
isg init -q -b main "$IS_A"; isg -C "$IS_A" add -A; isg -C "$IS_A" commit -qm base
isg -C "$IS_A" worktree add -q -b feat "$IS_W"
mkdir -p "$IS_W/sub"
is_dec() { # is_dec <cwd> <command> — decide with HIMMEL_REPO = the throwaway anchor
    local out
    out=$(j_bash_cwd "$1" "$2" | HIMMEL_REPO="$IS_A" bash "$HOOK" 2>/dev/null)
    if grepq "$out" '"permissionDecision":"allow"'; then echo ALLOW; else echo PASS; fi
}
IS_R="$(printf 'a%.0s' $(seq 40))..$(printf 'b%.0s' $(seq 40))"
IS_REL="bash scripts/cr/impacted-suites.sh"
IS_ABS="bash \"$IS_W/scripts/cr/impacted-suites.sh\""
IS_HD="<<'IMPACTED_EOF'"
IS_BODY=$'SUITE scripts/hooks/test-x.sh = PASS\nSUITE scripts/y.test.mjs = SKIP no node here; won'"'"'t $(run) `this`'
assert "precondition: impacted-suites anchor fixture built" ALLOW "$([ -f "$IS_W/scripts/cr/impacted-suites.sh" ] && echo ALLOW || echo PASS)"
assert "impacted-suites listing (rel, worktree root)"   ALLOW "$(is_dec "$IS_W" "$IS_REL $IS_R")"
assert "impacted-suites listing (rel, anchor root)"     ALLOW "$(is_dec "$IS_A" "$IS_REL $IS_R")"
assert "impacted-suites listing (abs, quoted)"          ALLOW "$(is_dec "$IS_TMP" "$IS_ABS $IS_R")"
assert "impacted-suites listing (abs, unquoted)"        ALLOW "$(is_dec "$IS_TMP" "bash $IS_A/scripts/cr/impacted-suites.sh $IS_R")"
assert "impacted-suites --check, no heredoc"            ALLOW "$(is_dec "$IS_W" "$IS_REL --check $IS_R")"
assert "impacted-suites --check heredoc (rel)"          ALLOW "$(is_dec "$IS_W" "$IS_REL --check $IS_R $IS_HD"$'\n'"$IS_BODY"$'\nIMPACTED_EOF')"
assert "impacted-suites --check heredoc (abs, trailing NL)" ALLOW "$(is_dec "$IS_W" "$IS_ABS --check $IS_R $IS_HD"$'\n'"$IS_BODY"$'\nIMPACTED_EOF\n')"
assert "impacted-suites --check heredoc, no verdicts"   ALLOW "$(is_dec "$IS_W" "$IS_REL --check $IS_R $IS_HD"$'\nIMPACTED_EOF')"
# CONTROLS — grammar.
assert "ctl: is extra trailing arg"          PASS "$(is_dec "$IS_W" "$IS_REL $IS_R --shell")"
assert "ctl: is --check after the range"     PASS "$(is_dec "$IS_W" "$IS_REL $IS_R --check")"
assert "ctl: is --runner form"               PASS "$(is_dec "$IS_W" "$IS_REL --runner scripts/x.test.mjs")"
assert "ctl: is ; rm"                        PASS "$(is_dec "$IS_W" "$IS_REL $IS_R; rm -rf x")"
assert "ctl: is && touch"                    PASS "$(is_dec "$IS_W" "$IS_REL $IS_R && touch x")"
assert "ctl: is | tee"                       PASS "$(is_dec "$IS_W" "$IS_REL $IS_R | tee x")"
assert "ctl: is > file"                      PASS "$(is_dec "$IS_W" "$IS_REL $IS_R > x")"
assert "ctl: is \$( in range"                PASS "$(is_dec "$IS_W" "$IS_REL \$(git rev-parse HEAD)..$(printf 'b%.0s' $(seq 40))")"
assert "ctl: is \$( in path"                 PASS "$(is_dec "$IS_W" "bash \"\$(pwd)/scripts/cr/impacted-suites.sh\" $IS_R")"
assert "ctl: is short sha"                   PASS "$(is_dec "$IS_W" "$IS_REL abcdef1..$(printf 'b%.0s' $(seq 40))")"
assert "ctl: is three-dot range"             PASS "$(is_dec "$IS_W" "$IS_REL ${IS_R/../...}")"
assert "ctl: is upper-case hex"              PASS "$(is_dec "$IS_W" "$IS_REL $(printf 'A%.0s' $(seq 40))..$(printf 'b%.0s' $(seq 40))")"
assert "ctl: is ref name range"              PASS "$(is_dec "$IS_W" "$IS_REL origin/main..HEAD")"
assert "ctl: is env prefix"                  PASS "$(is_dec "$IS_W" "BASH_ENV=x $IS_REL $IS_R")"
assert "ctl: is bash flag"                   PASS "$(is_dec "$IS_W" "bash -x scripts/cr/impacted-suites.sh $IS_R")"
assert "ctl: is other scripts/cr script"     PASS "$(is_dec "$IS_W" "bash scripts/cr/other.sh $IS_R")"
assert "ctl: is script outside scripts/cr"   PASS "$(is_dec "$IS_W" "bash scripts/impacted-suites.sh $IS_R")"
assert "ctl: is ./ spelling"                 PASS "$(is_dec "$IS_W" "bash ./scripts/cr/impacted-suites.sh $IS_R")"
assert "ctl: is dot-dot abs path"            PASS "$(is_dec "$IS_W" "bash $IS_W/sub/../scripts/cr/impacted-suites.sh $IS_R")"
assert "ctl: is heredoc without --check"     PASS "$(is_dec "$IS_W" "$IS_REL $IS_R $IS_HD"$'\n'"$IS_BODY"$'\nIMPACTED_EOF')"
assert "ctl: is unquoted heredoc delimiter"  PASS "$(is_dec "$IS_W" "$IS_REL --check $IS_R <<IMPACTED_EOF"$'\n'"$IS_BODY"$'\nIMPACTED_EOF')"
assert "ctl: is <<- heredoc"                 PASS "$(is_dec "$IS_W" "$IS_REL --check $IS_R <<-'IMPACTED_EOF'"$'\n'"$IS_BODY"$'\nIMPACTED_EOF')"
assert "ctl: is command after the heredoc"   PASS "$(is_dec "$IS_W" "$IS_REL --check $IS_R $IS_HD"$'\n'"$IS_BODY"$'\nIMPACTED_EOF\nrm -rf x')"
assert "ctl: is early delimiter then command" PASS "$(is_dec "$IS_W" "$IS_REL --check $IS_R $IS_HD"$'\nIMPACTED_EOF\nrm -rf x\nIMPACTED_EOF')"
assert "ctl: is doubled delimiter, no body"  PASS "$(is_dec "$IS_W" "$IS_REL --check $IS_R $IS_HD"$'\nIMPACTED_EOF\nIMPACTED_EOF')"
assert "ctl: is doubled delimiter after body" PASS "$(is_dec "$IS_W" "$IS_REL --check $IS_R $IS_HD"$'\n'"$IS_BODY"$'\nIMPACTED_EOF\nIMPACTED_EOF')"
assert "ctl: is non-SUITE body line"         PASS "$(is_dec "$IS_W" "$IS_REL --check $IS_R $IS_HD"$'\nrm -rf x\nIMPACTED_EOF')"
assert "ctl: is unterminated heredoc"        PASS "$(is_dec "$IS_W" "$IS_REL --check $IS_R $IS_HD"$'\n'"$IS_BODY")"
assert "ctl: is two commands on two lines"   PASS "$(is_dec "$IS_W" "$IS_REL $IS_R"$'\n'"rm -rf x")"
# CONTROLS — where it runs, and the bytes it runs.
assert "ctl: is rel from a sub-dir"          PASS "$(is_dec "$IS_W/sub" "$IS_REL $IS_R")"
assert "ctl: is rel from a non-checkout"     PASS "$(is_dec "$IS_TMP" "$IS_REL $IS_R")"
IS_FAKE="$IS_TMP/fake"; mkdir -p "$IS_FAKE/scripts/cr"; cp "$IS_A/scripts/cr/impacted-suites.sh" "$IS_FAKE/scripts/cr/"; isg init -q -b main "$IS_FAKE"
assert "ctl: is same bytes, foreign repo"    PASS "$(is_dec "$IS_FAKE" "$IS_REL $IS_R")"
printf 'echo edited\n' > "$IS_W/scripts/cr/impacted-suites.sh"
assert "ctl: is worktree copy differs (rel)" PASS "$(is_dec "$IS_W" "$IS_REL $IS_R")"
assert "ctl: is worktree copy differs (abs)" PASS "$(is_dec "$IS_TMP" "$IS_ABS $IS_R")"
assert "ctl: is worktree copy differs (--check)" PASS "$(is_dec "$IS_W" "$IS_REL --check $IS_R $IS_HD"$'\n'"$IS_BODY"$'\nIMPACTED_EOF')"
cp "$IS_A/scripts/cr/impacted-suites.sh" "$IS_W/scripts/cr/impacted-suites.sh"
assert "impacted-suites listing, copy restored"     ALLOW "$(is_dec "$IS_W" "$IS_REL $IS_R")"
rm "$IS_W/scripts/cr/impacted-suites.sh"; ln -s "$IS_A/scripts/cr/impacted-suites.sh" "$IS_W/scripts/cr/impacted-suites.sh"
assert "ctl: is worktree copy is a symlink"  PASS "$(is_dec "$IS_W" "$IS_REL $IS_R")"
rm "$IS_W/scripts/cr/impacted-suites.sh"; cp "$IS_A/scripts/cr/impacted-suites.sh" "$IS_W/scripts/cr/impacted-suites.sh"
printf 'echo drift\n' > "$IS_A/scripts/cr/impacted-suites.sh"
assert "ctl: is anchor tree off main's blob" PASS "$(is_dec "$IS_A" "$IS_REL $IS_R")"
isg -C "$IS_A" checkout -q -- scripts/cr/impacted-suites.sh
isg -C "$IS_A" checkout -q --detach
assert "ctl: is anchor HEAD detached"        PASS "$(is_dec "$IS_W" "$IS_REL $IS_R")"
isg -C "$IS_A" checkout -q main
IS_OUT=$(j_bash_cwd "$IS_W" "$IS_REL $IS_R" | env -u HIMMEL_REPO bash "$HOOK" 2>/dev/null)
assert "ctl: is HIMMEL_REPO unset"           PASS "$(grepq "$IS_OUT" '"permissionDecision":"allow"' && echo ALLOW || echo PASS)"
assert "impacted-suites listing, anchor back on main" ALLOW "$(is_dec "$IS_W" "$IS_REL $IS_R")"
# CONTROLS — console review of PR 1143. On POSIX a drive-letter or backslash
# word is checked as one path (`\`→`/`, resolved from the hook's cwd) but run
# as another (a cwd-relative file bash finds by its literal name), so neither
# spelling is in this grammar; and the root comes only from an absolute
# payload cwd, never the hook's own $PWD. A `C:` symlink in the hook's cwd,
# pointing at the real worktree, is what made those spellings pass the check.
is_dec_in() { # is_dec_in <hook-cwd> <payload-json>
    local out
    out=$(cd "$1" && printf '%s' "$2" | HIMMEL_REPO="$IS_A" bash "$HOOK" 2>/dev/null)
    if grepq "$out" '"permissionDecision":"allow"'; then echo ALLOW; else echo PASS; fi
}
IS_DRV="$IS_TMP/drv"; mkdir -p "$IS_DRV"
if ln -s "$IS_W" "$IS_DRV/C:" 2>/dev/null; then
    assert "ctl: is drive C:/ path"              PASS "$(is_dec_in "$IS_DRV" "$(j_bash_cwd "$IS_DRV" "bash C:/scripts/cr/impacted-suites.sh $IS_R")")"
    assert "ctl: is drive quoted backslash path" PASS "$(is_dec_in "$IS_DRV" "$(j_bash_cwd "$IS_DRV" "bash \"C:\\scripts\\cr\\impacted-suites.sh\" $IS_R")")"
    assert "ctl: is drive unquoted backslash"    PASS "$(is_dec_in "$IS_DRV" "$(j_bash_cwd "$IS_DRV" "bash C:\\\\scripts\\\\cr\\\\impacted-suites.sh $IS_R")")"
else
    echo "SKIP is drive rows (cannot create a C: symlink here)"
fi
assert "ctl: is rel, no payload cwd (hook PWD = worktree)" PASS "$(is_dec_in "$IS_W" "$(j_bash "$IS_REL $IS_R")")"
assert "ctl: is rel, relative payload cwd"   PASS "$(is_dec_in "$IS_TMP" "$(j_bash_cwd wt "$IS_REL $IS_R")")"
assert "ctl: is single-quoted path word"     PASS "$(is_dec "$IS_W" "bash 'scripts/cr/impacted-suites.sh' $IS_R")"
assert "ctl: is CRLF heredoc, no final CRLF" PASS "$(is_dec "$IS_W" "$IS_REL --check $IS_R $IS_HD"$'\r\nSUITE scripts/x.sh = PASS\r\nIMPACTED_EOF')"
assert "ctl: is CRLF heredoc"                PASS "$(is_dec "$IS_W" "$IS_REL --check $IS_R $IS_HD"$'\r\nSUITE scripts/x.sh = PASS\r\nIMPACTED_EOF\r\n')"
assert "ctl: is CRLF listing"                PASS "$(is_dec "$IS_W" "$IS_REL $IS_R"$'\r\n')"
assert "ctl: is lone CR in body"             PASS "$(is_dec "$IS_W" "$IS_REL --check $IS_R $IS_HD"$'\nSUITE x = PASS\rrm -rf x\nIMPACTED_EOF')"
assert "ctl: is tab on line 1"               PASS "$(is_dec "$IS_W" "bash"$'\t'"scripts/cr/impacted-suites.sh $IS_R")"
assert "ctl: is control char on line 1"      PASS "$(is_dec "$IS_W" "$IS_REL $IS_R"$'\x01')"
assert "ctl: is backtick in quoted word"     PASS "$(is_dec "$IS_W" "bash \"\`pwd\`/scripts/cr/impacted-suites.sh\" $IS_R")"
assert "ctl: is <( in quoted word"           PASS "$(is_dec "$IS_W" "bash \"<(x)/scripts/cr/impacted-suites.sh\" $IS_R")"
assert "ctl: is >( in quoted word"           PASS "$(is_dec "$IS_W" "bash \">(x)/scripts/cr/impacted-suites.sh\" $IS_R")"
assert "ctl: is glob in path"                PASS "$(is_dec "$IS_W" "bash scripts/cr/impacted-suite?.sh $IS_R")"
assert "ctl: is brace in path"               PASS "$(is_dec "$IS_W" "bash scripts/cr/{impacted-suites,other}.sh $IS_R")"
assert "ctl: is trailing &"                  PASS "$(is_dec "$IS_W" "$IS_REL $IS_R &")"
IS_OUT=$(j_bash_cwd "$IS_W" "$IS_REL $IS_R" | HIMMEL_REPO="$IS_W" bash "$HOOK" 2>/dev/null)
assert "ctl: is HIMMEL_REPO = own worktree"  PASS "$(grepq "$IS_OUT" '"permissionDecision":"allow"' && echo ALLOW || echo PASS)"
rm -rf "$IS_TMP"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "All cases passed."
    exit 0
else
    echo "$FAILED case(s) failed."
    exit 1
fi
