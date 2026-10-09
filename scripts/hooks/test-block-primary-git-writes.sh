#!/usr/bin/env bash
# Unit test for the HIMMEL-3401 arm of scripts/hooks/block-write-into-main-checkout.sh:
# a git command that rewrites the PRIMARY checkout's working tree, index,
# HEAD, refs or config — aimed at it via -C, --git-dir/--work-tree,
# GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE env, or a `cd` earlier in the command —
# is denied; read-only git and the console's wrap-flow `pull --ff-only` /
# `fetch` on the primary keep working. Platform guard: Git Bash on Windows /
# any POSIX bash 3.2+.
#
# Every row runs BOTH entry modes (direct-exec = the Claude Bash chain;
# sourced = the codex lane via block-terminal-write-fence.sh). Fixtures live
# under the REAL $HOME, never /tmp (is_temp_or_devnull exempts /tmp paths, so
# a /tmp fixture would make every DENY row pass as ALLOW for the wrong
# reason — see test-block-write-into-main-checkout.sh's FIXTURE RULE). The
# primary here is a FIXTURE; nothing in this suite touches the real checkout.
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
DIRECT="$HOOKS/block-write-into-main-checkout.sh"
FENCE="$HOOKS/block-terminal-write-fence.sh"
[ -f "$DIRECT" ] || { echo "guard not found: $DIRECT" >&2; exit 1; }
[ -f "$FENCE" ]  || { echo "guard not found: $FENCE" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not on PATH"; exit 0; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

FIX=$(mktemp -d "${HOME}/.himmel-3401-gitfix-XXXXXX") || exit 1
trap 'rm -rf "$FIX"' EXIT

export HOME="$FIX/home"
mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
git config --global user.email t@example.invalid
git config --global user.name t
unset EDIT_ON_MAIN_OK CODEX_EXTERNAL_WRITES_OK GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE 2>/dev/null || true

mkrepo() {  # mkrepo <dir> <branch>
    git init -q -b "$2" "$1" >/dev/null 2>&1
    mkdir -p "$1/handovers" "$1/ignored"
    printf 'ignored/\n' > "$1/.gitignore"
    : > "$1/README.md"
    git -C "$1" add README.md .gitignore >/dev/null 2>&1
    git -C "$1" commit -q -m init >/dev/null 2>&1
}

P="$FIX/primary"                 # the PRIMARY checkout, on main
mkrepo "$P" main
W="$FIX/wt"                      # a leg's linked worktree off it
git -C "$P" worktree add -q -b feat/x "$W" >/dev/null 2>&1
mkdir -p "$W/sub"
S="$FIX/swrepo"                  # a single-writer repo on main
mkrepo "$S" main
touch "$S/.single-writer"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

payload() { jq -nc --arg c "$1" --arg d "$2" '{tool_name:"Bash",tool_input:{command:$c,cwd:$d}}'; }

_rc() {  # _rc <script> <json> -> allow|block|?(rc=N)
    local rc=0
    printf '%s' "$2" | bash "$1" >/dev/null 2>&1 || rc=$?
    case "$rc" in 0) echo allow ;; 2) echo block ;; *) echo "?(rc=$rc)" ;; esac
}

# deny <label> <cwd> <command> — both modes block, and the deny names the
# git arm (a deny from some OTHER arm would be coverage by accident).
deny() {
    local label="$1" j s got err
    j=$(payload "$3" "$2")
    for s in "$DIRECT" "$FENCE"; do
        got=$(_rc "$s" "$j")
        if [ "$got" != block ]; then bad "$label [${s##*/}] — expected block got $got"; continue; fi
        err=$({ printf '%s' "$j" | bash "$s" >/dev/null; } 2>&1)
        case "$err" in
            *"git subcommand:"*) ok "$label [${s##*/}]" ;;
            *) bad "$label [${s##*/}] — denied, but not by the git arm: $(printf '%s' "$err" | head -2 | tr '\n' '|')" ;;
        esac
    done
}

# deny_any <label> <cwd> <command> — both modes block, by any arm. For shapes
# an older arm or the codex fence already owns in one mode (sourced-lane
# `commit` keeps HIMMEL-745's is_on_main message; the fence denies remote
# URL rewrites before it sources this hook).
deny_any() {
    local label="$1" j s got
    j=$(payload "$3" "$2")
    for s in "$DIRECT" "$FENCE"; do
        got=$(_rc "$s" "$j")
        if [ "$got" = block ]; then ok "$label [${s##*/}]"; else bad "$label [${s##*/}] — expected block got $got"; fi
    done
}

# allow <label> <cwd> <command> — both modes allow.
allow() {
    local label="$1" j s got
    j=$(payload "$3" "$2")
    for s in "$DIRECT" "$FENCE"; do
        got=$(_rc "$s" "$j")
        if [ "$got" = allow ]; then ok "$label [${s##*/}]"; else bad "$label [${s##*/}] — expected allow got $got"; fi
    done
}

# deny_direct / allow_direct <label> <cwd> <command> — direct-exec mode only,
# for `git push`: the codex fence refuses every push (external-write class,
# HIMMEL-745) before it sources this hook, so only the Claude lane decides.
deny_direct() {
    local j got err
    j=$(payload "$3" "$2")
    got=$(_rc "$DIRECT" "$j")
    if [ "$got" != block ]; then bad "$1 [direct] — expected block got $got"; return; fi
    err=$({ printf '%s' "$j" | bash "$DIRECT" >/dev/null; } 2>&1)
    case "$err" in
        *"git subcommand:"*) ok "$1 [direct]" ;;
        *) bad "$1 [direct] — denied, but not by the git arm: $(printf '%s' "$err" | head -2 | tr '\n' '|')" ;;
    esac
}
allow_direct() {
    local got
    got=$(_rc "$DIRECT" "$(payload "$3" "$2")")
    if [ "$got" = allow ]; then ok "$1 [direct]"; else bad "$1 [direct] — expected allow got $got"; fi
}

echo "== DENY: the ticket's shapes, from a leg worktree cwd =="
deny "checkout <leg-branch> -- <file>"      "$W" "git -C $P checkout feat/x -- README.md"
deny "restore --source"                     "$W" "git -C $P restore --source=HEAD~1 README.md"
deny "checkout <sha>"                       "$W" "git -C $P checkout 0123abc"
deny "merge <leg>"                          "$W" "git -C $P merge feat/x"
deny "pull . <leg>"                         "$W" "git -C $P pull . feat/x"
deny "read-tree -u -m"                      "$W" "git -C $P read-tree -u -m HEAD"
deny "--git-dir/--work-tree = primary"      "$W" "git --git-dir=$P/.git --work-tree=$P checkout feat/x -- README.md"
deny "--work-tree = primary (repo = leg)"   "$W" "git --work-tree=$P checkout feat/x -- README.md"
deny "--work-tree <p> two-token form"       "$W" "git --work-tree $P checkout feat/x -- README.md"
deny "cd <primary> && git checkout <sha>"   "$W" "cd $P && git checkout 0123abc"

echo "== DENY: substitution + compound-keyword forms =="
deny "backtick substitution"               "$W" "echo \`git -C $P checkout feat/x -- README.md\`"
deny "\$( ) substitution"                   "$W" "echo \$(git -C $P merge feat/x)"
deny "if cd <primary>; then git merge; fi"  "$W" "if cd $P; then git merge feat/x; fi"
# `merge` (a write subcommand) exercises the `builtin cd` prefix strip; the
# `reset` write form is covered in the write-set loop below.
deny "builtin cd <primary>; git merge"      "$W" "builtin cd $P; git merge feat/x"

echo "== DENY: the rest of the write set =="
for sub in "switch feat/x" "reset --hard HEAD~1" "rebase feat/x" "cherry-pick feat/x" \
           "revert HEAD" "am x.patch" "apply x.patch" "clean -fdx" "stash" "stash pop" \
           "stash apply" "stash push -m x" "rm README.md" "mv README.md y" "add README.md" \
           "update-ref refs/heads/main feat/x" "symbolic-ref HEAD refs/heads/feat/x" \
           "checkout-index -a -f" "update-index --assume-unchanged README.md" \
           "bisect start" "submodule update" "sparse-checkout set x" "replace HEAD feat/x" \
           "notes add -m x" "co feat/x"; do
    deny "git -C <primary> $sub" "$W" "git -C $P $sub"
done

deny_any "git -C <primary> commit -m x"   "$W" "git -C $P commit -m x"

echo "== DENY: ref/config writes that would poison the console's own pull =="
deny "branch --set-upstream-to"             "$W" "git -C $P branch --set-upstream-to=origin/feat/x main"
deny "branch -u"                            "$W" "git -C $P branch -u origin/feat/x"
deny "branch -f"                            "$W" "git -C $P branch -f other feat/x"
deny "config <key> <value>"                 "$W" "git -C $P config core.fsmonitor x"
deny "config --unset"                       "$W" "git -C $P config --unset branch.main.remote"
deny "config set (new syntax)"              "$W" "git -C $P config set core.hooksPath x"
deny "remote add"                           "$W" "git -C $P remote add evil $W"
deny_any "remote set-url"                     "$W" "git -C $P remote set-url origin $W"

echo "== DENY: the carve-outs are shape-bounded =="
deny "pull --ff-only . <leg>"               "$W" "git -C $P pull --ff-only . feat/x"
deny "pull --ff-only origin <leg-branch>"   "$W" "git -C $P pull --ff-only origin feat/x"
deny "pull --ff-only <path> main"           "$W" "git -C $P pull --ff-only $W main"
deny "pull --ff-only <url> main"            "$W" "git -C $P pull --ff-only https://example.invalid/r.git main"
deny "pull (no --ff-only)"                  "$W" "git -C $P pull"
deny "pull --rebase"                        "$W" "git -C $P pull --rebase"
deny "pull --ff-only --rebase"              "$W" "git -C $P pull --ff-only --rebase"
deny "pull --ff-only --autostash"           "$W" "git -C $P pull --ff-only --autostash"
deny "fetch --update-head-ok"               "$W" "git -C $P fetch --update-head-ok origin main:main"
deny "fetch -u"                             "$W" "git -C $P fetch -u origin main:main"
deny "fetch . <leg>:main"                   "$W" "git -C $P fetch . feat/x:main"
deny "fetch <path>"                         "$W" "git -C $P fetch $W"
deny "fetch <remote> <src>:<dst>"           "$W" "git -C $P fetch origin feat/x:refs/remotes/origin/main"
deny "fetch --refmap"                       "$W" "git -C $P fetch origin --refmap=refs/heads/feat/x:refs/remotes/origin/main"
deny "fetch --refm= abbreviation"           "$W" "git -C $P fetch origin --refm=refs/heads/feat/x:refs/remotes/origin/main"
deny "fetch --update-h abbreviation"        "$W" "git -C $P fetch --update-h origin"
deny "fetch --upload-p= abbreviation"       "$W" "git -C $P fetch --upload-p=x origin"

echo "== DENY: the path-exemption holes (verdict on the REPO ROOT, not the -C dir) =="
deny "-C <primary>/handovers checkout"      "$W" "git -C $P/handovers checkout feat/x -- README.md"
deny "-C <primary>/ignored checkout"        "$W" "git -C $P/ignored checkout feat/x -- README.md"
deny_any "-C <primary>/handovers commit"      "$W" "git -C $P/handovers commit -m x"
deny "--git-dir=<primary>/.git alone"      "$W" "git --git-dir=$P/.git checkout 0123abc"

