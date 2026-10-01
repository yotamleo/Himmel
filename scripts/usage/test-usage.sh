#!/usr/bin/env bash
# scripts/usage/test-usage.sh -- fixture test for usage-compute.sh and
# usage-read.sh (HIMMEL-3994). Synthetic transcripts and a synthetic CR ledger
# only: no real transcript, no network.
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



STORE="$ROOT/store"
run() { bash "$COMPUTE" --projects "$PROJ" --ledger "$LEDGER" --range HIMMEL-9001..HIMMEL-9002 "$@"; }

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

# 3. CR
check "cr rounds" "2" "$(printf '%s' "$rec" | jq -r '.cr.rounds')"
check "cr findings by verdict" '{"agreed":1,"disproved":1}' "$(printf '%s' "$rec" | jq -c '.cr.findings')"
check "cr est tokens" "1500" "$(printf '%s' "$rec" | jq -r '.cr.est_tokens')"

# explicit inputs that are missing fail closed and write nothing
FC="$ROOT/store-fc"
rc=0; bash "$COMPUTE" --projects "$PROJ" --ledger "$ROOT/no-such-ledger" --range HIMMEL-9001..HIMMEL-9002 --store "$FC" >/dev/null 2>&1 || rc=$?
check "missing explicit ledger fails closed" "1" "$rc"
rc=0; bash "$COMPUTE" --projects "$ROOT/no-such-dir" --ledger "$LEDGER" --range HIMMEL-9001..HIMMEL-9002 --store "$FC" >/dev/null 2>&1 || rc=$?
check "missing explicit projects fails closed" "1" "$rc"
check "fail-closed runs wrote nothing" "no" "$([ -e "$FC" ] && echo yes || echo no)"
# selector validation: --tickets as strict as --range, nothing-matches and conflicts fail closed
sel() { rc=0; bash "$COMPUTE" --projects "$PROJ" --ledger "$LEDGER" --store "$FC" "$@" >/dev/null 2>&1 || rc=$?; echo "$rc"; }
check "--tickets bad key fails" "1" "$(sel --tickets 'not a key')"
check "--tickets empty element fails" "1" "$(sel --tickets 'HIMMEL-9001,')"
check "--tickets matching nothing fails" "1" "$(sel --tickets HIMMEL-7777)"
check "--tickets valid still works" "0" "$(sel --tickets HIMMEL-9001 --print)"
check "--since empty fails" "1" "$(sel --since '' --print)"
check "--range with --tickets fails" "1" "$(sel --range HIMMEL-9001..HIMMEL-9002 --tickets HIMMEL-9001 --print)"
# every value-taking flag: empty or missing value fails closed
for flag in --projects --ledger --store --range --tickets --since; do
  check "$flag empty value fails" "1" "$(sel "$flag" '' --print)"
  check "$flag missing value fails" "1" "$(sel "$flag")"
done

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

# 8. PR/CI join (HIMMEL-4030): a stub gh, never the network. Fixtures are files
# the stub prints; GHFAIL / GHWANT_REPO make it fail like auth or a wrong repo.
STUB="$ROOT/stub"; mkdir -p "$STUB" "$ROOT/dir with space"
cat > "$STUB/gh" <<'STUBEOF'
#!/usr/bin/env bash
# logs every call; fails on GHFAIL or when -R is not GHWANT_REPO
printf '%s\n' "$*" >> "$GHLOG"
[ -z "${GHFAIL:-}" ] || { echo "gh: auth error" >&2; exit 4; }
repo=""; prev=""; search=""; branch=""
for a in "$@"; do
  [ "$prev" != "-R" ] || repo="$a"
  [ "$prev" != "--search" ] || search="$a"
  [ "$prev" != "--branch" ] || branch="$a"
  prev="$a"
done
[ "$repo" = "${GHWANT_REPO:-o/r}" ] || { echo "gh: repository not found: $repo" >&2; exit 1; }
case "$1 $2" in
  "pr list")  f="$GHFIX/pr-${search%% *}.json" ;;
  "run list") f="$GHFIX/run-$(printf '%s' "$branch" | tr '/' '_').json" ;;
  *) echo "stub: unexpected $*" >&2; exit 2 ;;
esac
if [ -f "$f" ]; then cat "$f"; else echo '[]'; fi
STUBEOF
chmod +x "$STUB/gh"; cp "$STUB/gh" "$ROOT/dir with space/gh"
export GHLOG="$ROOT/gh.log"; : > "$GHLOG"
GHFIX="$ROOT/fix"; export GHFIX; mkdir -p "$GHFIX"
cat > "$GHFIX/pr-HIMMEL-9001.json" <<'J'
[{"number":12,"state":"CLOSED","title":"[HIMMEL-9001] retry","headRefName":"feat/himmel-9001-retry"},
 {"number":11,"state":"MERGED","title":"[HIMMEL-9001] thing","headRefName":"feat/himmel-9001-thing"},
 {"number":13,"state":"OPEN","title":"[HIMMEL-90019] decoy","headRefName":"feat/himmel-90019-decoy"}]
