#!/usr/bin/env bash
# scripts/lib/chokepoint-seam-guard.sh - refuse a registered chokepoint seam
# that differs from the Claude Code session's LAUNCH environment (HIMMEL-3914).
# Sourced, never run, near the top of every chokepoint in scripts/chokepoints.json:
#
#   case "${BASH_SOURCE[0]}" in */*) _csg_dir="${BASH_SOURCE[0]%/*}" ;; *) _csg_dir=. ;; esac
#   _csg_lib="$_csg_dir/<rel>/lib/chokepoint-seam-guard.sh"   # never PATH's dirname
#   if ! { [ -r "$_csg_lib" ] && . "$_csg_lib"; }; then echo ... >&2; exit 96; fi
#   chokepoint_seam_guard <registry key>
#
# WHY: block-chokepoint-env-prefix.sh reads the command TEXT, so a seam
# assignment whose chokepoint path or seam name is obfuscated (glob, brace,
# ANSI-C, `${p}er.sh`, `export "$n=1"`, `read`, `printf -v`, `env -u`) gets
# past it. Every one of those spellings ends in the same state: the seam in the
# chokepoint's own environment differs from what the session was launched with.
# This guard compares that state, so the spelling stops mattering.
#
# Baseline = the OUTERMOST ancestor whose exe basename or argv[0] basename is
# `claude`: its /proc/<pid>/environ is the kernel's exec-time copy, which a
# descendant cannot rewrite (needs ptrace of an ancestor; yama ptrace_scope>=1).
# Outermost, not nearest: a nested fake `claude` carrying a forged env is not
# its own ancestor. Only exe/argv[0] basenames match, never another argv word
# (konsole's argv carrying `claude` is not claude).
#
# Settings overlay: Claude Code applies a settings-file `env` block to its tool
# subprocesses in-process, so it never reaches /proc environ. Per
# https://code.claude.com/docs/en/settings ("Settings precedence": managed >
# --settings > .claude/settings.local.json > .claude/settings.json >
# ~/.claude/settings.json; "An env block inside a settings file is an ordinary
# key and follows the levels above") and the settings-reference `env` entry
# (a variable exported in the launching shell wins over an env block), the
# effective value of a seam is: environ if set there, else the highest level
# that sets it. The overlay reads ONLY levels block-edit-live-settings.sh
# guards against the session's own Write/Edit and Bash writes (console ruling
# on HIMMEL-3914): <cwd>/.claude/settings.local.json and settings.json when the
# session's cwd IS the anchor (Claude Code reads project files from its primary
# working directory), then $HOME/.claude/settings.json. EXCLUDED: managed
# settings (not under the hook), the `--settings` file (a session-writable
# scratchpad file - overlaying it would re-open the per-call bypass), and
# ~/.claude when CLAUDE_CONFIG_DIR moves it (the hook guards $HOME/.claude).
# A seam set only by an excluded level therefore DENIES.
#
# Enforced only on the ANCHOR copy (this file's tree is the realpath of the
# baseline HIMMEL_REPO, or the primary checkout of the claude cwd's repo).
# Worktree and fixture copies are branch bytes a leg can run anyway, so a seam
# there adds no capability - that is what keeps every test suite working.
#
# Anchor: the baseline's HIMMEL_REPO, else HIMMEL_REPO from the guarded user
# settings file (an operator session whose cwd is luna or salus), else the
# primary checkout of the claude cwd's repo - or, under a daemon, whose cwd is
# only its spawner's, this copy's own primary. The project settings files need no
# step of their own: they are read only when the cwd IS the anchor, which the
# cwd step already yields.
#
# Headless (--bg) legs: the outermost claude ancestor is the `claude daemon
# run` service, whose environ is the daemon spawner's, and the leg's own env
# rides only in the excluded --settings file. So a seam a headless leg passes
# to a chokepoint always differs, and the guard refuses with a headless-specific
# message - headless legs cannot pass seams to chokepoints (console ruling on
# HIMMEL-3914; HIMMEL-3930 tracks a proper headless design).
#
# No claude ancestor (CI, a detached at/setsid launch, a daemon not
# recognised): allowed, UNLESS this is the anchor copy, this process's
# exec-time environ carries a Claude Code marker (CLAUDECODE, CLAUDE_CODE_*,
# HIMMEL_CONSOLE_LEG) AND one of the chokepoint's registered seams is set - a
# session that lost its ancestry cannot use that to pass a seam. An at job
# armed from a session carries the markers (at snapshots the env) but no seam,
# so it still runs.
#
# Fails CLOSED (exit 96) once enforcement applies: a walk error, an unreadable
# or empty environ, an unreadable registry entry, or any seam mismatch. The
# only allows are "no /proc" and "no claude ancestor" outside the marker rule.
# ponytail: R1 a detached launch with no Claude Code marker in its env (env -i,
# systemd-run, cron) and no claude ancestor is allowed; R2 a fresh `claude`
# launched with a forged env is indistinguishable from a legit launch; R3
# macOS/Git Bash (no /proc) keeps the unchanged hook-only posture - no guard
# runs there; R4 an operator (or an obfuscated Bash write the hook's text scan
# misses) editing a guarded settings file changes the baseline; R5 external
# tools come from fixed system dirs, but bash itself still honours inherited
# state before this lib runs: an exported BASH_FUNC_* shadowing a builtin
# (printf, read, [), BASH_ENV sourced at startup, SHELLOPTS/BASHOPTS turning on
# options, and an extdebug DEBUG trap - HIMMEL-3921 tracks the text-level (a)
# layer for R1/R3/R5.

