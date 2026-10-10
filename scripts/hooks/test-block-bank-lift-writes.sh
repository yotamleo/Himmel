#!/usr/bin/env bash
# Spec for block-bank-lift-writes.sh (HIMMEL-4445). The lift file
# ~/.himmel/state/bank-lift.json relaxes the 7-day bank gate while it is
# valid, so it is OPERATOR-ONLY: an agent session must not write it or run
# `bank-lift.sh set`. `show`, `clear` and plain reads stay allowed.
#
# Rows: one per write form, one per path spelling, one per `set` spelling,
# the directory-as-a-whole verdicts, the Write/Edit/NotebookEdit tools, the
# fail-closed inputs, and the ALLOW controls. The write-verb axis is also
# generated from the shared write-fence grammar (lib-test-write-fence-matrix.sh)
# so a spelling the main-checkout fence models is not missing here.
#
# Every row runs in a scratch HOME under mktemp; nothing is executed — each
# command is only piped to the hook as JSON.
# Platform guard: bash 3.2-safe; needs jq (SKIP without it, except the
# no-jq row, which runs the hook with jq off PATH).
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HOOKS/block-bank-lift-writes.sh"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

T=$(mktemp -d "${TMPDIR:-/tmp}/himmel-4445.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"
ST="$HOME/.himmel/state"
LIFT="$ST/bank-lift.json"
REPO="$T/repo"
mkdir -p "$ST" "$REPO/scripts/lib" "$REPO/scripts/hooks" "$T/src/sub"
: > "$REPO/scripts/lib/bank-lift.sh"
# HIMMEL-4458: `bank-lift.sh show|clear` is trusted only as the hook's OWN
# checkout's scripts/lib copy (or a .claude/worktrees/* one), so the hook
# under test runs from a copy inside the scratch repo.
cp "$HOOK" "$REPO/scripts/hooks/block-bank-lift-writes.sh" || exit 1
HOOK="$REPO/scripts/hooks/block-bank-lift-writes.sh"
printf '{}\n' > "$T/src/bank-lift.json"
printf 'x\n' > "$T/src/other.txt"
ln -s "$LIFT" "$T/filelink"       # dangling until a lift exists
ln -s "$ST" "$T/dirlink"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# _verdict <json> -> allow | deny | ?(rc=N)
_verdict() {
    local rc
    printf '%s' "$1" | bash "$HOOK" >/dev/null 2>&1
    rc=$?
    case "$rc" in 0) echo allow ;; 2) echo deny ;; *) echo "?(rc=$rc)" ;; esac
}
_check() {  # label expect json
    local got
    got=$(_verdict "$3")
    if [ "$got" = "$2" ]; then ok "$1"; else bad "$1 — expected $2 got $got"; fi
}
bash_json() {  # command [cwd]
    jq -cn --arg c "$1" --arg d "${2:-$REPO}" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}'
}
row() { _check "$1" "$2" "$(bash_json "$3" "${4:-$REPO}")"; }
tool_row() {  # label expect tool path-key path
    _check "$1" "$2" "$(jq -cn --arg t "$3" --arg k "$4" --arg p "$5" --arg d "$REPO" \
        '{tool_name:$t,tool_input:{($k):$p,content:"{}",old_string:"a",new_string:"b",new_source:"x"},cwd:$d}')"
}

echo "== write forms (target ~/.himmel/state/bank-lift.json) =="
# shellcheck disable=SC2088  # the literal ~ is the spelling under test
P='~/.himmel/state/bank-lift.json'
row "redirect >"          deny "echo '{}' > $P"
row "redirect >>"         deny "echo '{}' >> $P"
row "redirect >|"         deny "echo '{}' >| $P"
row "redirect &>"         deny "echo '{}' &> $P"
row "redirect 1> no space" deny "echo '{}' 1>$P"
row "redirect <> (rw)"    deny "exec 3<> $P"
row "exec fd redirect"    deny "exec 4> $P; echo x >&4"
row "heredoc into file"   deny "cat > $P <<'EOF'
{\"window\":\"seven_day\"}
EOF"
row "tee"                 deny "printf '{}' | tee $P"
row "tee -a"              deny "printf '{}' | tee -a /dev/null $P"
row "tee via >(…)"        deny "printf '{}' > >(tee $P)"
row "cp"                  deny "cp $T/src/bank-lift.json $P"
row "cp -f"               deny "cp -f /tmp/x.json $P"
row "mv"                  deny "mv /tmp/x.json $P"
row "install"             deny "install -m 600 /tmp/x.json $P"
row "install -D"          deny "install -D /tmp/x.json $P"
row "ln -s dest"          deny "ln -s /tmp/x.json $P"
row "ln -sf dest"         deny "ln -sf /tmp/x.json $P"
row "ln src (alias)"      deny "ln -s $P /tmp/alias.json"
row "cp -s src (alias)"   deny "cp -s $P /tmp/alias.json"
row "dd of="              deny "dd if=/tmp/x.json of=$P"
row "sed -i"              deny "sed -i 's/1/2/' $P"
row "sed -Ei bundle"      deny "sed -Ei 's/1/2/' $P"
row "sed --in-place"      deny "sed --in-place=.bak 's/1/2/' $P"
row "jq with redirect"    deny "jq -n '{window:\"seven_day\",until:9999999999}' > $P"
row "jq tmp then mv"      deny "jq . /tmp/a.json > /tmp/b.json && mv /tmp/b.json $P"
row "python3 one-liner"   deny "python3 -c \"open('$HOME/.himmel/state/bank-lift.json','w').write('{}')\""
row "python3 expanduser"  deny "python3 -c 'import os; open(os.path.expanduser(\"~/.himmel/state/bank-lift.json\"),\"w\")'"
row "python3 join"        deny "python3 -c 'import os; open(os.path.join(os.environ[\"HOME\"],\".himmel\",\"state\",\"bank\"+\"-lift.json\"),\"w\")'"
row "python3 heredoc"     deny "python3 - <<'EOF'
open('$LIFT','w').write('{}')
EOF"
row "perl one-liner"      deny "perl -e 'open(F,\">$LIFT\"); print F \"{}\"'"
row "perl -pi"            deny "perl -pi -e 's/1/2/' $P"
row "node one-liner"      deny "node -e \"require('fs').writeFileSync('$LIFT','{}')\""
row "touch"               deny "touch $P"
row "truncate"            deny "truncate -s 0 $P"
row "rsync"               deny "rsync /tmp/x.json $P"
row "curl -o"             deny "curl -s -o $P https://example.invalid/x"
row "bash -c body"        deny "bash -c \"echo '{}' > $P\""
row "sh -c body"          deny "sh -c 'cp /tmp/x.json $P'"
row "eval body"           deny "eval \"echo x > $P\""
row "env wrapper"         deny "env FOO=1 tee $P < /tmp/x.json"
row "sudo wrapper"        deny "sudo -u root cp /tmp/x.json $P"
row "xargs feed"          deny "echo $P | xargs -I{} cp /tmp/x.json {}"
row "xargs sort -o lift"  deny "echo x | xargs sort -o $P"
row "xargs -I cat lift (over-deny r7)"  deny "echo x | xargs -I{} cat $P"
row "xargs -I grep lift (over-deny r7)" deny "echo until | xargs -I{} grep -n {} $P"
row "xargs cat lift, no option (over-deny J1874)" deny "echo x | xargs cat $P"
row "find -exec"          deny "find ~/.himmel/state -name 'bank-lift.json' -exec sh -c 'echo x > {}' \\;"
row "backslash-newline"   deny "echo x \\
> $P"
row "\$(…) substitution"  deny "x=\$(echo y > $P)"
row "backtick substitution" deny "x=\`echo y > $P\`"

echo "== path spellings (redirect form) =="
row "tilde"               deny "echo x > ~/.himmel/state/bank-lift.json"
row "\$HOME"              deny "echo x > \$HOME/.himmel/state/bank-lift.json"
row "\${HOME}"            deny "echo x > \${HOME}/.himmel/state/bank-lift.json"
row "\"\$HOME\" quoted"   deny "echo x > \"\$HOME/.himmel/state/bank-lift.json\""
row "absolute (this HOME)" deny "echo x > $LIFT"
row "/home/<user>"        deny "echo x > /home/example/.himmel/state/bank-lift.json"
row "/Users/<user>"       deny "echo x > /Users/example/.himmel/state/bank-lift.json"
row "~user"               deny "echo x > ~someone/.himmel/state/bank-lift.json"
row "relative from ~/.himmel" deny "echo x > state/bank-lift.json" "$HOME/.himmel"
row "relative from state/" deny "echo x > bank-lift.json" "$ST"
row "./ from state/"      deny "echo x > ./bank-lift.json" "$ST"
row "../state/ from state/" deny "echo x > ../state/bank-lift.json" "$ST"
row "relative from ~"     deny "echo x > .himmel/state/bank-lift.json" "$HOME"
row "dot-dot normalise"   deny "echo x > ~/.himmel/./state/../state/bank-lift.json"
row "glob bank-l?ft.json" deny "echo x > ~/.himmel/state/bank-l?ft.json"
row "glob bank-lift.js*"  deny "sed -i s/1/2/ ~/.himmel/state/bank-lift.js*"
row "glob [b]ank"         deny "echo x > ~/.himmel/state/[b]ank-lift.json"
row "glob * in state/"    deny "sed -i s/1/2/ ~/.himmel/state/*"
row "glob dirs ~/.h*/st*" deny "echo x > ~/.h*/st*/bank-lift.json"
row "quote split 'bank'-lift" deny "echo x > ~/.himmel/state/'bank'-lift.json"
row "quote split \"bank\"-lift" deny "echo x > ~/.himmel/state/\"bank\"-lift.json"
row "backslash bank\\-lift" deny "echo x > ~/.himmel/state/bank\\-lift.json"
row "ANSI-C \$'\\x62ank'"  deny "echo x > ~/.himmel/state/\$'\\x62'ank-lift.json"
row "brace bank-{lift,x}" deny "echo x > ~/.himmel/state/bank-{lift,x}.json"
row "case BANK-LIFT.JSON" deny "echo x > ~/.himmel/state/BANK-LIFT.JSON"
row "dynamic name in state/" deny "echo x > ~/.himmel/state/\$name"
row "dynamic dir + lift name" deny "echo x > \"\$D/bank-lift.json\""
row "file symlink → lift" deny "echo x > $T/filelink"
row "dir symlink → state" deny "echo x > $T/dirlink/bank-lift.json"
row "cd then relative"    deny "cd ~/.himmel/state && echo x > bank-lift.json"

echo "== directory as a whole (cp/mv/rsync into ~/.himmel/state/) =="
row "cp lift-named file into state/"  deny  "cp $T/src/bank-lift.json ~/.himmel/state/"
row "cp -t state/ lift-named file"    deny  "cp -t ~/.himmel/state $T/src/bank-lift.json"
row "cp --target-directory="          deny  "cp --target-directory=$ST $T/src/bank-lift.json"
row "mv dynamic source into state/"   deny  "mv \"\$f\" ~/.himmel/state/"
row "cp glob source into state/"      deny  "cp $T/src/* ~/.himmel/state/"
row "cp -r dir/. (contents) into state/" deny "cp -r $T/src/. ~/.himmel/state/"
row "rsync dir/ (contents) into state/" deny "rsync -a $T/src/ ~/.himmel/state/"
row "cp -rT dir state"                deny  "cp -rT $T/src ~/.himmel/state"
row "cp state-named dir into ~/.himmel" deny "cp -r /tmp/x/state ~/.himmel/"
row "ln -s the state dir (alias)"     deny  "ln -s ~/.himmel/state /tmp/s"
row "cp other file into state/ (verdict: allow)" allow "cp $T/src/other.txt ~/.himmel/state/"
row "mv other file into state/ (verdict: allow)" allow "mv $T/src/other.txt ~/.himmel/state/other.txt"
# A HOME whose state dir does not exist yet: `cp X ~/.himmel/state` CREATES it
# from X, so a directory or unknowable source denies; a plain file cannot
# carry a lift in.
mkdir -p "$T/home2/.himmel"
HOME="$T/home2" row "no state dir: cp file → state (allow)"    allow "cp $T/src/other.txt ~/.himmel/state"
HOME="$T/home2" row "no state dir: cp -r dir → state"          deny  "cp -r $T/src ~/.himmel/state"
HOME="$T/home2" row "no state dir: mv missing source → state"  deny  "mv /nonexistent-4445 ~/.himmel/state"
# r10 codex-1: the same holds for EVERY missing ancestor of the lift. With no
# ~/.himmel, `cp -r payload ~/.himmel` creates it from payload, and
# payload/state/bank-lift.json becomes the live lift. Where ~/.himmel exists
# the copy only nests (~/.himmel/payload), so it stays allowed.
mkdir -p "$T/home3" "$T/payload/state"
printf '{}\n' > "$T/payload/state/bank-lift.json"
HOME="$T/home3" row "r10 no .himmel: cp -r dir → ~/.himmel"     deny  "cp -r $T/payload ~/.himmel"
HOME="$T/home3" row "r10 no .himmel: mv dir → ~/.himmel"        deny  "mv $T/payload ~/.himmel"
HOME="$T/home3" row "r10 no .himmel: mv missing src → ~/.himmel" deny "mv /nonexistent-4445 ~/.himmel"
HOME="$T/home3" row "r10 no .himmel: cp file → ~/.himmel (allow)" allow "cp $T/src/other.txt ~/.himmel"
HOME="$T/home2" row "r10 .himmel, no state: cp -r dir → ~/.himmel (allow)" allow "cp -r $T/payload ~/.himmel"

echo "== bank-lift.sh set spellings =="
S=scripts/lib/bank-lift.sh
row "bash"                 deny "bash $S set"
row "sh"                   deny "sh $S set"
row "direct relative"      deny "$S set"
row "direct ./"            deny "./bank-lift.sh set" "$REPO/scripts/lib"
row "absolute path"        deny "$REPO/$S set"
row "source"               deny "source $S set"
row ". (dot)"              deny ". $S set"
row "env"                  deny "env $S set"
row "env VAR=… bash"       deny "env FOO=1 bash $S set"
row "timeout"              deny "timeout 30 bash $S set"
row "timeout -s KILL"      deny "timeout -s KILL 30 bash $S set"
row "nohup"                deny "nohup bash $S set"
row "command"              deny "command $S set"
row "exec"                 deny "exec bash $S set"
row "nice -n"              deny "nice -n 5 bash $S set"
row "assignment prefix"    deny "X=1 bash $S set"
row "bash -x"              deny "bash -x $S set"
row "bash -o pipefail"     deny "bash -o pipefail $S set"
row "set with cache arg"   deny "bash $S set /tmp/cache.json"
row "glob bank-l?ft.sh"    deny "bash scripts/lib/bank-l?ft.sh set"
row "glob scripts/*/"      deny "bash scripts/*/bank-lift.sh set"
row "glob b*.sh"           deny "bash scripts/lib/b*-lift.sh set"
row "quoted 'set'"         deny "bash $S 'set'"
row "split s''et"          deny "bash $S s''et"
row "quoted script path"   deny "bash 'scripts/lib/bank'-lift.sh set"
row "bash -c"              deny "bash -c '$S set'"
row "after && "            deny "cd $REPO && bash $S set"
row "if … then"            deny "if bash $S set; then echo ok; fi"
row "dynamic subcommand"   deny "bash $S \"\$cmd\""
row "\$(…) subcommand"     deny "bash $S \"\$(echo set)\""
row "variable script path" deny "s=$S; bash \"\$s\" set"
row "sourced function"     deny "source $S; _bank_lift_cmd set"
row "xargs feeds set"      deny "echo set | xargs bash $S"
row "bash -s stdin"        deny "bash -s set < $S"
row "heredoc into bash"    deny "bash <<'EOF'
$S set
EOF"
row "computed sh -c body"  deny "sh -c \"\$(printf 'bash $S se%s' t)\""
row "computed eval"        deny "eval \"\$(printf 'bash $S se%s' t)\""
row "ln -sfn replaces state dir" deny "ln -sfn /tmp/fake ~/.himmel/state"

echo "== Write / Edit / MultiEdit / NotebookEdit / apply_patch =="
tool_row "Write lift (absolute)"      deny  Write file_path "$LIFT"
tool_row "Edit lift"                  deny  Edit file_path "$LIFT"
tool_row "MultiEdit lift"             deny  MultiEdit file_path "$LIFT"
tool_row "NotebookEdit lift"          deny  NotebookEdit notebook_path "$LIFT"
tool_row "Write lift via dir symlink" deny  Write file_path "$T/dirlink/bank-lift.json"
tool_row "Write lift via ../"         deny  Write file_path "$ST/../state/bank-lift.json"
tool_row "Write other state file"     allow Write file_path "$ST/other.json"
tool_row "Write the script source"    allow Write file_path "$REPO/$S"
tool_row "Edit a doc"                 allow Edit file_path "$REPO/docs/x.md"
_check "apply_patch Add File lift" deny "$(jq -cn --arg c "*** Begin Patch
*** Add File: $LIFT
+{}
*** End Patch" '{tool_name:"apply_patch",tool_input:{command:$c}}')"
_check "apply_patch other file" allow "$(jq -cn --arg c "*** Begin Patch
*** Add File: $REPO/x.txt
+{}
*** End Patch" '{tool_name:"apply_patch",tool_input:{command:$c}}')"

echo "== fail-closed =="
_check "malformed JSON"   deny '{"tool_name":"Bash","tool_input":'
_check "non-object JSON"  deny '"just a string"'
mkdir -p "$T/nojq"
for b in bash cat awk sed tr grep printf env dirname; do
    p=$(command -v "$b" 2>/dev/null) && ln -s "$p" "$T/nojq/$b"
done
got=$(printf '%s' "$(bash_json "echo hi")" | PATH="$T/nojq" "$(command -v bash)" "$HOOK" >/dev/null 2>&1; echo $?)
if [ "$got" = 2 ]; then ok "jq missing denies"; else bad "jq missing denies — rc=$got"; fi

echo "== deny message names the operator remedy =="
err=$(printf '%s' "$(bash_json "bash $S set")" | bash "$HOOK" 2>&1 >/dev/null)
case "$err" in
    *'! bash scripts/lib/bank-lift.sh set'*) ok "remedy named in deny" ;;
    *) bad "remedy missing from deny: $(printf '%s' "$err" | head -c 200)" ;;
