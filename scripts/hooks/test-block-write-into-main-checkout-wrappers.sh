#!/usr/bin/env bash
# Unit test for scripts/hooks/block-write-into-main-checkout.sh — the
# HIMMEL-4329 rows: path-qualified wrapper names and chroot readings.
# Platform guard: Git Bash on Windows / any POSIX bash 3.2+ (same as the
# guard; no .ps1 twin). A sibling of test-block-write-into-main-checkout.sh,
# split out so the parent suite stays under the CI per-suite cap; the harness
# below is a trimmed copy of the parent's (same fixtures, same FIXTURE RULE).
#
# Every row runs BOTH entry modes via `check_both`: direct-exec
# (`bash block-write-into-main-checkout.sh` with the JSON payload on stdin)
# and sourced (`bash block-terminal-write-fence.sh`, the codex adapter).
#
# FIXTURE RULE (load-bearing): fixtures are rooted under the REAL $HOME, NOT
# a bare `mktemp -d`. `/tmp` paths are exempted by is_temp_or_devnull, so a
# DENY row rooted under mktemp -d would pass as ALLOW for the wrong reason.
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
DIRECT="$HOOKS/block-write-into-main-checkout.sh"
FENCE="$HOOKS/block-terminal-write-fence.sh"
[ -f "$DIRECT" ] || { echo "guard not found: $DIRECT" >&2; exit 1; }
[ -f "$FENCE" ]  || { echo "guard not found: $FENCE" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not on PATH"; exit 0; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

_REAL_HOME="$HOME"
FIX=$(mktemp -d "${_REAL_HOME}/.himmel-4329-fencefix-XXXXXX") || exit 1
trap 'rm -rf "$FIX"' EXIT

export HOME="$FIX/home"
mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
git config --global user.email t@example.invalid
git config --global user.name t
unset CODEX_EXTERNAL_WRITES_OK 2>/dev/null || true
unset EDIT_ON_MAIN_OK 2>/dev/null || true

mkrepo_committed() {  # mkrepo_committed <dir> <branch>
    git init -q -b "$2" "$1" >/dev/null 2>&1
    mkdir -p "$1/scripts/hooks" "$1/handovers"
    : > "$1/README.md"
    git -C "$1" add README.md >/dev/null 2>&1
    git -C "$1" commit -q -m init >/dev/null 2>&1
}

# $FIX/primary — main; $FIX/wt — linked worktree off it, feat/x.
mkrepo_committed "$FIX/primary" main
git -C "$FIX/primary" worktree add -q -b feat/x "$FIX/wt" >/dev/null 2>&1
mkdir -p "$FIX/primary/somedir"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

# _run <script> <json> [cwd-for-hook-process] -> echoes allow/block/?(rc=N)
_run() {
    local script="$1" json="$2" hookpwd="${3:-}" rc got
    if [ -n "$hookpwd" ]; then
        ( cd "$hookpwd" && printf '%s' "$json" | bash "$script" >/dev/null 2>&1 )
        rc=$?
    else
        printf '%s' "$json" | bash "$script" >/dev/null 2>&1
        rc=$?
    fi
    case "$rc" in
        0) got=allow ;;
        2) got=block ;;
        *) got="?(rc=$rc)" ;;
    esac
    printf '%s' "$got"
}

# check_both <label> <block|allow> <json> — both entry modes must agree.
check_both() {
    local label="$1" expect="$2" json="$3" got
    got=$(_run "$DIRECT" "$json")
    if [ "$got" = "$expect" ]; then ok "$label (direct-exec)"; else bad "$label (direct-exec) — expected $expect got $got"; fi
    got=$(_run "$FENCE" "$json")
    if [ "$got" = "$expect" ]; then ok "$label (sourced/codex)"; else bad "$label (sourced/codex) — expected $expect got $got"; fi
}

_subst_row() { # label verdict command [cwd]
    local j
    j="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$3" | jq -Rs .),\"cwd\":\"${4:-$FIX/wt}\"}}"
    check_both "$1" "$2" "$j"
}
_PR="$FIX/primary"; _WR="$FIX/wt"

# _r4213 runs a row from cwd /tmp AND from the primary checkout.
_r4213() { # label verdict template
    local c="$3"
    c="${c//@P@/$_PR}"; c="${c//@W@/$_WR}"
    _subst_row "$1, cwd /tmp" "$2" "$c" /tmp
    _subst_row "$1, cwd the primary" "$2" "$c" "$_PR"
}

