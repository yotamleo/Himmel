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
#   LEG_PROFILE_NO_SETTING_SOURCES (HIMMEL-4069) exactly 1 -> --setting-sources ""
#                           (an empty list: no user, project or local settings
#                           scope loads, only --settings and managed policy).
#                           Set only by headed-arm-leg.sh --consult, whose
#                           sandbox those scopes' write roots would widen. It
#                           only ever loads LESS (clause 4).
# Seam: LEG_CLAUDE_BIN overrides the `claude` binary this execs (default:
# `claude` from PATH). headed-arm-leg.sh sets it to scripts/claude-codex on
# the claudex lane so all profile flags reach that backend (HIMMEL-2962);
# suites can point it at a recording stub.
#
# Platform: POSIX bash 3.2+ (macOS ships 3.2) - hence the
# ${PRE[@]+"${PRE[@]}"} empty-array expansion, which 3.2 needs under `set -u`.
#
# Platform guard: no .ps1 twin, by design. Its only caller is headed-arm.sh via
# HEADED_ARM_LAUNCHER, and that script is Linux/KDE-only (konsole).
set -u

CLAUDE_BIN="${LEG_CLAUDE_BIN:-claude}"

# (HIMMEL-4152) Under a consult the caller's PATH must not pick the binary: a
# foreign `claude` first on PATH could ignore `--setting-sources ""`. Resolve it
# once from the pinned PATH in consult-env.sh (its home part comes from the
# passwd entry, not the caller-set $HOME). A consult reaches here through
# leg-claude-launcher-consult.sh, which already ran this on an absolute
# `bash -p` with the startup variables and exported functions stripped, so
# `type -P` below is a plain PATH search. LEG_CLAUDE_BIN stays the suite's
# seam: headed-arm-leg.sh scrubs it (var + token) and refuses its
# HEADED_ARM_LEG_CLAUDE_BIN source before a consult launches, so no consult
# reaches here with it set. The ponytail for the pinned dirs is in consult-env.sh.
if [ "${LEG_PROFILE_NO_SETTING_SOURCES:-}" = 1 ] && [ -z "${LEG_CLAUDE_BIN:-}" ]; then
    # shellcheck source=consult-env.sh
    if ! . "${BASH_SOURCE[0]%/*}/consult-env.sh"; then
        echo "leg-claude-launcher: refusing to launch: LEG_PROFILE_NO_SETTING_SOURCES=1 (a consult) but consult-env.sh did not load" >&2
        exit 2
    fi
    _pin_path="$(consult_pin_path)"
    # shellcheck disable=SC2030  # the lookup PATH is subshell-local on purpose
    CLAUDE_BIN="$(PATH="$_pin_path"; type -P claude 2>/dev/null)" || CLAUDE_BIN=""
    case "$CLAUDE_BIN" in
        /*) ;;
        *)
            echo "leg-claude-launcher: refusing to launch: LEG_PROFILE_NO_SETTING_SOURCES=1 (a consult) but no claude on the pinned PATH ($_pin_path); a consult never runs the caller's PATH claude" >&2
            exit 2 ;;
    esac
    # An npm-installed claude is a `#!/usr/bin/env node` script, and claude
    # spawns helpers by name: the consult runs on the pinned PATH alone, so
    # neither can resolve through a caller-chosen dir.
    PATH="$_pin_path"
    export PATH
    unset -v _pin_path
fi

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

# HIMMEL-4786: headed-arm-leg.sh minted this id and already recorded it in the
# leg doc's front matter, so the digest step finds the session by id.
[ -z "${LEG_SESSION_ID:-}" ] || PRE+=(--session-id "$LEG_SESSION_ID")
if [ "${LEG_PROFILE_NO_SETTING_SOURCES:-}" = 1 ]; then
    PRE+=(--setting-sources "")
    # (HIMMEL-4118 F1) The consult is confined only if the FINAL argv carries
    # `--setting-sources ""` and nothing after it names the flag again (the
    # last occurrence wins, so a caller-built `--setting-sources user,project`
    # would load the scopes this exists to cut). Refuse rather than launch.
    for _nss_arg in "$@"; do
        case "$_nss_arg" in
            --setting-sources|--setting-sources=*)
                echo "leg-claude-launcher: refusing to launch: LEG_PROFILE_NO_SETTING_SOURCES=1 (a consult) but the caller's argv names --setting-sources again, which would override the empty list and load the user/project/local scopes" >&2
                exit 2 ;;
        esac
    done
fi

exec "$CLAUDE_BIN" ${PRE[@]+"${PRE[@]}"} "$@"
