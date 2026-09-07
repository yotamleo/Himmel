#!/usr/bin/env bash
set -u
FIX="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091  # verify-common.sh is sourced at runtime; linted standalone by pre-commit
. "$(cd "$(dirname "$0")/../../lib" && pwd)/verify-common.sh"
assert_only_paths_changed "$FIX/input" "$FIX/manifest.txt" || exit 1

fail=0

assert_json_parses propagation-config.json || fail=1

NEW_ENTRIES='config/local-secrets/ .himmel-cache/ scripts/vault-keys/ notes/private-journal/'
ORIG_ENTRIES='handovers/ docs/internals/ .env scripts/secrets/'

for entry in $NEW_ENTRIES $ORIG_ENTRIES; do
    needle="\"$entry\""
    if ! grep -Fq -- "$needle" propagation-config.sh; then
        echo "verify: entry missing from propagation-config.sh: $entry" >&2
        fail=1
    fi
    if ! grep -Fq -- "$needle" propagation-config.json; then
        echo "verify: entry missing from propagation-config.json: $entry" >&2
        fail=1
    fi
done

# secret-scan-patterns.txt must match the literal expected contract.
expected_patterns="$(mktemp)"
printf '%s\n' \
    '^AKIA[0-9A-Z]{16}$' \
    '^ghp_[A-Za-z0-9]{36}$' \
    '^sk-[A-Za-z0-9]{48}$' \
    '^xox[baprs]-[0-9A-Za-z-]{10,72}$' \
    '^AIza[0-9A-Za-z_-]{35}$' > "$expected_patterns"
assert_bytes_equal "$expected_patterns" secret-scan-patterns.txt || fail=1
rm -f "$expected_patterns"

if ! bash validate.sh; then
    echo "verify: validate.sh failed" >&2
    fail=1
fi

[ "$fail" -eq 0 ]
exit $?
