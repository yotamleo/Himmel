#!/usr/bin/env bash
# macos-lane.sh — HIMMEL-4980. Console-owned local macOS test lane over
# sickcodes/docker-osx (naked image, SSH-only). Plan + cost + EULA note:
# docs/internals/macos-local-lane.md.
#
# Subcommands: start | wait-ssh | sync-worktree <dir> | run-suites <suite>...
#              | fetch-results <dest> | stop | plan
#
# SAFETY: refuses to run unless HIMMEL_MACOS_LANE_OK=1 is set in the
# launching shell. Never reads or writes the real HOME or handover state:
# ssh runs with -F /dev/null and a lane-private key + known_hosts, all state
# lives under HIMMEL_MACOS_LANE_DIR. Every external call is bounded by
# `timeout`. DOCKER / SSH / RSYNC / TIMEOUT_BIN are overridable so the dry-run
# test (test-macos-lane.sh) can stub them.
#
# Bash 3.2-safe on purpose (no mapfile, no assoc arrays).
set -uo pipefail

if [ "${HIMMEL_MACOS_LANE_OK:-}" != "1" ]; then
  echo "macos-lane: refusing to run — set HIMMEL_MACOS_LANE_OK=1 in the launching shell (operator go required, HIMMEL-4980)" >&2
  exit 2
fi

DOCKER="${DOCKER:-docker}"
SSH="${SSH:-ssh}"
RSYNC="${RSYNC:-rsync}"
TIMEOUT_BIN="${TIMEOUT_BIN:-timeout}"

LANE_DIR="${HIMMEL_MACOS_LANE_DIR:-${TMPDIR:-/tmp}/himmel-macos-lane}"
NAME="${HIMMEL_MACOS_LANE_NAME:-himmel-macos-lane}"
IMAGE="${HIMMEL_MACOS_LANE_IMAGE:-sickcodes/docker-osx:naked-auto}"
DISK="${HIMMEL_MACOS_LANE_DISK:-$LANE_DIR/mac_hdd_ng.img}"
SSH_PORT="${HIMMEL_MACOS_LANE_PORT:-50922}"
SSH_USER="${HIMMEL_MACOS_LANE_USER:-user}"
RAM_GB="${HIMMEL_MACOS_LANE_RAM_GB:-8}"
CPUS="${HIMMEL_MACOS_LANE_CPUS:-4}"
KEY="${HIMMEL_MACOS_LANE_KEY:-$LANE_DIR/id_ed25519}"
REMOTE_DIR="himmel-work"
REMOTE_RESULTS="himmel-results"
T_START="${HIMMEL_MACOS_LANE_T_START:-120}"
T_BOOT="${HIMMEL_MACOS_LANE_T_BOOT:-600}"
T_SYNC="${HIMMEL_MACOS_LANE_T_SYNC:-300}"
T_SUITE="${HIMMEL_MACOS_LANE_T_SUITE:-900}"
T_FETCH="${HIMMEL_MACOS_LANE_T_FETCH:-120}"
T_STOP="${HIMMEL_MACOS_LANE_T_STOP:-60}"

die() { echo "macos-lane: $*" >&2; exit 1; }

mkdir -p "$LANE_DIR" || die "cannot create $LANE_DIR"

# ssh opts as a string so rsync -e can reuse it; no operator ssh config, no real HOME.
ssh_opts() {
  printf '%s' "-F /dev/null -i $KEY -p $SSH_PORT -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$LANE_DIR/known_hosts"
}

remote() { # remote <seconds> <command>
  local secs="$1"; shift
  # shellcheck disable=SC2046  # ssh_opts is a deliberate word-split option string
  "$TIMEOUT_BIN" "$secs" "$SSH" $(ssh_opts) "$SSH_USER@127.0.0.1" "$@"
}

cmd_plan() {
  echo "image=$IMAGE disk=$DISK port=127.0.0.1:$SSH_PORT ram=${RAM_GB}G cpus=$CPUS lane_dir=$LANE_DIR"
}

