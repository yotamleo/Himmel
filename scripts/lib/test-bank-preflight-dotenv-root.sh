#!/usr/bin/env bash
# test-bank-preflight-dotenv-root.sh — HIMMEL-3532. RED-first regression: the
# fleet cap must come from bank-preflight's OWN checkout's .env, never from
# whatever git repo the caller's CWD happens to be inside.
#
# Fixture: a scratch copy of bank-preflight.sh + load-dotenv.sh laid out as
# <scratch>/scripts/lib/*, so bank-preflight's own $REPO resolution
# (dirname "$0"/../..) lands on <scratch>, with <scratch>/.env carrying
# HIMMEL_FLEET_CAP=15. CWD is then pointed at a SEPARATE, foreign git repo
# (a bare `git init` mktemp dir) with no .env of its own at all. The old
# (CWD-based) load_dotenv call resolves the .env root from the CWD repo, not
# from $REPO, finds no HIMMEL_FLEET_CAP there, and falls back to the default
# cap of 4 -- this suite asserts the cap is 15 (from the SUT's own checkout),
# never 4.
#
# Hermetic: no live bank fetch, no real ps/proc census, no HOME writes
# outside the scratch dir, and the real primary checkout's .env is never
# read (block-read-secrets) -- only a fixture .env this suite writes itself.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0
W="$(mktemp -d -t bank-preflight-dotenv-root.XXXXXX)" || { echo "FAIL - could not create scratch dir via mktemp" >&2; exit 1; }
if [ -z "$W" ] || [ ! -d "$W" ]; then echo "FAIL - mktemp returned an empty/invalid scratch dir" >&2; exit 1; fi
trap 'rm -rf "$W"' EXIT

check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok - $1";
  else FAIL=$((FAIL+1)); echo "FAIL - $1: expected '$2' got '$3'"; fi; }

# --- scratch "own checkout": scripts/lib/{bank-preflight.sh,load-dotenv.sh}
# copied verbatim (not symlinked -- REPO resolution is dirname-based, and a
# symlinked script's dirname can resolve to the link's OWN directory
# identically either way, but a real copy is the least surprising fixture)
# plus a fixture .env at its root carrying the cap this suite expects to see.
own="$W/own-checkout"
mkdir -p "$own/scripts/lib"
cp "$REPO/scripts/lib/bank-preflight.sh" "$own/scripts/lib/bank-preflight.sh"
cp "$REPO/scripts/lib/load-dotenv.sh" "$own/scripts/lib/load-dotenv.sh"
printf 'HIMMEL_FLEET_CAP=15\n' > "$own/.env"
SUT="$own/scripts/lib/bank-preflight.sh"

# --- a FOREIGN git repo the caller's CWD sits inside, with no .env of its
# own -- this is the luna-vault-bucket repro from the ticket, generalised so
# the suite runs on any machine.
foreign="$W/foreign-repo"
mkdir -p "$foreign/nested/bucket"
( cd "$foreign" && git init -q )

p0="$W/ps0"; mkdir -p "$p0/proc"
printf '%s\n' '#!/usr/bin/env bash' 'true' > "$p0/ps"; chmod +x "$p0/ps"
NOW="$(date +%s)"
printf '{"five_hour":{"utilization":10},"seven_day":{"utilization":20},"primaries_refreshed_at":%s}' "$NOW" > "$W/c.json"

out="$W/out"; err="$W/err.log"
( cd "$foreign/nested/bucket" && env HIMMEL_FLEET_CAP= FLEET_PS_CMD="$p0/ps" FLEET_PROC="$p0/proc" \
    HIMMEL_FLEET_SLOTS="$W/slots" CADENCE_BANK_CACHE="$W/c.json" CADENCE_BANK_SKIP_REFRESH=1 \
    CADENCE_BANK_LEDGER="$W/ledger.jsonl" bash "$SUT" </dev/null > "$out" 2>"$err" )

fleet_line="$(grep -o 'FLEET .*total=[0-9]*/[0-9]*' "$err" || true)"
cap="${fleet_line##*/}"
check "cap resolves from the SUT's own checkout's .env (15), not the foreign CWD repo's default (4) -- fleet line: $fleet_line" "15" "$cap"

echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
