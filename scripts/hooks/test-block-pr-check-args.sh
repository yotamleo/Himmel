#!/usr/bin/env bash
# Smoke test for scripts/hooks/block-pr-check-args.sh (HIMMEL-2306).
#
# Usage: bash scripts/hooks/test-block-pr-check-args.sh
#
# Exit codes:
#   0 - all cases passed
#   1 - at least one case failed
#
# The payload shapes below are not invented: they are the UserPromptExpansion
# stdin schema read out of the installed build (claude.exe 2.1.251) —
# `expansion_type`, `command_name`, `command_args`, `command_source`, `prompt`.
# The published docs name `command_input` and `expanded_prompt` instead; those
# fields do not exist in the binary, so a test written from the docs would have
# passed against a hook that never fires. Case (xi) is the guard against that:
# it feeds the DOC-shaped payload and asserts the hook does not read it as a
# bare invocation.
set -uo pipefail

# Every case invokes the hook as `bash "$HOOK"`, so the executable bit is
# irrelevant here. The sibling suites carry a `chmod +x` at this point; copying
# it would MUTATE the worktree on every Unix run, because the hook is committed
# mode 100644 (panel round 3, codex-2). A test must not dirty the tree it tests.
HOOK="$(cd "$(dirname "$0")" && pwd)/block-pr-check-args.sh"

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

# Build a UserPromptExpansion payload. jq -Rs does the quoting so a case can
# carry apostrophes, $(…) and backticks without this test file becoming the
# very injection surface it is testing.
j_exp() {
    local name="$1" args="$2" type="${3:-slash_command}"
    printf '{"hook_event_name":"UserPromptExpansion","expansion_type":%s,"command_name":%s,"command_args":%s,"command_source":"project","prompt":"/pr-check"}' \
        "$(printf '%s' "$type" | jq -Rs .)" \
        "$(printf '%s' "$name" | jq -Rs .)" \
        "$(printf '%s' "$args" | jq -Rs .)"
}

