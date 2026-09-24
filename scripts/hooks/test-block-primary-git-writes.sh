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

echo "== HIMMEL-3565 residual 4 (documented, not fixed): branch -D main is inert, not modelled =="
# git itself refuses to delete the branch checked out in another worktree, so
# this is inert in the exact scenario this arm defends. See the ponytail
# comment beside the branch arm in block-write-into-main-checkout.sh. Pinned
# here so a change to that invariant is caught rather than silently drifting.
allow "branch -D main, no -C (git itself refuses; not modelled)" "$W" "git branch -D main"

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
