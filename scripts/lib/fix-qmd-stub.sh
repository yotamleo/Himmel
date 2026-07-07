#!/usr/bin/env bash
# scripts/lib/fix-qmd-stub.sh — neutralize the broken qmd plugin-cache stub
# at source (HIMMEL-163).
#
# The qmd Claude plugin ships a path stub at
# ~/.claude/plugins/cache/qmd/qmd/<v>/bin/qmd that hard-codes the plugin's
# own dist/cli/qmd.js. That dist tree is never built in the plugin cache
# (qmd is installed via bun — project rule: bun, never npm), and Claude
# Code's Bash tool prepends every plugin's bin/ to PATH, so the broken stub
# shadows the working install: plain `qmd` fails ONLY inside Claude's Bash
# tool. scripts/lib/qmd-bin.sh works around this per call site; this script
# fixes the stub itself, so plain `qmd` works everywhere (skills, runbooks,
# ad-hoc calls) without resolver adoption.
#
# It rewrites each broken stub to locate any installed qmd (the ticket's
# upstream ask, applied locally until the upstream plugin ships it):
#   1. plugin-local dist/cli/qmd.js — upstream layout, original dispatch kept
#   2. bun global install (honors BUN_INSTALL)
#   3. next `qmd` on PATH outside the plugin cache (npm installs)
# The original stub is preserved as bin/qmd.orig. Idempotent: already-patched
# stubs and healthy stubs (dist present) are left alone, so the script
# auto-no-ops once the upstream fix lands. A plugin update creates a new
# <version>/ dir with a fresh broken stub — re-run on setup
# (scripts/setup.sh, scripts/setup.ps1, scripts/machine-setup/ubuntu.sh all
# invoke this) or standalone.
#
# Intended semantics for ambiguous states (HIMMEL-163 CR round 1):
#   - A marker-less stub without dist/ is ALWAYS rewritten — including an
#     upstream stub that was itself fixed to dispatch elsewhere WITHOUT
#     shipping dist/. That is by design: the original is preserved as
#     qmd.orig, and the patched stub's bun-global/PATH fallbacks subsume any
#     dist-less upstream fix, so nothing is lost functionally.
#   - If qmd.orig already exists and the current stub differs from it
#     (upstream rewrote the stub in the same version dir), the OLDER backup
#     is kept and a note is printed; the rewritten stub is not separately
#     preserved.
#   - A stub carrying the patch marker but missing the trailing `exit 127`
#     sentinel is a corrupted/truncated patch: it is rewritten (and never
#     backed up over qmd.orig).
#
# Usage: bash scripts/lib/fix-qmd-stub.sh [--cache-root PATH] [--dry-run]
#   --cache-root PATH  Plugin cache root (default: ~/.claude/plugins/cache).
#   --dry-run          Report what would change; touch nothing.
# Exit: 0 = done (including nothing to do), 1 = usage error, unreadable
# cache root, or write failure.
set -uo pipefail

CACHE_ROOT="$HOME/.claude/plugins/cache"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: bash scripts/lib/fix-qmd-stub.sh [--cache-root PATH] [--dry-run]

Rewrites broken qmd plugin-cache stubs (bin/qmd referencing a missing
dist/cli/qmd.js) to locate any installed qmd: plugin dist, bun global
install, or the next qmd on PATH. Idempotent; originals kept as qmd.orig.

Optional:
  --cache-root PATH  Plugin cache root. Default: ~/.claude/plugins/cache.
  --dry-run          Report what would change; touch nothing.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --cache-root)
      [ -n "${2:-}" ] || { echo "ERR fix-qmd-stub: --cache-root needs a path" >&2; exit 1; }
      CACHE_ROOT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERR fix-qmd-stub: unknown arg: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# Patched stub body. POSIX sh, self-contained (it lives outside the repo, so
