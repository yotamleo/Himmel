#!/usr/bin/env bash
# handover/auto-commit — auto-branch + commit + push handover mutations.
#
# HIMMEL-59 (v2) wedge HIMMEL-140: replaces the v1 direct-main path
# with a per-ticket feature-branch flow. Every mutation creates or
# reuses `<branch_prefix><TICKET>-<slug>` in the handover repo,
# commits there, and auto-pushes for resilience.
#
# - Mode B (external HANDOVER_DIR pointing at a separate git repo) only.
#   Mode A (inline <repo>/handovers/ on the himmel feature branch) is
#   REFUSED — auto-committing there would conflict with the operator's
#   in-progress feature work and might land handover noise in a feature PR.
# - Stage tracked + untracked *.md files under the resolved root, commit
#   on the per-ticket branch, push immediately.
# - Branch prefix sourced from `~/.claude/handover/registry.json` per-repo
#   (`branch_prefix` field; default `handover/` per HIMMEL-139). Falls
#   back to `handover/` if the registry is missing, malformed, or has
#   no entry for the resolved handover repo.
# - Ticket extraction: regex `[A-Z][A-Z0-9]+-[0-9]+` against the message.
#   First match wins. No Jira API call — keeps the script offline-friendly.
# - Slug source: the commit message with the ticket token removed,
#   lowercased, non-alnum → `-`, trimmed + capped at 30 chars.
# - Untagged messages (no ticket detected) → `handover/session-YYYY-MM-DD`
#   (UTC). Reuse-friendly within a single calendar day.
# - HANDOVER_DIRECT_MAIN=1 → restore v1 direct-on-current-branch behavior.
#   Kept as a feature flag until the v2 branching path is fully validated.
#
# Exit codes:
#   0  committed (or no changes — nothing to do)
#   1  usage / input error
#   2  required tool missing or environment unusable
#   3  Mode A (inline) — refused; nothing committed
#   4  commit failed (git error)
#   5  push failed (commit landed locally, push didn't)
#   6  branch create/checkout failed
#   7  single-writer repo parked off its default branch — refused
#
# .single-writer marker at the handover repo root (HIMMEL-571) → commit
# directly on the default branch (no per-ticket branch, no PR), the same
# path as HANDOVER_DIRECT_MAIN. Refuses (exit 7) if the repo is parked on a
# non-default branch rather than entangle handover state onto a feature branch.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/handover-path.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/handover-path.sh"

MESSAGE=""
DO_PUSH=1     # HIMMEL-140: push is on by default on the branched path.
NO_PUSH=0
DRY_RUN=0

usage() {
    cat <<'EOF'
Usage: auto-commit.sh <message> [--no-push] [--dry-run]
       auto-commit.sh --message "<text>" [--no-push] [--dry-run]

Auto-stages and commits *.md changes in the resolved handover root
(per scripts/lib/handover-path.sh). Mode B (external HANDOVER_DIR) only;
refuses on Mode A (inline) to avoid clobbering the feature branch.

Branched path (default, HIMMEL-140): switches to
`<branch_prefix><TICKET>-<slug>` (idempotent reuse), commits, and pushes.
Untagged messages fall back to `<branch_prefix>session-YYYY-MM-DD`.

Required:
  <message>         Commit subject as the first positional arg, OR
  --message <text>  via explicit flag. Either way it's prefixed "handover: ".

Optional:
  --no-push         Skip auto-push (useful for tests / offline).
  --push            (Legacy flag, no-op — kept for backward compat.)
  --dry-run         Show the plan, touch nothing.

Environment:
  HANDOVER_DIR              External handover repo root (required for Mode B).
  HANDOVER_DIRECT_MAIN=1    Skip branching; commit on the current branch
                            (v1 behavior). Default opt-out kept until the
                            branched path is fully validated.

A `.single-writer` marker at the handover repo root forces direct-on-default-
branch commits (no branch, no PR) and refuses (exit 7) if the repo is parked
on a non-default branch (HIMMEL-571).

The positional form lets the /handover-commit slash command pass
$ARGUMENTS unquoted (so trailing --no-push / --dry-run still parse as
flags, not as part of the message).
EOF
}

