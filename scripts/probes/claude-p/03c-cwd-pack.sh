#!/usr/bin/env bash
# launch-profile-ok-file: experiment probe; it measures a specific headless claude config, so a role profile would change the measurement (HIMMEL-4013)
# Probe 3c (HIMMEL-2179, ported credential-free by HIMMEL-4410): project-tier skill
# discovery. cwd = a directory whose own ./.claude/skills/ holds the skill, no
# --bare, no --add-dir. fakekey_run runs claude with cwd = its outdir, so the
# outdir IS the project. Verified by ARTIFACT: the skill is listed in the
# stream-json init event.
# shellcheck source=./common.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

RUN="$OUT_DIR/03c-run"
rm -rf "$RUN"
mkdir -p "$RUN/.claude/skills/probe-skill"

cat > "$RUN/.claude/skills/probe-skill/SKILL.md" <<'EOF'
---
name: probe-skill
description: Probe skill for HIMMEL-2179 harness testing. Invoke as /probe-skill.
---

When invoked, write the word SKILLOK into ./skill-artifact.txt.
EOF

fakekey_run "$RUN" --output-format stream-json --verbose
echo "03c rc=$(cat "$RUN/rc")"
probe_skill_discovered "$RUN" probe-skill
