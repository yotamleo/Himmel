#!/usr/bin/env bash
# Smoke test for update_hermes() in himmel-update.sh (HIMMEL-426). Sources the
# script via its HIMMEL_UPDATE_LIB seam so the function runs in isolation with
# HERMES_HOME fixtures — no network, no repo mutation.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
HIMMEL_UPDATE_LIB=1 . "$HERE/himmel-update.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0

check() {  # <description> <expected-substring> <actual-output>
  if printf '%s' "$3" | grep -Eq "$2"; then
    echo "ok: $1"
  else
    echo "FAIL: $1"; echo "  expected /$2/ in:"; printf '%s\n' "$3" | sed 's/^/    /'
    fail=1
  fi
}

# HERMES_HOME is the install ROOT; the git checkout is its hermes-agent/ subdir.

# Case 1: install root with no hermes-agent checkout → "not installed" skip.
out=$(HERMES_HOME="$tmp/nope" update_hermes check 2>&1)
check "absent hermes skips" "skip: hermes not installed as a git checkout" "$out"

# Case 2: hermes-agent/ checkout with a foreign remote → "not a … checkout" skip
# (returns before any fetch/pull, so this stays offline).
git init -q "$tmp/other/hermes-agent"
git -C "$tmp/other/hermes-agent" remote add origin https://github.com/x/y.git
out=$(HERMES_HOME="$tmp/other" update_hermes apply 2>&1)
check "foreign checkout skips" "is not a NousResearch/hermes-agent checkout" "$out"

# Case 3: NousResearch hermes-agent/ checkout, check mode, fetch unreachable →
# graceful handling (offline / current / update-available), never crash/push.
git init -q "$tmp/install/hermes-agent"
git -C "$tmp/install/hermes-agent" remote add origin https://github.com/NousResearch/hermes-agent.git
out=$(HERMES_HOME="$tmp/install" update_hermes check 2>&1)
check "nous checkout check handled" "could not reach origin|hermes is current|update available" "$out"

# Case 4: HERMES_HOME pointing STRAIGHT at the checkout (…/.git present) is
# tolerated — same NousResearch handling.
git init -q "$tmp/direct"
git -C "$tmp/direct" remote add origin https://github.com/NousResearch/hermes-agent.git
out=$(HERMES_HOME="$tmp/direct" update_hermes check 2>&1)
check "direct checkout tolerated" "could not reach origin|hermes is current|update available" "$out"

# ── fail-vs-skip (CR: genuine hermes failures must not be hidden as skipped)─
# HIMMEL-893 CR fix: update_hermes used to `git pull --ff-only` in one shot
# and swallow BOTH a real non-ff failure AND an unreachable origin as the
# same non-aborting "warn" — hiding a genuinely broken hermes update behind
# "skipped". These cases build REAL local git remotes (bare repos / local
# paths — no real network) so fetch/pull genuinely succeed or fail, then
# assert the fail-vs-skip split end to end (update_hermes AND run_hermes_step,
# whose non-zero return is what makes the chain's
# `if ! run_hermes_step apply; then chain_rc=1; fi` abort like any other item).

# Case 5: a REAL non-fast-forward divergence (local unpushed commit + a
# different commit pushed to origin meanwhile) -> genuine FAILURE, not a skip.
bare5="$tmp/bare5/NousResearch/hermes-agent.git"
mkdir -p "$bare5"; git init -q --bare "$bare5"
seed5="$tmp/seed5"
git clone -q "$bare5" "$seed5"
git -C "$seed5" config user.email "test@test.test"; git -C "$seed5" config user.name "Test"
printf 'v1\n' > "$seed5/f.txt"; git -C "$seed5" add f.txt; git -C "$seed5" commit --quiet -m v1
defbranch5=$(git -C "$seed5" rev-parse --abbrev-ref HEAD)
git -C "$seed5" push --quiet origin "HEAD:$defbranch5"
git clone -q "$bare5" "$tmp/failcase/hermes-agent"
git -C "$tmp/failcase/hermes-agent" config user.email "test@test.test"
git -C "$tmp/failcase/hermes-agent" config user.name "Test"
printf 'local-edit\n' > "$tmp/failcase/hermes-agent/local.txt"
git -C "$tmp/failcase/hermes-agent" add local.txt
git -C "$tmp/failcase/hermes-agent" commit --quiet -m "local unpushed"
printf 'v2\n' > "$seed5/f.txt"; git -C "$seed5" add f.txt; git -C "$seed5" commit --quiet -m v2
git -C "$seed5" push --quiet origin "HEAD:$defbranch5"

