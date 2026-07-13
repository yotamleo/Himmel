#!/usr/bin/env bash
# test-arm-resume-proxy.sh -- regression test for the HIMMEL-901
# HIMMEL_HEADROOM_PROXY arm-time flag added to
# scripts/handover/arm-resume.sh + scripts/lib/headroom-proxy.sh.
#
# Kept SEPARATE from the (already large) test-arm-resume.sh, same rationale
# as test-arm-resume-queue-lock.sh: this ticket's surface stays
# independently reviewable. Shares the same stubbing conventions (PATH-
# stubbed schtasks/atq/at so no real scheduler job is ever created; a
# throwaway WORKSPACE_TRUST_CONFIG/SKILL_TELEMETRY_DIR so no operator state
# is touched) and the same OSTYPE-override trick test-arm-resume.sh's
# mac_env() uses (S4/macOS block) to exercise the POSIX at/crontab code
# paths from a Windows/Git-Bash runner: a bash child process HONORS an
# inherited/exported OSTYPE even though it looks like a bash-internal
# variable (verified empirically before relying on it here).
#
# Everything below runs under --dry-run: touches no real scheduler, no real
# ~/.headroom-venv, no real network. bash-3.2-safe, ASCII-only.
#
# CR round additions: mode-marker lines (HIMMEL-897 trail), absolute-curl
# baking, metachar escaping proof, lib fail-open, cygpath-failure, and the
# curl-missing arm-time deactivation.
#
# Usage: bash scripts/handover/test-arm-resume-proxy.sh
# Exit:  0 = all pass, 1 = one or more failures.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARM="$SCRIPT_DIR/arm-resume.sh"
LIB="$SCRIPT_DIR/../lib/headroom-proxy.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Hermetic shields (same as test-arm-resume.sh / test-arm-resume-queue-lock.sh):
# no real telemetry/trust writes, no operator-shell env bleed.
export SKILL_TELEMETRY_DIR="$TMP/telemetry"
export WORKSPACE_TRUST_CONFIG="$TMP/claude-trust.json"
export HIMMEL_FLOW_RUNS_LEDGER="$TMP/flow-runs.jsonl"
unset HIMMEL_HEADROOM_PROXY HEADROOM_BIN 2>/dev/null || true

FAILED=0
assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label -- expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}
assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) echo "PASS $label" ;;
        *) echo "FAIL $label -- output missing: $needle"; FAILED=$((FAILED + 1)) ;;
    esac
}
assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) echo "FAIL $label -- output unexpectedly contains: $needle"; FAILED=$((FAILED + 1)) ;;
        *) echo "PASS $label" ;;
    esac
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
WORK_REPO="$TMP/work-repo"
mkdir -p "$WORK_REPO"
git init -q "$WORK_REPO"
HANDOVER_DIR="$TMP/statedocs/handovers"
mkdir -p "$HANDOVER_DIR"
git init -q "$TMP/statedocs"
FUTURE_TIME="23:59"

make_handover() {
    local path="$HANDOVER_DIR/handover-$RANDOM.md"
    {
        printf -- '---\n'
        printf 'session_kind: test\n'
        printf 'resume_cwd: %s\n' "$WORK_REPO"
        printf -- '---\n'
        printf '# Test handover\n'
    } > "$path"
    printf '%s' "$path"
}

# Empty-scheduler stub (same pattern as test-arm-resume.sh SCHED_STUB_T17):
# /query (and atq/at) return nothing, rc 0 -- reads as "no existing jobs" so
# dedup/collision never interferes with these HIMMEL-901-specific assertions.
SCHED_STUB="$TMP/sched-stub"
mkdir -p "$SCHED_STUB"
cat > "$SCHED_STUB/schtasks" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$SCHED_STUB/atq" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$SCHED_STUB/at" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$SCHED_STUB/schtasks" "$SCHED_STUB/atq" "$SCHED_STUB/at"

