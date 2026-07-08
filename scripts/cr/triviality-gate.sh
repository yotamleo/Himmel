#!/usr/bin/env bash
# triviality-gate - deterministic CR triviality classifier (HIMMEL-737).
# Reads ONE unified diff on stdin, prints exactly one verdict line to stdout
# ('trivial' or 'nontrivial'), one short reason line to stderr, and exits 0 on
# any verdict (exit 2 only on usage error). WIRED into critic-panel.sh (a
# trivial verdict strips the paid tier); the CLI form remains standalone.
#
# Decision order: override=full -> fail-closed (empty/pathless) -> safety
# carve-out -> override=trivial -> docs-only -> one-liner -> substantive.
# 'trivial' never beats fail-closed or safety paths (codex-adv).
# Pure function (deterministic from diff text + CR_TRIVIALITY_OVERRIDE) plus a
# CLI form guarded by BASH_SOURCE[0] = $0. Mirrors scripts/cr/lane-classify.sh.
# bash 3.2-safe (no mapfile, no associative arrays); ASCII only; no .ps1 twin.
set -euo pipefail

# Rule 2 helper: is a changed path safety-critical (never trivial, any size)?
# Under scripts/hooks/, scripts/guardrails/, .claude/, or .github/; equal to
# .pre-commit-config.yaml; or basename CLAUDE.md / AGENTS.md / llms.txt.
path_is_safety() {
  case "$1" in
    scripts/hooks/*|scripts/guardrails/*|.claude/*|.github/*) return 0 ;;
    # HIMMEL-737 CR: the gate must not be able to blind the pipeline that
    # runs it - the CR scripts, the hermes invocation path the panel rides
    # (invoke.sh / dispatch-trusted.sh / parity assets), the lane registry,
    # and the backend router registry are safety surface too (a one-line
    # edit here must never skip the paid critic).
    scripts/cr/*|scripts/hermes/*|scripts/lanes/*) return 0 ;;
  esac
  case "${1##*/}" in
    CLAUDE.md|AGENTS.md|llms.txt|.pre-commit-config.yaml|backends.json) return 0 ;;
  esac
  return 1
}

# Rule 3 helper: is a changed path a doc/license (docs-only eligible)?
# *.md / *.markdown / *.txt, basename LICENSE*, or under docs/.
path_is_doc() {
  case "$1" in
    docs/*) return 0 ;;
    *.md|*.markdown|*.txt) return 0 ;;
  esac
  case "${1##*/}" in
    LICENSE*) return 0 ;;
  esac
  return 1
}

# Pure classifier. $1 = unified diff text. Prints 'verdict<TAB>reason' on one
# line. Reads CR_TRIVIALITY_OVERRIDE from env; warns to stderr on unknown value
# and falls through to the heuristic.
classify_triviality() {
  local diff_text="$1"
  local override="${CR_TRIVIALITY_OVERRIDE:-}"
  local line rest apath bpath path
  local nfiles=0 nlines=0 any_safety=0 all_docs=1

  # Rule 1: env override. Only 'full' (force nontrivial = force the FULL
  # panel) has absolute precedence. 'trivial' is applied AFTER the
  # fail-closed and safety-path checks below (codex-adv: a stale/hostile
  # CR_TRIVIALITY_OVERRIDE=trivial must never drop the paid critic on the
  # pipeline's own trust boundary - safety paths win over the override).
  if [ -n "$override" ]; then
    case "$override" in
      full)    printf 'nontrivial\toverride\n'; return 0 ;;
      trivial) ;;  # deferred below
      *)
        echo "triviality-gate: unknown CR_TRIVIALITY_OVERRIDE='$override', ignoring" >&2
        override=""
        ;;  # fall through to the heuristic
    esac
  fi

  # CONTRACT: empty stdin fails closed.
  if [ -z "$diff_text" ]; then
    printf 'nontrivial\tempty-diff fail-closed\n'; return 0
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"  # tolerate CRLF-terminated diffs
    case "$line" in
      "diff --git "*)
        nfiles=$((nfiles + 1))
        rest="${line#diff --git a/}"   # '<apath> b/<bpath>'
        apath="${rest% b/*}"           # drop shortest trailing ' b/<rest>'
        bpath="${rest##* b/}"          # drop longest leading '<apath> b/'
        if [ "$bpath" = "dev/null" ]; then
          path="$apath"                # deletion: b/ is /dev/null -> use a/ path
        else
          path="$bpath"
        fi
        if path_is_safety "$path"; then any_safety=1; fi
        if ! path_is_doc "$path"; then all_docs=0; fi
        ;;
      [-+]*)
        # HIMMEL-737: skip ONLY the exact file-header forms git emits
        # ('--- a/<path>', '+++ b/<path>', '--- /dev/null', '+++ /dev/null' -
        # note the space). The prior '+++*|---*' also swallowed real body
        # changes whose content began with '--'/'++' (a removed '--flag' arrives
        # as diff line '---flag'; an added '++i' as '+++i'), undercounting
        # nlines and misclassifying substantive diffs as trivial one-liners.
        case "$line" in
          "--- a/"*|"+++ b/"*|"--- /dev/null"|"+++ /dev/null") ;;  # file header line
          *) nlines=$((nlines + 1)) ;;  # +/- body line (@@ headers start with @)
        esac
        ;;
    esac
  done <<< "$diff_text"

  # Non-empty but pathless diff (no 'diff --git' parsed): fail closed.
  if [ "$nfiles" -eq 0 ]; then
    printf 'nontrivial\tno-paths fail-closed\n'; return 0
  fi

  # Rules 2-5, in order.
  if [ "$any_safety" -eq 1 ]; then
    printf 'nontrivial\tsafety-path\n'; return 0
  fi
  # Deferred 'trivial' override: beats the remaining size/type heuristics
  # only - never the fail-closed or safety-path rules above.
  if [ "$override" = "trivial" ]; then
    printf 'trivial\toverride\n'; return 0
  fi
  if [ "$all_docs" -eq 1 ]; then
    printf 'trivial\tdocs-only\n'; return 0
  fi
  if [ "$nfiles" -le 1 ] && [ "$nlines" -le 2 ]; then
    printf 'trivial\tone-liner\n'; return 0
  fi
  printf 'nontrivial\tsubstantive\n'
}

# CLI form (not sourced): read one unified diff on stdin, route verdict to
# stdout and reason to stderr.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  [ $# -eq 0 ] || { echo "usage: triviality-gate.sh < unified-diff" >&2; exit 2; }
  diff_input="$(cat)"
  result="$(classify_triviality "$diff_input")"
  printf '%s\n' "${result%%$'\t'*}"
  printf '%s\n' "${result#*$'\t'}" >&2
  exit 0
fi
