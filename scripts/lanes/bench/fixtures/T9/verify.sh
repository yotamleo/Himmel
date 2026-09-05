#!/usr/bin/env bash
set -u
FIX="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091  # verify-common.sh is sourced at runtime; linted standalone by pre-commit
. "$(cd "$(dirname "$0")/../../lib" && pwd)/verify-common.sh"
assert_only_paths_changed "$FIX/input" "$FIX/manifest.txt" || exit 1

OUT="audit.psv"

if [ ! -f "$OUT" ]; then
    echo "verify: missing $OUT" >&2
    exit 1
fi

expected_header='ticket_id|status|priority|assignee|title'
actual_header="$(awk 'NR==1{print; exit}' "$OUT")"
if [ "$actual_header" != "$expected_header" ]; then
    echo "verify: bad header row: got [$actual_header] want [$expected_header]" >&2
    exit 1
fi

total_lines="$(awk 'END{print NR}' "$OUT")"
data_rows=$((total_lines - 1))
if [ "$data_rows" -ne 20 ]; then
    echo "verify: expected 20 data rows, got $data_rows" >&2
    exit 1
fi

# Column count must be exactly 5 on every line (header + 20 data rows),
# treating an escaped pipe (\|) as part of a value rather than a delimiter.
col_counts="$(awk '
{
    line = $0
    gsub(/\\\|/, "\001", line)
    n = split(line, parts, "|")
    print n
}' "$OUT" | sort -u)"
if [ "$col_counts" != "5" ]; then
    echo "verify: inconsistent or wrong column count(s) across rows: $col_counts" >&2
    exit 1
fi

expected_rows="$(mktemp)"
printf '%s\n' \
    'ticket_id|status|priority|assignee|title' \
    'TCK-101|Open|P2|dana|Fix login redirect loop' \
    'TCK-102|In Progress|P1|marcus|Update onboarding email copy' \
    'TCK-103|Done|P3|priya|Refresh vendor contact table' \
    'TCK-104|Blocked|P0|elena|Resolve payment webhook duplication' \
    'TCK-105|Open|P2|tom|Add pagination to search results' \
    'TCK-106|Closed|P3|sofia|Archive stale customer records' \
    'TCK-107|Open|P2|dana|Handle rg \| grep pipeline crash' \
    'TCK-108|In Progress|P1|raj|Rewrite CSV export for large accounts' \
    'TCK-109|Done|P2|wei|Normalize timezone handling in reports' \
    'TCK-110|Blocked|P1|nadia|Investigate memory leak in worker pool' \
    'TCK-111|Open|P3|liam|Add retry logic to webhook sender' \
    'TCK-112|Done|P0|dana|Patch SQL injection in search endpoint' \
    'TCK-113|Closed|P2|marcus|Deprecate legacy auth token format' \
    'TCK-114|In Progress|P3|priya|Improve error messages on upload failure' \
    'TCK-115|Open|P1|elena|Rebuild nightly backup verification job' \
    'TCK-116|Blocked|P2|tom|Sync inventory counts across warehouses' \
    'TCK-117|Done|P3|sofia|Clean up dead feature flags' \
    'TCK-118|Open|P0|raj|Fix race condition in order cancellation' \
    'TCK-119|Closed|P1|wei|Migrate scheduled jobs to new queue' \
    'TCK-120|In Progress|P2|nadia|Add audit log export to admin panel' > "$expected_rows"
assert_bytes_equal "$expected_rows" "$OUT"
ok=$?
rm -f "$expected_rows"

[ "$ok" -eq 0 ]
