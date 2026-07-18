#!/usr/bin/env bash
# sessions-reindex.sh - connect auto-captured session notes into the vault graph.
#
# The end-session-wiki hook files a note per Claude session under
# <vault>/sessions/YYYY/MM/ but does NOT maintain an index, so each note is an
# orphan (no inbound links) and its `[[<repo>]]` preamble link dangles until a
# hub note exists. This script (lean-invoke; run on demand or on the
# pipeline-cadence) fixes both, idempotently:
#
#   1. Regenerates <vault>/sessions/_index.md linking every session note,
#      grouped by month (gives each note an inbound link -> not an orphan).
#   2. Ensures a hub note <vault>/sessions/<repo>.md exists for each distinct
#      `repo:` value (resolves the `[[<repo>]]` links). Existing hubs are left
#      untouched - only missing ones are created, and never when a note of that
#      basename already resolves elsewhere in the vault.
#
# A "session note" is any *.md under sessions/ with `type: session` in
# frontmatter; index/hub notes (type: backfill-index / repo-hub, or any
# basename starting with "_") are skipped.
#
# Usage: sessions-reindex.sh [--vault <path>]   (default: ~/Documents/luna)
set -uo pipefail

VAULT="${HOME}/Documents/luna"
while [ $# -gt 0 ]; do
    case "$1" in
        --vault) VAULT="$2"; shift 2 ;;
        -h|--help) sed -n '2,/^set /p' "$0" | sed '$d'; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done
# Expand a leading tilde (a CLI value can't rely on shell tilde expansion):
# bare "~" -> $HOME, and "~/..." -> "$HOME/...".
# shellcheck disable=SC2088  # the "~" patterns are literal case-pattern matches, not expansions
case "$VAULT" in
    "~")    VAULT="$HOME" ;;
    "~/"*)  VAULT="${HOME}/${VAULT#\~/}" ;;
esac

SESS="${VAULT}/sessions"
if [ ! -d "$SESS" ]; then
    echo "sessions-reindex: no sessions/ dir under $VAULT - nothing to do" >&2
    exit 0
fi

tmp_rows="$(mktemp)"; repos="$(mktemp)"; allmd="$(mktemp)"
trap 'rm -f "$tmp_rows" "$repos" "$allmd"' EXIT

# Build the vault-wide markdown basename list ONCE (used for hub-existence
# checks below, so we don't re-`find` the whole vault per repo).
find "$VAULT" -type f -name '*.md' -not -path '*/.git/*' -not -path '*/.worktrees/*' 2>/dev/null \
    | sed 's#.*/##' > "$allmd"

# read_fm <file> — emit "type<TAB>repo<TAB>date" read ONLY from the YAML
# frontmatter block (first `---` to the next `---`), in a single awk pass.
# Scoping to the block avoids matching `type:`/`repo:`/`date:` lines that appear
# in a note's body (e.g. quoted transcript text); one process per file, not six.
read_fm() {
    awk '
        NR==1 && $0 !~ /^---[[:space:]]*$/ { exit }
        NR==1 { infm=1; next }
        infm && $0 ~ /^---[[:space:]]*$/ { exit }
        infm && /^type:/ { v=$0; sub(/^type:[[:space:]]*/,"",v); gsub(/\r/,"",v); t=v }
        infm && /^repo:/ { v=$0; sub(/^repo:[[:space:]]*/,"",v); gsub(/\r/,"",v); r=v }
        infm && /^date:/ { v=$0; sub(/^date:[[:space:]]*/,"",v); gsub(/\r/,"",v); d=v }
        END { printf "%s\t%s\t%s", t, r, d }
    ' "$1" 2>/dev/null
}

# --- 1. Collect session notes -------------------------------------------------
count=0
while IFS= read -r f; do
    base="${f##*/}"
    case "$base" in _*) continue ;; esac           # skip _index / _backfill / etc.
    IFS=$'\t' read -r ftype repo d < <(read_fm "$f")
    [ "$ftype" = "session" ] || continue
    [ -n "$repo" ] || repo="unknown-repo"
    ym="${d:0:7}"                                   # YYYY-MM from ISO date
    case "$ym" in [0-9][0-9][0-9][0-9]-[0-9][0-9]) : ;; *) ym="undated" ;; esac
    printf '%s\t%s\t%s\t%s\n' "$ym" "$d" "${base%.md}" "$repo" >> "$tmp_rows"
    printf '%s\n' "$repo" >> "$repos"
    count=$((count + 1))
done < <(find "$SESS" -type f -name '*.md')

if [ "$count" -eq 0 ]; then
    echo "sessions-reindex: no session notes found under $SESS" >&2
    exit 0
fi

# --- 2. Ensure a hub note per repo -------------------------------------------
hubs_created=0
while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    # Skip if a note named <repo>.md already exists ANYWHERE in the vault: then
    # [[<repo>]] already resolves, and a new sessions/<repo>.md would be a
    # duplicate basename (ambiguous link + a vault-health duplicate flag).
    grep -qxF "${repo}.md" "$allmd" && continue
    hub="${SESS}/${repo}.md"
    cat > "$hub" <<EOF
---
type: repo-hub
repo: ${repo}
tags:
  - session
  - hub
ai-first: true
---

# ${repo}

Hub for auto-captured Claude Code session notes from the \`${repo}\` repo. Each
session note under \`sessions/\` links here via \`[[${repo}]]\`; the full list is
in [[_index]].
EOF
    hubs_created=$((hubs_created + 1))
done < <(sort -u "$repos")

# --- 3. Regenerate _index.md --------------------------------------------------
INDEX="${SESS}/_index.md"
{
    printf -- '---\ntype: session-index\ngenerated: sessions-reindex\ncount: %s\ntags:\n  - session\n  - index\nai-first: true\n---\n\n' "$count"
    printf '# Session Notes\n\n'
    # List repo hubs inline.
    hub_links=""
    while IFS= read -r repo; do
        [ -n "$repo" ] || continue
        if [ -z "$hub_links" ]; then hub_links="[[${repo}]]"; else hub_links="${hub_links}, [[${repo}]]"; fi
    done < <(sort -u "$repos")
    printf 'Auto-generated by scripts/sessions-reindex.sh - links every captured session note so none are orphaned. Re-run after new captures. Repo hubs: %s.\n\n' "$hub_links"
    # Group by month, newest first.
    prev_ym=""
    while IFS=$'\t' read -r ym d base repo; do
        if [ "$ym" != "$prev_ym" ]; then
            printf '\n## %s\n\n' "$ym"
            prev_ym="$ym"
        fi
        printf -- '- [[%s]]\n' "$base"
    done < <(sort -t"$(printf '\t')" -k1,1r -k2,2r "$tmp_rows")
} > "$INDEX"

echo "sessions-reindex: indexed $count session note(s) into ${INDEX#"$VAULT"/}; hubs created: $hubs_created"
