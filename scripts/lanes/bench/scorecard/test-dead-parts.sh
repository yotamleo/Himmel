#!/usr/bin/env bash
# scripts/lanes/bench/scorecard/test-dead-parts.sh - RED/GREEN suite for
# dead-parts.sh (HIMMEL-3513 EXPANSION 2). House check_contains/PASS-FAIL
# style, per test-extra-metrics.sh.
#
# Hermetic: never git-greps the live himmel repo. A throwaway fixture git
# repo is built fresh under a mktemp dir from the committed, .git-free tree at
# fixtures/dead-parts/basic-repo/ (a nested .git can never be committed into
# this repo itself - that would turn the fixture into a broken gitlink for
# the outer himmel repo). The transcript scan uses SCORECARD_PROJECTS_DIR
# fixtures, same convention as test-extra-metrics.sh.
#
# Platform guard: no .ps1 twin, by design.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/dead-parts.sh"
. "$HERE/../../../lib/timeout-bin.sh"
fails=0

check_contains() {
    name="$1"; haystack="$2"; needle="$3"
    case "$haystack" in
        *"$needle"*) echo "ok - $name" ;;
        *) echo "FAIL - $name: expected to find [$needle]"; fails=$((fails + 1)) ;;
    esac
}

check_not_contains() {
    name="$1"; haystack="$2"; needle="$3"
    case "$haystack" in
        *"$needle"*) echo "FAIL - $name: expected NOT to find [$needle]"; fails=$((fails + 1)) ;;
        *) echo "ok - $name" ;;
    esac
}

TMPREPO=$(mktemp -d "${TMPDIR:-/tmp}/test-dead-parts.XXXXXX") || { echo "FAIL - mktemp"; exit 1; }
WTPATH="$TMPREPO-worktree"
# shellcheck disable=SC2317,SC2329  # invoked by the EXIT trap below
cleanup() { git -C "$TMPREPO" worktree remove --force "$WTPATH" 2>/dev/null; rm -rf "$TMPREPO" "$WTPATH" "${BROKENREPO:-}" "${TSREPO:-}" "${TSREPO2:-}" "${BIGTS:-}" "${MALREPO:-}" "${JQORDERREPO:-}" "${BOTHEDGESREPO:-}"; }
trap cleanup EXIT

cp -R "$HERE/fixtures/dead-parts/basic-repo/." "$TMPREPO/" || { echo "FAIL - fixture copy"; exit 1; }
git -C "$TMPREPO" init -q || { echo "FAIL - git init"; exit 1; }
git -C "$TMPREPO" add -A || { echo "FAIL - git add"; exit 1; }
git -C "$TMPREPO" -c user.email=fixture@test -c user.name=fixture commit -q -m fixture \
    || { echo "FAIL - git commit"; exit 1; }

# --- basic: one entry per class, plus the precedence rule -------------------
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/dead-parts/basic-transcripts"
OUT=$("$SCRIPT" --since 2026-09-15T00:00:00Z --repo-root "$TMPREPO" 2>/dev/null)
rc=$?
if [ "$rc" -eq 0 ]; then
    echo "ok - basic: dead-parts.sh exits 0"
else
    echo "FAIL - basic: dead-parts.sh rc=$rc (expected 0): $OUT"
    fails=$((fails + 1))
fi

check_contains "basic: script class counts (USED/WIRED/TEST-ONLY/DOC-ONLY/DEAD)" \
    "$OUT" "kind=script USED=2 WIRED=3 TEST-ONLY=3 DOC-ONLY=1 DEAD=5"
check_contains "basic: command class counts" \
    "$OUT" "kind=command USED=1 WIRED=0 TEST-ONLY=0 DOC-ONLY=0 DEAD=1"
check_contains "basic: skill class counts" \
    "$OUT" "kind=skill USED=1 WIRED=0 TEST-ONLY=0 DOC-ONLY=0 DEAD=1"
check_contains "basic: agent class counts" \
    "$OUT" "kind=agent USED=1 WIRED=1 TEST-ONLY=0 DOC-ONLY=0 DEAD=1"
check_contains "basic: totals line sums every kind" \
    "$OUT" "totals: USED=5 WIRED=4 TEST-ONLY=3 DOC-ONLY=1 DEAD=8"
check_contains "basic: transcript coverage line beside the table" \
    "$OUT" "coverage: roots=1 discovered=1 parsed=1 skipped=0"

