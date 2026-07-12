#!/usr/bin/env bash
# Resolver for the project's handover directory.
#
# Source this file and call `handover_root` (PURE, no fs mutation) or
# `handover_root_ensure` (creates the Mode A inline dir on demand).
#
# Resolution order:
#   1. $HANDOVER_DIR — explicit override. Must resolve to an existing
#      directory; otherwise the resolver fails-closed (rc=2) rather than
#      silently falling back, so a typo or unmounted external repo gets
#      caught immediately instead of writing to the wrong location.
#   2. <repo-root>/handovers — inline default. Used when HANDOVER_DIR is
#      unset.
#
# Mode names (used by /handover-link diagnostics):
#   A — inline:   HANDOVER_DIR unset, content under <repo>/handovers
#   B — external: HANDOVER_DIR set, content under that path
#
# Return codes:
#   0 — printed an absolute path to stdout
#   2 — HANDOVER_DIR was set but did not resolve to a directory, OR
#       Mode A inline path does not yet exist (pure `handover_root` only —
#       use `handover_root_ensure` if you need the dir created)
#
# Pure / side-effecting split (HIMMEL-150 — back-port from luna-brain):
#   - `handover_root` is now PURE — never mkdirs. Status/doctor/read-only
#     callers cannot trigger filesystem mutation as a side effect of a
#     read. Returns rc=2 with diagnostic when the Mode A inline dir is
#     missing.
#   - `handover_root_ensure` mkdirs the Mode A inline dir if missing, then
#     delegates to `handover_root`. Direct callers in himmel:
#     `scripts/handover/auto-commit.sh`,
#     `scripts/overnight/morning-report.sh` and
#     `scripts/handover/generate-morning-briefing.sh` — write-op sites that
#     legitimately need the dir to exist. (setup.sh + flush.sh do NOT call
#     _ensure directly: setup.sh shells out to handover-link.sh doctor
#     which uses pure; flush.sh refuses Mode A explicitly and only runs
#     in Mode B where pure and _ensure behave identically.)
#
# Deployment guidance (HIMMEL-335):
#   Mode A (inline <repo>/handovers/) is the default and works out of the
#   box. To centralize handover state in a separate repo (Mode B) — so
#   handover commits don't land on your feature branches — run
#   `/handover-setup`: it prompts for the location and writes HANDOVER_DIR
#   into <repo>/.env. The shell loader scripts/lib/load-dotenv.sh feeds
#   that value to handover scripts; you can also export it directly:
#
#       export HANDOVER_DIR="/abs/path/to/your-state-repo/handovers"
#
#   HIMMEL-129 (done 2026-05-25) shipped the bucket-layout layer that
#   splits <state-root>/ into per-repo subfolders
#   (`cross/`, `himmel/`, `luna/`, `luna_brain/`). The v2 handover skill
#   auto-detects the layer when any bucket dir exists. This resolver
#   stays single-root; the bucket layer is applied by callers (skill +
#   handover/*.sh) on top of the resolved root.

# PURE resolver. No filesystem mutation. Returns rc=2 if Mode A inline
# dir doesn't yet exist — callers that legitimately need the dir
# created (bootstrap, write ops) should use `handover_root_ensure`.
handover_root() {
    if [ -n "${HANDOVER_DIR:-}" ]; then
        if [ -d "$HANDOVER_DIR" ]; then
            ( cd "$HANDOVER_DIR" && pwd )
            return 0
        fi
        echo "handover-path: HANDOVER_DIR='$HANDOVER_DIR' is not a directory" >&2
        return 2
    fi

    local repo_root
    if ! repo_root=$(git rev-parse --show-toplevel 2>/dev/null); then
        echo "handover-path: not inside a git repository and HANDOVER_DIR is unset" >&2
        return 2
    fi

    local inline="$repo_root/handovers"
    if [ ! -d "$inline" ]; then
        echo "handover-path: inline default '$inline' does not exist (call handover_root_ensure to create)" >&2
        return 2
    fi
    ( cd "$inline" && pwd )
}

# Side-effecting variant. mkdirs the Mode A inline dir if missing, then
# delegates to handover_root. No-op in Mode B (HANDOVER_DIR set).
handover_root_ensure() {
    if [ -z "${HANDOVER_DIR:-}" ]; then
        local repo_root
        if ! repo_root=$(git rev-parse --show-toplevel 2>/dev/null); then
            echo "handover-path: not inside a git repository and HANDOVER_DIR is unset" >&2
            return 2
        fi
        mkdir -p "$repo_root/handovers"
    fi
    handover_root
}

handover_mode() {
    if [ -n "${HANDOVER_DIR:-}" ]; then
        echo "B"
    else
        echo "A"
    fi
}

# --- flat-JSON helpers for the handover lock/registry files (HIMMEL-882) ---
# Shared by scripts/handover/queue-lock.sh and scripts/handover/arm-resume.sh
# (both already source this lib) for owner.json and the cross-machine arms
# registry (.locks/arms.jsonl). PURE BASH, ZERO FORKS by design: results are
# returned in globals (_HP_ESC / _HP_FIELD), not on stdout, so hot rewrite
# loops can call them per line without a command substitution -- the CR
# round-3 Critical measured the previous printf|grep|head|sed pipelines at
# ~185-200ms/LINE on Windows/Git-Bash (8+ forks each), which let a ~300-line
# registry rewrite outlive the arms-mutex's own 60s staleness expiry.

# _hp_json_escape <value> -- JSON-escape a string value into $_HP_ESC
# (backslashes doubled, double quotes escaped). The inverse pairing of
# _hp_json_field below: what one writes, the other reads back verbatim.
_HP_ESC=""
_hp_json_escape() {
    _HP_ESC="${1//\\/\\\\}"
    _HP_ESC="${_HP_ESC//\"/\\\"}"
}

# _hp_json_field <json-string> <key> -- extract the string value of a flat
# "key":"value" field into $_HP_FIELD (empty on miss/malformed). The value
# is returned in its RAW (still-escaped) form, so comparisons stay
# escaped-vs-escaped against _hp_json_escape output. Escape-AWARE: the
# value ends at the first UNESCAPED closing quote -- an escaped quote is
# recognized by trailing-backslash parity (odd run of backslashes before
# the quote = the quote is escaped and part of the value), so values
# containing \" and backslash runs extract correctly on every platform
# (macOS/Linux paths may legally contain double quotes). First occurrence
# of the key wins, matching the grep|head -1 extractors this replaces.
_HP_FIELD=""
_hp_json_field() {
    local _hp_rest _hp_chunk _hp_bs
    _HP_FIELD=""
    case "$1" in
        *"\"$2\":\""*) ;;
        *) return 0 ;;
    esac
    _hp_rest="${1#*"\"$2\":\""}"
    while :; do
        _hp_chunk="${_hp_rest%%\"*}"
        if [ "$_hp_chunk" = "$_hp_rest" ]; then
            # no closing quote at all -- malformed field, report a miss
            _HP_FIELD=""
            return 0
        fi
        _HP_FIELD="$_HP_FIELD$_hp_chunk"
        _hp_rest="${_hp_rest#*\"}"
        # trailing-backslash run of the chunk; ## leaves the chunk intact
        # when it is ALL backslashes (no non-backslash to anchor on).
        _hp_bs="${_hp_chunk##*[!\\]}"
        if [ $(( ${#_hp_bs} % 2 )) -eq 0 ]; then
            return 0   # even parity: the quote was unescaped -- value ends
        fi
        _HP_FIELD="$_HP_FIELD\""   # odd parity: escaped quote, keep scanning
    done
}
