#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # SC2015: A && B || C is intentional in check(), as in test-headed-arm-leg.sh; SC2016: group 10 greps literal $VAR text
# scripts/handover/console-kit/test-leg-pretrust.sh - suite for leg-pretrust.sh
# (HIMMEL-5056): the launcher's folder/hooks-trust pre-accept.
#
# Asserts:
#   1. a fresh linked worktree has NO trust entry before and an accepted one
#      after; unrelated keys and other projects survive verbatim.
#   2. a path under $HOME/.himmel/eval/ qualifies.
#   3. refusals (exit 3, config never created): $HOME, /, the primary checkout,
#      /tmp-style dirs, a worktree NOT under .claude/worktrees/, the eval root
#      itself.
#   4. each lane writes the config file its claude reads.
#   5. concurrent writers lose no keys.
#   6. an unparseable config is refused (exit 4) and left byte-identical.
#   7. (HIMMEL-5068) the lock is claude's own <cfg>.lock dir (proper-lockfile: mkdir,
#      stale after 10 s): a live claude's lock is waited on, a stale one is reclaimed
#      unless OUR sidecar owner is still alive.
#   8. a resolved path with a newline in its name is refused; non-object projects /
#      projects[key] are refused byte-identical; a symlinked config is written
#      through (link kept); the file mode is kept as found (new file 0600).
# Everything runs under LEG_PRETRUST_HOME in a temp dir; the real ~/.claude.json
# is never touched.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/leg-pretrust.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/leg-pretrust-test.XXXXXX")" || { echo "FAIL: mktemp" >&2; exit 1; }
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
fails=0
check() { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }

export LEG_PRETRUST_HOME="$tmp/home"
mkdir -p "$LEG_PRETRUST_HOME"
cfg="$LEG_PRETRUST_HOME/.claude.json"
trusted() { jq -r --arg k "$2" '.projects[$k].hasTrustDialogAccepted // "absent"' "$1" 2>/dev/null || echo "nofile"; }

primary="$tmp/primary"
git init -q "$primary"
git -C "$primary" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
mkdir -p "$primary/.claude/worktrees"
git -C "$primary" worktree add -q -b wt1 "$primary/.claude/worktrees/wt1"
git -C "$primary" worktree add -q -b wt-out "$tmp/outside-wt"

# 1. RED shape: no entry before, accepted after, other keys preserved.
printf '%s' '{"numStartups":7,"projects":{"/other":{"allowedTools":["x"],"hasTrustDialogAccepted":false}}}' > "$cfg"
check "1a fresh worktree: no trust entry before" "$(trusted "$cfg" "$primary/.claude/worktrees/wt1")" "absent"
rc=0; bash "$SCRIPT" native "$primary/.claude/worktrees/wt1" >/dev/null 2>&1 || rc=$?
check "1b worktree: exit 0" "$rc" "0"
check "1c worktree: trust accepted after" "$(trusted "$cfg" "$primary/.claude/worktrees/wt1")" "true"
check "1d unrelated top-level key preserved" "$(jq -r .numStartups "$cfg")" "7"
check "1e other project untouched" "$(jq -c '.projects["/other"]' "$cfg")" '{"allowedTools":["x"],"hasTrustDialogAccepted":false}'
rc=0; bash "$SCRIPT" native "$primary/.claude/worktrees/wt1" >/dev/null 2>&1 || rc=$?
check "1f idempotent: second run exit 0" "$rc" "0"

# 2. eval clone path.
mkdir -p "$LEG_PRETRUST_HOME/.himmel/eval/lane-quality/pilot/wt/p01"
rc=0; bash "$SCRIPT" native "$LEG_PRETRUST_HOME/.himmel/eval/lane-quality/pilot/wt/p01" >/dev/null 2>&1 || rc=$?
check "2a eval clone: exit 0" "$rc" "0"
check "2b eval clone: trusted" "$(trusted "$cfg" "$LEG_PRETRUST_HOME/.himmel/eval/lane-quality/pilot/wt/p01")" "true"

