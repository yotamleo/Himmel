#!/usr/bin/env bash
# skill-index/build-skill-index — scan installed Claude Code skills,
# commands, agents; emit one markdown file per item into a directory
# that qmd can ingest as the `skills` collection (HIMMEL-33).
#
# qmd backend: ships BM25 + vector search via embeddinggemma-300M.
# Indexing a directory is a `qmd ingest <dir>` away — this script
# produces that directory.
#
# Sources scanned (in order, dup-deduped by qualified name):
#   1. ~/.claude/plugins/cache/**/commands/*.md
#   2. ~/.claude/plugins/cache/**/agents/*.md
#   3. ~/.claude/plugins/cache/**/skills/<skill>/SKILL.md
#   4. <repo>/marketplace/plugins/**/skills/<skill>/SKILL.md
#   5. <repo>/marketplace/plugins/**/commands/*.md
#   6. <repo>/marketplace/plugins/**/agents/*.md
#   7. <repo>/.claude/commands/*.md  (project-local)
#   8. <repo>/.claude/agents/*.md
#
# Output layout: $OUT_DIR/<qualified-name>.md where qualified-name is
# `plugin:component` for plugin items + `local:component` for project-
# local ones. Each output file carries frontmatter the qmd indexer
# treats as queryable metadata:
#
#   ---
#   name: <qualified-name>
#   kind: command | agent | skill
#   plugin: <plugin-name> | local
#   invocation: <example>
#   ---
#
#   <description from the source's frontmatter `description:` field>
#
#   <body excerpt: first 40 lines of the source post-frontmatter>
#
# Exit codes:
#   0  index dir written; print path + item count
#   1  usage / input error
#   2  required tool missing
set -uo pipefail

OUT_DIR="${SKILL_INDEX_DIR:-$HOME/.claude/skill-index}"
DRY_RUN=0

usage() {
    cat <<'EOF'
Usage: build-skill-index.sh [--out PATH] [--dry-run]

Scans installed Claude Code skills/commands/agents and emits one
markdown file per item into the output directory. Intended to be
ingested by qmd as the `skills` collection so `/skill-find` can run
hybrid BM25 + vector search.

Optional:
  --out PATH    Output directory. Default: $SKILL_INDEX_DIR or
                $HOME/.claude/skill-index.
  --dry-run     Print summary; touch nothing.

After running:
  qmd ingest --collection skills "$SKILL_INDEX_DIR"

To query:
  qmd query --collection skills 'how do I review a PR'
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --out)      OUT_DIR="${2:-}"; shift 2 ;;
        --dry-run)  DRY_RUN=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)          echo "ERR build-skill-index: unknown arg: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if ! command -v find >/dev/null 2>&1; then
    echo "ERR build-skill-index: required tool 'find' not on PATH" >&2
    exit 2
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")

