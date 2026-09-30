#!/usr/bin/env bash
# scripts/ci/test-ci-nightly-only-os.sh -- regression suite for HIMMEL-3853:
# Windows is verified by the NIGHTLY (`schedule`) only (macOS by its own cadence
# workflow, macos-cadence.yml -- HIMMEL-3902). ci.yml has no
# `force_all_os` dispatch input, so no manually dispatched run can occupy the
# paid Windows/macOS runner slots (2026-09-29: per-PR dispatches held 14 of the
# account's 20 concurrent job slots and queued ~287 jobs behind them).
#
# Pure text + evaluated-expression assertions over the workflow file (comments
# stripped, so a comment cannot satisfy a policy check). The matrix `os:`
# expressions are EVALUATED per trigger event, so the nightly's 3-OS matrix and
# the ubuntu-only pull_request / push / workflow_dispatch matrices are proven,
# not grepped. No network, no PyYAML.
#
# Usage: bash scripts/ci/test-ci-nightly-only-os.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CI_YML="${CI_YML:-$ROOT/.github/workflows/ci.yml}"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }

# Whole file with full-line and trailing ` #` comments removed.
stripped="$(sed -e '/^[[:space:]]*#/d' -e 's/[[:space:]][[:space:]]*#.*$//' "$CI_YML")"

# 1. The input and every reference to it are gone.
if grep -q 'force_all_os' <<< "$stripped"; then
  bad "ci.yml still keys logic on force_all_os"
else
  ok "no force_all_os in the executable part of ci.yml"
fi
if grep -q 'force_all_os' "$CI_YML"; then
  bad "ci.yml still MENTIONS force_all_os (a comment telling someone to dispatch it)"
else
  ok "no force_all_os mention anywhere in ci.yml"
fi

# 2. workflow_dispatch stays a trigger but carries no inputs.
dispatch="$(awk '/^  workflow_dispatch:/ {f=1; next} f && /^  [a-z_]+:/ {f=0} f' <<< "$stripped")"
if grep -q 'inputs:' <<< "$dispatch"; then
  bad "workflow_dispatch still declares inputs"
else
  ok "workflow_dispatch declares no inputs"
fi
if grep -q '^  workflow_dispatch:' <<< "$stripped"; then
  ok "workflow_dispatch trigger is still present (plain dispatch stays ubuntu-only)"
else
  bad "workflow_dispatch trigger was removed (out of scope)"
fi
if grep -q 'inputs\.' <<< "$stripped"; then
  bad "ci.yml still reads an inputs.* context"
else
  ok "ci.yml reads no inputs.* context"
fi

# 3. Matrix by event: evaluate each job's `os:` expression per event.
job_block() { awk -v j="$1" '$0 == "  " j ":" {f=1; next} f && /^  [a-zA-Z_-]+:/ {f=0} f' <<< "$stripped"; }

eval_matrix() {
  # $1 = job id; prints "event=os,os,os" per event, or FAIL text on stderr + rc 1.
  # shellcheck disable=SC2016 # the python body is single-quoted on purpose; nothing in it is a shell expansion
  job_block "$1" | python3 -c '
import json, re, sys
from types import SimpleNamespace as NS
text = sys.stdin.read()
m = re.search(r"^\s+os:\s*(\$\{\{.*?\}\})", text, re.DOTALL | re.MULTILINE)
if not m:
    print("no `os: ${{ }}` matrix expression found", file=sys.stderr); sys.exit(1)
inner = re.fullmatch(r"\$\{\{\s*(.*?)\s*\}\}", " ".join(m.group(1).split()), re.DOTALL).group(1)
inner = re.sub(r"fromJSON\((\x27[^\x27]*\x27)\)", lambda x: "json.loads(" + x.group(1) + ")", inner)
inner = inner.replace("&&", " and ").replace("||", " or ")
for ev in ("pull_request", "push", "workflow_dispatch", "schedule"):
    try:
        val = eval(inner, {"__builtins__": {}, "json": json}, {"github": NS(event_name=ev)})
    except Exception as e:
        print("expression does not evaluate for %s: %r" % (ev, e), file=sys.stderr); sys.exit(1)
    print("%s=%s" % (ev, ",".join(val)))
'
}

check_matrix() {
  # $1 = job id, $2 = expected schedule OS list (comma-joined)
  local job="$1" want_sched="$2" out
  if ! out="$(eval_matrix "$job" 2>&1)"; then
    bad "$job: matrix expression not evaluable -- $out"
    return
  fi
  local ev got
  for ev in pull_request push workflow_dispatch; do
    got="$(sed -n "s/^$ev=//p" <<< "$out")"
    if [ "$got" = "ubuntu-latest" ]; then ok "$job: $ev runs ubuntu-latest only"
    else bad "$job: $ev matrix is '$got' (expected ubuntu-latest only)"; fi
  done
  got="$(sed -n 's/^schedule=//p' <<< "$out")"
  if [ "$got" = "$want_sched" ]; then ok "$job: schedule (nightly) runs $want_sched"
  else bad "$job: schedule matrix is '$got' (expected $want_sched)"; fi
}

