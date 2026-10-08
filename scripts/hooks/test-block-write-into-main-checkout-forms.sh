#!/usr/bin/env bash
# Shard of test-block-write-into-main-checkout.sh (HIMMEL-4164 split, so each
# suite stays under its CI per-suite cap): the shell-form rows (zsh/ANSI-C,
# assignment prefixes, nested heredocs, arithmetic/array values, prefix words,
# ~/ redirects; HIMMEL-4138..4253) and the non-command payloads.
# Same fixtures + harness as the parent suite via lib-test-write-fence.sh;
# the FIXTURE RULE lives in test-block-write-into-main-checkout.sh.
# shellcheck disable=SC2154  # pass/fail are defined by the sourced lib
# shellcheck source=lib-test-write-fence.sh
. "$(dirname "$0")/lib-test-write-fence.sh"

# HIMMEL-4138: four gaps J1661 execution-verified on #1661, plus a fifth found
# alongside (an ANSI-C NUL ends the name early). Every DENY row writes into the
# primary under real bash or zsh (zsh is Claude Code's own Bash-tool shell).
# Where the shells disagree the hook denies when EITHER reading writes, so a
# few rows aimed at the worktree deny too — that is the fail-closed rule, not
# an accident. Templates: @P@ = the primary, @W@ = the worktree, \n = newline.
_r4138() { # label verdict template
    local c="$3"
    c="${c//@P@/$_PR}"; c="${c//@W@/$_WR}"; c="${c//\\n/$'\n'}"; c="${c//\\t/$'\t'}"
    _subst_row "$1" "$2" "$c"
}
echo "== HIMMEL-4138 zsh \$\$', comments in substitutions, wrapped shells, \\x{…} and NUL =="
# shellcheck disable=SC2016,SC1003  # row templates are literal shell text
{
# (1) zsh opens ANSI-C at a `'` right after `$`, even the second `$` of `$$`.
_r4138 "77a echo \$\$'\\'' then a redirect into the primary"          block 'echo $$'"'"'\'"'"''"'"' > @P@/f'
_r4138 "77b x=\$\$\$\$'\\''; touch primary"                            block 'x=$$$$'"'"'\'"'"''"'"'; touch @P@/f'
_r4138 "77c \$\$'\\'' inside a dq-quoted body"                         block 'x="$(echo $$'"'"'\'"'"''"'"' > @P@/f)"'
_r4138 "77d \$\$'\\'' aimed at the worktree (ambiguous: fail closed)"  block 'echo $$'"'"'\'"'"''"'"' > @W@/f'
_r4138 "77e \$\$'\\'' inside bash -c"                                  block 'bash -c "echo \$\$'"'"'\\'"'"''"'"' > @W@/f; touch @P@/f"'
_r4138 "77f \$\$'abc' with no backslash reads the same (ALLOW)"        allow 'echo $$'"'"'abc'"'"' > @W@/f'
_r4138 "77g \$\$\$'\\'' is ANSI-C in both shells (ALLOW)"               allow 'echo $$$'"'"'\'"'"''"'"' > @W@/f'
# (2) A comment inside a command substitution hides a quote from the scan.
_r4138 "78a comment with a quote inside \$(…)"                         block 'x=$(echo hi # it'"'"'s\n); touch @P@/f'
_r4138 "78b comment with a quote inside a dq-quoted \$(…)"             block 'x="$(echo hi # it'"'"'s\n)"; touch @P@/f'
_r4138 "78c comment with a quote inside backticks"                     block 'x=`echo hi # it'"'"'s\n`; touch @P@/f'
_r4138 "78d top-level comments pairing a quote around a write"         block ': # '"'"'\necho x > @P@/f\n: # '"'"''
# 78e (a comment in $(…) in a multi-line bash -c body) sits with the
# HIMMEL-4143 rows below. 78p: the body newline now reaches the body scan as a
# real newline, which splits the body there.
_r4138 "78p bash -c body with a newline before a write (HIMMEL-4143)"  block 'bash -c "echo hi\ntouch @P@/f"'
# The strip copies a heredoc body through verbatim (speed); a shift is no opener.
_r4138 "78q ((x<<2)) is a shift, comment pair still stripped"            block '((x<<2))\n# '"'"'\necho x > @P@/f\n# '"'"'\n2'
_r4138 "78r \$[x<<2] is a shift, comment pair still stripped"            block 'echo $[1<<2]\n# '"'"'\necho x > @P@/f\n# '"'"'\n2'
_r4138 "78s heredoc body with a commented quote in \$(…), then a write"  block 'x=$(cat <<E\n# it'"'"'s\nE\n); touch @P@/f'
_r4138 "78u quoted heredoc terminator, then a write"                     block 'x=$(cat <<'"'"'E'"'"'\n# '"'"'\nE\n); echo x > @P@/f'
_r4138 "78v backslashed heredoc terminator, then a write"                block 'x=$(cat <<\E\n# '"'"'\nE\n); echo x > @P@/f'
_r4138 "78w <<- heredoc with tab-indented terminator, then a write"     block 'x=$(cat <<-E\n\t# it'"'"'s\n\tE\n); touch @P@/f'
_r4138 "78x near-miss terminator line, then a write"                     block 'x=$(cat <<E\n# '"'"'\nEE\n); echo x > @P@/f'
_r4138 "78y comment after the opener, then a write"                      block 'x=$(cat <<E # c\n# '"'"'\nE\n); echo x > @P@/f'
_r4138 "78t worktree heredoc commit with # and quotes (ALLOW)"           allow 'git -C @W@ commit -m "$(cat <<'"'"'EOF'"'"'\nfix: x\n\n# it'"'"'s (#12) done\nEOF\n)"'
_r4138 "78f comment inside \$(…), worktree target (ALLOW)"             allow 'x=$(echo hi # it'"'"'s\n); touch @W@/f'
_r4138 "78g a write inside a comment still denies (either reading)"    block 'echo hi # > @P@/f'
_r4138 "78h \$(true)#a is a word, not a comment"                       block 'echo $(true)#a > @P@/f'
_r4138 "78i \${x:- #} is a word, not a comment"                        block 'echo ${x:- #} > @P@/f'
_r4138 "78j a#b is a word (ALLOW)"                                     allow 'echo a#b > @W@/f'
_r4138 "78k \${#x} and \$((16#1f)) are not comments (ALLOW)"           allow 'echo ${#x} $((16#1f)) > @W@/f'
# (3) A wrapper before the shell or eval used to skip the body scan.
for _w in 'nice' 'timeout 5' 'nohup' 'env FOO=1' 'FOO=1' 'sudo -n' 'setsid' 'xargs' 'stdbuf -o0' 'ionice -c3' 'command' 'exec'; do
    _r4138 "79-$_w bash -c write into the primary"                    block "$_w bash -c 'echo x > @P@/f'"
    _r4138 "79-$_w bash -c write into the worktree (ALLOW)"           allow "$_w bash -c 'echo x > @W@/f'"
