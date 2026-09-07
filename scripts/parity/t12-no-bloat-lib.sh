#!/usr/bin/env bash
# scripts/parity/t12-no-bloat-lib.sh -- shared net-growth verdict for T12
# (scripts/parity/test-ws5-invariants.sh) and its control
# (scripts/parity/test-t12-no-bloat-lib.sh). HIMMEL-2581.
#
# T12 changed 2026-09-06 from a symmetric per-side churn cap (add<=1 AND
# del<=1) to a net-growth cap (add-del<=1). The per-side form rejected every
# ordinary rewording -- including the HIMMEL-2581 doc-sweep edit that
# triggered this change (two one-line rewordings, numstat add=2 del=2) and
# the routine PR #2101/HIMMEL-2413 edit of the identical shape -- and even a
# pure deletion of 5+ lines, none of which is the "root CLAUDE.md gains a
# rule block" bloat the check exists to catch. See test-ws5-invariants.sh's
# own header for the full history.
#
# t12_verdict <add> <del> -- prints the PASS/FAIL line T12 emits (PASS on
# stdout, FAIL on stderr, matching the caller's own convention) and returns
# 0 on PASS, 1 on FAIL. Callers must pass already-sanitized non-negative
# integers (test-ws5-invariants.sh sanitizes before calling; this function
# does not re-validate).
#
# Deliberately does NOT call `set` itself: sourced into callers running
# under their own shell options.
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Pure `$(( ))` integer arithmetic and `echo`; no .ps1 twin needed -- the
# only consumers are shell test suites which are themselves gitbash-only.
t12_verdict() {
    local add="$1" del="$2" net
    net=$((add - del))
    if [ "$net" -le 1 ]; then
        echo "PASS T12 no-bloat: root CLAUDE.md add=${add} del=${del} net=${net} (net growth <=1)."
        return 0
    fi
    echo "FAIL T12 no-bloat: root CLAUDE.md add=${add} del=${del} net=${net} -- a rule block was added." >&2
    return 1
}
