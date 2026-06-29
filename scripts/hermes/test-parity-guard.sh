#!/usr/bin/env bash
# Tests for the security-critical guard + wiring assets (HIMMEL-557).
# Drives parity_guard.py over stdin and asserts block/allow; exercises
# wire_parity_guard.py set/swap. Hermetic: HERMES_HOME points at a temp tree.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/assets/parity_guard.py"
WIRE="$SCRIPT_DIR/assets/wire_parity_guard.py"
PY="$(command -v python3 || command -v python)" || { echo "SKIP: no python"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/hermes/agent-hooks"
# On Git Bash, MSYS rewrites a /tmp env value to Windows form when launching
# the native python — so resolve HERMES_HOME and the payload paths to the SAME
# form (cygpath -m) to avoid a spurious mismatch. No-op off Windows.
H="$TMP/hermes"
if command -v cygpath >/dev/null 2>&1; then H="$(cygpath -m "$TMP/hermes")"; fi
export HERMES_HOME="$H"   # guard lower-cases internally via norm()

fails=0
# expect = "block" | "allow"
g() {  # g "<label>" "<expect>" '<json payload>'
  out="$(printf '%s' "$3" | "$PY" "$GUARD")"
  case "$out" in
    *'"decision": "block"'*) got=block ;;
    '{}')                     got=allow ;;
    *)                        got="?($out)" ;;
  esac
  if [ "$got" = "$2" ]; then echo "  ok: $1"; else
    echo "  FAIL: $1 — expected $2 got $got" >&2; fails=$((fails + 1)); fi
}

echo "== parity_guard: self-protection (any arg key) =="
g "guard self-write (path key)"   block "{\"tool_name\":\"write_file\",\"tool_input\":{\"path\":\"$H/agent-hooks/parity_guard.py\"}}"
g "guard self-write (odd key)"    block "{\"tool_name\":\"write_file\",\"tool_input\":{\"filename\":\"$H/agent-hooks/parity_guard.py\"}}"
g "profile SOUL write (odd key)"  block "{\"tool_name\":\"write_file\",\"tool_input\":{\"output\":\"$H/profiles/x/SOUL.md\"}}"
g "profile config write"          block "{\"tool_name\":\"write_file\",\"tool_input\":{\"target\":\"$H/profiles/x/config.yaml\"}}"

echo "== parity_guard: secret read fence (any arg key + classes) =="
g ".env (path key)"      block '{"tool_name":"read_file","tool_input":{"path":"/x/.env"}}'
g ".env (odd key)"       block '{"tool_name":"read_file","tool_input":{"whatever":"/x/.env"}}'
g ".envrc"               block '{"tool_name":"read_file","tool_input":{"path":"/x/.envrc"}}'
g "id_rsa"               block '{"tool_name":"read_file","tool_input":{"path":"/home/u/id_rsa"}}'
g "relative .ssh/"       block '{"tool_name":"read_file","tool_input":{"path":".ssh/id_ed25519"}}'
g "secrets.yaml"         block '{"tool_name":"read_file","tool_input":{"path":"/x/secrets.yaml"}}'
g "cert.p12"             block '{"tool_name":"read_file","tool_input":{"path":"/x/cert.p12"}}'
g "normal file read"     allow '{"tool_name":"read_file","tool_input":{"path":"/x/README.md"}}'

echo "== parity_guard: writes allowed where they should be =="
g "repo code write"      allow '{"tool_name":"write_file","tool_input":{"path":"/repo/foo.sh"}}'
g "content not over-blocked" allow '{"tool_name":"write_file","tool_input":{"path":"/repo/doc.md","content":"see /x/.env and config.yaml"}}'

echo "== parity_guard: terminal classes =="
g "git commit"     allow '{"tool_name":"terminal","tool_input":{"command":"git commit -m x"}}'
g "git push force" block '{"tool_name":"terminal","tool_input":{"command":"git push --force"}}'
g "rm -rf"         block '{"tool_name":"terminal","tool_input":{"command":"rm -rf build"}}'
g "plain rm"       allow '{"tool_name":"terminal","tool_input":{"command":"rm tmp.txt"}}'
g "schtasks"       block '{"tool_name":"terminal","tool_input":{"command":"schtasks /delete /tn X"}}'

echo "== parity_guard: fail-closed on malformed payload =="
g "malformed json" block 'NOT JSON'

echo "== wire_parity_guard: set (insert + replace) =="
cfg="$TMP/c1.yaml"
printf 'model:\n  default: gpt-5.5\nhooks: {}\nsecurity:\n  redact_secrets: true\n' > "$cfg"
"$PY" "$WIRE" set "$cfg" "$H/agent-hooks/parity_guard.py" "$PY" >/dev/null
if grep -q "parity_guard.py" "$cfg" && grep -q "pre_tool_call" "$cfg" && grep -q "redact_secrets" "$cfg"; then
  echo "  ok: set inserted hook, preserved other keys"; else
  echo "  FAIL: set did not wire correctly" >&2; fails=$((fails + 1)); fi
# replace an existing luna_vault_guard block; the top-level key AFTER the hooks
# block (here `trailing:`) MUST survive — guards against truncation.
printf 'hooks:\n  pre_tool_call:\n  - matcher: x\n    command: luna_vault_guard.py\n    timeout: 10\ntrailing: keep-me\n' > "$cfg"
"$PY" "$WIRE" set "$cfg" "$H/agent-hooks/parity_guard.py" "$PY" >/dev/null
n="$(grep -c "pre_tool_call" "$cfg")"
if grep -q "parity_guard.py" "$cfg" && ! grep -q "luna_vault_guard" "$cfg" && [ "$n" = "1" ] && grep -q "trailing: keep-me" "$cfg"; then
  echo "  ok: set replaced existing block (no dup, no leftover, trailing key kept)"; else
  echo "  FAIL: set replace wrong (n=$n, trailing key truncated?)" >&2; fails=$((fails + 1)); fi

echo "== wire_parity_guard: swap (non-destructive) =="
printf 'hooks:\n  pre_tool_call:\n  - command: /x/agent-hooks/luna_vault_guard.py\n' > "$cfg"
"$PY" "$WIRE" swap "$cfg" >/dev/null
if grep -q "parity_guard.py" "$cfg" && ! grep -q "luna_vault_guard" "$cfg"; then
  echo "  ok: swap converted luna_vault_guard -> parity_guard"; else
  echo "  FAIL: swap did not convert" >&2; fails=$((fails + 1)); fi
printf 'hooks: {}\n' > "$cfg"
before="$(cat "$cfg")"; "$PY" "$WIRE" swap "$cfg" >/dev/null
if [ "$(cat "$cfg")" = "$before" ]; then
  echo "  ok: swap left guard-less config untouched"; else
  echo "  FAIL: swap modified a guard-less config" >&2; fails=$((fails + 1)); fi

echo ""
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED" >&2; exit 1; fi