rc=0
out=$(HERMES_HOME="$tmp/failcase" update_hermes apply 2>&1) || rc=$?
check "real pull failure: FAILED message (update_hermes)" "FAILED: hermes git pull was not fast-forward" "$out"
if [ "$rc" -ne 0 ]; then echo "ok: real pull failure -> non-zero exit (update_hermes)"; else echo "FAIL: real pull failure -> exit was 0 (update_hermes)"; fail=1; fi

# NOTE: run_hermes_step is called as a plain redirected command here, NOT
# inside a `$(...)` command substitution — command substitution always forks
# a subshell in bash, which would make the function's STATUS_hermes= write
# invisible to this (parent) shell. A redirect on a simple/function command
# does not fork a subshell, so the global assignment is observable afterward.
rc=0
run_out5="$tmp/run-hermes-step-fail.out"
HERMES_HOME="$tmp/failcase" run_hermes_step apply > "$run_out5" 2>&1 || rc=$?
out=$(cat "$run_out5")
check "real pull failure: FAILED message (run_hermes_step)" "FAILED: hermes git pull was not fast-forward" "$out"
if [ "$rc" -ne 0 ]; then echo "ok: real pull failure -> non-zero exit (run_hermes_step, chain would abort)"; else echo "FAIL: real pull failure -> exit was 0 (run_hermes_step)"; fail=1; fi
# shellcheck disable=SC2154  # STATUS_hermes is set by the sourced himmel-update.sh (HIMMEL_UPDATE_LIB=1 seam above)
if [ "$STATUS_hermes" = "failed" ]; then echo "ok: run_hermes_step sets STATUS_hermes=failed on a genuine failure"; else echo "FAIL: STATUS_hermes was '$STATUS_hermes', expected 'failed'"; fail=1; fi

# Case 6: absent hermes -> skipped + run_hermes_step never aborts (rc 0).
rc=0
run_out6="$tmp/run-hermes-step-absent.out"
HERMES_HOME="$tmp/nope2" run_hermes_step apply > "$run_out6" 2>&1 || rc=$?
out=$(cat "$run_out6")
check "absent hermes: skip message (run_hermes_step)" "skip: hermes not installed as a git checkout" "$out"
if [ "$rc" -eq 0 ]; then echo "ok: absent hermes -> exit 0 (run_hermes_step, chain not aborted)"; else echo "FAIL: absent hermes -> exit $rc (run_hermes_step)"; fail=1; fi
# shellcheck disable=SC2154  # STATUS_hermes is set by the sourced himmel-update.sh (HIMMEL_UPDATE_LIB=1 seam above)
if [ "$STATUS_hermes" = "skipped" ]; then echo "ok: run_hermes_step sets STATUS_hermes=skipped when absent"; else echo "FAIL: STATUS_hermes was '$STATUS_hermes', expected 'skipped'"; fail=1; fi

# Case 7: origin unreachable (fetch itself fails) -> clean SKIP, never a
# FAILURE — "couldn't attempt" vs "ran and errored". A LOCAL path that does
# not exist forces a deterministic, instant, network-free fetch failure (the
# hermetic equivalent of "offline") — no real DNS/network dependency.
git init -q "$tmp/offline/hermes-agent"
git -C "$tmp/offline/hermes-agent" remote add origin "$tmp/no-such-remote/NousResearch/hermes-agent"
rc=0
out=$(HERMES_HOME="$tmp/offline" update_hermes apply 2>&1) || rc=$?
check "unreachable origin (apply): skip message, not FAILED" "skip: could not reach origin" "$out"
if [ "$rc" -eq 0 ]; then echo "ok: unreachable origin (apply) -> exit 0 (skip, not fail)"; else echo "FAIL: unreachable origin (apply) -> exit $rc"; fail=1; fi

