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

# HIMMEL-3599: the HIMMEL_CONSOLE_DOC fast path is now gated on the
# session's OWN -n name matching the doc's basename, never honored on its
# own -- every fast-path case below runs as this fixed console identity.
CMDLINE_SC="$TMP/cmdline-some-console"
printf 'claude\0-n\0some-console\0' > "$CMDLINE_SC"
sc_env() { env CLAUDE_PID=1 SESSION_NAME_CMDLINE_FILE="$CMDLINE_SC" "$@"; }

echo "== console doc via HIMMEL_CONSOLE_DOC (own name matches) -> emits Live state + Compact instructions + COMPACTED line =="
DOC1="$TMP/some-console.md"
mk_console_doc "$DOC1"
out="$(sc_env env HIMMEL_CONSOLE_DOC="$DOC1" bash "$HOOK")"; rc=$?
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
DOC1B="$TMP/some-console.md"
# shellcheck disable=SC2016  # backtick leg span, literal fixture text
printf '%s\n' "# Some Console" "" "## Live state" "" \
    'legs: `N1:nonce-abc:lock-tok-1:1234`' "" \
    "### MILESTONE 1 -- appended after Live state, must not leak" "" \
    "## Results" "" "- LIVE 09:00" > "$DOC1B"
out="$(sc_env env HIMMEL_CONSOLE_DOC="$DOC1B" bash "$HOOK")"; rc=$?
if [ "$rc" -eq 0 ]; then ok "milestone-after-Live-state doc still exits 0"; else bad "expected rc 0, got $rc"; fi
case "$out" in
    *'MILESTONE 1'*) bad "output leaked a ### subheading appended after ## Live state - got: $out" ;;
    *) ok "output does not leak a ### subheading appended after ## Live state" ;;
esac

echo "== a fenced code block inside ## Live state containing its own ## line does not truncate the section (fence-aware terminator) =="
DOC1C="$TMP/some-console.md"
printf '%s\n' "# Some Console" "" "## Live state" "" \
    "legs: N1 token-abc" "" \
    '```markdown' "## Something else entirely" "example body" '```' "" \
    "CRITICAL: lock token lock-tok-XYZ" "" \
    "## Results" "" "- LIVE 09:00" > "$DOC1C"
out="$(sc_env env HIMMEL_CONSOLE_DOC="$DOC1C" bash "$HOOK")"; rc=$?
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
DOC1D="$TMP/some-console.md"
printf '%s\n' "# Some Console" "" "## Live state" "" \
    "legs: N1 token-abc" "" \
    '```unterminated' "fence never closes" "" \
    "## Results" "" "- LIVE 09:00" "" \
    "SECRET-TAIL-SHOULD-NOT-APPEAR" > "$DOC1D"
out="$(sc_env env HIMMEL_CONSOLE_DOC="$DOC1D" bash "$HOOK" 2>"$TMP/stderr1d")"; rc=$?
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
DOC1E="$TMP/some-console.md"
printf '%s\n' "# Some Console" "" "## Live state" "" \
    "legs: N1 token-abc" "" \
    '  ```markdown' "## Something else entirely" "example body" '  ```' "" \
    "CRITICAL: lock token lock-tok-ABC" "" \
    "## Results" "" "- LIVE 09:00" > "$DOC1E"
out="$(sc_env env HIMMEL_CONSOLE_DOC="$DOC1E" bash "$HOOK")"; rc=$?
if [ "$rc" -eq 0 ]; then ok "indented-fence doc still exits 0"; else bad "expected rc 0, got $rc"; fi
case "$out" in
    *'lock-tok-ABC'*) ok "output preserves content after an indented fence's ## line" ;;
    *) bad "output silently dropped content past an indented fence - got: $out" ;;
esac
case "$out" in
    *'## Results'*) bad "output leaked past Live state's own section boundary into ## Results" ;;
    *) ok "output still stops at the real ## Results boundary" ;;
esac

echo "== a 4-backtick fence containing a nested 3-backtick line is NOT closed by the shorter marker (HIMMEL-3137) =="
DOC1F="$TMP/some-console.md"
printf '%s\n' "# Some Console" "" "## Live state" "" \
    "legs: N1 token-abc" "" \
    '````markdown' '```' "## Nested example heading, inside the 3-backtick inner fence" '```' '````' "" \
    "CRITICAL: lock token lock-tok-NESTED" "" \
    "## Results" "" "- LIVE 09:00" > "$DOC1F"
out="$(sc_env env HIMMEL_CONSOLE_DOC="$DOC1F" bash "$HOOK")"; rc=$?
if [ "$rc" -eq 0 ]; then ok "longer-fence doc still exits 0"; else bad "expected rc 0, got $rc"; fi
case "$out" in
    *'lock-tok-NESTED'*) ok "output preserves content after a 4-backtick fence with a nested 3-backtick line" ;;
    *) bad "output was truncated by the nested shorter fence marker - got: $out" ;;
