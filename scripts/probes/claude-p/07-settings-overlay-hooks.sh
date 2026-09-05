#!/usr/bin/env bash
# 07-settings-overlay-hooks.sh — probe 3e (HIMMEL-2178, Chain 2a).
#
# Question: does a `--settings <overlay.json>` on a headless `claude` `-p`
# session STRIP the project's .claude/settings.json hooks, MERGE with them,
# or leave them INTACT? Hook inheritance for profile workers is currently
# UNDESIGNED (architecture doc §4): strip = a guardrail bypass for writer
# roles, inherit-all = an interactive-shaped hook could hang a headless
# worker. This probe measures the actual behavior once so the P2b profile's
# hook-inheritance field can be designed against fact, not assumption.
#
# Method: a scratch project dir carries a PreToolUse hook (matcher: Bash)
# that appends a breadcrumb line to an absolute-path file. Run claude in
# -p mode TWICE with an identical Bash-triggering prompt: once with no --settings
# flag (control/baseline), once with a minimal `--settings {}` overlay
# (treatment). Compare breadcrumb presence after each run — the artifact,
# not the JSON envelope, is the verdict (this repo's standing rule).
#
# Same-shape as the P0 harness on feat/claude-p-probes
# (scripts/probes/claude-p/common.sh there): haiku, no /tmp (rc=127 trap;
# this repo requires probe state under scripts/, gitignored via tmp/), a
# fixed short timeout, MSYS_NO_PATHCONV=1 around every invocation (P0
# finding: Git Bash mangles a leading-slash arg into a Windows path before
# claude.exe sees it — not exercised by this probe's plain-text prompt, but
# set for consistency with every other headless call in this repo).
#
# ONE measured pass. Do not loop or retry this probe — record what happened.
set -uo pipefail

PROBE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$PROBE_DIR/tmp/07"
MODEL=haiku
TIMEOUT_S=120
REPO_ROOT="$(cd "$PROBE_DIR/../../.." && pwd)"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

echo "07-settings-overlay-hooks: bank preflight..."
BANK_VERDICT="$(CADENCE_BANK_LEG=probe-3e-settings-overlay-hooks bash "$REPO_ROOT/scripts/lib/bank-preflight.sh")"
echo "07-settings-overlay-hooks: bank verdict = $BANK_VERDICT"
if [ "$BANK_VERDICT" != "PROCEED" ]; then
  echo "07-settings-overlay-hooks: SKIP - bank preflight verdict '$BANK_VERDICT', not spending"
  exit 0
fi

SCRATCH="$OUT_DIR/scratch"
mkdir -p "$SCRATCH/.claude/hooks"
BREADCRUMB="$SCRATCH/breadcrumb.txt"

cat > "$SCRATCH/.claude/hooks/breadcrumb.sh" <<EOF
#!/usr/bin/env bash
echo "fired \$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$BREADCRUMB"
exit 0
EOF
chmod +x "$SCRATCH/.claude/hooks/breadcrumb.sh"

cat > "$SCRATCH/.claude/settings.json" <<EOF
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {"type": "command", "command": "bash \"$SCRATCH/.claude/hooks/breadcrumb.sh\""}
        ]
      }
    ]
  }
}
EOF

PROMPT_FILE="$OUT_DIR/prompt.txt"
echo "Use the Bash tool to run exactly this command: echo probe-marker" > "$PROMPT_FILE"

OVERLAY_FILE="$OUT_DIR/overlay.json"
echo '{}' > "$OVERLAY_FILE"
# MSYS_NO_PATHCONV=1 (set on every invocation below, per the mandatory P0
# convention) disables Git Bash's automatic POSIX->Windows path rewrite for
# EVERY argv element, not just a leading-slash prompt — so a POSIX-style
# path built by $(pwd) (e.g. /c/Users/...) reaches claude.exe unconverted
# and it cannot find the file. cygpath -m produces the Windows-style
# equivalent (C:/Users/...) so --settings still resolves under
# MSYS_NO_PATHCONV. First run of this probe hit exactly this (see
# RESULTS-3e.md methodology note) — corrected here, not papered over.
if command -v cygpath >/dev/null 2>&1; then OVERLAY_FILE="$(cygpath -m "$OVERLAY_FILE")"; fi

