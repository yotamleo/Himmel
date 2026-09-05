#!/usr/bin/env bash
# Probe 3 (HIMMEL-2179): does `--bare --add-dir <packdir>` discover a skill
# living in <packdir>/.claude/skills/? Verify by ARTIFACT: does invoking
# "/probe-skill" actually write skill-artifact.txt in the run cwd. Also
# capture stream-json output to inspect the init event for skill discovery.
# shellcheck source=./common.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PACKDIR="$OUT_DIR/03-pack"
WORKDIR="$OUT_DIR/03-work"
rm -rf "$PACKDIR" "$WORKDIR"
mkdir -p "$PACKDIR/.claude/skills/probe-skill" "$WORKDIR"

cat > "$PACKDIR/.claude/skills/probe-skill/SKILL.md" <<'EOF'
---
name: probe-skill
description: Probe skill for HIMMEL-2179 harness testing. Invoke as /probe-skill.
---

When invoked, write the word SKILLOK into ./skill-artifact.txt.
EOF

# MSYS_NO_PATHCONV=1 below disables Git-Bash path conversion for the WHOLE
# command line (protects the "/probe-skill" prompt from mangling) — so any
# OTHER POSIX-looking path on that same line needs pre-conversion to native
# Windows form itself, or it reaches claude.exe unconverted too.
PACKDIR_WIN="$PACKDIR"
command -v cygpath >/dev/null 2>&1 && PACKDIR_WIN=$(cygpath -m "$PACKDIR")

(
  cd "$WORKDIR" || exit 1
  # headless-claude-ok: HIMMEL-2179 probe
  MSYS_NO_PATHCONV=1 timeout "$TIMEOUT_S" claude -p --model "$MODEL" --max-turns 2 --bare \
    --add-dir "$PACKDIR_WIN" --permission-mode dontAsk --allowedTools "Write,Read" \
    --output-format stream-json --verbose "/probe-skill" \
    > "$OUT_DIR/03-stream.jsonl" 2>"$OUT_DIR/03.err"
  echo "03 rc=$?"
)

if [ -f "$WORKDIR/skill-artifact.txt" ]; then
  echo "03: artifact PRESENT — $(cat "$WORKDIR/skill-artifact.txt")"
else
  echo "03: artifact ABSENT"
fi

echo "03: init event (skill/slash-command discovery):"
grep -m1 '"subtype":"init"' "$OUT_DIR/03-stream.jsonl" 2>/dev/null | jq -c '{slash_commands: (.slash_commands // .available_slash_commands // null)}' 2>/dev/null

echo "03: final result line:"
tail -1 "$OUT_DIR/03-stream.jsonl" 2>/dev/null | jq -c '{is_error, result, permission_denials}' 2>/dev/null
