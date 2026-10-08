#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in the pass/fail reporting lines
# Tests for scripts/telegram/break-glass.sh and scripts/cr/cr-reset.sh
# (HIMMEL-5047): the shell half of the Telegram break-glass ops. Everything is
# a fixture: a bare origin + primary clone + linked worktree under mktemp, a
# fake HOME, and stubs for gh, systemctl, the bank preflight, the leg launcher,
# console.sh and close-wrapped-leg.sh. No real launch, merge or restart.
# BREAK_GLASS_SUT / CR_RESET_SUT override the scripts under test (RED control).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${BREAK_GLASS_SUT:-$HERE/break-glass.sh}"
AA="$HERE/auto-action.sh"
CRR="${CR_RESET_SUT:-$HERE/../cr/cr-reset.sh}"
LOCK_LIB="$HERE/../lib/shared-branch-lock.sh"

TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT
FAILED=0
assert_rc() {
    if [ "$3" = "$2" ]; then echo "PASS $1 (rc=$3)"
    else echo "FAIL $1 — expected rc=$2, got rc=$3"; cat "$TMP/err" 2>/dev/null; FAILED=$((FAILED + 1)); fi
}
assert_contains() {
    case "$3" in *"$2"*) echo "PASS $1" ;; *) echo "FAIL $1 — missing: $2"; FAILED=$((FAILED + 1)) ;; esac
}
assert_not_contains() {
    case "$3" in *"$2"*) echo "FAIL $1 — unexpectedly contains: $2"; FAILED=$((FAILED + 1)) ;; *) echo "PASS $1" ;; esac
}
# wait_for <file>: a detached launch records asynchronously; bounded at 5 s.
wait_for() { local i=0; while [ ! -s "$1" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done; }

export HOME="$TMP/home"; mkdir -p "$HOME"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q --bare -b main "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/seed" 2>/dev/null
mkdir -p "$TMP/seed/scripts/hooks"; echo v1 > "$TMP/seed/scripts/hooks/h.sh"
git -C "$TMP/seed" add -A; git -C "$TMP/seed" commit -qm "seed"; git -C "$TMP/seed" push -q origin main
git clone -q "$TMP/origin.git" "$TMP/primary"
PRIMARY="$TMP/primary"
echo v2 > "$TMP/seed/scripts/hooks/h.sh"; git -C "$TMP/seed" commit -qam "hook v2"; git -C "$TMP/seed" push -q origin main
TIP="$(git -C "$TMP/seed" rev-parse HEAD)"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
    "pr view") printf '%s\n' "${GH_VIEW:-}"; exit "${GH_VIEW_RC:-0}" ;;
    "api graphql") printf '%s\n' "${GH_REVERT_NUM:-77}"; exit 0 ;;
    "pr merge") exit "${GH_MERGE_RC:-0}" ;;
esac
exit 0
EOF
cat > "$TMP/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
exit "${SYSTEMCTL_CAT_RC:-0}"
EOF
cat > "$TMP/bin/record" <<'EOF'
#!/usr/bin/env bash
{ echo "pwd=$PWD"; echo "args=$*"; echo "bypass=${HIMMEL_HOOK_INTEGRITY_BYPASS_OK:-unset}"
  echo "other=${OTHER_GUARD_OK:-unset}"; echo "legrepo=${LEG_REPO:-unset}"; echo "token=${TELEGRAM_BOT_TOKEN:-unset}"; } > "$RECORD"
EOF
chmod +x "$TMP/bin/"*
export GH_LOG="$TMP/gh.log" BREAK_GLASS_GH="$TMP/bin/gh" BREAK_GLASS_SYSTEMCTL="$TMP/bin/systemctl"
export BREAK_GLASS_PRIMARY="$PRIMARY" BREAK_GLASS_MERGE_SLEEP=0 BREAK_GLASS_MERGE_TRIES=2
export BREAK_GLASS_BANK_CMD="echo BANK-STUB"
export OTHER_GUARD_OK=1 TELEGRAM_BOT_TOKEN=secret-token-fixture