done
_r4138 "79a command eval write into the primary"                       block "command eval 'echo x > @P@/f'"
_r4138 "79b flock -c write into the primary"                           block "flock /tmp/l -c 'echo x > @P@/f'"
_r4138 "79c su -c write into the primary"                              block "su -c 'echo x > @P@/f'"
_r4138 "79d builtin eval write into the worktree (ALLOW)"              allow "builtin eval 'echo x > @W@/f'"
_r4138 "79e a quoted 'nice bash -c' in a commit message (ALLOW)"       allow "git -C @W@ commit --allow-empty -m 'nice bash -c x'"
_r4138 "79f nice 'bash' -c (a quoted shell name) into the primary"     block "nice 'bash' -c 'echo x > @P@/f'"
_r4138 "79g nice ba''sh -c into the primary"                           block "nice ba''sh -c 'echo x > @P@/f'"
_r4138 "79h nice b\\ash -c into the primary"                           block "nice b\\ash -c 'echo x > @P@/f'"
_r4138 "79i 'bash' -c with no wrapper into the primary"                block "'bash' -c 'echo x > @P@/f'"
_r4138 "79j nice 'eval' into the primary"                              block "nice 'eval' 'echo x > @P@/f'"
_r4138 "79k nice 'bash' -c into the worktree (ALLOW)"                  allow "nice 'bash' -c 'echo x > @W@/f'"
# J1672: a \$'…' or \$\"…\" spelling of the shell name (bash and zsh decode it).
_r4138 "79l nice \$'bash' -c into the primary"                         block "nice \$'bash' -c 'touch @P@/x'"
_r4138 "79m env \$'sh' -c into the primary"                            block "env \$'sh' -c 'touch @P@/x'"
_r4138 "79n timeout 5 \$'bash' -c into the primary"                    block "timeout 5 \$'bash' -c 'touch @P@/x'"
_r4138 "79o nice ba\$'sh' -c into the primary"                         block "nice ba\$'sh' -c 'touch @P@/x'"
_r4138 "79p nice /bin/\$'bash' -c into the primary"                    block "nice /bin/\$'bash' -c 'touch @P@/x'"
_r4138 "79q nice \$''bash -c into the primary"                         block "nice \$''bash -c 'touch @P@/x'"
_r4138 "79r \$'bash' -c with no wrapper into the primary"              block "\$'bash' -c 'touch @P@/x'"
_r4138 "79s \$'eval' into the primary"                                 block "\$'eval' 'touch @P@/x'"
_r4138 "79t nice \$'\\x62ash' -c (a hex escape) into the primary"      block "nice \$'\\x62ash' -c 'touch @P@/x'"
_r4138 "79u nice \$\"bash\" -c into the primary"                       block "nice \$\"bash\" -c 'touch @P@/x'"
_r4138 "79v command \$'eval' into the primary"                         block "command \$'eval' 'touch @P@/x'"
_r4138 "79w nice \$'bash' -c into the worktree (ALLOW)"                allow "nice \$'bash' -c 'touch @W@/x'"
_r4138 "79x nice \$'\\x62ash' -c into the worktree (ALLOW)"            allow "nice \$'\\x62ash' -c 'touch @W@/x'"
# J1672: the comment reading blanks heredoc bodies, so a delimiter spelling
# the first reading's blanker misses cannot carry a quote past the body.
_r4138 "78z <<\\E body with a commented quote, then touch"            block 'x=$(cat <<\E\n# '"'"'\nE\n); touch @P@/x'
_r4138 "78za <<\$E body with a commented quote, then touch"           block 'x=$(cat <<$E\n# '"'"'\n$E\n); touch @P@/x'
_r4138 "78zb <<\${x} body with a commented quote, then touch"         block 'x=$(cat <<${x}\n# '"'"'\n${x}\n); touch @P@/x'
_r4138 "78zc <<'#' body with a commented quote, then touch"           block 'x=$(cat <<'"'"'#'"'"'\n# '"'"'\n#\n); touch @P@/x'
_r4138 "78zd <<\\E body with a commented quote, worktree (ALLOW)"     allow 'x=$(cat <<\E\n# '"'"'\nE\n); touch @W@/x'
# (4) bash 5.3 decodes \x{2f} as /, bash 5.2 keeps \x{ and zsh reads NUL.
_r4138 "80a \$'\\x{2f}' prefix of a primary path"                        block "echo > \$'\\x{2f}'@P@/f"
_r4138 "80b \$'\\x{2f}' aimed at the worktree (ambiguous: fail closed)"  block "echo > \$'\\x{2f}'@W@/f"
_r4138 "80c \$'\\x2f' has one reading (ALLOW)"                          allow "echo > \$'\\x2f'@W@/f"
# (5) An ANSI-C NUL ends the name (bash: the rest of the span, zsh: the word).
_r4138 "81a \\x00 ends the name inside the primary"                     block "echo x > \$'@P@/f\\x00/../../zz'"
_r4138 "81b \\0 ends the name inside the primary"                       block "echo x > \$'@P@/f\\0/../../zz'"
_r4138 "81c NUL at the span end, word continues"                       block "echo x > \$'@P@/f\\0'/../../zz"
_r4138 "81d read -d \$'\\0' stays allowed (ALLOW)"                      allow "while IFS= read -r -d \$'\\0' f; do :; done < /dev/null"
# CR codex-1: octal wraps mod 256 and bash masks \c to 5 bits, so these are NUL too.
_r4138 "81e \\400 ends the name inside the primary"                     block "echo x > \$'@P@/f\\400/../../zz'"
_r4138 "81f \\c\` ends the name inside the primary"                     block "echo x > \$'@P@/f\\c\`/../../zz'"
_r4138 "81g \\c<space> ends the name inside the primary"                block "echo x > \$'@P@/f\\c /../../zz'"
_r4138 "81h \\377 stays a byte, worktree write (ALLOW)"                 allow "echo x > \$'@W@/f\\377/../zz'"
}

echo "== HIMMEL-4153/4145/4143 assignment prefix, nested heredoc bodies, quoted newlines =="
# shellcheck disable=SC2016  # row templates are literal shell text
{
# HIMMEL-4153: leading NAME=value / NAME[…]=value words are skipped before the
# verb arms read the command word, and a plain `$((…))` no longer splits.
_r4138 "82a x=1 touch primary"                                         block 'x=1 touch @P@/x'
_r4138 "82b x=\$((1<<2)) touch primary"                                block 'x=$((1<<2)) touch @P@/x'
_r4138 "82c a[1<<2]=1 touch primary"                                   block 'a[1<<2]=1 touch @P@/x'
_r4138 "82d x=\$(echo hi) touch primary"                               block 'x=$(echo hi) touch @P@/x'
_r4138 "82e x=\"a b\" touch primary"                                   block 'x="a b" touch @P@/x'
_r4138 "82f x=1 y=2 touch primary"                                     block 'x=1 y=2 touch @P@/x'
_r4138 "82g x+=1 touch primary"                                        block 'x+=1 touch @P@/x'
_r4138 "82h x=1 cp into the primary"                                   block 'x=1 cp @W@/README.md @P@/x'
_r4138 "82i x=1 rm in the primary"                                     block 'x=1 rm @P@/README.md'
_r4138 "82j a[\$((1<<2))]=1 touch primary"                             block 'a[$((1<<2))]=1 touch @P@/x'
_r4138 "82k x=\`echo hi\` touch primary"                               block 'x=`echo hi` touch @P@/x'
_r4138 "82l x=1 sed -i in the primary"                                 block 'x=1 sed -i s/a/b/ @P@/README.md'
_r4138 "82m x=1 git -C primary commit"                                 block 'x=1 git -C @P@ commit --allow-empty -m m'
_r4138 "82n \$((touch …) ) is a subshell, still split"                 block 'echo $((touch @P@/x) )'
_r4138 "82o \$((echo a); touch …) is a subshell, still split"          block 'echo $((echo a); touch @P@/x)'
_r4138 "82p x=1 touch worktree (ALLOW)"                                allow 'x=1 touch @W@/x'
_r4138 "82q x=\$((1<<2)) touch worktree (ALLOW)"                       allow 'x=$((1<<2)) touch @W@/x'
_r4138 "82r a[1<<2]=1 touch worktree (ALLOW)"                          allow 'a[1<<2]=1 touch @W@/x'
_r4138 "82s bare assignment (ALLOW)"                                   allow 'x=1'
_r4138 "82t FOO=1 git -C worktree commit (ALLOW)"                      allow 'FOO=1 git -C @W@ commit --allow-empty -m m'
# Only `(` and `${` nest in an assignment value; a bare `[` or `{` is a
# literal, so the value ends at the next blank and the verb is read.
_r4138 "85a x=[ touch primary (bare [ is literal)"                     block 'x=[ touch @P@/x'
_r4138 "85b x={ touch primary (bare { is literal)"                     block 'x={ touch @P@/x'
_r4138 "85c x=a[b touch primary"                                       block 'x=a[b touch @P@/x'
_r4138 "85d x=\\\${ touch primary (escaped \$ is literal)"             block 'x=\${ touch @P@/x'
_r4138 "85e x=\$\${ touch primary (PID then literal {)"                block 'x=$${ touch @P@/x'
_r4138 "85f x=\${a:- b} touch primary (\${ nests)"                     block 'x=${a:- b} touch @P@/x'
_r4138 "85g x=\$(echo }) touch primary"                                block 'x=$(echo }) touch @P@/x'
_r4138 "85i x=[ touch worktree (ALLOW)"                                allow 'x=[ touch @W@/x'
_r4138 "85j x=\${a:- b} git -C worktree commit (ALLOW)"                allow 'x=${a:- b} git -C @W@ commit --allow-empty -m m'
# HIMMEL-4145: a heredoc body inside a dq-quoted `$(…)` is blanked in an
# extra reading, so a body apostrophe cannot swallow a later write.
_r4138 "83a dq \$(cat <<E it's E); touch primary"                      block 'x="$(cat <<E\nit'"'"'s\nE\n)"; touch @P@/f'
_r4138 "83b dq \$(cat <<E # it's E); touch primary"                    block 'x="$(cat <<E\n# it'"'"'s\nE\n)"; touch @P@/f'
_r4138 "83c commit idiom with it's, then touch primary"                block 'git -C @W@ commit --allow-empty -m "$(cat <<'"'"'EOF'"'"'\nfix: it'"'"'s done\nEOF\n)"; touch @P@/f'
_r4138 "83d dq <<- tab body with it's; touch primary"                  block 'x="$(cat <<-E\n\tit'"'"'s\n\tE\n)"; touch @P@/f'
_r4138 "83e dq body with a backtick; touch primary"                    block 'x="$(cat <<E\nuse `x\nE\n)"; touch @P@/f'
_r4138 "83f dq body with a dquote; touch primary"                      block 'x="$(cat <<E\nsay "hi\nE\n)"; touch @P@/f'
_r4138 "83g write inside \$(…) after the heredoc"                      block 'x="$(cat <<E\nhi\nE\necho x > @P@/f\n)"'
_r4138 "83h nested dq \$(…) twice, it's; touch primary"                block 'x="$(echo "$(cat <<E\nit'"'"'s\nE\n)")"; touch @P@/f'
_r4138 "83j \\\$( in dq is text, a body never opens"                   block 'x="\$(cat <<E"; touch @P@/f; echo "E"'
_r4138 "83k commit idiom with it's (ALLOW)"                            allow 'git -C @W@ commit --allow-empty -m "$(cat <<'"'"'EOF'"'"'\nfix: it'"'"'s done\nEOF\n)"'
_r4138 "83l dq it's, then touch worktree (ALLOW)"                      allow 'x="$(cat <<E\nit'"'"'s\nE\n)"; touch @W@/f'
_r4138 "83m redirect text in the body stays denied (flat reading, pin)" block 'x="$(cat <<E\na > @P@/f\nE\n)"'
# HIMMEL-4143: a newline inside a quoted span travels as \006, so a clause is
# never split mid-word (and the raw byte is a marker, denied).
_r4138 "84a echo 'a NL' > primary"                                     block 'echo '"'"'a\n'"'"' > @P@/f'
_r4138 "84b echo \"a NL b\" > primary"                                 block 'echo "a\nb" > @P@/f'
_r4138 "84c bash -c \"echo 'hi NL'; touch primary\""              block 'bash -c "echo '"'"'hi\n'"'"'; touch @P@/f"'
_r4138 "84d bash -c 'x=\$(echo hi NL); touch primary'"                 block 'bash -c '"'"'x=$(echo hi\n); touch @P@/f'"'"''
_r4138 "78e comment with a quote in \$(…) in a multi-line bash -c"     block 'bash -c "x=\$(echo hi # it'"'"'s\n); touch @P@/f"'
_r4138 "84e touch 'primary/a NL b'"                                    block 'touch '"'"'@P@/a\nb'"'"''
_r4138 "84f a raw 0x06 byte is a marker"                               block 'echo x > @W@/a'$'\006''b'
_r4138 "84g echo 'a NL' > worktree (ALLOW)"                            allow 'echo '"'"'a\n'"'"' > @W@/f'
_r4138 "84h bash -c \"echo 'hi NL'; touch worktree\" (ALLOW)"     allow 'bash -c "echo '"'"'hi\n'"'"'; touch @W@/f"'
_r4138 "84i commit -m 'a NL touch primary' stays denied (raw reading, pin)" block 'git -C @W@ commit --allow-empty -m '"'"'a\ntouch @P@/f'"'"''
_r4138 "84j git commit -m multi-line message (ALLOW)"                  allow 'git -C @W@ commit --allow-empty -m '"'"'fix: x\n\nbody it is\n'"'"''
}

