#!/usr/bin/env bash
# test-package-skills.sh — scripts/cloud/package-skills.sh (HIMMEL-4206 slice 6).
# The bundle is what the operator uploads to claude.ai, so the contract is: one
# zip per listed skill, SKILL.md at <skill>/SKILL.md inside it, nothing from a
# skill the list does not name, and a hard refusal on a missing skill.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PKG="$ROOT/scripts/cloud/package-skills.sh"
fails=0
ok() { echo "PASS - $1"; }
bad() { echo "FAIL - $1"; fails=$((fails + 1)); }

[ -f "$PKG" ] || { echo "FAIL - $PKG missing (every case below would pass or fail vacuously)"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cloud-pkg-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# Fixture skills tree: one real-shaped skill, one decoy the list must not pick up.
SK="$TMP/skills"
mkdir -p "$SK/alpha/sub" "$SK/decoy"
printf -- '---\nname: alpha\ndescription: a\n---\nbody\n' > "$SK/alpha/SKILL.md"
printf 'x\n' > "$SK/alpha/sub/extra.md"
printf -- '---\nname: decoy\ndescription: d\n---\n' > "$SK/decoy/SKILL.md"

OUTD="$TMP/out"
OUT="$(HIMMEL_CLOUD_SKILLS_DIR="$SK" HIMMEL_CLOUD_SKILLS_LIST="alpha" bash "$PKG" --out "$OUTD" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then ok "packaging exits 0"; else bad "rc=$RC: $OUT"; fi
if [ -f "$OUTD/alpha.zip" ]; then ok "alpha.zip written"; else bad "alpha.zip missing: $OUT"; fi
if [ ! -e "$OUTD/decoy.zip" ]; then ok "unlisted skill not packaged"; else bad "decoy.zip packaged"; fi

LIST="$(python3 -c 'import sys,zipfile; print("\n".join(sorted(zipfile.ZipFile(sys.argv[1]).namelist())))' "$OUTD/alpha.zip" 2>&1)"
case "$LIST" in *"alpha/SKILL.md"*) ok "SKILL.md sits at alpha/SKILL.md" ;; *) bad "zip layout: $LIST" ;; esac
case "$LIST" in *"alpha/sub/extra.md"*) ok "supporting files included" ;; *) bad "supporting file missing: $LIST" ;; esac

# A listed skill that does not exist must fail loudly, not produce a partial bundle.
OUT="$(HIMMEL_CLOUD_SKILLS_DIR="$SK" HIMMEL_CLOUD_SKILLS_LIST="alpha ghost" bash "$PKG" --out "$TMP/out2" 2>&1)"; RC=$?
if [ "$RC" -ne 0 ]; then ok "missing skill fails"; else bad "missing skill passed: $OUT"; fi

# The shipped default list names only skills that exist in the real tree.
OUT="$(bash "$PKG" --list 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then ok "--list resolves the default skills"; else bad "--list rc=$RC: $OUT"; fi

if bash -n "$PKG"; then ok "bash -n clean"; else bad "bash -n failed"; fi
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck "$PKG" >/dev/null 2>&1; then ok "shellcheck clean"; else bad "shellcheck findings"; fi
else
  echo "SKIP - shellcheck not installed here"
fi

if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed."; exit 1; fi
echo "all checks passed."
