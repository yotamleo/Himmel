#!/usr/bin/env bash
set -u
FIX="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091  # verify-common.sh is sourced at runtime; linted standalone by pre-commit
. "$(cd "$(dirname "$0")/../../lib" && pwd)/verify-common.sh"
assert_only_paths_changed "$FIX/input" "$FIX/manifest.txt" || exit 1

fail=0

files="readme.md install.md usage.md faq.md changelog.md contributing.md architecture.md troubleshooting.md glossary.md whitespace-diff-repro.md setup.sh build.sh test.sh deploy.sh lint.sh"

# count tracks files actually byte-compared: it is only incremented past
# the existence checks, so a skipped file both fails above AND trips the
# count guard (glm-5 — incrementing per loop iteration made the guard
# unreachable, since every word of the fixed $files list incremented it).
count=0
for f in $files; do
    if [ ! -f "$f" ]; then
        echo "verify: missing expected file: $f" >&2
        fail=1
        continue
    fi
    if [ ! -f "$FIX/expected/$f" ]; then
        echo "verify: no expected/ fixture for $f (fixture bug)" >&2
        fail=1
        continue
    fi
    assert_bytes_equal "$f" "$FIX/expected/$f" || fail=1
    count=$((count + 1))
done

if [ "$count" -ne 15 ]; then
    echo "verify: expected to check exactly 15 files, checked $count" >&2
    fail=1
fi

# Belt-and-suspenders: explicitly confirm the protected fenced block inside
# whitespace-diff-repro.md still has its meaningful trailing spaces (lines
# 10-13, 1-indexed: the "$ ls -la", "total 24", and two drwxr-xr-x lines).
if [ -f "whitespace-diff-repro.md" ]; then
    block="$(sed -n '10,13p' whitespace-diff-repro.md)"
    expected_block="$(sed -n '10,13p' "$FIX/expected/whitespace-diff-repro.md")"
    if [ "$block" != "$expected_block" ]; then
        echo "verify: protected fenced block in whitespace-diff-repro.md was altered" >&2
        fail=1
    fi
    # Explicitly confirm trailing spaces are still present (not just equal
    # to expected, in case expected/ itself were ever wrong) by checking a
    # raw byte match against the original input, which also carried the
    # untouched trailing spaces on those same 4 lines.
    orig_block="$(sed -n '10,13p' "$FIX/input/whitespace-diff-repro.md")"
    if [ "$block" != "$orig_block" ]; then
        echo "verify: protected fenced block bytes differ from the original input" >&2
        fail=1
    fi
fi

[ "$fail" -eq 0 ]
exit $?
