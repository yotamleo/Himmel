#!/usr/bin/env bash
# Shard of test-block-write-into-main-checkout.sh (HIMMEL-4164 split, so each
# suite stays under its CI per-suite cap): slice 3 of 3 of the HIMMEL-2592
# generated grammar matrix.
# Same fixtures + harness as the parent suite via lib-test-write-fence.sh and
# lib-test-write-fence-matrix.sh; the FIXTURE RULE lives in
# test-block-write-into-main-checkout.sh.
# shellcheck disable=SC2154  # pass/fail are defined by the sourced lib
# shellcheck source=lib-test-write-fence.sh
. "$(dirname "$0")/lib-test-write-fence.sh"
# shellcheck source=lib-test-write-fence-matrix.sh
. "$(dirname "$0")/lib-test-write-fence-matrix.sh"

_matrix_run_slice 3 3

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
