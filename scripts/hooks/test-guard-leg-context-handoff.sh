#!/usr/bin/env bash
# Smoke suite for scripts/hooks/guard-leg-context-handoff.sh (HIMMEL-4569): a
# console-spawned leg past its context threshold is denied ordinary tool calls
# until its RESUME doc exists or its last marker is WRAPPED/BLOCKED, while the
# hand-off calls themselves always pass. Every case runs against a synthetic
# session: a transcript whose first user turn is the launcher's
# `load <doc> and continue`, plus the claude-hud snapshot context-fill.sh reads.
#
# bash 3.2-safe. Platform guard (gitbash-only): env vars, jq, sha256sum/shasum,
# touch -t; no .ps1 twin (the hook has none).
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HOOKS/guard-leg-context-handoff.sh"

# HIMMEL-3092: a console leg's own exports (HIMMEL_CONSOLE_LEG, ...) must not
# reach the hook under test; each case sets what it needs on its own call.
# shellcheck source=../lib/override-env.sh
# shellcheck disable=SC1091
. "$HOOKS/../lib/override-env.sh"
scrub_override_env
unset HIMMEL_CONSOLE_LEG HIMMEL_CONSOLE_NAME HANDOVER_DIR CLAUDE_CONFIG_DIR \
    CONTEXT_FILL_TRANSCRIPT CLAUDE_CODE_SESSION_ID CLAUDE_PID \
    HIMMEL_LEG_CONTEXT_MODE HIMMEL_LEG_AUTOCOMPACT CLAUDE_CODE_AUTO_COMPACT_WINDOW
[ -f "$HOOK" ] || { echo "hook not found: $HOOK" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/guard-leg-ctx.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd)"
CFG="$T/cfg"
DIR="$T/handovers/u/himmel"
mkdir -p "$CFG/projects/p" "$CFG/plugins/claude-hud/context-cache" "$DIR"
DOC="$DIR/HIMMEL-9-N77-thing-2026-10-06.md"
TR="$CFG/projects/p/sess.jsonl"
# The guard is OFF unless the launch sets a mode (HIMMEL-4710): LEG_OFF is a
# leg launched without --context-guard; LEG_BASE turns compact on.
LEG_OFF="HIMMEL_CONSOLE_LEG=1 HIMMEL_CONSOLE_NAME=T-console CLAUDE_CONFIG_DIR=$CFG HANDOVER_DIR=$T/handovers"
LEG_BASE="$LEG_OFF HIMMEL_LEG_CONTEXT_MODE=compact"
# The RESUME-doc cases below run in handoff mode; compact has its own section,
# run with LEG_BASE alone.
LEG_ENV="$LEG_OFF HIMMEL_LEG_CONTEXT_MODE=handoff"

sha() {
    if command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum | cut -d' ' -f1
    else printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1; fi
}

# session <first-user-text> [timestamp] -- a fresh transcript whose first user turn says it
session() {
    jq -cn --arg t "$1" --arg ts "${2-2026-10-06T10:00:00.000Z}" \
        '{type:"user",timestamp:$ts,message:{role:"user",content:$t}}' > "$TR"
    printf '%s\n' '{"type":"assistant","message":{"usage":{"input_tokens":1}}}' >> "$TR"
}
# fill <pct> [window] -- a fresh HUD snapshot for the transcript at that fill
fill() {
    printf '{"used_percentage":%s,"remaining_percentage":%s,"context_window_size":%s,"saved_at":%s000}' \
        "$1" "$((100 - $1))" "${2:-200000}" "$(date +%s)" > "$CFG/plugins/claude-hud/context-cache/$(sha "$TR").json"
}
nofill() { rm -f "$CFG/plugins/claude-hud/context-cache/"*.json; }
# doc <last bullet>
doc() { printf -- '---\n---\n# brief\n\n## Results (newest at the bottom)\n\n%s\n' "$1" > "$DOC"; }