# Accept either positional message OR --message flag. If both are set,
# error — the operator's intent is ambiguous.
while [ $# -gt 0 ]; do
    case "$1" in
        --message)  MESSAGE="${2:-}"; shift 2 ;;
        --push)     DO_PUSH=1; shift ;;                       # legacy no-op
        --no-push)  NO_PUSH=1; shift ;;
        --dry-run)  DRY_RUN=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        --)         shift; while [ $# -gt 0 ]; do
                        if [ -z "$MESSAGE" ]; then MESSAGE="$1"; else MESSAGE="$MESSAGE $1"; fi
                        shift
                    done ;;
        -*)         echo "ERR auto-commit: unknown flag: $1" >&2; usage >&2; exit 1 ;;
        *)          # Positional — concatenate all positional args into the message
                    if [ -z "$MESSAGE" ]; then MESSAGE="$1"; else MESSAGE="$MESSAGE $1"; fi
                    shift
                    ;;
    esac
done

if [ "$NO_PUSH" -eq 1 ]; then DO_PUSH=0; fi

if [ -z "$MESSAGE" ]; then
    echo "ERR auto-commit: commit message is required (positional or --message)" >&2
    usage >&2
    exit 1
fi

if ! command -v git >/dev/null 2>&1; then
    echo "ERR auto-commit: required tool 'git' not on PATH" >&2
    exit 2
fi

# Resolve mode + root via the HIMMEL-118 resolver.
mode=$(handover_mode)
if [ "$mode" != "B" ]; then
    cat >&2 <<EOF
ERR auto-commit: Mode A (inline handovers in <repo>/handovers/) is not
supported by this MVP. Auto-committing there would land handover noise
on your active himmel feature branch and risk leaking into a feature PR.

To use auto-commit:
  1. Keep handover state in a separate repo (run /handover-setup to choose
     the location — it writes HANDOVER_DIR to .env).
  2. export HANDOVER_DIR=/abs/path/to/that/repo/handovers in the shell that
     launches Claude Code (or set it in .env; scripts/lib/load-dotenv.sh
     loads it).
  3. Re-run.

See HIMMEL-118 (handover root resolver) and HIMMEL-59 (this Epic) for
context on the deferred-branching design.
EOF
    exit 3
fi

if ! root=$(handover_root_ensure); then
    # _ensure prints its own error to stderr on rc=2. Use _ensure (not
    # pure handover_root) because auto-commit is a WRITE operation that
    # legitimately requires the Mode A inline dir to exist (HIMMEL-150).
    exit 2
fi

# Find the git repo that owns the root. Root may be a subdir of the
# external state repo (e.g. <state-repo>/handovers/ inside <state-repo>/),
# so walk up to the toplevel rather than assuming root == toplevel.
if ! handover_repo=$(git -C "$root" rev-parse --show-toplevel 2>&1); then
    echo "ERR auto-commit: handover root is not inside a git repo:" >&2
    echo "    root=$root" >&2
    echo "    git: $handover_repo" >&2
    exit 2
fi

# Refuse to operate on the himmel repo itself even if HANDOVER_DIR
# pathologically points inside it — defense in depth against a typo
# that made it past handover_mode's "B if env var set" check.
#
# Canonicalize both sides via realpath -m so Windows case-insensitive
# paths (C:/Users vs c:/users), trailing slashes, symlinks, and 8.3
# short names all normalize to the same string. Falls back to python
# on platforms missing GNU realpath (matches block-edit-on-main.sh's
# convention).
himmel_repo=$(git rev-parse --show-toplevel)
# shellcheck disable=SC2329  # used after definition below for handover_repo + root canonicalisation
canon() {
    local p="$1"
    if command -v realpath >/dev/null 2>&1; then
        p=$(realpath -m "$p" 2>/dev/null || echo "$p")
    elif command -v python3 >/dev/null 2>&1; then
        p=$(python3 -c "import sys, pathlib; print(pathlib.Path(sys.argv[1]).resolve(strict=False))" "$p")
    fi
    # On Git Bash / Cygwin, coerce to mixed-Windows style (C:/...) so paths
    # that arrived in msys form (/tmp/..., /c/...) line up with paths git
    # reports via `rev-parse --show-toplevel` (which resolves /tmp symlinks
    # to the real Windows path). Without this, `git -C $repo -- $root`
    # pathspec matching silently misses.
    if command -v cygpath >/dev/null 2>&1; then
        p=$(cygpath -m "$p" 2>/dev/null || printf '%s' "$p")
    fi
    printf '%s\n' "$p"
}
handover_canon=$(canon "$handover_repo")
himmel_canon=$(canon "$himmel_repo")
# On Windows / case-insensitive filesystems, lowercase both before
# comparing. Detect via OSTYPE — `msys`/`cygwin` cover gitbash + cygwin;
# `darwin` is also case-insensitive by default on most installs but
# users running case-sensitive APFS would over-match — accepting that
# small false-positive risk in exchange for catching the common case.
case "$OSTYPE" in
    msys*|cygwin*|win32*|darwin*)
        handover_canon=$(printf '%s' "$handover_canon" | tr '[:upper:]' '[:lower:]')
        himmel_canon=$(printf '%s' "$himmel_canon" | tr '[:upper:]' '[:lower:]')
        ;;
