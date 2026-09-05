#!/usr/bin/env bash
# Install himmel's pre-push CR marker gate into a FOREIGN git repo (an
# adopter's repo, or a throwaway clone for an upstream PR). Unlike
# scripts/hooks/install-cr-pre-push-legacy.sh (which writes pre-push.legacy,
# a pre-commit migration slot a foreign repo never chains, and self-locates
# the gate from the TARGET's own primary worktree — absent in a foreign
# clone, so it fails closed on every push), this writes the REAL pre-push
# slot with an absolute himmel gate path baked in at install time.
#
# Usage: install-cr-gate.sh --target <path> [--remove] [--status] [--force] [-h|--help]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OWNER_MARKER="# himmel-cr-gate-v1"

# is_himmel_hook FILE — ownership check for --status/--remove/--force
# (codex, CR round, HIMMEL-2035). `grep -Fq "$OWNER_MARKER" FILE` matched the
# marker text ANYWHERE in the file, so a foreign hook that merely mentions
# "# himmel-cr-gate-v1" in an unrelated comment would read as himmel-owned —
# letting --remove delete it, or a reinstall replace it. build_hook_content
# always writes the marker as the file's exact SECOND line (right after the
# shebang); require that instead of a substring match anywhere.
is_himmel_hook() {
    [ -f "$1" ] || return 1
    sed -n '2p' "$1" 2>/dev/null | grep -Fxq "$OWNER_MARKER"
}

is_windows() {
    case "$(uname -s 2>/dev/null || echo)" in
        *MINGW*|*MSYS*|*CYGWIN*|*NT*) return 0 ;; *) return 1 ;;
    esac
}

# to_native_path PATH — mirrors scripts/setup-hooks.sh's resolve_node/
# resolve_bash: an MSYS `/c/...` path baked into the hook could be invoked
# through a different bash on a later push, so normalize to the native
# `C:/...` form git itself uses.
to_native_path() {
    if is_windows && command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1" 2>/dev/null && return 0
    fi
    printf '%s\n' "$1"
}

usage() {
    cat <<'USAGE'
Usage: install-cr-gate.sh --target <path> [--remove] [--status] [--force] [-h|--help]
USAGE
}

TARGET=""
DO_REMOVE=0
DO_STATUS=0
FORCE=0
while [ $# -gt 0 ]; do
    case "$1" in
        # `shift 2` with only one arg left FAILS (and `set -e` is off by
        # design here), leaving $# unchanged — an infinite loop on a bare
        # trailing `--target`. Require the value explicitly instead.
        --target)
            [ $# -ge 2 ] || { echo "install-cr-gate: --target requires a value" >&2; usage >&2; exit 2; }
            TARGET="$2"; shift 2 ;;
        --target=*) TARGET="${1#--target=}"; shift ;;
        --remove) DO_REMOVE=1; shift ;;
        --status) DO_STATUS=1; shift ;;
        --force) FORCE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "install-cr-gate: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done
if [ -z "$TARGET" ]; then
    echo "install-cr-gate: --target <path> is required" >&2
    usage >&2
    exit 2
fi

if ! git -C "$TARGET" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "install-cr-gate: $TARGET is not a git work tree" >&2
    exit 2
fi
target_common_dir=$(git -C "$TARGET" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
    echo "install-cr-gate: cannot resolve git-common-dir of $TARGET" >&2
    exit 2
}

