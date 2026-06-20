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

# --- BYPASS case (expect rc=0 with READ_SECRETS_OK=1) ---
assert_rc "Bypass cat .env"                0 "$(run_case "$(j_bash 'cat .env')" "READ_SECRETS_OK=1")"
assert_rc "Bypass Read .env"               0 "$(run_case "$(j_read '/proj/.env')" "READ_SECRETS_OK=1")"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "All cases passed."
    exit 0
else
    echo "$FAILED case(s) failed."
    exit 1
fi
