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

# --- EMPTY/BLANK stdin (expect rc=2, fail closed) -- HIMMEL-2123 RETASK
# R2123A (CodeRabbit App, PR #1912): this is a secrets FENCE
# (scripts/hooks/CLAUDE.md fail-direction table), but `jq <<<""` on blank
# stdin emitted zero values with zero errors, so every field came back
# empty and the case statement's `*) exit 0` default silently ALLOWED --
# same shape already fixed in block-destructive-commands.sh/
# block-git-stash.sh.
assert_rc "empty stdin"           2 "$(run_case '')"
assert_rc "whitespace-only stdin" 2 "$(run_case '   ')"

# --- BYPASS case (expect rc=0 with READ_SECRETS_OK=1) ---
assert_rc "Bypass cat .env"                0 "$(run_case "$(j_bash 'cat .env')" "READ_SECRETS_OK=1")"
assert_rc "Bypass Read .env"               0 "$(run_case "$(j_read '/proj/.env')" "READ_SECRETS_OK=1")"

# --- NON-STRING sibling field (expect rc=2, fail closed) -- HIMMEL-2123
# RETASK R2123A: the combined tool_name/file_path/path/command extraction
# runs ONE jq call whose `+` is type-strict, so a non-string SIBLING field
# present alongside the real one (a numeric `path` next to `file_path`, or a
# non-string `command` next to a genuine one) threw a type error the whole
# call's `|| true` swallowed, blanking every field -- including the one this
# case actually cares about -- and silently disabling the guard for that
# call. `|tostring` on every operand closes it.
assert_rc "Read .env + numeric sibling path" 2 "$(run_case '{"tool_name":"Read","tool_input":{"file_path":"/home/user/.env","path":42}}')"
assert_rc "Bash cat .env + array sibling command" 2 "$(run_case '{"tool_name":"Bash","tool_input":{"command":"cat .env","file_path":["x"]}}')"

# --- Embedded newline in file_path/path (expect rc=2) -- HIMMEL-2123
# RETASK R2123A: the field separator between tool_name/file_path/path/command
# is a raw SOH byte, not "\n" -- a literal newline INSIDE file_path/path (a
# POSIX-legal, if rare, path component) used to truncate that field at the
# split, so is_secret_path never saw the real basename. SOH can't
# legitimately appear in a path, so the split stays exact regardless.
assert_rc "Read path with embedded newline"  2 "$(run_case '{"tool_name":"Read","tool_input":{"file_path":"/tmp/a\n/.env"}}')"

# --- SOH DELIMITER COLLISION (expect rc=2, fail closed) -- HIMMEL-2123
# RETASK R2123A (panel, codex-1): the field separator itself (SOH) is a
# real attack surface, not just a fix for Windows CRLF/embedded newlines --
# a model-influenced file_path/path CAN legally be a JSON string containing
# a literal SOH byte (spelled "\u0001" in valid JSON text; a RAW SOH byte
# is itself invalid JSON and jq's own parser rejects it first, which is
# also caught below, just via the generic parse-error branch). Embedding it
# desyncs the split -- "/tmp/<SOH>/.env" would parse as file_path="/tmp/"
# with ".env" shifted into `path` -- so it must fail CLOSED, deliberately
# overriding the "unparseable -> allow" shape this hook otherwise has for
# ordinary malformed JSON, because this is the fence's own threat model
# (deliberate evasion), not an infra hiccup.
assert_rc "Read file_path with escaped SOH (delimiter collision)" 2 "$(run_case '{"tool_name":"Read","tool_input":{"file_path":"/tmp/\u0001/.env"}}')"
assert_rc "Grep path with escaped SOH (delimiter collision)"      2 "$(run_case '{"tool_name":"Grep","tool_input":{"path":"/tmp/\u0001/.env"}}')"
# `command` is deliberately NOT guarded: it is read out as "everything
# after the third separator" and never split further, so an embedded SOH
# there cannot shift any OTHER field -- it becomes plain text inside $cmd,
# same as any other stray byte a shell command can legally contain. Confirm
# it splits safely rather than needing to fail closed: detection of an
# actual secret read earlier in the same command still fires normally.
assert_rc "Bash cat .env + trailing escaped SOH in command" 2 "$(run_case '{"tool_name":"Bash","tool_input":{"command":"cat .env \u0001"}}')"

