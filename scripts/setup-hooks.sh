#!/usr/bin/env bash
set -e

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GUARDRAIL_BLOCK="$SCRIPT_DIR/hooks/guardrail-block.mjs"

# ── guardrail mode toggle (HIMMEL-709) ───────────────────────────────────────
# `--guardrail-mode global|project` manages the himmel-owned user-level
# guardrail block via guardrail-block.mjs. Optional; a bare `setup-hooks.sh`
# installs git hooks (below) and only PRINTS guardrail status (no mutation).
GUARDRAIL_MODE=""
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --guardrail-mode) GUARDRAIL_MODE="__next__" ;;
    --guardrail-mode=*) GUARDRAIL_MODE="${arg#--guardrail-mode=}" ;;
    --yes|-y) ASSUME_YES=1 ;;
    *)
      if [ "$GUARDRAIL_MODE" = "__next__" ]; then GUARDRAIL_MODE="$arg";
      else echo "setup-hooks: unknown arg: $arg" >&2; exit 2; fi ;;
  esac
done
if [ "$GUARDRAIL_MODE" = "__next__" ]; then
  echo "setup-hooks: --guardrail-mode requires a value (global|project)" >&2; exit 2
fi

is_windows() {
  case "$(uname -s 2>/dev/null || echo)" in
    *MINGW*|*MSYS*|*CYGWIN*|*NT*) return 0 ;; *) return 1 ;;
  esac
}

# Absolute native path to node (baked into the hook commands + used to run the
# module). cygpath -m yields the C:/… form node/execFileSync can execute.
resolve_node() {
  local n
  n=$(command -v node 2>/dev/null) || return 1
  if is_windows && command -v cygpath >/dev/null 2>&1; then cygpath -m "$n" 2>/dev/null && return 0; fi
  printf '%s\n' "$n"
}

# Absolute native path to a real bash for the wrapper's GUARDRAIL_BASH — a bare
# `bash` on Windows may resolve to the WSL System32 stub and fail the guardrail
# closed, so prefer git-bash.exe by absolute path.
resolve_bash() {
  local b c
  if is_windows; then
    for c in "C:/Program Files/Git/bin/bash.exe" "C:/Program Files/Git/usr/bin/bash.exe" \
             "C:/Program Files (x86)/Git/bin/bash.exe"; do
      [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
    done
    b=$(command -v bash 2>/dev/null || echo)
    if [ -n "$b" ] && command -v cygpath >/dev/null 2>&1; then cygpath -m "$b" 2>/dev/null && return 0; fi
    printf '%s\n' "${b:-bash}"; return 0
  fi
  command -v bash 2>/dev/null || printf 'bash\n'
}

confirm() {
  # $1 = prompt. Honors --yes; on a non-tty with no --yes, callers decide.
  local ans
  [ "$ASSUME_YES" -eq 1 ] && return 0
  read -r -p "$1 [y/N] " ans || return 1
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

run_guardrail_mode() {
  local mode="$1" current node_abs bash_abs
  case "$mode" in global|project) ;; *) echo "setup-hooks: --guardrail-mode must be global|project" >&2; exit 2 ;; esac
  command -v node >/dev/null 2>&1 || { echo "setup-hooks: node not found on PATH (required for guardrail mode)" >&2; exit 1; }

  current=$(node "$GUARDRAIL_BLOCK" detect)

  if [ "$mode" = "project" ]; then
    if [ "$current" != "global" ]; then
      echo "guardrail mode already project (no user-level block to remove)."
      return 0
    fi
    # Destructive: removes the user-level block. NEVER infer consent from a
    # non-tty — an in-himmel agent runs non-tty and could otherwise strip the
    # security guardrails machine-wide.
    if [ "$ASSUME_YES" -ne 1 ] && [ ! -t 0 ]; then
      echo "setup-hooks: refusing global->project (removes user-level guardrails) without --yes on a non-interactive shell" >&2
      exit 3
    fi
    confirm "Remove the user-level guardrail block (global -> project)?" || { echo "aborted."; exit 0; }
    node "$GUARDRAIL_BLOCK" project
    return 0
  fi

  # mode = global: prompt only on a real transition; then ALWAYS run install —
  # it is idempotent (no-op if byte-identical) and re-bakes STALE node/bash/
  # wrapper paths in place, which is exactly the re-home case where the block
  # already exists (current == global) but points at old paths.
  if [ "$current" != "global" ]; then
    confirm "Install the himmel user-level guardrail block (-> global)?" || { echo "aborted."; exit 0; }
  fi
  node_abs=$(resolve_node) || { echo "setup-hooks: could not resolve an absolute node path" >&2; exit 1; }
  bash_abs=$(resolve_bash)
  node "$GUARDRAIL_BLOCK" global --node "$node_abs" --bash "$bash_abs"
}

if [ -n "$GUARDRAIL_MODE" ]; then
  run_guardrail_mode "$GUARDRAIL_MODE"
  exit 0
fi

# ── git / pre-commit hooks (default) ─────────────────────────────────────────
if command -v python3 >/dev/null 2>&1; then
  PYTHON=python3
elif command -v python >/dev/null 2>&1; then
  PYTHON=python
else
  echo "ERROR: python/python3 not found. Install Python 3.8+ first." >&2
  exit 1
fi

echo "==> Installing pre-commit..."
$PYTHON -m pip install pre-commit --quiet

echo "==> Installing git hooks..."
$PYTHON -m pre_commit install
$PYTHON -m pre_commit install --hook-type pre-push
$PYTHON -m pre_commit install --hook-type commit-msg

echo "==> Done. Run '$PYTHON -m pre_commit run --all-files' to validate all hooks now."

# Advisory only (no mutation): show the current guardrail mode if node is present.
if command -v node >/dev/null 2>&1 && [ -f "$GUARDRAIL_BLOCK" ]; then
  echo "==> guardrail mode: $(node "$GUARDRAIL_BLOCK" status 2>/dev/null || echo 'unknown')"
  echo "    Toggle with: bash scripts/setup-hooks.sh --guardrail-mode global|project [--yes]"
fi
