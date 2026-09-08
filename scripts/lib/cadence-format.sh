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
# v9 (HIMMEL-1706): the codex-sweep .bat preserves every payload rc and exits
# non-zero after all three legs when any leg failed. An armed v8 runner logs a
# refusing sweep but returns the final successful leg's rc to Task Scheduler,
# leaving LastTaskResult=0 while the primary sweep accomplished nothing. Re-arm
# with `codex-sweep-cadence.sh arm --force` to regenerate the runner.
# v10 (HIMMEL-1753): every generated task's Exec is now a hidden powershell.exe
# wrapper (`-WindowStyle Hidden -Command "& '<bat>'; exit $LASTEXITCODE"`)
# around the .bat, not the bare .bat. A bare .bat Exec pops a visible conhost
# window on every fire — an operator repro caught it flashing on top of a
# fullscreen game, and an uncontrolled console flash would contaminate the
# upcoming LUNA-131 focus soak. This is a REGISTERED-TASK-shape change, not a
# runner-content change: the .bat emitters and their rc logic are untouched, so
# an armed v9 task keeps firing its OLD bare-.bat Exec (still correct, still
# visible) until re-armed. `; exit $LASTEXITCODE` in the new wrapper preserves
# the v9 exit-code fidelity — re-arming does not regress it. Re-arm with
# `<cadence>.sh arm --force` to pick up the hidden-window Exec.
# v11 (HIMMEL-1753): the v10 hidden-powershell wrapper was MEASURED to still
# allocate visible consoles despite -WindowStyle Hidden, so the Exec shape moves
# again — now a `wscript.exe //B <shim>.vbs` whose .vbs runs the .bat hidden via
# WScript.Shell.Run(..., 0, True) and forwards its exit code through WScript.Quit
# (zero console allocation; rc=42 re-arm passthrough proven by an execution test
# in test-cadence-format.sh). The emitted .bat ALSO gained non-interactive-editor
# `set` lines (GIT_EDITOR/EDITOR/VISUAL=true, GH_PROMPT_DISABLED=1) so a cadence
# child can never block on an editor prompt — a runner-CONTENT change as well as
# a task-shape one. An armed v10 task keeps firing its powershell-Hidden Exec
# (still correct, still pops the measured-hidden consoles) until re-armed; the
# .bat rc logic is again untouched, and WScript.Quit preserves the v9/v10
# exit-code fidelity. Re-arm with `<cadence>.sh arm --force` to pick up the
# wscript shim + the editor-hardened .bat.
# v13 (HIMMEL-1724 + HIMMEL-1389): two runner-CONTENT changes. (a) the
# pipeline FetchHealth leg (.bat and cron runner) now writes flow-run ledger
# start/end rows like every other leg — an armed v12 runner keeps firing with
# NO ledger row, so that leg stays invisible to stall / never-started
# detection and "stopped firing" is indistinguishable from "never armed".
# (b) every emitter prefixes its shim-resolvable payload invocation with
# `call` (the #1454 fix, carried to the pipeline claude line, the fetch-health
# python line, codex-sweep's three pwsh legs and graphmap's payload): without
# it, a payload that resolves to a .cmd/.bat shim makes cmd.exe transfer
# control away for good, so the rc stamp, the ledger end row and the `exit /b`
# after it never run. Re-arm each cadence with `arm --force` to pick both up.
# v14 (HIMMEL-1152): the three pipeline CLAUDE legs (.bat and cron runner) wrap
# their claude invocation in a bounded retry/resume loop — up to 3 attempts,
# 60s then 180s backoff, and ONLY when the attempt's own log carries the
# transient upstream signature (`API Error: … Server error / overloaded / 5xx /
# mid-response`); every attempt lands its own flow-run ledger row pair tagged
# `attempt=N/3`. An armed v13 runner keeps firing with NO retry, so a leg that
# dies on a transient API error (the 2026-07-17 harvest, 48 minutes in, 7 clips
# already harvested) still just sits unfinished until a human notices. Re-arm
# with `pipeline-cadence.sh arm --force`. The other cadences are unaffected but
# stamp v14 too, so one version answers "is this runner current".
# v15 (HIMMEL-2044/2045): the three pipeline CLAUDE legs gate before they spend.
# Every one of them now runs scripts/lib/bank-preflight.sh first (with
# CADENCE_BANK_LEG set, so ~/.himmel/cadence-ledger.jsonl finally attributes the
# spend instead of logging leg:"unknown") and passes an explicit
# --permission-mode; the synthesize leg additionally runs the free
# scripts/luna/synth-input-check.sh and skips the session outright on a night
# with no newly triaged clips. A v14 runner has NO bank guard at all — it is the
# shape the 2026-08-23 cadence audit found spending the subscription bank
# unconditionally every night — so re-arm with
# `pipeline-cadence.sh arm --force`. The other cadences are unaffected but stamp
# v15 too, so one version still answers "is this runner current".
# v16 (HIMMEL-2367): a new runner joins the stamped set — upstream-watch, the
# daily delta-gated scan of open upstream PRs/issues (replacing the resident
# 20-minute interactive-claude poller per the 2026-09-01 operator ruling). It
# fires a plain shell script (never claude), so there is nothing for a v15
# runner to have missed and no re-arm is needed for existing cadences; this
# bump exists only to add "upstream-watch" to CADENCE_RUNNER_BASENAMES below so
# its own runner participates in the same staleness-stamp convention.
# shellcheck disable=SC2034  # consumed by sourcing scripts (pipeline-cadence/doctor/update)
CADENCE_RUNNER_FORMAT_VERSION=16

