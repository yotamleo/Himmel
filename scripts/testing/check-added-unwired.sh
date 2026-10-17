#!/usr/bin/env bash
# check-added-unwired.sh — fail when a file a PR ADDS is a hook, script, skill or
# suite that nothing reaches. Ready-check item 11 feeds it the
# diff's status-A files; existing debt is never judged.
#
# Everything is read from <ref>'s tree (the PR head), so wiring the PR adds in
# the same diff counts. "Wired" per kind:
#   hook   scripts/hooks/<name>.sh|js|mjs (not test-*, lib-*, *.test.*, runner tooling):
#          its basename appears in a file of the WIRING list parsed out of
#          scripts/testing/check-unwired-hooks.sh (the one notion of wired), or it
#          is on scripts/testing/unwired-hooks-allowlist.txt.
#   suite  test-*.sh: scripts/ci/run-shell-tests.sh finds it (scan roots scripts,
#          templates, marketplace, packaging) and suite-coverage.sh does not call it
#          SKIP_LIST. *.test.*: another WIRED file names it (a wrapper suite runs
#          it), a .github/workflows job runs bun test / node --test / vitest / jest
#          on a directory above it, or a package.json above it has a "test" script
#          whose runner's discovery reaches it (path args narrow; node --test
#          reaches only JS unless the script loads a TS transform; node may carry
#          flags before --test, e.g. node --import tsx --test; {a,b} groups in
#          a path arg are expanded, a nested brace group narrows by directory only;
#          a single * also matches across / — ponytail: over-accepts a nested file
#          for node --test, upgrade = a segment-aware glob matcher).
#   hooklib scripts/hooks/<subdir>/*: a wired hook, or another live library under
#          scripts/hooks/, names its basename (sourced). Judged read-only.
#   skill  SKILL.md under <plugin>/skills/<name>/ where <plugin> has
#          .claude-plugin/plugin.json (a marketplace/plugins/<p> must also be named in
#          marketplace/.claude-plugin/marketplace.json), or under .claude/skills/ or
#          .agents/skills/ (discovered by directory).
#   script a .sh/.mjs/.js/.ts/.py file under scripts/, or any scripts/ file with the
#          executable bit: some OTHER file at <ref> names its basename (settings,
#          runner, CI job, doctor check, caller, a sourcing script, or a runbook/
#          cadence doc already in the tree: operator-run tools are wired by the doc
#          that says when to run them). Never counted: a test or suite (test-*,
#          *.test.*), a handovers/ file, a fixtures/testdata/node_modules file.
#          A referencer that is itself an unwired added file does not count, nor does
#          a .md/.txt/.rst/.adoc doc the same PR adds. A generic TS/JS stem (index, utils) is matched by
#          directory/stem in an extensionless import, not the bare stem.
#          A test helper (under a tests?/ or *-cases/ dir, or named testlib-*) is also
#          wired by a suite that names it; an added suite still unwired does not count.
# Standalone by design (no reference needed): fixtures/testdata paths, ALLOW_PATH_RE.
#
# Usage: check-added-unwired.sh <ref> <added-file>...   (run inside the repo)
#        check-added-unwired.sh --branch-diff           (pre-push: the pushed tip, $PRE_COMMIT_TO_REF
#          else HEAD, vs its merge-base with $ADDED_UNWIRED_BASE, else origin/main, else
#          main; the status-A files of that diff. No resolvable base or no added file: exit 0, nothing to judge.)
# Exit: 0 clean, 1 unwired file(s), 2 usage / unreadable ref.
# Platform guard (gitbash-only): POSIX bash 3.2+, no mapfile.
set -uo pipefail

ALLOW_PATH_RE='(^|/)(fixtures|testdata|node_modules)/'
TEST_HELPER_RE='(^|/)(tests?|[^/]*-cases)/|(^|/)testlib-[^/]*$'

