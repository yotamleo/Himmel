#!/usr/bin/env bash
# validate.sh — structural validation for the propagation exclusion lists
# and the secret-scan regex patterns. Exits 0 only when everything is
# well-formed. Run from this directory: bash validate.sh
set -u

fail=0

# --- propagation-config.sh: PRIVATE_PATHS bash array ---
. ./propagation-config.sh

if [ "${#PRIVATE_PATHS[@]}" -eq 0 ]; then
    echo "validate: PRIVATE_PATHS is empty" >&2
    fail=1
fi

seen="|"
for p in "${PRIVATE_PATHS[@]}"; do
    if [ -z "$p" ]; then
        echo "validate: PRIVATE_PATHS has an empty entry" >&2
        fail=1
        continue
    fi
    case "$seen" in
        *"|$p|"*)
            echo "validate: PRIVATE_PATHS has a duplicate entry: $p" >&2
            fail=1
            ;;
    esac
    seen="$seen$p|"
done

# --- propagation-config.json: privatePaths JSON array ---
if ! node -e '
const data = JSON.parse(require("fs").readFileSync("propagation-config.json", "utf8"));
const arr = data.privatePaths;
if (!Array.isArray(arr) || arr.length === 0) {
    console.error("validate: privatePaths is missing or empty");
    process.exit(1);
}
const seen = new Set();
for (const p of arr) {
    if (typeof p !== "string" || p.length === 0) {
        console.error("validate: privatePaths has a non-string/empty entry");
        process.exit(1);
    }
    if (seen.has(p)) {
        console.error("validate: privatePaths has a duplicate entry: " + p);
        process.exit(1);
    }
    seen.add(p);
}
'; then
    fail=1
fi

# --- secret-scan-patterns.txt: every pattern must be a valid, anchored ERE ---
while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
        '^'*'$')
            :
            ;;
        *)
            echo "validate: unanchored pattern: $line" >&2
            fail=1
            continue
            ;;
    esac
    printf '' | grep -Eq -- "$line" 2>/dev/null
    rc=$?
    if [ "$rc" -eq 2 ]; then
        echo "validate: invalid regex: $line" >&2
        fail=1
    fi
done < secret-scan-patterns.txt

if [ "$fail" -eq 0 ]; then
    echo "OK: all propagation lists and patterns are valid"
    exit 0
else
    exit 1
fi
