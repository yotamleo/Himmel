#!/usr/bin/env bash
# Smoke suite for scripts/hooks/console-compact-reinject.sh (HIMMEL-2973 S1):
# a console session gets its `## Live state` + `## Compact instructions`
# re-injected verbatim on SessionStart:compact; every other session gets
# NOTHING — that negative case is the one that matters most, since this hook
# fires on every compaction fleet-wide.
#
# PLATFORM GUARD: no .ps1 twin — bash 3.2-safe, and Linux-only for the
# session-resolution cases (session-name.sh has no /proc on other
# platforms; the HIMMEL_CONSOLE_DOC path it exercises is platform-neutral).
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HOOKS/console-compact-reinject.sh"
[ -f "$HOOK" ] || { echo "hook not found: $HOOK" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/console-compact-reinject-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

mk_console_doc() {
    # $1 = path
    cat > "$1" <<'DOC'
# Some Console

## Live state

legs: `N1:nonce-abc:lock-tok-1:1234`, `N2:nonce-def:lock-tok-2:5678`
queue: N1
last GO: `#780:21b77d1`
acked: none

## Compact instructions

Carry the queue and last GO forward verbatim.

## Results

- LIVE 09:00
DOC
}

echo "== console doc via HIMMEL_CONSOLE_DOC -> emits Live state + Compact instructions + COMPACTED line =="
DOC1="$TMP/some-console.md"
mk_console_doc "$DOC1"
out="$(env HIMMEL_CONSOLE_DOC="$DOC1" bash "$HOOK")"; rc=$?
if [ "$rc" -eq 0 ]; then ok "exits 0"; else bad "expected rc 0, got $rc"; fi
case "$out" in
    *'## Live state'*) ok "output contains Live state heading" ;;
    *) bad "output missing '## Live state' - got: $out" ;;
esac
# shellcheck disable=SC2016  # backtick leg span, literal fixture text
case "$out" in
    *'legs: `N1:nonce-abc:lock-tok-1:1234`'*) ok "output contains the legs: line verbatim" ;;
    *) bad "output missing verbatim legs: line - got: $out" ;;
esac
case "$out" in
    *'## Compact instructions'*'Carry the queue and last GO forward verbatim.'*) ok "output contains Compact instructions verbatim" ;;
    *) bad "output missing Compact instructions body - got: $out" ;;
esac
case "$out" in
    *'COMPACTED'*'Live state above'*) ok "output names the COMPACTED bullet" ;;
    *) bad "output missing the COMPACTED instruction line - got: $out" ;;
esac
case "$out" in
    *'## Results'*) bad "output leaked past Live state's own section boundary into ## Results" ;;
    *) ok "output does not leak the doc's ## Results section" ;;
esac

echo "== a ### subheading appended after ## Live state is NOT re-injected (only ## boundaries end a section) =="
DOC1B="$TMP/some-console-with-milestone.md"
# shellcheck disable=SC2016  # backtick leg span, literal fixture text
printf '%s\n' "# Some Console" "" "## Live state" "" \
    'legs: `N1:nonce-abc:lock-tok-1:1234`' "" \
    "### MILESTONE 1 -- appended after Live state, must not leak" "" \
    "## Results" "" "- LIVE 09:00" > "$DOC1B"
out="$(env HIMMEL_CONSOLE_DOC="$DOC1B" bash "$HOOK")"; rc=$?
if [ "$rc" -eq 0 ]; then ok "milestone-after-Live-state doc still exits 0"; else bad "expected rc 0, got $rc"; fi
case "$out" in
    *'MILESTONE 1'*) bad "output leaked a ### subheading appended after ## Live state - got: $out" ;;
    *) ok "output does not leak a ### subheading appended after ## Live state" ;;
esac

echo "== a fenced code block inside ## Live state containing its own ## line does not truncate the section (fence-aware terminator) =="
DOC1C="$TMP/some-console-with-fenced-heading.md"
printf '%s\n' "# Some Console" "" "## Live state" "" \
    "legs: N1 token-abc" "" \
    '```markdown' "## Something else entirely" "example body" '```' "" \
    "CRITICAL: lock token lock-tok-XYZ" "" \
    "## Results" "" "- LIVE 09:00" > "$DOC1C"
