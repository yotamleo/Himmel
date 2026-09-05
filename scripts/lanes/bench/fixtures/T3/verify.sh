#!/usr/bin/env bash
set -u
FIX="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091  # verify-common.sh is sourced at runtime; linted standalone by pre-commit
. "$(cd "$(dirname "$0")/../../lib" && pwd)/verify-common.sh"
assert_only_paths_changed "$FIX/input" "$FIX/manifest.txt" || exit 1

fail=0

# Files that must be byte-identical to the original input (already had a
# BOM, must not be touched at all).
protected_files="Stop-Service.ps1 Test-Connection.ps1 Update-Registry.ps1"

# Files that were missing the BOM and must now have exactly one BOM
# prepended, with the rest of their content unchanged (3 bytes of delta).
changed_files="Deploy-App.ps1 Get-Status.ps1 Invoke-Backup.ps1 New-Report.ps1 Remove-TempFiles.ps1 Set-Config.ps1 Start-Service.ps1"

all_files="$protected_files $changed_files"

# Every .ps1 file present must be exactly one of the 10 known files (no
# extras, no missing) — belt-and-suspenders on top of assert_only_paths_changed.
count=0
for f in *.ps1; do
    [ -f "$f" ] || continue
    count=$((count + 1))
done
if [ "$count" -ne 10 ]; then
    echo "verify: expected exactly 10 .ps1 files, found $count" >&2
    fail=1
fi

for f in $all_files; do
    if [ ! -f "$f" ]; then
        echo "verify: missing expected file: $f" >&2
        fail=1
    fi
done

# Every .ps1 file must start with exactly one UTF-8 BOM (EF BB BF), and the
# 4th byte must NOT also be part of a second BOM (i.e. bytes 4-6 must not be
# EF BB BF again) — catches double-BOM corruption directly.
for f in $all_files; do
    [ -f "$f" ] || continue
    head6="$(head -c 6 "$f" | od -An -tx1 | tr -d ' \n')"
    case "$head6" in
        efbbbf*)
            rest="${head6#efbbbf}"
            if [ "$rest" = "efbbbf" ]; then
                echo "verify: DOUBLE BOM detected in $f" >&2
                fail=1
            fi
            ;;
        *)
            echo "verify: $f does not start with a UTF-8 BOM (first bytes: $head6)" >&2
            fail=1
            ;;
    esac
done

# Protected files: byte-identical to their originals.
for f in $protected_files; do
    assert_bytes_equal "$f" "$FIX/input/$f" || fail=1
done

# Changed files: exactly 3 bytes of delta (the prepended BOM), content after
# the BOM unchanged versus the original.
for f in $changed_files; do
    orig="$FIX/input/$f"
    if [ ! -f "$orig" ]; then
        echo "verify: no original for $f" >&2
        fail=1
        continue
    fi
    orig_size=$(wc -c < "$orig" | tr -d ' ')
    new_size=$(wc -c < "$f" | tr -d ' ')
    delta=$((new_size - orig_size))
    if [ "$delta" -ne 3 ]; then
        echo "verify: $f expected +3 bytes of delta over original, got $delta" >&2
        fail=1
        continue
    fi
    # Compare content after the 3-byte BOM prefix against the original
    # (which had zero BOM bytes) — must match exactly.
    tail_new="$(tail -c +4 "$f" | od -An -tx1)"
    all_orig="$(od -An -tx1 "$orig")"
    if [ "$tail_new" != "$all_orig" ]; then
        echo "verify: $f content after BOM does not match original content" >&2
        fail=1
    fi
done

[ "$fail" -eq 0 ]
exit $?
