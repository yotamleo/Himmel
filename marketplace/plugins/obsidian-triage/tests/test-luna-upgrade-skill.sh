#!/usr/bin/env bash
# Invariant tests for the obsidian-triage:luna-upgrade skill (HIMMEL-389 Phase 2).
#
# Scope: validates the structural invariants the skill + its slash-command
# wrapper must hold. Does NOT exercise the runbook end-to-end (the upgrade
# engine itself is covered by templates/luna-second-brain/scripts/test-upgrade.sh).
# Mirrors test-luna-ingest-skill.sh (the established obsidian-triage skill-test
# convention). What this gives us:
#
#   1. SKILL.md exists at the canonical skills/luna-upgrade/ path.
#   2. SKILL.md frontmatter parses and contains `name` + `description`.
#   3. `name` matches the skill directory name (loader convention).
#   4. `description` starts with "Use when" (CSO best practice).
#   5. Slash-command wrapper exists AND delegates to the skill (no body dup).
#   6. The skill body documents the dry-run -> confirm -> apply contract,
#      references the upgrade.sh engine, and uses --vault-dir (so a
#      pre-Phase-0+1 vault without its own upgrade.sh still upgrades).

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Plugin path: marketplace/plugins/obsidian-triage/ -> repo root is ../../..
REPO_DIR="$(cd "$PLUGIN_DIR/../../.." && pwd)"

SKILL="$PLUGIN_DIR/skills/luna-upgrade/SKILL.md"
WRAPPER="$REPO_DIR/.claude/commands/luna-upgrade.md"

pass=0
fail=0

assert() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS  $desc"; pass=$((pass+1))
    else
        echo "  FAIL  $desc"; echo "         expected: $expected"; echo "         actual:   $actual"; fail=$((fail+1))
    fi
}

echo "Test 1: SKILL.md exists at canonical path"
[ -r "$SKILL" ] && exists=yes || exists=no
assert "$SKILL exists" "yes" "$exists"
if [ "$exists" = "no" ]; then
    echo "Results: $pass passed, $fail failed"; exit 1
fi

echo "Test 2: SKILL.md frontmatter has required fields"
fm_lines=$(awk '/^---$/{c++; next} c==1' "$SKILL")
if printf '%s\n' "$fm_lines" | grep -qE "^name:[[:space:]]+luna-upgrade[[:space:]]*$"; then name_ok=yes; else name_ok=no; fi
assert "frontmatter name: luna-upgrade" "yes" "$name_ok"
if printf '%s\n' "$fm_lines" | grep -qE "^description:[[:space:]]+\S"; then desc_ok=yes; else desc_ok=no; fi
assert "frontmatter description: present + non-empty" "yes" "$desc_ok"

echo "Test 3: name matches skill directory (loader convention)"
skill_dir_name="$(basename "$(dirname "$SKILL")")"
assert "skill dir = luna-upgrade" "luna-upgrade" "$skill_dir_name"

echo "Test 4: description starts with 'Use when' (CSO best practice)"
if printf '%s\n' "$fm_lines" | grep -qE "^description:[[:space:]]+Use when"; then cso_ok=yes; else cso_ok=no; fi
assert "description starts with 'Use when'" "yes" "$cso_ok"

echo "Test 5: slash-command wrapper exists"
[ -r "$WRAPPER" ] && wrap_exists=yes || wrap_exists=no
assert "$WRAPPER exists" "yes" "$wrap_exists"

echo "Test 6: wrapper delegates via actual Skill-tool invocation (does NOT duplicate runbook body)"
if [ "$wrap_exists" = "yes" ]; then
    # shellcheck disable=SC2016
    if grep -qE 'Skill[[:space:]]*\{[[:space:]]*skill:[[:space:]]*"obsidian-triage:luna-upgrade"' "$WRAPPER" \
       && grep -qE 'args:[[:space:]]*"\$ARGUMENTS"' "$WRAPPER"; then invokes=yes; else invokes=no; fi
    assert "wrapper issues Skill { skill: \"obsidian-triage:luna-upgrade\", args: \"\$ARGUMENTS\" }" "yes" "$invokes"

    if awk '/^---$/{c++; next} c==1' "$WRAPPER" | grep -qE "^allowed-tools:.*\bSkill\b"; then allowed=yes; else allowed=no; fi
    assert "wrapper frontmatter allowed-tools: includes Skill" "yes" "$allowed"

    skill_lines=$(wc -l < "$SKILL" | tr -d ' ')
    wrap_lines=$(wc -l < "$WRAPPER" | tr -d ' ')
    if [ "$wrap_lines" -lt $((skill_lines / 5)) ]; then is_thin=yes; else is_thin=no; fi
    assert "wrapper is >=5x shorter than the skill (no body duplication)" "yes" "$is_thin"
fi

echo "Test 7: skill body documents the upgrade contract (engine + dry-run -> confirm -> apply + --vault-dir)"
for marker in "upgrade.sh" "--dry-run" "--vault-dir" "--yes" "--check"; do
    if grep -qF -e "$marker" "$SKILL"; then present=yes; else present=no; fi
    assert "skill body references: $marker" "yes" "$present"
done
# The confirm step is the load-bearing UX invariant — assert it's documented.
if grep -qiE "confirm" "$SKILL"; then confirm_ok=yes; else confirm_ok=no; fi
assert "skill body documents a confirm step" "yes" "$confirm_ok"

echo ""
echo "Results: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then exit 1; fi
