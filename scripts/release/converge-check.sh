#!/usr/bin/env bash
# converge-check.sh -- do two himmel installs end in the SAME state?
# (HIMMEL-3059 ADR Q3: the tarball path and the clone path both end in
# `himmelctl install`; that convergence is ASSERTED here, not assumed.)
# An optional third side c (HIMMEL-3059 S5: the AUR package, prefix
# /opt/himmel) is diffed against side a the same way; any pair that
# differs fails the run.
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
# homes are "identical"), so that is refused (exit 3) rather than passed -- counting
# COMPARED ENTRIES, not event keys, so {"hooks":{"PreToolUse":[]}} does not count as
# wired. The same for --a-target/--b-target when NEITHER repo has a git hook.
#
# USAGE:
#   converge-check.sh --a-home <d> --a-prefix <d> --b-home <d> --b-prefix <d> \
#                     [--c-home <d> --c-prefix <d>] \
#                     [--a-target <repo> --b-target <repo> [--c-target <repo>]]
#   (with a side c and targets, --c-target is required too)
# Exit: 0 identical | 1 differ (diff on stdout) | 2 usage | 3 vacuous snapshot
# shellcheck disable=SC2015  # `A && B || usage` -- usage exits, so C never runs after a true A
set -uo pipefail

usage() { sed -n '/^# USAGE:/,/^# Exit:/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

ah="" ap="" bh="" bp="" at="" bt="" ch="" cp="" ct=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case "$1" in
    --a-home) ah="$2" ;; --a-prefix) ap="$2" ;; --a-target) at="$2" ;;
    --b-home) bh="$2" ;; --b-prefix) bp="$2" ;; --b-target) bt="$2" ;;
    --c-home) ch="$2" ;; --c-prefix) cp="$2" ;; --c-target) ct="$2" ;;
    *) usage ;;
  esac
  shift 2
done
[ -n "$ah" ] && [ -n "$ap" ] && [ -n "$bh" ] && [ -n "$bp" ] || usage
{ [ -n "$at" ] && [ -z "$bt" ]; } && usage
{ [ -z "$at" ] && [ -n "$bt" ]; } && usage
{ [ -n "$ch" ] && [ -z "$cp" ]; } && usage
{ [ -z "$ch" ] && [ -n "$cp$ct" ]; } && usage
{ [ -n "$ch" ] && [ -n "$at" ] && [ -z "$ct" ]; } && usage
{ [ -z "$at" ] && [ -n "$ct" ]; } && usage
sides="a b"; [ -n "$ch" ] && sides="a b c"
command -v jq >/dev/null 2>&1 || { echo "converge-check: jq is required" >&2; exit 2; }

# mask <line> <path> <token> -- sets REPLY: every occurrence of <path> that ends on
# a path boundary becomes <token>. A longer sibling (<path>-old, <path>.bak) is a
# DIFFERENT location and must stay visible, or a leak into it would be masked.
mask() {
  local rest="$1" needle="$2" token="$3" out="" quote="" esc=0 chunk i c
  while [[ "$rest" == *"$needle"* ]]; do
    chunk="${rest%%"$needle"*}"
    # Track quote state across the text consumed so far: ':', ';' and whitespace are
    # only real token separators OUTSIDE a quoted value -- inside one (the common
    # case, since jq -S / the hook scripts always quote the whole string) they are
    # just filename bytes, same as '+' or '~' below (HIMMEL-3442). A backslash-escaped
    # quote (jq's own JSON escaping of a literal '"' inside a string) is not a real
    # delimiter and must not flip quote state -- track escaping too, one char lookahead.
    for (( i=0; i<${#chunk}; i++ )); do
      c="${chunk:i:1}"
      if [ "$esc" = 1 ]; then
        esc=0
      elif [ "$c" = "\\" ]; then
        esc=1
      elif [ -z "$quote" ]; then
        case "$c" in '"'|"'") quote="$c" ;; esac
      elif [ "$c" = "$quote" ]; then
        quote=""
      fi
    done
    out+="$chunk"
    rest="${rest#*"$needle"}"
    # A rejected sibling keeps a \001 after its first char, so a LATER mask (home is
    # usually a parent of the prefix) cannot re-match it; norm() strips the marks.
    # Boundary is a DENYLIST, not an allowlist: almost any byte can legally continue
    # a POSIX filename ('+', '~', '@', ',', '=', '%', ':', ';', whitespace, ... are
    # all valid), so only end-of-token, '/' (a real subpath), the matching closing
    # quote, or -- OUTSIDE any quote -- '"'/"'", ':', ';' and whitespace (the token
    # separators this snapshot's generated text actually emits around a path) count
    # as a boundary. Anything else marks a DIFFERENT sibling location, never masked.
    case "$rest" in
      "") out+="$token" ;;
      '/'*) out+="$token" ;;
      '"'*|"'"*)
        if [ -z "$quote" ] || [ "${rest:0:1}" = "$quote" ]; then out+="$token"
        else out+="${needle:0:1}"$'\001'"${needle:1}"; fi ;;
      ':'*|';'*|[[:space:]]*)
        if [ -z "$quote" ]; then out+="$token"
        else out+="${needle:0:1}"$'\001'"${needle:1}"; fi ;;
      *) out+="${needle:0:1}"$'\001'"${needle:1}" ;;
    esac
  done
  REPLY="$out$rest"
}