# 3. refusals write nothing.
rm -f "$cfg"
mkdir -p "$tmp/scratch-dir" "$LEG_PRETRUST_HOME/.himmel/eval"
for bad in "$LEG_PRETRUST_HOME" / "$primary" "$tmp/scratch-dir" "$tmp/outside-wt" "$LEG_PRETRUST_HOME/.himmel/eval" "$primary/.claude/worktrees"; do
  rc=0; bash "$SCRIPT" native "$bad" >/dev/null 2>&1 || rc=$?
  check "3 refused ($bad): exit 3" "$rc" "3"
  check "3 refused ($bad): no config written" "$([ -e "$cfg" ] && echo yes || echo no)" "no"
done
# a symlink under the eval root pointing outside must not launder a path
ln -s "$tmp/scratch-dir" "$LEG_PRETRUST_HOME/.himmel/eval/link"
rc=0; bash "$SCRIPT" native "$LEG_PRETRUST_HOME/.himmel/eval/link" >/dev/null 2>&1 || rc=$?
check "3 refused (symlink out of eval root): exit 3" "$rc" "3"

# 4. lanes (the lane launcher owns its config dir; the helper never creates one).
rc=0; bash "$SCRIPT" deepseek "$primary/.claude/worktrees/wt1" >/dev/null 2>&1 || rc=$?
check "4 absent lane dir: exit 4, dir not created" "$rc$([ -d "$LEG_PRETRUST_HOME/.claude-deepseek" ] && echo made)" "4"
mkdir -p "$LEG_PRETRUST_HOME/.claude-codex" "$LEG_PRETRUST_HOME/.claude-openrouter" "$LEG_PRETRUST_HOME/.claude-deepseek"
for pair in "claudex:.claude-codex" "openrouter:.claude-openrouter" "deepseek:.claude-deepseek"; do
  lane="${pair%%:*}"; sub="${pair#*:}"
  rc=0; bash "$SCRIPT" "$lane" "$primary/.claude/worktrees/wt1" >/dev/null 2>&1 || rc=$?
  check "4 lane $lane: exit 0" "$rc" "0"
  check "4 lane $lane: writes its own config" "$(trusted "$LEG_PRETRUST_HOME/$sub/.claude.json" "$primary/.claude/worktrees/wt1")" "true"
done
rc=0; bash "$SCRIPT" glm "$primary/.claude/worktrees/wt1" >/dev/null 2>&1 || rc=$?
check "4 unknown lane: exit 2" "$rc" "2"

# 5. concurrent writers lose nothing.
rm -f "$cfg"
printf '%s' '{"keep":"me","projects":{"/pre":{"hasTrustDialogAccepted":true}}}' > "$cfg"
n=12
for i in $(seq 1 $n); do git -C "$primary" worktree add -q -b "c$i" "$primary/.claude/worktrees/c$i"; done
for i in $(seq 1 $n); do bash "$SCRIPT" native "$primary/.claude/worktrees/c$i" >/dev/null 2>&1 & done
wait
got=0
for i in $(seq 1 $n); do [ "$(trusted "$cfg" "$primary/.claude/worktrees/c$i")" = "true" ] && got=$((got+1)); done
check "5a concurrent: all $n entries present" "$got" "$n"
check "5b concurrent: pre-existing project kept" "$(trusted "$cfg" /pre)" "true"
check "5c concurrent: top-level key kept" "$(jq -r .keep "$cfg")" "me"
check "5d concurrent: lock released" "$([ -e "$cfg.lock" ] && echo held || echo free)" "free"

# 6. unparseable config is never clobbered.
printf '%s' '{"projects": {oops' > "$cfg"
before="$(cksum < "$cfg")"
rc=0; bash "$SCRIPT" native "$primary/.claude/worktrees/wt1" >/dev/null 2>&1 || rc=$?
check "6a unparseable config: exit 4" "$rc" "4"
check "6b unparseable config: byte-identical" "$(cksum < "$cfg")" "$before"
check "6c unparseable config: lock released" "$([ -e "$cfg.lock" ] && echo held || echo free)" "free"

