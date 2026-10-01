#!/usr/bin/env bash
# scripts/usage/test-usage.sh -- fixture test for usage-compute.sh and
# usage-read.sh (HIMMEL-3994). Synthetic transcripts + a synthetic CR ledger +
# a stub gh under mktemp -d; never a real transcript.
# Platform guard (gitbash-only): pure bash 3.2-safe + jq, no .ps1 twin needed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPUTE="$HERE/usage-compute.sh"
READ="$HERE/usage-read.sh"
BANK="$HERE/../lib/bank-attribution.sh"

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-usage.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
PROJ="$ROOT/projects"; SLUG="$PROJ/slug"; mkdir -p "$SLUG"
FAIL=0
check() { # label expected actual
  if [ "$2" != "$3" ]; then echo "FAIL: $1 -- expected [$2] got [$3]" >&2; FAIL=1; else echo "ok: $1"; fi
}

row() { # sid sidechain ts req in cr cc out
  printf '{"type":"assistant","sessionId":"%s","isSidechain":%s,"timestamp":"%s","requestId":"%s","message":{"usage":{"input_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s,"output_tokens":%s}}}\n' "$@"
}
LEG="aaaaaaaa-0000-0000-0000-000000000001"
CON="bbbbbbbb-0000-0000-0000-000000000002"
JDG="cccccccc-0000-0000-0000-000000000003"
{
  echo '{"type":"custom-title","customTitle":"HIMMEL-9001-N1-thing","sessionId":"'$LEG'"}'
  row $LEG false 2026-01-01T00:00:02.000Z r1 10 100 5 20
  row $LEG false 2026-01-01T00:00:02.000Z r1 10 100 5 20
  row $LEG false 2026-01-01T00:00:03.000Z r2 11 101 6 21
  echo '{"type":"user","sessionId":"'$LEG'","message":{"content":"subagent prompt SECRETSENTINEL"}}'
} > "$SLUG/$LEG.jsonl"
mkdir -p "$SLUG/$LEG/subagents"
row $LEG true 2026-01-01T00:00:04.000Z s1 50 500 25 100 > "$SLUG/$LEG/subagents/agent-1.jsonl"
{
  echo '{"type":"custom-title","customTitle":"HIMMEL-nextleg-console","sessionId":"'$CON'"}'
  row $CON false 2026-01-01T00:00:02.000Z c1 3 30 2 7
} > "$SLUG/$CON.jsonl"
{
  echo '{"type":"custom-title","customTitle":"HIMMEL-9001-judge-call","sessionId":"'$JDG'"}'
  row $JDG false 2026-01-01T00:00:02.000Z j1 4 40 3 8
} > "$SLUG/$JDG.jsonl"

LEDGER="$ROOT/ledger.jsonl"
cat > "$LEDGER" <<'L'
{"kind":"finding","ts":"2026-01-01T01:00:00Z","branch":"feat/himmel-9001-thing","head":"h1","model":"codex","finding_id":"codex-1","severity":"imp","verdict":""}
{"kind":"finding","ts":"2026-01-01T01:00:00Z","branch":"feat/himmel-9001-thing","head":"h1","model":"codex","finding_id":"codex-2","severity":"sug","verdict":"agreed"}
{"kind":"amend","ts":"2026-01-01T01:05:00Z","branch":"","target_head":"h1","finding_id":"codex-1","set":{"verdict":"disproved"}}
{"kind":"avail","ts":"2026-01-01T02:00:00Z","branch":"feat/himmel-9001-thing","head":"h2","model":"codex","status":"ok"}
{"kind":"usage","ts":"2026-01-01T01:00:00Z","branch":"feat/himmel-9001-thing","head":"h1","model":"codex","est_total_tokens":1000,"estimated":true}
{"kind":"usage","ts":"2026-01-01T02:00:00Z","branch":"feat/himmel-9001-thing","head":"h2","model":"codex","est_total_tokens":500,"estimated":true}
{"kind":"avail","ts":"2026-01-01T02:00:00Z","branch":"feat/himmel-9002-other","head":"h9","model":"codex","status":"ok"}
L

mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/gh" <<'G'
#!/usr/bin/env bash
case "$*" in
  *"pr list"*) echo '[{"number":77,"title":"feat: [HIMMEL-9001] thing","headRefName":"feat/himmel-9001-thing","createdAt":"2026-01-01T00:00:00Z","mergedAt":"2026-01-01T03:00:00Z","state":"MERGED"},{"number":78,"title":"other [HIMMEL-9002]","headRefName":"x","createdAt":"2026-01-01T00:00:00Z","mergedAt":null,"state":"OPEN"}]' ;;
  *"run list"*) echo '[{"startedAt":"2026-01-01T00:10:00Z","updatedAt":"2026-01-01T00:20:00Z"},{"startedAt":"2026-01-01T01:00:00Z","updatedAt":"2026-01-01T01:05:00Z"}]' ;;
  *) exit 1 ;;
esac
G
chmod +x "$ROOT/bin/gh"

STORE="$ROOT/store"
run() { bash "$COMPUTE" --projects "$PROJ" --ledger "$LEDGER" --gh "$ROOT/bin/gh" --range HIMMEL-9001..HIMMEL-9002 "$@"; }

# 1. per-session totals equal bank-attribution.sh on the same fixture
BA="$(bash "$BANK" "$PROJ")"
ba_leg="$(printf '%s\n' "$BA" | grep -F '| HIMMEL-9001-N1-thing | slug' | awk -F' [|] ' '{print $4"/"$5"/"$6"/"$7"/"$8}')"
OUT="$(run --print)"
rec="$(printf '%s\n' "$OUT" | jq -c 'select(.ticket=="HIMMEL-9001")')"
rec_leg="$(printf '%s' "$rec" | jq -r '.legs[]|select(.name=="HIMMEL-9001-N1-thing")|"\(.turns)/\(.input)/\(.cache_read)/\(.cache_create)/\(.output)"')"
check "leg totals match bank-attribution" "$ba_leg" "$rec_leg"
check "leg totals literal (dedup'd turn)" "2/21/201/11/41" "$rec_leg"
check "subagent tokens carried" "1/50/500/25/100" "$(printf '%s' "$rec" | jq -r '.legs[]|select(.name=="HIMMEL-9001-N1-thing")|"\(.sub_turns)/\(.sub_input)/\(.sub_cache_read)/\(.sub_cache_create)/\(.sub_output)"')"

# 2. separate fields per kind
check "judge kind separate" "judge" "$(printf '%s' "$rec" | jq -r '.legs[]|select(.name=="HIMMEL-9001-judge-call").kind')"
check "totals.leg has no judge" "21" "$(printf '%s' "$rec" | jq -r '.totals.leg.input')"
check "totals.judge" "4" "$(printf '%s' "$rec" | jq -r '.totals.judge.input')"
check "console not attributed to ticket" "0" "$(printf '%s' "$rec" | jq -r '.totals.console.input')"
check "console pool record, unallocated" "3" "$(printf '%s\n' "$OUT" | jq -r 'select(.ticket=="_console")|.totals.console.input')"

# 3. CR + CI + PR
check "cr rounds" "2" "$(printf '%s' "$rec" | jq -r '.cr.rounds')"
check "cr findings by verdict" '{"agreed":1,"disproved":1}' "$(printf '%s' "$rec" | jq -c '.cr.findings')"
check "cr est tokens" "1500" "$(printf '%s' "$rec" | jq -r '.cr.est_tokens')"
check "ci secs" "900" "$(printf '%s' "$rec" | jq -r '.ci.secs')"
check "pr merged outcome" "MERGED" "$(printf '%s' "$rec" | jq -r '.pr.outcome')"
check "pr only title-matched" "[77]" "$(printf '%s' "$rec" | jq -c '.pr.numbers')"

