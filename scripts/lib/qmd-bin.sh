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
# HIMMEL-877: qmd installs from the himmel FORK (yotamleo/qmd), never
# upstream `bun add -g @tobilu/qmd` -- that command EPERM-wedges on this
# project's machines (zombie `qmd mcp` stdio node processes hold locks) and
# bun blocks the postinstall script. The proven recipe (done by hand on the
# primary machine, now automated here): clone the fork to a stable dir,
# `bun install && bun run build` in the clone, then a directory junction
# (Windows) / symlink (POSIX) at ~/.bun/install/global/node_modules/@tobilu/qmd
# pointing at the clone -- bun's stock global shims then transparently serve
# the fork from the same path every other consumer (qmd_cmd, has_qmd, the
# fix-qmd-stub patched stub) already resolves. qmd_install() is idempotent:
# it detects an already-fork-served install (global path already links to
# the fork clone AND the clone's HEAD is the pinned commit AND `qmd
# --version` reports >= QMD_FORK_MIN_VERSION) and skips.
#
# PIN (HIMMEL-911): the install ref is a FULL COMMIT SHA on the fork --
# not the himmel-main branch. himmel-main is a MUTABLE tracking branch
# (where upstream merges land); a force-push there would silently change
# what every future `qmd-bin.sh install` runs, with no reviewed repo change
# -- a supply-chain trust boundary on new-machine bootstrap (mirrors the
# HIMMEL-891 graphify precedent, scripts/lib/graphify-bin.sh). The commit
# SHA is the only content-addressed, unmovable ref. The fork tag
# v2.6.3-himmel.1 points at this same commit as human-readable release
# provenance; a pin bump is a reviewed change to this file. Fork
# repo/ref/clone-dir are overridable via QMD_FORK_REPO / QMD_FORK_REF /
# QMD_FORK_DIR for testing or a private mirror.
# qmd_register_collection() is the shared idempotent collection-
# registration helper used by setup.sh + adopt.sh. Executed directly
# (not sourced), this file also answers `install` on argv (see the CLI
# entry at the bottom) so the pwsh mirrors (scripts/setup.ps1,
# scripts/adopt.ps1) can delegate to this ONE implementation instead of
# duplicating the clone/build/link recipe natively.

# Fork config -- overridable per call (env var set before sourcing/calling).
_qmd_fork_repo() { printf '%s\n' "${QMD_FORK_REPO:-https://github.com/yotamleo/qmd.git}"; }
# = v2.6.3-himmel.1
_qmd_fork_ref() { printf '%s\n' "${QMD_FORK_REF:-1032a648447a54eb73df138a3861dd7a9a64c595}"; }
_qmd_fork_dir() { printf '%s\n' "${QMD_FORK_DIR:-$HOME/.himmel/qmd-fork}"; }
_qmd_fork_min_version() { printf '%s\n' "${QMD_FORK_MIN_VERSION:-2.6.3}"; }
# Build-success stamp INSIDE the clone (HIMMEL-911 CR r3): one file, no
# schema -- its content is the exact pinned SHA the artifacts were BUILT
# from. Written only after build + link + version verification all succeed;
# cleared at the start of any update attempt. HEAD alone cannot distinguish
# "checked out the pin" from "successfully BUILT the pin".
_qmd_build_stamp() { printf '%s\n' "$(_qmd_fork_dir)/.himmel-build-ok"; }

# Prints the manual recipe (clone + build + link). Best-effort documentation
# text embedded in WARN messages -- NOT eval'd (HIMMEL-877 dropped the old
# single-command `bun add -g @tobilu/qmd@latest` eval path; qmd_install()
# below runs the multi-step recipe directly).
qmd_install_hint() {
  local fork_dir ref global_dir
  fork_dir="$(_qmd_fork_dir)"
  ref="$(_qmd_fork_ref)"
  global_dir="$(_qmd_global_dir)"
  printf '%s\n' \
    "git clone $(_qmd_fork_repo) $fork_dir" \
    "(cd $fork_dir && git fetch origin $ref && git checkout $ref && bun install && bun run build)" \
    "link $fork_dir over $global_dir (Windows: mklink /J; POSIX: ln -s) -- or re-run qmd_install"
}

