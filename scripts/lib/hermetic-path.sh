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
#
# USE build_hermetic_bin FOR THAT (HIMMEL-2535) -- it is the MUST above in one
# call. The rule was stated here and broken anyway, three times in one week
# (HIMMEL-2470 node, HIMMEL-2520 bun, HIMMEL-2530 uv/graphify), because a stub
# dir holding only the FAKED tool looks correct and is not. Per the
# enforcement-strength convention, that is the point where prose stops being
# the right layer:
#
#   stub="$work/bin"
#   build_hermetic_bin "$stub" sed grep mktemp     # bash is always included
#   hermetic_path="$stub:$(scrub_path "$PATH" node)"
#   hermetic_path_excludes "$hermetic_path" node || fail "node leaked in"
#
# And note the inverse mistake, which an allowlist does NOT protect you from on
# its own: never build the allowlist from a DIRECTORY. `dirname $(command -v
# sort)` is /usr/bin on Arch, which also ships bun/uv/node -- adopting it
# re-admits the very tool you are hiding (HIMMEL-2524). Name tools individually.

# Executable suffix for stub files (HIMMEL-1686). On Windows an EXTENSIONLESS
# file named `bash` in scope makes ShellExecute return SE_ERR_NOASSOC, which
# pops the "Select an app to open 'bash'" picker — a modal that blocks the box
# and, in an unattended cadence run, hangs it with nobody to dismiss it.
# Defined ONCE here and consumed by callers (test-adopt.sh) so the writer side
# cannot drift from the reader side in path_dir_has_scrubbed_tool below.
HERMETIC_EXE_SUFFIX=''
case "${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}" in
  msys*|cygwin*|win32*|MINGW*|MSYS*|CYGWIN*) HERMETIC_EXE_SUFFIX='.exe' ;;
esac

# Default `fail` for callers that do not define one (HIMMEL-2535).
#
# link_hermetic_tool and build_hermetic_bin below call the SOURCING script's
# `fail`, which several suites do not define -- test-graphify-bin.sh had none at
# all, so a missing prerequisite would have died with "fail: command not found"
# instead of the intended diagnostic. Defining a fallback here makes the safe
# shape work out of the box; a caller that defines its own `fail` (before or
# after sourcing) still wins, so this changes no existing suite's behaviour.
# Note `command -v` finds functions and commands, never a plain VARIABLE, so a
# suite that merely counts failures in a `fail` variable still gets this.
if ! command -v fail >/dev/null 2>&1; then
    fail() { printf 'hermetic-path: %s\n' "$*" >&2; exit 1; }
fi

link_hermetic_tool() {
  local _tool="$1" _dest="${2:-$work/bin}" _src _dest_name
  _dest_name="${_tool}${HERMETIC_EXE_SUFFIX}"
  # Idempotent on the COMPUTED name (HIMMEL-1686). Callers that re-link one stub
  # dir guard with their own `[ -e "$stub/$tool" ]` check keyed on the
  # UNSUFFIXED name (e.g. test-wizard-contributor-profile.sh's already_linked,
  # whose caseC runs the same stub dir through build_path twice). Once this
  # helper started writing `<dest>/<tool>.exe`, that caller guard stopped
  # matching on Windows, so a second pass fell through to the fallbacks below --
  # and where `ln -s` SUCCEEDED on the first pass (Windows with symlinks
  # enabled, or POSIX), the wrapper write then redirects THROUGH the existing
  # symlink into the real binary, corrupting a writable user-installed tool or
  # aborting the suite on a protected one. That is the latent HIMMEL-1469 hazard
  # the suffix change made reachable. Guarding on $_dest_name here fixes it for
  # every caller at once, and short-circuits before any ln/write can fire.
  if [ -e "$_dest/$_dest_name" ] || [ -L "$_dest/$_dest_name" ]; then
    return 0
  fi
  # Every `fail` call below is followed by `return 1` (HIMMEL-2535). `fail` is
  # the SOURCING script's, and it is not required to exit -- a suite that counts
  # failures rather than aborting returns from it. Without the explicit return,
  # execution fell through with $_src EMPTY: `ln -s "" "$dest/$tool"` fails, the
  # wrapper fallback then WRITES `exec "" "$@"`, and the stub dir gains a
  # poisoned entry that the idempotency guard above will happily skip over
  # later. Callers whose `fail` exits are unaffected -- they never reach these.
  _src=$(command -v "$_tool" 2>/dev/null) || { fail "required test tool not found before PATH scrub: $_tool"; return 1; }
  case "$_src" in
    "$_dest/"*) return 0 ;;
  esac
  if ! ln -s "$_src" "$_dest/$_dest_name" 2>/dev/null; then
    # bash can't get a self-referential wrapper (the wrapper below execs via
    # #!/usr/bin/env bash, which needs a real bash on PATH). On symlink-
    # restricted shells, copy the binary instead of hard-failing the suite.
    if [ "$_tool" = "bash" ]; then
      cp "$_src" "$_dest/$_dest_name" || { fail "could not copy bash into hermetic stub dir"; return 1; }
      chmod +x "$_dest/$_dest_name"
      return 0
    fi
    {
      printf '%s\n' '#!/usr/bin/env bash'
      printf 'exec "%s" "$@"\n' "$_src"
    } > "$_dest/$_dest_name" || { fail "could not write hermetic wrapper for $_tool"; return 1; }
    chmod +x "$_dest/$_dest_name" || { fail "could not chmod hermetic wrapper for $_tool"; return 1; }
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

