#!/usr/bin/env bash
# Tests for guard-relay-writes.sh (HIMMEL-2975 Task 26, Guard D): the relay's
# write-deny fence on console inbox writes, leg handover docs, the console
# rundir, and the env-override / inbox-send --token Bash shapes that would
# defeat Guards B/C. Every row runs twice — HIMMEL_CONSOLE_RELAY=1 (expect
# the documented rc) and unset (expect a silent allow, rc=0/empty) — to pin
# the marker-gated no-op contract.
#
# Usage: bash scripts/hooks/test-guard-relay-writes.sh
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Pure bash + jq over a temp sandbox; NOT ported to native PowerShell — see
# guard-relay-writes.sh's own header for why (the relay lane is Linux-only).
set -uo pipefail

grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/guard-relay-writes.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK" 2>/dev/null || true

# Resolve bash ONCE from the suite's own unmodified PATH — see
# test-guard-subagent-model.sh's identical BASH_ABS rationale (HIMMEL-1567).
BASH_ABS=$(command -v bash)
[ -n "$BASH_ABS" ] || { echo "FATAL: cannot resolve bash on PATH" >&2; exit 1; }

# The fixture path is pid-derived (digits only), NOT a random mktemp suffix: the
# guard matches write verbs over the whole command text, and a random suffix can
# spell one (HIMMEL-3202: `...guard.mVddVZ` contains "dd"). Verb-free = the
# fixture can never be the cause of a row's result.
TMP="${TMPDIR:-/tmp}/himmel-relay-guard-fixture.$$"
mkdir "$TMP" || { echo "FATAL: mkdir $TMP failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

ROOT="$TMP/root"
mkdir -p "$ROOT/inbox" "$ROOT/yotamleo/himmel"

pass=0
fail=0

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "ok   $label (rc=$actual)"
        pass=$((pass + 1))
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        fail=$((fail + 1))
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if grepq "$haystack" -F "$needle"; then
        echo "ok   $label"
        pass=$((pass + 1))
    else
        echo "FAIL $label — missing '$needle'"
        echo "  actual: $haystack"
        fail=$((fail + 1))
    fi
}

assert_empty() {
    local label="$1" actual="$2"
    if [ -z "$actual" ]; then
        echo "ok   $label"
        pass=$((pass + 1))
    else
        echo "FAIL $label — expected empty, got: $actual"
        fail=$((fail + 1))
    fi
}

write_payload() {
    # write_payload <tool_name> <file_path>
    jq -nc --arg tn "$1" --arg p "$2" '{tool_name:$tn, tool_input:{file_path:$p}}'
}

bash_payload() {
    jq -nc --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}'
}

read_payload() {
    jq -nc --arg p "$1" '{tool_name:"Read", tool_input:{file_path:$p}}'
}

run_relay() {
    local name="$1" json="$2"
    printf '%s' "$json" | env HANDOVER_DIR="$ROOT" HIMMEL_CONSOLE_RELAY=1 "$BASH_ABS" "$HOOK" >"$TMP/out-$name" 2>"$TMP/err-$name"
    echo "$?"
}

run_norelay() {
    local name="$1" json="$2"
    printf '%s' "$json" | env -u HIMMEL_CONSOLE_RELAY HANDOVER_DIR="$ROOT" "$BASH_ABS" "$HOOK" >"$TMP/out-$name" 2>"$TMP/err-$name"
    echo "$?"
}

combined_output() {
    cat "$TMP/out-$1" "$TMP/err-$1" 2>/dev/null
}

INBOX_X="$ROOT/inbox/X.md"
LEG_DOC="$ROOT/yotamleo/himmel/HIMMEL-1-a-legN9-2026-09-12-RESUME.md"
RUNDIR_LOG="/run/user/1000/himmel-console/s/inbox-sent.log"
OWN_DOC="$ROOT/yotamleo/himmel/HIMMEL-1-relay-2026-09-12-RESUME.md"
EXTERNAL_LEG_DOC="/home/u/luna/handovers/a-legN3-2026-09-12-RESUME.md"

TRAVERSAL_INBOX="$ROOT/other/../inbox/X.md"
DOTSLASH_INBOX="$ROOT/./inbox/X.md"

# A final-component symlink OUTSIDE every guarded dir whose target resolves
# INTO the inbox (round-3 codex-1: a dir-only resolution missed exactly this).
SYMLINK_INTO_INBOX="$TMP/looks-safe.md"
ln -s "$INBOX_X" "$SYMLINK_INTO_INBOX"

