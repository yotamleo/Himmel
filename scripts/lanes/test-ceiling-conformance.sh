#!/usr/bin/env bash
# scripts/lanes/test-ceiling-conformance.sh - HIMMEL-2974. Hermetic tests for
# the live --autocompact-ceiling scan: PATH-stubbed pgrep, no real process
# table read.
#
# HIMMEL-2999: the primary-path scenarios below drive claude_sessions() via a
# fake /proc root (CLAUDE_SESSIONS_PROC) with real NUL-separated
# <pid>/cmdline files, not a flattened `pgrep -af` line -- this is what makes
# scenario (h) below a real regression test for the argv-boundary spoof
# (a pgrep -af-only stub cannot tell "free-text -p value" from "a real -n/
# --autocompact flag" in the first place). Scenario (i) keeps the OLD
# `pgrep -af` stub verbatim to prove the no-/proc fallback path is
# byte-identical.
#
# PLATFORM GUARD: no .ps1 twin, by design -- the SUT is Linux-only (pgrep).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/ceiling-conformance.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/ceiling-test.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
contains() {
    case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3' in '$2')" ;; esac
}

mkdir -p "$W/bin" "$W/proc"

# mkcmdline <pid> <argv...> - writes a real NUL-separated cmdline file for a
# fake /proc/<pid>, mirroring what the kernel exposes.
mkcmdline() {
    local pid="$1"; shift
    mkdir -p "$W/proc/$pid"
    # printf writes the NUL bytes straight to the file; a bash string
    # variable cannot hold an embedded NUL (`$'\0'` silently evaluates to
    # empty), so building the payload in a variable first would glue every
    # argv element together with no separator at all.
    printf '%s\0' "$@" > "$W/proc/$pid/cmdline"
}

# pgrep_x_stub <pid...> - a `pgrep -x claude` stub returning these bare pids.
pgrep_x_stub() {
    {
        printf '#!/usr/bin/env bash\n'
        # shellcheck disable=SC2016  # single quotes are deliberate: $1 must
        # reach the generated stub file literally, not expand here.
        printf 'if [ "$1" = "-x" ]; then printf "%%s\\n" %s; exit 0; fi\n' "$*"
        printf 'exit 1\n'
    } > "$W/bin/pgrep"
    chmod +x "$W/bin/pgrep"
}

run_primary() { CLAUDE_SESSIONS_PROC="$W/proc" PATH="$W/bin:$PATH" bash "$SUT"; }

# (a) two pinned legs + one console -> ceiling=ok
mkcmdline 101 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-111-legN61-2026-09-13 work
mkcmdline 102 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-222-legN62-2026-09-13 work
mkcmdline 103 claude --model claude-fable-5-1 --autocompact auto -n HIMMEL-nextleg-2026-09-13A-console work
pgrep_x_stub 101 102 103
out_a="$(run_primary)"; rc_a=$?
if [ "$rc_a" -eq 0 ]; then pass 'two pinned legs + one console exits 0'; else fail "exits 0 (rc=$rc_a)"; fi
contains 'two pinned legs + one console -> ceiling=ok' "$out_a" 'ceiling=ok'
contains 'per-session line for a pinned leg' "$out_a" 'HIMMEL-111-legN61-2026-09-13 200000'
contains 'per-session line for the console' "$out_a" 'HIMMEL-nextleg-2026-09-13A-console auto'

# (b) one leg with --autocompact auto -> DRIFT naming it
mkcmdline 104 claude --model claude-sonnet-5 --autocompact auto -n HIMMEL-333-legN63-2026-09-13 work
pgrep_x_stub 104
out_b="$(run_primary)"
contains 'a leg with --autocompact auto is DRIFT' "$out_b" 'ceiling=DRIFT:HIMMEL-333-legN63-2026-09-13'