check_contains "basic: USED script detected via a Bash tool_use naming its path" \
    "$OUT" $'script\tfoo-used\tscripts/foo-used.sh'
check_contains "basic: USED skill detected via a Skill tool_use" \
    "$OUT" $'skill\tused-skill\t.claude/skills/used-skill/SKILL.md'
check_contains "basic: USED command detected via a typed <command-name> tag" \
    "$OUT" $'command\tused-cmd\t.claude/commands/used-cmd.md'
check_contains "basic: WIRED script whose own self-referencing header used to mask a real external basename reference (codex-3 unmasking fix)" \
    "$OUT" $'script\tcaller\tscripts/caller.sh\tWIRED'
check_contains "basic: WIRED script whose own full-path doc mention used to mask a real basename-only code caller (codex-2 unmasking fix)" \
    "$OUT" $'script\tdoc-and-code\tscripts/doc-and-code.sh\tWIRED'
check_contains "basic: the basename-only caller itself has no reference anywhere and stays DEAD" \
    "$OUT" $'script\trelative-caller\tscripts/relative-caller.sh\tDEAD'
check_not_contains "basic: a non-script tracked file under scripts/ (README.md) is not classified as a script entry (codex-1, round 11)" \
    "$OUT" $'script\tREADME\t'
check_contains "basic: a mention living inside a nested fixtures/ dir does not count as a reference (codex-1 fixture-blind-spot fix)" \
    "$OUT" $'script\tfixture-blind\tscripts/fixture-blind.sh\tDEAD'
check_contains "basic: a mention living inside a top-level fixtures/ dir (no leading slash) does not count as a reference either (codex-2 top-level-fixtures fix)" \
    "$OUT" $'script\ttoplevel-blind\tscripts/toplevel-blind.sh\tDEAD'
check_contains "basic: plugin-qualified Skill tool_use (fixture-plugin:used-skill) still matches the bare discovered skill name" \
    "$OUT" $'skill\tused-skill\t.claude/skills/used-skill/SKILL.md\tUSED'
check_contains "basic: Agent tool_use subagent_type marks a zero-static-reference agent USED" \
    "$OUT" $'agent\tused-agent\t.claude/agents/used-agent.md\tUSED'
check_contains "basic: a Bash command with an embedded newline still counts its second line's script as USED" \
    "$OUT" $'script\tmultiline-used\tscripts/multiline-used.sh\tUSED'

check_contains "basic: DEAD list header" "$OUT" "--- DEAD (no reference anywhere, no transcript call)"
check_contains "basic: DEAD script with only a self-referencing header comment stays DEAD (self-match excluded)" \
    "$OUT" $'script\tqux-deadd\tscripts/qux-deadd.sh\tDEAD'
check_contains "basic: DEAD command" "$OUT" $'command\tdead-cmd\t.claude/commands/dead-cmd.md\tDEAD'
check_contains "basic: DEAD skill" "$OUT" $'skill\tdead-skill\t.claude/skills/dead-skill/SKILL.md\tDEAD'
check_contains "basic: DEAD agent" "$OUT" $'agent\tdead-agent\t.claude/agents/dead-agent.md\tDEAD'

check_contains "basic: DOC-ONLY list header" "$OUT" "--- DOC-ONLY (referenced only from docs/*.md)"
check_contains "basic: DOC-ONLY script referenced only from docs/readme.md" \
    "$OUT" $'script\tquux-doc\tscripts/quux-doc.sh\tDOC-ONLY'

check_contains "basic: precedence - a script referenced by BOTH a test file and a doc lands TEST-ONLY, not DOC-ONLY" \
    "$OUT" $'script\tprecedence-test\tscripts/precedence-test.sh\tTEST-ONLY'
check_contains "basic: a script referenced only from a .spec.* file lands TEST-ONLY (codex-3 .spec.* naming fix)" \
    "$OUT" $'script\tspec-testonly\tscripts/spec-testonly.sh\tTEST-ONLY'
dead_section=$(printf '%s\n' "$OUT" | sed -n '/^--- DEAD /,/^--- DOC-ONLY /p')
# codex-2 (round 12): a `grep -q` miss on an EMPTY $dead_section (e.g. the
# `--- DEAD ` header text drifted, breaking the sed range extraction) is
# indistinguishable from a genuine absence - guard that the section was
# actually extracted before trusting the negative assertion below.
if ! printf '%s\n' "$dead_section" | grep -q 'qux-deadd'; then
    echo "FAIL - precedence: DEAD section extraction is broken (missing known DEAD entry qux-deadd) - the precedence-test absence check below would be vacuous"
    fails=$((fails + 1))
