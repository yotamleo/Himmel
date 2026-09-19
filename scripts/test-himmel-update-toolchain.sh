#!/usr/bin/env bash
# test-himmel-update-toolchain.sh — report_toolchain's node-vs-.nvmrc verdict
# (HIMMEL-3088). himmel-update.sh --only toolchain compares the installed node
# against the pin at the PIN's own granularity (major / major.minor /
# major.minor.patch) and says match / behind / ahead — report-only, always rc 0.
#
# node/npm/bun are STUBS on a private PATH: --only toolchain runs in apply mode,
# which would otherwise self-upgrade the host's real npm and bun.
#
# Bash 3.2 compatible.

set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/himmel-update.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-himmel-update-toolchain.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

export USERPROFILE=''
export HOME="$TMP/home"
export CLAUDE_CONFIG_DIR="$TMP/no-claude-config"
export HERMES_HOME="$TMP/no-hermes"
export HIMMELCTL_CACHE_DIR="$TMP/himmelctl-cache"
mkdir -p "$HOME" "$HIMMELCTL_CACHE_DIR"
unset HIMMEL_UPDATE_CHANNEL

pass=0
fail=0
assert_pass() { pass=$((pass + 1)); echo "  PASS: $1"; }
assert_fail() { fail=$((fail + 1)); echo "  FAIL: $1"; }

# Mock clone: the script resolves its ROOT from its own location.
CLONE="$TMP/clone"
mkdir -p "$CLONE/scripts/guardrails" "$CLONE/scripts/lib"
src_scripts="$(dirname "$SCRIPT")"
cp "$SCRIPT" "$CLONE/scripts/himmel-update.sh"
cp "$src_scripts/guardrails/lib.sh"        "$CLONE/scripts/guardrails/lib.sh"
cp "$src_scripts/lib/cadence-format.sh"    "$CLONE/scripts/lib/cadence-format.sh"
cp "$src_scripts/lib/resolve-hermes-py.sh" "$CLONE/scripts/lib/resolve-hermes-py.sh"
cp "$src_scripts/lib/load-dotenv.sh"       "$CLONE/scripts/lib/load-dotenv.sh"
git init --quiet "$CLONE"

STUBS="$TMP/stubs"
mkdir -p "$STUBS"
# shellcheck disable=SC2016 # the stub's $STUB_NODE_VERSION must expand when the stub runs
printf '#!/bin/sh\nprintf "%%s\\n" "$STUB_NODE_VERSION"\n' > "$STUBS/node"
printf '#!/bin/sh\nprintf "1.0.0\\n"\n' > "$STUBS/npm"
printf '#!/bin/sh\nprintf "1.0.0\\n"\n' > "$STUBS/bun"
chmod +x "$STUBS/node" "$STUBS/npm" "$STUBS/bun"

# run_case <desc> <pin-file-content> <installed-node> <expected-pattern> [<forbidden-pattern>]
run_case() {
    local desc="$1" pin="$2" installed="$3" want="$4" forbid="${5:-}" out rc
    printf '%s\n' "$pin" > "$CLONE/.nvmrc"
    rc=0
    out="$(cd "$CLONE" && PATH="$STUBS:/usr/bin:/bin" STUB_NODE_VERSION="$installed" \
        bash scripts/himmel-update.sh --only toolchain 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        assert_fail "$desc — exit $rc (report-only must exit 0): $out"
    elif ! grep -q -- "$want" <<< "$out"; then
        assert_fail "$desc — expected '$want', got: $out"
    elif [ -n "$forbid" ] && grep -q -- "$forbid" <<< "$out"; then
        assert_fail "$desc — must not say '$forbid', got: $out"
    else
        assert_pass "$desc"
    fi
}

echo "report_toolchain: node vs .nvmrc at the pin's granularity (HIMMEL-3088)"
run_case "patch pin 20.11.0 vs 20.1.0 → behind"    "20.11.0" "v20.1.0"  "behind pin"
run_case "minor pin 20.11 vs 20.1.5 → behind"      "20.11"   "v20.1.5"  "behind pin"
run_case "major pin 20 vs 22.3.0 → ahead"          "20"      "v22.3.0"  "ahead of pin" "behind pin"
run_case "major pin 22 vs 20.9.0 → behind"         "22"      "v20.9.0"  "behind pin"
run_case "patch pin 20.11.0 vs 20.11.1 → ahead"    "20.11.0" "v20.11.1" "ahead of pin"
run_case "exact match 20.11.0 → match"             "20.11.0" "v20.11.0" "matches the .nvmrc pin" "behind pin"
run_case "major pin 20 vs 20.19.5 → match"         "20"      "v20.19.5" "matches the .nvmrc pin" "behind pin"
run_case "minor pin 20.11 vs 20.11.9 → match"      "20.11"   "v20.11.9" "matches the .nvmrc pin"
run_case "v-prefixed pin v20.11.0 vs 20.1.0"       "v20.11.0" "v20.1.0" "behind pin"
run_case "numeric compare, not lexical (20.9 vs 20.10)" "20.10" "v20.9.0" "behind pin"
run_case "lts/* pin → plain report, no crash"      "lts/*"   "v22.3.0"  "not a plain version" "behind pin"
run_case "lts/iron pin → plain report, no crash"   "lts/iron" "v20.1.0" "not a plain version"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
