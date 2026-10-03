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
unhashed=0   # the regenerate hint only helps when a file was read and lacked hashes
for file in "$@"; do
    # pre-commit never passes a deleted file, so a missing path is a dangling
    # reference (HIMMEL-4144): fail closed rather than skip it.
    [ -f "$file" ] || { echo "ERROR: $file does not exist (or is not a regular file)" >&2; fail=1; continue; }
    [ -r "$file" ] || { echo "ERROR: $file is unreadable" >&2; fail=1; continue; }

    # `--generate-hashes` writes each pin across multiple physical lines using
    # trailing `\` continuations. Join those into one logical line per package
    # before checking that every package line carries --hash=sha256:.
    bad=$(awk '
        function check(joined,   l) {
            l = joined
            # A `#` at line start or after whitespace opens a comment; a hash
            # inside one must not satisfy the check (HIMMEL-4144).
            sub(/(^|[[:space:]])#.*$/, "", l)
            if (l ~ /^[[:space:]]*$/) return        # blank
            if (l ~ /^[[:space:]]*-/) return        # pip directive (-r, -c, --index-url, ...)
            if (l !~ /--hash=sha256:/) print NR ": " l
        }
        {
            # Same order as pip join_lines: a continuation is decided on the
            # RAW line, so a line whose backslash is followed by a comment does
            # not continue; a full-line comment ends the logical line; comments
            # are stripped from the JOINED line (HIMMEL-4144).
            if ($0 ~ /^[[:space:]]*#/) { if (buf != "") check(buf); buf = ""; next }
            buf = buf $0
            if ($0 ~ /\\$/) { sub(/\\[[:space:]]*$/, " ", buf); next }
            check(buf); buf = ""
        }
        END {
            # Flush a trailing buffer left dangling by a final \ continuation
            # at EOF (otherwise that line would silently skip validation).
            if (buf != "") check(buf)
        }
    ' <"$file")  # stdin, not an operand: awk reads `requirements=x.txt` as an assignment (HIMMEL-4132)

    if [ -n "$bad" ]; then
        echo "ERROR: $file has package lines without --hash=sha256: pins:" >&2
        # Indent every line of $bad by two spaces (parameter expansion, no sed).
        printf '  %s\n' "${bad//$'\n'/$'\n'  }" >&2
        fail=1
        unhashed=1
    fi
done

if [ $unhashed -ne 0 ]; then
    echo "" >&2
    echo "Regenerate the file with hashes:" >&2
    echo "  uv pip compile pyproject.toml -o requirements.txt --generate-hashes" >&2
    echo "  # or" >&2
    echo "  pip-compile --generate-hashes pyproject.toml -o requirements.txt" >&2
fi

exit $fail