fi
if printf '%s\n' "$dead_section" | grep -q 'precedence-test'; then
    echo "FAIL - precedence: precedence-test.sh must not appear in the DEAD list"
    fails=$((fails + 1))
else
    echo "ok - precedence: precedence-test.sh absent from DEAD"
fi
# it must appear exactly once in the classified table (as TEST-ONLY), never twice
occurrences=$(printf '%s\n' "$OUT" | grep -c 'precedence-test')
if [ "$occurrences" -eq 1 ]; then
    echo "ok - precedence: precedence-test.sh classified exactly once"
else
    echo "FAIL - precedence: precedence-test.sh should appear exactly once in the report, got $occurrences"
    fails=$((fails + 1))
fi

# --- out-of-window: a Bash call before --since must not count as USED, and
# must not leak into the DEAD verdict for an otherwise-unreferenced script ---
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/dead-parts/out-of-window-transcripts"
OUT2=$("$SCRIPT" --since 2026-09-15T00:00:00Z --repo-root "$TMPREPO" 2>/dev/null)
rc2=$?
if [ "$rc2" -eq 0 ]; then
    echo "ok - out-of-window: dead-parts.sh exits 0"
else
    echo "FAIL - out-of-window: dead-parts.sh rc=$rc2 (expected 0): $OUT2"
    fails=$((fails + 1))
fi

check_contains "out-of-window: the pre-window transcript is discovered but skipped, not silently dropped" \
    "$OUT2" "coverage: roots=1 discovered=1 parsed=0 skipped=1 (out-of-window=1)"
check_contains "out-of-window: a Bash call before --since does not count as USED - the script stays DEAD" \
    "$OUT2" $'script\tout-of-window\tscripts/out-of-window.sh\tDEAD'

# --- non-chronological: a transcript whose PHYSICAL first and last records are
# both out-of-window must not skip an in-window record sitting between them -
# the window check must scan every record's timestamp, not just head/tail
# (round-6 codex-1) ------------------------------------------------------------
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/dead-parts/non-chronological-transcripts"
OUT5=$("$SCRIPT" --since 2026-09-15T00:00:00Z --repo-root "$TMPREPO" 2>/dev/null)
rc5=$?
if [ "$rc5" -eq 0 ]; then
    echo "ok - non-chronological: dead-parts.sh exits 0"
else
    echo "FAIL - non-chronological: dead-parts.sh rc=$rc5 (expected 0): $OUT5"
    fails=$((fails + 1))
fi
check_contains "non-chronological: an in-window Bash call is not discarded because the file's first and last physical records are both out-of-window (round-6 codex-1 fix)" \
    "$OUT5" $'script\tqux-deadd\tscripts/qux-deadd.sh\tUSED'

# --- linked worktree: --repo-root pointing at a worktree whose .git is a
# FILE (`gitdir: ...`), not a directory - every leg runs from exactly this
# shape, and a `[ -d "$REPO_ROOT/.git" ]` check (the pre-fix code) rejects it
# outright even though the repo is perfectly valid ---------------------------
git -C "$TMPREPO" worktree add -q -b test-dead-parts-wt "$WTPATH" >/dev/null 2>&1 \
    || { echo "FAIL - git worktree add"; fails=$((fails + 1)); }
if [ -f "$WTPATH/.git" ]; then
    echo "ok - linked worktree: .git is a file, not a directory (precondition)"
else
    echo "FAIL - linked worktree: expected $WTPATH/.git to be a file"
    fails=$((fails + 1))
fi
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/dead-parts/basic-transcripts"
OUT3=$("$SCRIPT" --since 2026-09-15T00:00:00Z --repo-root "$WTPATH" 2>&1)
rc3=$?
if [ "$rc3" -eq 0 ]; then
    echo "ok - linked worktree: dead-parts.sh accepts a file-shaped .git and exits 0"
else
    echo "FAIL - linked worktree: dead-parts.sh rc=$rc3 (expected 0): $OUT3"
    fails=$((fails + 1))
fi
check_contains "linked worktree: still reports the classification table" \
    "$OUT3" "--- entry-point classification"

