#!/usr/bin/env bash
# Regression test (HIMMEL-599): himmel's SessionEnd hooks must FIRE under Codex
# via the Stop lifecycle event.
#
# Background. himmel has three SessionEnd hooks: refresh-where-are-we-on-end +
# jira-nudge-on-end (himmel-ops plugin hooks.json, exec-if-exists via
# $CLAUDE_PROJECT_DIR) and end-session-wiki (user-scope settings-template via
# run-pwsh.sh + the .sh twin). Under Codex none of them ran: .codex/hooks.json had
# no Stop key, and the plugin wrapper's $CLAUDE_PROJECT_DIR is unset under Codex
# (the same no-op class HIMMEL-596 fixed for SessionStart). Fix: wire all three
# into .codex/hooks.json Stop via run-hook.cmd --sandbox.
#
# Stop is SIDE-EFFECTING, not context-injecting. The authoritative Codex
# stop.command.output schema carries NO additionalContext / hookSpecificOutput
# (only continue/decision[block]/reason/stopReason/suppressOutput/systemMessage).
# So the adapter must NOT wrap a Stop hook's output as additionalContext, and it
# must NOT feed the hook's stdout to Codex's Stop *decision* parser (raw advisory
# text there is mis-parsed; the generic exit-2 path would emit a hookSpecificOutput
# shape Stop's strict deny_unknown_fields schema rejects). codex-hook-adapter.sh
# therefore has a dedicated Stop branch: run the hook for its side effects, route
# any output to the adapter's stderr as advisory, always exit 0 (a SessionEnd
# advisory hook never blocks teardown). jira-nudge's operator-reaching surface
# under Codex is its Telegram relay, not stdout.
#
# This suite asserts:
#   1) STATIC WIRING - each of the 3 SessionEnd hooks is wired into
#      .codex/hooks.json Stop through run-hook.cmd --sandbox; no raw
#      $CLAUDE_PROJECT_DIR/bare-bash path remains; the file parses and carries ONLY
#      a top-level `hooks` key (Codex deny_unknown_fields strict schema).
#   2) BEHAVIORAL smoke (Codex env simulated, gates OFF) - each wired Stop hook runs
#      through run-hook.cmd and exits 0 emitting NO hookSpecificOutput on stdout
#      (proves the Stop branch is taken, not the additionalContext wrap, and that an
#      advisory hook never blocks teardown).
#   3) BEHAVIORAL positive (jira-nudge gate ON, hermetic temp git repo) - the nudge
#      reaches the adapter's STDERR as advisory and is NOT on stdout / NOT a
#      hookSpecificOutput JSON. Directly validates the Stop-branch design (vs the
#      vacuous gated-off "no JSON").
#   4) EXIT-2 protection (adapter direct, temp CLAUDE_PROJECT_DIR fixture) - a Stop
#      hook that exits 2 emitting hookSpecificOutput-looking stdout still yields
#      adapter exit 0 with NO hookSpecificOutput on stdout (locks in that Stop never
#      reaches the generic exit-2 branch -> no Stop-schema-invalid output).
#
# Hermetic: gate vars are set EXPLICITLY =0 (the plugin hooks load_dotenv their
# gate from the clone's .env non-clobbering, so merely unsetting would load ON on a
# dogfooding machine and the test would go LIVE). Ambient HIMMEL_* profile vars are
# stripped and HOME is pointed at a temp dir (so no HOME-rooted lookup -- vault
# resolution, jira breadcrumb store -- ever touches real machine state). No network,
# no real Telegram (relay stubbed). bash 3.2-safe. The run-hook.cmd cmd.exe branch is
# covered by the existing .ps1 twin (test-codex-run-hook.ps1).
#
# Coverage note: end-session-wiki.sh self-guards out on msys*/cygwin*/Windows_NT
# (its .ps1 is the Windows-Claude path; run-hook.cmd is bash-only), so on a Windows
# Git-Bash runner its section-2 smoke is a trivial exit-0 -- its Stop routing is
# exercised end-to-end only on POSIX. The adapter Stop branch itself is fully
# covered cross-platform by sections 3 (nudge) + 4 (stub).
set -uo pipefail

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HOOKS_DIR/../.." && pwd)"
HOOKS_JSON="$REPO_ROOT/.codex/hooks.json"
ADAPTER="$REPO_ROOT/.codex/codex-hook-adapter.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