# True on Git Bash / MSYS / Cygwin.
_qmd_is_windows() {
  case "$(uname -s 2>/dev/null || echo)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

# Windows-native absolute path for a POSIX path, for native tools (mklink,
# fsutil) invoked via cmd. Falls back to the input unchanged when cygpath is
# unavailable.
_qmd_win_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w -- "$1" 2>/dev/null || printf '%s\n' "$1"
  else
    printf '%s\n' "$1"
  fi
}

# Canonical form of an EXISTING directory, comparable across a Windows
# junction traversal: `cd + pwd -P` resolves the reparse point, but MSYS can
# print the result through a different mount-table alias than a direct `cd`
# to the same real location (e.g. .../AppData/Local/Temp/... resolving as
# /tmp/... through a junction but /c/Users/.../Temp/... directly) -- the two
# forms are NOT string-equal even though they name the same directory.
# cygpath -w normalizes both back to one Windows path, which is alias-free.
# POSIX has no such aliasing, so plain `pwd -P` is enough there.
_qmd_canonical_dir() {
  local real
  real="$(cd -- "$1" 2>/dev/null && pwd -P)" || return 1
  [ -n "$real" ] || return 1
  if _qmd_is_windows; then
    _qmd_win_path "$real"
  else
    printf '%s\n' "$real"
  fi
}

# True if the bun-global @tobilu/qmd path already resolves to the fork clone
# dir (both must exist). The core of qmd_install()'s idempotency check.
_qmd_global_points_to_fork() {
  local global_dir fork_dir g f
  global_dir="$(_qmd_global_dir)"
  fork_dir="$(_qmd_fork_dir)"
  [ -d "$global_dir" ] || return 1
  [ -d "$fork_dir" ] || return 1
  g="$(_qmd_canonical_dir "$global_dir")" || return 1
  f="$(_qmd_canonical_dir "$fork_dir")" || return 1
  [ -n "$g" ] && [ "$g" = "$f" ]
}

# $1 >= $2 for dotted version strings (e.g. "2.6.3" >= "2.6.3"). $1 may carry
# a prefix/suffix (e.g. "qmd 2.6.10 (himmel-main)") -- the first x.y.z run is
# extracted. bash-3.2-safe (no arrays, no [[ =~ ]] version-compare builtin).
_qmd_version_ge() {
  local actual min a1 a2 a3 m1 m2 m3 _save_ifs
  actual="$(printf '%s' "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
  [ -n "$actual" ] || return 1
  min="$2"
  _save_ifs="$IFS"
  IFS=.
  # shellcheck disable=SC2086
  # Unquoted on purpose: IFS=. splits the dotted version into 3 fields.
  set -- $actual
  a1="$1"; a2="$2"; a3="$3"
  # shellcheck disable=SC2086
  set -- $min
  m1="$1"; m2="$2"; m3="$3"
  IFS="$_save_ifs"
  [ "$a1" -gt "$m1" ] 2>/dev/null && return 0
  [ "$a1" -lt "$m1" ] 2>/dev/null && return 1
  [ "$a2" -gt "$m2" ] 2>/dev/null && return 0
  [ "$a2" -lt "$m2" ] 2>/dev/null && return 1
  [ "$a3" -ge "$m3" ] 2>/dev/null
}

# True if $1 is a symlink (POSIX) or a Windows directory junction / reparse
# point. Read-only probe -- never mutates.
_qmd_is_link() {
  [ -L "$1" ] && return 0
  if _qmd_is_windows && [ -d "$1" ]; then
    MSYS_NO_PATHCONV=1 fsutil reparsepoint query "$(_qmd_win_path "$1")" >/dev/null 2>&1
    return $?
  fi
  return 1
}

