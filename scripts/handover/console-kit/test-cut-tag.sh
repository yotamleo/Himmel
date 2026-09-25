#!/usr/bin/env bash
# scripts/handover/console-kit/test-cut-tag.sh - suite for cut-tag.sh
# (HIMMEL-3572 row 6). Hermetic: `gh` is stubbed via GH_BIN, `git` via a PATH
# stub dir prepended ahead of the real git, both driven by env vars and both
# logging every invocation to CALLS so a case can assert what was (and was
# NOT) called - e.g. --dry-run must never call the ref-create endpoint.
#
# Cases:
#   1.  usage: no args / 1 arg / bad version / bad sha / unknown flag /
#       --version-override with no reason           -> rc 2, nothing called
#   2.  sha not an ancestor of origin/main            -> rc 3
#   3.  version already tagged on origin              -> rc 5
#   4.  version out of sequence, no override           -> rc 6
#   5.  version out of sequence WITH --version-override -> rc 0, reason echoed
#   6.  no check-runs at all                          -> rc 4
#   7.  a red check-run                               -> rc 4 (RED control)
#   8.  combined status failure with any statuses      -> rc 4
#   9.  --dry-run on an otherwise-clean sha            -> rc 0, ref-create NOT called
#   10. clean sha, in-sequence version                -> rc 0, ref-create called once,
#       then git fetch --tags
#   11. gh repo view / origin remote mismatch          -> rc 1
#   12. origin remote URL unresolvable (RED)           -> rc 1
#   13. series ls-remote failure (RED)                 -> rc 1
#   14. check-runs gh api failure (RED)                -> rc 4
#   15. combined status gh api failure (RED)           -> rc 4
#   16. option-shaped / empty --version-override reason (RED) -> rc 2, nothing called
#
# Platform guard: Linux/macOS bash 3.2+.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/cut-tag.sh"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/cut-tag-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
fails=0
check()    { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); fi; }
contains() { if grep -q -F -e "$3" <<< "$2"; then echo "ok - $1"; else echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)); fi; }
not_contains() { if grep -q -F -e "$3" <<< "$2"; then echo "FAIL - $1: output unexpectedly contains [$3]"; fails=$((fails+1)); else echo "ok - $1"; fi; }

SHA=0123456789abcdef0123456789abcdef01234567
CALLS="$tmp/calls.log"

# ---- gh stub ----------------------------------------------------------------
GH_STUB="$tmp/gh"
cat > "$GH_STUB" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$CALLS_LOG"
RUNS_DEFAULT='{"total_count":1,"check_runs":[{"name":"ci","status":"completed","conclusion":"success"}]}'
STATUS_DEFAULT='{"state":"success","total_count":0}'
CI_RUNS_DEFAULT='{"workflow_runs":[{"name":"CI","status":"completed","conclusion":"success"}]}'
case "$1 $2" in
  "repo view")
    [ "${CT_NWO_MISMATCH:-0}" = "1" ] && { echo "octo-other/demo"; exit 0; }
    echo '{"owner":{"login":"octo"},"name":"demo"}' | jq -r '"\(.owner.login)/\(.name)"'
    exit 0 ;;
esac
case "$*" in
  *"commits/$SHA_ENV/check-runs"*)
    [ "${CT_RUNS_FAIL:-0}" = "1" ] && exit 1
    printf '%s' "${CT_RUNS_JSON:-$RUNS_DEFAULT}"
    exit 0 ;;
  *"commits/$SHA_ENV/status"*)
    [ "${CT_STATUS_FAIL:-0}" = "1" ] && exit 1
    printf '%s' "${CT_STATUS_JSON:-$STATUS_DEFAULT}"
    exit 0 ;;
  *"actions/runs?head_sha=$SHA_ENV"*)
    [ "${CT_CI_RUNS_FAIL:-0}" = "1" ] && exit 1
    printf '%s' "${CT_CI_RUNS_JSON:-$CI_RUNS_DEFAULT}"
    exit 0 ;;
  *"git/refs -f"*)
    [ "${CT_CREATE_FAIL:-0}" = "1" ] && exit 1
    exit 0 ;;
