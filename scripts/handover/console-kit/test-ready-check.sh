#!/usr/bin/env bash
# scripts/handover/console-kit/test-ready-check.sh — suite for ready-check.sh
# `gh` is a PATH stub (contract requirement — not GH_CMD, even
# though the script also honors that override); `jq` and `git` are real.
#
# Covers: usage (arg count / bad PR / bad sha), one all-green PR, and one
# failing case per check (1..6).
#
# Platform guard (gitbash-only): POSIX bash 3.2+.
# shellcheck disable=SC2015  # A && B || C is intentional in check()/contains(), as in test-go.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/ready-check.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ready-check-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd)"
fails=0
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { grepq "$2" -F -e "$3" && echo "ok - $1" || { echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)); }; }
notcontains() { grepq "$2" -F -e "$3" && { echo "FAIL - $1: output contains [$3]"; fails=$((fails+1)); } || echo "ok - $1"; }

SHA=0123456789abcdef0123456789abcdef01234567
PR=77
NWO=acme/repo

# ── a throwaway git repo, since check 4 resolves the ledger via
# `git rev-parse --git-common-dir` from the caller's cwd ──────────────────
REPO="$tmp/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name tester
git -C "$REPO" commit -q --allow-empty -m "chore: init"
LEDGER="$REPO/.git/cr-critic-scores.jsonl"

# ── gh PATH stub ─────────────────────────────────────────────────────────
mkdir -p "$tmp/bin"
GH_LOG="$tmp/gh.log"
export GH_PR_SNAPSHOT_CACHE_DIR="$tmp/snapshot-cache"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
args="$*"
case "$args" in
    "repo view --json owner,name"*)
        [ -z "${STUB_DEFAULT_BRANCH_FAIL:-}" ] || { printf '%s\n' "${STUB_NWO:-acme/repo}"; exit 0; }
        printf '%s main\n' "${STUB_NWO:-acme/repo}" ;;
    *"--json headRefOid,mergeStateStatus"*)
        printf '%s %s\n' "${STUB_HEAD:-}" "${STUB_MSS:-CLEAN}" ;;
    *"--json statusCheckRollup"*)
        printf '%s' "${STUB_ROLLUP:-[]}" ;;
    *"--json commits"*)
        printf '%s' "${STUB_COMMITS:-[]}" ;;
    *"--json body"*)
        printf '%b' "${STUB_BODY:-}" ;;
    *"contents/scripts/ci/ci-trust-paths.txt"*)
        [ -z "${STUB_TRUST_LIST_FAIL:-}" ] || { echo "boom" >&2; exit 1; }
        cat "$STUB_TRUST_LIST_FILE" ;;
    "api repos/"*"/pulls/"*"/files --paginate"*)
        printf '%s\n' "${STUB_FILES:-README.md}" | while IFS= read -r f; do printf '%s\t\n' "$f"; done ;;
    "api repos/"*"/pulls/"*"changed_files"*)
        printf '%s|%s\n' "${STUB_HEAD:-}" "$(printf '%s\n' "${STUB_FILES:-README.md}" | wc -l | tr -d ' ')" ;;
    'api repos/'*'/pulls/'*) printf '%s\n' "${STUB_HEAD:-}" ;;
    *'p77:pullRequest'*)
        [ -z "${STUB_SNAPSHOT_FAIL:-}" ] || exit 1
        jq -n --arg h "$STUB_HEAD" --arg m "${STUB_MSS:-CLEAN}" \
            --argjson rollup "${STUB_ROLLUP:-[]}" --argjson commits "${STUB_COMMITS:-[]}" \
            --arg merges "${STUB_MERGE_OIDS:-}" --argjson u "${STUB_UNRESOLVED:-0}" \
            --arg body "$(printf '%b' "${STUB_BODY:-}")" '
            {data:{repository:{p77:{number:77,headRefOid:$h,mergeStateStatus:$m,reviewDecision:null,body:$body,
                commits:{nodes:[$commits[] | . as $commit | {commit:(. + {oid:(.oid // $h),parents:{totalCount:(if (($merges|split("\n")) | index($commit.oid // "")) != null then 2 else 1 end)}})}],pageInfo:{hasNextPage:false,endCursor:null}},
                reviewThreads:{nodes:[range($u)|{isResolved:false}],pageInfo:{hasNextPage:false,endCursor:null}},
                statusCheckRollup:{contexts:{nodes:[$rollup[] | . + {__typename:(if has("conclusion") then "CheckRun" else "StatusContext" end)} | if has("workflowName") then . + {checkSuite:{workflowRun:{workflow:{name:.workflowName}}}} else . end],pageInfo:{hasNextPage:false,endCursor:null}}}
            }}}}' ;;
    *"commits(first:100)"*)
        printf '%s\n' "${STUB_MERGE_OIDS:-}" ;;
    *"api graphql"*)
        printf '%s %s %s\n' "${STUB_UNRESOLVED:-0}" "false" "null" ;;
    *"api --paginate"*"/files"*'select(.status'*)
        # run the script's own --jq filter over a files array, so the status filter is really exercised
        printf '%s\n' "${STUB_FILE_STATUS:-}" | jq -R -n '[inputs | select(length > 0) | split(" ") | {status: .[0], filename: .[1]}]' \
            | jq -r "${args#*--jq }" ;;
    "api -H Accept: application/vnd.github.raw repos/"*"/contents/"*)
        f="${args#*/contents/}"; f="${f%%\?ref=*}"
        [ -f "${STUB_WF_DIR:-/nonexistent}/${f##*/}" ] || exit 1
        cat "$STUB_WF_DIR/${f##*/}" ;;
    "run list"*)
        [ -z "${STUB_RUNS_FAIL:-}" ] || exit 1
        w="${args#*--workflow }"; w="${w%% *}"
        if [ -f "${STUB_RUNS_DIR:-/nonexistent}/$w.json" ]; then cat "$STUB_RUNS_DIR/$w.json"; else printf '[]'; fi ;;
    *"api --paginate"*"/files"*"filename"*)
        [ -n "${STUB_FILES_FAIL:-}" ] && exit 1
        printf '%s\n' "${STUB_FILES:-README.md}" ;;
    *)
        echo "gh-stub: unhandled args: $args" >&2
        exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/gh"

# ── jira stub (JIRA_CMD): `get KEY` reads STUB_JIRA_DB lines "KEY<TAB>Status";
# an absent key is the real CLI's HTTP 404, STUB_JIRA_DOWN=1 is an outage ────
cat > "$tmp/bin/jira-stub" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "get" ] || { echo "jira-stub: unhandled: $*" >&2; exit 1; }
[ -n "${STUB_JIRA_DOWN:-}" ] && { echo "jira: get $2 failed: connect ECONNREFUSED" >&2; exit 1; }
st=$(awk -F'\t' -v k="$2" '$1 == k { print $2 }' "${STUB_JIRA_DB:-/dev/null}")
if [ -z "$st" ]; then
    echo "jira: get $2 failed: HTTP 404: Issue does not exist or you do not have permission to see it." >&2
    exit 1
fi
[ "$st" = "MALFORMED" ] && { printf 'garbage with no tabs\n'; exit 0; }
[ "$st" = "BLANK" ] && st=""
printf '%s\tTask\t%s\tsummary\n' "$2" "$st"
STUB
chmod +x "$tmp/bin/jira-stub"
# ── trust-path fixtures: the REAL trust list, served as the default branch's; an
# anchor repo (carrying the real go-gate.sh) whose origin is at the same commit,
# so a trust-path hit passes trust_path_check's anchor-is-current test offline ──
TRUST_LIST_FILE="$HERE/../../ci/ci-trust-paths.txt"
TP_ANCHOR="$tmp/tp-anchor"
git init -q --bare "$tmp/tp-origin.git"
git init -q "$TP_ANCHOR"
mkdir -p "$TP_ANCHOR/scripts/lib"
cp "$HERE/../../lib/go-gate.sh" "$TP_ANCHOR/scripts/lib/go-gate.sh"
git -C "$TP_ANCHOR" add -A
git -C "$TP_ANCHOR" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$TP_ANCHOR" remote add origin "$tmp/tp-origin.git"
git -C "$TP_ANCHOR" push -q origin HEAD:refs/heads/main 2>/dev/null
git -C "$tmp/tp-origin.git" symbolic-ref HEAD refs/heads/main
export GH_LOG
PATH="$tmp/bin:$PATH"
export PATH

# ── shared green defaults ───────────────────────────────────────────────
GREEN_ROLLUP='[{"name":"build","status":"COMPLETED","conclusion":"SUCCESS"},{"context":"legacy-ci","state":"SUCCESS"}]'
GREEN_COMMITS='[{"messageHeadline":"feat(x): [HIMMEL-1] add thing","messageBody":"Platforms tested: linux\nSecurity reviewed: manual"},{"messageHeadline":"fix(x): [HIMMEL-2] tweak","messageBody":""}]'
GREEN_FILES="scripts/x/run.sh"
GREEN_BODY='## Summary\nthing\n\n## Ticket coverage\n- ask one: done\n- ask two: done\n\n## Test plan\nx\n'
JIRA_DB="$tmp/jira.db"
printf 'HIMMEL-50\tTo Do\nHIMMEL-51\tDone\nHIMMEL-52\tClosed\nHIMMEL-53\tWon'"'"'t Do\nHIMMEL-54\tBLANK\nHIMMEL-55\tMALFORMED\n' > "$JIRA_DB"