if ! command -v jq >/dev/null 2>&1; then
  echo "jq not on PATH - required for this test" >&2; exit 1
fi
command -v git >/dev/null 2>&1 || { echo "git not on PATH - required for this test" >&2; exit 1; }
[ -f "$HOOKS_JSON" ] || { echo ".codex/hooks.json not found: $HOOKS_JSON" >&2; exit 1; }
[ -f "$ADAPTER" ]    || { echo "adapter not found: $ADAPTER" >&2; exit 1; }

TMP_ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t himmel599)"
trap 'rm -rf "$TMP_ROOT" 2>/dev/null || true' EXIT

# Extract the (first) Stop hook command wiring a given hook filename.
wired_cmd() {
  jq -r --arg h "$1" \
    '.hooks.Stop[]?.hooks[]?.command // empty | select(contains($h))' \
    "$HOOKS_JSON" 2>/dev/null | head -1
}

# A minimal Codex Stop input payload. $1 = cwd, $2 = transcript_path (empty -> null).
stop_payload() {
  if [ -n "${2:-}" ]; then
    jq -cn --arg cwd "$1" --arg tp "$2" \
      '{hook_event_name:"Stop",cwd:$cwd,transcript_path:$tp,session_id:"t",turn_id:"t",model:"m",permission_mode:"default",last_assistant_message:null,stop_hook_active:false}'
  else
    jq -cn --arg cwd "$1" \
      '{hook_event_name:"Stop",cwd:$cwd,transcript_path:null,session_id:"t",turn_id:"t",model:"m",permission_mode:"default",last_assistant_message:null,stop_hook_active:false}'
  fi
}

# Strip ambient profile/initiative vars so a launching shell that has them ON
# (overnight/initiative sessions, dogfooded gates) can't flip a hook live and turn
# a gated-OFF assertion into a false red. Gate vars are then set explicitly per case.
ENV_CLEAN="-u CLAUDE_PROJECT_DIR -u HIMMEL_OVERNIGHT -u HIMMEL_INITIATIVE_OVERNIGHT -u HIMMEL_INITIATIVE -u HIMMEL_WHERE_ARE_WE -u HIMMEL_JIRA_NUDGE"

STOP_HOOKS="refresh-where-are-we-on-end.sh jira-nudge-on-end.sh end-session-wiki.sh"

# == 1) Static wiring ========================================================
for h in $STOP_HOOKS; do
  c="$(wired_cmd "$h")"
  if [ -n "$c" ]; then ok "$h wired into .codex/hooks.json Stop"; else bad "$h wired into .codex/hooks.json Stop"; fi
  case "$c" in *run-hook.cmd*) ok "$h routed through run-hook.cmd";; *) bad "$h routed through run-hook.cmd (got: ${c:-<none>})";; esac
  case "$c" in *--sandbox*) ok "$h uses --sandbox mode";; *) bad "$h uses --sandbox mode (got: ${c:-<none>})";; esac
done

# No raw $CLAUDE_PROJECT_DIR / bare-bash path may remain in any Stop command (that
# under-Codex no-op bug is exactly what this ticket fixes).
raw="$(jq -r '.hooks.Stop[]?.hooks[]?.command // empty | select(contains("CLAUDE_PROJECT_DIR"))' "$HOOKS_JSON" 2>/dev/null)"
if [ -z "$raw" ]; then ok "no raw \$CLAUDE_PROJECT_DIR path in any Stop command"; else bad "raw \$CLAUDE_PROJECT_DIR path present: $raw"; fi

