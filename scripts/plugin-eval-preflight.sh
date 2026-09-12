#!/usr/bin/env bash
# Preflight for `/plugin-eval` (HIMMEL-2931): bank check + version floor.
# Never invokes `claude plugin eval` itself — the command gates that
# invocation on this script's exit code. Exit 0 prints PROCEED on stdout;
# exit 1 prints the refusal reason on stderr.
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Pure bash + coreutils (grep, sort -V); no .ps1 twin needed.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIN_VERSION="2.1.269"

bank="$(CADENCE_BANK_LEG=plugin-eval bash "$SCRIPT_DIR/lib/bank-preflight.sh" 2>/dev/null)"
bank_rc=$?
if [ "$bank_rc" -ne 0 ]; then
    echo "plugin-eval-preflight: refused — bank-preflight.sh exited $bank_rc (contract is always-0; treat as a failed bank check)" >&2
    exit 1
fi
if [ "$bank" = "SKIPPED-BANK" ]; then
    echo "plugin-eval-preflight: refused — bank preflight returned SKIPPED-BANK (five_hour >= 85)" >&2
    exit 1
fi

version_line="$(claude --version 2>/dev/null)" || {
    echo "plugin-eval-preflight: refused — claude --version failed" >&2
    exit 1
}
version="$(printf '%s' "$version_line" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
if [ -z "$version" ]; then
    echo "plugin-eval-preflight: refused — could not parse a version from '$version_line'" >&2
    exit 1
fi

if ! printf '%s\n%s\n' "$MIN_VERSION" "$version" | sort -C -V 2>/dev/null; then
    echo "plugin-eval-preflight: refused — claude $version is below the $MIN_VERSION floor claude plugin eval needs" >&2
    exit 1
fi

echo "PROCEED"
