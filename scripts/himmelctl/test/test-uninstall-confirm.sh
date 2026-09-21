#!/usr/bin/env bash
# Platform guard: drives cross-platform bin.js from bash, including Git Bash
# on Windows via _hermetic-home.sh winpath; a .ps1 twin duplicates this coverage.
# WHY (HIMMEL-2755): non-interactive input is refusal; a decline is a TTY
# answer. --yes keeps uninstall's option whitelist narrow. Never use real HOME.
set -uo pipefail

test_dir="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$test_dir/../../.." && pwd)"
# shellcheck source=_hermetic-home.sh
. "$test_dir/_hermetic-home.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/uninstall-confirm.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home" "$tmp/repo/scripts" "$tmp/cache" "$tmp/bin"
export HOME="$tmp/home"
USERPROFILE="$(winpath "$HOME")"
HIMMELCTL_CACHE_DIR="$(winpath "$tmp/cache")"
HIMMELCTL_REPO_ROOT="$(winpath "$tmp/repo")"
HIMMELCTL_BIN_DIR="$(winpath "$tmp/bin")"
HIMMEL_LUNA_CONFIG_PATH="$(winpath "$tmp/home/luna-config.json")"
export USERPROFILE HIMMELCTL_CACHE_DIR HIMMELCTL_REPO_ROOT HIMMELCTL_BIN_DIR HIMMEL_LUNA_CONFIG_PATH
# Existing repo-root seam resolves only these harmless teardown scripts.
# HIMMEL-3058: --dry-run now RUNS the executor's own --dry-run (the plan it
# prints is the script's, not a second copy) — the stub answers it distinctly.
printf '#!/usr/bin/env bash\ncase " $* " in *" --dry-run "*) echo fixture-dry-run; exit 0 ;; esac\necho fixture-teardown\nexit 7\n' > "$tmp/repo/scripts/uninstall.sh"
# shellcheck disable=SC2016 # PowerShell $-variables must reach the file literally
printf 'param([switch]$Yes,[switch]$DryRun,[switch]$PurgeState)\nif ($DryRun) { Write-Output "fixture-dry-run"; exit 0 }\nWrite-Output "fixture-teardown"\nexit 7\n' > "$tmp/repo/scripts/uninstall.ps1"

check_rc() {
    [ "$1" -eq "$2" ] || { echo "FAIL - $3: expected rc=$1, got $2"; cat "$tmp/out" "$tmp/err"; exit 1; }
}
check_has() {
    grep -Fq -- "$1" "$2" || { echo "FAIL - $3: missing $1"; exit 1; }
}
check_not_has() {
    if grep -Fq -- "$1" "$2"; then echo "FAIL - $3: unexpected $1"; exit 1; fi
}

# C1 — RED: the old helper reported a successful human decline on EOF.
node "$root/scripts/himmelctl/bin.js" uninstall </dev/null >"$tmp/out" 2>"$tmp/err"; rc=$?
check_rc 2 "$rc" C1
check_has 'non-interactive run without --yes' "$tmp/err" C1
check_not_has 'declined; nothing run' "$tmp/out" C1
echo 'ok - C1 EOF refuses with rc=2'

printf 'n\n' | node "$root/scripts/himmelctl/bin.js" uninstall >"$tmp/out" 2>"$tmp/err"; rc=$?
check_rc 2 "$rc" C2
check_has 'non-interactive run without --yes' "$tmp/err" C2
echo 'ok - C2 a piped decline also refuses with rc=2'

node "$root/scripts/himmelctl/bin.js" uninstall --dry-run </dev/null >"$tmp/out" 2>"$tmp/err"; rc=$?
check_rc 0 "$rc" C3
check_not_has 'Proceed?' "$tmp/out" C3
check_has 'fixture-dry-run' "$tmp/out" C3
check_not_has 'fixture-teardown' "$tmp/out" C3
echo 'ok - C3 dry-run exits 0 without a prompt and runs the executor in dry-run mode only'

node "$root/scripts/himmelctl/bin.js" uninstall --yes --dry-run </dev/null >"$tmp/out" 2>"$tmp/err"; rc=$?
check_rc 0 "$rc" C4
check_not_has 'unknown option for uninstall' "$tmp/err" C4
check_not_has 'fixture-teardown' "$tmp/out" C4
echo 'ok - C4 --yes accepted with --dry-run, and --dry-run still wins (no teardown)'

