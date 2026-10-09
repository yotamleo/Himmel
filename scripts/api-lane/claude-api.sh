#!/usr/bin/env bash
# HIMMEL-4985: one-shot API-key launcher (task 2 of the HIMMEL-4904 plan).
# Runs ONE print-mode call billed to the API credit of HIMMEL_API_ACCOUNT, with
# auth isolation, a roster check, the API bank gate and a reserve/settle ledger entry.
# Deliberately NOT native-auth-pin: this lane is the API-key exception, so it
# removes the other credential sources itself instead of pinning native auth.
#
# Usage: claude-api.sh -p [prompt] --model M --permission-mode MODE \
#                      --max-budget-usd N [other claude flags]
# Env:   HIMMEL_API_LANE=on  HIMMEL_API_ACCOUNT=A|B  HIMMEL_API_KEY_ID=<roster id>
#        ANTHROPIC_API_KEY (presence only; never printed, logged or passed on a command line)
# OFF by default. No A/B rotation, no subscription fallback: a refusal is final.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLAUDE_BIN="${HIMMEL_API_CLAUDE_BIN:-claude}"

refuse() { echo "claude-api: refused: $*" >&2; exit 2; }

# --- lane opt-in and credentials (presence checks only) ---
[ "${HIMMEL_API_LANE:-}" = "on" ] || refuse "api lane is OFF (set HIMMEL_API_LANE=on)"
case "${HIMMEL_API_ACCOUNT:-}" in A|B) ;; *) refuse "HIMMEL_API_ACCOUNT must be A or B" ;; esac
[ -n "${ANTHROPIC_API_KEY:-}" ] || refuse "ANTHROPIC_API_KEY is absent"
[ -n "${HIMMEL_API_KEY_ID:-}" ] || refuse "HIMMEL_API_KEY_ID is absent"

# --- conflicting providers outrank the key or bill elsewhere: refuse, never guess ---
for v in CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY; do
  [ -z "${!v:-}" ] || refuse "conflicting provider flag $v"
done
[ -z "${ANTHROPIC_AUTH_TOKEN:-}" ] || refuse "conflicting provider ANTHROPIC_AUTH_TOKEN"
case "${HIMMEL_CLAUDE_LANE:-}" in ""|native) ;; *) refuse "conflicting lane HIMMEL_CLAUDE_LANE=$HIMMEL_CLAUDE_LANE" ;; esac

# --- argument policy: print mode only, explicit permission mode, model and budget ---
PRINT=0 MODE="" MODEL="" BUDGET="" FORMAT=""
ARGS=()
while [ "$#" -gt 0 ]; do
  a="$1"; shift
  # any spelling of a bypass flag (=true, =anything, any case, _ for -), and every caller-supplied tool list,
  # settings, MCP, plugin or extra-directory source: the launcher's own --allowedTools is the only one claude may see.
  # A @file argument is an args file, which could carry any of them.
  case "$a" in -*) n="$(printf '%s' "${a%%=*}" | tr 'A-Z_' 'a-z-')" ;; *) n="" ;; esac
  case "$n" in
    --dangerously-skip-permissions|--allow-dangerously-skip-permissions|--allowedtools|--allowed-tools|--settings|--mcp-config|--plugin-dir|--add-dir)
      refuse "flag ${a%%=*} is not allowed on the api lane" ;;
  esac
  case "$a" in @*) refuse "an @argsfile argument is not allowed on the api lane" ;; esac
  case "$a" in
    -p|--print) PRINT=1; ARGS+=("$a"); continue ;;
    --) refuse "the -- argument terminator would turn the enforced options into positionals" ;;
    --bg|--background|--cloud|--daemon) # t13b-ok: refuses the flag, starts no service
      refuse "flag $a is not allowed on the api lane" ;;
    --permission-mode|--model|--max-budget-usd|--output-format)
      [ "$#" -gt 0 ] || refuse "$a needs a value"
      val="$1"; shift ;;
    --permission-mode=*|--model=*|--max-budget-usd=*|--output-format=*)
      val="${a#*=}"; a="${a%%=*}" ;;
    *) ARGS+=("$a"); continue ;;
  esac
  case "$a" in
    --permission-mode) MODE="$val" ;;
    --model) MODEL="$val" ;;
    --max-budget-usd) BUDGET="$val" ;;
    --output-format) FORMAT="$val" ;;
  esac
done
[ "$PRINT" = 1 ] || refuse "only -p/--print runs are allowed"
[ -n "$MODE" ] || refuse "--permission-mode is required"
[ "$MODE" != "bypassPermissions" ] || refuse "permission mode bypassPermissions is not allowed"
[ -n "$MODEL" ] || refuse "--model is required"
case "$MODEL" in *[!A-Za-z0-9._:/@-]*) refuse "--model has characters outside [A-Za-z0-9._:/@-]" ;; esac
[ -n "$BUDGET" ] || refuse "--max-budget-usd is required"
case "$FORMAT" in ""|json) ;; *) refuse "--output-format must be json" ;; esac

