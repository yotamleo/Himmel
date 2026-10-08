#!/usr/bin/env bash
# leg-pretrust.sh <lane> <dir>  (HIMMEL-5056)
#
# Pre-accept Claude Code's folder-trust state for a leg's working directory so a
# headed leg does not park at the "Is this a project you trust?" prompt (the
# operator is not there to click it). Claude Code gates project hooks on the
# same flag (hooksSkippedByTrust / hookModulesAwaitTrust read the trust state,
# there is no separate hooks-approval key in the CLI), so the one
# projects[<dir>].hasTrustDialogAccepted write covers both prompts.
#
# Only two kinds of directory qualify; anything else is REFUSED (exit 3) and
# nothing is written:
#   (a) a linked git worktree strictly under <primary checkout>/.claude/worktrees/
#   (b) a path strictly under $HOME/.himmel/eval/
# Never $HOME, /, the primary checkout itself, or /tmp.
#
# The config file is the one the lane's claude reads: native -> ~/.claude.json,
# claudex/openrouter/deepseek -> ~/.claude-<lane dir>/.claude.json. It is shared
# by every live session, so the read-modify-write runs under a mkdir lock and
# commits by temp file + rename; other keys are preserved verbatim.
#
# Exit: 0 trusted (or already), 2 usage / missing dir / no node, 3 refused path,
# 4 config unreadable/unparseable (never clobbered) or write failed, 5 lock timeout.
# Callers treat non-zero as NON-FATAL: a pretrust problem must not block a launch.
set -uo pipefail

# shellcheck source=../../lib/git-clean.sh
. "$(dirname "$0")/../../lib/git-clean.sh"
git_env_scrub   # an inherited GIT_DIR would make the worktree check read the wrong repo

lane="${1:-}"; dir="${2:-}"
if [ -z "$lane" ] || [ -z "$dir" ]; then
    echo "leg-pretrust: usage: leg-pretrust.sh <native|claudex|openrouter|deepseek> <dir>" >&2
    exit 2
fi
[ -d "$dir" ] || { echo "leg-pretrust: not a directory: $dir" >&2; exit 2; }
command -v node >/dev/null 2>&1 || { echo "leg-pretrust: node not on PATH" >&2; exit 2; }

abs="$(cd -P "$dir" 2>/dev/null && pwd -P)" || { echo "leg-pretrust: cannot resolve: $dir" >&2; exit 2; }
home="$(cd -P "${LEG_PRETRUST_HOME:-$HOME}" 2>/dev/null && pwd -P)" || { echo "leg-pretrust: cannot resolve HOME" >&2; exit 2; }  # LEG_PRETRUST_HOME: test seam

refuse() { echo "leg-pretrust: REFUSED $abs: $1" >&2; exit 3; }

ok=0
case "$abs/" in
    "$home/.himmel/eval/"?*) ok=1 ;;
esac
if [ "$ok" -eq 0 ]; then
    common="$(git -C "$abs" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || common=""
    gitdir="$(git -C "$abs" rev-parse --path-format=absolute --git-dir 2>/dev/null)" || gitdir=""
    if [ -n "$common" ] && [ "$common" != "$gitdir" ]; then
        primary="$(cd -P "$common/.." 2>/dev/null && pwd -P)" || primary=""
        case "$abs/" in
            "$primary/.claude/worktrees/"?*) [ -n "$primary" ] && ok=1 ;;
        esac
    fi
fi
[ "$ok" -eq 1 ] || refuse "not a linked worktree under <primary>/.claude/worktrees/ nor a path under \$HOME/.himmel/eval/"

case "$lane" in
    native) cfg="$home/.claude.json" ;;
    claudex) cfg="$home/.claude-codex/.claude.json" ;;
    openrouter) cfg="$home/.claude-openrouter/.claude.json" ;;
    deepseek) cfg="$home/.claude-deepseek/.claude.json" ;;
    *) echo "leg-pretrust: unknown lane: $lane" >&2; exit 2 ;;
esac
# Never create a lane config dir: the lane launcher seeds it, and a dir it did not
# seed reads to it as a half-seeded one.
[ -d "$(dirname "$cfg")" ] || { echo "leg-pretrust: lane config dir absent (launcher not seeded yet): $(dirname "$cfg")" >&2; exit 4; }

# mkdir lock beside the config; a holder that died is reclaimed after 1-2 min.
lock="$cfg.leg-pretrust.lock"
waited=0
until mkdir "$lock" 2>/dev/null; do
    if [ -d "$lock" ] && [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
        rmdir "$lock" 2>/dev/null || true
        continue
    fi
    waited=$((waited + 1))
    [ "$waited" -le 100 ] || { echo "leg-pretrust: lock timeout: $lock" >&2; exit 5; }
    sleep 0.1
done
trap 'rmdir "$lock" 2>/dev/null || true' EXIT

WT_KEY="$abs" WT_CONFIG="$cfg" node -e '
const fs = require("fs");
const p = process.env.WT_CONFIG, key = process.env.WT_KEY;
const obj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
let j = {};
try {
    j = JSON.parse(fs.readFileSync(p, "utf8"));
} catch (e) {
    if (e.code !== "ENOENT") {
        console.error("leg-pretrust: cannot use " + p + " (" + e.message + ") - refusing to overwrite");
        process.exit(4);
    }
}
if (!obj(j)) { console.error("leg-pretrust: " + p + " is not a JSON object - refusing to overwrite"); process.exit(4); }
if (!obj(j.projects)) j.projects = {};
if (!obj(j.projects[key])) j.projects[key] = {};
if (j.projects[key].hasTrustDialogAccepted === true) process.exit(0);
j.projects[key].hasTrustDialogAccepted = true;
const tmp = p + ".tmp-pretrust-" + process.pid;
try {
    fs.writeFileSync(tmp, JSON.stringify(j, null, 2) + "\n", { mode: 0o600 });
    fs.renameSync(tmp, p);
} catch (e) {
    try { fs.unlinkSync(tmp); } catch (_) {}
    console.error("leg-pretrust: could not write " + p + ": " + e.message);
    process.exit(4);
}
'
