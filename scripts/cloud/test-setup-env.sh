#!/usr/bin/env bash
# test-setup-env.sh — scripts/cloud/setup-env.sh (HIMMEL-4206). Hermetic: every
# case runs --dry-run or a stubbed PATH, so nothing is installed and no network
# is touched. The script is a paste-in for a claude.ai cloud environment, so the
# contract worth pinning is: it plans every step, skips what is already present,
# changes nothing in dry-run, and rejects flags it does not know.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SETUP="$ROOT/scripts/cloud/setup-env.sh"
fails=0
ok() { echo "PASS - $1"; }
bad() { echo "FAIL - $1"; fails=$((fails + 1)); }

[ -f "$SETUP" ] || { echo "FAIL - $SETUP missing (every case below would pass or fail vacuously)"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cloud-setup-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# A fake repo root: the script must act on HIMMEL_CLOUD_ROOT, never on the real tree.
FAKE="$TMP/repo"
mkdir -p "$FAKE/scripts/jira" "$FAKE/marketplace/plugins/obsidian-triage/tools"
: > "$FAKE/scripts/jira/package.json"

# Stub bin: tools the script probes with `command -v`. An empty PATH dir means
# "nothing installed"; a stub means "already present".
EMPTY="$TMP/empty"; mkdir -p "$EMPTY"
HAVE="$TMP/have"; mkdir -p "$HAVE"
for t in shellcheck at pre-commit; do printf '#!/bin/sh\nexit 0\n' > "$HAVE/$t"; chmod +x "$HAVE/$t"; done

BASH_BIN="$(command -v bash)"
run() { # run <path-dir> [args...] -> stdout in $OUT, rc in $RC
  local pdir="$1"; shift
  # PATH is ONLY the stub dir: the host's own /usr/bin may already carry shellcheck.
  OUT="$(env -i PATH="$pdir" HIMMEL_CLOUD_ROOT="$FAKE" "$BASH_BIN" "$SETUP" "$@" 2>&1)"
  RC=$?
}

# 1. dry-run plans every step and exits 0.
run "$EMPTY" --dry-run
if [ "$RC" -eq 0 ]; then ok "dry-run exits 0"; else bad "dry-run rc=$RC: $OUT"; fi
for step in shellcheck at pre-commit jira-dist obsidian-deps env; do
  case "$OUT" in *"step=$step "*) ok "dry-run plans step $step" ;; *) bad "dry-run omits step $step: $OUT" ;; esac
done

# 2. nothing present -> shellcheck planned as install; present -> skip.
case "$OUT" in *"step=shellcheck action=install"*) ok "absent shellcheck is planned as install" ;; *) bad "absent shellcheck not install: $OUT" ;; esac
run "$HAVE" --dry-run
case "$OUT" in *"step=shellcheck action=skip"*) ok "present shellcheck is skipped" ;; *) bad "present shellcheck not skipped: $OUT" ;; esac

# 3. a built jira dist is skipped (idempotent re-run inside the 5-min cache window).
mkdir -p "$FAKE/scripts/jira/dist"; : > "$FAKE/scripts/jira/dist/index.js"
run "$HAVE" --dry-run
case "$OUT" in *"step=jira-dist action=skip"*) ok "built jira dist is skipped" ;; *) bad "built dist not skipped: $OUT" ;; esac
rm -rf "$FAKE/scripts/jira/dist"

# 4. dry-run changes nothing in the tree.
run "$EMPTY" --dry-run
if [ ! -e "$FAKE/scripts/jira/dist" ] && [ ! -e "$FAKE/scripts/jira/node_modules" ]; then ok "dry-run leaves the tree untouched"; else bad "dry-run created files"; fi

# 5. the timeout export is part of the plan and carries a number.
case "$OUT" in *"BASH_DEFAULT_TIMEOUT_MS=600000"*) ok "plans BASH_DEFAULT_TIMEOUT_MS=600000" ;; *) bad "no BASH_DEFAULT_TIMEOUT_MS in plan: $OUT" ;; esac

# 6. plugin experiment is OFF by default, planned only with --with-plugins.
case "$OUT" in *"step=plugins "*) bad "plugins step planned without --with-plugins" ;; *) ok "plugins step off by default" ;; esac
run "$EMPTY" --dry-run --with-plugins
case "$OUT" in *"step=plugins action=experiment"*) ok "--with-plugins plans the experiment" ;; *) bad "--with-plugins not planned: $OUT" ;; esac

# 7. an unknown flag is refused (rc 2) rather than silently ignored.
run "$EMPTY" --nope
if [ "$RC" -eq 2 ]; then ok "unknown flag exits 2"; else bad "unknown flag rc=$RC"; fi

# 8. syntax + lint.
if bash -n "$SETUP"; then ok "bash -n clean"; else bad "bash -n failed"; fi
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck "$SETUP" >/dev/null 2>&1; then ok "shellcheck clean"; else bad "shellcheck findings"; fi
else
  echo "SKIP - shellcheck not installed here"
fi

if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed."; exit 1; fi
echo "all checks passed."
