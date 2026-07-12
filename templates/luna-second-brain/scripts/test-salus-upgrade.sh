#!/usr/bin/env bash
# Hermetic integration test for the salus PROFILE GATE in upgrade.sh.
# Asserts: a vault that opted in (.salus-profile) gets the medic skill + egress
# floor refreshed with operator content preserved; a NON-medical vault never
# receives the egress floor (which would break its MCP/web workflows).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_SRC="$(cd "$HERE/.." && pwd)"

fails=0
ok()  { echo "  ok   - $1"; }
bad() { echo "  FAIL - $1" >&2; fails=$((fails+1)); }
chk() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

WORK="$(mktemp -d 2>/dev/null || mktemp -d -t salusupg)"
trap 'rm -rf "$WORK"' EXIT

# --- hermetic template: copy the real template, bump its version high ---
TPL="$WORK/template"
mkdir -p "$TPL"
cp -R "$TEMPLATE_SRC/scripts" "$TPL/scripts"
cp -R "$TEMPLATE_SRC/_profiles" "$TPL/_profiles"
mkdir -p "$TPL/marketplace/.claude-plugin"
printf '{ "metadata": { "version": "99.0.0" }, "plugins": [] }\n' \
  > "$TPL/marketplace/.claude-plugin/marketplace.json"

# minimal vault factory: a stamped (old-version) vault, optionally medical
make_vault() {
  local dir="$1" medical="$2"
  mkdir -p "$dir"
  printf '{"template":"luna-second-brain","version":"0.0.1"}\n' > "$dir/.vault-template.json"
  printf '# vault _CLAUDE.md\n\nmy own rules.\n' > "$dir/_CLAUDE.md"
  if [ "$medical" = 1 ]; then
    printf 'salus medical-vault profile\n' > "$dir/.salus-profile"
    # operator content that MUST survive the upgrade
    printf '# archive\n\n| 2025-12-31 | hands | active | x | **eczema** | real row |\n' > "$dir/_skin-photo-archive.md"
  fi
}

echo "== medical vault (.salus-profile) — refresh + preserve =="
MED="$WORK/vault-med"; make_vault "$MED" 1
bash "$TPL/scripts/upgrade.sh" --template-dir "$TPL" --vault-dir "$MED" --yes >/dev/null 2>&1
chk "medic skill installed"        "[ -f '$MED/.claude/skills/medic/SKILL.md' ]"
chk "egress floor installed"       "[ -f '$MED/.claude/hooks/block-cloud-egress.sh' ]"
chk "operator skin-archive row preserved" "grep -q '2025-12-31 | hands' '$MED/_skin-photo-archive.md'"
chk "operator _CLAUDE rules preserved" "grep -q 'my own rules' '$MED/_CLAUDE.md'"

echo "== non-medical vault (no marker) — gate must SKIP medical assets =="
PLAIN="$WORK/vault-plain"; make_vault "$PLAIN" 0
bash "$TPL/scripts/upgrade.sh" --template-dir "$TPL" --vault-dir "$PLAIN" --yes >/dev/null 2>&1
chk "egress floor NOT installed"   "[ ! -f '$PLAIN/.claude/hooks/block-cloud-egress.sh' ]"
chk "medic skill NOT installed"    "[ ! -f '$PLAIN/.claude/skills/medic/SKILL.md' ]"
chk "no .salus-profile created"    "[ ! -f '$PLAIN/.salus-profile' ]"

echo "== --dry-run on a medical vault must make NO changes =="
DRY="$WORK/vault-dry"; make_vault "$DRY" 1
bash "$TPL/scripts/upgrade.sh" --template-dir "$TPL" --vault-dir "$DRY" --dry-run >/dev/null 2>&1
chk "dry-run did NOT install the egress floor" "[ ! -f '$DRY/.claude/hooks/block-cloud-egress.sh' ]"
chk "dry-run did NOT install the medic skill"  "[ ! -f '$DRY/.claude/skills/medic/SKILL.md' ]"

echo ""
if [ "$fails" -eq 0 ]; then echo "PASS — salus upgrade profile-gate test"; else echo "FAIL — $fails check(s)"; exit 1; fi