# name|json|expect_rc_relay|expect_rc_norelay
ROWS_NAME=(row1 row2 row3 row4 row5 row6 row7 row8 row9 row10a row10b row10c row10d row11 row12 row13 row14 row15 row16 row17 row18 row19 row20
    read-tee read-cp read-mv read-rm read-rsync read-dd read-truncate read-sed read-install read-chmod read-chown read-address read-legdoc-form
    write-dd write-abs-rm write-sudo-rm write-rmdir write-cpio write-ddrescue write-xargs-rm write-paren-cp write-semi-mv write-sed-i write-tee write-install write-rsync write-chown write-chmod write-truncate write-newline-rm)
ROWS_JSON=(
    "$(write_payload Write "$INBOX_X")"
    "$(write_payload Edit "$LEG_DOC")"
    "$(write_payload Write "$RUNDIR_LOG")"
    "$(write_payload Edit "$OWN_DOC")"
    "$(bash_payload "echo x >> $ROOT/inbox/X.md")"
    "$(bash_payload "printf x | tee -a $EXTERNAL_LEG_DOC")"
    "$(bash_payload "bash scripts/handover/console-kit/inbox-send.sh S halt")"
    "$(bash_payload "bash scripts/handover/console-kit/inbox-send.sh S go --token t")"
    "$(bash_payload "HIMMEL_CONSOLE_RELAY= bash inbox-send.sh S x")"
    "$(bash_payload "CLAUDE_PID=1 bash x.sh")"
    "$(bash_payload "CONSOLE_SESSION_NAME=j bash x.sh")"
    "$(bash_payload "SESSION_NAME_CMDLINE_FILE=f bash x.sh")"
    "$(bash_payload "env -u HIMMEL_CONSOLE_LEG bash x.sh")"
    "$(bash_payload "cat $ROOT/inbox/X.md")"
    "$(write_payload Write "$TRAVERSAL_INBOX")"
    "$(bash_payload "cp x $ROOT/inbox/X.md")"
    "$(bash_payload "rm $RUNDIR_LOG")"
    "$(write_payload Write "$DOTSLASH_INBOX")"
    "$(bash_payload "unset CLAUDE_PID CONSOLE_SESSION_NAME; bash inbox-send.sh S x")"
    "$(bash_payload "env -u CLAUDE_PID bash inbox-send.sh S x")"
    "$(write_payload Write "$SYMLINK_INTO_INBOX")"
    "$(bash_payload "rm -rf $ROOT/inbox")"
    "$(bash_payload "mv $ROOT/inbox /tmp/saved")"
    # HIMMEL-3202: a READ of a guarded path whose TEXT merely contains a write
    # verb letter-sequence INSIDE a longer word (teeny/acpx/xmvx/form/…) must
    # allow — the verb match is a command WORD, not a substring.
    "$(bash_payload "cat $ROOT/inbox/teeny.md")"
    "$(bash_payload "cat $ROOT/inbox/acpx.md")"
    "$(bash_payload "cat $ROOT/inbox/xmvx.md")"
    "$(bash_payload "cat $ROOT/inbox/form.md")"
    "$(bash_payload "cat $ROOT/inbox/rsyncx.md")"
    "$(bash_payload "cat $ROOT/inbox/guard.mVddVZ.md")"
    "$(bash_payload "cat $ROOT/inbox/truncatex.md")"
    "$(bash_payload "cat $ROOT/inbox/used.md")"
    "$(bash_payload "cat $ROOT/inbox/installx.md")"
    "$(bash_payload "cat $ROOT/inbox/chmodx.md")"
    "$(bash_payload "cat $ROOT/inbox/chownx.md")"
    "$(bash_payload "grep -c address $ROOT/inbox/X.md")"
    "$(bash_payload "cat $ROOT/yotamleo/himmel/HIMMEL-1-form-legN9-2026-09-12-RESUME.md")"
    # ...while a REAL verb stays denied in every shape a command word can take
    # (bare, absolute path, after sudo/xargs, in a subshell, after ; or a newline).
    "$(bash_payload "dd of=$ROOT/inbox/X.md if=/dev/null")"
    "$(bash_payload "/bin/rm $ROOT/inbox/X.md")"
    "$(bash_payload "sudo rm -f $ROOT/inbox/X.md")"
    "$(bash_payload "rmdir $ROOT/inbox")"
    "$(bash_payload "echo x | cpio -p $ROOT/inbox")"
    "$(bash_payload "ddrescue x $ROOT/inbox/X.md")"
    "$(bash_payload "ls | xargs rm $ROOT/inbox/X.md")"
    "$(bash_payload "(cp x $ROOT/inbox/X.md)")"
    "$(bash_payload "true;mv x $ROOT/inbox/X.md")"
    "$(bash_payload "sed -i s/a/b/ $ROOT/inbox/X.md")"
    "$(bash_payload "printf x | tee $ROOT/inbox/X.md")"
    "$(bash_payload "install -m 600 x $ROOT/inbox/X.md")"
    "$(bash_payload "rsync x $ROOT/inbox/")"
    "$(bash_payload "chown u $ROOT/inbox/X.md")"
    "$(bash_payload "chmod 000 $ROOT/inbox/X.md")"
    "$(bash_payload "truncate -s0 $ROOT/inbox/X.md")"
    "$(bash_payload "cat $ROOT/inbox/X.md
rm $ROOT/inbox/Y.md")"
)
ROWS_EXPECT=(2 2 2 0 2 2 0 2 2 2 2 2 2 0 2 2 2 2 2 2 2 2 2
    0 0 0 0 0 0 0 0 0 0 0 0 0
    2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2)

