#!/usr/bin/env bash
# HIMMEL-709 — smoke test for setup-hooks.sh --guardrail-mode.
# Hermetic: CLAUDE_USER_SETTINGS points at a temp file; never touches ~/.claude.
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SETUP="$HERE/../setup-hooks.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
SETTINGS="$TMP/settings.json"
REPO="$TMP/himmel"
mkdir -p "$REPO/scripts/hooks"
printf '{}\n' > "$SETTINGS"

fail() { echo "FAIL: $1" >&2; exit 1; }
wrapped_count() {
  CLAUDE_USER_SETTINGS="$SETTINGS" node -e '
    const fs=require("fs");
    const d=JSON.parse(fs.readFileSync(process.env.CLAUDE_USER_SETTINGS,"utf8"));
    let c=0;for(const g of (d.hooks&&d.hooks.PreToolUse)||[])for(const h of (g.hooks||[]))
      if(h.command&&h.command.includes("guardrail-skip-in-himmel.js"))c++;
    process.stdout.write(String(c));'
}

# 1. global --yes installs exactly three wrapped entries.
CLAUDE_USER_SETTINGS="$SETTINGS" HIMMEL_REPO="$REPO" bash "$SETUP" --guardrail-mode global --yes >/dev/null \
  || fail "global install exited non-zero"
n=$(wrapped_count)
[ "$n" = "3" ] || fail "expected 3 wrapped entries, got $n"

# 2. global -> project on a NON-TTY without --yes must ABORT (exit 3) and NOT mutate.
before=$(cat "$SETTINGS")
CLAUDE_USER_SETTINGS="$SETTINGS" HIMMEL_REPO="$REPO" bash "$SETUP" --guardrail-mode project </dev/null >/dev/null 2>&1
rc=$?
[ "$rc" = "3" ] || fail "expected non-tty destructive abort (exit 3), got $rc"
[ "$(cat "$SETTINGS")" = "$before" ] || fail "settings mutated on an aborted project transition"

# 3. idempotent re-run reports no changes.
out=$(CLAUDE_USER_SETTINGS="$SETTINGS" HIMMEL_REPO="$REPO" bash "$SETUP" --guardrail-mode global --yes)
case "$out" in *"no changes"*) ;; *) fail "expected 'no changes' on idempotent re-run, got: $out" ;; esac

# 4. project --yes removes the block.
CLAUDE_USER_SETTINGS="$SETTINGS" HIMMEL_REPO="$REPO" bash "$SETUP" --guardrail-mode project --yes >/dev/null \
  || fail "project remove exited non-zero"
n=$(wrapped_count)
[ "$n" = "0" ] || fail "expected 0 wrapped after project remove, got $n"

echo "PASS: setup-hooks --guardrail-mode smoke (install/abort/idempotent/remove)"
