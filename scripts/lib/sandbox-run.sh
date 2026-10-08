#!/usr/bin/env bash
# HIMMEL-4912: containment for hook classification, never destructive exec mode.
# Linux only: missing bubblewrap/namespaces fail closed, never run on the host.
# Usage: sandbox-run.sh [--canary ABSENT_PATH] [--read-only INPUT]... -- CMD [ARG...]
# Bind only runtime directories, the worktree and explicit socket-free inputs.
# HOME and /tmp are bounded tmpfs; host outputs use stdout/stderr only.
set -uo pipefail

if ! command -v bwrap >/dev/null 2>&1; then
    printf 'sandbox-run: bwrap is required; refusing unsandboxed execution\n' >&2
    exit 125
fi
if ! command -v prlimit >/dev/null 2>&1; then
    printf 'sandbox-run: prlimit is required; refusing unsandboxed execution\n' >&2
    exit 125
fi
case "$(uname -s)" in
    Linux) ;;
    *) printf 'sandbox-run: Linux namespaces are required\n' >&2; exit 125 ;;
esac
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)" || exit 125
canary=''
inputs=("$ROOT")
while [ "$#" -gt 0 ]; do
    case "$1" in
        --canary)
            canary="${2:-}"
            case "$canary" in /*) ;; *) printf 'sandbox-run: canary must be an absolute absent path\n' >&2; exit 125 ;; esac
            [ "$#" -ge 2 ] || exit 125
            shift 2 ;;
        --read-only)
            [ "$#" -ge 2 ] || exit 125
            input=$(realpath -e -- "$2") || exit 125
            case "$input" in
                /|/tmp|/var|/var/tmp|/home|/run|/run/*|/var/run|/var/run/*|/proc|/proc/*|/dev|/dev/*|/etc|/usr|/bin|/sbin|/lib|/lib64|/sandbox|/sandbox/*)
                    printf 'sandbox-run: refusing broad or namespace input: %s\n' "$input" >&2; exit 125 ;;
            esac
            inputs+=("$input")
            shift 2 ;;
        --) shift; break ;;
        *) printf 'sandbox-run: unknown option: %s\n' "$1" >&2; exit 125 ;;
    esac
done
if [ "$#" -eq 0 ]; then
    printf 'usage: sandbox-run.sh [--canary ABSENT_PATH] [--read-only INPUT]... -- COMMAND [ARG...]\n' >&2
    exit 125
fi

scratch_root=$(mktemp -d /tmp/himmel-sandbox.XXXXXX) || exit 125
trap 'rm -rf "$scratch_root"' EXIT
canary="${canary:-$scratch_root/canary}"
if [ -e "$canary" ] || [ -L "$canary" ]; then
    printf 'sandbox-run: canary already exists; refusing replay\n' >&2
    exit 125
fi

runtime=()
binds=()
for input in /usr /bin /sbin /lib /lib64 /etc; do
    [ ! -e "$input" ] || runtime+=(--ro-bind "$input" "$input")
done
for input in "${inputs[@]}"; do
    # Read-only sockets still accept connections. Never expose one via fixtures
    # or the worktree; also reject devices/FIFOs, which are not replay inputs.
    special=$(find "$input" ! -type f ! -type d ! -type l -print -quit) || exit 125
    if [ -n "$special" ]; then
        printf 'sandbox-run: refusing socket/device/FIFO input: %s\n' "$special" >&2
        exit 125
    fi
    binds+=(--ro-bind "$input" "$input")
done

# Bound setup itself. Apply nproc AFTER creating the user/PID namespaces:
# before bwrap it counts the station UID's fleet and can prevent even setup.
# No host root bind: filesystem Unix sockets are absent, and abstract sockets
# are cut off by the network namespace. proc/dev are private pseudo-filesystems.
prlimit --as=1073741824 --cpu=60 -- \
    bwrap "${runtime[@]}" --unshare-all --unshare-user --unshare-net \
    --die-with-parent --new-session --cap-drop ALL --disable-userns \
    --proc /proc --remount-ro /proc --dev /dev --remount-ro /dev \
    --size 67108864 --tmpfs /tmp \
    --size 67108864 --tmpfs /sandbox/home \
    --tmpfs /run --remount-ro /run --symlink /run /var/run "${binds[@]}" \
    --clearenv --setenv PATH /usr/bin:/bin --setenv LANG C.UTF-8 \
    --setenv HOME /sandbox/home --setenv TMPDIR /tmp \
    --setenv SANDBOX_CANARY "$canary" --chdir "$PWD" \
    -- /usr/bin/prlimit --as=1073741824 --cpu=60 --nproc=128 -- "$@"
rc=$?
# Checked after EVERY invocation, including hook deny, crash and setup failure.
if [ -e "$canary" ] || [ -L "$canary" ]; then
    printf 'sandbox-run: CANARY CHANGED; replay escaped containment\n' >&2
    exit 125
fi
exit "$rc"