# check <label> <block|allow> <json> [extra ENV=val ...] -- leg env applied
check() {
    local label="$1" expect="$2" json="$3"; shift 3
    local rc got
    # shellcheck disable=SC2086  # LEG_ENV is a deliberate word list
    printf '%s' "$json" | env $LEG_ENV "$@" bash "$HOOK" >/dev/null 2>&1
    rc=$?
    case "$rc" in 0) got=allow ;; 2) got=block ;; *) got="?(rc=$rc)" ;; esac
    if [ "$got" = "$expect" ]; then ok "$label"; else bad "$label - expected $expect got $got"; fi
}
# Every call carries cwd = the fixture repo, where the CHECKPOINT sha is checked.
bash_call() { jq -cn --arg c "$1" --arg t "$TR" --arg w "$REPO" '{tool_name:"Bash",tool_input:{command:$c},transcript_path:$t,cwd:$w}'; }
tool_call() { jq -cn --arg n "$1" --arg t "$TR" --arg w "$REPO" '{tool_name:$n,tool_input:{},transcript_path:$t,cwd:$w}'; }
write_call() { jq -cn --arg n "$1" --arg p "$2" --arg t "$TR" --arg w "$REPO" '{tool_name:$n,tool_input:{file_path:$p,content:"x"},transcript_path:$t,cwd:$w}'; }
pc_call() { jq -cn --arg g "${1:-auto}" --arg t "$TR" --arg w "$REPO" '{hook_event_name:"PreCompact",trigger:$g,transcript_path:$t,cwd:$w,session_id:"s"}'; }
# check_c: the same check with compact in the launch env
check_c() { local LEG_ENV="$LEG_BASE"; check "$@"; }
# deny_text <json> [ENV=val ...] -- the hook's stderr for one call, handoff env
deny_text() {
    local json="$1"; shift
    # stderr only, stdout dropped: the order is deliberate.
    # shellcheck disable=SC2086,SC2069
    printf '%s' "$json" | env $LEG_ENV "$@" bash "$HOOK" 2>&1 >/dev/null
}

# The leg's worktree: a repo whose branch tracks a bare upstream, so a
# CHECKPOINT sha can be checked against HEAD and @{u}. Hooks and signing off,
# all config per call (never written to a shared .git/config).
REPO="$T/repo"
g() { git -C "$REPO" -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.email=t@t -c user.name=t "$@"; }
git init -q --bare "$T/up.git"
git init -q "$REPO"
printf 'a\n' > "$REPO/a"
g add a
g commit -qm one
g remote add origin "$T/up.git"
g push -q -u origin HEAD:refs/heads/main 2>/dev/null
g branch -q --set-upstream-to=origin/main

session "load $DOC and continue"
doc "- 10:01 LIVE — working"
LS="$(bash_call 'ls')"

echo "== off by default: no mode at launch, no guard (HIMMEL-4710) =="
fill 90
check_off() { local LEG_ENV="$LEG_OFF"; check "$@"; }
check_off "no mode, 90 % + ordinary Bash -> allow" allow "$LS"
check_off "no mode, 90 % + Edit -> allow" allow "$(write_call Edit "$T/notes.md")"
check_off "no mode, 100 % + Read -> allow" allow "$(tool_call Read)"
check_off "no mode, PreCompact auto at 90 % -> allow" allow "$(pc_call)"
check_off "mode none, 90 % -> allow" allow "$LS" HIMMEL_LEG_CONTEXT_MODE=none
check_off "empty mode, 90 % -> allow" allow "$LS" HIMMEL_LEG_CONTEXT_MODE=
# shellcheck disable=SC2086
off_out="$(printf '%s' "$LS" | env $LEG_OFF bash "$HOOK" 2>&1)"
if [ -z "$off_out" ]; then ok "no mode -> no output at all"; else bad "no mode printed: $off_out"; fi

echo "== the threshold =="
fill 90; check "90 % + ordinary Bash -> block" block "$LS"
fill 75; check "75 % (the threshold itself) -> block" block "$LS"
fill 66; check "66 % (past the old 65 % rule) -> allow" allow "$LS"
fill 74; check "74 % -> allow" allow "$LS"
fill 50; check "HIMMEL_LEG_CONTEXT_SHARE=50 at launch, 50 % -> block" block "$LS" HIMMEL_LEG_CONTEXT_SHARE=50
fill 49; check "HIMMEL_LEG_CONTEXT_SHARE=50 at launch, 49 % -> allow" allow "$LS" HIMMEL_LEG_CONTEXT_SHARE=50
fill 74; check "junk HIMMEL_LEG_CONTEXT_SHARE -> the 75 default, 74 % -> allow" allow "$LS" HIMMEL_LEG_CONTEXT_SHARE=junk
fill 75; check "out-of-range HIMMEL_LEG_CONTEXT_SHARE=0 -> the 75 default, 75 % -> block" block "$LS" HIMMEL_LEG_CONTEXT_SHARE=0
fill 75; check "out-of-range HIMMEL_LEG_CONTEXT_SHARE=101 -> the 75 default, 75 % -> block" block "$LS" HIMMEL_LEG_CONTEXT_SHARE=101
fill 90
check "90 % + Read -> block" block "$(tool_call Read)"
check "90 % + Write to an ordinary file -> block" block "$(write_call Write "$T/notes.md")"

echo "== the deny message tells the leg exactly what to do =="
# shellcheck disable=SC2086
out="$(printf '%s' "$LS" | env $LEG_ENV bash "$HOOK" 2>/dev/null)"
reason="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason' 2>/dev/null)"
if [ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)" = deny ]; then
    ok "structured permissionDecision is deny"
else
    bad "no structured deny - got: $out"