seed_ledger_ok() {
    printf '{"kind":"avail","ts":"2026-01-01T00:00:00Z","branch":"b","head":"%s","model":"codex","status":"ok"}\n' "$SHA" > "$LEDGER"
}
seed_ledger_missing() {
    printf '{"kind":"avail","ts":"2026-01-01T00:00:00Z","branch":"b","head":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef","model":"codex","status":"ok"}\n' > "$LEDGER"
}

run() {
    local cache
    cache=$(mktemp -d "$tmp/cache.XXXXXX") || return 1
    (cd "$REPO" && env -u TICKET_ID_PATTERN \
        JIRA_PROJECT_KEY=HIMMEL \
        STUB_NWO="$NWO" \
        STUB_HEAD="${STUB_HEAD:-$SHA}" STUB_MSS="${STUB_MSS:-CLEAN}" \
        STUB_ROLLUP="${STUB_ROLLUP:-$GREEN_ROLLUP}" \
        STUB_UNRESOLVED="${STUB_UNRESOLVED:-0}" \
        STUB_COMMITS="${STUB_COMMITS:-$GREEN_COMMITS}" \
        STUB_MERGE_OIDS="${STUB_MERGE_OIDS:-}" \
        STUB_FILES="${STUB_FILES:-$GREEN_FILES}" \
        STUB_FILES_FAIL="${STUB_FILES_FAIL:-}" \
        STUB_FILE_STATUS="${STUB_FILE_STATUS:-}" STUB_WF_DIR="${STUB_WF_DIR:-}" \
        STUB_RUNS_DIR="${STUB_RUNS_DIR:-}" STUB_RUNS_FAIL="${STUB_RUNS_FAIL:-}" \
        STUB_BODY="${STUB_BODY-$GREEN_BODY}" \
        JIRA_CMD="$tmp/bin/jira-stub" STUB_JIRA_DB="$JIRA_DB" STUB_JIRA_DOWN="${STUB_JIRA_DOWN:-}" \
        PATH="$PATH" GH_LOG="$GH_LOG" GH_PR_SNAPSHOT_CACHE_DIR="$cache" \
        STUB_SNAPSHOT_FAIL="${STUB_SNAPSHOT_FAIL:-}" \
        STUB_TRUST_LIST_FILE="$TRUST_LIST_FILE" STUB_TRUST_LIST_FAIL="${STUB_TRUST_LIST_FAIL:-}" \
        STUB_DEFAULT_BRANCH_FAIL="${STUB_DEFAULT_BRANCH_FAIL:-}" \
        READY_CHECK_ANCHOR="${READY_CHECK_ANCHOR:-$TP_ANCHOR}" \
        bash "$SCRIPT" "$PR" "$SHA")
}

reset_stubs() {
    unset STUB_TRUST_LIST_FAIL STUB_DEFAULT_BRANCH_FAIL
    unset STUB_HEAD STUB_MSS STUB_ROLLUP STUB_UNRESOLVED STUB_COMMITS STUB_MERGE_OIDS STUB_FILES STUB_FILES_FAIL STUB_BODY STUB_JIRA_DOWN STUB_SNAPSHOT_FAIL STUB_FILE_STATUS STUB_WF_DIR STUB_RUNS_DIR STUB_RUNS_FAIL
    seed_ledger_ok
}

# --- usage -------------------------------------------------------------
for args in "" "77" "77 $SHA extra" "x1 $SHA" "077 $SHA" "77 ${SHA%?}" "77 ${SHA}0" \
            "77 0123456789ABCDEF0123456789abcdef01234567" "77 g123456789abcdef0123456789abcdef01234567"; do
  rc=0
  # shellcheck disable=SC2086  # word-splitting the args string IS the point
  bash "$SCRIPT" $args >/dev/null 2>&1 || rc=$?
  check "usage: [$args] -> exit 2" "$rc" "2"
done

# --- 0. all-green PR: exit 0, READY-CHECK PASS, all six PASS lines ------
reset_stubs
: > "$GH_LOG"
rc=0; out="$(run)" || rc=$?
gql_calls=$(grep -Ec '^(repo view|pr view|api graphql)' "$GH_LOG")
check "green: at most two GraphQL calls" "$((gql_calls <= 2))" "1"
check "green: exit 0" "$rc" "0"
contains "green: overall verdict" "$out" "READY-CHECK PASS"
contains "green: check 1 passes" "$out" "[PASS] 1."
contains "green: check 2 passes" "$out" "[PASS] 2."
contains "green: check 3 passes" "$out" "[PASS] 3."
contains "green: check 4 passes" "$out" "[PASS] 4."
contains "green: check 5 passes" "$out" "[PASS] 5."
contains "green: check 6 passes" "$out" "[PASS] 6."
contains "green: names the diff read as the console's job" "$out" "stays the console's own judgement"

# An unreadable shared snapshot must fail every dependent check, not just head.
reset_stubs
STUB_SNAPSHOT_FAIL=1
rc=0; out="$(run)" || rc=$?
check "unreadable snapshot: exit 1" "$rc" "1"
for item in 1 2 3 5 6 7; do
    contains "unreadable snapshot: check $item fails" "$out" "[FAIL] $item."
done

# --- 1a. check 1 fails: head mismatch -----------------------------------
reset_stubs
STUB_HEAD=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
rc=0; out="$(run)" || rc=$?
check "head-mismatch: exit 1" "$rc" "1"
contains "head-mismatch: check 1 fails" "$out" "[FAIL] 1."
contains "head-mismatch: overall verdict" "$out" "READY-CHECK FAIL"

# --- 1b. check 1 fails: mergeStateStatus not CLEAN ----------------------
reset_stubs
STUB_MSS=DIRTY
rc=0; out="$(run)" || rc=$?
check "dirty-merge: exit 1" "$rc" "1"
contains "dirty-merge: check 1 fails" "$out" "[FAIL] 1."

# --- 2. check 2 fails: a red check in the rollup ------------------------
reset_stubs
STUB_ROLLUP='[{"name":"build","status":"COMPLETED","conclusion":"FAILURE"}]'
rc=0; out="$(run)" || rc=$?
check "red-check: exit 1" "$rc" "1"
contains "red-check: check 2 fails" "$out" "[FAIL] 2."
contains "red-check: names the offender" "$out" "build=COMPLETED/FAILURE"

# --- 2b. check 2 fails: empty rollup (CI not registered yet) ------------
reset_stubs
STUB_ROLLUP='[]'
rc=0; out="$(run)" || rc=$?
check "empty-rollup: exit 1" "$rc" "1"
contains "empty-rollup: check 2 fails" "$out" "[FAIL] 2. statusCheckRollup: no checks reported yet"

# --- 2c. same check name CANCELLED earlier, SUCCESS later —
# item 2 must PASS (judge the LATEST run per check identity, not any row) --
reset_stubs
STUB_ROLLUP='[{"name":"pr-title-lint","status":"COMPLETED","conclusion":"CANCELLED","startedAt":"2026-01-01T08:15:00Z","completedAt":"2026-01-01T08:19:58Z"},{"name":"pr-title-lint","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-01-01T08:24:00Z","completedAt":"2026-01-01T08:26:47Z"}]'
rc=0; out="$(run)" || rc=$?
check "superseded-cancelled: exit 0" "$rc" "0"
contains "superseded-cancelled: check 2 passes on the later SUCCESS run" "$out" "[PASS] 2."

# --- 2d. control: same name SUCCESS earlier, CANCELLED later — the later
# run still governs, so item 2 FAILs ----------------------------------------
reset_stubs
STUB_ROLLUP='[{"name":"pr-title-lint","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-01-01T08:10:00Z","completedAt":"2026-01-01T08:12:00Z"},{"name":"pr-title-lint","status":"COMPLETED","conclusion":"CANCELLED","startedAt":"2026-01-01T08:20:00Z","completedAt":"2026-01-01T08:22:00Z"}]'
rc=0; out="$(run)" || rc=$?
check "later-cancelled: exit 1" "$rc" "1"
contains "later-cancelled: check 2 fails on the later run" "$out" "[FAIL] 2."
contains "later-cancelled: names the latest run's detail" "$out" "pr-title-lint=COMPLETED/CANCELLED"

# --- 2e. control: two DIFFERENT check names, one FAILURE — each keeps its
# own verdict; grouping must not merge unrelated names ----------------------
reset_stubs
STUB_ROLLUP='[{"name":"build","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"lint","status":"COMPLETED","conclusion":"FAILURE"}]'
rc=0; out="$(run)" || rc=$?
check "two-names-one-failure: exit 1" "$rc" "1"
contains "two-names-one-failure: check 2 fails" "$out" "[FAIL] 2."
contains "two-names-one-failure: names only the failing check" "$out" "lint=COMPLETED/FAILURE"

# --- 2f. control: same name in two different workflows, one FAILURE — a
# different workflowName means a different identity, so the earlier failing
# workflow's run must not be superseded by the other workflow's later
# success (a grouping-by-name-only bug would hide this) ---------------------
reset_stubs
STUB_ROLLUP='[{"name":"test","workflowName":"CI-B","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-01-01T08:00:00Z","completedAt":"2026-01-01T08:02:00Z"},{"name":"test","workflowName":"CI-A","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-01-01T08:05:00Z","completedAt":"2026-01-01T08:07:00Z"}]'
rc=0; out="$(run)" || rc=$?
check "same-name-two-workflows: exit 1" "$rc" "1"
contains "same-name-two-workflows: check 2 fails" "$out" "[FAIL] 2."
contains "same-name-two-workflows: names the failing workflow's run" "$out" "test=COMPLETED/FAILURE"

