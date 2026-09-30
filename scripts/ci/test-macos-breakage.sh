#!/usr/bin/env bash
# scripts/ci/test-macos-breakage.sh -- HIMMEL-3902: the os:macos cadence
# breakage metric. Fixture JSON for two cadence runs -> the new-breakage list;
# the record builder; the gh-facing previous-run lookup and per-week read-back,
# driven by a fake `gh` that serves fixtures. No network, no auth.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/ci/macos-breakage.sh"
TMP="$(mktemp -d "/tmp/himmel-test-macos-breakage.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT

fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

[ -f "$SCRIPT" ] || { bad "macos-breakage.sh does not exist at $SCRIPT"; echo "$fails failed" >&2; exit 1; }
if bash -n "$SCRIPT"; then ok "syntax (bash -n)"; else bad "syntax"; fi

# --- diff: suites red now that were green on the previous run ---------------
echo '{"run_id":1,"head_sha":"aaa","failed":["s/a.sh","s/b.sh"]}' > "$TMP/prev.json"
echo '{"run_id":2,"head_sha":"bbb","failed":["s/b.sh","s/d.sh","s/c.sh"]}' > "$TMP/cur.json"
got="$(bash "$SCRIPT" diff "$TMP/prev.json" "$TMP/cur.json" | tr '\n' ' ')"
if [ "$got" = "s/c.sh s/d.sh " ]; then ok "diff lists only newly-red suites, sorted (still-red b and fixed a excluded)"
else bad "diff gave '$got' (want 's/c.sh s/d.sh ')"; fi

echo '{"run_id":3,"head_sha":"ccc","failed":["s/b.sh"]}' > "$TMP/cur2.json"
got="$(bash "$SCRIPT" diff "$TMP/cur.json" "$TMP/cur2.json")"
if [ -z "$got" ]; then ok "diff is empty when nothing new went red"; else bad "diff gave '$got' (want empty)"; fi

got="$(bash "$SCRIPT" diff "$TMP/no-such.json" "$TMP/cur.json")"
if [ -z "$got" ]; then ok "diff against a missing previous record is a baseline (no breakages)"
else bad "baseline diff gave '$got' (want empty)"; fi

# --- suites-from-logs: decode FAIL_LOG_DIR's injective escape ---------------
mkdir -p "$TMP/logs"
: > "$TMP/logs/scripts_sci_stest-macos-breakage.sh.log"
: > "$TMP/logs/scripts_shandover_stest-arm-resume.sh.log"
# fixture logs as run-shell-tests' own self-tests name them (HIMMEL-3906)
: > "$TMP/logs/test-127-3.sh.log"
: > "$TMP/logs/test-slowpoke.sh.log"
# suites-from-logs asks git which suites are tracked, so run it from the checkout
sfl() ( cd "$ROOT" && bash "$SCRIPT" suites-from-logs "$@" )
got="$(sfl "$TMP/logs" 2>"$TMP/sfl.err" | tr '\n' ' ')"
if [ "$got" = "scripts/ci/test-macos-breakage.sh scripts/handover/test-arm-resume.sh " ]; then
  ok "suites-from-logs keeps tracked suites (incl. one in a subdirectory) and drops self-test fixture logs"
else bad "suites-from-logs gave '$got'"; fi
if grep -q 'dropped 2' "$TMP/sfl.err" && grep -q 'test-127-3.sh' "$TMP/sfl.err" && grep -q 'test-slowpoke.sh' "$TMP/sfl.err"; then
  ok "suites-from-logs reports the dropped fixtures on stderr (count + names)"
else bad "stderr gave '$(cat "$TMP/sfl.err")'"; fi
got="$(sfl "$TMP/no-such-dir")"
if [ -z "$got" ]; then ok "suites-from-logs on a missing dir is empty"; else bad "missing dir gave '$got'"; fi
mkdir -p "$TMP/emptylogs"
got="$(sfl "$TMP/emptylogs" 2>&1)"
if [ -z "$got" ]; then ok "suites-from-logs on an empty dir is empty and quiet"; else bad "empty dir gave '$got'"; fi

# --- record: union the shard lists, diff against the previous record --------
mkdir -p "$TMP/art/macos-failed-suites-shard1" "$TMP/art/macos-failed-suites-shard2"
printf 's/b.sh\ns/c.sh\n' > "$TMP/art/macos-failed-suites-shard1/failed.txt"
printf 's/d.sh\ns/b.sh\n' > "$TMP/art/macos-failed-suites-shard2/failed.txt"
bash "$SCRIPT" record --run-id 2 --head-sha bbb --run-at 2026-09-30T06:17:00Z \
  --shards-result failure --failed-dir "$TMP/art" --prev-file "$TMP/prev.json" \
  --out "$TMP/rec.json" > "$TMP/summary.md"