out="$(env HIMMEL_CONSOLE_DOC="$DOC1C" bash "$HOOK")"; rc=$?
if [ "$rc" -eq 0 ]; then ok "fenced-heading doc still exits 0"; else bad "expected rc 0, got $rc"; fi
case "$out" in
    *'lock-tok-XYZ'*) ok "output preserves content after a fenced ## line inside Live state" ;;
    *) bad "output silently dropped content past a fenced ## line - got: $out" ;;
esac
case "$out" in
    *'## Results'*) bad "output leaked past Live state's own section boundary into ## Results" ;;
    *) ok "output still stops at the real ## Results boundary" ;;
esac

echo "== an UNTERMINATED fence inside ## Live state does not leak the doc tail to EOF (HIMMEL-3137) =="
DOC1D="$TMP/some-console-with-unterminated-fence.md"
printf '%s\n' "# Some Console" "" "## Live state" "" \
    "legs: N1 token-abc" "" \
    '```unterminated' "fence never closes" "" \
    "## Results" "" "- LIVE 09:00" "" \
    "SECRET-TAIL-SHOULD-NOT-APPEAR" > "$DOC1D"
out="$(env HIMMEL_CONSOLE_DOC="$DOC1D" bash "$HOOK" 2>"$TMP/stderr1d")"; rc=$?
if [ "$rc" -eq 0 ]; then ok "unterminated-fence doc still exits 0"; else bad "expected rc 0, got $rc"; fi
case "$out" in
    *'SECRET-TAIL-SHOULD-NOT-APPEAR'*) bad "output leaked the doc tail past an unterminated fence - got: $out" ;;
    *) ok "output does not leak the doc tail past an unterminated fence" ;;
esac
case "$out" in
    *'## Results'*) bad "output leaked into ## Results after an unterminated fence" ;;
    *) ok "output stops at the plain ## Results boundary when the fence is unterminated" ;;
esac
case "$(cat "$TMP/stderr1d")" in
    *"$DOC1D"*'Live state'*) ok "warns on stderr naming the doc and the section" ;;
    *) bad "expected a stderr warning naming the doc - got: $(cat "$TMP/stderr1d")" ;;
esac
case "$out" in
    *'falling back'*) bad "the stderr warning leaked onto stdout - got: $out" ;;
    *) ok "the warning does not leak onto stdout" ;;
esac

echo "== an INDENTED fence inside ## Live state containing a ## line still toggles (HIMMEL-3137) =="
DOC1E="$TMP/some-console-with-indented-fence.md"
printf '%s\n' "# Some Console" "" "## Live state" "" \
    "legs: N1 token-abc" "" \
    '  ```markdown' "## Something else entirely" "example body" '  ```' "" \
    "CRITICAL: lock token lock-tok-ABC" "" \
    "## Results" "" "- LIVE 09:00" > "$DOC1E"
out="$(env HIMMEL_CONSOLE_DOC="$DOC1E" bash "$HOOK")"; rc=$?
if [ "$rc" -eq 0 ]; then ok "indented-fence doc still exits 0"; else bad "expected rc 0, got $rc"; fi
case "$out" in
    *'lock-tok-ABC'*) ok "output preserves content after an indented fence's ## line" ;;
    *) bad "output silently dropped content past an indented fence - got: $out" ;;
esac
case "$out" in
    *'## Results'*) bad "output leaked past Live state's own section boundary into ## Results" ;;
    *) ok "output still stops at the real ## Results boundary" ;;
esac

echo "== doc has no ## Live state section -> one-line warning, still rc 0, no COMPACTED promise =="
DOC2="$TMP/bare-console.md"
printf '# Bare Console\n\n## Results\n\n- LIVE 09:00\n' > "$DOC2"
out="$(env HIMMEL_CONSOLE_DOC="$DOC2" bash "$HOOK")"; rc=$?
if [ "$rc" -eq 0 ]; then ok "no-Live-state doc still exits 0"; else bad "expected rc 0, got $rc"; fi
case "$out" in
    *'no "## Live state" section'*) ok "warns about the missing section" ;;
    *) bad "expected a missing-section warning - got: $out" ;;
