#!/usr/bin/env bash
# Probe 3d (HIMMEL-2179, RETASK RTK-2179-8f3a1c): --plugin-dir as the pack
# mechanism. A minimal plugin (.claude-plugin/plugin.json + skills/) loaded
# via --plugin-dir from a scratch cwd — no --bare, no --add-dir, no
# CLAUDE_CONFIG_DIR. Tries the namespaced "/probe-plugin:probe-skill" form
# first, falls back to bare "/probe-skill" if that doesn't produce the
# artifact. MSYS_NO_PATHCONV=1 throughout (Git Bash argv-mangling, see
# probe 1's methodology note). Verify by ARTIFACT.
# shellcheck source=./common.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PLUGINDIR="$OUT_DIR/pack3d/probe-plugin"
WORKDIR="$OUT_DIR/03d-work"
rm -rf "$PLUGINDIR"
rm -f "$WORKDIR/skill-artifact.txt" "$WORKDIR/out.json" "$WORKDIR/out.err" "$WORKDIR/out2.json" "$WORKDIR/out2.err"
mkdir -p "$PLUGINDIR/.claude-plugin" "$PLUGINDIR/skills/probe-skill" "$WORKDIR"

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

# MSYS_NO_PATHCONV=1 below disables Git-Bash path conversion for the WHOLE
# command line (protects the slash-command prompts) — so PLUGINDIR needs
# pre-conversion to native Windows form itself, or claude.exe receives an
# unresolvable /c/... path for --plugin-dir and any load failure would be
# a mangling artifact, not evidence about the manifest.
PLUGINDIR_WIN="$PLUGINDIR"
command -v cygpath >/dev/null 2>&1 && PLUGINDIR_WIN=$(cygpath -m "$PLUGINDIR")

(
  cd "$WORKDIR" || exit 1
  # headless-claude-ok: HIMMEL-2179 probe
  MSYS_NO_PATHCONV=1 timeout "$TIMEOUT_S" claude -p --model "$MODEL" --max-turns 2 \
    --plugin-dir "$PLUGINDIR_WIN" \
    --permission-mode dontAsk --allowedTools "Write,Read" \
    --output-format json "/probe-plugin:probe-skill" \
    > out.json 2>out.err
  echo "03d (namespaced) rc=$?"
)
echo "03d: namespaced envelope:"
jq -c '{is_error, result, permission_denials}' "$WORKDIR/out.json" 2>/dev/null

if [ -f "$WORKDIR/skill-artifact.txt" ]; then
  echo "03d: artifact PRESENT (namespaced) — $(cat "$WORKDIR/skill-artifact.txt")"
else
  echo "03d: artifact ABSENT (namespaced) — trying bare /probe-skill"
  (
    cd "$WORKDIR" || exit 1
    # headless-claude-ok: HIMMEL-2179 probe
    MSYS_NO_PATHCONV=1 timeout "$TIMEOUT_S" claude -p --model "$MODEL" --max-turns 2 \
      --plugin-dir "$PLUGINDIR_WIN" \
      --permission-mode dontAsk --allowedTools "Write,Read" \
      --output-format json "/probe-skill" \
      > out2.json 2>out2.err
    echo "03d (bare) rc=$?"
  )
  echo "03d: bare envelope:"
  jq -c '{is_error, result, permission_denials}' "$WORKDIR/out2.json" 2>/dev/null
  if [ -f "$WORKDIR/skill-artifact.txt" ]; then
    echo "03d: artifact PRESENT (bare) — $(cat "$WORKDIR/skill-artifact.txt")"
  else
    echo "03d: artifact ABSENT (bare too)"
  fi
fi
