#!/usr/bin/env bash
# Smoke suite for scripts/hooks/console-precompact-snapshot.sh (HIMMEL-2973
# S3): a PreCompact hook that snapshots a console's authority-bearing state to
# <HIMMEL_CONSOLE_WORKDIR>/precompact-<n>.snap at the moment of compaction, so
# compacted-check.sh (G11) can prove the post-compaction COMPACTED bullet
# matches. The hook exits 0 ALWAYS (a PreCompact failure must never block a
# compaction) and writes NOTHING for a session that is not a console.
#
# Hermetic: temp HOME / HANDOVER_DIR / workdir; never the live ~/.claude or
# /run/user/<uid>. PLATFORM GUARD: no .ps1 twin — bash 3.2-safe.
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HOOKS/console-precompact-snapshot.sh"
CHECKER="$HOOKS/../handover/console-kit/compacted-check.sh"
[ -f "$HOOK" ] || { echo "hook not found: $HOOK" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/console-precompact-snapshot-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd)"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: [$2] != [$3]"; fi; }

# Fixture: a handover root holding the console doc, its queue lock, two GO files.
ROOT="$TMP/root"
HOME_FIX="$TMP/home"; mkdir -p "$HOME_FIX"
DOC="$ROOT/yotamleo/himmel/fix-console.md"
SLUG="yotamleo__himmel__fix-console"
mkdir -p "$ROOT/yotamleo/himmel" "$ROOT/.locks/queue/$SLUG.lock" "$ROOT/.locks/go"
printf '{"session":"host-pid4242","host":"host","handover":"%s","started":"2026-09-18T10:00:00Z","heartbeat":"2026-09-18T10:00:00Z"}\n' "$DOC" \
    > "$ROOT/.locks/queue/$SLUG.lock/owner.json"
SHA_OLD=1111111111111111111111111111111111111111
SHA_NEW=2222222222222222222222222222222222222222
printf 'pr=12\nhead=%s\n' "$SHA_OLD" > "$ROOT/.locks/go/12.$SHA_OLD"
printf 'pr=13\nhead=%s\n' "$SHA_NEW" > "$ROOT/.locks/go/13.$SHA_NEW"
touch -t 202609181000 "$ROOT/.locks/go/12.$SHA_OLD"
touch -t 202609181100 "$ROOT/.locks/go/13.$SHA_NEW"

