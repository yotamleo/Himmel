#!/usr/bin/env bash
# test-ubuntu-shim.sh — HIMMEL-887 T8. ubuntu.sh is soft-deprecated: it KEEPS
# its full-toolchain provisioning (locked O4 option (b) — zero capability
# loss) but stops doing himmel/luna WIRING itself and delegates that to
# `himmelctl bootstrap` (the correct entry for a node-less machine; `install`
# directly would fail pre-node).
#
# Covers:
#   A. capability-regression guard — every tool the OLD script's fatal
#      provisioning block installed is still installed by the shim. Parses
#      the provisioning block and compares against a committed expected list
#      ("banners gone" alone is NOT sufficient).
#   B. order assertion — runs the REAL ubuntu.sh (stubbed sudo/apt/curl/git/
#      node/nvm/uv/claude/rtk on PATH, HOME redirected to a temp dir) and
#      asserts provisioning happens BEFORE the deprecation notice, which
#      happens BEFORE the delegated bootstrap invocation — AND (CR r4) that
#      the bootstrap runs with cwd=$HIMMEL_PATH (the wizard's role/scope
#      inference reads the CWD, so delegating from the operator's launch
#      directory would target the wrong repo).
#   C. CR r2 fail-closed --luna-remote guard — the delegated flow can't
#      restore a remote vault yet (HIMMEL-755), so passing the flag must
#      error out BEFORE any provisioning (no apt call, no bootstrap
#      invocation) instead of silently completing a rebuild without the
#      operator's vault.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
target="$repo_root/scripts/machine-setup/ubuntu.sh"
[ -f "$target" ] || { echo "FAIL: $target not found" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

work=$(mktemp -d)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

# ── Case A: capability-regression guard ─────────────────────────────────────
# The committed expected tool list (HIMMEL-887 T8) — every tool the old
# ubuntu.sh's fatal provisioning block (steps 1-6) installed, before wiring
# was dropped. If this list shrinks, provisioning capability regressed.
expected_apt_tools="curl git gitleaks jq python3 python3-pip shellcheck"

apt_line=$(grep -oE 'sudo apt install -y [a-z0-9. -]+' "$target" | head -1)
[ -n "$apt_line" ] || fail "caseA: could not find the core-tools 'sudo apt install -y ...' line"
actual_apt_tools=$(echo "$apt_line" | sed 's/^sudo apt install -y //' | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')
expected_sorted=$(echo "$expected_apt_tools" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')
[ "$actual_apt_tools" = "$expected_sorted" ] \
  || fail "caseA: core-tools apt-install list regressed -- expected [$expected_sorted], got [$actual_apt_tools]"

grep -q 'NVM_DIR' "$target" || fail "caseA: nvm provisioning missing"
grep -q 'nvm install' "$target" || fail "caseA: nvm install call missing"
grep -q 'astral.sh/uv/install.sh' "$target" || fail "caseA: uv provisioning missing"
grep -q 'claude.ai/install.sh' "$target" || fail "caseA: claude CLI provisioning missing"
grep -q 'rtk-ai/rtk/releases' "$target" || fail "caseA: rtk provisioning missing"
echo "ok: caseA every tool the old ubuntu.sh provisioned (${expected_sorted}, nvm, uv, claude, rtk) is still provisioned"

# ── Case B: order assertion (provisioning < notice < delegated bootstrap) ──
tmp_home="$work/home"
mkdir -p "$tmp_home"
stub_bin="$work/stub-bin"
mkdir -p "$stub_bin"

cat > "$stub_bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF

cat > "$stub_bin/apt" <<'EOF'
#!/usr/bin/env bash
echo "PROVISION:apt $*"
exit 0
EOF

cat > "$stub_bin/curl" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *api.github.com*) echo '{"tag_name":"v1.0.0"}' ;;
  *) exit 0 ;;
esac
EOF

cat > "$stub_bin/git" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "clone" ]; then
  target="$*"
  target="${target##* }"
  mkdir -p "$target/scripts/hooks" "$target/scripts/himmelctl"
  cat > "$target/scripts/hooks/check-hookspath.sh" <<'INNER'
#!/usr/bin/env bash
echo "STUB:check-hookspath"
exit 0
INNER
  cat > "$target/scripts/himmelctl/bootstrap.sh" <<'INNER'
#!/usr/bin/env bash
echo "BOOTSTRAP:invoked $*"
echo "BOOTSTRAP:pwd $PWD"
exit 0
INNER
  chmod +x "$target/scripts/hooks/check-hookspath.sh" "$target/scripts/himmelctl/bootstrap.sh"
fi
exit 0
EOF

node_stub_version="24.0.0"
cat > "$stub_bin/node" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "--version" ]; then echo "v${node_stub_version}"; exit 0; fi
exit 0
EOF

cat > "$stub_bin/uv" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then echo "uv-stub 1.0.0"; exit 0; fi
exit 0
EOF

cat > "$stub_bin/claude" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then echo "claude-stub 1.0.0"; exit 0; fi
exit 0
EOF