esac
case "$out" in
    *'## Results'*) bad "output leaked past Live state's own section boundary into ## Results" ;;
    *) ok "output still stops at the real ## Results boundary" ;;
esac

echo "== doc has no ## Live state section -> one-line warning, still rc 0, no COMPACTED promise =="
DOC2="$TMP/bare-console.md"
printf '# Bare Console\n\n## Results\n\n- LIVE 09:00\n' > "$DOC2"
CMDLINE_BC="$TMP/cmdline-bare-console"
printf 'claude\0-n\0bare-console\0' > "$CMDLINE_BC"
out="$(env CLAUDE_PID=1 SESSION_NAME_CMDLINE_FILE="$CMDLINE_BC" HIMMEL_CONSOLE_DOC="$DOC2" bash "$HOOK")"; rc=$?
if [ "$rc" -eq 0 ]; then ok "no-Live-state doc still exits 0"; else bad "expected rc 0, got $rc"; fi
case "$out" in
    *'no "## Live state" section'*) ok "warns about the missing section" ;;
    *) bad "expected a missing-section warning - got: $out" ;;
esac
case "$out" in
    *COMPACTED*) bad "should not promise a COMPACTED bullet when there is nothing to re-inject" ;;
    *) ok "does not print the COMPACTED line when Live state is absent" ;;
esac

echo "== HIMMEL_CONSOLE_DOC points at a nonexistent file (own name IS a console) -> fails safe, falls through to the (also empty) name search, one-line warning =="
EMPTY_ROOT="$TMP/empty-handover-root"
mkdir -p "$EMPTY_ROOT"
out="$(sc_env env HANDOVER_DIR="$EMPTY_ROOT" HIMMEL_CONSOLE_DOC="$TMP/does-not-exist.md" bash "$HOOK")"; rc=$?
if [ "$rc" -eq 0 ]; then ok "missing doc path exits 0"; else bad "expected rc 0, got $rc"; fi
case "$out" in
    *'NOT re-injected'*) ok "missing doc path falls through to the name search and warns, never trusting the stale path" ;;
    *) bad "expected the not-re-injected warning (stale doc must not print Live state) - got: $out" ;;
esac
case "$out" in
    *'## Live state'*) bad "a stale/missing HIMMEL_CONSOLE_DOC must never emit Live state - got: $out" ;;
    *) ok "no Live state leaks from a stale HIMMEL_CONSOLE_DOC path" ;;
esac

echo "== HIMMEL-3599: a LEG/JUDGE session (own name NOT *-console) inherits a console's ambient HIMMEL_CONSOLE_DOC/WORKDIR -- must stay SILENT, never trust it =="
# Reproduces the leak: headed-arm-leg.sh launches a leg/judge from a Bash
# subprocess of the console's own claude process, which had HIMMEL_CONSOLE_DOC
# set on ITS OWN env (HIMMEL-2973 S3, headed-arm.sh CONSOLE_ENV). Nothing
# strips that var for a non-console role, so it rides along as ordinary
# ambient env into the leg/judge's process -- exactly the shape this hook
# must refuse. At base (pre-fix) the hook honored HIMMEL_CONSOLE_DOC BEFORE
# ever checking the session's own name, so this printed the console's real
# Live state (the HIMMEL-3599 judge-session leak). Fixed: it must print
# nothing.
CMDLINE_LEG_LEAK="$TMP/cmdline-leg-leak"
printf 'claude\0-n\0himmel-3599-legN1\0' > "$CMDLINE_LEG_LEAK"
LEAK_DOC="$TMP/some-console.md"
mk_console_doc "$LEAK_DOC"
out="$(env CLAUDE_PID=1 SESSION_NAME_CMDLINE_FILE="$CMDLINE_LEG_LEAK" HIMMEL_CONSOLE_DOC="$LEAK_DOC" bash "$HOOK")"; rc=$?
if [ "$rc" -eq 0 ]; then ok "leg with inherited HIMMEL_CONSOLE_DOC still exits 0"; else bad "expected rc 0, got $rc"; fi
if [ -z "$out" ]; then ok "leg/judge with a leaked HIMMEL_CONSOLE_DOC prints NOTHING (no Live state, no token)"; else bad "SECURITY: leg/judge leaked the console's Live state via ambient HIMMEL_CONSOLE_DOC - got: $out"; fi

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

echo "== HIMMEL-3160: HANDOVER_DIR unset, handover_root resolves to a bare inline stub, a sandboxed registry root holds the doc -> Live state is re-injected via the registry fallback =="
# Hermeticity (HARD rule): a throwaway HOME/CLAUDE_CONFIG_DIR + a sandboxed
# registry.json at the real default path, so a bug that ever falls through
# to the unqualified default can't reach the operator's actual registry.
N3160_HOME="$TMP/3160-home"
mkdir -p "$N3160_HOME/.claude/handover"
printf '{"repos":{}}\n' > "$N3160_HOME/.claude/handover/registry.json"

