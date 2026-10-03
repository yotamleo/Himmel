#!/usr/bin/env bash
# skill-lint.sh — in-tree SKILL.md frontmatter hygiene gate (HIMMEL-3609, v1).
#
# A v1 regression guard, not a platform: three mechanically-checkable rules
# over the repo-owned SKILL.md corpus (frontmatter presence, name==dirname,
# no duplicate name). Description-length policy is NOT this script's job —
# that is the existing `skill-description-cap` pre-commit hook
# (scripts/lanes/skill-cost.mjs --max-desc 120), which is vendoring-aware;
# duplicating it here would be a second, weaker length policy.
#
# In-scope roots (repo-owned, hand-authored SKILL.md):
#   marketplace/plugins/*/skills/*/SKILL.md
#   .claude/skills/*/SKILL.md
#   plugins/himmel-gh/skills/*/SKILL.md
#   plugins/himmel-jira/skills/*/SKILL.md
# Deliberately out of scope: .agents/skills/** (generated Codex-compat
# mirror), the bench-scorecard test fixture, and any externally-sourced
# marketplace skill not vendored in this repo.
#
# Usage:
#   bash scripts/lint/skill-lint.sh              # scan the full in-scope tree
#   bash scripts/lint/skill-lint.sh --staged     # lint the STAGED (index) content
#                                                 # of in-scope SKILL.md paths, not
#                                                 # whatever is currently on disk
#   bash scripts/lint/skill-lint.sh FILE...      # lint exactly the named files
#   bash scripts/lint/skill-lint.sh --help
#
# Checks:
#   [no-frontmatter]  file does not open with a `---`/`---` frontmatter block.
#   [no-name]         frontmatter has no non-empty `name:` field.
#   [no-description]  frontmatter has no non-empty `description:` field.
#   [name-mismatch]   `name:` does not equal the skill's parent directory name.
#   [dup-name]        two or more scanned SKILL.md files share the same
#                     `name:` value (routing collision risk).
#
# Note on [dup-name] scope: duplicates are detected only within the set of
# files actually scanned this run (the full tree by default, or the staged/
# explicit subset otherwise) — mirroring how the rest of this repo's
# pre-commit hooks reason about staged content, and keeping fixture-based
# tests self-contained. CI runs this script over the full tree, so a
# duplicate introduced against an unstaged sibling is still caught there.
#
# Exit: 0 = clean, 1 = findings, 2 = usage error.
# bash 3.2-safe (no arrays); POSIX ERE only.

set -uo pipefail

usage() {
    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
}

# Print the frontmatter's non-empty `name:` value for $1, or nothing.
# Trim whitespace BEFORE stripping quotes, so `name: "foo"  ` (trailing
# spaces after the closing quote) unquotes to `foo`, not `foo"`.
_fm_name() {
    awk '
        NR==1 && /^---[[:space:]]*$/ { in_fm=1; next }
        in_fm && /^---[[:space:]]*$/ { exit }
        in_fm && /^name:/ {
            v = $0
            sub(/^name:/, "", v)
            sub(/^[[:space:]]+/, "", v)
            sub(/[[:space:]]+$/, "", v)
            gsub(/^["'"'"']|["'"'"']$/, "", v)
            print v; exit
        }
    ' "$1"
}