echo "== DENY: env and cd forms =="
deny "GIT_WORK_TREE= prefix"                "$W" "GIT_WORK_TREE=$P git checkout feat/x -- README.md"
deny "GIT_DIR= prefix"                      "$W" "GIT_DIR=$P/.git git reset --hard"
deny "env GIT_DIR="                         "$W" "env GIT_DIR=$P/.git git switch -c y"
deny "env -C <primary>"                     "$W" "env -C $P git checkout 0123abc"
deny "export leg GIT_DIR; env -u GIT_DIR"   "$W" "export GIT_DIR=$W/.git; env -u GIT_DIR git -C $P merge feat/x"
deny "export leg GIT_DIR; env -uGIT_DIR"    "$W" "export GIT_DIR=$W/.git; env -uGIT_DIR git -C $P merge feat/x"
deny "export leg GIT_DIR; env --unset="     "$W" "export GIT_DIR=$W/.git; env --unset=GIT_DIR git -C $P merge feat/x"
deny "export leg GIT_DIR; env -i"           "$W" "export GIT_DIR=$W/.git; env -i git -C $P merge feat/x"
deny "export leg GIT_DIR; env -"            "$W" "export GIT_DIR=$W/.git; env - git -C $P merge feat/x"
deny "env -iC<primary> attached"            "$W" "env -iC$P git merge feat/x"
deny "env -a name git (argv0 operand)"      "$W" "env -a foo git -C $P merge feat/x"
deny_any "env -S 'git …' split string"      "$W" "env -S 'git -C $P merge feat/x'"
allow "env -u GIT_DIR git in the leg"       "$W" "env -u GIT_DIR git -C $W merge feat/x"

# A config override can repoint the remote or refspec pull/fetch act on, so
# it voids their carve-out (HIMMEL-3401 panel round 2).
deny "-c remote url + pull --ff-only"       "$W" "git -C $P -c remote.origin.url=$W pull --ff-only"
deny "-c attached + fetch"                  "$W" "git -C $P -cremote.origin.fetch=+refs/heads/*:refs/heads/* fetch origin"
deny "--config-env + pull --ff-only"        "$W" "git -C $P --config-env=remote.origin.url=X pull --ff-only"
deny "--config-env spaced + fetch"          "$W" "git -C $P --config-env remote.origin.url=X fetch"
deny "GIT_CONFIG_PARAMETERS= + pull"        "$W" "GIT_CONFIG_PARAMETERS=x git -C $P pull --ff-only"
deny "env GIT_CONFIG_COUNT= + fetch"        "$W" "env GIT_CONFIG_COUNT=1 git -C $P fetch origin"
deny "export GIT_CONFIG_GLOBAL; pull"       "$W" "export GIT_CONFIG_GLOBAL=$W/cfg; git -C $P pull --ff-only"
allow "env -i clears GIT_CONFIG*; pull"     "$W" "export GIT_CONFIG_GLOBAL=$W/cfg; env -i git -C $P pull --ff-only"
allow "-c on a read subcommand"             "$W" "git -C $P -c color.ui=never log -1"

# Short-option clusters carry the write flags the exact matches miss.
deny "branch -uorigin/x attached"           "$W" "git -C $P branch -uorigin/feat/x main"
deny "branch -vf cluster"                   "$W" "git -C $P branch -vf main feat/x"
deny "fetch -qu cluster"                    "$W" "git -C $P fetch -qu origin main"
deny "config -le cluster"                   "$W" "git -C $P config -le"
deny "symbolic-ref -qd cluster"             "$W" "git -C $P symbolic-ref -qd HEAD"
deny "branch -D old"                        "$W" "git -C $P branch -D old"
deny "branch -d old"                        "$W" "git -C $P branch -d old"
deny "branch --delete old"                  "$W" "git -C $P branch --delete old"
deny "branch -qD cluster"                   "$W" "git -C $P branch -qD old"
deny "branch -r -d origin/x"                "$W" "git -C $P branch -r -d origin/feat/x"
deny "branch <new>"                         "$W" "git -C $P branch newbr"
deny "branch <new> <start>"                 "$W" "git -C $P branch newbr feat/x"
allow "branch -vv"                          "$W" "git -C $P branch -vv"
allow "branch --list 'feat/*'"              "$W" "git -C $P branch --list feat/x"
allow "branch -l pattern"                   "$W" "git -C $P branch -l feat/x"
allow "branch --contains <sha>"             "$W" "git -C $P branch --contains 0123abc"
allow "branch --merged main"                "$W" "git -C $P branch --merged main"
allow "branch -r"                           "$W" "git -C $P branch -r"
allow "fetch -q origin"                     "$W" "git -C $P fetch -q origin"
allow "config -l"                           "$W" "git -C $P config -l"
allow "symbolic-ref -q HEAD"                "$W" "git -C $P symbolic-ref -q HEAD"
deny "GIT_INDEX_FILE= into the primary"     "$W" "GIT_INDEX_FILE=$P/.git/index git read-tree HEAD"
deny "export GIT_WORK_TREE; git …"          "$W" "export GIT_WORK_TREE=$P; git checkout feat/x -- README.md"
deny "pushd <primary> && git …"             "$W" "pushd $P && git checkout 0123abc"
deny "(cd <primary>; git …) subshell"       "$W" "(cd $P; git checkout 0123abc)"
deny "relative cd ../primary"               "$W" "cd ../primary && git merge feat/x"
deny "cd <dynamic> && git checkout"         "$W" "cd \"\$X\" && git checkout 0123abc"
deny "cd - && git checkout"                 "$W" "cd - && git checkout 0123abc"
deny "cwd = primary, git merge"             "$P" "git merge feat/x"
deny "/usr/bin/git path form"               "$W" "/usr/bin/git -C $P checkout 0123abc"
deny "git -c k=v -C <primary> checkout"     "$W" "git -c advice.detachedHead=false -C $P checkout 0123abc"
deny "second clause, after a read"          "$W" "git -C $P status; git -C $P checkout 0123abc"

echo "== DENY: push INTO the primary (adversarial review C1) =="
deny_direct "push --receive-pack updateInstead" "$W" "git push --receive-pack='git -c receive.denyCurrentBranch=updateInstead receive-pack' $P feat/x:main"
deny_direct "push --receive-pack <v> (split)" "$W" "git push --receive-pack x origin feat/x"
deny_direct "push --receive-pack=… to a remote" "$W" "git push --receive-pack=x origin feat/x"
deny_direct "push origin --receive-pack after the destination" "$W" "git push origin --receive-pack=x feat/x"
deny_direct "push origin feat/x --exec at the end" "$W" "git push origin feat/x --exec=x"
deny_direct "push -- <primary>"             "$W" "git push -- $P feat/x:main"
deny_direct "push --receive-p= abbreviation" "$W" "git push --receive-p=x origin feat/x"
deny_direct "push --ex abbreviation"         "$W" "git push --ex=x origin feat/x"
deny_direct "push --rep=<primary> abbreviation" "$W" "git push --rep=$P feat/x:main"
deny_direct "push --rep <primary> abbreviation" "$W" "git push --rep $P feat/x:main"
deny_direct "push --exec"                   "$W" "git push --exec=x origin feat/x"
deny_direct "push <primary path>"           "$W" "git push $P feat/x:main"
deny_direct "push <primary>/.git"           "$W" "git push $P/.git feat/x:main"
deny_direct "push file://<primary>"         "$W" "git push file://$P feat/x:main"
deny_direct "push ../primary (relative)"    "$W" "git push ../primary feat/x:main"
deny_direct "push --repo=<primary>"         "$W" "git push --repo=$P feat/x:main"
deny_direct "push --repo <primary>"         "$W" "git push --repo $P feat/x:main"
deny_direct "push . from the primary"       "$W" "git -C $P push . feat/x:main"
allow_direct "push (configured upstream)"   "$W" "git push"
allow_direct "push -u origin feat/x"        "$W" "git push -u origin feat/x"
allow_direct "push --force-with-lease origin" "$W" "git push --force-with-lease origin feat/x"
allow_direct "push https URL"               "$W" "git push https://example.invalid/r.git feat/x"
allow_direct "push scp-like URL"            "$W" "git push git@example.invalid:r.git feat/x"
allow_direct "push -o ci.skip origin"       "$W" "git push -o ci.skip origin feat/x"
allow_direct "push --recurse-submodules=check origin" "$W" "git push --recurse-submodules=check origin feat/x"
allow_direct "push --push-option=x origin"  "$W" "git push --push-option=x origin feat/x"
allow_direct "push <single-writer path>"    "$W" "git push $S feat/x"
allow_direct "git -C <primary> push origin main" "$W" "git -C $P push origin main"

echo "== DENY: config-repointed remotes (AB delta review C1-a) =="
deny_direct "push -c remote.x.url + receivepack" "$W" "git -c remote.x.url=$P -c remote.x.receivepack='git -c receive.denyCurrentBranch=updateInstead receive-pack' push x feat/x:main"
deny_direct "push -c remote.x.pushurl"      "$W" "git -c remote.x.pushurl=$P push x feat/x:main"
deny_direct "push -c url.<primary>.insteadOf" "$W" "git -c url.$P.insteadOf=fake: push fake:r feat/x:main"
deny_direct "push -c URL.<p>.PushInsteadOf (case)" "$W" "git -c URL.$P.PushInsteadOf=fake: push fake:r feat/x:main"
deny_direct "push --config-env=remote.x.url" "$W" "git --config-env=remote.x.url=PV push x feat/x:main"
deny_direct "push --config-env remote.x.url" "$W" "git --config-env remote.x.url=PV push x feat/x:main"
deny_direct "push -c core.sshCommand"       "$W" "git -c core.sshCommand=x push origin feat/x"
deny_direct "push -c protocol.file.allow"   "$W" "git -c protocol.file.allow=always push origin feat/x"
deny_direct "push GIT_CONFIG_COUNT prefix"  "$W" "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.x.url GIT_CONFIG_VALUE_0=$P git push x feat/x:main"
deny_direct "push env GIT_CONFIG_PARAMETERS" "$W" "env GIT_CONFIG_PARAMETERS=\"'remote.x.url'='$P'\" git push x feat/x:main"
deny_direct "export GIT_CONFIG_KEY_0; push" "$W" "export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.x.url GIT_CONFIG_VALUE_0=$P; git push x feat/x:main"
deny_direct "remote add + push, one command" "$W" "git remote add x $P && git push x feat/x:main"
deny_direct "remote set-url + push"         "$W" "git remote set-url origin $P; git push origin feat/x:main"
deny_direct "push, then remote add (order-free)" "$W" "git push x feat/x:main || git remote add x $P"
deny "fetch -c remote.x.uploadpack"         "$W" "git -c remote.x.uploadpack=x fetch x"
deny "pull -c remote.x.url"                 "$W" "git -c remote.x.url=$P pull x"
deny "ls-remote -c remote.x.url"            "$W" "git -c remote.x.url=$P ls-remote x"
deny_direct "remote update -c url.insteadOf" "$W" "git -c url.$P.insteadOf=fake: remote update"
allow_direct "push -c advice.*=false origin" "$W" "git -c advice.pushUpdateRejected=false push origin feat/x"
# "remote add alone" used to be allow_direct here (this row only ever
# validated that the C1-a repoint+netop COMBO doesn't fire without a paired
# push — it never claimed the sourced/fence lane's own, unrelated verdict).
# HIMMEL-3407 now denies it too: adding ANY remote, even a harmless new name,
# still writes the leg worktree's SHARED $GIT_COMMON_DIR/config, and the
# existing -C <primary> rows already deny `remote add` unconditionally — the
# implicit-cwd form should not be a back door to the same write.
deny_direct "remote add alone"              "$W" "git remote add up https://example.invalid/r.git"
allow "remote -v"                           "$W" "git remote -v"
allow "fetch -c advice.*=false origin"      "$W" "git -c advice.detachedHead=false fetch origin"

