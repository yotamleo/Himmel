#!/usr/bin/env bash
# pr-range lint -- the PR-path lint for CI's lint job.
#
# `pre-commit run shellcheck --all-files` is one serial ~9 min shellcheck (the
# hook is require_serial) and cannot be sharded: shellcheck resolves `source`
# across the files of ONE invocation, so SC2034 "unused" verdicts depend on the
# input set. So a PR lints the files it changed PLUS their source-graph
# neighbours — files that source/`.` a changed (or deleted) file, and files a
# changed file sources — through the SAME hook (its `types` and `exclude` still
# apply to --files). "Changed" is the PR's own diff against its merge base, and the
# selected set is sharded by source-graph component and linted in parallel
# (sweep_all), with selection and lint timings printed.
#
# Fail-safe direction: when in doubt, lint everything (--all-files) if
#   - the diff cannot be computed or a neighbour lookup errors,
#   - a changed file has a source line naming no *.sh/*.bash (dynamic, uncertain),
#   - .pre-commit-config.yaml, a .shellcheckrc/shellcheckrc at ANY depth (the nearest
#     rc shadows the root one for untouched files), the CI workflow or this script changed,
#   - a changed path contains a newline anywhere, or a neighbour path needs quoting.
# Renames are split into delete+add (--no-renames) so the old path's consumers are
# found, and `# shellcheck source=` directive edges count as source edges.
#
# Usage: shellcheck-pr-range.sh [--dry-run] <base-sha>
#   --dry-run prints "ALL <reason>" or "FILES" + the file list, runs nothing.
set -u

dry=0
if [ "${1:-}" = "--dry-run" ]; then dry=1; shift; fi
base="${1:?usage: shellcheck-pr-range.sh [--dry-run] <base-sha>}"

src_re='(^|[;&|{(![:space:]])(source|\.)[[:space:]]'
dir_re='shellcheck[[:space:]].*source='

run_all() {
  echo "shellcheck-pr-range: ALL FILES ($1)" >&2
  if [ "$dry" = 1 ]; then echo "ALL $1"; exit 0; fi
  sweep_all
}