esac
echo "gh-stub: unhandled args: $*" >&2
exit 1
STUB
chmod +x "$GH_STUB"

# ---- git PATH stub (shadows real git for the subcommands cut-tag.sh uses) --
GIT_STUB_DIR="$tmp/bin"; mkdir -p "$GIT_STUB_DIR"
cat > "$GIT_STUB_DIR/git" <<'STUB'
#!/usr/bin/env bash
echo "git $*" >> "$CALLS_LOG"
case "$1 $2" in
  "remote get-url")
    [ "${CT_ORIGIN_URL_FAIL:-0}" = "1" ] && exit 1
    printf '%s\n' "${CT_ORIGIN_URL:-https://github.com/octo/demo.git}"
    exit 0 ;;
esac
case "$1 $2 $3" in
  "fetch origin main")
    [ "${CT_FETCH_FAIL:-0}" = "1" ] && exit 1
    exit 0 ;;
  "fetch origin --tags")
    exit 0 ;;
esac
case "$1 $2" in
  "merge-base --is-ancestor")
    [ "${CT_ANCESTOR_BAD:-0}" = "1" ] && exit 1
    exit 0 ;;
esac
case "$*" in
  "ls-remote --exit-code --tags origin "*)
    [ "${CT_TAG_EXISTS:-0}" = "1" ] && exit 0
    exit 2 ;;
  "ls-remote --tags origin "*)
    [ "${CT_SERIES_LS_FAIL:-0}" = "1" ] && exit 1
    printf '%s\n' "${CT_SERIES_TAGS:-}"
    exit 0 ;;
esac
echo "git-stub: unhandled args: $*" >&2
exit 1
STUB
chmod +x "$GIT_STUB_DIR/git"

run() { # run <version> <sha> [more args...] - runs the script under test
    CALLS_LOG="$CALLS" PATH="$GIT_STUB_DIR:$PATH" GH_BIN="$GH_STUB" SHA_ENV="$SHA" \
        CT_ANCESTOR_BAD="${CT_ANCESTOR_BAD:-0}" CT_TAG_EXISTS="${CT_TAG_EXISTS:-0}" \
        CT_SERIES_TAGS="${CT_SERIES_TAGS:-}" CT_FETCH_FAIL="${CT_FETCH_FAIL:-0}" \
        CT_RUNS_JSON="${CT_RUNS_JSON:-}" CT_STATUS_JSON="${CT_STATUS_JSON:-}" \
        CT_CI_RUNS_JSON="${CT_CI_RUNS_JSON:-}" CT_CI_RUNS_FAIL="${CT_CI_RUNS_FAIL:-0}" \
        CT_CREATE_FAIL="${CT_CREATE_FAIL:-0}" \
        CT_ORIGIN_URL="${CT_ORIGIN_URL:-}" CT_ORIGIN_URL_FAIL="${CT_ORIGIN_URL_FAIL:-0}" \
        CT_NWO_MISMATCH="${CT_NWO_MISMATCH:-0}" CT_SERIES_LS_FAIL="${CT_SERIES_LS_FAIL:-0}" \
        CT_RUNS_FAIL="${CT_RUNS_FAIL:-0}" CT_STATUS_FAIL="${CT_STATUS_FAIL:-0}" \
        bash "$SCRIPT" "$@"
}
reset_calls() { : > "$CALLS"; }
unset CT_ANCESTOR_BAD CT_TAG_EXISTS CT_SERIES_TAGS CT_FETCH_FAIL CT_RUNS_JSON CT_STATUS_JSON CT_CREATE_FAIL
unset CT_ORIGIN_URL CT_ORIGIN_URL_FAIL CT_NWO_MISMATCH CT_SERIES_LS_FAIL CT_RUNS_FAIL CT_STATUS_FAIL
unset CT_CI_RUNS_JSON CT_CI_RUNS_FAIL

