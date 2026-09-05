#!/usr/bin/env bash
# Smoke test for scripts/hooks/require-quiet-run.sh (HIMMEL-1952).
#
# Usage: bash scripts/hooks/test-require-quiet-run.sh
#
# Exit codes:
#   0 - all cases passed
#   1 - at least one case failed
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/require-quiet-run.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK" 2>/dev/null || true

FAILED=0

j_bash() { printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)"; }

# Runs the hook against one JSON payload, optionally with an env-var
# assignment string (e.g. "QUIET_RUN_BYPASS=1"). Sets RC and ERR.
run_case() {
    local input="$1" env_assign="${2:-}"
    if [ -n "$env_assign" ]; then
        ERR=$(printf '%s' "$input" | env "$env_assign" bash "$HOOK" 2>&1 >/dev/null)
    else
        ERR=$(printf '%s' "$input" | bash "$HOOK" 2>&1 >/dev/null)
    fi
    RC=$?
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

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*)
            echo "PASS $label (message has replacement)"
            ;;
        *)
            echo "FAIL $label - message did not contain: $needle"
            echo "  got: $haystack"
            FAILED=$((FAILED + 1))
            ;;
    esac
}

# 1. Bare suite run -> denied, message names the exact quiet-run replacement.
run_case "$(j_bash 'bash scripts/test-check-ci.sh')"
assert_rc "bare test-check-ci.sh" 2 "$RC"
assert_contains "bare test-check-ci.sh replacement" \
    "bash scripts/quiet-run.sh check-ci-suite -- bash scripts/test-check-ci.sh" "$ERR"

# 2. Same command already wrapped in quiet-run.sh -> passes through.
run_case "$(j_bash 'bash scripts/quiet-run.sh check-ci-suite -- bash scripts/test-check-ci.sh')"
assert_rc "already wrapped" 0 "$RC"

# 3. QUIET_RUN_BYPASS=1 -> passes through.
run_case "$(j_bash 'bash scripts/test-check-ci.sh')" "QUIET_RUN_BYPASS=1"
assert_rc "QUIET_RUN_BYPASS=1" 0 "$RC"

# 4. scripts/ci/run-shell-tests.sh -> denied (special-cased path, no test- prefix).
run_case "$(j_bash 'bash scripts/ci/run-shell-tests.sh')"
assert_rc "run-shell-tests.sh" 2 "$RC"
assert_contains "run-shell-tests.sh replacement" \
    "bash scripts/quiet-run.sh run-shell-tests-suite -- bash scripts/ci/run-shell-tests.sh" "$ERR"

# 5. Non-suite commands are unaffected - the regression that matters most.
run_case "$(j_bash 'git status')"
assert_rc "git status" 0 "$RC"
run_case "$(j_bash 'node --test --test-reporter=dot "scripts/lanes/tests/**/*.test.mjs"')"
assert_rc "node --test" 0 "$RC"
run_case "$(j_bash 'bun test --dots')"
assert_rc "bun test" 0 "$RC"

# 6. A suite path mentioned in an unrelated (non-executing) position is not denied.
run_case "$(j_bash 'cat scripts/test-check-ci.sh')"
assert_rc "cat suite file" 0 "$RC"

# 7. Nested suite path -> denied, label derived from the filename only.
run_case "$(j_bash 'bash scripts/hooks/test-block-destructive-commands.sh')"
assert_rc "nested suite path" 2 "$RC"
assert_contains "nested suite path replacement" \
    "bash scripts/quiet-run.sh block-destructive-commands-suite -- bash scripts/hooks/test-block-destructive-commands.sh" "$ERR"

# 8. Direct ./ exec form (no interpreter word) -> denied.
run_case "$(j_bash './scripts/test-check-ci.sh')"
assert_rc "direct ./ exec" 2 "$RC"

# 9. quiet-run.sh merely MENTIONED (not invoked) alongside a bare suite run
# -> still denied. This is the bypass HIMMEL-1952's CR fixed: a substring
# check on "quiet-run.sh" anywhere in the command let this through as an
# allow, silently skipping the deny entirely.
run_case "$(j_bash 'echo quiet-run.sh; bash scripts/test-check-ci.sh')"
assert_rc "quiet-run.sh mentioned, not invoked" 2 "$RC"

# 10. quiet-run.sh mentioned in a trailing comment / as a non-command
# argument, with a bare suite run present -> denied.
run_case "$(j_bash 'bash scripts/test-check-ci.sh # see scripts/quiet-run.sh')"
assert_rc "quiet-run.sh in comment" 2 "$RC"
run_case "$(j_bash 'bash scripts/test-check-ci.sh --note=quiet-run.sh')"
assert_rc "quiet-run.sh as argument" 2 "$RC"

