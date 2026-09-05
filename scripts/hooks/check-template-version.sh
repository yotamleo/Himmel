#!/usr/bin/env bash
# Template-version gate (HIMMEL-524): a commit/push that changes any
# template-OWNED file under templates/luna-second-brain/ MUST also bump the
# template's marketplace.json metadata.version — the stamp scripts/upgrade.sh
# compares against each vault's .vault-template.json. A content change with no
# bump ships "already current" and strands the change for every stamped vault,
# the 449/501/521 failure mode this closes structurally (HIMMEL-195).
#
# "Owned" = the upgrade.sh classifier's propagated-content classes
# (overwrite | threeway | jsonmerge); skip-class files (skip / skipexists /
# report — .vault-template.json, plugin assets, user content) do NOT fire. See
# owned_class() below: it is DERIVED FROM and MUST STAY IN SYNC WITH classify()
# in templates/luna-second-brain/scripts/upgrade.sh (the single source of truth
# — the case arms are copied verbatim so this gate tracks the classifier, not a
# hand-maintained second list).
#
# himmel-contributor-only (gated by the .himmel-dev marker), like doc-guard.
# pre-commit = staged set; --pre-push = push range.
# rc: 0 pass | 1 violation | 2 cannot-evaluate.
# Skips (exit 0) when jq is unavailable (mirrors check-template-himmel-plugins.sh
# — a missing optional tool must not block every contributor commit).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${TEMPLATE_VERSION_FORCE_ERR:-0}" = "1" ]; then
    echo "→ template-version: TEMPLATE_VERSION_FORCE_ERR=1 — forced cannot-evaluate" >&2; exit 2
fi
# shellcheck disable=SC1091
if ! . "$SCRIPT_DIR/../guardrails/lib.sh" 2>/dev/null; then
    echo "→ template-version: cannot source guardrails/lib.sh — fail-closed" >&2; exit 2
fi
rc=0; is_himmel_dev_repo || rc=$?
[ "$rc" -eq 2 ] && { echo "→ template-version: cannot resolve repo root — fail-closed" >&2; exit 2; }
[ "$rc" -eq 1 ] && exit 0   # not a contributor checkout → no-op
if [ "${TEMPLATE_VERSION_OK:-0}" = "1" ]; then
    echo "→ template-version: TEMPLATE_VERSION_OK=1 — skipping (verify the bump manually)" >&2; exit 0
fi

TEMPLATE_ROOT="templates/luna-second-brain"
MP_REL="marketplace/.claude-plugin/marketplace.json"
MP_REPO="$TEMPLATE_ROOT/$MP_REL"

# No early "$TEMPLATE_ROOT absent -> exit 0" short-circuit here on purpose: a
# WORKING-TREE dir check run before the diff is inspected would bypass the
# gate on exactly the case it exists to catch — deleting the entire template
# dir in this commit/range (HIMMEL-524 CR round 3). The owned-files collection
# below is diff-driven (git diff --name-only / --cached), so it still catches
# deletions even though the dir is now gone from the working tree; a checkout
# that genuinely never had the template (nothing touched under TEMPLATE_ROOT
# either) falls through to the owned_list emptiness check and exits 0 there.

# jq reads metadata.version out of git blobs (staged index, HEAD, range base).
command -v jq >/dev/null 2>&1 || { echo "→ template-version: jq not on PATH — skipping (verify the bump manually)" >&2; exit 0; }

