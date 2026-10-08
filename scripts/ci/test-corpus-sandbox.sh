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
argv = ["--", "bash", hook_path]
subprocess.Popen(["bash", runner] + argv)
PY
cat > "$SHELL_FIXTURE" <<'SH'
RUNNER="sandbox-run.sh"
printf '%s' "$input" | bash "$RUNNER" -- bash "$HOOK"
SH
if python3 -I "$LINT" "$TMP" >/dev/null 2>&1; then ok 'routed launch accepted'; else bad 'routed launch rejected'; fi
# These are source fixtures scanned as data, never expanded or executed.
# shellcheck disable=SC2016
for binding in 'RUNNER="$HOOK"' 'RUNNER="/tmp/not-the-runner.sh"' \
    'RUNNER="sandbox-run.sh"; RUNNER="$HOOK"' \
    'RUNNER="sandbox-run.sh"\nRUNNER="$HOOK"' \
    'if false; then RUNNER="sandbox-run.sh"; fi' \
    'RUNNER="$(echo sandbox-run.sh)"' ''; do
    printf '# sandbox-run.sh marker must not certify a binding\n%b\nbash "$RUNNER" -- bash "$HOOK"\n' "$binding" > "$SHELL_FIXTURE"
    if python3 -I "$LINT" "$TMP" >/dev/null 2>&1; then
        bad "unproven shell runner binding accepted: $binding"
    else ok "unproven shell runner binding rejected: $binding"; fi
done
cat > "$SHELL_FIXTURE" <<'SH'
RUNNER="$(cd "$(dirname "$HOOK")/../lib" && pwd)/sandbox-run.sh"
bash "$RUNNER" -- bash "$HOOK"
SH
if python3 -I "$LINT" "$TMP" >/dev/null 2>&1; then ok 'real shell runner binding accepted'; else bad 'real shell runner binding rejected'; fi
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
cat > "$PY_FIXTURE" <<'PY'
import subprocess
runner = "sandbox-run.sh" if False else "/tmp/not-the-runner.sh"
subprocess.Popen(["bash", runner])
PY
if python3 -I "$LINT" "$TMP" >/dev/null 2>&1; then bad 'conditional marker falsely certifies another executable'; else ok 'conditional marker does not certify runner'; fi
for mutation in 'argv[0] = "sh"' 'argv[1] = hook_path' 'del argv[0]' \
    'argv.clear()' 'argv.insert(0, "sh")' 'argv.pop(1)' \
    'alias = argv; alias[1] = hook_path' 'rewrite(argv)'; do
    cat > "$PY_FIXTURE" <<'PY'
import subprocess
runner = "sandbox-run.sh"
argv = ["bash", runner]
PY
    printf '%s\nsubprocess.Popen(argv)\n' "$mutation" >> "$PY_FIXTURE"
    if python3 -I "$LINT" "$TMP" >/dev/null 2>&1; then bad "mutated argv prefix falsely certified: $mutation"; else ok "mutated argv prefix rejected: $mutation"; fi
done
if python3 -I "$LINT" "$ROOT"; then ok 'owned real harnesses routed, others warned'; else bad 'real corpus sandbox lint'; fi
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
