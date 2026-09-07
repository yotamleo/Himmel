#!/usr/bin/env bash
# Zero-violation oxlint bug-class hardening gate (HIMMEL-2163/2802).
#
# Runs a pinned oxlint with a fixed set of bug-class rules (correctness rules
# that are OFF by default across oxc/eslint/promise, plus selected unicorn
# rules) over scripts/lanes, scripts/jira/src, scripts/telegram,
# scripts/luna-vitals, scripts/himmel-run, and direct hook/observability JS.
# dist/, node_modules/, and test fixtures are excluded.
#
# Zero tolerance applies to findings AND tool integrity: only a missing bunx is
# fail-open. A runner error, missing findings JSON, or inconsistent root blocks
# the commit loudly rather than turning an unevaluated gate into a pass.
set -uo pipefail

OXLINT_VERSION=1.81.0

# ---- rule set (HIMMEL-2163 audit) --------------------------------------
# oxc/bad-bitwise-operator and eslint/no-throw-literal each had exactly one
# hit in-scope, both VERIFIED FALSE POSITIVES (annotated with an
# oxlint-disable, not "fixed") — see scripts/hooks/guardrail-block.mjs:880
# and scripts/jira/src/mcp.test.ts:87. eslint/array-callback-return had one
# genuine one-liner, fixed. Every other rule below was already at zero.
RULES="unicorn/prefer-node-protocol oxc/bad-bitwise-operator no-self-compare no-constructor-return no-unreachable-loop no-unmodified-loop-condition no-fallthrough no-inner-declarations no-prototype-builtins no-new-wrappers no-proto accessor-pairs no-return-assign oxc/misrefactored-assign-op oxc/no-this-in-exported-function promise/no-multiple-resolved promise/no-promise-in-callback promise/no-return-wrap unicorn/no-instanceof-builtins unicorn/no-object-as-default-parameter unicorn/no-new-buffer no-throw-literal array-callback-return"
# -------------------------------------------------------------------------

cwd=$(pwd -P)
repo_root=$(git rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "$cwd")
if [ -d "$repo_root" ]; then
    if canonical_root=$(cd "$repo_root" 2>/dev/null && pwd -P); then
        repo_root="$canonical_root"
    fi
fi

# A resolver may be stubbed or otherwise return a non-ancestor. Refuse before
# changing directory: linting a different tree is not a successful gate.
case "$cwd/" in
    "$repo_root/"*) ;;
    *)
        echo "check-oxlint-hardening: oxlint $OXLINT_VERSION root=$repo_root cwd=$cwd" >&2
        echo "WARN check-oxlint-hardening: cwd is outside resolved root — refusing to lint an unrelated tree" >&2
        exit 1
        ;;
esac

# Hermetic tests (and callers auditing an extracted tree) can be plain
# directories nested beneath another git checkout. If cwd itself presents one
# of this gate's repo-relative lint surfaces, it is the intended root; otherwise
# preserve the normal behavior of resolving the containing repository when
# invoked from an arbitrary subdirectory.
if [ "$cwd" != "$repo_root" ] && {
    [ -d "$cwd/scripts/lanes" ] ||
    [ -d "$cwd/scripts/jira/src" ] ||
    [ -d "$cwd/scripts/telegram" ] ||
    [ -d "$cwd/scripts/luna-vitals" ] ||
    [ -d "$cwd/scripts/himmel-run" ];
}; then
    repo_root="$cwd"
fi

echo "check-oxlint-hardening: oxlint $OXLINT_VERSION root=$repo_root cwd=$cwd" >&2
cd "$repo_root" || {
    echo "WARN check-oxlint-hardening: cannot enter resolved root — refusing to skip an unevaluated gate" >&2
    exit 1
}

if ! command -v bunx >/dev/null 2>&1; then
    echo "WARN check-oxlint-hardening: bunx not found on PATH — skipping hardening gate (fail-open)" >&2
    exit 0
fi

targets="scripts/lanes scripts/jira/src scripts/telegram scripts/luna-vitals scripts/himmel-run"

