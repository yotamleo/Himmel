#!/usr/bin/env bash
# scripts/skill-index/test-ensure-skill-index.sh — HIMMEL-4302
# ensure-skill-index.sh registers the 'skills' collection when absent, never
# registers twice, and skips cleanly with no qmd or an empty/missing index dir.
# Stub qmd on PATH (BUN_INSTALL pointed at nothing), as test-skill-find.sh does.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$SCRIPT_DIR/ensure-skill-index.sh"

fail=0
check() {
    if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "FAIL - $1: got [$2] want [$3]"; fail=1; fi
}

td="$(mktemp -d "${TMPDIR:-/tmp}/test-ensure-skill-index.XXXXXX")" || exit 1
trap 'rm -rf "$td"' EXIT
mkdir -p "$td/bin" "$td/home/.claude/commands"
printf -- '---\ndescription: a test command\n---\nbody\n' > "$td/home/.claude/commands/zz.md"

cat > "$td/bin/qmd" <<'STUB'
#!/usr/bin/env bash
if [ "$1 $2" = "collection list" ]; then
    printf 'Collections:\n\nhimmel (qmd://himmel/)\n  Files:    5\n'
    [ -f "$QMD_STUB_STATE" ] && printf 'skills (qmd://skills/)\n  Files:    1\n'
    exit 0
fi
if [ "$1 $2" = "collection add" ]; then
    echo "$*" >> "$QMD_STUB_LOG"; : > "$QMD_STUB_STATE"; exit 0
fi
exit 2
STUB
chmod 755 "$td/bin/qmd"
export BUN_INSTALL="$td/no-bun" HOME="$td/home" QMD_STUB_LOG="$td/log" QMD_STUB_STATE="$td/state"
export PATH="$td/bin:$PATH"

# Absent collection, populated source -> exactly one 'collection add ... --name skills'.
export SKILL_INDEX_DIR="$td/idx"
bash "$TARGET" >/dev/null 2>&1; rc=$?
check "absent collection: rc" "$rc" "0"
check "absent collection: registered once" "$(grep -c -- '--name skills' "$td/log" 2>/dev/null)" "1"

# Already registered -> no second registration.
bash "$TARGET" >/dev/null 2>&1; rc=$?
check "already registered: rc" "$rc" "0"
check "already registered: still one add" "$(grep -c -- '--name skills' "$td/log")" "1"

# Missing SKILL_INDEX_DIR (parent absent too) -> created, rc 0, registered.
rm -f "$td/log" "$td/state"; rm -rf "$td/idx"
export SKILL_INDEX_DIR="$td/missing/idx"
bash "$TARGET" >/dev/null 2>&1; rc=$?
check "missing index dir: rc" "$rc" "0"
check "missing index dir: registered" "$(grep -c -- '--name skills' "$td/log" 2>/dev/null)" "1"

# No skills anywhere (build scans the cwd's git toplevel, so run from a non-git
# dir with an empty HOME) -> rc 0, nothing registered.
mkdir -p "$td/nogit"
rm -f "$td/log" "$td/state"; rm -rf "$td/home/.claude"
export SKILL_INDEX_DIR="$td/empty/idx"
(cd "$td/nogit" && bash "$TARGET" >/dev/null 2>&1); rc=$?
check "no skills at all: rc" "$rc" "0"
check "no skills at all: nothing registered" "$([ -f "$td/log" ] && echo registered || echo none)" "none"

# qmd unresolvable -> clean skip.
PATH="/usr/bin:/bin" bash "$TARGET" >/dev/null 2>&1; rc=$?
check "no qmd: rc" "$rc" "0"

exit "$fail"
