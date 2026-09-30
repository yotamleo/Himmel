#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check()/contains(), as in test-append-results.sh
# scripts/handover/console-kit/test-fleet-manifest.sh - suite for
# fleet-manifest.sh (HIMMEL-3748), the console's one writer for its fleet
# manifest (the JSON `tick.sh --legs-from` reads every sample):
#   1. add to a missing manifest creates it (schema 1, doc + N-label entry)
#   2. add is idempotent; a second leg appends in order; list prints docs
#   3. remove by label and by doc; removing an absent leg is not an error
#   4. a relative doc is refused (tick would resolve it against a different root)
#   5. keys the writer does not own survive a rewrite (room for HIMMEL-1873)
#   6. list on a missing or invalid manifest fails; add refuses to clobber an
#      invalid one
#   7. concurrent adds (two dispatches at once) lose no entry
#
# Hermetic: temp dir only. PLATFORM GUARD: no .ps1 twin, by design -- the
# console kit is Linux-only (util-linux flock). bash 3.2-safe.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/fleet-manifest.sh"

if ! command -v flock >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "skip - test-fleet-manifest.sh: needs flock and jq (the console kit is Linux-only)"
    exit 0
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/fleet-manifest-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd)"
fails=0
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

m="$tmp/console.fleet.json"
d1="$tmp/HIMMEL-1-N61-a-2026-09-30-RESUME.md"
d2="$tmp/HIMMEL-2-N65-b-2026-09-30-RESUME.md"

# 1. add creates the manifest.
bash "$SCRIPT" add "$m" "$d1" >/dev/null 2>&1; rc=$?
check '1. add to a missing manifest succeeds' 0 "$rc"
check '1. the new manifest is schema 1' 1 "$(jq -r '.schema' "$m" 2>/dev/null)"
check '1. the entry carries the absolute doc' "$d1" "$(jq -r '.legs[0].doc' "$m" 2>/dev/null)"
check '1. the entry carries the leg-identity label' N61 "$(jq -r '.legs[0].label' "$m" 2>/dev/null)"
check '1. the entry carries an added timestamp' yes "$(jq -e '.legs[0].added | test("^[0-9]{4}-")' "$m" >/dev/null 2>&1 && echo yes)"

# 2. idempotent add, order, list.
bash "$SCRIPT" add "$m" "$d1" >/dev/null 2>&1
bash "$SCRIPT" add "$m" "$d2" >/dev/null 2>&1
check '2. a repeated add does not duplicate a leg' 2 "$(jq '.legs | length' "$m" 2>/dev/null)"
check '2. list prints the docs in manifest order' "$d1
$d2" "$(bash "$SCRIPT" list "$m" 2>/dev/null)"

# 3. remove.
bash "$SCRIPT" remove "$m" N61 >/dev/null 2>&1; rc=$?
check '3. remove by label succeeds' 0 "$rc"
check '3. remove by label drops only that leg' "$d2" "$(bash "$SCRIPT" list "$m" 2>/dev/null)"
bash "$SCRIPT" remove "$m" "$d2" >/dev/null 2>&1
check '3. remove by doc empties the leg set' 0 "$(jq '.legs | length' "$m" 2>/dev/null)"
check '3. an empty manifest lists nothing and succeeds' "0:" "$(out="$(bash "$SCRIPT" list "$m" 2>/dev/null)"; echo "$?:$out")"
bash "$SCRIPT" remove "$m" N99 >/dev/null 2>&1; rc=$?
check '3. removing a leg that is not listed is not an error' 0 "$rc"

# 4. relative doc refused.
bash "$SCRIPT" add "$m" relative/HIMMEL-3-N70-c.md >/dev/null 2>&1; rc=$?
check '4. a relative doc is a usage error (rc 2)' 2 "$rc"
check '4. and writes nothing' 0 "$(jq '.legs | length' "$m" 2>/dev/null)"

# 5. foreign keys survive.
printf '{"schema":1,"chains":{"c1":["N61"]},"legs":[{"doc":"%s","label":"N61","lane":"opus"}]}\n' "$d1" > "$m"
bash "$SCRIPT" add "$m" "$d2" >/dev/null 2>&1
check '5. a top-level key the writer does not own survives' '["N61"]' "$(jq -c '.chains.c1' "$m" 2>/dev/null)"
check '5. a per-leg key the writer does not own survives' opus "$(jq -r '.legs[0].lane' "$m" 2>/dev/null)"

# 6. missing / invalid.
bash "$SCRIPT" list "$tmp/none.fleet.json" >/dev/null 2>&1; rc=$?
check '6. list on a missing manifest fails' 1 "$rc"
printf 'not json\n' > "$tmp/bad.fleet.json"
bash "$SCRIPT" list "$tmp/bad.fleet.json" >/dev/null 2>&1; rc=$?
check '6. list on an invalid manifest fails' 1 "$rc"
bash "$SCRIPT" add "$tmp/bad.fleet.json" "$d1" >/dev/null 2>&1; rc=$?
check '6. add refuses an invalid manifest' 1 "$rc"
check '6. and leaves it untouched' 'not json' "$(cat "$tmp/bad.fleet.json")"
printf '{"schema":2,"legs":[]}\n' > "$tmp/v2.fleet.json"
bash "$SCRIPT" list "$tmp/v2.fleet.json" >/dev/null 2>&1; rc=$?
check '6. an unknown schema version is refused' 1 "$rc"

# 7. concurrent adds lose nothing.
c="$tmp/race.fleet.json"
pids=""
i=1
while [ "$i" -le 12 ]; do
    bash "$SCRIPT" add "$c" "$tmp/HIMMEL-$i-N$((100 + i))-r.md" >/dev/null 2>&1 &
    pids="$pids $!"
    i=$((i + 1))
done
for p in $pids; do wait "$p"; done
check '7. twelve concurrent adds keep all twelve legs' 12 "$(jq '.legs | length' "$c" 2>/dev/null)"
check '7. no temp file is left behind' 0 "$(find "$tmp" -name 'race.fleet.json.*' ! -name '*.lock' | wc -l | tr -d ' ')"

# 8. usage.
bash "$SCRIPT" >/dev/null 2>&1; rc=$?
check '8. no verb is a usage error (rc 2)' 2 "$rc"
bash "$SCRIPT" frob "$m" >/dev/null 2>&1; rc=$?
check '8. an unknown verb is a usage error (rc 2)' 2 "$rc"

if [ "$fails" -eq 0 ]; then
    echo "PASS - test-fleet-manifest.sh"
    exit 0
fi
echo "FAIL - test-fleet-manifest.sh ($fails failure(s))"
exit 1
