#!/usr/bin/env bash
# Pre-commit hook: require --hash= on every package line in requirements*.txt.
# pre-commit passes staged matching filenames as positional args.
# A package line is anything that is not blank, not a comment, and not a
# directive (-r / -c / --index-url / --extra-index-url / --find-links / etc.).
set -euo pipefail

if [ $# -eq 0 ]; then
    echo "→ pip-hashes: no requirements files staged — nothing to check"
    exit 0
fi

fail=0
for file in "$@"; do
    [ -f "$file" ] || continue

    # `--generate-hashes` writes each pin across multiple physical lines using
    # trailing `\` continuations. Join those into one logical line per package
    # before checking that every package line carries --hash=sha256:.
    bad=$(awk '
        { buf = buf $0 }
        /\\$/ { sub(/\\[[:space:]]*$/, " ", buf); next }
        {
            line = buf
            buf = ""
            if (line ~ /^[[:space:]]*$/) next       # blank
            if (line ~ /^[[:space:]]*#/) next       # comment
            if (line ~ /^[[:space:]]*-/) next       # pip directive (-r, -c, --index-url, ...)
            if (line !~ /--hash=sha256:/) print NR ": " line
        }
        END {
            # Flush a trailing buffer left dangling by a final \ continuation
            # at EOF (otherwise that line would silently skip validation).
            if (buf ~ /[^[:space:]]/) {
                if (buf ~ /^[[:space:]]*#/) ; else
                if (buf ~ /^[[:space:]]*-/) ; else
                if (buf !~ /--hash=sha256:/) print NR ": " buf
            }
        }
    ' "$file")

    if [ -n "$bad" ]; then
        echo "ERROR: $file has package lines without --hash=sha256: pins:" >&2
        # Indent every line of $bad by two spaces (parameter expansion, no sed).
        printf '  %s\n' "${bad//$'\n'/$'\n'  }" >&2
        fail=1
    fi
done

if [ $fail -ne 0 ]; then
    echo "" >&2
    echo "Regenerate the file with hashes:" >&2
    echo "  uv pip compile pyproject.toml -o requirements.txt --generate-hashes" >&2
    echo "  # or" >&2
    echo "  pip-compile --generate-hashes pyproject.toml -o requirements.txt" >&2
fi

exit $fail
