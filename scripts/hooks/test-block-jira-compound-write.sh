#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016,SC2181 # compact status assertions; SC2016: raw-shape command strings are intentionally single-quoted literals.
# Tests for block-jira-compound-write.sh (HIMMEL-1077).
set -uo pipefail
# A CDPATH from the operator's shell would make the SCRIPT_DIR `cd` below resolve
# somewhere else (and print the target); unset it before any cd (coderabbit).
unset CDPATH
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/block-jira-compound-write.sh"
# Hermetic: an ambient bypass or CLI override from the operator's shell must not
# leak in — each is set explicitly by the tests that mean to exercise it.
unset JIRA_COMPOUND_WRITE_OK JIRA_CLI
# Synthetic absolute CLI path: the hook only pattern-matches command TEXT, it
# never executes the CLI — so the tests stay hermetic and do not depend on the
# untracked scripts/jira/dist/ build artifact existing in this checkout.
JIRA="/c/Users/x/himmel/scripts/jira/dist/index.js"

fails=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; fails=$((fails + 1)); }

ERR="$(mktemp)"
trap 'rm -f "$ERR"' EXIT

json_str() {  # json_str <text> — encode as a JSON string
  printf '%s' "$1" | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>process.stdout.write(JSON.stringify(d)))'
}

run_hook() {  # run_hook <tool_name> <command-string>
  printf '{"tool_name":"%s","tool_input":{"command":%s}}' "$1" "$(json_str "$2")" \
    | bash "$HOOK" >/dev/null 2>"$ERR"
  RC=$?
}

# --- 1. the incident shape: env-prefixed, ;-chained, $(…)-interpolated creates
run_hook Bash "JIRA_PROJECT_KEY=HIMMEL node $JIRA create --type Task --title \"a\" --desc \"\$(cat /tmp/a.md)\" ; node $JIRA create --type Task --title \"b\" --desc \"\$(cat /tmp/b.md)\""
[ "$RC" -eq 2 ] && pass "incident compound create bounced" || fail "incident shape not bounced (rc=$RC)"
grep -q -- "--desc-file" "$ERR" || fail "bounce message omits the --desc-file guidance"
grep -q "Write tool" "$ERR" || fail "bounce message omits the Write-tool guidance"

# --- 2. compound WITHOUT a jira write → untouched
run_hook Bash 'echo hello && ls -la /tmp | head -5'
[ "$RC" -eq 0 ] && pass "compound without jira allowed" || fail "non-jira compound bounced (rc=$RC)"

# --- 3. literal single jira write → untouched (the sanctioned shape)
run_hook Bash "node $JIRA create --type Task --title \"x\" --desc-file /tmp/b.md"
[ "$RC" -eq 0 ] && pass "literal jira create allowed" || fail "literal create bounced (rc=$RC)"

run_hook Bash "node $JIRA comment HIMMEL-1 --comment-file /tmp/c.md"
[ "$RC" -eq 0 ] && pass "literal jira comment allowed" || fail "literal comment bounced (rc=$RC)"

run_hook Bash "node $JIRA transition HIMMEL-1 Done"
[ "$RC" -eq 0 ] && pass "literal jira transition allowed" || fail "literal transition bounced (rc=$RC)"

# --- 4. cd-prefixed literal write → untouched (HIMMEL-205 sanctioned shape)
run_hook Bash "cd /c/Users/x/himmel && node $JIRA create --type Task --title \"x\" --desc-file /tmp/b.md"
[ "$RC" -eq 0 ] && pass "cd-prefixed literal create allowed" || fail "cd-prefixed create bounced (rc=$RC)"

# --- 5. heredoc-embedded create → bounced
run_hook Bash "cat > /tmp/b.md <<'EOF'
body line
EOF
node $JIRA create --type Task --title \"x\" --desc-file /tmp/b.md"
[ "$RC" -eq 2 ] && pass "heredoc-embedded create bounced" || fail "heredoc shape not bounced (rc=$RC)"

# --- 5.5 a heredoc BODY (or a comment) that merely MENTIONS the CLI is data, not
#         an invocation — documenting the command must not trip the guard
#         (codex-adv round 4, medium).
run_hook Bash "cat > /tmp/doc.md <<'EOF'
Run this to file a ticket:
node $JIRA create --type Task --title x
EOF"
[ "$RC" -eq 0 ] && pass "CLI text inside a heredoc body allowed" || fail "heredoc doc-body falsely bounced (rc=$RC)"

run_hook Bash "sudo apt install q ; echo ok  # node $JIRA create --title x"
[ "$RC" -eq 0 ] && pass "CLI text inside a comment allowed" || fail "comment falsely bounced (rc=$RC)"

# --- 5.7 CRLF heredoc: the delimiter must not capture the CR, or the closing
#         line never matches and the REST of the command (the real write) is
#         swallowed as body. Explicit — do not rely on this file's line endings.
crlf_cmd=$(printf 'cat > /tmp/b.md <<%sEOF%s\r\nbody\r\nEOF\r\nnode %s create --type Task --title x --desc-file /tmp/b.md' "'" "'" "$JIRA")
run_hook Bash "$crlf_cmd"
[ "$RC" -eq 2 ] && pass "CRLF heredoc + trailing write bounced" || fail "CRLF heredoc swallowed the write (rc=$RC)"

# --- 5.8 bash allows a TAB (not just a space) between << and the delimiter —
#         the body must still be recognised as data (panel round 6).
tab_cmd=$(printf 'cat > /tmp/doc.md <<\t%sEOF%s\nnode %s create --type Task --title x\nEOF' "'" "'" "$JIRA")
run_hook Bash "$tab_cmd"
[ "$RC" -eq 0 ] && pass "tab-separated heredoc delimiter parsed (body is data)" || fail "tab-delimited heredoc body scanned as code (rc=$RC)"

# --- 5.9 an UNQUOTED heredoc delimiter still expands substitutions, so a write
#         nested in the body really runs and must be seen; a QUOTED delimiter is
#         inert text and must not be (codex-adv round 6).
run_hook Bash "cat <<EOF
\$(node $JIRA create --type Task --title x)
EOF"
[ "$RC" -eq 2 ] && pass "write in an UNQUOTED heredoc body bounced" || fail "unquoted-heredoc write missed (rc=$RC)"

run_hook Bash "cat <<'EOF'
\$(node $JIRA create --type Task --title x)
EOF"
[ "$RC" -eq 0 ] && pass "same text in a QUOTED heredoc body allowed" || fail "quoted-heredoc doc text bounced (rc=$RC)"

# --- 5.95 shell operators bound tokens with or without cosmetic spaces
#          (codex-adv round 6): `;node`, `&&node`, `|node` all RUN node.
for op in ';' '|'; do
  run_hook Bash "echo ok${op}node $JIRA create --desc \"\$(cat /tmp/a.md)\""
  [ "$RC" -eq 2 ] || fail "write after a space-less '${op}' missed (rc=$RC)"
done
pass "writes adjacent to ; and | bounced without cosmetic spaces"

