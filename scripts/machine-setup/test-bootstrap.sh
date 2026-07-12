#!/usr/bin/env bash
# test-bootstrap.sh -- install the MINIMAL deps to RUN himmel's bash test suites
# on a fresh Debian/Ubuntu box: a throwaway test VM or a CI runner (HIMMEL-469).
#
# This is the TEST-HARNESS dependency set, deliberately SEPARATE from
# scripts/setup.sh's user-facing RUNTIME set ([0/10]: bash git node npm bun
# python3 jq gh mktemp + claude). Running the committed hermetic suites needs only:
#   bash  (always present)   git  (test-load-dotenv, test-inject-initiative)   jq
# node/npm/bun/python3/gh are NOT needed to run the suites -- they're runtime deps
# a real himmel USER installs, not test-harness deps.
#
# Idempotent: already-present tools are skipped. On a GitHub Actions ubuntu runner
# git+jq are preinstalled, so this is a no-op there. Uses `sudo apt-get` unless
# already root or --no-sudo is passed.
#
# Usage:
#   bash scripts/machine-setup/test-bootstrap.sh            # install missing test deps
#   bash scripts/machine-setup/test-bootstrap.sh --check    # report only, install nothing
#   bash scripts/machine-setup/test-bootstrap.sh --no-sudo  # don't prefix apt-get with sudo
set -euo pipefail

# The test-harness dependency set (NOT the user runtime set).
TEST_DEPS="git jq"

CHECK=0
NO_SUDO=0
for arg in "$@"; do
  case "$arg" in
    --check)   CHECK=1 ;;
    --no-sudo) NO_SUDO=1 ;;
    -h|--help) sed -n '2,/^set -e/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'; exit 0 ;;
    *) echo "test-bootstrap: unknown arg: $arg" >&2; exit 2 ;;
  esac
done

missing=""
for t in $TEST_DEPS; do
  command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
missing="${missing# }"

if [ -z "$missing" ]; then
  echo "test-bootstrap: all test deps present ($TEST_DEPS)."
  exit 0
fi

if [ "$CHECK" -eq 1 ]; then
  echo "test-bootstrap: MISSING test deps: $missing"
  exit 1
fi

# Resolve the install command. Only apt-get is supported (the test VMs + the CI
# runner are Debian/Ubuntu); other platforms get a loud manual hint.
if ! command -v apt-get >/dev/null 2>&1; then
  echo "test-bootstrap: apt-get not found -- install manually: $missing" >&2
  exit 1
fi

sudo_pfx="sudo"
if [ "$NO_SUDO" -eq 1 ] || [ "$(id -u 2>/dev/null || echo 0)" = "0" ]; then
  sudo_pfx=""
fi

echo "test-bootstrap: installing test deps:$missing"
# shellcheck disable=SC2086  # $missing intentionally word-splits into package args
$sudo_pfx apt-get update -qq
# shellcheck disable=SC2086
$sudo_pfx apt-get install -y $missing

# Verify.
still=""
for t in $missing; do
  command -v "$t" >/dev/null 2>&1 || still="$still $t"
done
if [ -n "$still" ]; then
  echo "test-bootstrap: STILL missing after install:$still" >&2
  exit 1
fi
echo "test-bootstrap: test deps ready ($TEST_DEPS)."
