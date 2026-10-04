#!/usr/bin/env bash
# skill-index/ensure-skill-index — idempotently build the /skill-find index
# and register it as the qmd 'skills' collection (HIMMEL-4302). Run by the
# himmelctl qmd install flow, so install and `himmelctl ensure` (which the
# update drift pass runs) both leave doctor C44-skill-index green.
#
# Registers the collection only; never runs `qmd embed` (no model download).
# qmd absent, or an index dir with no items, is a clean skip (rc 0): /skill-find
# is optional on a host without qmd.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/qmd-bin.sh
. "$REPO_ROOT/scripts/lib/qmd-bin.sh"

if ! has_qmd; then
    echo "ensure-skill-index: qmd not resolvable -- skipping (qmd is optional)"
    exit 0
fi

out_dir="${SKILL_INDEX_DIR:-$HOME/.claude/skill-index}"
bash "$SCRIPT_DIR/build-skill-index.sh" --out "$out_dir" || exit $?

if ! find "$out_dir" -maxdepth 1 -name '*.md' 2>/dev/null | grep -q .; then
    echo "ensure-skill-index: no skill items found under $out_dir -- not registering"
    exit 0
fi

# qmd_register_collection skips when 'skills' is already listed.
qmd_register_collection "$out_dir" skills