# it cannot source qmd-bin.sh). Resolution order mirrors qmd-bin.sh; the
# `himmel-qmd-stub-patch` marker is the idempotency key checked below.
# Written atomically: heredoc into a sibling temp file, chmod, then mv -f —
# a truncated write can never leave a half-written live stub whose marker
# (line 2) would read as "already patched" forever.
write_patched_stub() {
  local tmp="$1.tmp.$$"
  if ! cat > "$tmp" <<'STUB'
#!/bin/sh
# himmel-qmd-stub-patch: v1 — written by himmel scripts/lib/fix-qmd-stub.sh
# (HIMMEL-163). The upstream stub hard-codes "$DIR/dist/cli/qmd.js", which is
# never built in the Claude plugin cache (qmd is installed via bun), yet
# Claude Code's Bash tool puts this bin/ first on PATH — so the broken stub
# shadowed the working install. This stub locates any installed qmd instead.
# Original stub preserved alongside as qmd.orig.

# Resolve symlinks so the package directory is found from the real location.
SOURCE="$0"
while [ -L "$SOURCE" ]; do
  SOURCE_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  TARGET="$(readlink "$SOURCE")"
  case "$TARGET" in
    /*) SOURCE="$TARGET" ;;
    *) SOURCE="$SOURCE_DIR/$TARGET" ;;
  esac
done
BIN_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
DIR="$(cd -P "$BIN_DIR/.." && pwd)"

# MCP stdio reserves stdout for JSON-RPC frames; quiet native llama/ggml logs
# before the CLI loads. Kept from the upstream stub.
if [ "${1:-}" = "mcp" ]; then
  export LLAMA_LOG_LEVEL="${LLAMA_LOG_LEVEL:-error}"
  export GGML_LOG_LEVEL="${GGML_LOG_LEVEL:-error}"
  export GGML_BACKEND_SILENT="${GGML_BACKEND_SILENT:-1}"
fi

# 1. Plugin-local dist (upstream layout / source build): original dispatch,
#    lockfile-detected runtime to avoid native-module ABI mismatches.
if [ -f "$DIR/dist/cli/qmd.js" ]; then
  if [ -f "$DIR/package-lock.json" ]; then
    exec node "$DIR/dist/cli/qmd.js" "$@"
  elif [ -f "$DIR/bun.lock" ] || [ -f "$DIR/bun.lockb" ]; then
    exec bun "$DIR/dist/cli/qmd.js" "$@"
  fi
  exec node "$DIR/dist/cli/qmd.js" "$@"
fi

# 2. bun global install (project rule: qmd installs via bun). Honors
#    BUN_INSTALL for relocated bun roots, matching scripts/lib/qmd-bin.sh.
#    A bun-global qmd.js WITHOUT a bun binary is surfaced, not swallowed.
BUN_QMD_JS="${BUN_INSTALL:-$HOME/.bun}/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js"
BUN_QMD_NO_BUN=0
if [ -f "$BUN_QMD_JS" ]; then
  if command -v bun >/dev/null 2>&1; then
    exec bun "$BUN_QMD_JS" "$@"
  fi
  echo "qmd stub: bun-global qmd found at $BUN_QMD_JS but 'bun' is not on PATH; trying the next fallback." >&2
  BUN_QMD_NO_BUN=1
fi

# 3. Next `qmd` on PATH outside the Claude plugin cache (npm installs).
#    Skip this stub's own directory (and any sibling plugin-cache version)
#    to avoid exec recursion.
IFS=:
for _dir in $PATH; do
  [ -n "$_dir" ] || continue
  case "$_dir" in */plugins/cache/qmd/*) continue ;; esac
  _cand="$_dir/qmd"
  [ -f "$_cand" ] && [ -x "$_cand" ] || continue
  # Structural recursion guard, independent of the path segment above: a
  # cache relocated via --cache-root has no plugins/cache segment, and two
  # patched sibling version dirs on PATH would exec each other forever
  # (the BIN_DIR self-compare below only skips this stub's OWN dir). Never
  # exec another himmel-patched stub.
  if grep -q 'himmel-qmd-stub-patch' "$_cand" 2>/dev/null; then continue; fi
  _cand_dir="$(cd -P "$_dir" 2>/dev/null && pwd)" || continue
  [ "$_cand_dir" = "$BIN_DIR" ] && continue
  exec "$_cand" "$@"
done
unset IFS

if [ "$BUN_QMD_NO_BUN" -eq 1 ]; then
  echo "qmd: not found (plugin dist missing; bun-global qmd present but bun is not on PATH; nothing else on PATH)." >&2
else
  echo "qmd: not found (plugin dist missing; no bun global install; nothing else on PATH)." >&2
fi
echo "Install: bun add -g @tobilu/qmd@latest" >&2
exit 127
STUB
  then
    rm -f -- "$tmp"
    return 1
  fi
  if ! chmod +x "$tmp" || ! mv -f -- "$tmp" "$1"; then
    rm -f -- "$tmp"
    return 1
  fi
}

shopt -s nullglob
stubs=("$CACHE_ROOT"/qmd/qmd/*/bin/qmd)
shopt -u nullglob