# --- HIMMEL-2213: grep/sed/awk PATTERN argument is data, not a read target ---
# Final design (round 5, after 4 rounds of adversarial panel review each
# found a different way "the first non-flag/quoted argument is the pattern"
# broke): the exemption applies ONLY to a QUOTED token that is EITHER (a)
# immediately after the bare reader command with ZERO flags in between, OR
# (b) immediately after an -e/--regexp flag (whose value is unambiguously
# always a pattern, at any position). Every other flag before an otherwise-
# implicit pattern — -f/--file, -m/-A/-B/-C, ripgrep's --ignore-file, or
# any other tool-specific flag — is deliberately NOT special-cased: there is
# no bounded flag-arity table across every supported tool, so a flag in that
# position falls back to the ordinary (blocking) scan. See the hook's own
# header "Known limitations" for the full history and rationale.
assert_rc "Bash grep '.env' file.txt (pattern only, was FP-block)" 0 \
    "$(run_case "$(j_bash "grep '.env' file.txt")")"
assert_rc "Bash egrep '.env' file.txt" 0 "$(run_case "$(j_bash "egrep '.env' file.txt")")"
assert_rc "Bash rg '.env' src/" 0 "$(run_case "$(j_bash "rg '.env' src/")")"
assert_rc "Bash awk '.env' file.txt (pattern only)" 0 \
    "$(run_case "$(j_bash "awk '.env' file.txt")")"
# Any flag before the pattern — even one that takes no value at all, like
# -r/-n — puts the pattern at position 1, not 0, so it is NOT exempt and
# falls back to blocking. Deliberate scope limit (see header above).
assert_rc "Bash grep -rn '.env' scripts/ (flag before pattern, out of scope)" 2 \
    "$(run_case "$(j_bash "grep -rn '.env' scripts/")")"
# Positive control (must still BLOCK): the SAME pattern, but the target
# argument genuinely IS a secret file — proves the fix narrows only the
# pattern position, not secret-path detection on real targets.
assert_rc "Bash grep '.env' .env (pattern AND target both .env)" 2 \
    "$(run_case "$(j_bash "grep '.env' .env")")"
assert_rc "Bash awk '.env' .env (pattern AND target both .env)" 2 \
    "$(run_case "$(j_bash "awk '.env' .env")")"
# Still blocks: pattern is NOT secret-shaped, target genuinely is (unchanged
# pre-existing behaviour — same case as line ~45, pinned again here for
# contrast with the pattern-argument fix above).
assert_rc "Bash grep TOKEN .env (real target, still blocks)" 2 \
    "$(run_case "$(j_bash 'grep TOKEN .env')")"
# Round 5 (panel review, codex-1): an UNQUOTED implicit pattern must ALSO
# close the position-0 slot — otherwise a LATER quoted argument (the real
# target file) wrongly claims it as if it were the pattern.
assert_rc "Bash grep TOKEN '.env' (unquoted implicit pattern, '.env' is the real target)" 2 \
    "$(run_case "$(j_bash "grep TOKEN '.env'")")"
# Positive control: a bare unquoted pattern with no flags is out of the
# exemption's scope entirely (never quoted, so never exempt) — still blocks,
# same as before HIMMEL-2213.
assert_rc "Bash grep .env file.txt (bare unquoted pattern, out of exemption scope)" 2 \
    "$(run_case "$(j_bash "grep .env file.txt")")"
# The HIMMEL-440 recursion into `bash -c '<body>'` shares the same fix: a
# grep pattern inside a -c body must not false-positive either.
assert_rc "Bash bash -c \"grep '.env' file.txt\" (recursed pattern)" 0 \
    "$(run_case "$(j_bash "bash -c \"grep '.env' file.txt\"")")"
assert_rc "Bash bash -c \"grep TOKEN .env\" (recursed real target)" 2 \
    "$(run_case "$(j_bash "bash -c \"grep TOKEN .env\"")")"

