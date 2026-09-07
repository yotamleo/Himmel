#!/usr/bin/env bash
# Unit test for .codex/run-hook.sh + .codex/codex-hook-adapter.sh — the Codex
# hook wrapper + decision adapter (HIMMEL-427). Tests the UNIX (bash) branch of
# the Unix wrapper. The Windows run-hook.cmd wrapper is tested by the .ps1 twin.
#
# Sets up an ISOLATED temp tree (<T>/.codex/{run-hook.sh,codex-hook-adapter.sh}
# + <T>/scripts/hooks/...) so the test proves the wrapper derives the repo root
# from its OWN location, independent of the real repo.
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

HOOKS="$(cd "$(dirname "$0")" && pwd)"
WRAPPER="$HOOKS/../../.codex/run-hook.sh"
ADAPTER="$HOOKS/../../.codex/codex-hook-adapter.sh"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

[ -f "$WRAPPER" ] || { echo "wrapper not found: $WRAPPER" >&2; exit 1; }
[ -f "$ADAPTER" ] || { echo "adapter not found: $ADAPTER" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/.codex" "$T/scripts/hooks"
cp "$WRAPPER" "$T/.codex/run-hook.sh"
cp "$ADAPTER" "$T/.codex/codex-hook-adapter.sh"
# Canonical temp root (bash resolves symlinks via cd+pwd, mktemp may not).
TC="$(cd "$T" && pwd)"

# 1) NON-BLOCK path: a guardrail that exits non-2 PROCEEDS CLEANLY (codex-2).
#    Codex has no concept of "ran fine but exited nonzero" — a hook that isn't
#    a deny and still exits nonzero renders as a "PreToolUse hook (failed)"
#    banner, so the adapter always exits 0 here regardless of the guardrail's
#    own code. Proof-of-execution is the derived CLAUDE_PROJECT_DIR + forwarded
#    stdin, both on the adapter's OWN stderr (HIMMEL-1987): Codex rejects a
#    Claude permissionDecision:"allow" / updatedInput, so the adapter captures
#    guardrail stdout and re-emits it only as advisory stderr — the adapter's
#    STDOUT stays empty.
cat > "$T/scripts/hooks/dummy.sh" <<'EOF'
read -r line || true
echo "PROJDIR=[$CLAUDE_PROJECT_DIR]"
echo "STDIN=[$line]"
exit 7
EOF
sout="$(printf 'fromstdin\n' | bash "$T/.codex/run-hook.sh" dummy.sh 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "non-block -> adapter exits 0 (proceeds cleanly, not the guardrail's own code)"; else bad "non-block -> adapter exits 0 (got $rc)"; fi
if [ -z "$sout" ]; then ok "non-block guardrail stdout NOT forwarded to Codex stdout (swallowed)"; else bad "non-block stdout must not reach Codex stdout ($sout)"; fi
out="$(printf 'fromstdin\n' | bash "$T/.codex/run-hook.sh" dummy.sh 2>&1)"; rc=$?
case "$out" in
  *"PROJDIR=[$TC]"*) ok "CLAUDE_PROJECT_DIR derived from wrapper location + exported (advisory stderr)";;
  *) bad "CLAUDE_PROJECT_DIR derived ($out)";;
esac
case "$out" in
  *"STDIN=[fromstdin]"*) ok "stdin forwarded to the guardrail (advisory stderr)";;
  *) bad "stdin forwarded ($out)";;
esac

# 1b) Explicit sandbox mode is the tracked hook setup; it should behave like the
#     default sandbox path: adapter exits 0 (proceeds cleanly) and stdin is
#     still forwarded.
fout="$(printf 'fromstdin\n' | bash "$T/.codex/run-hook.sh" --sandbox dummy.sh 2>&1)"; frc=$?
if [ "$frc" -eq 0 ]; then ok "explicit --sandbox flag -> adapter exits 0 (proceeds cleanly)"; else bad "explicit --sandbox flag -> adapter exits 0 (got $frc)"; fi
case "$fout" in
  *"STDIN=[fromstdin]"*) ok "explicit --sandbox flag still forwards stdin";;
  *) bad "explicit --sandbox flag still forwards stdin ($fout)";;
esac