echo "== DENY: ANSI-C / locale quoting of the verb (AB delta review C2-a) =="
deny "\$'git' -C <primary> checkout"        "$W" "\$'git' -C $P checkout feat/x -- README.md"
deny "\$\"git\" -C <primary> checkout"      "$W" "\$\"git\" -C $P checkout feat/x -- README.md"
deny "\$'\\x67it' hex escape"               "$W" "\$'\\x67it' -C $P checkout feat/x -- README.md"
deny "\$'\\147it' octal escape"             "$W" "\$'\\147it' -C $P checkout feat/x -- README.md"
deny "\$'\\u0067it' unicode escape"         "$W" "\$'\\u0067it' -C $P checkout feat/x -- README.md"
deny "git \$'-C' <primary> checkout"        "$W" "git \$'-C' $P checkout feat/x -- README.md"
allow "\$'git' -C <primary> status"         "$W" "\$'git' -C $P status"

echo "== DENY: backslash-escaped spellings (adversarial review C2) =="
deny "\\git -C <primary> checkout"          "$W" "\\git -C $P checkout feat/x -- README.md"
deny "gi\\t -C <primary> checkout"          "$W" "gi\\t -C $P checkout feat/x -- README.md"
deny "git \\<newline>-C <primary>"          "$W" "git \\"$'\n'"-C $P checkout feat/x -- README.md"
deny "git \\-C <primary> checkout"          "$W" "git \\-C $P checkout feat/x -- README.md"
deny "git -C <primary> check\\out"          "$W" "git -C $P check\\out feat/x -- README.md"
allow "git -C <primary> st\\atus"           "$W" "git -C $P st\\atus"

echo "== ALLOW: the console's wrap-flow carve-out on the primary =="
allow "pull --ff-only"                      "$P" "git -C $P pull --ff-only"
allow "pull --ff-only origin"               "$W" "git -C $P pull --ff-only origin"
allow "pull --ff-only origin main"          "$W" "git -C $P pull --ff-only origin main"
allow "pull -q --ff-only --prune"           "$P" "git pull -q --ff-only --prune"
allow "fetch"                               "$P" "git -C $P fetch"
allow "fetch origin"                        "$W" "git -C $P fetch origin"
allow "fetch --prune origin"                "$P" "git fetch --prune origin"
allow "fetch origin pull/1/head"            "$P" "git fetch origin pull/1/head"
allow "fetch --all --tags"                  "$P" "git fetch --all --tags"

echo "== ALLOW: read-only git on the primary =="
for sub in "status" "status --porcelain" "log --oneline -3" "diff origin/main...HEAD" "show HEAD:README.md" \
           "rev-parse HEAD" "rev-parse --abbrev-ref HEAD" "ls-files" "merge-base --is-ancestor a b" \
           "cat-file -p HEAD" "for-each-ref" "branch --show-current" "branch -a" \
           "remote -v" "remote get-url origin" "config --get remote.origin.url" "config user.name" \
           "config -l" "config get user.name" "stash list" "stash show" "worktree list" \
           "worktree add $FIX/w2 -b w2" "worktree remove $W" "worktree prune" \
           "symbolic-ref --short HEAD" "tag" "describe --tags" "reflog -5" "blame README.md" \
           "grep x" "ls-remote origin" "gc" "--version" "--no-pager log -1"; do
    allow "git -C <primary> $sub" "$W" "git -C $P $sub"
done
allow "cd <primary> && git status"          "$W" "cd $P && git status"
allow "cd <primary> && git log"             "$W" "cd $P && git log -1"
allow "cd <primary> && git -C <wt> checkout" "$W" "cd $P && git -C $W checkout feat/x -- README.md"

echo "== ALLOW: leg-local git is unaffected =="
# "config core.x y" used to be ALLOW here; HIMMEL-3407 moved it to the DENY
# section below (an ordinary `git config` from a leg worktree always writes
# the shared config anyway — accepted cost, named in the ticket's proposed fix).
for sub in "checkout feat/x -- README.md" "reset --hard HEAD" "merge main" "stash pop" "commit -m x" \
           "restore README.md" "rebase main" "pull --rebase" "co x"; do
    allow "git $sub (cwd = leg worktree)" "$W" "git $sub"
done
allow "git -C <wt> checkout (cwd = primary)" "$P" "git -C $W checkout feat/x -- README.md"
# A cd may not have run, so a write is also checked from the cwd it left: the
# primary here (panel round 3). Deliberate over-deny, named in the hook.
deny "cd <wt>/sub && git checkout (cwd = primary)" "$P" "cd $W/sub && git checkout feat/x -- README.md"
deny "false && cd <leg>; git merge"         "$P" "false && cd $W; git merge feat/x"
deny "cd <leg>; cd <leg>/sub; git merge"    "$P" "cd $W; cd sub; git merge feat/x"
allow "cd <leg>/sub && git merge (cwd = leg)" "$W" "cd $W/sub && git merge feat/x"
allow "cd <primary>; cd <leg>; git status"  "$W" "cd $P; cd $W; git status"

# Ref-writing subcommands that used to sit on the read list (panel round 3).
deny "reflog delete on the primary"         "$W" "git -C $P reflog delete refs/heads/main@{0}"
deny "reflog expire on the primary"         "$W" "git -C $P reflog expire --all"
deny "tag create on the primary"            "$W" "git -C $P tag v9 main"
deny "tag -d on the primary"                "$W" "git -C $P tag -d v9"
deny "remote -v add on the primary"         "$W" "git -C $P remote -v add evil $W"
deny "remote --verbose set-url"             "$W" "git -C $P remote --verbose set-url origin $W"
allow "reflog on the primary"               "$W" "git -C $P reflog -n 5"
allow "reflog show main"                    "$W" "git -C $P reflog show main"
allow "tag list"                            "$W" "git -C $P tag"
allow "tag -l pattern"                      "$W" "git -C $P tag -l v*"
allow "tag --contains"                      "$W" "git -C $P tag --contains main"
allow "remote -v"                           "$W" "git -C $P remote -v"
allow "remote -v show origin"               "$W" "git -C $P remote -v show origin"
allow "GIT_WORK_TREE=<wt> git checkout"     "$W" "GIT_WORK_TREE=$W git checkout feat/x -- README.md"
allow "single-writer repo: checkout"        "$W" "git -C $S checkout 0123abc"
allow "single-writer repo: cwd + merge"     "$S" "git merge x"

echo "== DENY: HIMMEL-3407 — config/remote/branch-upstream/main-ref writes from a LEG'S OWN cwd (no -C) reach the primary's shared common dir =="
# The gap this ticket names: the git arm judges the leg's own repo root, and a
# feature worktree's own root allows — but git config/remote and the shared
# refs/heads namespace live in $GIT_COMMON_DIR, which the worktree shares
# with the primary. Every row below carries NO -C/--git-dir at all; the
# command is aimed at $W itself, which is exactly the shape the ticket says
# the existing arm (g) misses.
deny "config <key> <value>, no -C"          "$W" "git config core.fsmonitor x"
# --git-dir pointing at the worktree's OWN .git FILE (not a directory) is a
# real, working git invocation — git follows the gitfile redirection there —
# and primary_checkout_root's own `git -C <dir>` needs a directory, so
# _bwimc_git_check_common_owner must resolve the repo ROOT first or this
# exact spelling slips through with no check at all.
deny "config via --git-dir=<wt>/.git (file, not dir)" "$W" "git --git-dir=$W/.git config core.fsmonitor x"
deny "config --unset, no -C"                "$W" "git config --unset branch.main.remote"
deny "config set (new syntax), no -C"       "$W" "git config set core.hooksPath x"
deny "remote add, no -C"                    "$W" "git remote add evil $W"
deny_any "remote set-url, no -C"            "$W" "git remote set-url origin $W"
# Round 2 (N4) narrowed these to require an EXPLICIT main/master operand —
# -u/-f/etc with NO branch name given targets the CURRENT branch, which in a
# linked worktree is never main, so every row here now names main explicitly.
deny "branch -u <upstream> main, no -C"     "$W" "git branch -u origin/feat/x main"
deny "branch --set-upstream-to=<u> main, no -C" "$W" "git branch --set-upstream-to=origin/feat/x main"
deny "branch --unset-upstream main, no -C"  "$W" "git branch --unset-upstream main"
deny "branch -f main <start>, no -C"        "$W" "git branch -f main feat/x"
deny "branch -uorigin/x attached main, no -C" "$W" "git branch -uorigin/feat/x main"
deny "update-ref refs/heads/main, no -C"    "$W" "git update-ref refs/heads/main HEAD"
deny "update-ref refs/heads/master, no -C"  "$W" "git update-ref refs/heads/master HEAD"
deny "symbolic-ref refs/heads/main, no -C"  "$W" "git symbolic-ref refs/heads/main refs/heads/feat/x"

echo "== DENY: HIMMEL-3407 adversarial review round 1 =="
# F1 (HIGH, bypass): the old update-ref/symbolic-ref loop skipped every
# `-`-prefixed word but not the VALUE a value-taking flag consumes, so `-m
# <reason>` shifted the ref-name check onto the reason text instead. --stdin
# reads its ref updates from stdin, invisible to a command-text scanner.
deny "update-ref -m <reason> refs/heads/main, no -C" "$W" "git update-ref -m msg refs/heads/main HEAD"
deny "symbolic-ref -m <reason> refs/heads/main, no -C" "$W" "git symbolic-ref -m msg refs/heads/main refs/heads/feat/x"
deny "update-ref --stdin, no -C"            "$W" "git update-ref --stdin"
deny "update-ref --stdin -z, no -C"         "$W" "git update-ref --stdin -z"
# F3 (LOW): -M/-C are branch's FORCE rename/copy (bare -m/-c cannot overwrite
# an existing branch, so they stay in the ordinary-use bucket; only the
# force forms can move `main`). checkout -B / switch -C force-create-or-RESET
# a branch to a start-point, the same "move an existing ref" class spelled
# through a different verb.
deny "branch -M <old> main, no -C"          "$W" "git branch -M feat/x main"
deny "branch -C <old> main, no -C"          "$W" "git branch -C feat/x main"
deny "checkout -B main, no -C"              "$W" "git checkout --ignore-other-worktrees -B main"
deny "switch -C main, no -C"                "$W" "git switch -C main"
deny "checkout -Bmain attached, no -C"      "$W" "git checkout -Bmain"

echo "== DENY: HIMMEL-3407 adversarial review round 2 =="
# N1 (bypass): a glued -f<path> is a real git invocation and was not
# recognised as the file flag at all, so its value was never checked.
# cwd is a NON-repo directory (/tmp), not the leg worktree: the glued form
# must be recognised and checked by ITS OWN resolved path regardless of cwd,
# not fall through to the (here, repo-less and fail-open) common-owner check.
deny "config -f<glued primary path>, cwd=/tmp" "/tmp" "git config -f$P/.git/config core.hooksPath /x"
# N2 (fail-open): an unresolvable --file target used to be silently allowed;
# every other arm denies an unresolved git target, this one now does too.
deny "config --file \"\$DYNAMIC\", no -C"   "$W" "X=$P/.git/config; git config --file \"\$X\" core.hooksPath /x"
# N3 (bypass): GIT_CONFIG_GLOBAL/SYSTEM repoint what --global/--system
# actually write, voiding the scope exemption below.
deny "GIT_CONFIG_GLOBAL= + config --global, no -C" "$W" "GIT_CONFIG_GLOBAL=$P/.git/config git config --global core.hooksPath /x"
deny "GIT_CONFIG_SYSTEM= + config --system, no -C" "$W" "GIT_CONFIG_SYSTEM=$P/.git/config git config --system core.hooksPath /x"
# N5 (cheap): switch's long form of -C, an unambiguous --force abbreviation
# on branch, and a bundled short cluster on checkout.
deny "switch --force-create main, no -C"    "$W" "git switch --force-create main"
deny "branch --move --forc <old> main, no -C" "$W" "git branch --move --forc feat/x main"
deny "checkout -fB main (bundled), no -C"   "$W" "git checkout -fB main"