# CONDITIONAL writes are left alone (panel + codex round 14): this hook fires before
# either side has run, and "reissue as ONE literal command" strips the condition —
# filing a ticket exactly when the original wanted none (||) or when its prerequisite
# was never met (&&).
run_hook Bash "grep -q x /tmp/f || node $JIRA create --desc \"\$(cat /tmp/a.md)\""
[ "$RC" -eq 0 ] && pass "|| fallback write left alone" || fail "|| fallback write bounced (rc=$RC)"

run_hook Bash "test -f body && node $JIRA create --desc \"\$(cat body)\""
[ "$RC" -eq 0 ] && pass "&& prerequisite-gated write left alone" || fail "&& gated write bounced (rc=$RC)"

run_hook Bash "node $JIRA get HIMMEL-1 || node $JIRA create --desc \"\$(cat body)\""
[ "$RC" -eq 0 ] && pass "get-or-create fallback left alone" || fail "get||create bounced (rc=$RC)"

# A conditional whose RHS is a GROUP: the write never runs, and the `;` inside the
# group must not read as a fresh unconditional statement (codex round 20 [high]).
run_hook Bash "false && { echo skipped; node $JIRA create --desc \"\$(cat b)\"; }"
[ "$RC" -eq 0 ] && pass "grouped conditional RHS left alone" || fail "grouped conditional write bounced (rc=$RC)"

run_hook Bash "true || ( echo fallback; node $JIRA create --desc \"\$(cat b)\" )"
[ "$RC" -eq 0 ] && pass "grouped || fallback left alone" || fail "grouped || fallback bounced (rc=$RC)"

# UNREACHABLE after an unconditional `exit` (coderabbit [major]): everything past a
# bare `exit;` never runs, so bouncing the write and telling the agent to reissue
# standalone would file a ticket the command never would. The write BEFORE an exit
# is still reachable and must still bounce.
run_hook Bash "python setup.py; exit; node $JIRA create --type Task --title x --desc \"\$(cat body)\""
[ "$RC" -eq 0 ] && pass "write after unconditional exit (unreachable) left alone" || fail "unreachable-after-exit write bounced (rc=$RC)"

run_hook Bash "node $JIRA create --type Task --title x --desc \"\$(cat body)\"; exit"
[ "$RC" -eq 2 ] && pass "reachable write before exit still bounced" || fail "write before exit missed (rc=$RC)"

# ...and the WRAPPED/REDIRECTED unconditional-exit forms terminate too (coderabbit
# [major]): `command exit`, `builtin exit`, and an attached redirect `exit>/dev/null`
# all end the shell, so a later write stays unreachable and must not be bounced.
for term in "exit>/dev/null" "command exit" "builtin exit"; do
  run_hook Bash "$term; node $JIRA create --type Task --title x --desc \"\$(cat body)\""
  [ "$RC" -eq 0 ] || fail "write after '$term' (unreachable) bounced (rc=$RC)"
done
pass "wrapped/redirected unconditional exit truncates scanning"

# A canonical-RELATIVE CLI path after a `cd` (coderabbit [major]): the `cd` moves the
# CWD off this checkout, so resolving `scripts/jira/dist/index.js` to THIS checkout's
# primary CLI could redirect the write elsewhere or turn a would-fail command into a
# real ticket. Fail open. The no-cd relative form must still bounce (guidance names
# the primary CLI, the MODULE_NOT_FOUND-from-a-worktree fix).
run_hook Bash "cd /some/other/checkout && node scripts/jira/dist/index.js create --type Task --title x --desc \"\$(cat body)\""
[ "$RC" -eq 0 ] && pass "cd + relative-canonical CLI fails open (ambiguous cwd)" || fail "cd+relative-CLI resolved to primary (rc=$RC)"

run_hook Bash "node scripts/jira/dist/index.js create --type Task --title x --desc \"\$(cat body)\""
[ "$RC" -eq 2 ] && pass "relative-canonical CLI (no cd) still bounced" || fail "relative CLI no-cd not bounced (rc=$RC)"

# The UNCONDITIONAL part of such a statement is still in scope — including when the
# conditional RHS is a GROUP containing separators (panel round 21).
run_hook Bash "node $JIRA create --desc \"\$(cat /tmp/a.md)\" || echo failed"
[ "$RC" -eq 2 ] && pass "write BEFORE a || still bounced" || fail "pre-|| write missed (rc=$RC)"

run_hook Bash "node $JIRA create --desc \"\$(cat /tmp/a.md)\" || { echo failed; exit 1; }"
[ "$RC" -eq 2 ] && pass "write before a GROUPED || RHS still bounced" || fail "pre-|| write with grouped RHS missed (rc=$RC)"

# --- 5.96 delimiter quoting/closing follows bash exactly (panel round 8):
#          `<<\EOF` is quoted (inert body), and only `<<-` closes on a
#          TAB-indented delimiter — `  EOF` does NOT close a `<<EOF` body.
run_hook Bash "cat > /tmp/doc.md <<\\EOF
node $JIRA create --type Task --title x
EOF"
[ "$RC" -eq 0 ] && pass "backslash-escaped delimiter body is inert" || fail "<<\\EOF body scanned as code (rc=$RC)"

run_hook Bash "cat > /tmp/doc.md <<-'EOF'
	node $JIRA create --type Task --title x
	EOF"
[ "$RC" -eq 0 ] && pass "<<- closes on a tab-indented delimiter" || fail "<<- tab-indented close not recognised (rc=$RC)"

# A space-indented `  EOF` does NOT close a plain <<EOF: the write on the line
# after it is still heredoc BODY (inert here — quoted delimiter), so no bounce.
run_hook Bash "cat > /tmp/doc.md <<'EOF'
body
  EOF
node $JIRA create --type Task --title x
EOF"
[ "$RC" -eq 0 ] && pass "space-indented delimiter does not close the body early" || fail "premature heredoc close (rc=$RC)"

# --- 5.97 subshell grouping inside a substitution must not pop the substitution
#          frame early and re-mask the rest of it (coderabbit round 8).
run_hook Bash "key=\"\$( (node $JIRA create --type Task --title x) )\" ; echo \$key"
[ "$RC" -eq 2 ] && pass "write inside \$( (…) ) bounced" || fail "nested-paren substitution write missed (rc=$RC)"

# --- 5.98 a BROKEN gateway → fail open (coderabbit round 8). We cannot tell
#          "declined" from "crashed", and if nothing is approvable the bounce
#          would tell the agent to retry the shape it already used.
GW_TMP="$(mktemp -d)"
cp "$SCRIPT_DIR/block-jira-compound-write.sh" "$GW_TMP/"
# The stub records that it RAN: without that, an rc=0 could equally mean the hook
# exited before ever consulting the gateway, and the case would prove nothing.
printf '#!/usr/bin/env bash\ntouch "%s/called"\nexit 3\n' "$GW_TMP" > "$GW_TMP/auto-approve-safe-bash.sh"
printf '{"tool_name":"Bash","tool_input":{"command":"node %s create --desc \\"$(cat a)\\" ; echo x"}}' "$JIRA" \
  | bash "$GW_TMP/block-jira-compound-write.sh" >/dev/null 2>&1