# 11. HIMMEL-2322: the ceiling this used to pin (finding 2, "documented not
# fixed") is now fixed - a heredoc body is DATA, and `cat` never feeds this
# one to a shell, so suite-shaped text sitting inside it must not deny.
run_case "$(j_bash 'cat <<EOF
bash scripts/test-check-ci.sh
EOF')"
assert_rc "heredoc DATA no longer a false positive (HIMMEL-2322)" 0 "$RC"

# 12. Compound command: a wrapped quiet-run call, then a SEPARATE bare suite
# call -> still denied. This is the CR round 2 finding: the old allow-check
# was whole-command, so finding a quiet-run invocation ANYWHERE exit-0'd
# before the suite regexes ran against the rest of the command.
run_case "$(j_bash 'bash scripts/quiet-run.sh ok -- echo ok; bash scripts/test-check-ci.sh')"
assert_rc "quiet-run wrap then bare suite (compound bypass)" 2 "$RC"

# 13. Same bypass, reverse order: bare suite first, then a quiet-run call.
run_case "$(j_bash 'bash scripts/test-check-ci.sh; bash scripts/quiet-run.sh ok -- echo ok')"
assert_rc "bare suite then quiet-run wrap" 2 "$RC"

# 14. The tool's own sanctioned form must still pass through segment-wise
# evaluation - this is the regression that matters most: if this breaks, the
# gate denies its own remedy and becomes unusable.
run_case "$(j_bash 'bash scripts/quiet-run.sh check-ci-suite -- bash scripts/test-check-ci.sh')"
assert_rc "sanctioned single quiet-run wrap (regression)" 0 "$RC"

# 15. Two chained legitimate quiet-run calls -> passes through.
run_case "$(j_bash 'bash scripts/quiet-run.sh a -- true; bash scripts/quiet-run.sh b -- true')"
assert_rc "two chained quiet-run calls" 0 "$RC"

# 16. Nested command positions (CR round 3): the segment anchor only saw the
# START of a ';'/'&'/'|' segment, so a suite run behind an assignment prefix,
# a conditional keyword, a subshell, or a command substitution slipped past.
# Each of these executes the suite bare and floods the context.
run_case "$(j_bash 'FOO=1 bash scripts/test-check-ci.sh')"
assert_rc "assignment prefix" 2 "$RC"
run_case "$(j_bash 'if bash scripts/test-check-ci.sh; then echo ok; fi')"
assert_rc "conditional prefix" 2 "$RC"
run_case "$(j_bash '(bash scripts/test-check-ci.sh)')"
assert_rc "subshell" 2 "$RC"
# shellcheck disable=SC2016  # the payload is literal shell text, not expanded here
run_case "$(j_bash 'out=$(bash scripts/test-check-ci.sh)')"
assert_rc "command substitution" 2 "$RC"
# shellcheck disable=SC2016  # the payload is literal shell text, not expanded here
run_case "$(j_bash 'out=`bash scripts/test-check-ci.sh`')"
assert_rc "backtick substitution" 2 "$RC"
run_case "$(j_bash '{ bash scripts/test-check-ci.sh; }')"
assert_rc "brace group" 2 "$RC"

# 17. The same nested positions must NOT deny the sanctioned wrapped form -
# the strip/split widening has to stay symmetric or the gate eats its remedy.
run_case "$(j_bash 'if bash scripts/quiet-run.sh a -- true; then echo ok; fi')"
assert_rc "quiet-run in a conditional (regression)" 0 "$RC"
run_case "$(j_bash '(bash scripts/quiet-run.sh check-ci-suite -- bash scripts/test-check-ci.sh)')"
assert_rc "quiet-run wrap in a subshell (regression)" 0 "$RC"

# 18. Declared scope is scripts/**/test-*.sh, which includes dotted filenames;
# the filename class used to stop at the first '.' and exit 0 on them.
run_case "$(j_bash 'bash scripts/test-check.ci.sh')"
assert_rc "dotted suite filename" 2 "$RC"
assert_contains "dotted suite filename replacement"     "bash scripts/quiet-run.sh check.ci-suite -- bash scripts/test-check.ci.sh" "$ERR"

# 19. HIMMEL-2322 - heredoc bodies fed to a real shell still deny: a heredoc
# piped into bash, or bash reading its own heredoc, genuinely executes its
# body, so a suite call sitting inside one of these must still bounce.
run_case "$(j_bash "cat <<'EOF' | bash
bash scripts/ci/run-shell-tests.sh
EOF")"
assert_rc "heredoc piped to bash (HIMMEL-2322)" 2 "$RC"

