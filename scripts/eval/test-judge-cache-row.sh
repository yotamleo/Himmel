#!/usr/bin/env bash
# test-judge-cache-row.sh — judge-cache-row.sh ledger row + the judge agent
# frontmatter (HIMMEL-5180). Fixture transcripts only; nothing real is read.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
ROW="$HERE/judge-cache-row.sh"
T="$(mktemp -d)" || exit 1
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
eq() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$3" "$2"; fi; }

# Three distinct messages; m1 appears twice (one row per content block) and
# must count once. Gaps: 10 s, then 400 s (a cold re-prime on a 5m run).
a="$T/agent-a.jsonl"
cat > "$a" <<'EOF'
{"type":"assistant","timestamp":"2026-10-10T10:00:00.000Z","message":{"id":"m1","usage":{"cache_creation_input_tokens":100,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":0}}}}
{"type":"assistant","timestamp":"2026-10-10T10:00:00.500Z","message":{"id":"m1","usage":{"cache_creation_input_tokens":100,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":0}}}}
{"type":"assistant","timestamp":"2026-10-10T10:00:10.000Z","message":{"id":"m2","usage":{"cache_read_input_tokens":100,"cache_creation":{"ephemeral_5m_input_tokens":20,"ephemeral_1h_input_tokens":0}}}}
{"type":"assistant","timestamp":"2026-10-10T10:06:50.000Z","message":{"id":"m3","usage":{"cache_read_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":120,"ephemeral_1h_input_tokens":0}}}}
EOF
printf '{"agentType":"Explore","description":"Judge ja"}\n' > "$T/agent-a.meta.json"

got=$(bash "$ROW" "$a")
eq "5m row dedupes by message id and counts the idle gap" "$got" \
   "$(printf 'Judge ja\tExplore\t\t5m\t410\t3\t240\t0\t100\t400\t1')"

# 1h write present -> ttl 1h; --header + --ledger append
b="$T/agent-b.jsonl"
cat > "$b" <<'EOF'
{"type":"assistant","timestamp":"2026-10-10T10:00:00.000Z","message":{"id":"x1","usage":{"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":50}}}}
EOF
printf '{"agentType":"console-judge-ro","description":"Judge jb"}\n' > "$T/agent-b.meta.json"
bash "$ROW" --header --ledger "$T/ledger.tsv" "$b" > /dev/null
eq "ledger has header + one row" "$(wc -l < "$T/ledger.tsv" | tr -d ' ')" "2"
eq "1h write reported as ttl 1h" "$(sed -n 2p "$T/ledger.tsv" | cut -f2,4)" "$(printf 'console-judge-ro\t1h')"

bash "$ROW" >/dev/null 2>&1; eq "no transcript is rc 2" "$?" "2"

# Frontmatter of the two judge agents: same TTL, ro tool list pinned.
for f in console-judge console-judge-ro; do
    p="$REPO/.claude/agents/$f.md"
    eq "$f cacheTtl nested under experimental" \
       "$(awk '/^---$/{n++} n==1' "$p" | tr -d '\r' | grep -A1 '^experimental:' | tail -1)" "  cacheTtl: 1h"
done
eq "console-judge-ro tools pinned read-only" \
   "$(grep -m1 '^tools:' "$REPO/.claude/agents/console-judge-ro.md")" "tools: Read, Grep, Glob, Bash"

printf 'test-judge-cache-row: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