echo "=== marker set (HIMMEL_CONSOLE_RELAY=1) ==="
i=0
while [ "$i" -lt "${#ROWS_NAME[@]}" ]; do
    name="${ROWS_NAME[$i]}"
    json="${ROWS_JSON[$i]}"
    expect="${ROWS_EXPECT[$i]}"
    rc=$(run_relay "relay-$name" "$json")
    assert_rc "relay $name" "$expect" "$rc"
    if [ "$expect" = "2" ]; then
        assert_contains "relay $name deny reason" "relay write-deny:" "$(cat "$TMP/out-relay-$name")"
        assert_contains "relay $name deny decision" '"permissionDecision":"deny"' "$(cat "$TMP/out-relay-$name")"
    else
        assert_empty "relay $name allow: no output" "$(combined_output "relay-$name")"
    fi
    i=$((i + 1))
done

echo ""
echo "=== marker unset — every row is a silent no-op (rc=0, empty) ==="
i=0
while [ "$i" -lt "${#ROWS_NAME[@]}" ]; do
    name="${ROWS_NAME[$i]}"
    json="${ROWS_JSON[$i]}"
    rc=$(run_norelay "norelay-$name" "$json")
    assert_rc "norelay $name" 0 "$rc"
    assert_empty "norelay $name: no output" "$(combined_output "norelay-$name")"
    i=$((i + 1))
done

echo ""
echo "=== fail-closed / non-write edge cases (marker set) ==="

RC_MALFORMED=$(run_relay malformed "not-json{{{")
assert_rc "malformed stdin denies under the marker (rc=2)" 2 "$RC_MALFORMED"
assert_contains "malformed stdin deny reason" "relay write-deny:" "$(cat "$TMP/out-malformed")"

RC_READ=$(run_relay read-tool "$(read_payload "$INBOX_X")")
assert_rc "Read tool on inbox path allows (rc=0)" 0 "$RC_READ"
assert_empty "Read tool: no output" "$(combined_output read-tool)"

RC_NUM_PATH=$(run_relay num-path "$(jq -nc '{tool_name:"Write", tool_input:{file_path:5}}')")
assert_rc "non-string file_path denies (rc=2)" 2 "$RC_NUM_PATH"
assert_contains "non-string file_path deny reason" "relay write-deny:" "$(cat "$TMP/out-num-path")"

RC_NUM_CMD=$(run_relay num-cmd "$(jq -nc '{tool_name:"Bash", tool_input:{command:5}}')")
assert_rc "non-string command denies (rc=2)" 2 "$RC_NUM_CMD"
assert_contains "non-string command deny reason" "relay write-deny:" "$(cat "$TMP/out-num-cmd")"

NO_HANDOVER_DIR="$TMP/does-not-exist"
printf '%s' "$(write_payload Write "$ROOT/some-file.md")" \
    | env HANDOVER_DIR="$NO_HANDOVER_DIR" HIMMEL_CONSOLE_RELAY=1 "$BASH_ABS" "$HOOK" \
    >"$TMP/out-root-fail" 2>"$TMP/err-root-fail"
RC_ROOT_FAIL="$?"
assert_rc "handover_root failure denies fail-closed (rc=2)" 2 "$RC_ROOT_FAIL"
assert_contains "handover_root failure deny reason" "handover-root-unresolved" "$(cat "$TMP/out-root-fail")"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