CLEAN_VERSION="v0.3.0-pre.9"
CT_SERIES_TAGS_DEFAULT="aaaa1111	refs/tags/v0.3.0-pre.6
bbbb2222	refs/tags/v0.3.0-pre.7
cccc3333	refs/tags/v0.3.0-pre.8"

# --- 1. usage ------------------------------------------------------------
for args in "" "v0.3.0-pre.9" "bad-version $SHA" "v0.3.0-pre.9 tooshort" "v0.3.0-pre.9 $SHA --nope" "v0.3.0-pre.9 $SHA --version-override" "v0a.3.0-pre.9 $SHA" "v0.3.0-pre.9a $SHA" "v0.3.0.1-pre.9 $SHA"; do
    reset_calls
    rc=0
    # shellcheck disable=SC2086
    run $args >/dev/null 2>&1 || rc=$?
    check "usage: [$args] -> exit 2" "$rc" "2"
    check "usage: [$args] -> nothing called" "$(cat "$CALLS")" ""
done

# --- 2. sha not ancestor ---------------------------------------------------
reset_calls
rc=0; out=$(CT_ANCESTOR_BAD=1 run "$CLEAN_VERSION" "$SHA" 2>&1) || rc=$?
check "ancestor: rc 3" "$rc" "3"
contains "ancestor: names the reason" "$out" "not an ancestor"

# --- 3. tag already exists --------------------------------------------------
reset_calls
rc=0; out=$(CT_TAG_EXISTS=1 run "$CLEAN_VERSION" "$SHA" 2>&1) || rc=$?
check "exists: rc 5" "$rc" "5"
contains "exists: names the reason" "$out" "already exists"

# --- 4. out of sequence, no override ---------------------------------------
reset_calls
rc=0; out=$(CT_SERIES_TAGS="$CT_SERIES_TAGS_DEFAULT" run "v0.3.0-pre.11" "$SHA" 2>&1) || rc=$?
check "sequence: rc 6" "$rc" "6"
contains "sequence: names next expected" "$out" "next is v0.3.0-pre.9"

# --- 5. out of sequence WITH override ---------------------------------------
reset_calls
rc=0; out=$(CT_SERIES_TAGS="$CT_SERIES_TAGS_DEFAULT" run "v0.3.0-pre.11" "$SHA" --version-override "hotfix re-cut" 2>&1) || rc=$?
check "override: rc 0" "$rc" "0"
contains "override: reason echoed" "$out" "hotfix re-cut"
contains "override: ref created" "$(cat "$CALLS")" "git/refs -f ref=refs/tags/v0.3.0-pre.11"

# --- 6. no check-runs --------------------------------------------------------
reset_calls
rc=0; out=$(CT_SERIES_TAGS="$CT_SERIES_TAGS_DEFAULT" CT_RUNS_JSON='{"total_count":0,"check_runs":[]}' run "$CLEAN_VERSION" "$SHA" 2>&1) || rc=$?
check "no-runs: rc 4" "$rc" "4"
contains "no-runs: names the reason" "$out" "no check-runs"

# --- 7. a red check-run (RED control) ---------------------------------------
reset_calls
rc=0; out=$(CT_SERIES_TAGS="$CT_SERIES_TAGS_DEFAULT" CT_RUNS_JSON='{"total_count":1,"check_runs":[{"name":"unit","status":"completed","conclusion":"failure"}]}' run "$CLEAN_VERSION" "$SHA" 2>&1) || rc=$?
check "red-run: rc 4" "$rc" "4"
contains "red-run: names the failing run" "$out" "unit="

# --- 8. combined status failure with statuses present -----------------------
reset_calls
rc=0; out=$(CT_SERIES_TAGS="$CT_SERIES_TAGS_DEFAULT" CT_STATUS_JSON='{"state":"failure","total_count":2}' run "$CLEAN_VERSION" "$SHA" 2>&1) || rc=$?
check "combined-status: rc 4" "$rc" "4"
contains "combined-status: names it" "$out" "combined commit status"