# 7. claude's own <cfg>.lock (HIMMEL-5068).
rm -f "$cfg"; printf '%s' '{"keep":"me"}' > "$cfg"
mkdir "$cfg.lock"   # a live claude mid-save holds this (fresh mtime)
bash "$SCRIPT" native "$primary/.claude/worktrees/wt1" >/dev/null 2>&1 & pid=$!
sleep 1
check "7a claude's lock held: pretrust waits, writes nothing" "$(trusted "$cfg" "$primary/.claude/worktrees/wt1")" "absent"
rmdir "$cfg.lock"; wait "$pid"
check "7b claude's lock released: pretrust lands" "$(trusted "$cfg" "$primary/.claude/worktrees/wt1")" "true"
check "7c lock released afterwards" "$([ -e "$cfg.lock" ] && echo held || echo free)" "free"
deadpid="$(bash -c 'echo $$')"
stale_lock() { rm -rf "$cfg.lock" "$cfg.leg-pretrust.owner"; mkdir "$cfg.lock"; touch -t 200001010000 "$cfg.lock"; }
printf '%s' '{"keep":"me"}' > "$cfg"
stale_lock
rc=0; bash "$SCRIPT" native "$primary/.claude/worktrees/wt1" >/dev/null 2>&1 || rc=$?
check "7d stale lock, no sidecar owner (dead claude): reclaimed" "$rc" "0"
printf '%s' '{"keep":"me"}' > "$cfg"
stale_lock; echo "$deadpid" > "$cfg.leg-pretrust.owner"
rc=0; bash "$SCRIPT" native "$primary/.claude/worktrees/wt1" >/dev/null 2>&1 || rc=$?
check "7e stale lock, dead owner: reclaimed" "$rc" "0"
printf '%s' '{"keep":"me"}' > "$cfg"
stale_lock; echo "$$" > "$cfg.leg-pretrust.owner"
rc=0; export LEG_PRETRUST_LOCK_TRIES=15; bash "$SCRIPT" native "$primary/.claude/worktrees/wt1" >/dev/null 2>&1 || rc=$?; unset LEG_PRETRUST_LOCK_TRIES
check "7f stale lock, LIVE owner: not reclaimed (exit 5)" "$rc" "5"
check "7g live owner's lock left in place" "$([ -d "$cfg.lock" ] && echo held || echo free)" "held"
check "7h nothing written" "$(trusted "$cfg" "$primary/.claude/worktrees/wt1")" "absent"
rm -rf "$cfg.lock" "$cfg.leg-pretrust.owner"
# a stale lock that cannot be removed (read-only config dir) must time out, not spin
printf '%s' '{"keep":"me"}' > "$cfg"
stale_lock; chmod 555 "$(dirname "$cfg")"
rc=0; export LEG_PRETRUST_LOCK_TRIES=15; timeout 20 bash "$SCRIPT" native "$primary/.claude/worktrees/wt1" >/dev/null 2>&1 || rc=$?; unset LEG_PRETRUST_LOCK_TRIES
chmod 755 "$(dirname "$cfg")"
check "7i stale lock that cannot be removed: exit 5, no busy loop" "$rc" "5"
rm -rf "$cfg.lock" "$cfg.leg-pretrust.owner"

# 8. odd shapes.
nl="$LEG_PRETRUST_HOME/.himmel/eval/nl"$'\n'
mkdir -p "$nl"; rm -f "$cfg"
rc=0; bash "$SCRIPT" native "$nl" >/dev/null 2>&1 || rc=$?
check "8a newline in resolved path: exit 3" "$rc" "3"
check "8b newline in resolved path: no config written" "$([ -e "$cfg" ] && echo yes || echo no)" "no"
for shape in '{"projects":[1]}' '{"projects":"x"}' "{\"projects\":{\"$primary/.claude/worktrees/wt1\":5}}"; do
  printf '%s' "$shape" > "$cfg"; before="$(cksum < "$cfg")"
  rc=0; bash "$SCRIPT" native "$primary/.claude/worktrees/wt1" >/dev/null 2>&1 || rc=$?
  check "8c non-object shape $shape: exit 4" "$rc" "4"
  check "8c non-object shape $shape: byte-identical" "$(cksum < "$cfg")" "$before"
done
real="$tmp/real-claude.json"; printf '%s' '{"keep":"me"}' > "$real"; rm -f "$cfg"; ln -s "$real" "$cfg"
rc=0; bash "$SCRIPT" native "$primary/.claude/worktrees/wt1" >/dev/null 2>&1 || rc=$?
check "8d symlinked config: exit 0" "$rc" "0"
check "8d symlinked config: link kept" "$([ -L "$cfg" ] && echo link || echo replaced)" "link"
check "8d symlinked config: target written" "$(trusted "$real" "$primary/.claude/worktrees/wt1")" "true"
rm -f "$cfg"; printf '%s' '{"keep":"me"}' > "$cfg"; chmod 644 "$cfg"
bash "$SCRIPT" native "$primary/.claude/worktrees/wt1" >/dev/null 2>&1
check "8e existing mode 0644 kept" "$(stat -c %a "$cfg" 2>/dev/null || stat -f %Lp "$cfg")" "644"
rm -f "$cfg"
bash "$SCRIPT" native "$primary/.claude/worktrees/wt1" >/dev/null 2>&1
check "8f new file is 0600" "$(stat -c %a "$cfg" 2>/dev/null || stat -f %Lp "$cfg")" "600"