# --- -f/--file: never at position 0 (some flag always precedes its value),
# so it needs no special case — the position rule alone blocks it.
assert_rc "Bash grep -f .env file.txt (grep -f reads .env as pattern SOURCE, real leak)" 2 \
    "$(run_case "$(j_bash "grep -f .env file.txt")")"
assert_rc "Bash sed -f .env file.txt (sed -f reads .env as script SOURCE, real leak)" 2 \
    "$(run_case "$(j_bash "sed -f .env file.txt")")"
assert_rc "Bash awk -f .env file.txt (awk -f reads .env as program SOURCE, real leak)" 2 \
    "$(run_case "$(j_bash "awk -f .env file.txt")")"
assert_rc "Bash grep --file .env file.txt (long-form -f)" 2 \
    "$(run_case "$(j_bash "grep --file .env file.txt")")"
# Positive control: -f with a NON-secret pattern file still allows.
assert_rc "Bash grep -f patterns.txt file.txt (non-secret -f file, allows)" 0 \
    "$(run_case "$(j_bash "grep -f patterns.txt file.txt")")"
# The recursed bash -c body shares the same behaviour.
assert_rc "Bash bash -c \"grep -f .env file.txt\" (recursed -f, real leak)" 2 \
    "$(run_case "$(j_bash "bash -c \"grep -f .env file.txt\"")")"

# --- ripgrep's --ignore-file: same "no special case needed" story as -f —
# never at position 0, so it always falls back to the ordinary scan,
# quoted or not.
assert_rc "Bash rg --ignore-file .env TOKEN src/ (unquoted flag value, real leak)" 2 \
    "$(run_case "$(j_bash "rg --ignore-file .env TOKEN src/")")"
assert_rc "Bash rg --ignore-file '.env' TOKEN src/ (quoted flag value, real leak)" 2 \
    "$(run_case "$(j_bash "rg --ignore-file '.env' TOKEN src/")")"

# --- Flags that take a separate value but are NOT -e/--regexp (-m, -A, ...):
# deliberately NOT exempt at any position — an unquoted flag value (a count,
# a string) would otherwise be indistinguishable from a genuine positional
# pattern without a per-tool arity table (see header). The pattern that
# follows is therefore no longer at position 0 either, so it now also
# blocks — a documented, accepted scope limit, not a regression target.
assert_rc "Bash grep -m 1 '.env' file.txt (flag before pattern, out of scope)" 2 \
    "$(run_case "$(j_bash "grep -m 1 '.env' file.txt")")"
assert_rc "Bash grep -A 3 '.env' file.txt (flag before pattern, out of scope)" 2 \
    "$(run_case "$(j_bash "grep -A 3 '.env' file.txt")")"

# --- -e/--regexp: the one exception. Its value is UNAMBIGUOUSLY always a
# pattern (never a file), at any position, so it is exempt regardless — but
# seeing it also means any subsequent argument is a real target, never an
# implicit pattern.
assert_rc "Bash grep -e TOKEN '.env' (explicit -e pattern, '.env' is the real target)" 2 \
    "$(run_case "$(j_bash "grep -e TOKEN '.env'")")"
assert_rc "Bash grep -e '.env' file.txt (the -e value itself is a pattern, allows)" 0 \
    "$(run_case "$(j_bash "grep -e '.env' file.txt")")"
assert_rc "Bash grep --regexp TOKEN '.env' (long-form -e)" 2 \
    "$(run_case "$(j_bash "grep --regexp TOKEN '.env'")")"
# Multiple -e patterns: each -e's own value is exempt; a later unquoted
# operand still passes the ordinary (non-secret) scan.
assert_rc "Bash grep -e '.env' -e OTHER file.txt (multiple -e patterns)" 0 \
    "$(run_case "$(j_bash "grep -e '.env' -e OTHER file.txt")")"

