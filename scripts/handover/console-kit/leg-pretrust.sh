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

# The trailing "x" keeps $(...) from eating a newline that is part of the directory name.
abs="$(cd -P "$dir" 2>/dev/null && pwd -P && printf x)" || { echo "leg-pretrust: cannot resolve: $dir" >&2; exit 2; }
abs="${abs%x}"; abs="${abs%$'\n'}"   # drop the x, then the one newline pwd added
home="$(cd -P "${LEG_PRETRUST_HOME:-$HOME}" 2>/dev/null && pwd -P)" || { echo "leg-pretrust: cannot resolve HOME" >&2; exit 2; }  # LEG_PRETRUST_HOME: test seam

refuse() { echo "leg-pretrust: REFUSED $abs: $1" >&2; exit 3; }

case "$abs" in
    *$'\n'*|*/) refuse "path has a newline or ends in / (it would not round-trip as a projects key)" ;;
esac

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
# Jailed rows (HIMMEL-5068, pilot p20): claude runs inside a bwrap jail where the
# worktree is bound at another path and ~/.claude-<lane> is a per-row copy, so the
# flag must land in THAT config under THAT path. LEG_PRETRUST_CONFIG names the
# config file and LEG_PRETRUST_KEY the project key; the directory is still checked
# above. The jail can write the row's config dir, so in that mode nothing in it is
# trusted: the config, its sidecar and its lock must not be symlinks (the host would
# write through them), the dir must be ours, and the config must not be a real lane
# config. The key is honoured only with the config, as <repo>/.claude/worktrees/<same
# last component as the checked dir> with no empty or dot segment (the jail re-binds
# the same worktree, it never trusts a different one).
if [ -n "${LEG_PRETRUST_KEY:-}" ] && [ -z "${LEG_PRETRUST_CONFIG:-}" ]; then
    refuse "LEG_PRETRUST_KEY is honoured only together with LEG_PRETRUST_CONFIG"
fi
if [ -n "${LEG_PRETRUST_CONFIG:-}" ]; then
    case "$LEG_PRETRUST_CONFIG" in
        /*/.claude.json) cfg="$LEG_PRETRUST_CONFIG" ;;
        *) echo "leg-pretrust: LEG_PRETRUST_CONFIG must be an absolute path ending in /.claude.json" >&2; exit 2 ;;
    esac
    cfgdir="$(cd -P "$(dirname "$cfg")" 2>/dev/null && pwd -P)" || cfgdir=""
    [ -n "$cfgdir" ] || { echo "leg-pretrust: lane config dir absent (launcher not seeded yet): $(dirname "$cfg")" >&2; exit 4; }
    case "$cfgdir" in
        "$home"|"$home/.claude-codex"|"$home/.claude-openrouter"|"$home/.claude-deepseek") refuse "LEG_PRETRUST_CONFIG is a real lane config" ;;
    esac
    [ -O "$cfgdir" ] || refuse "LEG_PRETRUST_CONFIG dir is not owned by the current user"
    for f in "$cfg" "$cfg.lock" "$cfg.leg-pretrust.owner"; do
        [ ! -L "$f" ] || refuse "$f is a symlink (a jailed lane could point it outside the row)"
    done
fi
if [ -n "${LEG_PRETRUST_KEY:-}" ]; then
    case "$LEG_PRETRUST_KEY" in
        *$'\n'*|*/|*//*|*/./*|*/.|*/../*|*/..) refuse "LEG_PRETRUST_KEY has a newline, trailing /, empty or dot segment" ;;
        /*/.claude/worktrees/"${abs##*/}") abs="$LEG_PRETRUST_KEY" ;;
        *) refuse "LEG_PRETRUST_KEY must be <repo>/.claude/worktrees/${abs##*/}" ;;
    esac
fi
# Never create a lane config dir: the lane launcher seeds it, and a dir it did not
# seed reads to it as a half-seeded one.
[ -d "$(dirname "$cfg")" ] || { echo "leg-pretrust: lane config dir absent (launcher not seeded yet): $(dirname "$cfg")" >&2; exit 4; }

