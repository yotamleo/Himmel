#!/usr/bin/env bash
# scripts/telegram/test-glm-guard-parity.sh — HIMMEL-2204 cross-language
# parity test for the PHI/egress predicates.
#
# WHY: scripts/guardrails/phi-egress-lib.sh (HIMMEL-1776) is the shared bash
# implementation of the file-readability predicate that guards the phi-roots
# / egress-denylist lists; scripts/telegram/glm-guard.ts::checkGlmGuards is an
# independent, hand-kept TypeScript reimplementation of the SAME contract
# (marker check + list-membership check + fail-closed-on-unreadable) for the
# env-only GLM spawn path, which cannot source a bash lib. Two implementations
# of one security contract can silently drift (HIMMEL-1748/#1680 already
# happened once between two BASH copies before extraction). A parity test
# cannot make the drift impossible the way extraction would, but it can make
# it visible: this suite runs the SAME fixture inputs through both sides and
# asserts they reach the SAME allow/deny verdict.
#
# The bash side runs the REAL root-scan function — `path_under_any` is
# extracted verbatim (via sed) from scripts/claude-glm, glm-guard.ts's OWN
# documented sync partner (named in its header) — not a test-authored
# reimplementation, so drift in the ACTUAL deployed bash list-matching logic
# is caught, not just drift in this test's idea of it (HIMMEL-2204 CR round
# 1, codex-1: the first cut hand-rolled this loop; codex correctly flagged
# that a fixture-passing hand-rolled copy proves nothing about the real
# script). It also happens to be case-sensitive prefix matching, matching
# Node's `path.resolve()` string semantics (graphify-fence.sh's classifier
# uses case-INSENSITIVE matching instead, for a different, broader purpose;
# see HIMMEL-2204 mission notes for why that pairing does not apply here).
# The `.salus`/`.salus-profile` marker check stays test-owned: it is two
# inline `[ -e ... ]` lines in checkGlmGuards, not a function claude-glm
# exposes for extraction (claude-glm's own marker check is inline too, and
# uses `-f` instead of `-e` — a latent, currently-inert divergence reported
# separately in the HIMMEL-2204 PR body, not fixed here).
#
# The TS side runs the REAL checkGlmGuards() via glm-guard-verdict.ts, which
# normalizes {ok, reason} to a coarse verdict label so this suite compares
# ONLY the verdict, never the mechanism (an unreadable-file exception in TS
# and a non-zero rc in bash can both "fail" while meaning different things —
# per the HIMMEL-2204 brief, only the verdict is asserted here).
#
# bun is a RUNTIME capability this suite needs (glm-guard.ts is only run
# through the project's existing bun toolchain for scripts/telegram). Where
# it is absent the suite SKIPs loudly (HIMMEL-1788) rather than passing
# silently; registered in SUITE_REQUIRE_TOOL (scripts/ci/run-shell-tests.sh,
# HIMMEL-1792) so a bun-less host shows an attributed [SKIP], not a quiet
# green run with zero coverage.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
CLAUDE_GLM="$REPO_ROOT/scripts/claude-glm"
TS_VERDICT="$HERE/glm-guard-verdict.ts"

if ! command -v bun >/dev/null 2>&1; then
  echo "[SKIP] test-glm-guard-parity.sh — bun not found on PATH; the glm-guard.ts side of the HIMMEL-2204 parity check did NOT run on this host."
  exit 0
fi
for f in "$CLAUDE_GLM" "$TS_VERDICT"; do
  if [ ! -f "$f" ]; then echo "FAIL: $f not found"; exit 1; fi
done

# Extract the REAL path_under_any() function verbatim from scripts/claude-glm
# (bounded sed: opening line to the closing brace at column 0) rather than
# hand-copying its logic — sourcing claude-glm itself would run its whole
# launcher body, not just define the function.
_extracted_path_under_any="$(mktemp)"
sed -n '/^path_under_any() {/,/^}/p' "$CLAUDE_GLM" > "$_extracted_path_under_any"
if [ ! -s "$_extracted_path_under_any" ]; then
  echo "FAIL: could not extract path_under_any() from $CLAUDE_GLM (function moved or renamed?)"; exit 1
fi
# shellcheck disable=SC1090
. "$_extracted_path_under_any"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s (bash=%s ts=%s)\n' "$1" "$2" "$3"; failures=$((failures+1)); }

