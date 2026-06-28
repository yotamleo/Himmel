#!/usr/bin/env bash
# Smoke test for scripts/handover/generate-morning-briefing.sh
# (HIMMEL-135 core + HIMMEL-574 morning-report schema).
#
# Assertions match ASCII substrings only — both the 🌅/✅/🔴/🧹/📋 emoji and
# the em-dash separator are multibyte; MINGW `grep -qF` can SIGABRT on those,
# so every header is matched by an ASCII tail ("Morning Report", "Completed (",
# "In-flight WIP", "Stale worktrees", "Backlog (", "TL;DR", "Suggested order").
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/generate-morning-briefing.sh"

# Hermetic: neutralize env the script reads, so an operator's exported
# MORNING_REPORT_LLM (would flip on --llm → a real claude call mid-suite) or
# FORGE (would override the per-test remote-URL forge detection) can't leak in.
export MORNING_REPORT_LLM=0
unset FORGE 2>/dev/null || true

PASS=0
FAIL=0
TMP_ROOT=""

# shellcheck disable=SC2329,SC2317
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }
assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then pass "$name"; else fail "$name" "missing: $needle"; fi
}

TMP_ROOT=$(mktemp -d)
if command -v cygpath >/dev/null 2>&1; then TMP_ROOT=$(cygpath -m "$TMP_ROOT"); fi

# Fake gh + jira + claude CLIs -----------------------------------------

FAKE_GH="$TMP_ROOT/gh-fake.sh"
cat >"$FAKE_GH" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
    "pr list")
        # --search present => merged date query; else the all-state PR map.
        if printf '%s ' "$@" | grep -q -- '--search'; then
            printf '%s\n' "${FAKE_GH_PR_JSON:-[]}"
        else
            printf '%s\n' "${FAKE_GH_PR_ALL:-[]}"
        fi
        ;;
esac
exit 0
FAKE
chmod +x "$FAKE_GH"

FAKE_JIRA="$TMP_ROOT/jira-fake.sh"
cat >"$FAKE_JIRA" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
    list)
        status=""; prev=""
        for a in "$@"; do [ "$prev" = "--status" ] && status="$a"; prev="$a"; done
        case "$status" in
            "To Do")        printf '%s\n' "${FAKE_JIRA_TODO:-}";;
            "In Progress")  printf '%s\n' "${FAKE_JIRA_INPROG:-}";;
            *)              printf '%s\n' "${FAKE_JIRA_OUT:-}";;   # Done cross-ref
        esac ;;
esac
exit 0
FAKE
chmod +x "$FAKE_JIRA"

FAKE_CLAUDE="$TMP_ROOT/claude-fake.sh"
cat >"$FAKE_CLAUDE" <<'FAKE'
#!/usr/bin/env bash
# Emits sentinel blocks (with surrounding chrome) regardless of prompt; exit 0.
cat <<'OUT'
some preamble chrome
<<<TLDR_BEGIN>>>
LLM TL;DR line one
LLM TL;DR line two
<<<TLDR_END>>>
<<<ORDER_BEGIN>>>
1. LLM-suggested first
<<<ORDER_END>>>
<<<BACKLOG_BEGIN>>>
**theme A** — HIMMEL-801
<<<BACKLOG_END>>>
trailing chrome
OUT
exit 0
FAKE
chmod +x "$FAKE_CLAUDE"

# Partial fake: emits ONLY the TLDR block (ORDER + BACKLOG sentinels absent) —
# exercises per-block fail-open (TLDR from LLM, ORDER + BACKLOG fall back).
FAKE_CLAUDE_PARTIAL="$TMP_ROOT/claude-partial.sh"
cat >"$FAKE_CLAUDE_PARTIAL" <<'FAKE'
#!/usr/bin/env bash
cat <<'OUT'
<<<TLDR_BEGIN>>>
ONLY TLDR FROM LLM
<<<TLDR_END>>>
OUT
exit 0
FAKE
chmod +x "$FAKE_CLAUDE_PARTIAL"