# (c) a leg with no --autocompact at all -> DRIFT
mkcmdline 105 claude --model claude-sonnet-5 -n HIMMEL-444-legN64-2026-09-13 work
pgrep_x_stub 105
out_c="$(run_primary)"
contains 'a leg with no --autocompact at all is DRIFT' "$out_c" 'ceiling=DRIFT:HIMMEL-444-legN64-2026-09-13'
contains 'a leg with no --autocompact prints unset' "$out_c" 'HIMMEL-444-legN64-2026-09-13 unset'

# (d) a non-leg non-console `claude -n foo --autocompact auto` -> DRIFT
mkcmdline 106 claude --autocompact auto -n foo work
pgrep_x_stub 106
out_d="$(run_primary)"
contains 'a non-leg non-console name with auto is DRIFT' "$out_d" 'ceiling=DRIFT:foo'

# (e) the console row alone -> ok
mkcmdline 107 claude --model claude-fable-5-1 --autocompact auto -n HIMMEL-nextleg-2026-09-13B-console work
pgrep_x_stub 107
out_e="$(run_primary)"
contains 'the console row alone is ok' "$out_e" 'ceiling=ok'

# (f) pgrep itself fails (rc>1, a scan failure, not "no processes") -> ceiling=?
# (HIMMEL-2974, codex-1 round 1: a scan failure must not read as ceiling=ok).
# HIMMEL-3002: pgrep's own real fatal-error rc is ALSO 3 (e.g. OOM), same
# value claude_sessions() now returns for "scan completed but degraded" --
# this deliberately exercises that exact collision: an early pgrep failure
# prints NOTHING before returning, so ceiling-conformance.sh must still
# report ceiling=? here rather than misreading the empty table as a
# (vacuously) degraded-but-empty scan.
cat > "$W/bin/pgrep" <<'STUB'
#!/usr/bin/env bash
exit 3
STUB
chmod +x "$W/bin/pgrep"
out_f="$(run_primary)"; rc_f=$?
if [ "$rc_f" -eq 0 ]; then pass 'a pgrep scan failure still exits 0'; else fail "exits 0 (rc=$rc_f)"; fi
contains 'a pgrep scan failure (not "no processes") reports ceiling=?' "$out_f" 'ceiling=?'

# (g) pgrep genuinely finds nothing (rc=1) -> ceiling=ok, unchanged
cat > "$W/bin/pgrep" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$W/bin/pgrep"
out_g="$(run_primary)"
contains 'pgrep rc=1 (no processes matched) still reports ceiling=ok' "$out_g" 'ceiling=ok'

# (h) HIMMEL-2999: a real --autocompact auto leg whose -p free text contains
# the literal substring "--autocompact 200000" must still report auto/DRIFT
# -- the spoof text is one argv element, never the literal flag token.
mkcmdline 108 claude --model claude-sonnet-5 --autocompact auto -n HIMMEL-555-legN70-2026-09-13 \
    -p 'notes: use --autocompact 200000 here' work
pgrep_x_stub 108
out_h="$(run_primary)"
contains 'a spoofed --autocompact in free-text argv does not override the real value' "$out_h" 'HIMMEL-555-legN70-2026-09-13 auto'
contains 'the spoofed leg still reports its real DRIFT' "$out_h" 'ceiling=DRIFT:HIMMEL-555-legN70-2026-09-13'

# (i) HIMMEL-2999: /proc absent (CLAUDE_SESSIONS_PROC pointing nowhere) falls
# back to the old flattened `pgrep -af` parse -- same scenario as (a), old
# stub shape, kept byte-identical.
cat > "$W/bin/pgrep" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' \
  '101 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-111-legN61-2026-09-13 work' \
  '102 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-222-legN62-2026-09-13 work' \
  '103 claude --model claude-fable-5-1 --autocompact auto -n HIMMEL-nextleg-2026-09-13A-console work'
STUB
chmod +x "$W/bin/pgrep"
out_i="$(CLAUDE_SESSIONS_PROC="$W/no-such-proc" PATH="$W/bin:$PATH" bash "$SUT")"
contains 'the /proc-absent fallback still reports ceiling=ok' "$out_i" 'ceiling=ok'
contains 'the /proc-absent fallback still prints a pinned leg line' "$out_i" 'HIMMEL-111-legN61-2026-09-13 200000'

