#!/usr/bin/env bash
# scripts/lanes/bench/materialize.sh — HIMMEL-1723 P2.2
# Copies a fixture's input/ tree to a FRESH scratch dir OUTSIDE the himmel
# working tree (hard constraint: no dispatch may ever touch/commit inside
# this repo — spec §3.1) and prints the materialized path on stdout.
# Read-only on the fixture: only ever copies FROM <task-dir>/input, never
# writes back to it, so two runs against the same fixture never interfere and
# the source is byte-identical before and after.
#
# Usage: materialize.sh <task-dir> <run-id>
#   task-dir  path to a fixture directory (e.g. scripts/lanes/bench/fixtures/T7)
#             containing an input/ subdirectory
#   run-id    <task>-<cell>-<rep>, e.g. T7-luna-1 — used to name the scratch
#             dir; a timestamp+pid suffix is appended so a RETRY of the same
#             run-id (or two concurrent invocations) never collide
#
# Scratch root: BENCH_SCRATCH_ROOT env override, else ${TMPDIR:-/tmp}/himmel-bench.
# Both defaults resolve outside the himmel checkout on every machine this kit
# is expected to run on.
set -u

task_dir="${1:?usage: materialize.sh <task-dir> <run-id>}"
run_id="${2:?usage: materialize.sh <task-dir> <run-id>}"

input_dir="$task_dir/input"
if [ ! -d "$input_dir" ]; then
    echo "materialize.sh: no input/ dir under $task_dir" >&2
    exit 2
fi

scratch_root="${BENCH_SCRATCH_ROOT:-${TMPDIR:-/tmp}/himmel-bench}"
stamp="$(date +%s%N 2>/dev/null)"
case "$stamp" in ''|*N*) stamp="$(date +%s)" ;; esac
dest="$scratch_root/$run_id.$stamp.$$"

mkdir -p "$dest" || { echo "materialize.sh: could not create $dest" >&2; exit 3; }

# Copy the CONTENTS of input/ into dest (trailing slash on the source), never
# the input/ dir itself — verify-common.sh's diff compares dest against
# input_dir element-for-element, so the two trees must have the same shape.
if command -v rsync >/dev/null 2>&1; then
    rsync -a "$input_dir"/ "$dest"/ || { echo "materialize.sh: rsync copy failed" >&2; exit 4; }
else
    cp -R "$input_dir"/. "$dest"/ || { echo "materialize.sh: cp copy failed" >&2; exit 4; }
fi

printf '%s\n' "$dest"
