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
j_bash_cwd() { printf '{"tool_name":"Bash","cwd":%s,"tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)" "$(printf '%s' "$2" | jq -Rs .)"; }
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

# HIMMEL-3773/HIMMEL-3776 (judge J1387A): a jq-shim standing in for Windows
# jq.exe, which renders every LF of its `-r` output as CRLF. This is the
# same mechanism the judge used (own jq shim, not a real Windows box) to
# prove the hook's win-rendering detection and fold. WIN_JQ_SHIM_DIR wraps
# the real jq so every hook invocation under this PATH sees CRLF-rendered
# `jq -r` output, exactly like real Windows jq.exe.
WIN_JQ_SHIM_DIR="$(mktemp -d "${TMPDIR:-/tmp}/win-jq-shim.XXXXXX")" || exit 1
REAL_JQ="$(command -v jq)"
cat > "$WIN_JQ_SHIM_DIR/jq" <<EOF
#!/usr/bin/env bash
exec "$REAL_JQ" "\$@" | sed 's/\$/\r/'
EOF
chmod +x "$WIN_JQ_SHIM_DIR/jq"

# decide_win — same contract as decide(), but the hook sees CRLF-rendered
# jq -r output (Windows jq.exe), the case fold_backslash_newline()/scan_cmd()
# never exercise natively on this Linux test box.
decide_win() {
    local out
    out=$(printf '%s' "$1" | PATH="$WIN_JQ_SHIM_DIR:$PATH" bash "$HOOK" 2>/dev/null)
    if grepq "$out" '"permissionDecision":"deny"'; then
        echo "DENY"
    elif grepq "$out" '"permissionDecision":"allow"'; then
        echo "ALLOW"
    else
        echo "PASS"
    fi
}

# decide_posix — same contract as decide(), but the hook sees POSIX-bracket
# sed semantics (BSD/macOS sed), a proxy for a platform not available on this
# Linux test box: under POSIX brackets `\t`/`\n` in `[...]` mean the literal
# characters `\` and `t`/`n`, not TAB/LF (judge J1397A findings 2/3).
POSIX_SED_SHIM_DIR="$(mktemp -d "${TMPDIR:-/tmp}/posix-sed-shim.XXXXXX")" || exit 1
REAL_SED="$(command -v sed)"
# GNU sed needs --posix to get POSIX-bracket semantics; BSD/macOS sed rejects
# the flag (HIMMEL-3699) and already IS POSIX, so it is exec'd as-is there.
POSIX_SED_FLAG="--posix"
"$REAL_SED" --posix -n p </dev/null >/dev/null 2>&1 || POSIX_SED_FLAG=""
cat > "$POSIX_SED_SHIM_DIR/sed" <<EOF
#!/usr/bin/env bash
exec "$REAL_SED" $POSIX_SED_FLAG "\$@"
EOF
chmod +x "$POSIX_SED_SHIM_DIR/sed"
decide_posix() {
    local out
    out=$(printf '%s' "$1" | PATH="$POSIX_SED_SHIM_DIR:$PATH" bash "$HOOK" 2>/dev/null)
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
# HIMMEL-4780: a literal JIRA_PROJECT_KEY=<KEY> prefix on the jira CLI approves
# exactly like the bare form; the key only picks a project, which --project
# already may. Scoped to the jira CLI and to a bare literal key.
assert "JIRA_PROJECT_KEY jira comment" ALLOW "$(decide "$(j_bash 'JIRA_PROJECT_KEY=HIMMEL node /c/repo/scripts/jira/dist/index.js comment HIMMEL-1 --comment-file f.md')")"
assert "JIRA_PROJECT_KEY jira create"  ALLOW "$(decide "$(j_bash 'JIRA_PROJECT_KEY=HIMMEL node scripts/jira/dist/index.js create --type Task --title x --desc-file f.md')")"
assert "JIRA_PROJECT_KEY + LANG jira"  ALLOW "$(decide "$(j_bash 'LANG=C JIRA_PROJECT_KEY=LUNA node scripts/jira/dist/index.js get LUNA-1')")"
assert "JIRA_PROJECT_KEY on cat"       PASS  "$(decide "$(j_bash 'JIRA_PROJECT_KEY=HIMMEL cat f')")"
assert "JIRA_PROJECT_KEY on git"       PASS  "$(decide "$(j_bash 'JIRA_PROJECT_KEY=HIMMEL git log')")"
assert "JIRA_PROJECT_KEY other script" PASS  "$(decide "$(j_bash 'JIRA_PROJECT_KEY=HIMMEL node /tmp/evil.js')")"
assert "JIRA_PROJECT_KEY node -e"      PASS  "$(decide "$(j_bash 'JIRA_PROJECT_KEY=HIMMEL node -e code scripts/jira/dist/index.js')")"
assert "JIRA_PROJECT_KEY + NODE_OPTIONS" PASS "$(decide "$(j_bash 'JIRA_PROJECT_KEY=HIMMEL NODE_OPTIONS=--require=/tmp/x node scripts/jira/dist/index.js get X')")"
assert "JIRA_PROJECT_KEY var value"    PASS  "$(decide "$(j_bash 'JIRA_PROJECT_KEY=$K node scripts/jira/dist/index.js get X')")"
assert "JIRA_PROJECT_KEY empty value"  PASS  "$(decide "$(j_bash 'JIRA_PROJECT_KEY= node scripts/jira/dist/index.js get X')")"
assert "JIRA_PROJECT_KEY \$() value"   PASS  "$(decide "$(j_bash 'JIRA_PROJECT_KEY=$(cat k) node scripts/jira/dist/index.js get X')")"
assert "JIRA_PROJECT_KEY then rm"      PASS  "$(decide "$(j_bash 'JIRA_PROJECT_KEY=HIMMEL node scripts/jira/dist/index.js get X; rm -rf y')")"

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

# --- Round-6 locks: HIMMEL-2610 — abbreviated long-option write flags must
# be caught the same as the full spelling (GNU getopt_long-style unambiguous
# abbreviation; `sort`/`file` empirically confirmed to accept it). ---
assert "sort --outp abbrev write" PASS  "$(decide "$(j_bash 'sort --outp=/tmp/pwned f')")"
assert "tree --outp abbrev write" PASS  "$(decide "$(j_bash 'tree --outp=out.html .')")"
assert "base64 --outp abbrev"     PASS  "$(decide "$(j_bash 'base64 --outp=/tmp/x in')")"
assert "file --comp abbrev write" PASS  "$(decide "$(j_bash 'file --comp -m mymagic')")"
# negative controls: an unrelated long option on the same binary must not be
# swallowed by the abbreviation check (only a genuine prefix of the write
# flag's own name resolves).
assert "sort --buffer-size ctrl"  ALLOW "$(decide "$(j_bash 'sort --buffer-size=1M f')")"
assert "tree --dirsfirst ctrl"    ALLOW "$(decide "$(j_bash 'tree --dirsfirst .')")"
assert "file --mime-type ctrl"    ALLOW "$(decide "$(j_bash 'file --mime-type f')")"

# --- Round-7 locks: HIMMEL-3632 — sort's raw (quote-preserving) token
# defeated the `--*`/`-o*` case match, and `--compress-program` (runs an
# arbitrary program on spill = ACE) was never checked at all. FAIL CLOSED:
# an unrecognised or program/output-taking sort option must fall through to
# normal permission, never a per-shape patch that parses more. ---
assert "sort --compress-program"  PASS  "$(decide "$(j_bash 'sort --compress-program=sh f')")"
assert "sort --comp abbrev exec"  PASS  "$(decide "$(j_bash 'sort --comp=sh f')")"
assert "sort --output single-q"   PASS  "$(decide "$(j_bash "sort '--output=/tmp/pwned' f")")"
assert "sort --output double-q"   PASS  "$(decide "$(j_bash 'sort "--output=/tmp/pwned" f')")"
assert "sort -uo clustered write" PASS  "$(decide "$(j_bash 'sort -uo /tmp/pwned f')")"
# plain read-only sort forms (incl. clustered/unrelated short flags) still
# auto-approve.
assert "sort plain"               ALLOW "$(decide "$(j_bash 'sort f')")"
assert "sort -u plain"            ALLOW "$(decide "$(j_bash 'sort -u f')")"
assert "sort -k2 plain"           ALLOW "$(decide "$(j_bash 'sort -k2 f')")"

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
    if [ -n "${WIN_JQ_SHIM_DIR:-}" ] && [ -d "$WIN_JQ_SHIM_DIR" ]; then
        rm -rf "$WIN_JQ_SHIM_DIR" 2>/dev/null || true
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

# --- HIMMEL-2610 J1267O F2: the root-walk DENY (HIMMEL-2121) predates this
# hook's guardrails/lib.sh dependency and must survive lib.sh being missing —
# a fail-open here silently drops the ONLY thing this hook ever denies. ---
NOLIB_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/aasb-nolib.XXXXXX")" || { echo "FAIL mktemp for the no-lib fixture"; exit 1; }
mkdir -p "$NOLIB_ROOT/scripts/hooks"
cp "$HOOK" "$NOLIB_ROOT/scripts/hooks/auto-approve-safe-bash.sh"
decide_nolib() {
    local out
    out=$(printf '%s' "$1" | bash "$NOLIB_ROOT/scripts/hooks/auto-approve-safe-bash.sh" 2>/dev/null)
    if grepq "$out" '"permissionDecision":"deny"'; then
        echo "DENY"
    elif grepq "$out" '"permissionDecision":"allow"'; then
        echo "ALLOW"
    else
        echo "PASS"
    fi
}
assert "find / no maxdepth, NO lib.sh present" DENY "$(decide_nolib "$(j_bash 'find / -iname harvest-clips -not -path /node_modules/')")"
rm -rf "$NOLIB_ROOT"

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
# payload's absolute `cwd` (never $PWD, HIMMEL-3494) has to be a real
# checkout. j_bash_cwd puts a cwd field in the payload; decide_in runs the hook
# from a directory with no payload cwd (which now falls through).
QL_REL="HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh release $QL_DOC $QL_TOK"
assert "ctl: rel script, payload cwd = lookalike dir"  PASS  "$(decide "$(j_bash_cwd "$QL_FAKE" "$QL_REL")")"
assert "ctl: rel script, payload cwd = absent dir"     PASS  "$(decide "$(j_bash_cwd /tmp/x-himmel-3131-absent "$QL_REL")")"
assert "ctl: rel script, payload cwd = sub-dir"        PASS  "$(decide "$(j_bash_cwd "$QL_HERE/scripts" "$QL_REL")")"
assert "rel script, payload cwd = own checkout"        ALLOW "$(decide "$(j_bash_cwd "$QL_HERE" "$QL_REL")")"
assert "rel script, payload cwd = primary checkout"    ALLOW "$(decide "$(j_bash_cwd "$QL_PRIMARY" "$QL_REL")")"
assert "ctl: rel script, no payload cwd, PWD = lookalike"  PASS  "$(decide_in "$QL_FAKE" "$(j_bash "$QL_REL")")"
# HIMMEL-3494: the root resolves only against an ABSOLUTE payload cwd, never the
# hook's own $PWD — so no payload cwd, or a relative one, falls through.
assert "ctl: rel script, no payload cwd, PWD = own checkout" PASS "$(decide_in "$QL_HERE" "$(j_bash "$QL_REL")")"
assert "ctl: rel script, no payload cwd, PWD = primary"      PASS "$(decide_in "$QL_PRIMARY" "$(j_bash "$QL_REL")")"
assert "ctl: rel script, relative payload cwd (.)"           PASS "$(decide_in "$QL_HERE" "$(j_bash_cwd . "$QL_REL")")"
assert "ctl: rel script, relative payload cwd (name)"        PASS "$(decide_in "$(dirname "$QL_HERE")" "$(j_bash_cwd "$(basename "$QL_HERE")" "$QL_REL")")"
assert "ctl: payload cwd (lookalike) beats PWD (real)" PASS  "$(decide_in "$QL_HERE" "$(j_bash_cwd "$QL_FAKE" "$QL_REL")")"
assert "payload cwd (real) beats PWD (lookalike)"      ALLOW "$(decide_in "$QL_FAKE" "$(j_bash_cwd "$QL_HERE" "$QL_REL")")"
rm -rf "$QL_FAKE"
assert "queue-lock release (HANDOVER_DIR, rel script)" ALLOW "$(decide "$(j_bash_cwd "$QL_HERE" "HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh release $QL_DOC $QL_TOK")")"
assert "queue-lock release (no HANDOVER_DIR)"   ALLOW "$(decide "$(j_bash_cwd "$QL_HERE" "bash scripts/handover/queue-lock.sh release $QL_DOC $QL_TOK")")"
assert "queue-lock acquire"                     ALLOW "$(decide "$(j_bash_cwd "$QL_HERE" "HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh acquire $QL_DOC")")"
assert "queue-lock heartbeat"                   ALLOW "$(decide "$(j_bash_cwd "$QL_HERE" "HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh heartbeat $QL_DOC $QL_TOK")")"
assert "queue-lock status"                      ALLOW "$(decide "$(j_bash_cwd "$QL_HERE" "HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh status $QL_DOC")")"
assert "queue-lock status --sweep"              ALLOW "$(decide "$(j_bash_cwd "$QL_HERE" "HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh status --sweep $QL_R")")"
# CONTROLS — none of these may be approved. Compound: the carve-out is the whole
# command only; a queue-lock segment after &&/;/| (or a pipe INTO it) falls through.
assert "ctl: git log && queue-lock release"     PASS "$(decide "$(j_bash_cwd "$QL_HERE" "git log --oneline -1 && HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh release $QL_DOC $QL_TOK")")"
assert "ctl: queue-lock release && git log"     PASS "$(decide "$(j_bash_cwd "$QL_HERE" "HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh release $QL_DOC $QL_TOK && git log")")"
assert "ctl: echo ; queue-lock release"         PASS "$(decide "$(j_bash_cwd "$QL_HERE" "echo x; HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh release $QL_DOC $QL_TOK")")"
assert "ctl: pipe INTO queue-lock"              PASS "$(decide "$(j_bash_cwd "$QL_HERE" "cat $QL_DOC | HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh release $QL_DOC $QL_TOK")")"
assert "ctl: queue-lock | tail"                 PASS "$(decide "$(j_bash_cwd "$QL_HERE" "HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh status $QL_DOC | tail -1")")"
assert "ctl: queue-lock > file"                 PASS "$(decide "$(j_bash_cwd "$QL_HERE" "HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh status $QL_DOC > /tmp/out")")"
assert "ctl: force-release env prefix"          PASS "$(decide "$(j_bash_cwd "$QL_HERE" "QUEUE_LOCK_FORCE_RELEASE=1 bash scripts/handover/queue-lock.sh release $QL_DOC")")"
assert "ctl: second assignment"                 PASS "$(decide "$(j_bash_cwd "$QL_HERE" "HANDOVER_DIR=$QL_R QUEUE_LOCK_FORCE_RELEASE=1 bash scripts/handover/queue-lock.sh release $QL_DOC")")"
assert "ctl: other script name"                 PASS "$(decide "$(j_bash_cwd "$QL_HERE" "HANDOVER_DIR=$QL_R bash scripts/handover/other.sh release $QL_DOC $QL_TOK")")"
assert "ctl: bash flag before script"           PASS "$(decide "$(j_bash_cwd "$QL_HERE" "HANDOVER_DIR=$QL_R bash -x scripts/handover/queue-lock.sh release $QL_DOC $QL_TOK")")"
assert "ctl: unknown verb"                      PASS "$(decide "$(j_bash_cwd "$QL_HERE" "HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh force-release $QL_DOC")")"
assert "ctl: doc outside HANDOVER_DIR"          PASS "$(decide "$(j_bash_cwd "$QL_HERE" "HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh release /etc/passwd.md $QL_TOK")")"
assert "ctl: dot-dot doc"                       PASS "$(decide "$(j_bash_cwd "$QL_HERE" "HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh release $QL_R/../x.md $QL_TOK")")"
assert "ctl: variable doc"                      PASS "$(decide "$(j_bash_cwd "$QL_HERE" "HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh release \$DOC $QL_TOK")")"
assert "ctl: variable HANDOVER_DIR"             PASS "$(decide "$(j_bash_cwd "$QL_HERE" "HANDOVER_DIR=\$X bash scripts/handover/queue-lock.sh release $QL_DOC $QL_TOK")")"
assert "ctl: extra trailing arg"                PASS "$(decide "$(j_bash_cwd "$QL_HERE" "HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh release $QL_DOC $QL_TOK extra")")"
assert "ctl: relative doc"                      PASS "$(decide "$(j_bash_cwd "$QL_HERE" "bash scripts/handover/queue-lock.sh release yotamleo/x.md $QL_TOK")")"
assert "ctl: non-.md doc"                       PASS "$(decide "$(j_bash_cwd "$QL_HERE" "HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh release $QL_R/x.txt $QL_TOK")")"
assert "ctl: other bash script"                 PASS "$(decide "$(j_bash "bash scripts/handover/merge-on-green.sh 1 --jira-transition")")"
# Whole-command means NO unquoted separator anywhere — not merely one non-empty
# segment. scan_cmd emits an EMPTY segment after a trailing separator and the
# segment count skips it, so these once counted as a lone command (CodeRabbit,
# round 2): a trailing `&` even backgrounds the lock op. The lone command above
# still approves; each of these is a control that must fall through.
QL_LONE="HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh status $QL_DOC"
assert "ctl: trailing &"                        PASS "$(decide "$(j_bash_cwd "$QL_HERE" "$QL_LONE &")")"
assert "ctl: trailing ;"                        PASS "$(decide "$(j_bash_cwd "$QL_HERE" "$QL_LONE;")")"
assert "ctl: trailing && (empty tail)"          PASS "$(decide "$(j_bash_cwd "$QL_HERE" "$QL_LONE &&")")"
assert "ctl: trailing || (empty tail)"          PASS "$(decide "$(j_bash_cwd "$QL_HERE" "$QL_LONE ||")")"
assert "ctl: trailing |  (empty tail)"          PASS "$(decide "$(j_bash_cwd "$QL_HERE" "$QL_LONE |")")"
# A bare trailing newline never reaches the scanner (the hook's `$(jq …)` capture
# strips it), and `cmd\n` is the identical single command to the shell, so it
# approves; a newline that leaves ANYTHING behind it is a real separator.
assert "lone command + bare trailing newline"   ALLOW "$(decide "$(j_bash_cwd "$QL_HERE" "$QL_LONE"$'\n')")"
assert "ctl: newline + whitespace tail"         PASS "$(decide "$(j_bash_cwd "$QL_HERE" "$QL_LONE"$'\n  ')")"
assert "ctl: newline + second command"          PASS "$(decide "$(j_bash_cwd "$QL_HERE" "$QL_LONE"$'\necho x')")"
assert "ctl: leading newline + command"         PASS "$(decide "$(j_bash_cwd "$QL_HERE" $'\n'"$QL_LONE")")"
assert "ctl: trailing ;;"                       PASS "$(decide "$(j_bash_cwd "$QL_HERE" "$QL_LONE ;;")")"
assert "ctl: leading ;"                         PASS "$(decide "$(j_bash_cwd "$QL_HERE" "; $QL_LONE")")"
assert "ctl: leading &&"                        PASS "$(decide "$(j_bash_cwd "$QL_HERE" "&& $QL_LONE")")"
assert "ctl: release trailing &"                PASS "$(decide "$(j_bash_cwd "$QL_HERE" "HANDOVER_DIR=$QL_R bash scripts/handover/queue-lock.sh release $QL_DOC $QL_TOK &")")"
assert "the lone command still approves"        ALLOW "$(decide "$(j_bash_cwd "$QL_HERE" "$QL_LONE")")"

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
# Position 2 (absolute script path). HIMMEL-3494: a drive-letter or backslash
# script word is refused outright. On POSIX `C:/x/…` was checked as a checkout
# root resolved against the hook's $PWD, but bash runs whatever that relative
# name reaches — and `C:\scripts\handover\queue-lock.sh` is ONE slash-less file
# in the cwd, any content. A `C:` symlink in the hook's cwd pointing at the real
# checkout makes the check pass, so every row below must still fall through.
QD_DRV="$(mktemp -d "${TMPDIR:-/tmp}/qd-drv.XXXXXX")"
QD_FAKE="$(mktemp -d "${TMPDIR:-/tmp}/qd-fake.XXXXXX")"; mkdir -p "$QD_FAKE/scripts/handover" "$QD_FAKE/.git"; : > "$QD_FAKE/scripts/handover/queue-lock.sh"
ln -s "$QL_HERE" "$QD_DRV/C:" 2>/dev/null; ln -s "$QL_HERE" "$QD_DRV/c:" 2>/dev/null; ln -s "$QD_FAKE" "$QD_DRV/D:" 2>/dev/null; ln -s "$QL_HERE" "$QD_DRV/C:\\" 2>/dev/null
if [ -f "$QD_DRV/C:/scripts/handover/queue-lock.sh" ] && [ -f "$QD_DRV/c:/scripts/handover/queue-lock.sh" ] && [ -f "$QD_DRV/D:/scripts/handover/queue-lock.sh" ]; then
    qdd() { decide_in "$QD_DRV" "$(j_bash "$1")"; }   # no payload cwd → cwd = the symlink dir
    assert "ctl: drive abs script C:/, own checkout"    PASS "$(qdd "HANDOVER_DIR=$QD_R bash C:/scripts/handover/queue-lock.sh release $QD_DOC $QL_TOK")"
    assert "ctl: drive abs script c:/ (lower-case)"     PASS "$(qdd "HANDOVER_DIR=$QD_R bash c:/scripts/handover/queue-lock.sh release $QD_DOC $QL_TOK")"
    assert "ctl: drive abs script, single-quoted \\"     PASS "$(qdd "HANDOVER_DIR=$QD_R bash 'C:\\scripts\\handover\\queue-lock.sh' release $QD_DOC $QL_TOK")"
    assert "ctl: drive abs script, double-quoted \\"     PASS "$(qdd "HANDOVER_DIR=$QD_R bash \"C:\\scripts\\handover\\queue-lock.sh\" release $QD_DOC $QL_TOK")"
    assert "ctl: drive abs script, unquoted \\\\"        PASS "$(qdd "HANDOVER_DIR=$QD_R bash C:\\\\scripts\\\\handover\\\\queue-lock.sh release $QD_DOC $QL_TOK")"
    assert "ctl: drive abs script + sweep"              PASS "$(qdd "bash C:/scripts/handover/queue-lock.sh status --sweep $QD_R")"
    assert "ctl: rel script, drive payload cwd on POSIX" PASS "$(decide_in "$QD_DRV" "$(j_bash_cwd C:/ "$QD_S status $QL_DOC")")"
    assert "ctl: rel script, backslash payload cwd"     PASS "$(decide_in "$QD_DRV" "$(j_bash_cwd "C:\\" "$QD_S status $QL_DOC")")"
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
# HIMMEL-3880: bash 3.2 brace-expands `{a,b}` in a double-quoted string nested
# inside "$(...)", so the row once handed is_dec the plain impacted-suites
# literal (a legit ALLOW) on macOS. Each brace command is assigned first (an
# assignment is never brace-expanded), and a precondition proves it still
# carries its brace.
IS_BR_COMMA="bash scripts/cr/{impacted-suites,other}.sh $IS_R"
IS_BR_RANGE="bash scripts/cr/impacted-suite{r..s}.sh $IS_R"
IS_BR_NEST="bash scripts/cr/{{impacted-suites,other},x}.sh $IS_R"
IS_BR_CMD="{bash,sh} scripts/cr/impacted-suites.sh $IS_R"
IS_BR_ARG="$IS_REL --check {$IS_R,x}"
IS_BR_KEPT=PASS
case "$IS_BR_COMMA|$IS_BR_RANGE|$IS_BR_NEST|$IS_BR_CMD|$IS_BR_ARG" in
    *'{impacted-suites,other}'*'{r..s}'*'{{impacted-suites,other},x}'*'{bash,sh}'*",x}") IS_BR_KEPT=ALLOW ;;
