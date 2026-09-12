#!/usr/bin/env bash
# scripts/handover/console-kit/headed-arm-leg.sh - versioned LEG launcher
# (HIMMEL-2766). A thin wrapper around scripts/handover/headed-arm.sh that
# pins every leg arm to the standard --autocompact 200000 ceiling - the window
# itself measures 1M regardless (docs/internals/lane-calibration.md "What a
# plain launch reports") - and adds the leg-only env the console lane does not
# need.
#
# WHY (console correction 12:1x on HIMMEL-2766, on the ticket): legs were
# ALREADY on the standard window today - the HIMMEL-2658 mechanism is the
# model-id suffix (`<model>[1m]` + `--autocompact auto` = 1M; no suffix =
# standard - see docs/internals/lane-calibration.md "Context mode" and
# headed-arm.sh's own --context handling, which this wrapper reuses rather
# than forking). What was missing was a fail-closed PIN: the resolved leg argv
# must carry the cost-driving `--autocompact 200000`, not merely lack a [1m]
# model suffix. LEG_CONTEXT=1m therefore refuses with an actionable exit 2.
# The raw model string is still headed-arm.sh's concern: a caller handing this
# wrapper an already-[1m]-suffixed model gets it forwarded unchanged, and
# headed-arm.sh strips it under standard mode (test-headed-arm-leg.sh asserts
# this end-to-end).
#
# Folds the two prior ad-hoc kit-local copies (headed-arm-leg.sh,
# headed-arm-leg-cwd.sh - identical except an LEG_REPO override) into ONE
# versioned script: LEG_REPO now maps onto headed-arm.sh's own
# HEADED_ARM_REPO seam instead of a second, parallel repo-root variable.
#
# Usage: headed-arm-leg.sh [--dry-run] <session-name> <handover-doc> \
#                           <signal-file> <deadline-epoch> <log> [model]
# Run detached, same as headed-arm.sh itself:
#   setsid nohup bash headed-arm-leg.sh ... >/dev/null 2>&1 &
#
# --dry-run: prints the argv this would hand to headed-arm.sh (name, doc,
# signal, deadline, log, model, resolved context) plus the leg env this
# wrapper adds, and exits 0 without touching the signal/deadline wait loop,
# the claim lock, or konsole. The test seam - but not the ONLY proof: the
# suite also drives the real (non-dry) path with KONSOLE_CMD/PGREP_CMD stubs
# (the same seams headed-arm.sh's own suite uses) to confirm the launched
# argv matches what --dry-run predicted.
#
# Platform guard (gitbash-only): POSIX bash 3.2+, same as headed-arm.sh
# itself (konsole is Linux/KDE-only) - no .ps1 twin; the Windows station
# arms through arm-resume.sh's schtasks backend instead.
#
# Seams: HEADED_ARM_LEG_TARGET overrides the headed-arm.sh path this wrapper
# execs (default: ../headed-arm.sh next to this script) so a suite can point
# it at a fixture without touching PATH. HEADED_ARM_LEG_PREFLIGHT overrides
# the scripts/lib/bank-preflight.sh path the fleet-size cap below calls
# (default: ../../lib/bank-preflight.sh next to this script), same reason.
#
# Exit 10 (HIMMEL-2765): the fleet-size cap refused the launch - see the
# preflight call below. Exit 11 (HIMMEL-2782 codex-1): the $LANE bank is
# exhausted (SKIPPED-BANK) - same preflight call, distinct refusal reason.
# Both are distinct from headed-arm.sh's own 0-9 exit range, since this
# wrapper never reaches headed-arm.sh in either case.
#
# --lane (HIMMEL-2782): native (default) or claudex. --lane claudex (or
# LEG_LANE=claudex in the launching shell - the flag wins if both are
# given) routes the leg through scripts/claude-codex on the codex weekly
# bank instead of the Claude subscription bank: it routes headed-arm.sh's
# HEADED_ARM_LAUNCHER through the preface shim to the claudex binary (seam:
# HEADED_ARM_LEG_CLAUDEX_BIN, default ../../claude-codex), turns on the `script`
# tty recorder (HEADED_ARM_RECORDER=1 - load-bearing: konsole -e output is
# otherwise lost and a silent claudex death is undiagnosable), and exports
# CLAUDEX_LANE_OK=1 + CLAUDE_CODE_EFFORT_LEVEL=${LEG_EFFORT:-medium} into the
# launched process via HEADED_ARM_LAUNCHER_ENV. An empty/omitted MODEL
# defaults to gpt-6-astra for this lane (native's own default,
# claude-fable-5-1, is a Claude tier and would defeat the point of
# switching lanes). Context stays this wrapper's standard pin:
# --autocompact 200000 is the leg's ceiling; scripts/claude-codex's
# own CLAUDE_CODE_AUTO_COMPACT_WINDOW=272000 default never applies because
# `exec claude "$@"` forwards the CLI flag, which wins. An unknown lane
# name is a usage error (exit 2), not a silent fallback to native.
#
# --profile (HIMMEL-2830 / HIMMEL-2928 lever 1): applies a named plugin profile
# from scripts/lanes/plugin-profiles.json to the launched leg, plus the leg
# preface (docs/handover/leg-preface.md) and the lean-SessionStart switch. Also
# settable as LEG_PROFILE in the launching shell; the flag wins if both are
# given, same precedence as --lane. Omitted, NOTHING changes: no settings file
# is written, no env is exported, and the argv handed to headed-arm.sh is
# byte-identical to what it was before this flag existed (a suite case pins
# exactly that). Given, three things happen:
#   1. plugin-profiles.mjs resolves the name to an enabledPlugins map, written
#      as a settings JSON next to the launch log (the per-uid console work dir
#      the console already owns), and HEADED_ARM_LAUNCHER is pointed at
#      scripts/lanes/leg-claude-launcher.sh, which PREPENDS `--settings <that
#      file>` to headed-arm.sh's fixed argv. headed-arm.sh itself is untouched.
#   2. The same shim prepends `--append-system-prompt-file <leg-preface>`, so
#      the invariant leg rules ride the system prompt instead of being retyped
#      into every brief.
#   3. HIMMEL_LEAN_LEG=1 is exported, which silences the three advisory
#      SessionStart hooks (where-are-we, qmd staleness, graphify freshness) a
#      leg never acts on. inject-initiative.sh deliberately still speaks.
#   4. (HIMMEL-2935) When the profile declares an mcpServers allowlist,
#      plugin-profiles.mjs's definitions are written as a second JSON next to
#      the settings file, and the shim additionally prepends `--mcp-config
#      <that file> --strict-mcp-config` — stripping every MCP server NOT
#      named there, including the user-level ones (graphify, obsidian-vault,
#      context7 in ~/.claude.json) that were the bulk of the un-measured
#      first-turn floor and that a plugin profile alone cannot touch. A
#      profile with no mcpServers field changes nothing here (no file, no
#      flags); an unresolvable name refuses (exit 2) rather than launching
#      without it.
# WHY only leg-impl exists: the measured floor is schema-shaped, not
# roster-shaped (~40k of a 74.3k first-turn floor is tool + MCP schemas), so a
# second or third "profile by skill set" would resolve to the same manifest -
# see the _comment in plugin-profiles.json.
# --profile composes with --lane claudex (HIMMEL-2962): the shim prepends
# profile flags, then execs scripts/claude-codex via LEG_CLAUDE_BIN. The
# backend and its guarded argument screen remain in the launch path.
# Seams: HEADED_ARM_LEG_PROFILES overrides the plugin-profiles.mjs resolver
# path, HEADED_ARM_LEG_PREFACE the preface file, HEADED_ARM_LEG_SHIM the
# launcher shim - all script-relative by default, all so the suite can drive
# the real code against fixtures.
set -u

