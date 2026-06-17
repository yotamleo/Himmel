#!/usr/bin/env bash
# scripts/plugin-test.sh — self-bootstrapping test entry point for a
# marketplace plugin that declares its own deps (HIMMEL-366).
#
# A fresh worktree only gets scripts/jira/ deps installed (by
# _new-worktree.sh), so a raw `bun test` in marketplace/plugins/<plugin>/
# fails with "Cannot find module '@modelcontextprotocol/sdk/...'" until
# someone runs `bun install` by hand. That RED baseline masks real
# regressions — a developer (or an overnight subagent) can't tell a
# pre-existing env failure from a change they just introduced.
#
# This helper installs the plugin's deps THEN runs its tests, so a fresh
# checkout reaches a GREEN baseline in one command. Opt-in per plugin: no
# per-worktree cost (you only `bun install` the plugin you actually test),
# and it self-bootstraps because `bun test` (the runner subcommand) never
# runs the package.json `start` script — the one that would `bun install`.
#
# Usage:
#   bash scripts/plugin-test.sh <plugin>      # dir name under marketplace/plugins/
#   bash scripts/plugin-test.sh luna-correlate
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  echo "Usage: $0 <plugin>" >&2
  echo "  <plugin> = a directory name under marketplace/plugins/ that has a package.json" >&2
  exit 2
}

[ $# -eq 1 ] || usage
PLUGIN="$1"
DIR="$ROOT/marketplace/plugins/$PLUGIN"

[ -d "$DIR" ] || { echo "ERR plugin-test: no such plugin dir: marketplace/plugins/$PLUGIN" >&2; exit 2; }
[ -f "$DIR/package.json" ] || { echo "ERR plugin-test: $PLUGIN has no package.json (nothing to bootstrap/test)" >&2; exit 2; }
command -v bun >/dev/null 2>&1 || { echo "ERR plugin-test: bun not on PATH (install: https://bun.sh)" >&2; exit 127; }

echo "== plugin-test: $PLUGIN =="
echo "-- bun install --no-summary"
( cd "$DIR" && bun install --no-summary )
echo "-- bun test"
( cd "$DIR" && bun test )
