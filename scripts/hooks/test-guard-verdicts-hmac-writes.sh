#!/usr/bin/env bash
# Tests for guard-verdicts-hmac-writes.sh (HIMMEL-4733): no agent tool reads or
# writes the GO HMAC key (~/.config/himmel/go-hmac.key), in any session, judge
# included; and no session but a judge (HIMMEL_CONSOLE_JUDGE=1) writes under a
# verdicts/ dir, the sanctioned writer being console-kit/write-verdict.sh.
# Every row runs twice — a normal session and a judge session — each with its
# own expected rc, so the judge exemption is pinned to verdicts/ alone.
#
# Usage: bash scripts/hooks/test-guard-verdicts-hmac-writes.sh
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Pure bash + jq over a temp sandbox (a scratch HOME holds a FAKE key; the real
# key and the real verdicts/ are never named).
# shellcheck disable=SC2016 # rows feed literal command text
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/guard-verdicts-hmac-writes.sh"

BASH_ABS=$(command -v bash)
[ -n "$BASH_ABS" ] || { echo "FATAL: cannot resolve bash on PATH" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/verdicts-hmac-test.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 1; }
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

H="$TMP/home"
KEYDIR="$H/.config/himmel"
KEY="$KEYDIR/go-hmac.key"
ROOT="$TMP/handovers"
VD="$ROOT/u/himmel/verdicts"
REPO="$TMP/repo"
mkdir -p "$KEYDIR/sub" "$VD/q1/sub" "$H/.cache/himmel/verdicts/q1/scratch" "$REPO/scripts" "$TMP/work"
printf 'fake\n' > "$KEY"
printf 'X=1\n' > "$KEYDIR/env"
printf '# VERDICT\n' > "$VD/q1/judge.md"
ln -s "$KEY" "$TMP/alias"
ln -s "$KEYDIR" "$TMP/keydir-link"
ln -s "$VD" "$TMP/vd-link"
ln -s "$KEYDIR/sub" "$TMP/keysub-link"
ln -s "$VD/q1/sub" "$TMP/vsub-link"
SHA=0123456789abcdef0123456789abcdef01234567

pass=0
fail=0

# run <payload-json> <judge 0|1> — prints the hook's rc.
run() {
    if [ "$2" = "1" ]; then
        printf '%s' "$1" | env HOME="$H" HANDOVER_DIR="$ROOT" HIMMEL_CONSOLE_JUDGE=1 "$BASH_ABS" "$HOOK" >/dev/null 2>&1
    else
        printf '%s' "$1" | env -u HIMMEL_CONSOLE_JUDGE HOME="$H" HANDOVER_DIR="$ROOT" "$BASH_ABS" "$HOOK" >/dev/null 2>&1
    fi
    printf '%s' "$?"
}

# row <label> <rc normal> <rc judge> <payload-json>
row() {
    local label="$1" wn="$2" wj="$3" payload="$4" got
    got=$(run "$payload" 0)
    if [ "$got" = "$wn" ]; then
        echo "ok   normal: $label (rc=$got)"; pass=$((pass + 1))
    else
        echo "FAIL normal: $label — expected rc=$wn, got rc=$got"; fail=$((fail + 1))
    fi
    got=$(run "$payload" 1)
    if [ "$got" = "$wj" ]; then
        echo "ok   judge:  $label (rc=$got)"; pass=$((pass + 1))
    else
        echo "FAIL judge:  $label — expected rc=$wj, got rc=$got"; fail=$((fail + 1))
    fi
}

# bash_p <command> [cwd]
bash_p() { jq -nc --arg c "$1" --arg d "${2:-$TMP/work}" '{tool_name:"Bash", cwd:$d, tool_input:{command:$c}}'; }
# file_p <tool> <path> [cwd]
file_p() { jq -nc --arg t "$1" --arg p "$2" --arg d "${3:-$TMP/work}" '{tool_name:$t, cwd:$d, tool_input:{file_path:$p, content:"x", old_string:"a", new_string:"b"}}'; }
nb_p() { jq -nc --arg p "$1" '{tool_name:"NotebookEdit", tool_input:{notebook_path:$p, new_source:"x"}}'; }
grep_p() { jq -nc --arg p "$1" '{tool_name:"Grep", tool_input:{pattern:"x", path:$p}}'; }
patch_p() { jq -nc --arg c "$1" '{tool_name:"apply_patch", tool_input:{command:$c}}'; }

# ---- 1. the HMAC key: denied in every session, judge included ----
row "Read key" 2 2 "$(file_p Read "$KEY")"
row "Read key via symlinked file" 2 2 "$(file_p Read "$TMP/alias")"
row "Read key via symlinked dir" 2 2 "$(file_p Read "$TMP/keydir-link/go-hmac.key")"
row "Read key relative from its dir" 2 2 "$(file_p Read go-hmac.key "$KEYDIR")"
row "Grep the key dir" 2 2 "$(grep_p "$KEYDIR")"
row "Grep ~/.config" 2 2 "$(grep_p "$H/.config")"
row "Write key" 2 2 "$(file_p Write "$KEY")"
row "Edit key" 2 2 "$(file_p Edit "$KEY")"
row "MultiEdit key" 2 2 "$(file_p MultiEdit "$KEY")"
row "NotebookEdit key" 2 2 "$(nb_p "$KEY")"
row "Write a key temp beside it" 2 2 "$(file_p Write "$KEYDIR/.go-hmac.AbC123")"
row "apply_patch the key" 2 2 "$(patch_p "*** Begin Patch
*** Update File: $KEY
@@
-a
+b
*** End Patch")"
row "cat key" 2 2 "$(bash_p "cat $KEY")"
row "cat ~ spelling" 2 2 "$(bash_p 'cat ~/.config/himmel/go-hmac.key')"
row "cat \$HOME spelling" 2 2 "$(bash_p 'cat $HOME/.config/himmel/go-hmac.key')"
row "cat \${HOME} quoted spelling" 2 2 "$(bash_p 'cat "${HOME}/.config/himmel/go-hmac.key"')"
row "cat through symlinked file" 2 2 "$(bash_p "cat $TMP/alias")"
row "input redirect" 2 2 "$(bash_p "xxd < $KEY")"
row "cp key out" 2 2 "$(bash_p "cp $KEY /tmp/x")"
row "redirect into key" 2 2 "$(bash_p "echo x > $KEY")"
row "rm key" 2 2 "$(bash_p "rm -f $KEY")"
row "mv over key" 2 2 "$(bash_p "mv /tmp/k $KEY")"
row "tee key" 2 2 "$(bash_p "printf x | tee $KEY")"
row "ln -s to key" 2 2 "$(bash_p "ln -s $KEY /tmp/l")"
row "dd if=key" 2 2 "$(bash_p "dd if=$KEY of=/tmp/x")"
row "assignment then expand" 2 2 "$(bash_p "K=$KEY; cat \"\$K\"")"
row "glob in key dir" 2 2 "$(bash_p 'cat ~/.config/himmel/go-*')"
row "star in key dir" 2 2 "$(bash_p 'cat ~/.config/himmel/*')"
row "glob over the dir names" 2 2 "$(bash_p 'cat ~/.c*/h*/g*')"
row "glob through symlinked dir" 2 2 "$(bash_p "cat $TMP/keydir-link/*")"
row "cp -r the key dir" 2 2 "$(bash_p 'cp -r ~/.config/himmel /tmp/x')"
row "tar ~/.config" 2 2 "$(bash_p 'tar czf /tmp/x.tgz ~/.config')"
row "cd into the dir" 2 2 "$(bash_p 'cd ~/.config/himmel && ls')"
row "cd parent then relative" 2 2 "$(bash_p 'cd ~/.config && cat himmel/go-hmac.key')"
row "interpreter one-liner" 2 2 "$(bash_p "python3 -c \"print(open('$KEY').read())\"")"
row "bash -c body" 2 2 "$(bash_p "bash -c 'cat $KEY'")"
row "bash -lc tar ~/.config" 2 2 "$(bash_p "bash -lc 'tar czf /tmp/x.tgz ~/.config'")"
row "nested bash -c glob" 2 2 "$(bash_p "sh -c \"bash -c 'cat ~/.c*/h*/g*'\"")"
row "env-wrapped tar ~/.config" 2 2 "$(bash_p "env 'FOO=a b'c tar czf /tmp/x.tgz ~/.config")"