echo "== HIMMEL-4198/4174/4177 non-plain \$((…)), array values, continuations, case/esac tokens =="
# shellcheck disable=SC2016  # row templates are literal shell text
{
# HIMMEL-4198: a `$((…))` value holding `|`, `&`, `&&`, `$(…)` or a backtick,
# and a backslash-newline in a value, no longer hide the write verb after it.
_r4138 "86a x=\$((1|2)) touch primary"                                 block 'x=$((1|2)) touch @P@/f'
_r4138 "86b x=\$(( \$(echo 1) )) touch primary"                        block 'x=$(( $(echo 1) )) touch @P@/f'
_r4138 "86c x=\$((1&2)) cp into the primary"                           block 'x=$((1&2)) cp @W@/README.md @P@/f'
_r4138 "86d x=\$((1 && 2)) touch primary"                              block 'x=$((1 && 2)) touch @P@/f'
_r4138 "86e x=\$((\`echo 1\`)) touch primary"                          block 'x=$((`echo 1`)) touch @P@/f'
_r4138 "86f x=\\ NL 1 touch primary (line continuation)"              block 'x=\\n1 touch @P@/f'
_r4138 "86g x=\$((1|2)) rm in the primary"                             block 'x=$((1|2)) rm @P@/README.md'
_r4138 "86h x=\$((1|2)) sed -i in the primary"                         block 'x=$((1|2)) sed -i s/a/b/ @P@/README.md'
_r4138 "86i x=\"\$((1|2))\" touch primary"                             block 'x="$((1|2))" touch @P@/f'
_r4138 "86j x=\$((1|2)) y=\$((3&4)) touch primary"                     block 'x=$((1|2)) y=$((3&4)) touch @P@/f'
_r4138 "86k x=1\\ NL y=2 touch primary"                               block 'x=1 \\ny=2 touch @P@/f'
_subst_row "86l x=\$((1|2)) touch primary, cwd /tmp"                   block "x=\$((1|2)) touch $_PR/f" /tmp
_subst_row "86m x=\$(( \$(echo 1) )) touch ./f, cwd the primary"       block 'x=$(( $(echo 1) )) touch ./f' "$_PR"
_subst_row "86n x=\$((1&2)) cp into the primary, cwd /tmp"             block "x=\$((1&2)) cp /tmp/a $_PR/f" /tmp
_subst_row "86o x=\\ NL 1 touch primary, cwd /tmp"                    block "x=\\"$'\n'"1 touch $_PR/f" /tmp
_subst_row "86p x=\$((1|2)) touch ./f, cwd the primary"                block 'x=$((1|2)) touch ./f' "$_PR"
_r4138 "86q x=\$((1|2)) touch worktree (ALLOW)"                        allow 'x=$((1|2)) touch @W@/f'
_r4138 "86r x=\\ NL 1 touch worktree (ALLOW)"                         allow 'x=\\n1 touch @W@/f'
_r4138 "86s echo '\$((1|2)) touch primary' is text (ALLOW)"            allow 'echo '"'"'x=$((1|2)) touch @P@/f'"'"''
# The same join reaches a continuation anywhere in the command, not only in
# an assignment value: bash removes every unquoted backslash-newline.
_r4138 "86t cp a \\ NL primary/f"                                     block 'cp @W@/README.md \\n@P@/f'
_r4138 "86u tou\\ NL ch primary/f"                                    block 'tou\\nch @P@/f'
_r4138 "86v touch \\ NL primary/f"                                    block 'touch \\n@P@/f'
_r4138 "86w echo x >\\ NL primary/f"                                  block 'echo x >\\n@P@/f'
_r4138 "86x sed -i \\ NL s/a/b/ primary/README.md"                    block 'sed -i \\ns/a/b/ @P@/README.md'
_r4138 "86y touch \\ NL worktree/f (ALLOW)"                           allow 'touch \\n@W@/f'
_r4138 "86z echo '\\ NL' touch primary stays text (ALLOW)"            allow 'echo '"'"'a\\n'"'"'touch @P@/f'
# HIMMEL-4174: an array value `(…)` is one word, not a subshell break.
_r4138 "87a x=(a b) touch primary"                                     block 'x=(a b) touch @P@/x'
_r4138 "87b x+=(a b) touch primary"                                    block 'x+=(a b) touch @P@/x'
_r4138 "87c x=(a) y=\$((1|2)) touch primary"                           block 'x=(a) y=$((1|2)) touch @P@/x'
_subst_row "87d x=(a b) touch primary, cwd /tmp"                       block "x=(a b) touch $_PR/x" /tmp
_subst_row "87e x=(a b) touch ./x, cwd the primary"                    block 'x=(a b) touch ./x' "$_PR"
_r4138 "87f x=(a b) touch worktree (ALLOW)"                            allow 'x=(a b) touch @W@/x'
# HIMMEL-4177: only a case/esac TOKEN makes the nested reading fall back,
# so `showcase` no longer lets a body apostrophe hide a later write.
_r4138 "88a dq \$(echo showcase; cat <<E it's E); touch primary"       block 'x="$(echo showcase; cat <<E\nit'"'"'s\nE\n)"; touch @P@/f'
_r4138 "88b dq \$(echo lowercase-esacs; cat <<E it's E); touch primary" block 'x="$(echo lowercase esacs; cat <<E\nit'"'"'s\nE\n)"; touch @P@/f'
_r4138 "88c dq \$(echo showcase; cat <<E it's E); touch worktree (ALLOW)" allow 'x="$(echo showcase; cat <<E\nit'"'"'s\nE\n)"; touch @W@/f'
}

