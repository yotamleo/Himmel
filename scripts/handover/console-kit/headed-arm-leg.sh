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
# --ignore-denials (HIMMEL-3724): launch a leg even though it has an un-acked
# SHIP-STEP / PAUSE-RISK classifier-denial page on record. WITHOUT it the launch
# is refused, exit 14, with a message naming `ack-denial.sh <leg>` (the normal
# fix: review why the leg was parked, then ack it). The check keys on the
# session name and on the worktree slug in the handover doc's resume_cwd, reads
# only the page/ack records under ${HIMMEL_DENIAL_ACK_DIR:-~/.himmel/state/
# denial-acks} (never the denial log), and fails open: no record, an acked one,
# a REPEAT, or an unreadable record launches. Exit 14 joins 2 usage, 10 fleet
# cap, 11 bank exhausted, 12 macOS whitespace.
#
# --headless (HIMMEL-3403; or LEG_HEADLESS=1 in the launching shell, the flag
# wins): the same launch with no konsole - the leg runs as a Claude Code
# background session (headed-arm.sh adds --bg), and its env goes into the
# per-leg settings file because the session inherits the claude daemon's env,
# not ours. Needs a profile; native lane only. End a headless leg: `kill <pid>`
# (the pid= in the log's `headless=1` line, or `claude agents --json`), then
# `claude rm <short-id>`. Where -p vs --bg fits which job: HIMMEL-3410.
# A headless leg cannot pass seams to chokepoints (HIMMEL-3914): the seam
# guard ignores the per-leg settings file and refuses (exit 96) whenever a
# seam differs from the claude daemon's env, so merge-on-green.sh and go.sh
# refuse there. Use a headed leg for anything that ships; design: HIMMEL-3930.
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
# HEADED_ARM_UNAME overrides the platform leg_propagate_env's whitespace
# refusal branches on (default: real `uname -s`) - the same seam name and
# idiom headed-arm.sh itself defines and its own suite already overrides
# with HEADED_ARM_UNAME=Linux/Darwin; resolved again HERE because this
# wrapper is a separate process that must settle that decision before it
# ever execs into headed-arm.sh.
#
# Exit 10 (HIMMEL-2765): the fleet-size cap refused the launch - see the
# preflight call below. Exit 11 (HIMMEL-2782 codex-1): the $LANE bank is
# exhausted (SKIPPED-BANK) - same preflight call, distinct refusal reason.
# Exit 12 (HIMMEL-2534): on macOS, leg_propagate_env refused a leg-process
# env value that contains whitespace - it cannot round-trip through
# HEADED_ARM_LAUNCHER_ENV's whitespace-split token list, and macOS has no
# other channel for it (a plain export never reaches an `open -a` leg there).
# On any other platform, plain-export inheritance already carries such a
# value, so leg_propagate_env leaves it there instead of refusing - see its
# own doc comment below. All three exit codes are distinct from
# headed-arm.sh's own exit codes (0-9 and 13), since this wrapper never
# reaches headed-arm.sh in any of these cases.
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
# defaults to gpt-6.1-sol for this lane (native's own --judge default,
# claude-opus-5-5, is a Claude tier and would defeat the point of
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
# given, same precedence as --lane. A launch that supplies NO profile (no
# --profile, no LEG_PROFILE, and neither --relay nor --judge, which force one)
# is REFUSED with exit 2 unless --no-profile is passed (HIMMEL-3267): an
# unprofiled leg silently runs without the standing preface and without the
# lean plugin set, its launch log indistinguishable from a profiled one, and
# it cannot know what it was not given. --no-profile is the explicit opt-out
# for a brief that carries the preface pasted in itself; it conflicts (exit 2)
# with any resolved profile (--profile, LEG_PROFILE, --relay, --judge) rather
# than silently dropping one, and the real launch records it in the launch
# log. Under --no-profile NOTHING else changes: no settings file is written,
# no env is exported, and the argv handed to headed-arm.sh is byte-identical
# to what it was before --profile existed (a suite case pins exactly that).
# Given a profile, three things happen:
#   1. plugin-profiles.mjs resolves the name to an enabledPlugins map, written
#      as a settings JSON next to the launch log (the per-uid console work dir
#      the console already owns), and HEADED_ARM_LAUNCHER is pointed at
#      scripts/lanes/leg-claude-launcher.sh, which PREPENDS `--settings <that
#      file>` to headed-arm.sh's fixed argv. headed-arm.sh itself is untouched.
#   2. The same shim prepends `--append-system-prompt-file <leg-preface>`, so
#      the invariant leg rules ride the system prompt instead of being retyped
#      into every brief. On the claudex lane this leg-preface is a per-leg
#      concatenation of docs/handover/leg-preface.md and the claudex
#      coordination preface, written next to the launch log at real-launch
#      time. (HIMMEL-2990, superseding 2985's Ask 1) On the native lane the
#      brief's own contract (the brief up to but excluding its `## Results`
#      tail, or the whole file if it has none) does NOT ride this preface -
#      measured, riding it re-pays the contract on EVERY API call
#      (contract x calls), 25-30x costlier over a typical leg than
#      re-injecting it only after a compaction (contract x (compactions+1)).
#      Instead it is written to its own per-leg <name>.leg-contract.md, and a
#      SessionStart hook with `"matcher": "compact"` is added to the
#      generated <name>.leg-settings.json to `cat` it back in whenever a
#      compaction fires - the `load <brief> and continue` first turn is the
#      only thing still compactable, and this hook re-supplies the contract
#      the moment it would otherwise be lost.
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
#
# --relay (HIMMEL-2975): launches the Sonnet relay half of a split console.
# Forces --profile console-relay (a real --profile conflicts, exit 2); an
# empty MODEL defaults to claude-sonnet-5-5 and LEG_EFFORT defaults low, both
# only under this flag. Exports HIMMEL_CONSOLE_RELAY=1, the marker
# inbox-send.sh's Guard C already refuses --token under and the Task 26
# write-deny hook will key writes off - a distinct signal from the profile.
#
# --judge (HIMMEL-3133 / design §3.2 "the judge is a leg"): launches a judge
# session through this SAME launcher rather than a separate mechanism. Forces
# --profile console-judge (a real --profile conflicts, exit 2, same shape as
# --relay above); an empty MODEL defaults to claude-opus-5-5 at high effort
# (HIMMEL-3630), but only on the native lane. No new HIMMEL_CONSOLE_JUDGE
# marker: HIMMEL_CONSOLE_LEG=1 is
# already exported for every leg, so Guard E (go.sh refuses under it,
# merge-on-green.sh demands a console GO) already covers a judge - it is a
# leg, not a new role the guards need to learn. What DOES differ from a
# plain leg: no IMPL_GUARD_OK/INLINE_IMPL_OK (a judge does not implement),
# a raised HIMMEL_READ_CLAMP_LINES (independent reading is the job), and the
# judge preface instead of the leg preface.
#
# LEG_SUPPRESS_CR_TRIGGER (HIMMEL-3141): set in the launching shell to
# suppress the CodeRabbit auto-trigger for this one leg - see the
# LEG_REPO-style fold below for the mechanism. CodeRabbit is best effort
# (HIMMEL-3360): the knob exists so a console can skip the review on a PR
# that will never get one (machine-generated class), never to ration or
# sequence it. Opt-out, default ON: unset changes nothing.
set -u
# HIMMEL-3914: refuse a chokepoint seam that differs from the session's launch env.
# Parameter expansion, not dirname: a PATH-shadowed dirname must not pick
# what is sourced before the seam guard (HIMMEL-3914).
case "${BASH_SOURCE[0]}" in */*) _csg_dir="${BASH_SOURCE[0]%/*}" ;; *) _csg_dir=. ;; esac
_csg_lib="$_csg_dir/../../lib/chokepoint-seam-guard.sh"
# shellcheck source=scripts/lib/chokepoint-seam-guard.sh
# shellcheck disable=SC1091
if ! { [ -r "$_csg_lib" ] && . "$_csg_lib"; }; then
    echo "headed-arm-leg.sh: cannot load $_csg_lib - refusing (HIMMEL-3914)" >&2
    exit 96
fi
chokepoint_seam_guard scripts/handover/console-kit/headed-arm-leg.sh || exit 96

# HEADED_ARM_UNAME (HIMMEL-2534 follow-up) - same seam name and default-
# expansion idiom headed-arm.sh itself defines; resolved again HERE because
# this wrapper is a separate process that must settle leg_propagate_env's
# platform branch before it ever execs into headed-arm.sh. Test seam:
# HEADED_ARM_UNAME=Darwin|Linux|... overrides it without a real uname call,
# same as headed-arm.sh's own suite already does.
HEADED_ARM_UNAME="${HEADED_ARM_UNAME:-$(uname -s 2>/dev/null)}"
export HEADED_ARM_UNAME

usage() {
    echo "usage: headed-arm-leg.sh [--dry-run] [--headless] [--ignore-denials] [--lane native|claudex] (--profile <name[,name...]> | --no-profile) [--relay] [--judge] [--consult] [--console <name>] <session-name> <handover-doc> <signal-file> <deadline-epoch> <log> [model]" >&2
}

# leg_propagate_env NAME VALUE - HIMMEL-2534: on macOS, `open -a` starts a leg
# from a FRESH environment (konsole-macos.sh's own header - PATH excepted, by
# a deliberate policy this fix leaves untouched), so a plain `export` here
# never reaches the leg process on that platform. Only an explicit token on
# headed-arm.sh's own `env ... NAME=VALUE ...` command line does: it is baked
# into the launched .command file's argv (`%q`-quoted), not inherited, so it
# survives the boundary a plain export does not. Every leg-process var this
# wrapper sets (IMPL_GUARD_OK, LEG_PROFILE_*, HIMMEL_CONSOLE_LEG, ...) must go
# through this function instead of a bare `export`. Vars headed-arm.sh itself
# consumes in THIS SAME process tree (HEADED_ARM_REPO, HEADED_ARM_LAUNCHER,
# HEADED_ARM_RECORDER, HEADED_ARM_REQUIRED_AUTOCOMPACT, ...) never cross that
# boundary and must NOT be routed through it - they stay plain exports.
#
# A caller-preset HEADED_ARM_LAUNCHER_ENV is preserved (appended to, never
# replaced) and wins on a name clash: this function only ever adds a NAME not
# already present as a token. HEADED_ARM_LAUNCHER_ENV is a whitespace-split
# token list (same contract as CODEX_BANK_PROBE_CMD) with no quoting scheme,
# so a value containing whitespace cannot become a token: it would silently
# mis-split into extra bogus tokens. On macOS (HEADED_ARM_UNAME=Darwin), the
# token list is the ONLY channel to the leg, so such a value is refused
# loudly (exit 12) rather than silently corrupted. On every other platform, a
# plain `export` already reaches the leg via ordinary environment
# inheritance (this was true before HIMMEL-2534 and must stay true), so the
# value is left there untouched, a stderr warning explains why no token was
# added, and this function returns without exit.
leg_propagate_env() {
    _leg_prop_name="$1"
    _leg_prop_value="$2"
    case "$_leg_prop_value" in
        *[[:space:]]*)
            if [ "$HEADED_ARM_UNAME" = "Darwin" ]; then
                echo "headed-arm-leg: refusing to propagate $_leg_prop_name: value contains whitespace, which HEADED_ARM_LAUNCHER_ENV's token list cannot carry ($_leg_prop_name=$_leg_prop_value)" >&2
                exit 12
            fi
            echo "headed-arm-leg: $_leg_prop_name value contains whitespace - leaving it to plain-export inheritance instead of HEADED_ARM_LAUNCHER_ENV (whose token list cannot carry it); harmless on $HEADED_ARM_UNAME, which inherits this process's environment directly" >&2
            export "$_leg_prop_name=$_leg_prop_value"
            unset -v _leg_prop_name _leg_prop_value
            return
            ;;
    esac
    export "$_leg_prop_name=$_leg_prop_value"
    set -f
    for _leg_prop_tok in ${HEADED_ARM_LAUNCHER_ENV:-}; do
        case "$_leg_prop_tok" in
            "$_leg_prop_name="*)
                set +f
                unset -v _leg_prop_name _leg_prop_value _leg_prop_tok
                return
                ;;
        esac
    done
    set +f
    HEADED_ARM_LAUNCHER_ENV="${HEADED_ARM_LAUNCHER_ENV:+$HEADED_ARM_LAUNCHER_ENV }$_leg_prop_name=$_leg_prop_value"
    export HEADED_ARM_LAUNCHER_ENV
    unset -v _leg_prop_name _leg_prop_value _leg_prop_tok
}

# leg_env_drop_token NAME - HIMMEL-3456: remove every NAME=... token from a
# caller-preset HEADED_ARM_LAUNCHER_ENV, keeping the rest in order. For a var
# this wrapper must own outright (a scrubbed knob, a validated value), where
# leg_propagate_env's caller-wins de-dupe would otherwise let the preset token
# reach the leg. set -f so no caller token is glob-expanded.
leg_env_drop_token() {
    _leg_drop_kept=""
    set -f
    for _leg_drop_tok in ${HEADED_ARM_LAUNCHER_ENV:-}; do
        case "$_leg_drop_tok" in
            "$1="*) ;;
            *) _leg_drop_kept="${_leg_drop_kept:+$_leg_drop_kept }$_leg_drop_tok" ;;
        esac
    done
    set +f
    [ -n "${HEADED_ARM_LAUNCHER_ENV:-}" ] && HEADED_ARM_LAUNCHER_ENV="$_leg_drop_kept"
    unset -v _leg_drop_kept _leg_drop_tok
}

DRY_RUN=0
RELAY=0
JUDGE=0
CONSULT=0
READONLY_ROLE=0   # judge or consult: no implementation permissions, raised read clamp
NO_PROFILE=0
IGNORE_DENIALS=0
HEADLESS=0
[ "${LEG_HEADLESS:-}" = "1" ] && HEADLESS=1
LANE="${LEG_LANE:-native}"
PROFILE="${LEG_PROFILE:-}"
CONSOLE_FLAG=""
while :; do
    case "${1:-}" in
        --dry-run) DRY_RUN=1; shift ;;
        --relay) RELAY=1; shift ;;
        --judge) JUDGE=1; shift ;;
        --consult) CONSULT=1; shift ;;
        --ignore-denials) IGNORE_DENIALS=1; shift ;;
        --no-profile) NO_PROFILE=1; shift ;;
        --headless) HEADLESS=1; shift ;;
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
        --console)
            # Same missing-value trap as --lane/--profile above.
            if [ "$#" -lt 2 ]; then
                usage
                echo "headed-arm-leg: --console requires a value (the owning console's session name)" >&2
                exit 2
            fi
            CONSOLE_FLAG="$2"; shift 2 ;;
        *) break ;;
    esac
done

# --relay (HIMMEL-2975): forces the console-relay plugin profile - a relay is
# plugin-less by design, so any other --profile (flag or LEG_PROFILE) is a
# real conflict, not a preference to silently override.
if [ "$RELAY" -eq 1 ]; then
    if [ -n "$PROFILE" ] && [ "$PROFILE" != "console-relay" ]; then
        usage
        echo "headed-arm-leg: --relay forces --profile console-relay (got: $PROFILE)" >&2
        exit 2
    fi
    PROFILE="console-relay"
fi

# --judge (HIMMEL-3133): forces console-judge the same way --relay forces
# console-relay above - a real conflicting --profile refuses rather than
# silently overriding. --judge and --relay therefore also refuse each other
# here (each forces a different profile), which is the correct outcome: a
# session is not both roles at once.
if [ "$JUDGE" -eq 1 ]; then
    if [ -n "$PROFILE" ] && [ "$PROFILE" != "console-judge" ]; then
        usage
        echo "headed-arm-leg: --judge forces --profile console-judge (got: $PROFILE)" >&2
        exit 2
    fi
    PROFILE="console-judge"
fi

# --consult (HIMMEL-4014): a short read-only session that borrows the plugin set
# of the REQUESTED profile list (--profile design,design-motion). Unlike --judge
# it forces nothing, so the profile must be explicit (flag or LEG_PROFILE, never
# the brief's `profile:` line), and it refuses every non-additive profile even as
# a single name: operator/bare inject nothing, and the console/relay/judge role
# profiles carry guard semantics a consult must not inherit. It also refuses a
# leg-worktree cwd (an explicit LEG_REPO/HEADED_ARM_REPO under .claude/worktrees/):
# a consult reads, it never runs inside a leg's checkout.
if [ "$CONSULT" -eq 1 ]; then
    if [ "$JUDGE" -eq 1 ] || [ "$RELAY" -eq 1 ] || [ "$NO_PROFILE" -eq 1 ]; then
        usage
        echo "headed-arm-leg: --consult refuses --judge, --relay and --no-profile (a consult is its own role and needs the requested profile)" >&2
        exit 2
    fi
    if [ -z "$PROFILE" ]; then
        usage
        echo "headed-arm-leg: --consult refuses an empty profile: pass --profile <name[,name...]> (the plugin set to consult with)" >&2
        exit 2
    fi
    _consult_rest="$PROFILE,"
    while [ -n "$_consult_rest" ]; do
        _consult_m="${_consult_rest%%,*}"; _consult_rest="${_consult_rest#*,}"
        case "$_consult_m" in
            operator|bare|console|console-relay|console-judge)
                usage
                echo "headed-arm-leg: --consult refuses profile \"$_consult_m\": non-additive or role profiles cannot back a consult (got: $PROFILE)" >&2
                exit 2
                ;;
        esac
    done
    if [ "$LANE" != "native" ]; then
        usage
        echo "headed-arm-leg: --consult refuses --lane $LANE: the read-only envelope is native-lane only (claudex settings-deny parity is unverified, so it fails closed)" >&2
        exit 2
    fi
    # The EFFECTIVE repo, derived the way headed-arm.sh derives it (LEG_REPO folds
    # onto HEADED_ARM_REPO; neither set = the checkout this script lives in), then
    # canonicalised so a relative or symlinked path cannot dodge the glob. An
    # unresolvable repo fails closed.
    _consult_raw="${LEG_REPO:-${HEADED_ARM_REPO:-$(dirname "$0")/../../..}}"
    if ! _consult_repo="$(cd -P "$_consult_raw" 2>/dev/null && pwd -P)"; then
        usage
        echo "headed-arm-leg: --consult cannot resolve its repo ($_consult_raw): refusing" >&2
        exit 2
    fi
    case "$_consult_repo/" in
        */.claude/worktrees/*)
            usage
            echo "headed-arm-leg: --consult refuses a leg worktree cwd (effective repo $_consult_repo is under .claude/worktrees/): launch it from the console's own checkout" >&2
            exit 2
            ;;
    esac
    # (HIMMEL-4061) The envelope below sandboxes the consult's Bash (bubblewrap +
    # socat on Linux; macOS uses the built-in Seatbelt). Claude Code's own
    # failIfUnavailable already fails closed, but only as a dead window: refuse at
    # arm time instead. CONSULT_*_BIN are test seams.
    if [ "$(uname -s)" = "Linux" ]; then
        if ! command -v "${CONSULT_BWRAP_BIN:-bwrap}" >/dev/null 2>&1 || ! command -v "${CONSULT_SOCAT_BIN:-socat}" >/dev/null 2>&1; then
            usage
            echo "headed-arm-leg: --consult needs bwrap (bubblewrap) AND socat on PATH for its Bash sandbox: install both, then relaunch" >&2
            exit 2
        fi
    fi
    CONSULT_REPO_CANON="$_consult_repo"
    unset -v _consult_raw _consult_repo
fi

[ "$JUDGE" -eq 1 ] || [ "$CONSULT" -eq 1 ] && READONLY_ROLE=1

# --no-profile (HIMMEL-3267) is the deliberate opt-out; a profile from ANY
# source (flag, LEG_PROFILE, or the one --relay/--judge just forced) is a real
# conflict, not one to resolve by silently dropping either side.
if [ "$NO_PROFILE" -eq 1 ] && [ -n "$PROFILE" ]; then
    usage
    echo "headed-arm-leg: --no-profile conflicts with the profile requested via --profile, LEG_PROFILE, --relay or --judge (got: $PROFILE)" >&2
    exit 2
fi

case "$LANE" in
    native|claudex) ;;
    *)
        usage
        echo "headed-arm-leg: unknown lane: $LANE (expected native or claudex)" >&2
        exit 2
        ;;
esac

# --console (HIMMEL-3435): charset-checked here because it is an explicit,
# user-typed flag - same refuse-on-bad-input stance as --lane/--profile
# above. It lands in a filesystem path downstream (merge-block-alert.sh's
# console inbox lookup), so only letters, digits, '.', '_' and '-' pass, and
# "." / ".." are refused outright (HIMMEL-3456): they pass that charset but
# are path components, routing the lookup outside the console directory.
if [ -n "$CONSOLE_FLAG" ]; then
    case "$CONSOLE_FLAG" in
        .|..)
            usage
            echo "headed-arm-leg: --console: name must not be '.' or '..' (got: $CONSOLE_FLAG)" >&2
            exit 2
            ;;
        *[!A-Za-z0-9._-]*)
            usage
            echo "headed-arm-leg: --console: name must contain only letters, digits, '.', '_' or '-' (got: $CONSOLE_FLAG)" >&2
            exit 2
            ;;
    esac
fi

# --headless (HIMMEL-3403): the background session takes its env from the
# claude daemon, so the leg's own env is written into the profile's settings
# file. With no profile there is no such file, and the leg would silently run
# on whatever env the daemon was spawned with. The claudex lane wraps claude
# in script(1) for a tty, which has no background form.
if [ "$HEADLESS" -eq 1 ]; then
    if [ "$NO_PROFILE" -eq 1 ]; then
        usage
        echo "headed-arm-leg: --headless needs a profile (the leg's env rides in the profile's settings file); drop --no-profile" >&2
        exit 2
    fi
    if [ "$LANE" != "native" ]; then
        usage
        echo "headed-arm-leg: --headless supports the native lane only (got: $LANE)" >&2
        exit 2
    fi
    export HEADED_ARM_HEADLESS=1
else
    unset HEADED_ARM_HEADLESS
fi

if [ "$#" -lt 5 ]; then
    usage
    exit 2
fi

NAME="$1"; DOC="$2"; SIGNAL="$3"; DEADLINE="$4"; LOG="$5"; MODEL="${6:-}"

# HIMMEL-4013 role-to-profile rule: a `profile: <name>` line in the brief's first
# 60 lines selects the leg's profile when neither --profile nor LEG_PROFILE did
# (an explicit flag/env is the override and always wins; --no-profile opts out
# and is left alone). Only the explicit field is honoured here - inferring a
# profile from the doc would silently end the unprofiled-launch refusal below.
if [ -z "$PROFILE" ] && [ "$NO_PROFILE" -eq 0 ] && [ -f "$DOC" ]; then
    # shellcheck disable=SC2016  # backticks in the sed regex are literal
    PROFILE="$(head -n 60 "$DOC" | sed -n -E 's/^[>* -]*profile:[[:space:]]*`?([A-Za-z0-9._,-]+)`?[[:space:]]*$/\1/p' | head -n 1)"
fi

# HIMMEL-3267: same stance as the Tier-line refusal below - this wrapper
# refuses an under-specified dispatch rather than launching it. No profile and
# no explicit --no-profile would launch a leg with no standing preface and no
# lean plugin set, silently (see the --profile header comment). Runs before the
# --dry-run exit so a dry-run exercises the very decision it is predicting.
if [ -z "$PROFILE" ] && [ "$NO_PROFILE" -eq 0 ]; then
    usage
    echo "headed-arm-leg: refusing an unprofiled launch: pass --profile <name> (or set LEG_PROFILE; names: \`node scripts/lanes/plugin-profiles.mjs --list\`) so the leg gets docs/handover/leg-preface.md and the lean plugin set. Pass --no-profile only when the brief itself carries the preface pasted in." >&2
    exit 2
fi

# --relay defaults MODEL to the Sonnet relay's own default (an explicit model
# still wins, same precedence as --lane/--profile above); LEG_EFFORT defaults
# low for the same reason a relay runs plugin-less - it is not the implementor.
# Gated on RELAY: a non-relay leg's model default is headed-arm.sh's own, and
# must stay untouched (--dry-run's no-relay report is pinned byte-identical).
if [ "$RELAY" -eq 1 ]; then
    [ -z "$MODEL" ] && MODEL=claude-sonnet-5-5
    : "${LEG_EFFORT:=low}"
    export LEG_EFFORT
fi

# --judge defaults MODEL to the Opus tier at high effort, but ONLY on the
# native lane - the tier gate below matches a claude-* prefix, so a claudex
# judge would carry no cost gate at all under a borrowed default. --judge
# --lane claudex is left to fall through to the claudex lane's own gpt-6.1-sol
# default further down, unchanged: a known gap (design §3.2 P1), not this
# ticket's to close. HIMMEL-3630: Fable is retired as the judge DEFAULT (Opus
# 5.5 high measured ~2.7x cheaper per verdict than Fable 5.1 with comparable
# wall time and zero missed findings in the HIMMEL-3595 dataset); the effort
# default is set here, before the native-lane effort resolver below, so that
# resolver's own "an explicit CLAUDE_CODE_EFFORT_LEVEL wins" check treats it
# exactly like a caller-set value and never falls through to lanes.json's
# opus row (medium) instead. An explicit model still wins over the MODEL
# default; Fable stays available as an explicit, tier-gated choice.
#
# HIMMEL-3795: CLAUDE_CODE_EFFORT_LEVEL/LEG_EFFORT are deliberately kept as
# ambient leg-process input further down (the scrub loop's exclusion list),
# because a normal native leg's own effort resolver (below) needs a caller's
# explicit value to win. But a judge is armed by a LEG, not only by a
# console, and that leg's own shell can carry an inherited
# CLAUDE_CODE_EFFORT_LEVEL=low from ITS OWN launch - textually
# indistinguishable from a deliberate override, so the exclusion above let it
# silently beat this judge's high default. A console's actual deliberate
# override therefore gets its own name, HIMMEL_CONSOLE_JUDGE_EFFORT, which
# nothing else in this wrapper ever sets or reads - only a caller that means
# to override a judge's effort would set it. Overwriting
# CLAUDE_CODE_EFFORT_LEVEL here unconditionally (not just when unset) makes
# this the last word for a native judge against ambient/inherited input -
# this assignment, not the leg_propagate_env de-dupe below, is what a judge
# brief means by "the effort channel". HIMMEL-3797: it is NOT the only
# override channel left: a caller-preset HEADED_ARM_LAUNCHER_ENV token for
# CLAUDE_CODE_EFFORT_LEVEL still wins downstream, because
# leg_env_propagate's "caller-preset token wins" de-dupe (:242-249) leaves
# an existing token alone rather than replacing it with this value. That is
# a second, deliberate-only channel (a leg's own shell never reaches it -
# headed-arm.sh unsets HEADED_ARM_LAUNCHER_ENV before a leg's own children
# launch), unaffected by this ticket and not a bug to fix here.
if [ "$CONSULT" -eq 1 ] && [ "$LANE" = "native" ]; then
    # HIMMEL-4014: a consult is a short question, not a verdict - Sonnet at medium.
    [ -z "$MODEL" ] && MODEL=claude-sonnet-5-5
    CLAUDE_CODE_EFFORT_LEVEL="${HIMMEL_CONSOLE_JUDGE_EFFORT:-medium}"
fi
if [ "$JUDGE" -eq 1 ] && [ "$LANE" = "native" ]; then
    [ -z "$MODEL" ] && MODEL=claude-opus-5-5
    CLAUDE_CODE_EFFORT_LEVEL="${HIMMEL_CONSOLE_JUDGE_EFFORT:-high}"
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
HEADED_ARM="${HEADED_ARM_LEG_TARGET:-$HERE/../headed-arm.sh}"

# HIMMEL-3724 phase 2b: refuse to re-dispatch a leg whose worktree slug (from the
# handover doc's resume_cwd) or session name has an un-acked SHIP-STEP /
# PAUSE-RISK page record newer than its latest ack (console-wait.sh writes the
# page, ack-denial.sh the ack; see denial-ack-lib.sh). Exit 14, message naming
# ack-denial.sh and the override. No record, an acked one, a REPEAT, an unreadable
# lib or record all launch: this only ever fails OPEN. Runs before --dry-run's
# exit so a dry-run predicts the refusal, and before any real-launch write.
if [ "$IGNORE_DENIALS" -eq 0 ] && [ -r "$HERE/denial-ack-lib.sh" ]; then
    # shellcheck source=scripts/handover/console-kit/denial-ack-lib.sh
    . "$HERE/denial-ack-lib.sh"
    for _den_label in "$NAME" "$(denial_doc_label "$DOC" 2>/dev/null)"; do
        [ -n "$_den_label" ] || continue
        _den_key="$(denial_key "$_den_label")" || continue
        if _den_hit="$(denial_unacked "$_den_key")"; then
            echo "headed-arm-leg: refusing to launch $NAME: an un-acked ${_den_hit%% *} classifier denial (x${_den_hit##* }) is on record for $_den_key. Review why the leg was parked, then run: bash $HERE/ack-denial.sh $_den_key   (or pass --ignore-denials to launch anyway)" >&2
            exit 14
        fi
    done
    unset _den_label _den_key _den_hit
fi

# HIMMEL-3155: a console-spawned leg that runs merge-on-green.sh from its own
# (linked) worktree gets exit 17 "no console GO" - handover_root() falls back
# to `git rev-parse --show-toplevel`, which resolves to the WORKTREE, not the
# console's checkout, and <worktree>/handovers does not exist. Resolve the
# handover root HERE, in this wrapper's own process (still running in the
# CONSOLE's launching cwd - no konsole child exists yet), and export it
# explicitly as HANDOVER_DIR so the leg's own handover_root() call binds to
# the exact same root the console used to write its GO (console-kit/go.sh).
# HANDOVER_DIR is already a registered seam var (scripts/lib/handover-path.sh)
# read by every handover script; this widens nothing - it only makes each
# launch's already-resolved root explicit instead of leaving a leg in a
# linked worktree to silently re-derive (and miss) it. Skip resolving only
# when the console's own launching shell already set HANDOVER_DIR (Mode B -
# already correct, nothing to resolve) or when this process can't resolve
# one either (nothing to propagate - unchanged behavior from before this
# ticket).
if [ -z "${HANDOVER_DIR:-}" ]; then
    unset -f handover_root 2>/dev/null || true
    # shellcheck source=scripts/lib/handover-path.sh
    # shellcheck disable=SC1091
    if . "$HERE/../../lib/handover-path.sh" 2>/dev/null; then
        _leg_handover_root="$(handover_root 2>/dev/null)" || _leg_handover_root=""
        [ -n "$_leg_handover_root" ] && leg_propagate_env HANDOVER_DIR "$_leg_handover_root"
        unset -v _leg_handover_root
    fi
fi

# HIMMEL-2534 (coordinator follow-up): propagate HANDOVER_DIR whenever it is
# non-empty, not only when the block above just resolved it - the normal
# case for a grouped console already exports HANDOVER_DIR before this
# wrapper ever runs (Mode B above), and that caller-preset value needs the
# exact same macOS token-list crossing as the self-resolved case; on Linux
# it was already reaching the leg via inheritance, so this is a no-op there.
# leg_propagate_env de-dupes by NAME against any HEADED_ARM_LAUNCHER_ENV
# token already present, so re-calling it for the value the block above just
# propagated is a harmless no-op, not a double-add.
[ -n "${HANDOVER_DIR:-}" ] && leg_propagate_env HANDOVER_DIR "$HANDOVER_DIR"

# HIMMEL-3874: refuse a leg or judge whose handover doc's resume_cwd resolves
# INSIDE the handover root (exit 15). The root commonly lives in an Obsidian
# vault, which indexes every file regardless of .gitignore, so a judge whose
# cwd is in the vault and whose scratch is a repo tree hung it twice (609k
# files; HIMMEL-3705's docs-only fix never reached console-written briefs).
# This is the one launcher every leg and judge goes through, so the gate lives
# here. Both paths are realpath'd (symlinks followed) and the resume_cwd's
# not-yet-existing tail is resolved through its deepest existing ancestor, so
# neither a symlink under ~/.cache nor a fresh subdirectory dodges it. A leg
# worktree, a ~/.cache path and a doc with no resume_cwd are untouched, and no
# resolvable root (nothing to guard) launches as before. Runs before --dry-run's
# exit, like the denial gate above, so a dry-run predicts the refusal.
# ponytail: a `..` inside the NOT-yet-existing tail is not collapsed, so such a
# path is judged by its literal tail; it cannot be entered anyway (the launch
# cd fails on a missing component), upgrade path: normalise the tail lexically.
_leg_phys_path() { # <path> -> physical path on stdout; a missing tail is kept verbatim
    local p="$1" tail="" base
    case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
    while [ ! -d "$p" ]; do
        base="${p##*/}"
        [ -n "$base" ] || { p="${p%/}"; [ -n "$p" ] || break; continue; }
        tail="/$base$tail"
        p="${p%/*}"
        [ -n "$p" ] || p="/"
    done
    p="$(cd -P "$p" 2>/dev/null && pwd -P)" || return 1
    [ "$p" = "/" ] && p=""
    printf '%s%s\n' "$p" "$tail"
}
_leg_rcwd="$(awk '
    /^---[[:space:]]*$/ { fm++; if (fm == 2) exit; next }
    fm == 1 && /^resume_cwd:[[:space:]]*/ { sub(/^resume_cwd:[[:space:]]*/, ""); print; exit }