# ---- 2. verdicts/: judge-only writes ----
row "Write verdict" 2 0 "$(file_p Write "$VD/q1/judge.md")"
row "Edit verdict" 2 0 "$(file_p Edit "$VD/q1/judge.md")"
row "Write new verdict dir" 2 0 "$(file_p Write "$VD/q2/judge.md")"
row "Write via symlinked verdicts dir" 2 0 "$(file_p Write "$TMP/vd-link/q1/judge.md")"
row "Write relative into verdicts" 2 0 "$(file_p Write verdicts/q1/judge.md "$ROOT/u/himmel")"
row "NotebookEdit verdict" 2 0 "$(nb_p "$VD/q1/judge.ipynb")"
row "apply_patch add verdict" 2 0 "$(patch_p "*** Begin Patch
*** Add File: $VD/q1/judge.md
+**GO**
*** End Patch")"
row "redirect into verdict" 2 0 "$(bash_p "echo '**GO**' > $VD/q1/judge.md")"
row "append into verdict" 2 0 "$(bash_p "echo x >> $VD/q1/judge.md")"
row "relative redirect" 2 0 "$(bash_p 'echo x > verdicts/q1/judge.md' "$ROOT/u/himmel")"
row "cp into verdict" 2 0 "$(bash_p "cp /tmp/x $VD/q1/judge.md")"
row "cp into verdict dir" 2 0 "$(bash_p "cp /tmp/x $VD/q1/")"
row "cp -t verdict dir" 2 0 "$(bash_p "cp -t $VD/q1 /tmp/x")"
row "tee verdict" 2 0 "$(bash_p "printf x | tee $VD/q1/judge.md")"
row "rm verdict" 2 0 "$(bash_p "rm $VD/q1/judge.md")"
row "rm -r verdicts" 2 0 "$(bash_p "rm -rf $VD")"
row "mv verdict away" 2 0 "$(bash_p "mv $VD/q1/judge.md /tmp/x")"
row "sed -i verdict" 2 0 "$(bash_p "sed -i s/NO-GO/GO/ $VD/q1/judge.md")"  # gnu-ok: fixture text, never executed
row "ln into verdicts" 2 0 "$(bash_p "ln -s /tmp/x $VD/q1/judge.md")"
row "dd of= verdict" 2 0 "$(bash_p "dd if=/tmp/x of=$VD/q1/judge.md")"
row "truncate verdict" 2 0 "$(bash_p "truncate -s0 $VD/q1/judge.md")"
row "sudo wrapped rm" 2 0 "$(bash_p "sudo rm $VD/q1/judge.md")"
row "redirect via symlinked dir" 2 0 "$(bash_p "echo x > $TMP/vd-link/q1/judge.md")"
row "interpreter writes verdict" 2 0 "$(bash_p "python3 -c \"open('$VD/q1/judge.md','w').write('GO')\"")"
row "bash -c redirect into verdict" 2 0 "$(bash_p "bash -c 'echo GO > $VD/q1/judge.md'")"
row "eval redirect into verdict" 2 0 "$(bash_p "eval 'echo GO > $VD/q1/judge.md'")"
row "env-wrapped cp into verdict" 2 0 "$(bash_p "env 'FOO=a b'c cp /tmp/x $VD/q1/judge.md")"
row "timeout -s KILL cp into verdict" 2 0 "$(bash_p "timeout -s KILL '5' cp /tmp/x $VD/q1/judge.md")"