# _bash_under_any <target> <listfile> -> hit | miss | unreadable, from the
# REAL claude-glm path_under_any (0=hit, 2=unreadable, else miss).
_bash_under_any() {
    local target="$1" listfile="$2" rc
    path_under_any "$target" "$listfile"; rc=$?
    case "$rc" in
        0) echo hit ;;
        2) echo unreadable ;;
        *) echo miss ;;
    esac
}

# _bash_glm_guard_verdict <cwd> <cfgdir> -> the bash-side reference verdict,
# in the same label space glm-guard-verdict.ts prints.
_bash_glm_guard_verdict() {
    local cwd="$1" cfgdir="$2" rc
    [ -e "$cwd/.salus" ] && { echo DENY_SALUS; return; }
    [ -e "$cwd/.salus-profile" ] && { echo DENY_SALUS_PROFILE; return; }
    rc="$(_bash_under_any "$cwd" "$cfgdir/phi-roots")"
    case "$rc" in
        unreadable) echo DENY_UNREADABLE_PHI_ROOTS; return ;;
        hit)        echo DENY_PHI_ROOTS; return ;;
    esac
    rc="$(_bash_under_any "$cwd" "$cfgdir/egress-denylist")"
    case "$rc" in
        unreadable) echo DENY_UNREADABLE_EGRESS_DENYLIST; return ;;
        hit)        echo DENY_EGRESS_DENYLIST; return ;;
    esac
    echo ALLOW
}

# check <label> <cwd> <cfgdir> -> runs both sides, compares verdicts.
check() {
    local label="$1" cwd="$2" cfgdir="$3" bash_v ts_v
    bash_v="$(_bash_glm_guard_verdict "$cwd" "$cfgdir")"
    ts_v="$(bun "$TS_VERDICT" "$cwd" "$cfgdir" 2>/dev/null)"
    if [ "$bash_v" = "$ts_v" ]; then
        pass "$label -> $bash_v"
    else
        fail "$label" "$bash_v" "$ts_v"
    fi
}

# --- fixture workspace -------------------------------------------------
WS="$(mktemp -d)"
if command -v cygpath >/dev/null 2>&1; then WS="$(cygpath -m "$WS")"; fi
trap 'rm -rf "$WS" "$_extracted_path_under_any"' EXIT

CFG="$WS/cfg"; mkdir -p "$CFG"
WORK="$WS/work"; mkdir -p "$WORK/sub"
OTHER="$WS/other-workspace"; mkdir -p "$OTHER"

check "clean cwd, no guard config" "$WORK" "$CFG"

: > "$WORK/.salus"
check ".salus marker present" "$WORK" "$CFG"
rm -f "$WORK/.salus"

: > "$WORK/.salus-profile"
check ".salus-profile-only marker present (no .salus)" "$WORK" "$CFG"
rm -f "$WORK/.salus-profile"

printf '%s\n' "$WORK" > "$CFG/phi-roots"
check "phi-roots exact-match hit" "$WORK" "$CFG"
rm -f "$CFG/phi-roots"

printf '%s/\n' "$WORK" > "$CFG/phi-roots"
check "phi-roots trailing-slash root, descendant path" "$WORK/sub" "$CFG"
rm -f "$CFG/phi-roots"

printf '%s\n' "$WORK" > "$CFG/egress-denylist"
check "egress-denylist sibling-prefix does not false-positive" "$WORK-sibling-does-not-exist" "$CFG"
rm -f "$CFG/egress-denylist"

printf '%s\n' "$WORK" > "$CFG/egress-denylist"
check "egress-denylist exact-match hit" "$WORK" "$CFG"
check "egress-denylist miss on an unrelated cwd" "$OTHER" "$CFG"
rm -f "$CFG/egress-denylist"

mkdir "$CFG/phi-roots"
check "phi-roots list is a DIRECTORY -> unreadable, fails closed" "$WORK" "$CFG"
rmdir "$CFG/phi-roots"

mkdir "$CFG/egress-denylist"
check "egress-denylist list is a DIRECTORY -> unreadable, fails closed" "$WORK" "$CFG"
rmdir "$CFG/egress-denylist"

echo "---"
if [ "$failures" -eq 0 ]; then
    echo "test-glm-guard-parity: all fixture rows agree between phi-egress-lib.sh and glm-guard.ts"
    exit 0
else
    echo "test-glm-guard-parity: $failures divergence(s) found — see FAIL lines above"
    exit 1
fi
