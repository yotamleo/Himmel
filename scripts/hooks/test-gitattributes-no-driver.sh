#!/usr/bin/env bash
# HIMMEL-4923: guard-pr-check-literal treats a git pathspec operand as a mention,
# but `git add` / `restore` / `diff` / `show` run clean/smudge filters and
# textconv drivers named by .gitattributes + repo config, with no `-c` on argv.
# The hook is a command-text guard and cannot see that, so this lint pins the
# other half: no tracked .gitattributes may name a filter= or diff= driver
# outside the allowlist below. Fixtures prove the lint can fail.
#
# Fail direction: closed (a non-allowlisted driver fails the suite).
set -u
ROOT=$(git rev-parse --show-toplevel) || exit 1
ALLOW='lfs'
FAILED=0

# lint_file <file> - print each filter=/diff= driver outside ALLOW, one per line
lint_file() {
    local line trimmed tok name
    while IFS= read -r line || [ -n "$line" ]; do
        trimmed=${line#"${line%%[![:space:]]*}"}
        case "$trimmed" in '#'*) continue ;; esac
        for tok in $line; do
            case "$tok" in
                filter=* | diff=*)
                    name=${tok#*=}
                    case " $ALLOW " in *" $name "*) ;; *) echo "$tok" ;; esac
                    ;;
            esac
        done
    done <"$1"
}

check() { # check <label> <want-bad 0|1> <file>
    local out bad=0
    if [ -r "$3" ]; then
        out=$(lint_file "$3")
        [ -z "$out" ] || bad=1
    else
        out="unreadable"
        bad=1
    fi
    if [ "$bad" = "$2" ]; then echo "PASS $1"; else echo "FAIL $1 - drivers: ${out:-none}"; FAILED=1; fi
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/gitattr-lint.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
printf '*.bin filter=lfs diff=lfs merge=lfs -text\n' >"$TMP/ok"
printf '# filter=evil\n*.md text\n' >"$TMP/comment"
printf '  # filter=evil\n*.md text\n' >"$TMP/indented"
printf '*.txt filter=evil\n' >"$TMP/filter"
printf '*.pdf diff=pdf\n' >"$TMP/diff"
printf '*.a text\n*.b filter=lfs\n*.c diff=bash -x\n' >"$TMP/mixed"
check "fixture lfs-only -> clean" 0 "$TMP/ok"
check "fixture comment -> clean" 0 "$TMP/comment"
check "fixture indented comment -> clean" 0 "$TMP/indented"
check "fixture filter=evil -> flagged" 1 "$TMP/filter"
check "fixture diff=pdf -> flagged" 1 "$TMP/diff"
check "fixture mixed -> flagged" 1 "$TMP/mixed"
check "fixture missing file -> flagged" 1 "$TMP/absent"

TRACKED=$(git -C "$ROOT" ls-files -- '.gitattributes' '*/.gitattributes') || {
    echo "FAIL could not list tracked .gitattributes"
    exit 1
}
while IFS= read -r f; do
    [ -n "$f" ] || continue
    check "tracked $f" 0 "$ROOT/$f"
done <<EOF
$TRACKED
EOF

[ "$FAILED" -eq 0 ] && echo "all gitattributes driver lint cases passed" && exit 0
echo "gitattributes driver lint failed"
exit 1