echo "== ALLOW: HIMMEL-3407 scope is bounded — ordinary worktree git use keeps working =="
allow "branch <new>, no -C (no -u/-f)"      "$W" "git branch newbr"
allow "branch -d, no -C (delete only)"      "$W" "git branch -d newbr"
allow "branch -D, no -C (delete only)"      "$W" "git branch -D newbr"
allow "branch -m <old> <new> (plain rename, no -C)" "$W" "git branch -m feat/x renamedbr"
allow "checkout -b <new>, no -C (plain create)" "$W" "git checkout -b anothernew"
allow "update-ref refs/heads/other, no -C (not main/master)" "$W" "git update-ref refs/heads/other HEAD"
allow "config -l, no -C (read)"             "$W" "git config -l"
allow "config get user.name, no -C (read)"  "$W" "git config get user.name"
allow "remote -v, no -C (read)"             "$W" "git remote -v"
allow "single-writer repo: config write (no primary linkage)" "$S" "git config core.x y"

echo "== ALLOW: HIMMEL-3407 adversarial review round 1 -- F2 false-deny fixes =="
# F2 (MEDIUM, false deny): config/remote writes that do NOT touch the shared
# repo config at all must not deny just because the subcommand name matches.
allow "config --global, no -C"              "$W" "git config --global user.name t"
allow "config --system, no -C"              "$W" "git config --system core.x y"
allow "config --worktree, no -C"            "$W" "git config --worktree core.x y"
allow "config -f <outside path>, no -C"     "$W" "git config -f /tmp/himmel-3407-outside-cfg a.b c"
allow "config --file=<outside path>, no -C" "$W" "git config --file=/tmp/himmel-3407-outside-cfg a.b c"
deny "config --file=<primary>/.git/config, no -C" "$W" "git config --file=$P/.git/config a.b c"
allow "remote update, no -C"                "$W" "git remote update"
allow "remote prune origin, no -C"          "$W" "git remote prune origin"
allow "remote show origin, no -C"           "$W" "git remote show origin"

echo "== ALLOW: HIMMEL-3407 adversarial review round 2 -- N4 false-deny fixes =="
# N4 (false deny): -u/--set-upstream*/-f/-M/-C implicitly target the CURRENT
# branch when no branch-name operand is given — in a linked worktree that is
# always the leg's own feature branch (git refuses to check main out in two
# worktrees at once), never main. Only an EXPLICIT main/master operand makes
# any of these dangerous, matching update-ref/symbolic-ref's own scoping.
allow "branch -u origin/other (implicit target, not main)" "$W" "git branch -u origin/other"
allow "branch -f other start (no main operand)" "$W" "git branch -f other start"
allow "branch --set-upstream-to=<u> (implicit target)" "$W" "git branch --set-upstream-to=origin/other"
allow "branch --unset-upstream (implicit target)" "$W" "git branch --unset-upstream"
allow "branch -M old new (neither is main)" "$W" "git branch -M oldbr newbr2"
allow "branch -uorigin/x attached (implicit target)" "$W" "git branch -uorigin/feat/x"

echo "== HIMMEL-3565 residual 1 + 3: GIT_CONFIG_GLOBAL/SYSTEM value path-check + cross-clause carry =="
# Residual 1 (N3 incomplete): the old check only withheld the
# --global/--system exemption when the env var's NAME was present in the
# clause text; it never resolved the var's VALUE. The existing round-2 deny
# row (cwd=$W, a worktree of $P) passed by accident — $W's own common-dir
# owner IS $P, so the (wrong) check landed on the right answer. From a cwd
# with no repo at all (/tmp), that accident doesn't happen, and the old code
# allowed. The value itself must be resolved and checked directly.
deny "GIT_CONFIG_GLOBAL=<primary cfg> + config --global, cwd=/tmp" "/tmp" \
    "GIT_CONFIG_GLOBAL=$P/.git/config git config --global core.hooksPath /x"
deny "GIT_CONFIG_SYSTEM=<primary cfg> + config --system, cwd=/tmp" "/tmp" \
    "GIT_CONFIG_SYSTEM=$P/.git/config git config --system core.hooksPath /x"
allow "GIT_CONFIG_GLOBAL=<outside path> + config --global, cwd=/tmp" "/tmp" \
    "GIT_CONFIG_GLOBAL=/tmp/himmel-3565-outside-cfg git config --global core.hooksPath /x"
# Residual 3: the old scan read only the CURRENT clause's text, so an
# earlier `export` in the same command (arm (g) already carries
# GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE this way) was invisible to it.
deny "export GIT_CONFIG_GLOBAL=<primary cfg>; config --global, no -C" "$W" \
    "export GIT_CONFIG_GLOBAL=$P/.git/config; git config --global core.hooksPath /x"

echo "== HIMMEL-3565 residual 2: branch arm scopes to the flag's TARGET operand, not any main/master operand =="
# -f's target is the FIRST positional (the branch being created/reset); a
# main/master START-POINT (second positional) is read-only and must allow.
allow "branch -f <new> main (main is the START-POINT, not the target)" "$W" \
    "git branch -f feat main"
# -u/--set-upstream-to's mandatory value is the UPSTREAM, not a branch name;
# with no further operand the target is the CURRENT branch (never main here).
allow "branch -u main (main is -u's VALUE, not a branch operand)" "$W" \
    "git branch -u main"
# -C's target is the NEW branch (last positional); the old one is a read-only
# copy SOURCE.
allow "branch -C main <new> (main is the SOURCE, not the target)" "$W" \
    "git branch -C main feat2"

echo "== HIMMEL-3565 round-3 CR (B1): move SOURCE is a target too — <old> is deleted, not just read =="
# Copy's source is read-only (residual 2's -C row above stays allow), but
# move DELETES the source ref (refs/heads/<old> goes away, and if <old> was
# checked out elsewhere its HEAD repoints) — that is a write, not a read.
deny "branch -M main <new> (main is the MOVE SOURCE, uppercase)" "$W" \
    "git branch -M main renamed"
deny "branch -M master <new> (master is the MOVE SOURCE)" "$W" \
    "git branch -M master renamed"
deny "branch --move --force main <new> (long form, main is the SOURCE)" "$W" \
    "git branch --move --force main renamed"
# Bare -m (no force) is a real rename too — git only needs -f when <new>
# already exists — so it was wrongly excluded from br_danger entirely; now
# in the same danger bucket as -M.
deny "branch -m main <new>, no force (main is the MOVE SOURCE)" "$W" \
    "git branch -m main renamed"

echo "== HIMMEL-3565 round-3 CR (B2): -u's value hides inside a bundled short cluster =="
# The exact -u/-uVALUE forms above are matched, but a cluster like -fu bundles
# -u with an unrelated boolean flag in one token; -u still consumes the NEXT
# token as its mandatory value (never a branch-name operand), and the real
# target is main, the operand after it.
deny "branch -fu <upstream> main (u bundled with -f)" "$W" \
    "git branch -fu origin/feat/x main"
deny "branch -qu <upstream> main (u bundled with -q)" "$W" \
    "git branch -qu origin/feat/x main"
deny "branch -vu <upstream> main (u bundled with -v)" "$W" \
    "git branch -vu origin/feat/x main"

echo "== HIMMEL-3565 residual 4 (documented, not fixed): branch -D main is inert, not modelled =="
# git itself refuses to delete the branch checked out in another worktree, so
# this is inert in the exact scenario this arm defends. See the ponytail
# comment beside the branch arm in block-write-into-main-checkout.sh. Pinned
# here so a change to that invariant is caught rather than silently drifting.
allow "branch -D main, no -C (git itself refuses; not modelled)" "$W" "git branch -D main"

echo "== HIMMEL-4365: work-tree / index rewrites aimed at the primary, every spelling of the target =="
# `restore --staged` writes only the primary's INDEX; it is denied like `add`
# and `update-index` above (the console's next commit on the primary would
# carry the leg's staging). HOME here is the fixture's $FIX/home, so
# ~/../primary and $HOME/../primary resolve to the fixture primary.
for sub in "apply x.patch" "apply --index x.patch" "apply --3way x.patch" "apply -R x.patch" \
           "apply --cached x.patch" "reset --hard" "reset --hard origin/main" "reset --merge HEAD~1" \
           "reset --keep HEAD~1" "reset HEAD~1" "reset --soft HEAD~1" "checkout -- README.md" \
           "checkout ." "checkout -f" "checkout main" "checkout feat/x" "restore README.md" \
           "restore --worktree README.md" "restore --staged README.md" "restore -S README.md" \
           "restore -SW README.md" "stash push" "stash drop" "stash clear" "clean -f" "clean -fd" \
           "merge --ff-only origin/main" "pull origin main" "pull --rebase origin main" \
           "cherry-pick -n feat/x" "revert --no-commit HEAD" "am --3way x.patch" "switch -"; do
    deny "-C <primary> $sub" "$W" "git -C $P $sub"
done
for sub in "reset --hard" "apply x.patch" "checkout -- README.md" "restore README.md" "restore --staged README.md"; do
    deny "-C ~/../primary $sub"                  "$W" "git -C ~/../primary $sub"
    deny "-C \$HOME/../primary $sub"             "$W" "git -C \$HOME/../primary $sub"
    deny "-C \"\${HOME}\"/../primary $sub"       "$W" "git -C \"\${HOME}\"/../primary $sub"
    deny "-C ../primary (relative) $sub"         "$W" "git -C ../primary $sub"
    deny "-C <wt>/../primary $sub"               "$W" "git -C $W/../primary $sub"
    deny "-C <primary>/ (trailing slash) $sub"   "$W" "git -C $P/ $sub"
    deny "-C <primary>/handovers/.. $sub"        "$W" "git -C $P/handovers/.. $sub"
    deny "-C <wt> -C .. -C primary (chained) $sub" "$W" "git -C $W -C .. -C primary $sub"
    deny "-C . (cwd = primary) $sub"             "$P" "git -C . $sub"
    deny "no -C (cwd = primary) $sub"            "$P" "git $sub"
    deny "-c k=v -C <primary> $sub"              "$W" "git -c x.y=z -C $P $sub"
    deny "-C <primary> -c k=v $sub"              "$W" "git -C $P -c x.y=z $sub"
    deny "--no-pager -C <primary> $sub"          "$W" "git --no-pager -C $P $sub"
    deny "--git-dir= --work-tree= $sub"          "$W" "git --git-dir=$P/.git --work-tree=$P $sub"
    deny "--work-tree= --git-dir= (reversed) $sub" "$W" "git --work-tree=$P --git-dir=$P/.git $sub"
    deny "--git-dir <p> --work-tree <p> $sub"    "$W" "git --git-dir $P/.git --work-tree $P $sub"
    deny "--git-dir=\$HOME/../primary/.git $sub" "$W" "git --git-dir=\$HOME/../primary/.git --work-tree=\$HOME/../primary $sub"
    deny "--work-tree=../primary (relative) $sub" "$W" "git --work-tree=../primary $sub"
