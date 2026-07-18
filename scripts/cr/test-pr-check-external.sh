#!/usr/bin/env bash
# Smoke test for scripts/cr/pr-check-external.sh (HIMMEL-750). Bash 3.2 safe.
# Hermetic: builds a throwaway git repo + bare origin under mktemp, and stubs
# the critic panel via CRITIC_PANEL_CMD (FAKE_OUT/FAKE_ERR/FAKE_RC env). Never
# touches the real $HOME, the real origin, or the real critic panel.
set -uo pipefail
unset CR_PROFILE CRITIC_PANEL_TIERS 2>/dev/null || true

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/pr-check-external.sh"
tmp="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf $tmp" EXIT
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

# Default the CodeRabbit seat to ABSENT so T1-T6 stay hermetic and fast (no real
# CodeRabbit review on the GLM branch). T7-T9 override CODERABBIT_BIN per-case.
# CODERABBIT_WSL is overridden too so a host with real WSL does not resolve it.
export CODERABBIT_BIN="$tmp/no-coderabbit-bin"
export CODERABBIT_WSL="$tmp/no-coderabbit-wsl"

# --- A coderabbit stub driven by STUB_FINDINGS / STUB_RC ----------------------
# Mirrors test-coderabbit-review.sh: coderabbit-review.sh runs it inside the
# review clone, so STUB_FINDINGS/STUB_RC must reach it via the environment.
CRSTUBS="$tmp/crstubs"
mkdir -p "$CRSTUBS"
cat > "$CRSTUBS/coderabbit" <<'CRSTUBEOF'
#!/usr/bin/env bash
[ -n "${STUB_FINDINGS:-}" ] && printf '%s\n' "$STUB_FINDINGS"
exit "${STUB_RC:-0}"
CRSTUBEOF
chmod +x "$CRSTUBS/coderabbit"

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
    git -c init.defaultBranch=main init -q "$d"
    (
        cd "$d" || exit 1
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
make_repo "$repo"

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

# --- T7: coderabbit major finding BLOCKS (exit 1, no verdict) -----------------
# Clean panel + codex ok, but the coderabbit stub emits a critical/major
# finding (realistic --agent JSONL: status lines + a finding line) -> the gate
# fails closed on it ([coderabbit-N] blocking candidates).
sd="$tmp/s7"; new_session "$sd"
if (cd "$repo" && FAKE_OUT="$(panel_stdout 0 0)" FAKE_ERR="$CODEX_OK_ERR" FAKE_RC=0 \
    CODERABBIT_BIN="$CRSTUBS/coderabbit" STUB_RC=0 \
    STUB_FINDINGS='{"type":"status","phase":"analyzing","status":"reviewing"}
{"type":"finding","severity":"major","fileName":"f.txt","codegenInstructions":"bug here"}
{"type":"complete","status":"review_completed","findings":1}' \
    bash "$SCRIPT" --branch glm/x --session-dir "$sd" --base main >/dev/null 2>&1); then
    bad "T7: coderabbit major finding should BLOCK"
else
    ok "T7 coderabbit major finding blocks"
fi
if [ -z "$(meta_verdict "$sd/meta.json")" ]; then ok "T7 no verdict when coderabbit blocks"; else bad "T7: verdict should not be written when coderabbit blocks"; fi

# --- T7b: coderabbit minor-only findings do NOT block (Suggestion tier) -------
# Severity map parity with interactive /pr-check step 3.2: minor -> Suggestion,
# surfaced but non-blocking (PR #1139 CodeRabbit app finding, adjudicated).
sd="$tmp/s7b"; new_session "$sd"
out="$(cd "$repo" && FAKE_OUT="$(panel_stdout 0 0)" FAKE_ERR="$CODEX_OK_ERR" FAKE_RC=0 \
    CODERABBIT_BIN="$CRSTUBS/coderabbit" STUB_RC=0 \
    STUB_FINDINGS='{"type":"finding","severity":"minor","fileName":"f.txt","codegenInstructions":"nit"}
{"type":"complete","status":"review_completed","findings":1}' \
    bash "$SCRIPT" --branch glm/x --session-dir "$sd" --base main 2>/dev/null)"
rc=$?
if [ "$rc" -eq 0 ]; then ok "T7b minor-only does not block (exit 0)"; else bad "T7b: minor-only should not block (got $rc)"; fi
v="$(meta_verdict "$sd/meta.json")"
case "$v" in
    "pass (sha="*) ok "T7b verdict written on minor-only ($v)" ;;
    *) bad "T7b: verdict wrong (got: $v)" ;;
