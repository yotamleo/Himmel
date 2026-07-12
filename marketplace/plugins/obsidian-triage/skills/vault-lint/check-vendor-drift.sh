#!/usr/bin/env bash
# Flags when upstream claude-obsidian wiki-lint has drifted from the version
# vault-lint was forked from. Fail-open if the cache isn't installed locally
# (fresh clone, CI); fail-closed on drift when --strict is passed.
#
# Usage:
#   check-vendor-drift.sh           # warn on drift, exit 0
#   check-vendor-drift.sh --strict  # exit 1 on drift
set -euo pipefail

STRICT=0
if [ "${1:-}" = "--strict" ]; then
  STRICT=1
fi

# Locate UPSTREAM.json relative to this script (works regardless of cwd).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UPSTREAM_JSON="$SCRIPT_DIR/UPSTREAM.json"

if [ ! -f "$UPSTREAM_JSON" ]; then
  echo "vault-lint drift-check: UPSTREAM.json not found at $UPSTREAM_JSON — skipping" >&2
  exit 0
fi

CO="$HOME/.claude/plugins/cache/claude-obsidian-marketplace/claude-obsidian"
if [ ! -d "$CO" ]; then
  echo "vault-lint drift-check: upstream cache not installed locally ($CO) — skipping" >&2
  exit 0
fi

# Use the highest version dir (last in sorted glob order) containing the expected files.
SKILL_PATH=""
AGENT_PATH=""
for vdir in "$CO"/*/; do
  if [ -f "${vdir}skills/wiki-lint/SKILL.md" ]; then
    SKILL_PATH="${vdir}skills/wiki-lint/SKILL.md"
  fi
  if [ -f "${vdir}agents/wiki-lint.md" ]; then
    AGENT_PATH="${vdir}agents/wiki-lint.md"
  fi
done

if [ -z "$SKILL_PATH" ] || [ -z "$AGENT_PATH" ]; then
  echo "vault-lint drift-check: wiki-lint files not found in cache — skipping" >&2
  exit 0
fi

sha256_of() {
  python -c "import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$1"
}

WANT_SKILL="$(python -c "import json,sys; d=json.load(open(sys.argv[1])); print(next(f['sha256'] for f in d['files'] if 'SKILL.md' in f['path']))" "$UPSTREAM_JSON")"
WANT_AGENT="$(python -c "import json,sys; d=json.load(open(sys.argv[1])); print(next(f['sha256'] for f in d['files'] if 'wiki-lint.md' in f['path']))" "$UPSTREAM_JSON")"

GOT_SKILL="$(sha256_of "$SKILL_PATH")"
GOT_AGENT="$(sha256_of "$AGENT_PATH")"

DRIFT=0
SKILL_DRIFT=0
AGENT_DRIFT=0
if [ "$GOT_SKILL" != "$WANT_SKILL" ]; then DRIFT=1; SKILL_DRIFT=1; fi
if [ "$GOT_AGENT" != "$WANT_AGENT" ]; then DRIFT=1; AGENT_DRIFT=1; fi
if [ "$DRIFT" -eq 1 ]; then
  # Single banner regardless of how many files drifted; per-file detail follows.
  echo "vault-lint: upstream wiki-lint changed since fork — review for new checks" >&2
  if [ "$SKILL_DRIFT" -eq 1 ]; then
    echo "  skills/wiki-lint/SKILL.md: want=$WANT_SKILL got=$GOT_SKILL" >&2
  fi
  if [ "$AGENT_DRIFT" -eq 1 ]; then
    echo "  agents/wiki-lint.md: want=$WANT_AGENT got=$GOT_AGENT" >&2
  fi
fi

if [ "$DRIFT" -eq 0 ]; then
  echo "vault-lint drift-check: in sync with upstream wiki-lint"
  exit 0
fi

if [ "$STRICT" -eq 1 ]; then
  exit 1
fi

exit 0