# Strict schema: file parses, and the ONLY top-level key is `hooks`.
if jq -e . "$HOOKS_JSON" >/dev/null 2>&1; then ok ".codex/hooks.json is valid JSON"; else bad ".codex/hooks.json is valid JSON"; fi
if jq -e 'keys == ["hooks"]' "$HOOKS_JSON" >/dev/null 2>&1; then
  ok "strict schema: only top-level 'hooks' key"
else
  bad "strict schema: only top-level 'hooks' key (got: $(jq -rc 'keys' "$HOOKS_JSON" 2>/dev/null))"
fi

# == 2) Behavioral smoke: each Stop hook runs, exit 0, no hookSpecificOutput ==
# Gates set EXPLICITLY =0 (see ENV_CLEAN note). CLAUDE_PROJECT_DIR unset -> proves
# run-hook.cmd re-derives the repo root under Codex. cwd = REPO_ROOT (a real dir, so
# jira-nudge's `[ -d cwd ]` precondition holds before it exits at the gate).
SMOKE_PAYLOAD="$(stop_payload "$REPO_ROOT" "")"
for h in $STOP_HOOKS; do
  cmd="$(wired_cmd "$h")"
  if [ -z "$cmd" ]; then bad "$h smoke: not wired (cannot run)"; continue; fi
  out="$TMP_ROOT/smoke-$h.out"
  # shellcheck disable=SC2086 # $ENV_CLEAN flags + $cmd are intentional splits
  # HOME=$TMP_ROOT keeps any HOME-rooted lookup (vault resolution, breadcrumb store)
  # off the real machine -- tests must never touch real data.
  ( cd "$REPO_ROOT" && printf '%s' "$SMOKE_PAYLOAD" \
      | env $ENV_CLEAN HOME="$TMP_ROOT" HIMMEL_WHERE_ARE_WE=0 HIMMEL_JIRA_NUDGE=0 CLAUDE_END_SESSION_WIKI=0 \
        bash $cmd >"$out" 2>/dev/null ); rc=$?
  if [ "$rc" -eq 0 ]; then ok "$h smoke: exit 0 (advisory, never blocks teardown)"; else bad "$h smoke: exit 0 (got rc=$rc)"; fi
  if ! grep -q 'hookSpecificOutput' "$out" 2>/dev/null; then ok "$h smoke: no hookSpecificOutput on stdout"; else bad "$h smoke: stdout leaked hookSpecificOutput ($(cat "$out"))"; fi
done

# == 3) Behavioral positive: jira-nudge gate ON -> nudge on STDERR, not stdout ==
# Hermetic temp git repo with a commit referencing TESTKEY-1 inside the session
# window (transcript first-timestamp = far past), no breadcrumb, relay stubbed.
NUDGE_REPO="$TMP_ROOT/nudgerepo"
mkdir -p "$NUDGE_REPO"
(
  cd "$NUDGE_REPO" || exit 1
  git init -q
  git config user.email "t@example.com"
  git config user.name  "t"
  git config commit.gpgsign false
  echo x > f.txt
  git add f.txt
  git commit -q -m "feat: TESTKEY-1 work"
) >/dev/null 2>&1
NUDGE_TS="$TMP_ROOT/transcript.jsonl"
printf '%s\n' '{"timestamp":"2020-01-01T00:00:00Z"}' > "$NUDGE_TS"
NUDGE_PAYLOAD="$(stop_payload "$NUDGE_REPO" "$NUDGE_TS")"
nudge_cmd="$(wired_cmd jira-nudge-on-end.sh)"
if [ -z "$nudge_cmd" ]; then
  bad "jira-nudge positive: not wired (cannot run)"
