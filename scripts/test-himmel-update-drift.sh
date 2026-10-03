#!/usr/bin/env bash
# test-himmel-update-drift.sh — himmel-update's installer-drift pass (HIMMEL-4246).
# `himmel-update.sh --only drift` runs `himmelctl status --json`, converges the
# allow-listed items (pre-commit-hooks) via `himmelctl ensure --items <id> --yes`,
# and prints everything it cannot converge (credentials, leaked url.*.insteadOf,
# ...) in a loud DRIFT block. `--only drift-check` is the read-only twin.
#
# Fully sandboxed: scratch HOME, a throwaway clone (all git via `git -C`), and a
# STUB himmelctl (HIMMEL_DRIFT_CTL) whose "installed hooks" are files in a
# fixture dir — nothing touches the real primary, ~/.claude or .git/hooks.
#
# Bash 3.2 compatible.

# shellcheck disable=SC2015 # assert_pass/assert_fail always return 0
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/himmel-update.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-himmel-update-drift.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

export USERPROFILE=''
export HOME="$TMP/home"
export CLAUDE_CONFIG_DIR="$TMP/no-claude-config"
export HERMES_HOME="$TMP/no-hermes"
export HIMMELCTL_CACHE_DIR="$TMP/himmelctl-cache"
export CODEX_HOME="$TMP/codex-home"
mkdir -p "$HOME" "$HIMMELCTL_CACHE_DIR" || exit 1
unset HIMMEL_UPDATE_CHANNEL
# Keep git from reading the operator's global/system config.
export GIT_CONFIG_GLOBAL="$TMP/gitconfig-global" GIT_CONFIG_NOSYSTEM=1

pass=0
fail=0
assert_pass() { pass=$((pass + 1)); echo "  PASS: $1"; }
assert_fail() { fail=$((fail + 1)); echo "  FAIL: $1"; }

CLONE="$TMP/clone"
mkdir -p "$CLONE/scripts/guardrails" "$CLONE/scripts/lib" || exit 1
src_scripts="$(dirname "$SCRIPT")"
if ! { cp "$SCRIPT" "$CLONE/scripts/himmel-update.sh" \
    && cp "$src_scripts/guardrails/lib.sh"        "$CLONE/scripts/guardrails/lib.sh" \
    && cp "$src_scripts/lib/cadence-format.sh"    "$CLONE/scripts/lib/cadence-format.sh" \
    && cp "$src_scripts/lib/resolve-hermes-py.sh" "$CLONE/scripts/lib/resolve-hermes-py.sh" \
    && cp "$src_scripts/lib/load-dotenv.sh"       "$CLONE/scripts/lib/load-dotenv.sh" \
    && git init --quiet "$CLONE"; }; then
    echo "FAIL: mock clone setup" >&2
    exit 1
fi

FIX="$TMP/fix"
mkdir -p "$FIX/hooks" || exit 1
export FIX
CTL="$TMP/ctl.sh"
# Stub himmelctl. `status --json`: pre-commit-hooks is degraded while
# $FIX/hooks/pre-commit is absent; luna-sources is a permanent credential red
# (unless $FIX/no-cred). `ensure --items <ids> --yes` logs the call and
# "installs" the hook into the fixture dir.
cat > "$CTL" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  status)
    items=""
    if [ ! -f "$FIX/hooks/pre-commit" ]; then
      items='{"id":"pre-commit-hooks","kind":"hook","desired":true,"actual":"degraded","severity":"degraded","detail":"missing hook type(s): pre-commit"}'
    fi
    if [ ! -f "$FIX/no-cred" ]; then
      [ -n "$items" ] && items="$items,"
      items="$items"'{"id":"luna-sources","kind":"vault","desired":true,"actual":"degraded","severity":"red","detail":"1 unhealthy (fix credentials/config on the source itself): youtube-playwright: auth-or-cookie-expired"}'
    fi
    printf '{"schemaVersion":1,"items":[%s]}\n' "$items" ;;
  ensure)
    echo "$*" >> "$FIX/ensure.log"
    case "$*" in *pre-commit-hooks*) : > "$FIX/hooks/pre-commit" ;; esac ;;
esac
exit 0
STUB
chmod +x "$CTL"

run_update() { # run_update <only-item>; sets OUT / RC
    RC=0
    OUT="$(cd "$CLONE" && HIMMEL_DRIFT_CTL="$CTL" PATH="/usr/bin:/bin:$PATH" \
        bash scripts/himmel-update.sh --only "$1" 2>&1)" || RC=$?
}
reset_fix() { rm -f "$FIX/hooks/pre-commit" "$FIX/ensure.log" "$FIX/no-cred"; }

echo "drift pass: allow-listed item converges, credential red is reported (HIMMEL-4246)"
reset_fix
run_update drift
[ "$RC" -eq 0 ] && assert_pass "drift apply exits 0" || assert_fail "drift apply rc=$RC: $OUT"
[ -f "$FIX/hooks/pre-commit" ] && assert_pass "missing pre-commit hook converged" || assert_fail "hook not converged: $OUT"
grep -q -- '--items pre-commit-hooks --yes' "$FIX/ensure.log" 2>/dev/null \
    && assert_pass "ensure called with --items pre-commit-hooks --yes" || assert_fail "ensure call missing/wrong: $(cat "$FIX/ensure.log" 2>/dev/null)"
if grep -q 'luna-sources' "$FIX/ensure.log" 2>/dev/null; then assert_fail "ensure must never be asked to fix luna-sources"; else assert_pass "credential item never handed to ensure"; fi
grep -qi 'converged.*pre-commit-hooks' <<< "$OUT" && assert_pass "output reports pre-commit-hooks converged" || assert_fail "no converged line: $OUT"
grep -q 'DRIFT' <<< "$OUT" && grep -q 'luna-sources' <<< "$OUT" \
    && assert_pass "credential red printed in the DRIFT block" || assert_fail "no DRIFT/luna-sources: $OUT"