echo "== HIMMEL-4329 path-qualified wrapper names, chroot readings =="
# shellcheck disable=SC2016  # row templates are literal shell text
{
# A wrapper name matches on its basename, any case, `.exe` dropped (the
# HIMMEL-4138 interp-body treatment): `/usr/bin/nice` strips like `nice`.
# One row per wrapper _bwimc_strip_prefix knows, bare / path / .exe.
for _w4329 in 'command|' 'exec|' 'nohup|' 'chrt|5' 'taskset|-c 0' 'ionice|-c 3' 'nice|-n 5' \
    'timeout|5' 'stdbuf|-oL' 'env|FOO=1' 'sudo|-u root' 'chroot|/'; do
    _n4329="${_w4329%%|*}"; _a4329="${_w4329#*|}"
    for _f4329 in "$_n4329" "/usr/bin/$_n4329" "$_n4329.exe"; do
        _r4213 "101 $_f4329 $_a4329 touch primary" block "$_f4329 $_a4329 touch @P@/f"
    done
    _r4213 "101 /usr/bin/$_n4329 $_a4329 touch worktree (ALLOW)" allow "/usr/bin/$_n4329 $_a4329 touch @W@/f"
done
_r4213 "101a /usr/bin/env -C primary touch f"                          block '/usr/bin/env -C @P@ touch f'
_r4213 "101b /usr/bin/nice touch primary"                              block '/usr/bin/nice touch @P@/f'
_r4213 "101c /usr/bin/sudo -D primary touch f"                         block '/usr/bin/sudo -D @P@ touch f'
_r4213 "101d /USR/BIN/NICE.EXE touch primary"                          block '/USR/BIN/NICE.EXE touch @P@/f'
_r4213 "101e /usr/bin/nice /usr/bin/env -C primary rm f"               block '/usr/bin/nice /usr/bin/env -C @P@ rm f'
_subst_row "101f /usr/bin/env -C /tmp touch f (ALLOW), cwd /tmp"       allow "/usr/bin/env -C /tmp touch f" /tmp
_r4213 "101g /usr/bin/nice touch /tmp (ALLOW)"                         allow '/usr/bin/nice touch /tmp/himmel-4329-f'
_r4213 "101h /usr/bin/env FOO=1 ls (ALLOW)"                            allow '/usr/bin/env FOO=1 ls'
_subst_row "101i /usr/bin/env -C worktree touch f (ALLOW), cwd /tmp"   allow "/usr/bin/env -C $_WR touch f" /tmp
# chroot DIR / sudo -R DIR / sudo --chroot=DIR: the command's / is DIR, so a
# write target is also read as DIR + target; an unknown DIR fails closed.
_r4213 "102a sudo -R primary -D / touch /f"                            block 'sudo -R @P@ -D / touch /f'
_r4213 "102b sudo --chroot=primary touch /f"                           block 'sudo --chroot=@P@ touch /f'
_r4213 "102c chroot primary touch /f"                                  block 'chroot @P@ touch /f'
_r4213 "102d sudo --chroot primary touch /f"                           block 'sudo --chroot @P@ touch /f'
_r4213 "102e sudo -Rprimary touch /f"                                  block 'sudo -R@P@ touch /f'
_r4213 "102f /usr/sbin/chroot primary touch /f"                        block '/usr/sbin/chroot @P@ touch /f'
_r4213 "102g chroot --userspec=u:g primary rm /README.md"              block 'chroot --userspec=u:g @P@ rm /README.md'
# a root that IS the primary denies any write, even one the host would exempt
_r4213 "102h chroot primary touch /tmp/f (root is the primary)"        block 'chroot @P@ touch /tmp/f'
_subst_row "102i chroot primary touch f (relative: the chroot's /), cwd /tmp" block "chroot $_PR touch f" /tmp
_r4213 "102j chroot primary cp to /f"                                  block 'chroot @P@ cp /etc/hosts /f'
_r4213 "102k chroot \$X touch /f (unknown root)"                       block 'chroot $X touch /f'
_r4213 "102l chroot --bogus primary touch /f (unknown option)"         block 'chroot --bogus @P@ touch /f'
_subst_row "102m chroot fixture-root touch /primary/f (root above the primary), cwd /tmp" block "chroot $FIX touch /primary/f" /tmp
_subst_row "102n chroot rel-root touch /f (relative root), cwd the primary's parent" block "chroot primary touch /f" "$FIX"
_r4213 "102o chroot /srv/x touch /f (ALLOW)"                           allow 'chroot /srv/himmel-4329-x touch /f'
_r4213 "102p sudo -R /srv/x touch /f (ALLOW)"                          allow 'sudo -R /srv/himmel-4329-x touch /f'
_r4213 "102q chroot primary ls (no write, ALLOW)"                      allow 'chroot @P@ ls /'
_r4213 "102r chroot worktree touch /f (ALLOW)"                         allow 'chroot @W@ touch /f'
_r4213 "102s chroot / touch /tmp (ALLOW)"                              allow 'chroot / touch /tmp/himmel-4329-f'
# CR round 1 codex-1: inside the jail an absolute symlink restarts at the root
# and `..` stops there, so a root ABOVE the primary reaches it through a link
# the host resolves elsewhere. Fixture links live under $FIX only.
ln -sfn /primary "$FIX/jlnk"          # jail /jlnk -> jail /primary = $FIX/primary
ln -sfn ../../primary "$FIX/jrel"     # `..` clamps at the jail root -> $FIX/primary
mkdir -p "$FIX/jail"
ln -sfn /etc "$FIX/jail/jlnk"         # unrelated jail: its /etc, never the primary
_subst_row "102t chroot fixture-root touch /jlnk/f (absolute in-jail symlink), cwd /tmp" block "chroot $FIX touch /jlnk/f" /tmp
_subst_row "102u chroot fixture-root touch jlnk/f (relative target via the link), cwd /tmp" block "chroot $FIX touch jlnk/f" /tmp
_subst_row "102v chroot fixture-root touch /jrel/f (relative link, .. clamps at the root), cwd /tmp" block "chroot $FIX touch /jrel/f" /tmp
_subst_row "102w chroot fixture-root rm /jlnk/README.md, cwd /tmp" block "chroot $FIX rm /jlnk/README.md" /tmp
_subst_row "102x chroot primary/somedir touch /../../x (.. clamps at a root inside the primary), cwd /tmp" block "chroot $FIX/primary/somedir touch /../../x" /tmp
_subst_row "102y chroot fixture-root touch /../../../primary/f (.. clamps at an ancestor root), cwd /tmp" block "chroot $FIX touch /../../../primary/f" /tmp
_subst_row "102z chroot unrelated-jail touch /jlnk/f (ALLOW), cwd /tmp" allow "chroot $FIX/jail touch /jlnk/f" /tmp
}

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
