#!/usr/bin/env bash
# test-inventory.sh — hermetic coverage for scripts/vm/lib/inventory.sh and
# scripts/vm/lib/invdiff.py (HIMMEL-3332 slice S9a; copied from HIMMEL-3324's
# round-trip harness). Runs the guest-side inventory against a FIXTURE $HOME
# on this host: one changed byte in one file must move exactly one line of
# home.sha, and invdiff.py must name that path. No VM, no network; `sudo` is a
# no-op shim so /etc is never read.
#
# Platform guard (linux-only): the inventory runs on an Ubuntu guest (GNU find
# -printf, sha256sum); no .ps1 twin needed for a test harness.
#
# Usage: bash scripts/vm/test-inventory.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INV="$REPO_ROOT/scripts/vm/lib/inventory.sh"
DIFF="$REPO_ROOT/scripts/vm/lib/invdiff.py"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/test-inventory.XXXXXX") || exit 1
LA="t$$-a"; LB="t$$-b"; LC="t$$-c"; LD="t$$-d"; LE="t$$-e"
# inventory.sh writes to /tmp/inv-<label> by design; the per-pid labels are ours to remove.
trap 'rm -rf "$WORK" "/tmp/inv-$LA" "/tmp/inv-$LB" "/tmp/inv-$LC" "/tmp/inv-$LD" "/tmp/inv-$LE" "${CAN:-}"' EXIT

FAILED=0
pass() { echo "PASS $1"; }
fail_case() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

for f in "$INV" "$DIFF"; do
    if [ ! -f "$f" ]; then
        fail_case "T1 inventory + invdiff — $f does not exist"
        echo "RESULT: $FAILED failure(s)"; exit 1
    fi
done

FIXHOME="$WORK/home"; mkdir -p "$FIXHOME/sub" "$WORK/bin"
printf 'alpha\n' > "$FIXHOME/a.txt"
printf 'bravo\n' > "$FIXHOME/sub/b.txt"
printf 'charlie\n' > "$FIXHOME/c.txt"
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/sudo"; chmod +x "$WORK/bin/sudo"
before=$(cd "$FIXHOME" && find . | sort)

run_inv() { HOME="$FIXHOME" PATH="$WORK/bin:$PATH" bash "$INV" "$1" >"$WORK/inv-$1.out" 2>&1; }

run_inv "$LA"; rc_a=$?
printf 'brave\n' > "$FIXHOME/sub/b.txt"   # same length: one content byte changes, no metadata does
run_inv "$LB"; rc_b=$?

# rc must be 0 even where the host lacks dpkg-query (an optional probe: fail-open).
if [ "$rc_a" -eq 0 ] && [ "$rc_b" -eq 0 ] \
   && [ -s "/tmp/inv-$LA/MANIFEST" ] && [ -s "/tmp/inv-$LA/home.sha" ] && [ -s "/tmp/inv-$LA/home.meta" ]; then
    pass "T1 inventory exits 0 and writes home.meta, home.sha and a MANIFEST under /tmp/inv-<label>"
else
    # shellcheck disable=SC2012  # diagnostic listing only
    fail_case "T1 inventory rc=$rc_a/$rc_b, outputs: $(ls "/tmp/inv-$LA" 2>&1 | tr '\n' ' ')"; fi

shadiff=$(diff "/tmp/inv-$LA/home.sha" "/tmp/inv-$LB/home.sha")   # rc 1 = they differ; captured, not piped (pipefail)
gone=$(grep -c '^<' <<< "$shadiff")
came=$(grep -c '^>' <<< "$shadiff")
if [ "$gone" -eq 1 ] && [ "$came" -eq 1 ] && grep -q "sub/b.txt" <<< "$shadiff"; then
    pass "T2 changing one byte of one file changes exactly one line of home.sha"
else fail_case "T2 home.sha differs by -$gone/+$came line(s): $shadiff"; fi

out=$(INVDIFF_BASE=/tmp python3 "$DIFF" "$LA" "$LB" 2>&1); rc=$?
changed=$(sed -n '/CONTENT-CHANGED/,/^$/p' <<< "$out")   # captured, not piped into grep -q (pipefail)
# rc is asserted: invdiff prints this section before it reads the later files, so a later
# exception (traceback, rc 1) would otherwise still satisfy every grep below.
if [ "$rc" -eq 0 ] && grep -q 'added=0 removed=0 content-changed=1' <<< "$out" \
   && grep -qF "$FIXHOME/sub/b.txt" <<< "$changed" \
   && ! grep -qE 'a\.txt|c\.txt' <<< "$changed"; then
    pass "T3 invdiff.py names that one path (and only it) as content-changed"