# Case 8: apply mode follows the branch's CONFIGURED upstream — including a
# non-origin remote and a differently named remote branch — instead of fetching
# origin and then merging @{u}. Keep origin valid-looking but unreachable so
# the old hard-coded behavior would skip without updating.
bare8="$tmp/bare8/NousResearch/hermes-agent.git"
mkdir -p "$bare8"; git init -q --bare "$bare8"
seed8="$tmp/seed8"
git clone -q "$bare8" "$seed8"
git -C "$seed8" config user.email "test@test.test"; git -C "$seed8" config user.name "Test"
printf 'v1\n' > "$seed8/f.txt"; git -C "$seed8" add f.txt; git -C "$seed8" commit --quiet -m v1
git -C "$seed8" push --quiet origin HEAD:release
src8="$tmp/configured-upstream/hermes-agent"
git init -q "$src8"
git -C "$src8" remote add upstream "$bare8"
git -C "$src8" fetch -q upstream refs/heads/release
git -C "$src8" checkout -q -b local-work --track upstream/release
git -C "$src8" remote add origin "$tmp/no-such-origin/NousResearch/hermes-agent"
printf 'v2\n' > "$seed8/f.txt"; git -C "$seed8" add f.txt; git -C "$seed8" commit --quiet -m v2
git -C "$seed8" push --quiet origin HEAD:release
want8=$(git -C "$seed8" rev-parse HEAD)
rc=0
out=$(HERMES_HOME="$tmp/configured-upstream" update_hermes apply 2>&1) || rc=$?
got8=$(git -C "$src8" rev-parse HEAD)
if [ "$rc" -eq 0 ]; then echo "ok: configured upstream (apply) -> exit 0"; else echo "FAIL: configured upstream (apply) -> exit $rc"; printf '%s\n' "$out"; fail=1; fi
if [ "$got8" = "$want8" ]; then echo "ok: apply fetches configured non-origin/differently-named upstream"; else echo "FAIL: apply HEAD was '$got8', expected '$want8'"; printf '%s\n' "$out"; fail=1; fi

# ── --check must not mutate the checkout (CR: was fetch-based) ─────────────
# HIMMEL-893 CR fix: `update_hermes check` used to run a real `git fetch`,
# which writes FETCH_HEAD and updates remote-tracking refs in the EXTERNAL
# hermes checkout — mutating state under a read-only `--check` contract. Now
# it compares via `git ls-remote` (queries the remote directly, writes
# nothing locally). Build a REAL, reachable local "origin" (a bare repo, no
# real network) and snapshot FETCH_HEAD + every ref before/after — mirrors
# test-himmel-update-chain.sh's Test 4 full-state-snapshot technique.
bareC="$tmp/bare-check/NousResearch/hermes-agent.git"
mkdir -p "$bareC"; git init -q --bare "$bareC"
seedC="$tmp/seed-check"
git clone -q "$bareC" "$seedC"
git -C "$seedC" config user.email "test@test.test"; git -C "$seedC" config user.name "Test"
printf 'v1\n' > "$seedC/f.txt"; git -C "$seedC" add f.txt; git -C "$seedC" commit --quiet -m v1
defbranchC=$(git -C "$seedC" rev-parse --abbrev-ref HEAD)
git -C "$seedC" push --quiet origin "HEAD:$defbranchC"
git clone -q "$bareC" "$tmp/checkmode/hermes-agent"

fetch_head_snapshot() {
    [ -f "$1/.git/FETCH_HEAD" ] && cat "$1/.git/FETCH_HEAD" || echo "not-present"
}
refs_snapshot() {
    git -C "$1" for-each-ref --format='%(refname) %(objectname)' | sort
}

before_fetch_head=$(fetch_head_snapshot "$tmp/checkmode/hermes-agent")
before_refs=$(refs_snapshot "$tmp/checkmode/hermes-agent")
out=$(HERMES_HOME="$tmp/checkmode" update_hermes check 2>&1)
check "--check on a fresh, current checkout: reports current" "hermes is current" "$out"
after_fetch_head=$(fetch_head_snapshot "$tmp/checkmode/hermes-agent")
after_refs=$(refs_snapshot "$tmp/checkmode/hermes-agent")
if [ "$before_fetch_head" = "$after_fetch_head" ]; then echo "ok: --check leaves FETCH_HEAD unchanged"; else echo "FAIL: --check mutated FETCH_HEAD ('$before_fetch_head' -> '$after_fetch_head')"; fail=1; fi
if [ "$before_refs" = "$after_refs" ]; then echo "ok: --check leaves refs/remote-tracking unchanged (no fetch)"; else echo "FAIL: --check mutated refs"; printf 'before:\n%s\nafter:\n%s\n' "$before_refs" "$after_refs"; fail=1; fi