# (j) HIMMEL-2999: claude_sessions() unit row -- a fake proc root with two
# processes prints exactly two TAB lines with the right fields (cmdline
# files for pids 107/108 are still on disk from scenarios (e)/(h) above).
pgrep_x_stub 107 108
sess_out="$(CLAUDE_SESSIONS_PROC="$W/proc" PATH="$W/bin:$PATH" bash -c '
    . "'"$HERE"'/lib/claude-sessions.sh"
    claude_sessions
')"
sess_lines="$(printf '%s\n' "$sess_out" | grep -c .)"
if [ "$sess_lines" -eq 2 ]; then pass 'claude_sessions prints exactly two rows'; else fail "claude_sessions prints exactly two rows (got $sess_lines)"; fi
contains 'claude_sessions row for the pinned leg' "$sess_out" $'108\tHIMMEL-555-legN70-2026-09-13\tclaude-sonnet-5\tauto'
contains 'claude_sessions row for the console' "$sess_out" $'HIMMEL-nextleg-2026-09-13B-console\tclaude-fable-5-1\tauto'

# (k) HIMMEL-2999 CR round 1 (codex-1, Critical): a -p value containing a
# LITERAL embedded newline byte must not split into fake argv tokens -- the
# real --autocompact (auto) must survive, not be overwritten by the "200000"
# that a tr '\0' '\n' conversion would expose as a fake trailing token.
mkcmdline 109 claude --model claude-sonnet-5 --autocompact auto -n HIMMEL-666-legN80-2026-09-13 \
    -p $'notes\n--autocompact\n200000' work
pgrep_x_stub 109
out_k="$(run_primary)"
contains 'an embedded newline in a -p value does not overwrite the real autocompact value' "$out_k" 'HIMMEL-666-legN80-2026-09-13 auto'
contains 'the embedded-newline leg still reports its real DRIFT' "$out_k" 'ceiling=DRIFT:HIMMEL-666-legN80-2026-09-13'

# (l) HIMMEL-2999 CR round 1 (codex-2, Important): a value-bearing flag
# (--append-system-prompt) whose value happens to equal the literal string
# "-n" must not poison the NEXT argv element into being read as -n's value --
# the real -n (HIMMEL-999-legN90-2026-09-13), consumed earlier, must survive.
mkcmdline 110 claude --model claude-sonnet-5 --autocompact auto -n HIMMEL-999-legN90-2026-09-13 \
    --append-system-prompt -n work
pgrep_x_stub 110
out_l="$(run_primary)"
contains 'a flag value that looks like -n does not hijack the following token as the real name' "$out_l" 'HIMMEL-999-legN90-2026-09-13 auto'
contains 'the hijack-attempt leg still reports its real DRIFT' "$out_l" 'ceiling=DRIFT:HIMMEL-999-legN90-2026-09-13'

# (m) HIMMEL-2999 CR round 2 (codex-1, Important): `-p`/`--print` is a bare
# boolean flag (see scripts/probes/claude-p/*.sh -- it never itself takes a
# value) -- treating it as value-bearing swallowed the NEXT real flag's
# value. A real `-n` immediately after a bare `-p` must survive.
mkcmdline 111 claude --model claude-sonnet-5 -p -n HIMMEL-100-legN95-2026-09-13 --autocompact 200000
pgrep_x_stub 111
sess_out_m="$(CLAUDE_SESSIONS_PROC="$W/proc" PATH="$W/bin:$PATH" bash -c '
    . "'"$HERE"'/lib/claude-sessions.sh"
    claude_sessions
')"
contains 'a bare -p boolean flag does not swallow the following --model value' "$sess_out_m" $'111\tHIMMEL-100-legN95-2026-09-13\tclaude-sonnet-5\t200000'