# ---- 3. allow paths: every session ----
row "write-verdict.sh relative" 0 0 "$(bash_p "bash scripts/handover/console-kit/write-verdict.sh q1 GO $SHA --evidence-file /tmp/claude-1000/s/e.md")"
row "write-verdict.sh absolute" 0 0 "$(bash_p "bash $REPO/scripts/handover/console-kit/write-verdict.sh q1 NO-GO $SHA --evidence-file /tmp/claude-1000/s/e.md --judge j2")"
row "go.sh absolute" 0 0 "$(bash_p "bash $REPO/scripts/handover/console-kit/go.sh 123 $SHA --trust-reviewed q1")"
row "go.sh relative" 0 0 "$(bash_p "bash scripts/handover/console-kit/go.sh 123 $SHA")"
row "merge-on-green" 0 0 "$(bash_p "bash $REPO/scripts/handover/merge-on-green.sh --jira-transition")"
row "Read verdict" 0 0 "$(file_p Read "$VD/q1/judge.md")"
row "Grep verdicts" 0 0 "$(grep_p "$VD")"
row "cat verdict" 0 0 "$(bash_p "cat $VD/q1/judge.md")"
row "cat verdict 2>/dev/null" 0 0 "$(bash_p "cat $VD/q1/judge.md 2>/dev/null")"
row "ls verdicts" 0 0 "$(bash_p "ls -la $VD/q1")"
row "grep -rn verdicts" 0 0 "$(bash_p "grep -rn GO $VD")"
row "cp verdict out" 0 0 "$(bash_p "cp $VD/q1/judge.md /tmp/x")"
row "bash -c read of a verdict" 0 0 "$(bash_p "bash -c 'cat $VD/q1/judge.md'")"
row "nested sh -c grep of verdicts" 0 0 "$(bash_p "sh -c \"bash -c 'grep -rn GO $VD'\"")"
row "timeout-wrapped cp verdict out" 0 0 "$(bash_p "timeout -s KILL 5 cp $VD/q1/judge.md /tmp/x")"  # gnu-ok: fixture text, never executed
row "Write judge cache scratch" 0 0 "$(file_p Write "$H/.cache/himmel/verdicts/q1/scratch/e.md")"
row "redirect into judge cache" 0 0 "$(bash_p "echo x > $H/.cache/himmel/verdicts/q1/scratch/e.md")"
row "Write a handover doc" 0 0 "$(file_p Write "$ROOT/u/himmel/HIMMEL-1-doc.md")"
row "Write verdicts.json in a repo" 0 0 "$(file_p Write "$REPO/scripts/verdicts.json")"
row "grep for the key name" 0 0 "$(bash_p 'git grep -n go-hmac -- scripts')"
row "commit message by file" 0 0 "$(bash_p 'git commit -F /tmp/msg')"
row "cat the env beside the key" 0 0 "$(bash_p 'cat ~/.config/himmel/env')"
row "Read the env beside the key" 0 0 "$(file_p Read "$KEYDIR/env")"
row "ls ~/.config" 0 0 "$(bash_p 'ls ~/.config')"
row "cp the env out" 0 0 "$(bash_p 'cp ~/.config/himmel/env /tmp/x')"
row "glob elsewhere" 0 0 "$(bash_p 'ls /tmp/*.md')"
row "Write in worktree" 0 0 "$(file_p Write "$REPO/scripts/x.sh")"
row "git status" 0 0 "$(bash_p 'git status --short')"

