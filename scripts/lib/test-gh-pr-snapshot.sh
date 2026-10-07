#!/usr/bin/env bash
# Platform guard (gitbash-only): bash 3.2+. Offline snapshot/cache contract.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
W=$(mktemp -d "${TMPDIR:-/tmp}/pr-snapshot-test.XXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
export GH_PR_SNAPSHOT_CACHE_DIR="$W/cache" GH_LOG="$W/calls" HEAD_FILE="$W/head" REPLY_FILE="$W/reply"
SHA=0123456789abcdef0123456789abcdef01234567
NEW=1111111111111111111111111111111111111111
printf '%s\n' "$SHA" > "$HEAD_FILE"
cat > "$W/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$*" in
    *'pullRequest(number:$n)'*) cat "$PAGE_FILE" ;;
    'api graphql'*) cat "$REPLY_FILE"; [ -z "${CHANGE_HEAD:-}" ] || printf '%s\n' "$CHANGE_HEAD" > "$HEAD_FILE" ;;
    'api repos/'*)
        cat "$HEAD_FILE"
        if [ -n "${FAIL_FINAL_HEAD:-}" ] && [ "$(grep -c '^api repos/' "$GH_LOG")" -eq 2 ]; then exit 1; fi ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$W/bin/gh"
export PATH="$W/bin:$PATH"
fails=0
check() { if [ "$2" = "$3" ]; then printf 'ok - %s\n' "$1"; else printf 'FAIL - %s: [%s] != [%s]\n' "$1" "$2" "$3"; fails=$((fails+1)); fi; }
fixture() {
    jq -n --arg h "$1" '{data:{repository:{p77:{number:77,headRefOid:$h,mergeStateStatus:"CLEAN",reviewDecision:"APPROVED",body:"## Ticket coverage\n- ask: done",state:"OPEN",title:"test",headRefName:"fix/test",isDraft:false,mergedAt:null,commits:{nodes:[{commit:{oid:$h,messageHeadline:"fix: [HIMMEL-1] test",messageBody:"",parents:{totalCount:1}}}],pageInfo:{hasNextPage:false,endCursor:null}},reviewThreads:{nodes:[{isResolved:true}],pageInfo:{hasNextPage:false,endCursor:null}},statusCheckRollup:{contexts:{nodes:[{__typename:"CheckRun",name:"build",status:"COMPLETED",conclusion:"SUCCESS",startedAt:null,completedAt:null,checkSuite:{workflowRun:{workflow:{name:"CI"}}}}],pageInfo:{hasNextPage:false,endCursor:null}}}}}}}' > "$REPLY_FILE"
}
run() { bash "$HERE/gh-pr-snapshot.sh" acme/repo 60 "$@"; }
fixture "$SHA"
rc=0; out=$(run 77) || rc=$?
check 'snapshot returns usable data' "$rc" 0
check 'snapshot head' "$(printf '%s' "$out" | jq -r '.[0].headRefOid' 2>/dev/null)" "$SHA"
check 'workflow identity normalized' "$(printf '%s' "$out" | jq -r '.[0].statusCheckRollup[0].workflowName' 2>/dev/null)" CI
calls=$(grep -c '^api graphql' "$GH_LOG" 2>/dev/null || true)
check 'one GraphQL request' "${calls:-0}" 1
rc=0; out=$(run 77) || rc=$?
check 'cache hit succeeds' "$rc" 0
check 'cache hit makes no GraphQL request' "$(grep -c '^api graphql' "$GH_LOG" 2>/dev/null || true)" 1
printf '%s\n' "$NEW" > "$HEAD_FILE"
fixture "$NEW"
rc=0; out=$(run 77) || rc=$?
check 'stale-head cache replaced' "$(printf '%s' "$out" | jq -r '.[0].headRefOid' 2>/dev/null)" "$NEW"
check 'new head fetched' "$(grep -c '^api graphql' "$GH_LOG" 2>/dev/null || true)" 2
printf '%s\n' "$SHA" > "$HEAD_FILE"
fixture "$SHA"
rc=0; out=$(CHANGE_HEAD="$NEW" run 77) || rc=$?
check 'push during fetch fails closed' "$rc" 1
check 'push during fetch returns no stale data' "$out" ''
printf '%s\n' "$SHA" > "$HEAD_FILE"
printf '%s\n' '{"errors":[{"message":"unreadable"}]}' > "$REPLY_FILE"
rc=0; out=$(run 77) || rc=$?
check 'unreadable snapshot fails closed' "$rc" 1
check 'unreadable snapshot returns no data' "$out" ''
fixture "$SHA"
jq '.data.repository.p88 = (.data.repository.p77 | .number=88)' "$REPLY_FILE" > "$W/batch"
mv "$W/batch" "$REPLY_FILE"
: > "$GH_LOG"
rc=0; out=$(run 77 88) || rc=$?
check 'batch succeeds' "$rc" 0
check 'batch returns both PRs' "$(printf '%s' "$out" | jq -c 'map(.number)' 2>/dev/null)" '[77,88]'
check 'batch uses one query' "$(grep -c '^api graphql' "$GH_LOG" 2>/dev/null || true)" 1
# A missing alias is not a successful empty PR.
printf '%s\n' "$NEW" > "$HEAD_FILE"
fixture "$NEW"
rc=0; out=$(run 77 88) || rc=$?
check 'missing alias fails closed' "$rc" 1
check 'partial batch returns no data' "$out" ''
fixture "$NEW"
jq '.data.repository.p77.reviewThreads.nodes = [{}]' "$REPLY_FILE" > "$W/bad"
mv "$W/bad" "$REPLY_FILE"
rc=0; out=$(run 77) || rc=$?
check 'malformed thread is unreadable, not unresolved data' "$rc" 1
fixture "$NEW"
jq '.data.repository.p77.commits.nodes[0].commit.parents = null' "$REPLY_FILE" > "$W/bad"
mv "$W/bad" "$REPLY_FILE"
rc=0; out=$(run 77) || rc=$?
check 'missing parent counts fail closed' "$rc" 1
export PAGE_FILE="$W/page"
fixture "$NEW"
jq '.data.repository.p77.reviewThreads.pageInfo = {hasNextPage:true,endCursor:"next"}' "$REPLY_FILE" > "$W/start"
mv "$W/start" "$REPLY_FILE"
jq -n --arg h "$NEW" '{data:{repository:{pullRequest:{headRefOid:$h,reviewThreads:{nodes:[{isResolved:false}],pageInfo:{hasNextPage:false,endCursor:null}}}}}}' > "$PAGE_FILE"
rc=0; out=$(run 77) || rc=$?
check 'continuation thread page succeeds' "$rc" 0
check 'unresolved thread after page one is retained' "$(printf '%s' "$out" | jq -r '.[0].reviewThreads.nodes | map(select(.isResolved == false)) | length' 2>/dev/null)" 1
# Force a miss, then a cycling cursor must never return partial success.
rc=0; out=$(run 77) || rc=$?
check 'paginated result cache succeeds' "$rc" 0
jq '.data.repository.pullRequest.reviewThreads.pageInfo = {hasNextPage:true,endCursor:"next"}' "$PAGE_FILE" > "$W/cycle"
mv "$W/cycle" "$PAGE_FILE"
rc=0; out=$(bash "$HERE/gh-pr-snapshot.sh" acme/repo 0 77) || rc=$?
check 'cursor cycle fails closed' "$rc" 1
for field in commits statusCheckRollup; do
    fixture "$NEW"
    jq --arg f "$field" 'if $f == "commits" then .data.repository.p77.commits.pageInfo = {hasNextPage:true,endCursor:"next"} else .data.repository.p77.statusCheckRollup.contexts.pageInfo = {hasNextPage:true,endCursor:"next"} end' "$REPLY_FILE" > "$W/start"
    mv "$W/start" "$REPLY_FILE"
    jq --arg f "$field" '.data.repository.p77 | if $f == "commits" then {headRefOid,commits:(.commits | .pageInfo={hasNextPage:false,endCursor:null})} else {headRefOid,statusCheckRollup:(.statusCheckRollup | .contexts.pageInfo={hasNextPage:false,endCursor:null})} end | {data:{repository:{pullRequest:.}}}' "$REPLY_FILE" > "$PAGE_FILE"
    : > "$GH_LOG"
    rc=0; out=$(bash "$HERE/gh-pr-snapshot.sh" acme/repo 0 77) || rc=$?
    check "$field continuation succeeds" "$rc" 0
    check "$field continuation retains both pages" "$(printf '%s' "$out" | jq -r --arg f "$field" '.[0][$f] | length' 2>/dev/null)" 2
    check "$field continuation costs two queries" "$(grep -c '^api graphql' "$GH_LOG" 2>/dev/null || true)" 2