# 1b-bis) --lifecycle (HIMMEL-1981) marks a no-permission-gate hook. The Unix
#     wrapper exports the flag so adapter precondition failures report honestly,
#     then strips it before running the guardrail.
lout="$(printf 'fromstdin\n' | bash "$T/.codex/run-hook.sh" --sandbox --lifecycle dummy.sh 2>&1)"; lrc=$?
if [ "$lrc" -eq 0 ]; then ok "--lifecycle flag -> adapter exits 0 (proceeds cleanly)"; else bad "--lifecycle flag -> adapter exits 0 (got $lrc)"; fi
case "$lout" in
  *"STDIN=[fromstdin]"*) ok "--lifecycle flag is stripped, not passed to the guardrail";;
  *) bad "--lifecycle flag is stripped, not passed to the guardrail ($lout)";;
esac
# ...and it is EXPORTED, not merely stripped: the adapter's own preconditions run
# before stdin is read, so on a no-permission-gate hook they must report honestly
# (rc 1, no envelope) rather than emit a deny shaped for the wrong event.
pout="$(printf '{}\n' | bash "$T/.codex/run-hook.sh" --sandbox --lifecycle nonexistent-guardrail.sh 2>&1)"; prc=$?
if [ "$prc" -eq 1 ]; then ok "--lifecycle adapter precondition -> honest rc 1"; else bad "--lifecycle adapter precondition -> honest rc 1 (got $prc)"; fi
if grepq "$pout" -F -e 'permissionDecision'; then
  bad "--lifecycle adapter precondition must not emit a deny envelope ($pout)"
else ok "--lifecycle adapter precondition emits no deny envelope"; fi
# The wrapper is the ONLY authority on the flag: an INHERITED value must not
# promote a permission-gate hook, or its fail-closed deny becomes a bare rc 1
# (which Codex fails OPEN on).
iout="$(printf '{}\n' | HIMMEL_CODEX_HOOK_LIFECYCLE=1 bash "$T/.codex/run-hook.sh" --sandbox nonexistent-guardrail.sh 2>&1)"; irc=$?
if [ "$irc" -eq 0 ] && grepq "$iout" -F -e '"permissionDecision":"deny"'; then
  ok "inherited HIMMEL_CODEX_HOOK_LIFECYCLE does not promote a gate hook"
else bad "inherited HIMMEL_CODEX_HOOK_LIFECYCLE promoted a gate hook (rc=$irc, out=$iout)"; fi

# 1c) ALLOW-SWALLOW (HIMMEL-1987): a guardrail that emits a Claude
#     permissionDecision:"allow" (optionally with updatedInput) on stdout and
#     exits 0 — auto-approve-safe-bash / rtk-hook-guard shape. Codex rejects that
#     envelope ("unsupported permissionDecision:allow"), so the adapter must NOT
#     forward it: stdout empty, rc 0 (proceed).
cat > "$T/scripts/hooks/allowdummy.sh" <<'EOF'
cat >/dev/null
printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"command":"rtk git status"},"permissionDecisionReason":"safe"}}'
exit 0
EOF
aout="$(printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status"}}' | bash "$T/.codex/run-hook.sh" --sandbox allowdummy.sh 2>/dev/null)"; arc=$?
if [ "$arc" -eq 0 ] && [ -z "$aout" ]; then ok "allow/updatedInput envelope swallowed (empty stdout, rc 0)"; else bad "allow envelope must be swallowed (rc=$arc, out=$aout)"; fi

# 1d) STDOUT-DENY whitespace tolerance (CRITIC-1): a guardrail that exits 0 but
#     emits a permissionDecision:"deny" envelope on stdout with non-exact spacing
#     around the colon (pretty-printed / tab-indented) must still be detected as
#     a block, not swallowed as fail-OPEN.
cat > "$T/scripts/hooks/denyspace.sh" <<'EOF'
cat >/dev/null
printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision": "deny"}}'
exit 0
EOF
cat > "$T/scripts/hooks/denytab.sh" <<'EOF'
cat >/dev/null
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":\t"deny"}}\n'
exit 0
EOF
dsout="$(printf '{"hook_event_name":"PreToolUse"}\n' | bash "$T/.codex/run-hook.sh" --sandbox denyspace.sh)"; dsrc=$?
if [ "$dsrc" -eq 0 ]; then ok "stdout deny (space after colon) -> wrapper exits 0"; else bad "stdout deny (space after colon) -> wrapper exits 0 (got $dsrc)"; fi
case "$dsout" in
  *'"permissionDecision":"deny"'*) ok "stdout deny (space after colon) is detected, not swallowed";;
  *) bad "stdout deny (space after colon) must be detected, not swallowed ($dsout)";;