# 9. (HIMMEL-5068, pilot p20) a jailed row: claude sees the worktree at another path
# and a per-row copy of the lane config, so the flag goes to THAT file under THAT key.
rm -f "$cfg" "$LEG_PRETRUST_HOME/.claude-deepseek/.claude.json"
mkdir -p "$LEG_PRETRUST_HOME/.claude-deepseek" "$tmp/rowconf"
printf '%s' '{"projects":{"/repo":{"hasTrustDialogAccepted":true}}}' > "$tmp/rowconf/.claude.json"
mkdir -p "$LEG_PRETRUST_HOME/.himmel/eval/lane-quality/pilot/wt/lq-p20"
jkey="/jail/repo/.claude/worktrees/lq-p20"
rc=0; LEG_PRETRUST_CONFIG="$tmp/rowconf/.claude.json" LEG_PRETRUST_KEY="$jkey" bash "$SCRIPT" deepseek "$LEG_PRETRUST_HOME/.himmel/eval/lane-quality/pilot/wt/lq-p20" >/dev/null 2>&1 || rc=$?
check "9a jail key + row config: exit 0" "$rc" "0"
check "9b jail key trusted in the row config" "$(trusted "$tmp/rowconf/.claude.json" "$jkey")" "true"
check "9c row config keeps its other project" "$(trusted "$tmp/rowconf/.claude.json" "/repo")" "true"
check "9d real lane config not created" "$([ -e "$LEG_PRETRUST_HOME/.claude-deepseek/.claude.json" ] && echo yes || echo no)" "no"
for badkey in "relative/lq-p20" "/jail/other-name" "/jail/../x/lq-p20"; do
  rc=0; LEG_PRETRUST_CONFIG="$tmp/rowconf/.claude.json" LEG_PRETRUST_KEY="$badkey" bash "$SCRIPT" deepseek "$LEG_PRETRUST_HOME/.himmel/eval/lane-quality/pilot/wt/lq-p20" >/dev/null 2>&1 || rc=$?
  check "9e bad key $badkey: exit 3" "$rc" "3"
done
rc=0; LEG_PRETRUST_CONFIG="relative.json" bash "$SCRIPT" deepseek "$LEG_PRETRUST_HOME/.himmel/eval/lane-quality/pilot/wt/lq-p20" >/dev/null 2>&1 || rc=$?
check "9f relative config path: exit 2" "$rc" "2"
rc=0; LEG_PRETRUST_KEY="$jkey" bash "$SCRIPT" deepseek /tmp >/dev/null 2>&1 || rc=$?
check "9g key override does not widen the dir check: exit 3" "$rc" "3"

# 10. the pilot jail launcher seeds exactly its own jail key into exactly its row config.
sb="$HERE/../../eval/lane-quality/pilot-4869/sandbox.sh"
check "10a sandbox.sh launch seeds \$JWT into \$ROWCONF" "$(grep -c 'LEG_PRETRUST_CONFIG="$ROWCONF/.claude.json" LEG_PRETRUST_KEY="$JWT"' "$sb")" "1"
check "10b only one pretrust call in sandbox.sh" "$(grep -c 'leg-pretrust.sh' "$sb")" "1"