esac
assert "precondition: brace commands kept literal" ALLOW "$IS_BR_KEPT"
assert "ctl: is brace in path"               PASS "$(is_dec "$IS_W" "$IS_BR_COMMA")"
assert "ctl: is brace range in path"         PASS "$(is_dec "$IS_W" "$IS_BR_RANGE")"
assert "ctl: is nested brace in path"        PASS "$(is_dec "$IS_W" "$IS_BR_NEST")"
assert "ctl: is brace in command word"       PASS "$(is_dec "$IS_W" "$IS_BR_CMD")"
assert "ctl: is brace in argument"           PASS "$(is_dec "$IS_W" "$IS_BR_ARG")"
# The raw brace payload fed to the hook through files, with no is_dec and no
# nested-quote "$(...)" between the brace text and the hook's stdin.
j_bash_cwd "$IS_W" "$IS_BR_COMMA" > "$IS_TMP/brace.json"
IS_BR_RC=0
HIMMEL_REPO="$IS_A" bash "$HOOK" < "$IS_TMP/brace.json" > "$IS_TMP/brace.out" 2>/dev/null || IS_BR_RC=$?
if grep -qF '{impacted-suites,other}' "$IS_TMP/brace.json"; then IS_BR_RAW=ALLOW; else IS_BR_RAW=PASS; fi
assert "precondition: raw brace payload carries the brace" ALLOW "$IS_BR_RAW"
# A crashed hook also emits no allow; the row counts only a clean fall-through.
assert "precondition: raw brace payload hook exited 0" 0 "$IS_BR_RC"
if grep -qF '"permissionDecision":"allow"' "$IS_TMP/brace.out"; then IS_BR_RAW=ALLOW; else IS_BR_RAW=PASS; fi
assert "ctl: is brace in path, raw payload"  PASS "$IS_BR_RAW"
assert "ctl: is trailing &"                  PASS "$(is_dec "$IS_W" "$IS_REL $IS_R &")"
IS_OUT=$(j_bash_cwd "$IS_W" "$IS_REL $IS_R" | HIMMEL_REPO="$IS_W" bash "$HOOK" 2>/dev/null)
assert "ctl: is HIMMEL_REPO = own worktree"  PASS "$(grepq "$IS_OUT" '"permissionDecision":"allow"' && echo ALLOW || echo PASS)"
rm -rf "$IS_TMP"

