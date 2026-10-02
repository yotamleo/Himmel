#!/usr/bin/env bash
# HIMMEL-4081: hermetic lane bank gate, no key or real HTTP request.
# PLATFORM GUARD: bank-preflight is a POSIX shell path; no PowerShell twin.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
W="$(mktemp -d)" || exit 1
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/repo/scripts/lib" "$W/repo/scripts/lanes" "$W/home" "$W/proc"
cp "$REPO/scripts/lib/"*.sh "$W/repo/scripts/lib/"
cat > "$W/repo/scripts/lanes/openrouter-cost.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${OR_READING:-balance=? spend=?}"
STUB
cat > "$W/ps" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$W/ps"
fails=0
check() {
  local label="$1" expected="$2" actual; shift 2
  actual="$(env HOME="$W/home" HIMMEL_FLEET_CAP=4 HIMMEL_FLEET_SLOTS="$W/slots" FLEET_PS_CMD="$W/ps" FLEET_PROC="$W/proc" CADENCE_BANK_LEDGER="$W/ledger" CADENCE_BANK_LAUNCH= CADENCE_BANK_LANE=openrouter "$@" bash "$W/repo/scripts/lib/bank-preflight.sh" 2>"$W/err")"
  if [ "$actual" = "$expected" ]; then echo "ok - $label"; else echo "FAIL - $label: expected $expected got $actual"; fails=$((fails+1)); fi
}
check 'key cap below default floor refuses' SKIPPED-BANK OR_READING='balance=0.50:key-limit_remaining spend=?'
check 'credit below default floor refuses' SKIPPED-BANK OR_READING='balance=2.99:credit spend=?'
check 'exact floor proceeds' PROCEED OR_READING='balance=3.00:key-limit_remaining spend=?'
check 'custom floor applies' SKIPPED-BANK OPENROUTER_MIN_CREDIT_USD=8 OR_READING='balance=7.50:credit spend=?'
check 'invalid floor falls back to three' SKIPPED-BANK OPENROUTER_MIN_CREDIT_USD=invalid OR_READING='balance=2.00:credit spend=?'
check 'unknown balance refuses honestly' BANK-UNKNOWN OR_READING='balance=? spend=?'
check 'negative balance refuses' SKIPPED-BANK OR_READING='balance=-0.50:credit spend=?'
check 'malformed balance is unknown' BANK-UNKNOWN OR_READING='balance=3.0.0:credit spend=?'
check 'leg lane marker selects OpenRouter without explicit lane' SKIPPED-BANK CADENCE_BANK_LANE= LEG_LANE=openrouter OR_READING='balance=0.50:key-limit_remaining spend=?'
printf 'test-bank-preflight-openrouter: %s failures\n' "$fails"
[ "$fails" -eq 0 ]