# Marker line stamped into each generated runner
# (.bat: `rem <marker> N`; .sh: `# <marker> N`).
CADENCE_FORMAT_MARKER="himmel-cadence-runner-format:"

# Basename registry for generated cadence runners. Keep explicit: a stray
# foreign *.bat/*.sh in a runner dir must not poison the staleness probe.
# shellcheck disable=SC2034  # consumed by cadence_runner_stamp callers/tests
CADENCE_RUNNER_BASENAMES="pipeline-harvest pipeline-synthesize pipeline-health codex-sweep graphmap-luna graphmap-himmel qmd-reindex drift-fix fork-resync graphify-update-ggs upstream-watch"

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

# cadence_vbs_path <bat_win>
# Derive the .vbs shim path from a .bat runner path: same directory + basename,
# .vbs extension (HIMMEL-1753). The wscript //B shim lives BESIDE its .bat so a
# disarm that removes the .bat removes its shim too, and so the writer (cmd_arm)
# and the referencer (emit_task_xml) — both deriving through this helper — can
# never disagree about where the shim lives. <bat_win> is a Windows path.
cadence_vbs_path() {
    printf '%s' "${1%.bat}.vbs"
}

# cadence_vbs_wrapper <bat_win>
# Emit the body of the .vbs shim that hosts the .bat under wscript //B
# (HIMMEL-1753). This replaces the superseded pwsh -WindowStyle Hidden wrapper:
# that shape was MEASURED to still allocate visible consoles despite Hidden,
# while wscript //B hosting this shim allocates zero (wscript.exe is a
# windowless host; the .bat's cmd.exe console is launched with SW_HIDE).
#
# WScript.Shell.Run(cmd, 0, True) launches <bat_win> with a HIDDEN window
# (intWindowStyle=0), WAITS for it, and RETURNS its exit code; WScript.Quit
# propagates that code as the wscript.exe process exit code, preserving the
# HIMMEL-1706 exit-code fidelity contract. The command string includes literal
# quotes around <bat_win>, so runner paths with spaces execute as one command.
# rc=42 (the harness re-arm signal) survives — proven by an execution test in
# test-cadence-format.sh that runs a 42-exit .bat through this exact shim and
# asserts cscript's exit code.
#
# <bat_win> is a Windows path; a literal " in it (illegal in a path component,
# but defended anyway) is doubled per VBScript string-literal rules. ASCII-only:
# VBScript source is parsed under the OEM codepage where UTF-8 punctuation
# mojibakes (same constraint as the .bat emitter).
cadence_vbs_wrapper() {
    local bat_win="$1" bat_quoted
    bat_quoted="${bat_win//\"/\"\"}"
    printf '%s\r\n' "' himmel cadence wrapper (HIMMEL-1753) - generated DO NOT EDIT; runs the .bat hidden, returns its exit code."
    printf '%s\r\n' 'Set sh = CreateObject("WScript.Shell")'
    printf 'WScript.Quit sh.Run("""%s""", 0, True)\r\n' "$bat_quoted"
}