# --- Round 6 (panel review): the -e/--regexp exemption MUST be gated on
# pattern_cmd — grep-family only. `-e` means something else entirely for
# other readers (GNU cat's -e = -vE, unrelated to a pattern), and an
# earlier cut applied the exemption unconditionally, false-ALLOWing a real
# read: `cat -e .env` genuinely displays .env's content.
assert_rc "Bash cat -e .env (cat's own -e is unrelated to grep's, must still block)" 2 \
    "$(run_case "$(j_bash "cat -e .env")")"
assert_rc "Bash cat -e file.txt (non-secret target, allows)" 0 \
    "$(run_case "$(j_bash "cat -e file.txt")")"
assert_rc "Bash bash -c \"cat -e .env\" (recursed, same gate)" 2 \
    "$(run_case "$(j_bash "bash -c \"cat -e .env\"")")"

# --- Round 7 (panel review): raw-text comparison against "prev" is
# spoofable — an -f/--file VALUE can be crafted to equal "--regexp" (or the
# command's own name), tricking a text-based check into treating it as a
# real flag occurrence. Position and "was this consumed as -f's value" are
# now tracked as explicit state, immune to what the consumed value's text
# happens to say.
assert_rc "Bash grep -f --regexp .env (--regexp is -f's VALUE, not a real flag; .env is the real target)" 2 \
    "$(run_case "$(j_bash "grep -f --regexp .env")")"
assert_rc "Bash grep -f grep '.env' (grep is -f's VALUE, not cmdtok; '.env' is the real target)" 2 \
    "$(run_case "$(j_bash "grep -f grep '.env'")")"
assert_rc "Bash bash -c \"grep -f --regexp .env\" (recursed, same fix)" 2 \
    "$(run_case "$(j_bash "bash -c \"grep -f --regexp .env\"")")"
# Positive control: the SAME shape with a non-secret final argument allows.
assert_rc "Bash grep -f --regexp file.txt (non-secret target, allows)" 0 \
    "$(run_case "$(j_bash "grep -f --regexp file.txt")")"

# --- HIMMEL-2228: glued option tokens (--opt=<value> / -f<value> / -Param:<value>) ---
# The tokenizer above only ever fed WHOLE tokens to is_secret_path. A GLUED
# option — the flag and its value in one shell word — matched no secret glob
# and was ALLOWED, even though the command genuinely opens and reads that
# value as a file. glued_opt_secret() now splits the token at its first
# '='/':'  (or past a bundled short 'f') and scans the value half,
# unconditionally, outside the HIMMEL-2213 exemption chain.

# BLOCK: the ticket's five repro shapes plus siblings.
assert_rc "Bash grep '--file=.env' TOKEN file.txt (quoted glued long opt)" 2 \
    "$(run_case "$(j_bash "grep '--file=.env' TOKEN file.txt")")"
assert_rc "Bash grep '-f.env' TOKEN file.txt (quoted glued short opt)" 2 \
    "$(run_case "$(j_bash "grep '-f.env' TOKEN file.txt")")"
assert_rc "Bash grep --file=.env TOKEN file.txt (unquoted glued long opt)" 2 \
    "$(run_case "$(j_bash "grep --file=.env TOKEN file.txt")")"
assert_rc "Bash grep -f.env TOKEN file.txt (unquoted glued short opt)" 2 \
    "$(run_case "$(j_bash "grep -f.env TOKEN file.txt")")"
assert_rc "Bash grep '--file=.env' (quoted-at-position-0, 2213 exemption must not cover a glued value)" 2 \
    "$(run_case "$(j_bash "grep '--file=.env'")")"
assert_rc "Bash sed --file=.env file.txt (sed glued long opt)" 2 \
    "$(run_case "$(j_bash "sed --file=.env file.txt")")"
assert_rc "Bash awk -f.env file.txt (awk glued short opt)" 2 \
    "$(run_case "$(j_bash "awk -f.env file.txt")")"
assert_rc "Bash grep -rf.env TOKEN src/ (bundled short glue)" 2 \
    "$(run_case "$(j_bash "grep -rf.env TOKEN src/")")"
assert_rc "Bash rg --ignore-file=.env TOKEN src/ (ripgrep glued long opt)" 2 \
    "$(run_case "$(j_bash "rg --ignore-file=.env TOKEN src/")")"