check_matrix shell-unit-shard "ubuntu-latest,windows-latest"
check_matrix bun-suites "ubuntu-latest,windows-latest"

# 4. SUITE_TIER_MODE=all (the full corpus) only on the nightly.
tier="$(job_block shell-unit-shard | sed -n 's/^[[:space:]]*SUITE_TIER_MODE:[[:space:]]*//p')"
case "$tier" in
  "\${{ github.event_name == 'schedule' && 'all' || 'fast' }}")
    ok "SUITE_TIER_MODE is 'all' on schedule only, 'fast' otherwise" ;;
  *) bad "SUITE_TIER_MODE expression is not schedule-only; got '$tier'" ;;
esac

# 5. The aggregator's nightly-only steps are keyed on schedule alone.
agg="$(job_block shell-unit)"
n_if="$(grep -c "github.event_name == 'schedule'" <<< "$agg")"
if [ "$n_if" -ge 2 ]; then ok "shell-unit's extended-tier issue steps are gated on schedule ($n_if if:s)"
else bad "shell-unit has only $n_if schedule-gated steps (expected >= 2)"; fi

# 5b. HIMMEL-3902: macOS is not in ci.yml at all -- no matrix leg, no health
# step -- it runs on macos-cadence.yml, so a macOS red can never redden `CI`.
if grep -qi 'macos' <<< "$stripped"; then
  bad "ci.yml still runs or reads a macOS job: $(grep -i -m1 'macos' <<< "$stripped")"
else
  ok "no macOS job or macOS health step remains in the executable part of ci.yml"
fi

# 6. Non-ubuntu legs stay non-gating (advisory until HIMMEL-3699 / HIMMEL-3719 land).
for job in shell-unit-shard bun-suites; do
  blk="$(job_block "$job")"
  if grep -q "continue-on-error: \${{ matrix.os != 'ubuntu-latest' }}" <<< "$blk"; then
    ok "$job: non-ubuntu legs stay continue-on-error"
  else
    bad "$job: continue-on-error scoping to non-ubuntu legs changed (out of scope)"
  fi
done

# 7. HIMMEL-3919: the shard job and its apt/at install step are bounded (a hung
# apt lock once held a shard ~1.5 h; the 6 h default queued every later main run).
blk="$(job_block shell-unit-shard)"
# The cap must be OS-conditional: nightly windows shards run 79-128 min, so a
# flat cap cancels them (a timed-out job is `cancelled`, which continue-on-error
# does not absorb). Shape: `${{ matrix.os == 'windows-latest' && <win> || <other> }}`.
tm_re="^    timeout-minutes: \\\$\{\{ matrix\.os == 'windows-latest' && ([0-9]+) \|\| ([0-9]+) \}\}\$"
tm_line="$(grep -E '^    timeout-minutes:' <<< "$blk")"
if [[ "$tm_line" =~ $tm_re ]]; then
  win="${BASH_REMATCH[1]}"; other="${BASH_REMATCH[2]}"
  if [ "$win" -ge 180 ] && [ "$other" -ge 1 ] && [ "$other" -lt "$win" ]; then
    ok "shell-unit-shard: job-level timeout-minutes is OS-conditional (windows $win, other $other)"
  else
    bad "shell-unit-shard: OS-conditional timeout-minutes needs windows >= 180 and other < windows (got $win / $other)"
  fi
else
  bad "shell-unit-shard: job-level timeout-minutes is not the OS-conditional windows-latest form (flat or missing): $tm_line"
fi
# A timed-out shard is `cancelled`, so its failed-suite logs must upload then too.
if grep -Eq "^        if: failure\(\) \|\| cancelled\(\)$" <<< "$(awk '/name: Upload failed-suite logs/ {f=1; next} f {print; exit}' <<< "$blk")"; then
  ok "shell-unit-shard: failed-suite logs upload on failure() || cancelled()"
else
  bad "shell-unit-shard: failed-suite logs upload does not cover a cancelled (timed-out) shard"
fi
# The at/atd install step alone: from its `- name:` line to the next step.
step="$(awk '/^      - name: Install \+ enable at\/atd/ {f=1; print; next} f && /^      - / {f=0} f' <<< "$blk")"
if grep -Eq '^        timeout-minutes: [0-9]+$' <<< "$step"; then
  ok "shell-unit-shard: at/atd install step has its own timeout-minutes"
else
  bad "shell-unit-shard: at/atd install step has no step-level timeout-minutes"
fi
apt_total="$(grep -c 'apt-get ' <<< "$step")"
apt_locked="$(grep -c 'apt-get .*DPkg::Lock::Timeout=' <<< "$step")"
if [ "$apt_total" -gt 0 ] && [ "$apt_total" -eq "$apt_locked" ]; then
  ok "shell-unit-shard: every apt-get call in the install step carries DPkg::Lock::Timeout ($apt_locked/$apt_total)"
else
  bad "shell-unit-shard: apt-get calls in the install step lacking DPkg::Lock::Timeout ($apt_locked/$apt_total)"
fi

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed" >&2
exit 1