# Shared Windows Script Host availability predicate (HIMMEL-1793). Every
# Windows cadence Exec is `wscript.exe //B <shim>.vbs`, so a registered task is
# dead when wscript is missing, policy-disabled, or unable to execute even a
# zero-exit script. Keep the predicate here: five emitters share the dependency
# and must not grow five policy readers that drift.
#
# Policy precedence follows Windows Script Host: HKCU overrides HKLM; an absent
# Enabled value means no override at that scope (and both absent means enabled).
# Both hives are read through PowerShell PSDrive paths, never raw
# HKEY_LOCAL_MACHINE strings. The final smoke probe runs the exact windowless
# host the tasks use. Results are cached for the process so multi-task status
# commands probe once, not once per task.
#
# Test seams:
#   CADENCE_WSCRIPT_BIN       executable to smoke-probe (default wscript.exe)
#   CADENCE_WSH_POWERSHELL    PowerShell executable used for registry reads
CADENCE_WSH_CHECKED=0
CADENCE_WSH_AVAILABLE=0
CADENCE_WSH_DETAIL=""

_cadence_wsh_policy_value() {
    local powershell_bin="$1" hive="$2" registry_path out rc=0
    registry_path="${hive}:\\SOFTWARE\\Microsoft\\Windows Script Host\\Settings"
    out=$("$powershell_bin" -NoProfile -NonInteractive -Command "
        try {
            \$value = (Get-ItemProperty -LiteralPath '$registry_path' -Name Enabled -ErrorAction Stop).Enabled
            Write-Output ('VALUE:' + [string]\$value)
        } catch [System.Management.Automation.ItemNotFoundException] {
            Write-Output 'ABSENT'
        } catch [System.Management.Automation.PSArgumentException] {
            Write-Output 'ABSENT'
        } catch {
            Write-Error \$_
            exit 2
        }
    " 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
        printf '%s' "$out"
        return 2
    fi
    printf '%s' "$out" | tr -d '\r\n '
}

cadence_wsh_probe() {
    if [ "$CADENCE_WSH_CHECKED" -eq 1 ]; then
        [ "$CADENCE_WSH_AVAILABLE" -eq 1 ]
        return
    fi
    CADENCE_WSH_CHECKED=1

    local wscript_name="${CADENCE_WSCRIPT_BIN:-wscript.exe}" wscript_bin
    local powershell_name="${CADENCE_WSH_POWERSHELL:-}" powershell_bin
    local hklm hkcu effective source value
    local probe_file probe_arg probe_rc=0

    if ! wscript_bin=$(command -v "$wscript_name" 2>/dev/null); then
        CADENCE_WSH_DETAIL="'$wscript_name' is not on PATH"
        return 1
    fi

    if [ -n "$powershell_name" ]; then
        if ! powershell_bin=$(command -v "$powershell_name" 2>/dev/null); then
            CADENCE_WSH_DETAIL="registry probe executable '$powershell_name' is not available"
            return 1
        fi
    elif powershell_bin=$(command -v pwsh 2>/dev/null); then
        :
    elif powershell_bin=$(command -v pwsh.exe 2>/dev/null); then
        :
    elif powershell_bin=$(command -v powershell.exe 2>/dev/null); then
        # HIMMEL-2126: pwsh is unavailable — loud, named 5.1 fallback, never silent.
        echo "WARN cadence_wsh_probe: pwsh (PowerShell 7) not found; falling back to Windows PowerShell 5.1 (powershell.exe) -- HIMMEL-2126: PS 5.1 misreads BOM-less UTF-8 as cp1252 (em-dash mojibake -> phantom-token ParserError at the WRONG line), has reserved-variable quirks, and strips jq-style quoting differently than pwsh." >&2
    else
        CADENCE_WSH_DETAIL="PowerShell is unavailable, so WSH policy cannot be verified"
        return 1
    fi

    if ! hklm=$(_cadence_wsh_policy_value "$powershell_bin" HKLM); then
        CADENCE_WSH_DETAIL="HKLM WSH policy read failed: ${hklm:-no diagnostic}"
        return 1
    fi
    if ! hkcu=$(_cadence_wsh_policy_value "$powershell_bin" HKCU); then
        CADENCE_WSH_DETAIL="HKCU WSH policy read failed: ${hkcu:-no diagnostic}"
        return 1
    fi
    case "$hklm:$hkcu" in
        ABSENT:ABSENT|ABSENT:VALUE:*|VALUE:*:ABSENT|VALUE:*:VALUE:*) : ;;
        *)
            CADENCE_WSH_DETAIL="WSH policy probe returned an unrecognized answer (HKLM=$hklm, HKCU=$hkcu)"
            return 1
            ;;
    esac

    effective="$hkcu"
    source="HKCU"
    if [ "$effective" = "ABSENT" ]; then
        effective="$hklm"
        source="HKLM"
    fi
    if [ "$effective" != "ABSENT" ]; then
        value="${effective#VALUE:}"
        case "$value" in
            ""|*[!0-9]*)
                CADENCE_WSH_DETAIL="$source WSH Enabled value is not numeric: $value"
                return 1
                ;;
        esac
        if [ "$value" -eq 0 ]; then
            CADENCE_WSH_DETAIL="Windows Script Host is disabled by $source policy (Enabled=0)"
            return 1
        fi
    fi

    if ! probe_file=$(mktemp -t himmel-wsh-preflight.XXXXXX.vbs); then
        CADENCE_WSH_DETAIL="could not create the temporary WSH smoke probe"
        return 1
    fi
    if ! printf 'WScript.Quit 0\r\n' > "$probe_file"; then
        rm -f "$probe_file"
        CADENCE_WSH_DETAIL="could not write the temporary WSH smoke probe"
        return 1
    fi
    probe_arg="$probe_file"
    if command -v cygpath >/dev/null 2>&1; then
        if ! probe_arg=$(cygpath -w "$probe_file" 2>/dev/null); then
            rm -f "$probe_file"
            CADENCE_WSH_DETAIL="cygpath could not convert the temporary WSH smoke probe path"
            return 1
        fi
    fi
    MSYS_NO_PATHCONV=1 "$wscript_bin" //B //NoLogo "$probe_arg" >/dev/null 2>&1 || probe_rc=$?
    rm -f "$probe_file"
    if [ "$probe_rc" -ne 0 ]; then
        CADENCE_WSH_DETAIL="'$wscript_name //B' could not execute a zero-exit .vbs (rc=$probe_rc)"
        return 1
    fi

    CADENCE_WSH_AVAILABLE=1
    CADENCE_WSH_DETAIL="available"
    return 0
}