# --- HIMMEL-3660: auto-approve must not cook brace/parameter expansion literally ---
# The shell EXPANDS these before the command runs, but a literal-word match
# sees one un-exploded token and misses the write/delete/exec flag hiding
# inside it. FAIL CLOSED: these must PASS (fall through to a normal prompt),
# never ALLOW.
assert "sort brace -o/F split"        PASS "$(decide "$(j_bash 'sort {-o,F} f')")"
assert "sort param-default -o"        PASS "$(decide "$(j_bash 'sort ${X:--o/tmp/p} f')")"
assert "sort brace compress-program"  PASS "$(decide "$(j_bash 'sort {--compress-program=sh,f}')")"
assert "find brace -delete/-print"    PASS "$(decide "$(j_bash 'find . {-delete,-print}')")"
# Controls: unrelated shapes must keep behaving exactly as before.
assert "sort plain still ALLOW"       ALLOW "$(decide "$(j_bash 'sort f')")"
assert "find -name still ALLOW"       ALLOW "$(decide "$(j_bash "find . -name '*.md'")")"
assert "quoted literal brace ALLOW"   ALLOW "$(decide "$(j_bash "echo '{a,b}'")")"
assert "sort quoted literal brace"    ALLOW "$(decide "$(j_bash "sort '{a,b}' f")")"

# --- HIMMEL-3660 / J1300O finding (a): segment_is_rootwalk_find must treat an
# uncookable word ($VAR, brace) as OPAQUE and keep scanning, never bail out of
# the whole HIMMEL-2121 root-walk DENY the instant one word can't be cooked.
assert "rootwalk \$X quoted survives cook-fail" DENY "$(decide "$(j_bash 'find / -name "$X"')")"
assert "rootwalk \$X unquoted survives cook-fail" DENY "$(decide "$(j_bash 'find / -name $X')")"
assert "rootwalk \${X} survives cook-fail" DENY "$(decide "$(j_bash 'find / -name ${X}')")"
assert "rootwalk \$f in -newer survives cook-fail" DENY "$(decide "$(j_bash 'find / -newer $f')")"
assert "rootwalk loop-variable survives cook-fail" DENY "$(decide "$(j_bash 'for f in a b; do find / -name $f; done')")"
assert "rootwalk \$Y after -o survives cook-fail" DENY "$(decide "$(j_bash 'find / -name x -o -name $Y')")"
assert "rootwalk \$N maxdepth-value survives cook-fail" DENY "$(decide "$(j_bash 'find / -maxdepth $N -name x')")" # gnu-ok: fixture string fed to the hook under test, never executed as a shell command
assert "rootwalk brace maxdepth-value survives cook-fail" DENY "$(decide "$(j_bash 'find / -maxdepth {1,2} -name x')")" # gnu-ok: fixture string fed to the hook under test, never executed as a shell command
assert "rootwalk brace path-operand survives cook-fail" DENY "$(decide "$(j_bash 'find / -name *.{md,txt}')")"
# Control: the $(...) rootwalk DENY (round-3 lock, :346) must still hold.
assert "rootwalk \$(...)  still DENY"  DENY "$(decide "$(j_bash 'find / -iname $(hostname)')")"

# --- HIMMEL-3660 / J1300O finding (b): an UNQUOTED glob word (*, ?, [) in a
# guarded arm must fall through to normal permission, never auto-approve —
# real exploit: with a file named `-oPWNED` present, `sort -* f` wrote PWNED.
assert "sort -* glob"                 PASS "$(decide "$(j_bash 'sort -* f')")"
assert "sort ?o glob"                 PASS "$(decide "$(j_bash 'sort ?o f')")"
assert "sort [-]o glob"               PASS "$(decide "$(j_bash 'sort [-]o f')")"
assert "sort bare * glob"             PASS "$(decide "$(j_bash 'sort *')")"
assert "sort *.txt glob"              PASS "$(decide "$(j_bash 'sort *.txt')")"
assert "find . -* glob"               PASS "$(decide "$(j_bash 'find . -*')")"
assert "find -name x -o -* glob"      PASS "$(decide "$(j_bash 'find . -name x -o -*')")"
assert "find bare * glob"             PASS "$(decide "$(j_bash 'find *')")"
assert "tree -* glob"                 PASS "$(decide "$(j_bash 'tree -*')")"
assert "base64 -* glob"               PASS "$(decide "$(j_bash 'base64 -*')")"
# Controls: a QUOTED glob is a literal word, not shell-expanded — must keep
# auto-approving exactly as before.
assert "find quoted glob still ALLOW" ALLOW "$(decide "$(j_bash "find . -name '*.md'")")"
assert "sort quoted glob still ALLOW" ALLOW "$(decide "$(j_bash "sort '-*' f")")"

