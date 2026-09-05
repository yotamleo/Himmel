#!/usr/bin/env bash
# Smoke test for scripts/cr/docs-audit-panel.sh (HIMMEL-2226).
#
# Hermetic: builds a throwaway "toolroot" fixture (mirroring the real
# scripts/cr, scripts/lib, scripts/guardrails layout so the SUT's
# SCRIPT_DIR/HIMMEL_ROOT derivation resolves inside the fixture) plus a
# throwaway git repo the SUT's own git commands run against. The real
# critic-panel.sh is NEVER on disk under the fixture's HIMMEL_ROOT - a stub
# takes its place, so the (paid, real-money) critic panel can never be
# invoked no matter what the SUT does. PATH is stripped of rtk's install dir
# for every SUT invocation, so the SUT's `command -v rtk` reliably fails and
# the rtk-retry branch never fires - deterministic, and it can never write
# rtk's own cache/log files outside this fixture.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT_SRC="$DIR/docs-audit-panel.sh"

fail=0
check() { [ "$1" = "$2" ] || { echo "FAIL: $3 - got '$1' want '$2'"; fail=1; }; }
contains() {
    case "$1" in
        *"$2"*) : ;;
        *) echo "FAIL: $3 - expected output to contain '$2', got: $1"; fail=1 ;;
    esac
}
not_contains() {
    case "$1" in
        *"$2"*) echo "FAIL: $3 - unexpectedly contains '$2'"; fail=1 ;;
        *) : ;;
    esac
}

tmp="$(mktemp -d -t docs-audit-panel-test.XXXXXX)"; trap 'rm -rf "$tmp"' EXIT

# --- Fixture toolroot: docs-audit-panel.sh (SUT) + the two real libs it
# sources + a STUBBED critic-panel.sh, all under one throwaway HIMMEL_ROOT. ---
root="$tmp/root"
mkdir -p "$root/scripts/cr" "$root/scripts/lib" "$root/scripts/guardrails"
cp "$SUT_SRC" "$root/scripts/cr/docs-audit-panel.sh"
cp "$DIR/../lib/load-dotenv.sh" "$root/scripts/lib/load-dotenv.sh"
cp "$DIR/../guardrails/lib.sh" "$root/scripts/guardrails/lib.sh"
SUT="$root/scripts/cr/docs-audit-panel.sh"

STUB_MARKER="$tmp/stub-called"
STUB="$root/scripts/cr/critic-panel.sh"
cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
cat >/dev/null   # swallow the piped diff, like the real panel does
[ -n "${STUB_MARKER:-}" ] && : > "$STUB_MARKER"
[ -n "${STUB_OUT:-}" ] && printf '%s\n' "$STUB_OUT"
[ -n "${STUB_ERR:-}" ] && printf '%s\n' "$STUB_ERR" >&2
exit "${STUB_RC:-0}"
STUBEOF
chmod +x "$STUB"
export STUB_MARKER

# --- A tiny real git repo: the SUT's git commands run against this as CWD. --
repo="$tmp/repo"
mkdir -p "$repo"
(
    cd "$repo" || exit 1
    git init -q -b main .
    git config user.email t@t
    git config user.name t
    git config commit.gpgsign false
    echo base > f.txt
    git add f.txt
    git commit -q -m init
    git checkout -q -b feat
    echo change >> f.txt
    git commit -q -am change
)
head_feat="$(git -C "$repo" rev-parse feat)"
head_main="$(git -C "$repo" rev-parse main)"

# PATH with rtk's actual install dir stripped (see file header) - resolved
# via `command -v`, not a hardcoded `.local/bin` guess, so this stays
# hermetic wherever rtk happens to be installed.
rtk_bin="$(command -v rtk 2>/dev/null || true)"
if [ -n "$rtk_bin" ]; then
    rtk_dir="$(cd "$(dirname "$rtk_bin")" && pwd)"
    SAFE_PATH="$(printf '%s\n' "$PATH" | tr ':' '\n' | grep -v -x -F "$rtk_dir" | tr '\n' ':')"
else
    SAFE_PATH="$PATH"
fi
SAFE_PATH="${SAFE_PATH%:}"

stdout_file="$tmp/out.txt"
stderr_file="$tmp/err.txt"
run_sut() {
    rm -f "$STUB_MARKER"
    ( cd "$repo" && PATH="$SAFE_PATH" bash "$SUT" "$@" ) >"$stdout_file" 2>"$stderr_file"
    echo $?
}

# 1. Missing --head refuses with usage error, exit 2.
rc=$(run_sut --branch feat)
check "$rc" "2" "T1 rc"
contains "$(cat "$stderr_file")" "docs-audit-panel: --head is required" "T1 stderr"
check "$(cat "$stdout_file")" "" "T1 stdout"