usage() {
    echo "usage: headed-arm-leg.sh [--dry-run] [--lane native|claudex] [--profile <name>] <session-name> <handover-doc> <signal-file> <deadline-epoch> <log> [model]" >&2
}

DRY_RUN=0
LANE="${LEG_LANE:-native}"
PROFILE="${LEG_PROFILE:-}"
while :; do
    case "${1:-}" in
        --dry-run) DRY_RUN=1; shift ;;
        --lane)
            # codex CR fix: `--lane` as the LAST arg leaves only 1 positional,
            # so `shift 2` fails (rc=1) and shifts NOTHING under `set -u`
            # (no `set -e` here to catch it) - the case above then matches
            # `--lane` again forever. Require a value before consuming it.
            if [ "$#" -lt 2 ]; then
                usage
                echo "headed-arm-leg: --lane requires a value (native or claudex)" >&2
                exit 2
            fi
            LANE="$2"; shift 2 ;;
        --profile)
            # Same missing-value trap as --lane above: without this guard a
            # trailing `--profile` re-matches forever under `set -u`.
            if [ "$#" -lt 2 ]; then
                usage
                echo "headed-arm-leg: --profile requires a value (a profile name from scripts/lanes/plugin-profiles.json; run \`node scripts/lanes/plugin-profiles.mjs --list\`)" >&2
                exit 2
            fi
            PROFILE="$2"; shift 2 ;;
        *) break ;;
    esac
