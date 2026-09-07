#!/usr/bin/env bash
# Smoke test for scripts/lib/user-claude-md.sh's wire_user_claude_md
# (HIMMEL-2038 -- the user-scope "working principles" CLAUDE.md installer
# wired into adopt.sh's/adopt.ps1's do_core(), user-scope branch only).
#
# Every case runs against its own TEMP HOME fixture (mktemp -d) and an
# explicit --target path under it -- this NEVER reads or writes the real
# ~/.claude/CLAUDE.md.
#
# Usage: bash scripts/test-adopt-user-claude-md.sh
#
# Exit codes:
#   0 — all cases passed
#   1 — at least one case failed
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline, so a match under `set -o pipefail` can't be reported as a
# pipeline failure (HIMMEL-1430; same helper as test-check-no-secrets.sh).
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$SCRIPT_DIR/lib/user-claude-md.sh"
TEMPLATE="$REPO_ROOT/docs/setup/user-scope-claude-md-template.md"
MARKER="HIMMEL:working-principles"

if [ ! -f "$LIB" ]; then
  echo "FAIL: lib not found at $LIB"
  exit 1
fi
if [ ! -f "$TEMPLATE" ]; then
  echo "FAIL: template not found at $TEMPLATE"
  exit 1
fi

# shellcheck source=lib/user-claude-md.sh
# shellcheck disable=SC1091
. "$LIB"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

# ── Case 1: fresh HOME (no target file) → created, both markers + payload ──
echo "== Case 1: fresh HOME, no target file =="
home1="$(mktemp -d "${TMPDIR:-/tmp}/h2038.XXXXXX")"
target1="$home1/.claude/CLAUDE.md"
out1="$(DRY_RUN=0 wire_user_claude_md "$TEMPLATE" "$target1" 2>&1)"

if [ -f "$target1" ]; then pass "target created"; else fail "target NOT created"; fi
if grep -q -- "<!-- BEGIN $MARKER -->" "$target1" 2>/dev/null \
   && grep -q -- "<!-- END $MARKER -->" "$target1" 2>/dev/null; then
  pass "both marker lines present"
else
  fail "marker lines missing in created file"
fi
if grep -qi "simplicity first" "$target1" 2>/dev/null; then
  pass "payload text present"
else
  fail "payload text missing"
fi
if grepq "$out1" -F "created"; then pass "create status line printed"; else fail "no create status line, got: $out1"; fi
rm -rf "$home1"

# ── Case 2: existing file, unrelated content → payload appended, original
#            content preserved as an exact byte-for-byte prefix ──
echo "== Case 2: existing file, unrelated content =="
home2="$(mktemp -d "${TMPDIR:-/tmp}/h2038.XXXXXX")"
mkdir -p "$home2/.claude"
target2="$home2/.claude/CLAUDE.md"
orig2="$(mktemp "${TMPDIR:-/tmp}/h2038.XXXXXX")"
printf '# my own notes\nsome unrelated content\n' > "$orig2"
cp "$orig2" "$target2"
orig2_bytes="$(wc -c < "$orig2" | tr -d '[:space:]')"

out2="$(DRY_RUN=0 wire_user_claude_md "$TEMPLATE" "$target2" 2>&1)"

prefix2="$(mktemp "${TMPDIR:-/tmp}/h2038.XXXXXX")"
head -c "$orig2_bytes" "$target2" > "$prefix2"
if cmp -s "$orig2" "$prefix2"; then
  pass "original content preserved as exact prefix"
else
  fail "original content prefix does NOT match"
fi
if grep -q -- "<!-- BEGIN $MARKER -->" "$target2" 2>/dev/null; then
  pass "marker appended"
else
  fail "marker not appended"
fi
if grepq "$out2" -F "appended"; then pass "append status line printed"; else fail "no append status line, got: $out2"; fi
rm -f "$orig2" "$prefix2"

# ── Case 3: re-run over case 2's result → byte-identical, skip line printed ──
echo "== Case 3: re-run over an already-wired file =="
before3="$(mktemp "${TMPDIR:-/tmp}/h2038.XXXXXX")"
cp "$target2" "$before3"

out3="$(DRY_RUN=0 wire_user_claude_md "$TEMPLATE" "$target2" 2>&1)"

if cmp -s "$before3" "$target2"; then
  pass "file unchanged (byte-identical) on re-run"
else
  fail "file CHANGED on a re-run — not idempotent"
fi
if grepq "$out3" -F "already present"; then
  pass "skip line printed"
else
  fail "no skip line on re-run, got: $out3"
fi
rm -f "$before3"
rm -rf "$home2"

# ── Case 4: heuristic — existing file has "Simplicity first" but no marker
#            → left unchanged, heuristic skip line printed ──
echo "== Case 4: heuristic match (hand-written principles, no marker) =="
home4="$(mktemp -d "${TMPDIR:-/tmp}/h2038.XXXXXX")"
mkdir -p "$home4/.claude"
target4="$home4/.claude/CLAUDE.md"
printf '# My principles\n\n1. Simplicity first — do the minimum.\n' > "$target4"
before4="$(mktemp "${TMPDIR:-/tmp}/h2038.XXXXXX")"
cp "$target4" "$before4"

