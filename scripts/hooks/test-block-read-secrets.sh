#!/usr/bin/env bash
# Smoke test for scripts/hooks/block-read-secrets.sh.
#
# Usage: bash scripts/hooks/test-block-read-secrets.sh
#
# Exit codes:
#   0 — all cases passed
#   1 — at least one case failed
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/block-read-secrets.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK"

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
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

j_bash()  { printf '{"tool_name":"Bash","tool_input":{"command":%s}}'  "$(printf '%s' "$1" | jq -Rs .)"; }
j_pwsh()  { printf '{"tool_name":"PowerShell","tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }
j_read()  { printf '{"tool_name":"Read","tool_input":{"file_path":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }
j_grep()  { printf '{"tool_name":"Grep","tool_input":{"path":%s}}'      "$(printf '%s' "$1" | jq -Rs .)"; }

# --- BLOCK cases (expect rc=2) ---
assert_rc "Bash cat .env"                  2 "$(run_case "$(j_bash 'cat .env')")"
assert_rc "Bash cat /abs/path/.env"        2 "$(run_case "$(j_bash 'cat /home/user/proj/.env')")"
assert_rc "Bash grep TOKEN .env"           2 "$(run_case "$(j_bash 'grep TOKEN .env')")"
assert_rc "Bash cat .env.local"            2 "$(run_case "$(j_bash 'cat .env.local')")"
assert_rc "Bash head -1 .envrc"            2 "$(run_case "$(j_bash 'head -1 .envrc')")"
assert_rc "Bash cat id_rsa"                2 "$(run_case "$(j_bash 'cat ~/.ssh/id_rsa')")"
assert_rc "Bash cat key.pem"               2 "$(run_case "$(j_bash 'cat key.pem')")"
assert_rc "Bash jq . credentials.json"     2 "$(run_case "$(j_bash 'jq . credentials.json')")"
assert_rc "Bash redirect <.env"            2 "$(run_case "$(j_bash 'while read l; do :; done <.env')")"
assert_rc "Bash piped cat .env | grep"     2 "$(run_case "$(j_bash 'cat .env | grep FOO')")"
assert_rc "PowerShell Get-Content .env"    2 "$(run_case "$(j_pwsh 'Get-Content .env')")"
assert_rc "PowerShell type .env.local"     2 "$(run_case "$(j_pwsh 'type .env.local')")"
assert_rc "Read .env"                      2 "$(run_case "$(j_read '/home/user/.env')")"
assert_rc "Read .env.local"                2 "$(run_case "$(j_read '/proj/.env.local')")"
assert_rc "Read secrets.yaml"              2 "$(run_case "$(j_read '/etc/secrets.yaml')")"
assert_rc "Grep path=.env"                 2 "$(run_case "$(j_grep '.env')")"

# --- ALLOW cases (expect rc=0) ---
assert_rc "Bash ls .env"                   0 "$(run_case "$(j_bash 'ls -la .env')")"
assert_rc "Bash echo > .env (write only)"  0 "$(run_case "$(j_bash 'echo X=1 > .env')")"
assert_rc "Bash mv .env .env.bak"          0 "$(run_case "$(j_bash 'mv .env .env.bak')")"
assert_rc "Bash cat README.md"             0 "$(run_case "$(j_bash 'cat README.md')")"
assert_rc "Bash git log .env"              0 "$(run_case "$(j_bash 'git log -- .env')")"
assert_rc "Bash source .env"               0 "$(run_case "$(j_bash 'source .env')")"
# Reader list (post-CR re-review): interactive editors NEVER block,
# sed/awk block by default (they print to stdout), in-place forms of
# sed/awk are carved out.
assert_rc "Bash vim .env (interactive)"    0 "$(run_case "$(j_bash 'vim .env')")"
assert_rc "Bash nano .env (interactive)"   0 "$(run_case "$(j_bash 'nano .env')")"
assert_rc "Bash view .env (read-only vim)" 0 "$(run_case "$(j_bash 'view .env')")"

# sed/awk WITHOUT -i: print to stdout → BLOCK.
assert_rc "Bash sed s/X/Y/ .env"           2 "$(run_case "$(j_bash 'sed s/X/Y/ .env')")"
assert_rc "Bash awk {print} .env"          2 "$(run_case "$(j_bash 'awk {print} .env')")"
assert_rc "Bash gawk 1 .env"               2 "$(run_case "$(j_bash 'gawk 1 .env')")"

# sed/awk WITH in-place: ALLOW (rewrites without leaking content).
assert_rc "Bash sed -i in .env (rewrite)"  0 "$(run_case "$(j_bash 'sed -i s/X/Y/ .env')")"
assert_rc "Bash sed -i.bak .env"           0 "$(run_case "$(j_bash 'sed -i.bak s/X/Y/ .env')")"
assert_rc "Bash sed --in-place .env"       0 "$(run_case "$(j_bash 'sed --in-place s/X/Y/ .env')")"
assert_rc "Bash awk -i inplace .env"       0 "$(run_case "$(j_bash 'awk -i inplace 1 .env')")"
assert_rc "Bash awk --in-place .env"       0 "$(run_case "$(j_bash 'awk --in-place 1 .env')")"
# Non-secret env templates: committed scrubbed placeholders → ALLOW reading them.
assert_rc "Bash cat .env.example"          0 "$(run_case "$(j_bash 'cat .env.example')")"
assert_rc "Bash cat .env.sample"           0 "$(run_case "$(j_bash 'cat .env.sample')")"
assert_rc "Bash grep FOO .env.template"    0 "$(run_case "$(j_bash 'grep FOO .env.template')")"
assert_rc "Read .env.example"              0 "$(run_case "$(j_read '/proj/.env.example')")"
assert_rc "Grep path=.env.dist"            0 "$(run_case "$(j_grep '.env.dist')")"
# …but a real value file that merely starts like a template name is still a secret.
assert_rc "Bash cat .env.example.local"    2 "$(run_case "$(j_bash 'cat .env.example.local')")"
assert_rc "Read README.md"                 0 "$(run_case "$(j_read '/proj/README.md')")"
assert_rc "Grep path=src"                  0 "$(run_case "$(j_grep 'src/')")"
assert_rc "Unknown tool passthrough"       0 "$(run_case '{"tool_name":"WebFetch","tool_input":{"url":".env"}}')"
assert_rc "Empty input passthrough"        0 "$(run_case '{}')"

# --- HIMMEL-436: clause-aware, command-position matcher ---
# Inline interpreter bodies must NOT trip when a BARE reader-named identifier
# (head/file) coexists with a secret-glob token (cfg.key) in the body. The
# bare reader token is what makes these orig=BLOCK / new=ALLOW — i.e. they
# actually exercise the global-OR bug (an assignment form like `head=1` would
# already pass on the old hook and guard nothing).
assert_rc "Bash node -e bare head+cfg.key"   0 "$(run_case "$(j_bash 'node -e "const x = head; const k = cfg.key;"')")"
assert_rc "Bash python -c bare file+cfg.key" 0 "$(run_case "$(j_bash 'python -c "t = file; k = cfg.key"')")"
# Multi-clause: a reader in one clause + a secret-looking token in another
# (different command) must NOT cross-trip (the old global-OR bug).
assert_rc "Bash cat README.md; node cert.key" 0 "$(run_case "$(j_bash 'cat README.md; node x.js cert.key')")"
# Wrapper-skip: the reader is the real command behind a common wrapper.
assert_rc "Bash sudo cat .env"               2 "$(run_case "$(j_bash 'sudo cat .env')")"
assert_rc "Bash xargs cat .env"              2 "$(run_case "$(j_bash 'xargs cat .env')")"
assert_rc "Bash time cat .env"               2 "$(run_case "$(j_bash 'time cat .env')")"
assert_rc "Bash nice cat .env"               2 "$(run_case "$(j_bash 'nice cat .env')")"
# In-place carve-out is per-clause: a global `sed -i` must not mask a
# separate `cat .env` clause (today's global carve-out wrongly ALLOWs this).
assert_rc "Bash sed -i foo; cat .env"        2 "$(run_case "$(j_bash 'sed -i s/a/b/ foo.txt; cat .env')")"

# --- HIMMEL-440: recurse into bash -c / sh -c bodies ---
# An interpreter `-c '<reader> <secret>'` body IS shell, so re-running the
# matcher on it is correct (unlike node -e / python -c non-shell bodies, which
# is why HIMMEL-436 must NOT re-open). New BLOCK: the secret-read is the
# first/only statement of the -c body.
assert_rc "Bash bash -c 'cat .env'"          2 "$(run_case "$(j_bash "bash -c 'cat .env'")")"
assert_rc "Bash sh -c \"cat .env\""          2 "$(run_case "$(j_bash 'sh -c "cat .env"')")"
assert_rc "Bash bash -lc 'cat .env'"         2 "$(run_case "$(j_bash "bash -lc 'cat .env'")")"
assert_rc "Bash env bash -c 'cat .env'"      2 "$(run_case "$(j_bash "env bash -c 'cat .env'")")"
assert_rc "Bash zsh -c 'grep X .env'"        2 "$(run_case "$(j_bash "zsh -c 'grep X .env'")")"
# Regression (already green via the <-redirect path, must stay green).
assert_rc "Bash bash -c 'read x <.env'"      2 "$(run_case "$(j_bash "bash -c 'read x <.env'")")"
# PRESERVED ALLOW: -c body with no secret-read, and no -c at all.
assert_rc "Bash bash -c 'echo hi'"           0 "$(run_case "$(j_bash "bash -c 'echo hi'")")"
assert_rc "Bash sh -c 'ls -la'"              0 "$(run_case "$(j_bash "sh -c 'ls -la'")")"
assert_rc "Bash bash run.sh (no -c)"         0 "$(run_case "$(j_bash 'bash run.sh')")"
assert_rc "Bash bash script.sh .env (no -c)" 0 "$(run_case "$(j_bash 'bash script.sh .env')")"
# More interpreters + flag-shape coverage of the -c hunt state machine.
assert_rc "Bash dash -c 'cat .env'"          2 "$(run_case "$(j_bash "dash -c 'cat .env'")")"
assert_rc "Bash bash -x -c 'cat .env'"       2 "$(run_case "$(j_bash "bash -x -c 'cat .env'")")"
assert_rc "Bash bash --norc -c 'cat .env'"   2 "$(run_case "$(j_bash "bash --norc -c 'cat .env'")")"
# Multi-statement body blocks via the LATER clause (design's load-bearing claim).
assert_rc "Bash bash -c 'echo hi; cat .env'" 2 "$(run_case "$(j_bash "bash -c 'echo hi; cat .env'")")"
# In-place carve-out propagates into the -c body (recursive twin of sed -i).
assert_rc "Bash bash -c 'sed -i s/a/b/ .env'" 0 "$(run_case "$(j_bash "bash -c 'sed -i s/a/b/ .env'")")"
# No FP on a trailing positional ($0) after a quoted body that reads a NON-secret
# (the body reads config.json; .env is the unused $0, never read) — body-quote
# boundary tracking stops the recursed-arg scan at the body's closing quote.
assert_rc "Bash bash -c 'cat config.json' .env" 0 "$(run_case "$(j_bash "bash -c 'cat config.json' .env")")"

# --- HIMMEL-879: case-varied secret basenames must still block ---
# Windows/macOS filesystems are case-insensitive; is_secret_path/
# is_secret_basename must fold case BEFORE matching so a case-varied read
# (.ENV, ID_RSA, SECRETS.YAML, a mixed-case .pem) doesn't bypass the guard.
assert_rc "Bash cat .ENV (uppercase)"          2 "$(run_case "$(j_bash 'cat .ENV')")"
assert_rc "Bash cat ID_RSA (uppercase)"        2 "$(run_case "$(j_bash 'cat ~/.ssh/ID_RSA')")"
assert_rc "Bash cat SECRETS.YAML (uppercase)"  2 "$(run_case "$(j_bash 'cat SECRETS.YAML')")"
assert_rc "Bash cat KEY.PEM (uppercase ext)"   2 "$(run_case "$(j_bash 'cat KEY.PEM')")"
assert_rc "Read .ENV (uppercase)"              2 "$(run_case "$(j_read '/home/user/.ENV')")"
assert_rc "Grep path=ID_ED25519 (uppercase)"   2 "$(run_case "$(j_grep 'ID_ED25519')")"
assert_rc "PowerShell Get-Content .ENV"        2 "$(run_case "$(j_pwsh 'Get-Content .ENV')")"
# Template carve-out is also case-folded: an uppercase committed placeholder
# still reads as allowed, not as a secret.
assert_rc "Bash cat .ENV.EXAMPLE (uppercase)"  0 "$(run_case "$(j_bash 'cat .ENV.EXAMPLE')")"

# --- HIMMEL-879: trailing-space/dot normalization bypass (Windows) ---
# Win32 CreateFile / Node fs strip trailing spaces and dots from path
# components, so "/repo/.env " opens the SAME file as /repo/.env — the
# predicate must mirror that or the literal match lets it through.
assert_rc "Read .env<space> (trailing space)"  2 "$(run_case "$(j_read '/repo/.env ')")"
assert_rc "Grep path=.env. (trailing dot)"     2 "$(run_case "$(j_grep '/repo/.env.')")"

# Quote + uppercase through the real Bash clause tokenizer: the quote strip
# and the case fold must compose (`'.ENV'` -> `.ENV` -> `.env`).
assert_rc "Bash cat '.ENV' (quoted uppercase)" 2 "$(run_case "$(j_bash "cat '.ENV'")")"

# --- HIMMEL-879: native Windows backslash paths ---
# Read/Grep/PowerShell tool inputs carry backslash paths on Windows; the
# predicate must treat `\` as a path separator too, or `C:\repo\.ENV`
# lowercases to one giant non-matching "basename" and slips through.
assert_rc "Read C:\\repo\\.ENV (backslash path)" 2 \
    "$(run_case "$(j_read 'C:\repo\.ENV')")"
assert_rc "PowerShell Get-Content C:\\repo\\.ENV" 2 \
    "$(run_case "$(j_pwsh 'Get-Content C:\repo\.ENV')")"

# --- Missing guardrails/lib.sh fails CLOSED (mirrors test-block-edit-on-main
# T19). An unguarded source under set -e exits rc=1, which PreToolUse does NOT
# block on — fail OPEN. The guard must fail CLOSED (rc=2 + recognisable
# message), even on a payload it would otherwise block anyway.
GUARDRAILLESS=$(mktemp -d)
mkdir -p "$GUARDRAILLESS/hooks"
cp "$HOOK" "$GUARDRAILLESS/hooks/"
err=$(printf '%s' "$(j_bash 'cat .env')" | bash "$GUARDRAILLESS/hooks/block-read-secrets.sh" 2>&1 >/dev/null); rc=$?
assert_rc "Missing guardrails lib fails closed" 2 "$rc"
case "$err" in
    *"cannot source guardrails/lib.sh"*) echo "PASS missing-lib refusal message" ;;
    *) echo "FAIL missing-lib refusal message — got: $err"; FAILED=$((FAILED + 1)) ;;
