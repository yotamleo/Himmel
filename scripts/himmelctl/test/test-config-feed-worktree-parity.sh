#!/usr/bin/env bash
# test-config-feed-worktree-parity.sh — HIMMEL-4403: the config feed
# (`himmelctl report --json`) answers the same rows from the primary checkout
# and from a linked worktree of it. Rows whose answer must not depend on which
# checkout served them are the whole feed minus the envelope fields that name
# the checkout (generatedAt, probedAt, target.path, himmel.checkout).
#
# Also pins feed.himmel = {version, describe, commit, checkout}: the data the
# config UI header shows (HIMMEL-4405), with `checkout` naming the SERVED tree.
#
# Hermetic: fixture primary + `git worktree add`, fake HOME/cache, doctor and
# cadence seams stubbed (the test-config-feed.sh shape). HANDOVER_DIR is set
# ONLY in the primary's .env, never in the process env, which is exactly the
# config-UI launch the ticket reports.

set -uo pipefail

repo_root=$(git rev-parse --show-toplevel)
# shellcheck disable=SC1091
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"
wizard="$repo_root/scripts/himmelctl/bin.js"
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }
node_bin=$(command -v node)

# The launching shell may export HANDOVER_DIR; the scenario under test is its absence.
unset HANDOVER_DIR

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "PASS: $1"; }

work=$(mktemp -d "${TMPDIR:-/tmp}/feed-parity.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

primary="$work/primary"; wt="$work/wt"
mkdir -p "$primary/scripts/install" "$primary/scripts/lanes" "$primary/scripts/lib"
cp "$repo_root/scripts/install/manifest.json" "$primary/scripts/install/manifest.json"
cp "$repo_root/scripts/lib/handover-path.sh" "$repo_root/scripts/lib/load-dotenv.sh" "$primary/scripts/lib/"
echo '{"lanes":[{"id":"haiku","label":"Haiku"}]}' > "$primary/scripts/lanes/lanes.json"
echo "9.9.9" > "$primary/VERSION"
mkdir -p "$primary/handovers" "$work/real-root"
git -C "$primary" init -q -b main
git -C "$primary" add -A
git -C "$primary" -c user.name=t -c user.email=t@t commit -q -m fixture
git -C "$primary" worktree add -q "$wt" -b parity-wt
printf 'HANDOVER_DIR=%s\n' "$work/real-root" > "$primary/.env"
real_root=$(cd "$work/real-root" && pwd)

homeDir="$work/home"; mkdir -p "$homeDir/.claude" "$homeDir/.himmel/state/doctor-cadence"
cacheDir="$work/cache"; mkdir -p "$cacheDir"
cat > "$cacheDir/install-profile.json" <<'JSON'
{"role":"adopter","tier":"standard","scope":"user","vault":{"mode":"none","path":""},"handover":{"mode":"inline","path":""},"pluginSet":"lean","lanes":[],"lanesMeaningful":true,"alwaysOn":false}
JSON
stubDoctor="$work/stub-doctor.sh"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" '"'"'{"sev":"OK","id":"C1-guardrail","msg":"ok","remedy":""}'"'"'\n' > "$stubDoctor"
chmod +x "$stubDoctor"
fakeBin="$work/fakebin"; mkdir -p "$fakeBin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$fakeBin/crontab"; chmod +x "$fakeBin/crontab"

run_report() {  # run_report <served checkout>
  ( cd "$work" && HOME="$homeDir" USERPROFILE="$(winpath "$homeDir")" \
      HIMMELCTL_CACHE_DIR="$(winpath "$cacheDir")" HIMMELCTL_REPO_ROOT="$(winpath "$1")" \
      HIMMEL_LUNA_CONFIG_PATH="$(winpath "$cacheDir")-luna-config.json" \
      HIMMEL_REPORT_DOCTOR="$(winpath "$stubDoctor")" HIMMEL_REPORT_CADENCE_ROOT="$(winpath "$primary")" \
      PATH="$fakeBin:$PATH" "$node_bin" "$wizard" report --json )
}

run_report "$primary" > "$work/primary.json" 2> "$work/primary.err" || { cat "$work/primary.err" >&2; fail "report from the primary exited non-zero"; }
run_report "$wt" > "$work/wt.json" 2> "$work/wt.err" || { cat "$work/wt.err" >&2; fail "report from the worktree exited non-zero"; }

norm='del(.generatedAt, .target.path, .himmel.checkout) | .rows |= map(del(.probedAt))'
jq -S "$norm" "$work/primary.json" > "$work/primary.norm"
jq -S "$norm" "$work/wt.json" > "$work/wt.norm"
diff "$work/primary.norm" "$work/wt.norm" > "$work/feed.diff" \
  || { head -40 "$work/feed.diff" >&2; fail "feed rows differ between the primary and a worktree"; }
pass "feed is identical from the primary and from a linked worktree"

for f in primary wt; do
  jq -e --arg d "$real_root" '[.rows[]|select(.id=="handover-wiring")] | length == 1 and .[0].installed.state == "present" and .[0].installed.detail == $d' \
    "$work/$f.json" >/dev/null || fail "handover-wiring from $f must read the primary .env root $real_root (got: $(jq -c '[.rows[]|select(.id=="handover-wiring")|.installed]' "$work/$f.json"))"
done
pass "handover-wiring reads the .env root, not the checkout's handovers/ stub, from both"

primary_phys=$(cd "$primary" && pwd -P); wt_phys=$(cd "$wt" && pwd -P)
jq -e '.himmel | (.version == "9.9.9") and (.describe | length > 0) and (.commit | test("^[0-9a-f]{40}$"))' "$work/wt.json" >/dev/null \
  || fail "feed.himmel lacks version/describe/commit (got: $(jq -c .himmel "$work/wt.json"))"
[ "$(jq -r '.himmel.checkout' "$work/primary.json")" = "$primary_phys" ] || [ "$(jq -r '.himmel.checkout' "$work/primary.json")" = "$primary" ] \
  || fail "feed.himmel.checkout from the primary is not the primary"
[ "$(jq -r '.himmel.checkout' "$work/wt.json")" = "$wt_phys" ] || [ "$(jq -r '.himmel.checkout' "$work/wt.json")" = "$wt" ] \
  || fail "feed.himmel.checkout from the worktree is not the worktree (got: $(jq -r '.himmel.checkout' "$work/wt.json"))"
pass "feed.himmel carries version/describe/commit and names the served checkout"
