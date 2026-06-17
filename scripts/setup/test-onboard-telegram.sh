#!/usr/bin/env bash
# Smoke test for scripts/setup/onboard-telegram.sh (HIMMEL-227).
# Everything runs against a temp TELEGRAM_CHANNEL_DIR — never touches the
# operator's real channel dir, access.json, or the live bridge.
set -uo pipefail

CLI="$(cd "$(dirname "$0")" && pwd)/onboard-telegram.sh"

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

assert_has() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) echo "PASS $label" ;;
        *)
            echo "FAIL $label — output missing: $needle"
            FAILED=$((FAILED + 1))
            ;;
    esac
}

assert_lacks() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*)
            echo "FAIL $label — output unexpectedly contains: $needle"
            FAILED=$((FAILED + 1))
            ;;
        *) echo "PASS $label" ;;
    esac
}

FAILED=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CHANNEL="$TMP/channels/telegram"

# 1. fresh machine: dir + .env template created, access.json NOT created
out=$(TELEGRAM_CHANNEL_DIR="$CHANNEL" bash "$CLI" 2>&1); rc=$?
assert_rc "fresh run exits 0" 0 "$rc"
if [ -d "$CHANNEL" ]; then
    echo "PASS channel dir created"
else
    echo "FAIL channel dir not created"; FAILED=$((FAILED + 1))
fi
if grep -q '^TELEGRAM_BOT_TOKEN=$' "$CHANNEL/.env" 2>/dev/null; then
    echo "PASS .env template created with empty token"
else
    echo "FAIL .env template missing or malformed"; FAILED=$((FAILED + 1))
fi
if [ -e "$CHANNEL/access.json" ]; then
    echo "FAIL access.json was created — onboarding must NEVER write it"
    FAILED=$((FAILED + 1))
else
    echo "PASS access.json not created"
fi
assert_has "fresh run reports missing pairing" "access.json: MISSING" "$out"
assert_has "fresh run prints bridge bring-up" "bridge bring-up" "$out"
# Warp onboarding split out into onboard-warp.sh (HIMMEL-360) — the telegram
# step must no longer emit any Warp output.
assert_lacks "fresh run no longer mentions warp" "Warp" "$out"

# 2. idempotence: existing .env (with a token) is never rewritten
printf 'TELEGRAM_BOT_TOKEN=123:abc\n# operator custom line\n' > "$CHANNEL/.env"
before=$(cat "$CHANNEL/.env")
out=$(TELEGRAM_CHANNEL_DIR="$CHANNEL" bash "$CLI" 2>&1); rc=$?
assert_rc "re-run exits 0" 0 "$rc"
after=$(cat "$CHANNEL/.env")
if [ "$before" = "$after" ]; then
    echo "PASS existing .env untouched"
else
    echo "FAIL existing .env was modified"; FAILED=$((FAILED + 1))
fi
assert_has "re-run reports token set" ".env: present (token set)" "$out"

# 3. existing pairing is reported, file untouched
printf '{"allowFrom":["42"]}\n' > "$CHANNEL/access.json"
before=$(cat "$CHANNEL/access.json")
out=$(TELEGRAM_CHANNEL_DIR="$CHANNEL" bash "$CLI" 2>&1); rc=$?
assert_rc "paired run exits 0" 0 "$rc"
after=$(cat "$CHANNEL/access.json")
if [ "$before" = "$after" ]; then
    echo "PASS access.json untouched"
else
    echo "FAIL access.json was modified"; FAILED=$((FAILED + 1))
fi
assert_has "paired run reports pairing configured" "pairing configured" "$out"

# 4. empty-token .env is flagged but not rewritten
printf '# comment only\nTELEGRAM_BOT_TOKEN=\n' > "$CHANNEL/.env"
out=$(TELEGRAM_CHANNEL_DIR="$CHANNEL" bash "$CLI" 2>&1); rc=$?
assert_rc "empty-token run exits 0" 0 "$rc"
assert_has "empty token flagged" "TELEGRAM_BOT_TOKEN is empty" "$out"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "$FAILED FAILURE(S)"
    exit 1
fi
