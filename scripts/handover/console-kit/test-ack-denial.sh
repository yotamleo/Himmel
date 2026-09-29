#!/usr/bin/env bash
# test-ack-denial.sh — HIMMEL-3724. Exercises ack-denial.sh (the operator's ack
# of a paged classifier denial) and denial-ack-lib.sh (the shared record
# helpers). Scratch ack dir only (HIMMEL_DENIAL_ACK_DIR): never the real
# ~/.himmel/state. bash 3.2-safe.
#
# Run: bash scripts/handover/console-kit/test-ack-denial.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ACK="${ACK_DENIAL:-$HERE/ack-denial.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ack-denial-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT
export HIMMEL_DENIAL_ACK_DIR="$WORK/acks"

# A page record as console-wait writes it (denial_page_write in the lib).
mkpage() { # <label> <count> <class> <ts>
    [ -d "$HIMMEL_DENIAL_ACK_DIR" ] || { ( umask 077; mkdir -p "$HIMMEL_DENIAL_ACK_DIR" ); }  # as the real writer creates it
    printf 'leg=%s\ncount=%s\nclass=%s\nts=%s\n' "$1" "$2" "$3" "$4" > "$HIMMEL_DENIAL_ACK_DIR/$1.page"
}
field() { sed -n "s/^$2=//p" "$1" | head -n 1; }
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }  # gnu-ok: Linux-only kit, BSD fallback

# --- (a) no args -> usage, exit 2 ------------------------------------------
out="$(bash "$ACK" 2>&1)"; rc=$?
check "(a) no args exits 2" "2" "$rc"
check "(a) usage names the script" "yes" "$(printf '%s' "$out" | grep -q 'usage: ack-denial.sh' && echo yes)"

# --- (b) a paged denial is acked: file, fields, modes -----------------------
now=$(date +%s)
mkpage feat+leg-a 2 SHIP-STEP "$((now - 60))"
out="$(bash "$ACK" feat+leg-a 2>&1)"; rc=$?
check "(b) ack of a paged leg exits 0" "0" "$rc"
af="$HIMMEL_DENIAL_ACK_DIR/feat+leg-a.ack"
check "(b) the ack file exists" "yes" "$([ -f "$af" ] && echo yes)"
check "(b) it records the leg" "feat+leg-a" "$(field "$af" leg)"
check "(b) it records the paged class" "SHIP-STEP" "$(field "$af" class)"
check "(b) it records the paged count" "2" "$(field "$af" count)"
ats="$(field "$af" ts)"
check "(b) it carries a timestamp at or after the page" "yes" "$([ "${ats:-0}" -ge "$((now - 60))" ] 2>/dev/null && echo yes)"
check "(b) the ack file is 0600" "600" "$(mode "$af")"
check "(b) the ack dir is 0700" "700" "$(mode "$HIMMEL_DENIAL_ACK_DIR")"

# --- (c) idempotent: a second ack leaves the first untouched ---------------
sleep 1
cp "$af" "$WORK/first.ack"
out="$(bash "$ACK" feat+leg-a 2>&1)"; rc=$?
check "(c) a repeat ack exits 0" "0" "$rc"
check "(c) a repeat ack leaves the ack file byte-identical" "same" "$(cmp -s "$af" "$WORK/first.ack" && echo same)"
check "(c) and says it is already acked" "yes" "$(printf '%s' "$out" | grep -qi 'already acked' && echo yes)"

# --- (d) a NEWER page after the ack needs a fresh ack ----------------------
mkpage feat+leg-a 1 PAUSE-RISK "$(( $(date +%s) + 5 ))"
out="$(bash "$ACK" feat+leg-a 2>&1)"; rc=$?
check "(d) a page newer than the ack is acked again" "0" "$rc"
check "(d) the ack now records the newer class" "PAUSE-RISK" "$(field "$af" class)"

# --- (e) nothing paged -> exit 0, no ack file written -----------------------
out="$(bash "$ACK" feat+never-paged 2>&1)"; rc=$?
check "(e) a leg with no page on record exits 0" "0" "$rc"
check "(e) and writes no ack file" "no" "$([ -e "$HIMMEL_DENIAL_ACK_DIR/feat+never-paged.ack" ] && echo yes || echo no)"
check "(e) and says there is nothing to ack" "yes" "$(printf '%s' "$out" | grep -qi 'nothing to ack' && echo yes)"

# --- (f) a handover doc resolves to its worktree slug -----------------------
DOC="$WORK/leg-doc.md"
printf -- '---\nresume_cwd: /x/y/.claude/worktrees/feat+leg-doc\ntemplate_version: 3\n---\n\n# body\n' > "$DOC"
mkpage feat+leg-doc 3 PAUSE-RISK "$(( $(date +%s) - 5 ))"
out="$(bash "$ACK" "$DOC" 2>&1)"; rc=$?
check "(f) a doc arg exits 0" "0" "$rc"
check "(f) the ack lands under the doc's worktree slug" "yes" "$([ -f "$HIMMEL_DENIAL_ACK_DIR/feat+leg-doc.ack" ] && echo yes)"
NODOC="$WORK/no-cwd.md"
printf -- '---\ntemplate_version: 3\n---\n' > "$NODOC"
out="$(bash "$ACK" "$NODOC" 2>&1)"; rc=$?
check "(f) a doc with no resume_cwd exits 2" "2" "$rc"

# --- (g) a hostile label cannot leave the ack dir ---------------------------
out="$(bash "$ACK" '../../etc/x' 2>&1)"; rc=$?
check "(g) a path-shaped label exits 0 or 2, never writes outside" "yes" "$([ "$rc" = 0 ] || [ "$rc" = 2 ] && echo yes)"
check "(g) nothing appears above the ack dir" "no" "$([ -e "$WORK/etc" ] && echo yes || echo no)"

# --- (h) unwritable ack dir -> exit 1, not a crash --------------------------
mkpage feat+leg-h 1 SHIP-STEP "$(( $(date +%s) - 5 ))"
chmod 500 "$HIMMEL_DENIAL_ACK_DIR"
if [ "$(id -u)" != 0 ]; then
    out="$(bash "$ACK" feat+leg-h 2>&1)"; rc=$?
    check "(h) an unwritable ack dir exits 1" "1" "$rc"
else
    pass "(h) skipped as root (chmod does not bind)"
fi
chmod 700 "$HIMMEL_DENIAL_ACK_DIR"

echo "----"
if [ "$fails" -eq 0 ]; then echo "PASS - test-ack-denial.sh"; exit 0; fi
echo "FAIL - test-ack-denial.sh ($fails failure(s))"; exit 1