# Remove a CONFIRMED link, never the directory it points at: Windows'
# native rmdir on a junction deletes only the reparse point (verified --
# the target's contents survive); `rm -f` on a POSIX symlink is likewise
# link-only. Never call this on a real (non-link) directory. On failure the
# tool's output is captured in _QMD_LINK_ERR for the caller's ERROR message
# (CR: >/dev/null swallowed the actionable rmdir/mklink diagnostics).
_qmd_remove_link() {
  if _qmd_is_windows; then
    _QMD_LINK_ERR=$(MSYS_NO_PATHCONV=1 cmd /c rmdir "$(_qmd_win_path "$1")" 2>&1)
  else
    _QMD_LINK_ERR=$(rm -f -- "$1" 2>&1)
  fi
}

# Create a directory junction ($2 -> $1 on Windows) or a symlink (POSIX).
# $1 = target (the fork clone), $2 = link path (the bun-global @tobilu/qmd
# dir). On failure the tool's output is captured in _QMD_LINK_ERR.
_qmd_link() {
  if _qmd_is_windows; then
    _QMD_LINK_ERR=$(MSYS_NO_PATHCONV=1 cmd /c mklink /J "$(_qmd_win_path "$2")" "$(_qmd_win_path "$1")" 2>&1)
  else
    _QMD_LINK_ERR=$(ln -s -- "$1" "$2" 2>&1)
  fi
}

# Deterministic backup name for an existing REAL directory at $1: never a
# timestamp (non-reproducible, hard to assert on in tests) -- a fixed
# `.pre-fork-backup` suffix, numbered on collision from a prior aborted run.
_qmd_backup_name() {
  local base="$1.pre-fork-backup" n
  if [ ! -e "$base" ]; then
    printf '%s\n' "$base"
    return 0
  fi
  n=1
  while [ -e "$base.$n" ]; do
    n=$((n + 1))
  done
  printf '%s\n' "$base.$n"
}

# Point the bun-global @tobilu/qmd path at the fork clone. Idempotent
# (no-ops if already correct). A stale link (wrong target) is removed
# outright (link-only, safe); a REAL pre-existing directory is moved aside
# under a deterministic backup name first -- it is NEVER deleted, and on a
# link failure it is RESTORED (CR rollback: the failure mode this recipe
# exists for -- a locked path held by zombie `qmd mcp` processes -- must
# not leave the global path ABSENT with the old install stranded in the
# backup dir).
_qmd_ensure_global_link() {
  local fork_dir global_dir global_parent backup=""
  fork_dir="$(_qmd_fork_dir)"
  global_dir="$(_qmd_global_dir)"
  global_parent="$(dirname -- "$global_dir")"

  if _qmd_global_points_to_fork; then
    return 0
  fi

  # Surface a parent-dir mkdir failure as the root cause instead of the
  # generic link error it would otherwise cascade into (CR).
  if ! mkdir -p -- "$global_parent" 2>/dev/null; then
    echo "  ERROR: could not create $global_parent (permissions?) - cannot link the fork." >&2
    return 1
  fi

  if [ -e "$global_dir" ] || [ -L "$global_dir" ]; then
    if _qmd_is_link "$global_dir"; then
      echo "  Removing stale link at $global_dir..."
      if ! _qmd_remove_link "$global_dir"; then
        echo "  ERROR: could not remove stale link at $global_dir${_QMD_LINK_ERR:+: $_QMD_LINK_ERR}" >&2
        return 1
      fi
    else
      backup="$(_qmd_backup_name "$global_dir")"
      echo "  Existing real directory at $global_dir - moving aside to $backup" >&2
      if ! mv -- "$global_dir" "$backup"; then
        echo "  ERROR: could not move aside existing $global_dir" >&2
        return 1
      fi
    fi
  fi

  if ! _qmd_link "$fork_dir" "$global_dir"; then
    echo "  ERROR: failed to link $global_dir -> $fork_dir${_QMD_LINK_ERR:+: $_QMD_LINK_ERR}" >&2
    # Rollback: put the moved-aside directory back so the machine is no
    # worse off than before this attempt (the old install keeps resolving).
    if [ -n "$backup" ]; then
      if mv -- "$backup" "$global_dir"; then
        echo "  Restored the previous directory at $global_dir (no change applied)." >&2
      else
        echo "  ERROR: restore ALSO failed - your previous install is stranded at:" >&2
        echo "         $backup" >&2
        echo "         move it back by hand to: $global_dir" >&2
      fi
    fi
    return 1
  fi
  if [ -n "$backup" ]; then
    echo "  Note: previous @tobilu/qmd install preserved at $backup - remove it once the fork install is confirmed."
  fi
  return 0
}