CSG_DENY_RC=96

# _csg_bin <tool> - print the tool's path from the fixed system dirs, never
# PATH: a PATH-shadowed (or exported-function) jq/git/readlink could forge an
# empty seam list or a foreign anchor, and a curated PATH must not break it.
_csg_bin() {
    local d
    for d in /usr/bin /bin /usr/local/bin; do
        if [ -x "$d/$1" ]; then printf '%s' "$d/$1"; return 0; fi
    done
    printf '%s' "/nonexistent/$1"
    return 1
}

# _csg_env_get <nul-separated-environ-file> <name> - print the value; rc 0 set, 1 unset.
_csg_env_get() {
    local kv
    while IFS= read -r -d '' kv; do
        case "$kv" in
            "$2="*) printf '%s' "${kv#*=}"; return 0 ;;
        esac
    done < "$1"
    return 1
}

# _csg_settings_get <settings.json> <name> - print env[name]; rc 0 set, 1 unset
# (missing file, bad JSON or no such key all read as unset, which can only
# make a differing seam DENY).
_csg_settings_get() {
    local out
    [ -r "$1" ] || return 1
    # shellcheck disable=SC2016 # a jq program, not shell
    out=$("$(_csg_bin jq)" -j --arg n "$2" 'if (.env|type)=="object" and (.env|has($n)) then "1" + (.env[$n]|tostring) else "0" end' "$1" 2>/dev/null; printf x)
    case "$out" in
        1*) out="${out#1}"; printf '%s' "${out%x}"; return 0 ;;
    esac
    return 1
}

# _csg_verdict <environ-file> <anchor> <root> "<seam ...>" [settings-file ...]
# Settings files are given highest precedence first. Prints each mismatched
# seam NAME (never a value), one per line.
# rc 0 allow, 1 mismatch, 2 baseline unreadable or empty.
_csg_verdict() {
    local base="$1" anchor="$2" root="$3" seams="$4" kv n=0 seam bset bval sf v rc=0
    shift 4
    [ -n "$anchor" ] && [ -n "$root" ] || return 0
    [ "$root" -ef "$anchor" ] || return 0
    [ -r "$base" ] || return 2
    while IFS= read -r -d '' kv; do n=$((n + 1)); done < "$base"
    [ "$n" -gt 0 ] || return 2
    for seam in $seams; do
        case "$seam" in
            [A-Za-z_]*) ;;
            *) printf '%s\n' "$seam"; rc=1; continue ;;
        esac
        case "$seam" in
            *[!A-Za-z0-9_]*) printf '%s\n' "$seam"; rc=1; continue ;;
        esac
        # The trailing x keeps a value's trailing newlines through $(...).
        bset=0; bval=""
        if v=$(_csg_env_get "$base" "$seam"; r=$?; printf x; exit "$r"); then
            bset=1; bval="${v%x}"
        else
            for sf in "$@"; do
                if v=$(_csg_settings_get "$sf" "$seam"; r=$?; printf x; exit "$r"); then
                    bset=1; bval="${v%x}"; break
                fi
            done
        fi
        if [ -n "${!seam+x}" ]; then
            if [ "$bset" -eq 0 ] || [ "${!seam}" != "$bval" ]; then
                printf '%s\n' "$seam"; rc=1
            fi
        elif [ "$bset" -eq 1 ]; then
            printf '%s\n' "$seam"; rc=1
        fi
    done
    return "$rc"
}

