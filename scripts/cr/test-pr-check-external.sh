#!/usr/bin/env bash
# Smoke test for scripts/cr/pr-check-external.sh (HIMMEL-750). Bash 3.2 safe.
# Hermetic: builds a throwaway git repo + bare origin under mktemp, and stubs
# the critic panel via CRITIC_PANEL_CMD (FAKE_OUT/FAKE_ERR/FAKE_RC env). Never
# touches the real $HOME, the real origin, or the real critic panel.
set -uo pipefail
unset CR_PROFILE CRITIC_PANEL_TIERS 2>/dev/null || true

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/pr-check-external.sh"
# shellcheck source=scripts/lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$HERE/../lib/fixture-tempdir.sh"
tmp="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0

ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1"; fail=1; }

# --- A generic fake panel driven by FAKE_OUT / FAKE_ERR / FAKE_RC ------------
PANEL="$tmp/fake-panel.sh"
cat > "$PANEL" <<'PANELEOF'
#!/usr/bin/env bash
cat >/dev/null
[ -n "${FAKE_OUT:-}" ] && printf '%s\n' "$FAKE_OUT"
[ -n "${FAKE_ERR:-}" ] && printf '%s\n' "$FAKE_ERR" >&2
exit ${FAKE_RC:-0}
PANELEOF
chmod +x "$PANEL"
export CRITIC_PANEL_CMD="$PANEL"

# HIMMEL-2704: there is NO CodeRabbit CLI seat any more — the App reviews the
# PR after it exists, so pr-check-external.sh never shells out to a coderabbit
# binary. Nothing below stubs one, and no case here passes merely BECAUSE a
# binary is absent: the gate-infra cases assert the refusal on its own terms.

# Panel stdout for a given (critical,important) pair.
panel_stdout() {
    printf '# Critic Panel Review (2/2 critics responded)\n\n## Critical Issues (%s found)\n\n## Important Issues (%s found)\n\n## Suggestions (0 found)\n' "$1" "$2"
}
CODEX_OK_ERR="$(printf 'panel-availability: qwen3coder ok\npanel-availability: codex ok')"
CODEX_ABSENT_ERR="$(printf 'panel-availability: qwen3coder ok')"

# --- Build a fake repo with a bare origin + a glm branch with a real diff ----
make_repo() {
    # $1 = repo dir; creates origin.git sibling, main + glm/x (non-empty diff) + glm/empty (no diff)
    local d="$1"
    [ -n "$d" ] || { echo "FAIL: empty fixture repo path" >&2; return 1; }
    mkdir -p "$d" || return 1
    (
        fixture_enter_git_init_dir "$d" || exit 1
        git -c init.defaultBranch=main init -q
        git config user.email t@t.test
        git config user.name tester
        echo base > f.txt
        git add f.txt
        git commit -q -m init
        git init -q --bare "$d.origin.git"
        git remote add origin "$d.origin.git"
        git push -q -u origin main
        git checkout -q -b glm/x
        echo change >> f.txt
        git commit -q -am change
        git checkout -q -b glm/empty main
        # glm/gate: a diff that TOUCHES the gate infrastructure (scripts/cr/**),
        # used by the HIMMEL-1224 gate-infra quorum tests (T12-T14).
        git checkout -q -b glm/gate main
        mkdir -p scripts/cr
        printf 'x\n' > scripts/cr/dummy-gate.sh
        git add scripts/cr/dummy-gate.sh
        git commit -q -m "gate-infra change (scripts/cr/)"
    )
}

new_session() {
    # $1 = dir; writes a spawn-glm-shaped meta.json
    mkdir -p "$1"
    printf '%s\n' '{"status":"done","lane":"glm","task_name":"x"}' > "$1/meta.json"
}

meta_verdict() {
    node -e 'const m=JSON.parse(require("fs").readFileSync(process.argv[1]));process.stdout.write(String(m.external_cr_verdict||""))' "$1"
}

# ============================================================================
repo="$tmp/repo"
make_repo "$repo" || exit 1