bg() { (unset CLAUDECODE; bash "$SUT" "$@") 2>"$TMP/err"; }

# --- gate 0 and the closed op list ------------------------------------------
for op in station-status revert-main repin-hooks launch-leg cr-reset close-wrapped relaunch-console restart-bridge; do
    out=$(CLAUDECODE=1 bash "$SUT" "$op" 1 - 2>&1); rc=$?
    assert_rc "B1 $op refuses the agent marker" 19 "$rc"
done
out=$(CLAUDECODE=1 bash "$AA" repin-hooks - - 2>&1); rc=$?
assert_rc "B2 auto-action.sh routes a break-glass op to the executor (agent marker relayed)" 19 "$rc"
bg nope - - >/dev/null; assert_rc "B3 an unknown op is refused" 2 "$?"
bg station-status - >/dev/null; assert_rc "B4 a missing arg is bad input" 1 "$?"

# --- /station-status (read-only) --------------------------------------------
before="$(git -C "$PRIMARY" rev-parse HEAD)"
out=$(bg station-status - -); rc=$?
assert_rc "S1 station-status succeeds" 0 "$rc"
assert_contains "S2 it reports load" "load " "$out"
assert_contains "S3 it relays the bank preflight" "BANK-STUB" "$out"
assert_contains "S4 it reports the primary branch and cleanliness" "primary main" "$out"
assert_contains "S5 it reports the last tick age" "last tick:" "$out"
[ "$(git -C "$PRIMARY" rev-parse HEAD)" = "$before" ] && echo "PASS S6 station-status changes nothing" || { echo "FAIL S6 station-status moved the primary"; FAILED=$((FAILED + 1)); }

# --- /repin-hooks ------------------------------------------------------------
git -C "$PRIMARY" checkout -q -b side
bg repin-hooks - - >/dev/null; assert_rc "R1 primary off the default branch is left alone" 21 "$?"
git -C "$PRIMARY" checkout -q main
echo dirty >> "$PRIMARY/scripts/hooks/h.sh"
bg repin-hooks - - >/dev/null; assert_rc "R2 a primary with tracked changes is left alone" 21 "$?"
git -C "$PRIMARY" checkout -q -- scripts/hooks/h.sh
touch "$PRIMARY/untracked-note"
out=$(bg repin-hooks - -); rc=$?
assert_rc "R3 a clean primary (untracked files allowed) fast-forwards" 0 "$rc"
assert_contains "R4 it prints the new primary head" "primary=$TIP" "$out"
assert_contains "R5 the hooks on disk are the origin tip's" "v2" "$(cat "$PRIMARY/scripts/hooks/h.sh")"
echo local > "$PRIMARY/local.txt"; git -C "$PRIMARY" add local.txt; git -C "$PRIMARY" commit -qm local
bg repin-hooks - - >/dev/null; assert_rc "R6 a diverged primary is left alone" 22 "$?"
git -C "$PRIMARY" reset -q --hard "$TIP"

# --- /revert-main ------------------------------------------------------------
: > "$GH_LOG"
GH_VIEW='{"id":"PR_1","state":"OPEN","baseRefName":"main"}' bg revert-main 12 - >/dev/null
assert_rc "V1 an unmerged PR is refused" 12 "$?"
GH_VIEW='{"id":"PR_1","state":"MERGED","baseRefName":"dev"}' bg revert-main 12 - >/dev/null
assert_rc "V2 a PR merged into another branch is refused" 12 "$?"
assert_not_contains "V3 a refused revert never calls the revert mutation" "graphql" "$(cat "$GH_LOG")"
GH_VIEW_RC=1 bg revert-main 12 - >/dev/null; assert_rc "V4 a gh failure is rc 13" 13 "$?"
bg revert-main 12x - >/dev/null; assert_rc "V5 a non-numeric PR is bad input" 1 "$?"
GH_VIEW='{"id":"PR_1","state":"MERGED","baseRefName":"main"}' GH_MERGE_RC=1 bg revert-main 12 - >/dev/null
assert_rc "V6 a revert PR that will not merge is rc 18 (left open)" 18 "$?"
: > "$GH_LOG"
out=$(GH_VIEW='{"id":"PR_1","state":"MERGED","baseRefName":"main"}' bg revert-main 12 -); rc=$?
assert_rc "V7 a merged PR is reverted, merged and the primary synced" 0 "$rc"
assert_contains "V8 it names the revert PR" "revert_pr=77" "$out"
assert_contains "V9 the merge is --admin squash (break-glass)" "pr merge 77 --squash --admin" "$(cat "$GH_LOG")"
assert_contains "V10 the primary sync ran after the merge" "primary=" "$out"

