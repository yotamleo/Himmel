#!/usr/bin/env bash
# HIMMEL-3851: scripts/luna/vault-stall-alert.sh must hand the message to the
# operator's chat through the shared sender seam, and fail (non-zero) when it
# cannot deliver, so vault-autosync.sh retries instead of marking the stall
# episode alerted.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SINK="$ROOT/scripts/luna/vault-stall-alert.sh"
FAILED=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1 — $2"; FAILED=$((FAILED + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi; }

command -v jq >/dev/null 2>&1 || { echo "SKIP all — jq not on PATH"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/vault-stall-alert.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
printf '{"allowFrom":["4242"]}\n' >"$TMP/access.json"
printf '{"allowFrom":[]}\n' >"$TMP/empty-access.json"
cat >"$TMP/sender.sh" <<EOF
#!/usr/bin/env bash
printf '%s|%s\n' "\$1" "\$2" >>"$TMP/sent.log"
EOF
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/bad-sender.sh"
chmod +x "$TMP/sender.sh" "$TMP/bad-sender.sh"

TELEGRAM_ACCESS_PATH="$TMP/access.json" MERGE_BLOCK_ALERT_CMD="$TMP/sender.sh" \
    bash "$SINK" "vault stall: hook x refused file y"
assert_eq "V1 delivered: exit 0" "0" "$?"
assert_eq "V1b sent to the operator chat with the message" \
    "4242|vault stall: hook x refused file y" "$(cat "$TMP/sent.log" 2>/dev/null)"

TELEGRAM_ACCESS_PATH="$TMP/access.json" MERGE_BLOCK_ALERT_CMD="$TMP/bad-sender.sh" \
    bash "$SINK" "msg" 2>/dev/null
assert_eq "V2 sender failure: non-zero (autosync must retry)" "1" "$?"

: >"$TMP/sent.log"
TELEGRAM_ACCESS_PATH="$TMP/empty-access.json" MERGE_BLOCK_ALERT_CMD="$TMP/sender.sh" \
    bash "$SINK" "msg" 2>/dev/null
assert_eq "V3 no operator id: non-zero" "1" "$?"
assert_eq "V3b nothing sent without an operator id" "" "$(cat "$TMP/sent.log")"

TELEGRAM_ACCESS_PATH="$TMP/access.json" MERGE_BLOCK_ALERT_CMD="$TMP/sender.sh" \
    bash "$SINK" 2>/dev/null
assert_eq "V4 empty message: rejected (2)" "2" "$?"

echo "----"
if [ "$FAILED" -eq 0 ]; then echo "PASS: vault-stall-alert ($0)"; else echo "FAIL: vault-stall-alert — $FAILED failed ($0)" >&2; exit 1; fi