gw_rc=$?
[ -f "$GW_TMP/called" ] || fail "broken-gateway case never reached the gateway (vacuous)"
[ "$gw_rc" -eq 0 ] && pass "broken gateway -> fail open" || fail "broken gateway caused a bounce (rc=$gw_rc)"
rm -rf "$GW_TMP"

# A delimiter line with TRAILING whitespace does not close either — the write on
# the next line is still inert body text, so it must not be bounced. Built with
# printf: a literal trailing space in this file would not survive editors/lint.
trail_cmd=$(printf 'cat > /tmp/doc.md <<%sEOF%s\nbody\nEOF \nnode %s create --type Task --title x\nEOF\n' "'" "'" "$JIRA")
run_hook Bash "$trail_cmd"
[ "$RC" -eq 0 ] && pass "trailing-space delimiter does not close the body" || fail "trailing-space delimiter closed early (rc=$RC)"

# A redirect TARGET is never mistaken for the command — including the case that
# matters, a file literally NAMED node (codex round 11 [high]; coderabbit round 11
# raised the same class). `printf x >node …/index.js create` runs PRINTF.
run_hook Bash "printf x >node $JIRA create"
[ "$RC" -eq 0 ] && pass "redirect to a file named 'node' not treated as a write" || fail "redirect target 'node' classified as a jira write (rc=$RC)"

run_hook Bash "sudo apt install q ; cat > /tmp/f node $JIRA create"
[ "$RC" -eq 0 ] && pass "redirect target + CLI args not treated as a write" || fail "redirect target classified as a jira write (rc=$RC)"

# ...while a redirect that really precedes the command keeps the command visible.
# (`;`, not `&&`: a conditional write is out of scope by design — see round 14.)
run_hook Bash "sudo apt install q ; >/tmp/out node $JIRA create --desc \"\$(cat a)\""
[ "$RC" -eq 2 ] && pass "leading redirect before a real write still bounced" || fail "leading-redirect write missed (rc=$RC)"

# An unrelated node CLI whose path merely ENDS LIKE ours is not himmel's Jira CLI:
# the gateway declines it (wrong path), and bouncing it would tell the agent to
# rerun its verb against the REAL Jira CLI — filing a ticket it never asked for
# (codex round 11 [high]).
run_hook Bash "sudo apt install q ; node /tmp/myjira/dist/index.js create --title x --desc \"\$(cat b)\""
[ "$RC" -eq 0 ] && pass "near-suffix non-himmel CLI path untouched" || fail "unrelated myjira CLI bounced (rc=$RC)"

run_hook Bash "node $JIRA create --title x --desc \"\$(cat a)\">/tmp/out"
[ "$RC" -eq 2 ] && pass "space-less redirect after a write still bounced" || fail "create>out missed (rc=$RC)"

# --- 5.99 two heredocs on one line queue two bodies; this scanner tracks one, so
#          it must refuse to guess rather than risk scanning inert text as code.
run_hook Bash "cat <<'A' <<B
node $JIRA create --title x
A
body
B"
[ "$RC" -eq 0 ] && pass "multi-heredoc command fails open (no wrong block)" || fail "multi-heredoc produced a bounce (rc=$RC)"

# --- 5.995 an ARRAY assignment builds data, it executes nothing: bouncing it would
#           push the agent to file a ticket the command never attempted (codex
#           round 12 [high]).
run_hook Bash "sudo apt install q ; args=(node $JIRA create --title x)"
[ "$RC" -eq 0 ] && pass "array assignment not treated as a write" || fail "array assignment bounced (rc=$RC)"

# --- 5.996 a CONDITIONAL write is left alone (codex round 13 [high]): the bounce
#           says "reissue as ONE literal command", which drops the condition and
#           would perform a write the original might never perform. Undetected =
#           status quo; wrong guidance = an unwanted ticket.
run_hook Bash "if test -f body; then node $JIRA create --desc \"\$(cat body)\"; fi"
[ "$RC" -eq 0 ] && pass "conditional write left alone (guidance cannot keep the condition)" || fail "conditional write bounced (rc=$RC)"

run_hook Bash "if node $JIRA create --desc \"\$(cat b)\"; then echo ok; fi"
[ "$RC" -eq 0 ] && pass "'if <write>' left alone" || fail "if-prefixed write bounced (rc=$RC)"

# MULTILINE conditionals: segments are flat, so a body line would otherwise read as
# an unconditional command and lose its condition (codex round 16 [high]).
run_hook Bash "if test -f body; then
  node $JIRA create --desc \"\$(cat body)\"
fi"
[ "$RC" -eq 0 ] && pass "multiline 'if' body write left alone" || fail "multiline if body bounced (rc=$RC)"

run_hook Bash "for f in a b; do
  node $JIRA create --desc \"\$(cat \$f)\"
done"
[ "$RC" -eq 0 ] && pass "loop body write left alone" || fail "loop body bounced (rc=$RC)"

run_hook Bash "case \$x in
  a) node $JIRA create --desc \"\$(cat b)\" ;;
esac"
[ "$RC" -eq 0 ] && pass "case-branch write left alone" || fail "case branch bounced (rc=$RC)"

# A function DEFINITION executes nothing — bouncing it would order a write the
# command never performed (codex round 13 [high]).
run_hook Bash "deploy() {
  node $JIRA create --desc \"\$(cat b)\"
}"
[ "$RC" -eq 0 ] && pass "function definition not treated as a write" || fail "function definition bounced (rc=$RC)"

# ...including the `function name { … }` spelling, which has no parens for the raw
# check to catch (panel round 15).
run_hook Bash "function deploy {
  node $JIRA create --desc \"\$(cat b)\"
}"
[ "$RC" -eq 0 ] && pass "'function name { }' definition not treated as a write" || fail "function-keyword definition bounced (rc=$RC)"

# The word 'function' as quoted DATA must not disarm a real write.
run_hook Bash "node $JIRA create --title \"fix function foo\" --desc \"\$(cat b)\""
[ "$RC" -eq 2 ] && pass "'function' inside a quoted title still bounces" || fail "quoted 'function' disarmed the guard (rc=$RC)"

# A grouped write after && stays out of scope (panel round 15 read this as a gap;
# quote_mask blanks the group parens, so the && truncation already covers it).
run_hook Bash "test -f b && (node $JIRA create --desc \"\$(cat b)\")"
[ "$RC" -eq 0 ] && pass "grouped write after && left alone" || fail "&&-grouped write bounced (rc=$RC)"

# A leading `{` must not hide the compound's keyword: `{ case … }` and
# `{ function f { … }; }` are still a conditional branch and a definition (codex
# round 24 [high]).
run_hook Bash "{ case x in y) echo skipped; node $JIRA create --desc \"\$(cat b)\" ;; esac; }"
[ "$RC" -eq 0 ] && pass "grouped 'case' branch left alone" || fail "grouped case branch bounced (rc=$RC)"