# --- T1: clean path writes external_cr_verdict + prints snippet --------------
sd="$tmp/s1"; new_session "$sd"
out="$(cd "$repo" && FAKE_OUT="$(panel_stdout 0 0)" FAKE_ERR="$CODEX_OK_ERR" FAKE_RC=0 \
    bash "$SCRIPT" --branch glm/x --session-dir "$sd" --base main 2>/dev/null)"
rc=$?
if [ "$rc" -ne 0 ]; then bad "T1: clean path exit $rc (want 0)"; fi
case "$out" in
    "external_cr_verdict: pass ("*) ok "T1 snippet printed" ;;
    *) bad "T1: snippet not printed (got: $out)" ;;
esac
v="$(meta_verdict "$sd/meta.json")"
case "$v" in
    "pass (sha="*) ok "T1 meta external_cr_verdict written ($v)" ;;
    *) bad "T1: meta external_cr_verdict wrong (got: $v)" ;;
esac

# --- T2: unparseable count -> FAIL, no verdict written -----------------------
sd="$tmp/s2"; new_session "$sd"
if (cd "$repo" && FAKE_OUT="garbage with no headings" FAKE_ERR="$CODEX_OK_ERR" FAKE_RC=0 \
    bash "$SCRIPT" --branch glm/x --session-dir "$sd" --base main >/dev/null 2>&1); then
    bad "T2: unparseable count should FAIL"
else
    ok "T2 unparseable count fails closed"
fi
if [ -z "$(meta_verdict "$sd/meta.json")" ]; then ok "T2 no verdict written"; else bad "T2: verdict should not be written"; fi

# --- T3: codex absent -> FAIL ------------------------------------------------
sd="$tmp/s3"; new_session "$sd"
if (cd "$repo" && FAKE_OUT="$(panel_stdout 0 0)" FAKE_ERR="$CODEX_ABSENT_ERR" FAKE_RC=0 \
    bash "$SCRIPT" --branch glm/x --session-dir "$sd" --base main >/dev/null 2>&1); then
    bad "T3: codex-absent should FAIL"
else
    ok "T3 codex-absent fails closed"
fi

# --- T4: empty diff -> skip (exit 0, no verdict) -----------------------------
sd="$tmp/s4"; new_session "$sd"
if (cd "$repo" && FAKE_OUT="$(panel_stdout 0 0)" FAKE_ERR="$CODEX_OK_ERR" FAKE_RC=0 \
    bash "$SCRIPT" --branch glm/empty --session-dir "$sd" --base main >/dev/null 2>&1); then
    ok "T4 empty diff skips (exit 0)"
else
    bad "T4: empty diff should exit 0"
fi
if [ -z "$(meta_verdict "$sd/meta.json")" ]; then ok "T4 no verdict on empty diff"; else bad "T4: verdict should not be written on empty diff"; fi

# --- T5: CR_PROFILE=none -> refuse (exit 2) ----------------------------------
sd="$tmp/s5"; new_session "$sd"
rc=0
(cd "$repo" && CR_PROFILE=none FAKE_OUT="$(panel_stdout 0 0)" FAKE_ERR="$CODEX_OK_ERR" \
    bash "$SCRIPT" --branch glm/x --session-dir "$sd" --base main >/dev/null 2>&1) || rc=$?
if [ "$rc" -eq 2 ]; then ok "T5 CR_PROFILE=none refused (exit 2)"; else bad "T5: CR_PROFILE=none should exit 2 (got $rc)"; fi

# --- T6: dirty panel (Critical>0) -> NOT CLEAN (exit 1), no verdict ----------
sd="$tmp/s6"; new_session "$sd"
if (cd "$repo" && FAKE_OUT="$(panel_stdout 1 0)" FAKE_ERR="$CODEX_OK_ERR" FAKE_RC=0 \
    bash "$SCRIPT" --branch glm/x --session-dir "$sd" --base main >/dev/null 2>&1); then
    bad "T6: Critical>0 should be NOT CLEAN"
else
    ok "T6 Critical>0 not clean"
fi
if [ -z "$(meta_verdict "$sd/meta.json")" ]; then ok "T6 no verdict when not clean"; else bad "T6: verdict should not be written when not clean"; fi

