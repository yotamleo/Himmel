#!/usr/bin/env bash
# HIMMEL-4912: architecture lint catches direct hook launches, even when a
# sandbox marker occurs elsewhere. Fixtures are scanned as data, never run.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LINT="$ROOT/scripts/ci/lint-corpus-sandbox.py"
TMP="$(mktemp -d /tmp/corpus-lint-test.XXXXXX)" || exit 1
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
if [ ! -f "$LINT" ]; then bad 'corpus sandbox lint missing'; exit 1; fi
mkdir -p "$TMP/scripts/hooks" "$TMP/scripts/eval/guard-corpus"
SHELL_FIXTURE="$TMP/scripts/hooks/test-block-destructive-commands.sh"
PY_FIXTURE="$TMP/scripts/eval/guard-corpus/diff"
cat > "$PY_FIXTURE" <<'PY'
import subprocess
runner = "sandbox-run.sh"
argv = ["bash", runner]
subprocess.Popen(argv)
PY
cat > "$SHELL_FIXTURE" <<'SH'
RUNNER="sandbox-run.sh"
printf '%s' "$input" | bash "$RUNNER" -- bash "$HOOK"
SH
if python3 -I "$LINT" "$TMP" >/dev/null 2>&1; then ok 'routed launch accepted'; else bad 'routed launch rejected'; fi
cat >> "$SHELL_FIXTURE" <<'SH'
printf '%s' "$input" | bash "$HOOK"
SH
if python3 -I "$LINT" "$TMP" >/dev/null 2>&1; then bad 'unwrapped launch hidden by sandbox marker'; else ok 'unwrapped launch rejected despite marker'; fi
cat > "$SHELL_FIXTURE" <<'SH'
RUNNER="sandbox-run.sh"
bash "$RUNNER" -- bash "$HOOK"; bash "$HOOK"
SH
if python3 -I "$LINT" "$TMP" >/dev/null 2>&1; then bad 'second unsandboxed simple command accepted'; else ok 'second unsandboxed simple command rejected'; fi
cat > "$SHELL_FIXTURE" <<'SH'
RUNNER="sandbox-run.sh"
bash "$RUNNER" -- bash "$HOOK"
SH
cat >> "$PY_FIXTURE" <<'PY'
subprocess.Popen(["bash", hook_path])
PY
if python3 -I "$LINT" "$TMP" >/dev/null 2>&1; then bad 'direct Python launch accepted'; else ok 'direct Python launch rejected'; fi
cat > "$PY_FIXTURE" <<'PY'
import subprocess
runner = "sandbox-run.sh"
argv = ["bash", hook_path]
subprocess.Popen(argv)
PY
if python3 -I "$LINT" "$TMP" >/dev/null 2>&1; then bad 'unsafe named Python argv accepted'; else ok 'unsafe named Python argv rejected'; fi
if python3 -I "$LINT" "$ROOT"; then ok 'owned real harnesses routed, others warned'; else bad 'real corpus sandbox lint'; fi
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
