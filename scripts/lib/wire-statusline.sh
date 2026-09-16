#!/usr/bin/env bash
# wire-statusline.sh — single source of truth for wiring the himmel statusLine
# into a Claude Code settings.json (HIMMEL-359). Used by adopt.sh, setup.sh,
# and machine-setup/ubuntu.sh so the command string + merge logic live in one
# place instead of being duplicated per installer.
#
# Usage:
#   bash wire-statusline.sh <settings-json-path> <himmel-path>
#
# Does THREE things (HIMMEL-718 Task 4.1 — the wiring switch to the forked
# claude-hud renderer; the vendored bash bar is RETAINED as fallback):
#   1. .statusLine = { type: "command",
#                      command: "node \"<himmel>/marketplace/plugins/claude-hud/dist/index.js\"" }
#   2. .env.CLAUDE_HUD_ALLOW_EXTRA_CMD = "1"  (merged, preserving other env keys)
#      — activates hud's customLineCommand extra-cmd gate.
#   3. Drops the hud config: reads
#      marketplace/plugins/claude-hud/config/himmel-config.json from the himmel
#      clone, substitutes every <himmel-path> with this clone's path, and writes
#      it to ${CLAUDE_CONFIG_DIR:-~/.claude}/plugins/claude-hud/config.json
#      (CLAUDE_CONFIG_DIR trimmed, whitespace-only treated as unset — matching
#      the hud's own getClaudeConfigDir).
#      That path is the CONFIG DIR, always — never derived from the settings
#      file's own directory (HIMMEL-2892). The hud config is per-USER config,
#      not per-project: deriving it relative to the settings path dropped an
#      untracked .claude/plugins/claude-hud/config.json INSIDE the repo on
#      every project-scope install.
#   4. Drops the hud's RUNTIME cache state in that same dir whenever the wiring
#      actually CHANGED (HIMMEL-3065) — see _wire_statusline_purge_hud_cache.
#      That drop happens BEFORE (1) and (2) publish anything, so a failed purge
#      aborts the wire with the OLD wiring still on disk and the retry sees the
#      same change it did.
#
# Idempotent (re-running yields the same result), atomic (temp file + mv), and
# non-destructive (all other keys / all other env keys preserved; file + parent
# dir created if absent). Requires jq. Paths are forward-slashed.
set -euo pipefail

# The Claude Code config dir — mirror of the HUD's own getClaudeConfigDir()
# (marketplace/plugins/claude-hud/src/claude-config-dir.ts): CLAUDE_CONFIG_DIR
# wins, with a leading `~` expanded; otherwise $HOME/.claude.
#
# The value is TRIMMED first, exactly as the consumer does
# (`process.env.CLAUDE_CONFIG_DIR?.trim()`), and a whitespace-only value is
# therefore treated as UNSET. Without the trim the two disagree: the installer
# would write the hud config under a padded — i.e. different — directory from
# the one the hud reads it back from, and a whitespace-only value would make
# bash resolve a RELATIVE directory literally named with spaces. The
# PowerShell twin already had this via IsNullOrWhiteSpace.
_wire_statusline_config_dir() {
  local d="${CLAUDE_CONFIG_DIR:-}"
  # Strip leading and trailing whitespace (bash 3.2-safe: no ${var@Q}, no =~).
  d="${d#"${d%%[![:space:]]*}"}"
  d="${d%"${d##*[![:space:]]}"}"
  if [ -z "$d" ]; then
    printf '%s\n' "$HOME/.claude"
    return 0
  fi
  # shellcheck disable=SC2088  # matching/stripping a literal '~/' prefix, not expanding one
  case "$d" in
    '~') d="$HOME" ;;
    '~/'*) d="$HOME/${d#\~/}" ;;
  esac
  printf '%s\n' "$d"
}