# ---------------------------------------------------------------------------
# T1: flag OFF (env unset, no repo-root .env signal) -- Windows dry-run .bat
#     content carries NO proxy lines. No-regression guard: this worktree's
#     root has no .env (verified before writing this test), and
#     HIMMEL_HEADROOM_PROXY/HEADROOM_BIN are explicitly unset above.
# ---------------------------------------------------------------------------
HO=$(make_handover)
out=$(PATH="$SCHED_STUB:$PATH" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T1 flag-off dry-run exits 0" 0 "$rc"
assert_not_contains "T1 no ANTHROPIC_BASE_URL" "ANTHROPIC_BASE_URL" "$out"
assert_not_contains "T1 no livez check" "livez" "$out"
assert_not_contains "T1 no HEADROOM_OFFLINE" "HEADROOM_OFFLINE" "$out"
assert_not_contains "T1 no mode marker" "mode=" "$out"
assert_not_contains "T1 no detached proxy start" 'cmd /c "' "$out"

# ---------------------------------------------------------------------------
# T2: HIMMEL_HEADROOM_PROXY=1 in the process env -- the dry-run launcher
#     carries the livez check (ABSOLUTE curl path -- CR round), the detached
#     start, the env injection, the fail-open branch structure, and one
#     mode-marker line per branch (proxied / bare-fallback, HIMMEL-897).
#     CMD-specific shapes are gated to Windows; the POSIX twin shapes are
#     pinned by T5/T6 via the OSTYPE override.
# ---------------------------------------------------------------------------
HO=$(make_handover)
out=$(HIMMEL_HEADROOM_PROXY=1 PATH="$SCHED_STUB:$PATH" bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T2 flag-on dry-run exits 0" 0 "$rc"
assert_contains "T2 livez check present" "-s -m 5 http://127.0.0.1:8787/livez" "$out"
assert_contains "T2 proxy --port 8787 invoked" "proxy --port 8787" "$out"
assert_contains "T2 log path present" '.headroom-proxy.log' "$out"
assert_contains "T2 mode=proxied marker baked in" "mode=proxied" "$out"
assert_contains "T2 mode=bare-fallback marker baked in" "mode=bare-fallback" "$out"
assert_contains "T2 marker carries the arm identity" "arm=HIMMEL-Resume-" "$out"
assert_contains "T2 default headroom bin path baked in" "headroom-venv" "$out"
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
    msys*|cygwin*|win32*|MINGW*)
        assert_contains "T2 detached start line present" 'start "" /b cmd /c "' "$out"
        assert_contains "T2 ANTHROPIC_BASE_URL set" 'set "ANTHROPIC_BASE_URL=http://127.0.0.1:8787"' "$out"
        assert_contains "T2 HEADROOM_OFFLINE set" 'set "HEADROOM_OFFLINE=1"' "$out"
        assert_contains "T2 errorlevel gate present" "if errorlevel 1 (" "$out"
        assert_contains "T2 fail-open else branch present" ") else (" "$out"
        EXPECTED_CURL_WIN=$(cygpath -w "$(command -v curl)")
        assert_contains "T2 absolute curl path baked in" "\"$EXPECTED_CURL_WIN\" -s -m 5" "$out"
        ;;
    *)
        assert_contains "T2 ANTHROPIC_BASE_URL exported inline" "ANTHROPIC_BASE_URL=http://127.0.0.1:8787" "$out"
        assert_contains "T2 HEADROOM_OFFLINE exported inline" "HEADROOM_OFFLINE=1" "$out"
        EXPECTED_CURL_POSIX=$(printf '%q' "$(command -v curl)")
        assert_contains "T2 absolute curl path baked in" "$EXPECTED_CURL_POSIX -s -m 5" "$out"
        ;;
esac