if jq -e '.run_id == 2 and .head_sha == "bbb" and .prev_run_id == 1 and .prev_head_sha == "aaa"
          and (.failed == ["s/b.sh","s/c.sh","s/d.sh"])
          and (.new_breakages == ["s/c.sh","s/d.sh"]) and .infra_suspect == false' "$TMP/rec.json" >/dev/null; then
  ok "record unions shard lists, dedupes, and computes new_breakages vs the previous run"
else bad "record JSON wrong: $(cat "$TMP/rec.json" 2>&1)"; fi
if grep -q 'aaa' "$TMP/summary.md" && grep -q 'bbb' "$TMP/summary.md" && grep -q 's/c.sh' "$TMP/summary.md"; then
  ok "summary row names both head shas and the new breakages"
else bad "summary row incomplete: $(cat "$TMP/summary.md")"; fi

bash "$SCRIPT" record --run-id 5 --head-sha eee --run-at 2026-10-02T06:17:00Z \
  --shards-result success --failed-dir "$TMP/none" --out "$TMP/rec-base.json" > /dev/null
if jq -e '.prev_run_id == null and .new_breakages == [] and .failed == [] and .infra_suspect == false' "$TMP/rec-base.json" >/dev/null; then
  ok "record with no previous run is a baseline (null prev, no new breakages)"
else bad "baseline record wrong: $(cat "$TMP/rec-base.json" 2>&1)"; fi

bash "$SCRIPT" record --run-id 6 --head-sha fff --run-at 2026-10-03T06:17:00Z \
  --shards-result failure --failed-dir "$TMP/none" --out "$TMP/rec-infra.json" > /dev/null
if jq -e '.infra_suspect == true' "$TMP/rec-infra.json" >/dev/null; then
  ok "a red run with zero failed suites is flagged infra_suspect (crashed shard, not a suite red)"
else bad "infra_suspect not set on red-with-no-suites"; fi

bash "$SCRIPT" record --run-id 7 --head-sha ggg --run-at 2026-10-04T06:17:00Z \
  --shards-result failure --shards-expected 3 --failed-dir "$TMP/art" --out "$TMP/rec-short.json" > /dev/null
if jq -e '.infra_suspect == true' "$TMP/rec-short.json" >/dev/null; then
  ok "a red run where fewer shards reported than expected is infra_suspect (list is incomplete)"
else bad "infra_suspect not set when 2 of 3 shards reported on a red run"; fi
bash "$SCRIPT" record --run-id 8 --head-sha hhh --run-at 2026-10-04T06:17:00Z \
  --shards-result failure --shards-expected 2 --failed-dir "$TMP/art" --out "$TMP/rec-full.json" > /dev/null
if jq -e '.infra_suspect == false' "$TMP/rec-full.json" >/dev/null; then
  ok "a red run where every expected shard reported is a suite red, not infra"
else bad "infra_suspect wrongly set when 2 of 2 shards reported"; fi

# --- gh-facing: previous-record lookup + per-week read-back -----------------
mkdir -p "$TMP/fake"
cat > "$TMP/fake/gh" <<'GH'
#!/usr/bin/env bash
# fake gh: `run list ... --jq <expr>` applies <expr> to $FAKE_RUNS; `run download <id> -n <name> -D <dir>`
# copies $FAKE_DIR/<id>.json to <dir>/record.json, or fails when there is none.
set -u
if [ "${1:-}" = api ]; then
  # api repos/o/r/actions/runs/<id>/artifacts...: prints an artifact id iff the run has a record.
  [ -z "${FAKE_API_FAIL:-}" ] || { echo "fake-gh: api failed" >&2; exit 1; }
  id="${2#*runs/}"; id="${id%%/*}"
  [ -f "$FAKE_DIR/$id.json" ] && echo 1
  exit 0