# True when the fork is already the SERVED install: the bun-global
# @tobilu/qmd path resolves to the fork clone AND the clone's HEAD is the
# pinned commit AND the build-success stamp records that exact pin AND the
# version probe reports >= QMD_FORK_MIN_VERSION. This
# is the caller-side install gate (HIMMEL-877 CR codex-adv-1): callers must
# gate qmd_install on THIS, never on presence (has_qmd) -- a machine carrying
# the old upstream bun-global install (the exact population this change
# migrates) is qmd-PRESENT but not fork-served, and a presence gate would
# skip the migration entirely. Also exposed as the `fork-served` CLI verb so
# the pwsh mirrors share the same predicate.
qmd_fork_served() {
  local ver head stamp
  _qmd_global_points_to_fork || return 1
  # HIMMEL-911 CR r1 codex-adv-1: link-target + version alone would bless an
  # existing clean install built from the mutable himmel-main branch head --
  # exactly the population the pin migrates -- and qmd_install would skip it
  # forever. The clone's resolved HEAD must BE the pinned commit. Guarded:
  # any git failure = not-served. Cheap + local-only (rev-parse of HEAD
  # never touches the network).
  head="$(git -C "$(_qmd_fork_dir)" rev-parse HEAD 2>/dev/null)" || return 1
  [ "$head" = "$(_qmd_fork_ref)" ] || return 1
  # HIMMEL-911 CR r3 codex-adv: HEAD==pin is necessary but NOT sufficient --
  # a drifted upgrade moves HEAD to the pin BEFORE bun runs, so a build
  # failure would leave HEAD==pin while the OLD dist (built from the mutable
  # commit) keeps serving, and every retry would skip here forever. The
  # served artifacts must carry the build-success stamp for this exact pin.
  # Legacy installs without the stamp (pre-stamp machines) intentionally
  # read as not-served so they converge onto a stamped pinned build on the
  # next install pass.
  stamp="$(cat "$(_qmd_build_stamp)" 2>/dev/null)" || return 1
  [ "$stamp" = "$(_qmd_fork_ref)" ] || return 1
  ver="$(qmd_cmd --version 2>/dev/null)" || return 1
  _qmd_version_ge "$ver" "$(_qmd_fork_min_version)"
}

