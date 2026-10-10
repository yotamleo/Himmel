#!/usr/bin/env bash
# test-check-env.sh — scripts/cloud/check-env.sh (HIMMEL-5163). Hermetic: a
# fixture repo root (HIMMEL_CLOUD_ROOT), a fixture marker path, env -i for the
# "session" environment. The contract: the environment's variables and the
# setup script that ran are compared against the repo's declaration, and a
# mismatch names itself and exits 1.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/scripts/cloud/check-env.sh"
SETUP="$ROOT/scripts/cloud/setup-env.sh"
fails=0
ok() { echo "PASS - $1"; }
bad() { echo "FAIL - $1"; fails=$((fails + 1)); }

[ -f "$CHECK" ] || { echo "FAIL - $CHECK missing (every case below would pass or fail vacuously)"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cloud-check-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

FAKE="$TMP/repo"
mkdir -p "$FAKE/scripts/cloud"
printf '#!/bin/sh\necho setup\n' > "$FAKE/scripts/cloud/setup-env.sh"
cat > "$FAKE/scripts/cloud/environment.env" <<'EOF'
# rev: 7
JIRA_PROJECT_KEY=HIMMEL
BASH_DEFAULT_TIMEOUT_MS=600000
EOF
git -C "$FAKE" init -q
git -C "$FAKE" remote add origin git@github.com:someone/Himmel.git
MARK="$TMP/marker"
BASH_BIN="$(command -v bash)"

run() { # run [VAR=val ...] -- args... -> $OUT, $RC
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  OUT="$(env -i PATH="$PATH" HIMMEL_CLOUD_ROOT="$FAKE" HIMMEL_CLOUD_MARKER="$MARK" "${envs[@]}" "$BASH_BIN" "$CHECK" "$@" 2>&1)"
  RC=$?
}
GOODENV=(JIRA_PROJECT_KEY=HIMMEL BASH_DEFAULT_TIMEOUT_MS=600000)

# 1. stamp then check: all green, rc 0.
run -- --stamp
if [ "$RC" -eq 0 ] && [ -s "$MARK" ]; then ok "--stamp writes the marker"; else bad "--stamp rc=$RC marker missing: $OUT"; fi
run "${GOODENV[@]}" --
if [ "$RC" -eq 0 ]; then ok "matching env + marker exits 0"; else bad "matching case rc=$RC: $OUT"; fi

# 2. a wrong variable value fails and names the variable.
run JIRA_PROJECT_KEY=OTHER BASH_DEFAULT_TIMEOUT_MS=600000 --
if [ "$RC" -eq 1 ]; then ok "wrong value exits 1"; else bad "wrong value rc=$RC: $OUT"; fi
case "$OUT" in *JIRA_PROJECT_KEY*MISMATCH*) ok "mismatch names JIRA_PROJECT_KEY" ;; *) bad "mismatch not named: $OUT" ;; esac

# 3. an unset variable fails.
run JIRA_PROJECT_KEY=HIMMEL --
if [ "$RC" -eq 1 ]; then ok "unset variable exits 1"; else bad "unset variable rc=$RC: $OUT"; fi

# 4. the setup script changed since the snapshot: STALE.
printf '#!/bin/sh\necho setup v2\n' > "$FAKE/scripts/cloud/setup-env.sh"
run "${GOODENV[@]}" --
if [ "$RC" -eq 1 ]; then ok "changed setup script exits 1"; else bad "stale rc=$RC: $OUT"; fi
case "$OUT" in *STALE*) ok "stale marker is reported as STALE" ;; *) bad "STALE not reported: $OUT" ;; esac

# 5. no marker at all: MISSING.
rm -f "$MARK"
run "${GOODENV[@]}" --
case "$OUT" in *MISSING*) ok "absent marker is reported as MISSING" ;; *) bad "MISSING not reported: $OUT" ;; esac
if [ "$RC" -eq 1 ]; then ok "absent marker exits 1"; else bad "missing rc=$RC"; fi

# 6. --print emits the paste block from the declaration and the fork's origin.
run --  --print
if [ "$RC" -eq 0 ]; then ok "--print exits 0"; else bad "--print rc=$RC: $OUT"; fi
for want in "JIRA_PROJECT_KEY=HIMMEL" "BASH_DEFAULT_TIMEOUT_MS=600000" "# rev: 7" \
            "git clone --depth 1 https://github.com/someone/Himmel /tmp/himmel-setup" \
            "setup-env.sh --with-plugins || true"; do
  case "$OUT" in *"$want"*) ok "--print carries: $want" ;; *) bad "--print lacks '$want': $OUT" ;; esac
done

# 7. the real declaration and the real setup script agree with this contract.
if [ -f "$ROOT/scripts/cloud/environment.env" ]; then ok "environment.env is checked in"; else bad "scripts/cloud/environment.env missing"; fi
SOUT="$(env -i PATH="$PATH" HIMMEL_CLOUD_ROOT="$FAKE" "$BASH_BIN" "$SETUP" --dry-run 2>&1)"
case "$SOUT" in *"step=env-stamp "*) ok "setup-env.sh plans the env-stamp step" ;; *) bad "setup-env.sh lacks env-stamp: $SOUT" ;; esac

echo "fails=$fails"
[ "$fails" -eq 0 ]
