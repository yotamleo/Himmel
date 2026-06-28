#!/usr/bin/env bash
# Hermetic test suite for scripts/lib/doc-freshness.sh (HIMMEL-587).
# Builds throwaway git repos; asserts findings + always-exit-0. Exit 0 if all pass.
# shellcheck disable=SC2034,SC2016,SC2317,SC2329,SC1090
set -uo pipefail
LIBDIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$LIBDIR/doc-freshness.sh"
_fail=0
run_test() { local name="$1" body="$2" rc=0; ( eval "$body" ) || rc=$?; if [ "$rc" -eq 0 ]; then printf '  PASS  %s\n' "$name"; else printf '  FAIL  %s (rc=%s)\n' "$name" "$rc"; _fail=$((_fail+1)); fi; }

# A repo carrying himmel's 4-col map (BOTH advise rows, critic #1) at
# scripts/hooks/doc-guard-map.tsv and the mapped advise docs, so project-relative
# resolution works. init -b main for portability (critic #6).
setup_repo() {
  R=$(mktemp -d); git -C "$R" init -q -b main
  git -C "$R" config user.email t@t; git -C "$R" config user.name t
  mkdir -p "$R/scripts/hooks" "$R/scripts/jira" "$R/docs/internals"
  printf '# strength\ttrigger\tpath-regex\trequired-doc\n'                        >  "$R/scripts/hooks/doc-guard-map.tsv"
  printf 'advise\tmodify\t^scripts/hooks/\tdocs/internals/enforcement.md\n'       >> "$R/scripts/hooks/doc-guard-map.tsv"
  printf 'advise\tmodify\t^scripts/(jira|bitbucket)/\tdocs/internals/jira-plugin.md\n' >> "$R/scripts/hooks/doc-guard-map.tsv"
  : > "$R/docs/internals/enforcement.md"
  : > "$R/docs/internals/jira-plugin.md"
  git -C "$R" add -A; git -C "$R" commit -q -m "chore: seed"
  BASE=$(git -C "$R" rev-parse HEAD)
}

detect() { ( . "$LIB"; df_detect "$@" ); }

run_test "drift-catch: feat touches mapped source, doc untouched → finding" '
  setup_repo
  echo x >> "$R/scripts/hooks/some-hook.sh"
  git -C "$R" add -A; git -C "$R" commit -q -m "feat: add hook"
  out=$(cd "$R" && detect "$BASE..HEAD"); rc=$?
  [ "$rc" -eq 0 ] || exit 1
  printf "%s" "$out" | grep -q "docs/internals/enforcement.md" || exit 1
'

run_test "doc-presence suppression: doc ALSO touched → no finding" '
  setup_repo
  echo x >> "$R/scripts/hooks/some-hook.sh"
  echo y >> "$R/docs/internals/enforcement.md"
  git -C "$R" add -A; git -C "$R" commit -q -m "feat: add hook + doc"
  out=$(cd "$R" && detect "$BASE..HEAD")
  [ -z "$out" ] || exit 1
'

run_test "changelog scoping: chore-only change → no finding" '
  setup_repo
  echo x >> "$R/scripts/hooks/some-hook.sh"
  git -C "$R" add -A; git -C "$R" commit -q -m "chore: tweak hook"
  out=$(cd "$R" && detect "$BASE..HEAD")
  [ -z "$out" ] || exit 1
'

run_test "mixed feat+chore on same file → shippable wins → finding" '
  setup_repo
  echo a >> "$R/scripts/hooks/some-hook.sh"
  git -C "$R" add -A; git -C "$R" commit -q -m "chore: tweak"
  echo b >> "$R/scripts/hooks/some-hook.sh"
  git -C "$R" add -A; git -C "$R" commit -q -m "feat: extend"
  out=$(cd "$R" && detect "$BASE..HEAD")
  printf "%s" "$out" | grep -q "enforcement.md" || exit 1
'

run_test "SECOND advise row fires under set -e (critic #1): jira change → jira-plugin.md" '
  setup_repo
  echo x >> "$R/scripts/jira/thing.ts"
  git -C "$R" add -A; git -C "$R" commit -q -m "feat: jira thing"
  # Run the detect under set -e exactly like the real consumers, to prove the
  # first (non-matching ^scripts/hooks/) row does not abort the loop.
  out=$( cd "$R" && ( set -euo pipefail; . "$LIB"; df_detect "$BASE..HEAD" ) ); rc=$?
  [ "$rc" -eq 0 ] || exit 1
  printf "%s" "$out" | grep -q "docs/internals/jira-plugin.md" || exit 1