fi
for needle in "90 %" "$DIR/HIMMEL-9-N77b-thing-2026-10-06-RESUME.md" T-console \
    "append-results.sh $DOC" "Do exactly this" LEG_CONTEXT_HANDOFF_OK; do
    case "$reason" in
        *"$needle"*) ok "deny text names: $needle" ;;
        *) bad "deny text lacks '$needle' - got: $reason" ;;
    esac
done
check "bypass LEG_CONTEXT_HANDOFF_OK=1 -> allow" allow "$LS" LEG_CONTEXT_HANDOFF_OK=1

echo "== non-leg sessions are untouched =="
# shellcheck disable=SC2086
if printf '%s' "$LS" | env HIMMEL_LEG_CONTEXT_MODE=compact CLAUDE_CONFIG_DIR="$CFG" HANDOVER_DIR="$T/handovers" HIMMEL_CONSOLE_LEG=1 bash "$HOOK" >/dev/null 2>&1; then
    ok "no HIMMEL_CONSOLE_NAME at 90 % -> allow"
else
    bad "no HIMMEL_CONSOLE_NAME at 90 % -> blocked"
fi
if printf '%s' "$LS" | env HIMMEL_LEG_CONTEXT_MODE=compact CLAUDE_CONFIG_DIR="$CFG" HANDOVER_DIR="$T/handovers" HIMMEL_CONSOLE_NAME=T-console bash "$HOOK" >/dev/null 2>&1; then
    ok "no HIMMEL_CONSOLE_LEG at 90 % -> allow"
else
    bad "no HIMMEL_CONSOLE_LEG at 90 % -> blocked"
fi
silent_out="$(printf '%s' "$LS" | env HIMMEL_LEG_CONTEXT_MODE=compact CLAUDE_CONFIG_DIR="$CFG" bash "$HOOK" 2>&1)"
if [ -z "$silent_out" ]; then ok "non-leg -> no output at all"; else bad "non-leg printed: $silent_out"; fi

echo "== hand-off calls always pass at 90 % =="
RESUME="$DIR/HIMMEL-9-N77b-thing-2026-10-06-RESUME.md"
check "Write the RESUME doc -> allow" allow "$(write_call Write "$RESUME")"
check "Edit the RESUME doc -> allow" allow "$(write_call Edit "$RESUME")"
check "SendMessage -> allow" allow "$(tool_call SendMessage)"
check "ListAgents -> allow" allow "$(tool_call ListAgents)"
check "TaskStop -> allow" allow "$(tool_call TaskStop)"
check "ToolSearch -> allow" allow "$(tool_call ToolSearch)"
check "append-results.sh -> allow" allow \
    "$(bash_call "bash scripts/handover/console-kit/append-results.sh $DOC 'BLOCKED — context 90 %; ctx | see \`RESUME\` & (more)'")"
check "absolute append-results.sh -> allow" allow \
    "$(bash_call "bash /x/himmel/scripts/handover/console-kit/append-results.sh $DOC \"WRAPPED — done\"")"
check "queue-lock.sh release -> allow" allow "$(bash_call "bash scripts/handover/queue-lock.sh release $DOC tok")"
check "wrap-subtree-check.sh -> allow" allow "$(bash_call 'bash scripts/handover/wrap-subtree-check.sh')"
check "context-fill.sh probe -> allow" allow "$(bash_call 'bash scripts/context-fill.sh --percent')"
check "queue-lock.sh acquire -> block (not a hand-off)" block "$(bash_call "bash scripts/handover/queue-lock.sh acquire $DOC")"
check "append-results.sh && more -> block" block \
    "$(bash_call "bash scripts/handover/console-kit/append-results.sh $DOC \"LIVE x\" && rm -rf /tmp/x")"
check "append-results.sh || more -> block" block \
    "$(bash_call "bash scripts/handover/console-kit/append-results.sh $DOC \"LIVE x\" || ls")"
check "append-results.sh with \$( -> block" block \
    "$(bash_call "bash scripts/handover/console-kit/append-results.sh $DOC \"\$(ls)\"")"
check "echo naming append-results.sh -> block" block "$(bash_call 'echo scripts/handover/console-kit/append-results.sh')"