# Gather: produce a list of "kind|plugin|qualified-name|source-path"
# tuples. Skip dotfiles + non-.md files.
gather() {
    local sources=()
    [ -d "$HOME/.claude/plugins/cache" ] && sources+=("$HOME/.claude/plugins/cache")
    [ -n "$REPO_ROOT" ] && [ -d "$REPO_ROOT/marketplace/plugins" ] && sources+=("$REPO_ROOT/marketplace/plugins")
    [ -n "$REPO_ROOT" ] && [ -d "$REPO_ROOT/.claude" ] && sources+=("$REPO_ROOT/.claude")

    for src in "${sources[@]}"; do
        # Commands: */commands/*.md
        find "$src" -path '*/commands/*.md' -type f 2>/dev/null | while read -r f; do
            local plugin name kind="command"
            # Extract plugin name from path
            if [[ "$f" == */plugins/cache/* ]]; then
                plugin=$(printf '%s' "$f" | sed -E 's|.*/plugins/cache/([^/]+)/.*|\1|')
            elif [[ "$f" == */marketplace/plugins/* ]]; then
                plugin=$(printf '%s' "$f" | sed -E 's|.*/marketplace/plugins/([^/]+)/.*|\1|')
            else
                plugin="local"
            fi
            name=$(basename "$f" .md)
            printf '%s|%s|%s:%s|%s\n' "$kind" "$plugin" "$plugin" "$name" "$f"
        done
        find "$src" -path '*/agents/*.md' -type f 2>/dev/null | while read -r f; do
            local plugin name kind="agent"
            if [[ "$f" == */plugins/cache/* ]]; then
                plugin=$(printf '%s' "$f" | sed -E 's|.*/plugins/cache/([^/]+)/.*|\1|')
            elif [[ "$f" == */marketplace/plugins/* ]]; then
                plugin=$(printf '%s' "$f" | sed -E 's|.*/marketplace/plugins/([^/]+)/.*|\1|')
            else
                plugin="local"
            fi
            name=$(basename "$f" .md)
            printf '%s|%s|%s:%s|%s\n' "$kind" "$plugin" "$plugin" "$name" "$f"
        done
        find "$src" -path '*/skills/*/SKILL.md' -type f 2>/dev/null | while read -r f; do
            local plugin name kind="skill"
            if [[ "$f" == */plugins/cache/* ]]; then
                plugin=$(printf '%s' "$f" | sed -E 's|.*/plugins/cache/([^/]+)/.*|\1|')
            elif [[ "$f" == */marketplace/plugins/* ]]; then
                plugin=$(printf '%s' "$f" | sed -E 's|.*/marketplace/plugins/([^/]+)/.*|\1|')
            else
                plugin="local"
            fi
            # Skill name = parent dir of SKILL.md
            name=$(basename "$(dirname "$f")")
            printf '%s|%s|%s:%s|%s\n' "$kind" "$plugin" "$plugin" "$name" "$f"
        done
    done
}

# Extract description from a markdown file's frontmatter (between leading
# `---` markers). Returns "" if no frontmatter or no description: line.
extract_description() {
    local file="$1"
    awk '
        BEGIN { in_fm = 0 }
        NR == 1 && /^---[[:space:]]*$/ { in_fm = 1; next }
        in_fm == 1 && /^---[[:space:]]*$/ { exit }
        in_fm == 1 && /^description:[[:space:]]*/ {
            sub(/^description:[[:space:]]*/, "");
            sub(/^["'"'"']/, ""); sub(/["'"'"']$/, "");
            print; exit
        }
    ' "$file"
}

# Body excerpt: first 40 non-frontmatter lines.
extract_body() {
    local file="$1"
    awk '
        BEGIN { in_fm = 0; seen_fm_end = 0; count = 0 }
        NR == 1 && /^---[[:space:]]*$/ { in_fm = 1; next }
        in_fm == 1 && /^---[[:space:]]*$/ { in_fm = 0; seen_fm_end = 1; next }
        in_fm == 0 && seen_fm_end == 0 && /^---[[:space:]]*$/ { next }
        in_fm == 0 {
            if (count++ < 40) print
            else exit
        }
    ' "$file"
}

# Main
tmp_list=$(mktemp)
trap 'rm -f "$tmp_list"' EXIT
gather > "$tmp_list"
total=$(wc -l < "$tmp_list" | tr -d ' ')

if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY build-skill-index: would scan + write $total items to $OUT_DIR"
    head -20 "$tmp_list" | awk -F'|' '{ printf "  - %s (%s)\n", $3, $1 }'
    [ "$total" -gt 20 ] && echo "  ... ($((total - 20)) more)"
    exit 0
fi

mkdir -p "$OUT_DIR" || { echo "ERR build-skill-index: cannot create $OUT_DIR" >&2; exit 2; }
# Dedup by qualified name; first-seen wins.
declare -A seen 2>/dev/null || true
written=0
while IFS='|' read -r kind plugin qname src; do
    [ -z "$qname" ] && continue
    if [ "${seen[$qname]:-0}" = "1" ]; then
        continue
    fi
    seen[$qname]=1
    safe_name=$(printf '%s' "$qname" | tr ':/' '__')
    out_file="$OUT_DIR/$safe_name.md"
    desc=$(extract_description "$src")
    body=$(extract_body "$src")
    {
        echo "---"
        echo "name: $qname"
        echo "kind: $kind"
        echo "plugin: $plugin"
        echo "invocation: /$(printf '%s' "$qname" | sed 's|.*:||')"
        echo "source: $src"
        echo "---"
        echo
        if [ -n "$desc" ]; then
            echo "**Description:** $desc"
            echo
        fi
        echo "## Body excerpt"
        echo
        echo "$body"
    } > "$out_file"
    written=$((written+1))
done < "$tmp_list"

echo "build-skill-index: wrote $written item files to $OUT_DIR"
echo "Next: qmd ingest --collection skills \"$OUT_DIR\""
exit 0
