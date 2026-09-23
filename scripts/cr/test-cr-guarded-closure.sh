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
#   edges = source/exec sites (`.`, source, bash, sh, node, bun, tsx, deno,
#           python, python3, pwsh, exec) and direct script calls in command
#           position ("$DIR/x.sh" ...) and script paths stored in a variable
#           (X="$DIR/x.sh", ${X:-$DIR/x.sh}, an env prefix) on non-comment
#           lines, plus relative JS require/import, static or dynamic;
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
PATH_RE='(\$\{?[A-Za-z_][A-Za-z0-9_]*\}?|[)}])?/?[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*\.(sh|js|mjs|cjs|ts|py)'
# A script path in command position: line start, after ; & | ( $( or
# then/do/else, optionally quoted - a direct call with no interpreter word.
# The $VAR/ prefix is required: without it a `(` in a message string or a
# `|` in a case pattern reads as a call.
CMD_RE='(^|[;&|(]|\$\(|(then|do|else)[[:space:]])[[:space:]]*"?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*\.(sh|py|ts|mjs|cjs|js)'
# A line that assigns a variable (VAR=…, an env prefix, or a ${VAR:-…}
# default): a script path stored there is run later through the variable, so
# every path on it is an edge. Over-matching only widens the closure, which is
# the fail-safe direction.
ASSIGN_RE='[A-Za-z_][A-Za-z0-9_]*=|:-'
edges() {
  local f="$1" dir raw tail target cand
  dir="$(dirname "$f")"
  {
    grep -E '(^|[;&|({[:space:]])(\.|source|bash|sh|node|bun|tsx|deno|python|python3|pwsh|exec)[[:space:]]' "$ROOT/$f" 2>/dev/null \
      | grep -vE '^[[:space:]]*#' | grep -oE "$PATH_RE"
    grep -vE '^[[:space:]]*#' "$ROOT/$f" 2>/dev/null | grep -oE "$CMD_RE" | grep -oE "$PATH_RE"
    grep -vE '^[[:space:]]*#' "$ROOT/$f" 2>/dev/null | grep -E "$ASSIGN_RE" | grep -oE "$PATH_RE"
    grep -oE "(require\\(|import\\([[:space:]]*|from[[:space:]]+|import[[:space:]]+)['\"]\\.{1,2}/[^'\"]+['\"]" "$ROOT/$f" 2>/dev/null \
      | grep -oE "\\.{1,2}/[^'\"]+"
  } | while IFS= read -r raw; do
    tail="$raw"
    case "$tail" in
      '$'*|')'*|'}'*)
        # The prefix variable may name the repo root or the caller's own
        # directory - resolve both and keep whichever exists (fail-safe).
        tail="${tail#*/}"
        for target in "$(normalize "$tail")" "$(normalize "$dir/$tail")"; do
          [ -f "$ROOT/$target" ] && printf '%s\n' "$target"
        done
        continue ;;
    esac
    case "$tail" in
      /scripts/*|scripts/*) target="$(normalize "${tail#/}")" ;;
      *) target="$(normalize "$dir/${tail#/}")" ;;
    esac
    # An extensionless JS/TS import resolves the way node/bun would.
    for cand in "$target" "$target.ts" "$target.js" "$target.mjs" "$target.cjs" "$target/index.js"; do
      [ -f "$ROOT/$cand" ] && { printf '%s\n' "$cand"; break; }
    done
  done | sort -u | while IFS= read -r target; do
    # Drop the pinned non-executed edges (NOT_RUN below).
    grep -qxF -- "$f -> $target" <<< "$NOT_RUN" || printf '%s\n' "$target"
  done
}

# Edges the lexical scan sees that no "no" run executes: the path is written
# into a config or hook for later, or only named in a message, not run. Each is pinned exactly and must
# still be an edge (checked below), so the list cannot rot silently.
NOT_RUN="scripts/cr/install-cr-gate.sh -> scripts/hooks/check-cr-before-push.sh
scripts/lib/wire-statusline.sh -> marketplace/plugins/claude-hud/dist/index.js
scripts/lib/bank-preflight.sh -> scripts/lanes/codex-bank-probe.ts
scripts/lanes/bank-status-core.mjs -> scripts/lanes/codex-bank-probe.ts"

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

# unreadable <<closure - print each reached file edges() could not read (its
# greps discard errors, so an unreadable file would look like a leaf).
unreadable() {
  local f
  while IFS= read -r f; do
    [ -n "$f" ] && [ ! -r "$ROOT/$f" ] && printf '%s\n' "$f"
  done
  return 0
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
# The assignment spans several lines; flatten it to one space-separated list.
cr_guarded="$(sed -n '/^cr_guarded="/,/"$/p' "$DIR/pr-check-context.sh" | sed 's/^cr_guarded="//; s/"$//' | tr '\n' ' ')"
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

# Positive control for edges(): a direct script call with no interpreter
# word must yield an edge, in each command position CMD_RE names.
fx="$(mktemp -d "${TMPDIR:-/tmp}/cr-closure.XXXXXX")" || exit 1
mkdir -p "$fx/scripts/cr" "$fx/scripts/lib" "$fx/tools"
for n in a b c d; do : > "$fx/scripts/lib/$n.sh"; done
: > "$fx/tools/e.sh"
cat > "$fx/scripts/cr/caller.sh" <<'EOF'
"$ROOT/scripts/lib/a.sh" --flag
x=$("$DIR/../lib/b.sh")
if true; then "$ROOT/scripts/lib/c.sh"; fi
true && "$ROOT/scripts/lib/d.sh"
bash "$ROOT/tools/e.sh"
# "$ROOT/scripts/lib/commented.sh"
EOF
got="$(ROOT="$fx" edges scripts/cr/caller.sh | tr '\n' ' ')"
check "$got" "scripts/lib/a.sh scripts/lib/b.sh scripts/lib/c.sh scripts/lib/d.sh tools/e.sh " "edges() sees direct script calls in command position and repo-root paths outside scripts/"
# ...and a script path stored in a variable (a ${VAR:-…} default, an env
# prefix, a plain assignment) and an extensionless relative import.
: > "$fx/tools/f.sh"; : > "$fx/scripts/lib/g.sh"; : > "$fx/tools/h.sh"; : > "$fx/scripts/cr/helper.ts"
cat > "$fx/scripts/cr/assigner.sh" <<'EOF'
INVOKE="${X_INVOKE:-$SCRIPT_DIR/../../tools/f.sh}"
BRIDGE="$HERE/../lib/g.sh" node -e 'run(process.env.BRIDGE)'
P="$REPO/tools/h.sh"
EOF
printf 'import { q } from "./helper";\n' > "$fx/scripts/cr/importer.js"
got="$(ROOT="$fx" edges scripts/cr/assigner.sh | tr '\n' ' ')"
check "$got" "scripts/lib/g.sh tools/f.sh tools/h.sh " "edges() sees script paths stored in a variable (default, env prefix, assignment)"
check "$(ROOT="$fx" edges scripts/cr/importer.js)" "scripts/cr/helper.ts" "edges() resolves an extensionless relative import"
# ...and the non-shell runners (a bare `bun` with no assignment on the line),
# a direct .ts call, and a dynamic import().
mkdir -p "$fx/scripts/telegram"
for n in r1 r2 r3 r4 r5 r6 dyn; do : > "$fx/scripts/telegram/$n.ts"; done
cat > "$fx/scripts/lib/runner.sh" <<'EOF'
$tmo bun "$LIB/../telegram/r1.ts" reply "$chat"
tsx "$LIB/../telegram/r2.ts"
deno run "$LIB/../telegram/r3.ts"
python "$LIB/../telegram/r4.ts"
pwsh -File "$LIB/../telegram/r5.ts"
if true; then "$LIB/../telegram/r6.ts"; fi
EOF
printf 'const { f } = await import("./dyn");\n' > "$fx/scripts/telegram/importer.ts"
got="$(ROOT="$fx" edges scripts/lib/runner.sh | tr '\n' ' ')"
check "$got" "scripts/telegram/r1.ts scripts/telegram/r2.ts scripts/telegram/r3.ts scripts/telegram/r4.ts scripts/telegram/r5.ts scripts/telegram/r6.ts " "edges() sees bun/tsx/deno/python/pwsh runners and a direct .ts call"
check "$(ROOT="$fx" edges scripts/telegram/importer.ts)" "scripts/telegram/dyn.ts" "edges() sees a dynamic import()"
# A reached file edges() cannot read yields no edges, which would truncate the
# closure silently - unreadable() must name it.
: > "$fx/scripts/lib/locked.sh"; chmod 000 "$fx/scripts/lib/locked.sh"
if [ -r "$fx/scripts/lib/locked.sh" ]; then
  echo "skip: unreadable() control (running with read-all privileges)"
else
  check "$(printf 'scripts/lib/a.sh\nscripts/lib/locked.sh\n' | ROOT="$fx" unreadable)" "scripts/lib/locked.sh" "unreadable() names a reached file edges() cannot read"
fi
chmod 600 "$fx/scripts/lib/locked.sh"
rm -rf "$fx"

# Every pinned NOT_RUN edge is still a real edge of its parent.
while IFS= read -r pin; do
  check "$(NOT_RUN='' edges "${pin%% -> *}" | grep -cxF -- "${pin#* -> }")" "1" "NOT_RUN pin is still an edge: $pin"
done <<< "$NOT_RUN"

reached="$(closure)"
echo "closure ($(printf '%s\n' "$reached" | grep -c .) files reached from the runbook and scripts/cr):"
printf '%s\n' "$reached" | grep -v '^scripts/cr/' | sed 's/^/  /'

# Sanity: the derivation actually reaches the known non-scripts/cr sites, so
# an empty or truncated closure cannot pass vacuously.
# console-route.ts and poller.ts are reached only through merge-block-alert.sh's
# bare `bun` call and a dynamic import (second console review of #1148).
for known in scripts/check-ci.sh scripts/handover/resolve-active-item.sh scripts/lib/handover-path.sh scripts/lib/load-dotenv.sh scripts/guardrails/lib.sh \
    scripts/telegram/console-route.ts scripts/telegram/bus.ts scripts/telegram/console-heartbeat-watch.ts scripts/telegram/poller.ts; do
  check "$(printf '%s\n' "$reached" | grep -cxF "$known")" "1" "closure reaches $known"
done

check "$(printf '%s\n' "$reached" | unreadable)" "" "every reached file was readable, so no edge was dropped"

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

# RED control: the set PR #1148 first shipped (3f62af60) must fail too - it
# missed the variable-assigned exec paths the console's review found.
red="$(printf '%s\n' "$reached" | outside "scripts/cr scripts/lib scripts/guardrails/lib.sh scripts/check-ci.sh scripts/handover/resolve-active-item.sh")"
for missed in scripts/handover/append-cr-findings.sh scripts/handover/append-cr-bugs.sh scripts/hermes/invoke.sh scripts/statusline/usage-cache-producer.sh; do
  check "$(grep -cxF "$missed" <<< "$red")" "1" "RED control: the 3f62af60 set leaves $missed unguarded"
done

echo "test-cr-guarded-closure: $pass passed, fail=$fail"
exit "$fail"