run_claude() {
  # $1 = output json path, $2 = stderr path, extra args (e.g. --settings ...) follow
  local out="$1" err="$2"; shift 2
  # codex-5: native_auth_pin_env strips any ambient ANTHROPIC_*/
  # CLAUDE_CODE_USE_* proxy env before the launch (native-auth-pin.sh,
  # HIMMEL-1867) — without it a proxied dev shell would silently measure the
  # proxy's hook behavior, not native claude's, with no warning.
  # shellcheck disable=SC1091
  ( cd "$SCRATCH" && . "$REPO_ROOT/scripts/lib/native-auth-pin.sh" && native_auth_pin_env &&
    # headless-claude-ok: HIMMEL-2178 probe 3e (bank-preflight gates above)
    timeout "$TIMEOUT_S" env MSYS_NO_PATHCONV=1 claude -p \
      --output-format json --permission-mode acceptEdits --allowedTools "Bash" \
      --max-turns 2 --model "$MODEL" "$@" < "$PROMPT_FILE" > "$out" 2>"$err" )
}

echo "07-settings-overlay-hooks: run 1 (control, no --settings)..."
rm -f "$BREADCRUMB"
run_claude "$OUT_DIR/run-without.json" "$OUT_DIR/run-without.err"
WITHOUT_RC=$?
WITHOUT_FIRED=0
[ -s "$BREADCRUMB" ] && WITHOUT_FIRED=1
[ -f "$BREADCRUMB" ] && mv "$BREADCRUMB" "$OUT_DIR/breadcrumb-without.txt"

echo "07-settings-overlay-hooks: run 2 (treatment, --settings $OVERLAY_FILE)..."
rm -f "$BREADCRUMB"
run_claude "$OUT_DIR/run-with.json" "$OUT_DIR/run-with.err" --settings "$OVERLAY_FILE"
WITH_RC=$?
WITH_FIRED=0
[ -s "$BREADCRUMB" ] && WITH_FIRED=1
[ -f "$BREADCRUMB" ] && mv "$BREADCRUMB" "$OUT_DIR/breadcrumb-with.txt"

# codex-1 (final round): a breadcrumb absence alone does not distinguish
# "hooks were stripped" from "the treatment run itself failed" (timeout,
# auth error, a broken --settings file) — exactly the confound class this
# probe's own methodology-correction note documents from the first pass.
# Require the treatment run's envelope to show a clean completion before
# trusting an absent breadcrumb as evidence of stripping.
WITH_RUN_OK=0
if [ -s "$OUT_DIR/run-with.json" ] && [ "$(jq -r '.is_error // "null"' "$OUT_DIR/run-with.json" 2>/dev/null)" = "false" ]; then
  WITH_RUN_OK=1
fi

echo "07-settings-overlay-hooks: control(no --settings) hook fired=$WITHOUT_FIRED rc=$WITHOUT_RC"
echo "07-settings-overlay-hooks: treatment(--settings {}) hook fired=$WITH_FIRED rc=$WITH_RC run_ok=$WITH_RUN_OK"

if [ "$WITHOUT_FIRED" -eq 1 ] && [ "$WITH_FIRED" -eq 1 ]; then
  VERDICT="INTACT — --settings overlay does not strip project PreToolUse hooks (both runs fired the breadcrumb)."
elif [ "$WITHOUT_FIRED" -eq 1 ] && [ "$WITH_FIRED" -eq 0 ] && [ "$WITH_RUN_OK" -eq 1 ]; then
  VERDICT="STRIPPED — --settings overlay drops project .claude/settings.json hooks (control fired, treatment completed cleanly but did not fire)."
elif [ "$WITHOUT_FIRED" -eq 1 ] && [ "$WITH_FIRED" -eq 0 ] && [ "$WITH_RUN_OK" -eq 0 ]; then
  VERDICT="INCONCLUSIVE — treatment run did not complete cleanly (is_error != false in run-with.json — see run-with.err/run-with.json); a failed run is not evidence of stripping, same confound class as the methodology-correction note above."
elif [ "$WITHOUT_FIRED" -eq 0 ] && [ "$WITH_FIRED" -eq 0 ]; then
  VERDICT="INCONCLUSIVE — control run never fired the hook either; the hook mechanism itself did not engage in this environment, so run 2's absence is not evidence of stripping."
else
  VERDICT="UNEXPECTED — control did not fire but treatment did; investigate before trusting either result."
fi
echo "07-settings-overlay-hooks: VERDICT: $VERDICT"

{
  echo "measured_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "without_fired: $WITHOUT_FIRED (rc=$WITHOUT_RC)"
  echo "with_fired: $WITH_FIRED (rc=$WITH_RC)"
  echo "verdict: $VERDICT"
} > "$OUT_DIR/verdict.txt"

# codex-6: INTACT/STRIPPED are valid measured answers (exit 0); INCONCLUSIVE/
# UNEXPECTED mean the probe itself did not produce a trustworthy measurement
# — exit nonzero so automated invocation can tell the two apart instead of
# reading a broken probe run as a clean pass.
case "$VERDICT" in
  INTACT*|STRIPPED*) exit 0 ;;
  *) exit 1 ;;
esac
