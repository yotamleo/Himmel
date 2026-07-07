#!/usr/bin/env bash
# claude-glm-seed-check.sh -- read-only drift check for the glm-launcher seeded set.
# HIMMEL-654 WS5 Task 1. bash 3.2-safe. PowerShell twin: claude-glm-seed-check.ps1.
#
# The launcher (scripts/claude-glm) mirrors a seeded set from ~/.claude into
# ~/.claude-glm ONCE, then re-seeds only on --reseed or a missing .seeded
# sentinel. A reused ~/.claude-glm therefore lags ~/.claude. This check reports
# that drift. It NEVER mutates either directory (no --fix; --reseed lives on the
# launcher). Mirrors the seeded set + env defaults of scripts/claude-glm exactly.
#
# settings.json is INTENTIONALLY EXCLUDED: the launcher re-sanitizes it every
# seed (strips `model` + `env.ANTHROPIC_*`), so the sanitized copy never
# byte-matches the raw source -- comparing it would report permanent drift.
#
# Exit codes:
#   0  in sync (the seeded set matches; settings.json ignored)
#   1  drift  (per-file list printed to stdout; reseed hint at the end)
#   2  unseeded config dir (absent, or no .seeded sentinel -> first launch)
#
# Usage:
#   claude-glm-seed-check.sh --check [--config-dir DIR] [--source DIR]
#   ( --check is the only mode and may be omitted )
set -u

# Same env defaults as scripts/claude-glm (CONFIG_DIR / SRC there). NOT derived
# from CLAUDE_DIR -- the launcher hardcodes ~/.claude-glm, so this does too.
CONFIG_DIR="${HOME}/.claude-glm"
SOURCE="${HOME}/.claude"

while [ $# -gt 0 ]; do
    case "$1" in
        --check) ;;                                            # only mode; no-op
        --config-dir) shift; CONFIG_DIR="${1:?--config-dir needs a DIR}" ;;
        --source)     shift; SOURCE="${1:?--source needs a DIR}" ;;
        -h|--help)    sed -n '2,21p' "$0"; exit 0 ;;
        *) echo "claude-glm-seed-check: unknown arg '$1'" >&2; exit 2 ;;
    esac
    shift
done

# The EXACT seeded set the launcher's seed_config_dir() mirrors. Keep in sync
# with scripts/claude-glm + scripts/claude-glm.ps1. settings.json is NOT here.
SEED_FILES="CLAUDE.md RTK.md plugins/installed_plugins.json plugins/known_marketplaces.json plugins/claude-hud/config.json"
SEED_DIRS="commands skills hooks agents plugins/marketplaces"

# Unseeded = the launcher would re-seed on next run: dir absent OR no .seeded
# sentinel (mirrors the launcher's own seed trigger `[ ! -f .../.seeded ]`).
if [ ! -d "$CONFIG_DIR" ] || [ ! -f "$CONFIG_DIR/.seeded" ]; then
    echo "claude-glm-seed-check: unseeded config dir ($CONFIG_DIR) -- no .seeded sentinel. Run 'claude-glm' to seed on first launch."
    exit 2
fi

DRIFT="$(mktemp)"
trap 'rm -f "$DRIFT"' EXIT
note_drift() { printf '%s\n' "$1" >> "$DRIFT"; }

# Compare one seeded FILE entry (path relative to SOURCE/CONFIG_DIR).
cmp_seed_file() {
    local entry="$1" src="$SOURCE/$1" cfg="$CONFIG_DIR/$1"
    [ -f "$src" ] || return 0                  # source lacks it -> launcher skips -> no drift
    if [ ! -f "$cfg" ]; then note_drift "$entry"; return; fi   # missing or wrong-type
    cmp -s "$src" "$cfg" || note_drift "$entry"
}

# Compare one seeded DIR entry recursively via `diff -rq` (ONE process per
# subtree). A per-file `cmp` loop would spawn a process per file -- thousands
# under skills/ (~3800) + plugins/marketplaces (~900) on a real ~/.claude, so
# the diff is the fast path. Reports each missing/extra/changed file by its
# path relative to the CONFIG_DIR root ($entry/<sub>).
cmp_seed_dir() {
    local entry="$1" src="$SOURCE/$1" cfg="$CONFIG_DIR/$1"
    [ -d "$src" ] || return 0                  # source lacks it -> launcher skips -> no drift
    local line rest first sub body dir name rel
    if [ ! -d "$cfg" ]; then note_drift "$entry/"; return; fi  # whole subtree missing
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in
            "Files "*)                                  # Files <src>/<sub> and <cfg>/<sub> differ
                rest="${line#Files }"
                first="${rest%% and *}"
                sub="${first#"$src"/}"                  # strip the literal src/ prefix
                [ "$sub" != "$first" ] && note_drift "$entry/$sub"
                ;;
            "Only in "*)                                # Only in <dir>: <name>
                body="${line#Only in }"
                dir="${body%%: *}"
                name="${body##*: }"
                rel="$entry"
                case "$dir" in "$src"*) rel="$entry${dir#"$src"}" ;; esac
                case "$dir" in "$cfg"*) rel="$entry${dir#"$cfg"}" ;; esac
                note_drift "$rel/$name"
                ;;
        esac
    done <<EOF
$(diff -rq "$src" "$cfg" 2>/dev/null)
EOF
}

for f in $SEED_FILES; do cmp_seed_file "$f"; done
for d in $SEED_DIRS;  do cmp_seed_dir  "$d"; done

if [ -s "$DRIFT" ]; then
    n=$(wc -l < "$DRIFT" | tr -d ' ')
    echo "claude-glm-seed-check: drift -- $n seeded file(s) in $CONFIG_DIR lag $SOURCE (--check)"
    sed 's/^/  · /' "$DRIFT"
    echo "  reseed: claude-glm --reseed"
    exit 1
fi

echo "claude-glm-seed-check: in sync ($CONFIG_DIR matches the seeded set of $SOURCE; settings.json excluded)"
exit 0
