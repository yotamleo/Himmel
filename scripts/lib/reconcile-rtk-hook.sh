#!/usr/bin/env bash
# reconcile-rtk-hook.sh — standalone "reconcile now" path for the rtk
# PreToolUse hook in a Claude Code settings.json (HIMMEL-399).
#
# WHY this exists separately from machine-setup:
#   `rtk init -g` (the external rtk tool, rtk-ai/rtk) appends a bare
#   `rtk hook claude` PreToolUse(Bash) entry to ~/.claude/settings.json
#   WITHOUT checking for an existing one — so running it twice stacks two
#   entries. himmel swaps that bare entry for the rtk-hook-guard.sh wrapper
#   (HIMMEL-241, the compound-find fix), but the swap by itself never
#   COLLAPSES the result: a guard entry plus a freshly re-added bare entry,
#   swapped again, yields two guard entries. The full machine-setup scripts
#   (ubuntu.sh / win11.ps1) run `rtk init -g` exactly once so they never hit
#   this; the gap is when an operator runs `rtk init -g` on its own, OUTSIDE
#   machine-setup. This helper is the on-demand reconcile for that case.
#
# CONTRACT: after this runs, the settings file holds EXACTLY ONE PreToolUse
#   hook object pointing at rtk-hook-guard.sh. It is idempotent (a second run
#   is a no-op) and duplicate-safe across every starting shape — fresh bare,
#   guard+bare leftover, N bare, N guard.
#
# SCOPE: operates on the ONE settings.json passed as $1. The rtk guard belongs
#   at USER scope only (~/.claude/settings.json): `rtk init -g` is global and
#   the guard is referenced by an absolute himmel path, so a project-scope copy
#   would only make the hook fire twice. Reconcile the user file; do not
#   register the guard at project scope. "No cross-scope dup" is therefore a
#   per-file guarantee — this helper never reaches outside its argument.
#
# Idempotent, atomic (temp + mv), non-destructive (all other keys/hooks
# preserved). Refuses to touch a non-JSON file. A missing/empty file means rtk
# registered nothing yet → no-op (run `rtk init -g` first). Requires jq.
#
# Usage:
#   bash reconcile-rtk-hook.sh <settings-json-path> <himmel-path>
set -uo pipefail

# Bare `rtk hook claude` (extra flags included) — mirrors the BARE_RTK_RE in
# scripts/machine-setup/ubuntu.sh so the standalone path and the in-setup swap
# agree on what counts as a raw rtk entry.
BARE_RTK_RE='^[[:space:]]*rtk[[:space:]]+hook[[:space:]]+claude([[:space:]]|$)'

reconcile_rtk_hook() {
  local settings="$1" himmel="$2"
  command -v jq >/dev/null 2>&1 || { echo "reconcile-rtk-hook: jq required" >&2; return 1; }

  # Missing or empty file → rtk has registered nothing to reconcile. Do NOT
  # create it (this helper reconciles an existing rtk registration; it does not
  # bootstrap one — that is `rtk init -g`'s job).
  if [ ! -s "$settings" ] || [ -z "$(tr -d '[:space:]' < "$settings")" ]; then
    echo "  reconcile-rtk-hook: no rtk hook to reconcile in $settings (run 'rtk init -g' first)."
    return 0
  fi
  if ! jq -e . "$settings" >/dev/null 2>&1; then
    echo "reconcile-rtk-hook: $settings is not valid JSON — refusing to modify" >&2
    return 1
  fi

  # Forward-slash the himmel path so `bash "..."` is valid even from a Windows
  # backslash path (Git Bash tolerates /c/...), matching wire-statusline.sh.
  local himmel_fwd="${himmel//\\//}"
  local guard="bash \"${himmel_fwd}/scripts/hooks/rtk-hook-guard.sh\""

  local before after
  before=$(jq -S . "$settings")

  # Two-stage transform:
  #   1. SWAP — every bare `rtk hook claude` hook object's command becomes the
  #      guard command (mirrors ubuntu.sh's inline swap filter, line ~548).
  #   2. DEDUP — keep only the FIRST guard hook object in document order; drop
  #      every later guard hook object, then prune any group whose hooks array
  #      went empty. Non-guard hooks and group fields (matcher, …) are untouched.
  # The DEDUP assignment is gated on `.hooks.PreToolUse` already existing so a
  # settings file that has no PreToolUse key is left byte-for-byte (no spurious
  # `PreToolUse: []` injected) — matching ubuntu.sh's "skip when absent" and the
  # non-destructive contract above.
  after=$(jq --arg re "$BARE_RTK_RE" --arg guard "$guard" '
    (.hooks.PreToolUse[]?.hooks[]? | select((.command // "") | test($re))).command = $guard
    | if ((.hooks? // {}) | has("PreToolUse")) then
        .hooks.PreToolUse |= (
          reduce .[] as $g ({out: [], seen: false};
            ( reduce ($g.hooks // [])[] as $h ({hooks: [], seen: .seen};
                if (($h.command // "") | contains("rtk-hook-guard.sh"))
                then (if .seen then . else {hooks: (.hooks + [$h]), seen: true} end)
                else {hooks: (.hooks + [$h]), seen: .seen}
                end)
            ) as $r
            | {out: (.out + [$g + {hooks: $r.hooks}]), seen: $r.seen})
          | .out
          | map(select(((.hooks // []) | length) > 0))
        )
      else . end
  ' "$settings") || { echo "reconcile-rtk-hook: jq transform failed — $settings unchanged" >&2; return 1; }

  if [ "$(printf '%s' "$after" | jq -S .)" = "$before" ]; then
    echo "  reconcile-rtk-hook: already reconciled (1 guard entry) — no change."
    return 0
  fi

  # Gate the success report on the write actually landing — a failed printf/mv
  # (read-only dir, disk full) must not report success, and must not orphan the
  # temp file next to the user's settings.
  if printf '%s\n' "$after" > "$settings.rtk-reconcile.tmp" \
     && mv "$settings.rtk-reconcile.tmp" "$settings"; then
    echo "  reconcile-rtk-hook: reconciled $settings → exactly one rtk-hook-guard entry."
  else
    rm -f "$settings.rtk-reconcile.tmp"
    echo "reconcile-rtk-hook: failed to write $settings — left unchanged" >&2
    return 1
  fi
}

# Allow both `source reconcile-rtk-hook.sh` and direct invocation.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  if [ "$#" -ne 2 ]; then
    echo "usage: reconcile-rtk-hook.sh <settings-json-path> <himmel-path>" >&2
    exit 2
  fi
  reconcile_rtk_hook "$1" "$2"
fi