# Effective hooks dir. Two scopes, two different right answers
# (HIMMEL-2035 CR round 1, [codex-1]/[codex-2]).
#
# REPO-LOCAL core.hooksPath -> ask GIT where it points; never re-derive it.
# The hand-rolled `case` this replaced resolved a relative value against the
# toplevel (right) but left `~/hooks` unexpanded and produced the nonexistent
# "<toplevel>/~/hooks" (wrong) — git expands the tilde itself.
# `rev-parse --path-format=absolute --git-path hooks` is git's own answer and
# is correct for every form.
#
# GLOBAL/SYSTEM core.hooksPath -> git's answer points OUTSIDE this repo, at a
# directory EVERY repo on the machine shares. Installing a per-repo CR gate
# there would arm repos the operator never named and collide with whatever
# already owns that slot, so we install into this repo's own hooks dir and
# WARN instead: git will not run it unless that shared dir chains back to the
# repo hook. Chaining is common — tokensave's global `pre-push` is exactly
# such a shim, which is why the gate does fire on a box configured that way —
# but it cannot be assumed, and an un-chained global dir would otherwise leave
# the adopter with an "installed" report over an inert gate.
git_hooks_dir=$(git -C "$TARGET" rev-parse --path-format=absolute --git-path hooks 2>/dev/null) || git_hooks_dir=""
[ -n "$git_hooks_dir" ] || {
    echo "install-cr-gate: cannot resolve the effective hooks dir of $TARGET" >&2
    exit 2
}
target_toplevel=$(git -C "$TARGET" rev-parse --path-format=absolute --show-toplevel 2>/dev/null) || target_toplevel=""