# Recursed bash -c / sh -c bodies (HIMMEL-440 twin): the glued scan applies
# inside the body too.
assert_rc "Bash bash -c \"grep --file=.env TOKEN file.txt\" (recursed glued long opt)" 2 \
    "$(run_case "$(j_bash "bash -c \"grep --file=.env TOKEN file.txt\"")")"
assert_rc "Bash bash -c \"grep -f.env TOKEN file.txt\" (recursed glued short opt)" 2 \
    "$(run_case "$(j_bash "bash -c \"grep -f.env TOKEN file.txt\"")")"
assert_rc "Bash sh -c 'grep --file=.env TOKEN file.txt' (recursed, sh)" 2 \
    "$(run_case "$(j_bash "sh -c 'grep --file=.env TOKEN file.txt'")")"

# PowerShell glue: -Param:<value>.
assert_rc "PowerShell Get-Content -Path:.env (glued colon)" 2 \
    "$(run_case "$(j_pwsh 'Get-Content -Path:.env')")"
assert_rc "PowerShell Select-String -Path:.env TOKEN (glued colon)" 2 \
    "$(run_case "$(j_pwsh 'Select-String -Path:.env TOKEN')")"

# ACCEPTED false positive, explicitly labelled: a glued -e/--regexp value is
# scanned unconditionally even though its separate-token form is exempt.
assert_rc "Bash grep --regexp=.env file.txt (ACCEPTED false positive: glued -e/--regexp value)" 2 \
    "$(run_case "$(j_bash "grep --regexp=.env file.txt")")"

# Positive control: the pre-existing space-separated form (grep -f .env
# file.txt, pinned above in the HIMMEL-2213/round-7 sections) already proves
# the must-still-block direction for the non-glued shape; these cases pin
# the NEW glued shape specifically.

# ALLOW: negative controls — benign glued options that must NOT start denying.
assert_rc "Bash grep --color=auto TOKEN file.txt (unquoted benign glued opt)" 0 \
    "$(run_case "$(j_bash "grep --color=auto TOKEN file.txt")")"
assert_rc "Bash grep '--color=auto' TOKEN file.txt (quoted benign glued opt)" 0 \
    "$(run_case "$(j_bash "grep '--color=auto' TOKEN file.txt")")"
assert_rc "Bash grep --file=patterns.txt TOKEN file.txt (glued long opt, non-secret value)" 0 \
    "$(run_case "$(j_bash "grep --file=patterns.txt TOKEN file.txt")")"
assert_rc "Bash grep -fpatterns.txt TOKEN file.txt (glued short opt, non-secret value)" 0 \
    "$(run_case "$(j_bash "grep -fpatterns.txt TOKEN file.txt")")"
assert_rc "Bash grep --file=.env.example TOKEN file.txt (template carve-out survives the split)" 0 \
    "$(run_case "$(j_bash "grep --file=.env.example TOKEN file.txt")")"
assert_rc "Bash grep --exclude=README.md -r TOKEN src/ (glued long opt, non-secret value)" 0 \
    "$(run_case "$(j_bash "grep --exclude=README.md -r TOKEN src/")")"
assert_rc "Bash grep -m1 TOKEN file.txt (glued short opt with numeric value, not -f)" 0 \
    "$(run_case "$(j_bash "grep -m1 TOKEN file.txt")")"
assert_rc "Bash git log --pretty=format:%h (colon inside a long option's value)" 0 \
    "$(run_case "$(j_bash "git log --pretty=format:%h")")"
assert_rc "Bash docker run -v /a:/b img (colon inside a value, non-reader command)" 0 \
    "$(run_case "$(j_bash "docker run -v /a:/b img")")"
assert_rc "PowerShell Get-Content -Path:README.md (glued colon, non-secret value)" 0 \
    "$(run_case "$(j_pwsh 'Get-Content -Path:README.md')")"
# IMPORTANT and subtle: here -f CONSUMES --file=.env as its literal filename
# (grep opens a file literally named "--file=.env", not the secret) — the
# round-7 armed-state ordering (expect_file_val) must still win over the new
# independent glued scan, so this stays rc=0.
assert_rc "Bash grep -f --file=.env (armed expect_file_val consumption wins over the glued scan)" 0 \
    "$(run_case "$(j_bash "grep -f --file=.env")")"