done
echo "== HIMMEL-4365: the read-only and sanctioned forms on the primary stay ALLOWED =="
allow "-C ~/../primary status"                   "$W" "git -C ~/../primary status"
allow "-C \$HOME/../primary log -1"              "$W" "git -C \$HOME/../primary log -1"
allow "-C ../primary diff"                       "$W" "git -C ../primary diff"
allow "--git-dir= --work-tree= status"           "$W" "git --git-dir=$P/.git --work-tree=$P status"
# HIMMEL-4504: an unknown -c key fails closed on a read aimed at the primary
# (it may name a program git runs); an allowlisted display key still passes.
deny "-c <unknown key> -C <primary> show HEAD"   "$W" "git -c x.y=z -C $P show HEAD"
allow "-c color.ui=never -C <primary> show HEAD" "$W" "git -c color.ui=never -C $P show HEAD"
allow "-C <primary> rev-parse HEAD"              "$W" "git -C $P rev-parse HEAD"
allow "-C <primary> branch --list"               "$W" "git -C $P branch --list"
allow "-C ../primary fetch"                      "$W" "git -C ../primary fetch"
allow "-C ~/../primary pull --ff-only (wrap)"    "$W" "git -C ~/../primary pull --ff-only"
allow "-C <primary> worktree list"               "$W" "git -C $P worktree list"
allow "-C <primary> worktree remove <wt>"        "$W" "git -C $P worktree remove --force $W"

echo "== HIMMEL-4365: a git behind a wrapper the prefix loop does not strip =="
deny "timeout 5 git -C <primary> reset --hard"   "$W" "timeout 5 git -C $P reset --hard"
deny "nice git -C <primary> reset --hard"        "$W" "nice git -C $P reset --hard"
deny "nice -n 5 git -C <primary> apply"          "$W" "nice -n 5 git -C $P apply x.patch"
deny "stdbuf -o0 git -C <primary> checkout --"   "$W" "stdbuf -o0 git -C $P checkout -- README.md"
deny "ionice -c3 git -C <primary> restore"       "$W" "ionice -c3 git -C $P restore README.md"
deny "sudo git -C <primary> reset --hard"        "$W" "sudo git -C $P reset --hard"
deny "timeout 5 git -C ~/../primary reset"       "$W" "timeout 5 git -C ~/../primary reset --hard"
deny "timeout 5 git reset --hard, cwd=primary"   "$P" "timeout 5 git reset --hard"
deny "timeout 5 env -C <primary> git reset"      "$W" "timeout 5 env -C $P git reset --hard"
deny "env -C ../primary timeout 5 git reset"     "$W" "env -C ../primary timeout 5 git reset --hard"
deny "nice env GIT_DIR=<primary> git reset"      "$W" "nice env GIT_DIR=$P/.git git reset --hard"
deny "xargs git -C <primary> reset --hard"       "$W" "echo x | xargs git -C $P reset --hard"
deny "xargs -a list git -C <primary> apply"      "$W" "xargs -a list git -C $P apply"
deny "xargs -I{} git -C {} reset (stdin target)" "$W" "xargs -I{} git -C {} reset --hard"
deny "xargs -I % git -C % reset (custom replstr)" "$W" "xargs -I % git -C % reset --hard"
deny "xargs -i git {} --hard (sub from stdin)"   "$W" "xargs -i git {} --hard"
deny "xargs git, subcommand from stdin"          "$W" "echo reset | xargs git"
deny "xargs -I{} git diff --output={}"           "$W" "xargs -I{} git diff --output={}"
# --output's SEPARATE operand picks the target too (codex-1).
deny "xargs -I{} git -C <primary> diff --output {}" "$W" "printf x | xargs -I{} git -C $P diff --output {}"
deny "xargs -i git -C <primary> log -p --output {}" "$W" "xargs -i git -C $P log -p --output {}"
deny "xargs -I{} git diff --output {}, cwd=leg"  "$W" "printf x | xargs -I{} git diff --output {}"
deny "xargs --replace=Q git show --output Q"      "$W" "xargs --replace=Q git show HEAD --output Q"
deny "xargs -I{} git archive --output {}"         "$W" "xargs -I{} git archive --output {} HEAD"
# Stdin words land among the subcommand's arguments (codex-1, round 2): an
# injected --output overrides any literal one, so only add/stage/rm pass.
deny "xargs -I{} git -C <primary> diff --output /tmp/fixed {}" "$W" "xargs -I{} git -C $P diff --output /tmp/fixed {}"
deny "xargs -I{} git diff {} (--output from stdin)" "$W" "printf '%s\n' '--output=$P/README.md' | xargs -I{} git diff {}"
deny "xargs -I{} git -C <primary> diff {}"        "$W" "printf '%s\n' '--output=$P/README.md' | xargs -I{} git -C $P diff {}"
deny "xargs git diff (stdin appended)"            "$W" "printf -- '--output=$P/x' | xargs git diff"
deny "xargs git -C <primary> log -p (appended)"   "$W" "printf -- '--output=$P/x' | xargs git -C $P log -p"
deny "xargs -n1 git diff"                         "$W" "printf -- '--output=$P/x' | xargs -n1 git diff"
deny "xargs -L1 git show"                         "$W" "printf -- '--output=$P/x' | xargs -L1 git show"
deny "xargs -0 git diff"                          "$W" "xargs -0 git diff"
deny "xargs -d nl git log -p"                     "$W" "xargs -d '\n' git log -p"
deny "xargs -a /tmp/f git diff"                   "$W" "xargs -a /tmp/f git diff"
deny "xargs --arg-file=/tmp/f git show"           "$W" "xargs --arg-file=/tmp/f git show"
deny "xargs git archive HEAD (appended)"          "$W" "printf -- '--output=$P/x' | xargs git archive HEAD"
deny "xargs git branch (args from stdin)"         "$W" "printf -- '-D main' | xargs git branch"
deny "xargs -I{} git log -1 {} (cost: read denied)" "$W" "git log --format=%H | xargs -I{} git log -1 {} --format=%B"
deny "xargs -I{} git log --grep -- {} (-- is an operand)" "$W" "xargs -I{} git log --grep -- {}"
deny "xargs git rev-list (takes --output)"        "$W" "xargs git rev-list"
deny "xargs git grep (-O runs a command)"         "$W" "xargs git grep -l foo"
deny "xargs -I{} git -C <primary> checkout {}"    "$W" "xargs -I{} git -C $P checkout {}"
allow "xargs -I{} git log -1 --format=%B -- {}"   "$W" "xargs -I{} git log -1 --format=%B -- {}"
allow "xargs git log -- (appended after --)"      "$W" "xargs git log --"
allow "xargs -I{} git log -1 --end-of-options {}" "$W" "git log --format=%H | xargs -I{} git log -1 --format=%B --end-of-options {}"
allow "xargs -I{} git -C <primary> show --end-of-options {}" "$W" "xargs -I{} git -C $P show -s --format=%B --end-of-options {}"
allow "xargs git log --end-of-options (appended)" "$W" "xargs git log --format=%B --end-of-options"
deny "xargs git log -1 --end-of-options (-1 may take it)" "$W" "xargs git log -1 --end-of-options"
deny "xargs -I{} git log --grep --end-of-options {}" "$W" "xargs -I{} git log --grep --end-of-options {}"
deny "xargs -I{} git log {} --end-of-options"     "$W" "xargs -I{} git log {} --end-of-options HEAD"
allow "xargs -I{} git -C <primary> diff -- {}"    "$W" "xargs -I{} git -C $P diff -- {}"
allow "xargs -I{} git merge-base --is-ancestor {} HEAD" "$W" "xargs -I{} git merge-base --is-ancestor {} HEAD"
allow "xargs -I{} git -C <primary> ls-tree -r {}" "$W" "xargs -I{} git -C $P ls-tree -r {} --name-only"
allow "git ls-files | xargs git status, cwd=leg"  "$W" "git ls-files | xargs git status"
allow "xargs -n1 git checkout --, cwd=leg"        "$W" "git ls-files | xargs -n1 git checkout --"
allow "xargs git add, cwd=leg"                    "$W" "xargs git add"
allow "xargs -0 git add, cwd=leg"                 "$W" "xargs -0 git add"
allow "xargs -a /tmp/f git rm, cwd=leg"           "$W" "xargs -a /tmp/f git rm"
allow "xargs -I{} git commit, {} unused, cwd=leg" "$W" "echo x | xargs -I{} git commit -m msg"
allow "xargs -I{} git add {} (pathspec), cwd=leg" "$W" "xargs -I{} git add {}"
# HIMMEL-4518: archive/format-patch/bundle output operands are write targets.
deny "git archive -o <primary>/x.tar, cwd=leg"    "$W" "git archive -o $P/x.tar HEAD"
deny "git archive -o<primary>/x.tar, cwd=leg"     "$W" "git archive -o$P/x.tar HEAD"
deny "git archive --output=<primary>/x.tar"       "$W" "git archive --output=$P/x.tar HEAD"
deny "git format-patch -o <primary>/p, cwd=leg"   "$W" "git format-patch -1 -o $P/p"
deny "git format-patch --output-directory <primary>/p" "$W" "git format-patch -1 --output-directory $P/p"
deny "git format-patch --output-directory=<primary>/p" "$W" "git format-patch -1 --output-directory=$P/p"
deny "git format-patch -ko <primary>/p (bundled)" "$W" "git format-patch -1 -ko $P/p"
deny "git format-patch -no<primary>/p (bundled)"  "$W" "git format-patch -1 -no$P/p"
deny "git bundle create <primary>/x.bundle"       "$W" "git bundle create $P/x.bundle HEAD"
deny "git bundle create -q <primary>/x.bundle"    "$W" "git bundle create -q $P/x.bundle --all"
deny "git bundle create -- <primary>/x.bundle"    "$W" "git bundle create -- $P/x.bundle HEAD"
deny "git bundle create -q -- <primary>/x.bundle" "$W" "git bundle create -q -- $P/x.bundle HEAD"
deny "git -C <leg> archive -o <primary>/x.tar, cwd=primary" "$P" "git -C $W archive -o $P/x.tar HEAD"
deny "git -C <leg> format-patch -o <primary>/p"   "$W" "git -C $W format-patch -1 -o $P/p"
deny "git -C <leg> bundle create <primary>/x"     "$P" "git -C $W bundle create $P/x.bundle HEAD"
deny "git -C <primary> archive -o x.tar"          "$W" "git -C $P archive -o x.tar HEAD"
deny "git -C <primary> format-patch -o p"         "$W" "git -C $P format-patch -1 -o p"
deny "git -C <primary> bundle create x.bundle"    "$W" "git -C $P bundle create x.bundle HEAD"
deny "xargs -I{} git archive -o {}"               "$W" "echo $P/x.tar | xargs -I{} git archive -o {} HEAD"
deny "xargs -I{} git format-patch -o {}"          "$W" "echo $P/p | xargs -I{} git format-patch -1 -o {}"
deny "xargs -I{} git bundle create {}"            "$W" "echo $P/x | xargs -I{} git bundle create {} HEAD"
allow "git archive -o /tmp/x.tar, cwd=leg"        "$W" "git archive -o /tmp/x.tar HEAD"
allow "git archive -o x.tar, cwd=leg"             "$W" "git archive -o x.tar HEAD"
allow "git format-patch -o /tmp/p, cwd=leg"       "$W" "git format-patch -1 -o /tmp/p"
allow "git format-patch --output-directory=out, cwd=leg" "$W" "git format-patch -1 --output-directory=out"
allow "git format-patch --stdout, cwd=leg"        "$W" "git format-patch --stdout -1"
allow "git bundle create /tmp/x.bundle, cwd=leg"  "$W" "git bundle create /tmp/x.bundle HEAD"
allow "git bundle create x.bundle, cwd=leg"       "$W" "git bundle create x.bundle HEAD"
allow "git bundle create -- /tmp/x.bundle, cwd=leg" "$W" "git bundle create -- /tmp/x.bundle HEAD"
allow "git bundle verify <primary>/x (a read)"    "$W" "git bundle verify $P/x.bundle"
allow "git -C <leg> archive -o x.tar, cwd=primary" "$P" "git -C $W archive -o x.tar HEAD"
allow "timeout 5 git -C <primary> status"        "$W" "timeout 5 git -C $P status"
allow "sudo -u nobody git -C <primary> log -1"   "$W" "sudo -u nobody git -C $P log -1"
allow "timeout 60 git -C <primary> pull --ff-only" "$W" "timeout 60 git -C $P pull --ff-only"
allow "nice git -C <leg> reset --hard"           "$W" "nice git -C $W reset --hard"
allow "nice git reset --hard, cwd=leg"           "$W" "nice git reset --hard"
allow "git ls-files | xargs git add, cwd=leg"    "$W" "git ls-files | xargs git add"
allow "nice git status, cwd=primary"             "$P" "nice git status"
allow "timeout 5 git worktree remove, cwd=primary" "$P" "timeout 5 git worktree remove $W"