echo "== HIMMEL-4213/4228 prefix words before the verb, \${…}/\$[…] assignment values =="
# shellcheck disable=SC2016  # row templates are literal shell text
{
# _r4213 runs a row from cwd /tmp AND from the primary checkout.
_r4213() { # label verdict template
    local c="$3"
    c="${c//@P@/$_PR}"; c="${c//@W@/$_WR}"
    _subst_row "$1, cwd /tmp" "$2" "$c" /tmp
    _subst_row "$1, cwd the primary" "$2" "$c" "$_PR"
}
# HIMMEL-4213: a leading `{`, `!`, reserved word, `time [-p]` or wrapper
# command is skipped before the verb arms read the command word.
_r4213 "93a { touch primary; }"                                        block '{ touch @P@/f; }'
_r4213 "93b ! touch primary"                                           block '! touch @P@/f'
_r4213 "93c ! x=1 touch primary"                                       block '! x=1 touch @P@/f'
_r4213 "93d if true; then touch primary; fi"                           block 'if true; then touch @P@/f; fi'
_r4213 "93e while false; do touch primary; done"                       block 'while false; do touch @P@/f; done'
_r4213 "93f nice touch primary"                                        block 'nice touch @P@/f'
_r4213 "93g command touch primary"                                     block 'command touch @P@/f'
_r4213 "93h exec touch primary"                                        block 'exec touch @P@/f'
_r4213 "93i time touch primary"                                        block 'time touch @P@/f'
_r4213 "93j time -p ! nice -n 5 nohup touch primary"                   block 'time -p ! nice -n 5 nohup touch @P@/f'
_r4213 "93k timeout -k 1 5 cp into the primary"                        block 'timeout -k 1 5 cp @W@/README.md @P@/f'
_r4213 "93l env -u X FOO=1 rm in the primary"                          block 'env -u X FOO=1 rm @P@/README.md'
_r4213 "93m sudo -u root -E stdbuf -oL touch primary"                  block 'sudo -u root -E stdbuf -oL touch @P@/f'
_r4213 "93n exec -a n sed -i in the primary"                           block 'exec -a n sed -i s/a/b/ @P@/README.md'
_r4213 "93o until false; do x=1 ln -s into the primary"                block 'until false; do x=1 ln -s @W@/README.md @P@/l; done'
_r4213 "93p nice --bogus touch primary (unknown option: fail closed)"  block 'nice --bogus touch @P@/f'
_r4213 "93q sudo -Z v touch primary (unknown option: fail closed)"     block 'sudo -Z v touch @P@/f'
_r4213 "93r { touch worktree; } (ALLOW)"                               allow '{ touch @W@/f; }'
_r4213 "93s nice touch worktree (ALLOW)"                               allow 'nice touch @W@/f'
_r4213 "93t time touch /tmp (ALLOW)"                                   allow 'time touch /tmp/himmel-4213-f'
_r4213 "93u time make (ALLOW)"                                         allow 'time make -n'
_r4213 "93v nice grep in the primary (ALLOW)"                          allow 'nice grep x @P@/README.md'
_r4213 "93w command -v touch (ALLOW)"                                  allow 'command -v touch'
_r4213 "93x git -C primary log and status (ALLOW)"                     allow 'git -C @P@ log --oneline -1; git -C @P@ status --short'
_r4213 "93y queue-lock status piped to sed (ALLOW)"                    allow 'bash scripts/queue-lock.sh status | sed -n 1p'
_r4213 "93z if grep -q x primary; then echo y; fi (ALLOW)"             allow 'if grep -q x @P@/README.md; then echo y; fi'
# the wrapper check after the chain still reads the unstripped clause
_r4213 "93za exec -a sh -c 'touch primary' stays denied"              block "exec -a sh -c 'touch @P@/f'"
_r4213 "93zb sudo -u \$'\\x62ash' -c 'touch primary' stays denied"     block "sudo -u \$'\\x62ash' -c 'touch @P@/f'"
# HIMMEL-4228: a `${…}` or `$[…]` value holding a separator no longer hides
# the write verb after it.
_r4213 "94a x=\${y:-a|b} touch primary"                                block 'x=${y:-a|b} touch @P@/f'
_r4213 "94b x=\${y:-a;b} touch primary"                                block 'x=${y:-a;b} touch @P@/f'
_r4213 "94c x=\${y:-a&b} touch primary"                                block 'x=${y:-a&b} touch @P@/f'
_r4213 "94d x=\${y:-(a)} touch primary"                                block 'x=${y:-(a)} touch @P@/f'
_r4213 "94e x=\${y:-a|b} cp into the primary"                          block 'x=${y:-a|b} cp @W@/README.md @P@/f'
_r4213 "94f x=\$[1|2] touch primary"                                   block 'x=$[1|2] touch @P@/f'
_r4213 "94g x=\${y:-\${z:-a|b}} touch primary (nested)"                block 'x=${y:-${z:-a|b}} touch @P@/f'
_r4213 "94h x=\${y:-\"}|\"} touch primary (quoted brace)"              block 'x=${y:-"}|"} touch @P@/f'
_r4213 "94i x=\${y:-a} touch primary (control)"                        block 'x=${y:-a} touch @P@/f'
_r4213 "94j x=\"\${y:-a|b}\" touch primary (control)"                  block 'x="${y:-a|b}" touch @P@/f'
_r4213 "94k x=\$[1+2] touch primary (control)"                         block 'x=$[1+2] touch @P@/f'
_r4213 "94l x=\${y:-a|b} touch worktree (ALLOW)"                       allow 'x=${y:-a|b} touch @W@/f'
_r4213 "94m x=\$[1|2] touch worktree (ALLOW)"                          allow 'x=$[1|2] touch @W@/f'
_r4213 "94n cp worktree file to \${HOME}/x (ALLOW)"                    allow 'cp @W@/README.md ${HOME}/x'
_r4213 "94o echo '\${y:-a|b} touch primary' is text (ALLOW)"           allow 'echo '"'"'x=${y:-a|b} touch @P@/f'"'"''
# A `${…}` closes at its first active `}` — only a nested `${` nests, a bare
# `{` does not (bash). An unclosed span holding a separator fails closed, and
# a bash 5.3 `${ cmd; }` / `${| cmd; }` body is read as a command.
_r4213 "95a x=\${y:-a{|b} touch primary (bare { does not nest)"       block 'x=${y:-a{|b} touch @P@/f'
_r4213 "95b x=\${y:-\"{\"|b} touch primary (quoted brace)"             block 'x=${y:-"{"|b} touch @P@/f'
_r4213 "95c x=\${y:-a\\{|b} touch primary (escaped brace)"             block 'x=${y:-a\{|b} touch @P@/f'
_r4213 "95d x=\${y:-a|b touch primary (unclosed)"                      block 'x=${y:-a|b touch @P@/f'
_r4213 "95e x=\$[1|2 touch primary (unclosed)"                         block 'x=$[1|2 touch @P@/f'
_r4213 "95f x=\$[a[1]|2] touch primary (nested [)"                     block 'x=$[a[1]|2] touch @P@/f'
_r4213 "95g x=\${ touch primary; } (funsub)"                           block 'x=${ touch @P@/f; }'
_r4213 "95h echo \${ touch primary; } (funsub)"                        block 'echo ${ touch @P@/f; }'
_r4213 "95i x=\${y:-a{|b} touch worktree (ALLOW)"                      allow 'x=${y:-a{|b} touch @W@/f'
_r4213 "95j an unclosed \${ in a comment (ALLOW)"                      allow 'echo x # ${ y | z'
_r4213 "95k echo '\${y|z' (ALLOW)"                                     allow 'echo '"'"'${y|z'"'"''
# `env -C DIR` / `sudo -D DIR` run the command in DIR: a relative target is
# read against a literal DIR, and against an unknown one fails closed.
_r4213 "96a env -C primary touch f"                                    block 'env -C @P@ touch f'
_r4213 "96b env --chdir=primary touch f"                               block 'env --chdir=@P@ touch f'
_r4213 "96c env --chdir primary touch f"                               block 'env --chdir @P@ touch f'
_r4213 "96d sudo -D primary touch f"                                   block 'sudo -D @P@ touch f'
_r4213 "96e sudo --chdir=primary touch f"                              block 'sudo --chdir=@P@ touch f'
_r4213 "96f env -iC primary rm f"                                      block 'env -iC @P@ rm f'
_r4213 "96g env -Cprimary touch f"                                     block 'env -C@P@ touch f'
_r4213 "96h env -C primary/sub touch ../f"                             block 'env -C @P@/sub touch ../f'
_r4213 "96i env -C \$HOME/x touch f (dynamic dir)"                     block 'env -C $HOME/x touch f'
_r4213 "96k env -C \$HOME touch /tmp abs (ALLOW)"                      allow 'env -C $HOME touch /tmp/himmel-4213-h'
# from cwd the primary these still deny: like a `cd`, the chdir only adds a
# reading beside the real cwd (_bwimc_cd_guard)
_subst_row "96j env -C worktree touch f (ALLOW), cwd /tmp"             allow "env -C $_WR touch f" /tmp
_subst_row "96l sudo -D worktree touch f (ALLOW), cwd /tmp"            allow "sudo -D $_WR touch f" /tmp
_r4213 "96m env -C primary cat f (ALLOW)"                              allow 'env -C @P@ cat f'
_subst_row "96n env -C primary true; touch f (chdir ends with its command), cwd /tmp" allow "env -C $_PR true; touch f" /tmp
_subst_row "96o sudo -i touch f (login shell: dir unknown), cwd /tmp"    block "sudo -i touch f" /tmp
_subst_row "96p sudo --login touch f (dir unknown), cwd /tmp"           block "sudo --login touch f" /tmp
_subst_row "96q env -Z -C primary touch f (unknown option), cwd /tmp"   block "env -Z -C $_PR touch f" /tmp
_subst_row "96r env -C /tmp touch f (ALLOW), cwd /tmp"                  allow "env -C /tmp touch f" /tmp
# HIMMEL-4213 CR round 2: every wrapper end-of-options `--` (bash `time [-p] [--]`)
_r4213 "97a time -p -- touch primary"                                   block 'time -p -- touch @P@/f'
_r4213 "97b time -p -- nice -- env -- sudo -- touch primary"            block 'time -p -- nice -- env -- sudo -- touch @P@/f'
_r4213 "97c nice -- nohup -- timeout -- 5 time -p -- touch primary"     block 'nice -- nohup -- timeout -- 5 time -p -- touch @P@/f'
_r4213 "97d timeout -k 1 -s 9 -- 5 touch primary"                       block 'timeout -k 1 -s 9 -- 5 touch @P@/f'
_r4213 "97e exec -cl -a x -- touch primary"                             block 'exec -cl -a x -- touch @P@/f'
_r4213 "97f sudo -EH -u root -- touch primary"                          block 'sudo -EH -u root -- touch @P@/f'
_r4213 "97g command -- exec -- stdbuf -oL -- touch primary"             block 'command -- exec -- stdbuf -oL -- touch @P@/f'
_r4213 "97h time -p -- cat primary (ALLOW)"                             allow 'time -p -- cat @P@/f'
# HIMMEL-4213 latency: the flattened reading masks plain commands to `:`
# (_bwimc_flat_mask); a write beside a flattened span must still deny
_r4213 "98a x=\${y:-a|b} echo; touch primary (masked)"                  block 'x=${y:-a|b} echo; touch @P@/f'
_r4213 "98b x=\${y:-a|b} touch primary; echo ok"                        block 'x=${y:-a|b} touch @P@/f; echo ok'
_r4213 "98c x=\${y:-a|b} cd primary; touch f (cd: no mask)"             block 'x=${y:-a|b} cd @P@; touch f'
_r4213 "98d env -C primary touch f; x=\${y:-a|b} true"                  block 'env -C @P@ touch f; x=${y:-a|b} true'
_r4213 "98e x=\${y:-a|b} true; env -C primary touch f"                  block 'x=${y:-a|b} true; env -C @P@ touch f'
_r4213 "98f x=\${y:-a|b} true && rm primary"                            block 'x=${y:-a|b} true && rm @P@/README.md'
_r4213 "98g x=\${y:-a|b} true; git -C primary checkout main"            block 'x=${y:-a|b} true; git -C @P@ checkout main'
_r4213 "98h x=\${y:-a;b} git -C primary log; touch primary"             block 'x=${y:-a;b} git -C @P@ log; touch @P@/f'
_r4213 "98i x=\${y:-a|b} true; nice touch primary"                      block 'x=${y:-a|b} true; nice touch @P@/f'
_r4213 "98j x=\${y:-a|b} true; git -C primary log | head (ALLOW)"       allow 'x=${y:-a|b} true; git -C @P@ log --oneline -1 | head -n 1'
_r4213 "98k x=\${y:-a|b} true; echo ok (ALLOW)"                         allow 'x=${y:-a|b} true; echo ok'
# HIMMEL-4213 round 3: a quoted wrapper operand holding a blank is one word
# (_bwimc_sp_word honours '..', "..", $'..' and backslash); chrt, taskset and
# ionice read from the first verb word; an unclosed quote fails closed
_r4213 "99a exec -a dq-two-words touch primary"                            block 'exec -a "two words" touch @P@/f'
_r4213 "99b exec -a sq-two-words touch primary"                            block 'exec -a '\''two words'\'' touch @P@/f'
_r4213 "99c exec -a ansi-two-words touch primary"                          block 'exec -a $'\''two words'\'' touch @P@/f'
_r4213 "99d sudo -u dq-a-b touch primary"                                  block 'sudo -u "a b" touch @P@/f'
_r4213 "99e sudo --user=sq-a-b touch primary"                              block 'sudo --user='\''a b'\'' touch @P@/f'
_r4213 "99f sudo -g ansi-a-b touch primary"                                block 'sudo -g $'\''a b'\'' touch @P@/f'
_r4213 "99g sudo -E -u dq-a-b -- touch primary"                            block 'sudo -E -u "a b" -- touch @P@/f'
_r4213 "99h env dq-assignment touch primary"                               block 'env "A=b c" touch @P@/f'
_r4213 "99i env A=sq touch primary"                                        block 'env A='\''b c'\'' touch @P@/f'
_r4213 "99j env -u ansi touch primary"                                     block 'env -u $'\''A B'\'' touch @P@/f'
_r4213 "99k timeout -s dq 5 touch primary"                                 block 'timeout -s "KILL now" 5 touch @P@/f'
_r4213 "99l timeout dq-duration touch primary"                             block 'timeout "5 " touch @P@/f'
_r4213 "99m nice -n sq touch primary"                                      block 'nice -n '\''5 '\'' touch @P@/f'
_r4213 "99n stdbuf -o dq touch primary"                                    block 'stdbuf -o "L " touch @P@/f'
_r4213 "99o chrt 5 touch primary"                                          block 'chrt 5 touch @P@/f'
_r4213 "99p taskset -c dq touch primary"                                   block 'taskset -c "0 1" touch @P@/f'
_r4213 "99q ionice -c 3 touch primary"                                     block 'ionice -c 3 touch @P@/f'
_r4213 "99r quoted sudo -u x touch primary"                                block '"sudo" -u x touch @P@/f'
_r4213 "99s exec -a backslash-space touch primary"                         block 'exec -a a\ b touch @P@/f'
_r4213 "99t exec -a dq-with-escaped-quote touch primary"                   block 'exec -a "a \" b" touch @P@/f'
_r4213 "99u env -C dq-primary touch f"                                     block 'env -C "@P@" touch f'
_r4213 "99v sudo -D ansi-primary touch f"                                  block 'sudo -D $'\''@P@'\'' touch f'
_r4213 "99w exec -a unclosed-quote touch primary"                          block 'exec -a "two words touch @P@/f'
_r4213 "99x exec -a dq-two-words cat primary (ALLOW)"                      allow 'exec -a "two words" cat @P@/f'
_r4213 "99y env dq-assignment ls primary (ALLOW)"                          allow 'env "A=b c" ls @P@'
_r4213 "99z env -C dq-tmp touch tmp (ALLOW)"                               allow 'env -C "/tmp" touch /tmp/f'
# HIMMEL-4228 (J1790i): a `${` opened inside "…" whose span holds a quote is
# not flattened (_bwimc_brace_end scans from the unquoted state), so the
# `$((` flattening cannot erase the real write after it
_r4228q() { # label verdict template — cwd the primary only (a relative target)
    local c="$3"
    c="${c//@P@/$_PR}"
    _subst_row "$1, cwd the primary" "$2" "$c" "$_PR"
}
_r4213 "100-dash-sq-touch-abs"                    block $'echo "${y:-\'}" ; x=$((1|2)) touch @P@/f ; : \'}\''
_r4213 "100-dash-sq-bsnl-touch-abs"               block $'echo "${y:-\'}" ; x=$((1|2)) tou\\\nch @P@/f ; : \'}\''
_r4228q "100-dash-sq-touch-rel"                    block $'echo "${y:-\'}" ; x=$((1|2)) touch f ; : \'}\''
_r4228q "100-dash-sq-cp-rel"                       block $'echo "${y:-\'}" ; x=$((1|2)) cp /etc/hosts f ; : \'}\''
_r4228q "100-dash-sq-sed-i-rel"                    block $'echo "${y:-\'}" ; x=$((1|2)) sed -i s/a/b/ README.md ; : \'}\''
_r4213 "100-dash-bt-touch-abs"                    block $'echo "${y:-`}" ; x=$((1|2)) touch @P@/f ; : `}`'
_r4213 "100-dash-bt-bsnl-touch-abs"               block $'echo "${y:-`}" ; x=$((1|2)) tou\\\nch @P@/f ; : `}`'
_r4228q "100-dash-bt-touch-rel"                    block $'echo "${y:-`}" ; x=$((1|2)) touch f ; : `}`'
_r4228q "100-dash-bt-cp-rel"                       block $'echo "${y:-`}" ; x=$((1|2)) cp /etc/hosts f ; : `}`'
_r4228q "100-dash-bt-sed-i-rel"                    block $'echo "${y:-`}" ; x=$((1|2)) sed -i s/a/b/ README.md ; : `}`'
_r4213 "100-dash-dq-touch-abs"                    block $'echo "${y:-"}" ; x=$((1|2)) touch @P@/f ; : "}"'
_r4213 "100-dash-dq-bsnl-touch-abs"               block $'echo "${y:-"}" ; x=$((1|2)) tou\\\nch @P@/f ; : "}"'
_r4228q "100-dash-dq-touch-rel"                    block $'echo "${y:-"}" ; x=$((1|2)) touch f ; : "}"'
_r4228q "100-dash-dq-cp-rel"                       block $'echo "${y:-"}" ; x=$((1|2)) cp /etc/hosts f ; : "}"'
_r4228q "100-dash-dq-sed-i-rel"                    block $'echo "${y:-"}" ; x=$((1|2)) sed -i s/a/b/ README.md ; : "}"'
_r4213 "100-hash-sq-touch-abs"                    block $'echo "${y#\'}" ; x=$((1|2)) touch @P@/f ; : \'}\''
_r4213 "100-hash-sq-bsnl-touch-abs"               block $'echo "${y#\'}" ; x=$((1|2)) tou\\\nch @P@/f ; : \'}\''
_r4228q "100-hash-sq-touch-rel"                    block $'echo "${y#\'}" ; x=$((1|2)) touch f ; : \'}\''
_r4228q "100-hash-sq-cp-rel"                       block $'echo "${y#\'}" ; x=$((1|2)) cp /etc/hosts f ; : \'}\''
_r4228q "100-hash-sq-sed-i-rel"                    block $'echo "${y#\'}" ; x=$((1|2)) sed -i s/a/b/ README.md ; : \'}\''
_r4213 "100-hash-bt-touch-abs"                    block $'echo "${y#`}" ; x=$((1|2)) touch @P@/f ; : `}`'
_r4213 "100-hash-bt-bsnl-touch-abs"               block $'echo "${y#`}" ; x=$((1|2)) tou\\\nch @P@/f ; : `}`'
_r4228q "100-hash-bt-touch-rel"                    block $'echo "${y#`}" ; x=$((1|2)) touch f ; : `}`'
_r4228q "100-hash-bt-cp-rel"                       block $'echo "${y#`}" ; x=$((1|2)) cp /etc/hosts f ; : `}`'
_r4228q "100-hash-bt-sed-i-rel"                    block $'echo "${y#`}" ; x=$((1|2)) sed -i s/a/b/ README.md ; : `}`'
_r4213 "100-hash-dq-touch-abs"                    block $'echo "${y#"}" ; x=$((1|2)) touch @P@/f ; : "}"'
_r4213 "100-hash-dq-bsnl-touch-abs"               block $'echo "${y#"}" ; x=$((1|2)) tou\\\nch @P@/f ; : "}"'
_r4228q "100-hash-dq-touch-rel"                    block $'echo "${y#"}" ; x=$((1|2)) touch f ; : "}"'
_r4228q "100-hash-dq-cp-rel"                       block $'echo "${y#"}" ; x=$((1|2)) cp /etc/hosts f ; : "}"'
_r4228q "100-hash-dq-sed-i-rel"                    block $'echo "${y#"}" ; x=$((1|2)) sed -i s/a/b/ README.md ; : "}"'
_r4213 "100-slash-sq-touch-abs"                   block $'echo "${y/\'/x}" ; x=$((1|2)) touch @P@/f ; : \'}\''
_r4213 "100-slash-sq-bsnl-touch-abs"              block $'echo "${y/\'/x}" ; x=$((1|2)) tou\\\nch @P@/f ; : \'}\''
_r4228q "100-slash-sq-touch-rel"                   block $'echo "${y/\'/x}" ; x=$((1|2)) touch f ; : \'}\''
_r4228q "100-slash-sq-cp-rel"                      block $'echo "${y/\'/x}" ; x=$((1|2)) cp /etc/hosts f ; : \'}\''
_r4228q "100-slash-sq-sed-i-rel"                   block $'echo "${y/\'/x}" ; x=$((1|2)) sed -i s/a/b/ README.md ; : \'}\''
_r4213 "100-slash-bt-touch-abs"                   block $'echo "${y/`/x}" ; x=$((1|2)) touch @P@/f ; : `}`'
_r4213 "100-slash-bt-bsnl-touch-abs"              block $'echo "${y/`/x}" ; x=$((1|2)) tou\\\nch @P@/f ; : `}`'
_r4228q "100-slash-bt-touch-rel"                   block $'echo "${y/`/x}" ; x=$((1|2)) touch f ; : `}`'
_r4228q "100-slash-bt-cp-rel"                      block $'echo "${y/`/x}" ; x=$((1|2)) cp /etc/hosts f ; : `}`'
_r4228q "100-slash-bt-sed-i-rel"                   block $'echo "${y/`/x}" ; x=$((1|2)) sed -i s/a/b/ README.md ; : `}`'
_r4213 "100-slash-dq-touch-abs"                   block $'echo "${y/"/x}" ; x=$((1|2)) touch @P@/f ; : "}"'
_r4213 "100-slash-dq-bsnl-touch-abs"              block $'echo "${y/"/x}" ; x=$((1|2)) tou\\\nch @P@/f ; : "}"'
_r4228q "100-slash-dq-touch-rel"                   block $'echo "${y/"/x}" ; x=$((1|2)) touch f ; : "}"'
_r4228q "100-slash-dq-cp-rel"                      block $'echo "${y/"/x}" ; x=$((1|2)) cp /etc/hosts f ; : "}"'
_r4228q "100-slash-dq-sed-i-rel"                   block $'echo "${y/"/x}" ; x=$((1|2)) sed -i s/a/b/ README.md ; : "}"'
_r4213 "100-pct-sq-touch-abs"                     block $'echo "${y%\'}" ; x=$((1|2)) touch @P@/f ; : \'}\''
_r4213 "100-pct-sq-bsnl-touch-abs"                block $'echo "${y%\'}" ; x=$((1|2)) tou\\\nch @P@/f ; : \'}\''
_r4228q "100-pct-sq-touch-rel"                     block $'echo "${y%\'}" ; x=$((1|2)) touch f ; : \'}\''
_r4228q "100-pct-sq-cp-rel"                        block $'echo "${y%\'}" ; x=$((1|2)) cp /etc/hosts f ; : \'}\''
_r4228q "100-pct-sq-sed-i-rel"                     block $'echo "${y%\'}" ; x=$((1|2)) sed -i s/a/b/ README.md ; : \'}\''
_r4213 "100-pct-bt-touch-abs"                     block $'echo "${y%`}" ; x=$((1|2)) touch @P@/f ; : `}`'
_r4213 "100-pct-bt-bsnl-touch-abs"                block $'echo "${y%`}" ; x=$((1|2)) tou\\\nch @P@/f ; : `}`'
_r4228q "100-pct-bt-touch-rel"                     block $'echo "${y%`}" ; x=$((1|2)) touch f ; : `}`'
_r4228q "100-pct-bt-cp-rel"                        block $'echo "${y%`}" ; x=$((1|2)) cp /etc/hosts f ; : `}`'
_r4228q "100-pct-bt-sed-i-rel"                     block $'echo "${y%`}" ; x=$((1|2)) sed -i s/a/b/ README.md ; : `}`'
_r4213 "100-pct-dq-touch-abs"                     block $'echo "${y%"}" ; x=$((1|2)) touch @P@/f ; : "}"'
_r4213 "100-pct-dq-bsnl-touch-abs"                block $'echo "${y%"}" ; x=$((1|2)) tou\\\nch @P@/f ; : "}"'
_r4228q "100-pct-dq-touch-rel"                     block $'echo "${y%"}" ; x=$((1|2)) touch f ; : "}"'
_r4228q "100-pct-dq-cp-rel"                        block $'echo "${y%"}" ; x=$((1|2)) cp /etc/hosts f ; : "}"'
_r4228q "100-pct-dq-sed-i-rel"                     block $'echo "${y%"}" ; x=$((1|2)) sed -i s/a/b/ README.md ; : "}"'
_r4213 "100z dq-span with quote, ls primary (ALLOW)"           allow $'echo "${y:-\'}" ; x=$((1|2)) ls @P@ ; : \'}\''
}

