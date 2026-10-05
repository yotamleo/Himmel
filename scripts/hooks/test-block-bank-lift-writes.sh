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
mkdir -p "$ST" "$REPO/scripts/lib" "$T/src/sub"
: > "$REPO/scripts/lib/bank-lift.sh"
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
row "xargs cat lift (read, allow)"  allow "echo x | xargs -I{} cat $P"
row "xargs grep lift (read, allow)" allow "echo until | xargs -I{} grep -n {} $P"
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
row "cat lift > /tmp copy"         allow "cat ~/.himmel/state/bank-lift.json > /tmp/lift-copy.json"
row "cp lift to /tmp (read)"       allow "cp ~/.himmel/state/bank-lift.json /tmp/lift-copy.json"
row "rm the lift (tightens)"       allow "rm -f ~/.himmel/state/bank-lift.json"
row "test -f the lift"             allow "test -f ~/.himmel/state/bank-lift.json && echo yes"
row "ls state/"                    allow "ls -la ~/.himmel/state"
row "write other state file"       allow "echo x > ~/.himmel/state/other.json"
row "write lift-named file elsewhere" allow "echo x > /tmp/x/bank-lift.json"
row "write lookalike name"         allow "echo x > ~/.himmel/state/bank-lift.json.bak"
row "grep pattern"                 allow "grep -rn 'bank-lift' scripts/"
row "git grep 'bank-lift.sh set'"  allow "git grep -n 'bank-lift.sh set'"
row "commit message mention"       allow "git commit -m 'feat: [HIMMEL-4445] deny agent writes to ~/.himmel/state/bank-lift.json'"
row "commit message with set"      allow "git commit -m 'docs: bank-lift.sh set is operator-only'"
row "echo mention"                 allow "echo 'run: bash scripts/lib/bank-lift.sh set'"
row "set -e then show"             allow "set -euo pipefail; bash $S show"
row "preflight script"             allow "bash scripts/lib/bank-preflight.sh"
row "test suite"                   allow "bash scripts/lib/test-bank-preflight.sh"
row "cp unrelated"                 allow "cp a.txt b.txt"
row "redirect unrelated"           allow "echo hi > /tmp/out.txt 2>&1"
row "git config set"               allow "git config set user.name x"
row "Read-shaped python"           allow "python3 -c 'print(1)'"
row "mv the lift away (tightens)"  allow "mv ~/.himmel/state/bank-lift.json /tmp/old-lift.json"
row "redirect to \$OUT"            allow "echo x > \"\$OUT\""
row "cd + find -exec {}"           allow "cd foo && find . -name '*.tmp' -exec rm {} \\;"
row "rsync -avt (t is a flag)"     allow "rsync -avt src/ dst/"
row "heredoc commit naming set"    allow "git commit -F - <<'EOF'
feat: bash scripts/lib/bank-lift.sh set is operator-only
EOF"
row "\$(cat heredoc) commit naming set" allow "git commit -m \"\$(cat <<'EOF'
feat: [HIMMEL-4445] deny bash scripts/lib/bank-lift.sh set
EOF
)\""
# Differential over the session history (HIMMEL-4445): an interpreter running a
# script FILE whose data args merely mention bank-lift, and inline code whose
# prose says "bank" and "lift"/"left" without naming the lift file, are not
# writes.
row "node script, title mentions bank-lift" allow "node /x/jira/dist/index.js create --type Task --title 'bank-lift: hook-deny agent writes to ~/.himmel/state/bank-lift.json and bank-lift.sh set'"
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
row "real dir/.. outside state (control)"  allow "echo x > $T/src/sub/../bank-lift.json"
row "busybox by absolute path sh -c"       deny  "/usr/bin/busybox sh -c 'echo x > $P'"
row "busybox by relative path sh -c"       deny  "./busybox sh -c 'echo x > $P'"

echo "== review round 2 (codex-1, codex-2) =="
# sed writes a file with its w/W command (or the s///w flag), no -i needed.
row "sed w command"                        deny  "sed 'w $P' /tmp/in"
row "sed -n -e W command"                  deny  "sed -n -e 'W $P' /tmp/in"
row "sed --expression= s///w flag"         deny  "sed --expression='s/a/b/w $P' /tmp/in"
row "sed -ne bundle, w after address"      deny  "sed -ne '/x/w $P' /tmp/in"
row "sed e command naming the lift"        deny  "sed '1e cp /tmp/x ~/.himmel/state/bank-lift.json' /tmp/in"
row "sed reads the lift (control)"         allow "sed -n p $P"
row "sed w elsewhere (control)"            allow "sed 'w /tmp/out' $P"
row "sed -e script, lift is a file (ctrl)" allow "sed -e 's/w/x/' $P"
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
row "cat <<EOF body names bank-lift (ctrl)" allow "cat <<EOF
run bank-lift.sh set 10 at \$(date)
EOF"

echo "== generated write-verb axis (shared write-fence grammar) =="
# The verb x spelling axis the main-checkout fence suite enumerates, rendered
# against the lift path. rm rows are the ALLOW control (removing a lift only
# tightens the gate); every other verb must deny.
# shellcheck source=./lib-test-write-fence-matrix.sh
. "$HOOKS/lib-test-write-fence-matrix.sh" || { bad "source lib-test-write-fence-matrix.sh"; exit 1; }
mrows=0
while IFS='	' read -r vlabel vtmpl; do
    [ -n "$vlabel" ] || continue
    cmd=$(_matrix_render_cmd "$vtmpl" "/tmp/x.json" "$P")
    case "$vlabel" in rm|"rm -r") exp=allow ;; *) exp=deny ;; esac
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
