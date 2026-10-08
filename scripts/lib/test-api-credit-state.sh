#!/usr/bin/env bash
# HIMMEL-4904: credit fixtures plus API bank integration, no secrets or network.
# Platform guard: local filesystem accounting; Linux verified, no .ps1 twin.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
exec node --test "$REPO/scripts/lib/api-credit-state.test.mjs"