# Remote gains a new commit meanwhile — --check must detect it via ls-remote
# (never fetch) and STILL leave FETCH_HEAD/refs untouched.
printf 'v2\n' > "$seedC/f.txt"; git -C "$seedC" add f.txt; git -C "$seedC" commit --quiet -m v2
git -C "$seedC" push --quiet origin "HEAD:$defbranchC"
out=$(HERMES_HOME="$tmp/checkmode" update_hermes check 2>&1)
check "--check detects a real remote update via ls-remote" "update available" "$out"
after2_fetch_head=$(fetch_head_snapshot "$tmp/checkmode/hermes-agent")
after2_refs=$(refs_snapshot "$tmp/checkmode/hermes-agent")
if [ "$before_fetch_head" = "$after2_fetch_head" ]; then echo "ok: --check (update-available case) still leaves FETCH_HEAD unchanged"; else echo "FAIL: --check (update-available case) mutated FETCH_HEAD"; fail=1; fi
if [ "$before_refs" = "$after2_refs" ]; then echo "ok: --check (update-available case) still leaves refs unchanged"; else echo "FAIL: --check (update-available case) mutated refs"; fail=1; fi

# ── report_cadence_stale() — stale cadence runner nudge (HIMMEL-588/969) ─────
# Same lib seams; *_BAT_DIR point at fixture runner dirs.

# Case 5: no runners present anywhere → silent no-op (cadences not armed).
out=$(PIPELINE_BAT_DIR="$tmp/cad-empty" SWEEP_BAT_DIR="$tmp/sweep-empty" \
  GRAPHMAP_BAT_DIR="$tmp/graphmap-empty" report_cadence_stale 2>&1)
if [ -z "$out" ]; then echo "ok: cadence absent → silent"; else echo "FAIL: cadence absent not silent"; printf '%s\n' "$out"; fail=1; fi

# Case 6: codex-sweep.bat stamped current → shared probe returns its version.
mkdir -p "$tmp/cad-codex-current"
printf 'rem himmel-cadence-runner-format: %s\r\n' "$CADENCE_RUNNER_FORMAT_VERSION" \
  > "$tmp/cad-codex-current/codex-sweep.bat"
ver=$(cadence_runner_stamp "$tmp/cad-codex-current")
if [ "$ver" = "$CADENCE_RUNNER_FORMAT_VERSION" ]; then echo "ok: codex-sweep stamp probed"; else echo "FAIL: codex-sweep stamp probe got '$ver'"; fail=1; fi

# Case 7: pipeline runner with no format stamp (armed before HIMMEL-588) →
# STALE nudge with pipeline re-arm hint.
mkdir -p "$tmp/cad-stale"
printf '#!/bin/sh\necho old\n' > "$tmp/cad-stale/pipeline-harvest.sh"
out=$(PIPELINE_BAT_DIR="$tmp/cad-stale" SWEEP_BAT_DIR="$tmp/sweep-empty" \
  GRAPHMAP_BAT_DIR="$tmp/graphmap-empty" report_cadence_stale 2>&1)
check "stale pipeline cadence nudged (message)" "pipeline-cadence runners are STALE" "$out"
check "stale pipeline cadence nudged (rearm hint)" "bash scripts/luna/pipeline-cadence.sh arm --force" "$out"

# Case 8: codex-sweep.bat stamped stale → STALE nudge with codex re-arm hint.
mkdir -p "$tmp/cad-codex-stale"
printf 'rem himmel-cadence-runner-format: %s\r\n' "$((CADENCE_RUNNER_FORMAT_VERSION - 1))" \
  > "$tmp/cad-codex-stale/codex-sweep.bat"
out=$(PIPELINE_BAT_DIR="$tmp/cad-empty" SWEEP_BAT_DIR="$tmp/cad-codex-stale" \
  GRAPHMAP_BAT_DIR="$tmp/graphmap-empty" report_cadence_stale 2>&1)
check "stale codex-sweep cadence nudged (message)" "codex-sweep-cadence runners are STALE" "$out"
check "stale codex-sweep cadence nudged (rearm hint)" "bash scripts/cleanup/codex-sweep-cadence.sh arm --force" "$out"