# --- HIMMEL-3732 / HIMMEL-3733 (J1300A findings 6,7): an unquoted `(` in ANY
# word is zsh glob-qualifier / grouping syntax under zsh defaults — arbitrary
# code (`f(e:'cmd':)`) or a real write (`(-)oPWNED`) — independent of which
# binary carries it, so this is a GLOBAL refusal, not confined to the six
# write-guarded arms. Quoted/escaped `(` and the already-handled
# $(...)/<(...)/>(...)/$((...)) constructs stay unaffected.
assert "glob-qualifier exec f(e:...)"  PASS "$(decide "$(j_bash "cat f(e:'touch /tmp/x':)")")"
assert "glob-qualifier plus f(+cmd)"   PASS "$(decide "$(j_bash 'cat f(+cmd)')")"
assert "glob-qualifier dot *(.)"       PASS "$(decide "$(j_bash 'ls *(.)')")"
assert "grouping-glob sort (-)oX"      PASS "$(decide "$(j_bash 'sort (-)oX f')")"
assert "grouping (a|b) word"           PASS "$(decide "$(j_bash 'cat (a|b)')")"
assert "glob-qualifier grep f(N)"      PASS "$(decide "$(j_bash 'grep x f(N)')")"
# Controls: quoted/escaped '(' and unrelated shapes must keep ALLOWing.
assert "quoted paren in grep pattern"  ALLOW "$(decide "$(j_bash "grep '(' f")")"
assert "quoted paren in dquote arg"    ALLOW "$(decide "$(j_bash 'grep "a(b)" f')")"
assert "escaped paren"                 ALLOW "$(decide "$(j_bash 'echo \(')")"
assert "cmd-subst paren still PASS"    PASS "$(decide "$(j_bash 'cat "$(pwd)/f"')")"
assert "plain cat README still ALLOW"  ALLOW "$(decide "$(j_bash 'cat README.md')")"
assert "plain git log still ALLOW"     ALLOW "$(decide "$(j_bash 'git log --oneline -1')")"

# --- HIMMEL-3750 (J1366A finding 1): zsh parameter-flag expansions reach code
# execution or defeat quoting even INSIDE double quotes, so SCAN_MASK's
# quoted-span blanking never sees them — must be caught on the RAW text.
assert "param-flag (e) exec via char-code \$(" PASS "$(decide "$(j_bash 'echo "${(e)${:-${(#):-36}${(#):-40}touch PWN${(#):-41}}}"')")"
assert "param-flag (e) quoted"         PASS "$(decide "$(j_bash 'cat "${(e)X}"')")"
assert "param-flag (%) quoted"         PASS "$(decide "$(j_bash 'ls "${(%):-%x}"')")"
assert "param-flag through git log --" PASS "$(decide "$(j_bash 'git log -- "${(e)X}"')")"
# \$= / \${= (SH_WORD_SPLIT) forces field-splitting even inside double quotes,
# so a quoted "\$=x" can still explode into a flag argv word.
assert "dollar-eq splits through quotes"      PASS "$(decide "$(j_bash 'ls "$=x"')")"
assert "dollar-brace-eq splits through quotes" PASS "$(decide "$(j_bash 'ls "${=x}"')")"
# Checked and left alone: quoted \${~...} (GLOB_SUBST) does NOT glob under
# zsh -f (VERIFIED) — quoting still protects it, so it stays ALLOW.
assert "param-flag (~) quoted stays ALLOW"    ALLOW "$(decide "$(j_bash 'echo "${~x}"')")"
# HIMMEL-3750 (J1366A finding 4) regression: a backslash-newline between \$
# and ( hides \$( from the raw tripwire on main; head must still refuse it.
assert "backslash-newline \$( regression" PASS "$(decide "$(j_bash "echo \$\\"$'\n''(touch PWN)')")"
# Accepted false refusal (brief-documented): a SINGLE-QUOTED literal '\${('
# is refused too, since the fix reads the RAW command text, not the mask.
assert "single-quoted literal \${( (accepted false refusal)" PASS "$(decide "$(j_bash "grep '\${(' f")")"
# codex-1 (round 3): a backslash-newline between \$ and = INSIDE double quotes
# is folded away by the shell before parsing, same as finding 4's \$( case,
# but the newline sits inside the quotes here so the unquoted-separator
# fallback that protects finding 4 does not fire. Confirmed ALLOW (bypass) on
# the pre-fix code; the fold added above joins it into "\$=x" before the
# tripwires run, so it now falls through like any other \$= case.
assert "backslash-newline \$= regression" PASS "$(decide "$(j_bash "ls \"\$\\"$'\n''=x"')")"
# Judge J1370A (round 4, NO-GO): the round-3 fold above folded EVERY
# backslash-newline pair unconditionally, even when the backslash was itself
# escaped by a preceding backslash — an even run of backslashes before the
# newline pairs off completely in real shell parsing, leaving the newline a
# genuine, unescaped command separator. Folding it anyway merged two real
# commands into one harmless-looking approved line while the shell still ran
# the second command. These four must stay PASS (fall through, not approved),
# matching main's (safe) behavior exactly.
assert "escaped-backslash-newline stays PASS (J1370A finding 1a)" PASS "$(decide "$(j_bash "echo \\\\"$'\n'"touch PWN")")"
assert "escaped-backslash-newline w/ prior word stays PASS (finding 1b)" PASS "$(decide "$(j_bash "echo a\\\\"$'\n'"touch PWN")")"
assert "escaped-backslash-newline via cat/rm stays PASS (finding 1c)" PASS "$(decide "$(j_bash "cat f \\\\"$'\n'"rm -rf x")")"
assert "double escaped-backslash-newline stays PASS (finding 1d)" PASS "$(decide "$(j_bash "echo \\\\"$'\n'"\\\\"$'\n'"touch PWN")")"
# Control: a genuine (odd, single) backslash-newline continuation of an
# otherwise benign command must still fold and stay ALLOW.
assert "genuine single-backslash continuation still ALLOW" ALLOW "$(decide "$(j_bash "echo a \\"$'\n'"b")")"
# codex-1 (round 5): an ODD run of 3+ backslashes before the newline still
# has a genuine (single) continuation, but the code used to pre-COLLAPSE the
# other (N-1, always even) backslashes down to (N-1)/2 literal backslash
# BYTES before scan_cmd ever saw them. scan_cmd's own backslash-escape walk
# then treated that single residual backslash as a FRESH, still-escaping
# byte and swallowed the very next character — here a real `;` separator —
# as if it were escaped, hiding a second real command inside what looked
# like one approved `echo` line. VERIFIED (real bash): `echo hi\\\`+NL+
# `; touch PWN` runs `touch PWN` as its own command. Left raw (this fix),
# scan_cmd's own char-by-char escape rule re-derives the same even pairing
# and correctly leaves the `;` unescaped, so this must stay PASS (fall
# through), not get folded into a single approved segment.
assert "odd(3) backslash-newline leaves real separator visible (codex-1)" PASS "$(decide "$(j_bash "echo hi\\\\\\"$'\n'"; touch PWN")")"
# codex-1 (round 6): fold_backslash_newline() toggled its single-quote state
# on ANY `'`, even one appearing INSIDE double quotes, where it is a plain
# literal character, not a quote delimiter. `echo "'$\<NL>(touch PWN)"` has
# its apostrophe inside double quotes; the old code wrongly treated it as
# opening a single-quoted span (no closing `'` ever follows), so the fold
# never ran and the raw `$(` tripwire never saw the reconstituted `$(`.
# VERIFIED (real bash): this exact string, run as a script, executes
# `touch PWN`. Must fall through to PASS, not ALLOW.
assert "apostrophe inside dquotes no longer blocks fold (codex-1 round 6)" PASS "$(decide "$(j_bash "echo \"'\$\\"$'\n'"(touch PWN)\"")")"
# codex-1 (round 7): the `"` toggle in fold_backslash_newline() fired on ANY
# `"` byte, even one immediately preceded by a backslash (an ESCAPED quote,
# which stays a literal char and never closes the real double-quoted span).
# `echo "\"'$\<NL>(touch PWN)"` has that escaped `"` right after the opening
# quote; the old code wrongly flipped in_dq to 0, which then let the
# following (still-really-inside-double-quotes) apostrophe wrongly open the
# fake single-quote span, suppressing the fold for the rest of the string and
# hiding the reconstituted `$(` from the raw tripwire.
# VERIFIED (real bash): this exact string, run as a script, executes
# `touch PWN`. Must fall through to PASS, not ALLOW.
assert "escaped dquote no longer mistoggles state (codex-1 round 7)" PASS "$(decide "$(j_bash "echo \"\\\"'\$\\"$'\n'"(touch PWN)\"")")"
# Controls: common benign expansions must keep ALLOWing.
assert "echo \${HOME} still ALLOW"     ALLOW "$(decide "$(j_bash 'echo "${HOME}"')")"
assert "echo \$PWD still ALLOW"        ALLOW "$(decide "$(j_bash 'echo "$PWD"')")"

# --- HIMMEL-3762 (J1370A finding 2): a backslash-newline INSIDE a `#`
# comment must not fold as a continuation — the shell ends a comment at the
# very next newline unconditionally, backslash or not, so a real command
# hiding on the next line must stay its own segment (PASS), never get
# swallowed into the approved comment line (ALLOW).
# VERIFIED (real bash): every payload below, run as a script, executes the
# `touch PWN*` line as an independent second command.
assert "backslash-newline in a plain comment stays PASS" PASS "$(decide "$(j_bash "echo hi # x \\"$'\n'"touch PWN")")"
assert "backslash-newline in a comment inside a compound stays PASS" PASS "$(decide "$(j_bash "ls -la && echo ok # x \\"$'\n'"touch PWN2")")"
assert "backslash-newline after a QUOTED # (real comment follows) stays PASS" PASS "$(decide "$(j_bash "echo \"#\" # cmt \\"$'\n'"touch PWN3")")"
assert "backslash-newline in a comment, CRLF, stays PASS" PASS "$(decide "$(j_bash "echo hi # x \\"$'\r\n'"touch PWN4")")"
assert "odd(3) trailing backslashes in a comment stays PASS" PASS "$(decide "$(j_bash "echo hi # x \\\\\\"$'\n'"touch PWN5")")"
# Controls: a `#` that is NOT a real comment start (quoted, or not at a word
# boundary — \$#, \${#x}, mid-word) must not suppress a genuine continuation.
assert "quoted # does not block a real continuation"      ALLOW "$(decide "$(j_bash "echo \"a # b\" \\"$'\n'"echo c")")"
assert "\$# does not block a real continuation"            ALLOW "$(decide "$(j_bash "echo \$# \\"$'\n'"echo c")")"
assert "\${#x} does not block a real continuation"          ALLOW "$(decide "$(j_bash "echo \${#x} \\"$'\n'"echo c")")"
assert "mid-word # does not block a real continuation"     ALLOW "$(decide "$(j_bash "echo foo#bar \\"$'\n'"echo c")")"

