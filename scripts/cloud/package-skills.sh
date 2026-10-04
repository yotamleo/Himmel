#!/usr/bin/env bash
# scripts/cloud/package-skills.sh — build the claude.ai upload bundle of the
# plugin skills a cloud brief actually uses (HIMMEL-4206 slice 6).
#
# Cloud sessions do not load plugins, but they load skills enabled on claude.ai.
# The operator uploads each <skill>.zip at claude.ai (Settings, Skills). Skills
# kept here are skill-only and self-contained: no hooks, no plugin paths. A
# skill the repo already ships under .claude/skills (test-audit, unslop) loads
# from the clone and is deliberately NOT bundled.
#
# Usage:
#   package-skills.sh [--out <dir>]   write <dir>/<skill>.zip per listed skill
#                                     (default: ${TMPDIR:-/tmp}/himmel-cloud-skills;
#                                     never inside the repo, so no artifact is committed)
#   package-skills.sh --list          print the skill names and their source dirs
# Seams: HIMMEL_CLOUD_SKILLS_DIR (default marketplace/plugins/lean-skills/skills),
# HIMMEL_CLOUD_SKILLS_LIST (space-separated; default below).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILLS_DIR="${HIMMEL_CLOUD_SKILLS_DIR:-$ROOT/marketplace/plugins/lean-skills/skills}"
# The short list: what a small cloud brief (fix, test, PR) reaches for. The rest
# of lean-skills (planning, worktrees, subagents, branch finishing) serve local
# multi-step legs; stuck-playbook (himmel-ops) recovers local guard denials the
# cloud does not have.
LIST="${HIMMEL_CLOUD_SKILLS_LIST:-test-driven-development systematic-debugging verification-before-completion}"
OUT_DIR="${TMPDIR:-/tmp}/himmel-cloud-skills"
MODE=pack

while [ "$#" -gt 0 ]; do
  case "$1" in
    --out) [ "$#" -ge 2 ] || { echo "package-skills: --out needs a directory" >&2; exit 2; }; OUT_DIR="$2"; shift ;;
    --list) MODE=list ;;
    *) echo "package-skills: unknown argument '$1'" >&2; exit 2 ;;
  esac
  shift
done

missing=0
for s in $LIST; do
  if [ -f "$SKILLS_DIR/$s/SKILL.md" ]; then
    [ "$MODE" = list ] && echo "$s  $SKILLS_DIR/$s"
  else
    echo "package-skills: skill '$s' has no SKILL.md under $SKILLS_DIR" >&2
    missing=$((missing + 1))
  fi
done
[ "$missing" -eq 0 ] || exit 1
[ "$MODE" = list ] && exit 0

mkdir -p "$OUT_DIR" || exit 1
for s in $LIST; do
  python3 - "$SKILLS_DIR" "$s" "$OUT_DIR/$s.zip" <<'PY' || exit 1
import os, sys, zipfile
base, skill, dest = sys.argv[1:4]
with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as z:
    for dirpath, _, files in os.walk(os.path.join(base, skill)):
        for f in sorted(files):
            p = os.path.join(dirpath, f)
            z.write(p, os.path.relpath(p, base))
PY
  echo "package-skills: wrote $OUT_DIR/$s.zip"
done