# Case 9: graphmap runner stamped stale → STALE nudge with graphmap re-arm hint.
mkdir -p "$tmp/cad-graphmap-stale"
printf '#!/bin/sh\n# himmel-cadence-runner-format: %s\necho old\n' "$((CADENCE_RUNNER_FORMAT_VERSION - 1))" \
  > "$tmp/cad-graphmap-stale/graphmap-himmel.sh"
out=$(PIPELINE_BAT_DIR="$tmp/cad-empty" SWEEP_BAT_DIR="$tmp/sweep-empty" \
  GRAPHMAP_BAT_DIR="$tmp/cad-graphmap-stale" report_cadence_stale 2>&1)
check "stale graphmap cadence nudged (message)" "graphmap-cadence runners are STALE" "$out"
check "stale graphmap cadence nudged (rearm hint)" "bash scripts/luna/graphmap-cadence.sh arm --force" "$out"

# Case 10: pipeline-only runner stamped at the current version → no nudge and
# empty codex/graphmap dirs do not false-positive.
mkdir -p "$tmp/cad-current"
printf '#!/bin/sh\n# himmel-cadence-runner-format: %s\necho cur\n' "$CADENCE_RUNNER_FORMAT_VERSION" \
    > "$tmp/cad-current/pipeline-harvest.sh"
out=$(PIPELINE_BAT_DIR="$tmp/cad-current" SWEEP_BAT_DIR="$tmp/sweep-empty" \
  GRAPHMAP_BAT_DIR="$tmp/graphmap-empty" report_cadence_stale 2>&1)
if [ -z "$out" ]; then echo "ok: current cadence → silent"; else echo "FAIL: current cadence wrongly nudged"; printf '%s\n' "$out"; fail=1; fi

# Case 11: malformed marker (present but no version number) → safe fallback to
# version 0 → treated as stale (nudge), never a crash under set -e.
mkdir -p "$tmp/cad-malformed"
printf '#!/bin/sh\n# himmel-cadence-runner-format:\necho bad\n' > "$tmp/cad-malformed/pipeline-harvest.sh"
out=$(PIPELINE_BAT_DIR="$tmp/cad-malformed" SWEEP_BAT_DIR="$tmp/sweep-empty" \
  GRAPHMAP_BAT_DIR="$tmp/graphmap-empty" report_cadence_stale 2>&1)
check "malformed stamp → stale fallback (message)" "pipeline-cadence runners are STALE" "$out"
check "malformed stamp → stale fallback (rearm hint)" "bash scripts/luna/pipeline-cadence.sh arm --force" "$out"

# Case 12: MIXED runner versions in one dir → probe returns the MINIMUM (one
# current runner must not mask a stale sibling — interrupted re-arm).
mkdir -p "$tmp/cad-mixed"
printf '#!/bin/sh\n# himmel-cadence-runner-format: %s\necho cur\n' "$CADENCE_RUNNER_FORMAT_VERSION" \
  > "$tmp/cad-mixed/pipeline-harvest.sh"
printf '#!/bin/sh\n# himmel-cadence-runner-format: %s\necho old\n' "$((CADENCE_RUNNER_FORMAT_VERSION - 1))" \
  > "$tmp/cad-mixed/pipeline-health.sh"
ver=$(cadence_runner_stamp "$tmp/cad-mixed")
if [ "$ver" = "$((CADENCE_RUNNER_FORMAT_VERSION - 1))" ]; then echo "ok: mixed versions → minimum wins"; else echo "FAIL: mixed-version probe got '$ver'"; fail=1; fi
out=$(PIPELINE_BAT_DIR="$tmp/cad-mixed" SWEEP_BAT_DIR="$tmp/sweep-empty" \
  GRAPHMAP_BAT_DIR="$tmp/graphmap-empty" report_cadence_stale 2>&1)
check "mixed-version cadence nudged" "pipeline-cadence runners are STALE" "$out"

# Case 13: cadence_user_home — with USERPROFILE unset it echoes $HOME verbatim
# (the POSIX leg; the Windows USERPROFILE/cygpath leg is exercised by real
# Git-Bash runs where the two homes coincide).
uh=$(USERPROFILE='' HOME="$tmp/fake-home" cadence_user_home)
if [ "$uh" = "$tmp/fake-home" ]; then echo "ok: cadence_user_home falls back to HOME"; else echo "FAIL: cadence_user_home got '$uh'"; fail=1; fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: himmel-update hermes smoke test"
else
  echo "FAILED"; exit 1
fi
