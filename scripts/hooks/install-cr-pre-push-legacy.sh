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
set -u
repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "pre-push.legacy: cannot resolve repository root — refusing the push" >&2
    exit 2
}
exec bash "$repo_root/scripts/hooks/check-cr-before-push.sh" "$@"
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
