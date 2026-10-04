#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2086,SC2010  # A && B || C reporters; positional split of /proc stat; ls /proc/<pid>/fd probe
# scripts/test-tmp-reap.sh - suite for tmp-reap.sh (HIMMEL-4224), the /tmp
# preserve-then-reap reaper. Hermetic: every root is a scratch dir reached
# through TMP_REAP_TMP_ROOT / TMP_REAP_ARCHIVE_ROOT / TMP_REAP_SESSIONS_DIR;
# the real /tmp, ~/.himmel and ~/.claude are never touched.
#   1. dry-run (the default) changes nothing and writes no archive
#   2. a live session (sessions json -> this shell, matching procStart) is kept
#   3. a pid-reuse session json (procStart mismatch) does NOT keep a dead dir
#   4. a dir with an open fd held by a background sleep is kept
#   5. a dead session dir is archived (manifest row asserted) then reaped
#   6. a young judge dir is kept, an old one is archived then reaped
#   7. an old root fixture is reaped, a young one is kept
#   8. a failed preserve (unwritable archive root) means no reap
#   9. an archive target with different content keeps the dir
#  10. an unreadable same-uid /proc entry refuses --apply (fake TMP_REAP_PROC);
#      other-uid only warns (TMP_REAP_UID), dry-run warns, a readable proc is quiet;
#      an empty census root refuses
#  11. FAMILIES does not glob against the caller's cwd
# Platform guard: POSIX bash 3.2+.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/tmp-reap.sh"

T="$(mktemp -d "${TMPDIR:-/tmp}/tmp-reap-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
HOLD_PID=""
cleanup() { [ -n "$HOLD_PID" ] && kill "$HOLD_PID" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
T="$(cd "$T" && pwd)"
fails=0
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { case "$2" in *"$3"*) echo "ok - $1" ;; *) echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)) ;; esac; }
exists()   { [ -e "$2" ] && echo "ok - $1" || { echo "FAIL - $1: $2 missing"; fails=$((fails+1)); }; }
absent()   { [ ! -e "$2" ] && echo "ok - $1" || { echo "FAIL - $1: $2 still exists"; fails=$((fails+1)); }; }

OLD=200001010000
ROOT="$T/tmp"; ARCH="$T/archive"; SESS="$T/sessions"
CL="$ROOT/claude-$(id -u)/-proj"
LIVE=11111111-1111-1111-1111-111111111111
STALE=22222222-2222-2222-2222-222222222222
HELD=33333333-3333-3333-3333-333333333333
DEAD=44444444-4444-4444-4444-444444444444

mkd() { mkdir -p "$1/scratchpad"; printf '{"a":1}\n' > "$1/scratchpad/corpus-x.jsonl"; printf 'junk\n' > "$1/scratchpad/notes.md"; mkdir -p "$1/scratchpad/head"; printf 'checkout\n' > "$1/scratchpad/head/corpus-y.jsonl"; }
old() { touch -t "$OLD" "$@"; }

# $$ is this shell; its start time is field 22 of /proc/$$/stat (after the comm).
pstart() { local s; s="$(cat "/proc/$1/stat")"; s="${s##*) }"; set -f; set -- $s; set +f; shift 19; echo "$1"; }

build_tree() {
    rm -rf "$ROOT" "$SESS"; mkdir -p "$CL" "$SESS"
    mkd "$CL/$LIVE"; mkd "$CL/$STALE"; mkd "$CL/$HELD"; mkd "$CL/$DEAD"
    printf '{"pid":%s,"sessionId":"%s","procStart":"%s"}\n' "$$" "$LIVE" "$(pstart $$)" > "$SESS/$$.json"
    printf '{"pid":%s,"sessionId":"%s","procStart":"1"}\n' "$$" "$STALE" > "$SESS/stale.json"
    mkdir -p "$ROOT/claude-$(id -u)/j9001" "$ROOT/claude-$(id -u)/j9002"
    printf 'r\n' > "$ROOT/claude-$(id -u)/j9001/corpus-a.jsonl"
    printf 'r\n' > "$ROOT/claude-$(id -u)/j9002/corpus-b.jsonl"
    mkdir -p "$ROOT/mog-run.old" "$ROOT/mog-run.new" "$ROOT/unrelated-dir"
    printf 'x\n' > "$ROOT/mog-run.old/f"; printf 'x\n' > "$ROOT/mog-run.new/f"
    old "$CL/$LIVE/scratchpad/corpus-x.jsonl" "$CL/$LIVE/scratchpad" "$CL/$LIVE"
    old "$CL/$STALE/scratchpad/corpus-x.jsonl" "$CL/$STALE/scratchpad" "$CL/$STALE"
    old "$CL/$HELD/scratchpad/corpus-x.jsonl" "$CL/$HELD/scratchpad" "$CL/$HELD"
    old "$CL/$DEAD/scratchpad/corpus-x.jsonl" "$CL/$DEAD/scratchpad" "$CL/$DEAD"
    old "$ROOT/claude-$(id -u)/j9002/corpus-b.jsonl" "$ROOT/claude-$(id -u)/j9002"
    old "$ROOT/mog-run.old/f" "$ROOT/mog-run.old" "$ROOT/unrelated-dir"
}
# TMP_REAP_UID defaults to a uid nobody has, so an unreadable same-uid entry in the HOST's
# /proc (a non-dumpable runner process) only warns instead of refusing --apply; section 10 sets it.
reap() { TMP_REAP_TMP_ROOT="$ROOT" TMP_REAP_ARCHIVE_ROOT="$ARCH" TMP_REAP_SESSIONS_DIR="$SESS" TMP_REAP_UID="${TMP_REAP_UID:-99998}" bash "$SCRIPT" "$@" 2>&1; }

