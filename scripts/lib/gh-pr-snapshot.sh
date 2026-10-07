#!/usr/bin/env bash
# Shared head-tagged PR snapshots (HIMMEL-4858). CLI: <owner/repo> <ttl> <pr>...
# Platform guard (gitbash-only): bash 3.2+. Output: gh-shaped JSON array, or
# nonzero with no stdout. REST head reads validate even TTL hits; misses use
# one aliased GraphQL query. Continuation pages never become silent truncation.
set -uo pipefail
umask 077
GH="${GH_CMD:-gh}"
nwo="${1:-}"; ttl="${2:-}"; shift 2 2>/dev/null || exit 1
case "$nwo" in ''|*[!A-Za-z0-9._/-]*|*/*/*|/*|*/) exit 1 ;; */*) ;; *) exit 1 ;; esac
case "$ttl" in ''|*[!0-9]*) exit 1 ;; esac
[ "$#" -gt 0 ] || exit 1
for pr in "$@"; do
    case "$pr" in ''|0*|*[!0-9]*) exit 1 ;; esac
done
command -v jq >/dev/null 2>&1 || exit 1
dir="${GH_PR_SNAPSHOT_CACHE_DIR:-${HOME:-/tmp}/.himmel/state/pr-snapshot}"
(umask 077; mkdir -p "$dir") || exit 1
# Include the API host: an enterprise namesake must never read github.com's cache.
repository="${GH_HOST:-github.com}/$nwo"
key=$(printf '%s' "$repository" | cksum | awk '{print $1}')
lock="$dir/$key.lock"
# Fail closed under contention rather than fetching outside the lock. Do not
# steal by age: a slow live fetch must not lose its lock to another writer.
mkdir "$lock" 2>/dev/null || exit 1
printf '%s\n' "$$" > "$lock/pid"
work=$(mktemp -d "$dir/.snapshot.XXXXXX") || { rm -f "$lock/pid"; rmdir "$lock"; exit 1; }
trap 'rm -rf "$work"; rm -f "$lock/pid"; rmdir "$lock" 2>/dev/null' EXIT
trap 'exit 1' HUP INT TERM
now=$(date +%s)
owner=${nwo%%/*}; repo=${nwo#*/}
# shellcheck disable=SC2016  # GraphQL variables, not shell expansions.
query='query($o:String!,$r:String!){repository(owner:$o,name:$r){'
misses=""
head_now() { "$GH" api "repos/$nwo/pulls/$1" --jq '.head.sha' 2>/dev/null; }
valid_head() { [ "${#1}" -eq 40 ] && case "$1" in *[!0-9a-f]*) return 1 ;; esac; }
validation='def valid:
    (.mergeStateStatus | type == "string") and (.body | type == "string") and
    (.commits | type == "array" and length > 0) and all(.commits[];
        (.oid | type == "string" and test("^[0-9a-f]{40}$")) and (.messageHeadline | type == "string") and
        (.messageBody == null or (.messageBody | type == "string")) and
        (.parents.totalCount | type == "number" and . >= 0 and . == floor)) and
    (.reviewThreads.nodes | type == "array") and all(.reviewThreads.nodes[]; (.isResolved | type == "boolean")) and
    (.reviewThreads.pageInfo.hasNextPage == false) and
    (.statusCheckRollup == null or ((.statusCheckRollup | type == "array") and
        all(.statusCheckRollup[]; .__typename == "CheckRun" or .__typename == "StatusContext")));'
# The API read, not the caller's expected sha, is authoritative for freshness.
for pr in "$@"; do
    head=$(head_now "$pr") || exit 1
    valid_head "$head" || exit 1
    printf '%s\n' "$head" > "$work/$pr.head"
    file="$dir/$key-$pr.json"
    if jq -e --arg repository "$repository" --arg h "$head" --argjson n "$pr" --argjson now "$now" --argjson ttl "$ttl" "$validation"'
        .repository == $repository and .head == $h and .value.headRefOid == $h and .value.number == $n and (.value | valid) and
        (.at | type == "number") and ($now - .at >= 0 and $now - .at < $ttl)
    ' "$file" >/dev/null 2>&1; then
        jq '.value' "$file" > "$work/$pr.json" || exit 1
    else
        misses="$misses $pr"
        query="$query p$pr:pullRequest(number:$pr){number headRefOid mergeStateStatus reviewDecision body state title headRefName isDraft mergedAt commits(first:100){nodes{commit{oid messageHeadline messageBody parents{totalCount}}} pageInfo{hasNextPage endCursor}} reviewThreads(first:100){nodes{isResolved} pageInfo{hasNextPage endCursor}} statusCheckRollup{contexts(first:100){nodes{__typename ...on CheckRun{name status conclusion startedAt completedAt checkSuite{workflowRun{workflow{name}}}} ...on StatusContext{context state createdAt}} pageInfo{hasNextPage endCursor}}}}"
    fi
