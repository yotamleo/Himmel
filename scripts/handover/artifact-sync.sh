#!/usr/bin/env bash
# scripts/handover/artifact-sync.sh — local-vs-published Artifact parity (HIMMEL-2201).
#
# Makes the durable local HTML copy of a published Artifact equal-by-construction
# instead of by discipline: `record` stamps a content hash into a registry the
# instant a leg publishes from a local path; `check` fails loudly if that local
# file ever drifts from what was recorded. `slice` is the other half — turning a
# raw `Artifact action: read` dump (which carries a host-injected frame-runtime
# preamble) back into a clean local copy safe to republish.
#
# Bash 3.2 safe. No jq — flat single-line JSON, one row per artifact URL,
# read/written with the escape helpers already shared by queue-lock.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/handover-path.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/handover-path.sh"

usage() {
    cat >&2 <<'EOF'
Usage:
  artifact-sync.sh slice  <raw-read-file> <out-path>
  artifact-sync.sh record <url> <local-path> [--title <t>]
  artifact-sync.sh check  [--registry <path>]

slice   Strip the host frame-runtime preamble (line 1) from a raw
        `Artifact action: read` dump and write the result atomically to
        <out-path>. Refuses (exit 3) if _FRAMEPREAMBLE, frame-runtime, or
        <base href survive the slice -- republishing a file that still
        carries those nests a second runtime inside the artifact.

record  Hash <local-path>'s current content and upsert a row for <url> into
        the registry (<handover-root>/.artifacts/registry.jsonl). Run this
        immediately after publishing FROM <local-path> -- that is what makes
        local-vs-live equal by construction rather than by discipline.

check   Verify every registry row: local file still exists and its current
        sha256 still matches what was recorded at publish time. Exit 3 with
        a loud per-row report on any mismatch or absence; exit 0 if the
        registry is empty or every row is clean.
EOF
}

_af_die() { echo "artifact-sync.sh: $*" >&2; exit 2; }

# _af_file_hash <path> -- full sha256 hex of a file's content into stdout.
# Degrades the same way arm-resume.sh's _arm_path_hash does (sha256sum ->
# shasum -> python), but keeps the full 64 hex chars: this hash gates
# republish-corruption, not identity dedup, so truncation is not appropriate.
_af_file_hash() {
    local _h=""
    if command -v sha256sum >/dev/null 2>&1; then
        _h=$(sha256sum "$1" 2>/dev/null | cut -d' ' -f1) || _h=""
    fi
    if [ -z "$_h" ] && command -v shasum >/dev/null 2>&1; then
        _h=$(shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1) || _h=""
    fi
    if [ -z "$_h" ] && command -v py_armor_capture >/dev/null 2>&1; then
        if py_armor_capture -c 'import sys,hashlib;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1" 2>/dev/null; then
            _h="$PY_ARMOR_OUT"
        fi
    fi
    printf '%s' "$_h"
}

# _af_lock <registry> -- atomic mkdir mutex around record's read-modify-write
# (codex panel finding: two concurrent `record` calls on the same registry
# race and can drop each other's row). mkdir is atomic (like queue-lock.sh's
# convention) and portable to git-bash, unlike flock. Retries for up to ~10s;
# a leg-publish cadence is human-paced, so real contention is rare and brief.
# ponytail: a single registry-wide lock, not per-URL -- fine at this
# operator's publish cadence; upgrade to per-URL locking if throughput ever
# makes that a bottleneck.
_af_lock() {
    local _lockdir="${1}.lock" _tries=0
    while ! mkdir "$_lockdir" 2>/dev/null; do
        _tries=$((_tries + 1))
        [ "$_tries" -lt 100 ] || _af_die "record: could not acquire lock $_lockdir after 10s -- a stale lock from a crashed run? remove it manually if so"
        sleep 0.1
    done
}
_af_unlock() { rmdir "${1}.lock" 2>/dev/null || true; }

_af_registry_path() {
    local _root
    _root=$(handover_root_ensure) || exit 2
    printf '%s/.artifacts/registry.jsonl' "$_root"
}

_af_assert_clean() {
    # Forbidden-token guard shared by slice (post-strip) and record (pre-hash):
    # a local copy carrying any of these would nest a second runtime on republish.
    if grep -qiE '_FRAMEPREAMBLE|frame-runtime|<base[[:space:]]+href' "$1" 2>/dev/null; then
        echo "artifact-sync.sh: $1 still contains frame-runtime markup (_FRAMEPREAMBLE/frame-runtime/<base href) -- refusing, this would nest a second runtime on republish" >&2
        exit 3
    fi
}

cmd_slice() {
    local raw="${1:-}" out="${2:-}"
    if [ -z "$raw" ] || [ -z "$out" ]; then usage; exit 2; fi
    [ -f "$raw" ] || _af_die "slice: raw file not found: $raw"
    mkdir -p "$(dirname "$out")" || _af_die "slice: cannot create $(dirname "$out")"
    local tmpf
    tmpf="$(mktemp "${out}.slice.XXXXXX")" || _af_die "slice: cannot create temp file"
    trap 'rm -f "$tmpf"' EXIT
    tail -n +2 "$raw" > "$tmpf" || _af_die "slice: strip failed"
    _af_assert_clean "$tmpf"
    mv "$tmpf" "$out" || _af_die "slice: write failed"
    trap - EXIT
    echo "$out"
}