esac
rm -rf "$GUARDRAILLESS" 2>/dev/null || true

# --- BYPASS case (expect rc=0 with READ_SECRETS_OK=1) ---
assert_rc "Bypass cat .env"                0 "$(run_case "$(j_bash 'cat .env')" "READ_SECRETS_OK=1")"
assert_rc "Bypass Read .env"               0 "$(run_case "$(j_read '/proj/.env')" "READ_SECRETS_OK=1")"

# --- Direct tests of the shared predicate (scripts/guardrails/lib.sh) ---
# Exercises is_secret_basename in isolation, independent of either hook's
# tool-dispatch/tokenizer plumbing above.
LIB_DIR="$(cd "$(dirname "$0")/../guardrails" && pwd)"
# shellcheck source=../guardrails/lib.sh
# shellcheck disable=SC1091
. "$LIB_DIR/lib.sh"

assert_predicate() {
    local label="$1" expected="$2" arg="$3"
    local actual=0
    is_secret_basename "$arg" || actual=$?
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

assert_predicate "is_secret_basename .env"                    0 ".env"
assert_predicate "is_secret_basename .ENV (uppercase)"        0 ".ENV"
assert_predicate "is_secret_basename /abs/path/.env"          0 "/abs/path/.env"
assert_predicate "is_secret_basename id_rsa"                  0 "id_rsa"
assert_predicate "is_secret_basename ID_RSA (uppercase)"      0 "ID_RSA"
assert_predicate "is_secret_basename SECRETS.YAML (uppercase)" 0 "SECRETS.YAML"
assert_predicate "is_secret_basename secrets.yml"              0 "secrets.yml"
assert_predicate "is_secret_basename KEY.PEM (uppercase ext)" 0 "KEY.PEM"
assert_predicate "is_secret_basename foo.p12"                 0 "foo.p12"
assert_predicate "is_secret_basename quoted '.env'"            0 "'.env'"
assert_predicate "is_secret_basename .env.example (template)" 1 ".env.example"
assert_predicate "is_secret_basename .ENV.EXAMPLE (uppercase template)" 1 ".ENV.EXAMPLE"
assert_predicate "is_secret_basename README.md (non-secret)"  1 "README.md"
assert_predicate "is_secret_basename src/README.md"           1 "src/README.md"
# Trailing-space/dot normalization (Windows strips them; the predicate must too).
assert_predicate "is_secret_basename '.env ' (trailing space)"     0 ".env "
assert_predicate "is_secret_basename '.env  ' (two trailing spaces)" 0 ".env  "
assert_predicate "is_secret_basename '.ENV ' (uppercase + space)"  0 ".ENV "
assert_predicate "is_secret_basename '.env.' (trailing dot)"       0 ".env."
assert_predicate "is_secret_basename '.env. ' (dot + space)"       0 ".env. "
# After stripping, a trailing-space template equals the carve-out — stays
# ALLOWED, consistent with what the OS actually opens (.env.example).
assert_predicate "is_secret_basename '.env.example ' (template + space)" 1 ".env.example "
# Native Windows backslash paths (backslash is a path separator there).
assert_predicate "is_secret_basename 'C:\\repo\\.ENV' (backslash + case)"  0 'C:\repo\.ENV'
assert_predicate "is_secret_basename 'C:\\Users\\x\\.ssh\\ID_RSA'"          0 'C:\Users\x\.ssh\ID_RSA'
assert_predicate "is_secret_basename '\\\\server\\share\\.env' (UNC)"       0 '\\server\share\.env'
assert_predicate "is_secret_basename 'C:\\repo\\.env ' (backslash + space)" 0 'C:\repo\.env '
assert_predicate "is_secret_basename 'C:\\repo\\.env.example' (template)"   1 'C:\repo\.env.example'

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "All cases passed."
    exit 0
else
    echo "$FAILED case(s) failed."
    exit 1
fi
