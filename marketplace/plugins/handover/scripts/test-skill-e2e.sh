#!/usr/bin/env bash
# End-to-end verification of handover-v2 against the current state.
#
# Usage: bash marketplace/plugins/handover/scripts/test-skill-e2e.sh
#
# Exit codes:
#   0 — all checks pass
#   1 — at least one check failed
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
MIGRATE="$SCRIPT_DIR/migrate-v1-to-v2.sh"

pass=0
fail=0
note() { echo "[$1] $2"; }
ok() { pass=$((pass+1)); note OK "$1"; }
ko() { fail=$((fail+1)); note FAIL "$1"; }

# 1. Migration script executable
if [ -x "$MIGRATE" ]; then ok "migrate script executable"; else ko "migrate script not executable"; fi

# 2. Migration smoke test passes
if bash "$SCRIPT_DIR/test-migrate-v1-to-v2.sh" >/dev/null 2>&1; then
  ok "migrate smoke test"
else
  ko "migrate smoke test failed"
fi

# 3. Jira CLI builds + tests pass
if ( cd "$ROOT/scripts/jira" \
    && npm run build >/dev/null 2>&1 \
    && npm test >/dev/null 2>&1 ); then
  ok "jira CLI build + tests"
else
  ko "jira CLI build or tests failed"
fi

# 4. Every template is v2-tagged
v1_count=$(grep -lE '^template_version: 1' \
              "$ROOT/marketplace/plugins/handover/templates/"*.md 2>/dev/null \
           | wc -l)
if [ "$v1_count" -eq 0 ]; then ok "no v1 templates remain"; else ko "$v1_count v1 templates remain"; fi

# 5. SKILL.md references all v2 reference files
SKILL="$ROOT/marketplace/plugins/handover/skills/handover/SKILL.md"
refs=(v2-schema buckets sync hygiene routing init-register)
missing=0
for r in "${refs[@]}"; do
  grep -q "references/$r.md" "$SKILL" || { missing=$((missing+1)); echo "  miss: references/$r.md"; }
done
if [ "$missing" -eq 0 ]; then ok "SKILL.md references all v2 docs"; else ko "$missing references missing from SKILL.md"; fi

# 6. Post-migration himmel state: zero #N dirs (excluding .gitkeep)
nstale=$(find "$ROOT/handovers/yotam" -type d -name '#*' 2>/dev/null | wc -l)
if [ "$nstale" -eq 0 ]; then ok "no #N dirs in himmel state"; else ko "$nstale stray #N dirs in himmel state"; fi

# 7. status.md / roadmap.md / tech-debt.md all present in himmel
STATE="$ROOT/handovers/yotam"
for f in status.md roadmap.md tech-debt.md counter.md; do
  if [ -f "$STATE/$f" ]; then ok "$f exists"; else ko "$f missing"; fi
done

# 8. Every item has v2 frontmatter (template_version: 2)
v1_items=$(find "$ROOT/handovers/yotam" -type f -name '*.md' -exec grep -lE '^template_version: 1$' {} \; 2>/dev/null | wc -l)
if [ "$v1_items" -eq 0 ]; then ok "no v1 frontmatter in items"; else ko "$v1_items items still v1"; fi

echo "Total: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
