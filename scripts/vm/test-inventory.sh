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
LA="t$$-a"; LB="t$$-b"
# inventory.sh writes to /tmp/inv-<label> by design; the per-pid labels are ours to remove.
trap 'rm -rf "$WORK" "/tmp/inv-$LA" "/tmp/inv-$LB"' EXIT

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

run_inv "$LA"
printf 'brave\n' > "$FIXHOME/sub/b.txt"   # same length: one content byte changes, no metadata does
run_inv "$LB"

if [ -s "/tmp/inv-$LA/MANIFEST" ] && [ -s "/tmp/inv-$LA/home.sha" ] && [ -s "/tmp/inv-$LA/home.meta" ]; then
    pass "T1 inventory writes home.meta, home.sha and a MANIFEST under /tmp/inv-<label>"
else
    # shellcheck disable=SC2012  # diagnostic listing only
    fail_case "T1 inventory outputs missing: $(ls "/tmp/inv-$LA" 2>&1 | tr '\n' ' ')"; fi

shadiff=$(diff "/tmp/inv-$LA/home.sha" "/tmp/inv-$LB/home.sha")   # rc 1 = they differ; captured, not piped (pipefail)
gone=$(grep -c '^<' <<< "$shadiff")
came=$(grep -c '^>' <<< "$shadiff")
if [ "$gone" -eq 1 ] && [ "$came" -eq 1 ] && grep -q "sub/b.txt" <<< "$shadiff"; then
    pass "T2 changing one byte of one file changes exactly one line of home.sha"
else fail_case "T2 home.sha differs by -$gone/+$came line(s): $shadiff"; fi

out=$(INVDIFF_BASE=/tmp python3 "$DIFF" "$LA" "$LB" 2>&1)
changed=$(sed -n '/CONTENT-CHANGED/,/^$/p' <<< "$out")   # captured, not piped into grep -q (pipefail)
if grep -q 'added=0 removed=0 content-changed=1' <<< "$out" \
   && grep -qF "$FIXHOME/sub/b.txt" <<< "$changed" \
   && ! grep -qE 'a\.txt|c\.txt' <<< "$changed"; then
    pass "T3 invdiff.py names that one path (and only it) as content-changed"
else fail_case "T3 invdiff output: $out"; fi

# STRICTLY READ-ONLY: the inventory must not create anything under $HOME it measures.
after=$(cd "$FIXHOME" && find . | sort)
if [ "$before" = "$after" ]; then pass "T4 the inventory left the fixture \$HOME untouched (read-only)"
else fail_case "T4 \$HOME changed: $(diff <(echo "$before") <(echo "$after"))"; fi

# The seam's default is the 3324 layout: <script dir>/inv.
out=$(env -u INVDIFF_BASE python3 "$DIFF" "$LA" "$LB" 2>&1); rc=$?
if [ "$rc" -ne 0 ] && grep -qF "scripts/vm/lib/inv/inv-$LA" <<< "$out"; then
    pass "T5 with INVDIFF_BASE unset invdiff.py reads <script dir>/inv (the 3324 default)"
else fail_case "T5 default base rc=$rc: $out"; fi

echo
if [ "$FAILED" -eq 0 ]; then echo "RESULT: all passed"; exit 0; fi
echo "RESULT: $FAILED failure(s)"; exit 1