J
cat > "$GHFIX/run-feat_himmel-9001-thing.json" <<'J'
[{"databaseId":1,"status":"completed","conclusion":"success","createdAt":"2026-01-01T00:00:00Z","startedAt":"2026-01-01T00:00:10Z","updatedAt":"2026-01-01T00:01:10Z"},
 {"databaseId":2,"status":"completed","conclusion":"failure","createdAt":"2026-01-01T00:02:00Z","startedAt":"2026-01-01T00:02:00Z","updatedAt":"2026-01-01T00:02:30Z"},
 {"databaseId":3,"status":"in_progress","conclusion":"","createdAt":"2026-01-01T00:03:00Z","startedAt":"2026-01-01T00:03:00Z","updatedAt":"2026-01-01T00:03:05Z"}]
J
cat > "$GHFIX/run-feat_himmel-9001-retry.json" <<'J'
[{"databaseId":1,"status":"completed","conclusion":"success","createdAt":"2026-01-01T00:00:00Z","startedAt":"2026-01-01T00:00:10Z","updatedAt":"2026-01-01T00:01:10Z"}]
J
jrun() { run --repo o/r --gh "$STUB/gh" "$@"; }
J="$(jrun --print)"
jrec="$(printf '%s\n' "$J" | jq -c 'select(.ticket=="HIMMEL-9001")')"
check "pr facts (decoy HIMMEL-90019 excluded, numbers sorted)" '{"closed":1,"merged":1,"numbers":[11,12],"open":0,"state":"found"}' "$(printf '%s' "$jrec" | jq -cS .pr)"
check "ci facts (runs deduped by id, secs from startedAt, in_progress not summed)" '{"basis":"startedAt","completed":2,"runs":3,"secs":90,"state":"found"}' "$(printf '%s' "$jrec" | jq -cS .ci)"
check "no PR: pr is none" '{"state":"none"}' "$(printf '%s\n' "$J" | jq -c 'select(.ticket=="HIMMEL-9002")|.pr')"
check "no PR: ci is no-pr, not zero runs" '{"state":"no-pr"}' "$(printf '%s\n' "$J" | jq -c 'select(.ticket=="HIMMEL-9002")|.ci')"
check "pseudo-tickets carry no pr/ci" "null" "$(printf '%s\n' "$J" | jq -c 'select(.ticket=="_console")|.pr')"
check "no --repo: records carry no pr/ci" "null/null" "$(run --print | jq -r 'select(.ticket=="HIMMEL-9001")|"\(.pr)/\(.ci)"')"
mkdir -p "$ROOT/fix2"
echo '[{"number":5,"state":"OPEN","title":"HIMMEL-9001 x","headRefName":"b"}]' > "$ROOT/fix2/pr-HIMMEL-9001.json"
check "a PR with zero runs is runs:0, not no-pr" '{"basis":"none","completed":0,"runs":0,"secs":0,"state":"found"}' "$(GHFIX="$ROOT/fix2" jrun --print | jq -cS 'select(.ticket=="HIMMEL-9001")|.ci')"
mkdir -p "$ROOT/fix3"
echo '[{"number":6,"state":"OPEN","title":"HIMMEL-9001 y","headRefName":"b"}]' > "$ROOT/fix3/pr-HIMMEL-9001.json"
echo '[{"databaseId":9,"status":"completed","conclusion":"success","createdAt":"2026-01-01T00:00:00Z","startedAt":null,"updatedAt":"2026-01-01T00:00:45Z"}]' > "$ROOT/fix3/run-b.json"
check "missing startedAt falls back to createdAt and says so" '{"basis":"createdAt","completed":1,"runs":1,"secs":45,"state":"found"}' "$(GHFIX="$ROOT/fix3" jrun --print | jq -cS 'select(.ticket=="HIMMEL-9001")|.ci')"
mkdir -p "$ROOT/fix4"
echo '[{"number":7,"state":"OPEN","title":"HIMMEL-9001A decoy","headRefName":"b"}]' > "$ROOT/fix4/pr-HIMMEL-9001.json"
check "a letter after the key is not the key (HIMMEL-9001A)" '{"state":"none"}' "$(GHFIX="$ROOT/fix4" jrun --print | jq -cS 'select(.ticket=="HIMMEL-9001")|.pr')"
mkdir -p "$ROOT/fix5"
echo '[{"number":8,"state":"OPEN","title":"HIMMEL-9001 z","headRefName":"b"}]' > "$ROOT/fix5/pr-HIMMEL-9001.json"
echo '[{"databaseId":20,"status":"completed","conclusion":"success","createdAt":"2026-01-01T00:00:00Z","startedAt":"2026-01-01T00:01:00Z","updatedAt":"2026-01-01T00:00:50Z"},
 {"databaseId":21,"status":"completed","conclusion":"success","createdAt":"2026-01-01T00:00:00Z","startedAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:05:00Z"}]' > "$ROOT/fix5/run-b.json"