out4="$(DRY_RUN=0 wire_user_claude_md "$TEMPLATE" "$target4" 2>&1)"

if cmp -s "$before4" "$target4"; then
  pass "file unchanged (heuristic match — no marker duplicated)"
else
  fail "file CHANGED despite heuristic match"
fi
if grepq "$out4" -F "heuristic"; then
  pass "heuristic skip line printed"
else
  fail "no heuristic skip line, got: $out4"
fi
rm -f "$before4"
rm -rf "$home4"

# ── Case 5: template has a BEGIN marker but no END marker → refuse.
#            A sed range with an unmatched END address prints through EOF, so
#            without the guard the whole rest of the template would be appended
#            to the user's CLAUDE.md. ──
echo "== Case 5: unterminated marker range is refused =="
home5="$(mktemp -d "${TMPDIR:-/tmp}/h2038.XXXXXX")"
bad_template="$home5/bad-template.md"
printf '# doc\n\n<!-- BEGIN HIMMEL:working-principles -->\npayload line\n\nunrelated trailing prose that must NOT be installed\n' > "$bad_template"
target5="$home5/.claude/CLAUDE.md"

out5="$(DRY_RUN=0 wire_user_claude_md "$bad_template" "$target5" 2>&1)"

if [ ! -e "$target5" ]; then
  pass "target NOT created from an unterminated marker range"
else
  fail "target was created from an unterminated marker range: $(cat "$target5")"
fi
if grepq "$out5" -F "no END marker"; then
  pass "unterminated-range refusal line printed"
else
  fail "no unterminated-range refusal line, got: $out5"
fi
rm -rf "$home5"

# ── Case 6: two-target install (HIMMEL-2038 CR fix) -- adopt.sh/adopt.ps1 call
#            wire_user_claude_md once per user-scope rule file (Claude Code's
#            ~/.claude/CLAUDE.md AND Codex's ~/.codex/AGENTS.md) so a Codex
#            adopter isn't left with the principles nowhere. Fresh HOME -> both
#            created with the marker; re-run -> both byte-identical ──
echo "== Case 6: two-target install (Claude CLAUDE.md + Codex AGENTS.md) =="
home6="$(mktemp -d "${TMPDIR:-/tmp}/h2038.XXXXXX")"
claude_target6="$home6/.claude/CLAUDE.md"
codex_target6="$home6/.codex/AGENTS.md"

out6a="$(DRY_RUN=0 wire_user_claude_md "$TEMPLATE" "$claude_target6" 2>&1)"
out6b="$(DRY_RUN=0 wire_user_claude_md "$TEMPLATE" "$codex_target6" 2>&1)"

if [ -f "$claude_target6" ]; then pass "Claude target created"; else fail "Claude target NOT created"; fi
if [ -f "$codex_target6" ]; then pass "Codex target created"; else fail "Codex target NOT created"; fi
if grep -q -- "<!-- BEGIN $MARKER -->" "$claude_target6" 2>/dev/null \
   && grep -q -- "<!-- END $MARKER -->" "$claude_target6" 2>/dev/null; then
  pass "Claude target has both marker lines"
else
  fail "Claude target missing marker lines"
fi
if grep -q -- "<!-- BEGIN $MARKER -->" "$codex_target6" 2>/dev/null \
   && grep -q -- "<!-- END $MARKER -->" "$codex_target6" 2>/dev/null; then
  pass "Codex target has both marker lines"
else
  fail "Codex target missing marker lines"
fi
if grepq "$out6a" -F "created"; then pass "Claude create status line printed"; else fail "no Claude create status line, got: $out6a"; fi
if grepq "$out6b" -F "created"; then pass "Codex create status line printed"; else fail "no Codex create status line, got: $out6b"; fi

before6a="$(mktemp "${TMPDIR:-/tmp}/h2038.XXXXXX")"; cp "$claude_target6" "$before6a"
before6b="$(mktemp "${TMPDIR:-/tmp}/h2038.XXXXXX")"; cp "$codex_target6" "$before6b"

DRY_RUN=0 wire_user_claude_md "$TEMPLATE" "$claude_target6" >/dev/null 2>&1
DRY_RUN=0 wire_user_claude_md "$TEMPLATE" "$codex_target6" >/dev/null 2>&1

if cmp -s "$before6a" "$claude_target6"; then
  pass "Claude target unchanged (byte-identical) on re-run"
else
  fail "Claude target CHANGED on a re-run — not idempotent"
fi
if cmp -s "$before6b" "$codex_target6"; then
  pass "Codex target unchanged (byte-identical) on re-run"
else
  fail "Codex target CHANGED on a re-run — not idempotent"
fi
rm -f "$before6a" "$before6b"
rm -rf "$home6"

# Final tally
if [ "$failures" -eq 0 ]; then
  echo "OK: all cases passed"
  exit 0
else
  echo "FAIL: $failures case(s) failed"
  exit 1
fi