# --- 2g. control: an in-progress later run after an earlier SUCCESS — the
# later, unfinished run governs, so item 2 FAILs ----------------------------
reset_stubs
STUB_ROLLUP='[{"name":"pr-title-lint","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-01-01T08:10:00Z","completedAt":"2026-01-01T08:12:00Z"},{"name":"pr-title-lint","status":"IN_PROGRESS","conclusion":null,"startedAt":"2026-01-01T08:20:00Z"}]'
rc=0; out="$(run)" || rc=$?
check "later-in-progress: exit 1" "$rc" "1"
contains "later-in-progress: check 2 fails on the still-running later run" "$out" "[FAIL] 2."
contains "later-in-progress: names the in-progress run" "$out" "pr-title-lint=IN_PROGRESS/null"

# --- 2h. control: a later QUEUED run (no startedAt/completedAt at all) after
# an earlier timestamped SUCCESS — a run that has not started yet has no
# timestamp to lose a max_by comparison with, so it must still govern and
# item 2 FAILs (an untimed later run must not lose to an
# earlier timestamped one) --------------------------------------------------
reset_stubs
STUB_ROLLUP='[{"name":"pr-title-lint","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-01-01T08:10:00Z","completedAt":"2026-01-01T08:12:00Z"},{"name":"pr-title-lint","status":"QUEUED","conclusion":null}]'
rc=0; out="$(run)" || rc=$?
check "later-queued-untimed: exit 1" "$rc" "1"
contains "later-queued-untimed: check 2 fails on the still-queued later run" "$out" "[FAIL] 2."
contains "later-queued-untimed: names the queued run" "$out" "pr-title-lint=QUEUED/null"

# --- 3. check 3 fails: unresolved review threads > 0 --------------------
reset_stubs
STUB_UNRESOLVED=2
rc=0; out="$(run)" || rc=$?
check "unresolved-threads: exit 1" "$rc" "1"
contains "unresolved-threads: check 3 fails" "$out" "[FAIL] 3. unresolved review threads = 2"

# --- 4. check 4 fails: no ledger row for this head ----------------------
reset_stubs
seed_ledger_missing
rc=0; out="$(run)" || rc=$?
check "no-ledger-row: exit 1" "$rc" "1"
contains "no-ledger-row: check 4 fails" "$out" "[FAIL] 4."
seed_ledger_ok

# --- 5a. check 5 fails: sensitive files, no Platforms tested trailer ----
reset_stubs
STUB_COMMITS='[{"messageHeadline":"feat(x): [HIMMEL-1] add thing","messageBody":"Security reviewed: manual"},{"messageHeadline":"fix(x): [HIMMEL-2] tweak","messageBody":""}]'
rc=0; out="$(run)" || rc=$?
check "missing-platforms: exit 1" "$rc" "1"
contains "missing-platforms: check 5 fails" "$out" "missing 'Platforms tested:'"

# --- 5b. check 5 fails: non-docs files, no Security reviewed trailer ----
reset_stubs
STUB_COMMITS='[{"messageHeadline":"feat(x): [HIMMEL-1] add thing","messageBody":"Platforms tested: linux"},{"messageHeadline":"fix(x): [HIMMEL-2] tweak","messageBody":""}]'
rc=0; out="$(run)" || rc=$?
check "missing-security: exit 1" "$rc" "1"
contains "missing-security: check 5 fails" "$out" "missing 'Security reviewed:'"

# --- 5c. docs-only PR needs neither trailer ------------------------------
reset_stubs
STUB_FILES="docs/handover/running-a-console.md"
STUB_COMMITS='[{"messageHeadline":"docs: [HIMMEL-1] note","messageBody":""}]'
rc=0; out="$(run)" || rc=$?
check "docs-only: exit 0" "$rc" "0"
contains "docs-only: check 5 passes" "$out" "[PASS] 5."

# --- 5c2. Markdown/text under scripts/ needs no Platforms ---
reset_stubs
STUB_FILES="scripts/telegram/README.md"
STUB_COMMITS='[{"messageHeadline":"docs: [HIMMEL-1] note","messageBody":""}]'
rc=0; out="$(run)" || rc=$?
check "scripts-readme-only: exit 0" "$rc" "0"
contains "scripts-readme-only: check 5 passes" "$out" "[PASS] 5."
contains "scripts-readme-only: platforms not needed" "$out" "Platforms tested (needed=0)"

reset_stubs
STUB_FILES="scripts/x/run.sh"
STUB_COMMITS='[{"messageHeadline":"fix(x): [HIMMEL-1] tweak","messageBody":"Security reviewed: manual"}]'
rc=0; out="$(run)" || rc=$?
check "scripts-sh-only: exit 1" "$rc" "1"
contains "scripts-sh-only: check 5 fails" "$out" "missing 'Platforms tested:'"

reset_stubs
STUB_FILES="scripts/telegram/README.md
scripts/x/run.sh"
STUB_COMMITS='[{"messageHeadline":"fix(x): [HIMMEL-1] tweak","messageBody":"Security reviewed: manual"}]'
rc=0; out="$(run)" || rc=$?
check "scripts-mixed: exit 1" "$rc" "1"
contains "scripts-mixed: check 5 fails" "$out" "missing 'Platforms tested:'"

# --- 5d. check 5 fails: PR files unreadable (API call failed) -----------
reset_stubs
STUB_FILES_FAIL=1
rc=0; out="$(run)" || rc=$?
check "files-unreadable: exit 1" "$rc" "1"
contains "files-unreadable: check 5 fails" "$out" "[FAIL] 5. cannot read PR files"

# --- 5e. check 5 reads ONLY the first commit --------------
# A docs-only first commit with the trailers on a LATER commit (what a PR-body
# or follow-up-commit "recovery" amounts to) must still FAIL: the stuck-playbook
# recovery is a recut, not a trailer added after the fact.
reset_stubs
STUB_COMMITS='[{"messageHeadline":"docs: [HIMMEL-1] note","messageBody":""},{"messageHeadline":"fix(x): [HIMMEL-2] code","messageBody":"Platforms tested: linux\nSecurity reviewed: manual"}]'
rc=0; out="$(run)" || rc=$?
check "later-commit-trailers: exit 1" "$rc" "1"
contains "later-commit-trailers: check 5 fails (platforms)" "$out" "missing 'Platforms tested:'"
contains "later-commit-trailers: check 5 fails (security)" "$out" "missing 'Security reviewed:'"

# --- 6. check 6 fails: a commit subject with no ticket ID ---------------
reset_stubs
STUB_COMMITS='[{"messageHeadline":"feat(x): [HIMMEL-1] add thing","messageBody":"Platforms tested: linux\nSecurity reviewed: manual"},{"messageHeadline":"fix(x): tweak with no ticket","messageBody":""}]'
rc=0; out="$(run)" || rc=$?
check "missing-ticket: exit 1" "$rc" "1"
contains "missing-ticket: check 6 fails" "$out" "[FAIL] 6."
contains "missing-ticket: names the offending subject" "$out" "tweak with no ticket"

# --- 6b. a merge commit (>1 parent) is exempt from check 6,
# even though its subject carries no ticket ID -------------------------
reset_stubs
MERGE_OID=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
STUB_FILES="docs/handover/running-a-console.md"
STUB_COMMITS='[{"oid":"'"$MERGE_OID"'","messageHeadline":"Merge remote-tracking branch '"'"'origin/main'"'"' into fix/x","messageBody":""},{"oid":"111111111111111111111111111111111111111a","messageHeadline":"fix(x): [HIMMEL-1] tweak","messageBody":""}]'
rc=0; out="$(run)" || rc=$?
check "merge-commit unexempt (no STUB_MERGE_OIDS): exit 1" "$rc" "1"
contains "merge-commit unexempt: check 6 fails at base" "$out" "[FAIL] 6."

STUB_MERGE_OIDS="$MERGE_OID"
rc=0; out="$(run)" || rc=$?
check "merge-commit exempt: exit 0" "$rc" "0"
contains "merge-commit exempt: check 6 passes" "$out" "[PASS] 6."

# --- 6c. an unticketed NON-merge commit still fails check 6 even when a
# merge commit is present elsewhere in the range ------------------------
reset_stubs
STUB_MERGE_OIDS="$MERGE_OID"
STUB_COMMITS='[{"oid":"'"$MERGE_OID"'","messageHeadline":"Merge remote-tracking branch '"'"'origin/main'"'"' into fix/x","messageBody":""},{"oid":"111111111111111111111111111111111111111a","messageHeadline":"fix(x): tweak with no ticket","messageBody":"Platforms tested: linux\nSecurity reviewed: manual"}]'
rc=0; out="$(run)" || rc=$?
check "merge-plus-unticketed: exit 1" "$rc" "1"
contains "merge-plus-unticketed: check 6 fails" "$out" "[FAIL] 6."
contains "merge-plus-unticketed: names the offending subject, not the merge" "$out" "tweak with no ticket"