echo "== the exemptions: a RESUME doc exists, or the last marker is WRAPPED/BLOCKED =="
printf 'resume\n' > "$RESUME"
check "fresh N77b RESUME doc -> allow" allow "$LS"
doc "- 10:01 BLOCKED — context 90 %, RESUME written"
check "fresh RESUME then BLOCKED + Edit -> block" block "$(write_call Edit "$T/notes.txt")"
check "fresh RESUME then BLOCKED, PreCompact auto -> allow" allow "$(pc_call)"
doc "- 10:01 LIVE — working"
touch -t 202001010000 "$RESUME"
check "RESUME doc older than this session -> block" block "$LS"
session "load $DOC and continue" "2026-10-06T12:00:00+02:00"
check "session start unparsable + old RESUME doc -> block" block "$LS"
session "load $DOC and continue" ""
check "session start missing + old RESUME doc -> block" block "$LS"
session "load $DOC and continue"
rm -f "$RESUME"
printf 'other leg\n' > "$DIR/HIMMEL-9-N78b-thing-2026-10-06-RESUME.md"
check "another leg's RESUME doc -> block" block "$LS"
printf 'longer id\n' > "$DIR/HIMMEL-9-N770b-thing-2026-10-06-RESUME.md"
check "a longer id sharing the prefix (N770) -> block" block "$LS"
doc "- 10:01 WRAPPED — merged"
check "last marker WRAPPED -> allow" allow "$LS"
doc "- 10:01 BLOCKED — waiting on console"
# HIMMEL-4710 (B): BLOCKED is a hand-off, not an unlock - it frees reads and
# the hand-off calls, never ordinary work (N1383 wrote BLOCKED, then kept editing).
check "last marker BLOCKED + Edit -> block" block "$(write_call Edit "$T/notes.md")"
check "last marker BLOCKED + Write -> block" block "$(write_call Write "$T/notes.md")"
check "last marker BLOCKED + ordinary Bash -> block" block "$LS"
check "last marker BLOCKED + Read -> allow" allow "$(tool_call Read)"
check "last marker BLOCKED + Grep -> allow" allow "$(tool_call Grep)"
check "last marker BLOCKED + Glob -> allow" allow "$(tool_call Glob)"
check "last marker BLOCKED + SendMessage -> allow" allow "$(tool_call SendMessage)"
check_c "compact, last marker BLOCKED + Edit -> block" block "$(write_call Edit "$T/notes.md")"
doc "- 10:01 FINDING — question"
check "last marker FINDING -> block" block "$LS"
doc "- 10:01 LIVE — working"

echo "== a resumed leg: its own RESUME-named doc is not its hand-off =="
DOC2="$DIR/HIMMEL-9-N77b-thing-2026-10-06-RESUME.md"
printf -- '# resumed\n\n## Results\n\n- 10:01 LIVE — resumed\n' > "$DOC2"
session "load $DOC2 and continue"
fill 90
check "resumed leg, only its own doc -> block" block "$LS"
# shellcheck disable=SC2086
reason="$(printf '%s' "$LS" | env $LEG_ENV bash "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.permissionDecisionReason' 2>/dev/null)"
case "$reason" in
    *"HIMMEL-9-N77c-thing-2026-10-06-RESUME.md"*) ok "resumed leg is told to write the N77c doc" ;;
    *) bad "resumed leg suggestion wrong - got: $reason" ;;
esac
printf 'next\n' > "$DIR/HIMMEL-9-N77c-thing-2026-10-06-RESUME.md"
check "resumed leg + fresh N77c RESUME doc -> allow" allow "$LS"
rm -f "$DOC2" "$DIR/HIMMEL-9-N77c-thing-2026-10-06-RESUME.md"
session "load $DOC and continue"

echo "== in-process subagents (agent_id) are exempt =="
sub_call() { printf '%s' "$1" | jq -c --arg a "$2" '. + {agent_id:$a}'; }
check "subagent Bash at 90 % -> allow" allow "$(sub_call "$LS" a1b2c3)"
check "subagent Read at 90 % -> allow" allow "$(sub_call "$(tool_call Read)" a1b2c3)"
# shellcheck disable=SC2086
sub_out="$(sub_call "$LS" a1b2c3 | env $LEG_ENV bash "$HOOK" 2>&1)"
if [ -z "$sub_out" ]; then ok "subagent -> no deny text, never invited to write a RESUME"; else bad "subagent printed: $sub_out"; fi
check "subagent RESUME write -> allow" allow "$(sub_call "$(write_call Write "$T/scratch/x-RESUME.md")" a1b2c3)"
check "parent still blocked after the subagent's RESUME write" block "$LS"
check "agent_id empty string -> not a subagent, block" block "$(sub_call "$LS" '')"
check "agent_id non-string -> not a subagent, block" block "$(printf '%s' "$LS" | jq -c '. + {agent_id:true}')"