done

case "$LANE" in
    native|claudex) ;;
    *)
        usage
        echo "headed-arm-leg: unknown lane: $LANE (expected native or claudex)" >&2
        exit 2
        ;;
esac

if [ "$#" -lt 5 ]; then
    usage
    exit 2
fi

NAME="$1"; DOC="$2"; SIGNAL="$3"; DEADLINE="$4"; LOG="$5"; MODEL="${6:-}"

HERE="$(cd "$(dirname "$0")" && pwd)"
HEADED_ARM="${HEADED_ARM_LEG_TARGET:-$HERE/../headed-arm.sh}"

# Context resolution (HIMMEL-2766/HIMMEL-2779): off-values stay standard;
# the one old 1m opt-in is resolved explicitly so the argv guard below can
# reject it with a useful message rather than silently ignoring operator input.
if [ "${LEG_CONTEXT:-}" = "1m" ]; then
    CONTEXT="1m"
    RESOLVED_AUTOCOMPACT="auto"
else
    CONTEXT="standard"
    RESOLVED_AUTOCOMPACT="200000"
fi

# HIMMEL-2779: a leg's ceiling is the resolved CLI pair, not the absence of a
# model suffix. Fail before dry-run reporting or preflight when context already
# resolves wrong; headed-arm.sh separately validates the exact argv it launches.
if [ "$RESOLVED_AUTOCOMPACT" != "200000" ]; then
    echo "headed-arm-leg: refusing leg launch: resolved argv lacks the required --autocompact 200000 ceiling (got --autocompact $RESOLVED_AUTOCOMPACT). unset LEG_CONTEXT and retry; use a console arm, not a leg, for 1m context." >&2
    exit 2
fi

# LEG_REPO folds onto headed-arm.sh's own HEADED_ARM_REPO override seam -
# the one thing the two prior kit-local copies differed on.
if [ -n "${LEG_REPO:-}" ]; then
    HEADED_ARM_REPO="$LEG_REPO"
    export HEADED_ARM_REPO
fi

# IMPL_GUARD_OK=1 / INLINE_IMPL_OK=1: leg-only env for
# guard-implementor-dispatch / orchestrator-inline-guard (HIMMEL-2879).
# headed-arm.sh's shared console/leg child-env block does not set these.
# Export into THIS process so both survive konsole's `-e env -u ...`, which
# only unsets the three HIMMEL-2545 vars and otherwise inherits as-is.
export IMPL_GUARD_OK=1
export INLINE_IMPL_OK=1
# HIMMEL_CONSOLE_LEG=1 (HIMMEL-2919): marks the launched process as a
# console-spawned leg, both lanes. merge-on-green.sh then merges only on the
# console's GO file (console-kit/go.sh), and go.sh refuses to run under it.
export HIMMEL_CONSOLE_LEG=1
# headed-arm.sh builds one argv array for both native and recorder launches and
# refuses exit 2 if this exact pair is absent. This is the final resolved-argv
# guard; the context-value check above gives the earlier operator-facing error.
export HEADED_ARM_REQUIRED_AUTOCOMPACT=200000

