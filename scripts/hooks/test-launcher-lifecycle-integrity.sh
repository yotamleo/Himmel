#!/usr/bin/env bash
# selector: tree-scan
# HIMMEL-5168: an integrity failure on a hook event whose exit 2 means "keep
# going" (Stop, SubagentStop, ...) must not trap the session. The missing-record
# deny (HIMMEL-2588) is permanent for the session, so exit 2 on Stop made the
# model loop on every stop attempt. The unverified hook must still NEVER run.
# Gating events (PreToolUse and friends) keep exit 2.
set -uo pipefail

HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HOOKS_DIR/../.." && pwd)"
# shellcheck source=../lib/override-env.sh
# shellcheck disable=SC1091
. "$HOOKS_DIR/../lib/override-env.sh"
scrub_override_env

RECORDER="$HOOKS_DIR/record-hook-integrity.sh"
LAUNCHER="$HOOKS_DIR/run-hook-with-bash.js"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not on PATH"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH"; exit 0; }

T="$(mktemp -d "${TMPDIR:-/tmp}/himmel-launcher-lifecycle-integrity.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
PROJECT="$T/project"
OUT_DIR="$T/out"
CANARY="$T/canary"
SID="lifecycle-session-1"
mkdir -p "$PROJECT/scripts/hooks"

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

GUARD="$PROJECT/scripts/hooks/fake-guard.sh"
GUARD2="$PROJECT/scripts/hooks/fake-guard2.sh"
for g in "$GUARD" "$GUARD2"; do
  printf '#!/usr/bin/env bash\necho ran >> "%s"\nexit 0\n' "$CANARY" > "$g"
  chmod +x "$g"
done
git -C "$PROJECT" init -q
git -C "$PROJECT" -c user.email=t@t -c user.name=t add -A
git -C "$PROJECT" -c user.email=t@t -c user.name=t commit -q -m init

payload() { printf '{"session_id":"%s","hook_event_name":"%s"}' "$SID" "$1"; }

# Pin the session, then make the record vanish with the recorder marker `done`:
# the HIMMEL-2588 missing-record deny, permanent for the session.
payload SessionStart | CLAUDE_PROJECT_DIR="$PROJECT" HIMMEL_HOOK_INTEGRITY_DIR="$OUT_DIR" bash "$RECORDER" >/dev/null
rm -f "$OUT_DIR/$SID.json"
if [ "$(cat "$OUT_DIR/$SID.recorder" 2>/dev/null)" != "done" ]; then
  echo "setup: recorder marker is not 'done'" >&2
  exit 1
fi

run() {   # <event> <mode: single|chain>  -> sets RC, OUT, ERR
  rm -f "$CANARY"
  local args=(--optional "$GUARD")
  [ "$2" = chain ] && args=(--chain "$GUARD" "$GUARD2")
  payload "$1" | CLAUDE_PROJECT_DIR="$PROJECT" HIMMEL_HOOK_INTEGRITY_DIR="$OUT_DIR" \
    node "$LAUNCHER" "${args[@]}" >"$T/out.txt" 2>"$T/err.txt"
  RC=$?
  OUT="$(cat "$T/out.txt")"
  ERR="$(cat "$T/err.txt")"
}

# Non-gating: exit 0, hook never runs, notice names the deny, systemMessage on stdout.
for event in Stop SubagentStop TeammateIdle TaskCompleted PreCompact; do
  for mode in single chain; do
    run "$event" "$mode"
    if [ "$RC" -eq 0 ] && [ ! -e "$CANARY" ] \
      && grep -q 'record is missing' <<<"$ERR" \
      && printf '%s' "$OUT" | jq -e '.systemMessage | test("record is missing|integrity")' >/dev/null 2>&1; then
      ok "$event ($mode): integrity failure skips the hook, exits 0 with a notice"
    else
      bad "$event ($mode): rc=$RC canary=$([ -e "$CANARY" ] && echo ran || echo none) out=$OUT err=$ERR"
    fi
  done
done

# Gating / unclassified: exit 2 and the hook never runs.
for event in PreToolUse PermissionRequest UserPromptSubmit PostToolUse PostToolUseFailure SessionStart Notification SessionEnd PermissionDenied SomeFutureEvent ""; do
  for mode in single chain; do
    run "$event" "$mode"
    if [ "$RC" -eq 2 ] && [ ! -e "$CANARY" ] && grep -q 'record is missing' <<<"$ERR"; then
      ok "${event:-<absent>} ($mode): integrity failure still exits 2, hook not run"
    else
      bad "${event:-<absent>} ($mode): expected rc=2, got rc=$RC canary=$([ -e "$CANARY" ] && echo ran || echo none) err=$ERR"
    fi
  done
done

