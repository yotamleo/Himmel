#!/usr/bin/env bash
# Probe 3b (HIMMEL-2179, RETASK RTK-2179-8f3a1c): does a seeded
# CLAUDE_CONFIG_DIR (copying ONLY .credentials.json + a throwaway skills/
# dir — no --bare, no --add-dir) give bare-equivalent skill isolation WITH
# working auth? Verify by ARTIFACT: auth works, skill discovered, file
# written. Never commits credentials material — CFG_DIR lives under tmp/
# (gitignored), and only .credentials.json is copied (no settings/memory).
# shellcheck source=./common.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

CFG_DIR="$OUT_DIR/03b-cfg"
WORKDIR="$OUT_DIR/03b-work"
rm -rf "$CFG_DIR"
rm -f "$WORKDIR/skill-artifact.txt" "$WORKDIR/out.json" "$WORKDIR/out.err"
mkdir -p "$CFG_DIR/skills/probe-skill" "$WORKDIR"

REAL_CREDS="$HOME/.claude/.credentials.json"
if [ ! -f "$REAL_CREDS" ]; then
  echo "03b: SKIP — no $REAL_CREDS found (nothing to seed auth with)"
  exit 0
fi
# Credential hygiene: register the cleanup trap BEFORE the copy exists, so
# there's no window between creating it and being able to clean it up. Fires
# on ANY exit (normal, error, or signal) — except SIGKILL/crash/machine
# failure, which no userspace mechanism can catch; that residual is accepted
# for this gitignored, single-user, local scratch dir (see HIMMEL-2178 if
# this harness graduates beyond probes).
trap 'rm -f "$CFG_DIR/.credentials.json"' EXIT
cp "$REAL_CREDS" "$CFG_DIR/.credentials.json"
chmod 600 "$CFG_DIR/.credentials.json" 2>/dev/null || true

cat > "$CFG_DIR/skills/probe-skill/SKILL.md" <<'EOF'
---
name: probe-skill
description: Probe skill for HIMMEL-2179 harness testing. Invoke as /probe-skill.
---

When invoked, write the word SKILLOK into ./skill-artifact.txt.
EOF

# MSYS_NO_PATHCONV=1 below disables Git-Bash path conversion for the WHOLE
# invocation (protects the "/probe-skill" prompt) — including env-var
# VALUES, so CLAUDE_CONFIG_DIR needs pre-conversion to native Windows form
# itself, or claude.exe sees an unresolvable /c/... path and falls back to
# ambient config instead of the seeded one.
CFG_DIR_WIN="$CFG_DIR"
command -v cygpath >/dev/null 2>&1 && CFG_DIR_WIN=$(cygpath -m "$CFG_DIR")

(
  cd "$WORKDIR" || exit 1
  # headless-claude-ok: HIMMEL-2179 probe
  CLAUDE_CONFIG_DIR="$CFG_DIR_WIN" MSYS_NO_PATHCONV=1 timeout "$TIMEOUT_S" claude -p --model "$MODEL" --max-turns 2 \
    --permission-mode dontAsk --allowedTools "Write,Read" \
    --output-format json "/probe-skill" \
    > out.json 2>out.err
  echo "03b rc=$?"
)

if [ -f "$WORKDIR/skill-artifact.txt" ]; then
  echo "03b: artifact PRESENT — $(cat "$WORKDIR/skill-artifact.txt")"
else
  echo "03b: artifact ABSENT"
fi
echo "03b: envelope:"
jq -c '{is_error, result, permission_denials}' "$WORKDIR/out.json" 2>/dev/null
