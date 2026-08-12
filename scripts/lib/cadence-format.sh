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
# v6 (HIMMEL-1309): the codex-sweep runner gained a THIRD payload leg
# (reap-superseded-fleets.ps1 -Kill, the duplicate-fleet-under-a-LIVE-broker
# check) and its trigger gained an intra-day <Repetition>. An armed v5 cadence
# still fires, but only the two old legs and only once a day — so the leak class
# this version exists to cover keeps accumulating unswept. Nudge `arm --force`.
# v7 (HIMMEL-1286): the generated cron runner takes a self-overlap lock before
# rotating its log and firing the payload. cron has no MultipleInstancesPolicy,
# so the POSIX leg was the unguarded one — and once `qmd-cadence.sh arm
# --ship-to` can point that runner at ship-index.sh, two overlapping runs race
# on the receiver's single `<target>.preship` rollback copy and can leave no
# recoverable index. An armed v6 cron runner keeps firing WITHOUT the lock, so
# an operator running the cadence on POSIX must `arm --force` to pick it up.
# Windows runners are unaffected (the scheduler already serialized them) but
# stamp v7 too, so one version answers "is this runner current".
# v8 (HIMMEL-1672): every emitted .bat prepends Git's usr\bin + bin to PATH so a
# NON-LOGIN bash.exe (the interpreter the Windows runners bake in) resolves GNU
# coreutils ahead of their System32 namesakes. A non-login Git-Bash does not
# source the MSYS profile that prepends /usr/bin, so it inherits the bare Windows
# PATH: unqualified `find` hits System32 find.exe (a string search), `timeout`
# hits timeout.exe (no GNU -k), and `sed`/`grep`/`date` are missing entirely —
# which silently broke the graphify refresh cadence for days. The Git root is
# DERIVED from the baked-in bash.exe path (cadence_git_bin_path_win), never
# hardcoded, so adopters who install Git outside C:\Program Files get the right
# path. An armed v7 runner keeps firing under the bare Windows PATH, so an
# operator must `arm --force` to pick up the prepend. Affects the bash-emitters
# (graphmap/qmd/pipeline); drift-fix (claude-direct) and codex-sweep (pwsh) bake
# no bash.exe into their runner and are unaffected. POSIX cron runners unaffected.
# shellcheck disable=SC2034  # consumed by sourcing scripts (pipeline-cadence/doctor/update)
CADENCE_RUNNER_FORMAT_VERSION=9

# Marker line stamped into each generated runner
# (.bat: `rem <marker> N`; .sh: `# <marker> N`).
CADENCE_FORMAT_MARKER="himmel-cadence-runner-format:"

# Basename registry for generated cadence runners. Keep explicit: a stray
# foreign *.bat/*.sh in a runner dir must not poison the staleness probe.
# shellcheck disable=SC2034  # consumed by cadence_runner_stamp callers/tests
CADENCE_RUNNER_BASENAMES="pipeline-harvest pipeline-synthesize pipeline-health codex-sweep graphmap-luna graphmap-himmel qmd-reindex drift-fix fork-resync"

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

# cadence_git_bin_path_win <bash_win>
# Derive the cmd-PATH fragment that puts Git's GNU coreutils ahead of System32
# for a NON-LOGIN bash.exe (HIMMEL-1672). A non-login Git-Bash does NOT source
# the MSYS profile that prepends /usr/bin, so it inherits the bare Windows PATH
# and unqualified `find`/`timeout`/`sed`/`grep` resolve to System32 namesakes
# (find.exe is a string search; timeout.exe lacks -k) or are missing entirely.
#
# <bash_win> is the Windows bash.exe path a runner already bakes in (resolved by
# the emitters as `cygpath -w "$(command -v bash)"`). The Git install root is
# DERIVED from it — never hardcoded — so adopters who install Git outside
# C:\Program Files get the right path. `command -v bash` under Git-Bash resolves
# to /usr/bin/bash -> <root>\usr\bin\bash.exe; Git for Windows also ships a
# wrapper at <root>\bin\bash.exe. Both layouts are handled (the usr arm is tested
# first so the bin arm never mis-trims it).
#
# Echoes "<root>\usr\bin;<root>\bin" (usr\bin FIRST) and returns 0. Echoes
# nothing for a path that is not a recognized Git-Bash layout (e.g. the WSL
# System32 stub) — the caller then emits no PATH line and the runner is no worse
# than before. bash 3.2-safe; the backslash idiom mirrors the trailing-separator
# strip in graphmap-cadence.sh's cmd_arm (`${var%\\}`).
cadence_git_bin_path_win() {
    local bash_win="$1" root
    case "$bash_win" in
        *\\usr\\bin\\bash.exe) root="${bash_win%\\usr\\bin\\bash.exe}" ;;
        *\\bin\\bash.exe)      root="${bash_win%\\bin\\bash.exe}" ;;
        *)                     return 0 ;;
    esac
    printf '%s\\usr\\bin;%s\\bin' "$root" "$root"
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
