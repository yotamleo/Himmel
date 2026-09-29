#!/usr/bin/env bash
# HIMMEL-3851: vault-autosync.sh must ALERT the operator when a pre-commit hook
# keeps refusing the vault's pending changes (a "stall"), once per stall
# episode, naming the failing hook and the offending file. A stall is silent
# otherwise: the vault stops committing and nobody is told.
#
# Hermetic: a scratch repo with a LOCAL pre-commit hook that fails on a marker
# file, a local bare remote, and a stubbed alert sink (LUNA_VAULT_ALERT_CMD).
# SKIPs loud (never false-greens) without git or pre-commit.
#
# Usage: bash scripts/test-vault-autosync-stall.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/vault-autosync.sh"

FAILED=0
pass() { echo "PASS $1"; }
fail() {
  echo "FAIL $1 — $2"
  FAILED=$((FAILED + 1))
}
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi; }
assert_has() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "expected to contain '$2', got '$3'" ;; esac; }

command -v git >/dev/null 2>&1 || {
  echo "SKIP all — git not on PATH"
  exit 0
}
command -v pre-commit >/dev/null 2>&1 || {
  echo "SKIP all — pre-commit not on PATH (the stall is a pre-commit refusal)"
  exit 0
}

export GIT_AUTHOR_NAME=luna-test GIT_AUTHOR_EMAIL=luna-test@example.com
export GIT_COMMITTER_NAME=luna-test GIT_COMMITTER_EMAIL=luna-test@example.com

TMP=$(mktemp -d "${TMPDIR:-/tmp}/vault-autosync-stall.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
# Keep the host's global git config (core.hooksPath, templatedir) out of the fixture.
export GIT_CONFIG_GLOBAL="$TMP/gitconfig-isolated"
: >"$GIT_CONFIG_GLOBAL"

V="$TMP/vault"
BARE="$TMP/bare.git"
SINK="$TMP/sink.sh"
ALERTS="$TMP/alerts.log"

git init -q -b main "$V"
git init -q --bare -b main "$BARE"
git -C "$V" remote add origin "$BARE"

# A hook that refuses any staged file named bad-*.sh, printing shellcheck-style
# `In <file> line N:` output like the real shellcheck hook does.
cat >"$V/refuse-bad.sh" <<'EOF'
#!/usr/bin/env bash
rc=0
for f in "$@"; do
  case "$f" in
    */bad-*.sh | bad-*.sh) printf '\nIn %s line 1:\nnot a script\n^-- SC2148 (error): Tips depend on target shell.\n' "$f"; rc=1 ;;
  esac
done
exit "$rc"
EOF
cat >"$V/.pre-commit-config.yaml" <<'EOF'
repos:
  - repo: local
    hooks:
      - id: fake-shellcheck
        name: fake-shellcheck
        entry: bash refuse-bad.sh
        language: system
        files: '\.sh$'
EOF
: >"$V/.gitignore"
printf '%s\n' 'seed' >"$V/seed.md"
git -C "$V" add -A
git -C "$V" commit -q -m "seed" --no-verify
git -C "$V" push -q origin main
(cd "$V" && pre-commit install >/dev/null 2>&1)

# Stub sink: appends its single message argument, one line per alert.
cat >"$SINK" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >>"$ALERTS"
EOF
chmod +x "$SINK"

STATE="$V/.git/vault-autosync-stall"
run_sync() {
  (cd "$V" && LUNA_VAULT_AUTOSYNC=1 LUNA_VAULT_ALERT_CMD="${SINK_OVERRIDE:-$SINK}" \
    LUNA_VAULT_STALL_THRESHOLD_MIN="${THRESHOLD:-30}" bash "$SCRIPT") >/dev/null 2>&1
}
alert_count() { if [ -f "$ALERTS" ]; then wc -l <"$ALERTS" | tr -d ' '; else echo 0; fi; }
# Pretend the episode began an hour ago (line 1 of the state file = first-blocked epoch).
backdate() { printf '%s\n' "$(($(date +%s) - 3600))" >"$STATE"; }

# --- S1: a healthy commit alerts nobody and leaves no stall state -----------
printf 'note\n' >"$V/note.md"
run_sync
assert_eq "S1 healthy commit: no alert" "0" "$(alert_count)"
assert_eq "S1b healthy commit: no stall state" "no" "$([ -e "$STATE" ] && echo yes || echo no)"

# --- S2: a refused commit inside the threshold records the episode, no alert -
mkdir -p "$V/handovers/x/logs"
printf 'echo scratch\n' >"$V/handovers/x/logs/bad-scratch.sh"
run_sync
assert_eq "S2 refused commit under threshold: no alert yet" "0" "$(alert_count)"
assert_eq "S2b stall episode recorded" "yes" "$([ -e "$STATE" ] && echo yes || echo no)"

# --- S3: past the threshold the operator is alerted, naming hook and file ---
backdate
run_sync
assert_eq "S3 stall past threshold: exactly one alert" "1" "$(alert_count)"
msg="$(cat "$ALERTS" 2>/dev/null)"
assert_has "S3b alert names the failing hook" "fake-shellcheck" "$msg"
assert_has "S3c alert names the offending file" "handovers/x/logs/bad-scratch.sh" "$msg"

# --- S4: further refused retries in the SAME episode stay silent ------------
run_sync
run_sync
assert_eq "S4 same episode, more retries: still one alert" "1" "$(alert_count)"

# --- S5: recovery clears the episode; a NEW stall alerts again --------------
rm -f "$V/handovers/x/logs/bad-scratch.sh"
run_sync
assert_eq "S5 recovery: stall state cleared" "no" "$([ -e "$STATE" ] && echo yes || echo no)"
printf 'echo scratch2\n' >"$V/handovers/x/logs/bad-second.sh"
run_sync
backdate
run_sync
assert_eq "S5b second episode: a second alert" "2" "$(alert_count)"
assert_has "S5c second alert names the second file" "bad-second.sh" "$(tail -n 1 "$ALERTS")"

# --- S6: a sink that fails does not mark the episode alerted (retried) ------
rm -f "$V/handovers/x/logs/bad-second.sh"
run_sync
printf 'echo scratch3\n' >"$V/handovers/x/logs/bad-third.sh"
run_sync
backdate
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/failing-sink.sh"
chmod +x "$TMP/failing-sink.sh"
SINK_OVERRIDE="$TMP/failing-sink.sh" run_sync
assert_eq "S6 failing sink: no alert recorded" "2" "$(alert_count)"
run_sync
assert_eq "S6b next run with a working sink delivers it" "3" "$(alert_count)"

# --- S7: no sink configured must not crash the sync -------------------------
rm -f "$V/handovers/x/logs/bad-third.sh"
run_sync
printf 'echo scratch4\n' >"$V/handovers/x/logs/bad-fourth.sh"
backdate
s7_out="$(cd "$V" && env -u LUNA_VAULT_ALERT_CMD LUNA_VAULT_AUTOSYNC=1 LUNA_VAULT_STALL_THRESHOLD_MIN=30 bash "$SCRIPT" 2>&1)"
assert_has "S7 no sink configured: stall is logged, sync does not crash" "no operator alert sent" "$s7_out"
assert_eq "S7b no sink configured: no alert delivered" "3" "$(alert_count)"

echo "----"
if [ "$FAILED" -eq 0 ]; then
  echo "PASS: vault-autosync-stall ($0)"
else
  echo "FAIL: vault-autosync-stall — $FAILED failed ($0)" >&2
  exit 1
fi
