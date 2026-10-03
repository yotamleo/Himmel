#!/usr/bin/env bash
# scripts/handover/console-kit/test-ready-check.sh — suite for ready-check.sh
# (HIMMEL-3163). `gh` is a PATH stub (contract requirement — not GH_CMD, even
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
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
args="$*"
case "$args" in
    "repo view --json owner,name"*)
        printf '%s\n' "${STUB_NWO:-acme/repo}" ;;
    *"--json headRefOid,mergeStateStatus"*)
        printf '%s %s\n' "${STUB_HEAD:-}" "${STUB_MSS:-CLEAN}" ;;
    *"--json statusCheckRollup"*)
        printf '%s' "${STUB_ROLLUP:-[]}" ;;
    *"--json commits"*)
        printf '%s' "${STUB_COMMITS:-[]}" ;;
    *"--json body"*)
        printf '%b' "${STUB_BODY:-}" ;;
    *"commits(first:100)"*)
        printf '%s\n' "${STUB_MERGE_OIDS:-}" ;;
    *"api graphql"*)
        printf '%s %s %s\n' "${STUB_UNRESOLVED:-0}" "false" "null" ;;
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
export GH_LOG
PATH="$tmp/bin:$PATH"
export PATH

# ── shared green defaults ───────────────────────────────────────────────
GREEN_ROLLUP='[{"name":"build","status":"COMPLETED","conclusion":"SUCCESS"},{"context":"legacy-ci","state":"SUCCESS"}]'
GREEN_COMMITS='[{"messageHeadline":"feat(x): [HIMMEL-1] add thing","messageBody":"Platforms tested: linux\nSecurity reviewed: manual"},{"messageHeadline":"fix(x): [HIMMEL-2] tweak","messageBody":""}]'
GREEN_FILES="scripts/handover/console-kit/ready-check.sh"
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
        STUB_BODY="${STUB_BODY-$GREEN_BODY}" \
        JIRA_CMD="$tmp/bin/jira-stub" STUB_JIRA_DB="$JIRA_DB" STUB_JIRA_DOWN="${STUB_JIRA_DOWN:-}" \
        PATH="$PATH" GH_LOG="$GH_LOG" \
        bash "$SCRIPT" "$PR" "$SHA")
}

reset_stubs() {
    unset STUB_HEAD STUB_MSS STUB_ROLLUP STUB_UNRESOLVED STUB_COMMITS STUB_MERGE_OIDS STUB_FILES STUB_FILES_FAIL STUB_BODY STUB_JIRA_DOWN
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
rc=0; out="$(run)" || rc=$?
check "green: exit 0" "$rc" "0"
contains "green: overall verdict" "$out" "READY-CHECK PASS"
contains "green: check 1 passes" "$out" "[PASS] 1."
contains "green: check 2 passes" "$out" "[PASS] 2."
contains "green: check 3 passes" "$out" "[PASS] 3."
contains "green: check 4 passes" "$out" "[PASS] 4."
contains "green: check 5 passes" "$out" "[PASS] 5."
contains "green: check 6 passes" "$out" "[PASS] 6."
contains "green: names the diff read as the console's job" "$out" "stays the console's own judgement"

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

# --- 2c. HIMMEL-3690: same check name CANCELLED earlier, SUCCESS later —
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
# item 2 FAILs (HIMMEL-3690 codex-1: an untimed later run must not lose to an
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

# --- 5d. check 5 fails: PR files unreadable (API call failed) -----------
reset_stubs
STUB_FILES_FAIL=1
rc=0; out="$(run)" || rc=$?
check "files-unreadable: exit 1" "$rc" "1"
contains "files-unreadable: check 5 fails" "$out" "[FAIL] 5. cannot read PR files"

# --- 5e. check 5 reads ONLY the first commit (HIMMEL-4128) --------------
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

# --- 6b. HIMMEL-3586: a merge commit (>1 parent) is exempt from check 6,
# even though its subject carries no ticket ID -------------------------
reset_stubs
MERGE_OID=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
STUB_FILES="docs/handover/running-a-console.md"
STUB_COMMITS='[{"oid":"'"$MERGE_OID"'","messageHeadline":"Merge remote-tracking branch '"'"'origin/main'"'"' into fix/x","messageBody":""},{"oid":"1111111111111111111111111111111111111a","messageHeadline":"fix(x): [HIMMEL-1] tweak","messageBody":""}]'
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
STUB_COMMITS='[{"oid":"'"$MERGE_OID"'","messageHeadline":"Merge remote-tracking branch '"'"'origin/main'"'"' into fix/x","messageBody":""},{"oid":"1111111111111111111111111111111111111a","messageHeadline":"fix(x): tweak with no ticket","messageBody":"Platforms tested: linux\nSecurity reviewed: manual"}]'
rc=0; out="$(run)" || rc=$?
check "merge-plus-unticketed: exit 1" "$rc" "1"
contains "merge-plus-unticketed: check 6 fails" "$out" "[FAIL] 6."
contains "merge-plus-unticketed: names the offending subject, not the merge" "$out" "tweak with no ticket"

# --- 7. HIMMEL-4207: ticket coverage. The PR body needs a `## Ticket coverage`
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

# codex-1: `done` must be the line's terminal disposition, not a substring
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

# codex-2: a successful jira get with a blank status is UNKNOWN, never open
reset_stubs
STUB_BODY='## Ticket coverage\n- ask one: deferred -> HIMMEL-54\n'
rc=0; out="$(run)" || rc=$?
check "coverage blank jira status: exit 1" "$rc" "1"
contains "coverage blank jira status: reads UNKNOWN" "$out" "UNKNOWN"

# round 2: a deferral must also END the line, and a delimiter-free jira reply is not a status
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

# --- 8. HIMMEL-3533: TICKET_ID_PATTERN / JIRA_PROJECT_KEY must resolve from
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
printf 'JIRA_PROJECT_KEY=HIMMEL\n' > "$own/.env"

reset_stubs
STUB_COMMITS="$GREEN_COMMITS"
rc=0
out="$(cd "$REPO" && env -u TICKET_ID_PATTERN -u JIRA_PROJECT_KEY \
    STUB_NWO="$NWO" STUB_HEAD="$SHA" STUB_MSS=CLEAN \
    STUB_ROLLUP="$GREEN_ROLLUP" STUB_UNRESOLVED=0 \
    STUB_COMMITS="$STUB_COMMITS" STUB_FILES="$GREEN_FILES" \
    STUB_BODY="$GREEN_BODY" JIRA_CMD="$tmp/bin/jira-stub" STUB_JIRA_DB="$JIRA_DB" \
    PATH="$PATH" GH_LOG="$GH_LOG" \
    bash "$own/scripts/handover/console-kit/ready-check.sh" "$PR" "$SHA")" || rc=$?
check "own-checkout .env: exit 0" "$rc" "0"
contains "own-checkout .env: check 6 (ticket ID) passes" "$out" "[PASS] 6."

echo "---"
if [ "$fails" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "$fails FAILED"
    exit 1
fi