# --- J1385A (HIMMEL-3762 NO-GO finding 1): a comment must still SPLIT on an
# unquoted separator exactly as it does outside a comment — the fix must only
# suppress the backslash-newline continuation fold, never the segment break.
# main already denies (PASS) these, so head must match, never widen to ALLOW.
assert "; after a comment start still splits the segment"  PASS "$(decide "$(j_bash 'echo hi #x; touch MARKER')")"
assert "&& after a comment start still splits the segment" PASS "$(decide "$(j_bash 'echo hi #x && touch M')")"
assert "| after a comment start still splits the segment"  PASS "$(decide "$(j_bash 'echo hi #x | sh')")"
assert "& after a comment start still splits the segment"  PASS "$(decide "$(j_bash 'echo hi #x & touch M')")"

# codex-1 (round 2): a quote character inside a real comment must not enter
# quote state — a real shell gives comments zero quote semantics, so a
# balanced quote spanning the newline must never mask the real separator and
# hide a following command inside SCAN_MASK. main already denies (PASS) these.
assert "dquote inside a comment does not mask the next newline (codex-1)" PASS "$(decide "$(j_bash "echo hi #say \"x"$'\n'"touch MARKER\"")")"
assert "squote inside a comment does not mask the next newline (codex-1)" PASS "$(decide "$(j_bash "echo hi #it's fine"$'\n'"touch MARKER'")")"

# --- HIMMEL-3734 (J1300A finding 7): a brace-expanded root among the
# find path operands (\`{/,.}\` -> \`/ .\`) must DENY as a root-walk.
assert "find brace-expanded root DENY" DENY "$(decide "$(j_bash 'find {/,.} -name x')")"
# codex-1: // is POSIX root too (mirrors is_root_anchor's own /|// case).
assert "find brace-expanded // root DENY" DENY "$(decide "$(j_bash 'find {//,.} -name x')")"
# codex-2 (round 3): any run of slashes only (///, not just / and //) is root.
assert "find brace-expanded /// root DENY" DENY "$(decide "$(j_bash 'find {///,.} -name x')")"
# codex-1 (round 8): `/.` is root too (mirrors is_root_anchor's own trailing
# `/.` strip) — VERIFIED: unfixed hook returned PASS (not DENY) for this exact
# command before the fix.
assert "find brace-expanded /. root DENY" DENY "$(decide "$(j_bash 'find {/.,a} -name x')")"
# Controls: brace alternatives with no bare '/' stay as before (opaque, PASS).
assert "find brace non-root stays PASS" PASS "$(decide "$(j_bash 'find {a,b} -name x')")"
assert "find brace maxdepth-value unaffected" DENY "$(decide "$(j_bash 'find / -maxdepth {1,2} -name x')")" # gnu-ok: fixture string fed to the hook under test, never executed as a shell command

# --- HIMMEL-3773 (J1385A/B finding 3): the CRLF->LF fold used to run
# unconditionally, so a real backslash+CR+LF was seen as backslash+LF, a
# genuine continuation, and the command that followed the CR was swallowed
# into the prior approved segment. Real bash never treats `\`+CR as a
# continuation (CR has no special meaning; it is just an escaped byte), and
# the LF that follows it is a plain statement-ending newline. VERIFIED (real
# bash, run as a script): every ALLOW-on-unfixed-head payload below executes
# the `touch PWN*` line as its own, independent command.
assert "plain backslash+CRLF hides a second command"        PASS "$(decide "$(j_bash "echo hi \\"$'\r\n'"touch PWN10")")"
assert "compound prefix, backslash+CRLF hides a second command" PASS "$(decide "$(j_bash "ls -la && echo hi \\"$'\r\n'"touch PWN11")")"
assert "backslash+CRLF after a prior # comment line"        PASS "$(decide "$(j_bash "echo hi # cmt"$'\n'"echo ok \\"$'\r\n'"touch PWN12")")"
assert "even(2) backslash run + CRLF: still no continuation" PASS "$(decide "$(j_bash "echo hi\\\\\\"$'\r\n'"touch PWN13")")"
assert "odd(3) backslash run + CRLF: still no continuation"  PASS "$(decide "$(j_bash "echo hi\\\\\\\\\\"$'\r\n'"touch PWN14")")"
# Control: a backslash+CR+LF INSIDE a real `#` comment already stayed PASS
# before this fix (in_cm short-circuits before the backslash branch) —
# unaffected by fold_crlf(), still PASS: see "backslash-newline in a comment,
# CRLF, stays PASS" above.
# Control: a lone CR (no following LF) is not a CRLF pair — fold_crlf() must
# leave it untouched. It is not an exploit either way: the escaped CR merges
# into the following word (no separator), so nothing hidden ever executes.
assert "lone CR (no LF) is untouched by fold_crlf, no exploit" ALLOW "$(decide "$(j_bash "echo hi \\"$'\r'"touch PWN15")")"
# Control: a genuine safe continuation with a real LF (no CR at all) must
# still fold and ALLOW — fold_crlf() only withholds the fold for a
# backslash-preceded CR, never for a bare backslash+LF.
assert "genuine LF-only continuation still ALLOW"            ALLOW "$(decide "$(j_bash "echo a \\"$'\n'"echo b")")"

# --- HIMMEL-3773 round 2 / HIMMEL-3776 (judge J1387A): a genuine `\`+LF
# continuation, run under Windows jq.exe (every LF of jq's -r output
# rendered as CRLF), reaches the hook as `\`+CR+LF — byte-identical to the
# CRLF-continuation attack payload. Detecting the rendering from the CR jq
# already appends to the `tool` line (before this fix stripped it) lets the
# hook fold ALL CRLF back to LF on that path only (main's original, correct
# Windows behavior), while never folding on native jq (no rendering
# artifact to undo). VERIFIED (real bash): the destructive join below
# genuinely runs `find . echo -delete` once the two lines are joined.
assert "win-jq: crafted \\+CRLF join still PASS (destructive join blocked)" \
    PASS "$(decide_win "$(j_bash "find . \\"$'\n'"echo -delete")")"
assert "native jq: same payload, unaffected by win-jq detection, stays PASS" \
    PASS "$(decide "$(j_bash "find . \\"$'\n'"echo -delete")")"
# Control: a genuine continuation under win-jq rendering must still ALLOW —
# this is the HIMMEL-3776 usability loss the round-1 fix introduced, closed
# by folding on the win-jq path instead of deferring it.
assert "win-jq: genuine continuation still ALLOW (HIMMEL-3776 closed)" \
    ALLOW "$(decide_win "$(j_bash "git status \\"$'\n'"  --help")")"
# Control: a CR-free command takes the fast path (no CR at all to fold, on
# either jq rendering) — same verdict either way.
assert "win-jq: CR-free command unaffected" \
    ALLOW "$(decide_win "$(j_bash 'git log --oneline -1')")"

# --- HIMMEL-3777: the &-branch's fd-dup lookback (2>&1 / >&2, line ~908)
# reads the raw previous byte without checking whether THAT byte was itself
# the escaped payload of a preceding `\x` pair. An escaped `\&` followed by
# a real, live `&` then misreads the escaped `&` as a fd-dup neighbor and
# keeps the live `&` out of the bare-& break, hiding a second command.
# VERIFIED (real bash, scratch dir, marker-file M): each "HIDDEN-RAN" case
# below genuinely runs `touch M` as a second, separate command; each
# "no-hidden-run" case does not (`&` stays inert data). PASS is the correct
# verdict for a hidden-run case (the whole string must NOT be auto-ALLOWed);
# ALLOW is correct only where nothing is hidden.
assert "escaped amp, 1 backslash: touch M hidden (HIDDEN-RAN)" \
    PASS "$(decide "$(j_bash 'echo hi \&& touch M')")"
assert "escaped amp, 1 backslash, glued (HIDDEN-RAN)" \
    PASS "$(decide "$(j_bash 'echo hi \&&touch M')")"
assert "escaped amp, odd (3) backslashes: still escapes (HIDDEN-RAN)" \
    PASS "$(decide "$(j_bash 'echo hi \\\&& touch M')")"
assert "escaped amp, even (2) backslashes: real && (HIDDEN-RAN, pre-existing PASS)" \
    PASS "$(decide "$(j_bash 'echo hi \\&& touch M')")"
# BOTH &s individually backslash-escaped is truly literal text — no operator
# ever reaches the &-branch, no hidden run. HIMMEL-3793: it still falls through
# now (uniform rule: any unquoted `\&` stops auto-approving), a harmless prompt.
assert "both amps escaped: literal, no hidden run (falls through, HIMMEL-3793)" \
    PASS "$(decide "$(j_bash 'echo a\&\&b touch M')")"
# Controls: an escaped `;` or `|` is likewise fully consumed as literal data
# by the existing single-character escape walk (no lookback involved), so
# these were never part of this bug — confirm no regression.
assert "escaped semicolon: literal, no hidden run (control)" \
    ALLOW "$(decide "$(j_bash 'echo hi \; touch M')")"
assert "escaped pipe: literal, no hidden run (control)" \
    ALLOW "$(decide "$(j_bash 'echo hi \| touch M')")"
# Quoted variants: the backslash is INSIDE quotes (no escaping effect on the
# `&` outside), so this is a plain, visible `&&` chain — HIDDEN-RAN for real,
# but not disguised, and already correctly not auto-ALLOWed pre-fix.
assert "single-quoted backslash before real &&: visible chain (control)" \
    PASS "$(decide "$(j_bash "echo 'x\\'&& touch M")")"
assert "double-quoted backslash before real &&: visible chain (control)" \
    PASS "$(decide "$(j_bash 'echo "x\\"&& touch M')")"
# fd-dup must still parse as one safe segment even right after this fix.
assert "2>&1 fd-dup still safe post-fix"   ALLOW "$(decide "$(j_bash 'grep x f 2>&1 | head')")"
assert "amp-redirect &>devnull still safe post-fix" ALLOW "$(decide "$(j_bash 'grep x f &>/dev/null')")"

# --- HIMMEL-3782 (judge J1387B): an unquoted `>&2` followed by a lone CR is
# not a valid fd-dup word to real bash — the CR glues onto the digit, so the
# redirect target word is "2<CR>" (not the digit 2), and bash opens a REAL
# FILE named "2<CR>" instead of duplicating fd 2. VERIFIED (real bash, scratch
# dir): `grep x f >&2<CR>` creates a junk file literally named `2\r`. Must not
# auto-approve: falls through to PASS (the normal prompt), same as any other
# real-file redirect.
assert "fd-dup >&2 + lone CR writes a junk file (must not ALLOW)" \
    PASS "$(decide "$(j_bash "grep x f >&2"$'\r')")"