# the join fails closed: a failing gh writes nothing and leaves prior versions alone
SJ="$ROOT/store-join"
jrun --store "$SJ" >/dev/null
hj="$(cksum < "$SJ/records.jsonl")"
row $LEG false 2026-01-01T00:00:20.000Z r4 1 1 1 1 >> "$SLUG/$LEG.jsonl"   # input changed: a good run WOULD append
frc() { rc=0; "$@" >/dev/null 2>&1 || rc=$?; echo "$rc"; }
check "gh auth failure exits non-zero" "1" "$(GHFAIL=1 frc jrun --store "$SJ")"
check "wrong repo (gh error) exits non-zero" "1" "$(GHWANT_REPO=x/y frc jrun --store "$SJ")"
check "missing gh exits non-zero" "1" "$(frc run --repo o/r --gh "$ROOT/no-such-gh" --store "$SJ")"
check "one negative run duration aborts even when the sum is positive" "1" "$(GHFIX="$ROOT/fix5" frc jrun --store "$SJ")"
check "gh failure left the store byte-identical" "$hj" "$(cksum < "$SJ/records.jsonl")"
check "failed run released the lock" "no" "$([ -d "$SJ/.lock" ] && echo yes || echo no)"
cp -R "$GHFIX" "$ROOT/fix-bad"
echo 'not json' > "$ROOT/fix-bad/pr-HIMMEL-9001.json"
check "malformed pr JSON aborts" "1" "$(GHFIX="$ROOT/fix-bad" frc jrun --store "$SJ")"
echo '{"a":1}' > "$ROOT/fix-bad/pr-HIMMEL-9001.json"
check "non-array pr JSON aborts" "1" "$(GHFIX="$ROOT/fix-bad" frc jrun --store "$SJ")"
cp "$GHFIX/pr-HIMMEL-9001.json" "$ROOT/fix-bad/pr-HIMMEL-9001.json"
echo '[{"databaseId":1}]' > "$ROOT/fix-bad/run-feat_himmel-9001-thing.json"
check "run JSON missing fields aborts" "1" "$(GHFIX="$ROOT/fix-bad" frc jrun --store "$SJ")"
check "every abort left the store byte-identical" "$hj" "$(cksum < "$SJ/records.jsonl")"
SF="$ROOT/store-fresh"
check "failed run on a fresh store" "1" "$(GHFAIL=1 frc jrun --store "$SF")"
check "failed fresh run stored nothing" "no" "$([ -e "$SF/records.jsonl" ] && echo yes || echo no)"
check "good run still appends after the aborts" "0" "$(frc jrun --store "$SJ")"

# a --gh path with a space works; the repo is pinned whatever the cwd
: > "$GHLOG"
check "--gh path with a space works" "0" "$(frc run --repo o/r --gh "$ROOT/dir with space/gh" --print)"
mkdir -p "$ROOT/elsewhere"
(cd "$ROOT/elsewhere" && jrun --print >/dev/null)
check "gh was called" "yes" "$([ -s "$GHLOG" ] && echo yes || echo no)"
check "every gh call pinned -R o/r" "0" "$(grep -vcE '^(pr|run) list -R o/r ' "$GHLOG" || true)"
# join flags are validated
check "--gh without --repo fails" "1" "$(frc run --gh "$STUB/gh" --print)"
check "--repo malformed fails" "1" "$(frc run --repo 'not a repo' --print)"
check "--repo empty value fails" "1" "$(frc run --repo '' --print)"

# usage-read.sh waits on the store lock (no torn read) and releases it
mkdir "$SJ/.lock"
bash "$READ" --store "$SJ" > "$ROOT/read.out" 2>&1 & rp=$!
sleep 1
check "reader blocks while a writer holds the lock" "yes" "$(kill -0 "$rp" 2>/dev/null && echo yes || echo no)"
rmdir "$SJ/.lock"
rc=0; wait "$rp" || rc=$?
check "reader proceeds once the lock drops" "0" "$rc"
check "reader released its own lock" "no" "$([ -d "$SJ/.lock" ] && echo yes || echo no)"

if [ "$FAIL" -eq 0 ]; then echo "PASS"; else echo "FAILED" >&2; exit 1; fi