esac
case "$out" in
    *COMPACTED*) bad "should not promise a COMPACTED bullet when there is nothing to re-inject" ;;
    *) ok "does not print the COMPACTED line when Live state is absent" ;;
esac

echo "== HIMMEL_CONSOLE_DOC points at a nonexistent file -> SILENT no-op (fail safe) =="
out="$(env HIMMEL_CONSOLE_DOC="$TMP/does-not-exist.md" bash "$HOOK")"; rc=$?
if [ "$rc" -eq 0 ]; then ok "missing doc path exits 0"; else bad "expected rc 0, got $rc"; fi
if [ -z "$out" ]; then ok "missing doc path prints nothing"; else bad "expected silence - got: $out"; fi

echo "== non-console session (no HIMMEL_CONSOLE_DOC, session name has no -console suffix) -> SILENT no-op =="
# Adversarial, not just absent: a doc named EXACTLY after this leg's session
# name sits right there under HANDOVER_DIR, with a real ## Live state
# section. If the -console suffix gate were ever dropped, the find-by-name
# fallback would happily pick this fixture up and this assertion would catch
# it -- a fixture that merely doesn't exist would pass either way and prove
# nothing about the gate.
CMDLINE_LEG="$TMP/cmdline-leg"
printf 'claude\0-n\0himmel-2973-legN5\0' > "$CMDLINE_LEG"
mk_console_doc "$TMP/himmel-2973-legN5.md"
out="$(env -u HIMMEL_CONSOLE_DOC CLAUDE_PID=1 SESSION_NAME_CMDLINE_FILE="$CMDLINE_LEG" HANDOVER_DIR="$TMP" bash "$HOOK")"; rc=$?
if [ "$rc" -eq 0 ]; then ok "non-console session exits 0"; else bad "expected rc 0, got $rc"; fi
if [ -z "$out" ]; then ok "non-console session prints NOTHING"; else bad "expected total silence for a non-console session - got: $out"; fi

echo "== no CLAUDE_PID at all (unresolvable session name) -> SILENT no-op =="
out="$(env -u HIMMEL_CONSOLE_DOC -u CLAUDE_PID bash "$HOOK")"; rc=$?
if [ "$rc" -eq 0 ]; then ok "unresolvable session exits 0"; else bad "expected rc 0, got $rc"; fi
if [ -z "$out" ]; then ok "unresolvable session prints nothing"; else bad "expected silence - got: $out"; fi

echo "== console session resolved via the -n/HANDOVER_DIR fallback (no HIMMEL_CONSOLE_DOC) -> emits Live state =="
CMDLINE_CONSOLE="$TMP/cmdline-console"
printf 'claude\0-n\0fixture-2026-09-17-console\0' > "$CMDLINE_CONSOLE"
ROOT="$TMP/handover-root"
mkdir -p "$ROOT/yotamleo/himmel"
DOC3="$ROOT/yotamleo/himmel/fixture-2026-09-17-console.md"
mk_console_doc "$DOC3"
out="$(env -u HIMMEL_CONSOLE_DOC CLAUDE_PID=1 SESSION_NAME_CMDLINE_FILE="$CMDLINE_CONSOLE" HANDOVER_DIR="$ROOT" bash "$HOOK")"; rc=$?
if [ "$rc" -eq 0 ]; then ok "fallback-resolved console exits 0"; else bad "expected rc 0, got $rc"; fi
# shellcheck disable=SC2016  # backtick leg span, literal fixture text
case "$out" in
    *'legs: `N1:nonce-abc:lock-tok-1:1234`'*) ok "fallback path finds the doc under HANDOVER_DIR and emits it" ;;
    *) bad "fallback path did not emit the fixture doc's Live state - got: $out" ;;
esac

echo
printf '%d ok, %d FAILED\n' "$pass" "$fail"