# 2. Missing --branch refuses with usage error, exit 2.
rc=$(run_sut --head "$head_feat")
check "$rc" "2" "T2 rc"
contains "$(cat "$stderr_file")" "docs-audit-panel: --branch is required" "T2 stderr"
check "$(cat "$stdout_file")" "" "T2 stdout"

# 3. CR_REQUIRE_CROSS_MODEL unset/falsy: the whole lane is disabled, the
# panel is NEVER invoked, no output on either stream, exit 0.
unset CR_REQUIRE_CROSS_MODEL CR_PROFILE 2>/dev/null || true
export STUB_OUT="SHOULD-NOT-APPEAR" STUB_ERR="panel-availability: fake ok" STUB_RC=0
rc=$(run_sut --head "$head_feat" --branch feat)
check "$rc" "0" "T3 rc"
check "$(cat "$stdout_file")" "" "T3 stdout"
check "$(cat "$stderr_file")" "" "T3 stderr"
[ ! -e "$STUB_MARKER" ] || { echo "FAIL: T3 stub was invoked with CR_REQUIRE_CROSS_MODEL unset"; fail=1; }

# 4. CR_PROFILE=none wins even under CR_REQUIRE_CROSS_MODEL: prints the
# claude-only note, panel never invoked, exit 0.
export CR_REQUIRE_CROSS_MODEL=1
export CR_PROFILE=none
rc=$(run_sut --head "$head_feat" --branch feat)
check "$rc" "0" "T4 rc"
check "$(cat "$stdout_file")" "" "T4 stdout"
check "$(cat "$stderr_file")" "docs-audit: claude-only (CR_PROFILE=none) - cross-model critic not launched; marker stays closed under CR_REQUIRE_CROSS_MODEL until a non-Claude responder exists or CR_PROFILE is unset" "T4 stderr"
[ ! -e "$STUB_MARKER" ] || { echo "FAIL: T4 stub was invoked under CR_PROFILE=none"; fail=1; }

# 5. Empty diff (head == base) prints the skip note, panel never invoked.
export CR_REQUIRE_CROSS_MODEL=1
unset CR_PROFILE 2>/dev/null || true
rc=$(run_sut --head "$head_main" --branch main)
check "$rc" "0" "T5 rc"
check "$(cat "$stdout_file")" "" "T5 stdout"
check "$(cat "$stderr_file")" "docs-audit cross-model critic skipped: empty diff (marker will stay closed under CR_REQUIRE_CROSS_MODEL unless another non-Claude avail-ok row exists)" "T5 stderr"
[ ! -e "$STUB_MARKER" ] || { echo "FAIL: T5 stub was invoked on an empty diff"; fail=1; }

# 6. Stubbed panel exit 7 (input-pin mismatch): ABORT, exit 7, nothing on
# stdout, the exact ABORT block on stderr and nothing else (HIMMEL-1175,
# HIMMEL-1984 - never a degrade).
export CR_REQUIRE_CROSS_MODEL=1
unset CR_PROFILE 2>/dev/null || true
export STUB_RC=7 STUB_OUT="should-be-discarded" STUB_ERR="panel-availability: fake unavailable (rc=7)"
rc=$(run_sut --head "$head_feat" --branch feat)
check "$rc" "7" "T6 rc"
check "$(cat "$stdout_file")" "" "T6 stdout"
expect_abort="/pr-check ABORT - docs-audit critic-panel.sh exit 7: the checkout or the diff
base moved since step 1, so the review inputs no longer match the branch/SHA/base
the ledger would stamp (HIMMEL-1175, HIMMEL-1984). Nothing was reviewed and
nothing was recorded. Re-run /pr-check from step 1."
check "$(cat "$stderr_file")" "$expect_abort" "T6 stderr exact ABORT block"
[ -e "$STUB_MARKER" ] || { echo "FAIL: T6 stub was never invoked"; fail=1; }

# 7. Stubbed panel exit 1 (all critics failed): fail-OPEN degrade, not an
# abort - findings discarded (stdout empty), a loud stderr message, exit 0.
export CR_REQUIRE_CROSS_MODEL=1
unset CR_PROFILE 2>/dev/null || true
export STUB_RC=1 STUB_OUT="should-be-discarded" STUB_ERR="panel-availability: fake unavailable (rc=1)"
rc=$(run_sut --head "$head_feat" --branch feat)
check "$rc" "0" "T7 rc (degrade, not abort)"
check "$(cat "$stdout_file")" "" "T7 stdout (findings discarded)"
contains "$(cat "$stderr_file")" "docs-audit cross-model critic unavailable (all critics failed) - record any panel-availability unavailable rows; under CR_REQUIRE_CROSS_MODEL the marker will stay closed until a non-Claude critic records avail ok" "T7 stderr all-critics-failed note"
contains "$(cat "$stderr_file")" "panel-availability: fake unavailable (rc=1)" "T7 stderr re-emits the panel's availability line"
[ -e "$STUB_MARKER" ] || { echo "FAIL: T7 stub was never invoked"; fail=1; }

