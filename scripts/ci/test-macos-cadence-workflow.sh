#!/usr/bin/env bash
# scripts/ci/test-macos-cadence-workflow.sh -- HIMMEL-3902: pins the shape of
# .github/workflows/macos-cadence.yml, the lower-frequency os:macos workflow.
# Text assertions over the workflow with comments stripped (a comment cannot
# satisfy a policy check). No network, no PyYAML.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WF="${WF:-$ROOT/.github/workflows/macos-cadence.yml}"
CI_YML="${CI_YML:-$ROOT/.github/workflows/ci.yml}"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

[ -f "$WF" ] || { bad "macos-cadence.yml does not exist at $WF"; echo "$fails failed" >&2; exit 1; }
strip() { sed -e '/^[[:space:]]*#/d' -e 's/[[:space:]][[:space:]]*#.*$//' "$1"; }
s="$(strip "$WF")"

# 1. identifiable as os:macos.
if grep -q '^name: "CI (os:macos cadence)"$' <<< "$s"; then ok "workflow name carries os:macos"
else bad "workflow name is not exactly \"CI (os:macos cadence)\""; fi

# 2. triggers: schedule + workflow_dispatch only, never per-PR / per-push.
on_block="$(awk '/^on:/ {f=1; next} f && /^[a-z]/ {f=0} f' <<< "$s")"
keys="$(sed -n 's/^  \([a-z_]*\):.*/\1/p' <<< "$on_block" | tr '\n' ' ')"
if [ "$keys" = "workflow_dispatch schedule " ]; then ok "triggers are workflow_dispatch + schedule only"
else bad "triggers are '$keys' (want workflow_dispatch + schedule; never pull_request/push)"; fi

# 3. lower frequency than nightly: the cron's day-of-week field is restricted.
cron="$(sed -n "s/^[[:space:]]*- cron: '\([^']*\)'.*/\1/p" <<< "$s")"
dow="$(awk '{print $5}' <<< "$cron")"
if [ -n "$cron" ] && [ "$(wc -l <<< "$cron" | tr -d ' ')" = 1 ] && [ "$dow" != "*" ] && [ -n "$dow" ]; then
  ok "one cron ('$cron'), day-of-week restricted -> less often than nightly"
else bad "cron is not a single weekday-restricted schedule: '$cron'"; fi

# 4. least privilege + no advisory masking.
top_perm="$(awk '/^permissions:/ {f=1; next} f && /^[a-z]/ {f=0} f' <<< "$s" | sed '/^[[:space:]]*$/d')"
if [ "$top_perm" = "  contents: read" ]; then ok "top-level permissions are exactly contents: read"
else bad "top-level permissions are not exactly contents: read: $top_perm"; fi
extra="$(grep -E '^[[:space:]]+[a-z-]+: (read|write)$' <<< "$s" | sed 's/^[[:space:]]*//' | sort -u | tr '\n' ' ')"
if [ "$extra" = "actions: read contents: read " ]; then ok "the only permissions anywhere are contents: read and actions: read"
else bad "permission set is '$extra' (want exactly actions: read + contents: read)"; fi
if grep -q 'continue-on-error' <<< "$s"; then bad "a job tolerates failure (continue-on-error): a macOS red must redden THIS run"
else ok "no continue-on-error: a macOS red is a red of this workflow"; fi

# 5. every job is named with the cadence prefix; shards run on macOS, full corpus.
if [ "$(grep -c '^    name: ' <<< "$s")" = "$(grep -cE '^  [a-z][a-z-]*:$' <<< "$(awk '/^jobs:/ {f=1; next} f' <<< "$s")")" ] \
   && ! grep '^    name: ' <<< "$s" | grep -qv 'macos-cadence / '; then
  ok "every job name starts with 'macos-cadence / '"
else bad "a job has no name or one without the 'macos-cadence / ' prefix"; fi
# shellcheck disable=SC2016 # the ${{ }} is literal workflow text
if grep -q 'os: \[macos-latest\]' <<< "$s" && grep -q 'runs-on: \${{ matrix.os }}' <<< "$s"; then ok "shard matrix is macos-latest"
else bad "shard matrix is not macos-latest"; fi
if grep -q "SUITE_TIER_MODE: all" <<< "$s"; then ok "SUITE_TIER_MODE is all (the nightly's macOS coverage)"
else bad "SUITE_TIER_MODE is not all"; fi

# 6. shard count spelled three ways must agree, and match ci.yml's partition.
list="$(sed -n 's/^[[:space:]]*shard: \[\(.*\)\]$/\1/p' <<< "$s" | tr -d ' ')"
n_list="$(tr ',' '\n' <<< "$list" | grep -c .)"
n_run="$(sed -n 's/.*--shard \${{ matrix.shard }}\/\([0-9]*\) .*/\1/p' <<< "$s" | head -1)"
n_exp="$(sed -n 's/.*--shards-expected \([0-9]*\).*/\1/p' <<< "$s" | head -1)"
ci_list="$(strip "$CI_YML" | sed -n 's/^[[:space:]]*shard: \[\(.*\)\]$/\1/p' | head -1 | tr -d ' ')"
if [ "$n_list" = "$n_run" ] && [ "$n_run" = "$n_exp" ] && [ "$list" = "$ci_list" ]; then
  ok "shard list ($n_list), --shard /$n_run and --shards-expected $n_exp agree with ci.yml's partition"
else bad "shard spellings disagree: list=$n_list run=/$n_run expected=$n_exp ci.yml-list='$ci_list' here='$list'"; fi

# 7. same pinned action versions as ci.yml.
unpinned=""
# shellcheck disable=SC2013 # action refs contain no whitespace
for u in $(grep -o 'uses: [^ ]*' <<< "$s" | sed 's/uses: //' | sort -u); do
  grep -q "uses: $u\$" <<< "$(strip "$CI_YML")" || unpinned="$unpinned $u"
done
if [ -z "$unpinned" ]; then ok "every action is pinned to a version ci.yml already uses"
else bad "actions not pinned like ci.yml:$unpinned"; fi

# 8. the breakage metric is wired into the final job.
if grep -q 'scripts/ci/macos-breakage.sh record' <<< "$s" && grep -q 'macos-breakage-record' <<< "$s" \
   && grep -q 'GITHUB_STEP_SUMMARY' <<< "$s"; then ok "the summary job records the breakage metric (record + artifact + step summary)"
else bad "breakage metric is not wired into the workflow"; fi

# 9. fail closed: the record step pipes into tee, so it needs `shell: bash`
# (pipefail; the default `bash -e {0}` reports tee's status and a die inside
# record goes green), and a missing record.json must fail the upload.
step_of() { awk -v n="$1" 'index($0, "- name: " n) {f=1; print; next} f && /^      - / {f=0} f' <<< "$s"; }
if step_of "Record breakages" | grep -q '^        shell: bash$'; then ok "the record step runs under shell: bash (pipefail through | tee)"
else bad "the record step has no 'shell: bash': a die in record is masked by | tee"; fi
if step_of "Upload breakage record" | grep -q 'if-no-files-found: error'; then ok "a missing record.json fails the upload"
else bad "the record upload does not use if-no-files-found: error"; fi

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed" >&2
exit 1