# The full sweep, sharded by source-graph component and run in parallel. One serial
# `--all-files` is ~8 min unloaded and overran the lint job's cap on a loaded runner.
# Lint verdicts depend on the input set (a lib's SC2034 needs ALL its consumers
# beside it; a single-file or arbitrary shard goes falsely red), so a shard is a whole
# connected component of the source/`.`/`# shellcheck source=` graph, edges resolved by
# path suffix, else same directory, else basename. An over-merged component only costs
# speed. Components are packed largest-first onto nproc bins, one `pre-commit --files`
# per bin; the exit status is the first non-zero bin's. Anything unplannable -> serial.
# `sweep_all <files>` shards just that newline-separated list (the PR's selected set, already
# closed under its source neighbours); with no argument it shards the whole tree.
subset=""
serial_sweep() {
  if [ -n "$subset" ]; then
    printf '%s\n' "$subset" | tr '\n' '\0' | xargs -0 pre-commit run shellcheck --show-diff-on-failure --files
    exit $?
  fi
  exec pre-commit run shellcheck --all-files --show-diff-on-failure
}
sweep_all() {
  local n sd i r rc=0 plan
  [ $# -eq 0 ] || subset=$1
  t_lint=$SECONDS
  n=$(nproc 2>/dev/null) || n=1 # swallow-ok: no nproc means no parallelism, the serial sweep runs
  [ "${n:-1}" -gt 1 ] 2>/dev/null || serial_sweep
  sd=$(mktemp -d "${TMPDIR:-/tmp}/shellcheck-pr-range.XXXXXX") || serial_sweep
  if [ -n "$subset" ]; then plan=$subset; else plan=$(git ls-files) || serial_sweep; fi
  case "$plan" in '"'* | *'
"'*) rm -rf "$sd"; serial_sweep ;; esac
  printf '%s\n' "$plan" > "$sd/files" || { rm -rf "$sd"; serial_sweep; }
  git grep -n -I -E -e "$src_re" -e "$dir_re" -- . > "$sd/grep" 2>/dev/null || [ "$?" -eq 1 ] || { rm -rf "$sd"; serial_sweep; }
  awk '
    function find(x) { while (p[x] != x) { p[x] = p[p[x]]; x = p[x] } return x }
    function join(a, b) { a = find(a); b = find(b); if (a != b) p[a] = b }
    FNR == NR { n++; f[n] = $0; p[$0] = $0; k = split($0, q, "/"); byname[q[k]] = byname[q[k]] "\n" $0; next }
    {
      i = index($0, ":"); file = substr($0, 1, i - 1); rest = substr($0, i + 1); sub(/^[0-9]+:/, "", rest)
      if (!(file in p)) next
      if (rest ~ /^[[:space:]]*#/ && rest !~ /shellcheck[[:space:]]+source=/) next
      d = file; sub(/[^\/]*$/, "", d)
      while (match(rest, /[A-Za-z0-9_.\/+-]*[A-Za-z0-9_+-]\.(sh|bash)/)) {
        nm = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
        sub(/^(\.\.?\/)+/, "", nm); sub(/^\/+/, "", nm)
        k = split(nm, q, "/"); base = q[k]
        if (k == 1 && ((d base) in p)) { join(file, d base); continue }
        m = split(byname[base], c, "\n")
        for (j = 1; j <= m; j++) if (c[j] != "" && (k == 1 || c[j] == nm || substr(c[j], length(c[j]) - length(nm)) == "/" nm)) join(file, c[j])
      }
    }
    END {
      for (i = 1; i <= n; i++) size[find(f[i])]++
      for (i = 1; i <= n; i++) { r = find(f[i]); printf "%d\t%s\t%s\n", size[r], r, f[i] }
    }' "$sd/files" "$sd/grep" | sort -t "$(printf '\t')" -k1,1nr -k2,2 | awk -F '\t' -v P="$n" -v sd="$sd" '
    $2 != last { last = $2; b = 1; for (i = 2; i <= P; i++) if (load[i] < load[b]) b = i }
    { load[b]++; print $3 >> (sd "/bin." b) }' || { rm -rf "$sd"; serial_sweep; }
  set -- "$sd"/bin.*
  [ -f "$1" ] || { rm -rf "$sd"; serial_sweep; }
  # every tracked file must land in exactly one shard, else a pass would be vacuous
  [ "$(cat "$sd"/bin.* | wc -l)" -eq "$(wc -l < "$sd/files")" ] || { rm -rf "$sd"; serial_sweep; }
  echo "shellcheck-pr-range: parallel full sweep over $# shards" >&2
  # xargs splits past ~128 KB of arguments, which would cut a component across runs
  for i in "$sd"/bin.*; do
    [ "$(wc -c < "$i")" -le 100000 ] || { rm -rf "$sd"; serial_sweep; }
  done
  for i in "$sd"/bin.*; do
    ( set -o pipefail; tr '\n' '\0' < "$i" | xargs -0 pre-commit run shellcheck --show-diff-on-failure --files > "$i.out" 2>&1; echo $? > "$i.rc" ) &
  done
  wait
  # iterate the bins, not their outputs: a bin with no rc (its subshell died) is a failure
  for i in "$sd"/bin.[0-9]*; do
    case "$i" in *.out | *.rc) continue ;; esac
    cat "$i.out" 2>/dev/null || [ "$rc" -ne 0 ] || rc=1 # swallow-ok: a missing output means the bin never ran
    r=$(cat "$i.rc" 2>/dev/null) || r=1 # swallow-ok: a missing rc is a failed bin
    case "$r" in '' | *[!0-9]*) r=1 ;; esac
    [ "$rc" -ne 0 ] || rc=$r
  done
  rm -rf "$sd"
  echo "shellcheck-pr-range: lint took $((SECONDS - t_lint))s" >&2
  exit "$rc"
}

