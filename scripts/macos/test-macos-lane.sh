#!/usr/bin/env bash
# test-macos-lane.sh — HIMMEL-4980. Dry-run tests for macos-lane.sh: docker,
# ssh, rsync and timeout are PATH-independent stubs that log their argv, so
# nothing real (no docker, no network, no VM) is touched.
#
# PLATFORM GUARD: no .ps1 twin, by design — the lane drives KVM/docker on the
# Linux station; this Bash 3.2 suite tests that platform-specific script.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/macos-lane.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/macos-lane-test.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }
contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3' in '$2')" ;; esac; }
lacks() { case "$2" in *"$3"*) fail "$1 (unexpected '$3' in '$2')" ;; *) pass "$1" ;; esac; }

LOG="$W/calls.log"
# shellcheck disable=SC2016  # $* and $STUB_LOG must reach the stubs literally
for t in docker ssh rsync; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "$STUB_LOG"\nexit "${STUB_RC:-0}"\n' "$t" > "$W/$t"
done
# timeout stub: log the seconds, run the rest.
# shellcheck disable=SC2016  # $1, $@ and $STUB_LOG must reach the stub literally
printf '#!/usr/bin/env bash\necho "timeout $1" >> "$STUB_LOG"\nshift\nexec "$@"\n' > "$W/timeout"
chmod +x "$W/docker" "$W/ssh" "$W/rsync" "$W/timeout"

run() { # run <args...> ; sets OUT, RC, and rewrites LOG
  : > "$LOG"
  OUT=$(env -i PATH="$PATH" STUB_LOG="$LOG" STUB_RC="${STUB_RC:-0}" \
    HIMMEL_MACOS_LANE_OK="${OK-1}" HIMMEL_MACOS_LANE_DIR="$W/lane" \
    DOCKER="$W/docker" SSH="$W/ssh" RSYNC="$W/rsync" TIMEOUT_BIN="$W/timeout" \
    HIMMEL_MACOS_LANE_T_BOOT=1 \
    bash "$SUT" "$@" 2>&1)
  RC=$?
  CALLS=$(cat "$LOG")
}

# 1. opt-in gate: refuses without HIMMEL_MACOS_LANE_OK=1, runs nothing
OK="" run start
eq "gate: refuses without opt-in (rc 2)" 2 "$RC"
eq "gate: nothing executed" "" "$CALLS"
contains "gate: message names the var" "$OUT" "HIMMEL_MACOS_LANE_OK=1"
OK=0 run stop
eq "gate: =0 also refuses" 2 "$RC"

: > "$LOG"
SPACE_OUT=$(env -i PATH="$PATH" STUB_LOG="$LOG" HIMMEL_MACOS_LANE_OK=1 \
  HIMMEL_MACOS_LANE_DIR="$W/lane dir" DOCKER="$W/docker" SSH="$W/ssh" RSYNC="$W/rsync" TIMEOUT_BIN="$W/timeout" \
  bash "$SUT" plan 2>&1)
eq "lane dir with whitespace refused" 1 "$?"
contains "whitespace refusal names the cause" "$SPACE_OUT" "whitespace"

# 2. start: refuses without a persistent disk, then builds the docker plan
run start
eq "start: no disk -> fails" 1 "$RC"
lacks "start: no disk -> docker not called" "$CALLS" "docker "
mkdir -p "$W/lane" && : > "$W/lane/mac_hdd_ng.img"
run start
eq "start: rc 0" 0 "$RC"
contains "start: kvm device" "$CALLS" "--device /dev/kvm"
contains "start: loopback-only ssh port" "$CALLS" "-p 127.0.0.1:50922:10022"
contains "start: disk mounted from lane dir" "$CALLS" "-v $W/lane/mac_hdd_ng.img:/image"
contains "start: memory cap" "$CALLS" "--memory 10g"
contains "start: bounded by timeout" "$CALLS" "timeout 120"
contains "start: default image is the one that exists on Docker Hub" "$CALLS" "sickcodes/docker-osx:latest"
lacks "start: no naked-auto tag (gone from Docker Hub)" "$CALLS" "naked-auto"

# 3. ssh never reads the operator config or real HOME
run run-suites scripts/test-a.sh
contains "ssh: ignores operator config" "$CALLS" "-F /dev/null"
contains "ssh: lane-private known_hosts" "$CALLS" "UserKnownHostsFile=$W/lane/known_hosts"
contains "ssh: lane-private key" "$CALLS" "-i $W/lane/id_ed25519"
lacks "ssh: no operator ~/.ssh" "$CALLS" "$HOME/.ssh"

# 4. sync-worktree / run-suites / fetch-results / stop plans
mkdir -p "$W/wt"
run sync-worktree "$W/wt"
contains "sync: rsync with delete" "$CALLS" "--delete"
contains "sync: excludes .git" "$CALLS" "--exclude .git"
contains "sync: excludes .env" "$CALLS" "--exclude .env"
contains "sync: target is himmel-work" "$CALLS" "user@127.0.0.1:himmel-work/"
run sync-worktree "$W/nope"
eq "sync: missing dir fails" 1 "$RC"
run run-suites scripts/test-a.sh scripts/handover/console-kit/test-b.sh
eq "run-suites: rc 0" 0 "$RC"
contains "run-suites: first suite" "$CALLS" "bash scripts/test-a.sh"
contains "run-suites: second suite" "$CALLS" "bash scripts/handover/console-kit/test-b.sh"
contains "run-suites: ssh deadline leaves guest cleanup time" "$CALLS" "timeout 930"
contains "run-suites: results dir reset per run" "$CALLS" "rm -rf himmel-results"
contains "run-suites: guest-side deadline" "$CALLS" "alarm shift; exec @ARGV' 900 bash scripts/test-a.sh"
# shellcheck disable=SC2016  # the literal text '$rc' is what the remote command carries
contains "run-suites: suite status returned through ssh" "$CALLS" 'exit $rc'
STUB_RC=1 run run-suites scripts/test-a.sh
eq "run-suites: remote failure propagates" 1 "$RC"
run run-suites '../etc/passwd'
eq "run-suites: '..' refused" 1 "$RC"
run run-suites 'scripts/x.sh; rm -rf /'
eq "run-suites: shell metachar refused" 1 "$RC"
run run-suites /etc/x.sh
eq "run-suites: absolute path refused" 1 "$RC"
run run-suites
eq "run-suites: empty list refused" 1 "$RC"
run fetch-results "$W/out"
contains "fetch: rsync from remote results" "$CALLS" "user@127.0.0.1:himmel-results/"
run stop
contains "stop: docker stop" "$CALLS" "docker stop himmel-macos-lane"
contains "stop: docker rm -f" "$CALLS" "docker rm -f himmel-macos-lane"
STUB_RC=1 run stop
eq "stop: failed removal propagates" 1 "$RC"

# 5. wait-ssh gives up after the boot budget
STUB_RC=1 run wait-ssh
eq "wait-ssh: bounded failure" 1 "$RC"

if [ "$fails" -eq 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