esac

# --- T7c: clean review with status-lines-only stdout does NOT block -----------
# The --agent stream always carries status/complete JSONL even with zero
# findings; a non-empty-stdout gate would false-block every clean review.
sd="$tmp/s7c"; new_session "$sd"
if (cd "$repo" && FAKE_OUT="$(panel_stdout 0 0)" FAKE_ERR="$CODEX_OK_ERR" FAKE_RC=0 \
    CODERABBIT_BIN="$CRSTUBS/coderabbit" STUB_RC=0 \
    STUB_FINDINGS='{"type":"status","phase":"analyzing","status":"reviewing"}
{"type":"complete","status":"review_completed","findings":0}' \
    bash "$SCRIPT" --branch glm/x --session-dir "$sd" --base main >/dev/null 2>&1); then
    ok "T7c status-only stdout stays clean"
else
    bad "T7c: clean review with status lines must not block"
fi

# --- T7d: unrecognized (non-JSONL) output BLOCKS (format drift, fail-closed) --
sd="$tmp/s7d"; new_session "$sd"
if (cd "$repo" && FAKE_OUT="$(panel_stdout 0 0)" FAKE_ERR="$CODEX_OK_ERR" FAKE_RC=0 \
    CODERABBIT_BIN="$CRSTUBS/coderabbit" STUB_RC=0 \
    STUB_FINDINGS="[coderabbit-1] f.txt:1 critical bug here" \
    bash "$SCRIPT" --branch glm/x --session-dir "$sd" --base main >/dev/null 2>&1); then
    bad "T7d: unrecognized output format should BLOCK (fail-closed)"
else
    ok "T7d format drift fails closed"
fi

# --- T8: coderabbit absent (rc=3) skips cleanly (exit 0, verdict pass) --------
# A machine without the CLI is not a critic drop-out: skip note + fail-open.
sd="$tmp/s8"; new_session "$sd"
out="$(cd "$repo" && FAKE_OUT="$(panel_stdout 0 0)" FAKE_ERR="$CODEX_OK_ERR" FAKE_RC=0 \
    CODERABBIT_BIN="$tmp/no-coderabbit-bin" CODERABBIT_WSL="$tmp/no-coderabbit-wsl" \
    bash "$SCRIPT" --branch glm/x --session-dir "$sd" --base main 2>/dev/null)"
rc=$?
if [ "$rc" -eq 0 ]; then ok "T8 coderabbit-absent skips (exit 0)"; else bad "T8: coderabbit-absent should exit 0 (got $rc)"; fi
case "$out" in
    "external_cr_verdict: pass ("*) ok "T8 snippet printed (fail-open to verdict)" ;;
    *) bad "T8: verdict snippet missing (got: $out)" ;;
esac
v="$(meta_verdict "$sd/meta.json")"
case "$v" in
    "pass (sha="*) ok "T8 verdict written ($v)" ;;
    *) bad "T8: verdict wrong (got: $v)" ;;
esac

# --- T9: coderabbit review failed (rc=1) degrades open (exit 0, verdict) ------
# Stub exits 7 -> coderabbit-review.sh maps it to rc=1 + an unavailable line ->
# the external lane fails open and still records the pass verdict.
sd="$tmp/s9"; new_session "$sd"
out="$(cd "$repo" && FAKE_OUT="$(panel_stdout 0 0)" FAKE_ERR="$CODEX_OK_ERR" FAKE_RC=0 \
    CODERABBIT_BIN="$CRSTUBS/coderabbit" STUB_RC=7 \
    bash "$SCRIPT" --branch glm/x --session-dir "$sd" --base main 2>/dev/null)"
rc=$?
if [ "$rc" -eq 0 ]; then ok "T9 coderabbit-failed degrades open (exit 0)"; else bad "T9: coderabbit-failed should exit 0 (got $rc)"; fi
v="$(meta_verdict "$sd/meta.json")"
case "$v" in
    "pass (sha="*) ok "T9 verdict written despite coderabbit failure ($v)" ;;
    *) bad "T9: verdict should be written fail-open (got: $v)" ;;
esac

if [ "$fail" -eq 0 ]; then echo "PASS test-pr-check-external"; else echo "FAILURES in test-pr-check-external"; exit 1; fi