# --- T10: a failed rerun REVOKES a pre-existing same-SHA pass (no stale auth) --
# codex-adv (PR #1330): exit-1 alone left a prior `external_cr_verdict: pass`
# usable by ship-branch.sh at an unchanged SHA. Seed a same-SHA pass, force a
# failing review (a Critical>0 panel -> rc=1; the CodeRabbit CLI that used to
# force it here is gone, HIMMEL-2704), and assert the verdict is revoked.
sd="$tmp/s10"; new_session "$sd"
seed_sha="$(git -C "$repo" rev-parse glm/x)"
node -e 'const fs=require("fs");const m=JSON.parse(fs.readFileSync(process.argv[1]));m.external_cr_verdict="pass (sha="+process.argv[2]+"; critics=2)";fs.writeFileSync(process.argv[1],JSON.stringify(m,null,2)+"\n")' "$sd/meta.json" "$seed_sha"
[ -n "$(meta_verdict "$sd/meta.json")" ] || bad "T10 setup: seed verdict not written"
if (cd "$repo" || exit 99; FAKE_OUT="$(panel_stdout 1 0)" FAKE_ERR="$CODEX_OK_ERR" FAKE_RC=0 \
    bash "$SCRIPT" --branch glm/x --session-dir "$sd" --base main >/dev/null 2>&1); then
    bad "T10: failed rerun should exit non-zero"
else
    rc=$?
    if [ "$rc" -eq 99 ]; then
        bad "T10: cd to repo failed (test setup) — fail-closed path not exercised"
    elif [ "$rc" -eq 1 ]; then
        ok "T10 failed rerun fails closed (exit 1)"
    else
        bad "T10: failed rerun should exit 1 (got $rc)"
    fi
fi
if [ -z "$(meta_verdict "$sd/meta.json")" ]; then ok "T10 stale verdict revoked on failed rerun"; else bad "T10: stale external_cr_verdict survived a failed rerun"; fi

# --- T11: a revocation FAILURE fails closed (never warn-and-continue) --------
# codex-1 + CodeRabbit (PR #1330): a failed revoke must not let the review
# proceed and re-authorize. A corrupt meta makes the revoke node throw; the lane
# must exit non-zero and leave no readable 'pass'. A CLEAN panel (0/0) proves the
# non-zero exit is the revoke-failure path, not a review finding.
sd="$tmp/s11"; new_session "$sd"
printf '%s' 'not valid json {' > "$sd/meta.json"
if (cd "$repo" || exit 99; FAKE_OUT="$(panel_stdout 0 0)" FAKE_ERR="$CODEX_OK_ERR" FAKE_RC=0 \
    bash "$SCRIPT" --branch glm/x --session-dir "$sd" --base main >/dev/null 2>&1); then
    bad "T11: revocation failure (corrupt meta) should FAIL closed"
else
    rc=$?
    if [ "$rc" -eq 99 ]; then
        bad "T11: cd to repo failed (test setup) — revocation path not exercised"
    elif [ "$rc" -eq 1 ]; then
        ok "T11 revocation failure fails closed (exit 1)"
    else
        bad "T11: revocation failure should exit 1 (got $rc)"
    fi
fi
v="$(meta_verdict "$sd/meta.json" 2>/dev/null || true)"
case "$v" in
    "pass "*|"pass") bad "T11: a trusted pass resulted from a revocation failure (got: $v)" ;;
    *) ok "T11 no trusted pass after revocation failure" ;;
esac

# --- T12: gate-infra diff -> REFUSED outright (exit 1). HIMMEL-1224 raised the
# floor for gate-infra diffs to a quorum of two responding cross-model
# reviewers; the CodeRabbit CLI was the second seat and HIMMEL-2704 retired it,
# while critics.json's panel is codex-only — so the quorum has no second seat
# left and this path refuses gate-infra diffs unconditionally. RED CONTROL: the
# panel is CLEAN and codex RESPONDED here, so the ONLY thing producing exit 1 is
# the gate-infra file list; a regression that dropped the refusal flips this to
# 0. T14 is the paired control (same inputs, non-gate branch -> exit 0). No
# coderabbit binary exists on PATH in either case. ---
sd="$tmp/s12"; new_session "$sd"
rc=0
err12="$tmp/t12.err"
(cd "$repo" || exit 99; FAKE_OUT="$(panel_stdout 0 0)" FAKE_ERR="$CODEX_OK_ERR" FAKE_RC=0 \
    bash "$SCRIPT" --branch glm/gate --session-dir "$sd" --base main >/dev/null 2>"$err12") || rc=$?