echo "== HIMMEL-4476: git archive read into /tmp is not a write =="
allow "-C <primary> archive -o /tmp/x.tar, cwd=leg"      "$W" "git -C $P archive -o /tmp/x4476.tar HEAD"
allow "archive -o /tmp/x.tar, cwd=primary"               "$P" "git archive -o /tmp/x4476.tar HEAD"
allow "archive --output=/tmp/x.tar, cwd=primary"         "$P" "git archive --output=/tmp/x4476.tar HEAD"
allow "-C <primary> archive | tar -x -C /tmp/d, cwd=leg" "$W" "git -C $P archive HEAD README.md | tar -x -C /tmp/d4476"
allow "archive | tar -x -C /tmp/d, cwd=primary"          "$P" "git archive HEAD README.md | tar -x -C /tmp/d4476"
allow "archive | tar -xf - -C /tmp/d, cwd=primary"       "$P" "git archive HEAD | tar -xf - -C /tmp/d4476"
allow "archive | tar -x --directory=/tmp/d, cwd=leg"     "$W" "git -C $P archive HEAD | tar -xv --directory=/tmp/d4476"
deny "archive | tar -x -C <primary>/sub, cwd=leg"        "$W" "git -C $P archive HEAD | tar -x -C $P/sub"
deny "archive | tar -x -C <primary>, cwd=primary"        "$P" "git archive HEAD | tar -x -C $P"
deny "archive | tar -x -C sub (relative), cwd=primary"   "$P" "git archive HEAD | tar -x -C sub"
deny "archive | tar -x (no -C), cwd=primary"             "$P" "git archive HEAD | tar -x"
deny "archive | tar -x -C /tmp/../<primary>"             "$W" "git -C $P archive HEAD | tar -x -C /tmp/..$P"
deny "archive | tar -x -C /tmp/d --to-command"           "$W" "git -C $P archive HEAD | tar -x -C /tmp/d --to-command=sh"
deny "archive | tar -x -C /tmp/d -C <primary>"           "$W" "git -C $P archive HEAD | tar -x -C /tmp/d -C $P"
deny "archive | sudo tar -x -C <primary>"                "$W" "git -C $P archive HEAD | sudo tar -x -C $P"
deny "archive | bash -c 'tar -x -C <primary>'"           "$W" "git -C $P archive HEAD | bash -c 'tar -x -C $P'"
deny "archive -o /tmp/x && tar -x -C <primary> -f"       "$W" "git -C $P archive -o /tmp/x.tar HEAD && tar -x -C $P -f /tmp/x.tar"
deny "archive -o /tmp/x; tar -xf /tmp/x -C <primary>"    "$P" "git archive -o /tmp/x.tar HEAD; tar -xf /tmp/x.tar -C $P"
deny "archive -o /tmp/x; python3 extracts"               "$P" "git archive -o /tmp/x.tar HEAD; python3 -m tarfile -e /tmp/x.tar ."
deny "archive -o <primary>/x.tar, cwd=primary"           "$P" "git archive -o $P/x.tar HEAD"
deny "-C <primary> archive --out=<primary>/x.tar"        "$W" "git -C $P archive --out=$P/x.tar HEAD"
deny "-C <leg> archive --out=<primary>/x.tar"            "$P" "git -C $W archive --out=$P/x.tar HEAD"
deny "-C <leg> archive --outp <primary>/x.tar"           "$P" "git -C $W archive --outp $P/x.tar HEAD"
deny "-C <primary> archive --remote=. --exec=/tmp/evil"  "$W" "git -C $P archive --remote=. --exec=/tmp/evil HEAD"
deny "-C <primary> archive --ex=/tmp/evil"               "$W" "git -C $P archive --ex=/tmp/evil HEAD"
deny "-C <primary> -c tar.tgz.command archive"           "$W" "git -C $P -c tar.tgz.command=/tmp/evil archive --format=tgz -o /tmp/x.tgz HEAD"
# A non-tar format (zip included) runs any tar.<format>.command already in
# the repo or global config, so only the built-in tar format is a read.
deny "-C <primary> archive --format=zip -o /tmp/x.zip"    "$W" "git -C $P archive --format=zip -o /tmp/x4476.zip HEAD"
deny "archive --format=tgz -o /tmp/x.tgz, cwd=primary"    "$P" "git archive --format=tgz -o /tmp/x4476.tgz HEAD"
deny "archive --fo zip -o /tmp/x.tar, cwd=primary"        "$P" "git archive --fo zip -o /tmp/x4476.tar HEAD"
deny "-C <primary> archive -o /tmp/x.zip (by extension)"  "$W" "git -C $P archive -o /tmp/x4476.zip HEAD"
deny "archive --output=/tmp/x.xyz, cwd=primary"           "$P" "git archive --output=/tmp/x4476.xyz HEAD"
deny "archive --format=xyz | tar -x -C /tmp/d, cwd=leg"   "$W" "git -C $P archive --format=xyz HEAD | tar -x -C /tmp/d4476"
deny "archive -vo /tmp/x.tar (bundled -o), cwd=primary"   "$P" "git archive -vo /tmp/x4476.tar HEAD"
allow "archive --format tar | tar -x -C /tmp/d, cwd=leg"  "$W" "git -C $P archive --format tar HEAD | tar -x -C /tmp/d4476"

echo "== HIMMEL-4365: --output <file> on a read subcommand writes that file =="
deny "-C <primary> diff --output=<rel>"          "$W" "git -C $P diff --output=.claude/settings.json"
deny "-C <primary> diff --output <rel>"          "$W" "git -C $P diff --output .claude/settings.json"
deny "-C <primary> log -p --output=README.md"    "$W" "git -C $P log -p --output=README.md"
deny "-C <primary> show --output=README.md"      "$W" "git -C $P show --output=README.md HEAD"
deny "diff --output=<primary>/<f>, cwd=leg"      "$W" "git diff --output=$P/.claude/settings.json"
deny "--work-tree=<primary> diff --output=<rel>" "$W" "git --work-tree=$P --git-dir=$P/.git diff --output=README.md"
allow "diff --output=/tmp/x.diff"                "$W" "git diff --output=/tmp/x.diff"
allow "diff --output=<rel>, cwd=leg"             "$W" "git diff --output=out.diff"
allow "-C <primary> diff --output=/tmp/x.diff"   "$W" "git -C $P diff --output=/tmp/x.diff"
allow "-C <primary> log -- --output=x (pathspec)" "$W" "git -C $P log -- --output=x"

echo "== HIMMEL-4504: a read-shaped git clause that runs a program is a write =="
# Each shape runs from a leg cwd with -C <primary>, and from cwd=primary with
# no -C. The program runs with the primary as its cwd, so it can write there.
for pre in "-C $P " ""; do
    if [ -n "$pre" ]; then cwd="$W"; tag="-C <primary>"; else cwd="$P"; tag="cwd=primary"; fi
    deny "$tag -c core.pager='sh -c …' log"        "$cwd" "git ${pre}-c core.pager='sh -c \"touch x\"' log"
    deny "$tag -ccore.pager= (attached) log"       "$cwd" "git ${pre}-ccore.pager=x log"
    deny "$tag -c Core.Pager= (case) log"          "$cwd" "git ${pre}-c Core.Pager=x log"
    deny "$tag -c pager.log=<cmd> log"             "$cwd" "git ${pre}-c pager.log='sh -c x' log"
    deny "$tag -c core.editor= log"                "$cwd" "git ${pre}-c core.editor=x log"
    deny "$tag -c sequence.editor= log"            "$cwd" "git ${pre}-c sequence.editor=x log"
    deny "$tag -c diff.external= diff"             "$cwd" "git ${pre}-c diff.external=x diff"
    deny "$tag -c diff.d.command= diff"            "$cwd" "git ${pre}-c diff.d.command=x diff"
    deny "$tag -c diff.d.textconv= log -p"         "$cwd" "git ${pre}-c diff.d.textconv=x log -p"
    deny "$tag -c merge.d.driver= status"          "$cwd" "git ${pre}-c merge.d.driver=x status"
    deny "$tag -c core.fsmonitor= status"          "$cwd" "git ${pre}-c core.fsmonitor=x status"
    deny "$tag -c core.hooksPath= status"          "$cwd" "git ${pre}-c core.hooksPath=x status"
    deny "$tag -c core.sshCommand= ls-remote"      "$cwd" "git ${pre}-c core.sshCommand=x ls-remote origin"
    deny "$tag -c credential.helper= ls-remote"    "$cwd" "git ${pre}-c credential.helper=x ls-remote origin"
    deny "$tag -c gpg.program= log"                "$cwd" "git ${pre}-c gpg.program=x log --show-signature"
    deny "$tag -c alias.st='!sh' status"           "$cwd" "git ${pre}-c alias.st='!sh -c x' status"
    deny "$tag -c filter.f.smudge= status"         "$cwd" "git ${pre}-c filter.f.smudge=x status"
    deny "$tag -c unknown.key= status"             "$cwd" "git ${pre}-c x.y=z status"
    deny "$tag safe key then a program key"        "$cwd" "git ${pre}-c color.ui=never -c core.fsmonitor=x status"
    deny "$tag --config-env=core.pager=V log"      "$cwd" "git ${pre}--config-env=core.pager=V log"
    deny "$tag --config-env core.pager=V log"      "$cwd" "git ${pre}--config-env core.pager=V log"
    deny "$tag grep --open-files-in-pager=<cmd>"   "$cwd" "git ${pre}grep --open-files-in-pager='sh -c x' foo"
    deny "$tag grep --open-files-in-pager"         "$cwd" "git ${pre}grep --open-files-in-pager foo"
    deny "$tag grep --open-files=<cmd> (abbrev)"   "$cwd" "git ${pre}grep --open-files=x foo"
    deny "$tag grep --op (abbrev)"                 "$cwd" "git ${pre}grep --op foo"
    deny "$tag grep -O"                            "$cwd" "git ${pre}grep -O foo"
    deny "$tag grep -O<cmd>"                       "$cwd" "git ${pre}grep -Ox foo"
    deny "$tag grep -iO<cmd> (cluster)"            "$cwd" "git ${pre}grep -iOx foo"
    deny "$tag grep --textconv"                    "$cwd" "git ${pre}grep --textconv foo"
    deny "$tag diff --ext-diff"                    "$cwd" "git ${pre}diff --ext-diff"
    deny "$tag log -p --ext-diff"                  "$cwd" "git ${pre}log -p --ext-diff"
    deny "$tag show --ext-diff HEAD"               "$cwd" "git ${pre}show --ext-diff HEAD"
    deny "$tag log -p --textconv"                  "$cwd" "git ${pre}log -p --textconv"
    deny "$tag cat-file --textconv"                "$cwd" "git ${pre}cat-file --textconv HEAD:README.md"
    deny "$tag cat-file --filters"                 "$cwd" "git ${pre}cat-file --filters HEAD:README.md"
    deny "$tag worktree move <wt> into the primary" "$cwd" "git ${pre}worktree move $W $P/moved"
    deny "$tag worktree move <wt> <primary>"       "$cwd" "git ${pre}worktree move $W $P"
    deny "$tag worktree move -f <wt> <primary>/x"  "$cwd" "git ${pre}worktree move -f $W $P/x"
    deny "$tag worktree add <primary>/x"           "$cwd" "git ${pre}worktree add $P/nwt -b nwt"
    deny "$tag worktree add -b y <primary>/x"      "$cwd" "git ${pre}worktree add -b y $P/nwt"
    deny "$tag worktree add -btopicb <primary>/x"  "$cwd" "git ${pre}worktree add -btopicb $P/nwt"
    deny "$tag worktree add -Bxb <primary>/x"      "$cwd" "git ${pre}worktree add -Bxb $P/nwt"
    deny "$tag worktree add -fb y <primary>/x"     "$cwd" "git ${pre}worktree add -fb y $P/nwt"
    deny "$tag cat-file --filt"                    "$cwd" "git ${pre}cat-file --filt HEAD:README.md"
    deny "$tag cat-file --fi"                      "$cwd" "git ${pre}cat-file --fi HEAD:README.md"
    deny "$tag cat-file --text"                    "$cwd" "git ${pre}cat-file --text HEAD:README.md"
    deny "$tag grep --textc"                       "$cwd" "git ${pre}grep --textc foo"
