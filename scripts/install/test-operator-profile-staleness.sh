#!/usr/bin/env bash
# test-operator-profile-staleness.sh — HIMMEL-2307 CI staleness gate.
#
# Operator-machine only: runs a fresh capture-operator-profile.mjs against
# THIS machine and --checks it against the committed
# docs/setup/profiles/operator.install-profile.json, so drift between the
# operator's real setup and the committed reference fails loudly instead of
# silently going stale.
#
# Self-skips (SKIP contract below) everywhere except the operator's own
# machine — gated on HIMMEL_OPERATOR_MACHINE=1 in the PRIMARY checkout's
# .env (never hardcode a machine name/hostname check; the .env flag is the
# single opt-in, same shape as every other operator-only knob in this repo).
#
# NOTE: this does NOT validate the profile's SCHEMA (schemaVersion, field
# shapes, etc.) — that is the HIMMEL-2308 leg's CI check over every
# docs/setup/profiles/*.install-profile.json file. This gate only asks "does
# a fresh capture on this machine still match the committed one".
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
capture_script="$repo_root/scripts/install/capture-operator-profile.mjs"
profile_path="$repo_root/docs/setup/profiles/operator.install-profile.json"

[ -f "$capture_script" ] || { echo "FAIL: $capture_script not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH"; echo "$(basename "$0"): SKIPPED — 0 cases ran (node not on PATH)"; exit 0; }

# shellcheck source=../lib/load-dotenv.sh
# shellcheck disable=SC1091
. "$repo_root/scripts/lib/load-dotenv.sh"
# Capture-relevant keys the gate must see the same way the operator's capture run does.
load_dotenv HIMMEL_OPERATOR_MACHINE CLAUDE_CONFIG_DIR HIMMEL_OBSERVABILITY_CONFIG LANES_REGISTRY HANDOVER_DIR LUNA_VAULT_PATH WHISPER_DIR WHISPER_MODEL

if [ "${HIMMEL_OPERATOR_MACHINE:-}" != "1" ]; then
  echo "SKIP: HIMMEL_OPERATOR_MACHINE!=1 (this gate runs only on the operator's own machine)"
  echo "$(basename "$0"): SKIPPED — 0 cases ran (HIMMEL_OPERATOR_MACHINE!=1)"
  exit 0
fi

if [ ! -f "$profile_path" ]; then
  echo "FAIL: $profile_path is missing — nothing to check staleness against (run: node $capture_script --profile-out $profile_path)" >&2
  exit 1
fi

rc=0
out=$(node "$capture_script" --check "$profile_path" 2>&1) || rc=$?

if [ "$rc" -eq 0 ]; then
  echo "PASS: $profile_path matches a fresh capture on this machine"
  exit 0
fi
if [ "$rc" -eq 1 ]; then
  echo "FAIL: docs/setup/profiles/operator.install-profile.json is STALE — a fresh capture on this machine differs:" >&2
  printf '%s\n' "$out" >&2
  echo "fix: node $capture_script --profile-out $profile_path, then commit" >&2
  exit 1
fi
echo "FAIL: capture-operator-profile.mjs --check exited $rc (usage/runtime error):" >&2
printf '%s\n' "$out" >&2
exit 1