# --- 7. ticket coverage. The PR body needs a `## Ticket coverage`
# section, one line per ask, each `done` or `deferred → <KEY>`; a deferred key
# must exist and be open. A Jira error reads UNKNOWN, never PASS. ------------
reset_stubs
rc=0; out="$(run)" || rc=$?
contains "coverage all-done: check 7 passes" "$out" "[PASS] 7."

reset_stubs
STUB_BODY='## Summary\nthing\n'
rc=0; out="$(run)" || rc=$?
check "coverage missing section: exit 1" "$rc" "1"
contains "coverage missing section: check 7 fails" "$out" "[FAIL] 7."

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n- ask two: deferred -> HIMMEL-99999\n'
rc=0; out="$(run)" || rc=$?
check "coverage deferred to nonexistent key: exit 1" "$rc" "1"
contains "coverage nonexistent key: check 7 fails" "$out" "[FAIL] 7."
contains "coverage nonexistent key: names the key" "$out" "HIMMEL-99999"

for st in 51 52 53; do
    reset_stubs
    STUB_BODY='## Ticket coverage\n- ask one: done\n- ask two: deferred \xe2\x86\x92 HIMMEL-'"$st"'\n'
    rc=0; out="$(run)" || rc=$?
    check "coverage deferred to closed key HIMMEL-$st: exit 1" "$rc" "1"
    contains "coverage closed key HIMMEL-$st: check 7 fails" "$out" "[FAIL] 7."
done

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n- ask two: deferred \xe2\x86\x92 HIMMEL-50\n'
rc=0; out="$(run)" || rc=$?
check "coverage deferred to open key: exit 0" "$rc" "0"
contains "coverage open key: check 7 passes" "$out" "[PASS] 7."

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n- ask two: deferred -> HIMMEL-50\n'
STUB_JIRA_DOWN=1
rc=0; out="$(run)" || rc=$?
check "coverage jira unreachable: exit 1" "$rc" "1"
contains "coverage jira unreachable: reads UNKNOWN" "$out" "UNKNOWN"
case "$out" in *"[PASS] 7."*) echo "FAIL - coverage jira unreachable: must not PASS"; fails=$((fails+1)) ;; *) echo "ok - coverage jira unreachable: no PASS" ;; esac

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n- ask two: maybe later\n'
rc=0; out="$(run)" || rc=$?
check "coverage unmarked line: exit 1" "$rc" "1"
contains "coverage unmarked line: check 7 fails" "$out" "[FAIL] 7."

reset_stubs
STUB_BODY='## Ticket coverage\n'
rc=0; out="$(run)" || rc=$?
check "coverage empty section: exit 1" "$rc" "1"

# `done` must be the line's terminal disposition, not a substring
reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: not done\n'
rc=0; out="$(run)" || rc=$?
check "coverage 'not done': exit 1" "$rc" "1"
contains "coverage 'not done': check 7 fails" "$out" "[FAIL] 7."

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done pending verification\n'
rc=0; out="$(run)" || rc=$?
check "coverage 'done pending verification': exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done.\n- ask two: **done**\n'
rc=0; out="$(run)" || rc=$?
check "coverage 'done.' / bold done: exit 0" "$rc" "0"

# a successful jira get with a blank status is UNKNOWN, never open
reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-54\n'
rc=0; out="$(run)" || rc=$?
check "coverage blank jira status: exit 1" "$rc" "1"
contains "coverage blank jira status: reads UNKNOWN" "$out" "UNKNOWN"

# a deferral must also END the line, and a delimiter-free jira reply is not a status
reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50 pending verification\n'
rc=0; out="$(run)" || rc=$?
check "coverage deferral with trailing prose: exit 1" "$rc" "1"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-50.\n- ask two: deferred \xe2\x86\x92 **HIMMEL-50**\n'
rc=0; out="$(run)" || rc=$?
check "coverage deferral with trailing punctuation/bold: exit 0" "$rc" "0"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-55\n'
rc=0; out="$(run)" || rc=$?
check "coverage malformed jira reply: exit 1" "$rc" "1"
contains "coverage malformed jira reply: reads UNKNOWN" "$out" "UNKNOWN"

# --- 7b. `--only 7 <pr>` runs just the coverage check, so a leg
# lints its own PR body before READY with item 7's exact logic (no second copy).
run7() {
    (cd "$REPO" && env -u TICKET_ID_PATTERN \
        JIRA_PROJECT_KEY=HIMMEL STUB_NWO="$NWO" \
        STUB_BODY="${STUB_BODY-$GREEN_BODY}" \
        JIRA_CMD="$tmp/bin/jira-stub" STUB_JIRA_DB="$JIRA_DB" \
        PATH="$PATH" GH_LOG="$GH_LOG" \
        bash "$SCRIPT" --only 7 "$PR")
}

reset_stubs
rc=0; out="$(run7)" || rc=$?
check "only 7 clean body: exit 0" "$rc" "0"
contains "only 7 clean body: check 7 passes" "$out" "[PASS] 7."
contains "only 7 clean body: says PASS" "$out" "COVERAGE-LINT PASS"
notcontains "only 7 clean body: runs no other check" "$out" "[PASS] 1."

# checks 1-6 must not gate it: a head the stub does not know is irrelevant here
reset_stubs
STUB_HEAD=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef STUB_UNRESOLVED=3
rc=0; out="$(run7)" || rc=$?
check "only 7 ignores items 1-6: exit 0" "$rc" "0"

reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done\n- ask two: done pending verification\n- ask three: deferred -> HIMMEL-50 (see thread)\n'
rc=0; out="$(run7)" || rc=$?
check "only 7 trailing text: exit 1" "$rc" "1"
contains "only 7 trailing text: names the failing line" "$out" "ask two: done pending verification"
contains "only 7 trailing text: names the second failing line" "$out" "ask three: deferred -> HIMMEL-50 (see thread)"
contains "only 7 trailing text: prints the done shape" "$out" "- <ask>: done"
contains "only 7 trailing text: prints the deferred shape" "$out" "- <ask>: deferred → HIMMEL-<n>"
contains "only 7 trailing text: says marker LAST" "$out" "marker LAST"
contains "only 7 trailing text: says FAIL" "$out" "COVERAGE-LINT FAIL"

# the full run prints the same shape message on the same failure
reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: done pending verification\n'
rc=0; out="$(run)" || rc=$?
contains "full run trailing text: prints the accepted shape" "$out" "- <ask>: done"

rc=0; out="$(cd "$REPO" && bash "$SCRIPT" --only 6 "$PR" 2>&1)" || rc=$?
check "only 6 refused: exit 2" "$rc" "2"

# --- 8. TICKET_ID_PATTERN / JIRA_PROJECT_KEY must resolve from
# ready-check.sh's OWN checkout, never the caller's CWD repo. Fixture mirrors
# test-bank-preflight-dotenv-root.sh: a scratch "own checkout" (this script +
# scripts/lib/load-dotenv.sh, laid out at the same relative depth, plus a
# fixture .env carrying JIRA_PROJECT_KEY) is run with CWD at $REPO — a git
# repo with no .env of its own — and neither var exported by the caller.
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
own="$tmp/own-checkout"
mkdir -p "$own/scripts/handover/console-kit" "$own/scripts/lib"
cp "$SCRIPT" "$own/scripts/handover/console-kit/ready-check.sh"
cp "$REPO_ROOT/scripts/lib/load-dotenv.sh" "$own/scripts/lib/load-dotenv.sh"
cp "$REPO_ROOT/scripts/lib/gh-pr-snapshot.sh" "$own/scripts/lib/gh-pr-snapshot.sh"
cp "$REPO_ROOT/scripts/lib/go-gate.sh" "$own/scripts/lib/go-gate.sh"
printf 'JIRA_PROJECT_KEY=HIMMEL\n' > "$own/.env"

reset_stubs
STUB_COMMITS="$GREEN_COMMITS"
rc=0
out="$(cd "$REPO" && env -u TICKET_ID_PATTERN -u JIRA_PROJECT_KEY \
    STUB_NWO="$NWO" STUB_HEAD="$SHA" STUB_MSS=CLEAN \
    STUB_ROLLUP="$GREEN_ROLLUP" STUB_UNRESOLVED=0 \
    STUB_COMMITS="$STUB_COMMITS" STUB_FILES="$GREEN_FILES" \
    STUB_BODY="$GREEN_BODY" JIRA_CMD="$tmp/bin/jira-stub" STUB_JIRA_DB="$JIRA_DB" \
    STUB_TRUST_LIST_FILE="$TRUST_LIST_FILE" \
    PATH="$PATH" GH_LOG="$GH_LOG" \
    bash "$own/scripts/handover/console-kit/ready-check.sh" "$PR" "$SHA")" || rc=$?
check "own-checkout .env: exit 0" "$rc" "0"
contains "own-checkout .env: check 6 (ticket ID) passes" "$out" "[PASS] 6."