run_case "$(j_bash "bash <<'EOF'
bash scripts/test-check-ci.sh
EOF")"
assert_rc "bash reads its own heredoc (HIMMEL-2322)" 2 "$RC"

run_case "$(j_bash 'bash -s <<EOF
bash scripts/test-check-ci.sh
EOF')"
assert_rc "bash -s heredoc variant (HIMMEL-2322)" 2 "$RC"

# 20. HIMMEL-2322 - a quoted command word must still match: the SUITE/
# INTERP_RE regexes see plain text, so a quoted suite path has to be
# unwrapped (there are no embedded separators here to neutralize).
run_case "$(j_bash 'bash "scripts/ci/run-shell-tests.sh"')"
assert_rc "double-quoted suite path (HIMMEL-2322)" 2 "$RC"

run_case "$(j_bash "bash 'scripts/test-check-ci.sh'")"
assert_rc "single-quoted suite path (HIMMEL-2322)" 2 "$RC"

# 21. HIMMEL-2322 - a command that BOTH writes a prose heredoc AND
# separately runs a bare suite: stripping the prose heredoc body must not
# hide the real, un-heredoc'd invocation right after it.
run_case "$(j_bash "cat > handover.md <<'EOF'
bash scripts/ci/run-shell-tests.sh scripts/hooks
EOF
bash scripts/ci/run-shell-tests.sh")"
assert_rc "prose heredoc plus separate bare suite (HIMMEL-2322)" 2 "$RC"

# 22. HIMMEL-2322 - the reported shape (2026-08-31): a heredoc body
# redirected to a file, whose prose happens to quote a suite command, must
# not be denied - nothing in it executes.
run_case "$(j_bash "cat > handover.md <<'EOF'
prose line quoting bash scripts/ci/run-shell-tests.sh scripts/hooks
EOF")"
assert_rc "reported shape - prose heredoc to a file (HIMMEL-2322)" 0 "$RC"

# 23. Redirect-after form of the same shape - the '>' can come before OR
# after the heredoc operator.
run_case "$(j_bash "cat <<'EOF' > handover.md
bash scripts/ci/run-shell-tests.sh scripts/hooks
EOF")"
assert_rc "redirect-after heredoc form (HIMMEL-2322)" 0 "$RC"

# 24. <<- form: the closing delimiter line may be tab-indented.
run_case "$(j_bash $'cat <<-EOF\n\tbash scripts/ci/run-shell-tests.sh scripts/hooks\n\tEOF')"
assert_rc "<<- with tab-indented terminator (HIMMEL-2322)" 0 "$RC"

# 25. Bare (unquoted) delimiter - not just the quoted forms.
run_case "$(j_bash "cat > handover.md <<EOF
bash scripts/ci/run-shell-tests.sh scripts/hooks
EOF")"
assert_rc "bare unquoted heredoc delimiter (HIMMEL-2322)" 0 "$RC"

# 26. Two heredocs in one command, only the second is prose - the first
# (shell-fed) heredoc's real content must not be mistaken for prose, and
# the second (file-redirected) heredoc's prose must not be mistaken for a
# real invocation.
run_case "$(j_bash "bash <<'EOF'
echo hi
EOF
cat > handover.md <<'EOF2'
bash scripts/ci/run-shell-tests.sh scripts/hooks
EOF2")"
assert_rc "two heredocs, only second is prose (HIMMEL-2322)" 0 "$RC"

# 27. HIMMEL-2322 CR round 2 - unterminated heredoc: no closing delimiter
# line before the command ends. Round 1 dropped everything from the intro
# onward here (an rc=0 "assume it's prose" guess); CR round 2 flipped that
# because it's exactly what turned a MIS-CAPTURED delimiter into a silent
# bypass (a genuinely-executing suite call after the "body" got dropped
# along with it). Now nothing is stripped when a heredoc can't be closed -
# the scan proceeds over that text as it did before HIMMEL-2322, so this
# case denies again (a possible false positive, never a false negative).
run_case "$(j_bash "cat <<'EOF'
bash scripts/ci/run-shell-tests.sh scripts/hooks")"
assert_rc "unterminated heredoc now fails closed (HIMMEL-2322 CR round 2)" 2 "$RC"

# 28. A quoted ';' must not create a new segment - it collapses into the
# surrounding word instead of acting as a real command separator.
run_case "$(j_bash 'echo "step one; bash scripts/ci/run-shell-tests.sh scripts/hooks"')"
assert_rc "quoted semicolon inside echo (HIMMEL-2322)" 0 "$RC"