# -z + quotePath=false: a non-ASCII path must reach the lint verbatim; a NUL count that
# disagrees with the line count means a newline in a name -> uncertain.
git() { command git -c core.quotePath=false "$@"; }
dz=$(mktemp "${TMPDIR:-/tmp}/shellcheck-pr-range.XXXXXX") || run_all "mktemp failed"
trap 'rm -f "$dz"' EXIT
# The PR's OWN diff against its merge base (three-dot), so commits merged forward from main are
# not re-linted. On a pull_request run HEAD is GitHub's merge ref, whose parents are the base
# branch tip (^1) and the PR head (^2): a rerun reuses the event's stale base.sha, so base..HEAD
# would span every main commit since, while ^1...^2 is exactly the PR's own change.
t_sel=$SECONDS
if [ "${GITHUB_EVENT_NAME:-}" = pull_request ] && git rev-parse -q --verify 'HEAD^2' > /dev/null && ! git rev-parse -q --verify 'HEAD^3' > /dev/null; then
  git diff -z --no-renames --name-only --diff-filter=ACMRTD 'HEAD^1...HEAD^2' > "$dz" || run_all "git diff failed"
else
  git diff -z --no-renames --name-only --diff-filter=ACMRTD "$base...HEAD" > "$dz" || run_all "git diff failed"
fi
changed=$(tr '\0' '\n' < "$dz")
[ "$(tr -d '\0' < "$dz" | wc -c)" -eq "$(tr -d '\0\n' < "$dz" | wc -c)" ] || run_all "newline in a changed path"
[ -n "$changed" ] || { echo "shellcheck-pr-range: no changed files" >&2; [ "$dry" = 1 ] && echo "FILES"; exit 0; }

case "
$changed
" in
  *"
.pre-commit-config.yaml
"* | *"
.shellcheckrc
"* | *"
shellcheckrc
"* | *"/.shellcheckrc
"* | *"/shellcheckrc
"* | *"
.github/workflows/ci.yml
"* | *"
scripts/ci/shellcheck-pr-range.sh
"*) run_all "lint config, workflow or the range script changed" ;;
esac

tracked=$(git ls-files) || run_all "git ls-files failed"
list=$(mktemp "${TMPDIR:-/tmp}/shellcheck-pr-range.XXXXXX") ||run_all "mktemp failed"
trap 'rm -f "$dz" "$list" "$list.n" "$list.g"' EXIT
# every source/. line and `# shellcheck source=` directive in the tree, grepped ONCE: the
# closure below looks consumers up in this file instead of re-grepping the tree per file
case "$tracked" in *:*) run_all "a tracked path contains a colon" ;; esac
git grep -n -I -E -e "$src_re" -e "$dir_re" -- . > "$list.g" 2>/dev/null || [ "$?" -eq 1 ] || run_all "git grep failed"

# keep only lines whose source/. sits at command position OUTSIDE quotes: a `.` inside a jq
# or sed program is not a source command. Quoted spans are blanked for the test only; the
# kept line is the original, so its file names still count. ponytail: per-line, so a
# string spanning lines is not blanked, upgrade path is a real shell tokenizer.
cmd_pos() {
  local l b
  # one left-to-right scan, so an apostrophe inside a double-quoted span opens nothing; a
  # double-quoted span holding $( or a backtick is executable, so the scan stops there
  local prog=':a; s/^(([^"\x27\\]|\\.)*)("([^"\\$`]|\\.|\$[^("\\])*"|\x27[^\x27]*\x27)/\1_/; ta'
  while IFS= read -r l; do
    b=$(printf '%s\n' "$l" | sed -E "$prog")
    printf '%s\n' "$b" | grep -qE -e "$src_re" && printf '%s\n' "$l"
  done
  return 0
}
# consumers of $1: a source/. line or a `# shellcheck source=` directive naming it
consumers() { N="$1" awk '{ c = $0; sub(/^[^:]*:[0-9]+:/, "", c); if (index(c, ENVIRON["N"])) { sub(/:.*/, ""); print } }' "$list.g" | sort -u > "$list.n"; }

