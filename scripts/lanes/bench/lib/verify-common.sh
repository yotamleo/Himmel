#!/usr/bin/env bash
# scripts/lanes/bench/lib/verify-common.sh — HIMMEL-1723 P2.1
# Shared assertion helpers every fixture's verify.sh sources. bash 3.2-safe
# (no [[ ]], no associative arrays, no ${var,,}).
#
# assert_only_paths_changed is the highest-value assertion in the whole bench
# kit (spec §3.2): it is what turns "the model gratuitously touched an
# unrelated file" from a judgment call into a mechanical FAIL. It diffs the
# ORIGINAL fixture input/ tree against the CURRENT working directory (the
# materialized, possibly-edited copy — every verify.sh runs with cwd set
# there) and requires every difference (file added, removed, or modified) to
# be one of the manifest's sanctioned relative paths. A model that
# gratuitously refactors a file outside the sanctioned set FAILS here even if
# its actual task output is otherwise correct.
#
# Usage (from a fixture's verify.sh, invoked with cwd = the materialized dir):
#   . "<repo>/scripts/lanes/bench/lib/verify-common.sh"
#   assert_only_paths_changed "$ORIGINAL_INPUT_DIR" "$MANIFEST_FILE" || exit 1
#
# Contract for every helper here: return 0 = assertion held, return 1 =
# failed (a message is printed to stderr). These are library functions
# meant to be sourced, not run standalone — they `return`, never `exit`, so
# a caller's own verify.sh controls the final process exit code.
set -u

# assert_only_paths_changed <original-input-dir> <manifest-file>
#
# <manifest-file> is a plain text file, one sanctioned RELATIVE path per
# line (relative to <original-input-dir> / the materialized dir root — the
# two are the same tree shape by construction). Blank lines and lines
# starting with '#' are ignored.
assert_only_paths_changed() {
    local original_dir="$1" manifest="$2"
    if [ ! -d "$original_dir" ]; then
        echo "assert_only_paths_changed: original input dir not found: $original_dir" >&2
        return 1
    fi
    if [ ! -f "$manifest" ]; then
        echo "assert_only_paths_changed: manifest not found: $manifest" >&2
        return 1
    fi

    local diff_out bad=0 line rel
    diff_out="$(diff -rq "$original_dir" . 2>&1)"
    [ -z "$diff_out" ] && return 0

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        rel=""
        case "$line" in
            "Only in "*)
                rel="$(_verify_common_only_in_rel "$line" "$original_dir")"
                ;;
            "Files "*" and "*" differ")
                rel="$(_verify_common_files_differ_rel "$line" "$original_dir")"
                ;;
            *)
                # An unrecognized diff line (e.g. a binary-file notice on some
                # diff implementations) is treated as a failure rather than
                # silently skipped — fail-safe direction for a mechanical gate.
                echo "assert_only_paths_changed: unrecognized diff output, failing safe: $line" >&2
                bad=1
                continue
                ;;
        esac
        if [ -z "$rel" ]; then
            echo "assert_only_paths_changed: could not extract a path from: $line" >&2
            bad=1
            continue
        fi
        if ! grep -Fxq "$rel" "$manifest"; then
            echo "assert_only_paths_changed: OUT-OF-SCOPE change: $rel (not listed in $manifest)" >&2
            bad=1
        fi
    done <<EOF
$diff_out
EOF
    [ "$bad" -eq 0 ]
}

# _verify_common_only_in_rel <diff-line> <original-dir>
# Parses `diff -rq`'s "Only in <dir>: <name>" line into a path relative to
# <original-dir> (added files report the dir under ".", removed files report
# it under <original-dir> or a subdirectory of it).
_verify_common_only_in_rel() {
    local line="$1" root="$2" dir name rel
    dir="${line#Only in }"
    dir="${dir%%: *}"
    name="${line##*: }"
    case "$dir" in
        "$root") rel="$name" ;;
        "$root"/*) rel="${dir#"$root"/}/$name" ;;
        .) rel="$name" ;;
        ./*) rel="${dir#./}/$name" ;;
        *) rel="$name" ;;
    esac
    printf '%s\n' "$rel"
}

# _verify_common_files_differ_rel <diff-line> <original-dir>
# Parses `diff -rq`'s "Files <p1> and <p2> differ" line into a path relative
# to <original-dir>.
_verify_common_files_differ_rel() {
    local line="$1" root="$2" rest p1 rel
    rest="${line#Files }"
    p1="${rest%% and *}"
    case "$p1" in
        "$root"/*) rel="${p1#"$root"/}" ;;
        ./*) rel="${p1#./}" ;;
        *) rel="$p1" ;;
    esac
    printf '%s\n' "$rel"
}

# assert_no_hits <extended-regex> [path...]
# Fails when the pattern matches ANYWHERE under the given paths (default:
# recurse from .). Used for "the old pattern has zero hits" style checks.
assert_no_hits() {
    local pattern="$1"; shift
    local paths=("$@")
    [ "${#paths[@]}" -eq 0 ] && paths=(".")
    if grep -rEq -- "$pattern" "${paths[@]}" 2>/dev/null; then
        echo "assert_no_hits: pattern matched (expected zero hits): $pattern" >&2
        grep -rEn -- "$pattern" "${paths[@]}" 2>/dev/null | head -5 >&2
        return 1
    fi
    return 0
}

# assert_bytes_equal <file-a> <file-b>
assert_bytes_equal() {
    local a="$1" b="$2"
    if [ ! -f "$a" ] || [ ! -f "$b" ]; then
        echo "assert_bytes_equal: missing file(s): $a / $b" >&2
        return 1
    fi
    if ! cmp -s "$a" "$b"; then
        echo "assert_bytes_equal: byte mismatch: $a vs $b" >&2
        return 1
    fi
    return 0
}

# assert_json_parses <file>
assert_json_parses() {
    local f="$1"
    if [ ! -f "$f" ]; then
        echo "assert_json_parses: file not found: $f" >&2
        return 1
    fi
    if ! node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$f" 2>/dev/null; then
        echo "assert_json_parses: invalid JSON: $f" >&2
        return 1
    fi
    return 0
}