run_case "$(j_bash 'git commit -m "ran bash scripts/ci/run-shell-tests.sh; all green"')"
assert_rc "quoted semicolon inside commit message (HIMMEL-2322)" 0 "$RC"

run_case "$(j_bash "printf '%s\n' 'bash scripts/test-foo.sh; done'")"
assert_rc "quoted semicolon inside single-quoted printf arg (HIMMEL-2322)" 0 "$RC"

# 29. gh pr create --body-file heredoc - the other reported shape (a PR
# body quoting a suite command).
run_case "$(j_bash "gh pr create --body-file - <<'EOF'
bash scripts/ci/run-shell-tests.sh scripts/hooks
EOF")"
assert_rc "gh pr create body-file heredoc (HIMMEL-2322)" 0 "$RC"

# 30. HIMMEL-2322 CR round 1 - an EARLIER, unrelated segment on the intro
# line naming bash/sh/zsh must not make a LATER, unrelated heredoc
# shell-fed. Only the segment containing '<<' and segments after it count.
run_case "$(j_bash "echo hi; cat <<'EOF' > handover.md
bash scripts/ci/run-shell-tests.sh scripts/hooks
EOF")"
assert_rc "unrelated bash-named segment before an unrelated heredoc (HIMMEL-2322)" 0 "$RC"

run_case "$(j_bash "bash scripts/quiet-run.sh foo -- true; cat <<'EOF' > handover.md
bash scripts/ci/run-shell-tests.sh scripts/hooks
EOF")"
assert_rc "sanctioned quiet-run call before an unrelated heredoc (HIMMEL-2322)" 0 "$RC"

# 31. HIMMEL-2322 CR round 1 (codex-1, BLOCKING) - a QUOTED `<<EOF` in prose
# is not a real heredoc operator; the old (non-quote-aware) detector opened
# a fake heredoc anyway and swallowed the REAL bare suite call on the next
# line as its "body", silently allowing it. Both quote kinds close the same
# bypass.
run_case "$(j_bash "echo '<<EOF'
bash scripts/ci/run-shell-tests.sh")"
assert_rc "quoted single-quote heredoc-lookalike does not swallow the next line (HIMMEL-2322)" 2 "$RC"

run_case "$(j_bash 'echo "<<EOF"
bash scripts/ci/run-shell-tests.sh')"
assert_rc "quoted double-quote heredoc-lookalike does not swallow the next line (HIMMEL-2322)" 2 "$RC"

# 32. HIMMEL-2322 CR round 1 (codex-3, suggestion) - an escaped bare
# delimiter (`<<\EOF`) suppresses body expansion exactly like a quoted one;
# its prose body must not be denied either.
run_case "$(j_bash "cat <<\EOF > doc.md
prose line bash scripts/ci/run-shell-tests.sh scripts/hooks
EOF")"
assert_rc "escaped bare heredoc delimiter allows its prose body (HIMMEL-2322)" 0 "$RC"

# 33. HIMMEL-2322 CR round 1 - controls proving a REAL heredoc intro is
# still detected after the quote-aware detector change (not just the fake
# ones above).
run_case "$(j_bash "cat <<'EOF' > doc.md
prose
EOF")"
assert_rc "real single-quoted heredoc to a file still allows (HIMMEL-2322)" 0 "$RC"

run_case "$(j_bash "cat <<'EOF' | bash
bash scripts/ci/run-shell-tests.sh
EOF")"
assert_rc "real single-quoted heredoc piped to bash still denies (HIMMEL-2322)" 2 "$RC"

# 34. HIMMEL-2322 CR round 1 (codex-2, DISPROVED - regression pin) - the
# panel claimed `cat <<EOF | env bash` reads as prose because `env` isn't
# bash/sh/zsh. It doesn't: strip_lead already strips the `env ` prefix
# before line_invokes_shell's own regex runs, so the segment reduces to
# `bash` and matches. Pinned so a future round can't "fix" this back into a
# hole.
run_case "$(j_bash "cat <<EOF | env bash
bash scripts/ci/run-shell-tests.sh
EOF")"
assert_rc "heredoc piped through env bash still denies (HIMMEL-2322)" 2 "$RC"

# 35. HIMMEL-2322 CR round 2 (codex-1, BLOCKING) - `source`/`.` genuinely
# execute a heredoc body too; they were missing from the shell-fed verb
# set, so a suite call inside one of these read as inert prose.
run_case "$(j_bash "source /dev/stdin <<EOF
bash scripts/ci/run-shell-tests.sh
EOF")"
assert_rc "source /dev/stdin heredoc denies (HIMMEL-2322 CR round 2)" 2 "$RC"

