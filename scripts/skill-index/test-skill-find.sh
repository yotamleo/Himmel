#!/usr/bin/env bash
# scripts/skill-index/test-skill-find.sh — HIMMEL-2222
# Verifies skill-find.sh fails loudly (rebuild commands, non-zero rc) when the
# 'skills' qmd collection is missing or empty, and queries through when it's
# present — a stub `qmd` on PATH (BUN_INSTALL pointed at nothing, so qmd_cmd's
# bun-first branch always falls through to it), same shape as
# scripts/lib/test-provenance-read.sh's S16 qmd stub.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$REPO_ROOT/scripts/skill-index/skill-find.sh"

fail=0
check() {
    local desc="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
        echo "ok - $desc"
    else
        echo "FAIL - $desc: got [$got] want [$want]"
        fail=1
    fi
}

td="$(mktemp -d "${TMPDIR:-/tmp}/test-skill-find.XXXXXX")"
trap 'rm -rf "$td"' EXIT
mkdir -p "$td/bin"

cat > "$td/bin/qmd" <<'STUB'
#!/usr/bin/env bash
if [ "$1 $2" = "collection list" ]; then
    # Unset -> no 'skills' collection at all; set (including 0) -> registered
    # with that file count, so the zero-file case is a real registered collection.
    if [ -n "${QMD_STUB_SKILLS_FILES+x}" ]; then
        printf 'Collections (2):\n\nhimmel (qmd://himmel/)\n  Files:    527\n\nskills (qmd://skills/)\n  Files:    %s\n' "$QMD_STUB_SKILLS_FILES"
    else
        printf 'Collections (1):\n\nhimmel (qmd://himmel/)\n  Files:    527\n'
    fi
    exit 0
fi
if [ "$1" = "query" ]; then
    printf 'stub-query-ran %s\n' "$*"
    exit 0
fi
exit 2
STUB
chmod 755 "$td/bin/qmd"

export PATH="$td/bin:$PATH" BUN_INSTALL="$td/no-bun"

# RED: missing collection entirely -> loud rebuild remedy, rc 3, qmd query
# never invoked (only 'collection list' should appear in output).
unset QMD_STUB_SKILLS_FILES
out="$(bash "$TARGET" 'read a post from X' 2>&1)"; rc=$?
check "missing collection: exit code" "$rc" "3"
case "$out" in
    *"build-skill-index.sh"*"skills"*) ;;
    *) echo "FAIL - missing collection: remedy text absent from output"; fail=1 ;;
esac
case "$out" in
    *"stub-query-ran"*) echo "FAIL - missing collection: qmd query was invoked despite missing collection"; fail=1 ;;
    *) ;;
esac

# RED->GREEN: empty collection (registered, 0 files) -> same loud remedy, rc 3.
export QMD_STUB_SKILLS_FILES=0
out="$(bash "$TARGET" 'read a post from X' 2>&1)"; rc=$?
check "empty collection: exit code" "$rc" "3"
case "$out" in
    *"build-skill-index.sh"*) ;;
    *) echo "FAIL - empty collection: remedy text absent from output"; fail=1 ;;
esac
case "$out" in
    *"stub-query-ran"*) echo "FAIL - empty collection: qmd query was invoked despite 0 files"; fail=1 ;;
    *) ;;
esac
case "$(qmd collection list)" in
    *"skills (qmd://skills/)"*"Files:    0"*) echo "ok - empty collection: stub registers 'skills' with 0 files" ;;
    *) echo "FAIL - empty collection: stub did not register a zero-file 'skills' collection"; fail=1 ;;
esac

# Remedy honours a customised SKILL_INDEX_DIR (HIMMEL-3760) in both the build
# and ingest lines, instead of a hardcoded default path.
custom="$td/custom index"
out="$(SKILL_INDEX_DIR="$custom" bash "$TARGET" 'read a post from X' 2>&1)"; rc=$?
check "custom SKILL_INDEX_DIR: exit code" "$rc" "3"
q="$(printf '%q' "$custom")"
case "$out" in
    *"build-skill-index.sh --out $q"*"ingest --collection skills"*"_ $q"*) echo "ok - custom SKILL_INDEX_DIR: remedy uses it" ;;
    *) echo "FAIL - custom SKILL_INDEX_DIR: remedy does not print [$q]: $out"; fail=1 ;;
esac

# GREEN: populated collection -> query runs, rc from qmd propagates.
export QMD_STUB_SKILLS_FILES=42
out="$(bash "$TARGET" 'read a post from X' 2>&1)"; rc=$?
check "populated collection: exit code" "$rc" "0"
case "$out" in
    *"stub-query-ran"*) ;;
    *) echo "FAIL - populated collection: qmd query did not run"; fail=1 ;;
esac

# Usage error: no intent text.
out="$(bash "$TARGET" 2>&1)"; rc=$?
check "no intent: exit code" "$rc" "2"

exit "$fail"
