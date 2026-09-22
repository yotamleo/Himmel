#!/usr/bin/env bash
# Drift test for pr-check-context.sh's cr_guarded set (HIMMEL-3493).
#
# On a step-0 cr_diff_state=no verdict himmel_dir stays at the BRANCH, so
# every script a later /pr-check step runs through <himmel_dir> - and every
# file those scripts source or exec - runs the branch's bytes. "no" is only
# safe if all of those files lie inside cr_guarded (the paths the step-0 diff
# and byte manifest cover). This suite DERIVES that closure instead of
# trusting a hand-kept list:
#   seeds = every <himmel_dir>/scripts/... target named in the runbook twins
#           + every non-test script at the top of scripts/cr/;
#   edges = source/exec sites (`.`, source, bash, sh, node, python3, exec)
#           on non-comment lines, plus relative JS require/import;
# and fails when a reached file exists outside cr_guarded. On a failure,
# widen cr_guarded (and cr_pathspecs, and the runbook precheck) or prove the
# site is not reached on the "no" path.
#
# ponytail: the edge extraction is lexical. A path assembled at runtime from
# pieces that never appear as one `<prefix>/<name>.<ext>` literal on the
# source/exec line is invisible to it; the whole-directory entries in
# cr_guarded (scripts/cr, scripts/lib) are what keep that gap fail-safe.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"

fail=0
pass=0
check() { if [ "$1" = "$2" ]; then pass=$((pass + 1)); else echo "FAIL: $3 - got '$1' want '$2'"; fail=1; fi; }

# normalize <repo-relative path> - collapse `.` and `..` segments (portable:
# no realpath -m on macOS).
normalize() {
  local IFS=/ seg out=()
  set -f
  # shellcheck disable=SC2086  # deliberate split on /
  set -- $1
  set +f
  for seg in "$@"; do
    case "$seg" in
      ''|.) ;;
      ..) [ "${#out[@]}" -gt 0 ] && unset 'out[${#out[@]}-1]' ;;
      *) out+=("$seg") ;;
    esac
  done
  printf '%s\n' "${out[*]}"
}