hook_js=""
for f in scripts/hooks/*.mjs scripts/hooks/*.js scripts/observability/*.mjs scripts/observability/*.js; do
    [ -e "$f" ] && hook_js="$hook_js $f"
done

warn_flags=""
for r in $RULES; do
    warn_flags="$warn_flags -W $r"
done

if ! command -v jq >/dev/null 2>&1; then
    echo "WARN check-oxlint-hardening: jq not found — refusing to pass an unevaluated hardening gate" >&2
    exit 1
fi

stderr_file=$(mktemp "${TMPDIR:-/tmp}/check-oxlint-hardening.XXXXXX") || {
    echo "WARN check-oxlint-hardening: could not allocate stderr capture — refusing to pass an unevaluated hardening gate" >&2
    exit 1
}
# Keep stdout isolated for strict JSON parsing. bunx may emit benign cache or
# package-resolution diagnostics on stderr even when oxlint evaluated cleanly.
# shellcheck disable=SC2086 # word-split on purpose: rule flags + directory/file list
out=$(bunx "oxlint@$OXLINT_VERSION" -A all $warn_flags --promise-plugin \
    --format json \
    --disable-nested-config \
    --ignore-pattern 'dist/**' \
    --ignore-pattern 'node_modules/**' \
    --ignore-pattern '**/fixtures/**' \
    --ignore-pattern '**/__fixtures__/**' \
    $targets $hook_js 2>"$stderr_file")
rc=$?
if ! err=$(< "$stderr_file"); then
    rm -f -- "$stderr_file"
    echo "WARN check-oxlint-hardening: could not read stderr capture — refusing to pass an unevaluated hardening gate" >&2
    exit 1
fi
rm -f -- "$stderr_file"

# Slurp enforces exactly one complete JSON document covering at least one file.
# Substring matching would accept truncated JSON, an error plus empty envelope,
# or a syntactically valid zero-file result that evaluated none of the targets.
diagnostic_count=$(printf '%s' "$out" | jq -ser '
  if length == 1
     and (.[0] | type) == "object"
     and (.[0].diagnostics | type) == "array"
     and (.[0].number_of_files | type) == "number"
     and (.[0].number_of_files > 0)
     and (.[0].number_of_files == (.[0].number_of_files | floor))
  then .[0].diagnostics | length
  else error("invalid oxlint diagnostics envelope")
  end
' 2>/dev/null)
json_rc=$?
stderr_error=$(printf '%s\n' "$err" | grep -Ei '^(error:|error |fatal:|No files found to lint)' || true)

# rc>=2 is an oxlint/runner failure even if it emitted partial diagnostics.
# rc 0/1 is meaningful only with one validated findings envelope and no explicit
# error banner. Benign stderr alone is not evidence that evaluation failed.
if [ "$rc" -ge 2 ] || [ "$json_rc" -ne 0 ] || [ -n "$stderr_error" ]; then
    echo "WARN check-oxlint-hardening: oxlint tool/JSON error — refusing to pass an unevaluated hardening gate (exit $rc)" >&2
    [ -z "$err" ] || printf '%s\n' "$err" >&2
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    exit 1
fi

if [ "$diagnostic_count" -eq 0 ]; then
    if [ "$rc" -ne 0 ]; then
        echo "WARN check-oxlint-hardening: oxlint tool error — empty findings JSON returned exit $rc" >&2
        [ -z "$err" ] || printf '%s\n' "$err" >&2
        printf '%s\n' "$out" >&2
        exit 1
    fi
    exit 0
fi

# A non-empty diagnostics array is a finding regardless of oxlint's status.
echo "check-oxlint-hardening: bug-class rule violation(s) in the zero-tolerance set:" >&2
[ -z "$err" ] || printf '%s\n' "$err" >&2
printf '%s\n' "$out" >&2
echo "" >&2
echo "Fix the violation(s) above. If a hit is a genuine false positive, annotate it with a targeted oxlint-disable comment naming the reason; do not change behavior merely to satisfy the linter." >&2
exit 1