run_hook Bash "{ function f { node $JIRA create --desc \"\$(cat b)\"; }; }"
[ "$RC" -eq 0 ] && pass "grouped 'function' definition left alone" || fail "grouped function definition bounced (rc=$RC)"

# ...while unconditional wrappers/groupings DO run the command behind them.
run_hook Bash "{ node $JIRA create --desc \"\$(cat b)\"; }"
[ "$RC" -eq 2 ] && pass "write inside a brace group bounced" || fail "brace-group write missed (rc=$RC)"

run_hook Bash "! node $JIRA create --desc \"\$(cat b)\""
[ "$RC" -eq 2 ] && pass "write behind '!' bounced" || fail "'!'-prefixed write missed (rc=$RC)"

run_hook Bash "command node $JIRA create --desc \"\$(cat b)\""
[ "$RC" -eq 2 ] && pass "write behind 'command' bounced" || fail "command-wrapped write missed (rc=$RC)"

run_hook Bash "env JIRA_PROJECT_KEY=HIMMEL node $JIRA create --desc \"\$(cat b)\""
[ "$RC" -eq 2 ] && pass "write behind 'env K=V' bounced" || fail "env-wrapped write missed (rc=$RC)"

# ...but `command`/`nohup`/`exec` take a command NAME, not env assignments:
# `command FOO=1 node …` looks for a program named "FOO=1" and never runs node, so
# bouncing it would push a write the command never performed (panel round 16).
for w in command nohup exec; do
  run_hook Bash "$w JIRA_PROJECT_KEY=HIMMEL node $JIRA create --desc \"\$(cat b)\""
  [ "$RC" -eq 0 ] || fail "'$w VAR=v node …' bounced though node never runs (rc=$RC)"
done
pass "assignment after command/nohup/exec is not an env prefix"

# The same wrappers WITHOUT an assignment do run node.
run_hook Bash "nohup node $JIRA create --desc \"\$(cat b)\""
[ "$RC" -eq 2 ] && pass "write behind bare 'nohup' bounced" || fail "nohup-wrapped write missed (rc=$RC)"

# --- 5.997 only a VALID name= is an assignment: `foo-bar=1 node …` makes bash look
#           for a COMMAND named `foo-bar=1`, so node never runs (panel round 13).
run_hook Bash "foo-bar=1 node $JIRA create --desc \"\$(cat b)\""
[ "$RC" -eq 0 ] && pass "invalid assignment prefix is not skipped" || fail "foo-bar=1 prefix bounced (rc=$RC)"

# ...while a real assignment prefix still resolves to the command behind it.
run_hook Bash "JIRA_PROJECT_KEY=HIMMEL node $JIRA create --desc \"\$(cat b)\""
[ "$RC" -eq 2 ] && pass "valid assignment prefix still resolves to node" || fail "valid assignment prefix missed (rc=$RC)"

# --- 5.998 an array's ELEMENTS are data, but a substitution among them still runs
#           (coderabbit round 13).
run_hook Bash "args=(a \$(node $JIRA create --title x) b) ; echo \${args[0]}"
[ "$RC" -eq 2 ] && pass "write in a substitution inside an array bounced" || fail "array-substitution write missed (rc=$RC)"

# --- 5.999 an escaped SPACE belongs to the delimiter: `<<END\ MARK` is delimiter
#           `END MARK` and its body is inert. (Recording a short "END" would let a
#           body line "END" close early and expose inert text — a wrong block.)
esc_cmd=$(printf 'cat > /tmp/doc.md <<END\\ MARK\nnode %s create --title x\nEND MARK\n' "$JIRA")
run_hook Bash "$esc_cmd"
[ "$RC" -eq 0 ] && pass "escaped-space delimiter body is inert" || fail "escaped-space delimiter bounced (rc=$RC)"

# --- 5.9995 `<<''` is a legal EMPTY quoted delimiter: its body is inert, and the
#            "is a heredoc pending" test must not read the empty delimiter as
#            no-heredoc and scan the body as code (coderabbit round 15).
# `$( … )` strips TRAILING newlines, and here the delimiter IS an empty line — so a
# sentinel command after it keeps the fixture intact (coderabbit round 21).
empty_delim=$(printf "cat > /tmp/doc.md <<''\nnode %s create --type Task --title x\n\necho done\n" "$JIRA")
run_hook Bash "$empty_delim"
[ "$RC" -eq 0 ] && pass "empty quoted delimiter body is inert" || fail "<<'' body scanned as code (rc=$RC)"

# --- 5.9996 conditional scope covers the WHOLE statement, not just up to the next
#            pipe: `false && printf x | node … create` is conditional throughout
#            (coderabbit round 17).
run_hook Bash "false && printf x | node $JIRA create --desc \"\$(cat b)\""
[ "$RC" -eq 0 ] && pass "conditional pipeline left alone" || fail "conditional pipeline bounced (rc=$RC)"

# ...an UNCONDITIONAL pipeline into a write is still in scope.
run_hook Bash "printf x | node $JIRA create --desc \"\$(cat b)\""
[ "$RC" -eq 2 ] && pass "unconditional pipeline write bounced" || fail "unconditional pipeline missed (rc=$RC)"

# --- 5.9997 an escaped delimiter char belongs to the DELIMITER (coderabbit r17):
#            `<<END\;X` is delimiter `END;X`, and its body is inert.
esc2=$(printf 'cat > /tmp/doc.md <<END\\;X\nnode %s create --title x\nEND;X\n' "$JIRA")
run_hook Bash "$esc2"
[ "$RC" -eq 0 ] && pass "escaped-terminator delimiter body is inert" || fail "<<END\\;X body scanned as code (rc=$RC)"

# --- 5.9998 node options that consume a value must not have that value read as the
#            script — the real write behind them still bounces (coderabbit r17).
run_hook Bash "node --require /tmp/hook.js $JIRA create --desc \"\$(cat b)\""
[ "$RC" -eq 2 ] && pass "write behind 'node --require v' bounced" || fail "--require value read as script (rc=$RC)"

# --- 5.9999 the retry names the CLI that was ACTUALLY invoked when that path is
#            absolute: another checkout's CLI may front a different Jira, so echoing
#            our primary checkout's path back would redirect the write to the wrong
#            instance (panel round 18).
OTHER="/c/Users/x/other-repo/scripts/jira/dist/index.js"
run_hook Bash "node $OTHER create --title x --desc \"\$(cat b)\""
[ "$RC" -eq 2 ] && pass "other-checkout CLI still bounced" || fail "other-checkout CLI missed (rc=$RC)"
grep -qF "node $OTHER create" "$ERR" && pass "retry names the invoked CLI, not ours" || fail "retry redirected to a different checkout's CLI"