# (n) HIMMEL-2999 CR round 2 (codex-2, Suggestion): a field value carrying a
# literal embedded TAB must not widen the emitted TSV row -- the row must
# always print exactly 4 tab-separated fields.
mkcmdline 112 claude --model claude-sonnet-5 --autocompact 200000 -n $'HIMMEL-300-legN97\t2026-09-13'
pgrep_x_stub 112
sess_out_n="$(CLAUDE_SESSIONS_PROC="$W/proc" PATH="$W/bin:$PATH" bash -c '
    . "'"$HERE"'/lib/claude-sessions.sh"
    claude_sessions
')"
nf_n="$(printf '%s' "$sess_out_n" | awk -F'\t' '{print NF; exit}')"
if [ "$nf_n" -eq 4 ]; then pass 'an embedded TAB in a name value does not widen the TSV row'; else fail "an embedded TAB in a name value does not widen the TSV row (NF=$nf_n)"; fi

# (o) HIMMEL-2999 CR round 3 (codex-2, Suggestion): `--system-prompt` (the
# non-append variant) is a value-bearing free-text flag just like
# `--append-system-prompt` -- a value that happens to equal the literal
# string "-n" must not poison the NEXT argv element into being read as -n's
# value. The real -n (HIMMEL-200-legN99-2026-09-13), consumed earlier, must
# survive.
mkcmdline 113 claude --model claude-sonnet-5 --autocompact auto -n HIMMEL-200-legN99-2026-09-13 \
    --system-prompt -n work
pgrep_x_stub 113
out_o="$(run_primary)"
contains 'a --system-prompt value that looks like -n does not hijack the following token as the real name' "$out_o" 'HIMMEL-200-legN99-2026-09-13 auto'
contains 'the --system-prompt hijack-attempt leg still reports its real DRIFT' "$out_o" 'ceiling=DRIFT:HIMMEL-200-legN99-2026-09-13'

# (p) HIMMEL-3002: pgrep returns a pid that has already vanished from /proc
# by the time we read it (a race, or a stale table) -- no /proc/<pid> dir at
# all. Must print no row for it and must NOT count as scan-degraded -- this
# pins today's behaviour for a genuinely gone process.
pgrep_x_stub 108 999
out_p="$(run_primary)"; rc_p=$?
if [ "$rc_p" -eq 0 ]; then pass 'a vanished pid (no /proc dir) still exits 0'; else fail "exits 0 (rc=$rc_p)"; fi
case "$out_p" in
    *'999'*) fail 'a vanished pid prints no row for it' ;;
    *) pass 'a vanished pid prints no row for it' ;;
esac
case "$out_p" in
    *'scan-degraded'*) fail 'a vanished pid is not reported as scan-degraded' ;;
    *) pass 'a vanished pid is not reported as scan-degraded' ;;
esac

# (q) HIMMEL-3002: an alive pid whose /proc/<pid> dir exists but whose
# cmdline is unreadable (a permission boundary, e.g. hidepid) must not be
# silently treated as vanished -- the scan is reported as degraded, naming
# the pid, and the summary falls back to "cannot tell" (ceiling=?) rather
# than ok/DRIFT over a partial table. The other, readable row must still
# print.
if [ "$(id -u)" = "0" ]; then
    printf 'SKIP - unreadable-cmdline case cannot be simulated as root (chmod 000 is still readable to root)\n'
else
    mkcmdline 114 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-777-legN101-2026-09-13 work
    chmod 000 "$W/proc/114/cmdline"
    if [ -r "$W/proc/114/cmdline" ]; then
        printf 'SKIP - unreadable-cmdline case: chmod 000 did not remove read access here\n'
        chmod 700 "$W/proc/114/cmdline"
    else
        pgrep_x_stub 108 114
        out_q="$(run_primary)"; rc_q=$?
        if [ "$rc_q" -eq 0 ]; then pass 'a degraded scan still exits 0 (report, not a gate)'; else fail "exits 0 (rc=$rc_q)"; fi
        contains 'a scan-degraded pid is named (HIMMEL-3002)' "$out_q" 'scan-degraded:114'
        contains 'a degraded scan reports ceiling=? not ok/DRIFT' "$out_q" 'ceiling=?'
        contains 'a degraded scan still prints the readable row' "$out_q" 'HIMMEL-555-legN70-2026-09-13 auto'
        chmod 700 "$W/proc/114/cmdline"
    fi