echo "== HIMMEL-4253 (a ~/ redirect target is cwd-independent; the cd guard must not read it as relative) =="
# `echo done` is an accepted HIMMEL-3685 taint, so the cd below leaves the
# modelled cwd UNRESOLVED. A `~/…` target names the same file whatever the cwd,
# so the unresolved-cd guard must not deny it; the target is still checked
# against the primary after ~ expansion. HOME=$FIX for this block, so
# `~/primary/…` is the primary and `~/.cache/…` is outside every checkout.
_r4253() {  # _r4253 <label> <block|allow> <command> <payload-cwd>
    check_both "4253 $1" "$2" \
        "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$3" | jq -Rs .),\"cwd\":\"$4\"}}"
}
_SAVED_HOME_4253="$HOME"
export HOME="$FIX"
# ALLOW: the ticket's command (outside every checkout), and its minimal shapes.
_r4253 "a ticket command, ~/.cache target, cwd=wt allows" allow \
    "mkdir -p ~/.cache/himmel && cd $FIX/wt && timeout 550 pre-commit run --all-files > ~/.cache/himmel/4243-audit.txt 2>&1; echo done" "$FIX/wt"
_r4253 "b cd wt && ls > ~/.cache/x; echo done allows" allow \
    "cd $FIX/wt && ls > ~/.cache/x; echo done" "$FIX/wt"