# claudex lane (HIMMEL-2782): see the --lane header comment above.
if [ "$LANE" = "claudex" ]; then
    CLAUDEX_BIN="${HEADED_ARM_LEG_CLAUDEX_BIN:-$HERE/../../claude-codex}"
    export HEADED_ARM_LAUNCHER="$CLAUDEX_BIN"
    export HEADED_ARM_LAUNCHER_ENV="CLAUDEX_LANE_OK=1 CLAUDE_CODE_EFFORT_LEVEL=${LEG_EFFORT:-medium}"
    export HEADED_ARM_RECORDER=1
    [ -z "$MODEL" ] && MODEL="gpt-6-astra"
fi

# --profile (HIMMEL-2830): resolve the plugin profile and point headed-arm.sh's
# launcher seam at the shim that will apply it. Resolution happens even under
# --dry-run (so a typo'd profile name fails the same way either way); only the
# settings FILE is withheld until we know we are really launching.
if [ -n "$PROFILE" ]; then
    PROFILES_MJS="${HEADED_ARM_LEG_PROFILES:-$HERE/../../lanes/plugin-profiles.mjs}"
    LEG_SHIM="${HEADED_ARM_LEG_SHIM:-$HERE/../../lanes/leg-claude-launcher.sh}"
    LEG_PREFACE="${HEADED_ARM_LEG_PREFACE:-$HERE/../../../docs/handover/leg-preface.md}"
    # Next to the launch log, i.e. inside the per-uid console work dir the
    # console already owns and cleans - never /tmp world-readable, never the
    # repo (it is generated, per-leg state).
    PROFILE_SETTINGS="$(dirname "$LOG")/$NAME.leg-settings.json"
    for _leg_need in "$PROFILES_MJS" "$LEG_SHIM" "$LEG_PREFACE"; do
        if [ ! -f "$_leg_need" ]; then
            echo "headed-arm-leg: --profile $PROFILE: required file missing: $_leg_need" >&2
            exit 2
        fi
    done
    # cwd matters: the resolver reads the machine's LIVE enabled-plugin set
    # from every settings layer under it, and disables anything outside the
    # catalog (deny-by-default beyond CATALOG). Resolve from the leg's repo.
    _leg_resolve_cwd="${HEADED_ARM_REPO:-$HERE/../../..}"
    [ -d "$_leg_resolve_cwd" ] || _leg_resolve_cwd="$HERE"
    if ! PROFILE_JSON="$(cd "$_leg_resolve_cwd" && node "$PROFILES_MJS" "$PROFILE" 2>&1)"; then
        echo "headed-arm-leg: --profile $PROFILE: resolver failed: $PROFILE_JSON" >&2
        exit 2
    fi
    if [ -z "$PROFILE_JSON" ]; then
        echo "headed-arm-leg: --profile $PROFILE: resolver produced no settings JSON" >&2
        exit 2
    fi
    # The shim reads these; export so they survive konsole's `-e env -u ...`.
    export LEG_PROFILE_SETTINGS="$PROFILE_SETTINGS"
    export LEG_PROFILE_PREFACE="$LEG_PREFACE"
    export HEADED_ARM_LAUNCHER="$LEG_SHIM"
    # Lean SessionStart (HIMMEL-2830): the three advisory hooks go quiet. Only
    # the exact value 1 leans - the hooks are fail-open by construction.
    export HIMMEL_LEAN_LEG=1
    # mcpServers allowlist (HIMMEL-2935): resolved (and, on an unknown name,
    # REFUSED) here so a typo'd server name fails the same way under --dry-run
    # and for real, same reasoning as the settings JSON above. "null" (the
    # field is absent) is a deliberate no-op: no file, no LEG_PROFILE_MCP_CONFIG,
    # the shim adds nothing.
    if ! MCP_NAMES_JSON="$(cd "$_leg_resolve_cwd" && node "$PROFILES_MJS" "$PROFILE" --mcp-servers 2>&1)"; then
        echo "headed-arm-leg: --profile $PROFILE: mcp-servers resolution failed: $MCP_NAMES_JSON" >&2
        exit 2
    fi
    if [ "$MCP_NAMES_JSON" != "null" ]; then
        if ! MCP_CONFIG_JSON="$(cd "$_leg_resolve_cwd" && node "$PROFILES_MJS" "$PROFILE" --mcp-config 2>&1)"; then
            echo "headed-arm-leg: --profile $PROFILE: mcp-config resolution failed: $MCP_CONFIG_JSON" >&2
            exit 2
        fi
        PROFILE_MCP_CONFIG="$(dirname "$LOG")/$NAME.leg-mcp.json"
        export LEG_PROFILE_MCP_CONFIG="$PROFILE_MCP_CONFIG"
    fi