# _csg_is_claude <proc-root> <pid> - rc 0 when exe or argv[0] basename is
# `claude`, the exe is a native install's versioned binary
# (.../claude/versions/<v>, whose comm and argv[0] can be the version string),
# or a node process runs @anthropic-ai/claude-code's cli (npm install).
_csg_is_claude() {
    local exe a0="" a1=""
    exe=$("$(_csg_bin readlink)" "$1/$2/exe" 2>/dev/null) || exe=""
    [ "${exe##*/}" = claude ] && return 0
    case "$exe" in
        */claude/versions/*) return 0 ;;
    esac
    if [ -r "$1/$2/cmdline" ]; then
        { IFS= read -r -d '' a0; IFS= read -r -d '' a1; } < "$1/$2/cmdline" || true
    fi
    [ -n "$a0" ] && [ "${a0##*/}" = claude ] && return 0
    case "${a0##*/}|$a1" in
        node\|*/@anthropic-ai/claude-code/cli.js | node\|*/@anthropic-ai/claude-code/cli.mjs) return 0 ;;
    esac
    return 1
}

# _csg_is_bg_service <proc-root> <pid> - rc 0 when a claude pid is the background
# service: the subcommand `daemon run` right after the program - argv[1..2]
# for a native install (argv[0] may be the versioned binary, so argv[0] is not
# checked), argv[2..3] behind `node <cli.js>` for an npm install. Fixed
# positions, so a prompt or a later argv word reading "daemon run" is not it.
# A daemon this misses is still the outermost claude, so its seams still
# refuse; only the message is the generic one.
_csg_is_bg_service() {
    local a0="" a1="" a2="" a3=""
    [ -r "$1/$2/cmdline" ] || return 1
    { IFS= read -r -d '' a0; IFS= read -r -d '' a1; IFS= read -r -d '' a2; IFS= read -r -d '' a3; } < "$1/$2/cmdline" || true
    [ "$a1" = daemon ] && [ "$a2" = run ] && return 0 # t13b-ok: matches an existing claude service argv, starts nothing
    [ "${a0##*/}" = node ] && [ "$a2" = daemon ] && [ "$a3" = run ] && return 0 # t13b-ok: matches an existing claude service argv, starts nothing
    return 1
}

# _csg_has_marker <nul-separated-environ-file> - rc 0 when the environ carries
# a non-empty Claude Code marker: CLAUDECODE, any CLAUDE_CODE_*, or
# HIMMEL_CONSOLE_LEG.
_csg_has_marker() {
    local kv
    [ -r "$1" ] || return 1
    while IFS= read -r -d '' kv; do
        case "$kv" in
            CLAUDECODE=?* | CLAUDE_CODE_*=?* | HIMMEL_CONSOLE_LEG=?*) return 0 ;;
        esac
    done < "$1"
    return 1
}