# --- 9. the plugin version bump is re-checked against the CURRENT
# origin/main. Two PRs can each bump a plugin to the same version with different
# content; mergeStateStatus stays CLEAN, so check 1 cannot see it. Fixture: a
# bare origin; WORK builds history and pushes each PR head to refs/pull/77/head;
# CLONE (what run() cds into) is cloned BEFORE main moves, so its origin/main is
# stale and has none of the PR objects — check 9 must fetch both.
PLUG=marketplace/plugins/demo
ORIGIN="$tmp/origin.git"
WORK="$tmp/work"
CLONE="$tmp/clone"
git init -q --bare "$ORIGIN"
git init -q -b main "$WORK"
git -C "$WORK" config user.email t@example.com
git -C "$WORK" config user.name tester
git -C "$WORK" remote add origin "$ORIGIN"
write_plugin() {  # <version> <content>
    mkdir -p "$WORK/$PLUG/.claude-plugin"
    printf '{"name":"demo","version":"%s"}\n' "$1" > "$WORK/$PLUG/.claude-plugin/plugin.json"
    printf '%s\n' "$2" > "$WORK/$PLUG/body.txt"
    git -C "$WORK" add -A
    git -C "$WORK" commit -q -m "$3"
}
write_plugin 0.4.70 base "chore: base"
git -C "$WORK" push -q origin main
BASE_OID=$(git -C "$WORK" rev-parse HEAD)
git clone -q "$ORIGIN" "$CLONE"
pr_head() {  # <version> <content> -> commit on a branch off the base, pushed as the PR head
    git -C "$WORK" checkout -q -B pr "$BASE_OID"
    write_plugin "$1" "$2" "fix: pr"
    git -C "$WORK" rev-parse HEAD
}
PR_SAME=$(pr_head 0.4.71 from-pr)
PR_AHEAD=$(pr_head 0.4.72 from-pr)
PR_UNBUMPED=$(pr_head 0.4.70 from-pr)
PR_PRE=$(pr_head 0.4.71-alpha from-pr)
git -C "$WORK" checkout -q -B pr "$BASE_OID"
git -C "$WORK" rm -rq "$PLUG"
git -C "$WORK" commit -q -m "fix: pr removes the plugin"
PR_DEL=$(git -C "$WORK" rev-parse HEAD)
# a second plugin whose manifest on main carries no version (unreadable there)
BADP=marketplace/plugins/bad
pr_head 0.4.72 from-pr >/dev/null
mkdir -p "$WORK/$BADP/.claude-plugin"
printf '{"name":"bad","version":"1.0.0"}\n' > "$WORK/$BADP/.claude-plugin/plugin.json"
git -C "$WORK" add -A
git -C "$WORK" commit -q -m "fix: pr touches bad"
PR_BAD=$(git -C "$WORK" rev-parse HEAD)
git -C "$WORK" checkout -q main
write_plugin 0.4.71 from-main "feat: main shipped 0.4.71"
mkdir -p "$WORK/$BADP/.claude-plugin"
printf '{"name":"bad"}\n' > "$WORK/$BADP/.claude-plugin/plugin.json"
git -C "$WORK" add -A
git -C "$WORK" commit -q -m "feat: main bad manifest"
git -C "$WORK" push -q origin main

run_bump() {  # <pr head> <files> -> sets rc/out
    git -C "$WORK" push -q -f origin "$1:refs/pull/$PR/head"
    local keep_sha="$SHA" keep_repo="$REPO" keep_ledger="$LEDGER"
    SHA="$1"; REPO="$CLONE"; LEDGER="$CLONE/.git/cr-critic-scores.jsonl"
    reset_stubs
    STUB_FILES="$2"
    rc=0; out="$(run)" || rc=$?
    SHA="$keep_sha"; REPO="$keep_repo"; LEDGER="$keep_ledger"
}

run_bump "$PR_SAME" "$PLUG/body.txt"
check "plugin same-version-as-main: exit 1" "$rc" "1"
contains "plugin same-version-as-main: check 9 fails" "$out" "[FAIL] 9."
contains "plugin same-version-as-main: names the plugin" "$out" "demo"

run_bump "$PR_UNBUMPED" "$PLUG/body.txt"
check "plugin below main: exit 1" "$rc" "1"
contains "plugin below main: check 9 fails" "$out" "[FAIL] 9."

run_bump "$PR_AHEAD" "$PLUG/body.txt"
contains "plugin ahead of main: check 9 passes" "$out" "[PASS] 9."
notcontains "plugin ahead of main: no check fails" "$out" "[FAIL]"

run_bump "$PR_PRE" "$PLUG/body.txt"
check "prerelease PR version: exit 1" "$rc" "1"
contains "prerelease PR version: check 9 fails" "$out" "[FAIL] 9."

run_bump "$PR_BAD" "$BADP/.claude-plugin/plugin.json"
check "unreadable main manifest: exit 1" "$rc" "1"
contains "unreadable main manifest: check 9 fails" "$out" "[FAIL] 9."

run_bump "$PR_DEL" "$PLUG/body.txt"
contains "plugin removed by the PR: check 9 passes" "$out" "[PASS] 9."

run_bump "$PR_SAME" "README.md"
contains "no plugin touched: check 9 passes" "$out" "[PASS] 9."

# --- 10. a PR that changes a GitHub Actions workflow needs a
# completed, successful workflow_dispatch run AT ITS HEAD. ci.yml has no push
# trigger, so the dispatch run is the only pre-merge test of the non-PR path.
# Fixtures are copied from the real environment: the workflow bodies are this
# repo's own .github/workflows files at HEAD, the run row is the shape
# `gh run list --workflow ci.yml --event workflow_dispatch --json
# databaseId,status,conclusion,headSha,event,workflowName` printed.
WF_REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
WFDIR="$tmp/wf"; RUNDIR="$tmp/runs"
mkdir -p "$WFDIR" "$RUNDIR"
git -C "$WF_REPO_ROOT" show HEAD:.github/workflows/ci.yml > "$WFDIR/ci.yml"
git -C "$WF_REPO_ROOT" show HEAD:.github/workflows/pr-title-lint.yml > "$WFDIR/pr-title-lint.yml"
cp "$WFDIR/pr-title-lint.yml" "$WFDIR/new-thing.yml"
real_run() {  # <status> <conclusion> <headSha>
    printf '[{"conclusion":"%s","databaseId":38329960360,"event":"workflow_dispatch","headSha":"%s","status":"%s","workflowName":"CI"}]' "$2" "$3" "$1"
}
wf_run() {  # <files> [removed] -> rc/out
    reset_stubs
    STUB_FILES="$1"; STUB_FILE_STATUS="${2:-}"; STUB_WF_DIR="$WFDIR"; STUB_RUNS_DIR="$RUNDIR"
    rc=0; out="$(run)" || rc=$?
}

wf_run ".github/workflows/ci.yml"
check "workflow PR, no dispatch run: exit 1" "$rc" "1"
contains "workflow PR, no dispatch run: check 10 fails" "$out" "[FAIL] 10."
contains "workflow PR, no dispatch run: prints the dispatch command" "$out" "gh workflow run ci.yml --ref"

real_run completed success "$SHA" > "$RUNDIR/ci.yml.json"
wf_run ".github/workflows/ci.yml"
check "workflow PR, green dispatch at head: exit 0" "$rc" "0"
contains "workflow PR, green dispatch at head: check 10 passes" "$out" "[PASS] 10."

real_run completed success 915c81d1b19ee5df69793f327037e912a944957e > "$RUNDIR/ci.yml.json"
wf_run ".github/workflows/ci.yml"
check "workflow PR, dispatch at an OLDER sha: exit 1" "$rc" "1"
contains "workflow PR, dispatch at an OLDER sha: check 10 fails" "$out" "[FAIL] 10."

real_run completed failure "$SHA" > "$RUNDIR/ci.yml.json"
wf_run ".github/workflows/ci.yml"
check "workflow PR, failed dispatch at head: exit 1" "$rc" "1"
contains "workflow PR, failed dispatch at head: check 10 fails" "$out" "[FAIL] 10."

real_run in_progress "" "$SHA" > "$RUNDIR/ci.yml.json"
wf_run ".github/workflows/ci.yml"
check "workflow PR, dispatch still running: exit 1" "$rc" "1"
contains "workflow PR, dispatch still running: check 10 fails" "$out" "[FAIL] 10."

real_run completed success "$SHA" > "$RUNDIR/ci.yml.json"
reset_stubs; STUB_FILES=".github/workflows/ci.yml"; STUB_WF_DIR="$WFDIR"; STUB_RUNS_DIR="$RUNDIR"; STUB_RUNS_FAIL=1
rc=0; out="$(run)" || rc=$?
check "workflow PR, run list errors: exit 1 (fail closed)" "$rc" "1"
contains "workflow PR, run list errors: check 10 fails" "$out" "[FAIL] 10."

: > "$GH_LOG"
wf_run "scripts/handover/console-kit/ready-check.sh"
check "non-workflow PR: exit 0" "$rc" "0"
contains "non-workflow PR: check 10 not applicable" "$out" "[PASS] 10."
notcontains "non-workflow PR: no run list issued" "$(cat "$GH_LOG")" "run list"

wf_run ".github/workflows/new-thing.yml"
check "workflow with no workflow_dispatch trigger: exit 1" "$rc" "1"
contains "workflow with no workflow_dispatch trigger: check 10 fails" "$out" "[FAIL] 10."
contains "workflow with no workflow_dispatch trigger: names the missing trigger" "$out" "no workflow_dispatch trigger"

wf_run ".github/workflows/pr-title-lint.yml"
check "exempted workflow without a trigger: exit 0" "$rc" "0"
contains "exempted workflow without a trigger: check 10 passes" "$out" "[PASS] 10."