assert "fd-dup >&2 + CR then a second line (must not ALLOW)" \
    PASS "$(decide "$(j_bash "grep x f >&2"$'\r'"echo y")")"
# 2>&1 + lone CR: real bash raises "ambiguous redirect" (word "1<CR>" is not
# all-digit) instead of writing a file, but it is still not a genuine
# fd-dup — must not auto-approve either.
assert "fd-dup 2>&1 + lone CR is ambiguous, not a real fd-dup (must not ALLOW)" \
    PASS "$(decide "$(j_bash "grep x f 2>&1"$'\r')")"
# Controls: the CR-free originals must keep ALLOWing — this fix must not
# regress the ordinary fd-dup case.
assert "fd-dup >&2, no CR, still ALLOW (control)" \
    ALLOW "$(decide "$(j_bash 'grep x f >&2')")"
assert "fd-dup 2>&1, no CR, still ALLOW (control)" \
    ALLOW "$(decide "$(j_bash 'grep x f 2>&1')")"
# >&- (close fd) + CR was never matched by the digit-only strip pattern in the
# first place, so it already stays PASS — pin it so a future rewrite of the
# strip regex doesn't accidentally start ALLOWing it.
assert "fd-dup >&- + CR stays PASS (pre-existing, pin)" \
    PASS "$(decide "$(j_bash "grep x f >&-"$'\r')")"

# Same shapes under the CRLF-rendering jq shim (Windows jq.exe path): the
# embedded CR is not a line terminator by itself, so fold_crlf's CRLF-fold
# leaves it in place same as native — the fix must hold under both renderings.
assert "fd-dup >&2 + lone CR, CRLF-shim rendering (must not ALLOW)" \
    PASS "$(decide_win "$(j_bash "grep x f >&2"$'\r')")"
assert "fd-dup 2>&1 + lone CR, CRLF-shim rendering (must not ALLOW)" \
    PASS "$(decide_win "$(j_bash "grep x f 2>&1"$'\r')")"

# --- J1397A finding 1: ordinary trailing fd-dup must still ALLOW under the
# CRLF-shim (Windows jq.exe) rendering. jq.exe's own final-line CRLF leaves a
# stray, unpaired CR on the end of every command it renders (the LF/CR pair
# `$()` strips is only jq's very last newline); before this fix that stray CR
# was indistinguishable from a HIMMEL-3782 crafted CR and fell through to
# PASS on every ordinary command ending in a bare fd-dup. Must go back to
# ALLOW, while the genuinely crafted CR above (which arrives DOUBLED under
# this same rendering) still stays PASS.
assert "ordinary >&2, no CR, still ALLOW under CRLF-shim (J1397A finding 1)" \
    ALLOW "$(decide_win "$(j_bash 'echo "msg" >&2')")"
assert "ordinary 2>&1, no CR, still ALLOW under CRLF-shim (J1397A finding 1)" \
    ALLOW "$(decide_win "$(j_bash 'ls 2>&1')")"

# --- HIMMEL-3786 (judge J1391A): pin the escaped ->-before-fd-dup-& shapes
# (2\>&1 / \>&2) that #1391 (HIMMEL-3777) fixed but never got an explicit test
# row for. Escaping the `>` leaves a live, unescaped `&` right after it — the
# exact shape the &-branch's fd-dup lookback misparsed before #1391; the fix
# keeps it from being read as a hidden second command, at the cost of not
# auto-approving it either (PASS, not ALLOW) — same verdict as any other case
# scan_cmd can't prove safe.
assert "escaped \\>&1 before fd-dup &: not falsely ALLOW/DENY (HIMMEL-3786 pin)" \
    PASS "$(decide "$(j_bash 'grep x f 2\>&1 | head')")"
assert "escaped \\>&2: not falsely ALLOW/DENY (HIMMEL-3786 pin)" \
    PASS "$(decide "$(j_bash 'grep x f \>&2 | head')")"

# --- J1397A findings 2/3: the fd-dup boundary class must use [:blank:]
# (space + tab, POSIX-portable) instead of the GNU-only \t/\n bracket
# escapes, so BSD/macOS sed (where `\t`/`\n` inside `[...]` mean the literal
# characters `\` and `t`/`n`, not TAB/LF) behaves identically to GNU sed.
assert "fd-dup 2>&1 + TAB boundary: ALLOW under GNU sed (control)" \
    ALLOW "$(decide "$(j_bash "grep x f 2>&1"$'\t'"| head")")"
assert "fd-dup 2>&1 + TAB boundary: ALLOW under POSIX sed too (J1397A finding 2)" \
    ALLOW "$(decide_posix "$(j_bash "grep x f 2>&1"$'\t'"| head")")"
assert "word-glued >&2nd.txt: PASS under GNU sed (control)" \
    PASS "$(decide "$(j_bash 'grep x f >&2nd.txt')")"
assert "word-glued >&2nd.txt: PASS under POSIX sed too (J1397A finding 3)" \
    PASS "$(decide_posix "$(j_bash 'grep x f >&2nd.txt')")"

# --- HIMMEL-3793 (J1397A finding 4): a backslash-escaped CR, or a trailing
# backslash, right after an fd-dup target still writes a junk file. SCAN_MASK
# blanks BOTH bytes of an unquoted `\<x>` pair to spaces, so the fd-dup
# boundary check at :1571 sees a plain space right after the digit and treats
# it as a valid boundary — but to real bash the backslash keeps the CR
# literal, so the redirect word is "2<CR>" (a real file), not the digit 2.
# VERIFIED (real bash): `grep x f >&2\<CR>` creates a file named `2\r`;
# `grep x f >&2\` (trailing backslash, no CR) creates `2\`.
assert "fd-dup >&2 + backslash-escaped CR writes a junk file (must not ALLOW)" \
    PASS "$(decide "$(j_bash "grep x f >&2\\"$'\r')")"
assert "fd-dup >&2 + trailing backslash writes a junk file (must not ALLOW)" \
    PASS "$(decide "$(j_bash "grep x f >&2\\")")"
# Same root cause, a different consumer: an unquoted, backslash-escaped `&`
# is correctly kept as a LITERAL `&` argument (not a live separator) — but
# that literal survives as uniq's 2nd positional, which real uniq treats as
# an OUTPUT file, not another input. VERIFIED (real bash): `uniq -c f \&`
# creates a file named `&`; `uniq -c f a\&\&b` creates `a&&b`.
# Fix: ANY unquoted backslash-escaped `&` now falls through (no ALLOW) —
# uniform, no per-binary logic; an earlier uniq-specific guard kept yielding
# new bypasses each review round and was cut in favour of this.
assert "uniq 2nd positional via escaped bare & writes a junk file (must not ALLOW)" \
    PASS "$(decide "$(j_bash 'uniq -c f \&')")"
assert "uniq 2nd positional via escaped & inside a word writes a junk file (must not ALLOW)" \
    PASS "$(decide "$(j_bash 'uniq -c f a\&\&b')")"
assert "escaped & as a grep operand also falls through (uniform, not uniq-specific)" \
    PASS "$(decide "$(j_bash 'grep x f\&')")"
assert "escaped & inside double quotes is a plain quoted char: still ALLOW (control)" \
    ALLOW "$(decide "$(j_bash 'grep "a\&b" f')")"
assert "single-quoted backslash-& is literal: still ALLOW (control)" \
    ALLOW "$(decide "$(j_bash "grep 'a\\&b' f")")"
# Controls: ordinary fd-dups must keep ALLOWing — this fix must not regress
# anything main already approves.
assert "fd-dup >&2, no escape, still ALLOW (control)" \
    ALLOW "$(decide "$(j_bash 'grep x f >&2')")"
assert "fd-dup 2>&1, no escape, still ALLOW (control)" \
    ALLOW "$(decide "$(j_bash 'grep x f 2>&1')")"
assert "uniq single positional (no 2nd/output arg) still ALLOW (control)" \
    ALLOW "$(decide "$(j_bash 'uniq -c f')")"
assert "a plain backslash-escaped & INSIDE quotes still ALLOW (control)" \
    ALLOW "$(decide "$(j_bash 'grep "\&" f')")"

# --- HIMMEL-3886: an unquoted brace span (`{a,b}` / `{a..b}`) in ANY word must
# never reach an allow. The shell expands it into several argv words before the
# command runs, so `git log {--output=/tmp/PWN,-1}` runs `git log
# --output=/tmp/PWN -1` while every arm's literal-word match sees one harmless
# token. Each command is held in a single-quoted assignment (never
# brace-expanded, by bash 3.2 either — HIMMEL-3880) and passed by variable.
BR_ROWS='git log {--output=/tmp/PWN,-1}
git log {--output,PWN} -1
git log {--output=/tmp/brace\ proof,-1}
git log --{output,x}=PWN
git log --outpu{t..t}=PWN
git log {{--output=PWN,a},b}
git log "--out"{put=PWN,x}
git log {--output=PWN,"-1"}
git grep {-Otouch_PWN,x}
git grep -{O,e}touch_PWN x
git diff {--ext-diff,HEAD}
git show {--textconv,HEAD}
gh pr view {--web,1}
gh pr view --{web,x}
cat {a,b}
ls {a..c}
for f in {--output=PWN,-1}; do cat f; done
cat a && git log {--output=PWN,-1}'
while IFS= read -r BR_CMD; do
    case "$BR_CMD" in *'{'*'}'*) BR_KEPT=ALLOW ;; *) BR_KEPT=PASS ;; esac
    assert "precondition: brace row kept literal: $BR_CMD" ALLOW "$BR_KEPT"
    assert "brace-hidden word never ALLOW: $BR_CMD" PASS "$(decide "$(j_bash "$BR_CMD")")"
