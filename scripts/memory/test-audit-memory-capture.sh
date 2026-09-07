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

# 9 (CR round 2, HIMMEL-2194): outside any git repo and MEMDIR unset, the
# script must fail loudly instead of deriving a "." slug and silently auditing
# $HOME/.claude/projects/./memory. $SB (mktemp -d) is itself outside any git
# work tree, so cd there + no MEMDIR reproduces the bug's precondition exactly.
noncmd_err="$SB/noncmd.err"
( cd "$SB" && env -u MEMDIR MEMORY_CAPTURE_LOG="$SB/capture.jsonl" MEMORY_AUDIT_SKIP_QMD=1 bash "$AUDIT" >/dev/null 2>"$noncmd_err" )
noncmd_rc=$?
assert_rc "non-repo cwd fails loudly (no MEMDIR)" 1 "$noncmd_rc"
if grep -q 'not inside a git repo' "$noncmd_err"; then
    echo "PASS non-repo cwd diagnostic present"
else
    echo "FAIL non-repo cwd diagnostic present (stderr: $(cat "$noncmd_err"))"
    FAILED=1
fi

# 10 (HIMMEL-2194 r5): git < 2.31 lacks --path-format, so `git rev-parse
# --path-format=absolute --git-common-dir` returns nothing there; the script
# must fall back to plain `--git-common-dir` and still derive MEMDIR. A stub
# `git` on PATH that rejects --path-format (delegating everything else to the
# real git) simulates that shape cheaply, without needing an actual old git
# binary. Real git's plain form returns a RELATIVE ".git" from a repo's
# toplevel (verified empirically) — exactly the case the normalization step
# exists for; without it MEMDIR would derive from an unresolved relative path.
fb_repo="$SB/fb-repo"; git init -q "$fb_repo"
fb_bin="$SB/fb-bin"; mkdir -p "$fb_bin"
real_git="$(command -v git)"
cat > "$fb_bin/git" <<STUBEOF
#!/usr/bin/env bash
case " \$* " in
  *" --path-format=absolute "*) exit 1 ;;
esac
exec "$real_git" "\$@"
STUBEOF
chmod +x "$fb_bin/git"
fb_err="$SB/fb.err"
( cd "$fb_repo" && PATH="$fb_bin:$PATH" env -u MEMDIR MEMORY_CAPTURE_LOG="$SB/capture.jsonl" MEMORY_AUDIT_SKIP_QMD=1 bash "$AUDIT" >/dev/null 2>"$fb_err" )
fb_rc=$?
if grep -q 'not inside a git repo' "$fb_err"; then
    echo "FAIL git<2.31 fallback derives MEMDIR (stderr: $(cat "$fb_err"))"
    FAILED=1
else
    assert_rc "git<2.31 fallback derives MEMDIR (clean run)" 0 "$fb_rc"
fi

exit "$FAILED"