# Install/update the qmd fork and serve it from the bun-global @tobilu/qmd
# path (HIMMEL-877). Returns an honest rc: 0 ONLY when `qmd_cmd --version`
# verifiably succeeds afterward. WARN-not-fail by contract -- callers
# (adopt.sh/adopt.ps1, setup.sh/setup.ps1, ubuntu.sh) decide whether a qmd
# failure aborts. Every external command is under an `if`/`&&` guard so a
# caller's `set -e` cannot abort mid-install before the rc is returned.
#
# Idempotent: skips cleanly when qmd_fork_served (global path already links
# to the fork clone AND the clone's HEAD is the pinned commit AND the
# build-success stamp records that pin AND the version probe passes); still
# falls through to update+rebuild+re-link on a stale/older/pin-drifted or
# unstamped (failed/interrupted prior build) clone.
qmd_install() {
  local fork_dir ref repo global_dir origin_url

  fork_dir="$(_qmd_fork_dir)"
  ref="$(_qmd_fork_ref)"
  repo="$(_qmd_fork_repo)"
  global_dir="$(_qmd_global_dir)"

  if qmd_fork_served; then
    echo "  qmd fork already installed and served ($(qmd_cmd --version 2>/dev/null)) - skipping."
    return 0
  fi

  echo "Installing qmd fork ($repo@$ref)..."

  if ! command -v git >/dev/null 2>&1; then
    echo "  git not found - cannot clone the qmd fork." >&2
    return 1
  fi
  if ! command -v bun >/dev/null 2>&1; then
    echo "  bun not found - cannot build the qmd fork." >&2
    return 1
  fi

  if [ -d "$fork_dir/.git" ]; then
    # HIMMEL-877 CR codex-adv-2: never hard-reset a repo the installer does
    # not own. QMD_FORK_DIR is operator-overridable -- pointed at an
    # unrelated working repo, the fetch/checkout/reset below would DESTROY
    # its local changes. Refuse (WARN + nonzero, dir untouched) unless the
    # clone's origin matches QMD_FORK_REPO; refuse a dirty worktree too,
    # overridable only via QMD_FORK_FORCE=1.
    origin_url="$(git -C "$fork_dir" remote get-url origin 2>/dev/null)"
    if [ "$origin_url" != "$repo" ]; then
      echo "  WARNING: $fork_dir exists but its origin ('$origin_url') is not $repo - refusing to touch it." >&2
      echo "  Point QMD_FORK_DIR at a dedicated location, or fix the clone's origin remote." >&2
      return 1
    fi
    # HIMMEL-911 CR r3: clear the build-success stamp FIRST (ownership is
    # established by the origin check above) -- from here until the
    # post-verification stamp write this machine is NOT fork-served, so an
    # interrupted or failed upgrade can never be mistaken for served on a
    # retry. Also keeps our own untracked stamp file from tripping the
    # dirty-worktree probe below.
    rm -f -- "$(_qmd_build_stamp)"
    if [ -n "$(git -C "$fork_dir" status --porcelain 2>/dev/null)" ] && [ "${QMD_FORK_FORCE:-0}" != "1" ]; then
      echo "  WARNING: $fork_dir has uncommitted changes - refusing to hard-reset it." >&2
      echo "  Commit/stash them, or re-run with QMD_FORK_FORCE=1 to discard them." >&2
      return 1
    fi
    echo "  qmd fork clone exists at $fork_dir - updating to $ref..."
    # HIMMEL-911 CR r1 codex-adv-2: FAIL CLOSED. The old fallback (WARN +
    # build the clone contents as-is) silently served an UNPINNED commit
    # while reporting success -- the exact outcome the pin exists to prevent.
    # An already-served install stays untouched (nothing rebuilt/re-linked);
    # WARN-not-fail remains the CALLER's contract: qmd_install returns an
    # honest nonzero and the caller decides whether that aborts.
    if ! ( cd "$fork_dir" \
           && git fetch origin "$ref" \
           && git checkout "$ref" \
           && git reset --hard "$ref" ); then
      echo "  ERROR: could not update the qmd fork clone to pinned commit $ref - refusing to build/serve unpinned contents." >&2
      return 1
    fi
  else
    # HIMMEL-911 CR r2 codex-adv: never adopt an existing NON-git path.
    # QMD_FORK_DIR is operator-overridable, so a populated non-git directory
    # here is USER DATA that predates the installer -- `git init`ing it in
    # place and then `rm -rf`ing it on a clone failure would destroy it (the
    # origin-mismatch refusal above only protects dirs that already ARE git
    # repos). Refuse untouched; only a path THIS invocation creates is ever
    # cleaned up on failure.
    if [ -e "$fork_dir" ]; then
      echo "  WARNING: $fork_dir exists but is not a git clone - refusing to touch it." >&2
      echo "  Point QMD_FORK_DIR at a dedicated location, or remove the directory yourself." >&2
      return 1
    fi
    if ! mkdir -p -- "$(dirname -- "$fork_dir")"; then
      echo "  ERROR: could not create $(dirname -- "$fork_dir")" >&2
      return 1
    fi
    # A commit SHA cannot be passed to `git clone --branch` -- GitHub allows
    # fetching a reachable SHA directly, so init + fetch-by-sha + checkout is
    # the pinned-ref equivalent of a shallow branch clone (HIMMEL-911).
    if ! git init "$fork_dir" >/dev/null \
         || ! git -C "$fork_dir" remote add origin "$repo" \
         || ! git -C "$fork_dir" fetch --depth 1 origin "$ref" \
         || ! git -C "$fork_dir" checkout "$ref"; then
      echo "  qmd fork clone failed." >&2
      # Safe by construction: the refusal above guarantees $fork_dir did not
      # exist before this invocation created it (never delete what we did
      # not create -- HIMMEL-911 CR r2).
      rm -rf -- "$fork_dir"
      return 1
    fi
  fi

  # Belt-and-braces (HIMMEL-911 CR r1 codex-adv-2): whichever path ran above,
  # the clone must actually BE at the pinned commit before anything is built
  # or served -- guards a partial checkout that still returned 0.
  if [ "$(git -C "$fork_dir" rev-parse HEAD 2>/dev/null)" != "$ref" ]; then
    echo "  ERROR: $fork_dir HEAD is not the pinned commit $ref - refusing to build/serve it." >&2
    return 1
  fi

  echo "  Building qmd fork (bun install && bun run build)..."
  if ! ( cd "$fork_dir" && bun install && bun run build ); then
    echo "  WARNING: qmd fork build failed - continuing without qmd." >&2
    echo "  Manual: (cd $fork_dir && bun install && bun run build)" >&2
    return 1
  fi

  if ! _qmd_ensure_global_link; then
    echo "  WARNING: qmd fork built but could not be linked at $global_dir." >&2
    return 1
  fi

  if qmd_cmd --version >/dev/null 2>&1; then
    # HIMMEL-911 CR r3: stamp build success only NOW -- build + link +
    # version verification all passed, so the served artifacts really were
    # built from the pinned commit. An unwritable stamp keeps the install
    # honestly not-served (nonzero) instead of silently unstamped.
    if ! printf '%s\n' "$ref" > "$(_qmd_build_stamp)" 2>/dev/null; then
      echo "  WARNING: qmd fork verified but the build stamp could not be written." >&2
      return 1
    fi
    echo "  qmd fork installed and verified ($(qmd_cmd --version 2>/dev/null))."
    return 0
  fi
  echo "  WARNING: qmd fork installed but --version still fails." >&2
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

# Resolve the bun-global @tobilu/qmd package DIRECTORY (parent of dist/cli/
# qmd.js above) -- this is the path qmd_install() junctions/symlinks onto
# the fork clone so bun's stock global shims serve it.
_qmd_global_dir() {
  local bun_root="${BUN_INSTALL:-$HOME/.bun}"
  echo "$bun_root/install/global/node_modules/@tobilu/qmd"
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

# True (rc 0) iff `qmd collection list` succeeds and lists at least one
# collection (HIMMEL-756 T1.4: the himmelctl `qmd-index` probe's presence
# signal). qmd's actual on-disk data/index directory layout is an internal
# implementation detail with no stable path documented anywhere in this repo
# to probe directly (unlike the fork clone dir / bun-global link dir above,
# both of which ARE this resolver's own paths) — so this checks the
# registered-collections signal through qmd itself instead of guessing a
# filesystem location. Presence-only in the has_qmd sense: a real `qmd
# collection list` invocation runs (unlike has_qmd, which never invokes the
# binary), so a broken qmd surfaces here as absent rather than masked.
has_index() {
  local out
  out=$(qmd_cmd collection list 2>/dev/null) || return 1
  [ -n "$(printf '%s' "$out" | tr -d '[:space:]')" ]
}

# CLI entry -- only when EXECUTED (not sourced). Lets the pwsh mirrors
# (scripts/setup.ps1, scripts/adopt.ps1) delegate to this ONE
# implementation (`bash scripts/lib/qmd-bin.sh install`) instead of
# duplicating the fork clone/build/link recipe natively (HIMMEL-877).
if [ "${BASH_SOURCE[0]:-}" = "${0:-}" ]; then
  case "${1:-}" in
    install) qmd_install ;;
    # fork-served: rc 0 iff the fork is already the served install (the
    # caller-side install gate -- see qmd_fork_served above). Lets the pwsh
    # mirrors share the bash predicate instead of duplicating it.
    fork-served) qmd_fork_served ;;
    # has-index: rc 0 iff has_index (see above) -- lets probes.js (HIMMEL-756
    # T1.4) and any other non-bash consumer share the same predicate via a
    # single subprocess call instead of sourcing this file.
    has-index) has_index ;;
    *) echo "Usage: bash scripts/lib/qmd-bin.sh install|fork-served|has-index" >&2; exit 2 ;;
  esac
fi