# 8. Stubbed panel exit 0: findings land on stdout ONLY, panel-availability
# lands on stderr ONLY - the two streams never merge.
export CR_REQUIRE_CROSS_MODEL=1
unset CR_PROFILE 2>/dev/null || true
export STUB_RC=0 STUB_OUT="[docsaudit-1] some finding" STUB_ERR="panel-availability: fake ok"
rc=$(run_sut --head "$head_feat" --branch feat)
check "$rc" "0" "T8 rc"
check "$(cat "$stdout_file")" "[docsaudit-1] some finding" "T8 stdout carries the findings"
check "$(cat "$stderr_file")" "panel-availability: fake ok" "T8 stderr carries the availability line"
not_contains "$(cat "$stdout_file")" "panel-availability" "T8 stdout must not carry the availability line"
not_contains "$(cat "$stderr_file")" "docsaudit-1" "T8 stderr must not carry the findings"
[ -e "$STUB_MARKER" ] || { echo "FAIL: T8 stub was never invoked"; fail=1; }

# 9. HIMMEL-2542: a --head that names no commit in this repo ABORTs at exit 7
# naming the ARGUMENT, before any git command consumes it. Pre-fix, the bare
# `git rev-parse` accepted the well-formed 40-hex value, `git diff` then failed
# rc=128, and the lane reported "cross-model critic unavailable" at exit 0 -
# a caller error wearing a reviewer outage's clothes.
bogus_sha="0000000000000000000000000000000000000000"
export CR_REQUIRE_CROSS_MODEL=1
unset CR_PROFILE 2>/dev/null || true
export STUB_RC=0 STUB_OUT="MUST-NOT-REVIEW" STUB_ERR="panel-availability: fake ok"
rc=$(run_sut --head "$bogus_sha" --branch feat)
check "$rc" "7" "T9 rc (unresolvable --head aborts)"
check "$(cat "$stdout_file")" "" "T9 stdout empty"
contains "$(cat "$stderr_file")" "--head $bogus_sha does not resolve to a commit in this repo" "T9 ABORT names the argument"
not_contains "$(cat "$stderr_file")" "critic unavailable" "T9 must not report a critic outage for a caller error"
[ ! -e "$STUB_MARKER" ] || { echo "FAIL: T9 the panel was invoked on an unresolvable pin"; fail=1; }

# 10. NEGATIVE CONTROL for T9 (HIMMEL-2518 control contract): a mutant with the
# T9 guard deleted must RUN, PRODUCE a value, and produce the SPECIFIC wrong
# value - exit 0 plus the misleading "cross-model critic unavailable" line.
# Each property gets its own failure message so a crashed mutant can never pass
# for a reproduced defect. The mutant lives inside the fixture root, because
# the SUT resolves critic-panel.sh from its own SCRIPT_DIR/../.. and a mutant
# written elsewhere could reach the REAL, paid panel.
mutant="$root/scripts/cr/docs-audit-panel.mutant.sh"
awk '
    index($0, "git rev-parse --verify --quiet") && index($0, "head^{commit}") { drop = 1 }
    drop && $0 == "fi" { drop = 0; next }
    !drop { print }
' "$SUT" > "$mutant"
if cmp -s "$SUT" "$mutant"; then
    echo "FAIL: T10 control is VACUOUS - the guard-deleting mutation matched nothing, so the mutant IS the fixed script"; fail=1
elif grep -q 'does not resolve to a commit in this repo' "$mutant"; then
    echo "FAIL: T10 control is VACUOUS - the mutant still carries the guard's ABORT message"; fail=1
else
    rm -f "$STUB_MARKER"
    mutant_rc=0
    ( cd "$repo" && PATH="$SAFE_PATH" bash "$mutant" --head "$bogus_sha" --branch feat ) \
        >"$stdout_file" 2>"$stderr_file" || mutant_rc=$?
    # (a) the SPECIFIC wrong value, not merely "different from 7".
    check "$mutant_rc" "0" "T10 control reproduces the exact defect (exit 0 on an unresolvable pin)"
    # (b) it RAN and produced a value: the outage line is emitted only after
    # the SUT got past arg handling and actually attempted the diff.
    contains "$(cat "$stderr_file")" "docs-audit cross-model critic unavailable - git diff failed rc=" "T10 control RAN and produced the misleading outage message"
fi

unset STUB_RC STUB_OUT STUB_ERR CR_REQUIRE_CROSS_MODEL CR_PROFILE 2>/dev/null || true

[ "$fail" -eq 0 ] && echo "PASS test-docs-audit-panel" || exit 1