# More BLOCK: the documented in-place false positive, the corrected header
# claim about a short bundle whose earlier letter would really consume the
# value, a split value that still needs the basename strip, and the
# sole-argument short-glue form.
assert_rc "Bash sed --in-place=.env file.txt (documented in-place false positive)" 2 \
    "$(run_case "$(j_bash "sed --in-place=.env file.txt")")"
assert_rc "Bash grep -m1f.env TOKEN file.txt (short-glue split still fires past an earlier letter, over-blocks)" 2 \
    "$(run_case "$(j_bash "grep -m1f.env TOKEN file.txt")")"
assert_rc "Bash grep -fconf/.env TOKEN file.txt (split value still gets the basename strip)" 2 \
    "$(run_case "$(j_bash "grep -fconf/.env TOKEN file.txt")")"
assert_rc "Bash grep -f.env (sole-argument glued short form)" 2 \
    "$(run_case "$(j_bash "grep -f.env")")"

# More ALLOW: the -e half of the armed-state gate (only -f was pinned above),
# its recursed twin, and two non-reader commands carrying colon/-f shapes
# that must not start denying just because they look glued.
assert_rc "Bash grep -e --file=.env file.txt (armed expect_pattern_val wins over the glued scan)" 0 \
    "$(run_case "$(j_bash "grep -e --file=.env file.txt")")"
assert_rc "Bash bash -c \"grep -f --file=.env\" (recursed twin of the armed-state gate)" 0 \
    "$(run_case "$(j_bash "bash -c \"grep -f --file=.env\"")")"
assert_rc "Bash curl -H Authorization:Bearer x https://e.com (non-reader, colon shape)" 0 \
    "$(run_case "$(j_bash "curl -H Authorization:Bearer x https://e.com")")"
assert_rc "Bash ffmpeg -f mp4 -i in.mp4 out.mkv (non-reader, -f shape)" 0 \
    "$(run_case "$(j_bash "ffmpeg -f mp4 -i in.mp4 out.mkv")")"

# Denial TEXT, not just rc: the accepted-false-positive wording and the
# offending token must actually appear via glued_hint.
err=$(printf '%s' "$(j_bash 'grep --regexp=.env file.txt')" | bash "$HOOK" 2>&1 >/dev/null); rc=$?
assert_rc "Bash grep --regexp=.env file.txt (denied, glued hint shown)" 2 "$rc"
case "$err" in
    *"--regexp=.env"*"ACCEPTED false positive"*) echo "PASS glued hint names the token and the accepted false positive" ;;
    *) echo "FAIL glued hint text — got: $err"; FAILED=$((FAILED + 1)) ;;
esac
# Mirror: an ordinary (non-glued) denial must NOT show the glued hint.
err=$(printf '%s' "$(j_bash 'cat .env')" | bash "$HOOK" 2>&1 >/dev/null); rc=$?
assert_rc "Bash cat .env (denied, no glued hint)" 2 "$rc"
case "$err" in
    *"glues an option to its value"*) echo "FAIL cat .env denial wrongly shows glued hint"; FAILED=$((FAILED + 1)) ;;
    *) echo "PASS cat .env denial has no glued hint" ;;
esac

# --- HIMMEL-2213: pattern_hint on quoted pattern-family denials ---
# The quoted-pattern exemption is positional (see header): a flag before the
# pattern (`grep -rn '.env' scripts/`, blocked above) still denies. The agent
# has no way to know the two shapes that DO pass, so pattern_hint() names
# them on that denial. pattern_hint_applies() gates it to pattern-family
# commands (grep/egrep/fgrep/rg/ripgrep/ag/sed/awk/gawk/mawk/nawk) that also
# have a token which is BOTH quoted (is_quoted_pattern_tok) AND secret-looking
# (is_secret_path) — otherwise the hint is noise.
err=$(printf '%s' "$(j_bash "grep -rn '.env' scripts/")" | bash "$HOOK" 2>&1 >/dev/null); rc=$?
assert_rc "Bash grep -rn '.env' scripts/ (denied, pattern hint shown)" 2 "$rc"
case "$err" in
    *"pattern first, flags after it"*) echo "PASS pattern hint shown on quoted pattern-family denial" ;;
    *) echo "FAIL pattern hint shown on quoted pattern-family denial — got: $err"; FAILED=$((FAILED + 1)) ;;
