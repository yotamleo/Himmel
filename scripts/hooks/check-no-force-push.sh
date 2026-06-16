#!/usr/bin/env bash
# Pre-push hook: refuse force-push to protected refs (HIMMEL-136).
#
# Pre-commit framework wires this into the pre-push stage. Stdin
# contract (per git): "local_ref local_sha remote_ref remote_sha" per
# line, where:
# - remote_sha = 0000... if the remote ref does not exist (new branch).
# - Otherwise: remote_sha is the tip of the remote ref. A force-push is
#   detected when remote_sha is NOT reachable from local_sha
#   (i.e., the push would overwrite history on the remote).
#
# Behavior:
# - Force-push to main / refs/heads/main → hard refuse (exit 1).
# - Force-push to any other ref → warn (rc=0). Defense-in-depth; the
#   no-push-to-main hook already blocks any push to main, force or
#   otherwise. This hook adds explicit force-push framing + catches the
#   theoretical case where no-push-to-main is bypassed.
#
# Two-layer relationship (HIMMEL-212): this pre-push hook is the ref-level
# backstop — it sees only the remote/local SHAs (git's stdin contract), NOT the
# command flags, so it CANNOT tell `--force` from `--force-with-lease`. The
# lease-vs-bare distinction is enforced one layer up at PreToolUse: the
# `.claude/settings.json` deny-list blocks bare `git push --force` / `-f`, while
# `auto-approve-safe-bash.sh` grants a `--force-with-lease` push only on a
# non-main branch. The two layers AGREE: force-to-main is refused here and never
# granted there; a safe non-main lease push flows (granted upstream, warned here).
#
# Bypass: SKIP_FORCE_PUSH_GATE=1 git push --force-with-lease ...
#         (logs WARNING; only honored for non-main refs).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../guardrails/lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../guardrails/lib.sh"

z40="0000000000000000000000000000000000000000"
saw_force_main=0
saw_force_other=0
warn_lines=""

while read -r _local_ref local_sha remote_ref remote_sha; do
    # New remote branch (no existing remote tip) → not a force-push.
    if [ "$remote_sha" = "$z40" ] || [ -z "$remote_sha" ]; then
        continue
    fi
    # Deletion (local_sha is zero) → not a force-push of new content.
    if [ "$local_sha" = "$z40" ] || [ -z "$local_sha" ]; then
        continue
    fi
    # Force-push detection: remote_sha is NOT reachable from local_sha.
    # `git merge-base --is-ancestor A B` exits 0 if A is an ancestor of B.
    # If that's false, the local push rewrites history on the remote.
    if git merge-base --is-ancestor "$remote_sha" "$local_sha" 2>/dev/null; then
        # Fast-forward; not a force push.
        continue
    fi
    if is_main_ref "$remote_ref"; then
        cat >&2 <<EOF
ERROR: Force-push to 'main' is not allowed.
       Local SHA: $local_sha
       Remote SHA: $remote_sha (would be overwritten)

       No bypass available for main. Resolve via PR + merge instead.
EOF
        saw_force_main=1
    else
        warn_lines="${warn_lines}WARN: force-push detected on $remote_ref (local $local_sha vs remote $remote_sha)
"
        saw_force_other=1
    fi
done

if [ "$saw_force_main" -eq 1 ]; then
    exit 1
fi

if [ "$saw_force_other" -eq 1 ]; then
    if [ "${SKIP_FORCE_PUSH_GATE:-0}" = "1" ]; then
        printf '%s' "$warn_lines" >&2
        echo "→ no-force-push: SKIP_FORCE_PUSH_GATE=1 — warnings only, proceeding" >&2
        exit 0
    fi
    printf '%s' "$warn_lines" >&2
    echo "→ no-force-push: proceeding with force-push warnings (set SKIP_FORCE_PUSH_GATE=1 to silence)" >&2
    exit 0
fi

exit 0
