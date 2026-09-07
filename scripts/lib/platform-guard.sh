#!/usr/bin/env bash
# scripts/lib/platform-guard.sh -- shared T15 cross-platform predicate
# (HIMMEL-2682), used by scripts/parity/test-ws5-invariants.sh's T15 and
# scripts/hooks/check-new-shell-platform-guard.sh so the two cannot drift.
#
# Every NEW scripts/**/*.sh must ship a .ps1 twin OR carry a documented
# platform-guard marker ("platform guard" / "gitbash" / "git bash",
# case-insensitive) in its first 60 lines -- Windows contributors otherwise
# get a script that silently doesn't run for them.
#
# platform_guard_ok <path> -- 0 if <path> satisfies the predicate, 1
# otherwise. Prints nothing; callers report their own PASS/FAIL lines so the
# two consumers keep their own message formats.
#
# Deliberately does NOT call `set` itself: sourced into callers running
# under their own shell options.
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Pure `[ -f ]` + `head`/`grep`; no .ps1 twin needed -- the only consumers
# are shell suites and a shell pre-commit hook, both gitbash-only already.
platform_guard_ok() {
    local sh_path="$1" twin
    twin="${sh_path%.sh}.ps1"
    [ -f "$twin" ] && return 0
    [ -f "$sh_path" ] || return 1
    head -n 60 "$sh_path" | grep -Ei 'platform guard|gitbash|git bash' >/dev/null && return 0
    return 1
}
