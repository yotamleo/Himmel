#!/usr/bin/env bash
# Tests for scripts/lib/clean-sandbox.sh (HIMMEL-3321).
# Usage: bash scripts/lib/test-clean-sandbox.sh
# Hermetic: every launch gets a scratch dir under a mktemp root; the operator's
# real ~/.himmel/provenance.jsonl is hashed before and after and must not move.
# Platform guard (linux/macos-only): POSIX bash 3.2+, same as clean-sandbox.sh -
# no .ps1 twin; a test fixture needs none (WS5 T15 convention).
set -uo pipefail

LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
SB="$LIB_DIR/clean-sandbox.sh"

PASSED=0
FAILED=0
ok()   { echo "PASS $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }
assert_eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 — expected '$2', got '$3'"; fi
}
assert_contains() {
    case "$3" in *"$2"*) ok "$1" ;; *) fail "$1 — '$2' not in: $3" ;; esac
}
assert_not_contains() {
    case "$3" in *"$2"*) fail "$1 — '$2' unexpectedly in: $3" ;; *) ok "$1" ;; esac
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/clean-sandbox-test.XXXXXX") || { echo "FAIL could not create temp dir"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

real_prov="$HOME/.himmel/provenance.jsonl"
prov_state() { if [ -e "$real_prov" ]; then sha256sum "$real_prov" 2>/dev/null | cut -d' ' -f1; else echo absent; fi; }
PROV_BEFORE=$(prov_state)

# Caller env the launcher must NOT leak. Exported for every case below.
export HANDOVER_DIR=/x JIRA_API_TOKEN=y

# T0: the naive hand-rolled form leaks both (the control: proves the leak is
# real in this env, so the launcher assertions below can fail).
naive=$(HOME="$TMP/naive-home" env)
assert_contains "T0 naive 'HOME=... cmd' leaks HANDOVER_DIR" "HANDOVER_DIR=/x" "$naive"
assert_contains "T0 naive 'HOME=... cmd' leaks JIRA_API_TOKEN" "JIRA_API_TOKEN=y" "$naive"

# T1: the launcher's child sees neither.
if [ ! -f "$SB" ]; then
    fail "T1 launcher exists at $SB"
    out=""
else
    out=$(bash "$SB" --scratch "$TMP/s1" -- env 2>/dev/null)
fi
assert_not_contains "T1 child does not see HANDOVER_DIR" "HANDOVER_DIR" "$out"
assert_not_contains "T1 child does not see JIRA_API_TOKEN" "JIRA_API_TOKEN" "$out"
assert_contains "T1 control: child ran and printed env" "HOME=" "$out"

# T2: scratch HOME/PATH/cache dirs, and they exist.
assert_contains "T2 HOME is <scratch>/home" "HOME=$TMP/s1/home" "$out"
assert_contains "T2 HIMMEL_PROVENANCE_DIR is <scratch>/prov" "HIMMEL_PROVENANCE_DIR=$TMP/s1/prov" "$out"
assert_contains "T2 HIMMELCTL_CACHE_DIR is <scratch>/cache" "HIMMELCTL_CACHE_DIR=$TMP/s1/cache" "$out"
assert_contains "T2 TMPDIR is <scratch>/tmp" "TMPDIR=$TMP/s1/tmp" "$out"
assert_contains "T2 PATH is the minimal system PATH" "PATH=/usr/local/bin:/usr/bin:/bin" "$out"
dirs_ok=yes
for d in home prov cache tmp; do [ -d "$TMP/s1/$d" ] || dirs_ok="no ($d)"; done
assert_eq "T2 scratch subdirs exist" yes "$dirs_ok"
# The child sees exactly the five launcher vars and nothing else.
names=$(printf '%s\n' "$out" | sed 's/=.*//' | LC_ALL=C sort | tr '\n' ' ')
assert_eq "T2 child env is exactly the launcher-owned five" \
    "HIMMELCTL_CACHE_DIR HIMMEL_PROVENANCE_DIR HOME PATH TMPDIR " "$names"

# T3: --keep passes a named var; an unkept one stays out.
export KEEPME=bar UNKEPT=baz
out3=$(bash "$SB" --scratch "$TMP/s3" --keep KEEPME -- env 2>/dev/null)
assert_contains "T3 --keep KEEPME reaches the child" "KEEPME=bar" "$out3"
assert_not_contains "T3 an unkept var stays out" "UNKEPT" "$out3"

# T4: --keep HANDOVER_DIR refuses without --allow-handover-dir; the child never runs.
marker="$TMP/ran-marker"
bash "$SB" --scratch "$TMP/s4" --keep HANDOVER_DIR -- touch "$marker" >/dev/null 2>"$TMP/e4"
rc4=$?
assert_eq "T4 --keep HANDOVER_DIR without the allow flag exits non-zero" "yes" "$([ "$rc4" -ne 0 ] && echo yes || echo "no rc=$rc4")"
assert_eq "T4 the refused launch never ran the child" absent "$([ -e "$marker" ] && echo ran || echo absent)"
assert_contains "T4 the refusal names --allow-handover-dir" "--allow-handover-dir" "$(cat "$TMP/e4")"
out4=$(bash "$SB" --scratch "$TMP/s4b" --keep HANDOVER_DIR --allow-handover-dir -- env 2>/dev/null)
assert_contains "T4 with --allow-handover-dir it is passed" "HANDOVER_DIR=/x" "$out4"