echo "== WIP commit/push stays allowed at 90 % =="
check "git add -> allow" allow "$(bash_call 'git add scripts/x.sh')"
check "git commit -m -> allow" allow "$(bash_call 'git commit -m "wip: context hand-off"')"
check "git push -> allow" allow "$(bash_call 'git push origin fix/x')"
check "git -C <dir> commit -> allow" allow "$(bash_call "git -C $T commit -am wip")"
check "git commit && more -> block" block "$(bash_call 'git commit -m wip && ls')"
# shellcheck disable=SC2016 # a literal $( is the shape under test
check "git commit with \$( -> block" block "$(bash_call 'git commit -m "$(cat x)"')"
check "git status -> allow (the checkpoint reads it)" allow "$(bash_call 'git status --short')"
check "git rev-parse HEAD -> allow (the CHECKPOINT sha)" allow "$(bash_call 'git rev-parse HEAD')"
check "git log -> block (not a hand-off)" block "$(bash_call 'git log -1')"
check "git commitx -> block" block "$(bash_call 'git commitx')"
# HIMMEL-4710 item 2: a leg whose cwd drifted must be able to cd back.
check "bare cd <dir> -> allow" allow "$(bash_call "cd $REPO")"
check "bare cd -> allow" allow "$(bash_call 'cd')"
check "cd <dir>; more -> block" block "$(bash_call "cd $REPO; rm -rf x")"
check "cd <dir> | more -> block" block "$(bash_call "cd $REPO | ls")"
check "cd a b -> block" block "$(bash_call 'cd a b')"
# HIMMEL-4725: a quoted literal path is still one bare cd; a variable or a
# compound after it stays refused.
check "cd \"<dir with space>\" -> allow" allow "$(bash_call 'cd "/tmp/a b/c"')"
check "cd '<dir with space>' -> allow" allow "$(bash_call "cd '/tmp/a b/c'")"
check "cd \"<dir>\" -> allow" allow "$(bash_call "cd \"$REPO\"")"
check "cd \"<dir>\"; more -> block" block "$(bash_call 'cd "/tmp/a b"; rm -rf x')"
check "cd '<dir>' && more -> block" block "$(bash_call "cd '/tmp/a b' && ls")"
check "cd \"<dir>\" x -> block" block "$(bash_call 'cd "/tmp/a" x')"
# shellcheck disable=SC2016 # a literal $VAR / $( is the shape under test
check 'cd "$VAR" -> block' block "$(bash_call 'cd "$VAR"')"
# shellcheck disable=SC2016
check 'cd $VAR -> block' block "$(bash_call 'cd $VAR')"
# shellcheck disable=SC2016
check 'cd "$(pwd)" -> block' block "$(bash_call 'cd "$(pwd)"')"
# Round-2 codex-1: every command-substitution or chaining shape refuses the
# whole call, not only && || $( and a newline.
# shellcheck disable=SC2016 # literal backticks and <( are the shapes under test
check "cd \`payload\` -> block" block "$(bash_call 'cd `./payload`')"
# shellcheck disable=SC2016
check "git commit with backticks -> block" block "$(bash_call 'git commit -m "`id`"')"
check "git status; more -> block" block "$(bash_call 'git status; touch x')"
check "git status | more -> block" block "$(bash_call 'git status | sh')"
check "git push & more -> block" block "$(bash_call 'git push & touch x')"
check "git commit -F <( -> block" block "$(bash_call 'git commit -F <(echo x)')"
check "double-quoted bullet with ; -> allow" allow \
    "$(bash_call "bash scripts/handover/console-kit/append-results.sh $DOC \"LIVE a; b | c\"")"
# shellcheck disable=SC2016
check "double-quoted bullet with backticks -> block" block \
    "$(bash_call "bash scripts/handover/console-kit/append-results.sh $DOC \"LIVE \`id\`\"")"
check "escaped quote then ; -> block" block "$(bash_call "git status \\'; touch x; echo \\'")"
check "apostrophe in double quotes then ; -> block" block "$(bash_call "git commit -m \"it's\"; touch x; echo \"'\"")"
check "unclosed quote -> block" block "$(bash_call "git commit -m 'x")"
# Round-3 codex-1: ANSI-C quoting lets \' escape, so $'…' is refused outright.
check "ANSI-C quote then ; -> block" block "$(bash_call "git status \$'a\\'b'; touch x #'")"
check "ANSI-C quote alone -> block" block "$(bash_call "git commit -m \$'x'")"
check "dollar-quote inside double quotes is literal -> allow" allow "$(bash_call "git commit -m \"cost \$'x'\"")"
check "redirect -> block" block "$(bash_call 'git status > x')"
check "append-results.sh; more -> block" block \
    "$(bash_call "bash scripts/handover/console-kit/append-results.sh $DOC \"LIVE x\"; rm -rf /tmp/x")"