esac
dtout="$(printf '{"hook_event_name":"PreToolUse"}\n' | bash "$T/.codex/run-hook.sh" --sandbox denytab.sh)"; dtrc=$?
if [ "$dtrc" -eq 0 ]; then ok "stdout deny (tab after colon) -> wrapper exits 0"; else bad "stdout deny (tab after colon) -> wrapper exits 0 (got $dtrc)"; fi
case "$dtout" in
  *'"permissionDecision":"deny"'*) ok "stdout deny (tab after colon) is detected, not swallowed";;
  *) bad "stdout deny (tab after colon) must be detected, not swallowed ($dtout)";;
esac

# 2) BLOCK path: a guardrail that exits 2 is translated to Codex's JSON deny on
#    stdout (stderr -> reason) and the wrapper exits 0 (the block lives in the
#    JSON, not the exit code — Codex ignores exit 2). Use a DISTINCT inbound event
#    (PermissionRequest, not the PreToolUse default) so the hookEventName mirror
#    is load-bearing AND the non-PreToolUse path is covered.
cat > "$T/scripts/hooks/blocker.sh" <<'EOF'
read -r line || true
echo "blocking-reason-xyz" >&2
exit 2
EOF
bout="$(printf '{"hook_event_name":"PermissionRequest"}\n' | bash "$T/.codex/run-hook.sh" blocker.sh)"; brc=$?
if [ "$brc" -eq 0 ]; then ok "block -> wrapper exits 0 (decision is in stdout JSON)"; else bad "block -> wrapper exits 0 (got $brc)"; fi
case "$bout" in
  *'"permissionDecision":"deny"'*) ok "block -> emits permissionDecision deny";;
  *) bad "block -> emits permissionDecision deny ($bout)";;
esac
case "$bout" in
  *"blocking-reason-xyz"*) ok "block -> guardrail stderr becomes the deny reason";;
  *) bad "block -> guardrail stderr becomes the deny reason ($bout)";;
esac
case "$bout" in
  *'"hookEventName":"PermissionRequest"'*) ok "block -> hookEventName mirrors the inbound event";;
  *) bad "block -> hookEventName mirrors the inbound event ($bout)";;
esac

# 2b) NON-PERMISSION lifecycle exit-2 (HIMMEL-565): a guardrail that exits 2 on a
#     non-permission event (PostToolUse auto-arm success, SessionStart,
#     UserPromptSubmit) must surface its message via additionalContext — NOT a
#     bogus PreToolUse permission deny. Those events have no permission gate; the
#     guardrail's side effects (e.g. arm + snapshot) already ran during execution,
#     so exit 2 only needs to feed the advisory message to the model.
pout="$(printf '{"hook_event_name":"PostToolUse"}\n' | bash "$T/.codex/run-hook.sh" blocker.sh)"; prc=$?
if [ "$prc" -eq 0 ]; then ok "PostToolUse exit-2 -> wrapper exits 0 (signal is in stdout JSON)"; else bad "PostToolUse exit-2 -> wrapper exits 0 (got $prc)"; fi
case "$pout" in
  *'"hookEventName":"PostToolUse"'*) ok "PostToolUse exit-2 -> hookEventName mirrors PostToolUse";;
  *) bad "PostToolUse exit-2 -> hookEventName mirrors PostToolUse ($pout)";;
esac
case "$pout" in
  *'"additionalContext"'*) ok "PostToolUse exit-2 -> surfaces additionalContext";;
  *) bad "PostToolUse exit-2 -> surfaces additionalContext ($pout)";;
esac
case "$pout" in
  *permissionDecision*) bad "PostToolUse exit-2 -> must NOT emit a permission decision ($pout)";;
  *) ok "PostToolUse exit-2 -> no bogus permissionDecision";;
esac
case "$pout" in
  *"blocking-reason-xyz"*) ok "PostToolUse exit-2 -> guardrail stderr becomes the additionalContext reason";;
  *) bad "PostToolUse exit-2 -> guardrail stderr becomes the additionalContext reason ($pout)";;
esac

# 2c) Coherence: SessionStart exit-2 follows the same non-permission contract,
#     incl. the additionalContext channel carrying the guardrail's reason.
ssout="$(printf '{"hook_event_name":"SessionStart"}\n' | bash "$T/.codex/run-hook.sh" blocker.sh)"; ssrc=$?
if [ "$ssrc" -eq 0 ]; then ok "SessionStart exit-2 -> wrapper exits 0"; else bad "SessionStart exit-2 -> wrapper exits 0 (got $ssrc)"; fi
case "$ssout" in
  *'"hookEventName":"SessionStart"'*) ok "SessionStart exit-2 -> hookEventName mirrors SessionStart";;
  *) bad "SessionStart exit-2 -> hookEventName mirrors SessionStart ($ssout)";;
