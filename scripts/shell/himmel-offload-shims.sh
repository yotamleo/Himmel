#!/usr/bin/env bash
# shellcheck shell=bash

__himmel_root=
__himmel_shim_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)

if [ -n "${HIMMEL_ROOT:-}" ] && [ -f "$HIMMEL_ROOT/scripts/claude-codex" ]; then
  __himmel_root="$HIMMEL_ROOT"
else
  # Shim-relative resolution only — the shim is sourced by its absolute path, so
  # its own parent-of-parent IS the checkout. If that does not hold, leave
  # __himmel_root empty (fail closed) rather than guessing a candidate path that
  # could silently bind the launchers to an unrelated repo (CodeRabbit).
  __himmel_candidate=$(cd -- "$__himmel_shim_dir/../.." 2>/dev/null && pwd -P)
  if [ -f "$__himmel_candidate/scripts/claude-codex" ]; then
    __himmel_root="$__himmel_candidate"
  fi
fi

if [ -n "$__himmel_root" ] && [ -f "$__himmel_root/scripts/claude-codex" ]; then
  cc-codex() { bash "$__himmel_root/scripts/claude-codex" "$@"; }
fi

if [ -n "$__himmel_root" ] && [ -f "$__himmel_root/scripts/claude-glm" ]; then
  cc-glm() { bash "$__himmel_root/scripts/claude-glm" "$@"; }
fi

himmel_offload_shims_install() {
  local shim_path bashrc esc_path source_line
  shim_path="$__himmel_shim_dir/$(basename -- "${BASH_SOURCE[0]}")"
  bashrc="${HOME:?HOME is required}/.bashrc"
  # Single-quote the path so a checkout path containing $(), backticks, " or a
  # newline is persisted as an inert literal, never executed when the shell
  # later sources ~/.bashrc. Only an embedded single-quote needs escaping inside
  # single-quotes (the '\'' idiom) — everything else is literal (CodeRabbit).
  esc_path=${shim_path//\'/\'\\\'\'}
  source_line="[ -f '$esc_path' ] && . '$esc_path'"
  # Normalize CRLF before matching: a Windows Git Bash ~/.bashrc may carry
  # CRLF line endings, and grep -Fqx of an LF-terminated pattern would miss an
  # existing CRLF line, appending a duplicate on every install re-run.
  if [ ! -f "$bashrc" ] || ! tr -d '\r' < "$bashrc" | grep -Fqx "$source_line"; then
    printf '\n%s\n' "$source_line" >> "$bashrc"
  fi
}

if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  case "${1:-}" in
    install) himmel_offload_shims_install ;;
    *) echo "Usage: bash scripts/shell/himmel-offload-shims.sh install" >&2; exit 2 ;;
  esac
fi