if [ "${1:-}" = "--branch-diff" ] && [ "$#" -eq 1 ]; then
  bd_tip="${PRE_COMMIT_TO_REF:-HEAD}"
  bd_base=""
  for bd_cand in "${ADDED_UNWIRED_BASE:-}" origin/main main; do
    [ -n "$bd_cand" ] && bd_base=$(git merge-base "$bd_cand" "$bd_tip" 2>/dev/null) && break
    bd_base=""
  done
  [ -n "$bd_base" ] || { echo "ADDED-UNWIRED SKIPPED (no base to diff against)"; exit 0; }
  bd_list=$(mktemp "${TMPDIR:-/tmp}/added-unwired-bd.XXXXXX") || exit 2
  git diff -z --name-only --diff-filter=A "$bd_base" "$bd_tip" > "$bd_list" || { rm -f "$bd_list"; exit 2; }
  bd_args=()
  while IFS= read -r -d '' bd_f; do bd_args+=("$bd_f"); done < "$bd_list"
  rm -f "$bd_list"
  [ "${#bd_args[@]}" -gt 0 ] || { echo "ADDED-UNWIRED OK (the branch adds no files)"; exit 0; }
  bd_rc=0
  bd_out=$(bash "${BASH_SOURCE[0]}" "$bd_tip" "${bd_args[@]}" 2>&1) || bd_rc=$?
  [ "$bd_rc" -eq 0 ] && { printf '%s\n' "$bd_out"; exit 0; }
  echo "added but unwired (wire it, or allowlist it in the diff):"
  printf '%s\n' "$bd_out" | sed 's/^/       /'
  exit "$bd_rc"
fi
if [ "$#" -lt 2 ]; then
  echo "usage: check-added-unwired.sh <ref> <added-file>..." >&2
  exit 2
fi
ref="$1"; shift
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
top=$(git rev-parse --show-toplevel) || exit 2

tmp=$(mktemp -d "${TMPDIR:-/tmp}/added-unwired.XXXXXX") || exit 2
trap 'rm -rf "$tmp"' EXIT

show() { git show "$ref:$1" 2>/dev/null; }
exists() { git cat-file -e "$ref:$1" 2>/dev/null; }
# whole-basename match: not-foo.sh must not reference foo.sh
bn_re() { printf '(^|[^A-Za-z0-9._-])%s([^A-Za-z0-9._-]|$)' "${1//./\\.}"; }

# is_pending <path> — the path is an added file still judged unwired (literal match)
is_pending() { P="$1" awk -F'|' '$2 == ENVIRON["P"] {f=1} END {exit !f}' "$tmp/pending"; }

# brace_expand <word> — the word's {a,b} alternatives one per line (call under set -f);
# a word with no comma group, or a nested one, is printed unchanged
brace_expand() {
  local w="$1" pre rest in post a
  case "$w" in *\{*,*\}*) ;; *) printf '%s\n' "$w"; return ;; esac
  pre="${w%%\{*}"; rest="${w#*\{}"; in="${rest%%\}*}"; post="${rest#*\}}"
  case "$in" in *\{*) printf '%s\n' "$w"; return ;; esac
  while :; do  # parameter-expansion split keeps an empty alternative ({,src/})
    a="${in%%,*}"; brace_expand "$pre$a$post"
    case "$in" in *,*) in="${in#*,}" ;; *) break ;; esac
  done
}

# one flag before node's --test: only these take a value word (--import tsx, -r ./x.js);
# any other flag is bare, so `node --no-warnings build.js --test` is not a runner
node_flag='(--(import|loader|experimental-loader|require|conditions)([ =][^ -][^ ]*)|-r +[^ -][^ ]*|--[a-z-]+(=[^ ]*)?)'

