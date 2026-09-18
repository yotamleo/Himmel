#!/usr/bin/env bash
# scripts/lib/red-control-extraction-lint.sh -- repo-wide gate against a
# specific RED-control fragility class (HIMMEL-3154 / HIMMEL-3018): a test
# suite extracting a RED-control mutant via `git show <historical-sha>:<path>`
# at test time. Once the introducing PR's branch is squash-merged, that
# commit is permanently unreachable from a fresh clone of origin -- and even
# when the commit stays a reachable main ancestor, the extraction still fails
# FATAL on a shallow clone or a source archive, neither of which carries full
# history. #810 fixed two suites with per-file inline guards (grep for the
# pattern, `fail` if found); this is the repo-wide equivalent so every
# `test-*.sh` suite is covered by one check, not one copy-pasted per file.
#
# Unlike scripts/lib/red-control-lint.sh (HIMMEL-2544, a DIFFERENT, advisory-
# only tool for a DIFFERENT defect class -- vacuous mutation controls, always
# exits 0 by contract), this is a real gate: it exits nonzero on a hit. Its
# own suite (test-red-control-extraction-lint.sh) is what wires it into CI --
# run-shell-tests.sh auto-discovers every test-*.sh under scripts/, so no
# separate registration is needed.
#
# Usage: bash scripts/lib/red-control-extraction-lint.sh [PATH...]
#   PATH may be a file or a directory; directories are walked for test-*.sh.
#   With no PATH, the repo's scripts/ directory is scanned, resolved from
#   this script's own location (never from $PWD).
# Output: one `<file>:<line>: <content>` line per hit on stdout.
# Exit: 0 with no hits, 1 with one or more hits, 2 on a scan-setup failure.
set -uo pipefail

usage() {
    cat <<'USAGE'
Usage: bash scripts/lib/red-control-extraction-lint.sh [PATH...]

Flags a test suite that extracts a RED-control mutant via
`git show <7-40 hex sha>:<path>` -- unreachable from a shallow clone or
source archive, and permanently gone once a squash-merged PR branch is
deleted (HIMMEL-3154 / HIMMEL-3018). Use a committed fixtures/red-control/
snapshot instead.

  PATH   a file or directory to scan (directories are walked for test-*.sh).
         Defaults to the repo's scripts/ directory.

Prints one "<file>:<line>: <content>" line per hit on stdout. Exit 0 = clean,
1 = hit(s) found, 2 = scan-setup failure.
USAGE
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

roots=()
if [ "$#" -gt 0 ]; then
    for r in "$@"; do roots+=("$r"); done
else
    roots=("$DEFAULT_ROOT")
fi

# A 7-40 hex literal OR a `*_SHA`-suffixed shell variable, immediately before
# `:<path>` -- narrower than a bare "show ... :" scan (which false-positives
# repo-wide on refs/checkpoints/..., HEAD:file, bare :file index refs, and
# branch refs -- all legitimate, and none of them a historical-blob
# extraction). Real offending code shares one quoted string across the
# var/sha and the path (e.g. "$PRE_RC4_SHA:scripts/...", "$SHA":file with the
# closing quote AFTER the colon is a different, rarer shape and still caught
# by the SHA-variable branch since the quote is optional here).
#
# ponytail: a historical-ref variable whose name does not end in `_SHA`
# escapes this gate -- e.g. the HIMMEL-3018 motivating case itself,
# `git show "$BASE_PRE2831_1:scripts/..."`. Widening the pattern to match
# any `$VAR:path` would false-positive on legitimate ref vars (branch names,
# `$commit:file`, etc.), so this is a deliberate trade-off, not an oversight.
# Convention: name new historical-ref vars `*_SHA`, or add a per-file guard
# (see test-leak-classes.sh) when a suite genuinely needs a differently-named
# one.
PATTERN='git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?show[[:space:]]+"?(\$\{?[A-Za-z_][A-Za-z0-9_]*_SHA\}?|[0-9a-fA-F]{7,40})"?:[^[:space:]]+'

files=()
for r in "${roots[@]}"; do
    if [ -f "$r" ]; then
        files+=("$r")
    elif [ -d "$r" ]; then
        while IFS= read -r f; do
            files+=("$f")
        done < <(find "$r" -type f -name 'test-*.sh' 2>/dev/null | sort)
    else
        echo "red-control-extraction-lint: FAILED to scan $r (not a file or directory)" >&2
        exit 2
    fi
done

hits=0
for f in "${files[@]}"; do
    while IFS=: read -r lineno content; do
        [ -n "$lineno" ] || continue
        printf '%s:%s: %s\n' "$f" "$lineno" "$content"
        hits=$((hits+1))
    done < <(grep -nE "$PATTERN" "$f" | grep -vE '^[0-9]+:[[:space:]]*#')
done

if [ "$hits" -gt 0 ]; then
    echo "red-control-extraction-lint: $hits hit(s)" >&2
    exit 1
fi
echo "red-control-extraction-lint: 0 hits in ${#files[@]} test-*.sh files scanned" >&2
exit 0
