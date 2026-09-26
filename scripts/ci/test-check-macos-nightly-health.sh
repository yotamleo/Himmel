#!/usr/bin/env bash
# Smoke test for scripts/ci/check-macos-nightly-health.sh (HIMMEL-3699).
# Stubs `gh api ... --jq <expr>` with a fake gh that runs the SAME jq
# expression against a canned jobs-API fixture, so this exercises the real
# filter logic, not just the branch logic around it. No network, no auth.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/ci/check-macos-nightly-health.sh"
TMP="$(mktemp -d "/tmp/himmel-test-macos-health.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT

fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

if bash -n "$SCRIPT"; then ok "syntax (bash -n)"; else bad "syntax"; fi

cat > "$TMP/gh" <<'EOF'
#!/usr/bin/env bash
# fake gh: only supports `gh api <path> --paginate --jq <expr>`, applying
# <expr> to $FAKE_GH_JOBS_JSON the same way the real `gh api --jq` would.
set -u
if [ "${1:-}" != "api" ]; then
  echo "fake-gh: unsupported invocation: $*" >&2
  exit 1
fi
shift
shift # the API path — unused by the fake, it only ever serves one fixture
jq_expr=""
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) jq_expr="$2"; shift 2 ;;
    --paginate) shift ;;
    *) shift ;;
  esac
done
jq -r "$jq_expr" < "$FAKE_GH_JOBS_JSON"
EOF
chmod +x "$TMP/gh"

cat > "$TMP/jobs-green.json" <<'JSON'
{"jobs":[
  {"name":"shell-unit-shard (macos-latest, 1)","conclusion":"success"},
  {"name":"shell-unit-shard (macos-latest, 2)","conclusion":"skipped"},
  {"name":"shell-unit-shard (ubuntu-latest, 1)","conclusion":"success"}
]}
JSON

cat > "$TMP/jobs-red.json" <<'JSON'
{"jobs":[
  {"name":"shell-unit-shard (macos-latest, 1)","conclusion":"success"},
  {"name":"shell-unit-shard (macos-latest, 3)","conclusion":"failure"},
  {"name":"shell-unit-shard (ubuntu-latest, 1)","conclusion":"success"}
]}
JSON

out_green="$(FAKE_GH_JOBS_JSON="$TMP/jobs-green.json" PATH="$TMP:$PATH" REPO=owner/repo RUN_ID=1 bash "$SCRIPT" 2>&1)"
rc_green=$?
if [ "$rc_green" -eq 0 ]; then ok "all-green fixture -> exit 0"; else bad "all-green fixture exit=$rc_green (want 0): $out_green"; fi
if grep -q "OK: no failing macOS job" <<< "$out_green"; then ok "all-green -> OK message"; else bad "all-green missing OK message: $out_green"; fi

out_red="$(FAKE_GH_JOBS_JSON="$TMP/jobs-red.json" PATH="$TMP:$PATH" REPO=owner/repo RUN_ID=1 bash "$SCRIPT" 2>&1)"
rc_red=$?
if [ "$rc_red" -eq 1 ]; then ok "red fixture (one macOS job failed) -> exit 1"; else bad "red fixture exit=$rc_red (want 1): $out_red"; fi
if grep -q "macOS nightly job(s) failed" <<< "$out_red"; then ok "red -> error banner"; else bad "red missing error banner: $out_red"; fi
if grep -q "shell-unit-shard (macos-latest, 3)" <<< "$out_red"; then ok "red -> names the failing job"; else bad "red does not name the failing job: $out_red"; fi

# HIMMEL-3699 (CR round 1, codex-1): a failed `gh api` call must fail loudly,
# not read as an empty (all-clear) job list.
cat > "$TMP/gh-fail" <<'EOF'
#!/usr/bin/env bash
echo "fake-gh: simulated API failure" >&2
exit 1
EOF
chmod +x "$TMP/gh-fail"
gfdir="$TMP/ghfaildir"
mkdir -p "$gfdir"
cp "$TMP/gh-fail" "$gfdir/gh"

out_apifail="$(PATH="$gfdir:$PATH" REPO=owner/repo RUN_ID=1 bash "$SCRIPT" 2>&1)"
rc_apifail=$?
if [ "$rc_apifail" -eq 1 ]; then ok "gh api failure -> exit 1 (not silent OK)"; else bad "gh api failure exit=$rc_apifail (want 1): $out_apifail"; fi
if grep -q "gh api call failed" <<< "$out_apifail"; then ok "gh api failure -> error banner"; else bad "gh api failure missing error banner: $out_apifail"; fi
if grep -q "OK: no failing macOS job" <<< "$out_apifail"; then bad "gh api failure wrongly reported OK: $out_apifail"; else ok "gh api failure -> no false OK"; fi

# HIMMEL-3699 (CR round 1, codex-2): an empty jobs response, or one with no
# macOS jobs at all, must not read as an all-clear OK.
cat > "$TMP/jobs-none.json" <<'JSON'
{"jobs":[
  {"name":"shell-unit-shard (ubuntu-latest, 1)","conclusion":"success"}
]}
JSON

out_none="$(FAKE_GH_JOBS_JSON="$TMP/jobs-none.json" PATH="$TMP:$PATH" REPO=owner/repo RUN_ID=1 bash "$SCRIPT" 2>&1)"
rc_none=$?
if [ "$rc_none" -eq 1 ]; then ok "no-macOS-jobs fixture -> exit 1 (not silent OK)"; else bad "no-macOS-jobs fixture exit=$rc_none (want 1): $out_none"; fi
if grep -q "no macOS job actually passed" <<< "$out_none"; then ok "no-macOS-jobs -> error banner"; else bad "no-macOS-jobs missing error banner: $out_none"; fi
if grep -q "OK: no failing macOS job" <<< "$out_none"; then bad "no-macOS-jobs wrongly reported OK: $out_none"; else ok "no-macOS-jobs -> no false OK"; fi

# HIMMEL-3699 (CR round 2, codex-1): every macOS job SKIPPED (none passed, none
# failed) must not read as an all-clear OK either — nothing was actually tested.
cat > "$TMP/jobs-all-skipped.json" <<'JSON'
{"jobs":[
  {"name":"shell-unit-shard (macos-latest, 1)","conclusion":"skipped"},
  {"name":"shell-unit-shard (macos-latest, 2)","conclusion":"skipped"},
  {"name":"shell-unit-shard (ubuntu-latest, 1)","conclusion":"success"}
]}
JSON

out_skip="$(FAKE_GH_JOBS_JSON="$TMP/jobs-all-skipped.json" PATH="$TMP:$PATH" REPO=owner/repo RUN_ID=1 bash "$SCRIPT" 2>&1)"
rc_skip=$?
if [ "$rc_skip" -eq 1 ]; then ok "all-macOS-skipped fixture -> exit 1 (not silent OK)"; else bad "all-macOS-skipped fixture exit=$rc_skip (want 1): $out_skip"; fi
if grep -q "no macOS job actually passed" <<< "$out_skip"; then ok "all-macOS-skipped -> error banner"; else bad "all-macOS-skipped missing error banner: $out_skip"; fi
if grep -q "OK: no failing macOS job" <<< "$out_skip"; then bad "all-macOS-skipped wrongly reported OK: $out_skip"; else ok "all-macOS-skipped -> no false OK"; fi

echo "---"
if [ "$fails" -eq 0 ]; then
  echo "PASSED"
  exit 0
else
  echo "FAILED=$fails"
  exit 1
fi