# --- 5.99901 a crafted CLI path carrying shell-active metacharacters has no safe
#             sanctioned shape: printed into the "do exactly this" guidance it would
#             invite the agent to run INJECTED shell ($(…), backticks, globs). Fail
#             open rather than emit dangerous guidance (coderabbit [major]).
INJ='/tmp/$(id)/scripts/jira/dist/index.js'
run_hook Bash "node $INJ create --title x --desc \"\$(cat b)\""
[ "$RC" -eq 0 ] && pass "shell-active CLI path fails open (no injected guidance)" || fail "shell-active CLI path bounced (rc=$RC)"
GLOBP='/tmp/x*/scripts/jira/dist/index.js'
run_hook Bash "node $GLOBP create --title x --desc \"\$(cat b)\""
[ "$RC" -eq 0 ] && pass "glob-metachar CLI path fails open" || fail "glob CLI path bounced (rc=$RC)"

# --- 5.99991 a QUOTED delimiter may contain spaces: `<<'END MARK'` is ONE delimiter,
#             and its body is inert. Recording a short "END" would let a body line
#             "END" close early and expose inert text (codex + coderabbit round 18).
mw=$(printf "cat > /tmp/doc.md <<'END MARK'\nnode %s create --title x\nEND\nEND MARK\n" "$JIRA")
run_hook Bash "$mw"
[ "$RC" -eq 0 ] && pass "quoted multi-word delimiter body is inert" || fail "<<'END MARK' body scanned as code (rc=$RC)"

# --- 5.99992 ARITHMETIC evaluates, it does not execute: CLI text inside `$((…))` or
#             `((…))` is data, and bouncing it would order a write the command never
#             ran (panel round 19; my round-18 disproof probed `$((1+2))`, which never
#             exercised the risk).
run_hook Bash "sudo apt install q ; x=\$((node $JIRA create))"
[ "$RC" -eq 0 ] && pass "CLI text inside \$((…)) not treated as a write" || fail "arithmetic expansion bounced (rc=$RC)"

run_hook Bash "sudo apt install q ; ((node $JIRA create))"
[ "$RC" -eq 0 ] && pass "CLI text inside ((…)) not treated as a write" || fail "arithmetic command bounced (rc=$RC)"

# ...while arithmetic ALONGSIDE a real write leaves the write in scope.
run_hook Bash "x=\$((1+2)) ; node $JIRA create --desc \"\$(cat b)\""
[ "$RC" -eq 2 ] && pass "write after arithmetic still bounced" || fail "arithmetic masked a real write (rc=$RC)"

# ...and a substitution around a SUBSHELL (`$( (…) )`) is still code.
run_hook Bash "key=\"\$( (node $JIRA create --title x) )\""
[ "$RC" -eq 2 ] && pass "\$( (…) ) subshell write still bounced" || fail "subshell write missed (rc=$RC)"

# --- 5.99993 arithmetic inside DOUBLE QUOTES / a heredoc body is still arithmetic
#             (codex round 19 [high]) — the same class as 5.99992, other states.
run_hook Bash "sudo apt install q ; x=\"\$((node $JIRA create))\""
[ "$RC" -eq 0 ] && pass "arithmetic inside double quotes not treated as a write" || fail "quoted arithmetic bounced (rc=$RC)"

run_hook Bash "cat <<EOF
\$((node $JIRA create))
EOF"
[ "$RC" -eq 0 ] && pass "arithmetic inside a heredoc body not treated as a write" || fail "heredoc arithmetic bounced (rc=$RC)"

# ...and a real substitution inside double quotes is still code (regression).
run_hook Bash "x=\"\$(node $JIRA create --title y)\""
[ "$RC" -eq 2 ] && pass "substitution inside double quotes still bounced" || fail "quoted substitution write missed (rc=$RC)"

# ...but a SUBSTITUTION among arithmetic operands still runs (coderabbit round 20).
run_hook Bash "x=\$(( \$(node $JIRA create --title y) + 1 ))"
[ "$RC" -eq 2 ] && pass "write in a substitution inside arithmetic bounced" || fail "arithmetic-substitution write missed (rc=$RC)"

# --- 5.99994 `()` inside a quoted TITLE is data, not a function definition: it must
#             not disable the guard on a real write (codex round 19 [medium]).
run_hook Bash "node $JIRA create --title 'Fix parse()' --desc \"\$(cat body)\""
[ "$RC" -eq 2 ] && pass "'()' in a quoted title does not disarm the guard" || fail "quoted '()' disabled the guard (rc=$RC)"

# --- 5.99995 a substitution BODY is its own command context: `echo "$(node … create)"`
#             really writes during expansion, even though the outer command is echo
#             (codex round 21).
run_hook Bash "echo \"\$(node $JIRA create --title y)\""
[ "$RC" -eq 2 ] && pass "write inside \$(…) as an ARGUMENT bounced" || fail "substitution-argument write missed (rc=$RC)"

run_hook Bash "echo \"\`node $JIRA create --title y\`\""
[ "$RC" -eq 2 ] && pass "write inside backticks as an argument bounced" || fail "backtick-argument write missed (rc=$RC)"

# An ASSIGNMENT-value substitution may still be followed by a real command:
# `FOO=$(date) node … create` (panel round 28) — unlike an argument substitution,
# whose tail is arguments.
run_hook Bash "FOO=\$(date) node $JIRA create --desc \"\$(cat b)\""
[ "$RC" -eq 2 ] && pass "write after an assignment-value substitution bounced" || fail "FOO=\$(…) node … create missed (rc=$RC)"

# PROCESS substitution runs its command too (panel round 26).
run_hook Bash "read k < <(node $JIRA create --title x)"
[ "$RC" -eq 2 ] && pass "write inside <(…) process substitution bounced" || fail "process-substitution write missed (rc=$RC)"

# ...but the OUTER command's own arguments after a substitution are still ARGUMENTS,
# not a new command: `echo "$(date)" node … create` runs ECHO (coderabbit round 24
# [critical] — a wrong block introduced by the round-21 boundary fix).
run_hook Bash "echo \"\$(date)\" node $JIRA create --title x"
[ "$RC" -eq 0 ] && pass "outer args after a substitution stay arguments" || fail "outer args read as a command (rc=$RC)"

# --- an ANSI-C quoted delimiter is not decoded here: fail open (coderabbit r24).
ansi=$(printf "cat > /tmp/doc.md <<\$'EOF'\nnode %s create --title x\nEOF\n" "$JIRA")
run_hook Bash "$ansi"
[ "$RC" -eq 0 ] && pass "ANSI-C quoted delimiter fails open" || fail "<<\$'EOF' bounced (rc=$RC)"

# --- 5.99996 `${…}` text is DATA: a `;` inside must not split off a bogus command
#             that reads as a real write (coderabbit round 21).
run_hook Bash "sudo apt install q ; echo \${x:-a; node $JIRA create --title y}"
[ "$RC" -eq 0 ] && pass "\${…} expansion text not treated as a write" || fail "parameter expansion bounced (rc=$RC)"

