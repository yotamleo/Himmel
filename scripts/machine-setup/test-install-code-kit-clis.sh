#!/usr/bin/env bash
# HIMMEL-4024: hermetic test for install-code-kit-clis.sh (--dry-run only, no installs).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/install-code-kit-clis.sh"
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

# A PATH holding only stubs: npm + apt-get present, ast-grep/shfmt/bats absent.
STUBS="$(mktemp -d "${TMPDIR:-/tmp}/code-kit-stubs.XXXXXX")" || exit 1
trap 'rm -rf "$STUBS"' EXIT
for t in npm apt-get; do printf '#!/bin/sh\nexit 0\n' > "$STUBS/$t"; chmod +x "$STUBS/$t"; done
for t in bash grep dirname sh env; do ln -s "$(command -v "$t")" "$STUBS/$t" 2>/dev/null || true; done

out="$(PATH="$STUBS" bash "$SCRIPT" --dry-run 2>&1)"; rc=$?
if [ "$rc" = 0 ]; then ok "dry-run exits 0"; else bad "dry-run rc=$rc: $out"; fi
# The pin literal is rewritten by the drift bump, so read it from the script rather than hardcoding it.
# shellcheck disable=SC2016 # the ${...} is literal text to match in the script, not an expansion
PIN="$(sed -n 's/^AST_GREP_VERSION="\${AST_GREP_VERSION:-\(.*\)}"$/\1/p' "$SCRIPT")"
case "$PIN" in [0-9]*.[0-9]*.[0-9]*) ok "pin extracted: $PIN" ;; *) bad "could not extract the pin from the script: '$PIN'" ;; esac
case "$out" in *"would run: npm install -g @ast-grep/cli@$PIN"*) ok "ast-grep pinned to $PIN" ;; *) bad "no pinned npm install ($PIN): $out" ;; esac
case "$out" in *"would run: sudo apt-get install -y shfmt bats"*) ok "shfmt + bats via apt" ;; *) bad "no apt install line: $out" ;; esac

out="$(AST_GREP_VERSION=9.9.9 PATH="$STUBS" bash "$SCRIPT" --dry-run 2>&1)"
case "$out" in *"@ast-grep/cli@9.9.9"*) ok "AST_GREP_VERSION override honoured" ;; *) bad "override ignored: $out" ;; esac

PATH="$STUBS" bash "$SCRIPT" --bogus >/dev/null 2>&1; rc=$?
if [ "$rc" = 2 ]; then ok "unknown flag exits 2"; else bad "unknown flag rc=$rc"; fi

echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" = 0 ]