wf_run ".github/workflows/ci.yml" "removed .github/workflows/ci.yml"
contains "workflow deleted by the PR: check 10 passes" "$out" "[PASS] 10."

# A workflow the PR ADDS (or renames to) is not on the default branch, and GitHub
# only dispatches a workflow that exists there, so it cannot be dispatched yet.
rm -f "$RUNDIR"/*.json
cp "$WFDIR/ci.yml" "$WFDIR/brand-new.yml"
UNW_REAL_SHA="$SHA"
SHA=$(git -C "$REPO" rev-parse HEAD)  # check 11 now reads the head even when nothing judgeable is added
wf_run ".github/workflows/brand-new.yml" "added .github/workflows/brand-new.yml"
SHA="$UNW_REAL_SHA"
check "workflow added by the PR: exit 0" "$rc" "0"
contains "workflow added by the PR: check 10 passes" "$out" "[PASS] 10."
wf_run ".github/workflows/brand-new.yml" "renamed .github/workflows/brand-new.yml"
contains "workflow renamed by the PR: check 10 passes" "$out" "[PASS] 10."
wf_run ".github/workflows/brand-new.yml" "modified .github/workflows/brand-new.yml"
check "workflow modified (not added) still needs a dispatch run: exit 1" "$rc" "1"

# --- 11. a PR that ADDS a hook/script/skill/suite nothing reaches ---
# Each scenario commits into the throwaway REPO on top of a base that carries the
# real hook-wiring list; SHA is that commit, so the item reads its tree.
UNW_REAL_SHA="$SHA"
mkdir -p "$REPO/scripts/testing" "$REPO/scripts/hooks" "$REPO/.claude" "$REPO/.github/workflows"
cp "$HERE/../../testing/check-unwired-hooks.sh" "$REPO/scripts/testing/"
mkdir -p "$REPO/scripts/ci" && cp "$HERE/../../ci/run-shell-tests.sh" "$REPO/scripts/ci/"
printf '{}\n' > "$REPO/.claude/settings.json"
printf '# allowlist\n' > "$REPO/scripts/testing/unwired-hooks-allowlist.txt"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "chore: base for check 11"
UNW_BASE=$(git -C "$REPO" rev-parse HEAD)

# unw_run <added path>... — files are created empty-ish, committed, judged as status A
unw_run() {
    git -C "$REPO" checkout -q --detach "$UNW_BASE" && git -C "$REPO" clean -fdq
    local f st=""
    for f in "$@"; do
        mkdir -p "$REPO/${f%/*}"
        [ -f "$REPO/$f" ] || printf '#!/usr/bin/env bash\n' > "$REPO/$f"
        st="$st"$'added '"$f"$'\n'
    done
    mkdir -p "$REPO/.github/workflows" "$REPO/scripts/tools" "$REPO/scripts/lib"
    [ -z "${UNW_EXTRA:-}" ] || eval "$UNW_EXTRA"
    git -C "$REPO" add -A && git -C "$REPO" commit -q -m "feat: [HIMMEL-1] scenario"
    SHA=$(git -C "$REPO" rev-parse HEAD)
    seed_ledger_ok
    reset_stubs
    STUB_HEAD="$SHA"; STUB_FILES="$(printf '%s\n' "$@")"; STUB_FILE_STATUS="${st%$'\n'}"
    rc=0; out="$(run)" || rc=$?
    SHA="$UNW_REAL_SHA"
}

# RED: the hook is added and no wiring file names it
UNW_EXTRA=''
unw_run scripts/hooks/new-hook.sh
check "unwired hook: exit 1" "$rc" "1"
contains "unwired hook: check 11 fails" "$out" "[FAIL] 11."
contains "unwired hook: names the file" "$out" "scripts/hooks/new-hook.sh"

# the same hook, wired in a file of the WIRING list in the same diff
UNW_EXTRA="printf '{\"hooks\":\"scripts/hooks/new-hook.sh\"}\n' > \"\$REPO/.claude/settings.json\""
unw_run scripts/hooks/new-hook.sh
check "wired hook: exit 0" "$rc" "0"
contains "wired hook: check 11 passes" "$out" "[PASS] 11."

# a hook-name in a prefixed basename is not a registration
UNW_EXTRA="printf '{\"hooks\":\"scripts/hooks/not-new-hook.sh\"}\n' > \"\$REPO/.claude/settings.json\""
unw_run scripts/hooks/new-hook.sh
contains "hook wiring is whole-basename: check 11 fails" "$out" "[FAIL] 11."

# an explicitly allowlisted hook
UNW_EXTRA="printf 'new-hook.sh|ships unwired on purpose\n' >> \"\$REPO/scripts/testing/unwired-hooks-allowlist.txt\""
unw_run scripts/hooks/new-hook.sh
contains "allowlisted hook: check 11 passes" "$out" "[PASS] 11."

# scripts: unreferenced fails; a CI job naming it passes; a library sourced by it passes
UNW_EXTRA=''
unw_run scripts/tools/lonely.sh
contains "unreferenced script: check 11 fails" "$out" "[FAIL] 11."
UNW_EXTRA="printf 'run: bash scripts/tools/job.sh\n' > \"\$REPO/.github/workflows/ci.yml\""
unw_run scripts/tools/job.sh
contains "script named by a CI job: check 11 passes" "$out" "[PASS] 11."
UNW_EXTRA="printf 'run: bash scripts/tools/job.sh\n' > \"\$REPO/.github/workflows/ci.yml\"; printf 'source scripts/lib/helper-lib.sh\n' > \"\$REPO/scripts/tools/job.sh\""
unw_run scripts/tools/job.sh scripts/lib/helper-lib.sh
contains "library sourced by a wired script: check 11 passes" "$out" "[PASS] 11."
UNW_EXTRA="printf 'source scripts/lib/helper-lib.sh\n' > \"\$REPO/scripts/tools/job.sh\""
unw_run scripts/tools/job.sh scripts/lib/helper-lib.sh
contains "library sourced by an unwired script: check 11 fails" "$out" "[FAIL] 11."
contains "library sourced by an unwired script: names the library" "$out" "scripts/lib/helper-lib.sh"
UNW_EXTRA=''
unw_run scripts/tools/fixtures/sample.sh
contains "fixture path is standalone by design: check 11 passes" "$out" "[PASS] 11."

# skills and suites
unw_run .claude/skills/demo/SKILL.md
contains "skill under .claude/skills: check 11 passes" "$out" "[PASS] 11."
unw_run docs/demo/SKILL.md
contains "skill in an undiscovered directory: check 11 fails" "$out" "[FAIL] 11."
unw_run tests/test-lonely.sh
contains "suite outside the runner's scan roots: check 11 fails (run-shell-tests.sh never finds it)" "$out" "[FAIL] 11."
unw_run scripts/tools/test-found.sh
contains "suite under a scan root: check 11 passes" "$out" "[PASS] 11."

# test helpers: reached by the suite that uses them, but a plain script a suite alone names is not
UNW_EXTRA="mkdir -p \"\$REPO/scripts/cfg/tests\"; printf 'node stub-jira.js\n' > \"\$REPO/scripts/cfg/tests/test-cfg.sh\""
unw_run scripts/cfg/tests/stub-jira.js
contains "tests/ stub named by its suite: check 11 passes" "$out" "[PASS] 11."
UNW_EXTRA="printf 'source testlib-pass.sh\n' > \"\$REPO/scripts/tools/test-found.sh\""
unw_run scripts/tools/testlib-pass.sh
contains "testlib helper named by its suite: check 11 passes" "$out" "[PASS] 11."
UNW_EXTRA="mkdir -p \"\$REPO/scripts/g\"; printf 'python3 g-cases/a.py\n' > \"\$REPO/scripts/g/test-g.sh\""
unw_run scripts/g/g-cases/a.py
contains "-cases/ helper named by its suite: check 11 passes" "$out" "[PASS] 11."
UNW_EXTRA="printf 'bash lonely.sh\n' > \"\$REPO/scripts/tools/test-found.sh\""
unw_run scripts/tools/lonely.sh
contains "plain script named only by a suite: check 11 fails" "$out" "[FAIL] 11."
UNW_EXTRA="mkdir -p \"\$REPO/scripts/cfg/tests\""
unw_run scripts/cfg/tests/stub-orphan.js
contains "tests/ stub nothing names: check 11 fails" "$out" "[FAIL] 11."
UNW_EXTRA=''
unw_run scripts/cfg/tests/orphan.test.ts
contains "node/bun test file nothing runs: check 11 fails" "$out" "[FAIL] 11."
UNW_EXTRA="printf 'run: bun test scripts/cfg --dots\n' > \"\$REPO/.github/workflows/ci.yml\""
unw_run scripts/cfg/tests/ran.test.ts
contains "test file under a dir a CI job runs bun test on: check 11 passes" "$out" "[PASS] 11."
UNW_EXTRA="printf 'run: node --test \"scripts/cfg/tests/**/*.test.mjs\"\n' > \"\$REPO/.github/workflows/ci.yml\""
unw_run scripts/cfg/tests/globbed.test.mjs
contains "test file under a quoted-glob node --test job dir: check 11 passes" "$out" "[PASS] 11."
UNW_EXTRA="printf 'run: bun test scripts/other --dots\n' > \"\$REPO/.github/workflows/ci.yml\""
unw_run scripts/cfg/x.test.ts
contains "test file beside a dir a CI job runs bun test on: check 11 fails" "$out" "[FAIL] 11."
UNW_EXTRA="printf 'run: bun test scripts/cfg/tests/deep\n' > \"\$REPO/.github/workflows/ci.yml\""
unw_run scripts/cfg/y.test.ts
contains "test file above the dir a CI job runs bun test on: check 11 fails" "$out" "[FAIL] 11."

