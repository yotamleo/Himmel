#!/usr/bin/env bash
# Smoke test for scripts/hooks/block-tail-pipe-on-gates.sh (HIMMEL-1696).
#
# Usage: bash scripts/hooks/test-block-tail-pipe-on-gates.sh
#
# Contract under test:
#   * a pipeline whose FIRST stage is a registered gate command and whose LAST
#     stage is tail/head -> exit 2 (deny) + a stderr reason that names the
#     redirect shape, ${PIPESTATUS[0]} and the documented same-line marker.
#   * the same-line `# tail-pipe-ok: <reason>` marker -> exit 0, no decision.
#   * the CORRECT shape (redirect, then a separate tail) -> exit 0.
#   * unregistered commands, a bare tail, and a tail that is not the last stage
#     -> exit 0.
#   * fail OPEN on anything unevaluable (non-Bash tool, empty/unparseable stdin,
#     jq missing) — a hook that cannot parse its input must not deny unrelated
#     commands.
#   * the wiring contract: the hook is present in .claude/settings.json under a
#     PreToolUse Bash matcher AND in wire-hook-bash.mjs's owned inventory (an
#     entry missing from that inventory is refused as an impostor, which would
#     break the settings wirer).
#
# Exit codes: 0 all cases passed, 1 at least one failed.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/block-tail-pipe-on-gates.sh"
ROOT="$(cd "$HERE/../.." && pwd)"

FAILED=0

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