cadence_require_wsh() {
    local caller="$1"
    if cadence_wsh_probe; then
        return 0
    fi
    echo "ERR $caller: Windows Script Host runner is unavailable — $CADENCE_WSH_DETAIL." >&2
    echo "    Refusing to arm scheduled tasks whose wscript.exe //B runner cannot execute." >&2
    return 2
}

# cadence_registered_status <task-name> <suffix>
# Report a registered Windows task as ARMED only when its shared wscript runner
# passes the executable preflight. rc 2 marks registered-but-unexecutable as a
# health failure while preserving the caller's task-specific suffix.
cadence_registered_status() {
    local name="$1" suffix="${2:-}"
    if cadence_wsh_probe; then
        printf 'ARMED      %s%s\n' "$name" "$suffix"
        return 0
    fi
    printf 'UNHEALTHY  %s (registered; runner unavailable: %s)%s\n' "$name" "$CADENCE_WSH_DETAIL" "$suffix"
    return 2
}

# cadence_bat_editor_set
# Emit the non-interactive-editor `set` lines every generated .bat stamps near
# its top (HIMMEL-1753). A cadence child runs under schtasks with stdin closed,
# so it can never answer an interactive editor/prompt; any tool falling back to
# $EDITOR would otherwise open a window on the operator's desktop and block
# forever behind it. Pinning every editor hook to the no-op `true` (and
# disabling gh's prompt) turns that silent hang into a fast, loud failure.
# Mirrors scripts/telegram/run.ts NON_INTERACTIVE_EDITOR_ENV, but in the raw
# .bat so the hardening holds even without the sessionEnv merge. ASCII-only,
# CRLF-terminated, quoted `set` form (quoted-context safe per cadence_cmd_escape).
cadence_bat_editor_set() {
    printf 'set "GIT_EDITOR=true"\r\n'
    printf 'set "EDITOR=true"\r\n'
    printf 'set "VISUAL=true"\r\n'
    printf 'set "GH_PROMPT_DISABLED=1"\r\n'
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