if [ ${#stubs[@]} -eq 0 ]; then
  # Distinguish "cache root absent" (clean no-op) from "present but
  # unreadable/untraversable" (the glob silently expands empty either way)
  # — the latter must not masquerade as success. Check each intermediate
  # level too: a readable root with an unreadable qmd/ or qmd/qmd/ below it
  # empties the glob exactly the same way.
  for lvl in "$CACHE_ROOT" "$CACHE_ROOT/qmd" "$CACHE_ROOT/qmd/qmd"; do
    if [ -e "$lvl" ] && { [ ! -r "$lvl" ] || [ ! -x "$lvl" ]; }; then
      echo "ERR fix-qmd-stub: cache path exists but is not readable/traversable: $lvl" >&2
      exit 1
    fi
  done
  echo "fix-qmd-stub: no qmd plugin stubs under $CACHE_ROOT — nothing to do"
  exit 0
fi

patched=0 healthy=0 already=0 failed=0
for stub in "${stubs[@]}"; do
  verdir="$(cd "$(dirname "$stub")/.." && pwd)"
  corrupt=0
  # Distinguish rc=2 (unreadable stub) from rc=1 (no marker): an unreadable
  # stub must not silently flow into the patch path and fail later with a
  # misleading "backup failed" error.
  _grep_rc=0
  grep -q 'himmel-qmd-stub-patch' "$stub" 2>/dev/null || _grep_rc=$?
  if [ "$_grep_rc" -eq 2 ]; then
    echo "  ERR fix-qmd-stub: stub unreadable (permissions?): $stub" >&2
    failed=$((failed+1)); continue
  fi
  if [ "$_grep_rc" -eq 0 ]; then
    # Marker alone isn't proof of a whole patch (it sits on line 2): also
    # require the trailing `exit 127` sentinel. Marker without sentinel =
    # truncated/corrupted patch — re-patch instead of trusting it forever.
    if grep -q '^exit 127$' "$stub"; then
      echo "  already patched: $stub"
      already=$((already+1)); continue
    fi
    corrupt=1
    echo "  corrupted patch (marker without exit-127 sentinel) — re-patching: $stub"
  fi
  if [ "$corrupt" -eq 0 ] && [ -f "$verdir/dist/cli/qmd.js" ]; then
    echo "  healthy (dist present — upstream stub works): $stub"
    healthy=$((healthy+1)); continue
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  DRY would patch: $stub"
    patched=$((patched+1)); continue
  fi
  # Backup only marker-less stubs (a corrupted patch is not an original).
  if [ "$corrupt" -eq 0 ]; then
    if [ ! -f "$stub.orig" ]; then
      if ! cp -- "$stub" "$stub.orig"; then
        echo "  ERR fix-qmd-stub: backup failed: $stub" >&2
        failed=$((failed+1)); continue
      fi
    elif ! cmp -s -- "$stub" "$stub.orig"; then
      echo "  note: $stub differs from existing $stub.orig (upstream rewrote the stub in this version dir?); keeping the existing backup — the current stub content is NOT preserved"
    fi
  fi
  if write_patched_stub "$stub"; then
    echo "  patched: $stub (original at $stub.orig)"
    patched=$((patched+1))
  else
    echo "  ERR fix-qmd-stub: write failed: $stub" >&2
    failed=$((failed+1))
  fi
done

echo "fix-qmd-stub: patched=$patched healthy=$healthy already-patched=$already failed=$failed"
[ "$failed" -eq 0 ]
