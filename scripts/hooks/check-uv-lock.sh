#!/usr/bin/env bash
# Pre-commit hook: enforce uv.lock integrity for every pyproject.toml.
# For each pyproject.toml:
#   - assert sibling uv.lock exists and is tracked in git
#   - run `uv lock --check` to detect drift between pyproject.toml and uv.lock
# Soft-fail when `uv` is missing so contributors who don't touch Python aren't blocked.
set -euo pipefail

# bash 3.2-safe (macOS): no mapfile.
projects=()
while IFS= read -r _line; do projects+=("$_line"); done < <(find . -maxdepth 4 -name pyproject.toml \
    -not -path '*/.venv/*' \
    -not -path '*/node_modules/*' \
    -not -path '*/.claude/*')

if [ ${#projects[@]} -eq 0 ]; then
    echo "→ uv-lock-integrity: no pyproject.toml found — nothing to check"
    exit 0
fi

if ! command -v uv >/dev/null 2>&1; then
    echo "→ uv-lock-integrity: 'uv' not installed — skipping drift check"
    echo "  Install: https://docs.astral.sh/uv/getting-started/installation/"
    # Still verify uv.lock presence + tracking (does not require uv binary).
fi

fail=0
for pyproject in "${projects[@]}"; do
    dir=$(dirname "$pyproject")
    lock="$dir/uv.lock"

    if [ ! -f "$lock" ]; then
        echo "ERROR: $pyproject has no sibling uv.lock." >&2
        echo "       Run 'uv lock' in $dir and commit the result." >&2
        fail=1
        continue
    fi

    if ! git ls-files --error-unmatch "$lock" >/dev/null 2>&1; then
        echo "ERROR: $lock exists but is not tracked in git." >&2
        echo "       Run 'git add $lock'." >&2
        fail=1
        continue
    fi

    if command -v uv >/dev/null 2>&1; then
        echo "→ uv lock --check in $dir"
        if ! (cd "$dir" && uv lock --check); then
            echo "ERROR: uv.lock is out of sync with pyproject.toml in $dir." >&2
            echo "       Run 'uv lock' in $dir and commit the updated uv.lock." >&2
            fail=1
        fi
    fi
done

exit $fail
