#!/usr/bin/env bash
# marketplace/plugins/obsidian-triage/tools/ensure-deps.sh — dependency
# preflight for this tools/ directory (HIMMEL-1135).
#
# WHY: tools/.gitignore ignores node_modules/ ("Source files only ship in
# git"), so any git-derived copy of this directory NEVER carries deps —
# most critically the Claude plugin CACHE copy
# (~/.claude/plugins/cache/himmel/obsidian-triage/<v>/tools/), which is
# populated from git and can thus structurally never have node_modules.
# Eight tools import js-yaml (component-scan.mjs, dedup-sweep.mjs,
# fxtwitter-enrich.mjs, ig-embed-enrich.mjs, playwright-crawl-x.mjs,
# playwright-crawl-youtube.mjs, reddit-enrich.mjs, twitter-cli-enrich.mjs).
# Without this preflight, a runbook that shells out to one of them from the
# cache path throws `Cannot find package 'js-yaml'`, the tool reverts its
# write — and (a SEPARATE bug, HIMMEL-1136, NOT fixed here) still exits 0,
# so the failure is silent.
#
# Fast path (deps already present — the overwhelmingly common case): one
# `test -f`, no process spawn. Missing path: `npm install` (never
# downloads playwright's browser binaries — PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1;
# none of the js-yaml-importing tools launch a browser), then re-verify.
# Never exits 0 unless js-yaml is actually resolvable afterward — a install
# that "succeeds" but leaves the package missing is still a failure.
#
# Usage: bash ensure-deps.sh   (no args; resolves its own directory)
set -u -o pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARKER="$TOOLS_DIR/node_modules/js-yaml/package.json"

if [ -f "$MARKER" ]; then
  exit 0
fi

echo "ensure-deps: js-yaml not found under $TOOLS_DIR/node_modules - installing..." >&2

if ! command -v npm >/dev/null 2>&1; then
  echo "ensure-deps: FAILED - npm not on PATH, cannot install tool deps." >&2
  echo "  Remediation: install Node.js (bundles npm), then re-run, or by hand:" >&2
  echo "    (cd \"$TOOLS_DIR\" && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install --no-audit --no-fund)" >&2
  exit 1
fi

# Serialize installs against the shared node_modules tree (single-writer): two
# runbooks (or parallel harvests) hitting a fresh plugin-cache could both see the
# missing marker and npm-install the same tree at once. Atomic mkdir lock (flock
# is absent under Git Bash); bounded wait that re-checks the marker so a waiter
# whose peer finishes the install exits success without a redundant install.
LOCK_DIR="$TOOLS_DIR/.ensure-deps.lock"
_locked=0
_waited=0
while [ "$_waited" -lt 120 ]; do
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    _locked=1
    trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT
    break
  fi
  # A peer holds the lock; if it already finished the install, we are done.
  if [ -f "$MARKER" ]; then exit 0; fi
  sleep 1
  _waited=$((_waited + 1))
done
if [ "$_locked" -ne 1 ]; then
  echo "ensure-deps: FAILED - could not acquire the install lock at $LOCK_DIR after 120s." >&2
  echo "  Remediation: if no npm install is running, remove the stale lock and retry:" >&2
  echo "    rmdir \"$LOCK_DIR\"" >&2
  exit 1
fi
# Re-check AFTER locking: a peer may have completed the install while we waited.
if [ -f "$MARKER" ]; then exit 0; fi

# PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1: package.json also depends on
# playwright (used by the playwright-crawl-*.mjs / playwright-auth-save.mjs
# tools), whose postinstall otherwise fetches hundreds of MB of browser
# binaries. The js-yaml-importing tools this preflight exists for
# (fxtwitter-enrich.mjs etc.) are explicitly browser-free.
if ! ( cd "$TOOLS_DIR" && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install --no-audit --no-fund ); then
  echo "ensure-deps: FAILED - npm install did not complete in $TOOLS_DIR." >&2
  echo "  Remediation: check network/npm-registry access, then retry:" >&2
  echo "    (cd \"$TOOLS_DIR\" && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install)" >&2
  exit 1
fi

if [ ! -f "$MARKER" ]; then
  echo "ensure-deps: FAILED - npm install reported success but js-yaml is still missing." >&2
  echo "  Remediation: inspect $TOOLS_DIR/package.json and retry manually." >&2
  exit 1
fi

echo "ensure-deps: js-yaml installed OK." >&2
exit 0