# pkg_runs <pkg dir, "" = root> <file> — the package.json test script runs a known
# runner whose discovery reaches <file> (path args narrow it; bare = whole package)
pkg_runs() {
  local pd="$1" f="$2" ts rel tok tok0 prev="" pre reach have=0 hit=0 pj="package.json"
  [ -z "$pd" ] || pj="$pd/package.json"
  ts=$(show "$pj" | jq -r '.scripts.test // empty' 2>/dev/null)
  # a runner counts only as the start of a command (echo bun test runs nothing)
  printf '%s\n' "$ts" | sed -E 's/&&|;|\|\|?/\n/g' \
    | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)*((npx|bunx|pnpm exec|yarn)[[:space:]]+)?//' \
    | grep -qE "^(bun test|node( +$node_flag)* +--test|vitest|jest)([[:space:]]|\$)" || return 1
  case "$ts" in  # node --test globs only reach JS unless the script loads a TS transform
    *"bun test"*|*vitest*|*jest*) ;;
    *) case "${f##*/}" in *.js|*.mjs|*.cjs) ;; *) case "$ts" in *strip-types*|*tsx*|*--import*|*--loader*) ;; *) return 1 ;; esac ;; esac ;;
  esac
  rel="$f"; [ -z "$pd" ] || rel="${f#"$pd"/}"
  # only the words after the runner, up to the next command, can narrow discovery
  ts=$(printf '%s' "$ts" | sed -E "s/.*(bun test|node( +$node_flag)* +--test([[:space:]]|\$)|vitest( run)?|jest)//; s/(&&|;|\\|).*//")
  set -f
  for tok0 in $ts; do for tok in $(brace_expand "${tok0//[\"\']/}"); do
    tok="${tok#./}"
    case "$tok" in -*|'&&'|';'|'|'|'||'|'') prev="$tok"; continue ;; esac
    # a bare word is a path when it exists, or when it is not an option's value (--reporter dot)
    case "$tok" in *[/*?\{[]*) ;; *) exists "${pd:+$pd/}$tok" || case "$prev" in -*) prev="$tok"; continue ;; esac ;; esac
    prev="$tok"
    have=1
    case "$tok" in  # a glob narrows to the directory before its first wildcard segment
      *[*?\{[]*) pre="${tok%%[*?\{[]*}"; case "$pre" in */) pre="${pre%/}" ;; */*) pre="${pre%/*}" ;; *) pre="" ;; esac ;;
      *) pre="${tok%/}" ;;
    esac
    [ "$pre" != . ] || pre=""
    case "$rel" in "$pre"|"$pre"/*) reach=1 ;; *) reach=0 ;; esac
    [ -n "$pre" ] || reach=1
    case "$tok" in  # a glob must also match the file itself (braces: directory narrowing only)
      *\{*) ;;
      *[*?[]*)
        # shellcheck disable=SC2254  # the glob is the point: the arg's wildcards match the file
        case "$rel" in $tok|${tok//\*\*\//}|$tok/*) ;; *) reach=0 ;; esac ;;
    esac
    [ "$reach" -eq 0 ] || hit=1
  done; done
  set +f
  [ "$have" -eq 0 ] || [ "$hit" -eq 1 ]
}

# kind_of <path> — hook|hooklib|suite|skill|script|none
kind_of() {
  local p="$1" b="${1##*/}"
  case "$p" in *SKILL.md) printf skill; return ;; esac
  case "$b" in test-*.sh|*.test.*) printf suite; return ;; esac
  case "$p" in
    scripts/hooks/*/*) printf hooklib; return ;;
    scripts/hooks/*)
      case "$b" in lib-*|run-hook-with-bash.js|wire-hook-bash.mjs|wire-plugin-hook-bash.mjs|bench-hook-stack.mjs) printf none; return ;; esac
      case "$b" in *.sh|*.js|*.mjs) printf hook; return ;; esac ;;
    scripts/*)
      case "$b" in *.sh|*.mjs|*.js|*.ts|*.py) printf script; return ;; esac
      git ls-tree "$ref" -- "$p" | grep -q '^100755' && { printf script; return; } ;;
  esac
  printf none
}

wiring_text=""
if exists scripts/testing/check-unwired-hooks.sh; then
  wl=$(show scripts/testing/check-unwired-hooks.sh | sed -n '/^WIRING=(/,/^)/p' | grep -E '^[[:space:]]+[A-Za-z.]' | tr -d ' ')
  while IFS= read -r w; do
    [ -n "$w" ] && exists "$w" && wiring_text="$wiring_text$(show "$w")"$'\n'
  done <<EOF
$wl
EOF
fi
hook_allow=$(show scripts/testing/unwired-hooks-allowlist.txt | awk -F'|' '$1 !~ /^#/ && $2 != "" {print $1}')

runner="$tmp/run-shell-tests.sh"
show scripts/ci/run-shell-tests.sh > "$runner"

judge() {  # <path> <kind> -> prints a reason when unwired
  local p="$1" k="$2" b="${1##*/}" d plug imp generic_pat
  case "$k" in
    hook)
      printf '%s\n' "$wiring_text" | grep -qE -- "$(bn_re "$b")" && return 0
      printf '%s\n' "$hook_allow" | grep -qxF -- "$b" && return 0
      echo "no hook wiring file names it and it is not on unwired-hooks-allowlist.txt" ;;
    suite)
      case "$b" in
        test-*.sh)
          case "$p" in scripts/*|templates/*|marketplace/*|packaging/*) ;; *) echo "outside the runner's scan roots, so run-shell-tests.sh never finds it"; return 0 ;; esac
          [ -s "$runner" ] || { echo "cannot read scripts/ci/run-shell-tests.sh at $ref"; return 0; }
          cov=$(bash "$HERE/../handover/suite-coverage.sh" --runner "$runner" --root "$top" "$p" 2>&1)
          printf '%s\n' "$cov" | grep -qE 'runs in PR CI|nightly only|superseded by' \
            || echo "run-shell-tests.sh skips it (SKIP_LIST) or cannot classify it" ;;
        *)
          # a node/bun test file is run by a wrapper that names it, when that wrapper is itself wired
          git grep -lIE -e "$(bn_re "$b")" "$ref" -- . ':(exclude)handovers' 2>/dev/null | sed "s#^$ref:##" | grep -vxF "$p" > "$tmp/refs" || true
          while IFS= read -r r; do
            [ -n "$r" ] || continue
            is_pending "$r" || return 0
          done < "$tmp/refs"
          # a CI job that runs the test command on a directory above it
          d="${p%/*}"
          while :; do
            dre=$(printf '%s' "$d" | sed 's/[.+]/\\&/g')
            git grep -qIE -e "(bun test|node --test|vitest|jest)[^#]*[ '\"]${dre}(/?|/[^ /'\"]*\\*[^ '\"]*)( |\$|'|\")" -e "cd ${dre}/?[ ;&'\"][^#]*(bun test|node --test|vitest|jest)" "$ref" -- .github/workflows 2>/dev/null && return 0
            [ "$d" = "${d%/*}" ] && break
            d="${d%/*}"
          done
          d="${p%/*}"
          while :; do
            exists "$d/package.json" && pkg_runs "$d" "$p" && return 0
            [ "$d" = "${d%/*}" ] && break
            d="${d%/*}"
          done
          exists package.json && pkg_runs "" "$p" && return 0
          echo "no wired file names it and no package.json test script above it runs a runner that discovers it" ;;
      esac ;;
    hooklib)
      # a library under scripts/hooks/<subdir>/ is sourced by a wired hook (or another live library)
      pat="$(bn_re "$b")"
      git grep -lIE -e "$pat" "$ref" -- scripts/hooks 2>/dev/null | sed "s#^$ref:##" | grep -vxF "$p" > "$tmp/refs" || true
      while IFS= read -r r; do
        [ -n "$r" ] || continue
        rb="${r##*/}"
        case "$(kind_of "$r")" in
          hook) printf '%s\n' "$wiring_text" | grep -qE -- "$(bn_re "$rb")" && return 0
                printf '%s\n' "$hook_allow" | grep -qxF -- "$rb" && return 0 ;;
          suite) printf '%s\n' "$p" | grep -qE "$TEST_HELPER_RE" && { is_pending "$r" || return 0; } ;;
          *) is_pending "$r" || return 0 ;;
        esac
      done < "$tmp/refs"
      echo "no wired hook (or live hook library) in scripts/hooks names it" ;;
    skill)
      case "$p" in .claude/skills/*|.agents/skills/*) return 0 ;; esac
      plug="${p%%/skills/*}"
      if [ "$plug" = "$p" ] || ! exists "$plug/.claude-plugin/plugin.json"; then
        echo "not under .claude/skills, .agents/skills or a plugin with .claude-plugin/plugin.json"
      else
        case "$plug" in marketplace/plugins/*)
          show marketplace/.claude-plugin/marketplace.json | grep -qF "\"./plugins/${plug##*/}\"" \
            || echo "plugin ${plug##*/} is not listed in marketplace/.claude-plugin/marketplace.json" ;;
        esac
      fi ;;
    script)
      pat="$(bn_re "$b")"; generic_pat=""
      case "$b" in  # TS/JS import without the extension: from './sector.js', require('./sector')
        *.ts|*.tsx|*.js|*.mjs)
          # a generic stem (index, utils) also needs its directory: any './index' would wire it
          case "${b%.*}" in
            index|utils|util|helpers|types|main|config|constants|common)
              imp="${p%/*}"; imp="${imp##*/}/${b%.*}"; imp="${imp//./\\.}"
              pat="$pat|/${imp}(\\.[jt]sx?|\\.mjs)?['\"]"
              # a sibling's ./index is this file; any other ./index is not
              generic_pat="['\"]\\./${b%.*}(\\.[jt]sx?|\\.mjs)?['\"]" ;;
            *) imp="${b%.*}"; imp="${imp//./\\.}"; pat="$pat|/${imp}(\\.[jt]sx?|\\.mjs)?['\"]" ;;
          esac ;;
      esac
      if printf '%s\n' "$p" | grep -qE "$TEST_HELPER_RE"; then
        # a test helper is reached by the suite that uses it
        git grep -lIE -e "$pat" "$ref" -- . ':(exclude)handovers' 2>/dev/null
      else
        git grep -lIE -e "$pat" "$ref" -- . ':(exclude)handovers' ':(exclude,glob)**/test-*' ':(exclude,glob)**/*.test.*' 2>/dev/null
      fi | sed "s#^$ref:##" | grep -vxF "$p" > "$tmp/refs" || true
      if [ -n "$generic_pat" ]; then  # ponytail: only a sibling's ./stem import is resolved; a child's ../stem needs a real resolver
        if printf '%s\n' "$p" | grep -qE "$TEST_HELPER_RE"; then
          git grep -lIE -e "$generic_pat" "$ref" -- "${p%/*}" 2>/dev/null
        else
          git grep -lIE -e "$generic_pat" "$ref" -- "${p%/*}" ':(exclude,glob)**/test-*' ':(exclude,glob)**/*.test.*' 2>/dev/null
        fi | sed "s#^$ref:##" | while IFS= read -r r; do [ "${r%/*}" = "${p%/*}" ] && [ "$r" != "$p" ] && printf '%s\n' "$r"; done >> "$tmp/refs"
      fi
      # an added referencer still unwired itself does not count
      while IFS= read -r r; do
        [ -n "$r" ] || continue
        # sample data names scripts without running them
        printf '%s\n' "$r" | grep -qE "$ALLOW_PATH_RE" && continue
        # a doc the same PR adds only describes the file; it is not independent wiring
        case "$r" in *.md|*.txt|*.rst|*.adoc) grep -qxF -- "$r" "$tmp/added" && continue ;; esac
        is_pending "$r" || return 0
      done < "$tmp/refs"
      echo "no wiring, runner, CI job or wired script names it" ;;
  esac
}