# Failing gh fake: the all-state PR query (no --search) exits non-zero, to
# exercise the pr_map_ok=0 reachability path (gh down != clean garden).
FAKE_GH_FAIL="$TMP_ROOT/gh-fail.sh"
cat >"$FAKE_GH_FAIL" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
    "pr list")
        if printf '%s ' "$@" | grep -q -- '--search'; then
            printf '%s\n' "${FAKE_GH_PR_JSON:-[]}"; exit 0
        fi
        echo "gh: simulated auth failure" >&2; exit 1
        ;;
esac
exit 0
FAKE
chmod +x "$FAKE_GH_FAIL"

# Setup a tmp git repo with a marker SHA + 3 commits referencing tickets.
REPO="$TMP_ROOT/repo"
git init -q --initial-branch=main "$REPO" 2>/dev/null || {
    git init -q "$REPO"
    git -C "$REPO" symbolic-ref HEAD refs/heads/main || true
}
(
    cd "$REPO"
    git -c user.email=t@test.com -c user.name=test commit -q --allow-empty -m "init"
    git branch -m main 2>/dev/null || true
    MARKER=$(git rev-parse HEAD)
    echo "$MARKER" > "$TMP_ROOT/MARKER"
    git -c user.email=t@test.com -c user.name=test commit -q --allow-empty -m "feat(scope): HIMMEL-901 add A"
    git -c user.email=t@test.com -c user.name=test commit -q --allow-empty -m "fix(scope): HIMMEL-902 bug B"
    git -c user.email=t@test.com -c user.name=test commit -q --allow-empty -m "chore: nothing"
)
# Forge seam (HIMMEL-326): the merged-PR section is gated to a github origin.
git -C "$REPO" remote add origin https://github.com/test/test.git
MARKER=$(cat "$TMP_ROOT/MARKER")

# Two extra worktrees: one keyed to an In-Progress ticket, one unkeyed.
git -C "$REPO" worktree add -q -b feat/himmel-901-thing "$TMP_ROOT/wt901" >/dev/null 2>&1 || true
git -C "$REPO" worktree add -q -b feat/random-slug      "$TMP_ROOT/wtrand" >/dev/null 2>&1 || true

run_script() {
    (
        cd "$REPO"
        # shellcheck disable=SC2030
        export GH_CMD="$FAKE_GH"
        # shellcheck disable=SC2030
        export JIRA_CMD="$FAKE_JIRA"
        bash "$SCRIPT" "$@"
    )
}

# Test 1: default run, all sections (🌅 schema) -----------------------

echo "TEST: default run produces the morning-report schema"
OUT_DEFAULT="$TMP_ROOT/out1.md"
out=$(FAKE_GH_PR_JSON='[{"number":42,"title":"feat(scope): HIMMEL-901 add A","mergedAt":"2026-05-25T00:00:00Z"}]' \
    FAKE_JIRA_OUT=$'HIMMEL-901\tTask\tDone\tAdd A' \
    run_script --since "$MARKER" --out "$OUT_DEFAULT")
file=$(cat "$OUT_DEFAULT")
assert_contains "header"             "Morning Report"               "$file"
assert_contains "tldr section"       "## TL;DR"                     "$file"
assert_contains "completed section"  "Completed ("                  "$file"
assert_contains "commits subsection" "### Commits"                  "$file"
assert_contains "done subsection"    "Tickets transitioned to Done" "$file"
assert_contains "wip section"        "In-flight WIP"                "$file"
assert_contains "stale section"      "Stale worktrees"              "$file"
assert_contains "backlog section"    "Backlog ("                    "$file"
assert_contains "order section"      "Suggested order"              "$file"
assert_contains "PR row #42"         "#42"                          "$file"
assert_contains "commit cited"       "HIMMEL-901"                   "$file"
assert_contains "marker echoed"      "$MARKER"                      "$file"
# Removed section must NOT reappear:
if printf '%s' "$file" | grep -q 'Items for operator review'; then fail "stale 'Items for operator review' section present"; else pass "operator-review section removed"; fi

# Test 2: local-date default -----------------------------------------