fi

# (r) HIMMEL-3008: `-r` passes but the actual read fails -- readability can
# change between the upfront check and the read loop's own `< "$cmdline"`
# redirection. Simplest deterministic stand-in: a directory named `cmdline`
# in a fake /proc/<pid> -- `-r` succeeds on a directory, but reading from it
# fails at read() time (not open() time), so the loop consumes zero tokens
# exactly like case (q)'s permission-denied file. Must be reported the same
# way: a degraded scan naming the pid, rc 3 -- not a phantom empty-fields row
# for a "live" session (the exact bug this ticket closes).
mkdir -p "$W/proc/115/cmdline"
pgrep_x_stub 108 115
sess_out_r="$(CLAUDE_SESSIONS_PROC="$W/proc" PATH="$W/bin:$PATH" bash -c '
    . "'"$HERE"'/lib/claude-sessions.sh"
    claude_sessions
')"
sess_rc_r=$?
if [ "$sess_rc_r" -eq 3 ]; then pass 'a read-fails-after-precheck cmdline returns rc 3'; else fail "returns rc 3 (got $sess_rc_r)"; fi
contains 'a read-fails-after-precheck pid is reported unreadable, not a phantom row' "$sess_out_r" '# unreadable 115'
case "$sess_out_r" in
    *$'115\t'*) fail 'a read-fails-after-precheck pid does not print a data row' ;;
    *) pass 'a read-fails-after-precheck pid does not print a data row' ;;
esac
contains 'a read-fails-after-precheck scan still prints the other readable row' "$sess_out_r" $'108\tHIMMEL-555-legN70-2026-09-13\tclaude-sonnet-5\tauto'
out_r="$(run_primary)"
contains 'ceiling-conformance.sh surfaces the read-fails pid as scan-degraded' "$out_r" 'scan-degraded:115'
contains 'ceiling-conformance.sh reports ceiling=? over a read-fails pid' "$out_r" 'ceiling=?'

# (s) HIMMEL-3008 design: a live pid whose cmdline is empty is not the same
# fact as a permission race -- a zombie (already exited, not yet reaped)
# reads back a genuinely empty (0-byte) cmdline with no error at all. It must
# not be printed as a phantom empty-fields row, but it is not a readability
# failure either -- silent, rc 0, "not a row" for a different reason than
# case (p)'s vanished pid (empty content, not a missing /proc/<pid> dir).
mkdir -p "$W/proc/116"
: > "$W/proc/116/cmdline"
pgrep_x_stub 116
sess_out_s="$(CLAUDE_SESSIONS_PROC="$W/proc" PATH="$W/bin:$PATH" bash -c '
    . "'"$HERE"'/lib/claude-sessions.sh"
    claude_sessions
')"
sess_rc_s=$?
if [ "$sess_rc_s" -eq 0 ]; then pass 'a zero-token empty cmdline on a live pid returns rc 0'; else fail "returns rc 0 (got $sess_rc_s)"; fi
if [ -z "$sess_out_s" ]; then pass 'a zero-token empty cmdline on a live pid prints nothing'; else fail "prints nothing (got '$sess_out_s')"; fi
out_s="$(run_primary)"
contains 'ceiling-conformance.sh still reports ceiling=ok over a zero-token empty cmdline' "$out_s" 'ceiling=ok'
case "$out_s" in
    *'scan-degraded'*) fail 'a zero-token empty cmdline on a live pid is not reported as scan-degraded' ;;
    *) pass 'a zero-token empty cmdline on a live pid is not reported as scan-degraded' ;;
esac

if [ "$fails" -eq 0 ]; then
    printf '%s\n' 'PASS - test-ceiling-conformance.sh'
    exit 0
fi
printf 'FAIL - test-ceiling-conformance.sh (%s failure(s))\n' "$fails"
exit 1