# T5: the printed env masks TOKEN|KEY|SECRET|PASS values; the child gets the real value.
export SB_API_TOKEN=tok-value-1 SB_SSH_KEY=key-value-2 SB_CLIENT_SECRET=sec-value-3 SB_DB_PASSWORD=pw-value-4 PLAIN_NAME=plain-value-5
err5=$(bash "$SB" --scratch "$TMP/s5" --keep SB_API_TOKEN --keep SB_SSH_KEY --keep SB_CLIENT_SECRET --keep SB_DB_PASSWORD --keep PLAIN_NAME -- env 2>&1 >"$TMP/o5")
for v in tok-value-1 key-value-2 sec-value-3 pw-value-4; do
    assert_not_contains "T5 printed env hides $v" "$v" "$err5"
done
assert_contains "T5 printed env still names SB_API_TOKEN" "SB_API_TOKEN=" "$err5"
assert_contains "T5 a non-secret value is printed" "PLAIN_NAME=plain-value-5" "$err5"
assert_contains "T5 the child received the real token" "SB_API_TOKEN=tok-value-1" "$(cat "$TMP/o5")"

# T6: the printed env lists exactly the names the child sees.
printed=$(printf '%s\n' "$err5" | grep -E '^ +[A-Za-z_][A-Za-z0-9_]*=' | sed 's/^ *//; s/=.*//' | LC_ALL=C sort | tr '\n' ' ')
seen=$(sed 's/=.*//' "$TMP/o5" | LC_ALL=C sort | tr '\n' ' ')
assert_eq "T6 control: the child's env is non-empty" yes "$([ -n "${seen// /}" ] && echo yes || echo no)"
assert_eq "T6 printed env names equal the child's env names" "$seen" "$printed"

# T7: --scratch reuses the given directory; without it a fresh one is made.
mkdir -p "$TMP/reused"
bash "$SB" --scratch "$TMP/reused" -- true 2>/dev/null
assert_eq "T7 --scratch DIR is used" yes "$([ -d "$TMP/reused/home" ] && echo yes || echo no)"
out7=$(TMPDIR="$TMP" bash "$SB" -- env 2>/dev/null)
home7=$(printf '%s\n' "$out7" | sed -n 's/^HOME=//p')
assert_eq "T7 no --scratch: an auto-created scratch home exists" yes "$([ -d "$home7" ] && echo yes || echo no)"
assert_contains "T7 no --scratch: the auto scratch is under TMPDIR" "$TMP/" "$home7"

# T7b: a relative --scratch is made absolute, so a child that changes directory
# still resolves HOME/TMPDIR into the scratch dir (panel finding codex-1).
mkdir -p "$TMP/relcwd"
out7b=$(cd "$TMP/relcwd" && bash "$SB" --scratch relscratch -- env 2>/dev/null)
assert_contains "T7b relative --scratch: HOME is absolute" "HOME=$TMP/relcwd/relscratch/home" "$out7b"
assert_contains "T7b relative --scratch: TMPDIR is absolute" "TMPDIR=$TMP/relcwd/relscratch/tmp" "$out7b"

# T8: usage errors exit 2.
bash "$SB" --scratch "$TMP/s8" -- >/dev/null 2>&1; assert_eq "T8 no command after -- exits 2" 2 $?
bash "$SB" --scratch "$TMP/s8" env >/dev/null 2>&1; assert_eq "T8 missing -- exits 2" 2 $?
bash "$SB" --bogus -- env >/dev/null 2>&1; assert_eq "T8 unknown flag exits 2" 2 $?
bash "$SB" --keep 'bad name' -- env >/dev/null 2>&1; assert_eq "T8 invalid var name exits 2" 2 $?

# T9: launcher-owned vars cannot be kept.
for v in HOME PATH TMPDIR HIMMEL_PROVENANCE_DIR HIMMELCTL_CACHE_DIR; do
    bash "$SB" --scratch "$TMP/s9" --keep "$v" -- true >/dev/null 2>&1
    assert_eq "T9 --keep $v is refused (launcher-owned)" 2 $?
done

# T10: a --keep var that is unset in the caller is not passed (and not faked).
unset NOT_SET_HERE 2>/dev/null
out10=$(bash "$SB" --scratch "$TMP/s10" --keep NOT_SET_HERE -- env 2>/dev/null)
assert_not_contains "T10 an unset kept var is not passed" "NOT_SET_HERE" "$out10"

# T11: the child's exit code is the launcher's.
bash "$SB" --scratch "$TMP/s11" -- sh -c 'exit 7' >/dev/null 2>&1
assert_eq "T11 child exit code propagates" 7 $?

# T12: the operator's real provenance file did not move.
assert_eq "T12 real provenance.jsonl untouched" "$PROV_BEFORE" "$(prov_state)"

echo "----"
echo "clean-sandbox: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