# Non-gating event with a verifiable record still runs the hook.
payload SessionStart | CLAUDE_PROJECT_DIR="$PROJECT" HIMMEL_HOOK_INTEGRITY_DIR="$T/out2" bash "$RECORDER" >/dev/null
rm -f "$CANARY"
if payload Stop | CLAUDE_PROJECT_DIR="$PROJECT" HIMMEL_HOOK_INTEGRITY_DIR="$T/out2" \
  node "$LAUNCHER" --optional "$GUARD" >/dev/null 2>&1 && [ -e "$CANARY" ]; then
  ok "Stop with an intact record still runs the hook"
else
  bad "Stop with an intact record did not run the hook"
fi

# HIMMEL-5172: one member that fails integrity is skipped ALONE. The intact
# members around it still run and what they emitted is kept, a Stop block
# included. A verifiable record exists here; member M1 is rewritten after it.
P2="$T/project2"
O2="$T/out3"
mkdir -p "$P2/scripts/hooks"
M0="$P2/scripts/hooks/m0.sh"
M1="$P2/scripts/hooks/m1.sh"
M2="$P2/scripts/hooks/m2.sh"
BLK="$P2/scripts/hooks/blk.sh"
printf '#!/usr/bin/env bash\necho m0 >> "%s"\nprintf %%s '"'"'{"systemMessage":"from-m0"}'"'"'\nexit 0\n' "$CANARY" > "$M0"
printf '#!/usr/bin/env bash\necho m1 >> "%s"\nexit 0\n' "$CANARY" > "$M1"
printf '#!/usr/bin/env bash\necho m2 >> "%s"\nexit 0\n' "$CANARY" > "$M2"
printf '#!/usr/bin/env bash\necho blk >> "%s"\nprintf %%s '"'"'{"decision":"block","reason":"keep-going"}'"'"'\nexit 0\n' "$CANARY" > "$BLK"
chmod +x "$M0" "$M1" "$M2" "$BLK"
git -C "$P2" init -q
git -C "$P2" -c user.email=t@t -c user.name=t add -A
git -C "$P2" -c user.email=t@t -c user.name=t commit -q -m init
payload SessionStart | CLAUDE_PROJECT_DIR="$P2" HIMMEL_HOOK_INTEGRITY_DIR="$O2" bash "$RECORDER" >/dev/null
printf '# tampered\n' >> "$M1"

run2() {   # <event> <member>...  -> sets RC, OUT, ERR
  local event="$1"; shift
  rm -f "$CANARY"
  payload "$event" | CLAUDE_PROJECT_DIR="$P2" HIMMEL_HOOK_INTEGRITY_DIR="$O2" \
    node "$LAUNCHER" --chain "$@" >"$T/out.txt" 2>"$T/err.txt"
  RC=$?
  OUT="$(cat "$T/out.txt")"
  ERR="$(cat "$T/err.txt")"
}

run2 Stop "$M1" "$BLK"
# HIMMEL-5198: the block holds on exit 2, and Claude Code reads stderr there, so
# the blocking member's own reason must be on stderr, not just the skip notice.
if [ "$RC" -eq 2 ] && grep -q '"decision":"block"' <<<"$OUT" && grep -q 'keep-going' <<<"$ERR" \
  && grep -q '^blk$' "$CANARY" 2>/dev/null && ! grep -q '^m1$' "$CANARY" 2>/dev/null; then
  ok "Stop chain: tampered member skipped alone, the later member's block holds on exit 2 with its reason on stderr"
else
  bad "Stop chain (tampered, block): rc=$RC err=$ERR canary=$(cat "$CANARY" 2>/dev/null | tr '\n' ,) out=$OUT"
fi

run2 Stop "$M0" "$M1" "$M2"
if [ "$RC" -eq 0 ] && grep -q '^m0$' "$CANARY" && grep -q '^m2$' "$CANARY" && ! grep -q '^m1$' "$CANARY" \
  && printf '%s' "$OUT" | jq -e '.systemMessage | test("from-m0") and test("m1.sh was NOT run")' >/dev/null 2>&1; then
  ok "Stop chain: output from members before and after the tampered one is merged with the skip notice"
else
  bad "Stop chain (m0,m1,m2): rc=$RC canary=$(cat "$CANARY" 2>/dev/null | tr '\n' ,) out=$OUT"
fi

run2 PreToolUse "$M1" "$M2"
if [ "$RC" -eq 2 ] && [ ! -e "$CANARY" ]; then
  ok "PreToolUse chain: a tampered member still denies the whole chain, no member runs"
else
  bad "PreToolUse chain (tampered): expected rc=2 and no member run, got rc=$RC canary=$(cat "$CANARY" 2>/dev/null | tr '\n' ,)"
fi

# The plugin copy of the launcher is byte-identical, so it carries the fix.
if cmp -s "$LAUNCHER" "$REPO_ROOT/marketplace/plugins/himmel-ops/hooks/run-hook-with-bash.js"; then
  ok "plugin launcher copy is byte-identical"
else
  bad "plugin launcher copy drifted from scripts/hooks/run-hook-with-bash.js"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
