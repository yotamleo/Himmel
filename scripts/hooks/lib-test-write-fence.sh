# Shared fixture + harness for the block-write-into-main-checkout suite family
# (HIMMEL-4164). SOURCED by test-block-write-into-main-checkout.sh and its
# sibling shards test-block-write-into-main-checkout-<family>.sh; not a suite
# itself (no test- prefix, so CI does not discover it). Source it from the
# shard's own dir:  . "$(dirname "$0")/lib-test-write-fence.sh"
# It sets the same `set -uo pipefail`, builds the fixture repos under the REAL
# $HOME (see FIXTURE RULE in test-block-write-into-main-checkout.sh), and
# defines ok/bad/_run/check_both/check_both_reason/check_one. The caller prints
# the pass/fail summary itself.
# shellcheck shell=bash
# sourced-lib
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
DIRECT="$HOOKS/block-write-into-main-checkout.sh"
FENCE="$HOOKS/block-terminal-write-fence.sh"
[ -f "$DIRECT" ] || { echo "guard not found: $DIRECT" >&2; exit 1; }
[ -f "$FENCE" ]  || { echo "guard not found: $FENCE" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not on PATH"; exit 0; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

_REAL_HOME="$HOME"
FIX=$(mktemp -d "${_REAL_HOME}/.himmel-2526-fencefix-XXXXXX") || exit 1
TMPFIX=""
trap 'rm -rf "$FIX" "$TMPFIX"' EXIT

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

# $FIX/primary — main, with a .single-writer carve-out row target and the
# handovers/ + scripts/hooks/ dirs the required rows write into.
mkrepo_committed "$FIX/primary" main
echo ".single-writer" >> "$FIX/primary/.git/info/exclude"

# $FIX/wt — linked worktree off primary, feat/x.
git -C "$FIX/primary" worktree add -q -b feat/x "$FIX/wt" >/dev/null 2>&1

# $FIX/featprimary — PRIMARY checkout (no worktree) on a feature branch.
mkrepo_committed "$FIX/featprimary" feat/y

# $FIX/Docs/Primary — mixed-case-ancestor repo on main (case-preservation row).
mkdir -p "$FIX/Docs"
mkrepo_committed "$FIX/Docs/Primary" main

# $FIX/swrepo — main WITH a .single-writer marker present.
mkrepo_committed "$FIX/swrepo" main
touch "$FIX/swrepo/.single-writer"

# $TMPFIX — a /tmp-rooted clone of the primary shape, FLIP CONTROL ONLY (row 28).
# The `/tmp/` prefix is HARDCODED, not `${TMPDIR:-/tmp}` and not a bare
# `mktemp -d`: this row asserts a `*/tmp/*` pattern match, and on macOS both
# of those resolve TMPDIR to `/var/folders/.../T/`, which matches neither
# `*/tmp/*` nor `*/temp/*` — the row would fail there for an unrelated reason.
TMPFIX=$(mktemp -d /tmp/himmel-2526-bwimc-tmpfix.XXXXXX) || exit 1
mkrepo_committed "$TMPFIX/primary" main

# $FIX/wt/link-to-primary.txt — a worktree symlink pointing AT a file inside
# the PRIMARY checkout (CR round 3, codex-3).
printf 'orig\n' > "$FIX/primary/existing.txt"
ln -sf "$FIX/primary/existing.txt" "$FIX/wt/link-to-primary.txt"

# HIMMEL-2592 round 9 codex-3: two primary-side files whose NAMES are the
# whole finding — one contains "-i" as a substring (the real filename from
# the live false positive: an unanchored `sed...-i` entry-gate regex
# matched the "-i" inside "invariants"), one does not. Same content, same
# directory, same verb, only the name differs — this pair is what shows a
# fix is about the FILENAME and not about `sed -n`/`sed -e` generally.
printf 'a\n' > "$FIX/primary/test-ws5-invariants.sh"
printf 'a\n' > "$FIX/primary/run-shell-tests.sh"

# HIMMEL-2592 fixtures (operation-chosen path resolution + operand classes).
printf 'wt\n'   > "$FIX/wt/wtfile.txt"
printf 'wt\n'   > "$FIX/wt/z.txt"
printf 'orig\n' > "$FIX/primary/a.txt"
mkdir -p "$FIX/primary/somedir"
printf 'orig\n' > "$FIX/primary/somedir/inner.txt"
# A worktree DIRECTORY symlink pointing INTO the primary. `rm <wt>/dirlink`
# removes only the ENTRY (worktree-local, allow), but `rm -r <wt>/dirlink/`
# deletes the REFERENT's contents THROUGH the link (deny) — the pair is what
# proves resolution follows the OPERAND SHAPE, not just the verb.
ln -sfn "$FIX/primary/somedir" "$FIX/wt/dirlink"
# HIMMEL-2592 round 8 codex-2: a worktree entry literally NAMED "2" that is
# a symlink into the primary — `cp -t 2 > /dev/null src` types "2" as a
# GENUINE -t value (a real space separates it from the unrelated redirect
# that follows), so it must still deny; a naive "any digit before a
# redirect is an fd artifact" fix would wrongly discard it and fail open.
ln -sfn "$FIX/primary/somedir" "$FIX/wt/2"
# A symlink INSIDE the primary pointing OUT at a worktree file: `rm` on it
# unlinks an entry that lives in the protected checkout. This is the MIRROR
# of the argued deny removal — every removal row below sits beside the row
# asserting the same verb still denies when the ENTRY is in the primary.
ln -sf "$FIX/wt/wtfile.txt" "$FIX/primary/link-to-wt.txt"
# The DIRECTORY twin of the same mirror. It doubles as the regression row for
# guard_canon_path_nofollow's dir-symlink handling: this is exactly the shape
# that a nofollow which still dereferences a final dir-symlink turns into a
# false ALLOW.
mkdir -p "$FIX/wt/somedir"
printf 'w\n' > "$FIX/wt/somedir/inner.txt"
ln -sfn "$FIX/wt/somedir" "$FIX/primary/dirlink-out"
# CR round 1 codex-2: a worktree link to a WORKTREE directory — the
# false-positive control that keeps the `ln`-into-a-directory rule from
# degenerating into "deny every ln whose destination is a link".
mkdir -p "$FIX/wt/realsub"
ln -sfn "$FIX/wt/realsub" "$FIX/wt/wtdirlink"
# CR round 3 codex-3: a REAL worktree directory whose CHILD entry is a link
# into the primary. Creating `<wt>/childdir/z.txt` replaces that child ENTRY
# (ln, mv) but writes THROUGH it (cp) — the pair is what pins the split.
mkdir -p "$FIX/wt/childdir"
ln -sf "$FIX/primary/a.txt" "$FIX/wt/childdir/z.txt"

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

# check_both <label> <block|allow> <json> [hookpwd] — asserts BOTH entry
# modes (direct-exec via $DIRECT, sourced via $FENCE) agree with EXPECT.
check_both() {
    local label="$1" expect="$2" json="$3" hookpwd="${4:-}"
    local got
    got=$(_run "$DIRECT" "$json" "$hookpwd")
    if [ "$got" = "$expect" ]; then ok "$label (direct-exec)"; else bad "$label (direct-exec) — expected $expect got $got"; fi
    got=$(_run "$FENCE" "$json" "$hookpwd")
    if [ "$got" = "$expect" ]; then ok "$label (sourced/codex)"; else bad "$label (sourced/codex) — expected $expect got $got"; fi
}

# _run_stderr <script> <json> [cwd-for-hook-process] -> echoes stderr text.
# Brace-group form (shellcheck SC2069's own suggested fix) instead of a bare
# `2>&1 >/dev/null`: stdout is discarded INSIDE the group, then the group's
# own stderr becomes the surrounding command substitution's captured stream.
_run_stderr() {
    local script="$1" json="$2" hookpwd="${3:-}"
    if [ -n "$hookpwd" ]; then
        ( cd "$hookpwd" && { printf '%s' "$json" | bash "$script" >/dev/null; } 2>&1 )
    else
        { printf '%s' "$json" | bash "$script" >/dev/null; } 2>&1
    fi
}

# _check_one_reason / check_both_reason — a DENY row that asserts the deny
# REASON, not merely rc=2. Load-bearing (HIMMEL-2592): an rc-only assertion
# reports an area as covered when it is not. The canonical example is
# `tee /dev/null > <primary>/f` — before this round it DID deny, but because
# the tee operand loop swallowed the bare `>` as a bogus filename and then
# happened to check the real path as a SECOND tee operand. Asserting the
# `(target token: ...)` line is what distinguishes "denied by the redirect
# arm" from "denied by accident".
_check_one_reason() {
    local label="$1" script="$2" json="$3" needle="$4" hookpwd="${5:-}"
    local got err
    got=$(_run "$script" "$json" "$hookpwd")
    if [ "$got" != block ]; then
        bad "$label — expected block got $got"
        return 0
    fi
    err=$(_run_stderr "$script" "$json" "$hookpwd")
    case "$err" in
        *"$needle"*) ok "$label" ;;
        *) bad "$label — deny reason missing [$needle]; got: $(printf '%s' "$err" | tr '\n' '|' | cut -c1-200)" ;;
    esac
}

# check_both_reason <label> <json> <needle> [hookpwd]
check_both_reason() {
    local label="$1" json="$2" needle="$3" hookpwd="${4:-}"
    _check_one_reason "$label (direct-exec)" "$DIRECT" "$json" "$needle" "$hookpwd"
    _check_one_reason "$label (sourced/codex)" "$FENCE" "$json" "$needle" "$hookpwd"
}

# check_one <label> <script> <block|allow> <json> [hookpwd] — single-mode.
check_one() {
    local label="$1" script="$2" expect="$3" json="$4" hookpwd="${5:-}"
    local got
    got=$(_run "$script" "$json" "$hookpwd")
    if [ "$got" = "$expect" ]; then ok "$label"; else bad "$label — expected $expect got $got"; fi
}

# Shared by the -heredoc and -forms shards (the HIMMEL-3622 command-
# substitution row helper and the primary/worktree roots its rows aim at).
_subst_row() { # label verdict command [cwd]
    local j
    j="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$3" | jq -Rs .),\"cwd\":\"${4:-$FIX/wt}\"}}"
    check_both "$1" "$2" "$j"
}
_PR="$FIX/primary"; _WR="$FIX/wt"