done <<EOF
$BR_ROWS
EOF
# The raw payload through a file, with no nested "$(...)" between the brace
# text and the hook's stdin (the HIMMEL-3880 macOS shape).
BR_TMP="$(mktemp -d "${TMPDIR:-/tmp}/aasb-brace.XXXXXX")" || exit 1
BR_CMD='git log {--output=/tmp/PWN,-1}'
j_bash "$BR_CMD" > "$BR_TMP/brace.json"
BR_RC=0
bash "$HOOK" < "$BR_TMP/brace.json" > "$BR_TMP/brace.out" 2>/dev/null || BR_RC=$?
if grep -qF '{--output=/tmp/PWN,-1}' "$BR_TMP/brace.json"; then BR_RAW=ALLOW; else BR_RAW=PASS; fi
assert "precondition: raw git brace payload carries the brace" ALLOW "$BR_RAW"
assert "precondition: raw git brace payload hook exited 0" 0 "$BR_RC"
# grep rc 2 (an unreadable output file) is ERROR, never a PASS.
BR_G=0
grep -qF '"permissionDecision":"allow"' "$BR_TMP/brace.out" || BR_G=$?
case "$BR_G" in 0) BR_RAW=ALLOW ;; 1) BR_RAW=PASS ;; *) BR_RAW=ERROR ;; esac
assert "git log brace --output, raw payload" PASS "$BR_RAW"
rm -rf "$BR_TMP"
# Controls: a brace the shell does NOT expand (quoted, escaped, no comma or
# `..`, a git reflog selector, a lone group brace) keeps its old decision.
assert "git log quoted brace still ALLOW"     ALLOW "$(decide "$(j_bash "git log '{--output=PWN,-1}'")")"
# HIMMEL-3894: build this payload in a variable first. Nested inside
# "$(… "$(j_bash '…')")", bash 3.2 brace-expands the inner `"{a,b}"` and the
# hook would see `git log "--output=PWN"` instead (the HIMMEL-3880 shape).
BR_DQ=$(j_bash 'git log "{--output=PWN,-1}"')
assert "git log dq brace still ALLOW"         ALLOW "$(decide "$BR_DQ")"
assert "git log escaped brace still ALLOW"    ALLOW "$(decide "$(j_bash 'git log \{--output=PWN,-1\}')")"
assert "git log quoted comma still ALLOW"     ALLOW "$(decide "$(j_bash 'git log {a",b"}')")"
assert "git log reflog selector still ALLOW"  ALLOW "$(decide "$(j_bash 'git log -1 HEAD@{1}')")"
assert "git show stash@{0} still ALLOW"       ALLOW "$(decide "$(j_bash 'git show stash@{0}')")"
assert "git log range still ALLOW"            ALLOW "$(decide "$(j_bash 'git log main@{1}..HEAD')")"
assert "brace group still ALLOW"              ALLOW "$(decide "$(j_bash '{ git status; git log -1; }')")"
assert "plain git log still ALLOW"            ALLOW "$(decide "$(j_bash 'git log --oneline -5')")"
assert "plain gh pr view still ALLOW"         ALLOW "$(decide "$(j_bash 'gh pr view 1')")"
# Judge (PR 1468): bash word-splits only on space, tab and newline, so a raw
# CR, FF or VT stays inside the brace word and the flag still expands out of
# it (`{--output=/tmp/PWN,-1,--,<CR>}` runs `git log --output=/tmp/PWN -1 --
# <CR>`). The control byte must not end the brace word, and any raw FF/VT
# falls through. A CR splits the hook's tokens where bash keeps one word, so
# a leading flag must stay visible as the first sub-token.
BR_CR='git log {--output=/tmp/PWN,-1,--,'$'\r''}'
BR_FF='git log {--output=/tmp/PWN,-1'$'\f''}'
BR_VT='git log {-1,--output=/tmp/PWN'$'\v''}'
assert "brace word with raw CR never ALLOW" PASS "$(decide "$(j_bash "$BR_CR")")"
assert "brace word with raw FF never ALLOW" PASS "$(decide "$(j_bash "$BR_FF")")"
assert "brace word with raw VT never ALLOW" PASS "$(decide "$(j_bash "$BR_VT")")"
assert "raw FF outside any brace never ALLOW" PASS "$(decide "$(j_bash 'git log -1'$'\f')")"
assert "CR-joined --output word never ALLOW" PASS "$(decide "$(j_bash 'git log -1'$'\r''--output=/tmp/x')")"
assert "CR-joined -c word never ALLOW" PASS "$(decide "$(j_bash 'git -c'$'\r''core.pager=x log')")"
# Control: Windows jq.exe CRLF rendering of a multi-line command still ALLOWs.
assert "win-jq: multi-line CRLF command still ALLOW" \
    ALLOW "$(decide_win "$(j_bash 'git status'$'\n''git log -1')")"

# --- HIMMEL-3886: the node arm skipped every `-*` word before the script, so
# an `=`-form code-loading flag rode along with the Jira CLI marker. Only a
# small allowlist of inert flags may precede the script now.
NODE_ROWS='node --require=./x.js scripts/jira/dist/index.js list
node --import=./x.mjs scripts/jira/dist/index.js list
node --loader=./x.mjs scripts/jira/dist/index.js list
node --experimental-loader=./x.mjs scripts/jira/dist/index.js list
node --eval=code scripts/jira/dist/index.js list
node --print=code scripts/jira/dist/index.js list
node --env-file=./x.env scripts/jira/dist/index.js list
node --openssl-config=./x.cnf scripts/jira/dist/index.js list'
while IFS= read -r NODE_CMD; do
    assert "node code-loading flag never ALLOW: $NODE_CMD" PASS "$(decide "$(j_bash "$NODE_CMD")")"
done <<EOF
$NODE_ROWS
EOF

# --- HIMMEL-3894: the git/gh/xxd/file/tree/base64 arms matched flags on raw
# tokens with exact or `-X*` patterns. A denied short flag packed into a
# cluster, a unique-prefix abbreviation of a denied long option, a quoted or
# escaped spelling, and a leading glob all reach the option unseen. Every row
# must fall through (PASS), never ALLOW.
CL_ROWS='git grep -iOtouch_PWN x
git grep -nOtouch_PWN x
git log --outp=/tmp/PWN -1
git log --out /tmp/PWN
git diff --ext HEAD
git diff --ext-d HEAD
git show --textc HEAD
git show --filt HEAD
git grep --open-files=touch_PWN x
git grep --open x
git log "--output=/tmp/PWN" -1
git log '"'"'--output'"'"'=/tmp/PWN -1
git log --"output"=/tmp/PWN
git log \--output=/tmp/PWN
git diff "--ext-diff"
git show '"'"'--textconv'"'"' HEAD
git grep -"O"touch_PWN x
git grep --"open-files-in-pager"=touch_PWN x
git show "--filters" HEAD
git --"exec-path"=/tmp log
git -"C" status push
git log *
git grep x ?x -- a
gh pr view 1 -wR o/r
gh pr view -cw 1
gh pr view 1 --we
gh pr view 1 "--web"
gh pr view 1 '"'"'-w'"'"'
gh pr view 1 \-\-web
gh pr view 1 --"web"
gh pr list *
xxd -rp in
xxd -revers in
xxd --r in
file -bC -m magic
file -zC x
tree -ao out
base64 -io out
git log ""*
git log "-"*
gh pr view 1 ""*
git log --grep -- *
git grep -e -- *
gh pr view 1 -- *
git -C p* status
git --git-dir g* log
git --work-tree w* show
git -C "p"* diff
git symbolic-ref H*'
while IFS= read -r CL_CMD; do
    assert "cluster/abbrev/quoted flag or leading glob never ALLOW: $CL_CMD" PASS "$(decide "$(j_bash "$CL_CMD")")"
done <<EOF
$CL_ROWS
EOF
# The lease push arm reads the current branch, so its rows run on a feature
# branch in the throwaway repo.
git -C "$FWL_REPO" checkout -q feat/x
CL_FWL_ROWS='git push -uf --force-with-lease origin feat/x
git push -fv --force-with-lease
git push --force-with-lease --forc origin feat/x
git push --force-with-lease "--force" origin feat/x
git push --force-with-lease '"'"'-f'"'"' origin feat/x
git push --force-with-lease \-f origin feat/x
git push --force-with-lease origin "main"
git push --force-with-lease origin '"'"'HEAD:main'"'"'
git push --force-with-lease origin *
git push --force-with-lease origin ""*
git push --force-with-lease origin -- *
git push --force-with-lease origin +*
git push --force-with-lease origin HEAD:*
git push --force-with-lease origin m?in'
while IFS= read -r CL_CMD; do
    assert "lease push cluster/abbrev/quoted force, quoted main or glob never ALLOW: $CL_CMD" PASS "$(decide_in "$FWL_REPO" "$(j_bash "$CL_CMD")")"
done <<EOF
$CL_FWL_ROWS
EOF
# Controls: plain reads, a real option that merely prefixes a denied one, a
# non-leading pathspec glob, and the literal lease push still ALLOW.
assert "git log -5 still ALLOW"            ALLOW "$(decide "$(j_bash 'git log -5')")"
assert "git status still ALLOW"            ALLOW "$(decide "$(j_bash 'git status')")"
assert "gh pr view 1 still ALLOW"          ALLOW "$(decide "$(j_bash 'gh pr view 1')")"
assert "git diff --text still ALLOW"       ALLOW "$(decide "$(j_bash 'git diff --text HEAD')")"
assert "git diff -- dir glob still ALLOW"  ALLOW "$(decide "$(j_bash 'git diff -- scripts/*.sh')")"
assert "git log quoted grep still ALLOW"   ALLOW "$(decide "$(j_bash 'git log --grep="a b" -3')")"
assert "gh pr checks --watch still ALLOW"  ALLOW "$(decide "$(j_bash 'gh pr checks 1 --watch')")"
assert "xxd -ps still ALLOW"               ALLOW "$(decide "$(j_bash 'xxd -ps in')")"
assert "lease push literal still ALLOW"    ALLOW "$(decide_in "$FWL_REPO" "$(j_bash 'git push --force-with-lease origin feat/x')")"