echo "== compact mode: a pushed CHECKPOINT of HEAD unlocks =="
session "load $DOC and continue"
doc "- 10:01 LIVE — working"
rm -f "$RESUME"
fill 90
HEAD1="$(g rev-parse HEAD)"
check_c "compact, no CHECKPOINT -> block" block "$LS"
printf 'resume\n' > "$RESUME"
check_c "compact, a fresh RESUME doc is not the unlock -> block" block "$LS"
rm -f "$RESUME"
# shellcheck disable=SC2086
reason="$(printf '%s' "$LS" | env $LEG_BASE bash "$HOOK" 2>&1 >/dev/null)"
for needle in "mode compact" "git push" "CHECKPOINT <full sha of HEAD> pushed" "append-results.sh $DOC" \
    HIMMEL_LEG_CONTEXT_MODE "Do exactly this" \
    'git commit -m "<subject>" -m "<body>" --trailer' "one line" \
    "cannot push" "BLOCKED" "WRAPPED" "SendMessage your console T-console"; do
    case "$reason" in
        *"$needle"*) ok "compact deny text names: $needle" ;;
        *) bad "compact deny text lacks '$needle' - got: $reason" ;;
    esac
done
doc "- 10:01 LIVE — CHECKPOINT $HEAD1 pushed"
check_c "CHECKPOINT of the pushed HEAD -> allow" allow "$LS"
check_c "explicit HIMMEL_LEG_CONTEXT_MODE=compact -> allow" allow "$LS" HIMMEL_LEG_CONTEXT_MODE=compact
doc "- 10:01 LIVE — CHECKPOINT \`$HEAD1\` pushed"
check_c "backticked CHECKPOINT sha -> allow" allow "$LS"
# A BLOCKED after a valid CHECKPOINT is still a hand-off: the checkpoint unlock
# must not reopen ordinary work, though a safe auto-compaction may proceed.
doc "$(printf -- '- 10:01 LIVE — CHECKPOINT %s pushed\n- 10:02 BLOCKED — waiting on console' "$HEAD1")"
check_c "CHECKPOINT then BLOCKED + Edit -> block" block "$(write_call Edit "$T/notes.txt")"
check_c "CHECKPOINT then BLOCKED + ordinary Bash -> block" block "$LS"
check_c "CHECKPOINT then BLOCKED + Read -> allow" allow "$(tool_call Read)"
check_c "CHECKPOINT then BLOCKED, PreCompact auto -> allow" allow "$(pc_call)"
doc "- 10:01 LIVE — CHECKPOINT $HEAD1 pushed"
check "handoff mode: a CHECKPOINT is not its unlock -> block" block "$LS"
printf 'b\n' > "$REPO/b"
g add b
g commit -qm two
HEAD2="$(g rev-parse HEAD)"
doc "- 10:01 LIVE — CHECKPOINT $HEAD1 pushed"
check_c "stale CHECKPOINT (HEAD moved on) -> block" block "$LS"
doc "- 10:01 LIVE — CHECKPOINT $HEAD2 pushed"
check_c "CHECKPOINT of an unpushed HEAD -> block" block "$LS"
g push -q origin HEAD:refs/heads/main 2>/dev/null
check_c "the same CHECKPOINT once pushed -> allow" allow "$LS"
doc "$(printf -- '- 10:01 LIVE — CHECKPOINT %s pushed\n- 10:02 LIVE — CHECKPOINT %s pushed' "$HEAD2" "$HEAD1")"
check_c "newest CHECKPOINT bullet stale, older one fresh -> block" block "$LS"
doc "- 10:01 LIVE — CHECKPOINT $(printf '%040d' 7) pushed"
check_c "CHECKPOINT of a sha that is not this worktree's HEAD -> block" block "$LS"
doc "- 10:01 LIVE — CHECKPOINT ${HEAD2:0:12} pushed"
check_c "short CHECKPOINT sha -> block" block "$LS"
doc "- 10:01 LIVE — CHECKPOINT $HEAD2"
check_c "CHECKPOINT without 'pushed' -> block" block "$LS"
doc "CHECKPOINT $HEAD2 pushed"
check_c "CHECKPOINT outside a bullet -> block" block "$LS"
doc "- 10:01 LIVE — working"
printf -- '# other\n\n## Results\n\n- 10:01 LIVE — CHECKPOINT %s pushed\n' "$HEAD2" > "$DIR/HIMMEL-9-N78-other-2026-10-06.md"
check_c "another leg's doc carries the CHECKPOINT -> block" block "$LS"
rm -f "$DIR/HIMMEL-9-N78-other-2026-10-06.md"
doc "- 10:01 WRAPPED — merged"
check_c "compact, last marker WRAPPED -> allow" allow "$LS"
doc "- 10:01 LIVE — working"
check_c "compact, git commit stays allowed" allow "$(bash_call 'git commit -m wip')"
check_c "compact, append-results.sh stays allowed" allow \
    "$(bash_call "bash scripts/handover/console-kit/append-results.sh $DOC \"LIVE — CHECKPOINT $HEAD2 pushed\"")"

