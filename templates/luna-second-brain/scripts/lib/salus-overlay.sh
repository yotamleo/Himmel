#!/usr/bin/env bash
# salus medical-vault overlay — apply the PHI-free overlay (_profiles/salus/)
# onto a vault. Sourced by setup.sh (--medical) and the hermetic test.
#
# apply_salus_overlay <repo_root>
#   - code/config assets (.claude/skills/medic, .claude/hooks/egress floor,
#     .claude/settings.json) → always (re)installed (settings.json only if absent).
#   - _-root scaffolds (_skin-photo-archive.md, _derm-visit-prep.template.md,
#     _media/skin/) → scaffold-new ONLY; never overwrites operator content.
#   - appends the medical posture block to _CLAUDE.md once (idempotent).
#   - drops the .salus-profile marker (upgrade.sh gates on it) AND the .salus
#     PHI guard marker (HIMMEL-2173) — never overwrites an existing .salus.
# Returns non-zero only on a missing overlay dir. bash 3.2-safe.
apply_salus_overlay() {
  local repo_root="$1"
  local ov="$repo_root/_profiles/salus"
  local today
  today="$(date +%F)"
  if [ ! -d "$ov" ]; then
    echo "salus-overlay: overlay not found at $ov" >&2
    return 1
  fi
  mkdir -p "$repo_root/.claude/skills" "$repo_root/.claude/hooks"
  cp -R "$ov/.claude/skills/medic" "$repo_root/.claude/skills/"
  cp "$ov/.claude/hooks/block-cloud-egress.sh" "$repo_root/.claude/hooks/"
  chmod +x "$repo_root/.claude/hooks/block-cloud-egress.sh" 2>/dev/null || true
  if [ ! -e "$repo_root/.claude/settings.json" ]; then
    cp "$ov/.claude/settings.json" "$repo_root/.claude/settings.json"
  else
    echo "salus-overlay: .claude/settings.json exists — not overwritten; ensure it wires" >&2
    echo "  PreToolUse .* -> bash \$CLAUDE_PROJECT_DIR/.claude/hooks/block-cloud-egress.sh" >&2
  fi
  local f
  for f in _skin-photo-archive.md _derm-visit-prep.template.md; do
    if [ ! -e "$repo_root/$f" ]; then
      sed "s/<scaffold-date>/$today/" "$ov/$f" > "$repo_root/$f"
    fi
  done
  mkdir -p "$repo_root/_media/skin"
  [ -e "$repo_root/_media/skin/.gitkeep" ] || cp "$ov/_media/skin/.gitkeep" "$repo_root/_media/skin/.gitkeep"
  if [ -f "$repo_root/_CLAUDE.md" ] && ! grep -q "salus-posture-block" "$repo_root/_CLAUDE.md"; then
    printf '\n' >> "$repo_root/_CLAUDE.md"
    cat "$ov/_CLAUDE.salus.md" >> "$repo_root/_CLAUDE.md"
  fi
  printf 'salus medical-vault profile - managed by setup --medical / upgrade\n' > "$repo_root/.salus-profile"
  # PHI guard marker (HIMMEL-2173): the 7 PHI launcher guards (claude-glm/
  # claude-codex/claude-routed + their .ps1 twins + the hermes parity guard)
  # were written to test for .salus, not .salus-profile — without this, a
  # fresh salus deployment shipped an inert guard (marker present, but the
  # wrong one). The guards now accept .salus-profile too (part 2 of this
  # ticket), but that is a defense for pre-existing deployments; keep
  # shipping the real .salus marker here so a fresh deployment never relies
  # on it. Never overwrite an existing .salus (an operator may have
  # customized it).
  [ -e "$repo_root/.salus" ] || : > "$repo_root/.salus"
  return 0
}