# --- HIMMEL-3907: a value-taking option before the git subcommand / gh verb
# shifts which word the tool reads as the subcommand. Fail closed: only known
# value-less git globals are skipped; any dash word before the gh verb falls
# through. Rows are decision checks only; nothing here runs the command.
assert "git --attr-source sep value falls through"   PASS  "$(decide "$(j_bash 'git --attr-source log branch -D foo')")"
assert "git --attr-source= joined falls through"     PASS  "$(decide "$(j_bash 'git --attr-source=HEAD log -1')")"
assert "git unknown global falls through"            PASS  "$(decide "$(j_bash 'git --list-cmds log -1')")"
assert "lease push unknown-value global falls through" PASS "$(decide_in "$FWL_REPO" "$(j_bash 'git --attr-source push --force-with-lease origin feat/x')")"
assert "gh pr -R value shifts verb falls through"    PASS  "$(decide "$(j_bash 'gh pr -R view merge 1')")"
assert "gh pr --repo value shifts verb falls through" PASS "$(decide "$(j_bash 'gh pr --repo view merge 1')")"
assert "gh flag before group falls through"          PASS  "$(decide "$(j_bash 'gh -R pr view merge 1')")"
assert "gh --hostname before group falls through"    PASS  "$(decide "$(j_bash 'gh --hostname h pr view 1')")"
assert "git --no-pager log still ALLOW"              ALLOW "$(decide "$(j_bash 'git --no-pager log -1')")"
assert "git --git-dir x log still ALLOW"             ALLOW "$(decide "$(j_bash 'git --git-dir x log')")"
assert "git --no-advice -P status still ALLOW"       ALLOW "$(decide "$(j_bash 'git --no-advice -P status')")"
assert "gh pr view 1 -R o/r still ALLOW"             ALLOW "$(decide "$(j_bash 'gh pr view 1 -R o/r')")"
assert "gh pr list --repo o/r still ALLOW"           ALLOW "$(decide "$(j_bash 'gh pr list --repo o/r')")"
assert "lease push --no-pager still ALLOW"           ALLOW "$(decide_in "$FWL_REPO" "$(j_bash 'git --no-pager push --force-with-lease origin feat/x')")"

# --- HIMMEL-3668: `uniq in out` writes OUTPUT; `rg --pre` / `-z` / `ag --pager`
# run a program. Fall through on those; plain reads keep auto-approving.
assert "uniq in out falls through"            PASS  "$(decide "$(j_bash 'uniq in out')")"
assert "uniq -c in out falls through"         PASS  "$(decide "$(j_bash 'uniq -c in out')")"
assert "uniq -f 1 in out falls through"       PASS  "$(decide "$(j_bash 'uniq -f 1 in out')")"
assert "uniq --skip-fields 1 in out falls through" PASS "$(decide "$(j_bash 'uniq --skip-fields 1 in out')")"
assert "uniq -- in out falls through"         PASS  "$(decide "$(j_bash 'uniq -- in out')")"
assert "uniq f + glob falls through"          PASS  "$(decide "$(j_bash 'uniq in o*')")"
assert "uniq quoted >out operand falls through" PASS "$(decide "$(j_bash "uniq in '>out'")")"
assert "uniq mid-quoted 1'>'out operand falls through" PASS "$(decide "$(j_bash "uniq in 1'>'out")")"
assert "uniq escaped \\>out operand falls through" PASS "$(decide "$(j_bash 'uniq in \>out')")"
assert "uniq f ALLOW"                     ALLOW "$(decide "$(j_bash 'uniq f')")"
assert "uniq -c f ALLOW"                      ALLOW "$(decide "$(j_bash 'uniq -c f')")"
assert "uniq -f 1 f ALLOW"                    ALLOW "$(decide "$(j_bash 'uniq -f 1 f')")"
assert "uniq -f1 f ALLOW"                     ALLOW "$(decide "$(j_bash 'uniq -f1 f')")"
assert "uniq --skip-fields=1 f ALLOW"         ALLOW "$(decide "$(j_bash 'uniq --skip-fields=1 f')")"
assert "uniq f 2>/dev/null ALLOW"             ALLOW "$(decide "$(j_bash 'uniq f 2>/dev/null')")"
assert "uniq in 9x<in2 (digit-led name) falls through" PASS "$(decide "$(j_bash 'uniq in 9x<in2')")"
assert "uniq in 1a>/dev/null falls through"  PASS "$(decide "$(j_bash 'uniq in 1a>/dev/null')")"
assert "uniq 9x<in2 (one input operand) ALLOW" ALLOW "$(decide "$(j_bash 'uniq 9x<in2')")"
assert "xxd in 9x<in2 falls through"         PASS "$(decide "$(j_bash 'xxd in 9x<in2')")"
assert "uniq in 2>&1 ALLOW"                  ALLOW "$(decide "$(j_bash 'uniq in 2>&1')")"
assert "sort | uniq -c ALLOW"                 ALLOW "$(decide "$(j_bash 'sort f | uniq -c')")"
assert "rg --pre=sh falls through"            PASS  "$(decide "$(j_bash 'rg --pre=sh pat dir')")"
assert "rg --pre sh falls through"            PASS  "$(decide "$(j_bash 'rg --pre sh pat dir')")"
assert "rg --pre-glob falls through"          PASS  "$(decide "$(j_bash 'rg --pre-glob=x pat dir')")"
assert "rg --pr abbrev falls through"         PASS  "$(decide "$(j_bash 'rg --pr=sh pat dir')")"
assert "rg --hostname-bin falls through"      PASS  "$(decide "$(j_bash 'rg --hostname-bin=sh pat')")"
assert "rg --h abbrev falls through"          PASS  "$(decide "$(j_bash 'rg --h=sh pat')")"
assert "rg -z falls through"                  PASS  "$(decide "$(j_bash 'rg -z pat dir')")"
assert "rg -nz cluster falls through"         PASS  "$(decide "$(j_bash 'rg -nz pat dir')")"
assert "rg --search-zip falls through"        PASS  "$(decide "$(j_bash 'rg --search-zip pat dir')")"
assert "ripgrep --pre falls through"          PASS  "$(decide "$(j_bash 'ripgrep --pre=sh pat dir')")"
assert "ag --pager falls through"             PASS  "$(decide "$(j_bash 'ag --pager=sh pat')")"
assert "rg --pre glob falls through"          PASS  "$(decide "$(j_bash 'rg --pr* pat')")"
assert "rg pattern ALLOW"                     ALLOW "$(decide "$(j_bash 'rg pattern')")"
assert "rg -n pat dir ALLOW"                  ALLOW "$(decide "$(j_bash 'rg -n pat dir')")"
assert "rg -i --hidden pat ALLOW"             ALLOW "$(decide "$(j_bash 'rg -i --hidden pat')")"
assert "grep -r x . ALLOW"                    ALLOW "$(decide "$(j_bash 'grep -r x .')")"
assert "ag pat ALLOW"                         ALLOW "$(decide "$(j_bash 'ag pat')")"

# HIMMEL-4752 (judge j2011 on HIMMEL-4678): U+2028 (LINE SEPARATOR) is not
# whitespace to bash, so a command holding it gets NO opinion, never an allow.
# A bare U+2028 was allowed on base and head (harmless: bash reports command
# not found), but an auto-approver abstains when it cannot read the words the
# way the shell does.
# CORPUS NOTE (HIMMEL-4678, PR 2011 claimed "0 auto-approve changes"): that
# holds for the station corpus, not for adversarial Unicode-whitespace input.
# There the rewritten tokenizer differs from the old one on Unicode spaces
# only, and the new reading is closer to bash's (bash splits words on space,
# tab and newline alone). Acceptable: no such command widens an allow; U+2028
# is abstained (below) and the rest are classified by their literal bytes.
LS=$'\xe2\x80\xa8'
assert "bare U+2028 never ALLOW"              PASS  "$(decide "$(j_bash "$LS")")"
assert "ls with U+2028 argument never ALLOW"  PASS  "$(decide "$(j_bash "ls${LS}-l")")"
assert "plain ls -l still ALLOW"              ALLOW "$(decide "$(j_bash 'ls -l')")"

# HIMMEL-4967 (judge j2148 on HIMMEL-4752): the abstain cases (U+2028, FF, VT)
# used to exit before the HIMMEL-2121 root-walk DENY, downgrading a deny to no
# opinion. The deny runs first now; the abstain still holds for everything else.
FF=$'\f'
VT=$'\v'
assert "find / U+2028 DENY"                   DENY  "$(decide "$(j_bash "find / -name x${LS}")")"
assert "find / FF DENY"                       DENY  "$(decide "$(j_bash "find / -name x${FF}")")"
assert "find / VT DENY"                       DENY  "$(decide "$(j_bash "find / -name x${VT}")")"
assert "find / U+2028 bypass still PASS"      PASS  "$(FIND_ROOTWALK_OK=1 decide "$(j_bash "find / -name x${LS}")")"
assert "find / maxdepth U+2028 PASS"          PASS  "$(decide "$(j_bash "find / -maxdepth 2 -name x${LS}")")"
# HIMMEL-5034 (judge j2194 on HIMMEL-4967): bash splits words on space, tab and
# newline only, so a FF/VT/U+2028 inside the keyword or in place of the space
# makes ONE word (command not found), never a root walk. No DENY for these.
TB=$'\t'
assert "FF before find / is one word PASS"     PASS  "$(decide "$(j_bash "${FF}find / -name x")")"
assert "find FF / is one word PASS"            PASS  "$(decide "$(j_bash "find${FF}/ -name x")")"
assert "VT before find / is one word PASS"     PASS  "$(decide "$(j_bash "${VT}find / -name x")")"
assert "find VT / is one word PASS"            PASS  "$(decide "$(j_bash "find${VT}/ -name x")")"
assert "U+2028 before find / is one word PASS" PASS  "$(decide "$(j_bash "${LS}find / -name x")")"
assert "find U+2028 / is one word PASS"        PASS  "$(decide "$(j_bash "find${LS}/ -name x")")"
assert "for-loop FF find / is one word PASS"   PASS  "$(decide "$(j_bash "for f in a; do ${FF}find / -name x; done")")"
assert "tab-separated find / still DENY"       DENY  "$(decide "$(j_bash "find${TB}/ -name x")")"
# Judge j2231a on HIMMEL-5034: the queue-lock and all-segments-safe ltrims must
# agree with the root-walk one. A POSIX [[:space:]] ltrim strips U+2029/U+2002/
# U+3000 in a UTF-8 locale, so a led `find /` went DENY to ALLOW. Never ALLOW.
PS=$'\xe2\x80\xa9'
EN=$'\xe2\x80\x82'
ID=$'\xe3\x80\x80'
assert "U+2029 before find / never ALLOW"      PASS  "$(decide "$(j_bash "${PS}find / -name x")")"
assert "U+2002 before find / never ALLOW"      PASS  "$(decide "$(j_bash "${EN}find / -name x")")"
assert "U+3000 before find / never ALLOW"      PASS  "$(decide "$(j_bash "${ID}find / -name x")")"
assert "true; U+2029 find / never ALLOW"       PASS  "$(decide "$(j_bash "true; ${PS}find / -name x")")"
assert "impacted-suites literal FF never ALLOW" PASS "$(decide "$(j_bash "bash scripts/cr/impacted-suites.sh${FF}")")"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "All cases passed."
    exit 0
else
    echo "$FAILED case(s) failed."
    exit 1
fi