# The question that decides where we write is NOT "what scope is the config
# in" — it is "does git's effective hooks dir live INSIDE this repo".
# [codex-1], CR round 2: a REPO-LOCAL core.hooksPath can name a shared
# absolute or home directory just as easily as a global one can, so a
# scope-based test claimed a per-repo guarantee it did not deliver. One
# containment check covers both scopes and is the property we actually mean.
#
# Compared on RESOLVED real paths, not the nominal ones (codex CR round 4):
# a lexical prefix compare of $git_hooks_dir as-is would read a `.git/hooks`
# that is itself a SYMLINK to a shared external directory as "inside this
# repo" (it textually starts with $target_common_dir) and happily write the
# gate through it into a location this repo does not own. cd+pwd -P is the
# portable canonicalizer already used elsewhere in this repo
# (scripts/lib/shared-branch-lock.sh) — readlink -f is GNU-only and macOS
# ships none. `pwd -P` emits MSYS-style paths (`/tmp/...`) on Windows Git
# Bash while git's own --path-format=absolute emits native ones
# (`C:/Users/...`) for the SAME directory — comparing one resolved and one
# raw would silently break on format alone, not just on an actual symlink.
# Route through to_native_path (already defined above) so every value this
# feeds into the case statement below shares one format.
_real_dir() { local _d; _d=$(cd "$1" 2>/dev/null && pwd -P) && to_native_path "$_d" || printf '%s' "$1"; }
target_common_dir_real=$(_real_dir "$target_common_dir")
target_toplevel_real=$(_real_dir "$target_toplevel")
git_hooks_dir_real=$(_real_dir "$git_hooks_dir")
hooks_dir_shared=0
case "$git_hooks_dir_real/" in
    "$target_common_dir_real"/*) ;;
    "$target_toplevel_real"/*)   ;;
    *) hooks_dir_shared=1 ;;
esac

if [ "$hooks_dir_shared" -eq 1 ]; then
    # Out-of-repo hooks dir: install into THIS repo's own slot regardless.
    # Writing into a directory other repos share would arm repos the operator
    # never named and collide with whatever already owns that slot. do_install
    # warns and reports whether git will actually reach the hook.
    hooks_dir="$target_common_dir/hooks"
else
    hooks_dir="$git_hooks_dir"
fi
pre_push_hook="$hooks_dir/pre-push"

# The "own slot" fallback above is the SAME nominal path a symlinked
# `.git/hooks` entry resolves through, so it does not by itself dodge the
# symlink case above — the FINAL chosen dir is re-checked once it is
# guaranteed to exist (after do_install's own mkdir -p, below), and refuses
# rather than silently write through an escape. Checking here too, before
# mkdir -p, would miss a hooks_dir that does not exist YET but sits behind
# an existing symlinked ancestor — mkdir -p follows that symlink and creates
# the real target through it regardless (codex CR round, HIMMEL-2035).

# shellcheck disable=SC2016  # the single-quoted bodies below are the HOOK's
# source text; $gate/$@ must reach the generated file unexpanded.
build_hook_content() {
    # The baked path is interpolated with printf %q, NOT sed into a
    # double-quoted assignment ([codex-3], CR round 2). The old
    # `sed "s|@@HIMMEL_GATE@@|$1|"` broke two ways on a checkout path holding
    # shell/sed metacharacters — `|` ended the sed expression and `&` expanded
    # to the whole match, corrupting the path; and landing the result inside
    # `gate="..."` meant a `$`, backtick or `"` was EVALUATED when the hook ran.
    # %q emits a shell-quoted token that round-trips through exactly one level
    # of shell parsing, which is what the hook does to it. No delimiter to
    # collide with, nothing left to expand.
    printf '#!/usr/bin/env bash\n'
    printf '# himmel-cr-gate-v1\n'
    # A LITERAL, machine-readable copy of the baked path, so --status can read
    # it back with plain string ops. Round 3 [codex-1]: --status used to
    # recover the path by `eval`-ing the `gate=` line below — but that line
    # lives in a FOREIGN repo's hook, and the owner-marker comment guarding it
    # is just a comment anyone can paste. Inspecting a repo must never execute
    # anything it contains. This line is data; the `gate=` line is code, and
    # only git ever runs it.
    printf '# himmel-cr-gate-path: %s\n' "$1"
    printf 'set -u\n'
    printf 'gate=%q\n' "$1"
    printf '%s\n' '[ -f "$gate" ] || { echo "himmel CR gate not found at $gate — re-run install-cr-gate.sh --target <this repo>, or '"'"'git push --no-verify'"'"' to bypass" >&2; exit 2; }'
    printf '%s\n' 'exec bash "$gate" "$@"'
}

do_status() {
    if [ ! -e "$pre_push_hook" ]; then
        echo "absent"; exit 0
    fi
    if ! is_himmel_hook "$pre_push_hook"; then
        echo "foreign"; exit 1
    fi
    # Read the LITERAL path line — never eval the `gate=` line ([codex-1],
    # round 3). `sed` here only strips a fixed prefix; nothing is executed, so
    # a hostile hook that keeps the owner-marker comment can at worst make
    # --status print a wrong path, never run a command.
    baked=$(sed -n 's/^# himmel-cr-gate-path: //p' "$pre_push_hook" 2>/dev/null | head -n1)
    if [ -z "$baked" ] || [ ! -f "$baked" ]; then
        echo "stale"; exit 1
    fi
    echo "installed"; exit 0
}

do_remove() {
    if [ ! -e "$pre_push_hook" ]; then
        echo "nothing to remove"; exit 0
    fi
    if ! is_himmel_hook "$pre_push_hook"; then
        echo "install-cr-gate: refusing to remove — $pre_push_hook is not himmel-owned (no $OWNER_MARKER marker)" >&2
        exit 2
    fi
    rm -f "$pre_push_hook" || { echo "install-cr-gate: cannot remove $pre_push_hook" >&2; exit 2; }
    echo "removed"; exit 0
}

do_install() {
    # Refuse installing into himmel's own checkout (any worktree — worktrees
    # of one repo share one common dir): himmel already wires its own
    # pre-push CR gate via install-cr-pre-push-legacy.sh; installing this
    # hook there would double-run the gate.
    own_common_dir=$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || own_common_dir=""
    if [ -n "$own_common_dir" ] && [ "$target_common_dir" = "$own_common_dir" ]; then
        echo "install-cr-gate: refusing — target's git-common-dir ($target_common_dir) is himmel's own; himmel already has its own pre-push CR wiring (scripts/hooks/install-cr-pre-push-legacy.sh)" >&2
        exit 2
    fi

    # Shared-hooks-dir warning ([codex-1]). A core.hooksPath from GLOBAL or
    # SYSTEM scope makes git ignore this repo's own hooks dir unless that
    # shared dir chains back to it. We still install per-repo (installing INTO
    # the shared dir would arm every repo on the machine), but the operator
    # must be told, or "installed" reads as "armed" when it is not.
    if [ "$hooks_dir_shared" -eq 1 ]; then
        hooks_path_any=$(git -C "$TARGET" config --get core.hooksPath 2>/dev/null || true)
        shared_pre_push="$git_hooks_dir/pre-push"
        # Does the machine-wide hook CHAIN back to the repo's own pre-push? If
        # it does (tokensave's `chain-repo-hook` shim is exactly this shape),
        # the per-repo gate fires normally and this is informational. If it
        # does not, the gate is INERT and the operator must act. Reporting
        # those two as one undifferentiated warning is what makes an
        # "installed" line untrustworthy, so we separate them.
        # ponytail: textual probe — matches a chain that execs the repo hook by
        # its conventional `hooks/pre-push` path. A shim that computes that path
        # some other way reads as "no chain" (fail-LOUD: it over-warns, never
        # under-warns). Upgrade to a dry-run exec probe only if a real shim
        # trips it.
        if [ -f "$shared_pre_push" ] && grep -q 'hooks/pre-push' "$shared_pre_push" 2>/dev/null; then
            echo "install-cr-gate: NOTE: git resolves core.hooksPath=$hooks_path_any from GLOBAL/SYSTEM config, but $shared_pre_push appears to CHAIN to the repo's own pre-push — the gate installed at $pre_push_hook should fire. Confirm with one test push." >&2
        else
            echo "install-cr-gate: WARNING: git resolves core.hooksPath=$hooks_path_any from GLOBAL/SYSTEM config and runs hooks ONLY from there, so it will NOT run $pre_push_hook. $(if [ -f "$shared_pre_push" ]; then echo "$shared_pre_push exists but does not appear to chain to the repo hook."; else echo "There is no $shared_pre_push to chain from."; fi) THE GATE IS INSTALLED BUT INERT until the owner of this machine runs ONE of:" >&2
            # The remedy names the RESOLVED ABSOLUTE hooks dir, never the
            # relative `.git/hooks` ([codex-1], round 4). In a LINKED WORKTREE
            # `.git` is a FILE (a gitdir pointer), so `.git/hooks` does not
            # exist — following that advice would point core.hooksPath at a
            # missing directory and disable EVERY hook in the repo, which is
            # strictly worse than the inert gate it was meant to fix.
            echo "  (a) give this repo its own hooks dir:  git -C '$TARGET' config --local core.hooksPath '$hooks_dir'" >&2
            echo "  (b) chain the machine-wide hook, by adding to $shared_pre_push:" >&2
            # --git-common-dir, not --git-dir (codex, CR round, HIMMEL-2035):
            # in a LINKED WORKTREE --git-dir resolves to the worktree-local
            # gitdir (.git/worktrees/<name>), but the gate above was installed
            # into hooks_dir under the COMMON gitdir — a pasted --git-dir shim
            # would compute a repo_hook path that never matches, leaving the
            # installed gate silently inert despite the chain "working".
            echo "        repo_hook=\"\$(git rev-parse --path-format=absolute --git-common-dir)/hooks/pre-push\"" >&2
            echo "        [ -x \"\$repo_hook\" ] && [ \"\$repo_hook\" != \"\$0\" ] && exec \"\$repo_hook\" \"\$@\"" >&2
            echo "  install-cr-gate never edits git config or a machine-wide hook on your behalf." >&2
        fi
    fi

    # Non-github origin: clear-cr-marker.sh's post-PR gate is gh-only and
    # fail-closed. Warn and continue — never refuse on this alone.
    origin_url=$(git -C "$TARGET" remote get-url origin 2>/dev/null || true)
    if [ -n "$origin_url" ]; then
        case "$origin_url" in
            *github.com*) : ;;
            *) echo "install-cr-gate: WARNING: origin ($origin_url) is not github.com — clear-cr-marker.sh's post-PR gate is gh-only and fail-closed, so the marker will not be clearable past PR-open on this host" >&2 ;;
        esac
    fi

    if [ -e "$pre_push_hook" ] && ! is_himmel_hook "$pre_push_hook" && [ "$FORCE" -ne 1 ]; then
        echo "install-cr-gate: refusing to overwrite existing non-himmel pre-push hook at $pre_push_hook (use --force to replace it)" >&2
        exit 2
    fi

    # Resolve the baked gate path from himmel's PRIMARY checkout, never a
    # worktree and never dirname "$0" (HIMMEL-2035 A4): all feature work
    # happens in worktrees under .claude/worktrees/ that /clean_garden
    # deletes once merged, so a path baked from one would silently brick
    # every adopter's push gate the day that worktree is pruned. And
    # dirname "$0" resolves to the TARGET repo under the natural
    # `cd <adopter-repo> && install-cr-gate.sh --target .` invocation.
    himmel_root=$(git -C "$SCRIPT_DIR" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p;1q')
    [ -f "$himmel_root/scripts/hooks/check-cr-before-push.sh" ] || himmel_root=$(dirname "$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)")
    [ -f "$himmel_root/scripts/hooks/check-cr-before-push.sh" ] || { echo "install-cr-gate: cannot locate himmel's primary checkout" >&2; exit 2; }
    baked_gate=$(to_native_path "$himmel_root/scripts/hooks/check-cr-before-push.sh")

    # REFUSE a gate path holding a newline or other control character
    # ([codex-2], round 4). The `gate=` line is %q-quoted and safe, but the
    # machine-readable `# himmel-cr-gate-path:` line is a COMMENT: a newline in
    # the path ends that comment and everything after it becomes SHELL SOURCE
    # in the generated hook. Refusing is the honest fix — a checkout path with
    # a control character in it is broken in a dozen other ways, and inventing
    # an encoding scheme (that --status would then have to decode) buys nothing.
    case "$baked_gate" in
        *[[:cntrl:]]*)
            echo "install-cr-gate: refusing — himmel's gate path contains a control character (newline/tab), which cannot be safely recorded in the generated hook: $(printf '%q' "$baked_gate")" >&2
            exit 2
            ;;
    esac

    new_content=$(build_hook_content "$baked_gate")
    if [ -e "$pre_push_hook" ]; then
        old_content=$(cat "$pre_push_hook" 2>/dev/null || true)
        if [ "$old_content" = "$new_content" ]; then
            echo "already-current"; exit 0
        fi
    fi
    mkdir -p "$hooks_dir" || { echo "install-cr-gate: cannot create hooks directory $hooks_dir" >&2; exit 2; }
    # $hooks_dir is now guaranteed to exist, so this resolves for real even
    # when it did not exist before this mkdir -p — including the case where
    # a not-yet-existing hooks_dir sat behind an ALREADY-existing symlinked
    # ancestor, which mkdir -p follows through regardless of the pre-check
    # above ([codex-1], CR round, HIMMEL-2035).
    hooks_dir_real=$(_real_dir "$hooks_dir")
    case "$hooks_dir_real/" in
        "$target_common_dir_real"/*|"$target_toplevel_real"/*) ;;
        *)
            echo "install-cr-gate: refusing — $hooks_dir resolves outside $TARGET (via a symlink); installing there would write into a location this repo does not own" >&2
            exit 2
            ;;
    esac
    # Write-then-rename ([codex-3]): a direct `> "$pre_push_hook"` truncates
    # first, so an interrupted or failing write leaves the adopter's repo with
    # a half-written pre-push. Stage in the same directory (rename is only
    # atomic within one filesystem) and move into place.
    tmp_hook="$pre_push_hook.himmel-tmp.$$"
    printf '%s\n' "$new_content" > "$tmp_hook" || { rm -f "$tmp_hook"; echo "install-cr-gate: cannot write $pre_push_hook" >&2; exit 2; }
    chmod +x "$tmp_hook" || { rm -f "$tmp_hook"; echo "install-cr-gate: cannot make $pre_push_hook executable" >&2; exit 2; }
    mv -f "$tmp_hook" "$pre_push_hook" || { rm -f "$tmp_hook"; echo "install-cr-gate: cannot install $pre_push_hook" >&2; exit 2; }
    echo "installed"; exit 0
}

if [ "$DO_STATUS" -eq 1 ]; then
    do_status
elif [ "$DO_REMOVE" -eq 1 ]; then
    do_remove
else
    do_install
fi