fi

# HIMMEL-2953: every claudex leg gets its document-channel coordination
# rules, even without a profile. Claude accepts one preface file, so a
# profiled leg gets its own concatenation, with the lane override last.
if [ "$LANE" = "claudex" ]; then
    CLAUDEX_PREFACE="$HERE/../../../docs/handover/leg-preface-claudex.md"
    export HEADED_ARM_LAUNCHER="${HEADED_ARM_LEG_SHIM:-$HERE/../../lanes/leg-claude-launcher.sh}"
    export LEG_CLAUDE_BIN="$CLAUDEX_BIN"
    for _leg_need in "$CLAUDEX_PREFACE" "$HEADED_ARM_LAUNCHER"; do
        if [ ! -f "$_leg_need" ]; then
            echo "headed-arm-leg: --lane claudex: required file missing: $_leg_need" >&2
            exit 2
        fi
    done
    if [ -n "$PROFILE" ]; then
        LEG_PROFILE_PREFACE="$(dirname "$LOG")/$NAME.leg-preface.md"
        export LEG_PROFILE_PREFACE
    else
        export LEG_PROFILE_PREFACE="$CLAUDEX_PREFACE"
    fi
fi

if [ "$DRY_RUN" -eq 1 ]; then
    printf 'headed-arm-leg: would exec: %s %s %s %s %s %s %s %s\n' \
        "$HEADED_ARM" "$NAME" "$DOC" "$SIGNAL" "$DEADLINE" "$LOG" "$MODEL" "$CONTEXT"
    printf 'headed-arm-leg: env IMPL_GUARD_OK=%s INLINE_IMPL_OK=%s HIMMEL_CONSOLE_LEG=%s HEADED_ARM_REPO=%s\n' \
        "$IMPL_GUARD_OK" "$INLINE_IMPL_OK" "$HIMMEL_CONSOLE_LEG" "${HEADED_ARM_REPO:-<derived by headed-arm.sh>}"
    printf 'headed-arm-leg: lane=%s launcher=%s launcher-env=%s' \
        "$LANE" "${HEADED_ARM_LAUNCHER:-claude (native default)}" "${HEADED_ARM_LAUNCHER_ENV:-<none>}"
    if [ "$LANE" = "claudex" ]; then
        printf ' exec-target=%s preface=%s' "$LEG_CLAUDE_BIN" "$LEG_PROFILE_PREFACE"
    fi
    printf '\n'
    # Printed ONLY under --profile: with the flag omitted this whole line is
    # absent and the dry-run report is byte-identical to the pre-HIMMEL-2830
    # one, matching the argv guarantee it describes.
    if [ -n "$PROFILE" ]; then
        printf 'headed-arm-leg: profile=%s settings=%s preface=%s lean=%s mcp=%s mcp-config=%s\n' \
            "$PROFILE" "$PROFILE_SETTINGS" "$LEG_PROFILE_PREFACE" "$HIMMEL_LEAN_LEG" \
            "$MCP_NAMES_JSON" "${LEG_PROFILE_MCP_CONFIG:-<none>}"
    fi
    exit 0