build_tree
( exec 3< "$CL/$HELD/scratchpad/notes.md"; exec sleep 120 ) &
HOLD_PID=$!
i=0; while [ "$i" -lt 50 ] && ! ls -l "/proc/$HOLD_PID/fd" 2>/dev/null | grep -q notes.md; do sleep 0.1; i=$((i+1)); done

echo "== 1. dry-run changes nothing =="
before="$(find "$ROOT" | sort)"
out="$(reap)"; rc=$?
after="$(find "$ROOT" | sort)"
check "dry-run rc 0" "$rc" 0
check "dry-run leaves the tree identical" "$before" "$after"
absent "dry-run writes no archive" "$ARCH"
contains "dry-run lists a REAP row" "$out" "REAP"
contains "dry-run lists a KEEP row" "$out" "KEEP"

echo "== 8. failed preserve -> no reap =="
: > "$T/not-a-dir"
out="$(TMP_REAP_UID=99998 TMP_REAP_ARCHIVE_ROOT="$T/not-a-dir/archive" TMP_REAP_TMP_ROOT="$ROOT" TMP_REAP_SESSIONS_DIR="$SESS" bash "$SCRIPT" --apply 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && echo "ok - failed preserve exits non-zero" || { echo "FAIL - failed preserve rc=$rc"; fails=$((fails+1)); }
exists "dead session dir survives a failed preserve" "$CL/$DEAD"
exists "old judge dir survives a failed preserve" "$ROOT/claude-$(id -u)/j9002"
contains "failed preserve is reported" "$out" "preserve failed"

echo "== --apply =="
out="$(reap --apply)"; rc=$?
check "apply rc 0" "$rc" 0
exists "2. live session dir kept" "$CL/$LIVE"
exists "2. live session file kept" "$CL/$LIVE/scratchpad/corpus-x.jsonl"
absent "3. pid-reuse json does not protect a dead dir" "$CL/$STALE"
exists "4. open-fd dir kept" "$CL/$HELD"
absent "5. dead session dir reaped" "$CL/$DEAD"
exists "6. young judge dir kept" "$ROOT/claude-$(id -u)/j9001"
absent "6. old judge dir reaped" "$ROOT/claude-$(id -u)/j9002"
absent "7. old fixture reaped" "$ROOT/mog-run.old"
exists "7. young fixture kept" "$ROOT/mog-run.new"
exists "unrelated dir never touched" "$ROOT/unrelated-dir"

