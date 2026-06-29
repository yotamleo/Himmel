#!/usr/bin/env bash
# Hermetic tests for scripts/lib/scheduler-backend.sh — PATH-shimmed tools +
# env seams drive every OS/status branch deterministically.
set -uo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel)"
LIB="$REPO_ROOT/scripts/lib/scheduler-backend.sh"
[ -f "$LIB" ] || { echo "FAIL: $LIB not found"; exit 1; }

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

# BASE_PATH must carry the coreutils the lib/test need but NOT at/atq/crontab/
# systemctl/schtasks/pgrep, so each case adds exactly the tools it simulates and
# the "tool absent" cases are genuinely absent.
#
# On Windows Git-Bash those scheduler tools don't live in the coreutils dir at
# all (schtasks is in System32, not /usr/bin; at/crontab/systemctl don't exist),
# so the real coreutils dir is already a clean base — and a symlink farm is flaky
# there (no dev-mode symlinks → broken links → even bash won't resolve). On
# Linux/macOS the coreutils SHARE /usr/bin with the real at/crontab/systemctl, so
# the real dir leaks them (the VM e2e caught this); use a native-symlink farm to
# keep them absent. (ln -s is native on Linux/macOS.)
case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*)
        base_dir() {
            local t d; for t in bash sh sed grep tr head sort uname; do
                d="$(command -v "$t" 2>/dev/null)" && dirname "$d"
            done | sort -u | tr '\n' ':'
        }
        BASE_PATH="$(base_dir)"
        ;;
    *)
        CLEAN_BIN="$(mktemp -d)/clean-bin"; mkdir -p "$CLEAN_BIN"
        for t in bash sh sed grep tr head sort uname; do
            p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$CLEAN_BIN/$t"
        done
        BASE_PATH="$CLEAN_BIN"
        ;;
esac

# shim <dir> <name> — create an executable stub that exits 0.
shim() { mkdir -p "$1"; printf '#!/bin/sh\nexit 0\n' > "$1/$2"; chmod +x "$1/$2"; }

# run_status <shim_dir> <env...> — source lib under the shimmed PATH, echo status.
run_status() { # $1=bindir, rest=VAR=val
    local bindir="$1"; shift
    env -i HOME="$HOME" PATH="$bindir:$BASE_PATH" "$@" \
        bash -c "source '$LIB'; scheduler_backend_status"
}

# --- windows: schtasks present -> ok ---
d="$(mktemp -d)"; shim "$d/bin" schtasks
s="$(run_status "$d/bin" SCHEDULER_BACKEND_OS=windows)"
if [ "$s" = ok ]; then pass "windows+schtasks -> ok"; else fail "windows -> $s"; fi
rm -rf "$d"

# --- linux: at present + atd live -> ok ---
d="$(mktemp -d)"; shim "$d/bin" at
s="$(run_status "$d/bin" SCHEDULER_BACKEND_OS=linux SCHEDULER_BACKEND_ATD_ACTIVE=1)"
if [ "$s" = ok ]; then pass "linux at+atd-live -> ok"; else fail "linux ok -> $s"; fi
rm -rf "$d"

# --- linux: at present + atd DEAD -> disabled (the F1 false-OK case) ---
d="$(mktemp -d)"; shim "$d/bin" at; shim "$d/bin" crontab
s="$(run_status "$d/bin" SCHEDULER_BACKEND_OS=linux SCHEDULER_BACKEND_ATD_ACTIVE=0)"
if [ "$s" = disabled ]; then pass "linux at+atd-dead -> disabled"; else fail "linux disabled -> $s"; fi
rm -rf "$d"

# --- linux: no at, crontab present -> ok-cron ---
d="$(mktemp -d)"; shim "$d/bin" crontab
s="$(run_status "$d/bin" SCHEDULER_BACKEND_OS=linux)"
if [ "$s" = ok-cron ]; then pass "linux crontab-only -> ok-cron"; else fail "linux ok-cron -> $s"; fi
rm -rf "$d"

# --- linux: nothing -> missing ---
d="$(mktemp -d)"; mkdir -p "$d/bin"
s="$(run_status "$d/bin" SCHEDULER_BACKEND_OS=linux)"
if [ "$s" = missing ]; then pass "linux nothing -> missing"; else fail "linux missing -> $s"; fi
rm -rf "$d"

# --- linux: prober absent (no systemctl, atd-active seam UNSET) -> disabled ---
d="$(mktemp -d)"; shim "$d/bin" at
s="$(run_status "$d/bin" SCHEDULER_BACKEND_OS=linux)"   # no systemctl, no seam
if [ "$s" = disabled ]; then pass "linux prober-absent -> disabled (conservative)"; else fail "linux prober-absent -> $s"; fi
rm -rf "$d"

# --- linux: REAL systemctl prober (no seam) — exercises _scheduler_atd_live's
#     `systemctl is-active --quiet atd` branch, which the ATD_ACTIVE seam skips. ---
d="$(mktemp -d)"; shim "$d/bin" at; shim "$d/bin" systemctl   # systemctl exits 0 = active
s="$(run_status "$d/bin" SCHEDULER_BACKEND_OS=linux)"
if [ "$s" = ok ]; then pass "linux at+systemctl-active -> ok (real prober)"; else fail "linux real-prober ok -> $s"; fi
rm -rf "$d"

d="$(mktemp -d)"; shim "$d/bin" at
mkdir -p "$d/bin"; printf '#!/bin/sh\nexit 3\n' > "$d/bin/systemctl"; chmod +x "$d/bin/systemctl"  # is-active rc!=0 = inactive
s="$(run_status "$d/bin" SCHEDULER_BACKEND_OS=linux)"
if [ "$s" = disabled ]; then pass "linux at+systemctl-inactive -> disabled (real prober)"; else fail "linux real-prober disabled -> $s"; fi
rm -rf "$d"

# --- linux: pgrep fallback when no systemctl — exercises the pgrep branch. ---
d="$(mktemp -d)"; shim "$d/bin" at; shim "$d/bin" pgrep   # pgrep exits 0 = atd found
s="$(run_status "$d/bin" SCHEDULER_BACKEND_OS=linux)"
if [ "$s" = ok ]; then pass "linux at+pgrep-found -> ok (pgrep fallback)"; else fail "linux pgrep ok -> $s"; fi
rm -rf "$d"

# --- macos: crontab present -> ok-cron (at ignored) ---
d="$(mktemp -d)"; shim "$d/bin" crontab; shim "$d/bin" at; shim "$d/bin" atq
s="$(run_status "$d/bin" SCHEDULER_BACKEND_OS=macos)"
if [ "$s" = ok-cron ]; then pass "macos crontab -> ok-cron"; else fail "macos ok-cron -> $s"; fi
rm -rf "$d"

# --- macos: no crontab -> missing ---
d="$(mktemp -d)"; shim "$d/bin" at
s="$(run_status "$d/bin" SCHEDULER_BACKEND_OS=macos)"
if [ "$s" = missing ]; then pass "macos no-crontab -> missing"; else fail "macos missing -> $s"; fi
rm -rf "$d"

# --- remediation: linux missing is non-empty + mentions atd ---
d="$(mktemp -d)"; mkdir -p "$d/bin"
r="$(env -i HOME="$HOME" PATH="$d/bin:$BASE_PATH" SCHEDULER_BACKEND_OS=linux \
     bash -c "source '$LIB'; scheduler_backend_remediation")"
case "$r" in *atd*) pass "linux remediation mentions atd" ;; *) fail "linux remediation: $r" ;; esac
rm -rf "$d"

echo
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; else echo "$failures FAILED"; exit 1; fi
