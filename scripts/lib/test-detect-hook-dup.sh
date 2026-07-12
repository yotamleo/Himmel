#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-detect-hook-dup.sh -- hermetic tests for detect-hook-dup.sh.
# SC5:  warns iff a UNIVERSAL hook is wired at BOTH user + a NON-himmel project;
#       stays SILENT in-repo (project == himmel's own settings.json).
# SC11: the double-fire is benign -- a representative allow-case (auto-approve) and
#       block-case (block-read-secrets) each yield the SAME decision when the hook
#       runs twice on identical input (so wiring it at both scopes is harmless).
set -u
here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
det="$here/detect-hook-dup.sh"
fails=0
check(){ [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
td="$(mktemp -d)"

UJSON='{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash /user/scripts/hooks/auto-approve-safe-bash.sh"}]}],"SessionStart":[{"hooks":[{"type":"command","command":"bash /user/scripts/hooks/inject-initiative.sh"}]}]}}'
user="$td/user.json"; printf '%s' "$UJSON" > "$user"

# ── SC5a: non-himmel project sharing a UNIVERSAL hook → warning lists it ─────
mkdir -p "$td/proj/.claude"
printf '%s' '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash /proj/scripts/hooks/auto-approve-safe-bash.sh"}]}]}}' > "$td/proj/.claude/settings.json"
out=$(bash "$det" "$user" "$td/proj/.claude/settings.json" "/opt/himmel" 2>&1)
printf '%s' "$out" | grep -q "wired at BOTH user and project scope" && check "SC5 warns on non-himmel dup" yes yes || check "SC5 warns on non-himmel dup" no yes
printf '%s' "$out" | grep -q "auto-approve-safe-bash" && check "SC5 lists the dup hook" yes yes || check "SC5 lists the dup hook" no yes
printf '%s' "$out" | grep -q "unwire-pretooluse-hooks.sh --scope project --target $td/proj" && check "SC5 prints remediation target" yes yes || check "SC5 remediation" no yes

# ── SC5b: in-repo (project == himmel's own settings) → SILENT ───────────────
out=$(bash "$det" "$user" "$repo_root/.claude/settings.json" "$repo_root" 2>&1)
check "SC5 silent in-repo" "$(printf '%s' "$out" | grep -c 'BOTH user and project')" "0"

# ── SC5c: project does NOT share any UNIVERSAL hook → SILENT ────────────────
mkdir -p "$td/proj2/.claude"
printf '%s' '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash /proj2/scripts/hooks/some-other-hook.sh"}]}]}}' > "$td/proj2/.claude/settings.json"
out=$(bash "$det" "$user" "$td/proj2/.claude/settings.json" "/opt/himmel" 2>&1)
check "SC5 silent when no shared hook" "$(printf '%s' "$out" | grep -c 'BOTH user and project')" "0"

# ── SC5d: SessionStart inject-initiative dup is also detected ───────────────
mkdir -p "$td/proj3/.claude"
printf '%s' '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"bash /proj3/scripts/hooks/inject-initiative.sh"}]}]}}' > "$td/proj3/.claude/settings.json"
out=$(bash "$det" "$user" "$td/proj3/.claude/settings.json" "/opt/himmel" 2>&1)
printf '%s' "$out" | grep -q "inject-initiative" && check "SC5 detects SessionStart dup" yes yes || check "SC5 detects SessionStart dup" no yes

# ── SC11: benign double-fire — same hook, same input, twice → same decision ─
aa="$repo_root/scripts/hooks/auto-approve-safe-bash.sh"
brs="$repo_root/scripts/hooks/block-read-secrets.sh"

# allow-case (auto-approve a safe read): identical stdout both passes.
ALLOW_IN='{"tool_name":"Bash","tool_input":{"command":"cat notes.txt"}}'
o1=$(printf '%s' "$ALLOW_IN" | bash "$aa" 2>/dev/null); r1=$?
o2=$(printf '%s' "$ALLOW_IN" | bash "$aa" 2>/dev/null); r2=$?
check "SC11 allow-case rc stable"   "$r1" "$r2"
check "SC11 allow-case output stable" "$o1" "$o2"
printf '%s' "$o1" | grep -q '"permissionDecision"[: ]*"allow"' && check "SC11 allow-case actually allows" yes yes || check "SC11 allow-case actually allows" no yes

# block-case (read a .env secret): identical exit (block=2) both passes.
BLOCK_IN='{"tool_name":"Read","tool_input":{"file_path":"/somewhere/.env"}}'
printf '%s' "$BLOCK_IN" | bash "$brs" >/dev/null 2>&1; b1=$?
printf '%s' "$BLOCK_IN" | bash "$brs" >/dev/null 2>&1; b2=$?
check "SC11 block-case rc stable" "$b1" "$b2"
check "SC11 block-case actually blocks (exit 2)" "$b1" "2"

rm -rf "$td"
[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