printf '%s\n' "$changed" > "$list"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  b=$(basename "$f")
  # files that source this one (changed, added or deleted)
  consumers "$b"
  rc=$?
  [ "$rc" -le 1 ] || run_all "git grep failed on $f"
  cat "$list.n" >> "$list"
  # files this one sources (only if it still exists)
  [ -f "$f" ] || continue
  # directive targets: `# shellcheck source=<path>` names a file shellcheck follows
  grep -E -e "^[[:space:]]*#[[:space:]]*${dir_re}" "$f" 2>/dev/null | sed 's/.*source=//; s/[[:space:]].*$//' | grep -v '^/dev/null$' | while IFS= read -r d; do
    d=${d##*/}
    [ -n "$d" ] && printf '%s\n' "$tracked" | awk -v n="$d" '{ k=split($0,p,"/"); if (p[k]==n) print }'
  done >> "$list"
  # a source line under a `# shellcheck source=<x>.sh` directive is static: the directive names its
  # target (the directive loop above added that edge); comment lines in between, such as a stacked
  # `# shellcheck disable=`, do not break the cover, a blank or code line does
  mark=$(printf '\001')
  lines=$(sed -E "/^[[:space:]]*#[[:space:]]*shellcheck[[:space:]].*source=[^[:space:]]+\.(sh|bash)([[:space:]]|\$)/{:a;n;/^[[:space:]]*#/ba;s/^/$mark/;}" "$f" 2>/dev/null | grep -E -e "$src_re" | grep -v "^$mark" | grep -v '^[[:space:]]*#' | sed 's/[[:space:]]#.*$//' | cmd_pos)
  [ -n "$lines" ] || continue
  # every source line must name a *.sh/*.bash, else the neighbour set is uncertain
  printf '%s\n' "$lines" | grep -qvE '[A-Za-z0-9_.+-]+\.(sh|bash)' && run_all "dynamic source line in $f"
  # a name glued to a variable expansion ("${D}x.sh", "$N.sh") passes the check above but is dynamic
  printf '%s\n' "$lines" | grep -qE '(\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*)[A-Za-z0-9_.+-]*\.(sh|bash)' && run_all "variable-glued source name in $f"
  names=$(printf '%s\n' "$lines" | grep -oE '[A-Za-z0-9_.+-]+\.(sh|bash)')
  printf '%s\n' "$names" | while IFS= read -r n; do
    printf '%s\n' "$tracked" | awk -v n="$n" '{ k=split($0,p,"/"); if (p[k]==n) print }'
  done >> "$list"
done <<EOF
$changed
EOF
# closure: an untouched lib's SC2034 verdict depends on ALL its consumers being in the input set,
# and a consumer's own verdict on ITS consumers -- iterate until no new file appears (bounded)
done_set=""
i=0
while :; do
  i=$((i + 1))
  [ "$i" -le 20 ] || run_all "neighbour closure did not converge"
  cur=$(sort -u "$list")
  todo=$(printf '%s\n' "$cur" | grep -vxF -e "$done_set" -e '' || true)
  [ -n "$todo" ] || break
  done_set=$cur
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    consumers "$(basename "$f")"
    rc=$?
    [ "$rc" -le 1 ] || run_all "git grep failed on $f"
    cat "$list.n" >> "$list"
  done <<EOF
$todo
EOF
done
rm -f "$list.n"

# a quoted path (special chars) cannot be matched back to a file: lint everything
grep -q '^"' "$list" && run_all "path needing quotes in the neighbour set"
# only paths that exist at HEAD; the hook itself filters by type/exclude
files=$(sort -u "$list" | while IFS= read -r p; do [ -f "$p" ] && printf '%s\n' "$p"; done)
[ -n "$files" ] || { echo "shellcheck-pr-range: nothing lintable (only deletions)" >&2; [ "$dry" = 1 ] && echo "FILES"; exit 0; }

if [ "$dry" = 1 ]; then echo "shellcheck-pr-range: selection took $((SECONDS - t_sel))s" >&2; echo "FILES"; printf '%s\n' "$files"; exit 0; fi
echo "shellcheck-pr-range: $(printf '%s\n' "$files" | wc -l) files (changed + neighbours), selection took $((SECONDS - t_sel))s" >&2
sweep_all "$files"
