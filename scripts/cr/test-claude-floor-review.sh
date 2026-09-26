#!/usr/bin/env bash
# test-claude-floor-review.sh — HIMMEL-3107: the context-free CR floor reviewer.
# A fake claude (HIMMEL_CLAUDE_BIN) records its argv, cwd and stdin, so the
# suite pins that the reviewer invocation carries NO session context, that it
# refuses to spend when the floor could not unlock, and that it stamps the
# provenance artifact + ledger rows the gate reads.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SUT="$REPO/scripts/cr/claude-floor-review.sh"
AGENT_MD="$REPO/marketplace/plugins/pr-review-toolkit-himmel/agents/code-reviewer.md"
PASS=0; FAIL=0
W="$(mktemp -d -t claude-floor-test.XXXXXX)" || { echo "FAIL - mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$W"' EXIT
ok() { PASS=$((PASS+1)); echo "ok - $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL - $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$2' got '$3'"; fi; }
has() { if grep -qF -- "$2" "$3" 2>/dev/null; then ok "$1"; else bad "$1: '$2' not in $3"; fi; }
hasnt() { if grep -qE -- "$2" "$3" 2>/dev/null; then bad "$1: /$2/ found in $3"; else ok "$1"; fi; }

# HIMMEL-3220: a throwaway HOME and floor key dir — this suite never touches
# the real ~/.himmel/cr-floor-key.
export HOME="$W/home" CR_FLOOR_KEY_DIR="$W/keys"
mkdir -p "$HOME"
# HIMMEL-1712: bank-preflight distrusts a cache whose account doesn't match
# the current identity — synthesize one so this fixture still verdicts PROCEED.
printf '%s' '{"oauthAccount":{"accountUuid":"uuid-claude-floor-review-test"}}' > "$HOME/.claude.json"
# shellcheck source=../lib/usage-cache-identity.sh
# shellcheck disable=SC1091
. "$REPO/scripts/lib/usage-cache-identity.sh"
ACCT="$(current_account_hash)"

# Bank preflight + registry stubs (same shape as scripts/lib/test-claude-headless.sh).
printf '{"account":"%s","five_hour":{"utilization":10},"seven_day":{"utilization":20},"primaries_refreshed_at":%s}\n' "$ACCT" "$(date +%s)" > "$W/bank.json"
export CADENCE_BANK_CACHE="$W/bank.json" CADENCE_BANK_SKIP_REFRESH=1 CADENCE_BANK_LEDGER="$W/bank-ledger.jsonl"
printf '%s\n' '#!/usr/bin/env bash' 'true' > "$W/no-fleet.sh"; chmod +x "$W/no-fleet.sh"
export FLEET_PS_CMD="$W/no-fleet.sh" HIMMEL_REGISTRY_DIR="$W/registry"
FLOOR_MJS="$REPO/scripts/cr/claude-floor.mjs"
node "$FLOOR_MJS" init-key > "$W/init.out" 2>&1 || { echo "FAIL - floor key init failed: $(cat "$W/init.out")" >&2; exit 1; }

# The fake claude: records argv / cwd / stdin / whether cwd has a .git, then
# writes FAKE_OUT (verbatim) to .cr-floor-review.json and prints FAKE_ENV.
FAKE="$W/fake-claude.sh"
cat > "$FAKE" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$REC/argv"
pwd > "$REC/cwd"
cat > "$REC/stdin"
[ -e .git ] && echo yes > "$REC/has-git" || echo no > "$REC/has-git"
ls -A > "$REC/ls"
for f in f.txt g.txt x.sh; do [ -f "$f" ] && cp "$f" "$REC/$f"; done
[ -x x.sh ] && echo yes > "$REC/x-exec"
if [ -L link ]; then echo symlink > "$REC/link-kind"; elif [ -f link ]; then echo file > "$REC/link-kind"; cp link "$REC/link"; fi
prev=""; for a in "$@"; do [ "$prev" = "--system-prompt-file" ] && cp "$a" "$REC/system.md"; prev="$a"; done
[ -z "${FAKE_OUT:-}" ] || printf '%s' "$FAKE_OUT" > .cr-floor-review.json
# Default in a variable: inside ${FAKE_ENV:-...} the JSON's first } would close
# the expansion and append a stray } to a SET FAKE_ENV.
env_default='{"is_error":false,"session_id":"fake-sess-1","permission_denials":[],"num_turns":3}'
printf '%s\n' "${FAKE_ENV:-$env_default}"
EOF
chmod +x "$FAKE"
export HIMMEL_CLAUDE_BIN="$FAKE"
# The operator opt-in the gate requires. Non-empty, so the primary's .env never
# overrides a case (load_dotenv lets a non-empty process value win).
export CR_REQUIRE_CROSS_MODEL=1 CR_FLOOR_FALLBACK=claude-only

# mk_repo — main + one commit on feat/himmel-9-x; sets R and HEAD_SHA.
mk_repo() {
    R="$W/repo.$1"; rm -rf "$R"; mkdir -p "$R"
    ( cd "$R" && git init -q -b main . && git config user.email t@t.t && git config user.name t &&
      echo hi > f.txt && git add f.txt && git commit -qm base &&
      git init -q --bare .git/origin.git && git remote add origin .git/origin.git && git push -q origin main &&
      git checkout -qb feat/himmel-9-x && echo more >> f.txt && git commit -qam work ) >/dev/null 2>&1
    HEAD_SHA=$(git -C "$R" rev-parse HEAD)
    export CR_LEDGER="$R/.git/cr-critic-scores.jsonl"; : > "$CR_LEDGER"
    REC="$W/rec.$1"; rm -rf "$REC"; mkdir -p "$REC"; export REC
}
row() { printf '{"kind":"avail","head":"%s","model":"%s","status":"%s","reason":"%s"}\n' "$HEAD_SHA" "$1" "$2" "${3:-}" >> "$CR_LEDGER"; }
run_sut() { RC=0; ( cd "$R" && bash "$SUT" --branch feat/himmel-9-x --base main ) > "$W/out" 2>&1 || RC=$?; }

# 1. Eligible (CodeRabbit rate-limited + codex quota-5h): reviewed, recorded.
mk_repo 1; row coderabbit unavailable rate-limit; row codex unavailable quota-5h
export FAKE_OUT='{"findings":[{"severity":"imp","file":"f.txt","line":2,"text":"more is vague"}]}'
run_sut
check "1 eligible run exits 0" 0 "$RC"
# -- no session context reaches the reviewer --
check "1 reviewer cwd has no .git (a snapshot, not the worktree)" no "$(cat "$REC/has-git" 2>/dev/null)"
case "$(cat "$REC/cwd" 2>/dev/null)" in "$R"|"$R"/*) bad "1 reviewer cwd must not be inside the repo" ;; *) ok "1 reviewer cwd is outside the repo" ;; esac
has "1 --safe-mode (no CLAUDE.md/memory/skills/plugins/hooks)" "--safe-mode" "$REC/argv"
has "1 --strict-mcp-config (no MCP servers)" "--strict-mcp-config" "$REC/argv"
has "1 --no-session-persistence" "--no-session-persistence" "$REC/argv"
has "1 tools restricted to Read,Grep,Glob,Write" "Read,Grep,Glob,Write" "$REC/argv"
has "1 explicit acceptEdits permission mode" "acceptEdits" "$REC/argv"
has "1 --output-format json" "json" "$REC/argv"
hasnt "1 never resumes/continues a session" '^(--resume|-r|--continue|-c|--session-id|--fork-session)$' "$REC/argv"
hasnt "1 never bypassPermissions" 'bypassPermissions' "$REC/argv"
check "1 model from the agent frontmatter" opus "$(grep -A1 -x -- '--model' "$REC/argv" | tail -1)"
# stdin = the fixed header + the diff, nothing else
( cd "$R" && git diff --no-color --no-ext-diff main...HEAD ) > "$W/expect.diff"
tail -n +3 "$REC/stdin" > "$W/stdin.diff"
if cmp -s "$W/expect.diff" "$W/stdin.diff"; then ok "1 prompt body is exactly the diff"; else bad "1 prompt body is exactly the diff"; fi
check "1 prompt header names only the diff range" "Review this diff (" "$(head -1 "$REC/stdin" | cut -c1-18)"
# system prompt = the plugin's reviewer body verbatim, frontmatter stripped
awk 'NR==1 && $0=="---" {fm=1; next} fm && $0=="---" {fm=0; next} !fm' "$AGENT_MD" > "$W/agent-body.md"
if head -c "$(wc -c < "$W/agent-body.md")" "$REC/system.md" | cmp -s - "$W/agent-body.md"; then
    ok "1 system prompt starts with the reviewer agent body verbatim"; else bad "1 system prompt starts with the reviewer agent body verbatim"; fi
hasnt "1 system prompt carries no agent frontmatter" '^name: code-reviewer' "$REC/system.md"
# -- provenance + ledger --
ART="$R/.git/cr-floor/$HEAD_SHA.json"
check "1 artifact head" "$HEAD_SHA" "$(jq -r .head "$ART" 2>/dev/null)"
check "1 artifact diff hash = the gate's recompute" "$(git -C "$R" hash-object --stdin < "$W/expect.diff")" "$(jq -r .diff_hash "$ART" 2>/dev/null)"
check "1 artifact session id from the envelope" fake-sess-1 "$(jq -r .session_id "$ART" 2>/dev/null)"
check "1 artifact same_model/context_free" "true true" "$(jq -r '"\(.same_model) \(.context_free)"' "$ART" 2>/dev/null)"
check "1 artifact unlocked_by" "coderabbit(reason=rate-limit) codex(reason=quota-5h)" "$(jq -r '.unlocked_by|join(" ")' "$ART" 2>/dev/null)"
check "1 ledger floor ok row" 1 "$(jq -c 'select(.kind=="avail" and .model=="claude-floor" and .status=="ok")' "$CR_LEDGER" | wc -l | tr -d ' ')"
has "1 ledger row records same-model + context-free + unlocking lanes" "same-model context-free session=fake-sess-1 unlocked_by=coderabbit(reason=rate-limit) codex(reason=quota-5h)" "$CR_LEDGER"
check "1 finding recorded unadjudicated" '"claude-floor-1" "imp" ""' "$(jq -r 'select(.kind=="finding") | "\"\(.finding_id)\" \"\(.severity)\" \"\(.verdict)\""' "$CR_LEDGER")"
has "1 output says NOT cross-model" "NOT COVERED: cross-model review" "$W/out"
# -- HIMMEL-3220: the artifact is stamped and bound to the dispatch row --
check "1 artifact dispatch id = the registry row id" "$(jq -r .id "$HIMMEL_REGISTRY_DIR"/live/*.json 2>/dev/null | head -1)" "$(jq -r .dispatch_id "$ART" 2>/dev/null)"
if node "$FLOOR_MJS" verify "$ART" 2>"$W/verify.err"; then ok "1 artifact stamp verifies"; else bad "1 artifact stamp verifies: $(cat "$W/verify.err")"; fi
jq -c '.session_id = "forged"' "$ART" > "$W/forged.json"
if node "$FLOOR_MJS" verify "$W/forged.json" 2>/dev/null; then bad "1 an edited artifact must not verify"; else ok "1 an edited artifact does not verify"; fi

# 2. RED control: codex auth (401) — refuses, nothing spent.
mk_repo 2; row coderabbit unavailable rate-limit; row codex unavailable auth
run_sut
check "2 auth-faulted lane -> exit 3" 3 "$RC"
check "2 claude never invoked" no "$([ -e "$REC/argv" ] && echo yes || echo no)"
has "2 names the lane" "codex(status=unavailable,reason=auth)" "$W/out"

# 3. vacuous is coderabbit-only.
mk_repo 3; row codex unavailable vacuous
run_sut
check "3 codex reason=vacuous -> exit 3" 3 "$RC"

# 4. A non-Claude critic already responded: no floor needed.
mk_repo 4; row codex ok
run_sut
check "4 cross-model already met -> exit 3" 3 "$RC"
check "4 claude never invoked" no "$([ -e "$REC/argv" ] && echo yes || echo no)"

# 5. Silence with the real (non-empty) panel is not exhaustion.
mk_repo 5
run_sut
check "5 no rows + non-empty panel -> exit 3" 3 "$RC"

# 6. is_error=true -> recorded failure, no provenance.
mk_repo 6; row codex unavailable quota
FAKE_ENV='{"is_error":true,"session_id":"fake-sess-6"}' run_sut
check "6 is_error -> exit 1" 1 "$RC"
check "6 no provenance artifact" no "$([ -e "$R/.git/cr-floor/$HEAD_SHA.json" ] && echo yes || echo no)"
check "6 recorded claude-floor unavailable" 1 "$(jq -c 'select(.model=="claude-floor" and .status=="unavailable")' "$CR_LEDGER" | wc -l | tr -d ' ')"

# 7. malformed reviewer output -> recorded failure (malformed-output).
mk_repo 7; row codex unavailable quota
FAKE_OUT='here are my findings: none' run_sut
check "7 malformed output -> exit 1" 1 "$RC"
check "7 reason malformed-output" malformed-output "$(jq -r 'select(.model=="claude-floor") | .reason' "$CR_LEDGER")"
check "7 no provenance artifact" no "$([ -e "$R/.git/cr-floor/$HEAD_SHA.json" ] && echo yes || echo no)"

# 8. No opt-in: the gate would refuse the floor, so nothing is spent.
mk_repo 8; row codex unavailable quota
CR_FLOOR_FALLBACK=off run_sut
check "8 no claude-only opt-in -> exit 3" 3 "$RC"
check "8 claude never invoked" no "$([ -e "$REC/argv" ] && echo yes || echo no)"
mk_repo 8b; row codex unavailable quota
CR_REQUIRE_CROSS_MODEL=0 run_sut
check "8b no cross-model requirement -> exit 3" 3 "$RC"
check "8b claude never invoked" no "$([ -e "$REC/argv" ] && echo yes || echo no)"

# 9. A TRACKED .cr-floor-review.json in the snapshot never stands in for a
# review the headless session did not write.
mk_repo 9
( cd "$R" && printf '{"findings":[]}' > .cr-floor-review.json && git add .cr-floor-review.json && git commit -qm planted ) >/dev/null 2>&1
HEAD_SHA=$(git -C "$R" rev-parse HEAD); row codex unavailable quota
FAKE_OUT='' run_sut
check "9 planted output file, reviewer wrote nothing -> exit 1" 1 "$RC"
check "9 no provenance artifact" no "$([ -e "$R/.git/cr-floor/$HEAD_SHA.json" ] && echo yes || echo no)"

# 10. An EMPTY session id must be caught, not shifted: tab-separated fields
# collapse under a whitespace IFS, moving the dispatch id into session_id.
mk_repo 10; row codex unavailable quota
FAKE_ENV='{"is_error":false,"session_id":"","permission_denials":[],"num_turns":3}' run_sut
check "10 empty session id -> exit 1" 1 "$RC"
check "10 reason malformed-output" malformed-output "$(jq -r 'select(.model=="claude-floor") | .reason' "$CR_LEDGER")"
check "10 no provenance artifact" no "$([ -e "$R/.git/cr-floor/$HEAD_SHA.json" ] && echo yes || echo no)"

# 11. export-ignore never hides a tracked file from the reviewer's snapshot.
mk_repo 11
( cd "$R" && printf 'f.txt export-ignore\n' > .gitattributes && git add .gitattributes && git commit -qm attrs ) >/dev/null 2>&1
HEAD_SHA=$(git -C "$R" rev-parse HEAD); row codex unavailable quota
run_sut
check "11 export-ignore repo -> exit 0" 0 "$RC"
check "11 snapshot still holds the export-ignored f.txt" yes "$(grep -qx f.txt "$REC/ls" 2>/dev/null && echo yes || echo no)"

# 12. A base that is not on the default branch reviews a partial range the gate
# refuses — so nothing is spent.
mk_repo 12
( cd "$R" && echo tip >> f.txt && git commit -qam tip ) >/dev/null 2>&1
HEAD_SHA=$(git -C "$R" rev-parse HEAD); row codex unavailable quota
RC=0; ( cd "$R" && bash "$SUT" --branch feat/himmel-9-x --base HEAD~1 ) > "$W/out" 2>&1 || RC=$?
check "12 mid-branch base -> exit 3" 3 "$RC"
check "12 claude never invoked" no "$([ -e "$REC/argv" ] && echo yes || echo no)"

# 13. The artifact is published LAST: when recording a repeat review's findings
# fails, the previous artifact stays, so the prior ok row never pairs with
# findings the ledger does not hold.
mk_repo 13; row codex unavailable quota
FAKE_OUT='{"findings":[]}' run_sut
check "13 first (clean) review -> exit 0" 0 "$RC"
chmod a-w "$CR_LEDGER"
run_sut
chmod u+w "$CR_LEDGER"
check "13 repeat review whose ledger write fails -> exit 1" 1 "$RC"
check "13 artifact still carries the first review's findings" 0 "$(jq '.findings | length' "$R/.git/cr-floor/$HEAD_SHA.json" 2>/dev/null)"

# 14. A LOCAL main holding a mid-branch commit is not the default branch: the
# base binds to origin/HEAD (else origin/main) only, so nothing is spent.
mk_repo 14
( cd "$R" && echo tip >> f.txt && git commit -qam tip && git branch -f main HEAD~1 ) >/dev/null 2>&1
HEAD_SHA=$(git -C "$R" rev-parse HEAD); row codex unavailable quota
run_sut
check "14 base on a local main holding a mid-branch commit -> exit 3" 3 "$RC"
check "14 claude never invoked" no "$([ -e "$REC/argv" ] && echo yes || echo no)"

# 15. No remote default branch -> refuse before any spend (fail-closed).
mk_repo 15; row codex unavailable quota
git -C "$R" update-ref -d refs/remotes/origin/main >/dev/null 2>&1
run_sut
check "15 no origin/HEAD or origin/main -> exit 3" 3 "$RC"
check "15 claude never invoked" no "$([ -e "$REC/argv" ] && echo yes || echo no)"

# 16. HIMMEL-3229: the snapshot holds the RAW committed bytes — no smudge
# filter, no eol conversion — plus the exec bit; a symlink is an inert file
# holding its target, so it cannot point the reviewer outside the snapshot.
mk_repo 16
( cd "$R" && git config filter.up.smudge 'tr a-z A-Z' && git config filter.up.clean cat &&
  printf 'f.txt filter=up\ng.txt text eol=crlf\n' > .gitattributes &&
  printf 'one\ntwo\n' > g.txt && printf '#!/bin/sh\n' > x.sh && chmod +x x.sh &&
  git add .gitattributes g.txt x.sh &&
  # The 120000 entry goes through the index, not `ln -s` (which fails on a
  # Git Bash without the symlink privilege).
  link_blob=$(printf 'f.txt' | git hash-object -w --stdin) &&
  git update-index --add --cacheinfo 120000 "$link_blob" link &&
  git commit -qm attrs ) >/dev/null 2>&1
HEAD_SHA=$(git -C "$R" rev-parse HEAD); row codex unavailable quota
run_sut
check "16 smudge/eol repo -> exit 0" 0 "$RC"
if git -C "$R" cat-file blob "$HEAD_SHA:f.txt" | cmp -s - "$REC/f.txt"; then ok "16 smudge-filtered f.txt is the raw blob"; else bad "16 smudge-filtered f.txt is the raw blob (got: $(head -c 40 "$REC/f.txt" 2>/dev/null))"; fi
if git -C "$R" cat-file blob "$HEAD_SHA:g.txt" | cmp -s - "$REC/g.txt"; then ok "16 eol=crlf g.txt is the raw blob"; else bad "16 eol=crlf g.txt is the raw blob"; fi
check "16 exec bit kept" yes "$(cat "$REC/x-exec" 2>/dev/null)"
check "16 symlink is an inert file, not a link" file "$(cat "$REC/link-kind" 2>/dev/null)"
check "16 inert symlink file holds its target" f.txt "$(cat "$REC/link" 2>/dev/null)"

# 17. No floor signing key provisioned -> refuse BEFORE spending, naming the
# operator's init command (fail closed, never an unsigned artifact).
mk_repo 17; row codex unavailable quota
CR_FLOOR_KEY_DIR="$W/no-keys" run_sut
check "17 no signing key -> exit 3" 3 "$RC"
check "17 claude never invoked" no "$([ -e "$REC/argv" ] && echo yes || echo no)"
has "17 names the init command" "claude-floor.mjs init-key" "$W/out"
check "17 no provenance artifact" no "$([ -e "$R/.git/cr-floor/$HEAD_SHA.json" ] && echo yes || echo no)"

# 18. init-key: 0700 dir, 0600 private key, idempotent, never overwrites.
K="$W/k18"
CR_FLOOR_KEY_DIR="$K" node "$FLOOR_MJS" init-key >/dev/null 2>&1
check "18 key dir is 0700" 700 "$(stat -c %a "$K" 2>/dev/null || stat -f %Lp "$K")"
check "18 private key is 0600" 600 "$(stat -c %a "$K/signing.key" 2>/dev/null || stat -f %Lp "$K/signing.key")"
cp "$K/signing.key" "$W/k18.before"
RC=0; CR_FLOOR_KEY_DIR="$K" node "$FLOOR_MJS" init-key > "$W/out" 2>&1 || RC=$?
check "18 second init-key exits 0" 0 "$RC"
if cmp -s "$K/signing.key" "$W/k18.before"; then ok "18 second init-key leaves the key unchanged"; else bad "18 second init-key overwrote the key"; fi
has "18 second init-key says unchanged" "unchanged" "$W/out"

# 19. sign stamps only an artifact its registry row backs (completed,
# is_error=false, same dispatch id and session id).
printf '{"schema":2,"head":"h","base":"b","diff_hash":"d","session_id":"s1","dispatch_id":"d1","findings":[]}\n' > "$W/a19.json"
printf '{"id":"d1","status":"completed","outcome":{"is_error":false,"session_id":"s1"}}\n' > "$W/r19-ok.json"
printf '{"id":"d1","status":"completed","outcome":{"is_error":true,"session_id":"s1"}}\n' > "$W/r19-err.json"
printf '{"id":"d1","status":"completed","outcome":{"is_error":false,"session_id":"s2"}}\n' > "$W/r19-sess.json"
printf '{"id":"d2","status":"completed","outcome":{"is_error":false,"session_id":"s1"}}\n' > "$W/r19-id.json"
RC=0; node "$FLOOR_MJS" sign "$W/a19.json" "$W/r19-ok.json" > "$W/a19.signed" 2>"$W/out" || RC=$?
check "19 matching registry row -> signed" 0 "$RC"
RC=0; node "$FLOOR_MJS" verify "$W/a19.signed" > "$W/out" 2>&1 || RC=$?
check "19 the signed artifact verifies" 0 "$RC"
for c in err sess id; do
    RC=0; node "$FLOOR_MJS" sign "$W/a19.json" "$W/r19-$c.json" > /dev/null 2>"$W/out" || RC=$?
    check "19 registry row mismatch ($c) -> refused" 1 "$RC"
    has "19 refusal ($c) names the registry row" "registry row" "$W/out"
done

# 20. A non-UTF-8 path is refused, never decoded lossily into another name.
mk_repo 20
if ( cd "$R" && : > "$(printf 'bad\377name')" && git add -A && git commit -qm bad ) >/dev/null 2>&1; then
    RC=0; ( cd "$R" && node "$FLOOR_MJS" snapshot HEAD "$W/snap20" ) > "$W/out" 2>&1 || RC=$?
    check "20 non-UTF-8 path -> snapshot refused" 1 "$RC"
    has "20 refusal names the cause" "not valid UTF-8" "$W/out"
else
    ok "20 SKIP: this filesystem refuses non-UTF-8 names"
fi

# 21. The schema is signed and must be 2: sign refuses another schema, and a
# signed artifact whose schema is edited no longer verifies.
sed 's/"schema":2/"schema":1/' "$W/a19.json" > "$W/a21-s1.json"
RC=0; node "$FLOOR_MJS" sign "$W/a21-s1.json" "$W/r19-ok.json" > /dev/null 2>"$W/out" || RC=$?
check "21 sign refuses schema 1" 1 "$RC"
has "21 refusal names the schema" "schema" "$W/out"
sed 's/"schema":2/"schema":3/' "$W/a19.signed" > "$W/a21-edit.json"
RC=0; node "$FLOOR_MJS" verify "$W/a21-edit.json" > "$W/out" 2>&1 || RC=$?
check "21 schema edited after signing -> verify refuses" 1 "$RC"

# 22. Two tree paths landing on one host path (a case-insensitive or
# normalising filesystem, a Windows backslash) never overwrite silently: the
# snapshot creates every file exclusively. Simulated with a dest that already
# holds one of the head's paths.
mk_repo 22
mkdir -p "$W/snap22" && printf 'stale\n' > "$W/snap22/f.txt"
RC=0; ( cd "$R" && node "$FLOOR_MJS" snapshot HEAD "$W/snap22" ) > "$W/out" 2>&1 || RC=$?
check "22 colliding host path -> snapshot refused" 1 "$RC"
has "22 refusal names the collision" "collides" "$W/out"

# 23. A private key other users can read fails closed (POSIX): key-check and
# init-key both refuse it.
K="$W/k23"; mkdir -p "$K" && cp "$CR_FLOOR_KEY_DIR/signing.key" "$CR_FLOOR_KEY_DIR/signing.pub" "$K/" && chmod 700 "$K" && chmod 640 "$K/signing.key"
RC=0; CR_FLOOR_KEY_DIR="$K" node "$FLOOR_MJS" key-check > "$W/out" 2>&1 || RC=$?
check "23 group-readable key -> key-check refuses" 1 "$RC"
has "23 refusal names the permissions" "readable by other users" "$W/out"
RC=0; CR_FLOOR_KEY_DIR="$K" node "$FLOOR_MJS" init-key > "$W/out" 2>&1 || RC=$?
check "23 group-readable key -> init-key refuses" 1 "$RC"
chmod 600 "$K/signing.key"
RC=0; CR_FLOOR_KEY_DIR="$K" node "$FLOOR_MJS" key-check > "$W/out" 2>&1 || RC=$?
check "23 0600 key -> key-check passes" 0 "$RC"

# 24. A tree path that could leave the snapshot (a backslash `..` climbs out
# on Windows) is refused on every platform, and nothing is written outside it.
mk_repo 24
if ( cd "$R" && b=$(printf 'x' | git hash-object -w --stdin) &&
     t=$(printf '100644 blob %s\t..\\..\\evil24\n' "$b" | git mktree) &&
     c=$(git commit-tree -m esc "$t") && git update-ref refs/heads/esc "$c" ) >/dev/null 2>&1; then
    RC=0; ( cd "$R" && node "$FLOOR_MJS" snapshot esc "$W/snap24/in" ) > "$W/out" 2>&1 || RC=$?
    check "24 escaping tree path -> snapshot refused" 1 "$RC"
    has "24 refusal names the escape" "could leave the snapshot" "$W/out"
else
    bad "24 could not build the escaping tree"
fi

# 25. snapshotPath, the one write chokepoint, unit-tested under path.win32 and
# POSIX: every escaping or ambiguous component is refused, never normalised.
# shellcheck disable=SC2016 # a JS program, not a shell string
FLOOR_MJS="$FLOOR_MJS" node --input-type=module -e '
import path from "node:path";
const { snapshotPath } = await import(process.env.FLOOR_MJS);
const refused = ["..\\..\\x", "a\\b", "C:x", "a/C:/x", "../x", "a/../../x", "./x", "a//b", "", "a/."];
for (const p of [path.win32, path.posix]) for (const n of refused)
    console.log(`${p === path.win32 ? "win32" : "posix"} ${JSON.stringify(n)} ${snapshotPath(p === path.win32 ? "C:\\snap" : "/snap", n, p) === null ? "refused" : "ALLOWED"}`);
console.log(`win32 ok ${snapshotPath("C:\\snap", "a/b.txt", path.win32)}`);
console.log(`posix ok ${snapshotPath("/snap", "a/b.txt", path.posix)}`);
// HIMMEL-3240: a component that merely STARTS with two dots is an ordinary name.
for (const [p, d] of [[path.win32, "C:\\snap"], [path.posix, "/snap"]])
    for (const n of ["..config", "a/..config", "...", "a/..b/c"])
        console.log(`${p === path.win32 ? "win32" : "posix"} dots ${JSON.stringify(n)} ${snapshotPath(d, n, p) === null ? "REFUSED" : "inside"}`);
' > "$W/out25" 2>&1
check "25 every escaping name refused under win32 and posix" 20 "$(grep -c ' refused$' "$W/out25")"
check "25 a plain win32 path stays inside" 'win32 ok C:\snap\a\b.txt' "$(grep '^win32 ok' "$W/out25")"
check "25 a plain posix path stays inside" 'posix ok /snap/a/b.txt' "$(grep '^posix ok' "$W/out25")"
check "25 in-tree names starting with two dots stay inside (win32 + posix)" 8 "$(grep -c ' inside$' "$W/out25")"

# 26. HIMMEL-3240: `..config` (and an empty blob) snapshot end to end.
mk_repo 26
( cd "$R" && mkdir -p a && : > empty && echo cfg > ..config && echo b > a/..b && git add -A && git commit -qm dots ) >/dev/null 2>&1
RC=0; ( cd "$R" && node "$FLOOR_MJS" snapshot HEAD "$W/snap26" ) > "$W/out" 2>&1 || RC=$?
check "26 in-tree ..config snapshot -> exit 0" 0 "$RC"
check "26 ..config holds its bytes" cfg "$(cat "$W/snap26/..config" 2>/dev/null)"
check "26 a/..b holds its bytes" b "$(cat "$W/snap26/a/..b" 2>/dev/null)"
check "26 an empty blob snapshots as an empty file" "yes 0" "$([ -f "$W/snap26/empty" ] && echo yes) $(wc -c < "$W/snap26/empty" 2>/dev/null | tr -d ' ')"

# 27. HIMMEL-3240: blobs are read in BOUNDED batches (a tree larger than one
# batch must not need one whole-tree buffer), with every per-record check kept.
# eachBlob takes the cat-file runner as a seam, so the tamper cases need no git
# shim (a PATH stub does not work under Windows). Sizes are real, from ls-tree -l.
mk_repo 27
( cd "$R" && for i in 1 2 3 4 5; do head -c 1000 /dev/zero | tr '\0' "$i" > "big$i"; done && git add -A && git commit -qm big ) >/dev/null 2>&1
# shellcheck disable=SC2016 # a JS program, not a shell string
( cd "$R" && FLOOR_MJS="$FLOOR_MJS" node --input-type=module -e '
import { spawnSync, execFileSync } from "node:child_process";
const { eachBlob } = await import(process.env.FLOOR_MJS);
const listing = execFileSync("git", ["ls-tree", "-r", "-l", "HEAD"]).toString().split("\n").filter(Boolean);
const blobs = listing.map((l) => l.match(/^\d+ blob (\w+) +(\d+)\t(big\d)$/)).filter(Boolean).map((m) => ({ sha: m[1], size: Number(m[2]), name: m[3] }));
const real = (shas, maxBuffer) => spawnSync("git", ["cat-file", "--batch"], { input: shas.join("\n") + "\n", maxBuffer });
const run = (limit, cat) => { const calls = [], got = []; try {
    eachBlob(blobs, (e, body) => got.push(`${e.name}:${body.length}:${body[0]}`), { limit, cat: (s, m) => { calls.push({ n: s.length, m }); return cat(s, m, calls.length); } });
    return { calls, got, err: null };
} catch (e) { return { calls, got, err: e.message }; } };
const ok = run(2500, real);
console.log(`batches ${ok.calls.map((c) => c.n).join(",")}`);
console.log(`bounded ${ok.calls.length > 0 && ok.calls.every((c) => c.m < 5000)}`);
console.log(`bodies ${ok.got.length} ${ok.got.every((g, i) => g === `big${i + 1}:1000:${49 + i}`)}`);
console.log(`oversize ${run(500, real).calls.map((c) => c.n).join(",")}`);
const bad = (label, cat) => console.log(`${label} ${(run(2500, cat).err || "NO-ERROR").replace(/[0-9a-f]{40}/g, "<sha>")}`);
bad("truncated", (s, m, n) => { const r = real(s, m); return n === 2 ? { ...r, stdout: r.stdout.subarray(0, r.stdout.length - 5) } : r; });
bad("nosep", (s, m, n) => { const r = real(s, m); return n === 2 ? { ...r, stdout: Buffer.concat([r.stdout.subarray(0, r.stdout.length - 2), r.stdout.subarray(r.stdout.length - 1)]) } : r; });
bad("trailing", (s, m, n) => { const r = real(s, m); return n === 3 ? { ...r, stdout: Buffer.concat([r.stdout, Buffer.from("extra")]) } : r; });
bad("badhdr", (s, m, n) => { const r = real(s, m); return n === 2 ? { ...r, stdout: Buffer.from(r.stdout.toString("latin1").replace(" 1000\n", " 1000 junk\n"), "latin1") } : r; });
bad("expsize", (s, m, n) => { const r = real(s, m); return n === 2 ? { ...r, stdout: Buffer.from(r.stdout.toString("latin1").replace(" 1000\n", " 1e3\n"), "latin1") } : r; });
bad("badsha", (s, m, n) => { const r = real(s, m); return n === 2 ? { ...r, stdout: Buffer.concat([Buffer.from("0"), r.stdout.subarray(1)]) } : r; });
bad("badsize", (s, m, n) => { const r = real(s, m); return n === 2 ? { ...r, stdout: Buffer.from(r.stdout.toString("latin1").replace(" 1000\n", " 999\n"), "latin1") } : r; });
bad("failed", (s, m, n) => (n === 2 ? { status: 128, stderr: Buffer.from("boom"), stdout: Buffer.alloc(0) } : real(s, m)));
bad("enobufs", (s, m, n) => (n === 2 ? { status: null, error: new Error("spawnSync git ENOBUFS"), stdout: Buffer.alloc(0), stderr: Buffer.alloc(0) } : real(s, m)));
' ) > "$W/out27" 2>&1
check "27 five 1000-byte blobs under a 2500 cap -> batches 2,2,1" "batches 2,2,1" "$(grep '^batches' "$W/out27")"
check "27 every batch buffer is smaller than the whole tree" "bounded true" "$(grep '^bounded' "$W/out27")"
check "27 every blob is delivered, in order, with its bytes" "bodies 5 true" "$(grep '^bodies' "$W/out27")"
check "27 a blob over the cap gets a batch of its own" "oversize 1,1,1,1,1" "$(grep '^oversize' "$W/out27")"
has "27 a truncated batch is refused" "cat-file output truncated at" "$W/out27"
has "27 a body one byte short of its separator is refused" "nosep cat-file output truncated at" "$W/out27"
has "27 surplus output after the last record is refused" "trailing unexpected trailing cat-file output" "$W/out27"
has "27 a header with extra fields is refused" "badhdr unexpected cat-file record" "$W/out27"
has "27 a non-decimal size field (1e3) is refused" "expsize unexpected cat-file record" "$W/out27"
has "27 a wrong record sha is refused" "badsha unexpected cat-file record" "$W/out27"
has "27 a size that differs from ls-tree is refused" "!= listed" "$W/out27"
has "27 a failed cat-file is refused" "git cat-file --batch failed" "$W/out27"
check "27 no tamper case slipped through" 0 "$(grep -c 'NO-ERROR' "$W/out27")"

echo "claude-floor-review: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