# a package.json "test" script wires a file only when its runner's discovery reaches it
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"bun test src\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "pkg test script scoped to src: file outside it fails" "$out" "[FAIL] 11."
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"bun test tests --dots\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "pkg test script scoped to tests: file under it passes" "$out" "[PASS] 11."
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"bun test\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "bare bun test script: file passes" "$out" "[PASS] 11."
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"bun test tests/a*.test.ts\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/abc.test.ts
contains "glob arg with a partial segment: a matching file passes" "$out" "[PASS] 11."
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"bun test .\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "bun test . discovers the whole package: passes" "$out" "[PASS] 11."
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"npm run build && bun test\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "compound test script: only the runner's own words narrow it" "$out" "[PASS] 11."
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"echo hi\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "pkg test script with no test runner: file fails" "$out" "[FAIL] 11."
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"node --test\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "node --test never discovers a .ts file: fails" "$out" "[FAIL] 11."
unw_run scripts/cfg/tests/a.test.mjs
contains "node --test discovers a .mjs file: passes" "$out" "[PASS] 11."

# a referencer counts only when it is itself wired
UNW_EXTRA="printf 'bun test scripts/cfg/x.test.ts\n' > \"\$REPO/scripts/tools/lonely.sh\""
unw_run scripts/cfg/x.test.ts scripts/tools/lonely.sh
contains "test file named only by an unwired added script: names the test" "$out" "scripts/cfg/x.test.ts"
UNW_EXTRA="printf 'run: bash scripts/tools/job.sh\n' > \"\$REPO/.github/workflows/ci.yml\"; printf 'bun test scripts/cfg/x.test.ts\n' > \"\$REPO/scripts/tools/job.sh\""
unw_run scripts/cfg/x.test.ts scripts/tools/job.sh
contains "test file named by a wired added script: check 11 passes" "$out" "[PASS] 11."

# scripts/hooks/<subdir>/ files are libraries judged by a wired sourcing hook
UNW_EXTRA=''
unw_run scripts/hooks/lib/newlib.sh
contains "hook library nothing sources: check 11 fails" "$out" "[FAIL] 11."
UNW_EXTRA="printf '{\"hooks\":\"scripts/hooks/new-hook.sh\"}\n' > \"\$REPO/.claude/settings.json\"; printf 'source lib/newlib.sh\n' > \"\$REPO/scripts/hooks/new-hook.sh\""
unw_run scripts/hooks/new-hook.sh scripts/hooks/lib/newlib.sh
contains "hook library sourced by a wired hook: check 11 passes" "$out" "[PASS] 11."
UNW_EXTRA="printf 'source lib/newlib.sh\n' > \"\$REPO/scripts/hooks/new-hook.sh\""
unw_run scripts/hooks/new-hook.sh scripts/hooks/lib/newlib.sh
contains "hook library sourced by an unwired hook: names the library" "$out" "scripts/hooks/lib/newlib.sh"

# precision: each of these is a false wired verdict
# a generic extensionless import (./index) of some OTHER module does not wire an added index.ts
UNW_EXTRA="mkdir -p \"\$REPO/scripts/cfg/src\"; printf \"import x from './index'\\n\" > \"\$REPO/scripts/cfg/other.ts\""
unw_run scripts/cfg/src/index.ts
contains "generic index.ts imported as some other ./index: check 11 fails" "$out" "[FAIL] 11."
UNW_EXTRA="mkdir -p \"\$REPO/scripts/cfg/src\"; printf \"import x from './src/index'\\n\" > \"\$REPO/scripts/cfg/other.ts\""
unw_run scripts/cfg/src/index.ts
contains "generic index.ts imported through its own directory: check 11 passes" "$out" "[PASS] 11."
UNW_EXTRA="printf \"import x from './index'\\n\" > \"\$REPO/scripts/cfg/src/consumer.ts\""
unw_run scripts/cfg/src/index.ts
contains "generic index.ts imported as ./index by a sibling: check 11 passes" "$out" "[PASS] 11."
UNW_EXTRA="printf \"import x from '../index'\\n\" > \"\$REPO/scripts/cfg/src/consumer.ts\""
unw_run scripts/cfg/src/index.ts
contains "a sibling's ../index is the parent's index, not this one: check 11 fails" "$out" "[FAIL] 11."
UNW_EXTRA="mkdir -p \"\$REPO/scripts/cfg/tests\"; printf \"import x from './utils'\\n\" > \"\$REPO/scripts/cfg/tests/a.test.ts\""
unw_run scripts/cfg/tests/utils.ts
contains "test helper utils.ts imported as ./utils by its test: check 11 passes" "$out" "[PASS] 11."
UNW_EXTRA="mkdir -p \"\$REPO/scripts/cfg/a.b\";printf \"import x from './aXb/index'\\n\" > \"\$REPO/scripts/cfg/other.ts\""
unw_run scripts/cfg/a.b/index.ts
contains "directory dot is literal: aXb/index does not wire a.b/index.ts" "$out" "[FAIL] 11."

# cd X && node build.js is not a test runner in a CI job
UNW_EXTRA="printf 'run: cd scripts/cfg && node build.js\n' > \"\$REPO/.github/workflows/ci.yml\""
unw_run scripts/cfg/a.test.ts
contains "cd dir then node build.js is not a test runner: check 11 fails" "$out" "[FAIL] 11."
UNW_EXTRA="printf 'run: cd scripts/cfg && bun test\n' > \"\$REPO/.github/workflows/ci.yml\""
unw_run scripts/cfg/a.test.ts
contains "cd dir then bun test is a test runner: check 11 passes" "$out" "[PASS] 11."

# a doc added in the same PR does not wire a script; a doc already in the tree does
UNW_EXTRA="mkdir -p \"\$REPO/docs\"; printf 'run bash scripts/tools/docd.sh\n' > \"\$REPO/docs/run-docd.md\""
unw_run scripts/tools/docd.sh docs/run-docd.md
contains "script named only by a doc added in the same PR: check 11 fails" "$out" "[FAIL] 11."
unw_run scripts/tools/docd.sh
contains "script named by a doc already in the tree: check 11 passes" "$out" "[PASS] 11."

# a test script that merely echoes a runner name runs nothing
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"echo bun test\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "echo bun test is not a runner: file fails" "$out" "[FAIL] 11."

# a glob arg is matched against the file name, not just its directory
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"bun test tests/a*.test.ts\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/zzz.test.ts
contains "glob arg a*.test.ts does not match zzz.test.ts: file fails" "$out" "[FAIL] 11."

# a wired referencer's dot is literal: a.b.sh is not the pending file aXb.sh
UNW_EXTRA="printf 'run: bash scripts/tools/a.b.sh\\n' > \"\$REPO/.github/workflows/ci.yml\"; printf 'bash target.sh\\n' > \"\$REPO/scripts/tools/a.b.sh\""
unw_run scripts/tools/target.sh scripts/tools/aXb.sh
notcontains "wired referencer a.b.sh is not mistaken for the pending aXb.sh" "$out" "UNWIRED scripts/tools/target.sh"
UNW_EXTRA=''

# referencer, glob and runner corners
# a fixture file naming a script is sample data, not wiring
UNW_EXTRA="mkdir -p \"\$REPO/scripts/tools/fixtures\"; printf 'bash scripts/tools/fxd.sh\n' > \"\$REPO/scripts/tools/fixtures/run.txt\""
unw_run scripts/tools/fxd.sh
contains "script named only by a fixtures/ file: check 11 fails" "$out" "[FAIL] 11."
UNW_EXTRA="mkdir -p \"\$REPO/scripts/tools/fixtures\"; printf 'bash scripts/tools/fxd.sh\n' > \"\$REPO/scripts/tools/fixtures/run.txt\"; printf 'run: bash scripts/tools/fxd.sh\n' > \"\$REPO/.github/workflows/ci.yml\""
unw_run scripts/tools/fxd.sh
contains "script named by a fixtures/ file AND a CI job: check 11 passes" "$out" "[PASS] 11."

# a brace glob arg is expanded: only its alternatives reach the file
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"bun test tests/{a,b}.test.ts\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/zzz.test.ts
contains "brace glob {a,b}.test.ts does not reach zzz.test.ts: file fails" "$out" "[FAIL] 11."
unw_run scripts/cfg/tests/b.test.ts
contains "brace glob {a,b}.test.ts reaches b.test.ts: file passes" "$out" "[PASS] 11."
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"bun test {src,tests}/a.test.ts\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "brace glob in the directory part: a file under an alternative passes" "$out" "[PASS] 11."

UNW_EXTRA="printf '{\"scripts\":{\"test\":\"bun test {,src/}tests\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "brace glob with an empty alternative: the empty one still matches" "$out" "[PASS] 11."
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"bun test tests/a{,x}.test.ts\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "brace glob with an empty alternative inside a name: a.test.ts matches" "$out" "[PASS] 11."