esac
if [ "$handover_canon" = "$himmel_canon" ]; then
    echo "ERR auto-commit: HANDOVER_DIR resolved inside the himmel repo ($handover_repo)." >&2
    echo "    Refusing — Mode B must point at a SEPARATE repo." >&2
    exit 3
fi

# Canonicalise $root and $handover_repo so they share a path style, then
# compute $rel_root (the path of $root relative to $handover_repo) for use
# as a git pathspec. Git's absolute-path pathspec matching is brittle on
# Git Bash (where /tmp/... vs C:/... vs /c/... all coexist), but a relative
# pathspec works in every shell.
root=$(canon "$root")
handover_repo=$(canon "$handover_repo")

case "$root" in
    "$handover_repo")        rel_root="." ;;
    "$handover_repo"/*)      rel_root="${root#"${handover_repo}"/}" ;;
    *)                       rel_root="" ;;
esac
if [ -z "$rel_root" ]; then
    echo "ERR auto-commit: handover root '$root' is not under handover repo '$handover_repo'" >&2
    exit 2
fi

# HIMMEL-140 helpers ----------------------------------------------------------

# Read branch_prefix for the handover repo from ~/.claude/handover/registry.json.
# Compares canonicalised, lowercased paths so Windows c:/ vs C:/ doesn't bite.
# Returns the literal default "handover/" on missing/malformed registry or no
# matching entry — fail-OPEN so handover writes still land even on a stale
# registry; the worst case is a feature branch with the default prefix.
_lookup_branch_prefix() {
    local repo="$1"
    local registry="$HOME/.claude/handover/registry.json"
    local default_prefix="handover/"
    if [ ! -f "$registry" ] || ! command -v jq >/dev/null 2>&1; then
        printf '%s' "$default_prefix"
        return
    fi
    local target
    target=$(canon "$repo" | tr '[:upper:]' '[:lower:]')
    local found
    found=$(jq -r --arg t "$target" '
        .repos // {} | to_entries[] |
        select(((.value.path // "") | ascii_downcase) == $t) |
        .value.branch_prefix // "handover/"' "$registry" 2>/dev/null | head -1)
    if [ -n "$found" ]; then
        printf '%s' "$found"
    else
        printf '%s' "$default_prefix"
    fi
}

# Compute target branch name from a commit message + the resolved prefix.
# Ticket regex matches the first PROJECT-N occurrence (uppercase project
# prefix + digits). When found: `<prefix><PROJECT-N>-<slug>` (slug from
# the rest of the message, lowercased, non-alnum -> dash, ≤30 chars).
# When not found: `<prefix>session-YYYY-MM-DD` (UTC).
_compute_branch_name() {
    local msg="$1" prefix="$2"
    local ticket="" rest="" slug=""
    if [[ "$msg" =~ ([A-Z][A-Z0-9]+-[0-9]+) ]]; then
        ticket="${BASH_REMATCH[1]}"
        rest="${msg//${ticket}/}"
    else
        rest="$msg"
    fi
    slug=$(printf '%s' "$rest" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
        | cut -c1-30 \
        | sed -E 's/-+$//')
    if [ -z "$ticket" ]; then
        printf '%ssession-%s' "$prefix" "$(date -u +%Y-%m-%d)"
        return
    fi
    if [ -z "$slug" ]; then
        printf '%s%s' "$prefix" "$ticket"
    else
        printf '%s%s-%s' "$prefix" "$ticket" "$slug"
    fi
}

# Switch to or create the target branch in handover_repo. Idempotent:
# - branch exists locally    -> checkout
# - branch exists on origin  -> checkout tracking branch
# - branch missing entirely  -> create off current HEAD
# Returns 0 on success, prints an error and exits with the branch-op
# exit code (6) on failure.
_switch_to_branch() {
    local repo="$1" target="$2" tmpfile
    tmpfile="/tmp/auto-commit.branch.err.$$"
    local current
    current=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [ "$current" = "$target" ]; then
        return 0
    fi
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$target"; then
        if ! git -C "$repo" checkout "$target" 2>"$tmpfile"; then
            echo "ERR auto-commit: failed to checkout existing branch $target:" >&2
            cat "$tmpfile" >&2
            rm -f "$tmpfile"
            exit 6
        fi
    elif git -C "$repo" ls-remote --exit-code --heads origin "$target" >/dev/null 2>&1; then
        # Fetch the remote branch so `refs/remotes/origin/<target>` exists
        # locally — without this, `--track origin/<target>` fails on a
        # fresh clone that hasn't yet fetched the branch (CR scenario:
        # machine A pushes the branch; machine B's clone is stale).
        # Fetch failure (network blip) is non-fatal — the subsequent
        # checkout will surface a clear error if the ref is still missing.
        git -C "$repo" fetch -q origin "$target" 2>/dev/null || true
        if ! git -C "$repo" checkout -b "$target" --track "origin/$target" 2>"$tmpfile"; then
            echo "ERR auto-commit: failed to checkout remote branch $target:" >&2
            cat "$tmpfile" >&2
            rm -f "$tmpfile"
            exit 6
        fi
    else
        if ! git -C "$repo" checkout -b "$target" 2>"$tmpfile"; then
            echo "ERR auto-commit: failed to create branch $target:" >&2
            cat "$tmpfile" >&2
            rm -f "$tmpfile"
            exit 6
        fi
    fi
    rm -f "$tmpfile"
    return 0
}

# Echo the repo's default branch name (origin/HEAD short name, minus the
# `origin/` prefix), or empty when it can't be determined. Used by the
# single-writer guard (HIMMEL-571) to decide whether HEAD is parked off the
# default branch. Empty result → guard treats the repo as on-default
# (fail-open: never mis-refuse a repo whose default we can't read).
_default_branch() {
    # `|| true` is load-bearing: under `set -o pipefail`, git's exit 128 when
    # refs/remotes/origin/HEAD is absent would propagate out of the pipeline
    # and (via the unguarded `sw_default=$(…)` call site under `set -e`) abort
    # the whole script. Swallow it so the function fails OPEN (empty stdout).
    git -C "$1" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null \
        | sed 's@^origin/@@' || true
}

# ----------------------------------------------------------------------------

# Resolve target branch BEFORE staging — switching with staged content is
# risky when the new branch's tree differs significantly from current HEAD.
# HANDOVER_DIRECT_MAIN=1 short-circuits the resolution and keeps v1
# behavior (commit on whatever branch is checked out). A .single-writer
# marker (HIMMEL-571) does the same but additionally guards that HEAD is on
# the default branch (sw_parked → refuse later, exit 7).
direct_reason=""
sw_parked=0
if [ "${HANDOVER_DIRECT_MAIN:-0}" = "1" ]; then
    target_branch=""
    direct_reason="HANDOVER_DIRECT_MAIN"
elif [ -f "$handover_repo/.single-writer" ]; then
    target_branch=""
    direct_reason=".single-writer"
    sw_default=$(_default_branch "$handover_repo")
    sw_current=$(git -C "$handover_repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [ -n "$sw_default" ] && [ "$sw_current" != "$sw_default" ]; then
        sw_parked=1
    elif [ -z "$sw_default" ]; then
        # Fail-open, but LOUD (himmel no-silent-failure): we can't tell whether
        # HEAD is the default branch, so we commit on the current branch rather
        # than refuse. Warn so the degraded path is debuggable.
        echo "WARN auto-commit: .single-writer repo but could not resolve origin/HEAD — committing on current branch '$sw_current' (run: git -C '$handover_repo' remote set-head origin -a)" >&2
    fi
else
    branch_prefix=$(_lookup_branch_prefix "$handover_repo")
    target_branch=$(_compute_branch_name "$MESSAGE" "$branch_prefix")
fi

# Pre-check: any *.md changes under root? Bail early if not — this also
# avoids a no-op branch switch that would surprise the operator.
# Use --untracked-files=all (-u) so newly created files surface as
# individual paths; without it, git collapses untracked directories to
# a single entry ("?? handovers/") and our `.md$` grep misses every
# file inside.
mdchanges=$(git -C "$handover_repo" status --porcelain --untracked-files=all -- "$rel_root" | grep -E '\.md$' || true)
if [ -z "$mdchanges" ] && [ "$DRY_RUN" -eq 0 ]; then
    echo "auto-commit: no *.md changes to commit — nothing to do."
    exit 0
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY auto-commit: mode=B root=$root repo=$handover_repo"
    if [ "$sw_parked" -eq 1 ]; then
        echo "DRY auto-commit: would REFUSE (exit 7): single-writer repo on non-default branch '$sw_current' — checkout '$sw_default' first"
        exit 0
    fi
    if [ -n "$target_branch" ]; then
        echo "DRY auto-commit: would switch to branch '$target_branch' (prefix='$branch_prefix')"
    else
        echo "DRY auto-commit: ${direct_reason} — would commit on current branch"
    fi
    echo "DRY auto-commit: would stage *.md under $root (rel: $rel_root)"
    if [ -z "$mdchanges" ]; then
        echo "DRY auto-commit: no *.md changes to commit"
    else
        while IFS= read -r _line; do echo "  $_line"; done <<< "$mdchanges"
    fi
    echo "DRY auto-commit: would commit with message: 'handover: ${MESSAGE}'"
    if [ "$DO_PUSH" -eq 1 ]; then
        if [ -n "$target_branch" ]; then
            echo "DRY auto-commit: would push origin $target_branch"
        else
            echo "DRY auto-commit: would push to origin"
        fi
    fi
    exit 0
fi

# Single-writer guard (HIMMEL-571): a .single-writer repo must commit on its
# default branch. If it's parked elsewhere, refuse rather than entangle the
# handover state onto a feature branch. Enforced AFTER the no-op early-exit
# above (a no-op stays a quiet exit 0) and BEFORE staging (nothing committed).
if [ "$sw_parked" -eq 1 ]; then
    echo "ERR auto-commit: single-writer repo '$handover_repo' is on '$sw_current', not the default branch '$sw_default'." >&2
    echo "    Handover state must land on '$sw_default'. Run: git -C '$handover_repo' checkout $sw_default" >&2
    exit 7
fi

# Switch to the target branch on the branched path. Done BEFORE staging
# so the index lands cleanly on the target branch's tree.
if [ -n "$target_branch" ]; then
    _switch_to_branch "$handover_repo" "$target_branch"
fi

# Stage anything *.md under $root that's tracked-modified or untracked.
# Use `git add` with the root path; git takes care of recursion.
git -C "$handover_repo" add -A -- "$rel_root"

# Filter to only *.md changes — if the operator scribbled non-md files,
# unstage them so this commit stays handover-scoped.
non_md_staged=$(git -C "$handover_repo" diff --cached --name-only --relative=. | grep -Ev '\.md$' || true)
if [ -n "$non_md_staged" ]; then
    echo "auto-commit: dropping non-md files from staged set:" >&2
    while IFS= read -r _line; do echo "  $_line" >&2; done <<< "$non_md_staged"
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        git -C "$handover_repo" reset HEAD -- "$f" >/dev/null
    done <<< "$non_md_staged"
fi

# Anything left?
if git -C "$handover_repo" diff --cached --quiet; then
    echo "auto-commit: no *.md changes to commit — nothing to do."
    exit 0
fi

# Commit. Prefix the message so handover commits are greppable.
if ! git -C "$handover_repo" commit -m "handover: ${MESSAGE}" 2>/tmp/auto-commit.err.$$; then
    echo "ERR auto-commit: git commit failed:" >&2
    cat /tmp/auto-commit.err.$$ >&2
    rm -f /tmp/auto-commit.err.$$
    exit 4
fi
rm -f /tmp/auto-commit.err.$$

new_sha=$(git -C "$handover_repo" rev-parse --short HEAD)
if [ -n "$target_branch" ]; then
    echo "auto-commit: committed ${new_sha} on ${target_branch} (handover: ${MESSAGE})"
else
    echo "auto-commit: committed ${new_sha} (handover: ${MESSAGE})"
fi

if [ "$DO_PUSH" -eq 1 ]; then
    # On the branched path, use `-u` so subsequent pushes are no-prompt
    # for the same branch. The set-upstream is idempotent.
    if [ -n "$target_branch" ]; then
        push_args=(-u origin "$target_branch")
    else
        push_args=()
    fi
    if ! git -C "$handover_repo" push "${push_args[@]}" 2>/tmp/auto-commit.err.$$; then
        echo "ERR auto-commit: git push failed (commit ${new_sha} is local-only):" >&2
        cat /tmp/auto-commit.err.$$ >&2
        rm -f /tmp/auto-commit.err.$$
        exit 5
    fi
    rm -f /tmp/auto-commit.err.$$
    # HIMMEL-141: best-effort PR open/update on the branched path.
    # Skipped when HANDOVER_PR_AUTO=0, when not on a handover/* branch,
    # or when pr-open.sh is missing. Failures inside pr-open are
    # already treated as best-effort (exit 0); auto-commit must never
    # fail because of a PR-layer issue.
    pr_open_script="$SCRIPT_DIR/pr-open.sh"
    if [ -n "$target_branch" ] \
        && [ "${HANDOVER_PR_AUTO:-1}" != "0" ] \
        && [ -f "$pr_open_script" ]; then
        ( cd "$handover_repo" && bash "$pr_open_script" 2>&1 ) | sed 's/^/auto-commit (pr-open): /' || true
    fi
    echo "auto-commit: pushed."
fi
exit 0