# --- 5.99997 `&>` / `&>>` / `>&` are REDIRECTS, not separators: `printf &>/tmp/log
#             node … create …` runs PRINTF and passes the rest as arguments (codex
#             round 22 [high]).
run_hook Bash "printf x &>/tmp/log node $JIRA create --desc-file /tmp/b.md"
[ "$RC" -eq 0 ] && pass "&> redirect target not treated as a command" || fail "&> redirect bounced (rc=$RC)"

run_hook Bash "printf x &>>/tmp/log node $JIRA create --desc-file /tmp/b.md"
[ "$RC" -eq 0 ] && pass "&>> redirect target not treated as a command" || fail "&>> redirect bounced (rc=$RC)"

# ...while a real write with an fd-dup redirect still bounces.
run_hook Bash "node $JIRA create --desc \"\$(cat b)\" 2>&1"
[ "$RC" -eq 2 ] && pass "write with 2>&1 still bounced" || fail "fd-dup masked a real write (rc=$RC)"

# ...and a LEADING fd-descriptor redirect (`2>out node … create`) binds to the
# redirect — the `2` is an fd designator, not the command, so node still runs and
# the interpolated write must bounce, not slip past unbounced (codex panel).
for pre in "2>/tmp/x" "1>/tmp/x" ">/tmp/x" "2>&1"; do
  run_hook Bash "$pre node $JIRA create --type Task --title t --desc \"\$(cat /tmp/a.md)\""
  [ "$RC" -eq 2 ] || fail "leading redirect '$pre' let a real write slip past (rc=$RC)"
done
pass "leading fd-descriptor redirect does not mask a real interpolated write"
# ...but a bare integer that is NOT an fd redirect stays the command (node never
# runs): `2 node … create` looks for a program named `2`, so nothing is bounced.
run_hook Bash "2 node $JIRA create --title t --desc-file /tmp/b.md"
[ "$RC" -eq 0 ] && pass "bare integer command (no redirect) left alone" || fail "bare '2' misread as fd redirect (rc=$RC)"

# `>|` (clobber) and `<&` (fd-dup) are redirects too — their `|`/`&` must not split
# the tail into a fresh command (coderabbit). printf runs, node is just args.
run_hook Bash "printf x >|/tmp/log node $JIRA create --desc-file /tmp/b.md"
[ "$RC" -eq 0 ] && pass ">| redirect target not treated as a command" || fail ">| redirect bounced (rc=$RC)"
run_hook Bash "printf x <&3 node $JIRA create --desc-file /tmp/b.md"
[ "$RC" -eq 0 ] && pass "<& redirect target not treated as a command" || fail "<& redirect bounced (rc=$RC)"
# ...and a real write carrying these redirects still bounces.
run_hook Bash "node $JIRA create --desc \"\$(cat b)\" >|/tmp/log"
[ "$RC" -eq 2 ] && pass "write with >| redirect still bounced" || fail ">| masked a real write (rc=$RC)"

# --- 5.99998 the retry must not tell the agent to DROP targeting options: `create
#             --project CUSTOMER` retried without it files in the wrong project
#             (codex round 22 [high]).
run_hook Bash "node $JIRA create --project CUSTOMER --desc \"\$(cat body)\""
[ "$RC" -eq 2 ] && pass "create with --project override bounced" || fail "--project create missed (rc=$RC)"
grep -q "do not pass --project" "$ERR" && fail "guidance tells the retry to drop --project"
grep -q "keep everything else you already had" "$ERR" && pass "guidance preserves targeting options" || fail "guidance omits keep-your-arguments"

# ...including an env-var prefix: `JIRA_PROJECT_KEY=OTHER node … create` retried
# without it files in the DEFAULT project (coderabbit round 27).
run_hook Bash "JIRA_PROJECT_KEY=OTHER node $JIRA create --desc \"\$(cat body)\""
[ "$RC" -eq 2 ] && pass "env-prefixed create bounced" || fail "env-prefixed create missed (rc=$RC)"
grep -q "JIRA_PROJECT_KEY" "$ERR" && pass "guidance preserves a VAR=value prefix" || fail "guidance drops the env prefix"

# --- 5.99999 node MODES that never run the script write nothing: bouncing them would
#             recommend a literal invocation that DOES (codex round 28 [high]).
for mode in --check --version --help; do
  run_hook Bash "node $mode $JIRA create --desc \"\$(cat b)\""
  [ "$RC" -eq 0 ] || fail "'node $mode <cli> create' bounced though node runs nothing (rc=$RC)"
done
pass "node --check/--version/--help are not writes"

# --- 5.999991 a NON-canonical relative CLI path dies MODULE_NOT_FOUND and writes
#              nothing — naming the real primary CLI would turn a typo into a filed
#              ticket (codex round 28 [high]).
run_hook Bash "node bogus/scripts/jira/dist/index.js create --desc \"\$(cat body)\""
[ "$RC" -eq 0 ] && pass "non-canonical relative CLI path fails open" || fail "typo'd relative path bounced (rc=$RC)"

# ...while the canonical relative form still resolves to this checkout's CLI.
run_hook Bash "node scripts/jira/dist/index.js create --desc \"\$(cat body)\""
[ "$RC" -eq 2 ] && pass "canonical relative CLI path bounced" || fail "canonical relative path missed (rc=$RC)"
grep -qE "^    node (/|[A-Za-z]:|<primary-checkout>)" "$ERR" && pass "relative path resolved to an absolute retry" || fail "relative retry not resolved"

# --- 6. jira READ verbs are never bounced, compound or not
run_hook Bash "node $JIRA get HIMMEL-1 | head -5"
[ "$RC" -eq 0 ] && pass "compound jira read allowed" || fail "jira read bounced (rc=$RC)"

run_hook Bash "node $JIRA list --jql \"project = HIMMEL\" > /tmp/out.txt"
[ "$RC" -eq 0 ] && pass "redirected jira read allowed" || fail "jira read with redirect bounced (rc=$RC)"

# --- 7. the write verb must be the jira VERB, not incidental text
run_hook Bash "grep -rn 'jira/dist/index.js create' scripts/ && echo done"
[ "$RC" -eq 0 ] && pass "write verb inside a grep pattern allowed" || fail "quoted verb false-positive (rc=$RC)"

run_hook Bash "node $JIRA get HIMMEL-1 && echo create"
[ "$RC" -eq 0 ] && pass "write verb as a later unrelated arg allowed" || fail "non-verb 'create' bounced (rc=$RC)"

# --- 7.5 the CLI must be the script `node` RUNS, not a path passed as an
#         argument (codex-1 round 4): otherwise a non-jira command carrying the
#         path + a write verb would be falsely bounced with jira guidance.
run_hook Bash "sudo apt install q ; cp $JIRA create"
[ "$RC" -eq 0 ] && pass "CLI path as a bare argument allowed" || fail "non-node command falsely bounced (rc=$RC)"

run_hook Bash "sudo apt install q ; node -e \"require('fs')\" $JIRA create"
[ "$RC" -eq 0 ] && pass "node -e with CLI path as later arg allowed" || fail "node -e false-positive (rc=$RC)"