echo "== compact mode: a clean tree with nothing unpushed checkpoints without a push =="
# HIMMEL-4710 expansion: a leg that has only read has nothing to commit, and the
# pre-push CR gate refuses an empty push - N1386 could never checkpoint.
doc "- 10:01 LIVE — CHECKPOINT $HEAD2 clean"
check_c "CHECKPOINT <HEAD> clean, clean tree, HEAD = upstream -> allow" allow "$LS"
check_c "CHECKPOINT clean also unlocks PreCompact" allow "$(pc_call)"
doc "- 10:01 LIVE — CHECKPOINT \`$HEAD2\` clean"
check_c "backticked CHECKPOINT clean sha -> allow" allow "$LS"
doc "- 10:01 LIVE — CHECKPOINT $HEAD1 clean"
check_c "CHECKPOINT clean of a stale sha -> block" block "$LS"
doc "- 10:01 LIVE — CHECKPOINT $HEAD2 clean"
printf 'u\n' > "$REPO/untracked"
check_c "CHECKPOINT clean, untracked file -> block" block "$LS"
rm -f "$REPO/untracked"
printf 'a2\n' > "$REPO/a"
check_c "CHECKPOINT clean, modified file -> block" block "$LS"
g checkout -q -- a
g checkout -q -b noup
check_c "CHECKPOINT clean, no upstream, HEAD = origin/main (the base) -> allow" allow "$LS"
printf 'c\n' > "$REPO/c"
g add c
g commit -qm three
HEAD3="$(g rev-parse HEAD)"
doc "- 10:01 LIVE — CHECKPOINT $HEAD3 clean"
check_c "CHECKPOINT clean, no upstream, an unpushed commit -> block" block "$LS"
g checkout -q -
g branch -q -D noup
doc "- 10:01 LIVE — CHECKPOINT $HEAD2 clean"
check "handoff mode: CHECKPOINT clean is not its unlock -> block" block "$LS"
doc "- 10:01 LIVE — working"

echo "== the mode is launch-time only =="
printf 'resume\n' > "$RESUME"
check "handoff from the launch env + RESUME -> allow" allow "$LS"
check_c "a Bash call exporting the mode -> block (mode stays compact)" block "$(bash_call 'export HIMMEL_LEG_CONTEXT_MODE=handoff')"
check_c "a per-call mode prefix -> block" block "$(bash_call 'HIMMEL_LEG_CONTEXT_MODE=handoff ls')"
doc "$(printf -- 'HIMMEL_LEG_CONTEXT_MODE=handoff\n- 10:01 LIVE — working')"
check_c "the mode written into the leg doc -> ignored, block" block "$LS"
doc "- 10:01 LIVE — working"
check_c "unknown mode value -> compact, RESUME is not the unlock" block "$LS" HIMMEL_LEG_CONTEXT_MODE=bogus
case "$(deny_text "$LS" HIMMEL_LEG_CONTEXT_MODE=bogus)" in
    *"mode compact"*) ok "unknown mode value -> the deny text says compact" ;;
    *) bad "unknown mode value -> deny text does not say compact" ;;
esac
rm -f "$RESUME"

echo "== the threshold derives from the autocompact ceiling =="
fill 15 1000000; check "1M window, default 200000 ceiling, 15 % -> block" block "$LS"
fill 14 1000000; check "1M window, default 200000 ceiling, 14 % -> allow" allow "$LS"
fill 15 1000000
case "$(deny_text "$LS")" in
    *"threshold 15 %"*"200000"*) ok "deny text names the derived threshold and the ceiling" ;;
    *) bad "deny text lacks the derived threshold - got: $(deny_text "$LS")" ;;
esac
fill 29 1000000; check "400000 ceiling on 1M, 29 % -> allow" allow "$LS" HIMMEL_LEG_AUTOCOMPACT=400000
fill 30 1000000; check "400000 ceiling on 1M, 30 % -> block" block "$LS" HIMMEL_LEG_AUTOCOMPACT=400000
fill 74 1000000; check "auto ceiling (the window), 74 % -> allow" allow "$LS" HIMMEL_LEG_AUTOCOMPACT=auto
fill 75 1000000; check "auto ceiling (the window), 75 % -> block" block "$LS" HIMMEL_LEG_AUTOCOMPACT=auto
fill 23 1000000; check "CLAUDE_CODE_AUTO_COMPACT_WINDOW 300000 wins, 23 % -> block" block "$LS" \
    HIMMEL_LEG_AUTOCOMPACT=200000 CLAUDE_CODE_AUTO_COMPACT_WINDOW=300000
fill 22 1000000; check "CLAUDE_CODE_AUTO_COMPACT_WINDOW 300000 wins, 22 % -> allow" allow "$LS" \
    HIMMEL_LEG_AUTOCOMPACT=200000 CLAUDE_CODE_AUTO_COMPACT_WINDOW=300000
