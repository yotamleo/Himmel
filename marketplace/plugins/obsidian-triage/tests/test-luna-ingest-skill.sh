#!/usr/bin/env bash
# Invariant tests for the obsidian-triage:luna-ingest skill (LUNA-9).
#
# Scope: validates the structural invariants the skill file must hold
# AFTER the slash-cmd → skill conversion. Does NOT exercise the runbook
# end-to-end (that requires gh api + a real github URL — covered later
# in LUNA-10 calibration). What this test gives us:
#
#   1. SKILL.md exists at the canonical path the LUNA-3 plan expects.
#   2. SKILL.md frontmatter parses as YAML and contains `name` +
#      `description` (the only two REQUIRED fields per writing-skills).
#   3. `name` matches the skill directory name (skill loader convention).
#   4. `description` starts with "Use when" (CSO best practice — Claude's
#      skill picker reads this to decide relevance).
#   5. Slash-command wrapper still exists at the original path AND now
#      delegates to the skill (no full-runbook duplication).
#   6. The skill body preserves the same Phase-numbered structure as the
#      original (Phases 1-4 + Dry-run + Exit codes) so /harvest-clips
#      can rely on the documented contract.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# Plugin moved under marketplace/plugins/ in the LUNA-26 cleanup.
# Plugin path: marketplace/plugins/obsidian-triage/
# To reach himmel repo root: PLUGIN_DIR/../../..
REPO_DIR="$(cd "$PLUGIN_DIR/../../.." && pwd)"

SKILL="$PLUGIN_DIR/skills/luna-ingest/SKILL.md"
WRAPPER="$REPO_DIR/.claude/commands/luna-ingest.md"

pass=0
fail=0

assert() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS  $desc"
        pass=$((pass+1))
    else
        echo "  FAIL  $desc"
        echo "         expected: $expected"
        echo "         actual:   $actual"
        fail=$((fail+1))
    fi
}

echo "Test 1: SKILL.md exists at canonical path"
[ -r "$SKILL" ] && exists=yes || exists=no
assert "$SKILL exists" "yes" "$exists"
if [ "$exists" = "no" ]; then
    echo "Results: $pass passed, $fail failed"
    exit 1
fi

echo "Test 2: SKILL.md frontmatter has required fields"
# Extract frontmatter (between the first two --- delimiters).
fm_lines=$(awk '/^---$/{c++; next} c==1' "$SKILL")

if printf '%s\n' "$fm_lines" | grep -qE "^name:[[:space:]]+luna-ingest[[:space:]]*$"; then
    name_ok=yes
else
    name_ok=no
fi
assert "frontmatter name: luna-ingest" "yes" "$name_ok"

if printf '%s\n' "$fm_lines" | grep -qE "^description:[[:space:]]+\S"; then
    desc_ok=yes
else
    desc_ok=no
fi
assert "frontmatter description: present + non-empty" "yes" "$desc_ok"

echo "Test 3: name matches skill directory (loader convention)"
skill_dir_name="$(basename "$(dirname "$SKILL")")"
assert "skill dir = luna-ingest" "luna-ingest" "$skill_dir_name"

echo "Test 4: description starts with 'Use when' (CSO best practice)"
if printf '%s\n' "$fm_lines" | grep -qE "^description:[[:space:]]+Use when"; then
    cso_ok=yes
else
    cso_ok=no
fi
assert "description starts with 'Use when'" "yes" "$cso_ok"

echo "Test 5: slash-command wrapper still exists"
[ -r "$WRAPPER" ] && wrap_exists=yes || wrap_exists=no
assert "$WRAPPER exists" "yes" "$wrap_exists"

echo "Test 6: wrapper delegates via actual Skill-tool invocation (does NOT duplicate runbook body)"
# Wrapper body MUST issue the exact Skill-tool call AND must be much
# shorter than the skill (proves it's a wrapper, not a duplicate).
# CR finding (PR #173): an earlier wrapper revision only DESCRIBED the
# delegation in prose without giving Claude an executable tool call,
# risking that future-Claude would re-inline the runbook instead of
# dispatching. This test invariant now blocks that regression.
if [ "$wrap_exists" = "yes" ]; then
    # Imperative tool-call shape: `Skill { skill: "obsidian-triage:luna-ingest", args: "$ARGUMENTS" }`.
    # Tolerate whitespace variation but require the canonical key=value pairs.
    # Single-quoted patterns are intentional — we match the LITERAL `$ARGUMENTS`
    # token in the wrapper file (slash-cmd preprocessor substitutes at runtime).
    # shellcheck disable=SC2016
    if grep -qE 'Skill[[:space:]]*\{[[:space:]]*skill:[[:space:]]*"obsidian-triage:luna-ingest"' "$WRAPPER" \
       && grep -qE 'args:[[:space:]]*"\$ARGUMENTS"' "$WRAPPER"; then
        invokes=yes
    else
        invokes=no
    fi
    assert "wrapper issues Skill { skill: \"obsidian-triage:luna-ingest\", args: \"\$ARGUMENTS\" }" "yes" "$invokes"

    # Wrapper must include `Skill` in its `allowed-tools` frontmatter — the
    # invocation above is only safe if the slash command is permitted to
    # call the Skill tool.
    if awk '/^---$/{c++; next} c==1' "$WRAPPER" | grep -qE "^allowed-tools:.*\bSkill\b"; then
        allowed=yes
    else
        allowed=no
    fi
    assert "wrapper frontmatter allowed-tools: includes Skill" "yes" "$allowed"

    skill_lines=$(wc -l < "$SKILL" | tr -d ' ')
    wrap_lines=$(wc -l < "$WRAPPER" | tr -d ' ')
    # Wrapper should be at least 5x shorter than the skill body —
    # generous threshold that catches a forgotten copy-paste of the
    # full runbook into the wrapper.
    if [ "$wrap_lines" -lt $((skill_lines / 5)) ]; then
        is_thin=yes
    else
        is_thin=no
    fi
    assert "wrapper is ≥5x shorter than the skill (no body duplication)" "yes" "$is_thin"
fi

echo "Test 7: skill preserves the documented Phase structure"
# /harvest-clips dispatch contract (LUNA-10) relies on the Phase-numbered
# structure surviving the conversion.
for phase in "## Phase 1" "## Phase 2" "## Phase 3" "## Phase 4" "## Dry-run mode" "## Exit codes"; do
    if grep -qF "$phase" "$SKILL"; then
        present=yes
    else
        present=no
    fi
    assert "skill body has section: $phase" "yes" "$present"
done

echo "Test 8: bitbucket.org routing branch is documented (HIMMEL-329)"
# The Bitbucket branch is the forge-routed parallel to the github phases. These
# invariants block silent rot of the bitbucket contract that /harvest-clips and
# operators depend on.
for marker in \
    "## Bitbucket branch" \
    "### B-repo" \
    "### B-PR" \
    "### B-issue" \
    "bitbucket.org" \
    "source_type: bitbucket"; do
    if grep -qF "$marker" "$SKILL"; then
        present=yes
    else
        present=no
    fi
    assert "skill body documents bitbucket marker: $marker" "yes" "$present"
done

# The description must advertise bitbucket so the skill picker routes BB URLs here.
if printf '%s\n' "$fm_lines" | grep -qF "bitbucket.org"; then
    desc_bb=yes
else
    desc_bb=no
fi
assert "description advertises bitbucket.org" "yes" "$desc_bb"

echo ""
echo "Results: $pass passed, $fail failed"
if [ "$fail" -gt 0 ]; then
    exit 1
fi
