#!/usr/bin/env bash
# install-himmel-profile.sh (HIMMEL-557, HIMMEL-744)
#
# Provision the ADDITIVE `himmel_agent` hermes profile — himmel's main-tier
# orchestrator (Codex / GPT-5.5) — then wire the parity_guard into EVERY hermes
# profile (universal guard, HIMMEL-744). himmel owns only himmel_agent's
# SOUL/identity; SOUL stays per-role. The guard does NOT: it is universal.
# Non-clobbering — an existing luna_vault_guard is swapped, a profile with no
# guard has parity_guard ADDED (other unrelated hooks preserved). Idempotent.
#
#   install-himmel-profile.sh                  # himmel_agent + universal guard (default)
#   install-himmel-profile.sh --parity-guard=default,research   # narrow to named profiles
#
# By default the universal pass covers the `default` profile and all others.
# --parity-guard=<csv> narrows that pass to the named profiles only
# (=all is the explicit form of the default).
#
# Env overrides: HERMES_HOME (install root), HERMES_BIN (hermes CLI),
# HERMES_PY (python interpreter for the hook + wiring).
set -euo pipefail

PROFILE="himmel_agent"
PARITY_TARGETS=""

for arg in "$@"; do
  case "$arg" in
    --parity-guard=*) PARITY_TARGETS="${arg#*=}" ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERR: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS="$SCRIPT_DIR/assets"
SOUL_ASSET="$ASSETS/himmel-agent.SOUL.md"
GUARD_ASSET="$ASSETS/parity_guard.py"
WIRE="$ASSETS/wire_parity_guard.py"

for f in "$SOUL_ASSET" "$GUARD_ASSET" "$WIRE"; do
  [ -f "$f" ] || { echo "ERR: missing asset: $f" >&2; exit 1; }
done

# --- resolve hermes install root --------------------------------------------
resolve_home() {
  if [ -n "${HERMES_HOME:-}" ]; then echo "$HERMES_HOME"; return; fi
  if [ -n "${LOCALAPPDATA:-}" ]; then echo "$LOCALAPPDATA/hermes"; return; fi
  echo "$HOME/.local/share/hermes"
}
HOME_DIR="$(resolve_home)"
[ -d "$HOME_DIR" ] || { echo "ERR: hermes home not found at $HOME_DIR — is hermes installed? (set HERMES_HOME)" >&2; exit 1; }

# --- resolve hermes CLI ------------------------------------------------------
resolve_cli() {
  if [ -n "${HERMES_BIN:-}" ] && [ -x "${HERMES_BIN}" ]; then echo "$HERMES_BIN"; return; fi
  if command -v hermes >/dev/null 2>&1; then command -v hermes; return; fi
  for p in "$HOME_DIR/hermes-agent/venv/Scripts/hermes.exe" \
           "$HOME_DIR/hermes-agent/venv/bin/hermes"; do
    [ -x "$p" ] && { echo "$p"; return; }
  done
  return 1
}
HERMES="$(resolve_cli)" || { echo "ERR: hermes CLI not found (set HERMES_BIN)" >&2; exit 1; }

# --- resolve python interpreter (hook command + wiring) ----------------------
resolve_py() {
  if [ -n "${HERMES_PY:-}" ] && [ -x "${HERMES_PY}" ]; then echo "$HERMES_PY"; return; fi
  for p in "$HOME_DIR/hermes-agent/venv/Scripts/python.exe" \
           "$HOME_DIR/hermes-agent/venv/bin/python"; do
    [ -x "$p" ] && { echo "$p"; return; }
  done
  command -v python3 >/dev/null 2>&1 && { command -v python3; return; }
  command -v python  >/dev/null 2>&1 && { command -v python; return; }
  return 1
}
PYBIN="$(resolve_py)" || { echo "ERR: no python interpreter found (set HERMES_PY)" >&2; exit 1; }

GUARD_DEST="$HOME_DIR/agent-hooks/parity_guard.py"
HA_CONFIG="$HOME_DIR/profiles/$PROFILE/config.yaml"
HA_SOUL="$HOME_DIR/profiles/$PROFILE/SOUL.md"

echo "hermes home : $HOME_DIR"
echo "hermes CLI  : $HERMES"
echo "interpreter : $PYBIN"

# 1. install the guard into agent-hooks (idempotent)
mkdir -p "$HOME_DIR/agent-hooks"
cp "$GUARD_ASSET" "$GUARD_DEST"
echo "installed   : $GUARD_DEST"

# 2. create himmel_agent if missing (clone default for working keys/config)
if "$HERMES" profile list 2>/dev/null | grep -Eq "(^|[^a-z_])$PROFILE([^a-z_]|$)"; then
  echo "profile     : $PROFILE exists — refreshing assets (non-destructive)"
else
  echo "profile     : creating $PROFILE (clone of default)"
  "$HERMES" profile create "$PROFILE" --clone-from default \
    --description "himmel's main-tier orchestrator (Codex/GPT-5.5): code, repos, PRs, research, vault, writing. parity_guard (secret + catastrophic-shell fences kept). The main puller when Claude is scarce." >/dev/null
fi
[ -d "$HOME_DIR/profiles/$PROFILE" ] || { echo "ERR: $PROFILE profile dir missing after create" >&2; exit 1; }

# 3. install the main-tier SOUL onto himmel_agent (this profile is ours to own)
cp "$SOUL_ASSET" "$HA_SOUL"
echo "installed   : $HA_SOUL"

# 4. wire himmel_agent's pre_tool_call hook -> parity_guard (full set)
"$PYBIN" "$WIRE" set "$HA_CONFIG" "$GUARD_DEST" "$PYBIN"

# 5. universal guard (HIMMEL-744): ensure parity_guard on EVERY other profile.
#    Default (no flag) = the `default` profile + all others. --parity-guard=<csv>
#    narrows to named profiles; =all is the explicit form of the default. ensure
#    is non-clobbering: swaps a luna_vault_guard, adds the guard where none
#    exists, no-ops if already on parity_guard.
targets=""
if [ -z "$PARITY_TARGETS" ] || [ "$PARITY_TARGETS" = "all" ]; then
  targets="$HOME_DIR/config.yaml"   # the `default` profile
  if [ -d "$HOME_DIR/profiles" ]; then
    for d in "$HOME_DIR"/profiles/*/; do
      name="$(basename "$d")"
      [ "$name" = "$PROFILE" ] && continue
      [ -f "$d/config.yaml" ] && targets="$targets $d/config.yaml"
    done
  fi
else
  # comma-separated profile names (narrowing override)
  IFS=','; for name in $PARITY_TARGETS; do unset IFS
    name="$(echo "$name" | tr -d '[:space:]')"
    [ -z "$name" ] && continue
    if [ "$name" = "default" ]; then
      targets="$targets $HOME_DIR/config.yaml"
    else
      targets="$targets $HOME_DIR/profiles/$name/config.yaml"
    fi
  done; unset IFS
fi
for cfg in $targets; do
  if [ -f "$cfg" ]; then
    "$PYBIN" "$WIRE" ensure "$cfg" "$GUARD_DEST" "$PYBIN"
  else
    echo "SKIP: config not found: $cfg" >&2
  fi
done

echo "OK: himmel_agent provisioned. Reach it with:  hermes profile use $PROFILE"
echo "    Restart the gateway and approve the hook once: hermes gateway restart"