j_bash() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }
j_tool() { printf '{"tool_name":%s,"tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)" "$(printf '%s' "$2" | jq -Rs .)"; }

# Runs the hook on a payload, echoes "<rc>|<stderr>".
run_hook() {
    local err rc
    err=$(printf '%s' "$1" | bash "$HOOK" 2>&1 >/dev/null)
    rc=$?
    printf '%s|%s' "$rc" "$err"
}

assert_rc() {
    local label="$1" expected="$2" payload="$3" res
    res=$(run_hook "$payload")
    if [ "${res%%|*}" = "$expected" ]; then
        pass "$label (rc=${res%%|*})"
    else
        fail "$label — expected rc=$expected, got rc=${res%%|*}: ${res#*|}"
    fi
}

deny() { assert_rc "$1" 2 "$(j_bash "$2")"; }
allow() { assert_rc "$1" 0 "$(j_bash "$2")"; }

# --- DENY: the shapes that lose the gate's exit code -----------------------
deny "clear-cr-marker piped to tail" \
     'bash scripts/cr/clear-cr-marker.sh x | tail -20'
deny "a scripts/*/test-*.sh suite piped to head with 2>&1" \
     'bash scripts/handover/test-merge-on-green.sh 2>&1 | head -50'
# The leg-12 incident verbatim — the shape a bolded, worked-example brief failed
# to prevent, which is why this hook exists.
deny "run-shell-tests piped to tail (the leg-12 incident)" \
     'bash scripts/ci/run-shell-tests.sh scripts/handover 2>&1 | tail -80'
deny "check-ci piped to tail" 'bash scripts/check-ci.sh | tail'
deny "merge-on-green piped to head" 'bash scripts/handover/merge-on-green.sh | head -5'
deny "pr-merge piped to tail" 'bash scripts/handover/pr-merge.sh 123 | tail -3'
# Intermediate stages are irrelevant: what matters is first stage + LAST stage.
deny "gate | grep | tail (intermediate stage)" \
     'bash scripts/check-ci.sh | grep -E "^ok" | tail -5'
# An absolute-path invocation is the same command.
deny "absolute-path gate piped to tail" \
     'bash /c/Users/x/himmel/scripts/cr/clear-cr-marker.sh y | tail -20'
# The gate reached after a cd chain still denies (&& is a statement separator,
# so the gate is the first stage of the SECOND statement's pipeline).
deny "cd && gate | tail" \
     'cd /c/repo && bash scripts/cr/clear-cr-marker.sh x | tail -20'
# bash's `|&` puts the `&` at the head of the next stage once split on `|`.
deny "gate |& tail" 'bash scripts/check-ci.sh |& tail -20'
# Panel r1 codex-1: the gate path commonly arrives INSIDE quotes; blanking whole
# quoted spans would hide the invocation this hook exists to catch.
# shellcheck disable=SC2016  # the $VAR is payload text, not an expansion
deny "quoted gate path" 'bash "$CLAUDE_PROJECT_DIR/scripts/check-ci.sh" | tail -20'
deny "single-quoted gate path" "bash '/c/repo/scripts/cr/clear-cr-marker.sh' | head -5"
# Panel r1 codex-2: a pipeline split across physical lines is still one pipeline.
res=$(run_hook "$(j_bash 'bash scripts/check-ci.sh |
    tail -20')")
if [ "${res%%|*}" = "2" ]; then
    pass "pipeline continued onto the next physical line"
else
    fail "multiline pipeline bypassed the guard (rc=${res%%|*})"
fi
res=$(run_hook "$(j_bash 'bash scripts/check-ci.sh \
    | tail -20')")
if [ "${res%%|*}" = "2" ]; then
    pass "pipeline continued after a backslash"
else
    fail "backslash-continued pipeline bypassed the guard (rc=${res%%|*})"
fi
# CRLF canary: on a Windows checkout the payloads above already carry `\r`
# before every newline, so the two multiline cases are the real regression
# guard. This one states the property outright so a future reader knows it is
# load-bearing and not incidental.
res=$(run_hook "$(j_bash "$(printf 'bash scripts/check-ci.sh \\\r\n    | tail -20')")")
if [ "${res%%|*}" = "2" ]; then
    pass "CRLF line endings do not break continuation folding"
else
    fail "CRLF continuation bypassed the guard (rc=${res%%|*})"
fi
# Panel r1 codex-4: a marker carried inside a quoted argument is data.
deny "marker inside a quoted argument is not an opt-out" \
     'bash scripts/check-ci.sh --title "# tail-pipe-ok: not really" | tail -20'
# Panel r2 codex-1: the LAST stage is read at command position too, so a
# launcher or env prefix in front of tail/head does not hide it.
deny "gate | env tail" 'bash scripts/check-ci.sh | env tail -20'
deny "gate | command head" 'bash scripts/check-ci.sh | command head -5'
deny "gate | FOO=1 tail" 'bash scripts/check-ci.sh | FOO=1 tail -20'
deny "gate | /usr/bin/tail" 'bash scripts/check-ci.sh | /usr/bin/tail -20'
# Panel r2 codex-2: `|&` at end of line continues the pipeline too.
res=$(run_hook "$(j_bash 'bash scripts/check-ci.sh |&
    tail -20')")
if [ "${res%%|*}" = "2" ]; then
    pass "pipeline continued after a trailing |&"
else
    fail "multiline |& pipeline bypassed the guard (rc=${res%%|*})"
fi

# --- ALLOW: the correct shape, and everything unregistered ------------------
allow "redirect-then-tail (the prescribed shape)" \
      'bash scripts/cr/clear-cr-marker.sh x > /tmp/o 2>&1; tail /tmp/o'
allow "git log | tail" 'git log | tail'
allow "unregistered script piped to tail" 'bash scripts/lib/forge.sh | tail -20'
allow "bare tail -f" 'tail -f somefile'
allow "bare head" 'head -20 somefile'
allow "gate with no pipeline at all" 'bash scripts/check-ci.sh --pr 123'
# tail/head must be the LAST stage — a gate piped into something else is fine.
allow "gate | grep tail (tail is not the last stage)" \
      'bash scripts/check-ci.sh | grep tail'
allow "gate | tail | wc -l (last stage is wc)" \
      'bash scripts/check-ci.sh | tail -5 | wc -l'
# A `|` carried as DATA is not a pipe.
allow "gate with a quoted pipe in an argument" \
      'bash scripts/check-ci.sh --title "a | tail -20"'
# Panel r1 codex-3: MENTIONING a gate path is not INVOKING it. These read the
# gate script; their exit code is grep's/printf's, and nothing is lost.
allow "grep of a gate script piped to tail" \
      'grep -n CLEAR_RC scripts/cr/clear-cr-marker.sh | tail -5'
allow "printf of a gate path piped to tail" 'printf scripts/check-ci.sh | tail'
allow "cat of a gate script piped to head" 'cat scripts/handover/pr-merge.sh | head -40'
# A lookalike suffix is not the registered path.
allow "lookalike path piped to tail" 'bash vendor/scripts/check-ci.sh.bak | tail'
# Leading env assignments are stepped over — the gate is still the program.
deny "env-assigned gate piped to tail" 'FOO=1 bash scripts/check-ci.sh | tail -5'
# Panel r2 codex-3: a pipeline that exists only in a COMMENT is never run.
allow "gate pipeline inside a trailing comment" \
      'true # e.g. bash scripts/check-ci.sh | tail -20'
allow "gate pipeline in a whole-line comment" \
      '# never do: bash scripts/cr/clear-cr-marker.sh x | tail'
# ...but a `#` inside quotes is not a comment, so the real pipeline still denies.
deny "quoted hash does not start a comment" \
     'bash scripts/check-ci.sh --title "a#b" | tail -20'
# Panel r2 codex-4: `pipefail` is deliberately NOT an exemption — it fixes only
# the exit code, not the discarded output, and the hook cannot know the
# invoking shell's option state.
deny "pipefail in the same command is not an exemption" \
     'set -o pipefail; bash scripts/check-ci.sh | tail -20'
# Panel r3 codex-1: control-flow keywords and grouping/negation prefixes are not
# the invoked program.
deny "gate inside an if condition" \
     'if bash scripts/check-ci.sh | tail -5; then echo ok; fi'
deny "negated gate" '! bash scripts/check-ci.sh | tail -5'
deny "gate in a subshell" '( bash scripts/check-ci.sh | tail -5 )'
deny "gate in a while condition" \
     'while bash scripts/cr/clear-cr-marker.sh x | tail -1; do :; done'
# Panel r3 codex-2: a trailing comment must not hide the `|` that continues the
# pipeline onto the next line.
res=$(run_hook "$(j_bash 'bash scripts/check-ci.sh | # trim it
    tail -20')")
if [ "${res%%|*}" = "2" ]; then
    pass "pipeline continued after a trailing comment"
else
    fail "comment-then-continuation bypassed the guard (rc=${res%%|*})"
fi
# Panel r3 codex-3: a quote spanning newlines is DATA on every line it covers,
# so the scanner must track quote state across the whole command, not per line.
res=$(run_hook "$(j_bash "printf '%s' 'first line
bash scripts/check-ci.sh | tail -20'")")
if [ "${res%%|*}" = "0" ]; then
    pass "pipeline inside a multiline quoted string is data"
else
    fail "multiline quoted string denied as syntax (rc=${res%%|*})"
fi
# ...and a heredoc withdraws the hook entirely: its body is very often
# documentation OF this shape, and a flat scanner cannot tell body from syntax.
res=$(run_hook "$(j_bash 'cat > /tmp/doc <<XEOF
never do: bash scripts/check-ci.sh | tail -20
XEOF')")
if [ "${res%%|*}" = "0" ]; then
    pass "heredoc body -> no decision (fail-open)"
else
    fail "heredoc body denied as syntax (rc=${res%%|*})"
fi
# Cost bound: the character walk turns superlinear on very large inputs, and a
# PreToolUse hook runs on every Bash call. Over the bound it withdraws.
BIG=""
while [ "${#BIG}" -le 16000 ]; do BIG="$BIG: filler filler filler filler filler filler;"; done
allow "command over the 16KB cost bound -> no decision" \
      "$BIG bash scripts/check-ci.sh | tail -20"
# ...and just under it the guard is still live, so the bound is not a blanket off.
SMALLISH=""
while [ "${#SMALLISH}" -le 8000 ]; do SMALLISH="$SMALLISH: filler filler filler filler filler filler;"; done
deny "command under the cost bound is still scanned" \
     "$SMALLISH bash scripts/check-ci.sh | tail -20"
# Panel r4 codex-1: a LEADING redirection is not the invoked program.
deny "leading redirection then gate" \
     '2>/dev/null bash scripts/check-ci.sh | tail -20'
deny "leading redirection with a detached target" \
     '2> /dev/null bash scripts/check-ci.sh | tail -20'
# A redirection AFTER the program was always fine and must stay denied.
deny "gate with a trailing 2>&1 still denies" \
     'bash scripts/check-ci.sh 2>&1 | tail -20'
# Panel r4 codex-2: a command substitution swallows the status the same way.
# shellcheck disable=SC2016  # these payloads are literal command text
deny "gate inside a command substitution" \
     'echo $(bash scripts/check-ci.sh | tail -5)'
# shellcheck disable=SC2016
deny "gate captured into a variable" \
     'CLEAR_RC=$(bash scripts/cr/clear-cr-marker.sh x | tail -1)'
# shellcheck disable=SC2016
deny "gate inside backticks" 'echo `bash scripts/check-ci.sh | tail -5`'
# Panel r5 codex-1: substitution happens inside DOUBLE quotes, and the quoted
# spelling is the idiomatic, careful one — exactly the shape that must not slip.
# shellcheck disable=SC2016
deny "gate inside a double-quoted command substitution" \
     'CLEAR_RC="$(bash scripts/cr/clear-cr-marker.sh x | tail -1)"'
# shellcheck disable=SC2016
deny "gate inside double-quoted backticks" \
     'RC="`bash scripts/check-ci.sh | tail -1`"'
# Single quotes really are inert — there is no substitution to lift.
# shellcheck disable=SC2016
allow "substitution-looking text in single quotes is data" \
      "echo '\$(bash scripts/check-ci.sh | tail -5)'"
# Panel r6 codex-1: a standalone `&` backgrounds and STARTS a new statement.
deny "gate after a backgrounded command" \
     'true & bash scripts/check-ci.sh | tail -20'
# ...but the `&` in a redirection or in `&&` is not a separator.
deny "gate after && still denies" 'true && bash scripts/check-ci.sh | tail -20'
allow "backgrounded non-gate piped to tail" 'true & git log | tail -20'
# Panel r6 codex-2: a compact subshell closes onto the last word.
deny "compact subshell with no spaces" '(bash scripts/check-ci.sh|tail -5)'
deny "compact brace group" '{ bash scripts/check-ci.sh|tail -5; }'
# Panel r6 codex-3: `\"` does not close a double-quoted span, so the `|` inside
# it is still data.
allow "escaped quote inside a quoted argument keeps the pipe as data" \
      'bash scripts/check-ci.sh --title "a \" | tail"'
# Panel r7 codex-1: a quoted span with spaces arrives as several whitespace
# words; the tail half must not be mistaken for the command.
deny "quoted env assignment with a space before the gate" \
     'FOO="a b" bash scripts/check-ci.sh | tail -20'
deny "quoted arg with a space before the tail stage" \
     'bash scripts/check-ci.sh --title "a b" | tail -20'
# Panel r7 codex-2: `<<` as quoted DATA must not switch the whole guard off.
deny "quoted << is data, not a heredoc" \
     "bash scripts/check-ci.sh --title '<<' | tail -20"
# Panel r7 codex-3: `&>` and `&>>` are redirections, not statement separators.
deny "gate with &> redirection" 'bash scripts/check-ci.sh &>/tmp/o | tail -20'
deny "gate with &>> redirection" 'bash scripts/check-ci.sh &>>/tmp/o | tail -20'
# Panel r8 codex-1: a literal `)` inside a substitution must not end extraction
# early and leave the rest of the command unscanned.
# shellcheck disable=SC2016
deny "gate after a substitution containing a quoted paren" \
     'echo $(echo ")") ; bash scripts/check-ci.sh | tail -20'
# shellcheck disable=SC2016
deny "gate inside a substitution containing a quoted paren" \
     'echo $(bash scripts/check-ci.sh --title ")" | tail -20)'
# Panel r8 codex-2: `<<<` is a here-string and `$(( ))` is arithmetic — neither
# is a heredoc, so neither may switch the whole guard off.
deny "here-string prefix does not disable the guard" \
     'grep x <<< "data" ; bash scripts/check-ci.sh | tail -20'
# shellcheck disable=SC2016
deny "arithmetic shift does not disable the guard" \
     'echo $(( 1 << 2 )) ; bash scripts/check-ci.sh | tail -20'
# Panel r9 codex-1: an escaped space keeps bash inside the current WORD, so a
# `#` after it is not a comment and cannot carry a fake opt-out.
deny "escaped space does not let a fake marker start a comment" \
     'bash scripts/check-ci.sh x\ # tail-pipe-ok: fake | tail -20'
# The real marker — a `#` at a genuine word boundary — still works.
allow "genuine marker after an escaped-space argument still opts out" \
      'bash scripts/check-ci.sh x\ y | tail -20 # tail-pipe-ok: really'
# Panel r10 codex-1: a launcher's own options sit between it and the gate.
deny "bash -x before the gate" 'bash -x scripts/check-ci.sh | tail -20'
deny "bash -- before the gate" 'bash -- scripts/check-ci.sh | tail -20'
deny "env -i before the gate" 'env -i bash scripts/check-ci.sh | tail -20'
# ...but a flag with NO launcher in front of it is not that shape, so a plain
# command that merely NAMES a gate path still passes.
allow "flags without a launcher do not hide behind the rule" \
      'grep -n -e CLEAR_RC scripts/cr/clear-cr-marker.sh | tail -5'
# Panel r11 codex-1: bash RUNS a command substitution nested inside arithmetic.
# shellcheck disable=SC2016
deny "gate inside a substitution nested in arithmetic" \
     'x=$(( $(bash scripts/check-ci.sh | tail -1) + 1 ))'
# ...while a bare shift in arithmetic still does not disable the guard.
# shellcheck disable=SC2016
deny "arithmetic shift still does not disable the guard" \
     'echo $(( 1 << 2 )) ; bash scripts/check-ci.sh | tail -20'
# Panel r11 codex-2: an escaped space does not separate WORDS.
deny "escaped space inside an env assignment before the gate" \
     'FOO=a\ b bash scripts/check-ci.sh | tail -20'
# Panel r11 codex-3: launcher options that take an operand.
deny "sudo -u root before the gate" \
     'sudo -u root bash scripts/check-ci.sh | tail -20'
deny "env -u FOO before the gate" \
     'env -u FOO bash scripts/check-ci.sh | tail -20'
# Panel r11 codex-4: the marker must OPEN the comment, not merely appear in it.
deny "a comment merely mentioning the marker is not an opt-out" \
     'bash scripts/check-ci.sh | tail -20 # no tail-pipe-ok: marker supplied'
allow "the documented marker still opts out with leading spaces" \
      'bash scripts/check-ci.sh | tail -20 #   tail-pipe-ok: rc irrelevant'
# Panel r12 codex-1: an apostrophe INSIDE double quotes is data, not an opening
# quote — counting it left the word open and swallowed the gate behind it.
deny "apostrophe inside a double-quoted assignment before the gate" \
     'FOO="it'"'"'s fine" bash scripts/check-ci.sh | tail -20'
deny "apostrophe inside a double-quoted argument before the tail stage" \
     'bash scripts/check-ci.sh --title "it'"'"'s fine" | tail -20'
# Panel r4 codex-3: an ESCAPED operator is data — `\|` and `tail` are arguments
# to the gate, not a pipeline, so nothing swallows anything.
allow "escaped pipe is an argument, not a pipeline" \
      'bash scripts/check-ci.sh --pattern \| tail'

# --- HIMMEL-1979: the two lexer residuals the r13 panel deferred -----------
# codex-1 r13: normalisation dropped the escape from `\"`, so a VALID leading
# assignment left every later quote-state walk unbalanced — and an unbalanced
# walk resolves no command at all, so the gate behind it was never seen.
deny "escaped quote in a leading assignment before the gate" \
     'FOO="a \" b" bash scripts/check-ci.sh | tail -20'
# codex-2 r13: per-launcher operand tables. One flat launcher-agnostic list read
# the same letter the same way for every launcher and got it wrong BOTH ways.
# `-p` is time's bare portability flag, so the gate was stepped over as if it
# were -p's operand...
deny "time -p before the gate" \
     'time -p scripts/check-ci.sh | tail -20'
# ...while sudo's long option had no entry at all, so its OPERAND was returned
# as the invoked program.
deny "sudo --user root before the gate" \
     'sudo --user root bash scripts/check-ci.sh | tail -20'
# A sudo flag that takes NO operand must not swallow the gate either.
deny "sudo -n (bare flag) before the gate" \
     'sudo -n bash scripts/check-ci.sh | tail -20'
# `-S` takes an operand for env and none for sudo — the divergence one flat
# table could not express.
deny "env -S before the gate" \
     'env -S x bash scripts/check-ci.sh | tail -20'
# Panel r2 codex-1: `env -a <argv0>` takes an operand too, so the gate sat one
# token further along than the walk looked.
deny "env -a before the gate" \
     'env -a fake bash scripts/check-ci.sh | tail -20'
# `timeout` is the one launcher with a positional operand (its DURATION) before
# the program, with and without its own operand-taking options in front.
deny "timeout DURATION before the gate" \
     'timeout 300 bash scripts/check-ci.sh | tail -20'
deny "timeout -k with an option operand and a DURATION before the gate" \
     'timeout -k 5 30s bash scripts/check-ci.sh | tail -20'
deny "nice -n before the gate" \
     'nice -n 10 bash scripts/check-ci.sh | tail -20'
# Panel r1 codex-1/codex-2: the per-launcher tables must not LOSE an
# operand-taking option the retired flat list already covered.
deny "sudo -D before the gate" \
     'sudo -D /tmp bash scripts/check-ci.sh | tail -20'
deny "sudo -T before the gate" \
     'sudo -T 5 bash scripts/check-ci.sh | tail -20'
deny "GNU time -o before the gate" \
     'time -o log scripts/check-ci.sh | tail -20'
deny "xargs -I{} before the gate" \
     'xargs -I{} bash scripts/check-ci.sh | tail -20'

# --- HIMMEL-1979 negatives: what the wider walk must STILL allow ------------
# The escaped-quote fix must not turn every escaped quote into a denial — the
# command behind it is not a gate.
allow "escaped quote in a leading assignment on a NON-gate command" \
      'FOO="a \" b" git log | tail -20'
# The new launcher tables step over operands; the program they finally reach is
# still not a gate, so nothing is denied.
allow "sudo --user operand does not make a non-gate look like one" \
      'sudo --user root grep x f | head -5'
allow "timeout DURATION does not make a non-gate look like one" \
      'timeout 30 grep x f | head -5'
allow "xargs -I{} does not make a non-gate look like one" \
      'xargs -I{} echo {} | head -5'
# EXPECTED RESIDUAL (named ceiling, HIMMEL-1979): a gate invoked from inside a
# `-c` PAYLOAD is not seen — the payload is a quoted string this scanner reads
# as data, and catching it means running the scanner over it as a nested
# program (the HIMMEL-912 tokenizer class). This case asserts the CURRENT
# fail-open behaviour on purpose, so a future change to it is deliberate rather
# than accidental. It is not a shape written here: agents write `bash <gate>`.
allow "EXPECTED RESIDUAL: gate inside a -c payload is not scanned" \
      "bash -c 'scripts/check-ci.sh' | tail -20"

# --- BYPASS: the documented same-line marker --------------------------------
allow "same-line tail-pipe-ok marker" \
      'bash scripts/cr/clear-cr-marker.sh x | tail -20  # tail-pipe-ok: rc irrelevant, output only'
# The marker is SAME-LINE: a marker on a different line does not exempt.
res=$(run_hook "$(j_bash '# tail-pipe-ok: on the wrong line
bash scripts/cr/clear-cr-marker.sh x | tail -20')")
if [ "${res%%|*}" = "2" ]; then
    pass "marker on a different line does not exempt"
else
    fail "marker on a different line exempted the pipeline (rc=${res%%|*})"
fi
# The bypass must WITHDRAW the hook, never grant.
bout=$(printf '%s' "$(j_bash 'bash scripts/check-ci.sh | tail  # tail-pipe-ok: x')" | bash "$HOOK" 2>/dev/null)
if [ -z "$bout" ]; then
    pass "bypass emits no stdout decision (withdraws, does not grant)"
else
    fail "bypass wrote a decision to stdout — got: $bout"
fi

# --- The deny reason must be actionable ------------------------------------
res=$(run_hook "$(j_bash 'bash scripts/cr/clear-cr-marker.sh x | tail -20')")
msg=${res#*|}
for needle in 'RC=$?' 'PIPESTATUS[0]' 'tail-pipe-ok:' 'clear-cr-marker.sh'; do
    if grep -qF -- "$needle" <<< "$msg"; then
        pass "deny reason names $needle"
    else
        fail "deny reason does not name $needle — got: $msg"
    fi
done

# --- FAIL OPEN on anything unevaluable -------------------------------------
assert_rc "PowerShell tool -> no decision" 0 "$(j_tool PowerShell 'bash scripts/check-ci.sh | tail')"
assert_rc "Read tool -> no decision" 0 "$(j_tool Read 'x')"
assert_rc "empty input -> no decision" 0 ""
assert_rc "unparseable input -> no decision" 0 "not json"
assert_rc "no command field -> no decision" 0 '{"tool_name":"Bash","tool_input":{}}'
# jq unavailable: rename the probed binary in a temp copy of the hook (the
# sed-a-temp-copy seam the sibling suites use). An emptied PATH would instead
# take out `cat`/`sed` and pass for the wrong reason.
NOJQ_HOOK=$(mktemp "${TMPDIR:-/tmp}/block-tail-pipe-on-gates.XXXXXX")
trap 'rm -f "$NOJQ_HOOK"' EXIT
sed 's/command -v jq /command -v jq__absent__ /' "$HOOK" > "$NOJQ_HOOK"
if grep -q 'jq__absent__' "$NOJQ_HOOK"; then
    printf '%s' "$(j_bash 'bash scripts/check-ci.sh | tail')" | bash "$NOJQ_HOOK" >/dev/null 2>&1
    rc=$?
    if [ "$rc" = "0" ]; then
        pass "jq unavailable -> no decision (fail-open)"
    else
        fail "jq unavailable -> expected rc=0, got $rc"
    fi
else
    fail "jq-absent fixture did not patch the hook — the probe line changed shape"
fi

# --- The scanned command string is DATA, never code ------------------------
# The hook feeds $cmd through heredocs; bash expands a heredoc body ONCE, so the
# substituted value is not re-scanned. Pin that: a payload full of substitutions
# must neither run nor be expanded away.
CANARY="${TMPDIR:-/tmp}/h1696-canary-$$"
rm -f "$CANARY"
res=$(run_hook "$(j_bash "bash scripts/check-ci.sh \$(touch '$CANARY') \`touch '$CANARY'\` \${HOME} | tail")")
if [ -e "$CANARY" ]; then
    fail "hook EXECUTED a substitution from the scanned command string"
    rm -f "$CANARY"
else
    pass "substitutions in the scanned command are data, not executed"
fi
# ...and the gate is still recognised through them.
if [ "${res%%|*}" = "2" ]; then
    pass "gate with substitutions in its args still denies"
else
    fail "gate with substitutions in its args did not deny (rc=${res%%|*})"
fi

# The hook is deny-only: it must never emit a permission decision on stdout.
out=$(printf '%s' "$(j_bash 'bash scripts/check-ci.sh | tail')" | bash "$HOOK" 2>/dev/null)
if grep -q '"permissionDecision"' <<< "$out"; then
    fail "hook emitted a permission decision on stdout — it must only deny via exit 2"
else
    pass "hook emits no stdout permission decision"
fi

# --- Wiring contract --------------------------------------------------------
# .claude/settings.json is a PRIVATE_PATH: public-mirror / adopter clones lack
# it, so its absence is a skip, not a failure.
SETTINGS="$ROOT/.claude/settings.json"
if [ ! -f "$SETTINGS" ]; then
    echo "SKIP settings.json wiring — .claude/settings.json absent (public mirror / adopter checkout)"
elif ! command -v node >/dev/null 2>&1; then
    echo "SKIP settings.json wiring — node not found"
else
    if node -e '
        const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
        const groups = (s.hooks && s.hooks.PreToolUse) || [];
        const hit = groups.some((g) =>
            typeof g.matcher === "string" &&
            g.matcher.split("|").includes("Bash") &&
            (g.hooks || []).some((h) => typeof h.command === "string" &&
                h.command.includes("block-tail-pipe-on-gates.sh")));
        process.exit(hit ? 0 : 1);
    ' "$SETTINGS"; then
        pass "settings.json wires the hook under a PreToolUse Bash matcher"
    else
        fail "settings.json has no PreToolUse Bash entry for block-tail-pipe-on-gates.sh"
    fi
    # An owned-event hook script missing from wire-hook-bash.mjs's inventory is
    # refused as an impostor, which breaks the sanctioned settings wirer.
    if grep -qF "'block-tail-pipe-on-gates.sh'," "$ROOT/scripts/hooks/wire-hook-bash.mjs"; then
        pass "wire-hook-bash.mjs owns the hook (not an impostor)"
    else
        fail "wire-hook-bash.mjs EXPECTED_SCRIPT_ORDER is missing block-tail-pipe-on-gates.sh"
    fi
fi

# --- additionalDirectories guard (HIMMEL-2381) ------------------------------
# The operator hand-authored permissions.additionalDirectories in the primary
# checkout's settings.json to close outside-cwd Read/Grep/Glob prompts that
# hang an unattended overnight leg (docs/handover/overnight-mode.md). Pin the
# four entries exactly; SKIP (not fail) mirrors the wiring-contract block
# above — settings.json is a PRIVATE_PATH absent on public-mirror checkouts.
if [ ! -f "$SETTINGS" ]; then
    echo "SKIP additionalDirectories guard — .claude/settings.json absent (public mirror / adopter checkout)"
else
    EXPECTED_DIRS='["~/Documents/github/himmel","~/.himmel","~/Documents/luna","~/AppData/Local/Python"]'

    check_additional_dirs() {  # $1 = settings.json path -> rc 0 iff it matches EXPECTED_DIRS exactly
        [ -f "$1" ] || return 1
        local got
        got=$(jq -c '.permissions.additionalDirectories // empty' "$1" 2>/dev/null)
        [ "$got" = "$EXPECTED_DIRS" ]
    }

    if check_additional_dirs "$SETTINGS"; then
        pass "settings.json permissions.additionalDirectories pins the four operator-authored entries"
    else
        fail "settings.json permissions.additionalDirectories missing/changed: $(jq -c '.permissions.additionalDirectories // empty' "$SETTINGS" 2>/dev/null)"
    fi

    # Positive control (HIMMEL-2320): a pass is not evidence without proof the
    # assertion actually detects absence — show it goes red on a throwaway
    # copy with the key stripped.
    if ! MUTATED=$(mktemp); then
        fail "positive control could not create a temporary settings file"
    elif ! jq 'del(.permissions.additionalDirectories)' "$SETTINGS" > "$MUTATED"; then
        fail "positive control could not create a stripped settings file"
    elif check_additional_dirs "$MUTATED"; then
        fail "positive control failed: check_additional_dirs did not detect a stripped key"
    else
        pass "positive control: check_additional_dirs goes red when the key is removed"
    fi
    [ -z "${MUTATED:-}" ] || rm -f "$MUTATED"
fi

if [ "$FAILED" -eq 0 ]; then
    echo "OK block-tail-pipe-on-gates: all cases passed"
    exit 0
fi
echo "ERR block-tail-pipe-on-gates: $FAILED case(s) failed" >&2
exit 1