fi
[ "${1:-}" = run ] || { echo "fake-gh: unsupported: $*" >&2; exit 1; }
sub="$2"; shift 2
case "$sub" in
  list)
    expr="."
    while [ $# -gt 0 ]; do case "$1" in --jq) expr="$2"; shift 2 ;; *) shift ;; esac; done
    jq -r "$expr" < "$FAKE_RUNS" ;;
  download)
    id="$1"; shift; dir=""
    while [ $# -gt 0 ]; do case "$1" in -D) dir="$2"; shift 2 ;; *) shift ;; esac; done
    [ -f "$FAKE_DIR/$id.json" ] || exit 1
    mkdir -p "$dir"; cp "$FAKE_DIR/$id.json" "$dir/record.json" ;;
esac
GH
chmod +x "$TMP/fake/gh"
mkdir -p "$TMP/recs"
# 30 has no record (cancelled run), 20 and 10 do; 40 is the current run.
echo '[{"databaseId":40,"headSha":"h40"},{"databaseId":30,"headSha":"h30"},{"databaseId":20,"headSha":"h20"},{"databaseId":10,"headSha":"h10"}]' > "$TMP/runs.json"
echo '{"run_id":20,"head_sha":"h20","run_at":"2026-09-29T06:17:00Z","failed":["s/x.sh"],"new_breakages":["s/x.sh"],"prev_run_id":10,"prev_head_sha":"h10","infra_suspect":false}' > "$TMP/recs/20.json"
echo '{"run_id":10,"head_sha":"h10","run_at":"2026-09-28T06:17:00Z","failed":[],"new_breakages":[],"prev_run_id":null,"prev_head_sha":null,"infra_suspect":false}' > "$TMP/recs/10.json"
echo '{"run_id":40,"head_sha":"h40","run_at":"2026-10-06T06:17:00Z","failed":["s/x.sh","s/y.sh"],"new_breakages":["s/y.sh"],"prev_run_id":20,"prev_head_sha":"h20","infra_suspect":false}' > "$TMP/recs/40.json"

if PATH="$TMP/fake:$PATH" FAKE_RUNS="$TMP/runs.json" FAKE_DIR="$TMP/recs" \
   bash "$SCRIPT" prev-record --repo o/r --run-id 40 --dest "$TMP/prev-found.json" \
   && jq -e '.run_id == 20' "$TMP/prev-found.json" >/dev/null; then
  ok "prev-record skips the current run and a record-less run, returns the newest recorded one"
else bad "prev-record did not return run 20"; fi

PATH="$TMP/fake:$PATH" FAKE_RUNS="$TMP/runs.json" FAKE_DIR="$TMP/none" \
  bash "$SCRIPT" prev-record --repo o/r --run-id 40 --dest "$TMP/prev-none.json" >/dev/null 2>&1
rc=$?
if [ "$rc" = 1 ]; then ok "prev-record exits 1 (baseline) when no earlier run has a record"
else bad "prev-record rc=$rc with no recorded run (want exactly 1)"; fi

rep="$(PATH="$TMP/fake:$PATH" FAKE_RUNS="$TMP/runs.json" FAKE_DIR="$TMP/recs" \
       bash "$SCRIPT" report --repo o/r --limit 10 2>&1)"
if grep -q 'h20' <<< "$rep" && grep -q 'h40' <<< "$rep" && grep -q 's/y.sh' <<< "$rep"; then
  ok "report lists each recorded run with its head sha and new breakages"
else bad "report per-run rows missing: $rep"; fi
# 2026-09-28 and 2026-09-29 are ISO week 40 (0 + 1 new); 2026-10-06 is week 41 (1 new).
if grep -Eq '2026-W40[[:space:]]+runs=2[[:space:]]+new_breakages=1' <<< "$rep" \
   && grep -Eq '2026-W41[[:space:]]+runs=1[[:space:]]+new_breakages=1' <<< "$rep"; then
  ok "report totals runs and new breakages per ISO week"
else bad "report week totals wrong: $rep"; fi

# a lookup failure must NOT read as "no earlier record" (fail closed, rc 2).
PATH="$TMP/fake:$PATH" FAKE_API_FAIL=1 FAKE_RUNS="$TMP/runs.json" FAKE_DIR="$TMP/recs" \
  bash "$SCRIPT" prev-record --repo o/r --run-id 40 --dest "$TMP/prev-err.json" >/dev/null 2>&1
rc=$?
if [ "$rc" = 2 ]; then ok "prev-record fails closed (rc 2) when the artifact lookup errors"
else bad "prev-record rc=$rc on a lookup failure (want 2, not the baseline rc 1)"; fi

# fewer shard reports than expected is infra_suspect even when the shards said success.
mkdir -p "$TMP/fd1"; echo "s/a.sh" > "$TMP/fd1/failed.txt"
bash "$SCRIPT" record --run-id 5 --head-sha h5 --run-at 2026-09-30T00:00:00Z --shards-result success \
  --failed-dir "$TMP/fd1" --shards-expected 8 --out "$TMP/rec5.json" >/dev/null
if jq -e '.infra_suspect == true' "$TMP/rec5.json" >/dev/null; then ok "1 of 8 reports on a success run is infra_suspect"
else bad "incomplete report set not flagged infra_suspect"; fi

# option without a value must fail fast, not spin (shift 2 fails on 1 arg).
tmo="$(command -v timeout || command -v gtimeout || true)"  # absent on stock macOS: then a regression hangs instead of failing
# shellcheck disable=SC2086 # $tmo is empty or one command name
if ${tmo:+$tmo 10} bash "$SCRIPT" record --run-id >/dev/null 2>&1; then bad "record with a value-less option succeeded"
else rc=$?; if [ "$rc" = 2 ]; then ok "a value-less option is refused (rc 2), no infinite loop"; else bad "value-less option rc=$rc (124 = hung)"; fi; fi

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed" >&2
exit 1