echo "== manifest =="
M="$ARCH/$(date +%Y-%m)/../MANIFEST.jsonl"
[ -f "$M" ] || M="$ARCH/MANIFEST.jsonl"
exists "manifest written" "$M"
row="$(jq -c --arg id "$DEAD" 'select(.id==$id and .kind=="judge-corpus")' "$M" 2>/dev/null)"
[ -n "$row" ] && echo "ok - dead-dir manifest row present" || { echo "FAIL - no manifest row for $DEAD"; fails=$((fails+1)); }
dest="$(printf '%s' "$row" | jq -r .dest)"
exists "archived copy exists at dest" "$dest"
check "manifest sha256 matches the copy" "$(printf '%s' "$row" | jq -r .sha256)" "$(sha256sum "$dest" | cut -d' ' -f1)"
check "manifest bytes matches" "$(printf '%s' "$row" | jq -r .bytes)" "$(wc -c < "$dest" | tr -d ' ')"
check "manifest row has all keys" "$(printf '%s' "$row" | jq -r '[.src,.dest,.sha256,.bytes,.id,.kind,.archived_at]|map(select(.==null))|length')" 0
check "checkout dir (head/) not archived" "$(jq -r --arg id "$DEAD" 'select(.id==$id)|.src' "$M" | grep -c '/head/')" 0
check "non-whitelisted notes.md not archived" "$(jq -r --arg id "$DEAD" 'select(.id==$id)|.src' "$M" | grep -c 'notes.md')" 0
check "live dir has no manifest row" "$(jq -r --arg id "$LIVE" 'select(.id==$id)|.id' "$M" | wc -l | tr -d ' ')" 0
check "young judge dir has no manifest row" "$(jq -r 'select(.id=="j9001")|.id' "$M" | wc -l | tr -d ' ')" 0

echo "== 9. an archive target that already exists with DIFFERENT content: dir kept, earlier copy untouched =="
build_tree; rm -rf "$ARCH"
pre="$ARCH/$(date +%Y-%m)/judge-corpus/j9002/corpus-b.jsonl"
mkdir -p "${pre%/*}"; printf 'earlier archive, different bytes\n' > "$pre"
want="$(sha256sum "$pre" | cut -d' ' -f1)"
out="$(reap --apply)"; rc=$?
[ "$rc" -ne 0 ] && echo "ok - collision exits non-zero" || { echo "FAIL - collision rc=$rc"; fails=$((fails+1)); }
exists "colliding judge dir is kept" "$ROOT/claude-$(id -u)/j9002"
exists "its source file is kept" "$ROOT/claude-$(id -u)/j9002/corpus-b.jsonl"
check "earlier archive copy is byte-identical" "$(sha256sum "$pre" | cut -d' ' -f1)" "$want"
contains "collision is reported as a failed preserve" "$out" "preserve failed"

echo "== 10. unreadable /proc entries: same-uid refuses --apply, other-uid warns =="
FP="$T/proc"; rm -rf "$FP"; mkdir -p "$FP/100" "$FP/200"; ln -s "$T" "$FP/100/cwd"
build_tree; rm -rf "$ARCH"   # section 9 left a colliding j9002 archive copy behind
out="$(TMP_REAP_UID="$(id -u)" TMP_REAP_PROC="$FP" reap --apply)"; rc=$?
check "same-uid unreadable entry: --apply rc 2" "$rc" 2
contains "same-uid refusal is reported" "$out" "1 same-uid /proc entr(ies) unreadable: a live dir could be held by one; refusing --apply"
exists "refusal reaps no fixture" "$ROOT/mog-run.old"
exists "refusal reaps no dead session dir" "$CL/$DEAD"
out="$(TMP_REAP_UID="$(id -u)" TMP_REAP_PROC="$FP" reap)"; rc=$?
check "same-uid unreadable entry: dry-run rc 0" "$rc" 0
contains "dry-run warns that --apply would refuse" "$out" "--apply would refuse"
out="$(TMP_REAP_PROC="$FP" TMP_REAP_UID=99999 reap --apply)"; rc=$?
check "other-uid unreadable entry: --apply rc 0" "$rc" 0
contains "other-uid entry only warns" "$out" "WARN tmp-reap: 1 other-uid /proc entries unreadable (expected on a multi-user host; not checked)"
absent "other-uid entry: fixture reaped" "$ROOT/mog-run.old"
absent "other-uid entry: dead session dir reaped" "$CL/$DEAD"
rm -rf "$FP/200"; build_tree
out="$(TMP_REAP_UID="$(id -u)" TMP_REAP_PROC="$FP" reap --apply)"; rc=$?
check "readable fake proc: --apply rc 0" "$rc" 0
case "$out" in *WARN*) echo "FAIL - readable fake proc printed a WARN"; fails=$((fails+1)) ;; *) echo "ok - readable fake proc prints no WARN" ;; esac
absent "readable fake proc: fixture reaped" "$ROOT/mog-run.old"