if [ "$rc" -eq 99 ]; then
    bad "T12: cd to repo failed (test setup) - gate-infra path not exercised"
elif [ "$rc" -eq 1 ]; then
    ok "T12 gate-infra diff refused on the Claude-free path (exit 1)"
else
    bad "T12: expected exit 1 (gate-infra refused), got $rc"
fi
if grep -q 'gate-infrastructure diff requires a quorum' "$err12"; then
    ok "T12 refusal names the quorum it cannot reach"
else
    bad "T12: refusal message missing the quorum explanation"
fi
if [ -z "$(meta_verdict "$sd/meta.json")" ]; then ok "T12 no verdict written on a refused gate-infra diff"; else bad "T12: verdict written despite the refusal"; fi

# --- T13: the SAME refusal REVOKES a pre-existing same-SHA pass, so
# ship-branch.sh cannot ship on stale authorization. Require EXACTLY 1 so a
# failure for any other reason is caught rather than mistaken for the gate-infra
# outcome (HIMMEL-1224 rc-capture pattern, kept through HIMMEL-2704). ---
sd="$tmp/s13"; new_session "$sd"
seed_sha13="$(git -C "$repo" rev-parse glm/gate)"
node -e 'const fs=require("fs");const m=JSON.parse(fs.readFileSync(process.argv[1]));m.external_cr_verdict="pass (sha="+process.argv[2]+"; critics=2)";fs.writeFileSync(process.argv[1],JSON.stringify(m,null,2)+"\n")' "$sd/meta.json" "$seed_sha13"
[ -n "$(meta_verdict "$sd/meta.json")" ] || bad "T13 setup: seed verdict not written"
rc=0
(cd "$repo" || exit 99; FAKE_OUT="$(panel_stdout 0 0)" FAKE_ERR="$CODEX_OK_ERR" FAKE_RC=0 \
    bash "$SCRIPT" --branch glm/gate --session-dir "$sd" --base main >/dev/null 2>&1) || rc=$?
if [ "$rc" -eq 99 ]; then
    bad "T13: cd to repo failed (test setup) - revocation path not exercised"
elif [ "$rc" -eq 1 ]; then
    ok "T13 gate-infra refusal fails closed (exit 1)"
else
    bad "T13: expected exit 1 (gate-infra refused), got $rc"
fi
if [ -z "$(meta_verdict "$sd/meta.json")" ]; then ok "T13 stale verdict revoked on a refused gate-infra diff"; else bad "T13: stale external_cr_verdict survived the refusal"; fi

# --- T14: NON-gate diff -> the single-codex floor is UNCHANGED (CLEAN, exit 0)
# and the verdict carries NO coderabbit field (HIMMEL-2704). The paired half of
# T12's RED control: identical panel inputs, only the branch differs, so T12's
# exit 1 is attributable to the gate-infra file list and nothing else. ---
sd="$tmp/s14"; new_session "$sd"
out="$(cd "$repo" || exit 99; FAKE_OUT="$(panel_stdout 0 0)" FAKE_ERR="$CODEX_OK_ERR" FAKE_RC=0 \
    bash "$SCRIPT" --branch glm/x --session-dir "$sd" --base main 2>/dev/null)"
rc=$?
if [ "$rc" -eq 0 ]; then ok "T14 non-gate diff stays CLEAN (single-codex floor unchanged)"; else bad "T14: non-gate diff should exit 0 (got $rc)"; fi
v="$(meta_verdict "$sd/meta.json")"
case "$v" in
    *coderabbit*) bad "T14: verdict still carries a coderabbit field (got: $v)" ;;
    "pass (sha="*) ok "T14 verdict written with no coderabbit field ($v)" ;;
    *) bad "T14: verdict wrong (got: $v)" ;;
esac


if [ "$fail" -eq 0 ]; then echo "PASS test-pr-check-external"; else echo "FAILURES in test-pr-check-external"; exit 1; fi