# --- 9. --dry-run: no write --------------------------------------------------
reset_calls
rc=0; out=$(CT_SERIES_TAGS="$CT_SERIES_TAGS_DEFAULT" run "$CLEAN_VERSION" "$SHA" --dry-run 2>&1) || rc=$?
check "dry-run: rc 0" "$rc" "0"
contains "dry-run: prints the plan" "$out" "DRY RUN"
not_contains "dry-run: never calls the ref-create endpoint" "$(cat "$CALLS")" "git/refs -f"

# --- 10. clean success path --------------------------------------------------
reset_calls
rc=0; out=$(CT_SERIES_TAGS="$CT_SERIES_TAGS_DEFAULT" run "$CLEAN_VERSION" "$SHA" 2>&1) || rc=$?
check "success: rc 0" "$rc" "0"
contains "success: created message" "$out" "created refs/tags/$CLEAN_VERSION"
calls="$(cat "$CALLS")"
check "success: ref-create called exactly once" "$(grep -c 'git/refs -f' <<< "$calls")" "1"
create_line="$(grep -n 'git/refs -f' <<< "$calls" | head -1 | cut -d: -f1)"
fetch_line="$(grep -n 'git fetch origin --tags' <<< "$calls" | head -1 | cut -d: -f1)"
order_ok=no
[ -n "$create_line" ] && [ -n "$fetch_line" ] && [ "$create_line" -lt "$fetch_line" ] && order_ok=yes
check "success: fetches tags after write" "$order_ok" "yes"

# --- 11. gh repo view / origin remote mismatch --------------------------------
reset_calls
rc=0; out=$(CT_NWO_MISMATCH=1 run "$CLEAN_VERSION" "$SHA" 2>&1) || rc=$?
check "nwo-mismatch: rc 1" "$rc" "1"
contains "nwo-mismatch: names both repos" "$out" "octo-other/demo"
not_contains "nwo-mismatch: never writes the tag" "$(cat "$CALLS")" "git/refs -f"

# --- 12. origin remote URL unresolvable (RED: must refuse, not proceed) -------
reset_calls
rc=0; out=$(CT_ORIGIN_URL_FAIL=1 run "$CLEAN_VERSION" "$SHA" 2>&1) || rc=$?
check "origin-url-fail: rc 1" "$rc" "1"
not_contains "origin-url-fail: never writes the tag" "$(cat "$CALLS")" "git/refs -f"

# --- 13. series ls-remote failure (RED: must NOT read as "no tags") -----------
reset_calls
rc=0; out=$(CT_SERIES_LS_FAIL=1 run "$CLEAN_VERSION" "$SHA" 2>&1) || rc=$?
check "series-ls-fail: rc 1" "$rc" "1"
contains "series-ls-fail: names the reason" "$out" "ls-remote"
not_contains "series-ls-fail: never writes the tag" "$(cat "$CALLS")" "git/refs -f"

# --- 14. check-runs gh api failure (RED: must NOT read as clean) --------------
reset_calls
rc=0; out=$(CT_SERIES_TAGS="$CT_SERIES_TAGS_DEFAULT" CT_RUNS_FAIL=1 run "$CLEAN_VERSION" "$SHA" 2>&1) || rc=$?
check "runs-fail: rc 4" "$rc" "4"
not_contains "runs-fail: never writes the tag" "$(cat "$CALLS")" "git/refs -f"

# --- 15. combined status gh api failure (RED: must NOT read as clean) ---------
reset_calls
rc=0; out=$(CT_SERIES_TAGS="$CT_SERIES_TAGS_DEFAULT" CT_STATUS_FAIL=1 run "$CLEAN_VERSION" "$SHA" 2>&1) || rc=$?
check "status-fail: rc 4" "$rc" "4"
not_contains "status-fail: never writes the tag" "$(cat "$CALLS")" "git/refs -f"