# --- broken repo lookup: --repo-root's `.git` exists (passes the earlier
# `[ -e "$REPO_ROOT/.git" ]` guard) but is corrupt, so `git ls-files` itself
# fails - the report must abort loudly, never fall through to an empty
# discovery file and a "successful" table claiming every entry point is
# missing (round-8 codex-3) --------------------------------------------------
BROKENREPO=$(mktemp -d "${TMPDIR:-/tmp}/test-dead-parts-broken.XXXXXX") || { echo "FAIL - mktemp broken repo"; exit 1; }
mkdir -p "$BROKENREPO/scripts"
printf 'not a real gitfile\n' > "$BROKENREPO/.git"
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/dead-parts/basic-transcripts"
OUT4=$("$SCRIPT" --since 2026-09-15T00:00:00Z --repo-root "$BROKENREPO" 2>&1)
rc4=$?
if [ "$rc4" -ne 0 ]; then
    echo "ok - broken repo: dead-parts.sh aborts (rc=$rc4) instead of reporting success"
else
    echo "FAIL - broken repo: dead-parts.sh exited 0 despite a failed git ls-files"
    fails=$((fails + 1))
fi
check_contains "broken repo: the abort names the failing git ls-files call, not a silent empty report" \
    "$OUT4" "dead-parts: git ls-files failed for --repo-root"

# --- TS-ESM wiring: a .ts entry imported only via its compiled .js specifier
# (PR #1170's documented caveat) must classify WIRED, not DEAD -------------
TSREPO=$(mktemp -d "${TMPDIR:-/tmp}/test-dead-parts-ts.XXXXXX") || { echo "FAIL - mktemp ts repo"; exit 1; }
mkdir -p "$TSREPO/scripts"
printf 'export function actExec() {}\n' > "$TSREPO/scripts/act-exec.ts"
printf 'import { actExec } from "./act-exec.js";\nactExec();\n' > "$TSREPO/scripts/caller.mjs"
git -C "$TSREPO" init -q || { echo "FAIL - ts repo git init"; exit 1; }
git -C "$TSREPO" add -A || { echo "FAIL - ts repo git add"; exit 1; }
git -C "$TSREPO" -c user.email=fixture@test -c user.name=fixture commit -q -m fixture \
    || { echo "FAIL - ts repo git commit"; exit 1; }
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/dead-parts/basic-transcripts"
OUTTS=$("$SCRIPT" --since 2026-09-15T00:00:00Z --repo-root "$TSREPO" 2>&1)
rcts=$?
if [ "$rcts" -eq 0 ]; then
    echo "ok - ts-wiring: dead-parts.sh exits 0"
else
    echo "FAIL - ts-wiring: dead-parts.sh rc=$rcts (expected 0): $OUTTS"
    fails=$((fails + 1))
fi
check_contains "ts-wiring: a .ts entry referenced only via its .js import specifier lands WIRED, not DEAD (PR #1170 caveat fix)" \
    "$OUTTS" $'script\tact-exec\tscripts/act-exec.ts\tWIRED'

# --- TS extensionless wiring: a .ts entry imported only via an extensionless
# specifier (`from "./foo"`, common with bundler-resolved TS) must also
# classify WIRED, not DEAD - the .js-suffixed union above (PR #1170) covers
# the compiled-extension form but not this one (HIMMEL-3550) -----------------
TSREPO2=$(mktemp -d "${TMPDIR:-/tmp}/test-dead-parts-tsext.XXXXXX") || { echo "FAIL - mktemp ts-ext repo"; exit 1; }
mkdir -p "$TSREPO2/scripts"
printf 'export function extlessFn() {}\n' > "$TSREPO2/scripts/extless-src.ts"
printf 'import { extlessFn } from "./extless-src";\nextlessFn();\n' > "$TSREPO2/scripts/extless-caller.mjs"
git -C "$TSREPO2" init -q || { echo "FAIL - ts-ext repo git init"; exit 1; }
git -C "$TSREPO2" add -A || { echo "FAIL - ts-ext repo git add"; exit 1; }
git -C "$TSREPO2" -c user.email=fixture@test -c user.name=fixture commit -q -m fixture \
    || { echo "FAIL - ts-ext repo git commit"; exit 1; }
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/dead-parts/basic-transcripts"
OUTTSEXT=$("$SCRIPT" --since 2026-09-15T00:00:00Z --repo-root "$TSREPO2" 2>&1)
rctsext=$?
if [ "$rctsext" -eq 0 ]; then
    echo "ok - ts-extensionless: dead-parts.sh exits 0"
else
    echo "FAIL - ts-extensionless: dead-parts.sh rc=$rctsext (expected 0): $OUTTSEXT"
    fails=$((fails + 1))