_r4253 "c cd wt && ls >> ~/.cache/x 2>&1; echo done allows" allow \
    "cd $FIX/wt && ls >> ~/.cache/x 2>&1; echo done" "$FIX/wt"
_r4253 "d cd primary && ls > ~/.cache/x; echo done allows (twin of the allowed > /tmp/x)" allow \
    "cd $FIX/primary && ls > ~/.cache/x; echo done" "$FIX/wt"
# DENY: a redirect into the primary, in every spelling, with and without a cd.
_r4253 "e echo > ~/primary/x denies" block "echo hi > ~/primary/x" "$FIX/wt"
_r4253 "f echo > \$HOME/primary/x denies" block "echo hi > \$HOME/primary/x" "$FIX/wt"
_r4253 "g echo >> \${HOME}/primary/x denies" block "echo hi >> \${HOME}/primary/x" "$FIX/wt"
_r4253 "h ticket command into ~/primary denies" block \
    "mkdir -p ~/.cache/himmel && cd $FIX/wt && timeout 550 pre-commit run --all-files > ~/primary/4243-audit.txt 2>&1; echo done" "$FIX/wt"
_r4253 "i ticket command into \$HOME/primary denies" block \
    "mkdir -p ~/.cache/himmel && cd $FIX/wt && timeout 550 pre-commit run --all-files > \$HOME/primary/4243-audit.txt 2>&1; echo done" "$FIX/wt"
