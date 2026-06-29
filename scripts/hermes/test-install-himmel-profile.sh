#!/usr/bin/env bash
# Hermetic tests for install-himmel-profile.sh (HIMMEL-557).
# No real hermes install needed: a stub CLI simulates `profile list/create`
# and HERMES_HOME points at a throwaway temp tree. Asserts the provisioner is
# additive (only himmel_agent gets the main-tier SOUL + parity_guard) and that
# --parity-guard is non-destructive (swap-only; never clobbers existing hooks).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$SCRIPT_DIR/install-himmel-profile.sh"

PYBIN="$(command -v python3 || command -v python)" || {
  echo "SKIP: no python available" >&2; exit 0; }

fails=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; fails=$((fails + 1)); }
assert_contains() { if grep -qF "$2" "$1"; then pass "$3"; else fail "$3 (missing '$2' in $1)"; fi; }
assert_absent()   { if grep -qF "$2" "$1"; then fail "$3 (unexpected '$2' in $1)"; else pass "$3"; fi; }
assert_file()     { if [ -f "$1" ]; then pass "$2"; else fail "$2 (no file $1)"; fi; }

# --- build a throwaway hermes home + stub CLI --------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/hermes"
mkdir -p "$HOME_DIR/agent-hooks" "$HOME_DIR/profiles"

# a stub `hermes` CLI: profile list / profile create --clone-from default
STUB="$TMP/hermes-stub.sh"
cat > "$STUB" <<'STUB_EOF'
#!/usr/bin/env bash
set -euo pipefail
H="${HERMES_HOME:?}"
if [ "${1:-}" = "profile" ] && [ "${2:-}" = "list" ]; then
  echo "default"
  [ -d "$H/profiles" ] && for d in "$H"/profiles/*/; do
    [ -d "$d" ] && basename "$d"
  done
  exit 0
fi
if [ "${1:-}" = "profile" ] && [ "${2:-}" = "create" ]; then
  name="$3"
  mkdir -p "$H/profiles/$name"
  cp "$H/config.yaml" "$H/profiles/$name/config.yaml"
  cp "$H/SOUL.md" "$H/profiles/$name/SOUL.md"
  exit 0
fi
exit 0
STUB_EOF
chmod +x "$STUB"

seed_default() {  # $1 = hooks-block style: "guard" | "empty"
  cat > "$HOME_DIR/SOUL.md" <<'EOF'
# Hermes Agent Persona
You are the low-risk junior reviewer. (user's own default — must stay untouched)
EOF
  {
    echo "model:"
    echo "  default: gpt-5.5"
    if [ "$1" = "guard" ]; then
      echo "hooks:"
      echo "  pre_tool_call:"
      echo "  - matcher: write_file|patch|terminal"
      echo "    command: '\"$PYBIN\" \"$HOME_DIR/agent-hooks/luna_vault_guard.py\"'"
      echo "    timeout: 10"
    else
      echo "hooks: {}"
    fi
    echo "security:"
    echo "  redact_secrets: true"
  } > "$HOME_DIR/config.yaml"
}

run() { HERMES_HOME="$HOME_DIR" HERMES_BIN="$STUB" HERMES_PY="$PYBIN" \
        bash "$INSTALLER" "$@"; }

echo "== scenario A: fresh default (no guard) -> himmel_agent gets parity_guard =="
seed_default empty
run >/dev/null
assert_file    "$HOME_DIR/agent-hooks/parity_guard.py" "guard asset installed"
assert_contains "$HOME_DIR/profiles/himmel_agent/SOUL.md" "main tier" "himmel_agent has main-tier SOUL"
assert_contains "$HOME_DIR/profiles/himmel_agent/config.yaml" "parity_guard.py" "himmel_agent wired to parity_guard"
assert_contains "$HOME_DIR/profiles/himmel_agent/config.yaml" "pre_tool_call" "himmel_agent hook block present"
assert_contains "$HOME_DIR/SOUL.md" "junior reviewer" "user default SOUL untouched"

echo "== scenario B: idempotent re-run =="
run >/dev/null
assert_contains "$HOME_DIR/profiles/himmel_agent/config.yaml" "parity_guard.py" "still wired after re-run"
# exactly one pre_tool_call entry (no duplication)
n="$(grep -c "pre_tool_call" "$HOME_DIR/profiles/himmel_agent/config.yaml" || true)"
if [ "$n" = "1" ]; then pass "no hook duplication"; else fail "hook duplicated ($n pre_tool_call)"; fi

echo "== scenario C: default had luna_vault_guard -> himmel_agent still parity =="
rm -rf "$HOME_DIR/profiles"; mkdir -p "$HOME_DIR/profiles"
seed_default guard
run >/dev/null
assert_contains "$HOME_DIR/profiles/himmel_agent/config.yaml" "parity_guard.py" "cloned-guard config replaced with parity"
assert_absent   "$HOME_DIR/profiles/himmel_agent/config.yaml" "luna_vault_guard.py" "luna_vault_guard removed from himmel_agent"

echo "== scenario D: --parity-guard=default swaps default's guard (non-destructive) =="
run --parity-guard=default >/dev/null
assert_contains "$HOME_DIR/config.yaml" "parity_guard.py" "default swapped to parity_guard"
assert_absent   "$HOME_DIR/config.yaml" "luna_vault_guard.py" "default no longer references luna_vault_guard"

echo "== scenario E: --parity-guard on a guard-less profile leaves it untouched =="
mkdir -p "$HOME_DIR/profiles/research"
printf 'model:\n  default: gpt-5.5\nhooks: {}\n' > "$HOME_DIR/profiles/research/config.yaml"
run --parity-guard=research >/dev/null
assert_absent "$HOME_DIR/profiles/research/config.yaml" "parity_guard.py" "guard-less profile not force-wired (non-destructive)"

echo ""
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED" >&2; exit 1; fi