'

run_test "missing map → inert, exit 0, no output" '
  setup_repo; rm -f "$R/scripts/hooks/doc-guard-map.tsv"
  echo x >> "$R/scripts/hooks/some-hook.sh"
  git -C "$R" add -A; git -C "$R" commit -q -m "feat: x"
  out=$(cd "$R" && detect "$BASE..HEAD"); rc=$?
  [ "$rc" -eq 0 ] && [ -z "$out" ]
'

run_test "all-rows-inert (target docs absent) → warn once on stderr, no finding" '
  setup_repo; rm -f "$R/docs/internals/enforcement.md" "$R/docs/internals/jira-plugin.md"
  echo x >> "$R/scripts/hooks/some-hook.sh"
  git -C "$R" add -A; git -C "$R" commit -q -m "feat: x"
  err=$(cd "$R" && ( . "$LIB"; df_detect "$BASE..HEAD" ) 2>&1 >/dev/null)
  rc=$?; [ "$rc" -eq 0 ] || exit 1
  printf "%s" "$err" | grep -qi "no live advise rows" || exit 1
'

run_test "range parameterization: three-dot range works" '
  setup_repo
  git -C "$R" checkout -q -b feat/x
  echo x >> "$R/scripts/hooks/some-hook.sh"
  git -C "$R" add -A; git -C "$R" commit -q -m "feat: add hook"
  out=$(cd "$R" && detect "main...HEAD")
  printf "%s" "$out" | grep -q "enforcement.md" || exit 1
'

run_test "three-dot range: main-side feat commit is NOT a false positive (critic #3)" '
  setup_repo
  # Branch off BASE (behind the main-only feat commit below).
  git -C "$R" checkout -q -b feat/x
  echo b >> "$R/scripts/hooks/branch.sh"
  git -C "$R" add -A; git -C "$R" commit -q -m "chore: branch-only tweak"
  # Add a feat commit to MAIN touching a DIFFERENT mapped source.
  git -C "$R" checkout -q main
  echo m >> "$R/scripts/hooks/main-only.sh"
  git -C "$R" add -A; git -C "$R" commit -q -m "feat: main-only hook"
  git -C "$R" checkout -q feat/x
  # git log main...HEAD includes the main-side feat (symmetric diff), but
  # git diff main...HEAD (merge-base) does NOT → no finding after intersection.
  out=$(cd "$R" && detect "main...HEAD")
  [ -z "$out" ] || exit 1
'

run_test "leg gate: HIMMEL_DOC_FRESHNESS grammar" '
  ( . "$LIB"
    HIMMEL_DOC_FRESHNESS="" df_leg_active advise && exit 1
    HIMMEL_DOC_FRESHNESS=1 df_leg_active advise || exit 1
    HIMMEL_DOC_FRESHNESS=all df_leg_active morning || exit 1
    HIMMEL_DOC_FRESHNESS="advise,morning" df_leg_active session && exit 1
    HIMMEL_DOC_FRESHNESS="advise,morning" df_leg_active advise || exit 1
    HIMMEL_DOC_FRESHNESS=off df_leg_active advise && exit 1
    exit 0 )
'

run_test "df_leg_active extra grammar: 0/false/no off, true/on/yes on, UPPERCASE normalised" '
  ( . "$LIB"
    HIMMEL_DOC_FRESHNESS=0     df_leg_active advise   && exit 1   # 0 → off
    HIMMEL_DOC_FRESHNESS=false df_leg_active advise   && exit 1   # false → off
    HIMMEL_DOC_FRESHNESS=no    df_leg_active advise   && exit 1   # no → off
    HIMMEL_DOC_FRESHNESS=true  df_leg_active advise   || exit 1   # true → on
    HIMMEL_DOC_FRESHNESS=on    df_leg_active advise   || exit 1   # on → on
    HIMMEL_DOC_FRESHNESS=yes   df_leg_active morning  || exit 1   # yes → on
    HIMMEL_DOC_FRESHNESS=ALL   df_leg_active morning  || exit 1   # uppercase ALL → on (_df_norm lowers)
    HIMMEL_DOC_FRESHNESS=OFF   df_leg_active advise   && exit 1   # uppercase OFF → off
    exit 0 )
'

if [ "$_fail" -eq 0 ]; then echo "OK: all cases passed"; exit 0; else echo "FAIL: $_fail case(s)"; exit 1; fi
