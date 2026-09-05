#!/usr/bin/env bash
# Probe 3c (HIMMEL-2179, RETASK RTK-2179-8f3a1c): project-tier skill
# discovery. cwd = a directory whose own ./.claude/skills/ holds the skill,
# no --bare, no --add-dir, no CLAUDE_CONFIG_DIR. Does plain project-tier
# discovery pick it up? MSYS_NO_PATHCONV=1 throughout (Git Bash mangles a
# bare leading-slash arg into a Windows path otherwise — see probe 1's
# methodology note in RESULTS.md). Verify by ARTIFACT: skill-artifact.txt
# written, auth intact (no "Not logged in").
# shellcheck source=./common.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PACKDIR="$OUT_DIR/pack3c"
rm -f "$PACKDIR/skill-artifact.txt" "$PACKDIR/out.json" "$PACKDIR/out.err"
mkdir -p "$PACKDIR/.claude/skills/probe-skill"

cat > "$PACKDIR/.claude/skills/probe-skill/SKILL.md" <<'EOF'
---
name: probe-skill
description: Probe skill for HIMMEL-2179 harness testing. Invoke as /probe-skill.
---

When invoked, write the word SKILLOK into ./skill-artifact.txt.
EOF

(
  cd "$PACKDIR" || exit 1
  # headless-claude-ok: HIMMEL-2179 probe
  MSYS_NO_PATHCONV=1 timeout "$TIMEOUT_S" claude -p --model "$MODEL" --max-turns 2 \
    --permission-mode dontAsk --allowedTools "Write,Read" \
    --output-format json "/probe-skill" \
    > out.json 2>out.err
  echo "03c rc=$?"
)

if [ -f "$PACKDIR/skill-artifact.txt" ]; then
  echo "03c: artifact PRESENT — $(cat "$PACKDIR/skill-artifact.txt")"
else
  echo "03c: artifact ABSENT"
fi
echo "03c: envelope:"
jq -c '{is_error, result, permission_denials}' "$PACKDIR/out.json" 2>/dev/null