# ---------------------------------------------------------------------------
# T3a: direct unit tests of the sourceable .env parser
#      (_headroom_proxy_env_file_active in scripts/lib/headroom-proxy.sh).
#      arm-resume.sh itself is NOT safely sourceable (parses "$@", calls
#      exit unconditionally at the end), so the parser was split into this
#      small lib specifically so it -- and only it -- can be sourced
#      directly here without touching the real scheduler or exiting the
#      test runner.
# ---------------------------------------------------------------------------
(
    # shellcheck source=../lib/headroom-proxy.sh
    # shellcheck disable=SC1090,SC1091
    . "$LIB"
    ENVDIR="$TMP/envunit"
    mkdir -p "$ENVDIR"
    printf 'HIMMEL_HEADROOM_PROXY=1\n' > "$ENVDIR/.env"
    if _headroom_proxy_env_file_active "$ENVDIR"; then echo "PASS T3a plain =1 activates"; else echo "FAIL T3a plain =1"; fi
    printf 'export HIMMEL_HEADROOM_PROXY=1\n' > "$ENVDIR/.env"
    if _headroom_proxy_env_file_active "$ENVDIR"; then echo "PASS T3a export-prefixed =1 activates"; else echo "FAIL T3a export prefix"; fi
    printf 'HIMMEL_HEADROOM_PROXY=0\n' > "$ENVDIR/.env"
    if _headroom_proxy_env_file_active "$ENVDIR"; then echo "FAIL T3a =0 must NOT activate"; else echo "PASS T3a =0 stays inactive"; fi
    printf '# comment\n\nOTHER=1\nHIMMEL_HEADROOM_PROXY=1\n' > "$ENVDIR/.env"
    if _headroom_proxy_env_file_active "$ENVDIR"; then echo "PASS T3a comments/blank lines/other vars tolerated"; else echo "FAIL T3a mixed content"; fi
    printf 'HIMMEL_HEADROOM_PROXY=1\r\n' > "$ENVDIR/.env"
    if _headroom_proxy_env_file_active "$ENVDIR"; then echo "PASS T3a CRLF-terminated .env tolerated"; else echo "FAIL T3a CRLF .env"; fi
    rm -f "$ENVDIR/.env"
    if _headroom_proxy_env_file_active "$ENVDIR"; then echo "FAIL T3a missing .env must NOT activate"; else echo "PASS T3a missing .env stays inactive"; fi
) | while IFS= read -r line; do
    echo "$line"
    case "$line" in FAIL*) : > "$TMP/t3a-failed" ;; esac
done
[ -f "$TMP/t3a-failed" ] && FAILED=$((FAILED + 1))

# ---------------------------------------------------------------------------
# T3b/T3c: end-to-end .env fallback through the REAL arm-resume.sh, in an
#     ISOLATED copy of the repo layout (same technique test-arm-resume.sh's
#     T24 FAILOPEN block uses) so a controlled <root>/.env sits exactly
#     where SCRIPT_DIR/../.. resolves it, without touching this worktree's
#     real (absent) .env.
# ---------------------------------------------------------------------------
ENVROOT="$TMP/envfallback"
mkdir -p "$ENVROOT/scripts/handover" "$ENVROOT/scripts/lib"
cp "$ARM" "$ENVROOT/scripts/handover/arm-resume.sh"
cp "$SCRIPT_DIR/../lib/py-armor.sh" "$ENVROOT/scripts/lib/py-armor.sh"
cp "$LIB" "$ENVROOT/scripts/lib/headroom-proxy.sh"