# shellcheck disable=SC2016  # backtick spans are literal fixture text
write_doc() {
    # $1 = queue value
    cat > "$DOC" <<DOC
# Fix Console

## Live state

legs: \`N1:nA:lA:111\`, \`N2:nB:lB:222\`
queue: $1
last GO: \`13:2222222\`
acked: none

## Compact instructions

Carry state forward.

## Results

- LIVE 09:00
DOC
}
write_doc "12,13"

WORK="$TMP/work"
STDIN='{"session_id":"s1","transcript_path":"/x/t.jsonl","cwd":"/y","hook_event_name":"PreCompact","trigger":"auto"}'

# fire <stdin> [extra env assignments...] -- runs the hook in a scrubbed env.
fire() {
    local in="$1"; shift
    printf '%s' "$in" | env -u HIMMEL_CONSOLE_DOC -u HIMMEL_CONSOLE_WORKDIR -u HANDOVER_DIR \
        HOME="$HOME_FIX" HANDOVER_DIR="$ROOT" "$@" bash "$HOOK" 2>&1
}

echo "== first fire: console env set -> precompact-1.snap =="
out="$(fire "$STDIN" HIMMEL_CONSOLE_DOC="$DOC" HIMMEL_CONSOLE_WORKDIR="$WORK")"; rc=$?
eq "exits 0" "$rc" 0
SNAP1="$WORK/precompact-1.snap"
if [ -f "$SNAP1" ]; then ok "precompact-1.snap written"; else bad "precompact-1.snap missing (out: $out)"; fi
field() { awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$1"; }
eq "first line is a sha256= line" "$(head -n 1 "$SNAP1" | cut -c1-7)" "sha256="
eq "lock= is the queue-lock owner token" "$(field "$SNAP1" lock)" "host-pid4242"
eq "legs= copies the Live state legs line, backticks stripped" "$(field "$SNAP1" legs)" "N1:nA:lA:111, N2:nB:lB:222"
eq "queue= copies the Live state queue line" "$(field "$SNAP1" queue)" "12,13"
eq "last-go= copies the Live state last GO line" "$(field "$SNAP1" last-go)" "13:2222222"
eq "go-file= names the NEWEST GO file as <pr>.<sha7>" "$(field "$SNAP1" go-file)" "13.2222222"
eq "acked= copied" "$(field "$SNAP1" acked)" "none"
eq "trigger= recorded from stdin" "$(field "$SNAP1" trigger)" "auto"
if grep -q '`' "$SNAP1"; then bad "snap contains a backtick"; else ok "snap contains no backtick"; fi
if [ -x "$CHECKER" ] || [ -f "$CHECKER" ]; then
    # shellcheck disable=SC2016  # backtick spans are literal fixture text
    printf '%s\n' '- COMPACTED 12:00 — legs: `N1:nA:lA:111`, `N2:nB:lB:222`, queue: 12,13, last GO: `13:2222222`, acked: none' > "$TMP/bullet.md"
    bash "$CHECKER" "$TMP/bullet.md" "$WORK" >/dev/null 2>&1; crc=$?
    eq "the checker accepts the hook's snap against the matching bullet" "$crc" 0
else
    bad "checker missing: $CHECKER"
fi
eq "workdir is mode 700" "$(stat -c %a "$WORK" 2>/dev/null || stat -f %Lp "$WORK")" "700"

echo "== second fire after a queue edit: precompact-2.snap, snap 1 immutable =="
before="$(cksum < "$SNAP1")"
write_doc "13"
out="$(fire "$STDIN" HIMMEL_CONSOLE_DOC="$DOC" HIMMEL_CONSOLE_WORKDIR="$WORK")"; rc=$?
eq "exits 0" "$rc" 0
SNAP2="$WORK/precompact-2.snap"
if [ -f "$SNAP2" ]; then ok "precompact-2.snap written"; else bad "precompact-2.snap missing (out: $out)"; fi
eq "snap 2 queue=13" "$(field "$SNAP2" queue)" "13"
eq "snap 1 byte-identical" "$(cksum < "$SNAP1")" "$before"

echo "== last-tick.txt in the workdir rides under a --- tick separator =="
printf 'tick fixture line\n' > "$WORK/last-tick.txt"
fire "$STDIN" HIMMEL_CONSOLE_DOC="$DOC" HIMMEL_CONSOLE_WORKDIR="$WORK" >/dev/null
SNAP3="$WORK/precompact-3.snap"
if grep -qx -- '--- tick' "$SNAP3" 2>/dev/null; then ok "--- tick separator present"; else bad "--- tick separator missing"; fi
if grep -qx 'tick fixture line' "$SNAP3" 2>/dev/null; then ok "tick output carried verbatim"; else bad "tick output missing"; fi
bash "$CHECKER" "$TMP/bullet.md" "$WORK" >/dev/null 2>&1; crc=$?
eq "checker still parses a snap with a tick tail (LOSS rc 1 vs the stale bullet, never rc 2)" "$crc" 1

echo "== HIMMEL_CONSOLE_DOC unset (a non-console session) -> exit 0, nothing written =="
W2="$TMP/work-nonconsole"
out="$(fire "$STDIN" HIMMEL_CONSOLE_WORKDIR="$W2")"; rc=$?
eq "exits 0" "$rc" 0
if [ -e "$W2" ]; then bad "workdir created for a non-console session"; else ok "no workdir, no file"; fi

echo "== HIMMEL_CONSOLE_WORKDIR unset -> exit 0, nothing written =="
out="$(fire "$STDIN" HIMMEL_CONSOLE_DOC="$DOC")"; rc=$?
eq "exits 0" "$rc" 0

echo "== doc without a ## Live state section -> snap written with empty legs/queue =="
NOLS="$ROOT/yotamleo/himmel/nols-console.md"
printf '# no live state\n\n## Results\n\n- LIVE 09:00\n' > "$NOLS"
W3="$TMP/work-nols"
out="$(fire "$STDIN" HIMMEL_CONSOLE_DOC="$NOLS" HIMMEL_CONSOLE_WORKDIR="$W3")"; rc=$?
eq "exits 0" "$rc" 0
eq "legs= empty" "$(field "$W3/precompact-1.snap" legs)" ""
eq "queue= empty" "$(field "$W3/precompact-1.snap" queue)" ""
eq "last-go= empty" "$(field "$W3/precompact-1.snap" last-go)" ""

echo "== unresolvable inputs never block a compaction (exit 0) =="
out="$(fire "$STDIN" HIMMEL_CONSOLE_DOC="$TMP/nonexistent-console.md" HIMMEL_CONSOLE_WORKDIR="$TMP/work-x")"; rc=$?
eq "missing doc -> exit 0" "$rc" 0
if [ -e "$TMP/work-x" ]; then bad "workdir created for a missing doc"; else ok "missing doc -> nothing written"; fi
out="$(fire "" HIMMEL_CONSOLE_DOC="$DOC" HIMMEL_CONSOLE_WORKDIR="$TMP/work-empty-stdin")"; rc=$?
eq "empty stdin -> exit 0" "$rc" 0
if [ -f "$TMP/work-empty-stdin/precompact-1.snap" ]; then ok "empty stdin still snapshots (the hook needs no stdin field)"; else bad "empty stdin: no snap"; fi
eq "empty stdin -> trigger= empty" "$(field "$TMP/work-empty-stdin/precompact-1.snap" trigger)" ""
out="$(fire "not json{{" HIMMEL_CONSOLE_DOC="$DOC" HIMMEL_CONSOLE_WORKDIR="$TMP/work-garbage")"; rc=$?
eq "garbage stdin -> exit 0" "$rc" 0

echo "== a workdir that is a symlink is refused (exit 0, nothing written through it) =="
mkdir -p "$TMP/link-target"
ln -s "$TMP/link-target" "$TMP/work-link"
out="$(fire "$STDIN" HIMMEL_CONSOLE_DOC="$DOC" HIMMEL_CONSOLE_WORKDIR="$TMP/work-link")"; rc=$?
eq "exits 0" "$rc" 0
if ls "$TMP/link-target"/precompact-*.snap >/dev/null 2>&1; then bad "snap written through a symlinked workdir"; else ok "nothing written through the symlink"; fi

echo "== a workdir that cannot be created (parent is a file) -> exit 0 =="
: > "$TMP/a-file"
out="$(fire "$STDIN" HIMMEL_CONSOLE_DOC="$DOC" HIMMEL_CONSOLE_WORKDIR="$TMP/a-file/sub")"; rc=$?
eq "exits 0" "$rc" 0

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
