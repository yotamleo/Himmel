#!/usr/bin/env bash
# Smoke test for migrate-v1-to-v2.sh.
#
# Usage: bash marketplace/plugins/handover/scripts/test-migrate-v1-to-v2.sh
#
# Exit codes:
#   0 — all cases passed
#   1 — at least one case failed
set -uo pipefail
SLUG="hbtest$$"   # generated neutral test user-slug (not hardcoded)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MIGRATE="$SCRIPT_DIR/migrate-v1-to-v2.sh"
[ -x "$MIGRATE" ] || chmod +x "$MIGRATE"

pass=0
fail=0

fixture_setup() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir/handovers/$SLUG/epics" "$dir/handovers/$SLUG/standalones"

  # v1 item WITH Jira key
  mkdir -p "$dir/handovers/$SLUG/epics/#15-rename-himmel-and-jira/tasks"
  cat > "$dir/handovers/$SLUG/epics/#15-rename-himmel-and-jira/master-plan.md" <<'EOF'
---
template_version: 1
---
# #15 — rename-himmel-and-jira

**Status:** done
**Jira:** HIMMEL-15
EOF

  # v1 item WITHOUT Jira key (will be marked pending_jira_link with --no-jira-create)
  mkdir -p "$dir/handovers/$SLUG/standalones/#3-legacy-item"
  cat > "$dir/handovers/$SLUG/standalones/#3-legacy-item/brief.md" <<'EOF'
---
template_version: 1
---
# #3 — legacy-item

**Status:** done
EOF

  # Init the v1 counter
  printf "# Counter\nNext: 16\n" > "$dir/handovers/$SLUG/counter.md"
}

assert_dir_exists() {
  if [ -d "$1" ]; then
    pass=$((pass+1))
  else
    echo "FAIL: dir missing: $1"
    fail=$((fail+1))
  fi
}

assert_dir_absent() {
  if [ ! -d "$1" ]; then
    pass=$((pass+1))
  else
    echo "FAIL: dir should be gone: $1"
    fail=$((fail+1))
  fi
}

assert_grep() {
  local file="$1" pattern="$2"
  if grep -q "$pattern" "$file" 2>/dev/null; then
    pass=$((pass+1))
  else
    echo "FAIL: pattern '$pattern' not in $file"
    fail=$((fail+1))
  fi
}

# Case 1: items with Jira keys are renamed
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fixture_setup "$TMP"
"$MIGRATE" --root "$TMP" --no-jira-create --quiet >/dev/null 2>&1 || true
assert_dir_exists "$TMP/handovers/$SLUG/epics/HIMMEL-15-rename-himmel-and-jira"
assert_dir_absent "$TMP/handovers/$SLUG/epics/#15-rename-himmel-and-jira"
assert_grep "$TMP/handovers/$SLUG/epics/HIMMEL-15-rename-himmel-and-jira/master-plan.md" "template_version: 2"
assert_grep "$TMP/handovers/$SLUG/epics/HIMMEL-15-rename-himmel-and-jira/master-plan.md" "^jira: HIMMEL-15"

# Case 2: items without Jira keys stay #N when --no-jira-create
assert_dir_exists "$TMP/handovers/$SLUG/standalones/#3-legacy-item"
assert_grep "$TMP/handovers/$SLUG/standalones/#3-legacy-item/brief.md" "pending_jira_link: true"

# Case 3: re-running is idempotent
"$MIGRATE" --root "$TMP" --no-jira-create --quiet >/dev/null 2>&1 || true
assert_dir_exists "$TMP/handovers/$SLUG/epics/HIMMEL-15-rename-himmel-and-jira"
assert_dir_absent "$TMP/handovers/$SLUG/epics/#15-rename-himmel-and-jira"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