echo "TEST: default output is local-dated (no -u)"
LOCALDATE=$(date +%F)
assert_contains "local date in header" "Morning Report" "$file"
assert_contains "local date present"   "$LOCALDATE"     "$file"

# Test 3: --since SHA limits window -----------------------------------

echo "TEST: --since SHA limits the commit window"
LATEST=$(git -C "$REPO" rev-parse HEAD)
OUT2="$TMP_ROOT/out2.md"
out=$(run_script --since "$LATEST" --out "$OUT2")
file=$(cat "$OUT2")
assert_contains "no-commits message" "No commits found since" "$file"

# Test 4: --out writes to requested location --------------------------

echo "TEST: --out PATH respected (creates parent dirs)"
OUT3="$TMP_ROOT/sub/path/out3.md"
out=$(run_script --since "$MARKER" --out "$OUT3")
if [ -f "$OUT3" ]; then pass "wrote $OUT3"; else fail "did not create parent dir for --out"; fi

# Test 5: PR section absent (empty gh result) -------------------------

echo "TEST: empty gh PR list renders helpful message"
OUT4="$TMP_ROOT/out4.md"
out=$(FAKE_GH_PR_JSON='[]' run_script --since "$MARKER" --out "$OUT4")
file=$(cat "$OUT4")
assert_contains "empty PR fallback" "No merged PRs found" "$file"

# Test 6: jira unavailable -------------------------------------------

echo "TEST: jira unavailable yields ticket-keys-only fallback"
OUT5="$TMP_ROOT/out5.md"
out=$(
    cd "$REPO"
    GH_CMD="$FAKE_GH" JIRA_CMD="/no/such/binary" bash "$SCRIPT" --since "$MARKER" --out "$OUT5"
)
file=$(cat "$OUT5")
assert_contains "ticket keys listed in fallback" "HIMMEL-901" "$file"
# A failed jira CLI must surface a reachability banner — a 0 count means
# "unknown", not "none" (silent-failure-hunter HIGH).
assert_contains "jira-down banner" "jira unavailable" "$file"

# Test 7: --dry-run touches no files ----------------------------------

echo "TEST: --dry-run touches no files"
OUT6="$TMP_ROOT/out6.md"
out=$(run_script --since "$MARKER" --out "$OUT6" --dry-run)
if [ -f "$OUT6" ]; then fail "--dry-run created $OUT6"; else pass "--dry-run did not write file"; fi
assert_contains "dry-run prints body" "Morning Report" "$out"

# Test 8: cross-ref Done block ---------------------------------------