esac

# Non-pattern-family denial (cat) must NOT show the hint — pins the noise gate.
err=$(printf '%s' "$(j_bash 'cat .env')" | bash "$HOOK" 2>&1 >/dev/null); rc=$?
assert_rc "Bash cat .env (denied, no pattern hint)" 2 "$rc"
case "$err" in
    *"pattern first, flags after it"*) echo "FAIL cat .env denial wrongly shows pattern hint"; FAILED=$((FAILED + 1)) ;;
    *) echo "PASS cat .env denial has no pattern hint" ;;
esac

# Pattern-family denial with NO quote at all must also NOT show the hint —
# pins the other half of pattern_hint_applies' gate (it requires a quoted,
# secret-looking token, not just a recognised command name).
err=$(printf '%s' "$(j_bash 'grep TOKEN .env')" | bash "$HOOK" 2>&1 >/dev/null); rc=$?
assert_rc "Bash grep TOKEN .env (denied, unquoted, no pattern hint)" 2 "$rc"
case "$err" in
    *"pattern first, flags after it"*) echo "FAIL grep TOKEN .env (unquoted) wrongly shows pattern hint"; FAILED=$((FAILED + 1)) ;;
    *) echo "PASS grep TOKEN .env (unquoted) has no pattern hint" ;;
esac

# A <-redirect read of a secret whose only quoted token is an innocent
# (non-secret-looking) pattern must still block — it's a genuine read — but
# must NOT show the pattern hint: pattern_hint_applies() now requires a
# quoted token that ALSO looks like a secret name, not just any quote char
# anywhere in the command. Moving the pattern cannot fix a redirect, and a
# hint pointing at the wrong recovery costs the same cycle it exists to save.
err=$(printf '%s' "$(j_bash "grep 'x' < .env")" | bash "$HOOK" 2>&1 >/dev/null); rc=$?
assert_rc "Bash grep 'x' < .env (redirect read, denied, no pattern hint)" 2 "$rc"
case "$err" in
    *"pattern first, flags after it"*) echo "FAIL grep 'x' < .env (redirect) wrongly shows pattern hint"; FAILED=$((FAILED + 1)) ;;
    *) echo "PASS grep 'x' < .env (redirect) has no pattern hint" ;;
esac

# Both shapes the hint recommends must actually pass (exit 0) — proof the
# hint doesn't recommend something the guard itself rejects.
assert_rc "Bash grep '.env' -rn scripts/ (hint shape 1, pattern first)" 0 \
    "$(run_case "$(j_bash "grep '.env' -rn scripts/")")"
assert_rc "Bash grep -e '.env' -rn scripts/ (hint shape 2, explicit -e)" 0 \
    "$(run_case "$(j_bash "grep -e '.env' -rn scripts/")")"

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

