#!/usr/bin/env bash
# Tests for scripts/memory/audit-memory-capture.sh (HIMMEL-570 / HIMMEL-1090).
#
# Timestamps are generated at runtime — a hardcoded 2026-07-16/17 record falls
# outside the trailing window within a week and the tripwire/window cases then
# fail forever. MEMORY_AUDIT_SKIP_QMD=1 in run() keeps these cases hermetic
# (otherwise check 5 would query the real qmd index and go machine-dependent).
set -uo pipefail

AUDIT="$(cd "$(dirname "$0")" && pwd)/audit-memory-capture.sh"
[ -x "$AUDIT" ] || chmod +x "$AUDIT"

FAILED=0; SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
export HOME="$SB"
MEM="$SB/memory"; mkdir -p "$MEM"; VAULT="$SB/vault"; mkdir -p "$VAULT"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

assert_rc() { if [ "$3" = "$2" ]; then echo "PASS $1 (rc=$3)"; else echo "FAIL $1 (want $2, got $3)"; FAILED=1; fi; }
# LUNA_VAULT_PATH -> the sandbox vault (substrate for the orphaned-deny grep).
# MEMORY_AUDIT_SKIP_QMD=1 -> skip the best-effort qmd collection check (hermetic).
# MEMORY_AUDIT_WINDOW_DAYS=7 is PINNED so the out-of-window case stays hermetic
# regardless of a caller's env (an inherited value would move the window).
run() { MEMORY_CAPTURE_LOG="$SB/capture.jsonl" MEMDIR="$MEM" LUNA_VAULT_PATH="$VAULT" MEMORY_AUDIT_SKIP_QMD=1 MEMORY_AUDIT_WINDOW_DAYS=7 bash "$AUDIT" >/dev/null 2>&1; }

printf -- '- ok -> luna [[n]]\n' > "$MEM/MEMORY.md"

# 1: a deny whose fact never landed in the substrate = ORPHANED = finding.
jq -nc --arg ts "$NOW" '{ts:$ts,event:"deny",hash:"abc123",excerpt:"rtk masks gitleaks blocks"}' > "$SB/capture.jsonl"
run; assert_rc "orphaned deny flagged" 1 "$?"

# 2: same deny, fact now present in the substrate = clean.
printf 'rtk masks gitleaks blocks — always confirm a sha.\n' > "$VAULT/himmel-harness-gotchas.md"
run; assert_rc "landed deny clean" 0 "$?"

# 3 (Rev2 INVERT): a topic file NOT referenced by any MEMORY.md routing line =
# ORPHAN = finding. (The base asserted the OLD '>2 topic files' drift check; the
# design now EXPECTS topic files, so accumulation alone is never a finding.)
: > "$SB/capture.jsonl"   # isolate: no denies so check 1 is trivially clean
printf -- '- [Routed fact](fact-1.md) — hook\n' > "$MEM/MEMORY.md"
printf 'body\n' > "$MEM/fact-1.md"   # routed -> not an orphan
printf 'body\n' > "$MEM/fact-2.md"   # orphan
printf 'body\n' > "$MEM/fact-3.md"   # orphan
run; assert_rc "orphan topic file flagged" 1 "$?"
rm -f "$MEM"/fact-*.md
printf -- '- ok -> luna [[n]]\n' > "$MEM/MEMORY.md"   # reset for the remaining cases

# 4: weekly pointer-line growth >1 = tripwire finding (runtime ts, always in-window).
{ jq -nc --arg ts "$NOW" '{ts:$ts,event:"write",lines_delta:3}'
  jq -nc --arg ts "$NOW" '{ts:$ts,event:"write",lines_delta:4}'; } > "$SB/capture.jsonl"
run; assert_rc "line-growth tripwire flagged" 1 "$?"

# 5: an excerpt containing regex metachars must match literally, not as a pattern.
printf 'the pruned-worktree ../../ trap — capture the patch first.\n' > "$VAULT/t.md"
jq -nc --arg ts "$NOW" '{ts:$ts,event:"deny",hash:"d1",excerpt:"pruned-worktree ../../ trap"}' > "$SB/capture.jsonl"
run; assert_rc "regex-metachar excerpt matched literally" 0 "$?"

# 6 (P2-13): denies exist but substrate genuinely unresolvable -> WARN, NOT a
# silent 'clean'. Unset every substrate source so resolve_substrate returns "".
jq -nc --arg ts "$NOW" '{ts:$ts,event:"deny",hash:"x",excerpt:"unresolvable substrate fact"}' > "$SB/capture.jsonl"
HOME="" USERPROFILE="" LUNA_VAULT_PATH="" MEMORY_CAPTURE_LOG="$SB/capture.jsonl" MEMDIR="$MEM" MEMORY_AUDIT_SKIP_QMD=1 \
    bash "$AUDIT" >/dev/null 2>&1
assert_rc "substrate-unresolvable WARN flagged" 1 "$?"

# 7 (P2-14): an out-of-window deny does NOT ring once aged past the trailing
# window, even though the fact is genuinely absent. (jq gmtime/strftime instead
# of `date -d`, which is Git-Bash-unreliable.)
old_ts="$(jq -r '(now - 30*24*3600)|gmtime|strftime("%Y-%m-%dT%H:%M:%SZ")')"
jq -nc --arg ts "$old_ts" '{ts:$ts,event:"deny",hash:"o",excerpt:"ancient un-landed fact"}' > "$SB/capture.jsonl"
run; assert_rc "out-of-window deny aged out (clean)" 0 "$?"

# 8 (CR round 2): MEMORY.md deleted while a topic file remains = nothing routes
# anything = every topic is an orphan. The check must NOT skip (false-clean) when
# the index is absent.
: > "$SB/capture.jsonl"
rm -f "$MEM/MEMORY.md"
printf 'body\n' > "$MEM/orphan-when-no-index.md"
run; assert_rc "missing index + topic file = orphan flagged" 1 "$?"

exit "$FAILED"
