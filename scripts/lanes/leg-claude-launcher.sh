#!/usr/bin/env bash
# scripts/lanes/leg-claude-launcher.sh - the `claude` stand-in that applies a
# leg's plugin profile (HIMMEL-2830, HIMMEL-2928 lever 1).
#
# WHY THIS EXISTS AT ALL. headed-arm.sh builds ONE fixed argv:
#
#     LAUNCH_ARGV=("$LAUNCHER" --model "$MODEL" --autocompact "$AUTOCOMPACT" \
#                  -n "$NAME" "load $DOC and continue")
#
# There is no pass-through for extra `claude` flags - only HEADED_ARM_LAUNCHER
# (which binary to exec) and HEADED_ARM_LAUNCHER_ENV (env tokens). A profile
# needs two real CLI flags, so the flags have to come from the binary side of
# that seam. That is exactly the shape scripts/claude-codex already proves on
# the claudex lane, so headed-arm.sh stays untouched (console ruling, N159).
#
# CONTRACT (all four clauses are load-bearing; a suite case pins each):
#  1. PREPEND ONLY. We add flags in FRONT of "$@" and never reorder, drop or
#     rewrite anything headed-arm.sh built - `--model`, `--autocompact`, `-n
#     <name>` and the prompt reach claude in their original order. That keeps
#     headed-arm.sh's own resolved-argv guard, its `_argv_has_n_name`
#     positional walk and its `[c]laude .*-n <name>` pgrep confirm all valid
#     after the exec below.
#  2. FAIL CLOSED on a missing file. If a profile was requested but its
#     settings or preface file is gone, we refuse rather than launch. A leg
#     that silently runs full-fat is undetectable from the outside and
#     corrupts the very measurement this ticket exists to make.
#  3. NO PROFILE, NO CHANGE. With neither variable set this is a transparent
#     `exec claude "$@"` - byte-identical argv to today.
#  4. It never widens anything. `--settings` here can only DISABLE plugins
#     (the resolver emits a complete enabledPlugins map, deny-by-default), and
#     `--mcp-config`/`--strict-mcp-config` (HIMMEL-2935) can only NARROW the
#     MCP servers available to the leg (the config file is a copy of real
#     definitions the resolver read elsewhere, never a hand-written one) -
#     neither ever adds a tool, permission or MCP server beyond what the
#     leg's own plugin set already carries.
#
# Env (set by headed-arm-leg.sh --profile, exported so it survives konsole's
# `-e env -u ...` line, which only unsets the three HIMMEL-2545 vars):
#   LEG_PROFILE_SETTINGS   path to the resolved settings JSON  -> --settings
#   LEG_PROFILE_PREFACE    path to docs/handover/leg-preface.md
#                                                   -> --append-system-prompt-file
#   LEG_PROFILE_MCP_CONFIG (HIMMEL-2935) path to the resolved MCP-server
#                           allowlist JSON, set only when the profile declares
#                           one -> --mcp-config <file> --strict-mcp-config.
#                           --strict-mcp-config makes that file the ONLY
#                           source of MCP servers for this launch - it strips
#                           plugin-bundled servers too, not just the
#                           ~/.claude.json user-level ones this exists to cut,
#                           which is exactly why the file is never hand-typed
#                           (see plugin-profiles.mjs's collectMcpServerDefs).
# Seam: LEG_CLAUDE_BIN overrides the `claude` binary this execs (default:
# `claude` from PATH) so a suite can point it at a recording stub.
#
# Platform: POSIX bash 3.2+ (macOS ships 3.2) - hence the
# ${PRE[@]+"${PRE[@]}"} empty-array expansion, which 3.2 needs under `set -u`.
#
# Platform guard: no .ps1 twin, by design. Its only caller is headed-arm.sh via
# HEADED_ARM_LAUNCHER, and that script is Linux/KDE-only (konsole).
set -u

CLAUDE_BIN="${LEG_CLAUDE_BIN:-claude}"

PRE=()

if [ -n "${LEG_PROFILE_SETTINGS:-}" ]; then
    if [ ! -f "$LEG_PROFILE_SETTINGS" ]; then
        echo "leg-claude-launcher: refusing to launch: LEG_PROFILE_SETTINGS is set but missing: $LEG_PROFILE_SETTINGS" >&2
        echo "leg-claude-launcher: launching without it would silently give this leg the FULL plugin set and a floor the ticket cannot measure." >&2
        exit 2
    fi
    PRE+=(--settings "$LEG_PROFILE_SETTINGS")
fi

if [ -n "${LEG_PROFILE_PREFACE:-}" ]; then
    if [ ! -f "$LEG_PROFILE_PREFACE" ]; then
        echo "leg-claude-launcher: refusing to launch: LEG_PROFILE_PREFACE is set but missing: $LEG_PROFILE_PREFACE" >&2
        echo "leg-claude-launcher: the preface carries the invariant leg rules the brief no longer repeats; a leg without it is under-briefed." >&2
        exit 2
    fi
    PRE+=(--append-system-prompt-file "$LEG_PROFILE_PREFACE")
fi

if [ -n "${LEG_PROFILE_MCP_CONFIG:-}" ]; then
    if [ ! -f "$LEG_PROFILE_MCP_CONFIG" ]; then
        echo "leg-claude-launcher: refusing to launch: LEG_PROFILE_MCP_CONFIG is set but missing: $LEG_PROFILE_MCP_CONFIG" >&2
        echo "leg-claude-launcher: launching without it under --strict-mcp-config would start the leg with NO MCP servers at all, silently breaking whatever this profile's allowlist promised it." >&2
        exit 2
    fi
    PRE+=(--mcp-config "$LEG_PROFILE_MCP_CONFIG" --strict-mcp-config)
fi

exec "$CLAUDE_BIN" ${PRE[@]+"${PRE[@]}"} "$@"