fill 74 200000; check "ceiling above the window clamps to it, 74 % -> allow" allow "$LS" HIMMEL_LEG_AUTOCOMPACT=400000
fill 75 200000; check "ceiling above the window clamps to it, 75 % -> block" block "$LS" HIMMEL_LEG_AUTOCOMPACT=400000
fill 50 1000000; check "junk ceiling -> the window (fail-open), 50 % -> allow" allow "$LS" HIMMEL_LEG_AUTOCOMPACT=junk
printf '{"used_percentage":90,"remaining_percentage":10,"saved_at":%s000}' "$(date +%s)" \
    > "$CFG/plugins/claude-hud/context-cache/$(sha "$TR").json"
check "no window in the snapshot -> 75 % of the fill, 90 % -> block" block "$LS"

echo "== PreCompact: no auto-compaction past the threshold without CHECKPOINT/RESUME =="
fill 90
doc "- 10:01 LIVE — working"
check_c "PreCompact auto, compact, no CHECKPOINT -> block" block "$(pc_call)"
# shellcheck disable=SC2086
case "$(printf '%s' "$(pc_call)" | env $LEG_BASE bash "$HOOK" 2>&1 >/dev/null)" in
    *CHECKPOINT*) ok "PreCompact refusal names the CHECKPOINT unlock" ;;
    *) bad "PreCompact refusal does not name CHECKPOINT" ;;
esac
check_c "PreCompact manual (operator /compact) -> allow" allow "$(pc_call manual)"
doc "- 10:01 LIVE — CHECKPOINT $HEAD2 pushed"
check_c "PreCompact auto + fresh CHECKPOINT -> allow" allow "$(pc_call)"
doc "- 10:01 LIVE — working"
check "PreCompact auto, handoff, no RESUME -> block" block "$(pc_call)"
printf 'resume\n' > "$RESUME"
check "PreCompact auto, handoff + fresh RESUME -> allow" allow "$(pc_call)"
check_c "PreCompact auto, compact + fresh RESUME -> allow" allow "$(pc_call)"
rm -f "$RESUME"
doc "- 10:01 BLOCKED — waiting"
check_c "PreCompact auto, last marker BLOCKED, no CHECKPOINT -> block" block "$(pc_call)"
doc "- 10:01 WRAPPED — merged"
check_c "PreCompact auto, last marker WRAPPED -> allow" allow "$(pc_call)"
doc "- 10:01 LIVE — working"
# Below the threshold the leg has had no deny telling it to checkpoint, so a
# refusal there would be blind (ruling 2026-10-07): it passes.
fill 70; check_c "PreCompact below the threshold -> allow" allow "$(pc_call)"
nofill; check_c "PreCompact, fill UNKNOWN -> allow" allow "$(pc_call)"
fill 90
# A precomputed string: the hook exits before reading stdin here, and a slower
# writer would die of SIGPIPE under pipefail.
PC="$(pc_call)"
if printf '%s' "$PC" | env CLAUDE_CONFIG_DIR="$CFG" bash "$HOOK" >/dev/null 2>&1; then
    ok "PreCompact in a non-leg session -> allow"
else
    bad "PreCompact in a non-leg session -> blocked"
fi

echo "== fail-open: fill UNKNOWN/STALE, leg doc unknown, junk input =="
nofill
check "no HUD snapshot (UNKNOWN) at would-be 90 % -> allow" allow "$LS"
# shellcheck disable=SC2086
warn="$(printf '%s' "$LS" | env $LEG_ENV bash "$HOOK" 2>&1 >/dev/null)"
case "$warn" in
    *guard-leg-context-handoff*) ok "UNKNOWN fill -> one-line warning on stderr" ;;
    *) bad "UNKNOWN fill -> no warning - got: $warn" ;;
esac
if [ "$(printf '%s\n' "$warn" | wc -l | tr -d ' ')" = 1 ]; then ok "warning is one line"; else bad "warning is not one line: $warn"; fi
printf '{"used_percentage":90,"remaining_percentage":10,"context_window_size":200000,"saved_at":1000}' \
    > "$CFG/plugins/claude-hud/context-cache/$(sha "$TR").json"
check "STALE snapshot at 90 % -> allow" allow "$LS"
fill 90
check "no transcript_path -> allow" allow '{"tool_name":"Bash","tool_input":{"command":"ls"}}'
session "hello, no brief path here"
fill 90
check "leg doc not named in the first turn -> allow" allow "$LS"
session "load $DIR/missing-doc.md and continue"
fill 90
check "leg doc named but missing -> allow" allow "$LS"
session "load $DOC and continue"
fill 90
check "malformed JSON -> allow" allow '{not json'
check "empty stdin -> allow" allow ''

echo "== array-shaped first user turn =="
jq -cn --arg t "load $DOC and continue" \
    '{type:"user",timestamp:"2026-10-06T10:00:00.000Z",message:{role:"user",content:[{type:"text",text:$t}]}}' > "$TR"
fill 90
check "content as a text-block array -> leg doc found, block" block "$LS"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