done
deny "--exec-path=<dir> -C <primary> status"       "$W" "git --exec-path=/tmp/x -C $P status"
deny "-C <primary> --exec-path=<dir> log"          "$W" "git -C $P --exec-path=/tmp/x log"
deny "--exec-path=<dir> status, cwd=primary"       "$P" "git --exec-path=/tmp/x status"
deny "worktree move <wt> <rel>, cwd=primary"       "$P" "git worktree move $W moved"
deny "worktree add <rel>, cwd=primary"             "$P" "git worktree add nwt -b nwt"
deny "GIT_PAGER=<cmd> git -C <primary> log"        "$W" "GIT_PAGER='sh -c x' git -C $P log"
deny "PAGER=<cmd> git -C <primary> log"            "$W" "PAGER='sh -c x' git -C $P log"
deny "env GIT_PAGER=<cmd> git log, cwd=primary"    "$P" "env GIT_PAGER=x git log"
deny "export GIT_PAGER=<cmd>; git log, cwd=primary" "$P" "export GIT_PAGER=x; git log"
deny "GIT_EXTERNAL_DIFF=<cmd> git -C <primary> diff" "$W" "GIT_EXTERNAL_DIFF=x git -C $P diff"
deny "GIT_EXEC_PATH=<dir> git -C <primary> status" "$W" "GIT_EXEC_PATH=/tmp/x git -C $P status"
deny "GIT_CONFIG_GLOBAL=<file> git -C <primary> log" "$W" "GIT_CONFIG_GLOBAL=/tmp/evil git -C $P log"
deny "GIT_CONFIG_PARAMETERS= git -C <primary> log" "$W" "GIT_CONFIG_PARAMETERS=\"'core.pager'='x'\" git -C $P log"
deny "GIT_CONFIG_KEY_0=core.pager git log"         "$W" "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.pager GIT_CONFIG_VALUE_0=x git -C $P log"
for pre in "-C $P " ""; do
    if [ -n "$pre" ]; then cwd="$W"; tag="-C <primary>"; else cwd="$P"; tag="cwd=primary"; fi
    allow "$tag -c color.ui=never log"             "$cwd" "git ${pre}-c color.ui=never log -1"
    allow "$tag -c core.quotepath=off status"      "$cwd" "git ${pre}-c core.quotepath=off status"
    allow "$tag -c core.pager=cat log"             "$cwd" "git ${pre}-c core.pager=cat log -1"
    allow "$tag -c pager.log=false log"            "$cwd" "git ${pre}-c pager.log=false log -1"
    allow "$tag -c safe.directory=* status"        "$cwd" "git ${pre}-c safe.directory=* status"
    allow "$tag -c log.decorate=short log"         "$cwd" "git ${pre}-c log.decorate=short log -1"
    allow "$tag --no-pager log"                    "$cwd" "git ${pre}--no-pager log -1"
    allow "$tag diff --no-ext-diff"                "$cwd" "git ${pre}diff --no-ext-diff"
    allow "$tag log -p --no-textconv"              "$cwd" "git ${pre}log -p --no-textconv -1"
    allow "$tag grep foo"                          "$cwd" "git ${pre}grep foo"
    allow "$tag grep -n -i -e O foo"               "$cwd" "git ${pre}grep -n -i -e O"
    allow "$tag grep --or (not --open…)"           "$cwd" "git ${pre}grep -e a --or -e b"
    allow "$tag worktree move <wt> /tmp/x"         "$cwd" "git ${pre}worktree move $W /tmp/x"
    allow "$tag worktree list"                     "$cwd" "git ${pre}worktree list"
    allow "$tag grep --text foo (= -a)"            "$cwd" "git ${pre}grep --text foo"
    allow "$tag grep -e --textconv (operand)"      "$cwd" "git ${pre}grep -e --textconv foo"
    allow "$tag grep -A 2 -e x -- --textconv"      "$cwd" "git ${pre}grep -A 2 -e x -- --textconv"
    allow "$tag grep -ie --open-files-in-pager"    "$cwd" "git ${pre}grep -ie --open-files-in-pager foo"
    allow "$tag grep -f --textconv (file operand)" "$cwd" "git ${pre}grep -f --textconv"
    allow "$tag grep --max-depth 1 -e --textconv"  "$cwd" "git ${pre}grep --max-depth 1 -e --textconv"
    allow "$tag grep --context 2 --textconv-less"  "$cwd" "git ${pre}grep --context 2 foo"
    deny "$tag grep -e x --textconv (after operand)" "$cwd" "git ${pre}grep -e x --textconv foo"
    deny "$tag grep -A 2 --textconv"               "$cwd" "git ${pre}grep -A 2 --textconv foo"
    deny "$tag grep -e x -O"                       "$cwd" "git ${pre}grep -e x -O foo"
    deny "$tag grep --max-depth 1 --textc"         "$cwd" "git ${pre}grep --max-depth 1 --textc foo"
done
allow "git --exec-path (prints only), cwd=primary" "$P" "git --exec-path"
allow "git --exec-path -C <primary> status"        "$W" "git --exec-path -C $P status"
allow "GIT_PAGER=cat git -C <primary> log"         "$W" "GIT_PAGER=cat git -C $P log -1"
allow "PAGER=cat git log, cwd=primary"             "$P" "PAGER=cat git log -1"
allow "GIT_CONFIG_GLOBAL=/dev/null git -C <primary> log" "$W" "GIT_CONFIG_GLOBAL=/dev/null git -C $P log -1"
allow "worktree add <ignored dir>, cwd=primary"    "$P" "git worktree add ignored/nwt -b nwt"
allow "worktree add <outside>, -C <primary>"       "$W" "git -C $P worktree add $FIX/w3 -b w3"
# The program runs in the LEG, whose own repo the fence does not guard.
allow "-c core.pager=<cmd> log, cwd=leg"           "$W" "git -c core.pager='sh -c x' log -1"
allow "-c diff.external=<cmd> diff --ext-diff, cwd=leg" "$W" "git -c diff.external=x diff --ext-diff"
allow "grep -O<cmd>, cwd=leg"                      "$W" "git grep -Ox foo"
allow "--exec-path=<dir> status, cwd=leg"          "$W" "git --exec-path=/tmp/x status"

