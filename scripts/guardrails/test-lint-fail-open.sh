#!/usr/bin/env bash
# test-lint-fail-open.sh — suite for lint-fail-open.sh (HIMMEL-1776).
#
# Usage: bash scripts/guardrails/test-lint-fail-open.sh
#
# Three jobs, in priority order:
#   1. PROVE EACH DETECTOR RED against a committed reconstruction of the
#      ORIGINAL pre-fix code it was built for (fixtures/fail-open/*.fxt) —
#      a lint that has never been shown to catch the bug it targets is
#      decoration. Each pre-fix fixture has a fixed twin that must pass
#      clean, so the lint is also shown to accept the shapes that actually
#      shipped as the fixes.
#   2. Assert the lint passes on the REAL guard surfaces as they stand —
#      this is the standing assertion every future full-suite run re-makes:
#      instance six of "unknown treated as benign" cannot merge quietly.
#   3. Assert the WIRING (round 2, codex-adv-1): the lint is registered as
#      a pre-commit gate whose files: scope matches every protected path.
#      Private Actions are OFF by design, so pre-commit is the only
#      private-path surface that runs this lint — a green private PR is
#      not evidence any suite ran unless this gate is wired into it.
#
# Suppression-path fixtures prove the `fail-open-ok:` marker silences a
# flagged shape in both languages. Exit-code contract checks close the loop.
#
# Exit: 0 all passed, 1 any failed. bash 3.2-safe; shellcheck-clean.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT="$SCRIPT_DIR/lint-fail-open.sh"
FIX="$SCRIPT_DIR/fixtures/fail-open"

[ -f "$LINT" ] || { printf 'FAIL: lint-fail-open.sh not found at %s\n' "$LINT" >&2; exit 1; }

PASS=0
FAIL=0
pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() {
    printf '  FAIL: %s\n' "$1"
    [ "$#" -ge 2 ] && printf '    %s\n' "$2"
    FAIL=$((FAIL + 1))
}

OUT="$(mktemp)" || exit 1
trap 'rm -f "$OUT"' EXIT

# run_lint <args...> — invoke the lint, capture combined output + rc.
run_lint() {
    bash "$LINT" "$@" > "$OUT" 2>&1
    LINT_RC=$?
}

# expect_fires <label> <fixture> <rule-tag> — the lint must exit 1 AND name
# the rule, on the PRE-FIX reconstruction.
expect_fires() {
    local label="$1" fixture="$2" tag="$3"
    run_lint "$FIX/$fixture"
    if [ "$LINT_RC" -ne 1 ]; then
        fail "$label (expected exit 1, got $LINT_RC)" "$(cat "$OUT")"
        return 0
    fi
    if ! grep -q "fail-open($tag)" "$OUT"; then
        fail "$label (output does not name fail-open($tag))" "$(cat "$OUT")"
        return 0
    fi
    pass "$label fires fail-open($tag) on the pre-fix reconstruction"
}

# expect_clean <label> <fixture> — the lint must exit 0 with zero findings.
expect_clean() {
    local label="$1" fixture="$2"
    run_lint "$FIX/$fixture"
    if [ "$LINT_RC" -ne 0 ]; then
        fail "$label (expected exit 0, got $LINT_RC)" "$(cat "$OUT")"
        return 0
    fi
    if ! grep -q '0 finding(s)' "$OUT"; then
        fail "$label (summary does not report zero findings)" "$(cat "$OUT")"
        return 0
    fi
    pass "$label"
}

printf 'lint-fail-open suite (HIMMEL-1776)\n\n'

printf 'Case 1: detectors proven red against pre-fix reconstructions\n'
expect_fires  'instance 1 (unreadable phi-roots denylist)' 'instance1-unreadable-denylist.sh.fxt' 'unreadable-config'
expect_fires  'instance 2 (provider fallback sentinel)'   'instance2-provider-fallback.sh.fxt'   'sentinel-not-denied'
expect_fires  'instance 2 (multiline fallback arm)'       'instance2-multiline-arm.sh.fxt'       'sentinel-not-denied'
expect_fires  'instance 2 (single-quoted sentinel)'       'instance2-single-quoted.sh.fxt'       'sentinel-not-denied'
expect_fires  'instance 3 (unguarded bank threshold)'     'instance3-preflight-unguarded.mjs.fxt' 'pct-unguarded'
expect_fires  'instance 4 (usage coalesced to zero)'      'quota-zero-coalesce.mjs.fxt'          'quota-zero'

printf '\nCase 2: the fixed twins and the prescribed shapes pass clean\n'
expect_clean  'instance-1 fixed twin (-f paired with -r + hard deny)' 'instance1-fixed.sh.fxt'
expect_clean  'instance-2 fixed twin (sentinel denied before matrix)' 'instance2-fixed.sh.fxt'
expect_clean  'instance-2 fixed twin (multiline arm, sentinel denied)' 'instance2-multiline-fixed.sh.fxt'
expect_clean  'instance-2 fixed twin (single-quoted sentinel denied)'  'instance2-single-quoted-fixed.sh.fxt'
expect_clean  'instance-3 fixed twin (explicit UNKNOWN branch)'       'instance3-fixed.mjs.fxt'
expect_clean  'prescribed shape (unknown preserved via ?? null)'      'quota-null-ok.mjs.fxt'

printf '\nCase 3: the inline suppression path silences a flagged shape\n'
expect_clean  'shell # fail-open-ok: marker' 'suppressed-shell.sh.fxt'
expect_clean  'js // fail-open-ok: marker'   'suppressed-js.mjs.fxt'