build_tree
out="$(TMP_REAP_UID="$(id -u)" TMP_REAP_PROC="$T/no-such-proc" reap --apply)"; rc=$?
check "missing census root: --apply rc 2" "$rc" 2
exists "missing census root reaps nothing" "$ROOT/mog-run.old"
mkdir -p "$T/empty-proc"; build_tree
out="$(TMP_REAP_UID="$(id -u)" TMP_REAP_PROC="$T/empty-proc" reap --apply)"; rc=$?
check "census root listing no process: --apply rc 2" "$rc" 2
contains "empty census root is reported" "$out" "lists no process"
exists "empty census root reaps nothing" "$ROOT/mog-run.old"
mkdir -p "$T/bin2"; printf '#!/bin/sh\nexit 1\n' > "$T/bin2/stat"; chmod +x "$T/bin2/stat"
rm -rf "$FP/200"; mkdir -p "$FP/200"
out="$(PATH="$T/bin2:$PATH" TMP_REAP_UID="$(id -u)" TMP_REAP_PROC="$FP" reap --apply)"; rc=$?
check "unknown owner of an unreadable entry: --apply rc 2" "$rc" 2
exists "unknown owner reaps nothing" "$ROOT/mog-run.old"
printf '#!/bin/sh\necho "File: junk"\nexit 0\n' > "$T/bin2/stat"
out="$(PATH="$T/bin2:$PATH" TMP_REAP_UID="$(id -u)" TMP_REAP_PROC="$FP" reap --apply)"; rc=$?
check "non-numeric owner output: --apply rc 2" "$rc" 2
exists "non-numeric owner reaps nothing" "$ROOT/mog-run.old"
printf '#!/bin/sh\nrmdir "%s/200"\nexit 1\n' "$FP" > "$T/bin2/stat"
out="$(PATH="$T/bin2:$PATH" TMP_REAP_UID="$(id -u)" TMP_REAP_PROC="$FP" reap --apply)"; rc=$?
check "pid dir vanished before the owner read is skipped: --apply rc 0" "$rc" 0
mkdir -p "$FP/200"
FPX="$T/procx"; mkdir -p "$FPX"; chmod 000 "$FPX"
build_tree
out="$(TMP_REAP_UID="$(id -u)" TMP_REAP_PROC="$FPX" reap --apply)"; rc=$?
chmod 755 "$FPX"
check "existing but unreadable census root: --apply rc 2" "$rc" 2
exists "unreadable census root reaps nothing" "$ROOT/mog-run.old"

rm -rf "$FP/200"; mkdir -p "$FP/300"; printf '300 (x) Z b) S 1 2 3\n' > "$FP/300/stat"
out="$(TMP_REAP_UID="$(id -u)" TMP_REAP_PROC="$FP" reap --apply)"; rc=$?
check "comm containing ') Z ' is not a zombie: --apply rc 2" "$rc" 2
exists "spoofed zombie comm reaps nothing" "$ROOT/mog-run.old"
printf '300 (x y) Z 1 2 3\n' > "$FP/300/stat"
out="$(TMP_REAP_UID="$(id -u)" TMP_REAP_PROC="$FP" reap --apply)"; rc=$?
check "a real zombie is skipped: --apply rc 0" "$rc" 0

echo "== 11. FAMILIES does not glob against the caller's cwd =="
build_tree; CWD="$T/cwd"; mkdir -p "$CWD"; : > "$CWD/mog-run.zzz"; : > "$CWD/himmel-fixture.zzz"
out="$(cd "$CWD" && reap --apply)"; rc=$?
check "apply from a cwd with family-named files rc 0" "$rc" 0
absent "11. old fixture reaped despite cwd files" "$ROOT/mog-run.old"

echo "== 12. scoped to one leg (HIMMEL-4235): --judge / --session =="
build_tree
out="$(reap --apply --judge 9001)"; rc=$?
check "scoped --judge rc 0" "$rc" 0
absent "12. the named leg's young judge dir is reaped with no age floor" "$ROOT/claude-$(id -u)/j9001"
exists "12. another leg's old judge dir untouched" "$ROOT/claude-$(id -u)/j9002"
exists "12. fixture untouched by a scoped run" "$ROOT/mog-run.old"
exists "12. dead session untouched by a judge-only scope" "$CL/$DEAD"
build_tree
out="$(reap --apply --session "$DEAD")"; rc=$?
check "scoped --session rc 0" "$rc" 0
absent "12. the named dead session is reaped" "$CL/$DEAD"
exists "12. another session untouched" "$CL/$STALE"
exists "12. judge dir untouched by a session-only scope" "$ROOT/claude-$(id -u)/j9002"
out="$(reap --judge 9a)"; rc=$?
check "non-numeric --judge rc 2" "$rc" 2
out="$(reap --session nope)"; rc=$?
check "malformed --session rc 2" "$rc" 2

echo
[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILURE(S)"; exit 1; }