# _csg_find_outermost <proc-root> <start-pid> - print the outermost claude
# ancestor pid (nothing when none); rc 0 walked cleanly, 2 walk error.
_csg_find_outermost() {
    local proc="$1" pid="$2" found="" stat rest ppid i=0
    case "$pid" in
        '' | *[!0-9]*) return 2 ;;
    esac
    while [ "$pid" -gt 0 ]; do
        i=$((i + 1))
        [ "$i" -le 4096 ] || return 2
        stat=""
        [ -r "$proc/$pid/stat" ] || return 2
        IFS= read -r stat < "$proc/$pid/stat" || [ -n "$stat" ] || return 2
        if _csg_is_claude "$proc" "$pid"; then found="$pid"; fi
        # comm may hold spaces or parens: the fields after the LAST ") ".
        rest="${stat##*) }"
        [ "$rest" != "$stat" ] || return 2
        ppid=""
        read -r _ ppid _ <<EOF
$rest
EOF
        case "$ppid" in
            '' | *[!0-9]*) return 2 ;;
        esac
        [ "$ppid" != "$pid" ] || return 2
        pid="$ppid"
    done
    printf '%s' "$found"
    return 0
}

# _csg_registry_seams <chokepoints.json> <key> - print the key's enforced seams
# (seam_env_vars minus internal_seams), space-joined; rc!=0 when unreadable or
# the key is absent.
_csg_registry_seams() {
    # shellcheck disable=SC2016 # a jq program, not shell
    "$(_csg_bin jq)" -er --arg k "$2" '.[$k] | select(. != null) | ((.seam_env_vars // []) - (.internal_seams // [])) | join(" ")' "$1" 2>/dev/null
}

# _csg_overlay_files <claude-cwd> <anchor> <environ-file> - print the settings
# files to overlay, highest precedence first, one per line. Never the
# `--settings` file (see the header).
_csg_overlay_files() {
    local home
    if [ "$1" -ef "$2" ]; then
        printf '%s\n' "$1/.claude/settings.local.json" "$1/.claude/settings.json"
    fi
    _csg_env_get "$3" CLAUDE_CONFIG_DIR >/dev/null && return 0
    if home=$(_csg_env_get "$3" HOME); then
        printf '%s\n' "$home/.claude/settings.json"
    fi
    return 0
}

# _csg_valid_anchor <path> - print it when absolute and an existing dir, else nothing.
_csg_valid_anchor() {
    case "$1" in
        /*) [ -d "$1" ] && printf '%s' "$1" ;;
    esac
    return 0
}

# _csg_primary_of <dir> - print the primary checkout of dir's repo, else nothing.
# env -i: no caller GIT_* (config, ceiling, dir) can blank or move it.
_csg_primary_of() {
    local common
    common=$("$(_csg_bin env)" -i "$(_csg_bin git)" -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=""
    case "$common" in
        */.git) printf '%s' "${common%/.git}" ;;
    esac
    return 0
}

# _csg_orphan <proc-root> <start-pid> <key> <name> <root> - no claude ancestor.
# Allowed, except on the anchor copy (this tree is its own primary checkout)
# when this process's exec-time environ carries a Claude Code marker AND one of
# the chokepoint's registered seams is set: a session that lost its ancestry
# (setsid, a daemon not recognised) must not pass a seam that way. An at job
# armed from a session carries the markers but no seam, so it still runs.
_csg_orphan() {
    local primary seams seam set=""
    _csg_has_marker "$1/$2/environ" || return 0
    primary=$(_csg_primary_of "$5")
    [ -n "$primary" ] && [ "$5" -ef "$primary" ] || return 0
    if seams=$(_csg_registry_seams "$5/scripts/chokepoints.json" "$3"); then :; else
        _csg_deny "$4" "cannot read its seams from scripts/chokepoints.json"
    fi
    for seam in $seams; do
        case "$seam" in
            [A-Za-z_]*) ;;
            *) continue ;;
        esac
        case "$seam" in
            *[!A-Za-z0-9_]*) continue ;;
        esac
        # Presence, not non-emptiness: an empty seam can still change behaviour.
        [ -n "${!seam+x}" ] && set="$set $seam"
    done
    [ -z "$set" ] && return 0
    _csg_deny "$4" "no Claude Code session ancestor, yet this process carries Claude Code markers and seam(s)${set} are set - a detached or headless (--bg) launch cannot pass seams to chokepoints (HIMMEL-3914); use a headed leg"
}