# ---- 3b. round-1 panel: >& file, cd-relative targets, split eval ----
row ">& file into a verdict" 2 0 "$(bash_p "echo GO >& $VD/q1/judge.md")"
row ">&2 stays an fd dup" 0 0 "$(bash_p 'echo hi >&2')"
row "cd into verdicts then relative write" 2 0 "$(bash_p "cd $VD/q1 && echo GO > judge.md")"
row "pushd into verdicts then relative touch" 2 0 "$(bash_p "pushd $VD && touch q1/judge.md")"
row "cd into a dynamic verdicts path then write" 2 0 "$(bash_p 'cd "$D/verdicts" && echo GO > judge.md')"
row "cd elsewhere then relative write" 0 0 "$(bash_p 'cd /tmp && echo x > out.txt')"
row "eval args joined into a verdict write" 2 0 "$(bash_p "eval 'echo GO >' '$VD/q1/judge.md'")"
row "eval of a harmless split command" 0 0 "$(bash_p "eval 'echo' 'hi'")"
row "cd to ~/.config then copy himmel/" 2 2 "$(bash_p "cd $H/.config && cp -r himmel /tmp/x")"
row "cd into a dynamic himmel path then read the key" 2 2 "$(bash_p 'cd "$D/.config/himmel" && cat go-hmac.key')"