# 3b. a failed gh run list is null ci, never zero; unavailable avail is not a round
sed 's/\*"run list"\*) echo .*;;/*"run list"*) exit 1 ;;/' "$ROOT/bin/gh" > "$ROOT/bin/gh-nociruns"; chmod +x "$ROOT/bin/gh-nociruns"
check "failed run list gives null ci" "null" "$(run --print --gh "$ROOT/bin/gh-nociruns" | jq -c 'select(.ticket=="HIMMEL-9001")|.ci')"
sed 's/feat: \[HIMMEL-9001\] thing/HIMMEL-9001: thing/' "$ROOT/bin/gh" > "$ROOT/bin/gh-unbracketed"; chmod +x "$ROOT/bin/gh-unbracketed"
check "unbracketed title still joins" "[77]" "$(run --print --gh "$ROOT/bin/gh-unbracketed" | jq -c 'select(.ticket=="HIMMEL-9001")|.pr.numbers')"
sed 's/"startedAt":"2026-01-01T00:10:00Z"/"startedAt":"garbage"/' "$ROOT/bin/gh" > "$ROOT/bin/gh-badts"; chmod +x "$ROOT/bin/gh-badts"
check "bad run timestamp gives null ci" "null" "$(run --print --gh "$ROOT/bin/gh-badts" | jq -c 'select(.ticket=="HIMMEL-9001")|.ci')"
printf '%s\n' '{"kind":"avail","ts":"2026-01-01T03:00:00Z","branch":"feat/himmel-9001-thing","head":"h3","model":"codex","status":"unavailable"}' >> "$LEDGER"
check "unavailable avail not a round" "2" "$(run --print | jq -r 'select(.ticket=="HIMMEL-9001")|.cr.rounds')"

# 4. idempotency: byte-identical print + store unchanged on rerun
OUT2="$(run --print)"
check "print byte-identical" "$OUT" "$OUT2"
run --store "$STORE" >/dev/null
h1="$(cksum < "$STORE/records.jsonl")"
run --store "$STORE" >/dev/null
check "store byte-identical on rerun" "$h1" "$(cksum < "$STORE/records.jsonl")"

# 5. append-only: changed input appends a new version, old lines kept
before="$(wc -l < "$STORE/records.jsonl" | tr -d ' ')"
row $LEG false 2026-01-01T00:00:09.000Z r3 1 1 1 1 >> "$SLUG/$LEG.jsonl"
run --store "$STORE" >/dev/null
after="$(wc -l < "$STORE/records.jsonl" | tr -d ' ')"
check "changed input appends one version" "$((before + 1))" "$after"

# 6. consumer read test (no JSONL touched)
check "read latest turns" "3" "$(bash "$READ" --store "$STORE" --ticket HIMMEL-9001 | jq -r '.legs[]|select(.name=="HIMMEL-9001-N1-thing").turns')"
check "read all versions" "2" "$(bash "$READ" --store "$STORE" --ticket HIMMEL-9001 --all | wc -l | tr -d ' ')"

# 6b. two concurrent runs on a fresh store publish ONE record per ticket
# (the lock spans compute+append, so the second run sees the first's line)
STORE2="$ROOT/store2"
run --store "$STORE2" >/dev/null & p1=$!
run --store "$STORE2" >/dev/null & p2=$!
wait "$p1"; wait "$p2"
check "concurrent runs: one record per ticket" "1" "$(jq -r 'select(.ticket=="HIMMEL-9001")|.ticket' "$STORE2/records.jsonl" | wc -l | tr -d ' ')"
check "concurrent runs: lock released" "no" "$([ -d "$STORE2/.lock" ] && echo yes || echo no)"

# 7. no message text anywhere in the output
check "no transcript text leaks" "0" "$(grep -c 'SECRETSENTINEL' "$STORE/records.jsonl" || true)"

if [ "$FAIL" -eq 0 ]; then echo "PASS"; else echo "FAILED" >&2; exit 1; fi
