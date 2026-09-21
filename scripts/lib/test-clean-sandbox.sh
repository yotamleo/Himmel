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
# sha256 of $1, or nothing when no hasher works (sha256sum on linux, shasum on
# macOS). Builtins only, so it still runs (and reports nothing) on a bare PATH.
file_hash() {
    local out
    if command -v sha256sum >/dev/null 2>&1; then
        out=$(sha256sum "$1" 2>/dev/null) || return 0
    elif command -v shasum >/dev/null 2>&1; then
        out=$(shasum -a 256 "$1" 2>/dev/null) || return 0
    else
        return 0
    fi
    echo "${out%% *}"
}
# The file's sha256, "absent", or UNHASHABLE for a present file no hasher could
# read - never an empty string, which two snapshots would "agree" on vacuously.
prov_state() {
    local h
    [ -e "$1" ] || { echo absent; return 0; }
    h=$(file_hash "$1")
    if [ -n "$h" ]; then echo "$h"; else echo UNHASHABLE; fi
}
PROV_BEFORE=$(prov_state "$real_prov")

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

# T3b: --keep passes the value byte-exact - trailing newlines survive (HIMMEL-3367;
# a bare $(printenv VAR) strips them). printenv adds one newline of its own, and
# the x sentinel stops this capture from stripping the rest.
nl=$'\n'
export KEEPNL1="abc$nl" KEEPNL2="abc$nl$nl" KEEPMID="a${nl}b" KEEPEMPTY=""
for c in "KEEPNL1:abc$nl" "KEEPNL2:abc$nl$nl" "KEEPMID:a${nl}b" "KEEPEMPTY:"; do
    name=${c%%:*}
    want="${c#*:}$nl"
    got=$(bash "$SB" --scratch "$TMP/s3b" --keep "$name" -- printenv "$name" 2>/dev/null; printf x)
    got=${got%x}
    if [ "$got" = "$want" ]; then ok "T3b --keep $name arrives byte-exact"; else fail "T3b --keep $name arrives byte-exact — expected $(printf '%s' "$want" | od -An -c | tr -s ' '), got $(printf '%s' "$got" | od -An -c | tr -s ' ')"; fi
done

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
PROV_AFTER=$(prov_state "$real_prov")
case "$PROV_BEFORE$PROV_AFTER" in
    *UNHASHABLE*) fail "T12 real provenance.jsonl is present but no sha256 tool (sha256sum/shasum) could hash it" ;;
    *) assert_eq "T12 real provenance.jsonl untouched" "$PROV_BEFORE" "$PROV_AFTER" ;;
esac

# T12b: the hasher fallback, on a fixture (HIMMEL-3367). Control first: a present
# file hashes to 64 hex chars on this box, so the UNHASHABLE case below can fail.
printf 'x\n' > "$TMP/fixture-prov"
h_ok=$(prov_state "$TMP/fixture-prov")
case "$h_ok" in
    *[!0-9a-f]*|'') hex=no ;;
    *) if [ "${#h_ok}" -eq 64 ]; then hex=yes; else hex=no; fi ;;
esac
assert_eq "T12b control: a present file hashes to 64 hex chars" yes "$hex"
assert_eq "T12b an absent file reads absent" absent "$(prov_state "$TMP/no-such-file")"
mkdir -p "$TMP/nohash-bin" "$TMP/shasum-bin"
# shellcheck disable=SC2123 # PATH is narrowed on purpose, inside a subshell
h_none=$(PATH="$TMP/nohash-bin"; prov_state "$TMP/fixture-prov")
assert_eq "T12b no hasher on PATH: a present file is UNHASHABLE, not empty" UNHASHABLE "$h_none"
# macOS shape: no sha256sum, only shasum - it must be asked for -a 256.
# shellcheck disable=SC2016 # the fake hasher's body must stay literal
printf '%s\n' '#!/bin/sh' '[ "$1" = "-a" ] && [ "$2" = "256" ] && echo "cafe0123  $3"' > "$TMP/shasum-bin/shasum"
chmod +x "$TMP/shasum-bin/shasum"
# shellcheck disable=SC2123 # as above
h_shasum=$(PATH="$TMP/shasum-bin"; prov_state "$TMP/fixture-prov")
assert_eq "T12b only shasum on PATH: falls back to 'shasum -a 256'" cafe0123 "$h_shasum"
printf '%s\n' '#!/bin/sh' 'exit 1' > "$TMP/shasum-bin/shasum"
# shellcheck disable=SC2123 # as above
h_broken=$(PATH="$TMP/shasum-bin"; prov_state "$TMP/fixture-prov")
assert_eq "T12b a hasher that fails on a present file is UNHASHABLE" UNHASHABLE "$h_broken"

echo "----"
echo "clean-sandbox: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
