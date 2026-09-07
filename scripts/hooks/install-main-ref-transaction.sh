#!/usr/bin/env bash
# Install the HIMMEL-2095 main-branch reference-transaction guard.
#
# `pre-commit install --hook-type` does NOT support "reference-transaction"
# (its own --help lists only commit-msg, post-checkout, post-commit,
# post-merge, post-rewrite, pre-commit, pre-merge-commit, pre-push,
# pre-rebase, prepare-commit-msg) -- that is exactly why this installer
# exists, mirroring install-cr-pre-push-legacy.sh's reason for being (a hook
# type pre-commit cannot wire, installed as a tiny shim that execs the
# tracked, reviewable, testable script).
#
# PLATFORM GUARD (no .ps1 twin -- this note is that decision, not a
# placeholder for one): this script is plain POSIX shell, so under Git Bash
# on Windows it would run and install correctly the same way it does on
# Linux/macOS -- nothing here needs a PowerShell-specific rewrite. The real
# gap is that it is never INVOKED there at all: `scripts/setup.sh` and
# `scripts/setup-hooks.sh` both call this installer, but their Windows twin
# `scripts/setup-hooks.ps1` has no call to it whatsoever -- so a Windows
# station's setup run installs every OTHER hook and silently skips this one,
# leaving main completely unguarded with no error, no warning, nothing in
# `himmel-doctor` to catch it until C32 happens to be checked from a git
# context that can see it. That gap is HIMMEL-2638, tracked deliberately
# rather than closed here (this session cannot test PowerShell). A future
# `.ps1` twin -- or a call to this same script added to `setup-hooks.ps1` --
# is what resolves it; this note exists so nobody mistakes "no twin" for
# "no gap".
#
# THE STANDING LESSON on this guard, five review rounds deep now: writing a
# file that LOOKS like protection is not protection, and re-deriving either
# "where does git look" or "how do I safely embed one string in another"
# keeps re-opening the gap in new ways.
#   Round 1: a shim that fails on its own broken target must fail OPEN, not
#     brick the repo (reference-transaction fires on EVERY ref update, not
#     just main -- see the shim's own comment, below).
#   Round 2: three instances of "we wrote the file" != "git runs it" --
#     core.hooksPath, when set, is the ONLY place git looks (ignoring
#     .git/hooks/ entirely); a lost +x bit is silently ignored by git on
#     Unix; and the target path was interpolated unescaped into the shim,
#     breakable by a checkout path containing `$`/backtick/`"`.
#   Round 3: TWO more, both in HOW this installer answers "where does git
#     look" -- a RELATIVE core.hooksPath resolves PER WORKTREE (breaking
#     the shared-common-dir guarantee this installer otherwise relies on),
#     and `git rev-parse --git-common-dir`'s own output is relative to the
#     INVOKING DIRECTORY, not the worktree top, so joining it against
#     repo_root computed the WRONG path when run from a subdirectory. Both
#     closed the same way: stop re-deriving the answer and ask git for it
#     directly. `git rev-parse --path-format=absolute --git-path hooks` is
#     git's OWN resolution of "where does a hook file belong" -- already
#     correct for core.hooksPath unset/relative/absolute, already correct
#     from any invoking cwd, already correct per-worktree. This repo's own
#     scripts/cr/install-cr-gate.sh and pr-check-context.sh already rely on
#     `--path-format=absolute` unconditionally; matched here rather than
#     hand-rolling a fourth variant of the same arithmetic.
#   Round 4: `himmel-doctor`'s check_c32 used to `eval` a `target=...` line
#     extracted from the installed hook file to learn the target path,
#     gated on a marker comment that authenticates NOTHING (it's a comment,
#     copyable by anyone) -- a hook carrying the marker plus a hostile
#     `target=$(...)` executed arbitrary commands during a supposedly
#     read-only doctor run. "Fixed" by carrying the target in a SECOND,
#     literal comment form instead, read verbatim and never parsed as code.
#   Round 5: that literal comment form was ITSELF a third hand-rolled
#     representation of "embed this string, then read it back safely" -- and
#     it broke the same way its predecessors did: an embedded NEWLINE byte
#     in the checkout path (legal on POSIX filesystems) terminates the
#     comment line early and injects a new line of shell into the file.
#     Two rounds of "make this specific embedding safe" is the signature of
#     patching a SHAPE rather than removing the shape's reason to exist.
#     There IS a representation of one string with no escaping question at
#     all here: `git config`. Git's own config subsystem already solves
#     "store an arbitrary byte string associated with this repo, retrieve
#     it exactly" -- newlines, quotes, `$`, backticks, none of it needs any
#     escaping WE write, because `git config --local <key> <value>` and
#     `git config --local --get <key>` round-trip the value exactly via
#     git's own tested reader/writer, shared automatically across every
#     linked worktree (proven empirically: set from one worktree, read back
#     byte-identical from another, including a value containing a literal
#     embedded newline). So: the check-script path now lives in EXACTLY ONE
#     place, `git config --local himmel-main-ref.target <path>`, set once by
#     this installer. The generated shim is now fully STATIC -- the same
#     bytes for every install, everywhere, with NO per-checkout
#     interpolation of the path at all -- and reads the value back the same
#     way at hook-run time. `himmel-doctor`'s check_c32 reads it the exact
#     same way. Nothing is ever parsed out of the hook FILE's content beyond
#     the marker-presence check; there is no third format left to get wrong.
#   Round 6: TWO more, both about the worktree-coverage loop this installer
#     added in round 3. First, that loop only ran when THIS invocation's own
#     core.hooksPath read as relative -- but `extensions.worktreeConfig`
#     lets any ONE worktree override core.hooksPath independently, so
#     "usually shared" was never the same fact as "always shared"; fixed by
#     dropping the classification and always enumerating every worktree,
#     resolving each one's own hooks directory independently. Second: the
#     enumeration itself parsed `git worktree list --porcelain`'s
#     newline-delimited output line-by-line -- the SAME "an embedded newline
#     in a path breaks plain-text parsing" lesson round 5 had JUST designed
#     out of the target path, reappearing one line later on the worktree
#     PATH itself. Fixed with `--porcelain -z` (NUL-terminated fields) read
#     via `read -r -d ''`, fed by process substitution rather than captured
#     into a variable first (a captured `$(cmd -z)` truncates at the first
#     NUL byte -- bash cannot store one in a variable).
#   Round 7: TWO more, both "partial coverage reported as exit 0". First
#     (panel round 6): the per-worktree loop above could fail SOME locations
#     and still `exit 0` if at least one succeeded -- a caller checking only
#     the exit code could not tell full coverage from partial. Fixed:
#     `fail_count > 0` now exits non-zero (successful installs are still
#     KEPT, there is no rollback). Second (panel round 8): the SEPARATE
#     fallback below -- when enumeration itself fails and this script can
#     install only into the current worktree -- had the exact same property
#     and the round-6 fix did not reach it: a successful single-worktree
#     install still reported exit 0 even though this script has no idea
#     whether OTHER worktrees exist and are left uncovered. Fixed the same
#     way: that path now forces a non-zero exit (`enumeration_failed`)
#     regardless of whether its own single install succeeded.
#
# GIT VERSION: every `--path-format=absolute` call below (there are three:
# the per-worktree loop, and the single-worktree fallback) needs git >=
# 2.31 -- but this repo's declared minimum is git 2.30
# (docs/setup/new-machine.md, scripts/install/deps.json). CodeRabbit (PR
# #2195) caught the SAME exposure in himmel-doctor.sh's C32; a first pass
# at fixing both here concluded that an unsupported `--path-format` simply
# makes `rev-parse` fail, so a 2.30 station would loudly refuse rather than
# install anything -- THAT CONCLUSION WAS WRONG, and was reported as fact
# without being tested. Proven directly on this station instead of
# reasoned about: `git rev-parse --totally-unknown-option --git-path
# hooks` prints the unknown option back as an ordinary output line, THEN
# the (relative, since the format request was never honoured) resolved
# path -- and still exits 0. `git rev-parse` does not reject options it
# does not recognise; it echoes them. So on git < 2.31, `rev-parse
# --path-format=absolute --git-path hooks` returns rc=0 with a
# multi-line, non-absolute value -- NOT an error -- and this script would
# have installed the guard at a bogus path built from that garbage while
# reporting success, the exact "looks protected, is not" class this whole
# ticket exists to close. The fix (below, `looks_like_absolute_path`) does
# not trust the exit status at all: every `--path-format=absolute` result
# is validated as an actual single-line absolute path before use, which
# closes this regardless of which git versions echo which options --
# validating the VALUE does not require trusting our own reading of
# version-specific behaviour the way a version check would.
set -uo pipefail

