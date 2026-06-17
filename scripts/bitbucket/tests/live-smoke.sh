#!/usr/bin/env bash
# Live smoke test for the himmel bitbucket CLI (HIMMEL-326, spec §8).
#
# Exercises the real write path against a THROWAWAY repo in the test workspace,
# then deletes it. Gated on creds + an explicit workspace — NOT run in CI
# (the offline unit tests are the CI gate). Documented + manual by design.
#
# Usage:
#   BITBUCKET_SMOKE_WS=example-ws bash scripts/bitbucket/tests/live-smoke.sh
#
# Requires BITBUCKET_EMAIL + BITBUCKET_API_TOKEN (repo-root .env or env).
# Creates repo <ws>/forge-smoke, drives repo view → src commits → pr create →
# pr merge → pr list merged, and ALWAYS deletes the repo on exit (trap).
set -uo pipefail

WS="${BITBUCKET_SMOKE_WS:-}"
SLUG="forge-smoke"
API="https://api.bitbucket.org/2.0"

if [ -z "$WS" ]; then
    echo "SKIP: set BITBUCKET_SMOKE_WS=<workspace> to run the live smoke." >&2
    exit 0
fi

# Load creds from repo-root .env if not already in the environment.
ROOT="$(cd "$(dirname "$(git rev-parse --git-common-dir)")" && pwd)"
if [ -z "${BITBUCKET_EMAIL:-}" ] && [ -f "$ROOT/.env" ]; then
    set -a
    # shellcheck disable=SC1091  # .env is runtime/gitignored, not analyzable
    . "$ROOT/.env"
    set +a
fi
: "${BITBUCKET_EMAIL:?set BITBUCKET_EMAIL}" "${BITBUCKET_API_TOKEN:?set BITBUCKET_API_TOKEN}"

AUTH="$BITBUCKET_EMAIL:$BITBUCKET_API_TOKEN"
# Invoke the locally-built dist from THIS checkout (on a feature branch the
# primary checkout has no built dist yet — this is a dev-time smoke).
CLI="node $(git rev-parse --show-toplevel)/scripts/bitbucket/dist/index.js"
export BITBUCKET_WORKSPACE="$WS" BITBUCKET_REPO_SLUG="$SLUG"

PASS=0; FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; [ $# -ge 2 ] && printf '    %s\n' "$2"; FAIL=$((FAIL+1)); }

# shellcheck disable=SC2329,SC2317  # invoked via the EXIT trap
teardown() {
    echo "teardown: deleting $WS/$SLUG"
    curl -s -o /dev/null -w "  delete repo → %{http_code}\n" -X DELETE -u "$AUTH" "$API/repositories/$WS/$SLUG" || true
}
trap teardown EXIT

echo "smoke: creating throwaway repo $WS/$SLUG"
# Pre-delete any leftover from a prior run, then poll until it's actually gone —
# Bitbucket's repo delete is async, so an immediate re-create races to a 400.
curl -s -o /dev/null -X DELETE -u "$AUTH" "$API/repositories/$WS/$SLUG" || true
for _ in $(seq 1 15); do
    gone=$(curl -s -o /dev/null -w "%{http_code}" -u "$AUTH" "$API/repositories/$WS/$SLUG")
    [ "$gone" = "404" ] && break
    sleep 2
done
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST -u "$AUTH" \
    -H "Content-Type: application/json" \
    -d '{"scm":"git","is_private":true}' "$API/repositories/$WS/$SLUG")
case "$code" in 200|201) ok "repo create ($code)";; *) bad "repo create" "HTTP $code"; exit 1;; esac

echo "smoke: seeding main + feat/smoke commits via the src API"
curl -s -o /dev/null -u "$AUTH" -F "README.md=smoke base" -F "message=init" -F "branch=main" \
    "$API/repositories/$WS/$SLUG/src"
MAIN_HASH=$(curl -s -u "$AUTH" "$API/repositories/$WS/$SLUG/refs/branches/main" \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{process.stdout.write((JSON.parse(s).target||{}).hash||"")})')
curl -s -o /dev/null -u "$AUTH" -F "feature.txt=smoke feature" -F "message=feat" \
    -F "branch=feat/smoke" -F "parents=$MAIN_HASH" "$API/repositories/$WS/$SLUG/src"
ok "seeded commits (main=$MAIN_HASH)"

echo "smoke: CLI repo view"
if $CLI repo view; then ok "repo view"; else bad "repo view"; fi

echo "smoke: CLI pr create feat/smoke → main"
PR_JSON=$($CLI pr create --title "smoke PR" --body "live smoke" --source feat/smoke --destination main)
echo "$PR_JSON"
PR_ID=$(printf '%s' "$PR_JSON" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{process.stdout.write(String(JSON.parse(s).id))})')
if [ -n "$PR_ID" ]; then ok "pr create (id=$PR_ID)"; else bad "pr create"; exit 1; fi

echo "smoke: CLI pr merge $PR_ID"
MERGE_JSON=$($CLI pr merge "$PR_ID" --squash --delete-branch); echo "$MERGE_JSON"
if printf '%s' "$MERGE_JSON" | grep -q MERGED; then ok "pr merge → MERGED"; else bad "pr merge" "$MERGE_JSON"; fi

echo "smoke: CLI pr list --state MERGED"
LIST_JSON=$($CLI pr list --state MERGED)
if printf '%s' "$LIST_JSON" | grep -q "\"id\": $PR_ID"; then
    ok "pr list merged contains #$PR_ID"
else
    bad "pr list merged" "$LIST_JSON"
fi

echo
echo "smoke summary: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