# Take the lock claude itself takes when it saves this file (claude 2.1.295
# saveConfigWithLock: proper-lockfile with lockfilePath "<cfg>.lock" - a mkdir
# directory whose mtime the holder refreshes every 5 s, stale after 10 s), so
# pretrust and a live claude exclude each other. Nothing may live INSIDE that
# dir (claude releases it with rmdir), so our owner pid is a sidecar file.
# ponytail: pid reuse can keep a dead owner "alive", a pid on another host is
# not checked; upgrade path is a host+start-time stamp in the sidecar.
lock="$cfg.lock"
owner="$cfg.leg-pretrust.owner"
mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }
# Stale = claude's own rule (no mtime refresh for >10 s) AND no live owner of ours.
lock_reclaimable() {
    local m opid
    m="$(mtime_of "$lock")" || return 1
    [ -n "$m" ] && [ $(( $(date +%s) - m )) -gt 10 ] || return 1
    opid="$(cat "$owner" 2>/dev/null)"
    [ -n "$opid" ] && kill -0 "$opid" 2>/dev/null && return 1
    return 0
}
tries="${LEG_PRETRUST_LOCK_TRIES:-150}"   # x 0.1 s; > a 10 s stale window. LEG_PRETRUST_LOCK_TRIES: test seam
waited=0
until mkdir "$lock" 2>/dev/null; do
    # A reclaim that cannot remove the dir falls through to the timeout count below.
    if [ -d "$lock" ] && lock_reclaimable && rmdir "$lock" 2>/dev/null; then
        continue
    fi
    waited=$((waited + 1))
    [ "$waited" -le "$tries" ] || { echo "leg-pretrust: lock timeout: $lock" >&2; exit 5; }
    sleep 0.1
done
# The sidecar may be stale or a planted symlink: drop it (rm never follows) and create
# it O_EXCL (noclobber), so the pid is never written through a link.
rm -f "$owner" 2>/dev/null
( set -C; echo "$$" > "$owner" ) 2>/dev/null || true
# Release only a lock we still own: a reclaimed-then-retaken lock is the successor's.
trap '[ "$(cat "$owner" 2>/dev/null)" = "$$" ] && { rm -f "$owner"; rmdir "$lock" 2>/dev/null; }; true' EXIT

WT_KEY="$abs" WT_CONFIG="$cfg" node -e '
const fs = require("fs");
const key = process.env.WT_KEY;
// A symlinked config is written THROUGH (the link stays); the rename targets the real file.
let p = process.env.WT_CONFIG;
try { if (fs.lstatSync(p).isSymbolicLink()) p = fs.realpathSync(p); } catch (e) {
    if (e.code !== "ENOENT") { console.error("leg-pretrust: cannot resolve " + p + " (" + e.message + ")"); process.exit(4); }
    try { fs.lstatSync(p); console.error("leg-pretrust: " + p + " is a dangling symlink - refusing to write"); process.exit(4); } catch (_) {}
}
const obj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const sig = () => { try { const s = fs.statSync(p); return s.mtimeMs + ":" + s.size; } catch (_) { return "none"; } };
// Live claude sessions write this file without our lock, so re-check its
// mtime+size right before the rename and redo the read-modify-write if it moved.
for (let attempt = 0; attempt < 5; attempt++) {
    const before = sig();
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
    // A present-but-non-object projects / projects[key] is data we do not own: refuse, never overwrite.
    if (j.projects !== undefined && !obj(j.projects)) { console.error("leg-pretrust: " + p + " has a non-object projects - refusing to overwrite"); process.exit(4); }
    if (j.projects === undefined) j.projects = {};
    if (j.projects[key] !== undefined && !obj(j.projects[key])) { console.error("leg-pretrust: " + p + " has a non-object projects[" + key + "] - refusing to overwrite"); process.exit(4); }
    if (j.projects[key] === undefined) j.projects[key] = {};
    if (j.projects[key].hasTrustDialogAccepted === true) process.exit(0);
    j.projects[key].hasTrustDialogAccepted = true;
    const tmp = p + ".tmp-pretrust-" + process.pid;
    // Keep the mode as found (claude does the same); a new file gets the 0600 default claude uses.
    let mode = 0o600;
    try { mode = fs.statSync(p).mode & 0o777; } catch (_) {}
    try {
        fs.writeFileSync(tmp, JSON.stringify(j, null, 2) + "\n", { mode: 0o600, flag: "wx" });
        fs.chmodSync(tmp, mode);
        if (sig() !== before) { fs.unlinkSync(tmp); continue; }
        fs.renameSync(tmp, p);
        process.exit(0);
    } catch (e) {
        try { fs.unlinkSync(tmp); } catch (_) {}
        console.error("leg-pretrust: could not write " + p + ": " + e.message);
        process.exit(4);
    }
}
console.error("leg-pretrust: " + p + " kept changing under us - gave up without writing");
process.exit(4);
'