drift_block="$(printf '%s\n' "$OUT" | sed -n '/DRIFT/,$p')"
if grep -q 'pre-commit-hooks' <<< "$drift_block"; then assert_fail "converged item still listed as drift"; else assert_pass "converged item absent from DRIFT block"; fi

echo "drift-check: read-only twin reports, changes nothing"
reset_fix
run_update drift-check
[ "$RC" -eq 0 ] && assert_pass "drift-check exits 0" || assert_fail "drift-check rc=$RC: $OUT"
[ ! -f "$FIX/hooks/pre-commit" ] && assert_pass "hook NOT created in check mode" || assert_fail "check mode mutated the hooks dir"
[ ! -s "$FIX/ensure.log" ] && assert_pass "ensure NOT called in check mode" || assert_fail "ensure called in check mode: $(cat "$FIX/ensure.log")"
grep -qi 'would converge.*pre-commit-hooks' <<< "$OUT" && assert_pass "check says it would converge pre-commit-hooks" || assert_fail "no would-converge line: $OUT"

echo "credential-only red: reported, never 'fixed'"
reset_fix
: > "$FIX/hooks/pre-commit"
run_update drift
[ ! -s "$FIX/ensure.log" ] && assert_pass "no ensure call when only a credential red exists" || assert_fail "ensure called: $(cat "$FIX/ensure.log")"
if grep -qi 'converged' <<< "$OUT"; then assert_fail "claims convergence with nothing converged: $OUT"; else assert_pass "no convergence claim"; fi
grep -q 'luna-sources' <<< "$OUT" && grep -q 'DRIFT' <<< "$OUT" && assert_pass "credential red in DRIFT block" || assert_fail "missing from DRIFT: $OUT"

echo "clean state: no DRIFT block"
reset_fix
: > "$FIX/hooks/pre-commit"; : > "$FIX/no-cred"
run_update drift
if grep -q 'DRIFT' <<< "$OUT"; then assert_fail "DRIFT block on a clean state: $OUT"; else assert_pass "no DRIFT block when nothing is drifted"; fi

echo "leaked url.*.insteadOf in the local config: WARN with the unset command, config untouched"
git -C "$CLONE" config --local url.x.insteadOf y
for item in drift drift-check; do
    reset_fix; : > "$FIX/hooks/pre-commit"; : > "$FIX/no-cred"
    run_update "$item"
    grep -q 'url.x.insteadof' <<< "$OUT" && assert_pass "$item: WARN names the leaked key" || assert_fail "$item: no insteadof WARN: $OUT"
    grep -q 'config --local --unset-all url.x.insteadof' <<< "$OUT" && assert_pass "$item: prints the unset remedy" || assert_fail "$item: no unset remedy: $OUT"
    [ "$(git -C "$CLONE" config --local --get url.x.insteadOf)" = "y" ] && assert_pass "$item: config left untouched" || assert_fail "$item: config was modified"
done
git -C "$CLONE" config --local --unset-all url.x.insteadOf
reset_fix; : > "$FIX/hooks/pre-commit"; : > "$FIX/no-cred"
run_update drift
if grep -qi 'insteadof' <<< "$OUT"; then assert_fail "insteadof WARN with no leak: $OUT"; else assert_pass "no insteadof WARN on a clean config"; fi

echo "codex plugin registration drift (startup-health plugin-unregistered)"
mkdir -p "$CLONE/scripts/codex" "$TMP/stubbin" || exit 1
printf '#!/bin/sh\nexit 0\n' > "$TMP/stubbin/codex"; chmod +x "$TMP/stubbin/codex"
cat > "$CLONE/scripts/codex/startup-health.sh" <<'STUB'
#!/usr/bin/env bash
if [ -f "$FIX/codex-registered" ]; then exit 0; fi
echo "WARN plugin-unregistered: telegram-himmel@himmel missing"; exit 1
STUB
cat > "$CLONE/scripts/codex/install-himmel-codex.sh" <<'STUB'
#!/usr/bin/env bash
echo install >> "$FIX/codex-install.log"; : > "$FIX/codex-registered"
STUB
reset_fix; : > "$FIX/hooks/pre-commit"; : > "$FIX/no-cred"; rm -f "$FIX/codex-registered" "$FIX/codex-install.log"
RC=0; OUT="$(cd "$CLONE" && HIMMEL_DRIFT_CTL="$CTL" PATH="$TMP/stubbin:/usr/bin:/bin:$PATH" bash scripts/himmel-update.sh --only drift-check 2>&1)" || RC=$?
[ ! -f "$FIX/codex-install.log" ] && assert_pass "check: codex installer not run" || assert_fail "check ran the codex installer"
grep -q 'plugin-unregistered' <<< "$OUT" && assert_pass "check: reports the unregistered plugin" || assert_fail "check: no codex finding: $OUT"
RC=0; OUT="$(cd "$CLONE" && HIMMEL_DRIFT_CTL="$CTL" PATH="$TMP/stubbin:/usr/bin:/bin:$PATH" bash scripts/himmel-update.sh --only drift 2>&1)" || RC=$?
[ -f "$FIX/codex-install.log" ] && assert_pass "apply: ran install-himmel-codex.sh" || assert_fail "apply did not run the codex installer: $OUT"
if grep -q 'DRIFT' <<< "$OUT"; then assert_fail "converged codex registration still in DRIFT: $OUT"; else assert_pass "apply: codex drift converged, no DRIFT block"; fi

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