# --- /launch-leg -------------------------------------------------------------
git -C "$PRIMARY" worktree add -q "$TMP/wt" -b feat/leg-x
BUCKET="$TMP/bucket"; mkdir -p "$BUCKET"
FLEET="$BUCKET/HIMMEL-nextleg-2026-10-09ZZ-roadmap-console.fleet.json"
mkleg() { printf -- '---\nresume_cwd: %s\n---\n\n# HIMMEL-1 — x — leg %s (claude-opus-5-5, native), 2026-10-09\n' "$2" "$1" > "$BUCKET/HIMMEL-1-$1-x-2026-10-09.md"; }
mkleg N7 "$TMP/wt"; mkleg N8 "$TMP/gone"; mkleg N9 "$PRIMARY"
cat > "$FLEET" <<EOF
{"schema":1,"legs":[
 {"doc":"$BUCKET/HIMMEL-1-N7-x-2026-10-09.md","label":"N7"},
 {"doc":"$BUCKET/HIMMEL-1-N8-x-2026-10-09.md","label":"N8"},
 {"doc":"$BUCKET/HIMMEL-1-N9-x-2026-10-09.md","label":"N9"},
 {"doc":"$BUCKET/a.md","label":"N5"},{"doc":"$BUCKET/b.md","label":"N5"}]}
EOF
export BREAK_GLASS_FLEET="$FLEET" BREAK_GLASS_LEG_CMD="$TMP/bin/record" RECORD="$TMP/leg.rec"
rm -f "$RECORD"; out=$(bg launch-leg N7 bypass); rc=$?
assert_rc "L1 a manifest leg with a linked worktree launches" 0 "$rc"
wait_for "$RECORD"; rec="$(cat "$RECORD" 2>/dev/null)"
assert_contains "L2 the bypass exports HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1" "bypass=1" "$rec"
assert_contains "L3 every other *_OK is scrubbed" "other=unset" "$rec"
assert_contains "L4 the bot token is scrubbed" "token=unset" "$rec"
assert_contains "L5 it launches in the leg's own worktree" "legrepo=$TMP/wt" "$rec"
assert_contains "L6 with the doc's model, session name and fleet/console" "--fleet $FLEET --console HIMMEL-nextleg-2026-10-09ZZ-roadmap-console HIMMEL-1-N7-x-2026-10-09 $BUCKET/HIMMEL-1-N7-x-2026-10-09.md" "$rec"
assert_contains "L7 and the model named in the doc" "claude-opus-5-5" "$rec"
rm -f "$RECORD"; bg launch-leg N7 - >/dev/null; wait_for "$RECORD"
assert_contains "L8 without --hook-bypass nothing is exported" "bypass=unset" "$(cat "$RECORD" 2>/dev/null)"
bg launch-leg N8 bypass >/dev/null; assert_rc "L9 a leg whose worktree is gone is refused" 23 "$?"
bg launch-leg N9 bypass >/dev/null; assert_rc "L10 the primary (not a linked worktree) is refused" 23 "$?"
bg launch-leg N5 bypass >/dev/null; assert_rc "L11 a label naming two legs is refused" 23 "$?"
bg launch-leg N4 bypass >/dev/null; assert_rc "L12 an unknown label with no launcher is refused" 23 "$?"
bg launch-leg 'N7;x' bypass >/dev/null; assert_rc "L13 a malformed label is bad input" 1 "$?"
bg launch-leg N7 yes >/dev/null; assert_rc "L14 a bad bypass flag is bad input" 1 "$?"
# fresh start from a console-written launcher
cat > "$BUCKET/launch-N6.sh" <<EOF
#!/usr/bin/env bash
RECORD="$TMP/launcher.rec" "$TMP/bin/record"
EOF
SIDECAR="${FLEET%.json}.launchers.sha256"
bg launch-leg N6 bypass >/dev/null; assert_rc "L15 a launcher with no recorded sha256 is refused" 23 "$?"
sha256sum "$BUCKET/launch-N6.sh" > "$SIDECAR"
rm -f "$TMP/launcher.rec"; out=$(bg launch-leg N6 bypass); rc=$?
assert_rc "L16 a launcher matching its recorded sha256 starts" 0 "$rc"
wait_for "$TMP/launcher.rec"; rec="$(cat "$TMP/launcher.rec" 2>/dev/null)"
assert_contains "L17 the launcher gets only the hook-integrity bypass" "bypass=1" "$rec"
assert_contains "L18 and no other *_OK" "other=unset" "$rec"
echo "# tampered" >> "$BUCKET/launch-N6.sh"
bg launch-leg N6 bypass >/dev/null; assert_rc "L19 a launcher edited after the console recorded it is refused" 23 "$?"
unset BREAK_GLASS_LEG_CMD