' "$DOC" 2>/dev/null)"
_leg_rcwd="${_leg_rcwd%"${_leg_rcwd##*[![:space:]]}"}"
_leg_rcwd="${_leg_rcwd#\'}"; _leg_rcwd="${_leg_rcwd%\'}"
_leg_rcwd="${_leg_rcwd#\"}"; _leg_rcwd="${_leg_rcwd%\"}"
case "$_leg_rcwd" in \~|\~/*) _leg_rcwd="${HOME:-}${_leg_rcwd#\~}" ;; esac
_leg_vroot="${HANDOVER_DIR:-}"
if [ -z "$_leg_vroot" ] && command -v handover_root >/dev/null 2>&1; then
    _leg_vroot="$(handover_root 2>/dev/null)" || _leg_vroot=""
fi
if [ -n "$_leg_rcwd" ] && [ -n "$_leg_vroot" ]; then
    _leg_rcwd_phys="$(_leg_phys_path "$_leg_rcwd")" || _leg_rcwd_phys=""
    _leg_vroot_phys="$(_leg_phys_path "$_leg_vroot")" || _leg_vroot_phys=""
    if [ -n "$_leg_rcwd_phys" ] && [ -n "$_leg_vroot_phys" ]; then
        case "$_leg_rcwd_phys" in
        "$_leg_vroot_phys"|"$_leg_vroot_phys"/*)
            echo "headed-arm-leg: refusing to launch $NAME: the doc's resume_cwd ($_leg_rcwd -> $_leg_rcwd_phys) is inside the handover root ($_leg_vroot_phys), which an Obsidian vault indexes file by file (HIMMEL-3874). Judge scratch belongs under ~/.cache/himmel/verdicts/<qid>/; a leg belongs in a worktree under its repo's .claude/worktrees." >&2
            exit 15
            ;;
        esac
    fi
fi
unset -f _leg_phys_path
unset -v _leg_rcwd _leg_rcwd_phys _leg_vroot _leg_vroot_phys

# Context resolution (HIMMEL-2766/HIMMEL-2779): off-values stay standard;
# the one old 1m opt-in is resolved explicitly so the argv guard below can
# reject it with a useful message rather than silently ignoring operator input.
#
# HIMMEL-4012: the `design` profile (and only it) resolves 1m by itself - an
# operator ruling (2026-10-01) that early compaction hurts design work, so no
# LEG_CONTEXT or brief Context line is needed; every other profile keeps the
# 200000 ceiling and a bare LEG_CONTEXT=1m is still refused below.
DESIGN_CONTEXT_REASON=""
case ",$PROFILE," in
*,design,*)
    DESIGN_CONTEXT_REASON="design profile (HIMMEL-4012 operator ruling: no early compaction on design legs)" ;;
esac
if [ "${LEG_CONTEXT:-}" = "1m" ] || [ -n "$DESIGN_CONTEXT_REASON" ]; then
    CONTEXT="1m"
    RESOLVED_AUTOCOMPACT="auto"
else
    CONTEXT="standard"
    RESOLVED_AUTOCOMPACT="200000"
fi

# HIMMEL-3139: console-only knobs that must never reach a leg's own process,
# and therefore never reach the konsole child this wrapper execs into via
# headed-arm.sh (whose env -u list only clears the three HIMMEL-2545
# session-identity vars, not this one). CONSOLE_CONTEXT is read by
# headed-arm.sh to pick a CONSOLE's --autocompact ceiling; a leg's ceiling is
# already pinned above via LEG_CONTEXT/RESOLVED_AUTOCOMPACT, which never
# consults CONSOLE_CONTEXT, so unsetting it here loses nothing. A console
# armed with CONSOLE_CONTEXT=1m in its own environ (the same leak, one hop
# earlier - out of scope here, see the ticket) would otherwise forward it to
# every leg it arms. Kept as a list, not a bare `unset`, so --dry-run can
# print it and test-headed-arm-leg.sh can assert the exact set and fail on
# drift if a future console-only knob needs the same treatment.
# HIMMEL-3456: the scrub also strips NAME=... tokens from a caller-preset
# HEADED_ARM_LAUNCHER_ENV. leg_propagate_env appends to that list rather than
# replacing it, and headed-arm.sh hands every token to the leg on every lane,
# so an `unset` alone let a caller-listed CONSOLE_CONTEXT=1m come straight
# back into the leg.
#
# HIMMEL-3795: HIMMEL_CONSOLE_JUDGE_EFFORT is the same class of hazard as
# CONSOLE_CONTEXT, not the LEG_PROFILE_* class further down - it is consumed
# above (line ~469) for THIS invocation only, and a judge's own persisting
# shell must not keep it exported: an armed judge that itself later arms a
# nested judge would otherwise have its ambient (inherited, not deliberate)
# HIMMEL_CONSOLE_JUDGE_EFFORT silently win again, the exact same "ambient
# looks deliberate" failure this ticket closes for CLAUDE_CODE_EFFORT_LEVEL.
LEG_ENV_SCRUB="CONSOLE_CONTEXT HIMMEL_CONSOLE_JUDGE_EFFORT"
for _leg_env_scrub in $LEG_ENV_SCRUB; do
    unset "$_leg_env_scrub"
    leg_env_drop_token "$_leg_env_scrub"
done
unset -v _leg_env_scrub

# (#1334 CR follow-up) A different reason than the CONSOLE_CONTEXT scrub above
# but the same shape: this wrapper's own process may itself BE a leg that is
# now arming a SIBLING leg, and LEG_PROFILE_SETTINGS/LEG_PROFILE_PREFACE/
# LEG_PROFILE_MCP_CONFIG - both the plain env var and the
# HEADED_ARM_LAUNCHER_ENV token leg-1's own launch added - are still live in
# that shell. Unlike CONSOLE_CONTEXT these three names DO belong on a leg, so
# this is not a "must never reach a leg" scrub - it is "must be recomputed by
# THIS leg, never inherited from a sibling". Dropping the token only where a
# name is re-propagated is not enough: a path that does NOT touch a given name
# this run (no --profile; a profile with mcpServers: null skips
# LEG_PROFILE_MCP_CONFIG entirely) would otherwise leave that sibling's stale
# value live - the plain var read at
# real-launch time (LEG_PROFILE_MCP_CONFIG's write-if-set check further down)
# and the token forwarded to the actually-launched leg. Scrubbing both, once,
# before any branch, means every path starts clean and the existing
# leg_propagate_env calls are the only thing that can set them again.
for _leg_env_scrub in LEG_PROFILE_SETTINGS LEG_PROFILE_PREFACE LEG_PROFILE_MCP_CONFIG; do
    unset -v "$_leg_env_scrub"
    leg_env_drop_token "$_leg_env_scrub"
done
unset -v _leg_env_scrub

# HIMMEL-3720: same "this wrapper's own process may itself BE a leg" hazard as
# the LEG_PROFILE_* scrub above, but for the rest of the names a leg sets on
# itself while arming a SIBLING (most often a judge). A judge deliberately
# never gets IMPL_GUARD_OK/INLINE_IMPL_OK re-set below (a judge doesn't
# implement) - without this scrub, an inherited value from the calling leg's
# own session reaches it anyway, unset+undetected. console_context_leg_env_unset_names
# (scripts/lib/console-context.sh) is the single source of truth for this set
# already - console.sh's do_arm() blindly unsets the whole list before arming
# headed-arm.sh directly, which is safe there because do_arm() never reads any
# of these names as input. This wrapper DOES read six of them as deliberate,
# tested ambient input (HANDOVER_DIR above; HIMMEL_CONSOLE_NAME,
# CLAUDE_CODE_EFFORT_LEVEL, LEG_EFFORT and HEADED_ARM_UNAME further down;
# HIMMEL_CONSOLE_LEG has a pinned caller-preset-wins override test, case 31b),
# so scrubbing those here would destroy the exact feature they exist for -
# they are excluded by name, not by re-deriving a second list. The three
# LEG_PROFILE_* names are excluded because the loop above already scrubbed
# them; HEADED_ARM_LAUNCHER_ENV is excluded because it is the container being
# cleaned, not a name inside it. LEG_CLAUDE_BIN is NOT excluded (HIMMEL-3720
# left it as a plain-var exception; HIMMEL-3795 closes it): unlike the six
# names above, this wrapper never reads LEG_CLAUDE_BIN back as deliberate
# input on this native lane - only the claudex branch and the
# HEADED_ARM_LEG_CLAUDE_BIN test seam below ever set it again, both via a
# fresh `leg_propagate_env` call after this point. Scrubbing var+token here
# closes the leak: a claudex leg's own `LEG_CLAUDE_BIN=<claude-codex>`
# inherited into a native --judge/--profile launch would otherwise reach
# leg-claude-launcher.sh's `CLAUDE_BIN="${LEG_CLAUDE_BIN:-claude}"` (see
# leg-claude-launcher.sh:63) and exec the wrong binary. Every remaining name
# is set-only, so unsetting it early and letting the existing
# leg_propagate_env/export calls below re-set it is a no-op for a normal
# console-launched leg or judge and closes the leak for a leg-launched one.
# shellcheck source=scripts/lib/console-context.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/console-context.sh"
# HIMMEL-3797: LEG_EFFORT is excluded (not scrubbed) same as the other five
# names above, so it still passes through unchanged into a --judge launch as
# a plain ambient var. Harmless today: a native judge never reads LEG_EFFORT
# back (only the claudex branch further down and the relay path do), so an
# inherited value has nothing to affect here. It would matter the day a
# judge itself arms a claudex leg and forwards LEG_EFFORT to it - watch for
# that if the judge role ever grows a claudex-arming path.
for _leg_env_scrub in $(console_context_leg_env_unset_names); do
    case "$_leg_env_scrub" in
        HANDOVER_DIR|HIMMEL_CONSOLE_NAME|CLAUDE_CODE_EFFORT_LEVEL|LEG_EFFORT|HEADED_ARM_UNAME) continue ;;
        HIMMEL_CONSOLE_LEG) continue ;;
        LEG_PROFILE_SETTINGS|LEG_PROFILE_PREFACE|LEG_PROFILE_MCP_CONFIG) continue ;;
        HEADED_ARM_LAUNCHER_ENV) continue ;;
    esac
    unset -v "$_leg_env_scrub"
    leg_env_drop_token "$_leg_env_scrub"
done
unset -v _leg_env_scrub

# HIMMEL-3795: the scrub above just dropped any inherited LEG_CLAUDE_BIN, var
# and token, unconditionally. test-headed-arm-leg.sh's --headless suite
# (run_headless(), case 29) needs a way to point leg-claude-launcher.sh's
# `CLAUDE_BIN="${LEG_CLAUDE_BIN:-claude}"` (leg-claude-launcher.sh:63) at a
# stub, without reintroducing the leak the scrub just closed - a plain
# LEG_CLAUDE_BIN in this wrapper's own process env is now indistinguishable
# from a stale sibling leak, so the suite gets its own dedicated seam name
# instead. A real caller never sets this; only a test does. Scoped to the
# native lane so it can never race the claudex branch's own
# `leg_propagate_env LEG_CLAUDE_BIN "$CLAUDEX_BIN"` further down - no
# existing or new caller combines the two.
#
# The seam name itself is unset right after use (var + any launcher-env
# token) for the same reason HIMMEL_CONSOLE_JUDGE_EFFORT is scrubbed above:
# an armed leg that itself later arms a nested leg/judge must not have an
# ambient HEADED_ARM_LEG_CLAUDE_BIN, inherited from its own launch, silently
# satisfy this seam again - only the immediate caller of THIS invocation may
# set it.
if [ "$LANE" = "native" ] && [ -n "${HEADED_ARM_LEG_CLAUDE_BIN:-}" ]; then
    leg_propagate_env LEG_CLAUDE_BIN "$HEADED_ARM_LEG_CLAUDE_BIN"
fi
unset -v HEADED_ARM_LEG_CLAUDE_BIN
leg_env_drop_token HEADED_ARM_LEG_CLAUDE_BIN

# HIMMEL-2779: a leg's ceiling is the resolved CLI pair, not the absence of a
# model suffix. Fail before dry-run reporting or preflight when context already
# resolves wrong; headed-arm.sh separately validates the exact argv it launches.
#
# HIMMEL-3581: a sanctioned operator ruling opens this door - mirrors the
# Tier-line gate below (HIMMEL-2976), same shape: a fixed marker line in the
# brief, grepped by exact prefix, non-blank free text required. CONTEXT_REASON
# stays empty for every standard-ceiling launch (the case above never sets
# RESOLVED_AUTOCOMPACT to anything but 200000 there), so this block is a
# no-op for every existing caller.
CONTEXT_REASON=""
if [ "$RESOLVED_AUTOCOMPACT" != "200000" ]; then
    CONTEXT_REASON="$DESIGN_CONTEXT_REASON"
    [ -n "$CONTEXT_REASON" ] || CONTEXT_REASON="$(grep -m1 -E '^> \*\*Context:\*\* 1m — operator-ruling: ' "$DOC" 2>/dev/null | sed -E 's/^> \*\*Context:\*\* 1m — operator-ruling: //')"
    CONTEXT_REASON="$(printf '%s' "$CONTEXT_REASON" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    if [ -z "$CONTEXT_REASON" ]; then
        echo "headed-arm-leg: refusing leg launch: resolved argv lacks the required --autocompact 200000 ceiling (got --autocompact $RESOLVED_AUTOCOMPACT). unset LEG_CONTEXT and retry, or add '> **Context:** 1m — operator-ruling: <reason>' to $DOC for a sanctioned opt-in; use a console arm, not a leg, for unsanctioned 1m context." >&2
        exit 2
    fi
    # headed-arm.sh's own 1m gate (unedited by this ticket) requires
    # CONSOLE_CONTEXT=1m in ITS process env, not merely a resolved CONTEXT
    # positional - a var it consumes in THIS SAME process tree, so a plain
    # export (never leg_propagate_env) is the right channel, same convention
    # leg_propagate_env's own header documents for HEADED_ARM_REPO etc. The
    # HIMMEL-3139 scrub above already ran unconditionally and unset any
    # ambient value before this point; this is a deliberate, narrow re-set
    # for the one sanctioned exec below, not a change to that scrub. Any
    # further headed-arm-leg.sh launch this leg itself makes re-scrubs it
    # from scratch, so no ambient leak survives past this one call.
    export CONSOLE_CONTEXT=1m
fi

# HIMMEL-2976: an Opus or Fable leg costs materially more per turn than the
# Sonnet default implementor, so it launches only when its brief names one of
# the four sanctioned reasons on a Tier line (CLAUDE.md: "raise effort
# before tier"). Matched by MODEL PREFIX, same reasoning as the [1m] suffix
# guard above - a suffix (e.g. claude-opus-5[1m]) must not dodge the gate.
TIER_GATE=""
case "$MODEL" in
    claude-opus-*) TIER_GATE="opus" ;;
    claude-fable-*) TIER_GATE="fable" ;;
esac
if [ -n "$TIER_GATE" ]; then
    TIER_REASON="$(grep -m1 -E "^> \*\*Tier:\*\* $TIER_GATE — " "$DOC" 2>/dev/null | sed -E "s/^> \*\*Tier:\*\* $TIER_GATE — //")"
    # codex-1 (HIMMEL-2976 round 1 CR): `-z` alone treats a whitespace-only
    # reason (e.g. a Tier line with nothing but trailing spaces after the
    # dash) as non-empty, so strip surrounding whitespace before the check.
    TIER_REASON="$(printf '%s' "$TIER_REASON" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    if [ -z "$TIER_REASON" ]; then
        echo "headed-arm-leg: refusing $TIER_GATE launch: $DOC has no '> **Tier:** $TIER_GATE — <category>: <reason>' line (CLAUDE.md: raise effort before tier). Sanctioned reasons: multi-step design; a FINDING the console could not verify at Sonnet; a Sonnet leg returned the work as above its tier; a standing operator ruling on model choice (HIMMEL-3480). Category tags (exact lowercase): design|unverified-finding|tier-return|operator-ruling." >&2
        exit 2
    fi
    # HIMMEL-2997: the design was left open (keyword vs enum vs LLM) - console
    # ruling: a closed category TAG followed by free text, so paraphrase in
    # the free text can never be falsely rejected. Split on the first ':'.
    # codex-1 (HIMMEL-2997 round 1 CR): both expansions below are no-ops when
    # no literal ':' is present, so a bare tag (e.g. "design" alone) would
    # otherwise pass with TIER_CATEGORY=TIER_REASON=the tag itself - require
    # the colon explicitly first.
    case "$TIER_REASON" in
        *:*) ;;
        *)
            echo "headed-arm-leg: refusing $TIER_GATE launch: $DOC's Tier reason must open with one of the four sanctioned category tags (exact lowercase) followed by ': ' and non-blank free text: design|unverified-finding|tier-return|operator-ruling." >&2
            exit 2
            ;;
    esac
    TIER_CATEGORY="${TIER_REASON%%:*}"
    TIER_REASON="${TIER_REASON#*:}"
    case "$TIER_CATEGORY" in
        design|unverified-finding|tier-return|operator-ruling) ;;
        *)
            echo "headed-arm-leg: refusing $TIER_GATE launch: $DOC's Tier reason must open with one of the four sanctioned category tags (exact lowercase) followed by ': ' and non-blank free text: design|unverified-finding|tier-return|operator-ruling." >&2
            exit 2
            ;;
    esac
    TIER_REASON="$(printf '%s' "$TIER_REASON" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    if [ -z "$TIER_REASON" ]; then
        echo "headed-arm-leg: refusing $TIER_GATE launch: $DOC's Tier reason has category '$TIER_CATEGORY' but no free text after the colon." >&2
        exit 2
    fi
fi

# HIMMEL-3997: advisory effort recommendation. Only when the brief carries
# '> **Effort-record:** <path>' (an effort-assess record). One stderr line;
# it never changes the launch, the exit code or the Tier gate, and any failure
# (missing/unreadable record, node absent, bad JSON) degrades to an
# 'unavailable' line. Absent marker = no output at all.
EFFORT_REC="$(grep -m1 -E '^> \*\*Effort-record:\*\* ' "$DOC" 2>/dev/null | sed -E 's/^> \*\*Effort-record:\*\* //; s/[[:space:]]+$//')" || EFFORT_REC=""
if [ -n "$EFFORT_REC" ]; then
    EFFORT_WHY=""
    EFFORT_JSON=""
    if [ ! -r "$EFFORT_REC" ]; then
        EFFORT_WHY="record not readable: $EFFORT_REC"
    elif ! EFFORT_JSON="$(node "$HERE/../../lanes/effort-route.mjs" "$EFFORT_REC" 2>&1)"; then
        EFFORT_WHY="effort-route failed: $(printf '%s' "$EFFORT_JSON" | head -n 1)"
    else
        EFFORT_LINE="$(printf '%s' "$EFFORT_JSON" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).advisory||"")}catch(e){}})' 2>/dev/null)" || EFFORT_LINE=""
        if [ -n "$EFFORT_LINE" ]; then
            echo "headed-arm-leg: advisory: recommended $EFFORT_LINE; launching LEG_EFFORT=${LEG_EFFORT:-<unset>}" >&2
        else
            EFFORT_WHY="effort-route output not parseable"
        fi
    fi
    [ -z "$EFFORT_WHY" ] || echo "headed-arm-leg: advisory: unavailable ($EFFORT_WHY)" >&2
fi

# LEG_REPO folds onto headed-arm.sh's own HEADED_ARM_REPO override seam -
# the one thing the two prior kit-local copies differed on.
if [ -n "${LEG_REPO:-}" ]; then
    HEADED_ARM_REPO="$LEG_REPO"
    export HEADED_ARM_REPO
fi

# LEG_SUPPRESS_CR_TRIGGER (HIMMEL-3141): opt-out-by-console seam for the
# CodeRabbit auto-trigger hooks (trigger-cr-on-pr-create.sh,
# trigger-cr-on-push.sh - both route their post through
# cr_trigger_post_review in scripts/lib/cr-trigger-ledger.sh, so this ONE
# knob covers both; see that function for why). Set in the LAUNCHING shell
# (e.g. `LEG_SUPPRESS_CR_TRIGGER=1 bash headed-arm-leg.sh ...`), same
# pattern as LEG_REPO above, and folded here into CR_TRIGGER_SUPPRESS, the
# name the hooks/ledger actually read - never a flag, since this is a
# per-launch console decision, not part of the leg's identity. Opt-out
# ONLY: leaving it unset changes nothing, which is the ticket's explicit
# requirement (the auto-trigger hook exists because manual triggering was
# left to discretion once already and every open PR went unreviewed,
# HIMMEL-1362) - a default-off seam here would recreate that exact failure.
if [ -n "${LEG_SUPPRESS_CR_TRIGGER:-}" ]; then
    leg_propagate_env CR_TRIGGER_SUPPRESS 1
fi

# IMPL_GUARD_OK=1 / INLINE_IMPL_OK=1: leg-only env for
# guard-implementor-dispatch / orchestrator-inline-guard (HIMMEL-2879).
# headed-arm.sh's shared console/leg child-env block does not set these.
# Export into THIS process so both survive konsole's `-e env -u ...`, which
# only unsets the three HIMMEL-2545 vars and otherwise inherits as-is.
# --judge (HIMMEL-3133): a judge does not implement, so neither permission is
# exported for it. The --dry-run report below reads both via ${VAR:-<unset>}
# rather than a bare $VAR, since a judge launch never sets them at all and
# this script runs under `set -u`.
if [ "$READONLY_ROLE" -ne 1 ]; then
    leg_propagate_env IMPL_GUARD_OK 1
    leg_propagate_env INLINE_IMPL_OK 1
fi
# HIMMEL_CONSOLE_LEG=1 (HIMMEL-2919): marks the launched process as a
# console-spawned leg, both lanes - including --judge (design §3.2, "the
# judge is a leg": this IS Guard E for a judge too, no separate
# HIMMEL_CONSOLE_JUDGE marker). merge-on-green.sh then merges only on the
# console's GO file (console-kit/go.sh), and go.sh refuses to run under it.
leg_propagate_env HIMMEL_CONSOLE_LEG 1
# HIMMEL_CONSOLE_NAME (HIMMEL-3435): the owning console's session name, so a
# leg's HIMMEL-3430 merge-block alert (scripts/lib/merge-block-alert.sh,
# untouched by this ticket - it already reads this var) can route to the
# console's own inbox instead of DMing the operator. Resolved from the first
# of three sources that yields a name - never guessed from the process tree:
#   1. --console <name> (already charset-refused above if malformed)
#   2. the launching shell's own HIMMEL_CONSOLE_NAME
#   3. THIS process's own Claude session name (current_session_name(),
#      scripts/lib/session-name.sh) - set when this launcher call is itself
#      running inside a named console session
# Sources 2 and 3 are re-checked against the same charset --console was
# refused on above (it lands in the same inbox-lookup path), but a failure
# there does not abort the launch the way a bad --console flag does: this
# seam is best-effort alert routing, not load-bearing for the leg, and
# HIMMEL-3430's own no-name fallback (operator DM) already covers "no usable
# name" cleanly. A candidate failing the charset check is therefore treated
# exactly like an empty source - try the next one, or export nothing.
_console_name_ok() {
    case "$1" in
        ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;;
        *) return 0 ;;
    esac
}
# HIMMEL-3456: a caller-preset HIMMEL_CONSOLE_NAME= launcher token would win
# leg_propagate_env's name clash and reach the leg unvalidated, so drop it -
# only the name resolved below (or none) may propagate.
leg_env_drop_token HIMMEL_CONSOLE_NAME
if [ -n "$CONSOLE_FLAG" ]; then
    CONSOLE_NAME="$CONSOLE_FLAG"
elif _console_name_ok "${HIMMEL_CONSOLE_NAME:-}"; then
    CONSOLE_NAME="$HIMMEL_CONSOLE_NAME"
else
    CONSOLE_NAME=""
    # shellcheck source=../../lib/session-name.sh
    # shellcheck disable=SC1091
    if . "$HERE/../../lib/session-name.sh" 2>/dev/null; then
        _detected_console_name="$(current_session_name 2>/dev/null)" || _detected_console_name=""
        _console_name_ok "$_detected_console_name" && CONSOLE_NAME="$_detected_console_name"
        unset -v _detected_console_name
    fi
fi
if [ -n "$CONSOLE_NAME" ]; then
    # HIMMEL-2534: leg_propagate_env, not a bare export - on macOS `open -a`
    # starts a fresh environment, so a bare export never crosses and #1121's
    # console-alert routing would silently stop reaching the leg.
    # _console_name_ok already refuses whitespace, so leg_propagate_env's
    # Darwin exit 12 branch is unreachable for this variable.
    leg_propagate_env HIMMEL_CONSOLE_NAME "$CONSOLE_NAME"
else
    unset HIMMEL_CONSOLE_NAME
fi
unset -v CONSOLE_NAME
unset -f _console_name_ok
# HIMMEL_READ_CLAMP_LINES (HIMMEL-3133 / design §3.2): raises read-clamp.sh's
# whole-file limit for a judge - independent reading is the job. 4000 is a
# judgment call (no source document names a number): ~10x the leg default of
# 400, generous for a design-sized doc without reopening the clamp entirely,
# which stays HIMMEL_READ_CLAMP_OK's own, operator-only lever. The repeat-read
# half of the clamp (read-clamp.sh's per-range dedup) is untouched.
[ "$READONLY_ROLE" -eq 1 ] && leg_propagate_env HIMMEL_READ_CLAMP_LINES 4000
# HIMMEL_CONSOLE_RELAY=1 (HIMMEL-2975): marks this leg as the Sonnet relay half
# of a split console. inbox-send.sh's Guard C already refuses --token under it
# (#733); the Task 26 write-deny hook denies writes under it. Both key off
# this exact marker, not the console-relay profile above.
[ "$RELAY" -eq 1 ] && leg_propagate_env HIMMEL_CONSOLE_RELAY 1
# headed-arm.sh builds one argv array for both native and recorder launches and
# refuses exit 2 if this exact pair is absent. This is the final resolved-argv
# guard; the context-value check above gives the earlier operator-facing error.
# HIMMEL-3581: the required value tracks RESOLVED_AUTOCOMPACT, not a hardcoded
# 200000 - a sanctioned Context-line opt-in resolves it to `auto` above, and
# this guard must then require THAT value, not the standard ceiling.
export HEADED_ARM_REQUIRED_AUTOCOMPACT="$RESOLVED_AUTOCOMPACT"

# Native-lane effort (HIMMEL-3488): HIMMEL-3482 wired lanes.json's claude-tier
# effort into the native Telegram dispatch (scripts/telegram/run.ts's
# laneEffort()/spawnSpec, CLAUDE_CODE_EFFORT_LEVEL). This mirrors the same
# match rule - exact model id, or the model prefixed "claude-<tier-id>-" - for
# a console-launched native leg, which otherwise runs at ambient effort
# instead of the registry's declared value. Mirrored rather than imported:
# run.ts is TS/bun-only and off the leg's Do-not list to edit; jq is already
# a direct dependency of this file (the --profile settings merge below).
# An explicit CLAUDE_CODE_EFFORT_LEVEL from the LAUNCHING shell always wins
# over the registry - checked here, before the lookup, because
# leg_propagate_env's own `export` would otherwise silently overwrite it with
# the registry's value. It still needs the SAME leg_propagate_env call as the
# registry path (re-propagating a value already in the environment is a
# no-op), so it reaches HEADED_ARM_LAUNCHER_ENV's token list and shows up in
# the dry-run report the same way a registry-resolved value does.
if [ "$LANE" = "native" ]; then
    if [ -n "${CLAUDE_CODE_EFFORT_LEVEL:-}" ]; then
        leg_propagate_env CLAUDE_CODE_EFFORT_LEVEL "$CLAUDE_CODE_EFFORT_LEVEL"
    else
        LANES_JSON="${HEADED_ARM_LEG_LANES_JSON:-$HERE/../../lanes/lanes.json}"
        if [ -f "$LANES_JSON" ]; then
            NATIVE_EFFORT="$(jq -r --arg model "$MODEL" '
                [ .lanes[]? | select(.class == "claude-tier") | . as $lane
                  | select($lane.id == $model or ($model | startswith("claude-" + $lane.id + "-")))
                  | $lane.effort ] | first // empty
            ' "$LANES_JSON" 2>/dev/null)"
            case "$NATIVE_EFFORT" in
                low | medium | high | xhigh | max)
                    leg_propagate_env CLAUDE_CODE_EFFORT_LEVEL "$NATIVE_EFFORT"
                    ;;
            esac
        fi
    fi
fi

# claudex lane (HIMMEL-2782): see the --lane header comment above.
if [ "$LANE" = "claudex" ]; then
    CLAUDEX_BIN="${HEADED_ARM_LEG_CLAUDEX_BIN:-$HERE/../../claude-codex}"
    export HEADED_ARM_LAUNCHER="$CLAUDEX_BIN"
    leg_propagate_env CLAUDEX_LANE_OK 1
    leg_propagate_env CLAUDE_CODE_EFFORT_LEVEL "${LEG_EFFORT:-medium}"
    export HEADED_ARM_RECORDER=1
    [ -z "$MODEL" ] && MODEL="gpt-6.1-sol"
fi

# --profile (HIMMEL-2830): resolve the plugin profile and point headed-arm.sh's
# launcher seam at the shim that will apply it. Resolution happens even under
# --dry-run (so a typo'd profile name fails the same way either way); only the
# settings FILE is withheld until we know we are really launching.
if [ -n "$PROFILE" ]; then
    PROFILES_MJS="${HEADED_ARM_LEG_PROFILES:-$HERE/../../lanes/plugin-profiles.mjs}"
    LEG_SHIM="${HEADED_ARM_LEG_SHIM:-$HERE/../../lanes/leg-claude-launcher.sh}"
    # --judge (HIMMEL-3133): the leg preface tells a read-only judge to
    # implement and ship, which is wrong for the role. HEADED_ARM_LEG_PREFACE
    # stays the higher-precedence test seam either branch honors - only the
    # DEFAULT changes.
    if [ "$JUDGE" -eq 1 ]; then
        LEG_PREFACE="${HEADED_ARM_LEG_PREFACE:-$HERE/../../../docs/handover/judge-preface.md}"
    elif [ "$CONSULT" -eq 1 ]; then
        LEG_PREFACE="${HEADED_ARM_LEG_PREFACE:-$HERE/../../../docs/handover/consult-preface.md}"
    else
        LEG_PREFACE="${HEADED_ARM_LEG_PREFACE:-$HERE/../../../docs/handover/leg-preface.md}"
    fi
    # Next to the launch log, i.e. inside the per-uid console work dir the
    # console already owns and cleans - never /tmp world-readable, never the
    # repo (it is generated, per-leg state).
    PROFILE_SETTINGS="$(dirname "$LOG")/$NAME.leg-settings.json"
    # (HIMMEL-2990) Native lane only: the brief's own contract, re-injected by
    # the compact-matcher SessionStart hook below instead of ridden in the
    # preface on every call. Resolved to an absolute path (CR round 2,
    # codex-1): the hook command re-parses this path in the leg's OWN process
    # at fire time, whose cwd need not match this launcher's cwd, so a
    # relative path would silently miss.
    _leg_log_dir="$(cd "$(dirname "$LOG")" && pwd)" || {
        echo "headed-arm-leg: --profile $PROFILE: cannot resolve log directory for $LOG" >&2
        exit 2
    }
    PROFILE_CONTRACT="$_leg_log_dir/$NAME.leg-contract.md"
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
    # (HIMMEL-3536) A leg works in its worktree by cd, never by EnterWorktree:
    # a pinned session's worktree-isolation screen refuses /pr-check step 0's
    # canonical fence (it runs the HIMMEL_REPO anchor's script, outside the
    # pin), so a leg whose diff touches scripts/cr/ could not review itself
    # without a human. A tool-name deny removes the tool from the leg's list.
    # The relay never works in a worktree and keeps its settings as they are.
    if [ "$RELAY" -eq 0 ]; then
        if ! PROFILE_JSON="$(printf '%s' "$PROFILE_JSON" | jq '.permissions.deny = ((.permissions.deny // []) + ["EnterWorktree"])')"; then
            echo "headed-arm-leg: --profile $PROFILE: cannot add the EnterWorktree deny to settings JSON" >&2
            exit 2
        fi
    fi
    # HANDOVER_DIR reaches this wrapper as a plain exported string, which may
    # carry a trailing slash a caller happened to set. Normalize it once
    # through `cd -P && pwd -P` (the kit's own canonicaliser, matching
    # handover-path.sh's physical resolution) so both the root-equality
    # check below and the .locks deny pattern compare against the SAME
    # canonical form _leg_doc_dir (also `cd -P && pwd -P`-derived) uses - a
    # raw trailing-slash HANDOVER_DIR would otherwise silently bypass both
    # (CR round 3, codex-1), and a symlink component would otherwise let a
    # doc dir reached through it evade the comparison (CR round 5, codex-2).
    _leg_handover_dir_norm=""
    if [ -n "${HANDOVER_DIR:-}" ]; then
        _leg_handover_dir_norm="$(cd -P "$HANDOVER_DIR" 2>/dev/null && pwd -P)"
        if [ -z "$_leg_handover_dir_norm" ]; then
            echo "headed-arm-leg: --profile $PROFILE: HANDOVER_DIR='$HANDOVER_DIR' is not a directory" >&2
            exit 2
        fi
    fi
    # (HIMMEL-3285) A leg writes its Results bullets to its own handover doc,
    # which sits outside the leg's working directories whenever the resolved
    # handover root is external (Mode B) or the doc's own root otherwise -
    # the auto-mode classifier inconsistently refuses those writes as
    # Out-of-Place Publication. Grant only the DOC's own directory, never the
    # whole handover root: console-kit/go.sh's merge GO is authenticated only
    # by the EXISTENCE of <handover_root>/.locks/go/<pr>.<sha> (go-gate.sh,
    # merge-on-green.sh), with no hook guarding that path today - widening a
    # leg's grant to the root would auto-approve its own Write there, letting
    # a leg mint its own merge GO. The doc's directory is a strict subdir of
    # the leg's own bucket (handovers/<user>/<repo>/...), which never
    # contains .locks/ (that sits at the handover ROOT) - verified below
    # rather than assumed, so a doc placed directly AT the root can never
    # collapse this grant back to the whole root (CR round 2, codex-1).
    # A doc directory that EQUALS the handover root, or is an ANCESTOR of it
    # (CR round 4, codex-1, fixed per HIMMEL-3544), must never be granted:
    # additionalDirectories would then cover the whole root - and its
    # .locks/ - the exact privilege this grant exists to avoid. Rather than
    # refusing the launch outright (round-3 behaviour for the equal case),
    # skip the grant and fall back to today's classifier behaviour for this
    # leg's own doc writes; the launch still succeeds. Compared as canonical
    # absolute paths (both `cd -P && pwd -P`-derived, so a symlinked doc
    # directory resolves physically too) so a lookalike prefix like /a/bc
    # is never mistaken for an ancestor of /a/b.
    # When HANDOVER_DIR could not be resolved at all, _leg_handover_dir_norm
    # is empty and the root/ancestor comparison below cannot run - an
    # unknown root can never be proven safe, so treat that the same as a
    # confirmed root/ancestor match rather than falling through to an
    # ungated grant (CR round 5, codex-1).
    _leg_doc_path=""
    if [ -n "$DOC" ] && _leg_doc_dir="$(cd -P "$(dirname "$DOC")" 2>/dev/null && pwd -P)"; then
        _leg_doc_path="$_leg_doc_dir/$(basename "$DOC")"
        _leg_doc_is_root_or_ancestor=0
        if [ -z "$_leg_handover_dir_norm" ]; then
            _leg_doc_is_root_or_ancestor=1
        elif [ "$_leg_doc_dir" = "$_leg_handover_dir_norm" ]; then
            _leg_doc_is_root_or_ancestor=1
        else
            case "$_leg_handover_dir_norm" in
                "$_leg_doc_dir"/*)
                    _leg_doc_is_root_or_ancestor=1
                    ;;
            esac
        fi
        if [ "$_leg_doc_is_root_or_ancestor" -eq 1 ]; then
            echo "headed-arm-leg: --profile $PROFILE: leg doc directory ($_leg_doc_dir) is the handover root or an ancestor of it, or HANDOVER_DIR could not be resolved (HANDOVER_DIR='${HANDOVER_DIR:-}') - skipping additionalDirectories grant for it" >&2
        elif [ "$CONSULT" -eq 1 ]; then
            # additionalDirectories become sandbox write roots: a consult's write set is its doc FILE only.
            :
        elif ! PROFILE_JSON="$(printf '%s' "$PROFILE_JSON" | jq --arg dir "$_leg_doc_dir" \
            '.permissions.additionalDirectories = ((.permissions.additionalDirectories // []) + [$dir])')"; then
            echo "headed-arm-leg: --profile $PROFILE: cannot add the leg doc's directory to additionalDirectories" >&2
            exit 2
        fi
    fi
    unset -v _leg_doc_is_root_or_ancestor
    # Belt and braces: even scoped to the doc's own directory, deny Edit on
    # the handover root's .locks/** outright. Only Edit is emitted: Claude
    # Code applies an Edit(path) rule to every file-editing tool now, and
    # warns on every leg exit that Write/MultiEdit/NotebookEdit rules on the
    # same path are dead code (HIMMEL-3645) - so seeding them protects
    # nothing. Deny wins over additionalDirectories, so this holds even if a
    # future change widens the grant back toward the root. Gated the same as
    # the EnterWorktree deny above: the relay never works in a worktree and
    # keeps its settings as they are.
    if [ "$RELAY" -eq 0 ] && [ -n "$_leg_handover_dir_norm" ]; then
        if ! PROFILE_JSON="$(printf '%s' "$PROFILE_JSON" | jq --arg dir "$_leg_handover_dir_norm" \
            '.permissions.deny = ((.permissions.deny // []) + (["Edit"] | map(. + "(" + $dir + "/.locks/**)")))')"; then
            echo "headed-arm-leg: --profile $PROFILE: cannot add the .locks deny to settings JSON" >&2
            exit 2
        fi
    fi
    # (HIMMEL-3698) additionalDirectories above only widens the DIRECTORY
    # boundary check - it grants no permission `allow` rule, so the auto-mode
    # classifier could still deny the leg's own Edit of its handover doc
    # (N577, N582, N564 each parked on exactly this). Grant Edit on this
    # leg's OWN doc file only - an exact path, never a root-wide `**/*.md`
    # glob: a glob would let a leg edit a SIBLING leg's or a JUDGE's doc
    # (its Results, its RETASK block) under the same handover bucket (CR
    # round 2, codex-1 - the go-gate lock-file rationale above answers a
    # different question and does not cover cross-doc tampering). An exact
    # path carries no such risk regardless of where the doc sits relative to
    # the handover root, so this grant does not need the root/ancestor guard
    # the additionalDirectories widening above needs. Only Edit is emitted -
    # Claude Code now applies an Edit(path) rule to every file-editing tool
    # (HIMMEL-3645 above), so a sibling Write/MultiEdit/NotebookEdit rule on
    # the same pattern is dead code. Gated the same as the .locks deny
    # (never the relay), plus JUDGE: a judge does not implement (design 3.2,
    # Guard E above) and never needs to write a LEG's handover doc, so it
    # must not gain this grant even though it resolves its own DOC too.
    if [ "$RELAY" -eq 0 ] && [ "$READONLY_ROLE" -eq 0 ] && [ -n "$_leg_doc_path" ]; then
        if ! PROFILE_JSON="$(printf '%s' "$PROFILE_JSON" | jq --arg doc "$_leg_doc_path" \
            '.permissions.allow = ((.permissions.allow // []) + ["Edit(" + $doc + ")"])')"; then
            echo "headed-arm-leg: --profile $PROFILE: cannot add the handover-doc Edit allow to settings JSON" >&2
            exit 2
        fi
    fi
    # (HIMMEL-4014) --consult read-only envelope. The file-edit tools are denied
    # by BARE name, so no path-scoped allow can re-open them (deny wins), and the
    # session carries NO Edit allow at all. Its answer goes through exactly one
    # Bash allow: append-results.sh on its own consult doc. The allow list is
    # REPLACED, not appended to: a gateAllow profile (lane-impl, lane-content...)
    # would otherwise hand the consult its ship-step allows (merge-on-green etc.).
    # The Bash sandbox (HIMMEL-4061) is ADDED to the classifier, not swapped for it:
    # autoAllowBashIfSandboxed stays false, so every Bash call is still classifier-gated.
    # Writes: the one doc FILE (append-results.sh only appends with >>, so a file bind
    # is enough) plus Claude Code's own temp dirs; the doc's parent dir (the shared
    # handover bucket) is never granted, and the additionalDirectories grant above is
    # skipped under --consult because Claude Code turns those into sandbox write roots.
    # The repo is denied. Outer settings scopes MERGE their arrays into the consult's
    # (HIMMEL-4066): sandbox allowWrite, network allowedDomains and permissions.additionalDirectories
    # (a sandbox write root: himmel's own project settings list the luna vault) are refused at
    # arm time below. A doc inside the repo is always denied, so it is refused too.
    # ponytail: Bash sandboxed to the doc file plus Claude Code's temp dirs, reads open (no denyRead) and the symlink check is launch-time, upgrade to denyRead once the smoke test proves plugin reads survive (HIMMEL-4066 follow-ups)
    # ponytail: refuses every consult in a repo whose committed settings grant additionalDirectories (himmel itself), upgrade path HIMMEL-4069
    if [ "$CONSULT" -eq 1 ]; then
        case "$_leg_doc_path/" in
            "$CONSULT_REPO_CANON"/*)
                echo "headed-arm-leg: --consult: the consult doc ($_leg_doc_path) is inside the repo ($CONSULT_REPO_CANON), which the sandbox always write-denies: put the doc under the handover root" >&2
                exit 2
                ;;
        esac
        # Every scope Claude Code merges: user (home and CLAUDE_CONFIG_DIR), the cached server
        # policy remote-settings.json, project + local settings at the cwd repo, its git
        # toplevel and the main checkout (local settings load from the canonical git root, which
        # a linked worktree maps to the main checkout), managed-settings.json and every
        # managed-settings.d/*.json drop-in. CONSULT_SETTINGS_HOME / CONSULT_MANAGED_SETTINGS are
        # test seams that are honoured in production too.
        _cs_home="${CONSULT_SETTINGS_HOME:-$HOME}"
        _CS_SAFE_SANDBOX='["sandbox.enabled","sandbox.failIfUnavailable"]'
        case "$(uname -s)" in
            Darwin) _cs_managed="${CONSULT_MANAGED_SETTINGS:-/Library/Application Support/ClaudeCode/managed-settings.json}" ;;
            *) _cs_managed="${CONSULT_MANAGED_SETTINGS:-/etc/claude-code/managed-settings.json}" ;;
        esac
        _cs_roots="$CONSULT_REPO_CANON"
        # shellcheck source=scripts/lib/git-clean.sh
        . "$HERE/../../lib/git-clean.sh"
        git_env_scrub
        _cs_top="$(git -C "$CONSULT_REPO_CANON" rev-parse --show-toplevel 2>/dev/null)" || _cs_top=""
        _cs_gc="$(git -C "$CONSULT_REPO_CANON" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || _cs_gc=""
        [ -n "$_cs_top" ] && _cs_roots="$_cs_roots
$_cs_top"
        [ -n "$_cs_gc" ] && _cs_roots="$_cs_roots
$(dirname "$_cs_gc")"
        _cs_files="$_cs_home/.claude/settings.json
$_cs_home/.claude/remote-settings.json
${CLAUDE_CONFIG_DIR:-/nonexistent}/settings.json
${CLAUDE_CONFIG_DIR:-/nonexistent}/remote-settings.json
$_cs_managed"
        _cs_mgd="$_cs_managed
$_cs_home/.claude/remote-settings.json
${CLAUDE_CONFIG_DIR:-/nonexistent}/remote-settings.json"
        for _cs_d in "$(dirname "$_cs_managed")"/managed-settings.d/*.json; do
            _cs_mgd="$_cs_mgd
$_cs_d"
            _cs_files="$_cs_files
$_cs_d"
        done
        while IFS= read -r _cs_r; do
            [ -n "$_cs_r" ] || continue
            _cs_files="$_cs_files
$_cs_r/.claude/settings.json
$_cs_r/.claude/settings.local.json"
        done <<EOF_CS_ROOTS
$_cs_roots
EOF_CS_ROOTS
        while IFS= read -r _cs_f; do
            [ -f "$_cs_f" ] || continue
            # ALLOWLIST: refuse (a) any Edit/Write/NotebookEdit permissions.allow rule (merged into
            # the sandbox write roots), (b) non-empty permissions.additionalDirectories, (c) any
            # sandbox.* leaf outside _CS_SAFE_SANDBOX set to true. An unknown sandbox key refuses.
            # Fail closed: an existing scope file jq cannot read (malformed, JSONC, a
            # non-object intermediate) cannot be shown not to widen the sandbox.
            if ! _cs_n="$(jq -r --argjson safe "$_CS_SAFE_SANDBOX" '
                first(
                  ((.permissions.allow // [])[] | select(type == "string" and test("^(Edit|Write|NotebookEdit)(\\(|$)")) | "permissions.allow rule " + .),
                   (if ((.permissions.additionalDirectories // []) | length) > 0 then "permissions.additionalDirectories" else empty end),
                   ((.sandbox // {}) as $sb | $sb | paths(type != "object") as $p
                    | ($p | map(tostring) | join(".")) as $j
                    | select(($safe | index("sandbox." + $j)) == null or ($sb | getpath($p)) != true)
                    | "sandbox." + $j)
                ) // empty' "$_cs_f" 2>/dev/null)"; then
                echo "headed-arm-leg: --consult: cannot parse $_cs_f, so it cannot be shown not to widen the sandbox: fix or remove it" >&2
                exit 2
            fi
            if [ -n "$_cs_n" ]; then
                echo "headed-arm-leg: --consult: $_cs_f carries $_cs_n, which merges into the consult's sandbox and would widen it: remove or scope it (or launch the consult from a context that does not load it). A user scope with Edit allows cannot run consults until they are scoped; additionalDirectories becomes a sandbox write root and no confinement is proven yet: HIMMEL-4069" >&2
                exit 2
            fi
            # MANAGED scopes outrank the consult's own --settings, so the pins below cannot beat
            # them: refuse a managed scope that turns on env scrub (its sandbox adds allowWrite
            # /home /tmp /var ...), sets a permissive defaultMode, or carries a policyHelper(s).
            if printf '%s\n' "$_cs_mgd" | grep -Fxq -- "$_cs_f"; then
                if ! _cs_n="$(jq -r '
                    first(
                      ((.env.CLAUDE_CODE_SUBPROCESS_ENV_SCRUB // empty) | tostring | ascii_downcase
                        | select(. != "" and . != "0" and . != "false") | "env.CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"),
                      ((.permissions.defaultMode // empty) | select(. == "bypassPermissions" or . == "acceptEdits")
                        | "permissions.defaultMode " + .),
                      ((.. | objects | keys[] | select(. == "policyHelper" or . == "policyHelpers"))
                        | "key " + .)
                    ) // empty' "$_cs_f" 2>/dev/null)"; then
                    echo "headed-arm-leg: --consult: cannot parse $_cs_f, so it cannot be shown not to widen the sandbox: fix or remove it" >&2
                    exit 2
                fi
                if [ -n "$_cs_n" ]; then
                    echo "headed-arm-leg: --consult: managed scope $_cs_f carries $_cs_n, which the consult's own settings cannot override and would widen the sandbox or its permissions: HIMMEL-4066" >&2
                    exit 2
                fi
            fi
        done <<EOF_CS_FILES
$_cs_files
EOF_CS_FILES
        # ~/.claude.json top-level env is not a settings scope but is merged into the process env:
        # refuse a truthy env scrub there too (the flag-scope pin should win; belt and braces).
        for _cs_f in "$_cs_home/.claude.json" "${CLAUDE_CONFIG_DIR:-/nonexistent}/.claude.json"; do
            [ -f "$_cs_f" ] || continue
            if ! _cs_n="$(jq -r '(.env.CLAUDE_CODE_SUBPROCESS_ENV_SCRUB // empty) | tostring | ascii_downcase
                | select(. != "" and . != "0" and . != "false")' "$_cs_f" 2>/dev/null)"; then
                echo "headed-arm-leg: --consult: cannot parse $_cs_f, so it cannot be shown not to turn on env scrub: fix or remove it" >&2
                exit 2
            fi
            if [ -n "$_cs_n" ]; then
                echo "headed-arm-leg: --consult: $_cs_f sets env.CLAUDE_CODE_SUBPROCESS_ENV_SCRUB, whose sandbox adds write roots (/home /tmp /var ...): remove it: HIMMEL-4066" >&2
                exit 2
            fi
        done
        unset -v _cs_f _CS_SAFE_SANDBOX _cs_n _cs_d _cs_r _cs_roots _cs_top _cs_gc _cs_files _cs_home _cs_managed _cs_mgd
        if [ -L "$DOC" ]; then
            echo "headed-arm-leg: --consult: the consult doc must not be a symlink ($DOC): the sandbox binds the resolved file" >&2
            exit 2
        fi
        if [ -z "$_leg_doc_path" ]; then
            echo "headed-arm-leg: --consult: cannot resolve the consult doc path for $DOC" >&2
            exit 2
        fi
        if ! PROFILE_JSON="$(printf '%s' "$PROFILE_JSON" | jq --arg doc "$_leg_doc_path" --arg repo "$CONSULT_REPO_CANON" \
            '.permissions.deny = ((.permissions.deny // []) + ["Edit","Write","NotebookEdit"] | unique)
             | .permissions.allow = ["Bash(bash scripts/handover/console-kit/append-results.sh " + $doc + ":*)"]
             | del(.permissions.additionalDirectories)
             | .permissions.defaultMode = "auto"
             | .env = ((.env // {}) + {CLAUDE_CODE_SUBPROCESS_ENV_SCRUB: "0"})
             | .sandbox = {enabled: true, failIfUnavailable: true, allowUnsandboxedCommands: false,
                           autoAllowBashIfSandboxed: false,
                           filesystem: {allowWrite: [$doc], denyWrite: [$repo]}}')"; then
            echo "headed-arm-leg: --consult: cannot build the read-only envelope in settings JSON" >&2
            exit 2
        fi
    fi
    unset -v _leg_doc_path _leg_handover_dir_norm
    # (HIMMEL-2990) Native lane only - the claudex lane keeps its own
    # coordination preface untouched. Resolved even under --dry-run, same
    # reasoning as the profile/mcp resolution above: a jq failure here must
    # fail the same way either way.
    if [ "$LANE" != "claudex" ]; then
        # %q shell-quotes PROFILE_CONTRACT (log dir + leg name are caller
        # args, HIMMEL-2990 CR round 1): the generated command is re-parsed
        # by a DIFFERENT shell when the hook fires, so an unescaped quote or
        # $(...) in the path would break out of it.
        _leg_contract_cmd="$(printf 'cat %q' "$PROFILE_CONTRACT")"
        if ! PROFILE_JSON="$(printf '%s' "$PROFILE_JSON" | jq --arg cmd "$_leg_contract_cmd" \
            '.hooks.SessionStart = ((.hooks.SessionStart // []) + [{matcher:"compact", hooks:[{type:"command", command:$cmd, timeout:10}]}])')"; then
            echo "headed-arm-leg: --profile $PROFILE: cannot add compact-hook to settings JSON" >&2
            exit 2
        fi
    fi
    # The shim reads these; propagate so they survive both konsole's
    # `-e env -u ...` (Linux) and `open -a`'s fresh environment (macOS).
    # (#1334) The early scrub above already dropped any sibling-leg token/var
    # for this exact name, so this is a plain fresh add, never a clash.
    leg_propagate_env LEG_PROFILE_SETTINGS "$PROFILE_SETTINGS"
    # (HIMMEL-2985) Per-leg path, like PROFILE_SETTINGS above - the claudex
    # lane below overrides this to the same shape for its own coordination
    # preface; content is written only at real-launch time further down.
    LEG_PROFILE_PREFACE="$(dirname "$LOG")/$NAME.leg-preface.md"
    leg_propagate_env LEG_PROFILE_PREFACE "$LEG_PROFILE_PREFACE"
    export HEADED_ARM_LAUNCHER="$LEG_SHIM"
    # Lean SessionStart (HIMMEL-2830): the three advisory hooks go quiet. Only
    # the exact value 1 leans - the hooks are fail-open by construction.
    leg_propagate_env HIMMEL_LEAN_LEG 1
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
        leg_propagate_env LEG_PROFILE_MCP_CONFIG "$PROFILE_MCP_CONFIG"
    fi
fi

# HIMMEL-2953: every claudex leg gets its document-channel coordination
# rules, even without a profile. Claude accepts one preface file, so a
# profiled leg gets its own concatenation, with the lane override last.
if [ "$LANE" = "claudex" ]; then
    CLAUDEX_PREFACE="$HERE/../../../docs/handover/leg-preface-claudex.md"
    export HEADED_ARM_LAUNCHER="${HEADED_ARM_LEG_SHIM:-$HERE/../../lanes/leg-claude-launcher.sh}"
    leg_propagate_env LEG_CLAUDE_BIN "$CLAUDEX_BIN"
    for _leg_need in "$CLAUDEX_PREFACE" "$HEADED_ARM_LAUNCHER"; do
        if [ ! -f "$_leg_need" ]; then
            echo "headed-arm-leg: --lane claudex: required file missing: $_leg_need" >&2
            exit 2
        fi
    done
    if [ -n "$PROFILE" ]; then
        LEG_PROFILE_PREFACE="$(dirname "$LOG")/$NAME.leg-preface.md"
        leg_propagate_env LEG_PROFILE_PREFACE "$LEG_PROFILE_PREFACE"
    else
        LEG_PROFILE_PREFACE="$CLAUDEX_PREFACE"
        leg_propagate_env LEG_PROFILE_PREFACE "$LEG_PROFILE_PREFACE"
    fi
fi

if [ "$DRY_RUN" -eq 1 ]; then
    printf 'headed-arm-leg: would exec: %s %s %s %s %s %s %s %s\n' \
        "$HEADED_ARM" "$NAME" "$DOC" "$SIGNAL" "$DEADLINE" "$LOG" "$MODEL" "$CONTEXT"
    # HIMMEL-3139: scrub= and the resolved CONSOLE_CONTEXT are folded into this
    # existing unconditional line (rather than a new line) so the no-flag dry-run
    # report keeps its established line count - a caller can still set
    # CONSOLE_CONTEXT=1m and see it reported <unset> here, proving the scrub
    # above ran in THIS wrapper's own process before it ever execs into
    # headed-arm.sh.
    # HIMMEL-3133: ${VAR:-<unset>}, not a bare $VAR - a --judge dry-run never
    # exports IMPL_GUARD_OK/INLINE_IMPL_OK (see above) and this line must not
    # die on set -u the moment --judge is passed. A non-judge launch always
    # has both set to 1, so this stays byte-identical to before for every
    # existing caller.
    # HIMMEL-3141: CR_TRIGGER_SUPPRESS folded in the same way, for the same
    # reason - proves LEG_SUPPRESS_CR_TRIGGER->CR_TRIGGER_SUPPRESS ran in
    # THIS wrapper's own process, and stays <unset> (the default-ON case)
    # for every caller that never sets LEG_SUPPRESS_CR_TRIGGER.
    # HIMMEL-3435: HIMMEL_CONSOLE_NAME folded in the same way - proves the
    # three-source resolution above ran in THIS wrapper's own process, and
    # stays <unset> when no source yielded a well-formed name.
    printf 'headed-arm-leg: env IMPL_GUARD_OK=%s INLINE_IMPL_OK=%s HIMMEL_CONSOLE_LEG=%s HEADED_ARM_REPO=%s scrub=%s CONSOLE_CONTEXT=%s CR_TRIGGER_SUPPRESS=%s HANDOVER_DIR=%s HIMMEL_CONSOLE_NAME=%s\n' \
        "${IMPL_GUARD_OK:-<unset>}" "${INLINE_IMPL_OK:-<unset>}" "$HIMMEL_CONSOLE_LEG" "${HEADED_ARM_REPO:-<derived by headed-arm.sh>}" \
        "$LEG_ENV_SCRUB" "${CONSOLE_CONTEXT:-<unset>}" "${CR_TRIGGER_SUPPRESS:-<unset>}" "${HANDOVER_DIR:-<unset>}" "${HIMMEL_CONSOLE_NAME:-<unset>}"
    # Printed ONLY under --relay: with the flag omitted this line is absent and
    # the dry-run report stays byte-identical to today's, same guarantee shape
    # as the --profile line below.
    if [ "$RELAY" -eq 1 ]; then
        printf 'headed-arm-leg: relay=%s HIMMEL_CONSOLE_RELAY=%s LEG_EFFORT=%s\n' \
            "$RELAY" "$HIMMEL_CONSOLE_RELAY" "$LEG_EFFORT"
    fi
    # Printed ONLY under --judge, same guarantee shape as --relay above.
    # preface-source names the FILE that will be concatenated into the per-leg
    # preface (LEG_PROFILE_PREFACE, in the --profile line below, is the
    # generated per-leg copy - this is the one place the SOURCE choice is
    # directly observable in --dry-run).
    if [ "$JUDGE" -eq 1 ]; then
        printf 'headed-arm-leg: judge=%s read-clamp-lines=%s preface-source=%s\n' \
            "$JUDGE" "${HIMMEL_READ_CLAMP_LINES:-<unset>}" "$LEG_PREFACE"
    fi
    if [ "$CONSULT" -eq 1 ]; then
        printf 'headed-arm-leg: consult=%s read-clamp-lines=%s preface-source=%s\n' \
            "$CONSULT" "${HIMMEL_READ_CLAMP_LINES:-<unset>}" "$LEG_PREFACE"
    fi
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
        printf 'headed-arm-leg: profile=%s settings=%s preface=%s contract=%s lean=%s mcp=%s mcp-config=%s\n' \
            "$PROFILE" "$PROFILE_SETTINGS" "$LEG_PROFILE_PREFACE" "$PROFILE_CONTRACT" "$HIMMEL_LEAN_LEG" \
            "$MCP_NAMES_JSON" "${LEG_PROFILE_MCP_CONFIG:-<none>}"
    fi
    # Printed ONLY for an Opus/Fable model that cleared the tier gate above;
    # absent for Sonnet/Haiku, matching the argv-report guarantee pattern above.
    if [ -n "$TIER_GATE" ]; then
        printf 'headed-arm-leg: tier=%s tier-category=%s tier-reason=%s\n' "$TIER_GATE" "$TIER_CATEGORY" "$TIER_REASON"
    fi
    # Printed ONLY for a sanctioned 1m Context-line opt-in, same guarantee
    # shape as the Tier-gate line above.
    if [ -n "$CONTEXT_REASON" ]; then
        printf 'headed-arm-leg: context=1m (operator-ruling) context-reason=%s\n' "$CONTEXT_REASON"
    fi
    # Printed ONLY under --headless, same guarantee shape as --relay above.
    if [ "$HEADLESS" -eq 1 ]; then
        printf 'headed-arm-leg: headless=1 launch=%s --bg --permission-mode auto (env merged into %s at launch)\n' \
            "$HEADED_ARM_LAUNCHER" "$PROFILE_SETTINGS"
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
    else
        # (HIMMEL-2985/2990) Native lane: the leg preface stays the standing
        # rule set only. The brief's own contract (up to the Results tail) is
        # written to its own file and re-injected by a SessionStart compact
        # hook (added to PROFILE_JSON above) instead of riding every API call
        # in the preface. awk stops at the Results tail (or never, printing
        # the whole file) rather than mapfile, for bash 3.2 (macOS ships 3.2;
        # see the Platform guard above).
        if ! cat "$LEG_PREFACE" > "$LEG_PROFILE_PREFACE"; then
            echo "headed-arm-leg: --profile $PROFILE: cannot write preface to $LEG_PROFILE_PREFACE" >&2
            exit 2
        fi
        chmod 600 "$LEG_PROFILE_PREFACE" 2>/dev/null || true
        if ! awk '/^## Results/{exit} {print}' "$DOC" > "$PROFILE_CONTRACT"; then
            echo "headed-arm-leg: --profile $PROFILE: cannot write contract to $PROFILE_CONTRACT" >&2
            exit 2
        fi
        chmod 600 "$PROFILE_CONTRACT" 2>/dev/null || true
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
    # HIMMEL-2774: TTL from OUR OWN deadline plus a fixed grace period,
    # floored at 60s — a reservation must not outlive the arm attempt it
    # belongs to, but must also survive long enough to matter. codex-5 (this
    # round): for a FUTURE deadline, expiring the reservation exactly AT the
    # deadline leaves zero grace for the actual process spawn (scheduling
    # jitter, OS overhead) to complete and register in the live census —
    # another admission racing that gap sees the slot freed and can over-
    # admit the fleet right as this leg is coming up. The same +60s grace
    # also covers a near-past DEADLINE or clock skew, so the separate floor
    # below is now a belt-and-braces minimum rather than the only guard.
    _arm_fleet_ttl=$(( DEADLINE - $(date +%s) + 60 ))
    [ "$_arm_fleet_ttl" -ge 60 ] || _arm_fleet_ttl=60
    # HIMMEL-2789: this call launches a leg, so it declares launch intent —
    # the fleet cap must be able to actually refuse it, unlike a plain
    # bank-status READ.
    preflight_token="$(CADENCE_BANK_LEG="$NAME" CADENCE_BANK_LANE="$LANE" CADENCE_BANK_LAUNCH=1 CADENCE_BANK_CALLER_PID="$$" FLEET_RESERVE_TTL="$_arm_fleet_ttl" bash "$BANK_PREFLIGHT" 2>>"$LOG")"
    if [ "$preflight_token" = SKIPPED-FLEET ]; then
        # HIMMEL-2774: NOT a reservation release here — bank-preflight.sh
        # only ever returns SKIPPED-FLEET from its admission block itself
        # (lock failure, at/over-cap, or a DUPLICATE reservation name), and
        # none of those paths ever create a reservation for OUR call. The
        # duplicate case in particular is someone ELSE's still-pending
        # reservation for this same name — deleting it here would release a
        # slot out from under that other, still-live arm attempt.
        echo "$(date +%F_%T) headed-arm-leg: refusing to launch $NAME - fleet-size cap reached (bypass: FLEET_CAP_OK=1 in the LAUNCHING shell)" >> "$LOG"
        exit 10
    fi
    if [ "$preflight_token" = SKIPPED-BANK ]; then
        # HIMMEL-2774: SKIPPED-BANK is only reachable AFTER fleet admission
        # already succeeded and reserved a slot for $NAME (admission runs
        # before any bank check) — release it now since this attempt is not
        # going to launch after all, rather than leaving it to expire by TTL.
        _arm_fleet_slots="${HIMMEL_FLEET_SLOTS:-${XDG_RUNTIME_DIR:-/tmp}/himmel-fleet-$(id -u)}"
        # codex-3 (this round): the same admission-lock-failure bypass that
        # can reach here without ever creating OUR reservation (see the
        # comment above SKIPPED-FLEET) means a reservation already present
        # for $NAME may belong to an unrelated concurrent arm attempt —
        # verify pid ownership before deleting it out from under them.
        if [ "$(cat "${_arm_fleet_slots:?}/$NAME/pid" 2>/dev/null)" = "$$" ]; then
            rm -rf "${_arm_fleet_slots:?}/$NAME" 2>/dev/null
        fi
        echo "$(date +%F_%T) headed-arm-leg: refusing to launch $NAME - $LANE lane bank exhausted (park and retry later; see bank-preflight.sh for the parked lane's own bank status)" >> "$LOG"
        exit 11
    fi
fi

# HIMMEL-3267: a deliberate --no-profile launch looks exactly like a profiled
# one in headed-arm.sh's own log lines, so record the opt-out here.
if [ "$NO_PROFILE" -eq 1 ]; then
    echo "$(date +%F_%T) headed-arm-leg: WARN --no-profile: docs/handover/leg-preface.md NOT injected and no plugin profile applied (the brief must carry the preface)" >> "$LOG"
fi

# HIMMEL-2976: this wrapper execs into headed-arm.sh below, so its own
# "armed:" line (headed-arm.sh) never sees TIER_GATE - log the reason
# ourselves, same append style as the SKIPPED-FLEET/SKIPPED-BANK lines above.
if [ -n "$TIER_GATE" ]; then
    echo "$(date +%F_%T) headed-arm-leg: tier=$TIER_GATE tier-category=$TIER_CATEGORY tier-reason=$TIER_REASON" >> "$LOG"
fi
# HIMMEL-3581: same reasoning as the TIER_GATE line above - headed-arm.sh's
# own "armed:" line never sees CONTEXT_REASON, so log it ourselves.
if [ -n "$CONTEXT_REASON" ]; then
    echo "$(date +%F_%T) headed-arm-leg: context=1m (operator-ruling) context-reason=$CONTEXT_REASON" >> "$LOG"
fi

# HIMMEL-3270: record what this launch WAS, where a cohort query can find it
# after the fact. The launch-time facts (profile, role, model) are not
# recoverable from the transcript, so this is the only moment they exist.
# One appended line per real launch (never --dry-run) in the himmelctl cache
# dir, which uninstall already removes wholesale (scripts/install/
# uninstall-manifest.tsv, row himmelctl-cache). Launch metadata only - the
# fields below are the whole record; no env value and nothing from
# ~/.claude.json is ever read into it. Best-effort: a record that cannot be
# written is noted in $LOG and never stops the launch.
# ponytail: this records the launch ATTEMPT that reached the exec below;
# headed-arm.sh can still refuse it (duplicate session name, missing pin).
# A refused launch of a NEW name has no transcript, so a reader joining on
# the session name never counts it - but a refused DUPLICATE of a live
# session's name does match that session's transcript, and its line (which
# may carry a different profile) sits beside the original: the log is
# append-only and carries no attempt id, so the reader must not assume one
# line per session (it is not decided here - HIMMEL-3269 owns the reader).
# ponytail: with no HIMMELCTL_CACHE_DIR and no HOME nothing is written -
# falling back to /tmp would leave a file uninstall cannot find (HIMMEL-3260's
# accepted HOME-unset divergence, not repeated here).
_ll_cache="${HIMMELCTL_CACHE_DIR:-}"
[ -z "$_ll_cache" ] && [ -n "${HOME:-}" ] && _ll_cache="$HOME/.claude/himmel"
if [ -n "$_ll_cache" ]; then
    _ll_role=leg
    [ "$RELAY" -eq 1 ] && _ll_role=relay
    [ "$JUDGE" -eq 1 ] && _ll_role=judge
    [ "$CONSULT" -eq 1 ] && _ll_role=consult
    # HIMMEL-4014: a consult line also names the console that launched it; every other role's line
    # keeps its exact key set (the cost cohort reader and test 28c pin it).
    _ll_asker=""
    [ "$CONSULT" -eq 1 ] && _ll_asker=" console=${CONSOLE_FLAG:-unknown}"
    if ! ( umask 077 && mkdir -p "$_ll_cache/launch-logs" && \
        printf 'headed-arm-leg: profile=%s lane=%s model=%s role=%s session=%s launched=%s%s\n' \
            "${PROFILE:-none}" "$LANE" "${MODEL:-default}" "$_ll_role" "$NAME" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_ll_asker" \
            >> "$_ll_cache/launch-logs/$NAME.log" ) 2>/dev/null; then
        echo "$(date +%F_%T) headed-arm-leg: WARN launch record NOT written under $_ll_cache/launch-logs (the cost cohort cannot see this launch)" >> "$LOG"
    fi
fi

# HIMMEL-3403: the pid and session id of a headless leg exist only after
# headed-arm.sh launches it, so it appends them to the same durable record.
if [ "$HEADLESS" -eq 1 ] && [ -n "$_ll_cache" ]; then
    export HEADED_ARM_LAUNCH_RECORD="$_ll_cache/launch-logs/$NAME.log"
fi

exec "$HEADED_ARM" "$NAME" "$DOC" "$SIGNAL" "$DEADLINE" "$LOG" "$MODEL" "$CONTEXT"