# T3b: process env UNSET, repo-root .env carries HIMMEL_HEADROOM_PROXY=1 ->
#      falls back to the file -> proxy lines present.
printf 'HIMMEL_HEADROOM_PROXY=1\n' > "$ENVROOT/.env"
HO=$(make_handover)
out=$(env -u HIMMEL_HEADROOM_PROXY PATH="$SCHED_STUB:$PATH" \
    bash "$ENVROOT/scripts/handover/arm-resume.sh" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T3b .env fallback dry-run exits 0" 0 "$rc"
assert_contains "T3b .env fallback activates the proxy lines" "-s -m 5 http://127.0.0.1:8787/livez" "$out"

# T3c: process env EXPLICITLY set to a non-"1" value wins over a .env that
#      says "1" -- proves (a) process env always wins over the file, and
#      (b) only the exact value "1" activates (a set-but-wrong value is
#      NOT the same as unset -- it does not fall through to the file).
HO=$(make_handover)
out=$(HIMMEL_HEADROOM_PROXY=0 PATH="$SCHED_STUB:$PATH" \
    bash "$ENVROOT/scripts/handover/arm-resume.sh" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T3c process-env=0 dry-run exits 0" 0 "$rc"
assert_not_contains "T3c process-env=0 overrides a truthy .env (stays inactive)" "livez" "$out"

# T3d (CR round): set-but-EMPTY process env counts as set-and-inactive and
#     does NOT fall through to the truthy .env -- pins the ${VAR+x} set-test
#     against a regression to [ -n "$VAR" ] (which would treat empty as
#     unset and wrongly consult the file).
HO=$(make_handover)
out=$(HIMMEL_HEADROOM_PROXY='' PATH="$SCHED_STUB:$PATH" \
    bash "$ENVROOT/scripts/handover/arm-resume.sh" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T3d set-but-empty process env dry-run exits 0" 0 "$rc"
assert_not_contains "T3d set-but-empty env does NOT fall through to .env" "livez" "$out"

# ---------------------------------------------------------------------------
# T4: HEADROOM_BIN override lands in the generated launcher (cygpath-
#     converted + CMD-escaped on Windows; %q-quoted on POSIX). Uses a path
#     WITH a space to prove the quoting survives it. The file deliberately
#     does NOT exist -> also pins the arm-time existence WARN (CR round,
#     non-blocking: rc stays 0).
# ---------------------------------------------------------------------------
CUSTOM_HB="$TMP/custom bin/headroom.exe"
mkdir -p "$TMP/custom bin"
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
    msys*|cygwin*|win32*|MINGW*) EXPECTED_HB=$(cygpath -w "$CUSTOM_HB") ;;
    *)                           EXPECTED_HB=$(printf '%q' "$CUSTOM_HB") ;;
esac
HO=$(make_handover)
out=$(HIMMEL_HEADROOM_PROXY=1 HEADROOM_BIN="$CUSTOM_HB" PATH="$SCHED_STUB:$PATH" \
    bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T4 HEADROOM_BIN override dry-run exits 0" 0 "$rc"
assert_contains "T4 custom headroom bin path baked into launcher" "$EXPECTED_HB" "$out"
assert_not_contains "T4 default headroom-venv path NOT used" "headroom-venv" "$out"
assert_contains "T4 arm-time WARN for a missing/non-exec HEADROOM_BIN" "not found/executable" "$out"

# ---------------------------------------------------------------------------
# T4b (CR round): CMD-metachar escaping on the HEADROOM_BIN path actually
#     bites -- a dir name carrying % and & must land in the .bat with % as
#     %% and & as ^& (the _cmd_metachar_escape treatment; T4's space never
#     exercised the substitutions). POSIX: the same path must land %q-quoted.
# ---------------------------------------------------------------------------
MBIN_DIR="$TMP/hea%dr&om"
mkdir -p "$MBIN_DIR"
MBIN="$MBIN_DIR/headroom.exe"
HO=$(make_handover)
out=$(HIMMEL_HEADROOM_PROXY=1 HEADROOM_BIN="$MBIN" PATH="$SCHED_STUB:$PATH" \
    bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T4b metachar HEADROOM_BIN dry-run exits 0" 0 "$rc"
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
    msys*|cygwin*|win32*|MINGW*)
        assert_contains "T4b percent doubled for CMD" 'hea%%dr' "$out"
        assert_contains "T4b ampersand caret-escaped for CMD" '^&om' "$out"
        ;;
    *)
        EXPECTED_MBIN=$(printf '%q' "$MBIN")
        assert_contains "T4b metachar path %q-quoted for sh" "$EXPECTED_MBIN" "$out"
        ;;
esac

# ---------------------------------------------------------------------------
# T5: macOS backend (crontab) -- OSTYPE override, same technique as
#     test-arm-resume.sh's mac_env(). Verified empirically that a bash
#     child process honors an inherited/exported OSTYPE.
# ---------------------------------------------------------------------------
MACBIN="$TMP/macbin"; mkdir -p "$MACBIN"
printf '#!/bin/sh\necho "at MUST NOT be called on macOS" >&2; exit 1\n' > "$MACBIN/at"; chmod +x "$MACBIN/at"
printf '#!/bin/sh\nexit 0\n' > "$MACBIN/atq"; chmod +x "$MACBIN/atq"
cat > "$MACBIN/crontab" <<'EOF'
#!/bin/sh
case "$1" in
  -l) exit 0 ;;
  -)  cat > /dev/null ;;
  *)  exit 0 ;;
esac
EOF
chmod +x "$MACBIN/crontab"
mac_env() { env PATH="$MACBIN:$PATH" OSTYPE="darwin23" "$@"; }

# Expected POSIX curl reference for T5/T6 (CR round): the launchers bake the
# %q-quoted absolute path resolved at arm time.
EXPECTED_CURL_Q=$(printf '%q' "$(command -v curl)")