# --- /close-wrapped ------------------------------------------------------------
cat > "$TMP/bin/closer" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CLOSE_LOG"
case "$3" in *N7*) exit 0 ;; *) echo "refusing: last marker is LIVE" >&2; exit 3 ;; esac
EOF
chmod +x "$TMP/bin/closer"
export BREAK_GLASS_CLOSE_CMD="$TMP/bin/closer" CLOSE_LOG="$TMP/close.log"
out=$(bg close-wrapped - -); rc=$?
assert_rc "C1 close-wrapped over the fleet succeeds even when some legs refuse" 0 "$rc"
assert_contains "C2 it closes the wrapped leg" "closed HIMMEL-1-N7-x-2026-10-09.md" "$out"
assert_contains "C3 and counts the rest as left" "closed=1 left=4" "$out"
assert_contains "C4 each close goes through close-wrapped-leg.sh --fleet" "--fleet $FLEET $BUCKET/HIMMEL-1-N8-x-2026-10-09.md" "$(cat "$CLOSE_LOG")"
out=$(bg close-wrapped N8 -); rc=$?
assert_rc "C5 a named leg that is not wrapped is refused" 1 "$rc"
assert_contains "C6 with the closer's reason" "last marker is LIVE" "$out"
bg close-wrapped N5 - >/dev/null; assert_rc "C7 a label naming two legs is refused" 23 "$?"
bg close-wrapped N7 - >/dev/null; assert_rc "C8 a named wrapped leg closes" 0 "$?"

# --- /relaunch-console -------------------------------------------------------
export BREAK_GLASS_CONSOLE_CMD="$TMP/bin/record" RECORD="$TMP/console.rec"
out=$(bg relaunch-console roadmap-console -); rc=$?
assert_rc "K1 relaunch-console runs console.sh next" 0 "$rc"
rec="$(cat "$RECORD" 2>/dev/null)"
assert_contains "K2 with --arm and the console name" "args=next --arm --name roadmap-console" "$rec"
assert_contains "K3 from the primary" "pwd=$PRIMARY" "$rec"
assert_contains "K4 with no hook-integrity bypass" "bypass=unset" "$rec"
assert_contains "K5 and every *_OK scrubbed" "other=unset" "$rec"
bg relaunch-console - - >/dev/null
assert_contains "K6 the default name is console" "--name console" "$(cat "$RECORD")"
bg relaunch-console 'Bad;Name' - >/dev/null; assert_rc "K7 a bad console name is bad input" 1 "$?"

