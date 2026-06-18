#!/usr/bin/env bash
# ensure-workspace-trust.sh <dir>  (HIMMEL-386)
#
# Pre-trust <dir> in Claude Code's config (~/.claude.json) so an autonomous
# `claude` launch with that dir as cwd does NOT stall on the interactive
# workspace-trust prompt ("Is this a project you created or one you trust?").
# Autonomous arms (handover resume via arm-resume.sh, clip-pipeline cadence
# via pipeline-cadence.sh) have no human to answer it and their stdin is
# absent or /dev/null, so an untrusted cwd silently wastes the whole run.
#
# Sets projects[<key>].hasTrustDialogAccepted = true via an atomic
# read-modify-write. <key> matches how Claude stores it (observed as of
# HIMMEL-386): on Windows the `cygpath -m` mixed form (C:/Users/...),
# elsewhere the absolute path from `cd "$dir" && pwd`.
#
# Config path: $WORKSPACE_TRUST_CONFIG, else $HOME/.claude.json.
#
# Exit codes:
#   0  flag is set (already-true is a no-op that also exits 0)
#   2  bad usage / dir does not exist / node missing
#   3  config exists but is unreadable, not parseable JSON, or not a JSON
#      object — REFUSES to overwrite (never clobber Claude's state on a
#      transient read or parse error)
#
# Callers MUST treat a non-zero exit as NON-FATAL (warn, then continue): a
# trust pre-seed problem must never block an arm. The exit codes exist so
# the test harness can assert behaviour, not so callers can abort on them.
set -uo pipefail

dir="${1:-}"
if [ -z "$dir" ]; then
    echo "ensure-workspace-trust: usage: ensure-workspace-trust.sh <dir>" >&2
    exit 2
fi
if [ ! -d "$dir" ]; then
    echo "ensure-workspace-trust: not a directory: $dir" >&2
    exit 2
fi
if ! command -v node >/dev/null 2>&1; then
    echo "ensure-workspace-trust: node not on PATH" >&2
    exit 2
fi

# Absolute path, then normalize to the key form Claude persists.
abs=$(cd "$dir" && pwd)
if [ -z "$abs" ]; then
    # cd succeeded the -d check but pwd came back empty (dir vanished mid-run);
    # never write an empty trust key.
    echo "ensure-workspace-trust: could not resolve absolute path for: $dir" >&2
    exit 2
fi
if command -v cygpath >/dev/null 2>&1; then
    key=$(cygpath -m "$abs")   # /c/Users/... -> C:/Users/...
else
    key="$abs"
fi

config="${WORKSPACE_TRUST_CONFIG:-$HOME/.claude.json}"

# node does the read-modify-write: tolerant of a missing file (fresh create),
# strict on a present-but-unparseable file (refuse to clobber), atomic via
# write-to-temp + rename. Key/config passed by env to avoid all shell quoting.
WT_KEY="$key" WT_CONFIG="$config" node -e '
const fs = require("fs");
const p = process.env.WT_CONFIG, key = process.env.WT_KEY;
let raw = null;
try {
    raw = fs.readFileSync(p, "utf8");
} catch (e) {
    if (e.code !== "ENOENT") {
        console.error("ensure-workspace-trust: cannot read " + p + ": " + e.message);
        process.exit(3);
    }
}
let j = {};
if (raw !== null) {
    try {
        j = JSON.parse(raw);
    } catch (e) {
        console.error("ensure-workspace-trust: " + p + " is not valid JSON - refusing to overwrite");
        process.exit(3);
    }
    if (typeof j !== "object" || j === null || Array.isArray(j)) {
        console.error("ensure-workspace-trust: " + p + " is not a JSON object - refusing to overwrite");
        process.exit(3);
    }
}
if (!j.projects || typeof j.projects !== "object" || Array.isArray(j.projects)) j.projects = {};
if (!j.projects[key] || typeof j.projects[key] !== "object" || Array.isArray(j.projects[key])) j.projects[key] = {};
if (j.projects[key].hasTrustDialogAccepted === true) process.exit(0);
j.projects[key].hasTrustDialogAccepted = true;
const tmp = p + ".tmp-trust-" + process.pid;
fs.writeFileSync(tmp, JSON.stringify(j, null, 2));
fs.renameSync(tmp, p);
'
