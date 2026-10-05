#!/usr/bin/env bash
# pr-range lint -- the PR-path lint for CI's lint job (HIMMEL-4319).
#
# `pre-commit run shellcheck --all-files` is one serial ~9 min shellcheck (the
# hook is require_serial) and cannot be sharded: shellcheck resolves `source`
# across the files of ONE invocation, so SC2034 "unused" verdicts depend on the
# input set. So a PR lints the files it changed PLUS their source-graph
# neighbours — files that source/`.` a changed (or deleted) file, and files a
# changed file sources — in ONE serial run of the SAME hook (its `types` and
# `exclude` still apply to --files).
#
# Fail-safe direction: when in doubt, lint everything (--all-files) if
#   - the diff cannot be computed or a neighbour lookup errors,
#   - a changed file has a source line naming no *.sh/*.bash (dynamic, uncertain),
#   - .pre-commit-config.yaml, .shellcheckrc or the CI workflow changed.
#
# Usage: shellcheck-pr-range.sh [--dry-run] <base-sha>
#   --dry-run prints "ALL <reason>" or "FILES" + the file list, runs nothing.
set -u

dry=0
if [ "${1:-}" = "--dry-run" ]; then dry=1; shift; fi
base="${1:?usage: shellcheck-pr-range.sh [--dry-run] <base-sha>}"

run_all() {
  echo "shellcheck-pr-range: ALL FILES ($1)" >&2
  if [ "$dry" = 1 ]; then echo "ALL $1"; exit 0; fi
  exec pre-commit run shellcheck --all-files --show-diff-on-failure
}

changed=$(git diff --name-only --diff-filter=ACMRTD "$base" HEAD) || run_all "git diff failed"
[ -n "$changed" ] || { echo "shellcheck-pr-range: no changed files" >&2; [ "$dry" = 1 ] && echo "FILES"; exit 0; }

case "
$changed
" in
  *"
.pre-commit-config.yaml
"* | *"
.shellcheckrc
"* | *"
.github/workflows/ci.yml
"*) run_all "lint config or workflow changed" ;;
esac

tracked=$(git ls-files) || run_all "git ls-files failed"
list=$(mktemp "${TMPDIR:-/tmp}/shellcheck-pr-range.XXXXXX") ||run_all "mktemp failed"
trap 'rm -f "$list" "$list.n"' EXIT

esc() { printf '%s' "$1" | sed 's/[][\.*^$+?(){}|/]/\\&/g'; }
src_re='(^|[;&|{(![:space:]])(source|\.)[[:space:]]'

printf '%s\n' "$changed" > "$list"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  b=$(basename "$f")
  # files that source this one (changed, added or deleted)
  git grep -l -E -e "${src_re}.*$(esc "$b")" -- . > "$list.n" 2>/dev/null
  rc=$?
  [ "$rc" -le 1 ] || run_all "git grep failed on $f"
  cat "$list.n" >> "$list"
  # files this one sources (only if it still exists)
  [ -f "$f" ] || continue
  lines=$(grep -E -e "$src_re" "$f" 2>/dev/null | grep -v '^[[:space:]]*#' | sed 's/[[:space:]]#.*$//')
  [ -n "$lines" ] || continue
  # every source line must name a *.sh/*.bash, else the neighbour set is uncertain
  printf '%s\n' "$lines" | grep -qvE '[A-Za-z0-9_.+-]+\.(sh|bash)' && run_all "dynamic source line in $f"
  names=$(printf '%s\n' "$lines" | grep -oE '[A-Za-z0-9_.+-]+\.(sh|bash)')
  printf '%s\n' "$names" | while IFS= read -r n; do
    printf '%s\n' "$tracked" | awk -v n="$n" '{ k=split($0,p,"/"); if (p[k]==n) print }'
  done >> "$list"
done <<EOF
$changed
EOF
# second hop: an untouched lib's SC2034 verdict depends on ALL its consumers being in the input set
hop=$(sort -u "$list")
while IFS= read -r f; do
  [ -n "$f" ] || continue
  git grep -l -E -e "${src_re}.*$(esc "$(basename "$f")")" -- . > "$list.n" 2>/dev/null
  rc=$?
  [ "$rc" -le 1 ] || run_all "git grep failed on $f"
  cat "$list.n" >> "$list"
done <<EOF
$hop
EOF
rm -f "$list.n"

# only paths that exist at HEAD; the hook itself filters by type/exclude
files=$(sort -u "$list" | while IFS= read -r p; do [ -f "$p" ] && printf '%s\n' "$p"; done)
[ -n "$files" ] || { echo "shellcheck-pr-range: nothing lintable (only deletions)" >&2; [ "$dry" = 1 ] && echo "FILES"; exit 0; }

if [ "$dry" = 1 ]; then echo "FILES"; printf '%s\n' "$files"; exit 0; fi
echo "shellcheck-pr-range: $(printf '%s\n' "$files" | wc -l) files (changed + neighbours)" >&2
printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 pre-commit run shellcheck --show-diff-on-failure --files
