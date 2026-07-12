#!/usr/bin/env bash
# Regression test (HIMMEL-596): the three ADVISORY SessionStart hooks
# (inject-initiative, inject-where-are-we, inject-doc-freshness) must FIRE under
# Codex.
#
# Background. inject-initiative ships via .claude/settings.json; inject-where-are-we
# + inject-doc-freshness ship via the himmel-ops plugin hooks.json with a wrapper
# `h="$CLAUDE_PROJECT_DIR/scripts/hooks/<h>.sh"; [ -f "$h" ] && exec bash "$h"`.
# Codex injects CLAUDE_PLUGIN_ROOT for plugin hooks but NOT CLAUDE_PROJECT_DIR
# (and nothing for project hooks), so under Codex `$h` resolves empty,
# `[ -f "$h" ]` is false, and the hook SILENTLY NO-OPS — initiative / overnight
# mode, the where-are-we ledger, and the doc-freshness nudge never fire. Fix:
# wire all three into .codex/hooks.json SessionStart via run-hook.cmd --sandbox
# (the wrapper derives the repo root from its OWN location, harness-agnostically),
# exactly like check-update-available (the existing advisory SessionStart hook)
# and the HIMMEL-589 security guards.
#
# This suite asserts:
#   1) STATIC WIRING — each of the 3 hooks (+ retained check-update-available) is
#      wired into .codex/hooks.json SessionStart through run-hook.cmd; no raw
#      $CLAUDE_PROJECT_DIR/bare-bash path remains; the file parses and carries
#      ONLY a top-level `hooks` key (Codex's deny_unknown_fields strict schema).
#   2) BEHAVIORAL (advisory passthrough, end-to-end) — running the WIRED
#      inject-initiative command through run-hook.cmd (bash branch) with the Codex
#      env simulated (CLAUDE_PROJECT_DIR UNSET) emits its <system-reminder> on
#      STDOUT and exits 0 when the gate is ON, and emits nothing (exit 0) when the
#      gate is OFF. inject-initiative is pure local env+prose (no node/network),
#      so this is hermetic and proves a real advisory SessionStart hook fires
#      through the adapter under Codex.
#   3) SMOKE — inject-where-are-we + inject-doc-freshness run through their wired
#      command without crashing the wrapper (rc 0), tolerating empty output (their
#      full inject behavior is covered by their own test-inject-*.sh under Claude).
#
# Hermetic: no network, no .env required (process env wins via load_dotenv's
# non-clobber). The Windows cmd.exe branch of run-hook.cmd is covered by the
# existing .ps1 twin (test-codex-run-hook.ps1). bash 3.2-safe.
set -uo pipefail

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HOOKS_DIR/../.." && pwd)"
HOOKS_JSON="$REPO_ROOT/.codex/hooks.json"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

if ! command -v jq >/dev/null 2>&1; then
  echo "jq not on PATH — required for this test" >&2; exit 1
fi
[ -f "$HOOKS_JSON" ] || { echo ".codex/hooks.json not found: $HOOKS_JSON" >&2; exit 1; }

# Extract the (first) SessionStart hook command wiring a given hook filename.
wired_cmd() {
  jq -r --arg h "$1" \
    '.hooks.SessionStart[]?.hooks[]?.command // empty | select(contains($h))' \
    "$HOOKS_JSON" 2>/dev/null | head -1
}

# Run a hook via its WIRED .codex/hooks.json command, simulating the Codex env
# (CLAUDE_PROJECT_DIR UNSET — run-hook.cmd must re-derive + export it). Extra args
# are env overrides (e.g. HIMMEL_INITIATIVE=all). Feeds an empty SessionStart
# payload on stdin. Prints the command's stdout.
#
# Hermeticity: also strip the overnight-profile vars so an ambient
# HIMMEL_OVERNIGHT in the launching shell can't flip inject-initiative's
# resolve_legs onto HIMMEL_INITIATIVE_OVERNIGHT and turn the gate-ON case into a
# false red (the .env load is non-clobbering, so this guards only process-env
# leakage). CR: pr-test-analyzer HIMMEL-596.
HOOK_ENV_CLEAN="-u CLAUDE_PROJECT_DIR -u HIMMEL_OVERNIGHT -u HIMMEL_INITIATIVE_OVERNIGHT"
run_codex_hook() {
  local hook="$1"; shift
  local cmd; cmd="$(wired_cmd "$hook")"
  if [ -z "$cmd" ]; then printf '__NOT_WIRED__'; return; fi
  # shellcheck disable=SC2086 # $HOOK_ENV_CLEAN flags + $cmd are intentional splits
  ( cd "$REPO_ROOT" && printf '{"hook_event_name":"SessionStart"}' \
      | env $HOOK_ENV_CLEAN "$@" bash $cmd 2>/dev/null )
}

# ── 1) Static wiring: all advisory SessionStart hooks routed via run-hook.cmd ──
for h in inject-initiative.sh inject-where-are-we.sh inject-doc-freshness.sh check-update-available.sh; do
  c="$(wired_cmd "$h")"
  if [ -n "$c" ]; then ok "$h wired into .codex/hooks.json SessionStart"; else bad "$h wired into .codex/hooks.json SessionStart"; fi
  case "$c" in *run-hook.cmd*) ok "$h routed through run-hook.cmd";; *) bad "$h routed through run-hook.cmd (got: ${c:-<none>})";; esac
  case "$c" in *--sandbox*) ok "$h uses --sandbox mode";; *) bad "$h uses --sandbox mode (got: ${c:-<none>})";; esac