run_case "$(j_bash ". /dev/stdin <<EOF
bash scripts/ci/run-shell-tests.sh
EOF")"
assert_rc ". /dev/stdin heredoc denies (HIMMEL-2322 CR round 2)" 2 "$RC"

# 36. HIMMEL-2322 CR round 2 (codex-2, BLOCKING) - `<<END-MARK` is a real
# delimiter, but the old identifier-only charset captured just "END",
# never matched the "END-MARK" terminator, and (pre round-2 fail-closed
# fix) swallowed everything after it - including a real, separate bare
# suite call trailing the heredoc entirely.
run_case "$(j_bash "cat <<END-MARK > doc.md
prose
END-MARK
bash scripts/ci/run-shell-tests.sh")"
assert_rc "trailing real call after an END-MARK heredoc still denies (HIMMEL-2322 CR round 2)" 2 "$RC"

# 37. Same delimiter, but this time the ticket's actual goal: a suite-
# shaped PROSE line inside the (correctly terminated) heredoc body must
# still be stripped, not merely rendered harmless by the fail-closed net.
run_case "$(j_bash "cat <<END-MARK > doc.md
bash scripts/ci/run-shell-tests.sh scripts/hooks
END-MARK")"
assert_rc "END-MARK heredoc prose body still allows (HIMMEL-2322 CR round 2)" 0 "$RC"

# 38. HIMMEL-2322 CR round 2 (codex-3, BLOCKING) - a quoted heredoc-
# lookalike EARLIER on the same line as a REAL heredoc operator still
# mis-captures the delimiter (documented ceiling, see the comment above
# HEREDOC_INTRO_RE) - but the round-2 fail-closed posture means that
# mis-capture degrades to "strip nothing" rather than swallowing the real,
# separate bare suite call that follows.
run_case "$(j_bash "echo '<<FAKE' && cat <<'REAL' > doc.md
prose
REAL
bash scripts/ci/run-shell-tests.sh")"
assert_rc "quoted-then-real heredoc mis-capture still denies the trailing call (HIMMEL-2322 CR round 2)" 2 "$RC"

# 39. HIMMEL-2322 CR round 3 (codex-1, BLOCKING) - an UNQUOTED heredoc
# delimiter leaves the body subject to command substitution, which
# genuinely executes while bash builds the heredoc - regardless of
# shell_fed. `$(...)` and backtick forms both count.
run_case "$(j_bash "cat <<EOF > doc.md
\$(bash scripts/test-check-ci.sh)
EOF")"
assert_rc "unquoted-delimiter body with \$(...) denies (HIMMEL-2322 CR round 3)" 2 "$RC"

# shellcheck disable=SC2016  # the payload is literal shell text, not expanded here
run_case "$(j_bash 'cat <<EOF > doc.md
`bash scripts/test-check-ci.sh`
EOF')"
assert_rc "unquoted-delimiter body with backticks denies (HIMMEL-2322 CR round 3)" 2 "$RC"

# 40. A QUOTED or ESCAPED delimiter makes the body literal data - real bash
# never expands it, so it must stay allowed even though it contains the
# exact same \$(...) text as the denied case above.
run_case "$(j_bash "cat <<'EOF' > doc.md
\$(bash scripts/test-check-ci.sh)
EOF")"
assert_rc "single-quoted-delimiter body with \$(...) still allows (HIMMEL-2322 CR round 3)" 0 "$RC"

run_case "$(j_bash "cat <<\EOF > doc.md
\$(bash scripts/test-check-ci.sh)
EOF")"
assert_rc "escaped-delimiter body with \$(...) still allows (HIMMEL-2322 CR round 3)" 0 "$RC"

# 41. The ticket's original goal, unchanged: an unquoted-delimiter body
# with plain prose (nothing to expand) is still inert and still allowed.
run_case "$(j_bash "cat <<EOF > doc.md
bash scripts/test-check-ci.sh
EOF")"
assert_rc "unquoted-delimiter plain prose body still allows (HIMMEL-2322 CR round 3)" 0 "$RC"

# 42. Shell-fed path is unaffected by any of the above - a \$(...) body fed
# to bash directly still denies via the existing shell_fed=1 rule.
run_case "$(j_bash "cat <<EOF | bash
\$(bash scripts/test-check-ci.sh)
EOF")"
assert_rc "shell-fed heredoc with \$(...) body still denies (HIMMEL-2322 CR round 3)" 2 "$RC"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "All require-quiet-run.sh cases passed."
    exit 0
else
    echo "$FAILED case(s) failed."
    exit 1
fi
