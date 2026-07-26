#!/usr/bin/env bash
# cadence-format.sh — shared runner-format version + staleness probe for
# generated cadence runners (HIMMEL-588/HIMMEL-969).
#
# Cadence runners (.bat/.sh) are GENERATED artifacts, baked at arm time by the
# cadence emitters. They hard-code paths/payload config and are NOT regenerated
# when the himmel code changes. So an operator who armed BEFORE a runner-format
# change keeps firing stale runners with no nudge (this is exactly what bit
# HIMMEL-575: the --settings injection only took effect after a manual
# `arm --force`).
#
# This lib is the single source of truth: WRITERS stamp
# CADENCE_RUNNER_FORMAT_VERSION into every runner at arm time, and the READERS
# (himmel-doctor C8, himmel-update post-pull nudge) probe the stamp to detect
# stale armed cadences and point the operator at the matching `arm --force`.
#
# Sourced, not executed. bash 3.2-safe; no side effects.

# Bump when a runner/fragment format change requires an ALREADY-armed cadence to
# be re-armed (--force) to take effect. Runners armed before the stamp existed
# carry no marker and read as version 0 (stale). New users (first arm after a
# bump) get the current version automatically, so they never false-positive.
#
# v2 (HIMMEL-506): per-leg --model pins injected into every runner + the
# synthesize/health frequency shift (weekly→daily, monthly→weekly). An armed
# v1 cadence still fires, but on the OLD frequencies with NO model pin (so it
# inherits the operator's saved default tier) — nudge `arm --force`.
# v3 (HIMMEL-921): flow-run ledger start/end rows around each fired runner.
# v4 (HIMMEL-1036): the pipeline-cadence --settings fragment now carries an
# enabledPlugins block that force-enables obsidian-triage@himmel (the operator
# disables it interactively; the nightly cadence must re-enable it). An armed
# v3 cadence fires with the OLD fragment (no enabledPlugins), so once the
# interactive disable lands the pipeline runs with the plugin OFF — nudge
# `arm --force` to regenerate the fragment. Same class as the HIMMEL-575 bug
# noted at the top of this file.
# v5 (HIMMEL-1281): cadence_cmd_escape replaces the four per-emitter cmd_escape
# copies and drops their caret escaping of ^ & < > | (the " and % rules stay).
# Inside the double quotes every interpolated value sits in, `^` is LITERAL, so
# those carets corrupted the value instead of protecting it. An armed v4 runner
# keeps firing the corrupted form, so an operator whose bat dir / repo root /
# vault path carries one of those characters must `arm --force` to pick the fix
# up. Everyone else's regenerated runner is byte-identical bar the stamp.
# shellcheck disable=SC2034  # consumed by sourcing scripts (pipeline-cadence/doctor/update)
CADENCE_RUNNER_FORMAT_VERSION=5

# Marker line stamped into each generated runner
# (.bat: `rem <marker> N`; .sh: `# <marker> N`).
CADENCE_FORMAT_MARKER="himmel-cadence-runner-format:"

# Basename registry for generated cadence runners. Keep explicit: a stray
# foreign *.bat/*.sh in a runner dir must not poison the staleness probe.
# shellcheck disable=SC2034  # consumed by cadence_runner_stamp callers/tests
CADENCE_RUNNER_BASENAMES="pipeline-harvest pipeline-synthesize pipeline-health codex-sweep graphmap-luna graphmap-himmel qmd-reindex"

# cadence_user_home
# The runner homes the EMITTERS write under key off resolve_user_home
# (HIMMEL-645: on Windows Git-Bash $HOME can be the MSYS home while
# ~/.claude lives under the Windows profile — prefer USERPROFILE via
# cygpath). READERS must resolve the same way or they probe an empty MSYS
# dir and report "no armed cadence" on exactly the machines the Windows-only
# codex-sweep cadence runs on (HIMMEL-969 codex-adv finding). Same body as
# the emitters' resolve_user_home; kept here so the readers share one copy.
cadence_user_home() {
    if [ -n "${USERPROFILE:-}" ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -u "$USERPROFILE" 2>/dev/null || printf '%s' "$USERPROFILE"
    else
        printf '%s' "${HOME:-${USERPROFILE:-/tmp}}"
    fi
}

# cadence_cmd_escape <value>
# Escape a value for interpolation into a generated .bat, INSIDE DOUBLE QUOTES.
# That context is the whole contract (HIMMEL-1281) — every call site must emit
# the result as "%s", never bare. Two rules, and only two:
#
#   %  ->  %%   percent expansion DOES happen inside double quotes in a .bat,
#               so a literal % must be doubled or cmd eats `%X%` as a variable.
#               This one is complete: it makes any % safe.
#   "  ->  \"   carried over from the four copies this replaces. It is a
#               BEST EFFORT, not a guarantee: the receiving .exe parses \" as a
#               literal quote under MSVCRT argv rules, but cmd.exe itself
#               toggles quoting on every " regardless of backslashes, so an
#               embedded quote still shifts where cmd sees the quoted run end.
#               arm-resume.sh reaches the same conclusion and REFUSES such a
#               payload outright. It does not bite here because the values are
#               Windows paths (" is illegal in a path component) plus the
#               operator's own cadence prompts. Do not extend this function to
#               a value that can carry an arbitrary quote — refuse instead.
#
# What is deliberately NOT escaped: ^ & < > |. Inside double quotes cmd.exe
# already treats & < > | as literal data, and `^` is not an escape character
# there at all — it is literal. Caret-escaping them does not protect anything;
# it CORRUPTS the value. `C:\some&dir\bash.exe` emitted as "C:\some^&dir\..."
# hands the child a path that does not exist. (The four per-emitter copies this
# replaces all made exactly that mistake.)
#
# The quoting itself is what makes the value safe: a path can carry & < > | and
# still not inject, because cmd never re-parses inside the quotes.
cadence_cmd_escape() {
    local s="$1"
    s="${s//\"/\\\"}"
    s="${s//%/%%}"
    printf '%s' "$s"
}

# cadence_runner_stamp <bat_dir>
# Echo the MINIMUM format version stamped across the runners under <bat_dir>
# (an unstamped runner reads as 0 — i.e. armed before HIMMEL-588). Minimum,
# not first-found: a multi-runner re-arm interrupted between writes leaves a
# mixed set, and one current runner must not mask a stale sibling
# (HIMMEL-969 codex-adv finding). Return:
#   0 — at least one runner present (version echoed on stdout)
#   1 — no runners present (cadence not armed via this dir)
cadence_runner_stamp() {
    local dir="$1" name ext f ver min=""
    for name in $CADENCE_RUNNER_BASENAMES; do
        for ext in bat sh; do
            f="$dir/$name.$ext"
            [ -f "$f" ] || continue
            ver="$(grep -oE "${CADENCE_FORMAT_MARKER}[[:space:]]*[0-9]+" "$f" 2>/dev/null \
                | head -1 | grep -oE '[0-9]+$' || true)"
            [ -n "$ver" ] || ver=0
            if [ -z "$min" ] || [ "$ver" -lt "$min" ]; then
                min="$ver"
            fi
        done
    done
    [ -n "$min" ] || return 1
    printf '%s' "$min"
    return 0
}
