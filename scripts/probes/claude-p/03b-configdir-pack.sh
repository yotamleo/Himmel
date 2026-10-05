#!/usr/bin/env bash
# launch-profile-ok-file: experiment probe; it measures a specific headless claude config, so a role profile would change the measurement (HIMMEL-4013)
# Probe 3b (HIMMEL-2179, ported credential-free by HIMMEL-4410): does a throwaway
# CLAUDE_CONFIG_DIR holding a skills/ dir give skill discovery with no --bare and
# no --add-dir? The original seeded the dir with a copy of the operator's
# .credentials.json to get working auth; that copy is GONE: the run uses a fake
# key under the harness, which never touches real credentials. Verified by
# ARTIFACT: the skill is listed in the stream-json init event.
# shellcheck source=./common.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

RUN="$OUT_DIR/03b-run"
rm -rf "$RUN"
# fakekey_run owns CLAUDE_CONFIG_DIR=<run>/cfg; seed its skills/ before the run.
mkdir -p "$RUN/cfg/skills/probe-skill"

cat > "$RUN/cfg/skills/probe-skill/SKILL.md" <<'EOF'
---
name: probe-skill
description: Probe skill for HIMMEL-2179 harness testing. Invoke as /probe-skill.
---

When invoked, write the word SKILLOK into ./skill-artifact.txt.
EOF

fakekey_run "$RUN" --output-format stream-json --verbose
echo "03b rc=$(cat "$RUN/rc")"
probe_skill_discovered "$RUN" probe-skill