# --- roster: the selector must map to the credential's recorded key id ---
ROSTER="$(node "$REPO/scripts/api-lane/roster.mjs")" || refuse "roster: ${ROSTER#reason=}"
ROSTER_KEY="" ROSTER_ORG="" ROSTER_CYCLE="" STATE_DIR=""
while IFS='=' read -r k v; do
  case "$k" in
    key_id) ROSTER_KEY="$v" ;; organization_id) ROSTER_ORG="$v" ;;
    cycle_id) ROSTER_CYCLE="$v" ;; state_dir) STATE_DIR="$v" ;;
  esac
done <<EOF
$ROSTER
EOF
[ -n "$ROSTER_KEY" ] || refuse "roster has no key_id for account $HIMMEL_API_ACCOUNT"
[ "$HIMMEL_API_KEY_ID" = "$ROSTER_KEY" ] || refuse "key id does not match account $HIMMEL_API_ACCOUNT"

# --- API bank gate: the credit row decides; the native bank is never consulted ---
JOB_ID="${HIMMEL_API_JOB_ID:-api-$(date +%s)-$$}"
case "$JOB_ID" in ""|*[!A-Za-z0-9._:-]*) refuse "job id has characters outside [A-Za-z0-9._:-]" ;; esac
BANK_VERDICT="$(env -u CLAUDE_CODE_OAUTH_TOKEN CADENCE_BANK_LANE=api CADENCE_BANK_LAUNCH=1 LEG_LANE=api \
  CADENCE_BANK_LEG="${CADENCE_BANK_LEG:-claude-api:$JOB_ID}" \
  bash "$REPO/scripts/lib/bank-preflight.sh")" || BANK_VERDICT=BANK-UNKNOWN
[ "$BANK_VERDICT" = "PROCEED" ] || refuse "api bank gate said $BANK_VERDICT"

# HIMMEL-5073: CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 (what keeps the key out of Bash-tool children) forces
# permission mode "default" whatever --permission-mode a caller passes (the eval passes auto), and in -p that
# denies Edit/Write/Bash unless declared here. The scrub is the bwrap sandbox, so it cannot be dropped; this
# allowance is the fixture-work tool set, the sandbox bounds Bash, and callers cannot add to or replace it.
ALLOWED_TOOLS="Read,Edit,Write,Glob,Grep,Bash"

OUT="$(mktemp "${TMPDIR:-/tmp}/claude-api-out.XXXXXX")" || refuse "no scratch file"
trap 'rm -f "$OUT"' EXIT

# --- reserve the full budget before spending; refusal here means no launch ---
state() { node "$REPO/scripts/lib/api-credit-state.mjs" "$@"; }
RESERVED="$(state reserve --id "$JOB_ID" --usd "$BUDGET")"
case "$RESERVED" in *'"verdict":"PROCEED"'*) ;; *) refuse "reservation refused: $RESERVED" ;; esac

# --- launch: provider vars removed, endpoint pinned, only the key carried in ---
# headless-claude-ok: HIMMEL-4985 one-shot API-credit launch; bank gate, reservation and explicit --permission-mode above
env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_PROFILE -u ANTHROPIC_FEDERATION_RULE_ID \
  -u ANTHROPIC_ORGANIZATION_ID -u ANTHROPIC_AUTH_TOKEN -u HIMMEL_API_LANE -u HIMMEL_API_KEY_ID \
  ANTHROPIC_BASE_URL=https://api.anthropic.com CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 \
  "$CLAUDE_BIN" "${ARGS[@]}" --model "$MODEL" --permission-mode "$MODE" \
  --allowedTools "$ALLOWED_TOOLS" --max-budget-usd "$BUDGET" --output-format json >"$OUT"
RC=$?

# --- settle on verified cost, otherwise keep the reservation as unknown ---
COST="$(node "$REPO/scripts/api-lane/outcome.mjs" "$OUT")"
if [ "$RC" -eq 0 ] && [ -n "$COST" ]; then
  SETTLED="$(state settle --id "$JOB_ID" --usd "$COST" --completion verified)"
  case "$SETTLED" in
    *'"reason":"settled"'*) OUTCOME=settled ;;
    *'"reason":"reservation-overrun"'*) OUTCOME=overrun; echo "claude-api: warning: cost exceeded the reservation; ledger flagged" >&2 ;;
    *) echo "claude-api: warning: settle failed ($SETTLED); keeping the reservation as unknown" >&2
       state unknown --id "$JOB_ID" >/dev/null; OUTCOME=unknown ;;
  esac
else
  state unknown --id "$JOB_ID" >/dev/null; OUTCOME=unknown
fi

# --- secret-free launch record (no key, no prompt) ---
SOURCE="$(printf '%s' "$RESERVED" | sed -n 's/.*"source":"\([^"]*\)".*/\1/p')"
{
  printf '{"ts":"%s","job_id":"%s","account":"%s","organization_id":"%s","key_id":"%s","cycle_id":"%s","model":"%s","budget_usd":"%s","source":"%s","outcome":"%s","cost_usd":"%s","rc":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$JOB_ID" "$HIMMEL_API_ACCOUNT" "$ROSTER_ORG" "$ROSTER_KEY" \
    "$ROSTER_CYCLE" "$MODEL" "$BUDGET" "$SOURCE" "$OUTCOME" "$COST" "$RC"
} >>"$STATE_DIR/launches.jsonl" 2>/dev/null || echo "claude-api: warning: launch record not written" >&2

cat "$OUT"
exit "$RC"