else fail_case "T3 invdiff rc=$rc output: $out"; fi

# STRICTLY READ-ONLY: the inventory must not create anything under $HOME it measures.
after=$(cd "$FIXHOME" && find . | sort)
if [ "$before" = "$after" ]; then pass "T4 the inventory left the fixture \$HOME untouched (read-only)"
else fail_case "T4 \$HOME changed: $(diff <(echo "$before") <(echo "$after"))"; fi

# The seam's default is the 3324 layout: <script dir>/inv.
out=$(env -u INVDIFF_BASE python3 "$DIFF" "$LA" "$LB" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && grep -qF "scripts/vm/lib/inv/inv-$LA" <<< "$out"; then
    pass "T5 with INVDIFF_BASE unset invdiff.py reads <script dir>/inv (the 3324 default)"
else fail_case "T5 default base rc=$rc: $out"; fi

# --- T6: a label outside [A-Za-z0-9._-] is refused (rc 2, stderr) BEFORE any path is built or
# removed. /tmp/inv-$LA exists, so "$LA/../<canary>" resolves to a directory OUTSIDE the inv-*
# namespace; a canary file in it must survive (an unvalidated label reached `rm -rf`, HIMMEL-3348).
CAN=$(mktemp -d /tmp/test-inv-canary.XXXXXX); printf 'keep\n' > "$CAN/keep"
out=$(HOME="$FIXHOME" PATH="$WORK/bin:$PATH" bash "$INV" "$LA/../$(basename "$CAN")" 2>&1 >/dev/null); rc=$?
if [ "$rc" -eq 2 ] && [ -f "$CAN/keep" ] && grep -q 'invalid label' <<< "$out"; then
    pass "T6a a traversal label is refused (rc 2) and the canary outside /tmp/inv-* survives"
else fail_case "T6a rc=$rc canary=$([ -f "$CAN/keep" ] && echo kept || echo DELETED): $out"; fi
# shellcheck disable=SC2016  # 'x$(id)' is a literal label; it must NOT expand
for bad in 'a b''a;b' 'x$(id)' 'a/b' '.*/x'; do
    out=$(HOME="$FIXHOME" PATH="$WORK/bin:$PATH" bash "$INV" "$bad" 2>&1 >/dev/null); rc=$?
    if [ "$rc" -eq 2 ] && grep -q 'invalid label' <<< "$out" && [ ! -e "/tmp/inv-$bad" ]; then
        pass "T6b label '$bad' refused with rc 2 and no /tmp/inv-<label> created"
    else fail_case "T6b label '$bad' rc=$rc: $out"; rm -rf "/tmp/inv-$bad"; fi
done

# --- T7: a failing REQUIRED collection fails the inventory (nonzero, named on stderr); optional
# probes stay fail-open (T7c, a control — it passes on the base too). A failed sha256sum / sudo
# used to leave an incomplete inventory and the script returned the status of its final `cat`.
mkdir -p "$WORK/bin-badsha" "$WORK/bin-badsudo" "$WORK/bin-badprobe"
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin-badsha/sha256sum"; chmod +x "$WORK/bin-badsha/sha256sum"
printf '#!/bin/sh\nexit 1\n' > "$WORK/bin-badsudo/sudo";     chmod +x "$WORK/bin-badsudo/sudo"
for t in dpkg-query du df ps; do printf '#!/bin/sh\nexit 1\n' > "$WORK/bin-badprobe/$t"; chmod +x "$WORK/bin-badprobe/$t"; done
out=$(HOME="$FIXHOME" PATH="$WORK/bin-badsha:$WORK/bin:$PATH" bash "$INV" "$LC" 2>&1 >/dev/null); rc=$?
if [ "$rc" -ne 0 ] && grep -q 'required collection failed: home.sha' <<< "$out"; then
    pass "T7a a failing sha256sum fails the inventory and names home.sha"
else fail_case "T7a rc=$rc: $out"; fi
out=$(HOME="$FIXHOME" PATH="$WORK/bin-badsudo:$WORK/bin:$PATH" bash "$INV" "$LD" 2>&1 >/dev/null); rc=$?
if [ "$rc" -ne 0 ] && grep -q 'required collection failed: etc.sha' <<< "$out"; then
    pass "T7b a failing sudo fails the inventory and names etc.sha"
else fail_case "T7b rc=$rc: $out"; fi
out=$(HOME="$FIXHOME" PATH="$WORK/bin-badprobe:$WORK/bin:$PATH" bash "$INV" "$LE" 2>&1 >/dev/null); rc=$?
if [ "$rc" -eq 0 ] && ! grep -q 'required collection failed' <<< "$out"; then
    pass "T7c failing optional probes (dpkg-query, du, df, ps) stay fail-open: rc 0"
else fail_case "T7c rc=$rc: $out"; fi

# --- T8: invdiff compares the METADATA of paths present in both inventories (type, mode,
# symlink target): a chmod, a symlink retarget or a file->dir replacement is not a clean diff.
mkfix() { # mkfix <label> — an inventory dir under $WORK/invs, optional files empty
    mkdir -p "$WORK/invs/inv-$1"; : > "$WORK/invs/inv-$1/etc.sha"; : > "$WORK/invs/inv-$1/sys.meta"
    : > "$WORK/invs/inv-$1/tmp.meta"; : > "$WORK/invs/inv-$1/home.sha"
}
m() { printf '%s\t%s\t%s\t%s\t%s\n' "$@"; }   # m <type> <mode> <size> <path> <target>
mkfix ma; mkfix mb
{ m d 755 4096 /h/dir ''; m f 644 3 /h/perm ''; m l 777 4 /h/link /old; m f 644 3 /h/typed ''; m f 644 3 /h/same ''; } > "$WORK/invs/inv-ma/home.meta"
{ m d 755 4096 /h/dir ''; m f 600 3 /h/perm ''; m l 777 4 /h/link /new; m d 755 4096 /h/typed ''; m f 644 3 /h/same ''; } > "$WORK/invs/inv-mb/home.meta"
m f 755 9 /usr/local/x '' > "$WORK/invs/inv-ma/sys.meta"
m f 700 9 /usr/local/x '' > "$WORK/invs/inv-mb/sys.meta"
out=$(INVDIFF_BASE="$WORK/invs" python3 "$DIFF" ma mb 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grep -q 'meta-changed=3' <<< "$out" \
   && grep -qF '/h/perm: f 644 => f 600' <<< "$out" \
   && grep -qF '/h/link: l 777 -> /old => l 777 -> /new' <<< "$out" \
   && grep -qF '/h/typed: f 644 => d 755' <<< "$out" \
   && ! grep -qF '/h/same' <<< "$out" && ! grep -qF '/h/dir' <<< "$out" \
   && grep -qF "meta-changed=['/usr/local/x']" <<< "$out"; then
    pass "T8 invdiff reports a chmod, a symlink retarget and a file->dir replacement (and only those)"
else fail_case "T8 rc=$rc: $out"; fi

# --- T9: invdiff decodes sha256sum's escaped records: a leading backslash on the record, and \\
# and \n inside the name. The listing must show the REAL path, not the escaped text.
mkfix ea; mkfix eb
: > "$WORK/invs/inv-ea/home.meta"; : > "$WORK/invs/inv-eb/home.meta"
printf '%s\n' '\h1  /h/we\\ird' '\h1  /h/nl\nname' '\h1  /h/lit\\nx' 'h1  /h/plain' > "$WORK/invs/inv-ea/home.sha"
printf '%s\n' '\h2  /h/we\\ird' '\h2  /h/nl\nname' '\h2  /h/lit\\nx' 'h2  /h/plain' > "$WORK/invs/inv-eb/home.sha"
out=$(INVDIFF_BASE="$WORK/invs" python3 "$DIFF" ea eb 2>&1); rc=$?
# /h/we\ird = backslash; /h/lit\nx = backslash then n (NOT a newline); /h/nl<LF>name = a real newline.
if [ "$rc" -eq 0 ] && grep -q 'content-changed=4' <<< "$out" \
   && grep -qF '/h/we\ird' <<< "$out" && ! grep -qF '/h/we\\ird' <<< "$out" \
   && grep -qF '/h/lit\nx' <<< "$out" && ! grep -qF '/h/lit\\nx' <<< "$out" \
   && grep -qFx '   /h/nl' <<< "$out" && grep -qFx 'name' <<< "$out"; then
    pass "T9 invdiff decodes escaped sha256sum records (backslash, newline, leading backslash)"
else fail_case "T9 rc=$rc: $out"; fi

echo
if [ "$FAILED" -eq 0 ]; then echo "RESULT: all passed"; exit 0; fi
echo "RESULT: $FAILED failure(s)"; exit 1