_csg_deny() {
    echo "$1: $2 - refusing (HIMMEL-3914)" >&2
    exit "$CSG_DENY_RC"
}

# chokepoint_seam_guard <registry key> - the gate. No env or arg knobs: the
# proc root and start pid are fixed here; _csg_gate takes them only so the
# suite can drive the whole gate on a fake /proc tree.
chokepoint_seam_guard() {
    _csg_gate /proc "$$" "$1"
}

_csg_gate() {
    local proc="$1" start="$2" key="$3" name="${3##*/}" pid env cwd anchor="" root seams bad files f home bgsvc=0
    [ -r "$proc/self/stat" ] || return 0
    if pid=$(_csg_find_outermost "$proc" "$start"); then :; else
        _csg_deny "$name" "cannot walk this process's ancestry in /proc"
    fi
    # readlink -f from a fixed dir, not cd/pwd: both are shadowable builtins.
    root=$("$(_csg_bin readlink)" -f "${BASH_SOURCE[0]%/*}/../.." 2>/dev/null) || root=""
    [ -n "$root" ] || _csg_deny "$name" "cannot resolve this copy's tree"
    if [ -z "$pid" ]; then
        _csg_orphan "$proc" "$start" "$key" "$name" "$root"
        return 0
    fi
    _csg_is_bg_service "$proc" "$pid" && bgsvc=1
    env="$proc/$pid/environ"
    cwd=$("$(_csg_bin readlink)" "$proc/$pid/cwd" 2>/dev/null) || _csg_deny "$name" "cannot read the claude session's cwd (pid $pid)"
    [ -r "$env" ] || _csg_deny "$name" "cannot read the claude session's launch environment (pid $pid)"
    if anchor=$(_csg_env_get "$env" HIMMEL_REPO); then :; else
        anchor=""
    fi
    anchor=$(_csg_valid_anchor "$anchor")
    if [ -z "$anchor" ] && ! _csg_env_get "$env" CLAUDE_CONFIG_DIR >/dev/null && home=$(_csg_env_get "$env" HOME); then
        if anchor=$(_csg_settings_get "$home/.claude/settings.json" HIMMEL_REPO); then :; else
            anchor=""
        fi
        anchor=$(_csg_valid_anchor "$anchor")
    fi
    # A daemon's cwd is wherever its spawner ran (another repo, or none), so it
    # never names the anchor: use this copy's own primary instead, and the
    # headless refusal cannot fail open on an unrelated daemon cwd.
    if [ -z "$anchor" ] && [ "$bgsvc" -eq 1 ]; then
        anchor=$(_csg_primary_of "$root")
    fi
    [ -n "$anchor" ] || anchor=$(_csg_primary_of "$cwd")
    [ -n "$anchor" ] || return 0
    [ "$root" -ef "$anchor" ] || return 0
    if seams=$(_csg_registry_seams "$root/scripts/chokepoints.json" "$key"); then :; else
        _csg_deny "$name" "cannot read its seams from scripts/chokepoints.json"
    fi
    files=$(_csg_overlay_files "$cwd" "$anchor" "$env")
    set --
    while IFS= read -r f; do
        if [ -n "$f" ]; then set -- "$@" "$f"; fi
    done <<EOF
$files
EOF
    if bad=$(_csg_verdict "$env" "$anchor" "$root" "$seams" "$@"); then
        return 0
    else
        case "$?" in
            2) _csg_deny "$name" "the claude session's launch environment (pid $pid) is unreadable or empty" ;;
        esac
    fi
    bad=${bad//$'\n'/ }
    if [ "$bgsvc" -eq 1 ]; then
        _csg_deny "$name" "seam(s) ${bad% } differ from the claude background service's environment - headless (--bg) legs cannot pass seams to chokepoints (HIMMEL-3914); use a headed leg"
    fi
    _csg_deny "$name" "seam(s) ${bad% } differ from this session's launch environment. A chokepoint seam must come from the launching shell, not a per-call prefix, export or unset - set it in the launching shell (e.g. SEAM=1 claude)"
}
