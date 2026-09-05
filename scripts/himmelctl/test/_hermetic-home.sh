#!/usr/bin/env bash
# _hermetic-home.sh — sourced by every scripts/himmelctl/test/*.sh suite
# (HIMMEL-2350, Console Ruling 38).
#
# ROOT CAUSE: os.homedir() on win32 reads USERPROFILE, not HOME. Proven:
#   USERPROFILE='C:\Temp\sandbox' node -e "console.log(require('os').homedir())"
#   -> C:\Temp\sandbox, even with HOME set to something else entirely.
# A bash-level `HOME=` override is therefore a NO-OP for any node CHILD a
# suite spawns — the child still resolves the operator's REAL homedir. Every
# per-seam patch (HIMMELCTL_CACHE_DIR, HIMMEL_LUNA_CONFIG_PATH) only closes
# the ONE env-var override each library happens to check; it does nothing
# for a code path neither of us has enumerated. HIMMEL-2350's own live
# incident proved this: the operator's real install-profile.json was
# overwritten by a writeCache() call during a run where every suite already
# set HIMMELCTL_CACHE_DIR on every "$node_bin" "$wizard" invocation the
# static guard could see — the leak was in a shape the enumeration missed.
#
# THIS FILE'S JOB, post-consolidation: define `winpath()` ONCE for the whole
# directory instead of the 34 hand-copied local definitions that used to
# exist (one per suite file, plus a synthetic fixture copy inside
# test-suite-hermeticity.sh's own self-test). That duplication WAS the
# preflight bug: test-wizard-preflight.sh simply never got its copy, so
# every `$(winpath ...)` in it silently produced "" and the isolation vars
# built from it (USERPROFILE/HIMMELCTL_CACHE_DIR/HIMMEL_LUNA_CONFIG_PATH)
# fell straight through to the operator's real home. A shared definition
# means a suite that forgets (or fails) to source this file has NO winpath
# at all and dies on first use — loud and immediate — instead of quietly
# exporting an empty string that recreates the bug in whichever of the 34
# copies happens to be missing or broken next.
#
# WHY winpath ITSELF ASSERTS NON-EMPTY: the console's own read of the
# HIMMEL-2350 incident is the reason this function does not just transform
# and trust — cacheDir()/configPath() are BOTH `process.env.X || <real
# homedir path>`, and an EMPTY STRING IS FALSY in JS. "Set but empty" is
# therefore INDISTINGUISHABLE from "never set" at the seam this whole ticket
# exists to close. A missing `winpath()` definition, a failed `cygpath`, an
# unset upstream variable — any of them can silently produce `X=""`, and a
# static grep for `HIMMELCTL_CACHE_DIR=` still finds the assignment and
# scores the invocation "covered" even though the write lands on the
# operator (exactly what happened here). So `winpath()` ASSERTS its input is
# non-empty and its resolved output is non-empty, and fails LOUDLY (exit 1,
# to stderr) rather than silently returning "" and letting every
# `$(winpath ...)` call site downstream re-create the same bug.
#
# USAGE: source this file before using `winpath` anywhere in a suite —
# every *.sh in this directory that computes USERPROFILE/HIMMELCTL_CACHE_DIR/
# HIMMEL_LUNA_CONFIG_PATH/HIMMELCTL_BIN_DIR (or any other node-consumed path)
# via `$(winpath ...)` depends on it. Sourcing is now load-bearing BY
# CONSTRUCTION: a suite whose source line is missing, mistyped, or a no-op
# has no winpath function in scope at all, and bash fails the very first
# `$(winpath ...)` command substitution with "command not found" instead of
# silently expanding to "".
#
# winpath <posix-or-windows-path> — echoes <path> unchanged on posix, or its
# Windows form on git-bash/MSYS/Cygwin (node.exe/pwsh.exe misresolve MSYS
# /tmp-style paths). Dies loud on an empty INPUT, a missing/failing `cygpath`
# on MSYS/MinGW/Cygwin, or an empty OUTPUT.
winpath() {
  if [ -z "${1-}" ]; then
    echo "winpath: FATAL — called with an empty/missing path argument" >&2
    exit 1
  fi
  local _out
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      # codex-panel round 4: `cygpath -m "$1" 2>/dev/null || printf '%s' "$1"`
      # used to fall back to the RAW MSYS path (e.g. /c/Users/...) whenever
      # cygpath failed or was missing -- non-empty, so the empty-check below
      # passed it straight through, handing a native node.exe/pwsh.exe child
      # a path it cannot resolve. That silently defeated this function's
      # entire stated purpose (fail loud instead of handing back a bad
      # path), and swallowed the diagnosis with it (2>/dev/null). Both
      # failure modes now die loud instead, exactly like the two existing
      # FATAL paths -- no fallback to the untranslated path.
      if ! command -v cygpath >/dev/null 2>&1; then
        echo "winpath: FATAL — cygpath not found on PATH (required on $(uname -s) to translate \"$1\" to a Windows-native path) — refusing to silently return the untranslated MSYS path, which node.exe/pwsh.exe cannot resolve" >&2
        exit 1
      fi
      if ! _out="$(cygpath -m "$1" 2>/dev/null)"; then
        echo "winpath: FATAL — cygpath -m \"$1\" failed: $(cygpath -m "$1" 2>&1 >/dev/null) — refusing to silently return the untranslated MSYS path, which node.exe/pwsh.exe cannot resolve" >&2
        exit 1
      fi
      ;;
    *) _out="$1" ;;
  esac
  if [ -z "$_out" ]; then
    echo "winpath: FATAL — resolved an EMPTY path for input \"$1\" — refusing to return \"\" (this is the exact HIMMEL-2350 leak shape: USERPROFILE/HIMMELCTL_CACHE_DIR/HIMMEL_LUNA_CONFIG_PATH built from an empty winpath() result silently fall through to the operator's real home)" >&2
    exit 1
  fi
  printf '%s' "$_out"
}
