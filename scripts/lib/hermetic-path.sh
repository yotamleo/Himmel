# shellcheck shell=bash
# scripts/lib/hermetic-path.sh
#
# Shared hermetic-PATH helpers for test suites that invoke a target script
# under a PATH stripped of specific toolchain binaries (uv/pipx/node/npm/
# bun/qmd, ...) so the suite can observe the target's "tool absent" branches
# without depending on (or being confused by) the real dev machine's
# toolchain.
#
# HIMMEL-874 / HIMMEL-880: on stock Ubuntu, npm (and other scrubbed tools)
# lives in /usr/bin alongside bash and coreutils. Dropping every PATH dir
# that carries a scrubbed tool therefore drops /usr/bin wholesale, which
# takes bash itself down with it -- every subsequent
# `PATH="$scrubbed" bash "$target" ...` invocation then fails to resolve
# `bash` before running a single line of the target script. HIMMEL-874 fixed
# this for scripts/test-adopt.sh by pre-linking bash + the essential tools
# the target script needs into a hermetic stub dir BEFORE computing the
# scrub, then prepending that stub dir to the scrubbed PATH so those tools
# stay resolvable no matter which real dirs get dropped. HIMMEL-880 extracts
# that fix here so scripts/test-preflight-adopter.sh (which had the identical
# bug, added in the same HIMMEL-842 commit) can share it instead of
# re-diverging.
#
# FUNCTIONS ONLY -- sourcing this file has no side effects. Callers:
#
#   1. link_hermetic_tool <tool> [dest_dir]
#      Symlink <tool> (resolved via the CURRENT, un-scrubbed PATH) into
#      dest_dir (default: $work/bin -- callers must set $work, or pass an
#      explicit dest_dir). dest_dir must already exist (mkdir -p it)
#      before calling -- the function never creates it. Falls back to a
#      wrapper script that execs the real binary by absolute path if
#      `ln -s` fails (e.g. no symlink support), and to a plain copy for
#      `bash` specifically (a wrapper script needs a real bash on PATH to
#      exec via its own #!/usr/bin/env bash shebang, so a wrapper can't
#      bootstrap bash itself). Calls the caller's `fail "..."` (must be
#      defined by the sourcing script, matching each suite's own
#      diagnostic style) when the tool can't be found before the scrub OR
#      when a fallback itself fails (bash copy, wrapper write, chmod).
#
#   2. path_dir_has_scrubbed_tool <dir> <tool>...
#      True (rc 0) if <dir> carries any of the named tools (checked bare,
#      .exe, .cmd for Windows).
#
#   3. scrub_path <path> <tool>...
#      Returns <path> (colon-separated) with every dir carrying any named
#      tool dropped wholesale. Empty PATH segments (leading, trailing, or
#      mid-string "::") are ALWAYS dropped by design: an empty segment
#      means implicit-cwd search, which a hermetic test PATH must never do.
#
# Callers MUST link bash + whatever tools their target script needs into a
# stub dir BEFORE calling scrub_path, then prepend that stub dir ahead of the
# scrubbed PATH on every hermetic invocation.

link_hermetic_tool() {
  local _tool="$1" _dest="${2:-$work/bin}" _src
  _src=$(command -v "$_tool" 2>/dev/null) || fail "required test tool not found before PATH scrub: $_tool"
  case "$_src" in
    "$_dest/"*) return 0 ;;
  esac
  if ! ln -s "$_src" "$_dest/$_tool" 2>/dev/null; then
    # bash can't get a self-referential wrapper (the wrapper below execs via
    # #!/usr/bin/env bash, which needs a real bash on PATH). On symlink-
    # restricted shells, copy the binary instead of hard-failing the suite.
    if [ "$_tool" = "bash" ]; then
      cp "$_src" "$_dest/bash" || fail "could not copy bash into hermetic stub dir"
      chmod +x "$_dest/bash"
      return 0
    fi
    {
      printf '%s\n' '#!/usr/bin/env bash'
      printf 'exec "%s" "$@"\n' "$_src"
    } > "$_dest/$_tool" || fail "could not write hermetic wrapper for $_tool"
    chmod +x "$_dest/$_tool" || fail "could not chmod hermetic wrapper for $_tool"
  fi
}

path_dir_has_scrubbed_tool() {
  local _dir="$1"; shift
  local _tool
  for _tool in "$@"; do
    [ -x "$_dir/$_tool" ] && return 0
    [ -x "$_dir/$_tool.exe" ] && return 0
    [ -x "$_dir/$_tool.cmd" ] && return 0
  done
  return 1
}

scrub_path() {
  local _in="$1"; shift
  local _out="" _d _save_ifs2
  _save_ifs2="$IFS"; IFS=':'
  for _d in $_in; do
    [ -n "$_d" ] || continue
    path_dir_has_scrubbed_tool "$_d" "$@" && continue
    _out="${_out:+$_out:}$_d"
  done
  IFS="$_save_ifs2"
  printf '%s' "$_out"
}