# The `=`-glued inline-code forms run the attached code; the CLI path is a mere
# argv entry, so no write happens and the command must NOT bounce (codex-1).
run_hook Bash "node --eval='require(1)' $JIRA create --desc \"\$(cat b)\""
[ "$RC" -eq 0 ] && pass "node --eval=<code> with CLI path as arg allowed" || fail "--eval= form false-positive (rc=$RC)"
run_hook Bash "node --print='1+1' $JIRA create --desc \"\$(cat b)\""
[ "$RC" -eq 0 ] && pass "node --print=<code> with CLI path as arg allowed" || fail "--print= form false-positive (rc=$RC)"

# `node --run <script>` executes a package.json script; the CLI path after it is a
# mere arg, so no write happens and the command must NOT bounce (codex-adv). Both
# the space and `=`-glued spellings.
run_hook Bash "node --run build $JIRA create --desc \"\$(cat b)\""
[ "$RC" -eq 0 ] && pass "node --run <script> with CLI path as arg allowed" || fail "--run form false-positive (rc=$RC)"
run_hook Bash "node --run=build $JIRA create --desc \"\$(cat b)\""
[ "$RC" -eq 0 ] && pass "node --run=<script> with CLI path as arg allowed" || fail "--run= form false-positive (rc=$RC)"

# An option BEFORE the verb makes the CLI invocation uncertain — the CLI takes
# options after the verb, so a pre-verb option is either unknown (the CLI errors,
# writing nothing) or value-consuming (it swallows the verb). Fail open rather
# than bounce a command that may never write (coderabbit [critical]). The no-
# pre-verb-option form must still bounce.
run_hook Bash "node $JIRA --invalid create --title x --desc \"\$(cat b)\""
[ "$RC" -eq 0 ] && pass "pre-verb option fails open (uncertain invocation)" || fail "pre-verb option bounced (rc=$RC)"
run_hook Bash "node $JIRA create --title x --desc \"\$(cat b)\""
[ "$RC" -eq 2 ] && pass "no pre-verb option still bounces" || fail "plain create not bounced (rc=$RC)"

# `node` must be the command the segment EXECUTES, not a word inside it
# (coderabbit round 10) — `echo node … create` runs echo.
run_hook Bash "sudo apt install q ; echo node $JIRA create --title x"
[ "$RC" -eq 0 ] && pass "'node …' as echo ARGUMENTS allowed" || fail "non-command-position node bounced (rc=$RC)"

# --- 8. chaining is not itself the sin: a chain the auto-approve gateway
#        already sanctions keeps working (bouncing it would be a regression).
run_hook Bash "git status && node $JIRA transition HIMMEL-1 Done"
[ "$RC" -eq 0 ] && pass "gateway-safe chain allowed" || fail "gateway-safe chain bounced (rc=$RC)"

#        An &&-gated write the gateway declines is ALSO left alone — not because it
#        is approvable, but because the guidance cannot preserve the gate (round 14).
run_hook Bash "sudo apt install q && node $JIRA transition HIMMEL-1 Done"
[ "$RC" -eq 0 ] && pass "&&-gated write after an unvettable command left alone" || fail "&&-gated chain bounced (rc=$RC)"

#        The unconditional equivalent — the incident's own `;` shape — bounces.
run_hook Bash "sudo apt install q ; node $JIRA transition HIMMEL-1 \"\$(cat /tmp/s)\""
[ "$RC" -eq 2 ] && pass "unconditional ;-chained write bounced" || fail "unconditional chain not bounced (rc=$RC)"

# --- 9. bypass env var
JIRA_COMPOUND_WRITE_OK=1 run_hook Bash "node $JIRA create --title \"a\" --desc \"\$(cat /tmp/a.md)\" ; echo done"
[ "$RC" -eq 0 ] && pass "JIRA_COMPOUND_WRITE_OK bypass" || fail "bypass ignored (rc=$RC)"

# --- 10. non-Bash tools are none of this hook's business
run_hook PowerShell "node $JIRA create --title a --desc \"\$(cat x)\" ; echo hi"
[ "$RC" -eq 0 ] && pass "PowerShell input ignored" || fail "PowerShell input bounced (rc=$RC)"

# --- 11. exactly ONE sanctioned retry shape is named (HIMMEL-1077 comment:
#         retry sequences must not look like tool-shopping to the classifier)
run_hook Bash "node $JIRA create --type Task --title \"x\" --desc \"\$(cat /tmp/a.md)\""
[ "$RC" -eq 2 ] && pass "single command with \$(…) bounced" || fail "command-substitution write not bounced (rc=$RC)"
[ "$(grep -c '^    node ' "$ERR")" -eq 1 ] && pass "bounce names exactly one retry shape" || fail "bounce names $(grep -c '^    node ' "$ERR") retry shapes (want 1)"

# --- 11.5 the retry example names the verb the agent ACTUALLY used (codex-adv
#          round 4, high): printing a `create` example for a blocked `assign`
#          invites the retry to FILE A TICKET instead of assigning — a wrong
#          external write caused by our own guidance.
for verb in transition assign edit move watch unwatch link attach project-create sprint; do
  run_hook Bash "node $JIRA $verb HIMMEL-1 --x \"\$(cat /tmp/a.md)\""
  grep -q "^    node .* $verb " "$ERR" || fail "retry example for '$verb' does not name that verb"
  grep -q "^    node .* create " "$ERR" && fail "retry example for '$verb' suggests 'create'"
done
pass "retry example names the detected verb, never substitutes create"

# ...including the two-word `worklog add` verb (coderabbit): its retry example must
# name the full verb, never collapse to a bare `worklog` or substitute `create`.
run_hook Bash "node $JIRA worklog add HIMMEL-1 --x \"\$(cat /tmp/a.md)\""
grep -q "^    node .* worklog add " "$ERR" && pass "retry example names 'worklog add'" || fail "retry example drops 'worklog add'"
grep -q "^    node .* create " "$ERR" && fail "retry example for 'worklog add' suggests 'create'"

run_hook Bash "node $JIRA comment HIMMEL-1 \"\$(cat /tmp/a.md)\""
grep -q -- "--comment-file" "$ERR" && pass "comment bounce names --comment-file" || fail "comment bounce lacks --comment-file"

# --- 12. every MUTATING verb on the CLI's command surface is covered; reads are
#         not (codex-adv-2). `worklog add` writes, `worklog list` reads.
for verb in create comment transition edit link assign move watch unwatch attach project-create sprint; do
  run_hook Bash "node $JIRA $verb HIMMEL-1 --desc \"\$(cat /tmp/a.md)\""
  [ "$RC" -eq 2 ] || fail "write verb '$verb' not bounced (rc=$RC)"
done
pass "all write verbs bounced in a fall-through shape"

run_hook Bash "node $JIRA worklog add HIMMEL-1 --time \"\$(cat /tmp/t)\""
[ "$RC" -eq 2 ] && pass "nested 'worklog add' bounced" || fail "worklog add not bounced (rc=$RC)"

