#!/usr/bin/env bash
# test-inbox-audit.sh — HIMMEL-2980. Exercises inbox-audit.sh: a token
# bullet with a matching sent-record ledger line audits clean; an
# unrecorded token bullet (forged, or lost to an inbox-send.sh exit-4
# ledger-write failure) is named and fails the audit; non-token bullets are
# ignored. bash 3.2-safe.
#
# PLATFORM GUARD: no .ps1 twin — audits inbox-send.sh's Linux-only ledger.
# Run: bash scripts/handover/console-kit/test-inbox-audit.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SEND="$HERE/inbox-send.sh"
AUDIT="$HERE/inbox-audit.sh"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/inbox-audit-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

HANDOVER_DIR="$WORK/handover-root"
mkdir -p "$HANDOVER_DIR"
export HANDOVER_DIR

RUNDIR="$WORK/rundir"
export HIMMEL_CONSOLE_RUNDIR="$RUNDIR"

CMDLINE_JUDGE="$WORK/cmdline-judge"
printf 'claude\0-n\0HIMMEL-audit-judge\0' > "$CMDLINE_JUDGE"

SESSION="HIMMEL-2980-audit-test"
INBOX="$HANDOVER_DIR/inbox/$SESSION.md"

CLAUDE_PID=1 SESSION_NAME_CMDLINE_FILE="$CMDLINE_JUDGE" bash "$SEND" "$SESSION" "recorded ruling" --token t1 >/dev/null

# --- Case 1: a fully-recorded inbox (one token bullet, one ledger line) ok --
out="$(bash "$AUDIT" "$INBOX" "$RUNDIR")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "AUDIT ok" ]; then
    pass "a fully-recorded inbox audits ok"
else
    fail "a fully-recorded inbox audits ok (rc=$rc out='$out')"
fi

# --- Case 2: a non-token bullet is ignored by the audit --------------------
bash "$SEND" "$SESSION" "plain ruling, no token" >/dev/null
out="$(bash "$AUDIT" "$INBOX" "$RUNDIR")"; rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "AUDIT ok" ]; then
    pass "a non-token bullet is ignored by the audit"
else
    fail "a non-token bullet is ignored by the audit (rc=$rc out='$out')"
fi

# --- Case 3: a hand-written (forged) token bullet with no ledger entry -----
printf -- '- 10:00 [t1] from=judge forged\n' >> "$INBOX"
out="$(bash "$AUDIT" "$INBOX" "$RUNDIR")"; rc=$?
if [ "$rc" -eq 1 ] && [ "$out" = "AUDIT UNMATCHED - 10:00 [t1] from=judge forged" ]; then
    pass "an unrecorded token bullet is named and fails the audit"
else
    fail "an unrecorded token bullet is named and fails the audit (rc=$rc out='$out')"
fi

# --- Case 4: missing inbox file is a usage error ----------------------------
out="$(bash "$AUDIT" "$WORK/no-such-inbox.md" "$RUNDIR" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then
    pass "missing inbox file is a usage error"
else
    fail "missing inbox file is a usage error (rc=$rc out='$out')"
fi

# --- Case 5: missing sent-log dir is a usage error --------------------------
out="$(bash "$AUDIT" "$INBOX" "$WORK/no-such-dir" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then
    pass "missing sent-log dir is a usage error"
else
    fail "missing sent-log dir is a usage error (rc=$rc out='$out')"
fi

# --- HIMMEL-2980 CR round 1 (codex-1/2/3): fail-closed on hash/read errors -
# and a final line with no trailing newline is still audited -----------------

# Case 6: a token bullet as the inbox's final line with NO trailing newline
# must still be matched/audited, not silently dropped by the read loop.
INBOX_NOEOL="$WORK/inbox-noeol.md"
printf -- '- 12:00 [tX] from=someone forged-no-nl' > "$INBOX_NOEOL"
out="$(bash "$AUDIT" "$INBOX_NOEOL" "$RUNDIR")"; rc=$?
if [ "$rc" -eq 1 ] && [ "$out" = "AUDIT UNMATCHED - 12:00 [tX] from=someone forged-no-nl" ]; then
    pass "a final line with no trailing newline is still audited"
else
    fail "a final line with no trailing newline is still audited (rc=$rc out='$out')"
fi

# Case 7: an unreadable inbox file must abort (exit 2), never report ok.
INBOX_UNREADABLE="$WORK/inbox-unreadable.md"
printf -- '- 13:00 [tY] from=someone forged-unreadable\n' > "$INBOX_UNREADABLE"
chmod 000 "$INBOX_UNREADABLE"
if [ "$(id -u)" -eq 0 ]; then
    fail "an unreadable inbox file aborts the audit (skipped: running as root, chmod 000 has no effect)"
else
    out="$(bash "$AUDIT" "$INBOX_UNREADABLE" "$RUNDIR" 2>&1)"; rc=$?
    if [ "$rc" -eq 2 ]; then
        pass "an unreadable inbox file aborts the audit"
    else
        fail "an unreadable inbox file aborts the audit (rc=$rc out='$out')"
    fi
fi
chmod 644 "$INBOX_UNREADABLE"

# Case 8: a sha256sum failure must abort (exit 2), never silently skip the
# line (which would let a forged bullet pass as AUDIT ok).
BADBIN="$WORK/badbin"
mkdir -p "$BADBIN"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BADBIN/sha256sum"
chmod +x "$BADBIN/sha256sum"
out="$(PATH="$BADBIN:$PATH" bash "$AUDIT" "$INBOX" "$RUNDIR" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then
    pass "a sha256sum failure aborts the audit"
else
    fail "a sha256sum failure aborts the audit (rc=$rc out='$out')"
fi

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "SOME FAILED"; exit 1