done
# A cache hit must not hide an unreadable authoritative head.
printf '\n' > "$HEAD_FILE"
rc=0; out=$(run 77) || rc=$?
check 'unreadable head refuses cached data' "$rc" 1
check 'unreadable head returns no cached data' "$out" ''
printf '%s\n' "$NEW" > "$HEAD_FILE"
# A live fetch lock must not be stolen or bypassed.
locks=("$GH_PR_SNAPSHOT_CACHE_DIR"/*.json)
key=${locks[0]##*/}; key=${key%%-*}
mkdir "$GH_PR_SNAPSHOT_CACHE_DIR/$key.lock"
: > "$GH_LOG"
rc=0; out=$(run 77) || rc=$?
check 'contention fails closed' "$rc" 1
check 'contention does not bypass lock to fetch' "$(grep -c '^api graphql' "$GH_LOG" 2>/dev/null || true)" 0
rmdir "$GH_PR_SNAPSHOT_CACHE_DIR/$key.lock"
# A colliding/foreign entry with the same PR and head must not be a hit.
for f in "$GH_PR_SNAPSHOT_CACHE_DIR"/*.json; do
    jq '.repository = "github.com/foreign/repo"' "$f" > "$W/foreign"
    mv "$W/foreign" "$f"
done
printf '%s\n' '{"errors":[{"message":"unreadable"}]}' > "$REPLY_FILE"
rc=0; out=$(run 77) || rc=$?
check 'foreign repository cache tag is never served' "$rc" 1
fixture "$NEW"
: > "$GH_LOG"
rc=0; out=$(FAIL_FINAL_HEAD=1 bash "$HERE/gh-pr-snapshot.sh" acme/repo 0 77) || rc=$?
check 'failed final head read with valid stdout still fails closed' "$rc" 1
check 'failed final head read publishes nothing' "$out" ''
[ "$fails" -eq 0 ] || exit 1
printf 'ALL PASS\n'