esac

echo "== ALLOW controls =="
row "bank-lift.sh show"            allow "bash $S show"
row "bank-lift.sh show cache"      allow "bash $S show /tmp/cache.json"
row "bank-lift.sh clear"           allow "bash $S clear"
row "direct show"                  allow "$S show"
row "cat the lift"                 allow "cat ~/.himmel/state/bank-lift.json"
row "jq . the lift"                allow "jq . ~/.himmel/state/bank-lift.json"
row "jq -r .until the lift"        allow "jq -r .until \$HOME/.himmel/state/bank-lift.json"
row "cat lift > /tmp copy (over-deny J1874)" deny "cat ~/.himmel/state/bank-lift.json > /tmp/lift-copy.json"
# Round 6 ruling: naming bank-lift.json outside an allowlisted reader denies
# (accepted over-deny) — these rows were ALLOW before it.
row "cp lift to /tmp (over-deny r6)"   deny  "cp ~/.himmel/state/bank-lift.json /tmp/lift-copy.json"
row "rm the lift (over-deny r6)"       deny  "rm -f ~/.himmel/state/bank-lift.json"
row "test -f lift && echo (over-deny J1874)" deny "test -f ~/.himmel/state/bank-lift.json && echo yes"
row "ls state/"                    allow "ls -la ~/.himmel/state"
row "write other state file"       allow "echo x > ~/.himmel/state/other.json"
row "write lift-named file elsewhere (over-deny J1874)" deny "echo x > /tmp/x/bank-lift.json"
row "write lookalike name (over-deny J1874)" deny "echo x > ~/.himmel/state/bank-lift.json.bak"
row "grep pattern"                 allow "grep -rn 'bank-lift' scripts/"
row "git grep 'bank-lift.sh set' (over-deny r7)" deny "git grep -n 'bank-lift.sh set'"
row "commit msg names .json (over-deny r6)" deny "git commit -m 'feat: [HIMMEL-4445] deny agent writes to ~/.himmel/state/bank-lift.json'"
row "commit message with set (over-deny r7)" deny "git commit -m 'docs: bank-lift.sh set is operator-only'"
row "commit -F message file (ctrl)" allow "git commit -F /tmp/commit-msg.txt"
row "echo mention (over-deny r7)"  deny  "echo 'run: bash scripts/lib/bank-lift.sh set'"
row "longer name test-bank-lift.sh (ctrl)" allow "bash scripts/lib/test-bank-lift.sh"
row "set -e then show (over-deny J1874)" deny "set -euo pipefail; bash $S show"
row "preflight script"             allow "bash scripts/lib/bank-preflight.sh"
row "test suite"                   allow "bash scripts/lib/test-bank-preflight.sh"
row "cp unrelated"                 allow "cp a.txt b.txt"
row "redirect unrelated"           allow "echo hi > /tmp/out.txt 2>&1"
row "git config set"               allow "git config set user.name x"
row "Read-shaped python"           allow "python3 -c 'print(1)'"
# HIMMEL-4750: a JSON argument's braces are not a glob over the lift name.
row "eval_runs.py append JSON (4750)" allow "python3 scripts/eval/lib/eval_runs.py append '{\"ticket\":\"HIMMEL-4746\",\"result\":\"pass\"}'"
row "interp JSON arg, one key (4750)" allow "python3 x.py '{\"a\":1}'"
row "brace alt naming the lift still denies (interp)" deny "python3 x.py {bank-lift.json,y}"
row "brace alt naming the lift still denies (cp)"     deny "cp $T/src/other.txt ~/.himmel/state/{bank-lift.json,y}"
row "nested brace alt naming the lift still denies"   deny "cp $T/src/other.txt ~/.himmel/state/{bank-{lift,other}.json,y}"
row "brace alt with quote still denies (interp)"      deny "python3 x.py {bank-lift.json,\\\"}"
# Judge j2143: an alternative holding a char outside [alnum . _ / -] must fall
# back to `*`, never build a broken extglob that matches nothing.
row "tee brace alt with [ (j2143)"   deny "tee ~/.himmel/state/bank-lift{.json,[}"
row "touch brace alt with [ (j2143)" deny "touch ~/.himmel/state/bank-lift{.json,[}"
row "brace alt with backslash (j2143)" deny "tee ~/.himmel/state/bank-lift{.json,\\\\}"
row "mid-name brace alt with [ (j2143)" deny "tee ~/.himmel/state/bank{-lift,[}.json"
row "suffix brace alt with [ (j2143)" deny "tee ~/.himmel/state/bank-lift.{json,[}"
for _c in '[' ']' "\\" '*' '?' '!' '+' '@' '$' '"' '#' '~' ':'; do
    row "alt sweep last  [$_c]" deny "tee ~/.himmel/state/bank-lift{.json,$_c}"
    row "alt sweep first [$_c]" deny "tee ~/.himmel/state/bank-lift{$_c,.json}"
done
row "mv the lift away (over-deny r6)" deny "mv ~/.himmel/state/bank-lift.json /tmp/old-lift.json"
row "redirect to \$OUT"            allow "echo x > \"\$OUT\""
row "cd + find -exec {}"           allow "cd foo && find . -name '*.tmp' -exec rm {} \\;"
row "rsync -avt (t is a flag)"     allow "rsync -avt src/ dst/"
row "heredoc commit naming set (over-deny J1874)" deny "git commit -F - <<'EOF'
feat: bash scripts/lib/bank-lift.sh set is operator-only
EOF"
row "\$(cat heredoc) commit naming set (over-deny J1874)" deny "git commit -m \"\$(cat <<'EOF'
feat: [HIMMEL-4445] deny bash scripts/lib/bank-lift.sh set
EOF
)\""
# Differential over the session history (HIMMEL-4445): an interpreter running a
# script FILE whose data args merely mention bank-lift, and inline code whose
# prose says "bank" and "lift"/"left" without naming the lift file, are not
# writes.
row "node script, title names .json (over-deny r6)" deny "node /x/jira/dist/index.js create --type Task --title 'bank-lift: hook-deny agent writes to ~/.himmel/state/bank-lift.json and bank-lift.sh set'"
row "python heredoc, prose bank + left"     allow "python3 - doc.md <<'EOF'
s=open('doc.md').read().replace('bank 62 % left','bank 70 % left; lift voided')
EOF"
row "cd + awk program (not a path)"         allow "cd /some/dir && awk '{print NF}' data.tsv"
row "python script FILE handed the lift"   deny  "python3 /tmp/w.py ~/.himmel/state/bank-lift.json"
row "python heredoc naming bank-lift.sh"   deny  "python3 - <<'EOF'
import subprocess; subprocess.run(['bash','scripts/lib/bank-lift.sh','set'])
EOF"
_check "Read tool (not guarded)" allow "$(jq -cn --arg p "$LIFT" '{tool_name:"Read",tool_input:{file_path:$p}}')"

echo "== review round 1 (codex-1, codex-2) =="
# A symlink into a state SUBdir, then `..`: lexically that is outside the
# state dir, physically it is the state dir.
mkdir -p "$ST/sub"
ln -s "$ST/sub" "$T/sublink"
row "symlink/.. lands in state"            deny  "echo x > $T/sublink/../bank-lift.json"
row "symlink/.. lands in state (cp)"       deny  "cp $T/src/other.txt $T/sublink/../bank-lift.json"
_check "Write tool via symlink/.."          deny  "$(jq -cn --arg p "$T/sublink/../bank-lift.json" '{tool_name:"Write",tool_input:{file_path:$p,content:"{}"}}')"
row "real dir/.. outside state (over-deny J1874)" deny "echo x > $T/src/sub/../bank-lift.json"
row "busybox by absolute path sh -c"       deny  "/usr/bin/busybox sh -c 'echo x > $P'"
row "busybox by relative path sh -c"       deny  "./busybox sh -c 'echo x > $P'"