# norm <home> <prefix> <target> -- stdin -> stdout, own paths masked (prefix first:
# it is usually nested under home). The two installs use different target repos, so
# the target's own path is location, not state -- masked like the others.
norm() {
  local home="$1" prefix="$2" target="$3" line
  while IFS= read -r line || [ -n "$line" ]; do
    mask "$line" "$prefix" '{PREFIX}'
    [ -n "$target" ] && mask "$REPLY" "$target" '{TARGET}'
    mask "$REPLY" "$home" '{HOME}'
    printf '%s\n' "${REPLY//$'\001'/}"
  done
}

# snapshot <home> <prefix> <target> -- prints the normalized state.
snapshot() {
  local home="$1" prefix="$2" target="$3" f
  home="$(cd -- "$home" 2>/dev/null && pwd -P)" || home="$1"
  prefix="$(cd -- "$prefix" 2>/dev/null && pwd -P)" || prefix="$2"
  if [ -n "$target" ]; then target="$(cd -- "$target" 2>/dev/null && pwd -P)" || target="$3"; fi
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
    # ponytail: the seed is compared by FILE LIST only, not contents -- seeded files may carry
    # timestamps or ids that would false-diverge; the guest run (green at 0aacaa42, HIMMEL-3262)
    # converged on file lists, so tightening to normalized contents is a follow-up, not a gate.
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
        for f in $(find "$hooks" -maxdepth 1 \( -type f -o -type l \) -printf '%f\n' | LC_ALL=C sort); do  # gnu-ok: only ever runs on the Linux guest (the tarball is Linux-only), where find -printf is findutils' own
          case "$f" in *.sample) continue ;; esac
          echo "# hook: $f"
          cat "$hooks/$f" 2>/dev/null || echo "(unreadable: hook $f)"
          if [ -x "$hooks/$f" ]; then echo "# mode: executable"; else echo "# mode: NOT executable (git ignores it)"; fi
        done
      else
        echo "(no hooks dir)"
      fi
      echo "## target-settings"
      if [ -f "$target/.claude/settings.json" ]; then jq -S . "$target/.claude/settings.json" 2>/dev/null || echo "(unreadable: target settings.json)"; else echo "(absent)"; fi
    fi
  } | norm "$home" "$prefix" "$target"
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/himmel-converge.XXXXXX")" || { echo "converge-check: cannot create a scratch dir" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT
snapshot "$ah" "$ap" "$at" > "$tmp/a.txt"
snapshot "$bh" "$bp" "$bt" > "$tmp/b.txt"
[ -n "$ch" ] && snapshot "$ch" "$cp" "$ct" > "$tmp/c.txt"

# Vacuous guard: settings.json must exist and carry hooks on EVERY side.
for side in $sides; do
  case "$side" in a) home="$ah" ;; b) home="$bh" ;; c) home="$ch" ;; esac
  if ! jq -e '[(.hooks // {}) | .[] | length] | add // 0 | . > 0' "$home/.claude/settings.json" >/dev/null 2>&1; then
    echo "converge-check: VACUOUS -- side $side has no hooks in $home/.claude/settings.json; an install that wired nothing cannot 'converge'" >&2
    exit 3
  fi
done

# Vacuous gates: with targets supplied, two installs that wired NO git hook anywhere
# have not "converged" on the project gates, they have both done nothing. (One side
# having a hook and the other not is a real difference -- the diff below reports it.)
if [ -n "$at" ]; then
  nhooks=0
  for side in $sides; do nhooks=$((nhooks + $(grep -c '^# hook: ' "$tmp/$side.txt"))); done
  if [ "$nhooks" -eq 0 ]; then
    echo "converge-check: VACUOUS -- neither target repo has a git hook; a project install that wired no gate cannot 'converge'" >&2
    exit 3
  fi
fi

# Unusable snapshot guard: a file that would not parse is not state to compare.
for side in $sides; do
  if grep -q '^(unreadable' "$tmp/$side.txt"; then
    echo "converge-check: UNREADABLE -- side $side has a JSON file jq could not parse; a broken install cannot 'converge':" >&2
    grep '^(unreadable' "$tmp/$side.txt" >&2
    exit 3
  fi
done

# Every other side is diffed against side a; one diverging pair fails the run.
diverged=0
for side in $sides; do
  [ "$side" = a ] && continue
  case "$side" in b) sp="$bp" ;; c) sp="$cp" ;; esac
  if diff -u --label "side-a (${ap##*/})" --label "side-$side (${sp##*/})" "$tmp/a.txt" "$tmp/$side.txt"; then
    echo "converge-check: side-a vs side-$side CONVERGED"
  else
    echo "converge-check: side-a vs side-$side DIVERGED" >&2
    diverged=1
  fi
done
if [ "$diverged" -eq 0 ]; then
  echo "converge-check: CONVERGED ($(wc -l < "$tmp/a.txt") snapshot lines identical after path normalization)"
  exit 0
fi
echo "converge-check: DIVERGED" >&2
exit 1