done
query="$query }}"
if [ -n "$misses" ]; then
    "$GH" api graphql -f "query=$query" -f o="$owner" -f r="$repo" > "$work/reply" 2>/dev/null || exit 1
    jq -e '(.errors // [] | length) == 0 and (.data.repository | type == "object")' "$work/reply" >/dev/null 2>&1 || exit 1
    for pr in $misses; do
        jq -e ".data.repository.p$pr" "$work/reply" > "$work/$pr.raw" || exit 1
        head=$(cat "$work/$pr.head")
        jq -e --arg h "$head" --argjson n "$pr" '
            .number == $n and .headRefOid == $h and
            (.mergeStateStatus | type == "string") and (.body | type == "string") and
            (.commits.nodes | type == "array" and length > 0) and
            all(.commits.nodes[].commit; (.oid | type == "string" and test("^[0-9a-f]{40}$")) and
                (.messageHeadline | type == "string") and (.messageBody == null or (.messageBody | type == "string")) and
                (.parents.totalCount | type == "number" and . >= 0 and . == floor)) and
            (.reviewThreads.nodes | type == "array") and all(.reviewThreads.nodes[]; (.isResolved | type == "boolean")) and
            (.statusCheckRollup == null or ((.statusCheckRollup.contexts.nodes | type == "array") and
                all(.statusCheckRollup.contexts.nodes[]; .__typename == "CheckRun" or .__typename == "StatusContext")))
        ' "$work/$pr.raw" >/dev/null 2>&1 || exit 1
        # Each connection owns its cursor. Follow it independently, with the same
        # head binding and cycle/limit guards as the old ready-check thread read.
        for field in commits reviewThreads statusCheckRollup; do
            case "$field" in
                commits) path='.commits'; selection='nodes{commit{oid messageHeadline messageBody parents{totalCount}}}'; connection='commits' ;;
                reviewThreads) path='.reviewThreads'; selection='nodes{isResolved}'; connection='reviewThreads' ;;
                statusCheckRollup) path='.statusCheckRollup.contexts'; selection='nodes{__typename ...on CheckRun{name status conclusion startedAt completedAt checkSuite{workflowRun{workflow{name}}}} ...on StatusContext{context state createdAt}}'; connection='contexts' ;;
            esac
            [ "$field" != statusCheckRollup ] || ! jq -e '.statusCheckRollup == null' "$work/$pr.raw" >/dev/null || continue
            pages=1; seen='|'
            while :; do
                more=$(jq -r "$path.pageInfo.hasNextPage" "$work/$pr.raw") || exit 1
                case "$more" in false) break ;; true) ;; *) exit 1 ;; esac
                cursor=$(jq -er "$path.pageInfo.endCursor | select(type == \"string\" and length > 0)" "$work/$pr.raw") || exit 1
                case "$seen" in *"|$cursor|"*) exit 1 ;; esac
                seen="$seen$cursor|"; pages=$((pages + 1))
                [ "$pages" -le 50 ] || exit 1
                chunk="$connection(first:100,after:\$c){$selection pageInfo{hasNextPage endCursor}}"
                [ "$field" != statusCheckRollup ] || chunk="statusCheckRollup{$chunk}"
                q="query(\$o:String!,\$r:String!,\$n:Int!,\$c:String!){repository(owner:\$o,name:\$r){pullRequest(number:\$n){headRefOid $chunk}}}"
                "$GH" api graphql -f "query=$q" -f o="$owner" -f r="$repo" -F n="$pr" -f c="$cursor" > "$work/page" 2>/dev/null || exit 1
                jq -e --arg h "$head" '(.errors // [] | length) == 0 and .data.repository.pullRequest.headRefOid == $h' "$work/page" >/dev/null 2>&1 || exit 1
                jq --slurpfile page "$work/page" "$path as \$old | (\$page[0].data.repository.pullRequest $path) as \$new | if (\$new.nodes | type) != \"array\" then error(\"unreadable page\") else $path = {nodes:(\$old.nodes + \$new.nodes),pageInfo:\$new.pageInfo} end" "$work/$pr.raw" > "$work/next" || exit 1
                mv "$work/next" "$work/$pr.raw" || exit 1
            done
        done
        jq '{number,headRefOid,mergeStateStatus,reviewDecision,body,state,title,headRefName,isDraft,mergedAt,
            commits:[.commits.nodes[].commit], reviewThreads:.reviewThreads,
            statusCheckRollup:(if .statusCheckRollup == null then null else [.statusCheckRollup.contexts.nodes[] |
                if .__typename == "CheckRun" then . + {workflowName:(.checkSuite.workflowRun.workflow.name // "")} | del(.checkSuite) else . end] end)}' "$work/$pr.raw" > "$work/$pr.json" || exit 1
        jq -e "$validation valid" "$work/$pr.json" >/dev/null 2>&1 || exit 1
    done
fi
# Never publish or cache a reply across a push, including multi-PR batches.
for pr in "$@"; do
    head=$(cat "$work/$pr.head")
    [ "$(head_now "$pr")" = "$head" ] || exit 1
done
for pr in $misses; do
    head=$(cat "$work/$pr.head")
    jq -n --arg repository "$repository" --arg head "$head" --argjson at "$now" --slurpfile v "$work/$pr.json" '{repository:$repository,head:$head,at:$at,value:$v[0]}' > "$work/cache" || exit 1
    mv "$work/cache" "$dir/$key-$pr.json" || exit 1
done
# Emit only after every member has passed: no partial-success stdout.
set -- "$@"
files=()
for pr in "$@"; do files[${#files[@]}]="$work/$pr.json"; done
jq -s '.' "${files[@]}"
