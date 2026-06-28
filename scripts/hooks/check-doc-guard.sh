#!/usr/bin/env bash
# Doc-guard: block ADDING a himmel command/skill without updating its catalog.
# himmel-contributor-only (gated by .himmel-dev). pre-commit = staged set;
# --pre-push = push range. rc: 0 pass | 1 violation | 2 cannot-evaluate.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAP="$SCRIPT_DIR/doc-guard-map.tsv"

if [ "${DOC_GUARD_FORCE_ERR:-0}" = "1" ]; then
    echo "→ doc-guard: DOC_GUARD_FORCE_ERR=1 — forced cannot-evaluate" >&2; exit 2
fi
# shellcheck disable=SC1091
if ! . "$SCRIPT_DIR/../guardrails/lib.sh" 2>/dev/null; then
    echo "→ doc-guard: cannot source guardrails/lib.sh — fail-closed" >&2; exit 2
fi
# shellcheck disable=SC1091
if ! . "$SCRIPT_DIR/../lib/doc-guard-map.sh" 2>/dev/null; then
    echo "→ doc-guard: cannot source lib/doc-guard-map.sh — fail-closed" >&2; exit 2
fi
rc=0; is_himmel_dev_repo || rc=$?
[ "$rc" -eq 2 ] && { echo "→ doc-guard: cannot resolve repo root — fail-closed" >&2; exit 2; }
[ "$rc" -eq 1 ] && exit 0   # not a contributor checkout → no-op
if [ "${DOC_GUARD_OK:-0}" = "1" ]; then
    echo "→ doc-guard: DOC_GUARD_OK=1 — skipping (verify catalog manually)" >&2; exit 0
fi
[ -f "$MAP" ] || { echo "→ doc-guard: map file missing — fail-closed" >&2; exit 2; }

mode="${1:-pre-commit}"
if [ "$mode" = "--pre-push" ]; then
    db=$(default_branch)
    # On the default branch itself, or a detached HEAD: no feature-branch range
    # to check. is_on_main returns false on a detached HEAD (empty branch), so
    # check detached explicitly too — mirrors the .ps1 twin's `$branch -eq 'HEAD'`
    # skip and check-platforms-tested.sh's detached-HEAD handling.
    cur=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
    if [ "$cur" = "HEAD" ] || is_on_main; then exit 0; fi
    # Offline seam mirrors check-platforms-tested.sh (plan-critic r1, finding 3):
    # skip the fetch when DOC_GUARD_NO_FETCH=1, and on a known-offline clone with
    # no resolvable base, SKIP loudly rather than hard-block a legit offline push.
    [ "${DOC_GUARD_NO_FETCH:-0}" = "1" ] || git fetch -q origin "$db" 2>/dev/null || true
    base=""
    if git rev-parse --verify --quiet "origin/$db" >/dev/null; then base="origin/$db"
    elif git rev-parse --verify --quiet "$db" >/dev/null; then base="$db"
    elif [ "${DOC_GUARD_NO_FETCH:-0}" = "1" ]; then
        echo "→ doc-guard: no base + NO_FETCH — skipping (verify catalog manually)" >&2; exit 0
    else echo "→ doc-guard: no diff base after fetch — fail-closed" >&2; exit 2; fi
    if ! added=$(git diff --diff-filter=A --name-only "$base...HEAD" 2>/dev/null); then
        echo "→ doc-guard: cannot compute range diff — fail-closed" >&2; exit 2; fi
    touched=$(git diff --name-only "$base...HEAD" 2>/dev/null || true)
else
    added=$(git diff --cached --name-only --diff-filter=A)
    touched=$(git diff --cached --name-only)
fi
[ -z "$added" ] && exit 0

violations=""
# Read map via the shared loader, filtered to block+add (behaviour unchanged —
# the legacy 2 rows are now block+add; the new llms.txt row extends the gate).
# bash 3.2-safe: while-read, no assoc arrays.
while IFS=$'\t' read -r re doc; do
    [ -f "$doc" ] || continue        # path-keying: target doc absent → pair inert
    if printf '%s\n' "$added" | grep -qE "$re"; then
        if ! printf '%s\n' "$touched" | grep -qxF "$doc"; then
            hit=$(printf '%s\n' "$added" | grep -E "$re" | head -1)
            violations="${violations}     ${hit}  →  must also update ${doc}"$'\n'
        fi
    fi
done < <(dgm_rows "$MAP" block add)

[ -z "$violations" ] && exit 0
cat >&2 <<EOF
⛔ doc-guard: a command/skill was ADDED without updating its catalog.
$violations
   Fix: update the named doc in this change, or bypass for a doc-irrelevant
   add with  DOC_GUARD_OK=1 git commit ...  (per-session env, not a prefix).
EOF
exit 1
