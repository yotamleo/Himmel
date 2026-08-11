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

# Canonicalise a path, tolerating non-existent ones: GNU realpath -m, else
# armored python3 pathlib, else the input unchanged (best effort). Shared by
# arm-resume.sh's scheduler identity and the arms-registry contract so those
# two keys cannot drift (HIMMEL-1304/HIMMEL-1344).
_arm_realpath() {
    local _p=""
    _p=$(realpath -m "$1" 2>/dev/null) || _p=""
    if [ -z "$_p" ] && command -v py_armor_capture >/dev/null 2>&1; then
        if py_armor_capture -c 'import sys,pathlib;print(pathlib.Path(sys.argv[1]).resolve(strict=False))' "$1" 2>/dev/null; then
            _p="$PY_ARMOR_OUT"
        fi
    fi
    [ -n "$_p" ] || _p="$1"
    printf '%s\n' "$_p"
}

# _hp_ascii_lower <value> -- fold ASCII into $_HP_LOWER without a subprocess.
# bash 3.2 has no ${value,,}; arms-registry rewrites cannot afford a `tr` fork
# for every row that reaches the migration matcher.
_HP_LOWER=""
_hp_ascii_lower() {
    local _hp_s="$1" _hp_i=0 _hp_ch _hp_prefix
    local _hp_upper=ABCDEFGHIJKLMNOPQRSTUVWXYZ _hp_lower=abcdefghijklmnopqrstuvwxyz
    _HP_LOWER=""
    while [ "$_hp_i" -lt "${#_hp_s}" ]; do
        _hp_ch="${_hp_s:$_hp_i:1}"
        case "$_hp_ch" in
            [A-Z])
                _hp_prefix="${_hp_upper%%"$_hp_ch"*}"
                _hp_ch="${_hp_lower:${#_hp_prefix}:1}"
                ;;
        esac
        _HP_LOWER="$_HP_LOWER$_hp_ch"
        _hp_i=$((_hp_i + 1))
    done
}

# _arm_identity_path <path> -- the canonical handover identity first shipped
# in arm-resume.sh for scheduler-row dedup (HIMMEL-1304). It lives in this
# shared library now because queue-lock.sh must consume the exact same identity
# from arms.jsonl (HIMMEL-1344). On Windows, cygpath folds C:/, C:\ and /c/
# spellings together, then case-folding matches NTFS semantics; POSIX paths
# retain case because it can distinguish real files there.
_arm_identity_path() {
    local _p _platform="${PLATFORM:-}" _os
    _p=$(_arm_realpath "$1")
    if [ -z "$_platform" ]; then
        _os="${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}"
        case "$_os" in
            msys*|cygwin*|win32*|MINGW*) _platform=windows ;;
            linux*|Linux*)               _platform=linux ;;
            darwin*|Darwin*)             _platform=macos ;;
        esac
    fi
    if [ "$_platform" = windows ]; then
        if command -v cygpath >/dev/null 2>&1; then
            _p=$(cygpath -u "$_p" 2>/dev/null) || _p=$(_arm_realpath "$1")
        fi
        _hp_ascii_lower "$_p"; _p="$_HP_LOWER"
    fi
    printf '%s' "$_p"
}

# _arm_registry_identity_root <handover-root> -- canonicalize the loop-invariant
# root once before an arms-registry scan/rewrite.
_arm_registry_identity_root() {
    _arm_identity_path "$1"
}