# --- BLOCK cases (expect rc=2): /pr-check carrying any argument at all ---
assert_rc "(i) plain repo path"        2 "$(run_case "$(j_exp pr-check '/c/Users/x/other-repo')")"
assert_rc "(ii) relative path"         2 "$(run_case "$(j_exp pr-check '../sibling')")"
assert_rc "(iii) bare word"            2 "$(run_case "$(j_exp pr-check 'simplify')")"
assert_rc "(iv) leading-slash name"    2 "$(run_case "$(j_exp /pr-check '/some/path')")"
# The argument shapes that made the in-prompt approaches unfixable. The hook
# must refuse them like any other argument -- and must never echo them back.
# The single quotes below are the POINT, not an oversight: these payloads have
# to reach the hook as literal text, exactly as a user would type them. Letting
# them expand here would test the shell, not the hook -- and would run `id` in
# this test's own process.
assert_rc "(v) apostrophe in path"     2 "$(run_case "$(j_exp pr-check "/repos/o'brien/x")")"
# shellcheck disable=SC2016 # deliberate: literal payload, must not expand
assert_rc "(vi) command substitution"  2 "$(run_case "$(j_exp pr-check '/tmp/$(id)')")"
# shellcheck disable=SC2016 # deliberate: literal payload, must not expand
assert_rc "(vii) backticks"            2 "$(run_case "$(j_exp pr-check '/tmp/`id`')")"
# shellcheck disable=SC2016 # deliberate: literal payload, must not expand
assert_rc "(viii) braced expansion"    2 "$(run_case "$(j_exp pr-check '${HOME}/x')")"
assert_rc "(ix) semicolon chain"       2 "$(run_case "$(j_exp pr-check '/tmp/x;touch /tmp/pwned')")"
assert_rc "(x) newline in argument"    2 "$(run_case "$(j_exp pr-check '/tmp/x
/tmp/y')")"

# --- ALLOW cases (expect rc=0): a bare /pr-check must be untouched ---
assert_rc "(A) bare invocation"        0 "$(run_case "$(j_exp pr-check '')")"
assert_rc "(B) trailing space only"    0 "$(run_case "$(j_exp pr-check ' ')")"
assert_rc "(C) tab/newline only"       0 "$(run_case "$(j_exp pr-check '
')")"
# Scope: a different command carrying an argument is none of this hook's
# business, even when the operator wires it without a matcher.
assert_rc "(D) other command w/ arg"   0 "$(run_case "$(j_exp worktree 'feat/x')")"
assert_rc "(E) other command bare"     0 "$(run_case "$(j_exp clean '')")"
# An MCP prompt that happens to share the name is a different surface.
assert_rc "(F) mcp_prompt w/ arg"      0 "$(run_case "$(j_exp pr-check '/some/path' mcp_prompt)")"

# --- Bypass ---
assert_rc "(G) PR_CHECK_ARGS_OK=1"     0 "$(run_case "$(j_exp pr-check '/some/path')" 'PR_CHECK_ARGS_OK=1')"

# --- Fail-closed cases (expect rc=2): never allow on an input we cannot read ---
assert_rc "(H) malformed JSON"         2 "$(run_case 'not json at all')"
assert_rc "(I) empty stdin"            2 "$(run_case '')"

# --- (xi) The doc-shaped payload regression guard ---------------------------
# The published docs describe `command_input`/`expanded_prompt`. If a future
# edit rewrote the hook to read those, THIS payload (which carries the real
# field `command_args`, plus doc-named decoys) would still have to block --
# and the real-field cases above would keep passing. Conversely a hook that
# reads ONLY the doc fields would allow case (i) above, failing loudly.
doc_shaped='{"hook_event_name":"UserPromptExpansion","expansion_type":"slash_command","command_name":"pr-check","command_args":"/real/field/path","command_input":"","expanded_prompt":"/pr-check"}'
assert_rc "(xi) real field wins over doc decoys" 2 "$(run_case "$doc_shaped")"
# ...and the mirror: doc fields populated, real field EMPTY, is a bare call.
doc_only='{"hook_event_name":"UserPromptExpansion","expansion_type":"slash_command","command_name":"pr-check","command_args":"","command_input":"/doc/field/path","expanded_prompt":"/pr-check /doc/field/path"}'
assert_rc "(xii) doc-only fields are not an argument" 0 "$(run_case "$doc_only")"

# --- SCHEMA-DRIFT cases (panel round 2, codex-1) -----------------------------
# The guard must decide scope on POSITIVE evidence of being OUT of scope, never
# on a field it merely failed to read. An earlier revision skipped unless
# expansion_type was exactly "slash_command", so any payload missing or renaming
# that key took the ALLOW path — a silent disarm wearing a fail-closed header.
# These are not hypothetical: the published docs name fields this build does not
# have, which is how the hook came to be written from the binary in the first
# place.
drift_no_type='{"hook_event_name":"UserPromptExpansion","command_name":"pr-check","command_args":"/some/path"}'
assert_rc "(xvi) missing expansion_type still BLOCKS"   2 "$(run_case "$drift_no_type")"
drift_new_type='{"hook_event_name":"UserPromptExpansion","expansion_type":"slash_command_v2","command_name":"pr-check","command_args":"/some/path"}'
assert_rc "(xvii) renamed expansion_type still BLOCKS"  2 "$(run_case "$drift_new_type")"
# A missing command_args on an in-scope command is the case the guard cannot
# certify — it must deny, not assume "no argument".
drift_no_args='{"hook_event_name":"UserPromptExpansion","expansion_type":"slash_command","command_name":"pr-check"}'
assert_rc "(xviii) missing command_args BLOCKS"         2 "$(run_case "$drift_no_args")"
# ...and a payload with no command_name at all cannot be shown out of scope.
drift_no_name='{"hook_event_name":"UserPromptExpansion","expansion_type":"slash_command","command_args":"/some/path"}'
assert_rc "(xix) missing command_name still BLOCKS"     2 "$(run_case "$drift_no_name")"
# NULL is not absence, and `has()` alone does not catch it: an explicit null
# satisfies has(), and `// ""` then coerces it to the empty string — so a null
# command_args would have read as "a bare invocation" and a null command_name as
# "some other command". Both are schema drift. The guard types these fields
# (the 2.1.251 schema declares them plain strings), so anything non-string
# denies (panel round 4).
null_args='{"hook_event_name":"UserPromptExpansion","expansion_type":"slash_command","command_name":"pr-check","command_args":null}'
assert_rc "(xxii) null command_args BLOCKS"             2 "$(run_case "$null_args")"
null_name='{"hook_event_name":"UserPromptExpansion","expansion_type":"slash_command","command_name":null,"command_args":"/some/path"}'
assert_rc "(xxiii) null command_name BLOCKS"            2 "$(run_case "$null_name")"
null_type='{"hook_event_name":"UserPromptExpansion","expansion_type":null,"command_name":"pr-check","command_args":"/some/path"}'
assert_rc "(xxiv) null expansion_type still BLOCKS"     2 "$(run_case "$null_type")"
# A non-string of another shape must not slip past either.
num_args='{"hook_event_name":"UserPromptExpansion","expansion_type":"slash_command","command_name":"pr-check","command_args":42}'
assert_rc "(xxv) non-string command_args BLOCKS"        2 "$(run_case "$num_args")"
# The two carve-outs must SURVIVE the hardening — a present-but-different
# command name, and an explicit mcp_prompt, are real out-of-scope evidence.
assert_rc "(xx) other command still allowed"            0 "$(run_case "$(j_exp worktree '/some/path')")"
assert_rc "(xxi) explicit mcp_prompt still allowed"     0 "$(run_case "$(j_exp pr-check '/some/path' mcp_prompt)")"

# --- The argument must never reach the transcript ---------------------------
# The hazard this hook closes is an untrusted value transiting a prompt. A
# refusal that echoed the argument back into stderr would hand it to the agent
# by another route, so assert the secret is absent from the message.
secret='ZZCANARY7f3a'
msg="$(printf '%s' "$(j_exp pr-check "/tmp/$secret")" | bash "$HOOK" 2>&1 >/dev/null)"
# HERE-STRINGS, not `printf … | grep -q`: this file runs under `set -o
# pipefail`, where `grep -q` exits on its first match, the producer takes
# SIGPIPE writing the rest, and the PIPELINE status goes non-zero — so a
# SUCCESSFUL match can read as a failure and a negated guard inverts
# (HIMMEL-1430). `$msg` is a few hundred bytes, far under the ~64 KiB where a
# Git Bash here-string wedges (HIMMEL-2027), so the here-string is the right
# shape here rather than capturing into a variable.
if grep -qF -- "$secret" <<< "$msg"; then
    echo "FAIL (xiii) refusal message echoes the argument back ($secret found in stderr)"
    FAILED=$((FAILED + 1))
else
    echo "PASS (xiii) refusal message does not echo the argument back"
fi
# Positive control for (xiii): prove the grep would have found the canary.
if grep -qF -- "$secret" <<< "prefix $secret suffix"; then
    echo "PASS (xiv) canary grep positive control"
else
    echo "FAIL (xiv) canary grep positive control - the (xiii) check is vacuous"
    FAILED=$((FAILED + 1))
fi
# The refusal must still name the remedy, or it is a dead end for the operator.
if grep -q 'cwd selects the repo under review' <<< "$msg"; then
    echo "PASS (xv) refusal names the remedy"
else
    echo "FAIL (xv) refusal does not name the remedy"
    FAILED=$((FAILED + 1))
fi

if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "$FAILED FAILED"
exit 1