# Print the frontmatter's non-empty `description:` value for $1, or nothing.
# A value that is only a `# comment` (no real content before it) counts as
# empty; a trailing ` # comment` after real content is stripped, not kept.
# The comment is only stripped OUTSIDE quotes: a ` #` inside a quoted scalar is
# content (`description: " # TODO"` is non-empty), and anything after the
# closing quote is discarded (HIMMEL-3949). Double quotes skip a backslash-
# escaped char; single quotes treat a doubled quote as escaped. An unterminated
# quote keeps the rest of the line.
_fm_description() {
    awk -v sq="'" '
        NR==1 && /^---[[:space:]]*$/ { in_fm=1; next }
        in_fm && /^---[[:space:]]*$/ { exit }
        in_fm && /^description:/ {
            v = $0
            sub(/^description:/, "", v)
            sub(/^[[:space:]]+/, "", v)
            q = substr(v, 1, 1)
            if (v ~ /^#/) {
                v = ""
            } else if (q == "\"" || q == sq) {
                n = length(v); out = ""; closed = 0
                for (i = 2; i <= n; i++) {
                    c = substr(v, i, 1)
                    if (q == "\"" && c == "\\") { out = out substr(v, i, 2); i++; continue }
                    if (c == q) {
                        if (q == sq && substr(v, i + 1, 1) == sq) { out = out c c; i++; continue }
                        closed = 1; break
                    }
                    out = out c
                }
                v = out
                if (!closed) sub(/[[:space:]]+$/, "", v)
            } else {
                sub(/[[:space:]]+#.*$/, "", v)
                sub(/[[:space:]]+$/, "", v)
                gsub(/^["'"'"']|["'"'"']$/, "", v)
            }
            print v; exit
        }
    ' "$1"
}

# True if $1 opens with a `---` / `---` frontmatter block.
_has_frontmatter() {
    _first_line="$(head -n1 "$1" 2>/dev/null)"
    [[ "$_first_line" =~ ^---[[:space:]]*$ ]] || return 1
    awk 'NR==1{next} /^---[[:space:]]*$/{found=1; exit} END{exit !found}' "$1"
}

STAGED=0
EXPLICIT=0
# ALTERNATING newline-separated lines (bash 3.2-safe; no arrays): a display
# path on one line, its content path on the next. display-path is what gets
# printed; content-path is what gets linted. They differ only under --staged,
# where content-path is a temp copy of the file's INDEX content, not the
# working-tree file. Not TAB-delimited pairs: a path can hold a TAB (HIMMEL-3949).
# ponytail: a path containing a NEWLINE still mis-splits (bash 3.2 strings cannot hold NUL), upgrade to NUL-delimited `read -d ''` streams if such a path ever needs linting
FILES=""
STAGE_TMP=""
_cleanup_stage_tmp() { [ -n "$STAGE_TMP" ] && rm -rf "$STAGE_TMP" 2>/dev/null; :; }
trap _cleanup_stage_tmp EXIT
while [ $# -gt 0 ]; do
    case "$1" in
        --staged) STAGED=1; shift ;;
        --help|-h) usage; exit 0 ;;
        --) shift; while [ $# -gt 0 ]; do FILES="$FILES$1"$'\n'"$1"$'\n'; EXPLICIT=1; shift; done ;;
        -*) printf 'skill-lint: unknown option: %s\n' "$1" >&2; exit 2 ;;
        *) FILES="$FILES$1"$'\n'"$1"$'\n'; EXPLICIT=1; shift ;;
    esac
done

# In-scope path patterns (ERE, matched against a repo-root-relative path).
IN_SCOPE_RE='^(marketplace/plugins/[^/]+/skills/[^/]+/SKILL\.md|\.claude/skills/[^/]+/SKILL\.md|plugins/(himmel-gh|himmel-jira)/skills/[^/]+/SKILL\.md)$'

_root="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$_root" ] || { printf 'skill-lint: not inside a git work tree\n' >&2; exit 2; }

if [ "$STAGED" -eq 1 ] && [ "$EXPLICIT" -eq 1 ]; then
    printf 'skill-lint: --staged and explicit file args are mutually exclusive\n' >&2
    exit 2
fi

if [ "$STAGED" -eq 1 ]; then
    command -v git >/dev/null 2>&1 || { printf 'skill-lint: --staged needs git on PATH\n' >&2; exit 2; }
    if ! _staged="$(cd "$_root" && git diff --cached --name-only --diff-filter=ACM)"; then
        printf 'skill-lint: --staged: git diff --cached failed\n' >&2; exit 2
    fi
    STAGE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/skill-lint-staged.XXXXXX")" || {
        printf 'skill-lint: --staged: mktemp -d failed\n' >&2; exit 2
    }
    # ponytail: --staged sees C-quoted names for paths with TAB/newline (core.quotePath) and so skips them, switch to `git diff -z` + `read -d ''` if one is ever staged
    while IFS= read -r _f; do
        [ -n "$_f" ] || continue
        [[ "$_f" =~ $IN_SCOPE_RE ]] || continue
        _dest="$STAGE_TMP/$_f"
        mkdir -p "$(dirname "$_dest")"
        if ! (cd "$_root" && git show ":$_f") > "$_dest" 2>/dev/null; then
            printf 'skill-lint: --staged: git show failed for %s\n' "$_f" >&2
            exit 2
        fi
        FILES="$FILES$_root/$_f"$'\n'"$_dest"$'\n'
    done <<EOF