else
  nout="$TMP_ROOT/nudge.out"; nerr="$TMP_ROOT/nudge.err"
  # HIMMEL_INITIATIVE stripped (else the `ticket` leg would suppress the nudge);
  # gate ON; JIRA_PROJECT_KEY injected (temp repo has no .env); relay -> `true`.
  # HOME=$TMP_ROOT so the no-mutation breadcrumb check reads a temp store, never the
  # real ~/.claude/jira-breadcrumbs (a stale machine-global file could otherwise
  # suppress the nudge and false-FAIL this case).
  # shellcheck disable=SC2086 # $ENV_CLEAN flags + $nudge_cmd are intentional splits
  ( cd "$REPO_ROOT" && printf '%s' "$NUDGE_PAYLOAD" \
      | env $ENV_CLEAN HOME="$TMP_ROOT" HIMMEL_JIRA_NUDGE=1 JIRA_PROJECT_KEY=TESTKEY JIRA_NUDGE_RELAY_CMD=true \
        bash $nudge_cmd >"$nout" 2>"$nerr" ); rc=$?
  if [ "$rc" -eq 0 ]; then ok "jira-nudge positive: adapter exit 0"; else bad "jira-nudge positive: adapter exit 0 (got rc=$rc)"; fi
  if grep -q 'TESTKEY-1' "$nerr" 2>/dev/null; then ok "jira-nudge positive: nudge surfaced on adapter STDERR (advisory)"; else bad "jira-nudge positive: nudge expected on stderr (stderr: $(cat "$nerr" 2>/dev/null); stdout: $(cat "$nout" 2>/dev/null))"; fi
  if [ ! -s "$nout" ]; then
    ok "jira-nudge positive: stdout fully empty (nothing reaches Codex Stop decision parser)"
  else
    bad "jira-nudge positive: stdout not empty - leaked to Codex decision parser ($(cat "$nout" 2>/dev/null))"
  fi
fi

# == 4) Exit-2 protection: adapter direct, stub hook exits 2 with JSON stdout ==
# Proves the Stop branch swallows stdout (-> stderr) and exits 0 regardless, so a
# Stop hook can never emit the generic exit-2 hookSpecificOutput shape that Stop's
# strict output schema forbids.
FIX="$TMP_ROOT/fixture"
mkdir -p "$FIX/scripts/hooks"
# The stub emits on BOTH stdout and stderr so this also exercises the Stop branch's
# 2>&1 channel-merge: both must land on the adapter's stderr (advisory), never stdout.
cat > "$FIX/scripts/hooks/stub-exit2.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"x"}}\n'
printf 'STUB-STDOUT\n'
printf 'STUB-STDERR\n' >&2
exit 2
STUB
chmod +x "$FIX/scripts/hooks/stub-exit2.sh" 2>/dev/null || true
e2out="$TMP_ROOT/exit2.out"; e2err="$TMP_ROOT/exit2.err"
printf '%s' "$(stop_payload "$FIX" "")" \
  | env CLAUDE_PROJECT_DIR="$FIX" HOME="$TMP_ROOT" bash "$ADAPTER" stub-exit2.sh >"$e2out" 2>"$e2err"; rc=$?
if [ "$rc" -eq 0 ]; then ok "exit-2 stub: adapter exit 0 (Stop never blocks)"; else bad "exit-2 stub: adapter exit 0 (got rc=$rc)"; fi
if [ ! -s "$e2out" ]; then ok "exit-2 stub: stdout fully empty (no forbidden hookSpecificOutput; Stop bypasses generic exit-2 branch)"; else bad "exit-2 stub: stdout not empty ($(cat "$e2out"))"; fi
if grep -q 'STUB-STDOUT' "$e2err" 2>/dev/null && grep -q 'STUB-STDERR' "$e2err" 2>/dev/null; then ok "exit-2 stub: hook stdout AND stderr both routed to adapter stderr (2>&1 merge, advisory)"; else bad "exit-2 stub: hook stdout+stderr not both on adapter stderr (stderr: $(cat "$e2err" 2>/dev/null))"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