esac
case "$ssout" in
  *'"additionalContext"'*"blocking-reason-xyz"*) ok "SessionStart exit-2 -> guardrail stderr becomes the additionalContext reason";;
  *) bad "SessionStart exit-2 -> guardrail stderr becomes the additionalContext reason ($ssout)";;
esac
case "$ssout" in
  *permissionDecision*) bad "SessionStart exit-2 -> must NOT emit a permission decision ($ssout)";;
  *) ok "SessionStart exit-2 -> no bogus permissionDecision";;
esac

# 2d) Coherence: UserPromptSubmit exit-2 mirrors its own event (3rd whitelist arm).
upout="$(printf '{"hook_event_name":"UserPromptSubmit"}\n' | bash "$T/.codex/run-hook.sh" blocker.sh)"
case "$upout" in
  *'"hookEventName":"UserPromptSubmit"'*) ok "UserPromptSubmit exit-2 -> hookEventName mirrors UserPromptSubmit";;
  *) bad "UserPromptSubmit exit-2 -> hookEventName mirrors UserPromptSubmit ($upout)";;
esac

# 2e) Unknown/garbage inbound event on exit-2 is NORMALISED to PostToolUse — it
#     must NOT echo the attacker-controllable event string into the hookEventName
#     const (Codex's strict parser would reject it, dropping the message), and
#     must NOT become a permission deny. Use a clearly-bogus event name: `Stop` is
#     now a first-class adapter branch (HIMMEL-599), so it is no longer "unknown".
unkout="$(printf '{"hook_event_name":"BogusEvent"}\n' | bash "$T/.codex/run-hook.sh" blocker.sh)"; unkrc=$?
if [ "$unkrc" -eq 0 ]; then ok "unknown-event exit-2 -> wrapper exits 0"; else bad "unknown-event exit-2 -> wrapper exits 0 (got $unkrc)"; fi
case "$unkout" in
  *'"hookEventName":"PostToolUse"'*) ok "unknown-event exit-2 -> normalised to PostToolUse";;
  *) bad "unknown-event exit-2 -> normalised to PostToolUse ($unkout)";;
esac
case "$unkout" in
  *'"BogusEvent"'*) bad "unknown-event exit-2 -> must NOT echo the raw event string ($unkout)";;
  *) ok "unknown-event exit-2 -> raw event string not echoed";;
esac
case "$unkout" in
  *permissionDecision*) bad "unknown-event exit-2 -> must NOT emit a permission decision ($unkout)";;
  *) ok "unknown-event exit-2 -> no bogus permissionDecision";;
esac

# 3) FAIL-CLOSED paths: under Codex a bare exit 2 fails OPEN, so the adapter must
#    emit a JSON deny (exit 0) on its own precondition errors, not just on a
#    guardrail block.
# 3a) Missing script name -> fail closed (deny, rc 0), not a non-blocking error.
nout="$(printf '' | bash "$T/.codex/run-hook.sh" 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && grepq "$nout" '"permissionDecision":"deny"'; then
  ok "missing script name -> fail-closed deny (rc 0)"
else bad "missing script name -> fail-closed deny (rc=$rc, out=$nout)"; fi
# 3b) Referenced guardrail file does not exist -> fail closed (deny, rc 0).
gout="$(printf '{}' | bash "$T/.codex/run-hook.sh" nonexistent-guardrail.sh 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && grepq "$gout" '"permissionDecision":"deny"'; then
  ok "missing guardrail file -> fail-closed deny (rc 0)"
else bad "missing guardrail file -> fail-closed deny (rc=$rc, out=$gout)"; fi
# 3c) Adapter invoked with CLAUDE_PROJECT_DIR unset -> fail closed (deny, rc 0).
#     (The wrapper always exports it; this locks the adapter's own guard.)
uout="$(printf '{}' | env -u CLAUDE_PROJECT_DIR bash "$T/.codex/codex-hook-adapter.sh" somehook.sh 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ] && grepq "$uout" '"permissionDecision":"deny"'; then
  ok "unset CLAUDE_PROJECT_DIR -> fail-closed deny (rc 0)"
else bad "unset CLAUDE_PROJECT_DIR -> fail-closed deny (rc=$rc, out=$uout)"; fi