printf '\nCase 4: exit-code contract (fail-closed on misconfiguration)\n'
run_lint "$FIX/does-not-exist.sh.fxt"
if [ "$LINT_RC" -eq 2 ]; then pass "missing file exits 2"; else fail "missing file: expected exit 2, got $LINT_RC" "$(cat "$OUT")"; fi

run_lint "$OUT"
if [ "$LINT_RC" -eq 2 ]; then pass "extensionless file exits 2"; else fail "extensionless file: expected exit 2, got $LINT_RC" "$(cat "$OUT")"; fi

run_lint --no-such-flag
if [ "$LINT_RC" -eq 2 ]; then pass "unknown flag exits 2"; else fail "unknown flag: expected exit 2, got $LINT_RC" "$(cat "$OUT")"; fi

printf '\nCase 5: the real guard surfaces are clean (the standing assertion)\n'
run_lint
if [ "$LINT_RC" -eq 0 ]; then
    if grep -q '0 finding(s)' "$OUT"; then
        pass "lint-fail-open passes on the current tree ($(grep -o '[0-9]* file(s)' "$OUT"))"
    else
        fail "current-tree run exited 0 but the summary is not zero findings" "$(cat "$OUT")"
    fi
else
    fail "lint-fail-open must pass on the current tree (got exit $LINT_RC) — either a real instance six or a too-broad detector; triage honestly, do not tune until quiet" "$(cat "$OUT")"
fi

printf '\nCase 6: the pre-commit gate wiring — every protected path triggers it (codex-adv-1)\n'
# A lint no gate runs enforces nothing, and private Actions are OFF by
# design, so pre-commit is the only private-path surface that runs this
# lint at all. Prove the WIRING, not the intent: the hook must be
# registered, and the files: scope fed to pre-commit must match every
# scanned surface plus the lint, its fixtures, its test, the gate's own
# script and the yaml itself (an edit that unwires the gate must run the
# gate), while leaving unscanned surfaces alone.
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG="$ROOT/.pre-commit-config.yaml"
GATE_REL=scripts/hooks/check-fail-open-lint.sh
if [ ! -f "$CONFIG" ]; then
    fail ".pre-commit-config.yaml present" "missing: $CONFIG"
elif [ ! -f "$ROOT/$GATE_REL" ]; then
    fail "gate script present" "missing: $ROOT/$GATE_REL"
else
    hook_block="$(awk '/^      - id: fail-open-lint$/{f=1} f && /^      - id:/ && !/^      - id: fail-open-lint$/{f=0} f' "$CONFIG")"
    if [ -z "$hook_block" ]; then
        fail "fail-open-lint hook registered in .pre-commit-config.yaml" "the lint is wired to nothing on the private path. Apply the round-2 escalation block: id fail-open-lint · entry bash scripts/hooks/check-fail-open-lint.sh · pass_filenames false · stages [pre-commit] · files ^(scripts/(guardrails|hooks|lanes)/|scripts/graphify/refresh-graph-map\.sh$|scripts/claude-(codex|glm|routed)$|scripts/telegram/spawn-glm\.ts$|\.pre-commit-config\.yaml$)"
    else
        pass "fail-open-lint hook registered in .pre-commit-config.yaml"
        if printf '%s\n' "$hook_block" | grep -q "entry: bash $GATE_REL"; then
            pass "hook entry runs the gate script"
        else
            fail "hook entry runs the gate script" "expected: entry: bash $GATE_REL"
        fi
        if printf '%s\n' "$hook_block" | grep -q 'pass_filenames: false'; then
            pass "hook runs file-agnostic (pass_filenames false)"
        else
            fail "hook runs file-agnostic (pass_filenames false)" "the gate must scan the guard surfaces, not the staged subset"
        fi
        if printf '%s\n' "$hook_block" | grep -q 'stages: \[pre-commit\]'; then
            pass "hook fires at pre-commit (the private path)"
        else
            fail "hook fires at pre-commit (the private path)" "pre-push is too late for a surface Actions never runs"
        fi
        scope_re="$(printf '%s\n' "$hook_block" | sed -n 's/^        files: //p')"
        if [ -z "$scope_re" ]; then
            fail "hook has a files: scope" "no files: line found in the fail-open-lint block"
        else
            for p in \
                scripts/guardrails/lint-fail-open.sh \
                scripts/guardrails/test-lint-fail-open.sh \
                scripts/guardrails/fixtures/fail-open/instance2-fixed.sh.fxt \
                scripts/hooks/block-backend-tier.sh \
                scripts/hooks/check-fail-open-lint.sh \
                scripts/lanes/await-glm-worker.sh \
                scripts/lanes/bench/run-batch.sh \
                scripts/lanes/funded-max-pct.mjs \
                scripts/graphify/refresh-graph-map.sh \
                scripts/claude-glm \
                scripts/telegram/spawn-glm.ts \
                .pre-commit-config.yaml
            do
                if printf '%s' "$p" | grep -Eq "$scope_re"; then
                    pass "editing $p triggers the gate"
                else
                    fail "editing $p triggers the gate" "the files: scope does not match this protected path — a guard change here would merge without the lint running"
                fi
            done
            for p in README.md docs/internals/enforcement.md scripts/statusline/check-hud-drift.sh templates/luna-second-brain/x.md; do
                if printf '%s' "$p" | grep -Eq "$scope_re"; then
                    fail "editing $p stays untriggered" "unscanned surface matched the scope — over-broad trigger"
                else
                    pass "editing $p stays untriggered"
                fi
            done
        fi
    fi
fi

printf '\n== Summary ==\n'
printf ' PASS: %s\n FAIL: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
printf 'OK: lint-fail-open proven red on every pre-fix fixture and green on the tree\n'
exit 0