git cat-file -e "$ref^{commit}" 2>/dev/null || { echo "check-added-unwired: cannot read $ref" >&2; exit 2; }

: > "$tmp/added"; : > "$tmp/wired"; : > "$tmp/pending"
for f in "$@"; do
  printf '%s\n' "$f" >> "$tmp/added"
done
for f in "$@"; do
  k=$(kind_of "$f")
  [ "$k" = none ] && continue
  printf '%s\n' "$f" | grep -qE "$ALLOW_PATH_RE" && continue
  printf '%s|%s\n' "$k" "$f" >> "$tmp/pending"
done

# Fixpoint: an added library counts once a wired added script sources it.
report=""
changed=1
while [ "$changed" -eq 1 ]; do
  changed=0; : > "$tmp/next"; report=""
  while IFS='|' read -r k f; do
    [ -n "$f" ] || continue
    why=$(judge "$f" "$k")
    if [ -z "$why" ]; then
      printf '%s\n' "$f" >> "$tmp/wired"; changed=1
    else
      printf '%s|%s\n' "$k" "$f" >> "$tmp/next"
      report="$report$(printf 'UNWIRED %s (%s): %s' "$f" "$k" "$why")"$'\n'
    fi
  done < "$tmp/pending"
  mv "$tmp/next" "$tmp/pending"
done
if [ -s "$tmp/pending" ]; then
  printf '%s' "$report"
  exit 1
fi
echo "ADDED-UNWIRED OK"
exit 0
