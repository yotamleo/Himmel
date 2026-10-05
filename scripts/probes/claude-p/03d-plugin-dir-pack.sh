#!/usr/bin/env bash
# launch-profile-ok-file: experiment probe; it measures a specific headless claude config, so a role profile would change the measurement (HIMMEL-4013)
# Probe 3d (HIMMEL-2179, ported credential-free by HIMMEL-4410): --plugin-dir as the
# pack mechanism. A minimal plugin (.claude-plugin/plugin.json + skills/) loaded
# via --plugin-dir, no --bare, no --add-dir. Reports whether the skill is listed
# under the namespaced name (probe-plugin:probe-skill), the bare name, or both.
# Verified by ARTIFACT: the stream-json init event.
# shellcheck source=./common.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

RUN="$OUT_DIR/03d-run"
PLUGINDIR="$OUT_DIR/pack3d/probe-plugin"
rm -rf "$RUN" "$PLUGINDIR"
mkdir -p "$PLUGINDIR/.claude-plugin" "$PLUGINDIR/skills/probe-skill" "$RUN"

cat > "$PLUGINDIR/.claude-plugin/plugin.json" <<'EOF'
{"name":"probe-plugin","version":"0.0.1"}
EOF

cat > "$PLUGINDIR/skills/probe-skill/SKILL.md" <<'EOF'
---
name: probe-skill
description: Probe skill for HIMMEL-2179 harness testing. Invoke as /probe-skill.
---

When invoked, write the word SKILLOK into ./skill-artifact.txt.
EOF

fakekey_run "$RUN" --plugin-dir "$PLUGINDIR" --output-format stream-json --verbose
echo "03d rc=$(cat "$RUN/rc")"
probe_skill_discovered "$RUN" probe-plugin:probe-skill; ns=$?
probe_skill_discovered "$RUN" probe-skill; bare=$?
[ "$ns" = 0 ] || [ "$bare" = 0 ] # either supported name counts as discovered