node "$root/scripts/himmelctl/bin.js" uninstall -n </dev/null >"$tmp/out" 2>"$tmp/err"; rc=$?
check_rc 0 "$rc" C3n
check_has 'fixture-dry-run' "$tmp/out" C3n
check_not_has 'fixture-teardown' "$tmp/out" C3n
echo 'ok - C3n -n is the short form of --dry-run'

node "$root/scripts/himmelctl/bin.js" uninstall --lanes x </dev/null >"$tmp/out" 2>"$tmp/err"; rc=$?
if [ "$rc" -eq 0 ]; then echo 'FAIL - C5 unrelated option accepted'; exit 1; fi
check_not_has 'fixture-teardown' "$tmp/out" C5
echo 'ok - C5 unrelated option still rejected'

# WHY (HIMMEL-2755): neither an affirmative nor an empty pipe may consent.
# Isolate fail-fast assertions so both RED controls report before exiting.
confirm_failed=0
for confirm_case in C6 C7; do
    if [ "$confirm_case" = C6 ]; then confirm_answer=y; else confirm_answer=''; fi
    printf '%s\n' "$confirm_answer" | node "$root/scripts/himmelctl/bin.js" uninstall >"$tmp/out" 2>"$tmp/err"; rc=$?
    if (
        check_rc 2 "$rc" "$confirm_case"
        check_has 'non-interactive run without --yes' "$tmp/err" "$confirm_case"
        check_not_has 'fixture-teardown' "$tmp/out" "$confirm_case"
    ); then
        echo "ok - $confirm_case piped answer refuses with rc=2"
    else
        confirm_failed=$((confirm_failed + 1))
    fi
done

# C8 — WHY (HIMMEL-2755): an open, silent pipe must not stall teardown.
if command -v timeout >/dev/null 2>&1; then
    # WHY (HIMMEL-2755): an open pipe that never sends a byte and never closes.
    # No PID capture: $! is not set by a process substitution before bash 5.1,
    # so the producer cannot be reaped portably — instead it is given a short
    # lifetime and its stderr, the only fd it inherits, is discarded, so a
    # lingering producer holds nothing the test harness is reading.
    exec 3< <(sleep 10 2>/dev/null)
    timeout 2 node "$root/scripts/himmelctl/bin.js" uninstall <&3 >"$tmp/out" 2>"$tmp/err"; rc=$?  # gnu-ok: the whole C8 block is gated by `command -v timeout` and skips where it is absent
    exec 3<&-
    if (
        check_rc 2 "$rc" C8
        check_not_has 'fixture-teardown' "$tmp/out" C8
    ); then
        echo 'ok - C8 open silent pipe refuses promptly with rc=2'
    else
        confirm_failed=$((confirm_failed + 1))
    fi
else
    echo 'skip - C8 timeout is not available'
fi

