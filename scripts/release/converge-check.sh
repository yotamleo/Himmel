#!/usr/bin/env bash
# converge-check.sh -- do two himmel installs end in the SAME state?
# (HIMMEL-3059 ADR Q3: the tarball path and the clone path both end in
# `himmelctl install`; that convergence is ASSERTED here, not assumed.)
#
# Snapshots each side's post-install state into normalized text and diffs it:
#   settings   <home>/.claude/settings.json          (jq -S; statusLine, env.HIMMEL_REPO, hooks)
#   marketplaces / plugins   <home>/.claude/plugins/{known_marketplaces,installed_plugins}.json
#                            (names only -- timestamps / commit shas are not state)
#   seed       file list under <home>/.claude/himmel
#   launcher   <home>/.local/bin/himmelctl
#   gates      git hooks in each --a-target/--b-target repo (file name + content)
# The side's own prefix and HOME are rewritten to {PREFIX} / {HOME} first, so two
# installs at different paths compare equal iff they differ ONLY by location. A
# path that is neither prefix (a leaked third location) is NOT masked.
#
# VACUOUS GUARD: a snapshot with no settings.json hooks proves nothing (two empty
# homes are "identical"), so that is refused (exit 3) rather than passed.
#
# USAGE:
#   converge-check.sh --a-home <d> --a-prefix <d> --b-home <d> --b-prefix <d> \
#                     [--a-target <repo> --b-target <repo>]
# Exit: 0 identical | 1 differ (diff on stdout) | 2 usage | 3 vacuous snapshot
# shellcheck disable=SC2015  # `A && B || usage` -- usage exits, so C never runs after a true A
set -uo pipefail

usage() { sed -n '/^# USAGE:/,/^# Exit:/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

ah="" ap="" bh="" bp="" at="" bt=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case "$1" in
    --a-home) ah="$2" ;; --a-prefix) ap="$2" ;; --a-target) at="$2" ;;
    --b-home) bh="$2" ;; --b-prefix) bp="$2" ;; --b-target) bt="$2" ;;
    *) usage ;;
  esac
  shift 2
done
[ -n "$ah" ] && [ -n "$ap" ] && [ -n "$bh" ] && [ -n "$bp" ] || usage
{ [ -n "$at" ] && [ -z "$bt" ]; } && usage
{ [ -z "$at" ] && [ -n "$bt" ]; } && usage
command -v jq >/dev/null 2>&1 || { echo "converge-check: jq is required" >&2; exit 2; }

# norm <home> <prefix> -- stdin -> stdout, own paths masked (prefix first: it is
# usually nested under home).
norm() {
  local home="$1" prefix="$2" line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line//"$prefix"/\{PREFIX\}}"
    line="${line//"$home"/\{HOME\}}"
    printf '%s\n' "$line"
  done
}

# snapshot <home> <prefix> <target> -- prints the normalized state.
snapshot() {
  local home="$1" prefix="$2" target="$3" f
  home="$(cd -- "$home" 2>/dev/null && pwd -P)" || home="$1"
  prefix="$(cd -- "$prefix" 2>/dev/null && pwd -P)" || prefix="$2"
  {
    echo "## settings"
    # A jq failure prints a sentinel, never jq's own diagnostic: identical
    # malformed files on both sides must not compare as "converged".
    if [ -f "$home/.claude/settings.json" ]; then jq -S . "$home/.claude/settings.json" 2>/dev/null || echo "(unreadable: settings.json)"; else echo "(absent)"; fi
    echo "## marketplaces"
    f="$home/.claude/plugins/known_marketplaces.json"
    if [ -f "$f" ]; then jq -S 'with_entries(.value |= {source})' "$f" 2>/dev/null || echo "(unreadable: known_marketplaces.json)"; else echo "(absent)"; fi
    echo "## plugins"
    f="$home/.claude/plugins/installed_plugins.json"
    if [ -f "$f" ]; then jq -S '[(.plugins // .) | keys[]]' "$f" 2>/dev/null || echo "(unreadable: installed_plugins.json)"; else echo "(absent)"; fi
    echo "## seed"
    if [ -d "$home/.claude/himmel" ]; then ( cd "$home/.claude/himmel" && find . -type f | LC_ALL=C sort ); else echo "(absent)"; fi
    echo "## launcher"
    f="$home/.local/bin/himmelctl"
    if [ -f "$f" ]; then
      cat "$f"
      if [ -x "$f" ]; then echo "# mode: executable"; else echo "# mode: NOT executable"; fi
    else echo "(absent)"; fi
    if [ -n "$target" ]; then
      echo "## gates"
      local hooks
      hooks="$(git -C "$target" rev-parse --git-path hooks 2>/dev/null)"
      case "$hooks" in /*) ;; *) hooks="$target/$hooks" ;; esac
      if [ -d "$hooks" ]; then
        for f in $(find "$hooks" -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort); do  # gnu-ok: only ever runs on the Linux guest (the tarball is Linux-only), where find -printf is findutils' own
          case "$f" in *.sample) continue ;; esac
          echo "# hook: $f"
          cat "$hooks/$f"
          if [ -x "$hooks/$f" ]; then echo "# mode: executable"; else echo "# mode: NOT executable (git ignores it)"; fi
        done
      else
        echo "(no hooks dir)"
      fi
      echo "## target-settings"
      if [ -f "$target/.claude/settings.json" ]; then jq -S . "$target/.claude/settings.json" 2>/dev/null || echo "(unreadable: target settings.json)"; else echo "(absent)"; fi
    fi
  } | norm "$home" "$prefix"
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/himmel-converge.XXXXXX")" || { echo "converge-check: cannot create a scratch dir" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT
snapshot "$ah" "$ap" "$at" > "$tmp/a.txt"
snapshot "$bh" "$bp" "$bt" > "$tmp/b.txt"

# Vacuous guard: settings.json must exist and carry hooks on BOTH sides.
for side in a b; do
  home="$ah"; [ "$side" = b ] && home="$bh"
  if ! jq -e '(.hooks // {}) | length > 0' "$home/.claude/settings.json" >/dev/null 2>&1; then
    echo "converge-check: VACUOUS -- side $side has no hooks in $home/.claude/settings.json; an install that wired nothing cannot 'converge'" >&2
    exit 3
  fi
done

# Unusable snapshot guard: a file that would not parse is not state to compare.
for side in a b; do
  if grep -q '^(unreadable' "$tmp/$side.txt"; then
    echo "converge-check: UNREADABLE -- side $side has a JSON file jq could not parse; a broken install cannot 'converge':" >&2
    grep '^(unreadable' "$tmp/$side.txt" >&2
    exit 3
  fi
done

if diff -u --label "side-a (${ap##*/})" --label "side-b (${bp##*/})" "$tmp/a.txt" "$tmp/b.txt"; then
  echo "converge-check: CONVERGED ($(wc -l < "$tmp/a.txt") snapshot lines identical after path normalization)"
  exit 0
fi
echo "converge-check: DIVERGED" >&2
exit 1
