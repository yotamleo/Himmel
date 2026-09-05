#!/usr/bin/env bash
# Unit tests for scripts/luna/qmd-staleness.sh (HIMMEL-1286).
#
# The guard is a pure READ: it runs `qmd status` and classifies the result. So
# every case here drives a FAKE qmd that prints a canned report, which makes the
# suite hermetic — no real qmd, no index, no network — and lets us assert the
# fail-closed paths that a live index can never produce on demand (a reworded
# report, an unparseable age).
#
# Two of the fixtures are VERBATIM captures taken 2026-07-27 from the host
# (fresh, complete) and from the win2 station (1d stale, 1193 chunks pending).
# Parsing is coupled to human-readable output because `qmd status` has no
# machine format, so pinning the real shape is the only thing standing between
# a future rewording and a silent all-clear.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/qmd-staleness.sh"

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
# Here-string, not `printf … | grep -q` — see the HIMMEL-1115 note in
# test-qmd-reindex.sh: under pipefail a successful early-exiting grep -q turns
# the producer's SIGPIPE into a pipeline failure, so a real match reads as a
# miss once the haystack outgrows the pipe buffer.
assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if grep -qF -- "$needle" <<<"$haystack"; then pass "$name"; else fail "$name" "missing: $needle"; fi
}
assert_not_contains() {
    local name="$1" needle="$2" haystack="$3"
    if grep -qF -- "$needle" <<<"$haystack"; then fail "$name" "unexpected: $needle"; else pass "$name"; fi
}
assert_rc() {
    local name="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then pass "$name"; else fail "$name" "expected rc=$want, got rc=$got"; fi
}
summary() {
    echo
    echo "===================================="
    echo "test summary: $PASS passed, $FAIL failed"
    echo "===================================="
    [ "$FAIL" -gt 0 ] && exit 1 || exit 0
}

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/qmd-staleness-test.XXXXXX")
FAKE="$TMP_ROOT/fake-qmd.sh"
FIXTURE="$TMP_ROOT/status.txt"

# The fake ignores its args and prints the current fixture. QMD_FAKE_RC lets a
# case make `qmd status` itself fail, which must be distinguishable from a
# report the guard cannot parse.
# It also VALIDATES its argv: a fake that answers any invocation would let the
# guard call `qmd anything` and still score green, so the suite would stop
# pinning the one command this script is allowed to run. The rc override is
# checked first, so the qmd-itself-failed cases still exercise that path.
cat >"$FAKE" <<'EOF'
#!/usr/bin/env bash
if [ -n "${QMD_FAKE_RC:-}" ] && [ "$QMD_FAKE_RC" != "0" ]; then exit "$QMD_FAKE_RC"; fi
if [ "${1:-}" != "status" ]; then
    echo "fake-qmd: expected 'status' as the first argument, got '${1:-<none>}'" >&2
    exit 64
fi
cat "$QMD_FIXTURE"
EOF
chmod +x "$FAKE"

# Run the guard against a fixture. Captures stdout+stderr together: the notice
# is deliberately on stderr and the all-clear on stdout, and callers see both.
run_guard() {
    QMD_FIXTURE="$FIXTURE" bash "$SCRIPT" --qmd-bin "$FAKE" "$@" 2>&1
}

set_fixture() { printf '%s\n' "$1" >"$FIXTURE"; }

# --- fixtures ---------------------------------------------------------------

# VERBATIM host capture 2026-07-27 — fresh (2h) and complete (no Pending line).
# The Collections block is kept in full ON PURPOSE: its per-collection
# "(updated 6d ago)" suffixes are the exact thing a sloppy parser would pick up
# instead of the top-level Updated:, so their presence is load-bearing here.
HOST_FRESH='QMD Status

Index: C:/Users/example/.cache/qmd/index.sqlite
Size:  458.3 MB
MCP:   running (PID 37828) at http://localhost:8181

Documents
  Total:    17141 files indexed
  Vectors:  76055 embedded
  Updated:  2h ago