# T5a: flag ON -- the one-line compound tail carries the proxy markers.
HO=$(make_handover)
out=$(mac_env env HIMMEL_HEADROOM_PROXY=1 bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T5a macOS/crontab flag-on dry-run exits 0" 0 "$rc"
assert_contains "T5a crontab entry" "crontab entry" "$out"
assert_contains "T5a absolute curl path in livez check" "$EXPECTED_CURL_Q -s -m 5 http://127.0.0.1:8787/livez" "$out"
assert_contains "T5a ANTHROPIC_BASE_URL inline-exported" "ANTHROPIC_BASE_URL=http://127.0.0.1:8787" "$out"
assert_contains "T5a HEADROOM_OFFLINE inline-exported" "HEADROOM_OFFLINE=1" "$out"
assert_contains "T5a proxy started detached in background" "proxy --port 8787" "$out"
assert_contains "T5a mode=proxied marker baked in" "mode=proxied" "$out"
assert_contains "T5a mode=bare-fallback marker baked in" "mode=bare-fallback" "$out"
assert_contains "T5a marker timestamp is fire-time (literal date sub)" 'arm=HIMMEL-Resume-' "$out"

# T5b: flag OFF -- no-regression guard on the crontab path (negative-marker
# set aligned with T1/T6b, CR round).
HO=$(make_handover)
out=$(mac_env bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T5b macOS/crontab flag-off dry-run exits 0" 0 "$rc"
assert_not_contains "T5b no ANTHROPIC_BASE_URL" "ANTHROPIC_BASE_URL" "$out"
assert_not_contains "T5b no livez check" "livez" "$out"
assert_not_contains "T5b no HEADROOM_OFFLINE" "HEADROOM_OFFLINE" "$out"
assert_not_contains "T5b no mode marker" "mode=" "$out"

# ---------------------------------------------------------------------------
# T6: linux backend (at) -- OSTYPE override with `at`/`atq` present so
#     schedule_arm takes the `at` heredoc branch, not the crontab fallback.
# ---------------------------------------------------------------------------
LINBIN="$TMP/linbin"; mkdir -p "$LINBIN"
printf '#!/bin/sh\nexit 0\n' > "$LINBIN/atq"; chmod +x "$LINBIN/atq"
printf '#!/bin/sh\ncat >/dev/null\nexit 0\n' > "$LINBIN/at"; chmod +x "$LINBIN/at"
lin_env() { env PATH="$LINBIN:$PATH" OSTYPE="linux-gnu" "$@"; }

# T6a: flag ON -- the heredoc body carries the proxy markers.
HO=$(make_handover)
out=$(lin_env env HIMMEL_HEADROOM_PROXY=1 bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T6a linux/at flag-on dry-run exits 0" 0 "$rc"
assert_contains "T6a at -t heredoc" "would at -t" "$out"
assert_contains "T6a absolute curl path in livez check" "$EXPECTED_CURL_Q -s -m 5 http://127.0.0.1:8787/livez" "$out"
assert_contains "T6a if-curl gate present" "if $EXPECTED_CURL_Q -s -m 5" "$out"
assert_contains "T6a ANTHROPIC_BASE_URL inline-exported" "ANTHROPIC_BASE_URL=http://127.0.0.1:8787" "$out"
assert_contains "T6a HEADROOM_OFFLINE inline-exported" "HEADROOM_OFFLINE=1" "$out"
assert_contains "T6a proxy started detached in background" "proxy --port 8787" "$out"
assert_contains "T6a mode=proxied marker baked in" "mode=proxied" "$out"
assert_contains "T6a mode=bare-fallback marker baked in" "mode=bare-fallback" "$out"

# T6b: flag OFF -- no-regression guard on the at path (negative-marker set
# aligned with T1/T5b, CR round).
HO=$(make_handover)
out=$(lin_env bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T6b linux/at flag-off dry-run exits 0" 0 "$rc"
assert_not_contains "T6b no ANTHROPIC_BASE_URL" "ANTHROPIC_BASE_URL" "$out"
assert_not_contains "T6b no livez check" "livez" "$out"
assert_not_contains "T6b no HEADROOM_OFFLINE" "HEADROOM_OFFLINE" "$out"
assert_not_contains "T6b no mode marker" "mode=" "$out"

# T6c (CR round): POSIX HEADROOM_BIN override with a metachar + space path
# proves the %q quoting end-to-end on BOTH sh-variant launchers (at heredoc
# via lin_env, crontab one-liner via mac_env).
POSIX_HB="$TMP/head room/hea&droom"
mkdir -p "$TMP/head room"
EXPECTED_POSIX_HB=$(printf '%q' "$POSIX_HB")
HO=$(make_handover)
out=$(lin_env env HIMMEL_HEADROOM_PROXY=1 HEADROOM_BIN="$POSIX_HB" \
    bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T6c linux/at metachar HEADROOM_BIN dry-run exits 0" 0 "$rc"
assert_contains "T6c at heredoc bakes the %q-quoted bin" "$EXPECTED_POSIX_HB proxy --port 8787" "$out"
HO=$(make_handover)
out=$(mac_env env HIMMEL_HEADROOM_PROXY=1 HEADROOM_BIN="$POSIX_HB" \
    bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T6c macOS/crontab metachar HEADROOM_BIN dry-run exits 0" 0 "$rc"
assert_contains "T6c crontab entry bakes the %q-quoted bin" "$EXPECTED_POSIX_HB proxy --port 8787" "$out"

# ---------------------------------------------------------------------------
# T7 (CR round): lib fail-open -- arm-resume must behave identically when
#     scripts/lib/headroom-proxy.sh is ABSENT or syntactically BROKEN
#     (mirrors test-arm-resume.sh T24's telemetry-lib pattern). The source
#     failure now WARNs (Suggestion A) -- assert the WARN is present AND
#     that the process-env flag still works without the lib.
# ---------------------------------------------------------------------------
LIBFAIL="$TMP/libfail"
mkdir -p "$LIBFAIL/scripts/handover" "$LIBFAIL/scripts/lib"
cp "$ARM" "$LIBFAIL/scripts/handover/arm-resume.sh"
cp "$SCRIPT_DIR/../lib/py-armor.sh" "$LIBFAIL/scripts/lib/py-armor.sh"
printf 'HIMMEL_HEADROOM_PROXY=1\n' > "$LIBFAIL/.env"
# (a) lib ABSENT: arm works (rc 0), WARNs, and the truthy .env is IGNORED
#     (fallback disabled without the parser).
HO=$(make_handover)
out=$(env -u HIMMEL_HEADROOM_PROXY PATH="$SCHED_STUB:$PATH" \
    bash "$LIBFAIL/scripts/handover/arm-resume.sh" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T7a absent lib: arm still works (rc 0)" 0 "$rc"
assert_contains "T7a absent lib: source-failure WARN emitted" "headroom-proxy lib failed to load" "$out"
assert_not_contains "T7a absent lib: truthy .env fallback disabled" "livez" "$out"
# (b) lib ABSENT but process env =1: the flag still activates (env check
#     does not depend on the lib).
HO=$(make_handover)
out=$(HIMMEL_HEADROOM_PROXY=1 PATH="$SCHED_STUB:$PATH" \
    bash "$LIBFAIL/scripts/handover/arm-resume.sh" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T7b absent lib + process env: arm exits 0" 0 "$rc"
assert_contains "T7b absent lib + process env: proxy lines present" "livez" "$out"
# (c) lib BROKEN (bash syntax error): same invariants as (a).
printf 'if [ broken\nthen (\n' > "$LIBFAIL/scripts/lib/headroom-proxy.sh"
HO=$(make_handover)
out=$(env -u HIMMEL_HEADROOM_PROXY PATH="$SCHED_STUB:$PATH" \
    bash "$LIBFAIL/scripts/handover/arm-resume.sh" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "T7c broken lib: arm still works (rc 0)" 0 "$rc"
assert_contains "T7c broken lib: source-failure WARN emitted" "headroom-proxy lib failed to load" "$out"
assert_not_contains "T7c broken lib: truthy .env fallback disabled" "livez" "$out"

# ---------------------------------------------------------------------------
# T8 (CR round): cygpath failure on the headroom+curl conversion -> rc 4,
#     ERR text, and no leftover temp .bat. The stub delegates the batched
#     3-path call (-w + 3 args = $# 4) AND the single-path calls ($# 2:
#     bash.exe -w, flow-run-ledger.sh -m — HIMMEL-921) to the REAL cygpath
#     and refuses the 2-path headroom+curl call ($# 3), so the failure lands
#     exactly on the headroom conversion. Windows-only: the .bat branch is
#     the only cygpath consumer (POSIX launchers never call it).
# ---------------------------------------------------------------------------
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
    msys*|cygwin*|win32*|MINGW*)
        REAL_CYGPATH=$(command -v cygpath)
        CYGFAIL_STUB="$TMP/cygfail-stub"
        mkdir -p "$CYGFAIL_STUB"
        {
            printf '#!/usr/bin/env bash\n'
            printf 'if [ "$#" -eq 4 ] || [ "$#" -eq 2 ]; then exec "%s" "$@"; fi\n' "$REAL_CYGPATH"
            printf 'echo "stub cygpath: refused" >&2\n'
            printf 'exit 1\n'
        } > "$CYGFAIL_STUB/cygpath"
        chmod +x "$CYGFAIL_STUB/cygpath"
        T8_TMPDIR="$TMP/t8-tmp"
        mkdir -p "$T8_TMPDIR"
        HO=$(make_handover)
        out=$(TMPDIR="$T8_TMPDIR" HIMMEL_HEADROOM_PROXY=1 PATH="$CYGFAIL_STUB:$SCHED_STUB:$PATH" \
            bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
        rc=$?
        assert_rc "T8 cygpath failure on headroom conversion exits 4" 4 "$rc"
        assert_contains "T8 ERR names the failed conversion" "cygpath -w failed converting" "$out"
        if find "$T8_TMPDIR" -name 'himmel-resume.*.bat' 2>/dev/null | grep -q .; then
            echo "FAIL T8 leftover temp .bat not cleaned up"
            FAILED=$((FAILED + 1))
        else
            echo "PASS T8 no leftover temp .bat"
        fi
        ;;
    *)
        echo "SKIP T8 (cygpath failure path is Windows-only)"
        ;;
esac

# ---------------------------------------------------------------------------
# T9 (CR round): curl missing at arm time -> one honest WARN, launcher
#     emitted WITHOUT the proxy block (plain pre-901 launch), rc 0. curl is
#     hidden by rebuilding PATH from /usr/bin (Git Bash and most Linux
#     distros keep curl elsewhere) + the scheduler stub + python3's own dir
#     (py-armor needs it for the time fields). Skip-guarded: if curl is
#     still resolvable on the restricted PATH (e.g. a distro with
#     /usr/bin/curl), the hermetic premise fails, so document and skip
#     rather than assert on a broken fixture.
# ---------------------------------------------------------------------------
PY3BIN=$(command -v python3 2>/dev/null || true)
RESTRICTED_PATH="$SCHED_STUB:/usr/bin"
[ -n "$PY3BIN" ] && RESTRICTED_PATH="$RESTRICTED_PATH:$(dirname "$PY3BIN")"
if env PATH="$RESTRICTED_PATH" bash -c 'command -v curl' >/dev/null 2>&1; then
    echo "SKIP T9 (curl still resolvable on the restricted PATH; cannot fake a curl-less arm here)"
else
    HO=$(make_handover)
    out=$(env PATH="$RESTRICTED_PATH" HIMMEL_HEADROOM_PROXY=1 \
        bash "$ARM" --time "$FUTURE_TIME" --handover "$HO" --dry-run 2>&1)
    rc=$?
    assert_rc "T9 curl-missing arm still exits 0" 0 "$rc"
    assert_contains "T9 arm-time WARN about missing curl" "curl not on PATH" "$out"
    # Needle is the URL path "/livez" (with slash): the WARN itself says
    # "proxy livez unverifiable", so a bare "livez" would false-positive
    # on the very WARN this test requires.
    assert_not_contains "T9 launcher emitted WITHOUT the proxy block" "/livez" "$out"
    assert_not_contains "T9 no mode marker without the proxy block" "mode=" "$out"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [ "$FAILED" -gt 0 ]; then
    echo "---"
    echo "FAIL $FAILED case(s)"
    exit 1
fi
echo "---"
echo "PASS all cases"
exit 0
