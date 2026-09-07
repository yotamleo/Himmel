#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-oxlint-complexity.sh (HIMMEL-2154).
#
# Three cases: a clean fixture passes, a fixture function above the ratchet
# fails with a per-function listing, and a PATH with no bunx/bun fails OPEN
# (exit 0, loud WARN) rather than blocking the commit.
#
# Hermetic: throwaway tempdirs (never a git repo — same non-repo guarantee
# fixture-tempdir.sh gives the other suites here) holding a tiny
# scripts/lanes/*.mjs fixture, so the gate's own `git rev-parse
# --show-toplevel` falls back to the tempdir as repo root and only ever
# scans the fixture file, not this repo's real tree. OXLINT_COMPLEXITY_MAX
# is overridden low so a handful of if-statements is enough to trip the
# ratchet without needing a genuinely gnarly fixture. Needs a real
# bunx/oxlint on PATH for cases 1-2 (network-free once oxlint is cached);
# case 3 only needs PATH manipulation.
#
# Usage: bash scripts/hooks/test-check-oxlint-complexity.sh
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline (a here-string is not a pipeline, so `set -o pipefail` cannot
# report a SUCCESSFUL early match as a failed producer). HIMMEL-1430.
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
GATE="$SCRIPT_DIR/check-oxlint-complexity.sh"
# shellcheck source=../lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/fixture-tempdir.sh"

# Resolve bash ONCE from the suite's own unmodified PATH, before any test
# hands the gate a narrowed one (HIMMEL-2520, shape from HIMMEL-2470/
# HIMMEL-1567). Case 3 below invokes this absolute path so the narrowed PATH
# decides what the GATE sees, never whether it can start at all.
BASH_ABS=$(command -v bash)
if [ -z "$BASH_ABS" ]; then
    echo "FATAL: cannot resolve bash on PATH" >&2
    exit 1
fi
# Refusing a relative PATH is deliberate: these are hermetic fixtures.
# A bash resolved through a relative PATH means the invoking environment
# is already broken in a way that makes any result untrustworthy
# (HIMMEL-2520, CR [codex-1]).
case "$BASH_ABS" in
    /*) ;;
    *) echo "FATAL: bash resolved to a non-absolute path ('$BASH_ABS') — this fixture invokes it after a cd and/or as a shim shebang, both of which need an absolute path" >&2; exit 1 ;;
esac

FAILED=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label"
    else
        echo "FAIL $label"
        echo "     expected: $expected"
        echo "     actual:   $actual"
        FAILED=$((FAILED + 1))
    fi
}

assert_says() {
    local label="$1" needle="$2" text="$3"
    if grepq "$text" -- "$needle"; then
        echo "PASS $label"
    else
        echo "FAIL $label"
        echo "     output: $text"
        FAILED=$((FAILED + 1))
    fi
}

if ! command -v bunx >/dev/null 2>&1; then
    echo "SKIP test-check-oxlint-complexity: bunx not on PATH — cannot exercise the pass/fail cases"
    exit 0
fi

make_clean_fixture() {
    local dir
    dir=$(fixture_mktemp_dir) || return 1
    mkdir -p "$dir/scripts/lanes"
    cat > "$dir/scripts/lanes/clean.mjs" <<'EOF'
export function add(a, b) {
  return a + b;
}
EOF
    echo "$dir"
}

make_regressed_fixture() {
    local dir i
    dir=$(fixture_mktemp_dir) || return 1
    mkdir -p "$dir/scripts/lanes"
    {
        echo 'export function branchy(n) {'
        # oxlint's complexity rule only reports functions above ITS OWN
        # default max (20) in the first place, regardless of our ratchet —
        # so the fixture needs real complexity above 20, not just above the
        # (lower) OXLINT_COMPLEXITY_MAX the test overrides below. 25
        # branches -> complexity 26.
        i=1
        while [ "$i" -le 25 ]; do
            echo "  if (n === $i) return $i;"
            i=$((i + 1))
        done
        echo '  return 0;'
        echo '}'
    } > "$dir/scripts/lanes/branchy.mjs"
    echo "$dir"
}

# --- Case 1: clean fixture, threshold well above its complexity → passes ---
CLEAN=$(make_clean_fixture) || exit 1
rc=0
out=$(cd "$CLEAN" && OXLINT_COMPLEXITY_MAX=5 bash "$GATE" 2>&1) || rc=$?
assert_eq "clean fixture → gate passes (exit 0)" "0" "$rc"
rm -rf "$CLEAN"

# --- Case 2: fixture function (complexity 26) above a lowered ratchet → fails ---
REGRESSED=$(make_regressed_fixture) || exit 1
rc=0
out=$(cd "$REGRESSED" && OXLINT_COMPLEXITY_MAX=22 bash "$GATE" 2>&1) || rc=$?
assert_eq "regressed fixture → gate blocks (exit 1)" "1" "$rc"
assert_says "regressed fixture → names the offending function" "branchy" "$out"
assert_says "regressed fixture → names the ratchet value" "max 22" "$out"
rm -rf "$REGRESSED"

# --- Case 3: bunx/bun absent from PATH → fails OPEN (exit 0, loud WARN) ---
#
# An allowlist PATH -- an EMPTY scratch dir, so bunx/bun are absent
# regardless of where they live on the host (HIMMEL-2520, shape from
# HIMMEL-2470). The prior version filtered PATH by NAME
# (`grep -viE '(^|/)\.?bun(/bin)?$'`), which matches a `~/.bun/bin`-shaped
# directory but NOT `/usr/bin` -- on a host where bun/bunx ship in /usr/bin
# (Arch/CachyOS: both live there), that filter left bunx fully reachable and
# the gate correctly never warned, so this case silently tested nothing. The
# gate needs no external tool before its own bunx check (`git rev-parse
# --show-toplevel` falls back to `pwd` on failure, `command -v bunx` is a
# bash builtin, verified empirically) -- an EMPTY allowlist is sufficient,
# and it is a stronger no-bunx guarantee than filtering names ever was.
NOTOOL=$(make_clean_fixture) || exit 1
NO_BUNX_PATH=$(fixture_mktemp_dir) || exit 1
# Positive control for the instrument: the allowlist PATH resolves no bunx
# or bun at all. A "bunx not found" verdict proves nothing if bunx was never
# removed.
if PATH="$NO_BUNX_PATH" command -v bunx >/dev/null 2>&1 || PATH="$NO_BUNX_PATH" command -v bun >/dev/null 2>&1; then
    echo "FAIL fixture control: allowlist PATH still resolves bun/bunx"
    FAILED=$((FAILED + 1))
else
    echo "PASS fixture control: allowlist PATH resolves no bun/bunx"
fi
rc=0
out=$(cd "$NOTOOL" && PATH="$NO_BUNX_PATH" "$BASH_ABS" "$GATE" 2>&1) || rc=$?
assert_eq "no bunx on PATH → gate fails open (exit 0)" "0" "$rc"
assert_says "no bunx on PATH → loud WARN" "WARN" "$out"
rm -rf "$NOTOOL" "$NO_BUNX_PATH"

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "$FAILED case(s) FAILED"
exit 1