# edges <repo-relative file> - print each repo-relative path the file
# sources or execs (existing files only).
PATH_RE='(\$\{?[A-Za-z_][A-Za-z0-9_]*\}?|[)}])?/?[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*\.(sh|js|mjs|cjs|py)'
edges() {
  local f="$1" dir raw tail target
  dir="$(dirname "$f")"
  {
    grep -E '(^|[;&|({[:space:]])(\.|source|bash|sh|node|python3|exec)[[:space:]]' "$ROOT/$f" 2>/dev/null \
      | grep -vE '^[[:space:]]*#' | grep -oE "$PATH_RE"
    grep -oE "(require\\(|from[[:space:]]+|import[[:space:]]+)['\"]\\.{1,2}/[^'\"]+['\"]" "$ROOT/$f" 2>/dev/null \
      | grep -oE "\\.{1,2}/[^'\"]+"
  } | while IFS= read -r raw; do
    tail="$raw"
    case "$tail" in
      '$'*|')'*|'}'*) tail="/${tail#*/}" ;;
    esac
    case "$tail" in
      /scripts/*|scripts/*) target="$(normalize "${tail#/}")" ;;
      *) target="$(normalize "$dir/${tail#/}")" ;;
    esac
    [ -f "$ROOT/$target" ] && printf '%s\n' "$target"
  done | sort -u
}

# closure - the transitive set of files reached from the seeds.
closure() {
  local seen="" queue f e
  queue="$(
    grep -ohE '<himmel_dir>/scripts/[A-Za-z0-9_./-]+\.(sh|js|mjs|py)' \
      "$ROOT/.claude/commands/pr-check.md" "$ROOT/.agents/skills/pr-check/SKILL.md" \
      | sed 's#^<himmel_dir>/##'
    for f in "$ROOT"/scripts/cr/*.sh "$ROOT"/scripts/cr/*.js "$ROOT"/scripts/cr/*.mjs; do
      [ -f "$f" ] || continue
      case "$(basename "$f")" in test-*) continue ;; esac
      printf '%s\n' "${f#"$ROOT"/}"
    done
  )"
  while [ -n "$queue" ]; do
    f="${queue%%$'\n'*}"
    if [ "$f" = "$queue" ]; then queue=""; else queue="${queue#*$'\n'}"; fi
    [ -f "$ROOT/$f" ] || continue
    grep -qxF -- "$f" <<< "$seen" && continue
    seen="$seen$f"$'\n'
    for e in $(edges "$f"); do
      grep -qxF -- "$e" <<< "$seen" || queue="${queue:+$queue$'\n'}$e"
    done
  done
  printf '%s' "$seen" | sort -u
}

# outside <guarded list> <<closure - print each closure file not under a
# guarded entry (a directory entry covers everything below it).
outside() {
  local guarded="$1" f g hit
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    hit=no
    for g in $guarded; do
      case "$f" in "$g"|"$g"/*) hit=yes; break ;; esac
    done
    [ "$hit" = no ] && printf '%s\n' "$f"
  done
}

# The set under test, parsed from the script itself.
cr_guarded="$(sed -n 's/^cr_guarded="\(.*\)"$/\1/p' "$DIR/pr-check-context.sh")"
check "$([ -n "$cr_guarded" ] && echo parsed || echo empty)" "parsed" "cr_guarded parsed from pr-check-context.sh"

# Every guarded entry has a matching :(top) pathspec, and no pathspec names a
# path cr_guarded does not (the diff and the manifest must cover one set).
pathspec_block="$(sed -n '/^cr_pathspecs=(/,/)$/p' "$DIR/pr-check-context.sh")"
for g in $cr_guarded; do
  if [ -d "$ROOT/$g" ]; then want=":(top)$g/"; else want=":(top)$g"; fi
  check "$(printf '%s\n' "$pathspec_block" | grep -cF "'$want'")" "1" "cr_pathspecs carries '$want' for cr_guarded entry $g"
done
n_specs="$(printf '%s\n' "$pathspec_block" | grep -oE "':\\(top\\)[^']+'" | grep -c .)"
n_guarded="$(printf '%s\n' "$cr_guarded" | tr ' ' '\n' | grep -c .)"
check "$n_specs" "$n_guarded" "cr_pathspecs has exactly one :(top) include per cr_guarded entry"

reached="$(closure)"
echo "closure ($(printf '%s\n' "$reached" | grep -c .) files reached from the runbook and scripts/cr):"
printf '%s\n' "$reached" | grep -v '^scripts/cr/' | sed 's/^/  /'

# Sanity: the derivation actually reaches the known non-scripts/cr sites, so
# an empty or truncated closure cannot pass vacuously.
for known in scripts/check-ci.sh scripts/handover/resolve-active-item.sh scripts/lib/handover-path.sh scripts/lib/load-dotenv.sh scripts/guardrails/lib.sh; do
  check "$(printf '%s\n' "$reached" | grep -cxF "$known")" "1" "closure reaches $known"
done

escaped="$(printf '%s\n' "$reached" | outside "$cr_guarded")"
check "$escaped" "" "every file reached on the no path lies inside cr_guarded"

# RED control: the pre-HIMMEL-3493 set must fail this suite's own assertion,
# naming a scripts/lib/ file - proving the check depends on the set.
red="$(printf '%s\n' "$reached" | outside "scripts/cr scripts/guardrails/lib.sh")"
if grep -qxF scripts/lib/load-dotenv.sh <<< "$red"; then
  echo "RED control confirmed: the pre-HIMMEL-3493 set (scripts/cr scripts/guardrails/lib.sh) leaves $(printf '%s\n' "$red" | grep -c .) reached files unguarded, incl. scripts/lib/load-dotenv.sh"
  pass=$((pass + 1))
else
  echo "FAIL: RED control - the pre-HIMMEL-3493 set was not caught (got: $red)"
  fail=1
fi

echo "test-cr-guarded-closure: $pass passed, fail=$fail"
exit "$fail"