build_hermetic_bin() {
  # build_hermetic_bin <dest_dir> <tool>...
  #
  # THE SAFE SHAPE, in one call (HIMMEL-2535). Creates dest_dir and links
  # `bash` plus each named tool into it, so the caller can prepend dest_dir
  # ahead of a scrubbed PATH and satisfy the MUST in this file's header
  # without remembering it. `bash` is ALWAYS linked: it is the interpreter
  # every hermetic `bash -c` needs, and forgetting it is the failure that made
  # HIMMEL-2470/2520/2530 red.
  #
  # Name the tools your TARGET actually reaches for, derived empirically rather
  # than guessed -- the load-bearing step in all three of those tickets. The
  # recipe: build a dir where each candidate logs its own name then execs the
  # real binary, point the fixture at it, run once, read the log.
  #
  # Never name a tool you are scrubbing: this builds the allowlist, and a
  # scrubbed tool listed here is re-admitted through the front door (the
  # HIMMEL-2524 mistake, in its explicit form).
  local _dest="$1"; shift
  [ -n "$_dest" ] || { fail "build_hermetic_bin: empty destination dir"; return 1; }
  mkdir -p "$_dest" || { fail "build_hermetic_bin: could not create $_dest"; return 1; }
  # RETAIN a failure rather than letting the last iteration decide the rc
  # (HIMMEL-2535). `fail` belongs to the sourcing script and need not exit, so
  # with a counting `fail` a missing NON-FINAL tool was masked by a later
  # successful link and this returned 0 with an incomplete floor -- the exact
  # fail-open shape this helper exists to prevent. Every tool is still attempted
  # (one call reports every missing tool, not just the first), but the rc is the
  # AND of them all.
  local _t _rc=0
  for _t in bash "$@"; do
    link_hermetic_tool "$_t" "$_dest" || _rc=1
  done
  return "$_rc"
}

hermetic_path_excludes() {
  # hermetic_path_excludes <path> <tool>...
  #
  # rc 0 when NONE of the named tools resolve anywhere on <path>; rc 1 as soon
  # as one does. The assertion that turns "I built an allowlist" into evidence:
  # HIMMEL-2524's fixture believed it had excluded bun and had not, and nothing
  # checked. Call it right after composing the PATH a case will run under.
  local _path="$1"; shift
  local _t _d _save_ifs3 _norm
  # NORMALISE every empty segment to "." before splitting (HIMMEL-2535).
  # Word splitting alone cannot see them all, and each one it misses is a false
  # "excluded" about a PATH the shell WOULD resolve the tool on:
  #   ""        -> 0 fields   (an entirely empty PATH still runs ./tool -- measured)
  #   "/tmp:"   -> trailing empty dropped
  #   ":"       -> 1 field
  # Wrapping in delimiters and expanding "::" until none remain catches the
  # leading, trailing, doubled and whole-string cases uniformly.
  _norm=":$_path:"
  while case "$_norm" in *::*) true ;; *) false ;; esac; do
    _norm="${_norm/::/:.:}"
  done
  _norm="${_norm#:}"; _norm="${_norm%:}"
  for _t in "$@"; do
    _save_ifs3="$IFS"; IFS=':'
    for _d in $_norm; do
      # An EMPTY segment is not "nothing" — every shell reads it as the current
      # directory, so a tool sitting in the cwd genuinely resolves through it.
      # Skipping it here (the obvious spelling) makes this function answer
      # "excluded" about a PATH the shell would happily resolve the tool on: a
      # false negative in the one direction that matters, since callers use this
      # to PROVE a tool is unreachable. scrub_path drops empty segments by
      # design, but this checker is handed arbitrary paths and must model what a
      # shell actually does, not what a well-formed path would contain.
      [ -n "$_d" ] || _d="."
      if path_dir_has_scrubbed_tool "$_d" "$_t"; then IFS="$_save_ifs3"; return 1; fi
    done
    IFS="$_save_ifs3"
  done
  return 0
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