fi
check_contains "ts-extensionless: a .ts entry referenced only via an extensionless import specifier lands WIRED, not DEAD (HIMMEL-3550)" \
    "$OUTTSEXT" $'script\textless-src\tscripts/extless-src.ts\tWIRED'

# --- malformed edge timestamps: a transcript whose sorted-first (head) or
# sorted-last (tail) extracted timestamp matches the extraction charset but
# fails to parse must not skip the WHOLE file - fall back to the nearest
# timestamp that does parse instead, so an in-window Bash call elsewhere in
# the same file still counts as USED (HIMMEL-3547) --------------------------
MALREPO=$(mktemp -d "${TMPDIR:-/tmp}/test-dead-parts-mal.XXXXXX") || { echo "FAIL - mktemp mal repo"; exit 1; }
mkdir -p "$MALREPO/scripts"
printf '#!/usr/bin/env bash\necho head\n' > "$MALREPO/scripts/malformed-head.sh"
printf '#!/usr/bin/env bash\necho tail\n' > "$MALREPO/scripts/malformed-tail.sh"
git -C "$MALREPO" init -q || { echo "FAIL - mal repo git init"; exit 1; }
git -C "$MALREPO" add -A || { echo "FAIL - mal repo git add"; exit 1; }
git -C "$MALREPO" -c user.email=fixture@test -c user.name=fixture commit -q -m fixture \
    || { echo "FAIL - mal repo git commit"; exit 1; }
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/dead-parts/malformed-edge-timestamps-transcripts"
OUTMAL=$("$SCRIPT" --since 2026-09-15T00:00:00Z --repo-root "$MALREPO" 2>&1)
rcmal=$?
if [ "$rcmal" -eq 0 ]; then
    echo "ok - malformed-edge: dead-parts.sh exits 0"
else
    echo "FAIL - malformed-edge: dead-parts.sh rc=$rcmal (expected 0): $OUTMAL"
    fails=$((fails + 1))
fi
check_contains "malformed-edge: a transcript with a malformed HEAD timestamp still counts its in-window Bash call as USED, not skipped as bad-timestamp (HIMMEL-3547)" \
    "$OUTMAL" $'script\tmalformed-head\tscripts/malformed-head.sh\tUSED'
check_contains "malformed-edge: a transcript with a malformed TAIL timestamp still counts its in-window Bash call as USED, not skipped as bad-timestamp (HIMMEL-3547)" \
    "$OUTMAL" $'script\tmalformed-tail\tscripts/malformed-tail.sh\tUSED'
check_contains "malformed-edge: the WARNING names the fallback, not a silent skip" \
    "$OUTMAL" "dead-parts: WARNING: 2 transcript(s) had a malformed head/tail timestamp - fell back to the nearest valid one instead of skipping the file"

# --- malformed timestamp mid-scan: a valid in-window record followed later
# in FILE order (not sorted order) by a record with a malformed timestamp
# must not lose the valid record - jq's per-record fromdateiso8601 throws on
# the malformed one, which aborted the whole `jq` invocation (nonzero exit)
# and discarded every record it had already emitted via the JQ_FAILS/continue
# branch, even though the valid Bash call was already in jq's stdout
# (HIMMEL-3547 CR round 1) ----------------------------------------------
JQORDERREPO=$(mktemp -d "${TMPDIR:-/tmp}/test-dead-parts-jqorder.XXXXXX") || { echo "FAIL - mktemp jqorder repo"; exit 1; }
mkdir -p "$JQORDERREPO/scripts"
printf '#!/usr/bin/env bash\necho jqorder\n' > "$JQORDERREPO/scripts/malformed-jq-order.sh"
git -C "$JQORDERREPO" init -q || { echo "FAIL - jqorder repo git init"; exit 1; }
git -C "$JQORDERREPO" add -A || { echo "FAIL - jqorder repo git add"; exit 1; }
git -C "$JQORDERREPO" -c user.email=fixture@test -c user.name=fixture commit -q -m fixture \
    || { echo "FAIL - jqorder repo git commit"; exit 1; }
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/dead-parts/malformed-jq-order-transcripts"
OUTJQORDER=$("$SCRIPT" --since 2026-09-15T00:00:00Z --repo-root "$JQORDERREPO" 2>&1)
check_contains "malformed-jq-order: a valid in-window Bash record emitted before a later malformed-timestamp record still counts as USED (HIMMEL-3547)" \
    "$OUTJQORDER" $'script\tmalformed-jq-order\tscripts/malformed-jq-order.sh\tUSED'