# _arm_registry_identity_from_canonical <canonical-handover> <canonical-root>
# -- format the durable cross-machine key without re-canonicalizing either path.
_arm_registry_identity_from_canonical() {
    local _ho="$1" _root="$2" _key
    case "$_ho" in
        "$_root"/*)
            # Root-relative keys ARE folded on every platform: this is the
            # cross-machine dedup key, and a Windows peer can legitimately spell
            # the same in-root handover with different case. Both sides must
            # fold or they disagree. State the cost of that collision at full
            # strength rather than at its mildest (CR round, [glm-2]): across
            # hosts it is a refusal, overridable with --force, but a SAME-HOST
            # re-arm goes through _arm_registry_replace_and_append, which
            # retires the colliding record — so on a case-sensitive filesystem
            # two in-root handovers differing only by case would silently cost
            # one of them its pending row, not merely earn a refusal. That is
            # accepted because the line above is a real precondition, not a
            # hope: case-distinct sibling handovers do not legitimately coexist
            # inside one handover root. Folding is still right for the branch
            # that must survive a Windows peer spelling the same file
            # differently; NOT folding here would trade this bounded,
            # out-of-contract collision for the unbounded in-contract failure
            # the ticket exists to prevent (two machines disagreeing on the key
            # and both firing). The absolute branch below folds nothing,
            # precisely because it makes no cross-machine promise to keep.
            _key="root-relative:${_ho#"$_root"/}"
            _hp_ascii_lower "$_key"
            printf '%s' "$_HP_LOWER"
            ;;
        *)
            # Absolute (outside-root) keys keep their case. This branch already
            # carries the documented cross-layout limitation — it makes no
            # cross-machine promise — so folding buys nothing here, while on a
            # case-sensitive filesystem it would ERASE a distinction that really
            # exists: /work/Foo.md and /work/foo.md are two different files with
            # two different scheduler identities, and one folded key would let
            # a re-arm prune or a queue-lock consume retire the OTHER handover's
            # pending record (HIMMEL-1344 codex-adv round).
            printf 'absolute:%s' "$_ho"
            ;;
    esac
}

# _arm_registry_identity_path_from_root <handover-path> <canonical-root> --
# canonicalize only the row path; callers hoist the root out of hot loops.
_arm_registry_identity_path_from_root() {
    local _ho
    _ho=$(_arm_identity_path "$1")
    _arm_registry_identity_from_canonical "$_ho" "$2"
}

# _arm_registry_identity_path <handover-path> <handover-root> -- durable
# cross-machine arms-registry key (HIMMEL-1344). Paths under the handover root
# are stored ROOT-RELATIVE; outside-root paths retain a canonical absolute key.
_arm_registry_identity_path() {
    local _root
    _root=$(_arm_registry_identity_root "$2")
    _arm_registry_identity_path_from_root "$1" "$_root"
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

# _hp_json_unescape <escaped-value> -- inverse of _hp_json_escape into
# $_HP_UNESC. The writer emits only \\ and \" escapes, so a small pure-bash
# scanner is sufficient and avoids a process per legacy registry line.
_HP_UNESC=""
_hp_json_unescape() {
    local _hp_s="$1" _hp_i=0 _hp_ch
    _HP_UNESC=""
    while [ "$_hp_i" -lt "${#_hp_s}" ]; do
        _hp_ch="${_hp_s:$_hp_i:1}"
        if [ "$_hp_ch" = "\\" ] && [ $((_hp_i + 1)) -lt "${#_hp_s}" ]; then
            _hp_i=$((_hp_i + 1))
            _hp_ch="${_hp_s:$_hp_i:1}"
        fi
        _HP_UNESC="$_HP_UNESC$_hp_ch"
        _hp_i=$((_hp_i + 1))
    done
}

# _hp_path_quick_normalize <path> <fold-case> <windows-separators> -- cheap
# legacy-row filter into $_HP_PATH_NORM. It deliberately does not resolve the
# filesystem; false positives only spend one rare canonicalization, while the
# basename/symlink gate below rejects ordinary unrelated rows without a fork.
_HP_PATH_NORM=""
_hp_path_quick_normalize() {
    _HP_PATH_NORM="$1"
    if [ "$3" -eq 1 ]; then
        _HP_PATH_NORM="${_HP_PATH_NORM//\\//}"
    fi
    if [ "$2" -eq 1 ]; then
        _hp_ascii_lower "$_HP_PATH_NORM"; _HP_PATH_NORM="$_HP_LOWER"
    fi
}

# _hp_arms_record_matches_path <json-line> <raw-path> <registry-key>
# <canonical-root> -- set $_HP_ARMS_MATCH to 1 when an arms.jsonl record
# identifies this handover. New records match the canonical handover-key.
# Legacy raw-only records first take a fork-free normalized path/basename gate;
# only plausible aliases fall back to filesystem canonicalization. A
# nonmatching key also falls through for partial-deployment compatibility.
_HP_ARMS_MATCH=0
_hp_arms_record_matches_path() {
    local _hp_line="$1" _hp_raw="$2" _hp_key="$3" _hp_root="$4"
    local _hp_stored_key _hp_stored_raw _hp_key_esc _hp_raw_esc _hp_legacy_key
    local _hp_stored_norm _hp_raw_norm _hp_stored_leaf _hp_raw_leaf
    local _hp_fold=0 _hp_windows=0
    _HP_ARMS_MATCH=0

    _hp_json_escape "$_hp_key"; _hp_key_esc="$_HP_ESC"
    _hp_json_field "$_hp_line" handover-key; _hp_stored_key="$_HP_FIELD"
    if [ -n "$_hp_stored_key" ] && [ "$_hp_stored_key" = "$_hp_key_esc" ]; then
        _HP_ARMS_MATCH=1
        return 0
    fi

    _hp_json_field "$_hp_line" handover; _hp_stored_raw="$_HP_FIELD"
    [ -n "$_hp_stored_raw" ] || return 0
    _hp_json_escape "$_hp_raw"; _hp_raw_esc="$_HP_ESC"
    if [ "$_hp_stored_raw" = "$_hp_raw_esc" ]; then
        _HP_ARMS_MATCH=1
        return 0
    fi

    _hp_json_unescape "$_hp_stored_raw"
    case "${PLATFORM:-}:${OSTYPE:-}" in
        windows:*|*:msys*|*:cygwin*|*:win32*|*:MINGW*) _hp_windows=1 ;;
    esac
    case "$_hp_key" in
        root-relative:*) _hp_fold=1 ;;
        *) _hp_fold="$_hp_windows" ;;
    esac
    _hp_path_quick_normalize "$_HP_UNESC" "$_hp_fold" "$_hp_windows"
    _hp_stored_norm="$_HP_PATH_NORM"
    _hp_path_quick_normalize "$_hp_raw" "$_hp_fold" "$_hp_windows"
    _hp_raw_norm="$_HP_PATH_NORM"
    if [ "$_hp_stored_norm" = "$_hp_raw_norm" ]; then
        _HP_ARMS_MATCH=1
        return 0
    fi

    _hp_stored_leaf="${_hp_stored_norm##*/}"
    _hp_raw_leaf="${_hp_raw_norm##*/}"
    # Probe BOTH sides for a symlink, not just the stored one. The gate exists to
    # reject unrelated rows without a fork, and differing leaf names are the cheap
    # signal for that -- but a symlink on EITHER side can legitimately make two
    # different leaf names denote one file. Testing only the stored path made the
    # gate asymmetric: a queried handover that is itself a symlink to a
    # differently-named target, whose target spelling is what the registry stored,
    # was rejected here even though the canonical keys below would have matched --
    # a missed duplicate-arm on the foreign scan and a stale same-host record that
    # survives the rewrite. (CR round 1: panel [codex-1] + CodeRabbit, agreed.)
    if [ "$_hp_stored_leaf" != "$_hp_raw_leaf" ] \
        && [ ! -L "$_HP_UNESC" ] && [ ! -L "$_hp_raw" ]; then
        return 0
    fi
    _hp_legacy_key=$(_arm_registry_identity_path_from_root "$_HP_UNESC" "$_hp_root")
    [ "$_hp_legacy_key" = "$_hp_key" ] && _HP_ARMS_MATCH=1
    return 0
}