# Drop the hud's RUNTIME cache state — everything the hud writes under its
# plugin dir EXCEPT the config.json this script owns (HIMMEL-3065).
#
# That dir holds per-session snapshots, not settings: transcript-cache/ (session
# tokens, the prompt-cache anchor + TTL, compaction state), context-cache/ (the
# context-window fallback frame), config-cache/, plus the cache-economics and
# daily-cost ledgers. Wiring a DIFFERENT install over an existing one — the
# migration case: an earlier himmel instance, a moved or renamed clone — leaves
# that state behind, and the hud then renders the PREVIOUS install's counts
# (with an already-expired cache clock, and no cost figure once the stale
# snapshot no longer satisfies the cost path). Only the caller decides when this
# runs: a steady-state re-wire must NOT purge, or every himmel-update would
# throw away the context fallback snapshot of every live session.
#
# Denylist, not allowlist: the hud gains state files over time (daily-cost.json
# is itself recent), and a list enumerated here would silently stop covering
# them — which is the bug this function exists to fix. Dotfiles are skipped,
# and that is load-bearing in BOTH directions: the hud's own interrupted-write
# temp files are inert, and the caller stages its new config.json as a DOTFILE
# (.config.json.tmp) precisely so the purge — which runs before either file is
# published — cannot delete the config it is about to install.
_wire_statusline_purge_hud_cache() {
  local hud_dir="$1" entry dropped=0
  [ -d "$hud_dir" ] || return 0
  for entry in "$hud_dir"/*; do
    # An unmatched glob stays literal in bash — skip it rather than rm it.
    [ -e "$entry" ] || continue
    case "${entry##*/}" in
      config.json) continue ;;
    esac
    rm -rf "$entry" || return 1
    dropped=1
  done
  [ "$dropped" -eq 1 ] && echo "  dropped stale hud cache state → $hud_dir"
  return 0
}