# --- /restart-bridge -----------------------------------------------------------
export BREAK_GLASS_RESTART_CMD="$TMP/bin/record" RECORD="$TMP/restart.rec"
out=$(bg restart-bridge - -); rc=$?
assert_rc "X1 restart-bridge schedules the restart" 0 "$rc"
[ -s "$RECORD" ] && echo "PASS X2 the restart command ran" || { echo "FAIL X2 restart command not run"; FAILED=$((FAILED + 1)); }
SYSTEMCTL_CAT_RC=1 bg restart-bridge - - >/dev/null; assert_rc "X3 a missing unit is rc 20" 20 "$?"

# --- cr-reset.sh -----------------------------------------------------------------
crr() { (unset CLAUDECODE; CR_RESET_PRIMARY="$PRIMARY" CR_RESET_GH="$TMP/bin/gh" CR_RESET_LOCK_LIB="$LOCK_LIB" bash "$CRR" "$@") 2>"$TMP/err"; }
STATE="$PRIMARY/.git/cr-review-rounds"; mkdir -p "$STATE/feat"
echo 3 > "$STATE/feat/leg-x.round"; echo abc > "$STATE/feat/leg-x.head"; echo "a b c" > "$STATE/feat/leg-x.delta"
out=$(CLAUDECODE=1 bash "$CRR" 5 2>&1); rc=$?
assert_rc "Z1 cr-reset refuses the agent marker" 19 "$rc"
GH_VIEW='{"headRefName":"feat/leg-x","isCrossRepository":true,"state":"OPEN"}' crr 5 >/dev/null
assert_rc "Z2 a fork PR is refused" 12 "$?"
GH_VIEW='{"headRefName":"feat/leg-x","isCrossRepository":false,"state":"MERGED"}' crr 5 >/dev/null
assert_rc "Z3 a closed PR is refused" 12 "$?"
GH_VIEW='{"headRefName":"feat/unmapped","isCrossRepository":false,"state":"OPEN"}' crr 5 >/dev/null
assert_rc "Z4 a branch with no review-round state is refused" 12 "$?"
crr 5x >/dev/null; assert_rc "Z5 a non-numeric PR is bad input" 1 "$?"
[ -f "$STATE/feat/leg-x.round" ] && echo "PASS Z6 refusals leave the counters alone" || { echo "FAIL Z6 counters touched"; FAILED=$((FAILED + 1)); }
out=$(GH_VIEW='{"headRefName":"feat/leg-x","isCrossRepository":false,"state":"OPEN"}' crr 5); rc=$?
assert_rc "Z7 an open same-repo PR with state is reset" 0 "$rc"
[ ! -e "$STATE/feat/leg-x.round" ] && [ ! -e "$STATE/feat/leg-x.head" ] && [ ! -e "$STATE/feat/leg-x.delta" ] \
    && echo "PASS Z8 .round/.head/.delta are reset" || { echo "FAIL Z8 counters not reset"; FAILED=$((FAILED + 1)); }
assert_contains "Z9 the old round is backed up with a timestamp suffix" "3" "$(cat "$STATE"/feat/leg-x.round.bak-* 2>/dev/null)"
out=$(GH_VIEW='{"headRefName":"feat/leg-x","isCrossRepository":false,"state":"OPEN"}' BREAK_GLASS_CR_RESET="$CRR" CR_RESET_PRIMARY="$PRIMARY" CR_RESET_GH="$TMP/bin/gh" CR_RESET_LOCK_LIB="$LOCK_LIB" bg cr-reset 5 -); rc=$?
assert_rc "Z10 break-glass cr-reset relays cr-reset.sh (nothing left to reset)" 12 "$rc"

git -C "$PRIMARY" worktree remove --force "$TMP/wt" 2>/dev/null
echo
if [ "$FAILED" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILED FAILED"; exit 1; fi