Collections
  himmel (qmd://himmel/)
    Files:    285 (updated 1d ago)
  luna-curated (qmd://luna-curated/)
    Files:    362 (updated 6d ago)'

# VERBATIM win2 capture 2026-07-27 — 1d, 1193 pending. "1d ago" is the interval
# [24h, 48h) (qmd's formatter floors), so under the default 36h budget this
# specimen is BOTH out-of-budget and incomplete — see the worst-case section
# below. Incomplete-only is isolated with an hour-granular fixture instead.
WIN2_PENDING='QMD Status

Index: C:/Users/example/.cache/qmd/index.sqlite
Size:  482.7 MB
MCP:   running (PID 31236) at http://localhost:8181

Documents
  Total:    14918 files indexed
  Vectors:  72898 embedded
  Pending:  1193 need embedding (run '"'"'qmd embed'"'"')
  Updated:  1d ago'

mk_docs() {
    # mk_docs <updated> [pending-line]
    printf 'QMD Status\n\nDocuments\n  Total:    10 files indexed\n  Vectors:  20 embedded\n'
    if [ $# -ge 2 ] && [ -n "$2" ]; then printf '  Pending:  %s\n' "$2"; fi
    printf '  Updated:  %s\n' "$1"
}

echo "== fresh and complete =="
set_fixture "$HOST_FRESH"
out=$(run_guard) && rc=0 || rc=$?
assert_rc "host fixture is fresh+complete -> rc 0" 0 "$rc"
assert_contains "prints the all-clear" "OK qmd-staleness: newest indexed doc edited" "$out"
assert_contains "all-clear cites the real age" "2h ago" "$out"

echo "== the top-level Updated: is not confused with a collection's =="
# RUN it rather than re-asserting the previous case's $rc — that variable was
# already 0 from the fixture above, so the old form restated a result instead of
# producing one and would have passed with the parser removed entirely. Uses a
# fixture whose collection rows are much older than the top-level Updated:, so
# picking up a collection row trips the 36h budget and rc 0 is a real claim.
set_fixture 'QMD Status

Documents
  Total:    10 files indexed
  Vectors:  20 embedded
  Updated:  2h ago

Collections
  himmel (qmd://himmel/)
    Files:    285 (updated 30d ago)
  luna-curated (qmd://luna-curated/)
    Files:    362 (updated 6d ago)'
out=$(run_guard) && rc=0 || rc=$?
assert_rc "collection '(updated 30d ago)' suffixes are ignored" 0 "$rc"
assert_contains "the verdict cites the TOP-LEVEL age" "2h ago" "$out"

echo "== --quiet =="
out=$(run_guard --quiet) && rc=0 || rc=$?
assert_rc "quiet keeps rc 0" 0 "$rc"
assert_not_contains "quiet suppresses the all-clear" "OK qmd-staleness" "$out"

echo "== stale =="
set_fixture "$(mk_docs '3d ago')"
out=$(run_guard) && rc=0 || rc=$?
assert_rc "3d with 36h budget -> rc 3" 3 "$rc"
assert_contains "names STALE, hedged" "qmd index may be STALE" "$out"
# The banner must state the OBSERVATION and both of its readings, never assert
# staleness outright. `Updated:` is MAX(source-file mtime) over indexed docs
# (qmd cli: SELECT MAX(modified_at) …; store: modified_at = statSync().mtime),
# so it cannot tell "the index stopped being refreshed" from "nobody edited
# anything". Asserting the first every time the second is true would be wrong
# daily on a slow-moving corpus — and an always-on banner that is wrong daily
# is one the reader learns to skip, taking the real warning with it.
assert_contains "states what the number actually measures" "newest document this index knows about" "$out"
assert_contains "offers the index-stopped reading" "the index stopped being refreshed" "$out"
assert_contains "and the quiet-corpus reading" "corpus" "$out"
assert_contains "names the underlying figure" "MAX(source-file mtime)" "$out"
assert_not_contains "never asserts staleness as fact" "index is STALE" "$out"
assert_contains "warns misses are unproven" "MISSES AS UNPROVEN" "$out"
assert_contains "steers away from reindexing on a station" "Do NOT reindex on a receiving station" "$out"
assert_not_contains "does not claim incompleteness" "INCOMPLETE" "$out"

echo "== --quiet still prints the notice =="
out=$(run_guard --quiet) && rc=0 || rc=$?
# Assert the RC too, not just the text: --quiet suppressing the all-clear must
# never also collapse the stale exit code to 0, which would read as healthy to
# every caller while still printing a warning nobody's script checks.
assert_rc "quiet preserves the stale rc" 3 "$rc"
assert_contains "quiet never suppresses a warning" "qmd index may be STALE" "$out"

echo "== incomplete only =="
set_fixture "$(mk_docs '2h ago' "1193 need embedding (run 'qmd embed')")"
out=$(run_guard) && rc=0 || rc=$?
assert_rc "fresh index with pending chunks -> rc 4" 4 "$rc"
assert_contains "names INCOMPLETE" "qmd index is INCOMPLETE" "$out"
assert_contains "cites the pending count" "1193 chunks still need embedding" "$out"
assert_not_contains "2h is not stale under a 36h budget" "may be STALE" "$out"
assert_contains "explains lex still works" "lexical" "$out"

echo "== a floored 'Nd' age is read at its WORST case, not its floor =="
# qmd's formatter FLOORS (formatTimeAgo: days = Math.floor(hours / 24)), so
# "1d ago" is the whole interval [24h, 48h) — 47h59m and 24h01m print the same
# string. Reading it as 24 made the 36h budget behave like a ~48h one and
# reported a two-day-old index FRESH, which is exactly the silent
# under-checking this guard exists to prevent. The verbatim win2 capture is the
# specimen: 1d + 1193 pending is BOTH, not merely incomplete.
set_fixture "$WIN2_PENDING"
out=$(run_guard) && rc=0 || rc=$?
assert_rc "win2 fixture (1d, 1193 pending) -> rc 5, not a fresh-looking rc 4" 5 "$rc"
assert_contains "reports the staleness it used to hide" "qmd index may be STALE" "$out"
assert_contains "and still reports the pending chunks" "1193 chunks pending" "$out"
# The boundary the widening creates: 1d cannot be certified under 36h, but IS
# certifiable under a budget that covers the whole interval.
set_fixture "$(mk_docs '1d ago')"
out=$(run_guard) && rc=0 || rc=$?
assert_rc "'1d ago' is NOT certifiable under a 36h budget" 3 "$rc"
out=$(run_guard --max-age-hours 47) && rc=0 || rc=$?
assert_rc "'1d ago' IS fresh under a budget covering its worst case" 0 "$rc"
# Hours are NOT widened: the budget is itself whole hours, so `Nh` slop is the
# comparison's own granularity rather than a lost order of magnitude.
set_fixture "$(mk_docs '36h ago')"
out=$(run_guard) && rc=0 || rc=$?
assert_rc "an hour-granularity age at exactly the budget stays fresh" 0 "$rc"

echo "== stale AND incomplete =="
set_fixture "$(mk_docs '5d ago' "77 need embedding (run 'qmd embed')")"
out=$(run_guard) && rc=0 || rc=$?
assert_rc "both -> rc 5" 5 "$rc"
assert_contains "reports both in one line" "may be STALE (5d ago) and IS INCOMPLETE (77 chunks pending)" "$out"

echo "== budget boundary =="
set_fixture "$(mk_docs '36h ago')"
out=$(run_guard) && rc=0 || rc=$?
assert_rc "exactly at budget is NOT stale" 0 "$rc"
set_fixture "$(mk_docs '37h ago')"
out=$(run_guard) && rc=0 || rc=$?
assert_rc "one hour past budget is stale" 3 "$rc"

echo "== age units =="
set_fixture "$(mk_docs 'just now')"
out=$(run_guard) && rc=0 || rc=$?
assert_rc "'just now' -> fresh" 0 "$rc"
# EXACT, not substring. This was the one branch that skipped the strict
# `<n><unit> ago` validation, so anything merely CONTAINING the phrase was
# converted to 0 hours and reported a confident all-clear — the single outcome
# this parser exists to prevent, reachable by exactly the format drift it
# hardens against everywhere else.
set_fixture "$(mk_docs 'unexpected just now garbage')"
out=$(run_guard) && rc=0 || rc=$?
assert_rc "a string merely CONTAINING 'just now' -> rc 6, not an all-clear" 6 "$rc"
assert_not_contains "and never an all-clear" "OK qmd-staleness" "$out"
set_fixture "$(mk_docs 'just now-ish')"
out=$(run_guard) && rc=0 || rc=$?
assert_rc "'just now-ish' is not 'just now'" 6 "$rc"
set_fixture "$(mk_docs '45m ago')"
out=$(run_guard) && rc=0 || rc=$?
assert_rc "minutes -> fresh" 0 "$rc"
set_fixture "$(mk_docs '2w ago')"
out=$(run_guard) && rc=0 || rc=$?
assert_rc "weeks -> stale" 3 "$rc"
# A single-letter unit capture read "1mo" as MINUTES (1/60 -> 0h -> "fresh"),
# so a months-old index passed as healthy and skipped rc 6 too, because `m` is
# a recognised unit. Silence on exactly the staleness this guard exists to
# catch — so months and years get explicit units, and the whole alphabetic run
# is captured.
set_fixture "$(mk_docs '1mo ago')"
out=$(run_guard) && rc=0 || rc=$?
assert_rc "months are STALE, never minutes" 3 "$rc"
assert_contains "months notice cites the real age" "1mo ago" "$out"
set_fixture "$(mk_docs '2 months ago')"
out=$(run_guard) && rc=0 || rc=$?
assert_rc "spelled-out months -> stale" 3 "$rc"
set_fixture "$(mk_docs '1y ago')"
out=$(run_guard) && rc=0 || rc=$?
assert_rc "years -> stale" 3 "$rc"
set_fixture "$(mk_docs '30 minutes ago')"
out=$(run_guard) && rc=0 || rc=$?
assert_rc "spelled-out minutes still fresh" 0 "$rc"
set_fixture "$(mk_docs '5 hours ago')"
out=$(run_guard) && rc=0 || rc=$?
assert_rc "spelled-out hours still fresh" 0 "$rc"
# An unrecognised unit must fail CLOSED, never be coerced to the nearest branch.
set_fixture "$(mk_docs '3 fortnights ago')"
out=$(run_guard) && rc=0 || rc=$?
assert_rc "unknown unit -> rc 6, not a guess" 6 "$rc"
set_fixture "$(mk_docs '1d ago')"
out=$(run_guard --max-age-hours 12) && rc=0 || rc=$?
assert_rc "custom budget is honoured" 3 "$rc"

echo "== zero-padded ages are decimal, not octal =="
# `$(( 09 * 24 ))` is an OCTAL literal to bash and dies with "value too great
# for base", which took down every multiplying unit (d/w/mo/y) on a zero-padded
# age. It failed closed — rc 6, nothing certified fresh — but it printed a raw
# bash error and then blamed the AGE PARSER for what was an arithmetic fault,
# which sends a reader after the wrong thing entirely.
set_fixture "$(mk_docs '09d ago')"
out=$(run_guard) && rc=0 || rc=$?
assert_rc "'09d ago' is 9 days STALE, not an arithmetic error" 3 "$rc"
assert_not_contains "no raw bash arithmetic error leaks out" "value too great for base" "$out"
assert_not_contains "and it is not misreported as unparseable" "could not parse the index age" "$out"
set_fixture "$(mk_docs '08 days ago')"
out=$(run_guard) && rc=0 || rc=$?
assert_rc "spelled-out zero-padded days too" 3 "$rc"
set_fixture "$(mk_docs '007w ago')"
out=$(run_guard) && rc=0 || rc=$?
assert_rc "multi-zero padding too" 3 "$rc"
# The hour branch echoes its digits instead of multiplying them, so it never
# hit the octal path — pin that it still reads as decimal.
set_fixture "$(mk_docs '08h ago')"
out=$(run_guard) && rc=0 || rc=$?
assert_rc "'08h ago' is 8 hours, comfortably inside a 36h budget" 0 "$rc"

echo "== fail-closed: unreadable report =="
set_fixture 'QMD Status

Documents
  Total:    10 files indexed
  Vectors:  20 embedded'
out=$(run_guard) && rc=0 || rc=$?
assert_rc "missing Updated: -> rc 6, not a silent all-clear" 6 "$rc"
assert_contains "says it cannot read the block" "could not read the Documents block" "$out"
assert_contains "tells the reader to distrust the index" "UNVERIFIED" "$out"

set_fixture 'QMD Status

Documents
  Updated:  2h ago'
out=$(run_guard) && rc=0 || rc=$?
assert_rc "missing Total:/Vectors: -> rc 6" 6 "$rc"

set_fixture "$(mk_docs 'sometime last Tuesday')"
out=$(run_guard) && rc=0 || rc=$?
assert_rc "unparseable age -> rc 6" 6 "$rc"
assert_contains "names the age it could not parse" "could not parse the index age" "$out"

set_fixture "$(mk_docs '2h ago' 'lots of chunks need embedding')"
out=$(run_guard) && rc=0 || rc=$?
assert_rc "present-but-unparseable Pending: -> rc 6" 6 "$rc"
assert_contains "names the pending line it could not parse" "could not parse the pending count" "$out"

echo "== qmd absent vs qmd broken are DIFFERENT exit codes =="
# The whole point of the split. Both used to be rc 2, and the hook is silent on
# rc 2 so adopters without qmd are not nagged — so a corrupt index, a locked
# sqlite file or a wedged qmd process produced no warning at all, which is the
# failure class this guard exists to catch happening to the guard itself.
set_fixture "$HOST_FRESH"
out=$(QMD_FAKE_RC=1 QMD_FIXTURE="$FIXTURE" bash "$SCRIPT" --qmd-bin "$FAKE" 2>&1) && rc=0 || rc=$?
assert_rc "'qmd status' failing -> rc 7, NOT the silent rc 2" 7 "$rc"
assert_contains "rc 7 says qmd is installed but did not answer" "qmd IS installed here" "$out"
assert_contains "rc 7 names the exit code it saw" "failed (exit 1)" "$out"
assert_contains "rc 7 tells the reader to distrust the index" "UNVERIFIED" "$out"
out=$(QMD_FAKE_RC=3 QMD_FIXTURE="$FIXTURE" bash "$SCRIPT" --qmd-bin "$FAKE" 2>&1) && rc=0 || rc=$?
assert_rc "any nonzero from 'qmd status' -> rc 7" 7 "$rc"
out=$(QMD_FIXTURE="$FIXTURE" bash "$SCRIPT" --qmd-bin "$TMP_ROOT/does-not-exist" 2>&1) && rc=0 || rc=$?
assert_rc "missing qmd binary -> rc 2 (not installed, stays silent)" 2 "$rc"
assert_contains "rc 2 names the unusable path" "is not an executable file" "$out"
# A DIRECTORY is present and `-x`-true, so an executability check alone would
# wave it through and only fail at invocation — which now means rc 7 ("qmd is
# broken") for something that is not qmd at all. `-f` is what separates them.
# (A chmod-based non-executable-file case is deliberately absent: MSYS keeps a
# shebanged file `-x` regardless of chmod, so it cannot be tested portably.)
out=$(QMD_FIXTURE="$FIXTURE" bash "$SCRIPT" --qmd-bin "$TMP_ROOT" 2>&1) && rc=0 || rc=$?
assert_rc "a directory as --qmd-bin -> rc 2, not rc 7" 2 "$rc"
out=$(QMD_FIXTURE="$FIXTURE" bash "$SCRIPT" --qmd-bin "$FAKE" --qmd-js "$TMP_ROOT/no-such.js" 2>&1) && rc=0 || rc=$?
assert_rc "missing --qmd-js file -> rc 2" 2 "$rc"

echo "== required collections =="
# win2's ACTUAL incident shape: index fresh, index complete, an entire
# collection simply absent. Freshness and completeness are properties of the
# documents that ARE indexed, so this scored rc 0 — the guard promised a check
# it did not perform.
set_fixture "$HOST_FRESH"
out=$(run_guard --require-collections himmel,luna-curated) && rc=0 || rc=$?
assert_rc "all required collections present -> rc 0" 0 "$rc"
out=$(run_guard --require-collections himmel,salus) && rc=0 || rc=$?
assert_rc "fresh+complete index missing a required collection -> rc 8" 8 "$rc"
assert_contains "names the missing collection" "MISSING required collection(s): salus" "$out"
assert_contains "explains a miss against it is meaningless" "NOT SEARCHABLE here at all" "$out"
assert_not_contains "does not invent staleness" "may be STALE" "$out"
out=$(run_guard --require-collections salus,notes) && rc=0 || rc=$?
assert_contains "names EVERY missing collection" "salus, notes" "$out"
# Opt-in: with the flag absent nothing is checked, so the same fixture is clean.
out=$(run_guard) && rc=0 || rc=$?
assert_rc "collection check is opt-in (absent flag -> rc 0)" 0 "$rc"
# Precedence: a stale AND collection-missing index reports both, exits 8.
set_fixture 'QMD Status

Documents
  Total:    10 files indexed
  Vectors:  20 embedded
  Updated:  9d ago

Collections
  himmel (qmd://himmel/)
    Files:    285 (updated 1d ago)'
out=$(run_guard --require-collections himmel,salus) && rc=0 || rc=$?
assert_rc "missing collection outranks stale in the exit code" 8 "$rc"
assert_contains "but the banner still reports the staleness" "qmd index may be STALE" "$out"
assert_contains "and still reports the missing collection" "MISSING required collection(s): salus" "$out"
# Fail CLOSED: a required set that cannot be checked is rc 6, never rc 0. The
# Documents block here is perfectly readable — only the Collections block is
# gone, which is exactly how a rewording would silently disable this check.
set_fixture "$(mk_docs '2h ago')"
out=$(run_guard --require-collections himmel) && rc=0 || rc=$?
assert_rc "no Collections block + a required set -> rc 6, not a pass" 6 "$rc"
assert_contains "says it could not read the collection list" "no Collections block" "$out"
out=$(run_guard) && rc=0 || rc=$?
assert_rc "no Collections block WITHOUT the flag is still fine" 0 "$rc"

echo "== required-collections usage errors =="
set_fixture "$HOST_FRESH"
out=$(run_guard --require-collections) && rc=0 || rc=$?
assert_rc "flag without a value -> rc 1" 1 "$rc"
out=$(run_guard --require-collections "") && rc=0 || rc=$?
assert_rc "empty list -> rc 1, never a silently-skipped check" 1 "$rc"
out=$(run_guard --require-collections "himmel,,luna") && rc=0 || rc=$?
assert_rc "empty entry -> rc 1" 1 "$rc"
out=$(run_guard --require-collections "himmel,") && rc=0 || rc=$?
assert_rc "trailing comma -> rc 1" 1 "$rc"
out=$(run_guard --require-collections "himmel luna") && rc=0 || rc=$?
assert_rc "space-separated (not comma) -> rc 1" 1 "$rc"
# The other two operands the guard singles out under the same rule — "a flag
# that was passed must never be a no-op". An empty --qmd-bin falls through to
# PATH resolution, so a caller who passed it to PIN qmd ends up unpinned;
# --require-collections was the only one pinned here.
out=$(QMD_FIXTURE="$FIXTURE" bash "$SCRIPT" --qmd-bin "" 2>&1) && rc=0 || rc=$?
assert_rc "empty --qmd-bin -> rc 1, never a silent PATH fallback" 1 "$rc"
out=$(run_guard --qmd-js "") && rc=0 || rc=$?
assert_rc "empty --qmd-js -> rc 1" 1 "$rc"

echo "== usage errors =="
out=$(run_guard --max-age-hours abc) && rc=0 || rc=$?
assert_rc "non-numeric budget -> rc 1, never a silent default" 1 "$rc"
out=$(run_guard --max-age-hours -5) && rc=0 || rc=$?
assert_rc "negative budget -> rc 1" 1 "$rc"
out=$(run_guard --max-age-hours) && rc=0 || rc=$?
assert_rc "budget flag without a value -> rc 1" 1 "$rc"
out=$(run_guard --nope) && rc=0 || rc=$?
assert_rc "unknown flag -> rc 1" 1 "$rc"
# --qmd-js alone is worse than meaningless: PATH resolution OVERWRITES QMD_JS,
# so it would be silently discarded and the guard would run a different qmd
# than the caller named. Same rule as the empty-operand checks — a flag that
# was passed must never be a no-op.
out=$(QMD_FIXTURE="$FIXTURE" bash "$SCRIPT" --qmd-js "$FAKE" 2>&1) && rc=0 || rc=$?
assert_rc "--qmd-js without --qmd-bin -> rc 1, never a silent discard" 1 "$rc"
assert_contains "says which flag it needs" "--qmd-js requires --qmd-bin" "$out"
out=$(run_guard --help) && rc=0 || rc=$?
assert_rc "--help -> rc 0" 0 "$rc"
assert_contains "--help shows the exit codes" "Exit codes" "$out"

summary