N3160_WT="$TMP/3160-worktree"
mkdir -p "$N3160_WT/handovers"
git -C "$N3160_WT" init -q >/dev/null 2>&1

N3160_STATE="$TMP/3160-state"
mkdir -p "$N3160_STATE/handovers/yotamleo/himmel"
mk_console_doc "$N3160_STATE/handovers/yotamleo/himmel/fixture-3160-console.md"

N3160_REG="$TMP/3160-registry.json"
printf '{"repos":{"state":{"path":"%s","user":"yotamleo","branch_prefix":"handover/"}}}\n' \
    "$N3160_STATE" > "$N3160_REG"

CMDLINE_3160="$TMP/cmdline-3160-console"
printf 'claude\0-n\0fixture-3160-console\0' > "$CMDLINE_3160"

reg_before="$(sha256sum "$N3160_HOME/.claude/handover/registry.json" | awk '{print $1}')"
out="$(cd "$N3160_WT" && env -u HANDOVER_DIR -u HIMMEL_CONSOLE_DOC \
    HOME="$N3160_HOME" CLAUDE_CONFIG_DIR="$N3160_HOME/.claude" \
    CLAUDE_PID=1 SESSION_NAME_CMDLINE_FILE="$CMDLINE_3160" \
    HANDOVER_REGISTRY="$N3160_REG" bash "$HOOK")"; rc=$?
reg_after="$(sha256sum "$N3160_HOME/.claude/handover/registry.json" | awk '{print $1}')"
if [ "$rc" -eq 0 ]; then ok "registry-root fallback exits 0"; else bad "expected rc 0, got $rc"; fi
# shellcheck disable=SC2016  # backtick leg span, literal fixture text
case "$out" in
    *'legs: `N1:nonce-abc:lock-tok-1:1234`'*) ok "registry-root fallback finds the doc under the sandboxed state repo and emits Live state" ;;
    *) bad "registry-root fallback did not emit the fixture doc's Live state (HIMMEL-3160) - got: $out" ;;
esac
if [ "$reg_before" = "$reg_after" ]; then ok "the sandboxed default-path registry was untouched by the run"; else bad "the sandboxed default-path registry CHANGED during the run"; fi

echo "== HIMMEL-3160: HANDOVER_DIR unset, handover_root's stub misses AND the registry names nobody -> one-line warning naming the searched roots =="
N3160B_WT="$TMP/3160b-worktree"
mkdir -p "$N3160B_WT/handovers"
git -C "$N3160B_WT" init -q >/dev/null 2>&1

N3160B_REG="$TMP/3160b-registry.json"
printf '{"repos":{}}\n' > "$N3160B_REG"

CMDLINE_3160B="$TMP/cmdline-3160b-console"
printf 'claude\0-n\0fixture-3160b-console\0' > "$CMDLINE_3160B"

out="$(cd "$N3160B_WT" && env -u HANDOVER_DIR -u HIMMEL_CONSOLE_DOC \
    HOME="$N3160_HOME" CLAUDE_CONFIG_DIR="$N3160_HOME/.claude" \
    CLAUDE_PID=1 SESSION_NAME_CMDLINE_FILE="$CMDLINE_3160B" \
    HANDOVER_REGISTRY="$N3160B_REG" bash "$HOOK")"; rc=$?
if [ "$rc" -eq 0 ]; then ok "no-doc-anywhere fallback exits 0"; else bad "expected rc 0, got $rc"; fi
case "$out" in
    *'NOT re-injected'*) ok "no-doc-anywhere fallback warns Live state was NOT re-injected" ;;
    *) bad "expected a not-re-injected warning - got: $out" ;;
esac
case "$out" in
    *"$N3160B_WT/handovers"*) ok "warning names the searched handover_root stub" ;;
    *) bad "warning did not name the searched handover_root stub - got: $out" ;;
esac

echo "== HIMMEL-3160: the registry fallback never fires for a non-console session name, even with a matching registry root =="
CMDLINE_3160C="$TMP/cmdline-3160c-nonconsole"
printf 'claude\0-n\0fixture-3160-notconsole\0' > "$CMDLINE_3160C"
out="$(cd "$N3160_WT" && env -u HANDOVER_DIR -u HIMMEL_CONSOLE_DOC \
    HOME="$N3160_HOME" CLAUDE_CONFIG_DIR="$N3160_HOME/.claude" \
    CLAUDE_PID=1 SESSION_NAME_CMDLINE_FILE="$CMDLINE_3160C" \
    HANDOVER_REGISTRY="$N3160_REG" bash "$HOOK")"; rc=$?
if [ "$rc" -eq 0 ]; then ok "non-console name with a populated registry still exits 0"; else bad "expected rc 0, got $rc"; fi
if [ -z "$out" ]; then ok "non-console session stays silent even when the registry holds a matching doc"; else bad "expected total silence - got: $out"; fi

echo
printf '%d ok, %d FAILED\n' "$pass" "$fail"