# C9-C11 — real TTY decline, EOF, and redirected stdout must never teardown.
if [ "$(uname -s)" = "Linux" ] && command -v script >/dev/null 2>&1; then
    printf 'n\n' | script -qec "node \"$root/scripts/himmelctl/bin.js\" uninstall" /dev/null >"$tmp/out" 2>"$tmp/err"; rc=$? # gnu-ok: util-linux script(1), and the block is uname-gated to Linux
    if (
        check_rc 3 "$rc" C9
        check_has 'declined; nothing run' "$tmp/out" C9
        check_not_has 'fixture-teardown' "$tmp/out" C9
    ); then
        echo 'ok - C9 TTY decline exits with rc=3'
    else
        confirm_failed=$((confirm_failed + 1))
    fi

    printf '' | script -qec "node \"$root/scripts/himmelctl/bin.js\" uninstall" /dev/null >"$tmp/out" 2>"$tmp/err"; rc=$? # gnu-ok: util-linux script(1), and the block is uname-gated to Linux
    if (
        check_rc 2 "$rc" C10
        check_has 'non-interactive run without --yes' "$tmp/out" C10
        check_not_has 'fixture-teardown' "$tmp/out" C10
    ); then
        echo 'ok - C10 TTY EOF refuses with rc=2'
    else
        confirm_failed=$((confirm_failed + 1))
    fi

    printf 'n\n' | script -qec "node \"$root/scripts/himmelctl/bin.js\" uninstall > \"$tmp/redirected\"" /dev/null >"$tmp/out" 2>"$tmp/err"; rc=$? # gnu-ok: util-linux script(1), and the block is uname-gated to Linux
    if (
        check_rc 2 "$rc" C11
        check_has 'non-interactive run without --yes' "$tmp/out" C11
        check_not_has 'fixture-teardown' "$tmp/out" C11
        check_not_has 'fixture-teardown' "$tmp/redirected" C11
    ); then
        echo 'ok - C11 TTY stdin with redirected stdout refuses with rc=2'
    else
        confirm_failed=$((confirm_failed + 1))
    fi
    # C13-C18 — HIMMEL-3328 (operator ruling a): the prompt is default-No,
    # `Proceed? [y/N]`. Only y/yes (any case) consents; a bare Enter or any
    # other answer declines with rc=3. Each runs under the scratch HOME above.
    printf '\n' | script -qec "node \"$root/scripts/himmelctl/bin.js\" uninstall" /dev/null >"$tmp/out" 2>"$tmp/err"; rc=$? # gnu-ok: util-linux script(1), and the block is uname-gated to Linux
    if (
        check_rc 3 "$rc" C13
        check_has 'Proceed? [y/N]' "$tmp/out" C13
        check_has 'declined; nothing run' "$tmp/out" C13
        check_not_has 'fixture-teardown' "$tmp/out" C13
    ); then
        echo 'ok - C13 TTY bare Enter declines with rc=3 and the prompt reads [y/N]'
    else
        confirm_failed=$((confirm_failed + 1))
    fi

    for confirm_answer in y Y yes YES; do
        printf '%s\n' "$confirm_answer" | script -qec "node \"$root/scripts/himmelctl/bin.js\" uninstall" /dev/null >"$tmp/out" 2>"$tmp/err"; rc=$? # gnu-ok: util-linux script(1), and the block is uname-gated to Linux
        if (
            check_rc 7 "$rc" "C14 ($confirm_answer)"
            check_has 'fixture-teardown' "$tmp/out" "C14 ($confirm_answer)"
            check_not_has 'declined; nothing run' "$tmp/out" "C14 ($confirm_answer)"
        ); then
            echo "ok - C14 TTY '$confirm_answer' proceeds and propagates rc=7"
        else
            confirm_failed=$((confirm_failed + 1))
        fi
    done

    for confirm_answer in n N no maybe ok; do
        printf '%s\n' "$confirm_answer" | script -qec "node \"$root/scripts/himmelctl/bin.js\" uninstall" /dev/null >"$tmp/out" 2>"$tmp/err"; rc=$? # gnu-ok: util-linux script(1), and the block is uname-gated to Linux
        if (
            check_rc 3 "$rc" "C15 ($confirm_answer)"
            check_has 'declined; nothing run' "$tmp/out" "C15 ($confirm_answer)"
            check_not_has 'fixture-teardown' "$tmp/out" "C15 ($confirm_answer)"
        ); then
            echo "ok - C15 TTY '$confirm_answer' declines with rc=3"
        else
            confirm_failed=$((confirm_failed + 1))
        fi
    done
else
    echo 'skip - C9-C15 pty coverage needs Linux script(1)'
fi

# WHY (HIMMEL-2755): --yes must actually bypass the prompt and propagate the
# child's rc; the existing override makes that test harmless on both platforms.
node "$root/scripts/himmelctl/bin.js" uninstall --yes </dev/null >"$tmp/out" 2>"$tmp/err"; rc=$?
check_rc 7 "$rc" 'yes spawn'
check_has 'fixture-teardown' "$tmp/out" 'yes spawn'
check_not_has 'Proceed?' "$tmp/out" 'yes spawn'
echo 'ok - --yes runs only the fixture teardown and propagates rc=7'
# C12 — help must include the propagated teardown meanings of rc=2 and rc=3.
node "$root/scripts/himmelctl/bin.js" --help >"$tmp/out" 2>"$tmp/err"; rc=$?
check_rc 0 "$rc" C12
check_has '2 = refused (non-interactive without --yes) or' "$tmp/out" C12
check_has 'incomplete teardown (a required step could not run)' "$tmp/out" C12
check_has '3 = declined by the operator or teardown refused' "$tmp/out" C12
check_has 'a wet run against a non-fixture HOME' "$tmp/out" C12
check_not_has 'fixture-teardown' "$tmp/out" C12
echo 'ok - C12 help names both wrapper and teardown meanings of rc=2 and rc=3'
if [ "$confirm_failed" -gt 0 ]; then exit 1; fi