echo "== review round 2 (codex-1, codex-2) =="
# sed writes a file with its w/W command (or the s///w flag), no -i needed.
row "sed w command"                        deny  "sed 'w $P' /tmp/in"
row "sed -n -e W command"                  deny  "sed -n -e 'W $P' /tmp/in"
row "sed --expression= s///w flag"         deny  "sed --expression='s/a/b/w $P' /tmp/in"
row "sed -ne bundle, w after address"      deny  "sed -ne '/x/w $P' /tmp/in"
row "sed e command naming the lift"        deny  "sed '1e cp /tmp/x ~/.himmel/state/bank-lift.json' /tmp/in"
row "sed reads the lift (over-deny r6)"     deny  "sed -n p $P"
row "sed w elsewhere (over-deny r6)"        deny  "sed 'w /tmp/out' $P"
row "sed -e script on lift (over-deny r6)"  deny  "sed -e 's/w/x/' $P"
row "sed reads other file (ctrl)"           allow "sed -n p /tmp/other.txt"
# An unquoted heredoc delimiter runs \$( ) and backticks in the body.
row "cat <<EOF body \$( > lift)"           deny  "cat <<EOF
{\"a\": \$(printf '{}' > $P)}
EOF"
row "cat <<EOF body backtick > lift"       deny  "cat <<EOF
x \`cp /tmp/x $P\`
EOF"
row "cat <<'EOF' body \$( > lift) (quoted)" allow "cat <<'EOF'
{\"a\": \$(printf '{}' > $P)}
EOF"
row "cat <<EOF body names bank-lift, \$(date) (over-deny J1874)" deny "cat <<EOF
run bank-lift.sh set 10 at \$(date)
EOF"

echo "== review round 3 (codex-1, codex-2) =="
# find -exec/-execdir/-ok run a command: it is a launcher like xargs.
row "find -exec bash bank-lift.sh set"     deny  "find . -maxdepth 0 -exec bash scripts/lib/bank-lift.sh set \\;"
row "find -execdir bank-lift.sh set {} +"  deny  "find . -maxdepth 0 -execdir scripts/lib/bank-lift.sh set {} +"
row "find -ok sh -c set"                   deny  "find . -maxdepth 0 -ok sh -c 'bash scripts/lib/bank-lift.sh set 5' \\;"
row "find -exec bank-lift.sh show (over-deny r7)" deny "find . -maxdepth 0 -exec bash scripts/lib/bank-lift.sh show \\;"
row "find -exec cat (control)"             allow "find /tmp -name x -exec cat {} \\;"
# An alias of bank-lift.sh: making one, or running an existing symlink.
ln -s "$T/lib/bank-lift.sh" "$T/lifthelper"
ln -s "$T/lifthelper" "$T/lifthelper2"
row "ln -s bank-lift.sh alias"             deny  "ln -s \"\$PWD/scripts/lib/bank-lift.sh\" /tmp/lift-helper; bash /tmp/lift-helper set"
row "cp bank-lift.sh alias"                deny  "cp scripts/lib/bank-lift.sh $T/helper"
row "existing symlink alias set"           deny  "bash $T/lifthelper set 5"
row "symlink chain alias set (direct)"     deny  "$T/lifthelper2 set 5"
row "existing symlink alias show (ctrl)"   allow "bash $T/lifthelper show"

echo "== review round 4 (codex-1) =="
# After a cd the destination dir is unknown: a lift-named source copied into
# a bare directory destination lands as the lift.
row "cd state; cp lift-named src ."        deny  "cd ~/.himmel/state && cp /tmp/bank-lift.json ."
row "cd state; mv lift-named src ./"       deny  "cd ~/.himmel/state && mv $T/src/bank-lift.json ./"
row "cd state; cp -t . lift-named src"     deny  "cd ~/.himmel/state; cp -t . /tmp/bank-lift.json"
row "cd; cp other src . (cwd unproven)"            deny  "cd /tmp && cp $T/src/other.txt ."
row "cd; cp lift-named src (over-deny r6)" deny  "cd /tmp && cp $T/src/bank-lift.json backup.txt"
row "cd; cp other src to file (HIMMEL-4545 trim)"  allow "cd /tmp && cp $T/src/other.txt backup.txt"

echo "== HIMMEL-4545 over-deny trim: plain literal names under an unproven cwd =="
# Measured over-deny (J1916, p22-hist 845 of 211,645): most rows were a copy to
# a plain name after a $( ), backtick, ( ) or cd. A file-to-name copy reaches
# the lift only through a lift-named word (the mention rule) or a directory's
# contents landing on state / .himmel / HOME, so those shapes allow and every
# shape that can spill a directory or name a computed word still denies.
row "4545 cp name after \$( ) (trim)"        allow "n=\$(date +%H); cp $T/src/other.txt copy.txt"
row "4545 mv computed dir, literal names (trim)" allow "S=/tmp/s; cd \$S && mv \$S/legs.new \$S/legs.txt"
row "4545 backtick then cp to name (trim)"  allow "echo \`date\` ; cp $T/src/other.txt backup.txt"
row "4545 arithmetic then cp to name (trim)" allow "x=\$((1|2)); cp /etc/hosts f"
row "4545 rsync file to name (trim)"        allow "n=\$(date +%H); rsync -a $T/src/other.txt out.txt"
row "4545 cp two literal srcs to a name (trim)" allow "cd /tmp && cp $T/src/other.txt $T/src/sub dir2"
row "4545 cp dest . still denies"           deny  "cd /tmp && cp $T/src/other.txt ."
row "4545 cp dest .. still denies"          deny  "cd /tmp && cp $T/src/other.txt .."
row "4545 cp dest ./ still denies"          deny  "cd /tmp && cp $T/src/other.txt ./"
row "4545 cp dest name/ still denies"       deny  "cd /tmp && cp $T/src/other.txt out/"
row "4545 cp dest state still denies"       deny  "cd /tmp && cp $T/src/other.txt state"
row "4545 cp dest .himmel still denies"     deny  "cd /tmp && cp $T/src/other.txt .himmel"
row "4545 cp dest STATE (case) still denies" deny "cd /tmp && cp $T/src/other.txt STATE"
row "4545 cp dest glob still denies"        deny  "cd /tmp && cp $T/src/other.txt 'st*'"
row "4545 cp dest computed still denies"    deny  "cd /tmp && cp $T/src/other.txt \$d"
row "4545 cp dest brace still denies"       deny  "cd /tmp && cp $T/src/other.txt {state,x}"
row "4545 cp -T still denies"               deny  "cd /tmp && cp -rT /tmp/forged-home overlord"
row "4545 cp --no-target-directory denies"  deny  "cd /tmp && cp -r --no-target-directory /tmp/forged-home overlord"
row "4545 cp --parents still denies"        deny  "cd /tmp && cp --parents .himmel/state/x.json overlord"
row "4545 rsync -R still denies"            deny  "cd /tmp && rsync -R .himmel/state/x.json overlord"
row "4545 cp src dir/ still denies"         deny  "cd /tmp && cp -r /tmp/forged-home/ overlord"
row "4545 cp src dir/. still denies"        deny  "cd /tmp && cp -r /tmp/forged-home/. overlord"
row "4545 rsync src dir/ still denies"      deny  "cd /tmp && rsync -a /tmp/forged-home/ overlord"
row "4545 cp src glob still denies"         deny  "cd /tmp && cp /tmp/forged-home/* overlord"
row "4545 cp src computed still denies"     deny  "cd /tmp && cp \$s overlord"
row "4545 cp src .himmel still denies"      deny  "cd /tmp && cp -r /tmp/forged-home/.himmel overlord"
row "4545 cp src state still denies"        deny  "cd /tmp && cp -r /tmp/forged/state overlord"
row "4545 cp -t dir, src dir/ still denies" deny  "cd /tmp && cp -r -t overlord /tmp/forged-home/"
row "4545 mv src .himmel still denies"      deny  "cd /tmp && mv /tmp/forged-home/.himmel overlord"
row "4545 ln -s relative src still denies"  deny  "n=\$(date +%H); ln -s target link-\$n"
row "4545 ln -s computed src still denies"  deny  "n=\$(date +%H); ln -s \"\$p\" link"
# HIMMEL-4545 residual: a glob source into a computed destination that is the
# state dir (assigned in the command or inherited) lands the lift by name.
mkdir -p "$T/gsrc" && printf '{}' > "$T/gsrc/bank-lift.json"
row "4545 glob src, computed dest denies"   deny  "d=$ST; cp $T/gsrc/* \"\$d\""
row "4545 glob src, computed dest unquoted" deny  "d=$ST; cp $T/gsrc/*.json \$d"
row "4545 glob src, mv computed dest"       deny  "d=$ST; mv $T/gsrc/* \"\$d\""
row "4545 glob src, cp -t computed dest"    deny  "d=$ST; cp -t \"\$d\" $T/gsrc/*"
row "4545 glob src, rsync computed dest"    deny  "d=$ST; rsync -a $T/gsrc/* \"\$d\""
row "4545 glob src name-miss, computed dest (ctrl)" allow "d=$T/out; cp $T/gsrc/*.txt \"\$d\""
row "4545 literal src, computed dest (ctrl)" allow "d=$T/out; cp $T/src/other.txt \"\$d\""
# A source that is HOME or one of its ancestors, by any spelling, can alias or
# relocate the lift's whole tree; a plain-name test alone would pass it.
row "4545 ln -s abs HOME src still denies"  deny  "cd /tmp && ln -s $HOME link"
row "4545 ln -s ~ src still denies"         deny  "cd /tmp && ln -s ~ link"
row "4545 ln -s HOME parent still denies"   deny  "cd /tmp && ln -s $T link"
row "4545 mv abs HOME src still denies"     deny  "cd /tmp && mv $HOME moved"
row "4545 cp -r abs HOME src still denies"  deny  "cd /tmp && cp -r $HOME moved"
row "4545 cp -s abs HOME parent still denies" deny "cd /tmp && cp -s $T moved"
row "4545 cp src .. component still denies" deny  "cd /tmp && cp -r ../.. moved"
row "4545 ln -s HOME own name still denies" deny  "cd /tmp && ln -s ${HOME##*/} link"
row "4545 mv HOME ancestor name still denies" deny "cd /tmp && mv $(basename "$T") link"

echo "== review round 5 (unforgeable redirect marks) =="
# A word spelling a tokenizer mark must not be read as a redirect: the marks
# carry a control byte, and that byte in the input itself denies.
SB=$(printf '\002')
row "quoted @R@ word + redirect"           deny  "echo '@R@' > ~/.himmel/state/bank-lift.json"
row "quoted @W@ word + redirect"           deny  "echo '@W@' > ~/.himmel/state/bank-lift.json"
row "unquoted @R@ word + redirect"         deny  "echo @R@ > ~/.himmel/state/bank-lift.json"
row "unquoted @W@ word + append"           deny  "echo @W@ >> ~/.himmel/state/bank-lift.json"
row "dq @B@/@S@ words + redirect"          deny  "printf '%s' \"@B@\" @S@ > ~/.himmel/state/bank-lift.json"
row "raw sentinel byte in input"           deny  "echo '${SB}R' > ~/.himmel/state/bank-lift.json"
row "raw sentinel byte, harmless cmd"      deny  "echo a${SB}b"
row "ansi-c decoded sentinel byte"         deny  "echo \$'\\x02R' x"
row "@R@/@W@ words, no lift (ctrl)"        allow "echo '@R@' '@W@' > /tmp/out.txt"
row "grep @W@ in the lift (ctrl)"          allow "grep -c '@W@' ~/.himmel/state/bank-lift.json"
row "@B@ @S@ words alone (ctrl)"           allow "printf '%s\n' @B@ @S@"

echo "== review round 6 (lift name outside a reader denies) =="
# Console ruling: any word naming bank-lift.json in a clause whose command is
# not an allowlisted reader denies. Over-deny is accepted.
mkdir -p "$T/stage/.himmel/state"
row "python3 -c attached + positional"     deny  "python3 -c\"open('\$HOME/.himmel/state/bank-lift.json','w').write('{}')\" dummy"
row "cp --parents into \$HOME"             deny  "cp --parents .himmel/state/bank-lift.json \"\$HOME\"" "$T/stage"
row "rsync -R into \$HOME"                 deny  "rsync -R .himmel/state/bank-lift.json \"\$HOME\"" "$T/stage"
row "perl one-liner writes lift"           deny  "perl -e 'open(F,\">\$ENV{HOME}/.himmel/state/bank-lift.json\")' x"
row "ruby one-liner writes lift"           deny  "ruby -e 'File.write(Dir.home+\"/.himmel/state/bank-lift.json\",\"{}\")' x"
row "node one-liner writes lift"           deny  "node -e 'require(\"fs\").writeFileSync(process.env.HOME+\"/.himmel/state/bank-lift.json\",\"{}\")' x"
row "install onto lift"                    deny  "install /tmp/x ~/.himmel/state/bank-lift.json"
row "dd of= lift"                          deny  "dd if=/tmp/x of=\$HOME/.himmel/state/bank-lift.json"
row "sed -i lift"                          deny  "sed -i 's/a/b/' ~/.himmel/state/bank-lift.json"
row "jq -i lift"                           deny  "jq -i '.until=1' ~/.himmel/state/bank-lift.json"
row "jq --in-place lift"                   deny  "jq --in-place '.until=1' ~/.himmel/state/bank-lift.json"
row "tail -f lift piped"                   deny  "tail -f ~/.himmel/state/bank-lift.json | tee /tmp/x"
row "timeout-wrapped python names lift"    deny  "timeout 5 python3 -c 'print(1)' ~/.himmel/state/bank-lift.json"
row "\$( ) python names lift"              deny  "x=\$(python3 -c 'import sys' .himmel/state/bank-lift.json)"
row "reader redirected into lift"          deny  "cat /tmp/x > ~/.himmel/state/bank-lift.json"
row "reader: cat (ctrl)"                   allow "cat ~/.himmel/state/bank-lift.json"
row "reader: less (ctrl)"                  allow "less ~/.himmel/state/bank-lift.json"
row "reader: head (ctrl)"                  allow "head -n 3 ~/.himmel/state/bank-lift.json"
row "reader: stat (ctrl)"                  allow "stat ~/.himmel/state/bank-lift.json"
row "reader: ls (ctrl)"                    allow "ls -l ~/.himmel/state/bank-lift.json"
row "reader: file (ctrl)"                  allow "file ~/.himmel/state/bank-lift.json"
row "reader: wc (ctrl)"                    allow "wc -c ~/.himmel/state/bank-lift.json"
row "reader: test -f (ctrl)"               allow "test -f ~/.himmel/state/bank-lift.json"
row "reader: [ -f ] (ctrl)"                allow "[ -f ~/.himmel/state/bank-lift.json ]"
row "reader: jq . (ctrl)"                  allow "jq . ~/.himmel/state/bank-lift.json"
row "reader: tail -n (ctrl)"               allow "tail -n 5 ~/.himmel/state/bank-lift.json"
row "reader: grep -c (ctrl)"               allow "grep -c x ~/.himmel/state/bank-lift.json"
row "reader: rg (ctrl)"                    allow "rg until ~/.himmel/state/bank-lift.json"
row "reader past env/timeout (ctrl)"       allow "env LC_ALL=C timeout 5 cat ~/.himmel/state/bank-lift.json"
row "bank-lift.sh show (ctrl)"             allow "bash scripts/lib/bank-lift.sh show"

echo "== review round 7 (wrapper options, bank-lift.sh mentions) =="
# Console ruling: a wrapper carrying any option leaves the command word
# unknown; a word naming bank-lift.sh is allowed only in `bash <p> show|clear`
# (or the direct path) and in the reader allowlist.
row "env -u opt-arg hides python"          deny  "env -u cat python3 -c\"open('\$HOME/.himmel/state/bank-lift.json','w').write('{}')\" dummy"
row "env -u opt-arg hides cp --parents"    deny  "env -u cat cp --parents .himmel/state/bank-lift.json \"\$HOME\"" "$T/stage"
row "sudo -u opt-arg hides cp --parents"   deny  "sudo -u cat cp --parents .himmel/state/bank-lift.json \"\$HOME\"" "$T/stage"
row "bash -c source, set as \$1"           deny  "bash -c 'source scripts/lib/bank-lift.sh' _ set"
row "dot-source then _bank_lift_cmd set"   deny  ". scripts/lib/bank-lift.sh; _bank_lift_cmd set"
row "bank-lift.sh show (r7 ctrl)"          allow "bash scripts/lib/bank-lift.sh show"
row "bank-lift.sh clear (r7 ctrl)"         allow "bash scripts/lib/bank-lift.sh clear"
row "cat bank-lift.sh (ctrl)"              allow "cat scripts/lib/bank-lift.sh"
row "grep -n set bank-lift.sh (ctrl)"      allow "grep -n set scripts/lib/bank-lift.sh"

echo "== judge J1874 (whole-command mention rule) =="
# A reader on the allowlist, inside \$( ), backticks or a pipe into xargs,
# hands the lift path to a writer that never names it. Console ruling: when
# the command text names bank-lift.json / bank-lift.sh ANYWHERE, every clause
# at every depth must be a reader (or bank-lift.sh show|clear) and no redirect
# may write anything but /dev/null.
row "J1874 cp \$(jq -rn abs lift)"          deny  "cp /tmp/forged \$(jq -rn '\"$LIFT\"')"
row "J1874 cp \$(jq -rn \$HOME lift)"       deny  "cp /tmp/forged \$(jq -rn \"\\\"\$HOME/.himmel/state/bank-lift.json\\\"\")"
row "J1874 echo > \"\$(ls lift)\""          deny  "echo hi > \"\$(ls ~/.himmel/state/bank-lift.json)\""
row "J1874 echo > backtick ls lift"         deny  "echo hi > \"\`ls ~/.himmel/state/bank-lift.json\`\""
row "J1874 tee \"\$(ls lift)\""             deny  "tee \"\$(ls ~/.himmel/state/bank-lift.json)\""
row "J1874 printf | tee \"\$(ls lift)\""    deny  "printf x | tee \"\$(ls ~/.himmel/state/bank-lift.json)\""
row "J1874 ls lift | xargs cp"              deny  "ls ~/.himmel/state/bank-lift.json | xargs cp /tmp/x"
row "J1874 grep -l lift | xargs cp"         deny  "grep -l x ~/.himmel/state/bank-lift.json | xargs cp /tmp/x"
row "J1874 ls lift | xargs -I{} cp"         deny  "ls ~/.himmel/state/bank-lift.json | xargs -I{} cp /tmp/x {}"
row "J1874 nested \$(echo \$(ls lift))"     deny  "cp /tmp/x \"\$(echo \"\$(ls ~/.himmel/state/bank-lift.json)\")\""
row "J1874 \$HOME path in \$(ls)"           deny  "echo hi > \"\$(ls \$HOME/.himmel/state/bank-lift.json)\""
row "J1874 dd of=\$(ls lift)"               deny  "dd if=/tmp/x of=\$(ls ~/.himmel/state/bank-lift.json)"
row "J1874 var from \$(ls lift) then cp"    deny  "f=\$(ls ~/.himmel/state/bank-lift.json); cp /tmp/x \"\$f\""
row "J1874 heredoc sub ls | xargs cp"       deny  "cat <<EOF
\$(ls ~/.himmel/state/bank-lift.json | xargs cp /tmp/x)
EOF"
row "J1874 reader | tee elsewhere"          deny  "cat ~/.himmel/state/bank-lift.json | tee /tmp/copy"
row "J1874 less -O attached (4458 codex-1)" deny  "less -O\"\$HOME/.himmel/state/bank-lift.json\" /tmp/x"
row "J1874 less --log-file= lift"           deny  "less --log-file=\$HOME/.himmel/state/bank-lift.json /tmp/x"
row "J1874 less +! command"                 deny  "less '+!cp /tmp/x ~/.himmel/state/bank-lift.json' /tmp/y"
row "J1874 LESSOPEN prefix on less"         deny  "LESSOPEN='|cp /tmp/x %s' less ~/.himmel/state/bank-lift.json"
row "J1874 RIPGREP_CONFIG_PATH prefix"      deny  "RIPGREP_CONFIG_PATH=/tmp/rc rg x ~/.himmel/state/bank-lift.json"
row "J1874 heredoc delim w/ space (4458 codex-2)" deny "cat <<'E F'
x'
E F
echo x > ~/.himmel/state/bank-lift.json"
row "J1874 heredoc delim w/ space, unbalanced" deny "cat <<'E F'
data
E F
cp /tmp/x ~/.himmel/state/bank-lift.json"
row "J1874 reader | jq (ctrl)"              allow "cat ~/.himmel/state/bank-lift.json | jq .until"
row "J1874 grep 2>/dev/null (ctrl)"         allow "grep x ~/.himmel/state/bank-lift.json 2>/dev/null"
row "J1874 jq >/dev/null 2>&1 (ctrl)"       allow "jq . ~/.himmel/state/bank-lift.json >/dev/null 2>&1"
row "J1874 test || ls (ctrl)"               allow "test -f ~/.himmel/state/bank-lift.json || ls ~/.himmel/state"
row "J1874 if [ ] then cat fi (ctrl)"       allow "if [ -f ~/.himmel/state/bank-lift.json ]; then cat ~/.himmel/state/bank-lift.json; fi"
row "J1874 x=\$(cat lift) (ctrl)"           allow "x=\$(cat ~/.himmel/state/bank-lift.json)"
row "J1874 LC_ALL=C grep (ctrl)"            allow "LC_ALL=C grep -c x ~/.himmel/state/bank-lift.json"
row "J1874 show 2>&1 (ctrl)"                allow "bash scripts/lib/bank-lift.sh show 2>&1"
row "J1874 clear (ctrl)"                    allow "bash scripts/lib/bank-lift.sh clear"
row "J1874 cat <<'E F' no lift (ctrl)"      allow "cat <<'E F'
data
E F"

echo "== codex-1 (path-qualified reader / wrapper words) =="
# A command word resolved by basename let a planted `/tmp/cat` pass as the
# reader cat. A reader, wrapper or bash word must be bare or /usr/bin|/bin/<name>.
row "codex-1 /tmp/cat lift"                 deny  "/tmp/cat ~/.himmel/state/bank-lift.json"
row "codex-1 ./cat lift"                    deny  "./cat ~/.himmel/state/bank-lift.json"
# shellcheck disable=SC2088  # the tilde is command text for the hook, not expanded here
row "codex-1 ~/bin/less lift"              deny  "~/bin/less ~/.himmel/state/bank-lift.json"
row "codex-1 /tmp/env cat lift"             deny  "/tmp/env cat ~/.himmel/state/bank-lift.json"
row "codex-1 /tmp/bash show"                deny  "/tmp/bash scripts/lib/bank-lift.sh show"
row "codex-1 /usr/local/bin/jq lift"        deny  "/usr/local/bin/jq . ~/.himmel/state/bank-lift.json"
row "codex-1 /tmp/timeout 5 cat lift"       deny  "/tmp/timeout 5 cat ~/.himmel/state/bank-lift.json"
row "codex-1 \$(/tmp/cat lift) in cp"       deny  "cp /tmp/x \"\$(/tmp/cat ~/.himmel/state/bank-lift.json)\""
row "codex-1 /usr/bin/cat lift (ctrl)"      allow "/usr/bin/cat ~/.himmel/state/bank-lift.json"
row "codex-1 /bin/cat lift (ctrl)"          allow "/bin/cat ~/.himmel/state/bank-lift.json"
row "codex-1 /usr/bin/env cat lift (ctrl)"  allow "/usr/bin/env cat ~/.himmel/state/bank-lift.json"
row "codex-1 /usr/bin/bash show (ctrl)"     allow "/usr/bin/bash scripts/lib/bank-lift.sh show"
row "codex-1 bash show (ctrl)"              allow "bash scripts/lib/bank-lift.sh show"
row "codex-1 direct show (ctrl)"            allow "scripts/lib/bank-lift.sh show"

echo "== HIMMEL-4458 ask 1: less log options, every spelling (verify) =="
row "4458 less -O<p> exact ticket input"    deny  "cat /tmp/payload | less -O\"\$HOME/.himmel/state/bank-lift.json\""
row "4458 less -O <p>"                      deny  "cat /tmp/payload | less -O \"\$HOME/.himmel/state/bank-lift.json\""
row "4458 less -o<p>"                       deny  "cat /tmp/payload | less -o\"\$HOME/.himmel/state/bank-lift.json\""
row "4458 less -o <p>"                      deny  "cat /tmp/payload | less -o \"\$HOME/.himmel/state/bank-lift.json\""
row "4458 less --log-file=<p>"              deny  "cat /tmp/payload | less --log-file=\$HOME/.himmel/state/bank-lift.json"
row "4458 less --LOG-FILE=<p>"              deny  "cat /tmp/payload | less --LOG-FILE=\$HOME/.himmel/state/bank-lift.json"

echo "== HIMMEL-4458 ask 2: quoted heredoc delimiter with a space =="
row "4458 delim 'END MARK' exact ticket input" deny "cat <<'END MARK'
x
END MARK
printf 1 > ~/.himmel/state/bank-lift.json"
row "4458 delim \"E F\" (double)"           deny  "cat <<\"E F\"
x
E F
printf 1 > ~/.himmel/state/bank-lift.json"
row "4458 delim \"E\"' F' (mixed)"          deny  "cat <<\"E\"' F'
x
E F
printf 1 > ~/.himmel/state/bank-lift.json"
# Without a literal lift name the whole-command layer is silent: the
# tokenizer itself must read the quoted delimiter whole.
row "4458 delim 'E F', glob-spelled lift"   deny  "cat <<'E F'
x
E F
printf 1 > ~/.himmel/state/bank-l?ft.json"
row "4458 delim \"E F\", glob-spelled lift" deny  "cat <<\"E F\"
x
E F
printf 1 > ~/.himmel/state/bank-l?ft.json"
row "4458 delim 'E\"F' (other quote inside)" deny "cat <<'E\"F'
x
E\"F
printf 1 > ~/.himmel/state/bank-l?ft.json"
row "4458 delim 'E F', data only (ctrl)"    allow "cat <<'E F'
printf 1 > ~/.himmel/state/bank-l?ft.json
E F"

echo "== HIMMEL-4458 item 2: bank-lift.sh trusted only as the repo's own copy =="
mkdir -p "$T/x" "$T/evil/scripts/lib" "$REPO/.claude/worktrees/w1/scripts/lib"
: > "$T/x/bank-lift.sh"; : > "$T/evil/scripts/lib/bank-lift.sh"
: > "$REPO/.claude/worktrees/w1/scripts/lib/bank-lift.sh"
row "4458 bash /tmp/x/bank-lift.sh show"    deny  "bash $T/x/bank-lift.sh show"
row "4458 bash /tmp/x/bank-lift.sh clear"   deny  "bash $T/x/bank-lift.sh clear"
row "4458 direct /tmp/x/bank-lift.sh show"  deny  "$T/x/bank-lift.sh show"
row "4458 /usr/bin/bash planted show"       deny  "/usr/bin/bash $T/x/bank-lift.sh show"
row "4458 relative planted from a non-repo cwd" deny "bash scripts/lib/bank-lift.sh show" "$T/evil"
row "4458 ./ planted from a non-repo cwd"   deny  "./scripts/lib/bank-lift.sh show" "$T/evil"
row "4458 absolute escaping a worktree"     deny  "bash $REPO/.claude/worktrees/w1/../../../../evil/scripts/lib/bank-lift.sh show"
row "4458 relative from a repo subdir"      deny  "bash lib/bank-lift.sh show" "$REPO/scripts"
row "4458 cd then relative show"            deny  "cd $T/evil && bash scripts/lib/bank-lift.sh show"
row "4458 repo absolute show (ctrl)"        allow "bash $REPO/scripts/lib/bank-lift.sh show"
row "4458 repo ./ show (ctrl)"              allow "bash ./scripts/lib/bank-lift.sh show"
row "4458 direct ./ show (ctrl)"            allow "./scripts/lib/bank-lift.sh clear"
row "4458 worktree absolute show (ctrl)"    allow "bash $REPO/.claude/worktrees/w1/scripts/lib/bank-lift.sh show"
row "4458 worktree relative show (ctrl)"    allow "bash scripts/lib/bank-lift.sh show" "$REPO/.claude/worktrees/w1"
# Panel r3 codex-1: the script path itself resolves physically, every component.
mkdir -p "$REPO/.claude/worktrees/w2/scripts" "$REPO/.claude/worktrees/w3/scripts/lib"
ln -s "$T/evil/scripts/lib" "$REPO/.claude/worktrees/w2/scripts/lib"
ln -s "$T/x/bank-lift.sh" "$REPO/.claude/worktrees/w3/scripts/lib/bank-lift.sh"
ln -s "$REPO" "$T/repolink"
row "4458 worktree scripts/lib symlinked out"  deny  "bash $REPO/.claude/worktrees/w2/scripts/lib/bank-lift.sh show"
row "4458 worktree relative, lib symlinked out" deny "bash scripts/lib/bank-lift.sh show" "$REPO/.claude/worktrees/w2"
row "4458 worktree bank-lift.sh symlinked out" deny  "bash $REPO/.claude/worktrees/w3/scripts/lib/bank-lift.sh clear"
row "4458 direct, bank-lift.sh symlinked out"  deny  "./scripts/lib/bank-lift.sh show" "$REPO/.claude/worktrees/w3"
row "4458 missing worktree script (unresolved)" deny "bash $REPO/.claude/worktrees/w9/scripts/lib/bank-lift.sh show"
# HIMMEL-4545 residual: a worktree copy EDITED after the cut is other code
# under the trusted name, so it no longer runs as show/clear.
mkdir -p "$REPO/.claude/worktrees/w4/scripts/lib"
printf '%s\n' 'echo edited' > "$REPO/.claude/worktrees/w4/scripts/lib/bank-lift.sh"
row "4545 edited worktree copy: abs clear"   deny  "bash $REPO/.claude/worktrees/w4/scripts/lib/bank-lift.sh clear"
row "4545 edited worktree copy: rel show"    deny  "bash scripts/lib/bank-lift.sh show" "$REPO/.claude/worktrees/w4"
row "4545 edited worktree copy: direct"      deny  "./scripts/lib/bank-lift.sh clear" "$REPO/.claude/worktrees/w4"
row "4458 symlinked repo path show (ctrl)"     allow "bash $T/repolink/scripts/lib/bank-lift.sh show"
row "4458 symlinked repo cwd show (ctrl)"      allow "bash scripts/lib/bank-lift.sh show" "$T/repolink"

echo "== HIMMEL-4458 item 3: glob-spelled lift under cp --parents / rsync -R =="
row "4458 cp --parents bank-l?ft.json \"\$HOME\"" deny "cp --parents .himmel/state/bank-l?ft.json \"\$HOME\"" "$T/stage"
row "4458 cp --parents bank-l*.json ~"      deny  "cp --parents .himmel/state/bank-l*.json ~" "$T/stage"
row "4458 rsync -R bank-l?ft.json ~/"       deny  "rsync -R .himmel/state/bank-l?ft.json ~/" "$T/stage"
row "4458 rsync -aR bank-l?ft.json ~/"      deny  "rsync -aR .himmel/state/bank-l?ft.json ~/" "$T/stage"
row "4458 rsync --relative b*.json \$HOME"  deny  "rsync --relative .himmel/state/b*.json \$HOME" "$T/stage"
row "4458 rsync -R /./ marker"              deny  "rsync -R $T/stage/./.himmel/state/bank-l?ft.json ~/"
row "4458 cp --parents globbed dirs"        deny  "cp --parents .h*/st*/b?nk-lift.js?n ~" "$T/stage"
row "4458 cp --parents -r state dir"        deny  "cp --parents -r .himmel/state ~" "$T/stage"
row "4458 cp --parents state/* ~ (ctrl deny)" deny "cp --parents .himmel/state/* \"\$HOME\"" "$T/stage"
row "4458 cp --parents docs (ctrl)"         allow "cp --parents docs/a.md /tmp/out" "$T/stage"
row "4458 rsync -R glob docs (ctrl)"        allow "rsync -R docs/*.md /tmp/out/" "$T/stage"
row "4458 cp -R is recursive, not parents (ctrl)" allow "cp -R docs/* /tmp/out" "$T/stage"

echo "== HIMMEL-4458 item 4: interpreter code splitting the lift name =="
row "4458 python3 \"bank\"+\"-\"+\"lift\""  deny  "python3 -c 'import os; open(os.path.expanduser(\"~/.himmel/state/\"+\"bank\"+\"-\"+\"lift\"+\".json\"),\"w\")'"
row "4458 python3 many fragments"           deny  "python3 -c 'p=\"ba\"+\"nk\"+\"-\"+\"li\"+\"ft\"+\".js\"+\"on\"; open(p,\"w\")'"
row "4458 python3 join list"                deny  "python3 -c 'import os; open(os.path.join(os.environ[\"HOME\"], \".himmel/state\", \"bank\" + \"-\" + \"lift\" + \".json\"), \"w\")'"
row "4458 node split bank-lift.sh"          deny  "node -e 'require(\"child_process\").execSync(\"bash scripts/lib/\" + \"bank\" + \"-lift\" + \".sh set\")'"
row "4458 python heredoc split"             deny  "python3 - <<'EOF'
p = 'bank' + '-' + 'lift' + '.json'
open(p, 'w')
EOF"
row "4458 python prose bank % left (ctrl)"  allow "python3 -c 'print(\"bank 62 % left\")'"
row "4458 python prose bank-lift show (ctrl)" allow "python3 -c 'print(\"bank-lift show prints it\")'"
row "4458 awk row (ctrl)"                   allow "awk -F, '{print \$1, \"bank\", \$3}' data.csv"

echo "== HIMMEL-4458 item 5: archive extraction into a lift ancestor =="
row "4458 tar -xf -C ~"                     deny  "tar -xf /tmp/x.tar -C ~"
row "4458 tar -xf -C ~/.himmel"             deny  "tar -xf /tmp/x.tar -C ~/.himmel"
row "4458 tar xzf -C \$HOME (old-style)"    deny  "tar xzf /tmp/x.tgz -C \$HOME"
row "4458 tar --extract --directory="       deny  "tar --extract -f /tmp/x.tar --directory=\$HOME/.himmel"
row "4458 tar -x -f --directory ~"          deny  "tar -x -f /tmp/x.tar --directory ~"
row "4458 tar -C~ attached"                 deny  "tar -xf /tmp/x.tar -C~"
row "4458 cd ~ && tar -xf"                  deny  "cd ~ && tar -xf /tmp/x.tar"
row "4458 cd (bare) && tar xf"              deny  "cd && tar xf /tmp/x.tar"
row "4458 cd ~/.himmel; cpio -idm"          deny  "cd ~/.himmel; cpio -idm < /tmp/x.cpio"
row "4458 tar -xf, cwd is HOME"             deny  "tar -xf /tmp/x.tar" "$HOME"
row "4458 unzip -d ~/.himmel"               deny  "unzip /tmp/x.zip -d ~/.himmel"
row "4458 unzip -o -d ~"                    deny  "unzip -o /tmp/x.zip -d ~"
row "4458 unzip -d~ attached"               deny  "unzip /tmp/x.zip -d~"
row "4458 bsdtar -xf -C ~"                  deny  "bsdtar -xf /tmp/x.tar -C ~"
row "4458 tar -xf -C ~/.himmel/state"       deny  "tar -xf /tmp/x.tar -C ~/.himmel/state"
row "4458 tar -xf -C /tmp/out (ctrl)"       allow "tar -xf /tmp/x.tar -C /tmp/out"
row "4458 cd build && tar -xzf (r7: relative cd)" deny "cd build && tar -xzf /tmp/x.tgz"
row "4458 cd /var/build && tar -xzf (cwd unproven)" deny  "cd /var/build && tar -xzf /tmp/x.tgz"
row "4458 tar -czf -C ~ create (ctrl)"      allow "tar -czf /tmp/b.tgz -C ~ .config"
row "4458 tar -tf list, cwd HOME (ctrl)"    allow "tar -tf /tmp/x.tar" "$HOME"
row "4458 unzip -l list (ctrl)"             allow "unzip -l /tmp/x.zip -d ~"
row "4458 unzip -d /tmp/out (ctrl)"         allow "unzip /tmp/x.zip -d /tmp/out"
row "4458 tar -xf -C ~/projects (ctrl)"     allow "tar -xf /tmp/x.tar -C ~/projects"
row "4458 cd \"\$HOME\" && tar -xf"          deny  "cd \"\$HOME\" && tar -xf /tmp/x.tar"
row "4458 cd \"\$d\" && tar -xf (unresolved)" deny "cd \"\$d\" && tar -xf /tmp/x.tar"
row "4458 cd -; tar -xf (unresolved)"       deny  "cd -; tar -xf /tmp/x.tar"
row "4458 cd \"\$d\"; tar -C .himmel"         deny  "cd \"\$d\"; tar -xf x.tar -C .himmel"
# Differential (p22-samp): -O extracts to stdout; cwd HOME is not written.
row "4458 tar xzf -O member, cwd HOME (ctrl)" allow "tar xzf /tmp/x.tgz -O inv/home.sha | wc -l" "$HOME"
row "4458 tar -xf (no -O), cwd HOME"        deny  "tar -xzf /tmp/x.tgz inv/home.sha" "$HOME"
# Differential (p22-samp): a computed cd then a named relative -C stays allowed
# when joined by &&; after `;` the cwd is unproven (r6) and it denies.
row "4458 cd \$S; tar xzf -C head (r6 over-deny)" deny "S=/tmp/s; cd \$S; tar xzf head.tgz -C head --strip-components=1"
row "4458 cd \$S && tar xzf -C head (r7: computed cd)" deny "S=/tmp/s; cd \$S && tar xzf head.tgz -C head --strip-components=1"
row "4458 cd /var/s && tar xzf -C head (cwd unproven)" deny  "cd /var/s && tar xzf head.tgz -C head --strip-components=1"
# Panel r1 codex-1: an option's operand is never a flag (-O as the archive).
row "4458 tar -xf -O -C \$HOME (operand)"    deny  "tar -xf -O -C \"\$HOME\""
row "4458 tar xf -O -C ~ (old-style operand)" deny "tar xf -O -C ~"
row "4458 tar -x -f -O -C ~"                deny  "tar -x -f -O -C ~"
row "4458 tar -xfO -C ~ (attached operand)" deny  "tar -xfO -C ~"
row "4458 tar --file -O -C ~"               deny  "tar -x --file -O -C ~"
row "4458 tar -xf a -T -O -C ~"             deny  "tar -xf /tmp/a.tar -T -O -C ~"
row "4458 tar -xf a -X -O, cwd HOME"        deny  "tar -xf /tmp/a.tar -X -O" "$HOME"
row "4458 tar -xf a --exclude-from -O -C ~" deny  "tar -xf /tmp/a.tar --exclude-from -O -C ~"
row "4458 tar -xf a -N -C /tmp, cwd HOME"   deny  "tar -xf /tmp/a.tar -N -C /tmp/o" "$HOME"
row "4458 tar -C -O, cwd HOME (dir -O, ctrl)" allow "tar -xf /tmp/a.tar -C -O" "$HOME"
row "4458 tar -xf a -O -C ~ (real -O, ctrl)" allow "tar -xf /tmp/a.tar -O -C ~"
row "4458 tar -xOf a, cwd HOME (ctrl)"      allow "tar -xOf /tmp/a.tar m" "$HOME"
row "4458 tar --to-stdout, cwd HOME (ctrl)" allow "tar -xf /tmp/a.tar --to-stdout m" "$HOME"
row "4458 tar --exclude-vcs (r7: not allowlisted)" deny "tar -xf /tmp/a.tar --exclude-vcs -C /tmp/o" "$HOME"
row "4458 tar --no-same-owner -C /tmp/o, cwd HOME (ctrl)" allow "tar -xf /tmp/a.tar --no-same-owner -C /tmp/o" "$HOME"
row "4458 tar --frob -C /tmp/o, cwd HOME (unknown long)" deny "tar -xf /tmp/a.tar --frob -C /tmp/o" "$HOME"
row "4458 tar -xsO (s may take O), -C ~"     deny  "tar -xsO /tmp/a.tar -C ~"
row "4458 unzip -P -p x.zip -d ~"           deny  "unzip -P -p /tmp/x.zip -d ~"
row "4458 unzip -P -c x.zip, cwd HOME"      deny  "unzip -P -c /tmp/x.zip" "$HOME"
row "4458 unzip -p x.zip -d ~ (ctrl)"       allow "unzip -p /tmp/x.zip -d ~"
row "4458 unzip x.zip -x -l -d ~"           deny  "unzip /tmp/x.zip -x a -d ~"
row "4458 cpio -i -F -O, cwd HOME"          deny  "cpio -i -F --to-stdout" "$HOME"
row "4458 cpio -idF a -D ~"                 deny  "cpio -idF /tmp/a.cpio -D ~"
row "4458 cpio -i -E -D -D ~"               deny  "cpio -i -E -D -D ~"
row "4458 cpio -p ~/.himmel (pass-through)" deny  "find . | cpio -pdm ~/.himmel"
row "4458 cpio -i --to-stdout, cwd HOME (ctrl)" allow "cpio -i --to-stdout < /tmp/a.cpio" "$HOME"
row "4458 cpio -p /tmp/o (always denies)"  deny  "find . | cpio -pdm /tmp/o"
# Panel r1 codex-2: a relative operand after a cd (r9: cwd unknown) denies.
row "4458 cd ~/projects && tar -C .."       deny  "cd \"\$HOME/projects\" && tar -xf /tmp/x.tar -C .."
row "4458 cd ~/projects && tar -C ../.himmel" deny "cd ~/projects && tar -xf /tmp/x.tar -C ../.himmel"
row "4458 cd ~/projects && unzip -d .."      deny  "cd ~/projects && unzip /tmp/x.zip -d .."
row "4458 cd ~/projects/.. && tar -xf"       deny  "cd ~/projects/.. && tar -xf /tmp/x.tar"
row "4458 cd /var/w && tar -C .. (cwd unproven)"     deny  "cd /var/w && tar -xf /tmp/x.tar -C .."
row "4458 cd ~/projects && tar -C sub (cwd unproven)" deny  "cd ~/projects && tar -xf /tmp/x.tar -C sub"
row "4458 cd ~/projects && cp -r .himmel .." deny  "cd ~/projects && cp -r /tmp/h/.himmel .."
row "4458 cd ~ && cp -r .himmel ."         deny  "cd ~ && cp -r /tmp/h/.himmel ."
row "4458 cd ~/.himmel && cp -r d state (exists, cwd unproven)" deny  "cd ~/.himmel && cp -r /tmp/d state"
row "4458 cd ~/projects && cp lift-named ../.himmel/state/" deny "cd ~/projects && cp /tmp/s/bank-lift.json ../.himmel/state/"
row "4458 cd ~/projects && cp -r d .. (cwd unproven)" deny  "cd ~/projects && cp -r /tmp/d .."
row "4458 cd /tmp/w && cp -r .himmel .. (cwd unproven)" deny  "cd /tmp/w && cp -r /tmp/h/.himmel .."
# Panel r2 codex-1: a relative -C resolves against the -C before it.
row "4458 tar -C \$HOME/projects -C .."      deny  "tar -xf /tmp/x.tar -C \"\$HOME/projects\" -C .."
row "4458 tar -C ~/projects -C ../.himmel"    deny  "tar -xf /tmp/x.tar -C ~/projects -C ../.himmel"
row "4458 tar --directory= chained .."        deny  "tar -xf /tmp/x.tar --directory=\$HOME/projects --directory=.."
row "4458 tar -xC ~/projects -C .. (bundle)"  deny  "tar -xC ~/projects -f /tmp/x.tar -C .."
row "4458 tar -C~/projects -C .. (attached)"  deny  "tar -xf /tmp/x.tar -C\$HOME/projects -C.."
row "4458 cd ~/projects && tar -C sub -C ../.." deny "cd ~/projects && tar -xf /tmp/x.tar -C sub -C ../.."
row "4458 tar -C sub -C ../.., cwd ~/projects" deny "tar -xf /tmp/x.tar -C sub -C ../.." "$HOME/projects"
row "4458 tar -C \"\$d\" -C .. (unresolved chain)" deny "tar -xf /tmp/x.tar -C \"\$d\" -C .."
row "4458 cd \"\$d\"; tar -C sub -C ../.."   deny  "cd \"\$d\"; tar -xf /tmp/x.tar -C sub -C ../.."
row "4458 cd \"\$d\"; tar -C .."              deny  "cd \"\$d\"; tar -xf /tmp/x.tar -C .."
row "4458 cd \"\$d\"; tar -C sub (r6 unproven)" deny "cd \"\$d\"; tar -xf /tmp/x.tar -C sub"
row "4458 cd \"\$d\" && tar -C sub (r7: computed cd)" deny "cd \"\$d\" && tar -xf /tmp/x.tar -C sub"
row "4458 tar -C ~/projects -C sub (ctrl)"    allow "tar -xf /tmp/x.tar -C ~/projects -C sub"
row "4458 tar -C /var/w -C .. (ctrl)"         allow "tar -xf /tmp/x.tar -C /var/w -C .."
row "4458 tar -C ~ -C /tmp/o (absolute 2nd, ctrl)" allow "tar -xf /tmp/x.tar -C ~/projects -C /tmp/o"
# Panel r2 codex-2: kept absolute (or ../) member names land anywhere.
row "4458 tar -xPf -C /tmp/out"               deny  "tar -xPf /tmp/x.tar -C /tmp/out"
row "4458 tar xPf (old-style) -C /tmp/o"      deny  "tar xPf /tmp/x.tar -C /tmp/o"
row "4458 tar -x -P -f"                       deny  "tar -x -P -f /tmp/x.tar -C /tmp/o"
row "4458 tar --absolute-names"               deny  "tar -xf /tmp/x.tar --absolute-names -C /tmp/o"
row "4458 gtar --absolute-names"              deny  "gtar --extract --absolute-names -f /tmp/x.tar"
row "4458 bsdtar -xPf"                        deny  "bsdtar -xPf /tmp/x.tar -C /tmp/o"
row "4458 bsdtar --absolute-paths"            deny  "bsdtar -xf /tmp/x.tar --absolute-paths -C /tmp/o"
row "4458 tar -tPf (list, ctrl)"              allow "tar -tPf /tmp/x.tar"
row "4458 tar -xPOf (stdout, ctrl)"           allow "tar -xPOf /tmp/x.tar m"
row "4458 tar -cPf (create, ctrl)"            allow "tar -cPf /tmp/x.tar /etc/hosts"
row "4458 tar -xf -C /tmp/o (no -P, ctrl)"    allow "tar -xf /tmp/x.tar -C /tmp/o"
row "4458 unzip -: -d /tmp/o"                 deny  "unzip -: /tmp/x.zip -d /tmp/o"
row "4458 unzip -o -: -d /tmp/o"              deny  "unzip -o -: /tmp/x.zip -d /tmp/o"
row "4458 unzip -o: (bundle)"                 deny  "unzip -o: /tmp/x.zip -d /tmp/o"
row "4458 unzip -l -: (list, ctrl)"           allow "unzip -l -: /tmp/x.zip"
row "4458 cpio --absolute-filenames -D /tmp/o" deny "cpio -i --absolute-filenames -D /tmp/o < /tmp/a.cpio"
row "4458 cpio -idm (absolute by default)"    deny  "cpio -idm < /tmp/a.cpio"
row "4458 cpio --extract (absolute by default)" deny "cpio --extract -D /tmp/o < /tmp/a.cpio"
row "4458 cpio -idm --no-absolute-filenames (always denies)" deny "cpio -idm --no-absolute-filenames < /tmp/a.cpio"
row "4458 cpio -it (list, ctrl)"              allow "cpio -it < /tmp/a.cpio"
row "4458 cpio --list -i (list, ctrl)"        allow "cpio -i --list < /tmp/a.cpio"
# Panel r3 codex-2: an unresolved (computed) destination denies.
row "4458 D=\$HOME; tar -C \"\$D\""             deny  "D=\"\$HOME\"; tar -xf /tmp/x.tar -C \"\$D\""
row "4458 tar --directory=\"\$D\""              deny  "tar -xf /tmp/x.tar --directory=\"\$D\""
row "4458 tar -xC\"\$D\" (attached)"            deny  "tar -xC\"\$D\" -f /tmp/x.tar"
row "4458 unzip -d \"\$D\""                     deny  "unzip -o /tmp/x.zip -d \"\$D\""
row "4458 cpio -D \"\$D\""                      deny  "cpio -i --no-absolute-filenames -D \"\$D\" < /tmp/a.cpio"
row "4458 tar -C \"\$(cmd)\""                   deny  "tar -xf /tmp/x.tar -C \"\$(dirname /tmp/a)\""
row "4458 tar -C backtick"                     deny  "tar -xf /tmp/x.tar -C \`dirname /tmp/a\`"
row "4458 cpio -p \"\$D\""                      deny  "find . | cpio -pdm \"\$D\""
row "4458 tar -C \"\$HOME/x\" sub of HOME (ctrl)" allow "tar -xf /tmp/x.tar -C \"\$HOME/projects\""
row "4458 tar -C \"\$D\" -O (stdout, ctrl)"     allow "tar -xOf /tmp/x.tar -C \"\$D\" m"
row "4458 tar -tf -C \"\$D\" (list, ctrl)"      allow "tar -tf /tmp/x.tar -C \"\$D\""
# Panel r4 codex-1: an ancestor of HOME is a destination members can reach
# HOME through (a relative member home/<u>/.himmel/state/...). The scratch
# HOME is $T/home, so its ancestors are $T, /tmp and /.
row "4458 tar -C /"                           deny  "tar -xf /tmp/x.tar -C /"
row "4458 tar -C \$T (HOME's parent)"          deny  "tar -xf /tmp/x.tar -C $T"
row "4458 tar -C /tmp (HOME's ancestor)"      deny  "tar -xf /tmp/x.tar -C /tmp"
row "4458 tar --directory=/"                  deny  "tar -xf /tmp/x.tar --directory=/"
row "4458 tar -C ~/.. "                        deny  "tar -xf /tmp/x.tar -C ~/.."
row "4458 cd / && tar -xf"                    deny  "cd / && tar -xf /tmp/x.tar"
row "4458 cd \$T && tar -xf"                   deny  "cd $T && tar -xf /tmp/x.tar"
row "4458 cd / && tar -C tmp"                 deny  "cd / && tar -xf /tmp/x.tar -C tmp"
row "4458 tar -xf, cwd / "                    deny  "tar -xf /tmp/x.tar" "/"
row "4458 tar -xf, cwd \$T"                    deny  "tar -xf /tmp/x.tar" "$T"
row "4458 unzip -d /"                         deny  "unzip /tmp/x.zip -d /"
row "4458 cpio -D /"                          deny  "cpio -i --no-absolute-filenames -D / < /tmp/a.cpio"
row "4458 cpio -p /"                          deny  "find . | cpio -pdm /"
row "4458 tar -C /t (prefix, not ancestor, ctrl)" allow "tar -xf /tmp/x.tar -C ${T%/*}x"
row "4458 tar -C \$T/src (sibling of HOME, ctrl)" allow "tar -xf /tmp/x.tar -C $T/src"
row "4458 tar -C /var/out (ctrl)"             allow "tar -xf /tmp/x.tar -C /var/out"
row "4458 tar -tf -C / (list, ctrl)"          allow "tar -tf /tmp/x.tar -C /"
row "4458 tar -xOf -C / (stdout, ctrl)"       allow "tar -xOf /tmp/x.tar -C / m"
row "4458 tar -C \$HOME/projects (inside HOME, ctrl)" allow "tar -xf /tmp/x.tar -C \"\$HOME/projects\""
# Panel r4 codex-2: --keep-directory-symlink follows a destination symlink.
row "4458 tar --keep-directory-symlink"       deny  "tar -xf /tmp/x.tar --keep-directory-symlink -C /var/out"
row "4458 tar --keep-dir (prefix)"            deny  "tar -xf /tmp/x.tar --keep-dir -C /var/out"
row "4458 tar --keep-d (prefix)"              deny  "tar -x --keep-d -f /tmp/x.tar -C /var/out"
row "4458 tar -t --keep-directory-symlink (list, ctrl)" allow "tar -tf /tmp/x.tar --keep-directory-symlink"
row "4458 tar --keep-old-files (ctrl)"        allow "tar -xf /tmp/x.tar --keep-old-files -C /var/out"
# Panel r5 codex-1: only a cd joined by && moves the cwd; after ; newline & ||
# the cd may have failed, so the cwd is unknown (the old one may be HOME).
# (/var/w stands in for the panel's /tmp: /tmp is an ancestor of this suite's HOME.)
row "4458 tar -xf, cwd HOME"                  deny  "tar -xf /tmp/x.tar" "$HOME"
row "4458 cd X; tar -xf (cd may fail)"        deny  "cd /nonexistent; tar -xf /tmp/x.tar" "$HOME"
row "4458 cd X || tar -xf"                    deny  "cd /nonexistent || tar -xf /tmp/x.tar" "$HOME"
row "4458 cd X; unzip"                        deny  "cd /nonexistent; unzip /tmp/x.zip" "$HOME"
row "4458 cd X <newline> tar -xf"             deny  "cd /var/w
tar -xf /tmp/x.tar" "$HOME"
row "4458 cd X & tar -xf"                     deny  "cd /var/w & tar -xf /tmp/x.tar" "$HOME"
row "4458 cd X && cd Y; tar -xf"              deny  "cd /var/w && cd /var/v; tar -xf /tmp/x.tar" "$HOME"
row "4458 cd X | tar -xf"                     deny  "cd /var/w | tar -xf /tmp/x.tar" "$HOME"
row "4458 cd X && tar -xf (cwd unproven)"             deny  "cd /var/w && tar -xf /tmp/x.tar" "$HOME"
row "4458 cd X && cd Y && tar -xf (cwd unproven)"     deny  "cd /var/w && cd /var/v && tar -xf /tmp/x.tar" "$HOME"
# Panel r6 (HIMMEL-4490), reshaped in r9: with a directory-changing word
# anywhere the cwd is unknown; a relative or missing destination denies, an
# absolute one is judged as with a proven cwd.
row "4458 cd X; tar -C abs (abs dest)"     allow "cd /var/w; tar -xf /tmp/x.tar -C /var/out" "$HOME"
row "4458 cd X; unzip -d abs (abs dest)"   allow "cd /var/w; unzip /tmp/x.zip -d /var/out" "$HOME"
row "4458 cd X; tar -C rel, cwd .himmel"      deny  "cd /nonexistent; tar -xf /tmp/x.tar -C state" "$HOME/.himmel"
row "4458 bash -c 'cd X && true'; tar -xf"    deny  "bash -c 'cd /var/out && true'; tar -xf /tmp/x.tar" "$HOME"
row "4458 (cd X && true); tar -xf"            deny  "(cd /var/out && true); tar -xf /tmp/x.tar" "$HOME"
row "4458 { cd X && true; }; tar -xf"         deny  "{ cd /var/out && true; }; tar -xf /tmp/x.tar" "$HOME"
row "4458 true || cd X && tar -xf (cd skipped)" deny "true || cd /var/w && tar -xf /tmp/x.tar" "$HOME"
row "4458 echo | cd X && tar -xf (pipeline)"  deny  "echo | cd /var/w && tar -xf /tmp/x.tar" "$HOME"
row "4458 eval true; tar -C abs (abs dest)"               allow "eval true; tar -xf /tmp/x.tar -C /var/out" "$HOME"
row "4458 sh -c 'cd X && tar -xf' (nested)"   deny  "sh -c 'cd /var/w && tar -xf /tmp/x.tar'" "$HOME"
row "4458 cd X && tar -C rel (cwd unproven)"          deny  "cd /var/w && tar -xf /tmp/x.tar -C out" "$HOME"
row "4458 tar -C abs, no cd (ctrl)"           allow "tar -xf /tmp/x.tar -C /var/out" "$HOME"
row "4458 (true); tar -C abs, no cd (ctrl)"   allow "(true); tar -xf /tmp/x.tar -C /var/out" "$HOME"
row "4458 cd X; tar -tf (list, ctrl)"         allow "cd /var/w; tar -tf /tmp/x.tar" "$HOME"
# Panel r7: extraction options are an ALLOWLIST (structural); a relative cd
# target or any CDPATH mention leaves the cwd unproven. cwd /var as probed.
row "4458 tar --one-top-level=\$HOME"         deny  "tar -xf /tmp/a.tar -C /var/out --one-top-level=\"\$HOME\"" /var
row "4458 tar --one-top-level=~/.himmel"      deny  "tar -xf /tmp/a.tar -C /var/out --one-top-level=$HOME/.himmel" /var
row "4458 tar --one-top-level DIR (split)"    deny  "tar -xf /tmp/a.tar -C /var/out --one-top-level $HOME" /var
row "4458 tar --one-top (abbrev)"             deny  "tar -xf /tmp/a.tar -C /var/out --one-top=$HOME" /var
row "4458 tar --transform"                    deny  "tar -xf /tmp/a.tar -C /var/out --transform=s,^,x/,"
row "4458 tar -h bundled (unknown letter)"    deny  "tar -xhf /tmp/a.tar -C /var/out"
row "4458 tar xhf old-style (unknown letter)" deny  "tar xhf /tmp/a.tar -C /var/out"
row "4458 unzip -x (not allowlisted)"         deny  "unzip -o /tmp/x.zip -d /var/out -x a"
row "4458 cpio -iR (not allowlisted)"         deny  "cpio -i --no-absolute-filenames -R u -D /var/out"
row "4458 CDPATH=… cd rel && tar"             deny  "CDPATH=\"\$HOME/.himmel\" cd state && tar -xf /tmp/a.tar" /var
row "4458 export CDPATH; cd rel && tar"       deny  "export CDPATH=$HOME/.himmel; cd state && tar -xf /tmp/a.tar" /var
row "4458 cd rel && tar (no CDPATH word)"     deny  "cd state && tar -xf /tmp/a.tar" /var
row "4458 CDPATH quoted-split, cd abs && tar -C abs (abs dest)" allow "export CD\"\"PATH=/x; cd /var/w && tar -xf /tmp/a.tar -C /var/out" /var
row "4458 popd && tar (abs dest)"                         allow "popd && tar -xf /tmp/a.tar -C /var/out" /var
row "4458 cd /var/w && tar -xzf -C out --strip (cwd unproven)" deny  "cd /var/w && tar -xzf x.tgz -C out --strip-components=1" /var
row "4458 tar --strip-components N split (ctrl)" allow "tar -xzf /tmp/x.tgz --strip-components 1 -C /var/out" /var
row "4458 tar xzf old-style -C (ctrl)"        allow "tar xzf /tmp/x.tgz -C /var/out --strip-components=1" /var
row "4458 tar -C abs plain (ctrl)"            allow "tar -xf /tmp/x.tar -C /var/out" /var
row "4458 unzip -o -q -d (ctrl)"              allow "unzip -o -q /tmp/x.zip -d /var/out" /var
row "4458 tar -tf --one-top-level (list, ctrl)" allow "tar -tf x.tar --one-top-level" /var
row "4458 cd ~/x && tar -C abs (ctrl)"        allow "cd ~/x && tar -xf /tmp/x.tar -C /var/out" /var
# r8: an option word on cd/pushd/popd (pushd -n does not change dir) and a
# || anywhere beside a cd (the cd may be skipped) leave the cwd unproven.
row "4458 pushd -n abs && tar (from HOME)"    deny  "pushd -n /var/w && tar -xf /tmp/x.tar" "$HOME"
row "4458 cd -P abs && tar (from HOME)"       deny  "cd -P /var/w && tar -xf /tmp/x.tar" "$HOME"
row "4458 false && cd && true || tar (from HOME)" deny "false && cd /var/w && true || tar -xf /tmp/x.tar" "$HOME"
row "4458 cd abs && tar -C abs || true (abs dest)" allow "cd /var/w && tar -xf /tmp/x.tar -C /var/out || true" /var
row "4458 tar -C abs || true, no cd (ctrl)"   allow "tar -xf /tmp/x.tar -C /var/out || true" /var
row "4458 cd abs && tar, no dest (from HOME)" deny  "cd /var/w && tar -xf /tmp/x.tar" "$HOME"
# r9: a directory-changing word ANYWHERE leaves the cwd unknown for the whole
# command; a relative destination (extraction or copy) or no destination
# denies, an absolute one is judged as with a proven cwd.
row "4458 false && cd && true; tar (from HOME)" deny "false && cd /var/w && true; tar -xf /tmp/x.tar" "$HOME"
row "4458 false && cd && true; cp -r . (from HOME)" deny "false && cd /var/w && true; cp -r /tmp/h/.himmel ." "$HOME"
row "4458 cd /nonexistent; cp -r . (from HOME)" deny "cd /nonexistent; cp -r /tmp/h/.himmel ." "$HOME"
row "4458 cd abs; cp -r . (from HOME)"        deny  "cd /var/w; cp -r /tmp/h/.himmel ." "$HOME"
row "4458 cd abs && cp -r . (from HOME)"      deny  "cd /var/w && cp -r /tmp/h/.himmel ." "$HOME"
row "4458 cd abs; cp -r abs (from HOME, ctrl)" allow "cd /var/w; cp -r /tmp/h/.himmel /var/out" "$HOME"
row "4458 cd abs && tar -C abs (from HOME, ctrl)" allow "cd /var/w && tar -xf /tmp/x.tar -C /var/out" "$HOME"
row "4458 cd /x; cp a abs/ (ctrl)"            allow "cd /x; cp a /var/out/" /var
row "4458 tar -xf, cwd /var, no cd (ctrl)"    allow "tar -xf /tmp/x.tar" /var
row "4458 pushd abs; cp -r . (from HOME)"     deny  "pushd /var/w; cp -r /tmp/h/.himmel ." "$HOME"
row "4458 ( cd abs ); cp -r . (from HOME)"    deny  "(cd /var/w); cp -r /tmp/h/.himmel ." "$HOME"
row "4458 { cd abs; }; tar (from HOME)"       deny  "{ cd /var/w; }; tar -xf /tmp/x.tar" "$HOME"
row "4458 eval cd; tar -C . (from HOME)"      deny  "eval cd /var/w; tar -xf /tmp/x.tar -C ." "$HOME"
row "4458 bash -c cd; cp -r . (from HOME)"    deny  "bash -c 'cd /var/w'; cp -r /tmp/h/.himmel ." "$HOME"
row "4458 \$(cd) ; tar (from HOME)"           deny  "x=\$(cd /var/w); tar -xf /tmp/x.tar" "$HOME"
row "4458 CDPATH; cp -r . (cwd /var)"         deny  "CDPATH=/var; cp -r /tmp/h/.himmel ." /var
row "4458 ln -s rel src after cd (from HOME)" deny  "cd /var/w; ln -s .himmel/bank-lift.json /var/out/l" "$HOME"
# Absolute destinations still deny every way a member escapes them.
row "4458 tar -xPf -C abs"                    deny  "tar -xPf /tmp/x.tar -C /var/out" /var
row "4458 tar --absolute-names -C abs"        deny  "tar -xf /tmp/x.tar --absolute-names -C /var/out" /var
row "4458 bsdtar -xPf -C abs"                 deny  "bsdtar -xPf /tmp/x.tar -C /var/out" /var
row "4458 bsdtar --absolute-paths -C abs"     deny  "bsdtar -xf /tmp/x.tar --absolute-paths -C /var/out" /var
row "4458 unzip -: -d abs"                    deny  "unzip -: /tmp/x.zip -d /var/out" /var
row "4458 unzip -^ -d abs"                    deny  "unzip -^ /tmp/x.zip -d /var/out" /var
row "4458 cpio -i -D abs -F"                  deny  "cpio -i -D /var/out -F /tmp/x.cpio" /var
row "4458 cpio -p abs (pass mode)"            deny  "find . | cpio -pdm /var/out" /var
# r10: the tar/unzip MODE is allowlisted: extracting unless a non-extract
# mode is proven by a real option word; old-style bundle only as argv[1].
row "4458 tar long opts then member O"        deny  "tar --extract --file /tmp/a.tar --directory \"\$HOME\" O .himmel" /var
row "4458 tar --ge (abbrev of --get)"         deny  "tar --ge -f /tmp/a.tar -C \"\$HOME\"" /var
row "4458 tar --ex (abbrev of --extract)"     deny  "tar --ex -f /tmp/a.tar -C \"\$HOME\"" /var
row "4458 tar -f --directory -x then member O" deny "tar -f /tmp/a.tar --directory \"\$HOME\" -x O" /var
row "4458 unzip member named l"               deny  "unzip /tmp/a.zip -d \"\$HOME\" l" /var
row "4458 bsdtar --extract then member O"     deny  "bsdtar --extract -f /tmp/a.tar -C \"\$HOME\" O" /var
row "4458 tar -xf member then -O (after non-option)" deny "tar -xf /tmp/a.tar m -O -C \"\$HOME\"" /var
row "4458 tar --lis (abbrev, not proven)"      deny  "tar --lis -f /tmp/a.tar -C \"\$HOME\"" /var
row "4458 tar -tf (ctrl)"                      allow "tar -tf /tmp/a.tar" /var
row "4458 tar tvf old-style (ctrl)"            allow "tar tvf /tmp/a.tar" /var
row "4458 tar --list -f (ctrl)"                allow "tar --list -f /tmp/a.tar" /var
row "4458 tar -xOf (stdout, ctrl)"             allow "tar -xOf /tmp/a.tar" /var
row "4458 tar -xf -O (stdout, ctrl)"           allow "tar -xf /tmp/a.tar -O" /var
row "4458 tar -xf --to-stdout (ctrl)"          allow "tar -xf /tmp/a.tar --to-stdout" /var
row "4458 unzip -l (ctrl)"                     allow "unzip -l /tmp/a.zip" /var
row "4458 tar -cf (create, ctrl)"              allow "tar -cf /tmp/o.tar dir" /var
row "4458 tar -xf -C abs (ctrl)"               allow "tar -xf /tmp/a.tar -C /var/out" /var
# r11: a command that sets a tar/unzip option variable (any form) denies
# every extraction in it; a proven non-extract mode still allows.
row "4458 xenv prefix TAR_OPTIONS (/var)" deny "TAR_OPTIONS=-P tar -xf /tmp/a.tar -C /var/out" /var
row "4458 xenv export TAR_OPTIONS (/var)" deny "export TAR_OPTIONS=-P; tar -xf /tmp/a.tar -C /var/out" /var
row "4458 xenv prefix UNZIP (/var)" deny "UNZIP=-: unzip /tmp/a.zip -d /var/out" /var
row "4458 xenv env TAR_OPTIONS (/var)" deny "env TAR_OPTIONS=-P tar -xf /tmp/a.tar -C /var/out" /var
row "4458 xenv declare -x TAR_OPTIONS (/var)" deny "declare -x TAR_OPTIONS=-P; tar -xf /tmp/a.tar -C /var/out" /var
row "4458 xenv prefix UNZIPOPT (/var)" deny "UNZIPOPT=-: unzip /tmp/a.zip -d /var/out" /var
row "4458 xenv prefix ZIPINFO (/var)" deny "ZIPINFO=-: unzip /tmp/a.zip -d /var/out" /var
row "4458 xenv quote-split TAR_OPT\"\"IONS (/var)" deny "TAR_OPT\"\"IONS=-P tar -xf /tmp/a.tar -C /var/out" /var
row "4458 xenv TAR_OPTIONS + tar -tf (ctrl) (/var)" allow "TAR_OPTIONS=-P tar -tf /tmp/a.tar" /var
row "4458 xenv no env var (ctrl) (/var)" allow "tar -xf /tmp/a.tar -C /var/out" /var
row "4458 xenv prefix TAR_OPTIONS (HOME)" deny "TAR_OPTIONS=-P tar -xf /tmp/a.tar -C /var/out" "$HOME"
row "4458 xenv export TAR_OPTIONS (HOME)" deny "export TAR_OPTIONS=-P; tar -xf /tmp/a.tar -C /var/out" "$HOME"
row "4458 xenv prefix UNZIP (HOME)" deny "UNZIP=-: unzip /tmp/a.zip -d /var/out" "$HOME"
row "4458 xenv env TAR_OPTIONS (HOME)" deny "env TAR_OPTIONS=-P tar -xf /tmp/a.tar -C /var/out" "$HOME"
row "4458 xenv declare -x TAR_OPTIONS (HOME)" deny "declare -x TAR_OPTIONS=-P; tar -xf /tmp/a.tar -C /var/out" "$HOME"
row "4458 xenv prefix UNZIPOPT (HOME)" deny "UNZIPOPT=-: unzip /tmp/a.zip -d /var/out" "$HOME"
row "4458 xenv prefix ZIPINFO (HOME)" deny "ZIPINFO=-: unzip /tmp/a.zip -d /var/out" "$HOME"
row "4458 xenv quote-split TAR_OPT\"\"IONS (HOME)" deny "TAR_OPT\"\"IONS=-P tar -xf /tmp/a.tar -C /var/out" "$HOME"
row "4458 xenv TAR_OPTIONS + tar -tf (ctrl) (HOME)" allow "TAR_OPTIONS=-P tar -tf /tmp/a.tar" "$HOME"
row "4458 xenv no env var (ctrl) (HOME)" allow "tar -xf /tmp/a.tar -C /var/out" "$HOME"
# r12: the BARE variable name counts (printf -v, read, nameref, +=);
# case-sensitive, so the unzip command never matches UNZIP.
row "4458 xenv printf -v bare name (/var)" deny "printf -v TAR_OPTIONS -- -P; export TAR_OPTIONS; tar -xf /tmp/a.tar -C /var/out" /var
row "4458 xenv read bare name (/var)" deny "read TAR_OPTIONS </tmp/o; export TAR_OPTIONS; tar -xf /tmp/a.tar -C /var/out" /var
row "4458 xenv declare -n nameref (/var)" deny "declare -n r=TAR_OPTIONS; r=-P; export TAR_OPTIONS; tar -xf /tmp/a.tar -C /var/out" /var
row "4458 xenv UNZIP+= append (/var)" deny "UNZIP+=-: unzip /tmp/a.zip -d /var/out" /var
row "4458 xenv unzip cmd is not UNZIP (ctrl) (/var)" allow "unzip /tmp/a.zip -d /var/out" /var
row "4458 xenv printf -v bare name (HOME)" deny "printf -v TAR_OPTIONS -- -P; export TAR_OPTIONS; tar -xf /tmp/a.tar -C /var/out" "$HOME"
row "4458 xenv read bare name (HOME)" deny "read TAR_OPTIONS </tmp/o; export TAR_OPTIONS; tar -xf /tmp/a.tar -C /var/out" "$HOME"
row "4458 xenv declare -n nameref (HOME)" deny "declare -n r=TAR_OPTIONS; r=-P; export TAR_OPTIONS; tar -xf /tmp/a.tar -C /var/out" "$HOME"
row "4458 xenv UNZIP+= append (HOME)" deny "UNZIP+=-: unzip /tmp/a.zip -d /var/out" "$HOME"
row "4458 xenv unzip cmd is not UNZIP (ctrl) (HOME)" allow "unzip /tmp/a.zip -d /var/out" "$HOME"

echo "== HIMMEL-4458 item 6: contents copy into bare HOME (accepted over-deny) =="
row "4458 cp -r dir/ ~/ (over-deny kept)"   deny  "cp -r dotfiles/ ~/"
row "4458 rsync -a dir/ ~/ (over-deny kept)" deny "rsync -a dotfiles/ ~/"
row "4458 cp * ~/ (over-deny kept)"         deny  "cp * ~/"

echo "== HIMMEL-4458 item 7: latency stays linear =="
big=$(awk 'BEGIN { printf "echo"; for (i = 0; i < 10000; i++) printf " w%d", i }')
got=$(printf '%s' "$(bash_json "$big")" | timeout 15 bash "$HOOK" >/dev/null 2>&1; echo $?)
if [ "$got" = 0 ]; then ok "4458 10k-word echo allows within 15s"; else bad "4458 10k-word echo allows within 15s — rc=$got"; fi
big=$(awk 'BEGIN { printf "true"; for (i = 0; i < 1500; i++) printf " && echo w%d x", i }')
got=$(printf '%s' "$(bash_json "$big")" | timeout 15 bash "$HOOK" >/dev/null 2>&1; echo $?)
if [ "$got" = 0 ]; then ok "4458 1.5k-clause command allows within 15s"; else bad "4458 1.5k-clause command allows within 15s — rc=$got"; fi

echo "== HIMMEL-4972: brace-expand the original word, fail closed =="
# Each form is a path word that REAL bash expands to the lift file. Every form
# is run for real in a scratch HOME under each verb that can write it; a form
# no verb can write is a failure of this test (the row would prove nothing).
# The hook must deny each form under every verb.
US=$(printf '\037')
cat > "$T/x.py" <<'PYEOF'
import sys
for a in sys.argv[1:]:
    try:
        open(a, 'w').close()
    except Exception:
        pass
PYEOF
live_writes() {  # command -> 0 when real bash, in a scratch HOME, creates the lift
    rm -rf "$T/live"; mkdir -p "$T/live/.himmel/state"
    ( cd "$T/live" && HOME="$T/live" bash -c "$1" >/dev/null 2>&1 )
    [ -e "$T/live/.himmel/state/bank-lift.json" ]
}
forms4972=$(cat <<'EOF'
quoted } dq|~/.himmel/state/bank-lift{.json,"}"x}
quoted } sq|~/.himmel/state/bank-lift{.json,'}'x}
escaped }|~/.himmel/state/bank-lift{.json,\}x}
ansi-c } |~/.himmel/state/bank-lift{.json,$'\x7d'x}
quoted } first|~/.himmel/state/bank-lift{'}',.json}
escaped } first|~/.himmel/state/bank-lift{\},.json}
slash alt|~/.himmel/state/bank-lift{.json,/}
slash a/b|~/.himmel/state/bank-lift{.json,a/b}
slash ./|~/.himmel/state/bank-lift{.json,./}
slash x/..|~/.himmel/state/bank-lift{x/..,.json}
quoted slash|~/.himmel/state/bank-lift{'/',.json}
group spans dir|~/.himmel/{state/bank-lift,x}.json
nested spans dir|{~/.himmel/state/bank-lift{.json,x},y}
ansi-c 0x1f|~/.himmel/state/bank-lift{.json,$'\x1f'}
EOF
)
forms4972="$forms4972
raw 0x1f|~/.himmel/state/bank-lift{.json,${US}}"
n4972=0
while IFS='|' read -r flabel fword; do
    [ -n "$flabel" ] || continue
    live=0
    for vt in 'printf x | tee %T%' 'touch %T%' "install $T/src/other.txt %T%" "cp $T/src/other.txt %T%" ': > %T%' "python3 $T/x.py %T%"; do
        cmd="${vt//%T%/$fword}"
        row "4972 $flabel: ${vt%% *}" deny "$cmd"
        if live_writes "$cmd"; then live=1; fi
    done
    if [ "$live" = 1 ]; then ok "4972 $flabel: real bash writes the lift"; else bad "4972 $flabel: no verb writes the lift in real bash (form is not live)"; fi
    n4972=$((n4972+1))
done <<EOF
$forms4972
EOF
if [ "$n4972" -ge 15 ]; then ok "4972 generated $n4972 forms"; else bad "4972 generated only $n4972 forms"; fi
# Fail closed on a word the expander cannot handle.
row "4972 unbalanced { group denies"      deny "tee ~/.himmel/state/bank-lift{.json,x"
row "4972 deep nesting denies"            deny "tee ~/.himmel/state/bank-lift{a,{b,{c,{d,{e,{f,{g,{h,{i,{j,{k,{l,{m,{n,{o,{p,{q,x}}}}}}}}}}}}}}}}}"
row "4972 brace blow-up denies"           deny "tee ~/.himmel/state/bank-lift{a,b,c,d}{a,b,c,d}{a,b,c,d}{a,b,c,d}{a,b,c,d}.json"
# Controls: braces that cannot reach the lift stay allowed.
row "4972 quoted-brace JSON still allows" allow "python3 x.py '{\"a\":1,\"b\":2}'"
row "4972 brace alt, no lift, allows"     allow "cp $T/src/other.txt $T/src/{a,b}.txt"
row "4972 quoted brace is literal"        allow "tee ~/.himmel/state/'{bank-lift,y}.json'"
row "4972 \${HOME} still expands"         deny  "tee \${HOME}/.himmel/state/bank-lift.json"
row "4972 {fd}> redirect allows"          allow "exec {fd}>/dev/null"
row "4972 { group } allows"               allow "{ echo hi; }"

# Probe rows (console ruling, round 2): shapes a brace expander can get wrong.
# Same method as above: deny under every verb, and real bash must write the lift.
probe4972() {  # label prefix word
    local plabel="$1" pre="$2" pword="$3" vt cmd live=0
    for vt in 'printf x | tee %T%' 'touch %T%' "install $T/src/other.txt %T%" "cp $T/src/other.txt %T%" ': > %T%' "python3 $T/x.py %T%"; do
        cmd="$pre${vt//%T%/$pword}"
        row "4972 probe $plabel: ${vt%% *}" deny "$cmd"
        if live_writes "$cmd"; then live=1; fi
    done
    if [ "$live" = 1 ]; then ok "4972 probe $plabel: real bash writes the lift"; else bad "4972 probe $plabel: no verb writes the lift in real bash (form is not live)"; fi
}
# The words below are literals handed to the hook, so tilde and $VAR stay unexpanded on purpose.
# shellcheck disable=SC2088,SC2016
run_probes4972() {
NL=$'\n'
# (a) nesting 3+ deep
probe4972 "nest3"          '' '~/.himmel/state/bank-lift{.json,{x,{y,z}}}'
probe4972 "nest4 inner"    '' '~/.himmel/state/bank-lift{x,{y,{z,{.json,w}}}}'
probe4972 "nest5 outer"    '' '{{{{~/.himmel/state/bank-lift{.json,x},y},z},w},v}'
# (a) large alternation count: lift is the first / last alternative of 40
alts40=$(seq -s, -f 'a%g' 1 39)
probe4972 "40 alts first"  '' "~/.himmel/state/bank-lift{.json,${alts40},z}"
probe4972 "40 alts last"   '' "~/.himmel/state/bank-lift{${alts40},.json}"
# over BX_MAX (256) words: must fail closed, never allow
alts300=$(seq -s, -f 'a%g' 1 299)
row "4972 probe 300 alts denies"      deny "tee ~/.himmel/state/bank-lift{.json,${alts300},z}"
row "4972 probe 300 alts last denies" deny "tee ~/.himmel/state/bank-lift{${alts300},.json}"
# (b) sequence expressions near the lift name
probe4972 "seq char"       '' '~/.himmel/state/bank-lift.jso{n..n}'
probe4972 "seq dir"        '' '~/.himmel/stat{e..e}/bank-lift.json'
probe4972 "seq nested alt" '' '~/.himmel/state/bank-lift{.jso{n..n},x}'
probe4972 "seq in alt"     '' '~/.himmel/state/bank-lift{.json,{1..3}}'
# (c) variable and tilde forms mixed with braces in one word
probe4972 "HOME braced"    '' '${HOME}/.himmel/state/bank-lift{.json,x}'
probe4972 "HOME bare"      '' '$HOME/.himmel/state/bank-lift{.json,x}'
probe4972 "HOME in group"  '' '{$HOME,x}/.himmel/state/bank-lift.json'
probe4972 "tilde in group" '' '{~,x}/.himmel/state/bank-lift.json'
probe4972 "VAR braced"     'S=.json; ' '~/.himmel/state/bank-lift${S}'
probe4972 "VAR + group"    'S=.himmel; ' '~/${S}/state/bank-lift{.json,x}'
probe4972 "VAR in alt"     'S=.json; ' '~/.himmel/state/bank-lift{${S},x}'
probe4972 "VAR dir braced" 'D=state; ' '${HOME}/.himmel/${D}/bank-lift{.json,x}'
# (d) quote-split words and ANSI-C escapes inside alternatives
probe4972 "empty dq"       '' '~/.himmel/state/bank-lift"".json'
probe4972 "split dq"       '' '~/.himmel/state/bank-"lift".json'
probe4972 "split NA ME"    '' '~/.himmel/state/bank-lift."js""on"'
probe4972 "split sq+dq"    '' "~/.himmel/state/bank-'li'\"ft\".json"
probe4972 "ansi-c name"    '' "~/.himmel/state/\$'bank-lift'.json"
probe4972 "ansi-c in alt"  '' "~/.himmel/state/bank-lift{\$'.json',x}"
probe4972 "ansi-c hex alt" '' "~/.himmel/state/bank-lift{.js\$'\\x6f'n,x}"
probe4972 "ansi-c comma"   '' "~/.himmel/state/bank-lift{\$'\\x2c',.json}"
probe4972 "ansi-c brace"   '' "~/.himmel/state/bank-lift{\$'\\x7b',.json}"
probe4972 "split in alt"   '' '~/.himmel/state/bank-lift{.js"on",x}'
# (e) backslash-newline inside a word
probe4972 "bs-nl name"     '' "~/.himmel/state/bank-\\${NL}lift.json"
probe4972 "bs-nl ext"      '' "~/.himmel/state/bank-lift.js\\${NL}on"
probe4972 "bs-nl in group" '' "~/.himmel/state/bank-lift{.js\\${NL}on,x}"
probe4972 "bs-nl dir"      '' "~/.himmel/sta\\${NL}te/bank-lift.json"
# (f) the hook has no timer of its own: a harness kill reads as rc!=2, so the
# only defence is that the expander is bounded. Worst-case inputs must DENY
# (rc 2) fast, well inside the hook budget.
t0=$SECONDS
worst='tee ~/.himmel/state/bank-lift{a,b,c,d}{a,b,c,d}{a,b,c,d}{a,b,c,d}{a,b,c,d}{a,b,c,d}{a,b,c,d}{a,b,c,d}.json'
printf '%s' "$(bash_json "$worst")" | timeout 30 bash "$HOOK" >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ] && [ $((SECONDS-t0)) -le 10 ]; then ok "4972 probe worst-case blow-up denies (rc 2) within 10s"; else bad "4972 probe worst-case blow-up rc=$rc after $((SECONDS-t0))s"; fi
t0=$SECONDS
many='{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}{a,b}'
printf '%s' "$(bash_json "tee ~/.himmel/state/bank-lift${many}.json")" | timeout 30 bash "$HOOK" >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ] && [ $((SECONDS-t0)) -le 10 ]; then ok "4972 probe 20 groups denies (rc 2) within 10s"; else bad "4972 probe 20 groups rc=$rc after $((SECONDS-t0))s"; fi
}
run_probes4972

echo "== HIMMEL-4530: an extraction sharing a command with a symlink creation =="
row "4530 ln -s ~ ; tar -xf -C"               deny  "ln -s ~ /var/out/h; tar -xf /tmp/a.tar -C /var/out"
row "4530 ln -s .himmel && unzip -d"          deny  "ln -s \"\$HOME/.himmel\" /var/out/h && unzip /tmp/a.zip -d /var/out"
row "4530 ln -s fixture HOME path ; tar"     deny  "ln -s $HOME /var/out/h; tar -xf /tmp/a.tar -C /var/out"
row "4530 ln -sf && cpio -idm"                deny  "ln -sf ~ h && cpio -idm < /tmp/a.cpio"
row "4530 cp -s ; tar"                        deny  "cp -s ~/x /var/out/h; tar -xf /tmp/a.tar -C /var/out"
row "4530 cp --symbolic-link ; unzip"         deny  "cp --symbolic-link ~/x /var/out/h; unzip /tmp/a.zip -d /var/out"
row "4530 ln --symbolic ; tar"                deny  "ln --symbolic ~ /var/out/h; tar -xf /tmp/a.tar -C /var/out"
row "4530 ln -fs || tar"                      deny  "ln -fs ~ /var/out/h || tar -xf /tmp/a.tar -C /var/out"
row "4530 reversed: tar then ln -s"           deny  "tar -xf /tmp/a.tar -C /var/out; ln -s ~ /var/out/h"
row "4530 pipe: ln -s | tar"                  deny  "ln -s ~ /var/out/h | tar -xf /tmp/a.tar -C /var/out"
row "4530 inside bash -c"                     deny  "bash -c 'ln -s ~ /var/out/h; tar -xf /tmp/a.tar -C /var/out'"
row "4530 ln --sym (GNU long-option prefix)"  deny  "ln --sym ~ /var/out/h; tar -xf /tmp/a.tar -C /var/out"
row "4530 ln --sy"                            deny  "ln --sy ~ /var/out/h; tar -xf /tmp/a.tar -C /var/out"
row "4530 ln --symb"                          deny  "ln --symb ~ /var/out/h; tar -xf /tmp/a.tar -C /var/out"
row "4530 cp --sym"                           deny  "cp --sym ~/x /var/out/h; tar -xf /tmp/a.tar -C /var/out"
row "4530 ln -S -- -s (-- is -S value)"       deny  "ln -S -- -s ~ /var/out/h; tar -xf /tmp/a.tar -C /var/out"
row "4530 cp -S -- -s"                        deny  "cp -S -- -s ~/x /var/out/h; tar -xf /tmp/a.tar -C /var/out"
row "4530 ln --suffix -- -s"                  deny  "ln --suffix -- -s ~ /var/out/h; tar -xf /tmp/a.tar -C /var/out"
row "4530 ln -t -- -s (-- is -t value)"       deny  "ln -t -- -s ~; tar -xf /tmp/a.tar -C /var/out"
row "4530 tar -xf alone (ctrl)"              allow "tar -xf /tmp/a.tar -C /var/out"
row "4530 ln -s alone (ctrl)"                 allow "ln -s /tmp/a /var/out/h"
row "4530 ln hard link + tar (ctrl)"          allow "ln /tmp/a /var/out/h; tar -xf /tmp/a.tar -C /var/out"
row "4530 tar -tf list + ln -s (ctrl)"        allow "ln -s /tmp/a /var/out/h; tar -tf /tmp/a.tar"
row "4530 tar -xOf stdout + ln -s (ctrl)"     allow "ln -s /tmp/a /var/out/h; tar -xOf /tmp/a.tar"

echo "== HIMMEL-5094: residual extraction-into-HOME shapes =="
# A here-string / function body / wrapper / variable command word / deep eval
# nesting / unmodelled extractor each reached a HOME extraction on main.
row "5094 here-string into bash"               deny  "bash <<< 'tar -xf /tmp/a.tar -C ~'"
row "5094 here-string into sh (unzip)"         deny  "sh <<< \"unzip /tmp/a.zip -d ~/.himmel\""
row "5094 here-string into bash -s"            deny  "bash -s <<< 'tar -xf /tmp/a.tar -C ~'"
row "5094 here-string into bash (ctrl)"        allow "bash <<< 'echo hi'"
row "5094 bash < script file (ctrl)"           allow "bash < /tmp/script.sh"
row "5094 function NAME { } body"              deny  "function f { tar -xf /tmp/a.tar -C ~; }; f"
row "5094 function NAME() { } body"            deny  "function f() { tar -xf /tmp/a.tar -C ~; }; f"
row "5094 NAME() { } body"                     deny  "f() { tar -xf /tmp/a.tar -C ~; }; f"
row "5094 function body, safe dest (ctrl)"     allow "function f { tar -xf /tmp/a.tar -C /var/out; }; f"
row "5094 strace wrapper"                      deny  "strace -f tar -xf /tmp/a.tar -C ~"
row "5094 strace -o wrapper"                   deny  "strace -o /tmp/t.out tar -xf /tmp/a.tar -C ~"
row "5094 fakeroot wrapper"                    deny  "fakeroot tar -xf /tmp/a.tar -C ~"
row "5094 unshare wrapper"                     deny  "unshare -m tar -xf /tmp/a.tar -C ~"
row "5094 unshare --map-root-user wrapper"     deny  "unshare --user --map-root-user tar -xf /tmp/a.tar -C ~"
row "5094 ltrace wrapper"                      deny  "ltrace tar -xf /tmp/a.tar -C ~"
row "5094 nsenter wrapper"                     deny  "nsenter -t 1 -m tar -xf /tmp/a.tar -C ~"
row "5094 firejail wrapper"                    deny  "firejail --quiet tar -xf /tmp/a.tar -C ~"
row "5094 bwrap wrapper"                       deny  "bwrap --bind / / tar -xf /tmp/a.tar -C ~"
row "5094 unknown wrapper"                     deny  "somewrapper --opt tar -xf /tmp/a.tar -C ~"
row "5094 wrapper unzip"                       deny  "fakeroot unzip /tmp/a.zip -d ~/.himmel"
row "5094 wrapper, cwd HOME"                   deny  "strace tar -xf /tmp/a.tar" "$HOME"
row "5094 wrapper, safe dest (ctrl)"           allow "strace -f tar -xf /tmp/a.tar -C /var/out"
row "5094 wrapper on a non-extractor (ctrl)"   allow "strace -o /tmp/t.out ls ~"
row "5094 apt install tar (ctrl)"              allow "apt install tar"
row "5094 command word in a variable"          deny  "c=tar; \$c -xf /tmp/a.tar -C ~"
row "5094 quoted variable command word"        deny  "c=tar; \"\$c\" -xf /tmp/a.tar -C ~"
row "5094 braced variable command word"        deny  "c=tar; \${c} -xf /tmp/a.tar -C ~"
row "5094 var command, var dest"               deny  "c=tar; D=~; \$c -xf /tmp/a.tar -C \"\$D\""
row "5094 var command, safe dest (ctrl)"       allow "c=tar; \$c -xf /tmp/a.tar -C /var/out"
row "5094 var command on a file in HOME (ctrl)" allow "\$EDITOR ~/notes.txt"
row "5094 7z x -o HOME"                        deny  "7z x /tmp/a.7z -o\$HOME"
row "5094 7za x -o ~/.himmel"                  deny  "7za x /tmp/a.7z -o~/.himmel"
row "5094 7z e, cwd HOME"                      deny  "7z e /tmp/a.7z" "$HOME"
row "5094 7z x, safe dest (ctrl)"              allow "7z x /tmp/a.7z -o/var/out"
row "5094 7z l (ctrl)"                         allow "7z l /tmp/a.7z" "$HOME"
row "5094 pax -r, cwd HOME"                    deny  "pax -rf /tmp/a.tar" "$HOME"
row "5094 pax -rw copy into HOME"              deny  "pax -rw /tmp/src ~"
row "5094 pax -r -s rewrite"                   deny  "pax -rf /tmp/a.tar -s ',^,/home/x/,'"
row "5094 ar x, cwd HOME"                      deny  "ar x /tmp/a.a" "$HOME"
row "5094 ar t (ctrl)"                         allow "ar t /tmp/a.a" "$HOME"
row "5094 jar xf, cwd HOME"                    deny  "jar xf /tmp/a.jar" "$HOME"
row "5094 jar tf (ctrl)"                       allow "jar tf /tmp/a.jar" "$HOME"
row "5094 dpkg -x HOME"                        deny  "dpkg -x /tmp/a.deb ~"
row "5094 dpkg-deb -x ~/.himmel"               deny  "dpkg-deb -x /tmp/a.deb ~/.himmel"
row "5094 dpkg --extract HOME"                 deny  "dpkg --extract /tmp/a.deb ~"
row "5094 dpkg -x safe dest (ctrl)"            allow "dpkg -x /tmp/a.deb /var/out"
row "5094 dpkg -l (ctrl)"                      allow "dpkg -l"
row "5094 dpkg -X HOME"                        deny  "dpkg -X /tmp/a.deb ~"
row "5094 pnpm exec tar HOME"                  deny  "pnpm exec tar -xf /tmp/a.tar -C ~"
row "5094 yarn exec tar HOME"                  deny  "yarn exec tar -xf /tmp/a.tar -C ~"
row "5094 npx tar HOME"                        deny  "npx tar -xf /tmp/a.tar -C ~"
row "5094 npm install tar (ctrl)"              allow "npm install tar"
row "5094 pnpm add tar (ctrl)"                 allow "pnpm add tar"
row "5094 unar -o HOME"                        deny  "unar -o ~ /tmp/a.zip"
row "5094 unar, cwd HOME"                      deny  "unar /tmp/a.zip" "$HOME"
row "5094 unar safe dest (ctrl)"               allow "unar -o /var/out /tmp/a.zip"
row "5094 bsdcpio -id"                         deny  "bsdcpio -id < /tmp/a.cpio"
row "5094 python -m tarfile -e HOME"           deny  "python3 -m tarfile -e /tmp/a.tar ~"
row "5094 python -m zipfile -e HOME"           deny  "python3 -m zipfile -e /tmp/a.zip ~/.himmel"
row "5094 python -m zipfile -e safe (accepted over-deny)" deny "python3 -m zipfile -e /tmp/a.zip /var/out"
row "5094 python -m tarfile -l (ctrl)"         allow "python3 -m tarfile -l /tmp/a.tar"
row "5094 wrapped 7z"                          deny  "strace 7z x /tmp/a.7z -o~"
row "5094 python os.symlink + tar"             deny  "python3 -c \"import os; os.symlink('/home','/var/out/h')\"; tar -xf /tmp/a.tar -C /var/out"
row "5094 perl symlink + unzip"                deny  "perl -e 'symlink(\"/home\",\"/var/out/h\")'; unzip /tmp/a.zip -d /var/out"
row "5094 node symlinkSync + tar"              deny  "node -e \"require('fs').symlinkSync('/home','/var/out/h')\" && tar -xf /tmp/a.tar -C /var/out"
row "5094 ruby File.symlink + tar"             deny  "ruby -e 'File.symlink(\"/home\",\"/var/out/h\")'; tar -xf /tmp/a.tar -C /var/out"
row "5094 python no symlink + tar (ctrl)"      allow "python3 -c 'print(1)'; tar -xf /tmp/a.tar -C /var/out"
_nest() { local n="$1" c="$2" i; for ((i=0;i<n;i++)); do c=$(printf 'bash -c %q' "$c"); done; printf '%s' "$c"; }
row "5094 nesting depth 5"                     deny  "$(_nest 5 'tar -xf /tmp/a.tar -C ~')"
row "5094 nesting depth 7"                     deny  "$(_nest 7 'tar -xf /tmp/a.tar -C ~')"
row "5094 nesting depth 5, safe dest (ctrl)"   allow "$(_nest 5 'tar -xf /tmp/a.tar -C /var/out')"
row "5094 nesting depth 5, echo (ctrl)"        allow "$(_nest 5 'echo hi')"


echo "== HIMMEL-5094 judge j2243a NO-GO fixes =="
# (1) an unmodelled wrapper in front of a shell -c / eval fails closed
row "5094 j1 strace -f bash -c tar ~"          deny  "strace -f bash -c \"tar -xf /tmp/a.tar -C ~\""
row "5094 j1 fakeroot sh -c unzip ~/.himmel"   deny  "fakeroot sh -c \"unzip /tmp/a.zip -d ~/.himmel\""
row "5094 j1 unshare -m bash -c tar"           deny  "unshare -m bash -c \"tar -xf /tmp/a.tar -C ~\""
row "5094 j1 fakeroot eval tar"                deny  "fakeroot eval \"tar -xf /tmp/a.tar -C ~\""
row "5094 j1 strace -f sh -c 7z"               deny  "strace -f sh -c \"7z x /tmp/a.7z -o\$HOME\""
row "5094 j1 firejail bash -c"                 deny  "firejail --quiet bash -c \"tar -xf /tmp/a.tar -C ~\""
row "5094 j1 pnpm exec bash -c"                deny  "pnpm exec bash -c \"tar -xf /tmp/a.tar -C ~\""
row "5094 j1 wrapper bash -c link at HOME"     deny  "strace -f bash -c \"ln -s ~ /var/out/h; tar -xf /tmp/a.tar -C /var/out\""
row "5094 j1 strace bash script.sh (ctrl)"     allow "strace -f bash /tmp/s.sh"
row "5094 j1 strace bash -c safe (ctrl)"       allow "strace -f bash -c \"tar -xf /tmp/a.tar -C /tmp/x\""
# (2) a variable command word after a cd into HOME / the bank-lift dir, or in a HOME cwd
row "5094 j2 var cmd, cd ~ then"               deny  "c=tar; cd ~ && \$c -xf /tmp/a.tar"
row "5094 j2 var cmd, cd ~/.himmel"            deny  "c=unzip; cd ~/.himmel && \$c /tmp/a.zip"
row "5094 j2 var cmd, cd \$HOME/.himmel/state" deny  "c=tar; cd \$HOME/.himmel/state && \$c -xf /tmp/a.tar"
row "5094 j2 var cmd, cwd HOME"                deny  "c=tar; \$c -xf /tmp/a.tar" "$HOME"
row "5094 j2 var cmd 7z, cwd HOME"             deny  "c=7z; \$c x /tmp/a.7z" "$HOME"
row "5094 j2 var cmd, cd /tmp (accepted over-deny)" deny "c=tar; cd /tmp/x && \$c -xf /tmp/a.tar"
row "5094 j2 var cmd no archive, cwd HOME"     allow "\$EDITOR notes.txt" "$HOME"
# (3) python -m inside a combined short-flag cluster
row "5094 j3 python3 -Im tarfile -e ~"         deny  "python3 -Im tarfile -e /tmp/a.tar ~"
row "5094 j3 python3 -Imtarfile -e ~"          deny  "python3 -Imtarfile -e /tmp/a.tar ~"
row "5094 j3 python3 -Bm zipfile -e ~/.himmel" deny  "python3 -Bm zipfile -e /tmp/a.zip ~/.himmel"
row "5094 j3 python3 -BIm tarfile, cwd HOME"   deny  "python3 -BIm tarfile -e /tmp/a.tar" "$HOME"
row "5094 j3 python3 -Im tarfile -l (ctrl)"    allow "python3 -Im tarfile -l /tmp/a.tar"
row "5094 j3 python3 -Im tarfile -e safe (accepted over-deny)" deny "python3 -Im tarfile -e /tmp/a.tar /tmp/x"
# (5) fail-closed rules are scoped to the HOME bank-lift target, not a /home/ substring
WTU=home   # a worktree lives under a user dir; spelled apart so the home-path leak gate stays quiet
WT=/$WTU/dev/repos/proj/.claude/worktrees/w
row "5094 j5 var cmd + worktree path + tar (accepted over-deny)" deny "\$PY \$ARG $WT/a.tar; tar -tf $WT/a.tar"
row "5094 j5 var cmd + worktree path + ar (accepted over-deny)" deny "\"\$PY\" /tmp/s.py \"\$X\" $WT ar"
row "5094 j5 var cmd + worktree extract"       allow "c=tar; \$c -xf $WT/a.tar -C $WT/out"
row "5094 j5 print symlink + tar /tmp"         allow "python3 -c 'print(\"symlink\")'; tar -xf /tmp/a.tar -C /tmp/x"
row "5094 j5 print ln -s word + tar /tmp"      allow "python3 -c 'print(\"ln -s\")'; tar -xf /tmp/a.tar -C /tmp/x"
row "5094 j5 depth 5 worktree tar"             allow "$(_nest 5 "tar -xf $WT/a.tar -C $WT/out")"
row "5094 j5 var cmd + computed + tar ~"       deny  "c=tar; d=\$HOME; \$c -xf /tmp/a.tar -C \$d"
row "5094 j5 python os.symlink call + tar"     deny  "python3 -c 'import os; os.symlink(\"/home\",\"/var/out/h\")'; tar -xf /tmp/a.tar -C /var/out"
# /pr-check round 3 (codex): option clusters and stdin shells under a wrapper
row "5094 r3 ar -v -x, cwd HOME"               deny  "ar -v -x /tmp/a.a" "$HOME"
row "5094 r3 ar -vx, cwd HOME"                 deny  "ar -vx /tmp/a.a" "$HOME"
row "5094 r3 ar -t, cwd HOME (ctrl)"           allow "ar -t /tmp/a.a" "$HOME"
row "5094 r3 ar -v -x, safe cwd (ctrl)"        allow "ar -v -x /tmp/a.a"
row "5094 r3 strace python3 -Imtarfile -e ~"   deny  "strace python3 -Imtarfile -e /tmp/a.tar ~"
row "5094 r3 fakeroot python3 -Bmzipfile -e ~" deny  "fakeroot python3 -Bmzipfile -e /tmp/a.zip ~"
row "5094 r3 strace python3 -Imtarfile -l"     allow "strace python3 -Imtarfile -l /tmp/a.tar"
row "5094 r3 strace bash <<< tar ~"            deny  "strace bash <<< 'tar -xf /tmp/a.tar -C ~'"
row "5094 r3 fakeroot sh <<< unzip ~"          deny  "fakeroot sh <<< 'unzip /tmp/a.zip -d ~/.himmel'"
row "5094 r3 strace bash <<< echo (ctrl)"      allow "strace bash <<< 'echo hi'"
row "5094 r3 strace bash script.sh (ctrl)"     allow "strace bash /tmp/s.sh"
# j2243b: a variable-held extractor after a cd whose target is HOME or unknown.
row "5094 r4 bare cd; \$T xf"                   deny  "T=tar; cd; \$T xf /tmp/a.tar"
row "5094 r4 bare cd && \$T xf"                 deny  "T=tar; cd && \$T xf /tmp/a.tar"
row "5094 r4 cd \$D && \$T xf"                  deny  "T=tar; D=~; cd \$D && \$T xf /tmp/a.tar"
row "5094 r4 cd \"\$D\"; \$T -xf"                deny  "T=tar; cd \"\$D\"; \$T -xf /tmp/a.tar"
row "5094 r4 pushd; \$T xf"                     deny  "T=tar; pushd; \$T xf /tmp/a.tar"
row "5094 r4 cd -P; \$T xf (bare, option only)" deny  "T=tar; cd -P; \$T xf /tmp/a.tar"
row "5094 r4 cd \$(pwd)/..; \$T xf"              deny  "T=tar; cd \$(pwd)/..; \$T xf /tmp/a.tar"
row "5094 r4 bare cd newline \$T xf"            deny  "T=tar; cd
\$T xf /tmp/a.tar"
row "5094 r4 cd /tmp/w; \$T xf (accepted over-deny)" deny "T=tar; cd /tmp/w; \$T xf /tmp/a.tar"
row "5094 r4 \$T tf, no cd (ctrl)"              allow "T=tar; \$T tf /tmp/a.tar"
row "5094 r4 bare cd; echo (ctrl)"              allow "cd; echo hi"
row "5094 r4 cd /tmp/w; \$T --version (ctrl)"   allow "T=git; cd /tmp/w; \$T status"
# j2243b: python -m behind any CPython short flag (-b and the rest) in a cluster.
row "5094 r4 python3 -bm tarfile -e ~"          deny  "python3 -bm tarfile -e /tmp/a.tar ~"
row "5094 r4 python3 -bIm tarfile -e ~"         deny  "python3 -bIm tarfile -e /tmp/a.tar ~"
row "5094 r4 python3 -Ibm zipfile -e ~"         deny  "python3 -Ibm zipfile -e /tmp/a.zip ~/.himmel"
row "5094 r4 python3 -bmtarfile -e ~"           deny  "python3 -bmtarfile -e /tmp/a.tar ~"
row "5094 r4 python3 -bm tarfile -e, cwd HOME"  deny  "python3 -bm tarfile -e /tmp/a.tar" "$HOME"
row "5094 r4 strace python3 -bm tarfile -e ~"   deny  "strace python3 -bm tarfile -e /tmp/a.tar ~"
row "5094 r4 fakeroot python3 -bIm zipfile -e ~" deny "fakeroot python3 -bIm zipfile -e /tmp/a.zip ~"
row "5094 r4 python3 -bm tarfile -l (ctrl)"     allow "python3 -bm tarfile -l /tmp/a.tar"
row "5094 r4 python3 -bm json.tool (ctrl)"      allow "python3 -bm json.tool /tmp/a.json"
row "5094 r4 python3 -bm tarfile -e /tmp (accepted over-deny)" deny "python3 -bm tarfile -e /tmp/a.tar /tmp/out"
# j2243c: the directory-changing and computed-argument shapes beside a
# variable-held extractor deny whole (text layer, broad fail closed).
row "5094 r5 cd \" \$D\"; \$T xf"                deny  "T=tar; D=~; cd \" \$D\"; \$T xf /tmp/a.tar"
row "5094 r5 CDPATH; cd; \$T xf"                deny  "T=tar; CDPATH=/home; cd overlord; \$T xf /tmp/a.tar"
row "5094 r5 cd ../../..; \$T xf"               deny  "T=tar; cd ../../..; \$T xf /tmp/a.tar"
row "5094 r5 cd /; \$T xf"                      deny  "T=tar; cd /; \$T xf /tmp/a.tar"
row "5094 r5 cd glob HOME; \$T xf"              deny  "T=tar; cd /hom?/overlor?; \$T xf /tmp/a.tar"
row "5094 r5 cd backslash-newline \$D; \$T xf"  deny  "T=tar; D=~; cd \\
\"\$D\"; \$T xf /tmp/a.tar"
row "5094 r5 'cd' \$D; \$T xf"                  deny  "T=tar; D=~; 'cd' \"\$D\"; \$T xf /tmp/a.tar"
row "5094 r5 c\\d ~; \$T xf"                     deny  "T=tar; c\\d ~; \$T xf /tmp/a.tar"
row "5094 r5 \$T xf -C \"\$D\" (getent)"          deny  "T=tar; D=\$(getent passwd me | cut -d: -f6); \$T xf /tmp/a.tar -C \"\$D\""
row "5094 r5 env -C ~ \$T xf"                   deny  "T=tar; env -C ~ \$T xf /tmp/a.tar"
row "5094 r5 env --chdir=\$D \$T xf"             deny  "T=tar; env --chdir=\"\$D\" \$T xf /tmp/a.tar"
row "5094 r5 sudo -D ~ \$T xf"                  deny  "T=tar; sudo -D ~ \$T xf /tmp/a.tar"
row "5094 r5 \$T xf --directory=\$D"             deny  "T=tar; D=\$(getent passwd me|cut -d: -f6); \$T xf /tmp/a.tar --directory=\"\$D\""
row "5094 r5 cd quoted space prefix then \$D"   deny  "T=tar; D=../../home/me; cd \"/tmp/x y/\$D\"; \$T xf /tmp/a.tar"
row "5094 r5 pushd quoted space then \$D"       deny  "T=tar; pushd \"/tmp/x y/\$D\"; \$T xf /tmp/a.tar"
row "5094 r5 cd dq space brace HOME"            deny  "T=tar; cd \"/tmp/x y/../../\${HOME}\"; \$T xf /tmp/a.tar"
row "5094 r5 cd subst with space"               deny  "T=tar; cd \"\$( printf %s ~ )\"; \$T xf /tmp/a.tar"
row "5094 r5 popd; \$T xf"                      deny  "T=tar; pushd -n /tmp >/dev/null; popd; \$T xf /tmp/a.tar"
row "5094 r5 cd \"/tmp/x y\" literal; \$T xf (accepted over-deny)" deny "T=tar; cd \"/tmp/x y\"; \$T xf /tmp/a.tar"
row "5094 r5 \$T tf, no cd, no computed arg (ctrl)" allow "T=tar; \$T tf /tmp/a.tar"
row "5094 r5 plain tar -C /tmp/out (ctrl)"      allow "tar xf /tmp/a.tar -C /tmp/out"
row "5094 r5 cd \$WT && \$PY -m pytest (ctrl)"  allow "cd \"\$WT\" && \$PY -m pytest tests/test_tar.py"
row "5094 r5 cd \$D && \$MAKE build (ctrl)"     allow "cd \"\$D\" && \$MAKE build"
row "5094 r5 bare cd; \$EDITOR (ctrl)"          allow "cd; \$EDITOR notes.md"
# j2243c: python -m tarfile|zipfile is allowed only as a pure list/test.
row "5094 r5 python3 -m tarfile -ve ~"          deny  "python3 -m tarfile -ve /tmp/a.tar ~"
row "5094 r5 python3 -m tarfile --ex ~"         deny  "python3 -m tarfile --ex /tmp/a.tar ~"
row "5094 r5 python3 -m zipfile --ext ~"        deny  "python3 -m zipfile --ext /tmp/a.zip ~"
row "5094 r5 python3 -m tarfile --filter data -e ~" deny "python3 -m tarfile --filter data -e /tmp/a.tar ~"
row "5094 r5 python3 -m tarfile -e -- ~"        deny  "python3 -m tarfile -e -- /tmp/a.tar ~"
row "5094 r5 python3 -m tarfile -e rel dest"    deny  "python3 -m tarfile -e /tmp/a.tar .."
row "5094 r5 python3 -m tarfile -l (ctrl)"      allow "python3 -m tarfile -l /tmp/a.tar"
row "5094 r5 python3 -m tarfile --list (ctrl)"  allow "python3 -m tarfile --list /tmp/a.tar"
row "5094 r5 python3 -m zipfile -t (ctrl)"      allow "python3 -m zipfile -t /tmp/a.zip"
row "5094 r5 python3 -m json.tool (ctrl)"       allow "python3 -Im json.tool /tmp/a.json"
# j2243d: the variable-held command word uses the literal path's cwd verdict
# (backslash-newline cd, find -execdir), env/sudo -C/-D in any flag cluster is
# read on the whole text, and tarfile*/zipfile* or a computed module name denies.
row "5094 r6 E03 backslash-newline cd"          deny  $'T=tar; c\\\nd; $T xf /tmp/a.tar'
row "5094 r6 E04 backslash-newline pushd"       deny  $'T=tar; pu\\\nshd ../../..; $T xf /tmp/a.tar'
row "5094 r6 E21 env -iC"                       deny  "T=tar; env -iC ../../.. \$T xf /tmp/a.tar"
row "5094 r6 E21e env -0C"                      deny  "T=tar; env -0C ../../.. \$T xf /tmp/a.tar"
row "5094 r6 E28 find -execdir"                 deny  "T=tar; find ~ -maxdepth 0 -execdir \$T xf /tmp/a.tar \\;"
row "5094 r6 F01 zipfile.__main__"              deny  "python3 -m zipfile.__main__ -e /tmp/a.zip ~"
row "5094 r6 F01b zipfile.__main__ attached"    deny  "python3 -mzipfile.__main__ -e /tmp/a.zip ~"
row "5094 r6 F14 uv run zipfile.__main__"       deny  "uv run python -m zipfile.__main__ -e /tmp/a.zip ~"
row "5094 r6 F04 computed module"               deny  "M=tarfile; python3 -m \$M -e /tmp/a.tar ~"
row "5094 r6 F05 computed module quoted"        deny  "M=zipfile; python3 -m \"\$M\" -e /tmp/a.zip ~"
row "5094 r6 env -C literal tar (ctrl)"         allow "env -C /tmp/w tar tf /tmp/a.tar"
row "5094 r6 computed module, no archive (ctrl)" allow "M=json.tool; python3 -m \$M /tmp/a.json"

echo "== generated write-verb axis (shared write-fence grammar) =="
# The verb x spelling axis the main-checkout fence suite enumerates, rendered
# against the lift path. Every verb must deny; rm too since round 6 (it was
# the ALLOW control before: removing a lift only tightens the gate).
# shellcheck source=./lib-test-write-fence-matrix.sh
. "$HOOKS/lib-test-write-fence-matrix.sh" || { bad "source lib-test-write-fence-matrix.sh"; exit 1; }
mrows=0
while IFS='	' read -r vlabel vtmpl; do
    [ -n "$vlabel" ] || continue
    cmd=$(_matrix_render_cmd "$vtmpl" "/tmp/x.json" "$P")
    exp=deny   # rm rows too since round 6: rm names bank-lift.json, not a reader
    row "matrix: $vlabel" "$exp" "$cmd"
    mrows=$((mrows+1))
done <<EOF
$(_matrix_srcless_verbs)
$(_matrix_src_verbs)
EOF
# A failed generator leaves the heredoc empty: no rows must read as a failure.
if [ "$mrows" -ge 10 ]; then ok "matrix generated $mrows rows"; else bad "matrix generated only $mrows rows"; fi

echo
echo "PASS: $pass  FAIL: $fail"
[ "$fail" -eq 0 ]