# --- HIMMEL-1741: the case-fold is a bash builtin, not `printf | tr` ---
# is_secret_basename ran a `printf | tr` fork pair PER TOKEN (the hot path in
# block-read-secrets' clause tokenizer, ~667 ms a pair on Windows+Defender).
# It is now a bash-3.2-safe builtin loop. These cases pin the fold across the
# whole ASCII alphabet, digits/punctuation (which must pass through unchanged),
# already-lowercase input (the no-op path), and NON-ASCII bytes (which must
# neither fold nor hang the loop).
assert_predicate "fold: full-alphabet non-secret ABCDEFGHIJKLMNOPQRSTUVWXYZ.md" 1 "ABCDEFGHIJKLMNOPQRSTUVWXYZ.md"
assert_predicate "fold: mixed-case .eNv.LoCaL"                0 ".eNv.LoCaL"
assert_predicate "fold: mixed-case Id_Ed25519 (digits kept)"  0 "Id_Ed25519"
assert_predicate "fold: mixed-case CREDENTIALS.Json"          0 "CREDENTIALS.Json"
assert_predicate "fold: mixed-case Secrets.Yml"               0 "Secrets.Yml"
assert_predicate "fold: punctuation-only stem ---.PEM"        0 "---.PEM"
assert_predicate "fold: MY-Secret_File.P12"                   0 "MY-Secret_File.P12"
assert_predicate "fold: CONFIG.PFX"                           0 "CONFIG.PFX"
assert_predicate "fold: uppercase template .ENV.TEMPLATE"     1 ".ENV.TEMPLATE"
assert_predicate "fold: already-lowercase no-op app.config"   1 "app.config"
assert_predicate "fold: non-ASCII basename passes through"    1 "Ünïcodé-RÉADME.md"
assert_predicate "fold: non-ASCII + secret ext still blocks"  0 "Ünïcodé-KEY.PEM"
assert_predicate "fold: empty basename (trailing separator)"  1 "/path/to/"
# End-to-end through the Bash tokenizer, exercising the same builtin fold.
assert_rc "Bash cat CONFIG.PFX (uppercase ext)" 2 "$(run_case "$(j_bash 'cat CONFIG.PFX')")"
assert_rc "Bash cat Ünïcodé-RÉADME.md"          0 "$(run_case "$(j_bash 'cat Ünïcodé-RÉADME.md')")"

# --- HIMMEL-1741 CR r1 (codex-adv): the fold must be LINEAR, not quadratic ---
# is_secret_basename is NOT called only on short filesystem basenames —
# block-read-secrets tokenizes every Bash/PowerShell command and calls it once
# per TOKEN, so a base64 `-EncodedCommand` payload, a data: URI or a long JSON
# blob lands here whole. The first builtin fold peeled one character at a time
# and was O(n^2): an 8 KB uppercase-bearing token took 13,435 ms, versus 75 ms
# for the `printf | tr` fork pair it replaced — a worse stall than the fork this
# ticket removes, on a hook that fires on EVERY Read/Grep/Bash tool call.
# These cases pin BOTH the verdict and a wall-clock bound, so a future rewrite
# back into a character loop fails the suite instead of silently regressing.
BIGTOK=""
i=0
while [ "$i" -lt 512 ]; do
    BIGTOK="${BIGTOK}ABCDEFGHIJKLMNOP"   # 512 * 16 = 8192 uppercase chars
    i=$((i + 1))
done
assert_predicate "linear fold: 8KB uppercase token is not a secret" 1 "$BIGTOK"
assert_predicate "linear fold: 8KB uppercase token + .PEM still blocks" 0 "${BIGTOK}.PEM"

fold_start=$(date +%s)
is_secret_basename "$BIGTOK" || true
is_secret_basename "${BIGTOK}${BIGTOK}" || true   # 16 KB
fold_end=$(date +%s)
fold_elapsed=$((fold_end - fold_start))
# Generous bound: the linear fold is ~milliseconds; the quadratic one needed
# 13 s for 8 KB alone (and ~4x that for 16 KB), so 10 s separates them by well
# over an order of magnitude even on a heavily loaded Windows box.
if [ "$fold_elapsed" -le 10 ]; then
    echo "PASS fold stays linear on 8KB+16KB tokens (${fold_elapsed}s)"
else
    echo "FAIL fold is superlinear — 8KB+16KB tokens took ${fold_elapsed}s (expected <=10s); a character-loop fold was likely reintroduced"
    FAILED=$((FAILED + 1))
fi

# The same shape end-to-end through the hook's clause tokenizer: a long
# uppercase argument must not stall the guard, and must not change its verdict.
assert_rc "Bash long uppercase arg (linear fold)" 0 "$(run_case "$(j_bash "node -e 1 --data $BIGTOK")")"
assert_rc "Bash long uppercase arg + .env still blocks" 2 "$(run_case "$(j_bash "cat $BIGTOK .env")")"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "All cases passed."
    exit 0
else
    echo "$FAILED case(s) failed."
    exit 1
fi