# --- malformed BOTH edges: when the sorted-first AND sorted-last timestamp
# are both malformed, the fallback runs twice for the SAME transcript - the
# WARNING count must still name it once, not twice (HIMMEL-3547 CR round 1) -
BOTHEDGESREPO=$(mktemp -d "${TMPDIR:-/tmp}/test-dead-parts-bothedges.XXXXXX") || { echo "FAIL - mktemp bothedges repo"; exit 1; }
mkdir -p "$BOTHEDGESREPO/scripts"
printf '#!/usr/bin/env bash\necho bothedges\n' > "$BOTHEDGESREPO/scripts/malformed-both-edges.sh"
git -C "$BOTHEDGESREPO" init -q || { echo "FAIL - bothedges repo git init"; exit 1; }
git -C "$BOTHEDGESREPO" add -A || { echo "FAIL - bothedges repo git add"; exit 1; }
git -C "$BOTHEDGESREPO" -c user.email=fixture@test -c user.name=fixture commit -q -m fixture \
    || { echo "FAIL - bothedges repo git commit"; exit 1; }
export SCORECARD_PROJECTS_DIR="$HERE/fixtures/dead-parts/malformed-both-edges-transcripts"
OUTBOTHEDGES=$("$SCRIPT" --since 2026-09-15T00:00:00Z --repo-root "$BOTHEDGESREPO" 2>&1)
check_contains "malformed-both-edges: still counts the in-window Bash call as USED" \
    "$OUTBOTHEDGES" $'script\tmalformed-both-edges\tscripts/malformed-both-edges.sh\tUSED'
check_contains "malformed-both-edges: WARNING counts the transcript ONCE, not twice, when both edges are malformed" \
    "$OUTBOTHEDGES" "dead-parts: WARNING: 1 transcript(s) had a malformed head/tail timestamp - fell back to the nearest valid one instead of skipping the file"
check_not_contains "malformed-both-edges: WARNING must not double-count" \
    "$OUTBOTHEDGES" "dead-parts: WARNING: 2 transcript(s) had a malformed head/tail timestamp"

# --- pathological scale: many timestamps in one transcript file must not
# block the report - the whole report used to be buffered until a per-line
# `date -d` fork ran once for every extracted timestamp, so a large real
# transcript (thousands of tool_use records) made the tool look silently
# hung. A bounded `timeout` proves the fix. Measured on this machine: the
# pre-fix per-line fork loop takes ~3.8s per 4000 timestamps (linear), so
# 4000 alone finishes inside any reasonable timeout and proves nothing -
# 20000 is chosen because the pre-fix loop reliably exceeds 10s on it while
# the fixed sort-based gate finishes in well under 1s. ----------------------
BIGTS=$(mktemp -d "${TMPDIR:-/tmp}/test-dead-parts-bigts.XXXXXX") || { echo "FAIL - mktemp bigts"; exit 1; }
BIGFILE="$BIGTS/session.jsonl"
: > "$BIGFILE"
i=0
while [ "$i" -lt 20000 ]; do
    printf '{"type":"assistant","timestamp":"2026-09-15T00:00:%02d.%03dZ","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo hi"}}]}}\n' \
        "$((i % 60))" "$((i % 1000))" >> "$BIGFILE"
    i=$((i + 1))
done
export SCORECARD_PROJECTS_DIR="$BIGTS"
if [ -n "$_TIMEOUT_BIN" ]; then
    OUTBIG=$("$_TIMEOUT_BIN" 10 "$SCRIPT" --since 2026-09-15T00:00:00Z --repo-root "$TMPREPO" 2>&1)
    rcbig=$?
    if [ "$rcbig" -eq 0 ]; then
        echo "ok - pathological scale: dead-parts.sh completes well inside 10s on a 20000-timestamp transcript"
    else
        echo "FAIL - pathological scale: dead-parts.sh rc=$rcbig (expected 0, 124=timeout means the per-line date-fork hang is back): $OUTBIG"
        fails=$((fails + 1))
    fi
    check_contains "pathological scale: the report still prints (not silently empty)" \
        "$OUTBIG" "--- entry-point classification"
else
    echo "SKIP pathological-scale (no GNU coreutils timeout on this runner)"
fi

echo "---"
if [ "$fails" -eq 0 ]; then
    echo "PASS - test-dead-parts.sh: 0 failures"
    exit 0
else
    echo "FAIL - test-dead-parts.sh: $fails failure(s)"
    exit 1
fi