echo "TEST: Done block cross-references commits"
OUT7="$TMP_ROOT/out7.md"
out=$(FAKE_GH_PR_JSON='[]' \
    FAKE_JIRA_OUT=$'HIMMEL-901\tTask\tDone\tA
HIMMEL-902\tTask\tDone\tB
HIMMEL-999\tTask\tDone\tNot in commits' \
    run_script --since "$MARKER" --out "$OUT7")
file=$(cat "$OUT7")
assert_contains "Done block has HIMMEL-901" "HIMMEL-901 — Task — A" "$file"
assert_contains "Done block has HIMMEL-902" "HIMMEL-902 — Task — B" "$file"
if printf '%s' "$file" | grep -q 'HIMMEL-999'; then
    fail "Done block leaked unrelated ticket HIMMEL-999"
else
    pass "Done block filtered out HIMMEL-999 (not in commits)"
fi

# Test 9: In-flight WIP join rule + catch-all ------------------------

echo "TEST: In-flight WIP correlates by ticket key + catch-all"
OUT_WIP="$TMP_ROOT/wip.md"
out=$(FAKE_GH_PR_ALL='[{"number":50,"state":"OPEN","headRefName":"feat/himmel-901-thing","title":"x"},{"number":51,"state":"OPEN","headRefName":"feat/random-slug","title":"y"}]' \
    FAKE_JIRA_INPROG=$'HIMMEL-901\tTask\tIn Progress\tThing\nHIMMEL-903\tTask\tIn Progress\tNoBranch' \
    run_script --since "$MARKER" --out "$OUT_WIP")
file=$(cat "$OUT_WIP")
assert_contains "wip correlated ticket"   "HIMMEL-901" "$file"
assert_contains "wip correlated pr"       "#50"        "$file"
assert_contains "wip uncorrelated ticket" "HIMMEL-903" "$file"
assert_contains "wip catchall pr"         "#51"        "$file"

# Test 10: Stale worktrees = merged-PR only --------------------------

echo "TEST: stale worktrees = merged-PR branch only; main/open/no-PR not flagged"
OUT_STALE="$TMP_ROOT/stale.md"
out=$(FAKE_GH_PR_ALL='[{"number":60,"state":"MERGED","headRefName":"feat/himmel-901-thing","title":"x"},{"number":61,"state":"OPEN","headRefName":"feat/random-slug","title":"y"}]' \
    run_script --since "$MARKER" --out "$OUT_STALE")
file=$(cat "$OUT_STALE")
assert_contains "stale flags merged" "feat/himmel-901-thing" "$file"
# Stale-table rows are the only "| \`branch\` |" lines in the report.
stale_tbl=$(printf '%s\n' "$file" | grep -E '^\| `' || true)
# shellcheck disable=SC2016  # literal backtick-main-backtick in the table row, no expansion intended
if printf '%s\n' "$stale_tbl" | grep -qE '`main`'; then fail "stale flagged main"; else pass "main not flagged stale"; fi
if printf '%s\n' "$stale_tbl" | grep -q 'feat/random-slug'; then fail "stale flagged OPEN-PR worktree"; else pass "open-PR worktree not flagged stale"; fi

# Test 11: non-github origin degrades gracefully ---------------------

echo "TEST: non-github origin degrades gh sections without abort"
REPO_BB="$TMP_ROOT/repo_bb"; cp -r "$REPO" "$REPO_BB"
git -C "$REPO_BB" remote set-url origin https://bitbucket.org/test/test.git
OUT_BB="$TMP_ROOT/bb.md"
rc=0
out=$( cd "$REPO_BB"; GH_CMD="$FAKE_GH" JIRA_CMD="$FAKE_JIRA" bash "$SCRIPT" --since "$MARKER" --out "$OUT_BB" ) || rc=$?
if [ "$rc" -eq 0 ] && [ -f "$OUT_BB" ]; then pass "non-github run did not abort"; else fail "non-github run aborted (rc=$rc)"; fi
bb_file=$(cat "$OUT_BB")
assert_contains "bb still has wip header" "In-flight WIP"    "$bb_file"
assert_contains "bb stale degraded"       "non-github forge" "$bb_file"

# Test 12: Backlog flat + cap ----------------------------------------

echo "TEST: backlog renders flat + respects --backlog-limit"
OUT_BL="$TMP_ROOT/bl.md"
out=$(FAKE_JIRA_TODO=$'HIMMEL-801\tTask\tTo Do\tAlpha\nHIMMEL-802\tTask\tTo Do\tBeta\nHIMMEL-803\tTask\tTo Do\tGamma' \
    run_script --since "$MARKER" --out "$OUT_BL" --backlog-limit 2)
file=$(cat "$OUT_BL")
assert_contains "backlog item 1" "HIMMEL-801" "$file"
assert_contains "backlog item 2" "HIMMEL-802" "$file"
if printf '%s' "$file" | grep -q 'HIMMEL-803'; then fail "backlog ignored --backlog-limit 2"; else pass "backlog capped at 2"; fi
assert_contains "backlog total noted" "1 more" "$file"

# Test 13: TL;DR + Suggested order heuristics ------------------------

echo "TEST: TL;DR + Suggested order heuristics render"
OUT_TL="$TMP_ROOT/tldr.md"
out=$(FAKE_JIRA_INPROG=$'HIMMEL-901\tTask\tIn Progress\tThing' \
    FAKE_JIRA_TODO=$'HIMMEL-801\tTask\tTo Do\tAlpha' \
    run_script --since "$MARKER" --out "$OUT_TL")
file=$(cat "$OUT_TL")
# Assert COMPUTED content (1 In-Progress + 1 To-Do, no stale, no PRs), not just
# the static template labels — a wrong count/order must not ship green.
assert_contains "tldr 1 in-flight" "**1** in-flight" "$file"
assert_contains "tldr 1 backlog"   "**1** backlog"   "$file"
assert_contains "order advance"    "Advance 1 In-Progress ticket(s)." "$file"
assert_contains "order pull"       "Pull from the 1-item backlog."     "$file"

# Test 14: --llm splices enriched blocks -----------------------------

echo "TEST: --llm splices multi-line enriched blocks"
OUT_LLM="$TMP_ROOT/llm.md"
out=$( cd "$REPO"; GH_CMD="$FAKE_GH" JIRA_CMD="$FAKE_JIRA" CLAUDE_CMD="$FAKE_CLAUDE" \
       FAKE_JIRA_TODO=$'HIMMEL-801\tTask\tTo Do\tAlpha' \
       bash "$SCRIPT" --since "$MARKER" --out "$OUT_LLM" --llm )
file=$(cat "$OUT_LLM")
assert_contains "llm tldr spliced"   "LLM TL;DR line one"  "$file"
assert_contains "llm tldr multiline" "LLM TL;DR line two"  "$file"
assert_contains "llm order spliced"  "LLM-suggested first" "$file"
assert_contains "llm backlog theme"  "theme A"             "$file"

# Test 15: --llm fails open to heuristic -----------------------------

echo "TEST: --llm fails open to heuristic when claude errors"
OUT_LLF="$TMP_ROOT/llmfail.md"
rc=0
out=$( cd "$REPO"; GH_CMD="$FAKE_GH" JIRA_CMD="$FAKE_JIRA" CLAUDE_CMD="/no/such/claude" \
       bash "$SCRIPT" --since "$MARKER" --out "$OUT_LLF" --llm ) || rc=$?
if [ "$rc" -eq 0 ]; then pass "llm failure did not abort"; else fail "llm failure aborted rc=$rc"; fi
assert_contains "fallback tldr heuristic" "in-flight" "$(cat "$OUT_LLF")"

# Test 16: --llm per-block fail-open (only TLDR present) --------------

echo "TEST: --llm per-block fail-open (TLDR from LLM, ORDER + BACKLOG fall back)"
OUT_PARTIAL="$TMP_ROOT/partial.md"
out=$( cd "$REPO"; GH_CMD="$FAKE_GH" JIRA_CMD="$FAKE_JIRA" CLAUDE_CMD="$FAKE_CLAUDE_PARTIAL" \
       FAKE_JIRA_INPROG=$'HIMMEL-901\tTask\tIn Progress\tThing' \
       FAKE_JIRA_TODO=$'HIMMEL-801\tTask\tTo Do\tAlpha' \
       bash "$SCRIPT" --since "$MARKER" --out "$OUT_PARTIAL" --llm )
file=$(cat "$OUT_PARTIAL")
assert_contains "partial: llm tldr taken"    "ONLY TLDR FROM LLM"               "$file"
assert_contains "partial: order fell back"   "Advance 1 In-Progress ticket(s)." "$file"
assert_contains "partial: backlog fell back" "HIMMEL-801"                       "$file"

# Test 17: gh unreachable → pr_map_ok=0 banner + stale "unavailable" --

echo "TEST: gh all-state query failure → reachability banner + stale unavailable"
OUT_GHF="$TMP_ROOT/ghfail.md"
out=$( cd "$REPO"; GH_CMD="$FAKE_GH_FAIL" JIRA_CMD="$FAKE_JIRA" \
       bash "$SCRIPT" --since "$MARKER" --out "$OUT_GHF" )
file=$(cat "$OUT_GHF")
assert_contains "gh-down banner"          "gh PR state unavailable"      "$file"
assert_contains "gh-down stale message"   "stale detection unavailable"  "$file"

# Summary --------------------------------------------------------------

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