cmd_start() {
  [ -f "$DISK" ] || die "no persistent disk at $DISK — run the one-time setup in docs/internals/macos-local-lane.md first"
  "$TIMEOUT_BIN" "$T_START" "$DOCKER" run -d --name "$NAME" \
    --device /dev/kvm \
    --memory "$((10#$RAM_GB + 2))g" --cpus "$CPUS" --pids-limit 4096 \
    -p "127.0.0.1:$SSH_PORT:10022" \
    -v "$DISK:/image" \
    -e IMAGE_PATH=/image -e NOPICKER=true \
    -e "RAM=$RAM_GB" -e "CPUS=$CPUS" -e "SMP=$CPUS" -e "CORES=$CPUS" \
    "$IMAGE" || die "docker run failed"
}

cmd_wait_ssh() {
  local deadline now
  deadline=$(( $(date +%s) + T_BOOT ))
  while :; do
    if remote 15 true >/dev/null 2>&1; then echo "macos-lane: ssh up"; return 0; fi
    now=$(date +%s)
    [ "$now" -lt "$deadline" ] || die "ssh not up after ${T_BOOT}s"
    sleep 5
  done
}

cmd_sync_worktree() {
  local src="${1:-}"
  if [ -z "$src" ] || [ ! -d "$src" ]; then die "sync-worktree needs an existing worktree dir"; fi
  # shellcheck disable=SC2046
  "$TIMEOUT_BIN" "$T_SYNC" "$RSYNC" -a --delete --exclude .git --exclude node_modules --exclude '.env' --exclude '.env.*' \
    -e "$SSH $(ssh_opts)" "${src%/}/" "$SSH_USER@127.0.0.1:$REMOTE_DIR/" || die "rsync in failed"
}

cmd_run_suites() {
  [ "$#" -gt 0 ] || die "run-suites needs at least one suite path"
  local s name rc=0
  for s in "$@"; do
    case "$s" in
      *..*|/*) die "suite path must be repo-relative without '..': $s" ;;
      scripts/*.sh) ;;
      *) die "suite must match scripts/**/*.sh: $s" ;;
    esac
    case "$s" in *[!A-Za-z0-9._/-]*) die "suite path has unsafe characters: $s" ;; esac
  done
  remote 30 "mkdir -p $REMOTE_RESULTS" || die "cannot create remote results dir"
  for s in "$@"; do
    name=$(printf '%s' "$s" | tr '/' '_')
    # macOS has no coreutils timeout, so the guest-side deadline is perl's alarm
    # (perl ships with macOS); the outer ssh timeout stays as the backstop. The
    # suite's own exit status is kept in the .rc file AND returned through ssh.
    if remote "$T_SUITE" "cd $REMOTE_DIR && perl -e 'alarm shift; exec @ARGV' $T_SUITE bash $s > ../$REMOTE_RESULTS/$name.log 2>&1; rc=\$?; echo \$rc > ../$REMOTE_RESULTS/$name.rc; exit \$rc"; then
      echo "macos-lane: ran $s"
    else
      echo "macos-lane: $s failed or timed out" >&2; rc=1
    fi
  done
  return "$rc"
}

cmd_fetch_results() {
  local dest="${1:-}"
  [ -n "$dest" ] || die "fetch-results needs a destination dir"
  mkdir -p "$dest" || die "cannot create $dest"
  # shellcheck disable=SC2046
  "$TIMEOUT_BIN" "$T_FETCH" "$RSYNC" -a -e "$SSH $(ssh_opts)" \
    "$SSH_USER@127.0.0.1:$REMOTE_RESULTS/" "${dest%/}/" || die "rsync out failed"
}

cmd_stop() {
  "$TIMEOUT_BIN" "$T_STOP" "$DOCKER" stop "$NAME" || echo "macos-lane: stop failed (already gone?)" >&2
  # rm -f succeeds on a container that is already gone and fails if it cannot be removed.
  "$TIMEOUT_BIN" "$T_STOP" "$DOCKER" rm -f "$NAME" || die "docker rm -f $NAME failed — container may still be running"
}

sub="${1:-}"
[ "$#" -gt 0 ] && shift
case "$sub" in
  plan) cmd_plan ;;
  start) cmd_start ;;
  wait-ssh) cmd_wait_ssh ;;
  sync-worktree) cmd_sync_worktree "$@" ;;
  run-suites) cmd_run_suites "$@" ;;
  fetch-results) cmd_fetch_results "$@" ;;
  stop) cmd_stop ;;
  *) die "usage: macos-lane.sh start|wait-ssh|sync-worktree <dir>|run-suites <suite>...|fetch-results <dest>|stop|plan" ;;
esac