cat > "$stub_bin/rtk" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --version) echo "rtk-stub 1.0.0"; exit 0 ;;
  *) exit 0 ;;
esac
EOF

chmod +x "$stub_bin"/sudo "$stub_bin"/apt "$stub_bin"/curl "$stub_bin"/git \
  "$stub_bin"/node "$stub_bin"/uv "$stub_bin"/claude "$stub_bin"/rtk

# Pre-create $NVM_DIR/nvm.sh as a shell-function stub (nvm is sourced, not
# exec'd, so it can't be a PATH stub) — this also skips the real curl-based
# nvm installer via ubuntu.sh's own `[ ! -d "$NVM_DIR" ]` guard.
mkdir -p "$tmp_home/.nvm"
cat > "$tmp_home/.nvm/nvm.sh" <<'EOF'
nvm() { echo "STUB:nvm $*"; return 0; }
EOF

log="$work/run.log"
set +e
HOME="$tmp_home" PATH="$stub_bin:$PATH" bash "$target" >"$log" 2>&1
run_rc=$?
set -e
# The delegated bootstrap stub exits 0, so ubuntu.sh (via exec) should too.
[ "$run_rc" -eq 0 ] || { cat "$log" >&2; fail "caseB: ubuntu.sh exited $run_rc against the fully-stubbed environment (log above)"; }

provision_line=$(grep -n '^PROVISION:apt' "$log" | head -1 | cut -d: -f1)
notice_line=$(grep -n 'soft-deprecated' "$log" | head -1 | cut -d: -f1)
bootstrap_line=$(grep -n '^BOOTSTRAP:invoked' "$log" | head -1 | cut -d: -f1)

[ -n "$provision_line" ] || { cat "$log" >&2; fail "caseB: no PROVISION marker found (log above)"; }
[ -n "$notice_line" ] || { cat "$log" >&2; fail "caseB: no deprecation-notice marker found (log above)"; }
[ -n "$bootstrap_line" ] || { cat "$log" >&2; fail "caseB: no BOOTSTRAP marker found (log above)"; }

[ "$provision_line" -lt "$notice_line" ] \
  || fail "caseB: provisioning (line $provision_line) did not happen before the deprecation notice (line $notice_line)"
[ "$notice_line" -lt "$bootstrap_line" ] \
  || fail "caseB: deprecation notice (line $notice_line) did not happen before the delegated bootstrap invocation (line $bootstrap_line)"

# CR r4: the delegation must run FROM the himmel clone (the wizard's
# role/scope inference reads the CWD's git origin; scope=project wires
# .claude into the CWD), never from the operator's launch directory. The
# bootstrap stub records its $PWD; it must be exactly $HIMMEL_PATH
# ($HOME/github/himmel under the redirected temp HOME).
expected_pwd="$tmp_home/github/himmel"
bootstrap_pwd=$(grep '^BOOTSTRAP:pwd ' "$log" | head -1 | sed 's/^BOOTSTRAP:pwd //')
[ -n "$bootstrap_pwd" ] || { cat "$log" >&2; fail "caseB: no BOOTSTRAP:pwd marker found (log above)"; }
[ "$bootstrap_pwd" = "$expected_pwd" ] \
  || fail "caseB: bootstrap must be invoked with cwd=\$HIMMEL_PATH ($expected_pwd), got: $bootstrap_pwd"
echo "ok: caseB provisioning ($provision_line) < notice ($notice_line) < delegated bootstrap ($bootstrap_line), cwd=\$HIMMEL_PATH"

# ── Case C: --luna-remote -> fail-closed BEFORE any provisioning ───────────
# Reuses the Case B stub environment (same stub PATH + temp HOME) so a
# regression that lets the run continue would be caught by the provisioning/
# bootstrap markers, not by a missing-tool crash.
logC="$work/run-luna-remote.log"
set +e
HOME="$tmp_home" PATH="$stub_bin:$PATH" \
  bash "$target" --luna-remote "git@example.invalid:op/luna.git" >"$logC" 2>&1
run_rcC=$?
set -e
[ "$run_rcC" -ne 0 ] || { cat "$logC" >&2; fail "caseC: --luna-remote must exit nonzero (fail-closed), got rc=0 (log above)"; }
grep -q 'not supported' "$logC" \
  || { cat "$logC" >&2; fail "caseC: expected the not-supported error message (log above)"; }
grep -q 'Clone the vault manually first' "$logC" \
  || { cat "$logC" >&2; fail "caseC: expected the manual-clone remediation line (log above)"; }
grep -q '^PROVISION:apt' "$logC" \
  && fail "caseC: --luna-remote must fail BEFORE any provisioning (apt ran: $(cat "$logC"))"
grep -q '^BOOTSTRAP:invoked' "$logC" \
  && fail "caseC: --luna-remote must never reach the delegated bootstrap (got: $(cat "$logC"))"
echo "ok: caseC --luna-remote -> fail-closed error before any provisioning, bootstrap never invoked"

echo "PASS"
