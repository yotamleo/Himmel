#!/usr/bin/env bash
# scripts/lib/flake-repo-id.sh — the suite-flake ledger's repo id, ONE definition
# (HIMMEL-5145, HIMMEL-5147). Sourced by scripts/ci/run-shell-tests.sh (the
# writer) and scripts/observability/suite-flake-summary.sh (the reader); a copy
# in either place is how the two drifted before. Sourcing defines functions only.

# _flake_join <base> <rel> — <rel> resolved against the absolute <base>, `.` and
# `..` collapsed lexically (no filesystem access, no globbing).
_flake_join() {
  local _rest="$1/$2" _seg _out=""
  while [ -n "$_rest" ]; do
    _seg=${_rest%%/*}
    case "$_rest" in */*) _rest=${_rest#*/} ;; *) _rest="" ;; esac
    case "$_seg" in
      ''|.) ;;
      ..) _out=${_out%/*} ;;
      *) _out="$_out/$_seg" ;;
    esac
  done
  printf '%s' "${_out:-/}"
}

# _flake_norm_url <url> [<base>] — the origin reduced to host/path so the https,
# https+.git, ssh and scp spellings of one origin agree: scheme, user and
# trailing slash dropped, host lowercased, a default port (ssh 22, https 443,
# http 80) dropped, and a trailing .git dropped. A plain local path (no scheme,
# no scp colon) is none of those: it stays case-exact and keeps its .git, since
# Repo and repo, or r and r.git, are different directories. A file:// URL is that
# local path, so file:///srv/r.git is /srv/r.git and never /srv/r (HIMMEL-5156).
# A relative local path is resolved against <base> when one is given, so
# ../r.git from two different parents is two ids (HIMMEL-5156).
_flake_norm_url() {
  local _u="$1" _b="${2:-}" _s="" _h _r _p _d="" _net=0
  case "$_u" in
    file://*) _u=${_u#file://}; _u=${_u#localhost} ;;
    *://*) _s=$(printf '%s' "${_u%%://*}" | tr '[:upper:]' '[:lower:]'); _u=${_u#*://}; _net=1 ;;
    *) case "${_u%%/*}" in *:*) _u="${_u%%:*}/${_u#*:}"; _net=1 ;; esac ;;
  esac
  if [ "$_net" = 0 ]; then
    case "$_u" in
      /*) ;;
      *) [ -n "$_b" ] && _u=$(_flake_join "$_b" "$_u") ;;
    esac
    printf '%s' "${_u%/}"
    return 0
  fi
  case "${_u%%/*}" in *@*) _u=${_u#*@} ;; esac
  _u=${_u%/}; _u=${_u%.git}; _u=${_u%/}
  _h=${_u%%/*}; _r=${_u#"$_h"}
  case "$_s" in ssh) _d=22 ;; https) _d=443 ;; http) _d=80 ;; esac
  case "$_h" in
    *:*)
      _p=${_h##*:}
      case "$_p" in ''|*[!0-9]*) ;; *) [ "$_p" = "$_d" ] && _h=${_h%:*} ;; esac ;;
  esac
  printf '%s%s' "$(printf '%s' "$_h" | tr '[:upper:]' '[:lower:]')" "$_r"
}

# _flake_repo_id <dir> — the default repo id for the checkout at <dir>: a cksum
# of the normalised origin URL (never the URL, which may embed a credential),
# else of the git common dir, so every worktree of one repo shares an id. A
# relative origin is resolved against the main checkout (the common dir's
# parent), not <dir>, so a linked worktree keeps its checkout's id.
_flake_repo_id() {
  local _url _common _base
  _url=$(git -C "$1" config --get remote.origin.url 2>/dev/null)
  _common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  if [ -n "$_url" ]; then
    case "${_common:-}" in
      */.git) _base=${_common%/.git} ;;
      '') _base=$(cd "$1" 2>/dev/null && pwd) ;;
      *) _base=$_common ;;
    esac
    printf 'origin-%s' "$(_flake_norm_url "$_url" "$_base" | cksum | cut -d' ' -f1)"
  else
    printf 'dir-%s' "$(printf '%s' "${_common:-$1}" | cksum | cut -d' ' -f1)"
  fi
}