for verb in get list transitions transition_typo projects attachments watchers boards sprints; do
  run_hook Bash "node $JIRA $verb HIMMEL-1 --x \"\$(cat /tmp/a.md)\""
  [ "$RC" -eq 0 ] || fail "read verb '$verb' bounced (rc=$RC)"
done
run_hook Bash "node $JIRA worklog list HIMMEL-1 --x \"\$(cat /tmp/a.md)\""
[ "$RC" -eq 0 ] && pass "read verbs (incl. 'worklog list') left alone" || fail "worklog list bounced (rc=$RC)"

# --- 13. the retry shape names the PRIMARY checkout's ABSOLUTE CLI path
#         (codex-adv-1): `dist/` is untracked, so a relative path run from a
#         linked worktree dies MODULE_NOT_FOUND — a bounce whose "do exactly
#         this" command cannot run is what provokes retry-across-shapes.
FAKE_ROOT="$(mktemp -d)"
mkdir -p "$FAKE_ROOT/scripts/jira/dist"
: > "$FAKE_ROOT/scripts/jira/dist/index.js"
JIRA_CLI="$FAKE_ROOT/scripts/jira/dist/index.js" \
  run_hook Bash "node $JIRA create --title \"x\" --desc \"\$(cat /tmp/a.md)\""
[ "$RC" -eq 2 ] && pass "bounce still fires with a resolved CLI" || fail "resolved-CLI bounce missing (rc=$RC)"
grep -qF "node $FAKE_ROOT/scripts/jira/dist/index.js create" "$ERR" \
  && pass "retry shape names the resolved absolute CLI path" \
  || fail "retry shape does not name the resolved absolute path"
rm -rf "$FAKE_ROOT"

# Default resolution (no seam): the named path must be ABSOLUTE — never the
# bare relative `scripts/jira/dist/index.js` that breaks from a worktree.
# The `<primary-checkout>` placeholder is ACCEPTED on purpose: `dist/` is an
# untracked build artifact, so a fresh clone / CI checkout legitimately resolves
# no CLI and falls back to the generic shape. (Strict absolute-path assertion is
# the seam test above, which is hermetic.) Rejecting the placeholder here would
# make this test green only on machines that happen to have built the CLI.
run_hook Bash "node $JIRA create --title \"x\" --desc \"\$(cat /tmp/a.md)\""
suggested=$(grep -o 'node [^ ]*jira/dist/index.js create' "$ERR" | head -1 | awk '{print $2}')
case "$suggested" in
  # `C:foo` is drive-RELATIVE, not absolute — it must reach the failure branch.
  /*|[A-Za-z]:[/\\]*|'<primary-checkout>'*) pass "suggested CLI path is absolute (${suggested})" ;;
  *) fail "suggested CLI path is relative: '${suggested}'" ;;
esac

# --- 13.5 a write NESTED IN a substitution is code, not data (coderabbit-2):
#          `key="$(… create …)"` is the realistic capture-the-new-key shape and
#          must still bounce, even though it sits inside double quotes.
run_hook Bash "key=\"\$(node $JIRA create --type Task --title \"x\" --desc-file /tmp/b.md)\" ; echo \$key"
[ "$RC" -eq 2 ] && pass "write inside \$(…) in double quotes bounced" || fail "substitution-nested write missed (rc=$RC)"

run_hook Bash "key=\"\`node $JIRA create --type Task --title x --desc-file /tmp/b.md\`\" ; echo \$key"
[ "$RC" -eq 2 ] && pass "write inside backticks in double quotes bounced" || fail "backtick-nested write missed (rc=$RC)"

#          ...but DATA inside a substitution is still data — no false positive.
run_hook Bash "hits=\"\$(grep -rn 'jira/dist/index.js create' scripts/)\" ; echo \$hits"
[ "$RC" -eq 0 ] && pass "quoted data inside a substitution allowed" || fail "data-in-substitution false-positive (rc=$RC)"

# --- 14. a QUOTED CLI path stays silent, deliberately (codex-1, HIMMEL-1083):
#         the gateway cannot vet a quoted binary either, so a whitespace-path
#         checkout has NO approvable jira shape — bouncing it would hand the
#         agent advice it has already followed. Fail open = status quo, never a
#         wrong block.
run_hook Bash "node \"/c/Users/John Smith/himmel/scripts/jira/dist/index.js\" create --desc \"\$(cat /tmp/a.md)\" ; echo x"
[ "$RC" -eq 0 ] && pass "quoted CLI path stays silent (documented gap)" || fail "quoted CLI path bounced with unactionable guidance (rc=$RC)"

# --- 15. missing dependencies (jq/cat) → FAIL OPEN. A guard that only improves a
# denial message must never be the reason a sanctioned write cannot run.
#
# Run the REAL bash by absolute path (resolved BEFORE the PATH override, so the
# interpreter still finds its own libraries — a copied bash.exe cannot start on
# Windows) with an empty PATH, so the hook's external deps are unreachable. The
# copy-binaries-into-a-stub-dir approach the sibling suites use degrades to a
# permanent silent SKIP here (`command -v printf` returns the BUILTIN, the cp
# fails) and, once that is fixed, to a broken interpreter — so it never actually
# tested anything on this platform (coderabbit-2).
BASH_ABS="$(command -v bash)"
EMPTY_PATH_DIR="$(mktemp -d)"   # guaranteed to exist AND be empty, unlike /nonexistent
printf '{"tool_name":"Bash","tool_input":{"command":"node %s create --desc \\"$(cat a)\\" ; echo x"}}' "$JIRA" \
  | PATH="$EMPTY_PATH_DIR" "$BASH_ABS" "$HOOK" >/dev/null 2>&1
deps_rc=$?   # capture BEFORE the assertion: `$?` inside it reports the test, not the hook
[ "$deps_rc" -eq 0 ] && pass "no deps at all -> fail open" || fail "missing deps bricked the write (rc=$deps_rc)"

# ...and jq specifically, with everything else present: that is the branch the hook
# actually guards, and the all-deps-gone case alone would not prove it (coderabbit
# round 28). A stub dir shadowing only jq keeps the real PATH behind it.
JQ_SHADOW="$(mktemp -d)"
printf '#!/usr/bin/env bash\nexit 127\n' > "$JQ_SHADOW/jq"   # present but unusable
chmod +x "$JQ_SHADOW/jq" 2>/dev/null
printf '{"tool_name":"Bash","tool_input":{"command":"node %s create --desc \\"$(cat a)\\" ; echo x"}}' "$JIRA" \
  | PATH="$JQ_SHADOW:$PATH" "$BASH_ABS" "$HOOK" >/dev/null 2>&1
jq_rc=$?
[ "$jq_rc" -eq 0 ] && pass "broken jq -> fail open" || fail "broken jq bricked the write (rc=$jq_rc)"
rm -rf "$JQ_SHADOW"
rmdir "$EMPTY_PATH_DIR" 2>/dev/null || rm -rf "$EMPTY_PATH_DIR"

echo
if [ "$fails" -gt 0 ]; then echo "$fails failure(s)" >&2; exit 1; fi
echo "all tests passed"
