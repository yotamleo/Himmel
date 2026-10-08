#!/usr/bin/env bash
# HIMMEL-4912: containment for hook classification, never destructive exec mode.
# Linux namespaces or Darwin sandbox-exec; missing confinement fails closed.
# Usage: sandbox-run.sh [--canary ABSENT_PATH] [--read-only INPUT]... -- CMD [ARG...]
# Linux binds runtime/worktree/socket-free inputs and bounds HOME/tmp in tmpfs.
# Darwin confines writes to private scratch; outputs use stdout/stderr only.
set -uo pipefail

platform=$(uname -s) || exit 125
case "$platform" in
    Darwin)
        sandbox_exec=$(command -v sandbox-exec) || {
            printf 'sandbox-run: sandbox-exec is required; refusing unsandboxed execution\n' >&2
            exit 125
        }
        ;;
    Linux)
        if ! command -v bwrap >/dev/null 2>&1; then
            printf 'sandbox-run: bwrap is required; refusing unsandboxed execution\n' >&2
            exit 125
        fi
        if ! command -v prlimit >/dev/null 2>&1; then
            printf 'sandbox-run: prlimit is required; refusing unsandboxed execution\n' >&2
            exit 125
        fi
        ;;
    *) printf 'sandbox-run: Linux or Darwin confinement is required\n' >&2; exit 125 ;;
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
            if [ "$platform" = Darwin ]; then
                input=$(python3 -I -c 'import os,sys; p=os.path.realpath(sys.argv[1]); assert os.path.exists(p); print(p)' "$2") || exit 125
            else
                input=$(realpath -e -- "$2") || exit 125
            fi
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

if [ "$platform" = Darwin ]; then
    for input in "${inputs[@]}"; do
        special=$(find "$input" ! -type f ! -type d ! -type l -print -quit) || exit 125
        if [ -n "$special" ]; then
            printf 'sandbox-run: refusing socket/device/FIFO input: %s\n' "$special" >&2
            exit 125
        fi
    done
    # Seatbelt filters use the canonical scratch path as DATA, never SBPL text.
    scratch_root=$(cd "$scratch_root" && pwd -P) || exit 125
    writable_root="$scratch_root/work"
    mkdir -p "$writable_root/home" "$writable_root/tmp" || exit 125
    profile="$scratch_root/profile.sb"
    cat > "$profile" <<'PROFILE'
(version 1)
(allow default)
(deny network*)
(deny file-write*)
(allow file-write* (subpath (param "SCRATCH")) (literal "/dev/null"))
PROFILE
    [ -s "$profile" ] || exit 125
    darwin_env=(/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin LANG=C.UTF-8
        "HOME=$writable_root/home" "TMPDIR=$writable_root/tmp" "SANDBOX_CANARY=$canary")
    # Profile/setup errors must be rc125, not confused with a hook's denial.
    if ! "${darwin_env[@]}" "$sandbox_exec" -f "$profile" -D "SCRATCH=$writable_root" -- /usr/bin/true; then
        printf 'sandbox-run: sandbox-exec profile unusable; refusing execution\n' >&2
        exit 125
    fi
    "${darwin_env[@]}" "$sandbox_exec" -f "$profile" -D "SCRATCH=$writable_root" -- "$@"
    rc=$?
    if [ -e "$canary" ] || [ -L "$canary" ]; then
        printf 'sandbox-run: CANARY CHANGED; replay escaped containment\n' >&2
        exit 125
    fi
    exit "$rc"
fi

runtime=()
runtime_inputs=()
runtime_masks=()
binds=()
for input in /usr /bin /sbin /lib /lib64 /etc; do
    if [ -e "$input" ]; then
        runtime+=(--ro-bind "$input" "$input")
        runtime_inputs+=("$input")
    fi
done
# Read-only runtime sockets still permit IPC. Hide special nodes and directories
# whose contents cannot be inspected; never assume an unreadable tree is safe.
mask_list="$scratch_root/runtime-masks"
find "${runtime_inputs[@]}" \
    \( -type d \( ! -readable -o ! -executable \) -printf 'd\0%p\0' -prune \) \
    -o \( ! -type f ! -type d ! -type l -printf 'f\0%p\0' \) > "$mask_list" || exit 125
while IFS= read -r -d '' kind && IFS= read -r -d '' input; do
    case "$kind" in
        d) runtime_masks+=(--tmpfs "$input" --remount-ro "$input") ;;
        f) runtime_masks+=(--ro-bind /dev/null "$input") ;;
        *) exit 125 ;;
    esac
done < "$mask_list"
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
    --tmpfs /run --remount-ro /run --symlink /run /var/run "${binds[@]}" "${runtime_masks[@]}" \
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