# ---- 3c. round-2 panel: .. after a symlink, glob write targets, removing the key's parents ----
row "cat key via symlink then .." 2 2 "$(bash_p "cat $TMP/keysub-link/../go-hmac.key")"
row "Read key via symlink then .." 2 2 "$(file_p Read "$TMP/keysub-link/../go-hmac.key")"
row "cat the env via symlink then .." 0 0 "$(bash_p "cat $TMP/keysub-link/../env")"
row "redirect into a verdict via symlink then .." 2 0 "$(bash_p "echo GO > $TMP/vsub-link/../judge.md")"
row "redirect into a ? glob of verdicts" 2 0 "$(bash_p "echo GO > $ROOT/u/himmel/verdict?/q1/judge.md")"
row "tee into a * glob of verdicts" 2 0 "$(bash_p "printf GO | tee $ROOT/u/*/verdicts/q1/judge.md")"
row "glob write target elsewhere" 0 0 "$(bash_p "echo x > $TMP/wor?/out.txt")"
row "rm -rf ~/.config" 2 2 "$(bash_p 'rm -rf ~/.config')"
row "mv ~/.config away" 2 2 "$(bash_p 'mv ~/.config /tmp/c')"
row "chmod -R the home dir" 2 2 "$(bash_p "chmod -R 777 $H")"
row "rm -rf relative .config from home" 2 2 "$(bash_p 'rm -rf .config' "$H")"
row "rm -rf a sibling under ~/.config" 0 0 "$(bash_p 'rm -rf ~/.config/other')"
row "rm -rf a build dir" 0 0 "$(bash_p "rm -rf $TMP/work/build")"

# ---- 3d. round-3 panel: walkers over the key's parents, verdicts' parents, heredoc bodies ----
row "cp -r the home dir" 2 2 "$(bash_p "cp -r $H /tmp/backup")"
row "grep -r over \$HOME" 2 2 "$(bash_p 'grep -r PATTERN "$HOME"')"
row "rg over ~" 2 2 "$(bash_p 'rg PATTERN ~')"
row "find over ~ with -exec" 2 2 "$(bash_p 'find ~ -name "*.key" -exec cat {} +')"
row "find over ~ listing names" 0 0 "$(bash_p 'find ~ -name "*.md"')"
row "du over ~" 0 0 "$(bash_p 'du -sh ~')"
row "rm -rf a bucket holding verdicts" 2 0 "$(bash_p "rm -rf $ROOT/u/himmel")"
row "rm -rf the handover root" 2 0 "$(bash_p "rm -rf $ROOT")"
row "mv a user dir holding verdicts" 2 0 "$(bash_p "mv $ROOT/u /tmp/u")"
row "mv a file into the bucket" 0 0 "$(bash_p "mv /tmp/x.md $ROOT/u/himmel")"
row "mv -t moves a bucket out" 2 0 "$(bash_p "mv -t /opt $ROOT/u/himmel")"
row "mv -vt moves a bucket out" 2 0 "$(bash_p "mv -vt /opt $ROOT/u/himmel")"
row "mv --target-directory= moves a bucket out" 2 0 "$(bash_p "mv --target-directory=/opt $ROOT/u/himmel")"
row "mv with a trailing option moves a bucket out" 2 0 "$(bash_p "mv $ROOT/u/himmel /opt -v")"
row "mv -t into the bucket" 0 0 "$(bash_p "mv -t $ROOT/u/himmel /tmp/x.md")"
row "mv -t/opt attached moves a bucket out" 2 0 "$(bash_p "mv -t/opt $ROOT/u/himmel")"
row "mv -vt/opt attached moves a bucket out" 2 0 "$(bash_p "mv -vt/opt $ROOT/u/himmel")"
row "mv -St suffix does not hide a source" 2 0 "$(bash_p "mv -St $ROOT/u/himmel /opt")"
row "mv -t attached into verdict dir" 2 0 "$(bash_p "mv -t$VD/q1 /tmp/x")"
row "mv --target-directory= into verdict dir" 2 0 "$(bash_p "mv --target-directory=$VD/q1 /tmp/x")"
row "cp -t attached into verdict dir" 2 0 "$(bash_p "cp -t$VD/q1 /tmp/x")"
row "cp -vt into verdict dir" 2 0 "$(bash_p "cp -vt $VD/q1 /tmp/x")"
row "install -vt attached into verdict dir" 2 0 "$(bash_p "install -vt$VD/q1 /tmp/x")"
row "ln -st into verdict dir" 2 0 "$(bash_p "ln -st $VD/q1 /tmp/x")"
row "cp -vt out of the bucket" 0 0 "$(bash_p "cp -vt /opt $ROOT/u/himmel/notes.md")"
row "rm a handover doc" 0 0 "$(bash_p "rm $ROOT/u/himmel/HIMMEL-1-doc.md")"
row "heredoc body \$( ) reads the key" 2 2 "$(bash_p "cat <<EOF
\$(cat $TMP/alias)
EOF")"
row "heredoc body \$( ) writes a verdict" 2 0 "$(bash_p "cat <<EOF
\$(echo GO > $VD/q1/judge.md)
EOF")"
row "heredoc body backticks write a verdict" 2 0 "$(bash_p "cat <<EOF
\`echo GO > $VD/q1/judge.md\`
EOF")"
row "heredoc body with a harmless \$( )" 0 0 "$(bash_p "cat <<EOF
built \$(date +%F)
EOF")"

# ---- 4. fail closed ----
row "malformed JSON" 2 2 'not json'
row "non-object payload" 2 2 '[1]'
row "file_path not a string" 2 2 '{"tool_name":"Write","tool_input":{"file_path":7}}'

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