_r4253 "j ticket command into \${HOME}/primary (>>) denies" block \
    "mkdir -p ~/.cache/himmel && cd $FIX/wt && timeout 550 pre-commit run --all-files >> \${HOME}/primary/4243-audit.txt 2>&1; echo done" "$FIX/wt"
_r4253 "k cd primary && ls > ~/primary/x; echo done denies" block \
    "cd $FIX/primary && ls > ~/primary/x; echo done" "$FIX/wt"
_r4253 "l cd primary && ls > \$HOME/primary/x; echo done denies" block \
    "cd $FIX/primary && ls > \$HOME/primary/x; echo done" "$FIX/wt"
_r4253 "m cd primary && ls >> \${HOME}/primary/x; echo done denies" block \
    "cd $FIX/primary && ls >> \${HOME}/primary/x; echo done" "$FIX/wt"
_r4253 "n cd ~/primary && ls > ~/primary/x; echo done denies" block \
    "cd ~/primary && ls > ~/primary/x; echo done" "$FIX/wt"
_r4253 "o cd ~/primary && ls > x denies" block "cd ~/primary && ls > x" "$FIX/wt"
_r4253 "p cd primary && timeout 5 pre-commit run > ~/primary/a.txt 2>&1; echo done denies" block \
    "cd $FIX/primary && timeout 5 pre-commit run > ~/primary/a.txt 2>&1; echo done" "$FIX/wt"
# Still fail closed: tilde forms that do not name \$HOME, and a quoted ~ (literal, relative).
_r4253 "q ~user target behind an unresolved cd denies" block "cd $FIX/wt && ls > ~root/x; echo done" "$FIX/wt"
_r4253 "r ~+ target behind an unresolved cd denies" block "cd $FIX/wt && ls > ~+/x; echo done" "$FIX/wt"
_r4253 "s ~- target behind an unresolved cd denies" block "cd $FIX/wt && ls > ~-/x; echo done" "$FIX/wt"
_r4253 "t quoted \"~\"/x (a literal relative ~ dir) behind an unresolved cd denies" block \
    "cd $FIX/wt && ls > \"~\"/x; echo done" "$FIX/wt"
_r4253 "u quoted '~/x' behind an unresolved cd denies" block "cd $FIX/wt && ls > '~/x'; echo done" "$FIX/wt"
# A relative HOME makes ~ cwd-dependent again (bash expands it after the cd), so
# the exemption must not apply and the unresolved cd must still fail closed.
export HOME=.
_r4253 "v HOME=. : cd \"\$D\" && ls > ~/x; echo done denies" block "cd \"\$D\" && ls > ~/x; echo done" "$FIX/wt"
export HOME=home
_r4253 "w HOME=home : cd \"\$D\" && ls > ~; echo done denies" block "cd \"\$D\" && ls > ~; echo done" "$FIX/wt"
export HOME="$_SAVED_HOME_4253"

echo "== HIMMEL-4504: quoted / escaped spellings of a git read that runs a program =="
# shellcheck disable=SC2016  # row templates are literal shell text
{
_r4138 "4504a -c \"core.pager=…\" (dq) git -C primary log"         block 'git -C @P@ -c "core.pager=sh -c x" log'
_r4138 "4504b -c \$'core.pager=x' (ANSI-C) git -C primary log"      block "git -C @P@ -c \$'core.pager=x' log"
_r4138 "4504c -c core.pag\\er=x (escaped) git -C primary log"       block 'git -C @P@ -c core.pag\er=x log'
_r4138 "4504d grep '--open-files-in-pager=x' (sq) on primary"       block "git -C @P@ grep '--open-files-in-pager=x' foo"
_r4138 "4504e \"--exec-path=/tmp/x\" (dq) git -C primary status"    block 'git "--exec-path=/tmp/x" -C @P@ status'
_r4138 "4504f diff \"--ext-diff\" (dq) on primary"                  block 'git -C @P@ diff "--ext-diff"'
_r4138 "4504g cd primary && git -c diff.external=x diff"            block 'cd @P@ && git -c diff.external=x diff'
_subst_row "4504h cwd=primary git grep -Ox foo"                     block 'git grep -Ox foo' "$_PR"
_r4138 "4504i -c \"color.ui=never\" git -C primary log (ALLOW)"     allow 'git -C @P@ -c "color.ui=never" log -1'
_r4138 "4504j git -C primary diff \"--no-ext-diff\" (ALLOW)"        allow 'git -C @P@ diff "--no-ext-diff"'
}

echo "== HIMMEL-4476: loop keywords and read-only commands in a body, eval as a grep argument =="
# Every row runs from both cwds: a bare word in a body resolves against the
# cwd, so the primary cwd is where `until`/`sleep`/`0.1` used to deny. The
# bodies carry "github" because the body scan's prefilter needs a "git".
_r4476() { # label verdict template
    local c="$3"
    c="${c//@P@/$_PR}"; c="${c//@W@/$_WR}"
    _subst_row "$1 [cwd=primary]" "$2" "$c" "$_PR"
    _subst_row "$1 [cwd=leg]" "$2" "$c" "$_WR"
}
# shellcheck disable=SC2016  # row templates are literal shell text
{
# (1) until/while loops in a bash -c / eval body.
_r4476 "4476a bash -c until [ … ]; do sleep; done (ALLOW)"      allow "bash -c 'until [ -e /tmp/github-4476 ]; do sleep 0.1; done'"
_r4476 "4476b timeout bash -c until [ a -nt b ] (ALLOW)"         allow "timeout 5 bash -c 'until [ /tmp/github-a -nt /tmp/github-b ]; do sleep 0.1; done'"
_r4476 "4476c bash -c while ! test -e; do sleep; done; echo (ALLOW)" allow "bash -c 'while ! test -e /tmp/github-4476; do sleep 1; done; echo ok'"
_r4476 "4476d eval until true; do :; done (ALLOW)"               allow "eval 'until true; do :; done; echo github'"
_r4476 "4476e bash -c until … do echo > primary"                block "bash -c 'until false; do echo x > @P@/f; done'"
_r4476 "4476f bash -c until … do echo >primary (attached)"      block "bash -c 'until false; do printf x >@P@/f; done'"
_r4476 "4476g bash -c until … do cp into primary"               block "bash -c 'until false; do cp /tmp/a @P@/f; done'"
_r4476 "4476h until … do echo > primary (top level)"            block 'until false; do echo x > @P@/f; done'
_r4476 "4476i bash -c until …; done; touch primary"             block "bash -c 'until [ -e /tmp/g ]; do sleep 1; done; touch @P@/f'"
_r4476 "4476j bash -c while … do echo \$(touch primary)"        block "bash -c 'while false; do echo \$(touch @P@/f); done'"
_r4476 "4476k bash -c until … do sleep > primary"               block "bash -c 'until false; do sleep 1 > @P@/f; done'"
# (3) eval as a grep argument is a pattern, not a command.
_r4476 "4476l grep -n 'eval' <primary file> (ALLOW)"            allow "grep -n 'eval' @P@/.github/ci-trust-paths.txt"
_r4476 "4476m grep -n eval <primary file> (ALLOW)"              allow 'grep -n eval @P@/.github/ci-trust-paths.txt'
_r4476 "4476n LC_ALL=C grep -rn \"eval\" <primary dir> (ALLOW)" allow 'LC_ALL=C grep -rn "eval" @P@/.github'
_r4476 "4476o eval \"echo x > primary\""                       block 'eval "echo x > @P@/f"'
_r4476 "4476p grep 'eval' … > primary"                          block "grep -n 'eval' @P@/.github/x > @P@/f"
_r4476 "4476q grep …; eval touch primary"                       block "grep -n x /tmp/a; eval 'touch @P@/.github/f'"
_r4476 "4476r grep \$(eval touch primary)"                      block "grep -n \$(eval 'touch @P@/.github/f') /tmp/a"
_r4476 "4476s nice eval with a grep word in the body"          block "nice eval 'grep x /tmp/a > @P@/.github/f'"
# ugrep's --filter / --save-config keep the scan even quoted or split.
_r4476 "4476t grep '--filter=…' eval touch primary"              block "grep '--filter=x' eval 'touch @P@/.github/f'"
_r4476 "4476u grep \\-\\-save-config eval touch primary"         block "grep \\-\\-save-config eval 'touch @P@/.github/f'"
}