wire_statusline() {
  local settings="$1" himmel="$2"
  command -v jq >/dev/null 2>&1 || { echo "wire-statusline: jq required" >&2; return 1; }

  # Forward-slash the himmel path so the `node "..."` command is valid even
  # when a caller passes a Windows backslash path (Git Bash tolerates /c/... ).
  local himmel_fwd="${himmel//\\//}"
  local cmd="node \"${himmel_fwd}/marketplace/plugins/claude-hud/dist/index.js\""

  # The hud's plugin dir is per-USER (the config dir), never derived from the
  # settings path — see (3) below. Resolved up here because the previous hud
  # config is read from it BEFORE the write, to decide whether the wiring
  # changed (4).
  local hud_dir; hud_dir="$(_wire_statusline_config_dir)/plugins/claude-hud"
  local prev_hud_cfg=""
  [ -f "$hud_dir/config.json" ] && prev_hud_cfg="$(cat "$hud_dir/config.json")"

  local settings_dir; settings_dir="$(dirname "$settings")"
  mkdir -p "$settings_dir"
  local base="{}"
  if [ -s "$settings" ]; then
    base=$(cat "$settings")
    # An empty / whitespace-only file → treat as {} (jq would choke on it).
    # A non-empty but INVALID file → refuse, rather than clobber data.
    if [ -z "$(printf '%s' "$base" | tr -d '[:space:]')" ]; then
      base="{}"
    elif ! printf '%s' "$base" | jq -e . >/dev/null 2>&1; then
      echo "wire-statusline: $settings is not valid JSON — refusing to overwrite" >&2
      return 1
    fi
  fi

  # The command currently wired, if any — one half of the changed-wiring test
  # in (4). Read from the validated $base, so an absent/empty file yields "".
  local prev_cmd; prev_cmd="$(printf '%s' "$base" | jq -r '.statusLine.command? // ""')"

  # (1) Stage the hud config under the CONFIG DIR, substituting this clone's
  # path for the <himmel-path> placeholder. Guarded on the source existing so
  # tests wiring against a synthetic himmel path stay a pure statusLine/env op.
  # HIMMEL-2892: the destination is ${CLAUDE_CONFIG_DIR:-~/.claude}, never
  # $settings_dir — even when the caller passes a PROJECT settings path. The
  # hud reads its config from the config dir, so a copy beside a project's
  # .claude/settings.json is both inert and an untracked file dropped inside
  # someone's repo (observed on the himmel checkout itself, 2026-09-09).
  local hud_src="${himmel_fwd}/marketplace/plugins/claude-hud/config/himmel-config.json"
  local hud_cfg=""
  if [ -f "$hud_src" ]; then
    mkdir -p "$hud_dir"
    hud_cfg="$(cat "$hud_src")"
    hud_cfg="${hud_cfg//<himmel-path>/$himmel_fwd}"
    printf '%s\n' "$hud_cfg" > "$hud_dir/.config.json.tmp" \
      || { rm -f "$hud_dir/.config.json.tmp"; return 1; }
    # Validate the substituted config is still JSON before publishing it — a
    # JSON-breaking himmel path (e.g. an embedded quote) would otherwise yield a
    # config.json the renderer fails on silently at render time.
    if ! jq -e . "$hud_dir/.config.json.tmp" >/dev/null 2>&1; then
      rm -f "$hud_dir/.config.json.tmp"
      echo "wire-statusline: substituted hud config is not valid JSON — refusing to write" >&2
      return 1
    fi
  fi

  # (2) HIMMEL-3065: the wiring CHANGED when either half differs from what was
  # already on this machine — a different hud config, or an EXISTING statusLine
  # command that pointed somewhere else (a moved or renamed clone, an older
  # himmel instance). Both are compared against values captured BEFORE anything
  # is published. A re-run that changes neither purges nothing, so a live
  # session keeps its snapshots.
  #
  # The command half requires a NON-EMPTY previous command, because the two
  # halves have different scopes: the config is per-USER, but $settings may be
  # a PROJECT file. Wiring a machine's second project would otherwise read an
  # empty prev_cmd, call it a change, and purge the caches of every OTHER
  # project's live session on an install that did not move at all (codex-2).
  # No migration is lost to that: the dropped config embeds the clone path, so
  # a moved clone always differs in the config half — which also covers the
  # genuine first wire, where the previous config is absent and therefore
  # differs. $hud_cfg is "" only when the source config is absent
  # (synthetic-path callers, e.g. tests); the command half then decides alone.
  #
  # The purge runs BEFORE either file is published, and a failed purge aborts
  # the wire with NOTHING written (CR round 2): publish-then-purge left a
  # failed purge unrepeatable — the retry saw wiring that already matched,
  # took the no-change path, and the stale state it was meant to drop survived
  # every subsequent run. Aborting first keeps the old wiring on disk, so the
  # retry still sees a changed wiring and purges again.
  if { [ -n "$prev_cmd" ] && [ "$prev_cmd" != "$cmd" ]; } || { [ -n "$hud_cfg" ] && [ "$prev_hud_cfg" != "$hud_cfg" ]; }; then
    _wire_statusline_purge_hud_cache "$hud_dir" \
      || { rm -f "$hud_dir/.config.json.tmp"; return 1; }
  fi

  # (3) statusLine → hud renderer, (4) merge the extra-cmd gate into .env
  # (creating .env if absent, preserving every other env key). Fail LOUD on a
  # failed transform/write: a bare `… && mv` swallows the failure when the
  # caller runs us in an `if !` / errexit-exempt context and would report a
  # successful wire that never happened.
  printf '%s' "$base" | jq --arg cmd "$cmd" \
    '.statusLine = { type: "command", command: $cmd }
     | .env.CLAUDE_HUD_ALLOW_EXTRA_CMD = "1"' \
    > "$settings.statusline.tmp" || { rm -f "$settings.statusline.tmp"; return 1; }
  mv "$settings.statusline.tmp" "$settings" || return 1

  # (5) Publish the staged hud config.
  if [ -f "$hud_dir/.config.json.tmp" ]; then
    mv "$hud_dir/.config.json.tmp" "$hud_dir/config.json" || return 1
  fi
  echo "  wired statusLine → $settings"
}

# Allow both `source wire-statusline.sh` (to call wire_statusline directly) and
# direct invocation `bash wire-statusline.sh <settings> <himmel>`.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ "$#" -ne 2 ]; then
    echo "usage: wire-statusline.sh <settings-json-path> <himmel-path>" >&2
    exit 2
  fi
  wire_statusline "$1" "$2"
fi