# owned_class <rel> — print the upgrade.sh classifier class for a path RELATIVE
# to the template root. Copied verbatim from classify() in upgrade.sh so it stays
# structurally tied to the classifier; keep the two in sync. Owned (gate fires)
# = overwrite | threeway | jsonmerge; the rest are user-content / review-only.
owned_class() {
    case "$1" in
        _CLAUDE.md)                                   echo threeway ;;
        _Templates/*.md)                              echo report ;;
        .obsidian/community-plugins.json)             echo jsonmerge ;;
        .obsidian/plugins/*/data.json)                echo skipexists ;;
        .obsidian/plugins/*/main.js|.obsidian/plugins/*/manifest.json|.obsidian/plugins/*/styles.css) echo skipexists ;;
        .obsidian/PLUGINS-SETUP.md)                   echo overwrite ;;
        .obsidian/app.json|.obsidian/appearance.json|.obsidian/graph.json|.obsidian/core-plugins.json) echo overwrite ;;
        scripts/*)                                    echo overwrite ;;
        docs/*)                                       echo overwrite ;;
        .pre-commit-config.yaml)                      echo overwrite ;;
        marketplace/.claude-plugin/marketplace.json)  echo overwrite ;;
        .env.example|.gitignore|.gitattributes|.gitleaks.toml|README.md) echo overwrite ;;
        *)                                            echo skip ;;
    esac
}

# version_at <ref-path> — print metadata.version of the template marketplace.json
# at a git ref path (":<path>" = staged index, "HEAD:<path>", "<base>:<path>").
# Prints empty when the blob is absent at that ref or has no metadata.version.
version_at() {
    git show "$1" 2>/dev/null | jq -r '.metadata.version // empty' 2>/dev/null | tr -d '\r' || true
}

mode="${1:-pre-commit}"
if [ "$mode" = "--pre-push" ]; then
    db=$(default_branch)
    # On the default branch itself, or a detached HEAD: no feature-branch range
    # to check (mirrors check-doc-guard.sh).
    cur=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
    if [ "$cur" = "HEAD" ] || is_on_main; then
        echo "→ template-version: no feature-branch range (detached/default) — skipping" >&2; exit 0
    fi
    # Offline seam (mirrors check-doc-guard.sh): skip the fetch under NO_FETCH,
    # and on a known-offline clone with no resolvable base, SKIP loudly rather
    # than hard-block a legit offline push. A FAILED fetch (network blip, etc.)
    # is different: falling through would silently compare against a STALE
    # local origin/$db, which can carry an upstream version bump the branch
    # never earned — fail-closed instead (HIMMEL-524 CR round 5).
    if [ "${TEMPLATE_VERSION_NO_FETCH:-0}" != "1" ]; then
        git fetch -q origin "$db" 2>/dev/null || { echo "→ template-version: git fetch origin/$db failed — fail-closed (bypass: TEMPLATE_VERSION_NO_FETCH=1)" >&2; exit 2; }
    fi
    base=""
    if git rev-parse --verify --quiet "origin/$db" >/dev/null; then base="origin/$db"
    elif git rev-parse --verify --quiet "$db" >/dev/null; then base="$db"
    elif [ "${TEMPLATE_VERSION_NO_FETCH:-0}" = "1" ]; then
        echo "→ template-version: no base + NO_FETCH — skipping (verify the bump manually)" >&2; exit 0
    else echo "→ template-version: no diff base after fetch — fail-closed" >&2; exit 2; fi
    # --no-renames: name-only rename detection would report only the
    # destination path for a moved owned file, so the deleted source is never
    # classified and a rename-out-of-template silently escapes the gate
    # (HIMMEL-524 CR round 4). Force delete+add so both sides surface.
    # A FAILED diff must fail-closed too, not fall through as an empty
    # touched set — `|| true` here would turn "git couldn't evaluate the
    # range" into a silent pass (HIMMEL-524 CR round 5).
    if ! touched=$(git diff --no-renames --name-only "$base...HEAD" 2>/dev/null); then
        echo "→ template-version: cannot collect pre-push changes — fail-closed" >&2; exit 2
    fi
    cur_v="$(version_at "HEAD:$MP_REPO")"
    # prev_v must be read at the MERGE-BASE, not the base tip: the touched set
    # above is a three-dot diff (merge-base...HEAD), so the version comparison
    # has to match that same base or a post-split bump on main's tip falsely
    # clears a branch that never bumped (HIMMEL-524 CR).
    mb=$(git merge-base "$base" HEAD 2>/dev/null) || { echo "→ template-version: cannot resolve merge-base — fail-closed" >&2; exit 2; }
    prev_v="$(version_at "$mb:$MP_REPO")"
else
    # --no-renames: same rationale as the pre-push branch above — force
    # delete+add so a renamed owned file surfaces both sides. Fail-closed on
    # a diff failure too (HIMMEL-524 CR round 5) — see the pre-push branch.
    if ! touched=$(git diff --no-renames --cached --name-only); then
        echo "→ template-version: cannot collect staged changes — fail-closed" >&2; exit 2
    fi
    cur_v="$(version_at ":$MP_REPO")"
    prev_v="$(version_at "HEAD:$MP_REPO")"
fi

# Collect the owned template files among the touched set. bash 3.2-safe
# (while-read over a heredoc, no assoc arrays).
owned=""
while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
        "$TEMPLATE_ROOT"/*) rel="${f#"$TEMPLATE_ROOT"/}" ;;
        *) continue ;;
    esac
    case "$(owned_class "$rel")" in
        overwrite|threeway|jsonmerge) owned="${owned}${f}"$'\n' ;;
    esac
done <<EOF
$touched
EOF

owned_list="$(printf '%s' "$owned" | sed '/^$/d')"
[ -n "$owned_list" ] || exit 0

# A bump = the metadata.version value differs across the change set (staged vs
# HEAD for pre-commit; HEAD vs base for pre-push). String compare, not semver:
# the gap this closes is "version UNCHANGED while content shipped", and a plain
# inequality is portable (no sort -V) and catches exactly that.
if [ -n "$cur_v" ] && [ "$cur_v" != "$prev_v" ]; then
    exit 0
fi

cat >&2 <<EOF
⛔ template-version: template-OWNED content changed without bumping the template version.
$(printf '%s\n' "$owned_list" | sed 's/^/     /')

   marketplace.json metadata.version is the stamp /luna-upgrade compares against each
   vault's .vault-template.json: a content change with no bump reports "already current"
   and strands the change for every stamped vault (HIMMEL-449/501/521/524). Bump
   metadata.version in $MP_REPO within THIS change set.

   Bypass (per-session env, not a prefix):  TEMPLATE_VERSION_OK=1 git commit ...
EOF
exit 1
