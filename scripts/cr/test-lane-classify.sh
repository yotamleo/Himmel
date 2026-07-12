#!/usr/bin/env bash
# Smoke test for scripts/cr/lane-classify.sh (HIMMEL-654 WS7, spec D1.1).
# The suite is the spec: positive markers classify cheap; absence never does.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/cr/lane-classify.sh
# shellcheck disable=SC1091  # sourced at runtime; checked standalone by pre-commit
. "$DIR/lane-classify.sh"
fail=0
check() { [ "$1" = "$2" ] || { echo "FAIL: got '$1' want '$2'"; fail=1; }; }
check "$(lane_classify glm/spike-a)"        cheap-glm
check "$(lane_classify glm/nested/slug)"    cheap-glm
check "$(lane_classify codex/hermes-task)"  cheap-codex
check "$(lane_classify feat/himmel-654)"    claude
check "$(lane_classify main)"               claude
check "$(lane_classify glmfoo)"             claude   # prefix must be a path segment, not substring
# CLI form matches sourced form
check "$(bash "$DIR/lane-classify.sh" glm/x)" cheap-glm
[ "$fail" -eq 0 ] && echo "PASS test-lane-classify" || exit 1