done

# No raw $CLAUDE_PROJECT_DIR / bare-bash path may remain in any SessionStart cmd
# (that is exactly the under-Codex no-op bug this ticket fixes).
raw="$(jq -r '.hooks.SessionStart[]?.hooks[]?.command // empty | select(contains("CLAUDE_PROJECT_DIR"))' "$HOOKS_JSON" 2>/dev/null)"
if [ -z "$raw" ]; then ok "no raw \$CLAUDE_PROJECT_DIR path in any SessionStart command"; else bad "raw \$CLAUDE_PROJECT_DIR path present: $raw"; fi

# Strict schema: file parses, and the ONLY top-level key is `hooks`
# (Codex's deny_unknown_fields rejects any extra top-level key).
if jq -e . "$HOOKS_JSON" >/dev/null 2>&1; then ok ".codex/hooks.json is valid JSON"; else bad ".codex/hooks.json is valid JSON"; fi
# Assert the ONLY top-level key is `hooks` directly in jq (no string munging — a
# trailing CR on Windows Git Bash would defeat a shell `=` compare).
if jq -e 'keys == ["hooks"]' "$HOOKS_JSON" >/dev/null 2>&1; then
  ok "strict schema: only top-level 'hooks' key"
else
  bad "strict schema: only top-level 'hooks' key (got: $(jq -rc 'keys' "$HOOKS_JSON" 2>/dev/null))"
fi

# ── 2) Behavioral: inject-initiative FIRES through the adapter under Codex ────
# The boundary that matters is NOT "run-hook.cmd emits stdout" (the security
# guards already prove passthrough) but "Codex receives the directive as
# context". Under Codex that channel is hookSpecificOutput.additionalContext, so
# the adapter wraps an advisory SessionStart hook's exit-0 output into that JSON
# (HIMMEL-596). Gate ON: HIMMEL_INITIATIVE=all → resolve_legs yields a non-empty
# interactive set → the directive is emitted as additionalContext JSON, exit 0.
# CLAUDE_PROJECT_DIR is UNSET, so this also proves run-hook.cmd re-derives the
# repo root under Codex.
on_out="$(run_codex_hook inject-initiative.sh HIMMEL_INITIATIVE=all)"
if printf '%s' "$on_out" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null 2>&1; then
  ok "inject-initiative: gate ON → emitted as SessionStart additionalContext JSON"
else
  bad "inject-initiative: gate ON → SessionStart additionalContext JSON (got: ${on_out:-<empty>})"
fi
if printf '%s' "$on_out" | jq -e '.hookSpecificOutput.additionalContext | contains("is active")' >/dev/null 2>&1; then
  ok "inject-initiative: gate ON → additionalContext carries the directive"
else
  bad "inject-initiative: gate ON → additionalContext carries the directive (got: ${on_out:-<empty>})"
fi

# Gate OFF: HIMMEL_INITIATIVE=off → empty set → no output, exit 0.
off_out="$(run_codex_hook inject-initiative.sh HIMMEL_INITIATIVE=off)"
if [ -z "$off_out" ]; then ok "inject-initiative: gate OFF → no output"; else bad "inject-initiative: gate OFF → no output (got: $off_out)"; fi
off_cmd="$(wired_cmd inject-initiative.sh)"
# shellcheck disable=SC2086 # $HOOK_ENV_CLEAN flags + $off_cmd are intentional splits
( cd "$REPO_ROOT" && printf '{"hook_event_name":"SessionStart"}' | env $HOOK_ENV_CLEAN HIMMEL_INITIATIVE=off bash $off_cmd >/dev/null 2>&1 ); off_rc=$?
if [ "$off_rc" -eq 0 ]; then ok "inject-initiative: gate OFF → exit 0 (advisory, never blocks)"; else bad "inject-initiative: gate OFF → exit 0 (got rc=$off_rc)"; fi

# ── 3) Smoke: the node/git advisory hooks run through the wrapper, rc 0 ──────
# They may legitimately emit nothing on a bare runner (gated off / no node / no
# origin-main ref); the contract under test is "advisory → never crashes the
# wrapper, exit 0". Full inject behavior is covered by their own test-inject-*.sh.
for h in inject-where-are-we.sh inject-doc-freshness.sh; do
  h_cmd="$(wired_cmd "$h")"
  # shellcheck disable=SC2086 # $HOOK_ENV_CLEAN flags + $h_cmd are intentional splits
  ( cd "$REPO_ROOT" && printf '{"hook_event_name":"SessionStart"}' | env $HOOK_ENV_CLEAN bash $h_cmd >/dev/null 2>&1 ); rc=$?
  if [ "$rc" -eq 0 ]; then ok "$h: runs through run-hook.cmd, exit 0 (advisory)"; else bad "$h: runs through run-hook.cmd, exit 0 (got rc=$rc)"; fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