# looks_like_absolute_path VALUE -- true only if VALUE is a plausible
# absolute path (POSIX /... or a Windows drive-letter form), used to
# validate every `git rev-parse --path-format=absolute ...` result before
# trusting it (see the GIT VERSION note above for why exit status alone is
# not proof: older git echoes an unrecognised --path-format back as output
# and still exits 0). Deliberately NOT also rejecting embedded newlines --
# a worktree whose own path legitimately contains one is already covered
# elsewhere in this installer and in check-main-ref-transaction.sh's test
# suite (the newline-worktree-path case), and a genuine absolute path
# still starts with `/` (or a drive letter) regardless of what it
# contains further in -- while the garbage this validates against starts
# with the echoed option text itself (`-`), which this prefix check alone
# already rejects.
looks_like_absolute_path() {
    case "$1" in
        /*|[A-Za-z]:[/\\]*) return 0 ;;
        *) return 1 ;;
    esac
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
check_script="$SCRIPT_DIR/check-main-ref-transaction.sh"
if [ ! -f "$check_script" ]; then
    echo "install-main-ref-transaction: cannot find $check_script -- refusing to install" >&2
    exit 2
fi

git rev-parse --show-toplevel >/dev/null 2>&1 || {
    echo "install-main-ref-transaction: not a git repository" >&2
    exit 2
}

# THE single authoritative value (round 5 above): stored ONCE via git
# config, shared automatically by every linked worktree of this repo
# (`--local` writes the shared repo config, not a per-worktree override --
# proven empirically; `extensions.worktreeConfig` does not change this
# unless `--worktree` is explicitly requested, which this never does).
# Idempotent: setting the same key to the same value twice is a no-op as
# far as anything downstream can observe.
if ! git config --local himmel-main-ref.target "$check_script"; then
    echo "install-main-ref-transaction: could not record the target in git config (himmel-main-ref.target) -- refusing to install" >&2
    exit 2
fi

# install_one_hook HOOK_PATH -- idempotent single-location installer for the
# STATIC shim (see round 5 above: no per-checkout data is interpolated into
# it at all, so the same bytes are written everywhere). Prints its own
# diagnostics; returns 0 on success, nonzero on failure (a foreign hook
# already there, or a write/chmod failure).
install_one_hook() {
    local hook_path="$1"
    local owner_marker="# himmel-main-ref-transaction-v1"
    if [ -e "$hook_path" ] && ! grep -Fq "$owner_marker" "$hook_path"; then
        echo "install-main-ref-transaction: refusing to overwrite existing non-Himmel hook at $hook_path" >&2
        echo "Merge that hook with scripts/hooks/check-main-ref-transaction.sh manually, then re-run setup." >&2
        return 2
    fi
    if ! mkdir -p "$(dirname "$hook_path")"; then
        echo "install-main-ref-transaction: cannot create hooks directory for $hook_path" >&2
        return 2
    fi
    if ! cat > "$hook_path" <<'HOOK'
#!/usr/bin/env bash
# himmel-main-ref-transaction-v1
# Shim installed by scripts/hooks/install-main-ref-transaction.sh
# (HIMMEL-2095). Runs the tracked, reviewable check script via bash
# EXPLICITLY (never relying on the target's own exec bit surviving every
# checkout/platform) -- "$@" and stdin (the reference-transaction line
# stream) pass through unchanged.
#
# This file is 100% STATIC -- identical bytes at every install site, no
# per-checkout path baked in here at all. The one variable (which checkout
# to run) lives in `git config --local himmel-main-ref.target`, set once by
# the installer and shared automatically across every linked worktree; see
# that installer's own header for why (round 5: no escaping question left
# to get wrong, because git's own config subsystem already solved "store
# and retrieve one arbitrary string exactly").
#
# FAIL-OPEN, DELIBERATELY: if the configured target is missing, unreadable,
# not a regular file, or was never configured at all (the checkout that ran
# the installer got moved, renamed, or pruned; or install never ran), ALLOW
# rather than refuse. reference-transaction fires on EVERY ref update in
# this repo (fetch's refs/remotes/*, stash, tags, every branch), so
# treating a broken target as a refusal would fail every such operation
# repo-wide, recoverable only by knowing to delete this untracked file.
# Silently-absent protection is strictly better than a bricked repo; see
# this installer's own header for the full rationale. `himmel-doctor`
# check C32 is the structural catch for exactly this state.
#
# `-f`, not just `-r` (round 9): the target is always the installer-set
# path to check-main-ref-transaction.sh, so there is no realistic route by
# which it becomes a directory -- but `[ -r DIR ]` is TRUE for a readable
# directory, so a bare readability check would have let that shape reach
# `exec bash "$target"` below, where bash fails on a directory argument and
# this hook would FAIL-CLOSED instead of fail-open: every ref update in the
# repo refused, recoverable only by deleting an untracked file no `git
# diff` ever shows -- the exact brick this whole guard was designed
# against. Negligible probability, catastrophic and near-undiagnosable
# impact, one-line fix: worth guarding on purpose, not dead weight to
# simplify away.
target=$(git config --local --get himmel-main-ref.target 2>/dev/null)
if [ -z "$target" ] || [ ! -f "$target" ] || [ ! -r "$target" ]; then
    echo "reference-transaction (himmel-main-ref-transaction-v1): target check script unconfigured/missing/unreadable/not-a-regular-file: '$target' -- ALLOWING this ref update unconditionally (the main-branch guard is NOT protecting; re-run: bash <repo>/scripts/hooks/install-main-ref-transaction.sh)" >&2
    # DRAIN STDIN before exiting -- check-main-ref-transaction.sh's own
    # header states the contract this shim must honour too: git writes ONE
    # line per ref in the transaction, and a transaction can carry many
    # (a `fetch` touching hundreds of refs/remotes/* at once). Exiting here
    # without reading would leave git writing into a pipe nobody drains --
    # once the kernel buffer fills, git sees a broken pipe and the
    # operation can fail outright, which is exactly the outcome this
    # fail-open branch exists to avoid.
    cat >/dev/null
    exit 0
fi
exec bash "$target" "$@"
HOOK
    then
        echo "install-main-ref-transaction: cannot write $hook_path" >&2
        return 2
    fi
    if ! chmod +x "$hook_path"; then
        echo "install-main-ref-transaction: cannot make $hook_path executable" >&2
        return 2
    fi
    # Verify the bit actually took -- git silently ignores a non-executable
    # hook on Unix, so a chmod that reported success but didn't stick (an
    # unusual filesystem/mount) must not be reported as installed.
    if [ ! -x "$hook_path" ]; then
        echo "install-main-ref-transaction: $hook_path is not executable after chmod +x -- refusing to report success" >&2
        return 2
    fi
    echo "Himmel main-branch reference-transaction guard installed at $hook_path"
    return 0
}

# ALWAYS enumerate and resolve EVERY EXISTING linked worktree individually
# -- never assume core.hooksPath is shared just because THIS invocation's
# own value is unset or absolute (panel round 4, codex-1): `extensions.
# worktreeConfig` lets any ONE worktree override core.hooksPath
# independently of the others, so "usually shared" is not the same fact as
# "always shared" -- this is a security guard, and an earlier version's
# single-install shortcut for the unset/absolute case silently trusted that
# assumption. `git worktree list` always lists every worktree regardless of
# which one is invoking (including this one), and `git -C <worktree>
# rev-parse --path-format=absolute --git-path hooks` resolves EACH
# worktree's own hooks directory correctly no matter how core.hooksPath
# ended up set there (shared, absolute, or a per-worktree override) -- so
# looping unconditionally is both simpler and correct, replacing what used
# to be a hookspath-value classification plus two separate code paths.
#
# SCOPE, stated plainly (a Suggestion this installer accepts as a real,
# documented limitation rather than silently ignoring): this only covers
# worktrees that exist AT INSTALL TIME. A worktree created afterwards has
# no shim of its own and can move refs/heads/main unguarded until this
# installer is re-run. There is no git hook for "a worktree was just
# created" to hang an automatic re-install off; the honest fix is
# operational, not code -- re-run this installer (or scripts/setup.sh /
# scripts/setup-hooks.sh, which call it) after `git worktree add`. See
# enforcement.md.
ok_count=0
fail_count=0
enumeration_failed=0

# `-z` (panel round 4, codex-2): plain `git worktree list --porcelain`
# newline-delimited output treats a worktree path that itself contains a
# literal newline byte (legal on POSIX filesystems) as if it ended at that
# newline -- the SAME "parse structured git output as plain text and get
# bitten by an embedded newline" lesson this ticket already designed OUT of
# the target path (round 5), now reappearing on the enumeration side. `-z`
# NUL-terminates each field instead, so `read -r -d ''` below reads a
# worktree path's embedded newline as ordinary path content rather than a
# field boundary. Fed via process substitution, NOT captured into a
# variable first -- `x=$(cmd -z)` truncates at the first NUL byte (bash
# cannot store one in a variable), which would silently re-break this the
# same way capturing into a plain `worktree_list` variable used to.
while IFS= read -r -d '' wt_field; do
    case "$wt_field" in
        "worktree "*)
            wt_path="${wt_field#worktree }"
            wt_hooks_dir=$(git -C "$wt_path" rev-parse --path-format=absolute --git-path hooks 2>/dev/null) || wt_hooks_dir=""
            # Validate the VALUE, not just the exit status -- see the GIT
            # VERSION note above: git < 2.31 echoes an unrecognised
            # --path-format=absolute back as output and still exits 0.
            if ! looks_like_absolute_path "$wt_hooks_dir"; then
                echo "install-main-ref-transaction: could not resolve an absolute hooks directory for worktree $wt_path (got: '$wt_hooks_dir') -- skipping (NOT covered; this repo needs git >= 2.31 for --path-format, see this installer's own GIT VERSION note)" >&2
                fail_count=$((fail_count + 1))
                continue
            fi
            if install_one_hook "$wt_hooks_dir/reference-transaction"; then
                ok_count=$((ok_count + 1))
            else
                fail_count=$((fail_count + 1))
            fi
            ;;
    esac
done < <(git worktree list --porcelain -z 2>/dev/null)

if [ "$ok_count" -eq 0 ] && [ "$fail_count" -eq 0 ]; then
    # Enumeration itself produced nothing at all (old git without -z
    # support, or some other failure) -- fall back to installing only into
    # this worktree, so a genuine enumeration failure still leaves SOME
    # protection rather than none. This is ITSELF the partial-coverage case
    # (panel round 8, codex-2): enumeration failing means this script has
    # NO IDEA whether other worktrees exist, so even a successful install
    # here can only ever mean "this one location is covered" -- never
    # "every location is covered". Recorded via enumeration_failed, not
    # fail_count (there was no per-location failure to count -- the failure
    # is that enumeration could not tell us how many locations there are),
    # but it must drive the SAME non-zero-exit-on-anything-less-than-full-
    # coverage policy the fail_count>0 branch below enforces, or this path
    # keeps the exact "partial coverage indistinguishable from full
    # coverage" property that policy exists to prevent.
    echo "install-main-ref-transaction: could not enumerate worktrees (git worktree list --porcelain -z produced no output) -- installing only into this worktree; others are NOT covered" >&2
    enumeration_failed=1
    this_hooks_dir=$(git rev-parse --path-format=absolute --git-path hooks 2>/dev/null) || this_hooks_dir=""
    # Validate the VALUE, not just the exit status -- see the GIT VERSION
    # note above: git < 2.31 echoes an unrecognised --path-format=absolute
    # back as output and still exits 0.
    if ! looks_like_absolute_path "$this_hooks_dir"; then
        echo "install-main-ref-transaction: could not resolve an absolute hooks directory for this worktree (got: '$this_hooks_dir') -- refusing to install (this repo needs git >= 2.31 for --path-format, see this installer's own GIT VERSION note)" >&2
        exit 2
    fi
    if install_one_hook "$this_hooks_dir/reference-transaction"; then
        ok_count=$((ok_count + 1))
    else
        fail_count=$((fail_count + 1))
    fi
fi

if [ "$ok_count" -eq 0 ]; then
    echo "install-main-ref-transaction: every install attempt failed ($fail_count failure(s)) -- refusing to report success" >&2
    exit 2
fi
if [ "$fail_count" -gt 0 ]; then
    # Partial failure (panel round 6, codex-2): some location(s) DID get the
    # guard installed -- those are kept, there is no rollback -- but a
    # caller that only checks this script's exit code must be able to tell
    # "every location is protected" apart from "some are, some are not".
    # Reporting exit 0 here made that impossible: a partially-covered repo
    # looked identical to a fully-covered one to anything scripting against
    # this installer. Exit non-zero so partial coverage is never
    # indistinguishable from complete coverage, while still leaving every
    # successfully-installed hook in place.
    echo "install-main-ref-transaction: WARNING: $fail_count of $((ok_count + fail_count)) location(s) did NOT get the guard installed (see above) -- those are NOT protected" >&2
    exit 1
fi
if [ "$enumeration_failed" -eq 1 ]; then
    echo "install-main-ref-transaction: WARNING: worktree enumeration failed, so coverage of any worktree OTHER than this one is UNKNOWN (not confirmed installed, not confirmed absent) -- re-run from each worktree individually to be sure" >&2
    exit 1
fi
exit 0
