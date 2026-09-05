#!/usr/bin/env bash
# Install the Himmel-owned pre-push migration hook that receives git's complete
# raw ref stream before pre-commit collapses it to PRE_COMMIT_* for local hooks.
set -uo pipefail

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "install-cr-pre-push-legacy: not a git repository" >&2
    exit 2
}
git_dir=$(git rev-parse --git-common-dir 2>/dev/null) || {
    echo "install-cr-pre-push-legacy: cannot resolve git common dir" >&2
    exit 2
}
case "$git_dir" in
    /*|[A-Za-z]:[/\\]*) ;;
    *) git_dir="$repo_root/$git_dir" ;;
esac

legacy_hook="$git_dir/hooks/pre-push.legacy"
owner_marker="# himmel-cr-ref-stream-v1"
if [ -e "$legacy_hook" ] && ! grep -Fq "$owner_marker" "$legacy_hook"; then
    echo "install-cr-pre-push-legacy: refusing to overwrite existing non-Himmel hook at $legacy_hook" >&2
    echo "Merge that hook with scripts/hooks/check-cr-before-push.sh manually, then re-run setup." >&2
    exit 2
fi

if ! mkdir -p "$(dirname "$legacy_hook")"; then
    echo "install-cr-pre-push-legacy: cannot create hooks directory" >&2
    exit 2
fi
if ! cat > "$legacy_hook" <<'HOOK'
#!/usr/bin/env bash
# himmel-cr-ref-stream-v1
# pre-commit migration hook: preserve the complete git pre-push ref stream.
#
# HIMMEL-1574: resolve the gate from the PRIMARY checkout, never from
# --show-toplevel. core.hooksPath points every worktree at the primary's
# .git/hooks, so this one file is shared — but --show-toplevel returns the
# WORKTREE root, which made each worktree exec its own base commit's stale
# copy of the gate. Any pre-push hardening then silently did not apply to
# worktrees created before it (fail-OPEN: the stale gate reports success).
# `git worktree list --porcelain` names the main worktree on its first line
# regardless of where .git lives or which worktree we run in; the git-common-dir
# parent is the fallback for shapes it cannot answer. Fail CLOSED if neither
# candidate holds the gate.
set -u
gate=""
push_gate=""
primary_root=$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p;1q')
if [ -n "$primary_root" ] && [ -f "$primary_root/scripts/hooks/check-cr-before-push.sh" ]; then
    gate="$primary_root/scripts/hooks/check-cr-before-push.sh"
    push_gate="$primary_root/scripts/hooks/check-push-target.sh"
else
    common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common_dir=""
    if [ -n "$common_dir" ] && [ -f "$(dirname "$common_dir")/scripts/hooks/check-cr-before-push.sh" ]; then
        gate="$(dirname "$common_dir")/scripts/hooks/check-cr-before-push.sh"
        push_gate="$(dirname "$common_dir")/scripts/hooks/check-push-target.sh"
    fi
fi
if [ -z "$gate" ]; then
    echo "pre-push.legacy: cannot locate scripts/hooks/check-cr-before-push.sh in the primary checkout — refusing the push" >&2
    exit 2
fi
if [ -z "$push_gate" ] || [ ! -f "$push_gate" ]; then
    echo "pre-push.legacy: cannot locate scripts/hooks/check-push-target.sh in the primary checkout — refusing the push" >&2
    exit 2
fi

# HIMMEL-2371: capture the ref stream ONCE and replay it to each gate in turn
# — stdin cannot be rewound, and both gates need the COMPLETE, undrained
# stream (the whole reason this migration hook exists: a pre-commit-configured
# hook never sees it — see check-push-target.sh's own header). This is what
# closes the multi-ref gap the pre-commit-configured shape alone cannot: that
# shape only exposes the FIRST pushed ref, so a `git push` naming a feature
# branch before main in the same invocation would slip past it; this hook
# always sees every ref line, in order.
ref_stream=$(cat)
if ! printf '%s\n' "$ref_stream" | bash "$push_gate"; then
    exit 1
fi
printf '%s\n' "$ref_stream" | bash "$gate" "$@"
exit $?
HOOK
then
    echo "install-cr-pre-push-legacy: cannot write $legacy_hook" >&2
    exit 2
fi
if ! chmod +x "$legacy_hook"; then
    echo "install-cr-pre-push-legacy: cannot make $legacy_hook executable" >&2
    exit 2
fi
echo "Himmel CR ref-stream hook installed at $legacy_hook"