fi

# Real launch: now write the resolved settings the shim will pass to claude.
if [ -n "$PROFILE" ]; then
    if ! printf '%s\n' "$PROFILE_JSON" > "$PROFILE_SETTINGS"; then
        echo "headed-arm-leg: --profile $PROFILE: cannot write settings to $PROFILE_SETTINGS" >&2
        exit 2
    fi
    chmod 600 "$PROFILE_SETTINGS" 2>/dev/null || true
    if [ "$LANE" = "claudex" ]; then
        if ! cat "$LEG_PREFACE" "$CLAUDEX_PREFACE" > "$LEG_PROFILE_PREFACE"; then
            echo "headed-arm-leg: --lane claudex: cannot write preface to $LEG_PROFILE_PREFACE" >&2
            exit 2
        fi
        chmod 600 "$LEG_PROFILE_PREFACE" 2>/dev/null || true
    fi
    if [ -n "${LEG_PROFILE_MCP_CONFIG:-}" ]; then
        if ! printf '%s\n' "$MCP_CONFIG_JSON" > "$LEG_PROFILE_MCP_CONFIG"; then
            echo "headed-arm-leg: --profile $PROFILE: cannot write mcp config to $LEG_PROFILE_MCP_CONFIG" >&2
            exit 2
        fi
        chmod 600 "$LEG_PROFILE_MCP_CONFIG" 2>/dev/null || true
    fi
fi

# HIMMEL-2765: fleet-size cap. Checked at ARM time, before headed-arm.sh's own
# signal/deadline wait loop even starts - refusing now is cheaper than
# refusing after waiting out the deadline. SKIPPED-FLEET refuses the launch
# outright. SKIPPED-BANK (HIMMEL-2782 codex-1 CR fix) also refuses: we set
# CADENCE_BANK_LANE="$LANE" above specifically so bank-preflight.sh checks
# the bank this lane actually draws on (the codex weekly bank for claudex,
# the CLAUDE five_hour/seven_day bank for native) - unlike arm-resume.sh,
# this wrapper has no separate bank-aware scheduling path to fall back on,
# so ignoring SKIPPED-BANK would let a launch through against an exhausted
# bank. Any other verdict (PROCEED, BANK-STALE, BANK-UNKNOWN) falls through.
BANK_PREFLIGHT="${HEADED_ARM_LEG_PREFLIGHT:-$HERE/../../lib/bank-preflight.sh}"
if [ -f "$BANK_PREFLIGHT" ]; then
    # HIMMEL-2789: this call launches a leg, so it declares launch intent —
    # the fleet cap must be able to actually refuse it, unlike a plain
    # bank-status READ.
    preflight_token="$(CADENCE_BANK_LEG="$NAME" CADENCE_BANK_LANE="$LANE" CADENCE_BANK_LAUNCH=1 bash "$BANK_PREFLIGHT" 2>>"$LOG")"
    if [ "$preflight_token" = SKIPPED-FLEET ]; then
        echo "$(date +%F_%T) headed-arm-leg: refusing to launch $NAME - fleet-size cap reached (bypass: FLEET_CAP_OK=1 in the LAUNCHING shell)" >> "$LOG"
        exit 10
    fi
    if [ "$preflight_token" = SKIPPED-BANK ]; then
        echo "$(date +%F_%T) headed-arm-leg: refusing to launch $NAME - $LANE lane bank exhausted (park and retry later; see bank-preflight.sh for the parked lane's own bank status)" >> "$LOG"
        exit 11
    fi
fi

exec "$HEADED_ARM" "$NAME" "$DOC" "$SIGNAL" "$DEADLINE" "$LOG" "$MODEL" "$CONTEXT"
