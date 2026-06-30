#!/usr/bin/env bash
# Hermetic test for the salus medical overlay (apply_salus_overlay).
# No real data touched: everything happens under a fresh mktemp vault.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/salus-overlay.sh
# shellcheck disable=SC1091
. "$HERE/lib/salus-overlay.sh"

fails=0
ok()   { echo "  ok   - $1"; }
bad()  { echo "  FAIL - $1" >&2; fails=$((fails+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# --- fixture: a fresh "vault" with the overlay source + a base _CLAUDE.md ---
VAULT="$(mktemp -d 2>/dev/null || mktemp -d -t salus)"
trap 'rm -rf "$VAULT"' EXIT
mkdir -p "$VAULT/_profiles"
cp -R "$TEMPLATE_ROOT/_profiles/salus" "$VAULT/_profiles/salus"
printf '# base vault _CLAUDE.md\n\nbase rules here.\n' > "$VAULT/_CLAUDE.md"

echo "== apply (scaffold-new) =="
apply_salus_overlay "$VAULT" || bad "apply returned non-zero"

check "medic skill installed"        "[ -f '$VAULT/.claude/skills/medic/SKILL.md' ]"
check "egress hook installed"        "[ -f '$VAULT/.claude/hooks/block-cloud-egress.sh' ]"
check "settings.json installed"      "[ -f '$VAULT/.claude/settings.json' ]"
check "settings wires egress hook"   "grep -q 'block-cloud-egress.sh' '$VAULT/.claude/settings.json'"
check "skin archive scaffolded"      "[ -f '$VAULT/_skin-photo-archive.md' ]"
check "derm-prep template scaffolded" "[ -f '$VAULT/_derm-visit-prep.template.md' ]"
check "media/skin gitkeep present"   "[ -f '$VAULT/_media/skin/.gitkeep' ]"
check "posture appended to _CLAUDE"  "grep -q 'salus-posture-block' '$VAULT/_CLAUDE.md'"
check "base _CLAUDE preserved"       "grep -q 'base rules here' '$VAULT/_CLAUDE.md'"
check ".salus-profile marker dropped" "[ -f '$VAULT/.salus-profile' ]"

# skin archive ships schema-only (header + separator, ZERO data rows)
_datarows="$(grep -cE '^\| 20[0-9][0-9]-' "$VAULT/_skin-photo-archive.md" 2>/dev/null || true)"
check "skin archive has ZERO data rows" "[ \"\${_datarows:-0}\" -eq 0 ]"

# PHI-free: the shipped overlay/template must contain NONE of the operator's
# personal/PHI literals. The literal list lives OUTSIDE the repo (the leak
# denylist, default ~/.claude/himmel-leak-denylist.txt) so no real PHI is
# committed here — HIMMEL-638 found the old hardcoded canary list (a real name +
# medications) leaked into this very test. Skipped (with a note) when the
# denylist is absent.
_denylist="${HIMMEL_LEAK_DENYLIST:-$HOME/.claude/himmel-leak-denylist.txt}"
if [ -f "$_denylist" ]; then
  _phi_hit=0
  # `|| [ -n "$_t" ]`: process a final line with no trailing newline too, so the
  # last denylist term is never silently skipped (this is a security canary).
  while IFS= read -r _t || [ -n "$_t" ]; do
    _t="${_t%%$'\r'}"                       # strip CR (Windows-edited denylist)
    case "$_t" in ''|\#*) continue ;; esac
    # Substring (not -w): a PHI canary should catch the token ANYWHERE; this also
    # matches the PowerShell twin's -SimpleMatch semantics (twins in lockstep).
    if grep -rFiq -- "$_t" "$VAULT/.claude" "$VAULT/_skin-photo-archive.md" "$VAULT/.salus-profile" 2>/dev/null; then
      _phi_hit=1; break
    fi
  done < "$_denylist"
  if [ "$_phi_hit" -eq 0 ]; then ok "overlay is PHI-free (vs leak denylist)"; else bad "overlay is PHI-free (vs leak denylist)"; fi
else
  ok "overlay PHI-free check skipped (no leak denylist at $_denylist)"
fi

echo "== idempotency: re-apply must NOT overwrite operator content =="
# operator adds a real data row + a second settings sentinel
printf '| 2026-01-02 | hands | active | x | **eczema** | note |\n' >> "$VAULT/_skin-photo-archive.md"
printf '{"_sentinel":"do-not-clobber"}\n' > "$VAULT/.claude/settings.json"
apply_salus_overlay "$VAULT" || bad "re-apply returned non-zero"
check "operator data row preserved"  "grep -q '2026-01-02 | hands' '$VAULT/_skin-photo-archive.md'"
check "existing settings NOT clobbered" "grep -q 'do-not-clobber' '$VAULT/.claude/settings.json'"
check "posture appended ONCE (idempotent)" "[ \"\$(grep -c 'salus-posture-block' '$VAULT/_CLAUDE.md')\" -eq 1 ]"

echo "== egress floor BEHAVIOR (the structural PHI floor must actually DENY, not just exist) =="
# CR Critical (HIMMEL-577): assert the installed hook's exit codes per tool, so a
# regression that inverted a deny-arm would fail loudly instead of passing green.
HOOK="$VAULT/.claude/hooks/block-cloud-egress.sh"
egress_exit() { printf '%s' "$1" | bash "$HOOK" >/dev/null 2>&1; echo $?; }
e_web="$(egress_exit '{"tool_name":"WebFetch"}')"
e_push="$(egress_exit '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}')"
e_curl="$(egress_exit '{"tool_name":"Bash","tool_input":{"command":"curl https://example.com"}}')"
e_iwr="$(egress_exit '{"tool_name":"Bash","tool_input":{"command":"Invoke-WebRequest https://example.com"}}')"
e_cloud="$(egress_exit '{"tool_name":"mcp__claude_ai_Gmail__x"}')"
e_skill="$(egress_exit '{"tool_name":"Skill","tool_input":{"command":"research"}}')"
e_qmd="$(egress_exit '{"tool_name":"mcp__plugin_qmd_qmd__query"}')"
e_obs="$(egress_exit '{"tool_name":"mcp__obsidian-vault__x"}')"
e_skillok="$(egress_exit '{"tool_name":"Skill","tool_input":{"command":"obsidian-daily"}}')"
e_benign="$(egress_exit '{"tool_name":"Bash","tool_input":{"command":"cp a b"}}')"
check "egress DENIES WebFetch (exit 2)"   "[ '$e_web' = 2 ]"
check "egress DENIES git push (exit 2)"   "[ '$e_push' = 2 ]"
check "egress DENIES curl (exit 2)"       "[ '$e_curl' = 2 ]"
check "egress DENIES Invoke-WebRequest (exit 2)" "[ '$e_iwr' = 2 ]"
check "egress DENIES cloud MCP (exit 2)"  "[ '$e_cloud' = 2 ]"
check "egress DENIES research Skill (exit 2)" "[ '$e_skill' = 2 ]"
check "egress ALLOWS local qmd (exit 0)"  "[ '$e_qmd' = 0 ]"
check "egress ALLOWS localhost obsidian (exit 0)" "[ '$e_obs' = 0 ]"
check "egress ALLOWS benign Skill (exit 0)" "[ '$e_skillok' = 0 ]"
check "egress ALLOWS benign bash (exit 0)" "[ '$e_benign' = 0 ]"

echo "== error path: apply against a dir with no overlay must fail =="
NOOV="$(mktemp -d 2>/dev/null || mktemp -d -t noov)"
if apply_salus_overlay "$NOOV" >/dev/null 2>&1; then bad "apply on a non-template dir should have failed"; else ok "apply on a non-template dir returns non-zero"; fi
rm -rf "$NOOV"

echo ""
if [ "$fails" -eq 0 ]; then echo "PASS — salus overlay hermetic test"; else echo "FAIL — $fails check(s)"; exit 1; fi