$_staged
EOF
elif [ "$EXPLICIT" -eq 0 ]; then
    # Default: scan the full in-scope tree.
    for _pat in \
        "$_root"/marketplace/plugins/*/skills/*/SKILL.md \
        "$_root"/.claude/skills/*/SKILL.md \
        "$_root"/plugins/himmel-gh/skills/*/SKILL.md \
        "$_root"/plugins/himmel-jira/skills/*/SKILL.md
    do
        for _f in $_pat; do
            [ -f "$_f" ] && FILES="$FILES$_f"$'\n'"$_f"$'\n'
        done
    done
fi

CHECKED=0
MISSING=0
ISSUE_FILES=0
NAMES=""   # newline-separated "name<TAB>file" for the dup-name pass

while IFS= read -r f && IFS= read -r content_src; do
    [ -n "$f" ] || continue
    [ -n "$content_src" ] || content_src="$f"
    if [ ! -f "$content_src" ]; then
        printf 'skill-lint: skipping missing file: %s\n' "$f" >&2
        MISSING=$((MISSING + 1))
        continue
    fi
    CHECKED=$((CHECKED + 1))
    file_issues=0
    file_report=""

    if ! _has_frontmatter "$content_src"; then
        file_report="$file_report  [no-frontmatter] file does not open with a ---/--- frontmatter block"$'\n'
        file_issues=$((file_issues + 1))
    else
        name_val="$(_fm_name "$content_src")"
        desc_val="$(_fm_description "$content_src")"

        if [ -z "$name_val" ]; then
            file_report="$file_report  [no-name] frontmatter has no non-empty name: field"$'\n'
            file_issues=$((file_issues + 1))
        else
            dir_name="$(basename "$(dirname "$f")")"
            if [ "$name_val" != "$dir_name" ]; then
                file_report="$file_report  [name-mismatch] name: '$name_val' != parent directory '$dir_name'"$'\n'
                file_issues=$((file_issues + 1))
            fi
            NAMES="$NAMES$name_val	$f"$'\n'
        fi

        if [ -z "$desc_val" ]; then
            file_report="$file_report  [no-description] frontmatter has no non-empty description: field"$'\n'
            file_issues=$((file_issues + 1))
        fi
    fi

    if [ "$file_issues" -gt 0 ]; then
        ISSUE_FILES=$((ISSUE_FILES + 1))
        printf '%s:\n' "$f"
        printf '%s' "$file_report"
    fi
done <<EOF
$FILES
EOF

# [dup-name] pass — over the same scanned set collected above.
_dup_names="$(printf '%s' "$NAMES" | awk -F'\t' '{print $1}' | sort | uniq -d)"
if [ -n "$_dup_names" ]; then
    while IFS= read -r _dn; do
        [ -n "$_dn" ] || continue
        _dup_files="$(printf '%s' "$NAMES" | awk -F'\t' -v n="$_dn" '$1==n{print substr($0, length($1) + 2)}')"
        printf 'skill-lint: [dup-name] name "%s" claimed by multiple SKILL.md files:\n' "$_dn"
        printf '%s\n' "$_dup_files" | sed 's/^/  /'
        ISSUE_FILES=$((ISSUE_FILES + 1))
    done <<EOF
$_dup_names
EOF
fi

if [ "$EXPLICIT" -eq 1 ] && [ "$CHECKED" -eq 0 ] && [ "$MISSING" -gt 0 ]; then
    printf 'skill-lint: none of the named files exist (%d missing) — checked nothing\n' "$MISSING" >&2
    exit 2
fi

if [ "$ISSUE_FILES" -gt 0 ]; then
    printf 'skill-lint: %d issue(s) found — fix before committing\n' "$ISSUE_FILES"
    exit 1
fi
printf 'skill-lint: clean (%d file(s) checked)\n' "$CHECKED"