# 4) CHAIN CONTRACT (HIMMEL-1989). One adapter invocation runs N guardrails in
#    declared order, `+`-separated. These pin the contract `.codex/hooks.json`
#    depends on; they are written against fixtures, not the real guardrails, so
#    a guardrail's own behaviour change cannot make them pass vacuously.
#    Each fixture appends its name to $CHAIN_LOG, which is what proves WHICH
#    members ran and in what order.
CHAIN_LOG="$TC/chain.log"
export CHAIN_LOG
mk_member() {  # <name> <body...>
  local f="$T/scripts/hooks/$1"; shift
  {
    printf 'cat >/dev/null\n'
    # shellcheck disable=SC2016  # $CHAIN_LOG is expanded when the FIXTURE runs,
    # not while this test writes it — single quotes are the point.
    printf 'printf %%s%%s "%s" " " >> "$CHAIN_LOG"\n' "${f##*/}"
    printf '%s\n' "$@"
  } > "$f"
}
mk_member c1.sh 'exit 0'
mk_member c2.sh 'exit 0'
mk_member c3.sh 'exit 0'
mk_member cdeny.sh 'echo "chain-deny-reason-xyz" >&2' 'exit 2'
mk_member cdenyjson.sh 'printf %s "{\"hookSpecificOutput\":{\"permissionDecision\":\"deny\"}}"' 'exit 0'
mk_member callow.sh 'printf %s "{\"hookSpecificOutput\":{\"permissionDecision\":\"allow\"}}"' 'exit 0'
mk_member cinfo.sh 'echo "informational" >&2' 'exit 7'
mk_member cctxa.sh 'echo CTX-A' 'exit 0'
mk_member cctxb.sh 'echo CTX-B' 'exit 0'

run_chain() {  # <chain> [extra-wrapper-flags...]; sets $cout/$crc, resets the log
    : > "$CHAIN_LOG"
    local chain="$1"; shift
    cout="$(printf '%s' "${CHAIN_STDIN:-{\}}" | bash "$T/.codex/run-hook.sh" "$@" --sandbox "$chain" 2>/dev/null)"; crc=$?
    clog="$(cat "$CHAIN_LOG")"
}

# 4a) Every member runs, in the declared order, and a clean chain emits nothing
#     on stdout (the allow/advisory swallow of HIMMEL-1987 is per-chain now).
run_chain 'c1.sh+c2.sh+c3.sh'
if [ "$crc" -eq 0 ] && [ "$clog" = "c1.sh c2.sh c3.sh " ]; then
  ok "chain runs every member in declared order"
else bad "chain runs every member in declared order (rc=$crc, log='$clog')"; fi
if [ -z "$cout" ]; then ok "clean chain emits nothing on Codex stdout"
else bad "clean chain emits nothing on Codex stdout (out=$cout)"; fi

# 4b) FIRST deny wins and SHORT-CIRCUITS: the denying member's reason is the one
#     Codex sees, and no later member runs.
run_chain 'c1.sh+cdeny.sh+c3.sh'
if [ "$crc" -eq 0 ] && grepq "$cout" '"permissionDecision":"deny"' && grepq "$cout" 'chain-deny-reason-xyz'; then
  ok "chain exit-2 member -> deny carrying THAT member's reason"
else bad "chain exit-2 member -> deny carrying that member's reason (rc=$crc, out=$cout)"; fi
if [ "$clog" = "c1.sh cdeny.sh " ]; then ok "chain short-circuits after the first deny"
else bad "chain short-circuits after the first deny (log='$clog')"; fi

# 4c) A stdout deny envelope short-circuits identically to exit 2.
run_chain 'c1.sh+cdenyjson.sh+c3.sh'
if [ "$crc" -eq 0 ] && grepq "$cout" '"permissionDecision":"deny"' && [ "$clog" = "c1.sh cdenyjson.sh " ]; then
  ok "chain stdout-deny member short-circuits like exit 2"
else bad "chain stdout-deny member short-circuits like exit 2 (rc=$crc, log='$clog', out=$cout)"; fi

# 4d) An ALLOW envelope (auto-approve-safe-bash's shape) is swallowed and the
#     chain CONTINUES — Codex rejects allow, and it must not end the chain.
run_chain 'callow.sh+c2.sh'
if [ "$crc" -eq 0 ] && [ -z "$cout" ] && [ "$clog" = "callow.sh c2.sh " ]; then
  ok "chain allow envelope swallowed, later members still run"
else bad "chain allow envelope swallowed, later members still run (rc=$crc, log='$clog', out=$cout)"; fi

