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
for sub in "checkout feat/x -- README.md" "reset --hard HEAD" "merge main" "stash pop" "commit -m x" \
           "restore README.md" "rebase main" "pull --rebase" "config core.x y" "co x"; do
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