echo "== HIMMEL-4504 J1950: program env behind a wrapper, two-step exports, worktree --, transport programs =="
for pre in "-C $P " ""; do
    if [ -n "$pre" ]; then cwd="$W"; tag="-C <primary>"; else cwd="$P"; tag="cwd=primary"; fi
    # B1: a program env in front of (or inside) a wrapper the unwrap strips.
    deny "$tag GIT_EXTERNAL_DIFF= nice -n 5 diff"   "$cwd" "GIT_EXTERNAL_DIFF=x nice -n 5 git ${pre}diff"
    deny "$tag GIT_EXTERNAL_DIFF= timeout 5 diff"   "$cwd" "GIT_EXTERNAL_DIFF=x timeout 5 git ${pre}diff"
    deny "$tag GIT_EXTERNAL_DIFF= xargs diff"       "$cwd" "GIT_EXTERNAL_DIFF=x xargs git ${pre}diff < /dev/null"
    deny "$tag GIT_EXTERNAL_DIFF= stdbuf -o0 diff"  "$cwd" "GIT_EXTERNAL_DIFF=x stdbuf -o0 git ${pre}diff"
    deny "$tag GIT_EXTERNAL_DIFF= sudo -E diff"     "$cwd" "GIT_EXTERNAL_DIFF=x sudo -E git ${pre}diff"
    deny "$tag GIT_EXTERNAL_DIFF= ionice diff"      "$cwd" "GIT_EXTERNAL_DIFF=x ionice git ${pre}diff"
    deny "$tag GIT_EXTERNAL_DIFF= setsid diff"      "$cwd" "GIT_EXTERNAL_DIFF=x setsid git ${pre}diff"
    deny "$tag GIT_EXTERNAL_DIFF= nohup nice diff"  "$cwd" "GIT_EXTERNAL_DIFF=x nohup nice git ${pre}diff"
    deny "$tag GIT_EXTERNAL_DIFF= env nice diff"    "$cwd" "GIT_EXTERNAL_DIFF=x env nice git ${pre}diff"
    deny "$tag env GIT_EXTERNAL_DIFF= nice diff"    "$cwd" "env GIT_EXTERNAL_DIFF=x nice git ${pre}diff"
    deny "$tag nice env GIT_EXTERNAL_DIFF= diff"    "$cwd" "nice env GIT_EXTERNAL_DIFF=x git ${pre}diff"
    deny "$tag GIT_PAGER=<cmd> nice log"            "$cwd" "GIT_PAGER=x nice git ${pre}log"
    deny "$tag PAGER=<cmd> timeout 5 log"           "$cwd" "PAGER=x timeout 5 git ${pre}log"
    deny "$tag GIT_EXEC_PATH= nice status"          "$cwd" "GIT_EXEC_PATH=/tmp/x nice git ${pre}status"
    deny "$tag GIT_CONFIG_GLOBAL= nice status"      "$cwd" "GIT_CONFIG_GLOBAL=/tmp/evil nice git ${pre}status"
    deny "$tag GIT_CONFIG_PARAMETERS= timeout status" "$cwd" "GIT_CONFIG_PARAMETERS=\"'core.fsmonitor'='x'\" timeout 9 git ${pre}status"
    deny "$tag GIT_CONFIG_KEY_0= nice status"       "$cwd" "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0=x nice git ${pre}status"
    deny "$tag GIT_SSH_COMMAND= nice ls-remote"     "$cwd" "GIT_SSH_COMMAND=x nice git ${pre}ls-remote origin"
    # B2 / T5: a program env set as its own statement, exported before,
    # after or never (it may already be exported in the session).
    deny "$tag X=; export X; diff"                  "$cwd" "GIT_EXTERNAL_DIFF=x; export GIT_EXTERNAL_DIFF; git ${pre}diff"
    deny "$tag export X; X=; diff"                  "$cwd" "export GIT_EXTERNAL_DIFF; GIT_EXTERNAL_DIFF=x; git ${pre}diff"
    deny "$tag declare -x X=; diff"                 "$cwd" "declare -x GIT_EXTERNAL_DIFF=x; git ${pre}diff"
    deny "$tag typeset -x X=; diff"                 "$cwd" "typeset -x GIT_EXTERNAL_DIFF=x; git ${pre}diff"
    deny "$tag set -a; X=; diff"                    "$cwd" "set -a; GIT_EXTERNAL_DIFF=x; git ${pre}diff"
    deny "$tag readonly -x X=; diff"                "$cwd" "readonly -x GIT_EXTERNAL_DIFF=x; git ${pre}diff"
    deny "$tag GIT_CONFIG_GLOBAL=; export; status"  "$cwd" "GIT_CONFIG_GLOBAL=/tmp/evil; export GIT_CONFIG_GLOBAL; git ${pre}status"
    deny "$tag X= (bare, unexported); diff"         "$cwd" "GIT_EXTERNAL_DIFF=x; git ${pre}diff"
    # B3: after `--` every worktree add/move word is positional.
    deny "$tag worktree add -d -- -evil"            "$cwd" "git ${pre}worktree add -d -- -evil"
    deny "$tag worktree add -d -- --evil"           "$cwd" "git ${pre}worktree add -d -- --evil"
    deny "$tag worktree add -fd -- -x"              "$cwd" "git ${pre}worktree add -fd -- -x"
    deny "$tag worktree move -- <wt> -m"            "$cwd" "git ${pre}worktree move -- $W -m"
    deny "$tag worktree move <wt> -- -m"            "$cwd" "git ${pre}worktree move $W -- -m"
    # T1: ls-remote's --upload-pack (any abbreviation) / hidden --exec run a
    # program; fetch/pull already lose the carve-out on --upload-pack.
    deny "$tag ls-remote --upload-pack=<cmd> ."     "$cwd" "git ${pre}ls-remote --upload-pack='touch pwn; git-upload-pack' ."
    deny "$tag ls-remote --upload-pa=<cmd> ."       "$cwd" "git ${pre}ls-remote --upload-pa='touch pwn; git-upload-pack' ."
    deny "$tag ls-remote --u=<cmd> ."               "$cwd" "git ${pre}ls-remote --u=x ."
    deny "$tag ls-remote --upload-pack <cmd> ."     "$cwd" "git ${pre}ls-remote --upload-pack 'touch pwn; git-upload-pack' ."
    deny "$tag ls-remote --exec=<cmd> ."            "$cwd" "git ${pre}ls-remote --exec=x ."
    deny "$tag ls-remote --exe=<cmd> ."             "$cwd" "git ${pre}ls-remote --exe=x ."
    deny "$tag fetch --upload-pa=<cmd> ."           "$cwd" "git ${pre}fetch --upload-pa=x ."
    deny "$tag fetch origin --upload-pack <cmd>"    "$cwd" "git ${pre}fetch origin --upload-pack x"
    deny "$tag pull --ff-only --upload-pack=<cmd>"  "$cwd" "git ${pre}pull --ff-only --upload-pack=x origin"
    # T2: the ext:: transport runs its URL as a command.
    deny "$tag GIT_ALLOW_PROTOCOL=ext ls-remote ext::" "$cwd" "GIT_ALLOW_PROTOCOL=ext git ${pre}ls-remote 'ext::sh -c touch% pwn'"
    deny "$tag ls-remote ext::<cmd>"                "$cwd" "git ${pre}ls-remote 'ext::sh -c touch% pwn'"
    deny "$tag GIT_ALLOW_PROTOCOL=ext nice ls-remote origin" "$cwd" "GIT_ALLOW_PROTOCOL=file:ext nice git ${pre}ls-remote origin"
    # T3: HOME / XDG_CONFIG_HOME load another global config (core.fsmonitor).
    deny "$tag HOME=<dir> status"                   "$cwd" "HOME=/tmp/h git ${pre}status"
    deny "$tag XDG_CONFIG_HOME=<dir> status"        "$cwd" "XDG_CONFIG_HOME=/tmp/h git ${pre}status"
    deny "$tag HOME=<dir> nice status"              "$cwd" "HOME=/tmp/h nice git ${pre}status"
    deny "$tag env XDG_CONFIG_HOME=<dir> status"    "$cwd" "env XDG_CONFIG_HOME=/tmp/h git ${pre}status"
    deny "$tag export HOME=<dir>; status"           "$cwd" "export HOME=/tmp/h; git ${pre}status"
    deny "$tag HOME=<dir>; export HOME; status"     "$cwd" "HOME=/tmp/h; export HOME; git ${pre}status"
    deny "$tag XDG_CONFIG_HOME=<dir>; status"       "$cwd" "XDG_CONFIG_HOME=/tmp/h; git ${pre}status"
    # CR: envs that make git or a spawned program (ssh, the pager, a shell,
    # the loader) run an attacker-chosen program.
    deny "$tag SSH_ASKPASS= ls-remote"              "$cwd" "SSH_ASKPASS=x SSH_ASKPASS_REQUIRE=force git ${pre}ls-remote origin"
    deny "$tag SSH_ASKPASS_REQUIRE=force ls-remote" "$cwd" "SSH_ASKPASS_REQUIRE=force git ${pre}ls-remote origin"
    deny "$tag LESSOPEN= log"                       "$cwd" "LESSOPEN='|x %s' git ${pre}log"
    deny "$tag LESSCLOSE= log"                      "$cwd" "LESSCLOSE=x git ${pre}log"
    deny "$tag LD_PRELOAD= status"                  "$cwd" "LD_PRELOAD=/tmp/x.so git ${pre}status"
    deny "$tag LD_AUDIT= nice status"               "$cwd" "LD_AUDIT=/tmp/x.so nice git ${pre}status"
    deny "$tag LD_LIBRARY_PATH= status"             "$cwd" "LD_LIBRARY_PATH=/tmp/x git ${pre}status"
    deny "$tag BASH_ENV= log"                       "$cwd" "BASH_ENV=/tmp/x git ${pre}log"
    deny "$tag ENV= log"                            "$cwd" "ENV=/tmp/x git ${pre}log"
    deny "$tag PATH=<dir> log"                      "$cwd" "PATH=/tmp/evil:/usr/bin git ${pre}log"
    deny "$tag export LD_PRELOAD=; status"          "$cwd" "export LD_PRELOAD=/tmp/x.so; git ${pre}status"
    # Ordinary reads behind wrappers and safe envs keep the relief.
    allow "$tag nice log"                          "$cwd" "nice git ${pre}log -1"
    allow "$tag timeout 5 status"                   "$cwd" "timeout 5 git ${pre}status"
    allow "$tag GIT_PAGER=cat nice log"             "$cwd" "GIT_PAGER=cat nice git ${pre}log -1"
    allow "$tag X=1 nice log"                       "$cwd" "X=1 nice git ${pre}log -1"
    allow "$tag LC_ALL=C; status"                   "$cwd" "LC_ALL=C; git ${pre}status"
    allow "$tag declare -x LC_ALL=C; log"           "$cwd" "declare -x LC_ALL=C; git ${pre}log -1"
    allow "$tag log / status / diff / show"         "$cwd" "git ${pre}log -1; git ${pre}status; git ${pre}diff; git ${pre}show HEAD"
    allow "$tag ls-remote origin"                   "$cwd" "git ${pre}ls-remote origin"
    allow "$tag ls-remote --exit-code origin"       "$cwd" "git ${pre}ls-remote --exit-code origin"
    allow "$tag fetch origin"                       "$cwd" "git ${pre}fetch origin"
    allow "$tag worktree add <ignored>/wt -b"       "$cwd" "git ${pre}worktree add $P/ignored/wt -b feat/z"
    allow "$tag worktree add -- <ignored>/wt"       "$cwd" "git ${pre}worktree add -d -- $P/ignored/wt"
done
# The env before a wrapper also carries GIT_DIR / GIT_WORK_TREE (the unwrap
# re-read used to glue the assignments onto the git word).
deny "GIT_DIR= GIT_WORK_TREE= nice git reset --hard"  "$W" "GIT_DIR=$P/.git GIT_WORK_TREE=$P nice git reset --hard"
deny "GIT_DIR= GIT_WORK_TREE= timeout 5 git reset"    "$W" "GIT_DIR=$P/.git GIT_WORK_TREE=$P timeout 5 git reset --hard"
deny "X=1 nice git -C <primary> reset --hard"         "$W" "X=1 nice git -C $P reset --hard"
deny "GIT_DIR=; export GIT_DIR; … git reset --hard"   "$W" "GIT_DIR=$P/.git; export GIT_DIR; GIT_WORK_TREE=$P; export GIT_WORK_TREE; git reset --hard"
deny "declare -x GIT_DIR= GIT_WORK_TREE=; reset"      "$W" "declare -x GIT_DIR=$P/.git GIT_WORK_TREE=$P; git reset --hard"
deny "set -a; GIT_DIR=; GIT_WORK_TREE=; reset"        "$W" "set -a; GIT_DIR=$P/.git; GIT_WORK_TREE=$P; git reset --hard"
# The program runs in the LEG: no primary write.
allow "GIT_EXTERNAL_DIFF= nice git diff, cwd=leg"     "$W" "GIT_EXTERNAL_DIFF=x nice git diff"
allow "HOME=<dir> git status, cwd=leg"                "$W" "HOME=/tmp/h git status"
allow "LD_PRELOAD=<so> git status, cwd=leg"           "$W" "LD_PRELOAD=/tmp/x.so git status"
allow "ls-remote --upload-pack=<cmd> ., cwd=leg"      "$W" "git ls-remote --upload-pack=x ."

echo "== DENY: unparseable input fails CLOSED in direct-exec mode (adversarial review S6) =="
for raw in '' 'not json' '[]' '{}' '{"tool_name":"Bash"}' '{"tool_name":"Bash","tool_input":{}}' \
           '{"tool_input":{"command":"git status"}}'; do
    got=$(_rc "$DIRECT" "$raw")
    if [ "$got" = block ]; then ok "input '$raw' [direct]"; else bad "input '$raw' [direct] — expected block got $got"; fi
done
got=$(_rc "$DIRECT" '{"tool_name":"Read","tool_input":{"file_path":"/x"}}')
if [ "$got" = allow ]; then ok "non-Bash tool passes [direct]"; else bad "non-Bash tool [direct] — expected allow got $got"; fi

echo "== ALLOW: the documented bypass (EDIT_ON_MAIN_OK=1 in the launching shell) =="
j=$(payload "git -C $P checkout feat/x -- README.md" "$W")
for s in "$DIRECT" "$FENCE"; do
    rc=0; printf '%s' "$j" | EDIT_ON_MAIN_OK=1 bash "$s" >/dev/null 2>&1 || rc=$?
    if [ "$rc" = 0 ]; then ok "EDIT_ON_MAIN_OK=1 bypass [${s##*/}]"; else bad "EDIT_ON_MAIN_OK=1 bypass [${s##*/}] — rc=$rc"; fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