# 4e) An informational non-2 nonzero exit is NOT a deny and must not stop the chain.
run_chain 'cinfo.sh+c2.sh'
if [ "$crc" -eq 0 ] && ! grepq "$cout" 'permissionDecision' && [ "$clog" = "cinfo.sh c2.sh " ]; then
  ok "chain informational nonzero is not a deny and does not stop the chain"
else bad "chain informational nonzero is not a deny (rc=$crc, log='$clog', out=$cout)"; fi

# 4f) A missing member fails CLOSED before ANY member runs — never a prefix of
#     the chain with the rest silently skipped.
run_chain 'c1.sh+nonexistent-guardrail.sh+c3.sh'
if [ "$crc" -eq 0 ] && grepq "$cout" '"permissionDecision":"deny"' && [ -z "$clog" ]; then
  ok "chain with a missing member denies before running any member"
else bad "chain with a missing member denies before running any member (rc=$crc, log='$clog', out=$cout)"; fi

# 4g) A malformed chain is rejected fail-closed rather than silently coerced.
#     The comma case matters most: cmd.exe splits arguments on `,`, so a comma
#     chain truncates before the adapter sees it — it must never look valid here.
for badchain in 'c1.sh++c2.sh' '+c1.sh' 'c1.sh+' 'c1.sh,c2.sh'; do
  run_chain "$badchain"
  if [ "$crc" -eq 0 ] && grepq "$cout" '"permissionDecision":"deny"' && [ -z "$clog" ]; then
    ok "malformed chain '$badchain' -> fail-closed deny, nothing ran"
  else bad "malformed chain '$badchain' -> fail-closed deny (rc=$crc, log='$clog', out=$cout)"; fi
done

# 4g-bis) Degenerate names, straight at the adapter (the wrapper cannot produce
#     all of these). A chain that resolves to ZERO members must deny, not run no
#     guardrail and exit 0 — that would be a silent fail-OPEN.
for badname in '' ' ' '+' '++' '.' '..'; do
  dout="$(printf '{}' | CLAUDE_PROJECT_DIR="$TC" bash "$T/.codex/codex-hook-adapter.sh" "$badname" 2>/dev/null)"; drc=$?
  if [ "$drc" -eq 0 ] && grepq "$dout" '"permissionDecision":"deny"'; then
    ok "degenerate chain name '$badname' -> fail-closed deny"
  else bad "degenerate chain name '$badname' -> fail-closed deny (rc=$drc, out=$dout)"; fi
done

# 4h) The hook payload reaches EVERY member, not just the first (stdin is read
#     once by the adapter and replayed per member).
mk_member cstdin1.sh 'exit 0'
mk_member cstdin2.sh 'exit 0'
cat > "$T/scripts/hooks/cstdin1.sh" <<'MEMBER'
read -r line || true
printf '%s' "S1=[$line] " >> "$CHAIN_LOG"
exit 0
MEMBER
cat > "$T/scripts/hooks/cstdin2.sh" <<'MEMBER'
read -r line || true
printf '%s' "S2=[$line] " >> "$CHAIN_LOG"
exit 0
MEMBER
CHAIN_STDIN='payload-xyz' run_chain 'cstdin1.sh+cstdin2.sh'
if grepq "$clog" -F -e 'S1=[payload-xyz]' && grepq "$clog" -F -e 'S2=[payload-xyz]'; then
  ok "chain replays the hook payload to every member"
else bad "chain replays the hook payload to every member (log='$clog')"; fi

# 4i) --lifecycle + chain: bodies are JOINED into one additionalContext, and the
#     no-permission-gate contract (HIMMEL-1981) still holds — no deny envelope.
: > "$CHAIN_LOG"
lcout="$(printf '%s' '{"hook_event_name":"SessionStart"}' | bash "$T/.codex/run-hook.sh" --sandbox --lifecycle 'cctxa.sh+cctxb.sh' 2>/dev/null)"; lcrc=$?
# The joined body is newline-separated INSIDE the JSON string, so the escape is
# literal `\n` here — matching it proves ORDER, not just presence (HIMMEL-2003).
if [ "$lcrc" -eq 0 ] && grepq "$lcout" -F -e 'CTX-A\nCTX-B' && grepq "$lcout" -F -e 'additionalContext' && ! grepq "$lcout" -F -e 'permissionDecision'; then
  ok "--lifecycle chain joins every member's context in order, no deny envelope"
else bad "--lifecycle chain joins every member's context in order (rc=$lcrc, out=$lcout)"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
