# shellcheck shell=bash
# scripts/lib/qmd-bin.sh
#
# Resolver for the qmd CLI. qmd ships as a Claude plugin (path stub at
# ~/.claude/plugins/cache/qmd/qmd/<v>/bin/qmd) AND as a bun-installed
# binary (~/.bun/install/global/...). On Windows the plugin stub
# references a missing dist/cli/qmd.js and shadows the bun shim on
# Git Bash $PATH, so plain `qmd` fails with:
#   error: Module not found "...claude/plugins/cache/qmd/.../dist/cli/qmd.js"
# Real Git Bash terminals resolve qmd correctly; only Claude Code's
# Bash tool sees the broken plugin-cache PATH prepend. This helper
# picks the working invoker by preferring the canonical bun install
# when present, honoring BUN_INSTALL for relocated bun roots.
#
# scripts/lib/fix-qmd-stub.sh patches the broken plugin-cache stub at
# source (HIMMEL-163), which fixes plain `qmd` for call sites that don't
# source this lib; this resolver stays as the consumer-side path until
# the upstream plugin fix is pulled.
#
# Project rule: qmd is installed via bun, never npm. Bash callers get
# the install hint via qmd_install_hint() (single source of truth for
# bash); qmd_install() runs that hint, verifies the binary actually
# works, and heals a missing better-sqlite3 native build (HIMMEL-752:
# the old --ignore-scripts hint blocked better-sqlite3's native build
# and crashed qmd on platforms without a prebuilt binary, so the hint
# no longer carries it). qmd_register_collection() is the shared
# idempotent collection-registration helper used by setup.sh + adopt.sh.
# The pwsh mirrors in scripts/setup.ps1 + scripts/adopt.ps1, and the
# bash stub-error hint line in scripts/lib/fix-qmd-stub.sh, hardcode
# the same string and must be updated in lockstep.

qmd_install_hint() {
  echo 'bun add -g @tobilu/qmd@latest'
}

# Install qmd via the canonical hint, then verify the binary actually
# runs. Returns an honest rc: 0 ONLY when `qmd_cmd --version` succeeds.
# HIMMEL-752: the old `--ignore-scripts` hint blocked better-sqlite3's
# native build (its install script is `prebuild-install || node-gyp
# rebuild --release`), so on machines with no prebuilt binary (fresh
# macOS arm64 / new node major) every qmd command died with "Could not
# locate the bindings file". The hint now runs the full install; if the
# postinstall was skipped (bun does this for untrusted packages) or a
# prebuild is missing, fall back to a node-gyp build-release inside the
# better-sqlite3 dir, then re-verify. WARN-not-fail by contract: the
# rc is honest, callers (adopt.sh, ubuntu.sh) decide whether
# a qmd failure aborts. Every external command is under an `if` guard so
# a caller's `set -e` cannot abort mid-install before the rc is returned.
qmd_install() {
  local bun_root _bsqlite
  echo "Installing qmd via bun..."
  # Run the canonical hint command (single source of truth; a trusted
  # hardcoded literal, so eval is safe here - never feed it untrusted input).
  if ! eval "$(qmd_install_hint)"; then
    echo "  bun add failed - qmd not installed." >&2
    return 1
  fi
  # Verify the binary actually runs. has_qmd is presence-only by design,
  # so probe --version directly: a broken better-sqlite3 native build
  # (missing bindings file) dies here even though the package is present.
  if qmd_cmd --version >/dev/null 2>&1; then
    echo "  qmd installed and verified."
    return 0
  fi
  # Heal: bun may skip the postinstall for untrusted packages, and the
  # better-sqlite3 prebuild may be missing on a new platform. Build the
  # native module in place, then re-verify (HIMMEL-752).
  bun_root="${BUN_INSTALL:-$HOME/.bun}"
  _bsqlite="$bun_root/install/global/node_modules/better-sqlite3"
  if [ -d "$_bsqlite" ]; then
    echo "  qmd present but --version failed - rebuilding better-sqlite3 native module..."
    if (cd "$_bsqlite" && npm run build-release) >/dev/null 2>&1; then
      if qmd_cmd --version >/dev/null 2>&1; then
        echo "  qmd verified after native rebuild."
        return 0
      fi
      echo "  WARNING: native rebuild ran but qmd --version still fails." >&2
    else
      echo "  WARNING: better-sqlite3 native build failed (need a compiler toolchain?)." >&2
    fi
  else
    echo "  WARNING: better-sqlite3 not found at $_bsqlite - cannot heal." >&2
  fi
  return 1
}

# Register a directory as a qmd collection. Idempotent: skips when
# <name> is already listed. WARN-not-fail: a list/add error prints a
# WARNING (with the indented payload on a list failure, and the rc=127
# resolver hint on an add-127) and returns the nonzero rc, but the
# CALLER decides whether to abort (setup.sh wraps with `|| true`;
# adopt.sh treats qmd as best-effort). $1 = path, $2 = name.
qmd_register_collection() {
  local path="$1" name="$2" list_out list_rc add_rc
  list_out=$(qmd_cmd collection list 2>&1)
  list_rc=$?
  if [ "$list_rc" -ne 0 ]; then
    echo "  WARNING: qmd collection list failed (rc=$list_rc) - skipping '$name' registration." >&2
    # shellcheck disable=SC2001
    # Per-line indent - parameter expansion doesn't replicate sed's per-line anchor cleanly.
    echo "$list_out" | sed 's/^/    /' >&2
    return "$list_rc"
  fi
  # Idempotency check: skip when <name> is already a registered collection.
  if echo "$list_out" | grep -q "^${name}\b"; then
    echo "  Collection '$name' already registered - skipping."
    return 0
  fi
  qmd_cmd collection add "$path" --name "$name"
  add_rc=$?
  if [ "$add_rc" -ne 0 ]; then
    echo "  WARNING: qmd collection add '$name' failed (rc=$add_rc) - continuing." >&2
    if [ "$add_rc" -eq 127 ]; then
      echo "  (rc=127 means scripts/lib/qmd-bin.sh resolver could not find qmd - install: $(qmd_install_hint))" >&2
    fi
    return "$add_rc"
  fi
  return 0
}

# Resolve bun-direct qmd.js path. Respects BUN_INSTALL (bun's own override)
# so non-default global installs at /opt/bun etc. are picked up.
_qmd_bun_js() {
  local bun_root="${BUN_INSTALL:-$HOME/.bun}"
  echo "$bun_root/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js"
}

qmd_cmd() {
  local bun_qmd
  bun_qmd="$(_qmd_bun_js)"
  if [ -f "$bun_qmd" ] && command -v bun >/dev/null 2>&1; then
    bun "$bun_qmd" "$@"
  elif command -v qmd >/dev/null 2>&1; then
    qmd "$@"
  else
    return 127
  fi
}

# Presence check ONLY — does not invoke the binary, so real runtime errors
# (corrupt better-sqlite3 prebuild, broken cache) reach the caller instead
# of being masked as "qmd not installed".
has_qmd() {
  local bun_qmd
  bun_qmd="$(_qmd_bun_js)"
  if [ -f "$bun_qmd" ] && command -v bun >/dev/null 2>&1; then
    return 0
  fi
  command -v qmd >/dev/null 2>&1
}