# 11. (HIMMEL-5068, judge j2228a B1) the jail can write the row's config dir, so in seam
# mode a symlinked config, sidecar or lock is refused (exit 3) and nothing outside is touched.
ewt="$LEG_PRETRUST_HOME/.himmel/eval/lane-quality/pilot/wt/lq-p20"
jc="$tmp/jailconf"; vic="$tmp/victim"; rm -rf "$jc" "$vic"; mkdir -p "$jc" "$vic"
vsum() { cat "$vic/v.json" "$vic/v.txt" 2>/dev/null | cksum; }
printf '%s' '{"keep":"me"}' > "$vic/v.json"; printf 'precious\n' > "$vic/v.txt"; want="$(vsum)"
ln -s "$vic/v.json" "$jc/.claude.json"
rc=0; LEG_PRETRUST_CONFIG="$jc/.claude.json" LEG_PRETRUST_KEY="$jkey" bash "$SCRIPT" deepseek "$ewt" >/dev/null 2>&1 || rc=$?
check "11a seam + symlinked config: exit 3" "$rc" "3"
check "11a victim untouched" "$(vsum)" "$want"
rm -f "$jc/.claude.json"; printf '%s' '{}' > "$jc/.claude.json"; ln -s "$vic/v.txt" "$jc/.claude.json.leg-pretrust.owner"
rc=0; LEG_PRETRUST_CONFIG="$jc/.claude.json" LEG_PRETRUST_KEY="$jkey" bash "$SCRIPT" deepseek "$ewt" >/dev/null 2>&1 || rc=$?
check "11b seam + symlinked sidecar: exit 3" "$rc" "3"
check "11b victim untouched" "$(vsum)" "$want"
rm -f "$jc/.claude.json.leg-pretrust.owner"; ln -s "$vic" "$jc/.claude.json.lock"
rc=0; LEG_PRETRUST_CONFIG="$jc/.claude.json" LEG_PRETRUST_KEY="$jkey" bash "$SCRIPT" deepseek "$ewt" >/dev/null 2>&1 || rc=$?
check "11c seam + symlinked lock: exit 3" "$rc" "3"
rm -f "$jc/.claude.json.lock"
rc=0; LEG_PRETRUST_KEY="$jkey" bash "$SCRIPT" deepseek "$ewt" >/dev/null 2>&1 || rc=$?
check "11d key without config: exit 3" "$rc" "3"
rm -f "$LEG_PRETRUST_HOME/.claude-deepseek/.claude.json"
rc=0; LEG_PRETRUST_CONFIG="$LEG_PRETRUST_HOME/.claude-deepseek/.claude.json" LEG_PRETRUST_KEY="$jkey" bash "$SCRIPT" deepseek "$ewt" >/dev/null 2>&1 || rc=$?
check "11e config is a real lane config: exit 3" "$rc" "3"
check "11e real lane config not created" "$([ -e "$LEG_PRETRUST_HOME/.claude-deepseek/.claude.json" ] && echo yes || echo no)" "no"
for badkey in "/../x/.claude/worktrees/lq-p20" "//x/.claude/worktrees/lq-p20" "/./x/.claude/worktrees/lq-p20" "/x/./.claude/worktrees/lq-p20" "/x/.claude/worktrees/lq-p20/" "$LEG_PRETRUST_HOME/lq-p20"; do
  rc=0; LEG_PRETRUST_CONFIG="$jc/.claude.json" LEG_PRETRUST_KEY="$badkey" bash "$SCRIPT" deepseek "$ewt" >/dev/null 2>&1 || rc=$?
  check "11f bad key $badkey: exit 3" "$rc" "3"
done
# the happy path still works in the same dir, and a stale sidecar symlink is never written through
printf '%s' '{}' > "$jc/.claude.json"
rc=0; LEG_PRETRUST_CONFIG="$jc/.claude.json" LEG_PRETRUST_KEY="$jkey" bash "$SCRIPT" deepseek "$ewt" >/dev/null 2>&1 || rc=$?
check "11g seam happy path: exit 0" "$rc" "0"
check "11g trusted" "$(trusted "$jc/.claude.json" "$jkey")" "true"
rm -f "$cfg"; printf '%s' '{}' > "$cfg"; ln -s "$vic/v.txt" "$cfg.leg-pretrust.owner"
rc=0; bash "$SCRIPT" native "$primary/.claude/worktrees/wt1" >/dev/null 2>&1 || rc=$?
check "11h native + symlinked sidecar: exit 0" "$rc" "0"
check "11h victim untouched" "$(vsum)" "$want"
rm -f "$cfg.leg-pretrust.owner"

echo "---"
if [ "$fails" -eq 0 ]; then echo "PASS - test-leg-pretrust.sh"; exit 0; fi
echo "FAIL - test-leg-pretrust.sh ($fails failure(s))"; exit 1