# node --import tsx --test is a test runner that loads a TS transform
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"node --import tsx --test\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "node --import tsx --test discovers a .ts file: passes" "$out" "[PASS] 11."
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"node --import=tsx --test tests\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "node --import=tsx --test tests: file under it passes" "$out" "[PASS] 11."
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"node --import tsx --test src\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "node --import tsx --test src: file outside it fails" "$out" "[FAIL] 11."
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"node --import tsx build.js\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "node --import tsx build.js is not a test runner: file fails" "$out" "[FAIL] 11."

UNW_EXTRA="printf '{\"scripts\":{\"test\":\"node --test tests --test-name-pattern=foo\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/other/z.test.mjs
contains "a later --test-name-pattern flag does not drop the tests path: outside file fails" "$out" "[FAIL] 11."

# mutation pins: the TS-transform markers in the test script
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"node --test --experimental-strip-types\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "node --test with strip-types discovers a .ts file: passes" "$out" "[PASS] 11."
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"node --test --import tsimp\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "node --test with --import discovers a .ts file: passes" "$out" "[PASS] 11."
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"node --test --loader ts-node\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "node --test with --loader discovers a .ts file: passes" "$out" "[PASS] 11."
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"node --require tsx/cjs --test\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.ts
contains "node --test with only a tsx marker discovers a .ts file: passes" "$out" "[PASS] 11."
# a flag takes the next word only when it is a valued flag; --test after a script is its argument
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"node --no-warnings build.js --test\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.mjs
contains "node --no-warnings build.js --test is not a test runner: file fails" "$out" "[FAIL] 11."
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"node --no-warnings --test\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.mjs
contains "node --no-warnings --test is a runner: file passes" "$out" "[PASS] 11."
UNW_EXTRA="printf '{\"scripts\":{\"test\":\"node -r ./setup.js --test\"}}\n' > \"\$REPO/scripts/cfg/package.json\""
unw_run scripts/cfg/tests/a.test.mjs
contains "node -r ./setup.js --test is a runner: file passes" "$out" "[PASS] 11."

# mutation pins: hook-library referencer branches
UNW_EXTRA="printf 'source h.sh\n' > \"\$REPO/scripts/hooks/test-hk.sh\""
unw_run scripts/hooks/test-hk.sh scripts/hooks/tests/h.sh
contains "hook lib in tests/ named by its wired suite: check 11 passes" "$out" "[PASS] 11."
unw_run scripts/hooks/test-hk.sh scripts/hooks/sub/h.sh
contains "hook lib outside a test dir named only by a suite: check 11 fails" "$out" "[FAIL] 11."
UNW_EXTRA="printf '{\"hooks\":\"scripts/hooks/new-hook.sh\"}\n' > \"\$REPO/.claude/settings.json\"; printf 'source lib/a.sh\n' > \"\$REPO/scripts/hooks/new-hook.sh\"; printf 'source b.sh\n' > \"\$REPO/scripts/hooks/lib/a.sh\""
unw_run scripts/hooks/new-hook.sh scripts/hooks/lib/a.sh scripts/hooks/lib/b.sh
contains "hook lib sourced by a lib a wired hook sources: check 11 passes" "$out" "[PASS] 11."
UNW_EXTRA="printf 'source b.sh\n' > \"\$REPO/scripts/hooks/lib/a.sh\""
unw_run scripts/hooks/lib/a.sh scripts/hooks/lib/b.sh
contains "hook lib sourced only by an unwired added lib: check 11 fails" "$out" "[FAIL] 11."
UNW_EXTRA="printf 'source b.sh\n' > \"\$REPO/scripts/hooks/lib/old.sh\""
unw_run scripts/hooks/lib/b.sh
contains "hook lib sourced by a lib already in the tree: check 11 passes" "$out" "[PASS] 11."

# mutation pins: a non-generic TS stem is matched as an extensionless import
UNW_EXTRA="mkdir -p \"\$REPO/scripts/cfg/src\"; printf \"import x from './sector.js'\\n\" > \"\$REPO/scripts/cfg/src/consumer.ts\""
unw_run scripts/cfg/src/sector.ts
contains "non-generic sector.ts imported as ./sector.js: check 11 passes" "$out" "[PASS] 11."
UNW_EXTRA="mkdir -p \"\$REPO/scripts/cfg/src\"; printf \"import x from './sector'\\n\" > \"\$REPO/scripts/cfg/src/consumer.ts\""
unw_run scripts/cfg/src/sector.ts
contains "non-generic sector.ts imported as ./sector: check 11 passes" "$out" "[PASS] 11."
UNW_EXTRA="mkdir -p \"\$REPO/scripts/cfg/src\"; printf \"import x from './sectors'\\n\" > \"\$REPO/scripts/cfg/src/consumer.ts\""
unw_run scripts/cfg/src/sector.ts
contains "non-generic sector.ts is not wired by ./sectors: check 11 fails" "$out" "[FAIL] 11."
UNW_EXTRA=''

# an unreadable ref exits 2 even when the only file is an extensionless executable
rc=0; out=$(cd "$REPO" && bash "$HERE/../../testing/check-added-unwired.sh" 0000000000000000000000000000000000000000 scripts/tools/runme 2>&1) || rc=$?
check "unreadable ref with an extensionless file: exit 2" "$rc" "2"
UNW_EXTRA=''

# existing debt is never judged: the same unwired hook, status modified
git -C "$REPO" checkout -q --detach "$UNW_BASE" && git -C "$REPO" clean -fdq
mkdir -p "$REPO/scripts/hooks" && printf '#!/usr/bin/env bash\n' > "$REPO/scripts/hooks/old-hook.sh"
git -C "$REPO" add -A && git -C "$REPO" commit -q -m "feat: [HIMMEL-1] touch old hook"
SHA=$(git -C "$REPO" rev-parse HEAD); seed_ledger_ok; reset_stubs
STUB_HEAD="$SHA"; STUB_FILES="scripts/hooks/old-hook.sh"; STUB_FILE_STATUS="modified scripts/hooks/old-hook.sh"
rc=0; out="$(run)" || rc=$?
SHA="$UNW_REAL_SHA"
contains "modified (not added) unwired hook is not judged: check 11 passes" "$out" "[PASS] 11."
reset_stubs

# --- 12. computed TRUST-PATH line: from the PR diff against the default
# branch's list, never from any READY text ---------------------------------------
reset_stubs
rc=0; out="$(run)" || rc=$?
check "trust: docs/script-only diff exit 0" "$rc" "0"
contains "trust: a non-trust diff prints no" "$out" "TRUST-PATH: no"
notcontains "trust: a non-trust diff never prints yes" "$out" "TRUST-PATH: yes"
trust_line_pos=$(printf '%s\n' "$out" | grep -n '^TRUST-PATH:' | cut -d: -f1)
verdict_pos=$(printf '%s\n' "$out" | grep -n '^READY-CHECK ' | cut -d: -f1)
check "trust: the line comes before the verdict" "$((trust_line_pos < verdict_pos))" "1"

reset_stubs
STUB_FILES="scripts/lib/fixtures/anything.txt"
rc=0; out="$(run)" || rc=$?
contains "trust: scripts/lib/fixtures diff (PR 2475 shape) prints yes" "$out" "TRUST-PATH: yes"
notcontains "trust: fixtures diff never prints no" "$out" "TRUST-PATH: no"
contains "trust: a yes line is not a failure of the check" "$out" "[PASS] 12."

reset_stubs
STUB_FILES="scripts/lib/env-alias.sh"
STUB_BODY='## Ticket coverage\n- ask: done\n\nTRUST PATH: none touched\n'
rc=0; out="$(run)" || rc=$?
contains "trust: scripts/lib/env-alias.sh diff (PR 2885 shape) prints yes whatever the body claims" "$out" "TRUST-PATH: yes"

reset_stubs
STUB_TRUST_LIST_FAIL=1
rc=0; out="$(run)" || rc=$?
check "trust: unreadable list exits 1" "$rc" "1"
contains "trust: unreadable list fails check 12" "$out" "[FAIL] 12."
notcontains "trust: unreadable list never prints no" "$out" "TRUST-PATH: no"
contains "trust: unreadable list ends in FAIL" "$out" "READY-CHECK FAIL"

reset_stubs
STUB_DEFAULT_BRANCH_FAIL=1
rc=0; out="$(run)" || rc=$?
check "trust: unresolvable default branch exits 1" "$rc" "1"
contains "trust: unresolvable default branch fails check 12" "$out" "[FAIL] 12."
notcontains "trust: unresolvable default branch never prints no" "$out" "TRUST-PATH: no"

# --only 7 stays a coverage-only lint: no trust check
reset_stubs
rc=0; out=$(cd "$REPO" && STUB_BODY="$GREEN_BODY" STUB_TRUST_LIST_FILE="$TRUST_LIST_FILE" JIRA_CMD="$tmp/bin/jira-stub" STUB_JIRA_DB="$JIRA_DB" JIRA_PROJECT_KEY=HIMMEL STUB_HEAD="$SHA" bash "$SCRIPT" --only 7 "$PR" 2>&1) || rc=$?
notcontains "trust: --only 7 prints no TRUST-PATH line" "$out" "TRUST-PATH:"
reset_stubs

echo "---"
if [ "$fails" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "$fails FAILED"
    exit 1
fi
