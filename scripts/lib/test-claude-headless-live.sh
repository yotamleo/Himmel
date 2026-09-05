#!/usr/bin/env bash
# test-claude-headless-live.sh — HIMMEL-2178. The wrapper's own exit
# criterion (architecture doc §4 Chain 2a): a REAL, trivial `claude` `-p`
# dispatch through scripts/lib/claude-headless.sh, verifying the registry
# row and artifact-check verdict land correctly. Not part of the hermetic
# suite (test-claude-headless.sh) — this spends a small amount of bank, so
# it gates on bank-preflight itself and SKIPs loudly (rc 0) rather than
# failing when the bank is not available, per the plan's explicit
# instruction not to let an unattended bank refusal look like a bug.
# shellcheck disable=SC2012  # registry ids are UUIDs; ls-over-glob is fine here
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SUT="$REPO/scripts/lib/claude-headless.sh"

BANK_VERDICT="$(CADENCE_BANK_LEG=claude-headless-live-selftest bash "$REPO/scripts/lib/bank-preflight.sh")"
if [ "$BANK_VERDICT" != "PROCEED" ]; then
  echo "test-claude-headless-live: SKIP - bank preflight verdict '$BANK_VERDICT', not spending on the live self-test"
  exit 0
fi

W="$(mktemp -d -t claude-headless-live-test.XXXXXX)"; trap 'rm -rf "$W"' EXIT
# A bare `mktemp -t` gives a POSIX-only /tmp/... path on this platform. That
# is fine for bash's own file tests (artifact_present() below) but NOT for a
# path the PROMPT tells the model to write to: native claude.exe's Write
# tool needs a Windows-form path to resolve reliably — a POSIX-style path in
# the prompt text was observed to make the model non-deterministically
# report success without writing anything (diagnosed empirically: identical
# invocations with a Windows-form path never showed this, several with a
# POSIX-form path did). cygpath -m converts once, up front, for everything
# derived from $W.
if command -v cygpath >/dev/null 2>&1; then W="$(cygpath -m "$W")"; fi
REGISTRY_DIR="$W/registry"
ARTIFACT="$W/live-selftest-artifact.txt"
PROMPT_FILE="$W/prompt.txt"
cat > "$PROMPT_FILE" <<EOF
Run exactly this and nothing else: write the single line OK to the file
$ARTIFACT (create it if it does not exist), then stop. Do not ask questions.
EOF

echo "test-claude-headless-live: dispatching trivial live claude/-p job (artifact: $ARTIFACT)"
HIMMEL_REGISTRY_DIR="$REGISTRY_DIR" bash "$SUT" \
  --role live-selftest --ticket HIMMEL-2178 --worktree "$W" --cwd "$W" \
  --artifact "$ARTIFACT" --permission-mode acceptEdits \
  --allowed-tools "Write" --model haiku --prompt-file "$PROMPT_FILE"
RC=$?

ROW="$(ls "$REGISTRY_DIR/live"/*.json 2>/dev/null | head -1)"
if [ -z "$ROW" ]; then
  echo "test-claude-headless-live: FAIL - no registry row was written" >&2
  exit 1
fi
STATUS="$(jq -r '.status' "$ROW")"
VERDICT="$(jq -r '.artifact_check.verdict' "$ROW")"
echo "test-claude-headless-live: registry row status=$STATUS artifact_check=$VERDICT rc=$RC"
if [ "$STATUS" = "completed" ] && [ "$VERDICT" = "pass" ] && [ "$RC" -eq 0 ]; then
  echo "test-claude-headless-live: PASS - registry row + artifact verdict landed correctly"
  exit 0
fi
echo "test-claude-headless-live: FAIL - dispatch did not land a completed row with a passing artifact check" >&2
echo "--- registry row ---" >&2
cat "$ROW" >&2
exit 1