# --- 17. Pages-only check-runs, no CI workflow run (HIMMEL-3627 vacuous-pass bug) ---
reset_calls
PAGES_ONLY_RUNS='{"total_count":3,"check_runs":[{"name":"build","status":"completed","conclusion":"success"},{"name":"deploy","status":"completed","conclusion":"success"},{"name":"report-build-status","status":"completed","conclusion":"success"}]}'
rc=0; out=$(CT_SERIES_TAGS="$CT_SERIES_TAGS_DEFAULT" CT_RUNS_JSON="$PAGES_ONLY_RUNS" CT_CI_RUNS_JSON='{"workflow_runs":[]}' run "$CLEAN_VERSION" "$SHA" 2>&1) || rc=$?
check "pages-only: rc 4" "$rc" "4"
contains "pages-only: names the missing CI run" "$out" "CI workflow run"
not_contains "pages-only: never writes the tag" "$(cat "$CALLS")" "git/refs -f"

# --- 18. CI workflow run queued -------------------------------------------------
reset_calls
rc=0; out=$(CT_SERIES_TAGS="$CT_SERIES_TAGS_DEFAULT" CT_CI_RUNS_JSON='{"workflow_runs":[{"name":"CI","status":"queued","conclusion":null}]}' run "$CLEAN_VERSION" "$SHA" 2>&1) || rc=$?
check "ci-queued: rc 4" "$rc" "4"
contains "ci-queued: names the status" "$out" "queued"
not_contains "ci-queued: never writes the tag" "$(cat "$CALLS")" "git/refs -f"

# --- 19. CI workflow run in_progress --------------------------------------------
reset_calls
rc=0; out=$(CT_SERIES_TAGS="$CT_SERIES_TAGS_DEFAULT" CT_CI_RUNS_JSON='{"workflow_runs":[{"name":"CI","status":"in_progress","conclusion":null}]}' run "$CLEAN_VERSION" "$SHA" 2>&1) || rc=$?
check "ci-in-progress: rc 4" "$rc" "4"
contains "ci-in-progress: names the status" "$out" "in_progress"
not_contains "ci-in-progress: never writes the tag" "$(cat "$CALLS")" "git/refs -f"

# --- 20. CI workflow run completed/cancelled ------------------------------------
reset_calls
rc=0; out=$(CT_SERIES_TAGS="$CT_SERIES_TAGS_DEFAULT" CT_CI_RUNS_JSON='{"workflow_runs":[{"name":"CI","status":"completed","conclusion":"cancelled"}]}' run "$CLEAN_VERSION" "$SHA" 2>&1) || rc=$?
check "ci-cancelled: rc 4" "$rc" "4"
contains "ci-cancelled: names the conclusion" "$out" "cancelled"
not_contains "ci-cancelled: never writes the tag" "$(cat "$CALLS")" "git/refs -f"

# --- 21. CI actions/runs gh api failure (RED: must NOT read as clean) -----------
reset_calls
rc=0; out=$(CT_SERIES_TAGS="$CT_SERIES_TAGS_DEFAULT" CT_CI_RUNS_FAIL=1 run "$CLEAN_VERSION" "$SHA" 2>&1) || rc=$?
check "ci-runs-fail: rc 4" "$rc" "4"
not_contains "ci-runs-fail: never writes the tag" "$(cat "$CALLS")" "git/refs -f"

# --- 16. option-shaped / empty --version-override reason (RED: must not become the reason) ---
reset_calls
rc=0; out=$(run "$CLEAN_VERSION" "$SHA" --version-override --dry-run 2>&1) || rc=$?
check "override-reason-option-shaped: rc 2" "$rc" "2"
check "override-reason-option-shaped: nothing called" "$(cat "$CALLS")" ""

reset_calls
rc=0; out=$(run "$CLEAN_VERSION" "$SHA" --version-override "" 2>&1) || rc=$?
check "override-reason-empty: rc 2" "$rc" "2"
check "override-reason-empty: nothing called" "$(cat "$CALLS")" ""

echo "----"
if [ "$fails" -eq 0 ]; then
    echo "ALL OK"
    exit 0
else
    echo "FAILURES: $fails"
    exit 1
fi