# HIMMEL-4598: the `git archive | tar -x -C /tmp/<dir>` relief must not cover a
# destination at or under the resolved primary when the primary itself lives
# under /tmp ($TMPFIX/primary, main). From the primary cwd the relief used to
# allow a write the cwd rule denies; from a /tmp cwd the ratified
# is_temp_or_devnull exemption (row 28) allows the destination either way, so
# those rows pin parity with a plain `cat >` into the same primary. The
# control extracts into a /tmp dir outside any repo (ALLOW from both).
echo "== HIMMEL-4598: /tmp archive relief excludes a primary under /tmp =="
_TP="$TMPFIX/primary"
mkdir -p "$_TP/sub" "$TMPFIX/outside"
_subst_row "4598a tar -x -C primary-under-tmp, cwd the primary"      block "git archive HEAD | tar -x -C $_TP" "$_TP"
_subst_row "4598b tar -x -C primary-under-tmp/sub, cwd the primary"  block "git archive HEAD | tar -x -C $_TP/sub" "$_TP"
_subst_row "4598c tar -x -C primary/new (absent), cwd the primary"   block "git archive HEAD | tar -x -C $_TP/not-yet" "$_TP"
_subst_row "4598d tar -xf - --directory=primary, cwd the primary"    block "git archive HEAD | tar -xf - --directory=$_TP" "$_TP"
_subst_row "4598f tar -x -C outside under /tmp (ALLOW), cwd the primary" allow "git archive HEAD | tar -x -C $TMPFIX/outside" "$_TP"
_subst_row "4598g tar -x -C primary-under-tmp, cwd /tmp (row-28 parity ALLOW)" allow "git archive HEAD | tar -x -C $_TP" /tmp
_subst_row "4598h cat > primary-under-tmp/f, cwd /tmp (row-28 parity ALLOW)"   allow "cat > $_TP/f" /tmp
_subst_row "4598e tar -x -C outside under /tmp (ALLOW), cwd /tmp"    allow "git archive HEAD | tar -x -C $TMPFIX/outside" /tmp

# HIMMEL-4591: the scan is linear in the payload. A ~15 KB single command
# (quoted text, a dq span with a substitution, a heredoc) took ~27 s before
# the quoted-run fast-forward; it now takes ~1 s. The bound is generous
# (loaded-CI x2 rule) but far under the old figure. Verdict must stay ALLOW.
echo "== HIMMEL-4591: large single-command payload is scanned in linear time =="
_unit="the quick brown fox jumps over the lazy dog 0123456789 "
_blob=""; while [ ${#_blob} -lt 5000 ]; do _blob="$_blob$_unit"; done
_big="printf '%s\n' '$_blob' \"$_blob \$(echo hi)\" > $_WR/big.txt"$'\n'"cat <<'EOF' > $_WR/big2.txt"$'\n'"$_blob"$'\n'"EOF"
_bigj="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$_big" | jq -Rs .),\"cwd\":\"$_WR\"}}"
_t0=$SECONDS
_got=$(_run "$DIRECT" "$_bigj" "$_WR")
_el=$((SECONDS - _t0))
if [ "$_got" = allow ] && [ "$_el" -le 12 ]; then
    ok "4591 ${#_big}-byte payload: allow in ${_el}s (bound 12s)"
else
    bad "4591 ${#_big}-byte payload: got $_got in ${_el}s (want allow within 12s)"
fi

echo "== HIMMEL-4921: nested-quote \${:-} redirect, truncate, tar -C, /tmp symlink into the primary =="
_j4921() {  # _j4921 <command> <cwd> -> hook JSON
    printf '{"tool_name":"Bash","tool_input":{"command":%s,"cwd":"%s"}}' "$(printf '%s' "$1" | jq -Rs .)" "$2"
}
# A. nested double quotes inside a ${x:-...} expansion desynced the redirect scan.
check_both "4921 A echo \"\${x:-\"it's\"}\" > primary/f (cwd=wt) denies" block \
    "$(_j4921 "echo \"\${x:-\"it's\"}\" > $FIX/primary/f4921" "$FIX/wt")"
check_both "4921 A mirror: same redirect into the worktree allows" allow \
    "$(_j4921 "echo \"\${x:-\"it's\"}\" > $FIX/wt/f4921" "$FIX/wt")"
# B. truncate has no arm.
check_both "4921 B truncate -s0 primary/README.md (cwd=wt) denies" block \
    "$(_j4921 "truncate -s0 $FIX/primary/README.md" "$FIX/wt")"
check_both "4921 B mirror: truncate a worktree file allows" allow \
    "$(_j4921 "truncate -s0 $FIX/wt/wtfile.txt" "$FIX/wt")"
# C. tar -C destination is a write target in extract mode.
check_both "4921 C tar -xf x.tar -C primary (cwd=wt) denies" block \
    "$(_j4921 "tar -xf x.tar -C $FIX/primary" "$FIX/wt")"
check_both "4921 C git archive HEAD | tar -x -C primary (cwd=wt) denies" block \
    "$(_j4921 "git archive HEAD | tar -x -C $FIX/primary" "$FIX/wt")"
check_both "4921 C mirror: tar -xf x.tar -C worktree allows" allow \
    "$(_j4921 "tar -xf x.tar -C $FIX/wt" "$FIX/wt")"
check_both "4921 C mirror: tar -cf out.tar -C primary . (create, a read) allows" allow \
    "$(_j4921 "tar -cf out.tar -C $FIX/primary ." "$FIX/wt")"
# D. a /tmp symlink resolving into the primary: the /tmp exemption fired first.
ln -sfn "$FIX/primary" "$TMPFIX/plink"
check_both "4921 C tar -xf x.tar -C parent -C primary (cumulative -C) denies" block \
    "$(_j4921 "tar -xf x.tar -C $FIX -C primary" "$FIX/wt")"
check_both "4921 C mirror: tar -xf x.tar -C parent -C wt allows" allow \
    "$(_j4921 "tar -xf x.tar -C $FIX -C wt" "$FIX/wt")"
check_both "4921 C tar -xzC primary -f x.tar (-C inside a bundle) denies" block \
    "$(_j4921 "tar -xzC $FIX/primary -f x.tar" "$FIX/wt")"
check_both "4921 C mirror: tar -cf -x.tar -C primary . (archive named -x.tar) allows" allow \
    "$(_j4921 "tar -cf -x.tar -C $FIX/primary ." "$FIX/wt")"
check_both "4921 C tar -Mx -f x.tar -C primary (-M takes no value) denies" block \
    "$(_j4921 "tar -Mx -f x.tar -C $FIX/primary" "$FIX/wt")"
check_both "4921 C mirror: tar -Mx -f x.tar -C wt allows" allow \
    "$(_j4921 "tar -Mx -f x.tar -C $FIX/wt" "$FIX/wt")"
check_both "4921 C old-style tar xCf primary x.tar (operands follow) denies" block \
    "$(_j4921 "tar xCf $FIX/primary x.tar" "$FIX/wt")"
check_both "4921 C mirror: old-style tar xCf wt x.tar allows" allow \
    "$(_j4921 "tar xCf $FIX/wt x.tar" "$FIX/wt")"
check_both "4921 C mirror: old-style tar cCf primary out.tar (create) allows" allow \
    "$(_j4921 "tar cCf $FIX/primary out.tar ." "$FIX/wt")"
check_both "4921 D echo x > /tmp-symlink-to-primary/f (cwd=wt) denies" block \
    "$(_j4921 "echo x > $TMPFIX/plink/f4921" "$FIX/wt")"
check_both "4921 D mirror: echo x > plain /tmp dir/f allows" allow \
    "$(_j4921 "echo x > $TMPFIX/f4921" "$FIX/wt")"

echo "== non-command / non-Bash payloads (direct-exec only — sourced covered by test-block-terminal-write-fence.sh) =="
# HIMMEL-3401 (S6): a Bash payload with no command fails CLOSED.
check_one "no command -> block" "$DIRECT" block '{"tool_name":"Bash","tool_input":{}}'
check_one "numeric command -> block" "$DIRECT" block '{"tool_name":"Bash","tool_input":{"command":5}}'
check_one "non-terminal tool -> allow" "$DIRECT" allow '{"tool_name":"Read","tool_input":{"file_path":"/x/README.md"}}'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