# ponytail: `record` hashes only the LOCAL file -- it cannot independently
# re-fetch and verify the just-published artifact, because the Artifact tool
# (publish/read) is agent-only with no bash-callable API. It trusts the
# caller published FROM local_path, exactly as documented above. `check` is
# the structural backstop that catches drift AFTER the fact; a true
# publish-time verification would need an agent-side step (Artifact read +
# diff) wrapping this call, not something this script can do alone.
cmd_record() {
    local url="" local_path="" title=""
    url="${1:-}"; [ $# -ge 1 ] && shift
    local_path="${1:-}"; [ $# -ge 1 ] && shift
    while [ $# -gt 0 ]; do case "$1" in
        --title) [ $# -ge 2 ] || _af_die "record: --title requires a value"; title="$2"; shift 2 ;;
        *) _af_die "record: unknown arg $1" ;;
    esac; done
    if [ -z "$url" ] || [ -z "$local_path" ]; then usage; exit 2; fi
    [ -f "$local_path" ] || _af_die "record: local file not found: $local_path"
    _af_assert_clean "$local_path"

    local hash
    hash=$(_af_file_hash "$local_path")
    [ -n "$hash" ] || _af_die "record: no sha256 hasher available (sha256sum/shasum/python)"

    local registry
    registry=$(_af_registry_path) || exit 2
    mkdir -p "$(dirname "$registry")" || _af_die "record: cannot create $(dirname "$registry")"

    local url_esc path_esc title_esc row tmpf grc
    _hp_json_escape "$url"; url_esc="$_HP_ESC"
    _hp_json_escape "$local_path"; path_esc="$_HP_ESC"
    _hp_json_escape "$title"; title_esc="$_HP_ESC"
    row=$(printf '{"url":"%s","local":"%s","title":"%s","sha256":"%s","recorded_at":"%s"}' \
        "$url_esc" "$path_esc" "$title_esc" "$hash" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")

    # Locked read-modify-write: two concurrent `record` calls must not race
    # and drop each other's row (codex panel finding).
    _af_lock "$registry"
    trap '_af_unlock "$registry"' EXIT
    [ -f "$registry" ] || : > "$registry"
    tmpf="$(mktemp "${registry}.record.XXXXXX")" || { _af_unlock "$registry"; _af_die "record: cannot create temp file"; }
    trap '_af_unlock "$registry"; rm -f "$tmpf"' EXIT
    # Drop any existing row for this URL, then append the fresh one -- one row
    # per URL, always the latest publish. grep -v exits 1 when EVERY line
    # matched (nothing survives the filter) -- that's a normal outcome, not
    # an error, so treat it like a clean empty result. Any OTHER nonzero exit
    # is a genuine read error and must abort rather than silently truncate
    # the registry to just the new row (codex panel finding).
    if [ -s "$registry" ]; then
        grc=0
        grep -vF "\"url\":\"$url_esc\"" "$registry" > "$tmpf" || grc=$?
        if [ "$grc" -gt 1 ]; then
            _af_unlock "$registry"
            _af_die "record: failed to read $registry while filtering (grep rc=$grc) -- refusing to risk dropping unrelated rows"
        fi
    else
        : > "$tmpf"
    fi
    printf '%s\n' "$row" >> "$tmpf" || { _af_unlock "$registry"; _af_die "record: write failed"; }
    mv "$tmpf" "$registry" || { _af_unlock "$registry"; _af_die "record: write failed"; }
    trap - EXIT
    _af_unlock "$registry"
}

cmd_check() {
    local registry=""
    while [ $# -gt 0 ]; do case "$1" in
        --registry) [ $# -ge 2 ] || _af_die "check: --registry requires a value"; registry="$2"; shift 2 ;;
        *) _af_die "check: unknown arg $1" ;;
    esac; done
    [ -n "$registry" ] || registry=$(_af_registry_path) || exit 2
    [ -f "$registry" ] || { echo "artifact-sync.sh check: no registry at $registry -- nothing published through the helper yet"; exit 0; }

    local fail=0 line url path title expected actual
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        _hp_json_field "$line" url; _hp_json_unescape "$_HP_FIELD"; url="$_HP_UNESC"
        _hp_json_field "$line" local; _hp_json_unescape "$_HP_FIELD"; path="$_HP_UNESC"
        _hp_json_field "$line" title; _hp_json_unescape "$_HP_FIELD"; title="$_HP_UNESC"
        _hp_json_field "$line" sha256; expected="$_HP_FIELD"
        if [ -z "$url" ]; then
            echo "FAIL <unparseable row>: could not extract a url from registry line: $line" >&2
            fail=1
            continue
        fi

        if [ ! -f "$path" ]; then
            echo "FAIL $url ($title): local copy missing at $path" >&2
            fail=1
            continue
        fi
        actual=$(_af_file_hash "$path")
        if [ -z "$actual" ]; then
            echo "FAIL $url ($title): no sha256 hasher available to verify $path" >&2
            fail=1
        elif [ "$actual" != "$expected" ]; then
            echo "FAIL $url ($title): local copy at $path drifted from published bytes (expected ${expected:0:12}…, got ${actual:0:12}…)" >&2
            fail=1
        else
            echo "OK $url ($title): $path matches published bytes"
        fi
    done < "$registry"

    [ "$fail" -eq 0 ] || exit 3
}

sub="${1:-}"; [ $# -gt 0 ] && shift
case "$sub" in
    slice)  cmd_slice "$@" ;;
    record) cmd_record "$@" ;;
    check)  cmd_check "$@" ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
esac
