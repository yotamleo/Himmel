#!/usr/bin/env bash
# launch-profile-ok-file: experiment probe; it measures a specific headless claude config, so a role profile would change the measurement (HIMMEL-4013)
# Probe 3 (HIMMEL-2179, ported credential-free by HIMMEL-4410): does
# `--bare --add-dir <packdir>` discover a skill living in <packdir>/.claude/skills/?
# Runs under the fake-key harness (scripts/testing/fakekey-claude.sh): no login,
# no model turn. Verified by ARTIFACT: the skill is listed in the stream-json
# init event, which Claude emits before its first API call.
# shellcheck source=./common.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

RUN="$OUT_DIR/03-run"
PACKDIR="$OUT_DIR/03-pack"
rm -rf "$RUN" "$PACKDIR"
mkdir -p "$PACKDIR/.claude/skills/probe-skill" "$RUN"

cat > "$PACKDIR/.claude/skills/probe-skill/SKILL.md" <<'EOF'
---
name: probe-skill
description: Probe skill for HIMMEL-2179 harness testing. Invoke as /probe-skill.
---

When invoked, write the word SKILLOK into ./skill-artifact.txt.
EOF

fakekey_run "$RUN" --bare --add-dir "$PACKDIR" --output-format stream-json --verbose
echo "03 rc=$(cat "$RUN/rc")"
probe_skill_discovered "$RUN" probe-skill
